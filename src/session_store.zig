const std = @import("std");

const api = @import("api.zig");
const session = @import("session.zig");

const sessions_dir_parts = [_][]const u8{ "sessions", "zig" };

const StoredLine = struct {
    type: []const u8,
    title: ?[]const u8 = null,
    role: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    text: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub const SessionSummary = struct {
    id: []const u8,
    path: []const u8,
    title: ?[]const u8 = null,

    pub fn deinit(self: SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        if (self.title) |title| allocator.free(title);
    }
};

pub fn createSessionPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    try ensureSessionsDir(allocator, codex_home);

    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);

    const filename = try std.fmt.allocPrint(allocator, "rollout-{d}-{x}.jsonl", .{ timestamp, random_id });
    defer allocator.free(filename);

    return sessionFilePath(allocator, codex_home, filename);
}

pub fn createSessionPathForId(allocator: std.mem.Allocator, codex_home: []const u8, id: []const u8) ![]const u8 {
    try validateSessionId(id);
    try ensureSessionsDir(allocator, codex_home);

    const filename = try std.fmt.allocPrint(allocator, "rollout-{s}.jsonl", .{id});
    defer allocator.free(filename);

    return sessionFilePath(allocator, codex_home, filename);
}

pub fn saveTranscript(allocator: std.mem.Allocator, path: []const u8, transcript: *const session.Transcript) !void {
    try ensureParentDir(path);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    if (transcript.title) |title| {
        try appendStoredLineJson(allocator, &output, .{ .type = "metadata", .title = title });
    }

    for (transcript.history.items) |item| {
        const stored = try storedLineFromHistoryItem(item);
        try appendStoredLineJson(allocator, &output, stored);
    }

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = output.items,
    });
}

pub fn loadTranscript(allocator: std.mem.Allocator, path: []const u8) !session.Transcript {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        allocator,
        .limited(1024 * 1024 * 16),
    );
    defer allocator.free(bytes);

    var transcript = session.Transcript{};
    errdefer transcript.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(StoredLine, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.type, "metadata")) {
            if (parsed.value.title) |title| try transcript.setTitle(allocator, title);
            continue;
        }

        const item = try historyItemFromStoredLine(parsed.value);
        try transcript.appendHistoryItem(allocator, item);
    }

    return transcript;
}

pub fn resolveResumePath(allocator: std.mem.Allocator, codex_home: []const u8, target: ?[]const u8) ![]const u8 {
    const raw_target = std.mem.trim(u8, target orelse "last", " \t\r\n");
    if (raw_target.len == 0 or std.ascii.eqlIgnoreCase(raw_target, "last")) {
        return try latestSessionPath(allocator, codex_home) orelse error.NoSavedSessions;
    }

    if (std.fs.path.isAbsolute(raw_target) or hasPathSeparator(raw_target)) {
        return allocator.dupe(u8, raw_target);
    }

    const filename = if (std.mem.endsWith(u8, raw_target, ".jsonl"))
        try allocator.dupe(u8, raw_target)
    else if (std.mem.startsWith(u8, raw_target, "rollout-"))
        try std.fmt.allocPrint(allocator, "{s}.jsonl", .{raw_target})
    else
        try std.fmt.allocPrint(allocator, "rollout-{s}.jsonl", .{raw_target});
    defer allocator.free(filename);

    return sessionFilePath(allocator, codex_home, filename);
}

pub fn latestSessionPath(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const sessions = try listSessions(allocator, codex_home, 1);
    defer freeSessionSummaries(allocator, sessions);
    if (sessions.len == 0) return null;
    return try allocator.dupe(u8, sessions[0].path);
}

pub fn listSessions(allocator: std.mem.Allocator, codex_home: []const u8, limit: usize) ![]SessionSummary {
    const dir_path = try sessionsDirPath(allocator, codex_home);
    defer allocator.free(dir_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SessionSummary, 0),
        else => return err,
    };
    defer dir.close(io);

    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!isSessionFilename(entry.name)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }

    std.mem.sort([]const u8, names.items, {}, newerSessionNameFirst);

    const count = if (limit == 0) names.items.len else @min(limit, names.items.len);
    const summaries = try allocator.alloc(SessionSummary, count);
    var initialized: usize = 0;
    errdefer {
        for (summaries[0..initialized]) |summary| summary.deinit(allocator);
        allocator.free(summaries);
    }

    for (names.items[0..count], 0..) |name, index| {
        const id = try sessionIdFromFilename(allocator, name);
        errdefer allocator.free(id);
        const path = try sessionFilePath(allocator, codex_home, name);
        errdefer allocator.free(path);
        const title = readSessionTitle(allocator, path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (title) |value| allocator.free(value);
        summaries[index] = .{
            .id = id,
            .path = path,
            .title = title,
        };
        initialized += 1;
    }

    return summaries;
}

