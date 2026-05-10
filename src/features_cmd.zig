const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");

const FeatureSpec = struct {
    key: []const u8,
    stage: []const u8,
    default_enabled: bool,
};

pub const FeatureOverride = struct {
    key: []const u8,
    enabled: bool,
};

pub const FeatureOverrides = struct {
    items: std.ArrayList(FeatureOverride) = .empty,

    pub fn deinit(self: *FeatureOverrides, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item.key);
        self.items.deinit(allocator);
    }

    pub fn put(self: *FeatureOverrides, allocator: std.mem.Allocator, key: []const u8, enabled: bool) !void {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.key, key)) {
                item.enabled = enabled;
                return;
            }
        }
        try self.items.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .enabled = enabled,
        });
    }

    pub fn get(self: FeatureOverrides, key: []const u8) ?bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.key, key)) return item.enabled;
        }
        return null;
    }

    pub fn clone(self: FeatureOverrides, allocator: std.mem.Allocator) !FeatureOverrides {
        var cloned = FeatureOverrides{};
        errdefer cloned.deinit(allocator);
        for (self.items.items) |item| {
            try cloned.put(allocator, item.key, item.enabled);
        }
        return cloned;
    }
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: FeatureOverrides = .{},
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingFeaturesSubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, subcommand, "list")) {
        var runtime_overrides = try options.runtime_overrides.clone(allocator);
        defer runtime_overrides.deinit(allocator);
        if (args.next()) |extra| {
            if (isHelpFlag(extra)) {
                printListHelp();
                return;
            }
            try parseRuntimeToggle(allocator, extra, args, &runtime_overrides);
            while (args.next()) |arg| {
                if (isHelpFlag(arg)) {
                    printListHelp();
                    return;
                }
                try parseRuntimeToggle(allocator, arg, args, &runtime_overrides);
            }
            try listFeatures(allocator, .{
                .profile = options.profile,
                .runtime_overrides = runtime_overrides,
            });
            return;
        }
        try listFeatures(allocator, .{
            .profile = options.profile,
            .runtime_overrides = runtime_overrides,
        });
        return;
    }
    if (std.mem.eql(u8, subcommand, "enable") or std.mem.eql(u8, subcommand, "disable")) {
        const feature = args.next() orelse return error.MissingFeatureName;
        if (isHelpFlag(feature)) {
            printSetHelp(subcommand);
            return;
        }
        if (args.next() != null) return error.UnknownFeaturesOption;
        try setFeature(allocator, options, feature, std.mem.eql(u8, subcommand, "enable"));
        return;
    }
    return error.UnknownFeaturesSubcommand;
}

fn parseRuntimeToggle(
    allocator: std.mem.Allocator,
    arg: []const u8,
    args: *std.process.Args.Iterator,
    overrides: *FeatureOverrides,
) !void {
    if (std.mem.eql(u8, arg, "--enable")) {
        try putRuntimeToggle(allocator, overrides, args.next() orelse return error.MissingFeatureName, true);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--enable=")) {
        try putRuntimeToggle(allocator, overrides, arg["--enable=".len..], true);
        return;
    }
    if (std.mem.eql(u8, arg, "--disable")) {
        try putRuntimeToggle(allocator, overrides, args.next() orelse return error.MissingFeatureName, false);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--disable=")) {
        try putRuntimeToggle(allocator, overrides, arg["--disable=".len..], false);
        return;
    }
    return error.UnknownFeaturesOption;
}

pub fn putRuntimeToggle(
    allocator: std.mem.Allocator,
    overrides: *FeatureOverrides,
    feature: []const u8,
    enabled: bool,
) !void {
    if (!isKnownFeature(feature)) return error.UnknownFeature;
    try overrides.put(allocator, feature, enabled);
}

fn listFeatures(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);

    const config_bytes = try readConfigToml(allocator, cfg.codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var config_overrides = try parseFeatureOverrides(allocator, config_bytes orelse "");
    defer config_overrides.deinit(allocator);

    var name_width: usize = 0;
    var stage_width: usize = 0;
    for (features) |feature| {
        name_width = @max(name_width, feature.key.len);
        stage_width = @max(stage_width, feature.stage.len);
    }

    const rendered = try renderFeaturesList(allocator, config_overrides, options.runtime_overrides, name_width, stage_width);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
}

