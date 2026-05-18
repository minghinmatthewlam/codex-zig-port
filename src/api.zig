const std = @import("std");

const agents_md = @import("agents_md.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const features_cmd = @import("features_cmd.zig");
const model_catalog = @import("model_catalog.zig");
const mcp_runtime = @import("mcp_runtime.zig");

pub const FunctionCall = struct {
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: FunctionCall, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const ReasoningEventKind = enum {
    summary_text_delta,
    summary_part_added,
    text_delta,
};

pub const ReasoningEvent = struct {
    kind: ReasoningEventKind,
    item_id: []const u8,
    delta: []const u8,
    index: i64,

    pub fn deinit(self: ReasoningEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.item_id);
        allocator.free(self.delta);
    }
};

pub const ModelVerification = enum {
    trusted_access_for_cyber,

    pub fn label(self: ModelVerification) []const u8 {
        return switch (self) {
            .trusted_access_for_cyber => "trustedAccessForCyber",
        };
    }
};

pub const ParsedResponse = struct {
    text: []const u8,
    function_calls: []FunctionCall,
    raw_response_items: []const []const u8,
    reasoning_events: []const ReasoningEvent,
    server_model: ?[]const u8,
    model_verifications: []const ModelVerification,

    pub fn deinit(self: *ParsedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.function_calls) |call| call.deinit(allocator);
        allocator.free(self.function_calls);
        for (self.raw_response_items) |item| allocator.free(item);
        allocator.free(self.raw_response_items);
        for (self.reasoning_events) |event| event.deinit(allocator);
        allocator.free(self.reasoning_events);
        if (self.server_model) |server_model| allocator.free(server_model);
        allocator.free(self.model_verifications);
    }
};

pub const StreamCallback = struct {
    ctx: *anyopaque,
    on_text_delta: *const fn (ctx: *anyopaque, delta: []const u8) anyerror!void,
};

pub const CreateTurnOptions = struct {
    stream_callback: ?StreamCallback = null,
    output_schema: ?std.json.Value = null,
    input_images: []const []const u8 = &.{},
    mcp_tools: []const mcp_runtime.ToolSpec = &.{},
    include_tools: bool = true,
    feature_overrides: features_cmd.FeatureOverrides = .{},
};

pub const HistoryItem = struct {
    kind: Kind,
    role: ?[]const u8 = null,
    text: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,

    pub fn deinit(self: HistoryItem, allocator: std.mem.Allocator) void {
        if (self.role) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.content_type) |value| allocator.free(value);
        if (self.call_id) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
        if (self.arguments) |value| allocator.free(value);
        if (self.output) |value| allocator.free(value);
    }

    pub const Kind = enum {
        message,
        function_call,
        function_call_output,
    };
};

const ContentItem = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

const InputItem = struct {
    type: []const u8,
    role: ?[]const u8 = null,
    content: ?[]const ContentItem = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

const Tool = struct {
    type: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
    external_web_access: ?bool = null,
};

const Request = struct {
    model: []const u8,
    instructions: []const u8,
    input: []const InputItem,
    tools: []const Tool,
    text: ?TextControls = null,
    tool_choice: []const u8 = "auto",
    parallel_tool_calls: bool = false,
    reasoning: ?Reasoning = null,
    service_tier: ?[]const u8 = null,
    store: bool = false,
    stream: bool = true,
    include: []const []const u8,
    prompt_cache_key: []const u8,
    client_metadata: ClientMetadata,
};

const Reasoning = struct {
    effort: []const u8 = "medium",
    summary: []const u8 = "auto",
};

const ClientMetadata = struct {
    @"x-codex-installation-id": []const u8,
};

const TextControls = struct {
    verbosity: ?[]const u8 = null,
    format: ?TextFormat = null,
};

const TextFormat = struct {
    type: []const u8 = "json_schema",
    name: []const u8 = "codex_output_schema",
    schema: std.json.Value,
    strict: bool = true,
};

pub fn createTurn(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    history: []const HistoryItem,
) !ParsedResponse {
    return createTurnWithOptions(allocator, cfg, credentials, history, .{});
}

pub fn createTurnWithOptions(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: *auth.Credentials,
    history: []const HistoryItem,
    options: CreateTurnOptions,
) !ParsedResponse {
    const body = try buildRequestBodyWithOptions(allocator, cfg, history, .{
        .output_schema = options.output_schema,
        .input_images = options.input_images,
        .mcp_tools = options.mcp_tools,
        .include_tools = options.include_tools,
        .feature_overrides = options.feature_overrides,
    });
    defer allocator.free(body);

    if (cfg.model_provider_auth_command) |command| {
        try auth.refreshProviderCommandCredentialsIfExpired(allocator, credentials, command);
    }

    const base_url = switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => cfg.chatgpt_base_url,
        .api_key, .local_oss => cfg.openai_base_url,
    };
    const wire_path = switch (cfg.model_provider_wire_api) {
        .responses => "responses",
    };
    const url = try buildProviderUrl(allocator, base_url, wire_path, cfg.model_provider_query_params);
    defer allocator.free(url);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response = try fetchTurn(allocator, &client, url, body, cfg, credentials.*, options.stream_callback);
    defer response.deinit(allocator);

    if (response.status == .unauthorized) {
        if (cfg.model_provider_auth_command) |command| {
            try auth.refreshProviderCommandCredentials(allocator, credentials, command);
            var retry_response = try fetchTurn(allocator, &client, url, body, cfg, credentials.*, options.stream_callback);
            defer retry_response.deinit(allocator);
            if (@intFromEnum(retry_response.status) < 200 or @intFromEnum(retry_response.status) >= 300) {
                std.debug.print("Responses API error status {d}: {s}\n", .{ @intFromEnum(retry_response.status), retry_response.body });
                return error.ApiRequestFailed;
            }
            return parseSseResponseWithHttpModel(allocator, retry_response.body, retry_response.server_model);
        }
    }

    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) {
        std.debug.print("Responses API error status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return error.ApiRequestFailed;
    }

    return parseSseResponseWithHttpModel(allocator, response.body, response.server_model);
}

