const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");

const sandbox_exec_path = "/usr/bin/sandbox-exec";
pub const codex_sandbox_env_var = "CODEX_SANDBOX";
pub const seatbelt_env_value = "seatbelt";

pub const SandboxedArgv = struct {
    argv: []const []const u8,
    profile: []const u8,

    pub fn deinit(self: *const SandboxedArgv, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.profile);
    }
};

pub const WrapOptions = struct {
    cwd_override: ?[]const u8 = null,
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    read_denied_roots: []const []const u8 = &.{},
};

pub fn shouldSandbox(mode: config.SandboxMode) bool {
    return switch (mode) {
        .danger_full_access => false,
        .read_only, .workspace_write => builtin.os.tag == .macos,
    };
}

pub fn environmentWithSeatbeltMarker(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    if (builtin.os.tag == .windows) {
        var parent_env = try std.process.Environ.createMap(.{ .block = .global }, allocator);
        defer parent_env.deinit();
        var iterator = parent_env.iterator();
        while (iterator.next()) |entry| {
            try result.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        var index: usize = 0;
        while (std.c.environ[index]) |entry_ptr| : (index += 1) {
            const entry = std.mem.span(entry_ptr);
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            const key = entry[0..eq];
            if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
            try result.put(key, entry[eq + 1 ..]);
        }
    }

    try markEnvironmentSeatbelt(&result);
    return result;
}

pub fn markEnvironmentSeatbelt(env_map: *std.process.Environ.Map) !void {
    try env_map.put(codex_sandbox_env_var, seatbelt_env_value);
}

pub fn wrapArgv(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    argv: []const []const u8,
    additional_writable_roots: []const []const u8,
) !SandboxedArgv {
    return wrapArgvWithCwd(allocator, mode, argv, additional_writable_roots, null);
}

pub fn wrapArgvWithCwd(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    argv: []const []const u8,
    additional_writable_roots: []const []const u8,
    cwd_override: ?[]const u8,
) !SandboxedArgv {
    return wrapArgvWithCwdOptions(allocator, mode, argv, additional_writable_roots, cwd_override, true, true);
}

pub fn wrapArgvWithCwdOptions(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    argv: []const []const u8,
    additional_writable_roots: []const []const u8,
    cwd_override: ?[]const u8,
    include_cwd_write_root: bool,
    network_enabled: bool,
) !SandboxedArgv {
    return wrapArgvWithPolicy(allocator, mode, argv, additional_writable_roots, .{
        .cwd_override = cwd_override,
        .include_cwd_write_root = include_cwd_write_root,
        .network_enabled = network_enabled,
    });
}

pub fn wrapArgvWithPolicy(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    argv: []const []const u8,
    additional_writable_roots: []const []const u8,
    options: WrapOptions,
) !SandboxedArgv {
    const cwd = if (options.cwd_override) |cwd|
        try realPathAlloc(allocator, cwd)
    else blk: {
        break :blk try realPathAlloc(allocator, ".");
    };
    defer allocator.free(cwd);

    const resolved_roots = if (mode == .workspace_write)
        try resolveAdditionalRoots(allocator, additional_writable_roots)
    else
        try allocator.alloc([]const u8, 0);
    defer freeResolvedRoots(allocator, resolved_roots);

    const resolved_read_denied_roots = try resolveReadDeniedRoots(allocator, cwd, options.read_denied_roots);
    defer freeResolvedRoots(allocator, resolved_read_denied_roots);

    const profile = try buildProfileWithOptions(
        allocator,
        mode,
        cwd,
        resolved_roots,
        options.include_cwd_write_root,
        options.network_enabled,
        resolved_read_denied_roots,
    );
    errdefer allocator.free(profile);

    var wrapped = try allocator.alloc([]const u8, argv.len + 4);
    errdefer allocator.free(wrapped);
    wrapped[0] = sandbox_exec_path;
    wrapped[1] = "-p";
    wrapped[2] = profile;
    wrapped[3] = "--";
    @memcpy(wrapped[4..], argv);

    return .{ .argv = wrapped, .profile = profile };
}

fn buildProfile(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
) ![]const u8 {
    return buildProfileWithOptions(allocator, mode, cwd, additional_writable_roots, true, true, &.{});
}

fn buildProfileWithOptions(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
    include_cwd_write_root: bool,
    network_enabled: bool,
    read_denied_roots: []const []const u8,
) ![]const u8 {
    return switch (mode) {
        .danger_full_access => error.SandboxNotNeeded,
        .read_only => buildReadOnlyProfile(allocator, network_enabled, read_denied_roots),
        .workspace_write => blk: {
            var profile = std.ArrayList(u8).empty;
            errdefer profile.deinit(allocator);
            try profile.appendSlice(allocator, baseProfile);
            try profile.appendSlice(allocator,
                \\(deny file-write*)
                \\(allow file-write* (literal "/dev/null"))
                \\
            );
            if (include_cwd_write_root) {
                try appendWritableSubpath(allocator, &profile, cwd);
            }
            for (additional_writable_roots) |root| {
                try appendWritableSubpath(allocator, &profile, root);
            }
            try appendReadDeniedRoots(allocator, &profile, read_denied_roots);
            try appendNetworkPolicy(allocator, &profile, network_enabled);
            break :blk try profile.toOwnedSlice(allocator);
        },
    };
}

fn buildReadOnlyProfile(allocator: std.mem.Allocator, network_enabled: bool, read_denied_roots: []const []const u8) ![]const u8 {
    var profile = std.ArrayList(u8).empty;
    errdefer profile.deinit(allocator);
    try profile.appendSlice(allocator, baseProfile);
    try profile.appendSlice(allocator, readOnlyWritePolicy);
    try appendReadDeniedRoots(allocator, &profile, read_denied_roots);
    try appendNetworkPolicy(allocator, &profile, network_enabled);
    return profile.toOwnedSlice(allocator);
}

fn appendNetworkPolicy(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    network_enabled: bool,
) !void {
    if (network_enabled) return;
    try profile.appendSlice(allocator, deniedNetworkPolicy);
}

fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator);
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn resolveProfileRootPath(allocator: std.mem.Allocator, base_cwd: []const u8, root: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root)) return allocator.dupe(u8, root);
    return std.fs.path.join(allocator, &.{ base_cwd, root });
}

