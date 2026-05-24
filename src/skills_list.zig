const std = @import("std");

const config = @import("config.zig");
const env = @import("env.zig");
const plugin_config = @import("plugin_config.zig");
const product_restriction = @import("product_restriction.zig");

pub const ExtraRootsForCwd = struct {
    cwd: []const u8,
    roots: []const []const u8,
};

pub const SkillError = struct {
    path: []const u8,
    message: []const u8,

    fn deinit(self: SkillError, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
    }
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    short_description: ?[]const u8,
    interface: ?SkillInterface,
    dependencies: ?SkillDependencies,
    path: []const u8,
    scope: []const u8,
    enabled: bool,

    fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.short_description) |value| allocator.free(value);
        if (self.interface) |value| value.deinit(allocator);
        if (self.dependencies) |value| value.deinit(allocator);
        allocator.free(self.path);
        allocator.free(self.scope);
    }
};

pub const SkillInterface = struct {
    display_name: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    icon_small: ?[]const u8 = null,
    icon_large: ?[]const u8 = null,
    brand_color: ?[]const u8 = null,
    default_prompt: ?[]const u8 = null,

    fn deinit(self: SkillInterface, allocator: std.mem.Allocator) void {
        if (self.display_name) |value| allocator.free(value);
        if (self.short_description) |value| allocator.free(value);
        if (self.icon_small) |value| allocator.free(value);
        if (self.icon_large) |value| allocator.free(value);
        if (self.brand_color) |value| allocator.free(value);
        if (self.default_prompt) |value| allocator.free(value);
    }
};

pub const SkillDependencies = struct {
    tools: []SkillToolDependency,

    fn deinit(self: SkillDependencies, allocator: std.mem.Allocator) void {
        for (self.tools) |tool| tool.deinit(allocator);
        allocator.free(self.tools);
    }
};

pub const SkillToolDependency = struct {
    kind: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,

    fn deinit(self: SkillToolDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.value);
        if (self.description) |value| allocator.free(value);
        if (self.transport) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

pub const Entry = struct {
    cwd: []const u8,
    skills: []Skill,
    errors: []SkillError,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        for (self.skills) |skill| skill.deinit(allocator);
        allocator.free(self.skills);
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

pub const PluginSkillsResult = struct {
    skills: []Skill,

    pub fn deinit(self: PluginSkillsResult, allocator: std.mem.Allocator) void {
        for (self.skills) |skill| skill.deinit(allocator);
        allocator.free(self.skills);
    }
};

const Root = struct {
    path: []const u8,
    scope: []const u8,
    skill_name_prefix: ?[]const u8 = null,
};

pub const ConfigSelector = union(enum) {
    name: []const u8,
    path: []const u8,
};

const SkillConfigRule = struct {
    selector: ConfigSelector,
    enabled: bool,

    fn deinit(self: SkillConfigRule, allocator: std.mem.Allocator) void {
        deinitSelector(self.selector, allocator);
    }
};

const SkillConfigRules = struct {
    entries: []SkillConfigRule,
    owned: bool = false,

    fn deinit(self: SkillConfigRules, allocator: std.mem.Allocator) void {
        for (self.entries) |rule| rule.deinit(allocator);
        if (self.owned) allocator.free(self.entries);
    }
};

const ParsedSkillConfigBlock = struct {
    selector: ConfigSelector,
    enabled: bool,

    fn deinit(self: ParsedSkillConfigBlock, allocator: std.mem.Allocator) void {
        deinitSelector(self.selector, allocator);
    }
};

const SkillFrontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
};

const SkillFileMetadata = struct {
    interface: ?SkillInterface = null,
    dependencies: ?SkillDependencies = null,
    product_allowed: bool = true,

    fn deinit(self: SkillFileMetadata, allocator: std.mem.Allocator) void {
        if (self.interface) |value| value.deinit(allocator);
        if (self.dependencies) |value| value.deinit(allocator);
    }
};

const PartialSkillTool = struct {
    kind: ?[]const u8 = null,
    value: ?[]const u8 = null,
    description: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,

    fn deinit(self: PartialSkillTool, allocator: std.mem.Allocator) void {
        if (self.kind) |value| allocator.free(value);
        if (self.value) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.transport) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
    }
};

const SKILL_METADATA_DIR = "agents";
const SKILL_METADATA_FILENAME = "openai.yaml";
const MAX_SKILL_NAME_LEN = 64;
const MAX_SKILL_DESCRIPTION_LEN = 1024;

pub fn list(
    allocator: std.mem.Allocator,
    cwd_inputs: []const []const u8,
    extra_roots_by_cwd: []const ExtraRootsForCwd,
) !Result {
    return listForProduct(allocator, cwd_inputs, extra_roots_by_cwd, .codex);
}

