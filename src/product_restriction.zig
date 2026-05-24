const std = @import("std");

pub const Product = enum {
    chatgpt,
    codex,
    atlas,
};

pub fn fromName(value: []const u8) ?Product {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "chatgpt")) return .chatgpt;
    if (std.ascii.eqlIgnoreCase(trimmed, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(trimmed, "atlas")) return .atlas;
    return null;
}

pub fn fromSessionSourceName(value: []const u8) ?Product {
    return fromName(value);
}

pub fn nameMatches(product: Product, value: []const u8) bool {
    return switch (product) {
        .chatgpt => std.ascii.eqlIgnoreCase(value, "chatgpt"),
        .codex => std.ascii.eqlIgnoreCase(value, "codex"),
        .atlas => std.ascii.eqlIgnoreCase(value, "atlas"),
    };
}