const ApiFetchResponse = struct {
    status: std.http.Status,
    body: []u8,
    server_model: ?[]const u8,

    fn deinit(self: ApiFetchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.server_model) |server_model| allocator.free(server_model);
    }
};

fn fetchTurn(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    cfg: config.Config,
    credentials: auth.Credentials,
    stream_callback: ?StreamCallback,
) !ApiFetchResponse {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var provider_env_header_values = std.ArrayList([]const u8).empty;
    defer {
        for (provider_env_header_values.items) |value| allocator.free(value);
        provider_env_header_values.deinit(allocator);
    }
    if (credentials.mode != .local_oss) {
        auth_header = try auth.authorizationHeader(allocator, credentials);
        try headers.append(allocator, .{ .name = "Authorization", .value = auth_header.? });
    }
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "text/event-stream" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    try appendProviderHeaders(allocator, &headers, &provider_env_header_values, cfg);
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-ID", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var response_body = try StreamingResponseWriter.init(allocator, stream_callback);
    defer response_body.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    var request_body = try request.sendBodyUnflushed(&.{});
    try request_body.writer.writeAll(body);
    try request_body.end();
    try request.connection.?.flush();

    var response_head_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&response_head_buffer);
    const server_model = try serverModelFromHttpHeaders(allocator, response.head);
    errdefer if (server_model) |model| allocator.free(model);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&response_body.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| {
            if (response_body.failure) |failure| return failure;
            return e;
        },
    };

    if (response_body.failure) |err| return err;
    try response_body.finish();

    return .{
        .status = response.head.status,
        .body = try response_body.toOwnedSlice(),
        .server_model = server_model,
    };
}

fn serverModelFromHttpHeaders(allocator: std.mem.Allocator, head: std.http.Client.Response.Head) !?[]const u8 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "openai-model") and
            !std.ascii.eqlIgnoreCase(header.name, "x-openai-model"))
        {
            continue;
        }
        if (header.value.len == 0) continue;
        return try allocator.dupe(u8, header.value);
    }
    return null;
}

fn buildProviderUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    path: []const u8,
    query_params: ?config.StringMap,
) ![]const u8 {
    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, std.mem.trimEnd(u8, base_url, "/"));
    var path_start: usize = 0;
    while (path_start < path.len and path[path_start] == '/') : (path_start += 1) {}
    const trimmed_path = path[path_start..];
    if (trimmed_path.len > 0) {
        try url.append(allocator, '/');
        try url.appendSlice(allocator, trimmed_path);
    }
    if (query_params) |params| {
        if (params.entries.len > 0) {
            try url.append(allocator, '?');
            for (params.entries, 0..) |entry, index| {
                if (index > 0) try url.append(allocator, '&');
                try url.appendSlice(allocator, entry.key);
                try url.append(allocator, '=');
                try url.appendSlice(allocator, entry.value);
            }
        }
    }

    return url.toOwnedSlice(allocator);
}

fn appendProviderHeaders(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(std.http.Header),
    owned_env_values: *std.ArrayList([]const u8),
    cfg: config.Config,
) !void {
    if (cfg.model_provider_http_headers) |header_map| {
        for (header_map.entries) |entry| {
            try headers.append(allocator, .{ .name = entry.key, .value = entry.value });
        }
    }
    if (cfg.model_provider_env_http_headers) |header_map| {
        for (header_map.entries) |entry| {
            const value = try env.getOwnedDynamic(allocator, entry.value);
            if (value) |owned| {
                if (std.mem.trim(u8, owned, " \t\r\n").len == 0) {
                    allocator.free(owned);
                    continue;
                }
                owned_env_values.append(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
                try headers.append(allocator, .{ .name = entry.key, .value = owned });
            }
        }
    }
}

const StreamingResponseWriter = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    writer: std.Io.Writer,
    raw: std.ArrayList(u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    callback: ?StreamCallback,
    failure: ?anyerror = null,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn init(allocator: std.mem.Allocator, callback: ?StreamCallback) !StreamingResponseWriter {
        const buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .writer = .{
                .buffer = buffer,
                .vtable = &vtable,
            },
            .callback = callback,
        };
    }

    fn deinit(self: *StreamingResponseWriter) void {
        self.allocator.free(self.buffer);
        self.raw.deinit(self.allocator);
        self.line.deinit(self.allocator);
    }

    fn finish(self: *StreamingResponseWriter) !void {
        try self.writer.flush();
        if (self.line.items.len > 0) {
            try self.processLine(self.line.items);
            self.line.clearRetainingCapacity();
        }
    }

    fn toOwnedSlice(self: *StreamingResponseWriter) ![]u8 {
        return self.raw.toOwnedSlice(self.allocator);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamingResponseWriter = @fieldParentPtr("writer", w);
        var written: usize = 0;

        if (w.end > 0) {
            self.ingest(w.buffer[0..w.end]) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            w.end = 0;
        }

        for (data[0 .. data.len - 1]) |bytes| {
            self.ingest(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            written += bytes.len;
        }

        const pattern = data[data.len - 1];
        var repeat_index: usize = 0;
        while (repeat_index < splat) : (repeat_index += 1) {
            self.ingest(pattern) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            written += pattern.len;
        }

        return written;
    }

    fn ingest(self: *StreamingResponseWriter, bytes: []const u8) !void {
        try self.raw.appendSlice(self.allocator, bytes);
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(self.line.items);
                self.line.clearRetainingCapacity();
            } else {
                try self.line.append(self.allocator, byte);
            }
        }
    }

    fn processLine(self: *StreamingResponseWriter, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const data = std.mem.trim(u8, line[5..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };
        const event_type = object.get("type") orelse return;
        if (event_type != .string) return;
        if (!std.mem.eql(u8, event_type.string, "response.output_text.delta")) return;

        const delta = object.get("delta") orelse return;
        if (delta != .string or delta.string.len == 0) return;
        if (self.callback) |callback| {
            try callback.on_text_delta(callback.ctx, delta.string);
        }
    }
};

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    history: []const HistoryItem,
) ![]const u8 {
    return buildRequestBodyWithOptions(allocator, cfg, history, .{});
}

