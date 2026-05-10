const std = @import("std");

const env = @import("env.zig");
const plugin_config = @import("plugin_config.zig");

pub const OPENAI_CURATED_MARKETPLACE_NAME = "openai-curated";
pub const INSTALLED_MARKETPLACES_DIR = ".tmp/marketplaces";
const INSTALLED_MARKETPLACE_METADATA_FILE = ".codex-marketplace-install.json";

const MARKETPLACE_MANIFEST_RELATIVE_PATHS = [_][]const u8{
    ".agents/plugins/marketplace.json",
    ".claude-plugin/marketplace.json",
};

pub const AddError = error{
    MarketplaceSourceEmpty,
    InvalidMarketplaceSourceFormat,
    RefUnsupportedForLocalSource,
    SparseUnsupportedForLocalSource,
    InvalidLocalMarketplaceSource,
    LocalMarketplaceSourceMustBeDirectory,
    InvalidMarketplaceRoot,
    InvalidMarketplaceName,
    ReservedMarketplaceName,
    MarketplaceAlreadyAddedDifferentSource,
    InvalidMarketplaceInstallDirectory,
    GitCommandFailed,
};

pub const RemoveError = error{
    InvalidMarketplaceName,
    UnknownMarketplace,
};

pub const UpgradeError = error{
    MarketplaceNotConfiguredAsGit,
    GitCommandFailed,
};

pub const AddResult = struct {
    marketplace_name: []const u8,
    source_display: []const u8,
    installed_root: []const u8,
    updated_config: []const u8,
    already_added: bool,

    pub fn deinit(self: AddResult, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.source_display);
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

pub const UpgradeFailure = struct {
    marketplace_name: []const u8,
    message: []const u8,

    fn deinit(self: *UpgradeFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.marketplace_name);
        allocator.free(self.message);
    }
};

pub const UpgradeResult = struct {
    selected_marketplaces: []const []const u8,
    upgraded_roots: []const []const u8,
    errors: []UpgradeFailure,
    updated_config: []const u8,

    pub fn deinit(self: UpgradeResult, allocator: std.mem.Allocator) void {
        for (self.selected_marketplaces) |name| allocator.free(name);
        allocator.free(self.selected_marketplaces);
        for (self.upgraded_roots) |root| allocator.free(root);
        allocator.free(self.upgraded_roots);
        for (self.errors) |*failure| failure.deinit(allocator);
        allocator.free(self.errors);
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
    last_revision: ?[]const u8 = null,
    source_type: ?[]const u8 = null,
    source: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    sparse_paths: []const []const u8 = &.{},

    fn deinit(self: *MarketplaceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.last_revision) |value| allocator.free(value);
        if (self.source_type) |value| allocator.free(value);
        if (self.source) |value| allocator.free(value);
        if (self.ref_name) |value| allocator.free(value);
        for (self.sparse_paths) |path| allocator.free(path);
        if (self.sparse_paths.len > 0) allocator.free(self.sparse_paths);
    }
};

const MarketplaceSource = union(enum) {
    local: []const u8,
    git: GitMarketplaceSource,

    fn deinit(self: *MarketplaceSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .local => |path| allocator.free(path),
            .git => |*source| source.deinit(allocator),
        }
    }
};

const GitMarketplaceSource = struct {
    url: []const u8,
    ref_name: ?[]const u8,
    sparse_paths: []const []const u8,

    fn deinit(self: *GitMarketplaceSource, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.ref_name) |value| allocator.free(value);
    }

    fn display(self: GitMarketplaceSource, allocator: std.mem.Allocator) ![]const u8 {
        if (self.ref_name) |ref_name| {
            return std.fmt.allocPrint(allocator, "{s}#{s}", .{ self.url, ref_name });
        }
        return allocator.dupe(u8, self.url);
    }
};

const MarketplaceConfigUpdate = struct {
    source_type: []const u8,
    source: []const u8,
    last_revision: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    sparse_paths: []const []const u8 = &.{},
};

pub fn addMarketplace(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    source: []const u8,
    ref_name: ?[]const u8,
    sparse_paths: []const []const u8,
) !AddResult {
    var parsed = try parseMarketplaceSource(allocator, source, ref_name, sparse_paths);
    defer parsed.deinit(allocator);

    return switch (parsed) {
        .local => |path| addParsedLocalMarketplace(allocator, config_bytes, path),
        .git => |git_source| addGitMarketplace(allocator, codex_home, config_bytes, git_source),
    };
}

