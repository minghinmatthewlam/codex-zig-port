const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");
const git_diff = @import("git_diff.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

pub const Options = struct {
    resume_target: ?[]const u8 = null,
    resume_picker: bool = false,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    additional_writable_roots: []const []const u8 = &.{},
};

pub fn run(allocator: std.mem.Allocator) !void {
    try runWithOptions(allocator, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var resumed = false;
    var session_path = if (options.resume_picker) blk: {
        const picked_path = try promptResumePicker(allocator, cfg.codex_home);
        if (picked_path == null) {
            std.debug.print("resume canceled\n", .{});
            return;
        }
        resumed = true;
        break :blk picked_path.?;
    } else if (options.resume_target) |target| blk: {
        resumed = true;
        break :blk try session_store.resolveResumePath(allocator, cfg.codex_home, target);
    } else try session_store.createSessionPath(allocator, cfg.codex_home);
    defer allocator.free(session_path);

    if (resumed) {
        const loaded = try session_store.loadTranscript(allocator, session_path);
        transcript.deinit(allocator);
        transcript = loaded;
    }

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    printHeader(cfg, credentials, cwd);
    if (resumed) {
        std.debug.print("resumed: {s} ({d} items)\n", .{ session_path, transcript.history.items.len });
    }

    var input_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

    while (true) {
        std.debug.print("\n› ", .{});
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        const prompt = std.mem.trim(u8, line, " \t\r\n");
        if (prompt.len == 0) continue;
        if (std.mem.eql(u8, prompt, "q")) break;
        const slash_action = handleSlashCommand(allocator, &cfg, credentials, &transcript, &session_path, cwd, prompt) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (slash_action) |action| {
            switch (action) {
                .handled => continue,
                .quit => break,
            }
        }

        std.debug.print("\nassistant:\n", .{});
        const answer = session.runTurnWithOptions(allocator, cfg, credentials, &transcript, prompt, .{
            .stream_text = true,
            .additional_writable_roots = options.additional_writable_roots,
        }) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(answer);
        session_store.saveTranscript(allocator, session_path, &transcript) catch |err| {
            std.debug.print("warning: could not save session: {s}\n", .{@errorName(err)});
        };
        if (answer.len == 0 or answer[answer.len - 1] != '\n') {
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\nbye\n", .{});
}

fn printHeader(cfg: config.Config, credentials: auth.Credentials, cwd: []const u8) void {
    std.debug.print(
        \\╭────────────────────────────────────────────╮
        \\│ Codex Zig                                  │
        \\╰────────────────────────────────────────────╯
        \\model: {s}
        \\auth: {s}
        \\api:  {s}
        \\cwd:  {s}
        \\approval: {s}
        \\sandbox:  {s}
        \\Type /help for commands or /quit to exit.
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt => cfg.chatgpt_base_url,
            .api_key => cfg.openai_base_url,
        },
        cwd,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
    });
}

fn promptResumePicker(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const sessions = try session_store.listSessions(allocator, codex_home, 10);
    defer session_store.freeSessionSummaries(allocator, sessions);

    if (sessions.len == 0) {
        std.debug.print("resume: no saved Zig sessions\n", .{});
        return null;
    }

    std.debug.print("resume sessions:\n", .{});
    for (sessions, 0..) |entry, index| {
        std.debug.print("  {d}. {s}\n     {s}\n", .{ index + 1, entry.id, entry.path });
    }
    std.debug.print("Select session [1-{d}] or press Enter to cancel: ", .{sessions.len});

    var input_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);
    const line_opt = try stdin_reader.interface.takeDelimiter('\n');
    const line = line_opt orelse return null;
    const selection = try parseResumeSelection(line, sessions.len) orelse return null;
    const path = try allocator.dupe(u8, sessions[selection].path);
    return path;
}

fn parseResumeSelection(input: []const u8, count: usize) !?usize {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const selected = try std.fmt.parseUnsigned(usize, trimmed, 10);
    if (selected == 0 or selected > count) return error.InvalidResumeSelection;
    return selected - 1;
}

const SlashAction = enum {
    handled,
    quit,
};

const SlashParts = struct {
    name: []const u8,
    args: []const u8,
};

fn handleSlashCommand(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    credentials: auth.Credentials,
    transcript: *session.Transcript,
    session_path: *[]const u8,
    cwd: []const u8,
    prompt: []const u8,
) !?SlashAction {
    const parts = parseSlash(prompt) orelse return null;

    if (std.ascii.eqlIgnoreCase(parts.name, "quit") or
        std.ascii.eqlIgnoreCase(parts.name, "exit") or
        std.mem.eql(u8, parts.name, "q"))
    {
        return .quit;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "help")) {
        printSlashHelp();
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "status")) {
        printStatus(cfg.*, credentials, transcript, session_path.*, cwd);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "history")) {
        printHistory(transcript, try parseHistoryLimit(parts.args));
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "rollout")) {
        std.debug.print("rollout: {s}\n", .{session_path.*});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sessions")) {
        try session_store.printSessionList(allocator, cfg.codex_home, try parseSessionListLimit(parts.args));
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "diff")) {
        try printDiff(allocator, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "clear") or std.ascii.eqlIgnoreCase(parts.name, "new")) {
        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        transcript.deinit(allocator);
        transcript.* = .{};
        allocator.free(session_path.*);
        session_path.* = next_path;
        if (std.ascii.eqlIgnoreCase(parts.name, "clear")) {
            std.debug.print("\x1b[2J\x1b[H", .{});
            printHeader(cfg.*, credentials, cwd);
        } else {
            std.debug.print("started a new chat\n", .{});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "resume")) {
        const target = if (parts.args.len == 0) null else parts.args;
        const next_path = try session_store.resolveResumePath(allocator, cfg.codex_home, target);
        errdefer allocator.free(next_path);
        var loaded = try session_store.loadTranscript(allocator, next_path);
        errdefer loaded.deinit(allocator);

        transcript.deinit(allocator);
        transcript.* = loaded;
        allocator.free(session_path.*);
        session_path.* = next_path;
        std.debug.print("resumed: {s} ({d} items)\n", .{ session_path.*, transcript.history.items.len });
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "model")) {
        if (parts.args.len == 0) {
            std.debug.print("model: {s}\n", .{cfg.model});
        } else {
            const next_model = try allocator.dupe(u8, parts.args);
            allocator.free(cfg.model);
            cfg.model = next_model;
            std.debug.print("model: {s}\n", .{cfg.model});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "approval")) {
        if (parts.args.len == 0) {
            std.debug.print("approval: {s}\n", .{cfg.approval_policy.label()});
        } else {
            cfg.approval_policy = try config.ApprovalPolicy.parse(parts.args);
            std.debug.print("approval: {s}\n", .{cfg.approval_policy.label()});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "sandbox")) {
        if (parts.args.len == 0) {
            std.debug.print("sandbox: {s}\n", .{cfg.sandbox_mode.label()});
        } else {
            cfg.sandbox_mode = try config.SandboxMode.parse(parts.args);
            std.debug.print("sandbox: {s}\n", .{cfg.sandbox_mode.label()});
        }
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "permissions")) {
        try handlePermissions(cfg, parts.args);
        return .handled;
    }

    std.debug.print("unknown slash command: /{s} (try /help)\n", .{parts.name});
    return .handled;
}

