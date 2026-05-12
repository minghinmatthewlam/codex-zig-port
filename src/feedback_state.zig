const std = @import("std");

const memory_reset = @import("memory_reset.zig");
const sqlite = @import("sqlite.zig");

const SPAWN_DESCENDANTS_QUERY =
    \\WITH RECURSIVE subtree(child_thread_id, depth) AS (
    \\    SELECT child_thread_id, 1
    \\    FROM thread_spawn_edges
    \\    WHERE parent_thread_id = ? AND status IN ('open', 'closed')
    \\    UNION ALL
    \\    SELECT edge.child_thread_id, subtree.depth + 1
    \\    FROM thread_spawn_edges AS edge
    \\    JOIN subtree ON edge.parent_thread_id = subtree.child_thread_id
    \\    WHERE edge.status IN ('open', 'closed')
    \\)
    \\SELECT child_thread_id
    \\FROM subtree
    \\ORDER BY depth ASC, child_thread_id ASC
;

const ROLLOUT_PATH_QUERY =
    \\SELECT rollout_path
    \\FROM threads
    \\WHERE id = ?
;

pub fn appendSpawnDescendantThreadIds(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    root_thread_id: []const u8,
    thread_ids: *std.ArrayList([]const u8),
    owned_thread_ids: *std.ArrayList([]const u8),
) !void {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = try sqlite.prepare(allocator, db, SPAWN_DESCENDANTS_QUERY);
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, root_thread_id);

    while (true) {
        switch (sqlite.step(statement)) {
            sqlite.SQLITE_ROW => {
                const child_thread_id = try sqlite.columnTextOwned(allocator, statement, 0);
                if (containsString(thread_ids.items, child_thread_id)) {
                    allocator.free(child_thread_id);
                    continue;
                }
                thread_ids.append(allocator, child_thread_id) catch |err| {
                    allocator.free(child_thread_id);
                    return err;
                };
                owned_thread_ids.append(allocator, child_thread_id) catch |err| {
                    _ = thread_ids.pop();
                    allocator.free(child_thread_id);
                    return err;
                };
            },
            sqlite.SQLITE_DONE => break,
            else => return error.StateDbSpawnDescendantsStepFailed,
        }
    }
}

pub fn findRolloutPathByThreadId(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    thread_id: []const u8,
) !?[]const u8 {
    const state_path = try memory_reset.resolveStateDbPath(allocator, codex_home);
    defer allocator.free(state_path);
    if (!try memory_reset.stateDbExists(allocator, state_path)) return null;

    const db = try sqlite.openReadOnly(allocator, state_path);
    defer sqlite.close(db);

    const statement = try sqlite.prepare(allocator, db, ROLLOUT_PATH_QUERY);
    defer sqlite.finalize(statement);
    try sqlite.bindText(statement, 1, thread_id);

    switch (sqlite.step(statement)) {
        sqlite.SQLITE_ROW => return try sqlite.columnTextOwned(allocator, statement, 0),
        sqlite.SQLITE_DONE => return null,
        else => return error.StateDbRolloutPathStepFailed,
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
