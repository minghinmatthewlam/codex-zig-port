const std = @import("std");
const net = std.Io.net;

pub const default_bind_addr = "0.0.0.0:0";

const max_request_body_bytes = 64 * 1024;
const max_request_head_bytes = 64 * 1024;
const max_prompt_bytes = 64 * 1024;
const client_read_timeout_ms = 1000;
const pipe_read_events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;

const BindAddress = struct {
    host: []const u8,
    port: u16,
};

const Access = enum {
    controller,
    viewer,
};

const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    snapshot_json: []const u8,
    shutdown: std.atomic.Value(bool) = .init(false),
    prompt_write_fd: std.posix.fd_t,
};

const HttpRequest = struct {
    head: std.http.Server.Request.Head,
    head_buffer: []const u8,
    body: []const u8,
};

pub const Server = struct {
    url: []const u8,
    share_url: []const u8,
    controller_token: []const u8,
    viewer_token: []const u8,
    wake_host: []const u8,
    port: u16,
    prompt_read_fd: std.posix.fd_t,
    runtime: *Runtime,
    thread: ?std.Thread,

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        self.runtime.shutdown.store(true, .release);
        if (self.prompt_read_fd >= 0) {
            std.Io.Threaded.closeFd(self.prompt_read_fd);
            self.prompt_read_fd = -1;
        }
        wakeListener(self.wake_host, self.port);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        std.Io.Threaded.closeFd(self.runtime.prompt_write_fd);
        allocator.free(self.runtime.snapshot_json);
        allocator.destroy(self.runtime);
        allocator.free(self.url);
        allocator.free(self.share_url);
        allocator.free(self.controller_token);
        allocator.free(self.viewer_token);
    }

    pub fn updateSnapshot(self: *Server, allocator: std.mem.Allocator, snapshot_json: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.runtime.mutex.lockUncancelable(io);
        const old = self.runtime.snapshot_json;
        self.runtime.snapshot_json = snapshot_json;
        self.runtime.mutex.unlock(io);
        allocator.free(old);
    }

    pub fn readSubmittedPrompt(self: *Server, allocator: std.mem.Allocator) !?[]const u8 {
        var len_buffer: [4]u8 = undefined;
        const first_read = std.posix.read(self.prompt_read_fd, len_buffer[0..]) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (first_read == 0) return null;
        try readFdExact(self.prompt_read_fd, len_buffer[first_read..]);
        const prompt_len = std.mem.readInt(u32, &len_buffer, .big);
        if (prompt_len == 0 or prompt_len > max_prompt_bytes) return error.RemoteControlPromptTooLarge;
        const prompt = try allocator.alloc(u8, prompt_len);
        errdefer allocator.free(prompt);
        try readFdExact(self.prompt_read_fd, prompt);
        return prompt;
    }
};

pub fn start(
    allocator: std.mem.Allocator,
    bind_arg: ?[]const u8,
    initial_snapshot_json: []const u8,
) !Server {
    const bind = try parseBindAddress(bind_arg orelse default_bind_addr);
    var address = try net.IpAddress.parse(bind.host, bind.port);
    const io = std.Io.Threaded.global_single_threaded.io();
    var listener = try address.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);

    const actual_port = listener.socket.address.getPort();
    const public_host = try advertisedHost(allocator, bind.host);
    defer allocator.free(public_host);
    const url_host = try formatUrlHost(allocator, public_host);
    defer allocator.free(url_host);
    const wake_host = wakeHost(bind.host);

    const controller_token = try generateToken(allocator);
    errdefer allocator.free(controller_token);
    const viewer_token = try generateToken(allocator);
    errdefer allocator.free(viewer_token);

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}?token={s}", .{ url_host, actual_port, controller_token });
    errdefer allocator.free(url);
    const share_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}?token={s}", .{ url_host, actual_port, viewer_token });
    errdefer allocator.free(share_url);

    const pipe_fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer std.Io.Threaded.closeFd(pipe_fds[0]);
    errdefer std.Io.Threaded.closeFd(pipe_fds[1]);

    const runtime = try allocator.create(Runtime);
    errdefer allocator.destroy(runtime);
    runtime.* = .{
        .snapshot_json = initial_snapshot_json,
        .prompt_write_fd = pipe_fds[1],
    };

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, serve, .{
        listener,
        runtime,
        controller_token,
        viewer_token,
    });
    errdefer {
        runtime.shutdown.store(true, .release);
        wakeListener(wake_host, actual_port);
        thread.join();
    }

    return .{
        .url = url,
        .share_url = share_url,
        .controller_token = controller_token,
        .viewer_token = viewer_token,
        .wake_host = wake_host,
        .port = actual_port,
        .prompt_read_fd = pipe_fds[0],
        .runtime = runtime,
        .thread = thread,
    };
}

