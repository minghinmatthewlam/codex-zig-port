const std = @import("std");

const CommandOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn success(self: CommandOutput) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn diffSuccess(self: CommandOutput) bool {
        return switch (self.term) {
            .exited => |code| code == 0 or code == 1,
            else => false,
        };
    }
};

pub const Result = struct {
    sha: []const u8,
    diff: []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.sha);
        allocator.free(self.diff);
    }
};

const StringList = struct {
    items: []const []const u8,

    fn deinit(self: *StringList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.items = &.{};
    }
};

const RemoteBranch = struct {
    sha: ?[]const u8,
    ref_name: []const u8,

    fn deinit(self: *RemoteBranch, allocator: std.mem.Allocator) void {
        if (self.sha) |sha| allocator.free(sha);
        allocator.free(self.ref_name);
    }
};

const BranchCandidate = struct {
    sha: ?[]const u8,
    distance: usize,

    fn deinit(self: *BranchCandidate, allocator: std.mem.Allocator) void {
        if (self.sha) |sha| allocator.free(sha);
    }
};

pub fn compute(allocator: std.mem.Allocator, cwd: []const u8) !Result {
    var root = try runGit(allocator, cwd, &.{ "rev-parse", "--show-toplevel" });
    defer root.deinit(allocator);
    if (!root.success()) return error.GitRemoteDiffUnavailable;

    var remotes = try getGitRemotes(allocator, cwd);
    defer remotes.deinit(allocator);
    if (remotes.items.len == 0) return error.GitRemoteDiffUnavailable;

    var branches = try branchAncestry(allocator, cwd, remotes.items);
    defer branches.deinit(allocator);

    const base_sha = try findClosestSha(allocator, cwd, branches.items, remotes.items) orelse
        return error.GitRemoteDiffUnavailable;
    errdefer allocator.free(base_sha);

    const diff = try diffAgainstSha(allocator, cwd, base_sha);
    errdefer allocator.free(diff);

    return .{ .sha = base_sha, .diff = diff };
}

fn getGitRemotes(allocator: std.mem.Allocator, cwd: []const u8) !StringList {
    var output = try runGit(allocator, cwd, &.{"remote"});
    defer output.deinit(allocator);
    if (!output.success()) return error.GitRemoteDiffUnavailable;

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }

    for (list.items, 0..) |remote, index| {
        if (std.mem.eql(u8, remote, "origin")) {
            const origin = list.items[index];
            std.mem.copyForwards([]const u8, list.items[1 .. index + 1], list.items[0..index]);
            list.items[0] = origin;
            break;
        }
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

fn branchAncestry(allocator: std.mem.Allocator, cwd: []const u8, remotes: []const []const u8) !StringList {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    if (try currentBranch(allocator, cwd)) |branch| {
        defer allocator.free(branch);
        try appendUnique(allocator, &list, branch);
    }

    if (try defaultBranch(allocator, cwd, remotes)) |branch| {
        defer allocator.free(branch);
        try appendUnique(allocator, &list, branch);
    }

    for (remotes) |remote| {
        const ref_root = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{remote});
        defer allocator.free(ref_root);
        var output = try runGit(allocator, cwd, &.{ "for-each-ref", "--format=%(refname:short)", "--contains=HEAD", ref_root });
        defer output.deinit(allocator);
        if (!output.success()) continue;

        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{remote});
        defer allocator.free(prefix);
        var lines = std.mem.splitScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            const short = std.mem.trim(u8, line, " \t\r\n");
            if (!std.mem.startsWith(u8, short, prefix)) continue;
            const branch = short[prefix.len..];
            if (branch.len == 0) continue;
            try appendUnique(allocator, &list, branch);
        }
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

