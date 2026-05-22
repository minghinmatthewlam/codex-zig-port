const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const hooks_list = @import("hooks_list.zig");
const plugin_config = @import("plugin_config.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

const regex_c = @cImport({
    @cInclude("regex.h");
});

const COMMAND_OUTPUT_BYTES_CAP = 64 * 1024;
const COMMAND_TIMEOUT_EXIT_CODE = 124;

pub const BYPASS_HOOK_TRUST_WARNING = "`--dangerously-bypass-hook-trust` is enabled. Enabled hooks may run without review for this invocation.";

pub const PromptHookOptions = struct {
    codex_home: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    transcript_path: ?[]const u8 = null,
    model: []const u8,
    approval_policy: config.ApprovalPolicy,
    prompt: []const u8,
    session_start_source: ?[]const u8 = null,
    bypass_hook_trust: bool = false,
    hooks_enabled: bool = true,
    ignore_user_config: bool = false,
};

pub const PromptHookResult = struct {
    session_start_contexts: std.ArrayList([]const u8) = .empty,
    contexts: std.ArrayList([]const u8) = .empty,
    messages: std.ArrayList([]const u8) = .empty,
    should_stop: bool = false,

    pub fn deinit(self: *PromptHookResult, allocator: std.mem.Allocator) void {
        for (self.session_start_contexts.items) |context| allocator.free(context);
        self.session_start_contexts.deinit(allocator);
        for (self.contexts.items) |context| allocator.free(context);
        self.contexts.deinit(allocator);
        for (self.messages.items) |message| allocator.free(message);
        self.messages.deinit(allocator);
        self.* = .{};
    }
};

pub fn runPromptHooks(allocator: std.mem.Allocator, options: PromptHookOptions) !PromptHookResult {
    var result = PromptHookResult{};
    errdefer result.deinit(allocator);

    if (!options.hooks_enabled) return result;

    var listed = try hooks_list.listWithOptions(allocator, options.codex_home, &.{options.cwd}, .{
        .ignore_user_config = options.ignore_user_config,
    });
    defer listed.deinit(allocator);
    if (listed.entries.len == 0) return result;

    if (options.session_start_source) |source| {
        var session_start = try runSessionStartHooks(allocator, listed.entries[0].hooks, options, source);
        defer session_start.deinit(allocator);
        try moveSessionStartHookResult(allocator, &result, &session_start);
        if (result.should_stop) return result;
    }

    var user_prompt = try runUserPromptSubmitHooks(allocator, listed.entries[0].hooks, options);
    defer user_prompt.deinit(allocator);
    try moveHookResult(allocator, &result, &user_prompt);

    return result;
}

pub fn sessionIdForPayload(
    allocator: std.mem.Allocator,
    session_path: ?[]const u8,
    fallback_prefix: []const u8,
) ![]const u8 {
    if (session_path) |path| return session_store.sessionIdFromPath(allocator, path);
    return renderUniqueHookId(allocator, fallback_prefix);
}

pub fn turnIdForPayload(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    return renderUniqueHookId(allocator, prefix);
}

pub fn writeMessagesToStderr(messages: []const []const u8) !void {
    for (messages) |message| {
        try cli_utils.writeStderr("hook: ");
        try cli_utils.writeStderr(message);
        try cli_utils.writeStderr("\n");
    }
}

pub fn appendStoppedContexts(
    allocator: std.mem.Allocator,
    transcript: *session.Transcript,
    result: *const PromptHookResult,
) !void {
    for (result.session_start_contexts.items) |context| {
        try transcript.appendDeveloperMessage(allocator, context);
    }
    for (result.contexts.items) |context| {
        try transcript.appendDeveloperMessage(allocator, context);
    }
}

fn renderUniqueHookId(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);
    return std.fmt.allocPrint(allocator, "{s}-{d}-{x}", .{ prefix, timestamp, random_id });
}

fn moveHookResult(allocator: std.mem.Allocator, dest: *PromptHookResult, src: *PromptHookResult) !void {
    try dest.contexts.appendSlice(allocator, src.contexts.items);
    src.contexts.clearRetainingCapacity();
    try moveHookMessages(allocator, dest, src);
}

fn moveSessionStartHookResult(allocator: std.mem.Allocator, dest: *PromptHookResult, src: *PromptHookResult) !void {
    try dest.session_start_contexts.appendSlice(allocator, src.contexts.items);
    src.contexts.clearRetainingCapacity();
    try moveHookMessages(allocator, dest, src);
}

fn moveHookMessages(allocator: std.mem.Allocator, dest: *PromptHookResult, src: *PromptHookResult) !void {
    try dest.messages.appendSlice(allocator, src.messages.items);
    src.messages.clearRetainingCapacity();
    dest.should_stop = dest.should_stop or src.should_stop;
}

