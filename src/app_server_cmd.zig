const std = @import("std");

const account_nudge = @import("account_nudge.zig");
const account_rate_limits = @import("account_rate_limits.zig");
const auth_mod = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const features_cmd = @import("features_cmd.zig");
const git_remote_diff = @import("git_remote_diff.zig");
const memory_reset = @import("memory_reset.zig");

pub const DEFAULT_LISTEN_URL = "stdio://";
const DEFAULT_SOCKET_DIR_NAME = "app-server-control";
const DEFAULT_SOCKET_FILE_NAME = "app-server-control.sock";
const net = std.Io.net;

const WebsocketAuthMode = enum {
    capability_token,
    signed_bearer_token,
};

const WebsocketAuthArgs = struct {
    ws_auth: ?WebsocketAuthMode = null,
    ws_token_file: ?[]const u8 = null,
    ws_token_sha256: ?[]const u8 = null,
    ws_shared_secret_file: ?[]const u8 = null,
    ws_issuer: ?[]const u8 = null,
    ws_audience: ?[]const u8 = null,
    ws_max_clock_skew_seconds: ?u64 = null,
};

const AppServerOptions = struct {
    listen_url: []const u8 = DEFAULT_LISTEN_URL,
    websocket_auth: WebsocketAuthArgs = .{},
};

const AppServerState = struct {
    runtime_feature_enablement: features_cmd.FeatureOverrides = .{},

    fn deinit(self: *AppServerState, allocator: std.mem.Allocator) void {
        self.runtime_feature_enablement.deinit(allocator);
    }
};

const WebSocketListen = struct {
    host: []const u8,
    port: u16,
};

const Transport = union(enum) {
    stdio,
    off,
    unix_default,
    unix_path: []const u8,
    websocket: WebSocketListen,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var options = AppServerOptions{};
    var subcommand: ?[]const u8 = null;
    var subcommand_args = std.ArrayList([]const u8).empty;
    defer subcommand_args.deinit(allocator);

    while (args.next()) |arg| {
        if (subcommand != null) {
            try subcommand_args.append(allocator, arg);
            continue;
        }
        if (isHelpFlag(arg)) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--listen")) {
            options.listen_url = args.next() orelse return error.MissingAppServerListenValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            options.listen_url = arg["--listen=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--analytics-default-enabled")) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-auth")) {
            options.websocket_auth.ws_auth = try parseWebsocketAuthMode(args.next() orelse return error.MissingAppServerWebsocketAuthMode);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-auth=")) {
            options.websocket_auth.ws_auth = try parseWebsocketAuthMode(arg["--ws-auth=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-token-file")) {
            options.websocket_auth.ws_token_file = args.next() orelse return error.MissingAppServerWebsocketTokenFile;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-token-file=")) {
            options.websocket_auth.ws_token_file = arg["--ws-token-file=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-token-sha256")) {
            options.websocket_auth.ws_token_sha256 = args.next() orelse return error.MissingAppServerWebsocketTokenSha256;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-token-sha256=")) {
            options.websocket_auth.ws_token_sha256 = arg["--ws-token-sha256=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-shared-secret-file")) {
            options.websocket_auth.ws_shared_secret_file = args.next() orelse return error.MissingAppServerWebsocketSharedSecretFile;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-shared-secret-file=")) {
            options.websocket_auth.ws_shared_secret_file = arg["--ws-shared-secret-file=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-issuer")) {
            options.websocket_auth.ws_issuer = args.next() orelse return error.MissingAppServerWebsocketIssuer;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-issuer=")) {
            options.websocket_auth.ws_issuer = arg["--ws-issuer=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-audience")) {
            options.websocket_auth.ws_audience = args.next() orelse return error.MissingAppServerWebsocketAudience;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-audience=")) {
            options.websocket_auth.ws_audience = arg["--ws-audience=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws-max-clock-skew-seconds")) {
            options.websocket_auth.ws_max_clock_skew_seconds = try parseWebsocketClockSkew(args.next() orelse return error.MissingAppServerWebsocketClockSkew);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ws-max-clock-skew-seconds=")) {
            options.websocket_auth.ws_max_clock_skew_seconds = try parseWebsocketClockSkew(arg["--ws-max-clock-skew-seconds=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownAppServerOption;
        }
        if (subcommand != null) return error.UnexpectedAppServerArgument;
        subcommand = arg;
    }

    if (subcommand) |name| {
        if (std.mem.eql(u8, name, "proxy")) {
            try runProxy(allocator, subcommand_args.items);
            return;
        }
        if (std.mem.eql(u8, name, "generate-ts")) return error.AppServerGenerateTsNotImplemented;
        if (std.mem.eql(u8, name, "generate-json-schema")) return error.AppServerGenerateJsonSchemaNotImplemented;
        if (std.mem.eql(u8, name, "generate-internal-json-schema")) return error.AppServerGenerateInternalJsonSchemaNotImplemented;
        return error.UnknownAppServerSubcommand;
    }

    try validateWebsocketAuthArgs(options.websocket_auth);

    const transport = parseTransport(options.listen_url) catch |err| {
        const message = try std.fmt.allocPrint(
            allocator,
            "unsupported --listen URL '{s}', expected `stdio://`, `unix://`, `unix://PATH`, `ws://IP:PORT`, or `off`\n",
            .{options.listen_url},
        );
        defer allocator.free(message);
        try cli_utils.writeStderr(message);
        return err;
    };

    switch (transport) {
        .stdio => {
            var server = StdioServer{ .allocator = allocator };
            try server.run();
        },
        .off => try cli_utils.writeStdout("app-server transport: off\n"),
        .unix_default => {
            const socket_path = try defaultUnixSocketPath(allocator);
            defer allocator.free(socket_path);
            var server = UnixServer{ .allocator = allocator, .socket_path = socket_path };
            try server.run();
        },
        .unix_path => |path| {
            var server = UnixServer{ .allocator = allocator, .socket_path = path };
            try server.run();
        },
        .websocket => {
            const label = try formatTransportLabel(allocator, transport);
            defer allocator.free(label);
            const message = try std.fmt.allocPrint(
                allocator,
                "app-server listen transport is parsed but not implemented yet: {s}\n",
                .{label},
            );
            defer allocator.free(message);
            try cli_utils.writeStderr(message);
            return error.AppServerListenTransportNotImplemented;
        },
    }
}

fn parseWebsocketAuthMode(value: []const u8) !WebsocketAuthMode {
    if (std.mem.eql(u8, value, "capability-token")) return .capability_token;
    if (std.mem.eql(u8, value, "signed-bearer-token")) return .signed_bearer_token;
    return error.UnsupportedAppServerWebsocketAuthMode;
}

fn parseWebsocketClockSkew(value: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidAppServerWebsocketClockSkew;
}

fn validateWebsocketAuthArgs(auth: WebsocketAuthArgs) !void {
    switch (auth.ws_auth orelse {
        if (hasAnyWebsocketAuthModeSpecificFlag(auth)) return error.AppServerWebsocketAuthModeRequired;
        return;
    }) {
        .capability_token => {
            if (auth.ws_shared_secret_file != null or auth.ws_issuer != null or auth.ws_audience != null or auth.ws_max_clock_skew_seconds != null) {
                return error.AppServerWebsocketCapabilityTokenRejectedSignedBearerFlag;
            }
            if (auth.ws_token_file != null and auth.ws_token_sha256 != null) return error.AppServerWebsocketTokenSourcesMutuallyExclusive;
            if (auth.ws_token_file == null and auth.ws_token_sha256 == null) return error.AppServerWebsocketTokenSourceRequired;
            if (auth.ws_token_file) |path| try validateAbsolutePathArg(path);
            if (auth.ws_token_sha256) |digest| try validateSha256DigestArg(digest);
        },
        .signed_bearer_token => {
            if (auth.ws_token_file != null or auth.ws_token_sha256 != null) return error.AppServerWebsocketSignedBearerRejectedCapabilityTokenFlag;
            const shared_secret_file = auth.ws_shared_secret_file orelse return error.AppServerWebsocketSharedSecretFileRequired;
            try validateAbsolutePathArg(shared_secret_file);
        },
    }
}

fn hasAnyWebsocketAuthModeSpecificFlag(auth: WebsocketAuthArgs) bool {
    return auth.ws_token_file != null or
        auth.ws_token_sha256 != null or
        auth.ws_shared_secret_file != null or
        auth.ws_issuer != null or
        auth.ws_audience != null or
        auth.ws_max_clock_skew_seconds != null;
}

fn validateAbsolutePathArg(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.AppServerWebsocketAuthPathMustBeAbsolute;
}

fn validateSha256DigestArg(value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len != 64) return error.AppServerWebsocketAuthSha256DigestInvalid;
    for (trimmed) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return error.AppServerWebsocketAuthSha256DigestInvalid,
        }
    }
}

fn runProxy(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var socket_path_arg: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            printProxyHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--sock")) {
            if (index + 1 >= args.len) return error.MissingAppServerProxySocketPath;
            index += 1;
            socket_path_arg = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sock=")) {
            socket_path_arg = arg["--sock=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppServerProxyOption;
        return error.UnexpectedAppServerProxyArgument;
    }

    const owned_default_path = if (socket_path_arg == null) try defaultUnixSocketPath(allocator) else null;
    defer if (owned_default_path) |path| allocator.free(path);
    const socket_path = socket_path_arg orelse owned_default_path.?;
    try runStdioToUnixSocket(allocator, socket_path);
}

