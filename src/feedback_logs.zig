const std = @import("std");

const memory_reset = @import("memory_reset.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY = 0x00000001;
const LOG_PARTITION_SIZE_LIMIT_BYTES: usize = 10 * 1024 * 1024;

extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    pp_db: *?*sqlite3,
    flags: c_int,
    z_vfs: ?[*:0]const u8,
) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_prepare_v2(
    db: *sqlite3,
    z_sql: [*:0]const u8,
    n_byte: c_int,
    pp_stmt: *?*sqlite3_stmt,
    pz_tail: ?*[*:0]const u8,
) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    index: c_int,
    value: [*]const u8,
    bytes: c_int,
    destructor: ?*const anyopaque,
) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, column: c_int) i64;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, column: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, column: c_int) c_int;

pub fn queryFeedbackLogsForThreads(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thread_ids: []const []const u8,
) ![]const u8 {
    if (thread_ids.len == 0) return allocator.dupe(u8, "");

    const logs_path = try memory_reset.resolveLogsDbPath(allocator, codex_home);
    defer allocator.free(logs_path);
    if (!try memory_reset.stateDbExists(allocator, logs_path)) return allocator.dupe(u8, "");

    const logs_path_z = try allocator.dupeZ(u8, logs_path);
    defer allocator.free(logs_path_z);

    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(logs_path_z.ptr, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        if (db) |handle| _ = sqlite3_close(handle);
        return error.FeedbackLogsOpenFailed;
    }
    defer if (db) |handle| {
        _ = sqlite3_close(handle);
    };

    const query = try buildFeedbackLogsQuery(allocator, thread_ids.len);
    defer allocator.free(query);
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db.?, query_z.ptr, -1, &stmt, null) != SQLITE_OK) {
        return error.FeedbackLogsPrepareFailed;
    }
    defer if (stmt) |statement| {
        _ = sqlite3_finalize(statement);
    };

    const statement = stmt.?;
    for (thread_ids, 0..) |thread_id, index| {
        const bind_index: c_int = @intCast(index + 1);
        const bind_len: c_int = @intCast(thread_id.len);
        if (sqlite3_bind_text(statement, bind_index, thread_id.ptr, bind_len, null) != SQLITE_OK) {
            return error.FeedbackLogsBindFailed;
        }
    }
    const limit_index: c_int = @intCast(thread_ids.len + 1);
    if (sqlite3_bind_int64(statement, limit_index, @intCast(LOG_PARTITION_SIZE_LIMIT_BYTES)) != SQLITE_OK) {
        return error.FeedbackLogsBindFailed;
    }

    var newest_first = std.ArrayList([]const u8).empty;
    defer {
        for (newest_first.items) |line| allocator.free(line);
        newest_first.deinit(allocator);
    }
    var total_bytes: usize = 0;

    while (true) {
        switch (sqlite3_step(statement)) {
            SQLITE_ROW => {
                const ts = sqlite3_column_int64(statement, 0);
                const ts_nanos = sqlite3_column_int64(statement, 1);
                const level = try columnTextOwned(allocator, statement, 2);
                defer allocator.free(level);
                const body = try columnTextOwned(allocator, statement, 3);
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
            SQLITE_DONE => break,
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

fn columnTextOwned(allocator: std.mem.Allocator, stmt: *sqlite3_stmt, column: c_int) ![]const u8 {
    const text = sqlite3_column_text(stmt, column) orelse return allocator.dupe(u8, "");
    const len = sqlite3_column_bytes(stmt, column);
    if (len < 0) return error.FeedbackLogsColumnFailed;
    return allocator.dupe(u8, text[0..@intCast(len)]);
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