pub fn freeSessionSummaries(allocator: std.mem.Allocator, summaries: []SessionSummary) void {
    for (summaries) |summary| summary.deinit(allocator);
    allocator.free(summaries);
}

pub fn printSessionList(allocator: std.mem.Allocator, codex_home: []const u8, limit: usize) !void {
    const sessions = try listSessions(allocator, codex_home, limit);
    defer freeSessionSummaries(allocator, sessions);

    if (sessions.len == 0) {
        std.debug.print("sessions: <none>\n", .{});
        return;
    }

    std.debug.print("sessions: showing {d}\n", .{sessions.len});
    for (sessions, 0..) |entry, index| {
        printSessionSummary(index, entry);
    }
}

pub fn printSessionSummary(index: usize, entry: SessionSummary) void {
    if (entry.title) |title| {
        std.debug.print("  {d}. {s} - {s}\n     {s}\n", .{ index + 1, entry.id, title, entry.path });
    } else {
        std.debug.print("  {d}. {s}\n     {s}\n", .{ index + 1, entry.id, entry.path });
    }
}

fn appendStoredLineJson(allocator: std.mem.Allocator, output: *std.ArrayList(u8), stored: StoredLine) !void {
    const line = try std.json.Stringify.valueAlloc(allocator, stored, .{ .emit_null_optional_fields = false });
    defer allocator.free(line);
    try output.appendSlice(allocator, line);
    try output.append(allocator, '\n');
}

fn sessionsDirPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, sessions_dir_parts[0], sessions_dir_parts[1] });
}

fn sessionFilePath(allocator: std.mem.Allocator, codex_home: []const u8, filename: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, sessions_dir_parts[0], sessions_dir_parts[1], filename });
}

fn ensureSessionsDir(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const path = try sessionsDirPath(allocator, codex_home);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
}

fn validateSessionId(id: []const u8) !void {
    if (id.len == 0) return error.InvalidSessionId;
    if (hasPathSeparator(id)) return error.InvalidSessionId;
    if (std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidSessionId;
}

fn hasPathSeparator(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "/\\") != null;
}

fn isSessionFilename(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "rollout-") and std.mem.endsWith(u8, name, ".jsonl");
}

fn newerSessionNameFirst(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .gt;
}

fn sessionIdFromFilename(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const without_prefix = if (std.mem.startsWith(u8, filename, "rollout-"))
        filename["rollout-".len..]
    else
        filename;
    const without_suffix = if (std.mem.endsWith(u8, without_prefix, ".jsonl"))
        without_prefix[0 .. without_prefix.len - ".jsonl".len]
    else
        without_prefix;
    return allocator.dupe(u8, without_suffix);
}

fn storedLineFromHistoryItem(item: api.HistoryItem) !StoredLine {
    return switch (item.kind) {
        .message => .{
            .type = "message",
            .role = item.role orelse return error.InvalidSessionItem,
            .content_type = item.content_type orelse return error.InvalidSessionItem,
            .text = item.text orelse return error.InvalidSessionItem,
        },
        .function_call => .{
            .type = "function_call",
            .call_id = item.call_id orelse return error.InvalidSessionItem,
            .name = item.name orelse return error.InvalidSessionItem,
            .arguments = item.arguments orelse return error.InvalidSessionItem,
        },
        .function_call_output => .{
            .type = "function_call_output",
            .call_id = item.call_id orelse return error.InvalidSessionItem,
            .output = item.output orelse return error.InvalidSessionItem,
        },
    };
}

fn readSessionTitle(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        const line_raw = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return null,
            else => return err,
        } orelse return null;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(StoredLine, allocator, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.type, "metadata")) {
            if (parsed.value.title) |title| {
                const copy = try allocator.dupe(u8, title);
                return copy;
            }
            return null;
        }

        return null;
    }
}

fn historyItemFromStoredLine(line: StoredLine) !api.HistoryItem {
    if (std.mem.eql(u8, line.type, "message")) {
        if (line.role == null or line.content_type == null or line.text == null) return error.InvalidSessionLine;
        return .{
            .kind = .message,
            .role = line.role,
            .content_type = line.content_type,
            .text = line.text,
        };
    }

    if (std.mem.eql(u8, line.type, "function_call")) {
        if (line.call_id == null or line.name == null or line.arguments == null) return error.InvalidSessionLine;
        return .{
            .kind = .function_call,
            .call_id = line.call_id,
            .name = line.name,
            .arguments = line.arguments,
        };
    }

    if (std.mem.eql(u8, line.type, "function_call_output")) {
        if (line.call_id == null or line.output == null) return error.InvalidSessionLine;
        return .{
            .kind = .function_call_output,
            .call_id = line.call_id,
            .output = line.output,
        };
    }

    return error.InvalidSessionLine;
}

