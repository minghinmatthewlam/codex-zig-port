const std = @import("std");
const builtin = @import("builtin");

const net = std.Io.net;

const cli_utils = @import("cli_utils.zig");

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*anyopaque,
    winp: ?*std.posix.winsize,
) c_int;

const default_listen_url = "ws://127.0.0.1:0";
const max_stdio_json_rpc_line_bytes = 16 * 1024 * 1024;
const retained_output_bytes_per_process = 1024 * 1024;
const retained_closed_processes = 64;
const max_stdin_write_queue_bytes = 2 * 1024 * 1024;
const max_stdin_write_queue_chunks = 32;
const max_buffered_input_read_wait_ms = 200;
const max_detached_exec_sessions = 64;
const detached_exec_session_poll_interval_ms = 50;
const max_exec_server_read_file_bytes = 512 * 1024 * 1024;
const default_exec_tty_rows = 24;
const default_exec_tty_cols = 80;
const default_env_exclude_patterns = [_][]const u8{ "*KEY*", "*SECRET*", "*TOKEN*" };
const unix_core_env_vars = [_][]const u8{ "PATH", "SHELL", "TMPDIR", "TEMP", "TMP", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "USER" };
const windows_core_env_vars = [_][]const u8{
    "PATH",
    "PATHEXT",
    "SHELL",
    "COMSPEC",
    "SYSTEMROOT",
    "SYSTEMDRIVE",
    "USERNAME",
    "USERDOMAIN",
    "USERPROFILE",
    "HOMEDRIVE",
    "HOMEPATH",
    "PROGRAMFILES",
    "PROGRAMFILES(X86)",
    "PROGRAMW6432",
    "PROGRAMDATA",
    "LOCALAPPDATA",
    "APPDATA",
    "TEMP",
    "TMP",
    "TMPDIR",
    "POWERSHELL",
    "PWSH",
};

const WebSocketListen = struct {
    host: []const u8,
    port: u16,
};

const Transport = union(enum) {
    stdio,
    websocket: WebSocketListen,
};

const ParsedOptions = struct {
    help: bool = false,
    listen: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    executor_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const ExecStartParams = struct {
    process_id: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: std.json.Value,
    env_policy: ?ExecEnvPolicy,
    tty: bool,
    pipe_stdin: bool,
    arg0: ?[]const u8,

    fn deinit(self: ExecStartParams, allocator: std.mem.Allocator) void {
        if (self.env_policy) |policy| policy.deinit(allocator);
        allocator.free(self.argv);
    }
};

const ExecEnvPolicy = struct {
    inherit: ExecEnvPolicyInherit,
    ignore_default_excludes: bool,
    exclude: []const []const u8,
    set: std.json.Value,
    include_only: []const []const u8,

    fn deinit(self: ExecEnvPolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.exclude);
        allocator.free(self.include_only);
    }
};

const ExecEnvPolicyInherit = enum {
    all,
    core,
    none,
};

