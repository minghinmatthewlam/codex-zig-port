const std = @import("std");

pub const FeatureSpec = struct {
    pub const all = features[0..];

    key: []const u8,
    stage: []const u8,
    default_enabled: bool,
};

pub const FeatureAlias = struct {
    pub const all = feature_aliases[0..];

    alias: []const u8,
    canonical: []const u8,
};

pub fn isKnownFeature(key: []const u8) bool {
    return resolveFeatureKey(key) != null;
}

pub fn canonicalFeatureKey(key: []const u8) ?[]const u8 {
    return resolveFeatureKey(key);
}

pub fn isCanonicalFeatureKey(key: []const u8) bool {
    for (features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return true;
    }
    return false;
}

pub fn featureSpec(key: []const u8) ?FeatureSpec {
    for (features) |feature| {
        if (std.mem.eql(u8, feature.key, key)) return feature;
    }
    return null;
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
    .{ .key = "network_proxy", .stage = "experimental", .default_enabled = false },
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