fn setFeature(allocator: std.mem.Allocator, options: Options, feature: []const u8, enabled: bool) !void {
    if (!isKnownFeature(feature)) return error.UnknownFeature;

    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);

    const config_bytes = try readConfigToml(allocator, cfg.codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const updated = try updateFeatureConfig(allocator, config_bytes orelse "", feature, enabled);
    defer allocator.free(updated);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, cfg.codex_home);
    const path = try std.fs.path.join(allocator, &.{ cfg.codex_home, "config.toml" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = updated,
    });

    const verb = if (enabled) "Enabled" else "Disabled";
    const message = try std.fmt.allocPrint(allocator, "{s} feature `{s}` in config.toml.\n", .{ verb, feature });
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn readConfigToml(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn parseFeatureOverrides(allocator: std.mem.Allocator, bytes: []const u8) !FeatureOverrides {
    var overrides = FeatureOverrides{};
    errdefer overrides.deinit(allocator);

    var in_features = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_features = std.mem.eql(u8, line, "[features]");
            continue;
        }
        if (!in_features) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const enabled = if (std.mem.eql(u8, raw_value, "true"))
            true
        else if (std.mem.eql(u8, raw_value, "false"))
            false
        else
            continue;
        if (isKnownFeature(key)) try overrides.put(allocator, key, enabled);
    }

    return overrides;
}

fn updateFeatureConfig(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    feature: []const u8,
    enabled: bool,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const replacement = if (enabled) "true" else "false";
    var in_features = false;
    var saw_features = false;
    var wrote_feature = false;

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_features and !wrote_feature) {
                try appendFeatureLine(allocator, &output, feature, replacement);
                wrote_feature = true;
            }
            in_features = std.mem.eql(u8, trimmed, "[features]");
            saw_features = saw_features or in_features;
        }

        if (in_features and featureLineMatches(trimmed, feature)) {
            try appendFeatureLine(allocator, &output, feature, replacement);
            wrote_feature = true;
            continue;
        }

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    if (!saw_features) {
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }
        if (output.items.len > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, "[features]\n");
    }
    if (!wrote_feature) {
        try appendFeatureLine(allocator, &output, feature, replacement);
    }

    return output.toOwnedSlice(allocator);
}

fn featureLineMatches(trimmed: []const u8, feature: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] == '[') return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    return std.mem.eql(u8, key, feature);
}

fn appendFeatureLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    feature: []const u8,
    value: []const u8,
) !void {
    try output.appendSlice(allocator, feature);
    try output.appendSlice(allocator, " = ");
    try output.appendSlice(allocator, value);
    try output.append(allocator, '\n');
}

pub fn isKnownFeature(key: []const u8) bool {
    for (features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return true;
    }
    return false;
}

fn renderFeaturesList(
    allocator: std.mem.Allocator,
    config_overrides: FeatureOverrides,
    runtime_overrides: FeatureOverrides,
    name_width: usize,
    stage_width: usize,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (features) |feature| {
        const enabled = runtime_overrides.get(feature.key) orelse
            config_overrides.get(feature.key) orelse
            feature.default_enabled;
        try appendPadded(allocator, &output, feature.key, name_width);
        try output.appendSlice(allocator, "  ");
        try appendPadded(allocator, &output, feature.stage, stage_width);
        try output.appendSlice(allocator, if (enabled) "  true\n" else "  false\n");
    }

    return output.toOwnedSlice(allocator);
}

fn appendPadded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8, width: usize) !void {
    try output.appendSlice(allocator, value);
    var index = value.len;
    while (index < width) : (index += 1) {
        try output.append(allocator, ' ');
    }
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig features list [--enable FEATURE] [--disable FEATURE]
        \\  codex-zig features enable FEATURE
        \\  codex-zig features disable FEATURE
        \\
        \\Writes update the top-level [features] table in CODEX_HOME/config.toml.
        \\Root --enable/--disable flags apply only to the current invocation.
        \\
    , .{});
}

fn printListHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig features list [--enable FEATURE] [--disable FEATURE]
        \\
        \\Lists known feature flags with stage and effective state.
        \\Runtime --enable/--disable overrides take precedence over config.toml.
        \\
    , .{});
}

fn printSetHelp(action: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  codex-zig features {s} FEATURE
        \\
        \\Updates CODEX_HOME/config.toml for a known feature key.
        \\
    , .{action});
}

