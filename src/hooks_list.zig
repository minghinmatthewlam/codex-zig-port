const std = @import("std");

const config = @import("config.zig");
const plugin_config = @import("plugin_config.zig");

const DEFAULT_TIMEOUT_SEC: u64 = 600;

pub const Source = enum {
    user,
    project,
    plugin,

    fn label(self: Source) []const u8 {
        return switch (self) {
            .user => "user",
            .project => "project",
            .plugin => "plugin",
        };
    }
};

const TrustStatus = enum {
    untrusted,
    trusted,
    modified,

    fn label(self: TrustStatus) []const u8 {
        return switch (self) {
            .untrusted => "untrusted",
            .trusted => "trusted",
            .modified => "modified",
        };
    }
};

pub const HookEvent = enum {
    pre_tool_use,
    permission_request,
    post_tool_use,
    pre_compact,
    post_compact,
    session_start,
    user_prompt_submit,
    stop,

    fn configLabel(self: HookEvent) []const u8 {
        return switch (self) {
            .pre_tool_use => "PreToolUse",
            .permission_request => "PermissionRequest",
            .post_tool_use => "PostToolUse",
            .pre_compact => "PreCompact",
            .post_compact => "PostCompact",
            .session_start => "SessionStart",
            .user_prompt_submit => "UserPromptSubmit",
            .stop => "Stop",
        };
    }

    fn jsonLabel(self: HookEvent) []const u8 {
        return switch (self) {
            .pre_tool_use => "preToolUse",
            .permission_request => "permissionRequest",
            .post_tool_use => "postToolUse",
            .pre_compact => "preCompact",
            .post_compact => "postCompact",
            .session_start => "sessionStart",
            .user_prompt_submit => "userPromptSubmit",
            .stop => "stop",
        };
    }

    fn keyLabel(self: HookEvent) []const u8 {
        return switch (self) {
            .pre_tool_use => "pre_tool_use",
            .permission_request => "permission_request",
            .post_tool_use => "post_tool_use",
            .pre_compact => "pre_compact",
            .post_compact => "post_compact",
            .session_start => "session_start",
            .user_prompt_submit => "user_prompt_submit",
            .stop => "stop",
        };
    }

    fn index(self: HookEvent) usize {
        return switch (self) {
            .pre_tool_use => 0,
            .permission_request => 1,
            .post_tool_use => 2,
            .pre_compact => 3,
            .post_compact => 4,
            .session_start => 5,
            .user_prompt_submit => 6,
            .stop => 7,
        };
    }
};

const HOOK_EVENT_ORDER = [_]HookEvent{
    .pre_tool_use,
    .permission_request,
    .post_tool_use,
    .pre_compact,
    .post_compact,
    .session_start,
    .user_prompt_submit,
    .stop,
};

pub const Hook = struct {
    key: []const u8,
    event_name: HookEvent,
    matcher: ?[]const u8,
    command: []const u8,
    timeout_sec: u64,
    status_message: ?[]const u8,
    source_path: []const u8,
    source: Source,
    plugin_id: ?[]const u8 = null,
    display_order: i64,
    enabled: bool,
    current_hash: []const u8,
    trust_status: TrustStatus,

    fn deinit(self: Hook, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.matcher) |value| allocator.free(value);
        allocator.free(self.command);
        if (self.status_message) |value| allocator.free(value);
        allocator.free(self.source_path);
        if (self.plugin_id) |value| allocator.free(value);
        allocator.free(self.current_hash);
    }
};

const HookState = struct {
    key: []const u8,
    enabled: ?bool = null,
    trusted_hash: ?[]const u8 = null,

    fn deinit(self: HookState, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.trusted_hash) |value| allocator.free(value);
    }
};

const HookStates = struct {
    entries: []HookState = &.{},

    fn deinit(self: HookStates, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }

    fn find(self: HookStates, key: []const u8) ?HookState {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }
};

pub const HookError = struct {
    path: []const u8,
    message: []const u8,

    fn deinit(self: HookError, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
    }
};

pub const Entry = struct {
    cwd: []const u8,
    hooks: []Hook,
    warnings: []const []const u8,
    errors: []HookError,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        for (self.hooks) |hook| hook.deinit(allocator);
        allocator.free(self.hooks);
        for (self.warnings) |warning| allocator.free(warning);
        allocator.free(self.warnings);
        for (self.errors) |err| err.deinit(allocator);
        allocator.free(self.errors);
    }
};

pub const Result = struct {
    entries: []Entry,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const StartupWarnings = struct {
    items: []const []const u8,

    pub fn deinit(self: StartupWarnings, allocator: std.mem.Allocator) void {
        for (self.items) |warning| allocator.free(warning);
        allocator.free(self.items);
    }
};

const PartialGroup = struct {
    event_name: HookEvent,
    matcher: ?[]const u8 = null,
    group_index: usize,
    next_handler_index: usize = 0,

    fn deinit(self: *PartialGroup, allocator: std.mem.Allocator) void {
        if (self.matcher) |value| allocator.free(value);
        self.matcher = null;
    }
};

const PartialHook = struct {
    handler_type: ?[]const u8 = null,
    command: ?[]const u8 = null,
    timeout_sec: ?u64 = null,
    status_message: ?[]const u8 = null,
    async_handler: bool = false,

    fn deinit(self: *PartialHook, allocator: std.mem.Allocator) void {
        if (self.handler_type) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.status_message) |value| allocator.free(value);
        self.* = .{};
    }
};

