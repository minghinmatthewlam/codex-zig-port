const std = @import("std");

const auth = @import("auth.zig");
const config = @import("config.zig");

const DEFAULT_ISSUER = "https://auth.openai.com";
pub const default_issuer = DEFAULT_ISSUER;
const DEFAULT_CALLBACK_PORT: u16 = 1455;
const FALLBACK_CALLBACK_PORT: u16 = 1457;
const CALLBACK_HTTP_BUFFER_SIZE: usize = 128 * 1024;
const LOGIN_SCOPE = "openid profile email offline_access api.connectors.read api.connectors.invoke";
pub const missing_authorization_code_message = "Missing authorization code. Sign-in could not be completed.";
pub const missing_codex_entitlement_message = "Codex is not enabled for your workspace. Contact your workspace administrator to request access to Codex.";
const missing_codex_entitlement_code = "missing_codex_entitlement";
const missing_authorization_code = "missing_authorization_code";
const net = std.Io.net;

const LoginArgs = struct {
    help: bool = false,
    status: bool = false,
    with_api_key: bool = false,
    with_access_token: bool = false,
    device_auth: bool = false,
    open_browser: bool = true,
    callback_port: u16 = DEFAULT_CALLBACK_PORT,
    issuer: []const u8 = DEFAULT_ISSUER,
    client_id: []const u8 = auth.chatgpt_client_id,
    force_state: ?[]const u8 = null,
    issuer_owned: bool = false,
    client_id_owned: bool = false,
    force_state_owned: bool = false,

    fn deinit(self: LoginArgs, allocator: std.mem.Allocator) void {
        if (self.issuer_owned) allocator.free(self.issuer);
        if (self.client_id_owned) allocator.free(self.client_id);
        if (self.force_state_owned) allocator.free(self.force_state.?);
    }
};

pub const BrowserAuthOptions = struct {
    codex_home: []const u8,
    issuer: []const u8 = DEFAULT_ISSUER,
    client_id: []const u8 = auth.chatgpt_client_id,
    callback_port: u16 = DEFAULT_CALLBACK_PORT,
    force_state: ?[]const u8 = null,
    forced_chatgpt_workspace_id: ?[]const u8 = null,
    codex_streamlined_login: bool = false,
};

pub const BrowserAuthHandle = struct {
    codex_home: []const u8,
    issuer: []const u8,
    client_id: []const u8,
    callback_server: net.Server,
    redirect_uri: []const u8,
    code_verifier: []const u8,
    state: []const u8,
    auth_url: []const u8,
    actual_port: u16,
    codex_streamlined_login: bool,

    pub fn deinit(self: *BrowserAuthHandle, allocator: std.mem.Allocator) void {
        self.callback_server.deinit(std.Io.Threaded.global_single_threaded.io());
        allocator.free(self.codex_home);
        allocator.free(self.issuer);
        allocator.free(self.client_id);
        allocator.free(self.redirect_uri);
        allocator.free(self.code_verifier);
        allocator.free(self.state);
        allocator.free(self.auth_url);
    }

    pub fn waitAndSave(self: *BrowserAuthHandle, allocator: std.mem.Allocator) !void {
        return waitForBrowserCallback(
            allocator,
            self.codex_home,
            &self.callback_server,
            self.issuer,
            self.client_id,
            self.redirect_uri,
            self.code_verifier,
            self.state,
            self.actual_port,
            self.codex_streamlined_login,
        );
    }
};

pub const DeviceAuthOptions = struct {
    codex_home: []const u8,
    issuer: []const u8 = DEFAULT_ISSUER,
    client_id: []const u8 = auth.chatgpt_client_id,
};

pub const DeviceAuthHandle = struct {
    codex_home: []const u8,
    issuer: []const u8,
    client_id: []const u8,
    device_code: DeviceCode,

    pub fn deinit(self: *DeviceAuthHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        allocator.free(self.issuer);
        allocator.free(self.client_id);
        self.device_code.deinit(allocator);
    }

    pub fn completeAndSave(
        self: *DeviceAuthHandle,
        allocator: std.mem.Allocator,
        cancel_token: ?*const std.atomic.Value(bool),
    ) !void {
        var code = try pollForCodeCancelable(allocator, self.issuer, self.device_code, cancel_token);
        defer code.deinit(allocator);

        const redirect_uri = try std.fmt.allocPrint(allocator, "{s}/deviceauth/callback", .{std.mem.trimEnd(u8, self.issuer, "/")});
        defer allocator.free(redirect_uri);

        var tokens = try exchangeCodeForTokens(allocator, self.issuer, self.client_id, code.authorization_code, redirect_uri, code.code_verifier);
        defer tokens.deinit(allocator);

        try saveChatGptTokens(allocator, self.codex_home, tokens);
    }
};

