const std = @import("std");

pub const GitBranchDiffStats = struct {
    additions: u64,
    deletions: u64,
};

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
};

const DefaultBranch = struct {
    merge_ref: []const u8,

    fn deinit(self: *DefaultBranch, allocator: std.mem.Allocator) void {
        allocator.free(self.merge_ref);
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

pub fn currentBranchName(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var output = runGitCommand(allocator, cwd, &.{ "branch", "--show-current" }) catch return null;
    defer output.deinit(allocator);
    if (!output.success()) return null;

    const branch = std.mem.trim(u8, output.stdout, " \t\r\n");
    if (branch.len == 0) return null;
    return @as(?[]const u8, try allocator.dupe(u8, branch));
}

pub fn branchChangesLabel(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    const stats = (try branchDiffStatsToDefaultBranch(allocator, cwd)) orelse return null;
    if (stats.additions == 0 and stats.deletions == 0) {
        return @as(?[]const u8, try allocator.dupe(u8, "No changes"));
    }
    return @as(?[]const u8, try std.fmt.allocPrint(allocator, "+{d} -{d}", .{ stats.additions, stats.deletions }));
}

pub fn branchDiffStatsToDefaultBranch(allocator: std.mem.Allocator, cwd: []const u8) !?GitBranchDiffStats {
    var git_dir = runGitCommand(allocator, cwd, &.{ "rev-parse", "--git-dir" }) catch return null;
    defer git_dir.deinit(allocator);
    if (!git_dir.success()) return null;

    var default_branch = (try getDefaultBranch(allocator, cwd)) orelse return null;
    defer default_branch.deinit(allocator);

    var merge_base = runGitCommand(allocator, cwd, &.{ "merge-base", "HEAD", default_branch.merge_ref }) catch return null;
    defer merge_base.deinit(allocator);
    if (!merge_base.success()) return null;

    const base = std.mem.trim(u8, merge_base.stdout, " \t\r\n");
    if (base.len == 0) return null;

    const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{base});
    defer allocator.free(range);
    var numstat = runGitCommand(allocator, cwd, &.{ "diff", "--numstat", range }) catch return null;
    defer numstat.deinit(allocator);
    if (!numstat.success()) return null;

    return parseNumstat(numstat.stdout);
}

fn getDefaultBranch(allocator: std.mem.Allocator, cwd: []const u8) !?DefaultBranch {
    if (try getGitRemotes(allocator, cwd)) |remotes_value| {
        var remotes = remotes_value;
        defer remotes.deinit(allocator);
        for (remotes.items) |remote| {
            if (try remoteDefaultBranchFromSymbolicRef(allocator, cwd, remote)) |branch| {
                return branch;
            }
            if (try remoteDefaultBranchFromRemoteShow(allocator, cwd, remote)) |branch| {
                return branch;
            }
        }
    }

    return localDefaultBranch(allocator, cwd);
}

fn getGitRemotes(allocator: std.mem.Allocator, cwd: []const u8) !?StringList {
    var output = runGitCommand(allocator, cwd, &.{"remote"}) catch return null;
    defer output.deinit(allocator);
    if (!output.success()) return null;

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output.stdout, '\n');
    while (lines.next()) |line| {
        const remote = std.mem.trim(u8, line, " \t\r\n");
        if (remote.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, remote));
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

fn remoteDefaultBranchFromSymbolicRef(allocator: std.mem.Allocator, cwd: []const u8, remote: []const u8) !?DefaultBranch {
    const remote_head = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/HEAD", .{remote});
    defer allocator.free(remote_head);

    var output = runGitCommand(allocator, cwd, &.{ "symbolic-ref", "--quiet", remote_head }) catch return null;
    defer output.deinit(allocator);
    if (!output.success()) return null;

    const ref = std.mem.trim(u8, output.stdout, " \t\r\n");
    const remote_ref_prefix = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/", .{remote});
    defer allocator.free(remote_ref_prefix);
    if (!std.mem.startsWith(u8, ref, remote_ref_prefix)) return null;
    if (!try gitRefExists(allocator, cwd, ref)) return null;

    return .{ .merge_ref = try allocator.dupe(u8, ref) };
}

fn remoteDefaultBranchFromRemoteShow(allocator: std.mem.Allocator, cwd: []const u8, remote: []const u8) !?DefaultBranch {
    var output = runGitCommand(allocator, cwd, &.{ "remote", "show", remote }) catch return null;
    defer output.deinit(allocator);
    if (!output.success()) return null;

    var lines = std.mem.splitScalar(u8, output.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const prefix = "HEAD branch:";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const branch_name = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
        if (branch_name.len == 0) continue;

        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote, branch_name });
        errdefer allocator.free(remote_ref);
        if (try gitRefExists(allocator, cwd, remote_ref)) {
            return .{ .merge_ref = remote_ref };
        }
        allocator.free(remote_ref);
    }

    return null;
}

