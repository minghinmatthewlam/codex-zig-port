const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const DEFAULT_ISSUER = "https://auth.openai.com";

const LoginArgs = struct {
    help: bool = false,
    status: bool = false,
    with_api_key: bool = false,
    device_auth: bool = false,
    issuer: []const u8 = DEFAULT_ISSUER,
    client_id: []const u8 = CLIENT_ID,
    issuer_owned: bool = false,
    client_id_owned: bool = false,

    fn deinit(self: LoginArgs, allocator: std.mem.Allocator) void {
        if (self.issuer_owned) allocator.free(self.issuer);
        if (self.client_id_owned) allocator.free(self.client_id);
    }
};

const DeviceCode = struct {
    verification_url: []const u8,
    user_code: []const u8,
    device_auth_id: []const u8,
    interval_seconds: u64,

    fn deinit(self: DeviceCode, allocator: std.mem.Allocator) void {
        allocator.free(self.verification_url);
        allocator.free(self.user_code);
        allocator.free(self.device_auth_id);
    }
};

const CodeSuccess = struct {
    authorization_code: []const u8,
    code_verifier: []const u8,

    fn deinit(self: CodeSuccess, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization_code);
        allocator.free(self.code_verifier);
    }
};

const Tokens = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,

    fn deinit(self: Tokens, allocator: std.mem.Allocator) void {
        allocator.free(self.id_token);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

const JwtClaims = struct {
    account_id: ?[]const u8 = null,
    fedramp: bool = false,

    fn deinit(self: JwtClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |account_id| allocator.free(account_id);
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,

    fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    const parsed = try parseArgs(allocator, raw_args.items);
    defer parsed.deinit(allocator);

    if (parsed.help) {
        printLoginHelp();
        return;
    }

    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    if (parsed.status) {
        try runStatus(allocator, cfg);
        return;
    }

    if (parsed.with_api_key) {
        const api_key = try readSecretFromStdin(allocator, "No API key provided via stdin.");
        defer allocator.free(api_key);
        try saveApiKey(allocator, cfg.codex_home, api_key);
        std.debug.print("Successfully logged in\n", .{});
        return;
    }

    if (parsed.device_auth or raw_args.items.len == 0) {
        try runDeviceAuth(allocator, cfg.codex_home, parsed.issuer, parsed.client_id);
        std.debug.print("Successfully logged in\n", .{});
        return;
    }

    printLoginHelp();
    return error.InvalidLoginArguments;
}

pub fn runLogout(allocator: std.mem.Allocator) !void {
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    if (try deleteAuthFile(allocator, cfg.codex_home)) {
        std.debug.print("Successfully logged out\n", .{});
    } else {
        std.debug.print("Not logged in\n", .{});
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !LoginArgs {
    var parsed = LoginArgs{};
    errdefer parsed.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "status")) {
            parsed.status = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-api-key")) {
            parsed.with_api_key = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--device-auth")) {
            parsed.device_auth = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-access-token")) {
            std.debug.print("codex-zig login --with-access-token is not implemented yet\n", .{});
            return error.UnsupportedLoginMode;
        }
        if (std.mem.eql(u8, arg, "--experimental_issuer")) {
            index += 1;
            if (index >= args.len) return error.MissingLoginOptionValue;
            if (parsed.issuer_owned) allocator.free(parsed.issuer);
            parsed.issuer = try allocator.dupe(u8, args[index]);
            parsed.issuer_owned = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental_client-id")) {
            index += 1;
            if (index >= args.len) return error.MissingLoginOptionValue;
            if (parsed.client_id_owned) allocator.free(parsed.client_id);
            parsed.client_id = try allocator.dupe(u8, args[index]);
            parsed.client_id_owned = true;
            continue;
        }

        std.debug.print("unknown login option: {s}\n", .{arg});
        return error.UnknownLoginOption;
    }

    if (parsed.with_api_key and parsed.device_auth) return error.ConflictingLoginModes;
    if (parsed.status and (parsed.with_api_key or parsed.device_auth)) return error.ConflictingLoginModes;
    return parsed;
}

fn runStatus(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var credentials = (try auth.loadStored(allocator, cfg.codex_home)) orelse {
        std.debug.print("Not logged in\n", .{});
        std.process.exit(1);
    };
    defer credentials.deinit(allocator);

    switch (credentials.mode) {
        .chatgpt => std.debug.print("Logged in using ChatGPT\n", .{}),
        .api_key => {
            const formatted = try safeFormatKey(allocator, credentials.token);
            defer allocator.free(formatted);
            std.debug.print("Logged in using an API key - {s}\n", .{formatted});
        },
    }
}

fn readSecretFromStdin(allocator: std.mem.Allocator, empty_message: []const u8) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(bytes);

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("{s}\n", .{empty_message});
        return error.EmptyLoginSecret;
    }

    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(bytes);
    return owned;
}

