const std = @import("std");

const auth = @import("auth.zig");

const RemotePluginSkillDetailPayload = struct {
    plugin_id: []const u8,
    name: []const u8,
    skill_md_contents: ?[]const u8 = null,
};

pub fn isKnownRemoteMarketplace(name: []const u8) bool {
    return std.mem.eql(u8, name, "chatgpt-global") or
        std.mem.eql(u8, name, "workspace-directory") or
        std.mem.eql(u8, name, "shared-with-me");
}

pub fn isValidRemotePluginId(plugin_id: []const u8) bool {
    if (plugin_id.len == 0) return false;
    for (plugin_id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '~') continue;
        return false;
    }
    return true;
}

pub fn fetchSkillReadJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    plugin_id: []const u8,
    skill_name: []const u8,
) ![]const u8 {
    const url = try skillDetailUrl(allocator, base_url, plugin_id, skill_name);
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.RemotePluginSkillHttpStatus;
    }

    const bytes = try response_body.toOwnedSlice();
    defer allocator.free(bytes);
    return renderSkillReadJson(allocator, bytes, plugin_id, skill_name);
}

fn skillDetailUrl(allocator: std.mem.Allocator, base_url: []const u8, plugin_id: []const u8, skill_name: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidRemotePluginBaseUrl;

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, trimmed);
    try url.appendSlice(allocator, "/ps/plugins/");
    try appendPathSegment(allocator, &url, plugin_id);
    try url.appendSlice(allocator, "/skills/");
    try appendPathSegment(allocator, &url, skill_name);
    return url.toOwnedSlice(allocator);
}

fn appendPathSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (isUnreservedUrlByte(byte)) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn isUnreservedUrlByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn renderSkillReadJson(allocator: std.mem.Allocator, body: []const u8, expected_plugin_id: []const u8, expected_skill_name: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(RemotePluginSkillDetailPayload, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.plugin_id, expected_plugin_id)) return error.RemotePluginSkillPluginIdMismatch;
    if (!std.mem.eql(u8, parsed.value.name, expected_skill_name)) return error.RemotePluginSkillNameMismatch;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"contents\":");
    if (parsed.value.skill_md_contents) |contents| {
        const contents_json = try std.json.Stringify.valueAlloc(allocator, contents, .{});
        defer allocator.free(contents_json);
        try result.appendSlice(allocator, contents_json);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

test "remote plugin id validation follows Rust wire shape" {
    try std.testing.expect(isValidRemotePluginId("plugins~Plugin_00000000000000000000000000000000"));
    try std.testing.expect(isValidRemotePluginId("plugin-123"));
    try std.testing.expect(!isValidRemotePluginId(""));
    try std.testing.expect(!isValidRemotePluginId("plugin/123"));
}

test "remote skill detail URL appends escaped path segments" {
    const allocator = std.testing.allocator;
    const url = try skillDetailUrl(allocator, "https://chatgpt.com/backend-api/", "plugins~Plugin_123", "plan work");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/ps/plugins/plugins~Plugin_123/skills/plan%20work", url);
}

test "remote skill detail JSON renders nullable contents" {
    const allocator = std.testing.allocator;
    const body =
        \\{"plugin_id":"plugins~Plugin_123","name":"plan-work","skill_md_contents":"# Plan Work\n"}
    ;
    const rendered = try renderSkillReadJson(allocator, body, "plugins~Plugin_123", "plan-work");
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("{\"contents\":\"# Plan Work\\n\"}", rendered);

    const null_body =
        \\{"plugin_id":"plugins~Plugin_123","name":"plan-work","skill_md_contents":null}
    ;
    const null_rendered = try renderSkillReadJson(allocator, null_body, "plugins~Plugin_123", "plan-work");
    defer allocator.free(null_rendered);
    try std.testing.expectEqualStrings("{\"contents\":null}", null_rendered);
}
