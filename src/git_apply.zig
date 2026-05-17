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

const GitApplyOptions = struct {
    check_only: bool = false,
    reverse: bool = false,
    cwd: ?[]const u8 = null,
    output_limit_bytes: usize = 10 * 1024 * 1024,
};

const TemporaryGitIndex = struct {
    path: []const u8,
    env_map: std.process.Environ.Map,
    existed: bool,

    fn deinit(self: *TemporaryGitIndex, allocator: std.mem.Allocator) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
        self.env_map.deinit();
    }
};

const DiffGitPathPair = struct {
    first: []u8,
    second: []u8,

    fn deinit(self: *DiffGitPathPair, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.second);
    }
};

const HunkLineCounts = struct {
    old: usize,
    new: usize,
};

pub fn applyUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, .{});
}

pub fn checkUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, .{ .check_only = true });
}

pub fn revertUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, .{ .reverse = true });
}

pub fn checkRevertUnifiedDiff(allocator: std.mem.Allocator, diff: []const u8) !Result {
    return runGitApply(allocator, diff, .{ .check_only = true, .reverse = true });
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
    errdefer allocator.free(owned_path);
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, owned_path)) {
            allocator.free(owned_path);
            return;
        }
    }
    try list.append(allocator, owned_path);
}

fn appendPathCopy(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) !void {
    const owned = try allocator.dupe(u8, path);
    try appendUniqueOwnedPath(allocator, list, owned);
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

fn runGitApply(allocator: std.mem.Allocator, diff: []const u8, options: GitApplyOptions) !Result {
    const git_root = try resolveGitRoot(allocator, options.cwd);
    defer allocator.free(git_root);

    const patch_path = try writeTemporaryPatch(allocator, diff);
    defer {
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), patch_path) catch {};
        allocator.free(patch_path);
    }

    var temporary_index: ?TemporaryGitIndex = null;
    defer if (temporary_index) |*index| index.deinit(allocator);
    var restore_index_on_error = false;
    errdefer if (restore_index_on_error) {
        if (temporary_index) |*index| restoreGitIndex(allocator, git_root, index) catch {};
    };

    var apply_env: ?*const std.process.Environ.Map = null;
    if (options.reverse) {
        if (options.check_only) {
            temporary_index = try prepareTemporaryGitIndex(allocator, git_root);
            if (temporary_index) |*index| {
                try stageExistingDiffPaths(allocator, git_root, diff, &index.env_map);
                apply_env = &index.env_map;
            }
        } else {
            temporary_index = try prepareTemporaryGitIndex(allocator, git_root);
            restore_index_on_error = true;
            try stageExistingDiffPaths(allocator, git_root, diff, null);
        }
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "apply");
    if (options.check_only) try argv.append(allocator, "--check");
    try argv.append(allocator, "--3way");
    if (options.reverse) try argv.append(allocator, "-R");
    try argv.append(allocator, patch_path);

    const process_result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv.items,
        .cwd = .{ .path = git_root },
        .environ_map = apply_env,
        .stdout_limit = .limited(options.output_limit_bytes),
        .stderr_limit = .limited(options.output_limit_bytes),
    });
    errdefer allocator.free(process_result.stdout);
    errdefer allocator.free(process_result.stderr);

    switch (process_result.term) {
        .exited => |code| {
            if (options.reverse and !options.check_only and code != 0) {
                if (temporary_index) |*index| {
                    try restoreGitIndex(allocator, git_root, index);
                }
            }
            restore_index_on_error = false;
            return .{
                .exit_code = code,
                .stdout = process_result.stdout,
                .stderr = process_result.stderr,
            };
        },
        else => return error.GitApplyTerminated,
    }
}

fn prepareTemporaryGitIndex(allocator: std.mem.Allocator, git_root: []const u8) !TemporaryGitIndex {
    const source_index = try resolveGitInternalPath(allocator, git_root, "index");
    defer allocator.free(source_index);

    const temp_index = try temporaryGitIndexPath(allocator, git_root);
    errdefer allocator.free(temp_index);
    errdefer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), temp_index) catch {};

    const io = std.Io.Threaded.global_single_threaded.io();
    const existed = copy_index: {
        std.Io.Dir.copyFileAbsolute(source_index, temp_index, io, .{}) catch |err| switch (err) {
            error.FileNotFound => break :copy_index false,
            else => return err,
        };
        break :copy_index true;
    };

    var env_map = try environmentWithGitIndex(allocator, temp_index);
    errdefer env_map.deinit();

    return .{
        .path = temp_index,
        .env_map = env_map,
        .existed = existed,
    };
}

