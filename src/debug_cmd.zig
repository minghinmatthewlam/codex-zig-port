const std = @import("std");

const api = @import("api.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const input_images = @import("input_images.zig");
const memory_reset = @import("memory_reset.zig");
const model_catalog = @import("model_catalog.zig");
const session = @import("session.zig");
const trace_reduce = @import("trace_reduce.zig");

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
        try runAppServerDebug(allocator, args, options);
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

fn runAppServerDebug(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
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

    try runDebugAppServerSendMessageV2(allocator, user_message, options);
}

fn runDebugAppServerSendMessageV2(allocator: std.mem.Allocator, user_message: []const u8, options: Options) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var self_exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_len = try std.process.executablePath(io_instance.io(), &self_exe_buffer);
    const self_exe = self_exe_buffer[0..self_exe_len];

    var child_env = try currentEnvironmentMap(allocator);
    defer child_env.deinit();
    try applyDebugAppServerChildEnvOverrides(&child_env, options.runtime_overrides);

    var child_argv = std.ArrayList([]const u8).empty;
    defer child_argv.deinit(allocator);
    var owned_child_argv = std.ArrayList([]const u8).empty;
    defer {
        for (owned_child_argv.items) |value| allocator.free(value);
        owned_child_argv.deinit(allocator);
    }
    try child_argv.append(allocator, self_exe);
    try appendDebugAppServerChildOptions(allocator, &child_argv, &owned_child_argv, options);
    try child_argv.append(allocator, "app-server");

    var child = try std.process.spawn(io_instance.io(), .{
        .argv = child_argv.items,
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var child_alive = true;
    errdefer if (child_alive) child.kill(io_instance.io());

    const stdin_file = child.stdin orelse return error.DebugAppServerMissingPipe;
    const stdout_file = child.stdout orelse return error.DebugAppServerMissingPipe;
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_reader = stdout_file.reader(io_instance.io(), &stdout_buffer);

    const initialize_request =
        \\{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"clientInfo":{"name":"codex-zig-debug","version":"0"},"capabilities":{"experimentalApi":true}}}
    ;
    try writeAppServerRequest(&io_instance, stdin_file, initialize_request);
    const initialize_response = try readDebugResponseLine(allocator, &stdout_reader.interface, "initialize", "initialize");
    allocator.free(initialize_response);

    const thread_start_request =
        \\{"jsonrpc":"2.0","id":"thread-start","method":"thread/start","params":{}}
    ;
    try writeAppServerRequest(&io_instance, stdin_file, thread_start_request);
    const thread_start_response = try readDebugResponseLine(allocator, &stdout_reader.interface, "thread-start", "thread/start");
    defer allocator.free(thread_start_response);
    const thread_id = try extractNestedString(allocator, thread_start_response, &.{ "result", "thread", "id" });
    defer allocator.free(thread_id);

    const escaped_message = try std.json.Stringify.valueAlloc(allocator, user_message, .{});
    defer allocator.free(escaped_message);
    const thread_id_json = try std.json.Stringify.valueAlloc(allocator, thread_id, .{});
    defer allocator.free(thread_id_json);
    const turn_start_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"turn-start\",\"method\":\"turn/start\",\"params\":{{\"threadId\":{s},\"input\":[{{\"type\":\"text\",\"text\":{s},\"text_elements\":[]}}]}}}}",
        .{ thread_id_json, escaped_message },
    );
    defer allocator.free(turn_start_request);
    try writeAppServerRequest(&io_instance, stdin_file, turn_start_request);
    const turn_start_response = try readDebugResponseLine(allocator, &stdout_reader.interface, "turn-start", "turn/start");
    defer allocator.free(turn_start_response);
    const turn_id = try extractNestedString(allocator, turn_start_response, &.{ "result", "turn", "id" });
    defer allocator.free(turn_id);

    try streamDebugTurnUntilCompleted(allocator, &stdout_reader.interface, thread_id, turn_id);

    stdin_file.close(io_instance.io());
    child.stdin = null;
    const term = try child.wait(io_instance.io());
    child_alive = false;
    if (!childTermSuccess(term)) return error.DebugAppServerExited;
}

