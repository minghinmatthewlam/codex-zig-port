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

const LIST_ROLLOUT_PATHS_WITH_LIFECYCLE_METADATA_QUERY =
    \\SELECT id, rollout_path, title, memory_mode, git_sha, git_branch, git_origin_url,
    \\       created_at_ms, updated_at_ms, source, thread_source, agent_nickname, agent_role,
    \\       archived
    \\FROM threads
    \\WHERE rollout_path IS NOT NULL AND rollout_path != ''
    \\ORDER BY id ASC
;

const LIST_ROLLOUT_PATHS_WITH_SUMMARY_METADATA_QUERY =
    \\SELECT id, rollout_path, title, memory_mode, git_sha, git_branch, git_origin_url,
    \\       created_at_ms, updated_at_ms, source, thread_source, agent_nickname, agent_role,
    \\       model_provider, cwd, cli_version, first_user_message, archived
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

const THREAD_LIFECYCLE_METADATA_QUERY =
    \\SELECT title, memory_mode, git_sha, git_branch, git_origin_url,
    \\       created_at_ms, updated_at_ms, source, thread_source, agent_nickname, agent_role
    \\FROM threads
    \\WHERE id = ?
;

const THREAD_SUMMARY_METADATA_QUERY =
    \\SELECT title, memory_mode, git_sha, git_branch, git_origin_url,
    \\       created_at_ms, updated_at_ms, source, thread_source, agent_nickname, agent_role,
    \\       model_provider, model, reasoning_effort, cwd, cli_version, first_user_message
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
    lifecycle_loaded: bool = false,
    title: ?[]const u8,
    memory_mode: ?[]const u8,
    created_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
    source: ?[]const u8 = null,
    thread_source: ?[]const u8 = null,
    agent_nickname: ?[]const u8 = null,
    agent_role: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cli_version: ?[]const u8 = null,
    first_user_message: ?[]const u8 = null,
    git_sha: ?[]const u8,
    git_branch: ?[]const u8,
    git_origin_url: ?[]const u8,

    pub fn deinit(self: ThreadMetadata, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.memory_mode) |value| allocator.free(value);
        if (self.source) |value| allocator.free(value);
        if (self.thread_source) |value| allocator.free(value);
        if (self.agent_nickname) |value| allocator.free(value);
        if (self.agent_role) |value| allocator.free(value);
        if (self.model_provider) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.reasoning_effort) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.cli_version) |value| allocator.free(value);
        if (self.first_user_message) |value| allocator.free(value);
        if (self.git_sha) |value| allocator.free(value);
        if (self.git_branch) |value| allocator.free(value);
        if (self.git_origin_url) |value| allocator.free(value);
    }
};

const StateListQueryKind = enum {
    basic,
    metadata,
    lifecycle,
    summary,
};

