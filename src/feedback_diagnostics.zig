const std = @import("std");

const env = @import("env.zig");

pub const attachment_filename = "codex-connectivity-diagnostics.txt";

const proxy_env_vars = [_][]const u8{
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "ALL_PROXY",
    "all_proxy",
};

const proxy_headline = "Proxy environment variables are set and may affect connectivity.";

const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub fn attachmentTextFromEnv(allocator: std.mem.Allocator) !?[]const u8 {
    var details = std.ArrayList([]const u8).empty;
    defer {
        for (details.items) |detail| allocator.free(detail);
        details.deinit(allocator);
    }

    for (proxy_env_vars) |key| {
        const maybe_value = try env.getOwnedDynamic(allocator, key);
        const value = maybe_value orelse continue;
        defer allocator.free(value);

        const detail = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ key, value });
        details.append(allocator, detail) catch |err| {
            allocator.free(detail);
            return err;
        };
    }

    return attachmentTextFromDetails(allocator, details.items);
}

fn attachmentTextFromPairs(allocator: std.mem.Allocator, pairs: []const Pair) !?[]const u8 {
    var details = std.ArrayList([]const u8).empty;
    defer {
        for (details.items) |detail| allocator.free(detail);
        details.deinit(allocator);
    }

    for (proxy_env_vars) |key| {
        const value = pairValue(pairs, key) orelse continue;
        const detail = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ key, value });
        details.append(allocator, detail) catch |err| {
            allocator.free(detail);
            return err;
        };
    }

    return attachmentTextFromDetails(allocator, details.items);
}

fn pairValue(pairs: []const Pair, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key)) found = pair.value;
    }
    return found;
}

fn attachmentTextFromDetails(allocator: std.mem.Allocator, details: []const []const u8) !?[]const u8 {
    if (details.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "Connectivity diagnostics\n\n- ");
    try out.appendSlice(allocator, proxy_headline);
    for (details) |detail| {
        try out.appendSlice(allocator, "\n  - ");
        try out.appendSlice(allocator, detail);
    }

    const text = try out.toOwnedSlice(allocator);
    return text;
}

test "connectivity diagnostics report raw proxy values in Rust order" {
    const allocator = std.testing.allocator;
    const text = try attachmentTextFromPairs(allocator, &.{
        .{
            .key = "HTTPS_PROXY",
            .value = "https://secure-proxy.example.com:443/path?value=raw",
        },
        .{
            .key = "http_proxy",
            .value = "proxy.example.com:8080",
        },
        .{
            .key = "all_proxy",
            .value = "socks5h://all-proxy.example.com:1080",
        },
    });
    defer if (text) |value| allocator.free(value);

    try std.testing.expectEqualStrings(
        \\Connectivity diagnostics
        \\
        \\- Proxy environment variables are set and may affect connectivity.
        \\  - http_proxy = proxy.example.com:8080
        \\  - HTTPS_PROXY = https://secure-proxy.example.com:443/path?value=raw
        \\  - all_proxy = socks5h://all-proxy.example.com:1080
    ,
        text orelse return error.MissingDiagnosticsAttachment,
    );
}

test "connectivity diagnostics ignore absent proxy values" {
    const allocator = std.testing.allocator;
    const text = try attachmentTextFromPairs(allocator, &.{});
    try std.testing.expect(text == null);
}

test "connectivity diagnostics preserve whitespace and empty values" {
    const allocator = std.testing.allocator;
    const text = try attachmentTextFromPairs(allocator, &.{
        .{
            .key = "HTTP_PROXY",
            .value = "  proxy with spaces  ",
        },
        .{
            .key = "HTTPS_PROXY",
            .value = "",
        },
    });
    defer if (text) |value| allocator.free(value);

    try std.testing.expectEqualStrings(
        "Connectivity diagnostics\n\n" ++
            "- Proxy environment variables are set and may affect connectivity.\n" ++
            "  - HTTP_PROXY =   proxy with spaces  \n" ++
            "  - HTTPS_PROXY = ",
        text orelse return error.MissingDiagnosticsAttachment,
    );
}