pub fn addLocalMarketplace(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    source: []const u8,
    ref_name: ?[]const u8,
    sparse_paths: []const []const u8,
) !AddResult {
    var parsed = try parseMarketplaceSource(allocator, source, ref_name, sparse_paths);
    defer parsed.deinit(allocator);
    return switch (parsed) {
        .local => |path| addParsedLocalMarketplace(allocator, config_bytes, path),
        .git => AddError.InvalidMarketplaceSourceFormat,
    };
}

fn addParsedLocalMarketplace(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    installed_root: []const u8,
) !AddResult {
    const marketplace_name = try validateMarketplaceRoot(allocator, installed_root);
    defer allocator.free(marketplace_name);
    if (std.mem.eql(u8, marketplace_name, OPENAI_CURATED_MARKETPLACE_NAME)) return AddError.ReservedMarketplaceName;

    const update = MarketplaceConfigUpdate{
        .source_type = "local",
        .source = installed_root,
    };

    if (try marketplaceEntryForName(allocator, config_bytes, marketplace_name)) |entry_const| {
        var entry = entry_const;
        defer entry.deinit(allocator);
        if (!entryMatchesUpdate(entry, update)) return AddError.MarketplaceAlreadyAddedDifferentSource;
        return buildAddResult(allocator, config_bytes, marketplace_name, installed_root, installed_root, update, true);
    }

    return buildAddResult(allocator, config_bytes, marketplace_name, installed_root, installed_root, update, false);
}

fn buildAddResult(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    marketplace_name: []const u8,
    source_display: []const u8,
    installed_root: []const u8,
    update: MarketplaceConfigUpdate,
    already_added: bool,
) !AddResult {
    const result_name = try allocator.dupe(u8, marketplace_name);
    errdefer allocator.free(result_name);
    const result_source = try allocator.dupe(u8, source_display);
    errdefer allocator.free(result_source);
    const result_root = try allocator.dupe(u8, installed_root);
    errdefer allocator.free(result_root);
    const result_config = try upsertMarketplaceConfig(allocator, config_bytes, marketplace_name, update);
    errdefer allocator.free(result_config);

    return .{
        .marketplace_name = result_name,
        .source_display = result_source,
        .installed_root = result_root,
        .updated_config = result_config,
        .already_added = already_added,
    };
}

fn parseMarketplaceSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    explicit_ref: ?[]const u8,
    sparse_paths: []const []const u8,
) !MarketplaceSource {
    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed_source.len == 0) return AddError.MarketplaceSourceEmpty;

    const split = splitSourceRef(trimmed_source);
    const base_source = split.base;
    const parsed_ref = split.ref_name;
    const effective_ref = if (explicit_ref) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else parsed_ref;

    if (looksLikeLocalPath(base_source)) {
        if (effective_ref != null) return AddError.RefUnsupportedForLocalSource;
        if (sparse_paths.len > 0) return AddError.SparseUnsupportedForLocalSource;
        return .{ .local = try resolveLocalSourceRoot(allocator, base_source) };
    }

    if (isSshGitUrl(base_source) or isGitUrl(base_source)) {
        return .{ .git = .{
            .url = try normalizeGitUrl(allocator, base_source),
            .ref_name = if (effective_ref) |value| try allocator.dupe(u8, value) else null,
            .sparse_paths = sparse_paths,
        } };
    }

    if (looksLikeGithubShorthand(base_source)) {
        return .{ .git = .{
            .url = try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{base_source}),
            .ref_name = if (effective_ref) |value| try allocator.dupe(u8, value) else null,
            .sparse_paths = sparse_paths,
        } };
    }

    return AddError.InvalidMarketplaceSourceFormat;
}

