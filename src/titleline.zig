const std = @import("std");

const config = @import("config.zig");
const session = @import("session.zig");
const statusline = @import("statusline.zig");

pub const Item = enum {
    app_name,
    project,
    current_dir,
    activity,
    run_state,
    thread_title,
    git_branch,
    context_remaining,
    context_used,
    five_hour_limit,
    weekly_limit,
    codex_version,
    used_tokens,
    total_input_tokens,
    total_output_tokens,
    session_id,
    fast_mode,
    model_name,
    model_with_reasoning,
    task_progress,

    pub fn id(self: Item) []const u8 {
        return switch (self) {
            .app_name => "app-name",
            .project => "project-name",
            .current_dir => "current-dir",
            .activity => "activity",
            .run_state => "run-state",
            .thread_title => "thread-title",
            .git_branch => "git-branch",
            .context_remaining => "context-remaining",
            .context_used => "context-used",
            .five_hour_limit => "five-hour-limit",
            .weekly_limit => "weekly-limit",
            .codex_version => "codex-version",
            .used_tokens => "used-tokens",
            .total_input_tokens => "total-input-tokens",
            .total_output_tokens => "total-output-tokens",
            .session_id => "session-id",
            .fast_mode => "fast-mode",
            .model_name => "model",
            .model_with_reasoning => "model-with-reasoning",
            .task_progress => "task-progress",
        };
    }
};

pub const default_items = [_]Item{ .activity, .project };
pub const default_ids = [_][]const u8{ "activity", "project-name" };

pub fn printUsage() void {
    std.debug.print(
        \\usage: /title [status|off|default|ITEM...]
        \\items: app-name, project-name, current-dir, activity, run-state, thread-title, git-branch, context-remaining, context-used, five-hour-limit, weekly-limit, codex-version, used-tokens, total-input-tokens, total-output-tokens, session-id, fast-mode, model, model-with-reasoning, task-progress
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
    return try output.toOwnedSlice(allocator);
}

pub fn build(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    items: []const Item,
    raw_output_mode: bool,
) !?[]const u8 {
    if (items.len == 0) return null;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var previous: ?Item = null;
    for (items) |item| {
        const maybe_value = try value(allocator, cfg, transcript, session_path, cwd, raw_output_mode, item);
        const item_value = maybe_value orelse continue;
        defer allocator.free(item_value);
        if (item_value.len == 0) continue;
        try output.appendSlice(allocator, separatorFromPrevious(previous, item));
        try output.appendSlice(allocator, item_value);
        previous = item;
    }
    if (output.items.len == 0) return null;
    return try output.toOwnedSlice(allocator);
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
    const maybe_title = try build(allocator, cfg, transcript, session_path, cwd, items, raw_output_mode);
    if (maybe_title) |title| return title;
    return allocator.dupe(u8, if (items.len == 0) "<off>" else "<empty>");
}

fn separatorFromPrevious(previous: ?Item, item: Item) []const u8 {
    if (previous == null) return "";
    if (previous.? == .activity or item == .activity) return " ";
    return " | ";
}

fn value(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    raw_output_mode: bool,
    item: Item,
) !?[]const u8 {
    return switch (item) {
        .app_name => try allocator.dupe(u8, "codex"),
        .project => try truncateOwned(allocator, try allocator.dupe(u8, std.fs.path.basename(cwd)), 24),
        .current_dir => try truncateOwned(allocator, try allocator.dupe(u8, cwd), 32),
        .activity => null,
        .run_state => try allocator.dupe(u8, "Ready"),
        .thread_title => if (transcript.title) |title| try truncateOwned(allocator, try allocator.dupe(u8, title), 48) else null,
        .git_branch => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .git_branch, 32),
        .context_remaining => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .context_remaining, 32),
        .context_used => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .context_used, 32),
        .five_hour_limit => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .five_hour_limit, 32),
        .weekly_limit => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .weekly_limit, 32),
        .codex_version => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .codex_version, 32),
        .used_tokens => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .used_tokens, 32),
        .total_input_tokens => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .total_input_tokens, 32),
        .total_output_tokens => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .total_output_tokens, 32),
        .session_id => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .session_id, 32),
        .fast_mode => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .fast_mode, 32),
        .model_name => try truncateOwned(allocator, try allocator.dupe(u8, cfg.model), 32),
        .model_with_reasoning => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .model_with_reasoning, 32),
        .task_progress => try truncatedStatusLineValue(allocator, cfg, transcript, session_path, cwd, raw_output_mode, .task_progress, 32),
    };
}

fn truncatedStatusLineValue(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    raw_output_mode: bool,
    item: statusline.Item,
    max_chars: usize,
) !?[]const u8 {
    const maybe_value = try statusline.value(allocator, cfg, transcript, session_path, cwd, raw_output_mode, item);
    const item_value = maybe_value orelse return null;
    return try truncateOwned(allocator, item_value, max_chars);
}

fn truncateOwned(allocator: std.mem.Allocator, value_bytes: []const u8, max_chars: usize) ![]const u8 {
    defer allocator.free(value_bytes);
    if (max_chars == 0) return allocator.dupe(u8, "");

    const view = std.unicode.Utf8View.init(value_bytes) catch {
        return truncateBytes(allocator, value_bytes, max_chars);
    };
    var iterator = view.iterator();
    var chars: usize = 0;
    var end: usize = 0;
    var truncated = false;
    while (iterator.nextCodepointSlice()) |codepoint_slice| {
        if (chars == max_chars) {
            truncated = true;
            break;
        }
        chars += 1;
        end = @intFromPtr(codepoint_slice.ptr) - @intFromPtr(value_bytes.ptr) + codepoint_slice.len;
    }
    if (!truncated) {
        return allocator.dupe(u8, value_bytes);
    }
    if (max_chars <= 3) return allocator.dupe(u8, value_bytes[0..end]);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    iterator = view.iterator();
    chars = 0;
    while (iterator.nextCodepointSlice()) |codepoint_slice| {
        if (chars == max_chars - 3) break;
        try output.appendSlice(allocator, codepoint_slice);
        chars += 1;
    }
    try output.appendSlice(allocator, "...");
    return output.toOwnedSlice(allocator);
}

