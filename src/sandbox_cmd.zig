const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");
const workdir = @import("workdir.zig");

const SandboxKind = enum {
    macos,
    linux,
    windows,
};

const SandboxArgs = struct {
    help: bool = false,
    mode: ?config.SandboxMode = null,
    permissions_profile: ?[]const u8 = null,
    include_managed_config: bool = false,
    allow_unix_sockets: std.ArrayList([]const u8) = .empty,
    log_denials: bool = false,
    cwd: ?[]const u8 = null,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    command: []const []const u8 = &.{},

    fn deinit(self: SandboxArgs, allocator: std.mem.Allocator) void {
        if (self.permissions_profile) |profile| allocator.free(profile);
        for (self.allow_unix_sockets.items) |path| allocator.free(path);
        var sockets = self.allow_unix_sockets;
        sockets.deinit(allocator);
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
    const kind = parseSandboxKind(subcommand) orelse return error.UnknownSandboxSubcommand;

    var parsed = try parseSandboxArgs(allocator, raw_args.items[1..]);
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printMacosHelp();
        return;
    }
    if (parsed.command.len == 0) return error.MissingSandboxCommand;
    switch (kind) {
        .macos => if (builtin.os.tag != .macos) return error.SeatbeltUnsupported,
        .linux => return error.LinuxSandboxUnsupported,
        .windows => return error.WindowsSandboxUnsupported,
    }
    if (parsed.allow_unix_sockets.items.len > 0) return error.SandboxAllowUnixSocketUnsupported;
    if (parsed.log_denials) return error.SandboxLogDenialsUnsupported;

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    var sandbox_profile: ?config.SandboxPermissionProfile = null;
    defer if (sandbox_profile) |*profile| profile.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (parsed.mode) |mode| cfg.sandbox_mode = mode;
    if (parsed.permissions_profile) |profile| {
        sandbox_profile = try config.loadSandboxPermissionProfile(allocator, profile);
        cfg.sandbox_mode = sandbox_profile.?.mode;
    }

    const effective_cwd = parsed.cwd orelse options.cwd;
    if (effective_cwd) |cwd| try workdir.change(cwd);

    const profile_writable_roots = if (sandbox_profile) |profile|
        profile.additional_writable_roots.items
    else
        &.{};
    const option_and_profile_roots = try cli_utils.mergeStringSlices(
        allocator,
        options.additional_writable_roots,
        profile_writable_roots,
    );
    defer allocator.free(option_and_profile_roots);
    const additional_writable_roots = try cli_utils.mergeStringSlices(
        allocator,
        option_and_profile_roots,
        parsed.additional_writable_roots.items,
    );
    defer allocator.free(additional_writable_roots);

    const include_cwd_write_root = if (sandbox_profile) |profile| profile.include_cwd_write_root else true;
    try runCommand(allocator, parsed.command, cfg.sandbox_mode, additional_writable_roots, include_cwd_write_root);
}

fn parseSandboxKind(subcommand: []const u8) ?SandboxKind {
    if (std.mem.eql(u8, subcommand, "macos") or std.mem.eql(u8, subcommand, "seatbelt")) return .macos;
    if (std.mem.eql(u8, subcommand, "linux") or std.mem.eql(u8, subcommand, "landlock")) return .linux;
    if (std.mem.eql(u8, subcommand, "windows")) return .windows;
    return null;
}

fn parseSandboxArgs(allocator: std.mem.Allocator, args: []const []const u8) !SandboxArgs {
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
        if (!end_options and std.mem.eql(u8, arg, "--permissions-profile")) {
            index += 1;
            if (index >= args.len) return error.MissingSandboxOptionValue;
            if (parsed.permissions_profile) |existing| allocator.free(existing);
            parsed.permissions_profile = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--permissions-profile=")) {
            if (parsed.permissions_profile) |existing| allocator.free(existing);
            parsed.permissions_profile = try allocator.dupe(u8, arg["--permissions-profile=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--include-managed-config")) {
            parsed.include_managed_config = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--allow-unix-socket")) {
            index += 1;
            if (index >= args.len) return error.MissingSandboxOptionValue;
            try parsed.allow_unix_sockets.append(allocator, try allocator.dupe(u8, args[index]));
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--allow-unix-socket=")) {
            try parsed.allow_unix_sockets.append(allocator, try allocator.dupe(u8, arg["--allow-unix-socket=".len..]));
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--log-denials")) {
            parsed.log_denials = true;
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
        break;
    }

    if (!parsed.help and parsed.cwd != null and parsed.permissions_profile == null) {
        return error.MissingSandboxPermissionsProfile;
    }
    if (!parsed.help and parsed.include_managed_config and parsed.permissions_profile == null) {
        return error.MissingSandboxPermissionsProfile;
    }

    return parsed;
}

fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    mode: config.SandboxMode,
    additional_writable_roots: []const []const u8,
    include_cwd_write_root: bool,
) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var sandboxed_argv: ?sandbox.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(allocator);
    const effective_argv = if (sandbox.shouldSandbox(mode)) blk: {
        sandboxed_argv = try sandbox.wrapArgvWithCwdOptions(allocator, mode, argv, additional_writable_roots, null, include_cwd_write_root);
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
        \\  linux, landlock  Recognized Rust-compatible Linux sandbox command
        \\  windows          Recognized Rust-compatible Windows sandbox command
        \\
    , .{});
}