pub const DeviceCode = struct {
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

const PkceCodes = struct {
    code_verifier: []const u8,
    code_challenge: []const u8,

    fn deinit(self: PkceCodes, allocator: std.mem.Allocator) void {
        allocator.free(self.code_verifier);
        allocator.free(self.code_challenge);
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
        try auth.saveApiKeyAuthJson(allocator, cfg.codex_home, api_key);
        std.debug.print("Successfully logged in\n", .{});
        return;
    }

    if (parsed.with_access_token) {
        const access_token = try readSecretFromStdin(allocator, "No access token provided via stdin.");
        defer allocator.free(access_token);
        try saveAgentIdentity(allocator, cfg.codex_home, access_token);
        std.debug.print("Successfully logged in\n", .{});
        return;
    }

    if (parsed.device_auth) {
        try runDeviceAuth(allocator, cfg.codex_home, parsed.issuer, parsed.client_id);
        std.debug.print("Successfully logged in\n", .{});
        return;
    }

    try runBrowserAuth(allocator, cfg.codex_home, parsed);
    std.debug.print("Successfully logged in\n", .{});
}

pub fn runLogout(allocator: std.mem.Allocator) !void {
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    if (try auth.deleteAuthJson(allocator, cfg.codex_home)) {
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
        if (std.mem.eql(u8, arg, "--with-access-token")) {
            parsed.with_access_token = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--device-auth")) {
            parsed.device_auth = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-browser")) {
            parsed.open_browser = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental_port")) {
            index += 1;
            if (index >= args.len) return error.MissingLoginOptionValue;
            parsed.callback_port = try std.fmt.parseInt(u16, args[index], 10);
            continue;
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
        if (std.mem.eql(u8, arg, "--experimental_state")) {
            index += 1;
            if (index >= args.len) return error.MissingLoginOptionValue;
            if (parsed.force_state_owned) allocator.free(parsed.force_state.?);
            parsed.force_state = try allocator.dupe(u8, args[index]);
            parsed.force_state_owned = true;
            continue;
        }

        std.debug.print("unknown login option: {s}\n", .{arg});
        return error.UnknownLoginOption;
    }

    const login_mode_count: u8 =
        @as(u8, @intFromBool(parsed.with_api_key)) +
        @as(u8, @intFromBool(parsed.with_access_token)) +
        @as(u8, @intFromBool(parsed.device_auth));
    if (login_mode_count > 1) return error.ConflictingLoginModes;
    if (parsed.status and login_mode_count > 0) return error.ConflictingLoginModes;
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
        .chatgpt_auth_tokens => std.debug.print("Logged in using externally managed ChatGPT auth tokens\n", .{}),
        .agent_identity => std.debug.print("Logged in using access token\n", .{}),
        .api_key => {
            const formatted = try safeFormatKey(allocator, credentials.token);
            defer allocator.free(formatted);
            std.debug.print("Logged in using an API key - {s}\n", .{formatted});
        },
        .local_oss => std.debug.print("Using local OSS provider\n", .{}),
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

fn runBrowserAuth(allocator: std.mem.Allocator, codex_home: []const u8, args: LoginArgs) !void {
    var pkce = try generatePkce(allocator);
    defer pkce.deinit(allocator);

    const state = if (args.force_state) |forced|
        try allocator.dupe(u8, forced)
    else
        try randomUrlSafe(allocator, 32);
    defer allocator.free(state);

    var callback_server = try bindCallbackServer(args.callback_port);
    defer callback_server.deinit(std.Io.Threaded.global_single_threaded.io());

    const actual_port = callback_server.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}/auth/callback", .{actual_port});
    defer allocator.free(redirect_uri);

    const authorize_url = try buildAuthorizeUrl(allocator, args.issuer, args.client_id, redirect_uri, pkce, state);
    defer allocator.free(authorize_url);

    if (args.open_browser) {
        openBrowser(allocator, authorize_url) catch |err| {
            std.debug.print("warning: could not open browser automatically: {s}\n", .{@errorName(err)});
        };
    }

    std.debug.print(
        \\Starting local login server on http://localhost:{d}.
        \\If your browser did not open, navigate to this URL to authenticate:
        \\
        \\{s}
        \\
        \\On a remote or headless machine? Use `codex-zig login --device-auth` instead.
        \\
    , .{ actual_port, authorize_url });

    try waitForBrowserCallback(allocator, codex_home, &callback_server, args.issuer, args.client_id, redirect_uri, pkce.code_verifier, state, actual_port, false);
}

pub fn startBrowserAuthReturnUrl(allocator: std.mem.Allocator, options: BrowserAuthOptions) !BrowserAuthHandle {
    var pkce = try generatePkce(allocator);
    defer pkce.deinit(allocator);

    const code_verifier = try allocator.dupe(u8, pkce.code_verifier);
    errdefer allocator.free(code_verifier);

    const state = if (options.force_state) |forced|
        try allocator.dupe(u8, forced)
    else
        try randomUrlSafe(allocator, 32);
    errdefer allocator.free(state);

    var callback_server = try bindCallbackServer(options.callback_port);
    errdefer callback_server.deinit(std.Io.Threaded.global_single_threaded.io());

    const actual_port = callback_server.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}/auth/callback", .{actual_port});
    errdefer allocator.free(redirect_uri);

    const authorize_url = try buildAuthorizeUrlWithOptions(
        allocator,
        options.issuer,
        options.client_id,
        redirect_uri,
        pkce,
        state,
        options.forced_chatgpt_workspace_id,
    );
    errdefer allocator.free(authorize_url);

    const codex_home = try allocator.dupe(u8, options.codex_home);
    errdefer allocator.free(codex_home);
    const issuer = try allocator.dupe(u8, options.issuer);
    errdefer allocator.free(issuer);
    const client_id = try allocator.dupe(u8, options.client_id);
    errdefer allocator.free(client_id);

    return .{
        .codex_home = codex_home,
        .issuer = issuer,
        .client_id = client_id,
        .callback_server = callback_server,
        .redirect_uri = redirect_uri,
        .code_verifier = code_verifier,
        .state = state,
        .auth_url = authorize_url,
        .actual_port = actual_port,
        .codex_streamlined_login = options.codex_streamlined_login,
    };
}

pub fn cancelBrowserAuth(port: u16) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var output_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &output_buffer);
    try writer.interface.writeAll(
        "GET /cancel HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    try writer.interface.flush();
}

