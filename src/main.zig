const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const exec = @import("exec.zig");
const git_diff = @import("git_diff.zig");
const login = @import("login.zig");
const sandbox = @import("sandbox.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var profile_override: ?[]const u8 = null;
    var cmd_opt: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            profile_override = args.next() orelse return error.MissingProfileOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            profile_override = arg["--profile=".len..];
            continue;
        }
        cmd_opt = arg;
        break;
    }

    if (cmd_opt) |cmd| {
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            try printHelp();
            return;
        }
        if (std.mem.eql(u8, cmd, "auth-status")) {
            try runAuthStatus(allocator, profile_override);
            return;
        }
        if (std.mem.eql(u8, cmd, "login")) {
            try login.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "logout")) {
            try login.runLogout(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "exec")) {
            try exec.runWithOptions(allocator, &args, .{ .profile = profile_override });
            return;
        }
        if (std.mem.eql(u8, cmd, "resume")) {
            const target = args.next();
            if (target) |value| {
                if (std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h")) {
                    printResumeHelp();
                    return;
                }
                if (std.mem.eql(u8, value, "--last")) {
                    try tui.runWithOptions(allocator, .{ .resume_target = "last", .profile = profile_override });
                    return;
                }
                try tui.runWithOptions(allocator, .{ .resume_target = value, .profile = profile_override });
            } else {
                try tui.runWithOptions(allocator, .{ .resume_picker = true, .profile = profile_override });
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "sessions")) {
            try runSessions(allocator, args.next(), profile_override);
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
        if (std.mem.eql(u8, cmd, "mock-policy-demo")) {
            try runMockPolicyDemo(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-sandbox-demo")) {
            try runMockSandboxDemo(allocator);
            return;
        }
        std.debug.print("unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return error.UnknownCommand;
    }

    try tui.runWithOptions(allocator, .{ .profile = profile_override });
}

fn printHelp() !void {
    std.debug.print(
        \\Codex Zig
        \\
        \\Usage:
        \\  codex-zig              Start interactive TUI
        \\  codex-zig resume       Pick a saved Zig session to resume
        \\  codex-zig resume --last
        \\                          Resume the latest saved Zig session
        \\  codex-zig resume ID|PATH|last
        \\                          Start interactive TUI from a saved session
        \\  codex-zig sessions [N] List saved Zig sessions
        \\  codex-zig exec PROMPT  Run one non-interactive turn
        \\  codex-zig login        Sign in with ChatGPT device auth
        \\  codex-zig login status Show login status
        \\  codex-zig logout       Remove local Codex auth
        \\  codex-zig auth-status  Check local Codex auth reuse
        \\  codex-zig --profile NAME ...
        \\                          Select a config profile for the command
        \\  codex-zig mock-demo    Run deterministic local tool demo
        \\  codex-zig mock-apply-patch
        \\                          Run deterministic apply_patch demo
        \\  codex-zig mock-policy-demo
        \\                          Run deterministic approval/sandbox demo
        \\  codex-zig mock-sandbox-demo
        \\                          Run deterministic macOS sandbox demo
        \\
        \\Environment:
        \\  CODEX_HOME             Override Codex home (default: ~/.codex)
        \\  CODEX_ZIG_MODEL        Override model
        \\  CODEX_ZIG_BASE_URL     Override API base URL
        \\  CODEX_ZIG_APPROVAL_POLICY
        \\                         Override approval policy
        \\  CODEX_ZIG_SANDBOX_MODE Override sandbox mode
        \\
    , .{});
}

fn printResumeHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig resume
        \\  codex-zig resume --last
        \\  codex-zig resume ID|PATH|last
        \\
        \\Without a target, opens a numbered picker for saved Zig sessions.
        \\
    , .{});
}

fn runSessions(allocator: std.mem.Allocator, limit_arg: ?[]const u8, profile: ?[]const u8) !void {
    const limit = if (limit_arg) |value| try std.fmt.parseUnsigned(usize, value, 10) else 10;
    var cfg = try config.loadWithOptions(allocator, .{ .profile = profile });
    defer cfg.deinit(allocator);

    try session_store.printSessionList(allocator, cfg.codex_home, limit);
}