fn parseSlash(prompt: []const u8) ?SlashParts {
    if (prompt.len < 2 or prompt[0] != '/') return null;
    const body = std.mem.trim(u8, prompt[1..], " \t");
    if (body.len == 0) return .{ .name = "", .args = "" };
    const split = std.mem.indexOfAny(u8, body, " \t") orelse return .{ .name = body, .args = "" };
    const name = body[0..split];
    const args = std.mem.trim(u8, body[split + 1 ..], " \t");
    return .{ .name = name, .args = args };
}

fn printSlashHelp() void {
    std.debug.print(
        \\commands:
        \\  /help             show this help
        \\  /status           show current session settings
        \\  /model [name]     show or set the in-memory model for this session
        \\  /permissions      show or set approval/sandbox modes
        \\  /approval [mode]  show or set approval policy
        \\  /sandbox [mode]   show or set sandbox mode
        \\  /history [n]      show recent transcript items
        \\  /rollout          show the active session JSONL path
        \\  /sessions [n]     list saved Zig sessions
        \\  /diff             show git status and diff, including untracked files
        \\  /clear            clear transcript and redraw the header
        \\  /new              start a new transcript
        \\  /resume [target]  resume last, a session id, or a JSONL path
        \\  /quit, /exit      exit
        \\
    , .{});
}

