const std = @import("std");
const env = @import("env.zig");

pub const chatgpt_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const refresh_token_url = "https://auth.openai.com/oauth/token";
const refresh_token_url_override_env = "CODEX_REFRESH_TOKEN_URL_OVERRIDE";
const token_refresh_interval_days = 8;
const seconds_per_day = 24 * 60 * 60;

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
    last_refresh: ?[]const u8 = null,
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

pub const ChatGptClaims = struct {
    account_id: ?[]const u8 = null,
    email: ?[]const u8 = null,
    plan_type: ?[]const u8 = null,
    fedramp: bool = false,

    pub fn deinit(self: ChatGptClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
        if (self.email) |email| allocator.free(email);
        if (self.plan_type) |plan_type| allocator.free(plan_type);
    }
};

pub const ChatGptAccountInfo = struct {
    email: []const u8,
    plan_type: []const u8,

    pub fn deinit(self: ChatGptAccountInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.email);
        allocator.free(self.plan_type);
    }
};

const RefreshResponse = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,

    fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    if (try loadStoredWithOptions(allocator, codex_home, .{ .refresh_chatgpt = true })) |credentials| {
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

pub fn loadNoRefresh(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    if (try loadStoredWithOptions(allocator, codex_home, .{})) |credentials| {
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
    return loadStoredWithOptions(allocator, codex_home, .{});
}

pub fn loadStoredChatGptAccountInfo(allocator: std.mem.Allocator, codex_home: []const u8) !?ChatGptAccountInfo {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(AuthJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const tokens = parsed.value.tokens orelse return null;
    const id_token = tokens.id_token orelse return null;

    var claims = parseChatGptClaims(allocator, id_token) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer claims.deinit(allocator);

    const email = claims.email orelse return null;
    claims.email = null;
    const plan_type = if (claims.plan_type) |value| value else try allocator.dupe(u8, "unknown");
    claims.plan_type = null;
    errdefer allocator.free(email);
    errdefer allocator.free(plan_type);

    return .{ .email = email, .plan_type = plan_type };
}

const LoadStoredOptions = struct {
    refresh_chatgpt: bool = false,
};

fn loadStoredWithOptions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    options: LoadStoredOptions,
) !?Credentials {
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
            if (options.refresh_chatgpt and try shouldRefreshChatGptToken(allocator, tokens, parsed.value.last_refresh)) {
                refreshChatGptAuth(allocator, codex_home, parsed.value) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => std.debug.print("warning: could not refresh ChatGPT auth token: {s}\n", .{@errorName(err)}),
                };
                if (try loadStoredWithOptions(allocator, codex_home, .{})) |refreshed| return refreshed;
            }
            return try chatGptCredentials(allocator, tokens);
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

fn chatGptCredentials(allocator: std.mem.Allocator, tokens: TokenData) !Credentials {
    const account_id = if (tokens.account_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (account_id) |id| allocator.free(id);
    return .{
        .mode = .chatgpt,
        .token = try allocator.dupe(u8, tokens.access_token),
        .account_id = account_id,
        .fedramp = false,
    };
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

fn shouldRefreshChatGptToken(allocator: std.mem.Allocator, tokens: TokenData, last_refresh: ?[]const u8) !bool {
    return shouldRefreshChatGptTokenAt(allocator, tokens, last_refresh, currentEpochSeconds());
}

fn shouldRefreshChatGptTokenAt(
    allocator: std.mem.Allocator,
    tokens: TokenData,
    last_refresh: ?[]const u8,
    now: u64,
) !bool {
    if (tokens.refresh_token == null) return false;
    const expires_at = parseJwtExpiration(allocator, tokens.access_token) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (expires_at) |seconds| return seconds <= now;

    const refreshed_at = if (last_refresh) |value|
        parseRfc3339Seconds(value) catch return false
    else
        return false;
    const interval_seconds = token_refresh_interval_days * seconds_per_day;
    if (now <= interval_seconds) return false;
    return refreshed_at < now - interval_seconds;
}

fn refreshChatGptAuth(allocator: std.mem.Allocator, codex_home: []const u8, auth_json: AuthJson) !void {
    const tokens = auth_json.tokens orelse return error.MissingChatGptTokens;
    const existing_refresh = tokens.refresh_token orelse return error.MissingRefreshToken;

    const endpoint = try refreshTokenEndpoint(allocator);
    defer allocator.free(endpoint);

    const request_body = try std.json.Stringify.valueAlloc(allocator, .{
        .client_id = chatgpt_client_id,
        .grant_type = "refresh_token",
        .refresh_token = existing_refresh,
    }, .{});
    defer allocator.free(request_body);

    var response = try postJson(allocator, endpoint, request_body);
    defer response.deinit(allocator);
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) {
        std.debug.print("ChatGPT token refresh failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return error.RefreshTokenFailed;
    }

    var parsed = try std.json.parseFromSlice(RefreshResponse, allocator, response.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const refreshed_access = parsed.value.access_token orelse tokens.access_token;
    const refreshed_refresh = parsed.value.refresh_token orelse existing_refresh;
    const refreshed_id = parsed.value.id_token orelse tokens.id_token;

    var claims = if (refreshed_id) |id_token|
        parseChatGptClaims(allocator, id_token) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => ChatGptClaims{},
        }
    else
        ChatGptClaims{};
    defer claims.deinit(allocator);

    const account_id = if (claims.account_id) |id|
        id
    else
        tokens.account_id;

    const last_refresh = try currentRfc3339(allocator);
    defer allocator.free(last_refresh);

    const output = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "chatgpt",
        .tokens = .{
            .id_token = refreshed_id,
            .access_token = refreshed_access,
            .refresh_token = refreshed_refresh,
            .account_id = account_id,
        },
        .last_refresh = last_refresh,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(output);

    try writeAuthJson(allocator, codex_home, output);
}

fn refreshTokenEndpoint(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, refresh_token_url_override_env)) |override| return override;
    return allocator.dupe(u8, refresh_token_url);
}

fn postJson(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) !HttpResponse {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });

    return .{ .status = result.status, .body = try response_body.toOwnedSlice() };
}

