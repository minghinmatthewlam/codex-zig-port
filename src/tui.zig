const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const git_diff = @import("git_diff.zig");
const login = @import("login.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const review = @import("review.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const statusline = @import("statusline.zig");
const theme = @import("theme.zig");
const titleline = @import("titleline.zig");
const tools = @import("tools.zig");

const agents_filename = "AGENTS.md";
const mention_file_limit = 128 * 1024;
const terminal_title_limit = 240;
const default_status_line_ids = [_][]const u8{ "model-with-reasoning", "current-dir" };
const init_prompt =
    \\Create an AGENTS.md file for this repository.
    \\Make it a concise contributor guide with practical headings and repository-specific guidance.
    \\Include build, test, coding style, and workflow notes where they apply.
    \\Inspect the project files before writing, and do not overwrite an existing AGENTS.md.
;
const compact_prompt =
    \\Summarize this conversation so another coding agent can continue from the compacted context.
    \\Preserve the user's goal, decisions, constraints, files changed, commands run, verification results, unresolved risks, and exact next steps.
    \\Be concise but specific. Do not include generic advice.
;

pub const Options = struct {
    resume_target: ?[]const u8 = null,
    resume_picker: bool = false,
    resume_show_all: bool = false,
    fork_target: ?[]const u8 = null,
    fork_picker: bool = false,
    fork_show_all: bool = false,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
    initial_prompt: ?[]const u8 = null,
    initial_input_images: []const []const u8 = &.{},
    no_alt_screen: bool = false,
    remote: ?[]const u8 = null,
    remote_auth_token_env: ?[]const u8 = null,
    local_remote_control: bool = false,
    remote_control_bind: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator) !void {
    try runWithOptions(allocator, .{});
}

const RemoteScheme = enum {
    unix,
    ws,
    wss,
};

const RemoteUrlParts = struct {
    scheme: RemoteScheme,
    host: []const u8,
    path: []const u8 = "",
};

fn validateRemoteOptions(allocator: std.mem.Allocator, remote: ?[]const u8, remote_auth_token_env: ?[]const u8) !void {
    const remote_url = remote orelse {
        if (remote_auth_token_env != null) {
            std.debug.print("`--remote-auth-token-env` requires `--remote`.\n", .{});
            return error.RemoteAuthTokenEnvRequiresRemote;
        }
        return;
    };
    const parts = validateRemoteUrl(remote_url) catch |err| {
        std.debug.print("invalid remote address `{s}`; expected `unix://PATH`, `ws://host:port`, or `wss://host:port`\n", .{remote_url});
        return err;
    };
    if (remote_auth_token_env) |env_name| {
        if (!remoteUrlSupportsAuthToken(parts)) {
            std.debug.print("remote auth tokens require `wss://` or loopback `ws://` URLs; got `{s}`\n", .{remote_url});
            return error.RemoteAuthTokenTransportUnsupported;
        }
        const token = try getEnvVarOwned(allocator, env_name);
        defer if (token) |value| allocator.free(value);
        const value = token orelse {
            std.debug.print("environment variable `{s}` is not set\n", .{env_name});
            return error.RemoteAuthTokenEnvNotSet;
        };
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
            std.debug.print("environment variable `{s}` is empty\n", .{env_name});
            return error.RemoteAuthTokenEnvEmpty;
        }
    }
}

fn validateRemoteUrl(value: []const u8) !RemoteUrlParts {
    if (std.mem.startsWith(u8, value, "unix://")) {
        const path = value["unix://".len..];
        if (path.len == 0) return error.InvalidRemoteAddress;
        return .{ .scheme = .unix, .host = "", .path = path };
    }

    const scheme: RemoteScheme = if (std.mem.startsWith(u8, value, "ws://"))
        .ws
    else if (std.mem.startsWith(u8, value, "wss://"))
        .wss
    else
        return error.InvalidRemoteAddress;
    const rest = switch (scheme) {
        .ws => value["ws://".len..],
        .wss => value["wss://".len..],
        .unix => unreachable,
    };

    if (rest.len == 0) return error.InvalidRemoteAddress;
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return error.InvalidRemoteAddress;
    const slash_index = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = if (slash_index) |index| blk: {
        if (index != rest.len - 1) return error.InvalidRemoteAddress;
        break :blk rest[0..index];
    } else rest;
    if (host_port.len == 0) return error.InvalidRemoteAddress;

    const host: []const u8 = if (host_port[0] == '[') blk: {
        const close_index = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidRemoteAddress;
        if (close_index + 1 >= host_port.len or host_port[close_index + 1] != ':') return error.InvalidRemoteAddress;
        break :blk host_port[0 .. close_index + 1];
    } else blk: {
        const colon_index = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidRemoteAddress;
        break :blk host_port[0..colon_index];
    };
    const port_text: []const u8 = if (host_port[0] == '[') blk: {
        const close_index = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidRemoteAddress;
        break :blk host_port[close_index + 2 ..];
    } else blk: {
        const colon_index = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidRemoteAddress;
        break :blk host_port[colon_index + 1 ..];
    };
    if (host.len == 0 or port_text.len == 0) return error.InvalidRemoteAddress;
    _ = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidRemoteAddress;
    return .{ .scheme = scheme, .host = host };
}

fn remoteUrlSupportsAuthToken(parts: RemoteUrlParts) bool {
    if (parts.scheme == .wss) return true;
    if (parts.scheme != .ws) return false;
    return std.ascii.eqlIgnoreCase(parts.host, "localhost") or
        std.mem.startsWith(u8, parts.host, "127.") or
        std.mem.eql(u8, parts.host, "[::1]");
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return null;
    const copy: []const u8 = try allocator.dupe(u8, std.mem.span(value));
    return copy;
}

fn checkLocalRemoteControlOptions(enabled: bool, bind: ?[]const u8) !void {
    if (bind != null and !enabled) {
        return error.RemoteControlBindRequiresRemoteControl;
    }
}

test "local remote-control bind requires flag" {
    try checkLocalRemoteControlOptions(true, "127.0.0.1:0");
    try checkLocalRemoteControlOptions(false, null);
    try std.testing.expectError(
        error.RemoteControlBindRequiresRemoteControl,
        checkLocalRemoteControlOptions(false, "127.0.0.1:0"),
    );
}

fn validateLocalRemoteControlOptions(enabled: bool, bind: ?[]const u8) !void {
    checkLocalRemoteControlOptions(enabled, bind) catch |err| {
        if (err == error.RemoteControlBindRequiresRemoteControl) {
            std.debug.print("`--remote-control-bind` requires `--remote-control`.\n", .{});
        }
        return err;
    };
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    try validateRemoteOptions(allocator, options.remote, options.remote_auth_token_env);
    if (options.remote) |remote| {
        return runRemoteTui(allocator, options, remote);
    }
    try validateLocalRemoteControlOptions(options.local_remote_control, options.remote_control_bind);
    if (options.local_remote_control) {
        if (options.remote_control_bind) |bind| {
            std.debug.print("local remote control is parsed but not implemented yet: {s}\n", .{bind});
        } else {
            std.debug.print("local remote control is parsed but not implemented yet\n", .{});
        }
        return error.LocalRemoteControlNotImplemented;
    }

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (options.oss) {
        try config.applyOssMode(&cfg, allocator, options.oss_provider, options.runtime_overrides.model != null);
    }

    var credentials = if (options.oss)
        try auth.localOssCredentials(allocator)
    else
        try auth.loadForConfig(allocator, &cfg);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var resumed = false;
    var forked_from_path: ?[]const u8 = null;
    defer if (forked_from_path) |path| allocator.free(path);

    const source_fork_path = if (options.fork_picker) blk: {
        const picked_path = try promptSessionPicker(allocator, cfg.codex_home, "fork", options.fork_show_all);
        if (picked_path == null) {
            std.debug.print("fork canceled\n", .{});
            return;
        }
        break :blk picked_path.?;
    } else if (options.fork_target) |target|
        try session_store.resolveResumePath(allocator, cfg.codex_home, target)
    else
        null;

    var session_path = if (source_fork_path) |path| blk: {
        forked_from_path = path;
        var loaded = try session_store.loadTranscript(allocator, path);
        errdefer loaded.deinit(allocator);
        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        errdefer allocator.free(next_path);
        try session_store.saveTranscript(allocator, next_path, &loaded);
        transcript.deinit(allocator);
        transcript = loaded;
        break :blk next_path;
    } else if (options.resume_picker) blk: {
        const picked_path = try promptSessionPicker(allocator, cfg.codex_home, "resume", options.resume_show_all);
        if (picked_path == null) {
            std.debug.print("resume canceled\n", .{});
            return;
        }
        resumed = true;
        break :blk picked_path.?;
    } else if (options.resume_target) |target| blk: {
        resumed = true;
        break :blk try session_store.resolveResumePath(allocator, cfg.codex_home, target);
    } else try session_store.createSessionPath(allocator, cfg.codex_home);
    defer allocator.free(session_path);

    if (resumed) {
        const loaded = try session_store.loadTranscript(allocator, session_path);
        transcript.deinit(allocator);
        transcript = loaded;
    }

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    const use_alt_screen = shouldUseAlternateScreen(options.no_alt_screen, cfg.tui_alternate_screen);
    if (use_alt_screen) enterAlternateScreen();
    defer if (use_alt_screen) leaveAlternateScreen();

    printHeader(cfg, credentials, cwd);
    if (resumed) {
        std.debug.print("resumed: {s} ({d} items)\n", .{ session_path, transcript.history.items.len });
    }
    if (forked_from_path) |path| {
        std.debug.print("forked: {s} -> {s} ({d} items)\n", .{ path, session_path, transcript.history.items.len });
    }

    var state = TuiState{};
    defer state.deinit(allocator);
    state.syntax_theme = try theme.initialTheme(allocator, cfg.syntax_theme);
    if (cfg.tui_status_line) |ids| {
        try applyConfiguredStatusLine(allocator, &state, ids.items);
    }
    if (cfg.tui_terminal_title) |ids| {
        try applyConfiguredTerminalTitle(allocator, &state, ids.items);
    } else {
        try state.replaceTerminalTitleItems(allocator, &titleline.default_items);
    }
    try refreshTerminalTitle(allocator, cfg, cwd, &transcript, session_path, &state);

    var pending_input_images: []const []const u8 = options.initial_input_images;
    if (options.initial_prompt) |initial_prompt| {
        const prompt = std.mem.trim(u8, initial_prompt, " \t\r\n");
        if (prompt.len > 0) {
            runPrompt(allocator, cfg, &credentials, &transcript, session_path, prompt, options.additional_writable_roots, pending_input_images) catch |err| {
                std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            };
            pending_input_images = &.{};
        }
    }

    var input_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

    while (true) {
        std.debug.print("\n› ", .{});
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        const prompt = std.mem.trim(u8, line, " \t\r\n");
        if (prompt.len == 0) continue;
        if (std.mem.eql(u8, prompt, "q")) break;
        if (parseBangShellCommand(prompt)) |command| {
            runUserShellCommand(allocator, cfg, command, options.additional_writable_roots) catch |err| {
                std.debug.print("shell error: {s}\n", .{@errorName(err)});
            };
            continue;
        }
        const slash_action = handleSlashCommand(allocator, &cfg, &credentials, &transcript, &session_path, cwd, prompt, &state, options.additional_writable_roots) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (slash_action) |action| {
            switch (action) {
                .handled => continue,
                .quit => break,
            }
        }

        const input_images = pending_input_images;
        pending_input_images = &.{};
        runUserPrompt(allocator, cfg, &credentials, &transcript, session_path, prompt, options.additional_writable_roots, &state, input_images) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
    }

    if (state.terminal_title_items.items.len > 0) clearTerminalTitle();
    std.debug.print("\nbye\n", .{});
}