pub fn runStdioToUnixSocket(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var socket_in_buffer: [64 * 1024]u8 = undefined;
    var socket_out_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var socket_reader = stream.reader(io, &socket_in_buffer);
    var socket_writer = stream.writer(io, &socket_out_buffer);

    while (true) {
        const line_opt = try stdin_reader.interface.takeDelimiter('\n');
        const line = line_opt orelse break;
        try writeStreamLine(&socket_writer.interface, line);
        if (!try jsonRpcLineExpectsResponse(allocator, line)) continue;
        const response = try socket_reader.interface.takeDelimiter('\n') orelse break;
        try writeStdoutLine(response);
    }
}

fn jsonRpcLineExpectsResponse(allocator: std.mem.Allocator, line: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    return parsed.value.object.get("id") != null;
}

fn parseTransport(value: []const u8) !Transport {
    if (std.mem.eql(u8, value, "stdio://")) return .stdio;
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "unix://")) return .unix_default;
    if (std.mem.startsWith(u8, value, "unix://")) {
        const path = value["unix://".len..];
        if (path.len == 0) return error.UnsupportedAppServerListenUrl;
        return .{ .unix_path = path };
    }
    if (std.mem.startsWith(u8, value, "ws://")) {
        const address = value["ws://".len..];
        const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.UnsupportedAppServerListenUrl;
        const host = address[0..colon];
        const port_text = address[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.UnsupportedAppServerListenUrl;
        const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.UnsupportedAppServerListenUrl;
        return .{ .websocket = .{ .host = host, .port = port } };
    }
    return error.UnsupportedAppServerListenUrl;
}

fn formatTransportLabel(allocator: std.mem.Allocator, transport: Transport) ![]const u8 {
    return switch (transport) {
        .stdio => allocator.dupe(u8, "stdio://"),
        .off => allocator.dupe(u8, "off"),
        .unix_default => allocator.dupe(u8, "unix://"),
        .unix_path => |path| std.fmt.allocPrint(allocator, "unix://{s}", .{path}),
        .websocket => |address| std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ address.host, address.port }),
    };
}

const StdioServer = struct {
    allocator: std.mem.Allocator,

    fn run(self: *StdioServer) !void {
        var state = AppServerState{};
        defer state.deinit(self.allocator);

        var input_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &input_buffer);

        while (true) {
            const line_opt = try stdin_reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            const response = handleJsonRpcLine(self.allocator, &state, trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[app-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStdoutLine(payload);
            }
        }
    }
};

const UnixServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    fn run(self: *UnixServer) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        try ensureParentDir(io, self.socket_path);
        try deleteSocketFileIfSocket(self.allocator, io, self.socket_path);

        var address = try net.UnixAddress.init(self.socket_path);
        var server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse, error.NotDir => return error.AppServerUnixSocketPathExists,
            else => return err,
        };
        defer server.deinit(io);
        defer deleteSocketFileIfSocket(self.allocator, io, self.socket_path) catch {};

        var state = AppServerState{};
        defer state.deinit(self.allocator);

        var stream = try server.accept(io);
        defer stream.close(io);

        var input_buffer: [64 * 1024]u8 = undefined;
        var output_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &input_buffer);
        var writer = stream.writer(io, &output_buffer);

        while (true) {
            const line_opt = try reader.interface.takeDelimiter('\n');
            const line = line_opt orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            const response = handleJsonRpcLine(self.allocator, &state, trimmed) catch |err| {
                const message = try std.fmt.allocPrint(self.allocator, "[app-server] failed to handle message: {s}\n", .{@errorName(err)});
                defer self.allocator.free(message);
                try cli_utils.writeStderr(message);
                continue;
            };
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStreamLine(&writer.interface, payload);
            }
        }
    }
};

fn handleJsonRpcLine(allocator: std.mem.Allocator, state: *AppServerState, line: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return try renderJsonRpcError(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try renderJsonRpcError(allocator, null, -32600, "Invalid Request");
    }

    const object = parsed.value.object;
    const id_value = object.get("id");
    const method_value = object.get("method") orelse {
        return try renderJsonRpcError(allocator, id_value, -32600, "Invalid Request");
    };
    if (method_value != .string) {
        return try renderJsonRpcError(allocator, id_value, -32600, "Invalid Request");
    }
    if (id_value == null) return null;

    const method = method_value.string;
    if (std.mem.eql(u8, method, "initialize")) {
        const result = try renderInitializeResult(allocator);
        defer allocator.free(result);
        return try renderJsonRpcResult(allocator, id_value.?, result);
    }
    if (std.mem.eql(u8, method, "memory/reset")) {
        return try handleMemoryReset(allocator, id_value.?);
    }
    if (std.mem.eql(u8, method, "gitDiffToRemote")) {
        return try handleGitDiffToRemote(allocator, id_value.?, object.get("params"));
    }
    if (isMarketplaceMethod(method)) {
        return try handleMarketplaceMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isPluginMethod(method)) {
        return try handlePluginMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isFsMethod(method)) {
        return try handleFsMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isConfigMethod(method)) {
        return try handleConfigMethod(allocator, state, id_value.?, method, object.get("params"));
    }
    if (isAccountMethod(method)) {
        return try handleAccountMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isModelMethod(method)) {
        return try handleModelMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isExperimentalFeatureMethod(method)) {
        return try handleExperimentalFeatureMethod(allocator, state, id_value.?, method, object.get("params"));
    }

    const message = try std.fmt.allocPrint(allocator, "unsupported app-server method: {s}", .{method});
    defer allocator.free(message);
    return try renderJsonRpcError(allocator, id_value, -32601, message);
}

fn handleMemoryReset(allocator: std.mem.Allocator, id_value: std.json.Value) ![]const u8 {
    const codex_home = resolveCodexHome(allocator) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to resolve CODEX_HOME", err);
    };
    defer allocator.free(codex_home);

    const state_path = memory_reset.resolveStateDbPath(allocator, codex_home) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to resolve state db path", err);
    };
    defer allocator.free(state_path);

    const state_exists = memory_reset.stateDbExists(allocator, state_path) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to inspect state db", err);
    };
    if (state_exists) {
        const message = try std.fmt.allocPrint(
            allocator,
            "state db found at {s}; Zig memory-state clearing is not implemented yet",
            .{state_path},
        );
        defer allocator.free(message);
        return try renderJsonRpcError(allocator, id_value, -32603, message);
    }

    memory_reset.clearMemoryRootsContents(allocator, codex_home) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to clear memory directories", err);
    };
    return try renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleGitDiffToRemote(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "gitDiffToRemote params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "gitDiffToRemote params must be an object");

    const cwd_value = params.object.get("cwd") orelse return renderJsonRpcError(allocator, id_value, -32602, "cwd must be a string");
    if (cwd_value != .string or cwd_value.string.len == 0) {
        return renderJsonRpcError(allocator, id_value, -32602, "cwd must be a string");
    }

    var diff = git_remote_diff.compute(allocator, cwd_value.string) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const message = try std.fmt.allocPrint(allocator, "failed to compute git diff to remote for cwd: {s}", .{cwd_value.string});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32602, message);
        },
    };
    defer diff.deinit(allocator);

    const sha_json = try std.json.Stringify.valueAlloc(allocator, diff.sha, .{});
    defer allocator.free(sha_json);
    const diff_json = try std.json.Stringify.valueAlloc(allocator, diff.diff, .{});
    defer allocator.free(diff_json);
    const result = try std.fmt.allocPrint(allocator, "{{\"sha\":{s},\"diff\":{s}}}", .{ sha_json, diff_json });
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn isMarketplaceMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "marketplace/add") or
        std.mem.eql(u8, method, "marketplace/remove") or
        std.mem.eql(u8, method, "marketplace/upgrade");
}

fn handleMarketplaceMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "marketplace/add")) {
        if (validateMarketplaceAddParams(params_value)) |message| {
            return try renderJsonRpcError(allocator, id_value, -32602, message);
        }
    } else if (std.mem.eql(u8, method, "marketplace/remove")) {
        if (validateMarketplaceRemoveParams(params_value)) |message| {
            return try renderJsonRpcError(allocator, id_value, -32602, message);
        }
    } else if (std.mem.eql(u8, method, "marketplace/upgrade")) {
        if (validateMarketplaceUpgradeParams(params_value)) |message| {
            return try renderJsonRpcError(allocator, id_value, -32602, message);
        }
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "app-server method {s} is parsed but not implemented yet",
        .{method},
    );
    defer allocator.free(message);
    return try renderJsonRpcError(allocator, id_value, -32603, message);
}

fn validateMarketplaceAddParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "marketplace/add params must be an object";
    if (params != .object) return "marketplace/add params must be an object";
    const object = params.object;
    if (requireStringField(object, "source")) |message| return message;
    if (validateOptionalStringField(object, "refName")) |message| return message;
    if (validateOptionalStringArrayField(object, "sparsePaths")) |message| return message;
    return null;
}

fn validateMarketplaceRemoveParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "marketplace/remove params must be an object";
    if (params != .object) return "marketplace/remove params must be an object";
    return requireStringField(params.object, "marketplaceName");
}

fn validateMarketplaceUpgradeParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return null;
    if (params != .object) return "marketplace/upgrade params must be an object";
    return validateOptionalStringField(params.object, "marketplaceName");
}

fn requireStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return "required string field is missing";
    if (value != .string) return "required field must be a string";
    return null;
}

fn validateOptionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return "optional field must be a string or null";
    return null;
}

fn validateOptionalStringArrayField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .array) return "optional field must be an array of strings or null";
    for (value.array.items) |item| {
        if (item != .string) return "optional field must be an array of strings or null";
    }
    return null;
}

fn isPluginMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "plugin/list") or
        std.mem.eql(u8, method, "plugin/read") or
        std.mem.eql(u8, method, "plugin/skill/read") or
        std.mem.eql(u8, method, "plugin/share/save") or
        std.mem.eql(u8, method, "plugin/share/updateTargets") or
        std.mem.eql(u8, method, "plugin/share/list") or
        std.mem.eql(u8, method, "plugin/share/delete") or
        std.mem.eql(u8, method, "plugin/install") or
        std.mem.eql(u8, method, "plugin/uninstall");
}

