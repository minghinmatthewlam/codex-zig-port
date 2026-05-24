const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const features_cmd = @import("features_cmd.zig");
const sandbox = @import("sandbox.zig");
const workdir = @import("workdir.zig");

extern "c" fn proc_listchildpids(ppid: std.posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_listpgrppids(pgrpid: std.posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

const SandboxKind = enum {
    macos,
    linux,
    windows,
};

const SandboxArgs = struct {
    help: bool = false,
    profile_override: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    mode: ?config.SandboxMode = null,
    permissions_profile: ?[]const u8 = null,
    include_managed_config: bool = false,
    allow_unix_sockets: std.ArrayList([]const u8) = .empty,
    log_denials: bool = false,
    cwd: ?[]const u8 = null,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    command: []const []const u8 = &.{},

    fn deinit(self: SandboxArgs, allocator: std.mem.Allocator) void {
        var feature_overrides = self.feature_overrides;
        feature_overrides.deinit(allocator);
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

const SandboxRootOptions = struct {
    profile_override: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},

    fn deinit(self: *SandboxRootOptions, allocator: std.mem.Allocator) void {
        self.feature_overrides.deinit(allocator);
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

    var root_options = SandboxRootOptions{};
    defer root_options.deinit(allocator);
    var root_index: usize = 0;
    const kind = while (root_index < raw_args.items.len) : (root_index += 1) {
        const subcommand = raw_args.items[root_index];
        if (isHelpFlag(subcommand)) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, subcommand, "help")) {
            try printHelpForArgs(raw_args.items[root_index + 1 ..]);
            return;
        }
        if (try parseSandboxRootOption(allocator, raw_args.items, &root_index, &root_options)) {
            continue;
        }
        break parseSandboxKind(subcommand) orelse return error.UnknownSandboxSubcommand;
    } else {
        return error.MissingSandboxSubcommand;
    };

    var parsed = try parseSandboxArgs(allocator, raw_args.items[root_index + 1 ..]);
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printSandboxKindHelp(kind);
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

    const effective_profile = parsed.profile_override orelse root_options.profile_override orelse options.profile;
    var runtime_overrides = config.mergeRuntimeOverrides(options.runtime_overrides, root_options.runtime_overrides);
    runtime_overrides = config.mergeRuntimeOverrides(runtime_overrides, parsed.runtime_overrides);

    var cfg = try config.loadWithOptions(allocator, .{ .profile = effective_profile });
    defer cfg.deinit(allocator);
    var sandbox_profile: ?config.SandboxPermissionProfile = null;
    defer if (sandbox_profile) |*profile| profile.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, runtime_overrides);
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

fn parseSandboxRootOption(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    parsed: *SandboxRootOptions,
) !bool {
    return parseSandboxConfigFeatureOption(
        allocator,
        args,
        index,
        &parsed.profile_override,
        &parsed.runtime_overrides,
        &parsed.feature_overrides,
    );
}

fn parseSandboxConfigFeatureOption(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    profile_override: *?[]const u8,
    runtime_overrides: *config.RuntimeOverrides,
    feature_overrides: *features_cmd.FeatureOverrides,
) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingConfigOptionValue;
        if (std.mem.eql(u8, args[index.*], "--")) return error.MissingConfigOptionValue;
        try config.applyRawConfigOverride(runtime_overrides, profile_override, args[index.*]);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--config=")) {
        try config.applyRawConfigOverride(runtime_overrides, profile_override, arg["--config=".len..]);
        return true;
    }
    if (std.mem.eql(u8, arg, "--enable")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingFeatureName;
        if (std.mem.eql(u8, args[index.*], "--")) return error.MissingFeatureName;
        try features_cmd.putRuntimeToggle(allocator, feature_overrides, args[index.*], true);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--enable=")) {
        try features_cmd.putRuntimeToggle(allocator, feature_overrides, arg["--enable=".len..], true);
        return true;
    }
    if (std.mem.eql(u8, arg, "--disable")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingFeatureName;
        if (std.mem.eql(u8, args[index.*], "--")) return error.MissingFeatureName;
        try features_cmd.putRuntimeToggle(allocator, feature_overrides, args[index.*], false);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--disable=")) {
        try features_cmd.putRuntimeToggle(allocator, feature_overrides, arg["--disable=".len..], false);
        return true;
    }
    return false;
}

