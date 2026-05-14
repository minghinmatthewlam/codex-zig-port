const std = @import("std");
const builtin = @import("builtin");

const api = @import("api.zig");
const config = @import("config.zig");
const sandbox = @import("sandbox.zig");

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*anyopaque,
    winp: ?*anyopaque,
) c_int;

const session_allocator = std.heap.page_allocator;

var exec_sessions: std.ArrayList(ExecSession) = .empty;
var next_exec_session_id: u64 = 1000;

pub const ToolResult = struct {
    call_id: []const u8,
    summary: []const u8,
    output: []const u8,

    pub fn deinit(self: *const ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.summary);
        allocator.free(self.output);
    }
};

const ShellCommandArgs = struct {
    command: []const u8,
};

const ExecCommandArgs = struct {
    cmd: []const u8,
    workdir: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    tty: ?bool = null,
    yield_time_ms: ?u64 = null,
    max_output_tokens: ?usize = null,
    login: ?bool = null,
};

const WriteStdinArgs = struct {
    session_id: u64,
    chars: []const u8 = "",
    yield_time_ms: ?u64 = null,
    max_output_tokens: ?usize = null,
};

const ShellArgs = struct {
    command: []const []const u8,
};

const ExecSession = struct {
    id: u64,
    kind: ExecSessionKind,
    io_instance: std.Io.Threaded,
    child: std.process.Child,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    started: std.Io.Timestamp,

    fn deinit(self: *ExecSession) void {
        if (self.child.id != null) {
            self.child.kill(self.io_instance.io());
            if (self.kind == .pty) {
                self.closeOpenFiles();
            } else {
                self.stdin_file = null;
                self.stdout_file = null;
                self.stderr_file = null;
            }
        } else {
            self.closeOpenFiles();
        }
        self.io_instance.deinit();
    }

    fn closeOpenFiles(self: *ExecSession) void {
        switch (self.kind) {
            .pty => {
                if (self.stdin_file) |file| file.close(self.io_instance.io());
            },
            .pipes => {
                if (self.stdin_file) |file| file.close(self.io_instance.io());
                if (self.stdout_file) |file| file.close(self.io_instance.io());
                if (self.stderr_file) |file| file.close(self.io_instance.io());
            },
        }
        self.stdin_file = null;
        self.stdout_file = null;
        self.stderr_file = null;
    }
};

const ExecSessionKind = enum {
    pipes,
    pty,
};

pub const ExecSessionSummary = struct {
    id: u64,
    pty: bool,
    age_ms: u64,
};