fn handlePluginMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (validatePluginParams(method, params_value)) |message| {
        return try renderJsonRpcError(allocator, id_value, -32602, message);
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "app-server method {s} is parsed but not implemented yet",
        .{method},
    );
    defer allocator.free(message);
    return try renderJsonRpcError(allocator, id_value, -32603, message);
}

fn validatePluginParams(method: []const u8, params_value: ?std.json.Value) ?[]const u8 {
    if (std.mem.eql(u8, method, "plugin/list")) return validatePluginListParams(params_value);
    if (std.mem.eql(u8, method, "plugin/read")) return validatePluginReadLikeParams(params_value);
    if (std.mem.eql(u8, method, "plugin/skill/read")) return validatePluginSkillReadParams(params_value);
    if (std.mem.eql(u8, method, "plugin/share/save")) return validatePluginShareSaveParams(params_value);
    if (std.mem.eql(u8, method, "plugin/share/updateTargets")) return validatePluginShareUpdateTargetsParams(params_value);
    if (std.mem.eql(u8, method, "plugin/share/list")) return validateOptionalObjectParams(params_value);
    if (std.mem.eql(u8, method, "plugin/share/delete")) return validatePluginShareDeleteParams(params_value);
    if (std.mem.eql(u8, method, "plugin/install")) return validatePluginReadLikeParams(params_value);
    if (std.mem.eql(u8, method, "plugin/uninstall")) return validatePluginUninstallParams(params_value);
    return "unknown plugin method";
}

fn validatePluginListParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return null;
    if (params == .null) return null;
    if (params != .object) return "plugin/list params must be an object";
    const object = params.object;
    if (validateOptionalStringArrayField(object, "cwds")) |message| return message;
    const kinds = object.get("marketplaceKinds") orelse return null;
    if (kinds == .null) return null;
    if (kinds != .array) return "marketplaceKinds must be an array of strings or null";
    for (kinds.array.items) |item| {
        if (item != .string) return "marketplaceKinds must be an array of strings or null";
        if (!isPluginMarketplaceKind(item.string)) return "unknown marketplace kind";
    }
    return null;
}

fn validatePluginReadLikeParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin params must be an object";
    if (params != .object) return "plugin params must be an object";
    const object = params.object;
    if (requireStringField(object, "pluginName")) |message| return message;
    if (validateOptionalStringField(object, "marketplacePath")) |message| return message;
    if (validateOptionalStringField(object, "remoteMarketplaceName")) |message| return message;
    return null;
}

fn validatePluginSkillReadParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin/skill/read params must be an object";
    if (params != .object) return "plugin/skill/read params must be an object";
    const object = params.object;
    if (requireStringField(object, "remoteMarketplaceName")) |message| return message;
    if (requireStringField(object, "remotePluginId")) |message| return message;
    if (requireStringField(object, "skillName")) |message| return message;
    return null;
}

fn validatePluginShareSaveParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin/share/save params must be an object";
    if (params != .object) return "plugin/share/save params must be an object";
    const object = params.object;
    if (requireStringField(object, "pluginPath")) |message| return message;
    if (validateOptionalStringField(object, "remotePluginId")) |message| return message;
    if (validateOptionalDiscoverabilityField(object, "discoverability")) |message| return message;
    return validateOptionalShareTargetsField(object, "shareTargets");
}

fn validatePluginShareUpdateTargetsParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin/share/updateTargets params must be an object";
    if (params != .object) return "plugin/share/updateTargets params must be an object";
    const object = params.object;
    if (requireStringField(object, "remotePluginId")) |message| return message;
    return validateRequiredShareTargetsField(object, "shareTargets");
}

fn validatePluginShareDeleteParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin/share/delete params must be an object";
    if (params != .object) return "plugin/share/delete params must be an object";
    return requireStringField(params.object, "remotePluginId");
}

fn validatePluginUninstallParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return "plugin/uninstall params must be an object";
    if (params != .object) return "plugin/uninstall params must be an object";
    return requireStringField(params.object, "pluginId");
}

fn validateOptionalObjectParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return null;
    if (params == .null) return null;
    if (params != .object) return "params must be an object";
    return null;
}

fn validateOptionalDiscoverabilityField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return "discoverability must be LISTED, UNLISTED, PRIVATE, or null";
    if (std.mem.eql(u8, value.string, "LISTED") or
        std.mem.eql(u8, value.string, "UNLISTED") or
        std.mem.eql(u8, value.string, "PRIVATE")) return null;
    return "discoverability must be LISTED, UNLISTED, PRIVATE, or null";
}

fn validateRequiredShareTargetsField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return "shareTargets must be an array";
    return validateShareTargetsValue(value);
}

fn validateOptionalShareTargetsField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    return validateShareTargetsValue(value);
}

fn validateShareTargetsValue(value: std.json.Value) ?[]const u8 {
    if (value != .array) return "shareTargets must be an array";
    for (value.array.items) |item| {
        if (item != .object) return "shareTargets entries must be objects";
        const object = item.object;
        if (validatePrincipalTypeField(object, "principalType")) |message| return message;
        if (requireStringField(object, "principalId")) |message| return message;
    }
    return null;
}

fn validatePrincipalTypeField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return "principalType is missing";
    if (value != .string) return "principalType must be user, group, or workspace";
    if (std.mem.eql(u8, value.string, "user") or
        std.mem.eql(u8, value.string, "group") or
        std.mem.eql(u8, value.string, "workspace")) return null;
    return "principalType must be user, group, or workspace";
}

fn isPluginMarketplaceKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "local") or
        std.mem.eql(u8, value, "workspace-directory") or
        std.mem.eql(u8, value, "shared-with-me");
}

const FS_ABSOLUTE_PATH_MESSAGE = "Invalid request: AbsolutePathBuf deserialized without a base path";

const FsObjectParams = union(enum) {
    object: std.json.ObjectMap,
    message: []const u8,
};

const FsStringField = union(enum) {
    value: []const u8,
    message: []const u8,
};

const FsBoolField = union(enum) {
    value: bool,
    message: []const u8,
};

fn isFsMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "fs/readFile") or
        std.mem.eql(u8, method, "fs/writeFile") or
        std.mem.eql(u8, method, "fs/createDirectory") or
        std.mem.eql(u8, method, "fs/getMetadata") or
        std.mem.eql(u8, method, "fs/readDirectory") or
        std.mem.eql(u8, method, "fs/remove") or
        std.mem.eql(u8, method, "fs/copy") or
        std.mem.eql(u8, method, "fs/watch") or
        std.mem.eql(u8, method, "fs/unwatch");
}

fn handleFsMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "fs/readFile")) return handleFsReadFile(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/writeFile")) return handleFsWriteFile(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/createDirectory")) return handleFsCreateDirectory(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/getMetadata")) return handleFsGetMetadata(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/readDirectory")) return handleFsReadDirectory(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/remove")) return handleFsRemove(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/copy")) return handleFsCopy(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/watch")) return handleFsWatch(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/unwatch")) return handleFsUnwatch(allocator, id_value, params_value);
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown filesystem method");
}

fn handleFsReadFile(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/readFile")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/readFile failed", err);
    };
    defer allocator.free(data);

    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    const encoded_json = try std.json.Stringify.valueAlloc(allocator, encoded, .{});
    defer allocator.free(encoded_json);
    const result = try std.fmt.allocPrint(allocator, "{{\"dataBase64\":{s}}}", .{encoded_json});
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleFsWriteFile(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/writeFile")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const data_base64 = switch (requiredStringFieldValue(object, "dataBase64", "fs/writeFile requires string dataBase64")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_base64) catch |err| {
        return renderFsInvalidBase64(allocator, id_value, err);
    };
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, data_base64) catch |err| {
        return renderFsInvalidBase64(allocator, id_value, err);
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = decoded }) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/writeFile failed", err);
    };
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCreateDirectory(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/createDirectory")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    if (recursive) {
        std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "fs/createDirectory failed", err);
        };
    } else {
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "fs/createDirectory failed", err);
        };
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsGetMetadata(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/getMetadata")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const metadata = statPathFollow(allocator, path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/getMetadata failed", err);
    } orelse {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/getMetadata failed", error.FileNotFound);
    };
    const symlink_metadata = statPathNoFollow(allocator, path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/getMetadata failed", err);
    } orelse metadata;
    const mode: u32 = @intCast(metadata.mode);
    const symlink_mode: u32 = @intCast(symlink_metadata.mode);
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"isDirectory\":{},\"isFile\":{},\"isSymlink\":{},\"createdAtMs\":{},\"modifiedAtMs\":{}}}",
        .{
            std.c.S.ISDIR(mode),
            std.c.S.ISREG(mode),
            std.c.S.ISLNK(symlink_mode),
            statCreatedAtMs(metadata),
            timespecToUnixMs(metadata.mtime()),
        },
    );
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleFsReadDirectory(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/readDirectory")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/readDirectory failed", err);
    };
    defer dir.close(io);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"entries\":[");

    var first = true;
    var iter = dir.iterate();
    while (true) {
        const entry = (iter.next(io) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "fs/readDirectory failed", err);
        }) orelse break;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        const metadata = (statPathFollow(allocator, child_path) catch continue) orelse continue;
        const mode: u32 = @intCast(metadata.mode);
        const name_json = try std.json.Stringify.valueAlloc(allocator, entry.name, .{});
        defer allocator.free(name_json);
        const entry_json = try std.fmt.allocPrint(
            allocator,
            "{{\"fileName\":{s},\"isDirectory\":{},\"isFile\":{}}}",
            .{ name_json, std.c.S.ISDIR(mode), std.c.S.ISREG(mode) },
        );
        defer allocator.free(entry_json);
        if (!first) try result.appendSlice(allocator, ",");
        first = false;
        try result.appendSlice(allocator, entry_json);
    }

    try result.appendSlice(allocator, "]}");
    return renderJsonRpcResult(allocator, id_value, result.items);
}

