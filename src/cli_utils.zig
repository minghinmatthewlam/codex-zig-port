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

pub fn writeStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(bytes);
    try stdout.flush();
}

test "join with spaces" {
    const allocator = std.testing.allocator;
    const parts = [_][]const u8{ "one", "two", "three" };

    const joined = try joinWithSpaces(allocator, parts[0..]);
    defer allocator.free(joined);

    try std.testing.expectEqualStrings("one two three", joined);
}