pub fn pollReventsInclude(revents: i16) bool {
    return (@as(u16, @bitCast(revents)) & @as(u16, @intCast(pipe_read_events))) != 0;
}

fn parseBindAddress(value: []const u8) !BindAddress {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidRemoteControlBindAddress;
    const raw_host = value[0..colon];
    const raw_port = value[colon + 1 ..];
    if (raw_port.len == 0) return error.InvalidRemoteControlBindAddress;
    const port = std.fmt.parseUnsigned(u16, raw_port, 10) catch return error.InvalidRemoteControlBindAddress;
    if (raw_host.len == 0) return .{ .host = "0.0.0.0", .port = port };
    if (std.ascii.eqlIgnoreCase(raw_host, "localhost")) return .{ .host = "127.0.0.1", .port = port };
    if (raw_host.len >= 2 and raw_host[0] == '[' and raw_host[raw_host.len - 1] == ']') {
        return .{ .host = raw_host[1 .. raw_host.len - 1], .port = port };
    }
    return .{ .host = raw_host, .port = port };
}

fn advertisedHost(allocator: std.mem.Allocator, host: []const u8) ![]const u8 {
    const ipv4_wildcard = std.mem.eql(u8, host, "0.0.0.0");
    const ipv6_wildcard = std.mem.eql(u8, host, "::");
    if (!ipv4_wildcard and !ipv6_wildcard) return allocator.dupe(u8, host);

    const fallback_host = if (ipv6_wildcard) "::1" else "127.0.0.1";

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buffer) catch return allocator.dupe(u8, fallback_host);
    if (hostname.len == 0) return allocator.dupe(u8, fallback_host);
    if (std.mem.indexOfScalar(u8, hostname, '.') != null) return allocator.dupe(u8, hostname);
    return std.fmt.allocPrint(allocator, "{s}.local", .{hostname});
}

fn wakeHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) return "::1";
    return host;
}

fn formatUrlHost(allocator: std.mem.Allocator, host: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, host, ':') == null) return allocator.dupe(u8, host);
    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        return allocator.dupe(u8, host);
    }
    return std.fmt.allocPrint(allocator, "[{s}]", .{host});
}

fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &bytes);
    return encoded;
}

fn serve(
    listener_arg: net.Server,
    runtime: *Runtime,
    controller_token: []const u8,
    viewer_token: []const u8,
) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listener = listener_arg;
    defer listener.deinit(io);

    while (!runtime.shutdown.load(.acquire)) {
        var stream = listener.accept(io) catch continue;
        defer stream.close(io);
        if (runtime.shutdown.load(.acquire)) break;
        handleConnection(io, &stream, runtime, controller_token, viewer_token) catch {};
    }
}

fn handleConnection(
    io: std.Io,
    stream: *net.Stream,
    runtime: *Runtime,
    controller_token: []const u8,
    viewer_token: []const u8,
) !void {
    var input_buffer: [max_request_head_bytes + max_request_body_bytes]u8 = undefined;
    const request = readHttpRequest(stream.socket.handle, &input_buffer, runtime) catch return;
    const target = request.head.target;
    const path = requestPath(target);
    const access = authorizeRequest(request.head_buffer, target, controller_token, viewer_token) orelse {
        try respond(io, stream, .unauthorized, "text/plain; charset=utf-8", "Unauthorized\n");
        return;
    };

    if (request.head.method == .GET and std.mem.eql(u8, path, "/")) {
        try respondHtml(io, stream, access);
        return;
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) {
        try respond(io, stream, .ok, "application/json", "{\"ok\":true}");
        return;
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/api/state")) {
        try respondSnapshot(io, stream, runtime);
        return;
    }
    if (request.head.method == .POST and std.mem.eql(u8, path, "/api/message")) {
        if (access != .controller) {
            try respond(io, stream, .forbidden, "text/plain; charset=utf-8", "Shared viewers are read-only.\n");
            return;
        }
        try handleMessagePost(io, stream, request.body, runtime);
        return;
    }

    try respond(io, stream, .not_found, "text/plain; charset=utf-8", "Not found\n");
}

