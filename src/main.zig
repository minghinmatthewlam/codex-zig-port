const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const exec = @import("exec.zig");
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
        if (std.mem.eql(u8, cmd, "exec")) {
            try exec.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-demo")) {
            try runMockDemo(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-apply-patch")) {
            try runMockApplyPatch(allocator);
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
        \\  codex-zig exec PROMPT  Run one non-interactive turn
        \\  codex-zig auth-status  Check local Codex auth reuse
        \\  codex-zig mock-demo    Run deterministic local tool demo
        \\  codex-zig mock-apply-patch
        \\                          Run deterministic apply_patch demo
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
    std.debug.print("api_base_url: {s}\n", .{switch (credentials.mode) {
        .chatgpt => cfg.chatgpt_base_url,
        .api_key => cfg.openai_base_url,
    }});
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

fn runMockApplyPatch(allocator: std.mem.Allocator) !void {
    const demo_file = "codex_zig_apply_patch_demo.txt";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), demo_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const call = api.FunctionCall{
        .call_id = "call_mock_apply_patch",
        .name = "apply_patch",
        .arguments =
        \\{"patch":"*** Begin Patch\n*** Add File: codex_zig_apply_patch_demo.txt\n+zig-apply-patch-ok\n*** End Patch"}
        ,
    };
    const result = try tools.runFunctionCall(allocator, call, true);
    defer result.deinit(allocator);

    std.debug.print("tool: {s}\n", .{result.summary});
    std.debug.print("output: {s}\n", .{result.output});

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), demo_file, allocator, .limited(1024));
    defer allocator.free(content);
    if (!std.mem.eql(u8, content, "zig-apply-patch-ok\n")) {
        return error.MockApplyPatchFileMismatch;
    }
}

test {
    _ = api;
    _ = auth;
    _ = config;
    _ = env;
    _ = exec;
    _ = session;
    _ = tools;
    _ = tui;
}
