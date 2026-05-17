const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const env = @import("env.zig");

pub const Result = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn applyUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, false);
}

pub fn checkUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, true);
}

fn runGitApply(allocator: std.mem.Allocator, diff: []const u8, check_only: bool) !Result {
    const git_root = try resolveGitRoot(allocator);
    defer allocator.free(git_root);

    const patch_path = try writeTemporaryPatch(allocator, diff);
    defer {
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), patch_path) catch {};
        allocator.free(patch_path);
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "apply");
    if (check_only) try argv.append(allocator, "--check");
    try argv.append(allocator, "--3way");
    try argv.append(allocator, patch_path);

    const process_result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv.items,
        .cwd = .{ .path = git_root },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    errdefer allocator.free(process_result.stdout);
    errdefer allocator.free(process_result.stderr);

    switch (process_result.term) {
        .exited => |code| return .{
            .exit_code = code,
            .stdout = process_result.stdout,
            .stderr = process_result.stderr,
        },
        else => return error.GitApplyTerminated,
    }
}

pub fn isUnifiedDiff(diff: []const u8) bool {
    return std.mem.indexOf(u8, diff, "diff --git ") != null or
        (hasDiffHeader(diff, "--- ") and hasDiffHeader(diff, "+++ "));
}

fn hasDiffHeader(diff: []const u8, comptime header: []const u8) bool {
    return std.mem.startsWith(u8, diff, header) or std.mem.indexOf(u8, diff, "\n" ++ header) != null;
}

fn resolveGitRoot(allocator: std.mem.Allocator) ![]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            try cli_utils.writeStderr(result.stderr);
            return error.NotGitRepository;
        },
        else => return error.GitRevParseTerminated,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyGitRoot;
    return allocator.dupe(u8, trimmed);
}

fn writeTemporaryPatch(allocator: std.mem.Allocator, diff: []const u8) ![]const u8 {
    const tmpdir = try env.getOwned(allocator, "TMPDIR");
    defer if (tmpdir) |value| allocator.free(value);
    const dir = tmpdir orelse "/tmp";

    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);

    const filename = try std.fmt.allocPrint(allocator, "codex-zig-apply-{d}-{x}.diff", .{ timestamp, random_id });
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = diff });
    return path;
}

test "detects unified git diffs" {
    try std.testing.expect(isUnifiedDiff("diff --git a/a.txt b/a.txt\n"));
    try std.testing.expect(isUnifiedDiff("--- a/a.txt\n+++ b/a.txt\n"));
    try std.testing.expect(!isUnifiedDiff("not a patch"));
}
