const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const config = @import("config.zig");

pub const chatgpt_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const cli_auth_keyring_service = "Codex Auth";
const security_binary = "/usr/bin/security";
const refresh_token_url = "https://auth.openai.com/oauth/token";
const refresh_token_url_override_env = "CODEX_REFRESH_TOKEN_URL_OVERRIDE";
const revoke_token_url = "https://auth.openai.com/oauth/revoke";
const revoke_token_url_override_env = "CODEX_REVOKE_TOKEN_URL_OVERRIDE";
const revoke_token_timeout_ms_override_env = "CODEX_REVOKE_TOKEN_TIMEOUT_MS_OVERRIDE";
const revoke_http_timeout_ms = 10_000;
const security_command_timeout_ms = 5_000;
const token_refresh_interval_days = 8;
const seconds_per_day = 24 * 60 * 60;

var ephemeral_auth_mutex: std.Io.Mutex = .init;
var ephemeral_auth_store: std.StringHashMapUnmanaged([]const u8) = .empty;

pub const Credentials = struct {
    mode: Mode,
    token: []const u8,
    account_id: ?[]const u8 = null,
    chatgpt_user_id: ?[]const u8 = null,
    fedramp: bool = false,
    provider_auth_fetched_ms: ?i64 = null,

    pub const Mode = enum {
        chatgpt,
        chatgpt_auth_tokens,
        agent_identity,
        api_key,
        local_oss,
    };

    pub fn deinit(self: *Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.account_id) |account_id| allocator.free(account_id);
        if (self.chatgpt_user_id) |chatgpt_user_id| allocator.free(chatgpt_user_id);
    }

    pub fn describe(self: Credentials) []const u8 {
        return switch (self.mode) {
            .chatgpt => "ChatGPT token from auth.json",
            .chatgpt_auth_tokens => "Externally managed ChatGPT token",
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
    chatgpt_plan_type: ?[]const u8 = null,
};

const AgentIdentityClaims = struct {
    account_id: ?[]const u8 = null,
    chatgpt_user_id: ?[]const u8 = null,
    fedramp: bool = false,

    fn deinit(self: AgentIdentityClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
        if (self.chatgpt_user_id) |chatgpt_user_id| allocator.free(chatgpt_user_id);
    }
};

pub const ChatGptClaims = struct {
    account_id: ?[]const u8 = null,
    chatgpt_user_id: ?[]const u8 = null,
    email: ?[]const u8 = null,
    plan_type: ?[]const u8 = null,
    organization_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    completed_platform_onboarding: ?bool = null,
    is_org_owner: ?bool = null,
    fedramp: bool = false,

    pub fn deinit(self: ChatGptClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
        if (self.chatgpt_user_id) |chatgpt_user_id| allocator.free(chatgpt_user_id);
        if (self.email) |email| allocator.free(email);
        if (self.plan_type) |plan_type| allocator.free(plan_type);
        if (self.organization_id) |organization_id| allocator.free(organization_id);
        if (self.project_id) |project_id| allocator.free(project_id);
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

const RevokeTokenKind = enum {
    access,
    refresh,

    fn tokenTypeHint(self: RevokeTokenKind) []const u8 {
        return switch (self) {
            .access => "access_token",
            .refresh => "refresh_token",
        };
    }
};

const RevokeToken = struct {
    kind: RevokeTokenKind,
    token: []const u8,
};

const PostJsonTimeoutContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    payload: []const u8,
    done: std.Io.Event = .unset,
    result: ?HttpResponse = null,
    err: ?anyerror = null,
};

const PromptedSecurityCommandContext = struct {
    io: std.Io,
    argv: []const []const u8,
    password: []const u8,
    done: std.Io.Event = .unset,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
};

pub fn load(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    return loadWithProviderAuth(allocator, codex_home, null, null, null, .file, true);
}

pub fn loadForConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !Credentials {
    return loadWithProviderAuth(
        allocator,
        cfg.codex_home,
        cfg.model_provider_env_key,
        cfg.model_provider_bearer_token,
        cfg.model_provider_auth_command,
        cfg.cli_auth_credentials_store_mode,
        true,
    );
}

pub fn loadCliAuthForConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !Credentials {
    return loadCliAuthForConfigWithRefresh(allocator, cfg, true);
}

pub fn loadCliAuthNoRefreshForConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !Credentials {
    return loadCliAuthForConfigWithRefresh(allocator, cfg, false);
}

fn loadCliAuthForConfigWithRefresh(allocator: std.mem.Allocator, cfg: *const config.Config, refresh_chatgpt: bool) !Credentials {
    return loadWithProviderAuth(
        allocator,
        cfg.codex_home,
        null,
        null,
        null,
        cfg.cli_auth_credentials_store_mode,
        refresh_chatgpt,
    );
}

pub fn loadNoRefresh(allocator: std.mem.Allocator, codex_home: []const u8) !Credentials {
    return loadWithProviderAuth(allocator, codex_home, null, null, null, .file, false);
}

fn loadWithProviderAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    provider_env_key: ?[]const u8,
    provider_bearer_token: ?[]const u8,
    provider_auth_command: ?config.ProviderAuthCommand,
    store_mode: config.AuthCredentialsStoreMode,
    refresh_chatgpt: bool,
) !Credentials {
    if (provider_env_key) |key| {
        if (try env.getOwnedDynamic(allocator, key)) |token| {
            if (std.mem.trim(u8, token, " \t\r\n").len > 0) {
                return .{ .mode = .api_key, .token = token };
            }
            allocator.free(token);
        }
        return error.ModelProviderEnvKeyMissing;
    }
    if (provider_bearer_token) |token| {
        return .{ .mode = .api_key, .token = try allocator.dupe(u8, token) };
    }
    if (provider_auth_command) |command| {
        return loadProviderCommandCredentials(allocator, command);
    }

    if (try loadStoredWithOptions(allocator, codex_home, .{ .store_mode = store_mode, .refresh_chatgpt = refresh_chatgpt, .include_ephemeral_external = true })) |credentials| {
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

pub fn loadProviderCommandCredentials(
    allocator: std.mem.Allocator,
    provider_auth_command: config.ProviderAuthCommand,
) !Credentials {
    return loadProviderCommandCredentialsAt(allocator, provider_auth_command, currentAwakeMillis());
}

fn loadProviderCommandCredentialsAt(
    allocator: std.mem.Allocator,
    provider_auth_command: config.ProviderAuthCommand,
    fetched_at_ms: i64,
) !Credentials {
    const argv = try allocator.alloc([]const u8, provider_auth_command.args.items.len + 1);
    defer allocator.free(argv);
    argv[0] = provider_auth_command.command;
    for (provider_auth_command.args.items, 0..) |arg, index| {
        argv[index + 1] = arg;
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const cwd: std.process.Child.Cwd = if (provider_auth_command.cwd) |path| .{ .path = path } else .inherit;
    const timeout_ms = std.math.cast(i64, provider_auth_command.timeout_ms) orelse return error.InvalidModelProviderAuthTimeout;
    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!providerAuthCommandSucceeded(result.term)) return error.ModelProviderAuthCommandFailed;
    const token = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (token.len == 0) return error.ModelProviderAuthCommandEmptyToken;
    return .{
        .mode = .api_key,
        .token = try allocator.dupe(u8, token),
        .provider_auth_fetched_ms = fetched_at_ms,
    };
}

pub fn refreshProviderCommandCredentialsIfExpired(
    allocator: std.mem.Allocator,
    credentials: *Credentials,
    provider_auth_command: config.ProviderAuthCommand,
) !void {
    return refreshProviderCommandCredentialsIfExpiredAt(allocator, credentials, provider_auth_command, currentAwakeMillis());
}

fn refreshProviderCommandCredentialsIfExpiredAt(
    allocator: std.mem.Allocator,
    credentials: *Credentials,
    provider_auth_command: config.ProviderAuthCommand,
    now_ms: i64,
) !void {
    if (provider_auth_command.refresh_interval_ms == 0) return;
    const fetched_at_ms = credentials.provider_auth_fetched_ms orelse return;
    if (now_ms <= fetched_at_ms) return;
    const elapsed_ms: u64 = @intCast(now_ms - fetched_at_ms);
    if (elapsed_ms >= provider_auth_command.refresh_interval_ms) {
        try refreshProviderCommandCredentialsAt(allocator, credentials, provider_auth_command, now_ms);
    }
}

pub fn refreshProviderCommandCredentials(
    allocator: std.mem.Allocator,
    credentials: *Credentials,
    provider_auth_command: config.ProviderAuthCommand,
) !void {
    return refreshProviderCommandCredentialsAt(allocator, credentials, provider_auth_command, currentAwakeMillis());
}

fn refreshProviderCommandCredentialsAt(
    allocator: std.mem.Allocator,
    credentials: *Credentials,
    provider_auth_command: config.ProviderAuthCommand,
    fetched_at_ms: i64,
) !void {
    const refreshed = try loadProviderCommandCredentialsAt(allocator, provider_auth_command, fetched_at_ms);
    credentials.deinit(allocator);
    credentials.* = refreshed;
}

fn providerAuthCommandSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn loadStored(allocator: std.mem.Allocator, codex_home: []const u8) !?Credentials {
    return loadStoredWithOptions(allocator, codex_home, .{});
}

pub fn loadStoredWithMode(allocator: std.mem.Allocator, codex_home: []const u8, store_mode: config.AuthCredentialsStoreMode) !?Credentials {
    return loadStoredWithOptions(allocator, codex_home, .{ .store_mode = store_mode });
}

pub fn loadActiveStoredWithMode(allocator: std.mem.Allocator, codex_home: []const u8, store_mode: config.AuthCredentialsStoreMode) !?Credentials {
    return loadStoredWithOptions(allocator, codex_home, .{ .store_mode = store_mode, .include_ephemeral_external = true });
}

pub fn loadStoredChatGptAccountInfo(allocator: std.mem.Allocator, codex_home: []const u8) !?ChatGptAccountInfo {
    return loadStoredChatGptAccountInfoWithMode(allocator, codex_home, .file);
}

pub fn loadStoredChatGptAccountInfoWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !?ChatGptAccountInfo {
    const bytes = (try readAuthJsonBytesWithMode(allocator, codex_home, store_mode)) orelse return null;
    return loadChatGptAccountInfoFromBytes(allocator, bytes);
}

pub fn loadActiveStoredChatGptAccountInfoWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !?ChatGptAccountInfo {
    const bytes = (try readActiveAuthJsonBytesWithMode(allocator, codex_home, store_mode)) orelse return null;
    return loadChatGptAccountInfoFromBytes(allocator, bytes);
}

fn loadChatGptAccountInfoFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !?ChatGptAccountInfo {
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
    const plan_type = if (tokens.chatgpt_plan_type) |value|
        try normalizeChatGptPlanType(allocator, value)
    else if (claims.plan_type) |value|
        value
    else
        try allocator.dupe(u8, "unknown");
    if (tokens.chatgpt_plan_type == null) claims.plan_type = null;
    errdefer allocator.free(email);
    errdefer allocator.free(plan_type);

    return .{ .email = email, .plan_type = plan_type };
}

const LoadStoredOptions = struct {
    store_mode: config.AuthCredentialsStoreMode = .file,
    refresh_chatgpt: bool = false,
    include_ephemeral_external: bool = false,
};

fn loadStoredWithOptions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    options: LoadStoredOptions,
) !?Credentials {
    const bytes = if (options.include_ephemeral_external)
        (try readActiveAuthJsonBytesWithMode(allocator, codex_home, options.store_mode)) orelse return null
    else
        (try readAuthJsonBytesWithMode(allocator, codex_home, options.store_mode)) orelse return null;
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
        const credentials_mode: Credentials.Mode = if (parsed.value.auth_mode) |mode|
            if (isChatGptAuthTokensMode(mode)) .chatgpt_auth_tokens else .chatgpt
        else
            .chatgpt;
        if (credentials_mode == .chatgpt and options.refresh_chatgpt and try shouldRefreshChatGptToken(allocator, tokens, parsed.value.last_refresh)) {
            refreshChatGptAuth(allocator, codex_home, options.store_mode, parsed.value) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => std.debug.print("warning: could not refresh ChatGPT auth token: {s}\n", .{@errorName(err)}),
            };
            if (try loadStoredWithOptions(allocator, codex_home, .{ .store_mode = options.store_mode })) |refreshed| return refreshed;
        }
        return try chatGptCredentials(allocator, tokens, credentials_mode);
    }

    if (parsed.value.OPENAI_API_KEY) |api_key| {
        return .{ .mode = .api_key, .token = try allocator.dupe(u8, api_key) };
    }

    if (parsed.value.agent_identity) |agent_identity| {
        return try agentIdentityCredentials(allocator, agent_identity);
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

fn isChatGptAuthTokensMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "chatgptAuthTokens") or std.mem.eql(u8, mode, "chatgpt_auth_tokens");
}