pub const RequestBodyOptions = struct {
    output_schema: ?std.json.Value = null,
    input_images: []const []const u8 = &.{},
    mcp_tools: []const mcp_runtime.ToolSpec = &.{},
    include_tools: bool = true,
    feature_overrides: features_cmd.FeatureOverrides = .{},
};

fn latestUserMessageIndex(history: []const HistoryItem) ?usize {
    var latest: ?usize = null;
    for (history, 0..) |item, index| {
        if (item.kind != .message) continue;
        const role = item.role orelse continue;
        if (std.mem.eql(u8, role, "user")) latest = index;
    }
    return latest;
}

pub fn buildRequestBodyWithOptions(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    history: []const HistoryItem,
    options: RequestBodyOptions,
) ![]const u8 {
    var inputs = std.ArrayList(InputItem).empty;
    defer inputs.deinit(allocator);

    const image_message_index = latestUserMessageIndex(history);
    var message_contents = std.ArrayList([]ContentItem).empty;
    defer {
        for (message_contents.items) |content| allocator.free(content);
        message_contents.deinit(allocator);
    }

    for (history, 0..) |item, history_index| {
        switch (item.kind) {
            .message => {
                const role = item.role orelse return error.InvalidMessageHistory;
                const text = item.text orelse return error.InvalidMessageHistory;
                const content_type = item.content_type orelse return error.InvalidMessageHistory;

                const include_images = image_message_index != null and
                    image_message_index.? == history_index and
                    options.input_images.len > 0;
                const content_len: usize = if (include_images) 1 + options.input_images.len else 1;
                const content = try allocator.alloc(ContentItem, content_len);
                var content_owned = true;
                errdefer if (content_owned) allocator.free(content);
                content[0] = .{
                    .type = content_type,
                    .text = text,
                };
                if (include_images) {
                    for (options.input_images, 0..) |image_url, image_index| {
                        content[1 + image_index] = .{
                            .type = "input_image",
                            .image_url = image_url,
                            .detail = "auto",
                        };
                    }
                }
                try message_contents.append(allocator, content);
                content_owned = false;
                try inputs.append(allocator, .{
                    .type = "message",
                    .role = role,
                    .content = content,
                });
            },
            .function_call => try inputs.append(allocator, .{
                .type = "function_call",
                .call_id = item.call_id,
                .name = item.name,
                .arguments = item.arguments,
            }),
            .function_call_output => try inputs.append(allocator, .{
                .type = "function_call_output",
                .call_id = item.call_id,
                .output = item.output,
            }),
        }
    }

    var parsed_parameter_values = std.ArrayList(std.json.Parsed(std.json.Value)).empty;
    defer {
        for (parsed_parameter_values.items) |*parsed| parsed.deinit();
        parsed_parameter_values.deinit(allocator);
    }

    var tools_list = std.ArrayList(Tool).empty;
    defer tools_list.deinit(allocator);
    const shell_tools_enabled = options.feature_overrides.get("shell_tool") orelse true;
    const request_permissions_tool_enabled = options.feature_overrides.get("request_permissions_tool") orelse false;
    const request_user_input_tool_enabled = options.feature_overrides.get("request_user_input_tool") orelse false;
    const default_mode_request_user_input_enabled = options.feature_overrides.get("default_mode_request_user_input") orelse false;
    if (options.include_tools) {
        const shell_tool = Tool{
            .type = "function",
            .name = "shell",
            .description = "Run a command as an argv array in the current workspace.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"command":{"type":"array","description":"Command and arguments to execute.","items":{"type":"string"}}},"required":["command"],"additionalProperties":false}
            ),
        };
        const exec_command_tool = Tool{
            .type = "function",
            .name = "exec_command",
            .description = "Runs a shell command, returning terminal-style output. Set tty=true for a PTY-backed long-running session that can receive input through write_stdin.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"cmd":{"type":"string","description":"Shell command to execute."},"workdir":{"type":"string","description":"Optional working directory to run the command in; defaults to the current workspace."},"shell":{"type":"string","description":"Shell binary to launch. Defaults to /bin/zsh."},"tty":{"type":"boolean","description":"When true, start a PTY-backed long-running session instead of waiting for completion."},"yield_time_ms":{"type":"number","description":"Milliseconds to wait for initial session output when tty=true; one-shot exec waits for completion."},"max_output_tokens":{"type":"number","description":"Maximum approximate tokens to return. Excess output is truncated."},"login":{"type":"boolean","description":"Whether to run the shell with login semantics."}},"required":["cmd"],"additionalProperties":false}
            ),
        };
        const write_stdin_tool = Tool{
            .type = "function",
            .name = "write_stdin",
            .description = "Writes input to a running exec_command session and returns any new output.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"session_id":{"type":"number","description":"Session ID returned by exec_command when tty=true."},"chars":{"type":"string","description":"Literal text to write to the session stdin."},"yield_time_ms":{"type":"number","description":"Milliseconds to wait for output after writing."},"max_output_tokens":{"type":"number","description":"Maximum approximate tokens to return. Excess output is truncated."}},"required":["session_id"],"additionalProperties":false}
            ),
        };
        const shell_command_tool = Tool{
            .type = "function",
            .name = "shell_command",
            .description = "Run a shell command string in the current workspace.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute."}},"required":["command"],"additionalProperties":false}
            ),
        };
        const apply_patch_tool = Tool{
            .type = "function",
            .name = "apply_patch",
            .description = "Apply a Codex-style patch to files in the current workspace. The patch must start with *** Begin Patch and end with *** End Patch.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"patch":{"type":"string","description":"Patch text with Add File, Update File, or Delete File sections."}},"required":["patch"],"additionalProperties":false}
            ),
        };
        const update_plan_tool = Tool{
            .type = "function",
            .name = "update_plan",
            .description = "Update the visible task plan with ordered items and statuses.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"explanation":{"type":"string","description":"Optional short explanation for the plan update."},"plan":{"type":"array","description":"Ordered plan items.","items":{"type":"object","properties":{"step":{"type":"string","description":"A concise task step."},"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Current status for the step."}},"required":["step","status"],"additionalProperties":false}}},"required":["plan"],"additionalProperties":false}
            ),
        };
        const request_permissions_tool = Tool{
            .type = "function",
            .name = "request_permissions",
            .description = "Request additional filesystem or network permissions from the user and wait for the client to grant a subset of the requested permission profile. Granted permissions apply automatically to later shell-like commands in the current turn, or for the rest of the session if the client approves them at session scope.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"reason":{"type":"string","description":"Optional short explanation for why additional permissions are needed."},"permissions":{"type":"object","properties":{"network":{"type":"object","properties":{"enabled":{"type":"boolean"}},"additionalProperties":false},"file_system":{"type":"object","properties":{"read":{"type":"array","items":{"type":"string"}},"write":{"type":"array","items":{"type":"string"}}},"additionalProperties":false}},"required":["permissions"],"additionalProperties":false}},"required":["permissions"],"additionalProperties":false}
            ),
        };
        const request_user_input_tool = Tool{
            .type = "function",
            .name = "request_user_input",
            .description = if (default_mode_request_user_input_enabled)
                "Request user input for one to three short questions and wait for the response. This tool is only available in Default or Plan mode."
            else
                "Request user input for one to three short questions and wait for the response. This tool is only available in Plan mode.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"questions":{"type":"array","description":"Questions to show the user. Prefer 1 and do not exceed 3","items":{"type":"object","properties":{"id":{"type":"string","description":"Stable identifier for mapping answers (snake_case)."},"header":{"type":"string","description":"Short header label shown in the UI (12 or fewer chars)."},"question":{"type":"string","description":"Single-sentence prompt shown to the user."},"options":{"type":"array","description":"Provide 2-3 mutually exclusive choices. Put the recommended option first and suffix its label with \"(Recommended)\". Do not include an \"Other\" option in this list; the client will add a free-form \"Other\" option automatically.","items":{"type":"object","properties":{"label":{"type":"string","description":"User-facing label (1-5 words)."},"description":{"type":"string","description":"One short sentence explaining impact/tradeoff if selected."}},"required":["label","description"],"additionalProperties":false}}},"required":["id","header","question","options"],"additionalProperties":false}}},"required":["questions"],"additionalProperties":false}
            ),
        };
        const list_mcp_resources_tool = Tool{
            .type = "function",
            .name = "list_mcp_resources",
            .description = "Lists resources provided by MCP servers. Resources allow servers to share data that provides context to language models, such as files, database schemas, or application-specific information. Prefer resources over web search when possible.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"server":{"type":"string","description":"Optional MCP server name. When omitted, lists resources from every configured server."},"cursor":{"type":"string","description":"Opaque cursor returned by a previous list_mcp_resources call for the same server."}},"additionalProperties":false}
            ),
        };
        const list_mcp_resource_templates_tool = Tool{
            .type = "function",
            .name = "list_mcp_resource_templates",
            .description = "Lists resource templates provided by MCP servers. Parameterized resource templates allow servers to share data that takes parameters and provides context to language models, such as files, database schemas, or application-specific information. Prefer resource templates over web search when possible.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"server":{"type":"string","description":"Optional MCP server name. When omitted, lists resource templates from all configured servers."},"cursor":{"type":"string","description":"Opaque cursor returned by a previous list_mcp_resource_templates call for the same server."}},"additionalProperties":false}
            ),
        };
        const read_mcp_resource_tool = Tool{
            .type = "function",
            .name = "read_mcp_resource",
            .description = "Read a specific resource from an MCP server given the server name and resource URI.",
            .parameters = try appendParsedJsonValue(allocator, &parsed_parameter_values,
                \\{"type":"object","properties":{"server":{"type":"string","description":"MCP server name exactly as configured. Must match the 'server' field returned by list_mcp_resources."},"uri":{"type":"string","description":"Resource URI to read. Must be one of the URIs returned by list_mcp_resources."}},"required":["server","uri"],"additionalProperties":false}
            ),
        };
        if (shell_tools_enabled) {
            try tools_list.append(allocator, exec_command_tool);
            try tools_list.append(allocator, write_stdin_tool);
            try tools_list.append(allocator, shell_tool);
            try tools_list.append(allocator, shell_command_tool);
        }
        try tools_list.append(allocator, apply_patch_tool);
        try tools_list.append(allocator, update_plan_tool);
        if (request_permissions_tool_enabled) {
            try tools_list.append(allocator, request_permissions_tool);
        }
        if (request_user_input_tool_enabled) {
            try tools_list.append(allocator, request_user_input_tool);
        }
        try tools_list.append(allocator, list_mcp_resources_tool);
        try tools_list.append(allocator, list_mcp_resource_templates_tool);
        try tools_list.append(allocator, read_mcp_resource_tool);
        if (cfg.web_search_mode) |web_search_mode| {
            if (web_search_mode.externalWebAccess()) |external_web_access| {
                try tools_list.append(allocator, .{
                    .type = "web_search",
                    .external_web_access = external_web_access,
                });
            }
        }
        for (options.mcp_tools) |mcp_tool| {
            const parameters = appendParsedJsonValue(allocator, &parsed_parameter_values, mcp_tool.input_schema_json) catch
                try appendParsedJsonValue(allocator, &parsed_parameter_values, "{\"type\":\"object\"}");
            const description = if (mcp_tool.description.len > 0)
                mcp_tool.description
            else
                "Call a configured MCP server tool.";
            try tools_list.append(allocator, .{
                .type = "function",
                .name = mcp_tool.callable_name,
                .description = description,
                .parameters = parameters,
            });
        }
    }
    const include = [_][]const u8{};

    const base_instructions = try baseInstructionsForConfig(allocator, cfg, shell_tools_enabled);
    defer allocator.free(base_instructions);
    const instructions = try agents_md.buildInstructions(allocator, base_instructions);
    defer allocator.free(instructions);

    const verbosity = verbosityForRequest(cfg);
    const text_controls: ?TextControls = if (options.output_schema != null or verbosity != null)
        .{
            .verbosity = verbosity,
            .format = if (options.output_schema) |schema| .{ .schema = schema } else null,
        }
    else
        null;

    const reasoning_effort = if (cfg.model_reasoning_effort) |effort| effort.label() else "medium";
    const reasoning_summary = if (cfg.model_reasoning_summary) |summary| summary.label() else "auto";
    const req = Request{
        .model = cfg.model,
        .instructions = instructions,
        .input = inputs.items,
        .tools = tools_list.items,
        .text = text_controls,
        .reasoning = .{ .effort = reasoning_effort, .summary = reasoning_summary },
        .service_tier = cfg.service_tier,
        .include = include[0..],
        .prompt_cache_key = cfg.installation_id,
        .client_metadata = .{ .@"x-codex-installation-id" = cfg.installation_id },
    };
    return std.json.Stringify.valueAlloc(allocator, req, .{ .emit_null_optional_fields = false });
}