fn currentBranch(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var output = try runGit(allocator, cwd, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer output.deinit(allocator);
    if (!output.success()) return null;

    const branch = std.mem.trim(u8, output.stdout, " \t\r\n");
    if (branch.len == 0 or std.mem.eql(u8, branch, "HEAD")) return null;
    return try allocator.dupe(u8, branch);
}

fn defaultBranch(allocator: std.mem.Allocator, cwd: []const u8, remotes: []const []const u8) !?[]const u8 {
    for (remotes) |remote| {
        const remote_head = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/HEAD", .{remote});
        defer allocator.free(remote_head);
        var output = try runGit(allocator, cwd, &.{ "symbolic-ref", "--quiet", remote_head });
        defer output.deinit(allocator);
        if (output.success()) {
            const ref = std.mem.trim(u8, output.stdout, " \t\r\n");
            if (std.mem.lastIndexOfScalar(u8, ref, '/')) |index| {
                const name = ref[index + 1 ..];
                if (name.len > 0) return try allocator.dupe(u8, name);
            }
        }

        var show = try runGit(allocator, cwd, &.{ "remote", "show", remote });
        defer show.deinit(allocator);
        if (!show.success()) continue;
        var lines = std.mem.splitScalar(u8, show.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            const prefix = "HEAD branch:";
            if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
            const name = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
            if (name.len > 0) return try allocator.dupe(u8, name);
        }
    }

    for ([_][]const u8{ "main", "master" }) |candidate| {
        const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{candidate});
        defer allocator.free(ref);
        var output = try runGit(allocator, cwd, &.{ "rev-parse", "--verify", "--quiet", ref });
        defer output.deinit(allocator);
        if (output.success()) return try allocator.dupe(u8, candidate);
    }

    return null;
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, value)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn findClosestSha(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    branches: []const []const u8,
    remotes: []const []const u8,
) !?[]const u8 {
    var best_sha: ?[]const u8 = null;
    errdefer if (best_sha) |sha| allocator.free(sha);
    var best_distance: usize = 0;

    for (branches) |branch| {
        var candidate = (try branchCandidate(allocator, cwd, branch, remotes)) orelse continue;
        defer candidate.deinit(allocator);
        if (best_sha == null or candidate.distance < best_distance) {
            if (best_sha) |sha| allocator.free(sha);
            best_sha = candidate.sha.?;
            candidate.sha = null;
            best_distance = candidate.distance;
        }
    }

    return best_sha;
}

fn branchCandidate(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    branch: []const u8,
    remotes: []const []const u8,
) !?BranchCandidate {
    var remote_branch = (try firstRemoteBranch(allocator, cwd, branch, remotes)) orelse return null;
    defer remote_branch.deinit(allocator);

    const distance = (try branchDistance(allocator, cwd, branch, remote_branch.ref_name)) orelse return null;
    const sha = remote_branch.sha.?;
    remote_branch.sha = null;
    return .{ .sha = sha, .distance = distance };
}

fn firstRemoteBranch(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    branch: []const u8,
    remotes: []const []const u8,
) !?RemoteBranch {
    for (remotes) |remote| {
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote, branch });
        errdefer allocator.free(remote_ref);
        var output = try runGit(allocator, cwd, &.{ "rev-parse", "--verify", "--quiet", remote_ref });
        defer output.deinit(allocator);
        if (!output.success()) {
            allocator.free(remote_ref);
            continue;
        }

        const trimmed = std.mem.trim(u8, output.stdout, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(remote_ref);
            continue;
        }
        const sha = try allocator.dupe(u8, trimmed);
        return .{ .sha = sha, .ref_name = remote_ref };
    }
    return null;
}

fn branchDistance(allocator: std.mem.Allocator, cwd: []const u8, branch: []const u8, remote_ref: []const u8) !?usize {
    const local_range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{branch});
    defer allocator.free(local_range);
    var local = try runGit(allocator, cwd, &.{ "rev-list", "--count", local_range });
    defer local.deinit(allocator);
    if (local.success()) return parseCount(local.stdout);

    const remote_range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{remote_ref});
    defer allocator.free(remote_range);
    var remote = try runGit(allocator, cwd, &.{ "rev-list", "--count", remote_range });
    defer remote.deinit(allocator);
    if (!remote.success()) return null;
    return parseCount(remote.stdout);
}

fn parseCount(stdout: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

fn diffAgainstSha(allocator: std.mem.Allocator, cwd: []const u8, sha: []const u8) ![]const u8 {
    var base = try runGit(allocator, cwd, &.{ "diff", "--no-textconv", "--no-ext-diff", sha });
    defer base.deinit(allocator);
    if (!base.diffSuccess()) return error.GitRemoteDiffUnavailable;

    var diff = std.ArrayList(u8).empty;
    errdefer diff.deinit(allocator);
    try diff.appendSlice(allocator, base.stdout);

    var untracked = try runGit(allocator, cwd, &.{ "ls-files", "--others", "--exclude-standard" });
    defer untracked.deinit(allocator);
    if (!untracked.success()) return diff.toOwnedSlice(allocator);

    var lines = std.mem.splitScalar(u8, untracked.stdout, '\n');
    while (lines.next()) |line| {
        const file = std.mem.trim(u8, line, " \t\r\n");
        if (file.len == 0) continue;
        var extra = try runGit(allocator, cwd, &.{ "diff", "--no-textconv", "--no-ext-diff", "--binary", "--no-index", "--", "/dev/null", file });
        defer extra.deinit(allocator);
        if (extra.diffSuccess()) try diff.appendSlice(allocator, extra.stdout);
    }

    return diff.toOwnedSlice(allocator);
}

fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !CommandOutput {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    @memcpy(argv[1..], args);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(128 * 1024),
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

test "parse git count trims whitespace" {
    try std.testing.expectEqual(@as(?usize, 12), parseCount(" 12\n"));
    try std.testing.expectEqual(@as(?usize, null), parseCount(""));
}
