const std = @import("std");

pub const Db = opaque {};
pub const Statement = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_OPEN_READONLY = 0x00000001;

extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    pp_db: *?*Db,
    flags: c_int,
    z_vfs: ?[*:0]const u8,
) c_int;
extern fn sqlite3_close(db: *Db) c_int;
extern fn sqlite3_prepare_v2(
    db: *Db,
    z_sql: [*:0]const u8,
    n_byte: c_int,
    pp_stmt: *?*Statement,
    pz_tail: ?*[*:0]const u8,
) c_int;
extern fn sqlite3_finalize(stmt: *Statement) c_int;
extern fn sqlite3_bind_text(
    stmt: *Statement,
    index: c_int,
    value: [*]const u8,
    bytes: c_int,
    destructor: ?*const anyopaque,
) c_int;
extern fn sqlite3_bind_int64(stmt: *Statement, index: c_int, value: i64) c_int;
extern fn sqlite3_step(stmt: *Statement) c_int;
extern fn sqlite3_column_int64(stmt: *Statement, column: c_int) i64;
extern fn sqlite3_column_text(stmt: *Statement, column: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *Statement, column: c_int) c_int;

pub fn openReadOnly(allocator: std.mem.Allocator, path: []const u8) !*Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db: ?*Db = null;
    if (sqlite3_open_v2(path_z.ptr, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        if (db) |handle| close(handle);
        return error.SqliteOpenFailed;
    }
    return db.?;
}

pub fn close(db: *Db) void {
    _ = sqlite3_close(db);
}

pub fn prepare(allocator: std.mem.Allocator, db: *Db, query: []const u8) !*Statement {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*Statement = null;
    if (sqlite3_prepare_v2(db, query_z.ptr, -1, &stmt, null) != SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    return stmt.?;
}

pub fn finalize(stmt: *Statement) void {
    _ = sqlite3_finalize(stmt);
}

pub fn bindText(stmt: *Statement, index: c_int, value: []const u8) !void {
    const bind_len: c_int = @intCast(value.len);
    if (sqlite3_bind_text(stmt, index, value.ptr, bind_len, null) != SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

pub fn bindInt64(stmt: *Statement, index: c_int, value: i64) !void {
    if (sqlite3_bind_int64(stmt, index, value) != SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

pub fn step(stmt: *Statement) c_int {
    return sqlite3_step(stmt);
}

pub fn columnInt64(stmt: *Statement, column: c_int) i64 {
    return sqlite3_column_int64(stmt, column);
}

pub fn columnTextOwned(allocator: std.mem.Allocator, stmt: *Statement, column: c_int) ![]const u8 {
    const text = sqlite3_column_text(stmt, column) orelse return allocator.dupe(u8, "");
    const len = sqlite3_column_bytes(stmt, column);
    if (len < 0) return error.SqliteColumnFailed;
    return allocator.dupe(u8, text[0..@intCast(len)]);
}