pub fn listForProduct(
    allocator: std.mem.Allocator,
    cwd_inputs: []const []const u8,
    extra_roots_by_cwd: []const ExtraRootsForCwd,
    restriction_product: ?product_restriction.Product,
) !Result {
    const resolved_cwds = if (cwd_inputs.len == 0)
        try defaultCwdList(allocator)
    else
        try cloneStrings(allocator, cwd_inputs);
    defer freeStringList(allocator, resolved_cwds);

    const skill_config_rules = try loadSkillConfigRules(allocator);
    defer skill_config_rules.deinit(allocator);

    var entries = try std.ArrayList(Entry).initCapacity(allocator, resolved_cwds.len);
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    for (resolved_cwds) |cwd| {
        const entry = try listForCwd(allocator, cwd, extra_roots_by_cwd, skill_config_rules, restriction_product);
        try entries.append(allocator, entry);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn listPluginSkills(
    allocator: std.mem.Allocator,
    plugin_root: []const u8,
    skill_name_prefix: []const u8,
    config_bytes: []const u8,
) !PluginSkillsResult {
    return listPluginSkillsForProduct(allocator, plugin_root, skill_name_prefix, config_bytes, .codex);
}

pub fn listPluginSkillsForProduct(
    allocator: std.mem.Allocator,
    plugin_root: []const u8,
    skill_name_prefix: []const u8,
    config_bytes: []const u8,
    restriction_product: ?product_restriction.Product,
) !PluginSkillsResult {
    var skills = std.ArrayList(Skill).empty;
    errdefer {
        for (skills.items) |skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }
    var errors = std.ArrayList(SkillError).empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }

    const skills_root = try std.fs.path.join(allocator, &.{ plugin_root, "skills" });
    defer allocator.free(skills_root);
    const prefix = try allocator.dupe(u8, skill_name_prefix);
    defer allocator.free(prefix);
    try scanSkillRoot(
        allocator,
        .{
            .path = skills_root,
            .scope = "user",
            .skill_name_prefix = prefix,
        },
        restriction_product,
        &skills,
        &errors,
    );

    const rules = try skillConfigRulesFromBytes(allocator, config_bytes);
    defer rules.deinit(allocator);
    applySkillConfigRules(skills.items, rules);

    return .{ .skills = try skills.toOwnedSlice(allocator) };
}

fn defaultCwdList(allocator: std.mem.Allocator) ![]const []const u8 {
    const cwd = try realPathOwnedAlloc(allocator, ".");
    errdefer allocator.free(cwd);

    const cwds = try allocator.alloc([]const u8, 1);
    cwds[0] = cwd;
    return cwds;
}

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
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

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn listForCwd(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    extra_roots_by_cwd: []const ExtraRootsForCwd,
    skill_config_rules: SkillConfigRules,
    restriction_product: ?product_restriction.Product,
) !Entry {
    var skills = std.ArrayList(Skill).empty;
    errdefer {
        for (skills.items) |skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }

    var errors = std.ArrayList(SkillError).empty;
    errdefer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }

    var roots = std.ArrayList(Root).empty;
    defer {
        for (roots.items) |root| {
            allocator.free(root.path);
            if (root.skill_name_prefix) |value| allocator.free(value);
        }
        roots.deinit(allocator);
    }
    try appendRepoSkillRoots(allocator, &roots, cwd);
    try appendCodexHomeSkillRoot(allocator, &roots);
    try appendPluginSkillRoots(allocator, &roots);
    try appendExtraSkillRoots(allocator, &roots, cwd, extra_roots_by_cwd);

    for (roots.items) |root| {
        try scanSkillRoot(allocator, root, restriction_product, &skills, &errors);
    }
    applySkillConfigRules(skills.items, skill_config_rules);

    return .{
        .cwd = try allocator.dupe(u8, cwd),
        .skills = try skills.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn appendRepoSkillRoots(allocator: std.mem.Allocator, roots: *std.ArrayList(Root), cwd: []const u8) !void {
    try roots.append(allocator, .{ .path = try std.fs.path.join(allocator, &.{ cwd, ".codex", "skills" }), .scope = "repo" });
    try roots.append(allocator, .{ .path = try std.fs.path.join(allocator, &.{ cwd, ".agents", "skills" }), .scope = "repo" });
}

fn appendCodexHomeSkillRoot(allocator: std.mem.Allocator, roots: *std.ArrayList(Root)) !void {
    const codex_home = resolveCodexHome(allocator) catch return;
    defer allocator.free(codex_home);
    try roots.append(allocator, .{ .path = try std.fs.path.join(allocator, &.{ codex_home, "skills" }), .scope = "user" });
}

fn appendPluginSkillRoots(allocator: std.mem.Allocator, roots: *std.ArrayList(Root)) !void {
    const codex_home = resolveCodexHome(allocator) catch return;
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const bytes = config.readConfigTomlFile(allocator, config_path) catch return;
    defer if (bytes) |value| allocator.free(value);
    const contents = bytes orelse return;
    if (!plugin_config.pluginsFeatureEnabled(contents)) return;

    const plugin_ids = try plugin_config.enabledPluginIds(allocator, contents);
    defer plugin_config.freeStringList(allocator, plugin_ids);
    for (plugin_ids) |plugin_id| {
        const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse continue;
        defer allocator.free(plugin_root);
        const skills_path = try std.fs.path.join(allocator, &.{ plugin_root, "skills" });
        errdefer allocator.free(skills_path);
        const skill_name_prefix = try pluginSkillNamePrefix(allocator, plugin_root, plugin_id);
        errdefer allocator.free(skill_name_prefix);
        try roots.append(allocator, .{
            .path = skills_path,
            .scope = "user",
            .skill_name_prefix = skill_name_prefix,
        });
    }
}

fn pluginSkillNamePrefix(allocator: std.mem.Allocator, plugin_root: []const u8, plugin_id: []const u8) ![]const u8 {
    return plugin_config.pluginSkillNamePrefixForRoot(allocator, plugin_root, plugin_id);
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| return value;

    const home = (try env.getOwned(allocator, "HOME")) orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn appendExtraSkillRoots(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList(Root),
    cwd: []const u8,
    extra_roots_by_cwd: []const ExtraRootsForCwd,
) !void {
    for (extra_roots_by_cwd) |entry| {
        if (!std.mem.eql(u8, entry.cwd, cwd)) continue;
        for (entry.roots) |root| {
            try roots.append(allocator, .{ .path = try allocator.dupe(u8, root), .scope = "user" });
        }
    }
}

fn scanSkillRoot(
    allocator: std.mem.Allocator,
    root: Root,
    restriction_product: ?product_restriction.Product,
    skills: *std.ArrayList(Skill),
    errors: *std.ArrayList(SkillError),
) !void {
    try scanSkillDirectoryIfPresent(allocator, root.path, root.scope, root.skill_name_prefix, restriction_product, skills, errors);

    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root.path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => {
            try appendSkillError(allocator, errors, root.path, "failed to scan skill root");
            return;
        },
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try std.fs.path.join(allocator, &.{ root.path, entry.name });
        defer allocator.free(child);
        try scanSkillDirectoryIfPresent(allocator, child, root.scope, root.skill_name_prefix, restriction_product, skills, errors);
    }
}

fn scanSkillDirectoryIfPresent(
    allocator: std.mem.Allocator,
    directory: []const u8,
    scope: []const u8,
    skill_name_prefix: ?[]const u8,
    restriction_product: ?product_restriction.Product,
    skills: *std.ArrayList(Skill),
    errors: *std.ArrayList(SkillError),
) !void {
    const skill_path = try std.fs.path.join(allocator, &.{ directory, "SKILL.md" });
    defer allocator.free(skill_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), skill_path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendSkillError(allocator, errors, skill_path, "failed to read SKILL.md");
            return;
        },
    };
    defer allocator.free(bytes);

    const metadata = parseSkillFrontmatter(bytes);
    const base_name = metadata.name orelse std.fs.path.basename(directory);
    const description = metadata.description orelse "";
    const name = if (skill_name_prefix) |prefix|
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, base_name })
    else
        try allocator.dupe(u8, base_name);
    errdefer allocator.free(name);

    const normalized_skill_path = try normalizePathAlloc(allocator, skill_path);
    errdefer allocator.free(normalized_skill_path);

    const metadata_directory = std.fs.path.dirname(normalized_skill_path) orelse directory;
    var file_metadata = try loadSkillFileMetadata(allocator, metadata_directory, restriction_product);
    errdefer file_metadata.deinit(allocator);
    if (!file_metadata.product_allowed) {
        file_metadata.deinit(allocator);
        allocator.free(normalized_skill_path);
        allocator.free(name);
        return;
    }
    if (metadata.description == null) {
        try appendSkillError(allocator, errors, skill_path, "SKILL.md is missing description frontmatter");
    }

    try skills.append(allocator, .{
        .name = name,
        .description = try allocator.dupe(u8, description),
        .short_description = if (metadata.short_description) |value| try allocator.dupe(u8, value) else null,
        .interface = file_metadata.interface,
        .dependencies = file_metadata.dependencies,
        .path = normalized_skill_path,
        .scope = try allocator.dupe(u8, scope),
        .enabled = true,
    });
    file_metadata = .{};
}

