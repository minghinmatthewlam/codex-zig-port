const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const git_diff = @import("git_diff.zig");
const login = @import("login.zig");
const local_remote_control = @import("local_remote_control.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const remote_ws_client = @import("remote_ws_client.zig");
const review = @import("review.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const statusline = @import("statusline.zig");
const theme = @import("theme.zig");
const titleline = @import("titleline.zig");
const tools = @import("tools.zig");

const agents_filename = "AGENTS.md";
const mention_file_limit = 128 * 1024;
const remote_line_limit = 16 * 1024 * 1024;
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
    initial_input_image_paths: []const []const u8 = &.{},
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
    port: u16 = 0,
    path: []const u8 = "",
};

const RemoteTransportKind = enum {
    jsonl,
    websocket,
};

const RemoteTransport = struct {
    allocator: std.mem.Allocator,
    kind: RemoteTransportKind,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    fn writeJson(self: *RemoteTransport, payload: []const u8) !void {
        switch (self.kind) {
            .jsonl => try writeRemoteLine(self.writer, payload),
            .websocket => try writeClientWebSocketTextFrame(self.allocator, self.writer, payload),
        }
    }

    fn readMessage(self: *RemoteTransport) !?[]u8 {
        return switch (self.kind) {
            .jsonl => try readRemoteLine(self.allocator, self.reader),
            .websocket => try readServerWebSocketTextFrame(self.allocator, self.reader, self.writer),
        };
    }
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
    const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidRemoteAddress;
    return .{ .scheme = scheme, .host = host, .port = port };
}

fn remoteUrlSupportsAuthToken(parts: RemoteUrlParts) bool {
    if (parts.scheme == .wss) return true;
    if (parts.scheme != .ws) return false;
    return remote_ws_client.isLoopbackHost(parts.host);
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

    var local_remote_server: ?local_remote_control.Server = null;
    defer if (local_remote_server) |*server| server.deinit(allocator);
    if (options.local_remote_control) {
        var snapshot_json: ?[]const u8 = try renderLocalRemoteControlSnapshotJson(allocator, cwd, &transcript);
        errdefer if (snapshot_json) |value| allocator.free(value);
        local_remote_server = try local_remote_control.start(allocator, options.remote_control_bind, snapshot_json.?);
        snapshot_json = null;
        if (local_remote_server) |*server| printLocalRemoteControlLinks(server);
    }

    var pending_input_images: []const []const u8 = options.initial_input_images;
    if (options.initial_prompt) |initial_prompt| {
        const prompt = std.mem.trim(u8, initial_prompt, " \t\r\n");
        if (prompt.len > 0) {
            runPrompt(allocator, cfg, &credentials, &transcript, session_path, prompt, options.additional_writable_roots, pending_input_images) catch |err| {
                std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            };
            refreshLocalRemoteControlSnapshot(allocator, &local_remote_server, cwd, &transcript);
            pending_input_images = &.{};
        }
    }

    var stdin_line = std.ArrayList(u8).empty;
    defer stdin_line.deinit(allocator);
    var stdin_read_buffer: [4096]u8 = undefined;
    var prompt_visible = false;
    while (true) {
        if (!prompt_visible) {
            std.debug.print("\n› ", .{});
            prompt_visible = true;
        }

        var fds: [2]std.posix.pollfd = undefined;
        fds[0] = .{ .fd = std.posix.STDIN_FILENO, .events = @intCast(std.posix.POLL.IN), .revents = 0 };
        var fd_count: usize = 1;
        const remote_fd_index: ?usize = if (local_remote_server) |*server| blk: {
            fds[fd_count] = .{ .fd = server.prompt_read_fd, .events = @intCast(std.posix.POLL.IN), .revents = 0 };
            fd_count += 1;
            break :blk fd_count - 1;
        } else null;

        _ = try std.posix.poll(fds[0..fd_count], -1);

        if (remote_fd_index) |index| {
            if (local_remote_control.pollReventsInclude(fds[index].revents)) {
                if (local_remote_server) |*server| {
                    const remote_prompt_opt = server.readSubmittedPrompt(allocator) catch |err| {
                        std.debug.print("\nremote control error: {s}\n", .{@errorName(err)});
                        prompt_visible = false;
                        continue;
                    };
                    if (remote_prompt_opt) |remote_prompt| {
                        defer allocator.free(remote_prompt);
                        std.debug.print("\nremote › {s}\n", .{remote_prompt});
                        const input_images = pending_input_images;
                        pending_input_images = &.{};
                        runUserPrompt(allocator, cfg, &credentials, &transcript, session_path, remote_prompt, options.additional_writable_roots, &state, input_images) catch |err| {
                            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
                        };
                        refreshLocalRemoteControlSnapshot(allocator, &local_remote_server, cwd, &transcript);
                        prompt_visible = false;
                    }
                }
            }
        }

        if (local_remote_control.pollReventsInclude(fds[0].revents)) {
            const read_len = try std.posix.read(std.posix.STDIN_FILENO, &stdin_read_buffer);
            if (read_len == 0) {
                if (stdin_line.items.len > 0) {
                    const should_quit = try handleInteractivePromptLine(allocator, &cfg, &credentials, &transcript, &session_path, cwd, stdin_line.items, &state, options.additional_writable_roots, &pending_input_images, &local_remote_server, options.remote_control_bind);
                    refreshLocalRemoteControlSnapshot(allocator, &local_remote_server, cwd, &transcript);
                    if (should_quit) break;
                }
                break;
            }
            var should_quit = false;
            for (stdin_read_buffer[0..read_len]) |byte| {
                if (byte == '\n') {
                    prompt_visible = false;
                    should_quit = try handleInteractivePromptLine(allocator, &cfg, &credentials, &transcript, &session_path, cwd, stdin_line.items, &state, options.additional_writable_roots, &pending_input_images, &local_remote_server, options.remote_control_bind);
                    refreshLocalRemoteControlSnapshot(allocator, &local_remote_server, cwd, &transcript);
                    stdin_line.clearRetainingCapacity();
                    if (should_quit) break;
                } else if (byte != '\r') {
                    try stdin_line.append(allocator, byte);
                }
            }
            if (should_quit) break;
        }
    }

    if (state.terminal_title_items.items.len > 0) clearTerminalTitle();
    std.debug.print("\nbye\n", .{});
}

fn handleInteractivePromptLine(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    credentials: *auth.Credentials,
    transcript: *session.Transcript,
    session_path: *[]const u8,
    cwd: []const u8,
    line: []const u8,
    state: *TuiState,
    additional_writable_roots: []const []const u8,
    pending_input_images: *[]const []const u8,
    local_remote_server: *?local_remote_control.Server,
    remote_control_bind: ?[]const u8,
) !bool {
    const prompt = std.mem.trim(u8, line, " \t\r\n");
    if (prompt.len == 0) return false;
    if (std.mem.eql(u8, prompt, "q")) return true;
    if (parseBangShellCommand(prompt)) |command| {
        runUserShellCommand(allocator, cfg.*, command, additional_writable_roots) catch |err| {
            std.debug.print("shell error: {s}\n", .{@errorName(err)});
        };
        return false;
    }
    const slash_action = handleSlashCommand(allocator, cfg, credentials, transcript, session_path, cwd, prompt, state, additional_writable_roots, local_remote_server, remote_control_bind) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return false;
    };
    if (slash_action) |action| {
        return switch (action) {
            .handled => false,
            .quit => true,
        };
    }

    const input_images = pending_input_images.*;
    pending_input_images.* = &.{};
    runUserPrompt(allocator, cfg.*, credentials, transcript, session_path.*, prompt, additional_writable_roots, state, input_images) catch |err| {
        std.debug.print("\nerror: {s}\n", .{@errorName(err)});
    };
    return false;
}

fn printLocalRemoteControlLinks(server: *const local_remote_control.Server) void {
    std.debug.print(
        \\Remote control active
        \\Controller link: {s}
        \\Share link: {s}
        \\
    , .{ server.url, server.share_url });
}

fn refreshLocalRemoteControlSnapshot(
    allocator: std.mem.Allocator,
    server_opt: *?local_remote_control.Server,
    cwd: []const u8,
    transcript: *const session.Transcript,
) void {
    const server = if (server_opt.*) |*server| server else return;
    const snapshot_json = renderLocalRemoteControlSnapshotJson(allocator, cwd, transcript) catch |err| {
        std.debug.print("warning: could not update remote-control snapshot: {s}\n", .{@errorName(err)});
        return;
    };
    server.updateSnapshot(allocator, snapshot_json);
}

