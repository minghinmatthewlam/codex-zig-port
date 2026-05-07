const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");
const session = @import("session.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    var credentials = try auth.load(allocator, cfg.codex_home);
    defer credentials.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    printHeader(cfg, credentials);

    var input_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

    while (true) {
        std.debug.print("\n› ", .{});
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        const prompt = std.mem.trim(u8, line, " \t\r\n");
        if (prompt.len == 0) continue;
        if (std.mem.eql(u8, prompt, "/quit") or std.mem.eql(u8, prompt, "q")) break;

        std.debug.print("\nassistant streaming...\n", .{});
        const answer = session.runTurn(allocator, cfg, credentials, &transcript, prompt) catch |err| {
            std.debug.print("\nerror: {s}\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(answer);
        std.debug.print("\nassistant:\n{s}\n", .{answer});
    }

    std.debug.print("\nbye\n", .{});
}

fn printHeader(cfg: config.Config, credentials: auth.Credentials) void {
    std.debug.print(
        \\╭────────────────────────────────────────────╮
        \\│ Codex Zig                                  │
        \\╰────────────────────────────────────────────╯
        \\model: {s}
        \\auth: {s}
        \\cwd:  {s}
        \\Type /quit to exit.
        \\
    , .{ cfg.model, credentials.describe(), "." });
}
