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

const THREAD_EXISTS_QUERY =
    \\SELECT 1
    \\FROM threads
    \\WHERE id = ?
;

const THREAD_GOAL_QUERY =
    \\SELECT
    \\    thread_id,
    \\    goal_id,
    \\    objective,
    \\    status,
    \\    token_budget,
    \\    tokens_used,
    \\    time_used_seconds,
    \\    created_at_ms,
    \\    updated_at_ms
    \\FROM thread_goals
    \\WHERE thread_id = ?
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

const REPLACE_THREAD_GOAL_QUERY =
    \\INSERT INTO thread_goals (
    \\    thread_id,
    \\    goal_id,
    \\    objective,
    \\    status,
    \\    token_budget,
    \\    tokens_used,
    \\    time_used_seconds,
    \\    created_at_ms,
    \\    updated_at_ms
    \\) VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
    \\ON CONFLICT(thread_id) DO UPDATE SET
    \\    goal_id = excluded.goal_id,
    \\    objective = excluded.objective,
    \\    status = excluded.status,
    \\    token_budget = excluded.token_budget,
    \\    tokens_used = 0,
    \\    time_used_seconds = 0,
    \\    created_at_ms = excluded.created_at_ms,
    \\    updated_at_ms = excluded.updated_at_ms
;

const UPDATE_THREAD_GOAL_QUERY =
    \\UPDATE thread_goals
    \\SET status = ?, token_budget = ?, updated_at_ms = ?
    \\WHERE thread_id = ?
;

const SAVE_THREAD_GOAL_SNAPSHOT_QUERY =
    \\INSERT INTO thread_goals (
    \\    thread_id,
    \\    goal_id,
    \\    objective,
    \\    status,
    \\    token_budget,
    \\    tokens_used,
    \\    time_used_seconds,
    \\    created_at_ms,
    \\    updated_at_ms
    \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    \\ON CONFLICT(thread_id) DO UPDATE SET
    \\    objective = excluded.objective,
    \\    status = excluded.status,
    \\    token_budget = excluded.token_budget,
    \\    tokens_used = excluded.tokens_used,
    \\    time_used_seconds = excluded.time_used_seconds,
    \\    created_at_ms = excluded.created_at_ms,
    \\    updated_at_ms = excluded.updated_at_ms
;

const SAVE_REPLACED_THREAD_GOAL_SNAPSHOT_QUERY =
    \\INSERT INTO thread_goals (
    \\    thread_id,
    \\    goal_id,
    \\    objective,
    \\    status,
    \\    token_budget,
    \\    tokens_used,
    \\    time_used_seconds,
    \\    created_at_ms,
    \\    updated_at_ms
    \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    \\ON CONFLICT(thread_id) DO UPDATE SET
    \\    goal_id = excluded.goal_id,
    \\    objective = excluded.objective,
    \\    status = excluded.status,
    \\    token_budget = excluded.token_budget,
    \\    tokens_used = excluded.tokens_used,
    \\    time_used_seconds = excluded.time_used_seconds,
    \\    created_at_ms = excluded.created_at_ms,
    \\    updated_at_ms = excluded.updated_at_ms
;

const DELETE_THREAD_GOAL_QUERY =
    \\DELETE FROM thread_goals
    \\WHERE thread_id = ?
;

const DELETE_THREAD_QUERY =
    \\DELETE FROM threads
    \\WHERE id = ?
;

const DELETE_THREAD_SPAWN_EDGES_QUERY =
    \\DELETE FROM thread_spawn_edges
    \\WHERE parent_thread_id = ? OR child_thread_id = ?
;

const UPDATE_ARCHIVE_QUERY =
    \\UPDATE threads
    \\SET rollout_path = ?, archived = 1, archived_at = ?, updated_at = ?, updated_at_ms = ?
    \\WHERE id = ?
;

const UPDATE_UNARCHIVE_QUERY =
    \\UPDATE threads
    \\SET rollout_path = ?, archived = 0, archived_at = NULL, updated_at = ?, updated_at_ms = ?
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

pub const ThreadGoal = struct {
    thread_id: []const u8,
    goal_id: []const u8,
    objective: []const u8,
    status: []const u8,
    token_budget: ?i64,
    tokens_used: i64,
    time_used_seconds: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: ThreadGoal, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_id);
        allocator.free(self.goal_id);
        allocator.free(self.objective);
        allocator.free(self.status);
    }
};

