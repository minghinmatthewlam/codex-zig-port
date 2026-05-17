const std = @import("std");
const net = std.Io.net;

const stream_buffer_len = 64 * 1024;
const tls_buffer_len = std.crypto.tls.Client.min_buffer_len;
const writer_adapter_buffer_len = 16 * 1024;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: ?std.crypto.tls.Client,
    ca_bundle: std.crypto.Certificate.Bundle,
    ca_lock: std.Io.RwLock,
    tls_writer: std.Io.Writer,
    stream_input_buffer: [stream_buffer_len]u8,
    stream_output_buffer: [stream_buffer_len]u8,
    tls_read_buffer: [tls_buffer_len]u8,
    tls_write_buffer: [tls_buffer_len]u8,
    writer_adapter_buffer: [writer_adapter_buffer_len]u8,

    pub fn initPlain(self: *Connection, allocator: std.mem.Allocator, io: std.Io, stream: net.Stream) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .stream_reader = undefined,
            .stream_writer = undefined,
            .tls_client = null,
            .ca_bundle = .empty,
            .ca_lock = .init,
            .tls_writer = undefined,
            .stream_input_buffer = undefined,
            .stream_output_buffer = undefined,
            .tls_read_buffer = undefined,
            .tls_write_buffer = undefined,
            .writer_adapter_buffer = undefined,
        };
        self.stream_reader = self.stream.reader(io, &self.stream_input_buffer);
        self.stream_writer = self.stream.writer(io, &self.stream_output_buffer);
    }

    pub fn initTls(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = undefined,
            .stream_reader = undefined,
            .stream_writer = undefined,
            .tls_client = null,
            .ca_bundle = .empty,
            .ca_lock = .init,
            .tls_writer = undefined,
            .stream_input_buffer = undefined,
            .stream_output_buffer = undefined,
            .tls_read_buffer = undefined,
            .tls_write_buffer = undefined,
            .writer_adapter_buffer = undefined,
        };

        const connect_host = remoteWebSocketConnectHost(host);
        self.stream = try connectTcp(io, connect_host, port);
        errdefer self.stream.close(io);

        self.stream_reader = self.stream.reader(io, &self.stream_input_buffer);
        self.stream_writer = self.stream.writer(io, &self.stream_output_buffer);

        const now = std.Io.Clock.real.now(io);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        try io.randomSecure(&entropy);

        self.tls_client = if (std.ascii.eqlIgnoreCase(connect_host, "localhost"))
            try self.initTlsClient(.{
                .host = .{ .explicit = connect_host },
                .ca = .self_signed,
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
            })
        else if (isLoopbackIpLiteral(connect_host))
            try self.initTlsClient(.{
                // Zig 0.16 verifies only DNS SANs, not iPAddress SANs. Limit
                // this weaker self-signed mode to parsed loopback IP literals.
                .host = .no_verification,
                .ca = .self_signed,
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
            })
        else blk: {
            try self.ca_bundle.rescan(allocator, io, now);
            errdefer self.ca_bundle.deinit(allocator);
            break :blk try self.initTlsClient(.{
                .host = .{ .explicit = connect_host },
                .ca = .{ .bundle = .{
                    .gpa = allocator,
                    .io = io,
                    .lock = &self.ca_lock,
                    .bundle = &self.ca_bundle,
                } },
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
            });
        };

        self.tls_writer = .{
            .buffer = &self.writer_adapter_buffer,
            .vtable = &tls_writer_vtable,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.tls_client) |*tls| {
            tls.end() catch {};
            self.stream_writer.interface.flush() catch {};
        } else {
            self.stream_writer.interface.flush() catch {};
        }
        self.stream.close(self.io);
        self.ca_bundle.deinit(self.allocator);
    }

    pub fn reader(self: *Connection) *std.Io.Reader {
        if (self.tls_client) |*tls| return &tls.reader;
        return &self.stream_reader.interface;
    }

    pub fn writer(self: *Connection) *std.Io.Writer {
        if (self.tls_client != null) return &self.tls_writer;
        return &self.stream_writer.interface;
    }

    fn initTlsClient(self: *Connection, options: std.crypto.tls.Client.Options) !std.crypto.tls.Client {
        return std.crypto.tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            options,
        ) catch |err| switch (err) {
            error.WriteFailed => return self.stream_writer.err orelse err,
            error.ReadFailed => return self.stream_reader.err orelse err,
            else => |e| return e,
        };
    }

    fn tlsWriterDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("tls_writer", w));
        const tls = if (self.tls_client) |*tls| tls else return error.WriteFailed;

        if (w.end > 0) {
            try tls.writer.writeAll(w.buffered());
            w.end = 0;
        }

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try tls.writer.writeAll(bytes);
            consumed += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try tls.writer.writeAll(last);
            consumed += last.len;
        }
        return consumed;
    }

    fn tlsWriterFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Connection = @alignCast(@fieldParentPtr("tls_writer", w));
        const tls = if (self.tls_client) |*tls| tls else return error.WriteFailed;
        if (w.end > 0) {
            try tls.writer.writeAll(w.buffered());
            w.end = 0;
        }
        try tls.writer.flush();
        try self.stream_writer.interface.flush();
    }
};

const tls_writer_vtable: std.Io.Writer.VTable = .{
    .drain = Connection.tlsWriterDrain,
    .flush = Connection.tlsWriterFlush,
};

pub fn remoteWebSocketConnectHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

pub fn isLoopbackHost(host: []const u8) bool {
    const connect_host = remoteWebSocketConnectHost(host);
    if (std.ascii.eqlIgnoreCase(connect_host, "localhost")) return true;
    return isLoopbackIpLiteral(connect_host);
}

fn isLoopbackIpLiteral(host: []const u8) bool {
    const address = net.IpAddress.parse(host, 0) catch return false;
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| blk: {
            const loopback = net.Ip6Address.loopback(0).bytes;
            break :blk std.mem.eql(u8, &ip6.bytes, &loopback);
        },
    };
}

fn connectTcp(io: std.Io, host: []const u8, port: u16) !net.Stream {
    if (net.IpAddress.parse(host, port)) |address| {
        var mutable_address = address;
        return try mutable_address.connect(io, .{ .mode = .stream });
    } else |_| {}

    const host_name = try net.HostName.init(host);
    return try host_name.connect(io, port, .{ .mode = .stream });
}

test "detects loopback websocket TLS hosts" {
    try std.testing.expect(isLoopbackHost("localhost"));
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("127.4.5.6"));
    try std.testing.expect(isLoopbackHost("[::1]"));
    try std.testing.expect(!isLoopbackHost("127.attacker.example"));
    try std.testing.expect(!isLoopbackHost("127.0.0.1.example"));
    try std.testing.expect(!isLoopbackHost("example.com"));

    try std.testing.expect(!isLoopbackIpLiteral("localhost"));
    try std.testing.expect(isLoopbackIpLiteral("127.0.0.1"));
    try std.testing.expect(isLoopbackIpLiteral("::1"));
    try std.testing.expect(!isLoopbackIpLiteral("127.attacker.example"));
}
