const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const env = @import("env.zig");

const CODEX_DMG_URL_ARM64 = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";
const CODEX_DMG_URL_X64 = "https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg";

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;

const ParsedAppCommand = struct {
    path: []const u8 = ".",
    download_url_override: ?[]const u8 = null,
    help: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const parsed = try parseArgs(allocator, args);
    if (parsed.help) {
        printHelp();
        return;
    }
    try runParsed(allocator, parsed);
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig app [PATH] [--download-url URL]
        \\
        \\Open PATH in Codex Desktop, installing Codex Desktop first if needed.
        \\
        \\Options:
        \\  --download-url URL      Override the Codex Desktop installer URL
        \\  -h, --help              Print help
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !ParsedAppCommand {
    var values = std.ArrayList([]const u8).empty;
    defer values.deinit(allocator);
    while (args.next()) |arg| {
        try values.append(allocator, arg);
    }
    return parseArgSlice(values.items);
}

fn parseArgSlice(arguments: []const []const u8) !ParsedAppCommand {
    var parsed = ParsedAppCommand{};
    var path_seen = false;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const arg = arguments[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.help = true;
            return parsed;
        }
        if (std.mem.eql(u8, arg, "--download-url")) {
            index += 1;
            if (index >= arguments.len) return error.MissingAppDownloadUrl;
            parsed.download_url_override = arguments[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--download-url=")) {
            parsed.download_url_override = arg["--download-url=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppOption;
        if (path_seen) return error.UnexpectedAppArgument;
        parsed.path = arg;
        path_seen = true;
    }
    return parsed;
}

fn runParsed(allocator: std.mem.Allocator, parsed: ParsedAppCommand) !void {
    if (builtin.os.tag != .macos) return error.AppCommandUnsupportedPlatform;

    const workspace = try canonicalizePathOrOriginal(allocator, parsed.path);
    defer allocator.free(workspace);

    if (try findExistingCodexAppPath(allocator)) |app_path| {
        defer allocator.free(app_path);
        const message = try std.fmt.allocPrint(allocator, "Opening Codex Desktop at {s}...\n", .{app_path});
        defer allocator.free(message);
        try cli_utils.writeStderr(message);
        try openCodexApp(allocator, app_path, workspace);
        return;
    }

    try cli_utils.writeStderr("Codex Desktop not found; downloading installer...\n");
    const download_url = parsed.download_url_override orelse defaultDownloadUrl();
    const installed_app = try downloadAndInstallCodexToUserApplications(allocator, download_url);
    defer allocator.free(installed_app);

    const message = try std.fmt.allocPrint(allocator, "Launching Codex Desktop from {s}...\n", .{installed_app});
    defer allocator.free(message);
    try cli_utils.writeStderr(message);
    try openCodexApp(allocator, installed_app, workspace);
}

fn defaultDownloadUrl() []const u8 {
    return if (isAppleSiliconMac()) CODEX_DMG_URL_ARM64 else CODEX_DMG_URL_X64;
}

fn isAppleSiliconMac() bool {
    return appDownloadUsesArm64Dmg(
        builtin.cpu.arch == .aarch64,
        macosSysctlFlag("sysctl.proc_translated"),
        macosSysctlFlag("hw.optional.arm64"),
    );
}

fn appDownloadUsesArm64Dmg(binary_is_arm64: bool, proc_translated: ?bool, hw_optional_arm64: ?bool) bool {
    return binary_is_arm64 or (proc_translated orelse false) or (hw_optional_arm64 orelse false);
}

fn macosSysctlFlag(name: [:0]const u8) ?bool {
    if (builtin.os.tag != .macos) return null;
    var value: c_int = 0;
    var size: usize = @sizeOf(c_int);
    const result = sysctlbyname(name.ptr, &value, &size, null, 0);
    if (result != 0) return null;
    return value != 0;
}

fn canonicalizePathOrOriginal(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch
        return allocator.dupe(u8, path);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn findExistingCodexAppPath(allocator: std.mem.Allocator) !?[]u8 {
    if (try isDirectory("/Applications/Codex.app")) {
        return try allocator.dupe(u8, "/Applications/Codex.app");
    }

    const home = try env.getOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    const home_value = home orelse return null;
    const user_app = try std.fs.path.join(allocator, &.{ home_value, "Applications", "Codex.app" });
    errdefer allocator.free(user_app);
    if (try isDirectory(user_app)) return user_app;
    allocator.free(user_app);
    return null;
}

fn isDirectory(path: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return stat.kind == .directory;
}

fn openCodexApp(allocator: std.mem.Allocator, app_path: []const u8, workspace: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "Opening workspace {s}...\n", .{workspace});
    defer allocator.free(message);
    try cli_utils.writeStderr(message);

    const open_bin = try env.getOwned(allocator, "CODEX_TEST_APP_OPEN_BIN");
    defer if (open_bin) |value| allocator.free(value);
    try runInherited(allocator, &.{ open_bin orelse "open", "-a", app_path, workspace });
}

fn downloadAndInstallCodexToUserApplications(allocator: std.mem.Allocator, dmg_url: []const u8) ![]u8 {
    const temp_root = try createInstallerTempRoot(allocator);
    defer {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};
        allocator.free(temp_root);
    }

    const dmg_path = try std.fs.path.join(allocator, &.{ temp_root, "Codex.dmg" });
    defer allocator.free(dmg_path);
    try downloadDmg(allocator, dmg_url, dmg_path);

    try cli_utils.writeStderr("Mounting Codex Desktop installer...\n");
    const mount_point = try mountDmg(allocator, dmg_path);
    defer allocator.free(mount_point);

    const mounted_message = try std.fmt.allocPrint(allocator, "Installer mounted at {s}.\n", .{mount_point});
    defer allocator.free(mounted_message);
    try cli_utils.writeStderr(mounted_message);

    const installed_app = installFromMountedDmg(allocator, mount_point) catch |err| {
        detachDmg(allocator, mount_point) catch |detach_err| {
            const warning = std.fmt.allocPrint(
                allocator,
                "warning: failed to detach dmg at {s}: {s}\n",
                .{ mount_point, @errorName(detach_err) },
            ) catch null;
            defer if (warning) |value| allocator.free(value);
            if (warning) |value| cli_utils.writeStderr(value) catch {};
        };
        return err;
    };

    detachDmg(allocator, mount_point) catch |err| {
        const warning = try std.fmt.allocPrint(
            allocator,
            "warning: failed to detach dmg at {s}: {s}\n",
            .{ mount_point, @errorName(err) },
        );
        defer allocator.free(warning);
        try cli_utils.writeStderr(warning);
    };
    return installed_app;
}

fn installFromMountedDmg(allocator: std.mem.Allocator, mount_point: []const u8) ![]u8 {
    const app_in_volume = try findCodexAppInMount(allocator, mount_point);
    defer allocator.free(app_in_volume);
    return installCodexAppBundle(allocator, app_in_volume);
}

fn createInstallerTempRoot(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const suffix = std.mem.readInt(u64, &random_bytes, .little);
        const path = try std.fmt.allocPrint(allocator, "/tmp/codex-app-installer-{x}", .{suffix});
        errdefer allocator.free(path);
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.AppTempDirUnavailable;
}

fn downloadDmg(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    try cli_utils.writeStderr("Downloading installer...\n");
    try runInherited(allocator, &.{ "curl", "-fL", "--retry", "3", "--retry-delay", "1", "-o", dest, url });
}

fn mountDmg(allocator: std.mem.Allocator, dmg_path: []const u8) ![]u8 {
    const stdout = try runCapturedStdout(allocator, &.{ "hdiutil", "attach", "-nobrowse", "-readonly", dmg_path });
    defer allocator.free(stdout);
    return (try parseHdiutilAttachMountPoint(allocator, stdout)) orelse error.AppInstallerMountPointNotFound;
}

fn detachDmg(allocator: std.mem.Allocator, mount_point: []const u8) !void {
    try runInherited(allocator, &.{ "hdiutil", "detach", mount_point });
}

fn installCodexAppBundle(allocator: std.mem.Allocator, app_in_volume: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const home = try env.getOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);

    var application_dirs = std.ArrayList([]const u8).empty;
    defer application_dirs.deinit(allocator);
    try application_dirs.append(allocator, "/Applications");
    var user_applications_dir: ?[]u8 = null;
    defer if (user_applications_dir) |value| allocator.free(value);
    if (home) |home_value| {
        user_applications_dir = try std.fs.path.join(allocator, &.{ home_value, "Applications" });
        try application_dirs.append(allocator, user_applications_dir.?);
    }

    for (application_dirs.items) |applications_dir| {
        const message = try std.fmt.allocPrint(allocator, "Installing Codex Desktop into {s}...\n", .{applications_dir});
        defer allocator.free(message);
        try cli_utils.writeStderr(message);

        std.Io.Dir.cwd().createDirPath(io, applications_dir) catch |err| {
            const warning = try std.fmt.allocPrint(allocator, "warning: failed to create applications dir {s}: {s}\n", .{ applications_dir, @errorName(err) });
            defer allocator.free(warning);
            try cli_utils.writeStderr(warning);
            continue;
        };

        const dest_app = try std.fs.path.join(allocator, &.{ applications_dir, "Codex.app" });
        defer allocator.free(dest_app);
        if (try isDirectory(dest_app)) return allocator.dupe(u8, dest_app);

        runInherited(allocator, &.{ "ditto", app_in_volume, dest_app }) catch |err| {
            const warning = try std.fmt.allocPrint(allocator, "warning: failed to install Codex.app to {s}: {s}\n", .{ applications_dir, @errorName(err) });
            defer allocator.free(warning);
            try cli_utils.writeStderr(warning);
            continue;
        };
        return allocator.dupe(u8, dest_app);
    }

    return error.AppInstallFailed;
}

fn findCodexAppInMount(allocator: std.mem.Allocator, mount_point: []const u8) ![]u8 {
    const direct = try std.fs.path.join(allocator, &.{ mount_point, "Codex.app" });
    errdefer allocator.free(direct);
    if (try isDirectory(direct)) return direct;
    allocator.free(direct);

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;
        return std.fs.path.join(allocator, &.{ mount_point, entry.name });
    }
    return error.AppBundleNotFound;
}

