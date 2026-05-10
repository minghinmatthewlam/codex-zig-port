const std = @import("std");

const env = @import("env.zig");
const plugin_config = @import("plugin_config.zig");

pub const OPENAI_CURATED_MARKETPLACE_NAME = "openai-curated";
pub const INSTALLED_MARKETPLACES_DIR = ".tmp/marketplaces";

const MARKETPLACE_MANIFEST_RELATIVE_PATHS = [_][]const u8{
    ".agents/plugins/marketplace.json",
    ".claude-plugin/marketplace.json",
};

pub const AddError = error{
    MarketplaceSourceEmpty,
    UnsupportedMarketplaceSource,
    RefUnsupportedForLocalSource,
    SparseUnsupportedForLocalSource,
    InvalidLocalMarketplaceSource,
    LocalMarketplaceSourceMustBeDirectory,
    InvalidMarketplaceRoot,
    InvalidMarketplaceName,
    ReservedMarketplaceName,
    MarketplaceAlreadyAddedDifferentSource,
};

pub const RemoveError = error{
    InvalidMarketplaceName,
    UnknownMarketplace,
};

pub const AddResult = struct {
    marketplace_name: []const u8,
    installed_root: []const u8,
    updated_config: []const u8,
    already_added: bool,

    pub fn deinit(self: AddResult, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.installed_root);
        allocator.free(self.updated_config);
    }
};

pub const RemoveResult = struct {
    marketplace_name: []const u8,
    installed_root: ?[]const u8,
    updated_config: []const u8,

    pub fn deinit(self: RemoveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        if (self.installed_root) |path| allocator.free(path);
        allocator.free(self.updated_config);
    }
};

pub const ConfiguredMarketplaceRoot = struct {
    marketplace_name: []const u8,
    root: []const u8,

    pub fn deinit(self: *ConfiguredMarketplaceRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.root);
    }
};

const MarketplaceEntry = struct {
    name: []const u8,
    source_type: ?[]const u8 = null,
    source: ?[]const u8 = null,

    fn deinit(self: *MarketplaceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.source_type) |value| allocator.free(value);
        if (self.source) |value| allocator.free(value);
    }
};

pub fn addLocalMarketplace(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    source: []const u8,
    ref_name: ?[]const u8,
    sparse_paths: []const []const u8,
) !AddResult {
    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed_source.len == 0) return AddError.MarketplaceSourceEmpty;
    if (!looksLikeLocalPath(trimmed_source)) return AddError.UnsupportedMarketplaceSource;
    if (ref_name) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return AddError.RefUnsupportedForLocalSource;
    }
    if (sparse_paths.len > 0) return AddError.SparseUnsupportedForLocalSource;

    const installed_root = try resolveLocalSourceRoot(allocator, trimmed_source);
    defer allocator.free(installed_root);
    const marketplace_name = try validateMarketplaceRoot(allocator, installed_root);
    defer allocator.free(marketplace_name);
    if (std.mem.eql(u8, marketplace_name, OPENAI_CURATED_MARKETPLACE_NAME)) return AddError.ReservedMarketplaceName;

    if (try marketplaceEntryForName(allocator, config_bytes, marketplace_name)) |entry_const| {
        var entry = entry_const;
        defer entry.deinit(allocator);
        const same_source = entry.source_type != null and
            entry.source != null and
            std.mem.eql(u8, entry.source_type.?, "local") and
            std.mem.eql(u8, entry.source.?, installed_root);
        if (!same_source) return AddError.MarketplaceAlreadyAddedDifferentSource;
        return .{
            .marketplace_name = try allocator.dupe(u8, marketplace_name),
            .installed_root = try allocator.dupe(u8, installed_root),
            .updated_config = try upsertLocalMarketplaceConfig(allocator, config_bytes, marketplace_name, installed_root),
            .already_added = true,
        };
    }

    return .{
        .marketplace_name = try allocator.dupe(u8, marketplace_name),
        .installed_root = try allocator.dupe(u8, installed_root),
        .updated_config = try upsertLocalMarketplaceConfig(allocator, config_bytes, marketplace_name, installed_root),
        .already_added = false,
    };
}

