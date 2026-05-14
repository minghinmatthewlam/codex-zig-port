const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const mcp_runtime = @import("mcp_runtime.zig");
const plan_tool = @import("plan_tool.zig");
const proposed_plan = @import("proposed_plan.zig");
const tools = @import("tools.zig");

pub const Transcript = struct {
    id: ?[]const u8 = null,
    forked_from_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    thread_source: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cli_version: ?[]const u8 = null,
    memory_mode: ?[]const u8 = null,
    git_sha: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_origin_url: ?[]const u8 = null,
    token_usage: ?TokenUsageInfo = null,
    token_usage_turn_index: ?usize = null,
    title: ?[]const u8 = null,
    history: std.ArrayList(api.HistoryItem) = .empty,
    plan: plan_tool.State = .{},

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        self.clearMetadata(allocator);
        self.clearTitle(allocator);
        self.plan.deinit(allocator);
        for (self.history.items) |item| item.deinit(allocator);
        self.history.deinit(allocator);
    }

    pub fn clearMetadata(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.id);
        clearOptionalString(allocator, &self.forked_from_id);
        clearOptionalString(allocator, &self.source);
        clearOptionalString(allocator, &self.thread_source);
        clearOptionalString(allocator, &self.model_provider);
        clearOptionalString(allocator, &self.cwd);
        clearOptionalString(allocator, &self.cli_version);
        clearOptionalString(allocator, &self.memory_mode);
        clearOptionalString(allocator, &self.git_sha);
        clearOptionalString(allocator, &self.git_branch);
        clearOptionalString(allocator, &self.git_origin_url);
    }

    pub fn setId(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.id, value);
    }

    pub fn setForkedFromId(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.forked_from_id, value);
    }

    pub fn setSource(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.source, value);
    }

    pub fn setThreadSource(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.thread_source, value);
    }

    pub fn setModelProvider(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.model_provider, value);
    }

    pub fn setCwd(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.cwd, value);
    }

    pub fn setCliVersion(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.cli_version, value);
    }

    pub fn setMemoryMode(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.memory_mode, value);
    }

    pub fn setGitSha(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.git_sha, value);
    }

    pub fn clearGitSha(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.git_sha);
    }

    pub fn setGitBranch(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.git_branch, value);
    }

    pub fn clearGitBranch(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.git_branch);
    }

    pub fn setGitOriginUrl(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.git_origin_url, value);
    }

    pub fn clearGitOriginUrl(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.git_origin_url);
    }

    pub fn setTitle(self: *Transcript, allocator: std.mem.Allocator, title: []const u8) !void {
        const copy = try allocator.dupe(u8, title);
        self.clearTitle(allocator);
        self.title = copy;
    }

    pub fn clearTitle(self: *Transcript, allocator: std.mem.Allocator) void {
        if (self.title) |title| {
            allocator.free(title);
            self.title = null;
        }
    }

    pub fn titleLabel(self: *const Transcript) []const u8 {
        return self.title orelse "<none>";
    }

    pub fn clone(self: *const Transcript, allocator: std.mem.Allocator) !Transcript {
        var copy = Transcript{};
        errdefer copy.deinit(allocator);

        if (self.id) |value| try copy.setId(allocator, value);
        if (self.forked_from_id) |value| try copy.setForkedFromId(allocator, value);
        if (self.source) |value| try copy.setSource(allocator, value);
        if (self.thread_source) |value| try copy.setThreadSource(allocator, value);
        if (self.model_provider) |value| try copy.setModelProvider(allocator, value);
        if (self.cwd) |value| try copy.setCwd(allocator, value);
        if (self.cli_version) |value| try copy.setCliVersion(allocator, value);
        if (self.memory_mode) |value| try copy.setMemoryMode(allocator, value);
        if (self.git_sha) |value| try copy.setGitSha(allocator, value);
        if (self.git_branch) |value| try copy.setGitBranch(allocator, value);
        if (self.git_origin_url) |value| try copy.setGitOriginUrl(allocator, value);
        copy.token_usage = self.token_usage;
        copy.token_usage_turn_index = self.token_usage_turn_index;
        if (self.title) |title| try copy.setTitle(allocator, title);
        copy.plan = try self.plan.clone(allocator);
        for (self.history.items) |item| try copy.appendHistoryItem(allocator, item);

        return copy;
    }

    pub fn appendUserMessage(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendMessage(allocator, "user", "input_text", text);
    }

    pub fn appendAssistantMessage(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendMessage(allocator, "assistant", "output_text", text);
    }

    pub fn appendHistoryItem(self: *Transcript, allocator: std.mem.Allocator, item: api.HistoryItem) !void {
        var owned = api.HistoryItem{ .kind = item.kind };
        errdefer owned.deinit(allocator);

        owned.role = if (item.role) |value| try allocator.dupe(u8, value) else null;
        owned.text = if (item.text) |value| try allocator.dupe(u8, value) else null;
        owned.content_type = if (item.content_type) |value| try allocator.dupe(u8, value) else null;
        owned.call_id = if (item.call_id) |value| try allocator.dupe(u8, value) else null;
        owned.name = if (item.name) |value| try allocator.dupe(u8, value) else null;
        owned.arguments = if (item.arguments) |value| try allocator.dupe(u8, value) else null;
        owned.output = if (item.output) |value| try allocator.dupe(u8, value) else null;

        try self.history.append(allocator, owned);
    }

    fn appendMessage(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: []const u8,
        content_type: []const u8,
        text: []const u8,
    ) !void {
        const role_copy = try allocator.dupe(u8, role);
        errdefer allocator.free(role_copy);
        const content_type_copy = try allocator.dupe(u8, content_type);
        errdefer allocator.free(content_type_copy);
        const text_copy = try allocator.dupe(u8, text);
        errdefer allocator.free(text_copy);

        try self.history.append(allocator, .{
            .kind = .message,
            .role = role_copy,
            .content_type = content_type_copy,
            .text = text_copy,
        });
    }

    pub fn appendFunctionCall(self: *Transcript, allocator: std.mem.Allocator, call: api.FunctionCall) !void {
        const call_id_copy = try allocator.dupe(u8, call.call_id);
        errdefer allocator.free(call_id_copy);
        const name_copy = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name_copy);
        const arguments_copy = try allocator.dupe(u8, call.arguments);
        errdefer allocator.free(arguments_copy);

        try self.history.append(allocator, .{
            .kind = .function_call,
            .call_id = call_id_copy,
            .name = name_copy,
            .arguments = arguments_copy,
        });
    }

    pub fn appendFunctionOutput(
        self: *Transcript,
        allocator: std.mem.Allocator,
        call_id: []const u8,
        output: []const u8,
    ) !void {
        const call_id_copy = try allocator.dupe(u8, call_id);
        errdefer allocator.free(call_id_copy);
        const output_copy = try allocator.dupe(u8, output);
        errdefer allocator.free(output_copy);

        try self.history.append(allocator, .{
            .kind = .function_call_output,
            .call_id = call_id_copy,
            .output = output_copy,
        });
    }

    pub fn replaceWithCompactedSummary(
        self: *Transcript,
        allocator: std.mem.Allocator,
        summary: []const u8,
    ) !void {
        var replacement = Transcript{};
        errdefer replacement.deinit(allocator);

        if (self.id) |value| try replacement.setId(allocator, value);
        if (self.forked_from_id) |value| try replacement.setForkedFromId(allocator, value);
        if (self.source) |value| try replacement.setSource(allocator, value);
        if (self.thread_source) |value| try replacement.setThreadSource(allocator, value);
        if (self.model_provider) |value| try replacement.setModelProvider(allocator, value);
        if (self.cwd) |value| try replacement.setCwd(allocator, value);
        if (self.cli_version) |value| try replacement.setCliVersion(allocator, value);
        if (self.memory_mode) |value| try replacement.setMemoryMode(allocator, value);
        if (self.git_sha) |value| try replacement.setGitSha(allocator, value);
        if (self.git_branch) |value| try replacement.setGitBranch(allocator, value);
        if (self.git_origin_url) |value| try replacement.setGitOriginUrl(allocator, value);
        if (self.title) |value| try replacement.setTitle(allocator, value);
        try replacement.appendUserMessage(allocator, summary);

        self.deinit(allocator);
        self.* = replacement;
    }
};

