const std = @import("std");

const api = @import("api.zig");
const session = @import("session.zig");

const sessions_dir_parts = [_][]const u8{ "sessions", "zig" };

const StoredLine = struct {
    type: []const u8,
    title: ?[]const u8 = null,
    memory_mode: ?[]const u8 = null,
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

pub fn sessionIdFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return sessionIdFromFilename(allocator, std.fs.path.basename(path));
}

pub fn saveTranscript(allocator: std.mem.Allocator, path: []const u8, transcript: *const session.Transcript) !void {
    try ensureParentDir(path);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    if (transcript.title != null or transcript.memory_mode != null) {
        try appendStoredLineJson(allocator, &output, .{
            .type = "metadata",
            .title = transcript.title,
            .memory_mode = transcript.memory_mode,
        });
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

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try appendTranscriptLine(allocator, &transcript, parsed.value);
    }

    return transcript;
}

fn appendTranscriptLine(allocator: std.mem.Allocator, transcript: *session.Transcript, line: std.json.Value) !void {
    if (line != .object) return error.InvalidSessionLine;
    const object = line.object;
    const type_value = object.get("type") orelse return error.InvalidSessionLine;
    if (type_value != .string) return error.InvalidSessionLine;
    const line_type = type_value.string;

    if (std.mem.eql(u8, line_type, "metadata")) {
        if (jsonStringField(object, "title")) |title| try transcript.setTitle(allocator, title);
        if (jsonStringField(object, "memory_mode")) |value| try transcript.setMemoryMode(allocator, value);
        return;
    }

    if (std.mem.eql(u8, line_type, "message")) {
        try appendStoredMessage(allocator, transcript, object);
        return;
    }

    if (std.mem.eql(u8, line_type, "function_call")) {
        try appendStoredFunctionCall(allocator, transcript, object);
        return;
    }

    if (std.mem.eql(u8, line_type, "function_call_output")) {
        try appendStoredFunctionCallOutput(allocator, transcript, object);
        return;
    }

    if (std.mem.eql(u8, line_type, "session_meta")) {
        const payload = object.get("payload") orelse return;
        try applyRolloutSessionMeta(allocator, transcript, payload);
        return;
    }

    if (std.mem.eql(u8, line_type, "response_item")) {
        const payload = object.get("payload") orelse return error.InvalidSessionLine;
        try session.appendResponseHistoryItem(allocator, transcript, payload);
        return;
    }

    if (std.mem.eql(u8, line_type, "event_msg")) {
        const payload = object.get("payload") orelse return;
        applyRolloutEventMsg(transcript, payload);
        return;
    }
}

fn appendStoredMessage(allocator: std.mem.Allocator, transcript: *session.Transcript, object: std.json.ObjectMap) !void {
    try transcript.appendHistoryItem(allocator, .{
        .kind = .message,
        .role = jsonStringField(object, "role") orelse return error.InvalidSessionLine,
        .content_type = jsonStringField(object, "content_type") orelse return error.InvalidSessionLine,
        .text = jsonStringField(object, "text") orelse return error.InvalidSessionLine,
    });
}

fn appendStoredFunctionCall(allocator: std.mem.Allocator, transcript: *session.Transcript, object: std.json.ObjectMap) !void {
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call,
        .call_id = jsonStringField(object, "call_id") orelse return error.InvalidSessionLine,
        .name = jsonStringField(object, "name") orelse return error.InvalidSessionLine,
        .arguments = jsonStringField(object, "arguments") orelse return error.InvalidSessionLine,
    });
}

fn appendStoredFunctionCallOutput(allocator: std.mem.Allocator, transcript: *session.Transcript, object: std.json.ObjectMap) !void {
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call_output,
        .call_id = jsonStringField(object, "call_id") orelse return error.InvalidSessionLine,
        .output = jsonStringField(object, "output") orelse return error.InvalidSessionLine,
    });
}

