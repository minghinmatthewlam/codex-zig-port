const std = @import("std");

const net = std.Io.net;

const cli_utils = @import("cli_utils.zig");

const default_listen_url = "ws://127.0.0.1:0";

const Transport = union(enum) {
    stdio,
    websocket,
};

const ParsedOptions = struct {
    help: bool = false,
    listen: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    executor_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const StdioServer = struct {
    allocator: std.mem.Allocator,
    initialized: bool = false,
    session_id: ?[]const u8 = null,

    fn deinit(self: *StdioServer) void {
        if (self.session_id) |value| self.allocator.free(value);
    }

    fn run(self: *StdioServer) !void {
        var input_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

        while (true) {
            const line_opt = try stdin_reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            const response = self.handleLine(trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[exec-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStdoutLine(payload);
            }
        }
    }

    fn handleLine(self: *StdioServer, line: []const u8) !?[]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            return try renderJsonRpcError(self.allocator, null, -32700, "Parse error");
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return try renderJsonRpcError(self.allocator, null, -32600, "Invalid Request");
        }

        const object = parsed.value.object;
        const id_value = object.get("id");
        const method_value = object.get("method") orelse {
            if (object.get("result") != null or object.get("error") != null) return null;
            return try renderJsonRpcError(self.allocator, id_value, -32600, "Invalid Request");
        };
        if (method_value != .string) {
            return try renderJsonRpcError(self.allocator, id_value, -32600, "Invalid Request");
        }

        const method = method_value.string;
        if (id_value == null) {
            if (std.mem.eql(u8, method, "initialized")) return null;
            return null;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            return try self.handleInitialize(id_value.?, object.get("params"));
        }

        const message = try std.fmt.allocPrint(self.allocator, "exec-server stub does not implement `{s}` yet", .{method});
        defer self.allocator.free(message);
        return try renderJsonRpcError(self.allocator, id_value, -32601, message);
    }

    fn handleInitialize(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (self.initialized) {
            return try renderJsonRpcError(self.allocator, id_value, -32600, "initialize may only be sent once per connection");
        }
        const resume_session_id = parseInitializeParams(params_value) catch {
            return try renderJsonRpcError(self.allocator, id_value, -32602, "initialize params must include clientName");
        };
        if (resume_session_id) |session_id| {
            const message = try std.fmt.allocPrint(self.allocator, "unknown session id {s}", .{session_id});
            defer self.allocator.free(message);
            return try renderJsonRpcError(self.allocator, id_value, -32600, message);
        }

        self.session_id = try generateUuidString(self.allocator);
        self.initialized = true;

        const result = try renderInitializeResult(self.allocator, self.session_id.?);
        defer self.allocator.free(result);
        return try renderJsonRpcResult(self.allocator, id_value, result);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const parsed = parseArgs(args) catch |err| switch (err) {
        error.MissingExecServerListenUrl => return fail(allocator, "error: --listen requires a URL\n", .{}),
        error.MissingExecServerRemoteUrl => return fail(allocator, "error: --remote requires a URL\n", .{}),
        error.MissingExecServerExecutorIdOption => return fail(allocator, "error: --executor-id requires an ID\n", .{}),
        error.MissingExecServerNameOption => return fail(allocator, "error: --name requires a value\n", .{}),
        error.ConflictingExecServerOptions => return fail(allocator, "error: --listen cannot be combined with --remote\n", .{}),
        error.MissingExecServerExecutorId => return fail(allocator, "error: --executor-id is required when --remote is set\n", .{}),
        error.UnknownExecServerOption => return fail(allocator, "error: unknown exec-server option\n", .{}),
        error.UnexpectedExecServerArgument => return fail(allocator, "error: unexpected exec-server argument\n", .{}),
    };

    if (parsed.help) {
        printHelp();
        return;
    }

    if (parsed.remote != null) {
        return fail(allocator, "codex-zig exec-server remote registration is parsed but not implemented yet\n", .{});
    }

    const listen_url = parsed.listen orelse default_listen_url;
    const transport = parseListenUrl(listen_url) catch |err| switch (err) {
        error.UnsupportedExecServerListenUrl => return fail(
            allocator,
            "unsupported --listen URL `{s}`; expected `ws://IP:PORT` or `stdio`\n",
            .{listen_url},
        ),
        error.InvalidExecServerWebSocketListenUrl => return fail(
            allocator,
            "invalid websocket --listen URL `{s}`; expected `ws://IP:PORT`\n",
            .{listen_url},
        ),
    };

    switch (transport) {
        .stdio => {
            var server = StdioServer{ .allocator = allocator };
            defer server.deinit();
            try server.run();
        },
        .websocket => return fail(
            allocator,
            "codex-zig exec-server websocket listen transport is parsed but not implemented yet; use --listen stdio\n",
            .{},
        ),
    }
}

fn parseArgs(args: *std.process.Args.Iterator) !ParsedOptions {
    var parsed = ParsedOptions{};

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--listen")) {
            parsed.listen = args.next() orelse return error.MissingExecServerListenUrl;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            parsed.listen = arg["--listen=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            parsed.remote = args.next() orelse return error.MissingExecServerRemoteUrl;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            parsed.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--executor-id")) {
            parsed.executor_id = args.next() orelse return error.MissingExecServerExecutorIdOption;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--executor-id=")) {
            parsed.executor_id = arg["--executor-id=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            parsed.name = args.next() orelse return error.MissingExecServerNameOption;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            parsed.name = arg["--name=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownExecServerOption;
        return error.UnexpectedExecServerArgument;
    }

    if (parsed.listen != null and parsed.remote != null) return error.ConflictingExecServerOptions;
    if (parsed.remote != null and parsed.executor_id == null) return error.MissingExecServerExecutorId;
    return parsed;
}

fn parseListenUrl(value: []const u8) !Transport {
    if (std.mem.eql(u8, value, "stdio") or std.mem.eql(u8, value, "stdio://")) return .stdio;

    if (std.mem.startsWith(u8, value, "ws://")) {
        const address = value["ws://".len..];
        const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidExecServerWebSocketListenUrl;
        const host = address[0..colon];
        const port_text = address[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.InvalidExecServerWebSocketListenUrl;
        const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidExecServerWebSocketListenUrl;
        _ = net.IpAddress.parse(host, port) catch return error.InvalidExecServerWebSocketListenUrl;
        return .websocket;
    }

    return error.UnsupportedExecServerListenUrl;
}

fn parseInitializeParams(params_value: ?std.json.Value) !?[]const u8 {
    const params = params_value orelse return error.InvalidExecServerInitializeParams;
    if (params != .object) return error.InvalidExecServerInitializeParams;
    const client_name = params.object.get("clientName") orelse return error.InvalidExecServerInitializeParams;
    if (client_name != .string) return error.InvalidExecServerInitializeParams;
    if (params.object.get("resumeSessionId")) |resume_value| {
        if (resume_value == .null) return null;
        if (resume_value != .string) return error.InvalidExecServerInitializeParams;
        return resume_value.string;
    }
    return null;
}

fn renderInitializeResult(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const session_id_json = try std.json.Stringify.valueAlloc(allocator, session_id, .{});
    defer allocator.free(session_id_json);
    return std.fmt.allocPrint(allocator, "{{\"sessionId\":{s}}}", .{session_id_json});
}

fn renderJsonRpcResult(allocator: std.mem.Allocator, id_value: std.json.Value, result_json: []const u8) ![]const u8 {
    const id_json = try std.json.Stringify.valueAlloc(allocator, id_value, .{});
    defer allocator.free(id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn renderJsonRpcError(allocator: std.mem.Allocator, id_value: ?std.json.Value, code: i64, message: []const u8) ![]const u8 {
    const id_json = if (id_value) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_json);
    const message_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(message_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json, code, message_json },
    );
}

fn generateUuidString(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 36);
    var out_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            out[out_index] = '-';
            out_index += 1;
        }
        out[out_index] = hex[byte >> 4];
        out[out_index + 1] = hex[byte & 0x0f];
        out_index += 2;
    }
    return out;
}