fn applySkillConfigRules(skills: []Skill, skill_config_rules: SkillConfigRules) void {
    for (skills) |*skill| {
        var enabled = true;
        for (skill_config_rules.entries) |rule| {
            switch (rule.selector) {
                .name => |name| {
                    if (std.mem.eql(u8, skill.name, name)) enabled = rule.enabled;
                },
                .path => |path| {
                    if (std.mem.eql(u8, skill.path, path)) enabled = rule.enabled;
                },
            }
        }
        skill.enabled = enabled;
    }
}

fn loadSkillConfigRules(allocator: std.mem.Allocator) !SkillConfigRules {
    const codex_home = resolveCodexHome(allocator) catch return .{ .entries = &.{} };
    defer allocator.free(codex_home);
    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);

    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var rules = std.ArrayList(SkillConfigRule).empty;
    errdefer {
        for (rules.items) |rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    if (config_bytes) |bytes| {
        try appendSkillConfigRulesFromToml(allocator, bytes, &rules);
    }

    return .{ .entries = try rules.toOwnedSlice(allocator), .owned = true };
}

fn skillConfigRulesFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !SkillConfigRules {
    var rules = std.ArrayList(SkillConfigRule).empty;
    errdefer {
        for (rules.items) |rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    try appendSkillConfigRulesFromToml(allocator, bytes, &rules);
    return .{ .entries = try rules.toOwnedSlice(allocator), .owned = true };
}

fn appendSkillConfigRulesFromToml(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    rules: *std.ArrayList(SkillConfigRule),
) !void {
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    var in_skill_config = false;

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line = bytes[start..end];
        const has_newline = end < bytes.len;
        start = if (has_newline) end + 1 else bytes.len;

        if (isTomlHeader(line)) {
            if (in_skill_config) {
                try appendRuleFromBlock(allocator, block.items, rules);
                block.clearRetainingCapacity();
                in_skill_config = false;
            }
            if (isSkillConfigHeader(line)) {
                in_skill_config = true;
                try appendLine(allocator, &block, line, has_newline);
            }
            continue;
        }

        if (in_skill_config) {
            try appendLine(allocator, &block, line, has_newline);
        }
    }

    if (in_skill_config) {
        try appendRuleFromBlock(allocator, block.items, rules);
    }
}

fn appendRuleFromBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    rules: *std.ArrayList(SkillConfigRule),
) !void {
    var parsed = (try parseSkillConfigBlock(allocator, block)) orelse return;
    errdefer parsed.deinit(allocator);
    try rules.append(allocator, .{
        .selector = parsed.selector,
        .enabled = parsed.enabled,
    });
}

pub fn updateSkillConfigToml(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    selector: ConfigSelector,
    enabled: bool,
) ![]const u8 {
    const normalized_selector = try normalizeSelector(allocator, selector);
    defer deinitSelector(normalized_selector, allocator);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    var in_skill_config = false;

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line = bytes[start..end];
        const has_newline = end < bytes.len;
        start = if (has_newline) end + 1 else bytes.len;

        if (isTomlHeader(line)) {
            if (in_skill_config) {
                try flushSkillConfigBlock(allocator, &output, block.items, normalized_selector);
                block.clearRetainingCapacity();
                in_skill_config = false;
            }
            if (isSkillConfigHeader(line)) {
                in_skill_config = true;
                try appendLine(allocator, &block, line, has_newline);
            } else {
                try appendLine(allocator, &output, line, has_newline);
            }
            continue;
        }

        if (in_skill_config) {
            try appendLine(allocator, &block, line, has_newline);
        } else {
            try appendLine(allocator, &output, line, has_newline);
        }
    }

    if (in_skill_config) {
        try flushSkillConfigBlock(allocator, &output, block.items, normalized_selector);
    }

    if (!enabled) {
        try appendSkillConfigBlock(allocator, &output, normalized_selector);
    }

    return output.toOwnedSlice(allocator);
}

fn flushSkillConfigBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    block: []const u8,
    selector: ConfigSelector,
) !void {
    if (try parseSkillConfigBlock(allocator, block)) |parsed| {
        defer parsed.deinit(allocator);
        if (selectorsEqual(parsed.selector, selector)) return;
    }
    try output.appendSlice(allocator, block);
}

fn appendSkillConfigBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    selector: ConfigSelector,
) !void {
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, "[[skills.config]]\n");
    switch (selector) {
        .name => |name| {
            try output.appendSlice(allocator, "name = ");
            try appendTomlStringLiteral(allocator, output, name);
            try output.append(allocator, '\n');
        },
        .path => |path| {
            try output.appendSlice(allocator, "path = ");
            try appendTomlStringLiteral(allocator, output, path);
            try output.append(allocator, '\n');
        },
    }
    try output.appendSlice(allocator, "enabled = false\n");
}

fn parseSkillConfigBlock(allocator: std.mem.Allocator, block: []const u8) !?ParsedSkillConfigBlock {
    var path: ?[]const u8 = null;
    defer if (path) |value| allocator.free(value);
    var name: ?[]const u8 = null;
    defer if (name) |value| allocator.free(value);
    var enabled: ?bool = null;

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;

        if (try tomlStringValueForKey(allocator, line, "path")) |value| {
            if (path) |previous| allocator.free(previous);
            path = value;
            continue;
        }
        if (try tomlStringValueForKey(allocator, line, "name")) |value| {
            if (name) |previous| allocator.free(previous);
            name = value;
            continue;
        }
        if (tomlBoolValueForKey(line, "enabled")) |value| {
            enabled = value;
        }
    }

    const effective_enabled = enabled orelse return null;
    const selector = switch (classifySelector(path, name)) {
        .path => |value| blk: {
            if (!std.fs.path.isAbsolute(value)) return null;
            break :blk ConfigSelector{ .path = try normalizePathAlloc(allocator, value) };
        },
        .name => |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0) return null;
            break :blk ConfigSelector{ .name = try allocator.dupe(u8, trimmed) };
        },
        .invalid => return null,
    };
    errdefer deinitSelector(selector, allocator);

    return .{
        .selector = selector,
        .enabled = effective_enabled,
    };
}

const SelectorClassification = union(enum) {
    path: []const u8,
    name: []const u8,
    invalid,
};

fn classifySelector(path: ?[]const u8, name: ?[]const u8) SelectorClassification {
    if (path != null and name == null) return .{ .path = path.? };
    if (path == null and name != null) return .{ .name = name.? };
    return .invalid;
}