pub fn printHelpForArgs(args: []const []const u8) !void {
    if (args.len == 0) {
        printHelp();
        return;
    }
    if (args.len != 1) return error.UnexpectedHelpArgument;
    const target = args[0];
    if (isHelpFlag(target)) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, target, "help")) {
        printSandboxHelpSubcommandHelp();
        return;
    }
    const kind = parseSandboxKind(target) orelse return error.UnknownSandboxSubcommand;
    printSandboxKindHelp(kind);
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
        if (!end_options and try parseSandboxConfigFeatureOption(
            allocator,
            args,
            &index,
            &parsed.profile_override,
            &parsed.runtime_overrides,
            &parsed.feature_overrides,
        )) {
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

    if (log_denials) {
        var result = try runCommandWithDenialLog(
            allocator,
            &io_instance,
            effective_argv,
            if (child_env) |*env_map| env_map else null,
        );
        defer result.deinit(allocator);

        try cli_utils.writeStdout(result.stdout);
        try cli_utils.writeStderr(result.stderr);
        try printSandboxDenials(allocator, result.log_output, &result.tracked_pids);

        switch (result.term) {
            .exited => |code| if (code != 0) std.process.exit(@intCast(@min(code, 255))),
            else => return error.SandboxedCommandTerminated,
        }
        return;
    }

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

    switch (result.term) {
        .exited => |code| if (code != 0) std.process.exit(@intCast(@min(code, 255))),
        else => return error.SandboxedCommandTerminated,
    }
}

const COMMAND_OUTPUT_LIMIT = 10 * 1024 * 1024;
const DENIAL_LOG_OUTPUT_LIMIT = 2 * 1024 * 1024;
const DENIAL_LOG_STARTUP_GRACE_MS = 1000;
const DENIAL_LOG_SHUTDOWN_GRACE_MS = 1000;

var sandbox_forward_process_group = std.atomic.Value(i32).init(0);
var sandbox_forward_log_pid = std.atomic.Value(i32).init(0);

const SandboxLogRunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    log_output: []u8,
    tracked_pids: std.AutoHashMap(i32, void),

    fn deinit(self: *SandboxLogRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        allocator.free(self.log_output);
        self.tracked_pids.deinit();
    }
};

const SandboxSignalForwarder = struct {
    int_action: std.posix.Sigaction = undefined,
    term_action: std.posix.Sigaction = undefined,
    hup_action: std.posix.Sigaction = undefined,
    installed: bool = false,

    fn install(process_group_id: i32, log_pid: i32) SandboxSignalForwarder {
        sandbox_forward_process_group.store(process_group_id, .seq_cst);
        sandbox_forward_log_pid.store(log_pid, .seq_cst);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = forwardSandboxSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var forwarder = SandboxSignalForwarder{};
        std.posix.sigaction(.INT, &action, &forwarder.int_action);
        std.posix.sigaction(.TERM, &action, &forwarder.term_action);
        std.posix.sigaction(.HUP, &action, &forwarder.hup_action);
        forwarder.installed = true;
        return forwarder;
    }

    fn deinit(self: *SandboxSignalForwarder) void {
        sandbox_forward_process_group.store(0, .seq_cst);
        sandbox_forward_log_pid.store(0, .seq_cst);
        if (!self.installed) return;
        std.posix.sigaction(.INT, &self.int_action, null);
        std.posix.sigaction(.TERM, &self.term_action, null);
        std.posix.sigaction(.HUP, &self.hup_action, null);
        self.* = .{};
    }
};

fn forwardSandboxSignal(signal: std.c.SIG) callconv(.c) void {
    const process_group_id = sandbox_forward_process_group.load(.seq_cst);
    if (process_group_id > 0) {
        _ = std.c.kill(-@as(std.c.pid_t, @intCast(process_group_id)), signal);
    }
    const log_pid = sandbox_forward_log_pid.load(.seq_cst);
    if (log_pid > 0) {
        _ = std.c.kill(@as(std.c.pid_t, @intCast(log_pid)), signal);
    }
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &default_action, null);
    _ = std.c.kill(std.c.getpid(), signal);
}

