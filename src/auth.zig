const std = @import("std");
const env = @import("env.zig");

pub const Credentials = struct {
    mode: Mode,
    token: []const u8,
    account_id: ?[]const u8 = null,
    fedramp: bool = false,

    pub const Mode = enum {
        chatgpt,
        agent_identity,
        api_key,
        local_oss,
    };

    pub fn deinit(self: *Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.account_id) |account_id| allocator.free(account_id);
    }

    pub fn describe(self: Credentials) []const u8 {
        return switch (self.mode) {
            .chatgpt => "ChatGPT token from auth.json",
            .agent_identity => "Access token",
            .api_key => "API key",
            .local_oss => "Local OSS provider",
        };
    }
};

const AuthJson = struct {
    auth_mode: ?[]const u8 = null,
    OPENAI_API_KEY: ?[]const u8 = null,
    tokens: ?TokenData = null,
    agent_identity: ?[]const u8 = null,
};

const TokenData = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
};

const AgentIdentityClaims = struct {
    account_id: ?[]const u8 = null,
    fedramp: bool = false,

    fn deinit(self: AgentIdentityClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
    }
};

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    if (try loadStored(allocator, codex_home)) |credentials| {
        return credentials;
    }

    const env_access_token = try env.getOwned(allocator, "CODEX_ACCESS_TOKEN");
    if (env_access_token) |access_token| {
        return try agentIdentityCredentialsFromOwnedToken(allocator, access_token);
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

        if (parsed.value.auth_mode) |mode| {
            if (isAgentIdentityAuthMode(mode)) {
                if (parsed.value.agent_identity) |agent_identity| {
                    return try agentIdentityCredentials(allocator, agent_identity);
                }
                return null;
            }
        }

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

        if (parsed.value.agent_identity) |agent_identity| {
            return try agentIdentityCredentials(allocator, agent_identity);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return null;
}

pub fn authorizationHeader(allocator: std.mem.Allocator, credentials: Credentials) ![]const u8 {
    if (credentials.mode == .local_oss) return error.LocalOssAuthHeaderUnavailable;
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{credentials.token});
}

pub fn localOssCredentials(allocator: std.mem.Allocator) !Credentials {
    return .{ .mode = .local_oss, .token = try allocator.dupe(u8, "") };
}

fn isAgentIdentityAuthMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "agentIdentity") or std.mem.eql(u8, mode, "agent_identity");
}

fn agentIdentityCredentials(allocator: std.mem.Allocator, token: []const u8) !Credentials {
    const owned_token = try allocator.dupe(u8, token);
    return try agentIdentityCredentialsFromOwnedToken(allocator, owned_token);
}

fn agentIdentityCredentialsFromOwnedToken(allocator: std.mem.Allocator, token: []const u8) !Credentials {
    errdefer allocator.free(token);

    var claims = parseAgentIdentityClaims(allocator, token) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .mode = .agent_identity, .token = token },
    };
    defer claims.deinit(allocator);

    const account_id = claims.account_id;
    claims.account_id = null;
    return .{
        .mode = .agent_identity,
        .token = token,
        .account_id = account_id,
        .fedramp = claims.fedramp,
    };
}

fn parseAgentIdentityClaims(allocator: std.mem.Allocator, jwt: []const u8) !AgentIdentityClaims {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload = parts.next() orelse return error.InvalidJwt;
    _ = parts.next() orelse return error.InvalidJwt;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonObject;
    const object = parsed.value.object;

    const account_id = if (object.get("account_id")) |value|
        if (value == .string) try allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (account_id) |id| allocator.free(id);

    const fedramp = if (object.get("chatgpt_account_is_fedramp")) |value|
        value == .bool and value.bool
    else
        false;

    return .{ .account_id = account_id, .fedramp = fedramp };
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

test "parses agent identity auth" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "auth.json",
        .data = "{\"auth_mode\":\"agentIdentity\",\"agent_identity\":\"agent-token\"}",
    });
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var creds = try load(allocator, root);
    defer creds.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.agent_identity, creds.mode);
    try std.testing.expectEqualStrings("agent-token", creds.token);
}

test "parses agent identity auth metadata from jwt" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const payload =
        \\{"account_id":"acct_agent","chatgpt_account_is_fedramp":true}
    ;
    var encoded_buffer: [512]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);
    const auth_json = try std.fmt.allocPrint(allocator, "{{\"auth_mode\":\"agentIdentity\",\"agent_identity\":\"{s}\"}}", .{jwt});
    defer allocator.free(auth_json);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "auth.json",
        .data = auth_json,
    });
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var creds = try load(allocator, root);
    defer creds.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.agent_identity, creds.mode);
    try std.testing.expectEqualStrings(jwt, creds.token);
    try std.testing.expectEqualStrings("acct_agent", creds.account_id.?);
    try std.testing.expect(creds.fedramp);
}