fn normalizeSelector(allocator: std.mem.Allocator, selector: ConfigSelector) !ConfigSelector {
    return switch (selector) {
        .name => |name| blk: {
            const trimmed = std.mem.trim(u8, name, " \t\r\n");
            break :blk .{ .name = try allocator.dupe(u8, trimmed) };
        },
        .path => |path| .{ .path = try normalizePathAlloc(allocator, path) },
    };
}

fn normalizePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return realPathOwnedAlloc(allocator, path) catch try allocator.dupe(u8, path);
}

fn realPathOwnedAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn deinitSelector(selector: ConfigSelector, allocator: std.mem.Allocator) void {
    switch (selector) {
        .name => |name| allocator.free(name),
        .path => |path| allocator.free(path),
    }
}

fn selectorsEqual(a: ConfigSelector, b: ConfigSelector) bool {
    return switch (a) {
        .name => |a_name| switch (b) {
            .name => |b_name| std.mem.eql(u8, a_name, b_name),
            .path => false,
        },
        .path => |a_path| switch (b) {
            .name => false,
            .path => |b_path| std.mem.eql(u8, a_path, b_path),
        },
    };
}

fn isTomlHeader(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len > 0 and trimmed[0] == '[';
}

fn isSkillConfigHeader(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, trimmed, "[[skills.config]]");
}

fn appendLine(allocator: std.mem.Allocator, output: *std.ArrayList(u8), line: []const u8, has_newline: bool) !void {
    try output.appendSlice(allocator, line);
    if (has_newline) try output.append(allocator, '\n');
}

fn tomlStringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlStringLiteral(allocator, rhs);
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

fn parseTomlStringLiteral(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const rhs = std.mem.trim(u8, raw, " \t\r");
    if (rhs.len < 2 or rhs[0] != '"') return null;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 1;
    while (index < rhs.len) : (index += 1) {
        const byte = rhs[index];
        if (byte == '"') {
            return try output.toOwnedSlice(allocator);
        }
        if (byte != '\\') {
            try output.append(allocator, byte);
            continue;
        }

        index += 1;
        if (index >= rhs.len) return error.InvalidTomlString;
        const escaped: u8 = switch (rhs[index]) {
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

fn parseSkillFrontmatter(bytes: []const u8) SkillFrontmatter {
    var metadata = SkillFrontmatter{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return metadata;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "---")) return metadata;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, "---")) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = trimFrontmatterValue(line[colon + 1 ..]);
        if (std.mem.eql(u8, key, "name")) {
            metadata.name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            metadata.description = value;
        } else if (std.mem.eql(u8, key, "short_description")) {
            metadata.short_description = value;
        }
    }
    return metadata;
}