pub fn list(allocator: std.mem.Allocator, codex_home: []const u8, cwd_inputs: []const []const u8) !Result {
    const resolved_cwds = if (cwd_inputs.len == 0)
        try defaultCwdList(allocator)
    else
        try cloneStrings(allocator, cwd_inputs);
    defer freeStringList(allocator, resolved_cwds);

    var entries = try std.ArrayList(Entry).initCapacity(allocator, resolved_cwds.len);
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    for (resolved_cwds) |cwd| {
        const entry = try listForCwd(allocator, codex_home, cwd);
        try entries.append(allocator, entry);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn startupWarnings(allocator: std.mem.Allocator, codex_home: []const u8) !StartupWarnings {
    var hooks = std.ArrayList(Hook).empty;
    defer {
        for (hooks.items) |hook| hook.deinit(allocator);
        hooks.deinit(allocator);
    }
    var warnings = std.ArrayList([]const u8).empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }
    var errors = std.ArrayList(HookError).empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }
    var display_order: i64 = 0;

    const user_config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(user_config_path);
    const hook_states = try loadHookStatesFromConfigFile(allocator, user_config_path);
    defer hook_states.deinit(allocator);
    const user_hooks_json_path = try std.fs.path.join(allocator, &.{ codex_home, "hooks.json" });
    defer allocator.free(user_hooks_json_path);

    try appendHooksFromLayer(allocator, user_config_path, user_hooks_json_path, .user, hook_states, &hooks, &warnings, &errors, &display_order);
    try appendPluginHooks(allocator, codex_home, user_config_path, hook_states, &hooks, &warnings, &display_order);

    return .{ .items = try warnings.toOwnedSlice(allocator) };
}

fn listForCwd(allocator: std.mem.Allocator, codex_home: []const u8, cwd: []const u8) !Entry {
    var hooks = std.ArrayList(Hook).empty;
    errdefer {
        for (hooks.items) |hook| hook.deinit(allocator);
        hooks.deinit(allocator);
    }
    var warnings = std.ArrayList([]const u8).empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }
    var errors = std.ArrayList(HookError).empty;
    errdefer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }
    var display_order: i64 = 0;

    const user_config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(user_config_path);
    const hook_states = try loadHookStatesFromConfigFile(allocator, user_config_path);
    defer hook_states.deinit(allocator);
    const user_hooks_json_path = try std.fs.path.join(allocator, &.{ codex_home, "hooks.json" });
    defer allocator.free(user_hooks_json_path);
    try appendHooksFromLayer(allocator, user_config_path, user_hooks_json_path, .user, hook_states, &hooks, &warnings, &errors, &display_order);

    const project_config_path = try std.fs.path.join(allocator, &.{ cwd, ".codex", "config.toml" });
    defer allocator.free(project_config_path);
    const project_hooks_json_path = try std.fs.path.join(allocator, &.{ cwd, ".codex", "hooks.json" });
    defer allocator.free(project_hooks_json_path);
    try appendHooksFromLayer(allocator, project_config_path, project_hooks_json_path, .project, hook_states, &hooks, &warnings, &errors, &display_order);

    try appendPluginHooks(allocator, codex_home, user_config_path, hook_states, &hooks, &warnings, &display_order);

    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);
    const owned_hooks = try hooks.toOwnedSlice(allocator);
    errdefer {
        for (owned_hooks) |hook| hook.deinit(allocator);
        allocator.free(owned_hooks);
    }
    const owned_warnings = try warnings.toOwnedSlice(allocator);
    errdefer {
        for (owned_warnings) |warning| allocator.free(warning);
        allocator.free(owned_warnings);
    }
    const owned_errors = try errors.toOwnedSlice(allocator);
    errdefer {
        for (owned_errors) |err| err.deinit(allocator);
        allocator.free(owned_errors);
    }

    return .{
        .cwd = owned_cwd,
        .hooks = owned_hooks,
        .warnings = owned_warnings,
        .errors = owned_errors,
    };
}

fn appendHooksFromLayer(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    hooks_json_path: []const u8,
    source: Source,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    errors: *std.ArrayList(HookError),
    display_order: *i64,
) !void {
    if (!try hooksFeatureEnabledFromConfigFile(allocator, config_path, errors)) return;
    const has_json_hooks = try appendHooksFromJsonFile(allocator, hooks_json_path, source, null, null, hook_states, hooks, warnings, display_order);
    const has_toml_hooks = try appendHooksFromConfig(allocator, config_path, source, hook_states, hooks, warnings, errors, display_order);
    if (has_json_hooks and has_toml_hooks) {
        const json_source_path = try canonicalPathOrCopy(allocator, hooks_json_path);
        defer allocator.free(json_source_path);
        const toml_source_path = try canonicalPathOrCopy(allocator, config_path);
        defer allocator.free(toml_source_path);
        const warning = try std.fmt.allocPrint(allocator, "loading hooks from both {s} and {s}; prefer a single representation for this layer", .{ json_source_path, toml_source_path });
        try warnings.append(allocator, warning);
    }
}

fn appendPluginHooks(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    user_config_path: []const u8,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !void {
    const bytes = config.readConfigTomlFile(allocator, user_config_path) catch return;
    defer if (bytes) |value| allocator.free(value);
    const contents = bytes orelse return;
    if (!hooksFeatureEnabled(contents) or !plugin_config.pluginsFeatureEnabled(contents) or !plugin_config.pluginHooksFeatureEnabled(contents)) return;

    const plugin_ids = try plugin_config.enabledPluginIds(allocator, contents);
    defer plugin_config.freeStringList(allocator, plugin_ids);
    for (plugin_ids) |plugin_id| {
        const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse continue;
        defer allocator.free(plugin_root);
        const hooks_json_path = try std.fs.path.join(allocator, &.{ plugin_root, "hooks", "hooks.json" });
        defer allocator.free(hooks_json_path);
        const key_source = try std.fmt.allocPrint(allocator, "{s}:hooks/hooks.json", .{plugin_id});
        defer allocator.free(key_source);
        _ = try appendHooksFromJsonFile(
            allocator,
            hooks_json_path,
            .plugin,
            plugin_id,
            key_source,
            hook_states,
            hooks,
            warnings,
            display_order,
        );
    }
}

fn hooksFeatureEnabledFromConfigFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    errors: *std.ArrayList(HookError),
) !bool {
    const bytes = config.readConfigTomlFile(allocator, path) catch |err| {
        try appendError(allocator, errors, path, @errorName(err));
        return false;
    };
    defer if (bytes) |value| allocator.free(value);
    const contents = bytes orelse return true;
    return hooksFeatureEnabled(contents);
}

