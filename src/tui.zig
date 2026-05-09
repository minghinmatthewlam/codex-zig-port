const std = @import("std");
const builtin = @import("builtin");

const api = @import("api.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const git_diff = @import("git_diff.zig");
const login = @import("login.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const review = @import("review.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const tools = @import("tools.zig");

const agents_filename = "AGENTS.md";
const init_prompt =
    \\Create an AGENTS.md file for this repository.
    \\Make it a concise contributor guide with practical headings and repository-specific guidance.
    \\Include build, test, coding style, and workflow notes where they apply.
    \\Inspect the project files before writing, and do not overwrite an existing AGENTS.md.
;
const compact_prompt =
    \\Summarize this conversation so another coding agent can continue from the compacted context.
    \\Preserve the user's goal, decisions, constraints, files changed, commands run, verification results, unresolved risks, and exact next steps.
    \\Be concise but specific. Do not include generic advice.
;

pub const Options = struct {
    resume_target: ?[]const u8 = null,
    resume_picker: bool = false,
    fork_target: ?[]const u8 = null,
    fork_picker: bool = false,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
    initial_prompt: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator) !void {
    try runWithOptions(allocator, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = options.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    if (options.oss) {
        try config.applyOssMode(&cfg, allocator, options.oss_provider, options.runtime_overrides.model != null);
    }

    var credentials = if (options.oss)
        try auth.localOssCredentials(allocator)
    else
        try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var resumed = false;
    var forked_from_path: ?[]const u8 = null;
    defer if (forked_from_path) |path| allocator.free(path);

    const source_fork_path = if (options.fork_picker) blk: {
        const picked_path = try promptSessionPicker(allocator, cfg.codex_home, "fork");
        if (picked_path == null) {
            std.debug.print("fork canceled\n", .{});
            return;
        }
        break :blk picked_path.?;
    } else if (options.fork_target) |target|
        try session_store.resolveResumePath(allocator, cfg.codex_home, target)
    else
        null;

    var session_path = if (source_fork_path) |path| blk: {
        forked_from_path = path;
        var loaded = try session_store.loadTranscript(allocator, path);
        errdefer loaded.deinit(allocator);
        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        errdefer allocator.free(next_path);
        try session_store.saveTranscript(allocator, next_path, &loaded);
        transcript.deinit(allocator);
        transcript = loaded;
        break :blk next_path;
    } else if (options.resume_picker) blk: {
        const picked_path = try promptSessionPicker(allocator, cfg.codex_home, "resume");
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
    if (forked_from_path) |path| {
        std.debug.print("forked: {s} -> {s} ({d} items)\n", .{ path, session_path, transcript.history.items.len });
    }

    var state = TuiState{};

    if (options.initial_prompt) |initial_prompt| {
        const prompt = std.mem.trim(u8, initial_prompt, " \t\r\n");
        if (prompt.len > 0) {
            runPrompt(allocator, cfg, credentials, &transcript, session_path, prompt, options.additional_writable_roots) catch |err| {
                std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            };
        }
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
        if (parseBangShellCommand(prompt)) |command| {
            runUserShellCommand(allocator, cfg, command, options.additional_writable_roots) catch |err| {
                std.debug.print("shell error: {s}\n", .{@errorName(err)});
            };
            continue;
        }
        const slash_action = handleSlashCommand(allocator, &cfg, credentials, &transcript, &session_path, cwd, prompt, &state, options.additional_writable_roots) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (slash_action) |action| {
            switch (action) {
                .handled => continue,
                .quit => break,
            }
        }

        runPrompt(allocator, cfg, credentials, &transcript, session_path, prompt, options.additional_writable_roots) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
    }

    std.debug.print("\nbye\n", .{});
}

fn runPrompt(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    prompt: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    std.debug.print("\nassistant:\n", .{});
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, transcript, prompt, .{
        .stream_text = true,
        .additional_writable_roots = additional_writable_roots,
    });
    defer allocator.free(answer);
    session_store.saveTranscript(allocator, session_path, transcript) catch |err| {
        std.debug.print("warning: could not save session: {s}\n", .{@errorName(err)});
    };
    if (answer.len == 0 or answer[answer.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
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
        \\search:   {s}
        \\Type /help for commands or /quit to exit.
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt, .agent_identity => cfg.chatgpt_base_url,
            .api_key, .local_oss => cfg.openai_base_url,
        },
        cwd,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
    });
}

fn promptSessionPicker(allocator: std.mem.Allocator, codex_home: []const u8, action: []const u8) !?[]const u8 {
    const sessions = try session_store.listSessions(allocator, codex_home, 10);
    defer session_store.freeSessionSummaries(allocator, sessions);

    if (sessions.len == 0) {
        std.debug.print("{s}: no saved Zig sessions\n", .{action});
        return null;
    }

    std.debug.print("{s} sessions:\n", .{action});
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

const TuiState = struct {
    raw_output_mode: bool = false,
    vim_mode: bool = false,
};

fn handleSlashCommand(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    credentials: auth.Credentials,
    transcript: *session.Transcript,
    session_path: *[]const u8,
    cwd: []const u8,
    prompt: []const u8,
    state: *TuiState,
    additional_writable_roots: []const []const u8,
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

    if (std.ascii.eqlIgnoreCase(parts.name, "init")) {
        if (try agentsFileExists(allocator, cwd)) {
            std.debug.print("{s} already exists here. Skipping /init to avoid overwriting it.\n", .{agents_filename});
            return .handled;
        }
        try runPrompt(allocator, cfg.*, credentials, transcript, session_path.*, init_prompt, additional_writable_roots);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "compact")) {
        try runCompact(allocator, cfg.*, credentials, transcript, session_path.*, additional_writable_roots);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "status")) {
        printStatus(cfg.*, credentials, transcript, session_path.*, cwd, state.*);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "debug-config")) {
        printDebugConfig(cfg.*, credentials);
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

    if (std.ascii.eqlIgnoreCase(parts.name, "copy")) {
        copyLastAssistantMessage(allocator, transcript);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "raw")) {
        handleRawOutputMode(&state.raw_output_mode, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "vim")) {
        state.vim_mode = !state.vim_mode;
        std.debug.print("vim mode: {s}\n", .{if (state.vim_mode) "on" else "off"});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "mcp")) {
        try printMcpStatus(allocator, cfg.codex_home, parts.args);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "ps")) {
        try printBackgroundTerminals(allocator);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "stop") or std.ascii.eqlIgnoreCase(parts.name, "clean")) {
        const stopped = tools.stopAllExecSessions();
        std.debug.print("stopped {d} background terminal(s)\n", .{stopped});
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "logout")) {
        try login.runLogout(allocator);
        return .handled;
    }

    if (std.ascii.eqlIgnoreCase(parts.name, "review")) {
        const review_prompt = if (parts.args.len == 0)
            try review.buildUncommittedPrompt(allocator)
        else
            try review.buildCustomPrompt(allocator, parts.args);
        defer allocator.free(review_prompt);
        try runPrompt(allocator, cfg.*, credentials, transcript, session_path.*, review_prompt, additional_writable_roots);
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

    if (std.ascii.eqlIgnoreCase(parts.name, "fork")) {
        const source_path = if (parts.args.len == 0)
            try allocator.dupe(u8, session_path.*)
        else
            try session_store.resolveResumePath(allocator, cfg.codex_home, parts.args);
        defer allocator.free(source_path);

        if (parts.args.len > 0) {
            var loaded = try session_store.loadTranscript(allocator, source_path);
            errdefer loaded.deinit(allocator);
            transcript.deinit(allocator);
            transcript.* = loaded;
        }

        const next_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        errdefer allocator.free(next_path);
        try session_store.saveTranscript(allocator, next_path, transcript);
        allocator.free(session_path.*);
        session_path.* = next_path;
        std.debug.print("forked: {s} -> {s} ({d} items)\n", .{ source_path, session_path.*, transcript.history.items.len });
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

    if (std.ascii.eqlIgnoreCase(parts.name, "fast")) {
        try handleFastMode(allocator, cfg, parts.args);
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
        \\  /init             create an AGENTS.md contributor guide
        \\  /compact          summarize and replace this session's history
        \\  /status           show current session settings
        \\  /debug-config     show effective configuration values
        \\  /model [name]     show or set the in-memory model for this session
        \\  /fast [on|off|status]
        \\                    toggle Fast service tier for this session
        \\  /permissions      show or set approval/sandbox modes
        \\  /approval [mode]  show or set approval policy
        \\  /sandbox [mode]   show or set sandbox mode
        \\  /history [n]      show recent transcript items
        \\  /rollout          show the active session JSONL path
        \\  /sessions [n]     list saved Zig sessions
        \\  /diff             show git status and diff, including untracked files
        \\  /copy             copy the last assistant response
        \\  /raw [on|off]     toggle copy-friendly transcript output
        \\  /vim              toggle Vim composer mode
        \\  /mcp [verbose]    list configured MCP servers
        \\  /ps               list background terminals
        \\  /stop, /clean     stop all background terminals
        \\  /logout           remove local Codex auth
        \\  /review [text]    review current changes or custom instructions
        \\  /clear            clear transcript and redraw the header
        \\  /new              start a new transcript
        \\  /resume [target]  resume last, a session id, or a JSONL path
        \\  /fork [target]    fork current, last, a session id, or a JSONL path
        \\  /quit, /exit      exit
        \\  !COMMAND          run a local shell command without sending to the model
        \\
    , .{});
}

fn agentsFileExists(allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ cwd, agents_filename });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn runCompact(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *session.Transcript,
    session_path: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    const previous_items = transcript.history.items.len;
    if (previous_items == 0) {
        std.debug.print("nothing to compact yet\n", .{});
        return;
    }

    std.debug.print("\ncompact:\n", .{});
    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, transcript, compact_prompt, .{
        .stream_text = true,
        .additional_writable_roots = additional_writable_roots,
        .include_tools = false,
    });
    defer allocator.free(answer);

    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCompactionSummary;

    const compacted = try std.fmt.allocPrint(
        allocator,
        "Compacted conversation summary:\n\n{s}",
        .{trimmed},
    );
    defer allocator.free(compacted);

    try transcript.replaceWithCompactedSummary(allocator, compacted);
    try session_store.saveTranscript(allocator, session_path, transcript);
    std.debug.print("\ncompacted: {d} -> {d} item\n", .{ previous_items, transcript.history.items.len });
}

