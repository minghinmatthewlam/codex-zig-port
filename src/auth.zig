const std = @import("std");
const env = @import("env.zig");

pub const Credentials = struct {
    mode: Mode,
    token: []const u8,
    account_id: ?[]const u8 = null,
    fedramp: bool = false,

    pub const Mode = enum {
        chatgpt,
        api_key,
    };

    pub fn deinit(self: *Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.account_id) |account_id| allocator.free(account_id);
    }

    pub fn describe(self: Credentials) []const u8 {
        return switch (self.mode) {
            .chatgpt => "ChatGPT token from auth.json",
            .api_key => "API key",
        };
    }
};

const AuthJson = struct {
    auth_mode: ?[]const u8 = null,
    OPENAI_API_KEY: ?[]const u8 = null,
    tokens: ?TokenData = null,
};

const TokenData = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
};

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    if (try loadStored(allocator, codex_home)) |credentials| {
        return credentials;
    }

    const env_api_key = try env.getOwned(allocator, "OPENAI_API_KEY");
    if (env_api_key) |api_key| {
        return .{ .mode = .api_key, .token = api_key };
    }

    return error.NoUsableAuth;
}

pub fn loadStored(allocator: std.mem.Allocator, codex_home: []const u8) !?Credentials {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);

    if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024))) |bytes| {
        defer allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(AuthJson, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.tokens) |tokens| {
            const account_id = if (tokens.account_id) |id| try allocator.dupe(u8, id) else null;
            errdefer if (account_id) |id| allocator.free(id);
            return .{
                .mode = .chatgpt,
                .token = try allocator.dupe(u8, tokens.access_token),
                .account_id = account_id,
                .fedramp = false,
            };
        }

        if (parsed.value.OPENAI_API_KEY) |api_key| {
            return .{ .mode = .api_key, .token = try allocator.dupe(u8, api_key) };
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return null;
}

pub fn authorizationHeader(allocator: std.mem.Allocator, credentials: Credentials) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{credentials.token});
}

test "parses chatgpt auth" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "auth.json",
        .data = "{\"tokens\":{\"access_token\":\"tok\",\"account_id\":\"acct\"}}",
    });
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var creds = try load(allocator, root);
    defer creds.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.chatgpt, creds.mode);
    try std.testing.expectEqualStrings("tok", creds.token);
    try std.testing.expectEqualStrings("acct", creds.account_id.?);
}
