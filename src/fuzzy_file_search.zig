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

const IgnoreRule = struct {
    base_dir: []const u8,
    pattern: []const u8,
    negated: bool,
    directory_only: bool,
    anchored: bool,
    has_slash: bool,

    fn deinit(self: *IgnoreRule, allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        allocator.free(self.pattern);
    }
};

const IgnoreStack = struct {
    rules: std.ArrayList(IgnoreRule) = .empty,

    fn deinit(self: *IgnoreStack, allocator: std.mem.Allocator) void {
        self.truncate(allocator, 0);
        self.rules.deinit(allocator);
    }

    fn truncate(self: *IgnoreStack, allocator: std.mem.Allocator, len: usize) void {
        for (self.rules.items[len..]) |*rule| rule.deinit(allocator);
        self.rules.shrinkRetainingCapacity(len);
    }

    fn isIgnored(self: *const IgnoreStack, relative_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.rules.items) |rule| {
            if (ruleMatches(rule, relative_path, is_dir)) {
                ignored = !rule.negated;
            }
        }
        return ignored;
    }
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

const NormalizedFuzzyInput = struct {
    bytes: []const u8,
    char_indices: []const u32,

    fn deinit(self: *NormalizedFuzzyInput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.char_indices);
    }
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
    const has_git_context = try rootHasGitContext(allocator, io, root);
    var ignore_stack = IgnoreStack{};
    defer ignore_stack.deinit(allocator);
    try scanDir(allocator, io, root, "", &dir, query, matches, state, &ignore_stack, has_git_context);
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
    ignore_stack: *IgnoreStack,
    parent_git_context: bool,
) !void {
    const current_has_git_marker = try dirHasGitMarker(allocator, io, root, relative_dir);
    const current_git_context = parent_git_context or current_has_git_marker;
    const previous_ignore_rule_len = ignore_stack.rules.items.len;
    defer ignore_stack.truncate(allocator, previous_ignore_rule_len);
    if (current_git_context) {
        try loadGitignoreRules(allocator, io, root, relative_dir, ignore_stack);
    }
    if (current_has_git_marker) {
        try loadGitInfoExcludeRules(allocator, io, root, relative_dir, ignore_stack);
    }

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
        if (match_type != null and ignore_stack.isIgnored(relative_path, stat.kind == .directory)) {
            allocator.free(relative_path);
            owns_relative_path = false;
            continue;
        }
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
            {
                var child_dir = openIterableDir(io, full_path) catch {
                    if (owns_relative_path) {
                        allocator.free(relative_path);
                        owns_relative_path = false;
                    }
                    continue;
                };
                defer child_dir.close(io);
                try scanDir(allocator, io, root, relative_path, &child_dir, query, matches, state, ignore_stack, current_git_context);
            }
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

fn rootHasGitContext(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
    const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch return false;
    defer allocator.free(real_root);
    return findGitMarkerInAncestors(allocator, io, real_root);
}

fn findGitMarkerInAncestors(allocator: std.mem.Allocator, io: std.Io, start: []const u8) !bool {
    var current = try allocator.dupe(u8, start);
    defer allocator.free(current);

    while (true) {
        const marker = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(marker);
        if (pathExists(io, marker)) return true;

        const parent = std.fs.path.dirname(current) orelse return false;
        if (std.mem.eql(u8, parent, current)) return false;
        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }
}

fn dirHasGitMarker(allocator: std.mem.Allocator, io: std.Io, root: []const u8, relative_dir: []const u8) !bool {
    const marker = if (relative_dir.len == 0)
        try std.fs.path.join(allocator, &.{ root, ".git" })
    else
        try std.fs.path.join(allocator, &.{ root, relative_dir, ".git" });
    defer allocator.free(marker);
    return pathExists(io, marker);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn loadGitignoreRules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_dir: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    const path = if (relative_dir.len == 0)
        try std.fs.path.join(allocator, &.{ root, ".gitignore" })
    else
        try std.fs.path.join(allocator, &.{ root, relative_dir, ".gitignore" });
    defer allocator.free(path);

    try loadIgnoreRulesFromPath(allocator, io, path, relative_dir, ignore_stack);
}

fn loadGitInfoExcludeRules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_dir: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    const path = if (relative_dir.len == 0)
        try std.fs.path.join(allocator, &.{ root, ".git", "info", "exclude" })
    else
        try std.fs.path.join(allocator, &.{ root, relative_dir, ".git", "info", "exclude" });
    defer allocator.free(path);

    try loadIgnoreRulesFromPath(allocator, io, path, relative_dir, ignore_stack);
}