fn resolveAdditionalRoots(allocator: std.mem.Allocator, roots: []const []const u8) ![]const []const u8 {
    var resolved = try allocator.alloc([]const u8, roots.len);
    errdefer allocator.free(resolved);

    var count: usize = 0;
    errdefer {
        for (resolved[0..count]) |root| allocator.free(root);
    }

    for (roots) |root| {
        resolved[count] = try realPathAlloc(allocator, root);
        count += 1;
    }

    return resolved;
}

fn resolveReadDeniedRoots(allocator: std.mem.Allocator, base_cwd: []const u8, roots: []const []const u8) ![]const []const u8 {
    var resolved = try allocator.alloc([]const u8, roots.len);
    errdefer allocator.free(resolved);

    var count: usize = 0;
    errdefer {
        for (resolved[0..count]) |root| allocator.free(root);
    }

    for (roots) |root| {
        const path = try resolveProfileRootPath(allocator, base_cwd, root);
        defer allocator.free(path);
        resolved[count] = realPathAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => try canonicalMissingPath(allocator, path),
            else => return err,
        };
        count += 1;
    }

    return resolved;
}

fn canonicalMissingPath(allocator: std.mem.Allocator, absolute_path: []const u8) ![]const u8 {
    var probe_end = absolute_path.len;
    while (probe_end > 0) {
        const probe = absolute_path[0..probe_end];
        const real_parent = realPathAlloc(allocator, probe) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => {
                const parent = std.fs.path.dirname(probe) orelse return allocator.dupe(u8, absolute_path);
                if (parent.len >= probe.len) return allocator.dupe(u8, absolute_path);
                probe_end = parent.len;
                continue;
            },
            else => return err,
        };
        errdefer allocator.free(real_parent);

        const suffix = if (probe_end < absolute_path.len and absolute_path[probe_end] == std.fs.path.sep)
            absolute_path[probe_end + 1 ..]
        else
            absolute_path[probe_end..];
        if (suffix.len == 0) return real_parent;

        const joined = try std.fs.path.join(allocator, &.{ real_parent, suffix });
        allocator.free(real_parent);
        return joined;
    }
    return allocator.dupe(u8, absolute_path);
}

fn freeResolvedRoots(allocator: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |root| allocator.free(root);
    allocator.free(roots);
}

