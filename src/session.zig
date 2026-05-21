const std = @import("std");
const builtin = @import("builtin");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const features_cmd = @import("features_cmd.zig");
const mcp_runtime = @import("mcp_runtime.zig");
const plan_tool = @import("plan_tool.zig");
const proposed_plan = @import("proposed_plan.zig");
const tools = @import("tools.zig");

pub const ThreadGoal = struct {
    objective: []const u8,
    status: []const u8,
    token_budget: ?i64,
    tokens_used: i64,
    time_used_seconds: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *ThreadGoal, allocator: std.mem.Allocator) void {
        allocator.free(self.objective);
        allocator.free(self.status);
    }

    pub fn clone(self: ThreadGoal, allocator: std.mem.Allocator) !ThreadGoal {
        const objective = try allocator.dupe(u8, self.objective);
        errdefer allocator.free(objective);
        const status = try allocator.dupe(u8, self.status);
        errdefer allocator.free(status);

        return .{
            .objective = objective,
            .status = status,
            .token_budget = self.token_budget,
            .tokens_used = self.tokens_used,
            .time_used_seconds = self.time_used_seconds,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
        };
    }
};

pub const Transcript = struct {
    id: ?[]const u8 = null,
    forked_from_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    thread_source: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    openai_base_url: ?[]const u8 = null,
    chatgpt_base_url: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cli_version: ?[]const u8 = null,
    memory_mode: ?[]const u8 = null,
    git_sha: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_origin_url: ?[]const u8 = null,
    token_usage: ?TokenUsageInfo = null,
    token_usage_turn_index: ?usize = null,
    goal: ?ThreadGoal = null,
    title: ?[]const u8 = null,
    history: std.ArrayList(api.HistoryItem) = .empty,
    plan: plan_tool.State = .{},

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        self.clearMetadata(allocator);
        self.clearTitle(allocator);
        self.clearGoal(allocator);
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
        clearOptionalString(allocator, &self.openai_base_url);
        clearOptionalString(allocator, &self.chatgpt_base_url);
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

    pub fn setOpenaiBaseUrl(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.openai_base_url, value);
    }

    pub fn clearOpenaiBaseUrl(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.openai_base_url);
    }

    pub fn setChatgptBaseUrl(self: *Transcript, allocator: std.mem.Allocator, value: []const u8) !void {
        try replaceOptionalString(allocator, &self.chatgpt_base_url, value);
    }

    pub fn clearChatgptBaseUrl(self: *Transcript, allocator: std.mem.Allocator) void {
        clearOptionalString(allocator, &self.chatgpt_base_url);
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

    pub fn setGoal(self: *Transcript, allocator: std.mem.Allocator, goal: ThreadGoal) !void {
        var copy = try goal.clone(allocator);
        errdefer copy.deinit(allocator);
        self.clearGoal(allocator);
        self.goal = copy;
    }

    pub fn clearGoal(self: *Transcript, allocator: std.mem.Allocator) void {
        if (self.goal) |*goal| {
            goal.deinit(allocator);
            self.goal = null;
        }
    }

    pub fn clone(self: *const Transcript, allocator: std.mem.Allocator) !Transcript {
        var copy = Transcript{};
        errdefer copy.deinit(allocator);

        if (self.id) |value| try copy.setId(allocator, value);
        if (self.forked_from_id) |value| try copy.setForkedFromId(allocator, value);
        if (self.source) |value| try copy.setSource(allocator, value);
        if (self.thread_source) |value| try copy.setThreadSource(allocator, value);
        if (self.model_provider) |value| try copy.setModelProvider(allocator, value);
        if (self.openai_base_url) |value| try copy.setOpenaiBaseUrl(allocator, value);
        if (self.chatgpt_base_url) |value| try copy.setChatgptBaseUrl(allocator, value);
        if (self.cwd) |value| try copy.setCwd(allocator, value);
        if (self.cli_version) |value| try copy.setCliVersion(allocator, value);
        if (self.memory_mode) |value| try copy.setMemoryMode(allocator, value);
        if (self.git_sha) |value| try copy.setGitSha(allocator, value);
        if (self.git_branch) |value| try copy.setGitBranch(allocator, value);
        if (self.git_origin_url) |value| try copy.setGitOriginUrl(allocator, value);
        copy.token_usage = self.token_usage;
        copy.token_usage_turn_index = self.token_usage_turn_index;
        if (self.goal) |goal| try copy.setGoal(allocator, goal);
        if (self.title) |title| try copy.setTitle(allocator, title);
        copy.plan = try self.plan.clone(allocator);
        for (self.history.items) |item| try copy.appendHistoryItem(allocator, item);

        return copy;
    }

    pub fn appendUserMessage(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendMessage(allocator, "user", "input_text", text);
    }

    pub fn appendUserMessageWithImages(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
        images: []const []const u8,
    ) !void {
        if (images.len == 0) return self.appendUserMessage(allocator, text);
        try self.appendMessageWithInputImages(allocator, "user", "input_text", text, images);
    }

    pub fn appendAssistantMessage(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendMessage(allocator, "assistant", "output_text", text);
    }

    pub fn appendDeveloperMessage(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendMessage(allocator, "developer", "input_text", text);
    }

    pub fn appendHistoryItem(self: *Transcript, allocator: std.mem.Allocator, item: api.HistoryItem) !void {
        var owned = api.HistoryItem{ .kind = item.kind };
        errdefer owned.deinit(allocator);

        owned.role = if (item.role) |value| try allocator.dupe(u8, value) else null;
        owned.text = if (item.text) |value| try allocator.dupe(u8, value) else null;
        owned.content_type = if (item.content_type) |value| try allocator.dupe(u8, value) else null;
        owned.content = try cloneHistoryContent(allocator, item.content);
        owned.images = try cloneHistoryImages(allocator, item.images);
        owned.call_id = if (item.call_id) |value| try allocator.dupe(u8, value) else null;
        owned.namespace = if (item.namespace) |value| try allocator.dupe(u8, value) else null;
        owned.name = if (item.name) |value| try allocator.dupe(u8, value) else null;
        owned.arguments = if (item.arguments) |value| try allocator.dupe(u8, value) else null;
        owned.output = if (item.output) |value| try allocator.dupe(u8, value) else null;
        owned.output_content = if (item.output_content) |content| try cloneHistoryContent(allocator, content) else null;

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

    fn appendMessageWithInputImages(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: []const u8,
        content_type: []const u8,
        text: []const u8,
        images: []const []const u8,
    ) !void {
        var item = api.HistoryItem{ .kind = .message };
        errdefer item.deinit(allocator);

        item.role = try allocator.dupe(u8, role);
        item.content_type = try allocator.dupe(u8, content_type);
        item.text = try allocator.dupe(u8, text);
        item.content = try historyContentFromTextAndInputImages(allocator, content_type, text, images);

        try self.history.append(allocator, item);
    }

    pub fn appendFunctionCall(self: *Transcript, allocator: std.mem.Allocator, call: api.FunctionCall) !void {
        if (call.kind == .tool_search) return self.appendToolSearchCall(allocator, call);
        const call_id_copy = try allocator.dupe(u8, call.call_id);
        errdefer allocator.free(call_id_copy);
        const namespace_copy = if (call.namespace) |namespace| try allocator.dupe(u8, namespace) else null;
        errdefer if (namespace_copy) |value| allocator.free(value);
        const name_copy = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name_copy);
        const arguments_copy = try allocator.dupe(u8, call.arguments);
        errdefer allocator.free(arguments_copy);

        try self.history.append(allocator, .{
            .kind = .function_call,
            .call_id = call_id_copy,
            .namespace = namespace_copy,
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

    pub fn appendToolSearchCall(self: *Transcript, allocator: std.mem.Allocator, call: api.FunctionCall) !void {
        const call_id_copy = try allocator.dupe(u8, call.call_id);
        errdefer allocator.free(call_id_copy);
        const arguments_copy = try allocator.dupe(u8, call.arguments);
        errdefer allocator.free(arguments_copy);

        try self.history.append(allocator, .{
            .kind = .tool_search_call,
            .call_id = call_id_copy,
            .arguments = arguments_copy,
        });
    }

    pub fn appendToolSearchOutput(
        self: *Transcript,
        allocator: std.mem.Allocator,
        call_id: []const u8,
        tools_json: []const u8,
    ) !void {
        const call_id_copy = try allocator.dupe(u8, call_id);
        errdefer allocator.free(call_id_copy);
        const tools_copy = try allocator.dupe(u8, tools_json);
        errdefer allocator.free(tools_copy);

        try self.history.append(allocator, .{
            .kind = .tool_search_output,
            .call_id = call_id_copy,
            .output = tools_copy,
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
        if (self.goal) |goal| try replacement.setGoal(allocator, goal);
        if (self.title) |value| try replacement.setTitle(allocator, value);
        try replacement.appendUserMessage(allocator, summary);
        replacement.token_usage = self.token_usage;
        replacement.token_usage_turn_index = null;

        self.deinit(allocator);
        self.* = replacement;
    }
};

fn cloneHistoryImages(allocator: std.mem.Allocator, images: []const api.HistoryImage) ![]const api.HistoryImage {
    if (images.len == 0) return &.{};
    const owned = try allocator.alloc(api.HistoryImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |image| image.deinit(allocator);
        allocator.free(owned);
    }

    for (images, 0..) |image, index| {
        const image_url = try allocator.dupe(u8, image.image_url);
        var image_url_owned = true;
        errdefer if (image_url_owned) allocator.free(image_url);
        const detail = if (image.detail) |value| try allocator.dupe(u8, value) else null;
        var detail_owned = true;
        errdefer if (detail_owned) if (detail) |value| allocator.free(value);
        owned[index] = .{
            .image_url = image_url,
            .detail = detail,
        };
        image_url_owned = false;
        detail_owned = false;
        initialized += 1;
    }
    return owned;
}

fn cloneHistoryContent(allocator: std.mem.Allocator, content: []const api.HistoryContent) ![]const api.HistoryContent {
    if (content.len == 0) return &.{};
    const owned = try allocator.alloc(api.HistoryContent, content.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| item.deinit(allocator);
        allocator.free(owned);
    }

    for (content, 0..) |item, index| {
        owned[index] = try cloneHistoryContentItem(allocator, item);
        initialized += 1;
    }
    return owned;
}

fn cloneHistoryContentItem(allocator: std.mem.Allocator, item: api.HistoryContent) !api.HistoryContent {
    const content_type = try allocator.dupe(u8, item.type);
    errdefer allocator.free(content_type);
    const text = if (item.text) |value| try allocator.dupe(u8, value) else null;
    var text_owned = true;
    errdefer if (text_owned) if (text) |value| allocator.free(value);
    const image_url = if (item.image_url) |value| try allocator.dupe(u8, value) else null;
    var image_url_owned = true;
    errdefer if (image_url_owned) if (image_url) |value| allocator.free(value);
    const detail = if (item.detail) |value| try allocator.dupe(u8, value) else null;
    var detail_owned = true;
    errdefer if (detail_owned) if (detail) |value| allocator.free(value);

    text_owned = false;
    image_url_owned = false;
    detail_owned = false;
    return .{
        .type = content_type,
        .text = text,
        .image_url = image_url,
        .detail = detail,
    };
}

fn historyContentFromTextAndInputImages(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    text: []const u8,
    images: []const []const u8,
) ![]const api.HistoryContent {
    const content = try allocator.alloc(api.HistoryContent, 1 + images.len);
    var initialized: usize = 0;
    errdefer {
        for (content[0..initialized]) |item| item.deinit(allocator);
        allocator.free(content);
    }

    content[0] = try cloneHistoryContentItem(allocator, .{
        .type = content_type,
        .text = text,
    });
    initialized += 1;
    for (images, 0..) |image_url, image_index| {
        content[1 + image_index] = try cloneHistoryContentItem(allocator, .{
            .type = "input_image",
            .image_url = image_url,
            .detail = "auto",
        });
        initialized += 1;
    }
    return content;
}

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
    approval_callback: ?tools.ApprovalCallback = null,
    request_permissions_callback: ?RequestPermissionsCallback = null,
    request_user_input_callback: ?RequestUserInputCallback = null,
    goal_tool_callback: ?GoalToolCallback = null,
    mcp_elicitation_callback: ?mcp_runtime.ElicitationCallback = null,
    json_events: bool = false,
    stream_text: bool = false,
    additional_writable_roots: []const []const u8 = &.{},
    read_denied_roots: []const []const u8 = &.{},
    read_denied_globs: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    output_schema: ?std.json.Value = null,
    input_images: []const []const u8 = &.{},
    include_tools: bool = true,
    plan_mode: bool = false,
    plan_update_callback: ?PlanUpdateCallback = null,
    proposed_plan_callback: ?ProposedPlanCallback = null,
    diff_update_callback: ?DiffUpdateCallback = null,
    command_execution_output_callback: ?CommandExecutionOutputCallback = null,
    terminal_interaction_callback: ?TerminalInteractionCallback = null,
    file_change_patch_update_callback: ?FileChangePatchUpdateCallback = null,
    raw_response_item_callback: ?RawResponseItemCallback = null,
    reasoning_event_callback: ?ReasoningEventCallback = null,
    server_model_callback: ?ServerModelCallback = null,
    models_etag_callback: ?ModelsEtagCallback = null,
    model_verification_callback: ?ModelVerificationCallback = null,
    mcp_tool_call_progress_callback: ?McpToolCallProgressCallback = null,
    mcp_startup_status_callback: ?mcp_runtime.StartupStatusCallback = null,
    external_auth_refresh_callback: ?api.ExternalAuthRefreshCallback = null,
    developer_messages_after_user: []const []const u8 = &.{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    workdir: ?[]const u8 = null,
    background_terminal_owner: ?[]const u8 = null,
};

pub const PlanUpdateCallback = struct {
    ctx: *anyopaque,
    on_plan_updated: *const fn (ctx: *anyopaque, plan: *const plan_tool.State) anyerror!void,
};

pub const ProposedPlanCallback = struct {
    ctx: *anyopaque,
    on_proposed_plan: *const fn (ctx: *anyopaque, plan_text: []const u8) anyerror!void,
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

pub const ModelsEtagCallback = struct {
    ctx: *anyopaque,
    on_models_etag: *const fn (ctx: *anyopaque, etag: []const u8) anyerror!void,
};

pub const ModelVerificationCallback = struct {
    ctx: *anyopaque,
    on_model_verifications: *const fn (ctx: *anyopaque, verifications: []const api.ModelVerification) anyerror!void,
};

pub const McpToolCallProgressCallback = struct {
    ctx: *anyopaque,
    on_mcp_tool_call_progress: *const fn (ctx: *anyopaque, item_id: []const u8, message: []const u8) anyerror!void,
};

pub const PermissionGrantScope = enum {
    turn,
    session,
};

pub const RequestPermissionsRequest = struct {
    call_id: []const u8,
    reason: ?[]const u8,
    arguments_json: []const u8,
    cwd: []const u8,
};

pub const RequestPermissionsResult = struct {
    output_json: []const u8,
    scope: PermissionGrantScope,
    writable_roots: []const []const u8 = &.{},
    network_enabled: ?bool = null,

    pub fn deinit(self: *RequestPermissionsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_json);
        for (self.writable_roots) |root| allocator.free(root);
        allocator.free(self.writable_roots);
    }
};

pub const RequestPermissionsCallback = struct {
    ctx: *anyopaque,
    on_request_permissions_requested: *const fn (ctx: *anyopaque, request: RequestPermissionsRequest) anyerror!RequestPermissionsResult,
};

pub const RequestUserInputRequest = struct {
    call_id: []const u8,
    arguments_json: []const u8,
};

pub const RequestUserInputResult = struct {
    output_json: []const u8,

    pub fn deinit(self: *RequestUserInputResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_json);
    }
};

pub const RequestUserInputCallback = struct {
    ctx: *anyopaque,
    on_request_user_input_requested: *const fn (ctx: *anyopaque, request: RequestUserInputRequest) anyerror!RequestUserInputResult,
};

pub const GoalToolCallback = struct {
    ctx: *anyopaque,
    on_goal_tool_requested: *const fn (ctx: *anyopaque, call: api.FunctionCall) anyerror!tools.ToolResult,
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
    } else if (std.mem.eql(u8, item_type, "tool_search_call")) {
        try appendResponseHistoryToolSearchCall(allocator, transcript, object);
    } else if (std.mem.eql(u8, item_type, "tool_search_output")) {
        try appendResponseHistoryToolSearchOutput(allocator, transcript, object);
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

    var content = try responseMessageContentFromItems(allocator, content_value.array.items, defaultHistoryContentType(role_value.string));
    defer content.deinit(allocator);

    try transcript.appendHistoryItem(allocator, .{
        .kind = .message,
        .role = role_value.string,
        .content_type = content.content_type,
        .text = content.text,
        .content = content.items,
    });
}

const ResponseMessageContent = struct {
    text: []const u8,
    content_type: []const u8,
    items: []const api.HistoryContent,

    fn deinit(self: ResponseMessageContent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.items) |item| item.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

fn responseMessageContentFromItems(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
    default_content_type: []const u8,
) !ResponseMessageContent {
    var segments = std.ArrayList([]const u8).empty;
    defer segments.deinit(allocator);
    var content = std.ArrayList(api.HistoryContent).empty;
    errdefer {
        for (content.items) |item| item.deinit(allocator);
        content.deinit(allocator);
    }
    var content_type = default_content_type;

    for (items) |item| {
        if (item != .object) continue;
        const object = item.object;
        const type_value = object.get("type");
        if (type_value != null and type_value.? == .string and std.mem.eql(u8, type_value.?.string, "input_image")) {
            const image_url_value = object.get("image_url") orelse continue;
            if (image_url_value != .string) continue;
            const detail_value = object.get("detail");
            const detail = if (detail_value != null and detail_value.? == .string) detail_value.?.string else null;
            var content_item = try cloneHistoryContentItem(allocator, .{
                .type = type_value.?.string,
                .image_url = image_url_value.string,
                .detail = detail,
            });
            var content_item_owned = true;
            errdefer if (content_item_owned) content_item.deinit(allocator);
            try content.append(allocator, content_item);
            content_item_owned = false;
            continue;
        }

        const text_value = object.get("text") orelse continue;
        if (text_value != .string) continue;
        const text_content_type = if (type_value) |value|
            if (value == .string) value.string else content_type
        else
            content_type;
        var content_item = try cloneHistoryContentItem(allocator, .{
            .type = text_content_type,
            .text = text_value.string,
        });
        var content_item_owned = true;
        errdefer if (content_item_owned) content_item.deinit(allocator);
        try content.append(allocator, content_item);
        content_item_owned = false;
        if (segments.items.len == 0) content_type = text_content_type;
        if (std.mem.trim(u8, text_value.string, " \t\r\n").len == 0) continue;
        try segments.append(allocator, text_value.string);
    }

    const text = if (segments.items.len == 0)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, "\n", segments.items);
    errdefer allocator.free(text);
    const owned_content = try content.toOwnedSlice(allocator);
    return .{
        .text = text,
        .content_type = content_type,
        .items = owned_content,
    };
}

fn appendResponseHistoryFunctionCall(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    const call_id = requiredJsonStringField(object, "call_id") orelse requiredJsonStringField(object, "callId") orelse return error.InvalidHistory;
    const namespace = optionalJsonStringField(object, "namespace");
    const name = requiredJsonStringField(object, "name") orelse return error.InvalidHistory;
    const arguments = requiredJsonStringField(object, "arguments") orelse return error.InvalidHistory;
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call,
        .call_id = call_id,
        .namespace = namespace,
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
    const output_value = object.get("output") orelse return error.InvalidHistory;
    var structured_output: ?FunctionCallOutputContent = null;
    defer if (structured_output) |content| content.deinit(allocator);
    const output = switch (output_value) {
        .string => |value| value,
        .array => |array| blk: {
            const content = try functionCallOutputContentFromItems(allocator, array.items);
            structured_output = content;
            break :blk content.text;
        },
        else => return error.InvalidHistory,
    };
    try transcript.appendHistoryItem(allocator, .{
        .kind = .function_call_output,
        .call_id = call_id,
        .output = output,
        .output_content = if (structured_output) |content| content.items else null,
    });
}

fn appendResponseHistoryToolSearchCall(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    if (isServerToolSearchItemWithNullCallId(object)) return;
    const call_id = requiredJsonStringField(object, "call_id") orelse requiredJsonStringField(object, "callId") orelse return error.InvalidHistory;
    const arguments_value = object.get("arguments") orelse return error.InvalidHistory;
    const arguments = try std.json.Stringify.valueAlloc(allocator, arguments_value, .{});
    defer allocator.free(arguments);
    try transcript.appendHistoryItem(allocator, .{
        .kind = .tool_search_call,
        .call_id = call_id,
        .arguments = arguments,
    });
}

fn appendResponseHistoryToolSearchOutput(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    object: std.json.ObjectMap,
) !void {
    if (isServerToolSearchItemWithNullCallId(object)) return;
    const call_id = requiredJsonStringField(object, "call_id") orelse requiredJsonStringField(object, "callId") orelse return error.InvalidHistory;
    const tools_value = object.get("tools") orelse return error.InvalidHistory;
    if (tools_value != .array) return error.InvalidHistory;
    const tools_json = try std.json.Stringify.valueAlloc(allocator, tools_value, .{});
    defer allocator.free(tools_json);
    try transcript.appendHistoryItem(allocator, .{
        .kind = .tool_search_output,
        .call_id = call_id,
        .output = tools_json,
    });
}

fn isServerToolSearchItemWithNullCallId(object: std.json.ObjectMap) bool {
    const call_id_value = object.get("call_id") orelse object.get("callId") orelse return false;
    if (call_id_value != .null) return false;
    const execution = optionalJsonStringField(object, "execution") orelse return false;
    return std.mem.eql(u8, execution, "server");
}

const FunctionCallOutputContent = struct {
    text: []const u8,
    items: []const api.HistoryContent,

    fn deinit(self: FunctionCallOutputContent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.items) |item| item.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

fn functionCallOutputContentFromItems(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
) !FunctionCallOutputContent {
    var segments = std.ArrayList([]const u8).empty;
    defer segments.deinit(allocator);
    var content = std.ArrayList(api.HistoryContent).empty;
    errdefer {
        for (content.items) |item| item.deinit(allocator);
        content.deinit(allocator);
    }

    for (items) |item| {
        if (item != .object) return error.InvalidHistory;
        const object = item.object;
        const type_value = object.get("type") orelse return error.InvalidHistory;
        if (type_value != .string) return error.InvalidHistory;
        if (std.mem.eql(u8, type_value.string, "input_text")) {
            const text_value = object.get("text") orelse return error.InvalidHistory;
            if (text_value != .string) return error.InvalidHistory;
            var content_item = try cloneHistoryContentItem(allocator, .{
                .type = type_value.string,
                .text = text_value.string,
            });
            var content_item_owned = true;
            errdefer if (content_item_owned) content_item.deinit(allocator);
            try content.append(allocator, content_item);
            content_item_owned = false;
            if (std.mem.trim(u8, text_value.string, " \t\r\n").len == 0) continue;
            try segments.append(allocator, text_value.string);
            continue;
        }
        if (std.mem.eql(u8, type_value.string, "input_image")) {
            const image_url_value = object.get("image_url") orelse return error.InvalidHistory;
            if (image_url_value != .string) return error.InvalidHistory;
            const detail_value = object.get("detail");
            const detail = if (detail_value) |value| switch (value) {
                .string => value.string,
                .null => null,
                else => return error.InvalidHistory,
            } else null;
            var content_item = try cloneHistoryContentItem(allocator, .{
                .type = type_value.string,
                .image_url = image_url_value.string,
                .detail = detail,
            });
            var content_item_owned = true;
            errdefer if (content_item_owned) content_item.deinit(allocator);
            try content.append(allocator, content_item);
            content_item_owned = false;
            continue;
        }
        return error.InvalidHistory;
    }

    const text = if (segments.items.len == 0)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, "\n", segments.items);
    errdefer allocator.free(text);
    const owned_content = try content.toOwnedSlice(allocator);
    return .{
        .text = text,
        .items = owned_content,
    };
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

fn optionalJsonStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
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
    try transcript.appendUserMessageWithImages(allocator, prompt, options.input_images);
    const token_usage_turn_index = lastMessageTurnIndex(transcript) orelse 0;
    for (options.developer_messages_after_user) |developer_message| {
        try transcript.appendDeveloperMessage(allocator, developer_message);
    }
    if (options.json_events) try emitJsonEvent(allocator, .{ .type = "turn.started" });

    var final_text = std.ArrayList(u8).empty;
    errdefer final_text.deinit(allocator);
    var last_reported_server_model: ?[]const u8 = null;
    defer if (last_reported_server_model) |model| allocator.free(model);
    var turn_writable_roots = std.ArrayList([]const u8).empty;
    defer {
        for (turn_writable_roots.items[options.additional_writable_roots.len..]) |root| allocator.free(root);
        turn_writable_roots.deinit(allocator);
    }
    try turn_writable_roots.appendSlice(allocator, options.additional_writable_roots);
    var turn_network_enabled = options.network_enabled;
    const turn_start_total_usage: TokenUsage = if (transcript.token_usage) |usage_info| usage_info.total else .{};
    var turn_token_usage: TokenUsage = .{};

    const load_mcp_tools = options.include_tools and mcpToolsEnabled(options);
    var mcp_catalog = if (load_mcp_tools)
        try mcp_runtime.loadCatalogWithOptions(allocator, cfg.codex_home, .{
            .startup_status_callback = options.mcp_startup_status_callback,
            .elicitation_callback = options.mcp_elicitation_callback,
        })
    else
        mcp_runtime.Catalog{ .tools = &.{} };
    defer if (load_mcp_tools) mcp_catalog.deinit(allocator);

    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        var stream_context = StreamTextContext{};
        var create_options = api.CreateTurnOptions{};
        create_options.output_schema = options.output_schema;
        create_options.input_images = &.{};
        create_options.include_tools = options.include_tools;
        create_options.mcp_tools = if (load_mcp_tools) mcp_catalog.tools else &.{};
        create_options.feature_overrides = options.feature_overrides;
        create_options.external_auth_refresh_callback = options.external_auth_refresh_callback;
        if (options.stream_text and !options.json_events and !options.plan_mode) {
            create_options.stream_callback = api.StreamCallback{
                .ctx = &stream_context,
                .on_text_delta = streamTextDelta,
            };
        }
        var response = try api.createTurnWithOptions(allocator, cfg, credentials, transcript.history.items, create_options);
        defer response.deinit(allocator);

        if (response.token_usage) |usage_info| {
            recordResponseTokenUsage(
                transcript,
                usage_info,
                turn_start_total_usage,
                &turn_token_usage,
                token_usage_turn_index,
                cfg.model_context_window,
            );
        }

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
        if (response.models_etag) |models_etag| {
            if (options.models_etag_callback) |callback| {
                try callback.on_models_etag(callback.ctx, models_etag);
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
                if (options.proposed_plan_callback) |callback| {
                    if (try proposed_plan.extractPlanText(allocator, answer)) |plan_text| {
                        defer allocator.free(plan_text);
                        try callback.on_proposed_plan(callback.ctx, plan_text);

                        const visible_answer = try proposed_plan.stripPlanBlocks(allocator, answer);
                        errdefer allocator.free(visible_answer);
                        const stored_answer = try proposed_plan.renderPlanMode(allocator, answer);
                        defer allocator.free(stored_answer);
                        if (stored_answer.len > 0) try transcript.appendAssistantMessage(allocator, stored_answer);

                        allocator.free(answer);
                        answer = visible_answer;
                        if (options.json_events) try emitJsonEvent(allocator, .{ .type = "turn.completed", .message = answer });
                        return answer;
                    }
                } else {
                    const rendered = try proposed_plan.renderPlanMode(allocator, answer);
                    allocator.free(answer);
                    answer = rendered;
                }
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

            var tool_result = if (call.kind == .tool_search)
                try runToolSearchCall(allocator, mcp_catalog, call)
            else if (std.mem.eql(u8, call.name, "request_permissions"))
                if (requestPermissionsToolEnabled(options))
                    try runRequestPermissionsToolCall(
                        allocator,
                        call,
                        options,
                        &turn_writable_roots,
                        &turn_network_enabled,
                    )
                else
                    try disabledToolResult(allocator, call)
            else if (std.mem.eql(u8, call.name, "request_user_input"))
                if (requestUserInputToolEnabled(options))
                    try runRequestUserInputToolCall(
                        allocator,
                        call,
                        options,
                    )
                else
                    try disabledToolResult(allocator, call)
            else if (isGoalToolName(call.name))
                if (goalToolsEnabled(options))
                    try runGoalToolCall(
                        allocator,
                        call,
                        options,
                    )
                else
                    try disabledToolResult(allocator, call)
            else
                try runToolCall(
                    allocator,
                    cfg,
                    mcp_catalog,
                    call,
                    transcript,
                    options,
                    turn_writable_roots.items,
                    options.read_denied_roots,
                    options.read_denied_globs,
                    turn_network_enabled,
                );
            defer tool_result.deinit(allocator);

            if (options.json_events) {
                try emitJsonEvent(allocator, .{ .type = "tool.completed", .name = call.name, .summary = tool_result.summary });
            } else {
                std.debug.print("[tool result] {s}\n", .{tool_result.summary});
            }

            if (call.kind == .tool_search) {
                try transcript.appendToolSearchCall(allocator, call);
                try transcript.appendToolSearchOutput(allocator, tool_result.call_id, tool_result.output);
            } else {
                try transcript.appendFunctionCall(allocator, call);
                try transcript.appendFunctionOutput(allocator, tool_result.call_id, tool_result.output);
            }
        }
    }

    return error.TooManyToolRounds;
}

fn recordResponseTokenUsage(
    transcript: *Transcript,
    response_usage: api.ResponseTokenUsageInfo,
    turn_start_total_usage: TokenUsage,
    turn_token_usage: *TokenUsage,
    token_usage_turn_index: usize,
    configured_context_window: ?i64,
) void {
    const previous_context_window = if (transcript.token_usage) |usage_info| usage_info.model_context_window else null;
    const usage = tokenUsageFromApi(response_usage.usage);
    turn_token_usage.* = addTokenUsage(turn_token_usage.*, usage);
    transcript.token_usage = .{
        .total = addTokenUsage(turn_start_total_usage, turn_token_usage.*),
        .last = usage,
        .model_context_window = response_usage.model_context_window orelse previous_context_window orelse configured_context_window,
    };
    transcript.token_usage_turn_index = token_usage_turn_index;
}

fn tokenUsageFromApi(usage: api.ResponseTokenUsage) TokenUsage {
    return .{
        .input_tokens = usage.input_tokens,
        .cached_input_tokens = usage.cached_input_tokens,
        .output_tokens = usage.output_tokens,
        .reasoning_output_tokens = usage.reasoning_output_tokens,
        .total_tokens = usage.total_tokens,
    };
}

fn addTokenUsage(left: TokenUsage, right: TokenUsage) TokenUsage {
    return .{
        .input_tokens = left.input_tokens + right.input_tokens,
        .cached_input_tokens = left.cached_input_tokens + right.cached_input_tokens,
        .output_tokens = left.output_tokens + right.output_tokens,
        .reasoning_output_tokens = left.reasoning_output_tokens + right.reasoning_output_tokens,
        .total_tokens = left.total_tokens + right.total_tokens,
    };
}

fn lastMessageTurnIndex(transcript: *const Transcript) ?usize {
    var message_turn_index: usize = 0;
    var last: ?usize = null;
    for (transcript.history.items) |item| {
        if (item.kind != .message) continue;
        last = message_turn_index;
        message_turn_index += 1;
    }
    return last;
}

fn runToolCall(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    mcp_catalog: mcp_runtime.Catalog,
    call: api.FunctionCall,
    transcript: *Transcript,
    options: TurnOptions,
    additional_writable_roots: []const []const u8,
    read_denied_roots: []const []const u8,
    read_denied_globs: []const []const u8,
    network_enabled: bool,
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

    if (std.mem.eql(u8, call.name, "write_stdin") and !writeStdinToolEnabled(options)) {
        return try disabledToolResult(allocator, call);
    }

    if (mcp_runtime.isResourceToolName(call.name) and mcpResourceToolsEnabled(options)) {
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

    if (mcpToolsEnabled(options)) {
        if (try findMcpToolForFunctionCall(allocator, mcp_catalog, call)) |mcp_tool| {
            try reportMcpToolCallProgress(allocator, options, call.call_id, "calling", mcp_tool.server_name, mcp_tool.raw_tool_name, null);
            var mcp_progress_context = McpRuntimeProgressContext{
                .allocator = allocator,
                .callback = options.mcp_tool_call_progress_callback,
                .item_id = call.call_id,
                .server_name = mcp_tool.server_name,
                .tool_name = mcp_tool.raw_tool_name,
            };
            var output = mcp_runtime.callToolWithOptions(allocator, cfg.codex_home, mcp_tool, call.arguments, .{
                .elicitation_callback = options.mcp_elicitation_callback,
                .progress_callback = if (options.mcp_tool_call_progress_callback != null) .{
                    .ctx = &mcp_progress_context,
                    .on_progress = handleMcpRuntimeProgress,
                } else null,
            }) catch |err| {
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
    }

    var tool_result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = cfg.approval_policy,
        .sandbox_mode = cfg.sandbox_mode,
        .additional_writable_roots = additional_writable_roots,
        .read_denied_roots = read_denied_roots,
        .read_denied_globs = read_denied_globs,
        .include_cwd_write_root = options.include_cwd_write_root,
        .network_enabled = network_enabled,
        .auto_approve = options.auto_approve,
        .prompt_for_approval = options.prompt_for_approval,
        .approval_callback = options.approval_callback,
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
    if (std.mem.eql(u8, call.name, "write_stdin") and writeStdinToolEnabled(options) and !std.mem.eql(u8, tool_result.summary, "unknown session")) {
        try reportTerminalInteraction(allocator, options, call.call_id, call.arguments);
    }
    if (isCommandExecutionToolName(call.name) and tool_result.output.len > 0) {
        if (options.command_execution_output_callback) |callback| {
            try callback.on_command_execution_output(callback.ctx, call.call_id, tool_result.output);
        }
    }

    return tool_result;
}

fn findMcpToolForFunctionCall(
    allocator: std.mem.Allocator,
    mcp_catalog: mcp_runtime.Catalog,
    call: api.FunctionCall,
) !?mcp_runtime.ToolSpec {
    if (call.namespace) |namespace| {
        const namespaced_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ namespace, call.name });
        defer allocator.free(namespaced_name);
        if (mcp_catalog.find(namespaced_name)) |tool| return tool;
    }
    return mcp_catalog.find(call.name);
}

const ToolSearchArgs = struct {
    query: []const u8,
    limit: usize,
    limit_configured: bool,
};

const tool_search_default_limit: usize = 8;
const tool_search_computer_use_limit: usize = 20;

fn runToolSearchCall(
    allocator: std.mem.Allocator,
    mcp_catalog: mcp_runtime.Catalog,
    call: api.FunctionCall,
) !tools.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch {
        return toolSearchModelError(allocator, call, "arguments must be a JSON object");
    };
    defer parsed.deinit();

    const args = parseToolSearchArgs(parsed.value) catch |err| switch (err) {
        error.ToolSearchInvalidArguments => return toolSearchModelError(allocator, call, "arguments must be a JSON object"),
        error.ToolSearchMissingQuery => return toolSearchModelError(allocator, call, "query must be a string"),
        error.ToolSearchEmptyQuery => return toolSearchModelError(allocator, call, "query must not be empty"),
        error.ToolSearchInvalidLimit => return toolSearchModelError(allocator, call, "limit must be greater than zero"),
    };

    const tools_json = try renderToolSearchMcpResults(allocator, mcp_catalog.tools, args);
    errdefer allocator.free(tools_json);
    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "tool_search completed"),
        .output = tools_json,
    };
}

fn toolSearchModelError(allocator: std.mem.Allocator, call: api.FunctionCall, message: []const u8) !tools.ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try std.fmt.allocPrint(allocator, "tool_search invalid: {s}", .{message}),
        .output = try allocator.dupe(u8, "[]"),
    };
}