fn addGitMarketplace(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    source: GitMarketplaceSource,
) !AddResult {
    const install_root = try installedMarketplacesRoot(allocator, codex_home);
    defer allocator.free(install_root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), install_root);

    const update = MarketplaceConfigUpdate{
        .source_type = "git",
        .source = source.url,
        .ref_name = source.ref_name,
        .sparse_paths = source.sparse_paths,
    };
    const source_display = try source.display(allocator);
    defer allocator.free(source_display);

    if (try marketplaceEntryForUpdate(allocator, config_bytes, update)) |entry_const| {
        var entry = entry_const;
        defer entry.deinit(allocator);
        const root = try installedMarketplaceRoot(allocator, codex_home, entry.name);
        defer allocator.free(root);
        if (try validateMarketplaceRootOrNull(allocator, root)) |marketplace_name| {
            defer allocator.free(marketplace_name);
            return buildAddResult(allocator, config_bytes, marketplace_name, source_display, root, update, true);
        }
    }

    const staged_root = try createMarketplaceStagingRoot(allocator, install_root, "marketplace-add");
    defer allocator.free(staged_root);
    errdefer deleteTreeBestEffort(staged_root);

    const added_revision = try cloneGitSource(allocator, source, staged_root);
    defer allocator.free(added_revision);

    const marketplace_name = try validateMarketplaceRoot(allocator, staged_root);
    defer allocator.free(marketplace_name);
    if (std.mem.eql(u8, marketplace_name, OPENAI_CURATED_MARKETPLACE_NAME)) return AddError.ReservedMarketplaceName;

    if (try marketplaceEntryForName(allocator, config_bytes, marketplace_name)) |entry_const| {
        var entry = entry_const;
        defer entry.deinit(allocator);
        if (!entryMatchesUpdate(entry, update)) return AddError.MarketplaceAlreadyAddedDifferentSource;
    }

    const destination = try installedMarketplaceRoot(allocator, codex_home, marketplace_name);
    defer allocator.free(destination);
    if (!isPathWithinOrEqual(install_root, destination)) return AddError.InvalidMarketplaceInstallDirectory;
    if (pathExists(destination)) return AddError.MarketplaceAlreadyAddedDifferentSource;

    const result = try buildAddResult(allocator, config_bytes, marketplace_name, source_display, destination, update, false);
    errdefer result.deinit(allocator);

    const parent = std.fs.path.dirname(destination) orelse return AddError.InvalidMarketplaceInstallDirectory;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
    try std.Io.Dir.rename(
        std.Io.Dir.cwd(),
        staged_root,
        std.Io.Dir.cwd(),
        destination,
        std.Io.Threaded.global_single_threaded.io(),
    );

    return result;
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

pub fn upgradeMarketplaces(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    requested_marketplace_name: ?[]const u8,
) !UpgradeResult {
    const entries = try marketplaceEntries(allocator, config_bytes);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    var selected = std.ArrayList([]const u8).empty;
    errdefer {
        for (selected.items) |name| allocator.free(name);
        selected.deinit(allocator);
    }
    var upgraded = std.ArrayList([]const u8).empty;
    errdefer {
        for (upgraded.items) |root| allocator.free(root);
        upgraded.deinit(allocator);
    }
    var failures = std.ArrayList(UpgradeFailure).empty;
    errdefer {
        for (failures.items) |*failure| failure.deinit(allocator);
        failures.deinit(allocator);
    }

    var updated_config: []const u8 = try allocator.dupe(u8, config_bytes);
    errdefer allocator.free(updated_config);

    for (entries) |entry| {
        if (requested_marketplace_name) |requested| {
            if (!std.mem.eql(u8, entry.name, requested)) continue;
        }
        if (!isConfiguredGitMarketplace(entry)) continue;

        const selected_name = try allocator.dupe(u8, entry.name);
        selected.append(allocator, selected_name) catch |err| {
            allocator.free(selected_name);
            return err;
        };
        const maybe_result = upgradeConfiguredGitMarketplace(allocator, codex_home, updated_config, entry) catch |err| {
            try appendUpgradeFailure(allocator, &failures, entry.name, err);
            continue;
        };
        if (maybe_result) |result| {
            allocator.free(updated_config);
            updated_config = result.updated_config;
            upgraded.append(allocator, result.installed_root) catch |err| {
                allocator.free(result.installed_root);
                return err;
            };
        }
    }

    if (requested_marketplace_name != null and selected.items.len == 0) return UpgradeError.MarketplaceNotConfiguredAsGit;

    const selected_slice = try selected.toOwnedSlice(allocator);
    selected = .empty;
    errdefer {
        for (selected_slice) |name| allocator.free(name);
        allocator.free(selected_slice);
    }
    const upgraded_slice = try upgraded.toOwnedSlice(allocator);
    upgraded = .empty;
    errdefer {
        for (upgraded_slice) |root| allocator.free(root);
        allocator.free(upgraded_slice);
    }
    const failure_slice = try failures.toOwnedSlice(allocator);
    failures = .empty;
    errdefer {
        for (failure_slice) |*failure| failure.deinit(allocator);
        allocator.free(failure_slice);
    }

    return .{
        .selected_marketplaces = selected_slice,
        .upgraded_roots = upgraded_slice,
        .errors = failure_slice,
        .updated_config = updated_config,
    };
}

const OneUpgradeResult = struct {
    installed_root: []const u8,
    updated_config: []const u8,
};

