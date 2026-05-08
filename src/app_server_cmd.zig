const std = @import("std");

const cli_utils = @import("cli_utils.zig");

pub const DEFAULT_LISTEN_URL = "stdio://";

const WebSocketListen = struct {
    host: []const u8,
    port: u16,
};

const Transport = union(enum) {
    stdio,
    off,
    unix_default,
    unix_path: []const u8,
    websocket: WebSocketListen,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var listen_url: []const u8 = DEFAULT_LISTEN_URL;
    var subcommand: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--listen")) {
            listen_url = args.next() orelse return error.MissingAppServerListenValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            listen_url = arg["--listen=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownAppServerOption;
        }
        if (subcommand != null) return error.UnexpectedAppServerArgument;
        subcommand = arg;
    }

    if (subcommand) |name| {
        if (std.mem.eql(u8, name, "proxy")) return error.AppServerProxyNotImplemented;
        if (std.mem.eql(u8, name, "generate-ts")) return error.AppServerGenerateTsNotImplemented;
        if (std.mem.eql(u8, name, "generate-json-schema")) return error.AppServerGenerateJsonSchemaNotImplemented;
        return error.UnknownAppServerSubcommand;
    }

    const transport = parseTransport(listen_url) catch |err| {
        const message = try std.fmt.allocPrint(
            allocator,
            "unsupported --listen URL '{s}', expected `stdio://`, `unix://`, `unix://PATH`, `ws://IP:PORT`, or `off`\n",
            .{listen_url},
        );
        defer allocator.free(message);
        try cli_utils.writeStderr(message);
        return err;
    };

    switch (transport) {
        .stdio => {
            var server = StdioServer{ .allocator = allocator };
            try server.run();
        },
        .off => try cli_utils.writeStdout("app-server transport: off\n"),
        .unix_default, .unix_path, .websocket => {
            const label = try formatTransportLabel(allocator, transport);
            defer allocator.free(label);
            const message = try std.fmt.allocPrint(
                allocator,
                "app-server listen transport is parsed but not implemented yet: {s}\n",
                .{label},
            );
            defer allocator.free(message);
            try cli_utils.writeStderr(message);
            return error.AppServerListenTransportNotImplemented;
        },
    }
}

fn parseTransport(value: []const u8) !Transport {
    if (std.mem.eql(u8, value, "stdio://")) return .stdio;
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "unix://")) return .unix_default;
    if (std.mem.startsWith(u8, value, "unix://")) {
        const path = value["unix://".len..];
        if (path.len == 0) return error.UnsupportedAppServerListenUrl;
        return .{ .unix_path = path };
    }
    if (std.mem.startsWith(u8, value, "ws://")) {
        const address = value["ws://".len..];
        const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.UnsupportedAppServerListenUrl;
        const host = address[0..colon];
        const port_text = address[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.UnsupportedAppServerListenUrl;
        const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.UnsupportedAppServerListenUrl;
        return .{ .websocket = .{ .host = host, .port = port } };
    }
    return error.UnsupportedAppServerListenUrl;
}

fn formatTransportLabel(allocator: std.mem.Allocator, transport: Transport) ![]const u8 {
    return switch (transport) {
        .stdio => allocator.dupe(u8, "stdio://"),
        .off => allocator.dupe(u8, "off"),
        .unix_default => allocator.dupe(u8, "unix://"),
        .unix_path => |path| std.fmt.allocPrint(allocator, "unix://{s}", .{path}),
        .websocket => |address| std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ address.host, address.port }),
    };
}

