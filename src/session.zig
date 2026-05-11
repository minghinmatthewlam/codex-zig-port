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

        if (self.title) |title| try replacement.setTitle(allocator, title);
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
    output_schema: ?std.json.Value = null,
    input_images: []const []const u8 = &.{},
    include_tools: bool = true,
    plan_mode: bool = false,
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

    var mcp_catalog = try mcp_runtime.loadCatalog(allocator, cfg.codex_home);
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
        if (!options.json_events) {
            std.debug.print("{s}", .{update.output});
        }
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, update.summary),
            .output = try allocator.dupe(u8, update.output),
        };
    }

    if (mcp_catalog.find(call.name)) |mcp_tool| {
        var output = mcp_runtime.callTool(allocator, cfg.codex_home, mcp_tool, call.arguments) catch |err| {
            return .{
                .call_id = try allocator.dupe(u8, call.call_id),
                .summary = try allocator.dupe(u8, "mcp failed"),
                .output = try std.fmt.allocPrint(allocator, "mcp tool failed: {s}", .{@errorName(err)}),
            };
        };
        defer output.deinit(allocator);
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, output.summary),
            .output = try allocator.dupe(u8, output.output),
        };
    }

    return tools.runFunctionCall(allocator, call, .{
        .approval_policy = cfg.approval_policy,
        .sandbox_mode = cfg.sandbox_mode,
        .additional_writable_roots = options.additional_writable_roots,
        .auto_approve = options.auto_approve,
        .prompt_for_approval = options.prompt_for_approval,
    });
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
    try transcript.appendUserMessage(allocator, "first");
    try transcript.appendAssistantMessage(allocator, "second");
    try transcript.replaceWithCompactedSummary(allocator, "summary");

    try std.testing.expectEqualStrings("demo title", transcript.title.?);
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