fn loadIgnoreRulesFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    relative_dir: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const raw_without_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, raw_without_cr, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var pattern = trimmed;
        const negated = pattern[0] == '!';
        if (negated) {
            pattern = pattern[1..];
            if (pattern.len == 0) continue;
        }
        const anchored = pattern.len > 0 and pattern[0] == '/';
        if (anchored) pattern = pattern[1..];

        var directory_only = false;
        while (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
            directory_only = true;
            pattern = pattern[0 .. pattern.len - 1];
        }
        if (pattern.len == 0) continue;

        const owned_base = try allocator.dupe(u8, relative_dir);
        errdefer allocator.free(owned_base);
        const owned_pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_pattern);
        try ignore_stack.rules.append(allocator, .{
            .base_dir = owned_base,
            .pattern = owned_pattern,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
            .has_slash = std.mem.indexOfScalar(u8, pattern, '/') != null,
        });
    }
}

fn ruleMatches(rule: IgnoreRule, relative_path: []const u8, is_dir: bool) bool {
    if (rule.directory_only and !is_dir) return false;
    const rel_to_base = pathRelativeToBase(rule.base_dir, relative_path) orelse return false;
    if (rel_to_base.len == 0) return false;

    if (rule.anchored or rule.has_slash) {
        return gitignoreGlobMatches(rule.pattern, rel_to_base);
    }
    var components = std.mem.splitScalar(u8, rel_to_base, '/');
    while (components.next()) |component| {
        if (gitignoreGlobMatches(rule.pattern, component)) return true;
    }
    return false;
}

fn pathRelativeToBase(base_dir: []const u8, relative_path: []const u8) ?[]const u8 {
    if (base_dir.len == 0) return relative_path;
    if (std.mem.eql(u8, base_dir, relative_path)) return "";
    if (!std.mem.startsWith(u8, relative_path, base_dir)) return null;
    if (relative_path.len <= base_dir.len or relative_path[base_dir.len] != '/') return null;
    return relative_path[base_dir.len + 1 ..];
}

fn gitignoreGlobMatches(pattern: []const u8, value: []const u8) bool {
    return globMatchesAt(pattern, value);
}

fn globMatchesAt(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    while (pattern_index < pattern.len) {
        const token = pattern[pattern_index];
        if (token == '*') {
            var allow_slash = false;
            while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                if (pattern_index + 1 < pattern.len and pattern[pattern_index + 1] == '*') {
                    allow_slash = true;
                }
                pattern_index += 1;
            }
            const rest = pattern[pattern_index..];
            var end = value_index;
            while (true) {
                if (globMatchesAt(rest, value[end..])) return true;
                if (end >= value.len) break;
                if (!allow_slash and value[end] == '/') break;
                end += 1;
            }
            return false;
        }
        if (value_index >= value.len) return false;
        if (token == '?') {
            if (value[value_index] == '/') return false;
            pattern_index += 1;
            value_index += 1;
            continue;
        }
        if (token != value[value_index]) return false;
        pattern_index += 1;
        value_index += 1;
    }
    return value_index == value.len;
}