fn runSessionStartHooks(
    allocator: std.mem.Allocator,
    hooks: []const hooks_list.Hook,
    options: PromptHookOptions,
    source: []const u8,
) !PromptHookResult {
    var result = PromptHookResult{};
    errdefer result.deinit(allocator);

    const input_json = try renderSessionStartHookInput(
        allocator,
        options.session_id,
        options.transcript_path,
        options.cwd,
        options.model,
        hookPermissionMode(options.approval_policy),
        source,
    );
    defer allocator.free(input_json);

    var tasks = try startMatchingHookCommands(allocator, hooks, options, input_json, .session_start, source);
    defer deinitHookCommandTasks(allocator, &tasks);
    joinHookCommandTasks(&tasks);

    for (tasks.items) |*task| {
        const status = if (task.result) |*run_result|
            try collectSessionStartHookEntries(allocator, run_result, &result)
        else
            try collectHookRunError(allocator, task, &result);
        if (status == .stopped) result.should_stop = true;
    }

    return result;
}

fn runUserPromptSubmitHooks(
    allocator: std.mem.Allocator,
    hooks: []const hooks_list.Hook,
    options: PromptHookOptions,
) !PromptHookResult {
    var result = PromptHookResult{};
    errdefer result.deinit(allocator);

    const input_json = try renderUserPromptSubmitHookInput(
        allocator,
        options.session_id,
        options.turn_id,
        options.transcript_path,
        options.cwd,
        options.model,
        hookPermissionMode(options.approval_policy),
        options.prompt,
    );
    defer allocator.free(input_json);

    var tasks = try startMatchingHookCommands(allocator, hooks, options, input_json, .user_prompt_submit, null);
    defer deinitHookCommandTasks(allocator, &tasks);
    joinHookCommandTasks(&tasks);

    for (tasks.items) |*task| {
        const status = if (task.result) |*run_result|
            try collectUserPromptSubmitHookEntries(allocator, run_result, &result)
        else
            try collectHookRunError(allocator, task, &result);
        if (status == .blocked or status == .stopped) result.should_stop = true;
    }

    return result;
}

fn hookPermissionMode(approval_policy: config.ApprovalPolicy) []const u8 {
    return switch (approval_policy) {
        .never => "bypassPermissions",
        .untrusted, .on_failure, .on_request => "default",
    };
}

const HookStatus = enum {
    completed,
    failed,
    blocked,
    stopped,
};

const HookCommandTask = struct {
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    hook: hooks_list.Hook,
    cwd: []const u8,
    input_json: []const u8,
    thread: ?std.Thread = null,
    result: ?CommandRunResult = null,
    err: ?anyerror = null,

    fn run(self: *HookCommandTask) void {
        self.result = runHookCommand(self.allocator, self.codex_home, self.hook, self.cwd, self.input_json) catch |err| {
            self.err = err;
            return;
        };
    }

    fn deinit(self: *HookCommandTask) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.result) |*run_result| {
            run_result.deinit(self.allocator);
            self.result = null;
        }
    }
};

fn startMatchingHookCommands(
    allocator: std.mem.Allocator,
    hooks: []const hooks_list.Hook,
    options: PromptHookOptions,
    input_json: []const u8,
    event_name: hooks_list.HookEvent,
    matcher_input: ?[]const u8,
) !std.ArrayList(HookCommandTask) {
    var tasks = std.ArrayList(HookCommandTask).empty;
    errdefer deinitHookCommandTasks(allocator, &tasks);
    try tasks.ensureTotalCapacity(allocator, hooks.len);

    for (hooks) |hook| {
        if (hook.event_name != event_name or !hook.shouldRunWithBypass(options.bypass_hook_trust)) continue;
        if (matcher_input) |input| {
            if (!(try hookMatcherMatchesInput(allocator, hook.matcher, input))) continue;
        }

        const index = tasks.items.len;
        tasks.appendAssumeCapacity(.{
            .allocator = std.heap.c_allocator,
            .codex_home = options.codex_home,
            .hook = hook,
            .cwd = options.cwd,
            .input_json = input_json,
        });
        tasks.items[index].thread = std.Thread.spawn(.{}, HookCommandTask.run, .{&tasks.items[index]}) catch |err| {
            joinHookCommandTasks(&tasks);
            return err;
        };
    }

    return tasks;
}

fn collectHookRunError(
    allocator: std.mem.Allocator,
    task: *const HookCommandTask,
    result: *PromptHookResult,
) !HookStatus {
    const err = task.err orelse return error.HookCommandMissingResult;
    const message = try std.fmt.allocPrint(allocator, "hook failed to run: {s}", .{@errorName(err)});
    defer allocator.free(message);
    try appendMessage(allocator, &result.messages, message);
    return .failed;
}