fn runCommandWithDenialLog(
    allocator: std.mem.Allocator,
    io_instance: *std.Io.Threaded,
    argv: []const []const u8,
    environ_map: ?*std.process.Environ.Map,
) !SandboxLogRunResult {
    var denial_log_stream = startSandboxDenialLogStream(io_instance.io()) catch null;
    var denial_log_stream_alive = denial_log_stream != null;
    errdefer if (denial_log_stream_alive) {
        if (denial_log_stream) |*child| child.kill(io_instance.io());
    };
    if (denial_log_stream != null) {
        std.Io.sleep(
            io_instance.io(),
            .{ .nanoseconds = DENIAL_LOG_STARTUP_GRACE_MS * std.time.ns_per_ms },
            .awake,
        ) catch {};
    }

    var child = try std.process.spawn(io_instance.io(), .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .macos) 0 else null,
    });
    var child_alive = true;
    errdefer if (child_alive) killSandboxCommandGroup(io_instance.io(), &child);

    const root_pid = child.id orelse return error.SandboxedCommandTerminated;
    const log_pid: i32 = if (denial_log_stream) |log_child|
        @intCast(log_child.id orelse 0)
    else
        0;
    var signal_forwarder = SandboxSignalForwarder.install(@intCast(root_pid), log_pid);
    defer signal_forwarder.deinit();

    var pid_tracker = try SandboxPidTracker.init(allocator, @intCast(root_pid));
    defer pid_tracker.deinit();

    var stdout = std.ArrayList(u8).empty;
    errdefer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    errdefer stderr.deinit(allocator);
    var log_stdout = std.ArrayList(u8).empty;
    errdefer log_stdout.deinit(allocator);
    var log_stderr = std.ArrayList(u8).empty;
    defer log_stderr.deinit(allocator);
    var stdout_observed_len: usize = 0;
    var stderr_observed_len: usize = 0;
    var log_stdout_observed_len: usize = 0;
    var log_stderr_observed_len: usize = 0;
    var log_stdout_parse_cursor: usize = 0;

    while (true) {
        try pid_tracker.poll();
        if (pollSandboxChild(&child)) |term| {
            child_alive = false;
            try drainSandboxPostExit(
                io_instance,
                allocator,
                &child,
                if (denial_log_stream) |*log_child| log_child else null,
                &denial_log_stream_alive,
                &stdout,
                &stderr,
                &log_stdout,
                &log_stderr,
                &stdout_observed_len,
                &stderr_observed_len,
                &log_stdout_observed_len,
                &log_stderr_observed_len,
                &log_stdout_parse_cursor,
                &pid_tracker,
            );
            if (denial_log_stream) |*log_child| {
                try stopSandboxDenialLogStream(
                    io_instance,
                    allocator,
                    log_child,
                    &denial_log_stream_alive,
                    &log_stdout,
                    &log_stderr,
                    &log_stdout_observed_len,
                    &log_stderr_observed_len,
                    &log_stdout_parse_cursor,
                    &pid_tracker,
                );
                closeSandboxChildPipes(io_instance.io(), log_child);
            }
            closeSandboxChildPipes(io_instance.io(), &child);

            const stdout_owned = try stdout.toOwnedSlice(allocator);
            errdefer allocator.free(stdout_owned);
            const stderr_owned = try stderr.toOwnedSlice(allocator);
            errdefer allocator.free(stderr_owned);
            const log_stdout_owned = try log_stdout.toOwnedSlice(allocator);
            errdefer allocator.free(log_stdout_owned);
            var tracked_pids = pid_tracker.takeSeen();
            errdefer tracked_pids.deinit();
            return .{
                .term = term,
                .stdout = stdout_owned,
                .stderr = stderr_owned,
                .log_output = log_stdout_owned,
                .tracked_pids = tracked_pids,
            };
        }

        var made_progress = false;
        made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stdout, &stdout, &stdout_observed_len, COMMAND_OUTPUT_LIMIT, true, 0) or made_progress;
        try pid_tracker.poll();
        made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stderr, &stderr, &stderr_observed_len, COMMAND_OUTPUT_LIMIT, true, 0) or made_progress;
        try pid_tracker.poll();
        if (denial_log_stream) |*log_child| {
            made_progress = try readSandboxPipeChunk(io_instance, allocator, log_child.stdout, &log_stdout, &log_stdout_observed_len, DENIAL_LOG_OUTPUT_LIMIT, false, 0) or made_progress;
            try pid_tracker.poll();
            made_progress = try readSandboxPipeChunk(io_instance, allocator, log_child.stderr, &log_stderr, &log_stderr_observed_len, DENIAL_LOG_OUTPUT_LIMIT, false, 0) or made_progress;
            try addLiveSandboxDenialPidsFromLogOutput(allocator, log_stdout.items, &log_stdout_parse_cursor, &pid_tracker);
            if (denial_log_stream_alive and pollSandboxChild(log_child) != null) {
                denial_log_stream_alive = false;
            }
        }
        if (!made_progress) {
            std.Io.sleep(
                io_instance.io(),
                .{ .nanoseconds = std.time.ns_per_ms },
                .awake,
            ) catch {};
        }
    }
}