fn applyRolloutSessionMeta(
    allocator: std.mem.Allocator,
    transcript: *session.Transcript,
    payload: std.json.Value,
) !void {
    if (payload != .object) return;
    const object = if (payload.object.get("meta")) |meta_value|
        if (meta_value == .object) meta_value.object else payload.object
    else
        payload.object;

    if (jsonStringField(object, "id")) |value| try transcript.setId(allocator, value);
    if (jsonStringField(object, "forked_from_id")) |value| try transcript.setForkedFromId(allocator, value);
    if (jsonStringField(object, "source")) |value| try transcript.setSource(allocator, value);
    if (jsonStringField(object, "thread_source")) |value| try transcript.setThreadSource(allocator, value);
    if (jsonStringField(object, "model_provider")) |value| try transcript.setModelProvider(allocator, value);
    if (jsonStringField(object, "cwd")) |value| try transcript.setCwd(allocator, value);
    if (jsonStringField(object, "cli_version")) |value| try transcript.setCliVersion(allocator, value);
    if (jsonStringField(object, "memory_mode")) |value| try transcript.setMemoryMode(allocator, value);
}

fn jsonStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn applyRolloutEventMsg(transcript: *session.Transcript, payload: std.json.Value) void {
    if (payload != .object) return;
    const object = payload.object;
    const event_type = jsonStringField(object, "type") orelse return;
    if (!std.mem.eql(u8, event_type, "token_count")) return;

    const info_value = object.get("info") orelse return;
    if (info_value != .object) return;
    const info = parseTokenUsageInfo(info_value.object) orelse return;
    transcript.token_usage = info;
    transcript.token_usage_turn_index = lastMessageTurnIndex(transcript);
}

fn parseTokenUsageInfo(object: std.json.ObjectMap) ?session.TokenUsageInfo {
    const total_value = object.get("total_token_usage") orelse return null;
    if (total_value != .object) return null;
    const last_value = object.get("last_token_usage") orelse return null;
    if (last_value != .object) return null;

    return .{
        .total = parseTokenUsage(total_value.object) orelse return null,
        .last = parseTokenUsage(last_value.object) orelse return null,
        .model_context_window = jsonOptionalIntField(object, "model_context_window"),
    };
}

fn parseTokenUsage(object: std.json.ObjectMap) ?session.TokenUsage {
    return .{
        .input_tokens = jsonIntField(object, "input_tokens") orelse return null,
        .cached_input_tokens = jsonIntField(object, "cached_input_tokens") orelse return null,
        .output_tokens = jsonIntField(object, "output_tokens") orelse return null,
        .reasoning_output_tokens = jsonIntField(object, "reasoning_output_tokens") orelse return null,
        .total_tokens = jsonIntField(object, "total_tokens") orelse return null,
    };
}

fn jsonOptionalIntField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    return jsonValueAsInt(value);
}

fn jsonIntField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return jsonValueAsInt(value);
}

fn jsonValueAsInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        else => null,
    };
}

fn lastMessageTurnIndex(transcript: *const session.Transcript) ?usize {
    var turn_index: usize = 0;
    var last_index: ?usize = null;
    for (transcript.history.items) |item| {
        if (item.kind != .message) continue;
        last_index = turn_index;
        turn_index += 1;
    }
    return last_index;
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

    const zig_path = try sessionFilePath(allocator, codex_home, filename);
    errdefer allocator.free(zig_path);
    if (fileExists(zig_path)) return zig_path;

    if (isUuidLike(raw_target)) {
        if (try findRolloutPathByThreadId(allocator, codex_home, raw_target)) |path| {
            allocator.free(zig_path);
            return path;
        }
    }

    return zig_path;
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
    return allocator.dupe(u8, rolloutThreadIdFromStem(without_suffix) orelse without_suffix);
}

fn rolloutThreadIdFromStem(stem: []const u8) ?[]const u8 {
    if (isUuidLike(stem)) return stem;
    if (stem.len < 37) return null;
    const uuid_start = stem.len - 36;
    if (stem[uuid_start - 1] != '-') return null;
    const candidate = stem[uuid_start..];
    if (!isUuidLike(candidate)) return null;
    return candidate;
}

fn findRolloutPathByThreadId(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thread_id: []const u8,
) !?[]const u8 {
    const sessions_root = try std.fs.path.join(allocator, &.{ codex_home, "sessions" });
    defer allocator.free(sessions_root);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, sessions_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    return try findRolloutPathByThreadIdInDir(allocator, io, sessions_root, "", &dir, thread_id, 0);
}

fn findRolloutPathByThreadIdInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_dir: []const u8,
    dir: *std.Io.Dir,
    thread_id: []const u8,
    depth: usize,
) !?[]const u8 {
    if (depth > 8) return null;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        const relative_path = try relativeChildPath(allocator, relative_dir, entry.name);
        defer allocator.free(relative_path);

        const full_path = try std.fs.path.join(allocator, &.{ root, relative_path });
        defer allocator.free(full_path);

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file and isSessionFilename(entry.name)) {
            const id = try sessionIdFromFilename(allocator, entry.name);
            defer allocator.free(id);
            if (std.mem.eql(u8, id, thread_id)) return try allocator.dupe(u8, full_path);
            continue;
        }

        if (stat.kind != .directory) continue;
        var child_dir = std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true }) catch continue;
        defer child_dir.close(io);
        if (try findRolloutPathByThreadIdInDir(allocator, io, root, relative_path, &child_dir, thread_id, depth + 1)) |path| {
            return path;
        }
    }

    return null;
}

fn relativeChildPath(allocator: std.mem.Allocator, relative_dir: []const u8, name: []const u8) ![]const u8 {
    if (relative_dir.len == 0) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ relative_dir, name });
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .file;
}

fn isUuidLike(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(char)) return false;
    }
    return true;
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

test "session store round trips transcript jsonl" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.setTitle(allocator, "demo transcript");
    try transcript.setMemoryMode(allocator, "disabled");
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
    try std.testing.expectEqualStrings("disabled", loaded.memory_mode.?);
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

test "session id from path extracts Rust rollout uuid suffix" {
    const allocator = std.testing.allocator;
    const id = try sessionIdFromPath(allocator, "/tmp/sessions/2025/01/05/rollout-2025-01-05T12-00-00-22222222-2222-4222-8222-222222222222.jsonl");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("22222222-2222-4222-8222-222222222222", id);
}

test "resume target finds Rust rollout layout by uuid" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    const path = try std.fs.path.join(allocator, &.{ root, "sessions", "2025", "01", "05", "rollout-2025-01-05T12-00-00-22222222-2222-4222-8222-222222222222.jsonl" });
    defer allocator.free(path);
    try ensureParentDir(path);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = "\n",
    });

    const resolved = try resolveResumePath(allocator, root, "22222222-2222-4222-8222-222222222222");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(path, resolved);
}

test "load transcript accepts Rust rollout response items and session metadata" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    const path = try std.fs.path.join(allocator, &.{ root, "sessions", "2025", "01", "05", "rollout-2025-01-05T12-00-00-22222222-2222-4222-8222-222222222222.jsonl" });
    defer allocator.free(path);
    try ensureParentDir(path);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data =
        \\{"timestamp":"2025-01-05T12:00:00Z","type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","timestamp":"2025-01-05T12:00:00Z","cwd":"/","originator":"codex","cli_version":"0.0.0","source":"cli","thread_source":"user","model_provider":"mock_provider","memory_mode":"polluted"}}
        \\{"timestamp":"2025-01-05T12:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rust hello"}]}}
        \\{"timestamp":"2025-01-05T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":150},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":90},"model_context_window":200000},"rate_limits":null}}
        \\
        ,
    });

    var loaded = try loadTranscript(allocator, path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("22222222-2222-4222-8222-222222222222", loaded.id.?);
    try std.testing.expectEqualStrings("cli", loaded.source.?);
    try std.testing.expectEqualStrings("user", loaded.thread_source.?);
    try std.testing.expectEqualStrings("mock_provider", loaded.model_provider.?);
    try std.testing.expectEqualStrings("/", loaded.cwd.?);
    try std.testing.expectEqualStrings("0.0.0", loaded.cli_version.?);
    try std.testing.expectEqualStrings("polluted", loaded.memory_mode.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.history.items.len);
    try std.testing.expectEqualStrings("user", loaded.history.items[0].role.?);
    try std.testing.expectEqualStrings("rust hello", loaded.history.items[0].text.?);
    try std.testing.expectEqual(@as(usize, 0), loaded.token_usage_turn_index.?);
    try std.testing.expectEqual(@as(i64, 150), loaded.token_usage.?.total.total_tokens);
    try std.testing.expectEqual(@as(i64, 120), loaded.token_usage.?.total.input_tokens);
    try std.testing.expectEqual(@as(i64, 20), loaded.token_usage.?.total.cached_input_tokens);
    try std.testing.expectEqual(@as(i64, 30), loaded.token_usage.?.total.output_tokens);
    try std.testing.expectEqual(@as(i64, 10), loaded.token_usage.?.total.reasoning_output_tokens);
    try std.testing.expectEqual(@as(i64, 90), loaded.token_usage.?.last.total_tokens);
    try std.testing.expectEqual(@as(i64, 200000), loaded.token_usage.?.model_context_window.?);
}