fn appendHooksFromConfig(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: Source,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    errors: *std.ArrayList(HookError),
    display_order: *i64,
) !bool {
    const bytes = config.readConfigTomlFile(allocator, path) catch |err| {
        try appendError(allocator, errors, path, @errorName(err));
        return false;
    };
    defer if (bytes) |value| allocator.free(value);
    const contents = bytes orelse return false;
    if (!hooksFeatureEnabled(contents)) return false;
    const has_hooks = configContainsHooks(contents);

    const source_path = try canonicalPathOrCopy(allocator, path);
    defer allocator.free(source_path);
    try parseConfigHooks(allocator, contents, source_path, source, hook_states, hooks, warnings, display_order);
    return has_hooks;
}

fn appendHooksFromJsonFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: Source,
    plugin_id: ?[]const u8,
    key_source_override: ?[]const u8,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            const warning = try std.fmt.allocPrint(allocator, "failed to read hooks config {s}: {s}", .{ path, @errorName(err) });
            try warnings.append(allocator, warning);
            return false;
        },
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: {s}", .{ path, @errorName(err) });
        try warnings.append(allocator, warning);
        return false;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: expected object", .{path});
        try warnings.append(allocator, warning);
        return false;
    }
    const events_value = parsed.value.object.get("hooks") orelse return false;
    if (events_value != .object) {
        const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: expected hooks object", .{path});
        try warnings.append(allocator, warning);
        return false;
    }
    const has_hooks = jsonEventsContainHooks(events_value.object);

    const source_path = try canonicalPathOrCopy(allocator, path);
    defer allocator.free(source_path);
    try appendJsonHookEvents(allocator, events_value.object, source_path, key_source_override orelse source_path, source, plugin_id, hook_states, hooks, warnings, display_order);
    return has_hooks;
}

fn appendJsonHookEvents(
    allocator: std.mem.Allocator,
    events: std.json.ObjectMap,
    source_path: []const u8,
    key_source: []const u8,
    source: Source,
    plugin_id: ?[]const u8,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !void {
    for (HOOK_EVENT_ORDER) |event_name| {
        const groups_value = events.get(event_name.configLabel()) orelse continue;
        if (groups_value != .array) {
            const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: {s} must be an array", .{ source_path, event_name.configLabel() });
            try warnings.append(allocator, warning);
            continue;
        }

        for (groups_value.array.items, 0..) |group_value, group_index| {
            if (group_value != .object) {
                const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: {s} group must be an object", .{ source_path, event_name.configLabel() });
                try warnings.append(allocator, warning);
                continue;
            }
            const matcher = jsonStringField(group_value.object, "matcher");
            const handlers_value = group_value.object.get("hooks") orelse continue;
            if (handlers_value != .array) {
                const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: {s} hooks must be an array", .{ source_path, event_name.configLabel() });
                try warnings.append(allocator, warning);
                continue;
            }
            for (handlers_value.array.items, 0..) |handler_value, handler_index| {
                if (handler_value != .object) {
                    const warning = try std.fmt.allocPrint(allocator, "failed to parse hooks config {s}: hook handler must be an object", .{source_path});
                    try warnings.append(allocator, warning);
                    continue;
                }
                const handler_type = jsonStringField(handler_value.object, "type") orelse continue;
                if (!std.mem.eql(u8, handler_type, "command")) {
                    const warning = try std.fmt.allocPrint(allocator, "skipping {s} hook in {s}: {s} hooks are not supported yet", .{ handler_type, source_path, handler_type });
                    try warnings.append(allocator, warning);
                    continue;
                }
                if (jsonBoolField(handler_value.object, "async") orelse false) {
                    const warning = try std.fmt.allocPrint(allocator, "skipping async hook in {s}: async hooks are not supported yet", .{source_path});
                    try warnings.append(allocator, warning);
                    continue;
                }
                const command = jsonStringField(handler_value.object, "command") orelse continue;
                try appendCommandHook(
                    allocator,
                    source_path,
                    key_source,
                    source,
                    plugin_id,
                    hook_states,
                    event_name,
                    matcher,
                    group_index,
                    handler_index,
                    command,
                    jsonUnsignedField(handler_value.object, "timeout"),
                    jsonStringField(handler_value.object, "statusMessage"),
                    hooks,
                    warnings,
                    display_order,
                );
            }
        }
    }
}

fn parseConfigHooks(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    source_path: []const u8,
    source: Source,
    hook_states: HookStates,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !void {
    var event_group_counts = [_]usize{0} ** 8;
    var current_group: ?PartialGroup = null;
    defer if (current_group) |*group| group.deinit(allocator);
    var current_hook: ?PartialHook = null;
    defer if (current_hook) |*hook| hook.deinit(allocator);
    var section: enum { none, group, hook } = .none;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (parseHookHeader(line)) |header| {
            try flushPartialHook(allocator, source_path, source, hook_states, &current_group, &current_hook, hooks, warnings, display_order);
            if (header.kind == .group) {
                if (current_group) |*group| group.deinit(allocator);
                current_group = startGroup(header.event_name, &event_group_counts);
                section = .group;
            } else {
                if (current_group == null or current_group.?.event_name != header.event_name) {
                    if (current_group) |*group| group.deinit(allocator);
                    current_group = startGroup(header.event_name, &event_group_counts);
                }
                current_hook = .{};
                section = .hook;
            }
            continue;
        }

        if (isTomlHeader(line)) {
            try flushPartialHook(allocator, source_path, source, hook_states, &current_group, &current_hook, hooks, warnings, display_order);
            if (current_group) |*group| group.deinit(allocator);
            current_group = null;
            section = .none;
            continue;
        }

        switch (section) {
            .group => if (current_group) |*group| {
                if (try tomlStringValueForKey(allocator, line, "matcher")) |matcher| {
                    if (group.matcher) |previous| allocator.free(previous);
                    group.matcher = matcher;
                }
            },
            .hook => if (current_hook) |*hook| {
                try updatePartialHookFromLine(allocator, hook, line);
            },
            .none => {},
        }
    }

    try flushPartialHook(allocator, source_path, source, hook_states, &current_group, &current_hook, hooks, warnings, display_order);
}

const HookHeader = struct {
    kind: enum { group, hook },
    event_name: HookEvent,
};

fn parseHookHeader(line: []const u8) ?HookHeader {
    if (line.len < 4 or !std.mem.startsWith(u8, line, "[[") or !std.mem.endsWith(u8, line, "]]")) return null;
    const inner = std.mem.trim(u8, line[2 .. line.len - 2], " \t\r");
    if (!std.mem.startsWith(u8, inner, "hooks.")) return null;
    const rest = inner["hooks.".len..];
    if (std.mem.endsWith(u8, rest, ".hooks")) {
        const event_name = eventFromConfigLabel(rest[0 .. rest.len - ".hooks".len]) orelse return null;
        return .{ .kind = .hook, .event_name = event_name };
    }
    const event_name = eventFromConfigLabel(rest) orelse return null;
    return .{ .kind = .group, .event_name = event_name };
}

fn eventFromConfigLabel(label: []const u8) ?HookEvent {
    inline for (std.meta.fields(HookEvent)) |field| {
        const event: HookEvent = @enumFromInt(field.value);
        if (std.mem.eql(u8, label, event.configLabel())) return event;
    }
    return null;
}

fn startGroup(event_name: HookEvent, event_group_counts: *[8]usize) PartialGroup {
    const index = event_name.index();
    const group_index = event_group_counts[index];
    event_group_counts[index] += 1;
    return .{ .event_name = event_name, .group_index = group_index };
}

fn updatePartialHookFromLine(allocator: std.mem.Allocator, hook: *PartialHook, line: []const u8) !void {
    if (try tomlStringValueForKey(allocator, line, "type")) |value| {
        replaceOptionalString(allocator, &hook.handler_type, value);
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "command")) |value| {
        replaceOptionalString(allocator, &hook.command, value);
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "statusMessage")) |value| {
        replaceOptionalString(allocator, &hook.status_message, value);
        return;
    }
    if (tomlUnsignedValueForKey(line, "timeout")) |value| {
        hook.timeout_sec = value;
        return;
    }
    if (tomlUnsignedValueForKey(line, "timeoutSec")) |value| {
        hook.timeout_sec = value;
        return;
    }
    if (tomlBoolValueForKey(line, "async")) |value| {
        hook.async_handler = value;
    }
}