pub fn listRolloutFiles(allocator: std.mem.Allocator, codex_home: []const u8) ![]session_store.RolloutFile {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return allocator.alloc(session_store.RolloutFile, 0);

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    var query_kind: StateListQueryKind = .summary;
    const statement = sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_WITH_SUMMARY_METADATA_QUERY) catch |summary_err| switch (summary_err) {
        error.SqlitePrepareFailed => blk: {
            query_kind = .lifecycle;
            break :blk sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_WITH_LIFECYCLE_METADATA_QUERY) catch |lifecycle_err| switch (lifecycle_err) {
                error.SqlitePrepareFailed => metadata_blk: {
                    query_kind = .metadata;
                    break :metadata_blk sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_WITH_METADATA_QUERY) catch |metadata_err| switch (metadata_err) {
                        error.SqlitePrepareFailed => basic_blk: {
                            query_kind = .basic;
                            break :basic_blk sqlite.prepare(allocator, db, LIST_ROLLOUT_PATHS_QUERY) catch |fallback_err| switch (fallback_err) {
                                error.SqlitePrepareFailed => return allocator.alloc(session_store.RolloutFile, 0),
                                else => return fallback_err,
                            };
                        },
                        else => return metadata_err,
                    };
                },
                else => return lifecycle_err,
            };
        },
        else => return summary_err,
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
                const has_metadata_columns = query_kind != .basic;
                const has_lifecycle_columns = query_kind == .lifecycle or query_kind == .summary;
                const has_summary_columns = query_kind == .summary;
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
                const created_at_ms = if (has_lifecycle_columns) sqlite.columnNullableInt64(statement, 7) else null;
                const updated_at_ms = if (has_lifecycle_columns) sqlite.columnNullableInt64(statement, 8) else null;
                const source = if (has_lifecycle_columns) try sqlite.columnNullableTextOwned(allocator, statement, 9) else null;
                errdefer if (source) |value| allocator.free(value);
                const thread_source = if (has_lifecycle_columns) try sqlite.columnNullableTextOwned(allocator, statement, 10) else null;
                errdefer if (thread_source) |value| allocator.free(value);
                const agent_nickname = if (has_lifecycle_columns) try sqlite.columnNullableTextOwned(allocator, statement, 11) else null;
                errdefer if (agent_nickname) |value| allocator.free(value);
                const agent_role = if (has_lifecycle_columns) try sqlite.columnNullableTextOwned(allocator, statement, 12) else null;
                errdefer if (agent_role) |value| allocator.free(value);
                const model_provider = if (has_summary_columns) try sqlite.columnNullableTextOwned(allocator, statement, 13) else null;
                errdefer if (model_provider) |value| allocator.free(value);
                const cwd = if (has_summary_columns) try sqlite.columnNullableTextOwned(allocator, statement, 14) else null;
                errdefer if (cwd) |value| allocator.free(value);
                const cli_version = if (has_summary_columns) try sqlite.columnNullableTextOwned(allocator, statement, 15) else null;
                errdefer if (cli_version) |value| allocator.free(value);
                const first_user_message = if (has_summary_columns) try sqlite.columnNullableTextOwned(allocator, statement, 16) else null;
                errdefer if (first_user_message) |value| allocator.free(value);
                const archived_column: c_int = if (has_summary_columns) 17 else 13;
                const archived = has_lifecycle_columns and sqlite.columnInt64(statement, archived_column) != 0;

                try files.append(allocator, .{
                    .id = id,
                    .path = real_path,
                    .modified_at_seconds = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
                    .archived = archived,
                    .state_metadata_loaded = has_metadata_columns,
                    .state_lifecycle_loaded = has_lifecycle_columns,
                    .created_at_ms = created_at_ms,
                    .updated_at_ms = updated_at_ms,
                    .title = title,
                    .memory_mode = memory_mode,
                    .source = source,
                    .thread_source = thread_source,
                    .agent_nickname = agent_nickname,
                    .agent_role = agent_role,
                    .model_provider = model_provider,
                    .cwd = cwd,
                    .cli_version = cli_version,
                    .first_user_message = first_user_message,
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

const StateMetadataQueryKind = enum {
    metadata,
    lifecycle,
    summary,
};

pub fn findThreadMetadataByThreadId(allocator: std.mem.Allocator, codex_home: []const u8, thread_id: []const u8) !?ThreadMetadata {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    var query_kind: StateMetadataQueryKind = .summary;
    const statement = sqlite.prepare(allocator, db, THREAD_SUMMARY_METADATA_QUERY) catch |summary_err| switch (summary_err) {
        error.SqlitePrepareFailed => blk: {
            query_kind = .lifecycle;
            break :blk sqlite.prepare(allocator, db, THREAD_LIFECYCLE_METADATA_QUERY) catch |lifecycle_err| switch (lifecycle_err) {
                error.SqlitePrepareFailed => metadata_blk: {
                    query_kind = .metadata;
                    break :metadata_blk sqlite.prepare(allocator, db, THREAD_METADATA_QUERY) catch |metadata_err| switch (metadata_err) {
                        error.SqlitePrepareFailed => return null,
                        else => return metadata_err,
                    };
                },
                else => return lifecycle_err,
            };
        },
        else => return summary_err,
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
            const lifecycle_loaded = query_kind == .lifecycle or query_kind == .summary;
            const summary_loaded = query_kind == .summary;
            const created_at_ms = if (lifecycle_loaded) sqlite.columnNullableInt64(statement, 5) else null;
            const updated_at_ms = if (lifecycle_loaded) sqlite.columnNullableInt64(statement, 6) else null;
            const source = if (lifecycle_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 7) else null;
            errdefer if (source) |value| allocator.free(value);
            const thread_source = if (lifecycle_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 8) else null;
            errdefer if (thread_source) |value| allocator.free(value);
            const agent_nickname = if (lifecycle_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 9) else null;
            errdefer if (agent_nickname) |value| allocator.free(value);
            const agent_role = if (lifecycle_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 10) else null;
            errdefer if (agent_role) |value| allocator.free(value);
            const model_provider = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 11) else null;
            errdefer if (model_provider) |value| allocator.free(value);
            const model = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 12) else null;
            errdefer if (model) |value| allocator.free(value);
            const reasoning_effort = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 13) else null;
            errdefer if (reasoning_effort) |value| allocator.free(value);
            const cwd = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 14) else null;
            errdefer if (cwd) |value| allocator.free(value);
            const cli_version = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 15) else null;
            errdefer if (cli_version) |value| allocator.free(value);
            const first_user_message = if (summary_loaded) try sqlite.columnNullableTextOwned(allocator, statement, 16) else null;
            errdefer if (first_user_message) |value| allocator.free(value);
            return ThreadMetadata{
                .lifecycle_loaded = lifecycle_loaded,
                .title = title,
                .memory_mode = memory_mode,
                .created_at_ms = created_at_ms,
                .updated_at_ms = updated_at_ms,
                .source = source,
                .thread_source = thread_source,
                .agent_nickname = agent_nickname,
                .agent_role = agent_role,
                .model_provider = model_provider,
                .model = model,
                .reasoning_effort = reasoning_effort,
                .cwd = cwd,
                .cli_version = cli_version,
                .first_user_message = first_user_message,
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