fn runAuthStatus(allocator: std.mem.Allocator, profile: ?[]const u8) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = profile });
    defer cfg.deinit(allocator);
    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    std.debug.print("codex_home: {s}\n", .{cfg.codex_home});
    std.debug.print("active_profile: {s}\n", .{cfg.active_profile orelse "<none>"});
    std.debug.print("model: {s}\n", .{cfg.model});
    std.debug.print("auth: {s}\n", .{credentials.describe()});
    std.debug.print("approval_policy: {s}\n", .{cfg.approval_policy.label()});
    std.debug.print("sandbox_mode: {s}\n", .{cfg.sandbox_mode.label()});
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
    const result = try tools.runFunctionCall(allocator, call, .{ .auto_approve = true });
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
    const result = try tools.runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);

    std.debug.print("tool: {s}\n", .{result.summary});
    std.debug.print("output: {s}\n", .{result.output});

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), demo_file, allocator, .limited(1024));
    defer allocator.free(content);
    if (!std.mem.eql(u8, content, "zig-apply-patch-ok\n")) {
        return error.MockApplyPatchFileMismatch;
    }
}

fn runMockPolicyDemo(allocator: std.mem.Allocator) !void {
    const blocked_file = "codex_zig_policy_blocked.txt";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), blocked_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const read_call = api.FunctionCall{
        .call_id = "call_mock_read_policy",
        .name = "shell_command",
        .arguments = "{\"command\":\"pwd\"}",
    };
    const read_result = try tools.runFunctionCall(allocator, read_call, .{
        .approval_policy = .untrusted,
        .sandbox_mode = .read_only,
        .prompt_for_approval = false,
    });
    defer read_result.deinit(allocator);
    if (!std.mem.startsWith(u8, read_result.summary, "exit ")) return error.MockPolicyReadMismatch;

    const write_call = api.FunctionCall{
        .call_id = "call_mock_write_policy",
        .name = "apply_patch",
        .arguments =
        \\{"patch":"*** Begin Patch\n*** Add File: codex_zig_policy_blocked.txt\n+should-not-write\n*** End Patch"}
        ,
    };
    const write_result = try tools.runFunctionCall(allocator, write_call, .{
        .approval_policy = .on_failure,
        .sandbox_mode = .read_only,
        .auto_approve = true,
    });
    defer write_result.deinit(allocator);
    if (!std.mem.eql(u8, write_result.summary, "blocked by sandbox")) return error.MockPolicyWriteMismatch;
    if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), blocked_file, allocator, .limited(1024))) |bytes| {
        defer allocator.free(bytes);
        return error.MockPolicyBlockedFileCreated;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    std.debug.print("read: {s}\n", .{read_result.summary});
    std.debug.print("write: {s}\n", .{write_result.summary});
    std.debug.print("policy: ok\n", .{});
}

fn runMockSandboxDemo(allocator: std.mem.Allocator) !void {
    const allowed_file = "codex_zig_sandbox_allowed.txt";
    const blocked_file = "/tmp/codex_zig_sandbox_blocked.txt";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, allowed_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(io, blocked_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const call = api.FunctionCall{
        .call_id = "call_mock_sandbox",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf workspace-ok > codex_zig_sandbox_allowed.txt; printf outside > /tmp/codex_zig_sandbox_blocked.txt\"}",
    };
    const result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = .never,
        .sandbox_mode = .workspace_write,
        .auto_approve = true,
    });
    defer result.deinit(allocator);

    if (std.mem.eql(u8, result.summary, "exit 0")) return error.MockSandboxOutsideWriteAllowed;

    const allowed = try std.Io.Dir.cwd().readFileAlloc(io, allowed_file, allocator, .limited(1024));
    defer allocator.free(allowed);
    if (!std.mem.eql(u8, allowed, "workspace-ok")) return error.MockSandboxAllowedWriteMismatch;

    if (std.Io.Dir.cwd().readFileAlloc(io, blocked_file, allocator, .limited(1024))) |blocked| {
        defer allocator.free(blocked);
        return error.MockSandboxBlockedFileCreated;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.debug.print("sandbox: {s}\n", .{result.summary});
    std.debug.print("workspace-write: ok\n", .{});
    std.debug.print("outside-write: blocked\n", .{});
}

test {
    _ = api;
    _ = auth;
    _ = config;
    _ = env;
    _ = exec;
    _ = git_diff;
    _ = login;
    _ = sandbox;
    _ = session;
    _ = session_store;
    _ = tools;
    _ = tui;
}