fn respondHtml(io: std.Io, stream: *net.Stream, access: Access) !void {
    const body = switch (access) {
        .controller =>
        \\<!doctype html><html><head><meta charset="utf-8"><title>Codex Zig Remote Control</title></head><body><h1>Codex Zig Remote Control</h1><p>Controller mode</p><p>Use <code>/api/state</code> and <code>/api/message</code>.</p></body></html>
        ,
        .viewer =>
        \\<!doctype html><html><head><meta charset="utf-8"><title>Codex Zig Remote Control</title></head><body><h1>Codex Zig Remote Control</h1><p>Viewer mode</p><p>This link is read-only.</p></body></html>
        ,
    };
    try respond(io, stream, .ok, "text/html; charset=utf-8", body);
}

fn respondSnapshot(io: std.Io, stream: *net.Stream, runtime: *Runtime) !void {
    runtime.mutex.lockUncancelable(io);
    const snapshot_json = std.heap.page_allocator.dupe(u8, runtime.snapshot_json) catch |err| {
        runtime.mutex.unlock(io);
        return err;
    };
    runtime.mutex.unlock(io);
    defer std.heap.page_allocator.free(snapshot_json);
    try respond(io, stream, .ok, "application/json", snapshot_json);
}

fn handleMessagePost(io: std.Io, stream: *net.Stream, body: []const u8, runtime: *Runtime) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch {
        try respond(io, stream, .bad_request, "text/plain; charset=utf-8", "request body must be JSON\n");
        return;
    };
    defer parsed.deinit();

    const object = if (parsed.value == .object) parsed.value.object else {
        try respond(io, stream, .bad_request, "text/plain; charset=utf-8", "request body must be a JSON object\n");
        return;
    };
    const message_value = object.get("message") orelse {
        try respond(io, stream, .bad_request, "text/plain; charset=utf-8", "message is required\n");
        return;
    };
    if (message_value != .string) {
        try respond(io, stream, .bad_request, "text/plain; charset=utf-8", "message must be a string\n");
        return;
    }

    const message = std.mem.trim(u8, message_value.string, " \t\r\n");
    if (message.len == 0) {
        try respond(io, stream, .bad_request, "text/plain; charset=utf-8", "Message is empty\n");
        return;
    }
    try writePromptFrame(runtime.prompt_write_fd, message);
    try respond(io, stream, .accepted, "application/json", "{\"ok\":true}");
}

fn authorizeRequest(
    head_buffer: []const u8,
    target: []const u8,
    controller_token: []const u8,
    viewer_token: []const u8,
) ?Access {
    const token = requestToken(head_buffer, target) orelse return null;
    if (std.mem.eql(u8, token, controller_token)) return .controller;
    if (std.mem.eql(u8, token, viewer_token)) return .viewer;
    return null;
}

fn requestToken(head_buffer: []const u8, target: []const u8) ?[]const u8 {
    if (requestQuery(target)) |query| {
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            const split = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..split], "token")) return pair[split + 1 ..];
        }
    }
    var iter = std.http.HeaderIterator.init(head_buffer);
    while (iter.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        const value = std.mem.trim(u8, header.value, " \t\r\n");
        const separator = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
        if (!std.ascii.eqlIgnoreCase(value[0..separator], "Bearer")) return null;
        const token = std.mem.trim(u8, value[separator + 1 ..], " \t\r\n");
        if (token.len == 0) return null;
        return token;
    }
    return null;
}

fn readHttpRequest(fd: std.posix.fd_t, buffer: []u8, runtime: *const Runtime) !HttpRequest {
    var used: usize = 0;
    var head_end: ?usize = null;
    while (head_end == null) {
        if (used >= max_request_head_bytes) return error.HttpHeadersOversize;
        try waitForReadable(fd, runtime);
        const count = try std.posix.read(fd, buffer[used..max_request_head_bytes]);
        if (count == 0) {
            if (used == 0) return error.HttpConnectionClosing;
            return error.HttpRequestTruncated;
        }
        used += count;
        head_end = httpHeadEnd(buffer[0..used]);
    }

    const end = head_end.?;
    const head = try std.http.Server.Request.Head.parse(buffer[0..end]);
    if (head.transfer_encoding != .none) return error.UnsupportedTransferEncoding;

    const body_len_u64 = head.content_length orelse 0;
    if (body_len_u64 > max_request_body_bytes) return error.HttpBodyOversize;
    const body_len: usize = @intCast(body_len_u64);
    const total_len = end + body_len;
    if (total_len > buffer.len) return error.HttpBodyOversize;
    while (used < total_len) {
        try waitForReadable(fd, runtime);
        const count = try std.posix.read(fd, buffer[used..total_len]);
        if (count == 0) return error.HttpRequestTruncated;
        used += count;
    }

    return .{
        .head = head,
        .head_buffer = buffer[0..end],
        .body = buffer[end..total_len],
    };
}