fn verbosityForRequest(cfg: config.Config) ?[]const u8 {
    const model = model_catalog.bundledModel(cfg.model) orelse return null;
    if (!model.support_verbosity) return null;
    if (cfg.model_verbosity) |verbosity| return verbosity.label();
    return model.default_verbosity;
}

fn appendParsedJsonValue(
    allocator: std.mem.Allocator,
    parsed_values: *std.ArrayList(std.json.Parsed(std.json.Value)),
    bytes: []const u8,
) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed_values.append(allocator, parsed);
    return parsed_values.items[parsed_values.items.len - 1].value;
}

pub fn parseSseResponse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedResponse {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var calls = std.ArrayList(FunctionCall).empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }
    var raw_response_items = std.ArrayList([]const u8).empty;
    errdefer {
        for (raw_response_items.items) |item| allocator.free(item);
        raw_response_items.deinit(allocator);
    }
    var reasoning_events = std.ArrayList(ReasoningEvent).empty;
    errdefer {
        for (reasoning_events.items) |event| event.deinit(allocator);
        reasoning_events.deinit(allocator);
    }
    var server_model: ?[]const u8 = null;
    errdefer if (server_model) |model| allocator.free(model);
    var model_verifications = std.ArrayList(ModelVerification).empty;
    errdefer model_verifications.deinit(allocator);

    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line[5..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const event_type = object.get("type") orelse continue;
        if (event_type != .string) continue;

        if (server_model == null) {
            server_model = try parseServerModel(allocator, object);
        }
        if (std.mem.eql(u8, event_type.string, "response.metadata")) {
            try appendModelVerifications(&model_verifications, allocator, object);
        }

        if (std.mem.eql(u8, event_type.string, "response.output_text.delta")) {
            if (object.get("delta")) |delta| {
                if (delta == .string) try text.appendSlice(allocator, delta.string);
            }
        } else if (try parseReasoningEvent(allocator, event_type.string, object)) |reasoning_event| {
            try reasoning_events.append(allocator, reasoning_event);
        } else if (std.mem.eql(u8, event_type.string, "response.failed")) {
            return error.ApiResponseFailed;
        } else if (std.mem.eql(u8, event_type.string, "response.output_item.done")) {
            const item_value = object.get("item") orelse continue;
            if (item_value != .object) continue;
            const item_json = try std.json.Stringify.valueAlloc(allocator, item_value, .{});
            var item_json_moved = false;
            errdefer if (!item_json_moved) allocator.free(item_json);
            try raw_response_items.append(allocator, item_json);
            item_json_moved = true;
            const item = item_value.object;
            const item_type = item.get("type") orelse continue;
            if (item_type != .string) continue;
            if (!std.mem.eql(u8, item_type.string, "function_call")) continue;

            const call_id = item.get("call_id") orelse continue;
            const name = item.get("name") orelse continue;
            const arguments = item.get("arguments") orelse continue;
            if (call_id != .string or name != .string or arguments != .string) continue;
            try calls.append(allocator, .{
                .call_id = try allocator.dupe(u8, call_id.string),
                .name = try allocator.dupe(u8, name.string),
                .arguments = try allocator.dupe(u8, arguments.string),
            });
        }
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .function_calls = try calls.toOwnedSlice(allocator),
        .raw_response_items = try raw_response_items.toOwnedSlice(allocator),
        .reasoning_events = try reasoning_events.toOwnedSlice(allocator),
        .server_model = server_model,
        .model_verifications = try model_verifications.toOwnedSlice(allocator),
    };
}