const features = [_]FeatureSpec{
    .{ .key = "apply_patch_freeform", .stage = "under development", .default_enabled = false },
    .{ .key = "apply_patch_streaming_events", .stage = "under development", .default_enabled = false },
    .{ .key = "apps", .stage = "stable", .default_enabled = true },
    .{ .key = "apps_mcp_path_override", .stage = "under development", .default_enabled = false },
    .{ .key = "artifact", .stage = "under development", .default_enabled = false },
    .{ .key = "auth_elicitation", .stage = "under development", .default_enabled = false },
    .{ .key = "browser_use", .stage = "stable", .default_enabled = true },
    .{ .key = "browser_use_external", .stage = "stable", .default_enabled = true },
    .{ .key = "builtin_mcp", .stage = "under development", .default_enabled = false },
    .{ .key = "child_agents_md", .stage = "under development", .default_enabled = false },
    .{ .key = "chronicle", .stage = "under development", .default_enabled = false },
    .{ .key = "code_mode", .stage = "under development", .default_enabled = false },
    .{ .key = "code_mode_only", .stage = "under development", .default_enabled = false },
    .{ .key = "codex_git_commit", .stage = "under development", .default_enabled = false },
    .{ .key = "collaboration_modes", .stage = "removed", .default_enabled = true },
    .{ .key = "computer_use", .stage = "stable", .default_enabled = true },
    .{ .key = "default_mode_request_user_input", .stage = "under development", .default_enabled = false },
    .{ .key = "elevated_windows_sandbox", .stage = "removed", .default_enabled = false },
    .{ .key = "enable_fanout", .stage = "under development", .default_enabled = false },
    .{ .key = "enable_mcp_apps", .stage = "under development", .default_enabled = false },
    .{ .key = "enable_request_compression", .stage = "stable", .default_enabled = true },
    .{ .key = "exec_permission_approvals", .stage = "under development", .default_enabled = false },
    .{ .key = "experimental_windows_sandbox", .stage = "removed", .default_enabled = false },
    .{ .key = "external_migration", .stage = "experimental", .default_enabled = false },
    .{ .key = "fast_mode", .stage = "stable", .default_enabled = true },
    .{ .key = "goals", .stage = "experimental", .default_enabled = false },
    .{ .key = "guardian_approval", .stage = "stable", .default_enabled = true },
    .{ .key = "hooks", .stage = "stable", .default_enabled = true },
    .{ .key = "image_detail_original", .stage = "removed", .default_enabled = false },
    .{ .key = "image_generation", .stage = "stable", .default_enabled = true },
    .{ .key = "in_app_browser", .stage = "stable", .default_enabled = true },
    .{ .key = "js_repl", .stage = "removed", .default_enabled = false },
    .{ .key = "js_repl_tools_only", .stage = "removed", .default_enabled = false },
    .{ .key = "memories", .stage = "experimental", .default_enabled = false },
    .{ .key = "multi_agent", .stage = "stable", .default_enabled = true },
    .{ .key = "multi_agent_v2", .stage = "under development", .default_enabled = false },
    .{ .key = "personality", .stage = "stable", .default_enabled = true },
    .{ .key = "plugin_hooks", .stage = "under development", .default_enabled = false },
    .{ .key = "plugins", .stage = "stable", .default_enabled = true },
    .{ .key = "prevent_idle_sleep", .stage = "experimental", .default_enabled = false },
    .{ .key = "realtime_conversation", .stage = "under development", .default_enabled = false },
    .{ .key = "remote_compaction_v2", .stage = "under development", .default_enabled = false },
    .{ .key = "remote_control", .stage = "under development", .default_enabled = false },
    .{ .key = "remote_models", .stage = "removed", .default_enabled = false },
    .{ .key = "remote_plugin", .stage = "under development", .default_enabled = false },
    .{ .key = "request_permissions_tool", .stage = "under development", .default_enabled = false },
    .{ .key = "request_rule", .stage = "removed", .default_enabled = false },
    .{ .key = "responses_websocket_response_processed", .stage = "under development", .default_enabled = false },
    .{ .key = "responses_websockets", .stage = "removed", .default_enabled = false },
    .{ .key = "responses_websockets_v2", .stage = "removed", .default_enabled = false },
    .{ .key = "runtime_metrics", .stage = "under development", .default_enabled = false },
    .{ .key = "search_tool", .stage = "removed", .default_enabled = false },
    .{ .key = "shell_snapshot", .stage = "stable", .default_enabled = true },
    .{ .key = "shell_tool", .stage = "stable", .default_enabled = true },
    .{ .key = "shell_zsh_fork", .stage = "under development", .default_enabled = false },
    .{ .key = "skill_env_var_dependency_prompt", .stage = "under development", .default_enabled = false },
    .{ .key = "skill_mcp_dependency_install", .stage = "stable", .default_enabled = true },
    .{ .key = "sqlite", .stage = "removed", .default_enabled = true },
    .{ .key = "steer", .stage = "removed", .default_enabled = true },
    .{ .key = "terminal_resize_reflow", .stage = "experimental", .default_enabled = true },
    .{ .key = "tool_call_mcp_elicitation", .stage = "stable", .default_enabled = true },
    .{ .key = "tool_search", .stage = "stable", .default_enabled = true },
    .{ .key = "tool_search_always_defer_mcp_tools", .stage = "under development", .default_enabled = false },
    .{ .key = "tool_suggest", .stage = "stable", .default_enabled = true },
    .{ .key = "tui_app_server", .stage = "removed", .default_enabled = true },
    .{ .key = "unavailable_dummy_tools", .stage = "stable", .default_enabled = true },
    .{ .key = "undo", .stage = "removed", .default_enabled = false },
    .{ .key = "unified_exec", .stage = "stable", .default_enabled = true },
    .{ .key = "use_legacy_landlock", .stage = "deprecated", .default_enabled = false },
    .{ .key = "use_linux_sandbox_bwrap", .stage = "removed", .default_enabled = false },
    .{ .key = "web_search_cached", .stage = "deprecated", .default_enabled = false },
    .{ .key = "web_search_request", .stage = "deprecated", .default_enabled = false },
    .{ .key = "workspace_dependencies", .stage = "stable", .default_enabled = true },
    .{ .key = "workspace_owner_usage_nudge", .stage = "under development", .default_enabled = false },
};

