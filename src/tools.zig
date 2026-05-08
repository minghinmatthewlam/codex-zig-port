const std = @import("std");

const api = @import("api.zig");

pub const ToolResult = struct {
    call_id: []const u8,
    summary: []const u8,
    output: []const u8,

    pub fn deinit(self: *const ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.summary);
        allocator.free(self.output);
    }
};

const ShellCommandArgs = struct {
    command: []const u8,
};

const ShellArgs = struct {
    command: []const []const u8,
};

const ApplyPatchArgs = struct {
    patch: []const u8,
};

const PatchStats = struct {
    added: usize = 0,
    updated: usize = 0,
    deleted: usize = 0,
};

pub fn runFunctionCall(allocator: std.mem.Allocator, call: api.FunctionCall, auto_approve: bool) !ToolResult {
    if (std.mem.eql(u8, call.name, "shell_command")) {
        var parsed = try std.json.parseFromSlice(ShellCommandArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!auto_approve and !try confirm("command", parsed.value.command)) {
            return rejected(allocator, call.call_id);
        }
        return runShellCommand(allocator, call.call_id, parsed.value.command);
    }

    if (std.mem.eql(u8, call.name, "shell")) {
        var parsed = try std.json.parseFromSlice(ShellArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.command.len == 0) return error.EmptyShellCommand;
        const command = try joinCommand(allocator, parsed.value.command);
        defer allocator.free(command);
        if (!auto_approve and !try confirm("command", command)) {
            return rejected(allocator, call.call_id);
        }
        return runArgv(allocator, call.call_id, parsed.value.command);
    }

    if (std.mem.eql(u8, call.name, "apply_patch")) {
        var parsed = try std.json.parseFromSlice(ApplyPatchArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!auto_approve and !try confirm("patch", parsed.value.patch)) {
            return rejected(allocator, call.call_id);
        }
        return runApplyPatch(allocator, call.call_id, parsed.value.patch);
    }

    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "unsupported tool"),
        .output = try std.fmt.allocPrint(allocator, "unsupported tool: {s}", .{call.name}),
    };
}

fn confirm(kind: []const u8, detail: []const u8) !bool {
    std.debug.print("\nTool approval required\n  {s}: {s}\nRun this {s}? [y/N] ", .{ kind, detail, kind });
    var buffer: [16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return false;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

pub fn rejected(allocator: std.mem.Allocator, call_id: []const u8) !ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = try allocator.dupe(u8, "rejected"),
        .output = try allocator.dupe(u8, "user rejected tool execution"),
    };
}

fn runShellCommand(allocator: std.mem.Allocator, call_id: []const u8, command: []const u8) !ToolResult {
    const argv = [_][]const u8{ "/bin/zsh", "-lc", command };
    return runArgv(allocator, call_id, argv[0..]);
}

fn runApplyPatch(allocator: std.mem.Allocator, call_id: []const u8, patch: []const u8) !ToolResult {
    const stats = try applyPatchInDir(allocator, std.Io.Dir.cwd(), patch);
    const summary = try std.fmt.allocPrint(
        allocator,
        "patched +{d} ~{d} -{d}",
        .{ stats.added, stats.updated, stats.deleted },
    );
    errdefer allocator.free(summary);

    const output = try std.fmt.allocPrint(
        allocator,
        "applied patch\nadded: {d}\nupdated: {d}\ndeleted: {d}",
        .{ stats.added, stats.updated, stats.deleted },
    );
    errdefer allocator.free(output);

    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = summary,
        .output = output,
    };
}

fn runArgv(allocator: std.mem.Allocator, call_id: []const u8, argv: []const []const u8) !ToolResult {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(30_000),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_summary = switch (result.term) {
        .exited => |code| try std.fmt.allocPrint(allocator, "exit {d}", .{code}),
        .signal => |sig| try std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| try std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(sig)}),
        .unknown => |code| try std.fmt.allocPrint(allocator, "unknown {d}", .{code}),
    };
    errdefer allocator.free(exit_summary);

    const output = try std.fmt.allocPrint(
        allocator,
        "stdout:\n{s}\nstderr:\n{s}",
        .{ result.stdout, result.stderr },
    );
    errdefer allocator.free(output);

    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = exit_summary,
        .output = output,
    };
}

fn joinCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    for (argv, 0..) |part, index| {
        if (index > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, part);
    }
    return list.toOwnedSlice(allocator);
}