fn printStatus(
    cfg: config.Config,
    credentials: auth.Credentials,
    transcript: *const session.Transcript,
    session_path: []const u8,
    cwd: []const u8,
    state: TuiState,
) void {
    const tool_label = if (cfg.web_search_mode) |mode|
        if (mode.externalWebAccess() != null)
            "exec_command, write_stdin, shell, shell_command, apply_patch, web_search"
        else
            "exec_command, write_stdin, shell, shell_command, apply_patch"
    else
        "exec_command, write_stdin, shell, shell_command, apply_patch";

    std.debug.print(
        \\status:
        \\  model:       {s}
        \\  auth:        {s}
        \\  api:         {s}
        \\  cwd:         {s}
        \\  session:     {s}
        \\  approval:    {s}
        \\  sandbox:     {s}
        \\  search:      {s}
        \\  service tier: {s}
        \\  raw output:  {s}
        \\  vim:         {s}
        \\  transcript:  {d} items
        \\  tools:       {s}
        \\
    , .{
        cfg.model,
        credentials.describe(),
        switch (credentials.mode) {
            .chatgpt, .agent_identity => cfg.chatgpt_base_url,
            .api_key, .local_oss => cfg.openai_base_url,
        },
        cwd,
        session_path,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
        if (cfg.service_tier) |service_tier| service_tier else "unset",
        if (state.raw_output_mode) "on" else "off",
        if (state.vim_mode) "on" else "off",
        transcript.history.items.len,
        tool_label,
    });
}

