const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const socket_override_env = "CODEX_ZIG_IDE_CONTEXT_SOCKET";
const source_client_id = "codex-tui";
const request_timeout_ms: i64 = 5 * std.time.ms_per_s;
const max_ipc_frame_bytes: usize = 256 * 1024 * 1024;
const max_active_selection_chars: usize = 40_000;
const max_open_tabs: usize = 100;
const max_open_tabs_chars: usize = 20_000;
const prompt_request_begin = "## My request for Codex:";

const keep_trying_hint = "Codex will keep trying on future messages.";
const open_ide_hint = "Open this project in VS Code or Cursor with the Codex extension active.";
const ide_missing_context_hint = "The IDE extension did not provide context.";

extern fn getpeereid(fd: c_int, euid: *std.c.uid_t, egid: *std.c.gid_t) c_int;

pub const FetchFailureKind = enum {
    connect,
    send,
    read,
    invalid_response,
    response_too_large,
    request_failed,
};

pub const RequestFailureKind = enum {
    no_client_found,
    client_disconnected,
    request_timeout,
    request_version_mismatch,
    no_handler_for_request,
    unknown,
};

pub const FetchFailure = struct {
    kind: FetchFailureKind,
    request_error: ?RequestFailureKind = null,
    timed_out: bool = false,
};

pub const FetchOutcome = union(enum) {
    context: ?[]const u8,
    failure: FetchFailure,
};

const FrameOutcome = union(enum) {
    payload: []u8,
    failure: FetchFailure,
};

const Position = struct {
    line: u64,
    character: u64,
};

const Range = struct {
    start: Position,
    end: Position,
};

pub fn fetchPromptContext(allocator: std.mem.Allocator, workspace_root: []const u8) !FetchOutcome {
    const socket_path = try defaultSocketPath(allocator);
    defer allocator.free(socket_path);

    if (try validateSocketPath(allocator, socket_path)) |failure| return .{ .failure = failure };

    var address = net.UnixAddress.init(socket_path) catch return .{ .failure = .{ .kind = .connect } };
    const io = std.Io.Threaded.global_single_threaded.io();
    var stream = address.connect(io) catch return .{ .failure = .{ .kind = .connect } };
    defer stream.close(io);

    const fd = stream.socket.handle;
    if (validatePeerOwner(fd)) |failure| return .{ .failure = failure };

    const deadline_ms = nowMs() + request_timeout_ms;
    const request_id = try generateRequestId(allocator);
    defer allocator.free(request_id);
    const request = try renderIdeContextRequest(allocator, request_id, workspace_root);
    defer allocator.free(request);

    if (writeFrame(fd, request, deadline_ms)) |failure| return .{ .failure = failure };
    return try readIdeContextResponse(allocator, fd, request_id, deadline_ms);
}

pub fn prefixPrompt(allocator: std.mem.Allocator, context_text: []const u8, prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ context_text, prompt_request_begin, prompt });
}

pub fn userFacingHint(failure: FetchFailure) []const u8 {
    return switch (failure.kind) {
        .connect => open_ide_hint,
        .request_failed => if (failure.request_error == .no_client_found)
            open_ide_hint
        else
            ide_missing_context_hint ++ " Try /ide again.",
        .response_too_large => "The selected IDE context is too large. Clear any large selection in your IDE and try /ide again.",
        .send => "Codex could not request IDE context. Try /ide again.",
        .read, .invalid_response => "Codex could not read IDE context. Try /ide again.",
    };
}