pub fn removeMarketplace(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    marketplace_name: []const u8,
) !RemoveResult {
    if (!plugin_config.isValidPluginSegment(marketplace_name)) return RemoveError.InvalidMarketplaceName;
    const removed_config = try removeMarketplaceConfig(allocator, config_bytes, marketplace_name);
    errdefer allocator.free(removed_config.updated_config);

    const installed_root_path = try installedMarketplaceRoot(allocator, codex_home, marketplace_name);
    defer allocator.free(installed_root_path);
    const removed_root = try deletePathIfPresent(allocator, installed_root_path);
    errdefer if (removed_root) |path| allocator.free(path);

    if (!removed_config.removed and removed_root == null) return RemoveError.UnknownMarketplace;

    return .{
        .marketplace_name = try allocator.dupe(u8, marketplace_name),
        .installed_root = removed_root,
        .updated_config = removed_config.updated_config,
    };
}

pub fn configuredMarketplaceRoots(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8) ![]ConfiguredMarketplaceRoot {
    const entries = try marketplaceEntries(allocator, config_bytes);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    var roots = std.ArrayList(ConfiguredMarketplaceRoot).empty;
    errdefer {
        for (roots.items) |*root| root.deinit(allocator);
        roots.deinit(allocator);
    }

    for (entries) |entry| {
        if (!plugin_config.isValidPluginSegment(entry.name)) continue;
        const source_type = entry.source_type orelse "";
        const root = if (std.mem.eql(u8, source_type, "local")) blk: {
            const source = entry.source orelse continue;
            if (source.len == 0) continue;
            break :blk try allocator.dupe(u8, source);
        } else try installedMarketplaceRoot(allocator, codex_home, entry.name);
        errdefer allocator.free(root);
        try roots.append(allocator, .{
            .marketplace_name = try allocator.dupe(u8, entry.name),
            .root = root,
        });
    }

    return roots.toOwnedSlice(allocator);
}

fn resolveLocalSourceRoot(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const expanded = try expandTildePath(allocator, source);
    defer allocator.free(expanded);

    const path = if (std.fs.path.isAbsolute(expanded))
        try allocator.dupe(u8, expanded)
    else blk: {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, expanded });
    };
    defer allocator.free(path);

    const real_path_z = std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator) catch return AddError.InvalidLocalMarketplaceSource;
    defer allocator.free(real_path_z);
    const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), real_path_z, .{ .follow_symlinks = true }) catch return AddError.InvalidLocalMarketplaceSource;
    if (stat.kind != .directory) return AddError.LocalMarketplaceSourceMustBeDirectory;
    return allocator.dupe(u8, real_path_z);
}

fn expandTildePath(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, source, "~/")) return allocator.dupe(u8, source);
    const home = (try env.getOwned(allocator, "HOME")) orelse return allocator.dupe(u8, source);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, source[2..] });
}

fn looksLikeLocalPath(source: []const u8) bool {
    return std.fs.path.isAbsolute(source) or
        std.mem.eql(u8, source, ".") or
        std.mem.eql(u8, source, "..") or
        std.mem.startsWith(u8, source, "./") or
        std.mem.startsWith(u8, source, "../") or
        std.mem.startsWith(u8, source, "~/");
}

fn validateMarketplaceRoot(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    const manifest_path = try marketplaceManifestPath(allocator, root) orelse return AddError.InvalidMarketplaceRoot;
    defer allocator.free(manifest_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), manifest_path, allocator, .limited(1024 * 1024)) catch return AddError.InvalidMarketplaceRoot;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return AddError.InvalidMarketplaceRoot;
    defer parsed.deinit();
    if (parsed.value != .object) return AddError.InvalidMarketplaceRoot;
    const object = parsed.value.object;
    const name_value = object.get("name") orelse return AddError.InvalidMarketplaceRoot;
    if (name_value != .string) return AddError.InvalidMarketplaceRoot;
    if (!plugin_config.isValidPluginSegment(name_value.string)) return AddError.InvalidMarketplaceName;
    const plugins_value = object.get("plugins") orelse return AddError.InvalidMarketplaceRoot;
    if (plugins_value != .array) return AddError.InvalidMarketplaceRoot;
    return allocator.dupe(u8, name_value.string);
}

fn marketplaceManifestPath(allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    for (MARKETPLACE_MANIFEST_RELATIVE_PATHS) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ root, relative_path });
        errdefer allocator.free(path);
        _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = true }) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return null;
}