fn appendDebugAppServerChildOptions(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]const u8),
    options: Options,
) !void {
    if (options.profile) |profile| {
        try argv.append(allocator, "-p");
        try argv.append(allocator, profile);
    }
    const overrides = options.runtime_overrides;
    if (overrides.model) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "model", value);
    if (overrides.review_model) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "review_model", value);
    if (overrides.model_context_window) |value| try appendConfigOverrideIntArg(allocator, argv, owned_args, "model_context_window", value);
    if (overrides.model_auto_compact_token_limit) |value| try appendConfigOverrideIntArg(allocator, argv, owned_args, "model_auto_compact_token_limit", value);
    if (overrides.openai_base_url) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "openai_base_url", value);
    if (overrides.chatgpt_base_url) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "chatgpt_base_url", value);
    if (overrides.oss_provider) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "oss_provider", value);
    if (overrides.approval_policy) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "approval_policy", value.label());
    if (overrides.sandbox_mode) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "sandbox_mode", value.label());
    if (overrides.web_search_mode) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "web_search", value.label());
    if (overrides.service_tier) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "service_tier", value);
    if (overrides.model_reasoning_summary) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "model_reasoning_summary", value.label());
    if (overrides.model_verbosity) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "model_verbosity", value.label());
    if (overrides.syntax_theme) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "syntax_theme", value);
    if (overrides.personality) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "personality", value.label());
    if (overrides.tui_alternate_screen) |value| try appendConfigOverrideArg(allocator, argv, owned_args, "tui.alternate_screen", value.label());
}

fn applyDebugAppServerChildEnvOverrides(env_map: *std.process.Environ.Map, overrides: config.RuntimeOverrides) !void {
    // The app-server loads config inside request handlers, so base-url overrides
    // need the existing env hook in addition to the forwarded argv flags.
    const base_url = overrides.chatgpt_base_url orelse overrides.openai_base_url orelse return;
    try env_map.put("CODEX_ZIG_BASE_URL", base_url);
}

fn appendConfigOverrideArg(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]const u8),
    key: []const u8,
    value: []const u8,
) !void {
    const arg = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
    errdefer allocator.free(arg);
    try owned_args.append(allocator, arg);
    try argv.append(allocator, "-c");
    try argv.append(allocator, arg);
}

fn appendConfigOverrideIntArg(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]const u8),
    key: []const u8,
    value: i64,
) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(rendered);
    try appendConfigOverrideArg(allocator, argv, owned_args, key, rendered);
}

fn writeAppServerRequest(io_instance: *std.Io.Threaded, stdin_file: std.Io.File, request: []const u8) !void {
    try stdin_file.writeStreamingAll(io_instance.io(), request);
    try stdin_file.writeStreamingAll(io_instance.io(), "\n");
}

fn readDebugResponseLine(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    request_id: []const u8,
    label: []const u8,
) ![]const u8 {
    var lines_read: usize = 0;
    while (lines_read < 256) : (lines_read += 1) {
        const line = try readDebugAppServerLine(reader) orelse return error.DebugAppServerClosed;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) {
            try printDebugAppServerMessage("app-server message", line);
            continue;
        }
        const object = parsed.value.object;
        if (object.get("id")) |id_value| {
            if (jsonValueStringEquals(id_value, request_id)) {
                const response_label = try std.fmt.allocPrint(allocator, "{s} response", .{label});
                defer allocator.free(response_label);
                try printDebugAppServerMessage(response_label, line);
                if (object.get("error") != null) return error.DebugAppServerRequestFailed;
                return allocator.dupe(u8, line);
            }
        }
        if (object.get("method")) |method| {
            if (method == .string) {
                try printDebugAppServerMessage("notification", line);
                continue;
            }
        }
        try printDebugAppServerMessage("app-server message", line);
    }
    return error.DebugAppServerResponseNotFound;
}

fn streamDebugTurnUntilCompleted(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    thread_id: []const u8,
    turn_id: []const u8,
) !void {
    var lines_read: usize = 0;
    while (lines_read < 512) : (lines_read += 1) {
        const line = try readDebugAppServerLine(reader) orelse return error.DebugAppServerClosed;
        try printDebugAppServerMessage("notification", line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        if (object.get("error") != null) return error.DebugAppServerRequestFailed;
        const method = object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "turn/completed")) continue;
        if (debugTurnNotificationMatches(object, thread_id, turn_id)) return;
    }
    return error.DebugAppServerTurnIncomplete;
}

fn readDebugAppServerLine(reader: *std.Io.Reader) !?[]const u8 {
    const line_opt = try reader.takeDelimiter('\n');
    const line = line_opt orelse return null;
    return std.mem.trim(u8, line, " \t\r\n");
}

