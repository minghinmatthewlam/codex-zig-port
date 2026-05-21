const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");

const sandbox_exec_path = "/usr/bin/sandbox-exec";
pub const codex_sandbox_env_var = "CODEX_SANDBOX";
pub const seatbelt_env_value = "seatbelt";

pub const SandboxedArgv = struct {
    argv: []const []const u8,
    profile: []const u8,
    owned_args: []const []const u8 = &.{},

    pub fn deinit(self: *const SandboxedArgv, allocator: std.mem.Allocator) void {
        for (self.owned_args) |arg| allocator.free(arg);
        if (self.owned_args.len > 0) allocator.free(self.owned_args);
        allocator.free(self.argv);
        allocator.free(self.profile);
    }
};

pub const WrapOptions = struct {
    cwd_override: ?[]const u8 = null,
    include_cwd_write_root: bool = true,
    include_platform_defaults: bool = false,
    network_enabled: bool = true,
    readable_roots: []const []const u8 = &.{},
    read_denied_roots: []const []const u8 = &.{},
    read_denied_globs: []const []const u8 = &.{},
    allow_unix_sockets: []const []const u8 = &.{},
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
    defer freeResolvedPaths(allocator, resolved_roots);

    const resolved_readable_roots = try resolveReadableRoots(allocator, cwd, options.readable_roots);
    defer freeResolvedPaths(allocator, resolved_readable_roots);
    const resolved_read_denied_roots = try resolveReadDeniedRoots(allocator, cwd, options.read_denied_roots);
    defer freeResolvedPaths(allocator, resolved_read_denied_roots);
    const resolved_read_denied_globs = try resolveReadDeniedGlobPatterns(allocator, cwd, options.read_denied_globs);
    defer freeResolvedPaths(allocator, resolved_read_denied_globs);
    const resolved_unix_sockets = try resolveUnixSocketPaths(allocator, options.allow_unix_sockets);
    defer freeResolvedPaths(allocator, resolved_unix_sockets);

    const profile = try buildProfileWithOptions(
        allocator,
        mode,
        cwd,
        resolved_roots,
        resolved_readable_roots,
        options.include_cwd_write_root,
        options.include_platform_defaults,
        options.network_enabled,
        resolved_read_denied_roots,
        resolved_read_denied_globs,
        resolved_unix_sockets.len,
    );
    errdefer allocator.free(profile);

    const definition_args = try unixSocketDefinitionArgs(allocator, resolved_unix_sockets);
    errdefer freeOwnedArgs(allocator, definition_args);

    var wrapped = try allocator.alloc([]const u8, argv.len + 4 + definition_args.len);
    errdefer allocator.free(wrapped);
    wrapped[0] = sandbox_exec_path;
    wrapped[1] = "-p";
    wrapped[2] = profile;
    @memcpy(wrapped[3 .. 3 + definition_args.len], definition_args);
    const command_separator_index = 3 + definition_args.len;
    wrapped[command_separator_index] = "--";
    @memcpy(wrapped[command_separator_index + 1 ..], argv);

    return .{ .argv = wrapped, .profile = profile, .owned_args = definition_args };
}

fn buildProfile(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
) ![]const u8 {
    return buildProfileWithOptions(allocator, mode, cwd, additional_writable_roots, &.{}, true, false, true, &.{}, &.{}, 0);
}

fn buildProfileWithOptions(
    allocator: std.mem.Allocator,
    mode: config.SandboxMode,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
    readable_roots: []const []const u8,
    include_cwd_write_root: bool,
    include_platform_defaults: bool,
    network_enabled: bool,
    read_denied_roots: []const []const u8,
    read_denied_globs: []const []const u8,
    unix_socket_path_count: usize,
) ![]const u8 {
    return switch (mode) {
        .danger_full_access => error.SandboxNotNeeded,
        .read_only => if (readable_roots.len > 0 or include_platform_defaults)
            buildRestrictedReadOnlyProfile(allocator, readable_roots, include_platform_defaults, network_enabled, read_denied_roots, read_denied_globs, unix_socket_path_count)
        else
            buildReadOnlyProfile(allocator, network_enabled, read_denied_roots, read_denied_globs, unix_socket_path_count),
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
            const writable_roots = try workspaceWriteRootsForGlobExceptions(allocator, cwd, additional_writable_roots, include_cwd_write_root);
            defer allocator.free(writable_roots);
            try appendReadDeniedGlobPatterns(allocator, &profile, read_denied_globs, writable_roots, read_denied_roots);
            try appendReadDeniedRoots(allocator, &profile, read_denied_roots);
            try appendNetworkPolicy(allocator, &profile, network_enabled);
            try appendUnixSocketPolicy(allocator, &profile, unix_socket_path_count);
            break :blk try profile.toOwnedSlice(allocator);
        },
    };
}

fn buildReadOnlyProfile(
    allocator: std.mem.Allocator,
    network_enabled: bool,
    read_denied_roots: []const []const u8,
    read_denied_globs: []const []const u8,
    unix_socket_path_count: usize,
) ![]const u8 {
    var profile = std.ArrayList(u8).empty;
    errdefer profile.deinit(allocator);
    try profile.appendSlice(allocator, baseProfile);
    try profile.appendSlice(allocator, readOnlyWritePolicy);
    try appendReadDeniedRoots(allocator, &profile, read_denied_roots);
    try appendReadDeniedGlobPatterns(allocator, &profile, read_denied_globs, &.{}, read_denied_roots);
    try appendNetworkPolicy(allocator, &profile, network_enabled);
    try appendUnixSocketPolicy(allocator, &profile, unix_socket_path_count);
    return profile.toOwnedSlice(allocator);
}

