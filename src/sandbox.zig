const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");

const sandbox_exec_path = "/usr/bin/sandbox-exec";

pub const SandboxedArgv = struct {
    argv: []const []const u8,
    profile: []const u8,

    pub fn deinit(self: *const SandboxedArgv, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.profile);
    }
};

pub fn shouldSandbox(mode: config.SandboxMode) bool {
    return switch (mode) {
        .danger_full_access => false,
        .read_only, .workspace_write => builtin.os.tag == .macos,
    };
}

pub fn wrapArgv(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    argv: []const []const u8,
    additional_writable_roots: []const []const u8,
) !SandboxedArgv {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    const resolved_roots = if (mode == .workspace_write)
        try resolveAdditionalRoots(allocator, additional_writable_roots)
    else
        try allocator.alloc([]const u8, 0);
    defer freeResolvedRoots(allocator, resolved_roots);

    const profile = try buildProfile(allocator, mode, cwd, resolved_roots);
    errdefer allocator.free(profile);

    var wrapped = try allocator.alloc([]const u8, argv.len + 4);
    errdefer allocator.free(wrapped);
    wrapped[0] = sandbox_exec_path;
    wrapped[1] = "-p";
    wrapped[2] = profile;
    wrapped[3] = "--";
    @memcpy(wrapped[4..], argv);

    return .{ .argv = wrapped, .profile = profile };
}

fn buildProfile(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
) ![]const u8 {
    return switch (mode) {
        .danger_full_access => error.SandboxNotNeeded,
        .read_only => allocator.dupe(u8, baseProfile ++ readOnlyWritePolicy),
        .workspace_write => blk: {
            var profile = std.ArrayList(u8).empty;
            errdefer profile.deinit(allocator);
            try profile.appendSlice(allocator, baseProfile);
            try profile.appendSlice(allocator,
                \\(deny file-write*)
                \\(allow file-write* (literal "/dev/null"))
                \\
            );
            try appendWritableSubpath(allocator, &profile, cwd);
            for (additional_writable_roots) |root| {
                try appendWritableSubpath(allocator, &profile, root);
            }
            break :blk try profile.toOwnedSlice(allocator);
        },
    };
}

fn resolveAdditionalRoots(allocator: std.mem.Allocator, roots: []const []const u8) ![]const []const u8 {
    var resolved = try allocator.alloc([]const u8, roots.len);
    errdefer allocator.free(resolved);

    var count: usize = 0;
    errdefer {
        for (resolved[0..count]) |root| allocator.free(root);
    }

    for (roots) |root| {
        const real_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), root, allocator);
        defer allocator.free(real_path);
        resolved[count] = try allocator.dupe(u8, real_path);
        count += 1;
    }

    return resolved;
}

fn freeResolvedRoots(allocator: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |root| allocator.free(root);
    allocator.free(roots);
}

fn appendWritableSubpath(allocator: std.mem.Allocator, profile: *std.ArrayList(u8), path: []const u8) !void {
    const escaped = try escapeSeatbeltString(allocator, path);
    defer allocator.free(escaped);
    const line = try std.fmt.allocPrint(allocator, "(allow file-write* (subpath \"{s}\"))\n", .{escaped});
    defer allocator.free(line);
    try profile.appendSlice(allocator, line);
}

fn escapeSeatbeltString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);

    for (value) |byte| {
        if (byte == '"' or byte == '\\') try escaped.append(allocator, '\\');
        try escaped.append(allocator, byte);
    }

    return escaped.toOwnedSlice(allocator);
}

const baseProfile =
    \\(version 1)
    \\(allow default)
;

const readOnlyWritePolicy =
    \\(deny file-write*)
    \\(allow file-write* (literal "/dev/null"))
    \\
;

test "wrap argv builds sandbox-exec command" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/echo", "ok" };

    var wrapped = try wrapArgv(allocator, .read_only, argv[0..], &.{});
    defer wrapped.deinit(allocator);

    try std.testing.expectEqualStrings(sandbox_exec_path, wrapped.argv[0]);
    try std.testing.expectEqualStrings("-p", wrapped.argv[1]);
    try std.testing.expectEqualStrings("--", wrapped.argv[3]);
    try std.testing.expectEqualStrings("/bin/echo", wrapped.argv[4]);
}

test "seatbelt string escaping handles quotes and backslashes" {
    const allocator = std.testing.allocator;
    const escaped = try escapeSeatbeltString(allocator, "a\"b\\c");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c", escaped);
}

test "read-only sandbox denies file writes" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "blocked.txt" });
    defer allocator.free(target);

    const profile = try buildProfile(allocator, .read_only, root, &.{});
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(allocator, "printf nope > {s}", .{target});
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}

test "workspace-write sandbox allows cwd writes and denies outside writes" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var allowed_dir = std.testing.tmpDir(.{});
    defer allowed_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();

    const allowed_root = try allowed_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(allowed_root);
    const blocked_root = try blocked_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(blocked_root);
    const allowed_target = try std.fs.path.join(allocator, &.{ allowed_root, "allowed.txt" });
    defer allocator.free(allowed_target);
    const blocked_target = try std.fs.path.join(allocator, &.{ blocked_root, "blocked.txt" });
    defer allocator.free(blocked_target);

    const profile = try buildProfile(allocator, .workspace_write, allowed_root, &.{});
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf ok > {s}; printf nope > {s}",
        .{ allowed_target, blocked_target },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try allowed_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "allowed.txt", .{});
    try std.testing.expectError(error.FileNotFound, blocked_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}

test "workspace-write sandbox allows additional writable roots" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var cwd_dir = std.testing.tmpDir(.{});
    defer cwd_dir.cleanup();
    var extra_dir = std.testing.tmpDir(.{});
    defer extra_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();

    const cwd_root = try cwd_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_root);
    const extra_root = try extra_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(extra_root);
    const blocked_root = try blocked_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(blocked_root);

    const extra_target = try std.fs.path.join(allocator, &.{ extra_root, "extra.txt" });
    defer allocator.free(extra_target);
    const blocked_target = try std.fs.path.join(allocator, &.{ blocked_root, "blocked.txt" });
    defer allocator.free(blocked_target);

    const additional_roots = [_][]const u8{extra_root};
    const profile = try buildProfile(allocator, .workspace_write, cwd_root, additional_roots[0..]);
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf ok > {s}; printf nope > {s}",
        .{ extra_target, blocked_target },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try extra_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "extra.txt", .{});
    try std.testing.expectError(error.FileNotFound, blocked_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}
