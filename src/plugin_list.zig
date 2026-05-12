const std = @import("std");

const marketplace_config = @import("marketplace_config.zig");
const plugin_config = @import("plugin_config.zig");
const skills_list = @import("skills_list.zig");

const MARKETPLACE_MANIFEST_RELATIVE_PATHS = [_][]const u8{
    ".agents/plugins/marketplace.json",
    ".claude-plugin/marketplace.json",
};

const AGENTS_MARKETPLACE_SUFFIX = "/.agents/plugins/marketplace.json";
const CLAUDE_MARKETPLACE_SUFFIX = "/.claude-plugin/marketplace.json";

const SourceRender = struct {
    plugin_root: ?[]const u8 = null,
    source_json: []const u8,

    fn deinit(self: SourceRender, allocator: std.mem.Allocator) void {
        if (self.plugin_root) |path| allocator.free(path);
        allocator.free(self.source_json);
    }
};

const InstallSourceRoot = struct {
    plugin_root: []const u8,
    cleanup_root: ?[]const u8 = null,

    fn deinit(self: InstallSourceRoot, allocator: std.mem.Allocator) void {
        if (self.cleanup_root) |path| {
            deletePathIfPresent(path) catch {};
            allocator.free(path);
        }
        allocator.free(self.plugin_root);
    }
};

pub const ReadError = error{
    InvalidMarketplaceFile,
    PluginNotFound,
    MissingPluginManifest,
    PluginsDisabled,
};

pub const InstallError = error{
    InvalidMarketplaceFile,
    PluginNotFound,
    MissingPluginManifest,
    PluginsDisabled,
    UnsupportedInstallSource,
    PluginNotAvailable,
    InvalidPluginId,
    PluginNameMismatch,
    InvalidPluginVersion,
};

pub const InstallResult = struct {
    response_json: []const u8,
    updated_config: []const u8,
    installed_path: []const u8,

    pub fn deinit(self: InstallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.response_json);
        allocator.free(self.updated_config);
        allocator.free(self.installed_path);
    }
};

const AppListEntry = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    install_url: ?[]const u8,
    is_enabled: bool,
    plugin_display_names: std.ArrayList([]const u8),

    fn deinit(self: *AppListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.description) |value| allocator.free(value);
        if (self.install_url) |value| allocator.free(value);
        for (self.plugin_display_names.items) |value| allocator.free(value);
        self.plugin_display_names.deinit(allocator);
    }
};

pub fn renderAppsListResponse(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    cwds: []const []const u8,
    start: usize,
    limit: ?usize,
    total_out: *usize,
) !?[]const u8 {
    var apps = std.ArrayList(AppListEntry).empty;
    defer {
        for (apps.items) |*app| app.deinit(allocator);
        apps.deinit(allocator);
    }

    if (plugin_config.pluginsFeatureEnabled(config_bytes)) {
        const enabled_ids = try plugin_config.enabledPluginIds(allocator, config_bytes);
        defer plugin_config.freeStringList(allocator, enabled_ids);

        var seen_plugin_ids = std.ArrayList([]const u8).empty;
        defer {
            for (seen_plugin_ids.items) |plugin_id| allocator.free(plugin_id);
            seen_plugin_ids.deinit(allocator);
        }

        try collectAppsFromEnabledPluginCache(allocator, codex_home, config_bytes, enabled_ids, &seen_plugin_ids, &apps);
        try collectAppsForRoot(allocator, config_bytes, codex_home, enabled_ids, &seen_plugin_ids, &apps);
        const configured_roots = try marketplace_config.configuredMarketplaceRoots(allocator, codex_home, config_bytes);
        defer {
            for (configured_roots) |*root| root.deinit(allocator);
            allocator.free(configured_roots);
        }
        for (configured_roots) |root| {
            try collectAppsForRoot(allocator, config_bytes, root.root, enabled_ids, &seen_plugin_ids, &apps);
        }
        for (cwds) |cwd| {
            try collectAppsForRoot(allocator, config_bytes, cwd, enabled_ids, &seen_plugin_ids, &apps);
        }
    }

    std.mem.sort(AppListEntry, apps.items, {}, appListEntryLessThan);
    for (apps.items) |*app| {
        std.mem.sort([]const u8, app.plugin_display_names.items, {}, appListStringLessThan);
    }

    const total = apps.items.len;
    total_out.* = total;
    if (start > total) return null;

    const effective_limit = @min(@max(limit orelse total, 1), total);
    const end = @min(start + effective_limit, total);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");
    for (apps.items[start..end], 0..) |app, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendAppListEntryJson(allocator, &out, app);
    }
    try out.appendSlice(allocator, "],\"nextCursor\":");
    if (end < total) {
        const next_cursor = try std.fmt.allocPrint(allocator, "{d}", .{end});
        defer allocator.free(next_cursor);
        const next_cursor_json = try jsonString(allocator, next_cursor);
        defer allocator.free(next_cursor_json);
        try out.appendSlice(allocator, next_cursor_json);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "}");
    return try out.toOwnedSlice(allocator);
}

pub fn renderResponse(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    cwds: []const []const u8,
    include_local: bool,
) ![]const u8 {
    return renderResponseWithRemoteMarketplaces(allocator, codex_home, config_bytes, cwds, include_local, null);
}

pub fn renderResponseWithRemoteMarketplaces(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    cwds: []const []const u8,
    include_local: bool,
    remote_marketplaces_json: ?[]const u8,
) ![]const u8 {
    if (!plugin_config.pluginsFeatureEnabled(config_bytes)) {
        return allocator.dupe(u8, "{\"marketplaces\":[],\"marketplaceLoadErrors\":[],\"featuredPluginIds\":[]}");
    }

    var seen_plugin_ids = std.ArrayList([]const u8).empty;
    defer {
        for (seen_plugin_ids.items) |plugin_id| allocator.free(plugin_id);
        seen_plugin_ids.deinit(allocator);
    }

    var marketplaces = std.ArrayList(u8).empty;
    defer marketplaces.deinit(allocator);
    var marketplace_count: usize = 0;

    var load_errors = std.ArrayList(u8).empty;
    defer load_errors.deinit(allocator);
    var load_error_count: usize = 0;

    if (include_local) {
        const enabled_ids = try plugin_config.enabledPluginIds(allocator, config_bytes);
        defer plugin_config.freeStringList(allocator, enabled_ids);

        try appendMarketplacesForRoot(allocator, codex_home, codex_home, enabled_ids, &seen_plugin_ids, &marketplaces, &marketplace_count, &load_errors, &load_error_count);
        const configured_roots = try marketplace_config.configuredMarketplaceRoots(allocator, codex_home, config_bytes);
        defer {
            for (configured_roots) |*root| root.deinit(allocator);
            allocator.free(configured_roots);
        }
        for (configured_roots) |root| {
            try appendMarketplacesForRoot(allocator, codex_home, root.root, enabled_ids, &seen_plugin_ids, &marketplaces, &marketplace_count, &load_errors, &load_error_count);
        }
        for (cwds) |cwd| {
            try appendMarketplacesForRoot(allocator, codex_home, cwd, enabled_ids, &seen_plugin_ids, &marketplaces, &marketplace_count, &load_errors, &load_error_count);
        }
    }
    if (remote_marketplaces_json) |json| {
        try appendRemoteMarketplaceArrayItems(allocator, &marketplaces, &marketplace_count, json);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"marketplaces\":[");
    try out.appendSlice(allocator, marketplaces.items);
    try out.appendSlice(allocator, "],\"marketplaceLoadErrors\":[");
    try out.appendSlice(allocator, load_errors.items);
    try out.appendSlice(allocator, "],\"featuredPluginIds\":[]}");
    return out.toOwnedSlice(allocator);
}

fn appendRemoteMarketplaceArrayItems(
    allocator: std.mem.Allocator,
    marketplaces: *std.ArrayList(u8),
    marketplace_count: *usize,
    remote_marketplaces_json: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, remote_marketplaces_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidRemoteMarketplaceJson;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (inner.len == 0) return;
    if (marketplace_count.* > 0) try marketplaces.append(allocator, ',');
    try marketplaces.appendSlice(allocator, inner);
    marketplace_count.* += 1;
}

