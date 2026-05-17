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

pub const DiffSummary = struct {
    files_changed: usize = 0,
    lines_added: usize = 0,
    lines_removed: usize = 0,
};

pub const ApplyOutputPaths = struct {
    applied_paths: std.ArrayList([]const u8) = .empty,
    skipped_paths: std.ArrayList([]const u8) = .empty,
    conflicted_paths: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ApplyOutputPaths, allocator: std.mem.Allocator) void {
        freePathList(allocator, &self.applied_paths);
        freePathList(allocator, &self.skipped_paths);
        freePathList(allocator, &self.conflicted_paths);
    }
};

pub fn applyUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, false);
}

pub fn checkUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, true);
}

pub fn checkResultFailed(exit_code: u8, stdout: []const u8, stderr: []const u8) bool {
    return exit_code != 0 or checkOutputHasConflicts(stdout) or checkOutputHasConflicts(stderr);
}

pub fn diffSummary(diff: []const u8) DiffSummary {
    var summary = DiffSummary{};
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            summary.files_changed += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "@@")) {
            continue;
        }
        if (line.len == 0) continue;
        if (line[0] == '+') summary.lines_added += 1;
        if (line[0] == '-') summary.lines_removed += 1;
    }
    if (summary.files_changed == 0 and std.mem.trim(u8, diff, " \t\r\n").len > 0) summary.files_changed = 1;
    return summary;
}

pub fn parseApplyOutputPaths(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) !ApplyOutputPaths {
    var paths = ApplyOutputPaths{};
    errdefer paths.deinit(allocator);

    var last_seen_path: ?[]const u8 = null;
    try parseApplyOutputText(allocator, &paths, &last_seen_path, stdout);
    try parseApplyOutputText(allocator, &paths, &last_seen_path, stderr);
    return paths;
}

pub fn formatPathSummary(allocator: std.mem.Allocator, label: []const u8, paths: []const []const u8) !?[]u8 {
    if (paths.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{s} ({d}):\n", .{ label, paths.len });
    for (paths) |path| {
        try out.writer.print("  {s}\n", .{path});
    }
    return try out.toOwnedSlice();
}

fn checkOutputHasConflicts(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (std.mem.endsWith(u8, trimmed, " with conflicts.")) return true;
    }
    return false;
}

const PathKind = enum {
    applied,
    skipped,
    conflicted,
};

fn parseApplyOutputText(
    allocator: std.mem.Allocator,
    paths: *ApplyOutputPaths,
    last_seen_path: *?[]const u8,
    text: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        try parseApplyOutputLine(allocator, paths, last_seen_path, raw_line);
    }
}

fn parseApplyOutputLine(
    allocator: std.mem.Allocator,
    paths: *ApplyOutputPaths,
    last_seen_path: *?[]const u8,
    raw_line: []const u8,
) !void {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return;

    if (extractCheckingPatchPath(line)) |path| {
        last_seen_path.* = path;
        return;
    }
    if (extractAppliedStatusPath(line, " cleanly.")) |path| {
        try recordPath(allocator, paths, .applied, path);
        last_seen_path.* = path;
        return;
    }
    if (extractAppliedStatusPath(line, " cleanly")) |path| {
        try recordPath(allocator, paths, .applied, path);
        last_seen_path.* = path;
        return;
    }
    if (extractAppliedStatusPath(line, " with conflicts.")) |path| {
        try recordPath(allocator, paths, .conflicted, path);
        last_seen_path.* = path;
        return;
    }
    if (extractAppliedStatusPath(line, " with conflicts")) |path| {
        try recordPath(allocator, paths, .conflicted, path);
        last_seen_path.* = path;
        return;
    }
    if (extractApplyingWithRejectsPath(line)) |path| {
        try recordPath(allocator, paths, .conflicted, path);
        last_seen_path.* = path;
        return;
    }
    if (line.len > 2 and line[0] == 'U' and std.ascii.isWhitespace(line[1])) {
        const path = std.mem.trim(u8, line[2..], " \t");
        try recordPath(allocator, paths, .conflicted, path);
        last_seen_path.* = path;
        return;
    }
    if (extractPatchFailedPath(line)) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractErrorPathWithSuffix(line, ": patch does not apply")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractErrorPathWithSuffix(line, ": does not match index")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractErrorPathWithSuffix(line, ": does not exist in index")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractErrorPathBeforeMarker(line, " already exists in ")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractRenamedDeletedPath(line)) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractBinaryPath(line, "error: cannot apply binary patch to ", " without full index line")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractBinaryPath(line, "error: binary patch does not apply to ", "")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractBinaryPath(line, "error: binary patch to ", " creates incorrect result")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractBinaryPath(line, "error: cannot read the current contents of ", "")) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractSkippedPatchPath(line)) |path| {
        try recordPath(allocator, paths, .skipped, path);
        last_seen_path.* = path;
        return;
    }
    if (extractCannotMergeBinaryWarningPath(line)) |path| {
        try recordPath(allocator, paths, .conflicted, path);
        last_seen_path.* = path;
        return;
    }
    if (isThreeWayFailureLine(line) or isLacksBlobLine(line)) {
        if (last_seen_path.*) |path| {
            try recordPath(allocator, paths, .skipped, path);
        }
        return;
    }
}