fn upgradeConfiguredGitMarketplace(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    entry: MarketplaceEntry,
) !?OneUpgradeResult {
    if (!plugin_config.isValidPluginSegment(entry.name)) return AddError.InvalidMarketplaceName;
    const source = entry.source orelse return null;
    const remote_revision = try gitRemoteRevision(allocator, source, entry.ref_name);
    defer allocator.free(remote_revision);

    const destination = try installedMarketplaceRoot(allocator, codex_home, entry.name);
    defer allocator.free(destination);
    if (try installedMarketplaceIsCurrent(allocator, destination, entry, remote_revision)) return null;

    const install_root = try installedMarketplacesRoot(allocator, codex_home);
    defer allocator.free(install_root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), install_root);

    const staged_root = try createMarketplaceStagingRoot(allocator, install_root, "marketplace-upgrade");
    defer allocator.free(staged_root);
    errdefer deleteTreeBestEffort(staged_root);

    const source_info = GitMarketplaceSource{
        .url = source,
        .ref_name = entry.ref_name,
        .sparse_paths = entry.sparse_paths,
    };
    const activated_revision = try cloneGitSource(allocator, source_info, staged_root);
    defer allocator.free(activated_revision);

    const upgraded_name = try validateMarketplaceRoot(allocator, staged_root);
    defer allocator.free(upgraded_name);
    if (!std.mem.eql(u8, upgraded_name, entry.name)) return AddError.InvalidMarketplaceName;

    try writeInstalledMarketplaceMetadata(allocator, staged_root, entry, activated_revision);
    const update = MarketplaceConfigUpdate{
        .source_type = "git",
        .source = source,
        .last_revision = activated_revision,
        .ref_name = entry.ref_name,
        .sparse_paths = entry.sparse_paths,
    };
    const next_config = try upsertMarketplaceConfig(allocator, config_bytes, entry.name, update);
    errdefer allocator.free(next_config);

    if (!isPathWithinOrEqual(install_root, destination)) return AddError.InvalidMarketplaceInstallDirectory;
    try replaceMarketplaceRoot(allocator, install_root, staged_root, destination);

    return .{
        .installed_root = try allocator.dupe(u8, destination),
        .updated_config = next_config,
    };
}

fn isConfiguredGitMarketplace(entry: MarketplaceEntry) bool {
    return entry.source_type != null and
        entry.source != null and
        std.mem.eql(u8, entry.source_type.?, "git");
}

fn appendUpgradeFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList(UpgradeFailure),
    marketplace_name: []const u8,
    err: anyerror,
) !void {
    const name = try allocator.dupe(u8, marketplace_name);
    errdefer allocator.free(name);
    const message = try upgradeErrorMessage(allocator, err);
    errdefer allocator.free(message);
    try failures.append(allocator, .{
        .marketplace_name = name,
        .message = message,
    });
}

fn upgradeErrorMessage(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return switch (err) {
        error.GitCommandFailed => allocator.dupe(u8, "failed to run git while upgrading marketplace"),
        error.InvalidMarketplaceRoot => allocator.dupe(u8, "failed to validate upgraded marketplace root"),
        error.InvalidMarketplaceName => allocator.dupe(u8, "upgraded marketplace name does not match configured marketplace"),
        error.InvalidMarketplaceInstallDirectory => allocator.dupe(u8, "marketplace install destination is outside install root"),
        else => std.fmt.allocPrint(allocator, "failed to upgrade marketplace: {s}", .{@errorName(err)}),
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

const SourceRef = struct {
    base: []const u8,
    ref_name: ?[]const u8,
};

fn splitSourceRef(source: []const u8) SourceRef {
    if (std.mem.lastIndexOfScalar(u8, source, '#')) |index| {
        return .{ .base = source[0..index], .ref_name = nonEmptyRef(source[index + 1 ..]) };
    }
    if (std.mem.indexOf(u8, source, "://") == null and !isSshGitUrl(source)) {
        if (std.mem.lastIndexOfScalar(u8, source, '@')) |index| {
            return .{ .base = source[0..index], .ref_name = nonEmptyRef(source[index + 1 ..]) };
        }
    }
    return .{ .base = source, .ref_name = null };
}

fn nonEmptyRef(ref_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, ref_name, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn normalizeGitUrl(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, source, "/");
    if (std.mem.startsWith(u8, trimmed, "https://github.com/") and !std.mem.endsWith(u8, trimmed, ".git")) {
        return std.fmt.allocPrint(allocator, "{s}.git", .{trimmed});
    }
    return allocator.dupe(u8, trimmed);
}

fn isSshGitUrl(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "ssh://") or
        (std.mem.startsWith(u8, source, "git@") and std.mem.indexOfScalar(u8, source, ':') != null);
}

fn isGitUrl(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://");
}

fn looksLikeGithubShorthand(source: []const u8) bool {
    var parts = std.mem.splitScalar(u8, source, '/');
    const owner = parts.next() orelse return false;
    const repo = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return isGithubShorthandSegment(owner) and isGithubShorthandSegment(repo);
}

fn isGithubShorthandSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    for (segment) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
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

fn validateMarketplaceRootOrNull(allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    return validateMarketplaceRoot(allocator, root) catch |err| switch (err) {
        AddError.InvalidMarketplaceRoot, AddError.InvalidMarketplaceName => return null,
        else => return err,
    };
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

fn installedMarketplacesRoot(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, INSTALLED_MARKETPLACES_DIR });
}