fn flushPartialHook(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: Source,
    hook_states: HookStates,
    current_group: *?PartialGroup,
    current_hook: *?PartialHook,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !void {
    if (current_hook.* == null) return;
    var hook = current_hook.*.?;
    current_hook.* = null;
    defer hook.deinit(allocator);

    const group = current_group.* orelse return;
    const handler_index = current_group.*.?.next_handler_index;
    current_group.*.?.next_handler_index += 1;

    const handler_type = hook.handler_type orelse "command";
    if (!std.mem.eql(u8, handler_type, "command")) {
        const warning = try std.fmt.allocPrint(allocator, "skipping {s} hook in {s}: only command hooks are supported", .{ handler_type, source_path });
        try warnings.append(allocator, warning);
        return;
    }
    if (hook.async_handler) {
        const warning = try std.fmt.allocPrint(allocator, "skipping async hook in {s}: async hooks are not supported yet", .{source_path});
        try warnings.append(allocator, warning);
        return;
    }
    const command = hook.command orelse return;
    try appendCommandHook(
        allocator,
        source_path,
        source_path,
        source,
        null,
        hook_states,
        group.event_name,
        group.matcher,
        group.group_index,
        handler_index,
        command,
        hook.timeout_sec,
        hook.status_message,
        hooks,
        warnings,
        display_order,
    );
}

fn appendCommandHook(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    key_source: []const u8,
    source: Source,
    plugin_id: ?[]const u8,
    hook_states: HookStates,
    event_name: HookEvent,
    matcher: ?[]const u8,
    group_index: usize,
    handler_index: usize,
    command: []const u8,
    timeout_sec_opt: ?u64,
    status_message: ?[]const u8,
    hooks: *std.ArrayList(Hook),
    warnings: *std.ArrayList([]const u8),
    display_order: *i64,
) !void {
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
        const warning = try std.fmt.allocPrint(allocator, "skipping empty hook command in {s}", .{source_path});
        try warnings.append(allocator, warning);
        return;
    }

    const timeout_sec = @max(timeout_sec_opt orelse DEFAULT_TIMEOUT_SEC, 1);
    const key = try std.fmt.allocPrint(
        allocator,
        "{s}:{s}:{d}:{d}",
        .{ key_source, event_name.keyLabel(), group_index, handler_index },
    );
    errdefer allocator.free(key);
    const current_hash = try commandHookHash(allocator, event_name, matcher, command, timeout_sec, status_message);
    errdefer allocator.free(current_hash);
    const hook_state = hook_states.find(key);
    const enabled = if (hook_state) |state| state.enabled orelse true else true;
    const trust_status = hookTrustStatus(current_hash, if (hook_state) |state| state.trusted_hash else null);
    const owned_matcher = if (matcher) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_matcher) |value| allocator.free(value);
    const owned_command = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_command);
    const owned_status_message = if (status_message) |status| try allocator.dupe(u8, status) else null;
    errdefer if (owned_status_message) |status| allocator.free(status);
    const owned_source_path = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source_path);
    const owned_plugin_id = if (plugin_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_plugin_id) |value| allocator.free(value);

    const owned = Hook{
        .key = key,
        .event_name = event_name,
        .matcher = owned_matcher,
        .command = owned_command,
        .timeout_sec = timeout_sec,
        .status_message = owned_status_message,
        .source_path = owned_source_path,
        .source = source,
        .plugin_id = owned_plugin_id,
        .display_order = display_order.*,
        .enabled = enabled,
        .current_hash = current_hash,
        .trust_status = trust_status,
    };
    errdefer owned.deinit(allocator);
    try hooks.append(allocator, owned);
    display_order.* += 1;
}