const SessionRead = struct {
    output: []const u8,
    term: ?std.process.Child.Term,

    fn deinit(self: SessionRead, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

const ApplyPatchArgs = struct {
    patch: []const u8,
};

const PatchStats = struct {
    added: usize = 0,
    updated: usize = 0,
    deleted: usize = 0,
};

pub const Policy = struct {
    approval_policy: config.ApprovalPolicy = .on_request,
    sandbox_mode: config.SandboxMode = .workspace_write,
    additional_writable_roots: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    auto_approve: bool = false,
    prompt_for_approval: bool = true,
};

const ToolKind = enum {
    shell,
    apply_patch,
};

const PermissionDecision = enum {
    allow,
    prompt,
    reject,
    block,
};

pub fn runFunctionCall(allocator: std.mem.Allocator, call: api.FunctionCall, policy: Policy) !ToolResult {
    if (std.mem.eql(u8, call.name, "exec_command")) {
        var parsed = try std.json.parseFromSlice(ExecCommandArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (try permissionResult(allocator, call.call_id, policy, .shell, parsed.value.cmd, isTrustedShellCommand(parsed.value.cmd))) |result| return result;
        return runExecCommand(allocator, call.call_id, parsed.value, policy);
    }

    if (std.mem.eql(u8, call.name, "write_stdin")) {
        var parsed = try std.json.parseFromSlice(WriteStdinArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return runWriteStdin(allocator, call.call_id, parsed.value);
    }

    if (std.mem.eql(u8, call.name, "shell_command")) {
        var parsed = try std.json.parseFromSlice(ShellCommandArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (try permissionResult(allocator, call.call_id, policy, .shell, parsed.value.command, isTrustedShellCommand(parsed.value.command))) |result| return result;
        return runShellCommand(allocator, call.call_id, parsed.value.command, policy);
    }

    if (std.mem.eql(u8, call.name, "shell")) {
        var parsed = try std.json.parseFromSlice(ShellArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.command.len == 0) return error.EmptyShellCommand;
        const command = try joinCommand(allocator, parsed.value.command);
        defer allocator.free(command);
        if (try permissionResult(allocator, call.call_id, policy, .shell, command, isTrustedArgv(parsed.value.command))) |result| return result;
        return runArgv(allocator, call.call_id, parsed.value.command, policy);
    }

    if (std.mem.eql(u8, call.name, "apply_patch")) {
        var parsed = try std.json.parseFromSlice(ApplyPatchArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (try permissionResult(allocator, call.call_id, policy, .apply_patch, parsed.value.patch, false)) |result| return result;
        return runApplyPatch(allocator, call.call_id, parsed.value.patch);
    }

    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "unsupported tool"),
        .output = try std.fmt.allocPrint(allocator, "unsupported tool: {s}", .{call.name}),
    };
}

fn permissionResult(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    policy: Policy,
    kind: ToolKind,
    detail: []const u8,
    trusted_read_only: bool,
) !?ToolResult {
    return switch (decidePermission(policy, kind, trusted_read_only)) {
        .allow => null,
        .prompt => if (try confirm(toolKindLabel(kind), detail)) null else try rejected(allocator, call_id),
        .reject => try rejected(allocator, call_id),
        .block => try blockedBySandbox(allocator, call_id, policy.sandbox_mode),
    };
}

fn decidePermission(policy: Policy, kind: ToolKind, trusted_read_only: bool) PermissionDecision {
    if (policy.sandbox_mode == .read_only and (kind != .shell or !trusted_read_only)) return .block;
    if (policy.auto_approve) return .allow;

    return switch (policy.approval_policy) {
        .never => .allow,
        .on_failure => .allow,
        .on_request => if (policy.prompt_for_approval) .prompt else .reject,
        .untrusted => if (trusted_read_only) .allow else if (policy.prompt_for_approval) .prompt else .reject,
    };
}

fn toolKindLabel(kind: ToolKind) []const u8 {
    return switch (kind) {
        .shell => "command",
        .apply_patch => "patch",
    };
}

fn confirm(kind: []const u8, detail: []const u8) !bool {
    std.debug.print("\nTool approval required\n  {s}: {s}\nRun this {s}? [y/N] ", .{ kind, detail, kind });
    var buffer: [16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return false;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

pub fn rejected(allocator: std.mem.Allocator, call_id: []const u8) !ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = try allocator.dupe(u8, "rejected"),
        .output = try allocator.dupe(u8, "user rejected tool execution"),
    };
}

fn blockedBySandbox(allocator: std.mem.Allocator, call_id: []const u8, sandbox_mode: config.SandboxMode) !ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = try allocator.dupe(u8, "blocked by sandbox"),
        .output = try std.fmt.allocPrint(allocator, "blocked by sandbox_mode={s}", .{sandbox_mode.label()}),
    };
}

fn runShellCommand(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    command: []const u8,
    policy: Policy,
) !ToolResult {
    const argv = [_][]const u8{ "/bin/zsh", "-lc", command };
    return runArgv(allocator, call_id, argv[0..], policy);
}

fn runExecCommand(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    args: ExecCommandArgs,
    policy: Policy,
) !ToolResult {
    const shell = args.shell orelse "/bin/zsh";
    const shell_flag = if (args.login orelse false) "-lic" else "-lc";
    const argv = [_][]const u8{ shell, shell_flag, args.cmd };
    if (args.tty orelse false) {
        return runExecCommandSession(allocator, call_id, argv[0..], .{
            .sandbox_mode = policy.sandbox_mode,
            .additional_writable_roots = policy.additional_writable_roots,
            .include_cwd_write_root = policy.include_cwd_write_root,
            .network_enabled = policy.network_enabled,
            .workdir = args.workdir,
            .yield_time_ms = args.yield_time_ms orelse 1000,
            .max_output_tokens = args.max_output_tokens,
            .pty = true,
        });
    }
    return runArgvWithOptions(allocator, call_id, argv[0..], .{
        .sandbox_mode = policy.sandbox_mode,
        .additional_writable_roots = policy.additional_writable_roots,
        .include_cwd_write_root = policy.include_cwd_write_root,
        .network_enabled = policy.network_enabled,
        .workdir = args.workdir,
        .max_output_tokens = args.max_output_tokens,
        .unified_format = true,
    });
}

const ExecSessionOptions = struct {
    sandbox_mode: config.SandboxMode,
    additional_writable_roots: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    workdir: ?[]const u8 = null,
    yield_time_ms: u64 = 1000,
    max_output_tokens: ?usize = null,
    pty: bool = false,
};

fn runExecCommandSession(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    argv: []const []const u8,
    options: ExecSessionOptions,
) !ToolResult {
    const session_index = try startExecSession(argv, options);
    var session_registered = true;
    errdefer if (session_registered) removeExecSession(session_index);
    const session = &exec_sessions.items[session_index];
    var read = try readExecSession(allocator, session, options.yield_time_ms, options.max_output_tokens);
    defer read.deinit(allocator);

    const summary = if (read.term) |term|
        try termSummary(allocator, term)
    else
        try std.fmt.allocPrint(allocator, "session {d}", .{session.id});
    errdefer allocator.free(summary);

    const output = try renderExecSessionOutput(allocator, session, read.output, read.term);
    errdefer allocator.free(output);

    const result_call_id = try allocator.dupe(u8, call_id);
    errdefer allocator.free(result_call_id);

    if (read.term != null) {
        removeExecSession(session_index);
        session_registered = false;
    }

    return .{
        .call_id = result_call_id,
        .summary = summary,
        .output = output,
    };
}

fn runWriteStdin(allocator: std.mem.Allocator, call_id: []const u8, args: WriteStdinArgs) !ToolResult {
    const session_index = findExecSessionIndex(args.session_id) orelse {
        return .{
            .call_id = try allocator.dupe(u8, call_id),
            .summary = try allocator.dupe(u8, "unknown session"),
            .output = try std.fmt.allocPrint(allocator, "unknown exec session: {d}", .{args.session_id}),
        };
    };
    const session = &exec_sessions.items[session_index];
    if (args.chars.len > 0) {
        const stdin_file = session.stdin_file orelse return error.ExecSessionStdinClosed;
        try stdin_file.writeStreamingAll(session.io_instance.io(), args.chars);
    }

    var read = try readExecSession(allocator, session, args.yield_time_ms orelse 1000, args.max_output_tokens);
    defer read.deinit(allocator);
    var reap_on_error = read.term != null;
    errdefer if (reap_on_error) removeExecSession(session_index);

    const summary = if (read.term) |term|
        try termSummary(allocator, term)
    else
        try std.fmt.allocPrint(allocator, "session {d}", .{session.id});
    errdefer allocator.free(summary);

    const output = try renderExecSessionOutput(allocator, session, read.output, read.term);
    errdefer allocator.free(output);

    if (read.term != null) {
        removeExecSession(session_index);
        reap_on_error = false;
    }

    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = summary,
        .output = output,
    };
}

fn startExecSession(argv: []const []const u8, options: ExecSessionOptions) !usize {
    var io_instance: std.Io.Threaded = .init(session_allocator, .{});
    errdefer io_instance.deinit();

    var sandboxed_argv: ?sandbox.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(session_allocator);
    const effective_argv = if (sandbox.shouldSandbox(options.sandbox_mode)) blk: {
        sandboxed_argv = try sandbox.wrapArgvWithCwdOptions(
            session_allocator,
            options.sandbox_mode,
            argv,
            options.additional_writable_roots,
            options.workdir,
            options.include_cwd_write_root,
            options.network_enabled,
        );
        break :blk sandboxed_argv.?.argv;
    } else argv;

    const cwd: std.process.Child.Cwd = if (options.workdir) |workdir| .{ .path = workdir } else .inherit;
    var pty_master: ?std.Io.File = null;
    var pty_slave: ?std.Io.File = null;
    errdefer {
        if (pty_slave) |file| file.close(io_instance.io());
        if (pty_master) |file| file.close(io_instance.io());
    }
    if (options.pty) {
        const handles = try openPtyPair();
        pty_master = handles.master;
        pty_slave = handles.slave;
    }
    const child_stdio: std.process.SpawnOptions.StdIo = if (pty_slave) |file| .{ .file = file } else .pipe;
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = effective_argv,
        .cwd = cwd,
        .stdin = child_stdio,
        .stdout = child_stdio,
        .stderr = child_stdio,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_instance.io());
    if (pty_slave) |file| {
        file.close(io_instance.io());
        pty_slave = null;
    }

    const id = next_exec_session_id;
    next_exec_session_id += 1;
    const kind: ExecSessionKind = if (pty_master != null) .pty else .pipes;
    var session = ExecSession{
        .id = id,
        .kind = kind,
        .io_instance = io_instance,
        .child = child,
        .stdin_file = if (pty_master) |file| file else child.stdin,
        .stdout_file = if (pty_master) |file| file else child.stdout,
        .stderr_file = if (pty_master == null) child.stderr else null,
        .started = std.Io.Timestamp.now(io_instance.io(), .awake),
    };
    child_owned = false;
    if (pty_master != null) pty_master = null;
    var moved = false;
    errdefer if (!moved) session.deinit();

    try exec_sessions.append(session_allocator, session);
    moved = true;
    return exec_sessions.items.len - 1;
}

const PtyPair = struct {
    master: std.Io.File,
    slave: std.Io.File,
};

fn openPtyPair() !PtyPair {
    if (builtin.os.tag != .macos) return error.PtyUnsupported;

    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    if (openpty(&master_fd, &slave_fd, null, null, null) != 0) return error.OpenPtyFailed;

    return .{
        .master = fileFromFd(master_fd),
        .slave = fileFromFd(slave_fd),
    };
}

fn fileFromFd(fd: c_int) std.Io.File {
    return .{
        .handle = @intCast(fd),
        .flags = .{ .nonblocking = false },
    };
}

