const std = @import("std");

const MATCH_LIMIT = 50;
const MAX_SCANNED_ENTRIES = 20_000;

pub const MatchType = enum {
    file,
    directory,

    pub fn jsonLabel(self: MatchType) []const u8 {
        return switch (self) {
            .file => "file",
            .directory => "directory",
        };
    }
};

pub const Match = struct {
    root: []const u8,
    path: []const u8,
    match_type: MatchType,
    file_name: []const u8,
    score: u32,
    indices: []const u32,

    fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.file_name);
        allocator.free(self.indices);
    }
};

pub const Results = struct {
    files: []Match,

    pub fn deinit(self: *Results, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

const ScanState = struct {
    scanned_entries: usize = 0,
};

const FuzzyMatch = struct {
    score: u32,
    indices: []const u32,
};

pub fn search(allocator: std.mem.Allocator, query: []const u8, roots: []const []const u8) !Results {
    var matches = std.ArrayList(Match).empty;
    errdefer {
        for (matches.items) |*file| file.deinit(allocator);
        matches.deinit(allocator);
    }

    if (query.len == 0 or roots.len == 0) {
        return .{ .files = try matches.toOwnedSlice(allocator) };
    }

    var state = ScanState{};
    for (roots) |root| {
        if (state.scanned_entries >= MAX_SCANNED_ENTRIES) break;
        try scanRoot(allocator, root, query, &matches, &state);
    }

    std.mem.sort(Match, matches.items, {}, matchLessThan);

    if (matches.items.len > MATCH_LIMIT) {
        for (matches.items[MATCH_LIMIT..]) |*file| file.deinit(allocator);
        matches.shrinkRetainingCapacity(MATCH_LIMIT);
    }

    return .{ .files = try matches.toOwnedSlice(allocator) };
}

fn scanRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    query: []const u8,
    matches: *std.ArrayList(Match),
    state: *ScanState,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = openIterableDir(io, root) catch return;
    defer dir.close(io);
    try scanDir(allocator, io, root, "", &dir, query, matches, state);
}

fn scanDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_dir: []const u8,
    dir: *std.Io.Dir,
    query: []const u8,
    matches: *std.ArrayList(Match),
    state: *ScanState,
) !void {
    var iter = dir.iterate();
    while (state.scanned_entries < MAX_SCANNED_ENTRIES) {
        const entry = iter.next(io) catch break;
        const child = entry orelse break;
        if (shouldSkipName(child.name)) continue;

        state.scanned_entries += 1;
        const relative_path = try relativeChildPath(allocator, relative_dir, child.name);
        var owns_relative_path = true;
        errdefer if (owns_relative_path) allocator.free(relative_path);

        const full_path = try std.fs.path.join(allocator, &.{ root, relative_path });
        defer allocator.free(full_path);
        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch {
            allocator.free(relative_path);
            owns_relative_path = false;
            continue;
        };

        const match_type: ?MatchType = switch (stat.kind) {
            .file => .file,
            .directory => .directory,
            else => null,
        };
        if (match_type) |kind| {
            if (try fuzzyMatchPath(allocator, relative_path, query)) |fuzzy| {
                defer allocator.free(fuzzy.indices);
                const file_name = std.fs.path.basename(relative_path);
                const owned_file_name = try allocator.dupe(u8, file_name);
                errdefer allocator.free(owned_file_name);
                const owned_indices = try allocator.dupe(u32, fuzzy.indices);
                errdefer allocator.free(owned_indices);
                try matches.append(allocator, .{
                    .root = root,
                    .path = relative_path,
                    .match_type = kind,
                    .file_name = owned_file_name,
                    .score = fuzzy.score,
                    .indices = owned_indices,
                });
                owns_relative_path = false;
            } else {
                allocator.free(relative_path);
                owns_relative_path = false;
            }
        } else {
            allocator.free(relative_path);
            owns_relative_path = false;
        }

        if (stat.kind == .directory) {
            var child_dir = openIterableDir(io, full_path) catch continue;
            defer child_dir.close(io);
            try scanDir(allocator, io, root, relative_path, &child_dir, query, matches, state);
        }
    }
}

fn openIterableDir(io: std.Io, path: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn relativeChildPath(allocator: std.mem.Allocator, relative_dir: []const u8, name: []const u8) ![]const u8 {
    if (relative_dir.len == 0) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ relative_dir, name });
}

fn shouldSkipName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out");
}

fn fuzzyMatchPath(allocator: std.mem.Allocator, path: []const u8, query: []const u8) !?FuzzyMatch {
    var indices = std.ArrayList(u32).empty;
    errdefer indices.deinit(allocator);

    var search_from: usize = 0;
    for (query) |query_byte| {
        const query_lower = std.ascii.toLower(query_byte);
        var found_index: ?usize = null;
        var index = search_from;
        while (index < path.len) : (index += 1) {
            if (std.ascii.toLower(path[index]) == query_lower) {
                found_index = index;
                break;
            }
        }
        const matched = found_index orelse return null;
        try indices.append(allocator, @intCast(matched));
        search_from = matched + 1;
    }

    return .{
        .score = scoreMatch(path, query, indices.items),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

fn scoreMatch(path: []const u8, query: []const u8, indices: []const u32) u32 {
    var score: u32 = @intCast(query.len * 12);
    const basename = std.fs.path.basename(path);
    if (startsWithIgnoreCase(basename, query)) score += 40;
    if (containsIgnoreCase(path, query)) score += 20;
    if (indices.len > 0) {
        const leading_gap = if (indices[0] > 16) 16 else indices[0];
        score += 16 - leading_gap;
    }

    var contiguous_bonus: u32 = 0;
    for (indices[1..], 1..) |value, index| {
        if (value == indices[index - 1] + 1) contiguous_bonus += 8;
    }
    score += contiguous_bonus;

    const gap_penalty: u32 = if (indices.len == 0) 0 else penalty: {
        const last_index: usize = @intCast(indices[indices.len - 1]);
        const spread = last_index + 1 - indices.len;
        const capped = @min(path.len, spread);
        break :penalty @intCast(@min(capped, std.math.maxInt(u32)));
    };
    return if (score > gap_penalty) score - gap_penalty else 1;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn matchLessThan(_: void, left: Match, right: Match) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.lessThan(u8, left.path, right.path);
}

test "fuzzy match finds subsequence indices in relative path" {
    const allocator = std.testing.allocator;
    const matched = (try fuzzyMatchPath(allocator, "sub/abce", "abe")).?;
    defer allocator.free(matched.indices);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 7 }, matched.indices);
}