fn trimFrontmatterValue(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r");
    if (value.len >= 2 and value[0] == value[value.len - 1] and (value[0] == '"' or value[0] == '\'')) {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn loadSkillFileMetadata(allocator: std.mem.Allocator, directory: []const u8, restriction_product: ?product_restriction.Product) !SkillFileMetadata {
    const metadata_path = try std.fs.path.join(allocator, &.{ directory, SKILL_METADATA_DIR, SKILL_METADATA_FILENAME });
    defer allocator.free(metadata_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), metadata_path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    defer allocator.free(bytes);

    if (try parseSkillMetadataJson(allocator, bytes, directory, restriction_product)) |metadata| return metadata;
    return try parseSkillMetadataYaml(allocator, bytes, directory, restriction_product);
}

fn parseSkillMetadataJson(allocator: std.mem.Allocator, bytes: []const u8, directory: []const u8, restriction_product: ?product_restriction.Product) !?SkillFileMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    var metadata = SkillFileMetadata{};
    errdefer metadata.deinit(allocator);
    metadata.interface = try parseSkillInterfaceJson(allocator, parsed.value.object.get("interface"), directory);
    metadata.dependencies = try parseSkillDependenciesJson(allocator, parsed.value.object.get("dependencies"));
    metadata.product_allowed = skillPolicyJsonAllowsProduct(parsed.value.object.get("policy"), restriction_product);
    return metadata;
}

fn parseSkillInterfaceJson(allocator: std.mem.Allocator, value_opt: ?std.json.Value, directory: []const u8) !?SkillInterface {
    const value = value_opt orelse return null;
    if (value != .object) return null;
    var interface = SkillInterface{};
    errdefer interface.deinit(allocator);
    interface.display_name = try ownedSanitizedString(allocator, jsonStringField(value.object, "display_name"), MAX_SKILL_NAME_LEN);
    interface.short_description = try ownedSanitizedString(allocator, jsonStringField(value.object, "short_description"), MAX_SKILL_DESCRIPTION_LEN);
    interface.icon_small = try ownedIconPath(allocator, directory, jsonStringField(value.object, "icon_small"));
    interface.icon_large = try ownedIconPath(allocator, directory, jsonStringField(value.object, "icon_large"));
    interface.brand_color = try ownedBrandColor(allocator, jsonStringField(value.object, "brand_color"));
    interface.default_prompt = try ownedSanitizedString(allocator, jsonStringField(value.object, "default_prompt"), MAX_SKILL_DESCRIPTION_LEN);
    if (skillInterfaceIsEmpty(interface)) return null;
    return interface;
}

fn parseSkillDependenciesJson(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !?SkillDependencies {
    const value = value_opt orelse return null;
    if (value != .object) return null;
    const tools_value = value.object.get("tools") orelse return null;
    if (tools_value != .array) return null;

    var tools = std.ArrayList(SkillToolDependency).empty;
    errdefer {
        for (tools.items) |tool| tool.deinit(allocator);
        tools.deinit(allocator);
    }
    for (tools_value.array.items) |item| {
        if (item != .object) continue;
        if (try skillToolDependencyFromJson(allocator, item.object)) |tool| {
            try tools.append(allocator, tool);
        }
    }
    if (tools.items.len == 0) return null;
    return .{ .tools = try tools.toOwnedSlice(allocator) };
}

fn skillToolDependencyFromJson(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SkillToolDependency {
    var tool = PartialSkillTool{};
    errdefer tool.deinit(allocator);
    tool.kind = try ownedSanitizedString(allocator, jsonStringField(object, "type"), MAX_SKILL_NAME_LEN);
    tool.value = try ownedSanitizedString(allocator, jsonStringField(object, "value"), MAX_SKILL_DESCRIPTION_LEN);
    tool.description = try ownedSanitizedString(allocator, jsonStringField(object, "description"), MAX_SKILL_DESCRIPTION_LEN);
    tool.transport = try ownedSanitizedString(allocator, jsonStringField(object, "transport"), MAX_SKILL_NAME_LEN);
    tool.command = try ownedSanitizedString(allocator, jsonStringField(object, "command"), MAX_SKILL_DESCRIPTION_LEN);
    tool.url = try ownedSanitizedString(allocator, jsonStringField(object, "url"), MAX_SKILL_DESCRIPTION_LEN);
    return takePartialSkillTool(allocator, &tool);
}

const SkillMetadataYamlSection = enum { none, interface, dependencies, tools, policy, policy_products };

fn parseSkillMetadataYaml(allocator: std.mem.Allocator, bytes: []const u8, directory: []const u8, restriction_product: ?product_restriction.Product) !SkillFileMetadata {
    var metadata = SkillFileMetadata{};
    errdefer metadata.deinit(allocator);
    var interface = SkillInterface{};
    errdefer interface.deinit(allocator);
    var tools = std.ArrayList(SkillToolDependency).empty;
    errdefer {
        for (tools.items) |tool| tool.deinit(allocator);
        tools.deinit(allocator);
    }
    var current_tool = PartialSkillTool{};
    defer current_tool.deinit(allocator);
    var section: SkillMetadataYamlSection = .none;
    var policy_products = SkillProductPolicyAccumulator{};

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line_with_cr| {
        const raw_line = if (std.mem.endsWith(u8, raw_line_with_cr, "\r"))
            raw_line_with_cr[0 .. raw_line_with_cr.len - 1]
        else
            raw_line_with_cr;
        const trimmed = std.mem.trim(u8, stripYamlInlineComment(raw_line), " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = leadingSpaceCount(raw_line);

        if (indent == 0) {
            try appendPartialSkillTool(allocator, &tools, &current_tool);
            if (std.mem.eql(u8, trimmed, "interface:")) {
                section = .interface;
            } else if (std.mem.eql(u8, trimmed, "dependencies:")) {
                section = .dependencies;
            } else if (std.mem.eql(u8, trimmed, "policy:")) {
                section = .policy;
            } else if (parseYamlKeyValue(trimmed)) |entry| {
                section = .none;
                if (std.mem.eql(u8, entry.key, "policy")) {
                    parseYamlPolicyInline(&policy_products, restriction_product, entry.value);
                }
            } else {
                section = .none;
            }
            continue;
        }

        switch (section) {
            .interface => {
                if (parseYamlKeyValue(trimmed)) |entry| {
                    try setSkillInterfaceField(allocator, &interface, directory, entry.key, entry.value);
                }
            },
            .dependencies => {
                if (std.mem.eql(u8, trimmed, "tools:")) section = .tools;
            },
            .tools => {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    try appendPartialSkillTool(allocator, &tools, &current_tool);
                    if (parseYamlKeyValue(std.mem.trim(u8, trimmed[2..], " \t"))) |entry| {
                        try setPartialToolField(allocator, &current_tool, entry.key, entry.value);
                    }
                } else if (parseYamlKeyValue(trimmed)) |entry| {
                    try setPartialToolField(allocator, &current_tool, entry.key, entry.value);
                }
            },
            .policy => {
                section = parseYamlPolicyLine(&policy_products, restriction_product, trimmed);
            },
            .policy_products => {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    addYamlPolicyProduct(&policy_products, restriction_product, std.mem.trim(u8, trimmed[2..], " \t"));
                } else {
                    section = parseYamlPolicyLine(&policy_products, restriction_product, trimmed);
                }
            },
            .none => {},
        }
    }
    try appendPartialSkillTool(allocator, &tools, &current_tool);

    if (!skillInterfaceIsEmpty(interface)) {
        metadata.interface = interface;
        interface = .{};
    }
    if (tools.items.len > 0) {
        metadata.dependencies = .{ .tools = try tools.toOwnedSlice(allocator) };
    }
    metadata.product_allowed = policy_products.allows(restriction_product);
    return metadata;
}

const SkillProductPolicyAccumulator = struct {
    has_products: bool = false,
    count: usize = 0,
    matched: bool = false,
    invalid: bool = false,

    fn allows(self: SkillProductPolicyAccumulator, restriction_product: ?product_restriction.Product) bool {
        if (self.invalid) return true;
        if (!self.has_products) return true;
        if (self.count == 0) return true;
        return restriction_product != null and self.matched;
    }
};

fn parseYamlPolicyLine(accumulator: *SkillProductPolicyAccumulator, restriction_product: ?product_restriction.Product, trimmed: []const u8) SkillMetadataYamlSection {
    if (std.mem.eql(u8, trimmed, "products:")) {
        accumulator.has_products = true;
        return .policy_products;
    }
    if (parseYamlKeyValue(trimmed)) |entry| {
        if (std.mem.eql(u8, entry.key, "products")) {
            accumulator.has_products = true;
            addYamlPolicyProducts(accumulator, restriction_product, entry.value);
        }
    }
    return .policy;
}

fn skillPolicyJsonAllowsProduct(policy_value: ?std.json.Value, restriction_product: ?product_restriction.Product) bool {
    const policy = policy_value orelse return true;
    if (policy == .null) return true;
    if (policy != .object) return true;
    const products = policy.object.get("products") orelse return true;
    if (products == .null) return true;
    if (products != .array) return true;
    if (products.array.items.len == 0) return true;
    var product_count: usize = 0;
    var matched = false;
    for (products.array.items) |item| {
        if (item != .string) return true;
        const item_product = product_restriction.fromName(item.string) orelse return true;
        product_count += 1;
        if (restriction_product) |product| {
            if (item_product == product) matched = true;
        }
    }
    if (product_count == 0) return true;
    return restriction_product != null and matched;
}

fn addYamlPolicyProducts(accumulator: *SkillProductPolicyAccumulator, restriction_product: ?product_restriction.Product, raw: []const u8) void {
    const trimmed = std.mem.trim(u8, stripYamlInlineComment(raw), " \t\r");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        var values = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
        while (values.next()) |value| {
            addYamlPolicyProduct(accumulator, restriction_product, value);
        }
        return;
    }
    const value = trimFrontmatterValue(trimmed);
    if (value.len == 0 or isYamlNullScalar(value)) return;
    accumulator.invalid = true;
}

fn parseYamlPolicyInline(accumulator: *SkillProductPolicyAccumulator, restriction_product: ?product_restriction.Product, raw: []const u8) void {
    const trimmed = std.mem.trim(u8, stripYamlInlineComment(raw), " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;
    const inner = trimmed[1 .. trimmed.len - 1];

    var index: usize = 0;
    while (index < inner.len) {
        while (index < inner.len and (std.ascii.isWhitespace(inner[index]) or inner[index] == ',')) : (index += 1) {}
        if (index >= inner.len) break;

        const key_start = index;
        if (inner[index] == '"' or inner[index] == '\'') {
            const quote = inner[index];
            index += 1;
            while (index < inner.len and inner[index] != quote) : (index += 1) {}
            if (index < inner.len) index += 1;
        } else {
            while (index < inner.len and inner[index] != ':' and inner[index] != ',' and !std.ascii.isWhitespace(inner[index])) : (index += 1) {}
        }
        const key = trimFrontmatterValue(std.mem.trim(u8, inner[key_start..index], " \t\r"));

        while (index < inner.len and std.ascii.isWhitespace(inner[index])) : (index += 1) {}
        if (index >= inner.len or inner[index] != ':') {
            while (index < inner.len and inner[index] != ',') : (index += 1) {}
            continue;
        }
        index += 1;
        while (index < inner.len and std.ascii.isWhitespace(inner[index])) : (index += 1) {}

        const value_start = index;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var quote: ?u8 = null;
        while (index < inner.len) : (index += 1) {
            const byte = inner[index];
            if (quote) |active_quote| {
                if (byte == active_quote and (index == value_start or inner[index - 1] != '\\')) quote = null;
                continue;
            }
            if (byte == '"' or byte == '\'') {
                quote = byte;
            } else if (byte == '[') {
                bracket_depth += 1;
            } else if (byte == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
            } else if (byte == '{') {
                brace_depth += 1;
            } else if (byte == '}') {
                if (brace_depth > 0) brace_depth -= 1;
            } else if (byte == ',' and bracket_depth == 0 and brace_depth == 0) {
                break;
            }
        }

        if (std.mem.eql(u8, key, "products")) {
            accumulator.has_products = true;
            addYamlPolicyProducts(accumulator, restriction_product, inner[value_start..index]);
        }
    }
}

fn addYamlPolicyProduct(accumulator: *SkillProductPolicyAccumulator, restriction_product: ?product_restriction.Product, raw: []const u8) void {
    var value = std.mem.trim(u8, stripYamlInlineComment(raw), " \t\r");
    value = trimFrontmatterValue(value);
    if (value.len == 0 or isYamlNullScalar(value)) return;
    accumulator.has_products = true;
    const value_product = product_restriction.fromName(value) orelse {
        accumulator.invalid = true;
        return;
    };
    accumulator.count += 1;
    const product = restriction_product orelse return;
    if (value_product == product) accumulator.matched = true;
}

fn isYamlNullScalar(value: []const u8) bool {
    return std.mem.eql(u8, value, "~") or std.ascii.eqlIgnoreCase(value, "null");
}

const YamlKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseYamlKeyValue(line: []const u8) ?YamlKeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (key.len == 0) return null;
    const value = trimFrontmatterValue(stripYamlInlineComment(line[colon + 1 ..]));
    if (value.len == 0) return null;
    return .{ .key = key, .value = value };
}

fn stripYamlInlineComment(raw: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (raw, 0..) |byte, index| {
        if (quote) |active_quote| {
            if (byte == active_quote and (index == 0 or raw[index - 1] != '\\')) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == '#' and (index == 0 or std.ascii.isWhitespace(raw[index - 1]))) {
            return std.mem.trim(u8, raw[0..index], " \t\r");
        }
    }
    return raw;
}

fn setSkillInterfaceField(
    allocator: std.mem.Allocator,
    interface: *SkillInterface,
    directory: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    if (std.mem.eql(u8, key, "display_name")) {
        replaceOptionalString(allocator, &interface.display_name, try ownedSanitizedString(allocator, value, MAX_SKILL_NAME_LEN));
    } else if (std.mem.eql(u8, key, "short_description")) {
        replaceOptionalString(allocator, &interface.short_description, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    } else if (std.mem.eql(u8, key, "icon_small")) {
        replaceOptionalString(allocator, &interface.icon_small, try ownedIconPath(allocator, directory, value));
    } else if (std.mem.eql(u8, key, "icon_large")) {
        replaceOptionalString(allocator, &interface.icon_large, try ownedIconPath(allocator, directory, value));
    } else if (std.mem.eql(u8, key, "brand_color")) {
        replaceOptionalString(allocator, &interface.brand_color, try ownedBrandColor(allocator, value));
    } else if (std.mem.eql(u8, key, "default_prompt")) {
        replaceOptionalString(allocator, &interface.default_prompt, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    }
}

fn setPartialToolField(allocator: std.mem.Allocator, tool: *PartialSkillTool, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "type")) {
        replaceOptionalString(allocator, &tool.kind, try ownedSanitizedString(allocator, value, MAX_SKILL_NAME_LEN));
    } else if (std.mem.eql(u8, key, "value")) {
        replaceOptionalString(allocator, &tool.value, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    } else if (std.mem.eql(u8, key, "description")) {
        replaceOptionalString(allocator, &tool.description, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    } else if (std.mem.eql(u8, key, "transport")) {
        replaceOptionalString(allocator, &tool.transport, try ownedSanitizedString(allocator, value, MAX_SKILL_NAME_LEN));
    } else if (std.mem.eql(u8, key, "command")) {
        replaceOptionalString(allocator, &tool.command, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    } else if (std.mem.eql(u8, key, "url")) {
        replaceOptionalString(allocator, &tool.url, try ownedSanitizedString(allocator, value, MAX_SKILL_DESCRIPTION_LEN));
    }
}

fn appendPartialSkillTool(allocator: std.mem.Allocator, tools: *std.ArrayList(SkillToolDependency), partial: *PartialSkillTool) !void {
    if (try takePartialSkillTool(allocator, partial)) |tool| {
        try tools.append(allocator, tool);
    }
}

fn takePartialSkillTool(allocator: std.mem.Allocator, partial: *PartialSkillTool) !?SkillToolDependency {
    if (partial.kind == null or partial.value == null) {
        partial.deinit(allocator);
        partial.* = .{};
        return null;
    }
    const tool = SkillToolDependency{
        .kind = partial.kind.?,
        .value = partial.value.?,
        .description = partial.description,
        .transport = partial.transport,
        .command = partial.command,
        .url = partial.url,
    };
    partial.* = .{};
    return tool;
}

fn skillInterfaceIsEmpty(interface: SkillInterface) bool {
    return interface.display_name == null and
        interface.short_description == null and
        interface.icon_small == null and
        interface.icon_large == null and
        interface.brand_color == null and
        interface.default_prompt == null;
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn ownedSanitizedString(allocator: std.mem.Allocator, value_opt: ?[]const u8, max_len: usize) !?[]const u8 {
    const raw = value_opt orelse return null;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try output.append(allocator, ' ');
        first = false;
        try output.appendSlice(allocator, token);
    }
    if (output.items.len == 0 or output.items.len > max_len) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

fn ownedBrandColor(allocator: std.mem.Allocator, value_opt: ?[]const u8) !?[]const u8 {
    const raw = value_opt orelse return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len != 7 or value[0] != '#') return null;
    for (value[1..]) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return try allocator.dupe(u8, value);
}

fn ownedIconPath(allocator: std.mem.Allocator, directory: []const u8, value_opt: ?[]const u8) !?[]const u8 {
    const raw = value_opt orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return null;

    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(allocator);
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return null;
        if (normalized.items.len > 0) try normalized.append(allocator, std.fs.path.sep);
        try normalized.appendSlice(allocator, part);
    }
    if (normalized.items.len == 0) return null;
    if (!std.mem.eql(u8, normalized.items, "assets") and
        !std.mem.startsWith(u8, normalized.items, "assets" ++ std.fs.path.sep_str))
    {
        return null;
    }
    return try std.fs.path.join(allocator, &.{ directory, normalized.items });
}

fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, next: ?[]const u8) void {
    if (slot.*) |previous| allocator.free(previous);
    slot.* = next;
}

fn leadingSpaceCount(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn appendSkillError(allocator: std.mem.Allocator, errors: *std.ArrayList(SkillError), path: []const u8, message: []const u8) !void {
    try errors.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    });
}

test "skill frontmatter parser extracts common fields" {
    const parsed = parseSkillFrontmatter(
        \\---
        \\name: "demo-skill"
        \\description: Demo skill description
        \\short_description: "Short demo"
        \\---
        \\body
    );
    try std.testing.expectEqualStrings("demo-skill", parsed.name.?);
    try std.testing.expectEqualStrings("Demo skill description", parsed.description.?);
    try std.testing.expectEqualStrings("Short demo", parsed.short_description.?);
}

test "skill metadata parser loads interface and dependencies" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\{
        \\  "interface": {
        \\    "display_name": "Demo Skill",
        \\    "short_description": "  Demo   short  ",
        \\    "icon_small": "./assets/small.svg",
        \\    "brand_color": "#3B82F6",
        \\    "default_prompt": "  Run   demo "
        \\  },
        \\  "dependencies": {
        \\    "tools": [
        \\      {"type": "env_var", "value": "DEMO_TOKEN", "description": "Demo token"},
        \\      {"type": "mcp", "value": "demo-mcp", "transport": "stdio", "command": "demo-mcp"}
        \\    ]
        \\  }
        \\}
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer metadata.deinit(allocator);

    try std.testing.expect(metadata.interface != null);
    try std.testing.expectEqualStrings("Demo Skill", metadata.interface.?.display_name.?);
    try std.testing.expectEqualStrings("Demo short", metadata.interface.?.short_description.?);
    const expected_icon = try std.fs.path.join(allocator, &.{ skill_dir, "assets", "small.svg" });
    defer allocator.free(expected_icon);
    try std.testing.expectEqualStrings(expected_icon, metadata.interface.?.icon_small.?);
    try std.testing.expectEqualStrings("#3B82F6", metadata.interface.?.brand_color.?);
    try std.testing.expectEqualStrings("Run demo", metadata.interface.?.default_prompt.?);

    try std.testing.expect(metadata.dependencies != null);
    try std.testing.expectEqual(@as(usize, 2), metadata.dependencies.?.tools.len);
    try std.testing.expectEqualStrings("env_var", metadata.dependencies.?.tools[0].kind);
    try std.testing.expectEqualStrings("DEMO_TOKEN", metadata.dependencies.?.tools[0].value);
    try std.testing.expectEqualStrings("Demo token", metadata.dependencies.?.tools[0].description.?);
    try std.testing.expectEqualStrings("mcp", metadata.dependencies.?.tools[1].kind);
    try std.testing.expectEqualStrings("demo-mcp", metadata.dependencies.?.tools[1].value);
    try std.testing.expectEqualStrings("stdio", metadata.dependencies.?.tools[1].transport.?);
    try std.testing.expectEqualStrings("demo-mcp", metadata.dependencies.?.tools[1].command.?);
}