fn runApplyPatch(allocator: std.mem.Allocator, call_id: []const u8, patch: []const u8) !ToolResult {
    const stats = try applyPatchInDir(allocator, std.Io.Dir.cwd(), patch);
    const summary = try std.fmt.allocPrint(
        allocator,
        "patched +{d} ~{d} -{d}",
        .{ stats.added, stats.updated, stats.deleted },
    );
    errdefer allocator.free(summary);

    const output = try std.fmt.allocPrint(
        allocator,
        "applied patch\nadded: {d}\nupdated: {d}\ndeleted: {d}",
        .{ stats.added, stats.updated, stats.deleted },
    );
    errdefer allocator.free(output);

    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = summary,
        .output = output,
    };
}

fn runArgv(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    argv: []const []const u8,
    policy: Policy,
) !ToolResult {
    return runArgvWithOptions(allocator, call_id, argv, .{
        .sandbox_mode = policy.sandbox_mode,
        .additional_writable_roots = policy.additional_writable_roots,
        .include_cwd_write_root = policy.include_cwd_write_root,
        .network_enabled = policy.network_enabled,
    });
}

const RunArgvOptions = struct {
    sandbox_mode: config.SandboxMode,
    additional_writable_roots: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    workdir: ?[]const u8 = null,
    max_output_tokens: ?usize = null,
    unified_format: bool = false,
};

fn runArgvWithOptions(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    argv: []const []const u8,
    options: RunArgvOptions,
) !ToolResult {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var sandboxed_argv: ?sandbox.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(allocator);
    const effective_argv = if (sandbox.shouldSandbox(options.sandbox_mode)) blk: {
        sandboxed_argv = try sandbox.wrapArgvWithCwdOptions(
            allocator,
            options.sandbox_mode,
            argv,
            options.additional_writable_roots,
            options.workdir,
            options.include_cwd_write_root,
            options.network_enabled,
        );
        break :blk sandboxed_argv.?.argv;
    } else argv;

    const cwd: std.process.Child.Cwd = if (options.workdir) |workdir| .{ .path = workdir } else .inherit;
    const started = std.Io.Timestamp.now(io_instance.io(), .awake);
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = effective_argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(30_000),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const elapsed = started.durationTo(std.Io.Timestamp.now(io_instance.io(), .awake));
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / @as(f64, @floatFromInt(std.time.ns_per_s));

    const exit_summary = switch (result.term) {
        .exited => |code| try std.fmt.allocPrint(allocator, "exit {d}", .{code}),
        .signal => |sig| try std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| try std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(sig)}),
        .unknown => |code| try std.fmt.allocPrint(allocator, "unknown {d}", .{code}),
    };
    errdefer allocator.free(exit_summary);

    const output = if (options.unified_format)
        try renderUnifiedExecOutput(allocator, result.term, result.stdout, result.stderr, elapsed_seconds, options.max_output_tokens)
    else
        try std.fmt.allocPrint(
            allocator,
            "stdout:\n{s}\nstderr:\n{s}",
            .{ result.stdout, result.stderr },
        );
    errdefer allocator.free(output);

    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = exit_summary,
        .output = output,
    };
}

fn readExecSession(
    allocator: std.mem.Allocator,
    session: *ExecSession,
    yield_time_ms: u64,
    max_output_tokens: ?usize,
) !SessionRead {
    var raw = std.ArrayList(u8).empty;
    errdefer raw.deinit(allocator);

    const start = std.Io.Timestamp.now(session.io_instance.io(), .awake);
    var term: ?std.process.Child.Term = null;
    while (elapsedMilliseconds(session.io_instance.io(), start) < yield_time_ms) {
        var made_progress = false;
        switch (session.kind) {
            .pty => {
                if (try readOnePipeByte(allocator, session, session.stdout_file, &raw, null)) {
                    made_progress = true;
                }
            },
            .pipes => {
                if (try readOnePipeByte(allocator, session, session.stdout_file, &raw, null)) {
                    made_progress = true;
                }
                if (try readOnePipeByte(allocator, session, session.stderr_file, &raw, "[stderr]\n")) {
                    made_progress = true;
                }
            },
        }

        if (pollExecSession(session)) |process_term| {
            term = process_term;
            try drainRemainingSessionOutput(session, allocator, &raw);
            break;
        }

        if (!made_progress) {
            // Avoid spinning after both streams timed out.
            continue;
        }
    }

    if (term == null) {
        if (pollExecSession(session)) |process_term| {
            term = process_term;
            try drainRemainingSessionOutput(session, allocator, &raw);
        }
    }

    const merged = try raw.toOwnedSlice(allocator);
    errdefer allocator.free(merged);
    const rendered = try truncateOutputForTokens(allocator, merged, max_output_tokens);
    allocator.free(merged);
    return .{ .output = rendered, .term = term };
}

fn readOnePipeByte(
    allocator: std.mem.Allocator,
    session: *ExecSession,
    maybe_file: ?std.Io.File,
    raw: *std.ArrayList(u8),
    prefix: ?[]const u8,
) !bool {
    const file = maybe_file orelse return false;
    var byte: [1]u8 = undefined;
    const count = readPipeByteWithTimeout(session, file, byte[0..], 25) catch |err| switch (err) {
        error.Timeout => return false,
        error.EndOfStream => return false,
        else => return err,
    };
    if (count == 0) return false;
    if (prefix) |value| {
        if (raw.items.len == 0 or std.mem.indexOf(u8, raw.items, value) == null) {
            try raw.appendSlice(allocator, value);
        }
    }
    try raw.append(allocator, byte[0]);
    return true;
}

fn drainRemainingSessionOutput(
    session: *ExecSession,
    allocator: std.mem.Allocator,
    raw: *std.ArrayList(u8),
) !void {
    var attempts: usize = 0;
    while (attempts < 4096) : (attempts += 1) {
        const before = raw.items.len;
        switch (session.kind) {
            .pty => _ = try readOnePipeByte(allocator, session, session.stdout_file, raw, null),
            .pipes => {
                _ = try readOnePipeByte(allocator, session, session.stdout_file, raw, null);
                _ = try readOnePipeByte(allocator, session, session.stderr_file, raw, "[stderr]\n");
            },
        }
        if (raw.items.len == before) break;
    }
}

fn readPipeByteWithTimeout(session: *ExecSession, file: std.Io.File, buffer: []u8, timeout_ms: u64) !usize {
    const result = try session.io_instance.io().operateTimeout(.{ .file_read_streaming = .{
        .file = file,
        .data = &.{buffer},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } });
    return result.file_read_streaming;
}

fn pollExecSession(session: *ExecSession) ?std.process.Child.Term {
    const pid = session.child.id orelse return null;
    var status: c_int = 0;
    const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (result == 0) return null;
    if (result < 0) return null;
    session.child.id = null;

    const status_u: u32 = @intCast(status);
    if (std.c.W.IFEXITED(status_u)) return .{ .exited = std.c.W.EXITSTATUS(status_u) };
    if (std.c.W.IFSIGNALED(status_u)) return .{ .signal = std.c.W.TERMSIG(status_u) };
    if (std.c.W.IFSTOPPED(status_u)) return .{ .stopped = std.c.W.STOPSIG(status_u) };
    return .{ .unknown = status_u };
}