fn buildRestrictedReadOnlyProfile(
    allocator: std.mem.Allocator,
    readable_roots: []const []const u8,
    include_platform_defaults: bool,
    network_enabled: bool,
    read_denied_roots: []const []const u8,
    read_denied_globs: []const []const u8,
    unix_socket_path_count: usize,
) ![]const u8 {
    var profile = std.ArrayList(u8).empty;
    errdefer profile.deinit(allocator);
    try profile.appendSlice(allocator, restrictedBaseProfile);
    try profile.append(allocator, '\n');
    try profile.appendSlice(allocator, "; allow read-only file operations\n");
    for (readable_roots) |root| {
        try appendReadableSubpath(allocator, &profile, root, read_denied_roots);
    }
    try appendRestrictedNetworkPolicy(allocator, &profile, network_enabled);
    try appendUnixSocketPolicy(allocator, &profile, unix_socket_path_count);
    if (include_platform_defaults) {
        try profile.append(allocator, '\n');
        try profile.appendSlice(allocator, restrictedReadOnlyPlatformDefaults);
    }
    try appendRestrictedReadDeniedRoots(allocator, &profile, read_denied_roots, readable_roots);
    try appendReadDeniedGlobPatterns(allocator, &profile, read_denied_globs, &.{}, read_denied_roots);
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

fn appendRestrictedNetworkPolicy(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    network_enabled: bool,
) !void {
    if (!network_enabled) return;
    try profile.appendSlice(allocator,
        \\(allow network-outbound)
        \\(allow network-inbound)
        \\
    );
}

fn appendUnixSocketPolicy(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    path_count: usize,
) !void {
    if (path_count == 0) return;
    try profile.appendSlice(allocator, "(allow system-socket (socket-domain AF_UNIX))\n");
    for (0..path_count) |index| {
        const block = try std.fmt.allocPrint(
            allocator,
            \\(allow network-bind (local unix-socket (subpath (param "UNIX_SOCKET_PATH_{d}"))))
            \\(allow network-outbound (remote unix-socket (subpath (param "UNIX_SOCKET_PATH_{d}"))))
            \\
        ,
            .{ index, index },
        );
        defer allocator.free(block);
        try profile.appendSlice(allocator, block);
    }
}

pub fn resolveUnixSocketPathsAgainst(
    allocator: std.mem.Allocator,
    base_cwd: []const u8,
    paths: []const []const u8,
) ![]const []const u8 {
    var resolved = std.ArrayList([]const u8).empty;
    var moved = false;
    errdefer if (!moved) {
        for (resolved.items) |path| allocator.free(path);
        resolved.deinit(allocator);
    };

    for (paths) |path| {
        const absolute = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ base_cwd, path });
        defer allocator.free(absolute);

        const normalized = realPathAlloc(allocator, absolute) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => try canonicalMissingPath(allocator, absolute),
            else => return err,
        };
        try appendUniqueOwnedPath(allocator, &resolved, normalized);
    }

    const items = try resolved.toOwnedSlice(allocator);
    moved = true;
    return items;
}

fn resolveUnixSocketPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ![]const []const u8 {
    const cwd = try realPathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return resolveUnixSocketPathsAgainst(allocator, cwd, paths);
}

fn unixSocketDefinitionArgs(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ![]const []const u8 {
    if (paths.len == 0) return &.{};

    var args = try allocator.alloc([]const u8, paths.len);
    errdefer allocator.free(args);
    var count: usize = 0;
    errdefer {
        for (args[0..count]) |arg| allocator.free(arg);
    }

    for (paths, 0..) |path, index| {
        args[count] = try std.fmt.allocPrint(allocator, "-DUNIX_SOCKET_PATH_{d}={s}", .{ index, path });
        count += 1;
    }
    return args;
}

fn freeOwnedArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    if (args.len > 0) allocator.free(args);
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

fn resolveReadableRoots(allocator: std.mem.Allocator, base_cwd: []const u8, roots: []const []const u8) ![]const []const u8 {
    return resolveReadDeniedRoots(allocator, base_cwd, roots);
}

pub fn resolveReadDeniedGlobPatterns(allocator: std.mem.Allocator, base_cwd: []const u8, patterns: []const []const u8) ![]const []const u8 {
    var resolved = std.ArrayList([]const u8).empty;
    var moved = false;
    errdefer if (!moved) {
        for (resolved.items) |pattern| allocator.free(pattern);
        resolved.deinit(allocator);
    };

    for (patterns) |pattern| {
        const original = if (std.fs.path.isAbsolute(pattern))
            try allocator.dupe(u8, pattern)
        else
            try std.fs.path.join(allocator, &.{ base_cwd, pattern });
        var original_moved = false;
        errdefer if (!original_moved) allocator.free(original);

        const canonical = try canonicalizeGlobStaticPrefix(allocator, original);
        var canonical_moved = false;
        errdefer if (!canonical_moved) allocator.free(canonical);

        try appendUniqueOwnedPath(allocator, &resolved, original);
        original_moved = true;
        try appendUniqueOwnedPath(allocator, &resolved, canonical);
        canonical_moved = true;
    }

    const items = try resolved.toOwnedSlice(allocator);
    moved = true;
    return items;
}

fn appendUniqueOwnedPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            allocator.free(path);
            return;
        }
    }
    try paths.append(allocator, path);
}

