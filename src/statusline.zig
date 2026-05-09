const std = @import("std");

const config = @import("config.zig");
const session = @import("session.zig");

pub const Item = enum {
    model_name,
    model_with_reasoning,
    current_dir,
    project_root,
    git_branch,
    pull_request_number,
    branch_changes,
    run_state,
    context_remaining,
    context_used,
    five_hour_limit,
    weekly_limit,
    codex_version,
    context_window_size,
    used_tokens,
    total_input_tokens,
    total_output_tokens,
    session_id,
    fast_mode,
    raw_output,
    thread_title,
    task_progress,

    pub fn id(self: Item) []const u8 {
        return switch (self) {
            .model_name => "model",
            .model_with_reasoning => "model-with-reasoning",
            .current_dir => "current-dir",
            .project_root => "project-name",
            .git_branch => "git-branch",
            .pull_request_number => "pull-request-number",
            .branch_changes => "branch-changes",
            .run_state => "run-state",
            .context_remaining => "context-remaining",
            .context_used => "context-used",
            .five_hour_limit => "five-hour-limit",
            .weekly_limit => "weekly-limit",
            .codex_version => "codex-version",
            .context_window_size => "context-window-size",
            .used_tokens => "used-tokens",
            .total_input_tokens => "total-input-tokens",
            .total_output_tokens => "total-output-tokens",
            .session_id => "session-id",
            .fast_mode => "fast-mode",
            .raw_output => "raw-output",
            .thread_title => "thread-title",
            .task_progress => "task-progress",
        };
    }
};

pub const default_items = [_]Item{ .model_with_reasoning, .current_dir };

pub fn printUsage() void {
    std.debug.print(
        \\usage: /statusline [status|off|default|ITEM...]
        \\items: model, model-with-reasoning, current-dir, project-name, git-branch, pull-request-number, branch-changes, run-state, context-remaining, context-used, five-hour-limit, weekly-limit, codex-version, context-window-size, used-tokens, total-input-tokens, total-output-tokens, session-id, fast-mode, raw-output, thread-title, task-progress
        \\
    , .{});
}

pub fn itemsLabel(allocator: std.mem.Allocator, items: []const Item) ![]const u8 {
    if (items.len == 0) return allocator.dupe(u8, "<off>");

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (items, 0..) |item, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, item.id());
    }
    return output.toOwnedSlice(allocator);
}

pub fn buildPreview(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    items: []const Item,
    raw_output_mode: bool,
) ![]const u8 {
    if (items.len == 0) return allocator.dupe(u8, "<off>");

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (items) |item| {
        const maybe_value = try value(allocator, cfg, transcript, session_path, cwd, raw_output_mode, item);
        const item_value = maybe_value orelse continue;
        defer allocator.free(item_value);
        if (item_value.len == 0) continue;
        if (output.items.len > 0) try output.appendSlice(allocator, " | ");
        try output.appendSlice(allocator, item_value);
    }
    if (output.items.len == 0) try output.appendSlice(allocator, "<empty>");
    return output.toOwnedSlice(allocator);
}

pub fn value(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    raw_output_mode: bool,
    item: Item,
) !?[]const u8 {
    return switch (item) {
        .model_name => try allocator.dupe(u8, cfg.model),
        .model_with_reasoning => try std.fmt.allocPrint(allocator, "{s} medium", .{cfg.model}),
        .current_dir => try allocator.dupe(u8, cwd),
        .project_root => try allocator.dupe(u8, std.fs.path.basename(cwd)),
        .git_branch => try currentGitBranch(allocator, cwd),
        .pull_request_number => null,
        .branch_changes => null,
        .run_state => try allocator.dupe(u8, "Ready"),
        .context_remaining => null,
        .context_used => null,
        .five_hour_limit => null,
        .weekly_limit => null,
        .codex_version => try allocator.dupe(u8, "codex-zig 0.0.1"),
        .context_window_size => null,
        .used_tokens => null,
        .total_input_tokens => null,
        .total_output_tokens => null,
        .session_id => try sessionIdFromPath(allocator, session_path),
        .fast_mode => if (cfg.service_tier != null and std.mem.eql(u8, cfg.service_tier.?, "priority")) try allocator.dupe(u8, "fast") else null,
        .raw_output => if (raw_output_mode) try allocator.dupe(u8, "raw output") else null,
        .thread_title => if (transcript.title) |title| try allocator.dupe(u8, title) else null,
        .task_progress => null,
    };
}

fn currentGitBranch(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = std.process.run(allocator, io_instance.io(), .{
        .argv = &.{ "git", "branch", "--show-current" },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(1000),
            .clock = .awake,
        } },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return null;
    const branch = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (branch.len == 0) return null;
    return try allocator.dupe(u8, branch);
}