fn parseToolSearchArgs(value: std.json.Value) !ToolSearchArgs {
    if (value != .object) return error.ToolSearchInvalidArguments;
    const query_value = value.object.get("query") orelse return error.ToolSearchMissingQuery;
    if (query_value != .string) return error.ToolSearchMissingQuery;
    const query = std.mem.trim(u8, query_value.string, " \t\r\n");
    if (query.len == 0) return error.ToolSearchEmptyQuery;

    var limit: usize = tool_search_default_limit;
    var limit_configured = false;
    if (value.object.get("limit")) |limit_value| {
        limit_configured = true;
        limit = switch (limit_value) {
            .integer => |number| if (number > 0) @intCast(number) else return error.ToolSearchInvalidLimit,
            .float => |number| blk: {
                if (number <= 0) return error.ToolSearchInvalidLimit;
                const truncated = @trunc(number);
                if (truncated != number) return error.ToolSearchInvalidLimit;
                break :blk @intFromFloat(truncated);
            },
            .number_string => |text| std.fmt.parseUnsigned(usize, text, 10) catch return error.ToolSearchInvalidLimit,
            else => return error.ToolSearchInvalidLimit,
        };
        if (limit == 0) return error.ToolSearchInvalidLimit;
    }

    return .{
        .query = query,
        .limit = limit,
        .limit_configured = limit_configured,
    };
}