fn handleFsRemove(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/remove")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const force = switch (optionalBoolFieldValue(object, "force", true, true)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const metadata = statPathNoFollow(allocator, path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/remove failed", err);
    } orelse {
        if (force) return renderJsonRpcResult(allocator, id_value, "{}");
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/remove failed", error.FileNotFound);
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    const mode: u32 = @intCast(metadata.mode);
    if (std.c.S.ISDIR(mode)) {
        if (recursive) {
            std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
                return renderJsonRpcErrorForFailure(allocator, id_value, "fs/remove failed", err);
            };
        } else {
            std.Io.Dir.deleteDirAbsolute(io, path) catch |err| {
                return renderJsonRpcErrorForFailure(allocator, id_value, "fs/remove failed", err);
            };
        }
    } else {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "fs/remove failed", err);
        };
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCopy(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/copy")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const source_path = switch (requiredAbsolutePathField(object, "sourcePath")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const destination_path = switch (requiredAbsolutePathField(object, "destinationPath")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const recursive = switch (optionalBoolFieldValue(object, "recursive", false, false)) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    const io = std.Io.Threaded.global_single_threaded.io();
    copyPath(allocator, io, source_path, destination_path, recursive) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "fs/copy failed", err);
    };
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsWatch(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/watch")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    _ = switch (requiredStringFieldValue(object, "watchId", "fs/watch requires string watchId")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    _ = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    return renderParsedButNotImplemented(allocator, id_value, "fs/watch");
}

fn handleFsUnwatch(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/unwatch")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    _ = switch (requiredStringFieldValue(object, "watchId", "fs/unwatch requires string watchId")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    return renderParsedButNotImplemented(allocator, id_value, "fs/unwatch");
}

fn fsObjectParams(params_value: ?std.json.Value, method: []const u8) FsObjectParams {
    const invalid_message = fsObjectParamsMessage(method);
    const params = params_value orelse return .{ .message = invalid_message };
    if (params != .object) return .{ .message = invalid_message };
    return .{ .object = params.object };
}

fn fsObjectParamsMessage(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "fs/copy")) return "fs/copy params must be an object";
    if (std.mem.eql(u8, method, "fs/watch")) return "fs/watch params must be an object";
    if (std.mem.eql(u8, method, "fs/unwatch")) return "fs/unwatch params must be an object";
    return "filesystem params must be an object";
}

fn requiredAbsolutePathField(object: std.json.ObjectMap, field: []const u8) FsStringField {
    const path = switch (requiredStringFieldValue(object, field, "required path field must be an absolute string")) {
        .value => |value| value,
        .message => |message| return .{ .message = message },
    };
    if (!std.fs.path.isAbsolute(path)) return .{ .message = FS_ABSOLUTE_PATH_MESSAGE };
    return .{ .value = path };
}

fn requiredStringFieldValue(object: std.json.ObjectMap, field: []const u8, message: []const u8) FsStringField {
    const value = object.get(field) orelse return .{ .message = message };
    if (value != .string) return .{ .message = message };
    return .{ .value = value.string };
}

fn optionalBoolFieldValue(object: std.json.ObjectMap, field: []const u8, default: bool, null_is_default: bool) FsBoolField {
    const value = object.get(field) orelse return .{ .value = default };
    if (value == .null and null_is_default) return .{ .value = default };
    if (value != .bool) return .{ .message = "optional field must be a boolean" };
    return .{ .value = value.bool };
}

fn optionalNullableBoolField(object: std.json.ObjectMap, field: []const u8, default: bool) FsBoolField {
    const value = object.get(field) orelse return .{ .value = default };
    if (value == .null) return .{ .value = default };
    if (value != .bool) return .{ .message = "optional field must be a boolean" };
    return .{ .value = value.bool };
}

fn renderFsInvalidBase64(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "fs/writeFile requires valid base64 dataBase64: {s}", .{@errorName(err)});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32602, message);
}

fn renderParsedButNotImplemented(allocator: std.mem.Allocator, id_value: std.json.Value, method: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(
        allocator,
        "app-server method {s} is parsed but not implemented yet",
        .{method},
    );
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32603, message);
}

fn copyPath(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, destination_path: []const u8, recursive: bool) !void {
    const metadata = (try statPathNoFollow(allocator, source_path)) orelse return error.FileNotFound;
    const mode: u32 = @intCast(metadata.mode);
    if (std.c.S.ISDIR(mode)) {
        if (!recursive) return error.FsCopyDirectoryRequiresRecursive;
        if (pathIsSameOrDescendant(source_path, destination_path)) return error.FsCopyDestinationInsideSource;
        try std.Io.Dir.cwd().createDirPath(io, destination_path);
        var source_dir = try std.Io.Dir.openDirAbsolute(io, source_path, .{ .iterate = true });
        defer source_dir.close(io);
        var iter = source_dir.iterate();
        while (try iter.next(io)) |entry| {
            const child_source = try std.fs.path.join(allocator, &.{ source_path, entry.name });
            defer allocator.free(child_source);
            const child_destination = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
            defer allocator.free(child_destination);
            try copyPath(allocator, io, child_source, child_destination, recursive);
        }
        return;
    }
    if (std.c.S.ISLNK(mode)) {
        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = try std.Io.Dir.readLinkAbsolute(io, source_path, &target_buffer);
        try std.Io.Dir.cwd().symLink(io, target_buffer[0..target_len], destination_path, .{});
        return;
    }
    if (std.c.S.ISREG(mode)) {
        try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io, .{});
        return;
    }
    return error.FsCopyUnsupportedFileType;
}

fn pathIsSameOrDescendant(source_path: []const u8, destination_path: []const u8) bool {
    const source = std.mem.trimEnd(u8, source_path, std.fs.path.sep_str);
    const destination = std.mem.trimEnd(u8, destination_path, std.fs.path.sep_str);
    if (std.mem.eql(u8, source, destination)) return true;
    if (!std.mem.startsWith(u8, destination, source)) return false;
    if (destination.len <= source.len) return false;
    return destination[source.len] == std.fs.path.sep;
}

fn statCreatedAtMs(stat: std.c.Stat) i64 {
    if (@hasDecl(std.c.Stat, "birthtime")) return timespecToUnixMs(stat.birthtime());
    return 0;
}

fn timespecToUnixMs(value: std.c.timespec) i64 {
    return @as(i64, @intCast(value.sec)) * 1000 + @divTrunc(@as(i64, @intCast(value.nsec)), 1_000_000);
}

fn isConfigMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "config/read") or
        std.mem.eql(u8, method, "configRequirements/read");
}

fn handleConfigMethod(
    allocator: std.mem.Allocator,
    state: *const AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "config/read")) {
        return handleConfigRead(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "configRequirements/read")) {
        return handleConfigRequirementsRead(allocator, id_value, params_value);
    }
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown config method");
}

fn handleConfigRequirementsRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (params_value) |params| {
        if (params != .null) {
            return renderJsonRpcError(allocator, id_value, -32602, "configRequirements/read params must be null or omitted");
        }
    }
    return renderJsonRpcResult(allocator, id_value, "{\"requirements\":null}");
}

fn handleConfigRead(
    allocator: std.mem.Allocator,
    state: *const AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = switch (optionalConfigReadParams(params_value)) {
        .object => |object| object,
        .empty => null,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    var include_layers = false;
    if (params) |object| {
        if (object.get("includeLayers")) |value| {
            if (value != .bool) return renderJsonRpcError(allocator, id_value, -32602, "includeLayers must be a boolean");
            include_layers = value.bool;
        }
        if (object.get("cwd")) |value| {
            if (value != .null and value != .string) return renderJsonRpcError(allocator, id_value, -32602, "cwd must be a string or null");
        }
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to load config", err);
    };
    defer cfg.deinit(allocator);
    var feature_overrides = features_cmd.loadFeatureOverrides(allocator, cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to load feature config", err);
    };
    defer feature_overrides.deinit(allocator);

    const result = try renderConfigReadResponse(allocator, cfg, feature_overrides, state.runtime_feature_enablement, include_layers);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn optionalConfigReadParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "config/read params must be an object" };
    return .{ .object = params.object };
}

fn renderConfigReadResponse(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    config_feature_overrides: features_cmd.FeatureOverrides,
    runtime_feature_enablement: features_cmd.FeatureOverrides,
    include_layers: bool,
) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"config\":{");
    var first = true;
    try appendJsonStringField(allocator, &result, &first, "model", cfg.model);
    try appendJsonMaybeStringField(allocator, &result, &first, "profile", cfg.active_profile);
    try appendJsonStringField(allocator, &result, &first, "approval_policy", cfg.approval_policy.label());
    try appendJsonStringField(allocator, &result, &first, "sandbox_mode", cfg.sandbox_mode.label());
    try appendJsonMaybeStringField(allocator, &result, &first, "web_search", if (cfg.web_search_mode) |mode| mode.label() else null);
    try appendJsonMaybeStringField(allocator, &result, &first, "service_tier", cfg.service_tier);
    try appendJsonMaybeStringField(allocator, &result, &first, "oss_provider", cfg.oss_provider);
    try appendJsonStringField(allocator, &result, &first, "openai_base_url", cfg.openai_base_url);
    try appendJsonStringField(allocator, &result, &first, "chatgpt_base_url", cfg.chatgpt_base_url);
    try appendConfigReadFeaturesField(allocator, &result, &first, config_feature_overrides, runtime_feature_enablement);
    try result.appendSlice(allocator, "},\"origins\":{},\"layers\":");
    try result.appendSlice(allocator, if (include_layers) "[]" else "null");
    try result.appendSlice(allocator, "}");

    return result.toOwnedSlice(allocator);
}