fn elapsedMilliseconds(io: std.Io, started: std.Io.Timestamp) u64 {
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    if (elapsed.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
}

fn renderExecSessionOutput(
    allocator: std.mem.Allocator,
    session: *ExecSession,
    output_text: []const u8,
    term: ?std.process.Child.Term,
) ![]const u8 {
    const elapsed = session.started.durationTo(std.Io.Timestamp.now(session.io_instance.io(), .awake));
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const status = if (term) |value|
        try termStatusLine(allocator, value)
    else
        try std.fmt.allocPrint(allocator, "Process running with session ID {d}", .{session.id});
    defer allocator.free(status);

    return std.fmt.allocPrint(
        allocator,
        "Wall time: {d:.3} seconds\n{s}\nOutput:\n{s}",
        .{ elapsed_seconds, status, output_text },
    );
}

fn termSummary(allocator: std.mem.Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "exit {d}", .{code}),
        .signal => |sig| std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(sig)}),
        .unknown => |code| std.fmt.allocPrint(allocator, "unknown {d}", .{code}),
    };
}

fn termStatusLine(allocator: std.mem.Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "Process exited with code {d}", .{code}),
        .signal => |sig| std.fmt.allocPrint(allocator, "Process killed by signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "Process stopped by signal {d}", .{@intFromEnum(sig)}),
        .unknown => |code| std.fmt.allocPrint(allocator, "Process ended with unknown status {d}", .{code}),
    };
}

fn findExecSessionIndex(session_id: u64) ?usize {
    for (exec_sessions.items, 0..) |session, index| {
        if (session.id == session_id) return index;
    }
    return null;
}

pub fn listExecSessions(allocator: std.mem.Allocator) ![]ExecSessionSummary {
    const summaries = try allocator.alloc(ExecSessionSummary, exec_sessions.items.len);
    errdefer allocator.free(summaries);
    for (exec_sessions.items, 0..) |*session, index| {
        summaries[index] = .{
            .id = session.id,
            .pty = session.kind == .pty,
            .age_ms = elapsedMilliseconds(session.io_instance.io(), session.started),
        };
    }
    return summaries;
}

pub fn activeExecSessionCount() usize {
    return exec_sessions.items.len;
}

pub fn stopAllExecSessions() usize {
    const count = exec_sessions.items.len;
    while (exec_sessions.items.len > 0) {
        removeExecSession(exec_sessions.items.len - 1);
    }
    return count;
}

fn removeExecSession(index: usize) void {
    var removed = exec_sessions.orderedRemove(index);
    removed.deinit();
}

fn renderUnifiedExecOutput(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    elapsed_seconds: f64,
    max_output_tokens: ?usize,
) ![]const u8 {
    const raw_output = try mergeExecStreams(allocator, stdout, stderr);
    defer allocator.free(raw_output);
    const rendered_output = try truncateOutputForTokens(allocator, raw_output, max_output_tokens);
    defer allocator.free(rendered_output);

    const status = try termStatusLine(allocator, term);
    defer allocator.free(status);

    return std.fmt.allocPrint(
        allocator,
        "Wall time: {d:.3} seconds\n{s}\nOutput:\n{s}",
        .{ elapsed_seconds, status, rendered_output },
    );
}

fn mergeExecStreams(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    if (stderr.len == 0) return allocator.dupe(u8, stdout);
    if (stdout.len == 0) return allocator.dupe(u8, stderr);
    return std.fmt.allocPrint(allocator, "{s}\n[stderr]\n{s}", .{ stdout, stderr });
}

fn truncateOutputForTokens(allocator: std.mem.Allocator, output: []const u8, max_output_tokens: ?usize) ![]const u8 {
    const token_limit = max_output_tokens orelse return allocator.dupe(u8, output);
    if (token_limit == 0) return allocator.dupe(u8, "");
    const byte_limit = token_limit * 4;
    if (output.len <= byte_limit) return allocator.dupe(u8, output);
    if (byte_limit < 32) return allocator.dupe(u8, output[0..byte_limit]);

    const head_len = byte_limit / 2;
    const tail_len = byte_limit - head_len;
    const omitted = output.len - head_len - tail_len;
    return std.fmt.allocPrint(
        allocator,
        "{s}\n... {d} bytes truncated ...\n{s}",
        .{ output[0..head_len], omitted, output[output.len - tail_len ..] },
    );
}

fn joinCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    for (argv, 0..) |part, index| {
        if (index > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, part);
    }
    return list.toOwnedSlice(allocator);
}

fn isTrustedShellCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfAny(u8, trimmed, "><;|&`$\n\r") != null) return false;

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = parts.next() orelse return false;
    const second = parts.next();
    return isTrustedCommandName(first, second);
}

fn isTrustedArgv(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const first = std.fs.path.basename(argv[0]);
    const second = if (argv.len > 1) argv[1] else null;
    return isTrustedCommandName(first, second);
}

fn isTrustedCommandName(first: []const u8, second: ?[]const u8) bool {
    const read_only_commands = [_][]const u8{
        "pwd",
        "ls",
        "cat",
        "sed",
        "rg",
        "grep",
        "find",
        "wc",
        "head",
        "tail",
        "nl",
    };
    for (read_only_commands) |name| {
        if (std.mem.eql(u8, first, name)) return true;
    }

    if (!std.mem.eql(u8, first, "git")) return false;
    const subcommand = second orelse return false;
    const read_only_git = [_][]const u8{
        "status",
        "diff",
        "show",
        "log",
        "branch",
        "rev-parse",
        "ls-files",
    };
    for (read_only_git) |name| {
        if (std.mem.eql(u8, subcommand, name)) return true;
    }
    return false;
}

fn applyPatchInDir(allocator: std.mem.Allocator, root: std.Io.Dir, patch: []const u8) !PatchStats {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    const patch_text = normalizePatchText(patch);
    var raw_lines = std.mem.splitScalar(u8, patch_text, '\n');
    while (raw_lines.next()) |raw_line| {
        try lines.append(allocator, std.mem.trimEnd(u8, raw_line, "\r"));
    }

    if (lines.items.len < 2) return error.InvalidPatch;
    if (!std.mem.eql(u8, patchDirective(lines.items[0]), "*** Begin Patch")) return error.InvalidPatch;
    try validatePatchTerminator(lines.items);

    var stats = PatchStats{};
    var index: usize = 1;
    while (index < lines.items.len) {
        const line = patchDirective(lines.items[index]);
        if (std.mem.eql(u8, line, "*** End Patch")) {
            if (stats.added == 0 and stats.updated == 0 and stats.deleted == 0) return error.InvalidPatch;
            return stats;
        }

        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            const path = line["*** Add File: ".len..];
            try validateRelativePath(path);
            index += 1;
            try addFileFromPatch(allocator, root, path, lines.items, &index);
            stats.added += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            const path = line["*** Update File: ".len..];
            try validateRelativePath(path);
            index += 1;
            try updateFileFromPatch(allocator, root, path, lines.items, &index);
            stats.updated += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Delete File: ")) {
            const path = line["*** Delete File: ".len..];
            try validateRelativePath(path);
            if (index + 1 >= lines.items.len or !isPatchSection(lines.items[index + 1])) return error.InvalidPatch;
            try root.deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
            stats.deleted += 1;
            index += 1;
            continue;
        }

        return error.InvalidPatch;
    }

    return error.InvalidPatch;
}

