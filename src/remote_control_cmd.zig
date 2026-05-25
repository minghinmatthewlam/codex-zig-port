const std = @import("std");

const app_server_cmd = @import("app_server_cmd.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const features_cmd = @import("features_cmd.zig");

const Command = enum {
    foreground,
    start,
    stop,
};

const HelpTarget = enum {
    root,
    start,
    stop,
    help_cmd,
};

pub const ParsedOptions = struct {
    command: Command = .foreground,
    json: bool = false,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    child_global_args: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ParsedOptions, allocator: std.mem.Allocator) void {
        self.feature_overrides.deinit(allocator);
        self.child_global_args.deinit(allocator);
    }
};

pub const RunOptions = struct {
    feature_overrides: features_cmd.FeatureOverrides = .{},
    child_global_args: []const []const u8 = &.{},
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    try runWithOptions(allocator, args, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: RunOptions) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    var parsed = try parseArgSliceWithOptions(allocator, raw_args.items, options);
    defer parsed.deinit(allocator);

    switch (parsed.command) {
        .foreground => return error.RemoteControlStateDbUnavailable,
        .start => {
            if (!parsed.json) {
                try cli_utils.writeStdout("Starting app-server daemon with remote control enabled...\n");
            }
            try app_server_cmd.runRemoteControlDaemonStart(allocator, parsed.json, parsed.child_global_args.items, options.feature_overrides);
        },
        .stop => {
            if (!parsed.json) {
                try cli_utils.writeStdout("Stopping remote control...\n");
            }
            try app_server_cmd.runRemoteControlDaemonStop(allocator, parsed.json);
        },
    }
}

fn parseArgSlice(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    return parseArgSliceWithOptions(allocator, args, .{});
}

fn parseArgSliceWithOptions(allocator: std.mem.Allocator, args: []const []const u8, options: RunOptions) !ParsedOptions {
    var parsed = ParsedOptions{
        .feature_overrides = try options.feature_overrides.clone(allocator),
    };
    errdefer parsed.deinit(allocator);
    try parsed.child_global_args.appendSlice(allocator, options.child_global_args);

    if (helpPreflight(args)) |target| {
        printHelpTarget(target);
        return error.RemoteControlHelpRequested;
    }

    var profile: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            printHelpForCommand(parsed.command);
            return error.RemoteControlHelpRequested;
        }
        if (std.mem.eql(u8, arg, "help")) {
            if (parsed.command != .foreground) return error.UnexpectedRemoteControlArgument;
            if (index + 1 < args.len) {
                if (index + 2 < args.len) return error.UnexpectedRemoteControlArgument;
                if (std.mem.eql(u8, args[index + 1], "help")) {
                    printHelpCommandHelp();
                    return error.RemoteControlHelpRequested;
                }
                const help_command = parseCommand(args[index + 1]) orelse return error.UnexpectedRemoteControlArgument;
                printCommandHelp(help_command);
                return error.RemoteControlHelpRequested;
            }
            printHelp();
            return error.RemoteControlHelpRequested;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigOptionValue;
            try parsed.child_global_args.append(allocator, arg);
            try parsed.child_global_args.append(allocator, args[index]);
            try config.applyRawConfigOverride(
                &parsed.runtime_overrides,
                &profile,
                args[index],
            );
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            try parsed.child_global_args.append(allocator, arg);
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
            try parsed.child_global_args.append(allocator, arg);
            try parsed.child_global_args.append(allocator, args[index]);
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, args[index], true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            try parsed.child_global_args.append(allocator, arg);
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            index += 1;
            if (index >= args.len) return error.MissingFeatureName;
            try parsed.child_global_args.append(allocator, arg);
            try parsed.child_global_args.append(allocator, args[index]);
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, args[index], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            try parsed.child_global_args.append(allocator, arg);
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownRemoteControlOption;
        if (parsed.command != .foreground) return error.UnexpectedRemoteControlArgument;
        parsed.command = parseCommand(arg) orelse return error.UnexpectedRemoteControlArgument;
    }

    try enableRemoteControlForInvocation(allocator, &parsed.feature_overrides);
    return parsed;
}

fn helpPreflight(args: []const []const u8) ?HelpTarget {
    var command: Command = .foreground;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return helpTargetForCommand(command);
        if (std.mem.eql(u8, arg, "help")) {
            if (command != .foreground) return null;
            if (index + 1 >= args.len) return .root;
            if (index + 2 < args.len) return null;
            if (std.mem.eql(u8, args[index + 1], "help")) return .help_cmd;
            const target = parseCommand(args[index + 1]) orelse return null;
            return helpTargetForCommand(target);
        }
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--enable") or
            std.mem.eql(u8, arg, "--disable"))
        {
            index += 1;
            if (index >= args.len or optionValueBoundary(args[index])) return null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=") or
            std.mem.startsWith(u8, arg, "--enable=") or
            std.mem.startsWith(u8, arg, "--disable="))
        {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return null;
        if (command != .foreground) return null;
        command = parseCommand(arg) orelse return null;
    }
    return null;
}

fn helpTargetForCommand(command: Command) HelpTarget {
    return switch (command) {
        .foreground => .root,
        .start => .start,
        .stop => .stop,
    };
}

fn optionValueBoundary(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
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

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "start")) return .start;
    if (std.mem.eql(u8, arg, "stop")) return .stop;
    return null;
}