const SandboxPidTracker = struct {
    allocator: std.mem.Allocator,
    kq: ?c_int,
    process_group_id: ?i32,
    seen: std.AutoHashMap(i32, void),
    active: std.AutoHashMap(i32, void),

    fn init(allocator: std.mem.Allocator, root_pid: i32) !SandboxPidTracker {
        var tracker = SandboxPidTracker{
            .allocator = allocator,
            .kq = null,
            .process_group_id = null,
            .seen = std.AutoHashMap(i32, void).init(allocator),
            .active = std.AutoHashMap(i32, void).init(allocator),
        };
        errdefer tracker.deinit();

        try tracker.seen.put(root_pid, {});
        if (builtin.os.tag != .macos or root_pid <= 0) return tracker;

        const kq = std.c.kqueue();
        if (kq < 0) return tracker;
        tracker.kq = kq;
        tracker.process_group_id = root_pid;
        try tracker.addPidWatch(root_pid);
        try tracker.watchProcessGroup();
        return tracker;
    }

    fn deinit(self: *SandboxPidTracker) void {
        if (self.kq) |kq| _ = std.c.close(kq);
        self.seen.deinit();
        self.active.deinit();
    }

    fn takeSeen(self: *SandboxPidTracker) std.AutoHashMap(i32, void) {
        const seen = self.seen;
        self.seen = std.AutoHashMap(i32, void).init(self.allocator);
        return seen;
    }

    fn poll(self: *SandboxPidTracker) !void {
        if (builtin.os.tag != .macos) return;
        try self.watchProcessGroup();
        const kq = self.kq orelse return;
        if (self.active.count() == 0) return;

        var timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        var events: [32]std.posix.Kevent = undefined;
        const count = std.Io.Kqueue.kevent(kq, &.{}, events[0..], &timeout) catch return;
        for (events[0..count]) |event| {
            const pid: i32 = @intCast(event.ident);
            if ((event.flags & std.c.EV.ERROR) != 0) {
                _ = self.active.remove(pid);
                continue;
            }
            if ((event.fflags & std.c.NOTE.FORK) != 0) {
                try self.watchChildren(pid);
            }
            if ((event.fflags & std.c.NOTE.EXIT) != 0) {
                _ = self.active.remove(pid);
            }
        }
    }

    fn addPidWatch(self: *SandboxPidTracker, pid: i32) anyerror!void {
        if (pid <= 0) return;

        const newly_seen = !self.seen.contains(pid);
        if (newly_seen) try self.seen.put(pid, {});
        var should_recurse = newly_seen;

        if (!self.active.contains(pid)) {
            if (self.watchPid(pid)) {
                try self.active.put(pid, {});
                should_recurse = true;
            } else {
                _ = self.active.remove(pid);
                return;
            }
        }

        if (should_recurse) try self.watchChildren(pid);
    }

    fn addSeenPid(self: *SandboxPidTracker, pid: i32) !void {
        if (pid <= 0 or self.seen.contains(pid)) return;
        try self.seen.put(pid, {});
    }

    fn addPidIfInProcessGroup(self: *SandboxPidTracker, pid: i32) !void {
        if (builtin.os.tag != .macos) return;
        if (pid <= 0 or self.seen.contains(pid)) return;
        const process_group_id = self.process_group_id orelse return;
        const observed_process_group = getpgid(@intCast(pid));
        if (observed_process_group < 0) return;
        if (observed_process_group != process_group_id) return;
        try self.addSeenPid(pid);
    }

    fn watchPid(self: *SandboxPidTracker, pid: i32) bool {
        const kq = self.kq orelse return false;
        const change = std.posix.Kevent{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = std.c.NOTE.FORK | std.c.NOTE.EXEC | std.c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        };
        _ = std.Io.Kqueue.kevent(kq, &.{change}, &.{}, null) catch return false;
        return true;
    }

    fn watchChildren(self: *SandboxPidTracker, parent: i32) anyerror!void {
        if (builtin.os.tag != .macos) return;
        var capacity: usize = 16;
        while (true) {
            const children = try self.allocator.alloc(i32, capacity);
            defer self.allocator.free(children);

            const buffer_size = std.math.cast(c_int, children.len * @sizeOf(i32)) orelse return error.OutOfMemory;
            const count = proc_listchildpids(
                @intCast(parent),
                children.ptr,
                buffer_size,
            );
            if (count <= 0) return;

            const returned: usize = @intCast(count);
            if (returned < capacity) {
                for (children[0..returned]) |child_pid| try self.addPidWatch(child_pid);
                return;
            }
            capacity = @max(std.math.mul(usize, capacity, 2) catch returned + 16, returned + 16);
        }
    }

    fn watchProcessGroup(self: *SandboxPidTracker) anyerror!void {
        if (builtin.os.tag != .macos) return;
        const process_group_id = self.process_group_id orelse return;
        var capacity: usize = 16;
        while (true) {
            const pids = try self.allocator.alloc(i32, capacity);
            defer self.allocator.free(pids);

            const buffer_size = std.math.cast(c_int, pids.len * @sizeOf(i32)) orelse return error.OutOfMemory;
            const count = proc_listpgrppids(
                @intCast(process_group_id),
                pids.ptr,
                buffer_size,
            );
            if (count <= 0) return;

            const returned: usize = @intCast(count);
            if (returned < capacity) {
                for (pids[0..returned]) |pid| try self.addPidWatch(pid);
                return;
            }
            capacity = @max(std.math.mul(usize, capacity, 2) catch returned + 16, returned + 16);
        }
    }
};

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