pub fn promptSkipHint(failure: FetchFailure) []const u8 {
    return switch (failure.kind) {
        .response_too_large => "The selected IDE context is too large. Clear any large selection in your IDE.",
        .connect => open_ide_hint,
        .request_failed => switch (failure.request_error orelse .unknown) {
            .no_client_found => open_ide_hint,
            .client_disconnected => "The IDE connection changed while Codex was requesting context. " ++ keep_trying_hint,
            .request_timeout => "The IDE extension did not answer in time. " ++ keep_trying_hint,
            .request_version_mismatch => "The connected IDE extension is not compatible with this IDE context request.",
            .no_handler_for_request => "The connected IDE client does not support IDE context requests.",
            .unknown => ide_missing_context_hint ++ " " ++ keep_trying_hint,
        },
        .send => "Codex lost the IDE connection while requesting context. " ++ keep_trying_hint,
        .invalid_response => "Codex received an unexpected IDE context response. " ++ keep_trying_hint,
        .read => if (failure.timed_out)
            "Codex timed out waiting for IDE context. It will keep trying on future messages."
        else
            "Codex could not read IDE context. " ++ keep_trying_hint,
    };
}

fn defaultSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (try getEnvVarOwned(allocator, socket_override_env)) |override| {
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        if (trimmed.len > 0) {
            const copy = try allocator.dupe(u8, trimmed);
            allocator.free(override);
            return copy;
        }
        allocator.free(override);
    }

    const tmpdir_owned = try getEnvVarOwned(allocator, "TMPDIR");
    defer if (tmpdir_owned) |tmpdir| allocator.free(tmpdir);
    const tmpdir = tmpdir_owned orelse "/tmp";
    const file_name = try std.fmt.allocPrint(allocator, "ipc-{d}.sock", .{std.c.getuid()});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ tmpdir, "codex-ipc", file_name });
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
}

fn validateSocketPath(allocator: std.mem.Allocator, socket_path: []const u8) !?FetchFailure {
    const parent = std.fs.path.dirname(socket_path) orelse return .{ .kind = .connect };
    const uid = std.c.getuid();
    const parent_stat = (try statPathNoFollow(allocator, parent)) orelse return .{ .kind = .connect };
    const parent_mode: u32 = @intCast(parent_stat.mode);
    if (!std.c.S.ISDIR(parent_mode) or parent_stat.uid != uid or parent_mode & 0o022 != 0) {
        return .{ .kind = .connect };
    }

    const socket_stat = (try statPathNoFollow(allocator, socket_path)) orelse return .{ .kind = .connect };
    const socket_mode: u32 = @intCast(socket_stat.mode);
    if (!std.c.S.ISSOCK(socket_mode) or socket_stat.uid != uid) {
        return .{ .kind = .connect };
    }

    return null;
}

fn statPathNoFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
            .SUCCESS => return stat,
            .INTR => continue,
            .NOENT => return null,
            else => return error.StatFailed,
        }
    }
}

fn validatePeerOwner(fd: std.posix.fd_t) ?FetchFailure {
    if (builtin.os.tag != .macos) return null;
    var peer_uid: std.c.uid_t = 0;
    var peer_gid: std.c.gid_t = 0;
    if (getpeereid(@intCast(fd), &peer_uid, &peer_gid) != 0) return .{ .kind = .connect };
    if (peer_uid != std.c.getuid()) return .{ .kind = .connect };
    return null;
}

fn generateRequestId(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &bytes);
    return encoded;
}

fn renderIdeContextRequest(allocator: std.mem.Allocator, request_id: []const u8, workspace_root: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"request\",\"requestId\":");
    try appendJsonString(allocator, &out, request_id);
    try out.appendSlice(allocator, ",\"sourceClientId\":\"" ++ source_client_id ++ "\",\"version\":0,\"method\":\"ide-context\",\"params\":{\"workspaceRoot\":");
    try appendJsonString(allocator, &out, workspace_root);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn writeFrame(fd: std.posix.fd_t, payload: []const u8, deadline_ms: i64) ?FetchFailure {
    if (payload.len > std.math.maxInt(u32)) return .{ .kind = .send };
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(payload.len), .little);
    if (writeAllBeforeDeadline(fd, &len_bytes, deadline_ms)) |failure| return failure;
    return writeAllBeforeDeadline(fd, payload, deadline_ms);
}

