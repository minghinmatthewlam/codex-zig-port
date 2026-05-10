const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");
const workdir = @import("workdir.zig");

const SandboxArgs = struct {
    help: bool = false,
    mode: ?config.SandboxMode = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    command: []const []const u8 = &.{},

    fn deinit(self: SandboxArgs, allocator: std.mem.Allocator) void {
        if (self.cwd) |cwd| allocator.free(cwd);
        for (self.additional_writable_roots.items) |root| allocator.free(root);
        var roots = self.additional_writable_roots;
        roots.deinit(allocator);
        if (self.command.len > 0) allocator.free(self.command);
    }
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    cwd: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    if (raw_args.items.len == 0) {
        printHelp();
        return error.MissingSandboxSubcommand;
    }

    const subcommand = raw_args.items[0];
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (!std.mem.eql(u8, subcommand, "macos") and !std.mem.eql(u8, subcommand, "seatbelt")) {
        return error.UnknownSandboxSubcommand;
    }

    var parsed = try parseMacosArgs(allocator, raw_args.items[1..]);
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printMacosHelp();
        return;
    }
    if (parsed.command.len == 0) return error.MissingSandboxCommand;
    if (builtin.os.tag != .macos) return error.SeatbeltUnsupported;

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (parsed.mode) |mode| cfg.sandbox_mode = mode;

    const effective_cwd = parsed.cwd orelse options.cwd;
    if (effective_cwd) |cwd| try workdir.change(cwd);

    const additional_writable_roots = try cli_utils.mergeStringSlices(
        allocator,
        options.additional_writable_roots,
        parsed.additional_writable_roots.items,
    );
    defer allocator.free(additional_writable_roots);

    try runCommand(allocator, parsed.command, cfg.sandbox_mode, additional_writable_roots);
}

fn parseMacosArgs(allocator: std.mem.Allocator, args: []const []const u8) !SandboxArgs {
    var parsed = SandboxArgs{};
    errdefer parsed.deinit(allocator);

    var index: usize = 0;
    var end_options = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s"))) {
            index += 1;
            if (index >= args.len) return error.MissingSandboxOptionValue;
            parsed.mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--sandbox=")) {
            parsed.mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C"))) {
            index += 1;
            if (index >= args.len) return error.MissingSandboxOptionValue;
            if (parsed.cwd) |existing| allocator.free(existing);
            parsed.cwd = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--cd=")) {
            if (parsed.cwd) |existing| allocator.free(existing);
            parsed.cwd = try allocator.dupe(u8, arg["--cd=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingSandboxOptionValue;
            try parsed.additional_writable_roots.append(allocator, try allocator.dupe(u8, args[index]));
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--add-dir=")) {
            try parsed.additional_writable_roots.append(allocator, try allocator.dupe(u8, arg["--add-dir=".len..]));
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownSandboxOption;
        }

        parsed.command = try dupeRemaining(allocator, args[index..]);
        return parsed;
    }

    return parsed;
}

fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    mode: config.SandboxMode,
    additional_writable_roots: []const []const u8,
) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var sandboxed_argv: ?sandbox.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(allocator);
    const effective_argv = if (sandbox.shouldSandbox(mode)) blk: {
        sandboxed_argv = try sandbox.wrapArgv(allocator, mode, argv, additional_writable_roots);
        break :blk sandboxed_argv.?.argv;
    } else argv;

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = effective_argv,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try cli_utils.writeStdout(result.stdout);
    try cli_utils.writeStderr(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) std.process.exit(@intCast(@min(code, 255))),
        else => return error.SandboxedCommandTerminated,
    }
}

fn dupeRemaining(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    const command = try allocator.alloc([]const u8, args.len);
    errdefer allocator.free(command);
    @memcpy(command, args);
    return command;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig sandbox macos [OPTIONS] -- COMMAND [ARGS...]
        \\  codex-zig sandbox seatbelt [OPTIONS] -- COMMAND [ARGS...]
        \\
        \\Subcommands:
        \\  macos, seatbelt  Run a command under macOS Seatbelt
        \\
    , .{});
}

fn printMacosHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig sandbox macos [OPTIONS] -- COMMAND [ARGS...]
        \\
        \\Options:
        \\  -s, --sandbox MODE  read-only, workspace-write, or danger-full-access
        \\  -C, --cd DIR        Use DIR as the working root
        \\  --add-dir DIR       Allow workspace-write command to write DIR
        \\
    , .{});
}

test "sandbox macos args parse command and options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--sandbox", "read-only", "--add-dir", "/tmp/extra", "--", "/bin/echo", "ok" };
    const parsed = try parseMacosArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(config.SandboxMode.read_only, parsed.mode.?);
    try std.testing.expectEqualStrings("/tmp/extra", parsed.additional_writable_roots.items[0]);
    try std.testing.expectEqualStrings("/bin/echo", parsed.command[0]);
    try std.testing.expectEqualStrings("ok", parsed.command[1]);
}

test "sandbox macos args parse help" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--help"};
    const parsed = try parseMacosArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.help);
}