fn commandHookHash(
    allocator: std.mem.Allocator,
    event_name: HookEvent,
    matcher: ?[]const u8,
    command: []const u8,
    timeout_sec: u64,
    status_message: ?[]const u8,
) ![]const u8 {
    var canonical = std.ArrayList(u8).empty;
    defer canonical.deinit(allocator);
    try canonical.appendSlice(allocator, "{\"event_name\":");
    try appendJsonString(allocator, &canonical, event_name.keyLabel());
    try canonical.appendSlice(allocator, ",\"hooks\":[{\"async\":false,\"command\":");
    try appendJsonString(allocator, &canonical, command);
    try canonical.appendSlice(allocator, ",\"statusMessage\":");
    try appendJsonStringOrNull(allocator, &canonical, status_message);
    try canonical.appendSlice(allocator, ",\"timeout\":");
    try appendDecimal(allocator, &canonical, timeout_sec);
    try canonical.appendSlice(allocator, ",\"type\":\"command\"}],\"matcher\":");
    try appendJsonStringOrNull(allocator, &canonical, matcher);
    try canonical.append(allocator, '}');
    return sha256VersionAlloc(allocator, canonical.items);
}

fn hookTrustStatus(current_hash: []const u8, trusted_hash: ?[]const u8) TrustStatus {
    const trusted = trusted_hash orelse return .untrusted;
    if (std.mem.eql(u8, trusted, current_hash)) return .trusted;
    return .modified;
}

fn loadHookStatesFromConfigFile(allocator: std.mem.Allocator, path: []const u8) !HookStates {
    const bytes = config.readConfigTomlFile(allocator, path) catch return .{};
    defer if (bytes) |value| allocator.free(value);
    return try parseHookStates(allocator, bytes orelse "");
}

fn parseHookStates(allocator: std.mem.Allocator, bytes: []const u8) !HookStates {
    var states = std.ArrayList(HookState).empty;
    errdefer {
        for (states.items) |state| state.deinit(allocator);
        states.deinit(allocator);
    }

    var section: enum { none, hooks, hook_state } = .none;
    var table_state: ?HookState = null;
    errdefer if (table_state) |state| state.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            try flushHookState(allocator, &states, &table_state);
            if (std.mem.eql(u8, line, "[hooks]")) {
                section = .hooks;
                continue;
            }
            if (try parseHookStateTableHeader(allocator, line)) |key| {
                table_state = .{ .key = key };
                section = .hook_state;
                continue;
            }
            section = .none;
            continue;
        }
        switch (section) {
            .hooks => if (tomlRawValueForKey(line, "state")) |raw_state| {
                try appendInlineHookStates(allocator, &states, raw_state);
            },
            .hook_state => if (table_state) |*state| {
                try updateHookStateFromLine(allocator, state, line);
            },
            .none => {},
        }
    }
    try flushHookState(allocator, &states, &table_state);

    return .{ .entries = try states.toOwnedSlice(allocator) };
}

fn parseHookStateTableHeader(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    const prefix = "hooks.state.";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    var index: usize = prefix.len;
    const key = (try parseTomlStringAt(allocator, inner, &index)) orelse return null;
    errdefer allocator.free(key);
    skipTomlWhitespace(inner, &index);
    if (index != inner.len) {
        allocator.free(key);
        return null;
    }
    return key;
}

fn updateHookStateFromLine(allocator: std.mem.Allocator, state: *HookState, line: []const u8) !void {
    if (tomlBoolValueForKey(line, "enabled")) |enabled| {
        state.enabled = enabled;
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "trusted_hash")) |trusted_hash| {
        if (state.trusted_hash) |previous| allocator.free(previous);
        state.trusted_hash = trusted_hash;
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "trustedHash")) |trusted_hash| {
        if (state.trusted_hash) |previous| allocator.free(previous);
        state.trusted_hash = trusted_hash;
    }
}

fn flushHookState(allocator: std.mem.Allocator, states: *std.ArrayList(HookState), state: *?HookState) !void {
    var owned = state.* orelse return;
    state.* = null;
    errdefer owned.deinit(allocator);
    if (owned.enabled == null and owned.trusted_hash == null) {
        owned.deinit(allocator);
        return;
    }
    try states.append(allocator, owned);
}

fn appendInlineHookStates(allocator: std.mem.Allocator, states: *std.ArrayList(HookState), raw: []const u8) !void {
    var index: usize = 0;
    skipTomlWhitespace(raw, &index);
    if (index >= raw.len or raw[index] != '{') return;
    index += 1;

    while (index < raw.len) {
        skipTomlWhitespaceAndCommas(raw, &index);
        if (index >= raw.len or raw[index] == '}') return;

        const key = (try parseTomlStringAt(allocator, raw, &index)) orelse return;
        errdefer allocator.free(key);
        skipTomlWhitespace(raw, &index);
        if (index >= raw.len or raw[index] != '=') {
            allocator.free(key);
            return;
        }
        index += 1;

        var state = try parseInlineHookStateValue(allocator, raw, &index);
        errdefer state.deinit(allocator);
        if (state.enabled == null and state.trusted_hash == null) {
            state.deinit(allocator);
            allocator.free(key);
            continue;
        }
        state.key = key;
        try states.append(allocator, state);
    }
}