pub fn startDeviceAuth(allocator: std.mem.Allocator, options: DeviceAuthOptions) !DeviceAuthHandle {
    var device_code = try requestDeviceCode(allocator, options.issuer, options.client_id);
    errdefer device_code.deinit(allocator);

    const codex_home = try allocator.dupe(u8, options.codex_home);
    errdefer allocator.free(codex_home);
    const issuer = try allocator.dupe(u8, options.issuer);
    errdefer allocator.free(issuer);
    const client_id = try allocator.dupe(u8, options.client_id);
    errdefer allocator.free(client_id);

    return .{
        .codex_home = codex_home,
        .issuer = issuer,
        .client_id = client_id,
        .device_code = device_code,
    };
}

fn bindCallbackServer(port: u16) !net.Server {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    return address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => {
            if (port != DEFAULT_CALLBACK_PORT) return err;
            var fallback: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(FALLBACK_CALLBACK_PORT) };
            return fallback.listen(io, .{ .reuse_address = true });
        },
        else => return err,
    };
}

fn waitForBrowserCallback(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: *net.Server,
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
    expected_state: []const u8,
    actual_port: u16,
    codex_streamlined_login: bool,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var callback_completed = false;
    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var send_buffer: [CALLBACK_HTTP_BUFFER_SIZE]u8 = undefined;
        var recv_buffer: [CALLBACK_HTTP_BUFFER_SIZE]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var http_server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            else => return err,
        };

        const completed = try handleBrowserLoginRequest(
            allocator,
            codex_home,
            &request,
            issuer,
            client_id,
            redirect_uri,
            code_verifier,
            expected_state,
            actual_port,
            codex_streamlined_login,
            &callback_completed,
        );
        if (completed) return;
    }
}

fn handleBrowserLoginRequest(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    request: *std.http.Server.Request,
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
    expected_state: []const u8,
    actual_port: u16,
    codex_streamlined_login: bool,
    callback_completed: *bool,
) !bool {
    const target = request.head.target;
    const path, const query = splitTarget(target);

    if (std.mem.eql(u8, path, "/cancel")) {
        try respondText(request, .ok, "Login cancelled\n");
        return error.LoginCancelled;
    }
    if (std.mem.eql(u8, path, "/success")) {
        if (!callback_completed.*) {
            try respondText(request, .bad_request, "Login has not completed\n");
            return false;
        }
        const success_streamlined = try successPageUsesStreamlinedLogin(allocator, query, codex_streamlined_login);
        try respondText(request, .ok, if (success_streamlined) STREAMLINED_SUCCESS_PAGE else LEGACY_SUCCESS_PAGE);
        return true;
    }
    if (!std.mem.eql(u8, path, "/auth/callback")) {
        try respondText(request, .not_found, "Not Found\n");
        return false;
    }

    const callback_state = try queryParam(allocator, query, "state");
    defer if (callback_state) |value| allocator.free(value);
    if (callback_state == null or !std.mem.eql(u8, callback_state.?, expected_state)) {
        try respondText(request, .bad_request, "State mismatch\n");
        return false;
    }

    const error_code = try queryParam(allocator, query, "error");
    defer if (error_code) |value| allocator.free(value);
    if (error_code) |value| {
        const description = try queryParam(allocator, query, "error_description");
        defer if (description) |text| allocator.free(text);
        const rendered = try renderOAuthCallbackErrorPage(allocator, value, description);
        defer rendered.deinit(allocator);
        try respondText(request, .ok, rendered.html);
        return rendered.failure;
    }

    const code = try queryParam(allocator, query, "code");
    defer if (code) |value| allocator.free(value);
    if (code == null or code.?.len == 0) {
        const page = try renderLoginErrorPage(
            allocator,
            "Sign-in could not be completed",
            missing_authorization_code_message,
            missing_authorization_code,
            missing_authorization_code_message,
            "Return to Codex to retry, switch accounts, or contact your workspace admin if access is restricted.",
        );
        defer allocator.free(page);
        try respondText(request, .ok, page);
        return error.MissingAuthorizationCode;
    }

    var tokens = try exchangeCodeForTokens(allocator, issuer, client_id, code.?, redirect_uri, code_verifier);
    defer tokens.deinit(allocator);

    try saveChatGptTokens(allocator, codex_home, tokens);
    const success_url = try composeSuccessUrl(allocator, actual_port, issuer, tokens, codex_streamlined_login);
    defer allocator.free(success_url);
    callback_completed.* = true;
    try respondRedirect(request, success_url);
    return false;
}

