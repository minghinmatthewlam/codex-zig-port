const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const tools = @import("tools.zig");

pub const Transcript = struct {
    history: std.ArrayList(api.HistoryItem) = .empty,

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        self.history.deinit(allocator);
    }
};

pub fn runTurn(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *Transcript,
    prompt: []const u8,
) ![]const u8 {
    var current_prompt = prompt;
    var final_text = std.ArrayList(u8).empty;
    errdefer final_text.deinit(allocator);

    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        var response = try api.createTurn(allocator, cfg, credentials, current_prompt, transcript.history.items);
        defer response.deinit(allocator);

        if (response.text.len > 0) {
            try final_text.appendSlice(allocator, response.text);
        }

        if (response.function_calls.len == 0) {
            return final_text.toOwnedSlice(allocator);
        }

        for (response.function_calls) |call| {
            std.debug.print("\n[tool requested] {s} {s}\n", .{ call.name, call.arguments });
            var tool_result = try tools.runFunctionCall(allocator, call, false);
            defer tool_result.deinit(allocator);

            std.debug.print("[tool result] {s}\n", .{tool_result.summary});

            try transcript.history.append(allocator, .{
                .kind = .function_call,
                .call_id = call.call_id,
                .name = call.name,
                .arguments = call.arguments,
            });
            try transcript.history.append(allocator, .{
                .kind = .function_call_output,
                .call_id = tool_result.call_id,
                .output = tool_result.output,
            });
        }

        current_prompt = "";
    }

    return error.TooManyToolRounds;
}