fn renderLocalRemoteControlSnapshotJson(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    transcript: *const session.Transcript,
) ![]const u8 {
    const cwd_json = try std.json.Stringify.valueAlloc(allocator, cwd, .{});
    defer allocator.free(cwd_json);
    const status_json = try std.json.Stringify.valueAlloc(allocator, "Connected to Codex", .{});
    defer allocator.free(status_json);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{{\"cwd\":{s},\"status\":{s},\"messages\":[", .{ cwd_json, status_json });

    var message_id: usize = 1;
    for (transcript.history.items) |item| {
        const text = switch (item.kind) {
            .message => item.text orelse "",
            .function_call => item.arguments orelse "",
            .function_call_output => item.output orelse "",
        };
        const trimmed_text = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed_text.len == 0) continue;

        const role = remoteControlRoleForItem(item);
        {
            const role_json = try std.json.Stringify.valueAlloc(allocator, role, .{});
            defer allocator.free(role_json);
            const text_json = try std.json.Stringify.valueAlloc(allocator, trimmed_text, .{});
            defer allocator.free(text_json);

            if (message_id > 1) try out.append(allocator, ',');
            try out.print(
                allocator,
                "{{\"id\":{d},\"role\":{s},\"text\":{s}}}",
                .{ message_id, role_json, text_json },
            );
        }
        message_id += 1;
    }

    const thread_id_json = if (transcript.id) |thread_id|
        try std.json.Stringify.valueAlloc(allocator, thread_id, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(thread_id_json);
    const fork_available = transcript.id != null;
    try out.print(
        allocator,
        "],\"fork\":{{\"available\":{s},\"threadId\":{s}}}}}",
        .{ if (fork_available) "true" else "false", thread_id_json },
    );
    return out.toOwnedSlice(allocator);
}

fn remoteControlRoleForItem(item: api.HistoryItem) []const u8 {
    return switch (item.kind) {
        .message => blk: {
            const role = item.role orelse break :blk "status";
            if (std.mem.eql(u8, role, "user")) break :blk "user";
            if (std.mem.eql(u8, role, "assistant")) break :blk "assistant";
            break :blk "status";
        },
        .function_call, .function_call_output => "tool",
    };
}

fn runRemoteTui(allocator: std.mem.Allocator, options: Options, remote: []const u8) !void {
    if (options.local_remote_control or options.remote_control_bind != null) {
        std.debug.print("`--remote-control` cannot be combined with `--remote`.\n", .{});
        return error.RemoteControlCannotCombineWithRemote;
    }

    const parts = try validateRemoteUrl(remote);
    try validateRemoteTuiSupportedOptions(options);

    const io = std.Io.Threaded.global_single_threaded.io();
    var remote_ws_connection: remote_ws_client.Connection = undefined;
    var remote_ws_connection_initialized = false;
    defer if (remote_ws_connection_initialized) remote_ws_connection.deinit();

    var unix_stream: net.Stream = undefined;
    var unix_stream_initialized = false;
    defer if (unix_stream_initialized) unix_stream.close(io);

    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var unix_reader: net.Stream.Reader = undefined;
    var unix_writer: net.Stream.Writer = undefined;
    var transport_reader: *std.Io.Reader = undefined;
    var transport_writer: *std.Io.Writer = undefined;

    const transport_kind: RemoteTransportKind = switch (parts.scheme) {
        .unix => blk: {
            var address = try net.UnixAddress.init(parts.path);
            unix_stream = try address.connect(io);
            unix_stream_initialized = true;
            unix_reader = unix_stream.reader(io, &input_buffer);
            unix_writer = unix_stream.writer(io, &output_buffer);
            transport_reader = &unix_reader.interface;
            transport_writer = &unix_writer.interface;
            break :blk .jsonl;
        },
        .ws => blk: {
            const stream = try connectRemoteWebSocket(io, parts);
            remote_ws_connection.initPlain(allocator, io, stream);
            remote_ws_connection_initialized = true;
            transport_reader = remote_ws_connection.reader();
            transport_writer = remote_ws_connection.writer();
            try performRemoteWebSocketHandshake(allocator, transport_reader, transport_writer, parts, options.remote_auth_token_env);
            break :blk .websocket;
        },
        .wss => blk: {
            try remote_ws_connection.initTls(allocator, io, parts.host, parts.port);
            remote_ws_connection_initialized = true;
            transport_reader = remote_ws_connection.reader();
            transport_writer = remote_ws_connection.writer();
            try performRemoteWebSocketHandshake(allocator, transport_reader, transport_writer, parts, options.remote_auth_token_env);
            break :blk .websocket;
        },
    };
    var transport = RemoteTransport{
        .allocator = allocator,
        .kind = transport_kind,
        .reader = transport_reader,
        .writer = transport_writer,
    };

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const remote_additional_writable_roots = try resolveRemoteAdditionalWritableRoots(allocator, io, cwd, options.additional_writable_roots);
    defer freeRemoteAdditionalWritableRoots(allocator, remote_additional_writable_roots);

    const alt_screen_mode = options.runtime_overrides.tui_alternate_screen orelse .auto;
    const use_alt_screen = shouldUseAlternateScreen(options.no_alt_screen, alt_screen_mode);
    if (use_alt_screen) enterAlternateScreen();
    defer if (use_alt_screen) leaveAlternateScreen();

    printRemoteHeader(remote, cwd);

    try transport.writeJson(
        \\{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"clientInfo":{"name":"codex-zig-tui","version":"0.0.1"},"capabilities":{"experimentalApi":true}}}
    );
    var initialize_response = try readRemoteResponse(&transport, "initialize");
    initialize_response.deinit();

    var remote_state = RemoteTuiState.init(options.runtime_overrides, remote_additional_writable_roots);
    defer remote_state.deinit(allocator);

    var thread_id = (try openRemoteThread(allocator, &transport, cwd, options, &remote_state)) orelse return;
    defer allocator.free(thread_id);

    var pending_input_image_paths: []const []const u8 = options.initial_input_image_paths;
    if (options.initial_prompt) |initial_prompt| {
        const prompt = std.mem.trim(u8, initial_prompt, " \t\r\n");
        if (prompt.len > 0) {
            runRemotePrompt(allocator, &transport, thread_id, prompt, pending_input_image_paths, remote_state.overrides, remote_state.service_tier_cleared, remote_state.additional_writable_roots, remote_state.effective_sandbox_mode, remote_state.effectiveWorkspaceSandbox()) catch |err| {
                std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            };
            pending_input_image_paths = &.{};
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
        if (std.mem.eql(u8, prompt, "q")) break;
        if (std.mem.startsWith(u8, prompt, "/")) {
            const action = handleRemoteSlashCommand(allocator, &transport, &thread_id, remote, cwd, &remote_state, &stdin_reader.interface, prompt) catch |err| {
                std.debug.print("remote command error: {s}\n", .{@errorName(err)});
                continue;
            };
            if (action == .quit) break;
            continue;
        }
        const input_image_paths = pending_input_image_paths;
        pending_input_image_paths = &.{};
        runRemotePrompt(allocator, &transport, thread_id, prompt, input_image_paths, remote_state.overrides, remote_state.service_tier_cleared, remote_state.additional_writable_roots, remote_state.effective_sandbox_mode, remote_state.effectiveWorkspaceSandbox()) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
    }

    std.debug.print("\nbye\n", .{});
}

const RemoteSlashAction = enum {
    handled,
    quit,
};

const RemoteTuiState = struct {
    overrides: config.RuntimeOverrides,
    additional_writable_roots: []const []const u8 = &.{},
    effective_sandbox_mode: ?config.SandboxMode = null,
    effective_workspace_sandbox: ?RemoteEffectiveWorkspaceSandbox = null,
    owned_model: ?[]const u8 = null,
    effective_service_tier: ?[]const u8 = null,
    owned_effective_service_tier: ?[]const u8 = null,
    service_tier_cleared: bool = false,

    fn init(overrides: config.RuntimeOverrides, additional_writable_roots: []const []const u8) RemoteTuiState {
        return .{
            .overrides = overrides,
            .additional_writable_roots = additional_writable_roots,
            .effective_service_tier = overrides.service_tier,
        };
    }

    fn deinit(self: *RemoteTuiState, allocator: std.mem.Allocator) void {
        if (self.effective_workspace_sandbox) |*sandbox| sandbox.deinit(allocator);
        if (self.owned_model) |model| allocator.free(model);
        if (self.owned_effective_service_tier) |service_tier| allocator.free(service_tier);
    }

    fn setModel(self: *RemoteTuiState, allocator: std.mem.Allocator, model: []const u8) !void {
        const copy = try allocator.dupe(u8, model);
        if (self.owned_model) |existing| allocator.free(existing);
        self.owned_model = copy;
        self.overrides.model = copy;
    }

    fn setEffectiveServiceTier(self: *RemoteTuiState, allocator: std.mem.Allocator, service_tier: ?[]const u8) !void {
        if (self.owned_effective_service_tier) |existing| allocator.free(existing);
        self.owned_effective_service_tier = null;
        self.effective_service_tier = null;
        if (service_tier) |value| {
            const copy = try allocator.dupe(u8, value);
            self.owned_effective_service_tier = copy;
            self.effective_service_tier = copy;
        }
    }

    fn updateFromLifecycleResponse(self: *RemoteTuiState, allocator: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .object) return error.InvalidRemoteAppServerResponse;
        const result = value.object.get("result") orelse return error.InvalidRemoteAppServerResponse;
        if (result != .object) return error.InvalidRemoteAppServerResponse;
        if (result.object.get("serviceTier")) |service_tier| {
            switch (service_tier) {
                .null => try self.setEffectiveServiceTier(allocator, null),
                .string => |label| try self.setEffectiveServiceTier(allocator, label),
                else => return error.InvalidRemoteAppServerResponse,
            }
        }
        if (result.object.get("sandbox")) |sandbox| {
            try self.setEffectiveSandbox(allocator, sandbox);
        }
    }

    fn setEffectiveSandbox(self: *RemoteTuiState, allocator: std.mem.Allocator, value: std.json.Value) !void {
        var parsed = try parseRemoteSandboxState(allocator, value);
        errdefer parsed.deinit(allocator);

        if (self.effective_workspace_sandbox) |*sandbox| sandbox.deinit(allocator);
        self.effective_workspace_sandbox = null;
        self.effective_sandbox_mode = parsed.mode;
        if (parsed.workspace_sandbox) |workspace_sandbox| {
            self.effective_workspace_sandbox = workspace_sandbox;
            parsed.workspace_sandbox = null;
        }
    }

    fn effectiveWorkspaceSandbox(self: *const RemoteTuiState) ?*const RemoteEffectiveWorkspaceSandbox {
        if (self.effective_workspace_sandbox) |*sandbox| return sandbox;
        return null;
    }

    fn setFastMode(self: *RemoteTuiState, allocator: std.mem.Allocator, enabled: bool) void {
        if (self.owned_effective_service_tier) |existing| allocator.free(existing);
        self.owned_effective_service_tier = null;
        self.overrides.service_tier = if (enabled) "priority" else null;
        self.effective_service_tier = self.overrides.service_tier;
        self.service_tier_cleared = !enabled;
    }
};

