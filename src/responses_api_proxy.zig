const std = @import("std");

const cli_utils = @import("cli_utils.zig");

const net = std.Io.net;
const DEFAULT_UPSTREAM_URL = "https://api.openai.com/v1/responses";
const AUTH_HEADER_PREFIX = "Bearer ";
const AUTH_TOKEN_CAPACITY = 1024 - AUTH_HEADER_PREFIX.len;

const Options = struct {
    port: ?u16 = null,
    server_info: ?[]const u8 = null,
    http_shutdown: bool = false,
    upstream_url: []const u8 = DEFAULT_UPSTREAM_URL,
    dump_dir: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const options = try parseArgs(args);
    if (options.dump_dir != null) return error.ResponsesApiProxyDumpDirUnsupported;

    const auth_header = try readAuthHeaderFromStdin(allocator);
    defer allocator.free(auth_header);

    const upstream_uri = std.Uri.parse(options.upstream_url) catch return error.InvalidResponsesApiProxyUpstreamUrl;
    if (upstream_uri.host == null) return error.InvalidResponsesApiProxyUpstreamUrl;

    var server = try bindLoopback(options.port);
    const io = std.Io.Threaded.global_single_threaded.io();
    defer server.deinit(io);

    const actual_port = server.socket.address.getPort();
    if (options.server_info) |path| try writeServerInfo(allocator, path, actual_port);

    var listen_message_buffer: [128]u8 = undefined;
    const listen_message = try std.fmt.bufPrint(
        &listen_message_buffer,
        "responses-api-proxy listening on 127.0.0.1:{d}\n",
        .{actual_port},
    );
    try cli_utils.writeStderr(listen_message);

    while (true) {
        var stream = try server.accept(io);
        var shutdown = false;
        handleConnection(allocator, io, &stream, auth_header, upstream_uri, options.http_shutdown, &shutdown) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "responses-api-proxy connection error: {s}\n", .{@errorName(err)});
            defer allocator.free(message);
            try cli_utils.writeStderr(message);
        };
        stream.close(io);
        if (shutdown) return;
    }
}

fn parseArgs(args: *std.process.Args.Iterator) !Options {
    var options = Options{};
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printHelp();
            return error.ResponsesApiProxyHelpRequested;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            options.port = try parsePort(args.next() orelse return error.MissingResponsesApiProxyPort);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            options.port = try parsePort(arg["--port=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--server-info")) {
            options.server_info = args.next() orelse return error.MissingResponsesApiProxyServerInfo;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--server-info=")) {
            options.server_info = arg["--server-info=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--http-shutdown")) {
            options.http_shutdown = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--upstream-url")) {
            options.upstream_url = args.next() orelse return error.MissingResponsesApiProxyUpstreamUrl;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--upstream-url=")) {
            options.upstream_url = arg["--upstream-url=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-dir")) {
            options.dump_dir = args.next() orelse return error.MissingResponsesApiProxyDumpDir;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-dir=")) {
            options.dump_dir = arg["--dump-dir=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownResponsesApiProxyOption;
        return error.UnexpectedResponsesApiProxyArgument;
    }
    return options;
}

fn parsePort(value: []const u8) !u16 {
    if (value.len == 0) return error.InvalidResponsesApiProxyPort;
    return std.fmt.parseUnsigned(u16, value, 10) catch error.InvalidResponsesApiProxyPort;
}

fn readAuthHeaderFromStdin(allocator: std.mem.Allocator) ![]u8 {
    var input_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

    var token = std.ArrayList(u8).empty;
    defer token.deinit(allocator);
    while (token.items.len < AUTH_TOKEN_CAPACITY) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        try token.append(allocator, byte);
    }

    if (token.items.len == AUTH_TOKEN_CAPACITY) {
        return error.ResponsesApiProxyApiKeyTooLarge;
    }
    const trimmed = std.mem.trimEnd(u8, token.items, "\r");
    if (trimmed.len == 0) return error.ResponsesApiProxyMissingApiKey;
    if (!isValidApiKey(trimmed)) return error.ResponsesApiProxyInvalidApiKey;

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ AUTH_HEADER_PREFIX, trimmed });
}