fn agentIdentityCredentials(allocator: std.mem.Allocator, token: []const u8) !Credentials {
    const owned_token = try allocator.dupe(u8, token);
    return try agentIdentityCredentialsFromOwnedToken(allocator, owned_token);
}

fn chatGptCredentials(allocator: std.mem.Allocator, tokens: TokenData, mode: Credentials.Mode) !Credentials {
    const account_id = if (tokens.account_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (account_id) |id| allocator.free(id);

    var claims = if (tokens.id_token) |id_token|
        parseChatGptClaims(allocator, id_token) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => ChatGptClaims{},
        }
    else
        ChatGptClaims{};
    defer claims.deinit(allocator);

    const chatgpt_user_id = claims.chatgpt_user_id;
    claims.chatgpt_user_id = null;
    errdefer if (chatgpt_user_id) |id| allocator.free(id);

    return .{
        .mode = mode,
        .token = try allocator.dupe(u8, tokens.access_token),
        .account_id = account_id,
        .chatgpt_user_id = chatgpt_user_id,
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
    const chatgpt_user_id = claims.chatgpt_user_id;
    claims.chatgpt_user_id = null;
    return .{
        .mode = .agent_identity,
        .token = token,
        .account_id = account_id,
        .chatgpt_user_id = chatgpt_user_id,
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

    const chatgpt_user_id = try parseFirstStringClaim(allocator, object, &.{ "chatgpt_user_id", "user_id" });
    errdefer if (chatgpt_user_id) |id| allocator.free(id);

    const fedramp = if (object.get("chatgpt_account_is_fedramp")) |value|
        value == .bool and value.bool
    else
        false;

    return .{ .account_id = account_id, .chatgpt_user_id = chatgpt_user_id, .fedramp = fedramp };
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

fn refreshChatGptAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
    auth_json: AuthJson,
) !void {
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
        .OPENAI_API_KEY = auth_json.OPENAI_API_KEY,
        .tokens = .{
            .id_token = refreshed_id,
            .access_token = refreshed_access,
            .refresh_token = refreshed_refresh,
            .account_id = account_id,
        },
        .last_refresh = last_refresh,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(output);

    try writeAuthJsonWithMode(allocator, codex_home, store_mode, output);
}

fn refreshTokenEndpoint(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, refresh_token_url_override_env)) |override| return override;
    return allocator.dupe(u8, refresh_token_url);
}