fn upsertMarketplaceConfig(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    marketplace_name: []const u8,
    update: MarketplaceConfigUpdate,
) ![]const u8 {
    const removed = try removeMarketplaceConfig(allocator, bytes, marketplace_name);
    defer allocator.free(removed.updated_config);

    const last_updated = try currentRfc3339(allocator);
    defer allocator.free(last_updated);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, std.mem.trimEnd(u8, removed.updated_config, " \t\r\n"));
    if (output.items.len > 0) try output.appendSlice(allocator, "\n\n");
    try output.appendSlice(allocator, "[marketplaces.");
    try output.appendSlice(allocator, marketplace_name);
    try output.appendSlice(allocator, "]\n");
    try output.appendSlice(allocator, "last_updated = ");
    try appendTomlStringLiteral(allocator, &output, last_updated);
    try output.append(allocator, '\n');
    try output.appendSlice(allocator, "source_type = ");
    try appendTomlStringLiteral(allocator, &output, update.source_type);
    try output.append(allocator, '\n');
    try output.appendSlice(allocator, "source = ");
    try appendTomlStringLiteral(allocator, &output, update.source);
    try output.append(allocator, '\n');
    if (update.last_revision) |last_revision| {
        try output.appendSlice(allocator, "last_revision = ");
        try appendTomlStringLiteral(allocator, &output, last_revision);
        try output.append(allocator, '\n');
    }
    if (update.ref_name) |ref_name| {
        try output.appendSlice(allocator, "ref = ");
        try appendTomlStringLiteral(allocator, &output, ref_name);
        try output.append(allocator, '\n');
    }
    if (update.sparse_paths.len > 0) {
        try output.appendSlice(allocator, "sparse_paths = [");
        for (update.sparse_paths, 0..) |path, index| {
            if (index > 0) try output.appendSlice(allocator, ", ");
            try appendTomlStringLiteral(allocator, &output, path);
        }
        try output.appendSlice(allocator, "]\n");
    }
    return output.toOwnedSlice(allocator);
}

fn currentRfc3339(allocator: std.mem.Allocator) ![]const u8 {
    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real);
    const seconds = @as(u64, @intCast(now.toSeconds()));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn entryMatchesUpdate(entry: MarketplaceEntry, update: MarketplaceConfigUpdate) bool {
    return entry.source_type != null and
        entry.source != null and
        std.mem.eql(u8, entry.source_type.?, update.source_type) and
        std.mem.eql(u8, entry.source.?, update.source) and
        optionalStringEql(entry.ref_name, update.ref_name) and
        stringListsEqual(entry.sparse_paths, update.sparse_paths);
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn stringListsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_item, right_item| {
        if (!std.mem.eql(u8, left_item, right_item)) return false;
    }
    return true;
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn isPathWithinOrEqual(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn deleteTreeBestEffort(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

fn createMarketplaceStagingRoot(allocator: std.mem.Allocator, install_root: []const u8, prefix: []const u8) ![]const u8 {
    const staging_parent = try std.fs.path.join(allocator, &.{ install_root, ".staging" });
    defer allocator.free(staging_parent);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), staging_parent);

    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);
    const dir_name = try std.fmt.allocPrint(allocator, "{s}-{d}-{x}", .{ prefix, now, random_id });
    defer allocator.free(dir_name);
    return std.fs.path.join(allocator, &.{ staging_parent, dir_name });
}

fn cloneGitSource(allocator: std.mem.Allocator, source: GitMarketplaceSource, destination: []const u8) ![]const u8 {
    if (source.sparse_paths.len == 0) {
        try runGit(allocator, null, &.{ "clone", source.url, destination });
        if (source.ref_name) |ref_name| {
            try runGit(allocator, destination, &.{ "checkout", ref_name });
        }
        return gitWorktreeRevision(allocator, destination);
    }

    try runGit(allocator, null, &.{ "clone", "--filter=blob:none", "--no-checkout", source.url, destination });
    var sparse_args = std.ArrayList([]const u8).empty;
    defer sparse_args.deinit(allocator);
    try sparse_args.append(allocator, "sparse-checkout");
    try sparse_args.append(allocator, "set");
    for (source.sparse_paths) |path| try sparse_args.append(allocator, path);
    try runGit(allocator, destination, sparse_args.items);
    try runGit(allocator, destination, &.{ "checkout", source.ref_name orelse "HEAD" });
    return gitWorktreeRevision(allocator, destination);
}