fn restoreGitIndex(allocator: std.mem.Allocator, git_root: []const u8, snapshot: *const TemporaryGitIndex) !void {
    const index_path = try resolveGitInternalPath(allocator, git_root, "index");
    defer allocator.free(index_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    if (snapshot.existed) {
        try std.Io.Dir.copyFileAbsolute(snapshot.path, index_path, io, .{});
    } else {
        std.Io.Dir.cwd().deleteFile(io, index_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn stageExistingDiffPaths(
    allocator: std.mem.Allocator,
    git_root: []const u8,
    diff: []const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    var paths = try extractReverseStagePathsFromPatch(allocator, diff);
    defer freePathList(allocator, &paths);

    var existing = std.ArrayList([]const u8).empty;
    defer existing.deinit(allocator);

    const io = std.Io.Threaded.global_single_threaded.io();
    for (paths.items) |path| {
        const full_path = try std.fs.path.join(allocator, &.{ git_root, path });
        defer allocator.free(full_path);
        _ = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false }) catch continue;
        try existing.append(allocator, path);
    }
    if (existing.items.len == 0) return;

    var remove_argv = std.ArrayList([]const u8).empty;
    defer remove_argv.deinit(allocator);
    try remove_argv.append(allocator, "git");
    try remove_argv.append(allocator, "update-index");
    try remove_argv.append(allocator, "--force-remove");
    try remove_argv.append(allocator, "--");
    try remove_argv.appendSlice(allocator, existing.items);
    try runGitStageCommand(allocator, git_root, remove_argv.items, env_map);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "--literal-pathspecs");
    try argv.append(allocator, "add");
    try argv.append(allocator, "-f");
    try argv.append(allocator, "--");
    try argv.appendSlice(allocator, existing.items);
    try runGitStageCommand(allocator, git_root, argv.items, env_map);
}

fn runGitStageCommand(
    allocator: std.mem.Allocator,
    git_root: []const u8,
    argv: []const []const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = .{ .path = git_root },
        .environ_map = env_map,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitStageFailed,
        else => return error.GitStageTerminated,
    }
}

pub fn isUnifiedDiff(diff: []const u8) bool {
    return std.mem.indexOf(u8, diff, "diff --git ") != null or
        (hasDiffHeader(diff, "--- ") and hasDiffHeader(diff, "+++ "));
}

fn hasDiffHeader(diff: []const u8, comptime header: []const u8) bool {
    return std.mem.startsWith(u8, diff, header) or std.mem.indexOf(u8, diff, "\n" ++ header) != null;
}

fn resolveGitRoot(allocator: std.mem.Allocator, cwd: ?[]const u8) ![]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const run_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .cwd = run_cwd,
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

fn resolveGitInternalPath(allocator: std.mem.Allocator, git_root: []const u8, path: []const u8) ![]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{ "git", "rev-parse", "--git-path", path };
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &argv,
        .cwd = .{ .path = git_root },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitRevParseFailed,
        else => return error.GitRevParseTerminated,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyGitPath;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ git_root, trimmed });
}

fn environmentWithGitIndex(allocator: std.mem.Allocator, index_path: []const u8) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    var index: usize = 0;
    while (std.c.environ[index]) |entry_ptr| : (index += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        try result.put(key, entry[eq + 1 ..]);
    }
    try result.put("GIT_INDEX_FILE", index_path);
    return result;
}