fn postJson(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) !HttpResponse {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    return postJsonWithIo(allocator, io_instance.io(), url, payload);
}

fn postJsonWithTimeout(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, timeout_ms: u64) !HttpResponse {
    var io_instance: std.Io.Threaded = .init(allocator, .{ .async_limit = .limited(1) });
    defer io_instance.deinit();
    const io = io_instance.io();
    var context = PostJsonTimeoutContext{
        .allocator = allocator,
        .io = io,
        .url = url,
        .payload = payload,
    };
    var future = try io.concurrent(postJsonTimeoutWorker, .{&context});
    const deadline = requestDeadline(io, timeout_ms);
    while (true) {
        context.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (context.done.isSet()) break;
                const now = std.Io.Clock.Timestamp.now(io, .awake);
                if (std.Io.Clock.Timestamp.compare(now, .lt, deadline)) continue;
                _ = future.cancel(io);
                if (context.result) |response| response.deinit(allocator);
                return error.Timeout;
            },
            else => |e| {
                _ = future.cancel(io);
                if (context.result) |response| response.deinit(allocator);
                return e;
            },
        };
        break;
    }
    _ = future.await(io);
    if (context.result) |response| return response;
    return context.err orelse error.Canceled;
}

fn postJsonTimeoutWorker(context: *PostJsonTimeoutContext) void {
    defer context.done.set(context.io);
    context.result = postJsonWithIo(context.allocator, context.io, context.url, context.payload) catch |err| {
        context.err = err;
        return;
    };
}

fn requestDeadline(io: std.Io, timeout_ms: u64) std.Io.Clock.Timestamp {
    const timeout_ms_i64 = std.math.cast(i64, timeout_ms) orelse std.math.maxInt(i64);
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms_i64),
        .clock = .awake,
    });
}

