const std = @import("std");

const skills_list = @import("skills_list.zig");

pub const RegisteredSkillOptions = struct {
    extra_roots_by_cwd: []const skills_list.ExtraRootsForCwd = &.{},
    registered_paths: []const []const u8 = &.{},
};

pub fn renderNamedPathPreview(
    allocator: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
    path: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "[{s}:${s}]({s})", .{ kind, name, path });
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