fn sessionIdFromPath(allocator: std.mem.Allocator, session_path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(session_path);
    if (std.mem.endsWith(u8, basename, ".jsonl")) {
        return allocator.dupe(u8, basename[0 .. basename.len - ".jsonl".len]);
    }
    return allocator.dupe(u8, basename);
}

pub fn parseItem(raw: []const u8) ?Item {
    if (std.ascii.eqlIgnoreCase(raw, "model") or std.ascii.eqlIgnoreCase(raw, "model-name")) return .model_name;
    if (std.ascii.eqlIgnoreCase(raw, "model-with-reasoning")) return .model_with_reasoning;
    if (std.ascii.eqlIgnoreCase(raw, "current-dir") or std.ascii.eqlIgnoreCase(raw, "cwd")) return .current_dir;
    if (std.ascii.eqlIgnoreCase(raw, "project-name") or std.ascii.eqlIgnoreCase(raw, "project") or std.ascii.eqlIgnoreCase(raw, "project-root")) return .project_root;
    if (std.ascii.eqlIgnoreCase(raw, "git-branch") or std.ascii.eqlIgnoreCase(raw, "branch")) return .git_branch;
    if (std.ascii.eqlIgnoreCase(raw, "pull-request-number") or std.ascii.eqlIgnoreCase(raw, "pr")) return .pull_request_number;
    if (std.ascii.eqlIgnoreCase(raw, "branch-changes")) return .branch_changes;
    if (std.ascii.eqlIgnoreCase(raw, "run-state") or std.ascii.eqlIgnoreCase(raw, "status")) return .run_state;
    if (std.ascii.eqlIgnoreCase(raw, "context-remaining")) return .context_remaining;
    if (std.ascii.eqlIgnoreCase(raw, "context-used") or std.ascii.eqlIgnoreCase(raw, "context-usage")) return .context_used;
    if (std.ascii.eqlIgnoreCase(raw, "five-hour-limit") or std.ascii.eqlIgnoreCase(raw, "5-hour-limit")) return .five_hour_limit;
    if (std.ascii.eqlIgnoreCase(raw, "weekly-limit")) return .weekly_limit;
    if (std.ascii.eqlIgnoreCase(raw, "codex-version") or std.ascii.eqlIgnoreCase(raw, "version")) return .codex_version;
    if (std.ascii.eqlIgnoreCase(raw, "context-window-size")) return .context_window_size;
    if (std.ascii.eqlIgnoreCase(raw, "used-tokens")) return .used_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "total-input-tokens")) return .total_input_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "total-output-tokens")) return .total_output_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "session-id") or std.ascii.eqlIgnoreCase(raw, "session")) return .session_id;
    if (std.ascii.eqlIgnoreCase(raw, "fast-mode") or std.ascii.eqlIgnoreCase(raw, "fast")) return .fast_mode;
    if (std.ascii.eqlIgnoreCase(raw, "raw-output") or std.ascii.eqlIgnoreCase(raw, "raw")) return .raw_output;
    if (std.ascii.eqlIgnoreCase(raw, "thread-title") or std.ascii.eqlIgnoreCase(raw, "title")) return .thread_title;
    if (std.ascii.eqlIgnoreCase(raw, "task-progress")) return .task_progress;
    return null;
}

pub fn containsItem(items: []const Item, target: Item) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

test "parses status line item aliases" {
    try std.testing.expectEqual(Item.model_name, parseItem("model").?);
    try std.testing.expectEqual(Item.model_name, parseItem("model-name").?);
    try std.testing.expectEqual(Item.project_root, parseItem("project-root").?);
    try std.testing.expectEqual(Item.project_root, parseItem("project").?);
    try std.testing.expectEqual(Item.run_state, parseItem("status").?);
    try std.testing.expectEqual(Item.context_used, parseItem("context-usage").?);
    try std.testing.expectEqual(Item.pull_request_number, parseItem("pull-request-number").?);
    try std.testing.expectEqual(Item.task_progress, parseItem("task-progress").?);
    try std.testing.expect(parseItem("missing") == null);
}

test "renders status line labels and previews known values" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.setTitle(allocator, "Demo Thread");

    const items = &.{ .model_name, .project_root, .thread_title, .fast_mode, .raw_output, .session_id };

    var cfg = try config.loadWithOptions(allocator, .{ .ignore_user_config = true });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, .{ .model = "gpt-demo", .service_tier = "priority" });

    const label = try itemsLabel(allocator, items);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("model, project-name, thread-title, fast-mode, raw-output, session-id", label);

    const preview = try buildPreview(allocator, cfg, &transcript, "/tmp/rollout-123.jsonl", "/tmp/codex-zig-port", items, true);
    defer allocator.free(preview);
    try std.testing.expectEqualStrings("gpt-demo | codex-zig-port | Demo Thread | fast | raw output | rollout-123", preview);
}
