const std = @import("std");

const config = @import("config.zig");
const session = @import("session.zig");

const baseline_context_tokens: i64 = 12000;

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
        .context_remaining => try std.fmt.allocPrint(allocator, "Context {d}% left", .{contextRemainingPercent(cfg, transcript)}),
        .context_used => try std.fmt.allocPrint(allocator, "Context {d}% used", .{contextUsedPercent(cfg, transcript)}),
        .five_hour_limit => null,
        .weekly_limit => null,
        .codex_version => try allocator.dupe(u8, "codex-zig 0.0.1"),
        .context_window_size => if (contextWindowSize(cfg, transcript)) |window|
            try formatTokenStatusValue(allocator, window, "window")
        else
            null,
        .used_tokens => if (totalUsage(transcript).total_tokens > 0)
            try formatTokenStatusValue(allocator, totalUsage(transcript).total_tokens, "used")
        else
            null,
        .total_input_tokens => try formatTokenStatusValue(allocator, totalUsage(transcript).input_tokens, "in"),
        .total_output_tokens => try formatTokenStatusValue(allocator, totalUsage(transcript).output_tokens, "out"),
        .session_id => try sessionIdFromPath(allocator, session_path),
        .fast_mode => if (cfg.service_tier != null and std.mem.eql(u8, cfg.service_tier.?, "priority")) try allocator.dupe(u8, "fast") else null,
        .raw_output => if (raw_output_mode) try allocator.dupe(u8, "raw output") else null,
        .thread_title => if (transcript.title) |title| try allocator.dupe(u8, title) else null,
        .task_progress => try transcript.plan.progressLabel(allocator),
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

fn contextWindowSize(cfg: config.Config, transcript: *const session.Transcript) ?i64 {
    if (transcript.token_usage) |info| {
        if (info.model_context_window) |window| return window;
    }
    return cfg.model_context_window;
}

fn contextRemainingPercent(cfg: config.Config, transcript: *const session.Transcript) i64 {
    const window = contextWindowSize(cfg, transcript) orelse return 100;
    const usage = if (transcript.token_usage) |info| info.last else session.TokenUsage{};
    return percentOfContextWindowRemaining(usage, window);
}

fn contextUsedPercent(cfg: config.Config, transcript: *const session.Transcript) i64 {
    return clampPercent(100 - contextRemainingPercent(cfg, transcript));
}

fn totalUsage(transcript: *const session.Transcript) session.TokenUsage {
    return if (transcript.token_usage) |info| info.total else session.TokenUsage{};
}

fn percentOfContextWindowRemaining(usage: session.TokenUsage, context_window: i64) i64 {
    if (context_window <= baseline_context_tokens) return 0;

    const effective_window = context_window - baseline_context_tokens;
    const context_tokens = @max(usage.total_tokens, 0);
    const used = @max(context_tokens - baseline_context_tokens, 0);
    const remaining = @max(effective_window - used, 0);
    const rounded = roundedDiv(@as(i128, remaining) * 100, effective_window);
    return clampPercent(@intCast(rounded));
}

fn clampPercent(percent: i64) i64 {
    return @min(@max(percent, 0), 100);
}

fn formatTokenStatusValue(allocator: std.mem.Allocator, tokens: i64, label: []const u8) ![]const u8 {
    const compact = try formatTokensCompact(allocator, tokens);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ compact, label });
}

fn formatTokensCompact(allocator: std.mem.Allocator, raw_value: i64) ![]const u8 {
    const token_count = @max(raw_value, 0);
    if (token_count < 1000) return std.fmt.allocPrint(allocator, "{d}", .{token_count});

    const divisor: i128, const suffix: []const u8 = if (token_count >= 1_000_000_000_000)
        .{ 1_000_000_000_000, "T" }
    else if (token_count >= 1_000_000_000)
        .{ 1_000_000_000, "B" }
    else if (token_count >= 1_000_000)
        .{ 1_000_000, "M" }
    else
        .{ 1_000, "K" };

    if (@as(i128, token_count) < divisor * 10) {
        const scaled_100 = roundedDiv(@as(i128, token_count) * 100, divisor);
        return formatScaledTokens(allocator, scaled_100, 2, suffix);
    }
    if (@as(i128, token_count) < divisor * 100) {
        const scaled_10 = roundedDiv(@as(i128, token_count) * 10, divisor);
        return formatScaledTokens(allocator, scaled_10, 1, suffix);
    }
    const scaled = roundedDiv(token_count, divisor);
    return std.fmt.allocPrint(allocator, "{d}{s}", .{ scaled, suffix });
}