fn extractCheckingPatchPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "Checking patch ") orelse return null;
    const path = stripSuffixIgnoreCase(rest, "...") orelse return null;
    return std.mem.trim(u8, path, " \t");
}

fn extractAppliedStatusPath(line: []const u8, suffix: []const u8) ?[]const u8 {
    const rest = (stripPrefixIgnoreCase(line, "Applied patch to ") orelse
        stripPrefixIgnoreCase(line, "Applied patch ")) orelse return null;
    const path = stripSuffixIgnoreCase(rest, suffix) orelse return null;
    return std.mem.trim(u8, path, " \t");
}

fn extractApplyingWithRejectsPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "Applying patch ") orelse return null;
    const marker_index = indexOfIgnoreCase(rest, " with ") orelse return null;
    const suffix = rest[marker_index..];
    if (indexOfIgnoreCase(suffix, " reject") == null) return null;
    return std.mem.trim(u8, rest[0..marker_index], " \t");
}

fn extractPatchFailedPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "error: patch failed: ") orelse return null;
    if (indexOfIgnoreCase(rest, " File exists")) |index| {
        return std.mem.trim(u8, rest[0..index], " \t");
    }
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        if (allAsciiDigits(rest[colon + 1 ..])) {
            return std.mem.trim(u8, rest[0..colon], " \t");
        }
    }
    return std.mem.trim(u8, rest, " \t");
}

fn extractErrorPathWithSuffix(line: []const u8, suffix: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "error: ") orelse return null;
    const path = stripSuffixIgnoreCase(rest, suffix) orelse return null;
    return std.mem.trim(u8, path, " \t");
}

fn extractErrorPathBeforeMarker(line: []const u8, marker: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "error: ") orelse return null;
    const marker_index = indexOfIgnoreCase(rest, marker) orelse return null;
    return std.mem.trim(u8, rest[0..marker_index], " \t");
}

fn extractRenamedDeletedPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "error: path ") orelse return null;
    const path = stripSuffixIgnoreCase(rest, " has been renamed/deleted") orelse return null;
    return std.mem.trim(u8, path, " \t");
}

fn extractBinaryPath(line: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, prefix) orelse return null;
    const path = if (suffix.len == 0)
        rest
    else if (stripSuffixIgnoreCase(rest, suffix)) |without_suffix|
        without_suffix
    else
        return null;
    return std.mem.trim(u8, path, " \t");
}

fn extractSkippedPatchPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "Skipped patch ") orelse return null;
    const path = stripSuffixIgnoreCase(rest, ".") orelse rest;
    return std.mem.trim(u8, path, " \t");
}

fn extractCannotMergeBinaryWarningPath(line: []const u8) ?[]const u8 {
    const rest = stripPrefixIgnoreCase(line, "warning: Cannot merge binary files: ") orelse return null;
    const marker_index = indexOfIgnoreCase(rest, " (ours vs. theirs)") orelse return null;
    return std.mem.trim(u8, rest[0..marker_index], " \t");
}

fn isThreeWayFailureLine(line: []const u8) bool {
    return std.ascii.eqlIgnoreCase(line, "Failed to perform three-way merge...");
}

fn isLacksBlobLine(line: []const u8) bool {
    const rest = stripPrefixIgnoreCase(line, "error: ") orelse line;
    return std.ascii.eqlIgnoreCase(rest, "repository lacks the necessary blob to perform 3-way merge.") or
        std.ascii.eqlIgnoreCase(rest, "repository lacks the necessary blob to perform 3-way merge") or
        std.ascii.eqlIgnoreCase(rest, "repository lacks the necessary blob to fall back on 3-way merge.") or
        std.ascii.eqlIgnoreCase(rest, "repository lacks the necessary blob to fall back on 3-way merge");
}

fn recordPath(allocator: std.mem.Allocator, paths: *ApplyOutputPaths, kind: PathKind, raw_path: []const u8) !void {
    const normalized = try duplicateNormalizedPath(allocator, raw_path) orelse return;
    errdefer allocator.free(normalized);

    switch (kind) {
        .applied => {
            removePath(allocator, &paths.skipped_paths, normalized);
            removePath(allocator, &paths.conflicted_paths, normalized);
            try appendUniqueOwnedPath(allocator, &paths.applied_paths, normalized);
        },
        .skipped => {
            removePath(allocator, &paths.applied_paths, normalized);
            removePath(allocator, &paths.conflicted_paths, normalized);
            try appendUniqueOwnedPath(allocator, &paths.skipped_paths, normalized);
        },
        .conflicted => {
            removePath(allocator, &paths.applied_paths, normalized);
            removePath(allocator, &paths.skipped_paths, normalized);
            try appendUniqueOwnedPath(allocator, &paths.conflicted_paths, normalized);
        },
    }
}