fn canonicalizeGlobStaticPrefix(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    const first_glob = firstGlobCharIndex(pattern) orelse {
        return realPathAlloc(allocator, pattern) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => try canonicalMissingPath(allocator, pattern),
            else => return err,
        };
    };

    const static_prefix = pattern[0..first_glob];
    const prefix_end = if (static_prefix.len > 0 and static_prefix[static_prefix.len - 1] == std.fs.path.sep)
        static_prefix.len - 1
    else
        std.mem.lastIndexOfScalar(u8, static_prefix, std.fs.path.sep) orelse 0;
    if (prefix_end == 0) return allocator.dupe(u8, pattern);

    const prefix = pattern[0..prefix_end];
    const suffix = pattern[prefix_end..];
    const real_prefix = realPathAlloc(allocator, prefix) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => try canonicalMissingPath(allocator, prefix),
        else => return err,
    };
    defer allocator.free(real_prefix);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ real_prefix, suffix });
}

fn firstGlobCharIndex(value: []const u8) ?usize {
    for (value, 0..) |byte, index| {
        if (byte == '*' or byte == '?' or byte == '[' or byte == ']') return index;
    }
    return null;
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

pub fn freeResolvedPaths(allocator: std.mem.Allocator, roots: []const []const u8) void {
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

fn appendReadableSubpath(allocator: std.mem.Allocator, profile: *std.ArrayList(u8), path: []const u8, read_denied_roots: []const []const u8) !void {
    const escaped = try escapeSeatbeltString(allocator, path);
    defer allocator.free(escaped);
    try profile.print(
        allocator,
        "(allow file-read* file-test-existence (require-all (literal \"{s}\")",
        .{escaped},
    );
    try appendReadableSubpathDenyRequirements(allocator, profile, path, read_denied_roots);
    try profile.appendSlice(allocator, "))\n");
    try profile.print(
        allocator,
        "(allow file-read* file-test-existence (require-all (subpath \"{s}\")",
        .{escaped},
    );
    try appendReadableSubpathDenyRequirements(allocator, profile, path, read_denied_roots);
    try profile.appendSlice(allocator, "))\n");
}

fn appendReadableSubpathDenyRequirements(allocator: std.mem.Allocator, profile: *std.ArrayList(u8), readable_root: []const u8, read_denied_roots: []const []const u8) !void {
    for (read_denied_roots) |denied_root| {
        if (!pathWithinRoot(denied_root, readable_root)) continue;
        const escaped = try escapeSeatbeltString(allocator, denied_root);
        defer allocator.free(escaped);
        try profile.print(
            allocator,
            " (require-not (literal \"{s}\")) (require-not (subpath \"{s}\"))",
            .{ escaped, escaped },
        );
    }
}

fn appendRestrictedReadDeniedRoots(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    roots: []const []const u8,
    readable_roots: []const []const u8,
) !void {
    for (roots) |root| {
        if (std.mem.eql(u8, root, std.fs.path.sep_str)) continue;
        const escaped = try escapeSeatbeltString(allocator, root);
        defer allocator.free(escaped);

        try profile.print(allocator, "(deny file-read* (literal \"{s}\"))\n", .{escaped});
        try profile.print(allocator, "(deny file-read* (require-all (subpath \"{s}\")", .{escaped});
        try appendRestrictedReadDenyCarveouts(allocator, profile, root, readable_roots);
        try profile.appendSlice(allocator, "))\n");

        try profile.print(
            allocator,
            \\(deny file-write* (literal "{s}"))
            \\(deny file-write* (subpath "{s}"))
            \\
        ,
            .{ escaped, escaped },
        );
    }
}

fn appendRestrictedReadDenyCarveouts(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    denied_root: []const u8,
    readable_roots: []const []const u8,
) !void {
    for (readable_roots) |readable_root| {
        if (std.mem.eql(u8, readable_root, denied_root)) continue;
        if (!pathWithinRoot(readable_root, denied_root)) continue;
        const escaped = try escapeSeatbeltString(allocator, readable_root);
        defer allocator.free(escaped);
        try profile.print(
            allocator,
            " (require-not (literal \"{s}\")) (require-not (subpath \"{s}\"))",
            .{ escaped, escaped },
        );
    }
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

fn appendReadDeniedGlobPatterns(
    allocator: std.mem.Allocator,
    profile: *std.ArrayList(u8),
    patterns: []const []const u8,
    writable_roots: []const []const u8,
    read_denied_roots: []const []const u8,
) !void {
    for (patterns) |pattern| {
        const regex = try seatbeltRegexForUnreadableGlob(allocator, pattern);
        defer allocator.free(regex);
        const escaped = try escapeSeatbeltRawRegex(allocator, regex);
        defer allocator.free(escaped);
        // Allow overwriting existing glob-denied files only when the glob is wholly
        // inside a writable root and cannot cover a more specific denied root.
        // Directory-entry operations remain blocked.
        const can_allow_data_write = globPatternUnderAnyRoot(pattern, writable_roots) and !globPatternOverlapsAnyRoot(pattern, read_denied_roots);
        const block = if (can_allow_data_write)
            try std.fmt.allocPrint(
                allocator,
                \\(deny file-read* (regex #"{s}"))
                \\(deny file-write* (regex #"{s}"))
                \\(allow file-write-data (regex #"{s}"))
                \\
            ,
                .{ escaped, escaped, escaped },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                \\(deny file-read* (regex #"{s}"))
                \\(deny file-write* (regex #"{s}"))
                \\
            ,
                .{ escaped, escaped },
            );
        defer allocator.free(block);
        try profile.appendSlice(allocator, block);
    }
}

fn workspaceWriteRootsForGlobExceptions(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    additional_writable_roots: []const []const u8,
    include_cwd_write_root: bool,
) ![]const []const u8 {
    const cwd_count: usize = if (include_cwd_write_root) 1 else 0;
    const roots = try allocator.alloc([]const u8, cwd_count + additional_writable_roots.len);
    if (include_cwd_write_root) roots[0] = cwd;
    @memcpy(roots[cwd_count..], additional_writable_roots);
    return roots;
}

fn globPatternUnderAnyRoot(pattern: []const u8, roots: []const []const u8) bool {
    const prefix = globStaticDirectoryPrefix(pattern) orelse return false;
    for (roots) |root| {
        if (pathWithinRoot(prefix, root)) return true;
    }
    return false;
}

pub fn readDeniedGlobUnderRoot(pattern: []const u8, root: []const u8) bool {
    const prefix = globStaticDirectoryPrefix(pattern) orelse return false;
    return pathWithinRoot(prefix, root);
}

fn globPatternOverlapsAnyRoot(pattern: []const u8, roots: []const []const u8) bool {
    const prefix = globStaticDirectoryPrefix(pattern) orelse return roots.len > 0;
    for (roots) |root| {
        if (pathWithinRoot(root, prefix) or pathWithinRoot(prefix, root)) return true;
    }
    return false;
}

pub fn readDeniedGlobOverlapsRoot(pattern: []const u8, root: []const u8) bool {
    const prefix = globStaticDirectoryPrefix(pattern) orelse return true;
    return pathWithinRoot(root, prefix) or pathWithinRoot(prefix, root);
}

fn globStaticDirectoryPrefix(pattern: []const u8) ?[]const u8 {
    const first_glob = firstGlobCharIndex(pattern) orelse return if (pattern.len == 0) null else pattern;
    const static_prefix = pattern[0..first_glob];
    if (static_prefix.len == 0) return null;
    if (static_prefix[static_prefix.len - 1] == std.fs.path.sep) {
        var end = static_prefix.len;
        while (end > 0 and static_prefix[end - 1] == std.fs.path.sep) : (end -= 1) {}
        if (end == 0) return static_prefix[0..1];
        return static_prefix[0..end];
    }
    return std.fs.path.dirname(static_prefix);
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (pathBytesEqual(path, root)) return true;
    if (path.len <= root.len) return false;
    if (!pathStartsWith(path, root)) return false;
    return (root.len > 0 and root[root.len - 1] == std.fs.path.sep) or path[root.len] == std.fs.path.sep;
}

fn pathBytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (builtin.os.tag != .macos) return std.mem.eql(u8, left, right);
    for (left, right) |left_byte, right_byte| {
        if (std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte)) return false;
    }
    return true;
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    if (builtin.os.tag != .macos) return std.mem.startsWith(u8, path, prefix);
    for (path[0..prefix.len], prefix) |path_byte, prefix_byte| {
        if (std.ascii.toLower(path_byte) != std.ascii.toLower(prefix_byte)) return false;
    }
    return true;
}

fn escapeSeatbeltRawRegex(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);

    for (value) |byte| {
        if (byte == '"') try escaped.append(allocator, '\\');
        try escaped.append(allocator, byte);
    }

    return escaped.toOwnedSlice(allocator);
}

fn seatbeltRegexForUnreadableGlob(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var regex = std.ArrayList(u8).empty;
    errdefer regex.deinit(allocator);

    try regex.append(allocator, '^');
    var index: usize = 0;
    var saw_glob = false;
    while (index < pattern.len) {
        const byte = pattern[index];
        switch (byte) {
            '*' => {
                saw_glob = true;
                if (index + 1 < pattern.len and pattern[index + 1] == '*') {
                    index += 2;
                    if (index < pattern.len and pattern[index] == '/') {
                        index += 1;
                        try regex.appendSlice(allocator, "(.*/)?");
                    } else {
                        try regex.appendSlice(allocator, ".*");
                    }
                    continue;
                }
                try regex.appendSlice(allocator, "[^/]*");
                index += 1;
                continue;
            },
            '?' => {
                saw_glob = true;
                try regex.appendSlice(allocator, "[^/]");
            },
            '[' => {
                saw_glob = true;
                const class_start = index;
                appendSeatbeltRegexClass(allocator, &regex, pattern, &index) catch |err| switch (err) {
                    error.InvalidGlobClass => try regex.appendSlice(allocator, "\\["),
                    else => return err,
                };
                if (index != class_start) continue;
            },
            ']' => {
                saw_glob = true;
                try regex.appendSlice(allocator, "\\]");
            },
            else => try appendRegexEscapedByteFolded(allocator, &regex, byte),
        }
        index += 1;
    }
    if (!saw_glob) try regex.appendSlice(allocator, "(/.*)?");
    try regex.append(allocator, '$');
    return regex.toOwnedSlice(allocator);
}

fn appendSeatbeltRegexClass(
    allocator: std.mem.Allocator,
    regex: *std.ArrayList(u8),
    pattern: []const u8,
    index: *usize,
) !void {
    var cursor = index.* + 1;
    var close: ?usize = null;
    while (cursor < pattern.len) : (cursor += 1) {
        if (pattern[cursor] == ']') {
            close = cursor;
            break;
        }
    }
    const end = close orelse return error.InvalidGlobClass;

    try regex.append(allocator, '[');
    var class_index = index.* + 1;
    if (class_index < end) {
        const first = pattern[class_index];
        if (first == '!') {
            try regex.append(allocator, '^');
            class_index += 1;
        } else if (first == '^') {
            try regex.appendSlice(allocator, "\\^");
            class_index += 1;
        }
    }
    while (class_index < end) : (class_index += 1) {
        const byte = pattern[class_index];
        if (class_index + 2 < end and pattern[class_index + 1] == '-') {
            try appendSeatbeltRegexClassRange(allocator, regex, byte, pattern[class_index + 2]);
            class_index += 2;
        } else if (byte == '\\') {
            try regex.appendSlice(allocator, "\\\\");
        } else {
            try appendSeatbeltRegexClassByteFolded(allocator, regex, byte);
        }
    }
    try regex.append(allocator, ']');
    index.* = end + 1;
}

fn appendSeatbeltRegexClassRange(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), start: u8, end: u8) !void {
    if (builtin.os.tag == .macos and (std.ascii.isAlphabetic(start) or std.ascii.isAlphabetic(end))) {
        const lower_start = std.ascii.toLower(start);
        const lower_end = std.ascii.toLower(end);
        const lo = @min(lower_start, lower_end);
        const hi = @max(lower_start, lower_end);
        try appendSeatbeltRegexClassRangeRaw(allocator, regex, lo, hi);
        try appendSeatbeltRegexClassRangeRaw(allocator, regex, std.ascii.toUpper(lo), std.ascii.toUpper(hi));
        return;
    }

    try appendSeatbeltRegexClassRangeRaw(allocator, regex, start, end);
}

fn appendSeatbeltRegexClassRangeRaw(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), start: u8, end: u8) !void {
    try appendSeatbeltRegexClassByteRaw(allocator, regex, start);
    try regex.append(allocator, '-');
    try appendSeatbeltRegexClassByteRaw(allocator, regex, end);
}

fn appendSeatbeltRegexClassByteFolded(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), byte: u8) !void {
    if (builtin.os.tag == .macos and std.ascii.isAlphabetic(byte)) {
        try appendSeatbeltRegexClassByteRaw(allocator, regex, std.ascii.toLower(byte));
        try appendSeatbeltRegexClassByteRaw(allocator, regex, std.ascii.toUpper(byte));
        return;
    }

    try appendSeatbeltRegexClassByteRaw(allocator, regex, byte);
}

fn appendSeatbeltRegexClassByteRaw(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '\\', '^', ']' => {
            try regex.append(allocator, '\\');
            try regex.append(allocator, byte);
        },
        else => try regex.append(allocator, byte),
    }
}

fn appendRegexEscapedByte(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '.', '+', '(', ')', '{', '}', '^', '$', '|', '\\' => {
            try regex.append(allocator, '\\');
            try regex.append(allocator, byte);
        },
        else => try regex.append(allocator, byte),
    }
}

fn appendRegexEscapedByteFolded(allocator: std.mem.Allocator, regex: *std.ArrayList(u8), byte: u8) !void {
    if (builtin.os.tag == .macos and std.ascii.isAlphabetic(byte)) {
        try regex.append(allocator, '[');
        try regex.append(allocator, std.ascii.toLower(byte));
        try regex.append(allocator, std.ascii.toUpper(byte));
        try regex.append(allocator, ']');
        return;
    }

    try appendRegexEscapedByte(allocator, regex, byte);
}

fn profileGlobRuleNeedle(allocator: std.mem.Allocator, effect: []const u8, pattern: []const u8) ![]const u8 {
    const regex = try seatbeltRegexForUnreadableGlob(allocator, pattern);
    defer allocator.free(regex);
    const escaped = try escapeSeatbeltRawRegex(allocator, regex);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "({s} (regex #\"{s}\"))", .{ effect, escaped });
}

fn expectProfileGlobRule(profile: []const u8, effect: []const u8, pattern: []const u8) !void {
    const allocator = std.testing.allocator;
    const needle = try profileGlobRuleNeedle(allocator, effect, pattern);
    defer allocator.free(needle);
    try std.testing.expect(std.mem.indexOf(u8, profile, needle) != null);
}

fn expectProfileOmitsGlobRule(profile: []const u8, effect: []const u8, pattern: []const u8) !void {
    const allocator = std.testing.allocator;
    const needle = try profileGlobRuleNeedle(allocator, effect, pattern);
    defer allocator.free(needle);
    try std.testing.expect(std.mem.indexOf(u8, profile, needle) == null);
}

pub fn readDeniedGlobMatchesPath(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return false;
    if (firstGlobCharIndex(pattern) == null) return pathWithinRoot(path, pattern);
    return readDeniedGlobMatchesPathAt(pattern, 0, path, 0);
}

fn readDeniedGlobMatchesPathAt(pattern: []const u8, pattern_index: usize, path: []const u8, path_index: usize) bool {
    if (pattern_index == pattern.len) return path_index == path.len;
    if (pattern_index > pattern.len) return false;

    switch (pattern[pattern_index]) {
        '*' => {
            if (pattern_index + 1 < pattern.len and pattern[pattern_index + 1] == '*') {
                const next_pattern_index = pattern_index + 2;
                if (next_pattern_index < pattern.len and pattern[next_pattern_index] == '/') {
                    const after_globstar_slash = next_pattern_index + 1;
                    if (readDeniedGlobMatchesPathAt(pattern, after_globstar_slash, path, path_index)) return true;
                    var cursor = path_index;
                    while (cursor < path.len) : (cursor += 1) {
                        if (path[cursor] == '/' and readDeniedGlobMatchesPathAt(pattern, after_globstar_slash, path, cursor + 1)) return true;
                    }
                    return false;
                }

                var cursor = path_index;
                while (cursor <= path.len) : (cursor += 1) {
                    if (readDeniedGlobMatchesPathAt(pattern, next_pattern_index, path, cursor)) return true;
                    if (cursor == path.len) break;
                }
                return false;
            }

            if (readDeniedGlobMatchesPathAt(pattern, pattern_index + 1, path, path_index)) return true;
            var cursor = path_index;
            while (cursor < path.len and path[cursor] != '/') : (cursor += 1) {
                if (readDeniedGlobMatchesPathAt(pattern, pattern_index + 1, path, cursor + 1)) return true;
            }
            return false;
        },
        '?' => {
            if (path_index >= path.len or path[path_index] == '/') return false;
            return readDeniedGlobMatchesPathAt(pattern, pattern_index + 1, path, path_index + 1);
        },
        '[' => {
            const class_end = globClassEnd(pattern, pattern_index) orelse {
                if (path_index >= path.len or !globByteEqual('[', path[path_index])) return false;
                return readDeniedGlobMatchesPathAt(pattern, pattern_index + 1, path, path_index + 1);
            };
            if (path_index >= path.len or path[path_index] == '/') return false;
            if (!globClassMatches(pattern[pattern_index + 1 .. class_end], path[path_index])) return false;
            return readDeniedGlobMatchesPathAt(pattern, class_end + 1, path, path_index + 1);
        },
        else => |byte| {
            if (path_index >= path.len or !globByteEqual(byte, path[path_index])) return false;
            return readDeniedGlobMatchesPathAt(pattern, pattern_index + 1, path, path_index + 1);
        },
    }
}

fn globClassEnd(pattern: []const u8, start: usize) ?usize {
    var cursor = start + 1;
    while (cursor < pattern.len) : (cursor += 1) {
        if (pattern[cursor] == ']') return cursor;
    }
    return null;
}

fn globClassMatches(class: []const u8, byte: u8) bool {
    var index: usize = 0;
    var negated = false;
    if (index < class.len and class[index] == '!') {
        negated = true;
        index += 1;
    }

    var matched = false;
    while (index < class.len) : (index += 1) {
        const start = class[index];
        if (index + 2 < class.len and class[index + 1] == '-') {
            const end = class[index + 2];
            if (globByteInRange(byte, start, end)) matched = true;
            index += 2;
            continue;
        }
        if (globByteEqual(start, byte)) matched = true;
    }
    return if (negated) !matched else matched;
}

fn globByteInRange(byte: u8, start: u8, end: u8) bool {
    const comparable_byte = globComparableByte(byte);
    const comparable_start = globComparableByte(start);
    const comparable_end = globComparableByte(end);
    if (comparable_start <= comparable_end) {
        return comparable_byte >= comparable_start and comparable_byte <= comparable_end;
    }
    return comparable_byte >= comparable_end and comparable_byte <= comparable_start;
}

fn globByteEqual(left: u8, right: u8) bool {
    if (left == right) return true;
    if (builtin.os.tag == .macos) return std.ascii.toLower(left) == std.ascii.toLower(right);
    return false;
}

fn globComparableByte(byte: u8) u8 {
    return if (builtin.os.tag == .macos) std.ascii.toLower(byte) else byte;
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

const restrictedBaseProfile = @embedFile("seatbelt_base_policy.sbpl");
const restrictedReadOnlyPlatformDefaults = @embedFile("restricted_read_only_platform_defaults.sbpl");

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
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, false, &.{}, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
}

test "sandbox profile can allow unix socket paths" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.createDirPath(io_instance.io(), "socket-root");

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const socket_root = try std.fs.path.join(allocator, &.{ root, "socket-root" });
    defer allocator.free(socket_root);

    const argv = [_][]const u8{ "/bin/echo", "ok" };
    var wrapped = try wrapArgvWithPolicy(allocator, .read_only, argv[0..], &.{}, .{
        .network_enabled = false,
        .allow_unix_sockets = &.{socket_root},
    });
    defer wrapped.deinit(allocator);

    const expected_definition = try std.fmt.allocPrint(allocator, "-DUNIX_SOCKET_PATH_0={s}", .{socket_root});
    defer allocator.free(expected_definition);

    try std.testing.expectEqualStrings(expected_definition, wrapped.argv[3]);
    try std.testing.expectEqualStrings("--", wrapped.argv[4]);
    try std.testing.expectEqualStrings("/bin/echo", wrapped.argv[5]);
    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, "(allow system-socket (socket-domain AF_UNIX))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, "(allow network-bind (local unix-socket (subpath (param \"UNIX_SOCKET_PATH_0\"))))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, "(allow network-outbound (remote unix-socket (subpath (param \"UNIX_SOCKET_PATH_0\"))))") != null);
}

test "relative unix socket paths resolve against provided base cwd" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.createDirPath(io_instance.io(), "socket-root");

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const expected = try std.fs.path.join(allocator, &.{ root, "socket-root" });
    defer allocator.free(expected);

    const resolved = try resolveUnixSocketPathsAgainst(allocator, root, &.{"socket-root"});
    defer freeResolvedPaths(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings(expected, resolved[0]);
}

test "sandbox profile can deny read roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, true, &.{"/tmp/codex-workspace/secret"}, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-read* (literal \"/tmp/codex-workspace/secret\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-write* (subpath \"/tmp/codex-workspace/secret\"))") != null);
}

test "restricted read-only profile allows explicit readable roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .read_only, "/tmp/codex-workspace", &.{}, &.{"/Users/example/repo"}, true, false, false, &.{}, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* file-test-existence (require-all (literal \"/Users/example/repo\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* file-test-existence (require-all (subpath \"/Users/example/repo\")))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read-data (subpath \"/bin\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* file-test-existence file-write* (subpath \"/tmp\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow network-outbound)") == null);
}

test "restricted read-only profile gates platform defaults on minimal read" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .read_only, "/tmp/codex-workspace", &.{}, &.{"/Users/example/repo"}, true, true, false, &.{}, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read-data (subpath \"/bin\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* file-test-existence file-write* (subpath \"/tmp\"))") != null);
}

test "restricted read-only profile applies deny roots after minimal defaults" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .read_only, "/tmp/codex-workspace", &.{}, &.{"/tmp/allowed"}, true, true, false, &.{ "/tmp", "/tmp/secret" }, &.{}, 0);
    defer allocator.free(profile);

    const tmp_default_index = std.mem.indexOf(u8, profile, "(allow file-read* file-test-existence file-write* (subpath \"/tmp\"))").?;
    const tmp_deny_index = std.mem.indexOf(u8, profile, "(deny file-read* (require-all (subpath \"/tmp\") (require-not (literal \"/tmp/allowed\"))").?;
    const secret_deny_index = std.mem.indexOf(u8, profile, "(deny file-read* (require-all (subpath \"/tmp/secret\"))").?;

    try std.testing.expect(tmp_default_index < tmp_deny_index);
    try std.testing.expect(tmp_deny_index < secret_deny_index);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-write* (subpath \"/tmp\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-write* (subpath \"/tmp/secret\"))") != null);
}