fn truncateBytes(allocator: std.mem.Allocator, value_bytes: []const u8, max_chars: usize) ![]const u8 {
    if (value_bytes.len <= max_chars) return allocator.dupe(u8, value_bytes);
    if (max_chars <= 3) return allocator.dupe(u8, value_bytes[0..max_chars]);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, value_bytes[0 .. max_chars - 3]);
    try output.appendSlice(allocator, "...");
    return output.toOwnedSlice(allocator);
}

pub fn parseItem(raw: []const u8) ?Item {
    if (std.ascii.eqlIgnoreCase(raw, "app-name") or std.ascii.eqlIgnoreCase(raw, "app")) return .app_name;
    if (std.ascii.eqlIgnoreCase(raw, "project-name") or std.ascii.eqlIgnoreCase(raw, "project")) return .project;
    if (std.ascii.eqlIgnoreCase(raw, "current-dir") or std.ascii.eqlIgnoreCase(raw, "cwd")) return .current_dir;
    if (std.ascii.eqlIgnoreCase(raw, "activity") or std.ascii.eqlIgnoreCase(raw, "spinner")) return .activity;
    if (std.ascii.eqlIgnoreCase(raw, "run-state") or std.ascii.eqlIgnoreCase(raw, "status")) return .run_state;
    if (std.ascii.eqlIgnoreCase(raw, "thread-title") or std.ascii.eqlIgnoreCase(raw, "thread") or std.ascii.eqlIgnoreCase(raw, "title")) return .thread_title;
    if (std.ascii.eqlIgnoreCase(raw, "git-branch") or std.ascii.eqlIgnoreCase(raw, "branch")) return .git_branch;
    if (std.ascii.eqlIgnoreCase(raw, "context-remaining")) return .context_remaining;
    if (std.ascii.eqlIgnoreCase(raw, "context-used") or std.ascii.eqlIgnoreCase(raw, "context-usage")) return .context_used;
    if (std.ascii.eqlIgnoreCase(raw, "five-hour-limit") or std.ascii.eqlIgnoreCase(raw, "5-hour-limit")) return .five_hour_limit;
    if (std.ascii.eqlIgnoreCase(raw, "weekly-limit")) return .weekly_limit;
    if (std.ascii.eqlIgnoreCase(raw, "codex-version") or std.ascii.eqlIgnoreCase(raw, "version")) return .codex_version;
    if (std.ascii.eqlIgnoreCase(raw, "used-tokens")) return .used_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "total-input-tokens")) return .total_input_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "total-output-tokens")) return .total_output_tokens;
    if (std.ascii.eqlIgnoreCase(raw, "session-id") or std.ascii.eqlIgnoreCase(raw, "session")) return .session_id;
    if (std.ascii.eqlIgnoreCase(raw, "fast-mode") or std.ascii.eqlIgnoreCase(raw, "fast")) return .fast_mode;
    if (std.ascii.eqlIgnoreCase(raw, "model") or std.ascii.eqlIgnoreCase(raw, "model-name")) return .model_name;
    if (std.ascii.eqlIgnoreCase(raw, "model-with-reasoning")) return .model_with_reasoning;
    if (std.ascii.eqlIgnoreCase(raw, "task-progress")) return .task_progress;
    return null;
}

pub fn containsItem(items: []const Item, target: Item) bool {
    for (items) |item| {
        if (item == target) return true;
    }
    return false;
}

test "parses terminal title item aliases" {
    try std.testing.expectEqual(Item.app_name, parseItem("app").?);
    try std.testing.expectEqual(Item.project, parseItem("project-name").?);
    try std.testing.expectEqual(Item.activity, parseItem("spinner").?);
    try std.testing.expectEqual(Item.run_state, parseItem("status").?);
    try std.testing.expectEqual(Item.thread_title, parseItem("thread").?);
    try std.testing.expectEqual(Item.model_name, parseItem("model-name").?);
    try std.testing.expect(parseItem("missing") == null);
}

test "renders terminal title labels and preview" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    try transcript.setTitle(allocator, "Demo Thread");

    const items = &.{ .app_name, .thread_title, .model_name, .fast_mode };

    var cfg = try config.loadWithOptions(allocator, .{ .ignore_user_config = true });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, .{ .model = "gpt-demo", .service_tier = "priority" });

    const label = try itemsLabel(allocator, items);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("app-name, thread-title, model, fast-mode", label);

    const preview = try buildPreview(allocator, cfg, &transcript, "/tmp/rollout-123.jsonl", "/tmp/codex-zig-port", items, false);
    defer allocator.free(preview);
    try std.testing.expectEqualStrings("codex | Demo Thread | gpt-demo | fast", preview);
}

test "truncates terminal title parts without splitting UTF-8" {
    const allocator = std.testing.allocator;
    const truncated = try truncateOwned(allocator, try allocator.dupe(u8, "alpha🚀beta"), 8);
    defer allocator.free(truncated);
    try std.testing.expectEqualStrings("alpha...", truncated);
}