fn installedMarketplaceRoot(allocator: std.mem.Allocator, codex_home: []const u8, marketplace_name: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, INSTALLED_MARKETPLACES_DIR, marketplace_name });
}

fn upsertLocalMarketplaceConfig(allocator: std.mem.Allocator, bytes: []const u8, marketplace_name: []const u8, source: []const u8) ![]const u8 {
    const removed = try removeMarketplaceConfig(allocator, bytes, marketplace_name);
    defer allocator.free(removed.updated_config);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, std.mem.trimEnd(u8, removed.updated_config, " \t\r\n"));
    if (output.items.len > 0) try output.appendSlice(allocator, "\n\n");
    try output.appendSlice(allocator, "[marketplaces.");
    try output.appendSlice(allocator, marketplace_name);
    try output.appendSlice(allocator, "]\n");
    try output.appendSlice(allocator, "source_type = \"local\"\n");
    try output.appendSlice(allocator, "source = ");
    try appendTomlStringLiteral(allocator, &output, source);
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

const RemoveConfigResult = struct {
    updated_config: []const u8,
    removed: bool,
};

fn removeMarketplaceConfig(allocator: std.mem.Allocator, bytes: []const u8, marketplace_name: []const u8) !RemoveConfigResult {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var skipping_table = false;
    var removed = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = stripTomlLineComment(line_raw);
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (isTomlTableHeader(trimmed)) {
            const belongs = try marketplaceTableHeaderBelongsTo(allocator, trimmed, marketplace_name);
            skipping_table = belongs;
            removed = removed or belongs;
        }
        if (skipping_table) continue;

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    if (!removed) {
        output.deinit(allocator);
        return .{ .updated_config = try allocator.dupe(u8, bytes), .removed = false };
    }
    return .{ .updated_config = try output.toOwnedSlice(allocator), .removed = true };
}

fn marketplaceEntryForName(allocator: std.mem.Allocator, bytes: []const u8, marketplace_name: []const u8) !?MarketplaceEntry {
    const entries = try marketplaceEntries(allocator, bytes);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, marketplace_name)) {
            return .{
                .name = try allocator.dupe(u8, entry.name),
                .source_type = if (entry.source_type) |value| try allocator.dupe(u8, value) else null,
                .source = if (entry.source) |value| try allocator.dupe(u8, value) else null,
            };
        }
    }
    return null;
}

fn marketplaceEntries(allocator: std.mem.Allocator, bytes: []const u8) ![]MarketplaceEntry {
    var entries = std.ArrayList(MarketplaceEntry).empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var current: ?MarketplaceEntry = null;
    errdefer if (current) |*entry| entry.deinit(allocator);

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = stripTomlLineComment(line_raw);
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (isTomlTableHeader(trimmed)) {
            if (current) |entry| try entries.append(allocator, entry);
            current = null;
            if (try parseMarketplaceTableHeader(allocator, trimmed)) |header| {
                defer allocator.free(header.name);
                if (!header.is_child) {
                    current = .{ .name = try allocator.dupe(u8, header.name) };
                }
            }
            continue;
        }
        if (current) |*entry| {
            if (tomlStringValueForKey(allocator, trimmed, "source_type") catch |err| switch (err) {
                error.InvalidTomlString => null,
                else => return err,
            }) |value| {
                if (entry.source_type) |existing| allocator.free(existing);
                entry.source_type = value;
            } else if (tomlStringValueForKey(allocator, trimmed, "source") catch |err| switch (err) {
                error.InvalidTomlString => null,
                else => return err,
            }) |value| {
                if (entry.source) |existing| allocator.free(existing);
                entry.source = value;
            }
        }
    }
    if (current) |entry| {
        try entries.append(allocator, entry);
        current = null;
    }

    return entries.toOwnedSlice(allocator);
}

fn deletePathIfPresent(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const removed_root = try allocator.dupe(u8, path);
    errdefer allocator.free(removed_root);
    if (stat.kind == .directory) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    } else if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.deleteFileAbsolute(io, path);
    } else {
        try std.Io.Dir.cwd().deleteFile(io, path);
    }
    return removed_root;
}