test "restricted read-only profile carves denied descendants from readable roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .read_only, "/tmp/codex-workspace", &.{}, &.{"/Users/example/repo"}, true, false, false, &.{ "/", "/Users/example/repo/private" }, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-read* (subpath \"/\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(require-not (literal \"/Users/example/repo/private\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(require-not (subpath \"/Users/example/repo/private\"))") != null);
}

test "restricted read-only profile can enable network access" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .read_only, "/tmp/codex-workspace", &.{}, &.{"/Users/example/repo"}, true, false, true, &.{}, &.{}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow network-outbound)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow network-inbound)") != null);
}

test "restricted read-only sandbox honors explicit readable roots with minimal defaults" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var allowed_dir = std.testing.tmpDir(.{});
    defer allowed_dir.cleanup();
    var blocked_dir = std.testing.tmpDir(.{});
    defer blocked_dir.cleanup();

    try allowed_dir.dir.writeFile(io, .{ .sub_path = "allowed.txt", .data = "allowed" });
    try blocked_dir.dir.writeFile(io, .{ .sub_path = "blocked.txt", .data = "blocked" });

    const allowed_root = try allowed_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(allowed_root);
    const blocked_root = try blocked_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(blocked_root);
    const allowed_file = try std.fs.path.join(allocator, &.{ allowed_root, "allowed.txt" });
    defer allocator.free(allowed_file);
    const blocked_file = try std.fs.path.join(allocator, &.{ blocked_root, "blocked.txt" });
    defer allocator.free(blocked_file);
    const write_target = try std.fs.path.join(allocator, &.{ allowed_root, "write-blocked.txt" });
    defer allocator.free(write_target);

    const profile = try buildProfileWithOptions(
        allocator,
        .read_only,
        allowed_root,
        &.{},
        &.{allowed_root},
        true,
        true,
        false,
        &.{ "/", blocked_root, write_target },
        &.{},
        0,
    );
    defer allocator.free(profile);
    const script = try std.fmt.allocPrint(
        allocator,
        "cat {s}; ! cat {s}; ! printf nope > {s}; printf ok",
        .{ allowed_file, blocked_file, write_target },
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

    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |code| code,
        else => 255,
    });
    try std.testing.expectEqualStrings("allowedok", result.stdout);
    try std.testing.expectError(error.FileNotFound, allowed_dir.dir.access(io, "write-blocked.txt", .{}));
}