fn applyPatchInDir(allocator: std.mem.Allocator, root: std.Io.Dir, patch: []const u8) !PatchStats {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var raw_lines = std.mem.splitScalar(u8, patch, '\n');
    while (raw_lines.next()) |raw_line| {
        try lines.append(allocator, std.mem.trimEnd(u8, raw_line, "\r"));
    }

    if (lines.items.len < 2) return error.InvalidPatch;
    if (!std.mem.eql(u8, patchDirective(lines.items[0]), "*** Begin Patch")) return error.InvalidPatch;

    var stats = PatchStats{};
    var index: usize = 1;
    while (index < lines.items.len) {
        const line = patchDirective(lines.items[index]);
        if (std.mem.eql(u8, line, "*** End Patch")) {
            for (lines.items[index + 1 ..]) |trailing| {
                if (trailing.len != 0) return error.InvalidPatch;
            }
            if (stats.added == 0 and stats.updated == 0 and stats.deleted == 0) return error.InvalidPatch;
            return stats;
        }

        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            const path = line["*** Add File: ".len..];
            try validateRelativePath(path);
            index += 1;
            try addFileFromPatch(allocator, root, path, lines.items, &index);
            stats.added += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            const path = line["*** Update File: ".len..];
            try validateRelativePath(path);
            index += 1;
            try updateFileFromPatch(allocator, root, path, lines.items, &index);
            stats.updated += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Delete File: ")) {
            const path = line["*** Delete File: ".len..];
            try validateRelativePath(path);
            try root.deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
            stats.deleted += 1;
            index += 1;
            continue;
        }

        return error.InvalidPatch;
    }

    return error.InvalidPatch;
}

fn addFileFromPatch(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    lines: []const []const u8,
    index: *usize,
) !void {
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    while (index.* < lines.len and !isPatchSection(lines[index.*])) : (index.* += 1) {
        const line = lines[index.*];
        if (line.len == 0 or line[0] != '+') return error.InvalidPatch;
        try content.appendSlice(allocator, line[1..]);
        try content.append(allocator, '\n');
    }

    try ensureParentDir(root, path);
    try root.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = content.items,
        .flags = .{ .exclusive = true },
    });
}

fn updateFileFromPatch(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    lines: []const []const u8,
    index: *usize,
) !void {
    var target_path = path;
    if (index.* < lines.len) {
        const directive = patchDirective(lines[index.*]);
        if (std.mem.startsWith(u8, directive, "*** Move to: ")) {
            target_path = directive["*** Move to: ".len..];
            try validateRelativePath(target_path);
            index.* += 1;
        }
    }

    var current = try root.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(current);

    var saw_hunk = false;
    while (index.* < lines.len and !isPatchSection(lines[index.*])) {
        const directive = patchDirective(lines[index.*]);
        if (std.mem.eql(u8, directive, "*** End of File")) {
            index.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, directive, "@@")) {
            index.* += 1;
            continue;
        }

        var old = std.ArrayList(u8).empty;
        defer old.deinit(allocator);
        var new = std.ArrayList(u8).empty;
        defer new.deinit(allocator);

        while (index.* < lines.len and !isPatchSection(lines[index.*]) and !isHunkBoundary(lines[index.*])) : (index.* += 1) {
            const line = lines[index.*];
            if (line.len == 0) return error.InvalidPatch;
            switch (line[0]) {
                ' ' => {
                    try old.appendSlice(allocator, line[1..]);
                    try old.append(allocator, '\n');
                    try new.appendSlice(allocator, line[1..]);
                    try new.append(allocator, '\n');
                },
                '-' => {
                    try old.appendSlice(allocator, line[1..]);
                    try old.append(allocator, '\n');
                },
                '+' => {
                    try new.appendSlice(allocator, line[1..]);
                    try new.append(allocator, '\n');
                },
                else => return error.InvalidPatch,
            }
        }

        if (old.items.len == 0 and new.items.len == 0) continue;
        const replaced = if (old.items.len == 0)
            try appendToEnd(allocator, current, new.items)
        else
            try replaceOnce(allocator, current, old.items, new.items);
        allocator.free(current);
        current = replaced;
        saw_hunk = true;
    }

    if (!saw_hunk) return error.InvalidPatch;
    try ensureParentDir(root, target_path);
    try root.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = target_path,
        .data = current,
    });
    if (!std.mem.eql(u8, path, target_path)) {
        try root.deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
    }
}

fn appendToEnd(allocator: std.mem.Allocator, current: []const u8, addition: []const u8) ![]u8 {
    if (addition.len == 0) return error.InvalidPatch;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, current);
    if (current.len > 0 and current[current.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, addition);
    return output.toOwnedSlice(allocator);
}

fn replaceOnce(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return error.InvalidPatch;
    const match = if (std.mem.indexOf(u8, haystack, needle)) |start|
        TextMatch{ .start = start, .end = start + needle.len }
    else
        trailingNewlineMatch(haystack, needle) orelse return error.PatchContextNotFound;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, haystack[0..match.start]);
    try output.appendSlice(allocator, replacement);
    try output.appendSlice(allocator, haystack[match.end..]);
    return output.toOwnedSlice(allocator);
}

fn ensureParentDir(root: std.Io.Dir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try root.createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPatchPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidPatchPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPatchPath;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPatchPath;
        }
    }
}

fn isPatchSection(line: []const u8) bool {
    const directive = patchDirective(line);
    return std.mem.eql(u8, directive, "*** End Patch") or
        std.mem.startsWith(u8, directive, "*** Add File: ") or
        std.mem.startsWith(u8, directive, "*** Update File: ") or
        std.mem.startsWith(u8, directive, "*** Delete File: ");
}

