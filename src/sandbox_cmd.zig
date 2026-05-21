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

    const original_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(original_cwd);
    const allow_unix_sockets = try sandbox.resolveUnixSocketPathsAgainst(allocator, original_cwd, parsed.allow_unix_sockets.items);
    defer sandbox.freeResolvedPaths(allocator, allow_unix_sockets);

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    var sandbox_profile: ?config.SandboxPermissionProfile = null;
    defer if (sandbox_profile) |*profile| profile.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (parsed.mode) |mode| cfg.sandbox_mode = mode;
    if (parsed.permissions_profile) |profile| {
        sandbox_profile = try config.loadSandboxPermissionProfileWithOptions(allocator, profile, .{
            .allow_read_denied_globs = true,
        });
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
    const network_enabled = if (sandbox_profile) |profile| profile.network_enabled else true;
    const read_denied_roots = if (sandbox_profile) |profile| profile.read_denied_roots.items else &.{};
    const read_denied_globs = if (sandbox_profile) |profile| profile.read_denied_globs.items else &.{};
    try runCommand(allocator, parsed.command, cfg.sandbox_mode, additional_writable_roots, include_cwd_write_root, network_enabled, read_denied_roots, read_denied_globs, allow_unix_sockets, parsed.log_denials);
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
    network_enabled: bool,
    read_denied_roots: []const []const u8,
    read_denied_globs: []const []const u8,
    allow_unix_sockets: []const []const u8,
    log_denials: bool,
) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var sandboxed_argv: ?sandbox.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(allocator);
    const effective_argv = if (sandbox.shouldSandbox(mode)) blk: {
        sandboxed_argv = try sandbox.wrapArgvWithPolicy(allocator, mode, argv, additional_writable_roots, .{
            .include_cwd_write_root = include_cwd_write_root,
            .network_enabled = network_enabled,
            .read_denied_roots = read_denied_roots,
            .read_denied_globs = read_denied_globs,
            .allow_unix_sockets = allow_unix_sockets,
        });
        break :blk sandboxed_argv.?.argv;
    } else argv;
    var child_env: ?std.process.Environ.Map = null;
    defer if (child_env) |*env_map| env_map.deinit();
    if (sandboxed_argv != null) {
        child_env = try sandbox.environmentWithSeatbeltMarker(allocator);
    }

    var denial_log_stream: ?std.process.Child = null;
    if (log_denials) {
        denial_log_stream = startSandboxDenialLogStream(io_instance.io()) catch null;
        if (denial_log_stream != null) {
            std.Io.sleep(
                io_instance.io(),
                .{ .nanoseconds = 1000 * std.time.ns_per_ms },
                .awake,
            ) catch {};
        }
    }
    defer if (denial_log_stream) |*child| child.kill(io_instance.io());

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = effective_argv,
        .environ_map = if (child_env) |*env_map| env_map else null,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try cli_utils.writeStdout(result.stdout);
    try cli_utils.writeStderr(result.stderr);
    if (log_denials) {
        const log_output = if (denial_log_stream) |*child| blk: {
            const captured = stopSandboxDenialLogStream(allocator, io_instance.io(), child) catch null;
            denial_log_stream = null;
            break :blk captured;
        } else null;
        defer if (log_output) |output| allocator.free(output);
        try printSandboxDenials(allocator, log_output orelse "");
    }

    switch (result.term) {
        .exited => |code| if (code != 0) std.process.exit(@intCast(@min(code, 255))),
        else => return error.SandboxedCommandTerminated,
    }
}