const ProcessOutputChunk = struct {
    seq: u64,
    stream: []const u8,
    data: []const u8,

    fn deinit(self: ProcessOutputChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const StdinWriteTask = struct {
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: std.ArrayList([]const u8) = .empty,
    pending_bytes: usize = 0,
    closed: bool = false,
    allocator: std.mem.Allocator,
    file: std.Io.File,

    fn deinit(self: *StdinWriteTask, allocator: std.mem.Allocator) void {
        for (self.queue.items) |chunk| allocator.free(chunk);
        self.queue.deinit(allocator);
    }
};

fn runStdinWriteTask(task: *StdinWriteTask) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    while (true) {
        task.mutex.lockUncancelable(io);
        while (task.queue.items.len == 0 and !task.closed) {
            task.condition.waitUncancelable(io, &task.mutex);
        }
        if (task.closed) {
            clearStdinTaskQueue(task);
            task.mutex.unlock(io);
            break;
        }
        const chunk = task.queue.orderedRemove(0);
        task.mutex.unlock(io);

        const ok = writeStdinChunk(task.file, chunk);
        const chunk_len = chunk.len;
        task.allocator.free(chunk);
        task.mutex.lockUncancelable(io);
        task.pending_bytes -|= chunk_len;
        task.mutex.unlock(io);
        if (!ok) {
            task.failed.store(true, .release);
            task.mutex.lockUncancelable(io);
            task.closed = true;
            clearStdinTaskQueue(task);
            task.mutex.unlock(io);
            break;
        }
    }
    task.done.store(true, .release);
}

fn writeStdinChunk(file: std.Io.File, chunk: []const u8) bool {
    var offset: usize = 0;
    while (offset < chunk.len) {
        const rc = std.c.write(file.handle, chunk[offset..].ptr, chunk.len - offset);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc <= 0) return false;
                offset += @intCast(rc);
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn clearStdinTaskQueue(task: *StdinWriteTask) void {
    for (task.queue.items) |chunk| {
        task.pending_bytes -|= chunk.len;
        task.allocator.free(chunk);
    }
    task.queue.clearRetainingCapacity();
}

const ProcessSession = struct {
    process_id: []const u8,
    io_instance: std.Io.Threaded,
    child: std.process.Child,
    process_group_id: ?std.posix.pid_t,
    path_lookup_env_block: ?std.process.Environ.Block = null,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    tty: bool = false,
    stdin_write_task: ?*StdinWriteTask = null,
    output: std.ArrayList(ProcessOutputChunk) = .empty,
    retained_bytes: usize = 0,
    next_seq: u64 = 1,
    exit_code: ?i32 = null,
    closed: bool = false,

    fn deinit(self: *ProcessSession, allocator: std.mem.Allocator) void {
        if (!self.closed and self.process_group_id != null) {
            terminateProcess(allocator, self) catch {
                self.child.kill(self.io_instance.io());
                self.closeOpenFiles();
                self.markClosed();
            };
        }
        self.finishStdinWriteTask(allocator);
        self.closeOpenFiles();
        for (self.output.items) |chunk| chunk.deinit(allocator);
        self.output.deinit(allocator);
        allocator.free(self.process_id);
        self.io_instance.deinit();
        if (self.path_lookup_env_block) |block| block.deinit(allocator);
    }

    fn closeOpenFiles(self: *ProcessSession) void {
        const io = self.io_instance.io();
        if (self.stdin_file) |file| file.close(io);
        if (self.stdout_file) |file| file.close(io);
        if (self.stderr_file) |file| file.close(io);
        self.stdin_file = null;
        self.stdout_file = null;
        self.stderr_file = null;
    }

    fn reapStdinWriteTask(self: *ProcessSession, allocator: std.mem.Allocator) void {
        const task = self.stdin_write_task orelse return;
        if (!task.done.load(.acquire)) return;
        task.thread.join();
        const failed = task.failed.load(.acquire);
        task.deinit(allocator);
        allocator.destroy(task);
        self.stdin_write_task = null;
        if (failed) {
            self.closeStdinFile();
        }
    }

    fn finishStdinWriteTask(self: *ProcessSession, allocator: std.mem.Allocator) void {
        const task = self.stdin_write_task orelse return;
        self.closeStdinFile();
        const io = std.Io.Threaded.global_single_threaded.io();
        task.mutex.lockUncancelable(io);
        task.closed = true;
        task.condition.broadcast(io);
        task.mutex.unlock(io);
        task.thread.join();
        task.deinit(allocator);
        allocator.destroy(task);
        self.stdin_write_task = null;
    }

    fn closeStdinFile(self: *ProcessSession) void {
        if (self.stdin_file) |file| {
            file.close(self.io_instance.io());
            self.stdin_file = null;
        }
    }

    fn appendOutput(self: *ProcessSession, allocator: std.mem.Allocator, stream: []const u8, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        try self.output.append(allocator, .{
            .seq = self.next_seq,
            .stream = stream,
            .data = owned,
        });
        self.next_seq += 1;
        self.retained_bytes += owned.len;
        while (self.retained_bytes > retained_output_bytes_per_process and self.output.items.len > 0) {
            const removed = self.output.orderedRemove(0);
            self.retained_bytes -= removed.data.len;
            removed.deinit(allocator);
        }
    }

    fn markExited(self: *ProcessSession, exit_code: i32) void {
        if (self.exit_code == null) {
            self.exit_code = exit_code;
            self.next_seq += 1;
        }
    }

    fn markClosed(self: *ProcessSession) void {
        if (!self.closed) {
            self.closed = true;
            self.next_seq += 1;
            self.process_group_id = null;
        }
    }

    fn forceClosed(self: *ProcessSession, exit_code: i32) void {
        self.markExited(exit_code);
        self.markClosed();
    }
};

const DetachedExecSession = struct {
    session_id: []const u8,
    processes: std.ArrayList(ProcessSession) = .empty,

    fn deinit(self: *DetachedExecSession, allocator: std.mem.Allocator) void {
        for (self.processes.items) |*process| process.deinit(allocator);
        self.processes.deinit(allocator);
        allocator.free(self.session_id);
    }
};

const StdioServer = struct {
    allocator: std.mem.Allocator,
    initialize_complete: bool = false,
    initialized: bool = false,
    check_stdin_readiness: bool = true,
    detached_sessions: ?*std.ArrayList(DetachedExecSession) = null,
    session_id: ?[]const u8 = null,
    processes: std.ArrayList(ProcessSession) = .empty,

    fn deinit(self: *StdioServer) void {
        for (self.processes.items) |*process| process.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        if (self.session_id) |value| self.allocator.free(value);
    }

    fn detachSession(self: *StdioServer) !void {
        const detached_sessions = self.detached_sessions orelse return;
        const session_id = self.session_id orelse return;
        if (!self.initialize_complete) return;

        try detached_sessions.append(self.allocator, .{
            .session_id = session_id,
            .processes = self.processes,
        });
        self.session_id = null;
        self.processes = .empty;
        while (detached_sessions.items.len > max_detached_exec_sessions) {
            var removed = detached_sessions.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    fn run(self: *StdioServer) !void {
        var input_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);
        var line_data: std.Io.Writer.Allocating = .init(self.allocator);
        defer line_data.deinit();

        while (true) {
            if (stdin_reader.interface.seek == stdin_reader.interface.end) {
                switch (stdinReadinessWithTimeout(50)) {
                    .none => {
                        self.pollAllProcesses(0);
                        continue;
                    },
                    .readable, .closed => {},
                }
            }
            line_data.clearRetainingCapacity();
            switch (try readStdioJsonRpcLine(&stdin_reader.interface, &line_data)) {
                .eof => break,
                .too_long => {
                    const response = try renderJsonRpcError(self.allocator, null, -32600, "Request too large");
                    defer self.allocator.free(response);
                    try writeStdoutLine(response);
                    continue;
                },
                .line => {},
            }
            const line = line_data.written();
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            const buffered_input = stdin_reader.interface.buffer[stdin_reader.interface.seek..stdin_reader.interface.end];

            const response = self.handleLine(trimmed, buffered_input) catch |err| {
                if (err == error.ExecServerClientDisconnected) break;
                const message = try std.fmt.allocPrint(self.allocator, "[exec-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStdoutLine(payload);
            }
        }
    }

    fn handleLine(self: *StdioServer, line: []const u8, buffered_input: []const u8) !?[]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            return try renderJsonRpcError(self.allocator, null, -32700, "Parse error");
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return try renderJsonRpcError(self.allocator, null, -32600, "Invalid Request");
        }

        const object = parsed.value.object;
        const id_value = object.get("id");
        const method_value = object.get("method") orelse {
            if (object.get("result") != null or object.get("error") != null) return null;
            return try renderJsonRpcError(self.allocator, id_value, -32600, "Invalid Request");
        };
        if (method_value != .string) {
            return try renderJsonRpcError(self.allocator, id_value, -32600, "Invalid Request");
        }

        const method = method_value.string;
        if (id_value == null) {
            if (std.mem.eql(u8, method, "initialized")) {
                if (self.initialize_complete) self.initialized = true;
                return null;
            }
            return null;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            return try self.handleInitialize(id_value.?, object.get("params"));
        }
        if (std.mem.eql(u8, method, "process/start")) {
            return try self.handleProcessStart(id_value.?, object.get("params"));
        }
        if (std.mem.eql(u8, method, "process/read")) {
            return try self.handleProcessRead(id_value.?, object.get("params"), buffered_input);
        }
        if (std.mem.eql(u8, method, "process/write")) {
            return try self.handleProcessWrite(id_value.?, object.get("params"));
        }
        if (std.mem.eql(u8, method, "process/terminate")) {
            return try self.handleProcessTerminate(id_value.?, object.get("params"));
        }
        if (isFsMethod(method)) {
            return try self.handleFsMethod(id_value.?, method, object.get("params"));
        }

        const message = try std.fmt.allocPrint(self.allocator, "exec-server stub does not implement `{s}` yet", .{method});
        defer self.allocator.free(message);
        return try renderJsonRpcError(self.allocator, id_value, -32601, message);
    }

    fn handleInitialize(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (self.initialize_complete) {
            return try renderJsonRpcError(self.allocator, id_value, -32600, "initialize may only be sent once per connection");
        }
        const resume_session_id = parseInitializeParams(params_value) catch {
            return try renderJsonRpcError(self.allocator, id_value, -32602, "initialize params must include clientName");
        };
        if (resume_session_id) |session_id| {
            if (self.attachDetachedSession(session_id)) {
                self.initialize_complete = true;
                const result = try renderInitializeResult(self.allocator, self.session_id.?);
                defer self.allocator.free(result);
                return try renderJsonRpcResult(self.allocator, id_value, result);
            } else {
                const message = try std.fmt.allocPrint(self.allocator, "unknown session id {s}", .{session_id});
                defer self.allocator.free(message);
                return try renderJsonRpcError(self.allocator, id_value, -32600, message);
            }
        }

        self.session_id = try generateUuidString(self.allocator);
        self.initialize_complete = true;

        const result = try renderInitializeResult(self.allocator, self.session_id.?);
        defer self.allocator.free(result);
        return try renderJsonRpcResult(self.allocator, id_value, result);
    }

    fn attachDetachedSession(self: *StdioServer, session_id: []const u8) bool {
        const detached_sessions = self.detached_sessions orelse return false;
        for (detached_sessions.items, 0..) |detached, index| {
            if (!std.mem.eql(u8, detached.session_id, session_id)) continue;
            const resumed = detached_sessions.orderedRemove(index);
            self.session_id = resumed.session_id;
            self.processes = resumed.processes;
            return true;
        }
        return false;
    }

    fn handleProcessStart(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "initialized notification must be sent before process requests");

        const params = parseExecStartParams(self.allocator, params_value) catch |err| switch (err) {
            error.InvalidExecServerEnvPolicy => return renderJsonRpcError(self.allocator, id_value, -32602, "envPolicy must include inherit, ignoreDefaultExcludes, exclude, set, and includeOnly"),
            else => return renderJsonRpcError(self.allocator, id_value, -32602, "process/start params must include processId, argv, cwd, env, and tty"),
        };
        defer params.deinit(self.allocator);

        self.pollAllProcesses(0);
        self.evictExcessClosedProcesses();

        if (self.findProcessIndex(params.process_id) != null) {
            const message = try std.fmt.allocPrint(self.allocator, "process {s} already exists", .{params.process_id});
            defer self.allocator.free(message);
            return try renderJsonRpcError(self.allocator, id_value, -32600, message);
        }

        var child_env = execServerEnvironment(self.allocator, params.env, params.env_policy) catch |err| switch (err) {
            error.InvalidExecServerEnv => return renderJsonRpcError(self.allocator, id_value, -32602, "env must be an object"),
            error.InvalidExecServerEnvKey => return renderJsonRpcError(self.allocator, id_value, -32602, "env keys must be non-empty strings without NUL or '='"),
            error.InvalidExecServerEnvValue => return renderJsonRpcError(self.allocator, id_value, -32602, "env values must be strings without NUL"),
            else => return err,
        };
        defer child_env.deinit();

        var spawned = spawnExecServerProcess(self.allocator, params.argv, params.arg0, params.cwd, &child_env, params.pipe_stdin, params.tty) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "failed to start process {s}: {s}", .{
                params.process_id,
                switch (err) {
                    error.ExecServerExecutableNotFound => "FileNotFound",
                    else => @errorName(err),
                },
            });
            defer self.allocator.free(message);
            return renderJsonRpcError(self.allocator, id_value, -32603, message);
        };
        errdefer spawned.deinit(self.allocator);
        var child_owned = true;
        errdefer if (child_owned) spawned.child.kill(spawned.io_instance.io());

        const owned_process_id = try self.allocator.dupe(u8, params.process_id);
        errdefer self.allocator.free(owned_process_id);
        const stdin_file = spawned.child.stdin;
        const stdout_file = spawned.child.stdout;
        const stderr_file = spawned.child.stderr;
        spawned.child.stdin = null;
        spawned.child.stdout = null;
        spawned.child.stderr = null;
        errdefer if (child_owned) {
            const io = spawned.io_instance.io();
            if (stdin_file) |file| file.close(io);
            if (stdout_file) |file| file.close(io);
            if (stderr_file) |file| file.close(io);
        };

        try self.processes.append(self.allocator, .{
            .process_id = owned_process_id,
            .io_instance = spawned.io_instance,
            .child = spawned.child,
            .process_group_id = spawned.child.id,
            .path_lookup_env_block = spawned.path_lookup_env_block,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
            .tty = spawned.tty,
        });
        child_owned = false;
        spawned.path_lookup_env_block = null;

        const result = try renderProcessStartResult(self.allocator, params.process_id);
        defer self.allocator.free(result);
        return try renderJsonRpcResult(self.allocator, id_value, result);
    }

    fn handleProcessRead(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value, buffered_input: []const u8) ![]const u8 {
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "initialized notification must be sent before process requests");
        const params = parseProcessReadParams(params_value) catch {
            return renderJsonRpcError(self.allocator, id_value, -32602, "process/read params must include processId");
        };
        const process_index = self.findProcessIndex(params.process_id) orelse {
            const message = try std.fmt.allocPrint(self.allocator, "unknown process id {s}", .{params.process_id});
            defer self.allocator.free(message);
            return try renderJsonRpcError(self.allocator, id_value, -32600, message);
        };
        const process = &self.processes.items[process_index];

        const buffered_input_pending = buffered_input.len != 0;
        const interrupt_for_buffered_input = bufferedInputInterruptsProcessRead(self.allocator, buffered_input, params.process_id);
        switch (try waitForProcessRead(self.allocator, process, params.after_seq, params.wait_ms, interrupt_for_buffered_input, buffered_input_pending, self.check_stdin_readiness and !buffered_input_pending)) {
            .ready => {},
            .client_disconnected => return error.ExecServerClientDisconnected,
        }
        try drainAvailableProcessOutputForRead(self.allocator, process, params.after_seq, params.max_bytes);
        const result = try renderProcessReadResult(self.allocator, process, params.after_seq, params.max_bytes);
        defer self.allocator.free(result);
        self.evictExcessClosedProcesses();
        return try renderJsonRpcResult(self.allocator, id_value, result);
    }

    fn handleProcessWrite(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "initialized notification must be sent before process requests");
        const params = parseProcessWriteParams(self.allocator, params_value) catch |err| switch (err) {
            error.InvalidExecServerBase64 => return renderJsonRpcError(self.allocator, id_value, -32602, "process/write chunk must be valid base64"),
            else => return renderJsonRpcError(self.allocator, id_value, -32602, "process/write params must include processId and chunk"),
        };
        defer params.deinit(self.allocator);

        const process = self.findProcess(params.process_id) orelse {
            return try renderJsonRpcResult(self.allocator, id_value, "{\"status\":\"unknownProcess\"}");
        };
        process.reapStdinWriteTask(self.allocator);
        try pollProcess(self.allocator, process, 1);
        if (process.closed or process.stdin_file == null) {
            const response = try renderJsonRpcResult(self.allocator, id_value, "{\"status\":\"stdinClosed\"}");
            self.evictExcessClosedProcesses();
            return response;
        }
        enqueueStdinWrite(self.allocator, process, params.chunk) catch |err| switch (err) {
            error.ExecServerStdinQueueFull => return try renderJsonRpcError(self.allocator, id_value, -32603, "process stdin write queue is full"),
            else => return try renderJsonRpcError(self.allocator, id_value, -32603, "failed to write to process stdin"),
        };
        return try renderJsonRpcResult(self.allocator, id_value, "{\"status\":\"accepted\"}");
    }

    fn handleProcessTerminate(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "initialized notification must be sent before process requests");
        const process_id = parseProcessIdParam(params_value) catch {
            return renderJsonRpcError(self.allocator, id_value, -32602, "process/terminate params must include processId");
        };
        const process = self.findProcess(process_id) orelse {
            return try renderJsonRpcResult(self.allocator, id_value, "{\"running\":false}");
        };
        try pollProcess(self.allocator, process, 1);
        if (process.closed or process.process_group_id == null) {
            return try renderJsonRpcResult(self.allocator, id_value, "{\"running\":false}");
        }
        try terminateProcess(self.allocator, process);
        self.evictExcessClosedProcesses();
        return try renderJsonRpcResult(self.allocator, id_value, "{\"running\":true}");
    }

    fn handleFsMethod(self: *StdioServer, id_value: std.json.Value, method: []const u8, params_value: ?std.json.Value) ![]const u8 {
        if (!self.initialize_complete) return try renderJsonRpcError(self.allocator, id_value, -32600, "client must call initialize before using filesystem methods");
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "client must send initialized before using filesystem methods");
        if (std.mem.eql(u8, method, "fs/readFile")) return handleFsReadFile(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/writeFile")) return handleFsWriteFile(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/createDirectory")) return handleFsCreateDirectory(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/getMetadata")) return handleFsGetMetadata(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/readDirectory")) return handleFsReadDirectory(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/remove")) return handleFsRemove(self.allocator, id_value, params_value);
        if (std.mem.eql(u8, method, "fs/copy")) return handleFsCopy(self.allocator, id_value, params_value);
        return try renderJsonRpcError(self.allocator, id_value, -32601, "unknown filesystem method");
    }

    fn findProcess(self: *StdioServer, process_id: []const u8) ?*ProcessSession {
        const index = self.findProcessIndex(process_id) orelse return null;
        return &self.processes.items[index];
    }

    fn findProcessIndex(self: *const StdioServer, process_id: []const u8) ?usize {
        for (self.processes.items, 0..) |process, index| {
            if (std.mem.eql(u8, process.process_id, process_id)) return index;
        }
        return null;
    }

    fn removeProcessAt(self: *StdioServer, index: usize) void {
        var process = self.processes.orderedRemove(index);
        process.deinit(self.allocator);
    }

    fn evictExcessClosedProcesses(self: *StdioServer) void {
        var closed_count: usize = 0;
        for (self.processes.items) |process| {
            if (process.closed) closed_count += 1;
        }
        var index: usize = 0;
        while (closed_count > retained_closed_processes and index < self.processes.items.len) {
            if (self.processes.items[index].closed) {
                self.removeProcessAt(index);
                closed_count -= 1;
            } else {
                index += 1;
            }
        }
    }

    fn pollAllProcesses(self: *StdioServer, timeout_ms: u64) void {
        for (self.processes.items) |*process| {
            pollProcess(self.allocator, process, timeout_ms) catch {};
        }
    }
};