fn postJsonWithIo(allocator: std.mem.Allocator, io: std.Io, url: []const u8, payload: []const u8) !HttpResponse {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });

    var client = std.http.Client{ .allocator = allocator, .io = io };
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
    return writeAuthJsonFile(allocator, codex_home, json);
}

pub fn writeAuthJsonWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
    json: []const u8,
) !void {
    switch (store_mode) {
        .file => return writeAuthJsonFile(allocator, codex_home, json),
        .keyring => return writeCliAuthKeyringJsonAndRemoveFile(allocator, codex_home, json),
        .auto => {
            writeCliAuthKeyringJsonAndRemoveFile(allocator, codex_home, json) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return writeAuthJsonFile(allocator, codex_home, json),
            };
        },
        .ephemeral => return writeEphemeralAuthJson(allocator, codex_home, json),
    }
}

fn writeAuthJsonFile(allocator: std.mem.Allocator, codex_home: []const u8, json: []const u8) !void {
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

pub fn saveApiKeyAuthJson(allocator: std.mem.Allocator, codex_home: []const u8, api_key: []const u8) !void {
    return saveApiKeyAuth(allocator, codex_home, .file, api_key);
}

pub fn saveApiKeyAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
    api_key: []const u8,
) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "apikey",
        .OPENAI_API_KEY = api_key,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeAuthJsonWithMode(allocator, codex_home, store_mode, json);
}

pub fn saveChatGptAuthTokensJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    access_token: []const u8,
    chatgpt_account_id: []const u8,
) !void {
    return saveChatGptAuthTokensJsonWithMode(allocator, codex_home, .file, access_token, chatgpt_account_id, null);
}

pub fn saveChatGptAuthTokensJsonWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
    access_token: []const u8,
    chatgpt_account_id: []const u8,
    chatgpt_plan_type: ?[]const u8,
) !void {
    _ = store_mode;
    var claims = try parseChatGptClaims(allocator, access_token);
    defer claims.deinit(allocator);
    const plan_type = if (chatgpt_plan_type) |value| try normalizeChatGptPlanType(allocator, value) else null;
    defer if (plan_type) |value| allocator.free(value);

    const last_refresh = try currentRfc3339(allocator);
    defer allocator.free(last_refresh);

    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "chatgptAuthTokens",
        .tokens = .{
            .id_token = access_token,
            .access_token = access_token,
            .refresh_token = "",
            .account_id = chatgpt_account_id,
            .chatgpt_plan_type = plan_type orelse claims.plan_type,
        },
        .last_refresh = last_refresh,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(json);
    try writeAuthJsonWithMode(allocator, codex_home, .ephemeral, json);
}

pub fn logoutWithRevoke(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    return logoutWithRevokeWithMode(allocator, codex_home, .file);
}

pub fn logoutWithRevokeWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !bool {
    if (store_mode == .ephemeral) {
        revokeStoredAuthTokensWithMode(allocator, codex_home, .ephemeral) catch {};
        return deleteAuthWithMode(allocator, codex_home, .ephemeral);
    }

    revokeStoredAuthTokensWithMode(allocator, codex_home, store_mode) catch {};
    const ephemeral_removed = try deleteAuthWithMode(allocator, codex_home, .ephemeral);
    const managed_removed = try deleteAuthWithMode(allocator, codex_home, store_mode);
    return ephemeral_removed or managed_removed;
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

fn deleteAuthWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !bool {
    return switch (store_mode) {
        .file => deleteAuthJson(allocator, codex_home),
        .keyring => deleteCliAuthKeyringJsonAndFile(allocator, codex_home),
        .auto => deleteCliAuthAuto(allocator, codex_home),
        .ephemeral => deleteEphemeralAuthJson(allocator, codex_home),
    };
}

fn deleteCliAuthAuto(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const keyring_removed = deleteCliAuthKeyringJsonAndFile(allocator, codex_home) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return deleteAuthJson(allocator, codex_home),
    };
    return keyring_removed;
}

fn readAuthJsonBytesWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !?[]const u8 {
    return switch (store_mode) {
        .file => readAuthJsonFileBytes(allocator, codex_home),
        .keyring => readCliAuthKeyringJson(allocator, codex_home),
        .auto => readCliAuthAuto(allocator, codex_home),
        .ephemeral => readEphemeralAuthJson(allocator, codex_home),
    };
}

fn readActiveAuthJsonBytesWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !?[]const u8 {
    if (store_mode != .ephemeral) {
        if (try readAuthJsonBytesWithMode(allocator, codex_home, .ephemeral)) |bytes| return bytes;
    }
    return readAuthJsonBytesWithMode(allocator, codex_home, store_mode);
}

fn readCliAuthAuto(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    if (readCliAuthKeyringJson(allocator, codex_home)) |bytes| {
        if (bytes) |value| {
            var parsed = std.json.parseFromSlice(AuthJson, allocator, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    allocator.free(value);
                    return readAuthJsonFileBytes(allocator, codex_home);
                },
            };
            parsed.deinit();
            return value;
        }
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
    return readAuthJsonFileBytes(allocator, codex_home);
}

fn readAuthJsonFileBytes(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn cliAuthKeyringSupported() bool {
    return builtin.os.tag == .macos;
}

fn readCliAuthKeyringJson(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    if (!cliAuthKeyringSupported()) return error.UnsupportedCliAuthKeyring;

    const key = try computeCliAuthStoreKey(allocator, codex_home);
    defer allocator.free(key);
    const argv = [_][]const u8{ security_binary, "find-generic-password", "-w", "-s", cli_auth_keyring_service, "-a", key };
    var result = try runSecurityCommand(allocator, argv[0..]);
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {
                const serialized = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (serialized.len == 0) return null;
                return try allocator.dupe(u8, serialized);
            },
            44 => return null,
            else => return error.CliAuthKeyringUnavailable,
        },
        else => return error.CliAuthKeyringUnavailable,
    }
}

