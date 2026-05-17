const std = @import("std");

pub const PluginIdParts = struct {
    name: []const u8,
    marketplace: []const u8,
};

pub fn featureEnabled(bytes: []const u8, key: []const u8, default_enabled: bool) bool {
    var in_features = false;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_features = std.mem.eql(u8, line, "[features]");
            continue;
        }
        if (!in_features) continue;
        if (tomlBoolValueForKey(line, key)) |value| return value;
    }
    return default_enabled;
}

pub fn pluginsFeatureEnabled(bytes: []const u8) bool {
    return featureEnabled(bytes, "plugins", true);
}

pub fn pluginHooksFeatureEnabled(bytes: []const u8) bool {
    return featureEnabled(bytes, "plugin_hooks", false);
}

pub fn remotePluginFeatureEnabled(bytes: []const u8) bool {
    return featureEnabled(bytes, "remote_plugin", false);
}

pub fn enabledPluginIds(allocator: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var ids = std.ArrayList([]const u8).empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var current_plugin_id: ?[]const u8 = null;
    var current_enabled = false;
    errdefer if (current_plugin_id) |id| allocator.free(id);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            try flushEnabledPluginId(allocator, &ids, &current_plugin_id, current_enabled);
            current_enabled = false;
            current_plugin_id = try parsePluginTableHeader(allocator, line);
            continue;
        }
        if (current_plugin_id != null) {
            if (tomlBoolValueForKey(line, "enabled")) |enabled| current_enabled = enabled;
        }
    }
    try flushEnabledPluginId(allocator, &ids, &current_plugin_id, current_enabled);

    return ids.toOwnedSlice(allocator);
}

pub fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn splitPluginId(plugin_id: []const u8) ?PluginIdParts {
    const at_index = std.mem.lastIndexOfScalar(u8, plugin_id, '@') orelse return null;
    if (at_index == 0 or at_index + 1 >= plugin_id.len) return null;
    return .{
        .name = plugin_id[0..at_index],
        .marketplace = plugin_id[at_index + 1 ..],
    };
}

pub fn isValidPluginId(plugin_id: []const u8) bool {
    const parts = splitPluginId(plugin_id) orelse return false;
    return isValidPluginSegment(parts.name) and isValidPluginSegment(parts.marketplace);
}

pub fn isValidPluginSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

pub fn localPluginRoot(allocator: std.mem.Allocator, codex_home: []const u8, plugin_id: []const u8) !?[]const u8 {
    const parts = splitPluginId(plugin_id) orelse return null;
    return try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", parts.marketplace, parts.name, "local" });
}

pub fn localPluginBaseRoot(allocator: std.mem.Allocator, codex_home: []const u8, plugin_id: []const u8) !?[]const u8 {
    const parts = splitPluginId(plugin_id) orelse return null;
    return try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", parts.marketplace, parts.name });
}

pub fn localPluginDataRoot(allocator: std.mem.Allocator, codex_home: []const u8, plugin_id: []const u8) !?[]const u8 {
    const parts = splitPluginId(plugin_id) orelse return null;
    const leaf = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ parts.name, parts.marketplace });
    defer allocator.free(leaf);
    return try std.fs.path.join(allocator, &.{ codex_home, "plugins", "data", leaf });
}

pub fn removePluginConfig(allocator: std.mem.Allocator, bytes: []const u8, plugin_id: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var skipping_plugin_table = false;
    var removed_plugin_table = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (isTomlTableHeader(trimmed)) {
            skipping_plugin_table = try tableHeaderBelongsToPlugin(allocator, trimmed, plugin_id);
            removed_plugin_table = removed_plugin_table or skipping_plugin_table;
        }
        if (skipping_plugin_table) continue;

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    if (!removed_plugin_table) {
        output.deinit(allocator);
        return allocator.dupe(u8, bytes);
    }
    return output.toOwnedSlice(allocator);
}

pub fn upsertEnabledPluginConfig(allocator: std.mem.Allocator, bytes: []const u8, plugin_id: []const u8) ![]const u8 {
    if (!isValidPluginId(plugin_id)) return error.InvalidPluginId;

    const without_plugin = try removePluginConfig(allocator, bytes, plugin_id);
    defer allocator.free(without_plugin);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, std.mem.trimEnd(u8, without_plugin, " \t\r\n"));
    if (output.items.len > 0) try output.appendSlice(allocator, "\n\n");
    try output.appendSlice(allocator, "[plugins.\"");
    try output.appendSlice(allocator, plugin_id);
    try output.appendSlice(allocator, "\"]\n");
    try output.appendSlice(allocator, "enabled = true\n");
    return output.toOwnedSlice(allocator);
}