fn stopSandboxDenialLogStream(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    child_alive: *bool,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    stdout_parse_cursor: *usize,
    pid_tracker: *SandboxPidTracker,
) !void {
    try drainSandboxLogStreamForDuration(
        io_instance,
        allocator,
        child,
        child_alive,
        stdout,
        stderr,
        stdout_observed_len,
        stderr_observed_len,
        stdout_parse_cursor,
        pid_tracker,
        DENIAL_LOG_SHUTDOWN_GRACE_MS,
    );
    if (child.id) |pid| {
        std.posix.kill(pid, .TERM) catch {};
    }
    var empty_rounds: usize = 0;
    while (child.id != null and empty_rounds < 20) {
        const made_progress = try drainSandboxLogStreamChunk(
            io_instance,
            allocator,
            child,
            child_alive,
            stdout,
            stderr,
            stdout_observed_len,
            stderr_observed_len,
            stdout_parse_cursor,
            pid_tracker,
        );
        if (!child_alive.*) break;
        if (made_progress) {
            empty_rounds = 0;
        } else {
            empty_rounds += 1;
        }
    }
    if (child.id != null) {
        child.kill(io_instance.io());
        child_alive.* = false;
    }
    try drainSandboxOutput(io_instance, allocator, child, stdout, stderr, stdout_observed_len, stderr_observed_len, DENIAL_LOG_OUTPUT_LIMIT);
    try addLiveSandboxDenialPidsFromLogOutput(allocator, stdout.items, stdout_parse_cursor, pid_tracker);
}

fn drainSandboxLogStreamForDuration(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    child_alive: *bool,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    stdout_parse_cursor: *usize,
    pid_tracker: *SandboxPidTracker,
    duration_ms: u64,
) !void {
    const started = std.Io.Timestamp.now(io_instance.io(), .awake);
    while (child_alive.* and elapsedSandboxMilliseconds(io_instance.io(), started) < duration_ms) {
        const made_progress = try drainSandboxLogStreamChunk(
            io_instance,
            allocator,
            child,
            child_alive,
            stdout,
            stderr,
            stdout_observed_len,
            stderr_observed_len,
            stdout_parse_cursor,
            pid_tracker,
        );
        if (!made_progress) {
            std.Io.sleep(
                io_instance.io(),
                .{ .nanoseconds = std.time.ns_per_ms },
                .awake,
            ) catch {};
        }
    }
}

fn drainSandboxLogStreamChunk(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    child_alive: *bool,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    stdout_parse_cursor: *usize,
    pid_tracker: *SandboxPidTracker,
) !bool {
    try pid_tracker.poll();
    var made_progress = false;
    made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stdout, stdout, stdout_observed_len, DENIAL_LOG_OUTPUT_LIMIT, false, 1) or made_progress;
    made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stderr, stderr, stderr_observed_len, DENIAL_LOG_OUTPUT_LIMIT, false, 1) or made_progress;
    try addLiveSandboxDenialPidsFromLogOutput(allocator, stdout.items, stdout_parse_cursor, pid_tracker);
    if (child_alive.* and pollSandboxChild(child) != null) {
        child_alive.* = false;
    }
    return made_progress;
}

fn drainSandboxPostExit(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    log_child: ?*std.process.Child,
    log_child_alive: *bool,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    log_stdout: *std.ArrayList(u8),
    log_stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    log_stdout_observed_len: *usize,
    log_stderr_observed_len: *usize,
    log_stdout_parse_cursor: *usize,
    pid_tracker: *SandboxPidTracker,
) !void {
    var stdout_open = child.stdout != null;
    var stderr_open = child.stderr != null;
    while (stdout_open or stderr_open) {
        try pid_tracker.poll();
        var made_progress = false;
        switch (try readSandboxPipeChunkState(io_instance, allocator, child.stdout, stdout, stdout_observed_len, COMMAND_OUTPUT_LIMIT, true, 1)) {
            .progress => made_progress = true,
            .idle => {},
            .closed => stdout_open = false,
        }
        switch (try readSandboxPipeChunkState(io_instance, allocator, child.stderr, stderr, stderr_observed_len, COMMAND_OUTPUT_LIMIT, true, 1)) {
            .progress => made_progress = true,
            .idle => {},
            .closed => stderr_open = false,
        }
        if (log_child) |log| {
            made_progress = try drainSandboxLogStreamChunk(
                io_instance,
                allocator,
                log,
                log_child_alive,
                log_stdout,
                log_stderr,
                log_stdout_observed_len,
                log_stderr_observed_len,
                log_stdout_parse_cursor,
                pid_tracker,
            ) or made_progress;
        }
        if (!made_progress) {
            std.Io.sleep(
                io_instance.io(),
                .{ .nanoseconds = std.time.ns_per_ms },
                .awake,
            ) catch {};
        }
    }
}