fn parseSseResponseWithHttpModel(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    http_server_model: ?[]const u8,
) !ParsedResponse {
    var parsed = try parseSseResponse(allocator, bytes);
    errdefer parsed.deinit(allocator);
    if (parsed.server_model == null) {
        if (http_server_model) |server_model| {
            parsed.server_model = try allocator.dupe(u8, server_model);
        }
    }
    return parsed;
}

fn parseServerModel(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    if (object.get("response")) |response| {
        if (response == .object) {
            if (try parseServerModelFromObject(allocator, response.object)) |model| return model;
        }
    }
    return parseServerModelFromObject(allocator, object);
}

fn parseServerModelFromObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    const headers = object.get("headers") orelse return null;
    if (headers != .object) return null;

    var iterator = headers.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.ascii.eqlIgnoreCase(name, "openai-model") and
            !std.ascii.eqlIgnoreCase(name, "x-openai-model"))
        {
            continue;
        }
        const model = jsonStringOrFirstArrayString(entry.value_ptr.*) orelse continue;
        if (model.len == 0) continue;
        return try allocator.dupe(u8, model);
    }
    return null;
}

fn jsonStringOrFirstArrayString(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |string| return string,
        .array => |array| {
            if (array.items.len == 0) return null;
            const first = array.items[0];
            if (first != .string) return null;
            return first.string;
        },
        else => return null,
    }
}