fn runRemoteTui(allocator: std.mem.Allocator, options: Options, remote: []const u8) !void {
    if (options.local_remote_control or options.remote_control_bind != null) {
        std.debug.print("`--remote-control` cannot be combined with `--remote`.\n", .{});
        return error.RemoteControlCannotCombineWithRemote;
    }
    if (options.resume_target != null or options.resume_picker or options.fork_target != null or options.fork_picker) {
        std.debug.print("remote app-server TUI is parsed but not implemented yet for resume/fork\n", .{});
        return error.RemoteAppServerSessionTuiNotImplemented;
    }

    const parts = try validateRemoteUrl(remote);
    if (parts.scheme != .unix) {
        std.debug.print("remote app-server TUI is parsed but not implemented yet for websocket transport: {s}\n", .{remote});
        return error.RemoteAppServerTuiNotImplemented;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try net.UnixAddress.init(parts.path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &input_buffer);
    var writer = stream.writer(io, &output_buffer);

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);

    const use_alt_screen = shouldUseAlternateScreen(options.no_alt_screen, .auto);
    if (use_alt_screen) enterAlternateScreen();
    defer if (use_alt_screen) leaveAlternateScreen();

    printRemoteHeader(remote, cwd);

    try writeRemoteLine(&writer.interface,
        \\{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"clientInfo":{"name":"codex-zig-tui","version":"0.0.1"},"capabilities":{}}}
    );
    var initialize_response = try readRemoteResponse(allocator, &reader.interface, "initialize");
    initialize_response.deinit();

    const thread_start = try renderRemoteThreadStartRequest(allocator, cwd, options.runtime_overrides);
    defer allocator.free(thread_start);
    try writeRemoteLine(&writer.interface, thread_start);
    var thread_response = try readRemoteResponse(allocator, &reader.interface, "thread-start");
    const thread_id_raw = try remoteNestedString(thread_response.value, &.{ "result", "thread", "id" });
    const thread_id = try allocator.dupe(u8, thread_id_raw);
    thread_response.deinit();
    defer allocator.free(thread_id);

    var pending_input_images: []const []const u8 = options.initial_input_images;
    if (options.initial_prompt) |initial_prompt| {
        const prompt = std.mem.trim(u8, initial_prompt, " \t\r\n");
        if (prompt.len > 0) {
            try runRemotePrompt(allocator, &writer.interface, &reader.interface, thread_id, prompt, pending_input_images);
            pending_input_images = &.{};
        }
    }

    var stdin_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    while (true) {
        std.debug.print("\n› ", .{});
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        const prompt = std.mem.trim(u8, line, " \t\r\n");
        if (prompt.len == 0) continue;
        if (std.mem.eql(u8, prompt, "q") or std.mem.eql(u8, prompt, "/quit")) break;
        if (std.mem.eql(u8, prompt, "/help")) {
            std.debug.print("commands:\n  /help\n  /quit\n", .{});
            continue;
        }
        if (std.mem.startsWith(u8, prompt, "/")) {
            std.debug.print("remote TUI slash command is parsed but not implemented yet: {s}\n", .{prompt});
            continue;
        }
        const input_images = pending_input_images;
        pending_input_images = &.{};
        runRemotePrompt(allocator, &writer.interface, &reader.interface, thread_id, prompt, input_images) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
    }

    std.debug.print("\nbye\n", .{});
}

fn printRemoteHeader(remote: []const u8, cwd: []const u8) void {
    std.debug.print(
        \\╭────────────────────────────────────────────╮
        \\│ Codex Zig Remote                           │
        \\╰────────────────────────────────────────────╯
        \\remote: {s}
        \\cwd:    {s}
        \\Type /help for commands or /quit to exit.
        \\
    , .{ remote, cwd });
}

fn renderRemoteThreadStartRequest(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    overrides: config.RuntimeOverrides,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"thread-start\",\"method\":\"thread/start\",\"params\":{");
    var first = true;
    try appendJsonStringField(allocator, &out, &first, "cwd", cwd);
    if (overrides.model) |model| try appendJsonStringField(allocator, &out, &first, "model", model);
    if (overrides.approval_policy) |policy| try appendJsonStringField(allocator, &out, &first, "approvalPolicy", policy.label());
    if (overrides.sandbox_mode) |sandbox| try appendJsonStringField(allocator, &out, &first, "sandbox", sandbox.label());
    if (overrides.service_tier) |service_tier| try appendJsonStringField(allocator, &out, &first, "serviceTier", service_tier);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn runRemotePrompt(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    thread_id: []const u8,
    prompt: []const u8,
    input_images: []const []const u8,
) !void {
    const request = try renderRemoteTurnStartRequest(allocator, thread_id, prompt, input_images);
    defer allocator.free(request);

    std.debug.print("\nassistant:\n", .{});
    try writeRemoteLine(writer, request);

    var response = try readRemoteResponse(allocator, reader, "turn-start");
    const turn_id_raw = try remoteNestedString(response.value, &.{ "result", "turn", "id" });
    const turn_id = try allocator.dupe(u8, turn_id_raw);
    response.deinit();
    defer allocator.free(turn_id);

    try streamRemoteTurnUntilCompleted(allocator, reader, thread_id, turn_id);
}

fn renderRemoteTurnStartRequest(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    prompt: []const u8,
    input_images: []const []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"turn-start\",\"method\":\"turn/start\",\"params\":{\"threadId\":");
    try appendJsonString(allocator, &out, thread_id);
    try out.appendSlice(allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
    try appendJsonString(allocator, &out, prompt);
    try out.appendSlice(allocator, "}");
    for (input_images) |image| {
        try out.appendSlice(allocator, ",{\"type\":\"image\",\"url\":");
        try appendJsonString(allocator, &out, image);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
}

fn writeRemoteLine(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeAll(payload);
    try writer.writeByte('\n');
    try writer.flush();
}

fn readRemoteResponse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    request_id: []const u8,
) !std.json.Parsed(std.json.Value) {
    var lines_read: usize = 0;
    while (lines_read < 512) : (lines_read += 1) {
        const line = try readRemoteLine(reader) orelse return error.RemoteAppServerClosed;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
        if (parsed.value != .object) {
            parsed.deinit();
            continue;
        }
        const object = parsed.value.object;
        if (object.get("id")) |id_value| {
            if (jsonValueStringEquals(id_value, request_id)) {
                if (remoteErrorMessage(object)) |message| {
                    std.debug.print("remote app-server error: {s}\n", .{message});
                    parsed.deinit();
                    return error.RemoteAppServerRequestFailed;
                }
                return parsed;
            }
        }
        parsed.deinit();
    }
    return error.RemoteAppServerResponseNotFound;
}

fn streamRemoteTurnUntilCompleted(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    thread_id: []const u8,
    turn_id: []const u8,
) !void {
    var saw_delta = false;
    var lines_read: usize = 0;
    while (lines_read < 1024) : (lines_read += 1) {
        const line = try readRemoteLine(reader) orelse return error.RemoteAppServerClosed;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        if (remoteErrorMessage(object)) |message| {
            std.debug.print("remote app-server error: {s}\n", .{message});
            return error.RemoteAppServerRequestFailed;
        }
        const method = object.get("method") orelse continue;
        if (method != .string) continue;
        if (!remoteTurnNotificationMatches(object, thread_id, turn_id)) continue;

        if (std.mem.eql(u8, method.string, "item/agentMessage/delta")) {
            if (remoteNotificationDelta(object)) |delta| {
                saw_delta = true;
                std.debug.print("{s}", .{delta});
            }
            continue;
        }
        if (std.mem.eql(u8, method.string, "turn/completed")) {
            if (!saw_delta) std.debug.print("(no assistant output)", .{});
            std.debug.print("\n", .{});
            return;
        }
    }
    return error.RemoteAppServerTurnIncomplete;
}

fn readRemoteLine(reader: *std.Io.Reader) !?[]const u8 {
    const line_opt = try reader.takeDelimiter('\n');
    const line = line_opt orelse return null;
    return std.mem.trim(u8, line, " \t\r\n");
}