fn runGit(allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) !void {
    const stdout = try runGitOutput(allocator, cwd, args);
    allocator.free(stdout);
}

fn runGitOutput(allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) ![]const u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var child_env = try gitChildEnvironment(allocator);
    defer child_env.deinit();

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const run_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv.items,
        .cwd = run_cwd,
        .environ_map = &child_env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(30_000),
            .clock = .awake,
        } },
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }

    std.debug.print("git command failed: git", .{});
    for (args) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n{s}\n{s}\n", .{ result.stdout, result.stderr });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return AddError.GitCommandFailed;
}

fn gitWorktreeRevision(allocator: std.mem.Allocator, destination: []const u8) ![]const u8 {
    const stdout = try runGitOutput(allocator, destination, &.{ "rev-parse", "HEAD" });
    defer allocator.free(stdout);
    const revision = std.mem.trim(u8, stdout, " \t\r\n");
    if (revision.len == 0) return AddError.GitCommandFailed;
    return allocator.dupe(u8, revision);
}

fn gitRemoteRevision(allocator: std.mem.Allocator, source: []const u8, ref_name: ?[]const u8) ![]const u8 {
    if (ref_name) |value| {
        if (isFullGitSha(value)) return allocator.dupe(u8, value);
    }
    const stdout = try runGitOutput(allocator, null, &.{ "ls-remote", source, ref_name orelse "HEAD" });
    defer allocator.free(stdout);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const tab_index = std.mem.indexOfScalar(u8, trimmed, '\t') orelse return AddError.GitCommandFailed;
        const revision = trimmed[0..tab_index];
        if (revision.len == 0) return AddError.GitCommandFailed;
        return allocator.dupe(u8, revision);
    }
    return AddError.GitCommandFailed;
}

fn isFullGitSha(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn installedMarketplaceIsCurrent(
    allocator: std.mem.Allocator,
    destination: []const u8,
    entry: MarketplaceEntry,
    revision: []const u8,
) !bool {
    const marketplace_name = (try validateMarketplaceRootOrNull(allocator, destination)) orelse return false;
    defer allocator.free(marketplace_name);
    if (!std.mem.eql(u8, marketplace_name, entry.name)) return false;
    if (entry.last_revision == null) return false;
    if (!std.mem.eql(u8, entry.last_revision.?, revision)) return false;
    return installedMarketplaceMetadataMatches(allocator, destination, entry, revision);
}

fn installedMarketplaceMetadataMatches(
    allocator: std.mem.Allocator,
    root: []const u8,
    entry: MarketplaceEntry,
    revision: []const u8,
) !bool {
    const path = try installedMarketplaceMetadataPath(allocator, root);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    if (!jsonStringFieldEql(object, "source_type", "git")) return false;
    if (!jsonStringFieldEql(object, "source", entry.source orelse return false)) return false;
    if (!jsonStringFieldEql(object, "revision", revision)) return false;
    if (!jsonOptionalStringFieldEql(object, "ref_name", entry.ref_name)) return false;
    if (!jsonStringArrayFieldEql(object, "sparse_paths", entry.sparse_paths)) return false;
    return true;
}

fn jsonStringFieldEql(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const value = object.get(field) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn jsonOptionalStringFieldEql(object: std.json.ObjectMap, field: []const u8, expected: ?[]const u8) bool {
    const value = object.get(field) orelse return expected == null;
    if (expected) |expected_value| {
        return value == .string and std.mem.eql(u8, value.string, expected_value);
    }
    return value == .null;
}

fn jsonStringArrayFieldEql(object: std.json.ObjectMap, field: []const u8, expected: []const []const u8) bool {
    const value = object.get(field) orelse return expected.len == 0;
    if (value != .array) return false;
    const items = value.array.items;
    if (items.len != expected.len) return false;
    for (items, expected) |item, expected_value| {
        if (item != .string or !std.mem.eql(u8, item.string, expected_value)) return false;
    }
    return true;
}

fn writeInstalledMarketplaceMetadata(
    allocator: std.mem.Allocator,
    root: []const u8,
    entry: MarketplaceEntry,
    revision: []const u8,
) !void {
    const path = try installedMarketplaceMetadataPath(allocator, root);
    defer allocator.free(path);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, "{\n  \"source_type\": \"git\",\n  \"source\": ");
    try appendJsonStringLiteral(allocator, &output, entry.source orelse return AddError.InvalidMarketplaceRoot);
    try output.appendSlice(allocator, ",\n  \"ref_name\": ");
    if (entry.ref_name) |ref_name| {
        try appendJsonStringLiteral(allocator, &output, ref_name);
    } else {
        try output.appendSlice(allocator, "null");
    }
    try output.appendSlice(allocator, ",\n  \"sparse_paths\": [");
    for (entry.sparse_paths, 0..) |sparse_path, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try appendJsonStringLiteral(allocator, &output, sparse_path);
    }
    try output.appendSlice(allocator, "],\n  \"revision\": ");
    try appendJsonStringLiteral(allocator, &output, revision);
    try output.appendSlice(allocator, "\n}\n");

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = output.items });
}