const RemoteEffectiveWorkspaceSandbox = struct {
    writable_roots: config.StringList,
    network_enabled: bool = false,
    exclude_tmpdir_env_var: bool = false,
    exclude_slash_tmp: bool = false,

    fn deinit(self: *RemoteEffectiveWorkspaceSandbox, allocator: std.mem.Allocator) void {
        self.writable_roots.deinit(allocator);
    }

    fn canExtendWithWritableRoots(self: RemoteEffectiveWorkspaceSandbox) bool {
        return !self.network_enabled and !self.exclude_tmpdir_env_var and !self.exclude_slash_tmp;
    }
};

const RemoteParsedSandboxState = struct {
    mode: config.SandboxMode,
    workspace_sandbox: ?RemoteEffectiveWorkspaceSandbox = null,

    fn deinit(self: *RemoteParsedSandboxState, allocator: std.mem.Allocator) void {
        if (self.workspace_sandbox) |*sandbox| sandbox.deinit(allocator);
    }
};

fn handleRemoteSlashCommand(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    thread_id: *[]const u8,
    remote: []const u8,
    cwd: []const u8,
    state: *RemoteTuiState,
    stdin_reader: *std.Io.Reader,
    prompt: []const u8,
) !RemoteSlashAction {
    const parts = parseSlash(prompt) orelse return .handled;

    if (std.ascii.eqlIgnoreCase(parts.name, "quit") or
        std.ascii.eqlIgnoreCase(parts.name, "exit") or
        std.mem.eql(u8, parts.name, "q"))
    {
        return .quit;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "help")) {
        printRemoteSlashHelp();
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "status")) {
        std.debug.print("remote: {s}\nthread: {s}\ncwd: {s}\n", .{ remote, thread_id.*, cwd });
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "compact")) {
        const trimmed = std.mem.trim(u8, parts.args, " \t\r\n");
        if (trimmed.len != 0) {
            std.debug.print("usage: /compact\n", .{});
            return .handled;
        }
        try compactRemoteThread(allocator, transport, thread_id.*);
        std.debug.print("compacted remote thread: {s}\n", .{thread_id.*});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "model")) {
        try handleRemoteModel(allocator, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "fast")) {
        handleRemoteFastMode(allocator, state, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "personality")) {
        handleRemotePersonality(&state.overrides, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "approval")) {
        try handleRemoteApproval(&state.overrides, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sandbox")) {
        try handleRemoteSandbox(&state.overrides, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "permissions")) {
        try handleRemotePermissions(&state.overrides, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sessions")) {
        const limit = try parseSessionListLimit(parts.args);
        try printRemoteSessions(allocator, transport, limit);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "new") or std.ascii.eqlIgnoreCase(parts.name, "clear")) {
        const trimmed = std.mem.trim(u8, parts.args, " \t\r\n");
        if (trimmed.len != 0) {
            std.debug.print("usage: /{s}\n", .{parts.name});
            return .handled;
        }
        const next_thread_id = try startRemoteThread(allocator, transport, cwd, state);
        allocator.free(thread_id.*);
        thread_id.* = next_thread_id;
        if (std.ascii.eqlIgnoreCase(parts.name, "clear")) {
            std.debug.print("\x1b[2J\x1b[H", .{});
            printRemoteHeader(remote, cwd);
        }
        std.debug.print("started remote thread: {s}\n", .{thread_id.*});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "resume")) {
        if (try switchRemoteThread(allocator, transport, thread_id, "resume", "thread/resume", cwd, state, stdin_reader, parts.args)) {
            std.debug.print("resumed remote thread: {s}\n", .{thread_id.*});
        } else {
            std.debug.print("resume canceled\n", .{});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "fork")) {
        if (try switchRemoteThread(allocator, transport, thread_id, "fork", "thread/fork", cwd, state, stdin_reader, parts.args)) {
            std.debug.print("forked remote thread: {s}\n", .{thread_id.*});
        } else {
            std.debug.print("fork canceled\n", .{});
        }
        return .handled;
    }

    std.debug.print("unknown remote slash command: /{s}\nType /help for commands.\n", .{parts.name});
    return .handled;
}

fn printRemoteSlashHelp() void {
    std.debug.print(
        \\commands:
        \\  /help
        \\  /status
        \\  /compact
        \\  /model [MODEL]
        \\  /fast [on|off|status]
        \\  /personality [status|list|none|friendly|pragmatic]
        \\  /permissions [approval=<mode>] [sandbox=<mode>]
        \\  /approval [mode]
        \\  /sandbox [mode]
        \\  /sessions [N]
        \\  /clear
        \\  /new
        \\  /resume [TARGET|last]
        \\  /fork [TARGET|last]
        \\  /quit
        \\
    , .{});
}

fn handleRemoteModel(allocator: std.mem.Allocator, state: *RemoteTuiState, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        std.debug.print("model: {s}\n", .{state.overrides.model orelse "remote default"});
        return;
    }
    try state.setModel(allocator, trimmed);
    std.debug.print("model: {s}\n", .{state.overrides.model.?});
}

fn handleRemoteFastMode(allocator: std.mem.Allocator, state: *RemoteTuiState, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        state.setFastMode(allocator, !remoteFastMode(state.effective_service_tier));
        printRemoteFastMode(state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
        state.setFastMode(allocator, true);
        printRemoteFastMode(state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        state.setFastMode(allocator, false);
        printRemoteFastMode(state);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printRemoteFastMode(state);
        return;
    }
    std.debug.print("usage: /fast [on|off|status]\n", .{});
}

fn remoteFastMode(service_tier: ?[]const u8) bool {
    return if (service_tier) |value|
        std.ascii.eqlIgnoreCase(value, "priority") or std.ascii.eqlIgnoreCase(value, "fast")
    else
        false;
}

fn printRemoteFastMode(state: *const RemoteTuiState) void {
    std.debug.print("Fast mode is {s}.\n", .{if (remoteFastMode(state.effective_service_tier)) "on" else "off"});
}

fn parseRemoteSandboxState(allocator: std.mem.Allocator, value: std.json.Value) !RemoteParsedSandboxState {
    if (value == .string) {
        return .{
            .mode = config.SandboxMode.parse(value.string) catch return error.InvalidRemoteAppServerResponse,
        };
    }
    if (value != .object) return error.InvalidRemoteAppServerResponse;
    const type_value = value.object.get("type") orelse return error.InvalidRemoteAppServerResponse;
    if (type_value != .string) return error.InvalidRemoteAppServerResponse;
    if (std.mem.eql(u8, type_value.string, "workspaceWrite")) {
        return .{
            .mode = .workspace_write,
            .workspace_sandbox = try parseRemoteWorkspaceSandbox(allocator, value.object),
        };
    }
    if (std.mem.eql(u8, type_value.string, "readOnly")) return .{ .mode = .read_only };
    if (std.mem.eql(u8, type_value.string, "dangerFullAccess")) return .{ .mode = .danger_full_access };
    if (std.mem.eql(u8, type_value.string, "externalSandbox")) return .{ .mode = .danger_full_access };
    return error.InvalidRemoteAppServerResponse;
}

fn parseRemoteWorkspaceSandbox(allocator: std.mem.Allocator, object: std.json.ObjectMap) !RemoteEffectiveWorkspaceSandbox {
    return .{
        .writable_roots = try parseRemoteWorkspaceWritableRoots(allocator, object),
        .network_enabled = try parseRemoteWorkspaceSandboxBool(object, "networkAccess"),
        .exclude_tmpdir_env_var = try parseRemoteWorkspaceSandboxBool(object, "excludeTmpdirEnvVar"),
        .exclude_slash_tmp = try parseRemoteWorkspaceSandboxBool(object, "excludeSlashTmp"),
    };
}

fn parseRemoteWorkspaceWritableRoots(allocator: std.mem.Allocator, object: std.json.ObjectMap) !config.StringList {
    const value = object.get("writableRoots") orelse return .{ .items = try allocator.alloc([]const u8, 0) };
    if (value == .null) return .{ .items = try allocator.alloc([]const u8, 0) };
    if (value != .array) return error.InvalidRemoteAppServerResponse;

    const items = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(items);
    var copied: usize = 0;
    errdefer {
        for (items[0..copied]) |item| allocator.free(item);
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .string or !std.fs.path.isAbsolute(item.string)) return error.InvalidRemoteAppServerResponse;
        items[index] = try allocator.dupe(u8, item.string);
        copied += 1;
    }
    return .{ .items = items };
}