fn extractDiffPathsFromPatch(allocator: std.mem.Allocator, diff: []const u8) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8).empty;
    errdefer freePathList(allocator, &paths);

    var expect_old_header = true;
    var expect_new_header = false;
    var in_hunk = false;
    var old_remaining: usize = 0;
    var new_remaining: usize = 0;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            expect_old_header = true;
            expect_new_header = false;
            in_hunk = false;
            old_remaining = 0;
            new_remaining = 0;

            const rest = line["diff --git ".len..];

            var pair = (try parseDiffGitPaths(allocator, rest)) orelse continue;
            defer pair.deinit(allocator);

            try recordNormalizedDiffPath(allocator, &paths, pair.first, "a/");
            try recordNormalizedDiffPath(allocator, &paths, pair.second, "b/");
            continue;
        }
        if (parseHunkLineCounts(line)) |counts| {
            expect_old_header = false;
            expect_new_header = false;
            in_hunk = true;
            old_remaining = counts.old;
            new_remaining = counts.new;
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
            }
            continue;
        }
        if (in_hunk) {
            consumeHunkBodyLine(line, &old_remaining, &new_remaining);
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
                expect_new_header = false;
            }
            continue;
        }
        if (expect_old_header and std.mem.startsWith(u8, line, "--- ")) {
            try recordNormalizedDiffPath(allocator, &paths, unifiedHeaderPath(line["--- ".len..]), "a/");
            expect_old_header = false;
            expect_new_header = true;
            continue;
        }
        if (expect_new_header and std.mem.startsWith(u8, line, "+++ ")) {
            try recordNormalizedDiffPath(allocator, &paths, unifiedHeaderPath(line["+++ ".len..]), "b/");
            expect_new_header = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename from ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["rename from ".len..], "");
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename to ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["rename to ".len..], "");
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy from ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["copy from ".len..], "");
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy to ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["copy to ".len..], "");
            continue;
        }
    }

    return paths;
}

fn extractReverseStagePathsFromPatch(allocator: std.mem.Allocator, diff: []const u8) !std.ArrayList([]const u8) {
    var paths = try extractDiffPathsFromPatch(allocator, diff);
    errdefer freePathList(allocator, &paths);

    var restore_paths = try extractReverseRestorePathsFromPatch(allocator, diff);
    defer freePathList(allocator, &restore_paths);

    var current_paths = try extractReverseCurrentPathsFromPatch(allocator, diff);
    defer freePathList(allocator, &current_paths);

    for (restore_paths.items) |path| {
        if (!containsPath(current_paths.items, path)) removePath(allocator, &paths, path);
    }
    return paths;
}

fn extractReverseCurrentPathsFromPatch(allocator: std.mem.Allocator, diff: []const u8) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8).empty;
    errdefer freePathList(allocator, &paths);

    var expect_old_header = true;
    var expect_new_header = false;
    var in_hunk = false;
    var old_remaining: usize = 0;
    var new_remaining: usize = 0;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            expect_old_header = true;
            expect_new_header = false;
            in_hunk = false;
            old_remaining = 0;
            new_remaining = 0;
            continue;
        }
        if (parseHunkLineCounts(line)) |counts| {
            expect_old_header = false;
            expect_new_header = false;
            in_hunk = true;
            old_remaining = counts.old;
            new_remaining = counts.new;
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
            }
            continue;
        }
        if (in_hunk) {
            consumeHunkBodyLine(line, &old_remaining, &new_remaining);
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
                expect_new_header = false;
            }
            continue;
        }
        if (expect_old_header and std.mem.startsWith(u8, line, "--- ")) {
            expect_old_header = false;
            expect_new_header = true;
            continue;
        }
        if (expect_new_header and std.mem.startsWith(u8, line, "+++ ")) {
            if (!isDiffNullPath(line["+++ ".len..])) {
                try recordNormalizedDiffPath(allocator, &paths, unifiedHeaderPath(line["+++ ".len..]), "b/");
            }
            expect_new_header = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename to ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["rename to ".len..], "");
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy to ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["copy to ".len..], "");
            continue;
        }
    }

    return paths;
}

