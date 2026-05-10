const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");

pub const FeatureSpec = struct {
    pub const all = features[0..];

    key: []const u8,
    stage: []const u8,
    default_enabled: bool,
};

const FeatureAlias = struct {
    alias: []const u8,
    canonical: []const u8,
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
    const canonical = resolveFeatureKey(feature) orelse return error.UnknownFeature;
    try overrides.put(allocator, canonical, enabled);
}

fn listFeatures(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);

    const config_bytes = try readConfigToml(allocator, cfg.codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var config_overrides = try parseFeatureOverridesForProfile(allocator, config_bytes orelse "", cfg.active_profile);
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

    const codex_home = try config.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const update: FeatureConfigUpdate = if (!enabled and options.profile == null and isDirectDefaultFalseFeature(feature))
        .clear
    else
        .{ .set = enabled };
    const updated = try updateFeatureConfig(allocator, config_bytes orelse "", options.profile, feature, update);
    defer allocator.free(updated);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, codex_home);
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = updated,
    });

    const verb = if (enabled) "Enabled" else "Disabled";
    const message = try std.fmt.allocPrint(allocator, "{s} feature `{s}` in config.toml.\n", .{ verb, feature });
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
    if (enabled and options.profile == null and isDirectUnderDevelopmentFeature(feature)) {
        const config_path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
        defer allocator.free(config_path);
        const warning = try std.fmt.allocPrint(
            allocator,
            "Under-development features enabled: {s}. Under-development features are incomplete and may behave unpredictably. To suppress this warning, set `suppress_unstable_features_warning = true` in {s}.\n",
            .{ feature, config_path },
        );
        defer allocator.free(warning);
        try cli_utils.writeStderr(warning);
    }
}

pub fn loadFeatureOverrides(allocator: std.mem.Allocator, codex_home: []const u8) !FeatureOverrides {
    return loadFeatureOverridesForProfile(allocator, codex_home, null);
}

pub fn loadFeatureOverridesForProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    profile: ?[]const u8,
) !FeatureOverrides {
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    return parseFeatureOverridesForProfile(allocator, config_bytes orelse "", profile);
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
    return parseFeatureOverridesForProfile(allocator, bytes, null);
}

fn parseFeatureOverridesForProfile(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    profile: ?[]const u8,
) !FeatureOverrides {
    var base_overrides = FeatureOverrides{};
    defer base_overrides.deinit(allocator);
    var profile_overrides = FeatureOverrides{};
    defer profile_overrides.deinit(allocator);

    var section: FeatureConfigSection = .none;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = featureConfigSectionForLine(line, profile);
            continue;
        }
        if (section == .none) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const enabled = if (std.mem.eql(u8, raw_value, "true"))
            true
        else if (std.mem.eql(u8, raw_value, "false"))
            false
        else
            continue;
        const canonical_key = resolveFeatureKey(key) orelse continue;
        switch (section) {
            .none => {},
            .top_level => try base_overrides.put(allocator, canonical_key, enabled),
            .profile => try profile_overrides.put(allocator, canonical_key, enabled),
        }
    }

    var overrides = try base_overrides.clone(allocator);
    errdefer overrides.deinit(allocator);
    for (profile_overrides.items.items) |item| {
        try overrides.put(allocator, item.key, item.enabled);
    }
    return overrides;
}

const FeatureConfigSection = enum {
    none,
    top_level,
    profile,
};

const FeatureConfigUpdate = union(enum) {
    set: bool,
    clear,
};

fn featureConfigSectionForLine(line: []const u8, profile: ?[]const u8) FeatureConfigSection {
    if (std.mem.eql(u8, line, "[features]")) return .top_level;
    if (profile) |name| {
        if (isProfileFeaturesSection(line, name)) return .profile;
    }
    return .none;
}

fn updateFeatureConfig(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    profile: ?[]const u8,
    feature: []const u8,
    update: FeatureConfigUpdate,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const target_section = if (profile != null) FeatureConfigSection.profile else FeatureConfigSection.top_level;
    var in_target_section = false;
    var saw_target_section = false;
    var wrote_feature = false;

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_target_section and !wrote_feature) {
                switch (update) {
                    .set => |enabled| {
                        try appendFeatureLine(allocator, &output, feature, enabled);
                        wrote_feature = true;
                    },
                    .clear => {},
                }
            }
            in_target_section = featureConfigSectionForLine(trimmed, profile) == target_section;
            saw_target_section = saw_target_section or in_target_section;
        }

        if (in_target_section and featureLineMatches(trimmed, feature)) {
            switch (update) {
                .set => |enabled| try appendFeatureLine(allocator, &output, feature, enabled),
                .clear => {},
            }
            wrote_feature = true;
            continue;
        }

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    switch (update) {
        .set => |enabled| {
            if (!saw_target_section) {
                if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
                    try output.append(allocator, '\n');
                }
                if (output.items.len > 0) try output.append(allocator, '\n');
                try appendFeatureSectionHeader(allocator, &output, profile);
            }
            if (!wrote_feature) {
                try appendFeatureLine(allocator, &output, feature, enabled);
            }
        },
        .clear => {},
    }

    return output.toOwnedSlice(allocator);
}

fn isProfileFeaturesSection(line: []const u8, profile: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "profiles.";
    const suffix = ".features";
    if (!std.mem.startsWith(u8, section, prefix) or !std.mem.endsWith(u8, section, suffix)) return false;
    const raw_name = section[prefix.len .. section.len - suffix.len];
    if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"') {
        return std.mem.eql(u8, raw_name[1 .. raw_name.len - 1], profile);
    }
    return std.mem.eql(u8, raw_name, profile);
}