test "skill metadata parser accepts yaml interface and tool dependencies" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\interface:
        \\  display_name: "Yaml Skill"
        \\  icon_large: "assets/large.svg"
        \\dependencies:
        \\  tools:
        \\    - type: cli
        \\      value: gh
        \\      description: "GitHub CLI"
        \\
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer metadata.deinit(allocator);

    try std.testing.expectEqualStrings("Yaml Skill", metadata.interface.?.display_name.?);
    const expected_icon = try std.fs.path.join(allocator, &.{ skill_dir, "assets", "large.svg" });
    defer allocator.free(expected_icon);
    try std.testing.expectEqualStrings(expected_icon, metadata.interface.?.icon_large.?);
    try std.testing.expectEqual(@as(usize, 1), metadata.dependencies.?.tools.len);
    try std.testing.expectEqualStrings("cli", metadata.dependencies.?.tools[0].kind);
    try std.testing.expectEqualStrings("gh", metadata.dependencies.?.tools[0].value);
    try std.testing.expectEqualStrings("GitHub CLI", metadata.dependencies.?.tools[0].description.?);
}

test "skill metadata parser honors json product policy" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\{
        \\  "policy": {
        \\    "products": ["CHATGPT"]
        \\  }
        \\}
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const codex_metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer codex_metadata.deinit(allocator);
    try std.testing.expect(!codex_metadata.product_allowed);

    const chatgpt_metadata = try loadSkillFileMetadata(allocator, skill_dir, .chatgpt);
    defer chatgpt_metadata.deinit(allocator);
    try std.testing.expect(chatgpt_metadata.product_allowed);
}