fn remoteNestedString(value: std.json.Value, path: []const []const u8) ![]const u8 {
    var current = value;
    for (path) |part| {
        if (current != .object) return error.InvalidRemoteAppServerResponse;
        current = current.object.get(part) orelse return error.InvalidRemoteAppServerResponse;
    }
    if (current != .string) return error.InvalidRemoteAppServerResponse;
    return current.string;
}

fn remoteErrorMessage(object: std.json.ObjectMap) ?[]const u8 {
    const error_value = object.get("error") orelse return null;
    if (error_value != .object) return "unknown error";
    const message = error_value.object.get("message") orelse return "unknown error";
    if (message != .string) return "unknown error";
    return message.string;
}

fn remoteTurnNotificationMatches(object: std.json.ObjectMap, thread_id: []const u8, turn_id: []const u8) bool {
    const params = object.get("params") orelse return false;
    if (params != .object) return false;
    const notification_thread_id = params.object.get("threadId") orelse return false;
    if (!jsonValueStringEquals(notification_thread_id, thread_id)) return false;
    if (params.object.get("turnId")) |notification_turn_id| {
        if (jsonValueStringEquals(notification_turn_id, turn_id)) return true;
    }
    const turn = params.object.get("turn") orelse return false;
    if (turn != .object) return false;
    const nested_turn_id = turn.object.get("id") orelse return false;
    return jsonValueStringEquals(nested_turn_id, turn_id);
}

fn remoteNotificationDelta(object: std.json.ObjectMap) ?[]const u8 {
    const params = object.get("params") orelse return null;
    if (params != .object) return null;
    const delta = params.object.get("delta") orelse return null;
    if (delta != .string) return null;
    return delta.string;
}

fn jsonValueStringEquals(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn appendJsonStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":");
    try appendJsonString(allocator, out, value);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    try out.appendSlice(allocator, value_json);
}

fn enterAlternateScreen() void {
    std.debug.print("\x1b[?1049h", .{});
}

fn leaveAlternateScreen() void {
    std.debug.print("\x1b[?1049l", .{});
}

fn shouldUseAlternateScreen(no_alt_screen: bool, mode: config.AltScreenMode) bool {
    if (no_alt_screen) return false;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!(std.Io.File.stdout().isTty(io) catch false)) return false;
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => !isZellij(),
    };
}

fn isZellij() bool {
    return std.c.getenv("ZELLIJ") != null or std.c.getenv("ZELLIJ_SESSION_NAME") != null;
}

fn runPrompt(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    prompt: []const u8,
    additional_writable_roots: []const []const u8,
    input_images: []const []const u8,
) !void {
    try runPromptWithToolMode(allocator, cfg, credentials, transcript, session_path, prompt, additional_writable_roots, true, false, input_images);
}

fn runPromptWithToolMode(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    prompt: []const u8,
    additional_writable_roots: []const []const u8,
    include_tools: bool,
    render_plan_blocks: bool,
    input_images: []const []const u8,
) !void {
    std.debug.print("\nassistant:\n", .{});
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, transcript, prompt, .{
        .stream_text = true,
        .additional_writable_roots = additional_writable_roots,
        .include_tools = include_tools,
        .plan_mode = render_plan_blocks,
        .input_images = input_images,
    });
    defer allocator.free(answer);
    if (render_plan_blocks and answer.len > 0) {
        std.debug.print("{s}", .{answer});
    }
    session_store.saveTranscript(allocator, session_path, transcript) catch |err| {
        std.debug.print("warning: could not save session: {s}\n", .{@errorName(err)});
    };
    if (answer.len == 0 or answer[answer.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn runUserPrompt(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    prompt: []const u8,
    additional_writable_roots: []const []const u8,
    state: *TuiState,
    input_images: []const []const u8,
) !void {
    var expanded_prompt: ?[]const u8 = null;
    defer if (expanded_prompt) |value| allocator.free(value);

    const prompt_for_model = if (state.mentions.items.len == 0)
        prompt
    else blk: {
        const value = try buildPromptWithMentions(allocator, prompt, state.mentions.items);
        expanded_prompt = value;
        break :blk value;
    };

    try runPromptWithToolMode(allocator, cfg, credentials, transcript, session_path, prompt_for_model, additional_writable_roots, !state.plan_mode, state.plan_mode, input_images);
    state.clearMentions(allocator);
}

fn runSidePrompt(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *const session.Transcript,
    prompt: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("usage: /side <prompt>\n", .{});
        return;
    }

    var side_transcript = try transcript.clone(allocator);
    defer side_transcript.deinit(allocator);

    std.debug.print("\nside conversation:\n", .{});
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, &side_transcript, trimmed, .{
        .stream_text = true,
        .additional_writable_roots = additional_writable_roots,
    });
    defer allocator.free(answer);
    if (answer.len == 0 or answer[answer.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn buildPromptWithMentions(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    mention_paths: []const []const u8,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, prompt);
    try output.appendSlice(allocator, "\n\nMentioned files:\n");

    for (mention_paths) |path| {
        const content = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            allocator,
            .limited(mention_file_limit),
        ) catch |err| switch (err) {
            error.FileTooBig => {
                try output.appendSlice(allocator, "\n--- ");
                try output.appendSlice(allocator, path);
                try output.appendSlice(allocator, " ---\n");
                try output.print(allocator, "[file omitted: larger than {d} bytes]\n", .{mention_file_limit});
                continue;
            },
            else => return err,
        };
        defer allocator.free(content);

        try output.appendSlice(allocator, "\n--- ");
        try output.appendSlice(allocator, path);
        try output.appendSlice(allocator, " ---\n");
        try output.appendSlice(allocator, content);
        if (content.len == 0 or content[content.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }
    }

    return output.toOwnedSlice(allocator);
}

fn printHeader(cfg: config.Config, credentials: auth.Credentials, cwd: []const u8) void {
    std.debug.print(
        \\╭────────────────────────────────────────────╮
        \\│ Codex Zig                                  │
        \\╰────────────────────────────────────────────╯
        \\model: {s}
        \\auth: {s}
        \\api:  {s}
        \\cwd:  {s}
        \\approval: {s}
        \\sandbox:  {s}
        \\search:   {s}
        \\Type /help for commands or /quit to exit.
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt, .chatgpt_auth_tokens, .agent_identity => cfg.chatgpt_base_url,
            .api_key, .local_oss => cfg.openai_base_url,
        },
        cwd,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
    });
}

fn promptSessionPicker(allocator: std.mem.Allocator, codex_home: []const u8, action: []const u8, show_all: bool) !?[]const u8 {
    const limit: usize = if (show_all) 0 else 10;
    const sessions = try session_store.listSessions(allocator, codex_home, limit);
    defer session_store.freeSessionSummaries(allocator, sessions);

    if (sessions.len == 0) {
        std.debug.print("{s}: no saved Zig sessions\n", .{action});
        return null;
    }

    std.debug.print("{s} sessions:\n", .{action});
    for (sessions, 0..) |entry, index| {
        session_store.printSessionSummary(index, entry);
    }
    std.debug.print("Select session [1-{d}] or press Enter to cancel: ", .{sessions.len});

    var input_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);
    const line_opt = try stdin_reader.interface.takeDelimiter('\n');
    const line = line_opt orelse return null;
    const selection = try parseResumeSelection(line, sessions.len) orelse return null;
    const path = try allocator.dupe(u8, sessions[selection].path);
    return path;
}

fn parseResumeSelection(input: []const u8, count: usize) !?usize {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const selected = try std.fmt.parseUnsigned(usize, trimmed, 10);
    if (selected == 0 or selected > count) return error.InvalidResumeSelection;
    return selected - 1;
}

const SlashAction = enum {
    handled,
    quit,
};

const SlashParts = struct {
    name: []const u8,
    args: []const u8,
};

const TuiState = struct {
    raw_output_mode: bool = false,
    vim_mode: bool = false,
    plan_mode: bool = false,
    terminal_title_items: std.ArrayList(titleline.Item) = .empty,
    status_line_items: std.ArrayList(statusline.Item) = .empty,
    syntax_theme: ?[]const u8 = null,
    mentions: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *TuiState, allocator: std.mem.Allocator) void {
        if (self.syntax_theme) |value| allocator.free(value);
        self.clearMentions(allocator);
        self.mentions.deinit(allocator);
        self.terminal_title_items.deinit(allocator);
        self.status_line_items.deinit(allocator);
    }

    fn addMention(self: *TuiState, allocator: std.mem.Allocator, path: []const u8) !void {
        const copy = try allocator.dupe(u8, path);
        errdefer allocator.free(copy);
        try self.mentions.append(allocator, copy);
    }

    fn clearMentions(self: *TuiState, allocator: std.mem.Allocator) void {
        for (self.mentions.items) |path| allocator.free(path);
        self.mentions.clearRetainingCapacity();
    }

    fn replaceStatusLineItems(self: *TuiState, allocator: std.mem.Allocator, items: []const statusline.Item) !void {
        self.status_line_items.clearRetainingCapacity();
        try self.status_line_items.appendSlice(allocator, items);
    }

    fn replaceTerminalTitleItems(self: *TuiState, allocator: std.mem.Allocator, items: []const titleline.Item) !void {
        self.terminal_title_items.clearRetainingCapacity();
        try self.terminal_title_items.appendSlice(allocator, items);
    }

    fn clearStatusLine(self: *TuiState) void {
        self.status_line_items.clearRetainingCapacity();
    }

    fn clearTerminalTitle(self: *TuiState) void {
        self.terminal_title_items.clearRetainingCapacity();
    }

    fn setSyntaxTheme(self: *TuiState, allocator: std.mem.Allocator, name: []const u8) !void {
        const next = try allocator.dupe(u8, name);
        if (self.syntax_theme) |existing| allocator.free(existing);
        self.syntax_theme = next;
    }

    fn syntaxThemeName(self: TuiState) []const u8 {
        return self.syntax_theme orelse theme.default_theme;
    }
};