pub fn renderReadResponse(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    marketplace_path: []const u8,
    requested_plugin_name: []const u8,
) ![]const u8 {
    if (!plugin_config.pluginsFeatureEnabled(config_bytes)) return ReadError.PluginsDisabled;

    const enabled_ids = try plugin_config.enabledPluginIds(allocator, config_bytes);
    defer plugin_config.freeStringList(allocator, enabled_ids);

    const bytes = try readFileOptional(allocator, marketplace_path, 1024 * 1024) orelse return ReadError.InvalidMarketplaceFile;
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return ReadError.InvalidMarketplaceFile;
    defer parsed.deinit();
    if (parsed.value != .object) return ReadError.InvalidMarketplaceFile;
    const object = parsed.value.object;
    const marketplace_name = stringField(object, "name") orelse return ReadError.InvalidMarketplaceFile;
    const plugins_value = object.get("plugins") orelse return ReadError.InvalidMarketplaceFile;
    if (plugins_value != .array) return ReadError.InvalidMarketplaceFile;

    for (plugins_value.array.items) |plugin_value| {
        if (plugin_value != .object) continue;
        const plugin_name = stringField(plugin_value.object, "name") orelse continue;
        if (!std.mem.eql(u8, plugin_name, requested_plugin_name)) continue;

        const source_value = plugin_value.object.get("source") orelse return ReadError.MissingPluginManifest;
        const source = (try renderPluginSource(allocator, marketplace_path, source_value)) orelse return ReadError.MissingPluginManifest;
        defer source.deinit(allocator);
        const plugin_root = source.plugin_root orelse return ReadError.MissingPluginManifest;

        const manifest_bytes = try readPluginManifestBytes(allocator, plugin_root) orelse return ReadError.MissingPluginManifest;
        defer allocator.free(manifest_bytes);
        var manifest_parse = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch return ReadError.MissingPluginManifest;
        defer manifest_parse.deinit();
        if (manifest_parse.value != .object) return ReadError.MissingPluginManifest;

        const plugin_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ plugin_name, marketplace_name });
        defer allocator.free(plugin_id);
        const category = stringField(plugin_value.object, "category");

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const marketplace_name_json = try jsonString(allocator, marketplace_name);
        defer allocator.free(marketplace_name_json);
        const marketplace_path_json = try jsonString(allocator, marketplace_path);
        defer allocator.free(marketplace_path_json);

        try out.appendSlice(allocator, "{\"plugin\":{\"marketplaceName\":");
        try out.appendSlice(allocator, marketplace_name_json);
        try out.appendSlice(allocator, ",\"marketplacePath\":");
        try out.appendSlice(allocator, marketplace_path_json);
        try out.appendSlice(allocator, ",\"summary\":");
        try appendPluginSummaryJson(
            allocator,
            &out,
            codex_home,
            marketplace_name,
            plugin_name,
            plugin_id,
            source,
            plugin_value.object,
            enabled_ids,
            manifest_parse.value,
            category,
        );
        try out.appendSlice(allocator, ",\"description\":");
        try appendOptionalStringJson(allocator, &out, stringField(manifest_parse.value.object, "description"));
        try out.appendSlice(allocator, ",\"skills\":");
        try appendPluginSkillsJson(allocator, &out, plugin_root, manifest_parse.value.object, config_bytes);
        try out.appendSlice(allocator, ",\"hooks\":");
        try appendPluginHooksJson(allocator, &out, plugin_root, plugin_id);
        try out.appendSlice(allocator, ",\"apps\":");
        try appendPluginAppsJson(allocator, &out, plugin_root);
        try out.appendSlice(allocator, ",\"mcpServers\":");
        try appendPluginMcpServerNamesJson(allocator, &out, plugin_root);
        try out.appendSlice(allocator, "}}");
        return out.toOwnedSlice(allocator);
    }

    return ReadError.PluginNotFound;
}

pub fn installLocalPlugin(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    marketplace_path: []const u8,
    requested_plugin_name: []const u8,
) !InstallResult {
    if (!plugin_config.pluginsFeatureEnabled(config_bytes)) return InstallError.PluginsDisabled;

    const bytes = try readFileOptional(allocator, marketplace_path, 1024 * 1024) orelse return InstallError.InvalidMarketplaceFile;
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return InstallError.InvalidMarketplaceFile;
    defer parsed.deinit();
    if (parsed.value != .object) return InstallError.InvalidMarketplaceFile;
    const object = parsed.value.object;
    const marketplace_name = stringField(object, "name") orelse return InstallError.InvalidMarketplaceFile;
    const plugins_value = object.get("plugins") orelse return InstallError.InvalidMarketplaceFile;
    if (plugins_value != .array) return InstallError.InvalidMarketplaceFile;

    for (plugins_value.array.items) |plugin_value| {
        if (plugin_value != .object) continue;
        const plugin_name = stringField(plugin_value.object, "name") orelse continue;
        if (!std.mem.eql(u8, plugin_name, requested_plugin_name)) continue;
        if (!plugin_config.isValidPluginSegment(plugin_name) or !plugin_config.isValidPluginSegment(marketplace_name)) {
            return InstallError.InvalidPluginId;
        }
        if (std.mem.eql(u8, installPolicy(plugin_value.object.get("policy")), "NOT_AVAILABLE")) {
            return InstallError.PluginNotAvailable;
        }

        const source_value = plugin_value.object.get("source") orelse return InstallError.UnsupportedInstallSource;
        const plugin_base_root = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", marketplace_name, plugin_name });
        defer allocator.free(plugin_base_root);
        const install_source = (try materializeInstallSource(
            allocator,
            codex_home,
            marketplace_name,
            plugin_name,
            marketplace_path,
            source_value,
        )) orelse return InstallError.UnsupportedInstallSource;
        defer install_source.deinit(allocator);
        const plugin_root = install_source.plugin_root;

        const manifest_bytes = try readPluginManifestBytes(allocator, plugin_root) orelse return InstallError.MissingPluginManifest;
        defer allocator.free(manifest_bytes);
        var manifest_parse = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch return InstallError.MissingPluginManifest;
        defer manifest_parse.deinit();
        if (manifest_parse.value != .object) return InstallError.MissingPluginManifest;
        const manifest_name = stringField(manifest_parse.value.object, "name") orelse return InstallError.MissingPluginManifest;
        if (!std.mem.eql(u8, manifest_name, plugin_name)) return InstallError.PluginNameMismatch;
        const plugin_version = try pluginVersionForManifest(manifest_parse.value.object);

        const plugin_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ plugin_name, marketplace_name });
        defer allocator.free(plugin_id);
        const installed_path = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", marketplace_name, plugin_name, plugin_version });
        errdefer allocator.free(installed_path);

        try replaceLocalPluginCache(allocator, plugin_root, plugin_base_root, installed_path);
        const updated_config = try plugin_config.upsertEnabledPluginConfig(allocator, config_bytes, plugin_id);
        errdefer allocator.free(updated_config);
        const response_json = try renderInstallResponseJson(allocator, authPolicy(plugin_value.object.get("policy")));
        errdefer allocator.free(response_json);
        return .{
            .response_json = response_json,
            .updated_config = updated_config,
            .installed_path = installed_path,
        };
    }

    return InstallError.PluginNotFound;
}

fn appendMarketplacesForRoot(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    root: []const u8,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    marketplaces: *std.ArrayList(u8),
    marketplace_count: *usize,
    load_errors: *std.ArrayList(u8),
    load_error_count: *usize,
) !void {
    for (MARKETPLACE_MANIFEST_RELATIVE_PATHS) |relative_path| {
        const marketplace_path = try std.fs.path.join(allocator, &.{ root, relative_path });
        defer allocator.free(marketplace_path);
        try appendMarketplaceFromFile(
            allocator,
            codex_home,
            marketplace_path,
            enabled_ids,
            seen_plugin_ids,
            marketplaces,
            marketplace_count,
            load_errors,
            load_error_count,
        );
    }
}

fn appendMarketplaceFromFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_path: []const u8,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    marketplaces: *std.ArrayList(u8),
    marketplace_count: *usize,
    load_errors: *std.ArrayList(u8),
    load_error_count: *usize,
) !void {
    const bytes = try readFileOptional(allocator, marketplace_path, 1024 * 1024) orelse return;
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try appendMarketplaceLoadError(allocator, load_errors, load_error_count, marketplace_path, "invalid marketplace file");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try appendMarketplaceLoadError(allocator, load_errors, load_error_count, marketplace_path, "invalid marketplace file: root must be an object");
        return;
    }
    const object = parsed.value.object;
    const marketplace_name = stringField(object, "name") orelse {
        try appendMarketplaceLoadError(allocator, load_errors, load_error_count, marketplace_path, "invalid marketplace file: name must be a string");
        return;
    };
    const plugins_value = object.get("plugins") orelse {
        try appendMarketplaceLoadError(allocator, load_errors, load_error_count, marketplace_path, "invalid marketplace file: plugins must be an array");
        return;
    };
    if (plugins_value != .array) {
        try appendMarketplaceLoadError(allocator, load_errors, load_error_count, marketplace_path, "invalid marketplace file: plugins must be an array");
        return;
    }

    var plugins = std.ArrayList(u8).empty;
    defer plugins.deinit(allocator);
    var plugin_count: usize = 0;
    for (plugins_value.array.items) |plugin_value| {
        try appendPluginFromMarketplaceEntry(
            allocator,
            codex_home,
            marketplace_path,
            marketplace_name,
            plugin_value,
            enabled_ids,
            seen_plugin_ids,
            &plugins,
            &plugin_count,
        );
    }
    if (plugin_count == 0) return;

    try appendCommaIfNeeded(allocator, marketplaces, marketplace_count);
    const name_json = try jsonString(allocator, marketplace_name);
    defer allocator.free(name_json);
    const path_json = try jsonString(allocator, marketplace_path);
    defer allocator.free(path_json);

    try marketplaces.appendSlice(allocator, "{\"name\":");
    try marketplaces.appendSlice(allocator, name_json);
    try marketplaces.appendSlice(allocator, ",\"path\":");
    try marketplaces.appendSlice(allocator, path_json);
    try marketplaces.appendSlice(allocator, ",\"interface\":");
    try appendMarketplaceInterfaceJson(allocator, marketplaces, object.get("interface"));
    try marketplaces.appendSlice(allocator, ",\"plugins\":[");
    try marketplaces.appendSlice(allocator, plugins.items);
    try marketplaces.appendSlice(allocator, "]}");
}