const ToolSearchMatch = struct {
    tool: mcp_runtime.ToolSpec,
    score: usize,
};

fn renderToolSearchMcpResults(
    allocator: std.mem.Allocator,
    mcp_tools: []const mcp_runtime.ToolSpec,
    args: ToolSearchArgs,
) ![]const u8 {
    var matches = std.ArrayList(ToolSearchMatch).empty;
    defer matches.deinit(allocator);

    for (mcp_tools) |tool| {
        const score = toolSearchScore(args.query, tool);
        if (score == 0) continue;
        try matches.append(allocator, .{
            .tool = tool,
            .score = score,
        });
    }

    std.mem.sort(ToolSearchMatch, matches.items, {}, toolSearchMatchLessThan);

    const limit = toolSearchEffectiveLimit(matches.items, args);
    const result_limit = @min(matches.items.len, limit);
    var selected = std.ArrayList(ToolSearchMatch).empty;
    defer selected.deinit(allocator);
    for (matches.items[0..result_limit]) |match| {
        if (!args.limit_configured and toolSearchBucketCount(selected.items, match.tool.server_name) >= toolSearchDefaultLimitForBucket(match.tool.server_name)) {
            continue;
        }
        try selected.append(allocator, match);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var emitted_servers = std.ArrayList([]const u8).empty;
    defer emitted_servers.deinit(allocator);
    var namespace_count: usize = 0;
    for (selected.items) |match| {
        const server_name = match.tool.server_name;
        if (toolSearchServerEmitted(emitted_servers.items, server_name)) continue;
        if (namespace_count > 0) try out.append(allocator, ',');
        try appendToolSearchMcpNamespaceJson(allocator, &out, server_name, selected.items);
        try emitted_servers.append(allocator, server_name);
        namespace_count += 1;
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn toolSearchEffectiveLimit(matches: []const ToolSearchMatch, args: ToolSearchArgs) usize {
    if (args.limit_configured) return args.limit;
    const default_window = @min(matches.len, tool_search_default_limit);
    for (matches[0..default_window]) |match| {
        if (std.mem.eql(u8, match.tool.server_name, "computer-use")) return tool_search_computer_use_limit;
    }
    return args.limit;
}

fn toolSearchDefaultLimitForBucket(server_name: []const u8) usize {
    if (std.mem.eql(u8, server_name, "computer-use")) return tool_search_computer_use_limit;
    return tool_search_default_limit;
}

fn toolSearchBucketCount(matches: []const ToolSearchMatch, server_name: []const u8) usize {
    var count: usize = 0;
    for (matches) |match| {
        if (std.mem.eql(u8, match.tool.server_name, server_name)) count += 1;
    }
    return count;
}

fn toolSearchServerEmitted(emitted_servers: []const []const u8, server_name: []const u8) bool {
    for (emitted_servers) |emitted| {
        if (std.mem.eql(u8, emitted, server_name)) return true;
    }
    return false;
}

fn toolSearchMatchLessThan(_: void, lhs: ToolSearchMatch, rhs: ToolSearchMatch) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    const server_order = std.mem.order(u8, lhs.tool.server_name, rhs.tool.server_name);
    if (server_order != .eq) return server_order == .lt;
    return std.mem.lessThan(u8, lhs.tool.raw_tool_name, rhs.tool.raw_tool_name);
}

fn toolSearchScore(query: []const u8, tool: mcp_runtime.ToolSpec) usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        if (containsAsciiIgnoreCase(tool.callable_name, token) or
            containsAsciiIgnoreCase(tool.raw_tool_name, token) or
            containsAsciiIgnoreCase(tool.server_name, token) or
            containsAsciiIgnoreCase(tool.description, token) or
            containsAsciiIgnoreCase(tool.input_schema_json, token))
        {
            score += token.len;
        }
    }
    if (containsAsciiIgnoreCase(tool.callable_name, query) or containsAsciiIgnoreCase(tool.description, query)) {
        score += query.len * 2;
    }
    return score;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn appendToolSearchMcpNamespaceJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    server_name: []const u8,
    matches: []const ToolSearchMatch,
) !void {
    const namespace_name = try toolSearchNamespaceName(allocator, server_name);
    defer allocator.free(namespace_name);
    const namespace_json = try std.json.Stringify.valueAlloc(allocator, namespace_name, .{});
    defer allocator.free(namespace_json);
    const description = try std.fmt.allocPrint(allocator, "Tools in the {s} namespace.", .{namespace_name});
    defer allocator.free(description);
    const description_json = try std.json.Stringify.valueAlloc(allocator, description, .{});
    defer allocator.free(description_json);

    try out.appendSlice(allocator, "{\"type\":\"namespace\",\"name\":");
    try out.appendSlice(allocator, namespace_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    try out.appendSlice(allocator, ",\"tools\":[");
    var first_tool = true;
    for (matches) |match| {
        if (!std.mem.eql(u8, match.tool.server_name, server_name)) continue;
        if (!first_tool) try out.append(allocator, ',');
        try appendToolSearchMcpToolJson(allocator, out, match.tool, namespace_name);
        first_tool = false;
    }
    try out.appendSlice(allocator, "]}");
}

fn appendToolSearchMcpToolJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tool: mcp_runtime.ToolSpec,
    namespace_name: []const u8,
) !void {
    const model_name = toolSearchMcpCallableLeafName(tool, namespace_name);
    const name_json = try std.json.Stringify.valueAlloc(allocator, model_name, .{});
    defer allocator.free(name_json);
    const description = if (tool.description.len > 0) tool.description else "Call a configured MCP server tool.";
    const description_json = try std.json.Stringify.valueAlloc(allocator, description, .{});
    defer allocator.free(description_json);
    var schema_parse = std.json.parseFromSlice(std.json.Value, allocator, tool.input_schema_json, .{}) catch null;
    defer if (schema_parse) |*parsed| parsed.deinit();
    const schema_json = if (schema_parse) |parsed|
        try std.json.Stringify.valueAlloc(allocator, parsed.value, .{})
    else
        try allocator.dupe(u8, "{\"type\":\"object\"}");
    defer allocator.free(schema_json);

    try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    try out.appendSlice(allocator, ",\"strict\":false,\"defer_loading\":true,\"parameters\":");
    try out.appendSlice(allocator, schema_json);
    try out.append(allocator, '}');
}