pub const ThreadGoalUpdate = struct {
    status: ?[]const u8 = null,
    token_budget_present: bool = false,
    token_budget: ?i64 = null,
};

pub const ThreadGoalSnapshot = struct {
    objective: []const u8,
    status: []const u8,
    token_budget: ?i64,
    tokens_used: i64,
    time_used_seconds: i64,
    created_at: i64,
    updated_at: i64,
};

const StateListQueryKind = enum {
    basic,
    metadata,
    lifecycle,
    summary,
};

pub fn listRolloutFiles(allocator: std.mem.Allocator, codex_home: []const u8, sqlite_home: []const u8) ![]session_store.RolloutFile {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
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

pub fn findRolloutPathByThreadId(allocator: std.mem.Allocator, codex_home: []const u8, sqlite_home: []const u8, thread_id: []const u8) !?[]const u8 {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
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

pub fn findThreadMetadataByThreadId(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !?ThreadMetadata {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
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

pub fn stateDbThreadExists(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !bool {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return false;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, THREAD_EXISTS_QUERY) catch |err| switch (err) {
        error.SqlitePrepareFailed => return false,
        else => return err,
    };
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, thread_id);

    return switch (sqlite.step(statement)) {
        sqlite.SQLITE_ROW => true,
        sqlite.SQLITE_DONE => false,
        else => error.StateDbThreadMetadataStepFailed,
    };
}

pub fn findThreadGoalByThreadId(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !?ThreadGoal {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = sqlite.prepare(allocator, db, THREAD_GOAL_QUERY) catch |err| switch (err) {
        error.SqlitePrepareFailed => return null,
        else => return err,
    };
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, thread_id);

    return switch (sqlite.step(statement)) {
        sqlite.SQLITE_ROW => try threadGoalFromStatement(allocator, statement),
        sqlite.SQLITE_DONE => null,
        else => error.StateDbThreadMetadataStepFailed,
    };
}

pub fn updateThreadTitle(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8, title: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_TITLE_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, title);
    try sqlite.bindText(statement.statement, 2, thread_id);
    return try finishStateUpdate(statement);
}

pub fn updateThreadMemoryMode(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8, mode: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_MEMORY_MODE_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, mode);
    try sqlite.bindText(statement.statement, 2, thread_id);
    return try finishStateUpdate(statement);
}

pub fn updateThreadGitInfo(
    allocator: std.mem.Allocator,
    sqlite_home: []const u8,
    thread_id: []const u8,
    sha: ?[]const u8,
    branch: ?[]const u8,
    origin_url: ?[]const u8,
) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_GIT_INFO_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindNullableText(statement.statement, 1, sha);
    try sqlite.bindNullableText(statement.statement, 2, branch);
    try sqlite.bindNullableText(statement.statement, 3, origin_url);
    try sqlite.bindText(statement.statement, 4, thread_id);
    return try finishStateUpdate(statement);
}

pub fn replaceThreadGoal(
    allocator: std.mem.Allocator,
    sqlite_home: []const u8,
    thread_id: []const u8,
    objective: []const u8,
    status: []const u8,
    token_budget: ?i64,
) !?ThreadGoal {
    if (!try stateDbThreadExists(allocator, sqlite_home, thread_id)) return null;

    const statement = try prepareStateUpdate(allocator, sqlite_home, REPLACE_THREAD_GOAL_QUERY) orelse return null;
    errdefer statement.deinit();
    const goal_id = try generateUuidString(allocator);
    defer allocator.free(goal_id);
    const now_ms = currentUnixMilliseconds();
    const state_status = stateGoalStatus(statusAfterBudgetLimit(status, 0, token_budget));
    try sqlite.bindText(statement.statement, 1, thread_id);
    try sqlite.bindText(statement.statement, 2, goal_id);
    try sqlite.bindText(statement.statement, 3, objective);
    try sqlite.bindText(statement.statement, 4, state_status);
    try sqlite.bindNullableInt64(statement.statement, 5, token_budget);
    try sqlite.bindInt64(statement.statement, 6, now_ms);
    try sqlite.bindInt64(statement.statement, 7, now_ms);
    if (!try finishStateUpdate(statement)) return null;
    return findThreadGoalByThreadId(allocator, sqlite_home, thread_id);
}

