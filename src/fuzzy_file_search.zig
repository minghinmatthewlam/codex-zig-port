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

const CharClass = enum {
    whitespace,
    non_word,
    delimiter,
    lower,
    upper,
    number,
};

const FuzzyMatch = struct {
    score: u32,
    indices: []const u32,
};

const ScoreState = struct {
    score: u32 = 0,
    run_bonus: u32 = 0,
    valid: bool = false,
};

const ParentIndexNone = std.math.maxInt(usize);

const ScoreMatch = 16;
const PenaltyGapStart = 3;
const PenaltyGapExtension = 1;
const BonusBoundary = ScoreMatch / 2;
const BonusCamel123 = BonusBoundary - PenaltyGapStart;
const BonusNonWord = BonusBoundary;
const BonusConsecutive = PenaltyGapStart + PenaltyGapExtension;
const BonusFirstCharMultiplier = 2;
const BonusBoundaryWhite = BonusBoundary;
const BonusBoundaryDelimiter = BonusBoundary + 1;

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
        const should_recurse = stat.kind == .directory;
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
            } else if (!should_recurse) {
                allocator.free(relative_path);
                owns_relative_path = false;
            }
        } else {
            allocator.free(relative_path);
            owns_relative_path = false;
        }

        if (should_recurse) {
            var child_dir = openIterableDir(io, full_path) catch {
                if (owns_relative_path) {
                    allocator.free(relative_path);
                    owns_relative_path = false;
                }
                continue;
            };
            defer child_dir.close(io);
            try scanDir(allocator, io, root, relative_path, &child_dir, query, matches, state);
            if (owns_relative_path) {
                allocator.free(relative_path);
                owns_relative_path = false;
            }
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
    if (query.len == 0) {
        return .{
            .score = 0,
            .indices = try allocator.alloc(u32, 0),
        };
    }
    if (query.len > path.len) return null;

    const path_len = path.len;
    const bonuses = try allocator.alloc(u32, path_len);
    defer allocator.free(bonuses);
    fillPathBonuses(path, bonuses);

    var parents = try allocator.alloc(usize, query.len * path_len);
    defer allocator.free(parents);
    @memset(parents, ParentIndexNone);

    var previous = try allocator.alloc(ScoreState, path_len);
    defer allocator.free(previous);
    @memset(previous, .{});

    var current = try allocator.alloc(ScoreState, path_len);
    defer allocator.free(current);

    for (query, 0..) |query_byte, query_index| {
        @memset(current, .{});
        var best_gap_value: ?u32 = null;
        var best_gap_index: usize = ParentIndexNone;
        const query_lower = std.ascii.toLower(query_byte);

        for (path, 0..) |path_byte, path_index| {
            if (query_index > 0 and path_index >= 2 and previous[path_index - 2].valid) {
                const candidate_gap_value = previous[path_index - 2].score + @as(u32, @intCast(path_index - 2));
                if (best_gap_value == null or candidate_gap_value > best_gap_value.?) {
                    best_gap_value = candidate_gap_value;
                    best_gap_index = path_index - 2;
                }
            }

            if (std.ascii.toLower(path_byte) != query_lower) continue;

            const row_offset = query_index * path_len + path_index;
            const base_score = ScoreMatch + bonuses[path_index];

            if (query_index == 0) {
                current[path_index] = .{
                    .score = ScoreMatch + bonuses[path_index] * BonusFirstCharMultiplier,
                    .run_bonus = bonuses[path_index],
                    .valid = true,
                };
                continue;
            }

            var best: ScoreState = .{};
            var parent: usize = ParentIndexNone;

            if (path_index > 0 and previous[path_index - 1].valid) {
                var consecutive_bonus = @max(previous[path_index - 1].run_bonus, BonusConsecutive);
                if (bonuses[path_index] >= BonusBoundary and bonuses[path_index] > consecutive_bonus) {
                    consecutive_bonus = bonuses[path_index];
                }
                best = .{
                    .score = previous[path_index - 1].score + ScoreMatch + @max(consecutive_bonus, bonuses[path_index]),
                    .run_bonus = consecutive_bonus,
                    .valid = true,
                };
                parent = path_index - 1;
            }

            if (best_gap_value) |gap_value| {
                const gap_penalty_offset = @as(u32, @intCast(path_index + 1));
                const gap_adjustment = if (gap_value > gap_penalty_offset) gap_value - gap_penalty_offset else 0;
                const gap_score = gap_adjustment + base_score;
                if (!best.valid or gap_score > best.score) {
                    best = .{
                        .score = gap_score,
                        .run_bonus = bonuses[path_index],
                        .valid = true,
                    };
                    parent = best_gap_index;
                }
            }

            if (best.valid) {
                current[path_index] = best;
                parents[row_offset] = parent;
            }
        }

        const temp = previous;
        previous = current;
        current = temp;
    }

    var best_index: usize = ParentIndexNone;
    var best_score: u32 = 0;
    for (previous, 0..) |state, index| {
        if (state.valid and (best_index == ParentIndexNone or state.score > best_score)) {
            best_index = index;
            best_score = state.score;
        }
    }

    if (best_index == ParentIndexNone) return null;

    var indices = try allocator.alloc(u32, query.len);
    errdefer allocator.free(indices);
    var query_index = query.len;
    var path_index = best_index;
    while (query_index > 0) {
        query_index -= 1;
        indices[query_index] = @intCast(path_index);
        const parent = parents[query_index * path_len + path_index];
        if (query_index == 0) break;
        path_index = parent;
    }

    return .{
        .score = best_score,
        .indices = indices,
    };
}

fn fillPathBonuses(path: []const u8, bonuses: []u32) void {
    var previous_class = CharClass.delimiter;
    for (path, 0..) |byte, index| {
        const class = charClass(byte);
        bonuses[index] = bonusFor(previous_class, class);
        previous_class = class;
    }
}

fn bonusFor(previous_class: CharClass, class: CharClass) u32 {
    switch (class) {
        .lower, .upper, .number => switch (previous_class) {
            .whitespace => return BonusBoundaryWhite,
            .delimiter => return BonusBoundaryDelimiter,
            .non_word => return BonusBoundary,
            else => {},
        },
        else => {},
    }

    if ((previous_class == .lower and class == .upper) or
        (previous_class != .number and class == .number))
    {
        return BonusCamel123;
    }

    return switch (class) {
        .whitespace => BonusBoundaryWhite,
        .non_word => BonusNonWord,
        else => 0,
    };
}

fn charClass(byte: u8) CharClass {
    if (byte >= 'a' and byte <= 'z') return .lower;
    if (byte >= 'A' and byte <= 'Z') return .upper;
    if (byte >= '0' and byte <= '9') return .number;
    if (std.ascii.isWhitespace(byte)) return .whitespace;
    if (byte == '/') return .delimiter;
    return .non_word;
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

test "fuzzy match uses Rust path scoring constants" {
    const allocator = std.testing.allocator;

    const prefix = (try fuzzyMatchPath(allocator, "abexy", "abe")).?;
    defer allocator.free(prefix.indices);
    try std.testing.expectEqual(@as(u32, 84), prefix.score);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, prefix.indices);

    const nested = (try fuzzyMatchPath(allocator, "sub/abce", "abe")).?;
    defer allocator.free(nested.indices);
    try std.testing.expectEqual(@as(u32, 72), nested.score);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 7 }, nested.indices);

    const spread = (try fuzzyMatchPath(allocator, "abcde", "abe")).?;
    defer allocator.free(spread.indices);
    try std.testing.expectEqual(@as(u32, 71), spread.score);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4 }, spread.indices);
}