const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    address: WebSocketListen,
    detached_sessions: std.ArrayList(DetachedExecSession) = .empty,

    fn deinit(self: *WebSocketServer) void {
        for (self.detached_sessions.items) |*session| session.deinit(self.allocator);
        self.detached_sessions.deinit(self.allocator);
    }

    fn run(self: *WebSocketServer) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var address = net.IpAddress.parse(self.address.host, self.address.port) catch return error.InvalidExecServerWebSocketListenUrl;
        var server = try address.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);

        const actual_port = server.socket.address.getPort();
        const bind_message = try std.fmt.allocPrint(self.allocator, "exec-server websocket listening on ws://{s}:{d}\n", .{ self.address.host, actual_port });
        defer self.allocator.free(bind_message);
        try cli_utils.writeStderr(bind_message);

        while (true) {
            self.pollDetachedSessions();
            if (!try listenerReadyForAccept(server.socket.handle, detached_exec_session_poll_interval_ms)) {
                continue;
            }
            var stream = try server.accept(io);
            self.handleConnection(io, &stream) catch |err| {
                const message = std.fmt.allocPrint(
                    self.allocator,
                    "[exec-server] websocket connection error: {s}\n",
                    .{@errorName(err)},
                ) catch null;
                if (message) |stderr_message| {
                    defer self.allocator.free(stderr_message);
                    cli_utils.writeStderr(stderr_message) catch {};
                }
                stream.close(io);
                continue;
            };
            stream.close(io);
        }
    }

    fn pollDetachedSessions(self: *WebSocketServer) void {
        for (self.detached_sessions.items) |*session| {
            for (session.processes.items) |*process| {
                pollProcess(self.allocator, process, 0) catch {};
                drainAvailableProcessOutputForRead(self.allocator, process, 0, null) catch {};
            }
        }
    }

    fn handleConnection(
        self: *WebSocketServer,
        io: std.Io,
        stream: *net.Stream,
    ) !void {
        var input_buffer: [64 * 1024]u8 = undefined;
        var output_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &input_buffer);
        var writer = stream.writer(io, &output_buffer);
        var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        if (websocketHeaderValue(&request, "origin") != null) {
            try request.respond("Forbidden\n", .{ .status = .forbidden });
            return;
        }

        if (std.mem.eql(u8, request.head.target, "/readyz") or std.mem.eql(u8, request.head.target, "/healthz")) {
            try request.respond("OK\n", .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                    .{ .name = "Connection", .value = "close" },
                },
            });
            return;
        }

        if (request.head.method != .GET) {
            try request.respond("Not Found\n", .{ .status = .not_found });
            return;
        }

        const websocket_key = websocketHeaderValue(&request, "sec-websocket-key") orelse {
            try request.respond("Bad Request\n", .{ .status = .bad_request });
            return;
        };
        if (!websocketHeaderEquals(&request, "upgrade", "websocket") or
            !websocketConnectionIncludesUpgrade(&request) or
            !websocketHeaderEquals(&request, "sec-websocket-version", "13"))
        {
            try request.respond("Bad Request\n", .{ .status = .bad_request });
            return;
        }
        const accept = try websocketAcceptValue(self.allocator, websocket_key);
        defer self.allocator.free(accept);

        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();

        var connection = StdioServer{
            .allocator = self.allocator,
            .check_stdin_readiness = false,
            .detached_sessions = &self.detached_sessions,
        };
        // Defers run in reverse: detach before deinit so live processes can resume.
        defer connection.deinit();
        defer connection.detachSession() catch |err| {
            const message = std.fmt.allocPrint(
                self.allocator,
                "[exec-server] failed to detach websocket session: {s}\n",
                .{@errorName(err)},
            ) catch null;
            if (message) |stderr_message| {
                defer self.allocator.free(stderr_message);
                cli_utils.writeStderr(stderr_message) catch {};
            }
        };

        while (true) {
            const payload = try readWebSocketTextFrame(self.allocator, &reader.interface, &writer.interface) orelse return;
            defer self.allocator.free(payload);
            const trimmed = std.mem.trim(u8, payload, " \t\r\n");
            if (trimmed.len == 0) continue;

            const response = connection.handleLine(trimmed, "") catch |err| {
                if (err == error.ExecServerClientDisconnected) return;
                const message = try std.fmt.allocPrint(self.allocator, "[exec-server] failed to handle websocket message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload_response| {
                defer self.allocator.free(payload_response);
                try writeWebSocketTextFrame(&writer.interface, payload_response);
            }
        }
    }
};

fn listenerReadyForAccept(fd: std.posix.fd_t, timeout_ms: u64) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL),
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, @intCast(timeout_ms));
    return ready != 0;
}

fn websocketHeaderValue(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return std.mem.trim(u8, header.value, " \t\r\n");
    }
    return null;
}

fn websocketHeaderEquals(request: *const std.http.Server.Request, name: []const u8, expected: []const u8) bool {
    const value = websocketHeaderValue(request, name) orelse return false;
    return std.ascii.eqlIgnoreCase(value, expected);
}

fn websocketConnectionIncludesUpgrade(request: *const std.http.Server.Request) bool {
    const value = websocketHeaderValue(request, "connection") orelse return false;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const token = std.mem.trim(u8, part, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(token, "upgrade")) return true;
    }
    return false;
}

fn websocketAcceptValue(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, magic });
    defer allocator.free(combined);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});
    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, &digest);
    return encoded;
}

fn readWebSocketTextFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !?[]const u8 {
    while (true) {
        const first = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const second = try reader.takeByte();
        const fin = (first & 0x80) != 0;
        const opcode = first & 0x0f;
        const masked = (second & 0x80) != 0;
        var payload_len: u64 = second & 0x7f;
        if (payload_len == 126) {
            payload_len = try reader.takeInt(u16, .big);
        } else if (payload_len == 127) {
            payload_len = try reader.takeInt(u64, .big);
        }
        if (!fin) return error.UnsupportedWebSocketFragment;
        if (!masked) return error.UnmaskedWebSocketClientFrame;
        if (payload_len > max_stdio_json_rpc_line_bytes) return error.WebSocketFrameTooLarge;

        const mask = try reader.takeArray(4);
        const payload = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(payload);
        try reader.readSliceAll(payload);
        for (payload, 0..) |*byte, index| {
            byte.* ^= mask[index % 4];
        }

        switch (opcode) {
            0x1 => return payload,
            0x8 => {
                try writeWebSocketFrame(writer, 0x8, payload);
                allocator.free(payload);
                return null;
            },
            0x9 => {
                try writeWebSocketFrame(writer, 0xA, payload);
                allocator.free(payload);
                continue;
            },
            0xA => {
                allocator.free(payload);
                continue;
            },
            else => {
                allocator.free(payload);
                return error.UnsupportedWebSocketOpcode;
            },
        }
    }
}

fn writeWebSocketTextFrame(writer: *std.Io.Writer, payload: []const u8) !void {
    try writeWebSocketFrame(writer, 0x1, payload);
}

