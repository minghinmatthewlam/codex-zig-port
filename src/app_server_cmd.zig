const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const env = @import("env.zig");

pub const DEFAULT_LISTEN_URL = "stdio://";
const DEFAULT_SOCKET_DIR_NAME = "app-server-control";
const DEFAULT_SOCKET_FILE_NAME = "app-server-control.sock";
const net = std.Io.net;

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
    var subcommand_args = std.ArrayList([]const u8).empty;
    defer subcommand_args.deinit(allocator);

    while (args.next()) |arg| {
        if (subcommand != null) {
            try subcommand_args.append(allocator, arg);
            continue;
        }
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
        if (std.mem.eql(u8, name, "proxy")) {
            try runProxy(allocator, subcommand_args.items);
            return;
        }
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
        .unix_default => {
            const socket_path = try defaultUnixSocketPath(allocator);
            defer allocator.free(socket_path);
            var server = UnixServer{ .allocator = allocator, .socket_path = socket_path };
            try server.run();
        },
        .unix_path => |path| {
            var server = UnixServer{ .allocator = allocator, .socket_path = path };
            try server.run();
        },
        .websocket => {
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

fn runProxy(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var socket_path_arg: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            printProxyHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--sock")) {
            if (index + 1 >= args.len) return error.MissingAppServerProxySocketPath;
            index += 1;
            socket_path_arg = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sock=")) {
            socket_path_arg = arg["--sock=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppServerProxyOption;
        return error.UnexpectedAppServerProxyArgument;
    }

    const owned_default_path = if (socket_path_arg == null) try defaultUnixSocketPath(allocator) else null;
    defer if (owned_default_path) |path| allocator.free(path);
    const socket_path = socket_path_arg orelse owned_default_path.?;
    try runStdioToUnixSocket(allocator, socket_path);
}

pub fn runStdioToUnixSocket(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var socket_in_buffer: [64 * 1024]u8 = undefined;
    var socket_out_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var socket_reader = stream.reader(io, &socket_in_buffer);
    var socket_writer = stream.writer(io, &socket_out_buffer);

    while (true) {
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        try writeStreamLine(&socket_writer.interface, line);
        if (!try jsonRpcLineExpectsResponse(allocator, line)) continue;
        const response = try socket_reader.interface.takeDelimiter('\n') orelse break;
        try writeStdoutLine(response);
    }
}

fn jsonRpcLineExpectsResponse(allocator: std.mem.Allocator, line: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    return parsed.value.object.get("id") != null;
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
            const response = handleJsonRpcLine(self.allocator, trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[app-server] failed to handle message: {s}\n", .{@errorName(err)});
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
};

const UnixServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    fn run(self: *UnixServer) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        try ensureParentDir(io, self.socket_path);
        try deleteSocketFileIfSocket(self.allocator, io, self.socket_path);

        var address = try net.UnixAddress.init(self.socket_path);
        var server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse, error.NotDir => return error.AppServerUnixSocketPathExists,
            else => return err,
        };
        defer server.deinit(io);
        defer deleteSocketFileIfSocket(self.allocator, io, self.socket_path) catch {};

        var stream = try server.accept(io);
        defer stream.close(io);

        var input_buffer: [64 * 1024]u8 = undefined;
        var output_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &input_buffer);
        var writer = stream.writer(io, &output_buffer);

        while (true) {
            const line_opt = try reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            const response = handleJsonRpcLine(self.allocator, trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[app-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStreamLine(&writer.interface, payload);
            }
        }
    }
};

fn handleJsonRpcLine(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return try renderJsonRpcError(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try renderJsonRpcError(allocator, null, -32600, "Invalid Request");
    }

    const object = parsed.value.object;
    const id_value = object.get("id");
    const method_value = object.get("method") orelse {
        return try renderJsonRpcError(allocator, id_value, -32600, "Invalid Request");
    };
    if (method_value != .string) {
        return try renderJsonRpcError(allocator, id_value, -32600, "Invalid Request");
    }
    if (id_value == null) return null;

    const method = method_value.string;
    if (std.mem.eql(u8, method, "initialize")) {
        const result = try renderInitializeResult(allocator);
        defer allocator.free(result);
        return try renderJsonRpcResult(allocator, id_value.?, result);
    }

    const message = try std.fmt.allocPrint(allocator, "unsupported app-server method: {s}", .{method});
    defer allocator.free(message);
    return try renderJsonRpcError(allocator, id_value, -32601, message);
}

fn renderInitializeResult(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(
        u8,
        "{\"serverInfo\":{\"name\":\"codex-zig-app-server\",\"version\":\"0.0.1\"},\"capabilities\":{}}",
    );
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

fn writeStdoutLine(payload: []const u8) !void {
    try cli_utils.writeStdout(payload);
    try cli_utils.writeStdout("\n");
}

fn writeStreamLine(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeAll(payload);
    try writer.writeAll("\n");
    try writer.flush();
}

fn defaultUnixSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    return std.fs.path.join(allocator, &.{ codex_home, DEFAULT_SOCKET_DIR_NAME, DEFAULT_SOCKET_FILE_NAME });
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| return value;

    const home = (try env.getOwned(allocator, "HOME")) orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    if (try dirExists(io, parent)) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn dirExists(io: std.Io, path: []const u8) !bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    defer dir.close(io);
    return true;
}

fn deleteSocketFileIfSocket(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const stat = statPathNoFollow(allocator, path) catch |err| switch (err) {
        error.NotDir => return error.AppServerUnixSocketPathExists,
        else => return err,
    } orelse return;
    if (!std.c.S.ISSOCK(@intCast(stat.mode))) return error.AppServerUnixSocketPathExists;
    try std.Io.Dir.cwd().deleteFile(io, path);
}

fn statPathNoFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT => return null,
            .NOTDIR => return error.NotDir,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return stat;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig app-server [--listen URL]
        \\  codex-zig app-server proxy [--sock SOCKET_PATH]
        \\
        \\Runs the app-server JSON-RPC transport.
        \\
        \\Subcommands:
        \\  proxy                  Proxy stdio to the app-server Unix socket
        \\
        \\Options:
        \\  --listen URL           Transport URL. Defaults to stdio://.
        \\
        \\Supported URL forms:
        \\  stdio://               Read and write newline-delimited JSON-RPC on stdio
        \\  off                    Disable the app-server transport
        \\  unix://                Listen on CODEX_HOME/app-server-control/app-server-control.sock
        \\  unix://PATH            Listen on a Unix socket transport path
        \\  ws://IP:PORT           Parse a websocket transport address
        \\
        \\The Zig port currently implements stdio://, unix://, unix://PATH, and off.
        \\
    , .{});
}

fn printProxyHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig app-server proxy [--sock SOCKET_PATH]
        \\
        \\Relays newline-delimited JSON-RPC between stdio and the app-server
        \\Unix control socket. If --sock is omitted, the default
        \\CODEX_HOME/app-server-control/app-server-control.sock path is used.
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