pub fn writeAuthJson(allocator: std.mem.Allocator, codex_home: []const u8, json: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, codex_home);

    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = json,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

pub fn deleteAuthJson(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn parseJwtExpiration(allocator: std.mem.Allocator, jwt: []const u8) !?u64 {
    var parsed = try parseJwtPayload(allocator, jwt);
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("exp") orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @as(u64, @intCast(number)) else null,
        .float => |number| if (number >= 0) @as(u64, @intFromFloat(number)) else null,
        else => null,
    };
}

pub fn parseChatGptClaims(allocator: std.mem.Allocator, jwt: []const u8) !ChatGptClaims {
    var parsed = try parseJwtPayload(allocator, jwt);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonObject;
    const object = parsed.value.object;

    const email = try parseChatGptEmailClaim(allocator, object);
    errdefer if (email) |value| allocator.free(value);

    const auth_value = object.get("https://api.openai.com/auth") orelse return .{ .email = email };
    if (auth_value != .object) return .{ .email = email };
    const auth_object = auth_value.object;

    const account_id = if (auth_object.get("chatgpt_account_id")) |value|
        if (value == .string) try allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (account_id) |id| allocator.free(id);

    const plan_type = if (auth_object.get("chatgpt_plan_type")) |value|
        if (value == .string) try normalizeChatGptPlanType(allocator, value.string) else null
    else
        null;
    errdefer if (plan_type) |value| allocator.free(value);

    const fedramp = if (auth_object.get("chatgpt_account_is_fedramp")) |value|
        value == .bool and value.bool
    else
        false;

    return .{ .account_id = account_id, .email = email, .plan_type = plan_type, .fedramp = fedramp };
}

fn parseChatGptEmailClaim(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    if (object.get("email")) |value| {
        if (value == .string) return try allocator.dupe(u8, value.string);
    }
    const profile = object.get("https://api.openai.com/profile") orelse return null;
    if (profile != .object) return null;
    const email = profile.object.get("email") orelse return null;
    if (email != .string) return null;
    return try allocator.dupe(u8, email.string);
}