fn installedMarketplaceMetadataPath(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, INSTALLED_MARKETPLACE_METADATA_FILE });
}

fn appendJsonStringLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try output.appendSlice(allocator, json);
}

fn replaceMarketplaceRoot(allocator: std.mem.Allocator, install_root: []const u8, staged_root: []const u8, destination: []const u8) !void {
    const parent = std.fs.path.dirname(destination) orelse return AddError.InvalidMarketplaceInstallDirectory;
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);

    if (!pathExists(destination)) {
        try std.Io.Dir.rename(
            std.Io.Dir.cwd(),
            staged_root,
            std.Io.Dir.cwd(),
            destination,
            std.Io.Threaded.global_single_threaded.io(),
        );
        return;
    }

    const backup_root = try createMarketplaceStagingRoot(allocator, install_root, "marketplace-backup");
    defer allocator.free(backup_root);
    errdefer deleteTreeBestEffort(backup_root);

    try std.Io.Dir.rename(
        std.Io.Dir.cwd(),
        destination,
        std.Io.Dir.cwd(),
        backup_root,
        std.Io.Threaded.global_single_threaded.io(),
    );
    errdefer {
        if (!pathExists(destination)) {
            std.Io.Dir.rename(
                std.Io.Dir.cwd(),
                backup_root,
                std.Io.Dir.cwd(),
                destination,
                std.Io.Threaded.global_single_threaded.io(),
            ) catch {};
        }
    }

    try std.Io.Dir.rename(
        std.Io.Dir.cwd(),
        staged_root,
        std.Io.Dir.cwd(),
        destination,
        std.Io.Threaded.global_single_threaded.io(),
    );
    deleteTreeBestEffort(backup_root);
}

fn gitChildEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var child_env = std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

    try putCurrentEnvIfPresent(&child_env, "PATH");
    try putCurrentEnvIfPresent(&child_env, "HOME");
    try putCurrentEnvIfPresent(&child_env, "USERPROFILE");
    try putCurrentEnvIfPresent(&child_env, "XDG_CONFIG_HOME");
    try putCurrentEnvIfPresent(&child_env, "GIT_CONFIG_GLOBAL");
    try putCurrentEnvIfPresent(&child_env, "GIT_CONFIG_SYSTEM");
    try putCurrentEnvIfPresent(&child_env, "GIT_CONFIG_NOSYSTEM");
    try putCurrentEnvIfPresent(&child_env, "GIT_ALLOW_PROTOCOL");
    try putCurrentEnvIfPresent(&child_env, "GIT_SSH");
    try putCurrentEnvIfPresent(&child_env, "GIT_SSH_COMMAND");
    try putCurrentEnvIfPresent(&child_env, "SSH_AUTH_SOCK");
    try putCurrentEnvIfPresent(&child_env, "SSH_AGENT_PID");
    try putCurrentEnvIfPresent(&child_env, "HTTPS_PROXY");
    try putCurrentEnvIfPresent(&child_env, "HTTP_PROXY");
    try putCurrentEnvIfPresent(&child_env, "ALL_PROXY");
    try putCurrentEnvIfPresent(&child_env, "NO_PROXY");
    try putCurrentEnvIfPresent(&child_env, "https_proxy");
    try putCurrentEnvIfPresent(&child_env, "http_proxy");
    try putCurrentEnvIfPresent(&child_env, "all_proxy");
    try putCurrentEnvIfPresent(&child_env, "no_proxy");
    try putCurrentEnvIfPresent(&child_env, "SSL_CERT_FILE");
    try putCurrentEnvIfPresent(&child_env, "SSL_CERT_DIR");
    try child_env.put("GIT_TERMINAL_PROMPT", "0");
    try child_env.put("GIT_OPTIONAL_LOCKS", "0");
    return child_env;
}

fn putCurrentEnvIfPresent(child_env: *std.process.Environ.Map, comptime name: []const u8) !void {
    const c_name: [*:0]const u8 = name ++ "\x00";
    const value = std.c.getenv(c_name) orelse return;
    try child_env.put(name, std.mem.span(value));
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
            const cloned = try cloneMarketplaceEntry(allocator, entry);
            return cloned;
        }
    }
    return null;
}