fn runDeviceAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    issuer: []const u8,
    client_id: []const u8,
) !void {
    var device_code = try requestDeviceCode(allocator, issuer, client_id);
    defer device_code.deinit(allocator);

    printDeviceCodePrompt(device_code.verification_url, device_code.user_code);

    var code = try pollForCode(allocator, issuer, device_code);
    defer code.deinit(allocator);

    var tokens = try exchangeCodeForTokens(allocator, issuer, client_id, code.authorization_code, code.code_verifier);
    defer tokens.deinit(allocator);

    try saveChatGptTokens(allocator, codex_home, tokens);
}

fn requestDeviceCode(allocator: std.mem.Allocator, issuer: []const u8, client_id: []const u8) !DeviceCode {
    const api_base = try apiAccountsBase(allocator, issuer);
    defer allocator.free(api_base);
    const url = try std.fmt.allocPrint(allocator, "{s}/deviceauth/usercode", .{api_base});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{ .client_id = client_id }, .{});
    defer allocator.free(body);

    var response = try post(allocator, url, "application/json", body);
    defer response.deinit(allocator);
    if (!statusIsSuccess(response.status)) {
        if (response.status == .not_found) return error.DeviceAuthUnsupported;
        std.debug.print("device code request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return error.DeviceCodeRequestFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);

    const verification_url = try std.fmt.allocPrint(allocator, "{s}/codex/device", .{std.mem.trimEnd(u8, issuer, "/")});
    errdefer allocator.free(verification_url);
    const user_code = try allocator.dupe(u8, try jsonRequiredString(object, "user_code", "usercode"));
    errdefer allocator.free(user_code);
    const device_auth_id = try allocator.dupe(u8, try jsonRequiredString(object, "device_auth_id", null));
    errdefer allocator.free(device_auth_id);

    return .{
        .verification_url = verification_url,
        .user_code = user_code,
        .device_auth_id = device_auth_id,
        .interval_seconds = try jsonInterval(object),
    };
}

fn pollForCode(allocator: std.mem.Allocator, issuer: []const u8, device_code: DeviceCode) !CodeSuccess {
    const api_base = try apiAccountsBase(allocator, issuer);
    defer allocator.free(api_base);
    const url = try std.fmt.allocPrint(allocator, "{s}/deviceauth/token", .{api_base});
    defer allocator.free(url);

    const max_wait_seconds: u64 = 15 * 60;
    var waited_seconds: u64 = 0;
    while (waited_seconds < max_wait_seconds) {
        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .device_auth_id = device_code.device_auth_id,
            .user_code = device_code.user_code,
        }, .{});
        defer allocator.free(body);

        var response = try post(allocator, url, "application/json", body);
        defer response.deinit(allocator);
        if (statusIsSuccess(response.status)) {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
            defer parsed.deinit();
            const object = try jsonObject(parsed.value);
            const authorization_code = try allocator.dupe(u8, try jsonRequiredString(object, "authorization_code", null));
            errdefer allocator.free(authorization_code);
            const code_verifier = try allocator.dupe(u8, try jsonRequiredString(object, "code_verifier", null));
            errdefer allocator.free(code_verifier);
            return .{ .authorization_code = authorization_code, .code_verifier = code_verifier };
        }

        if (response.status != .forbidden and response.status != .not_found) {
            std.debug.print("device auth failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.DeviceAuthFailed;
        }

        const sleep_for = @min(device_code.interval_seconds, max_wait_seconds - waited_seconds);
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            .{ .nanoseconds = @intCast(sleep_for * std.time.ns_per_s) },
            .awake,
        ) catch return error.DeviceAuthInterrupted;
        waited_seconds += sleep_for;
    }

    return error.DeviceAuthTimedOut;
}