fn parseRemoteWorkspaceSandboxBool(object: std.json.ObjectMap, field: []const u8) !bool {
    const value = object.get(field) orelse return false;
    if (value == .null) return false;
    if (value != .bool) return error.InvalidRemoteAppServerResponse;
    return value.bool;
}

fn handleRemotePersonality(overrides: *config.RuntimeOverrides, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printPersonalityStatus(overrides.personality);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "list")) {
        printPersonalityList(overrides.personality);
        return;
    }
    const personality = config.Personality.parse(trimmed) catch {
        std.debug.print("unknown personality: {s}\n", .{trimmed});
        printPersonalityUsage();
        return;
    };
    overrides.personality = personality;
    printPersonalityStatus(overrides.personality);
}

fn handleRemoteApproval(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    try updateRemoteApprovalOverride(overrides, args);
    printRemoteApproval(overrides.approval_policy);
}

fn handleRemoteSandbox(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    try updateRemoteSandboxOverride(overrides, args);
    printRemoteSandbox(overrides.sandbox_mode);
}

fn handleRemotePermissions(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    try updateRemotePermissionsOverrides(overrides, args);
    printRemotePermissions(overrides.*);
}

fn updateRemoteApprovalOverride(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) return;
    overrides.approval_policy = try config.ApprovalPolicy.parse(trimmed);
}

fn updateRemoteSandboxOverride(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "status")) return;
    overrides.sandbox_mode = try config.SandboxMode.parse(trimmed);
}

fn updateRemotePermissionsOverrides(overrides: *config.RuntimeOverrides, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return;

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (tokens.next()) |token| {
        const update = try parsePermissionUpdate(token);
        switch (update) {
            .approval => |approval_policy| overrides.approval_policy = approval_policy,
            .sandbox => |sandbox_mode| overrides.sandbox_mode = sandbox_mode,
        }
    }
}

fn printRemoteApproval(approval_policy: ?config.ApprovalPolicy) void {
    std.debug.print("approval: {s}\n", .{if (approval_policy) |policy| policy.label() else "remote default"});
}

fn printRemoteSandbox(sandbox_mode: ?config.SandboxMode) void {
    std.debug.print("sandbox: {s}\n", .{if (sandbox_mode) |mode| mode.label() else "remote default"});
}

fn printRemotePermissions(overrides: config.RuntimeOverrides) void {
    std.debug.print(
        \\permissions:
        \\  approval: {s}
        \\  sandbox:  {s}
        \\usage: /permissions [approval=<mode>] [sandbox=<mode>]
        \\
    , .{
        if (overrides.approval_policy) |policy| policy.label() else "remote default",
        if (overrides.sandbox_mode) |mode| mode.label() else "remote default",
    });
}

fn printRemoteSessions(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    limit: usize,
) !void {
    const request = try renderRemoteThreadListRequest(allocator, limit);
    defer allocator.free(request);
    try transport.writeJson(request);

    var response = try readRemoteResponse(transport, "thread-list-picker");
    defer response.deinit();
    const sessions = try remoteThreadListItems(response.value);
    if (sessions.len == 0) {
        std.debug.print("remote sessions: none\n", .{});
        return;
    }

    std.debug.print("remote sessions:\n", .{});
    for (sessions, 0..) |entry, index| {
        try printRemoteSessionSummary(index, entry);
    }
}

fn switchRemoteThread(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    current_thread_id: *[]const u8,
    action: []const u8,
    method: []const u8,
    cwd: []const u8,
    state: *RemoteTuiState,
    stdin_reader: *std.Io.Reader,
    args: []const u8,
) !bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const target_owned = if (trimmed.len == 0)
        try promptRemoteSessionPickerWithReader(allocator, transport, action, false, stdin_reader)
    else if (std.mem.eql(u8, trimmed, "--all"))
        try promptRemoteSessionPickerWithReader(allocator, transport, action, true, stdin_reader)
    else
        try allocator.dupe(u8, trimmed);
    const target = target_owned orelse return false;
    defer allocator.free(target);

    const next_thread_id = try openRemoteLifecycleThread(allocator, transport, action, method, target, cwd, state);
    allocator.free(current_thread_id.*);
    current_thread_id.* = next_thread_id;
    return true;
}

fn openRemoteThread(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    cwd: []const u8,
    options: Options,
    state: *RemoteTuiState,
) !?[]const u8 {
    if (options.resume_picker) {
        const target = (try promptRemoteSessionPicker(allocator, transport, "resume", options.resume_show_all)) orelse {
            std.debug.print("resume canceled\n", .{});
            return null;
        };
        defer allocator.free(target);
        const thread_id = try openRemoteLifecycleThread(allocator, transport, "thread-resume", "thread/resume", target, cwd, state);
        return thread_id;
    }
    if (options.fork_picker) {
        const target = (try promptRemoteSessionPicker(allocator, transport, "fork", options.fork_show_all)) orelse {
            std.debug.print("fork canceled\n", .{});
            return null;
        };
        defer allocator.free(target);
        const thread_id = try openRemoteLifecycleThread(allocator, transport, "thread-fork", "thread/fork", target, cwd, state);
        return thread_id;
    }
    if (options.resume_target) |target| {
        const thread_id = try openRemoteLifecycleThread(allocator, transport, "thread-resume", "thread/resume", target, cwd, state);
        return thread_id;
    }
    if (options.fork_target) |target| {
        const thread_id = try openRemoteLifecycleThread(allocator, transport, "thread-fork", "thread/fork", target, cwd, state);
        return thread_id;
    }

    return try startRemoteThread(allocator, transport, cwd, state);
}

fn startRemoteThread(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    cwd: []const u8,
    state: *RemoteTuiState,
) ![]const u8 {
    const thread_start = try renderRemoteThreadStartRequest(allocator, cwd, state.overrides, state.service_tier_cleared);
    defer allocator.free(thread_start);
    try transport.writeJson(thread_start);
    var thread_response = try readRemoteResponse(transport, "thread-start");
    defer thread_response.deinit();
    try state.updateFromLifecycleResponse(allocator, thread_response.value);
    const thread_id_raw = try remoteNestedString(thread_response.value, &.{ "result", "thread", "id" });
    return try allocator.dupe(u8, thread_id_raw);
}

fn compactRemoteThread(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    thread_id: []const u8,
) !void {
    const request = try renderRemoteThreadCompactStartRequest(allocator, thread_id);
    defer allocator.free(request);
    try transport.writeJson(request);
    var response = try readRemoteResponse(transport, "thread-compact");
    response.deinit();
}

fn promptRemoteSessionPicker(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    action: []const u8,
    show_all: bool,
) !?[]const u8 {
    var input_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);
    return try promptRemoteSessionPickerWithReader(allocator, transport, action, show_all, &stdin_reader.interface);
}

fn promptRemoteSessionPickerWithReader(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    action: []const u8,
    show_all: bool,
    stdin_reader: *std.Io.Reader,
) !?[]const u8 {
    const limit: usize = if (show_all) 100 else 10;
    const request = try renderRemoteThreadListRequest(allocator, limit);
    defer allocator.free(request);
    try transport.writeJson(request);

    var response = try readRemoteResponse(transport, "thread-list-picker");
    defer response.deinit();
    const sessions = try remoteThreadListItems(response.value);
    if (sessions.len == 0) {
        std.debug.print("{s}: no saved remote sessions\n", .{action});
        return null;
    }

    std.debug.print("{s} sessions:\n", .{action});
    for (sessions, 0..) |entry, index| {
        try printRemoteSessionSummary(index, entry);
    }
    std.debug.print("Select session [1-{d}] or press Enter to cancel: ", .{sessions.len});

    const line_opt = try stdin_reader.takeDelimiter('\n');
    const line = line_opt orelse return null;
    const selection = try parseResumeSelection(line, sessions.len) orelse return null;
    const id = try remoteObjectString(sessions[selection], "id");
    const owned_id = try allocator.dupe(u8, id);
    return owned_id;
}

fn renderRemoteThreadListRequest(allocator: std.mem.Allocator, limit: usize) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"thread-list-picker\",\"method\":\"thread/list\",\"params\":{{\"limit\":{d},\"sortKey\":\"updated_at\",\"sortDirection\":\"desc\",\"modelProviders\":[]}}}}",
        .{limit},
    );
}

fn remoteThreadListItems(value: std.json.Value) ![]std.json.Value {
    if (value != .object) return error.InvalidRemoteAppServerResponse;
    const result = value.object.get("result") orelse return error.InvalidRemoteAppServerResponse;
    if (result != .object) return error.InvalidRemoteAppServerResponse;
    const data = result.object.get("data") orelse return error.InvalidRemoteAppServerResponse;
    if (data != .array) return error.InvalidRemoteAppServerResponse;
    return data.array.items;
}

