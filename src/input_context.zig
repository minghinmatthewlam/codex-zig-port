const std = @import("std");

const mcp_runtime = @import("mcp_runtime.zig");
const plugin_config = @import("plugin_config.zig");
const skills_list = @import("skills_list.zig");

pub const NamedPathInput = struct {
    name: []const u8,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, path: []const u8) !NamedPathInput {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{ .name = owned_name, .path = owned_path };
    }

    pub fn deinit(self: NamedPathInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const RegisteredSkillOptions = struct {
    extra_roots_by_cwd: []const skills_list.ExtraRootsForCwd = &.{},
    registered_paths: []const []const u8 = &.{},
};

pub const DeveloperMessages = struct {
    items: []const []const u8 = &.{},

    pub fn deinit(self: DeveloperMessages, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

pub fn renderNamedPathPreview(
    allocator: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
    path: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "[{s}:${s}]({s})", .{ kind, name, path });
}

pub fn buildPluginMentionDeveloperMessages(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    mentions: []const NamedPathInput,
    mcp_tools: []const mcp_runtime.ToolSpec,
) !DeveloperMessages {
    if (mentions.len == 0 or !plugin_config.pluginsFeatureEnabled(config_bytes)) return .{};

    const enabled_ids = try plugin_config.enabledPluginIds(allocator, config_bytes);
    defer plugin_config.freeStringList(allocator, enabled_ids);

    var messages = std.ArrayList([]const u8).empty;
    errdefer {
        for (messages.items) |message| allocator.free(message);
        messages.deinit(allocator);
    }

    for (enabled_ids) |plugin_id| {
        if (!pluginMentioned(mentions, plugin_id)) continue;
        const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse continue;
        defer allocator.free(plugin_root);
        const display_name = try plugin_config.pluginDisplayNameForRoot(allocator, plugin_root, plugin_id);
        defer allocator.free(display_name);
        const skill_name_prefix = try plugin_config.pluginSkillNamePrefixForRoot(allocator, plugin_root, plugin_id);
        defer allocator.free(skill_name_prefix);
        const has_skills = try pluginHasEnabledSkills(allocator, plugin_root, skill_name_prefix, config_bytes);
        const mcp_server_names = try pluginMcpServerNamesFromTools(allocator, plugin_id, mcp_tools);
        defer freeStringList(allocator, mcp_server_names);
        if (try renderExplicitPluginInstructions(allocator, display_name, skill_name_prefix, has_skills, mcp_server_names)) |message| {
            try messages.append(allocator, message);
        }
    }

    return .{ .items = try messages.toOwnedSlice(allocator) };
}

fn pluginMentioned(mentions: []const NamedPathInput, plugin_id: []const u8) bool {
    for (mentions) |mention| {
        const mentioned_id = pluginConfigNameFromPath(mention.path) orelse continue;
        if (std.mem.eql(u8, mentioned_id, plugin_id)) return true;
    }
    return false;
}

fn pluginConfigNameFromPath(path: []const u8) ?[]const u8 {
    const prefix = "plugin://";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const value = path[prefix.len..];
    if (value.len == 0) return null;
    return value;
}

fn pluginHasEnabledSkills(
    allocator: std.mem.Allocator,
    plugin_root: []const u8,
    display_name: []const u8,
    config_bytes: []const u8,
) !bool {
    var listed = try skills_list.listPluginSkills(allocator, plugin_root, display_name, config_bytes);
    defer listed.deinit(allocator);
    return listed.skills.len > 0;
}

fn pluginMcpServerNamesFromTools(
    allocator: std.mem.Allocator,
    plugin_id: []const u8,
    mcp_tools: []const mcp_runtime.ToolSpec,
) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (mcp_tools) |tool| {
        const tool_plugin_id = tool.plugin_id orelse continue;
        if (!std.mem.eql(u8, tool_plugin_id, plugin_id)) continue;
        try appendUniqueString(allocator, &names, tool.server_name);
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    return names.toOwnedSlice(allocator);
}

fn renderExplicitPluginInstructions(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    skill_name_prefix: []const u8,
    has_skills: bool,
    mcp_server_names: []const []const u8,
) !?[]const u8 {
    if (!has_skills and mcp_server_names.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "Capabilities from the `{s}` plugin:", .{display_name});
    if (has_skills) {
        try out.print(allocator, "\n- Skills from this plugin are prefixed with `{s}:`.", .{skill_name_prefix});
    }
    if (mcp_server_names.len > 0) {
        try out.appendSlice(allocator, "\n- MCP servers from this plugin available in this session: ");
        for (mcp_server_names, 0..) |server_name, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.print(allocator, "`{s}`", .{server_name});
        }
        try out.append(allocator, '.');
    }
    try out.appendSlice(allocator, "\nUse these plugin-associated capabilities to help solve the task.");
    return try out.toOwnedSlice(allocator);
}

fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn loadRegisteredSkillBlockFromBase(
    allocator: std.mem.Allocator,
    base_cwd: ?[]const u8,
    name: []const u8,
    path: []const u8,
) ![]const u8 {
    return loadRegisteredSkillBlockFromBaseWithOptions(allocator, base_cwd, name, path, .{});
}

pub fn loadRegisteredSkillBlockFromBaseWithOptions(
    allocator: std.mem.Allocator,
    base_cwd: ?[]const u8,
    name: []const u8,
    path: []const u8,
    options: RegisteredSkillOptions,
) ![]const u8 {
    const resolved = try resolvePathFromBase(allocator, base_cwd, path);
    defer allocator.free(resolved);
    const allowed = registeredSkillPathAllowed(allocator, base_cwd, resolved, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return renderSkillReadError(allocator, err),
    };
    if (!allowed) {
        return renderSkillReadError(allocator, error.UnregisteredSkill);
    }
    return loadSkillBlockFromResolvedPath(allocator, name, path, resolved);
}

fn loadSkillBlockFromResolvedPath(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    resolved_path: []const u8,
) ![]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        resolved_path,
        allocator,
        .limited(512 * 1024),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try renderSkillReadError(allocator, err),
    };
    defer allocator.free(contents);
    return renderSkillBlock(allocator, name, path, contents);
}