fn appendPluginFromMarketplaceEntry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_path: []const u8,
    marketplace_name: []const u8,
    plugin_value: std.json.Value,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    plugins: *std.ArrayList(u8),
    plugin_count: *usize,
) !void {
    if (plugin_value != .object) return;
    const object = plugin_value.object;
    const plugin_name = stringField(object, "name") orelse return;
    if (plugin_name.len == 0 or marketplace_name.len == 0) return;

    const source_value = object.get("source") orelse return;
    const source = (try renderPluginSource(allocator, marketplace_path, source_value)) orelse return;
    defer source.deinit(allocator);

    const plugin_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ plugin_name, marketplace_name });
    errdefer allocator.free(plugin_id);
    if (containsString(seen_plugin_ids.items, plugin_id)) {
        allocator.free(plugin_id);
        return;
    }
    try seen_plugin_ids.append(allocator, plugin_id);

    const category = stringField(object, "category");

    var manifest_parse: ?std.json.Parsed(std.json.Value) = null;
    defer if (manifest_parse) |*parsed| parsed.deinit();
    var manifest_bytes: ?[]const u8 = null;
    defer if (manifest_bytes) |bytes| allocator.free(bytes);
    if (source.plugin_root) |plugin_root| {
        manifest_bytes = try readPluginManifestBytes(allocator, plugin_root);
        if (manifest_bytes) |bytes| {
            manifest_parse = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null;
        }
    }
    const manifest_value = if (manifest_parse) |parsed| parsed.value else null;

    try appendCommaIfNeeded(allocator, plugins, plugin_count);
    try appendPluginSummaryJson(
        allocator,
        plugins,
        codex_home,
        marketplace_name,
        plugin_name,
        plugin_id,
        source,
        object,
        enabled_ids,
        manifest_value,
        category,
    );
}

fn appendPluginSummaryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    codex_home: []const u8,
    marketplace_name: []const u8,
    plugin_name: []const u8,
    plugin_id: []const u8,
    source: SourceRender,
    plugin_object: std.json.ObjectMap,
    enabled_ids: []const []const u8,
    manifest_value: ?std.json.Value,
    category: ?[]const u8,
) !void {
    const installed = try installedPluginExists(allocator, codex_home, marketplace_name, plugin_name);
    const enabled = containsString(enabled_ids, plugin_id);
    const install_policy = installPolicy(plugin_object.get("policy"));
    const auth_policy = authPolicy(plugin_object.get("policy"));

    const id_json = try jsonString(allocator, plugin_id);
    defer allocator.free(id_json);
    const name_json = try jsonString(allocator, plugin_name);
    defer allocator.free(name_json);

    try out.appendSlice(allocator, "{\"id\":");
    try out.appendSlice(allocator, id_json);
    try out.appendSlice(allocator, ",\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"shareContext\":null,\"source\":");
    try out.appendSlice(allocator, source.source_json);
    try out.appendSlice(allocator, ",\"installed\":");
    try appendBool(allocator, out, installed);
    try out.appendSlice(allocator, ",\"enabled\":");
    try appendBool(allocator, out, enabled);
    try out.appendSlice(allocator, ",\"installPolicy\":\"");
    try out.appendSlice(allocator, install_policy);
    try out.appendSlice(allocator, "\",\"authPolicy\":\"");
    try out.appendSlice(allocator, auth_policy);
    try out.appendSlice(allocator, "\",\"availability\":\"AVAILABLE\",\"interface\":");
    try appendPluginInterfaceJson(allocator, out, source.plugin_root, manifest_value, category);
    try out.appendSlice(allocator, ",\"keywords\":");
    try appendManifestKeywordsJson(allocator, out, manifest_value);
    try out.appendSlice(allocator, "}");
}

fn renderPluginSource(allocator: std.mem.Allocator, marketplace_path: []const u8, source_value: std.json.Value) !?SourceRender {
    if (source_value == .string) {
        return try renderLocalPluginSource(allocator, marketplace_path, source_value.string);
    }
    if (source_value != .object) return null;

    const kind = stringField(source_value.object, "source") orelse return null;
    if (std.mem.eql(u8, kind, "local")) {
        const path = stringField(source_value.object, "path") orelse return null;
        return try renderLocalPluginSource(allocator, marketplace_path, path);
    }
    if (std.mem.eql(u8, kind, "url")) {
        return try renderGitPluginSource(allocator, source_value.object, false);
    }
    if (std.mem.eql(u8, kind, "git-subdir")) {
        return try renderGitPluginSource(allocator, source_value.object, true);
    }
    return null;
}

fn renderLocalPluginSource(allocator: std.mem.Allocator, marketplace_path: []const u8, raw_path: []const u8) !?SourceRender {
    const plugin_root = (try resolveLocalPluginPath(allocator, marketplace_path, raw_path)) orelse return null;
    errdefer allocator.free(plugin_root);
    const path_json = try jsonString(allocator, plugin_root);
    defer allocator.free(path_json);
    const source_json = try std.fmt.allocPrint(allocator, "{{\"type\":\"local\",\"path\":{s}}}", .{path_json});
    return .{ .plugin_root = plugin_root, .source_json = source_json };
}

fn renderGitPluginSource(allocator: std.mem.Allocator, object: std.json.ObjectMap, require_path: bool) !?SourceRender {
    const url = stringField(object, "url") orelse return null;
    const path = stringField(object, "path");
    if (require_path and path == null) return null;
    const url_json = try jsonString(allocator, url);
    defer allocator.free(url_json);
    const path_json = try optionalJsonString(allocator, path);
    defer allocator.free(path_json);
    const ref_json = try optionalJsonString(allocator, stringField(object, "ref"));
    defer allocator.free(ref_json);
    const sha_json = try optionalJsonString(allocator, stringField(object, "sha"));
    defer allocator.free(sha_json);
    const source_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"git\",\"url\":{s},\"path\":{s},\"refName\":{s},\"sha\":{s}}}",
        .{ url_json, path_json, ref_json, sha_json },
    );
    return .{ .source_json = source_json };
}

fn materializeInstallSource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_name: []const u8,
    plugin_name: []const u8,
    marketplace_path: []const u8,
    source_value: std.json.Value,
) !?InstallSourceRoot {
    if (source_value == .string) {
        return materializeLocalInstallSource(allocator, marketplace_path, source_value.string);
    }
    if (source_value != .object) return null;

    const kind = stringField(source_value.object, "source") orelse return null;
    if (std.mem.eql(u8, kind, "local")) {
        const path = stringField(source_value.object, "path") orelse return null;
        return materializeLocalInstallSource(allocator, marketplace_path, path);
    }
    if (std.mem.eql(u8, kind, "url")) {
        return materializeGitInstallSource(allocator, codex_home, marketplace_name, plugin_name, source_value.object, false);
    }
    if (std.mem.eql(u8, kind, "git-subdir")) {
        return materializeGitInstallSource(allocator, codex_home, marketplace_name, plugin_name, source_value.object, true);
    }
    return null;
}

fn materializeLocalInstallSource(allocator: std.mem.Allocator, marketplace_path: []const u8, raw_path: []const u8) !?InstallSourceRoot {
    const plugin_root = (try resolveLocalPluginPath(allocator, marketplace_path, raw_path)) orelse return null;
    return .{ .plugin_root = plugin_root };
}

fn materializeGitInstallSource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    marketplace_name: []const u8,
    plugin_name: []const u8,
    object: std.json.ObjectMap,
    require_path: bool,
) !?InstallSourceRoot {
    const url = stringField(object, "url") orelse return null;
    if (std.mem.trim(u8, url, " \t\r\n").len == 0) return null;
    const source_path = stringField(object, "path");
    if (require_path and source_path == null) return null;
    if (source_path) |path| {
        if (path.len == 0 or !isSafeRelativePath(path)) return null;
    }

    const staging_root = try std.fs.path.join(allocator, &.{ codex_home, "plugins", ".marketplace-plugin-source-staging" });
    defer allocator.free(staging_root);
    const clone_root = try std.fs.path.join(allocator, &.{ staging_root, marketplace_name, plugin_name });
    errdefer allocator.free(clone_root);

    try deletePathIfPresent(clone_root);
    errdefer deletePathIfPresent(clone_root) catch {};
    const clone_parent = std.fs.path.dirname(clone_root) orelse staging_root;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), clone_parent);
    try cloneGitPluginSource(allocator, url, stringField(object, "ref"), stringField(object, "sha"), source_path, clone_root);

    const plugin_root = if (source_path) |path|
        try std.fs.path.join(allocator, &.{ clone_root, path })
    else
        try allocator.dupe(u8, clone_root);
    errdefer allocator.free(plugin_root);

    return .{
        .plugin_root = plugin_root,
        .cleanup_root = clone_root,
    };
}