fn joinHookCommandTasks(tasks: *std.ArrayList(HookCommandTask)) void {
    for (tasks.items) |*task| {
        if (task.thread) |thread| {
            thread.join();
            task.thread = null;
        }
    }
}

fn deinitHookCommandTasks(allocator: std.mem.Allocator, tasks: *std.ArrayList(HookCommandTask)) void {
    for (tasks.items) |*task| task.deinit();
    tasks.deinit(allocator);
}

const CommandRunResult = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    stdout_observed_len: usize,
    stderr_observed_len: usize,

    fn deinit(self: *CommandRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = .{ .exit_code = 0, .stdout = "", .stderr = "", .stdout_observed_len = 0, .stderr_observed_len = 0 };
    }
};

fn runHookCommand(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    hook: hooks_list.Hook,
    cwd: []const u8,
    input_json: []const u8,
) !CommandRunResult {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const command = try hookCommand(allocator, codex_home, hook);
    defer allocator.free(command);
    const argv = [_][]const u8{ currentHookShell(), "-lc", command };
    const timeout_sec = @min(hook.timeout_sec, @as(u64, @intCast(std.math.maxInt(i64) / 1000)));
    const timeout_ms: i64 = @intCast(timeout_sec * 1000);

    var child_env = try hookEnvironment(allocator, codex_home, hook);
    defer if (child_env) |*hook_env| hook_env.deinit();
    const env_map = if (child_env) |*hook_env| hook_env else null;

    return runCommandProcess(
        allocator,
        &io_instance,
        &argv,
        .{ .path = cwd },
        env_map,
        input_json,
        timeout_ms,
        COMMAND_OUTPUT_BYTES_CAP,
    );
}

fn hookCommand(allocator: std.mem.Allocator, codex_home: []const u8, hook: hooks_list.Hook) ![]const u8 {
    var command = try allocator.dupe(u8, hook.command);
    errdefer allocator.free(command);
    if (hook.source != .plugin) return command;

    const plugin_id = hook.plugin_id orelse return command;
    const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse return command;
    defer allocator.free(plugin_root);
    const plugin_data_root = (try plugin_config.localPluginDataRoot(allocator, codex_home, plugin_id)) orelse return command;
    defer allocator.free(plugin_data_root);

    try replaceHookCommandPlaceholder(allocator, &command, "${PLUGIN_ROOT}", plugin_root);
    try replaceHookCommandPlaceholder(allocator, &command, "${CLAUDE_PLUGIN_ROOT}", plugin_root);
    try replaceHookCommandPlaceholder(allocator, &command, "${PLUGIN_DATA}", plugin_data_root);
    try replaceHookCommandPlaceholder(allocator, &command, "${CLAUDE_PLUGIN_DATA}", plugin_data_root);
    return command;
}

fn replaceHookCommandPlaceholder(
    allocator: std.mem.Allocator,
    command: *[]u8,
    placeholder: []const u8,
    replacement: []const u8,
) !void {
    if (std.mem.indexOf(u8, command.*, placeholder) == null) return;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, command.*, start, placeholder)) |index| {
        try out.appendSlice(allocator, command.*[start..index]);
        try out.appendSlice(allocator, replacement);
        start = index + placeholder.len;
    }
    try out.appendSlice(allocator, command.*[start..]);

    const next = try out.toOwnedSlice(allocator);
    allocator.free(command.*);
    command.* = next;
}

fn hookEnvironment(allocator: std.mem.Allocator, codex_home: []const u8, hook: hooks_list.Hook) !?std.process.Environ.Map {
    if (hook.source != .plugin) return null;
    const plugin_id = hook.plugin_id orelse return null;
    const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse return null;
    defer allocator.free(plugin_root);
    const plugin_data_root = (try plugin_config.localPluginDataRoot(allocator, codex_home, plugin_id)) orelse return null;
    defer allocator.free(plugin_data_root);

    var hook_env = try currentEnvironment(allocator);
    errdefer hook_env.deinit();
    try hook_env.put("PLUGIN_ROOT", plugin_root);
    try hook_env.put("CLAUDE_PLUGIN_ROOT", plugin_root);
    try hook_env.put("PLUGIN_DATA", plugin_data_root);
    try hook_env.put("CLAUDE_PLUGIN_DATA", plugin_data_root);
    return hook_env;
}

fn currentEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    var index: usize = 0;
    while (std.c.environ[index]) |entry_ptr| : (index += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        try result.put(key, entry[eq + 1 ..]);
    }
    return result;
}

fn currentHookShell() []const u8 {
    const raw = std.c.getenv("SHELL") orelse return "/bin/sh";
    const shell = std.mem.span(raw);
    if (shell.len == 0 or !std.fs.path.isAbsolute(shell)) return "/bin/sh";
    return shell;
}