fn appendJsonStringField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: []const u8,
) !void {
    try appendJsonFieldName(allocator, result, first, name);
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    try result.appendSlice(allocator, value_json);
}

fn appendJsonMaybeStringField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |string| {
        try appendJsonStringField(allocator, result, first, name, string);
    } else {
        try appendJsonFieldName(allocator, result, first, name);
        try result.appendSlice(allocator, "null");
    }
}

fn appendConfigReadFeaturesField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    config_feature_overrides: features_cmd.FeatureOverrides,
    runtime_feature_enablement: features_cmd.FeatureOverrides,
) !void {
    try appendJsonFieldName(allocator, result, first, "features");
    try result.appendSlice(allocator, "{");
    for (features_cmd.FeatureSpec.all, 0..) |feature, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        const key_json = try std.json.Stringify.valueAlloc(allocator, feature.key, .{});
        defer allocator.free(key_json);
        const enabled = config_feature_overrides.get(feature.key) orelse
            runtime_feature_enablement.get(feature.key) orelse
            feature.default_enabled;
        try result.appendSlice(allocator, key_json);
        try result.appendSlice(allocator, if (enabled) ":true" else ":false");
    }
    try result.appendSlice(allocator, "}");
}

fn appendJsonFieldName(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try result.appendSlice(allocator, ",");
    }
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    try result.appendSlice(allocator, name_json);
    try result.appendSlice(allocator, ":");
}

fn isAccountMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "account/read") or
        std.mem.eql(u8, method, "getAuthStatus") or
        std.mem.eql(u8, method, "account/login/cancel") or
        std.mem.eql(u8, method, "account/login/start") or
        std.mem.eql(u8, method, "account/rateLimits/read") or
        std.mem.eql(u8, method, "account/sendAddCreditsNudgeEmail") or
        std.mem.eql(u8, method, "account/logout");
}

fn handleAccountMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "account/read")) {
        return handleAccountRead(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "getAuthStatus")) {
        return handleGetAuthStatus(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "account/login/cancel")) {
        return handleAccountLoginCancel(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "account/login/start")) {
        return handleAccountLoginStart(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "account/rateLimits/read")) {
        return handleAccountRateLimitsRead(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "account/sendAddCreditsNudgeEmail")) {
        return handleSendAddCreditsNudgeEmail(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "account/logout")) {
        return handleAccountLogout(allocator, id_value, params_value);
    }
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown account method");
}

fn handleAccountLoginStart(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "account/login/start params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "account/login/start params must be an object");
    const object = params.object;

    const type_value = object.get("type") orelse return renderJsonRpcError(allocator, id_value, -32602, "type must be a string");
    if (type_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "type must be a string");

    const login_type = type_value.string;
    if (!std.mem.eql(u8, login_type, "apiKey")) {
        const message = try std.fmt.allocPrint(
            allocator,
            "account/login/start type {s} is parsed but not implemented yet",
            .{login_type},
        );
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32603, message);
    }

    const api_key_value = object.get("apiKey") orelse return renderJsonRpcError(allocator, id_value, -32602, "apiKey must be a non-empty string");
    if (api_key_value != .string or api_key_value.string.len == 0) {
        return renderJsonRpcError(allocator, id_value, -32602, "apiKey must be a non-empty string");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/login/start failed to load config", err);
    };
    defer cfg.deinit(allocator);

    auth_mod.saveApiKeyAuthJson(allocator, cfg.codex_home, api_key_value.string) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/login/start failed to save API key", err);
    };

    const response = try renderJsonRpcResult(allocator, id_value, "{\"type\":\"apiKey\"}");
    defer allocator.free(response);
    return renderResultWithApiKeyLoginNotifications(allocator, response);
}

fn handleAccountLoginCancel(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "account/login/cancel params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "account/login/cancel params must be an object");

    const login_id_value = params.object.get("loginId") orelse return renderJsonRpcError(allocator, id_value, -32602, "loginId must be a string");
    if (login_id_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "loginId must be a string");
    if (!isUuidString(login_id_value.string)) {
        const message = try std.fmt.allocPrint(allocator, "invalid login id: {s}", .{login_id_value.string});
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }

    return renderJsonRpcResult(allocator, id_value, "{\"status\":\"notFound\"}");
}

fn isUuidString(value: []const u8) bool {
    return switch (value.len) {
        32 => isSimpleUuidString(value),
        36 => isHyphenatedUuidString(value),
        38 => value[0] == '{' and value[37] == '}' and isHyphenatedUuidString(value[1..37]),
        45 => std.mem.startsWith(u8, value, "urn:uuid:") and isHyphenatedUuidString(value[9..]),
        else => false,
    };
}

fn isSimpleUuidString(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isHyphenatedUuidString(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        switch (index) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => if (!std.ascii.isHex(byte)) return false,
        }
    }
    return true;
}

fn handleAccountRateLimitsRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (params_value) |params| {
        if (params != .null) return renderJsonRpcError(allocator, id_value, -32602, "account/rateLimits/read params must be null or omitted");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/rateLimits/read failed to load config", err);
    };
    defer cfg.deinit(allocator);

    var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
        error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "codex account authentication required to read rate limits"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "account/rateLimits/read failed to load auth", err),
    };
    defer credentials.deinit(allocator);

    switch (credentials.mode) {
        .chatgpt, .agent_identity => {},
        .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to read rate limits"),
    }

    const result = account_rate_limits.fetchJson(allocator, cfg.chatgpt_base_url, credentials) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/rateLimits/read failed to fetch codex rate limits", err);
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleSendAddCreditsNudgeEmail(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "account/sendAddCreditsNudgeEmail params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "account/sendAddCreditsNudgeEmail params must be an object");

    const credit_type_value = params.object.get("creditType") orelse return renderJsonRpcError(allocator, id_value, -32602, "creditType must be credits or usage_limit");
    if (credit_type_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "creditType must be credits or usage_limit");
    const credit_type = credit_type_value.string;
    if (!std.mem.eql(u8, credit_type, "credits") and !std.mem.eql(u8, credit_type, "usage_limit")) {
        return renderJsonRpcError(allocator, id_value, -32602, "creditType must be credits or usage_limit");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/sendAddCreditsNudgeEmail failed to load config", err);
    };
    defer cfg.deinit(allocator);

    var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
        error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "codex account authentication required to notify workspace owner"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "account/sendAddCreditsNudgeEmail failed to load auth", err),
    };
    defer credentials.deinit(allocator);

    switch (credentials.mode) {
        .chatgpt, .agent_identity => {},
        .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to notify workspace owner"),
    }

    const status = account_nudge.sendAddCreditsNudgeEmail(allocator, cfg.chatgpt_base_url, credentials, credit_type) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/sendAddCreditsNudgeEmail failed to notify workspace owner", err);
    };
    const result = try std.fmt.allocPrint(allocator, "{{\"status\":\"{s}\"}}", .{status.jsonLabel()});
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleGetAuthStatus(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = switch (optionalGetAuthStatusParams(params_value)) {
        .object => |object| object,
        .empty => null,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    var include_token = false;
    var refresh_token = false;
    if (params) |object| {
        include_token = switch (optionalNullableBoolField(object, "includeToken", false)) {
            .value => |value| value,
            .message => return renderJsonRpcError(allocator, id_value, -32602, "includeToken must be a boolean"),
        };
        refresh_token = switch (optionalNullableBoolField(object, "refreshToken", false)) {
            .value => |value| value,
            .message => return renderJsonRpcError(allocator, id_value, -32602, "refreshToken must be a boolean"),
        };
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "getAuthStatus failed to load config", err);
    };
    defer cfg.deinit(allocator);

    const provider_requires_openai_auth = config.loadModelProviderRequiresOpenAiAuth(allocator, null) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "getAuthStatus failed to load model provider auth requirements", err);
    };
    const requires_openai_auth = cfg.oss_provider == null and provider_requires_openai_auth;
    if (!requires_openai_auth) {
        const result = try renderAuthStatusJson(allocator, null, null, false);
        defer allocator.free(result);
        return renderJsonRpcResult(allocator, id_value, result);
    }

    var credentials = blk: {
        const loaded = if (refresh_token)
            auth_mod.load(allocator, cfg.codex_home)
        else
            auth_mod.loadNoRefresh(allocator, cfg.codex_home);
        break :blk loaded catch |err| switch (err) {
            error.NoUsableAuth => null,
            else => return renderJsonRpcErrorForFailure(allocator, id_value, "getAuthStatus failed to load auth", err),
        };
    };
    defer if (credentials) |*value| value.deinit(allocator);

    const fields = if (credentials) |value|
        authStatusFields(value, include_token)
    else
        AuthStatusFields{};
    const result = try renderAuthStatusJson(allocator, fields.auth_method, fields.auth_token, true);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn optionalGetAuthStatusParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "getAuthStatus params must be an object" };
    return .{ .object = params.object };
}

const AuthStatusFields = struct {
    auth_method: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
};

fn authStatusFields(credentials: auth_mod.Credentials, include_token: bool) AuthStatusFields {
    return switch (credentials.mode) {
        .api_key, .chatgpt => if (credentials.token.len == 0)
            .{}
        else
            .{
                .auth_method = authMethodLabel(credentials.mode),
                .auth_token = if (include_token) credentials.token else null,
            },
        .agent_identity => .{ .auth_method = authMethodLabel(credentials.mode) },
        .local_oss => .{},
    };
}

fn authMethodLabel(mode: auth_mod.Credentials.Mode) ?[]const u8 {
    return switch (mode) {
        .api_key => "apikey",
        .chatgpt => "chatgpt",
        .agent_identity => "agentIdentity",
        .local_oss => null,
    };
}