fn writeAllBeforeDeadline(fd: std.posix.fd_t, bytes: []const u8, deadline_ms: i64) ?FetchFailure {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (waitForFd(fd, @intCast(std.posix.POLL.OUT), deadline_ms, .send)) |failure| return failure;
        const rc = sendNoSigpipe(fd, bytes[offset..]);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc <= 0) return .{ .kind = .send };
                offset += @intCast(rc);
            },
            .INTR => continue,
            else => return .{ .kind = .send },
        }
    }
    return null;
}

fn sendNoSigpipe(fd: std.posix.fd_t, bytes: []const u8) isize {
    return std.c.send(fd, bytes.ptr, bytes.len, noSigpipeSendFlags());
}

fn noSigpipeSendFlags() u32 {
    return switch (builtin.os.tag) {
        .driverkit, .ios, .linux, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.c.MSG.NOSIGNAL,
        else => 0,
    };
}

fn readIdeContextResponse(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    request_id: []const u8,
    deadline_ms: i64,
) !FetchOutcome {
    while (true) {
        const frame = try readFrame(allocator, fd, deadline_ms);
        switch (frame) {
            .failure => |failure| return .{ .failure = failure },
            .payload => |payload| {
                defer allocator.free(payload);
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
                    return .{ .failure = .{ .kind = .invalid_response } };
                };
                defer parsed.deinit();

                const message_type = valueString(objectField(parsed.value, "type")) orelse {
                    return .{ .failure = .{ .kind = .invalid_response } };
                };
                if (std.mem.eql(u8, message_type, "response")) {
                    const response_request_id = valueString(objectField(parsed.value, "requestId")) orelse "";
                    if (!std.mem.eql(u8, response_request_id, request_id)) continue;
                    return try extractPromptContext(allocator, parsed.value);
                }
                if (std.mem.eql(u8, message_type, "broadcast") or
                    std.mem.eql(u8, message_type, "client-discovery-response"))
                {
                    continue;
                }
                if (std.mem.eql(u8, message_type, "client-discovery-request")) {
                    try answerClientDiscovery(allocator, fd, parsed.value, deadline_ms);
                    continue;
                }
                if (std.mem.eql(u8, message_type, "request")) {
                    try answerUnsupportedRequest(allocator, fd, parsed.value, deadline_ms);
                    continue;
                }
                return .{ .failure = .{ .kind = .invalid_response } };
            },
        }
    }
}

fn readFrame(allocator: std.mem.Allocator, fd: std.posix.fd_t, deadline_ms: i64) !FrameOutcome {
    var len_bytes: [4]u8 = undefined;
    if (readExactBeforeDeadline(fd, &len_bytes, deadline_ms)) |failure| return .{ .failure = failure };
    const len = std.mem.readInt(u32, &len_bytes, .little);
    if (len > max_ipc_frame_bytes) return .{ .failure = .{ .kind = .response_too_large } };
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    if (readExactBeforeDeadline(fd, payload, deadline_ms)) |failure| {
        allocator.free(payload);
        return .{ .failure = failure };
    }
    return .{ .payload = payload };
}

fn readExactBeforeDeadline(fd: std.posix.fd_t, bytes: []u8, deadline_ms: i64) ?FetchFailure {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (waitForFd(fd, @intCast(std.posix.POLL.IN), deadline_ms, .read)) |failure| return failure;
        const read_len = std.posix.read(fd, bytes[offset..]) catch return .{ .kind = .read };
        if (read_len == 0) return .{ .kind = .read };
        offset += read_len;
    }
    return null;
}

fn waitForFd(fd: std.posix.fd_t, events: i16, deadline_ms: i64, failure_kind: FetchFailureKind) ?FetchFailure {
    while (true) {
        const remaining = deadline_ms - nowMs();
        if (remaining <= 0) return .{ .kind = failure_kind, .timed_out = failure_kind == .read };
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const timeout: i32 = @intCast(@min(remaining, std.math.maxInt(i32)));
        const ready = std.posix.poll(&fds, timeout) catch return .{ .kind = failure_kind };
        if (ready == 0) return .{ .kind = failure_kind, .timed_out = failure_kind == .read };
        if (fds[0].revents & @as(i16, @intCast(std.posix.POLL.NVAL)) != 0) return .{ .kind = failure_kind };
        if (fds[0].revents & (events | @as(i16, @intCast(std.posix.POLL.ERR | std.posix.POLL.HUP))) != 0) return null;
    }
}