fn appendModelVerifications(
    verifications: *std.ArrayList(ModelVerification),
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !void {
    const metadata = object.get("metadata") orelse return;
    if (metadata != .object) return;
    const recommendation = metadata.object.get("openai_verification_recommendation") orelse return;
    if (recommendation != .array) return;

    for (recommendation.array.items) |item| {
        if (item != .string) continue;
        const verification = parseModelVerification(item.string) orelse continue;
        if (containsModelVerification(verifications.items, verification)) continue;
        try verifications.append(allocator, verification);
    }
}

fn parseModelVerification(raw: []const u8) ?ModelVerification {
    if (std.mem.eql(u8, raw, "trusted_access_for_cyber")) return .trusted_access_for_cyber;
    if (std.mem.eql(u8, raw, "trustedAccessForCyber")) return .trusted_access_for_cyber;
    return null;
}

fn containsModelVerification(verifications: []const ModelVerification, needle: ModelVerification) bool {
    for (verifications) |verification| {
        if (verification == needle) return true;
    }
    return false;
}

fn parseReasoningEvent(
    allocator: std.mem.Allocator,
    event_type: []const u8,
    object: std.json.ObjectMap,
) !?ReasoningEvent {
    const kind: ReasoningEventKind = if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta"))
        .summary_text_delta
    else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added"))
        .summary_part_added
    else if (std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        .text_delta
    else
        return null;

    const item_id = jsonStringFieldAny(object, "item_id", "itemId") orelse return null;
    const index = switch (kind) {
        .summary_text_delta, .summary_part_added => jsonIntegerFieldAny(object, "summary_index", "summaryIndex") orelse return null,
        .text_delta => jsonIntegerFieldAny(object, "content_index", "contentIndex") orelse return null,
    };
    const delta = switch (kind) {
        .summary_text_delta, .text_delta => jsonStringFieldAny(object, "delta", "delta") orelse return null,
        .summary_part_added => "",
    };
    const owned_item_id = try allocator.dupe(u8, item_id);
    errdefer allocator.free(owned_item_id);

    return .{
        .kind = kind,
        .item_id = owned_item_id,
        .delta = try allocator.dupe(u8, delta),
        .index = index,
    };
}

fn jsonStringFieldAny(object: std.json.ObjectMap, snake_name: []const u8, camel_name: []const u8) ?[]const u8 {
    const value = object.get(snake_name) orelse object.get(camel_name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonIntegerFieldAny(object: std.json.ObjectMap, snake_name: []const u8, camel_name: []const u8) ?i64 {
    const value = object.get(snake_name) orelse object.get(camel_name) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

const baseInstructions =
    \\You are Codex Zig, an experimental local coding agent. Use tools only when needed.
;

const shellToolInstructions =
    \\When you need to inspect files or run commands, call exec_command. Use write_stdin for running exec_command sessions. shell_command and shell remain supported.
;

const baseInstructionsTail =
    \\When you need to edit files, prefer apply_patch with a focused Codex-style patch.
    \\For multi-step work, call update_plan with concise steps and current statuses.
    \\Use list_mcp_resources, list_mcp_resource_templates, and read_mcp_resource to inspect configured MCP context resources.
    \\Configured MCP server tools may appear as mcp__server__tool function tools.
    \\Keep answers concise and report command outcomes.
;

const friendlyPersonalityInstructions =
    "You optimize for team morale and being a supportive teammate as much as code quality.";
const pragmaticPersonalityInstructions =
    "You are a deeply pragmatic, effective software engineer.";

fn baseInstructionsForConfig(allocator: std.mem.Allocator, cfg: config.Config, shell_tools_enabled: bool) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (cfg.base_instructions) |base_override| {
        try out.appendSlice(allocator, base_override);
    } else {
        try out.appendSlice(allocator, baseInstructions);
        try out.append(allocator, '\n');
        if (shell_tools_enabled) {
            try out.appendSlice(allocator, shellToolInstructions);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, baseInstructionsTail);

        if (cfg.personality) |personality| {
            const message = switch (personality) {
                .none => null,
                .friendly => friendlyPersonalityInstructions,
                .pragmatic => pragmaticPersonalityInstructions,
            };
            if (message) |text| {
                try out.appendSlice(allocator, "\n<personality_spec>\nThe user has requested a new communication style. Future messages should adhere to the following personality:\n");
                try out.appendSlice(allocator, text);
                try out.appendSlice(allocator, "\n</personality_spec>\n");
            }
        }
    }

    if (cfg.developer_instructions) |developer_instructions| {
        if (developer_instructions.len > 0) {
            try out.appendSlice(allocator, "\n<collaboration_mode>\n");
            try out.appendSlice(allocator, developer_instructions);
            try out.appendSlice(allocator, "\n</collaboration_mode>\n");
        }
    }

    return out.toOwnedSlice(allocator);
}

test "developer instructions config adds collaboration mode instructions" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
        .developer_instructions = "Use plan mode.",
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "hello",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, instructions, "<collaboration_mode>") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Use plan mode.") != null);
}

test "empty developer instructions do not add collaboration mode block" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
        .developer_instructions = "",
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "hello",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, instructions, "<collaboration_mode>") == null);
}