fn renderAuthStatusJson(
    allocator: std.mem.Allocator,
    auth_method: ?[]const u8,
    auth_token: ?[]const u8,
    requires_openai_auth: bool,
) ![]const u8 {
    const auth_method_json = if (auth_method) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(auth_method_json);

    const auth_token_json = if (auth_token) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(auth_token_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"authMethod\":{s},\"authToken\":{s},\"requiresOpenaiAuth\":{}}}",
        .{ auth_method_json, auth_token_json, requires_openai_auth },
    );
}

fn handleAccountLogout(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (params_value) |params| {
        if (params != .null) return renderJsonRpcError(allocator, id_value, -32602, "account/logout params must be null or omitted");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/logout failed to load config", err);
    };
    defer cfg.deinit(allocator);

    _ = auth_mod.deleteAuthJson(allocator, cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/logout failed to delete auth", err);
    };

    const response = try renderJsonRpcResult(allocator, id_value, "{}");
    defer allocator.free(response);
    return renderResultWithAccountUpdatedNotification(allocator, response);
}

fn handleAccountRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = switch (optionalAccountReadParams(params_value)) {
        .object => |object| object,
        .empty => null,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    var refresh_token = false;
    if (params) |object| {
        if (object.get("refreshToken")) |value| {
            if (value != .bool) return renderJsonRpcError(allocator, id_value, -32602, "refreshToken must be a boolean");
            refresh_token = value.bool;
        }
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/read failed to load config", err);
    };
    defer cfg.deinit(allocator);

    const model_provider = config.loadModelProviderId(allocator, null) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/read failed to load model provider", err);
    };
    defer if (model_provider) |value| allocator.free(value);

    const is_bedrock = if (model_provider) |provider| std.mem.eql(u8, provider, "amazon-bedrock") else false;
    const provider_requires_openai_auth = config.loadModelProviderRequiresOpenAiAuth(allocator, null) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/read failed to load model provider auth requirements", err);
    };
    const requires_openai_auth = cfg.oss_provider == null and provider_requires_openai_auth;
    const account_json = if (requires_openai_auth)
        try renderOpenAiAccountJson(allocator, cfg.codex_home, refresh_token)
    else if (is_bedrock)
        try allocator.dupe(u8, "{\"type\":\"amazonBedrock\"}")
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(account_json);

    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"account\":{s},\"requiresOpenaiAuth\":{}}}",
        .{ account_json, requires_openai_auth },
    );
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn optionalAccountReadParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "account/read params must be an object" };
    return .{ .object = params.object };
}

fn renderOpenAiAccountJson(allocator: std.mem.Allocator, codex_home: []const u8, refresh_token: bool) ![]const u8 {
    var credentials = blk: {
        const loaded = if (refresh_token)
            auth_mod.load(allocator, codex_home)
        else
            auth_mod.loadNoRefresh(allocator, codex_home);
        break :blk loaded catch |err| switch (err) {
            error.NoUsableAuth => return allocator.dupe(u8, "null"),
            else => return err,
        };
    };
    defer credentials.deinit(allocator);

    switch (credentials.mode) {
        .api_key => return allocator.dupe(u8, "{\"type\":\"apiKey\"}"),
        .chatgpt, .agent_identity => {
            if (try auth_mod.loadStoredChatGptAccountInfo(allocator, codex_home)) |info| {
                defer info.deinit(allocator);
                return renderChatGptAccountJson(allocator, info);
            }
            return allocator.dupe(u8, "null");
        },
        .local_oss => return allocator.dupe(u8, "null"),
    }
}

fn renderChatGptAccountJson(allocator: std.mem.Allocator, info: auth_mod.ChatGptAccountInfo) ![]const u8 {
    const email_json = try std.json.Stringify.valueAlloc(allocator, info.email, .{});
    defer allocator.free(email_json);
    const plan_type_json = try std.json.Stringify.valueAlloc(allocator, info.plan_type, .{});
    defer allocator.free(plan_type_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"chatgpt\",\"email\":{s},\"planType\":{s}}}",
        .{ email_json, plan_type_json },
    );
}

fn renderResultWithAccountUpdatedNotification(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n{{\"method\":\"account/updated\",\"params\":{{\"authMode\":null,\"planType\":null}}}}",
        .{response},
    );
}

fn renderResultWithApiKeyLoginNotifications(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n{{\"method\":\"account/login/completed\",\"params\":{{\"loginId\":null,\"success\":true,\"error\":null}}}}\n{{\"method\":\"account/updated\",\"params\":{{\"authMode\":\"apikey\",\"planType\":null}}}}",
        .{response},
    );
}

fn isModelMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "model/list") or
        std.mem.eql(u8, method, "modelProvider/capabilities/read");
}

fn handleModelMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "model/list")) return handleModelList(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "modelProvider/capabilities/read")) {
        return handleModelProviderCapabilitiesRead(allocator, id_value, params_value);
    }
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown model method");
}

fn handleModelList(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = switch (optionalModelListParams(params_value)) {
        .object => |object| object,
        .empty => null,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    var cursor: ?[]const u8 = null;
    var limit: ?usize = null;
    if (params) |object| {
        if (object.get("cursor")) |value| {
            if (value != .null) {
                if (value != .string) return renderJsonRpcError(allocator, id_value, -32602, "cursor must be a string or null");
                cursor = value.string;
            }
        }
        if (object.get("limit")) |value| {
            limit = switch (value) {
                .null => null,
                .integer => |integer| blk: {
                    if (integer < 0) return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null");
                    break :blk @intCast(integer);
                },
                .number_string => |number| std.fmt.parseUnsigned(usize, number, 10) catch {
                    return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null");
                },
                else => return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null"),
            };
        }
        _ = switch (optionalBoolFieldValue(object, "includeHidden", false, true)) {
            .value => |value| value,
            .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
        };
    }

    const start = if (cursor) |value|
        std.fmt.parseUnsigned(usize, value, 10) catch {
            const message = try std.fmt.allocPrint(allocator, "invalid cursor: {s}", .{value});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }
    else
        0;

    const total: usize = 1;
    if (start > total) {
        const message = try std.fmt.allocPrint(allocator, "cursor {d} exceeds total models {d}", .{ start, total });
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "model/list failed to load config", err);
    };
    defer cfg.deinit(allocator);

    const effective_limit = @min(@max(limit orelse total, 1), total);
    const end = @min(start + effective_limit, total);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"data\":[");
    if (start < end) {
        try appendConfiguredModelJson(allocator, &result, cfg.model);
    }
    try result.appendSlice(allocator, "],\"nextCursor\":");
    if (end < total) {
        const next_cursor = try std.fmt.allocPrint(allocator, "{d}", .{end});
        defer allocator.free(next_cursor);
        const next_cursor_json = try std.json.Stringify.valueAlloc(allocator, next_cursor, .{});
        defer allocator.free(next_cursor_json);
        try result.appendSlice(allocator, next_cursor_json);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");

    return renderJsonRpcResult(allocator, id_value, result.items);
}

const OptionalObjectParams = union(enum) {
    object: std.json.ObjectMap,
    empty,
    message: []const u8,
};

fn optionalModelListParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "model/list params must be an object" };
    return .{ .object = params.object };
}

fn appendConfiguredModelJson(allocator: std.mem.Allocator, result: *std.ArrayList(u8), model: []const u8) !void {
    const model_json = try std.json.Stringify.valueAlloc(allocator, model, .{});
    defer allocator.free(model_json);
    const description_json = try std.json.Stringify.valueAlloc(allocator, "Configured Codex Zig model.", .{});
    defer allocator.free(description_json);
    try result.appendSlice(allocator, "{\"id\":");
    try result.appendSlice(allocator, model_json);
    try result.appendSlice(allocator, ",\"model\":");
    try result.appendSlice(allocator, model_json);
    try result.appendSlice(allocator, ",\"upgrade\":null,\"upgradeInfo\":null,\"availabilityNux\":null,\"displayName\":");
    try result.appendSlice(allocator, model_json);
    try result.appendSlice(allocator, ",\"description\":");
    try result.appendSlice(allocator, description_json);
    try result.appendSlice(allocator, ",\"hidden\":false,\"supportedReasoningEfforts\":[");
    try result.appendSlice(allocator, "{\"reasoningEffort\":\"low\",\"description\":\"Fast responses with lighter reasoning\"}");
    try result.appendSlice(allocator, ",{\"reasoningEffort\":\"medium\",\"description\":\"Balanced reasoning depth\"}");
    try result.appendSlice(allocator, ",{\"reasoningEffort\":\"high\",\"description\":\"Greater reasoning depth\"}");
    try result.appendSlice(allocator, ",{\"reasoningEffort\":\"xhigh\",\"description\":\"Extra high reasoning depth\"}");
    try result.appendSlice(allocator, "],\"defaultReasoningEffort\":\"medium\",\"inputModalities\":[\"text\",\"image\"],\"supportsPersonality\":false,\"additionalSpeedTiers\":[],\"serviceTiers\":[],\"isDefault\":true}");
}

fn handleModelProviderCapabilitiesRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (validateOptionalObjectParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }

    const model_provider = config.loadModelProviderId(allocator, null) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "modelProvider/capabilities/read failed to load config", err);
    };
    defer if (model_provider) |value| allocator.free(value);

    const supports_default_tools = if (model_provider) |provider|
        !std.mem.eql(u8, provider, "amazon-bedrock")
    else
        true;
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"namespaceTools\":{},\"imageGeneration\":{},\"webSearch\":{}}}",
        .{ supports_default_tools, supports_default_tools, supports_default_tools },
    );
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn isExperimentalFeatureMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "experimentalFeature/list") or
        std.mem.eql(u8, method, "experimentalFeature/enablement/set");
}