fn nowMs() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn answerClientDiscovery(allocator: std.mem.Allocator, fd: std.posix.fd_t, message: std.json.Value, deadline_ms: i64) !void {
    const request_id = valueString(objectField(message, "requestId")) orelse return;
    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);
    try response.appendSlice(allocator, "{\"type\":\"client-discovery-response\",\"requestId\":");
    try appendJsonString(allocator, &response, request_id);
    try response.appendSlice(allocator, ",\"response\":{\"canHandle\":false}}");
    if (writeFrame(fd, response.items, deadline_ms)) |_| {}
}

fn answerUnsupportedRequest(allocator: std.mem.Allocator, fd: std.posix.fd_t, message: std.json.Value, deadline_ms: i64) !void {
    const request_id = valueString(objectField(message, "requestId")) orelse return;
    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);
    try response.appendSlice(allocator, "{\"type\":\"response\",\"requestId\":");
    try appendJsonString(allocator, &response, request_id);
    try response.appendSlice(allocator, ",\"resultType\":\"error\",\"error\":\"no-handler-for-request\"}");
    if (writeFrame(fd, response.items, deadline_ms)) |_| {}
}

fn extractPromptContext(allocator: std.mem.Allocator, response: std.json.Value) !FetchOutcome {
    const result_type = valueString(objectField(response, "resultType")) orelse {
        return .{ .failure = .{ .kind = .invalid_response } };
    };
    if (std.mem.eql(u8, result_type, "error")) {
        return .{ .failure = .{
            .kind = .request_failed,
            .request_error = mapRequestFailure(valueString(objectField(response, "error")) orelse ""),
        } };
    }
    if (!std.mem.eql(u8, result_type, "success")) {
        return .{ .failure = .{ .kind = .invalid_response } };
    }
    const result = objectField(response, "result") orelse return .{ .failure = .{ .kind = .invalid_response } };
    if (result != .object) return .{ .failure = .{ .kind = .invalid_response } };
    const context = objectField(result, "ideContext") orelse return .{ .failure = .{ .kind = .invalid_response } };
    if (context != .object) return .{ .failure = .{ .kind = .invalid_response } };
    const prompt_context = renderPromptContext(allocator, context) catch return .{ .failure = .{ .kind = .invalid_response } };
    return .{ .context = prompt_context };
}

fn mapRequestFailure(raw: []const u8) RequestFailureKind {
    if (std.mem.eql(u8, raw, "no-client-found")) return .no_client_found;
    if (std.mem.eql(u8, raw, "client-disconnected")) return .client_disconnected;
    if (std.mem.eql(u8, raw, "request-timeout")) return .request_timeout;
    if (std.mem.eql(u8, raw, "request-version-mismatch")) return .request_version_mismatch;
    if (std.mem.eql(u8, raw, "no-handler-for-request")) return .no_handler_for_request;
    return .unknown;
}

