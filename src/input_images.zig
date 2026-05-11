const std = @import("std");

pub fn appendFiles(
    allocator: std.mem.Allocator,
    image_files: *std.ArrayList([]const u8),
    raw: []const u8,
) !void {
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        try image_files.append(allocator, try allocator.dupe(u8, part));
    }
}

pub const Loaded = struct {
    data_urls: []const []const u8 = &.{},

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        for (self.data_urls) |url| allocator.free(url);
        if (self.data_urls.len > 0) allocator.free(self.data_urls);
    }
};

pub fn load(allocator: std.mem.Allocator, paths: []const []const u8) !Loaded {
    if (paths.len == 0) return .{};

    const data_urls = try allocator.alloc([]const u8, paths.len);
    errdefer allocator.free(data_urls);
    var count: usize = 0;
    errdefer {
        for (data_urls[0..count]) |url| allocator.free(url);
    }

    for (paths) |path| {
        data_urls[count] = try loadOne(allocator, path);
        count += 1;
    }

    return .{ .data_urls = data_urls };
}

pub fn loadOne(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(bytes);

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mimeForImage(path, bytes), encoded });
}

fn mimeForImage(path: []const u8, bytes: []const u8) []const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";

    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    return "image/png";
}