fn printStatus(
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
) void {
    std.debug.print(
        \\status:
        \\  model:       {s}
        \\  auth:        {s}
        \\  api:         {s}
        \\  cwd:         {s}
        \\  session:     {s}
        \\  approval:    {s}
        \\  sandbox:     {s}
        \\  transcript:  {d} items
        \\  tools:       shell, shell_command, apply_patch
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt => cfg.chatgpt_base_url,
            .api_key => cfg.openai_base_url,
        },
        cwd,
        session_path,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        transcript.history.items.len,
    });
}

fn printDiff(allocator: std.mem.Allocator, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len != 0) {
        std.debug.print("usage: /diff\n", .{});
        return;
    }

    const rendered = try git_diff.render(allocator);
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

const PermissionUpdate = union(enum) {
    approval: config.ApprovalPolicy,
    sandbox: config.SandboxMode,
};

fn handlePermissions(cfg: *config.Config, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        printPermissions(cfg.*);
        return;
    }

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (tokens.next()) |token| {
        const update = try parsePermissionUpdate(token);
        switch (update) {
            .approval => |approval_policy| cfg.approval_policy = approval_policy,
            .sandbox => |sandbox_mode| cfg.sandbox_mode = sandbox_mode,
        }
    }

    printPermissions(cfg.*);
}

fn printPermissions(cfg: config.Config) void {
    std.debug.print(
        \\permissions:
        \\  approval: {s}
        \\  sandbox:  {s}
        \\usage: /permissions [approval=<mode>] [sandbox=<mode>]
        \\
    , .{ cfg.approval_policy.label(), cfg.sandbox_mode.label() });
}

fn parsePermissionUpdate(token: []const u8) !PermissionUpdate {
    if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
        const key = token[0..eq];
        const value = token[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "approval")) {
            return .{ .approval = try config.ApprovalPolicy.parse(value) };
        }
        if (std.ascii.eqlIgnoreCase(key, "sandbox")) {
            return .{ .sandbox = try config.SandboxMode.parse(value) };
        }
        return error.InvalidPermissionsArgument;
    }

    if (config.ApprovalPolicy.parse(token)) |approval_policy| {
        return .{ .approval = approval_policy };
    } else |approval_err| switch (approval_err) {
        error.InvalidApprovalPolicy => {},
    }

    if (config.SandboxMode.parse(token)) |sandbox_mode| {
        return .{ .sandbox = sandbox_mode };
    } else |sandbox_err| switch (sandbox_err) {
        error.InvalidSandboxMode => {},
    }

    return error.InvalidPermissionsArgument;
}

fn printHistory(transcript: *const session.Transcript, limit: usize) void {
    const total = transcript.history.items.len;
    const start = if (limit == 0 or limit >= total) 0 else total - limit;
    std.debug.print("history: showing {d} of {d} items\n", .{ total - start, total });
    if (total == 0) {
        std.debug.print("  <empty>\n", .{});
        return;
    }

    for (transcript.history.items[start..], start..) |item, index| {
        std.debug.print("\n#{d} ", .{index + 1});
        switch (item.kind) {
            .message => {
                const role = item.role orelse "message";
                const text = item.text orelse "";
                std.debug.print("{s}:\n", .{role});
                printIndented(text, 1200);
            },
            .function_call => {
                std.debug.print("tool call: {s}\n", .{item.name orelse "unknown"});
                printIndented(item.arguments orelse "", 800);
            },
            .function_call_output => {
                std.debug.print("tool output: {s}\n", .{item.call_id orelse "unknown"});
                printIndented(item.output orelse "", 800);
            },
        }
    }
}

