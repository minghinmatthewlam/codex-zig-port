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
    return featureEnabled(bytes, "plugin_hooks", true);
}

pub fn remotePluginFeatureEnabled(bytes: []const u8) bool {
    return featureEnabled(bytes, "remote_plugin", false);
}

pub fn pluginSharingFeatureEnabled(bytes: []const u8) bool {
    return featureEnabled(bytes, "plugin_sharing", false);
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

pub fn configuredPluginIds(allocator: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var ids = std.ArrayList([]const u8).empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != '[') continue;
        if (try parsePluginTableHeader(allocator, line)) |id| {
            try ids.append(allocator, id);
        }
    }

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
    const plugin_base_root = (try localPluginBaseRoot(allocator, codex_home, plugin_id)) orelse return null;
    defer allocator.free(plugin_base_root);

    const active_version = try activePluginVersion(allocator, plugin_base_root);
    defer if (active_version) |version| allocator.free(version);

    return try std.fs.path.join(allocator, &.{ plugin_base_root, active_version orelse "local" });
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

pub fn pluginDisplayNameForRoot(allocator: std.mem.Allocator, plugin_root: []const u8, plugin_id: []const u8) ![]const u8 {
    if (try pluginManifestDisplayName(allocator, plugin_root, ".codex-plugin")) |name| return name;
    if (try pluginManifestDisplayName(allocator, plugin_root, ".claude-plugin")) |name| return name;
    return pluginSkillNamePrefixForRoot(allocator, plugin_root, plugin_id);
}

pub fn pluginSkillNamePrefixForRoot(allocator: std.mem.Allocator, plugin_root: []const u8, plugin_id: []const u8) ![]const u8 {
    if (try pluginManifestName(allocator, plugin_root, ".codex-plugin")) |name| return name;
    if (try pluginManifestName(allocator, plugin_root, ".claude-plugin")) |name| return name;
    const parts = splitPluginId(plugin_id) orelse return allocator.dupe(u8, plugin_id);
    return allocator.dupe(u8, parts.name);
}

fn pluginManifestDisplayName(allocator: std.mem.Allocator, plugin_root: []const u8, manifest_dir: []const u8) !?[]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_root, manifest_dir, "plugin.json" });
    defer allocator.free(manifest_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), manifest_path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("interface")) |interface_value| {
        if (interface_value == .object) {
            if (trimmedJsonString(interface_value.object, "displayName")) |value| return try allocator.dupe(u8, value);
        }
    }
    if (trimmedJsonString(parsed.value.object, "name")) |value| return try allocator.dupe(u8, value);
    return null;
}

fn pluginManifestName(allocator: std.mem.Allocator, plugin_root: []const u8, manifest_dir: []const u8) !?[]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_root, manifest_dir, "plugin.json" });
    defer allocator.free(manifest_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), manifest_path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (trimmedJsonString(parsed.value.object, "name")) |value| return try allocator.dupe(u8, value);
    return null;
}

fn trimmedJsonString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn activePluginVersion(allocator: std.mem.Allocator, plugin_base_root: []const u8) !?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = (if (std.fs.path.isAbsolute(plugin_base_root))
        std.Io.Dir.openDirAbsolute(io, plugin_base_root, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, plugin_base_root, .{ .iterate = true })) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var best: ?[]const u8 = null;
    errdefer if (best) |value| allocator.free(value);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!isValidPluginVersionSegment(entry.name)) continue;
        if (std.mem.eql(u8, entry.name, "local")) {
            if (best) |value| allocator.free(value);
            return try allocator.dupe(u8, "local");
        }
        if (best == null or comparePluginVersions(entry.name, best.?) == .gt) {
            if (best) |value| allocator.free(value);
            best = try allocator.dupe(u8, entry.name);
        }
    }

    return best;
}

fn isValidPluginVersionSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '+') continue;
        return false;
    }
    return true;
}

fn comparePluginVersions(a: []const u8, b: []const u8) std.math.Order {
    const parsed_a = parsePluginSemver(a);
    const parsed_b = parsePluginSemver(b);
    if (parsed_a != null and parsed_b != null) return comparePluginSemver(parsed_a.?, parsed_b.?);
    return naturalOrder(a, b);
}

const PluginSemver = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: ?[]const u8,
};

