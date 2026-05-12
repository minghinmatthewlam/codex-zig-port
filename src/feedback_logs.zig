const std = @import("std");

const memory_reset = @import("memory_reset.zig");
const sqlite = @import("sqlite.zig");

const LOG_PARTITION_SIZE_LIMIT_BYTES: usize = 10 * 1024 * 1024;

pub fn queryFeedbackLogsForThreads(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thread_ids: []const []const u8,
) ![]const u8 {
    if (thread_ids.len == 0) return allocator.dupe(u8, "");

    const logs_path = try memory_reset.resolveLogsDbPath(allocator, codex_home);
    defer allocator.free(logs_path);
    if (!try memory_reset.stateDbExists(allocator, logs_path)) return allocator.dupe(u8, "");

    const db = try sqlite.openReadOnly(allocator, logs_path);
    defer sqlite.close(db);

    const query = try buildFeedbackLogsQuery(allocator, thread_ids.len);
    defer allocator.free(query);

    const statement = try sqlite.prepare(allocator, db, query);
    defer sqlite.finalize(statement);

    for (thread_ids, 0..) |thread_id, index| {
        const bind_index: c_int = @intCast(index + 1);
        try sqlite.bindText(statement, bind_index, thread_id);
    }
    const limit_index: c_int = @intCast(thread_ids.len + 1);
    try sqlite.bindInt64(statement, limit_index, @intCast(LOG_PARTITION_SIZE_LIMIT_BYTES));

    var newest_first = std.ArrayList([]const u8).empty;
    defer {
        for (newest_first.items) |line| allocator.free(line);
        newest_first.deinit(allocator);
    }
    var total_bytes: usize = 0;

    while (true) {
        switch (sqlite.step(statement)) {
            sqlite.SQLITE_ROW => {
                const ts = sqlite.columnInt64(statement, 0);
                const ts_nanos = sqlite.columnInt64(statement, 1);
                const level = try sqlite.columnTextOwned(allocator, statement, 2);
                defer allocator.free(level);
                const body = try sqlite.columnTextOwned(allocator, statement, 3);
                defer allocator.free(body);

                const line = try formatFeedbackLogLine(allocator, ts, ts_nanos, level, body);
                errdefer allocator.free(line);
                if (line.len > LOG_PARTITION_SIZE_LIMIT_BYTES - total_bytes) {
                    allocator.free(line);
                    break;
                }
                total_bytes += line.len;
                try newest_first.append(allocator, line);
            },
            sqlite.SQLITE_DONE => break,
            else => return error.FeedbackLogsStepFailed,
        }
    }

    var ordered = std.ArrayList(u8).empty;
    errdefer ordered.deinit(allocator);
    try ordered.ensureTotalCapacity(allocator, total_bytes);
    var index = newest_first.items.len;
    while (index > 0) {
        index -= 1;
        try ordered.appendSlice(allocator, newest_first.items[index]);
    }
    return ordered.toOwnedSlice(allocator);
}

fn buildFeedbackLogsQuery(allocator: std.mem.Allocator, thread_count: usize) ![]const u8 {
    var query = std.ArrayList(u8).empty;
    errdefer query.deinit(allocator);
    try query.appendSlice(allocator,
        \\WITH requested_threads(thread_id) AS (
        \\    VALUES 
    );
    for (0..thread_count) |index| {
        if (index > 0) try query.appendSlice(allocator, ", ");
        try query.appendSlice(allocator, "(?)");
    }
    try query.appendSlice(allocator,
        \\
        \\),
        \\latest_processes AS (
        \\    SELECT (
        \\        SELECT process_uuid
        \\        FROM logs
        \\        WHERE logs.thread_id = requested_threads.thread_id AND process_uuid IS NOT NULL
        \\        ORDER BY ts DESC, ts_nanos DESC, id DESC
        \\        LIMIT 1
        \\    ) AS process_uuid
        \\    FROM requested_threads
        \\),
        \\feedback_logs AS (
        \\    SELECT ts, ts_nanos, level, feedback_log_body, estimated_bytes, id
        \\    FROM logs
        \\    WHERE feedback_log_body IS NOT NULL AND (
        \\        thread_id IN (SELECT thread_id FROM requested_threads)
        \\        OR (
        \\            thread_id IS NULL
        \\            AND process_uuid IN (
        \\                SELECT process_uuid
        \\                FROM latest_processes
        \\                WHERE process_uuid IS NOT NULL
        \\            )
        \\        )
        \\    )
        \\),
        \\bounded_feedback_logs AS (
        \\    SELECT
        \\        ts,
        \\        ts_nanos,
        \\        level,
        \\        feedback_log_body,
        \\        id,
        \\        SUM(estimated_bytes) OVER (
        \\            ORDER BY ts DESC, ts_nanos DESC, id DESC
        \\        ) AS cumulative_estimated_bytes
        \\    FROM feedback_logs
        \\)
        \\SELECT ts, ts_nanos, level, feedback_log_body
        \\FROM bounded_feedback_logs
        \\WHERE cumulative_estimated_bytes <= ?
        \\ORDER BY ts DESC, ts_nanos DESC, id DESC
        \\
    );
    return query.toOwnedSlice(allocator);
}

fn formatFeedbackLogLine(
    allocator: std.mem.Allocator,
    ts: i64,
    ts_nanos: i64,
    level: []const u8,
    body: []const u8,
) ![]const u8 {
    const timestamp = try formatTimestampMicros(allocator, ts, ts_nanos);
    defer allocator.free(timestamp);

    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, timestamp);
    try line.append(allocator, ' ');
    const padding = if (level.len < 5) 5 - level.len else 0;
    try line.appendNTimes(allocator, ' ', padding);
    try line.appendSlice(allocator, level);
    try line.append(allocator, ' ');
    try line.appendSlice(allocator, body);
    if (!std.mem.endsWith(u8, body, "\n")) try line.append(allocator, '\n');
    return line.toOwnedSlice(allocator);
}

fn formatTimestampMicros(allocator: std.mem.Allocator, ts: i64, ts_nanos: i64) ![]const u8 {
    if (ts < 0 or ts_nanos < 0 or ts_nanos >= std.time.ns_per_s) {
        return std.fmt.allocPrint(allocator, "{d}.{d:0>9}Z", .{ ts, ts_nanos });
    }

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const micros: u32 = @intCast(@divTrunc(ts_nanos, std.time.ns_per_us));

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            micros,
        },
    );
}

test "feedback log line matches Rust attachment format" {
    const allocator = std.testing.allocator;
    const line = try formatFeedbackLogLine(allocator, 1700000000, 123456789, "INFO", "smoke row");
    defer allocator.free(line);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.123456Z  INFO smoke row\n", line);
}

test "feedback log line preserves trailing newline" {
    const allocator = std.testing.allocator;
    const line = try formatFeedbackLogLine(allocator, 1, 0, "WARN", "already newline\n");
    defer allocator.free(line);
    try std.testing.expectEqualStrings("1970-01-01T00:00:01.000000Z  WARN already newline\n", line);
}