fn handleExperimentalFeatureMethod(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "experimentalFeature/list")) {
        return handleExperimentalFeatureList(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "experimentalFeature/enablement/set")) {
        return handleExperimentalFeatureEnablementSet(allocator, state, id_value, params_value);
    }
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown experimental feature method");
}

fn handleExperimentalFeatureList(
    allocator: std.mem.Allocator,
    state: *const AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = switch (optionalExperimentalFeatureListParams(params_value)) {
        .object => |object| object,
        .empty => null,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };

    var cursor: ?[]const u8 = null;
    var limit: ?usize = null;
    if (params) |object| {
        if (object.get("cursor")) |value| {
            if (value != .null) {
                if (value != .string) return renderJsonRpcError(allocator, id_value, -32602, "cursor must be a string or null");
                cursor = value.string;
            }
        }
        if (object.get("limit")) |value| {
            limit = switch (value) {
                .null => null,
                .integer => |integer| blk: {
                    if (integer < 0) return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null");
                    break :blk @intCast(integer);
                },
                .number_string => |number| std.fmt.parseUnsigned(usize, number, 10) catch {
                    return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null");
                },
                else => return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null"),
            };
        }
    }

    const start = if (cursor) |value|
        std.fmt.parseUnsigned(usize, value, 10) catch {
            const message = try std.fmt.allocPrint(allocator, "invalid cursor: {s}", .{value});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }
    else
        0;

    const all_features = features_cmd.FeatureSpec.all;
    const total = all_features.len;
    if (start > total) {
        const message = try std.fmt.allocPrint(allocator, "cursor {d} exceeds total feature flags {d}", .{ start, total });
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "experimentalFeature/list failed to load config", err);
    };
    defer cfg.deinit(allocator);
    var feature_overrides = features_cmd.loadFeatureOverrides(allocator, cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "experimentalFeature/list failed to load feature config", err);
    };
    defer feature_overrides.deinit(allocator);

    const effective_limit = if (total == 0) 0 else @min(@max(limit orelse total, 1), total);
    const end = @min(start + effective_limit, total);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"data\":[");
    for (all_features[start..end], 0..) |feature, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        const enabled = feature_overrides.get(feature.key) orelse
            state.runtime_feature_enablement.get(feature.key) orelse
            feature.default_enabled;
        try appendExperimentalFeatureJson(allocator, &result, feature, enabled);
    }
    try result.appendSlice(allocator, "],\"nextCursor\":");
    if (end < total) {
        const next_cursor = try std.fmt.allocPrint(allocator, "{d}", .{end});
        defer allocator.free(next_cursor);
        const next_cursor_json = try std.json.Stringify.valueAlloc(allocator, next_cursor, .{});
        defer allocator.free(next_cursor_json);
        try result.appendSlice(allocator, next_cursor_json);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");

    return renderJsonRpcResult(allocator, id_value, result.items);
}

fn optionalExperimentalFeatureListParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "experimentalFeature/list params must be an object" };
    return .{ .object = params.object };
}

fn appendExperimentalFeatureJson(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    feature: features_cmd.FeatureSpec,
    enabled: bool,
) !void {
    const key_json = try std.json.Stringify.valueAlloc(allocator, feature.key, .{});
    defer allocator.free(key_json);
    try result.appendSlice(allocator, "{\"name\":");
    try result.appendSlice(allocator, key_json);
    try result.appendSlice(allocator, ",\"stage\":\"");
    try result.appendSlice(allocator, experimentalFeatureStageLabel(feature.stage));
    try result.appendSlice(allocator, "\",\"displayName\":");
    if (std.mem.eql(u8, feature.stage, "experimental")) {
        try result.appendSlice(allocator, key_json);
        try result.appendSlice(allocator, ",\"description\":\"Experimental Zig feature flag.\",\"announcement\":\"Available for opt-in testing in the Zig port.\"");
    } else {
        try result.appendSlice(allocator, "null,\"description\":null,\"announcement\":null");
    }
    try result.appendSlice(allocator, ",\"enabled\":");
    try result.appendSlice(allocator, if (enabled) "true" else "false");
    try result.appendSlice(allocator, ",\"defaultEnabled\":");
    try result.appendSlice(allocator, if (feature.default_enabled) "true" else "false");
    try result.appendSlice(allocator, "}");
}

fn experimentalFeatureStageLabel(stage: []const u8) []const u8 {
    if (std.mem.eql(u8, stage, "experimental")) return "beta";
    if (std.mem.eql(u8, stage, "under development")) return "underDevelopment";
    if (std.mem.eql(u8, stage, "stable")) return "stable";
    if (std.mem.eql(u8, stage, "deprecated")) return "deprecated";
    if (std.mem.eql(u8, stage, "removed")) return "removed";
    return "underDevelopment";
}

const supported_experimental_feature_enablement = [_][]const u8{
    "apps",
    "memories",
    "plugins",
    "remote_control",
    "tool_search",
    "tool_suggest",
    "tool_call_mcp_elicitation",
};

const supported_experimental_feature_enablement_message = "apps, memories, plugins, remote_control, tool_search, tool_suggest, tool_call_mcp_elicitation";

fn handleExperimentalFeatureEnablementSet(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "experimentalFeature/enablement/set params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "experimentalFeature/enablement/set params must be an object");
    const enablement = params.object.get("enablement") orelse return renderJsonRpcError(allocator, id_value, -32602, "enablement must be an object");
    if (enablement != .object) return renderJsonRpcError(allocator, id_value, -32602, "enablement must be an object");

    for (enablement.object.keys(), enablement.object.values()) |key, value| {
        if (value != .bool) return renderJsonRpcError(allocator, id_value, -32602, "enablement values must be booleans");
        if (!features_cmd.isKnownFeature(key)) {
            const message = try std.fmt.allocPrint(allocator, "invalid feature enablement `{s}`", .{key});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }
        if (!isSupportedExperimentalFeatureEnablement(key)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "unsupported feature enablement `{s}`: currently supported features are {s}",
                .{ key, supported_experimental_feature_enablement_message },
            );
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }
    }

    for (enablement.object.keys(), enablement.object.values()) |key, value| {
        try state.runtime_feature_enablement.put(allocator, key, value.bool);
    }

    const result = try renderExperimentalFeatureEnablementResponse(allocator, enablement.object);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn isSupportedExperimentalFeatureEnablement(key: []const u8) bool {
    for (supported_experimental_feature_enablement) |supported| {
        if (std.mem.eql(u8, key, supported)) return true;
    }
    return false;
}

fn renderExperimentalFeatureEnablementResponse(allocator: std.mem.Allocator, enablement: std.json.ObjectMap) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"enablement\":{");
    for (enablement.keys(), enablement.values(), 0..) |key, value, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        const key_json = try std.json.Stringify.valueAlloc(allocator, key, .{});
        defer allocator.free(key_json);
        try result.appendSlice(allocator, key_json);
        try result.appendSlice(allocator, if (value.bool) ":true" else ":false");
    }
    try result.appendSlice(allocator, "}}");
    return result.toOwnedSlice(allocator);
}

fn renderInitializeResult(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(
        u8,
        "{\"serverInfo\":{\"name\":\"codex-zig-app-server\",\"version\":\"0.0.1\"},\"capabilities\":{}}",
    );
}

fn renderJsonRpcResult(allocator: std.mem.Allocator, id_value: std.json.Value, result_json: []const u8) ![]const u8 {
    const id_json = try std.json.Stringify.valueAlloc(allocator, id_value, .{});
    defer allocator.free(id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn renderJsonRpcError(allocator: std.mem.Allocator, id_value: ?std.json.Value, code: i64, message: []const u8) ![]const u8 {
    const id_json = if (id_value) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_json);
    const message_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(message_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json, code, message_json },
    );
}

fn renderJsonRpcErrorForFailure(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    context: []const u8,
    err: anyerror,
) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ context, @errorName(err) });
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32603, message);
}

fn writeStdoutLine(payload: []const u8) !void {
    try cli_utils.writeStdout(payload);
    try cli_utils.writeStdout("\n");
}

fn writeStreamLine(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeAll(payload);
    try writer.writeAll("\n");
    try writer.flush();
}

fn defaultUnixSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    return std.fs.path.join(allocator, &.{ codex_home, DEFAULT_SOCKET_DIR_NAME, DEFAULT_SOCKET_FILE_NAME });
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| return value;

    const home = (try env.getOwned(allocator, "HOME")) orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    if (try dirExists(io, parent)) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn dirExists(io: std.Io, path: []const u8) !bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    defer dir.close(io);
    return true;
}

fn deleteSocketFileIfSocket(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const stat = statPathNoFollow(allocator, path) catch |err| switch (err) {
        error.NotDir => return error.AppServerUnixSocketPathExists,
        else => return err,
    } orelse return;
    if (!std.c.S.ISSOCK(@intCast(stat.mode))) return error.AppServerUnixSocketPathExists;
    try std.Io.Dir.cwd().deleteFile(io, path);
}

fn statPathFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    return statPathWithFlags(allocator, path, 0);
}

fn statPathNoFollow(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    return statPathWithFlags(allocator, path, std.c.AT.SYMLINK_NOFOLLOW);
}