fn writeWebSocketFrame(writer: *std.Io.Writer, opcode: u8, payload: []const u8) !void {
    try writer.writeByte(0x80 | (opcode & 0x0f));
    if (payload.len <= 125) {
        try writer.writeByte(@intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(127);
        try writer.writeInt(u64, @intCast(payload.len), .big);
    }
    try writer.writeAll(payload);
    try writer.flush();
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const parsed = parseArgs(args) catch |err| switch (err) {
        error.MissingExecServerListenUrl => return fail(allocator, "error: --listen requires a URL\n", .{}),
        error.MissingExecServerRemoteUrl => return fail(allocator, "error: --remote requires a URL\n", .{}),
        error.MissingExecServerExecutorIdOption => return fail(allocator, "error: --executor-id requires an ID\n", .{}),
        error.MissingExecServerNameOption => return fail(allocator, "error: --name requires a value\n", .{}),
        error.ConflictingExecServerOptions => return fail(allocator, "error: --listen cannot be combined with --remote\n", .{}),
        error.MissingExecServerExecutorId => return fail(allocator, "error: --executor-id is required when --remote is set\n", .{}),
        error.UnknownExecServerOption => return fail(allocator, "error: unknown exec-server option\n", .{}),
        error.UnexpectedExecServerArgument => return fail(allocator, "error: unexpected exec-server argument\n", .{}),
    };

    if (parsed.help) {
        printHelp();
        return;
    }

    if (parsed.remote != null) {
        return fail(allocator, "codex-zig exec-server remote registration is parsed but not implemented yet\n", .{});
    }

    const listen_url = parsed.listen orelse default_listen_url;
    const transport = parseListenUrl(listen_url) catch |err| switch (err) {
        error.UnsupportedExecServerListenUrl => return fail(
            allocator,
            "unsupported --listen URL `{s}`; expected `ws://IP:PORT` or `stdio`\n",
            .{listen_url},
        ),
        error.InvalidExecServerWebSocketListenUrl => return fail(
            allocator,
            "invalid websocket --listen URL `{s}`; expected `ws://IP:PORT`\n",
            .{listen_url},
        ),
    };

    switch (transport) {
        .stdio => {
            var server = StdioServer{ .allocator = allocator };
            defer server.deinit();
            try server.run();
        },
        .websocket => |address| {
            var server = WebSocketServer{ .allocator = allocator, .address = address };
            defer server.deinit();
            try server.run();
        },
    }
}

fn parseArgs(args: *std.process.Args.Iterator) !ParsedOptions {
    var parsed = ParsedOptions{};

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--listen")) {
            parsed.listen = args.next() orelse return error.MissingExecServerListenUrl;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            parsed.listen = arg["--listen=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            parsed.remote = args.next() orelse return error.MissingExecServerRemoteUrl;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            parsed.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--executor-id")) {
            parsed.executor_id = args.next() orelse return error.MissingExecServerExecutorIdOption;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--executor-id=")) {
            parsed.executor_id = arg["--executor-id=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            parsed.name = args.next() orelse return error.MissingExecServerNameOption;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            parsed.name = arg["--name=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownExecServerOption;
        return error.UnexpectedExecServerArgument;
    }

    if (parsed.listen != null and parsed.remote != null) return error.ConflictingExecServerOptions;
    if (parsed.remote != null and parsed.executor_id == null) return error.MissingExecServerExecutorId;
    return parsed;
}

fn parseListenUrl(value: []const u8) !Transport {
    if (std.mem.eql(u8, value, "stdio") or std.mem.eql(u8, value, "stdio://")) return .stdio;

    if (std.mem.startsWith(u8, value, "ws://")) {
        const address = value["ws://".len..];
        const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidExecServerWebSocketListenUrl;
        const host = address[0..colon];
        const port_text = address[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.InvalidExecServerWebSocketListenUrl;
        const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidExecServerWebSocketListenUrl;
        _ = net.IpAddress.parse(host, port) catch return error.InvalidExecServerWebSocketListenUrl;
        return .{ .websocket = .{ .host = host, .port = port } };
    }

    return error.UnsupportedExecServerListenUrl;
}

fn parseInitializeParams(params_value: ?std.json.Value) !?[]const u8 {
    const params = params_value orelse return error.InvalidExecServerInitializeParams;
    if (params != .object) return error.InvalidExecServerInitializeParams;
    const client_name = params.object.get("clientName") orelse return error.InvalidExecServerInitializeParams;
    if (client_name != .string) return error.InvalidExecServerInitializeParams;
    if (params.object.get("resumeSessionId")) |resume_value| {
        if (resume_value == .null) return null;
        if (resume_value != .string) return error.InvalidExecServerInitializeParams;
        return resume_value.string;
    }
    return null;
}

const StdioJsonRpcLineStatus = enum {
    line,
    eof,
    too_long,
};

fn readStdioJsonRpcLine(reader: *std.Io.Reader, line_data: *std.Io.Writer.Allocating) !StdioJsonRpcLineStatus {
    const line_len = reader.streamDelimiterLimit(&line_data.writer, '\n', .limited(max_stdio_json_rpc_line_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.EndOfStream => return .too_long,
                else => |e| return e,
            };
            return .too_long;
        },
        else => |e| return e,
    };

    const ended = blk: {
        _ = reader.peek(1) catch |err| switch (err) {
            error.EndOfStream => break :blk true,
            error.ReadFailed => return error.ReadFailed,
        };
        reader.toss(1);
        break :blk false;
    };
    if (ended and line_len == 0) return .eof;
    return .line;
}

fn parseExecStartParams(allocator: std.mem.Allocator, params_value: ?std.json.Value) !ExecStartParams {
    const params = params_value orelse return error.InvalidExecServerStartParams;
    if (params != .object) return error.InvalidExecServerStartParams;
    const object = params.object;

    const process_id = try requiredStringField(object, "processId");
    if (process_id.len == 0) return error.InvalidExecServerStartParams;

    const argv_value = object.get("argv") orelse return error.InvalidExecServerStartParams;
    if (argv_value != .array or argv_value.array.items.len == 0) return error.InvalidExecServerStartParams;
    const argv = try allocator.alloc([]const u8, argv_value.array.items.len);
    errdefer allocator.free(argv);
    for (argv_value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidExecServerStartParams;
        if (std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidExecServerStartParams;
        argv[index] = item.string;
    }

    const cwd = try requiredStringField(object, "cwd");
    if (cwd.len == 0) return error.InvalidExecServerStartParams;
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidExecServerStartParams;
    const env = object.get("env") orelse return error.InvalidExecServerStartParams;
    const tty = try requiredBoolField(object, "tty");
    const env_policy = try parseExecEnvPolicy(allocator, object.get("envPolicy"));
    errdefer if (env_policy) |policy| policy.deinit(allocator);

    if (object.get("arg0")) |arg0| {
        if (arg0 != .null and arg0 != .string) return error.InvalidExecServerStartParams;
        if (arg0 == .string and std.mem.indexOfScalar(u8, arg0.string, 0) != null) return error.InvalidExecServerStartParams;
    }

    return .{
        .process_id = process_id,
        .argv = argv,
        .cwd = cwd,
        .env = env,
        .env_policy = env_policy,
        .tty = tty,
        .pipe_stdin = try optionalBoolField(object, "pipeStdin", false),
        .arg0 = if (object.get("arg0")) |arg0| switch (arg0) {
            .string => |string| string,
            else => null,
        } else null,
    };
}

fn parseExecEnvPolicy(allocator: std.mem.Allocator, value: ?std.json.Value) !?ExecEnvPolicy {
    const policy_value = value orelse return null;
    if (policy_value == .null) return null;
    if (policy_value != .object) return error.InvalidExecServerEnvPolicy;
    const object = policy_value.object;

    const inherit_value = object.get("inherit") orelse return error.InvalidExecServerEnvPolicy;
    if (inherit_value != .string) return error.InvalidExecServerEnvPolicy;
    const inherit: ExecEnvPolicyInherit = if (std.mem.eql(u8, inherit_value.string, "all"))
        .all
    else if (std.mem.eql(u8, inherit_value.string, "core"))
        .core
    else if (std.mem.eql(u8, inherit_value.string, "none"))
        .none
    else
        return error.InvalidExecServerEnvPolicy;

    const ignore_default_excludes_value = object.get("ignoreDefaultExcludes") orelse return error.InvalidExecServerEnvPolicy;
    if (ignore_default_excludes_value != .bool) return error.InvalidExecServerEnvPolicy;

    const exclude = try parseExecEnvPatternList(allocator, object.get("exclude") orelse return error.InvalidExecServerEnvPolicy);
    errdefer allocator.free(exclude);
    const include_only = try parseExecEnvPatternList(allocator, object.get("includeOnly") orelse return error.InvalidExecServerEnvPolicy);
    errdefer allocator.free(include_only);

    const set = object.get("set") orelse return error.InvalidExecServerEnvPolicy;
    if (set != .object) return error.InvalidExecServerEnvPolicy;

    return .{
        .inherit = inherit,
        .ignore_default_excludes = ignore_default_excludes_value.bool,
        .exclude = exclude,
        .set = set,
        .include_only = include_only,
    };
}

fn parseExecEnvPatternList(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return error.InvalidExecServerEnvPolicy;
    const patterns = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(patterns);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidExecServerEnvPolicy;
        if (std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidExecServerEnvPolicy;
        patterns[index] = item.string;
    }
    return patterns;
}

const ProcessReadParams = struct {
    process_id: []const u8,
    after_seq: u64,
    max_bytes: ?usize,
    wait_ms: u64,
};

fn parseProcessReadParams(params_value: ?std.json.Value) !ProcessReadParams {
    const params = params_value orelse return error.InvalidExecServerReadParams;
    if (params != .object) return error.InvalidExecServerReadParams;
    const object = params.object;
    return .{
        .process_id = try requiredStringField(object, "processId"),
        .after_seq = try optionalU64Field(object, "afterSeq", 0),
        .max_bytes = try optionalUsizeField(object, "maxBytes"),
        .wait_ms = try optionalU64Field(object, "waitMs", 0),
    };
}

const ProcessWriteParams = struct {
    process_id: []const u8,
    chunk: []const u8,

    fn deinit(self: ProcessWriteParams, allocator: std.mem.Allocator) void {
        allocator.free(self.chunk);
    }
};

fn parseProcessWriteParams(allocator: std.mem.Allocator, params_value: ?std.json.Value) !ProcessWriteParams {
    const params = params_value orelse return error.InvalidExecServerWriteParams;
    if (params != .object) return error.InvalidExecServerWriteParams;
    const object = params.object;
    const process_id = try requiredStringField(object, "processId");
    const chunk_base64 = try requiredStringField(object, "chunk");
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(chunk_base64) catch return error.InvalidExecServerBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, chunk_base64) catch return error.InvalidExecServerBase64;
    return .{ .process_id = process_id, .chunk = decoded };
}

const FsObjectParams = union(enum) {
    object: std.json.ObjectMap,
    message: []const u8,
};

const FsStringField = union(enum) {
    value: []const u8,
    message: []const u8,
};

const FsBoolField = union(enum) {
    value: bool,
    message: []const u8,
};

const ResolvedExecArgv = struct {
    argv: []const []const u8,
    path_lookup_env_block: ?std.process.Environ.Block = null,

    fn deinit(self: ResolvedExecArgv, allocator: std.mem.Allocator) void {
        if (self.path_lookup_env_block) |block| block.deinit(allocator);
        allocator.free(self.argv);
    }
};

const SpawnedExecProcess = struct {
    io_instance: std.Io.Threaded,
    child: std.process.Child,
    path_lookup_env_block: ?std.process.Environ.Block = null,
    tty: bool = false,

    fn deinit(self: *SpawnedExecProcess, allocator: std.mem.Allocator) void {
        self.child.kill(self.io_instance.io());
        self.io_instance.deinit();
        if (self.path_lookup_env_block) |block| block.deinit(allocator);
    }
};

fn spawnExecServerProcess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    arg0: ?[]const u8,
    cwd: []const u8,
    child_env: *const std.process.Environ.Map,
    pipe_stdin: bool,
    tty: bool,
) !SpawnedExecProcess {
    if (tty) return try spawnExecServerTtyProcess(allocator, argv, arg0, cwd, child_env);

    if (arg0) |custom_arg0| {
        if (builtin.os.tag == .windows) return try spawnExecServerProcessDefault(allocator, argv, cwd, child_env, pipe_stdin);
        const executable_path = try resolveExecProgramPath(allocator, argv[0], cwd, child_env);
        defer allocator.free(executable_path);
        const child_argv = try execArgvWithArg0(allocator, argv, custom_arg0);
        defer allocator.free(child_argv);

        var io_instance: std.Io.Threaded = .init(allocator, .{});
        errdefer io_instance.deinit();
        const child = try spawnUnixArg0Process(allocator, executable_path, child_argv, cwd, child_env, pipe_stdin);
        return .{ .io_instance = io_instance, .child = child };
    }

    return try spawnExecServerProcessDefault(allocator, argv, cwd, child_env, pipe_stdin);
}

fn spawnExecServerProcessDefault(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    child_env: *const std.process.Environ.Map,
    pipe_stdin: bool,
) !SpawnedExecProcess {
    var resolved_argv = try resolveExecArgv(allocator, argv, cwd, child_env);
    errdefer resolved_argv.deinit(allocator);

    var io_instance: std.Io.Threaded = .init(allocator, .{
        .environ = .{ .block = resolved_argv.path_lookup_env_block orelse .empty },
    });
    errdefer io_instance.deinit();
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = resolved_argv.argv,
        .cwd = .{ .path = cwd },
        .environ_map = child_env,
        .stdin = if (pipe_stdin) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    errdefer child.kill(io_instance.io());

    const path_lookup_env_block = resolved_argv.path_lookup_env_block;
    resolved_argv.path_lookup_env_block = null;
    resolved_argv.deinit(allocator);
    return .{
        .io_instance = io_instance,
        .child = child,
        .path_lookup_env_block = path_lookup_env_block,
    };
}

fn spawnExecServerTtyProcess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    arg0: ?[]const u8,
    cwd: []const u8,
    child_env: *const std.process.Environ.Map,
) !SpawnedExecProcess {
    if (builtin.os.tag != .macos) return error.ExecServerTtyUnsupported;

    const executable_path = try resolveExecProgramPath(allocator, argv[0], cwd, child_env);
    defer allocator.free(executable_path);

    var owned_child_argv: ?[]const []const u8 = null;
    defer if (owned_child_argv) |value| allocator.free(value);
    const child_argv = if (arg0) |custom_arg0| blk: {
        owned_child_argv = try execArgvWithArg0(allocator, argv, custom_arg0);
        break :blk owned_child_argv.?;
    } else argv;

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    errdefer io_instance.deinit();
    const child = try spawnUnixPtyProcess(allocator, executable_path, child_argv, cwd, child_env);
    return .{ .io_instance = io_instance, .child = child, .tty = true };
}

fn execArgvWithArg0(allocator: std.mem.Allocator, argv: []const []const u8, arg0: []const u8) ![]const []const u8 {
    const child_argv = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(child_argv);
    child_argv[0] = arg0;
    if (argv.len > 1) @memcpy(child_argv[1..], argv[1..]);
    return child_argv;
}

fn resolveExecProgramPath(
    allocator: std.mem.Allocator,
    argv0: []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return try allocator.dupe(u8, argv0);
    const path = env.get("PATH") orelse defaultExecPath();
    return (try resolveExecutableOnPath(allocator, argv0, cwd, path)) orelse error.ExecServerExecutableNotFound;
}

