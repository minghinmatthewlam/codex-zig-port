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

pub fn runFunctionCall(allocator: std.mem.Allocator, call: api.FunctionCall, auto_approve: bool) !ToolResult {
    if (std.mem.eql(u8, call.name, "shell_command")) {
        var parsed = try std.json.parseFromSlice(ShellCommandArgs, allocator, call.arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!auto_approve and !try confirm(parsed.value.command)) {
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
        if (!auto_approve and !try confirm(command)) {
            return rejected(allocator, call.call_id);
        }
        return runArgv(allocator, call.call_id, parsed.value.command);
    }

    return .{
        .call_id = try allocator.dupe(u8, call.call_id),
        .summary = try allocator.dupe(u8, "unsupported tool"),
        .output = try std.fmt.allocPrint(allocator, "unsupported tool: {s}", .{call.name}),
    };
}

fn confirm(command: []const u8) !bool {
    std.debug.print("\nTool approval required\n  command: {s}\nRun this command? [y/N] ", .{command});
    var buffer: [16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return false;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

fn rejected(allocator: std.mem.Allocator, call_id: []const u8) !ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, call_id),
        .summary = try allocator.dupe(u8, "rejected"),
        .output = try allocator.dupe(u8, "user rejected command execution"),
    };
}

fn runShellCommand(allocator: std.mem.Allocator, call_id: []const u8, command: []const u8) !ToolResult {
    const argv = [_][]const u8{ "/bin/zsh", "-lc", command };
    return runArgv(allocator, call_id, argv[0..]);
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