fn registeredSkillPathAllowed(
    allocator: std.mem.Allocator,
    base_cwd: ?[]const u8,
    resolved_path: []const u8,
    options: RegisteredSkillOptions,
) !bool {
    const normalized_path = realPathOwnedAlloc(allocator, resolved_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return err,
    };
    defer allocator.free(normalized_path);

    const metadata = std.Io.Dir.cwd().statFile(
        std.Io.Threaded.global_single_threaded.io(),
        resolved_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return err,
    };
    if (metadata.kind == .sym_link) return false;

    for (options.registered_paths) |registered_path| {
        if (pathsEqual(registered_path, normalized_path)) return true;
    }

    const cwd = if (base_cwd) |base| try allocator.dupe(u8, base) else try realPathOwnedAlloc(allocator, ".");
    defer allocator.free(cwd);

    var listed = try skills_list.list(allocator, &.{cwd}, options.extra_roots_by_cwd);
    defer listed.deinit(allocator);
    for (listed.entries) |entry| {
        for (entry.skills) |skill| {
            if (!skill.enabled) continue;
            if (pathsEqual(skill.path, normalized_path)) return true;
        }
    }
    return false;
}

fn renderSkillReadError(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Codex could not read the skill file: {s}", .{@errorName(err)});
}

fn renderSkillBlock(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    contents: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "<skill>\n<name>{s}</name>\n<path>{s}</path>\n{s}\n</skill>",
        .{ name, path, contents },
    );
}

fn resolvePathFromBase(allocator: std.mem.Allocator, base_cwd: ?[]const u8, path: []const u8) ![]const u8 {
    const base = base_cwd orelse return allocator.dupe(u8, path);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ base, path });
}

fn realPathOwnedAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "registered skill block from base resolves relative paths" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".codex/skills/demo");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = ".codex/skills/demo/SKILL.md",
        .data = "# Demo\n\nShared skill body.\n",
    });
    const base = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(base);

    const block = try loadRegisteredSkillBlockFromBase(allocator, base, "demo", ".codex/skills/demo/SKILL.md");
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "<name>demo</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "<path>.codex/skills/demo/SKILL.md</path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Shared skill body.") != null);
}