fn spawnUnixPtyProcess(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    child_env: *const std.process.Environ.Map,
) !std.process.Child {
    if (builtin.os.tag != .macos) return error.ExecServerTtyUnsupported;

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const executable_z = try arena.dupeZ(u8, executable_path);
    const cwd_z = try arena.dupeZ(u8, cwd);
    const argv_buf = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, index| {
        argv_buf[index] = (try arena.dupeZ(u8, arg)).ptr;
    }
    const env_block = try child_env.createPosixBlock(arena, .{ .zig_progress_fd = null });

    const pty_pair = try openExecServerPtyPair();
    var master_open = true;
    var slave_open = true;
    errdefer {
        if (master_open) closeFd(pty_pair.master);
        if (slave_open) closeFd(pty_pair.slave);
    }

    const master_write_fd = try duplicateFd(pty_pair.master);
    var master_write_open = true;
    errdefer if (master_write_open) closeFd(master_write_fd);

    const err_pipe = try makeUnixPipe();
    var err_read_open = true;
    var err_write_open = true;
    errdefer {
        if (err_read_open) closeFd(err_pipe[0]);
        if (err_write_open) closeFd(err_pipe[1]);
    }
    try setFdCloseOnExec(err_pipe[1]);

    const pid_result = std.posix.system.fork();
    switch (std.c.errno(pid_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        .NOSYS => return error.OperationUnsupported,
        else => return error.Unexpected,
    }

    if (pid_result == 0) {
        closeFd(err_pipe[0]);
        closeFd(pty_pair.master);
        closeFd(master_write_fd);

        switch (std.c.errno(std.c.setsid())) {
            .SUCCESS => {},
            else => |err| childExitWithErrno(err_pipe[1], err),
        }
        childDup2OrExit(pty_pair.slave, std.posix.STDIN_FILENO, err_pipe[1]);
        childDup2OrExit(pty_pair.slave, std.posix.STDOUT_FILENO, err_pipe[1]);
        childDup2OrExit(pty_pair.slave, std.posix.STDERR_FILENO, err_pipe[1]);
        closeFd(pty_pair.slave);

        switch (std.c.errno(std.c.chdir(cwd_z.ptr))) {
            .SUCCESS => {},
            else => |err| childExitWithErrno(err_pipe[1], err),
        }
        _ = std.c.execve(executable_z.ptr, argv_buf.ptr, env_block.slice.ptr);
        childExitWithErrno(err_pipe[1], std.c.errno(-1));
    }

    const pid: std.posix.pid_t = @intCast(pid_result);
    closeFd(pty_pair.slave);
    slave_open = false;
    closeFd(err_pipe[1]);
    err_write_open = false;

    if (readSpawnErrno(err_pipe[0])) |err| {
        closeFd(err_pipe[0]);
        err_read_open = false;
        closeFd(pty_pair.master);
        master_open = false;
        closeFd(master_write_fd);
        master_write_open = false;
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        return spawnErrorFromErrno(err);
    }
    closeFd(err_pipe[0]);
    err_read_open = false;

    const stdin_file: std.Io.File = .{ .handle = master_write_fd, .flags = .{ .nonblocking = false } };
    master_write_open = false;
    const stdout_file: std.Io.File = .{ .handle = pty_pair.master, .flags = .{ .nonblocking = false } };
    master_open = false;

    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = stdin_file,
        .stdout = stdout_file,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

const ExecServerPtyPair = struct {
    master: std.c.fd_t,
    slave: std.c.fd_t,
};

fn openExecServerPtyPair() !ExecServerPtyPair {
    if (builtin.os.tag != .macos) return error.ExecServerTtyUnsupported;

    var window_size: std.posix.winsize = .{
        .row = default_exec_tty_rows,
        .col = default_exec_tty_cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    if (openpty(&master_fd, &slave_fd, null, null, &window_size) != 0) return error.ExecServerOpenPtyFailed;
    return .{
        .master = @intCast(master_fd),
        .slave = @intCast(slave_fd),
    };
}

fn spawnUnixArg0Process(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    child_env: *const std.process.Environ.Map,
    pipe_stdin: bool,
) !std.process.Child {
    if (builtin.os.tag == .windows) return error.ExecServerArg0Unsupported;

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const executable_z = try arena.dupeZ(u8, executable_path);
    const cwd_z = try arena.dupeZ(u8, cwd);
    const argv_buf = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, index| {
        argv_buf[index] = (try arena.dupeZ(u8, arg)).ptr;
    }
    const env_block = try child_env.createPosixBlock(arena, .{ .zig_progress_fd = null });

    const stdin_pipe: [2]std.c.fd_t = if (pipe_stdin) try makeUnixPipe() else .{ -1, -1 };
    var stdin_read_open = pipe_stdin;
    var stdin_write_open = pipe_stdin;
    errdefer {
        if (stdin_read_open) closeFd(stdin_pipe[0]);
        if (stdin_write_open) closeFd(stdin_pipe[1]);
    }

    const dev_null_file: ?std.Io.File = if (pipe_stdin)
        null
    else
        try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), "/dev/null", .{});
    var dev_null_open = dev_null_file != null;
    errdefer if (dev_null_open) closeFd(dev_null_file.?.handle);

    const stdout_pipe = try makeUnixPipe();
    var stdout_read_open = true;
    var stdout_write_open = true;
    errdefer {
        if (stdout_read_open) closeFd(stdout_pipe[0]);
        if (stdout_write_open) closeFd(stdout_pipe[1]);
    }

    const stderr_pipe = try makeUnixPipe();
    var stderr_read_open = true;
    var stderr_write_open = true;
    errdefer {
        if (stderr_read_open) closeFd(stderr_pipe[0]);
        if (stderr_write_open) closeFd(stderr_pipe[1]);
    }

    const err_pipe = try makeUnixPipe();
    var err_read_open = true;
    var err_write_open = true;
    errdefer {
        if (err_read_open) closeFd(err_pipe[0]);
        if (err_write_open) closeFd(err_pipe[1]);
    }
    try setFdCloseOnExec(err_pipe[1]);

    const pid_result = std.posix.system.fork();
    switch (std.c.errno(pid_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        .NOSYS => return error.OperationUnsupported,
        else => return error.Unexpected,
    }

    if (pid_result == 0) {
        closeFd(err_pipe[0]);
        if (pipe_stdin) closeFd(stdin_pipe[1]);
        closeFd(stdout_pipe[0]);
        closeFd(stderr_pipe[0]);

        const child_stdin_fd = if (pipe_stdin) stdin_pipe[0] else dev_null_file.?.handle;
        childDup2OrExit(child_stdin_fd, std.posix.STDIN_FILENO, err_pipe[1]);
        childDup2OrExit(stdout_pipe[1], std.posix.STDOUT_FILENO, err_pipe[1]);
        childDup2OrExit(stderr_pipe[1], std.posix.STDERR_FILENO, err_pipe[1]);
        closeFd(child_stdin_fd);
        closeFd(stdout_pipe[1]);
        closeFd(stderr_pipe[1]);

        switch (std.c.errno(std.c.chdir(cwd_z.ptr))) {
            .SUCCESS => {},
            else => |err| childExitWithErrno(err_pipe[1], err),
        }
        switch (std.c.errno(std.c.setpgid(0, 0))) {
            .SUCCESS => {},
            else => |err| childExitWithErrno(err_pipe[1], err),
        }
        _ = std.c.execve(executable_z.ptr, argv_buf.ptr, env_block.slice.ptr);
        childExitWithErrno(err_pipe[1], std.c.errno(-1));
    }

    const pid: std.posix.pid_t = @intCast(pid_result);
    if (pipe_stdin) {
        closeFd(stdin_pipe[0]);
        stdin_read_open = false;
    } else {
        closeFd(dev_null_file.?.handle);
        dev_null_open = false;
    }
    closeFd(stdout_pipe[1]);
    stdout_write_open = false;
    closeFd(stderr_pipe[1]);
    stderr_write_open = false;
    closeFd(err_pipe[1]);
    err_write_open = false;

    if (readSpawnErrno(err_pipe[0])) |err| {
        closeFd(err_pipe[0]);
        err_read_open = false;
        if (pipe_stdin) {
            closeFd(stdin_pipe[1]);
            stdin_write_open = false;
        }
        closeFd(stdout_pipe[0]);
        stdout_read_open = false;
        closeFd(stderr_pipe[0]);
        stderr_read_open = false;
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        return spawnErrorFromErrno(err);
    }
    closeFd(err_pipe[0]);
    err_read_open = false;

    const stdin_file: ?std.Io.File = if (pipe_stdin) .{ .handle = stdin_pipe[1], .flags = .{ .nonblocking = false } } else null;
    if (pipe_stdin) stdin_write_open = false;
    const stdout_file: std.Io.File = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } };
    stdout_read_open = false;
    const stderr_file: std.Io.File = .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } };
    stderr_read_open = false;

    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = stdin_file,
        .stdout = stdout_file,
        .stderr = stderr_file,
        .request_resource_usage_statistics = false,
    };
}