fn renderPromptContext(allocator: std.mem.Allocator, context: std.json.Value) !?[]const u8 {
    var section = std.ArrayList(u8).empty;
    errdefer section.deinit(allocator);

    if (objectField(context, "activeFile")) |active_file| {
        if (active_file != .null) {
            if (active_file != .object) return error.InvalidIdeContext;
            const path = valueString(objectField(active_file, "path")) orelse return error.InvalidIdeContext;
            try section.print(allocator, "\n## Active file: {s}\n", .{path});
            try appendSelectionRanges(allocator, &section, active_file, path);
            if (valueString(objectField(active_file, "activeSelectionContent"))) |selection| {
                if (selection.len > 0) {
                    try section.appendSlice(allocator, "\n## Active selection of the file:\n");
                    try appendSelectionContent(allocator, &section, selection);
                }
            }
        }
    }

    if (objectField(context, "openTabs")) |open_tabs| {
        if (open_tabs != .null) {
            if (open_tabs != .array) return error.InvalidIdeContext;
            if (open_tabs.array.items.len > 0) {
                try section.appendSlice(allocator, "\n## Open tabs:\n");
                var rendered_tabs: usize = 0;
                var rendered_tab_chars: usize = 0;
                for (open_tabs.array.items) |tab| {
                    if (rendered_tabs >= max_open_tabs) break;
                    if (tab != .object) return error.InvalidIdeContext;
                    const label = valueString(objectField(tab, "label")) orelse return error.InvalidIdeContext;
                    const path = valueString(objectField(tab, "path")) orelse return error.InvalidIdeContext;
                    const tab_line = try std.fmt.allocPrint(allocator, "- {s}: {s}\n", .{ label, path });
                    defer allocator.free(tab_line);
                    if (rendered_tab_chars + tab_line.len > max_open_tabs_chars) break;
                    try section.appendSlice(allocator, tab_line);
                    rendered_tabs += 1;
                    rendered_tab_chars += tab_line.len;
                }
                const omitted_tabs = open_tabs.array.items.len - rendered_tabs;
                if (omitted_tabs > 0) {
                    try section.print(allocator, "[{d} open tabs omitted.]\n", .{omitted_tabs});
                }
            }
        }
    }

    if (section.items.len == 0) {
        section.deinit(allocator);
        return null;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Context from my IDE setup:\n");
    try out.appendSlice(allocator, section.items);
    section.deinit(allocator);
    return @as(?[]const u8, try out.toOwnedSlice(allocator));
}

fn appendSelectionRanges(allocator: std.mem.Allocator, section: *std.ArrayList(u8), active_file: std.json.Value, path: []const u8) !void {
    const active_selection_content = valueString(objectField(active_file, "activeSelectionContent")) orelse "";
    var ranges = std.ArrayList(Range).empty;
    defer ranges.deinit(allocator);

    if (objectField(active_file, "selections")) |selections| {
        if (selections == .array and selections.array.items.len > 0) {
            for (selections.array.items) |range_value| {
                if (try parseNonEmptyRange(range_value)) |range| try ranges.append(allocator, range);
            }
        }
    }
    if (ranges.items.len == 0) {
        if (objectField(active_file, "selection")) |selection| {
            if (try parseNonEmptyRange(selection)) |range| try ranges.append(allocator, range);
        }
    }

    if (ranges.items.len == 0) return;
    if (active_selection_content.len > 0 and ranges.items.len == 1) return;

    if (ranges.items.len == 1) {
        try section.appendSlice(allocator, "\n## Active selection range:\n");
    } else {
        try section.appendSlice(allocator, "\n## Active selection ranges:\n");
    }
    for (ranges.items) |range| {
        try section.print(
            allocator,
            "- {s}: line {d}, column {d} to line {d}, column {d}\n",
            .{
                path,
                range.start.line + 1,
                range.start.character + 1,
                range.end.line + 1,
                range.end.character + 1,
            },
        );
    }
}

fn parseNonEmptyRange(value: std.json.Value) !?Range {
    if (value != .object) return error.InvalidIdeContext;
    const start = try parsePosition(objectField(value, "start") orelse return error.InvalidIdeContext);
    const end = try parsePosition(objectField(value, "end") orelse return error.InvalidIdeContext);
    if (start.line == end.line and start.character == end.character) return null;
    return .{ .start = start, .end = end };
}

fn parsePosition(value: std.json.Value) !Position {
    if (value != .object) return error.InvalidIdeContext;
    return .{
        .line = try parseUnsignedJson(objectField(value, "line") orelse return error.InvalidIdeContext),
        .character = try parseUnsignedJson(objectField(value, "character") orelse return error.InvalidIdeContext),
    };
}

fn parseUnsignedJson(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidIdeContext,
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidIdeContext,
        else => error.InvalidIdeContext,
    };
}