const RenderedLoginError = struct {
    html: []const u8,
    failure: anyerror,

    fn deinit(self: RenderedLoginError, allocator: std.mem.Allocator) void {
        allocator.free(self.html);
    }
};

fn renderOAuthCallbackErrorPage(
    allocator: std.mem.Allocator,
    error_code: []const u8,
    description: ?[]const u8,
) !RenderedLoginError {
    const missing_entitlement = std.mem.eql(u8, error_code, "access_denied") and
        description != null and
        asciiContainsIgnoreCase(description.?, missing_codex_entitlement_code);

    if (missing_entitlement) {
        const html = try renderLoginErrorPage(
            allocator,
            "You do not have access to Codex",
            "This account is not currently authorized to use Codex in this workspace.",
            error_code,
            "Contact your workspace administrator to request access to Codex.",
            "Contact your workspace administrator to get access to Codex, then return to Codex and try again.",
        );
        return .{ .html = html, .failure = error.MissingCodexEntitlement };
    }

    const message = if (description) |text|
        if (text.len > 0)
            try std.fmt.allocPrint(allocator, "Sign-in failed: {s}", .{text})
        else
            try std.fmt.allocPrint(allocator, "Sign-in failed: {s}", .{error_code})
    else
        try std.fmt.allocPrint(allocator, "Sign-in failed: {s}", .{error_code});
    defer allocator.free(message);

    const html = try renderLoginErrorPage(
        allocator,
        "Sign-in could not be completed",
        message,
        error_code,
        description orelse message,
        "Return to Codex to retry, switch accounts, or contact your workspace admin if access is restricted.",
    );
    return .{ .html = html, .failure = error.OAuthCallbackError };
}