test "feature overrides parse booleans from features table" {
    const allocator = std.testing.allocator;
    var overrides = try parseFeatureOverrides(allocator,
        \\model = "ignored"
        \\[features]
        \\goals = true
        \\shell_tool = false
        \\unknown = true
        \\
    );
    defer overrides.deinit(allocator);

    try std.testing.expectEqual(true, overrides.get("goals").?);
    try std.testing.expectEqual(false, overrides.get("shell_tool").?);
    try std.testing.expect(overrides.get("unknown") == null);
}

test "features table is sorted by key" {
    var index: usize = 1;
    while (index < features.len) : (index += 1) {
        try std.testing.expect(std.mem.order(u8, features[index - 1].key, features[index].key) == .lt);
    }
}

test "feature list renderer includes config overrides" {
    const allocator = std.testing.allocator;
    var overrides = FeatureOverrides{};
    defer overrides.deinit(allocator);
    try overrides.put(allocator, "goals", true);

    const rendered = try renderFeaturesList(allocator, overrides, .{}, "goals".len, "experimental".len);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "goals  experimental  true\n") != null);
}

test "feature list renderer lets runtime overrides win" {
    const allocator = std.testing.allocator;
    var config_overrides = FeatureOverrides{};
    defer config_overrides.deinit(allocator);
    try config_overrides.put(allocator, "goals", false);
    var runtime_overrides = FeatureOverrides{};
    defer runtime_overrides.deinit(allocator);
    try runtime_overrides.put(allocator, "goals", true);

    const rendered = try renderFeaturesList(allocator, config_overrides, runtime_overrides, "goals".len, "experimental".len);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "goals  experimental  true\n") != null);
}

test "runtime feature toggles reject unknown keys" {
    const allocator = std.testing.allocator;
    var overrides = FeatureOverrides{};
    defer overrides.deinit(allocator);

    try std.testing.expectError(error.UnknownFeature, putRuntimeToggle(allocator, &overrides, "not_real", true));
}

test "feature config update creates features table" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator, "model = \"demo\"\n", "goals", true);
    defer allocator.free(updated);

    try std.testing.expectEqualStrings(
        "model = \"demo\"\n\n[features]\ngoals = true\n",
        updated,
    );
}

test "feature config update replaces existing feature" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator,
        \\model = "demo"
        \\[features]
        \\goals = false
        \\shell_tool = true
        \\[profiles.work]
        \\model = "work"
        \\
    , "goals", true);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "goals = true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "shell_tool = true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[profiles.work]\n") != null);
}

test "feature config update appends to existing features table" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator,
        \\[features]
        \\shell_tool = true
        \\
    , "goals", false);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "shell_tool = true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "goals = false\n") != null);
}