fn printDebugAppServerMessage(label: []const u8, line: []const u8) !void {
    try cli_utils.writeStdout("< ");
    try cli_utils.writeStdout(label);
    try cli_utils.writeStdout(": ");
    try cli_utils.writeStdout(line);
    try cli_utils.writeStdout("\n");
}

fn extractNestedString(allocator: std.mem.Allocator, response_line: []const u8, path: []const []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_line, .{});
    defer parsed.deinit();

    var current = parsed.value;
    for (path) |part| {
        if (current != .object) return error.InvalidDebugAppServerResponse;
        current = current.object.get(part) orelse return error.InvalidDebugAppServerResponse;
    }
    if (current != .string) return error.InvalidDebugAppServerResponse;
    return allocator.dupe(u8, current.string);
}

fn debugTurnNotificationMatches(object: std.json.ObjectMap, thread_id: []const u8, turn_id: []const u8) bool {
    const params = object.get("params") orelse return false;
    if (params != .object) return false;
    const notification_thread_id = params.object.get("threadId") orelse return false;
    if (!jsonValueStringEquals(notification_thread_id, thread_id)) return false;
    const turn = params.object.get("turn") orelse return false;
    if (turn != .object) return false;
    const notification_turn_id = turn.object.get("id") orelse return false;
    return jsonValueStringEquals(notification_turn_id, turn_id);
}

fn jsonValueStringEquals(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn childTermSuccess(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn currentEnvironmentMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    var index: usize = 0;
    while (std.c.environ[index]) |entry_ptr| : (index += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        try result.put(key, entry[eq + 1 ..]);
    }
    return result;
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
    const output_path = try trace_reduce.reduceBundleToFile(allocator, bundle, output);
    defer allocator.free(output_path);
    try cli_utils.writeStdout(output_path);
    try cli_utils.writeStdout("\n");
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
    var cleared_state_db = false;
    if (state_exists) {
        try memory_reset.clearMemoryStateDb(allocator, state_path);
        cleared_state_db = true;
    }

    try memory_reset.clearMemoryRootsContents(allocator, cfg.codex_home);

    const message = if (cleared_state_db)
        try std.fmt.allocPrint(
            allocator,
            "Cleared memory state from {s}. Cleared memory directories under {s}.\n",
            .{ state_path, cfg.codex_home },
        )
    else
        try std.fmt.allocPrint(
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

const ModelsResponse = struct {
    models: []const model_catalog.Entry,
};

fn renderModels(allocator: std.mem.Allocator, options: Options, bundled: bool) ![]const u8 {
    if (bundled) {
        return stringifyModels(allocator, model_catalog.bundled_models[0..]);
    }

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);

    const models = [_]model_catalog.Entry{model_catalog.configuredModel(cfg.model, "Configured Codex Zig model.")};
    return stringifyModels(allocator, models[0..]);
}

fn stringifyModels(allocator: std.mem.Allocator, models: []const model_catalog.Entry) ![]const u8 {
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
        \\  send-message-v2    Send a V2 debug message through the local app-server
        \\
    , .{});
}

fn printDebugAppServerSendMessageV2Help() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug app-server send-message-v2 USER_MESSAGE
        \\
        \\Spawns the local app-server over stdio, starts a thread, sends a
        \\turn/start text message, and prints responses and notifications.
        \\
    , .{});
}

fn printTraceReduceHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig debug trace-reduce [--output FILE] TRACE_BUNDLE
        \\
        \\Replays stable rollout trace bundle lifecycle events into state JSON.
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
    try std.testing.expectEqualStrings("gpt-5.5", model.get("slug").?.string);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"slug\": \"gpt-test\"") == null);
}

test "debug app-server forwards model config overrides" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    var owned_args = std.ArrayList([]const u8).empty;
    defer {
        for (owned_args.items) |value| allocator.free(value);
        owned_args.deinit(allocator);
    }

    try appendDebugAppServerChildOptions(allocator, &argv, &owned_args, .{
        .profile = "work",
        .runtime_overrides = .{
            .model_context_window = 128000,
            .model_auto_compact_token_limit = 96000,
            .model_reasoning_summary = .detailed,
            .model_verbosity = .high,
        },
    });

    const expected = [_][]const u8{
        "-p",
        "work",
        "-c",
        "model_context_window=128000",
        "-c",
        "model_auto_compact_token_limit=96000",
        "-c",
        "model_reasoning_summary=detailed",
        "-c",
        "model_verbosity=high",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}
