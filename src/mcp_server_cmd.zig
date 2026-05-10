const std = @import("std");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const workdir = @import("workdir.zig");

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
};

const SavedSession = struct {
    id: []const u8,
    transcript: session.Transcript,

    fn deinit(self: *SavedSession, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.transcript.deinit(allocator);
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    runtime_overrides: config.RuntimeOverrides,
    oss: bool,
    oss_provider: ?[]const u8,
    additional_writable_roots: []const []const u8,
    sessions: std.ArrayList(SavedSession) = .empty,
    next_thread_id: usize = 1,

    fn deinit(self: *Server) void {
        for (self.sessions.items) |*saved| saved.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.credentials.deinit(self.allocator);
        self.cfg.deinit(self.allocator);
    }

    fn run(self: *Server) !void {
        var input_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

        while (true) {
            const line_opt = try stdin_reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            self.handleLine(trimmed) catch |err| {
                std.debug.print("[mcp-server] failed to handle message: {s}\n", .{@errorName(err)});
            };
        }
    }

    fn handleLine(self: *Server, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try self.writeError(null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try self.writeError(null, -32600, "Invalid Request");
            return;
        }

        const object = parsed.value.object;
        const id_value = object.get("id");
        const method_value = object.get("method") orelse {
            try self.writeError(id_value, -32600, "Invalid Request");
            return;
        };
        if (method_value != .string) {
            try self.writeError(id_value, -32600, "Invalid Request");
            return;
        }
        const method = method_value.string;
        const params_value = object.get("params");

        if (std.mem.eql(u8, method, "notifications/initialized")) return;
        if (id_value == null) return;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id_value.?, params_value);
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.writeResult(id_value.?, "{}");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const result = try renderToolsList(self.allocator);
            defer self.allocator.free(result);
            try self.writeResult(id_value.?, result);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolsCall(id_value.?, params_value);
        } else {
            try self.writeError(id_value, -32601, "Method not found");
        }
    }

    fn handleInitialize(self: *Server, id_value: std.json.Value, params_value: ?std.json.Value) !void {
        const protocol_version = if (params_value) |params|
            if (params == .object)
                if (params.object.get("protocolVersion")) |value|
                    if (value == .string) value.string else "2025-03-26"
                else
                    "2025-03-26"
            else
                "2025-03-26"
        else
            "2025-03-26";

        const result = try renderInitializeResult(self.allocator, protocol_version);
        defer self.allocator.free(result);
        try self.writeResult(id_value, result);
    }

    fn handleToolsCall(self: *Server, id_value: std.json.Value, params_value: ?std.json.Value) !void {
        const params = params_value orelse {
            try self.writeToolResult(id_value, "", "Missing params for tools/call.", true);
            return;
        };
        if (params != .object) {
            try self.writeToolResult(id_value, "", "Invalid params for tools/call.", true);
            return;
        }
        const name_value = params.object.get("name") orelse {
            try self.writeToolResult(id_value, "", "Missing tool name.", true);
            return;
        };
        if (name_value != .string) {
            try self.writeToolResult(id_value, "", "Invalid tool name.", true);
            return;
        }
        const arguments_value = params.object.get("arguments") orelse {
            try self.writeToolResult(id_value, "", "Missing tool arguments.", true);
            return;
        };
        if (arguments_value != .object) {
            try self.writeToolResult(id_value, "", "Tool arguments must be an object.", true);
            return;
        }

        if (std.mem.eql(u8, name_value.string, "codex")) {
            try self.callCodex(id_value, arguments_value);
        } else if (std.mem.eql(u8, name_value.string, "codex-reply")) {
            try self.callCodexReply(id_value, arguments_value);
        } else {
            const message = try std.fmt.allocPrint(self.allocator, "Unknown tool '{s}'.", .{name_value.string});
            defer self.allocator.free(message);
            try self.writeToolResult(id_value, "", message, true);
        }
    }

    fn callCodex(self: *Server, id_value: std.json.Value, arguments_value: std.json.Value) !void {
        const prompt = getStringField(arguments_value, "prompt") orelse {
            try self.writeToolResult(id_value, "", "Missing arguments for codex tool-call; the `prompt` field is required.", true);
            return;
        };

        var transcript = session.Transcript{};
        var transcript_moved = false;
        defer if (!transcript_moved) transcript.deinit(self.allocator);

        var turn_cfg = try self.turnConfig(arguments_value);
        defer turn_cfg.deinit(self.allocator);
        const restore_cwd = try enterCallCwd(self.allocator, arguments_value);
        defer restoreCallCwd(self.allocator, restore_cwd);

        const answer = session.runTurnWithOptions(self.allocator, turn_cfg, self.credentials, &transcript, prompt, .{
            .auto_approve = true,
            .prompt_for_approval = false,
            .additional_writable_roots = self.additional_writable_roots,
        }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "Codex failed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try self.writeToolResult(id_value, "", message, true);
            return;
        };
        defer self.allocator.free(answer);

        const thread_id = try self.nextThreadId();
        errdefer self.allocator.free(thread_id);
        try self.sessions.append(self.allocator, .{ .id = thread_id, .transcript = transcript });
        transcript_moved = true;

        try self.writeToolResult(id_value, thread_id, answer, false);
    }

    fn callCodexReply(self: *Server, id_value: std.json.Value, arguments_value: std.json.Value) !void {
        const thread_id = getStringField(arguments_value, "threadId") orelse getStringField(arguments_value, "conversationId") orelse {
            try self.writeToolResult(id_value, "", "Missing arguments for codex-reply tool-call; the `threadId` and `prompt` fields are required.", true);
            return;
        };
        const prompt = getStringField(arguments_value, "prompt") orelse {
            try self.writeToolResult(id_value, thread_id, "Missing arguments for codex-reply tool-call; the `threadId` and `prompt` fields are required.", true);
            return;
        };
        const saved = self.findSession(thread_id) orelse {
            try self.writeToolResult(id_value, thread_id, "Unknown thread id.", true);
            return;
        };

        var turn_cfg = try self.turnConfig(arguments_value);
        defer turn_cfg.deinit(self.allocator);
        const restore_cwd = try enterCallCwd(self.allocator, arguments_value);
        defer restoreCallCwd(self.allocator, restore_cwd);

        const answer = session.runTurnWithOptions(self.allocator, turn_cfg, self.credentials, &saved.transcript, prompt, .{
            .auto_approve = true,
            .prompt_for_approval = false,
            .additional_writable_roots = self.additional_writable_roots,
        }) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "Codex failed: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            try self.writeToolResult(id_value, thread_id, message, true);
            return;
        };
        defer self.allocator.free(answer);

        try self.writeToolResult(id_value, saved.id, answer, false);
    }

    fn turnConfig(self: *Server, arguments_value: std.json.Value) !config.Config {
        const profile = getStringField(arguments_value, "profile");
        var cfg = if (profile) |profile_name|
            try config.loadWithOptions(self.allocator, .{ .profile = profile_name })
        else
            try cloneConfig(self.allocator, self.cfg);
        errdefer cfg.deinit(self.allocator);

        if (profile != null) {
            try config.applyRuntimeOverrides(&cfg, self.allocator, self.runtime_overrides);
            if (self.oss) {
                try config.applyOssMode(&cfg, self.allocator, self.oss_provider, self.runtime_overrides.model != null);
            }
        }

        if (getStringField(arguments_value, "model")) |model| {
            try config.applyRuntimeOverrides(&cfg, self.allocator, .{ .model = model });
        }
        if (getStringField(arguments_value, "approval-policy")) |approval_policy| {
            cfg.approval_policy = try config.ApprovalPolicy.parse(approval_policy);
        }
        if (getStringField(arguments_value, "sandbox")) |sandbox_mode| {
            cfg.sandbox_mode = try config.SandboxMode.parse(sandbox_mode);
        }

        return cfg;
    }

    fn findSession(self: *Server, thread_id: []const u8) ?*SavedSession {
        for (self.sessions.items) |*saved| {
            if (std.mem.eql(u8, saved.id, thread_id)) return saved;
        }
        return null;
    }

    fn nextThreadId(self: *Server) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "zig-{d}", .{self.next_thread_id});
        self.next_thread_id += 1;
        return id;
    }

    fn writeToolResult(self: *Server, id_value: std.json.Value, thread_id: []const u8, content: []const u8, is_error: bool) !void {
        const result = try renderToolResult(self.allocator, thread_id, content, is_error);
        defer self.allocator.free(result);
        try self.writeResult(id_value, result);
    }

    fn writeResult(self: *Server, id_value: std.json.Value, result_json: []const u8) !void {
        const id_json = try std.json.Stringify.valueAlloc(self.allocator, id_value, .{});
        defer self.allocator.free(id_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_json, result_json },
        );
        defer self.allocator.free(payload);
        try self.writeLine(payload);
    }

    fn writeError(self: *Server, id_value: ?std.json.Value, code: i64, message: []const u8) !void {
        const id_json = if (id_value) |value|
            try std.json.Stringify.valueAlloc(self.allocator, value, .{})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(id_json);
        const message_json = try std.json.Stringify.valueAlloc(self.allocator, message, .{});
        defer self.allocator.free(message_json);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
            .{ id_json, code, message_json },
        );
        defer self.allocator.free(payload);
        try self.writeLine(payload);
    }

    fn writeLine(self: *Server, payload: []const u8) !void {
        _ = self;
        try cli_utils.writeStdout(payload);
        try cli_utils.writeStdout("\n");
    }
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }
    if (raw_args.items.len > 0) {
        if (isHelpFlag(raw_args.items[0])) {
            printHelp();
            return;
        }
        return error.UnknownMcpServerOption;
    }

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    var cfg_owned = true;
    defer if (cfg_owned) cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (options.oss) {
        try config.applyOssMode(&cfg, allocator, options.oss_provider, options.runtime_overrides.model != null);
    }

    var credentials = if (options.oss)
        try auth.localOssCredentials(allocator)
    else
        try auth.loadForConfig(allocator, &cfg);
    var credentials_owned = true;
    defer if (credentials_owned) credentials.deinit(allocator);

    var server = Server{
        .allocator = allocator,
        .cfg = cfg,
        .credentials = credentials,
        .runtime_overrides = options.runtime_overrides,
        .oss = options.oss,
        .oss_provider = options.oss_provider,
        .additional_writable_roots = options.additional_writable_roots,
    };
    cfg_owned = false;
    credentials_owned = false;
    defer server.deinit();
    try server.run();
}