fn duplicateNormalizedPath(allocator: std.mem.Allocator, raw_path: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' or first == '\'') and last == first) {
            return try unescapeCStyle(allocator, trimmed[1 .. trimmed.len - 1]);
        }
    }
    return try allocator.dupe(u8, trimmed);
}

fn unescapeCStyle(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const ch = input[index];
        index += 1;
        if (ch != '\\') {
            try out.append(allocator, ch);
            continue;
        }
        if (index >= input.len) {
            try out.append(allocator, '\\');
            break;
        }
        const escaped = input[index];
        index += 1;
        switch (escaped) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            'a' => try out.append(allocator, 0x07),
            'v' => try out.append(allocator, 0x0b),
            '\\' => try out.append(allocator, '\\'),
            '"' => try out.append(allocator, '"'),
            '\'' => try out.append(allocator, '\''),
            '0'...'7' => {
                var value: u8 = escaped - '0';
                var octal_count: u8 = 0;
                while (octal_count < 2 and index < input.len and input[index] >= '0' and input[index] <= '7') : (octal_count += 1) {
                    value = value * 8 + (input[index] - '0');
                    index += 1;
                }
                try out.append(allocator, value);
            },
            else => try out.append(allocator, escaped),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendUniqueOwnedPath(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), owned_path: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, owned_path)) {
            allocator.free(owned_path);
            return;
        }
    }
    try list.append(allocator, owned_path);
}

fn removePath(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) void {
    var index: usize = 0;
    while (index < list.items.len) {
        if (std.mem.eql(u8, list.items[index], path)) {
            const removed = list.orderedRemove(index);
            allocator.free(removed);
            continue;
        }
        index += 1;
    }
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn stripPrefixIgnoreCase(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (value.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    return value[prefix.len..];
}

fn stripSuffixIgnoreCase(value: []const u8, suffix: []const u8) ?[]const u8 {
    if (value.len < suffix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix)) return null;
    return value[0 .. value.len - suffix.len];
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn allAsciiDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
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

test "detects failed git apply check output" {
    try std.testing.expect(checkResultFailed(0, "", "Applied patch to 'README.md' with conflicts.\n"));
    try std.testing.expect(checkResultFailed(1, "", "error: patch failed\n"));
    try std.testing.expect(!checkResultFailed(0, "", "Applied patch to 'with conflicts.txt' cleanly.\n"));
    try std.testing.expect(!checkResultFailed(
        0,
        "",
        "error: repository lacks the necessary blob to perform 3-way merge.\nFalling back to direct application...\n",
    ));
}

test "summarizes unified diff contents" {
    const summary = diffSummary(
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,2 +1,3 @@
        \\ same
        \\-old
        \\+new
        \\+extra
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), summary.files_changed);
    try std.testing.expectEqual(@as(usize, 2), summary.lines_added);
    try std.testing.expectEqual(@as(usize, 1), summary.lines_removed);
}

test "parses git apply output path groups" {
    const allocator = std.testing.allocator;
    var paths = try parseApplyOutputPaths(
        allocator,
        "Applied patch to 'src/app.zig' cleanly.\n",
        "Applied patch to 'README.md' with conflicts.\nerror: patch failed: docs/guide.md:12\n",
    );
    defer paths.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), paths.applied_paths.items.len);
    try std.testing.expectEqualStrings("src/app.zig", paths.applied_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), paths.conflicted_paths.items.len);
    try std.testing.expectEqualStrings("README.md", paths.conflicted_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), paths.skipped_paths.items.len);
    try std.testing.expectEqualStrings("docs/guide.md", paths.skipped_paths.items[0]);
}

test "parses quoted paths and last seen three-way failures" {
    const allocator = std.testing.allocator;
    var paths = try parseApplyOutputPaths(
        allocator,
        "",
        "Checking patch \"hello\\tworld.txt\"...\nFailed to perform three-way merge...\n",
    );
    defer paths.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), paths.skipped_paths.items.len);
    try std.testing.expectEqualStrings("hello\tworld.txt", paths.skipped_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 0), paths.applied_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), paths.conflicted_paths.items.len);
}

test "parses unmerged and renamed deleted paths" {
    const allocator = std.testing.allocator;
    var paths = try parseApplyOutputPaths(
        allocator,
        "",
        "U src/conflict.zig\nerror: path docs/old.md has been renamed/deleted\n",
    );
    defer paths.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), paths.conflicted_paths.items.len);
    try std.testing.expectEqualStrings("src/conflict.zig", paths.conflicted_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), paths.skipped_paths.items.len);
    try std.testing.expectEqualStrings("docs/old.md", paths.skipped_paths.items[0]);
}