fn extractReverseRestorePathsFromPatch(allocator: std.mem.Allocator, diff: []const u8) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8).empty;
    errdefer freePathList(allocator, &paths);

    var current_old_path: ?[]u8 = null;
    defer if (current_old_path) |path| allocator.free(path);

    var expect_old_header = true;
    var expect_new_header = false;
    var in_hunk = false;
    var old_remaining: usize = 0;
    var new_remaining: usize = 0;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            expect_old_header = true;
            expect_new_header = false;
            in_hunk = false;
            old_remaining = 0;
            new_remaining = 0;

            if (current_old_path) |path| allocator.free(path);
            current_old_path = null;

            const rest = line["diff --git ".len..];
            var pair = (try parseDiffGitPaths(allocator, rest)) orelse continue;
            defer pair.deinit(allocator);

            current_old_path = try normalizedDiffPathAlloc(allocator, pair.first, "a/");
            if (isDiffNullPath(pair.second)) {
                if (current_old_path) |path| try appendPathCopy(allocator, &paths, path);
            }
            continue;
        }
        if (parseHunkLineCounts(line)) |counts| {
            expect_old_header = false;
            expect_new_header = false;
            in_hunk = true;
            old_remaining = counts.old;
            new_remaining = counts.new;
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
            }
            continue;
        }
        if (in_hunk) {
            consumeHunkBodyLine(line, &old_remaining, &new_remaining);
            if (old_remaining == 0 and new_remaining == 0) {
                in_hunk = false;
                expect_old_header = true;
                expect_new_header = false;
            }
            continue;
        }
        if (expect_old_header and std.mem.startsWith(u8, line, "--- ")) {
            if (current_old_path) |path| allocator.free(path);
            current_old_path = null;
            current_old_path = try normalizedDiffPathAlloc(allocator, unifiedHeaderPath(line["--- ".len..]), "a/");
            expect_old_header = false;
            expect_new_header = true;
            continue;
        }
        if (expect_new_header and std.mem.startsWith(u8, line, "+++ ")) {
            if (isDiffNullPath(line["+++ ".len..])) {
                if (current_old_path) |path| try appendPathCopy(allocator, &paths, path);
            }
            expect_new_header = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "deleted file mode")) {
            if (current_old_path) |path| try appendPathCopy(allocator, &paths, path);
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename from ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["rename from ".len..], "");
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy from ")) {
            try recordNormalizedMetadataPath(allocator, &paths, line["copy from ".len..], "");
            continue;
        }
    }

    return paths;
}

fn containsPath(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, wanted)) return true;
    }
    return false;
}

fn parseDiffGitPaths(allocator: std.mem.Allocator, line: []const u8) !?DiffGitPathPair {
    const trimmed = std.mem.trim(u8, line, "\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "a/")) {
        if (findUnquotedDiffSeparator(trimmed)) |separator| {
            const first = try allocator.dupe(u8, trimmed[0..separator]);
            errdefer allocator.free(first);
            const second = try allocator.dupe(u8, trimmed[separator + 1 ..]);
            return .{ .first = first, .second = second };
        }
        if (hasUnquotedDiffSeparator(trimmed)) return null;
    }

    var index: usize = 0;
    const first = (try readDiffGitToken(allocator, trimmed, &index)) orelse return null;
    errdefer allocator.free(first);
    const second = (try readDiffGitToken(allocator, trimmed, &index)) orelse {
        allocator.free(first);
        return null;
    };
    return .{ .first = first, .second = second };
}

fn findUnquotedDiffSeparator(line: []const u8) ?usize {
    var first_separator: ?usize = null;
    var separator_count: usize = 0;
    var search_index: usize = 1;
    while (std.mem.indexOfPos(u8, line, search_index, " b/")) |separator| {
        if (first_separator == null) first_separator = separator;
        separator_count += 1;
        const first = line["a/".len..separator];
        const second = line[separator + " b/".len ..];
        if (std.mem.eql(u8, first, second)) return separator;
        search_index = separator + 1;
    }
    if (separator_count == 1) return first_separator;
    return null;
}

fn hasUnquotedDiffSeparator(line: []const u8) bool {
    return std.mem.indexOfPos(u8, line, 1, " b/") != null;
}

fn parseHunkLineCounts(line: []const u8) ?HunkLineCounts {
    if (!std.mem.startsWith(u8, line, "@@")) return null;

    var index: usize = 2;
    while (index < line.len and std.ascii.isWhitespace(line[index])) : (index += 1) {}
    if (index >= line.len or line[index] != '-') return null;
    index += 1;
    const old_count = parseHunkRangeCount(line, &index) orelse return null;

    while (index < line.len and std.ascii.isWhitespace(line[index])) : (index += 1) {}
    if (index >= line.len or line[index] != '+') return null;
    index += 1;
    const new_count = parseHunkRangeCount(line, &index) orelse return null;

    return .{ .old = old_count, .new = new_count };
}

fn parseHunkRangeCount(line: []const u8, index: *usize) ?usize {
    _ = parseUnsigned(line, index) orelse return null;
    if (index.* >= line.len or line[index.*] != ',') return 1;
    index.* += 1;
    return parseUnsigned(line, index);
}

fn parseUnsigned(line: []const u8, index: *usize) ?usize {
    const start = index.*;
    while (index.* < line.len and line[index.*] >= '0' and line[index.*] <= '9') : (index.* += 1) {}
    if (index.* == start) return null;
    return std.fmt.parseInt(usize, line[start..index.*], 10) catch null;
}

