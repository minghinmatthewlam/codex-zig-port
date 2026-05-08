const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const workdir = @import("workdir.zig");

const ExecArgs = struct {
    auto_approve: bool = false,
    ephemeral: bool = false,
    json: bool = false,
    help: bool = false,
    last_message_file: ?[]const u8 = null,
    model: ?[]const u8 = null,
    approval_policy: ?config.ApprovalPolicy = null,
    sandbox_mode: ?config.SandboxMode = null,
    profile: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    resume_target: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    read_stdin: bool = false,

    fn deinit(self: ExecArgs, allocator: std.mem.Allocator) void {
        if (self.last_message_file) |path| allocator.free(path);
        if (self.model) |model| allocator.free(model);
        if (self.profile) |profile| allocator.free(profile);
        if (self.cwd) |cwd| allocator.free(cwd);
        if (self.resume_target) |target| allocator.free(target);
        if (self.prompt) |prompt| allocator.free(prompt);
    }
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    cwd: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    try runWithOptions(allocator, args, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    var parsed = try parseArgs(allocator, raw_args.items);
    defer parsed.deinit(allocator);
    if (parsed.profile == null) {
        if (options.profile) |profile| {
            parsed.profile = try allocator.dupe(u8, profile);
        }
    }

    if (parsed.help) {
        printHelp();
        return;
    }

    if (parsed.prompt == null and !parsed.read_stdin) {
        std.debug.print("codex-zig exec requires a prompt or - for stdin\n", .{});
        return error.MissingExecPrompt;
    }

    const effective_cwd = parsed.cwd orelse options.cwd;
    if (effective_cwd) |cwd| try workdir.change(cwd);

    const prompt = if (parsed.read_stdin)
        try readPromptFromStdin(allocator, parsed.prompt)
    else
        try allocator.dupe(u8, parsed.prompt.?);
    defer allocator.free(prompt);

    var cfg = try config.loadWithOptions(allocator, .{ .profile = parsed.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (parsed.model) |model| {
        try config.applyRuntimeOverrides(&cfg, allocator, .{ .model = model });
    }
    if (parsed.approval_policy) |approval_policy| cfg.approval_policy = approval_policy;
    if (parsed.sandbox_mode) |sandbox_mode| cfg.sandbox_mode = sandbox_mode;

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var session_path: ?[]const u8 = null;
    defer if (session_path) |path| allocator.free(path);
    if (!parsed.ephemeral) {
        if (parsed.resume_target) |target| {
            session_path = try session_store.resolveResumePath(allocator, cfg.codex_home, target);
            const loaded = try session_store.loadTranscript(allocator, session_path.?);
            transcript.deinit(allocator);
            transcript = loaded;
        } else {
            session_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        }
    }

    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, &transcript, prompt, .{
        .auto_approve = parsed.auto_approve,
        .prompt_for_approval = false,
        .json_events = parsed.json,
    });
    defer allocator.free(answer);

    if (session_path) |path| {
        try session_store.saveTranscript(allocator, path, &transcript);
    }

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
    var resume_mode = false;
    var resume_target_set = false;
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
        if (!end_options and (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo"))) {
            parsed.approval_policy = .never;
            parsed.sandbox_mode = .danger_full_access;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.model) |existing| {
                allocator.free(existing);
                parsed.model = null;
            }
            parsed.model = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--model=")) {
            if (parsed.model) |existing| {
                allocator.free(existing);
                parsed.model = null;
            }
            parsed.model = try allocator.dupe(u8, arg["--model=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--ephemeral")) {
            parsed.ephemeral = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.cwd) |existing| {
                allocator.free(existing);
                parsed.cwd = null;
            }
            parsed.cwd = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--cd=")) {
            if (parsed.cwd) |existing| {
                allocator.free(existing);
                parsed.cwd = null;
            }
            parsed.cwd = try allocator.dupe(u8, arg["--cd=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            parsed.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--approval-policy")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--sandbox")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--sandbox=")) {
            parsed.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.profile) |existing| {
                allocator.free(existing);
                parsed.profile = null;
            }
            parsed.profile = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--profile=")) {
            if (parsed.profile) |existing| {
                allocator.free(existing);
                parsed.profile = null;
            }
            parsed.profile = try allocator.dupe(u8, arg["--profile=".len..]);
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
        if (!end_options and resume_mode and std.mem.eql(u8, arg, "--last")) {
            try setResumeTarget(allocator, &parsed, "last");
            resume_target_set = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            std.debug.print("unknown exec option: {s}\n", .{arg});
            return error.UnknownExecOption;
        }

        if (!end_options and !resume_mode and prompt_parts.items.len == 0 and std.mem.eql(u8, arg, "resume")) {
            resume_mode = true;
            continue;
        }

        if (resume_mode and !resume_target_set) {
            try setResumeTarget(allocator, &parsed, arg);
            resume_target_set = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-") and prompt_parts.items.len == 0) {
            parsed.read_stdin = true;
        } else {
            try prompt_parts.append(allocator, arg);
        }
    }

    if (resume_mode and !resume_target_set) {
        try setResumeTarget(allocator, &parsed, "last");
    }

    if (prompt_parts.items.len > 0) {
        parsed.prompt = try joinPrompt(allocator, prompt_parts.items);
    }

    return parsed;
}

fn setResumeTarget(allocator: std.mem.Allocator, parsed: *ExecArgs, target: []const u8) !void {
    if (parsed.resume_target) |existing| allocator.free(existing);
    parsed.resume_target = try allocator.dupe(u8, target);
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
        \\  codex-zig exec [OPTIONS] resume [last|ID|PATH] PROMPT
        \\
        \\Options:
        \\  --auto-approve          Run requested tools without prompting
        \\  --yolo                  Danger: approval=never and sandbox=danger-full-access
        \\  -m, --model MODEL       Override the model
        \\  --ephemeral             Do not save or resume a session file
        \\  -C, --cd DIR            Use DIR as the working root
        \\  -a, --ask-for-approval MODE
        \\                          untrusted, on-failure, on-request, or never
        \\  --approval-policy MODE  Alias for --ask-for-approval
        \\  -s, --sandbox MODE      read-only, workspace-write, or danger-full-access
        \\  -p, --profile PROFILE   Select a config profile
        \\  --json                  Emit JSONL events instead of plain final text
        \\  -o, --output-last-message FILE
        \\                          Write final answer to FILE
        \\
    , .{});
}