fn printDebugConfig(cfg: config.Config, credentials: auth.Credentials) void {
    std.debug.print(
        \\/debug-config
        \\
        \\effective config:
        \\  codex_home:     {s}
        \\  active_profile: {s}
        \\  model:          {s}
        \\  auth:           {s}
        \\  openai_base:    {s}
        \\  chatgpt_base:   {s}
        \\  approval:       {s}
        \\  sandbox:        {s}
        \\  web_search:     {s}
        \\  service_tier:   {s}
        \\  oss_provider:   {s}
        \\  installation:   {s}
        \\
        \\config layers: not yet implemented in the Zig port
        \\
    , .{
        cfg.codex_home,
        cfg.active_profile orelse "<none>",
        cfg.model,
        credentials.describe(),
        cfg.openai_base_url,
        cfg.chatgpt_base_url,
        cfg.approval_policy.label(),
        cfg.sandbox_mode.label(),
        config.webSearchLabel(cfg.web_search_mode),
        cfg.service_tier orelse "<none>",
        cfg.oss_provider orelse "<none>",
        cfg.installation_id,
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

fn handleFastMode(allocator: std.mem.Allocator, cfg: *config.Config, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        try setFastMode(allocator, cfg, !isFastMode(cfg.*));
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
        try setFastMode(allocator, cfg, true);
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
        try setFastMode(allocator, cfg, false);
        printFastMode(cfg.*);
        return;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "status")) {
        printFastMode(cfg.*);
        return;
    }
    std.debug.print("usage: /fast [on|off|status]\n", .{});
}

fn setFastMode(allocator: std.mem.Allocator, cfg: *config.Config, enabled: bool) !void {
    if (cfg.service_tier) |existing| {
        allocator.free(existing);
        cfg.service_tier = null;
    }
    if (enabled) {
        cfg.service_tier = try allocator.dupe(u8, "priority");
    }
}

fn isFastMode(cfg: config.Config) bool {
    return if (cfg.service_tier) |service_tier|
        std.ascii.eqlIgnoreCase(service_tier, "priority") or std.ascii.eqlIgnoreCase(service_tier, "fast")
    else
        false;
}

fn printFastMode(cfg: config.Config) void {
    std.debug.print("Fast mode is {s}.\n", .{if (isFastMode(cfg)) "on" else "off"});
}

fn copyLastAssistantMessage(allocator: std.mem.Allocator, transcript: *const session.Transcript) void {
    const text = lastAssistantMessage(transcript) orelse {
        std.debug.print("copy: no assistant response yet\n", .{});
        return;
    };
    copyToClipboard(allocator, text) catch |err| {
        std.debug.print("copy failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("copied {d} bytes to clipboard\n", .{text.len});
}

fn lastAssistantMessage(transcript: *const session.Transcript) ?[]const u8 {
    var index = transcript.history.items.len;
    while (index > 0) {
        index -= 1;
        const item = transcript.history.items[index];
        if (item.kind != .message) continue;
        const role = item.role orelse continue;
        if (!std.ascii.eqlIgnoreCase(role, "assistant")) continue;
        const text = item.text orelse continue;
        if (text.len == 0) continue;
        return text;
    }
    return null;
}

fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    const command_override = try env.getOwned(allocator, "CODEX_ZIG_COPY_COMMAND");
    defer if (command_override) |command| allocator.free(command);

    const command = command_override orelse switch (builtin.os.tag) {
        .macos => "/usr/bin/pbcopy",
        else => return error.ClipboardUnsupported,
    };

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const argv = [_][]const u8{command};
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io_instance.io());

    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(io_instance.io(), text);
        stdin_file.close(io_instance.io());
        child.stdin = null;
    }

    const term = try child.wait(io_instance.io());
    switch (term) {
        .exited => |code| if (code != 0) return error.ClipboardCommandFailed,
        .signal, .stopped, .unknown => return error.ClipboardCommandFailed,
    }
}