fn toolSearchMcpCallableLeafName(tool: mcp_runtime.ToolSpec, namespace_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tool.callable_name, namespace_name)) {
        const leaf = tool.callable_name[namespace_name.len..];
        if (leaf.len > 0) return leaf;
    }
    return tool.callable_name;
}

fn toolSearchNamespaceName(allocator: std.mem.Allocator, server_name: []const u8) ![]const u8 {
    const placeholder = try mcp_runtime.canonicalToolName(allocator, server_name, "tool");
    defer allocator.free(placeholder);
    const suffix = "__tool";
    if (std.mem.endsWith(u8, placeholder, suffix)) {
        return std.fmt.allocPrint(allocator, "{s}__", .{placeholder[0 .. placeholder.len - suffix.len]});
    }
    return allocator.dupe(u8, placeholder);
}

test "findMcpToolForFunctionCall resolves namespaced mcp calls" {
    const allocator = std.testing.allocator;
    var mcp_tools = [_]mcp_runtime.ToolSpec{.{
        .server_name = "demo",
        .raw_tool_name = "echo",
        .callable_name = "mcp__demo__echo",
        .description = "Echo through MCP",
        .input_schema_json = "{\"type\":\"object\"}",
    }};
    const catalog = mcp_runtime.Catalog{ .tools = mcp_tools[0..] };
    const call = api.FunctionCall{
        .call_id = "call-1",
        .namespace = "mcp__demo__",
        .name = "echo",
        .arguments = "{}",
    };

    const resolved = (try findMcpToolForFunctionCall(allocator, catalog, call)).?;
    try std.testing.expectEqualStrings("demo", resolved.server_name);
    try std.testing.expectEqualStrings("echo", resolved.raw_tool_name);
    try std.testing.expectEqualStrings("mcp__demo__echo", resolved.callable_name);
}