fn cloneGitPluginSource(
    allocator: std.mem.Allocator,
    url: []const u8,
    ref_name: ?[]const u8,
    sha: ?[]const u8,
    sparse_checkout_path: ?[]const u8,
    destination: []const u8,
) !void {
    if (sparse_checkout_path) |path| {
        try runGit(allocator, &.{ "git", "clone", "--filter=blob:none", "--sparse", "--no-checkout", url, destination }, null);
        try runGit(allocator, &.{ "git", "sparse-checkout", "set", "--no-cone", "--", path }, destination);
    } else {
        try runGit(allocator, &.{ "git", "clone", url, destination }, null);
    }

    if (sha orelse ref_name) |target| {
        try runGit(allocator, &.{ "git", "checkout", target }, destination);
    } else if (sparse_checkout_path != null) {
        try runGit(allocator, &.{ "git", "checkout" }, destination);
    }
}

fn runGit(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var env_argv = std.ArrayList([]const u8).empty;
    defer env_argv.deinit(allocator);
    try env_argv.append(allocator, "env");
    try env_argv.append(allocator, "GIT_TERMINAL_PROMPT=0");
    try env_argv.appendSlice(allocator, argv);

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = env_argv.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(30_000),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return InstallError.UnsupportedInstallSource;
}

fn resolveLocalPluginPath(allocator: std.mem.Allocator, marketplace_path: []const u8, raw_path: []const u8) !?[]const u8 {
    const stripped = std.mem.trim(u8, raw_path, " \t\r\n");
    if (!std.mem.startsWith(u8, stripped, "./")) return null;
    const relative = stripped[2..];
    if (relative.len == 0 or !isSafeRelativePath(relative)) return null;
    const root = try marketplaceRootDir(allocator, marketplace_path);
    defer allocator.free(root);
    const resolved = try std.fs.path.join(allocator, &.{ root, relative });
    return resolved;
}

fn marketplaceRootDir(allocator: std.mem.Allocator, marketplace_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, marketplace_path, AGENTS_MARKETPLACE_SUFFIX)) {
        const end = marketplace_path.len - AGENTS_MARKETPLACE_SUFFIX.len;
        if (end == 0) return allocator.dupe(u8, "/");
        return allocator.dupe(u8, marketplace_path[0..end]);
    }
    if (std.mem.endsWith(u8, marketplace_path, CLAUDE_MARKETPLACE_SUFFIX)) {
        const end = marketplace_path.len - CLAUDE_MARKETPLACE_SUFFIX.len;
        if (end == 0) return allocator.dupe(u8, "/");
        return allocator.dupe(u8, marketplace_path[0..end]);
    }
    return error.InvalidMarketplaceLayout;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn appendMarketplaceInterfaceJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value_opt: ?std.json.Value) !void {
    const value = value_opt orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    if (value != .object) {
        try out.appendSlice(allocator, "null");
        return;
    }
    const display_name = stringField(value.object, "displayName") orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    const display_name_json = try jsonString(allocator, display_name);
    defer allocator.free(display_name_json);
    try out.appendSlice(allocator, "{\"displayName\":");
    try out.appendSlice(allocator, display_name_json);
    try out.appendSlice(allocator, "}");
}

fn appendPluginInterfaceJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    plugin_root: ?[]const u8,
    manifest_value: ?std.json.Value,
    marketplace_category: ?[]const u8,
) !void {
    const interface_value = pluginManifestInterfaceValue(manifest_value);
    if (!pluginInterfaceHasFields(interface_value, marketplace_category)) {
        try out.appendSlice(allocator, "null");
        return;
    }
    const interface_object = if (interface_value) |value| value.object else null;

    try out.appendSlice(allocator, "{");
    try appendNamedOptionalString(allocator, out, "displayName", stringFieldOpt(interface_object, "displayName"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "shortDescription", stringFieldOpt(interface_object, "shortDescription"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "longDescription", stringFieldOpt(interface_object, "longDescription"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "developerName", stringFieldOpt(interface_object, "developerName"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "category", marketplace_category orelse stringFieldOpt(interface_object, "category"));
    try out.appendSlice(allocator, ",\"capabilities\":");
    try appendStringArrayValue(allocator, out, valueFieldOpt(interface_object, "capabilities"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "websiteUrl", stringFieldAliasOpt(interface_object, "websiteUrl", "websiteURL"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "privacyPolicyUrl", stringFieldAliasOpt(interface_object, "privacyPolicyUrl", "privacyPolicyURL"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "termsOfServiceUrl", stringFieldAliasOpt(interface_object, "termsOfServiceUrl", "termsOfServiceURL"));
    try out.appendSlice(allocator, ",\"defaultPrompt\":");
    try appendDefaultPromptJson(allocator, out, valueFieldOpt(interface_object, "defaultPrompt"));
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "brandColor", stringFieldOpt(interface_object, "brandColor"));
    try out.appendSlice(allocator, ",\"composerIcon\":");
    try appendAssetPathJson(allocator, out, plugin_root, stringFieldOpt(interface_object, "composerIcon"));
    try out.appendSlice(allocator, ",\"composerIconUrl\":null,\"logo\":");
    try appendAssetPathJson(allocator, out, plugin_root, stringFieldOpt(interface_object, "logo"));
    try out.appendSlice(allocator, ",\"logoUrl\":null,\"screenshots\":");
    try appendAssetArrayJson(allocator, out, plugin_root, valueFieldOpt(interface_object, "screenshots"));
    try out.appendSlice(allocator, ",\"screenshotUrls\":[]}");
}

fn pluginManifestInterfaceValue(manifest_value: ?std.json.Value) ?std.json.Value {
    const manifest = manifest_value orelse return null;
    if (manifest != .object) return null;
    const value = manifest.object.get("interface") orelse return null;
    if (value != .object) return null;
    return value;
}

fn pluginInterfaceHasFields(interface_value: ?std.json.Value, marketplace_category: ?[]const u8) bool {
    if (marketplace_category != null) return true;
    const value = interface_value orelse return false;
    const object = value.object;
    if (stringField(object, "displayName") != null) return true;
    if (stringField(object, "shortDescription") != null) return true;
    if (stringField(object, "longDescription") != null) return true;
    if (stringField(object, "developerName") != null) return true;
    if (stringField(object, "category") != null) return true;
    if (stringFieldAlias(object, "websiteUrl", "websiteURL") != null) return true;
    if (stringFieldAlias(object, "privacyPolicyUrl", "privacyPolicyURL") != null) return true;
    if (stringFieldAlias(object, "termsOfServiceUrl", "termsOfServiceURL") != null) return true;
    if (stringField(object, "brandColor") != null) return true;
    if (stringField(object, "composerIcon") != null) return true;
    if (stringField(object, "logo") != null) return true;
    if (stringArrayHasStrings(object.get("capabilities"))) return true;
    if (stringArrayHasStrings(object.get("screenshots"))) return true;
    if (defaultPromptHasStrings(object.get("defaultPrompt"))) return true;
    return false;
}

fn appendManifestKeywordsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), manifest_value: ?std.json.Value) !void {
    const manifest = manifest_value orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    if (manifest != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    try appendStringArrayValue(allocator, out, manifest.object.get("keywords"));
}

fn appendPluginSkillsJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    plugin_root: []const u8,
    manifest_object: std.json.ObjectMap,
    config_bytes: []const u8,
) !void {
    const prefix = pluginNamePrefix(manifest_object, plugin_root);
    var result = try skills_list.listPluginSkills(allocator, plugin_root, prefix, config_bytes);
    defer result.deinit(allocator);

    try out.appendSlice(allocator, "[");
    for (result.skills, 0..) |skill, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendPluginSkillSummaryJson(allocator, out, skill);
    }
    try out.appendSlice(allocator, "]");
}

fn appendPluginSkillSummaryJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), skill: skills_list.Skill) !void {
    const name_json = try jsonString(allocator, skill.name);
    defer allocator.free(name_json);
    const description_json = try jsonString(allocator, skill.description);
    defer allocator.free(description_json);
    const path_json = try jsonString(allocator, skill.path);
    defer allocator.free(path_json);

    try out.appendSlice(allocator, "{\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    try out.appendSlice(allocator, ",\"shortDescription\":");
    try appendOptionalStringJson(allocator, out, skill.short_description);
    try out.appendSlice(allocator, ",\"interface\":");
    if (skill.interface) |interface| {
        try appendSkillInterfaceJson(allocator, out, interface);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"path\":");
    try out.appendSlice(allocator, path_json);
    try out.appendSlice(allocator, ",\"enabled\":");
    try appendBool(allocator, out, skill.enabled);
    try out.appendSlice(allocator, "}");
}

fn appendSkillInterfaceJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), interface: skills_list.SkillInterface) !void {
    try out.appendSlice(allocator, "{");
    try appendNamedOptionalString(allocator, out, "displayName", interface.display_name);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "shortDescription", interface.short_description);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "iconSmall", interface.icon_small);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "iconLarge", interface.icon_large);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "brandColor", interface.brand_color);
    try out.appendSlice(allocator, ",");
    try appendNamedOptionalString(allocator, out, "defaultPrompt", interface.default_prompt);
    try out.appendSlice(allocator, "}");
}