const MarketplaceTableHeader = struct {
    name: []const u8,
    is_child: bool,
};

fn marketplaceTableHeaderBelongsTo(allocator: std.mem.Allocator, line: []const u8, marketplace_name: []const u8) !bool {
    const header = (try parseMarketplaceTableHeader(allocator, line)) orelse return false;
    defer allocator.free(header.name);
    return std.mem.eql(u8, header.name, marketplace_name);
}

fn parseMarketplaceTableHeader(allocator: std.mem.Allocator, line: []const u8) !?MarketplaceTableHeader {
    if (!isTomlTableHeader(line)) return null;
    if (line.len >= 4 and line[1] == '[') return null;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    const prefix = "marketplaces.";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    var index: usize = prefix.len;
    const name = if (index < inner.len and inner[index] == '"')
        (try parseTomlStringAt(allocator, inner, &index)) orelse return null
    else blk: {
        const start = index;
        while (index < inner.len and inner[index] != '.') : (index += 1) {}
        if (index == start) return null;
        break :blk try allocator.dupe(u8, std.mem.trim(u8, inner[start..index], " \t\r"));
    };
    errdefer allocator.free(name);
    skipTomlWhitespace(inner, &index);
    if (index == inner.len) return .{ .name = name, .is_child = false };
    if (inner[index] == '.') return .{ .name = name, .is_child = true };
    allocator.free(name);
    return null;
}

fn isTomlTableHeader(line: []const u8) bool {
    return line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']';
}

fn tomlStringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    if (line.len == 0 or line[0] == '[') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs_with_comment = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const rhs = std.mem.trim(u8, stripTomlLineComment(rhs_with_comment), " \t");
    var index: usize = 0;
    const value = (try parseTomlStringAt(allocator, rhs, &index)) orelse return null;
    skipTomlWhitespace(rhs, &index);
    if (index != rhs.len) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn appendTomlStringLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
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

fn stripTomlLineComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (!in_string and byte == '#') return line[0..index];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string and byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') in_string = !in_string;
    }
    return line;
}

test "marketplace add records local source and reports already added" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "source#hash/.agents/plugins");
    try dir.dir.writeFile(io, .{
        .sub_path = "source#hash/.agents/plugins/marketplace.json",
        .data = "{\"name\":\"debug\",\"plugins\":[]}",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source#hash" });
    defer allocator.free(source);

    const added = try addLocalMarketplace(allocator, "", source, null, &.{});
    defer added.deinit(allocator);
    try std.testing.expectEqualStrings("debug", added.marketplace_name);
    try std.testing.expectEqualStrings(source, added.installed_root);
    try std.testing.expect(!added.already_added);
    try std.testing.expect(std.mem.indexOf(u8, added.updated_config, "[marketplaces.debug]") != null);
    try std.testing.expect(std.mem.indexOf(u8, added.updated_config, "source_type = \"local\"") != null);

    const repeated = try addLocalMarketplace(allocator, added.updated_config, source, null, &.{});
    defer repeated.deinit(allocator);
    try std.testing.expect(repeated.already_added);
}

test "marketplace remove deletes config and installed root" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "home/.tmp/marketplaces/debug");
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(codex_home);
    const config_bytes =
        \\[features]
        \\plugins = true
        \\
        \\[marketplaces.debug]
        \\source_type = "git"
        \\source = "https://github.com/owner/repo.git"
    ;

    const removed = try removeMarketplace(allocator, codex_home, config_bytes, "debug");
    defer removed.deinit(allocator);
    try std.testing.expectEqualStrings("debug", removed.marketplace_name);
    try std.testing.expect(removed.installed_root != null);
    try std.testing.expect(std.mem.indexOf(u8, removed.updated_config, "[marketplaces.debug]") == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, removed.installed_root.?, .{}));
}

test "configured marketplace roots include local sources" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[marketplaces.debug]
        \\source_type = "local"
        \\source = "/tmp/debug-marketplace"
    ;

    const roots = try configuredMarketplaceRoots(allocator, "/tmp/codex-home", bytes);
    defer {
        for (roots) |*root| root.deinit(allocator);
        allocator.free(roots);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings("debug", roots[0].marketplace_name);
    try std.testing.expectEqualStrings("/tmp/debug-marketplace", roots[0].root);
}
