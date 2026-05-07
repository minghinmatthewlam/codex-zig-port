const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            try printHelp();
            return;
        }
        if (std.mem.eql(u8, cmd, "auth-status")) {
            try runAuthStatus(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-demo")) {
            try runMockDemo(allocator);
            return;
        }
        std.debug.print("unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return error.UnknownCommand;
    }

    try tui.run(allocator);
}

fn printHelp() !void {
    std.debug.print(
        \\Codex Zig
        \\
        \\Usage:
        \\  codex-zig              Start interactive TUI
        \\  codex-zig auth-status  Check local Codex auth reuse
        \\  codex-zig mock-demo    Run deterministic local tool demo
        \\
        \\Environment:
        \\  CODEX_HOME             Override Codex home (default: ~/.codex)
        \\  CODEX_ZIG_MODEL        Override model
        \\  CODEX_ZIG_BASE_URL     Override API base URL
        \\
    , .{});
}

fn runAuthStatus(allocator: std.mem.Allocator) !void {
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    std.debug.print("codex_home: {s}\n", .{cfg.codex_home});
    std.debug.print("model: {s}\n", .{cfg.model});
    std.debug.print("auth: {s}\n", .{credentials.describe()});
    if (credentials.account_id) |account_id| {
        std.debug.print("chatgpt_account_id: {s}\n", .{account_id});
    }
}

fn runMockDemo(allocator: std.mem.Allocator) !void {
    const call = api.FunctionCall{
        .call_id = "call_mock_shell",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf zig-port-ok > codex_zig_mock_demo.txt\"}",
    };
    const result = try tools.runFunctionCall(allocator, call, true);
    defer result.deinit(allocator);

    std.debug.print("tool: {s}\n", .{result.summary});
    std.debug.print("output: {s}\n", .{result.output});

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "codex_zig_mock_demo.txt", allocator, .limited(1024));
    defer allocator.free(content);
    if (!std.mem.eql(u8, content, "zig-port-ok")) {
        return error.MockDemoFileMismatch;
    }
}

test {
    _ = api;
    _ = auth;
    _ = config;
    _ = env;
    _ = session;
    _ = tools;
    _ = tui;
}