const HookEventSpec = struct {
    config_label: []const u8,
    key_label: []const u8,
    json_label: []const u8,
};

const HOOK_EVENT_SPECS = [_]HookEventSpec{
    .{ .config_label = "PreToolUse", .key_label = "pre_tool_use", .json_label = "preToolUse" },
    .{ .config_label = "PermissionRequest", .key_label = "permission_request", .json_label = "permissionRequest" },
    .{ .config_label = "PostToolUse", .key_label = "post_tool_use", .json_label = "postToolUse" },
    .{ .config_label = "PreCompact", .key_label = "pre_compact", .json_label = "preCompact" },
    .{ .config_label = "PostCompact", .key_label = "post_compact", .json_label = "postCompact" },
    .{ .config_label = "SessionStart", .key_label = "session_start", .json_label = "sessionStart" },
    .{ .config_label = "UserPromptSubmit", .key_label = "user_prompt_submit", .json_label = "userPromptSubmit" },
    .{ .config_label = "Stop", .key_label = "stop", .json_label = "stop" },
};

fn appendPluginHooksJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), plugin_root: []const u8, plugin_id: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ plugin_root, "hooks", "hooks.json" });
    defer allocator.free(path);
    const bytes = try readFileOptional(allocator, path, 1024 * 256) orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    const hooks_value = parsed.value.object.get("hooks") orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    if (hooks_value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }

    try out.appendSlice(allocator, "[");
    var count: usize = 0;
    for (HOOK_EVENT_SPECS) |event| {
        const groups_value = hooks_value.object.get(event.config_label) orelse continue;
        if (groups_value != .array) continue;
        for (groups_value.array.items, 0..) |group_value, group_index| {
            if (group_value != .object) continue;
            const handlers_value = group_value.object.get("hooks") orelse continue;
            if (handlers_value != .array) continue;
            for (handlers_value.array.items, 0..) |handler_value, handler_index| {
                if (handler_value != .object) continue;
                const handler_type = stringField(handler_value.object, "type") orelse continue;
                if (!std.mem.eql(u8, handler_type, "command")) continue;
                try appendCommaIfNeeded(allocator, out, &count);
                const key = try std.fmt.allocPrint(
                    allocator,
                    "{s}:hooks/hooks.json:{s}:{}:{}",
                    .{ plugin_id, event.key_label, group_index, handler_index },
                );
                defer allocator.free(key);
                const key_json = try jsonString(allocator, key);
                defer allocator.free(key_json);
                const event_json = try jsonString(allocator, event.json_label);
                defer allocator.free(event_json);
                try out.appendSlice(allocator, "{\"key\":");
                try out.appendSlice(allocator, key_json);
                try out.appendSlice(allocator, ",\"eventName\":");
                try out.appendSlice(allocator, event_json);
                try out.appendSlice(allocator, "}");
            }
        }
    }
    try out.appendSlice(allocator, "]");
}

fn collectAppsForRoot(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    root: []const u8,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    apps: *std.ArrayList(AppListEntry),
) !void {
    for (MARKETPLACE_MANIFEST_RELATIVE_PATHS) |relative_path| {
        const marketplace_path = try std.fs.path.join(allocator, &.{ root, relative_path });
        defer allocator.free(marketplace_path);
        try collectAppsFromMarketplaceFile(allocator, config_bytes, marketplace_path, enabled_ids, seen_plugin_ids, apps);
    }
}

fn collectAppsFromEnabledPluginCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    apps: *std.ArrayList(AppListEntry),
) !void {
    for (enabled_ids) |plugin_id| {
        if (containsString(seen_plugin_ids.items, plugin_id)) continue;
        const parts = plugin_config.splitPluginId(plugin_id) orelse continue;
        const plugin_base_root = (try plugin_config.localPluginBaseRoot(allocator, codex_home, plugin_id)) orelse continue;
        defer allocator.free(plugin_base_root);
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.openDirAbsolute(io, plugin_base_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close(io);

        var added = false;
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const plugin_root = try std.fs.path.join(allocator, &.{ plugin_base_root, entry.name });
            defer allocator.free(plugin_root);

            var manifest_parse: ?std.json.Parsed(std.json.Value) = null;
            defer if (manifest_parse) |*parsed| parsed.deinit();
            var manifest_bytes: ?[]const u8 = null;
            defer if (manifest_bytes) |bytes| allocator.free(bytes);
            manifest_bytes = try readPluginManifestBytes(allocator, plugin_root);
            if (manifest_bytes) |bytes| {
                manifest_parse = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null;
            }
            const manifest_value = if (manifest_parse) |parsed| parsed.value else null;
            const display_name = pluginDisplayName(manifest_value, parts.name);
            added = (try collectAppsFromPluginRoot(allocator, config_bytes, plugin_root, display_name, apps)) or added;
        }
        if (added) {
            try appendSeenPluginId(allocator, seen_plugin_ids, plugin_id);
        }
    }
}

fn collectAppsFromMarketplaceFile(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    marketplace_path: []const u8,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    apps: *std.ArrayList(AppListEntry),
) !void {
    const bytes = try readFileOptional(allocator, marketplace_path, 1024 * 1024) orelse return;
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;
    const marketplace_name = stringField(object, "name") orelse return;
    const plugins_value = object.get("plugins") orelse return;
    if (plugins_value != .array) return;

    for (plugins_value.array.items) |plugin_value| {
        try collectAppsFromMarketplaceEntry(allocator, config_bytes, marketplace_path, marketplace_name, plugin_value, enabled_ids, seen_plugin_ids, apps);
    }
}

fn collectAppsFromMarketplaceEntry(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    marketplace_path: []const u8,
    marketplace_name: []const u8,
    plugin_value: std.json.Value,
    enabled_ids: []const []const u8,
    seen_plugin_ids: *std.ArrayList([]const u8),
    apps: *std.ArrayList(AppListEntry),
) !void {
    if (plugin_value != .object) return;
    const object = plugin_value.object;
    const plugin_name = stringField(object, "name") orelse return;
    if (plugin_name.len == 0 or marketplace_name.len == 0) return;

    const plugin_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ plugin_name, marketplace_name });
    if (!containsString(enabled_ids, plugin_id)) {
        allocator.free(plugin_id);
        return;
    }

    const source_value = object.get("source") orelse {
        allocator.free(plugin_id);
        return;
    };
    const source = (renderPluginSource(allocator, marketplace_path, source_value) catch |err| {
        allocator.free(plugin_id);
        return err;
    }) orelse {
        allocator.free(plugin_id);
        return;
    };
    defer source.deinit(allocator);
    const plugin_root = source.plugin_root orelse {
        allocator.free(plugin_id);
        return;
    };

    if (containsString(seen_plugin_ids.items, plugin_id)) {
        allocator.free(plugin_id);
        return;
    }
    seen_plugin_ids.append(allocator, plugin_id) catch |err| {
        allocator.free(plugin_id);
        return err;
    };

    var manifest_parse: ?std.json.Parsed(std.json.Value) = null;
    defer if (manifest_parse) |*parsed| parsed.deinit();
    var manifest_bytes: ?[]const u8 = null;
    defer if (manifest_bytes) |bytes| allocator.free(bytes);
    manifest_bytes = try readPluginManifestBytes(allocator, plugin_root);
    if (manifest_bytes) |bytes| {
        manifest_parse = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null;
    }
    const manifest_value = if (manifest_parse) |parsed| parsed.value else null;
    const display_name = pluginDisplayName(manifest_value, plugin_name);

    _ = try collectAppsFromPluginRoot(allocator, config_bytes, plugin_root, display_name, apps);
}

fn collectAppsFromPluginRoot(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    plugin_root: []const u8,
    plugin_display_name: []const u8,
    apps: *std.ArrayList(AppListEntry),
) !bool {
    const path = try std.fs.path.join(allocator, &.{ plugin_root, ".app.json" });
    defer allocator.free(path);
    const bytes = try readFileOptional(allocator, path, 1024 * 256) orelse return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const apps_value = parsed.value.object.get("apps") orelse parsed.value;
    if (apps_value != .object) return false;

    var added = false;
    var iterator = apps_value.object.iterator();
    while (iterator.next()) |entry| {
        const fallback_id = entry.key_ptr.*;
        const app_object = if (entry.value_ptr.* == .object) entry.value_ptr.object else null;
        const app_id = stringFieldOpt(app_object, "id") orelse fallback_id;
        if (app_id.len == 0 or app_id[0] == '$') continue;
        const name = stringFieldOpt(app_object, "name") orelse app_id;
        const description = stringFieldOpt(app_object, "description");
        const raw_install_url = stringFieldOpt(app_object, "installUrl") orelse stringFieldOpt(app_object, "install_url");
        const default_install_url = try std.fmt.allocPrint(allocator, "https://chatgpt.com/apps/{s}/{s}", .{ app_id, app_id });
        defer allocator.free(default_install_url);
        const install_url = raw_install_url orelse default_install_url;
        try upsertAppListEntry(allocator, apps, app_id, name, description, install_url, plugin_display_name, appEnabledFromConfig(config_bytes, app_id));
        added = true;
    }
    return added;
}