fn runCommandProcess(
    allocator: std.mem.Allocator,
    io_instance: *std.Io.Threaded,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*std.process.Environ.Map,
    stdin_payload: []const u8,
    timeout_ms: i64,
    output_bytes_cap: usize,
) !CommandRunResult {
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var child_alive = true;
    errdefer if (child_alive) child.kill(io_instance.io());

    var stdin_file: ?std.Io.File = child.stdin;
    child.stdin = null;
    defer if (stdin_file) |file| file.close(io_instance.io());

    var stdout = std.ArrayList(u8).empty;
    errdefer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    errdefer stderr.deinit(allocator);
    var stdout_observed_len: usize = 0;
    var stderr_observed_len: usize = 0;
    var stdin_written: usize = 0;

    const started = std.Io.Timestamp.now(io_instance.io(), .awake);
    while (true) {
        if (pollCommandChild(&child)) |term| {
            child_alive = false;
            try drainCommandOutput(io_instance, allocator, &child, &stdout, &stderr, &stdout_observed_len, &stderr_observed_len, output_bytes_cap);
            return finishCommandRunResult(allocator, commandExitCode(term), &stdout, &stderr, stdout_observed_len, stderr_observed_len);
        }

        _ = try writeCommandStdinChunk(io_instance, &stdin_file, stdin_payload, &stdin_written, 2);
        _ = try readCommandPipeChunk(io_instance, allocator, child.stdout, &stdout, &stdout_observed_len, output_bytes_cap, 2);
        _ = try readCommandPipeChunk(io_instance, allocator, child.stderr, &stderr, &stderr_observed_len, output_bytes_cap, 2);

        if (elapsedCommandMilliseconds(io_instance.io(), started) >= @as(u64, @intCast(timeout_ms))) {
            child.kill(io_instance.io());
            child_alive = false;
            return finishCommandRunResult(allocator, COMMAND_TIMEOUT_EXIT_CODE, &stdout, &stderr, stdout_observed_len, stderr_observed_len);
        }
    }
}