fn fuzzyMatchPath(allocator: std.mem.Allocator, path: []const u8, query: []const u8) !?FuzzyMatch {
    var normalized_path = try normalizeFuzzyInput(allocator, path);
    defer normalized_path.deinit(allocator);

    var normalized_query = try normalizeFuzzyInput(allocator, query);
    defer normalized_query.deinit(allocator);

    if (normalized_query.bytes.len == 0) {
        return .{
            .score = 0,
            .indices = try allocator.alloc(u32, 0),
        };
    }
    if (normalized_query.bytes.len > normalized_path.bytes.len) return null;

    const path_len = normalized_path.bytes.len;
    const query_len = normalized_query.bytes.len;
    const cell_count = std.math.mul(usize, query_len, path_len) catch return error.OutOfMemory;
    const bonuses = try allocator.alloc(u32, path_len);
    defer allocator.free(bonuses);
    fillPathBonuses(normalized_path.bytes, bonuses);

    var parents = try allocator.alloc(usize, cell_count);
    defer allocator.free(parents);
    @memset(parents, ParentIndexNone);

    var previous = try allocator.alloc(ScoreState, path_len);
    defer allocator.free(previous);
    @memset(previous, .{});

    var current = try allocator.alloc(ScoreState, path_len);
    defer allocator.free(current);

    for (normalized_query.bytes, 0..) |query_byte, query_index| {
        @memset(current, .{});
        var best_gap_value: ?u32 = null;
        var best_gap_index: usize = ParentIndexNone;
        const query_lower = std.ascii.toLower(query_byte);

        for (normalized_path.bytes, 0..) |path_byte, path_index| {
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

    var raw_indices = try allocator.alloc(u32, query_len);
    errdefer allocator.free(raw_indices);
    var query_index = query_len;
    var path_index = best_index;
    while (query_index > 0) {
        query_index -= 1;
        raw_indices[query_index] = normalized_path.char_indices[path_index];
        const parent = parents[query_index * path_len + path_index];
        if (query_index == 0) break;
        path_index = parent;
    }

    var indices = std.ArrayList(u32).empty;
    errdefer indices.deinit(allocator);
    var previous_index: ?u32 = null;
    for (raw_indices) |index| {
        if (previous_index == null or previous_index.? != index) {
            try indices.append(allocator, index);
            previous_index = index;
        }
    }
    const owned_indices = try indices.toOwnedSlice(allocator);
    allocator.free(raw_indices);

    return .{
        .score = best_score,
        .indices = owned_indices,
    };
}

fn normalizeFuzzyInput(allocator: std.mem.Allocator, value: []const u8) !NormalizedFuzzyInput {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);
    var char_indices = std.ArrayList(u32).empty;
    errdefer char_indices.deinit(allocator);

    var index: usize = 0;
    var char_index: u32 = 0;
    while (index < value.len) {
        const start_index = index;
        if (value[index] < 0x80) {
            try appendNormalizedFuzzyByte(allocator, &bytes, &char_indices, value[index], char_index);
            index += 1;
            char_index += 1;
            continue;
        }

        const width = std.unicode.utf8ByteSequenceLength(value[index]) catch {
            try appendNormalizedFuzzyByte(allocator, &bytes, &char_indices, value[index], char_index);
            index += 1;
            char_index += 1;
            continue;
        };
        if (index + width > value.len) {
            try appendNormalizedFuzzyByte(allocator, &bytes, &char_indices, value[index], char_index);
            index += 1;
            char_index += 1;
            continue;
        }

        const codepoint = std.unicode.utf8Decode(value[index .. index + width]) catch {
            try appendNormalizedFuzzyByte(allocator, &bytes, &char_indices, value[index], char_index);
            index += 1;
            char_index += 1;
            continue;
        };
        const codepoint_char_index = char_index;
        index += width;
        char_index += 1;

        if (isCombiningMark(codepoint)) continue;
        if (try appendFoldedLatin(allocator, &bytes, &char_indices, codepoint, codepoint_char_index)) continue;

        for (value[start_index..index]) |byte| {
            try appendNormalizedFuzzyByte(allocator, &bytes, &char_indices, byte, codepoint_char_index);
        }
    }

    const owned_bytes = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bytes);
    const owned_char_indices = try char_indices.toOwnedSlice(allocator);
    return .{
        .bytes = owned_bytes,
        .char_indices = owned_char_indices,
    };
}

fn appendNormalizedFuzzyByte(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    char_indices: *std.ArrayList(u32),
    byte: u8,
    char_index: u32,
) !void {
    try bytes.append(allocator, byte);
    try char_indices.append(allocator, char_index);
}

fn appendNormalizedFuzzyAscii(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    char_indices: *std.ArrayList(u32),
    replacement: []const u8,
    char_index: u32,
) !void {
    for (replacement) |byte| try appendNormalizedFuzzyByte(allocator, bytes, char_indices, byte, char_index);
}

fn appendFoldedLatin(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    char_indices: *std.ArrayList(u32),
    codepoint: u21,
    char_index: u32,
) !bool {
    const replacement = foldedLatinReplacement(codepoint) orelse return false;
    try appendNormalizedFuzzyAscii(allocator, bytes, char_indices, replacement, char_index);
    return true;
}

fn isCombiningMark(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f);
}