fn drainSandboxOutput(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    output_bytes_cap: usize,
) !void {
    var empty_rounds: usize = 0;
    while (empty_rounds < 2) {
        var made_progress = false;
        made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stdout, stdout, stdout_observed_len, output_bytes_cap, false, 1) or made_progress;
        made_progress = try readSandboxPipeChunk(io_instance, allocator, child.stderr, stderr, stderr_observed_len, output_bytes_cap, false, 1) or made_progress;
        if (made_progress) {
            empty_rounds = 0;
        } else {
            empty_rounds += 1;
        }
    }
}

const SandboxPipeReadResult = enum {
    idle,
    progress,
    closed,
};

fn readSandboxPipeChunk(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    maybe_file: ?std.Io.File,
    output: *std.ArrayList(u8),
    observed_len: *usize,
    output_bytes_cap: usize,
    error_on_cap: bool,
    timeout_ms: u64,
) !bool {
    return switch (try readSandboxPipeChunkState(
        io_instance,
        allocator,
        maybe_file,
        output,
        observed_len,
        output_bytes_cap,
        error_on_cap,
        timeout_ms,
    )) {
        .progress => true,
        .idle, .closed => false,
    };
}

fn readSandboxPipeChunkState(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    maybe_file: ?std.Io.File,
    output: *std.ArrayList(u8),
    observed_len: *usize,
    output_bytes_cap: usize,
    error_on_cap: bool,
    timeout_ms: u64,
) !SandboxPipeReadResult {
    const file = maybe_file orelse return .closed;
    var buffer: [4096]u8 = undefined;
    const result = io_instance.io().operateTimeout(.{ .file_read_streaming = .{
        .file = file,
        .data = &.{buffer[0..]},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return .idle,
        else => return err,
    };
    const count = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => return .closed,
        error.WouldBlock => return .idle,
        else => return err,
    };
    if (count == 0) return .closed;
    const previous_observed_len = observed_len.*;
    if (error_on_cap and count > output_bytes_cap -| previous_observed_len) return error.StreamTooLong;
    observed_len.* += count;
    const bytes = buffer[0..count];
    const remaining = output_bytes_cap -| previous_observed_len;
    try output.appendSlice(allocator, bytes[0..@min(bytes.len, remaining)]);
    return .progress;
}

fn pollSandboxChild(child: *std.process.Child) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    var status: c_int = 0;
    const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (result == 0) return null;
    if (result < 0) return null;
    child.id = null;

    const status_u: u32 = @intCast(status);
    if (std.c.W.IFEXITED(status_u)) return .{ .exited = std.c.W.EXITSTATUS(status_u) };
    if (std.c.W.IFSIGNALED(status_u)) return .{ .signal = std.c.W.TERMSIG(status_u) };
    if (std.c.W.IFSTOPPED(status_u)) return .{ .stopped = std.c.W.STOPSIG(status_u) };
    return .{ .unknown = status_u };
}

fn killSandboxCommandGroup(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| {
        if (builtin.os.tag == .macos) {
            _ = std.c.kill(-@as(std.c.pid_t, @intCast(pid)), .KILL);
        }
    }
    child.kill(io);
}

fn closeSandboxChildPipes(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |file| {
        file.close(io);
        child.stdin = null;
    }
    if (child.stdout) |file| {
        file.close(io);
        child.stdout = null;
    }
    if (child.stderr) |file| {
        file.close(io);
        child.stderr = null;
    }
}

fn addLiveSandboxDenialPidsFromLogOutput(
    allocator: std.mem.Allocator,
    log_output: []const u8,
    parse_cursor: *usize,
    pid_tracker: *SandboxPidTracker,
) !void {
    while (std.mem.indexOfScalarPos(u8, log_output, parse_cursor.*, '\n')) |newline_index| {
        const line = log_output[parse_cursor.*..newline_index];
        parse_cursor.* = newline_index + 1;
        const message = eventMessageFromLogLine(allocator, line) catch continue;
        defer allocator.free(message);
        const denial = parseSandboxDenialMessage(message) orelse continue;
        try pid_tracker.addPidIfInProcessGroup(denial.pid);
    }
}