test "base instructions override replaces default instruction body" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
        .personality = .pragmatic,
        .base_instructions = "Custom base instructions.",
        .developer_instructions = "Developer addendum.",
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "hello",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;
    try std.testing.expect(std.mem.startsWith(u8, instructions, "Custom base instructions."));
    try std.testing.expect(std.mem.indexOf(u8, instructions, "You are Codex Zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "<personality_spec>") == null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Developer addendum.") != null);
}

test "parses SSE text and function call" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"shell_command\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}\n" ++
        "data: [DONE]\n";
    var parsed = try parseSseResponse(allocator, body);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("hi", parsed.text);
    try std.testing.expectEqual(@as(usize, 1), parsed.function_calls.len);
    try std.testing.expectEqualStrings("shell_command", parsed.function_calls[0].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.raw_response_items.len);
    try std.testing.expect(std.mem.indexOf(u8, parsed.raw_response_items[0], "\"call_id\":\"c1\"") != null);
}

test "parses SSE reasoning events" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_1\",\"summary_index\":0}\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"summary_index\":0,\"delta\":\"thinking\"}\n" ++
        "data: {\"type\":\"response.reasoning_text.delta\",\"item_id\":\"rt_1\",\"content_index\":2,\"delta\":\"trace\"}\n" ++
        "data: [DONE]\n";
    var parsed = try parseSseResponse(allocator, body);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.reasoning_events.len);
    try std.testing.expectEqual(ReasoningEventKind.summary_part_added, parsed.reasoning_events[0].kind);
    try std.testing.expectEqualStrings("rs_1", parsed.reasoning_events[0].item_id);
    try std.testing.expectEqual(@as(i64, 0), parsed.reasoning_events[0].index);
    try std.testing.expectEqual(ReasoningEventKind.summary_text_delta, parsed.reasoning_events[1].kind);
    try std.testing.expectEqualStrings("thinking", parsed.reasoning_events[1].delta);
    try std.testing.expectEqual(ReasoningEventKind.text_delta, parsed.reasoning_events[2].kind);
    try std.testing.expectEqual(@as(i64, 2), parsed.reasoning_events[2].index);
}

test "parses SSE model metadata" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"type\":\"response.created\",\"response\":{\"headers\":{\"OpenAI-Model\":\"gpt-rerouted\"}}}\n" ++
        "data: {\"type\":\"response.metadata\",\"metadata\":{\"openai_verification_recommendation\":[\"trusted_access_for_cyber\",\"unknown\",\"trusted_access_for_cyber\"]}}\n" ++
        "data: [DONE]\n";
    var parsed = try parseSseResponse(allocator, body);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("gpt-rerouted", parsed.server_model.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.model_verifications.len);
    try std.testing.expectEqual(ModelVerification.trusted_access_for_cyber, parsed.model_verifications[0]);
}

test "parses SSE failed response as API failure" {
    const allocator = std.testing.allocator;
    const body =
        "event: response.failed\n" ++
        "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp-1\",\"error\":{\"code\":\"server_error\",\"message\":\"simulated failure\"}}}\n\n";
    try std.testing.expectError(error.ApiResponseFailed, parseSseResponse(allocator, body));
}

const TestStreamContext = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestStreamContext) void {
        self.text.deinit(self.allocator);
    }
};

fn collectTextDelta(ctx: *anyopaque, delta: []const u8) anyerror!void {
    const test_context: *TestStreamContext = @ptrCast(@alignCast(ctx));
    try test_context.text.appendSlice(test_context.allocator, delta);
}

test "streaming response writer emits text deltas while retaining raw SSE" {
    const allocator = std.testing.allocator;
    var stream_context = TestStreamContext{ .allocator = allocator };
    defer stream_context.deinit();

    var writer = try StreamingResponseWriter.init(allocator, .{
        .ctx = &stream_context,
        .on_text_delta = collectTextDelta,
    });
    defer writer.deinit();

    try writer.writer.writeAll("data: {\"type\":\"response.output_text.delta\",\"delta\":\"he\"}\n");
    try writer.writer.writeAll("data: {\"type\":\"response.output_text.delta\",\"delta\":\"llo\"}\n");
    try writer.writer.writeAll("data: [DONE]\n");
    try writer.finish();

    const raw = try writer.toOwnedSlice();
    defer allocator.free(raw);

    try std.testing.expectEqualStrings("hello", stream_context.text.items);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"delta\":\"he\"") != null);
}

test "builds chronological request input from owned history" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "create a file",
        },
        .{
            .kind = .function_call,
            .call_id = "call-1",
            .name = "shell_command",
            .arguments = "{\"command\":\"pwd\"}",
        },
        .{
            .kind = .function_call_output,
            .call_id = "call-1",
            .output = "stdout:\n/tmp\nstderr:\n",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;
    const input = parsed.value.object.get("input").?.array;

    try std.testing.expect(std.mem.indexOf(u8, instructions, "needed.\nWhen you need to inspect files") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "supported.\nWhen you need to edit files") != null);
    try std.testing.expectEqual(@as(usize, 3), input.items.len);
    try std.testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("input_text", input.items[0].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("create a file", input.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("function_call", input.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input.items[2].object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"exec_command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"write_stdin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"apply_patch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"update_plan\"") != null);
}

test "runtime feature overrides can disable shell tools" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
    const history = [_]HistoryItem{.{
        .kind = .message,
        .role = "user",
        .content_type = "input_text",
        .text = "hello",
    }};

    var feature_overrides = features_cmd.FeatureOverrides{};
    defer feature_overrides.deinit(allocator);
    try feature_overrides.put(allocator, "shell_tool", false);

    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{
        .feature_overrides = feature_overrides,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;

    try std.testing.expect(std.mem.indexOf(u8, instructions, "needed.\nWhen you need to edit files") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "call exec_command") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"exec_command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"write_stdin\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"shell\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"shell_command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"apply_patch\"") != null);
}