fn renderLoginErrorPage(
    allocator: std.mem.Allocator,
    title: []const u8,
    message: []const u8,
    code: []const u8,
    description: []const u8,
    help: []const u8,
) ![]const u8 {
    const escaped_title = try htmlEscapeAlloc(allocator, title);
    defer allocator.free(escaped_title);
    const escaped_message = try htmlEscapeAlloc(allocator, message);
    defer allocator.free(escaped_message);
    const escaped_code = try htmlEscapeAlloc(allocator, code);
    defer allocator.free(escaped_code);
    const escaped_description = try htmlEscapeAlloc(allocator, description);
    defer allocator.free(escaped_description);
    const escaped_help = try htmlEscapeAlloc(allocator, help);
    defer allocator.free(escaped_help);

    return std.fmt.allocPrint(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<title>Codex Sign-in Error</title>
        \\<style>
        \\body{{margin:0;min-height:100vh;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#fff;color:#0d0d0d;display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box;}}
        \\.card{{width:min(680px,100%);border:1px solid rgba(13,13,13,.12);border-radius:16px;box-shadow:0 12px 32px rgba(0,0,0,.06);padding:24px;}}
        \\.brand{{color:#5d5d5d;font-size:14px;}}
        \\h1{{margin:18px 0 10px;font-size:28px;line-height:1.2;}}
        \\.message{{font-size:16px;line-height:1.45;}}
        \\.details{{margin-top:18px;border:1px solid rgba(13,13,13,.1);border-radius:12px;background:#fafafa;padding:14px;display:grid;gap:8px;}}
        \\.row{{display:grid;grid-template-columns:136px 1fr;gap:10px;font-size:13px;align-items:baseline;}}
        \\.row strong{{color:#5d5d5d;}}
        \\code{{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace;word-break:break-all;}}
        \\.help{{margin-top:16px;font-size:14px;color:#5d5d5d;}}
        \\</style>
        \\</head>
        \\<body>
        \\<main class="card">
        \\<div class="brand">Codex login</div>
        \\<h1>{s}</h1>
        \\<p class="message">{s}</p>
        \\<div class="details">
        \\<div class="row"><strong>Error code</strong><code>{s}</code></div>
        \\<div class="row"><strong>Details</strong><code>{s}</code></div>
        \\</div>
        \\<p class="help">{s}</p>
        \\</main>
        \\</body>
        \\</html>
    , .{ escaped_title, escaped_message, escaped_code, escaped_description, escaped_help });
}

fn successPageUsesStreamlinedLogin(
    allocator: std.mem.Allocator,
    query: []const u8,
    default_value: bool,
) !bool {
    const raw = try queryParam(allocator, query, "codex_streamlined_login");
    defer if (raw) |value| allocator.free(value);
    if (raw) |value| {
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }
    return default_value;
}

fn composeSuccessUrl(
    allocator: std.mem.Allocator,
    actual_port: u16,
    issuer: []const u8,
    tokens: Tokens,
    codex_streamlined_login: bool,
) ![]const u8 {
    var id_claims = try parseChatGptClaimsOrEmpty(allocator, tokens.id_token);
    defer id_claims.deinit(allocator);
    const access_plan_type = try parseChatGptRawPlanTypeOrEmpty(allocator, tokens.access_token);
    defer if (access_plan_type) |value| allocator.free(value);
    const id_plan_type = if (access_plan_type == null)
        try parseChatGptRawPlanTypeOrEmpty(allocator, tokens.id_token)
    else
        null;
    defer if (id_plan_type) |value| allocator.free(value);

    const completed_onboarding = id_claims.completed_platform_onboarding orelse false;
    const is_org_owner = id_claims.is_org_owner orelse false;
    const needs_setup = !completed_onboarding and is_org_owner;
    const needs_setup_text = if (needs_setup) "true" else "false";
    const organization_id = id_claims.organization_id orelse "";
    const project_id = id_claims.project_id orelse "";
    const plan_type = access_plan_type orelse id_plan_type orelse "";
    const platform_url = platformUrlForIssuer(issuer);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "http://localhost:{d}/success?", .{actual_port});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);
    var first = true;
    try appendFormField(allocator, &out, &first, "id_token", tokens.id_token);
    try appendFormField(allocator, &out, &first, "needs_setup", needs_setup_text);
    try appendFormField(allocator, &out, &first, "org_id", organization_id);
    try appendFormField(allocator, &out, &first, "project_id", project_id);
    try appendFormField(allocator, &out, &first, "plan_type", plan_type);
    try appendFormField(allocator, &out, &first, "platform_url", platform_url);
    if (codex_streamlined_login) {
        try appendFormField(allocator, &out, &first, "codex_streamlined_login", "true");
    }
    return out.toOwnedSlice(allocator);
}

fn parseChatGptClaimsOrEmpty(allocator: std.mem.Allocator, jwt: []const u8) !auth.ChatGptClaims {
    return auth.parseChatGptClaims(allocator, jwt) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => auth.ChatGptClaims{},
    };
}

fn parseChatGptRawPlanTypeOrEmpty(allocator: std.mem.Allocator, jwt: []const u8) !?[]const u8 {
    return auth.parseChatGptRawPlanType(allocator, jwt) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

fn platformUrlForIssuer(issuer: []const u8) []const u8 {
    if (std.mem.eql(u8, std.mem.trimEnd(u8, issuer, "/"), DEFAULT_ISSUER)) {
        return "https://platform.openai.com";
    }
    return "https://platform.api.openai.org";
}

const LEGACY_SUCCESS_PAGE =
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>Sign into Codex</title></head>
    \\<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
    \\<main style="text-align:center;">
    \\<h1>Signed in to Codex</h1>
    \\<p id="close-message" style="display:none;">You may now close this page</p>
    \\<div id="setup-message" style="display:none;">
    \\<p>Finish setting up your API organization</p>
    \\<p>Add a payment method to use your organization. Redirecting in <span id="countdown">3</span>s...</p>
    \\</div>
    \\</main>
    \\<script>
    \\(function(){
    \\const params=new URLSearchParams(window.location.search);
    \\const needsSetup=params.get('needs_setup')==='true';
    \\if(!needsSetup){document.getElementById('close-message').style.display='block';return;}
    \\document.getElementById('setup-message').style.display='block';
    \\const platformUrl=params.get('platform_url')||'https://platform.openai.com';
    \\const redirectUrl=new URL('/org-setup',platformUrl);
    \\redirectUrl.searchParams.set('p',params.get('plan_type')||'');
    \\redirectUrl.searchParams.set('t',params.get('id_token')||'');
    \\redirectUrl.searchParams.set('with_org',params.get('org_id')||'');
    \\redirectUrl.searchParams.set('project_id',params.get('project_id')||'');
    \\let countdown=3;
    \\function tick(){
    \\document.getElementById('countdown').textContent=String(countdown);
    \\if(countdown===0){window.location.replace(redirectUrl.toString());return;}
    \\countdown-=1;
    \\setTimeout(tick,1000);
    \\}
    \\tick();
    \\})();
    \\</script>
    \\</body>
    \\</html>
;

const STREAMLINED_SUCCESS_PAGE =
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>Signed in to Codex</title></head>
    \\<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
    \\<main style="text-align:center;">
    \\<p id="status-message">You're signed in and may close this tab</p>
    \\<button id="open-codex" type="button" onclick="window.location.href='codex://threads/new'">Open Codex</button>
    \\<div id="setup-message" style="display:none;">
    \\<p>Finish setting up your API organization</p>
    \\<p>Add a payment method to use your organization. Redirecting in <span id="countdown">3</span>s...</p>
    \\</div>
    \\</main>
    \\<script>
    \\(function(){
    \\const params=new URLSearchParams(window.location.search);
    \\const needsSetup=params.get('needs_setup')==='true';
    \\window.history.replaceState(null,'',window.location.pathname);
    \\if(!needsSetup){setTimeout(function(){window.location.href='codex://threads/new';},250);return;}
    \\document.getElementById('status-message').style.display='none';
    \\document.getElementById('open-codex').style.display='none';
    \\document.getElementById('setup-message').style.display='block';
    \\const platformUrl=params.get('platform_url')||'https://platform.openai.com';
    \\const redirectUrl=new URL('/org-setup',platformUrl);
    \\redirectUrl.searchParams.set('p',params.get('plan_type')||'');
    \\redirectUrl.searchParams.set('t',params.get('id_token')||'');
    \\redirectUrl.searchParams.set('with_org',params.get('org_id')||'');
    \\redirectUrl.searchParams.set('project_id',params.get('project_id')||'');
    \\let countdown=3;
    \\function tick(){
    \\document.getElementById('countdown').textContent=String(countdown);
    \\if(countdown===0){window.location.replace(redirectUrl.toString());return;}
    \\countdown-=1;
    \\setTimeout(tick,1000);
    \\}
    \\tick();
    \\})();
    \\</script>
    \\</body>
    \\</html>
;

fn respondRedirect(request: *std.http.Server.Request, location: []const u8) !void {
    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "Location", .value = location },
            .{ .name = "Connection", .value = "close" },
        },
    });
}

fn htmlEscapeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (raw) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn queryParam(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const key_raw, const value_raw = if (std.mem.indexOfScalar(u8, part, '=')) |index|
            .{ part[0..index], part[index + 1 ..] }
        else
            .{ part, "" };
        const key = try percentDecodeQueryComponent(allocator, key_raw);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, name)) continue;
        return try percentDecodeQueryComponent(allocator, value_raw);
    }
    return null;
}

fn splitTarget(target: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{ target[0..index], target[index + 1 ..] };
    }
    return .{ target, "" };
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            .{ .name = "Connection", .value = "close" },
        },
    });
}