fn elapsedSandboxMilliseconds(io: std.Io, started: std.Io.Timestamp) u64 {
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    if (elapsed.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
}

fn printSandboxDenials(allocator: std.mem.Allocator, log_output: []const u8, tracked_pids: *const std.AutoHashMap(i32, void)) !void {
    try cli_utils.writeStderr("\n=== Sandbox denials ===\n");
    const rendered = try renderSandboxDenialSummary(allocator, log_output, tracked_pids);
    defer allocator.free(rendered);
    try cli_utils.writeStderr(rendered);
}

fn renderSandboxDenialSummary(allocator: std.mem.Allocator, log_output: []const u8, tracked_pids: *const std.AutoHashMap(i32, void)) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

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
        if (!tracked_pids.contains(denial.pid)) continue;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ denial.name, denial.capability });
        errdefer allocator.free(key);
        if (seen.contains(key)) {
            allocator.free(key);
            continue;
        }
        try seen.put(key, {});
        const rendered = try std.fmt.allocPrint(allocator, "({s}) {s}\n", .{ denial.name, denial.capability });
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        count += 1;
    }

    if (count == 0) try output.appendSlice(allocator, "None found.\n");
    return output.toOwnedSlice(allocator);
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
    pid: i32,
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
    const pid = std.fmt.parseInt(i32, parsed_pid, 10) catch return null;
    const deny_start = marker_index + marker.len;
    const deny_end = std.mem.indexOfScalarPos(u8, after_prefix, deny_start, ')') orelse return null;
    const capability = std.mem.trim(u8, after_prefix[deny_end + 1 ..], " \t");
    if (capability.len == 0) return null;
    return .{ .name = name, .pid = pid, .capability = capability };
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
        \\Run commands within a Codex-provided sandbox
        \\
        \\Usage: codex-zig sandbox [OPTIONS] <COMMAND>
        \\
        \\Commands:
        \\  macos    Run a command under Seatbelt (macOS only) [aliases: seatbelt]
        \\  linux    Run a command under the Linux sandbox (bubblewrap by default) [aliases: landlock]
        \\  windows  Run a command under Windows restricted token (Windows only)
        \\  help     Print this message or the help of the given subcommand(s)
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\          Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`
        \\      --enable <FEATURE>
        \\          Enable a feature (repeatable). Equivalent to `-c features.<name>=true`
        \\      --disable <FEATURE>
        \\          Disable a feature (repeatable). Equivalent to `-c features.<name>=false`
        \\  -h, --help
        \\          Print help
        \\
    , .{});
}

fn printSandboxKindHelp(kind: SandboxKind) void {
    switch (kind) {
        .macos => printMacosHelp(),
        .linux => printLinuxHelp(),
        .windows => printWindowsHelp(),
    }
}

fn printSandboxHelpSubcommandHelp() void {
    std.debug.print(
        \\Print this message or the help of the given subcommand(s)
        \\
        \\Usage: codex-zig sandbox help [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...  Print help for the subcommand(s)
        \\
    , .{});
}

fn printMacosHelp() void {
    std.debug.print(
        \\Run a command under Seatbelt (macOS only)
        \\
        \\Usage: codex-zig sandbox macos [OPTIONS] [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...
        \\          Full command args to run under seatbelt
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\                      Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`
        \\  --permissions-profile NAME
        \\                      Named permissions profile to apply from the active configuration stack (:read-only, :workspace, :danger-no-sandbox, or a supported custom [permissions] profile)
        \\  -C, --cd DIR        Working directory used for profile resolution and command execution
        \\  --enable FEATURE    Enable a feature (repeatable). Equivalent to `-c features.<name>=true`
        \\  --disable FEATURE   Disable a feature (repeatable). Equivalent to `-c features.<name>=false`
        \\  --include-managed-config
        \\                      Include managed requirements while resolving an explicit permissions profile
        \\  --allow-unix-socket PATH
        \\                      Allow the sandboxed command to bind/connect AF_UNIX sockets rooted at PATH
        \\  --log-denials      Print a macOS sandbox denial summary after the command exits
        \\  -s, --sandbox MODE  read-only, workspace-write, or danger-full-access
        \\  --add-dir DIR       Allow workspace-write command to write DIR
        \\  -h, --help          Print help
        \\
    , .{});
}

