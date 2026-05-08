const std = @import("std");

const CommandOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    fn deinit(self: *const CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn success(self: CommandOutput) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub fn render(allocator: std.mem.Allocator) ![]const u8 {
    var status = try runGit(allocator, &.{ "git", "status", "--short" });
    defer status.deinit(allocator);
    if (!status.success()) return gitUnavailable(allocator, status);

    var stat = try runGit(allocator, &.{ "git", "diff", "--stat" });
    defer stat.deinit(allocator);
    if (!stat.success()) return gitUnavailable(allocator, stat);

    var diff = try runGit(allocator, &.{ "git", "diff", "--" });
    defer diff.deinit(allocator);
    if (!diff.success()) return gitUnavailable(allocator, diff);

    var untracked = try runGit(allocator, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" });
    defer untracked.deinit(allocator);
    if (!untracked.success()) return gitUnavailable(allocator, untracked);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "workspace diff\n\nstatus:\n");
    try appendOrNone(allocator, &out, status.stdout, "<clean>\n");
    try out.appendSlice(allocator, "\nstat:\n");
    try appendOrNone(allocator, &out, stat.stdout, "<none>\n");
    try out.appendSlice(allocator, "\ndiff:\n");
    try appendOrNone(allocator, &out, diff.stdout, "<none>\n");
    try appendUntrackedFiles(allocator, &out, untracked.stdout);

    return out.toOwnedSlice(allocator);
}

pub fn renderCommit(allocator: std.mem.Allocator, commit: []const u8) ![]const u8 {
    try validateRevision(commit);

    var show = try runGit(allocator, &.{
        "git",
        "show",
        "--stat",
        "--patch",
        "--format=medium",
        "--no-ext-diff",
        commit,
        "--",
    });
    defer show.deinit(allocator);
    if (!show.success()) return gitUnavailable(allocator, show);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "commit diff\n\n");
    try appendOrNone(allocator, &out, show.stdout, "<none>\n");
    return out.toOwnedSlice(allocator);
}

fn runGit(allocator: std.mem.Allocator, argv: []const []const u8) !CommandOutput {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(32 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(30_000),
            .clock = .awake,
        } },
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn gitUnavailable(allocator: std.mem.Allocator, output: CommandOutput) ![]const u8 {
    const message = if (output.stderr.len > 0) output.stderr else output.stdout;
    return std.fmt.allocPrint(allocator, "git diff unavailable:\n{s}", .{message});
}

fn appendOrNone(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    empty_text: []const u8,
) !void {
    if (text.len == 0) {
        try out.appendSlice(allocator, empty_text);
    } else {
        try out.appendSlice(allocator, text);
        if (text[text.len - 1] != '\n') try out.append(allocator, '\n');
    }
}

fn appendUntrackedFiles(allocator: std.mem.Allocator, out: *std.ArrayList(u8), paths: []const u8) !void {
    if (paths.len == 0) return;

    try out.appendSlice(allocator, "\nuntracked files:\n");
    var path_iter = std.mem.splitScalar(u8, paths, 0);
    var rendered: usize = 0;
    while (path_iter.next()) |path| {
        if (path.len == 0) continue;
        if (rendered == 20) {
            try out.appendSlice(allocator, "... additional untracked files omitted\n");
            break;
        }

        try appendUntrackedFile(allocator, out, path);
        rendered += 1;
    }
}

fn appendUntrackedFile(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    try validateGitPath(path);
    const header = try std.fmt.allocPrint(allocator,
        \\diff --git a/{s} b/{s}
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/{s}
        \\@@
        \\
    , .{ path, path, path });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        allocator,
        .limited(16 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try out.appendSlice(allocator, "+<file disappeared before diff render>\n");
            return;
        },
        error.FileTooBig => {
            try out.appendSlice(allocator, "+<file exceeds 16 KiB preview limit>\n");
            return;
        },
        error.IsDir => {
            try out.appendSlice(allocator, "+<directory omitted>\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);

    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        try out.appendSlice(allocator, "+<binary or NUL-containing file omitted>\n");
        return;
    }

    try appendAddedLines(allocator, out, bytes);
}

fn appendAddedLines(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    if (bytes.len == 0) {
        try out.appendSlice(allocator, "+<empty file>\n");
        return;
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) continue;
        try out.append(allocator, '+');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

fn validateGitPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidGitPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidGitPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidGitPath;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidGitPath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGitPath;
    }
}

pub fn validateRevision(revision: []const u8) !void {
    if (revision.len == 0) return error.InvalidGitRevision;
    if (revision[0] == '-') return error.InvalidGitRevision;
    if (std.mem.indexOfScalar(u8, revision, 0) != null) return error.InvalidGitRevision;
    if (std.mem.indexOfAny(u8, revision, "\r\n") != null) return error.InvalidGitRevision;
}

test "append added lines prefixes text as a synthetic new-file diff" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendAddedLines(allocator, &out, "one\ntwo\n");

    try std.testing.expectEqualStrings("+one\n+two\n", out.items);
}

test "validate git path rejects absolute and parent traversal paths" {
    try validateGitPath("src/main.zig");
    try std.testing.expectError(error.InvalidGitPath, validateGitPath("/tmp/file"));
    try std.testing.expectError(error.InvalidGitPath, validateGitPath("../file"));
    try std.testing.expectError(error.InvalidGitPath, validateGitPath("a/../file"));
}

test "validate revision rejects option-shaped and empty values" {
    try validateRevision("abc123");
    try std.testing.expectError(error.InvalidGitRevision, validateRevision(""));
    try std.testing.expectError(error.InvalidGitRevision, validateRevision("--stat"));
    try std.testing.expectError(error.InvalidGitRevision, validateRevision("abc\n123"));
}
