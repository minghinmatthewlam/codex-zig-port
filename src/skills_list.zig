const std = @import("std");

const env = @import("env.zig");

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
    path: []const u8,
    scope: []const u8,

    fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.short_description) |value| allocator.free(value);
        allocator.free(self.path);
        allocator.free(self.scope);
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

const Root = struct {
    path: []const u8,
    scope: []const u8,
};

const SkillFrontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
};

pub fn list(
    allocator: std.mem.Allocator,
    cwd_inputs: []const []const u8,
    extra_roots_by_cwd: []const ExtraRootsForCwd,
) !Result {
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
        const entry = try listForCwd(allocator, cwd, extra_roots_by_cwd);
        try entries.append(allocator, entry);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn defaultCwdList(allocator: std.mem.Allocator) ![]const []const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
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

fn listForCwd(allocator: std.mem.Allocator, cwd: []const u8, extra_roots_by_cwd: []const ExtraRootsForCwd) !Entry {
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
        for (roots.items) |root| allocator.free(root.path);
        roots.deinit(allocator);
    }
    try appendRepoSkillRoots(allocator, &roots, cwd);
    try appendCodexHomeSkillRoot(allocator, &roots);
    try appendExtraSkillRoots(allocator, &roots, cwd, extra_roots_by_cwd);

    for (roots.items) |root| {
        try scanSkillRoot(allocator, root, &skills, &errors);
    }

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
    skills: *std.ArrayList(Skill),
    errors: *std.ArrayList(SkillError),
) !void {
    try scanSkillDirectoryIfPresent(allocator, root.path, root.scope, skills, errors);

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
        try scanSkillDirectoryIfPresent(allocator, child, root.scope, skills, errors);
    }
}

fn scanSkillDirectoryIfPresent(
    allocator: std.mem.Allocator,
    directory: []const u8,
    scope: []const u8,
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
    const name = metadata.name orelse std.fs.path.basename(directory);
    const description = metadata.description orelse "";
    if (metadata.description == null) {
        try appendSkillError(allocator, errors, skill_path, "SKILL.md is missing description frontmatter");
    }

    try skills.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .short_description = if (metadata.short_description) |value| try allocator.dupe(u8, value) else null,
        .path = try allocator.dupe(u8, skill_path),
        .scope = try allocator.dupe(u8, scope),
    });
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