pub const TokenUsage = struct {
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    total_tokens: i64 = 0,
};

pub const TokenUsageInfo = struct {
    total: TokenUsage,
    last: TokenUsage,
    model_context_window: ?i64 = null,
};

pub const TurnOptions = struct {
    auto_approve: bool = false,
    prompt_for_approval: bool = true,
    json_events: bool = false,
    stream_text: bool = false,
    additional_writable_roots: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    output_schema: ?std.json.Value = null,
    input_images: []const []const u8 = &.{},
    include_tools: bool = true,
    plan_mode: bool = false,
    plan_update_callback: ?PlanUpdateCallback = null,
    diff_update_callback: ?DiffUpdateCallback = null,
    command_execution_output_callback: ?CommandExecutionOutputCallback = null,
    terminal_interaction_callback: ?TerminalInteractionCallback = null,
    file_change_patch_update_callback: ?FileChangePatchUpdateCallback = null,
    raw_response_item_callback: ?RawResponseItemCallback = null,
    reasoning_event_callback: ?ReasoningEventCallback = null,
    server_model_callback: ?ServerModelCallback = null,
    model_verification_callback: ?ModelVerificationCallback = null,
    mcp_tool_call_progress_callback: ?McpToolCallProgressCallback = null,
    mcp_startup_status_callback: ?mcp_runtime.StartupStatusCallback = null,
    workdir: ?[]const u8 = null,
    background_terminal_owner: ?[]const u8 = null,
};