fn writeCommandStdinChunk(
    io_instance: *std.Io.Threaded,
    stdin_file: *?std.Io.File,
    payload: []const u8,
    written: *usize,
    timeout_ms: u64,
) !bool {
    const file = stdin_file.* orelse return false;
    if (written.* >= payload.len) {
        closeCommandStdin(io_instance, stdin_file);
        return false;
    }

    const remaining = payload[written.*..];
    const chunk = remaining[0..@min(remaining.len, 16 * 1024)];
    const result = io_instance.io().operateTimeout(.{ .file_write_streaming = .{
        .file = file,
        .data = &.{chunk},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    const count = result.file_write_streaming catch |err| switch (err) {
        error.WouldBlock => return false,
        error.BrokenPipe => {
            closeCommandStdin(io_instance, stdin_file);
            return false;
        },
        else => return err,
    };
    if (count == 0) return false;

    written.* += count;
    if (written.* >= payload.len) closeCommandStdin(io_instance, stdin_file);
    return true;
}

fn closeCommandStdin(io_instance: *std.Io.Threaded, stdin_file: *?std.Io.File) void {
    const file = stdin_file.* orelse return;
    file.close(io_instance.io());
    stdin_file.* = null;
}

fn readCommandPipeChunk(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    maybe_file: ?std.Io.File,
    output: *std.ArrayList(u8),
    observed_len: *usize,
    output_bytes_cap: usize,
    timeout_ms: u64,
) !bool {
    const file = maybe_file orelse return false;
    var buffer: [4096]u8 = undefined;
    const result = io_instance.io().operateTimeout(.{ .file_read_streaming = .{
        .file = file,
        .data = &.{buffer[0..]},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    const count = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => return false,
        error.WouldBlock => return false,
        else => return err,
    };
    if (count == 0) return false;
    observed_len.* += count;
    const bytes = buffer[0..count];
    const remaining = output_bytes_cap -| output.items.len;
    try output.appendSlice(allocator, bytes[0..@min(bytes.len, remaining)]);
    return true;
}

fn drainCommandOutput(
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
        made_progress = try readCommandPipeChunk(io_instance, allocator, child.stdout, stdout, stdout_observed_len, output_bytes_cap, 1) or made_progress;
        made_progress = try readCommandPipeChunk(io_instance, allocator, child.stderr, stderr, stderr_observed_len, output_bytes_cap, 1) or made_progress;
        if (made_progress) {
            empty_rounds = 0;
        } else {
            empty_rounds += 1;
        }
    }
}

fn pollCommandChild(child: *std.process.Child) ?std.process.Child.Term {
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

fn commandExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        .unknown => |status| @intCast(status),
    };
}

fn elapsedCommandMilliseconds(io: std.Io, started: std.Io.Timestamp) u64 {
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    if (elapsed.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
}

fn finishCommandRunResult(
    allocator: std.mem.Allocator,
    exit_code: i32,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: usize,
    stderr_observed_len: usize,
) !CommandRunResult {
    const stdout_owned = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_owned);
    const stderr_owned = try stderr.toOwnedSlice(allocator);
    return .{
        .exit_code = exit_code,
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .stdout_observed_len = stdout_observed_len,
        .stderr_observed_len = stderr_observed_len,
    };
}

fn renderUserPromptSubmitHookInput(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    turn_id: []const u8,
    transcript_path: ?[]const u8,
    cwd: []const u8,
    model: []const u8,
    permission_mode: []const u8,
    prompt: []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try appendJsonString(allocator, &out, session_id);
    try out.appendSlice(allocator, ",\"turn_id\":");
    try appendJsonString(allocator, &out, turn_id);
    try out.appendSlice(allocator, ",\"transcript_path\":");
    try appendOptionalJsonString(allocator, &out, transcript_path);
    try out.appendSlice(allocator, ",\"cwd\":");
    try appendJsonString(allocator, &out, cwd);
    try out.appendSlice(allocator, ",\"hook_event_name\":\"UserPromptSubmit\",\"model\":");
    try appendJsonString(allocator, &out, model);
    try out.appendSlice(allocator, ",\"permission_mode\":");
    try appendJsonString(allocator, &out, permission_mode);
    try out.appendSlice(allocator, ",\"prompt\":");
    try appendJsonString(allocator, &out, prompt);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn renderSessionStartHookInput(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    transcript_path: ?[]const u8,
    cwd: []const u8,
    model: []const u8,
    permission_mode: []const u8,
    source: []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"session_id\":");
    try appendJsonString(allocator, &out, session_id);
    try out.appendSlice(allocator, ",\"transcript_path\":");
    try appendOptionalJsonString(allocator, &out, transcript_path);
    try out.appendSlice(allocator, ",\"cwd\":");
    try appendJsonString(allocator, &out, cwd);
    try out.appendSlice(allocator, ",\"hook_event_name\":\"SessionStart\",\"model\":");
    try appendJsonString(allocator, &out, model);
    try out.appendSlice(allocator, ",\"permission_mode\":");
    try appendJsonString(allocator, &out, permission_mode);
    try out.appendSlice(allocator, ",\"source\":");
    try appendJsonString(allocator, &out, source);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn collectSessionStartHookEntries(
    allocator: std.mem.Allocator,
    run_result: *const CommandRunResult,
    result: *PromptHookResult,
) !HookStatus {
    if (run_result.exit_code == 0) {
        const trimmed_stdout = std.mem.trim(u8, run_result.stdout, " \t\r\n");
        if (trimmed_stdout.len == 0) return .completed;
        if (try collectJsonSessionStartHookOutput(allocator, trimmed_stdout, result)) |status| return status;
        if (looksLikeJson(trimmed_stdout)) {
            try appendMessage(allocator, &result.messages, "hook returned invalid session start JSON output");
            return .failed;
        }
        try appendContext(allocator, &result.contexts, trimmed_stdout);
        return .completed;
    }
    const message = try std.fmt.allocPrint(allocator, "hook exited with code {d}", .{run_result.exit_code});
    defer allocator.free(message);
    try appendMessage(allocator, &result.messages, message);
    return .failed;
}

fn collectJsonSessionStartHookOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    result: *PromptHookResult,
) !?HookStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    if (!isValidSessionStartOutputObject(object)) return try invalidSessionStartJsonOutput(allocator, result);

    if (optionalHookStringField(object, "systemMessage")) |message| {
        try appendMessage(allocator, &result.messages, message);
    }

    if (object.get("hookSpecificOutput")) |specific| {
        if (specific == .object) {
            const event_name = optionalHookStringField(specific.object, "hookEventName") orelse return try invalidSessionStartJsonOutput(allocator, result);
            if (!std.mem.eql(u8, event_name, "SessionStart")) return try invalidSessionStartJsonOutput(allocator, result);
            if (optionalHookStringField(specific.object, "additionalContext")) |context| {
                try appendContext(allocator, &result.contexts, context);
            }
        } else if (specific != .null) {
            return try invalidSessionStartJsonOutput(allocator, result);
        }
    }

    if (optionalBoolField(object, "continue")) |continue_processing| {
        if (!continue_processing) {
            if (optionalHookStringField(object, "stopReason")) |reason| {
                try appendMessage(allocator, &result.messages, reason);
            }
            return .stopped;
        }
    }

    return .completed;
}

fn invalidSessionStartJsonOutput(allocator: std.mem.Allocator, result: *PromptHookResult) !HookStatus {
    try appendMessage(allocator, &result.messages, "hook returned invalid session start JSON output");
    return .failed;
}

fn collectUserPromptSubmitHookEntries(
    allocator: std.mem.Allocator,
    run_result: *const CommandRunResult,
    result: *PromptHookResult,
) !HookStatus {
    if (run_result.exit_code == 0) {
        const trimmed_stdout = std.mem.trim(u8, run_result.stdout, " \t\r\n");
        if (trimmed_stdout.len == 0) return .completed;
        if (try collectJsonUserPromptSubmitHookOutput(allocator, trimmed_stdout, result)) |status| return status;
        if (looksLikeJson(trimmed_stdout)) {
            try appendMessage(allocator, &result.messages, "hook returned invalid user prompt submit JSON output");
            return .failed;
        }
        try appendContext(allocator, &result.contexts, trimmed_stdout);
        return .completed;
    }
    if (run_result.exit_code == 2) {
        const reason = std.mem.trim(u8, run_result.stderr, " \t\r\n");
        if (reason.len > 0) {
            try appendMessage(allocator, &result.messages, reason);
            return .blocked;
        }
        try appendMessage(allocator, &result.messages, "UserPromptSubmit hook exited with code 2 but did not write a blocking reason to stderr");
        return .failed;
    }
    const message = try std.fmt.allocPrint(allocator, "hook exited with code {d}", .{run_result.exit_code});
    defer allocator.free(message);
    try appendMessage(allocator, &result.messages, message);
    return .failed;
}

fn collectJsonUserPromptSubmitHookOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    result: *PromptHookResult,
) !?HookStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    if (!isValidUserPromptSubmitOutputObject(object)) return try invalidUserPromptSubmitJsonOutput(allocator, result);

    var additional_context: ?[]const u8 = null;
    if (object.get("hookSpecificOutput")) |specific| {
        if (specific == .object) {
            const event_name = optionalHookStringField(specific.object, "hookEventName") orelse return try invalidUserPromptSubmitJsonOutput(allocator, result);
            if (!isHookEventWireName(event_name)) return try invalidUserPromptSubmitJsonOutput(allocator, result);
            additional_context = optionalHookStringField(specific.object, "additionalContext");
        } else if (specific != .null) {
            return try invalidUserPromptSubmitJsonOutput(allocator, result);
        }
    }

    var should_block = false;
    var invalid_block_reason = false;
    var block_reason: ?[]const u8 = null;
    if (object.get("decision")) |decision_value| {
        if (decision_value == .string and std.mem.eql(u8, decision_value.string, "block")) {
            should_block = true;
            block_reason = optionalHookStringField(object, "reason");
            invalid_block_reason = block_reason == null or std.mem.trim(u8, block_reason.?, " \t\r\n").len == 0;
        } else if (decision_value != .null) {
            return try invalidUserPromptSubmitJsonOutput(allocator, result);
        }
    }

    if (optionalHookStringField(object, "systemMessage")) |message| {
        try appendMessage(allocator, &result.messages, message);
    }

    if (!invalid_block_reason) {
        if (additional_context) |context| {
            try appendContext(allocator, &result.contexts, context);
        }
    }

    if (optionalBoolField(object, "continue")) |continue_processing| {
        if (!continue_processing) {
            if (optionalHookStringField(object, "stopReason")) |reason| {
                if (std.mem.trim(u8, reason, " \t\r\n").len > 0) try appendMessage(allocator, &result.messages, reason);
            }
            return .stopped;
        }
    }
    if (invalid_block_reason) {
        try appendMessage(allocator, &result.messages, "UserPromptSubmit hook returned decision:block without a non-empty reason");
        return .failed;
    }
    if (should_block) {
        try appendMessage(allocator, &result.messages, block_reason.?);
        return .blocked;
    }
    return .completed;
}