fn handleSlashCommand(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: *[]const u8,
    cwd: []const u8,
    prompt: []const u8,
    state: *TuiState,
    additional_writable_roots: []const []const u8,
) !?SlashAction {
    const parts = parseSlash(prompt) orelse return null;

    if (std.ascii.eqlIgnoreCase(parts.name, "quit") or
        std.ascii.eqlIgnoreCase(parts.name, "exit") or
        std.mem.eql(u8, parts.name, "q"))
    {
        return .quit;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "help")) {
        printSlashHelp();
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "init")) {
        if (try agentsFileExists(allocator, cwd)) {
            std.debug.print("{s} already exists here. Skipping /init to avoid overwriting it.\n", .{agents_filename});
            return .handled;
        }
        try runPrompt(allocator, cfg.*, credentials, transcript, session_path.*, init_prompt, additional_writable_roots, &.{});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "compact")) {
        try runCompact(allocator, cfg.*, credentials, transcript, session_path.*, additional_writable_roots);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "status")) {
        try printStatus(allocator, cfg.*, credentials.*, transcript, session_path.*, cwd, state.*);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "debug-config")) {
        try printDebugConfig(allocator, cfg.*, credentials.*);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "keymap")) {
        printKeymap(parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "plan")) {
        handlePlanMode(&state.plan_mode, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "title")) {
        try handleTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "statusline")) {
        try handleStatusLine(allocator, cfg.*, transcript, session_path.*, cwd, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "theme")) {
        try handleTheme(allocator, cfg, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "personality")) {
        try handlePersonality(allocator, cfg, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "rename")) {
        if (try renameThread(allocator, transcript, session_path.*, parts.args)) {
            try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state);
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "history")) {
        printHistory(transcript, try parseHistoryLimit(parts.args));
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "mention")) {
        try mentionFile(allocator, cwd, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "side")) {
        try runSidePrompt(allocator, cfg.*, credentials, transcript, parts.args, additional_writable_roots);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "rollout")) {
        std.debug.print("rollout: {s}\n", .{session_path.*});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sessions")) {
        try session_store.printSessionList(allocator, cfg.codex_home, try parseSessionListLimit(parts.args));
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "diff")) {
        try printDiff(allocator, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "copy")) {
        copyLastAssistantMessage(allocator, transcript);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "raw")) {
        handleRawOutputMode(&state.raw_output_mode, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "vim")) {
        state.vim_mode = !state.vim_mode;
        std.debug.print("vim mode: {s}\n", .{if (state.vim_mode) "on" else "off"});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "mcp")) {
        try printMcpStatus(allocator, cfg.codex_home, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "ps")) {
        try printBackgroundTerminals(allocator);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "stop") or std.ascii.eqlIgnoreCase(parts.name, "clean")) {
        const stopped = tools.stopAllExecSessions();
        std.debug.print("stopped {d} background terminal(s)\n", .{stopped});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "logout")) {
        try login.runLogout(allocator);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "review")) {
        const review_prompt = if (parts.args.len == 0)
            try review.buildUncommittedPrompt(allocator)
        else
            try review.buildCustomPrompt(allocator, parts.args);
        defer allocator.free(review_prompt);
        try runPrompt(allocator, cfg.*, credentials, transcript, session_path.*, review_prompt, additional_writable_roots, &.{});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "clear") or std.ascii.eqlIgnoreCase(parts.name, "new")) {
        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        transcript.deinit(allocator);
        transcript.* = .{};
        state.clearMentions(allocator);
        const previous_path = session_path.*;
        session_path.* = next_path;
        allocator.free(previous_path);
        try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state);
        if (std.ascii.eqlIgnoreCase(parts.name, "clear")) {
            std.debug.print("\x1b[2J\x1b[H", .{});
            printHeader(cfg.*, credentials.*, cwd);
        } else {
            std.debug.print("started a new chat\n", .{});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "resume")) {
        const target = if (parts.args.len == 0) null else parts.args;
        const next_path = try session_store.resolveResumePath(allocator, cfg.codex_home, target);
        errdefer allocator.free(next_path);
        var loaded = try session_store.loadTranscript(allocator, next_path);
        errdefer loaded.deinit(allocator);

        transcript.deinit(allocator);
        transcript.* = loaded;
        state.clearMentions(allocator);
        try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, next_path, state);
        allocator.free(session_path.*);
        session_path.* = next_path;
        std.debug.print("resumed: {s} ({d} items)\n", .{ session_path.*, transcript.history.items.len });
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "fork")) {
        const source_path = if (parts.args.len == 0)
            try allocator.dupe(u8, session_path.*)
        else
            try session_store.resolveResumePath(allocator, cfg.codex_home, parts.args);
        defer allocator.free(source_path);

        if (parts.args.len > 0) {
            var loaded = try session_store.loadTranscript(allocator, source_path);
            errdefer loaded.deinit(allocator);
            transcript.deinit(allocator);
            transcript.* = loaded;
        }
        state.clearMentions(allocator);

        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        errdefer allocator.free(next_path);
        try session_store.saveTranscript(allocator, next_path, transcript);
        const previous_path = session_path.*;
        session_path.* = next_path;
        allocator.free(previous_path);
        try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state);
        std.debug.print("forked: {s} -> {s} ({d} items)\n", .{ source_path, session_path.*, transcript.history.items.len });
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "model")) {
        if (parts.args.len == 0) {
            std.debug.print("model: {s}\n", .{cfg.model});
        } else {
            const next_model = try allocator.dupe(u8, parts.args);
            allocator.free(cfg.model);
            cfg.model = next_model;
            std.debug.print("model: {s}\n", .{cfg.model});
            try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state);
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "fast")) {
        try handleFastMode(allocator, cfg, parts.args);
        try refreshTerminalTitle(allocator, cfg.*, cwd, transcript, session_path.*, state);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "approval")) {
        if (parts.args.len == 0) {
            std.debug.print("approval: {s}\n", .{cfg.approval_policy.label()});
        } else {
            cfg.approval_policy = try config.ApprovalPolicy.parse(parts.args);
            std.debug.print("approval: {s}\n", .{cfg.approval_policy.label()});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sandbox")) {
        if (parts.args.len == 0) {
            std.debug.print("sandbox: {s}\n", .{cfg.sandbox_mode.label()});
        } else {
            cfg.sandbox_mode = try config.SandboxMode.parse(parts.args);
            std.debug.print("sandbox: {s}\n", .{cfg.sandbox_mode.label()});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "permissions")) {
        try handlePermissions(cfg, parts.args);
        return .handled;
    }

    std.debug.print("unknown slash command: /{s} (try /help)\n", .{parts.name});
    return .handled;
}

fn parseSlash(prompt: []const u8) ?SlashParts {
    if (prompt.len < 2 or prompt[0] != '/') return null;
    const body = std.mem.trim(u8, prompt[1..], " \t");
    if (body.len == 0) return .{ .name = "", .args = "" };
    const split = std.mem.indexOfAny(u8, body, " \t") orelse return .{ .name = body, .args = "" };
    const name = body[0..split];
    const args = std.mem.trim(u8, body[split + 1 ..], " \t");
    return .{ .name = name, .args = args };
}

fn printSlashHelp() void {
    std.debug.print(
        \\commands:
        \\  /help             show this help
        \\  /init             create an AGENTS.md contributor guide
        \\  /compact          summarize and replace this session's history
        \\  /status           show current session settings
        \\  /debug-config     show effective configuration values
        \\  /keymap [debug]   show current key bindings
        \\  /plan [on|off|status]
        \\                    toggle plan-only mode for normal prompts
        \\  /title [status|off|default|ITEM...]
        \\                    manage the terminal window title
        \\  /statusline [status|off|default|ITEM...]
        \\                    configure status line preview items
        \\  /theme [status|list|NAME]
        \\                    choose a syntax highlighting theme
        \\  /personality [status|list|none|friendly|pragmatic]
        \\                    choose a communication style
        \\  /rename <title>   set this session's persisted title
        \\  /model [name]     show or set the in-memory model for this session
        \\  /fast [on|off|status]
        \\                    toggle Fast service tier for this session
        \\  /permissions      show or set approval/sandbox modes
        \\  /approval [mode]  show or set approval policy
        \\  /sandbox [mode]   show or set sandbox mode
        \\  /history [n]      show recent transcript items
        \\  /mention <path>   include a file in the next message
        \\  /side <prompt>    ask in an ephemeral fork
        \\  /rollout          show the active session JSONL path
        \\  /sessions [n]     list saved Zig sessions
        \\  /diff             show git status and diff, including untracked files
        \\  /copy             copy the last assistant response
        \\  /raw [on|off]     toggle copy-friendly transcript output
        \\  /vim              toggle Vim composer mode
        \\  /mcp [verbose]    list configured MCP servers
        \\  /ps               list background terminals
        \\  /stop, /clean     stop all background terminals
        \\  /logout           remove local Codex auth
        \\  /review [text]    review current changes or custom instructions
        \\  /clear            clear transcript and redraw the header
        \\  /new              start a new transcript
        \\  /resume [target]  resume last, a session id, or a JSONL path
        \\  /fork [target]    fork current, last, a session id, or a JSONL path
        \\  /quit, /exit      exit
        \\  !COMMAND          run a local shell command without sending to the model
        \\
    , .{});
}

fn agentsFileExists(allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ cwd, agents_filename });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn runCompact(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    const previous_items = transcript.history.items.len;
    if (previous_items == 0) {
        std.debug.print("nothing to compact yet\n", .{});
        return;
    }

    std.debug.print("\ncompact:\n", .{});
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, transcript, compact_prompt, .{
        .stream_text = true,
        .additional_writable_roots = additional_writable_roots,
        .include_tools = false,
    });
    defer allocator.free(answer);

    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCompactionSummary;

    const compacted = try std.fmt.allocPrint(
        allocator,
        "Compacted conversation summary:\n\n{s}",
        .{trimmed},
    );
    defer allocator.free(compacted);

    try transcript.replaceWithCompactedSummary(allocator, compacted);
    try session_store.saveTranscript(allocator, session_path, transcript);
    std.debug.print("\ncompacted: {d} -> {d} item\n", .{ previous_items, transcript.history.items.len });
}

