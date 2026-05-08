const std = @import("std");

pub fn change(path: []const u8) !void {
    try std.Io.Threaded.chdir(path);
}