pub const PlanUpdateCallback = struct {
    ctx: *anyopaque,
    on_plan_updated: *const fn (ctx: *anyopaque, plan: *const plan_tool.State) anyerror!void,
};

pub const DiffUpdateCallback = struct {
    ctx: *anyopaque,
    on_diff_updated: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const CommandExecutionOutputCallback = struct {
    ctx: *anyopaque,
    on_command_execution_output: *const fn (ctx: *anyopaque, item_id: []const u8, delta: []const u8) anyerror!void,
};

pub const TerminalInteractionCallback = struct {
    ctx: *anyopaque,
    on_terminal_interaction: *const fn (ctx: *anyopaque, item_id: []const u8, process_id: []const u8, stdin: []const u8) anyerror!void,
};

pub const FileChangePatchUpdateCallback = struct {
    ctx: *anyopaque,
    on_file_change_patch_updated: *const fn (ctx: *anyopaque, item_id: []const u8, arguments_json: []const u8) anyerror!void,
};

pub const RawResponseItemCallback = struct {
    ctx: *anyopaque,
    on_raw_response_item: *const fn (ctx: *anyopaque, item_json: []const u8) anyerror!void,
};

pub const ReasoningEventCallback = struct {
    ctx: *anyopaque,
    on_reasoning_event: *const fn (ctx: *anyopaque, event: api.ReasoningEvent) anyerror!void,
};

pub const ServerModelCallback = struct {
    ctx: *anyopaque,
    on_server_model: *const fn (ctx: *anyopaque, model: []const u8) anyerror!void,
};

pub const ModelVerificationCallback = struct {
    ctx: *anyopaque,
    on_model_verifications: *const fn (ctx: *anyopaque, verifications: []const api.ModelVerification) anyerror!void,
};

pub const McpToolCallProgressCallback = struct {
    ctx: *anyopaque,
    on_mcp_tool_call_progress: *const fn (ctx: *anyopaque, item_id: []const u8, message: []const u8) anyerror!void,
};

fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    clearOptionalString(allocator, slot);
    slot.* = copy;
}

fn clearOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8) void {
    if (slot.*) |value| {
        allocator.free(value);
        slot.* = null;
    }
}

pub fn transcriptFromResponseHistory(allocator: std.mem.Allocator, history: []const std.json.Value) !Transcript {
    if (history.len == 0) return error.EmptyHistory;

    var transcript = Transcript{};
    errdefer transcript.deinit(allocator);

    for (history) |item| {
        try appendResponseHistoryItem(allocator, &transcript, item);
    }

    return transcript;
}

pub fn appendResponseHistoryItem(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    item: std.json.Value,
) !void {
    if (item != .object) return error.InvalidHistory;
    const object = item.object;
    const item_type_value = object.get("type") orelse return error.InvalidHistory;
    if (item_type_value != .string) return error.InvalidHistory;
    const item_type = item_type_value.string;

    if (std.mem.eql(u8, item_type, "message")) {
        try appendResponseHistoryMessage(allocator, transcript, object);
    } else if (std.mem.eql(u8, item_type, "function_call")) {
        try appendResponseHistoryFunctionCall(allocator, transcript, object);
    } else if (std.mem.eql(u8, item_type, "function_call_output")) {
        try appendResponseHistoryFunctionCallOutput(allocator, transcript, object);
    }
}