const StdioServer = struct {
    allocator: std.mem.Allocator,

    fn run(self: *StdioServer) !void {
        var input_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

        while (true) {
            const line_opt = try stdin_reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            self.handleLine(trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[app-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
            };
        }
    }

    fn handleLine(self: *StdioServer, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try self.writeError(null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try self.writeError(null, -32600, "Invalid Request");
            return;
        }

        const object = parsed.value.object;
        const id_value = object.get("id");
        const method_value = object.get("method") orelse {
            try self.writeError(id_value, -32600, "Invalid Request");
            return;
        };
        if (method_value != .string) {
            try self.writeError(id_value, -32600, "Invalid Request");
            return;
        }
        if (id_value == null) return;

        const method = method_value.string;
        if (std.mem.eql(u8, method, "initialize")) {
            const result = try renderInitializeResult(self.allocator);
            defer self.allocator.free(result);
            try self.writeResult(id_value.?, result);
            return;
        }

        const message = try std.fmt.allocPrint(self.allocator, "unsupported app-server method: {s}", .{method});
        defer self.allocator.free(message);
        try self.writeError(id_value, -32601, message);
    }

    fn writeResult(self: *StdioServer, id_value: std.json.Value, result_json: []const u8) !void {
        const id_json = try std.json.Stringify.valueAlloc(self.allocator, id_value, .{});
        defer self.allocator.free(id_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_json, result_json },
        );
        defer self.allocator.free(payload);
        try writeLine(payload);
    }

    fn writeError(self: *StdioServer, id_value: ?std.json.Value, code: i64, message: []const u8) !void {
        const id_json = if (id_value) |value|
            try std.json.Stringify.valueAlloc(self.allocator, value, .{})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(id_json);
        const message_json = try std.json.Stringify.valueAlloc(self.allocator, message, .{});
        defer self.allocator.free(message_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
            .{ id_json, code, message_json },
        );
        defer self.allocator.free(payload);
        try writeLine(payload);
    }
};

fn renderInitializeResult(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(
        u8,
        "{\"serverInfo\":{\"name\":\"codex-zig-app-server\",\"version\":\"0.0.1\"},\"capabilities\":{}}",
    );
}

fn writeLine(payload: []const u8) !void {
    try cli_utils.writeStdout(payload);
    try cli_utils.writeStdout("\n");
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn printHelp() void {
    std.debug.print(
        \\Usage: codex-zig app-server [--listen URL]
        \\
        \\Runs the app-server JSON-RPC transport.
        \\
        \\Options:
        \\  --listen URL           Transport URL. Defaults to stdio://.
        \\
        \\Supported URL forms:
        \\  stdio://               Read and write newline-delimited JSON-RPC on stdio
        \\  off                    Disable the app-server transport
        \\  unix://                Parse the default Unix socket transport
        \\  unix://PATH            Parse a Unix socket transport path
        \\  ws://IP:PORT           Parse a websocket transport address
        \\
        \\The Zig port currently implements stdio:// and off.
        \\
    , .{});
}

test "app-server transport parser accepts Rust listen URL forms" {
    try std.testing.expectEqual(.stdio, try parseTransport("stdio://"));
    try std.testing.expectEqual(.off, try parseTransport("off"));
    try std.testing.expectEqual(.unix_default, try parseTransport("unix://"));

    const unix_path = try parseTransport("unix:///tmp/codex.sock");
    try std.testing.expectEqualStrings("/tmp/codex.sock", unix_path.unix_path);

    const websocket = try parseTransport("ws://127.0.0.1:3456");
    try std.testing.expectEqualStrings("127.0.0.1", websocket.websocket.host);
    try std.testing.expectEqual(@as(u16, 3456), websocket.websocket.port);
}

test "app-server transport parser rejects unsupported listen URLs" {
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("http://127.0.0.1:8000"));
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("ws://127.0.0.1"));
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("ws://127.0.0.1:not-a-port"));
}

test "app-server initialize result exposes server info" {
    const allocator = std.testing.allocator;
    const result = try renderInitializeResult(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"codex-zig-app-server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"capabilities\":{}") != null);
}

test "app-server transport labels preserve configured listen URL" {
    const allocator = std.testing.allocator;
    const unix_path = try formatTransportLabel(allocator, try parseTransport("unix:///tmp/codex.sock"));
    defer allocator.free(unix_path);
    try std.testing.expectEqualStrings("unix:///tmp/codex.sock", unix_path);

    const websocket = try formatTransportLabel(allocator, try parseTransport("ws://127.0.0.1:3456"));
    defer allocator.free(websocket);
    try std.testing.expectEqualStrings("ws://127.0.0.1:3456", websocket);
}