test "registered skill block rejects unregistered paths without reading contents" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "secret.txt",
        .data = "do not inject this secret\n",
    });
    const base = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(base);

    const block = try loadRegisteredSkillBlockFromBase(allocator, base, "secret", "secret.txt");
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "UnregisteredSkill") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "do not inject this secret") == null);
}

test "registered skill block accepts extra-root registrations" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "shared/demo");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "shared/demo/SKILL.md",
        .data = "# Demo\n\nExtra root skill body.\n",
    });
    const base = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(base);
    const shared = try std.fs.path.join(allocator, &.{ base, "shared" });
    defer allocator.free(shared);
    const skill_path = try std.fs.path.join(allocator, &.{ shared, "demo", "SKILL.md" });
    defer allocator.free(skill_path);

    const block = try loadRegisteredSkillBlockFromBaseWithOptions(allocator, base, "demo", skill_path, .{
        .extra_roots_by_cwd = &.{.{ .cwd = base, .roots = &.{shared} }},
    });
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "Extra root skill body.") != null);
}

test "registered skill path comparison is exact" {
    try std.testing.expect(pathsEqual("/tmp/Demo/SKILL.md", "/tmp/Demo/SKILL.md"));
    try std.testing.expect(!pathsEqual("/tmp/Demo/SKILL.md", "/tmp/Demo/skill.md"));
}

test "plugin mention developer messages describe enabled plugin capabilities" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home/plugins/cache/local/demo/local/.codex-plugin");
    try dir.dir.createDirPath(io, "codex-home/plugins/cache/local/demo/local/skills/search");
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/plugins/cache/local/demo/local/.codex-plugin/plugin.json",
        .data =
        \\{
        \\  "name": "demo",
        \\  "interface": { "displayName": "Demo Plugin" }
        \\}
        ,
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/plugins/cache/local/demo/local/skills/search/SKILL.md",
        .data = "# Search\n\nUse plugin search.",
    });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const config_bytes =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."demo@local"]
        \\enabled = true
    ;
    const mentions = [_]NamedPathInput{.{ .name = "Demo Plugin", .path = "plugin://demo@local" }};
    const tools = [_]mcp_runtime.ToolSpec{
        .{
            .server_name = "plugin_docs",
            .raw_tool_name = "search",
            .callable_name = "mcp__plugin_docs__search",
            .description = "Search plugin docs.",
            .input_schema_json = "{\"type\":\"object\"}",
            .plugin_id = "demo@local",
            .plugin_display_name = "Demo Plugin",
        },
        .{
            .server_name = "other",
            .raw_tool_name = "ignored",
            .callable_name = "mcp__other__ignored",
            .description = "",
            .input_schema_json = "{\"type\":\"object\"}",
        },
    };

    const messages = try buildPluginMentionDeveloperMessages(allocator, codex_home, config_bytes, mentions[0..], tools[0..]);
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[0], "Capabilities from the `Demo Plugin` plugin:") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[0], "Skills from this plugin are prefixed with `demo:`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[0], "MCP servers from this plugin available in this session: `plugin_docs`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[0], "Use these plugin-associated capabilities to help solve the task.") != null);
}

test "plugin mention developer messages ignore disabled and non-plugin mentions" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try dir.dir.createDirPath(io, "codex-home/plugins/cache/local/demo/local/.codex-plugin");
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/plugins/cache/local/demo/local/.codex-plugin/plugin.json",
        .data = "{\"name\":\"demo\"}",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);

    const disabled_config =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."demo@local"]
        \\enabled = false
    ;
    const mentions = [_]NamedPathInput{
        .{ .name = "Demo Plugin", .path = "plugin://demo@local" },
        .{ .name = "Drive", .path = "app://drive" },
    };

    const messages = try buildPluginMentionDeveloperMessages(allocator, codex_home, disabled_config, mentions[0..], &.{});
    defer messages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}