fn appendResponseHistoryMessage(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    const role_value = object.get("role") orelse return error.InvalidHistory;
    if (role_value != .string) return error.InvalidHistory;
    const content_value = object.get("content") orelse return error.InvalidHistory;
    if (content_value != .array) return error.InvalidHistory;

    var content_type = defaultHistoryContentType(role_value.string);
    var text: []const u8 = "";
    for (content_value.array.items) |content_item| {
        if (content_item != .object) continue;
        const content_object = content_item.object;
        if (content_object.get("type")) |type_value| {
            if (type_value == .string) content_type = type_value.string;
        }
        const text_value = content_object.get("text") orelse continue;
        if (text_value != .string) continue;
        text = text_value.string;
        break;
    }

    try transcript.appendHistoryItem(allocator, .{
        .kind = .message,
        .role = role_value.string,
        .content_type = content_type,
        .text = text,
    });
}

fn appendResponseHistoryFunctionCall(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    const call_id = requiredJsonStringField(object, "call_id") orelse requiredJsonStringField(object, "callId") orelse return error.InvalidHistory;
    const name = requiredJsonStringField(object, "name") orelse return error.InvalidHistory;
    const arguments = requiredJsonStringField(object, "arguments") orelse return error.InvalidHistory;
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call,
        .call_id = call_id,
        .name = name,
        .arguments = arguments,
    });
}

fn appendResponseHistoryFunctionCallOutput(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    const call_id = requiredJsonStringField(object, "call_id") orelse requiredJsonStringField(object, "callId") orelse return error.InvalidHistory;
    const output = requiredJsonStringField(object, "output") orelse return error.InvalidHistory;
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call_output,
        .call_id = call_id,
        .output = output,
    });
}

fn defaultHistoryContentType(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "assistant")) return "output_text";
    return "input_text";
}

fn requiredJsonStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn runTurn(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *Transcript,
    prompt: []const u8,
) ![]const u8 {
    return runTurnWithOptions(allocator, cfg, credentials, transcript, prompt, .{});
}

pub fn runTurnWithOptions(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    transcript: *Transcript,
    prompt: []const u8,
    options: TurnOptions,
) ![]const u8 {
    try transcript.appendUserMessage(allocator, prompt);
    if (options.json_events) try emitJsonEvent(allocator, .{ .type = "turn.started" });

    var final_text = std.ArrayList(u8).empty;
    errdefer final_text.deinit(allocator);
    var last_reported_server_model: ?[]const u8 = null;
    defer if (last_reported_server_model) |model| allocator.free(model);

    var mcp_catalog = try mcp_runtime.loadCatalogWithOptions(allocator, cfg.codex_home, .{
        .startup_status_callback = options.mcp_startup_status_callback,
    });
    defer mcp_catalog.deinit(allocator);

    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        var stream_context = StreamTextContext{};
        var create_options = api.CreateTurnOptions{};
        create_options.output_schema = options.output_schema;
        create_options.input_images = options.input_images;
        create_options.include_tools = options.include_tools;
        create_options.mcp_tools = if (options.include_tools) mcp_catalog.tools else &.{};
        if (options.stream_text and !options.json_events and !options.plan_mode) {
            create_options.stream_callback = api.StreamCallback{
                .ctx = &stream_context,
                .on_text_delta = streamTextDelta,
            };
        }
        var response = try api.createTurnWithOptions(allocator, cfg, credentials, transcript.history.items, create_options);
        defer response.deinit(allocator);

        if (response.text.len > 0) {
            try final_text.appendSlice(allocator, response.text);
        }

        if (options.raw_response_item_callback) |callback| {
            for (response.raw_response_items) |item_json| {
                try callback.on_raw_response_item(callback.ctx, item_json);
            }
        }
        if (options.reasoning_event_callback) |callback| {
            for (response.reasoning_events) |event| {
                try callback.on_reasoning_event(callback.ctx, event);
            }
        }
        if (response.server_model) |server_model| {
            if (options.server_model_callback) |callback| {
                const changed = if (last_reported_server_model) |last|
                    !std.ascii.eqlIgnoreCase(last, server_model)
                else
                    true;
                if (changed) {
                    const copy = try allocator.dupe(u8, server_model);
                    errdefer allocator.free(copy);
                    try callback.on_server_model(callback.ctx, server_model);
                    if (last_reported_server_model) |last| allocator.free(last);
                    last_reported_server_model = copy;
                }
            }
        }
        if (response.model_verifications.len > 0) {
            if (options.model_verification_callback) |callback| {
                try callback.on_model_verifications(callback.ctx, response.model_verifications);
            }
        }

        if (response.function_calls.len == 0) {
            var answer = try final_text.toOwnedSlice(allocator);
            errdefer allocator.free(answer);
            if (options.plan_mode) {
                const rendered = try proposed_plan.renderPlanMode(allocator, answer);
                allocator.free(answer);
                answer = rendered;
            }
            if (answer.len > 0) try transcript.appendAssistantMessage(allocator, answer);
            if (options.json_events) try emitJsonEvent(allocator, .{ .type = "turn.completed", .message = answer });
            return answer;
        }

        for (response.function_calls) |call| {
            if (options.json_events) {
                try emitJsonEvent(allocator, .{ .type = "tool.started", .name = call.name, .arguments = call.arguments });
            } else {
                std.debug.print("\n[tool requested] {s} {s}\n", .{ call.name, call.arguments });
            }

            var tool_result = try runToolCall(allocator, cfg, mcp_catalog, call, transcript, options);
            defer tool_result.deinit(allocator);

            if (options.json_events) {
                try emitJsonEvent(allocator, .{ .type = "tool.completed", .name = call.name, .summary = tool_result.summary });
            } else {
                std.debug.print("[tool result] {s}\n", .{tool_result.summary});
            }

            try transcript.appendFunctionCall(allocator, call);
            try transcript.appendFunctionOutput(allocator, tool_result.call_id, tool_result.output);
        }
    }

    return error.TooManyToolRounds;
}

