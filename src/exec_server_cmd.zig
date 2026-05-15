const std = @import("std");

const net = std.Io.net;

const cli_utils = @import("cli_utils.zig");

const default_listen_url = "ws://127.0.0.1:0";
const max_stdio_json_rpc_line_bytes = 16 * 1024 * 1024;
const retained_output_bytes_per_process = 1024 * 1024;
const retained_closed_processes = 64;
const max_stdin_write_queue_bytes = 2 * 1024 * 1024;
const max_stdin_write_queue_chunks = 32;
const max_buffered_input_read_wait_ms = 200;

const Transport = union(enum) {
    stdio,
    websocket,
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
    pipe_stdin: bool,

    fn deinit(self: ExecStartParams, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
    }
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

const StdioServer = struct {
    allocator: std.mem.Allocator,
    initialize_complete: bool = false,
    initialized: bool = false,
    session_id: ?[]const u8 = null,
    processes: std.ArrayList(ProcessSession) = .empty,

    fn deinit(self: *StdioServer) void {
        for (self.processes.items) |*process| process.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        if (self.session_id) |value| self.allocator.free(value);
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
            const message = try std.fmt.allocPrint(self.allocator, "unknown session id {s}", .{session_id});
            defer self.allocator.free(message);
            return try renderJsonRpcError(self.allocator, id_value, -32600, message);
        }

        self.session_id = try generateUuidString(self.allocator);
        self.initialize_complete = true;

        const result = try renderInitializeResult(self.allocator, self.session_id.?);
        defer self.allocator.free(result);
        return try renderJsonRpcResult(self.allocator, id_value, result);
    }

    fn handleProcessStart(self: *StdioServer, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
        if (!self.initialized) return try renderJsonRpcError(self.allocator, id_value, -32600, "initialized notification must be sent before process requests");

        const params = parseExecStartParams(self.allocator, params_value) catch |err| switch (err) {
            error.ExecServerTtyUnsupported => return renderJsonRpcError(self.allocator, id_value, -32600, "process/start tty is not implemented yet"),
            error.ExecServerEnvPolicyUnsupported => return renderJsonRpcError(self.allocator, id_value, -32600, "process/start envPolicy is not implemented yet"),
            error.ExecServerArg0Unsupported => return renderJsonRpcError(self.allocator, id_value, -32600, "process/start arg0 is not implemented yet"),
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

        var child_env = execServerEnvironment(self.allocator, params.env) catch |err| switch (err) {
            error.InvalidExecServerEnv => return renderJsonRpcError(self.allocator, id_value, -32602, "env must be an object"),
            error.InvalidExecServerEnvKey => return renderJsonRpcError(self.allocator, id_value, -32602, "env keys must be non-empty strings without NUL or '='"),
            error.InvalidExecServerEnvValue => return renderJsonRpcError(self.allocator, id_value, -32602, "env values must be strings without NUL"),
            else => return err,
        };
        defer child_env.deinit();

        var resolved_argv = resolveExecArgv(self.allocator, params.argv, params.cwd, params.env) catch |err| switch (err) {
            error.ExecServerExecutableNotFound => {
                const message = try std.fmt.allocPrint(self.allocator, "failed to start process {s}: FileNotFound", .{params.process_id});
                defer self.allocator.free(message);
                return renderJsonRpcError(self.allocator, id_value, -32603, message);
            },
            else => return err,
        };
        defer resolved_argv.deinit(self.allocator);

        var io_instance: std.Io.Threaded = .init(self.allocator, .{
            .environ = .{ .block = resolved_argv.path_lookup_env_block orelse .empty },
        });
        errdefer io_instance.deinit();
        var child = std.process.spawn(io_instance.io(), .{
            .argv = resolved_argv.argv,
            .cwd = .{ .path = params.cwd },
            .environ_map = &child_env,
            .stdin = if (params.pipe_stdin) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "failed to start process {s}: {s}", .{ params.process_id, @errorName(err) });
            defer self.allocator.free(message);
            return renderJsonRpcError(self.allocator, id_value, -32603, message);
        };
        var child_owned = true;
        errdefer if (child_owned) child.kill(io_instance.io());

        const owned_process_id = try self.allocator.dupe(u8, params.process_id);
        errdefer self.allocator.free(owned_process_id);
        const stdin_file = child.stdin;
        const stdout_file = child.stdout;
        const stderr_file = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        errdefer if (child_owned) {
            const io = io_instance.io();
            if (stdin_file) |file| file.close(io);
            if (stdout_file) |file| file.close(io);
            if (stderr_file) |file| file.close(io);
        };

        try self.processes.append(self.allocator, .{
            .process_id = owned_process_id,
            .io_instance = io_instance,
            .child = child,
            .process_group_id = child.id,
            .path_lookup_env_block = resolved_argv.path_lookup_env_block,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
        });
        child_owned = false;
        resolved_argv.path_lookup_env_block = null;

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
        switch (try waitForProcessRead(self.allocator, process, params.after_seq, params.wait_ms, interrupt_for_buffered_input, buffered_input_pending, !buffered_input_pending)) {
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
        .websocket => return fail(
            allocator,
            "codex-zig exec-server websocket listen transport is parsed but not implemented yet; use --listen stdio\n",
            .{},
        ),
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
        return .websocket;
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
    if (tty) return error.ExecServerTtyUnsupported;
    if (object.get("envPolicy")) |env_policy| {
        if (env_policy != .null) return error.ExecServerEnvPolicyUnsupported;
    }

    if (object.get("arg0")) |arg0| {
        if (arg0 != .null and arg0 != .string) return error.InvalidExecServerStartParams;
        if (arg0 == .string) return error.ExecServerArg0Unsupported;
    }

    return .{
        .process_id = process_id,
        .argv = argv,
        .cwd = cwd,
        .env = env,
        .pipe_stdin = try optionalBoolField(object, "pipeStdin", false),
    };
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

const ResolvedExecArgv = struct {
    argv: []const []const u8,
    path_lookup_env_block: ?std.process.Environ.Block = null,

    fn deinit(self: ResolvedExecArgv, allocator: std.mem.Allocator) void {
        if (self.path_lookup_env_block) |block| block.deinit(allocator);
        allocator.free(self.argv);
    }
};

fn resolveExecArgv(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, env_value: std.json.Value) !ResolvedExecArgv {
    const resolved = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(resolved);
    @memcpy(resolved, argv);

    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) return .{ .argv = resolved };
    const path = execServerEnvString(env_value, "PATH") orelse defaultExecPath();
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

fn execServerEnvString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
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

fn execServerEnvironment(allocator: std.mem.Allocator, value: std.json.Value) !std.process.Environ.Map {
    if (value != .object) return error.InvalidExecServerEnv;
    var child_env = std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

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

    return child_env;
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
    _ = try readProcessPipeChunk(allocator, process, &process.stdout_file, "stdout", timeout_ms);
    _ = try readProcessPipeChunk(allocator, process, &process.stderr_file, "stderr", timeout_ms);

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
        made_progress = (try readProcessPipeChunk(allocator, process, &process.stdout_file, "stdout", 1)) == .data or made_progress;
        made_progress = (try readProcessPipeChunk(allocator, process, &process.stderr_file, "stderr", 1)) == .data or made_progress;
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
        \\The current Zig parity slice implements stdio initialize plus non-tty process lifecycle RPCs.
        \\
    , .{});
}

test "exec server parses listen transports" {
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio"));
    try std.testing.expectEqual(Transport.stdio, try parseListenUrl("stdio://"));
    try std.testing.expectEqual(Transport.websocket, try parseListenUrl("ws://127.0.0.1:0"));
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