test "sandbox profile can deny read glob patterns" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, true, &.{}, &.{"/tmp/codex-workspace/**/*.secret"}, 0);
    defer allocator.free(profile);

    try expectProfileGlobRule(profile, "deny file-read*", "/tmp/codex-workspace/**/*.secret");
    try expectProfileGlobRule(profile, "deny file-write*", "/tmp/codex-workspace/**/*.secret");
    try expectProfileGlobRule(profile, "allow file-write-data", "/tmp/codex-workspace/**/*.secret");
}

test "sandbox profile keeps glob data write allow scoped to writable roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{"/tmp/codex-extra"}, &.{}, false, false, true, &.{}, &.{"/tmp/codex-workspace/**/*.secret"}, 0);
    defer allocator.free(profile);

    try expectProfileGlobRule(profile, "deny file-read*", "/tmp/codex-workspace/**/*.secret");
    try expectProfileGlobRule(profile, "deny file-write*", "/tmp/codex-workspace/**/*.secret");
    try expectProfileOmitsGlobRule(profile, "allow file-write-data", "/tmp/codex-workspace/**/*.secret");
}

test "sandbox profile keeps root slash glob data write allow" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{"/"}, &.{}, false, false, true, &.{}, &.{"/**/*.secret"}, 0);
    defer allocator.free(profile);

    try expectProfileGlobRule(profile, "deny file-read*", "/**/*.secret");
    try expectProfileGlobRule(profile, "deny file-write*", "/**/*.secret");
    try expectProfileGlobRule(profile, "allow file-write-data", "/**/*.secret");
}

