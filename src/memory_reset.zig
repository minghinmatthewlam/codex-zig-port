const std = @import("std");

const builtin = @import("builtin");
const env = @import("env.zig");

pub const state_db_filename = "state_5.sqlite";

pub fn resolveStateDbPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    const sqlite_home = try resolveSqliteHome(allocator, codex_home);
    defer allocator.free(sqlite_home);
    return std.fs.path.join(allocator, &.{ sqlite_home, state_db_filename });
}

pub fn stateDbExists(allocator: std.mem.Allocator, state_path: []const u8) !bool {
    return (try statPathNoFollow(allocator, state_path)) != null;
}

pub fn clearMemoryStateDb(allocator: std.mem.Allocator, state_path: []const u8) !void {
    const sql =
        \\BEGIN IMMEDIATE;
        \\DELETE FROM stage1_outputs;
        \\DELETE FROM jobs
        \\WHERE kind = 'memory_stage1' OR kind = 'memory_consolidate_global';
        \\COMMIT;
    ;

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &.{ "sqlite3", state_path, sql },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.MemoryStateDbClearFailed,
        else => return error.MemoryStateDbClearFailed,
    }
}

pub fn clearMemoryRootsContents(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const roots = [_][]const u8{ "memories", "memories_extensions" };
    for (roots) |root_name| {
        const root_path = try std.fs.path.join(allocator, &.{ codex_home, root_name });
        defer allocator.free(root_path);
        try clearMemoryRootContents(allocator, root_path);
    }
}

pub fn clearMemoryRootContents(allocator: std.mem.Allocator, root_path: []const u8) !void {
    if (try statPathNoFollow(allocator, root_path)) |stat| {
        const mode: u32 = @intCast(stat.mode);
        if (std.c.S.ISLNK(mode)) return error.SymlinkedMemoryRoot;
        if (!std.c.S.ISDIR(mode)) return error.MemoryRootNotDirectory;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, root_path);
    var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        try dir.deleteTree(io, entry.name);
    }
}

fn resolveSqliteHome(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_SQLITE_HOME")) |raw| {
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);

            const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
            defer allocator.free(cwd);
            return std.fs.path.join(allocator, &.{ cwd, trimmed });
        }
    }
    return allocator.dupe(u8, codex_home);
}

fn statPathNoFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT => return null,
            .NOTDIR => return error.NotDir,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return stat;
}

test "memory reset preserves empty root directory" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDirPath(io, "memories/rollout_summaries");
    try dir.dir.writeFile(io, .{ .sub_path = "memories/MEMORY.md", .data = "stale memory index\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "memories/rollout_summaries/rollout.md", .data = "stale rollout\n" });

    const root = try dir.dir.realPathFileAlloc(io, "memories", allocator);
    defer allocator.free(root);
    try clearMemoryRootContents(allocator, root);

    var memory_dir = try dir.dir.openDir(io, "memories", .{ .iterate = true });
    defer memory_dir.close(io);
    var iter = memory_dir.iterate();
    try std.testing.expect((try iter.next(io)) == null);
}

test "memory reset creates missing roots" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try clearMemoryRootsContents(allocator, root);

    var memories = try dir.dir.openDir(io, "memories", .{ .iterate = true });
    defer memories.close(io);
    var extensions = try dir.dir.openDir(io, "memories_extensions", .{ .iterate = true });
    defer extensions.close(io);
}

test "memory reset rejects symlinked root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDirPath(io, "outside");
    try dir.dir.writeFile(io, .{ .sub_path = "outside/keep.txt", .data = "keep\n" });
    try dir.dir.symLink(io, "outside", "memories", .{ .is_directory = true });

    const temp_root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_root);
    const root = try std.fs.path.join(allocator, &.{ temp_root, "memories" });
    defer allocator.free(root);
    try std.testing.expectError(error.SymlinkedMemoryRoot, clearMemoryRootContents(allocator, root));

    const kept = try dir.dir.readFileAlloc(io, "outside/keep.txt", allocator, .limited(1024));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
}
