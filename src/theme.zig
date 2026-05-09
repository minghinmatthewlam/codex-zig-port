const std = @import("std");

pub const default_theme = "catppuccin-mocha";

pub const ThemeEntry = struct {
    name: []const u8,
    is_custom: bool,

    fn deinit(self: ThemeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const ThemeList = struct {
    items: std.ArrayList(ThemeEntry) = .empty,

    pub fn deinit(self: *ThemeList, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

pub const builtin_theme_names = [_][]const u8{
    "1337",
    "ansi",
    "base16",
    "base16-256",
    "base16-eighties-dark",
    "base16-mocha-dark",
    "base16-ocean-dark",
    "base16-ocean-light",
    "catppuccin-frappe",
    "catppuccin-latte",
    "catppuccin-macchiato",
    "catppuccin-mocha",
    "coldark-cold",
    "coldark-dark",
    "dark-neon",
    "dracula",
    "github",
    "gruvbox-dark",
    "gruvbox-light",
    "inspired-github",
    "monokai-extended",
    "monokai-extended-bright",
    "monokai-extended-light",
    "monokai-extended-origin",
    "nord",
    "one-half-dark",
    "one-half-light",
    "solarized-dark",
    "solarized-light",
    "sublime-snazzy",
    "two-dark",
    "zenburn",
};

pub fn initialTheme(allocator: std.mem.Allocator, configured_theme: ?[]const u8) ![]const u8 {
    return allocator.dupe(u8, configured_theme orelse default_theme);
}

pub fn isAvailable(allocator: std.mem.Allocator, codex_home: []const u8, name: []const u8) !bool {
    if (isBuiltin(name)) return true;
    return customThemeExists(allocator, codex_home, name);
}

pub fn listAvailable(allocator: std.mem.Allocator, codex_home: []const u8) !ThemeList {
    var list = ThemeList{};
    errdefer list.deinit(allocator);

    for (builtin_theme_names) |name| {
        try appendEntry(allocator, &list, name, false);
    }

    const themes_dir = try std.fs.path.join(allocator, &.{ codex_home, "themes" });
    defer allocator.free(themes_dir);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, themes_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            sortEntries(list.items.items);
            return list;
        },
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".tmTheme")) continue;
        const stem = entry.name[0 .. entry.name.len - ".tmTheme".len];
        if (!isSafeThemeName(stem)) continue;
        if (containsName(list.items.items, stem)) continue;
        try appendEntry(allocator, &list, stem, true);
    }

    sortEntries(list.items.items);
    return list;
}

pub fn printUsage() void {
    std.debug.print(
        \\usage: /theme [status|list|NAME]
        \\custom themes: place .tmTheme files in $CODEX_HOME/themes
        \\
    , .{});
}

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_theme_names) |builtin_name| {
        if (std.mem.eql(u8, name, builtin_name)) return true;
    }
    return false;
}

fn customThemeExists(allocator: std.mem.Allocator, codex_home: []const u8, name: []const u8) !bool {
    if (!isSafeThemeName(name)) return false;
    const filename = try std.fmt.allocPrint(allocator, "{s}.tmTheme", .{name});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ codex_home, "themes", filename });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn appendEntry(allocator: std.mem.Allocator, list: *ThemeList, name: []const u8, is_custom: bool) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try list.items.append(allocator, .{
        .name = owned_name,
        .is_custom = is_custom,
    });
}

fn containsName(entries: []const ThemeEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn sortEntries(entries: []ThemeEntry) void {
    std.mem.sort(ThemeEntry, entries, {}, entryLessThan);
}

fn entryLessThan(_: void, left: ThemeEntry, right: ThemeEntry) bool {
    return asciiCaseOrder(left.name, right.name) == .lt;
}

fn asciiCaseOrder(left: []const u8, right: []const u8) std.math.Order {
    const min_len = @min(left.len, right.len);
    var index: usize = 0;
    while (index < min_len) : (index += 1) {
        const left_byte = std.ascii.toLower(left[index]);
        const right_byte = std.ascii.toLower(right[index]);
        if (left_byte < right_byte) return .lt;
        if (left_byte > right_byte) return .gt;
    }
    if (left.len < right.len) return .lt;
    if (left.len > right.len) return .gt;
    return std.mem.order(u8, left, right);
}

fn isSafeThemeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

test "recognizes bundled themes" {
    try std.testing.expect(isBuiltin("catppuccin-mocha"));
    try std.testing.expect(isBuiltin("solarized-light"));
    try std.testing.expect(!isBuiltin("missing-theme"));
}

test "lists bundled and custom themes sorted together" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "themes");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "themes/zzz-custom.tmTheme", .data = "placeholder" });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "themes/Aaa-custom.tmTheme", .data = "placeholder" });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "themes/not-a-theme.txt", .data = "placeholder" });

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var list = try listAvailable(allocator, root);
    defer list.deinit(allocator);

    try std.testing.expect(containsName(list.items.items, "Aaa-custom"));
    try std.testing.expect(containsName(list.items.items, "zzz-custom"));
    try std.testing.expect(!containsName(list.items.items, "not-a-theme"));
    try std.testing.expect(asciiCaseOrder(list.items.items[0].name, list.items.items[1].name) != .gt);
}

test "accepts existing custom theme names" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "themes");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "themes/my-theme.tmTheme", .data = "placeholder" });

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try std.testing.expect(try isAvailable(allocator, root, "my-theme"));
    try std.testing.expect(!try isAvailable(allocator, root, "../bad"));
}