fn invalidUserPromptSubmitJsonOutput(allocator: std.mem.Allocator, result: *PromptHookResult) !HookStatus {
    try appendMessage(allocator, &result.messages, "hook returned invalid user prompt submit JSON output");
    return .failed;
}

fn isValidSessionStartOutputObject(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "continue") or std.mem.eql(u8, key, "suppressOutput")) {
            if (value != .bool) return false;
        } else if (std.mem.eql(u8, key, "systemMessage") or std.mem.eql(u8, key, "stopReason")) {
            if (!isNullOrString(value)) return false;
        } else if (std.mem.eql(u8, key, "hookSpecificOutput")) {
            if (!isValidSessionStartHookSpecificOutput(value)) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn isValidSessionStartHookSpecificOutput(value: std.json.Value) bool {
    if (value == .null) return true;
    if (value != .object) return false;
    const object = value.object;
    const event_name = object.get("hookEventName") orelse return false;
    if (event_name != .string or !std.mem.eql(u8, event_name.string, "SessionStart")) return false;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "hookEventName")) {
            if (field_value != .string or !std.mem.eql(u8, field_value.string, "SessionStart")) return false;
        } else if (std.mem.eql(u8, key, "additionalContext")) {
            if (!isNullOrString(field_value)) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn isValidUserPromptSubmitOutputObject(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "continue") or std.mem.eql(u8, key, "suppressOutput")) {
            if (value != .bool) return false;
        } else if (std.mem.eql(u8, key, "systemMessage") or std.mem.eql(u8, key, "stopReason") or std.mem.eql(u8, key, "reason")) {
            if (!isNullOrString(value)) return false;
        } else if (std.mem.eql(u8, key, "decision")) {
            if (value != .null and (value != .string or !std.mem.eql(u8, value.string, "block"))) return false;
        } else if (std.mem.eql(u8, key, "hookSpecificOutput")) {
            if (!isValidUserPromptSubmitHookSpecificOutput(value)) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn isValidUserPromptSubmitHookSpecificOutput(value: std.json.Value) bool {
    if (value == .null) return true;
    if (value != .object) return false;
    const object = value.object;
    const event_name = object.get("hookEventName") orelse return false;
    if (event_name != .string or !isHookEventWireName(event_name.string)) return false;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "hookEventName")) {
            if (field_value != .string or !isHookEventWireName(field_value.string)) return false;
        } else if (std.mem.eql(u8, key, "additionalContext")) {
            if (!isNullOrString(field_value)) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn optionalHookStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn optionalBoolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn isNullOrString(value: std.json.Value) bool {
    return value == .null or value == .string;
}

fn isHookEventWireName(value: []const u8) bool {
    inline for (&.{
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PreCompact",
        "PostCompact",
        "SessionStart",
        "UserPromptSubmit",
        "Stop",
    }) |name| {
        if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn appendContext(allocator: std.mem.Allocator, contexts: *std.ArrayList([]const u8), context: []const u8) !void {
    const owned = try allocator.dupe(u8, context);
    errdefer allocator.free(owned);
    try contexts.append(allocator, owned);
}

fn appendMessage(allocator: std.mem.Allocator, messages: *std.ArrayList([]const u8), message: []const u8) !void {
    const owned = try allocator.dupe(u8, message);
    errdefer allocator.free(owned);
    try messages.append(allocator, owned);
}

fn looksLikeJson(value: []const u8) bool {
    return value.len > 0 and (value[0] == '{' or value[0] == '[');
}

fn hookMatcherMatchesInput(allocator: std.mem.Allocator, matcher: ?[]const u8, input: []const u8) !bool {
    const value = matcher orelse return true;
    if (value.len == 0 or std.mem.eql(u8, value, "*")) return true;
    if (!hookMatcherIsExact(value)) return hookRegexMatcherMatchesInput(allocator, value, input);

    var parts = std.mem.splitScalar(u8, value, '|');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, input)) return true;
    }
    return false;
}