fn runInherited(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var child = try std.process.spawn(io_instance.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io_instance.io());
    if (!childTermSuccess(term)) return error.AppCommandFailed;
}

fn runCapturedStdout(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!childTermSuccess(result.term)) {
        try cli_utils.writeStderr(result.stderr);
        return error.AppCommandFailed;
    }
    return result.stdout;
}

fn parseHdiutilAttachMountPoint(allocator: std.mem.Allocator, output: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOf(u8, line, "/Volumes/") == null) continue;
        if (std.mem.lastIndexOfScalar(u8, line, '\t')) |tab_index| {
            const mount = std.mem.trim(u8, line[tab_index + 1 ..], " \t\r");
            if (mount.len > 0) return try allocator.dupe(u8, mount);
        }
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "/Volumes/")) return try allocator.dupe(u8, field);
        }
    }
    return null;
}

fn childTermSuccess(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "app command parser accepts path and download URL" {
    const argv = [_][]const u8{ "/tmp/workspace", "--download-url=https://example.test/Codex.dmg" };
    const parsed = try parseArgSlice(argv[0..]);
    try std.testing.expectEqualStrings("/tmp/workspace", parsed.path);
    try std.testing.expectEqualStrings("https://example.test/Codex.dmg", parsed.download_url_override.?);
}

test "app command parser defaults workspace path" {
    const argv = [_][]const u8{};
    const parsed = try parseArgSlice(argv[0..]);
    try std.testing.expectEqualStrings(".", parsed.path);
    try std.testing.expect(parsed.download_url_override == null);
}

test "app command parser rejects extra path after explicit dot" {
    const argv = [_][]const u8{ ".", "/tmp/workspace" };
    try std.testing.expectError(error.UnexpectedAppArgument, parseArgSlice(argv[0..]));
}

test "app command download URL uses arm64 dmg for Apple Silicon indicators" {
    try std.testing.expect(appDownloadUsesArm64Dmg(true, null, null));
    try std.testing.expect(appDownloadUsesArm64Dmg(false, true, null));
    try std.testing.expect(appDownloadUsesArm64Dmg(false, null, true));
    try std.testing.expect(!appDownloadUsesArm64Dmg(false, false, false));
}

test "hdiutil attach mount point parser accepts tab separated output" {
    const output = "/dev/disk2s1\tApple_HFS\tCodex Installer\t/Volumes/Codex Installer\n";
    const parsed = (try parseHdiutilAttachMountPoint(std.testing.allocator, output)).?;
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualStrings("/Volumes/Codex Installer", parsed);
}
