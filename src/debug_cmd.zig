const std = @import("std");

const api = @import("api.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const input_images = @import("input_images.zig");
const memory_reset = @import("memory_reset.zig");
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
    if (std.mem.eql(u8, subcommand, "models")) {
        try runModels(allocator, args, options);
        return;
    }
    if (std.mem.eql(u8, subcommand, "app-server")) {
        try runAppServerDebug(args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "trace-reduce")) {
        try runTraceReduce(allocator, args);
        return;
    }
    if (std.mem.eql(u8, subcommand, "clear-memories")) {
        try runClearMemories(allocator, args, options);
        return;
    }

    std.debug.print("unknown debug subcommand: {s}\n", .{subcommand});
    return error.UnknownDebugSubcommand;
}

fn runPromptInput(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var prompt_parts = std.ArrayList([]const u8).empty;
    defer prompt_parts.deinit(allocator);
    var image_files = std.ArrayList([]const u8).empty;
    defer {
        for (image_files.items) |path| allocator.free(path);
        image_files.deinit(allocator);
    }

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printPromptInputHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            const value = args.next() orelse return error.MissingDebugPromptInputOptionValue;
            try input_images.appendFiles(allocator, &image_files, value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendFiles(allocator, &image_files, arg["--image=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownDebugPromptInputOption;
        try prompt_parts.append(allocator, arg);
    }

    const prompt = if (prompt_parts.items.len > 0)
        try cli_utils.joinWithSpaces(allocator, prompt_parts.items)
    else
        null;
    defer if (prompt) |value| allocator.free(value);

    var loaded_images = try input_images.load(allocator, image_files.items);
    defer loaded_images.deinit(allocator);

    const rendered = try renderPromptInput(allocator, prompt, loaded_images.data_urls, options);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
    try cli_utils.writeStdout("\n");
}

fn runModels(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var bundled = false;
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printModelsHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--bundled")) {
            bundled = true;
            continue;
        }
        return error.UnknownDebugModelsOption;
    }

    const rendered = try renderModels(allocator, options, bundled);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
    try cli_utils.writeStdout("\n");
}

fn runAppServerDebug(args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printDebugAppServerHelp();
        return error.MissingDebugAppServerSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printDebugAppServerHelp();
        return;
    }
    if (!std.mem.eql(u8, subcommand, "send-message-v2")) {
        return error.UnknownDebugAppServerSubcommand;
    }

    const user_message = args.next() orelse {
        printDebugAppServerSendMessageV2Help();
        return error.MissingDebugAppServerSendMessage;
    };
    if (isHelpFlag(user_message)) {
        printDebugAppServerSendMessageV2Help();
        return;
    }
    if (args.next() != null) return error.UnexpectedDebugAppServerArgument;

    try cli_utils.writeStderr("codex-zig debug app-server send-message-v2 is parsed but not implemented yet\n");
    return error.DebugAppServerSendMessageV2NotImplemented;
}

fn runTraceReduce(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var trace_bundle: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printTraceReduceHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output = args.next() orelse return error.MissingDebugTraceReduceOutput;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownDebugTraceReduceOption;
        if (trace_bundle != null) return error.UnexpectedDebugTraceReduceArgument;
        trace_bundle = arg;
    }

    const bundle = trace_bundle orelse {
        printTraceReduceHelp();
        return error.MissingDebugTraceBundle;
    };
    const message = if (output) |path|
        try std.fmt.allocPrint(
            allocator,
            "codex-zig debug trace-reduce is parsed but not implemented yet: {s} -> {s}\n",
            .{ bundle, path },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "codex-zig debug trace-reduce is parsed but not implemented yet: {s}\n",
            .{bundle},
        );
    defer allocator.free(message);
    try cli_utils.writeStderr(message);
    return error.DebugTraceReduceNotImplemented;
}

fn runClearMemories(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printClearMemoriesHelp();
            return;
        }
        return error.UnknownDebugClearMemoriesOption;
    }

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);

    const state_path = try memory_reset.resolveStateDbPath(allocator, cfg.codex_home);
    defer allocator.free(state_path);
    const state_exists = try memory_reset.stateDbExists(allocator, state_path);
    if (state_exists) {
        const message = try std.fmt.allocPrint(
            allocator,
            "State db found at {s}; Zig memory-state clearing is not implemented yet. Refusing partial memory reset.\n",
            .{state_path},
        );
        defer allocator.free(message);
        try cli_utils.writeStderr(message);
        return error.MemoryStateDbClearNotImplemented;
    }

    try memory_reset.clearMemoryRootsContents(allocator, cfg.codex_home);

    const message = try std.fmt.allocPrint(
        allocator,
        "No state db found at {s}. Cleared memory directories under {s}.\n",
        .{ state_path, cfg.codex_home },
    );
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn renderPromptInput(
    allocator: std.mem.Allocator,
    prompt: ?[]const u8,
    image_data_urls: []const []const u8,
    options: Options,
) ![]const u8 {
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
        .input_images = image_data_urls,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDebugPromptInput;
    const input = parsed.value.object.get("input") orelse return error.InvalidDebugPromptInput;
    return std.json.Stringify.valueAlloc(allocator, input, .{ .whitespace = .indent_2 });
}

const ReasoningLevel = struct {
    effort: []const u8,
    description: []const u8,
};

const ModelEntry = struct {
    slug: []const u8,
    display_name: []const u8,
    description: []const u8,
    default_reasoning_level: []const u8,
    supported_reasoning_levels: []const ReasoningLevel,
    input_modalities: []const []const u8,
    supports_parallel_tool_calls: bool,
    supported_in_api: bool,
    visibility: []const u8,
    priority: u32,
};

