const std = @import("std");

pub fn getOwned(allocator: std.mem.Allocator, comptime name: []const u8) !?[]const u8 {
    const c_name: [*:0]const u8 = name ++ "\x00";
    const value = std.c.getenv(c_name) orelse return null;
    const copy = try allocator.dupe(u8, std.mem.span(value));
    return copy;
}