fn percentDecodeQueryComponent(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    for (copy) |*byte| {
        if (byte.* == '+') byte.* = ' ';
    }
    const decoded = std.Uri.percentDecodeInPlace(copy);
    if (decoded.ptr != copy.ptr) {
        std.mem.copyForwards(u8, copy[0..decoded.len], decoded);
    }
    if (decoded.len == copy.len) return copy;
    return try allocator.realloc(copy, decoded.len);
}

fn buildAuthorizeUrl(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    pkce: PkceCodes,
    state: []const u8,
) ![]const u8 {
    return buildAuthorizeUrlWithOptions(allocator, issuer, client_id, redirect_uri, pkce, state, null);
}

fn buildAuthorizeUrlWithOptions(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    pkce: PkceCodes,
    state: []const u8,
    forced_chatgpt_workspace_id: ?[]const u8,
) ![]const u8 {
    const base = std.mem.trimEnd(u8, issuer, "/");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, base);
    try out.appendSlice(allocator, "/oauth/authorize?");
    var first = true;
    try appendFormField(allocator, &out, &first, "response_type", "code");
    try appendFormField(allocator, &out, &first, "client_id", client_id);
    try appendFormField(allocator, &out, &first, "redirect_uri", redirect_uri);
    try appendFormField(allocator, &out, &first, "scope", LOGIN_SCOPE);
    try appendFormField(allocator, &out, &first, "code_challenge", pkce.code_challenge);
    try appendFormField(allocator, &out, &first, "code_challenge_method", "S256");
    try appendFormField(allocator, &out, &first, "id_token_add_organizations", "true");
    try appendFormField(allocator, &out, &first, "codex_cli_simplified_flow", "true");
    try appendFormField(allocator, &out, &first, "state", state);
    try appendFormField(allocator, &out, &first, "originator", "codex_cli");
    if (forced_chatgpt_workspace_id) |workspace_id| {
        try appendFormField(allocator, &out, &first, "allowed_workspace_id", workspace_id);
    }
    return out.toOwnedSlice(allocator);
}