fn localDefaultBranch(allocator: std.mem.Allocator, cwd: []const u8) !?DefaultBranch {
    for ([_][]const u8{ "main", "master" }) |candidate| {
        const local_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{candidate});
        errdefer allocator.free(local_ref);
        if (try gitRefExists(allocator, cwd, local_ref)) {
            return .{ .merge_ref = local_ref };
        }
        allocator.free(local_ref);
    }
    return null;
}

fn gitRefExists(allocator: std.mem.Allocator, cwd: []const u8, reference: []const u8) !bool {
    var output = runGitCommand(allocator, cwd, &.{ "rev-parse", "--verify", "--quiet", reference }) catch return false;
    defer output.deinit(allocator);
    return output.success();
}

fn parseNumstat(stdout: []const u8) GitBranchDiffStats {
    var stats = GitBranchDiffStats{ .additions = 0, .deletions = 0 };
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.splitScalar(u8, line, '\t');
        stats.additions += parseNumstatColumn(columns.next() orelse "");
        stats.deletions += parseNumstatColumn(columns.next() orelse "");
    }
    return stats;
}

fn parseNumstatColumn(raw: []const u8) u64 {
    return std.fmt.parseUnsigned(u64, raw, 10) catch 0;
}

fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !CommandOutput {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "git";
    @memcpy(argv[1..], args);

    var child_env = try gitCommandEnvironment(allocator);
    defer child_env.deinit();

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &child_env,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(1000),
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

fn gitCommandEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var child_env = std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

    var index: usize = 0;
    while (std.c.environ[index]) |entry_ptr| : (index += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        try child_env.put(key, entry[eq + 1 ..]);
    }
    try child_env.put("GIT_OPTIONAL_LOCKS", "0");
    return child_env;
}

test "parses git numstat output" {
    const stats = parseNumstat("12\t3\tfile.txt\n-\t-\tbinary.bin\n4\t0\tother.txt\n");
    try std.testing.expectEqual(@as(u64, 16), stats.additions);
    try std.testing.expectEqual(@as(u64, 3), stats.deletions);
}

test "renders branch change labels from committed default-branch diff" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try runGitForTest(allocator, root, &.{ "init", "--quiet" });
    try runGitForTest(allocator, root, &.{ "config", "user.email", "test@example.com" });
    try runGitForTest(allocator, root, &.{ "config", "user.name", "Test User" });
    try dir.dir.writeFile(io, .{ .sub_path = "README.md", .data = "one\ntwo\nthree\n" });
    try runGitForTest(allocator, root, &.{ "add", "README.md" });
    try runGitForTest(allocator, root, &.{ "commit", "--quiet", "-m", "initial" });
    try runGitForTest(allocator, root, &.{ "branch", "-M", "main" });

    const clean_label = (try branchChangesLabel(allocator, root)).?;
    defer allocator.free(clean_label);
    try std.testing.expectEqualStrings("No changes", clean_label);

    try runGitForTest(allocator, root, &.{ "checkout", "--quiet", "-b", "feature" });
    try dir.dir.writeFile(io, .{ .sub_path = "README.md", .data = "one\nthree\nfour\nfive\n" });
    try runGitForTest(allocator, root, &.{ "add", "README.md" });
    try runGitForTest(allocator, root, &.{ "commit", "--quiet", "-m", "feature changes" });

    const changes_label = (try branchChangesLabel(allocator, root)).?;
    defer allocator.free(changes_label);
    try std.testing.expectEqualStrings("+2 -1", changes_label);
}

fn runGitForTest(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var output = try runGitCommand(allocator, cwd, args);
    defer output.deinit(allocator);
    switch (output.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandTerminated,
    }
}