fn writeCliAuthKeyringJsonAndRemoveFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    json: []const u8,
) !void {
    try writeCliAuthKeyringJson(allocator, codex_home, json);
    _ = deleteAuthJson(allocator, codex_home) catch false;
}

fn writeCliAuthKeyringJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    json: []const u8,
) !void {
    if (!cliAuthKeyringSupported()) return error.UnsupportedCliAuthKeyring;

    const key = try computeCliAuthStoreKey(allocator, codex_home);
    defer allocator.free(key);
    const serialized = try compactAuthJsonForKeyring(allocator, json);
    defer allocator.free(serialized);

    const argv = cliAuthKeyringWriteArgv(key);
    const term = try runSecurityCommandWithPromptedPassword(allocator, argv[0..], serialized);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CliAuthKeyringUnavailable;
}

fn cliAuthKeyringWriteArgv(key: []const u8) [8][]const u8 {
    return .{ security_binary, "add-generic-password", "-U", "-s", cli_auth_keyring_service, "-a", key, "-w" };
}

fn runSecurityCommandWithPromptedPassword(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    password: []const u8,
) !std.process.Child.Term {
    return runSecurityCommandWithPromptedPasswordTimeout(allocator, argv, password, security_command_timeout_ms);
}

fn runSecurityCommandWithPromptedPasswordTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    password: []const u8,
    timeout_ms: u64,
) !std.process.Child.Term {
    var io_instance: std.Io.Threaded = .init(allocator, .{ .async_limit = .limited(1) });
    defer io_instance.deinit();
    const io = io_instance.io();

    var context = PromptedSecurityCommandContext{
        .io = io,
        .argv = argv,
        .password = password,
    };
    var future = try io.concurrent(promptedSecurityCommandWorker, .{&context});
    const deadline = requestDeadline(io, timeout_ms);
    while (true) {
        context.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (context.done.isSet()) break;
                const now = std.Io.Clock.Timestamp.now(io, .awake);
                if (std.Io.Clock.Timestamp.compare(now, .lt, deadline)) continue;
                _ = future.cancel(io);
                _ = future.await(io);
                return error.Timeout;
            },
            else => |e| {
                _ = future.cancel(io);
                _ = future.await(io);
                return e;
            },
        };
        break;
    }

    _ = future.await(io);
    if (context.term) |term| return term;
    return context.err orelse error.Canceled;
}

fn promptedSecurityCommandWorker(context: *PromptedSecurityCommandContext) void {
    defer context.done.set(context.io);
    context.term = runSecurityCommandWithPromptedPasswordNoTimeout(context.io, context.argv, context.password) catch |err| {
        context.err = err;
        return;
    };
}

fn runSecurityCommandWithPromptedPasswordNoTimeout(
    io: std.Io,
    argv: []const []const u8,
    password: []const u8,
) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var child_alive = true;
    defer if (child_alive) child.kill(io);

    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(io, password);
        try stdin_file.writeStreamingAll(io, "\n");
        try stdin_file.writeStreamingAll(io, password);
        try stdin_file.writeStreamingAll(io, "\n");
        stdin_file.close(io);
        child.stdin = null;
    }

    const term = try child.wait(io);
    child_alive = false;
    return term;
}