fn normalizeChatGptPlanType(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "free")) return allocator.dupe(u8, "free");
    if (std.ascii.eqlIgnoreCase(raw, "go")) return allocator.dupe(u8, "go");
    if (std.ascii.eqlIgnoreCase(raw, "plus")) return allocator.dupe(u8, "plus");
    if (std.ascii.eqlIgnoreCase(raw, "pro")) return allocator.dupe(u8, "pro");
    if (std.ascii.eqlIgnoreCase(raw, "prolite")) return allocator.dupe(u8, "prolite");
    if (std.ascii.eqlIgnoreCase(raw, "team")) return allocator.dupe(u8, "team");
    if (std.ascii.eqlIgnoreCase(raw, "self_serve_business_usage_based")) return allocator.dupe(u8, "self_serve_business_usage_based");
    if (std.ascii.eqlIgnoreCase(raw, "business")) return allocator.dupe(u8, "business");
    if (std.ascii.eqlIgnoreCase(raw, "enterprise_cbp_usage_based")) return allocator.dupe(u8, "enterprise_cbp_usage_based");
    if (std.ascii.eqlIgnoreCase(raw, "enterprise") or std.ascii.eqlIgnoreCase(raw, "hc")) return allocator.dupe(u8, "enterprise");
    if (std.ascii.eqlIgnoreCase(raw, "education") or std.ascii.eqlIgnoreCase(raw, "edu")) return allocator.dupe(u8, "edu");
    return allocator.dupe(u8, "unknown");
}

fn parseJwtPayload(allocator: std.mem.Allocator, jwt: []const u8) !std.json.Parsed(std.json.Value) {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload = parts.next() orelse return error.InvalidJwt;
    _ = parts.next() orelse return error.InvalidJwt;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);

    return std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
}

fn currentEpochSeconds() u64 {
    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real);
    return @as(u64, @intCast(now.toSeconds()));
}

pub fn currentRfc3339(allocator: std.mem.Allocator) ![]const u8 {
    const seconds = currentEpochSeconds();
    return rfc3339FromSeconds(allocator, seconds);
}

pub fn rfc3339FromSeconds(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn parseRfc3339Seconds(value: []const u8) !u64 {
    if (value.len < "YYYY-MM-DDTHH:MM:SSZ".len) return error.InvalidRfc3339;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') {
        return error.InvalidRfc3339;
    }

    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);

    var end_index: usize = 19;
    if (end_index < value.len and value[end_index] == '.') {
        end_index += 1;
        const fraction_start = end_index;
        while (end_index < value.len and std.ascii.isDigit(value[end_index])) {
            end_index += 1;
        }
        if (end_index == fraction_start) return error.InvalidRfc3339;
    }
    if (end_index >= value.len or value[end_index] != 'Z' or end_index + 1 != value.len) {
        return error.InvalidRfc3339;
    }
    if (year < std.time.epoch.epoch_year or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) {
        return error.InvalidRfc3339;
    }

    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month = std.time.epoch.getDaysInMonth(year, month_enum);
    if (day < 1 or day > days_in_month) return error.InvalidRfc3339;

    var days: u64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }

    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;

    return days * seconds_per_day + @as(u64, hour) * 60 * 60 + @as(u64, minute) * 60 + second;
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

test "jwt expiration parser reads exp claim" {
    const allocator = std.testing.allocator;
    const payload = "{\"exp\":4102444800}";
    var encoded_buffer: [128]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);

    const expires_at = try parseJwtExpiration(allocator, jwt);
    try std.testing.expectEqual(@as(u64, 4102444800), expires_at.?);
}

test "chatgpt refresh decision uses expired access token with refresh token" {
    const allocator = std.testing.allocator;
    const payload = "{\"exp\":1}";
    var encoded_buffer: [128]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);

    try std.testing.expect(try shouldRefreshChatGptTokenAt(allocator, .{
        .access_token = jwt,
        .refresh_token = "refresh-token",
    }, null, currentEpochSeconds()));
    try std.testing.expect(!try shouldRefreshChatGptTokenAt(allocator, .{
        .access_token = jwt,
        .refresh_token = null,
    }, null, currentEpochSeconds()));
}

test "chatgpt refresh decision falls back to stale last_refresh" {
    const allocator = std.testing.allocator;
    const now = try parseRfc3339Seconds("2026-01-09T00:00:01Z");

    try std.testing.expect(try shouldRefreshChatGptTokenAt(allocator, .{
        .access_token = "not-a-jwt",
        .refresh_token = "refresh-token",
    }, "2026-01-01T00:00:00.123456789Z", now));

    try std.testing.expect(!try shouldRefreshChatGptTokenAt(allocator, .{
        .access_token = "not-a-jwt",
        .refresh_token = "refresh-token",
    }, "2026-01-02T00:00:00Z", now));
}