const ModelsResponse = struct {
    models: []const ModelEntry,
};

const default_reasoning_levels = [_]ReasoningLevel{
    .{ .effort = "low", .description = "Fast responses with lighter reasoning" },
    .{ .effort = "medium", .description = "Balanced reasoning depth" },
    .{ .effort = "high", .description = "Greater reasoning depth" },
    .{ .effort = "xhigh", .description = "Extra high reasoning depth" },
};

const text_image_modalities = [_][]const u8{ "text", "image" };

fn renderModels(allocator: std.mem.Allocator, options: Options, bundled: bool) ![]const u8 {
    if (bundled) {
        const models = [_]ModelEntry{defaultModelEntry("gpt-5.2-codex", "GPT-5.2 Codex", "Default Codex Zig coding model.")};
        return stringifyModels(allocator, models[0..]);
    }

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);

    const models = [_]ModelEntry{defaultModelEntry(cfg.model, cfg.model, "Configured Codex Zig model.")};
    return stringifyModels(allocator, models[0..]);
}

fn defaultModelEntry(slug: []const u8, display_name: []const u8, description: []const u8) ModelEntry {
    return .{
        .slug = slug,
        .display_name = display_name,
        .description = description,
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = default_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .supports_parallel_tool_calls = true,
        .supported_in_api = true,
        .visibility = "list",
        .priority = 0,
    };
}

fn stringifyModels(allocator: std.mem.Allocator, models: []const ModelEntry) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, ModelsResponse{ .models = models }, .{ .whitespace = .indent_2 });
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug prompt-input [OPTIONS] [PROMPT]
        \\  codex-zig debug models [--bundled]
        \\  codex-zig debug app-server <COMMAND>
        \\  codex-zig debug clear-memories
        \\
        \\Subcommands:
        \\  prompt-input       Render the model-visible input list as JSON
        \\  models             Render the raw model catalog as JSON
        \\  app-server         App-server debugging helpers
        \\  clear-memories     Clear local memory directories
        \\
    , .{});
}

fn printPromptInputHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug prompt-input [OPTIONS] [PROMPT]
        \\
        \\Prints the Responses API input list that would be sent for PROMPT.
        \\
        \\Options:
        \\  -i, --image FILE        Attach local image file(s); comma-separated values accepted
        \\
    , .{});
}

fn printModelsHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug models [--bundled]
        \\
        \\Prints a Zig-native model catalog snapshot as JSON.
        \\
        \\Options:
        \\  --bundled              Skip config and dump the bundled Zig catalog
        \\
    , .{});
}

fn printDebugAppServerHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug app-server send-message-v2 USER_MESSAGE
        \\
        \\Subcommands:
        \\  send-message-v2    Send a V2 debug message through the Rust app-server test client
        \\
    , .{});
}

fn printDebugAppServerSendMessageV2Help() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug app-server send-message-v2 USER_MESSAGE
        \\
        \\Parses the Rust debug app-server helper shape. The app-server test
        \\client transport is not implemented in the Zig port yet.
        \\
    , .{});
}

fn printTraceReduceHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug trace-reduce [--output FILE] TRACE_BUNDLE
        \\
        \\Parses the hidden Rust rollout trace reducer command. Rollout trace
        \\replay is not implemented in the Zig port yet.
        \\
        \\Options:
        \\  -o, --output FILE      Output path for reduced state JSON
        \\
    , .{});
}

fn printClearMemoriesHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug clear-memories
        \\
        \\Clears CODEX_HOME/memories and CODEX_HOME/memories_extensions while
        \\preserving the root directories. Symlinked memory roots are refused.
        \\
    , .{});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

test "debug prompt input renders optional user prompt" {
    const allocator = std.testing.allocator;
    const rendered = try renderPromptInput(allocator, "hello debug", &.{}, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"type\": \"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"role\": \"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"text\": \"hello debug\"") != null);
}

test "debug prompt input renders empty history" {
    const allocator = std.testing.allocator;
    const rendered = try renderPromptInput(allocator, null, &.{}, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[]", rendered);
}

test "debug prompt input renders images on latest user message" {
    const allocator = std.testing.allocator;
    const images = [_][]const u8{"data:image/png;base64,aW1hZ2U="};
    const rendered = try renderPromptInput(allocator, "describe", images[0..], .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"type\": \"input_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"image_url\": \"data:image/png;base64,aW1hZ2U=\"") != null);
}

test "debug models renders configured model" {
    const allocator = std.testing.allocator;
    const rendered = try renderModels(allocator, .{ .runtime_overrides = .{ .model = "gpt-test" } }, false);
    defer allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const model = parsed.value.object.get("models").?.array.items[0].object;
    try std.testing.expectEqualStrings("gpt-test", model.get("slug").?.string);
    try std.testing.expectEqualStrings("medium", model.get("default_reasoning_level").?.string);
    try std.testing.expectEqual(@as(usize, 4), model.get("supported_reasoning_levels").?.array.items.len);
}

test "debug models bundled ignores configured model" {
    const allocator = std.testing.allocator;
    const rendered = try renderModels(allocator, .{ .runtime_overrides = .{ .model = "gpt-test" } }, true);
    defer allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const model = parsed.value.object.get("models").?.array.items[0].object;
    try std.testing.expectEqualStrings("gpt-5.2-codex", model.get("slug").?.string);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"slug\": \"gpt-test\"") == null);
}