fn compactAuthJsonForKeyring(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn deleteCliAuthKeyringJsonAndFile(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const keyring_removed = try deleteCliAuthKeyringJson(allocator, codex_home);
    const file_removed = try deleteAuthJson(allocator, codex_home);
    return keyring_removed or file_removed;
}

fn deleteCliAuthKeyringJson(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    if (!cliAuthKeyringSupported()) return error.UnsupportedCliAuthKeyring;

    const key = try computeCliAuthStoreKey(allocator, codex_home);
    defer allocator.free(key);
    const argv = [_][]const u8{ security_binary, "delete-generic-password", "-s", cli_auth_keyring_service, "-a", key };
    var result = try runSecurityCommand(allocator, argv[0..]);
    defer result.deinit(allocator);
    return classifySecurityGenericPasswordResult(result.term);
}

const SecurityCommandOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    fn deinit(self: *const SecurityCommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runSecurityCommand(allocator: std.mem.Allocator, argv: []const []const u8) !SecurityCommandOutput {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(32 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(5_000),
            .clock = .awake,
        } },
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn classifySecurityGenericPasswordResult(term: std.process.Child.Term) !bool {
    return switch (term) {
        .exited => |code| switch (code) {
            0 => true,
            44 => false,
            else => error.CliAuthKeyringUnavailable,
        },
        else => error.CliAuthKeyringUnavailable,
    };
}

fn computeCliAuthStoreKey(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = if (std.Io.Dir.cwd().realPathFile(std.Io.Threaded.global_single_threaded.io(), codex_home, &path_buffer)) |len|
        try allocator.dupe(u8, path_buffer[0..len])
    else |err| switch (err) {
        else => try allocator.dupe(u8, codex_home),
    };
    defer allocator.free(canonical);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = "0123456789abcdef";
    var prefix: [16]u8 = undefined;
    for (digest[0..8], 0..) |byte, index| {
        prefix[index * 2] = hex[byte >> 4];
        prefix[index * 2 + 1] = hex[byte & 0x0f];
    }
    return std.fmt.allocPrint(allocator, "cli|{s}", .{prefix[0..]});
}

fn readEphemeralAuthJson(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const key = try computeCliAuthStoreKey(allocator, codex_home);
    defer allocator.free(key);

    const io = std.Io.Threaded.global_single_threaded.io();
    ephemeral_auth_mutex.lockUncancelable(io);
    defer ephemeral_auth_mutex.unlock(io);

    const json = ephemeral_auth_store.get(key) orelse return null;
    return try allocator.dupe(u8, json);
}

fn writeEphemeralAuthJson(allocator: std.mem.Allocator, codex_home: []const u8, json: []const u8) !void {
    _ = allocator;
    const page_allocator = std.heap.page_allocator;
    const key = try computeCliAuthStoreKey(page_allocator, codex_home);
    errdefer page_allocator.free(key);
    const value = try page_allocator.dupe(u8, json);
    errdefer page_allocator.free(value);

    const io = std.Io.Threaded.global_single_threaded.io();
    ephemeral_auth_mutex.lockUncancelable(io);
    defer ephemeral_auth_mutex.unlock(io);

    if (ephemeral_auth_store.getEntry(key)) |entry| {
        page_allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = value;
        page_allocator.free(key);
        return;
    }
    try ephemeral_auth_store.put(page_allocator, key, value);
}

fn deleteEphemeralAuthJson(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const key = try computeCliAuthStoreKey(allocator, codex_home);
    defer allocator.free(key);
    const page_allocator = std.heap.page_allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    ephemeral_auth_mutex.lockUncancelable(io);
    defer ephemeral_auth_mutex.unlock(io);

    const entry = ephemeral_auth_store.getEntry(key) orelse return false;
    const stored_key = entry.key_ptr.*;
    const stored_value = entry.value_ptr.*;
    _ = ephemeral_auth_store.remove(key);
    page_allocator.free(stored_key);
    page_allocator.free(stored_value);
    return true;
}

fn revokeStoredAuthTokens(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    return revokeStoredAuthTokensWithMode(allocator, codex_home, .file);
}

fn revokeStoredAuthTokensWithMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: config.AuthCredentialsStoreMode,
) !void {
    const bytes = (try readAuthJsonBytesWithMode(allocator, codex_home, store_mode)) orelse return;
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(AuthJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const token = managedChatGptTokenForRevoke(parsed.value) orelse return;
    try revokeOAuthToken(allocator, token);
}

fn managedChatGptTokenForRevoke(auth_json: AuthJson) ?RevokeToken {
    if (!isManagedChatGptAuth(auth_json)) return null;
    const tokens = auth_json.tokens orelse return null;
    if (tokens.refresh_token) |refresh_token| {
        if (refresh_token.len > 0) return .{ .kind = .refresh, .token = refresh_token };
    }
    if (tokens.access_token.len > 0) return .{ .kind = .access, .token = tokens.access_token };
    return null;
}

fn isManagedChatGptAuth(auth_json: AuthJson) bool {
    if (auth_json.auth_mode) |mode| return isChatGptAuthMode(mode);
    if (auth_json.OPENAI_API_KEY != null) return false;
    return true;
}

fn isChatGptAuthMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "chatgpt");
}

fn revokeOAuthToken(allocator: std.mem.Allocator, token: RevokeToken) !void {
    const endpoint = try revokeTokenEndpoint(allocator);
    defer allocator.free(endpoint);

    const request_body = switch (token.kind) {
        .access => try std.json.Stringify.valueAlloc(allocator, .{
            .token = token.token,
            .token_type_hint = token.kind.tokenTypeHint(),
        }, .{}),
        .refresh => try std.json.Stringify.valueAlloc(allocator, .{
            .token = token.token,
            .token_type_hint = token.kind.tokenTypeHint(),
            .client_id = chatgpt_client_id,
        }, .{}),
    };
    defer allocator.free(request_body);

    const timeout_ms = try revokeRequestTimeoutMs(allocator);
    var response = try postJsonWithTimeout(allocator, endpoint, request_body, timeout_ms);
    defer response.deinit(allocator);
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) return error.RevokeTokenFailed;
}

fn revokeTokenEndpoint(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, revoke_token_url_override_env)) |override| return override;

    if (try env.getOwned(allocator, refresh_token_url_override_env)) |refresh_endpoint| {
        defer allocator.free(refresh_endpoint);
        if (try deriveRevokeTokenEndpoint(allocator, refresh_endpoint)) |endpoint| return endpoint;
    }

    return allocator.dupe(u8, revoke_token_url);
}

fn revokeRequestTimeoutMs(allocator: std.mem.Allocator) !u64 {
    if (try env.getOwned(allocator, revoke_token_timeout_ms_override_env)) |override| {
        defer allocator.free(override);
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        const parsed = std.fmt.parseUnsigned(u64, trimmed, 10) catch return revoke_http_timeout_ms;
        if (parsed > 0) return parsed;
    }
    return revoke_http_timeout_ms;
}

fn deriveRevokeTokenEndpoint(allocator: std.mem.Allocator, refresh_endpoint: []const u8) !?[]const u8 {
    var uri = std.Uri.parse(refresh_endpoint) catch return null;
    uri.path = .{ .percent_encoded = "/oauth/revoke" };
    uri.query = null;
    uri.fragment = null;
    const endpoint = try std.fmt.allocPrint(allocator, "{f}", .{std.Uri.fmt(&uri, .all)});
    return endpoint;
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

    const chatgpt_user_id = try parseFirstStringClaim(allocator, auth_object, &.{ "chatgpt_user_id", "user_id" });
    errdefer if (chatgpt_user_id) |id| allocator.free(id);

    const plan_type = if (auth_object.get("chatgpt_plan_type")) |value|
        if (value == .string) try normalizeChatGptPlanType(allocator, value.string) else null
    else
        null;
    errdefer if (plan_type) |value| allocator.free(value);

    const organization_id = if (auth_object.get("organization_id")) |value|
        if (value == .string) try allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (organization_id) |id| allocator.free(id);

    const project_id = if (auth_object.get("project_id")) |value|
        if (value == .string) try allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (project_id) |id| allocator.free(id);

    const completed_platform_onboarding = if (auth_object.get("completed_platform_onboarding")) |value|
        if (value == .bool) value.bool else null
    else
        null;

    const is_org_owner = if (auth_object.get("is_org_owner")) |value|
        if (value == .bool) value.bool else null
    else
        null;

    const fedramp = if (auth_object.get("chatgpt_account_is_fedramp")) |value|
        value == .bool and value.bool
    else
        false;

    return .{
        .account_id = account_id,
        .chatgpt_user_id = chatgpt_user_id,
        .email = email,
        .plan_type = plan_type,
        .organization_id = organization_id,
        .project_id = project_id,
        .completed_platform_onboarding = completed_platform_onboarding,
        .is_org_owner = is_org_owner,
        .fedramp = fedramp,
    };
}