fn printIndented(text: []const u8, max_bytes: usize) void {
    const shown = text[0..@min(text.len, max_bytes)];
    if (shown.len == 0) {
        std.debug.print("  <empty>\n", .{});
    } else {
        var lines = std.mem.splitScalar(u8, shown, '\n');
        while (lines.next()) |line| {
            std.debug.print("  {s}\n", .{line});
        }
    }
    if (text.len > shown.len) {
        std.debug.print("  ... truncated {d} bytes\n", .{text.len - shown.len});
    }
}

fn parseHistoryLimit(args: []const u8) !usize {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return 20;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

fn parseSessionListLimit(args: []const u8) !usize {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return 10;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

test "parse slash command names and args" {
    const status = parseSlash("/status").?;
    try std.testing.expectEqualStrings("status", status.name);
    try std.testing.expectEqualStrings("", status.args);

    const model = parseSlash("/model gpt-test").?;
    try std.testing.expectEqualStrings("model", model.name);
    try std.testing.expectEqualStrings("gpt-test", model.args);

    const approval = parseSlash("/approval on-request").?;
    try std.testing.expectEqualStrings("approval", approval.name);
    try std.testing.expectEqualStrings("on-request", approval.args);

    const permissions = parseSlash("/permissions sandbox=read-only").?;
    try std.testing.expectEqualStrings("permissions", permissions.name);
    try std.testing.expectEqualStrings("sandbox=read-only", permissions.args);

    const history = parseSlash("/history 5").?;
    try std.testing.expectEqualStrings("history", history.name);
    try std.testing.expectEqualStrings("5", history.args);

    const rollout = parseSlash("/rollout").?;
    try std.testing.expectEqualStrings("rollout", rollout.name);
    try std.testing.expectEqualStrings("", rollout.args);

    const sessions = parseSlash("/sessions 2").?;
    try std.testing.expectEqualStrings("sessions", sessions.name);
    try std.testing.expectEqualStrings("2", sessions.args);

    const diff = parseSlash("/diff").?;
    try std.testing.expectEqualStrings("diff", diff.name);
    try std.testing.expectEqualStrings("", diff.args);

    try std.testing.expect(parseSlash("hello") == null);
}

test "parse history limit" {
    try std.testing.expectEqual(@as(usize, 20), try parseHistoryLimit(""));
    try std.testing.expectEqual(@as(usize, 3), try parseHistoryLimit(" 3 "));
    try std.testing.expectError(error.InvalidCharacter, parseHistoryLimit("abc"));

    try std.testing.expectEqual(@as(usize, 10), try parseSessionListLimit(""));
    try std.testing.expectEqual(@as(usize, 2), try parseSessionListLimit("2"));
    try std.testing.expectError(error.InvalidCharacter, parseSessionListLimit("x"));
}

test "parse resume picker selection" {
    try std.testing.expectEqual(@as(?usize, 0), try parseResumeSelection("1\n", 2));
    try std.testing.expectEqual(@as(?usize, 1), try parseResumeSelection(" 2 ", 2));
    try std.testing.expectEqual(@as(?usize, null), try parseResumeSelection("\n", 2));
    try std.testing.expectError(error.InvalidResumeSelection, parseResumeSelection("3", 2));
    try std.testing.expectError(error.InvalidCharacter, parseResumeSelection("x", 2));
}

test "parse permission updates" {
    const approval = try parsePermissionUpdate("approval=never");
    try std.testing.expectEqual(config.ApprovalPolicy.never, approval.approval);

    const sandbox = try parsePermissionUpdate("read-only");
    try std.testing.expectEqual(config.SandboxMode.read_only, sandbox.sandbox);

    try std.testing.expectError(error.InvalidPermissionsArgument, parsePermissionUpdate("unknown=value"));
}