test "skill metadata parser honors yaml product policy" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\policy: # product access
        \\  products: # allowed products
        \\    - CODEX
        \\
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const codex_metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer codex_metadata.deinit(allocator);
    try std.testing.expect(codex_metadata.product_allowed);

    const chatgpt_metadata = try loadSkillFileMetadata(allocator, skill_dir, .chatgpt);
    defer chatgpt_metadata.deinit(allocator);
    try std.testing.expect(!chatgpt_metadata.product_allowed);
}

test "skill metadata parser honors yaml flow product policy" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\policy: { allow_implicit_invocation: false, products: [CHATGPT] } # chat only
        \\
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const codex_metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer codex_metadata.deinit(allocator);
    try std.testing.expect(!codex_metadata.product_allowed);

    const chatgpt_metadata = try loadSkillFileMetadata(allocator, skill_dir, .chatgpt);
    defer chatgpt_metadata.deinit(allocator);
    try std.testing.expect(chatgpt_metadata.product_allowed);
}

test "skill metadata parser leaves yaml product list before sibling lists" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "demo/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "demo/agents/openai.yaml",
        .data =
        \\policy:
        \\  products:
        \\    - CODEX
        \\  allow_tools:
        \\    - future-tool
        \\
        ,
    });
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "demo" });
    defer allocator.free(skill_dir);

    const codex_metadata = try loadSkillFileMetadata(allocator, skill_dir, .codex);
    defer codex_metadata.deinit(allocator);
    try std.testing.expect(codex_metadata.product_allowed);

    const chatgpt_metadata = try loadSkillFileMetadata(allocator, skill_dir, .chatgpt);
    defer chatgpt_metadata.deinit(allocator);
    try std.testing.expect(!chatgpt_metadata.product_allowed);
}