test "runToolSearchCall returns matching mcp namespace tools" {
    const allocator = std.testing.allocator;
    var mcp_tools = [_]mcp_runtime.ToolSpec{
        .{
            .server_name = "demo",
            .raw_tool_name = "echo",
            .callable_name = "mcp__demo__echo",
            .description = "Echo through MCP",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}}}",
        },
        .{
            .server_name = "demo",
            .raw_tool_name = "calendar",
            .callable_name = "mcp__demo__calendar",
            .description = "Calendar lookup",
            .input_schema_json = "{\"type\":\"object\"}",
        },
    };
    const catalog = mcp_runtime.Catalog{ .tools = mcp_tools[0..] };
    const call = api.FunctionCall{
        .kind = .tool_search,
        .call_id = "search-1",
        .name = "tool_search",
        .arguments = "{\"query\":\"echo\",\"limit\":1}",
    };

    const result = try runToolSearchCall(allocator, catalog, call);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("search-1", result.call_id);
    try std.testing.expectEqualStrings("tool_search completed", result.summary);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const namespaces = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), namespaces.items.len);
    const namespace = namespaces.items[0].object;
    try std.testing.expectEqualStrings("namespace", namespace.get("type").?.string);
    try std.testing.expectEqualStrings("mcp__demo__", namespace.get("name").?.string);
    const namespace_tools = namespace.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), namespace_tools.items.len);
    try std.testing.expectEqualStrings("function", namespace_tools.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("echo", namespace_tools.items[0].object.get("name").?.string);
    try std.testing.expectEqual(true, namespace_tools.items[0].object.get("defer_loading").?.bool);
}