fn consumeHunkBodyLine(line: []const u8, old_remaining: *usize, new_remaining: *usize) void {
    if (line.len == 0) return;
    switch (line[0]) {
        ' ' => {
            decrementRemaining(old_remaining);
            decrementRemaining(new_remaining);
        },
        '-' => decrementRemaining(old_remaining),
        '+' => decrementRemaining(new_remaining),
        else => {},
    }
}

fn decrementRemaining(remaining: *usize) void {
    if (remaining.* > 0) remaining.* -= 1;
}

fn unifiedHeaderPath(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '\t')) |index| return trimmed[0..index];
    if (spaceSeparatedUnifiedTimestamp(trimmed)) |index| return trimmed[0..index];
    return trimmed;
}

fn isDiffNullPath(value: []const u8) bool {
    const path = std.mem.trim(u8, unifiedHeaderPath(value), " \t\r\n");
    return std.mem.eql(u8, path, "/dev/null");
}

fn spaceSeparatedUnifiedTimestamp(value: []const u8) ?usize {
    var search_end = value.len;
    while (std.mem.lastIndexOfScalar(u8, value[0..search_end], ' ')) |space| {
        const suffix = value[space + 1 ..];
        if (isIsoLikeUnifiedTimestamp(suffix)) return space;
        search_end = space;
    }
    return null;
}

fn isIsoLikeUnifiedTimestamp(value: []const u8) bool {
    return value.len > 10 and
        allAsciiDigits(value[0..4]) and
        value[4] == '-' and
        allAsciiDigits(value[5..7]) and
        value[7] == '-' and
        allAsciiDigits(value[8..10]) and
        std.ascii.isWhitespace(value[10]);
}

fn readDiffGitToken(allocator: std.mem.Allocator, line: []const u8, index: *usize) !?[]u8 {
    while (index.* < line.len and std.ascii.isWhitespace(line[index.*])) : (index.* += 1) {}
    if (index.* >= line.len) return null;

    const quote: ?u8 = switch (line[index.*]) {
        '"', '\'' => blk: {
            const value = line[index.*];
            index.* += 1;
            break :blk value;
        },
        else => null,
    };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    while (index.* < line.len) {
        const ch = line[index.*];
        index.* += 1;
        if (quote) |value| {
            if (ch == value) break;
            if (ch == '\\') {
                try out.append(allocator, '\\');
                if (index.* < line.len) {
                    try out.append(allocator, line[index.*]);
                    index.* += 1;
                }
                continue;
            }
        } else if (std.ascii.isWhitespace(ch)) {
            break;
        }
        try out.append(allocator, ch);
    }

    if (out.items.len == 0 and quote == null) {
        out.deinit(allocator);
        return null;
    }

    const raw = try out.toOwnedSlice(allocator);
    if (quote == null) return raw;
    defer allocator.free(raw);
    return try unescapeCStyle(allocator, raw);
}

fn normalizedDiffPath(raw_path: []const u8, prefix: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_path, "\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "/dev/null")) return null;

    const normalized = if (std.mem.startsWith(u8, trimmed, prefix))
        trimmed[prefix.len..]
    else
        trimmed;
    if (normalized.len == 0) return null;
    return normalized;
}

fn normalizedDiffPathAlloc(allocator: std.mem.Allocator, raw_path: []const u8, prefix: []const u8) !?[]u8 {
    const normalized = normalizedDiffPath(raw_path, prefix) orelse return null;
    return try allocator.dupe(u8, normalized);
}

fn recordNormalizedDiffPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), raw_path: []const u8, prefix: []const u8) !void {
    const owned = (try normalizedDiffPathAlloc(allocator, raw_path, prefix)) orelse return;
    try appendUniqueOwnedPath(allocator, paths, owned);
}

fn normalizedMetadataPathAlloc(allocator: std.mem.Allocator, raw_path: []const u8, prefix: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"' or trimmed[0] == '\'') {
        var index: usize = 0;
        const decoded = (try readDiffGitToken(allocator, trimmed, &index)) orelse return null;
        defer allocator.free(decoded);
        return normalizedDiffPathAlloc(allocator, decoded, prefix);
    }
    return normalizedDiffPathAlloc(allocator, trimmed, prefix);
}

fn recordNormalizedMetadataPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), raw_path: []const u8, prefix: []const u8) !void {
    const owned = (try normalizedMetadataPathAlloc(allocator, raw_path, prefix)) orelse return;
    try appendUniqueOwnedPath(allocator, paths, owned);
}