fn hookMatcherIsExact(matcher: []const u8) bool {
    for (matcher) |ch| {
        if ((ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or
            ch == '|')
        {
            continue;
        }
        return false;
    }
    return true;
}

fn hookRegexMatcherMatchesInput(allocator: std.mem.Allocator, matcher: []const u8, input: []const u8) !bool {
    const translated = try translateRustRegexForPosix(allocator, matcher);
    defer translated.deinit(allocator);
    return hookPosixRegexMatcherMatchesInput(allocator, translated.pattern, input, translated.flags);
}

const TranslatedHookRegex = struct {
    pattern: []const u8,
    flags: c_int,

    fn deinit(self: TranslatedHookRegex, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
};

fn translateRustRegexForPosix(allocator: std.mem.Allocator, matcher: []const u8) !TranslatedHookRegex {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var flags: c_int = regex_c.REG_EXTENDED;
    var index: usize = 0;
    while (index < matcher.len) {
        if (try appendTranslatedRustRegexGroup(allocator, &out, matcher, &index, &flags)) continue;

        const ch = matcher[index];
        if (ch == '\\' and index + 1 < matcher.len) {
            const next = matcher[index + 1];
            switch (next) {
                'd' => {
                    try out.appendSlice(allocator, "[[:digit:]]");
                    index += 2;
                    continue;
                },
                'D' => {
                    try out.appendSlice(allocator, "[^[:digit:]]");
                    index += 2;
                    continue;
                },
                's' => {
                    try out.appendSlice(allocator, "[[:space:]]");
                    index += 2;
                    continue;
                },
                'S' => {
                    try out.appendSlice(allocator, "[^[:space:]]");
                    index += 2;
                    continue;
                },
                'w' => {
                    try out.appendSlice(allocator, "[[:alnum:]_]");
                    index += 2;
                    continue;
                },
                'W' => {
                    try out.appendSlice(allocator, "[^[:alnum:]_]");
                    index += 2;
                    continue;
                },
                else => {},
            }
            try out.append(allocator, ch);
            try out.append(allocator, next);
            index += 2;
            continue;
        }

        if ((ch == '*' or ch == '+' or ch == '?') and index + 1 < matcher.len and matcher[index + 1] == '?') {
            try out.append(allocator, ch);
            index += 2;
            continue;
        }

        try out.append(allocator, ch);
        index += 1;
    }
    return .{ .pattern = try out.toOwnedSlice(allocator), .flags = flags };
}

fn appendTranslatedRustRegexGroup(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    matcher: []const u8,
    index: *usize,
    flags: *c_int,
) !bool {
    if (index.* + 2 >= matcher.len) return false;
    if (matcher[index.*] != '(' or matcher[index.* + 1] != '?') return false;

    const kind = matcher[index.* + 2];
    if (kind == ':') {
        try out.append(allocator, '(');
        index.* += 3;
        return true;
    }
    if (kind == '<') {
        if (std.mem.indexOfScalarPos(u8, matcher, index.* + 3, '>')) |end| {
            try out.append(allocator, '(');
            index.* = end + 1;
            return true;
        }
        return false;
    }
    if (kind == 'P' and index.* + 3 < matcher.len and matcher[index.* + 3] == '<') {
        if (std.mem.indexOfScalarPos(u8, matcher, index.* + 4, '>')) |end| {
            try out.append(allocator, '(');
            index.* = end + 1;
            return true;
        }
        return false;
    }

    var cursor = index.* + 2;
    var saw_flag = false;
    var negating = false;
    while (cursor < matcher.len) : (cursor += 1) {
        switch (matcher[cursor]) {
            'i' => {
                saw_flag = true;
                if (!negating) flags.* |= regex_c.REG_ICASE;
            },
            'm', 's', 'U', 'x' => saw_flag = true,
            '-' => {
                saw_flag = true;
                negating = true;
            },
            ':' => {
                if (!saw_flag) return false;
                try out.append(allocator, '(');
                index.* = cursor + 1;
                return true;
            },
            ')' => {
                if (!saw_flag) return false;
                index.* = cursor + 1;
                return true;
            },
            else => return false,
        }
    }
    return false;
}

fn hookPosixRegexMatcherMatchesInput(allocator: std.mem.Allocator, matcher: []const u8, input: []const u8, flags: c_int) !bool {
    const matcher_z = try allocator.dupeZ(u8, matcher);
    defer allocator.free(matcher_z);
    const input_z = try allocator.dupeZ(u8, input);
    defer allocator.free(input_z);

    var regex: regex_c.regex_t = undefined;
    if (regex_c.regcomp(&regex, matcher_z.ptr, flags) != 0) return false;
    defer regex_c.regfree(&regex);
    return regex_c.regexec(&regex, input_z.ptr, 0, null, 0) == 0;
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn appendOptionalJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |text| {
        try appendJsonString(allocator, out, text);
    } else {
        try out.appendSlice(allocator, "null");
    }
}

test "hook matcher supports exact alternatives and regexes" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try hookMatcherMatchesInput(allocator, null, "startup"));
    try std.testing.expect(try hookMatcherMatchesInput(allocator, "startup|resume", "resume"));
    try std.testing.expect(!try hookMatcherMatchesInput(allocator, "startup|resume", "clear"));
    try std.testing.expect(try hookMatcherMatchesInput(allocator, "^start.*$", "startup"));
    try std.testing.expect(try hookMatcherMatchesInput(allocator, "(?i)^(?:STARTUP|RESUME)$", "startup"));
}

test "hook payload ids use session ids and unique generated turn ids" {
    const allocator = std.testing.allocator;
    const session_id = try sessionIdForPayload(allocator, "/tmp/rollout-123456-test.jsonl", "exec");
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("123456-test", session_id);

    const ephemeral_session_id = try sessionIdForPayload(allocator, null, "exec");
    defer allocator.free(ephemeral_session_id);
    try std.testing.expect(std.mem.startsWith(u8, ephemeral_session_id, "exec-"));

    const turn_id = try turnIdForPayload(allocator, "exec-turn");
    defer allocator.free(turn_id);
    try std.testing.expect(std.mem.startsWith(u8, turn_id, "exec-turn-"));
    try std.testing.expect(!std.mem.eql(u8, turn_id, "exec-turn"));
}