fn appendWritableSubpath(allocator: std.mem.Allocator, profile: *std.ArrayList(u8), path: []const u8) !void {
    const escaped = try escapeSeatbeltString(allocator, path);
    defer allocator.free(escaped);
    const line = try std.fmt.allocPrint(allocator, "(allow file-write* (subpath \"{s}\"))\n", .{escaped});
    defer allocator.free(line);
    try profile.appendSlice(allocator, line);
}

fn appendReadDeniedRoots(allocator: std.mem.Allocator, profile: *std.ArrayList(u8), roots: []const []const u8) !void {
    for (roots) |root| {
        const escaped = try escapeSeatbeltString(allocator, root);
        defer allocator.free(escaped);
        const block = try std.fmt.allocPrint(
            allocator,
            \\(deny file-read* (literal "{s}"))
            \\(deny file-read* (subpath "{s}"))
            \\(deny file-write* (literal "{s}"))
            \\(deny file-write* (subpath "{s}"))
            \\
        ,
            .{ escaped, escaped, escaped, escaped },
        );
        defer allocator.free(block);
        try profile.appendSlice(allocator, block);
    }
}

fn escapeSeatbeltString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);

    for (value) |byte| {
        if (byte == '"' or byte == '\\') try escaped.append(allocator, '\\');
        try escaped.append(allocator, byte);
    }

    return escaped.toOwnedSlice(allocator);
}

const baseProfile =
    \\(version 1)
    \\(allow default)
;

const readOnlyWritePolicy =
    \\(deny file-write*)
    \\(allow file-write* (literal "/dev/null"))
    \\
;

const deniedNetworkPolicy =
    \\(deny network*)
    \\
;

test "wrap argv builds sandbox-exec command" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/echo", "ok" };

    var wrapped = try wrapArgv(allocator, .read_only, argv[0..], &.{});
    defer wrapped.deinit(allocator);

    try std.testing.expectEqualStrings(sandbox_exec_path, wrapped.argv[0]);
    try std.testing.expectEqualStrings("-p", wrapped.argv[1]);
    try std.testing.expectEqualStrings("--", wrapped.argv[3]);
    try std.testing.expectEqualStrings("/bin/echo", wrapped.argv[4]);
}

test "seatbelt marker environment overrides parent value" {
    const allocator = std.testing.allocator;
    var env_map = try environmentWithSeatbeltMarker(allocator);
    defer env_map.deinit();

    try std.testing.expectEqualStrings(seatbelt_env_value, env_map.get(codex_sandbox_env_var).?);
}

test "seatbelt string escaping handles quotes and backslashes" {
    const allocator = std.testing.allocator;
    const escaped = try escapeSeatbeltString(allocator, "a\"b\\c");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c", escaped);
}

test "sandbox profile can disable network access" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, true, false, &.{});
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
}

test "sandbox profile can deny read roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, true, true, &.{"/tmp/codex-workspace/secret"});
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-read* (literal \"/tmp/codex-workspace/secret\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-write* (subpath \"/tmp/codex-workspace/secret\"))") != null);
}

test "relative read-denied roots resolve against cwd override" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.createDirPath(io_instance.io(), "workspace/secret");

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);
    const secret = try std.fs.path.join(allocator, &.{ workspace, "secret" });
    defer allocator.free(secret);

    const argv = [_][]const u8{ "/bin/echo", "ok" };
    var wrapped = try wrapArgvWithPolicy(allocator, .workspace_write, argv[0..], &.{}, .{
        .cwd_override = workspace,
        .read_denied_roots = &.{"secret"},
    });
    defer wrapped.deinit(allocator);

    const expected_secret = try std.fmt.allocPrint(allocator, "(deny file-read* (subpath \"{s}\"))", .{secret});
    defer allocator.free(expected_secret);

    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, expected_secret) != null);
}

test "relative additional writable roots stay anchored to process cwd" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.createDirPath(io_instance.io(), "workspace");

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);
    const process_src = try realPathAlloc(allocator, "src");
    defer allocator.free(process_src);

    const argv = [_][]const u8{ "/bin/echo", "ok" };
    var wrapped = try wrapArgvWithPolicy(allocator, .workspace_write, argv[0..], &.{"src"}, .{
        .cwd_override = workspace,
    });
    defer wrapped.deinit(allocator);

    const expected_src = try std.fmt.allocPrint(allocator, "(allow file-write* (subpath \"{s}\"))", .{process_src});
    defer allocator.free(expected_src);

    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, expected_src) != null);
}