test "runToolSearchCall advertises sanitized mcp callable leaf names" {
    const allocator = std.testing.allocator;
    var mcp_tools = [_]mcp_runtime.ToolSpec{.{
        .server_name = "demo",
        .raw_tool_name = "read-file",
        .callable_name = "mcp__demo__read_file",
        .description = "Read a file through MCP",
        .input_schema_json = "{\"type\":\"object\"}",
    }};
    const catalog = mcp_runtime.Catalog{ .tools = mcp_tools[0..] };
    const call = api.FunctionCall{
        .kind = .tool_search,
        .call_id = "search-sanitized",
        .name = "tool_search",
        .arguments = "{\"query\":\"read-file\"}",
    };

    const result = try runToolSearchCall(allocator, catalog, call);
    defer result.deinit(allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const namespace = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("mcp__demo__", namespace.get("name").?.string);
    const namespace_tools = namespace.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), namespace_tools.items.len);
    try std.testing.expectEqualStrings("read_file", namespace_tools.items[0].object.get("name").?.string);

    const resolved = (try findMcpToolForFunctionCall(allocator, catalog, .{
        .call_id = "call-sanitized",
        .namespace = "mcp__demo__",
        .name = namespace_tools.items[0].object.get("name").?.string,
        .arguments = "{}",
    })).?;
    try std.testing.expectEqualStrings("read-file", resolved.raw_tool_name);
}

test "runToolSearchCall returns empty tools array for invalid arguments" {
    const allocator = std.testing.allocator;
    const catalog = mcp_runtime.Catalog{ .tools = &.{} };
    const call = api.FunctionCall{
        .kind = .tool_search,
        .call_id = "search-invalid",
        .name = "tool_search",
        .arguments = "{\"query\":\"\"}",
    };

    const result = try runToolSearchCall(allocator, catalog, call);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("search-invalid", result.call_id);
    try std.testing.expect(std.mem.startsWith(u8, result.summary, "tool_search invalid:"));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "runToolSearchCall uses larger default limit for computer-use tools" {
    const allocator = std.testing.allocator;
    var owned_tools = std.ArrayList(mcp_runtime.ToolSpec).empty;
    defer {
        for (owned_tools.items) |tool| tool.deinit(allocator);
        owned_tools.deinit(allocator);
    }

    for (0..25) |index| {
        const raw_name = try std.fmt.allocPrint(allocator, "tool_{d}", .{index});
        errdefer allocator.free(raw_name);
        const callable_name = try std.fmt.allocPrint(allocator, "mcp__computer_use__tool_{d}", .{index});
        errdefer allocator.free(callable_name);
        try owned_tools.append(allocator, .{
            .server_name = try allocator.dupe(u8, "computer-use"),
            .raw_tool_name = raw_name,
            .callable_name = callable_name,
            .description = try allocator.dupe(u8, "computer use desktop tool"),
            .input_schema_json = try allocator.dupe(u8, "{\"type\":\"object\"}"),
        });
    }

    const catalog = mcp_runtime.Catalog{ .tools = owned_tools.items };
    const call = api.FunctionCall{
        .kind = .tool_search,
        .call_id = "search-computer-use",
        .name = "tool_search",
        .arguments = "{\"query\":\"computer use\"}",
    };

    const result = try runToolSearchCall(allocator, catalog, call);
    defer result.deinit(allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const namespaces = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), namespaces.items.len);
    const namespace = namespaces.items[0].object;
    try std.testing.expectEqualStrings("mcp__computer_use__", namespace.get("name").?.string);
    try std.testing.expectEqual(@as(usize, tool_search_computer_use_limit), namespace.get("tools").?.array.items.len);
}

test "runToolCall applies read-denied roots" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.writeFile(io_instance.io(), .{ .sub_path = "secret.txt", .data = "secret" });
    try dir.dir.writeFile(io_instance.io(), .{ .sub_path = "public.txt", .data = "public" });
    const cwd = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);
    const secret_path = try std.fs.path.join(allocator, &.{ cwd, "secret.txt" });
    defer allocator.free(secret_path);

    var cfg = config.Config{
        .codex_home = try allocator.dupe(u8, cwd),
        .active_profile = null,
        .model = try allocator.dupe(u8, "gpt-test"),
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1"),
        .chatgpt_base_url = try allocator.dupe(u8, "http://127.0.0.1"),
        .oss_provider = null,
        .installation_id = try allocator.dupe(u8, "install"),
        .approval_policy = .never,
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
    defer cfg.deinit(allocator);

    const cwd_json = try std.json.Stringify.valueAlloc(allocator, cwd, .{});
    defer allocator.free(cwd_json);
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"cmd\":\"! cat secret.txt && cat public.txt && printf session-read-deny-ok\",\"workdir\":{s}}}",
        .{cwd_json},
    );
    defer allocator.free(args);

    var transcript = Transcript{};
    defer transcript.deinit(allocator);
    const call = api.FunctionCall{
        .call_id = "session-read-deny",
        .name = "exec_command",
        .arguments = args,
    };
    var result = try runToolCall(
        allocator,
        cfg,
        .{ .tools = &.{} },
        call,
        &transcript,
        .{ .workdir = cwd },
        &.{},
        &.{secret_path},
        &.{},
        true,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("exit 0", result.summary);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session-read-deny-ok") != null);
}

fn disabledToolResult(allocator: std.mem.Allocator, call: api.FunctionCall) !tools.ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "disabled tool"),
        .output = try std.fmt.allocPrint(allocator, "{s} is disabled in this session", .{call.name}),
    };
}

fn mcpToolsEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("mcp_tools") orelse true;
}