pub fn parseChatGptRawPlanType(allocator: std.mem.Allocator, jwt: []const u8) !?[]const u8 {
    var parsed = try parseJwtPayload(allocator, jwt);
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;

    const auth_value = object.get("https://api.openai.com/auth") orelse return null;
    if (auth_value != .object) return null;
    const value = auth_value.object.get("chatgpt_plan_type") orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
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

fn parseFirstStringClaim(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    names: []const []const u8,
) !?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string) return try allocator.dupe(u8, value.string);
    }
    return null;
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

fn currentAwakeMillis() i64 {
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds;
    return @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
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

test "cli auth store key uses cli prefix and stable short hash" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    const first = try computeCliAuthStoreKey(allocator, root);
    defer allocator.free(first);
    const second = try computeCliAuthStoreKey(allocator, root);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, "cli|"));
    try std.testing.expectEqual(@as(usize, 20), first.len);
}

test "ephemeral cli auth store is process-local" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    _ = try deleteEphemeralAuthJson(allocator, root);

    try saveApiKeyAuth(allocator, root, .ephemeral, "test-ephemeral-api-key");
    var credentials = (try loadStoredWithMode(allocator, root, .ephemeral)).?;
    defer credentials.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.api_key, credentials.mode);
    try std.testing.expectEqualStrings("test-ephemeral-api-key", credentials.token);
    try std.testing.expect((try loadStored(allocator, root)) == null);

    const path = try std.fs.path.join(allocator, &.{ root, "auth.json" });
    defer allocator.free(path);
    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (file_bytes) |bytes| allocator.free(bytes);
    try std.testing.expect(file_bytes == null);

    try std.testing.expect(try logoutWithRevokeWithMode(allocator, root, .ephemeral));
    try std.testing.expect((try loadStoredWithMode(allocator, root, .ephemeral)) == null);
}

test "cli auth keyring security exit classification" {
    try std.testing.expect(try classifySecurityGenericPasswordResult(.{ .exited = 0 }));
    try std.testing.expect(!(try classifySecurityGenericPasswordResult(.{ .exited = 44 })));
    try std.testing.expectError(error.CliAuthKeyringUnavailable, classifySecurityGenericPasswordResult(.{ .exited = 1 }));
    try std.testing.expectError(error.CliAuthKeyringUnavailable, classifySecurityGenericPasswordResult(.{ .unknown = 9 }));
}

test "cli auth keyring payload is compact json" {
    const allocator = std.testing.allocator;
    const compact = try compactAuthJsonForKeyring(
        allocator,
        "{\n  \"auth_mode\": \"apikey\",\n  \"OPENAI_API_KEY\": \"sk-test\"\n}",
    );
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"sk-test\"}", compact);
}

test "cli auth keyring write argv prompts for password" {
    const argv = cliAuthKeyringWriteArgv("cli|test");
    try std.testing.expectEqualStrings(security_binary, argv[0]);
    try std.testing.expectEqualStrings("-w", argv[argv.len - 1]);
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "secret-auth-json"));
    }
}

test "cli auth prompted keyring write has timeout" {
    const argv = [_][]const u8{ "/bin/sleep", "1" };
    try std.testing.expectError(error.Timeout, runSecurityCommandWithPromptedPasswordTimeout(std.testing.allocator, argv[0..], "secret-auth-json", 10));
}

test "saves externally managed chatgpt auth tokens" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const payload =
        \\{"email":"external@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct_external","chatgpt_user_id":"user_external","organization_id":"org_external","project_id":"proj_external","completed_platform_onboarding":false,"is_org_owner":true}}
    ;
    var encoded_buffer: [512]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);

    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    try saveApiKeyAuthJson(allocator, root, "persistent-api-key");
    try saveChatGptAuthTokensJsonWithMode(allocator, root, .file, jwt, "acct_external", "pro");

    var creds = try load(allocator, root);
    defer creds.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.chatgpt_auth_tokens, creds.mode);
    try std.testing.expectEqualStrings(jwt, creds.token);
    try std.testing.expectEqualStrings("acct_external", creds.account_id.?);
    try std.testing.expectEqualStrings("user_external", creds.chatgpt_user_id.?);

    var file_creds = (try loadStored(allocator, root)).?;
    defer file_creds.deinit(allocator);
    try std.testing.expectEqual(Credentials.Mode.api_key, file_creds.mode);
    try std.testing.expectEqualStrings("persistent-api-key", file_creds.token);

    var info = (try loadActiveStoredChatGptAccountInfoWithMode(allocator, root, .file)).?;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("external@example.com", info.email);
    try std.testing.expectEqualStrings("pro", info.plan_type);

    try std.testing.expect(try logoutWithRevokeWithMode(allocator, root, .file));
    try std.testing.expect((try loadStored(allocator, root)) == null);
    try std.testing.expect((try loadActiveStoredWithMode(allocator, root, .file)) == null);

    var claims = try parseChatGptClaims(allocator, jwt);
    defer claims.deinit(allocator);
    try std.testing.expectEqualStrings("org_external", claims.organization_id.?);
    try std.testing.expectEqualStrings("proj_external", claims.project_id.?);
    try std.testing.expectEqual(false, claims.completed_platform_onboarding.?);
    try std.testing.expectEqual(true, claims.is_org_owner.?);

    try std.testing.expect((try parseChatGptRawPlanType(allocator, jwt)) == null);
}

