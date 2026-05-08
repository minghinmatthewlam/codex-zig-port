const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");
const session = @import("session.zig");

const ExecArgs = struct {
    auto_approve: bool = false,
    json: bool = false,
    help: bool = false,
    last_message_file: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    read_stdin: bool = false,

    fn deinit(self: ExecArgs, allocator: std.mem.Allocator) void {
        if (self.last_message_file) |path| allocator.free(path);
        if (self.prompt) |prompt| allocator.free(prompt);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    const parsed = try parseArgs(allocator, raw_args.items);
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printHelp();
        return;
    }

    if (parsed.prompt == null and !parsed.read_stdin) {
        std.debug.print("codex-zig exec requires a prompt or - for stdin\n", .{});
        return error.MissingExecPrompt;
    }

    const prompt = if (parsed.read_stdin)
        try readPromptFromStdin(allocator, parsed.prompt)
    else
        try allocator.dupe(u8, parsed.prompt.?);
    defer allocator.free(prompt);

    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, &transcript, prompt, .{
        .auto_approve = parsed.auto_approve,
        .prompt_for_approval = false,
        .json_events = parsed.json,
    });
    defer allocator.free(answer);

    if (parsed.last_message_file) |path| {
        try writeFile(path, answer);
    }

    if (!parsed.json) {
        try writeStdout(answer);
        if (answer.len == 0 or answer[answer.len - 1] != '\n') {
            try writeStdout("\n");
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ExecArgs {
    var parsed = ExecArgs{};
    errdefer parsed.deinit(allocator);

    var prompt_parts = std.ArrayList([]const u8).empty;
    defer prompt_parts.deinit(allocator);

    var index: usize = 0;
    var end_options = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--auto-approve")) {
            parsed.auto_approve = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--experimental-json"))) {
            parsed.json = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--output-last-message") or std.mem.eql(u8, arg, "-o"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.last_message_file) |existing| {
                allocator.free(existing);
                parsed.last_message_file = null;
            }
            parsed.last_message_file = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            parsed.help = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            std.debug.print("unknown exec option: {s}\n", .{arg});
            return error.UnknownExecOption;
        }

        if (std.mem.eql(u8, arg, "-") and prompt_parts.items.len == 0) {
            parsed.read_stdin = true;
        } else {
            try prompt_parts.append(allocator, arg);
        }
    }

    if (prompt_parts.items.len > 0) {
        parsed.prompt = try joinPrompt(allocator, prompt_parts.items);
    }

    return parsed;
}

fn joinPrompt(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var joined = std.ArrayList(u8).empty;
    errdefer joined.deinit(allocator);
    for (parts, 0..) |part, index| {
        if (index > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, part);
    }
    return joined.toOwnedSlice(allocator);
}

fn readPromptFromStdin(allocator: std.mem.Allocator, prefix: ?[]const u8) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdin_text = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stdin_text);

    if (prefix) |text| {
        var combined = std.ArrayList(u8).empty;
        errdefer combined.deinit(allocator);
        try combined.appendSlice(allocator, text);
        try combined.appendSlice(allocator, "\n\n<stdin>\n");
        try combined.appendSlice(allocator, stdin_text);
        try combined.appendSlice(allocator, "\n</stdin>");
        allocator.free(stdin_text);
        return combined.toOwnedSlice(allocator);
    }

    return stdin_text;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = bytes,
    });
}

fn writeStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(bytes);
    try stdout.flush();
}

fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig exec [OPTIONS] [PROMPT]
        \\  codex-zig exec [OPTIONS] -
        \\
        \\Options:
        \\  --auto-approve          Run requested tools without prompting
        \\  --json                  Emit JSONL events instead of plain final text
        \\  -o, --output-last-message FILE
        \\                          Write final answer to FILE
        \\
    , .{});
}

test "exec args parse prompt and options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--auto-approve", "--json", "-o", "last.txt", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.auto_approve);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("last.txt", parsed.last_message_file.?);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args parse stdin sentinel with context prompt" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "-", "summarize", "this" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.read_stdin);
    try std.testing.expectEqualStrings("summarize this", parsed.prompt.?);
}