fn printStatus(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    state: TuiState,
) !void {
    const tool_label = if (cfg.web_search_mode) |mode|
        if (mode.externalWebAccess() != null)
            "exec_command, write_stdin, shell, shell_command, apply_patch, update_plan, web_search"
        else
            "exec_command, write_stdin, shell, shell_command, apply_patch, update_plan"
    else
        "exec_command, write_stdin, shell, shell_command, apply_patch, update_plan";
    const status_line_label = try statusline.itemsLabel(allocator, state.status_line_items.items);
    defer allocator.free(status_line_label);

    std.debug.print(
        \\status:
        \\  model:       {s}
        \\  auth:        {s}
        \\  api:         {s}
        \\  cwd:         {s}
        \\  session:     {s}
        \\  title:       {s}
        \\  approval:    {s}
        \\  sandbox:     {s}
        \\  search:      {s}
        \\  service tier: {s}
        \\  plan mode:   {s}
        \\  alt screen:   {s}
        \\  term title:  {s}
        \\  status line: {s}
        \\  theme:       {s}
        \\  personality: {s}
        \\  raw output:  {s}
        \\  vim:         {s}
        \\  mentions:    {d} pending
        \\  transcript:  {d} items
        \\  tools:       {s}
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt, .chatgpt_auth_tokens, .agent_identity => cfg.chatgpt_base_url,
            .api_key, .local_oss => cfg.openai_base_url,
        },
        cwd,
        session_path,
        transcript.titleLabel(),
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
        if (cfg.service_tier) |service_tier| service_tier else "unset",
        if (state.plan_mode) "on" else "off",
        cfg.tui_alternate_screen.label(),
        if (state.terminal_title_items.items.len > 0) "on" else "off",
        status_line_label,
        state.syntaxThemeName(),
        personalityLabel(cfg.personality),
        if (state.raw_output_mode) "on" else "off",
        if (state.vim_mode) "on" else "off",
        state.mentions.items.len,
        transcript.history.items.len,
        tool_label,
    });
}

fn printDebugConfig(allocator: std.mem.Allocator, cfg: config.Config, credentials: auth.Credentials) !void {
    const config_path = try config.configTomlPath(allocator, cfg.codex_home);
    defer allocator.free(config_path);
    const user_config_status = configFileStatus(config_path);
    const profile_status = if (cfg.active_profile == null) "not selected" else "active";

    std.debug.print(
        \\/debug-config
        \\
        \\effective config:
        \\  codex_home:     {s}
        \\  active_profile: {s}
        \\  model:          {s}
        \\  auth:           {s}
        \\  openai_base:    {s}
        \\  chatgpt_base:   {s}
        \\  approval:       {s}
        \\  sandbox:        {s}
        \\  web_search:     {s}
        \\  service_tier:   {s}
        \\  alt_screen:     {s}
        \\  syntax_theme:   {s}
        \\  personality:    {s}
        \\  oss_provider:   {s}
        \\  installation:   {s}
        \\
        \\config layers:
        \\  defaults:      built-in
        \\  user config:   {s} ({s})
        \\  profile:       {s} ({s})
        \\  runtime:       interactive slash-command changes are reflected above
        \\
    , .{
        cfg.codex_home,
        cfg.active_profile orelse "<none>",
        cfg.model,
        credentials.describe(),
        cfg.openai_base_url,
        cfg.chatgpt_base_url,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
        cfg.service_tier orelse "<none>",
        cfg.tui_alternate_screen.label(),
        cfg.syntax_theme orelse "<default>",
        personalityLabel(cfg.personality),
        cfg.oss_provider orelse "<none>",
        cfg.installation_id,
        config_path,
        user_config_status,
        cfg.active_profile orelse "<none>",
        profile_status,
    });
}

fn configFileStatus(path: []const u8) []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return "missing",
        error.AccessDenied => return "unreadable",
        else => return "unavailable",
    };
    return "present";
}

fn printKeymap(args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len != 0 and !std.ascii.eqlIgnoreCase(trimmed, "debug")) {
        std.debug.print("usage: /keymap [debug]\n", .{});
        return;
    }

    std.debug.print(
        \\keymap:
        \\  Enter            submit the current line
        \\  q                quit from an empty prompt
        \\  !COMMAND         run a local shell command
        \\  /quit, /exit     exit Codex Zig
        \\  /stop, /clean    stop background terminals
        \\  /raw             toggle raw output mode
        \\  /vim             toggle Vim mode indicator
        \\
    , .{});

    if (trimmed.len != 0) {
        std.debug.print(
            \\keymap debug:
            \\  backend: built-in
            \\  configurable: false
            \\  alternate screen: supported; disable with --no-alt-screen
            \\
        , .{});
    }
}

fn handlePlanMode(plan_mode: *bool, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        plan_mode.* = !plan_mode.*;
        printPlanMode(plan_mode.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
        plan_mode.* = true;
        printPlanMode(plan_mode.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        plan_mode.* = false;
        printPlanMode(plan_mode.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printPlanMode(plan_mode.*);
        return;
    }
    std.debug.print("usage: /plan [on|off|status]\n", .{});
}

fn printPlanMode(enabled: bool) void {
    std.debug.print("plan mode: {s}\n", .{if (enabled) "on" else "off"});
}

fn handleTerminalTitle(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cwd: []const u8,
    transcript: *const session.Transcript,
    session_path: []const u8,
    state: *TuiState,
    args: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        try printTerminalTitleStatus(allocator, cfg, cwd, transcript, session_path, state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "on") or std.ascii.eqlIgnoreCase(trimmed, "default")) {
        try config.persistTuiTerminalTitle(allocator, cfg.codex_home, &titleline.default_ids);
        try state.replaceTerminalTitleItems(allocator, &titleline.default_items);
        try refreshTerminalTitle(allocator, cfg, cwd, transcript, session_path, state);
        try printTerminalTitleStatus(allocator, cfg, cwd, transcript, session_path, state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        try config.persistTuiTerminalTitle(allocator, cfg.codex_home, &.{});
        state.clearTerminalTitle();
        clearTerminalTitle();
        try printTerminalTitleStatus(allocator, cfg, cwd, transcript, session_path, state);
        return;
    }

    var parsed = std.ArrayList(titleline.Item).empty;
    defer parsed.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, trimmed, ", \t\r\n");
    while (tokens.next()) |token| {
        const item = titleline.parseItem(token) orelse {
            std.debug.print("unknown terminal title item: {s}\n", .{token});
            titleline.printUsage();
            return;
        };
        if (!titleline.containsItem(parsed.items, item)) {
            try parsed.append(allocator, item);
        }
    }
    if (parsed.items.len == 0) {
        titleline.printUsage();
        return;
    }

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (parsed.items) |item| try ids.append(allocator, item.id());
    try config.persistTuiTerminalTitle(allocator, cfg.codex_home, ids.items);
    try state.replaceTerminalTitleItems(allocator, parsed.items);
    try refreshTerminalTitle(allocator, cfg, cwd, transcript, session_path, state);
    try printTerminalTitleStatus(allocator, cfg, cwd, transcript, session_path, state);
}

fn printTerminalTitleStatus(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cwd: []const u8,
    transcript: *const session.Transcript,
    session_path: []const u8,
    state: *const TuiState,
) !void {
    const label = try titleline.itemsLabel(allocator, state.terminal_title_items.items);
    defer allocator.free(label);
    const title = try titleline.buildPreview(allocator, cfg, transcript, session_path, cwd, state.terminal_title_items.items, state.raw_output_mode);
    defer allocator.free(title);
    const sanitized = try sanitizeTerminalTitle(allocator, title);
    defer allocator.free(sanitized);
    std.debug.print("terminal title: {s}\n  items: {s}\n  preview: {s}\n", .{ if (state.terminal_title_items.items.len > 0) "on" else "off", label, sanitized });
}

fn refreshTerminalTitle(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cwd: []const u8,
    transcript: *const session.Transcript,
    session_path: []const u8,
    state: *const TuiState,
) !void {
    if (state.terminal_title_items.items.len == 0) return;
    const maybe_title = try titleline.build(allocator, cfg, transcript, session_path, cwd, state.terminal_title_items.items, state.raw_output_mode);
    const title = maybe_title orelse {
        clearTerminalTitle();
        return;
    };
    defer allocator.free(title);
    try writeTerminalTitle(allocator, title);
}

fn writeTerminalTitle(allocator: std.mem.Allocator, title: []const u8) !void {
    const sanitized = try sanitizeTerminalTitle(allocator, title);
    defer allocator.free(sanitized);
    if (sanitized.len == 0) return;
    std.debug.print("\x1b]0;{s}\x07", .{sanitized});
}

fn clearTerminalTitle() void {
    std.debug.print("\x1b]0;\x07", .{});
}

fn handleStatusLine(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    state: *TuiState,
    args: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        try printStatusLineStatus(allocator, cfg, transcript, session_path, cwd, state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "none") or std.ascii.eqlIgnoreCase(trimmed, "clear")) {
        try config.persistTuiStatusLine(allocator, cfg.codex_home, &.{});
        state.clearStatusLine();
        try printStatusLineStatus(allocator, cfg, transcript, session_path, cwd, state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "default")) {
        try config.persistTuiStatusLine(allocator, cfg.codex_home, &default_status_line_ids);
        try state.replaceStatusLineItems(allocator, &statusline.default_items);
        try printStatusLineStatus(allocator, cfg, transcript, session_path, cwd, state);
        return;
    }

    var parsed = std.ArrayList(statusline.Item).empty;
    defer parsed.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, trimmed, ", \t\r\n");
    while (tokens.next()) |token| {
        const item = statusline.parseItem(token) orelse {
            std.debug.print("unknown status line item: {s}\n", .{token});
            statusline.printUsage();
            return;
        };
        if (!statusline.containsItem(parsed.items, item)) {
            try parsed.append(allocator, item);
        }
    }
    if (parsed.items.len == 0) {
        statusline.printUsage();
        return;
    }

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (parsed.items) |item| try ids.append(allocator, item.id());
    try config.persistTuiStatusLine(allocator, cfg.codex_home, ids.items);
    try state.replaceStatusLineItems(allocator, parsed.items);
    try printStatusLineStatus(allocator, cfg, transcript, session_path, cwd, state);
}