fn getStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn cloneConfig(allocator: std.mem.Allocator, source: config.Config) !config.Config {
    const codex_home = try allocator.dupe(u8, source.codex_home);
    errdefer allocator.free(codex_home);
    const active_profile = if (source.active_profile) |value| try allocator.dupe(u8, value) else null;
    errdefer if (active_profile) |value| allocator.free(value);
    const model = try allocator.dupe(u8, source.model);
    errdefer allocator.free(model);
    const openai_base_url = try allocator.dupe(u8, source.openai_base_url);
    errdefer allocator.free(openai_base_url);
    const chatgpt_base_url = try allocator.dupe(u8, source.chatgpt_base_url);
    errdefer allocator.free(chatgpt_base_url);
    const model_provider_env_key = if (source.model_provider_env_key) |value| try allocator.dupe(u8, value) else null;
    errdefer if (model_provider_env_key) |value| allocator.free(value);
    const model_provider_bearer_token = if (source.model_provider_bearer_token) |value| try allocator.dupe(u8, value) else null;
    errdefer if (model_provider_bearer_token) |value| allocator.free(value);
    var model_provider_auth_command = if (source.model_provider_auth_command) |value| try value.clone(allocator) else null;
    errdefer if (model_provider_auth_command) |*value| value.deinit(allocator);
    const oss_provider = if (source.oss_provider) |value| try allocator.dupe(u8, value) else null;
    errdefer if (oss_provider) |value| allocator.free(value);
    const installation_id = try allocator.dupe(u8, source.installation_id);
    errdefer allocator.free(installation_id);
    const service_tier = if (source.service_tier) |value| try allocator.dupe(u8, value) else null;
    errdefer if (service_tier) |value| allocator.free(value);
    const syntax_theme = if (source.syntax_theme) |value| try allocator.dupe(u8, value) else null;
    errdefer if (syntax_theme) |value| allocator.free(value);
    var tui_status_line = if (source.tui_status_line) |value| try value.clone(allocator) else null;
    errdefer if (tui_status_line) |*value| value.deinit(allocator);
    var tui_terminal_title = if (source.tui_terminal_title) |value| try value.clone(allocator) else null;
    errdefer if (tui_terminal_title) |*value| value.deinit(allocator);

    return .{
        .codex_home = codex_home,
        .active_profile = active_profile,
        .model = model,
        .openai_base_url = openai_base_url,
        .chatgpt_base_url = chatgpt_base_url,
        .model_provider_wire_api = source.model_provider_wire_api,
        .model_provider_env_key = model_provider_env_key,
        .model_provider_bearer_token = model_provider_bearer_token,
        .model_provider_auth_command = model_provider_auth_command,
        .oss_provider = oss_provider,
        .installation_id = installation_id,
        .approval_policy = source.approval_policy,
        .sandbox_mode = source.sandbox_mode,
        .web_search_mode = source.web_search_mode,
        .model_reasoning_effort = source.model_reasoning_effort,
        .service_tier = service_tier,
        .syntax_theme = syntax_theme,
        .personality = source.personality,
        .tui_status_line = tui_status_line,
        .tui_terminal_title = tui_terminal_title,
        .tui_alternate_screen = source.tui_alternate_screen,
    };
}

