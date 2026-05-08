const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const tools = @import("tools.zig");

pub const Transcript = struct {
    history: std.ArrayList(api.HistoryItem) = .empty,

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        for (self.history.items) |item| item.deinit(allocator);
        self.history.deinit(allocator);
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
};

pub const TurnOptions = struct {
    auto_approve: bool = false,
    prompt_for_approval: bool = true,
    json_events: bool = false,
    stream_text: bool = false,
    additional_writable_roots: []const []const u8 = &.{},
    output_schema: ?std.json.Value = null,
};

pub fn runTurn(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *Transcript,
    prompt: []const u8,
) ![]const u8 {
    return runTurnWithOptions(allocator, cfg, credentials, transcript, prompt, .{});
}

pub fn runTurnWithOptions(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *Transcript,
    prompt: []const u8,
    options: TurnOptions,
) ![]const u8 {
    try transcript.appendUserMessage(allocator, prompt);
    if (options.json_events) try emitJsonEvent(allocator, .{ .type = "turn.started" });

    var final_text = std.ArrayList(u8).empty;
    errdefer final_text.deinit(allocator);

    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        var stream_context = StreamTextContext{};
        var create_options = api.CreateTurnOptions{};
        create_options.output_schema = options.output_schema;
        if (options.stream_text and !options.json_events) {
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
            const answer = try final_text.toOwnedSlice(allocator);
            errdefer allocator.free(answer);
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

            var tool_result = try tools.runFunctionCall(allocator, call, .{
                .approval_policy = cfg.approval_policy,
                .sandbox_mode = cfg.sandbox_mode,
                .additional_writable_roots = options.additional_writable_roots,
                .auto_approve = options.auto_approve,
                .prompt_for_approval = options.prompt_for_approval,
            });
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