fn exchangeCodeForTokens(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
) !Tokens {
    const base = std.mem.trimEnd(u8, issuer, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{base});
    defer allocator.free(url);

    const redirect_uri = try std.fmt.allocPrint(allocator, "{s}/deviceauth/callback", .{base});
    defer allocator.free(redirect_uri);

    const body = try formEncode(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = authorization_code },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "code_verifier", .value = code_verifier },
    });
    defer allocator.free(body);

    var response = try post(allocator, url, "application/x-www-form-urlencoded", body);
    defer response.deinit(allocator);
    if (!statusIsSuccess(response.status)) {
        std.debug.print("token exchange failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return error.TokenExchangeFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);
    const id_token = try allocator.dupe(u8, try jsonRequiredString(object, "id_token", null));
    errdefer allocator.free(id_token);
    const access_token = try allocator.dupe(u8, try jsonRequiredString(object, "access_token", null));
    errdefer allocator.free(access_token);
    const refresh_token = try allocator.dupe(u8, try jsonRequiredString(object, "refresh_token", null));
    errdefer allocator.free(refresh_token);
    return .{ .id_token = id_token, .access_token = access_token, .refresh_token = refresh_token };
}

fn post(allocator: std.mem.Allocator, url: []const u8, content_type: []const u8, payload: []const u8) !HttpResponse {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = content_type });
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

fn saveApiKey(allocator: std.mem.Allocator, codex_home: []const u8, api_key: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "apikey",
        .OPENAI_API_KEY = api_key,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeAuthJson(allocator, codex_home, json);
}

fn saveChatGptTokens(allocator: std.mem.Allocator, codex_home: []const u8, tokens: Tokens) !void {
    var claims = try parseJwtClaims(allocator, tokens.id_token);
    defer claims.deinit(allocator);

    const last_refresh = try currentRfc3339(allocator);
    defer allocator.free(last_refresh);

    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "chatgpt",
        .tokens = .{
            .id_token = tokens.id_token,
            .access_token = tokens.access_token,
            .refresh_token = tokens.refresh_token,
            .account_id = claims.account_id,
        },
        .last_refresh = last_refresh,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(json);
    try writeAuthJson(allocator, codex_home, json);
}

fn writeAuthJson(allocator: std.mem.Allocator, codex_home: []const u8, json: []const u8) !void {
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

fn deleteAuthFile(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "auth.json" });
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn apiAccountsBase(allocator: std.mem.Allocator, issuer: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/accounts", .{std.mem.trimEnd(u8, issuer, "/")});
}

fn statusIsSuccess(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

fn jsonRequiredString(
    object: std.json.ObjectMap,
    primary_key: []const u8,
    alternate_key: ?[]const u8,
) ![]const u8 {
    if (object.get(primary_key)) |value| {
        if (value == .string) return value.string;
    }
    if (alternate_key) |key| {
        if (object.get(key)) |value| {
            if (value == .string) return value.string;
        }
    }
    return error.MissingJsonString;
}

fn jsonObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidJsonObject;
    return value.object;
}

fn jsonInterval(object: std.json.ObjectMap) !u64 {
    const value = object.get("interval") orelse return 5;
    return switch (value) {
        .string => |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10),
        .integer => |number| @intCast(number),
        else => error.InvalidDeviceInterval,
    };
}