fn httpHeadEnd(bytes: []const u8) ?usize {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| return index + 4;
    return null;
}

fn waitForReadable(fd: std.posix.fd_t, runtime: *const Runtime) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL),
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, client_read_timeout_ms);
    if (runtime.shutdown.load(.acquire)) return error.RemoteControlShutdown;
    if (ready == 0) return error.RemoteControlClientTimeout;
    if (pollReventsInclude(fds[0].revents)) return;
    return error.RemoteControlClientClosed;
}

fn respond(
    io: std.Io,
    stream: *net.Stream,
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &output_buffer);
    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ @intFromEnum(status), status.phrase() orelse "Status", content_type, body.len, body },
    );
    try writer.interface.flush();
}

fn requestPath(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..query_start];
}

fn requestQuery(target: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    return target[query_start + 1 ..];
}

fn writePromptFrame(fd: std.posix.fd_t, message: []const u8) !void {
    if (message.len > max_prompt_bytes) return error.RemoteControlPromptTooLarge;
    var len_buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buffer, @intCast(message.len), .big);
    try writeFdAll(fd, &len_buffer);
    try writeFdAll(fd, message);
}

fn writeFdAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

fn readFdExact(fd: std.posix.fd_t, bytes: []u8) !void {
    var read_count: usize = 0;
    while (read_count < bytes.len) {
        const count = try std.posix.read(fd, bytes[read_count..]);
        if (count == 0) return error.RemoteControlPipeClosed;
        read_count += count;
    }
}

fn wakeListener(host: []const u8, port: u16) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = net.IpAddress.parse(host, port) catch return;
    var stream = address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

test "local remote-control bind parser accepts loopback and wildcard" {
    const default_bind = try parseBindAddress(default_bind_addr);
    try std.testing.expectEqualStrings("0.0.0.0", default_bind.host);
    try std.testing.expectEqual(@as(u16, 0), default_bind.port);

    const loopback = try parseBindAddress("127.0.0.1:1234");
    try std.testing.expectEqualStrings("127.0.0.1", loopback.host);
    try std.testing.expectEqual(@as(u16, 1234), loopback.port);

    const localhost = try parseBindAddress("localhost:0");
    try std.testing.expectEqualStrings("127.0.0.1", localhost.host);
    try std.testing.expectEqual(@as(u16, 0), localhost.port);

    const wildcard = try parseBindAddress(":99");
    try std.testing.expectEqualStrings("0.0.0.0", wildcard.host);
    try std.testing.expectEqual(@as(u16, 99), wildcard.port);

    const ipv6 = try parseBindAddress("[::1]:0");
    try std.testing.expectEqualStrings("::1", ipv6.host);
    try std.testing.expectEqual(@as(u16, 0), ipv6.port);

    const ipv6_wildcard = try parseBindAddress("[::]:0");
    try std.testing.expectEqualStrings("::", ipv6_wildcard.host);
    try std.testing.expectEqual(@as(u16, 0), ipv6_wildcard.port);
}

test "local remote-control wildcard bind does not advertise loopback" {
    const host = try advertisedHost(std.testing.allocator, "0.0.0.0");
    defer std.testing.allocator.free(host);
    try std.testing.expect(!std.mem.eql(u8, host, "127.0.0.1"));
}

test "local remote-control IPv6 wildcard bind does not advertise unspecified address" {
    const host = try advertisedHost(std.testing.allocator, "::");
    defer std.testing.allocator.free(host);
    try std.testing.expect(!std.mem.eql(u8, host, "::"));
}

test "local remote-control URL host brackets IPv6 literals" {
    const host = try formatUrlHost(std.testing.allocator, "::1");
    defer std.testing.allocator.free(host);
    try std.testing.expectEqualStrings("[::1]", host);

    const ipv4 = try formatUrlHost(std.testing.allocator, "127.0.0.1");
    defer std.testing.allocator.free(ipv4);
    try std.testing.expectEqualStrings("127.0.0.1", ipv4);
}

test "local remote-control request target token parsing" {
    try std.testing.expectEqualStrings("token=abc", requestQuery("/api/state?token=abc").?);
    try std.testing.expectEqualStrings("/api/state", requestPath("/api/state?token=abc"));
    try std.testing.expectEqualStrings("/", requestPath("/"));
}