fn writeStdoutLine(payload: []const u8) !void {
    try cli_utils.writeStdout(payload);
    try cli_utils.writeStdout("\n");
}

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try cli_utils.writeStderr(message);
    return error.ExecServerCommandFailed;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig exec-server [--listen URL]
        \\  codex-zig exec-server --remote URL --executor-id ID [--name NAME]
        \\
        \\Transport endpoint URL values match Rust Codex: `ws://IP:PORT`, `stdio`, or `stdio://`.
        \\The current Zig parity slice implements the stdio JSON-RPC initialize handshake.
        \\
    , .{});
}

test "exec server parses listen transports" {
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio"));
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio://"));
    try std.testing.expectEqual(Transport.websocket, try parseListenUrl("ws://127.0.0.1:0"));
    try std.testing.expectError(error.UnsupportedExecServerListenUrl, parseListenUrl("http://127.0.0.1:0"));
    try std.testing.expectError(error.InvalidExecServerWebSocketListenUrl, parseListenUrl("ws://127.0.0.1"));
    try std.testing.expectError(error.InvalidExecServerWebSocketListenUrl, parseListenUrl("ws://127.0.0.1:not-a-port"));
}

test "exec server initialize result is Rust-shaped" {
    const allocator = std.testing.allocator;
    const result = try renderInitializeResult(allocator, "11111111-1111-4111-8111-111111111111");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"sessionId\":\"11111111-1111-4111-8111-111111111111\"}", result);
}

test "exec server validates initialize params" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"clientName\":\"smoke\",\"resumeSessionId\":null}", .{});
    defer parsed.deinit();
    try std.testing.expect(try parseInitializeParams(parsed.value) == null);

    var resume_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"clientName\":\"smoke\",\"resumeSessionId\":\"session-1\"}", .{});
    defer resume_params.deinit();
    try std.testing.expectEqualStrings("session-1", (try parseInitializeParams(resume_params.value)).?);

    var missing = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.InvalidExecServerInitializeParams, parseInitializeParams(missing.value));
}