test "skill metadata parser treats yaml null product policy as unrestricted" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "block/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "block/agents/openai.yaml",
        .data =
        \\policy:
        \\  products: null
        \\
        ,
    });
    const block_skill_dir = try std.fs.path.join(allocator, &.{ root, "block" });
    defer allocator.free(block_skill_dir);

    const block_metadata = try loadSkillFileMetadata(allocator, block_skill_dir, .codex);
    defer block_metadata.deinit(allocator);
    try std.testing.expect(block_metadata.product_allowed);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "flow/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "flow/agents/openai.yaml",
        .data =
        \\policy: { products: null }
        \\
        ,
    });
    const flow_skill_dir = try std.fs.path.join(allocator, &.{ root, "flow" });
    defer allocator.free(flow_skill_dir);

    const flow_metadata = try loadSkillFileMetadata(allocator, flow_skill_dir, .chatgpt);
    defer flow_metadata.deinit(allocator);
    try std.testing.expect(flow_metadata.product_allowed);
}

test "skill metadata parser treats invalid product policy as unrestricted" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "json/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "json/agents/openai.yaml",
        .data =
        \\{
        \\  "policy": {
        \\    "products": ["SORA"]
        \\  }
        \\}
        ,
    });
    const json_skill_dir = try std.fs.path.join(allocator, &.{ root, "json" });
    defer allocator.free(json_skill_dir);

    const json_metadata = try loadSkillFileMetadata(allocator, json_skill_dir, .codex);
    defer json_metadata.deinit(allocator);
    try std.testing.expect(json_metadata.product_allowed);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "scalar/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "scalar/agents/openai.yaml",
        .data =
        \\policy:
        \\  products: CHATGPT
        \\
        ,
    });
    const scalar_skill_dir = try std.fs.path.join(allocator, &.{ root, "scalar" });
    defer allocator.free(scalar_skill_dir);

    const scalar_metadata = try loadSkillFileMetadata(allocator, scalar_skill_dir, .codex);
    defer scalar_metadata.deinit(allocator);
    try std.testing.expect(scalar_metadata.product_allowed);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "future/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "future/agents/openai.yaml",
        .data =
        \\policy: { products: [CODEX, SORA] }
        \\
        ,
    });
    const future_skill_dir = try std.fs.path.join(allocator, &.{ root, "future" });
    defer allocator.free(future_skill_dir);

    const future_metadata = try loadSkillFileMetadata(allocator, future_skill_dir, .chatgpt);
    defer future_metadata.deinit(allocator);
    try std.testing.expect(future_metadata.product_allowed);
}

test "skills list suppresses validation errors for product-hidden skills" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "skills/hidden/agents");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "skills/hidden/SKILL.md",
        .data =
        \\---
        \\name: hidden
        \\---
        \\Hidden for Codex.
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "skills/hidden/agents/openai.yaml",
        .data =
        \\policy:
        \\  products:
        \\    - CHATGPT
        \\
        ,
    });
    const skills_root = try std.fs.path.join(allocator, &.{ root, "skills" });
    defer allocator.free(skills_root);

    var skills = std.ArrayList(Skill).empty;
    defer {
        for (skills.items) |skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }
    var errors = std.ArrayList(SkillError).empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }

    try scanSkillRoot(
        allocator,
        .{ .path = skills_root, .scope = "user" },
        .codex,
        &skills,
        &errors,
    );

    try std.testing.expectEqual(@as(usize, 0), skills.items.len);
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "skill config writer toggles name selector" {
    const allocator = std.testing.allocator;

    const disabled = try updateSkillConfigToml(allocator, "", .{ .name = "github:yeet" }, false);
    defer allocator.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "[[skills.config]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "name = \"github:yeet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "enabled = false") != null);

    const enabled = try updateSkillConfigToml(allocator, disabled, .{ .name = "github:yeet" }, true);
    defer allocator.free(enabled);
    try std.testing.expectEqualStrings("", enabled);
}

test "skill config writer replaces path selector without dropping unrelated config" {
    const allocator = std.testing.allocator;
    const original =
        \\model = "gpt-test"
        \\[[skills.config]]
        \\path = "/tmp/demo/SKILL.md"
        \\enabled = false
        \\[features]
        \\goals = true
        \\
    ;

    const updated = try updateSkillConfigToml(allocator, original, .{ .path = "/tmp/demo/SKILL.md" }, false);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "model = \"gpt-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[features]") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "goals = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "path = \"/tmp/demo/SKILL.md\"") != null);
}

test "skills list scans extra roots" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "shared/demo-skill");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "shared/demo-skill/SKILL.md",
        .data =
        \\---
        \\name: demo-skill
        \\description: Demo skill description
        \\---
        \\Use this skill for demos.
        ,
    });
    const shared = try std.fs.path.join(allocator, &.{ root, "shared" });
    defer allocator.free(shared);

    var result = try list(allocator, &.{root}, &.{.{ .cwd = root, .roots = &.{shared} }});
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    var found = false;
    for (result.entries[0].skills) |skill| {
        if (std.mem.eql(u8, skill.name, "demo-skill")) {
            found = true;
            try std.testing.expectEqualStrings("user", skill.scope);
        }
    }
    try std.testing.expect(found);
}

test "skills list namespaces plugin skill names" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "plugin/.codex-plugin");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "plugin/skills/search");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "plugin/.codex-plugin/plugin.json",
        .data = "{\"name\":\"sample\"}",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "plugin/skills/search/SKILL.md",
        .data =
        \\---
        \\name: search
        \\description: Search sample data
        \\---
        \\Use this plugin skill.
        ,
    });

    const plugin_root = try std.fs.path.join(allocator, &.{ root, "plugin" });
    defer allocator.free(plugin_root);
    const skills_path = try std.fs.path.join(allocator, &.{ plugin_root, "skills" });
    defer allocator.free(skills_path);
    const prefix = try pluginSkillNamePrefix(allocator, plugin_root, "sample@test");
    defer allocator.free(prefix);

    var skills = std.ArrayList(Skill).empty;
    defer {
        for (skills.items) |skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }
    var errors = std.ArrayList(SkillError).empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }
    try scanSkillRoot(
        allocator,
        .{ .path = skills_path, .scope = "user", .skill_name_prefix = prefix },
        .codex,
        &skills,
        &errors,
    );

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), skills.items.len);
    try std.testing.expectEqualStrings("sample:search", skills.items[0].name);
    try std.testing.expectEqualStrings("user", skills.items[0].scope);
    try std.testing.expect(std.mem.endsWith(u8, skills.items[0].path, "plugin/skills/search/SKILL.md"));
}