fn applyConfiguredStatusLine(allocator: std.mem.Allocator, state: *TuiState, ids: []const []const u8) !void {
    var parsed = std.ArrayList(statusline.Item).empty;
    defer parsed.deinit(allocator);
    for (ids) |id| {
        const item = statusline.parseItem(id) orelse continue;
        if (!statusline.containsItem(parsed.items, item)) {
            try parsed.append(allocator, item);
        }
    }
    try state.replaceStatusLineItems(allocator, parsed.items);
}

fn applyConfiguredTerminalTitle(allocator: std.mem.Allocator, state: *TuiState, ids: []const []const u8) !void {
    var parsed = std.ArrayList(titleline.Item).empty;
    defer parsed.deinit(allocator);
    for (ids) |id| {
        const item = titleline.parseItem(id) orelse continue;
        if (!titleline.containsItem(parsed.items, item)) {
            try parsed.append(allocator, item);
        }
    }
    try state.replaceTerminalTitleItems(allocator, parsed.items);
}

fn printStatusLineStatus(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    state: *const TuiState,
) !void {
    const label = try statusline.itemsLabel(allocator, state.status_line_items.items);
    defer allocator.free(label);
    const preview = try statusline.buildPreview(allocator, cfg, transcript, session_path, cwd, state.status_line_items.items, state.raw_output_mode);
    defer allocator.free(preview);
    std.debug.print("status line: {s}\n  preview: {s}\n", .{ label, preview });
}

fn handleTheme(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    state: *TuiState,
    args: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printThemeStatus(state.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "list")) {
        try printThemeList(allocator, cfg.codex_home, state.syntaxThemeName());
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "default") or std.ascii.eqlIgnoreCase(trimmed, "auto")) {
        try config.persistTuiTheme(allocator, cfg.codex_home, theme.default_theme);
        try setSyntaxTheme(allocator, cfg, state, theme.default_theme);
        printThemeStatus(state.*);
        return;
    }
    if (!try theme.isAvailable(allocator, cfg.codex_home, trimmed)) {
        std.debug.print("unknown theme: {s}\n", .{trimmed});
        theme.printUsage();
        return;
    }
    try config.persistTuiTheme(allocator, cfg.codex_home, trimmed);
    try setSyntaxTheme(allocator, cfg, state, trimmed);
    printThemeStatus(state.*);
}

fn setSyntaxTheme(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    state: *TuiState,
    name: []const u8,
) !void {
    const next_cfg_value = try allocator.dupe(u8, name);
    errdefer allocator.free(next_cfg_value);
    try state.setSyntaxTheme(allocator, name);
    if (cfg.syntax_theme) |existing| allocator.free(existing);
    cfg.syntax_theme = next_cfg_value;
}

fn printThemeStatus(state: TuiState) void {
    std.debug.print("theme: {s}\n", .{state.syntaxThemeName()});
}

fn printThemeList(allocator: std.mem.Allocator, codex_home: []const u8, current_theme: []const u8) !void {
    var list = try theme.listAvailable(allocator, codex_home);
    defer list.deinit(allocator);

    std.debug.print("themes:\n", .{});
    for (list.items.items) |entry| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, current_theme)) "*" else " ";
        const suffix: []const u8 = if (entry.is_custom) " (custom)" else "";
        std.debug.print("  {s} {s}{s}\n", .{ marker, entry.name, suffix });
    }
}

fn handlePersonality(allocator: std.mem.Allocator, cfg: *config.Config, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printPersonalityStatus(cfg.personality);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "list")) {
        printPersonalityList(cfg.personality);
        return;
    }
    const personality = config.Personality.parse(trimmed) catch {
        std.debug.print("unknown personality: {s}\n", .{trimmed});
        printPersonalityUsage();
        return;
    };
    try config.persistPersonality(allocator, cfg.codex_home, cfg.active_profile, personality);
    cfg.personality = personality;
    printPersonalityStatus(cfg.personality);
}

fn printPersonalityStatus(personality: ?config.Personality) void {
    std.debug.print("personality: {s}\n", .{personalityLabel(personality)});
}

fn printPersonalityList(current: ?config.Personality) void {
    std.debug.print("personalities:\n", .{});
    for ([_]config.Personality{ .none, .friendly, .pragmatic }) |personality| {
        const marker: []const u8 = if (current != null and current.? == personality) "*" else " ";
        std.debug.print("  {s} {s} - {s}\n", .{ marker, personality.label(), personality.description() });
    }
}

fn printPersonalityUsage() void {
    std.debug.print("usage: /personality [status|list|none|friendly|pragmatic]\n", .{});
}

fn personalityLabel(personality: ?config.Personality) []const u8 {
    return if (personality) |value| value.label() else "unset";
}

fn sanitizeTerminalTitle(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    const view = std.unicode.Utf8View.init(title) catch {
        return sanitizeTerminalTitleBytes(allocator, title);
    };

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var chars_written: usize = 0;
    var pending_space = false;
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |codepoint_slice| {
        const codepoint = std.unicode.utf8Decode(codepoint_slice) catch unreachable;
        if (isTerminalTitleWhitespace(codepoint)) {
            pending_space = output.items.len > 0;
            continue;
        }
        if (isDisallowedTerminalTitleCodepoint(codepoint)) continue;
        if (pending_space) {
            const remaining = terminal_title_limit - chars_written;
            if (remaining > 1) {
                try output.append(allocator, ' ');
                chars_written += 1;
            }
            pending_space = false;
        }
        if (chars_written >= terminal_title_limit) break;
        try output.appendSlice(allocator, codepoint_slice);
        chars_written += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn sanitizeTerminalTitleBytes(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var pending_space = false;
    for (title) |byte| {
        if (isTerminalTitleWhitespace(byte)) {
            pending_space = output.items.len > 0;
            continue;
        }
        if (isDisallowedTerminalTitleCodepoint(byte)) continue;
        if (pending_space and output.items.len < terminal_title_limit) {
            try output.append(allocator, ' ');
        }
        pending_space = false;
        if (output.items.len >= terminal_title_limit) break;
        try output.append(allocator, byte);
    }

    return output.toOwnedSlice(allocator);
}

fn isTerminalTitleWhitespace(codepoint: u21) bool {
    return codepoint == 0x09 or
        codepoint == 0x0a or
        codepoint == 0x0b or
        codepoint == 0x0c or
        codepoint == 0x0d or
        codepoint == 0x20 or
        codepoint == 0x85 or
        codepoint == 0xa0 or
        codepoint == 0x1680 or
        (codepoint >= 0x2000 and codepoint <= 0x200a) or
        codepoint == 0x2028 or
        codepoint == 0x2029 or
        codepoint == 0x202f or
        codepoint == 0x205f or
        codepoint == 0x3000;
}

fn isDisallowedTerminalTitleCodepoint(codepoint: u21) bool {
    if (codepoint <= 0x1f) return true;
    if (codepoint >= 0x7f and codepoint <= 0x9f) return true;
    return codepoint == 0x00ad or
        codepoint == 0x034f or
        codepoint == 0x061c or
        codepoint == 0x180e or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        codepoint == 0xfeff or
        (codepoint >= 0xfff9 and codepoint <= 0xfffb) or
        (codepoint >= 0x1bca0 and codepoint <= 0x1bca3) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn renameThread(
    allocator: std.mem.Allocator,
    transcript: *session.Transcript,
    session_path: []const u8,
    args: []const u8,
) !bool {
    const title = std.mem.trim(u8, args, " \t\r\n");
    if (title.len == 0) {
        std.debug.print("usage: /rename <title>\n", .{});
        return false;
    }
    try transcript.setTitle(allocator, title);
    try session_store.saveTranscript(allocator, session_path, transcript);
    std.debug.print("renamed thread: {s}\n", .{transcript.title.?});
    return true;
}

fn mentionFile(allocator: std.mem.Allocator, cwd: []const u8, state: *TuiState, args: []const u8) !void {
    const raw_path = std.mem.trim(u8, args, " \t\r\n");
    if (raw_path.len == 0) {
        std.debug.print("usage: /mention <path>\n", .{});
        return;
    }
    if (std.mem.indexOfScalar(u8, raw_path, 0) != null) return error.InvalidMentionPath;

    const path = if (std.fs.path.isAbsolute(raw_path))
        try allocator.dupe(u8, raw_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, raw_path });
    defer allocator.free(path);

    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
        std.debug.print("mention failed: {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };

    try state.addMention(allocator, path);
    std.debug.print("mentioned: {s}\n", .{path});
}

fn printDiff(allocator: std.mem.Allocator, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len != 0) {
        std.debug.print("usage: /diff\n", .{});
        return;
    }

    const rendered = try git_diff.render(allocator);
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn handleFastMode(allocator: std.mem.Allocator, cfg: *config.Config, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        try setFastMode(allocator, cfg, !isFastMode(cfg.*));
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
        try setFastMode(allocator, cfg, true);
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        try setFastMode(allocator, cfg, false);
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printFastMode(cfg.*);
        return;
    }
    std.debug.print("usage: /fast [on|off|status]\n", .{});
}

fn setFastMode(allocator: std.mem.Allocator, cfg: *config.Config, enabled: bool) !void {
    if (cfg.service_tier) |existing| {
        allocator.free(existing);
        cfg.service_tier = null;
    }
    if (enabled) {
        cfg.service_tier = try allocator.dupe(u8, "priority");
    }
}

fn isFastMode(cfg: config.Config) bool {
    return if (cfg.service_tier) |service_tier|
        std.ascii.eqlIgnoreCase(service_tier, "priority") or std.ascii.eqlIgnoreCase(service_tier, "fast")
    else
        false;
}

fn printFastMode(cfg: config.Config) void {
    std.debug.print("Fast mode is {s}.\n", .{if (isFastMode(cfg)) "on" else "off"});
}

fn copyLastAssistantMessage(allocator: std.mem.Allocator, transcript: *const session.Transcript) void {
    const text = lastAssistantMessage(transcript) orelse {
        std.debug.print("copy: no assistant response yet\n", .{});
        return;
    };
    copyToClipboard(allocator, text) catch |err| {
        std.debug.print("copy failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("copied {d} bytes to clipboard\n", .{text.len});
}

fn lastAssistantMessage(transcript: *const session.Transcript) ?[]const u8 {
    var index = transcript.history.items.len;
    while (index > 0) {
        index -= 1;
        const item = transcript.history.items[index];
        if (item.kind != .message) continue;
        const role = item.role orelse continue;
        if (!std.ascii.eqlIgnoreCase(role, "assistant")) continue;
        const text = item.text orelse continue;
        if (text.len == 0) continue;
        return text;
    }
    return null;
}

fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    const command_override = try env.getOwned(allocator, "CODEX_ZIG_COPY_COMMAND");
    defer if (command_override) |command| allocator.free(command);

    const command = command_override orelse switch (builtin.os.tag) {
        .macos => "/usr/bin/pbcopy",
        else => return error.ClipboardUnsupported,
    };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{command};
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io_instance.io());

    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(io_instance.io(), text);
        stdin_file.close(io_instance.io());
        child.stdin = null;
    }

    const term = try child.wait(io_instance.io());
    switch (term) {
        .exited => |code| if (code != 0) return error.ClipboardCommandFailed,
        .signal, .stopped, .unknown => return error.ClipboardCommandFailed,
    }
}

fn handleRawOutputMode(raw_output_mode: *bool, args: []const u8) void {
    const next_mode = parseRawOutputMode(args, raw_output_mode.*) catch |err| switch (err) {
        error.InvalidRawOutputMode => {
            std.debug.print("usage: /raw [on|off]\n", .{});
            return;
        },
    };
    raw_output_mode.* = next_mode;
    std.debug.print("raw output mode: {s}\n", .{if (raw_output_mode.*) "on" else "off"});
}

fn parseRawOutputMode(args: []const u8, current: bool) !bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return !current;
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    return error.InvalidRawOutputMode;
}

