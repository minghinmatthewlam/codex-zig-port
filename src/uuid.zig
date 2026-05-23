const std = @import("std");

pub fn generateV4String(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return renderBytes(allocator, bytes);
}

pub fn generateV7String(allocator: std.mem.Allocator) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var bytes: [16]u8 = undefined;
    io.random(&bytes);

    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_ms_i64 = @divTrunc(now_ns, std.time.ns_per_ms);
    const now_ms: u64 = @intCast(@max(now_ms_i64, 0));
    bytes[0] = @intCast((now_ms >> 40) & 0xff);
    bytes[1] = @intCast((now_ms >> 32) & 0xff);
    bytes[2] = @intCast((now_ms >> 24) & 0xff);
    bytes[3] = @intCast((now_ms >> 16) & 0xff);
    bytes[4] = @intCast((now_ms >> 8) & 0xff);
    bytes[5] = @intCast(now_ms & 0xff);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return renderBytes(allocator, bytes);
}

fn renderBytes(allocator: std.mem.Allocator, bytes: [16]u8) ![]const u8 {
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

test "generateV4String returns uuid v4 shape" {
    const allocator = std.testing.allocator;
    const id = try generateV4String(allocator);
    defer allocator.free(id);

    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expect(id[8] == '-');
    try std.testing.expect(id[13] == '-');
    try std.testing.expect(id[18] == '-');
    try std.testing.expect(id[23] == '-');
    try std.testing.expect(id[14] == '4');
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", id[19]) != null);
}

test "generateV7String returns uuid v7 shape" {
    const allocator = std.testing.allocator;
    const id = try generateV7String(allocator);
    defer allocator.free(id);

    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expect(id[8] == '-');
    try std.testing.expect(id[13] == '-');
    try std.testing.expect(id[18] == '-');
    try std.testing.expect(id[23] == '-');
    try std.testing.expect(id[14] == '7');
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", id[19]) != null);
}