fn printLinuxHelp() void {
    std.debug.print(
        \\Run a command under the Linux sandbox (bubblewrap by default)
        \\
        \\Usage: codex-zig sandbox linux [OPTIONS] [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...
        \\          Full command args to run under the Linux sandbox
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\                      Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`
        \\  --permissions-profile NAME
        \\                      Named permissions profile to apply from the active configuration stack
        \\  -C, --cd DIR        Working directory used for profile resolution and command execution
        \\  --enable FEATURE    Enable a feature (repeatable). Equivalent to `-c features.<name>=true`
        \\  --disable FEATURE   Disable a feature (repeatable). Equivalent to `-c features.<name>=false`
        \\  --include-managed-config
        \\                      Include managed requirements while resolving an explicit permissions profile
        \\  -h, --help          Print help
        \\
    , .{});
}

fn printWindowsHelp() void {
    std.debug.print(
        \\Run a command under Windows restricted token (Windows only)
        \\
        \\Usage: codex-zig sandbox windows [OPTIONS] [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...
        \\          Full command args to run under Windows restricted token sandbox
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\                      Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`
        \\  --permissions-profile NAME
        \\                      Named permissions profile to apply from the active configuration stack
        \\  -C, --cd DIR        Working directory used for profile resolution and command execution
        \\  --enable FEATURE    Enable a feature (repeatable). Equivalent to `-c features.<name>=true`
        \\  --disable FEATURE   Disable a feature (repeatable). Equivalent to `-c features.<name>=false`
        \\  --include-managed-config
        \\                      Include managed requirements while resolving an explicit permissions profile
        \\  -h, --help          Print help
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

test "sandbox args parse Rust config and feature controls" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "-c", "sandbox_mode=\"danger-full-access\"", "--enable", "goals", "--disable=shell_tool", "--", "/bin/echo", "ok" };
    const parsed = try parseSandboxArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(config.SandboxMode.danger_full_access, parsed.runtime_overrides.sandbox_mode.?);
    try std.testing.expectEqual(true, parsed.feature_overrides.get("goals").?);
    try std.testing.expectEqual(false, parsed.feature_overrides.get("shell_tool").?);
    try std.testing.expectEqualStrings("/bin/echo", parsed.command[0]);
}

test "sandbox root options parse Rust config and feature controls" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--config=sandbox_mode=\"workspace-write\"", "--enable", "goals", "--disable=shell_tool", "macos" };
    var parsed = SandboxRootOptions{};
    defer parsed.deinit(allocator);

    var index: usize = 0;
    try std.testing.expect(try parseSandboxRootOption(allocator, argv[0..], &index, &parsed));
    try std.testing.expectEqual(config.SandboxMode.workspace_write, parsed.runtime_overrides.sandbox_mode.?);
    index += 1;
    try std.testing.expect(try parseSandboxRootOption(allocator, argv[0..], &index, &parsed));
    try std.testing.expectEqual(true, parsed.feature_overrides.get("goals").?);
    index += 1;
    try std.testing.expect(try parseSandboxRootOption(allocator, argv[0..], &index, &parsed));
    try std.testing.expectEqual(false, parsed.feature_overrides.get("shell_tool").?);
    index += 1;
    try std.testing.expect(!try parseSandboxRootOption(allocator, argv[0..], &index, &parsed));
}

test "sandbox value options reject option terminator as missing value" {
    const allocator = std.testing.allocator;
    const missing_config = [_][]const u8{ "-c", "--", "/bin/echo", "ok" };
    const missing_enable = [_][]const u8{ "--enable", "--", "/bin/echo", "ok" };
    const missing_disable = [_][]const u8{ "--disable", "--", "/bin/echo", "ok" };

    try std.testing.expectError(error.MissingConfigOptionValue, parseSandboxArgs(allocator, missing_config[0..]));
    try std.testing.expectError(error.MissingFeatureName, parseSandboxArgs(allocator, missing_enable[0..]));
    try std.testing.expectError(error.MissingFeatureName, parseSandboxArgs(allocator, missing_disable[0..]));
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
    try std.testing.expectEqual(@as(i32, 1234), parsed.pid);
    try std.testing.expectEqualStrings("file-write-create /tmp/blocked", parsed.capability);
    try std.testing.expect(parseSandboxDenialMessage("other") == null);
}

test "sandbox denial summary filters untracked pids and dedupes" {
    const allocator = std.testing.allocator;
    var tracked_pids = std.AutoHashMap(i32, void).init(allocator);
    defer tracked_pids.deinit();
    try tracked_pids.put(1234, {});

    const log_output =
        \\{"eventMessage":"Sandbox: sh(1234) deny(1) file-read-data /tmp/blocked"}
        \\{"eventMessage":"Sandbox: other(9999) deny(1) file-read-data /tmp/noise"}
        \\{"eventMessage":"Sandbox: sh(1234) deny(1) file-read-data /tmp/blocked"}
    ;
    const rendered = try renderSandboxDenialSummary(allocator, log_output, &tracked_pids);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("(sh) file-read-data /tmp/blocked\n", rendered);
}