fn temporaryApplyPath(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const tmpdir = try env.getOwned(allocator, "TMPDIR");
    defer if (tmpdir) |value| allocator.free(value);
    const dir = tmpdir orelse "/tmp";

    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);

    const filename = try std.fmt.allocPrint(allocator, "codex-zig-apply-{d}-{x}{s}", .{ timestamp, random_id, suffix });
    defer allocator.free(filename);

    return std.fs.path.join(allocator, &.{ dir, filename });
}

fn temporaryGitIndexPath(allocator: std.mem.Allocator, git_root: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_id = std.mem.readInt(u64, &random_bytes, .little);

    const filename = try std.fmt.allocPrint(allocator, "codex-zig-apply-{d}-{x}.index", .{ timestamp, random_id });
    defer allocator.free(filename);

    return resolveGitInternalPath(allocator, git_root, filename);
}

fn writeTemporaryPatch(allocator: std.mem.Allocator, diff: []const u8) ![]const u8 {
    const path = try temporaryApplyPath(allocator, ".diff");
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = diff });
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

test "extracts normalized paths from diff git headers" {
    const allocator = std.testing.allocator;
    var paths = try extractDiffPathsFromPatch(
        allocator,
        "diff --git a/file.txt b/file.txt\n" ++
            " diff --git a/context.txt b/context.txt\n" ++
            "diff --git a/hello world.txt b/hello world.txt\n" ++
            "diff --git a/foo b/bar.txt b/foo b/bar.txt\n" ++
            "diff --git \"a/hello\\tworld.txt\" \"b/hello\\tworld.txt\"\n" ++
            "diff --git a/old.txt /dev/null\n" ++
            "diff --git a/dev/null b/dev/null\n" ++
            "--- a/plain.txt\n" ++
            "+++ b/plain.txt\n" ++
            "@@ -1,1 +1,1 @@\n" ++
            "--- hunk-body-old.txt\n" ++
            "+++ hunk-body-new.txt\n" ++
            "--- a/timed.txt 2024-01-01 00:00:00\n" ++
            "+++ b/timed.txt 2024-01-01 00:00:00\n" ++
            "@@ -1,1 +1,1 @@\n" ++
            "-old\n" ++
            "+new\n",
    );
    defer freePathList(allocator, &paths);

    try std.testing.expectEqual(@as(usize, 8), paths.items.len);
    try std.testing.expectEqualStrings("file.txt", paths.items[0]);
    try std.testing.expectEqualStrings("hello world.txt", paths.items[1]);
    try std.testing.expectEqualStrings("foo b/bar.txt", paths.items[2]);
    try std.testing.expectEqualStrings("hello\tworld.txt", paths.items[3]);
    try std.testing.expectEqualStrings("old.txt", paths.items[4]);
    try std.testing.expectEqualStrings("dev/null", paths.items[5]);
    try std.testing.expectEqualStrings("plain.txt", paths.items[6]);
    try std.testing.expectEqualStrings("timed.txt", paths.items[7]);
}

test "reverse stage paths skip forward deletions" {
    const allocator = std.testing.allocator;
    var paths = try extractReverseStagePathsFromPatch(
        allocator,
        "diff --git a/deleted.txt b/deleted.txt\n" ++
            "deleted file mode 100644\n" ++
            "--- a/deleted.txt\n" ++
            "+++ /dev/null\n" ++
            "@@ -1,1 +0,0 @@\n" ++
            "-deleted\n" ++
            "diff --git a/new.txt b/new.txt\n" ++
            "new file mode 100644\n" ++
            "--- /dev/null\n" ++
            "+++ b/new.txt\n" ++
            "@@ -0,0 +1,2 @@\n" ++
            "+new\n" ++
            "+++ unrelated.txt\n",
    );
    defer freePathList(allocator, &paths);

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("new.txt", paths.items[0]);
}