fn printRemoteSessionSummary(index: usize, entry: std.json.Value) !void {
    const id = try remoteObjectString(entry, "id");
    const preview = remoteObjectOptionalString(entry, "preview") orelse "";
    const name = remoteObjectOptionalString(entry, "name");
    const path = remoteObjectOptionalString(entry, "path");

    if (name) |title| {
        std.debug.print("  {d}. {s} - {s}\n", .{ index + 1, id, title });
    } else {
        std.debug.print("  {d}. {s}\n", .{ index + 1, id });
    }
    if (preview.len > 0) std.debug.print("     {s}\n", .{preview});
    if (path) |session_path| std.debug.print("     {s}\n", .{session_path});
}

fn openRemoteLifecycleThread(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    request_id: []const u8,
    method: []const u8,
    target: []const u8,
    cwd: []const u8,
    state: *RemoteTuiState,
) ![]const u8 {
    const request = try renderRemoteThreadLifecycleRequest(allocator, request_id, method, target, cwd, state.overrides, state.service_tier_cleared);
    defer allocator.free(request);
    try transport.writeJson(request);
    var response = try readRemoteResponse(transport, request_id);
    defer response.deinit();
    try state.updateFromLifecycleResponse(allocator, response.value);
    const thread_id_raw = try remoteNestedString(response.value, &.{ "result", "thread", "id" });
    return allocator.dupe(u8, thread_id_raw);
}

fn validateRemoteTuiSupportedOptions(options: Options) !void {
    if (options.profile != null) return rejectUnsupportedRemoteTuiOption("--profile");
    if (options.oss) return rejectUnsupportedRemoteTuiOption("--oss");
    if (options.oss_provider != null) return rejectUnsupportedRemoteTuiOption("--local-provider");

    const overrides = options.runtime_overrides;
    if (overrides.openai_base_url != null) return rejectUnsupportedRemoteTuiOption("-c openai_base_url");
    if (overrides.chatgpt_base_url != null) return rejectUnsupportedRemoteTuiOption("-c chatgpt_base_url");
    if (overrides.oss_provider != null) return rejectUnsupportedRemoteTuiOption("-c oss_provider");
    if (overrides.web_search_mode != null) return rejectUnsupportedRemoteTuiOption("--search");
    if (overrides.syntax_theme != null) return rejectUnsupportedRemoteTuiOption("-c syntax_theme");
}

fn rejectUnsupportedRemoteTuiOption(option: []const u8) error{RemoteTuiUnsupportedOption} {
    std.debug.print("remote app-server TUI does not support `{s}` yet\n", .{option});
    return error.RemoteTuiUnsupportedOption;
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

fn renderRemoteThreadCompactStartRequest(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"thread-compact\",\"method\":\"thread/compact/start\",\"params\":{");
    var first = true;
    try appendJsonStringField(allocator, &out, &first, "threadId", thread_id);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn renderRemoteThreadStartRequest(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"thread-start\",\"method\":\"thread/start\",\"params\":{");
    var first = true;
    try appendJsonStringField(allocator, &out, &first, "cwd", cwd);
    try appendRemoteThreadRuntimeOverrides(allocator, &out, &first, overrides, service_tier_cleared, &.{}, null, null);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn renderRemoteThreadLifecycleRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    method: []const u8,
    target: []const u8,
    cwd: []const u8,
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const target_path = try remoteThreadTargetPath(allocator, cwd, target);
    defer if (target_path) |path| allocator.free(path);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonString(allocator, &out, request_id);
    try out.appendSlice(allocator, ",\"method\":");
    try appendJsonString(allocator, &out, method);
    try out.appendSlice(allocator, ",\"params\":{");
    var first = true;
    try appendJsonStringField(allocator, &out, &first, "threadId", target);
    if (target_path) |path| try appendJsonStringField(allocator, &out, &first, "path", path);
    try appendJsonStringField(allocator, &out, &first, "cwd", cwd);
    try appendJsonBoolField(allocator, &out, &first, "excludeTurns", true);
    try appendRemoteThreadRuntimeOverrides(allocator, &out, &first, overrides, service_tier_cleared, &.{}, null, null);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

fn appendRemoteThreadRuntimeOverrides(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
    additional_writable_roots: []const []const u8,
    effective_sandbox_mode: ?config.SandboxMode,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) !void {
    if (overrides.model) |model| try appendJsonStringField(allocator, out, first, "model", model);
    if (overrides.approval_policy) |policy| try appendJsonStringField(allocator, out, first, "approvalPolicy", policy.label());
    if (shouldSendRemoteSandboxPolicy(additional_writable_roots, overrides, effective_sandbox_mode, effective_workspace_sandbox)) {
        try appendRemoteSandboxPolicyField(allocator, out, first, additional_writable_roots, effective_workspace_sandbox);
    } else if (overrides.sandbox_mode) |sandbox| {
        try appendJsonStringField(allocator, out, first, "sandbox", sandbox.label());
    }
    if (overrides.service_tier) |service_tier| {
        try appendJsonStringField(allocator, out, first, "serviceTier", service_tier);
    } else if (service_tier_cleared) {
        try appendJsonNullField(allocator, out, first, "serviceTier");
    }
    if (overrides.personality) |personality| try appendJsonStringField(allocator, out, first, "personality", personality.label());
}

fn remoteThreadTargetLooksPath(target: []const u8) bool {
    return std.fs.path.isAbsolute(target) or
        std.mem.indexOfScalar(u8, target, '/') != null or
        std.mem.indexOfScalar(u8, target, '\\') != null;
}

fn remoteThreadTargetPath(allocator: std.mem.Allocator, cwd: []const u8, target: []const u8) !?[]const u8 {
    if (!remoteThreadTargetLooksPath(target)) return null;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidRemoteThreadPath;
    if (std.fs.path.isAbsolute(target)) return try allocator.dupe(u8, target);
    return try std.fs.path.join(allocator, &.{ cwd, target });
}

fn runRemotePrompt(
    allocator: std.mem.Allocator,
    transport: *RemoteTransport,
    thread_id: []const u8,
    prompt: []const u8,
    input_image_paths: []const []const u8,
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
    additional_writable_roots: []const []const u8,
    effective_sandbox_mode: ?config.SandboxMode,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) !void {
    const request = try renderRemoteTurnStartRequest(allocator, thread_id, prompt, input_image_paths, overrides, service_tier_cleared, additional_writable_roots, effective_sandbox_mode, effective_workspace_sandbox);
    defer allocator.free(request);

    std.debug.print("\nassistant:\n", .{});
    try transport.writeJson(request);

    var response = try readRemoteResponse(transport, "turn-start");
    defer response.deinit();
    const turn_id_raw = try remoteNestedString(response.value, &.{ "result", "turn", "id" });
    const turn_id = try allocator.dupe(u8, turn_id_raw);
    defer allocator.free(turn_id);

    try streamRemoteTurnUntilCompleted(transport, thread_id, turn_id);
}

fn renderRemoteTurnStartRequest(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    prompt: []const u8,
    input_image_paths: []const []const u8,
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
    additional_writable_roots: []const []const u8,
    effective_sandbox_mode: ?config.SandboxMode,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"turn-start\",\"method\":\"turn/start\",\"params\":{\"threadId\":");
    try appendJsonString(allocator, &out, thread_id);
    try out.appendSlice(allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
    try appendJsonString(allocator, &out, prompt);
    try out.appendSlice(allocator, "}");
    for (input_image_paths) |path| {
        try out.appendSlice(allocator, ",{\"type\":\"localImage\",\"path\":");
        try appendJsonString(allocator, &out, path);
        try out.appendSlice(allocator, "}");
    }
    try out.append(allocator, ']');
    try appendRemoteTurnRuntimeOverrides(allocator, &out, overrides, service_tier_cleared, additional_writable_roots, effective_sandbox_mode, effective_workspace_sandbox);
    try out.append(allocator, '}');
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendRemoteTurnRuntimeOverrides(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    overrides: config.RuntimeOverrides,
    service_tier_cleared: bool,
    additional_writable_roots: []const []const u8,
    effective_sandbox_mode: ?config.SandboxMode,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) !void {
    if (overrides.model) |model| try appendJsonStringFieldAfterExisting(allocator, out, "model", model);
    if (overrides.approval_policy) |policy| try appendJsonStringFieldAfterExisting(allocator, out, "approvalPolicy", policy.label());
    if (shouldSendRemoteSandboxPolicy(additional_writable_roots, overrides, effective_sandbox_mode, effective_workspace_sandbox)) {
        try appendRemoteSandboxPolicyFieldAfterExisting(allocator, out, additional_writable_roots, effective_workspace_sandbox);
    } else if (overrides.sandbox_mode) |sandbox| {
        try appendJsonStringFieldAfterExisting(allocator, out, "sandbox", sandbox.label());
    }
    if (overrides.service_tier) |service_tier| {
        try appendJsonStringFieldAfterExisting(allocator, out, "serviceTier", service_tier);
    } else if (service_tier_cleared) {
        try appendJsonNullFieldAfterExisting(allocator, out, "serviceTier");
    }
    if (overrides.model_reasoning_summary) |summary| {
        try appendJsonStringFieldAfterExisting(allocator, out, "summary", summary.label());
    }
    if (overrides.personality) |personality| try appendJsonStringFieldAfterExisting(allocator, out, "personality", personality.label());
}

fn shouldSendRemoteSandboxPolicy(
    additional_writable_roots: []const []const u8,
    overrides: config.RuntimeOverrides,
    effective_sandbox_mode: ?config.SandboxMode,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) bool {
    if (additional_writable_roots.len == 0) return false;
    if (overrides.sandbox_mode) |sandbox| return sandbox == .workspace_write;
    if (effective_sandbox_mode == null or effective_sandbox_mode.? != .workspace_write) return false;
    return remoteWorkspaceSandboxCanExtend(effective_workspace_sandbox);
}

fn remoteWorkspaceSandboxCanExtend(effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox) bool {
    if (effective_workspace_sandbox) |sandbox| return sandbox.canExtendWithWritableRoots();
    return true;
}

fn resolveRemoteAdditionalWritableRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    roots: []const []const u8,
) ![]const []const u8 {
    var resolved = try allocator.alloc([]const u8, roots.len);
    errdefer allocator.free(resolved);

    var count: usize = 0;
    errdefer {
        for (resolved[0..count]) |root| allocator.free(root);
    }

    for (roots) |root| {
        var owned_candidate: ?[]const u8 = null;
        defer if (owned_candidate) |candidate| allocator.free(candidate);

        const candidate = if (std.fs.path.isAbsolute(root))
            root
        else blk: {
            const joined = try std.fs.path.join(allocator, &.{ cwd, root });
            owned_candidate = joined;
            break :blk joined;
        };
        const real_path = try std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
        defer allocator.free(real_path);
        resolved[count] = try allocator.dupe(u8, real_path);
        count += 1;
    }

    return resolved;
}

fn freeRemoteAdditionalWritableRoots(allocator: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |root| allocator.free(root);
    allocator.free(roots);
}

fn appendRemoteSandboxPolicyFieldAfterExisting(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    additional_writable_roots: []const []const u8,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) !void {
    var first = false;
    try appendRemoteSandboxPolicyField(allocator, out, &first, additional_writable_roots, effective_workspace_sandbox);
}

fn appendRemoteSandboxPolicyField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    additional_writable_roots: []const []const u8,
    effective_workspace_sandbox: ?*const RemoteEffectiveWorkspaceSandbox,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try out.appendSlice(allocator, "\"sandboxPolicy\":{\"type\":\"workspaceWrite\",\"writableRoots\":[");
    var root_index: usize = 0;
    if (effective_workspace_sandbox) |sandbox| {
        if (sandbox.canExtendWithWritableRoots()) {
            for (sandbox.writable_roots.items) |root| {
                if (root_index > 0) try out.append(allocator, ',');
                try appendJsonString(allocator, out, root);
                root_index += 1;
            }
        }
    }
    for (additional_writable_roots) |root| {
        if (root_index > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, root);
        root_index += 1;
    }
    try out.appendSlice(allocator, "],\"networkAccess\":false,\"excludeTmpdirEnvVar\":false,\"excludeSlashTmp\":false}");
}