fn isHunkBoundary(line: []const u8) bool {
    const directive = patchDirective(line);
    return std.mem.startsWith(u8, directive, "@@") or std.mem.eql(u8, directive, "*** End of File");
}

fn patchDirective(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t");
}

const TextMatch = struct {
    start: usize,
    end: usize,
};

fn trailingNewlineMatch(haystack: []const u8, needle: []const u8) ?TextMatch {
    if (!std.mem.endsWith(u8, needle, "\n")) return null;
    const trimmed = needle[0 .. needle.len - 1];
    if (trimmed.len == 0) return null;
    if (!std.mem.endsWith(u8, haystack, trimmed)) return null;
    return .{ .start = haystack.len - trimmed.len, .end = haystack.len };
}

test "shell command creates output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const call = api.FunctionCall{
        .call_id = "c1",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf hello\"}",
    };
    const result = try runFunctionCall(allocator, call, true);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "apply_patch adds and updates files" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const add_patch =
        \\*** Begin Patch
        \\*** Add File: docs/demo.txt
        \\+alpha
        \\+beta
        \\*** End Patch
    ;
    const add_stats = try applyPatchInDir(allocator, dir.dir, add_patch);
    try std.testing.expectEqual(@as(usize, 1), add_stats.added);

    const update_patch =
        \\*** Begin Patch
        \\*** Update File: docs/demo.txt
        \\@@
        \\ alpha
        \\-beta
        \\+gamma
        \\*** End Patch
    ;
    const update_stats = try applyPatchInDir(allocator, dir.dir, update_patch);
    try std.testing.expectEqual(@as(usize, 1), update_stats.updated);

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "docs/demo.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("alpha\ngamma\n", content);
}

test "apply_patch deletes files and rejects unsafe paths" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "remove-me.txt",
        .data = "temporary\n",
    });

    const delete_patch =
        \\*** Begin Patch
        \\*** Delete File: remove-me.txt
        \\*** End Patch
    ;
    const delete_stats = try applyPatchInDir(allocator, dir.dir, delete_patch);
    try std.testing.expectEqual(@as(usize, 1), delete_stats.deleted);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "remove-me.txt", .{}));

    const unsafe_patch =
        \\*** Begin Patch
        \\*** Add File: ../escape.txt
        \\+nope
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatchPath, applyPatchInDir(allocator, dir.dir, unsafe_patch));
}

test "apply_patch supports moves and destination overwrite" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "old");
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "renamed/dir");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "old/name.txt",
        .data = "from\n",
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "renamed/dir/name.txt",
        .data = "existing\n",
    });

    const patch =
        \\*** Begin Patch
        \\*** Update File: old/name.txt
        \\*** Move to: renamed/dir/name.txt
        \\@@
        \\-from
        \\+new
        \\*** End Patch
    ;
    const stats = try applyPatchInDir(allocator, dir.dir, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), "old/name.txt", .{}));

    const content = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "renamed/dir/name.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new\n", content);
}

test "apply_patch handles EOF, pure additions, and padded markers" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "tail.txt",
        .data = "first\nsecond\n",
    });
    const eof_patch =
        \\*** Begin Patch
        \\*** Update File: tail.txt
        \\@@
        \\ first
        \\-second
        \\+second updated
        \\*** End of File
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, eof_patch);
    const tail = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "tail.txt", allocator, .limited(1024));
    defer allocator.free(tail);
    try std.testing.expectEqualStrings("first\nsecond updated\n", tail);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "input.txt",
        .data = "line1\nline2\n",
    });
    const addition_patch =
        \\*** Begin Patch
        \\*** Update File: input.txt
        \\@@
        \\+added line 1
        \\+added line 2
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, addition_patch);
    const input = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "input.txt", allocator, .limited(1024));
    defer allocator.free(input);
    try std.testing.expectEqualStrings("line1\nline2\nadded line 1\nadded line 2\n", input);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "no_newline.txt",
        .data = "no newline at end",
    });
    const no_newline_patch =
        \\*** Begin Patch
        \\*** Update File: no_newline.txt
        \\@@
        \\-no newline at end
        \\+first line
        \\+second line
        \\*** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, no_newline_patch);
    const no_newline = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "no_newline.txt", allocator, .limited(1024));
    defer allocator.free(no_newline);
    try std.testing.expectEqualStrings("first line\nsecond line\n", no_newline);

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "padded.txt",
        .data = "one\n",
    });
    const padded_patch =
        \\ *** Begin Patch
        \\  *** Update File: padded.txt
        \\@@
        \\-one
        \\+two
        \\ *** End Patch
    ;
    _ = try applyPatchInDir(allocator, dir.dir, padded_patch);
    const padded = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "padded.txt", allocator, .limited(1024));
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("two\n", padded);
}

test "apply_patch rejects empty patch and trailing content" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const empty_patch =
        \\*** Begin Patch
        \\*** End Patch
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, empty_patch));

    const trailing_patch =
        \\*** Begin Patch
        \\*** Add File: foo.txt
        \\+ok
        \\*** End Patch
        \\extra
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchInDir(allocator, dir.dir, trailing_patch));
}