fn parseInlineHookStateValue(allocator: std.mem.Allocator, raw: []const u8, index: *usize) !HookState {
    var state = HookState{ .key = &.{} };
    errdefer state.deinit(allocator);
    skipTomlWhitespace(raw, index);
    if (index.* >= raw.len or raw[index.*] != '{') return state;
    index.* += 1;

    while (index.* < raw.len) {
        skipTomlWhitespaceAndCommas(raw, index);
        if (index.* >= raw.len) return state;
        if (raw[index.*] == '}') {
            index.* += 1;
            return state;
        }

        const field = (try parseTomlStringAt(allocator, raw, index)) orelse return state;
        defer allocator.free(field);
        skipTomlWhitespace(raw, index);
        if (index.* >= raw.len or raw[index.*] != '=') return state;
        index.* += 1;
        skipTomlWhitespace(raw, index);

        if (std.mem.eql(u8, field, "enabled")) {
            if (parseTomlBoolAt(raw, index)) |enabled| state.enabled = enabled else skipTomlInlineValue(raw, index);
        } else if (std.mem.eql(u8, field, "trusted_hash") or std.mem.eql(u8, field, "trustedHash")) {
            const trusted_hash = (try parseTomlStringAt(allocator, raw, index)) orelse {
                skipTomlInlineValue(raw, index);
                continue;
            };
            if (state.trusted_hash) |previous| allocator.free(previous);
            state.trusted_hash = trusted_hash;
        } else {
            skipTomlInlineValue(raw, index);
        }
    }

    return state;
}

pub fn renderResponse(allocator: std.mem.Allocator, result: Result) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");
    for (result.entries, 0..) |entry, entry_index| {
        if (entry_index > 0) try out.append(allocator, ',');
        try appendEntryJson(allocator, &out, entry);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendEntryJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry) !void {
    try out.appendSlice(allocator, "{\"cwd\":");
    try appendJsonString(allocator, out, entry.cwd);
    try out.appendSlice(allocator, ",\"hooks\":[");
    for (entry.hooks, 0..) |hook, hook_index| {
        if (hook_index > 0) try out.append(allocator, ',');
        try appendHookJson(allocator, out, hook);
    }
    try out.appendSlice(allocator, "],\"warnings\":[");
    for (entry.warnings, 0..) |warning, warning_index| {
        if (warning_index > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, warning);
    }
    try out.appendSlice(allocator, "],\"errors\":[");
    for (entry.errors, 0..) |err, error_index| {
        if (error_index > 0) try out.append(allocator, ',');
        try appendErrorJson(allocator, out, err);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendHookJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), hook: Hook) !void {
    try out.appendSlice(allocator, "{\"key\":");
    try appendJsonString(allocator, out, hook.key);
    try out.appendSlice(allocator, ",\"eventName\":");
    try appendJsonString(allocator, out, hook.event_name.jsonLabel());
    try out.appendSlice(allocator, ",\"handlerType\":\"command\",\"matcher\":");
    try appendJsonStringOrNull(allocator, out, hook.matcher);
    try out.appendSlice(allocator, ",\"command\":");
    try appendJsonString(allocator, out, hook.command);
    try out.appendSlice(allocator, ",\"timeoutSec\":");
    try appendDecimal(allocator, out, hook.timeout_sec);
    try out.appendSlice(allocator, ",\"statusMessage\":");
    try appendJsonStringOrNull(allocator, out, hook.status_message);
    try out.appendSlice(allocator, ",\"sourcePath\":");
    try appendJsonString(allocator, out, hook.source_path);
    try out.appendSlice(allocator, ",\"source\":");
    try appendJsonString(allocator, out, hook.source.label());
    try out.appendSlice(allocator, ",\"pluginId\":");
    try appendJsonStringOrNull(allocator, out, hook.plugin_id);
    try out.appendSlice(allocator, ",\"displayOrder\":");
    try appendDecimal(allocator, out, hook.display_order);
    try out.appendSlice(allocator, ",\"enabled\":");
    try out.appendSlice(allocator, if (hook.enabled) "true" else "false");
    try out.appendSlice(allocator, ",\"isManaged\":false,\"currentHash\":");
    try appendJsonString(allocator, out, hook.current_hash);
    try out.appendSlice(allocator, ",\"trustStatus\":");
    try appendJsonString(allocator, out, hook.trust_status.label());
    try out.append(allocator, '}');
}

fn appendErrorJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), err: HookError) !void {
    try out.appendSlice(allocator, "{\"path\":");
    try appendJsonString(allocator, out, err.path);
    try out.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, out, err.message);
    try out.append(allocator, '}');
}

fn hooksFeatureEnabled(bytes: []const u8) bool {
    return plugin_config.featureEnabled(bytes, "hooks", true);
}

fn configContainsHooks(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (parseHookHeader(line) != null) return true;
    }
    return false;
}

fn jsonEventsContainHooks(events: std.json.ObjectMap) bool {
    for (HOOK_EVENT_ORDER) |event_name| {
        const groups_value = events.get(event_name.configLabel()) orelse continue;
        if (groups_value == .array and groups_value.array.items.len > 0) return true;
    }
    return false;
}

fn isTomlHeader(line: []const u8) bool {
    return line.len > 0 and line[0] == '[';
}

fn tomlStringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const rhs = tomlRawValueForKey(line, key) orelse return null;
    return parseTomlStringLiteral(allocator, rhs);
}

fn tomlRawValueForKey(line: []const u8, key: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    return std.mem.trim(u8, line[eq + 1 ..], " \t");
}

fn tomlBoolValueForKey(line: []const u8, key: []const u8) ?bool {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const raw_rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const rhs = if (std.mem.indexOfScalar(u8, raw_rhs, '#')) |index|
        std.mem.trim(u8, raw_rhs[0..index], " \t")
    else
        raw_rhs;
    if (std.mem.eql(u8, rhs, "true")) return true;
    if (std.mem.eql(u8, rhs, "false")) return false;
    return null;
}

fn tomlUnsignedValueForKey(line: []const u8, key: []const u8) ?u64 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const raw_rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const rhs = if (std.mem.indexOfScalar(u8, raw_rhs, '#')) |index|
        std.mem.trim(u8, raw_rhs[0..index], " \t")
    else
        raw_rhs;
    return std.fmt.parseUnsigned(u64, rhs, 10) catch null;
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBoolField(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonUnsignedField(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch null,
        else => null,
    };
}

fn parseTomlStringLiteral(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var index: usize = 0;
    return parseTomlStringAt(allocator, raw, &index);
}