pub fn updateThreadGoal(
    allocator: std.mem.Allocator,
    sqlite_home: []const u8,
    thread_id: []const u8,
    update: ThreadGoalUpdate,
) !?ThreadGoal {
    var existing = (try findThreadGoalByThreadId(allocator, sqlite_home, thread_id)) orelse return null;
    if (update.status == null and !update.token_budget_present) return existing;
    defer existing.deinit(allocator);

    var status = update.status orelse existing.status;
    if (std.mem.eql(u8, existing.status, "budgetLimited") and
        update.status != null and
        budgetLimitedPreservesStatus(update.status.?))
    {
        status = "budgetLimited";
    }
    const token_budget = if (update.token_budget_present) update.token_budget else existing.token_budget;
    status = statusAfterBudgetLimit(status, existing.tokens_used, token_budget);

    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_THREAD_GOAL_QUERY) orelse return null;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, stateGoalStatus(status));
    try sqlite.bindNullableInt64(statement.statement, 2, token_budget);
    try sqlite.bindInt64(statement.statement, 3, currentUnixMilliseconds());
    try sqlite.bindText(statement.statement, 4, thread_id);
    if (!try finishStateUpdate(statement)) return null;
    return findThreadGoalByThreadId(allocator, sqlite_home, thread_id);
}

pub fn saveThreadGoalSnapshot(
    allocator: std.mem.Allocator,
    sqlite_home: []const u8,
    thread_id: []const u8,
    snapshot: ThreadGoalSnapshot,
    replace_goal_id: bool,
) !bool {
    if (!try stateDbThreadExists(allocator, sqlite_home, thread_id)) return false;

    const query = if (replace_goal_id) SAVE_REPLACED_THREAD_GOAL_SNAPSHOT_QUERY else SAVE_THREAD_GOAL_SNAPSHOT_QUERY;
    const statement = try prepareStateUpdate(allocator, sqlite_home, query) orelse return false;
    errdefer statement.deinit();
    const goal_id = try generateUuidString(allocator);
    defer allocator.free(goal_id);
    try sqlite.bindText(statement.statement, 1, thread_id);
    try sqlite.bindText(statement.statement, 2, goal_id);
    try sqlite.bindText(statement.statement, 3, snapshot.objective);
    try sqlite.bindText(statement.statement, 4, stateGoalStatus(snapshot.status));
    try sqlite.bindNullableInt64(statement.statement, 5, snapshot.token_budget);
    try sqlite.bindInt64(statement.statement, 6, snapshot.tokens_used);
    try sqlite.bindInt64(statement.statement, 7, snapshot.time_used_seconds);
    try sqlite.bindInt64(statement.statement, 8, secondsToMilliseconds(snapshot.created_at));
    try sqlite.bindInt64(statement.statement, 9, secondsToMilliseconds(snapshot.updated_at));
    return try finishStateUpdate(statement);
}

pub fn deleteThreadGoal(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, DELETE_THREAD_GOAL_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, thread_id);
    return try finishStateUpdate(statement);
}

pub fn deleteThreadState(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !bool {
    const edges_changed = try deleteThreadSpawnEdges(allocator, sqlite_home, thread_id);
    const goal_changed = try deleteThreadGoal(allocator, sqlite_home, thread_id);
    const statement = try prepareStateUpdate(allocator, sqlite_home, DELETE_THREAD_QUERY) orelse return edges_changed or goal_changed;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, thread_id);
    const thread_changed = try finishStateUpdate(statement);
    return edges_changed or goal_changed or thread_changed;
}

fn deleteThreadSpawnEdges(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, DELETE_THREAD_SPAWN_EDGES_QUERY) orelse return false;
    errdefer statement.deinit();
    try sqlite.bindText(statement.statement, 1, thread_id);
    try sqlite.bindText(statement.statement, 2, thread_id);
    return try finishStateUpdate(statement);
}

pub fn markThreadArchived(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8, rollout_path: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_ARCHIVE_QUERY) orelse return false;
    errdefer statement.deinit();
    const times = try fileModifiedTimes(rollout_path);
    const archived_at_seconds = currentUnixSeconds();
    try sqlite.bindText(statement.statement, 1, rollout_path);
    try sqlite.bindInt64(statement.statement, 2, archived_at_seconds);
    try sqlite.bindInt64(statement.statement, 3, times.seconds);
    try sqlite.bindInt64(statement.statement, 4, times.milliseconds);
    try sqlite.bindText(statement.statement, 5, thread_id);
    return try finishStateUpdate(statement);
}