fn startSandboxDenialLogStream(io: std.Io) !std.process.Child {
    const predicate = "(((processID == 0) AND (senderImagePath CONTAINS \"/Sandbox\")) OR (subsystem == \"com.apple.sandbox.reporting\"))";
    const argv = [_][]const u8{ "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", predicate };
    return std.process.spawn(io, .{
        .argv = argv[0..],
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

fn stopSandboxDenialLogStream(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child) ![]u8 {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    std.Io.sleep(
        io,
        .{ .nanoseconds = 1000 * std.time.ns_per_ms },
        .awake,
    ) catch {};
    if (child.id) |pid| {
        std.posix.kill(pid, .TERM) catch {};
    }

    const stdout_reader = multi_reader.reader(0);
    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 2 * 1024 * 1024) break;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {},
    }
    multi_reader.checkAnyError() catch {};

    _ = child.wait(io) catch {};
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    allocator.free(stderr);
    return stdout;
}

fn printSandboxDenials(allocator: std.mem.Allocator, log_output: []const u8) !void {
    try cli_utils.writeStderr("\n=== Sandbox denials ===\n");

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = seen.keyIterator();
        while (iterator.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, log_output, '\n');
    while (lines.next()) |line| {
        const message = eventMessageFromLogLine(allocator, line) catch continue;
        defer allocator.free(message);
        const denial = parseSandboxDenialMessage(message) orelse continue;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ denial.name, denial.capability });
        errdefer allocator.free(key);
        if (seen.contains(key)) {
            allocator.free(key);
            continue;
        }
        try seen.put(key, {});
        const rendered = try std.fmt.allocPrint(allocator, "({s}) {s}\n", .{ denial.name, denial.capability });
        defer allocator.free(rendered);
        try cli_utils.writeStderr(rendered);
        count += 1;
    }

    if (count == 0) try cli_utils.writeStderr("None found.\n");
}

fn eventMessageFromLogLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (std.mem.trim(u8, line, " \t\r\n").len == 0) return error.EmptyLogLine;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidLogLine,
    };
    const message_value = object.get("eventMessage") orelse return error.InvalidLogLine;
    const message = switch (message_value) {
        .string => |value| value,
        else => return error.InvalidLogLine,
    };
    return allocator.dupe(u8, message);
}

const ParsedSandboxDenial = struct {
    name: []const u8,
    pid: []const u8,
    capability: []const u8,
};

fn parseSandboxDenialMessage(message: []const u8) ?ParsedSandboxDenial {
    const prefix = "Sandbox:";
    if (!std.mem.startsWith(u8, message, prefix)) return null;
    const after_prefix = std.mem.trim(u8, message[prefix.len..], " \t");
    const marker = ") deny(";
    const marker_index = std.mem.indexOf(u8, after_prefix, marker) orelse return null;
    const before_marker = after_prefix[0..marker_index];
    const open_index = std.mem.lastIndexOfScalar(u8, before_marker, '(') orelse return null;
    const name = std.mem.trim(u8, before_marker[0..open_index], " \t");
    if (name.len == 0) return null;
    const parsed_pid = std.mem.trim(u8, before_marker[open_index + 1 ..], " \t");
    if (parsed_pid.len == 0) return null;
    const deny_start = marker_index + marker.len;
    const deny_end = std.mem.indexOfScalarPos(u8, after_prefix, deny_start, ')') orelse return null;
    const capability = std.mem.trim(u8, after_prefix[deny_end + 1 ..], " \t");
    if (capability.len == 0) return null;
    return .{ .name = name, .pid = parsed_pid, .capability = capability };
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
        \\                      Allow AF_UNIX bind/connect operations rooted at PATH
        \\  --log-denials      Print a macOS sandbox denial summary after the command exits
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
    try std.testing.expect(!read_only.network_enabled);
    try std.testing.expectEqual(config.SandboxMode.workspace_write, workspace.mode);
    try std.testing.expect(!workspace.network_enabled);
    try std.testing.expectEqual(config.SandboxMode.danger_full_access, danger.mode);
    try std.testing.expect(danger.network_enabled);
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

test "sandbox denial messages parse name and capability" {
    const parsed = parseSandboxDenialMessage("Sandbox: sh(1234) deny(1) file-write-create /tmp/blocked") orelse return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("sh", parsed.name);
    try std.testing.expectEqualStrings("1234", parsed.pid);
    try std.testing.expectEqualStrings("file-write-create /tmp/blocked", parsed.capability);
    try std.testing.expect(parseSandboxDenialMessage("other") == null);
}