test "reverse stage paths skip rename and copy sources" {
    const allocator = std.testing.allocator;
    var paths = try extractReverseStagePathsFromPatch(
        allocator,
        "diff --git a/old.txt b/new.txt\n" ++
            "similarity index 100%\n" ++
            "rename from old.txt\n" ++
            "rename to new.txt\n" ++
            "diff --git a/template.txt b/copy.txt\n" ++
            "similarity index 100%\n" ++
            "copy from template.txt\n" ++
            "copy to copy.txt\n",
    );
    defer freePathList(allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("new.txt", paths.items[0]);
    try std.testing.expectEqualStrings("copy.txt", paths.items[1]);
}

test "reverse stage paths skip ambiguous diff git prefixes" {
    const allocator = std.testing.allocator;
    var paths = try extractReverseStagePathsFromPatch(
        allocator,
        "diff --git a/foo b/bar b/baz\n" ++
            "similarity index 100%\n" ++
            "rename from foo b/bar\n" ++
            "rename to baz\n" ++
            "diff --git a/src b/template b/copied\n" ++
            "similarity index 100%\n" ++
            "copy from src b/template\n" ++
            "copy to copied\n",
    );
    defer freePathList(allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("baz", paths.items[0]);
    try std.testing.expectEqualStrings("copied", paths.items[1]);
}

test "reverse stage paths keep copy sources with their own content changes" {
    const allocator = std.testing.allocator;
    var paths = try extractReverseStagePathsFromPatch(
        allocator,
        "diff --git a/template.txt b/copy.txt\n" ++
            "similarity index 100%\n" ++
            "copy from template.txt\n" ++
            "copy to copy.txt\n" ++
            "diff --git a/template.txt b/template.txt\n" ++
            "--- a/template.txt\n" ++
            "+++ b/template.txt\n" ++
            "@@ -1,1 +1,1 @@\n" ++
            "-orig\n" ++
            "+changed\n",
    );
    defer freePathList(allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("template.txt", paths.items[0]);
    try std.testing.expectEqualStrings("copy.txt", paths.items[1]);
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

test "reverse git apply stages unquoted spaced paths before restoring content" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "hello world.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "hello world.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "hello world.txt", .data = "ORIG\n" });
    const diff =
        \\diff --git a/hello world.txt b/hello world.txt
        \\--- a/hello world.txt
        \\+++ b/hello world.txt
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const after_revert = try dir.dir.readFileAlloc(io, "hello world.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("orig\n", after_revert);
}

test "reverse git apply stages every file in plain multi-file unified diff" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file1.txt", .data = "orig1\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "file2.txt", .data = "orig2\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file1.txt", "file2.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file1.txt", .data = "NEW1\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "file2.txt", .data = "NEW2\n" });
    const diff =
        \\--- a/file1.txt
        \\+++ b/file1.txt
        \\@@ -1,1 +1,1 @@
        \\-orig1
        \\+NEW1
        \\--- a/file2.txt
        \\+++ b/file2.txt
        \\@@ -1,1 +1,1 @@
        \\-orig2
        \\+NEW2
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const file1 = try dir.dir.readFileAlloc(io, "file1.txt", allocator, .limited(1024));
    defer allocator.free(file1);
    const file2 = try dir.dir.readFileAlloc(io, "file2.txt", allocator, .limited(1024));
    defer allocator.free(file2);
    try std.testing.expectEqualStrings("orig1\n", file1);
    try std.testing.expectEqualStrings("orig2\n", file2);
}

test "reverse git apply stages space-timestamp unified headers" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "ORIG\n" });
    const diff =
        \\--- file.txt 2024-01-01 00:00:00
        \\+++ file.txt 2024-01-01 00:00:00
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const after_revert = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("orig\n", after_revert);
}

test "reverse git apply preflight stages a temporary index only" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "ORIG\n" });
    const diff =
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var staged_before = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_before.deinit(allocator);

    var preflight_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true, .check_only = true });
    defer preflight_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), preflight_result.exit_code);

    var staged_after = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_after.deinit(allocator);
    try std.testing.expectEqualStrings(
        std.mem.trim(u8, staged_before.stdout, " \t\r\n"),
        std.mem.trim(u8, staged_after.stdout, " \t\r\n"),
    );

    const after_preflight = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_preflight);
    try std.testing.expectEqualStrings("ORIG\n", after_preflight);
}

test "reverse git apply stages untracked additions before removing them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "base.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "new\n" });
    const diff =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,1 @@
        \\+new
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(io, "new.txt", .{}));
}

test "reverse git apply force-stages ignored additions before removing them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try expectGitSuccess(allocator, root, &.{ "add", ".gitignore" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignored\n" });
    const diff =
        \\diff --git a/ignored.txt b/ignored.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/ignored.txt
        \\@@ -0,0 +1,1 @@
        \\+ignored
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(io, "ignored.txt", .{}));
}