fn parseTomlStringAt(allocator: std.mem.Allocator, raw: []const u8, index: *usize) !?[]const u8 {
    skipTomlWhitespace(raw, index);
    if (index.* >= raw.len or raw[index.*] != '"') return null;
    index.* += 1;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    while (index.* < raw.len) : (index.* += 1) {
        const byte = raw[index.*];
        if (byte == '"') {
            index.* += 1;
            return try output.toOwnedSlice(allocator);
        }
        if (byte != '\\') {
            try output.append(allocator, byte);
            continue;
        }

        index.* += 1;
        if (index.* >= raw.len) return error.InvalidTomlString;
        const escaped: u8 = switch (raw[index.*]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidTomlString,
        };
        try output.append(allocator, escaped);
    }

    return error.InvalidTomlString;
}

fn parseTomlBoolAt(raw: []const u8, index: *usize) ?bool {
    skipTomlWhitespace(raw, index);
    if (std.mem.startsWith(u8, raw[index.*..], "true")) {
        index.* += "true".len;
        return true;
    }
    if (std.mem.startsWith(u8, raw[index.*..], "false")) {
        index.* += "false".len;
        return false;
    }
    return null;
}

fn skipTomlInlineValue(raw: []const u8, index: *usize) void {
    var depth: usize = 0;
    var in_string = false;
    while (index.* < raw.len) : (index.* += 1) {
        const byte = raw[index.*];
        if (in_string) {
            if (byte == '\\' and index.* + 1 < raw.len) {
                index.* += 1;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return;
                depth -= 1;
            },
            ',' => if (depth == 0) return,
            else => {},
        }
    }
}

fn skipTomlWhitespace(raw: []const u8, index: *usize) void {
    while (index.* < raw.len and (raw[index.*] == ' ' or raw[index.*] == '\t' or raw[index.*] == '\r' or raw[index.*] == '\n')) : (index.* += 1) {}
}

fn skipTomlWhitespaceAndCommas(raw: []const u8, index: *usize) void {
    while (index.* < raw.len and (raw[index.*] == ' ' or raw[index.*] == '\t' or raw[index.*] == '\r' or raw[index.*] == '\n' or raw[index.*] == ',')) : (index.* += 1) {}
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn appendJsonStringOrNull(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |present| {
        try appendJsonString(allocator, out, present);
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendDecimal(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn sha256VersionAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const prefix = "sha256:";
    var out = try allocator.alloc(u8, prefix.len + digest.len * 2);
    @memcpy(out[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[prefix.len + index * 2] = hex[byte >> 4];
        out[prefix.len + index * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

fn appendError(allocator: std.mem.Allocator, errors: *std.ArrayList(HookError), path: []const u8, message: []const u8) !void {
    const err = HookError{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    };
    errdefer err.deinit(allocator);
    try errors.append(allocator, err);
}

fn canonicalPathOrCopy(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator) catch return allocator.dupe(u8, path);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn defaultCwdList(allocator: std.mem.Allocator) ![]const []const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    errdefer allocator.free(cwd);
    const cwds = try allocator.alloc([]const u8, 1);
    cwds[0] = cwd;
    return cwds;
}

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const copied = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(copied);
    var initialized: usize = 0;
    errdefer {
        for (copied[0..initialized]) |value| allocator.free(value);
    }
    for (values, 0..) |value, index| {
        copied[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return copied;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, value: []const u8) void {
    if (slot.*) |previous| allocator.free(previous);
    slot.* = value;
}

test "hooks list loads user and project command hooks" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo/.codex");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/config.toml",
        .data =
        \\[hooks]
        \\
        \\[[hooks.PreToolUse]]
        \\matcher = "Bash"
        \\
        \\[[hooks.PreToolUse.hooks]]
        \\type = "command"
        \\command = "python3 /tmp/listed-hook.py"
        \\timeout = 5
        \\statusMessage = "running listed hook"
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "repo/.codex/config.toml",
        .data =
        \\[features]
        \\hooks = true
        \\
        \\[hooks]
        \\
        \\[[hooks.UserPromptSubmit]]
        \\
        \\[[hooks.UserPromptSubmit.hooks]]
        \\type = "command"
        \\command = "echo project hook"
        ,
    });

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 2), result.entries[0].hooks.len);
    const user_hook = result.entries[0].hooks[0];
    try std.testing.expectEqualStrings("preToolUse", user_hook.event_name.jsonLabel());
    try std.testing.expectEqualStrings("Bash", user_hook.matcher.?);
    try std.testing.expectEqualStrings("python3 /tmp/listed-hook.py", user_hook.command);
    try std.testing.expectEqual(@as(u64, 5), user_hook.timeout_sec);
    try std.testing.expectEqualStrings("running listed hook", user_hook.status_message.?);
    try std.testing.expectEqual(Source.user, user_hook.source);
    try std.testing.expect(std.mem.endsWith(u8, user_hook.key, ":pre_tool_use:0:0"));
    try std.testing.expect(std.mem.startsWith(u8, user_hook.current_hash, "sha256:"));

    const project_hook = result.entries[0].hooks[1];
    try std.testing.expectEqualStrings("userPromptSubmit", project_hook.event_name.jsonLabel());
    try std.testing.expectEqualStrings("echo project hook", project_hook.command);
    try std.testing.expectEqual(@as(u64, DEFAULT_TIMEOUT_SEC), project_hook.timeout_sec);
    try std.testing.expectEqual(Source.project, project_hook.source);
}

test "hooks list honors disabled hooks feature" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/config.toml",
        .data =
        \\[features]
        \\hooks = false
        \\
        \\[hooks]
        \\
        \\[[hooks.PreToolUse]]
        \\
        \\[[hooks.PreToolUse.hooks]]
        \\type = "command"
        \\command = "echo skipped"
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/hooks.json",
        .data =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo skipped json"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), result.entries[0].hooks.len);
}

test "hooks list loads user and project hooks json" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo/.codex");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/hooks.json",
        .data =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "matcher": "Bash",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo user json",
        \\            "timeout": 7,
        \\            "statusMessage": "running user json"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "repo/.codex/hooks.json",
        .data =
        \\{
        \\  "hooks": {
        \\    "UserPromptSubmit": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo project json"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 2), result.entries[0].hooks.len);

    const user_hook = result.entries[0].hooks[0];
    try std.testing.expectEqualStrings("preToolUse", user_hook.event_name.jsonLabel());
    try std.testing.expectEqualStrings("Bash", user_hook.matcher.?);
    try std.testing.expectEqualStrings("echo user json", user_hook.command);
    try std.testing.expectEqual(@as(u64, 7), user_hook.timeout_sec);
    try std.testing.expectEqualStrings("running user json", user_hook.status_message.?);
    try std.testing.expectEqual(Source.user, user_hook.source);
    try std.testing.expect(std.mem.endsWith(u8, user_hook.source_path, "codex-home/hooks.json"));
    try std.testing.expect(std.mem.endsWith(u8, user_hook.key, "hooks.json:pre_tool_use:0:0"));

    const project_hook = result.entries[0].hooks[1];
    try std.testing.expectEqualStrings("userPromptSubmit", project_hook.event_name.jsonLabel());
    try std.testing.expectEqualStrings("echo project json", project_hook.command);
    try std.testing.expectEqual(@as(u64, DEFAULT_TIMEOUT_SEC), project_hook.timeout_sec);
    try std.testing.expectEqual(Source.project, project_hook.source);
    try std.testing.expect(std.mem.endsWith(u8, project_hook.source_path, "repo/.codex/hooks.json"));
    try std.testing.expect(std.mem.endsWith(u8, project_hook.key, "hooks.json:user_prompt_submit:0:0"));
}

test "hooks list loads enabled plugin hooks from local cache" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home/plugins/cache/test/demo/local/.codex-plugin");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home/plugins/cache/test/demo/local/hooks");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/config.toml",
        .data =
        \\[features]
        \\hooks = true
        \\plugins = true
        \\plugin_hooks = true
        \\
        \\[plugins."demo@test"]
        \\enabled = true
        \\
        \\[plugins."disabled@test"]
        \\enabled = false
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/plugins/cache/test/demo/local/.codex-plugin/plugin.json",
        .data = "{\"name\":\"demo\"}",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/plugins/cache/test/demo/local/hooks/hooks.json",
        .data =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "matcher": "Bash",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo plugin hook",
        \\            "timeout": 7,
        \\            "statusMessage": "running plugin hook"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        ,
    });

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 1), result.entries[0].hooks.len);

    const hook = result.entries[0].hooks[0];
    try std.testing.expectEqualStrings("demo@test:hooks/hooks.json:pre_tool_use:0:0", hook.key);
    try std.testing.expectEqualStrings("preToolUse", hook.event_name.jsonLabel());
    try std.testing.expectEqualStrings("Bash", hook.matcher.?);
    try std.testing.expectEqualStrings("echo plugin hook", hook.command);
    try std.testing.expectEqual(@as(u64, 7), hook.timeout_sec);
    try std.testing.expectEqualStrings("running plugin hook", hook.status_message.?);
    try std.testing.expectEqual(Source.plugin, hook.source);
    try std.testing.expectEqualStrings("demo@test", hook.plugin_id.?);
    try std.testing.expect(std.mem.endsWith(u8, hook.source_path, "codex-home/plugins/cache/test/demo/local/hooks/hooks.json"));
    try std.testing.expect(std.mem.startsWith(u8, hook.current_hash, "sha256:"));

    const rendered = try renderResponse(allocator, result);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source\":\"plugin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"pluginId\":\"demo@test\"") != null);
}