fn formatScaledTokens(
    allocator: std.mem.Allocator,
    scaled: i128,
    decimals: u8,
    suffix: []const u8,
) ![]const u8 {
    if (decimals == 2) {
        const whole = @divTrunc(scaled, 100);
        const fraction = @mod(scaled, 100);
        if (fraction == 0) return std.fmt.allocPrint(allocator, "{d}{s}", .{ whole, suffix });
        if (@mod(fraction, 10) == 0) return std.fmt.allocPrint(allocator, "{d}.{d}{s}", .{ whole, @divTrunc(fraction, 10), suffix });
        if (fraction < 10) return std.fmt.allocPrint(allocator, "{d}.0{d}{s}", .{ whole, fraction, suffix });
        return std.fmt.allocPrint(allocator, "{d}.{d}{s}", .{ whole, fraction, suffix });
    }

    const whole = @divTrunc(scaled, 10);
    const fraction = @mod(scaled, 10);
    if (fraction == 0) return std.fmt.allocPrint(allocator, "{d}{s}", .{ whole, suffix });
    return std.fmt.allocPrint(allocator, "{d}.{d}{s}", .{ whole, fraction, suffix });
}

fn roundedDiv(numerator: i128, denominator: i128) i128 {
    if (denominator <= 0) return 0;
    return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
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

test "renders token and context status line values" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);
    transcript.token_usage = .{
        .total = .{
            .input_tokens = 1234,
            .output_tokens = 5678,
            .total_tokens = 20000,
        },
        .last = .{
            .input_tokens = 1234,
            .output_tokens = 5678,
            .total_tokens = 20000,
        },
        .model_context_window = 100000,
    };

    var cfg = try config.loadWithOptions(allocator, .{ .ignore_user_config = true });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, .{ .model_context_window = 128000 });

    const preview = try buildPreview(
        allocator,
        cfg,
        &transcript,
        "/tmp/rollout-123.jsonl",
        "/tmp/codex-zig-port",
        &.{ .context_window_size, .used_tokens, .context_remaining, .context_used, .total_input_tokens, .total_output_tokens },
        false,
    );
    defer allocator.free(preview);
    try std.testing.expectEqualStrings("100K window | 20K used | Context 91% left | Context 9% used | 1.23K in | 5.68K out", preview);
}

test "renders zero token status line values from configured window" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var cfg = try config.loadWithOptions(allocator, .{ .ignore_user_config = true });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, .{ .model_context_window = 128000 });

    const preview = try buildPreview(
        allocator,
        cfg,
        &transcript,
        "/tmp/rollout-123.jsonl",
        "/tmp/codex-zig-port",
        &.{ .context_window_size, .used_tokens, .context_remaining, .context_used, .total_input_tokens, .total_output_tokens },
        false,
    );
    defer allocator.free(preview);
    try std.testing.expectEqualStrings("128K window | Context 100% left | Context 0% used | 0 in | 0 out", preview);
}

test "formats compact token values with Rust-compatible thresholds" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        value: i64,
        expected: []const u8,
    }{
        .{ .value = -1, .expected = "0" },
        .{ .value = 0, .expected = "0" },
        .{ .value = 999, .expected = "999" },
        .{ .value = 1234, .expected = "1.23K" },
        .{ .value = 12000, .expected = "12K" },
        .{ .value = 123456, .expected = "123K" },
        .{ .value = 1234567, .expected = "1.23M" },
        .{ .value = 999500, .expected = "1000K" },
    };

    for (cases) |case| {
        const formatted = try formatTokensCompact(allocator, case.value);
        defer allocator.free(formatted);
        try std.testing.expectEqualStrings(case.expected, formatted);
    }
}