fn flushEnabledPluginId(
    allocator: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    current_plugin_id: *?[]const u8,
    current_enabled: bool,
) !void {
    const plugin_id = current_plugin_id.* orelse return;
    current_plugin_id.* = null;
    if (current_enabled) {
        try ids.append(allocator, plugin_id);
    } else {
        allocator.free(plugin_id);
    }
}

fn parsePluginTableHeader(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    const prefix = "plugins.";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    var index: usize = prefix.len;
    const plugin_id = (try parseTomlStringAt(allocator, inner, &index)) orelse return null;
    errdefer allocator.free(plugin_id);
    skipTomlWhitespace(inner, &index);
    if (index != inner.len) {
        allocator.free(plugin_id);
        return null;
    }
    return plugin_id;
}

fn isTomlTableHeader(line: []const u8) bool {
    return line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']';
}

fn tableHeaderBelongsToPlugin(allocator: std.mem.Allocator, line: []const u8, plugin_id: []const u8) !bool {
    if (!isTomlTableHeader(line)) return false;
    if (line.len >= 4 and line[1] == '[') return false;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    const prefix = "plugins.";
    if (!std.mem.startsWith(u8, inner, prefix)) return false;

    var index: usize = prefix.len;
    const table_plugin_id = (try parseTomlStringAt(allocator, inner, &index)) orelse return false;
    defer allocator.free(table_plugin_id);
    if (!std.mem.eql(u8, table_plugin_id, plugin_id)) return false;

    skipTomlWhitespace(inner, &index);
    return index == inner.len or inner[index] == '.';
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

fn skipTomlWhitespace(raw: []const u8, index: *usize) void {
    while (index.* < raw.len and (raw[index.*] == ' ' or raw[index.*] == '\t' or raw[index.*] == '\r' or raw[index.*] == '\n')) : (index.* += 1) {}
}

test "plugin config parses enabled plugin ids and feature flags" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[features]
        \\plugins = true
        \\plugin_hooks = true
        \\
        \\[plugins."demo@test"]
        \\enabled = true
        \\
        \\[plugins."disabled@test"]
        \\enabled = false
        \\
        \\[plugins."later@test"]
        \\enabled = true
    ;

    try std.testing.expect(pluginsFeatureEnabled(bytes));
    try std.testing.expect(pluginHooksFeatureEnabled(bytes));
    const ids = try enabledPluginIds(allocator, bytes);
    defer freeStringList(allocator, ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("demo@test", ids[0]);
    try std.testing.expectEqualStrings("later@test", ids[1]);
    const parts = splitPluginId(ids[0]).?;
    try std.testing.expectEqualStrings("demo", parts.name);
    try std.testing.expectEqualStrings("test", parts.marketplace);
    try std.testing.expect(isValidPluginId("demo@test"));
    try std.testing.expect(!isValidPluginId("demo/../../oops@test"));
    const data_root = (try localPluginDataRoot(allocator, "/tmp/codex-home", "demo@test")).?;
    defer allocator.free(data_root);
    try std.testing.expectEqualStrings("/tmp/codex-home/plugins/data/demo-test", data_root);
}

test "plugin config removal drops plugin table and child tables" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."demo@test"]
        \\enabled = true
        \\source = "/tmp/demo"
        \\
        \\[plugins."demo@test".mcp_servers.sample]
        \\command = "demo-mcp"
        \\
        \\[plugins."other@test"]
        \\enabled = true
    ;

    const updated = try removePluginConfig(allocator, bytes, "demo@test");
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[plugins.\"demo@test\"]") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[plugins.\"demo@test\".mcp_servers.sample]") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[plugins.\"other@test\"]") != null);

    const unchanged = try removePluginConfig(allocator, "profile = \"work\"", "missing@test");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("profile = \"work\"", unchanged);
}

test "plugin config upsert enables plugin table" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."demo@test"]
        \\enabled = false
        \\
        \\[plugins."demo@test".mcp_servers.sample]
        \\command = "demo-mcp"
    ;

    const updated = try upsertEnabledPluginConfig(allocator, bytes, "demo@test");
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[plugins.\"demo@test\".mcp_servers.sample]") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[plugins.\"demo@test\"]\nenabled = true") != null);
}
