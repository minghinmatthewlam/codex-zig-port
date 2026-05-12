const std = @import("std");

const memory_reset = @import("memory_reset.zig");
const session_store = @import("session_store.zig");
const sqlite = @import("sqlite.zig");

const LIST_ROLLOUT_PATHS_QUERY =
    \\SELECT id, rollout_path
    \\FROM threads
    \\WHERE rollout_path IS NOT NULL AND rollout_path != ''
    \\ORDER BY id ASC
;

const ROLLOUT_PATH_QUERY =
    \\SELECT rollout_path
    \\FROM threads
    \\WHERE id = ?
;

pub fn listRolloutFiles(allocator: std.mem.Allocator, codex_home: []const u8) ![]session_store.RolloutFile {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return allocator.alloc(session_store.RolloutFile, 0);

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_QUERY) catch |err| switch (err) {
        error.SqlitePrepareFailed => return allocator.alloc(session_store.RolloutFile, 0),
        else => return err,
    };
    defer sqlite.finalize(statement);

    var files = std.ArrayList(session_store.RolloutFile).empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    while (true) {
        switch (sqlite.step(statement)) {
            sqlite.SQLITE_ROW => {
                const id = try sqlite.columnTextOwned(allocator, statement, 0);
                errdefer allocator.free(id);
                const raw_path = try sqlite.columnTextOwned(allocator, statement, 1);
                defer allocator.free(raw_path);
                const path = try stateRolloutPath(allocator, codex_home, raw_path);
                defer allocator.free(path);

                const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch {
                    allocator.free(id);
                    continue;
                };
                if (stat.kind != .file) {
                    allocator.free(id);
                    continue;
                }

                const real_path_z = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
                    error.FileNotFound => {
                        allocator.free(id);
                        continue;
                    },
                    else => return err,
                };
                defer allocator.free(real_path_z);
                const real_path = try allocator.dupe(u8, real_path_z);
                errdefer allocator.free(real_path);

                try files.append(allocator, .{
                    .id = id,
                    .path = real_path,
                    .modified_at_seconds = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
                });
            },
            sqlite.SQLITE_DONE => break,
            else => return error.StateDbThreadListStepFailed,
        }
    }

    return files.toOwnedSlice(allocator);
}

pub fn findRolloutPathByThreadId(allocator: std.mem.Allocator, codex_home: []const u8, thread_id: []const u8) !?[]const u8 {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, ROLLOUT_PATH_QUERY) catch |err| switch (err) {
        error.SqlitePrepareFailed => return null,
        else => return err,
    };
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, thread_id);

    switch (sqlite.step(statement)) {
        sqlite.SQLITE_ROW => {
            const raw_path = try sqlite.columnTextOwned(allocator, statement, 0);
            defer allocator.free(raw_path);
            return try stateRolloutPath(allocator, codex_home, raw_path);
        },
        sqlite.SQLITE_DONE => return null,
        else => return error.StateDbRolloutPathStepFailed,
    }
}

fn stateRolloutPath(allocator: std.mem.Allocator, codex_home: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ codex_home, path });
}