fn normalizePatchText(patch: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, patch, " \t\r\n");
    const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    const last_newline = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    if (first_newline >= last_newline) return trimmed;

    const first_line = std.mem.trimEnd(u8, trimmed[0..first_newline], "\r");
    if (!isHeredocStart(first_line)) return trimmed;

    const last_line = std.mem.trimEnd(u8, trimmed[last_newline + 1 ..], "\r");
    if (!std.mem.endsWith(u8, last_line, "EOF")) return trimmed;

    return std.mem.trim(u8, trimmed[first_newline + 1 .. last_newline], " \t\r\n");
}

fn isHeredocStart(line: []const u8) bool {
    return std.mem.eql(u8, line, "<<EOF") or
        std.mem.eql(u8, line, "<<'EOF'") or
        std.mem.eql(u8, line, "<<\"EOF\"");
}

fn validatePatchTerminator(lines: []const []const u8) !void {
    for (lines[1..], 1..) |line, index| {
        if (std.mem.eql(u8, patchDirective(line), "*** End Patch")) {
            for (lines[index + 1 ..]) |trailing| {
                if (trailing.len != 0) return error.InvalidPatch;
            }
            return;
        }
    }
    return error.InvalidPatch;
}

fn addFileFromPatch(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    lines: []const []const u8,
    index: *usize,
) !void {
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    while (index.* < lines.len and !isPatchSection(lines[index.*])) : (index.* += 1) {
        const line = lines[index.*];
        if (line.len == 0 or line[0] != '+') return error.InvalidPatch;
        try content.appendSlice(allocator, line[1..]);
        try content.append(allocator, '\n');
    }

    try ensureParentDir(root, path);
    try root.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = content.items,
    });
}

fn updateFileFromPatch(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    lines: []const []const u8,
    index: *usize,
) !void {
    var target_path = path;
    if (index.* < lines.len) {
        const directive = patchDirective(lines[index.*]);
        if (std.mem.startsWith(u8, directive, "*** Move to: ")) {
            target_path = directive["*** Move to: ".len..];
            try validateRelativePath(target_path);
            index.* += 1;
        }
    }

    if (index.* >= lines.len or isPatchSection(lines[index.*])) return error.InvalidPatch;
    try validateUpdatePatchShape(lines, index.*);

    var current = try root.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(current);

    var saw_hunk = false;
    var consumed_context_marker = false;
    var search_start: usize = 0;
    while (index.* < lines.len and !isPatchSection(lines[index.*])) {
        if (!saw_hunk and !consumed_context_marker and lines[index.*].len == 0) {
            index.* += 1;
            continue;
        }

        const directive = patchDirective(lines[index.*]);
        if (std.mem.eql(u8, directive, "*** End of File")) {
            index.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, directive, "@@")) {
            if (changeContextFromMarker(directive)) |context| {
                const context_match = try findChangeContext(allocator, current, context, search_start);
                search_start = context_match.end;
            }
            index.* += 1;
            consumed_context_marker = true;
            continue;
        }

        var old = std.ArrayList(u8).empty;
        defer old.deinit(allocator);
        var new = std.ArrayList(u8).empty;
        defer new.deinit(allocator);

        while (index.* < lines.len and !isPatchSection(lines[index.*]) and !isHunkBoundary(lines[index.*])) : (index.* += 1) {
            const line = lines[index.*];
            if (line.len == 0) {
                try old.append(allocator, '\n');
                try new.append(allocator, '\n');
                continue;
            }
            switch (line[0]) {
                ' ' => {
                    try old.appendSlice(allocator, line[1..]);
                    try old.append(allocator, '\n');
                    try new.appendSlice(allocator, line[1..]);
                    try new.append(allocator, '\n');
                },
                '-' => {
                    try old.appendSlice(allocator, line[1..]);
                    try old.append(allocator, '\n');
                },
                '+' => {
                    try new.appendSlice(allocator, line[1..]);
                    try new.append(allocator, '\n');
                },
                else => return error.InvalidPatch,
            }
        }

        if (old.items.len == 0 and new.items.len == 0) continue;
        const replaced = if (old.items.len == 0) blk: {
            break :blk try appendToEnd(allocator, current, new.items);
        } else blk: {
            const replacement = try replaceOnceFrom(allocator, current, old.items, new.items, search_start);
            search_start = replacement.next_start;
            break :blk replacement.text;
        };
        allocator.free(current);
        current = replaced;
        saw_hunk = true;
        consumed_context_marker = false;
    }

    if (!saw_hunk) return error.InvalidPatch;
    try ensureParentDir(root, target_path);
    try root.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = target_path,
        .data = current,
    });
    if (!std.mem.eql(u8, path, target_path)) {
        try root.deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
    }
}

fn validateUpdatePatchShape(lines: []const []const u8, start_index: usize) !void {
    var index = start_index;
    var saw_hunk = false;
    var consumed_context_marker = false;
    var current_hunk_has_lines = false;

    while (index < lines.len and !isPatchSection(lines[index])) {
        const line = lines[index];
        if (!saw_hunk and !consumed_context_marker and line.len == 0) {
            index += 1;
            continue;
        }

        if (isHunkBoundary(line)) {
            if (std.mem.eql(u8, patchDirective(line), "*** End of File")) {
                if (!current_hunk_has_lines) return error.InvalidPatch;
                current_hunk_has_lines = false;
                index += 1;
                continue;
            }

            current_hunk_has_lines = false;
            consumed_context_marker = true;
            index += 1;
            if (index >= lines.len or isPatchSection(lines[index]) or isHunkBoundary(lines[index])) {
                return error.InvalidPatch;
            }
            continue;
        }

        if (line.len == 0 or line[0] == ' ' or line[0] == '+' or line[0] == '-') {
            saw_hunk = true;
            consumed_context_marker = false;
            current_hunk_has_lines = true;
            index += 1;
            continue;
        }

        return error.InvalidPatch;
    }

    if (!saw_hunk) return error.InvalidPatch;
}

fn appendToEnd(allocator: std.mem.Allocator, current: []const u8, addition: []const u8) ![]u8 {
    if (addition.len == 0) return error.InvalidPatch;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, current);
    if (current.len > 0 and current[current.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, addition);
    return output.toOwnedSlice(allocator);
}

fn ensureParentDir(root: std.Io.Dir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try root.createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPatchPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidPatchPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPatchPath;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPatchPath;
        }
    }
}

fn isPatchSection(line: []const u8) bool {
    const directive = patchDirective(line);
    return std.mem.eql(u8, directive, "*** End Patch") or
        std.mem.startsWith(u8, directive, "*** Add File: ") or
        std.mem.startsWith(u8, directive, "*** Update File: ") or
        std.mem.startsWith(u8, directive, "*** Delete File: ");
}

fn isHunkBoundary(line: []const u8) bool {
    const directive = patchDirective(line);
    return std.mem.startsWith(u8, directive, "@@") or std.mem.eql(u8, directive, "*** End of File");
}

fn patchDirective(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t");
}

const TextMatch = struct {
    start: usize,
    end: usize,
};

const PatchReplacement = struct {
    text: []u8,
    next_start: usize,
};

const PatchSourceLine = struct {
    content: []const u8,
    start: usize,
    end: usize,
};

const PatchLineMatchMode = enum {
    exact,
    trim_end,
    trim,
    normalized,
};

