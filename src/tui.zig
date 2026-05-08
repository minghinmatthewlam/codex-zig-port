const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

pub const Options = struct {
    resume_target: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator) !void {
    try runWithOptions(allocator, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var session_path = if (options.resume_target) |target|
        try session_store.resolveResumePath(allocator, cfg.codex_home, target)
    else
        try session_store.createSessionPath(allocator, cfg.codex_home);
    defer allocator.free(session_path);

    if (options.resume_target != null) {
        const loaded = try session_store.loadTranscript(allocator, session_path);
        transcript.deinit(allocator);
        transcript = loaded;
    }

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd);

    printHeader(cfg, credentials, cwd);
    if (options.resume_target != null) {
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

        std.debug.print("\nassistant streaming...\n", .{});
        const answer = session.runTurn(allocator, cfg, credentials, &transcript, prompt) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(answer);
        session_store.saveTranscript(allocator, session_path, &transcript) catch |err| {
            std.debug.print("warning: could not save session: {s}\n", .{@errorName(err)});
        };
        std.debug.print("\nassistant:\n{s}\n", .{answer});
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
    });
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
        \\  transcript:  {d} items
        \\  tools:       shell, shell_command, apply_patch
        \\  sandbox:     not implemented
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
        transcript.history.items.len,
    });
}

test "parse slash command names and args" {
    const status = parseSlash("/status").?;
    try std.testing.expectEqualStrings("status", status.name);
    try std.testing.expectEqualStrings("", status.args);

    const model = parseSlash("/model gpt-test").?;
    try std.testing.expectEqualStrings("model", model.name);
    try std.testing.expectEqualStrings("gpt-test", model.args);

    try std.testing.expect(parseSlash("hello") == null);
}
