const std = @import("std");

const cli_utils = @import("cli_utils.zig");

pub fn change(path: []const u8) !void {
    try std.Io.Threaded.chdir(path);
}

pub fn enforceTrustedGitRepository(allocator: std.mem.Allocator, skip_check: bool) !void {
    if (skip_check) return;
    if (try isInsideGitRepository(allocator, null)) return;

    try cli_utils.writeStderr("Not inside a trusted directory and --skip-git-repo-check was not specified.\n");
    return error.UntrustedDirectory;
}

pub fn isInsideGitRepository(allocator: std.mem.Allocator, cwd: ?[]const u8) !bool {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const run_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const result = std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .cwd = run_cwd,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(10_000),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0 and std.mem.trim(u8, result.stdout, " \t\r\n").len > 0,
        else => false,
    };
}

test "git repository detection distinguishes trusted directories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    const root = try std.fmt.allocPrint(allocator, "/tmp/codex-zig-git-check-{d}", .{timestamp});
    defer allocator.free(root);

    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.testing.expect(!try isInsideGitRepository(allocator, root));
    try runGitForTest(allocator, root, &.{ "init", "--quiet" });
    try std.testing.expect(try isInsideGitRepository(allocator, root));
}

fn runGitForTest(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    @memcpy(argv[1..], args);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(10_000),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandTerminated,
    }
}