fn writeRemoteLine(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeAll(payload);
    try writer.writeByte('\n');
    try writer.flush();
}

fn connectRemoteWebSocket(io: std.Io, parts: RemoteUrlParts) !net.Stream {
    const host = remoteWebSocketConnectHost(parts.host);
    var address = remoteWebSocketAddress(host, parts.port) catch |err| {
        std.debug.print("remote websocket TUI supports literal IP hosts or localhost only: {s}\n", .{parts.host});
        return err;
    };
    return address.connect(io, .{ .mode = .stream });
}

fn remoteWebSocketConnectHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

fn remoteWebSocketAddress(host: []const u8, port: u16) !net.IpAddress {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        return .{ .ip4 = net.Ip4Address.loopback(port) };
    }
    return net.IpAddress.parse(host, port) catch return error.InvalidRemoteAddress;
}

fn performRemoteWebSocketHandshake(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    parts: RemoteUrlParts,
    remote_auth_token_env: ?[]const u8,
) !void {
    var nonce: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&nonce);
    var key_buffer: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buffer, &nonce);
    const auth_token = if (remote_auth_token_env) |env_name|
        try remoteAuthTokenFromEnv(allocator, env_name)
    else
        null;
    defer if (auth_token) |token| allocator.free(token);

    try writer.print(
        "GET / HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n",
        .{ parts.host, parts.port, key },
    );
    if (auth_token) |token| {
        try writer.print("Authorization: Bearer {s}\r\n", .{token});
    }
    try writer.writeAll("\r\n");
    try writer.flush();

    const response = try readRemoteHttpHeaderBlock(allocator, reader);
    defer allocator.free(response);
    if (!remoteWebSocketStatusIsSwitchingProtocols(response)) {
        std.debug.print("remote websocket handshake failed\n", .{});
        return error.RemoteWebSocketHandshakeFailed;
    }
    const expected_accept = try remoteWebSocketAcceptValue(allocator, key);
    defer allocator.free(expected_accept);
    const actual_accept = remoteHttpHeaderValue(response, "sec-websocket-accept") orelse {
        std.debug.print("remote websocket handshake missing Sec-WebSocket-Accept\n", .{});
        return error.RemoteWebSocketHandshakeFailed;
    };
    if (!std.mem.eql(u8, actual_accept, expected_accept)) {
        std.debug.print("remote websocket handshake returned invalid Sec-WebSocket-Accept\n", .{});
        return error.RemoteWebSocketHandshakeFailed;
    }
}

fn remoteAuthTokenFromEnv(allocator: std.mem.Allocator, env_name: []const u8) ![]const u8 {
    const raw = try getEnvVarOwned(allocator, env_name);
    defer if (raw) |value| allocator.free(value);
    const value = raw orelse return error.RemoteAuthTokenEnvNotSet;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.RemoteAuthTokenEnvEmpty;
    return allocator.dupe(u8, trimmed);
}

fn readRemoteHttpHeaderBlock(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    while (out.items.len < 64 * 1024) {
        const byte = try reader.takeByte();
        try out.append(allocator, byte);
        if (out.items.len >= 4 and std.mem.eql(u8, out.items[out.items.len - 4 ..], "\r\n\r\n")) {
            return out.toOwnedSlice(allocator);
        }
    }
    return error.RemoteWebSocketHandshakeTooLarge;
}

fn remoteWebSocketStatusIsSwitchingProtocols(response: []const u8) bool {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse return false;
    const status_line = response[0..line_end];
    return std.mem.startsWith(u8, status_line, "HTTP/") and std.mem.indexOf(u8, status_line, " 101 ") != null;
}

fn remoteHttpHeaderValue(response: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[separator + 1 ..], " \t");
    }
    return null;
}

fn remoteWebSocketAcceptValue(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, magic });
    defer allocator.free(combined);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});
    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, &digest);
    return encoded;
}

fn writeClientWebSocketTextFrame(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    payload: []const u8,
) !void {
    try writeClientWebSocketFrame(allocator, writer, 0x1, payload);
}

fn writeClientWebSocketFrame(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    opcode: u8,
    payload: []const u8,
) !void {
    var mask: [4]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&mask);
    const masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |byte, index| {
        masked[index] = byte ^ mask[index % mask.len];
    }

    try writer.writeByte(0x80 | (opcode & 0x0f));
    if (payload.len <= 125) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(0x80 | 126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(0x80 | 127);
        try writer.writeInt(u64, @intCast(payload.len), .big);
    }
    try writer.writeAll(&mask);
    try writer.writeAll(masked);
    try writer.flush();
}

fn readServerWebSocketTextFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !?[]u8 {
    while (true) {
        const first = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const second = try reader.takeByte();
        const fin = (first & 0x80) != 0;
        const opcode = first & 0x0f;
        const masked = (second & 0x80) != 0;
        var payload_len: u64 = second & 0x7f;
        if (payload_len == 126) {
            payload_len = try reader.takeInt(u16, .big);
        } else if (payload_len == 127) {
            payload_len = try reader.takeInt(u64, .big);
        }
        if (!fin) return error.UnsupportedWebSocketFragment;
        if (payload_len > remote_line_limit) return error.WebSocketFrameTooLarge;

        var zero_mask = [4]u8{ 0, 0, 0, 0 };
        const mask: *const [4]u8 = if (masked) try reader.takeArray(4) else &zero_mask;
        const payload = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(payload);
        try reader.readSliceAll(payload);
        if (masked) {
            for (payload, 0..) |*byte, index| {
                byte.* ^= mask[index % mask.len];
            }
        }

        switch (opcode) {
            0x1 => return payload,
            0x8 => {
                try writeClientWebSocketFrame(allocator, writer, 0x8, payload);
                allocator.free(payload);
                return null;
            },
            0x9 => {
                try writeClientWebSocketFrame(allocator, writer, 0xA, payload);
                allocator.free(payload);
                continue;
            },
            0xA => {
                allocator.free(payload);
                continue;
            },
            else => {
                allocator.free(payload);
                return error.UnsupportedWebSocketOpcode;
            },
        }
    }
}