fn generatePkce(allocator: std.mem.Allocator) !PkceCodes {
    const code_verifier = try randomUrlSafe(allocator, 64);
    errdefer allocator.free(code_verifier);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code_verifier, &digest, .{});
    const code_challenge = try base64UrlSafeAlloc(allocator, &digest);
    errdefer allocator.free(code_challenge);

    return .{ .code_verifier = code_verifier, .code_challenge = code_challenge };
}

fn randomUrlSafe(allocator: std.mem.Allocator, comptime byte_count: usize) ![]const u8 {
    var bytes: [byte_count]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    return base64UrlSafeAlloc(allocator, &bytes);
}

fn base64UrlSafeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, len);
    errdefer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

fn openBrowser(allocator: std.mem.Allocator, url: []const u8) !void {
    if (@import("builtin").target.os.tag != .macos) return;
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = &.{ "/usr/bin/open", url },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(5000), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.OpenBrowserFailed,
        else => return error.OpenBrowserFailed,
    }
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

    const redirect_uri = try std.fmt.allocPrint(allocator, "{s}/deviceauth/callback", .{std.mem.trimEnd(u8, issuer, "/")});
    defer allocator.free(redirect_uri);

    var tokens = try exchangeCodeForTokens(allocator, issuer, client_id, code.authorization_code, redirect_uri, code.code_verifier);
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
    return pollForCodeCancelable(allocator, issuer, device_code, null);
}

fn pollForCodeCancelable(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    device_code: DeviceCode,
    cancel_token: ?*const std.atomic.Value(bool),
) !CodeSuccess {
    const api_base = try apiAccountsBase(allocator, issuer);
    defer allocator.free(api_base);
    const url = try std.fmt.allocPrint(allocator, "{s}/deviceauth/token", .{api_base});
    defer allocator.free(url);

    const max_wait_seconds: u64 = 15 * 60;
    var waited_seconds: u64 = 0;
    while (waited_seconds < max_wait_seconds) {
        if (cancel_token) |token| {
            if (token.load(.acquire)) return error.DeviceAuthCancelled;
        }

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

        const poll_interval_seconds = @max(device_code.interval_seconds, 1);
        const sleep_for = @min(poll_interval_seconds, max_wait_seconds - waited_seconds);
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            .{ .nanoseconds = @intCast(sleep_for * std.time.ns_per_s) },
            .awake,
        ) catch return error.DeviceAuthInterrupted;
        waited_seconds += sleep_for;

        if (cancel_token) |token| {
            if (token.load(.acquire)) return error.DeviceAuthCancelled;
        }
    }

    return error.DeviceAuthTimedOut;
}

fn exchangeCodeForTokens(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    authorization_code: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
) !Tokens {
    const base = std.mem.trimEnd(u8, issuer, "/");
    const url = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{base});
    defer allocator.free(url);

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

fn saveChatGptTokens(allocator: std.mem.Allocator, codex_home: []const u8, tokens: Tokens) !void {
    var claims = try auth.parseChatGptClaims(allocator, tokens.id_token);
    defer claims.deinit(allocator);

    const last_refresh = try auth.currentRfc3339(allocator);
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
    try auth.writeAuthJson(allocator, codex_home, json);
}

fn saveAgentIdentity(allocator: std.mem.Allocator, codex_home: []const u8, access_token: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .auth_mode = "agentIdentity",
        .agent_identity = access_token,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try auth.writeAuthJson(allocator, codex_home, json);
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

fn appendFormField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, '&');
    }
    try percentEncode(allocator, out, name);
    try out.append(allocator, '=');
    try percentEncode(allocator, out, value);
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

pub fn printLoginHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig login
        \\  codex-zig login --device-auth
        \\  codex-zig login --with-api-key
        \\  codex-zig login --with-access-token
        \\  codex-zig login status
        \\  codex-zig logout
        \\
        \\Options:
        \\  --with-api-key          Read an OpenAI API key from stdin
        \\  --with-access-token     Read an access token from stdin
        \\  --device-auth           Sign in with ChatGPT device code authorization
        \\  --no-browser            Print the ChatGPT login URL without opening it
        \\  --experimental_issuer URL
        \\                          Override OAuth issuer for testing
        \\  --experimental_client-id CLIENT_ID
        \\                          Override OAuth client id for testing
        \\  --experimental_port PORT
        \\                          Override localhost callback port for testing
        \\  --experimental_state STATE
        \\                          Override OAuth state for testing
        \\
    , .{});
}

test "safe api key formatting matches codex cli shape" {
    const allocator = std.testing.allocator;
    const formatted = try safeFormatKey(allocator, "test-api-key-12345ABCDE");
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("test-api***ABCDE", formatted);

    const short = try safeFormatKey(allocator, "test-key-123");
    defer allocator.free(short);
    try std.testing.expectEqualStrings("***", short);
}