fn marketplaceEntryForUpdate(allocator: std.mem.Allocator, bytes: []const u8, update: MarketplaceConfigUpdate) !?MarketplaceEntry {
    const entries = try marketplaceEntries(allocator, bytes);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    for (entries) |entry| {
        if (entryMatchesUpdate(entry, update)) {
            const cloned = try cloneMarketplaceEntry(allocator, entry);
            return cloned;
        }
    }
    return null;
}

fn cloneMarketplaceEntry(allocator: std.mem.Allocator, entry: MarketplaceEntry) !MarketplaceEntry {
    var cloned = MarketplaceEntry{ .name = try allocator.dupe(u8, entry.name) };
    errdefer cloned.deinit(allocator);
    if (entry.last_revision) |value| cloned.last_revision = try allocator.dupe(u8, value);
    if (entry.source_type) |value| cloned.source_type = try allocator.dupe(u8, value);
    if (entry.source) |value| cloned.source = try allocator.dupe(u8, value);
    if (entry.ref_name) |value| cloned.ref_name = try allocator.dupe(u8, value);
    cloned.sparse_paths = try cloneStringList(allocator, entry.sparse_paths);
    return cloned;
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    var copied: usize = 0;
    errdefer {
        for (cloned[0..copied]) |value| allocator.free(value);
    }
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        copied += 1;
    }
    return cloned;
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
            if (tomlStringValueForKey(allocator, trimmed, "last_revision") catch |err| switch (err) {
                error.InvalidTomlString => null,
                else => return err,
            }) |value| {
                if (entry.last_revision) |existing| allocator.free(existing);
                entry.last_revision = value;
            } else if (tomlStringValueForKey(allocator, trimmed, "source_type") catch |err| switch (err) {
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
            } else if (tomlStringValueForKey(allocator, trimmed, "ref") catch |err| switch (err) {
                error.InvalidTomlString => null,
                else => return err,
            }) |value| {
                if (entry.ref_name) |existing| allocator.free(existing);
                entry.ref_name = value;
            } else if (tomlStringArrayValueForKey(allocator, trimmed, "sparse_paths") catch |err| switch (err) {
                error.InvalidTomlString => null,
                else => return err,
            }) |value| {
                for (entry.sparse_paths) |existing| allocator.free(existing);
                if (entry.sparse_paths.len > 0) allocator.free(entry.sparse_paths);
                entry.sparse_paths = value;
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

fn tomlStringArrayValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const []const u8 {
    if (line.len == 0 or line[0] == '[') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs_with_comment = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const rhs = std.mem.trim(u8, stripTomlLineComment(rhs_with_comment), " \t");
    var index: usize = 0;
    skipTomlWhitespace(rhs, &index);
    if (index >= rhs.len or rhs[index] != '[') return null;
    index += 1;

    var values = std.ArrayList([]const u8).empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    while (true) {
        skipTomlWhitespace(rhs, &index);
        if (index >= rhs.len) return error.InvalidTomlString;
        if (rhs[index] == ']') {
            index += 1;
            break;
        }
        const value = (try parseTomlStringAt(allocator, rhs, &index)) orelse return error.InvalidTomlString;
        values.append(allocator, value) catch |err| {
            allocator.free(value);
            return err;
        };

        skipTomlWhitespace(rhs, &index);
        if (index >= rhs.len) return error.InvalidTomlString;
        if (rhs[index] == ',') {
            index += 1;
            continue;
        }
        if (rhs[index] == ']') {
            index += 1;
            break;
        }
        return error.InvalidTomlString;
    }

    skipTomlWhitespace(rhs, &index);
    if (index != rhs.len) return error.InvalidTomlString;
    if (values.items.len == 0) {
        values.deinit(allocator);
        return &.{};
    }
    const owned: []const []const u8 = try values.toOwnedSlice(allocator);
    return owned;
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
    try dir.dir.createDirPath(io, "source/.agents/plugins");
    try dir.dir.writeFile(io, .{
        .sub_path = "source/.agents/plugins/marketplace.json",
        .data = "{\"name\":\"debug\",\"plugins\":[]}",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
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

test "configured marketplace parser keeps hash inside source strings" {
    const allocator = std.testing.allocator;
    const bytes =
        \\[marketplaces.debug]
        \\source_type = "local"
        \\source = "/tmp/source#hash" # comment
    ;

    const roots = try configuredMarketplaceRoots(allocator, "/tmp/codex-home", bytes);
    defer {
        for (roots) |*root| root.deinit(allocator);
        allocator.free(roots);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings("/tmp/source#hash", roots[0].root);
}