fn parsePluginSemver(value: []const u8) ?PluginSemver {
    const without_build = if (std.mem.indexOfScalar(u8, value, '+')) |index| value[0..index] else value;
    const core = if (std.mem.indexOfScalar(u8, without_build, '-')) |index| without_build[0..index] else without_build;
    const prerelease = if (core.len < without_build.len) without_build[core.len + 1 ..] else null;

    var parts = std.mem.splitScalar(u8, core, '.');
    const major = parsePluginVersionNumber(parts.next() orelse return null) orelse return null;
    const minor = parsePluginVersionNumber(parts.next() orelse return null) orelse return null;
    const patch = parsePluginVersionNumber(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
        .prerelease = prerelease,
    };
}

fn parsePluginVersionNumber(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

fn comparePluginSemver(a: PluginSemver, b: PluginSemver) std.math.Order {
    if (a.major != b.major) return numericOrder(a.major, b.major);
    if (a.minor != b.minor) return numericOrder(a.minor, b.minor);
    if (a.patch != b.patch) return numericOrder(a.patch, b.patch);
    if (a.prerelease == null and b.prerelease == null) return .eq;
    if (a.prerelease == null) return .gt;
    if (b.prerelease == null) return .lt;
    return comparePluginPrerelease(a.prerelease.?, b.prerelease.?);
}

fn comparePluginPrerelease(a: []const u8, b: []const u8) std.math.Order {
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null and b_part == null) return .eq;
        if (a_part == null) return .lt;
        if (b_part == null) return .gt;

        const a_number = parsePluginVersionNumber(a_part.?);
        const b_number = parsePluginVersionNumber(b_part.?);
        const order = if (a_number != null and b_number != null)
            numericOrder(a_number.?, b_number.?)
        else if (a_number != null)
            std.math.Order.lt
        else if (b_number != null)
            std.math.Order.gt
        else
            std.mem.order(u8, a_part.?, b_part.?);
        if (order != .eq) return order;
    }
}

fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (a_index < a.len and b_index < b.len) {
        if (std.ascii.isDigit(a[a_index]) and std.ascii.isDigit(b[b_index])) {
            const a_start = a_index;
            const b_start = b_index;
            while (a_index < a.len and std.ascii.isDigit(a[a_index])) a_index += 1;
            while (b_index < b.len and std.ascii.isDigit(b[b_index])) b_index += 1;
            const order = digitRunOrder(a[a_start..a_index], b[b_start..b_index]);
            if (order != .eq) return order;
            continue;
        }
        if (a[a_index] != b[b_index]) return if (a[a_index] < b[b_index]) .lt else .gt;
        a_index += 1;
        b_index += 1;
    }
    if (a_index == a.len and b_index == b.len) return .eq;
    return if (a_index == a.len) .lt else .gt;
}

fn digitRunOrder(a: []const u8, b: []const u8) std.math.Order {
    const a_trimmed = trimLeadingZeroes(a);
    const b_trimmed = trimLeadingZeroes(b);
    if (a_trimmed.len != b_trimmed.len) return if (a_trimmed.len < b_trimmed.len) .lt else .gt;
    return std.mem.order(u8, a_trimmed, b_trimmed);
}

fn trimLeadingZeroes(value: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < value.len and value[index] == '0') index += 1;
    return value[index..];
}