fn formEncode(allocator: std.mem.Allocator, pairs: []const struct { name: []const u8, value: []const u8 }) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (pairs, 0..) |pair, index| {
        if (index > 0) try out.append(allocator, '&');
        try percentEncode(allocator, &out, pair.name);
        try out.append(allocator, '=');
        try percentEncode(allocator, &out, pair.value);
    }

    return out.toOwnedSlice(allocator);
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const unreserved =
            (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (unreserved) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn parseJwtClaims(allocator: std.mem.Allocator, jwt: []const u8) !JwtClaims {
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
    const root = try jsonObject(parsed.value);
    const auth_value = root.get("https://api.openai.com/auth") orelse return .{};
    if (auth_value != .object) return .{};
    const auth_object = auth_value.object;

    const account_id = if (auth_object.get("chatgpt_account_id")) |value|
        if (value == .string) try allocator.dupe(u8, value.string) else null
    else
        null;
    errdefer if (account_id) |id| allocator.free(id);

    const fedramp = if (auth_object.get("chatgpt_account_is_fedramp")) |value|
        value == .bool and value.bool
    else
        false;

    return .{ .account_id = account_id, .fedramp = fedramp };
}

fn currentRfc3339(allocator: std.mem.Allocator) ![]const u8 {
    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real);
    const seconds = @as(u64, @intCast(now.toSeconds()));
    return rfc3339FromSeconds(allocator, seconds);
}

fn rfc3339FromSeconds(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
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

fn safeFormatKey(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (key.len <= 13) return allocator.dupe(u8, "***");
    return std.fmt.allocPrint(allocator, "{s}***{s}", .{ key[0..8], key[key.len - 5 ..] });
}

fn printDeviceCodePrompt(verification_url: []const u8, code: []const u8) void {
    std.debug.print(
        \\
        \\Follow these steps to sign in with ChatGPT using device code authorization:
        \\
        \\1. Open this link in your browser and sign in to your account
        \\   {s}
        \\
        \\2. Enter this one-time code (expires in 15 minutes)
        \\   {s}
        \\
        \\Device codes are a common phishing target. Never share this code.
        \\
    , .{ verification_url, code });
}

fn printLoginHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig login
        \\  codex-zig login --device-auth
        \\  codex-zig login --with-api-key
        \\  codex-zig login status
        \\  codex-zig logout
        \\
        \\Options:
        \\  --with-api-key          Read an OpenAI API key from stdin
        \\  --device-auth           Sign in with ChatGPT device code authorization
        \\  --experimental_issuer URL
        \\                          Override OAuth issuer for testing
        \\  --experimental_client-id CLIENT_ID
        \\                          Override OAuth client id for testing
        \\
    , .{});
}

test "safe api key formatting matches codex cli shape" {
    const allocator = std.testing.allocator;
    const formatted = try safeFormatKey(allocator, "sk-proj-1234567890ABCDE");
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("sk-proj-***ABCDE", formatted);

    const short = try safeFormatKey(allocator, "sk-proj-12345");
    defer allocator.free(short);
    try std.testing.expectEqualStrings("***", short);
}

test "rfc3339 timestamp formats epoch seconds" {
    const allocator = std.testing.allocator;
    const formatted = try rfc3339FromSeconds(allocator, 1622924906);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("2021-06-05T20:28:26Z", formatted);
}

test "jwt parser extracts account metadata" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123","chatgpt_account_is_fedramp":true}}
    ;
    var encoded_buffer: [512]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, payload);
    const jwt = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{encoded});
    defer allocator.free(jwt);

    var claims = try parseJwtClaims(allocator, jwt);
    defer claims.deinit(allocator);
    try std.testing.expectEqualStrings("acct_123", claims.account_id.?);
    try std.testing.expect(claims.fedramp);
}

test "api key login writes auth json load can reuse" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try saveApiKey(allocator, root, "sk-test");
    var credentials = try auth.load(allocator, root);
    defer credentials.deinit(allocator);
    try std.testing.expectEqual(auth.Credentials.Mode.api_key, credentials.mode);
    try std.testing.expectEqualStrings("sk-test", credentials.token);
}