test "builds request with configured reasoning controls" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = .high,
        .model_reasoning_summary = .detailed,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "think harder",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const reasoning = parsed.value.object.get("reasoning").?.object;

    try std.testing.expectEqualStrings("high", reasoning.get("effort").?.string);
    try std.testing.expectEqualStrings("detailed", reasoning.get("summary").?.string);
}

test "builds input images on latest user message" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "describe this",
        },
    };
    const images = [_][]const u8{"data:image/png;base64,aGVsbG8="};

    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{ .input_images = images[0..] });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("input").?.array.items[0].object.get("content").?.array;

    try std.testing.expectEqual(@as(usize, 2), content.items.len);
    try std.testing.expectEqualStrings("input_text", content.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("input_image", content.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", content.items[1].object.get("image_url").?.string);
    try std.testing.expectEqualStrings("auto", content.items[1].object.get("detail").?.string);
}

test "builds web search tool from config mode" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = .live,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "search the web",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;

    var found = false;
    for (tools.items) |tool| {
        const object = tool.object;
        const tool_type = object.get("type") orelse continue;
        if (tool_type != .string or !std.mem.eql(u8, tool_type.string, "web_search")) continue;
        found = true;
        try std.testing.expectEqual(true, object.get("external_web_access").?.bool);
        try std.testing.expect(object.get("name") == null);
    }

    try std.testing.expect(found);
}

test "builds mcp function tools from catalog" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "use mcp",
        },
    };
    const mcp_tools = [_]mcp_runtime.ToolSpec{.{
        .server_name = "demo",
        .raw_tool_name = "echo",
        .callable_name = "mcp__demo__echo",
        .description = "Echo through MCP",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
    }};

    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{ .mcp_tools = mcp_tools[0..] });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;

    var found = false;
    for (tools.items) |tool| {
        const object = tool.object;
        const name = object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, "mcp__demo__echo")) continue;
        found = true;
        try std.testing.expectEqualStrings("function", object.get("type").?.string);
        try std.testing.expectEqualStrings("Echo through MCP", object.get("description").?.string);
        try std.testing.expectEqualStrings("object", object.get("parameters").?.object.get("type").?.string);
    }

    try std.testing.expect(found);
}

test "builds mcp resource function tools" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "use resources",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;

    const expected = [_][]const u8{
        "list_mcp_resources",
        "list_mcp_resource_templates",
        "read_mcp_resource",
    };
    for (expected) |expected_name| {
        var found = false;
        for (tools.items) |tool| {
            const object = tool.object;
            const name = object.get("name") orelse continue;
            if (name == .string and std.mem.eql(u8, name.string, expected_name)) {
                found = true;
                try std.testing.expectEqualStrings("function", object.get("type").?.string);
                try std.testing.expectEqualStrings("object", object.get("parameters").?.object.get("type").?.string);
            }
        }
        try std.testing.expect(found);
    }
}

test "can omit tools for compact-style turns" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = .live,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "summarize",
        },
    };
    const mcp_tools = [_]mcp_runtime.ToolSpec{.{
        .server_name = "demo",
        .raw_tool_name = "echo",
        .callable_name = "mcp__demo__echo",
        .description = "Echo through MCP",
        .input_schema_json = "{\"type\":\"object\"}",
    }};

    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{
        .mcp_tools = mcp_tools[0..],
        .include_tools = false,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tools").?.array.items.len);
}

test "builds output schema text format" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "gpt-5.5",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .model_verbosity = .high,
        .service_tier = "priority",
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "return json",
        },
    };

    var schema = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}}}", .{});
    defer schema.deinit();
    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{ .output_schema = schema.value });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const format = parsed.value.object.get("text").?.object.get("format").?.object;

    try std.testing.expectEqualStrings("json_schema", format.get("type").?.string);
    try std.testing.expectEqualStrings("high", parsed.value.object.get("text").?.object.get("verbosity").?.string);
    try std.testing.expectEqualStrings("priority", parsed.value.object.get("service_tier").?.string);
    try std.testing.expectEqualStrings("codex_output_schema", format.get("name").?.string);
    try std.testing.expect(format.get("strict").?.bool);
    try std.testing.expectEqualStrings("object", format.get("schema").?.object.get("type").?.string);
}

test "builds default verbosity for supported bundled model" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "gpt-5.4-mini",
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
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "hello",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("medium", parsed.value.object.get("text").?.object.get("verbosity").?.string);
}

test "omits unsupported model verbosity while preserving output schema" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .oss_provider = null,
        .installation_id = "install-test",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .model_verbosity = .high,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "return json",
        },
    };

    var schema = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"object\"}", .{});
    defer schema.deinit();
    const body = try buildRequestBodyWithOptions(allocator, cfg, history[0..], .{ .output_schema = schema.value });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("text").?.object;
    try std.testing.expect(text.get("verbosity") == null);
    try std.testing.expectEqualStrings("json_schema", text.get("format").?.object.get("type").?.string);
}

test "personality config adds personality instructions" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .active_profile = null,
        .model = "demo-model",
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
        .personality = .friendly,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    const history = [_]HistoryItem{
        .{
            .kind = .message,
            .role = "user",
            .content_type = "input_text",
            .text = "hello",
        },
    };

    const body = try buildRequestBody(allocator, cfg, history[0..]);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const instructions = parsed.value.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, instructions, "<personality_spec>") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, friendlyPersonalityInstructions) != null);
}

test "provider url appends configured query params" {
    const allocator = std.testing.allocator;
    var entries = [_]config.StringMapEntry{
        .{ .key = "api-version", .value = "2025-04-01-preview" },
        .{ .key = "deployment", .value = "codex" },
    };
    const query_params = config.StringMap{ .entries = entries[0..] };

    const url = try buildProviderUrl(allocator, "https://proxy.example/v1/", "/responses", query_params);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://proxy.example/v1/responses?api-version=2025-04-01-preview&deployment=codex",
        url,
    );
}