fn trailingNewlineMatch(haystack: []const u8, needle: []const u8) ?TextMatch {
    if (!std.mem.endsWith(u8, needle, "\n")) return null;
    const trimmed = needle[0 .. needle.len - 1];
    if (trimmed.len == 0) return null;
    if (!std.mem.endsWith(u8, haystack, trimmed)) return null;
    return .{ .start = haystack.len - trimmed.len, .end = haystack.len };
}

fn replaceOnceFrom(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    start_offset: usize,
) !PatchReplacement {
    if (needle.len == 0) return error.InvalidPatch;
    const bounded_start = @min(start_offset, haystack.len);
    const match = if (std.mem.indexOfPos(u8, haystack, bounded_start, needle)) |start|
        TextMatch{ .start = start, .end = start + needle.len }
    else if (trailingNewlineMatchFrom(haystack, needle, bounded_start)) |matched|
        matched
    else
        (try fuzzyLineMatchFrom(allocator, haystack, needle, bounded_start)) orelse return error.PatchContextNotFound;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, haystack[0..match.start]);
    try output.appendSlice(allocator, replacement);
    try output.appendSlice(allocator, haystack[match.end..]);
    return .{
        .text = try output.toOwnedSlice(allocator),
        .next_start = match.start + replacement.len,
    };
}

fn trailingNewlineMatchFrom(haystack: []const u8, needle: []const u8, start_offset: usize) ?TextMatch {
    const match = trailingNewlineMatch(haystack, needle) orelse return null;
    if (match.start < start_offset) return null;
    return match;
}

fn fuzzyLineMatchFrom(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, start_offset: usize) !?TextMatch {
    var source_lines = std.ArrayList(PatchSourceLine).empty;
    defer source_lines.deinit(allocator);
    try collectPatchSourceLines(allocator, haystack, &source_lines);

    var pattern_lines = std.ArrayList([]const u8).empty;
    defer pattern_lines.deinit(allocator);
    try collectPatchPatternLines(allocator, needle, &pattern_lines);

    if (pattern_lines.items.len == 0 or pattern_lines.items.len > source_lines.items.len) return null;

    const modes = [_]PatchLineMatchMode{ .exact, .trim_end, .trim, .normalized };
    for (modes) |mode| {
        const last_start = source_lines.items.len - pattern_lines.items.len;
        var source_index: usize = 0;
        while (source_index <= last_start) : (source_index += 1) {
            if (source_lines.items[source_index].start < start_offset) continue;
            var matched = true;
            for (pattern_lines.items, 0..) |pattern_line, pattern_index| {
                if (!try patchLinesEqual(allocator, source_lines.items[source_index + pattern_index].content, pattern_line, mode)) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return .{
                    .start = source_lines.items[source_index].start,
                    .end = source_lines.items[source_index + pattern_lines.items.len - 1].end,
                };
            }
        }
    }

    return null;
}

fn changeContextFromMarker(directive: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, directive, "@@ ")) return null;
    return directive["@@ ".len..];
}

fn findChangeContext(allocator: std.mem.Allocator, current: []const u8, context: []const u8, search_start: usize) !TextMatch {
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(allocator);
    try needle.appendSlice(allocator, context);
    try needle.append(allocator, '\n');
    return (try fuzzyLineMatchFrom(allocator, current, needle.items, search_start)) orelse error.PatchContextNotFound;
}

fn collectPatchSourceLines(allocator: std.mem.Allocator, text: []const u8, lines: *std.ArrayList(PatchSourceLine)) !void {
    var start: usize = 0;
    while (start < text.len) {
        const newline_index = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const end = if (newline_index < text.len) newline_index + 1 else newline_index;
        try lines.append(allocator, .{
            .content = text[start..newline_index],
            .start = start,
            .end = end,
        });
        start = end;
    }
}

fn collectPatchPatternLines(allocator: std.mem.Allocator, text: []const u8, lines: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    while (start < text.len) {
        const newline_index = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try lines.append(allocator, text[start..newline_index]);
        if (newline_index == text.len) break;
        start = newline_index + 1;
    }
}

fn patchLinesEqual(allocator: std.mem.Allocator, source: []const u8, pattern: []const u8, mode: PatchLineMatchMode) !bool {
    return switch (mode) {
        .exact => std.mem.eql(u8, source, pattern),
        .trim_end => std.mem.eql(u8, std.mem.trimEnd(u8, source, " \t\r"), std.mem.trimEnd(u8, pattern, " \t\r")),
        .trim => std.mem.eql(u8, std.mem.trim(u8, source, " \t\r"), std.mem.trim(u8, pattern, " \t\r")),
        .normalized => blk: {
            const normalized_source = try normalizePatchMatchLine(allocator, source);
            defer allocator.free(normalized_source);
            const normalized_pattern = try normalizePatchMatchLine(allocator, pattern);
            defer allocator.free(normalized_pattern);
            break :blk std.mem.eql(u8, normalized_source, normalized_pattern);
        },
    };
}

fn normalizePatchMatchLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const view = std.unicode.Utf8View.init(trimmed) catch return allocator.dupe(u8, trimmed);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |codepoint_slice| {
        const codepoint = std.unicode.utf8Decode(codepoint_slice) catch unreachable;
        if (normalizedPatchAsciiByte(codepoint)) |byte| {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, codepoint_slice);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn normalizedPatchAsciiByte(codepoint: u21) ?u8 {
    return switch (codepoint) {
        0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => '-',
        0x2018, 0x2019, 0x201a, 0x201b => '\'',
        0x201c, 0x201d, 0x201e, 0x201f => '"',
        0x00a0, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x202f, 0x205f, 0x3000 => ' ',
        else => null,
    };
}

test "shell command creates output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = api.FunctionCall{
        .call_id = "c1",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf hello\"}",
    };
    const result = try runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "exec_command returns unified-style one-shot output" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "exec-1",
        .name = "exec_command",
        .arguments = "{\"cmd\":\"printf exec-ok\",\"yield_time_ms\":100,\"max_output_tokens\":100}",
    };
    const result = try runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("exit 0", result.summary);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Wall time: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Process exited with code 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Output:\nexec-ok") != null);
}

test "exec_command honors workdir" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const cwd = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    const cwd_json = try std.json.Stringify.valueAlloc(allocator, cwd, .{});
    defer allocator.free(cwd_json);
    const args = try std.fmt.allocPrint(allocator, "{{\"cmd\":\"pwd\",\"workdir\":{s}}}", .{cwd_json});
    defer allocator.free(args);

    const call = api.FunctionCall{
        .call_id = "exec-cwd",
        .name = "exec_command",
        .arguments = args,
    };
    const result = try runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.output, cwd) != null);
}