fn handleRawOutputMode(raw_output_mode: *bool, args: []const u8) void {
    const next_mode = parseRawOutputMode(args, raw_output_mode.*) catch |err| switch (err) {
        error.InvalidRawOutputMode => {
            std.debug.print("usage: /raw [on|off]\n", .{});
            return;
        },
    };
    raw_output_mode.* = next_mode;
    std.debug.print("raw output mode: {s}\n", .{if (raw_output_mode.*) "on" else "off"});
}

fn parseRawOutputMode(args: []const u8, current: bool) !bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return !current;
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    return error.InvalidRawOutputMode;
}

fn printMcpStatus(allocator: std.mem.Allocator, codex_home: []const u8, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const verbose = if (trimmed.len == 0)
        false
    else if (std.ascii.eqlIgnoreCase(trimmed, "verbose"))
        true
    else {
        std.debug.print("usage: /mcp [verbose]\n", .{});
        return;
    };

    const rendered = try mcp_cmd.renderStatus(allocator, codex_home, verbose);
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn parseBangShellCommand(prompt: []const u8) ?[]const u8 {
    if (prompt.len == 0 or prompt[0] != '!') return null;
    return std.mem.trim(u8, prompt[1..], " \t\r\n");
}

fn runUserShellCommand(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    command: []const u8,
    additional_writable_roots: []const []const u8,
) !void {
    if (command.len == 0) {
        std.debug.print("usage: !COMMAND\n", .{});
        return;
    }

    const arguments = try std.json.Stringify.valueAlloc(allocator, .{ .command = command }, .{});
    defer allocator.free(arguments);

    const call = api.FunctionCall{
        .call_id = "user-shell",
        .name = "shell_command",
        .arguments = arguments,
    };
    var result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = cfg.approval_policy,
        .sandbox_mode = cfg.sandbox_mode,
        .additional_writable_roots = additional_writable_roots,
        .auto_approve = true,
        .prompt_for_approval = false,
    });
    defer result.deinit(allocator);

    std.debug.print("shell: {s}\n{s}\n", .{ result.summary, result.output });
}