fn readRemoteResponse(
    transport: *RemoteTransport,
    request_id: []const u8,
) !std.json.Parsed(std.json.Value) {
    var lines_read: usize = 0;
    while (lines_read < 512) : (lines_read += 1) {
        const line_raw = try transport.readMessage() orelse return error.RemoteAppServerClosed;
        defer transport.allocator.free(line_raw);
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        var parsed = try std.json.parseFromSlice(std.json.Value, transport.allocator, line, .{ .allocate = .alloc_always });
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
    transport: *RemoteTransport,
    thread_id: []const u8,
    turn_id: []const u8,
) !void {
    var saw_delta = false;
    while (true) {
        const line_raw = try transport.readMessage() orelse return error.RemoteAppServerClosed;
        defer transport.allocator.free(line_raw);
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        var parsed = try std.json.parseFromSlice(std.json.Value, transport.allocator, line, .{ .allocate = .alloc_always });
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
}

fn readRemoteLine(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    while (out.items.len < remote_line_limit) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (out.items.len == 0) return null;
                return try out.toOwnedSlice(allocator);
            },
            else => |e| return e,
        };
        if (byte == '\n') return try out.toOwnedSlice(allocator);
        try out.append(allocator, byte);
    }
    return error.RemoteAppServerLineTooLong;
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

fn remoteObjectString(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidRemoteAppServerResponse;
    const field = value.object.get(key) orelse return error.InvalidRemoteAppServerResponse;
    if (field != .string) return error.InvalidRemoteAppServerResponse;
    return field.string;
}

fn remoteObjectOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
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

fn appendJsonStringFieldAfterExisting(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    var first = false;
    try appendJsonStringField(allocator, out, &first, name, value);
}

fn appendJsonNullField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":null");
}

fn appendJsonNullFieldAfterExisting(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) !void {
    var first = false;
    try appendJsonNullField(allocator, out, &first, name);
}

fn appendJsonBoolField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: bool,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":");
    try out.appendSlice(allocator, if (value) "true" else "false");
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
    local_remote_server: *?local_remote_control.Server,
    remote_control_bind: ?[]const u8,
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

    if (std.ascii.eqlIgnoreCase(parts.name, "remote-control")) {
        try handleLocalRemoteControlSlash(allocator, local_remote_server, remote_control_bind, cwd, transcript, parts.args);
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
        var review_cfg = cfg.*;
        review_cfg.model = review.selectedModelForReview(cfg.model, cfg.review_model);
        try runPrompt(allocator, review_cfg, credentials, transcript, session_path.*, review_prompt, additional_writable_roots, &.{});
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

fn handleLocalRemoteControlSlash(
    allocator: std.mem.Allocator,
    server_opt: *?local_remote_control.Server,
    bind_arg: ?[]const u8,
    cwd: []const u8,
    transcript: *const session.Transcript,
    args: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "start")) {
        if (server_opt.*) |*server| {
            printLocalRemoteControlLinks(server);
            return;
        }

        const snapshot_json = try renderLocalRemoteControlSnapshotJson(allocator, cwd, transcript);
        errdefer allocator.free(snapshot_json);
        server_opt.* = try local_remote_control.start(allocator, bind_arg, snapshot_json);
        if (server_opt.*) |*server| printLocalRemoteControlLinks(server);
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "stop")) {
        if (server_opt.*) |*server| {
            server.deinit(allocator);
            server_opt.* = null;
        }
        std.debug.print("Remote control stopped.\n", .{});
        return;
    }

    std.debug.print("Usage: /remote-control [start|stop]\n", .{});
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
        \\  /remote-control [start|stop]
        \\                    manage local browser remote control
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
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, transcript, compactPromptForConfig(cfg), .{
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

fn compactPromptForConfig(cfg: config.Config) []const u8 {
    if (cfg.compact_prompt) |prompt| {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return compact_prompt;
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

    const remote_control = parseSlash("/remote-control stop").?;
    try std.testing.expectEqualStrings("remote-control", remote_control.name);
    try std.testing.expectEqualStrings("stop", remote_control.args);

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

test "compact prompt uses config override" {
    const default_cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    try std.testing.expectEqualStrings(compact_prompt, compactPromptForConfig(default_cfg));

    var custom_cfg = default_cfg;
    custom_cfg.compact_prompt = "Custom compact prompt.";
    try std.testing.expectEqualStrings("Custom compact prompt.", compactPromptForConfig(custom_cfg));

    var blank_cfg = default_cfg;
    blank_cfg.compact_prompt = " \n\t";
    try std.testing.expectEqualStrings(compact_prompt, compactPromptForConfig(blank_cfg));
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
    try std.testing.expectEqual(@as(u16, 4500), ws.port);

    const wss = try validateRemoteUrl("wss://example.com:443/");
    try std.testing.expectEqual(.wss, wss.scheme);
    try std.testing.expectEqualStrings("example.com", wss.host);
    try std.testing.expectEqual(@as(u16, 443), wss.port);

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
    try std.testing.expect(!remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://127.attacker.example:4500")));
    try std.testing.expect(!remoteUrlSupportsAuthToken(try validateRemoteUrl("ws://127.0.0.1.example:4500")));
}

test "remote TUI rejects unsupported local-only options" {
    try std.testing.expectError(error.RemoteTuiUnsupportedOption, validateRemoteTuiSupportedOptions(.{
        .profile = "work",
    }));
    try std.testing.expectError(error.RemoteTuiUnsupportedOption, validateRemoteTuiSupportedOptions(.{
        .runtime_overrides = .{ .web_search_mode = .live },
    }));
}

test "remote TUI resolves relative writable roots against cwd" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDir(io, "extra", .default_dir);

    const cwd = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const expected = try dir.dir.realPathFileAlloc(io, "extra", allocator);
    defer allocator.free(expected);

    const roots = [_][]const u8{"extra"};
    const resolved = try resolveRemoteAdditionalWritableRoots(allocator, io, cwd, &roots);
    defer freeRemoteAdditionalWritableRoots(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings(expected, resolved[0]);
}

test "remote TUI serializes supported runtime overrides" {
    const allocator = std.testing.allocator;
    const thread_start = try renderRemoteThreadStartRequest(allocator, "/tmp/work", .{
        .model = "gpt-remote",
        .approval_policy = .never,
        .sandbox_mode = .read_only,
        .service_tier = "flex",
        .personality = .friendly,
    }, false);
    defer allocator.free(thread_start);

    var parsed_thread = try std.json.parseFromSlice(std.json.Value, allocator, thread_start, .{});
    defer parsed_thread.deinit();
    const thread_params = parsed_thread.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("gpt-remote", thread_params.get("model").?.string);
    try std.testing.expectEqualStrings("never", thread_params.get("approvalPolicy").?.string);
    try std.testing.expectEqualStrings("read-only", thread_params.get("sandbox").?.string);
    try std.testing.expectEqualStrings("flex", thread_params.get("serviceTier").?.string);
    try std.testing.expectEqualStrings("friendly", thread_params.get("personality").?.string);

    const cleared_thread_start = try renderRemoteThreadStartRequest(allocator, "/tmp/work", .{}, true);
    defer allocator.free(cleared_thread_start);

    var parsed_cleared_thread = try std.json.parseFromSlice(std.json.Value, allocator, cleared_thread_start, .{});
    defer parsed_cleared_thread.deinit();
    const cleared_thread_params = parsed_cleared_thread.value.object.get("params").?.object;
    try std.testing.expect(cleared_thread_params.get("serviceTier").? == .null);

    const thread_compact = try renderRemoteThreadCompactStartRequest(allocator, "11111111-1111-4111-8111-111111111111");
    defer allocator.free(thread_compact);

    var parsed_compact = try std.json.parseFromSlice(std.json.Value, allocator, thread_compact, .{});
    defer parsed_compact.deinit();
    try std.testing.expectEqualStrings("thread/compact/start", parsed_compact.value.object.get("method").?.string);
    const compact_params = parsed_compact.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", compact_params.get("threadId").?.string);
    try std.testing.expect(compact_params.get("model") == null);
    try std.testing.expect(compact_params.get("serviceTier") == null);
    try std.testing.expect(compact_params.get("personality") == null);

    const thread_resume = try renderRemoteThreadLifecycleRequest(allocator, "thread-resume", "thread/resume", "/tmp/rollout.jsonl", "/tmp/work", .{
        .model = "gpt-resume",
        .sandbox_mode = .workspace_write,
    }, false);
    defer allocator.free(thread_resume);

    var parsed_resume = try std.json.parseFromSlice(std.json.Value, allocator, thread_resume, .{});
    defer parsed_resume.deinit();
    try std.testing.expectEqualStrings("thread/resume", parsed_resume.value.object.get("method").?.string);
    const resume_params = parsed_resume.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("/tmp/rollout.jsonl", resume_params.get("threadId").?.string);
    try std.testing.expectEqualStrings("/tmp/rollout.jsonl", resume_params.get("path").?.string);
    try std.testing.expectEqualStrings("/tmp/work", resume_params.get("cwd").?.string);
    try std.testing.expect(resume_params.get("excludeTurns").?.bool);
    try std.testing.expectEqualStrings("gpt-resume", resume_params.get("model").?.string);
    try std.testing.expectEqualStrings("workspace-write", resume_params.get("sandbox").?.string);

    const thread_resume_relative = try renderRemoteThreadLifecycleRequest(allocator, "thread-resume", "thread/resume", "./rollout.jsonl", "/tmp/work", .{}, false);
    defer allocator.free(thread_resume_relative);

    var parsed_resume_relative = try std.json.parseFromSlice(std.json.Value, allocator, thread_resume_relative, .{});
    defer parsed_resume_relative.deinit();
    const resume_relative_params = parsed_resume_relative.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("./rollout.jsonl", resume_relative_params.get("threadId").?.string);
    try std.testing.expectEqualStrings("/tmp/work/./rollout.jsonl", resume_relative_params.get("path").?.string);

    const thread_fork = try renderRemoteThreadLifecycleRequest(allocator, "thread-fork", "thread/fork", "11111111-1111-4111-8111-111111111111", "/tmp/work", .{}, false);
    defer allocator.free(thread_fork);

    var parsed_fork = try std.json.parseFromSlice(std.json.Value, allocator, thread_fork, .{});
    defer parsed_fork.deinit();
    const fork_params = parsed_fork.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", fork_params.get("threadId").?.string);
    try std.testing.expect(fork_params.get("path") == null);
    try std.testing.expect(fork_params.get("excludeTurns").?.bool);

    const images = [_][]const u8{"/tmp/image.png"};
    const extra_roots = [_][]const u8{"/tmp/extra-writable"};
    const turn_start = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &images, .{
        .model = "gpt-turn",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .service_tier = "priority",
        .model_reasoning_summary = .concise,
        .personality = .pragmatic,
    }, false, &extra_roots, null, null);
    defer allocator.free(turn_start);

    var parsed_turn = try std.json.parseFromSlice(std.json.Value, allocator, turn_start, .{});
    defer parsed_turn.deinit();
    const turn_params = parsed_turn.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("gpt-turn", turn_params.get("model").?.string);
    try std.testing.expectEqualStrings("on-request", turn_params.get("approvalPolicy").?.string);
    const sandbox_policy = turn_params.get("sandboxPolicy").?.object;
    try std.testing.expectEqualStrings("workspaceWrite", sandbox_policy.get("type").?.string);
    try std.testing.expectEqualStrings("/tmp/extra-writable", sandbox_policy.get("writableRoots").?.array.items[0].string);
    try std.testing.expect(!sandbox_policy.get("networkAccess").?.bool);
    try std.testing.expect(!sandbox_policy.get("excludeTmpdirEnvVar").?.bool);
    try std.testing.expect(!sandbox_policy.get("excludeSlashTmp").?.bool);
    try std.testing.expect(turn_params.get("sandbox") == null);
    try std.testing.expectEqualStrings("priority", turn_params.get("serviceTier").?.string);
    try std.testing.expectEqualStrings("concise", turn_params.get("summary").?.string);
    try std.testing.expectEqualStrings("pragmatic", turn_params.get("personality").?.string);
    const input_items = turn_params.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input_items.len);
    try std.testing.expectEqualStrings("/tmp/image.png", input_items[1].object.get("path").?.string);

    const effective_workspace_turn = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{}, false, &extra_roots, .workspace_write, null);
    defer allocator.free(effective_workspace_turn);

    var parsed_effective_workspace = try std.json.parseFromSlice(std.json.Value, allocator, effective_workspace_turn, .{});
    defer parsed_effective_workspace.deinit();
    const effective_workspace_params = parsed_effective_workspace.value.object.get("params").?.object;
    try std.testing.expect(effective_workspace_params.get("sandboxPolicy") != null);
    try std.testing.expect(effective_workspace_params.get("sandbox") == null);

    const existing_root_items = try allocator.alloc([]const u8, 1);
    existing_root_items[0] = try allocator.dupe(u8, "/tmp/existing-writable");
    var existing_workspace_sandbox = RemoteEffectiveWorkspaceSandbox{
        .writable_roots = .{ .items = existing_root_items },
    };
    defer existing_workspace_sandbox.deinit(allocator);
    const merged_workspace_turn = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{}, false, &extra_roots, .workspace_write, &existing_workspace_sandbox);
    defer allocator.free(merged_workspace_turn);

    var parsed_merged_workspace = try std.json.parseFromSlice(std.json.Value, allocator, merged_workspace_turn, .{});
    defer parsed_merged_workspace.deinit();
    const merged_workspace_params = parsed_merged_workspace.value.object.get("params").?.object;
    const merged_roots = merged_workspace_params.get("sandboxPolicy").?.object.get("writableRoots").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), merged_roots.len);
    try std.testing.expectEqualStrings("/tmp/existing-writable", merged_roots[0].string);
    try std.testing.expectEqualStrings("/tmp/extra-writable", merged_roots[1].string);

    const network_root_items = try allocator.alloc([]const u8, 1);
    network_root_items[0] = try allocator.dupe(u8, "/tmp/network-writable");
    var network_workspace_sandbox = RemoteEffectiveWorkspaceSandbox{
        .writable_roots = .{ .items = network_root_items },
        .network_enabled = true,
    };
    defer network_workspace_sandbox.deinit(allocator);
    const unsupported_workspace_turn = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{}, false, &extra_roots, .workspace_write, &network_workspace_sandbox);
    defer allocator.free(unsupported_workspace_turn);

    var parsed_unsupported_workspace = try std.json.parseFromSlice(std.json.Value, allocator, unsupported_workspace_turn, .{});
    defer parsed_unsupported_workspace.deinit();
    const unsupported_workspace_params = parsed_unsupported_workspace.value.object.get("params").?.object;
    try std.testing.expect(unsupported_workspace_params.get("sandboxPolicy") == null);
    try std.testing.expect(unsupported_workspace_params.get("sandbox") == null);

    const effective_read_only_turn = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{}, false, &extra_roots, .read_only, null);
    defer allocator.free(effective_read_only_turn);

    var parsed_effective_read_only = try std.json.parseFromSlice(std.json.Value, allocator, effective_read_only_turn, .{});
    defer parsed_effective_read_only.deinit();
    const effective_read_only_params = parsed_effective_read_only.value.object.get("params").?.object;
    try std.testing.expect(effective_read_only_params.get("sandboxPolicy") == null);
    try std.testing.expect(effective_read_only_params.get("sandbox") == null);

    const explicit_read_only_turn = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{
        .sandbox_mode = .read_only,
    }, false, &extra_roots, .workspace_write, null);
    defer allocator.free(explicit_read_only_turn);

    var parsed_explicit_read_only = try std.json.parseFromSlice(std.json.Value, allocator, explicit_read_only_turn, .{});
    defer parsed_explicit_read_only.deinit();
    const explicit_read_only_params = parsed_explicit_read_only.value.object.get("params").?.object;
    try std.testing.expect(explicit_read_only_params.get("sandboxPolicy") == null);
    try std.testing.expectEqualStrings("read-only", explicit_read_only_params.get("sandbox").?.string);

    const turn_clear_service_tier = try renderRemoteTurnStartRequest(allocator, "thread-1", "hello", &.{}, .{}, true, &.{}, null, null);
    defer allocator.free(turn_clear_service_tier);

    var parsed_turn_clear = try std.json.parseFromSlice(std.json.Value, allocator, turn_clear_service_tier, .{});
    defer parsed_turn_clear.deinit();
    const turn_clear_params = parsed_turn_clear.value.object.get("params").?.object;
    try std.testing.expect(turn_clear_params.get("serviceTier").? == .null);

    const resume_clear_service_tier = try renderRemoteThreadLifecycleRequest(allocator, "thread-resume", "thread/resume", "/tmp/rollout.jsonl", "/tmp/work", .{}, true);
    defer allocator.free(resume_clear_service_tier);

    var parsed_resume_clear = try std.json.parseFromSlice(std.json.Value, allocator, resume_clear_service_tier, .{});
    defer parsed_resume_clear.deinit();
    const resume_clear_params = parsed_resume_clear.value.object.get("params").?.object;
    try std.testing.expect(resume_clear_params.get("serviceTier").? == .null);
}