fn makeUnixPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    while (true) {
        switch (std.c.errno(std.c.pipe(&fds))) {
            .SUCCESS => return fds,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn setFdCloseOnExec(fd: std.c.fd_t) !void {
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn duplicateFd(fd: std.c.fd_t) !std.c.fd_t {
    while (true) {
        const duplicated = std.c.dup(fd);
        switch (std.c.errno(duplicated)) {
            .SUCCESS => return @intCast(duplicated),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

fn childDup2OrExit(old_fd: std.c.fd_t, new_fd: std.c.fd_t, err_fd: std.c.fd_t) void {
    switch (std.c.errno(std.c.dup2(old_fd, new_fd))) {
        .SUCCESS => {},
        else => |err| childExitWithErrno(err_fd, err),
    }
}

fn childExitWithErrno(err_fd: std.c.fd_t, err: std.c.E) noreturn {
    var errno_value: c_int = @intFromEnum(err);
    const bytes = std.mem.asBytes(&errno_value);
    _ = std.c.write(err_fd, bytes.ptr, bytes.len);
    std.c._exit(127);
}

fn readSpawnErrno(err_fd: std.c.fd_t) ?std.c.E {
    var errno_value: c_int = 0;
    const bytes = std.mem.asBytes(&errno_value);
    var filled: usize = 0;
    while (filled < bytes.len) {
        const read_count = std.c.read(err_fd, bytes[filled..].ptr, bytes.len - filled);
        switch (std.c.errno(read_count)) {
            .SUCCESS => {
                if (read_count == 0) return if (filled == 0) null else .INVAL;
                filled += @intCast(read_count);
            },
            .INTR => continue,
            else => return .INVAL,
        }
    }
    return @enumFromInt(errno_value);
}

fn spawnErrorFromErrno(err: std.c.E) std.process.SpawnError {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

fn resolveExecArgv(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map) !ResolvedExecArgv {
    const resolved = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(resolved);
    @memcpy(resolved, argv);

    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) return .{ .argv = resolved };
    const path = env.get("PATH") orelse defaultExecPath();
    const resolved_executable = (try resolveExecutableOnPath(allocator, argv[0], cwd, path)) orelse {
        return error.ExecServerExecutableNotFound;
    };
    defer allocator.free(resolved_executable);
    const resolved_directory = std.fs.path.dirname(resolved_executable) orelse ".";
    return .{
        .argv = resolved,
        .path_lookup_env_block = try pathLookupEnvBlock(allocator, resolved_directory),
    };
}

fn pathLookupEnvBlock(allocator: std.mem.Allocator, path: []const u8) !std.process.Environ.Block {
    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();
    try map.put("PATH", path);
    return try map.createPosixBlock(allocator, .{ .zig_progress_fd = null });
}

fn defaultExecPath() []const u8 {
    const path = std.c.getenv("PATH") orelse return "/usr/bin:/bin";
    return std.mem.span(path);
}

fn resolveExecutableOnPath(allocator: std.mem.Allocator, executable: []const u8, cwd: []const u8, path: []const u8) !?[]const u8 {
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |entry| {
        const path_entry = if (entry.len == 0) "." else entry;
        const directory = if (std.fs.path.isAbsolute(path_entry))
            path_entry
        else
            try std.fs.path.join(allocator, &.{ cwd, path_entry });
        defer if (!std.fs.path.isAbsolute(path_entry)) allocator.free(directory);
        const candidate = try std.fs.path.join(allocator, &.{ directory, executable });
        errdefer allocator.free(candidate);
        const io = std.Io.Threaded.global_single_threaded.io();
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileNotFound => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };
        if (stat.kind != .file) {
            allocator.free(candidate);
            continue;
        }
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileNotFound => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };
        return candidate;
    }
    return null;
}

fn parseProcessIdParam(params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return error.InvalidExecServerProcessIdParams;
    if (params != .object) return error.InvalidExecServerProcessIdParams;
    return requiredStringField(params.object, "processId");
}

fn requiredStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingExecServerField;
    if (value != .string) return error.InvalidExecServerField;
    return value.string;
}

fn requiredBoolField(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return error.MissingExecServerField;
    if (value != .bool) return error.InvalidExecServerField;
    return value.bool;
}

fn optionalBoolField(object: std.json.ObjectMap, name: []const u8, default: bool) !bool {
    const value = object.get(name) orelse return default;
    if (value == .null) return default;
    if (value != .bool) return error.InvalidExecServerField;
    return value.bool;
}

fn optionalU64Field(object: std.json.ObjectMap, name: []const u8, default: u64) !u64 {
    const value = object.get(name) orelse return default;
    if (value == .null) return default;
    return jsonIntegerAsU64(value) orelse error.InvalidExecServerField;
}

fn optionalUsizeField(object: std.json.ObjectMap, name: []const u8) !?usize {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    const parsed = jsonIntegerAsU64(value) orelse return error.InvalidExecServerField;
    if (parsed > std.math.maxInt(usize)) return error.InvalidExecServerField;
    return @intCast(parsed);
}

fn jsonIntegerAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn execServerEnvironment(allocator: std.mem.Allocator, value: std.json.Value, env_policy: ?ExecEnvPolicy) !std.process.Environ.Map {
    var child_env = if (env_policy) |policy|
        try inheritedExecEnvironment(allocator, policy.inherit)
    else
        std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

    if (env_policy) |policy| {
        if (!policy.ignore_default_excludes) {
            removeExecEnvMatches(&child_env, default_env_exclude_patterns[0..]);
        }
        removeExecEnvMatches(&child_env, policy.exclude);
        try applyExecEnvObject(&child_env, policy.set);
        if (policy.include_only.len > 0) retainExecEnvMatches(&child_env, policy.include_only);
    }

    try applyExecEnvObject(&child_env, value);
    return child_env;
}

fn inheritedExecEnvironment(allocator: std.mem.Allocator, inherit: ExecEnvPolicyInherit) !std.process.Environ.Map {
    var child_env = std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

    if (inherit != .none) {
        try copyParentExecEnvironment(&child_env, inherit);
    }

    if (builtin.os.tag == .windows and !child_env.contains("PATHEXT")) {
        try child_env.put("PATHEXT", ".COM;.EXE;.BAT;.CMD");
    }

    return child_env;
}

fn copyParentExecEnvironment(child_env: *std.process.Environ.Map, inherit: ExecEnvPolicyInherit) !void {
    switch (builtin.os.tag) {
        .windows => {
            var parent_env = try std.process.Environ.createMap(.{ .block = .global }, child_env.allocator);
            defer parent_env.deinit();

            var iterator = parent_env.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                if (inherit == .core and !isCoreExecEnvVar(key)) continue;
                try child_env.put(key, entry.value_ptr.*);
            }
        },
        else => {
            var index: usize = 0;
            while (std.c.environ[index]) |entry| : (index += 1) {
                const item = std.mem.span(entry);
                const separator = std.mem.indexOfScalar(u8, item, '=') orelse continue;
                const key = item[0..separator];
                if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
                if (inherit == .core and !isCoreExecEnvVar(key)) continue;
                try child_env.put(key, item[separator + 1 ..]);
            }
        },
    }
}

fn isCoreExecEnvVar(key: []const u8) bool {
    const core_vars = if (builtin.os.tag == .windows) windows_core_env_vars[0..] else unix_core_env_vars[0..];
    for (core_vars) |core| {
        if (std.ascii.eqlIgnoreCase(key, core)) return true;
    }
    return false;
}

fn applyExecEnvObject(child_env: *std.process.Environ.Map, value: std.json.Value) !void {
    if (value != .object) return error.InvalidExecServerEnv;

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.process.Environ.Map.validateKeyForPut(key)) return error.InvalidExecServerEnvKey;
        switch (entry.value_ptr.*) {
            .string => |string| {
                if (std.mem.indexOfScalar(u8, string, 0) != null) return error.InvalidExecServerEnvValue;
                try child_env.put(key, string);
            },
            else => return error.InvalidExecServerEnvValue,
        }
    }
}

fn removeExecEnvMatches(child_env: *std.process.Environ.Map, patterns: []const []const u8) void {
    var index: usize = 0;
    while (index < child_env.keys().len) {
        const key = child_env.keys()[index];
        if (execEnvMatchesAnyPattern(key, patterns)) {
            _ = child_env.swapRemove(key);
        } else {
            index += 1;
        }
    }
}

fn retainExecEnvMatches(child_env: *std.process.Environ.Map, patterns: []const []const u8) void {
    var index: usize = 0;
    while (index < child_env.keys().len) {
        const key = child_env.keys()[index];
        if (!execEnvMatchesAnyPattern(key, patterns)) {
            _ = child_env.swapRemove(key);
        } else {
            index += 1;
        }
    }
}

fn execEnvMatchesAnyPattern(name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (execEnvPatternMatches(pattern, name)) return true;
    }
    return false;
}

fn execEnvPatternMatches(pattern: []const u8, name: []const u8) bool {
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_index: ?usize = null;
    var star_name_index: usize = 0;

    while (name_index < name.len) {
        if (pattern_index < pattern.len and execEnvPatternCharMatches(pattern[pattern_index], name[name_index])) {
            pattern_index += 1;
            name_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_name_index = name_index;
            continue;
        }
        if (star_index) |star| {
            pattern_index = star + 1;
            star_name_index += 1;
            name_index = star_name_index;
            continue;
        }
        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn execEnvPatternCharMatches(pattern_char: u8, name_char: u8) bool {
    return pattern_char == '?' or std.ascii.toLower(pattern_char) == std.ascii.toLower(name_char);
}

fn waitForProcessRead(
    allocator: std.mem.Allocator,
    process: *ProcessSession,
    after_seq: u64,
    wait_ms: u64,
    interrupt_for_buffered_input: bool,
    buffered_input_pending: bool,
    check_stdin_readiness: bool,
) !ProcessReadWaitResult {
    const base_wait_ms = if (buffered_input_pending)
        @min(wait_ms, max_buffered_input_read_wait_ms)
    else
        wait_ms;
    const started = std.Io.Timestamp.now(process.io_instance.io(), .awake);
    while (true) {
        try pollProcess(allocator, process, 5);
        if (process.closed or processHasChunksAfter(process, after_seq)) return .ready;
        if (processHasTerminalEventAfter(process, after_seq)) return .ready;
        if (interrupt_for_buffered_input) return .ready;
        if (check_stdin_readiness) switch (stdinReadiness()) {
            .readable => return .ready,
            .closed => if (stdoutDisconnected()) return .client_disconnected,
            .none => {},
        };
        const elapsed_ms = elapsedMilliseconds(process.io_instance.io(), started);
        if (base_wait_ms == 0 or elapsed_ms >= base_wait_ms) return .ready;
        if (process.stdout_file == null and process.stderr_file == null) {
            const sleep_ms = @min(@as(u64, 5), base_wait_ms - elapsed_ms);
            const sleep_ns: i96 = @as(i96, @intCast(sleep_ms)) * @as(i96, std.time.ns_per_ms);
            std.Io.sleep(
                process.io_instance.io(),
                .{ .nanoseconds = sleep_ns },
                .awake,
            ) catch return .ready;
        }
    }
}

fn bufferedInputInterruptsProcessRead(allocator: std.mem.Allocator, buffered_input: []const u8, process_id: []const u8) bool {
    const line_end = std.mem.indexOfScalar(u8, buffered_input, '\n') orelse buffered_input.len;
    const line = std.mem.trim(u8, buffered_input[0..line_end], " \t\r\n");
    if (line.len == 0) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    const method_value = object.get("method") orelse return false;
    if (method_value != .string) return false;
    const interrupts = std.mem.eql(u8, method_value.string, "process/write") or
        std.mem.eql(u8, method_value.string, "process/terminate");
    if (!interrupts) return false;
    const params_value = object.get("params") orelse return false;
    if (params_value != .object) return false;
    const next_process_id = params_value.object.get("processId") orelse return false;
    return next_process_id == .string and std.mem.eql(u8, next_process_id.string, process_id);
}

const ProcessReadWaitResult = enum {
    ready,
    client_disconnected,
};

const StdinReadiness = enum {
    none,
    readable,
    closed,
};

fn stdinReadiness() StdinReadiness {
    return stdinReadinessWithTimeout(0);
}

fn stdinReadinessWithTimeout(timeout_ms: u64) StdinReadiness {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL),
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return .none;
    if (ready == 0) return .none;
    const revents: u16 = @bitCast(fds[0].revents);
    const terminal_events = @as(u16, @intCast(std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL));
    if ((revents & terminal_events) != 0) return .closed;
    const readable_events = @as(u16, @intCast(std.posix.POLL.IN));
    if ((revents & readable_events) != 0) return .readable;
    return .none;
}

fn stdoutDisconnected() bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDOUT_FILENO,
        .events = @intCast(std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL),
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    if (ready == 0) return false;
    const revents: u16 = @bitCast(fds[0].revents);
    const terminal_events = @as(u16, @intCast(std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL));
    return (revents & terminal_events) != 0;
}

fn pollProcess(allocator: std.mem.Allocator, process: *ProcessSession, timeout_ms: u64) !void {
    if (process.closed) return;
    process.reapStdinWriteTask(allocator);
    const stdout_stream = if (process.tty) "pty" else "stdout";
    _ = try readProcessPipeChunk(allocator, process, &process.stdout_file, stdout_stream, timeout_ms);
    if (!process.tty) _ = try readProcessPipeChunk(allocator, process, &process.stderr_file, "stderr", timeout_ms);

    if (pollProcessChild(process)) |term| {
        const exit_code = processExitCode(term);
        try drainProcessOutput(allocator, process);
        process.finishStdinWriteTask(allocator);
        process.closeStdinFile();
        process.markExited(exit_code);
    }
    maybeMarkProcessClosed(allocator, process);
}

fn drainAvailableProcessOutputForRead(allocator: std.mem.Allocator, process: *ProcessSession, after_seq: u64, max_bytes: ?usize) !void {
    var iterations: usize = 0;
    while (!process.closed and iterations < retained_output_bytes_per_process / 4096) {
        if (processReadBudgetReached(process, after_seq, max_bytes)) return;
        const before_seq = process.next_seq;
        const had_stdout = process.stdout_file != null;
        const had_stderr = process.stderr_file != null;
        const had_exit = process.exit_code != null;
        try pollProcess(allocator, process, 0);
        iterations += 1;
        if (process.next_seq == before_seq and
            (process.stdout_file != null) == had_stdout and
            (process.stderr_file != null) == had_stderr and
            (process.exit_code != null) == had_exit)
        {
            return;
        }
    }
}

fn enqueueStdinWrite(allocator: std.mem.Allocator, process: *ProcessSession, chunk: []const u8) !void {
    if (chunk.len > max_stdin_write_queue_bytes) return error.ExecServerStdinQueueFull;
    const owned_chunk = try allocator.dupe(u8, chunk);
    errdefer allocator.free(owned_chunk);
    if (process.stdin_write_task) |task| {
        const io = std.Io.Threaded.global_single_threaded.io();
        task.mutex.lockUncancelable(io);
        defer task.mutex.unlock(io);
        if (task.closed) return error.ExecServerStdinClosed;
        if (!stdinWriteQueueHasCapacity(task, owned_chunk.len)) return error.ExecServerStdinQueueFull;
        try task.queue.append(allocator, owned_chunk);
        task.pending_bytes += owned_chunk.len;
        task.condition.signal(io);
    } else {
        try startStdinWriteTaskOwned(allocator, process, owned_chunk);
    }
}