test "rfc3339 timestamp formats epoch seconds" {
    const allocator = std.testing.allocator;
    const formatted = try auth.rfc3339FromSeconds(allocator, 1622924906);
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

    var claims = try auth.parseChatGptClaims(allocator, jwt);
    defer claims.deinit(allocator);
    try std.testing.expectEqualStrings("acct_123", claims.account_id.?);
    try std.testing.expect(claims.fedramp);
}

test "browser authorize url matches codex callback shape" {
    const allocator = std.testing.allocator;
    const url = try buildAuthorizeUrl(allocator, "https://auth.example.test/", "client id", "http://localhost:1455/auth/callback", .{
        .code_verifier = "verifier",
        .code_challenge = "challenge",
    }, "state value");
    defer allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.example.test/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=client%20id") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state%20value") != null);
}

test "query params decode callback values" {
    const allocator = std.testing.allocator;
    const code = (try queryParam(allocator, "code=abc%20123&state=state+value", "code")).?;
    defer allocator.free(code);
    const state = (try queryParam(allocator, "code=abc%20123&state=state+value", "state")).?;
    defer allocator.free(state);

    try std.testing.expectEqualStrings("abc 123", code);
    try std.testing.expectEqualStrings("state value", state);
    try std.testing.expect((try queryParam(allocator, "code=abc", "missing")) == null);
}

test "browser success url includes setup redirect fields" {
    const allocator = std.testing.allocator;
    const id_payload =
        \\{"https://api.openai.com/auth":{"organization_id":"org_123","project_id":"proj_123","completed_platform_onboarding":false,"is_org_owner":true}}
    ;
    const access_payload =
        \\{"https://api.openai.com/auth":{"chatgpt_plan_type":"future_plan"}}
    ;
    var id_buffer: [512]u8 = undefined;
    const id_encoded = std.base64.url_safe_no_pad.Encoder.encode(&id_buffer, id_payload);
    var access_buffer: [512]u8 = undefined;
    const access_encoded = std.base64.url_safe_no_pad.Encoder.encode(&access_buffer, access_payload);
    const id_token = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{id_encoded});
    defer allocator.free(id_token);
    const access_token = try std.fmt.allocPrint(allocator, "header.{s}.sig", .{access_encoded});
    defer allocator.free(access_token);

    const url = try composeSuccessUrl(allocator, 1455, DEFAULT_ISSUER, .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = "refresh",
    }, true);
    defer allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "http://localhost:1455/success?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "needs_setup=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "org_id=org_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "project_id=proj_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "plan_type=future_plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "platform_url=https%3A%2F%2Fplatform.openai.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_streamlined_login=true") != null);
}

test "browser success pages include setup and app redirects" {
    try std.testing.expect(std.mem.indexOf(u8, LEGACY_SUCCESS_PAGE, "needs_setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, LEGACY_SUCCESS_PAGE, "/org-setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, STREAMLINED_SUCCESS_PAGE, "needs_setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, STREAMLINED_SUCCESS_PAGE, "/org-setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, STREAMLINED_SUCCESS_PAGE, "codex://threads/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, STREAMLINED_SUCCESS_PAGE, "history.replaceState") != null);
}

test "login error page escapes callback details" {
    const allocator = std.testing.allocator;
    const page = try renderLoginErrorPage(
        allocator,
        "Sign-in <failed>",
        "Bad & blocked",
        "code\"x",
        "detail <script>",
        "Try 'again'",
    );
    defer allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "Sign-in &lt;failed&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Bad &amp; blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "code&quot;x") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "detail &lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Try &#39;again&#39;") != null);
}

test "oauth entitlement page hides raw entitlement marker" {
    const allocator = std.testing.allocator;
    const rendered = try renderOAuthCallbackErrorPage(
        allocator,
        "access_denied",
        "workspace has missing_codex_entitlement",
    );
    defer rendered.deinit(allocator);

    try std.testing.expect(rendered.failure == error.MissingCodexEntitlement);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "You do not have access to Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "Contact your workspace administrator to request access to Codex.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.html, "missing_codex_entitlement") == null);
}

test "api key login writes auth json load can reuse" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try auth.saveApiKeyAuthJson(allocator, root, "test-api-key");
    var credentials = try auth.load(allocator, root);
    defer credentials.deinit(allocator);
    try std.testing.expectEqual(auth.Credentials.Mode.api_key, credentials.mode);
    try std.testing.expectEqualStrings("test-api-key", credentials.token);
}

test "access token login writes agent identity auth json load can reuse" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);

    try saveAgentIdentity(allocator, root, "agent-token");
    var credentials = try auth.load(allocator, root);
    defer credentials.deinit(allocator);
    try std.testing.expectEqual(auth.Credentials.Mode.agent_identity, credentials.mode);
    try std.testing.expectEqualStrings("agent-token", credentials.token);
}
