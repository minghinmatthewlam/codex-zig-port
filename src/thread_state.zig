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

const LIST_ROLLOUT_PATHS_WITH_METADATA_QUERY =
    \\SELECT id, rollout_path, title, memory_mode, git_sha, git_branch, git_origin_url
    \\FROM threads
    \\WHERE rollout_path IS NOT NULL AND rollout_path != ''
    \\ORDER BY id ASC
;

const ROLLOUT_PATH_QUERY =
    \\SELECT rollout_path
    \\FROM threads
    \\WHERE id = ?
;

const THREAD_METADATA_QUERY =
    \\SELECT title, memory_mode, git_sha, git_branch, git_origin_url
    \\FROM threads
    \\WHERE id = ?
;

const UPDATE_TITLE_QUERY =
    \\UPDATE threads
    \\SET title = ?
    \\WHERE id = ?
;

const UPDATE_MEMORY_MODE_QUERY =
    \\UPDATE threads
    \\SET memory_mode = ?
    \\WHERE id = ?
;

const UPDATE_GIT_INFO_QUERY =
    \\UPDATE threads
    \\SET git_sha = ?, git_branch = ?, git_origin_url = ?
    \\WHERE id = ?
;

pub const ThreadMetadata = struct {
    title: ?[]const u8,
    memory_mode: ?[]const u8,
    git_sha: ?[]const u8,
    git_branch: ?[]const u8,
    git_origin_url: ?[]const u8,

    pub fn deinit(self: ThreadMetadata, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.memory_mode) |value| allocator.free(value);
        if (self.git_sha) |value| allocator.free(value);
        if (self.git_branch) |value| allocator.free(value);
        if (self.git_origin_url) |value| allocator.free(value);
    }
};

pub fn listRolloutFiles(allocator: std.mem.Allocator, codex_home: []const u8) ![]session_store.RolloutFile {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return allocator.alloc(session_store.RolloutFile, 0);

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    var has_metadata_columns = true;
    const statement = sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_WITH_METADATA_QUERY) catch |metadata_err| switch (metadata_err) {
        error.SqlitePrepareFailed => blk: {
            has_metadata_columns = false;
            break :blk sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_QUERY) catch |fallback_err| switch (fallback_err) {
                error.SqlitePrepareFailed => return allocator.alloc(session_store.RolloutFile, 0),
                else => return fallback_err,
            };
        },
        else => return metadata_err,
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
                const title = if (has_metadata_columns) try sqlite.columnNullableTextOwned(allocator, statement, 2) else null;
                errdefer if (title) |value| allocator.free(value);
                const memory_mode = if (has_metadata_columns) try sqlite.columnNullableTextOwned(allocator, statement, 3) else null;
                errdefer if (memory_mode) |value| allocator.free(value);
                const git_sha = if (has_metadata_columns) try sqlite.columnNullableTextOwned(allocator, statement, 4) else null;
                errdefer if (git_sha) |value| allocator.free(value);
                const git_branch = if (has_metadata_columns) try sqlite.columnNullableTextOwned(allocator, statement, 5) else null;
                errdefer if (git_branch) |value| allocator.free(value);
                const git_origin_url = if (has_metadata_columns) try sqlite.columnNullableTextOwned(allocator, statement, 6) else null;
                errdefer if (git_origin_url) |value| allocator.free(value);

                try files.append(allocator, .{
                    .id = id,
                    .path = real_path,
                    .modified_at_seconds = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
                    .state_metadata_loaded = has_metadata_columns,
                    .title = title,
                    .memory_mode = memory_mode,
                    .git_sha = git_sha,
                    .git_branch = git_branch,
                    .git_origin_url = git_origin_url,
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

pub fn findThreadMetadataByThreadId(allocator: std.mem.Allocator, codex_home: []const u8, thread_id: []const u8) !?ThreadMetadata {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, THREAD_METADATA_QUERY) catch |err| switch (err) {
        error.SqlitePrepareFailed => return null,
        else => return err,
    };
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, thread_id);

    switch (sqlite.step(statement)) {
        sqlite.SQLITE_ROW => {
            const title = try sqlite.columnNullableTextOwned(allocator, statement, 0);
            errdefer if (title) |value| allocator.free(value);
            const memory_mode = try sqlite.columnNullableTextOwned(allocator, statement, 1);
            errdefer if (memory_mode) |value| allocator.free(value);
            const git_sha = try sqlite.columnNullableTextOwned(allocator, statement, 2);
            errdefer if (git_sha) |value| allocator.free(value);
            const git_branch = try sqlite.columnNullableTextOwned(allocator, statement, 3);
            errdefer if (git_branch) |value| allocator.free(value);
            const git_origin_url = try sqlite.columnNullableTextOwned(allocator, statement, 4);
            errdefer if (git_origin_url) |value| allocator.free(value);
            return ThreadMetadata{
                .title = title,
                .memory_mode = memory_mode,
                .git_sha = git_sha,
                .git_branch = git_branch,
                .git_origin_url = git_origin_url,
            };
        },
        sqlite.SQLITE_DONE => return null,
        else => return error.StateDbThreadMetadataStepFailed,
    }
}

pub fn updateThreadTitle(allocator: std.mem.Allocator, codex_home: []const u8, thread_id: []const u8, title: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, codex_home, UPDATE_TITLE_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, title);
    try sqlite.bindText(statement.statement, 2, thread_id);
    return try finishStateUpdate(statement);
}

pub fn updateThreadMemoryMode(allocator: std.mem.Allocator, codex_home: []const u8, thread_id: []const u8, mode: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, codex_home, UPDATE_MEMORY_MODE_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, mode);
    try sqlite.bindText(statement.statement, 2, thread_id);
    return try finishStateUpdate(statement);
}

pub fn updateThreadGitInfo(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thread_id: []const u8,
    sha: ?[]const u8,
    branch: ?[]const u8,
    origin_url: ?[]const u8,
) !bool {
    const statement = try prepareStateUpdate(allocator, codex_home, UPDATE_GIT_INFO_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindNullableText(statement.statement, 1, sha);
    try sqlite.bindNullableText(statement.statement, 2, branch);
    try sqlite.bindNullableText(statement.statement, 3, origin_url);
    try sqlite.bindText(statement.statement, 4, thread_id);
    return try finishStateUpdate(statement);
}

const StateUpdateStatement = struct {
    db: *sqlite.Db,
    statement: *sqlite.Statement,

    fn deinit(self: StateUpdateStatement) void {
        sqlite.finalize(self.statement);
        sqlite.close(self.db);
    }
};

fn prepareStateUpdate(allocator: std.mem.Allocator, codex_home: []const u8, query: []const u8) !?StateUpdateStatement {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadWrite(allocator, state_path);
    errdefer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, query) catch |err| switch (err) {
        error.SqlitePrepareFailed => {
            sqlite.close(db);
            return null;
        },
        else => return err,
    };
    errdefer sqlite.finalize(statement);
    return .{ .db = db, .statement = statement };
}

fn finishStateUpdate(statement: StateUpdateStatement) !bool {
    defer statement.deinit();
    switch (sqlite.step(statement.statement)) {
        sqlite.SQLITE_DONE => return sqlite.changes(statement.db) > 0,
        else => return error.StateDbThreadUpdateStepFailed,
    }
}

fn stateRolloutPath(allocator: std.mem.Allocator, codex_home: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ codex_home, path });
}