fn pluginDisplayName(manifest_value: ?std.json.Value, fallback: []const u8) []const u8 {
    const interface_value = pluginManifestInterfaceValue(manifest_value) orelse return fallback;
    return stringField(interface_value.object, "displayName") orelse fallback;
}

fn upsertAppListEntry(
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(AppListEntry),
    app_id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    install_url: ?[]const u8,
    plugin_display_name: []const u8,
    is_enabled: bool,
) !void {
    for (apps.items) |*app| {
        if (!std.mem.eql(u8, app.id, app_id)) continue;
        if (std.mem.eql(u8, app.name, app.id) and !std.mem.eql(u8, name, app_id)) {
            const updated_name = try allocator.dupe(u8, name);
            allocator.free(app.name);
            app.name = updated_name;
        }
        if (app.description == null and description != null) {
            app.description = try allocator.dupe(u8, description.?);
        }
        if (app.install_url == null and install_url != null) {
            app.install_url = try allocator.dupe(u8, install_url.?);
        }
        app.is_enabled = app.is_enabled and is_enabled;
        try appendUniquePluginDisplayName(allocator, &app.plugin_display_names, plugin_display_name);
        return;
    }

    var owned_id: ?[]const u8 = try allocator.dupe(u8, app_id);
    errdefer if (owned_id) |value| allocator.free(value);
    var owned_name: ?[]const u8 = try allocator.dupe(u8, name);
    errdefer if (owned_name) |value| allocator.free(value);
    var owned_description: ?[]const u8 = if (description) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_description) |value| allocator.free(value);
    var owned_install_url: ?[]const u8 = if (install_url) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_install_url) |value| allocator.free(value);

    var app = AppListEntry{
        .id = owned_id.?,
        .name = owned_name.?,
        .description = owned_description,
        .install_url = owned_install_url,
        .is_enabled = is_enabled,
        .plugin_display_names = .empty,
    };
    owned_id = null;
    owned_name = null;
    owned_description = null;
    owned_install_url = null;
    errdefer app.deinit(allocator);
    try appendUniquePluginDisplayName(allocator, &app.plugin_display_names, plugin_display_name);
    try apps.append(allocator, app);
}

fn appendUniquePluginDisplayName(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), value: []const u8) !void {
    if (value.len == 0) return;
    if (containsString(names.items, value)) return;
    var owned: ?[]const u8 = try allocator.dupe(u8, value);
    errdefer if (owned) |name| allocator.free(name);
    try names.append(allocator, owned.?);
    owned = null;
}

fn appendSeenPluginId(allocator: std.mem.Allocator, seen_plugin_ids: *std.ArrayList([]const u8), plugin_id: []const u8) !void {
    var owned: ?[]const u8 = try allocator.dupe(u8, plugin_id);
    errdefer if (owned) |value| allocator.free(value);
    try seen_plugin_ids.append(allocator, owned.?);
    owned = null;
}

fn appEnabledFromConfig(config_bytes: []const u8, app_id: []const u8) bool {
    var table: AppConfigTable = .none;
    var default_enabled: ?bool = null;
    var app_enabled: ?bool = null;

    var lines = std.mem.splitScalar(u8, config_bytes, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            table = appConfigTableForLine(line, app_id);
            continue;
        }
        const enabled = appConfigBoolValueForKey(line, "enabled") orelse continue;
        switch (table) {
            .default => default_enabled = enabled,
            .target => app_enabled = enabled,
            .none => {},
        }
    }

    return app_enabled orelse default_enabled orelse true;
}

const AppConfigTable = enum {
    none,
    default,
    target,
};

fn appConfigTableForLine(line: []const u8, app_id: []const u8) AppConfigTable {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return .none;
    if (line.len >= 4 and line[1] == '[') return .none;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    if (std.mem.eql(u8, inner, "apps._default")) return .default;
    const prefix = "apps.";
    if (!std.mem.startsWith(u8, inner, prefix)) return .none;
    const suffix = inner[prefix.len..];
    if (suffix.len >= 2 and suffix[0] == '"' and suffix[suffix.len - 1] == '"') {
        const quoted = suffix[1 .. suffix.len - 1];
        return if (std.mem.eql(u8, quoted, app_id)) .target else .none;
    }
    if (std.mem.indexOfScalar(u8, suffix, '.') != null) return .none;
    return if (std.mem.eql(u8, suffix, app_id)) .target else .none;
}

fn appConfigBoolValueForKey(line: []const u8, key: []const u8) ?bool {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, rhs, "true")) return true;
    if (std.mem.eql(u8, rhs, "false")) return false;
    return null;
}

fn appendAppListEntryJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), app: AppListEntry) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, out, app.id);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, app.name);
    try out.appendSlice(allocator, ",\"description\":");
    try appendOptionalStringJson(allocator, out, app.description);
    try out.appendSlice(allocator, ",\"logoUrl\":null,\"logoUrlDark\":null,\"distributionChannel\":null,\"branding\":null,\"appMetadata\":null,\"labels\":null,\"installUrl\":");
    try appendOptionalStringJson(allocator, out, app.install_url);
    try out.appendSlice(allocator, ",\"isAccessible\":false,\"isEnabled\":");
    try appendBool(allocator, out, app.is_enabled);
    try out.appendSlice(allocator, ",\"pluginDisplayNames\":[");
    for (app.plugin_display_names.items, 0..) |name, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendJsonString(allocator, out, name);
    }
    try out.appendSlice(allocator, "]}");
}

fn appListEntryLessThan(_: void, left: AppListEntry, right: AppListEntry) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order != .eq) return name_order == .lt;
    return std.mem.lessThan(u8, left.id, right.id);
}

fn appListStringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn appendPluginAppsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), plugin_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ plugin_root, ".app.json" });
    defer allocator.free(path);
    const bytes = try readFileOptional(allocator, path, 1024 * 256) orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    const apps_value = parsed.value.object.get("apps") orelse parsed.value;
    if (apps_value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }

    try out.appendSlice(allocator, "[");
    var iterator = apps_value.object.iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        const fallback_id = entry.key_ptr.*;
        const app_object = if (entry.value_ptr.* == .object) entry.value_ptr.object else null;
        const app_id = stringFieldOpt(app_object, "id") orelse fallback_id;
        if (app_id.len == 0 or app_id[0] == '$') continue;
        const name = stringFieldOpt(app_object, "name") orelse app_id;
        const description = stringFieldOpt(app_object, "description");
        const install_url = stringFieldOpt(app_object, "installUrl") orelse stringFieldOpt(app_object, "install_url");
        try appendCommaIfNeeded(allocator, out, &count);
        try appendPluginAppSummaryJson(allocator, out, app_id, name, description, install_url);
    }
    try out.appendSlice(allocator, "]");
}

fn appendPluginAppSummaryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    app_id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    install_url: ?[]const u8,
) !void {
    const id_json = try jsonString(allocator, app_id);
    defer allocator.free(id_json);
    const name_json = try jsonString(allocator, name);
    defer allocator.free(name_json);
    const default_install_url = try std.fmt.allocPrint(allocator, "https://chatgpt.com/apps/{s}/{s}", .{ app_id, app_id });
    defer allocator.free(default_install_url);

    try out.appendSlice(allocator, "{\"id\":");
    try out.appendSlice(allocator, id_json);
    try out.appendSlice(allocator, ",\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try appendOptionalStringJson(allocator, out, description);
    try out.appendSlice(allocator, ",\"installUrl\":");
    try appendOptionalStringJson(allocator, out, install_url orelse default_install_url);
    try out.appendSlice(allocator, ",\"needsAuth\":true}");
}

fn appendPluginMcpServerNamesJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), plugin_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ plugin_root, ".mcp.json" });
    defer allocator.free(path);
    const bytes = try readFileOptional(allocator, path, 1024 * 256) orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try out.appendSlice(allocator, "[]");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    const servers_value = parsed.value.object.get("mcpServers") orelse parsed.value;
    if (servers_value != .object) {
        try out.appendSlice(allocator, "[]");
        return;
    }

    try out.appendSlice(allocator, "[");
    var iterator = servers_value.object.iterator();
    var count: usize = 0;
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0 or name[0] == '$') continue;
        try appendCommaIfNeeded(allocator, out, &count);
        const name_json = try jsonString(allocator, name);
        defer allocator.free(name_json);
        try out.appendSlice(allocator, name_json);
    }
    try out.appendSlice(allocator, "]");
}