fn statPathWithFlags(allocator: std.mem.Allocator, path: []const u8, flags: u32) !?std.c.Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat, flags))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT => return null,
            .NOTDIR => return error.NotDir,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return stat;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig app-server [--listen URL]
        \\  codex-zig app-server proxy [--sock SOCKET_PATH]
        \\
        \\Runs the app-server JSON-RPC transport.
        \\
        \\Subcommands:
        \\  proxy                  Proxy stdio to the app-server Unix socket
        \\
        \\Options:
        \\  --listen URL           Transport URL. Defaults to stdio://.
        \\  --analytics-default-enabled
        \\                          Accept Rust-compatible app-server analytics default flag.
        \\  --ws-auth MODE         Websocket auth mode: capability-token or signed-bearer-token.
        \\  --ws-token-file PATH   Capability-token file. Requires --ws-auth capability-token.
        \\  --ws-token-sha256 HEX  Capability-token SHA-256. Requires --ws-auth capability-token.
        \\  --ws-shared-secret-file PATH
        \\                          Signed JWT bearer secret file. Requires --ws-auth signed-bearer-token.
        \\  --ws-issuer ISSUER     Expected signed JWT issuer.
        \\  --ws-audience AUDIENCE Expected signed JWT audience.
        \\  --ws-max-clock-skew-seconds SECONDS
        \\                          Signed JWT max clock skew. Defaults to 30.
        \\
        \\Supported URL forms:
        \\  stdio://               Read and write newline-delimited JSON-RPC on stdio
        \\  off                    Disable the app-server transport
        \\  unix://                Listen on CODEX_HOME/app-server-control/app-server-control.sock
        \\  unix://PATH            Listen on a Unix socket transport path
        \\  ws://IP:PORT           Parse a websocket transport address
        \\
        \\The Zig port currently implements stdio://, unix://, unix://PATH, and off.
        \\
    , .{});
}

fn printProxyHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig app-server proxy [--sock SOCKET_PATH]
        \\
        \\Relays newline-delimited JSON-RPC between stdio and the app-server
        \\Unix control socket. If --sock is omitted, the default
        \\CODEX_HOME/app-server-control/app-server-control.sock path is used.
        \\
    , .{});
}

test "app-server transport parser accepts Rust listen URL forms" {
    try std.testing.expectEqual(.stdio, try parseTransport("stdio://"));
    try std.testing.expectEqual(.off, try parseTransport("off"));
    try std.testing.expectEqual(.unix_default, try parseTransport("unix://"));

    const unix_path = try parseTransport("unix:///tmp/codex.sock");
    try std.testing.expectEqualStrings("/tmp/codex.sock", unix_path.unix_path);

    const websocket = try parseTransport("ws://127.0.0.1:3456");
    try std.testing.expectEqualStrings("127.0.0.1", websocket.websocket.host);
    try std.testing.expectEqual(@as(u16, 3456), websocket.websocket.port);
}

test "app-server websocket auth parser accepts Rust mode names" {
    try std.testing.expectEqual(.capability_token, try parseWebsocketAuthMode("capability-token"));
    try std.testing.expectEqual(.signed_bearer_token, try parseWebsocketAuthMode("signed-bearer-token"));
    try std.testing.expectError(error.UnsupportedAppServerWebsocketAuthMode, parseWebsocketAuthMode("none"));
}

test "app-server websocket auth validates capability token source" {
    try validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
        .ws_token_sha256 = "abababababababababababababababababababababababababababababababab",
    });
    try validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
        .ws_token_file = "/tmp/codex-token",
    });
    try std.testing.expectError(error.AppServerWebsocketTokenSourceRequired, validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
    }));
    try std.testing.expectError(error.AppServerWebsocketTokenSourcesMutuallyExclusive, validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
        .ws_token_file = "/tmp/codex-token",
        .ws_token_sha256 = "abababababababababababababababababababababababababababababababab",
    }));
    try std.testing.expectError(error.AppServerWebsocketAuthSha256DigestInvalid, validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
        .ws_token_sha256 = "not-a-sha256",
    }));
    try std.testing.expectError(error.AppServerWebsocketAuthPathMustBeAbsolute, validateWebsocketAuthArgs(.{
        .ws_auth = .capability_token,
        .ws_token_file = "relative-token",
    }));
}

test "app-server websocket auth validates signed bearer source" {
    try validateWebsocketAuthArgs(.{
        .ws_auth = .signed_bearer_token,
        .ws_shared_secret_file = "/tmp/codex-secret",
        .ws_issuer = "issuer",
        .ws_audience = "audience",
        .ws_max_clock_skew_seconds = 9,
    });
    try validateWebsocketAuthArgs(.{
        .ws_auth = .signed_bearer_token,
        .ws_shared_secret_file = "/tmp/codex-secret",
    });
    try std.testing.expectError(error.AppServerWebsocketSharedSecretFileRequired, validateWebsocketAuthArgs(.{
        .ws_auth = .signed_bearer_token,
    }));
    try std.testing.expectError(error.AppServerWebsocketSignedBearerRejectedCapabilityTokenFlag, validateWebsocketAuthArgs(.{
        .ws_auth = .signed_bearer_token,
        .ws_shared_secret_file = "/tmp/codex-secret",
        .ws_token_sha256 = "abababababababababababababababababababababababababababababababab",
    }));
}

test "app-server websocket auth rejects mode-specific flags without mode" {
    try validateWebsocketAuthArgs(.{});
    try std.testing.expectError(error.AppServerWebsocketAuthModeRequired, validateWebsocketAuthArgs(.{
        .ws_shared_secret_file = "/tmp/codex-secret",
    }));
}

test "app-server transport parser rejects unsupported listen URLs" {
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("http://127.0.0.1:8000"));
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("ws://127.0.0.1"));
    try std.testing.expectError(error.UnsupportedAppServerListenUrl, parseTransport("ws://127.0.0.1:not-a-port"));
}

test "app-server initialize result exposes server info" {
    const allocator = std.testing.allocator;
    const result = try renderInitializeResult(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"codex-zig-app-server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"capabilities\":{}") != null);
}

test "app-server marketplace methods validate params and return not implemented" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const valid_add = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"add\",\"method\":\"marketplace/add\",\"params\":{\"source\":\"owner/repo\",\"refName\":\"main\",\"sparsePaths\":[\"plugins/foo\"]}}",
    );
    defer allocator.free(valid_add.?);
    try std.testing.expect(std.mem.indexOf(u8, valid_add.?, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid_add.?, "marketplace/add is parsed but not implemented yet") != null);

    const valid_remove = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"remove\",\"method\":\"marketplace/remove\",\"params\":{\"marketplaceName\":\"debug\"}}",
    );
    defer allocator.free(valid_remove.?);
    try std.testing.expect(std.mem.indexOf(u8, valid_remove.?, "\"code\":-32603") != null);

    const valid_upgrade = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"upgrade\",\"method\":\"marketplace/upgrade\",\"params\":{\"marketplaceName\":null}}",
    );
    defer allocator.free(valid_upgrade.?);
    try std.testing.expect(std.mem.indexOf(u8, valid_upgrade.?, "\"code\":-32603") != null);

    const invalid_add = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-add\",\"method\":\"marketplace/add\",\"params\":{\"refName\":\"main\"}}",
    );
    defer allocator.free(invalid_add.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_add.?, "\"code\":-32602") != null);
}

test "app-server plugin methods validate params and return not implemented" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-list\",\"method\":\"plugin/list\",\"params\":{\"cwds\":[\"/tmp/repo\"],\"marketplaceKinds\":[\"local\",\"workspace-directory\",\"shared-with-me\"]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-read\",\"method\":\"plugin/read\",\"params\":{\"marketplacePath\":\"/tmp/marketplace.json\",\"remoteMarketplaceName\":null,\"pluginName\":\"gmail\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-skill-read\",\"method\":\"plugin/skill/read\",\"params\":{\"remoteMarketplaceName\":\"chatgpt-global\",\"remotePluginId\":\"plugins~Plugin_00000000000000000000000000000000\",\"skillName\":\"plan-work\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-share-save\",\"method\":\"plugin/share/save\",\"params\":{\"pluginPath\":\"/tmp/plugins/gmail\",\"remotePluginId\":null,\"discoverability\":\"PRIVATE\",\"shareTargets\":[{\"principalType\":\"user\",\"principalId\":\"user-1\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-share-update\",\"method\":\"plugin/share/updateTargets\",\"params\":{\"remotePluginId\":\"plugins~Plugin_00000000000000000000000000000000\",\"shareTargets\":[{\"principalType\":\"workspace\",\"principalId\":\"workspace-1\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-share-list\",\"method\":\"plugin/share/list\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-share-delete\",\"method\":\"plugin/share/delete\",\"params\":{\"remotePluginId\":\"plugins~Plugin_00000000000000000000000000000000\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-install\",\"method\":\"plugin/install\",\"params\":{\"remoteMarketplaceName\":\"openai-curated\",\"pluginName\":\"gmail\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-uninstall\",\"method\":\"plugin/uninstall\",\"params\":{\"pluginId\":\"gmail@openai-curated\"}}",
    };

    for (cases) |line| {
        const response = try handleJsonRpcLine(allocator, &state, line);
        defer allocator.free(response.?);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32603") != null);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "is parsed but not implemented yet") != null);
    }

    const invalid_read = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-read\",\"method\":\"plugin/read\",\"params\":{\"marketplacePath\":\"/tmp/marketplace.json\"}}",
    );
    defer allocator.free(invalid_read.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_read.?, "\"code\":-32602") != null);

    const invalid_kind = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-list\",\"method\":\"plugin/list\",\"params\":{\"marketplaceKinds\":[\"unexpected\"]}}",
    );
    defer allocator.free(invalid_kind.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_kind.?, "\"code\":-32602") != null);
}

test "app-server transport labels preserve configured listen URL" {
    const allocator = std.testing.allocator;
    const unix_path = try formatTransportLabel(allocator, try parseTransport("unix:///tmp/codex.sock"));
    defer allocator.free(unix_path);
    try std.testing.expectEqualStrings("unix:///tmp/codex.sock", unix_path);

    const websocket = try formatTransportLabel(allocator, try parseTransport("ws://127.0.0.1:3456"));
    defer allocator.free(websocket);
    try std.testing.expectEqualStrings("ws://127.0.0.1:3456", websocket);
}