test "remote TUI slash permissions update runtime overrides" {
    var overrides = config.RuntimeOverrides{};

    try updateRemoteApprovalOverride(&overrides, "on-request");
    try std.testing.expectEqual(config.ApprovalPolicy.on_request, overrides.approval_policy.?);

    try updateRemoteSandboxOverride(&overrides, "workspace-write");
    try std.testing.expectEqual(config.SandboxMode.workspace_write, overrides.sandbox_mode.?);

    try updateRemotePermissionsOverrides(&overrides, "approval=never sandbox=read-only");
    try std.testing.expectEqual(config.ApprovalPolicy.never, overrides.approval_policy.?);
    try std.testing.expectEqual(config.SandboxMode.read_only, overrides.sandbox_mode.?);

    try std.testing.expectError(error.InvalidApprovalPolicy, updateRemoteApprovalOverride(&overrides, "bogus"));
    try std.testing.expectError(error.InvalidSandboxMode, updateRemoteSandboxOverride(&overrides, "bogus"));
    try std.testing.expectError(error.InvalidPermissionsArgument, updateRemotePermissionsOverrides(&overrides, "mode=bogus"));
}

test "remote TUI waits past many ignored notifications" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    for (0..1030) |_| {
        try input.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}\n");
    }
    try input.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"delta\":\"done\"}}\n");
    try input.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}\n");

    var reader: std.Io.Reader = .fixed(input.items);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var transport = RemoteTransport{
        .allocator = allocator,
        .kind = .jsonl,
        .reader = &reader,
        .writer = &output.writer,
    };
    try streamRemoteTurnUntilCompleted(&transport, "thread-1", "turn-1");
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