fn startStdinWriteTaskOwned(allocator: std.mem.Allocator, process: *ProcessSession, owned_chunk: []const u8) !void {
    const stdin_file = process.stdin_file orelse return error.ExecServerStdinClosed;
    const task = try allocator.create(StdinWriteTask);
    errdefer allocator.destroy(task);
    task.* = .{
        .thread = undefined,
        .allocator = allocator,
        .file = stdin_file,
    };
    try task.queue.append(allocator, owned_chunk);
    errdefer task.queue.deinit(allocator);
    task.pending_bytes = owned_chunk.len;
    task.thread = try std.Thread.spawn(.{}, runStdinWriteTask, .{task});
    process.stdin_write_task = task;
}

fn stdinWriteQueueHasCapacity(task: *const StdinWriteTask, chunk_len: usize) bool {
    if (chunk_len > max_stdin_write_queue_bytes) return false;
    if (task.queue.items.len >= max_stdin_write_queue_chunks) return false;
    return task.pending_bytes <= max_stdin_write_queue_bytes - chunk_len;
}

fn terminateProcess(allocator: std.mem.Allocator, process: *ProcessSession) !void {
    const pgid = process.process_group_id orelse return;
    const group_pid: std.posix.pid_t = -pgid;
    std.posix.kill(group_pid, .TERM) catch {};

    const started = std.Io.Timestamp.now(process.io_instance.io(), .awake);
    while (!process.closed and elapsedMilliseconds(process.io_instance.io(), started) < 1000) {
        try pollProcess(allocator, process, 10);
    }

    if (!process.closed) {
        std.posix.kill(group_pid, .KILL) catch {};
        const kill_started = std.Io.Timestamp.now(process.io_instance.io(), .awake);
        while (!process.closed and elapsedMilliseconds(process.io_instance.io(), kill_started) < 1000) {
            try pollProcess(allocator, process, 10);
        }
    }

    if (!process.closed) {
        process.closeOpenFiles();
        process.forceClosed(-1);
    }
    process.finishStdinWriteTask(allocator);
}

fn drainProcessOutput(allocator: std.mem.Allocator, process: *ProcessSession) !void {
    var empty_rounds: usize = 0;
    while (empty_rounds < 2) {
        var made_progress = false;
        const stdout_stream = if (process.tty) "pty" else "stdout";
        made_progress = (try readProcessPipeChunk(allocator, process, &process.stdout_file, stdout_stream, 1)) == .data or made_progress;
        if (!process.tty) {
            made_progress = (try readProcessPipeChunk(allocator, process, &process.stderr_file, "stderr", 1)) == .data or made_progress;
        }
        if (made_progress) {
            empty_rounds = 0;
        } else {
            empty_rounds += 1;
        }
    }
}

const PipeReadStatus = enum {
    no_data,
    data,
    eof,
};

fn readProcessPipeChunk(
    allocator: std.mem.Allocator,
    process: *ProcessSession,
    maybe_file: *?std.Io.File,
    stream: []const u8,
    timeout_ms: u64,
) !PipeReadStatus {
    const file = maybe_file.* orelse return .eof;
    var buffer: [4096]u8 = undefined;
    const result = process.io_instance.io().operateTimeout(.{ .file_read_streaming = .{
        .file = file,
        .data = &.{buffer[0..]},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return .no_data,
        else => return err,
    };
    const count = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => {
            file.close(process.io_instance.io());
            maybe_file.* = null;
            return .eof;
        },
        error.WouldBlock => return .no_data,
        else => return err,
    };
    if (count == 0) {
        file.close(process.io_instance.io());
        maybe_file.* = null;
        return .eof;
    }
    try process.appendOutput(allocator, stream, buffer[0..count]);
    return .data;
}

fn maybeMarkProcessClosed(allocator: std.mem.Allocator, process: *ProcessSession) void {
    if (process.exit_code == null or process.stdout_file != null or process.stderr_file != null) return;
    process.finishStdinWriteTask(allocator);
    process.closeOpenFiles();
    killProcessGroup(process);
    process.markClosed();
}

fn killProcessGroup(process: *ProcessSession) void {
    const pgid = process.process_group_id orelse return;
    const group_pid: std.posix.pid_t = -pgid;
    std.posix.kill(group_pid, .KILL) catch {};
}

fn pollProcessChild(process: *ProcessSession) ?std.process.Child.Term {
    const pid = process.child.id orelse return null;
    var status: c_int = 0;
    const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (result == 0) return null;
    if (result < 0) return null;
    process.child.id = null;

    const status_u: u32 = @intCast(status);
    if (std.c.W.IFEXITED(status_u)) return .{ .exited = std.c.W.EXITSTATUS(status_u) };
    if (std.c.W.IFSIGNALED(status_u)) return .{ .signal = std.c.W.TERMSIG(status_u) };
    if (std.c.W.IFSTOPPED(status_u)) return .{ .stopped = std.c.W.STOPSIG(status_u) };
    return .{ .unknown = status_u };
}

fn processExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal, .stopped, .unknown => -1,
    };
}

fn processHasChunksAfter(process: *const ProcessSession, after_seq: u64) bool {
    for (process.output.items) |chunk| {
        if (chunk.seq > after_seq) return true;
    }
    return false;
}

fn processHasTerminalEventAfter(process: *const ProcessSession, after_seq: u64) bool {
    if (process.exit_code == null) return false;
    return after_seq < process.next_seq -| 1;
}

fn processReadBudgetReached(process: *const ProcessSession, after_seq: u64, max_bytes: ?usize) bool {
    const limit = max_bytes orelse return false;
    var emitted_chunks: usize = 0;
    var emitted_bytes: usize = 0;
    for (process.output.items) |chunk| {
        if (chunk.seq <= after_seq) continue;
        if (emitted_chunks > 0 and emitted_bytes + chunk.data.len > limit) return true;
        emitted_chunks += 1;
        emitted_bytes += chunk.data.len;
        if (emitted_bytes >= limit) return true;
    }
    return false;
}

fn elapsedMilliseconds(io: std.Io, started: std.Io.Timestamp) u64 {
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    if (elapsed.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
}

fn renderInitializeResult(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const session_id_json = try std.json.Stringify.valueAlloc(allocator, session_id, .{});
    defer allocator.free(session_id_json);
    return std.fmt.allocPrint(allocator, "{{\"sessionId\":{s}}}", .{session_id_json});
}

fn renderProcessStartResult(allocator: std.mem.Allocator, process_id: []const u8) ![]const u8 {
    const process_id_json = try std.json.Stringify.valueAlloc(allocator, process_id, .{});
    defer allocator.free(process_id_json);
    return std.fmt.allocPrint(allocator, "{{\"processId\":{s}}}", .{process_id_json});
}

fn renderProcessReadResult(allocator: std.mem.Allocator, process: *const ProcessSession, after_seq: u64, max_bytes: ?usize) ![]const u8 {
    var chunks = std.ArrayList(u8).empty;
    defer chunks.deinit(allocator);

    try chunks.append(allocator, '[');
    var emitted_chunks: usize = 0;
    var emitted_bytes: usize = 0;
    var next_seq = process.next_seq;
    for (process.output.items) |chunk| {
        if (chunk.seq <= after_seq) continue;
        if (max_bytes) |limit| {
            if (emitted_chunks > 0 and emitted_bytes + chunk.data.len > limit) break;
        }
        if (emitted_chunks > 0) try chunks.append(allocator, ',');
        const stream_json = try std.json.Stringify.valueAlloc(allocator, chunk.stream, .{});
        defer allocator.free(stream_json);
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.data.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, chunk.data);
        const chunk_json = try std.json.Stringify.valueAlloc(allocator, encoded, .{});
        defer allocator.free(chunk_json);
        const item = try std.fmt.allocPrint(
            allocator,
            "{{\"seq\":{d},\"stream\":{s},\"chunk\":{s}}}",
            .{ chunk.seq, stream_json, chunk_json },
        );
        defer allocator.free(item);
        try chunks.appendSlice(allocator, item);
        emitted_chunks += 1;
        emitted_bytes += chunk.data.len;
        next_seq = chunk.seq + 1;
        if (max_bytes) |limit| {
            if (emitted_bytes >= limit) break;
        }
    }
    try chunks.append(allocator, ']');

    const exit_code_json = if (process.exit_code) |code|
        try std.fmt.allocPrint(allocator, "{d}", .{code})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(exit_code_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"chunks\":{s},\"nextSeq\":{d},\"exited\":{s},\"exitCode\":{s},\"closed\":{s},\"failure\":null}}",
        .{
            chunks.items,
            next_seq,
            if (process.exit_code != null) "true" else "false",
            exit_code_json,
            if (process.closed) "true" else "false",
        },
    );
}

const FS_ABSOLUTE_PATH_MESSAGE = "Invalid request: AbsolutePathBuf deserialized without a base path";

fn isFsMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "fs/readFile") or
        std.mem.eql(u8, method, "fs/writeFile") or
        std.mem.eql(u8, method, "fs/createDirectory") or
        std.mem.eql(u8, method, "fs/getMetadata") or
        std.mem.eql(u8, method, "fs/readDirectory") or
        std.mem.eql(u8, method, "fs/remove") or
        std.mem.eql(u8, method, "fs/copy");
}

fn handleFsReadFile(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/readFile")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const metadata = statPath(path, true) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    } orelse {
        return renderFsFailure(allocator, id_value, error.FileNotFound);
    };
    if (metadata.size > max_exec_server_read_file_bytes) {
        return renderFsFailure(allocator, id_value, error.StreamTooLong);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_exec_server_read_file_bytes + 1)) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    };
    defer allocator.free(data);

    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    const encoded_json = try std.json.Stringify.valueAlloc(allocator, encoded, .{});
    defer allocator.free(encoded_json);
    const result = try std.fmt.allocPrint(allocator, "{{\"dataBase64\":{s}}}", .{encoded_json});
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleFsWriteFile(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/writeFile")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const data_base64 = switch (requiredStringFieldValue(object, "dataBase64", "fs/writeFile requires string dataBase64")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_base64) catch |err| {
        return renderFsInvalidBase64(allocator, id_value, err);
    };
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, data_base64) catch |err| {
        return renderFsInvalidBase64(allocator, id_value, err);
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = decoded }) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    };
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCreateDirectory(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/createDirectory")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    if (recursive) {
        std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
            return renderFsFailure(allocator, id_value, err);
        };
    } else {
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| {
            return renderFsFailure(allocator, id_value, err);
        };
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsGetMetadata(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/getMetadata")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const metadata = statPath(path, true) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    } orelse {
        return renderFsFailure(allocator, id_value, error.FileNotFound);
    };
    const symlink_metadata = statPath(path, false) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    } orelse metadata;
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"isDirectory\":{},\"isFile\":{},\"isSymlink\":{},\"createdAtMs\":{},\"modifiedAtMs\":{}}}",
        .{
            metadata.kind == .directory,
            metadata.kind == .file,
            symlink_metadata.kind == .sym_link,
            createdAtMs(path),
            timestampMs(metadata.mtime),
        },
    );
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleFsReadDirectory(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/readDirectory")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    };
    defer dir.close(io);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"entries\":[");

    var first = true;
    var iter = dir.iterate();
    while (true) {
        const entry = (iter.next(io) catch |err| {
            return renderFsFailure(allocator, id_value, err);
        }) orelse break;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        const metadata = (statPath(child_path, true) catch continue) orelse continue;
        const name_json = try std.json.Stringify.valueAlloc(allocator, entry.name, .{});
        defer allocator.free(name_json);
        const entry_json = try std.fmt.allocPrint(
            allocator,
            "{{\"fileName\":{s},\"isDirectory\":{},\"isFile\":{}}}",
            .{ name_json, metadata.kind == .directory, metadata.kind == .file },
        );
        defer allocator.free(entry_json);
        if (!first) try result.appendSlice(allocator, ",");
        first = false;
        try result.appendSlice(allocator, entry_json);
    }

    try result.appendSlice(allocator, "]}");
    return renderJsonRpcResult(allocator, id_value, result.items);
}