fn isValidApiKey(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

fn bindLoopback(port: ?u16) !net.Server {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port orelse 0) };
    return address.listen(io, .{ .reuse_address = true });
}

fn writeServerInfo(allocator: std.mem.Allocator, path: []const u8, port: u16) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const data = try std.fmt.allocPrint(
        allocator,
        "{{\"port\":{d},\"pid\":{d}}}\n",
        .{ port, std.c.getpid() },
    );
    defer allocator.free(data);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *net.Stream,
    auth_header: []const u8,
    upstream_uri: std.Uri,
    http_shutdown: bool,
    shutdown: *bool,
) !void {
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &input_buffer);
    var writer = stream.writer(io, &output_buffer);
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    if (http_shutdown and request.head.method == .GET and std.mem.eql(u8, request.head.target, "/shutdown")) {
        try request.respond("", .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
        });
        shutdown.* = true;
        return;
    }

    if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, "/v1/responses")) {
        try request.respond("", .{
            .status = .forbidden,
            .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
        });
        return;
    }

    try forwardResponsesRequest(allocator, &request, auth_header, upstream_uri);
}

fn forwardResponsesRequest(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    auth_header: []const u8,
    upstream_uri: std.Uri,
) !void {
    var forward_headers = std.ArrayList(std.http.Header).empty;
    defer deinitOwnedHeaders(allocator, &forward_headers);

    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (isRequestHeaderReplaced(header.name)) continue;
        try appendOwnedHeader(allocator, &forward_headers, header.name, header.value);
    }
    try appendOwnedHeader(allocator, &forward_headers, "Authorization", auth_header);

    var body_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const body = try body_reader.allocRemaining(allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(body);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var upstream_request = try client.request(.POST, upstream_uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = forward_headers.items,
    });
    defer upstream_request.deinit();

    upstream_request.transfer_encoding = .{ .content_length = body.len };
    var request_body = try upstream_request.sendBodyUnflushed(&.{});
    try request_body.writer.writeAll(body);
    try request_body.end();
    try upstream_request.connection.?.flush();

    var response_head_buffer: [8192]u8 = undefined;
    var upstream_response = try upstream_request.receiveHead(&response_head_buffer);

    var response_headers = std.ArrayList(std.http.Header).empty;
    defer deinitOwnedHeaders(allocator, &response_headers);
    var response_header_iter = upstream_response.head.iterateHeaders();
    while (response_header_iter.next()) |header| {
        if (isResponseHeaderManaged(header.name)) continue;
        try appendOwnedHeader(allocator, &response_headers, header.name, header.value);
    }
    try appendOwnedHeader(allocator, &response_headers, "Connection", "close");

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    var transfer_buffer: [1024]u8 = undefined;
    const response_reader = upstream_response.reader(&transfer_buffer);
    _ = response_reader.streamRemaining(&response_body.writer) catch |err| switch (err) {
        error.ReadFailed => return upstream_response.bodyErr().?,
        else => |e| return e,
    };
    const response_bytes = try response_body.toOwnedSlice();
    defer allocator.free(response_bytes);

    try request.respond(response_bytes, .{
        .status = upstream_response.head.status,
        .extra_headers = response_headers.items,
    });
}

fn appendOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(std.http.Header),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try headers.append(allocator, .{ .name = owned_name, .value = owned_value });
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(std.http.Header)) void {
    for (headers.items) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    headers.deinit(allocator);
}

fn isRequestHeaderReplaced(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn isResponseHeaderManaged(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig responses-api-proxy [OPTIONS]
        \\
        \\Minimal OpenAI responses proxy.
        \\
        \\Options:
        \\  --port PORT             Port to listen on; defaults to an ephemeral port
        \\  --server-info FILE      Write startup JSON with port and pid
        \\  --http-shutdown         Enable GET /shutdown
        \\  --upstream-url URL      Upstream responses endpoint URL
        \\  --dump-dir DIR          Recognized; dump writing is not implemented yet
        \\  -h, --help              Show help
        \\
    , .{});
}

test "responses-api-proxy auth reader trims newline and validates token" {
    try std.testing.expect(isValidApiKey("sk-abc_123"));
    try std.testing.expect(!isValidApiKey("sk abc"));
}