fn printMacosHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig sandbox macos [OPTIONS] -- COMMAND [ARGS...]
        \\
        \\Options:
        \\  --permissions-profile NAME
        \\                      Apply :read-only, :workspace, :danger-no-sandbox, or a supported custom [permissions] profile
        \\  --include-managed-config
        \\                      Recognize managed config with --permissions-profile
        \\  --allow-unix-socket PATH
        \\                      Parse Rust socket allowlists; currently returns an explicit unsupported error
        \\  --log-denials      Parse Rust denial logging; currently returns an explicit unsupported error
        \\  -s, --sandbox MODE  read-only, workspace-write, or danger-full-access
        \\  -C, --cd DIR        Profile working root; requires --permissions-profile
        \\  --add-dir DIR       Allow workspace-write command to write DIR
        \\
    , .{});
}

test "sandbox macos args parse command and options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--sandbox", "read-only", "--add-dir", "/tmp/extra", "--", "/bin/echo", "ok" };
    const parsed = try parseSandboxArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(config.SandboxMode.read_only, parsed.mode.?);
    try std.testing.expectEqualStrings("/tmp/extra", parsed.additional_writable_roots.items[0]);
    try std.testing.expectEqualStrings("/bin/echo", parsed.command[0]);
    try std.testing.expectEqualStrings("ok", parsed.command[1]);
}

test "sandbox args parse Rust seatbelt-only controls" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--allow-unix-socket", "/tmp/codex-browser-use", "--allow-unix-socket=relative.sock", "--log-denials", "--", "/bin/echo", "ok" };
    const parsed = try parseSandboxArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.allow_unix_sockets.items.len);
    try std.testing.expectEqualStrings("/tmp/codex-browser-use", parsed.allow_unix_sockets.items[0]);
    try std.testing.expectEqualStrings("relative.sock", parsed.allow_unix_sockets.items[1]);
    try std.testing.expect(parsed.log_denials);
    try std.testing.expectEqualStrings("/bin/echo", parsed.command[0]);
    try std.testing.expectEqualStrings("ok", parsed.command[1]);
}

test "sandbox args parse Rust permission profile controls" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--permissions-profile", ":workspace", "--include-managed-config", "--cd", "/tmp/profile-root", "--", "/bin/echo", "ok" };
    const parsed = try parseSandboxArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings(":workspace", parsed.permissions_profile.?);
    try std.testing.expect(parsed.include_managed_config);
    try std.testing.expectEqualStrings("/tmp/profile-root", parsed.cwd.?);
    try std.testing.expectEqualStrings("/bin/echo", parsed.command[0]);
    try std.testing.expectEqualStrings("ok", parsed.command[1]);
}

test "sandbox args require permission profile for profile controls" {
    const allocator = std.testing.allocator;
    const cwd_only = [_][]const u8{ "--cd", "/tmp", "--", "/bin/echo" };
    try std.testing.expectError(error.MissingSandboxPermissionsProfile, parseSandboxArgs(allocator, cwd_only[0..]));

    const managed_only = [_][]const u8{ "--include-managed-config", "--", "/bin/echo" };
    try std.testing.expectError(error.MissingSandboxPermissionsProfile, parseSandboxArgs(allocator, managed_only[0..]));
}

test "sandbox permission profile resolver supports Rust built-ins" {
    const allocator = std.testing.allocator;
    var read_only = (try config.loadSandboxPermissionProfile(allocator, ":read-only"));
    defer read_only.deinit(allocator);
    var workspace = (try config.loadSandboxPermissionProfile(allocator, ":workspace"));
    defer workspace.deinit(allocator);
    var danger = (try config.loadSandboxPermissionProfile(allocator, ":danger-no-sandbox"));
    defer danger.deinit(allocator);

    try std.testing.expectEqual(config.SandboxMode.read_only, read_only.mode);
    try std.testing.expectEqual(config.SandboxMode.workspace_write, workspace.mode);
    try std.testing.expectEqual(config.SandboxMode.danger_full_access, danger.mode);
}

test "sandbox macos args parse help" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--help"};
    const parsed = try parseSandboxArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.help);
}

test "sandbox kind recognizes Rust platform aliases" {
    try std.testing.expectEqual(SandboxKind.macos, parseSandboxKind("macos").?);
    try std.testing.expectEqual(SandboxKind.macos, parseSandboxKind("seatbelt").?);
    try std.testing.expectEqual(SandboxKind.linux, parseSandboxKind("linux").?);
    try std.testing.expectEqual(SandboxKind.linux, parseSandboxKind("landlock").?);
    try std.testing.expectEqual(SandboxKind.windows, parseSandboxKind("windows").?);
    try std.testing.expect(parseSandboxKind("other") == null);
}

test "sandbox args reject removed full auto flag" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--full-auto", "--" };
    try std.testing.expectError(error.UnknownSandboxOption, parseSandboxArgs(allocator, argv[0..]));
}