fn runToolCall(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    mcp_catalog: mcp_runtime.Catalog,
    call: api.FunctionCall,
    transcript: *Transcript,
    options: TurnOptions,
) !tools.ToolResult {
    if (std.mem.eql(u8, call.name, "update_plan")) {
        var update = try plan_tool.applyUpdate(allocator, &transcript.plan, call.arguments);
        defer update.deinit(allocator);
        if (update.applied) {
            if (options.plan_update_callback) |callback| {
                try callback.on_plan_updated(callback.ctx, &transcript.plan);
            }
        }
        if (!options.json_events) {
            std.debug.print("{s}", .{update.output});
        }
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, update.summary),
            .output = try allocator.dupe(u8, update.output),
        };
    }

    if (mcp_runtime.isResourceToolName(call.name)) {
        var output = mcp_runtime.callResourceTool(allocator, cfg.codex_home, call.name, call.arguments) catch |err| {
            return .{
                .call_id = try allocator.dupe(u8, call.call_id),
                .summary = try allocator.dupe(u8, "mcp resource failed"),
                .output = try std.fmt.allocPrint(allocator, "mcp resource tool failed: {s}", .{@errorName(err)}),
            };
        };
        defer output.deinit(allocator);
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, output.summary),
            .output = try allocator.dupe(u8, output.output),
        };
    }

    if (mcp_catalog.find(call.name)) |mcp_tool| {
        try reportMcpToolCallProgress(allocator, options, call.call_id, "calling", mcp_tool.server_name, mcp_tool.raw_tool_name, null);
        var output = mcp_runtime.callTool(allocator, cfg.codex_home, mcp_tool, call.arguments) catch |err| {
            try reportMcpToolCallProgress(allocator, options, call.call_id, "failed", mcp_tool.server_name, mcp_tool.raw_tool_name, @errorName(err));
            return .{
                .call_id = try allocator.dupe(u8, call.call_id),
                .summary = try allocator.dupe(u8, "mcp failed"),
                .output = try std.fmt.allocPrint(allocator, "mcp tool failed: {s}", .{@errorName(err)}),
            };
        };
        defer output.deinit(allocator);
        try reportMcpToolCallProgress(allocator, options, call.call_id, "completed", mcp_tool.server_name, mcp_tool.raw_tool_name, null);
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, output.summary),
            .output = try allocator.dupe(u8, output.output),
        };
    }

    var tool_result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = cfg.approval_policy,
        .sandbox_mode = cfg.sandbox_mode,
        .additional_writable_roots = options.additional_writable_roots,
        .include_cwd_write_root = options.include_cwd_write_root,
        .network_enabled = options.network_enabled,
        .auto_approve = options.auto_approve,
        .prompt_for_approval = options.prompt_for_approval,
        .workdir = options.workdir,
        .background_terminal_owner = options.background_terminal_owner,
        .background_terminal_max_timeout_ms = cfg.background_terminal_max_timeout,
    });
    errdefer tool_result.deinit(allocator);

    if (std.mem.eql(u8, call.name, "apply_patch") and std.mem.startsWith(u8, tool_result.summary, "patched ")) {
        if (options.file_change_patch_update_callback) |callback| {
            try callback.on_file_change_patch_updated(callback.ctx, call.call_id, call.arguments);
        }
        if (options.diff_update_callback) |callback| {
            try callback.on_diff_updated(callback.ctx);
        }
    }
    if (std.mem.eql(u8, call.name, "write_stdin") and !std.mem.eql(u8, tool_result.summary, "unknown session")) {
        try reportTerminalInteraction(allocator, options, call.call_id, call.arguments);
    }
    if (isCommandExecutionToolName(call.name) and tool_result.output.len > 0) {
        if (options.command_execution_output_callback) |callback| {
            try callback.on_command_execution_output(callback.ctx, call.call_id, tool_result.output);
        }
    }

    return tool_result;
}