test "exec_command tty session accepts write_stdin" {
    const allocator = std.testing.allocator;
    const start_call = api.FunctionCall{
        .call_id = "exec-session",
        .name = "exec_command",
        .arguments =
        \\{"cmd":"printf READY; if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then printf TTY-OK; else printf TTY-NO; fi; read line; printf \"GOT:%s\" \"$line\"","tty":true,"yield_time_ms":200,"max_output_tokens":100}
        ,
    };
    const start_result = try runFunctionCall(allocator, start_call, .{ .auto_approve = true });
    defer start_result.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, start_result.summary, "session "));
    const session_id = try std.fmt.parseInt(u64, start_result.summary["session ".len..], 10);
    const running_text = try std.fmt.allocPrint(allocator, "Process running with session ID {d}", .{session_id});
    defer allocator.free(running_text);
    try std.testing.expect(std.mem.indexOf(u8, start_result.output, running_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, start_result.output, "Output:\nREADY") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_result.output, "TTY-OK") != null);

    const write_args = try std.fmt.allocPrint(
        allocator,
        "{{\"session_id\":{d},\"chars\":\"hello\\n\",\"yield_time_ms\":1000,\"max_output_tokens\":100}}",
        .{session_id},
    );
    defer allocator.free(write_args);
    const write_call = api.FunctionCall{
        .call_id = "write-session",
        .name = "write_stdin",
        .arguments = write_args,
    };
    const write_result = try runFunctionCall(allocator, write_call, .{ .auto_approve = true });
    defer write_result.deinit(allocator);

    try std.testing.expectEqualStrings("exit 0", write_result.summary);
    try std.testing.expect(std.mem.indexOf(u8, write_result.output, "Process exited with code 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_result.output, "GOT:hello") != null);
    try std.testing.expect(findExecSessionIndex(session_id) == null);
}

test "exec sessions can be listed and stopped" {
    const allocator = std.testing.allocator;
    const start_call = api.FunctionCall{
        .call_id = "exec-session-list",
        .name = "exec_command",
        .arguments = "{\"cmd\":\"printf READY; sleep 30\",\"tty\":true,\"yield_time_ms\":200,\"max_output_tokens\":100}",
    };
    const start_result = try runFunctionCall(allocator, start_call, .{ .auto_approve = true });
    defer start_result.deinit(allocator);
    defer _ = stopAllExecSessions();

    try std.testing.expect(std.mem.startsWith(u8, start_result.summary, "session "));
    const session_id = try std.fmt.parseInt(u64, start_result.summary["session ".len..], 10);

    const sessions = try listExecSessions(allocator);
    defer allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(session_id, sessions[0].id);
    try std.testing.expect(sessions[0].pty);

    try std.testing.expectEqual(@as(usize, 1), activeExecSessionCount());
    try std.testing.expectEqual(@as(usize, 1), stopAllExecSessions());
    try std.testing.expectEqual(@as(usize, 0), activeExecSessionCount());
}

test "write_stdin reports unknown session" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "write-unknown",
        .name = "write_stdin",
        .arguments = "{\"session_id\":999999,\"chars\":\"ignored\"}",
    };
    const result = try runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("unknown session", result.summary);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unknown exec session: 999999") != null);
}

test "apply_patch adds and updates files" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const add_patch =
        \\*** Begin Patch
        \\*** Add File: docs/demo.txt
        \\+alpha
        \\+beta
        \\*** End Patch
    ;
    const add_stats = try applyPatchInDir(allocator, dir.dir, add_patch);
    try std.testing.expectEqual(@as(usize, 1), add_stats.added);

    const update_patch =
        \\*** Begin Patch
        \\*** Update File: docs/demo.txt
        \\@@
        \\ alpha
        \\-beta
        \\+gamma
        \\*** End Patch
    ;
    const update_stats = try applyPatchInDir(allocator, dir.dir, update_patch);
    try std.testing.expectEqual(@as(usize, 1), update_stats.updated);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "docs/demo.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("alpha\ngamma\n", content);
}

test "apply_patch add overwrites existing file" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "duplicate.txt",
        .data = "old content\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Add File: duplicate.txt
        \\+new content
        \\*** End Patch
    ;
    const stats = try applyPatchInDir(allocator, dir.dir, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.added);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "duplicate.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new content\n", content);
}

test "apply_patch accepts heredoc-wrapped patch text" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const bare_patch =
        \\<<EOF
        \\*** Begin Patch
        \\*** Add File: heredoc.txt
        \\+hello
        \\*** End Patch
        \\EOF
    ;
    const bare_stats = try applyPatchInDir(allocator, dir.dir, bare_patch);
    try std.testing.expectEqual(@as(usize, 1), bare_stats.added);

    const bare_content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "heredoc.txt", allocator, .limited(1024));
    defer allocator.free(bare_content);
    try std.testing.expectEqualStrings("hello\n", bare_content);

    const quoted_patch =
        \\<<'EOF'
        \\*** Begin Patch
        \\*** Add File: quoted.txt
        \\+world
        \\*** End Patch
        \\EOF
    ;
    const quoted_stats = try applyPatchInDir(allocator, dir.dir, quoted_patch);
    try std.testing.expectEqual(@as(usize, 1), quoted_stats.added);

    const quoted_content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "quoted.txt", allocator, .limited(1024));
    defer allocator.free(quoted_content);
    try std.testing.expectEqualStrings("world\n", quoted_content);

    const double_quoted_patch =
        \\<<"EOF"
        \\*** Begin Patch
        \\*** Add File: double-quoted.txt
        \\+again
        \\*** End Patch
        \\EOF
    ;
    const double_quoted_stats = try applyPatchInDir(allocator, dir.dir, double_quoted_patch);
    try std.testing.expectEqual(@as(usize, 1), double_quoted_stats.added);

    const double_quoted_content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "double-quoted.txt", allocator, .limited(1024));
    defer allocator.free(double_quoted_content);
    try std.testing.expectEqualStrings("again\n", double_quoted_content);
}

test "apply_patch rejects empty update before reading target" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const patch =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, patch));
}

test "apply_patch rejects empty marked update hunks before reading target" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const end_patch =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\@@
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, end_patch));

    const eof_marker =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\@@
        \\*** End of File
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, eof_marker));

    const repeated_context =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\@@
        \\@@
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, repeated_context));
}

test "apply_patch rejects malformed update hunks before reading target" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const invalid_line =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\@@
        \\-old
        \\bad
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, invalid_line));

    const section_after_empty_context =
        \\*** Begin Patch
        \\*** Update File: missing.txt
        \\@@
        \\*** Update File: other.txt
        \\@@
        \\+new
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, section_after_empty_context));
}

test "apply_patch treats blank hunk lines as empty context" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "blank.txt",
        .data = "alpha\n\nbeta\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Update File: blank.txt
        \\@@
        \\ alpha
        \\
        \\-beta
        \\+gamma
        \\*** End Patch
    ;
    const stats = try applyPatchInDir(allocator, dir.dir, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "blank.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("alpha\n\ngamma\n", content);
}

test "apply_patch fuzzy matches Unicode punctuation" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "unicode_dash.txt",
        .data = "import asyncio  # local import \u{2013} avoids top\u{2011}level dep\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Update File: unicode_dash.txt
        \\@@
        \\-import asyncio  # local import - avoids top-level dep
        \\+import asyncio  # HELLO
        \\*** End Patch
    ;
    const stats = try applyPatchInDir(allocator, dir.dir, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "unicode_dash.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("import asyncio  # HELLO\n", content);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "unicode_quotes.txt",
        .data = "say \u{201c}hello\u{201d}\nkey\u{00a0}value\n",
    });

    const quotes_patch =
        \\*** Begin Patch
        \\*** Update File: unicode_quotes.txt
        \\@@
        \\-say "hello"
        \\-key value
        \\+normalized
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, quotes_patch);

    const quotes_content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "unicode_quotes.txt", allocator, .limited(1024));
    defer allocator.free(quotes_content);
    try std.testing.expectEqualStrings("normalized\n", quotes_content);
}