test "session store round trips transcript jsonl" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.setTitle(allocator, "demo transcript");
    try transcript.appendUserMessage(allocator, "hello");
    try transcript.appendAssistantMessage(allocator, "hi");
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call,
        .call_id = "call-1",
        .name = "shell_command",
        .arguments = "{\"command\":\"pwd\"}",
    });
    try transcript.appendFunctionOutput(allocator, "call-1", "stdout:\n/tmp\n");

    const path = try createSessionPathForId(allocator, root, "test-a");
    defer allocator.free(path);
    try saveTranscript(allocator, path, &transcript);

    var loaded = try loadTranscript(allocator, path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("demo transcript", loaded.title.?);
    try std.testing.expectEqual(@as(usize, 4), loaded.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.message, loaded.history.items[0].kind);
    try std.testing.expectEqualStrings("user", loaded.history.items[0].role.?);
    try std.testing.expectEqualStrings("hello", loaded.history.items[0].text.?);
    try std.testing.expectEqual(api.HistoryItem.Kind.function_call, loaded.history.items[2].kind);
    try std.testing.expectEqualStrings("shell_command", loaded.history.items[2].name.?);
    try std.testing.expectEqualStrings("stdout:\n/tmp\n", loaded.history.items[3].output.?);
}

test "list sessions includes persisted title metadata" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.setTitle(allocator, "important demo");
    try transcript.appendUserMessage(allocator, "session");

    const path = try createSessionPathForId(allocator, root, "001-titled");
    defer allocator.free(path);
    try saveTranscript(allocator, path, &transcript);

    const sessions = try listSessions(allocator, root, 1);
    defer freeSessionSummaries(allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("001-titled", sessions[0].id);
    try std.testing.expectEqualStrings("important demo", sessions[0].title.?);
}

test "list sessions tolerates large untitled transcript lines" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    const long_text = try allocator.alloc(u8, 8192);
    defer allocator.free(long_text);
    @memset(long_text, 'a');

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.appendUserMessage(allocator, long_text);

    const path = try createSessionPathForId(allocator, root, "001-large");
    defer allocator.free(path);
    try saveTranscript(allocator, path, &transcript);

    const sessions = try listSessions(allocator, root, 1);
    defer freeSessionSummaries(allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("001-large", sessions[0].id);
    try std.testing.expect(sessions[0].title == null);
}

test "latest session path picks lexicographically newest rollout" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.appendUserMessage(allocator, "first");

    const older = try createSessionPathForId(allocator, root, "2024-01-01");
    defer allocator.free(older);
    try saveTranscript(allocator, older, &transcript);

    const newer = try createSessionPathForId(allocator, root, "2024-01-02");
    defer allocator.free(newer);
    try saveTranscript(allocator, newer, &transcript);

    const latest = (try latestSessionPath(allocator, root)).?;
    defer allocator.free(latest);
    try std.testing.expectEqualStrings("rollout-2024-01-02.jsonl", std.fs.path.basename(latest));
}

test "list sessions returns newest first and supports limits" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.appendUserMessage(allocator, "session");

    const older = try createSessionPathForId(allocator, root, "001-older");
    defer allocator.free(older);
    try saveTranscript(allocator, older, &transcript);

    const newer = try createSessionPathForId(allocator, root, "002-newer");
    defer allocator.free(newer);
    try saveTranscript(allocator, newer, &transcript);

    const sessions = try listSessions(allocator, root, 0);
    defer freeSessionSummaries(allocator, sessions);
    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("002-newer", sessions[0].id);
    try std.testing.expectEqualStrings("001-older", sessions[1].id);

    const limited = try listSessions(allocator, root, 1);
    defer freeSessionSummaries(allocator, limited);
    try std.testing.expectEqual(@as(usize, 1), limited.len);
    try std.testing.expectEqualStrings("002-newer", limited[0].id);
}

test "resume target accepts ids and rollout filenames" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    const id_path = try resolveResumePath(allocator, root, "2024-01-03");
    defer allocator.free(id_path);
    try std.testing.expectEqualStrings("rollout-2024-01-03.jsonl", std.fs.path.basename(id_path));

    const filename_path = try resolveResumePath(allocator, root, "rollout-2024-01-04");
    defer allocator.free(filename_path);
    try std.testing.expectEqualStrings("rollout-2024-01-04.jsonl", std.fs.path.basename(filename_path));
}