fn foldedLatinReplacement(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0x00c0...0x00c5, 0x00e0...0x00e5, 0x0100...0x0105, 0x01cd...0x01ce, 0x01de...0x01e1, 0x01fa...0x01fb, 0x0200...0x0203, 0x0226...0x0227 => "a",
        0x00c7, 0x00e7, 0x0106...0x010d, 0x0187...0x0188, 0x023b...0x023c => "c",
        0x00d0, 0x00f0, 0x010e...0x0111 => "d",
        0x00c8...0x00cb, 0x00e8...0x00eb, 0x0112...0x011b, 0x0204...0x0207, 0x0228...0x0229 => "e",
        0x011c...0x0123, 0x01e4...0x01e7 => "g",
        0x0124...0x0127, 0x021e...0x021f => "h",
        0x00cc...0x00cf, 0x00ec...0x00ef, 0x0128...0x0131, 0x01cf...0x01d0, 0x0208...0x020b => "i",
        0x0134...0x0135 => "j",
        0x0136...0x0138, 0x01e8...0x01e9 => "k",
        0x0139...0x0142, 0x0234 => "l",
        0x00d1, 0x00f1, 0x0143...0x0149, 0x01f8...0x01f9 => "n",
        0x00d2...0x00d6, 0x00d8, 0x00f2...0x00f6, 0x00f8, 0x014c...0x0151, 0x01d1...0x01d2, 0x01fe...0x01ff, 0x020c...0x020f, 0x022a...0x0231 => "o",
        0x0154...0x0159, 0x0210...0x0213 => "r",
        0x015a...0x0161, 0x0218...0x0219 => "s",
        0x0162...0x0167, 0x021a...0x021b, 0x0236 => "t",
        0x00d9...0x00dc, 0x00f9...0x00fc, 0x0168...0x0173, 0x01d3...0x01dc, 0x0214...0x0217 => "u",
        0x0174...0x0175 => "w",
        0x00dd, 0x00fd, 0x00ff, 0x0176...0x0178, 0x0232...0x0233 => "y",
        0x0179...0x017e => "z",
        0x00c6, 0x00e6 => "ae",
        0x0152, 0x0153 => "oe",
        0x00df => "ss",
        0x00de, 0x00fe => "th",
        else => null,
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

test "fuzzy match folds latin accents while preserving original character indices" {
    const allocator = std.testing.allocator;

    const composed = (try fuzzyMatchPath(allocator, "caf\u{e9}.txt", "cafe")).?;
    defer allocator.free(composed.indices);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, composed.indices);

    const decomposed = (try fuzzyMatchPath(allocator, "src/cafe\u{301}.txt", "cafe")).?;
    defer allocator.free(decomposed.indices);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6, 7 }, decomposed.indices);

    const query_accent = (try fuzzyMatchPath(allocator, "resume.md", "r\u{e9}sum\u{e9}")).?;
    defer allocator.free(query_accent.indices);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, query_accent.indices);

    const path_accent = (try fuzzyMatchPath(allocator, "r\u{e9}sum\u{e9}.md", "resume")).?;
    defer allocator.free(path_accent.indices);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, path_accent.indices);
}

test "fuzzy search respects local gitignore rules in git context" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDir(io, ".git", .default_dir);
    try dir.dir.createDirPath(io, ".git/info");
    try dir.dir.createDirPath(io, ".vscode");
    try dir.dir.createDirPath(io, "ignored-dir");
    try dir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "ignored.txt\nignored-dir/\n.vscode/*\n!.vscode/\n!.vscode/settings.json\n",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = ".git/info/exclude",
        .data = "info-excluded.txt\n",
    });
    try dir.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignored\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "info-excluded.txt", .data = "ignored\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "ignored-dir/nested.txt", .data = "ignored\n" });
    try dir.dir.writeFile(io, .{ .sub_path = ".vscode/extensions.json", .data = "{}\n" });
    try dir.dir.writeFile(io, .{ .sub_path = ".vscode/settings.json", .data = "{}\n" });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    var settings = try search(allocator, "settings", &roots);
    defer settings.deinit(allocator);
    try std.testing.expect(resultContainsPath(settings, ".vscode/settings.json"));

    var extensions = try search(allocator, "extensions", &roots);
    defer extensions.deinit(allocator);
    try std.testing.expect(!resultContainsPath(extensions, ".vscode/extensions.json"));

    var ignored = try search(allocator, "ignored", &roots);
    defer ignored.deinit(allocator);
    try std.testing.expect(!resultContainsPath(ignored, "ignored.txt"));
    try std.testing.expect(!resultContainsPath(ignored, "ignored-dir"));
    try std.testing.expect(!resultContainsPath(ignored, "ignored-dir/nested.txt"));

    var info_excluded = try search(allocator, "infoexcluded", &roots);
    defer info_excluded.deinit(allocator);
    try std.testing.expect(!resultContainsPath(info_excluded, "info-excluded.txt"));
}

fn resultContainsPath(results: Results, path: []const u8) bool {
    for (results.files) |file| {
        if (std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}
