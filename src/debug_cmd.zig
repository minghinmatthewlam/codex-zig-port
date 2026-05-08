const std = @import("std");

const api = @import("api.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const session = @import("session.zig");

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingDebugSubcommand;
    };

    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, subcommand, "prompt-input")) {
        try runPromptInput(allocator, args, options);
        return;
    }

    std.debug.print("unknown debug subcommand: {s}\n", .{subcommand});
    return error.UnknownDebugSubcommand;
}

fn runPromptInput(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var prompt_parts = std.ArrayList([]const u8).empty;
    defer prompt_parts.deinit(allocator);

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printPromptInputHelp();
            return;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownDebugPromptInputOption;
        try prompt_parts.append(allocator, arg);
    }

    const prompt = if (prompt_parts.items.len > 0)
        try cli_utils.joinWithSpaces(allocator, prompt_parts.items)
    else
        null;
    defer if (prompt) |value| allocator.free(value);

    const rendered = try renderPromptInput(allocator, prompt, options);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
    try cli_utils.writeStdout("\n");
}

fn renderPromptInput(allocator: std.mem.Allocator, prompt: ?[]const u8, options: Options) ![]const u8 {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    if (prompt) |value| {
        try transcript.appendUserMessage(allocator, value);
    }

    const body = try api.buildRequestBodyWithOptions(allocator, cfg, transcript.history.items, .{
        .include_tools = false,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDebugPromptInput;
    const input = parsed.value.object.get("input") orelse return error.InvalidDebugPromptInput;
    return std.json.Stringify.valueAlloc(allocator, input, .{ .whitespace = .indent_2 });
}

fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug prompt-input [PROMPT]
        \\
        \\Subcommands:
        \\  prompt-input       Render the model-visible input list as JSON
        \\
    , .{});
}

fn printPromptInputHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug prompt-input [PROMPT]
        \\
        \\Prints the Responses API input list that would be sent for PROMPT.
        \\
    , .{});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

test "debug prompt input renders optional user prompt" {
    const allocator = std.testing.allocator;
    const rendered = try renderPromptInput(allocator, "hello debug", .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"type\": \"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"role\": \"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"text\": \"hello debug\"") != null);
}

test "debug prompt input renders empty history" {
    const allocator = std.testing.allocator;
    const rendered = try renderPromptInput(allocator, null, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[]", rendered);
}
