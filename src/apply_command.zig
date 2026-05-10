const std = @import("std");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const env = @import("env.zig");

const ApplyArgs = struct {
    help: bool = false,
    task_id: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    const parsed = try parseArgs(raw_args.items);
    if (parsed.help) {
        printHelp();
        return;
    }
    const task_id = parsed.task_id orelse {
        printHelp();
        return error.MissingApplyTaskId;
    };

    const active_profile = parsed.profile orelse options.profile;
    var cfg = try config.loadWithOptions(allocator, .{ .profile = active_profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    try config.applyRuntimeOverrides(&cfg, allocator, parsed.runtime_overrides);

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    const response_body = try fetchTask(allocator, cfg, credentials, task_id);
    defer allocator.free(response_body);

    const diff = try extractPrDiff(allocator, response_body);
    defer allocator.free(diff);

    try applyGitDiff(allocator, diff);
}

fn parseArgs(args: []const []const u8) !ApplyArgs {
    var parsed = ApplyArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigOptionValue;
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, arg["--config=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownApplyOption;
        if (parsed.task_id != null) return error.UnexpectedApplyArgument;
        parsed.task_id = arg;
    }
    return parsed;
}

fn fetchTask(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    task_id: []const u8,
) ![]const u8 {
    if (credentials.mode != .chatgpt and credentials.mode != .agent_identity) {
        return error.ChatGptBackendAuthRequired;
    }
    const account_id = credentials.account_id orelse return error.MissingChatGptAccountId;

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/wham/tasks/{s}",
        .{ std.mem.trimEnd(u8, cfg.chatgpt_base_url, "/"), task_id },
    );
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    try headers.append(allocator, .{ .name = "ChatGPT-Account-ID", .value = account_id });
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
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });

    const body = try response_body.toOwnedSlice();
    errdefer allocator.free(body);
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        std.debug.print("ChatGPT task request failed with status {d}: {s}\n", .{ @intFromEnum(result.status), body });
        return error.TaskRequestFailed;
    }
    return body;
}

fn extractPrDiff(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskResponse;

    const turn = parsed.value.object.get("current_diff_task_turn") orelse return error.NoDiffTurnFound;
    if (turn == .null) return error.NoDiffTurnFound;
    if (turn != .object) return error.InvalidTaskResponse;

    const items = turn.object.get("output_items") orelse return error.NoPrOutputItemFound;
    if (items != .array) return error.InvalidTaskResponse;

    for (items.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "pr")) continue;
        const output_diff = item.object.get("output_diff") orelse return error.InvalidTaskResponse;
        if (output_diff != .object) return error.InvalidTaskResponse;
        const diff = output_diff.object.get("diff") orelse return error.InvalidTaskResponse;
        if (diff != .string) return error.InvalidTaskResponse;
        return allocator.dupe(u8, diff.string);
    }
    return error.NoPrOutputItemFound;
}

fn applyGitDiff(allocator: std.mem.Allocator, diff: []const u8) !void {
    const git_root = try resolveGitRoot(allocator);
    defer allocator.free(git_root);

    const patch_path = try writeTemporaryPatch(allocator, diff);
    defer {
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), patch_path) catch {};
        allocator.free(patch_path);
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "apply", "--3way", patch_path };
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .cwd = .{ .path = git_root },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try cli_utils.writeStdout(result.stdout);
    try cli_utils.writeStderr(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                try cli_utils.writeStdout("Successfully applied diff\n");
                return;
            }
            std.debug.print("Git apply failed (exit {d})\n", .{code});
            return error.GitApplyFailed;
        },
        else => return error.GitApplyTerminated,
    }
}

fn resolveGitRoot(allocator: std.mem.Allocator) ![]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            try cli_utils.writeStderr(result.stderr);
            return error.NotGitRepository;
        },
        else => return error.GitRevParseTerminated,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyGitRoot;
    return allocator.dupe(u8, trimmed);
}

fn writeTemporaryPatch(allocator: std.mem.Allocator, diff: []const u8) ![]const u8 {
    const tmpdir = try env.getOwned(allocator, "TMPDIR");
    defer if (tmpdir) |value| allocator.free(value);
    const dir = tmpdir orelse "/tmp";

    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);

    const filename = try std.fmt.allocPrint(allocator, "codex-zig-apply-{d}-{x}.diff", .{ timestamp, random_id });
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = diff });
    return path;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig apply TASK_ID [OPTIONS]
        \\  codex-zig a TASK_ID [OPTIONS]
        \\
        \\Applies the latest PR diff from a Codex agent task to the current git
        \\repository with `git apply --3way`.
        \\
        \\Options:
        \\  -c, --config key=value  Override a supported config value
        \\  -h, --help              Print help
        \\
    , .{});
}

test "apply command extracts PR diff from task response" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "current_diff_task_turn": {
        \\    "output_items": [
        \\      {"type": "message", "content": []},
        \\      {"type": "pr", "output_diff": {"diff": "diff --git a/a.txt b/a.txt\n"}}
        \\    ]
        \\  }
        \\}
    ;

    const diff = try extractPrDiff(allocator, body);
    defer allocator.free(diff);
    try std.testing.expectEqualStrings("diff --git a/a.txt b/a.txt\n", diff);
}

test "apply command reports missing PR diff" {
    const allocator = std.testing.allocator;
    const body =
        \\{"current_diff_task_turn":{"output_items":[{"type":"message"}]}}
    ;
    try std.testing.expectError(error.NoPrOutputItemFound, extractPrDiff(allocator, body));
}

test "apply command parses task and config override" {
    const argv = [_][]const u8{ "task_123", "-c", "model=gpt-test" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqualStrings("task_123", parsed.task_id.?);
    try std.testing.expectEqualStrings("gpt-test", parsed.runtime_overrides.model.?);
}