fn printMcpStatus(allocator: std.mem.Allocator, codex_home: []const u8, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const verbose = if (trimmed.len == 0)
        false
    else if (std.ascii.eqlIgnoreCase(trimmed, "verbose"))
        true
    else {
        std.debug.print("usage: /mcp [verbose]\n", .{});
        return;
    };

    const rendered = try mcp_cmd.renderStatus(allocator, codex_home, verbose);
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn parseBangShellCommand(prompt: []const u8) ?[]const u8 {
    if (prompt.len == 0 or prompt[0] != '!') return null;
    return std.mem.trim(u8, prompt[1..], " \t\r\n");
}

fn runUserShellCommand(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    command: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    if (command.len == 0) {
        std.debug.print("usage: !COMMAND\n", .{});
        return;
    }

    const arguments = try std.json.Stringify.valueAlloc(allocator, .{ .command = command }, .{});
    defer allocator.free(arguments);

    const call = api.FunctionCall{
        .call_id = "user-shell",
        .name = "shell_command",
        .arguments = arguments,
    };
    var result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = cfg.approval_policy,
        .sandbox_mode = cfg.sandbox_mode,
        .additional_writable_roots = additional_writable_roots,
        .auto_approve = true,
        .prompt_for_approval = false,
    });
    defer result.deinit(allocator);

    std.debug.print("shell: {s}\n{s}\n", .{ result.summary, result.output });
}

fn printBackgroundTerminals(allocator: std.mem.Allocator) !void {
    const sessions = try tools.listExecSessions(allocator);
    defer allocator.free(sessions);

    if (sessions.len == 0) {
        std.debug.print("background terminals: none\n", .{});
        return;
    }

    std.debug.print("background terminals:\n", .{});
    for (sessions) |entry| {
        const kind = if (entry.pty) "pty" else "pipes";
        std.debug.print("  {d}. {s}, {d}ms\n", .{ entry.id, kind, entry.age_ms });
    }
}

const PermissionUpdate = union(enum) {
    approval: config.ApprovalPolicy,
    sandbox: config.SandboxMode,
};

fn handlePermissions(cfg: *config.Config, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        printPermissions(cfg.*);
        return;
    }

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (tokens.next()) |token| {
        const update = try parsePermissionUpdate(token);
        switch (update) {
            .approval => |approval_policy| cfg.approval_policy = approval_policy,
            .sandbox => |sandbox_mode| cfg.sandbox_mode = sandbox_mode,
        }
    }

    printPermissions(cfg.*);
}

fn printPermissions(cfg: config.Config) void {
    std.debug.print(
        \\permissions:
        \\  approval: {s}
        \\  sandbox:  {s}
        \\usage: /permissions [approval=<mode>] [sandbox=<mode>]
        \\
    , .{ cfg.approval_policy.label(), cfg.sandbox_mode.label() });
}

fn parsePermissionUpdate(token: []const u8) !PermissionUpdate {
    if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
        const key = token[0..eq];
        const value = token[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "approval")) {
            return .{ .approval = try config.ApprovalPolicy.parse(value) };
        }
        if (std.ascii.eqlIgnoreCase(key, "sandbox")) {
            return .{ .sandbox = try config.SandboxMode.parse(value) };
        }
        return error.InvalidPermissionsArgument;
    }

    if (config.ApprovalPolicy.parse(token)) |approval_policy| {
        return .{ .approval = approval_policy };
    } else |approval_err| switch (approval_err) {
        error.InvalidApprovalPolicy => {},
    }

    if (config.SandboxMode.parse(token)) |sandbox_mode| {
        return .{ .sandbox = sandbox_mode };
    } else |sandbox_err| switch (sandbox_err) {
        error.InvalidSandboxMode => {},
    }

    return error.InvalidPermissionsArgument;
}

fn printHistory(transcript: *const session.Transcript, limit: usize) void {
    const total = transcript.history.items.len;
    const start = if (limit == 0 or limit >= total) 0 else total - limit;
    std.debug.print("history: showing {d} of {d} items\n", .{ total - start, total });
    if (total == 0) {
        std.debug.print("  <empty>\n", .{});
        return;
    }

    for (transcript.history.items[start..], start..) |item, index| {
        std.debug.print("\n#{d} ", .{index + 1});
        switch (item.kind) {
            .message => {
                const role = item.role orelse "message";
                const text = item.text orelse "";
                std.debug.print("{s}:\n", .{role});
                printIndented(text, 1200);
            },
            .function_call => {
                std.debug.print("tool call: {s}\n", .{item.name orelse "unknown"});
                printIndented(item.arguments orelse "", 800);
            },
            .function_call_output => {
                std.debug.print("tool output: {s}\n", .{item.call_id orelse "unknown"});
                printIndented(item.output orelse "", 800);
            },
        }
    }
}

fn printIndented(text: []const u8, max_bytes: usize) void {
    const shown = text[0..@min(text.len, max_bytes)];
    if (shown.len == 0) {
        std.debug.print("  <empty>\n", .{});
    } else {
        var lines = std.mem.splitScalar(u8, shown, '\n');
        while (lines.next()) |line| {
            std.debug.print("  {s}\n", .{line});
        }
    }
    if (text.len > shown.len) {
        std.debug.print("  ... truncated {d} bytes\n", .{text.len - shown.len});
    }
}