test "reverse git apply stages literal pathspec metacharacters only" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "base.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "*.txt", .data = "literal\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "other\n" });
    const diff =
        \\diff --git "a/*.txt" "b/*.txt"
        \\new file mode 100644
        \\--- /dev/null
        \\+++ "b/*.txt"
        \\@@ -0,0 +1,1 @@
        \\+literal
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(io, "*.txt", .{}));

    const unrelated = try dir.dir.readFileAlloc(io, "other.txt", allocator, .limited(1024));
    defer allocator.free(unrelated);
    try std.testing.expectEqualStrings("other\n", unrelated);

    var staged_after = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_after.deinit(allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, staged_after.stdout, " \t\r\n"));
}

test "reverse git apply does not stage ambiguous rename prefix" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "foo", .data = "unrelated\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "baz", .data = "renamed\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "foo", "baz" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "foo", .data = "USER\n" });
    const diff =
        \\diff --git a/foo b/bar b/baz
        \\similarity index 100%
        \\rename from foo b/bar
        \\rename to baz
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const unrelated = try dir.dir.readFileAlloc(io, "foo", allocator, .limited(1024));
    defer allocator.free(unrelated);
    try std.testing.expectEqualStrings("USER\n", unrelated);

    var staged_unrelated = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only", "--", "foo" });
    defer staged_unrelated.deinit(allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, staged_unrelated.stdout, " \t\r\n"));
}

test "reverse git apply leaves conflicting deleted-file restore target untouched" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "base.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "USER\n" });
    const diff =
        \\diff --git a/file.txt b/file.txt
        \\deleted file mode 100644
        \\--- a/file.txt
        \\+++ /dev/null
        \\@@ -1,1 +0,0 @@
        \\-orig
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expect(revert_result.exit_code != 0);

    const after_revert = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("USER\n", after_revert);

    var staged_after = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_after.deinit(allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, staged_after.stdout, " \t\r\n"));
}

test "reverse git apply restores index after failed staged revert" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "USER\n" });
    const diff =
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expect(revert_result.exit_code != 0);

    const after_revert = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("USER\n", after_revert);

    var staged_after = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_after.deinit(allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, staged_after.stdout, " \t\r\n"));
}

test "reverse git apply restores index after post-staging process error" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "USER\n" });
    const diff =
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    try std.testing.expectError(
        error.StreamTooLong,
        runGitApply(allocator, diff, .{ .cwd = root, .reverse = true, .output_limit_bytes = 1 }),
    );

    const after_revert = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("USER\n", after_revert);

    var staged_after = try runGitForApplyTest(allocator, root, &.{ "diff", "--cached", "--name-only" });
    defer staged_after.deinit(allocator);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, staged_after.stdout, " \t\r\n"));
}

test "reverse git apply stages unified headers without diff git header" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "file.txt" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "ORIG\n" });
    const diff =
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const after_revert = try dir.dir.readFileAlloc(io, "file.txt", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("orig\n", after_revert);
}

test "reverse git apply stages real dev null path" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try expectGitSuccess(allocator, root, &.{ "init", "--quiet" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try expectGitSuccess(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.createDir(io, "dev", .default_dir);
    try dir.dir.writeFile(io, .{ .sub_path = "dev/null", .data = "orig\n" });
    try expectGitSuccess(allocator, root, &.{ "add", "dev/null" });
    try expectGitSuccess(allocator, root, &.{ "commit", "--quiet", "-m", "seed" });

    try dir.dir.writeFile(io, .{ .sub_path = "dev/null", .data = "ORIG\n" });
    const diff =
        \\diff --git a/dev/null b/dev/null
        \\--- a/dev/null
        \\+++ b/dev/null
        \\@@ -1,1 +1,1 @@
        \\-orig
        \\+ORIG
        \\
    ;

    var revert_result = try runGitApply(allocator, diff, .{ .cwd = root, .reverse = true });
    defer revert_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), revert_result.exit_code);

    const after_revert = try dir.dir.readFileAlloc(io, "dev/null", allocator, .limited(1024));
    defer allocator.free(after_revert);
    try std.testing.expectEqualStrings("orig\n", after_revert);
}

fn expectGitSuccess(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var result = try runGitForApplyTest(allocator, cwd, args);
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.GitCommandFailed;
}

fn runGitForApplyTest(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !Result {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    @memcpy(argv[1..], args);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const process_result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    errdefer allocator.free(process_result.stdout);
    errdefer allocator.free(process_result.stderr);

    return switch (process_result.term) {
        .exited => |code| .{
            .exit_code = code,
            .stdout = process_result.stdout,
            .stderr = process_result.stderr,
        },
        else => error.GitCommandTerminated,
    };
}