test "parses chatgpt user id fallback claim" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"https://api.openai.com/auth":{"user_id":"user_fallback"}}
    ;
    var encoded_buffer: [256]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);

    var claims = try parseChatGptClaims(allocator, jwt);
    defer claims.deinit(allocator);
    try std.testing.expectEqualStrings("user_fallback", claims.chatgpt_user_id.?);
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
        \\{"account_id":"acct_agent","chatgpt_user_id":"user_agent","chatgpt_account_is_fedramp":true}
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
    try std.testing.expectEqualStrings("user_agent", creds.chatgpt_user_id.?);
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

test "derives revoke endpoint from refresh endpoint override" {
    const allocator = std.testing.allocator;
    const endpoint = (try deriveRevokeTokenEndpoint(allocator, "http://127.0.0.1:1234/oauth/token?unified=true")).?;
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/oauth/revoke", endpoint);
}

test "managed chatgpt revoke token selection matches Rust logout" {
    const managed_refresh = managedChatGptTokenForRevoke(.{
        .auth_mode = "chatgpt",
        .OPENAI_API_KEY = "preserved-api-key",
        .tokens = .{ .access_token = "access-token", .refresh_token = "refresh-token" },
    }).?;
    try std.testing.expectEqual(RevokeTokenKind.refresh, managed_refresh.kind);
    try std.testing.expectEqualStrings("refresh-token", managed_refresh.token);

    const managed_access = managedChatGptTokenForRevoke(.{
        .auth_mode = "chatgpt",
        .tokens = .{ .access_token = "access-token", .refresh_token = "" },
    }).?;
    try std.testing.expectEqual(RevokeTokenKind.access, managed_access.kind);
    try std.testing.expectEqualStrings("access-token", managed_access.token);

    try std.testing.expect(managedChatGptTokenForRevoke(.{
        .auth_mode = "chatgptAuthTokens",
        .tokens = .{ .access_token = "external-token", .refresh_token = "" },
    }) == null);
    try std.testing.expect(managedChatGptTokenForRevoke(.{
        .OPENAI_API_KEY = "test-api-key",
        .tokens = .{ .access_token = "access-token", .refresh_token = "refresh-token" },
    }) == null);
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

test "provider command credentials refresh when interval expires" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var command = try testCounterProviderAuthCommand(allocator, root, 1000);
    defer command.deinit(allocator);

    var creds = try loadProviderCommandCredentialsAt(allocator, command, 1000);
    defer creds.deinit(allocator);
    try std.testing.expectEqualStrings("token-1", creds.token);
    try std.testing.expectEqual(@as(?i64, 1000), creds.provider_auth_fetched_ms);

    try refreshProviderCommandCredentialsIfExpiredAt(allocator, &creds, command, 1999);
    try std.testing.expectEqualStrings("token-1", creds.token);
    try std.testing.expectEqual(@as(?i64, 1000), creds.provider_auth_fetched_ms);

    try refreshProviderCommandCredentialsIfExpiredAt(allocator, &creds, command, 2000);
    try std.testing.expectEqualStrings("token-2", creds.token);
    try std.testing.expectEqual(@as(?i64, 2000), creds.provider_auth_fetched_ms);
}

test "provider command credentials disable automatic interval refresh at zero" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    var command = try testCounterProviderAuthCommand(allocator, root, 0);
    defer command.deinit(allocator);

    var creds = try loadProviderCommandCredentialsAt(allocator, command, 1000);
    defer creds.deinit(allocator);
    try std.testing.expectEqualStrings("token-1", creds.token);

    try refreshProviderCommandCredentialsIfExpiredAt(allocator, &creds, command, 100_000);
    try std.testing.expectEqualStrings("token-1", creds.token);

    try refreshProviderCommandCredentialsAt(allocator, &creds, command, 100_000);
    try std.testing.expectEqualStrings("token-2", creds.token);
    try std.testing.expectEqual(@as(?i64, 100_000), creds.provider_auth_fetched_ms);
}

fn testCounterProviderAuthCommand(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    refresh_interval_ms: u64,
) !config.ProviderAuthCommand {
    const script =
        \\counter="$0"
        \\if [ -f "$counter" ]; then
        \\  value=$(cat "$counter")
        \\else
        \\  value=0
        \\fi
        \\value=$((value + 1))
        \\printf 'token-%s\n' "$value"
        \\printf '%s\n' "$value" > "$counter"
    ;

    const command_name = try allocator.dupe(u8, "/bin/sh");
    errdefer allocator.free(command_name);
    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);

    const args_items = try allocator.alloc([]const u8, 3);
    var copied: usize = 0;
    errdefer {
        for (args_items[0..copied]) |item| allocator.free(item);
        allocator.free(args_items);
    }
    args_items[0] = try allocator.dupe(u8, "-c");
    copied += 1;
    args_items[1] = try allocator.dupe(u8, script);
    copied += 1;
    args_items[2] = try allocator.dupe(u8, "counter");
    copied += 1;

    return .{
        .command = command_name,
        .args = .{ .items = args_items },
        .cwd = owned_cwd,
        .refresh_interval_ms = refresh_interval_ms,
    };
}