fn appendSelectionContent(allocator: std.mem.Allocator, section: *std.ArrayList(u8), selection: []const u8) !void {
    const view = std.unicode.Utf8View.init(selection) catch return error.InvalidIdeContext;
    var iterator = view.iterator();
    var count: usize = 0;
    while (count < max_active_selection_chars) : (count += 1) {
        if (iterator.nextCodepointSlice() == null) {
            try section.appendSlice(allocator, selection);
            return;
        }
    }
    const truncate_at = iterator.i;
    if (truncate_at >= selection.len) {
        try section.appendSlice(allocator, selection);
        return;
    }
    try section.appendSlice(allocator, selection[0..truncate_at]);
    try section.print(allocator, "\n[Selection truncated to {d} characters.]\n", .{max_active_selection_chars});
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn valueString(value_opt: ?std.json.Value) ?[]const u8 {
    const value = value_opt orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    try out.appendSlice(allocator, value_json);
}

test "renders prompt context in Rust IDE format" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{
        \\  "activeFile": {
        \\    "label": "lib.rs",
        \\    "path": "src/lib.rs",
        \\    "fsPath": "/repo/src/lib.rs",
        \\    "selection": {
        \\      "start": { "line": 4, "character": 0 },
        \\      "end": { "line": 6, "character": 1 }
        \\    },
        \\    "activeSelectionContent": "fn selected() {}",
        \\    "selections": []
        \\  },
        \\  "openTabs": [
        \\    { "label": "lib.rs", "path": "src/lib.rs" },
        \\    { "label": "main.rs", "path": "src/main.rs" }
        \\  ]
        \\}
    ,
        .{},
    );
    defer parsed.deinit();

    const rendered = (try renderPromptContext(allocator, parsed.value)).?;
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "# Context from my IDE setup:\n\n## Active file: src/lib.rs\n\n## Active selection of the file:\nfn selected() {}\n## Open tabs:\n- lib.rs: src/lib.rs\n- main.rs: src/main.rs\n",
        rendered,
    );
}

test "renders selection ranges without content" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{
        \\  "activeFile": {
        \\    "label": "lib.rs",
        \\    "path": "src/lib.rs",
        \\    "selection": {
        \\      "start": { "line": 0, "character": 2 },
        \\      "end": { "line": 2, "character": 4 }
        \\    },
        \\    "activeSelectionContent": "",
        \\    "selections": []
        \\  },
        \\  "openTabs": []
        \\}
    ,
        .{},
    );
    defer parsed.deinit();

    const rendered = (try renderPromptContext(allocator, parsed.value)).?;
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "## Active selection range:\n- src/lib.rs: line 1, column 3 to line 3, column 5\n") != null);
}

test "prefixes user request with desktop delimiter" {
    const allocator = std.testing.allocator;
    const prefixed = try prefixPrompt(allocator, "# Context from my IDE setup:\n\n## Active file: src/lib.rs\n", "explain it");
    defer allocator.free(prefixed);
    try std.testing.expectEqualStrings(
        "# Context from my IDE setup:\n\n## Active file: src/lib.rs\n\n## My request for Codex:\nexplain it",
        prefixed,
    );
}

test "closed socket write returns send failure without SIGPIPE" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var fds: [2]std.c.fd_t = undefined;
    if (socketpair(@intCast(std.c.AF.UNIX), @intCast(std.c.SOCK.STREAM), 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer _ = close(fds[0]);
    _ = close(fds[1]);

    const failure = writeAllBeforeDeadline(fds[0], "hello", nowMs() + std.time.ms_per_s) orelse {
        return error.ExpectedSendFailure;
    };
    try std.testing.expectEqual(FetchFailureKind.send, failure.kind);
}

extern fn socketpair(domain: c_uint, sock_type: c_uint, protocol: c_uint, sv: *[2]std.c.fd_t) c_int;
extern fn close(fd: std.c.fd_t) c_int;