pub fn markThreadUnarchived(allocator: std.mem.Allocator, sqlite_home: []const u8, thread_id: []const u8, rollout_path: []const u8) !bool {
    const statement = try prepareStateUpdate(allocator, sqlite_home, UPDATE_UNARCHIVE_QUERY) orelse return false;
    errdefer statement.deinit();
    const times = try fileModifiedTimes(rollout_path);
    try sqlite.bindText(statement.statement, 1, rollout_path);
    try sqlite.bindInt64(statement.statement, 2, times.seconds);
    try sqlite.bindInt64(statement.statement, 3, times.milliseconds);
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

fn prepareStateUpdate(allocator: std.mem.Allocator, sqlite_home: []const u8, query: []const u8) !?StateUpdateStatement {
    const state_path = try memory_reset.resolveStateDbPathForSqliteHome(allocator, sqlite_home);
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

fn currentUnixSeconds() i64 {
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    return @intCast(@divTrunc(now_ns, std.time.ns_per_s));
}

fn currentUnixMilliseconds() i64 {
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    return @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
}

fn threadGoalFromStatement(allocator: std.mem.Allocator, statement: *sqlite.Statement) !ThreadGoal {
    const thread_id = try sqlite.columnTextOwned(allocator, statement, 0);
    errdefer allocator.free(thread_id);
    const goal_id = try sqlite.columnTextOwned(allocator, statement, 1);
    errdefer allocator.free(goal_id);
    const objective = try sqlite.columnTextOwned(allocator, statement, 2);
    errdefer allocator.free(objective);
    const raw_status = try sqlite.columnTextOwned(allocator, statement, 3);
    defer allocator.free(raw_status);
    const status = try allocator.dupe(u8, apiGoalStatus(raw_status));
    errdefer allocator.free(status);
    return .{
        .thread_id = thread_id,
        .goal_id = goal_id,
        .objective = objective,
        .status = status,
        .token_budget = sqlite.columnNullableInt64(statement, 4),
        .tokens_used = sqlite.columnInt64(statement, 5),
        .time_used_seconds = sqlite.columnInt64(statement, 6),
        .created_at = millisecondsToSeconds(sqlite.columnInt64(statement, 7)),
        .updated_at = millisecondsToSeconds(sqlite.columnInt64(statement, 8)),
    };
}

fn apiGoalStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "usage_limited")) return "usageLimited";
    if (std.mem.eql(u8, status, "budget_limited")) return "budgetLimited";
    return status;
}

fn stateGoalStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "usageLimited")) return "usage_limited";
    if (std.mem.eql(u8, status, "budgetLimited")) return "budget_limited";
    return status;
}

fn budgetLimitedPreservesStatus(requested_status: []const u8) bool {
    return std.mem.eql(u8, requested_status, "paused") or std.mem.eql(u8, requested_status, "blocked");
}

test "thread goal status maps api and stored variants" {
    try std.testing.expectEqualStrings("usageLimited", apiGoalStatus("usage_limited"));
    try std.testing.expectEqualStrings("budgetLimited", apiGoalStatus("budget_limited"));
    try std.testing.expectEqualStrings("blocked", apiGoalStatus("blocked"));

    try std.testing.expectEqualStrings("usage_limited", stateGoalStatus("usageLimited"));
    try std.testing.expectEqualStrings("budget_limited", stateGoalStatus("budgetLimited"));
    try std.testing.expectEqualStrings("blocked", stateGoalStatus("blocked"));

    try std.testing.expect(budgetLimitedPreservesStatus("paused"));
    try std.testing.expect(budgetLimitedPreservesStatus("blocked"));
    try std.testing.expect(!budgetLimitedPreservesStatus("complete"));
}

fn statusAfterBudgetLimit(status: []const u8, tokens_used: i64, token_budget: ?i64) []const u8 {
    if (std.mem.eql(u8, status, "active")) {
        if (token_budget) |budget| {
            if (tokens_used >= budget) return "budgetLimited";
        }
    }
    return status;
}

fn millisecondsToSeconds(value: i64) i64 {
    return @divFloor(value, std.time.ms_per_s);
}

fn secondsToMilliseconds(value: i64) i64 {
    return value * std.time.ms_per_s;
}

fn generateUuidString(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15],
        },
    );
}

const FileModifiedTimes = struct {
    seconds: i64,
    milliseconds: i64,
};

fn fileModifiedTimes(path: []const u8) !FileModifiedTimes {
    const stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = true });
    return .{
        .seconds = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)),
        .milliseconds = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)),
    };
}
