const std = @import("std");

const config = @import("config.zig");
const features_cmd = @import("features_cmd.zig");

pub const ParsedOptions = struct {
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},

    pub fn deinit(self: *ParsedOptions, allocator: std.mem.Allocator) void {
        self.feature_overrides.deinit(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    var parsed = try parseArgSlice(allocator, raw_args.items);
    defer parsed.deinit(allocator);

    std.debug.print(
        "codex-zig remote-control parsed Rust-compatible options, but headless app-server remote control is not implemented yet\n",
        .{},
    );
    return error.RemoteControlCommandNotImplemented;
}

fn parseArgSlice(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    var parsed = ParsedOptions{};
    errdefer parsed.deinit(allocator);

    var profile: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            printHelp();
            return error.RemoteControlHelpRequested;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigOptionValue;
            try config.applyRawConfigOverride(
                &parsed.runtime_overrides,
                &profile,
                args[index],
            );
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            try config.applyRawConfigOverride(
                &parsed.runtime_overrides,
                &profile,
                arg["--config=".len..],
            );
            continue;
        }
        if (std.mem.eql(u8, arg, "--enable")) {
            index += 1;
            if (index >= args.len) return error.MissingFeatureName;
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, args[index], true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            index += 1;
            if (index >= args.len) return error.MissingFeatureName;
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, args[index], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownRemoteControlOption;
        return error.UnexpectedRemoteControlArgument;
    }

    try enableRemoteControlForInvocation(allocator, &parsed.feature_overrides);
    return parsed;
}

fn enableRemoteControlForInvocation(
    allocator: std.mem.Allocator,
    overrides: *features_cmd.FeatureOverrides,
) !void {
    try features_cmd.putRuntimeToggle(allocator, overrides, "remote_control", true);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\[experimental] Start a headless app-server with remote control enabled
        \\
        \\Usage:
        \\  codex-zig remote-control [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\          Override a configuration value that would otherwise be loaded
        \\          from ~/.codex/config.toml. Dotted paths override nested values.
        \\
        \\      --enable <FEATURE>
        \\          Enable a feature for this invocation.
        \\
        \\      --disable <FEATURE>
        \\          Disable a feature for this invocation.
        \\
        \\  -h, --help
        \\          Print help.
        \\
    , .{});
}

test "remote-control command appends feature override after user toggles" {
    const allocator = std.testing.allocator;
    const raw_args = [_][]const u8{ "--disable", "remote_control", "--enable", "goals" };
    var parsed = try parseArgSlice(allocator, raw_args[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.feature_overrides.items.items.len);
    try std.testing.expectEqualStrings("remote_control", parsed.feature_overrides.items.items[0].key);
    try std.testing.expectEqual(true, parsed.feature_overrides.items.items[0].enabled);
    try std.testing.expectEqualStrings("goals", parsed.feature_overrides.items.items[1].key);
    try std.testing.expectEqual(true, parsed.feature_overrides.items.items[1].enabled);
}

test "remote-control command rejects positional arguments" {
    const allocator = std.testing.allocator;
    const stop_args = [_][]const u8{"stop"};
    try std.testing.expectError(
        error.UnexpectedRemoteControlArgument,
        parseArgSlice(allocator, stop_args[0..]),
    );
}

test "remote-control command parses config overrides" {
    const allocator = std.testing.allocator;
    const raw_args = [_][]const u8{ "-c", "model=\"o3\"", "--config=chatgpt_base_url=http://127.0.0.1:9" };
    var parsed = try parseArgSlice(allocator, raw_args[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("o3", parsed.runtime_overrides.model.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", parsed.runtime_overrides.chatgpt_base_url.?);
    try std.testing.expectEqual(true, parsed.feature_overrides.get("remote_control").?);
}
