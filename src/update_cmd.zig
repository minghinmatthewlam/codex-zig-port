const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const env = @import("env.zig");

const STANDALONE_PACKAGES_DIRNAME = "standalone";
const RELEASES_DIRNAME = "releases";

pub const UpdateAction = enum {
    npm_global_latest,
    bun_global_latest,
    brew_upgrade,
    standalone_unix,
    standalone_windows,

    fn argv(action: UpdateAction) []const []const u8 {
        return switch (action) {
            .npm_global_latest => &.{ "npm", "install", "-g", "@openai/codex" },
            .bun_global_latest => &.{ "bun", "install", "-g", "@openai/codex" },
            .brew_upgrade => &.{ "brew", "upgrade", "--cask", "codex" },
            .standalone_unix => &.{ "sh", "-c", "curl -fsSL https://chatgpt.com/codex/install.sh | sh" },
            .standalone_windows => &.{ "powershell", "-c", "irm https://chatgpt.com/codex/install.ps1|iex" },
        };
    }

    pub fn commandString(action: UpdateAction) []const u8 {
        return switch (action) {
            .npm_global_latest => "npm install -g @openai/codex",
            .bun_global_latest => "bun install -g @openai/codex",
            .brew_upgrade => "brew upgrade --cask codex",
            .standalone_unix => "sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'",
            .standalone_windows => "powershell -c 'irm https://chatgpt.com/codex/install.ps1|iex'",
        };
    }
};

pub fn detectCurrentUpdateAction(allocator: std.mem.Allocator) !?UpdateAction {
    const managed_by_npm = try env.getOwned(allocator, "CODEX_MANAGED_BY_NPM");
    defer if (managed_by_npm) |value| allocator.free(value);

    const managed_by_bun = try env.getOwned(allocator, "CODEX_MANAGED_BY_BUN");
    defer if (managed_by_bun) |value| allocator.free(value);

    const io = std.Io.Threaded.global_single_threaded.io();
    const current_exe = std.process.executablePathAlloc(io, allocator) catch null;
    defer if (current_exe) |value| allocator.free(value);

    const codex_home = config.resolveCodexHome(allocator) catch null;
    defer if (codex_home) |value| allocator.free(value);

    return detectUpdateActionFromContext(
        allocator,
        builtin.os.tag == .macos,
        if (current_exe) |value| value else null,
        if (codex_home) |value| value else null,
        managed_by_npm != null,
        managed_by_bun != null,
        builtin.os.tag == .windows,
    );
}

pub fn runAction(allocator: std.mem.Allocator, action: UpdateAction) !void {
    const command = action.commandString();
    const start_message = try std.fmt.allocPrint(allocator, "\nUpdating Codex via `{s}`...\n", .{command});
    defer allocator.free(start_message);
    try cli_utils.writeStdout(start_message);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var child = try std.process.spawn(io_instance.io(), .{
        .argv = action.argv(),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io_instance.io());
    if (!childTermSuccess(term)) return error.UpdateCommandFailed;

    try cli_utils.writeStdout("\nUpdate ran successfully! Please restart Codex.\n");
}

fn detectUpdateActionFromContext(
    allocator: std.mem.Allocator,
    is_macos: bool,
    current_exe: ?[]const u8,
    codex_home: ?[]const u8,
    managed_by_npm: bool,
    managed_by_bun: bool,
    is_windows: bool,
) !?UpdateAction {
    if (managed_by_npm) return .npm_global_latest;
    if (managed_by_bun) return .bun_global_latest;

    if (current_exe) |exe_path| {
        if (try standaloneUpdateAction(allocator, exe_path, codex_home, is_windows)) |action| return action;
        if (is_macos and (pathStartsWith(exe_path, "/opt/homebrew") or pathStartsWith(exe_path, "/usr/local"))) {
            return .brew_upgrade;
        }
    }
    return null;
}

fn standaloneUpdateAction(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    codex_home: ?[]const u8,
    is_windows: bool,
) !?UpdateAction {
    const home = codex_home orelse return null;
    const canonical_exe = canonicalizePath(allocator, exe_path) catch return null;
    defer allocator.free(canonical_exe);
    const canonical_home = canonicalizePath(allocator, home) catch return null;
    defer allocator.free(canonical_home);

    const release_dir = std.fs.path.dirname(canonical_exe) orelse return null;
    const releases_root = try std.fs.path.join(allocator, &.{
        canonical_home,
        "packages",
        STANDALONE_PACKAGES_DIRNAME,
        RELEASES_DIRNAME,
    });
    defer allocator.free(releases_root);

    if (!pathStartsWith(release_dir, releases_root)) return null;
    return if (is_windows) .standalone_windows else .standalone_unix;
}

fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    }
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len == 0) return false;
    return path[prefix.len] == std.fs.path.sep;
}

fn childTermSuccess(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "update actions map to Rust-compatible commands" {
    try std.testing.expectEqualStrings("npm install -g @openai/codex", UpdateAction.npm_global_latest.commandString());
    try std.testing.expectEqualStrings("bun install -g @openai/codex", UpdateAction.bun_global_latest.commandString());
    try std.testing.expectEqualStrings("brew upgrade --cask codex", UpdateAction.brew_upgrade.commandString());
    try std.testing.expectEqualStrings("sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'", UpdateAction.standalone_unix.commandString());
    try std.testing.expectEqualStrings("powershell -c 'irm https://chatgpt.com/codex/install.ps1|iex'", UpdateAction.standalone_windows.commandString());
}

test "update detection maps install context to actions" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(UpdateAction.brew_upgrade, (try detectUpdateActionFromContext(
        allocator,
        true,
        "/opt/homebrew/bin/codex",
        null,
        false,
        false,
        false,
    )).?);
    try std.testing.expectEqual(null, try detectUpdateActionFromContext(
        allocator,
        true,
        "/opt/homebrew-extra/bin/codex",
        null,
        false,
        false,
        false,
    ));
    try std.testing.expectEqual(UpdateAction.npm_global_latest, (try detectUpdateActionFromContext(
        allocator,
        true,
        "/opt/homebrew/bin/codex",
        null,
        true,
        true,
        false,
    )).?);
    try std.testing.expectEqual(UpdateAction.bun_global_latest, (try detectUpdateActionFromContext(
        allocator,
        true,
        "/opt/homebrew/bin/codex",
        null,
        false,
        true,
        false,
    )).?);
}

test "update detection maps standalone release layout" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "codex-home/packages/standalone/releases/1.2.3/bin");
    try dir.dir.writeFile(io, .{
        .sub_path = "codex-home/packages/standalone/releases/1.2.3/bin/codex",
        .data = "",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(allocator, &.{ root, "codex-home" });
    defer allocator.free(codex_home);
    const exe_path = try std.fs.path.join(allocator, &.{ codex_home, "packages", "standalone", "releases", "1.2.3", "bin", "codex" });
    defer allocator.free(exe_path);

    try std.testing.expectEqual(UpdateAction.standalone_unix, (try detectUpdateActionFromContext(
        allocator,
        false,
        exe_path,
        codex_home,
        false,
        false,
        false,
    )).?);
    try std.testing.expectEqual(UpdateAction.standalone_windows, (try detectUpdateActionFromContext(
        allocator,
        false,
        exe_path,
        codex_home,
        false,
        false,
        true,
    )).?);
}