fn appendFeatureSectionHeader(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    profile: ?[]const u8,
) !void {
    if (profile) |name| {
        try output.appendSlice(allocator, "[profiles.");
        try appendTomlStringLiteral(allocator, output, name);
        try output.appendSlice(allocator, ".features]\n");
    } else {
        try output.appendSlice(allocator, "[features]\n");
    }
}

fn appendTomlStringLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
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
    enabled: bool,
) !void {
    try output.appendSlice(allocator, feature);
    try output.appendSlice(allocator, " = ");
    try output.appendSlice(allocator, if (enabled) "true" else "false");
    try output.append(allocator, '\n');
}

pub fn isKnownFeature(key: []const u8) bool {
    return resolveFeatureKey(key) != null;
}

fn resolveFeatureKey(key: []const u8) ?[]const u8 {
    for (features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return feature.key;
    }
    for (feature_aliases) |alias| {
        if (std.mem.eql(u8, alias.alias, key)) return alias.canonical;
    }
    return null;
}

fn directFeatureSpec(key: []const u8) ?FeatureSpec {
    for (features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return feature;
    }
    return null;
}

fn isDirectDefaultFalseFeature(key: []const u8) bool {
    const feature = directFeatureSpec(key) orelse return false;
    return !feature.default_enabled;
}

fn isDirectUnderDevelopmentFeature(key: []const u8) bool {
    const feature = directFeatureSpec(key) orelse return false;
    return std.mem.eql(u8, feature.stage, "under development");
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
        \\Root --profile NAME writes to [profiles.NAME.features] instead.
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
        \\Root --profile NAME scopes the write to that profile.
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

const feature_aliases = [_]FeatureAlias{
    .{ .alias = "codex_hooks", .canonical = "hooks" },
    .{ .alias = "collab", .canonical = "multi_agent" },
    .{ .alias = "connectors", .canonical = "apps" },
    .{ .alias = "enable_experimental_windows_sandbox", .canonical = "experimental_windows_sandbox" },
    .{ .alias = "experimental_use_freeform_apply_patch", .canonical = "apply_patch_freeform" },
    .{ .alias = "experimental_use_unified_exec_tool", .canonical = "unified_exec" },
    .{ .alias = "include_apply_patch_tool", .canonical = "apply_patch_freeform" },
    .{ .alias = "memory_tool", .canonical = "memories" },
    .{ .alias = "request_permissions", .canonical = "exec_permission_approvals" },
    .{ .alias = "telepathy", .canonical = "chronicle" },
    .{ .alias = "web_search", .canonical = "web_search_request" },
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

test "feature overrides parse legacy aliases as canonical features" {
    const allocator = std.testing.allocator;
    var overrides = try parseFeatureOverrides(allocator,
        \\[features]
        \\collab = false
        \\memory_tool = true
        \\
    );
    defer overrides.deinit(allocator);

    try std.testing.expectEqual(false, overrides.get("multi_agent").?);
    try std.testing.expectEqual(true, overrides.get("memories").?);
    try std.testing.expect(overrides.get("collab") == null);
}

test "feature overrides apply profile scoped values over base values" {
    const allocator = std.testing.allocator;
    var overrides = try parseFeatureOverridesForProfile(allocator,
        \\[features]
        \\goals = false
        \\shell_tool = true
        \\[profiles.work.features]
        \\goals = true
        \\shell_tool = false
        \\
    , "work");
    defer overrides.deinit(allocator);

    try std.testing.expectEqual(true, overrides.get("goals").?);
    try std.testing.expectEqual(false, overrides.get("shell_tool").?);
}

test "feature overrides parse quoted profile feature sections" {
    const allocator = std.testing.allocator;
    var overrides = try parseFeatureOverridesForProfile(allocator,
        \\[features]
        \\goals = false
        \\[profiles."team a".features]
        \\goals = true
        \\
    , "team a");
    defer overrides.deinit(allocator);

    try std.testing.expectEqual(true, overrides.get("goals").?);
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
    const updated = try updateFeatureConfig(allocator, "model = \"demo\"\n", null, "goals", .{ .set = true });
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
    , null, "goals", .{ .set = true });
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
    , null, "goals", .{ .set = false });
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "shell_tool = true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "goals = false\n") != null);
}

test "feature config update creates profile feature table" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator,
        \\model = "demo"
        \\
    , "team a", "goals", .{ .set = true });
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "[profiles.\"team a\".features]\ngoals = true\n") != null);
}

test "feature config update replaces profile feature value" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator,
        \\[features]
        \\goals = false
        \\[profiles.work.features]
        \\goals = false
        \\shell_tool = true
        \\[profiles.other.features]
        \\goals = false
        \\
    , "work", "goals", .{ .set = true });
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]\ngoals = false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[profiles.work.features]\ngoals = true\nshell_tool = true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[profiles.other.features]\ngoals = false\n") != null);
}

test "feature config update clears root default false feature" {
    const allocator = std.testing.allocator;
    const updated = try updateFeatureConfig(allocator,
        \\[features]
        \\goals = true
        \\shell_tool = false
        \\[profiles.work.features]
        \\goals = true
        \\
    , null, "goals", .clear);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]\nshell_tool = false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]\ngoals =") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[profiles.work.features]\ngoals = true\n") != null);
}

test "runtime feature toggles accept legacy aliases" {
    const allocator = std.testing.allocator;
    var overrides = FeatureOverrides{};
    defer overrides.deinit(allocator);

    try putRuntimeToggle(allocator, &overrides, "collab", false);

    try std.testing.expectEqual(false, overrides.get("multi_agent").?);
    try std.testing.expect(overrides.get("collab") == null);
}