fn printBackgroundTerminals(allocator: std.mem.Allocator) !void {
    const sessions = try tools.listExecSessions(allocator);
    defer allocator.free(sessions);

    if (sessions.len == 0) {
        std.debug.print("background terminals: none\n", .{});
        return;
    }

    std.debug.print("background terminals:\n", .{});
    for (sessions) |entry| {
        const kind = if (entry.pty) "pty" else "pipes";
        std.debug.print("  {d}. {s}, {d}ms\n", .{ entry.id, kind, entry.age_ms });
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
    const init = parseSlash("/init").?;
    try std.testing.expectEqualStrings("init", init.name);
    try std.testing.expectEqualStrings("", init.args);

    const compact = parseSlash("/compact").?;
    try std.testing.expectEqualStrings("compact", compact.name);
    try std.testing.expectEqualStrings("", compact.args);

    const status = parseSlash("/status").?;
    try std.testing.expectEqualStrings("status", status.name);
    try std.testing.expectEqualStrings("", status.args);

    const debug_config = parseSlash("/debug-config").?;
    try std.testing.expectEqualStrings("debug-config", debug_config.name);
    try std.testing.expectEqualStrings("", debug_config.args);

    const model = parseSlash("/model gpt-test").?;
    try std.testing.expectEqualStrings("model", model.name);
    try std.testing.expectEqualStrings("gpt-test", model.args);

    const fast = parseSlash("/fast status").?;
    try std.testing.expectEqualStrings("fast", fast.name);
    try std.testing.expectEqualStrings("status", fast.args);

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

    const copy = parseSlash("/copy").?;
    try std.testing.expectEqualStrings("copy", copy.name);
    try std.testing.expectEqualStrings("", copy.args);

    const raw = parseSlash("/raw on").?;
    try std.testing.expectEqualStrings("raw", raw.name);
    try std.testing.expectEqualStrings("on", raw.args);

    const vim = parseSlash("/vim").?;
    try std.testing.expectEqualStrings("vim", vim.name);
    try std.testing.expectEqualStrings("", vim.args);

    const mcp = parseSlash("/mcp verbose").?;
    try std.testing.expectEqualStrings("mcp", mcp.name);
    try std.testing.expectEqualStrings("verbose", mcp.args);

    const ps = parseSlash("/ps").?;
    try std.testing.expectEqualStrings("ps", ps.name);
    try std.testing.expectEqualStrings("", ps.args);

    const stop = parseSlash("/stop").?;
    try std.testing.expectEqualStrings("stop", stop.name);
    try std.testing.expectEqualStrings("", stop.args);

    const clean = parseSlash("/clean").?;
    try std.testing.expectEqualStrings("clean", clean.name);
    try std.testing.expectEqualStrings("", clean.args);

    const logout = parseSlash("/logout").?;
    try std.testing.expectEqualStrings("logout", logout.name);
    try std.testing.expectEqualStrings("", logout.args);

    const review_cmd = parseSlash("/review check regressions").?;
    try std.testing.expectEqualStrings("review", review_cmd.name);
    try std.testing.expectEqualStrings("check regressions", review_cmd.args);

    try std.testing.expect(parseSlash("hello") == null);
}

test "parse bang shell command" {
    try std.testing.expect(parseBangShellCommand("hello") == null);
    try std.testing.expectEqualStrings("echo hi", parseBangShellCommand("! echo hi").?);
    try std.testing.expectEqualStrings("", parseBangShellCommand("!   ").?);
}

test "parse raw output mode args" {
    try std.testing.expectEqual(true, try parseRawOutputMode("", false));
    try std.testing.expectEqual(false, try parseRawOutputMode("", true));
    try std.testing.expectEqual(true, try parseRawOutputMode(" on ", false));
    try std.testing.expectEqual(false, try parseRawOutputMode("OFF", true));
    try std.testing.expectError(error.InvalidRawOutputMode, parseRawOutputMode("status", false));
}

test "finds last assistant message for copy" {
    const allocator = std.testing.allocator;
    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    try std.testing.expect(lastAssistantMessage(&transcript) == null);
    try transcript.appendUserMessage(allocator, "hello");
    try std.testing.expect(lastAssistantMessage(&transcript) == null);
    try transcript.appendAssistantMessage(allocator, "first answer");
    try transcript.appendUserMessage(allocator, "next");
    try transcript.appendAssistantMessage(allocator, "second answer");

    try std.testing.expectEqualStrings("second answer", lastAssistantMessage(&transcript).?);
}

test "agents file existence check" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const cwd = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    try std.testing.expect(!try agentsFileExists(allocator, cwd));
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = agents_filename,
        .data = "repo guidance\n",
    });
    try std.testing.expect(try agentsFileExists(allocator, cwd));
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