test "hooks list applies user hook state" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo");

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const config_path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(config_path);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);
    const hook_key = try std.fmt.allocPrint(allocator, "{s}:pre_tool_use:0:0", .{config_path});
    defer allocator.free(hook_key);
    const current_hash = try commandHookHash(allocator, .pre_tool_use, "Bash", "echo stateful", 5, null);
    defer allocator.free(current_hash);
    const config_bytes = try std.fmt.allocPrint(
        allocator,
        \\[hooks]
        \\state = {{"{s}" = {{"enabled" = false, "trusted_hash" = "{s}"}}}}
        \\
        \\[[hooks.PreToolUse]]
        \\matcher = "Bash"
        \\
        \\[[hooks.PreToolUse.hooks]]
        \\type = "command"
        \\command = "echo stateful"
        \\timeout = 5
        \\
    ,
        .{ hook_key, current_hash },
    );
    defer allocator.free(config_bytes);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/config.toml",
        .data = config_bytes,
    });

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries[0].hooks.len);
    const hook = result.entries[0].hooks[0];
    try std.testing.expectEqual(false, hook.enabled);
    try std.testing.expectEqual(TrustStatus.trusted, hook.trust_status);
}

test "hooks list applies user hook state table" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "codex-home");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repo");

    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const config_path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(config_path);
    const cwd = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(cwd);
    const hook_key = try std.fmt.allocPrint(allocator, "{s}:pre_tool_use:0:0", .{config_path});
    defer allocator.free(hook_key);
    const current_hash = try commandHookHash(allocator, .pre_tool_use, "Bash", "echo table state", 5, null);
    defer allocator.free(current_hash);
    const config_bytes = try std.fmt.allocPrint(
        allocator,
        \\[hooks]
        \\
        \\[hooks.state."{s}"]
        \\enabled = false
        \\trusted_hash = "{s}"
        \\
        \\[[hooks.PreToolUse]]
        \\matcher = "Bash"
        \\
        \\[[hooks.PreToolUse.hooks]]
        \\type = "command"
        \\command = "echo table state"
        \\timeout = 5
        \\
    ,
        .{ hook_key, current_hash },
    );
    defer allocator.free(config_bytes);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "codex-home/config.toml",
        .data = config_bytes,
    });

    var result = try list(allocator, codex_home, &.{cwd});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries[0].hooks.len);
    const hook = result.entries[0].hooks[0];
    try std.testing.expectEqual(false, hook.enabled);
    try std.testing.expectEqual(TrustStatus.trusted, hook.trust_status);
}