test "exec args parse prompt and options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--auto-approve", "--json", "--profile", "work", "-m", "gpt-test", "--cd", "/tmp/demo", "-o", "last.txt", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.auto_approve);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("work", parsed.profile.?);
    try std.testing.expectEqualStrings("gpt-test", parsed.model.?);
    try std.testing.expectEqualStrings("/tmp/demo", parsed.cwd.?);
    try std.testing.expectEqualStrings("last.txt", parsed.last_message_file.?);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args parse resume last prompt" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--json", "resume", "last", "say", "again" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("last", parsed.resume_target.?);
    try std.testing.expectEqualStrings("say again", parsed.prompt.?);
}

test "exec args parse resume --last stdin" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "resume", "--last", "-" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("last", parsed.resume_target.?);
    try std.testing.expect(parsed.read_stdin);
}

test "exec args parse ephemeral" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--ephemeral", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.ephemeral);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args keep resume literal after end options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--", "resume", "this", "prompt" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.resume_target == null);
    try std.testing.expectEqualStrings("resume this prompt", parsed.prompt.?);
}

test "exec args parse approval and sandbox options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--approval-policy", "never", "--sandbox", "read-only", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(config.ApprovalPolicy.never, parsed.approval_policy.?);
    try std.testing.expectEqual(config.SandboxMode.read_only, parsed.sandbox_mode.?);
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