test "sandbox profile skips glob data write allow when explicit read root overlaps" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, true, &.{"/tmp/codex-workspace/secret-dir"}, &.{"/tmp/codex-workspace/**/*.secret"}, 0);
    defer allocator.free(profile);

    try expectProfileOmitsGlobRule(profile, "allow file-write-data", "/tmp/codex-workspace/**/*.secret");
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-write* (subpath \"/tmp/codex-workspace/secret-dir\"))") != null);
}

test "sandbox profile keeps literal glob data write allow outside explicit read roots" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, true, &.{"/tmp/codex-workspace/private2"}, &.{"/tmp/codex-workspace/private"}, 0);
    defer allocator.free(profile);

    try expectProfileGlobRule(profile, "allow file-write-data", "/tmp/codex-workspace/private");
}

test "seatbelt glob regex folds ascii literals and classes on macos" {
    const allocator = std.testing.allocator;
    const regex = try seatbeltRegexForUnreadableGlob(allocator, "/tmp/**/[a-c]x[!d].secret");
    defer allocator.free(regex);

    const expected = if (builtin.os.tag == .macos)
        "^/[tT][mM][pP]/(.*/)?[a-cA-C][xX][^dD]\\.[sS][eE][cC][rR][eE][tT]$"
    else
        "^/tmp/(.*/)?[a-c]x[^d]\\.secret$";
    try std.testing.expectEqualStrings(expected, regex);
}