fn pluginNamePrefix(manifest_object: std.json.ObjectMap, plugin_root: []const u8) []const u8 {
    if (stringField(manifest_object, "name")) |name| {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return std.fs.path.basename(plugin_root);
}

fn readPluginManifestBytes(allocator: std.mem.Allocator, plugin_root: []const u8) !?[]const u8 {
    const codex_path = try std.fs.path.join(allocator, &.{ plugin_root, ".codex-plugin", "plugin.json" });
    defer allocator.free(codex_path);
    if (try readFileOptional(allocator, codex_path, 1024 * 1024)) |bytes| return bytes;

    const claude_path = try std.fs.path.join(allocator, &.{ plugin_root, ".claude-plugin", "plugin.json" });
    defer allocator.free(claude_path);
    return readFileOptional(allocator, claude_path, 1024 * 1024);
}

fn installedPluginExists(allocator: std.mem.Allocator, codex_home: []const u8, marketplace_name: []const u8, plugin_name: []const u8) !bool {
    const plugin_root = try std.fs.path.join(allocator, &.{
        codex_home,
        "plugins",
        "cache",
        marketplace_name,
        plugin_name,
    });
    defer allocator.free(plugin_root);
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, plugin_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const version_root = try std.fs.path.join(allocator, &.{ plugin_root, entry.name });
        defer allocator.free(version_root);
        if (try readPluginManifestBytes(allocator, version_root)) |bytes| {
            allocator.free(bytes);
            return true;
        }
    }
    return false;
}

fn readFileOptional(allocator: std.mem.Allocator, path: []const u8, limit: usize) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
}

fn appendMarketplaceLoadError(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    count: *usize,
    marketplace_path: []const u8,
    message: []const u8,
) !void {
    try appendCommaIfNeeded(allocator, out, count);
    const path_json = try jsonString(allocator, marketplace_path);
    defer allocator.free(path_json);
    const message_json = try jsonString(allocator, message);
    defer allocator.free(message_json);
    try out.appendSlice(allocator, "{\"marketplacePath\":");
    try out.appendSlice(allocator, path_json);
    try out.appendSlice(allocator, ",\"message\":");
    try out.appendSlice(allocator, message_json);
    try out.appendSlice(allocator, "}");
}

fn appendCommaIfNeeded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: *usize) !void {
    if (count.* > 0) try out.appendSlice(allocator, ",");
    count.* += 1;
}

fn installPolicy(policy_value: ?std.json.Value) []const u8 {
    const policy_object = policyObject(policy_value) orelse return "AVAILABLE";
    const value = stringField(policy_object, "installation") orelse return "AVAILABLE";
    if (std.mem.eql(u8, value, "NOT_AVAILABLE")) return "NOT_AVAILABLE";
    if (std.mem.eql(u8, value, "INSTALLED_BY_DEFAULT")) return "INSTALLED_BY_DEFAULT";
    return "AVAILABLE";
}

fn authPolicy(policy_value: ?std.json.Value) []const u8 {
    const policy_object = policyObject(policy_value) orelse return "ON_INSTALL";
    const value = stringField(policy_object, "authentication") orelse return "ON_INSTALL";
    if (std.mem.eql(u8, value, "ON_USE")) return "ON_USE";
    return "ON_INSTALL";
}

fn renderInstallResponseJson(allocator: std.mem.Allocator, auth_policy: []const u8) ![]const u8 {
    const auth_policy_json = try jsonString(allocator, auth_policy);
    defer allocator.free(auth_policy_json);
    return std.fmt.allocPrint(allocator, "{{\"authPolicy\":{s},\"appsNeedingAuth\":[]}}", .{auth_policy_json});
}

fn pluginVersionForManifest(object: std.json.ObjectMap) ![]const u8 {
    const value = object.get("version") orelse return "local";
    if (value == .null) return "local";
    if (value != .string) return InstallError.InvalidPluginVersion;
    const version = std.mem.trim(u8, value.string, " \t\r\n");
    if (!isValidPluginVersion(version)) return InstallError.InvalidPluginVersion;
    return version;
}

fn isValidPluginVersion(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '+') continue;
        return false;
    }
    return true;
}

fn replaceLocalPluginCache(allocator: std.mem.Allocator, source_root: []const u8, plugin_base_root: []const u8, installed_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const plugin_version = std.fs.path.basename(installed_path);
    const staged_base_root = try std.fmt.allocPrint(allocator, "{s}.installing", .{plugin_base_root});
    defer allocator.free(staged_base_root);
    const backup_base_root = try std.fmt.allocPrint(allocator, "{s}.previous", .{plugin_base_root});
    defer allocator.free(backup_base_root);
    const staged_installed_path = try std.fs.path.join(allocator, &.{ staged_base_root, plugin_version });
    defer allocator.free(staged_installed_path);

    try deletePathIfPresent(staged_base_root);
    try deletePathIfPresent(backup_base_root);
    errdefer deletePathIfPresent(staged_base_root) catch {};

    try copyDirRecursive(allocator, source_root, staged_installed_path);
    const had_existing = try renamePathIfPresent(plugin_base_root, backup_base_root);
    std.Io.Dir.renameAbsolute(staged_base_root, plugin_base_root, io) catch |err| {
        if (had_existing) {
            std.Io.Dir.renameAbsolute(backup_base_root, plugin_base_root, io) catch {};
        }
        return err;
    };
    if (had_existing) deletePathIfPresent(backup_base_root) catch {};
}

fn copyDirRecursive(allocator: std.mem.Allocator, source_root: []const u8, target_root: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, target_root);

    var source_dir = try std.Io.Dir.openDirAbsolute(io, source_root, .{ .iterate = true });
    defer source_dir.close(io);

    var iter = source_dir.iterate();
    while (try iter.next(io)) |entry| {
        const source_path = try std.fs.path.join(allocator, &.{ source_root, entry.name });
        defer allocator.free(source_path);
        const target_path = try std.fs.path.join(allocator, &.{ target_root, entry.name });
        defer allocator.free(target_path);

        if (entry.kind == .directory) {
            try copyDirRecursive(allocator, source_path, target_path);
        } else if (entry.kind == .file) {
            try std.Io.Dir.copyFileAbsolute(source_path, target_path, io, .{});
        }
    }
}

fn renamePathIfPresent(old_path: []const u8, new_path: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.renameAbsolute(old_path, new_path, io) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn deletePathIfPresent(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .directory) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    } else {
        try std.Io.Dir.deleteFileAbsolute(io, path);
    }
}

fn policyObject(policy_value: ?std.json.Value) ?std.json.ObjectMap {
    const value = policy_value orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn appendNamedOptionalString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const name_json = try jsonString(allocator, name);
    defer allocator.free(name_json);
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ":");
    try appendOptionalStringJson(allocator, out, value);
}

fn appendOptionalStringJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |string| {
        const value_json = try jsonString(allocator, string);
        defer allocator.free(value_json);
        try out.appendSlice(allocator, value_json);
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendStringArrayValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value_opt: ?std.json.Value) !void {
    const value = value_opt orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    if (value != .array) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    try out.appendSlice(allocator, "[");
    var count: usize = 0;
    for (value.array.items) |item| {
        if (item != .string) continue;
        try appendCommaIfNeeded(allocator, out, &count);
        const item_json = try jsonString(allocator, item.string);
        defer allocator.free(item_json);
        try out.appendSlice(allocator, item_json);
    }
    try out.appendSlice(allocator, "]");
}

fn appendDefaultPromptJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value_opt: ?std.json.Value) !void {
    const value = value_opt orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    if (value == .string) {
        try out.appendSlice(allocator, "[");
        const prompt_json = try jsonString(allocator, value.string);
        defer allocator.free(prompt_json);
        try out.appendSlice(allocator, prompt_json);
        try out.appendSlice(allocator, "]");
        return;
    }
    if (value != .array) {
        try out.appendSlice(allocator, "null");
        return;
    }
    try out.appendSlice(allocator, "[");
    var count: usize = 0;
    for (value.array.items) |item| {
        if (item == .string) {
            try appendCommaIfNeeded(allocator, out, &count);
            const prompt_json = try jsonString(allocator, item.string);
            defer allocator.free(prompt_json);
            try out.appendSlice(allocator, prompt_json);
        } else if (item == .object) {
            const prompt = stringField(item.object, "prompt") orelse stringField(item.object, "text") orelse continue;
            try appendCommaIfNeeded(allocator, out, &count);
            const prompt_json = try jsonString(allocator, prompt);
            defer allocator.free(prompt_json);
            try out.appendSlice(allocator, prompt_json);
        }
    }
    try out.appendSlice(allocator, "]");
}

fn appendAssetPathJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), plugin_root: ?[]const u8, value: ?[]const u8) !void {
    const root = plugin_root orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    const raw = value orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    const path = (try resolveManifestAssetPath(allocator, root, raw)) orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    defer allocator.free(path);
    const path_json = try jsonString(allocator, path);
    defer allocator.free(path_json);
    try out.appendSlice(allocator, path_json);
}