fn handleFsRemove(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/remove")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const force = switch (optionalBoolFieldValue(object, "force", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const metadata = statPath(path, false) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    } orelse {
        if (force) return renderJsonRpcResult(allocator, id_value, "{}");
        return renderFsFailure(allocator, id_value, error.FileNotFound);
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    if (metadata.kind == .directory) {
        if (recursive) {
            std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
                return renderFsFailure(allocator, id_value, err);
            };
        } else {
            std.Io.Dir.deleteDirAbsolute(io, path) catch |err| {
                return renderFsFailure(allocator, id_value, err);
            };
        }
    } else {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| {
            return renderFsFailure(allocator, id_value, err);
        };
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCopy(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/copy")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (fsSandboxContextError(object)) |message| return renderJsonRpcError(allocator, id_value, -32600, message);
    const source_path = switch (requiredAbsolutePathField(object, "sourcePath")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const destination_path = switch (requiredAbsolutePathField(object, "destinationPath")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", false, false)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    copyPath(allocator, io, source_path, destination_path, recursive) catch |err| {
        return renderFsFailure(allocator, id_value, err);
    };
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn fsObjectParams(params_value: ?std.json.Value, method: []const u8) FsObjectParams {
    const invalid_message = fsObjectParamsMessage(method);
    const params = params_value orelse return .{ .message = invalid_message };
    if (params != .object) return .{ .message = invalid_message };
    return .{ .object = params.object };
}

fn fsObjectParamsMessage(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "fs/copy")) return "fs/copy params must be an object";
    return "filesystem params must be an object";
}

fn fsSandboxContextError(object: std.json.ObjectMap) ?[]const u8 {
    const value = object.get("sandbox") orelse return null;
    if (value == .null) return null;
    return "direct filesystem operations do not accept sandbox context";
}

fn requiredAbsolutePathField(object: std.json.ObjectMap, field: []const u8) FsStringField {
    const path = switch (requiredStringFieldValue(object, field, "required path field must be an absolute string")) {
        .value => |value| value,
        .message => |message| return .{ .message = message },
    };
    if (!std.fs.path.isAbsolute(path)) return .{ .message = FS_ABSOLUTE_PATH_MESSAGE };
    return .{ .value = path };
}

fn requiredStringFieldValue(object: std.json.ObjectMap, field: []const u8, message: []const u8) FsStringField {
    const value = object.get(field) orelse return .{ .message = message };
    if (value != .string) return .{ .message = message };
    return .{ .value = value.string };
}

fn optionalBoolFieldValue(object: std.json.ObjectMap, field: []const u8, default: bool, null_is_default: bool) FsBoolField {
    const value = object.get(field) orelse return .{ .value = default };
    if (value == .null and null_is_default) return .{ .value = default };
    if (value != .bool) return .{ .message = "optional field must be a boolean" };
    return .{ .value = value.bool };
}

fn renderFsInvalidBase64(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "fs/writeFile requires valid base64 dataBase64: {s}", .{@errorName(err)});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32600, message);
}

fn renderFsFailure(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror) ![]const u8 {
    const message = try fsFailureMessage(allocator, err);
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, fsFailureCode(err), message);
}

fn fsFailureMessage(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return switch (err) {
        error.FsCopyDirectoryRequiresRecursive => allocator.dupe(u8, "fs/copy requires recursive: true when sourcePath is a directory"),
        error.FsCopyDestinationInsideSource => allocator.dupe(u8, "fs/copy cannot copy a directory to itself or one of its descendants"),
        error.FsCopyUnsupportedFileType => allocator.dupe(u8, "fs/copy only supports regular files, directories, and symlinks"),
        error.StreamTooLong => std.fmt.allocPrint(allocator, "file is too large to read: limit is {d} bytes", .{max_exec_server_read_file_bytes}),
        else => std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
}

fn fsFailureCode(err: anyerror) i64 {
    return switch (err) {
        error.FileNotFound => -32004,
        error.AccessDenied,
        error.PermissionDenied,
        error.InvalidArgument,
        error.BadPathName,
        error.NameTooLong,
        error.StreamTooLong,
        error.FsCopyDirectoryRequiresRecursive,
        error.FsCopyDestinationInsideSource,
        error.FsCopyUnsupportedFileType,
        => -32600,
        else => -32603,
    };
}

fn statPath(path: []const u8, follow_symlinks: bool) !?std.Io.File.Stat {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow_symlinks }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn timestampMs(value: std.Io.Timestamp) i64 {
    return @divTrunc(@as(i64, @intCast(value.nanoseconds)), 1_000_000);
}

fn createdAtMs(path: []const u8) i64 {
    if (builtin.os.tag != .macos) return 0;

    const path_c = std.posix.toPosixPath(path) catch return 0;
    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, &path_c, &stat, 0))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return 0,
        }
    }
    if (@hasDecl(std.c.Stat, "birthtime")) return timespecToUnixMs(stat.birthtime());
    return 0;
}

fn timespecToUnixMs(value: std.c.timespec) i64 {
    return @as(i64, @intCast(value.sec)) * 1000 + @divTrunc(@as(i64, @intCast(value.nsec)), 1_000_000);
}

fn copyPath(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, destination_path: []const u8, recursive: bool) !void {
    const metadata = (try statPath(source_path, false)) orelse return error.FileNotFound;
    if (metadata.kind == .directory) {
        if (!recursive) return error.FsCopyDirectoryRequiresRecursive;
        if (pathIsSameOrDescendant(source_path, destination_path)) return error.FsCopyDestinationInsideSource;
        try std.Io.Dir.cwd().createDirPath(io, destination_path);
        var source_dir = try std.Io.Dir.openDirAbsolute(io, source_path, .{ .iterate = true });
        defer source_dir.close(io);
        var iter = source_dir.iterate();
        while (try iter.next(io)) |entry| {
            const child_source = try std.fs.path.join(allocator, &.{ source_path, entry.name });
            defer allocator.free(child_source);
            const child_destination = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
            defer allocator.free(child_destination);
            try copyPath(allocator, io, child_source, child_destination, recursive);
        }
        return;
    }
    if (metadata.kind == .sym_link) {
        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = try std.Io.Dir.readLinkAbsolute(io, source_path, &target_buffer);
        try std.Io.Dir.cwd().symLink(io, target_buffer[0..target_len], destination_path, .{});
        return;
    }
    if (metadata.kind == .file) {
        try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io, .{});
        return;
    }
    return error.FsCopyUnsupportedFileType;
}

fn pathIsSameOrDescendant(source_path: []const u8, destination_path: []const u8) bool {
    const source = std.mem.trimEnd(u8, source_path, std.fs.path.sep_str);
    const destination = std.mem.trimEnd(u8, destination_path, std.fs.path.sep_str);
    if (std.mem.eql(u8, source, destination)) return true;
    if (!std.mem.startsWith(u8, destination, source)) return false;
    if (destination.len <= source.len) return false;
    return destination[source.len] == std.fs.path.sep;
}

fn renderJsonRpcResult(allocator: std.mem.Allocator, id_value: std.json.Value, result_json: []const u8) ![]const u8 {
    const id_json = try std.json.Stringify.valueAlloc(allocator, id_value, .{});
    defer allocator.free(id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn renderJsonRpcError(allocator: std.mem.Allocator, id_value: ?std.json.Value, code: i64, message: []const u8) ![]const u8 {
    const id_json = if (id_value) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_json);
    const message_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(message_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json, code, message_json },
    );
}

fn generateUuidString(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 36);
    var out_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            out[out_index] = '-';
            out_index += 1;
        }
        out[out_index] = hex[byte >> 4];
        out[out_index + 1] = hex[byte & 0x0f];
        out_index += 2;
    }
    return out;
}

fn writeStdoutLine(payload: []const u8) !void {
    try cli_utils.writeStdout(payload);
    try cli_utils.writeStdout("\n");
}

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try cli_utils.writeStderr(message);
    return error.ExecServerCommandFailed;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig exec-server [--listen URL]
        \\  codex-zig exec-server --remote URL --executor-id ID [--name NAME]
        \\
        \\Transport endpoint URL values match Rust Codex: `ws://IP:PORT`, `stdio`, or `stdio://`.
        \\The current Zig parity slice implements stdio/websocket initialize plus non-tty process lifecycle RPCs.
        \\
    , .{});
}

test "exec server parses listen transports" {
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio"));
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio://"));
    const websocket = try parseListenUrl("ws://127.0.0.1:0");
    try std.testing.expectEqualStrings("127.0.0.1", websocket.websocket.host);
    try std.testing.expectEqual(@as(u16, 0), websocket.websocket.port);
    try std.testing.expectError(error.UnsupportedExecServerListenUrl, parseListenUrl("http://127.0.0.1:0"));
    try std.testing.expectError(error.InvalidExecServerWebSocketListenUrl, parseListenUrl("ws://127.0.0.1"));
    try std.testing.expectError(error.InvalidExecServerWebSocketListenUrl, parseListenUrl("ws://127.0.0.1:not-a-port"));
}

test "exec server initialize result is Rust-shaped" {
    const allocator = std.testing.allocator;
    const result = try renderInitializeResult(allocator, "11111111-1111-4111-8111-111111111111");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"sessionId\":\"11111111-1111-4111-8111-111111111111\"}", result);
}

test "exec server validates initialize params" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"clientName\":\"smoke\",\"resumeSessionId\":null}", .{});
    defer parsed.deinit();
    try std.testing.expect(try parseInitializeParams(parsed.value) == null);

    var resume_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"clientName\":\"smoke\",\"resumeSessionId\":\"session-1\"}", .{});
    defer resume_params.deinit();
    try std.testing.expectEqualStrings("session-1", (try parseInitializeParams(resume_params.value)).?);

    var missing = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.InvalidExecServerInitializeParams, parseInitializeParams(missing.value));
}

test "exec server env policy applies set includeOnly and request env overlay" {
    const allocator = std.testing.allocator;
    var policy_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"inherit\":\"none\",\"ignoreDefaultExcludes\":false,\"exclude\":[],\"set\":{\"DROP_ME\":\"drop\",\"KEEP_ME\":\"set\",\"OVERLAY_ME\":\"policy\"},\"includeOnly\":[\"KEEP_*\",\"OVERLAY_*\"]}",
        .{},
    );
    defer policy_json.deinit();
    const policy = (try parseExecEnvPolicy(allocator, policy_json.value)).?;
    defer policy.deinit(allocator);

    var env_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"OVERLAY_ME\":\"request\",\"REQUEST_ONLY\":\"request\"}",
        .{},
    );
    defer env_json.deinit();

    var child_env = try execServerEnvironment(allocator, env_json.value, policy);
    defer child_env.deinit();

    try std.testing.expect(child_env.get("DROP_ME") == null);
    try std.testing.expectEqualStrings("set", child_env.get("KEEP_ME").?);
    try std.testing.expectEqualStrings("request", child_env.get("OVERLAY_ME").?);
    try std.testing.expectEqualStrings("request", child_env.get("REQUEST_ONLY").?);
}

test "exec server env policy validates required wire fields" {
    const allocator = std.testing.allocator;
    var missing = try std.json.parseFromSlice(std.json.Value, allocator, "{\"inherit\":\"all\"}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.InvalidExecServerEnvPolicy, parseExecEnvPolicy(allocator, missing.value));
}

test "exec server env policy patterns match Rust wildcard semantics" {
    try std.testing.expect(execEnvPatternMatches("*KEY*", "OPENAI_API_KEY"));
    try std.testing.expect(execEnvPatternMatches("foo?bar", "Foo1Bar"));
    try std.testing.expect(execEnvPatternMatches("*", ""));
    try std.testing.expect(!execEnvPatternMatches("foo?bar", "foobar"));
}
