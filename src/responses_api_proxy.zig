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
    if (options.dump_dir) |path| try ensureDirectory(path);

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

    var next_dump_sequence: u64 = 1;
    while (true) {
        var stream = try server.accept(io);
        var shutdown = false;
        handleConnection(allocator, io, &stream, auth_header, upstream_uri, options.http_shutdown, options.dump_dir, &next_dump_sequence, &shutdown) catch |err| {
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
        if (parent.len > 0) try ensureDirectory(parent);
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

fn ensureDirectory(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *net.Stream,
    auth_header: []const u8,
    upstream_uri: std.Uri,
    http_shutdown: bool,
    dump_dir: ?[]const u8,
    next_dump_sequence: *u64,
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

    try forwardResponsesRequest(allocator, &request, auth_header, upstream_uri, dump_dir, next_dump_sequence);
}

fn forwardResponsesRequest(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    auth_header: []const u8,
    upstream_uri: std.Uri,
    dump_dir: ?[]const u8,
    next_dump_sequence: *u64,
) !void {
    var forward_headers = std.ArrayList(std.http.Header).empty;
    defer deinitOwnedHeaders(allocator, &forward_headers);
    var dump_request_headers = std.ArrayList(std.http.Header).empty;
    defer deinitOwnedHeaders(allocator, &dump_request_headers);

    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (dump_dir != null) try appendOwnedHeader(allocator, &dump_request_headers, header.name, header.value);
        if (isRequestHeaderReplaced(header.name)) continue;
        try appendOwnedHeader(allocator, &forward_headers, header.name, header.value);
    }
    try appendOwnedHeader(allocator, &forward_headers, "Authorization", auth_header);

    var body_buffer: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const body = try body_reader.allocRemaining(allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(body);

    const response_dump_path = if (dump_dir) |path|
        dumpRequest(allocator, path, next_dump_sequence, dump_request_headers.items, body) catch |err| path: {
            logDumpError(allocator, "request", err);
            break :path null;
        }
    else
        null;
    defer if (response_dump_path) |path| allocator.free(path);

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
    var dump_response_headers = std.ArrayList(std.http.Header).empty;
    defer deinitOwnedHeaders(allocator, &dump_response_headers);
    var response_header_iter = upstream_response.head.iterateHeaders();
    while (response_header_iter.next()) |header| {
        if (response_dump_path != null) try appendOwnedHeader(allocator, &dump_response_headers, header.name, header.value);
        if (isResponseHeaderManaged(header.name)) continue;
        try appendOwnedHeader(allocator, &response_headers, header.name, header.value);
    }
    try appendOwnedHeader(allocator, &response_headers, "Connection", "close");
    const upstream_status = upstream_response.head.status;
    const upstream_content_length = upstream_response.head.content_length;

    var downstream_buffer: [16 * 1024]u8 = undefined;
    var downstream = try request.respondStreaming(&downstream_buffer, .{
        .content_length = upstream_content_length,
        .respond_options = .{
            .status = upstream_status,
            .extra_headers = response_headers.items,
        },
    });

    var response_dump_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_dump_body.deinit();
    var response_dump_failed = false;

    var transfer_buffer: [16 * 1024]u8 = undefined;
    var response_reader = upstream_response.reader(&transfer_buffer);
    while (true) {
        const chunk = response_reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return upstream_response.bodyErr().?,
        };
        try downstream.writer.writeAll(chunk);
        try downstream.writer.flush();
        try downstream.flush();

        if (response_dump_path != null and !response_dump_failed) {
            response_dump_body.writer.writeAll(chunk) catch |err| {
                logDumpError(allocator, "response", err);
                response_dump_failed = true;
            };
        }
        response_reader.toss(chunk.len);
    }

    if (response_dump_path) |path| {
        if (!response_dump_failed) {
            const response_bytes = try response_dump_body.toOwnedSlice();
            defer allocator.free(response_bytes);
            dumpResponse(allocator, path, upstream_status, dump_response_headers.items, response_bytes) catch |err| {
                logDumpError(allocator, "response", err);
            };
        }
    }

    try downstream.end();
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

fn dumpRequest(
    allocator: std.mem.Allocator,
    dump_dir: []const u8,
    next_sequence: *u64,
    headers: []const std.http.Header,
    body: []const u8,
) ![]u8 {
    const sequence = next_sequence.*;
    next_sequence.* += 1;
    const timestamp_ms = currentUnixMilliseconds();
    const prefix = try std.fmt.allocPrint(allocator, "{d:0>6}-{d}", .{ sequence, timestamp_ms });
    defer allocator.free(prefix);

    const request_name = try std.fmt.allocPrint(allocator, "{s}-request.json", .{prefix});
    defer allocator.free(request_name);
    const request_path = try std.fs.path.join(allocator, &.{ dump_dir, request_name });
    defer allocator.free(request_path);

    const response_name = try std.fmt.allocPrint(allocator, "{s}-response.json", .{prefix});
    defer allocator.free(response_name);
    const response_path = try std.fs.path.join(allocator, &.{ dump_dir, response_name });
    errdefer allocator.free(response_path);

    const json = try renderRequestDumpJson(allocator, headers, body);
    defer allocator.free(json);
    try writeFile(request_path, json);
    return response_path;
}

fn dumpResponse(
    allocator: std.mem.Allocator,
    response_path: []const u8,
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
) !void {
    const json = try renderResponseDumpJson(allocator, @intCast(@intFromEnum(status)), headers, body);
    defer allocator.free(json);
    try writeFile(response_path, json);
}

fn renderRequestDumpJson(allocator: std.mem.Allocator, headers: []const std.http.Header, body: []const u8) ![]u8 {
    const headers_json = try renderHeadersJson(allocator, headers);
    defer allocator.free(headers_json);
    const body_json = try renderBodyJson(allocator, body);
    defer allocator.free(body_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"POST\",\"url\":\"/v1/responses\",\"headers\":{s},\"body\":{s}}}\n",
        .{ headers_json, body_json },
    );
}

fn renderResponseDumpJson(
    allocator: std.mem.Allocator,
    status: u16,
    headers: []const std.http.Header,
    body: []const u8,
) ![]u8 {
    const headers_json = try renderHeadersJson(allocator, headers);
    defer allocator.free(headers_json);
    const body_json = try renderBodyJson(allocator, body);
    defer allocator.free(body_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"status\":{d},\"headers\":{s},\"body\":{s}}}\n",
        .{ status, headers_json, body_json },
    );
}

fn renderHeadersJson(allocator: std.mem.Allocator, headers: []const std.http.Header) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("[");
    for (headers, 0..) |header, index| {
        if (index > 0) try out.writer.writeAll(",");
        const name_json = try std.json.Stringify.valueAlloc(allocator, header.name, .{});
        defer allocator.free(name_json);
        const value = if (shouldRedactHeader(header.name)) "[REDACTED]" else header.value;
        const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(value_json);
        try out.writer.print("{{\"name\":{s},\"value\":{s}}}", .{ name_json, value_json });
    }
    try out.writer.writeAll("]");
    return out.toOwnedSlice();
}

fn shouldRedactHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        containsIgnoreCase(name, "cookie");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn currentUnixMilliseconds() i64 {
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    return @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
}

fn renderBodyJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return std.json.Stringify.valueAlloc(allocator, body, .{});
    };
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn logDumpError(allocator: std.mem.Allocator, label: []const u8, err: anyerror) void {
    const message = std.fmt.allocPrint(allocator, "responses-api-proxy failed to dump {s}: {s}\n", .{ label, @errorName(err) }) catch return;
    defer allocator.free(message);
    cli_utils.writeStderr(message) catch {};
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
        \\  --dump-dir DIR          Write request/response JSON dumps
        \\  -h, --help              Show help
        \\
    , .{});
}

test "responses-api-proxy auth reader trims newline and validates token" {
    try std.testing.expect(isValidApiKey("sk-abc_123"));
    try std.testing.expect(!isValidApiKey("sk abc"));
}