fn mcpResourceToolsEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("mcp_resource_tools") orelse true;
}

fn writeStdinToolEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("write_stdin_tool") orelse true;
}

fn requestPermissionsToolEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("request_permissions_tool") orelse false;
}

fn requestUserInputToolEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("request_user_input_tool") orelse false;
}

fn goalToolsEnabled(options: TurnOptions) bool {
    return options.feature_overrides.get("goal_tools") orelse false;
}

fn isGoalToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_goal") or
        std.mem.eql(u8, name, "create_goal") or
        std.mem.eql(u8, name, "update_goal");
}

const McpRuntimeProgressContext = struct {
    allocator: std.mem.Allocator,
    callback: ?McpToolCallProgressCallback,
    item_id: []const u8,
    server_name: []const u8,
    tool_name: []const u8,
};

fn handleMcpRuntimeProgress(ctx: *anyopaque, notification: mcp_runtime.ProgressNotification) !void {
    const context: *McpRuntimeProgressContext = @ptrCast(@alignCast(ctx));
    const callback = context.callback orelse return;
    const detail = try formatMcpRuntimeProgressDetail(context.allocator, notification.params_json);
    defer context.allocator.free(detail);
    const message = try std.fmt.allocPrint(
        context.allocator,
        "progress {s}.{s}: {s}",
        .{ context.server_name, context.tool_name, detail },
    );
    defer context.allocator.free(message);
    try callback.on_mcp_tool_call_progress(callback.ctx, context.item_id, message);
}

fn formatMcpRuntimeProgressDetail(allocator: std.mem.Allocator, params_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch {
        return allocator.dupe(u8, "update");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "update");
    const object = parsed.value.object;

    if (object.get("message")) |message| {
        if (message == .string and message.string.len > 0) {
            return allocator.dupe(u8, message.string);
        }
    }

    const progress_json = if (object.get("progress")) |progress|
        try std.json.Stringify.valueAlloc(allocator, progress, .{})
    else
        null;
    defer if (progress_json) |json| allocator.free(json);
    const total_json = if (object.get("total")) |total|
        try std.json.Stringify.valueAlloc(allocator, total, .{})
    else
        null;
    defer if (total_json) |json| allocator.free(json);

    if (progress_json) |progress| {
        if (total_json) |total| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ progress, total });
        }
        return allocator.dupe(u8, progress);
    }

    return allocator.dupe(u8, "update");
}

fn runRequestUserInputToolCall(
    allocator: std.mem.Allocator,
    call: api.FunctionCall,
    options: TurnOptions,
) !tools.ToolResult {
    const default_mode_enabled = options.feature_overrides.get("default_mode_request_user_input") orelse false;
    if (!options.plan_mode and !default_mode_enabled) {
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "request user input unavailable"),
            .output = try allocator.dupe(u8, "request_user_input is unavailable in Default mode"),
        };
    }

    const callback = options.request_user_input_callback orelse return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request user input unavailable"),
        .output = try allocator.dupe(u8, "request_user_input is not available in this session"),
    };

    if (!requestUserInputArgumentsAreValid(allocator, call.arguments)) {
        return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "request user input invalid"),
            .output = try allocator.dupe(u8, "request_user_input requires non-empty options for every question"),
        };
    }

    var response = callback.on_request_user_input_requested(callback.ctx, .{
        .call_id = call.call_id,
        .arguments_json = call.arguments,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "request user input failed"),
            .output = try std.fmt.allocPrint(allocator, "request_user_input failed: {s}", .{@errorName(err)}),
        },
    };
    defer response.deinit(allocator);

    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request user input completed"),
        .output = try allocator.dupe(u8, response.output_json),
    };
}

fn runGoalToolCall(
    allocator: std.mem.Allocator,
    call: api.FunctionCall,
    options: TurnOptions,
) !tools.ToolResult {
    const callback = options.goal_tool_callback orelse return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "goal tool unavailable"),
        .output = try allocator.dupe(u8, "goal tools are not available in this session"),
    };

    return callback.on_goal_tool_requested(callback.ctx, call) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "goal tool failed"),
            .output = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ call.name, @errorName(err) }),
        },
    };
}

fn requestUserInputArgumentsAreValid(allocator: std.mem.Allocator, arguments_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const questions = parsed.value.object.get("questions") orelse return false;
    if (questions != .array) return false;
    if (questions.array.items.len == 0) return false;
    for (questions.array.items) |question| {
        if (question != .object) return false;
        if (!jsonStringFieldIsPresent(question.object, "id")) return false;
        if (!jsonStringFieldIsPresent(question.object, "header")) return false;
        if (!jsonStringFieldIsPresent(question.object, "question")) return false;
        const options = question.object.get("options") orelse return false;
        if (options != .array) return false;
        if (options.array.items.len == 0) return false;
        for (options.array.items) |option| {
            if (option != .object) return false;
            if (!jsonStringFieldIsPresent(option.object, "label")) return false;
            if (!jsonStringFieldIsPresent(option.object, "description")) return false;
        }
    }
    return true;
}

fn jsonStringFieldIsPresent(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .string;
}

fn runRequestPermissionsToolCall(
    allocator: std.mem.Allocator,
    call: api.FunctionCall,
    options: TurnOptions,
    writable_roots: *std.ArrayList([]const u8),
    network_enabled: *bool,
) !tools.ToolResult {
    const callback = options.request_permissions_callback orelse return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request permissions unavailable"),
        .output = try allocator.dupe(u8, "request_permissions is not available in this session"),
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "request permissions invalid"),
            .output = try allocator.dupe(u8, "request_permissions handler received unsupported payload"),
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request permissions invalid"),
        .output = try allocator.dupe(u8, "request_permissions handler received unsupported payload"),
    };
    const permissions = parsed.value.object.get("permissions") orelse return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request permissions invalid"),
        .output = try allocator.dupe(u8, "request_permissions requires at least one permission"),
    };
    if (permissions != .object) return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request permissions invalid"),
        .output = try allocator.dupe(u8, "request_permissions requires at least one permission"),
    };
    const reason = if (parsed.value.object.get("reason")) |reason_value|
        if (reason_value == .string) reason_value.string else null
    else
        null;
    const cwd = options.workdir orelse ".";

    var response = callback.on_request_permissions_requested(callback.ctx, .{
        .call_id = call.call_id,
        .reason = reason,
        .arguments_json = call.arguments,
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .call_id = try allocator.dupe(u8, call.call_id),
            .summary = try allocator.dupe(u8, "request permissions failed"),
            .output = try std.fmt.allocPrint(allocator, "request_permissions failed: {s}", .{@errorName(err)}),
        },
    };
    defer response.deinit(allocator);

    for (response.writable_roots) |root| {
        if (stringListContains(writable_roots.items, root)) continue;
        const copy = try allocator.dupe(u8, root);
        writable_roots.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };
    }
    if (response.network_enabled) |enabled| {
        if (enabled) network_enabled.* = true;
    }

    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "request permissions completed"),
        .output = try allocator.dupe(u8, response.output_json),
    };
}

fn stringListContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
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
    try transcript.setGoal(allocator, .{
        .objective = "ship persistence",
        .status = "active",
        .token_budget = 1000,
        .tokens_used = 20,
        .time_used_seconds = 30,
        .created_at = 11,
        .updated_at = 12,
    });
    try transcript.appendUserMessage(allocator, "first");
    try transcript.appendAssistantMessage(allocator, "second");
    transcript.token_usage = .{
        .total = .{
            .input_tokens = 10,
            .cached_input_tokens = 2,
            .output_tokens = 5,
            .reasoning_output_tokens = 1,
            .total_tokens = 15,
        },
        .last = .{
            .input_tokens = 4,
            .cached_input_tokens = 1,
            .output_tokens = 3,
            .reasoning_output_tokens = 1,
            .total_tokens = 7,
        },
        .model_context_window = 200000,
    };
    transcript.token_usage_turn_index = 1;
    try transcript.replaceWithCompactedSummary(allocator, "summary");

    try std.testing.expectEqualStrings("demo title", transcript.title.?);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", transcript.id.?);
    try std.testing.expectEqualStrings("/tmp/demo", transcript.cwd.?);
    try std.testing.expectEqualStrings("main", transcript.git_branch.?);
    try std.testing.expectEqualStrings("ship persistence", transcript.goal.?.objective);
    try std.testing.expectEqualStrings("active", transcript.goal.?.status);
    try std.testing.expectEqual(@as(?i64, 1000), transcript.goal.?.token_budget);
    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.message, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("user", transcript.history.items[0].role.?);
    try std.testing.expectEqualStrings("input_text", transcript.history.items[0].content_type.?);
    try std.testing.expectEqualStrings("summary", transcript.history.items[0].text.?);
    try std.testing.expectEqual(@as(i64, 15), transcript.token_usage.?.total.total_tokens);
    try std.testing.expectEqual(@as(i64, 7), transcript.token_usage.?.last.total_tokens);
    try std.testing.expectEqual(@as(i64, 200000), transcript.token_usage.?.model_context_window.?);
    try std.testing.expectEqual(@as(?usize, null), transcript.token_usage_turn_index);
}