fn parseHistoryLimit(args: []const u8) !usize {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return 20;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

fn parseSessionListLimit(args: []const u8) !usize {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return 10;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

test "parse slash command names and args" {
    const init = parseSlash("/init").?;
    try std.testing.expectEqualStrings("init", init.name);
    try std.testing.expectEqualStrings("", init.args);

    const compact = parseSlash("/compact").?;
    try std.testing.expectEqualStrings("compact", compact.name);
    try std.testing.expectEqualStrings("", compact.args);

    const status = parseSlash("/status").?;
    try std.testing.expectEqualStrings("status", status.name);
    try std.testing.expectEqualStrings("", status.args);

    const debug_config = parseSlash("/debug-config").?;
    try std.testing.expectEqualStrings("debug-config", debug_config.name);
    try std.testing.expectEqualStrings("", debug_config.args);

    const keymap = parseSlash("/keymap debug").?;
    try std.testing.expectEqualStrings("keymap", keymap.name);
    try std.testing.expectEqualStrings("debug", keymap.args);

    const plan = parseSlash("/plan on").?;
    try std.testing.expectEqualStrings("plan", plan.name);
    try std.testing.expectEqualStrings("on", plan.args);

    const title = parseSlash("/title status").?;
    try std.testing.expectEqualStrings("title", title.name);
    try std.testing.expectEqualStrings("status", title.args);

    const rename = parseSlash("/rename demo title").?;
    try std.testing.expectEqualStrings("rename", rename.name);
    try std.testing.expectEqualStrings("demo title", rename.args);

    const model = parseSlash("/model gpt-test").?;
    try std.testing.expectEqualStrings("model", model.name);
    try std.testing.expectEqualStrings("gpt-test", model.args);

    const fast = parseSlash("/fast status").?;
    try std.testing.expectEqualStrings("fast", fast.name);
    try std.testing.expectEqualStrings("status", fast.args);

    const approval = parseSlash("/approval on-request").?;
    try std.testing.expectEqualStrings("approval", approval.name);
    try std.testing.expectEqualStrings("on-request", approval.args);

    const permissions = parseSlash("/permissions sandbox=read-only").?;
    try std.testing.expectEqualStrings("permissions", permissions.name);
    try std.testing.expectEqualStrings("sandbox=read-only", permissions.args);

    const history = parseSlash("/history 5").?;
    try std.testing.expectEqualStrings("history", history.name);
    try std.testing.expectEqualStrings("5", history.args);

    const mention = parseSlash("/mention README.md").?;
    try std.testing.expectEqualStrings("mention", mention.name);
    try std.testing.expectEqualStrings("README.md", mention.args);

    const side = parseSlash("/side explore alternative").?;
    try std.testing.expectEqualStrings("side", side.name);
    try std.testing.expectEqualStrings("explore alternative", side.args);

    const rollout = parseSlash("/rollout").?;
    try std.testing.expectEqualStrings("rollout", rollout.name);
    try std.testing.expectEqualStrings("", rollout.args);

    const sessions = parseSlash("/sessions 2").?;
    try std.testing.expectEqualStrings("sessions", sessions.name);
    try std.testing.expectEqualStrings("2", sessions.args);

    const diff = parseSlash("/diff").?;
    try std.testing.expectEqualStrings("diff", diff.name);
    try std.testing.expectEqualStrings("", diff.args);

    const copy = parseSlash("/copy").?;
    try std.testing.expectEqualStrings("copy", copy.name);
    try std.testing.expectEqualStrings("", copy.args);

    const raw = parseSlash("/raw on").?;
    try std.testing.expectEqualStrings("raw", raw.name);
    try std.testing.expectEqualStrings("on", raw.args);

    const vim = parseSlash("/vim").?;
    try std.testing.expectEqualStrings("vim", vim.name);
    try std.testing.expectEqualStrings("", vim.args);

    const mcp = parseSlash("/mcp verbose").?;
    try std.testing.expectEqualStrings("mcp", mcp.name);
    try std.testing.expectEqualStrings("verbose", mcp.args);

    const ps = parseSlash("/ps").?;
    try std.testing.expectEqualStrings("ps", ps.name);
    try std.testing.expectEqualStrings("", ps.args);

    const stop = parseSlash("/stop").?;
    try std.testing.expectEqualStrings("stop", stop.name);
    try std.testing.expectEqualStrings("", stop.args);

    const clean = parseSlash("/clean").?;
    try std.testing.expectEqualStrings("clean", clean.name);
    try std.testing.expectEqualStrings("", clean.args);

    const logout = parseSlash("/logout").?;
    try std.testing.expectEqualStrings("logout", logout.name);
    try std.testing.expectEqualStrings("", logout.args);

    const review_cmd = parseSlash("/review check regressions").?;
    try std.testing.expectEqualStrings("review", review_cmd.name);
    try std.testing.expectEqualStrings("check regressions", review_cmd.args);

    try std.testing.expect(parseSlash("hello") == null);
}

test "parse bang shell command" {
    try std.testing.expect(parseBangShellCommand("hello") == null);
    try std.testing.expectEqualStrings("echo hi", parseBangShellCommand("! echo hi").?);
    try std.testing.expectEqualStrings("", parseBangShellCommand("!   ").?);
}

test "parse raw output mode args" {
    try std.testing.expectEqual(true, try parseRawOutputMode("", false));
    try std.testing.expectEqual(false, try parseRawOutputMode("", true));
    try std.testing.expectEqual(true, try parseRawOutputMode(" on ", false));
    try std.testing.expectEqual(false, try parseRawOutputMode("OFF", true));
    try std.testing.expectError(error.InvalidRawOutputMode, parseRawOutputMode("status", false));
}

test "sanitizes terminal title text" {
    const allocator = std.testing.allocator;

    const sanitized = try sanitizeTerminalTitle(allocator, "  Project\t|\nWorking\x1b\x07\u{009d}\u{009c} |  Thread  ");
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("Project | Working | Thread", sanitized);

    const invisible = try sanitizeTerminalTitle(allocator, "Pro\u{202e}j\u{2066}e\u{200f}c\u{061c}t\u{200b} \u{feff}Title");
    defer allocator.free(invisible);
    try std.testing.expectEqualStrings("Project Title", invisible);

    const unicode = try sanitizeTerminalTitle(allocator, "Project \u{1f680}");
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("Project \u{1f680}", unicode);

    const long_title = try allocator.alloc(u8, terminal_title_limit + 16);
    defer allocator.free(long_title);
    @memset(long_title, 'x');

    const truncated = try sanitizeTerminalTitle(allocator, long_title);
    defer allocator.free(truncated);
    try std.testing.expectEqual(@as(usize, terminal_title_limit), truncated.len);

    const prefix = try allocator.alloc(u8, terminal_title_limit - 1);
    defer allocator.free(prefix);
    @memset(prefix, 'a');
    const pending_space_input = try std.fmt.allocPrint(allocator, "{s} b", .{prefix});
    defer allocator.free(pending_space_input);
    const pending_space = try sanitizeTerminalTitle(allocator, pending_space_input);
    defer allocator.free(pending_space);
    try std.testing.expectEqual(@as(usize, terminal_title_limit), pending_space.len);
    try std.testing.expectEqual(@as(u8, 'b'), pending_space[pending_space.len - 1]);
}

test "finds last assistant message for copy" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    try std.testing.expect(lastAssistantMessage(&transcript) == null);
    try transcript.appendUserMessage(allocator, "hello");
    try std.testing.expect(lastAssistantMessage(&transcript) == null);
    try transcript.appendAssistantMessage(allocator, "first answer");
    try transcript.appendUserMessage(allocator, "next");
    try transcript.appendAssistantMessage(allocator, "second answer");

    try std.testing.expectEqualStrings("second answer", lastAssistantMessage(&transcript).?);
}

test "build prompt with mentioned files" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "context.txt",
        .data = "important context\n",
    });

    const path = try std.fs.path.join(allocator, &.{ root, "context.txt" });
    defer allocator.free(path);
    const mentions = [_][]const u8{path};

    const prompt = try buildPromptWithMentions(allocator, "summarize this", &mentions);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "summarize this") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Mentioned files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "context.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "important context") != null);
}

test "agents file existence check" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const cwd = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    try std.testing.expect(!try agentsFileExists(allocator, cwd));
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = agents_filename,
        .data = "repo guidance\n",
    });
    try std.testing.expect(try agentsFileExists(allocator, cwd));
}

test "parse history limit" {
    try std.testing.expectEqual(@as(usize, 20), try parseHistoryLimit(""));
    try std.testing.expectEqual(@as(usize, 3), try parseHistoryLimit(" 3 "));
    try std.testing.expectError(error.InvalidCharacter, parseHistoryLimit("abc"));

    try std.testing.expectEqual(@as(usize, 10), try parseSessionListLimit(""));
    try std.testing.expectEqual(@as(usize, 2), try parseSessionListLimit("2"));
    try std.testing.expectError(error.InvalidCharacter, parseSessionListLimit("x"));
}

test "validates remote app-server URLs" {
    const unix = try validateRemoteUrl("unix:///tmp/codex.sock");
    try std.testing.expectEqual(.unix, unix.scheme);
    try std.testing.expectEqualStrings("/tmp/codex.sock", unix.path);

    const ws = try validateRemoteUrl("ws://127.0.0.1:4500");
    try std.testing.expectEqual(.ws, ws.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", ws.host);

    const wss = try validateRemoteUrl("wss://example.com:443/");
    try std.testing.expectEqual(.wss, wss.scheme);
    try std.testing.expectEqualStrings("example.com", wss.host);

    const ipv6 = try validateRemoteUrl("ws://[::1]:4500");
    try std.testing.expectEqualStrings("[::1]", ipv6.host);

    try std.testing.expectError(error.InvalidRemoteAddress, validateRemoteUrl("https://127.0.0.1:4500"));
    try std.testing.expectError(error.InvalidRemoteAddress, validateRemoteUrl("unix://"));
    try std.testing.expectError(error.InvalidRemoteAddress, validateRemoteUrl("ws://127.0.0.1"));
    try std.testing.expectError(error.InvalidRemoteAddress, validateRemoteUrl("ws://127.0.0.1:4500/path"));
}

test "remote auth token transport is limited to secure or loopback URLs" {
    try std.testing.expect(remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://127.0.0.1:4500")));
    try std.testing.expect(remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://127.1.2.3:4500")));
    try std.testing.expect(remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://localhost:4500")));
    try std.testing.expect(remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://[::1]:4500")));
    try std.testing.expect(remoteUrlSupportsAuthToken(try validateRemoteUrl("wss://example.com:443")));
    try std.testing.expect(!remoteUrlSupportsAuthToken(try validateRemoteUrl("unix:///tmp/codex.sock")));
    try std.testing.expect(!remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://example.com:4500")));
}

test "parse resume picker selection" {
    try std.testing.expectEqual(@as(?usize, 0), try parseResumeSelection("1\n", 2));
    try std.testing.expectEqual(@as(?usize, 1), try parseResumeSelection(" 2 ", 2));
    try std.testing.expectEqual(@as(?usize, null), try parseResumeSelection("\n", 2));
    try std.testing.expectError(error.InvalidResumeSelection, parseResumeSelection("3", 2));
    try std.testing.expectError(error.InvalidCharacter, parseResumeSelection("x", 2));
}

test "parse permission updates" {
    const approval = try parsePermissionUpdate("approval=never");
    try std.testing.expectEqual(config.ApprovalPolicy.never, approval.approval);

    const sandbox = try parsePermissionUpdate("read-only");
    try std.testing.expectEqual(config.SandboxMode.read_only, sandbox.sandbox);

    try std.testing.expectError(error.InvalidPermissionsArgument, parsePermissionUpdate("unknown=value"));
}