test "apply_patch uses context markers to disambiguate updates" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "context.txt",
        .data = "fn first()\n    pass\n\nfn second()\n    pass\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Update File: context.txt
        \\@@ fn second()
        \\-    pass
        \\+    return 2
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, patch);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "context.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("fn first()\n    pass\n\nfn second()\n    return 2\n", content);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "missing_context.txt",
        .data = "fn first()\n    pass\n",
    });

    const missing_context_patch =
        \\*** Begin Patch
        \\*** Update File: missing_context.txt
        \\@@ fn missing()
        \\-    pass
        \\+    return 3
        \\*** End Patch
    ;
    try std.testing.expectError(error.PatchContextNotFound, applyPatchInDir(allocator, dir.dir, missing_context_patch));

    const missing_context = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "missing_context.txt", allocator, .limited(1024));
    defer allocator.free(missing_context);
    try std.testing.expectEqualStrings("fn first()\n    pass\n", missing_context);
}

test "apply_patch skips blank lines before first update chunk" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "leading_blank.txt",
        .data = "alpha\n",
    });

    const context_marker_patch =
        \\*** Begin Patch
        \\*** Update File: leading_blank.txt
        \\
        \\@@
        \\-alpha
        \\+beta
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, context_marker_patch);

    const updated = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "leading_blank.txt", allocator, .limited(1024));
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("beta\n", updated);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "missing_context.txt",
        .data = "import foo\n",
    });

    const missing_context_patch =
        \\*** Begin Patch
        \\*** Update File: missing_context.txt
        \\
        \\ import foo
        \\+bar
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, missing_context_patch);

    const missing_context = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "missing_context.txt", allocator, .limited(1024));
    defer allocator.free(missing_context);
    try std.testing.expectEqualStrings("import foo\nbar\n", missing_context);
}

test "apply_patch deletes files and rejects unsafe paths" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "remove-me.txt",
        .data = "temporary\n",
    });

    const delete_patch =
        \\*** Begin Patch
        \\*** Delete File: remove-me.txt
        \\*** End Patch
    ;
    const delete_stats = try applyPatchInDir(allocator, dir.dir, delete_patch);
    try std.testing.expectEqual(@as(usize, 1), delete_stats.deleted);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "remove-me.txt", .{}));

    const unsafe_patch =
        \\*** Begin Patch
        \\*** Add File: ../escape.txt
        \\+nope
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatchPath, applyPatchInDir(allocator, dir.dir, unsafe_patch));
}

test "apply_patch rejects delete body before deleting file" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "delete.txt",
        .data = "keep\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Delete File: delete.txt
        \\bad
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, patch));
    try dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "delete.txt", .{});
}

test "apply_patch supports moves and destination overwrite" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "old");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "renamed/dir");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "old/name.txt",
        .data = "from\n",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "renamed/dir/name.txt",
        .data = "existing\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Update File: old/name.txt
        \\*** Move to: renamed/dir/name.txt
        \\@@
        \\-from
        \\+new
        \\*** End Patch
    ;
    const stats = try applyPatchInDir(allocator, dir.dir, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "old/name.txt", .{}));

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "renamed/dir/name.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new\n", content);
}

test "apply_patch handles EOF, pure additions, and padded markers" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "tail.txt",
        .data = "first\nsecond\n",
    });
    const eof_patch =
        \\*** Begin Patch
        \\*** Update File: tail.txt
        \\@@
        \\ first
        \\-second
        \\+second updated
        \\*** End of File
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, eof_patch);
    const tail = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "tail.txt", allocator, .limited(1024));
    defer allocator.free(tail);
    try std.testing.expectEqualStrings("first\nsecond updated\n", tail);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "input.txt",
        .data = "line1\nline2\n",
    });
    const addition_patch =
        \\*** Begin Patch
        \\*** Update File: input.txt
        \\@@
        \\+added line 1
        \\+added line 2
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, addition_patch);
    const input = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "input.txt", allocator, .limited(1024));
    defer allocator.free(input);
    try std.testing.expectEqualStrings("line1\nline2\nadded line 1\nadded line 2\n", input);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "no_newline.txt",
        .data = "no newline at end",
    });
    const no_newline_patch =
        \\*** Begin Patch
        \\*** Update File: no_newline.txt
        \\@@
        \\-no newline at end
        \\+first line
        \\+second line
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, no_newline_patch);
    const no_newline = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "no_newline.txt", allocator, .limited(1024));
    defer allocator.free(no_newline);
    try std.testing.expectEqualStrings("first line\nsecond line\n", no_newline);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "padded.txt",
        .data = "one\n",
    });
    const padded_patch =
        \\ *** Begin Patch
        \\  *** Update File: padded.txt
        \\@@
        \\-one
        \\+two
        \\ *** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, padded_patch);
    const padded = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "padded.txt", allocator, .limited(1024));
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("two\n", padded);
}

test "apply_patch rejects empty patch and trailing content" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const empty_patch =
        \\*** Begin Patch
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, empty_patch));

    const trailing_patch =
        \\*** Begin Patch
        \\*** Add File: foo.txt
        \\+ok
        \\*** End Patch
        \\extra
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, trailing_patch));
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "foo.txt", .{}));
}

test "apply_patch rejects missing end patch before mutating files" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const add_patch =
        \\*** Begin Patch
        \\*** Add File: created.txt
        \\+new
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, add_patch));
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "created.txt", .{}));

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "existing.txt",
        .data = "old\n",
    });

    const update_patch =
        \\*** Begin Patch
        \\*** Update File: existing.txt
        \\@@
        \\-old
        \\+new
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, update_patch));

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "existing.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("old\n", content);
}

test "untrusted policy allows trusted read-only shell command without prompt" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "call-read",
        .name = "shell_command",
        .arguments = "{\"command\":\"pwd\"}",
    };

    const result = try runFunctionCall(allocator, call, .{
        .approval_policy = .untrusted,
        .sandbox_mode = .read_only,
        .prompt_for_approval = false,
    });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.summary, "exit "));
}

test "read-only sandbox blocks apply_patch even with auto approval" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "call-write",
        .name = "apply_patch",
        .arguments =
        \\{"patch":"*** Begin Patch\n*** Add File: blocked.txt\n+blocked\n*** End Patch"}
        ,
    };

    const result = try runFunctionCall(allocator, call, .{
        .approval_policy = .on_failure,
        .sandbox_mode = .read_only,
        .auto_approve = true,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("blocked by sandbox", result.summary);
    try std.testing.expectEqualStrings("blocked by sandbox_mode=read-only", result.output);
}

test "untrusted policy rejects untrusted shell command when prompting is disabled" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "call-write-shell",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf nope > blocked.txt\"}",
    };

    const result = try runFunctionCall(allocator, call, .{
        .approval_policy = .untrusted,
        .sandbox_mode = .workspace_write,
        .prompt_for_approval = false,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("rejected", result.summary);
}

test "never policy runs without prompting unless sandbox blocks it" {
    const allocator = std.testing.allocator;
    const call = api.FunctionCall{
        .call_id = "call-never",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf never-ok\"}",
    };

    const result = try runFunctionCall(allocator, call, .{
        .approval_policy = .never,
        .sandbox_mode = .danger_full_access,
        .prompt_for_approval = false,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("exit 0", result.summary);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "never-ok") != null);
}
