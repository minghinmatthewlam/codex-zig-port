const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");

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

pub const ParsedResponse = struct {
    text: []const u8,
    function_calls: []FunctionCall,

    pub fn deinit(self: *ParsedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.function_calls) |call| call.deinit(allocator);
        allocator.free(self.function_calls);
    }
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

pub const ToolOutput = struct {
    call_id: []const u8,
    output: []const u8,
};

const ContentItem = struct {
    type: []const u8,
    text: []const u8,
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

const FunctionParameters = struct {
    type: []const u8 = "object",
    properties: Properties,
    required: []const []const u8,
    additionalProperties: bool = false,
};

const Properties = struct {
    command: CommandProperty,
};

const CommandProperty = struct {
    type: []const u8,
    description: []const u8,
    items: ?CommandItems = null,
};

const CommandItems = struct {
    type: []const u8 = "string",
};

const Tool = struct {
    type: []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: FunctionParameters,
};

const Request = struct {
    model: []const u8,
    instructions: []const u8,
    input: []const InputItem,
    tools: []const Tool,
    tool_choice: []const u8 = "auto",
    parallel_tool_calls: bool = false,
    reasoning: ?Reasoning = null,
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

pub fn createTurn(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    history: []const HistoryItem,
) !ParsedResponse {
    const body = try buildRequestBody(allocator, cfg, history);
    defer allocator.free(body);

    const base_url = switch (credentials.mode) {
        .chatgpt => cfg.chatgpt_base_url,
        .api_key => cfg.openai_base_url,
    };
    const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{std.mem.trimEnd(u8, base_url, "/")});
    defer allocator.free(url);

    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "text/event-stream" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-ID", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });

    const bytes = try response_body.toOwnedSlice();
    defer allocator.free(bytes);

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        std.debug.print("Responses API error status {d}: {s}\n", .{ @intFromEnum(result.status), bytes });
        return error.ApiRequestFailed;
    }

    return parseSseResponse(allocator, bytes);
}

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    history: []const HistoryItem,
) ![]const u8 {
    var inputs = std.ArrayList(InputItem).empty;
    defer inputs.deinit(allocator);

    var message_count: usize = 0;
    for (history) |item| {
        if (item.kind == .message) message_count += 1;
    }

    const message_content = try allocator.alloc([1]ContentItem, message_count);
    defer allocator.free(message_content);
    var message_index: usize = 0;

    for (history) |item| {
        switch (item.kind) {
            .message => {
                const role = item.role orelse return error.InvalidMessageHistory;
                const text = item.text orelse return error.InvalidMessageHistory;
                const content_type = item.content_type orelse return error.InvalidMessageHistory;
                message_content[message_index][0] = .{
                    .type = content_type,
                    .text = text,
                };
                try inputs.append(allocator, .{
                    .type = "message",
                    .role = role,
                    .content = message_content[message_index][0..],
                });
                message_index += 1;
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

    const required = [_][]const u8{"command"};
    const shell_tool = Tool{
        .name = "shell",
        .description = "Run a command as an argv array in the current workspace.",
        .parameters = .{
            .properties = .{ .command = .{
                .type = "array",
                .description = "Command and arguments to execute.",
                .items = .{},
            } },
            .required = required[0..],
        },
    };
    const shell_command_tool = Tool{
        .name = "shell_command",
        .description = "Run a shell command string in the current workspace.",
        .parameters = .{
            .properties = .{ .command = .{
                .type = "string",
                .description = "Shell command to execute.",
            } },
            .required = required[0..],
        },
    };
    const tools = [_]Tool{ shell_tool, shell_command_tool };
    const include = [_][]const u8{};

    const req = Request{
        .model = cfg.model,
        .instructions = baseInstructions,
        .input = inputs.items,
        .tools = tools[0..],
        .reasoning = .{},
        .include = include[0..],
        .prompt_cache_key = cfg.installation_id,
        .client_metadata = .{ .@"x-codex-installation-id" = cfg.installation_id },
    };
    return std.json.Stringify.valueAlloc(allocator, req, .{ .emit_null_optional_fields = false });
}

pub fn parseSseResponse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedResponse {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var calls = std.ArrayList(FunctionCall).empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

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

        if (std.mem.eql(u8, event_type.string, "response.output_text.delta")) {
            if (object.get("delta")) |delta| {
                if (delta == .string) try text.appendSlice(allocator, delta.string);
            }
        } else if (std.mem.eql(u8, event_type.string, "response.output_item.done")) {
            const item_value = object.get("item") orelse continue;
            if (item_value != .object) continue;
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
    };
}

const baseInstructions =
    \\You are Codex Zig, an experimental local coding agent. Use tools only when needed.
    \\When you need to inspect or modify files, call shell_command or shell.
    \\Keep answers concise and report command outcomes.
;

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
}

test "builds chronological request input from owned history" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .codex_home = ".",
        .model = "demo-model",
        .openai_base_url = "https://example.invalid/v1",
        .chatgpt_base_url = "https://example.invalid/backend-api/codex",
        .installation_id = "install-test",
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
    const input = parsed.value.object.get("input").?.array;

    try std.testing.expectEqual(@as(usize, 3), input.items.len);
    try std.testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("input_text", input.items[0].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("create a file", input.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("function_call", input.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input.items[2].object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"\"") == null);
}