pub fn printHelp() void {
    std.debug.print(
        \\[experimental] Manage the app-server daemon with remote control enabled
        \\
        \\Usage:
        \\  codex-zig remote-control [OPTIONS] [COMMAND]
        \\
        \\Commands:
        \\  start       Start the app-server daemon with remote control enabled
        \\  stop        Stop the app-server daemon
        \\  help        Print this message or the help of the given subcommand(s)
        \\
        \\Options:
        \\      --json
        \\          Emit machine-readable JSON.
        \\
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

fn printHelpForCommand(command: Command) void {
    switch (command) {
        .foreground => printHelp(),
        .start, .stop => printCommandHelp(command),
    }
}

fn printHelpTarget(target: HelpTarget) void {
    switch (target) {
        .root => printHelp(),
        .start => printCommandHelp(.start),
        .stop => printCommandHelp(.stop),
        .help_cmd => printHelpCommandHelp(),
    }
}

fn printHelpCommandHelp() void {
    std.debug.print(
        \\Print this message or the help of the given subcommand(s)
        \\
        \\Usage: codex-zig remote-control help [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...  Print help for the subcommand(s)
        \\
    , .{});
}

fn printCommandHelp(command: Command) void {
    switch (command) {
        .foreground => printHelp(),
        .start => std.debug.print(
            \\Start the app-server daemon with remote control enabled
            \\
            \\Usage: codex-zig remote-control start [OPTIONS]
            \\
            \\Options:
            \\      --json
            \\          Emit machine-readable JSON.
            \\
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
        , .{}),
        .stop => std.debug.print(
            \\Stop the app-server daemon
            \\
            \\Usage: codex-zig remote-control stop [OPTIONS]
            \\
            \\Options:
            \\      --json
            \\          Emit machine-readable JSON.
            \\
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
        , .{}),
    }
}

test "remote-control command appends feature override after user toggles" {
    const allocator = std.testing.allocator;
    const raw_args = [_][]const u8{ "--disable", "remote_control", "--enable", "goals" };
    var parsed = try parseArgSlice(allocator, raw_args[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Command.foreground, parsed.command);
    try std.testing.expect(!parsed.json);
    try std.testing.expectEqual(@as(usize, 2), parsed.feature_overrides.items.items.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.child_global_args.items.len);
    try std.testing.expectEqualStrings("remote_control", parsed.feature_overrides.items.items[0].key);
    try std.testing.expectEqual(true, parsed.feature_overrides.items.items[0].enabled);
    try std.testing.expectEqualStrings("goals", parsed.feature_overrides.items.items[1].key);
    try std.testing.expectEqual(true, parsed.feature_overrides.items.items[1].enabled);
}

test "remote-control command parses daemon subcommands and json" {
    const allocator = std.testing.allocator;
    const start_args = [_][]const u8{ "--json", "start" };
    var start = try parseArgSlice(allocator, start_args[0..]);
    defer start.deinit(allocator);

    try std.testing.expectEqual(Command.start, start.command);
    try std.testing.expect(start.json);
    try std.testing.expectEqual(true, start.feature_overrides.get("remote_control").?);
    try std.testing.expectEqual(@as(usize, 0), start.child_global_args.items.len);

    const stop_args = [_][]const u8{ "stop", "--json" };
    var stop = try parseArgSlice(allocator, stop_args[0..]);
    defer stop.deinit(allocator);

    try std.testing.expectEqual(Command.stop, stop.command);
    try std.testing.expect(stop.json);
    try std.testing.expectEqual(true, stop.feature_overrides.get("remote_control").?);
    try std.testing.expectEqual(@as(usize, 0), stop.child_global_args.items.len);
}

test "remote-control command rejects unexpected positional arguments" {
    const allocator = std.testing.allocator;
    const status_args = [_][]const u8{"status"};
    try std.testing.expectError(
        error.UnexpectedRemoteControlArgument,
        parseArgSlice(allocator, status_args[0..]),
    );

    const extra_args = [_][]const u8{ "stop", "extra" };
    try std.testing.expectError(
        error.UnexpectedRemoteControlArgument,
        parseArgSlice(allocator, extra_args[0..]),
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
    try std.testing.expectEqual(@as(usize, 3), parsed.child_global_args.items.len);
    try std.testing.expectEqualStrings("-c", parsed.child_global_args.items[0]);
    try std.testing.expectEqualStrings("model=\"o3\"", parsed.child_global_args.items[1]);
    try std.testing.expectEqualStrings("--config=chatgpt_base_url=http://127.0.0.1:9", parsed.child_global_args.items[2]);
}

test "remote-control command preserves root child global args before command-local args" {
    const allocator = std.testing.allocator;
    const root_args = [_][]const u8{ "-c", "model=\"o3\"" };
    const raw_args = [_][]const u8{ "--enable", "goals", "start" };
    var parsed = try parseArgSliceWithOptions(allocator, raw_args[0..], .{
        .child_global_args = root_args[0..],
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Command.start, parsed.command);
    try std.testing.expectEqual(@as(usize, 4), parsed.child_global_args.items.len);
    try std.testing.expectEqualStrings("-c", parsed.child_global_args.items[0]);
    try std.testing.expectEqualStrings("model=\"o3\"", parsed.child_global_args.items[1]);
    try std.testing.expectEqualStrings("--enable", parsed.child_global_args.items[2]);
    try std.testing.expectEqualStrings("goals", parsed.child_global_args.items[3]);
}