fn enterCallCwd(allocator: std.mem.Allocator, arguments_value: std.json.Value) !?[]const u8 {
    const cwd = getStringField(arguments_value, "cwd") orelse return null;
    const previous = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    errdefer allocator.free(previous);
    try workdir.change(cwd);
    return previous;
}

fn restoreCallCwd(allocator: std.mem.Allocator, restore_cwd: ?[]const u8) void {
    const previous = restore_cwd orelse return;
    defer allocator.free(previous);
    workdir.change(previous) catch |err| {
        std.debug.print("[mcp-server] failed to restore cwd: {s}\n", .{@errorName(err)});
    };
}

fn renderInitializeResult(allocator: std.mem.Allocator, protocol_version: []const u8) ![]const u8 {
    const protocol_json = try std.json.Stringify.valueAlloc(allocator, protocol_version, .{});
    defer allocator.free(protocol_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":{s},\"capabilities\":{{\"tools\":{{\"listChanged\":true}}}},\"serverInfo\":{{\"name\":\"codex-mcp-server\",\"title\":\"Codex\",\"version\":\"0.0.1\"}}}}",
        .{protocol_json},
    );
}

fn renderToolsList(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8,
        \\{"tools":[{"name":"codex","title":"Codex","description":"Run a Codex session.","inputSchema":{"type":"object","properties":{"approval-policy":{"description":"Approval policy for shell commands generated by the model: `untrusted`, `on-failure`, `on-request`, `never`.","enum":["untrusted","on-failure","on-request","never"],"type":"string"},"cwd":{"description":"Working directory for the session. If relative, it is resolved against the server process's current working directory.","type":"string"},"model":{"description":"Optional override for the model name.","type":"string"},"profile":{"description":"Configuration profile from config.toml to specify default options.","type":"string"},"prompt":{"description":"The initial user prompt to start the Codex conversation.","type":"string"},"sandbox":{"description":"Sandbox mode: `read-only`, `workspace-write`, or `danger-full-access`.","enum":["read-only","workspace-write","danger-full-access"],"type":"string"}},"required":["prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}},{"name":"codex-reply","title":"Codex Reply","description":"Continue a Codex conversation by providing the thread id and prompt.","inputSchema":{"type":"object","properties":{"conversationId":{"description":"Deprecated alias for threadId.","type":"string"},"cwd":{"description":"Working directory for the reply turn.","type":"string"},"model":{"description":"Optional override for the model name.","type":"string"},"prompt":{"description":"The next user prompt to continue the Codex conversation.","type":"string"},"threadId":{"description":"The thread id for this Codex session.","type":"string"}},"required":["prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}}]}
    );
}