fn appendAssetArrayJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), plugin_root: ?[]const u8, value_opt: ?std.json.Value) !void {
    const root = plugin_root orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    const value = value_opt orelse {
        try out.appendSlice(allocator, "[]");
        return;
    };
    if (value != .array) {
        try out.appendSlice(allocator, "[]");
        return;
    }
    try out.appendSlice(allocator, "[");
    var count: usize = 0;
    for (value.array.items) |item| {
        if (item != .string) continue;
        const path = (try resolveManifestAssetPath(allocator, root, item.string)) orelse continue;
        defer allocator.free(path);
        try appendCommaIfNeeded(allocator, out, &count);
        const path_json = try jsonString(allocator, path);
        defer allocator.free(path_json);
        try out.appendSlice(allocator, path_json);
    }
    try out.appendSlice(allocator, "]");
}

fn resolveManifestAssetPath(allocator: std.mem.Allocator, plugin_root: []const u8, raw_path: []const u8) !?[]const u8 {
    const stripped = std.mem.trim(u8, raw_path, " \t\r\n");
    if (!std.mem.startsWith(u8, stripped, "./")) return null;
    const relative = stripped[2..];
    if (relative.len == 0 or !isSafeRelativePath(relative)) return null;
    const resolved = try std.fs.path.join(allocator, &.{ plugin_root, relative });
    return resolved;
}

fn defaultPromptHasStrings(value_opt: ?std.json.Value) bool {
    const value = value_opt orelse return false;
    if (value == .string) return true;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string) return true;
        if (item == .object and (stringField(item.object, "prompt") != null or stringField(item.object, "text") != null)) return true;
    }
    return false;
}

fn stringArrayHasStrings(value_opt: ?std.json.Value) bool {
    const value = value_opt orelse return false;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string) return true;
    }
    return false;
}

fn valueFieldOpt(object_opt: ?std.json.ObjectMap, field: []const u8) ?std.json.Value {
    const object = object_opt orelse return null;
    return object.get(field);
}

fn stringFieldOpt(object_opt: ?std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const object = object_opt orelse return null;
    return stringField(object, field);
}

fn stringFieldAliasOpt(object_opt: ?std.json.ObjectMap, field: []const u8, alias: []const u8) ?[]const u8 {
    const object = object_opt orelse return null;
    return stringFieldAlias(object, field, alias);
}

fn stringFieldAlias(object: std.json.ObjectMap, field: []const u8, alias: []const u8) ?[]const u8 {
    return stringField(object, field) orelse stringField(object, alias);
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.appendSlice(allocator, if (value) "true" else "false");
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try jsonString(allocator, value);
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn optionalJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    if (value) |string| return jsonString(allocator, string);
    return allocator.dupe(u8, "null");
}

test "plugin list renders local marketplaces with installed state and manifest metadata" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home/plugins/cache/codex-curated/enabled-plugin/local/.codex-plugin");
    try dir.dir.createDirPath(io, "repo/.agents/plugins");
    try dir.dir.createDirPath(io, "repo/plugins/enabled-plugin/.codex-plugin");
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/plugins/cache/codex-curated/enabled-plugin/local/.codex-plugin/plugin.json",
        .data = "{\"name\":\"enabled-plugin\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/.agents/plugins/marketplace.json",
        .data =
        \\{
        \\  "name": "codex-curated",
        \\  "interface": {"displayName": "ChatGPT Official"},
        \\  "plugins": [
        \\    {
        \\      "name": "enabled-plugin",
        \\      "source": {"source": "local", "path": "./plugins/enabled-plugin"},
        \\      "category": "Design"
        \\    }
        \\  ]
        \\}
        ,
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/plugins/enabled-plugin/.codex-plugin/plugin.json",
        .data =
        \\{
        \\  "name": "enabled-plugin",
        \\  "keywords": ["api-key", "developer tools"],
        \\  "interface": {
        \\    "displayName": "Enabled Plugin",
        \\    "shortDescription": "Short plugin description",
        \\    "capabilities": ["Write"],
        \\    "defaultPrompt": "Try this plugin"
        \\  }
        \\}
        ,
    });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const config_bytes =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."enabled-plugin@codex-curated"]
        \\enabled = true
    ;

    const response = try renderResponse(allocator, codex_home, config_bytes, &.{repo}, true);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"codex-curated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"displayName\":\"ChatGPT Official\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"enabled-plugin@codex-curated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"installed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"category\":\"Design\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"keywords\":[\"api-key\",\"developer tools\"]") != null);

    const marketplace_path = try std.fs.path.join(allocator, &.{ repo, ".agents", "plugins", "marketplace.json" });
    defer allocator.free(marketplace_path);
    const read_response = try renderReadResponse(allocator, codex_home, config_bytes, marketplace_path, "enabled-plugin");
    defer allocator.free(read_response);
    try std.testing.expect(std.mem.indexOf(u8, read_response, "\"marketplaceName\":\"codex-curated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_response, "\"summary\":{\"id\":\"enabled-plugin@codex-curated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_response, "\"description\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_response, "\"skills\":[]") != null);
}

test "plugin list reports invalid marketplace files and honors plugins feature flag" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home");
    try dir.dir.createDirPath(io, "repo/.agents/plugins");
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/.agents/plugins/marketplace.json",
        .data = "{not json",
    });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);

    const response = try renderResponse(allocator, codex_home, "[features]\nplugins = true\n", &.{repo}, true);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"marketplaces\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"marketplaceLoadErrors\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "invalid marketplace file") != null);

    const disabled = try renderResponse(allocator, codex_home, "[features]\nplugins = false\n", &.{repo}, true);
    defer allocator.free(disabled);
    try std.testing.expectEqualStrings("{\"marketplaces\":[],\"marketplaceLoadErrors\":[],\"featuredPluginIds\":[]}", disabled);
}

test "plugin install copies local source and enables config" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home");
    try dir.dir.createDirPath(io, "repo/.agents/plugins");
    try dir.dir.createDirPath(io, "repo/plugins/sample-plugin/.codex-plugin");
    try dir.dir.createDirPath(io, "repo/plugins/sample-plugin/skills/example");
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/.agents/plugins/marketplace.json",
        .data =
        \\{
        \\  "name": "debug",
        \\  "plugins": [
        \\    {
        \\      "name": "sample-plugin",
        \\      "source": {"source": "local", "path": "./plugins/sample-plugin"},
        \\      "policy": {"authentication": "ON_USE"}
        \\    }
        \\  ]
        \\}
        ,
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/plugins/sample-plugin/.codex-plugin/plugin.json",
        .data = "{\"name\":\"sample-plugin\",\"version\":\"1.2.3\"}",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "repo/plugins/sample-plugin/skills/example/SKILL.md",
        .data = "# Example\n",
    });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const marketplace_path = try std.fs.path.join(allocator, &.{ root, "repo", ".agents", "plugins", "marketplace.json" });
    defer allocator.free(marketplace_path);

    const installed = try installLocalPlugin(allocator, codex_home, "[features]\nplugins = true\n", marketplace_path, "sample-plugin");
    defer installed.deinit(allocator);
    try std.testing.expectEqualStrings("{\"authPolicy\":\"ON_USE\",\"appsNeedingAuth\":[]}", installed.response_json);
    try std.testing.expect(std.mem.indexOf(u8, installed.updated_config, "[plugins.\"sample-plugin@debug\"]\nenabled = true") != null);
    try std.testing.expect(std.mem.endsWith(u8, installed.installed_path, "plugins/cache/debug/sample-plugin/1.2.3"));

    const copied_manifest = try std.fs.path.join(allocator, &.{ installed.installed_path, ".codex-plugin", "plugin.json" });
    defer allocator.free(copied_manifest);
    const copied_skill = try std.fs.path.join(allocator, &.{ installed.installed_path, "skills", "example", "SKILL.md" });
    defer allocator.free(copied_skill);
    _ = try std.Io.Dir.cwd().statFile(io, copied_manifest, .{});
    _ = try std.Io.Dir.cwd().statFile(io, copied_skill, .{});

    const repo_root = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo_root);
    const listed = try renderResponse(allocator, codex_home, installed.updated_config, &.{repo_root}, true);
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"id\":\"sample-plugin@debug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"installed\":true") != null);
}

test "plugin install cache replacement keeps existing cache when staging fails" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home/plugins/cache/debug/sample-plugin/local");
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/plugins/cache/debug/sample-plugin/local/old.txt",
        .data = "old",
    });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const missing_source = try std.fs.path.join(allocator, &.{ root, "missing-source" });
    defer allocator.free(missing_source);
    const plugin_base_root = try std.fs.path.join(allocator, &.{ root, "codex-home", "plugins", "cache", "debug", "sample-plugin" });
    defer allocator.free(plugin_base_root);
    const installed_path = try std.fs.path.join(allocator, &.{ plugin_base_root, "1.2.3" });
    defer allocator.free(installed_path);

    var failed = false;
    replaceLocalPluginCache(allocator, missing_source, plugin_base_root, installed_path) catch {
        failed = true;
    };
    try std.testing.expect(failed);

    const old_path = try std.fs.path.join(allocator, &.{ plugin_base_root, "local", "old.txt" });
    defer allocator.free(old_path);
    const old = try std.Io.Dir.cwd().readFileAlloc(io, old_path, allocator, .limited(16));
    defer allocator.free(old);
    try std.testing.expectEqualStrings("old", old);
}
