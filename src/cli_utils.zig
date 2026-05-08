const std = @import("std");

pub fn joinWithSpaces(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    errdefer joined.deinit(allocator);
    for (parts, 0..) |part, index| {
        if (index > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, part);
    }
    return joined.toOwnedSlice(allocator);
}

pub fn mergeStringSlices(
    allocator: std.mem.Allocator,
    first: []const []const u8,
    second: []const []const u8,
) ![]const []const u8 {
    const merged = try allocator.alloc([]const u8, first.len + second.len);
    @memcpy(merged[0..first.len], first);
    @memcpy(merged[first.len..], second);
    return merged;
}

pub fn writeStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(bytes);
    try stdout.flush();
}

pub fn writeStderr(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stderr = &writer.interface;
    try stderr.writeAll(bytes);
    try stderr.flush();
}

test "join with spaces" {
    const allocator = std.testing.allocator;
    const parts = [_][]const u8{ "one", "two", "three" };

    const joined = try joinWithSpaces(allocator, parts[0..]);
    defer allocator.free(joined);

    try std.testing.expectEqualStrings("one two three", joined);
}

test "merge string slices" {
    const allocator = std.testing.allocator;
    const first = [_][]const u8{"one"};
    const second = [_][]const u8{ "two", "three" };

    const merged = try mergeStringSlices(allocator, first[0..], second[0..]);
    defer allocator.free(merged);

    try std.testing.expectEqualStrings("one", merged[0]);
    try std.testing.expectEqualStrings("two", merged[1]);
    try std.testing.expectEqualStrings("three", merged[2]);
}
