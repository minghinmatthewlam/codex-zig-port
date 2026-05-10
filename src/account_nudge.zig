const std = @import("std");

const auth = @import("auth.zig");

pub const SendStatus = enum {
    sent,
    cooldown_active,

    pub fn jsonLabel(self: SendStatus) []const u8 {
        return switch (self) {
            .sent => "sent",
            .cooldown_active => "cooldown_active",
        };
    }
};

pub fn sendAddCreditsNudgeEmail(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    credit_type: []const u8,
) !SendStatus {
    const url = try nudgeUrl(allocator, base_url);
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    const body = try std.fmt.allocPrint(allocator, "{{\"credit_type\":\"{s}\"}}", .{credit_type});
    defer allocator.free(body);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });

    if (result.status == .too_many_requests) return .cooldown_active;
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.AppServerAddCreditsNudgeHttpStatus;
    }
    return .sent;
}

fn nudgeUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    const normalized = if ((std.mem.startsWith(u8, trimmed, "https://chatgpt.com") or
        std.mem.startsWith(u8, trimmed, "https://chat.openai.com")) and
        std.mem.indexOf(u8, trimmed, "/backend-api") == null)
        try std.fmt.allocPrint(allocator, "{s}/backend-api", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(normalized);

    const suffix = if (std.mem.indexOf(u8, normalized, "/backend-api") != null)
        "wham/accounts/send_add_credits_nudge_email"
    else
        "api/codex/accounts/send_add_credits_nudge_email";
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalized, suffix });
}

test "add credits nudge url follows backend path style" {
    const allocator = std.testing.allocator;

    const codex_url = try nudgeUrl(allocator, "https://example.test/");
    defer allocator.free(codex_url);
    try std.testing.expectEqualStrings(
        "https://example.test/api/codex/accounts/send_add_credits_nudge_email",
        codex_url,
    );

    const chatgpt_url = try nudgeUrl(allocator, "https://chatgpt.com/backend-api");
    defer allocator.free(chatgpt_url);
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/wham/accounts/send_add_credits_nudge_email",
        chatgpt_url,
    );
}