test "seatbelt glob regex keeps trailing hyphen classes valid" {
    const allocator = std.testing.allocator;
    const profile = try buildProfileWithOptions(allocator, .workspace_write, "/tmp/codex-workspace", &.{}, &.{}, true, false, true, &.{}, &.{"/tmp/codex-workspace/**/*[A-Za-z0-9_-].secret"}, 0);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "\\-]") == null);
    if (builtin.os.tag != .macos) return;

    const argv = [_][]const u8{ sandbox_exec_path, "-p", profile, "--", "/usr/bin/true" };
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |code| code,
        else => 255,
    });
}

test "read-denied glob matcher mirrors seatbelt translation" {
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/private", "/tmp/repo/private"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/private", "/tmp/repo/private/token"));
    try std.testing.expect(!readDeniedGlobMatchesPath("/tmp/repo/private", "/tmp/repo/private2/token"));
    try std.testing.expectEqual(builtin.os.tag == .macos, readDeniedGlobMatchesPath("/tmp/repo/Private", "/tmp/repo/private/token"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/**/*.env", "/tmp/repo/.env"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/**/*.env", "/tmp/repo/nested/child.env"));
    try std.testing.expect(!readDeniedGlobMatchesPath("/tmp/repo/**/*.env", "/tmp/repo/nested/child.env.bak"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/*/file[0-9]?.txt", "/tmp/repo/a/file5x.txt"));
    try std.testing.expect(!readDeniedGlobMatchesPath("/tmp/repo/*/file[0-9]?.txt", "/tmp/repo/a/b/file5x.txt"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/[*.env", "/tmp/repo/[file.env"));
    try std.testing.expect(!readDeniedGlobMatchesPath("/tmp/repo/[*.env", "/tmp/repo/file.env"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/[^a].env", "/tmp/repo/^.env"));
    try std.testing.expect(readDeniedGlobMatchesPath("/tmp/repo/[^a].env", "/tmp/repo/a.env"));
    try std.testing.expect(!readDeniedGlobMatchesPath("/tmp/repo/[^a].env", "/tmp/repo/b.env"));
}

test "relative read-denied globs resolve against cwd override" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    try dir.dir.createDirPath(io_instance.io(), "workspace/nested");

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace);

    const argv = [_][]const u8{ "/bin/echo", "ok" };
    var wrapped = try wrapArgvWithPolicy(allocator, .workspace_write, argv[0..], &.{}, .{
        .cwd_override = workspace,
        .read_denied_globs = &.{"**/*.secret"},
    });
    defer wrapped.deinit(allocator);

    const resolved_pattern = try std.fs.path.join(allocator, &.{ workspace, "**/*.secret" });
    defer allocator.free(resolved_pattern);

    try std.testing.expect(std.mem.indexOf(u8, wrapped.profile, "(deny file-read* (regex #\"^") != null);
    try expectProfileGlobRule(wrapped.profile, "deny file-read*", resolved_pattern);
}

test "read-denied glob resolver includes canonicalized static prefix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(io, "target/nested");
    try dir.dir.symLink(io, "target", "alias", .{ .is_directory = true });

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const alias_pattern = try std.fs.path.join(allocator, &.{ root, "alias", "**/*.secret" });
    defer allocator.free(alias_pattern);
    const target_pattern = try std.fs.path.join(allocator, &.{ root, "target", "**/*.secret" });
    defer allocator.free(target_pattern);

    const resolved = try resolveReadDeniedGlobPatterns(allocator, root, &.{alias_pattern});
    defer freeResolvedPaths(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 2), resolved.len);
    try std.testing.expectEqualStrings(alias_pattern, resolved[0]);
    try std.testing.expectEqualStrings(target_pattern, resolved[1]);
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
    const profile = try buildProfileWithOptions(allocator, .workspace_write, cwd_root, additional_roots[0..], &.{}, false, false, true, &.{}, &.{}, 0);
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
