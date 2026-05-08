const std = @import("std");

const default_filename = "AGENTS.md";
const override_filename = "AGENTS.override.md";
const separator = "\n\n--- project-doc ---\n\n";
const max_doc_bytes = 64 * 1024;

pub fn buildInstructions(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);
    return buildInstructionsForCwd(allocator, base, cwd);
}

pub fn buildInstructionsForCwd(
    allocator: std.mem.Allocator,
    base: []const u8,
    cwd: []const u8,
) ![]const u8 {
    const docs = try readProjectDocs(allocator, cwd);
    defer allocator.free(docs);
    if (docs.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base, separator, docs });
}

fn readProjectDocs(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const root = try findProjectRoot(allocator, cwd);
    defer allocator.free(root);

    var dirs = std.ArrayList([]const u8).empty;
    defer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    var current = try allocator.dupe(u8, cwd);
    while (true) {
        try dirs.append(allocator, current);
        if (std.mem.eql(u8, current, root)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = try allocator.dupe(u8, parent);
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var remaining: usize = 256 * 1024;

    var index = dirs.items.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        const dir = dirs.items[index];
        const doc = try readDocForDir(allocator, dir, remaining) orelse continue;
        defer allocator.free(doc);
        if (output.items.len > 0) try output.appendSlice(allocator, "\n\n");
        try output.appendSlice(allocator, doc);
        remaining -|= doc.len;
    }

    return output.toOwnedSlice(allocator);
}

fn findProjectRoot(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        if (try hasRootMarker(allocator, current)) return current;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return allocator.dupe(u8, cwd);
}

fn hasRootMarker(allocator: std.mem.Allocator, dir: []const u8) !bool {
    const marker = try std.fs.path.join(allocator, &.{ dir, ".git" });
    defer allocator.free(marker);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), marker, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

fn readDocForDir(allocator: std.mem.Allocator, dir: []const u8, remaining: usize) !?[]const u8 {
    const filenames = [_][]const u8{ override_filename, default_filename };
    for (filenames) |filename| {
        const path = try std.fs.path.join(allocator, &.{ dir, filename });
        defer allocator.free(path);
        const limit = @min(max_doc_bytes, remaining);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            allocator,
            .limited(limit),
        ) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => continue,
            else => return err,
        };
        defer allocator.free(bytes);

        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) continue;
        const formatted = try std.fmt.allocPrint(
            allocator,
            "# {s} instructions for {s}\n\n<INSTRUCTIONS>\n{s}\n</INSTRUCTIONS>",
            .{ filename, dir, trimmed },
        );
        return @as(?[]const u8, formatted);
    }
    return null;
}

test "build instructions appends agents docs from root to cwd" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDir(std.Io.Threaded.global_single_threaded.io(), ".git", .default_dir);
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "nested/crate");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "AGENTS.md",
        .data = "root doc\n",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "nested/crate/AGENTS.md",
        .data = "crate doc\n",
    });

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const cwd = try std.fs.path.join(allocator, &.{ root, "nested", "crate" });
    defer allocator.free(cwd);

    const instructions = try buildInstructionsForCwd(allocator, "base", cwd);
    defer allocator.free(instructions);

    try std.testing.expect(std.mem.indexOf(u8, instructions, "base\n\n--- project-doc ---") != null);
    const root_index = std.mem.indexOf(u8, instructions, "root doc").?;
    const crate_index = std.mem.indexOf(u8, instructions, "crate doc").?;
    try std.testing.expect(root_index < crate_index);
}

test "agents override is preferred over agents md" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDir(std.Io.Threaded.global_single_threaded.io(), ".git", .default_dir);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "AGENTS.md",
        .data = "base doc\n",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "AGENTS.override.md",
        .data = "override doc\n",
    });

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const instructions = try buildInstructionsForCwd(allocator, "base", root);
    defer allocator.free(instructions);

    try std.testing.expect(std.mem.indexOf(u8, instructions, "override doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "base doc") == null);
}