fn numericOrder(a: u64, b: u64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
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

pub fn applyRawConfigOverrides(allocator: std.mem.Allocator, config_bytes: []const u8, raw_overrides: []const []const u8) ![]const u8 {
    var current: []const u8 = try allocator.dupe(u8, config_bytes);
    errdefer allocator.free(current);

    for (raw_overrides) |raw| {
        const parsed = try parseRawPluginEnabledOverride(raw) orelse continue;
        const updated = try upsertPluginEnabledConfig(allocator, current, parsed.plugin_id, parsed.enabled);
        allocator.free(current);
        current = updated;
    }

    return current;
}

const RawPluginEnabledOverride = struct {
    plugin_id: []const u8,
    enabled: bool,
};

fn parseRawPluginEnabledOverride(raw: []const u8) !?RawPluginEnabledOverride {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidConfigOverride;
    const key = std.mem.trim(u8, raw[0..eq], " \t");
    const prefix = "plugins.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const tail = key[prefix.len..];
    const plugin_id = parseRawPluginEnabledOverrideId(tail) orelse return null;
    if (!isValidPluginId(plugin_id)) return null;
    const raw_value = std.mem.trim(u8, raw[eq + 1 ..], " \t");
    const enabled = if (std.mem.eql(u8, raw_value, "true"))
        true
    else if (std.mem.eql(u8, raw_value, "false"))
        false
    else
        return error.InvalidConfigOverride;
    return .{ .plugin_id = plugin_id, .enabled = enabled };
}

fn parseRawPluginEnabledOverrideId(tail: []const u8) ?[]const u8 {
    const suffix = ".enabled";
    if (tail.len == 0) return null;
    if (tail[0] != '"') {
        if (!std.mem.endsWith(u8, tail, suffix)) return null;
        return tail[0 .. tail.len - suffix.len];
    }

    var index: usize = 1;
    while (index < tail.len and tail[index] != '"') : (index += 1) {
        if (tail[index] == '\\') return null;
    }
    if (index >= tail.len) return null;
    if (!std.mem.eql(u8, tail[index + 1 ..], suffix)) return null;
    return tail[1..index];
}

fn upsertPluginEnabledConfig(allocator: std.mem.Allocator, bytes: []const u8, plugin_id: []const u8, enabled: bool) ![]const u8 {
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
    try output.appendSlice(allocator, if (enabled) "enabled = true\n" else "enabled = false\n");
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
    const configured_ids = try configuredPluginIds(allocator, bytes);
    defer freeStringList(allocator, configured_ids);
    try std.testing.expectEqual(@as(usize, 3), configured_ids.len);
    try std.testing.expectEqualStrings("demo@test", configured_ids[0]);
    try std.testing.expectEqualStrings("disabled@test", configured_ids[1]);
    try std.testing.expectEqualStrings("later@test", configured_ids[2]);
    const parts = splitPluginId(ids[0]).?;
    try std.testing.expectEqualStrings("demo", parts.name);
    try std.testing.expectEqualStrings("test", parts.marketplace);
    try std.testing.expect(isValidPluginId("demo@test"));
    try std.testing.expect(!isValidPluginId("demo/../../oops@test"));
    const data_root = (try localPluginDataRoot(allocator, "/tmp/codex-home", "demo@test")).?;
    defer allocator.free(data_root);
    try std.testing.expectEqualStrings("/tmp/codex-home/plugins/data/demo-test", data_root);
}

test "plugin hooks feature defaults enabled" {
    const bytes =
        \\[features]
        \\plugins = true
        \\
    ;

    try std.testing.expect(pluginHooksFeatureEnabled(bytes));
}

test "plugin config resolves active versioned plugin roots" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/1.0.9");
    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/1.0.10");
    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/1.0.793");
    const codex_home = try dir.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(codex_home);

    const versioned = (try localPluginRoot(allocator, codex_home, "computer-use@openai-bundled")).?;
    defer allocator.free(versioned);
    try std.testing.expect(std.mem.endsWith(u8, versioned, "plugins/cache/openai-bundled/computer-use/1.0.793"));
    try std.testing.expect(comparePluginVersions("1.0.10", "1.0.9") == .gt);
    try std.testing.expect(comparePluginVersions("1.0.10", "1.0.10-beta.1") == .gt);

    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/local");
    const local = (try localPluginRoot(allocator, codex_home, "computer-use@openai-bundled")).?;
    defer allocator.free(local);
    try std.testing.expect(std.mem.endsWith(u8, local, "plugins/cache/openai-bundled/computer-use/local"));
}

test "plugin config resolves active versioned plugin roots from relative codex home" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/1.0.793");
    try dir.dir.createDirPath(io, "home/plugins/cache/openai-bundled/computer-use/zzz!");

    const codex_home = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/home", .{dir.sub_path[0..]});
    defer allocator.free(codex_home);

    const versioned = (try localPluginRoot(allocator, codex_home, "computer-use@openai-bundled")).?;
    defer allocator.free(versioned);
    try std.testing.expect(std.mem.endsWith(u8, versioned, "plugins/cache/openai-bundled/computer-use/1.0.793"));
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

test "raw plugin config overrides update enabled state" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[plugins."demo@test"]
        \\enabled = true
    ;

    const updated = try applyRawConfigOverrides(allocator, bytes, &.{"plugins.\"demo@test\".enabled=false"});
    defer allocator.free(updated);

    const configured_ids = try configuredPluginIds(allocator, updated);
    defer freeStringList(allocator, configured_ids);
    try std.testing.expectEqual(@as(usize, 1), configured_ids.len);
    try std.testing.expectEqualStrings("demo@test", configured_ids[0]);

    const enabled_ids = try enabledPluginIds(allocator, updated);
    defer freeStringList(allocator, enabled_ids);
    try std.testing.expectEqual(@as(usize, 0), enabled_ids.len);
}