test "append user message with images records ordered content" {
    const allocator = std.testing.allocator;
    var transcript = Transcript{};
    defer transcript.deinit(allocator);
    const images = [_][]const u8{
        "data:image/png;base64,Zmlyc3Q=",
        "data:image/png;base64,c2Vjb25k",
    };

    try transcript.appendUserMessageWithImages(allocator, "describe", images[0..]);

    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    const item = transcript.history.items[0];
    try std.testing.expectEqualStrings("user", item.role.?);
    try std.testing.expectEqualStrings("describe", item.text.?);
    try std.testing.expectEqual(@as(usize, 3), item.content.len);
    try std.testing.expectEqualStrings("input_text", item.content[0].type);
    try std.testing.expectEqualStrings("describe", item.content[0].text.?);
    try std.testing.expectEqualStrings("input_image", item.content[1].type);
    try std.testing.expectEqualStrings("data:image/png;base64,Zmlyc3Q=", item.content[1].image_url.?);
    try std.testing.expectEqualStrings("auto", item.content[1].detail.?);
    try std.testing.expectEqualStrings("data:image/png;base64,c2Vjb25k", item.content[2].image_url.?);
}

test "append response history function call output accepts structured content items" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "function_call_output",
        \\  "call_id": "call-structured",
        \\  "output": [
        \\    {"type": "input_text", "text": "line one"},
        \\    {"type": "input_image", "image_url": "data:image/png;base64,AAA", "detail": "high"},
        \\    {"type": "input_text", "text": "   "},
        \\    {"type": "input_text", "text": "line two"}
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, parsed.value);

    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.function_call_output, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("call-structured", transcript.history.items[0].call_id.?);
    try std.testing.expectEqualStrings("line one\nline two", transcript.history.items[0].output.?);
    const output_content = transcript.history.items[0].output_content.?;
    try std.testing.expectEqual(@as(usize, 4), output_content.len);
    try std.testing.expectEqualStrings("input_text", output_content[0].type);
    try std.testing.expectEqualStrings("line one", output_content[0].text.?);
    try std.testing.expectEqualStrings("input_image", output_content[1].type);
    try std.testing.expectEqualStrings("data:image/png;base64,AAA", output_content[1].image_url.?);
    try std.testing.expectEqualStrings("high", output_content[1].detail.?);
    try std.testing.expectEqualStrings("line two", output_content[3].text.?);
}

test "append response history function call preserves namespace" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "function_call",
        \\  "call_id": "call-ns",
        \\  "namespace": "mcp__demo__",
        \\  "name": "echo",
        \\  "arguments": "{}"
        \\}
    , .{});
    defer parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, parsed.value);

    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.function_call, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("call-ns", transcript.history.items[0].call_id.?);
    try std.testing.expectEqualStrings("mcp__demo__", transcript.history.items[0].namespace.?);
    try std.testing.expectEqualStrings("echo", transcript.history.items[0].name.?);
}

test "append response history tool_search call and output" {
    const allocator = std.testing.allocator;
    var call_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "tool_search_call",
        \\  "call_id": "search-1",
        \\  "execution": "client",
        \\  "arguments": {"query": "echo"}
        \\}
    , .{});
    defer call_parsed.deinit();
    var output_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "tool_search_output",
        \\  "call_id": "search-1",
        \\  "status": "completed",
        \\  "execution": "client",
        \\  "tools": [{"type": "namespace", "name": "mcp__demo__"}]
        \\}
    , .{});
    defer output_parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, call_parsed.value);
    try appendResponseHistoryItem(allocator, &transcript, output_parsed.value);

    try std.testing.expectEqual(@as(usize, 2), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.tool_search_call, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("search-1", transcript.history.items[0].call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, transcript.history.items[0].arguments.?, "\"query\":\"echo\"") != null);
    try std.testing.expectEqual(api.HistoryItem.Kind.tool_search_output, transcript.history.items[1].kind);
    try std.testing.expectEqualStrings("search-1", transcript.history.items[1].call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, transcript.history.items[1].output.?, "\"name\":\"mcp__demo__\"") != null);
}

test "append response history skips server tool_search items with null call id" {
    const allocator = std.testing.allocator;
    var call_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "tool_search_call",
        \\  "call_id": null,
        \\  "status": "completed",
        \\  "execution": "server",
        \\  "arguments": {"paths": ["crm"]}
        \\}
    , .{});
    defer call_parsed.deinit();
    var output_parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "tool_search_output",
        \\  "call_id": null,
        \\  "status": "completed",
        \\  "execution": "server",
        \\  "tools": []
        \\}
    , .{});
    defer output_parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, call_parsed.value);
    try appendResponseHistoryItem(allocator, &transcript, output_parsed.value);

    try std.testing.expectEqual(@as(usize, 0), transcript.history.items.len);
}

test "append response history message joins text content items" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "output_text", "text": "first fragment"},
        \\    {"type": "input_image", "image_url": "https://example.invalid/context.png", "detail": "high"},
        \\    {"type": "output_text", "text": "  "},
        \\    {"type": "output_text", "text": "second fragment"}
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, parsed.value);

    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqual(api.HistoryItem.Kind.message, transcript.history.items[0].kind);
    try std.testing.expectEqualStrings("assistant", transcript.history.items[0].role.?);
    try std.testing.expectEqualStrings("output_text", transcript.history.items[0].content_type.?);
    try std.testing.expectEqualStrings("first fragment\nsecond fragment", transcript.history.items[0].text.?);
    try std.testing.expectEqual(@as(usize, 4), transcript.history.items[0].content.len);
    try std.testing.expectEqualStrings("first fragment", transcript.history.items[0].content[0].text.?);
    try std.testing.expectEqualStrings("https://example.invalid/context.png", transcript.history.items[0].content[1].image_url.?);
    try std.testing.expectEqualStrings("high", transcript.history.items[0].content[1].detail.?);
    try std.testing.expectEqualStrings("  ", transcript.history.items[0].content[2].text.?);
    try std.testing.expectEqualStrings("second fragment", transcript.history.items[0].content[3].text.?);
}

test "append response history function call output preserves image content items" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "function_call_output",
        \\  "call_id": "call-image",
        \\  "output": [
        \\    {"type": "input_image", "image_url": "file:///tmp/out.png", "detail": null}
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try appendResponseHistoryItem(allocator, &transcript, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), transcript.history.items.len);
    try std.testing.expectEqualStrings("call-image", transcript.history.items[0].call_id.?);
    try std.testing.expectEqualStrings("", transcript.history.items[0].output.?);
    try std.testing.expectEqual(@as(usize, 1), transcript.history.items[0].output_content.?.len);
    try std.testing.expectEqualStrings("file:///tmp/out.png", transcript.history.items[0].output_content.?[0].image_url.?);
    try std.testing.expect(transcript.history.items[0].output_content.?[0].detail == null);
}

test "append response history function call output rejects unsupported content items" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "type": "function_call_output",
        \\  "call_id": "call-unsupported",
        \\  "output": [
        \\    {"type": "output_text", "text": "not valid here"}
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try std.testing.expectError(error.InvalidHistory, appendResponseHistoryItem(allocator, &transcript, parsed.value));
    try std.testing.expectEqual(@as(usize, 0), transcript.history.items.len);
}

test "clone transcript copies title and history" {
    const allocator = std.testing.allocator;
    var transcript = Transcript{};
    defer transcript.deinit(allocator);

    try transcript.setTitle(allocator, "source title");
    try transcript.setGoal(allocator, .{
        .objective = "clone goal",
        .status = "paused",
        .token_budget = null,
        .tokens_used = 5,
        .time_used_seconds = 6,
        .created_at = 7,
        .updated_at = 8,
    });
    try transcript.appendUserMessage(allocator, "hello");

    var copy = try transcript.clone(allocator);
    defer copy.deinit(allocator);

    try std.testing.expectEqualStrings("source title", copy.title.?);
    try std.testing.expectEqualStrings("clone goal", copy.goal.?.objective);
    try std.testing.expectEqualStrings("paused", copy.goal.?.status);
    try std.testing.expectEqual(@as(i64, 5), copy.goal.?.tokens_used);
    try std.testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try std.testing.expectEqualStrings("hello", copy.history.items[0].text.?);

    try transcript.setTitle(allocator, "changed title");
    transcript.clearGoal(allocator);
    try transcript.appendAssistantMessage(allocator, "later");

    try std.testing.expectEqualStrings("source title", copy.title.?);
    try std.testing.expectEqualStrings("clone goal", copy.goal.?.objective);
    try std.testing.expectEqual(@as(usize, 1), copy.history.items.len);
    try std.testing.expectEqualStrings("hello", copy.history.items[0].text.?);
}