const TerminalInteractionArgs = struct {
    session_id: u64,
    chars: []const u8 = "",
};

fn reportTerminalInteraction(
    allocator: std.mem.Allocator,
    options: TurnOptions,
    item_id: []const u8,
    arguments_json: []const u8,
) !void {
    const callback = options.terminal_interaction_callback orelse return;
    var parsed = std.json.parseFromSlice(TerminalInteractionArgs, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value.chars.len == 0) return;

    const process_id = try std.fmt.allocPrint(allocator, "{d}", .{parsed.value.session_id});
    defer allocator.free(process_id);
    try callback.on_terminal_interaction(callback.ctx, item_id, process_id, parsed.value.chars);
}

fn reportMcpToolCallProgress(
    allocator: std.mem.Allocator,
    options: TurnOptions,
    item_id: []const u8,
    status: []const u8,
    server_name: []const u8,
    tool_name: []const u8,
    maybe_error: ?[]const u8,
) !void {
    const callback = options.mcp_tool_call_progress_callback orelse return;
    const message = if (maybe_error) |error_message|
        try std.fmt.allocPrint(allocator, "{s} {s}.{s}: {s}", .{ status, server_name, tool_name, error_message })
    else
        try std.fmt.allocPrint(allocator, "{s} {s}.{s}", .{ status, server_name, tool_name });
    defer allocator.free(message);
    try callback.on_mcp_tool_call_progress(callback.ctx, item_id, message);
}

fn isCommandExecutionToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "exec_command") or
        std.mem.eql(u8, name, "write_stdin") or
        std.mem.eql(u8, name, "shell_command") or
        std.mem.eql(u8, name, "shell");
}

const StreamTextContext = struct {};

fn streamTextDelta(ctx: *anyopaque, delta: []const u8) anyerror!void {
    _ = ctx;
    std.debug.print("{s}", .{delta});
}

fn emitJsonEvent(allocator: std.mem.Allocator, event: anytype) !void {
    const line = try std.json.Stringify.valueAlloc(allocator, event, .{});
    defer allocator.free(line);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(line);
    try stdout.writeAll("\n");
    try stdout.flush();
}

test "replace transcript with compacted summary" {
    const allocator = std.testing.allocator;
    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try transcript.setTitle(allocator, "demo title");
    try transcript.setId(allocator, "11111111-1111-4111-8111-111111111111");
    try transcript.setCwd(allocator, "/tmp/demo");
    try transcript.setGitBranch(allocator, "main");
    try transcript.appendUserMessage(allocator, "first");
    try transcript.appendAssistantMessage(allocator, "second");
    try transcript.replaceWithCompactedSummary(allocator, "summary");

    try std.testing.expectEqualStrings("demo title", transcript.title.?);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", transcript.id.?);
    try std.testing.expectEqualStrings("/tmp/demo", transcript.cwd.?);
    try std.testing.expectEqualStrings("main", transcript.git_branch.?);
    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.message, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("user", transcript.history.items[0].role.?);
    try std.testing.expectEqualStrings("input_text", transcript.history.items[0].content_type.?);
    try std.testing.expectEqualStrings("summary", transcript.history.items[0].text.?);
}

test "clone transcript copies title and history" {
    const allocator = std.testing.allocator;
    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try transcript.setTitle(allocator, "source title");
    try transcript.appendUserMessage(allocator, "hello");

    var copy = try transcript.clone(allocator);
    defer copy.deinit(allocator);

    try std.testing.expectEqualStrings("source title", copy.title.?);
    try std.testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try std.testing.expectEqualStrings("hello", copy.history.items[0].text.?);

    try transcript.setTitle(allocator, "changed title");
    try transcript.appendAssistantMessage(allocator, "later");

    try std.testing.expectEqualStrings("source title", copy.title.?);
    try std.testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try std.testing.expectEqualStrings("hello", copy.history.items[0].text.?);
}
