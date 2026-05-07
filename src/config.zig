const std = @import("std");
const env = @import("env.zig");

pub const Config = struct {
    codex_home: []const u8,
    model: []const u8,
    base_url: []const u8,
    installation_id: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.installation_id);
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const codex_home = try resolveCodexHome(allocator);
    errdefer allocator.free(codex_home);

    const model = try resolveModel(allocator, codex_home);
    errdefer allocator.free(model);

    const base_url = if (try env.getOwned(allocator, "CODEX_ZIG_BASE_URL")) |value|
        value
    else
        try allocator.dupe(u8, "https://api.openai.com/v1");
    errdefer allocator.free(base_url);

    const installation_id = try readOptionalFileTrimmed(allocator, codex_home, "installation_id", "unknown-zig-port");
    errdefer allocator.free(installation_id);

    return .{
        .codex_home = codex_home,
        .model = model,
        .base_url = base_url,
        .installation_id = installation_id,
    };
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| {
        return value;
    }

    const home = (try env.getOwned(allocator, "HOME")) orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn resolveModel(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL")) |value| {
        return value;
    }

    if (try readModelFromConfig(allocator, codex_home)) |model| {
        return model;
    }

    return allocator.dupe(u8, "gpt-5.2-codex");
}

fn readModelFromConfig(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;
        if (!std.mem.startsWith(u8, line, "model")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '"' and rhs[rhs.len - 1] == '"') {
            const model = try allocator.dupe(u8, rhs[1 .. rhs.len - 1]);
            return model;
        }
    }
    return null;
}

fn readOptionalFileTrimmed(
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, fallback),
        else => return err,
    };
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback);
    return allocator.dupe(u8, trimmed);
}

test "top-level model is read from config" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "config.toml", .data = "model = \"demo-model\"\n[other]\nmodel = \"ignored\"\n" });
    const cwd_path = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_path);
    const model = try readModelFromConfig(allocator, cwd_path);
    defer allocator.free(model.?);
    try std.testing.expectEqualStrings("demo-model", model.?);
}