fn renderToolResult(allocator: std.mem.Allocator, thread_id: []const u8, content: []const u8, is_error: bool) ![]const u8 {
    const thread_id_json = try std.json.Stringify.valueAlloc(allocator, thread_id, .{});
    defer allocator.free(thread_id_json);
    const content_json = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(content_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"structuredContent\":{{\"threadId\":{s},\"content\":{s}}},\"isError\":{s}}}",
        .{ content_json, thread_id_json, content_json, if (is_error) "true" else "false" },
    );
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage: codex-zig mcp-server
        \\
        \\Run a stdio MCP server exposing the Codex tools `codex` and `codex-reply`.
        \\
    , .{});
}

test "mcp server initialize result echoes protocol and server info" {
    const allocator = std.testing.allocator;
    const result = try renderInitializeResult(allocator, "2025-03-26");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"codex-mcp-server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"listChanged\":true") != null);
}

test "mcp server tools list exposes codex tools" {
    const allocator = std.testing.allocator;
    const result = try renderToolsList(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"codex-reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"required\":[\"prompt\"]") != null);
}

test "mcp server tool result includes text and structured content" {
    const allocator = std.testing.allocator;
    const result = try renderToolResult(allocator, "zig-1", "hello", false);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"structuredContent\":{\"threadId\":\"zig-1\",\"content\":\"hello\"},\"isError\":false}",
        result,
    );
}

test "mcp server turn config applies direct call overrides" {
    const allocator = std.testing.allocator;
    const source = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "base-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    var credentials = try auth.localOssCredentials(allocator);
    defer credentials.deinit(allocator);
    var server = Server{
        .allocator = allocator,
        .cfg = source,
        .credentials = credentials,
        .runtime_overrides = .{},
        .oss = false,
        .oss_provider = null,
        .additional_writable_roots = &.{},
    };
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"model\":\"call-model\",\"approval-policy\":\"never\",\"sandbox\":\"read-only\"}",
        .{},
    );
    defer parsed.deinit();

    var cfg = try server.turnConfig(parsed.value);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("call-model", cfg.model);
    try std.testing.expectEqual(config.ApprovalPolicy.never, cfg.approval_policy);
    try std.testing.expectEqual(config.SandboxMode.read_only, cfg.sandbox_mode);
}
