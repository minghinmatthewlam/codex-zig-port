const std = @import("std");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const git_diff = @import("git_diff.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

const ReviewArgs = struct {
    help: bool = false,
    uncommitted: bool = false,
    base: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    commit_title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    read_stdin: bool = false,

    fn deinit(self: ReviewArgs, allocator: std.mem.Allocator) void {
        if (self.base) |base| allocator.free(base);
        if (self.commit) |commit| allocator.free(commit);
        if (self.commit_title) |title| allocator.free(title);
        if (self.prompt) |prompt| allocator.free(prompt);
    }
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    ignore_user_config: bool = false,
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    try runRawArgsWithOptions(allocator, raw_args.items, options);
}

pub fn runRawArgsWithOptions(allocator: std.mem.Allocator, raw_args: []const []const u8, options: Options) !void {
    var parsed = try parseArgs(allocator, raw_args);
    defer parsed.deinit(allocator);
    if (parsed.help) {
        printHelp();
        return;
    }

    var cfg = try config.loadWithOptions(allocator, .{
        .profile = options.profile,
        .ignore_user_config = options.ignore_user_config,
    });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (options.oss) {
        try config.applyOssMode(&cfg, allocator, options.oss_provider, options.runtime_overrides.model != null);
    }

    var credentials = if (options.oss)
        try auth.localOssCredentials(allocator)
    else
        try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    const prompt = if (parsed.read_stdin) prompt: {
        try cli_utils.writeStderr("Reading review prompt from stdin...\n");
        const stdin_prompt = try readPromptFromStdin(allocator);
        defer allocator.free(stdin_prompt);
        break :prompt try buildCustomPrompt(allocator, stdin_prompt);
    } else try buildPrompt(allocator, parsed);
    defer allocator.free(prompt);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    const session_path = try session_store.createSessionPath(allocator, cfg.codex_home);
    defer allocator.free(session_path);

    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, &transcript, prompt, .{
        .prompt_for_approval = false,
    });
    defer allocator.free(answer);

    try session_store.saveTranscript(allocator, session_path, &transcript);
    try cli_utils.writeStdout(answer);
    if (answer.len == 0 or answer[answer.len - 1] != '\n') {
        try cli_utils.writeStdout("\n");
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ReviewArgs {
    var parsed = ReviewArgs{};
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
        if (!end_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            parsed.help = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--uncommitted")) {
            parsed.uncommitted = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--base")) {
            index += 1;
            if (index >= args.len) return error.MissingReviewOptionValue;
            try setRevisionOption(allocator, &parsed.base, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--base=")) {
            try setRevisionOption(allocator, &parsed.base, arg["--base=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--commit")) {
            index += 1;
            if (index >= args.len) return error.MissingReviewOptionValue;
            try setRevisionOption(allocator, &parsed.commit, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--commit=")) {
            try setRevisionOption(allocator, &parsed.commit, arg["--commit=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--title")) {
            index += 1;
            if (index >= args.len) return error.MissingReviewOptionValue;
            try setRequiredOption(allocator, &parsed.commit_title, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--title=")) {
            try setRequiredOption(allocator, &parsed.commit_title, arg["--title=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "-") and prompt_parts.items.len == 0) {
            parsed.read_stdin = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownReviewOption;
        }

        try prompt_parts.append(allocator, arg);
    }

    var target_count: usize = 0;
    if (parsed.uncommitted) target_count += 1;
    if (parsed.base != null) target_count += 1;
    if (parsed.commit != null) target_count += 1;
    if (parsed.read_stdin) target_count += 1;
    if (prompt_parts.items.len > 0) target_count += 1;
    if (target_count > 1) return error.InvalidReviewArguments;
    if (parsed.commit_title != null and parsed.commit == null) return error.InvalidReviewArguments;

    if (prompt_parts.items.len > 0) {
        parsed.prompt = try cli_utils.joinWithSpaces(allocator, prompt_parts.items);
    }
    if (!parsed.help and !parsed.uncommitted and parsed.base == null and parsed.commit == null and !parsed.read_stdin and parsed.prompt == null) return error.MissingReviewTarget;

    return parsed;
}

fn readPromptFromStdin(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdin_text = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stdin_text);

    if (std.mem.trim(u8, stdin_text, " \t\r\n").len == 0) {
        std.debug.print("No review prompt provided via stdin.\n", .{});
        return error.MissingReviewTarget;
    }

    return stdin_text;
}

fn setRevisionOption(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !void {
    try git_diff.validateRevision(value);
    try setOwnedOption(allocator, field, value);
}

fn setRequiredOption(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !void {
    if (value.len == 0) return error.MissingReviewOptionValue;
    try setOwnedOption(allocator, field, value);
}

fn setOwnedOption(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !void {
    if (field.*) |existing| allocator.free(existing);
    field.* = try allocator.dupe(u8, value);
}

fn buildPrompt(allocator: std.mem.Allocator, args: ReviewArgs) ![]const u8 {
    if (args.uncommitted) {
        return buildUncommittedPrompt(allocator);
    }

    if (args.base) |base| {
        return buildBasePrompt(allocator, base);
    }

    if (args.commit) |commit| {
        return buildCommitPrompt(allocator, commit, args.commit_title);
    }

    const prompt = args.prompt orelse return error.MissingReviewTarget;
    return buildCustomPrompt(allocator, prompt);
}

pub fn buildUncommittedPrompt(allocator: std.mem.Allocator) ![]const u8 {
    const diff = try git_diff.render(allocator);
    defer allocator.free(diff);
    return std.fmt.allocPrint(allocator,
        \\Review the uncommitted changes below. Focus on bugs, behavioral regressions, security issues, and missing tests. Report findings first, ordered by severity, and say clearly if no actionable issues are found.
        \\
        \\```diff
        \\{s}
        \\```
    , .{diff});
}

pub fn buildBasePrompt(allocator: std.mem.Allocator, branch: []const u8) ![]const u8 {
    const diff = try git_diff.renderBase(allocator, branch);
    defer allocator.free(diff);
    return std.fmt.allocPrint(allocator,
        \\Review the changes against base branch `{s}` below. Focus on bugs, behavioral regressions, security issues, and missing tests. Report findings first, ordered by severity, and say clearly if no actionable issues are found.
        \\
        \\```diff
        \\{s}
        \\```
    , .{ branch, diff });
}

pub fn buildCommitPrompt(allocator: std.mem.Allocator, commit: []const u8, title: ?[]const u8) ![]const u8 {
    const diff = try git_diff.renderCommit(allocator, commit);
    defer allocator.free(diff);
    const title_block = if (title) |value|
        try std.fmt.allocPrint(allocator, "Commit title: {s}\n\n", .{value})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(title_block);
    return std.fmt.allocPrint(allocator,
        \\Review the changes introduced by commit `{s}` below. Focus on bugs, behavioral regressions, security issues, and missing tests. Report findings first, ordered by severity, and say clearly if no actionable issues are found.
        \\
        \\{s}```diff
        \\{s}
        \\```
    , .{ commit, title_block, diff });
}

pub fn buildCustomPrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return error.MissingReviewTarget;
    return std.fmt.allocPrint(allocator,
        \\Review according to these instructions:
        \\
        \\{s}
    , .{trimmed});
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig review --uncommitted
        \\  codex-zig review --base BRANCH
        \\  codex-zig review --commit SHA [--title TITLE]
        \\  codex-zig review PROMPT
        \\
        \\Options:
        \\  --uncommitted     Review staged, unstaged, and untracked changes
        \\  --base BRANCH     Review changes against the merge base with BRANCH
        \\  --commit SHA      Review the changes introduced by a commit
        \\  --title TITLE     Optional title for --commit review context
        \\
        \\Planned:
        \\  structured review JSON
        \\
    , .{});
}

test "review args parse uncommitted" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--uncommitted"};
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.uncommitted);
    try std.testing.expect(parsed.prompt == null);
}

test "review args join custom prompt" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "check", "this" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("check this", parsed.prompt.?);
}

test "review args parse stdin prompt sentinel" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"-"};
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.read_stdin);
    try std.testing.expect(parsed.prompt == null);
}

test "review args parse commit and title" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--commit", "abc123", "--title", "demo commit" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("abc123", parsed.commit.?);
    try std.testing.expectEqualStrings("demo commit", parsed.commit_title.?);
}

test "review args parse base" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--base", "main" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("main", parsed.base.?);
}

test "review args reject title without commit" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--title", "orphan" };
    try std.testing.expectError(error.InvalidReviewArguments, parseArgs(allocator, argv[0..]));
}

test "review args reject invalid commit values before prompt building" {
    const allocator = std.testing.allocator;
    {
        const argv = [_][]const u8{"--commit="};
        try std.testing.expectError(error.InvalidGitRevision, parseArgs(allocator, argv[0..]));
    }
    {
        const argv = [_][]const u8{ "--commit", "--stat" };
        try std.testing.expectError(error.InvalidGitRevision, parseArgs(allocator, argv[0..]));
    }
}

test "review args reject conflicting base and commit targets" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--base", "main", "--commit", "abc123" };
    try std.testing.expectError(error.InvalidReviewArguments, parseArgs(allocator, argv[0..]));
}

test "review args reject empty title values" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--title="};
    try std.testing.expectError(error.MissingReviewOptionValue, parseArgs(allocator, argv[0..]));
}