test "missing read-denied roots canonicalize symlinked parents" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    try dir.dir.createDirPath(io, "secret");
    try dir.dir.symLink(io, "secret", "alias", .{ .is_directory = true });

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const secret_future = try std.fs.path.join(allocator, &.{ root, "secret", "future.txt" });
    defer allocator.free(secret_future);

    const argv = [_][]const u8{ "/bin/echo", "ok" };
    var wrapped = try wrapArgvWithPolicy(allocator, .workspace_write, argv[0..], &.{}, .{
        .cwd_override = root,
        .read_denied_roots = &.{"alias/future.txt"},
    });
    defer wrapped.deinit(allocator);

    const expected_secret = try std.fmt.allocPrint(allocator, "(deny file-write* (subpath \"{s}\"))", .{secret_future});
    defer allocator.free(expected_secret);

    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, expected_secret) != null);
}

test "read-only sandbox denies file writes" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "blocked.txt" });
    defer allocator.free(target);

    const profile = try buildProfile(allocator, .read_only, root, &.{});
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(allocator, "printf nope > {s}", .{target});
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}

test "workspace-write sandbox allows cwd writes and denies outside writes" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var allowed_dir = std.testing.tmpDir(.{});
    defer allowed_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();

    const allowed_root = try allowed_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(allowed_root);
    const blocked_root = try blocked_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(blocked_root);
    const allowed_target = try std.fs.path.join(allocator, &.{ allowed_root, "allowed.txt" });
    defer allocator.free(allowed_target);
    const blocked_target = try std.fs.path.join(allocator, &.{ blocked_root, "blocked.txt" });
    defer allocator.free(blocked_target);

    const profile = try buildProfile(allocator, .workspace_write, allowed_root, &.{});
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf ok > {s}; printf nope > {s}",
        .{ allowed_target, blocked_target },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try allowed_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "allowed.txt", .{});
    try std.testing.expectError(error.FileNotFound, blocked_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}

test "workspace-write sandbox allows additional writable roots" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var cwd_dir = std.testing.tmpDir(.{});
    defer cwd_dir.cleanup();
    var extra_dir = std.testing.tmpDir(.{});
    defer extra_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();

    const cwd_root = try cwd_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_root);
    const extra_root = try extra_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(extra_root);
    const blocked_root = try blocked_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(blocked_root);

    const extra_target = try std.fs.path.join(allocator, &.{ extra_root, "extra.txt" });
    defer allocator.free(extra_target);
    const blocked_target = try std.fs.path.join(allocator, &.{ blocked_root, "blocked.txt" });
    defer allocator.free(blocked_target);

    const additional_roots = [_][]const u8{extra_root};
    const profile = try buildProfile(allocator, .workspace_write, cwd_root, additional_roots[0..]);
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf ok > {s}; printf nope > {s}",
        .{ extra_target, blocked_target },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try extra_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "extra.txt", .{});
    try std.testing.expectError(error.FileNotFound, blocked_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "blocked.txt", .{}));
}

test "workspace-write sandbox can omit cwd write root" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var cwd_dir = std.testing.tmpDir(.{});
    defer cwd_dir.cleanup();
    var extra_dir = std.testing.tmpDir(.{});
    defer extra_dir.cleanup();

    const cwd_root = try cwd_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_root);
    const extra_root = try extra_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(extra_root);

    const cwd_target = try std.fs.path.join(allocator, &.{ cwd_root, "cwd.txt" });
    defer allocator.free(cwd_target);
    const extra_target = try std.fs.path.join(allocator, &.{ extra_root, "extra.txt" });
    defer allocator.free(extra_target);

    const additional_roots = [_][]const u8{extra_root};
    const profile = try buildProfileWithOptions(allocator, .workspace_write, cwd_root, additional_roots[0..], false, true, &.{});
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "printf ok > {s}; printf nope > {s}",
        .{ extra_target, cwd_target },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/bin/sh", "-c", script };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    });
    try extra_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "extra.txt", .{});
    try std.testing.expectError(error.FileNotFound, cwd_dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "cwd.txt", .{}));
}
