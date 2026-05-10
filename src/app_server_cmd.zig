const std = @import("std");
const builtin = @import("builtin");

const account_nudge = @import("account_nudge.zig");
const account_rate_limits = @import("account_rate_limits.zig");
const auth_mod = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const config_requirements_hooks = @import("config_requirements_hooks.zig");
const env = @import("env.zig");
const features_cmd = @import("features_cmd.zig");
const fuzzy_file_search = @import("fuzzy_file_search.zig");
const git_remote_diff = @import("git_remote_diff.zig");
const hooks_list = @import("hooks_list.zig");
const memory_reset = @import("memory_reset.zig");
const marketplace_config = @import("marketplace_config.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const model_catalog = @import("model_catalog.zig");
const plugin_config = @import("plugin_config.zig");
const plugin_list = @import("plugin_list.zig");
const remote_plugin = @import("remote_plugin.zig");
const sandbox_mod = @import("sandbox.zig");
const skills_list = @import("skills_list.zig");

pub const DEFAULT_LISTEN_URL = "stdio://";
const DEFAULT_SOCKET_DIR_NAME = "app-server-control";
const DEFAULT_SOCKET_FILE_NAME = "app-server-control.sock";
const MANAGED_CONFIG_PATH_ENV_VAR = "CODEX_APP_SERVER_MANAGED_CONFIG_PATH";
const SYSTEM_CONFIG_PATH_ENV_VAR = "CODEX_APP_SERVER_SYSTEM_CONFIG_PATH";
const SYSTEM_REQUIREMENTS_PATH_ENV_VAR = "CODEX_APP_SERVER_SYSTEM_REQUIREMENTS_PATH";
const UNIX_MANAGED_CONFIG_SYSTEM_PATH = "/etc/codex/managed_config.toml";
const UNIX_SYSTEM_CONFIG_PATH = "/etc/codex/config.toml";
const UNIX_SYSTEM_REQUIREMENTS_PATH = "/etc/codex/requirements.toml";
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
    fs_watches: std.ArrayList(FsWatchEntry) = .empty,
    fuzzy_search_sessions: std.ArrayList(FuzzySearchSessionEntry) = .empty,
    skill_watch_roots: std.ArrayList([]const u8) = .empty,
    skills_list_cache: std.ArrayList(SkillsListCacheEntry) = .empty,
    pre_response_notifications: std.ArrayList([]const u8) = .empty,
    pending_notifications: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *AppServerState, allocator: std.mem.Allocator) void {
        self.runtime_feature_enablement.deinit(allocator);
        for (self.fs_watches.items) |*watch| watch.deinit(allocator);
        self.fs_watches.deinit(allocator);
        for (self.fuzzy_search_sessions.items) |*session| session.deinit(allocator);
        self.fuzzy_search_sessions.deinit(allocator);
        for (self.skill_watch_roots.items) |root| allocator.free(root);
        self.skill_watch_roots.deinit(allocator);
        clearSkillsListCache(allocator, self);
        self.skills_list_cache.deinit(allocator);
        for (self.pre_response_notifications.items) |payload| allocator.free(payload);
        self.pre_response_notifications.deinit(allocator);
        for (self.pending_notifications.items) |payload| allocator.free(payload);
        self.pending_notifications.deinit(allocator);
    }
};

const FsWatchEntry = struct {
    watch_id: []const u8,
    path: []const u8,
    snapshot: std.ArrayList(FsWatchSnapshotEntry) = .empty,

    fn deinit(self: *FsWatchEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.watch_id);
        allocator.free(self.path);
        deinitFsWatchSnapshot(allocator, &self.snapshot);
    }
};

const FsWatchSnapshotKind = enum {
    missing,
    file,
    directory,
    symlink,
    other,
};

const FsWatchSnapshotEntry = struct {
    path: []const u8,
    kind: FsWatchSnapshotKind,
    mode: u32,
    size: i64,
    modified_at_ns: i64,

    fn deinit(self: *FsWatchSnapshotEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const FuzzySearchSessionEntry = struct {
    session_id: []const u8,
    roots: []const []const u8,

    fn deinit(self: *FuzzySearchSessionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        for (self.roots) |root| allocator.free(root);
        allocator.free(self.roots);
    }
};

const SkillsListCacheEntry = struct {
    cwd: []const u8,
    entry_json: []const u8,

    fn deinit(self: *SkillsListCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.entry_json);
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
        if (std.mem.eql(u8, name, "generate-ts")) {
            try runGenerateTs(allocator, subcommand_args.items);
            return;
        }
        if (std.mem.eql(u8, name, "generate-json-schema")) {
            try runGenerateJsonSchema(allocator, subcommand_args.items);
            return;
        }
        if (std.mem.eql(u8, name, "generate-internal-json-schema")) {
            try runGenerateInternalJsonSchema(allocator, subcommand_args.items);
            return;
        }
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

fn runGenerateTs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var out_dir: ?[]const u8 = null;
    var prettier: ?[]const u8 = null;
    var experimental = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            if (index + 1 >= args.len) return error.MissingAppServerGenerateTsOutDir;
            index += 1;
            out_dir = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=")) {
            out_dir = arg["--out=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prettier")) {
            if (index + 1 >= args.len) return error.MissingAppServerGenerateTsPrettierPath;
            index += 1;
            prettier = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--prettier=")) {
            prettier = arg["--prettier=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental")) {
            experimental = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppServerGenerateTsOption;
        return error.UnexpectedAppServerGenerateTsArgument;
    }

    const target_dir = out_dir orelse return error.MissingAppServerGenerateTsOutDir;
    if (target_dir.len == 0) return error.MissingAppServerGenerateTsOutDir;
    try writeAppServerTs(allocator, target_dir, prettier, experimental);
}

fn runGenerateJsonSchema(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var out_dir: ?[]const u8 = null;
    var experimental = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            if (index + 1 >= args.len) return error.MissingAppServerGenerateJsonSchemaOutDir;
            index += 1;
            out_dir = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=")) {
            out_dir = arg["--out=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental")) {
            experimental = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppServerGenerateJsonSchemaOption;
        return error.UnexpectedAppServerGenerateJsonSchemaArgument;
    }

    const target_dir = out_dir orelse return error.MissingAppServerGenerateJsonSchemaOutDir;
    if (target_dir.len == 0) return error.MissingAppServerGenerateJsonSchemaOutDir;
    try writeAppServerJsonSchemas(allocator, target_dir, experimental);
}

fn runGenerateInternalJsonSchema(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var out_dir: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            if (index + 1 >= args.len) return error.MissingAppServerGenerateInternalJsonSchemaOutDir;
            index += 1;
            out_dir = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=")) {
            out_dir = arg["--out=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownAppServerGenerateInternalJsonSchemaOption;
        return error.UnexpectedAppServerGenerateInternalJsonSchemaArgument;
    }

    const target_dir = out_dir orelse return error.MissingAppServerGenerateInternalJsonSchemaOutDir;
    if (target_dir.len == 0) return error.MissingAppServerGenerateInternalJsonSchemaOutDir;
    try writeRolloutLineJsonSchema(allocator, target_dir);
}

const SchemaFile = struct {
    name: []const u8,
    contents: []const u8,
};

const GENERATED_TS_HEADER = "// GENERATED CODE! DO NOT MODIFY BY HAND!\n\n";

const REQUEST_ID_TS =
    GENERATED_TS_HEADER ++
    \\export type RequestId = string | number;
    \\
    ;

const JSONRPC_REQUEST_TS =
    GENERATED_TS_HEADER ++
    \\import type { RequestId } from "./RequestId";
    \\
    \\export interface JSONRPCRequest {
    \\  id: RequestId;
    \\  method: string;
    \\  params?: unknown;
    \\  trace?: Record<string, unknown>;
    \\}
    \\
    ;

const JSONRPC_NOTIFICATION_TS =
    GENERATED_TS_HEADER ++
    \\export interface JSONRPCNotification {
    \\  method: string;
    \\  params?: unknown;
    \\}
    \\
    ;

const JSONRPC_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\import type { RequestId } from "./RequestId";
    \\
    \\export interface JSONRPCResponse {
    \\  id: RequestId;
    \\  result: unknown;
    \\}
    \\
    ;

const JSONRPC_ERROR_ERROR_TS =
    GENERATED_TS_HEADER ++
    \\export interface JSONRPCErrorError {
    \\  code: number;
    \\  message: string;
    \\  data?: unknown;
    \\}
    \\
    ;

const JSONRPC_ERROR_TS =
    GENERATED_TS_HEADER ++
    \\import type { JSONRPCErrorError } from "./JSONRPCErrorError";
    \\import type { RequestId } from "./RequestId";
    \\
    \\export interface JSONRPCError {
    \\  id: RequestId;
    \\  error: JSONRPCErrorError;
    \\}
    \\
    ;

const JSONRPC_MESSAGE_TS =
    GENERATED_TS_HEADER ++
    \\import type { JSONRPCError } from "./JSONRPCError";
    \\import type { JSONRPCNotification } from "./JSONRPCNotification";
    \\import type { JSONRPCRequest } from "./JSONRPCRequest";
    \\import type { JSONRPCResponse } from "./JSONRPCResponse";
    \\
    \\export type JSONRPCMessage =
    \\  | JSONRPCRequest
    \\  | JSONRPCNotification
    \\  | JSONRPCResponse
    \\  | JSONRPCError;
    \\
    ;

const INITIALIZE_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface ClientInfo {
    \\  name: string;
    \\  title?: string | null;
    \\  version: string;
    \\}
    \\
    \\export interface InitializeCapabilities {
    \\  experimentalApi?: boolean;
    \\  optOutNotificationMethods?: string[] | null;
    \\}
    \\
    \\export interface InitializeParams {
    \\  clientInfo: ClientInfo;
    \\  capabilities?: InitializeCapabilities | null;
    \\}
    \\
    ;

const INITIALIZE_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export interface ServerInfo {
    \\  name: string;
    \\  version: string;
    \\}
    \\
    \\export interface InitializeResponse {
    \\  serverInfo: ServerInfo;
    \\  capabilities: Record<string, unknown>;
    \\}
    \\
    ;

const COMMAND_EXEC_TERMINAL_SIZE_TS =
    GENERATED_TS_HEADER ++
    \\export interface CommandExecTerminalSize {
    \\  rows: number;
    \\  cols: number;
    \\}
    \\
    ;

const COMMAND_EXEC_OUTPUT_STREAM_TS =
    GENERATED_TS_HEADER ++
    \\export type CommandExecOutputStream = "stdout" | "stderr";
    \\
    ;

const NETWORK_ACCESS_TS =
    GENERATED_TS_HEADER ++
    \\export type NetworkAccess = "restricted" | "enabled";
    \\
    ;

const ABSOLUTE_PATH_BUF_TS =
    GENERATED_TS_HEADER ++
    \\export type AbsolutePathBuf = string;
    \\
    ;

const SANDBOX_POLICY_TS =
    GENERATED_TS_HEADER ++
    \\import type { AbsolutePathBuf } from "../AbsolutePathBuf";
    \\import type { NetworkAccess } from "./NetworkAccess";
    \\
    \\export type SandboxPolicy =
    \\  | { type: "dangerFullAccess" }
    \\  | { type: "readOnly"; networkAccess: boolean }
    \\  | { type: "externalSandbox"; networkAccess: NetworkAccess }
    \\  | {
    \\      type: "workspaceWrite";
    \\      writableRoots: AbsolutePathBuf[];
    \\      networkAccess: boolean;
    \\      excludeTmpdirEnvVar: boolean;
    \\      excludeSlashTmp: boolean;
    \\    };
    \\
    ;

const FILE_SYSTEM_ACCESS_MODE_TS =
    GENERATED_TS_HEADER ++
    \\export type FileSystemAccessMode = "read" | "write" | "none";
    \\
    ;

const FILE_SYSTEM_SPECIAL_PATH_TS =
    GENERATED_TS_HEADER ++
    \\export type FileSystemSpecialPath =
    \\  | { kind: "root" }
    \\  | { kind: "minimal" }
    \\  | { kind: "project_roots"; subpath: string | null }
    \\  | { kind: "tmpdir" }
    \\  | { kind: "slash_tmp" }
    \\  | { kind: "unknown"; path: string; subpath: string | null };
    \\
    ;

const FILE_SYSTEM_PATH_TS =
    GENERATED_TS_HEADER ++
    \\import type { AbsolutePathBuf } from "../AbsolutePathBuf";
    \\import type { FileSystemSpecialPath } from "./FileSystemSpecialPath";
    \\
    \\export type FileSystemPath =
    \\  | { type: "path"; path: AbsolutePathBuf }
    \\  | { type: "glob_pattern"; pattern: string }
    \\  | { type: "special"; value: FileSystemSpecialPath };
    \\
    ;

const FILE_SYSTEM_SANDBOX_ENTRY_TS =
    GENERATED_TS_HEADER ++
    \\import type { FileSystemAccessMode } from "./FileSystemAccessMode";
    \\import type { FileSystemPath } from "./FileSystemPath";
    \\
    \\export interface FileSystemSandboxEntry {
    \\  path: FileSystemPath;
    \\  access: FileSystemAccessMode;
    \\}
    \\
    ;

const PERMISSION_PROFILE_NETWORK_PERMISSIONS_TS =
    GENERATED_TS_HEADER ++
    \\export interface PermissionProfileNetworkPermissions {
    \\  enabled: boolean;
    \\}
    \\
    ;

const PERMISSION_PROFILE_FILE_SYSTEM_PERMISSIONS_TS =
    GENERATED_TS_HEADER ++
    \\import type { FileSystemSandboxEntry } from "./FileSystemSandboxEntry";
    \\
    \\export type PermissionProfileFileSystemPermissions =
    \\  | {
    \\      type: "restricted";
    \\      entries: FileSystemSandboxEntry[];
    \\      globScanMaxDepth?: number;
    \\    }
    \\  | { type: "unrestricted" };
    \\
    ;

const PERMISSION_PROFILE_TS =
    GENERATED_TS_HEADER ++
    \\import type { PermissionProfileFileSystemPermissions } from "./PermissionProfileFileSystemPermissions";
    \\import type { PermissionProfileNetworkPermissions } from "./PermissionProfileNetworkPermissions";
    \\
    \\export type PermissionProfile =
    \\  | {
    \\      type: "managed";
    \\      fileSystem: PermissionProfileFileSystemPermissions;
    \\      network: PermissionProfileNetworkPermissions;
    \\    }
    \\  | { type: "disabled" }
    \\  | { type: "external"; network: PermissionProfileNetworkPermissions };
    \\
    ;

const COMMAND_EXEC_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecTerminalSize } from "./CommandExecTerminalSize";
    \\import type { PermissionProfile } from "./PermissionProfile";
    \\import type { SandboxPolicy } from "./SandboxPolicy";
    \\
    \\export interface CommandExecParams {
    \\  command: string[];
    \\  processId?: string | null;
    \\  tty?: boolean;
    \\  streamStdin?: boolean;
    \\  streamStdoutStderr?: boolean;
    \\  outputBytesCap?: number | null;
    \\  disableOutputCap?: boolean;
    \\  disableTimeout?: boolean;
    \\  timeoutMs?: number | null;
    \\  cwd?: string | null;
    \\  env?: Record<string, string | null> | null;
    \\  size?: CommandExecTerminalSize | null;
    \\  sandboxPolicy?: SandboxPolicy | null;
    \\  permissionProfile?: PermissionProfile | null;
    \\}
    \\
    ;

const COMMAND_EXEC_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export interface CommandExecResponse {
    \\  exitCode: number;
    \\  stdout: string;
    \\  stderr: string;
    \\}
    \\
    ;

const COMMAND_EXEC_WRITE_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface CommandExecWriteParams {
    \\  processId: string;
    \\  deltaBase64?: string | null;
    \\  closeStdin?: boolean;
    \\}
    \\
    ;

const COMMAND_EXEC_WRITE_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export type CommandExecWriteResponse = Record<string, never>;
    \\
    ;

const COMMAND_EXEC_TERMINATE_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export type CommandExecTerminateResponse = Record<string, never>;
    \\
    ;

const COMMAND_EXEC_RESIZE_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export type CommandExecResizeResponse = Record<string, never>;
    \\
    ;

const COMMAND_EXEC_TERMINATE_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface CommandExecTerminateParams {
    \\  processId: string;
    \\}
    \\
    ;

const COMMAND_EXEC_RESIZE_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecTerminalSize } from "./CommandExecTerminalSize";
    \\
    \\export interface CommandExecResizeParams {
    \\  processId: string;
    \\  size: CommandExecTerminalSize;
    \\}
    \\
    ;

const COMMAND_EXEC_OUTPUT_DELTA_NOTIFICATION_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecOutputStream } from "./CommandExecOutputStream";
    \\
    \\export interface CommandExecOutputDeltaNotification {
    \\  processId: string;
    \\  stream: CommandExecOutputStream;
    \\  deltaBase64: string;
    \\  capReached: boolean;
    \\}
    \\
    ;

const THREAD_LOADED_LIST_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadLoadedListParams {
    \\  cursor?: string | null;
    \\  limit?: number | null;
    \\}
    \\
    ;

const THREAD_LOADED_LIST_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadLoadedListResponse {
    \\  data: string[];
    \\  nextCursor: string | null;
    \\}
    \\
    ;

const THREAD_UNSUBSCRIBE_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadUnsubscribeParams {
    \\  threadId: string;
    \\}
    \\
    ;

const THREAD_UNSUBSCRIBE_STATUS_TS =
    GENERATED_TS_HEADER ++
    \\export type ThreadUnsubscribeStatus = "notLoaded" | "notSubscribed" | "unsubscribed";
    \\
    ;

const THREAD_UNSUBSCRIBE_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\import type { ThreadUnsubscribeStatus } from "./ThreadUnsubscribeStatus";
    \\
    \\export interface ThreadUnsubscribeResponse {
    \\  status: ThreadUnsubscribeStatus;
    \\}
    \\
    ;

const THREAD_COMPACT_START_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadCompactStartParams {
    \\  threadId: string;
    \\}
    \\
    ;

const THREAD_COMPACT_START_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadCompactStartResponse {}
    \\
    ;

const THREAD_SHELL_COMMAND_PARAMS_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadShellCommandParams {
    \\  threadId: string;
    \\  command: string;
    \\}
    \\
    ;

const THREAD_SHELL_COMMAND_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\export interface ThreadShellCommandResponse {}
    \\
    ;

const CLIENT_REQUEST_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecParams } from "./v2/CommandExecParams";
    \\import type { CommandExecResizeParams } from "./v2/CommandExecResizeParams";
    \\import type { CommandExecTerminateParams } from "./v2/CommandExecTerminateParams";
    \\import type { CommandExecWriteParams } from "./v2/CommandExecWriteParams";
    \\import type { ThreadCompactStartParams } from "./v2/ThreadCompactStartParams";
    \\import type { ThreadLoadedListParams } from "./v2/ThreadLoadedListParams";
    \\import type { ThreadShellCommandParams } from "./v2/ThreadShellCommandParams";
    \\import type { ThreadUnsubscribeParams } from "./v2/ThreadUnsubscribeParams";
    \\import type { InitializeParams } from "./InitializeParams";
    \\
    \\export type ClientRequest =
    \\  | {
    \\      method: "initialize";
    \\      params: InitializeParams;
    \\    }
    \\  | {
    \\      method: "command/exec";
    \\      params: CommandExecParams;
    \\    }
    \\  | {
    \\      method: "command/exec/write";
    \\      params: CommandExecWriteParams;
    \\    }
    \\  | {
    \\      method: "command/exec/terminate";
    \\      params: CommandExecTerminateParams;
    \\    }
    \\  | {
    \\      method: "command/exec/resize";
    \\      params: CommandExecResizeParams;
    \\    }
    \\  | {
    \\      method: "thread/loaded/list";
    \\      params?: ThreadLoadedListParams | null;
    \\    }
    \\  | {
    \\      method: "thread/unsubscribe";
    \\      params: ThreadUnsubscribeParams;
    \\    }
    \\  | {
    \\      method: "thread/compact/start";
    \\      params: ThreadCompactStartParams;
    \\    }
    \\  | {
    \\      method: "thread/shellCommand";
    \\      params: ThreadShellCommandParams;
    \\    };
    \\
    ;

const CLIENT_RESPONSE_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecResponse } from "./v2/CommandExecResponse";
    \\import type { CommandExecResizeResponse } from "./v2/CommandExecResizeResponse";
    \\import type { CommandExecTerminateResponse } from "./v2/CommandExecTerminateResponse";
    \\import type { CommandExecWriteResponse } from "./v2/CommandExecWriteResponse";
    \\import type { ThreadCompactStartResponse } from "./v2/ThreadCompactStartResponse";
    \\import type { ThreadLoadedListResponse } from "./v2/ThreadLoadedListResponse";
    \\import type { ThreadShellCommandResponse } from "./v2/ThreadShellCommandResponse";
    \\import type { ThreadUnsubscribeResponse } from "./v2/ThreadUnsubscribeResponse";
    \\import type { InitializeResponse } from "./InitializeResponse";
    \\import type { RequestId } from "./RequestId";
    \\
    \\export type ClientResponse =
    \\  | {
    \\      id: RequestId;
    \\      method: "initialize";
    \\      result: InitializeResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "command/exec";
    \\      result: CommandExecResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "command/exec/write";
    \\      result: CommandExecWriteResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "command/exec/terminate";
    \\      result: CommandExecTerminateResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "command/exec/resize";
    \\      result: CommandExecResizeResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "thread/loaded/list";
    \\      result: ThreadLoadedListResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "thread/unsubscribe";
    \\      result: ThreadUnsubscribeResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "thread/compact/start";
    \\      result: ThreadCompactStartResponse;
    \\    }
    \\  | {
    \\      id: RequestId;
    \\      method: "thread/shellCommand";
    \\      result: ThreadShellCommandResponse;
    \\    };
    \\
    ;

const SERVER_NOTIFICATION_TS =
    GENERATED_TS_HEADER ++
    \\import type { CommandExecOutputDeltaNotification } from "./v2/CommandExecOutputDeltaNotification";
    \\
    \\export type ServerNotification =
    \\  | {
    \\      method: "command/exec/outputDelta";
    \\      params: CommandExecOutputDeltaNotification;
    \\    };
    \\
    ;

const INDEX_TS =
    GENERATED_TS_HEADER ++
    \\export type { ClientRequest } from "./ClientRequest";
    \\export type { ClientResponse } from "./ClientResponse";
    \\export type { InitializeCapabilities, InitializeParams, ClientInfo } from "./InitializeParams";
    \\export type { InitializeResponse, ServerInfo } from "./InitializeResponse";
    \\export type { JSONRPCError } from "./JSONRPCError";
    \\export type { JSONRPCErrorError } from "./JSONRPCErrorError";
    \\export type { JSONRPCMessage } from "./JSONRPCMessage";
    \\export type { JSONRPCNotification } from "./JSONRPCNotification";
    \\export type { JSONRPCRequest } from "./JSONRPCRequest";
    \\export type { JSONRPCResponse } from "./JSONRPCResponse";
    \\export type { AbsolutePathBuf } from "./AbsolutePathBuf";
    \\export type { RequestId } from "./RequestId";
    \\export type { ServerNotification } from "./ServerNotification";
    \\export * as v2 from "./v2";
    \\
    ;

const V2_INDEX_TS =
    GENERATED_TS_HEADER ++
    \\export type { CommandExecOutputDeltaNotification } from "./CommandExecOutputDeltaNotification";
    \\export type { CommandExecOutputStream } from "./CommandExecOutputStream";
    \\export type { CommandExecParams } from "./CommandExecParams";
    \\export type { CommandExecResizeParams } from "./CommandExecResizeParams";
    \\export type { CommandExecResizeResponse } from "./CommandExecResizeResponse";
    \\export type { CommandExecResponse } from "./CommandExecResponse";
    \\export type { CommandExecTerminalSize } from "./CommandExecTerminalSize";
    \\export type { CommandExecTerminateParams } from "./CommandExecTerminateParams";
    \\export type { CommandExecTerminateResponse } from "./CommandExecTerminateResponse";
    \\export type { CommandExecWriteParams } from "./CommandExecWriteParams";
    \\export type { CommandExecWriteResponse } from "./CommandExecWriteResponse";
    \\export type { FileSystemAccessMode } from "./FileSystemAccessMode";
    \\export type { FileSystemPath } from "./FileSystemPath";
    \\export type { FileSystemSandboxEntry } from "./FileSystemSandboxEntry";
    \\export type { FileSystemSpecialPath } from "./FileSystemSpecialPath";
    \\export type { NetworkAccess } from "./NetworkAccess";
    \\export type { PermissionProfile } from "./PermissionProfile";
    \\export type { PermissionProfileFileSystemPermissions } from "./PermissionProfileFileSystemPermissions";
    \\export type { PermissionProfileNetworkPermissions } from "./PermissionProfileNetworkPermissions";
    \\export type { SandboxPolicy } from "./SandboxPolicy";
    \\export type { ThreadCompactStartParams } from "./ThreadCompactStartParams";
    \\export type { ThreadCompactStartResponse } from "./ThreadCompactStartResponse";
    \\export type { ThreadLoadedListParams } from "./ThreadLoadedListParams";
    \\export type { ThreadLoadedListResponse } from "./ThreadLoadedListResponse";
    \\export type { ThreadShellCommandParams } from "./ThreadShellCommandParams";
    \\export type { ThreadShellCommandResponse } from "./ThreadShellCommandResponse";
    \\export type { ThreadUnsubscribeParams } from "./ThreadUnsubscribeParams";
    \\export type { ThreadUnsubscribeResponse } from "./ThreadUnsubscribeResponse";
    \\export type { ThreadUnsubscribeStatus } from "./ThreadUnsubscribeStatus";
    \\
    ;

const REQUEST_ID_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "RequestId",
    \\  "oneOf": [
    \\    { "type": "string" },
    \\    { "type": "integer" }
    \\  ]
    \\}
    \\
;

const JSONRPC_REQUEST_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCRequest",
    \\  "type": "object",
    \\  "required": ["id", "method"],
    \\  "properties": {
    \\    "id": { "$ref": "RequestId.json" },
    \\    "method": { "type": "string" },
    \\    "params": true,
    \\    "trace": { "type": "object" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const JSONRPC_NOTIFICATION_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCNotification",
    \\  "type": "object",
    \\  "required": ["method"],
    \\  "properties": {
    \\    "method": { "type": "string" },
    \\    "params": true
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const JSONRPC_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCResponse",
    \\  "type": "object",
    \\  "required": ["id", "result"],
    \\  "properties": {
    \\    "id": { "$ref": "RequestId.json" },
    \\    "result": true
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const JSONRPC_ERROR_ERROR_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCErrorError",
    \\  "type": "object",
    \\  "required": ["code", "message"],
    \\  "properties": {
    \\    "code": { "type": "integer" },
    \\    "message": { "type": "string" },
    \\    "data": true
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const JSONRPC_ERROR_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCError",
    \\  "type": "object",
    \\  "required": ["id", "error"],
    \\  "properties": {
    \\    "id": { "$ref": "RequestId.json" },
    \\    "error": { "$ref": "JSONRPCErrorError.json" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const JSONRPC_MESSAGE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "JSONRPCMessage",
    \\  "oneOf": [
    \\    { "$ref": "JSONRPCRequest.json" },
    \\    { "$ref": "JSONRPCNotification.json" },
    \\    { "$ref": "JSONRPCResponse.json" },
    \\    { "$ref": "JSONRPCError.json" }
    \\  ]
    \\}
    \\
;

const INITIALIZE_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "InitializeParams",
    \\  "type": "object",
    \\  "required": ["clientInfo"],
    \\  "properties": {
    \\    "clientInfo": {
    \\      "type": "object",
    \\      "required": ["name", "version"],
    \\      "properties": {
    \\        "name": { "type": "string" },
    \\        "title": { "type": ["string", "null"] },
    \\        "version": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "capabilities": {
    \\      "type": ["object", "null"],
    \\      "properties": {
    \\        "experimentalApi": { "type": "boolean" },
    \\        "optOutNotificationMethods": {
    \\          "type": ["array", "null"],
    \\          "items": { "type": "string" }
    \\        }
    \\      },
    \\      "additionalProperties": true
    \\    }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const INITIALIZE_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "InitializeResponse",
    \\  "type": "object",
    \\  "required": ["serverInfo", "capabilities"],
    \\  "properties": {
    \\    "serverInfo": {
    \\      "type": "object",
    \\      "required": ["name", "version"],
    \\      "properties": {
    \\        "name": { "type": "string" },
    \\        "version": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "capabilities": { "type": "object" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const COMMAND_EXEC_TERMINAL_SIZE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecTerminalSize",
    \\  "type": "object",
    \\  "required": ["rows", "cols"],
    \\  "properties": {
    \\    "rows": { "type": "integer", "minimum": 1 },
    \\    "cols": { "type": "integer", "minimum": 1 }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

const ABSOLUTE_PATH_BUF_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "AbsolutePathBuf",
    \\  "description": "A path that is guaranteed to be absolute and normalized. When deserializing an AbsolutePathBuf, a base path must be set unless the path is already absolute.",
    \\  "type": "string"
    \\}
    \\
;

const NETWORK_ACCESS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "NetworkAccess",
    \\  "enum": ["restricted", "enabled"],
    \\  "type": "string"
    \\}
    \\
;

const SANDBOX_POLICY_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "SandboxPolicy",
    \\  "oneOf": [
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": { "type": { "const": "dangerFullAccess" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": {
    \\        "type": { "const": "readOnly" },
    \\        "networkAccess": { "type": "boolean", "default": false }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": {
    \\        "type": { "const": "externalSandbox" },
    \\        "networkAccess": {
    \\          "allOf": [{ "$ref": "NetworkAccess.json" }],
    \\          "default": "restricted"
    \\        }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": {
    \\        "type": { "const": "workspaceWrite" },
    \\        "writableRoots": {
    \\          "type": "array",
    \\          "items": { "$ref": "AbsolutePathBuf.json" },
    \\          "default": []
    \\        },
    \\        "networkAccess": { "type": "boolean", "default": false },
    \\        "excludeTmpdirEnvVar": { "type": "boolean", "default": false },
    \\        "excludeSlashTmp": { "type": "boolean", "default": false }
    \\      },
    \\      "additionalProperties": true
    \\    }
    \\  ]
    \\}
    \\
;

const FILE_SYSTEM_ACCESS_MODE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "FileSystemAccessMode",
    \\  "enum": ["read", "write", "none"],
    \\  "type": "string"
    \\}
    \\
;

const FILE_SYSTEM_SPECIAL_PATH_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "FileSystemSpecialPath",
    \\  "oneOf": [
    \\    {
    \\      "type": "object",
    \\      "required": ["kind"],
    \\      "properties": { "kind": { "const": "root" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["kind"],
    \\      "properties": { "kind": { "const": "minimal" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["kind"],
    \\      "properties": {
    \\        "kind": { "const": "project_roots" },
    \\        "subpath": { "type": ["string", "null"] }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["kind"],
    \\      "properties": { "kind": { "const": "tmpdir" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["kind"],
    \\      "properties": { "kind": { "const": "slash_tmp" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["kind", "path"],
    \\      "properties": {
    \\        "kind": { "const": "unknown" },
    \\        "path": { "type": "string" },
    \\        "subpath": { "type": ["string", "null"] }
    \\      },
    \\      "additionalProperties": true
    \\    }
    \\  ]
    \\}
    \\
;

const FILE_SYSTEM_PATH_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "FileSystemPath",
    \\  "oneOf": [
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "path"],
    \\      "properties": {
    \\        "type": { "const": "path" },
    \\        "path": { "$ref": "AbsolutePathBuf.json" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "pattern"],
    \\      "properties": {
    \\        "type": { "const": "glob_pattern" },
    \\        "pattern": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "value"],
    \\      "properties": {
    \\        "type": { "const": "special" },
    \\        "value": { "$ref": "FileSystemSpecialPath.json" }
    \\      },
    \\      "additionalProperties": true
    \\    }
    \\  ]
    \\}
    \\
;

const FILE_SYSTEM_SANDBOX_ENTRY_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "FileSystemSandboxEntry",
    \\  "type": "object",
    \\  "required": ["path", "access"],
    \\  "properties": {
    \\    "path": { "$ref": "FileSystemPath.json" },
    \\    "access": { "$ref": "FileSystemAccessMode.json" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const PERMISSION_PROFILE_NETWORK_PERMISSIONS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "PermissionProfileNetworkPermissions",
    \\  "type": "object",
    \\  "required": ["enabled"],
    \\  "properties": {
    \\    "enabled": { "type": "boolean" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const PERMISSION_PROFILE_FILE_SYSTEM_PERMISSIONS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "PermissionProfileFileSystemPermissions",
    \\  "oneOf": [
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "entries"],
    \\      "properties": {
    \\        "type": { "const": "restricted" },
    \\        "entries": {
    \\          "type": "array",
    \\          "items": { "$ref": "FileSystemSandboxEntry.json" }
    \\        },
    \\        "globScanMaxDepth": { "type": ["integer", "null"], "minimum": 1 }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": { "type": { "const": "unrestricted" } },
    \\      "additionalProperties": true
    \\    }
    \\  ]
    \\}
    \\
;

const PERMISSION_PROFILE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "PermissionProfile",
    \\  "oneOf": [
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "fileSystem", "network"],
    \\      "properties": {
    \\        "type": { "const": "managed" },
    \\        "fileSystem": { "$ref": "PermissionProfileFileSystemPermissions.json" },
    \\        "network": { "$ref": "PermissionProfileNetworkPermissions.json" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type"],
    \\      "properties": { "type": { "const": "disabled" } },
    \\      "additionalProperties": true
    \\    },
    \\    {
    \\      "type": "object",
    \\      "required": ["type", "network"],
    \\      "properties": {
    \\        "type": { "const": "external" },
    \\        "network": { "$ref": "PermissionProfileNetworkPermissions.json" }
    \\      },
    \\      "additionalProperties": true
    \\    }
    \\  ]
    \\}
    \\
;

const COMMAND_EXEC_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecParams",
    \\  "type": "object",
    \\  "required": ["command"],
    \\  "properties": {
    \\    "command": {
    \\      "type": "array",
    \\      "items": { "type": "string" }
    \\    },
    \\    "processId": { "type": ["string", "null"] },
    \\    "tty": { "type": "boolean" },
    \\    "streamStdin": { "type": "boolean" },
    \\    "streamStdoutStderr": { "type": "boolean" },
    \\    "outputBytesCap": { "type": ["integer", "null"], "minimum": 0 },
    \\    "disableOutputCap": { "type": "boolean" },
    \\    "disableTimeout": { "type": "boolean" },
    \\    "timeoutMs": { "type": ["integer", "null"], "minimum": 0 },
    \\    "cwd": { "type": ["string", "null"] },
    \\    "env": {
    \\      "type": ["object", "null"],
    \\      "additionalProperties": { "type": ["string", "null"] }
    \\    },
    \\    "size": {
    \\      "oneOf": [
    \\        { "$ref": "CommandExecTerminalSize.json" },
    \\        { "type": "null" }
    \\      ]
    \\    },
    \\    "sandboxPolicy": {
    \\      "oneOf": [
    \\        { "$ref": "SandboxPolicy.json" },
    \\        { "type": "null" }
    \\      ]
    \\    },
    \\    "permissionProfile": {
    \\      "oneOf": [
    \\        { "$ref": "PermissionProfile.json" },
    \\        { "type": "null" }
    \\      ]
    \\    }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const COMMAND_EXEC_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecResponse",
    \\  "type": "object",
    \\  "required": ["exitCode", "stdout", "stderr"],
    \\  "properties": {
    \\    "exitCode": { "type": "integer" },
    \\    "stdout": { "type": "string" },
    \\    "stderr": { "type": "string" }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

const COMMAND_EXEC_WRITE_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecWriteParams",
    \\  "type": "object",
    \\  "required": ["processId"],
    \\  "properties": {
    \\    "processId": { "type": "string" },
    \\    "deltaBase64": { "type": ["string", "null"] },
    \\    "closeStdin": { "type": "boolean" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const COMMAND_EXEC_TERMINATE_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecTerminateParams",
    \\  "type": "object",
    \\  "required": ["processId"],
    \\  "properties": {
    \\    "processId": { "type": "string" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const COMMAND_EXEC_RESIZE_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecResizeParams",
    \\  "type": "object",
    \\  "required": ["processId", "size"],
    \\  "properties": {
    \\    "processId": { "type": "string" },
    \\    "size": { "$ref": "CommandExecTerminalSize.json" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const COMMAND_EXEC_WRITE_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecWriteResponse",
    \\  "type": "object",
    \\  "additionalProperties": false
    \\}
    \\
;

const COMMAND_EXEC_TERMINATE_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecTerminateResponse",
    \\  "type": "object",
    \\  "additionalProperties": false
    \\}
    \\
;

const COMMAND_EXEC_RESIZE_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecResizeResponse",
    \\  "type": "object",
    \\  "additionalProperties": false
    \\}
    \\
;

const COMMAND_EXEC_OUTPUT_DELTA_NOTIFICATION_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "CommandExecOutputDeltaNotification",
    \\  "type": "object",
    \\  "required": ["processId", "stream", "deltaBase64", "capReached"],
    \\  "properties": {
    \\    "processId": { "type": "string" },
    \\    "stream": { "enum": ["stdout", "stderr"] },
    \\    "deltaBase64": { "type": "string" },
    \\    "capReached": { "type": "boolean" }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

const THREAD_LOADED_LIST_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadLoadedListParams",
    \\  "type": "object",
    \\  "properties": {
    \\    "cursor": { "type": ["string", "null"] },
    \\    "limit": { "type": ["integer", "null"], "minimum": 0, "maximum": 4294967295 }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const THREAD_LOADED_LIST_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadLoadedListResponse",
    \\  "type": "object",
    \\  "required": ["data", "nextCursor"],
    \\  "properties": {
    \\    "data": { "type": "array", "items": { "type": "string" } },
    \\    "nextCursor": { "type": ["string", "null"] }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

const THREAD_UNSUBSCRIBE_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadUnsubscribeParams",
    \\  "type": "object",
    \\  "required": ["threadId"],
    \\  "properties": {
    \\    "threadId": { "type": "string" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const THREAD_UNSUBSCRIBE_STATUS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadUnsubscribeStatus",
    \\  "enum": ["notLoaded", "notSubscribed", "unsubscribed"]
    \\}
    \\
;

const THREAD_UNSUBSCRIBE_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadUnsubscribeResponse",
    \\  "type": "object",
    \\  "required": ["status"],
    \\  "properties": {
    \\    "status": { "$ref": "ThreadUnsubscribeStatus.json" }
    \\  },
    \\  "additionalProperties": false
    \\}
    \\
;

const THREAD_COMPACT_START_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadCompactStartParams",
    \\  "type": "object",
    \\  "required": ["threadId"],
    \\  "properties": {
    \\    "threadId": { "type": "string" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const THREAD_COMPACT_START_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadCompactStartResponse",
    \\  "type": "object",
    \\  "additionalProperties": false
    \\}
    \\
;

const THREAD_SHELL_COMMAND_PARAMS_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadShellCommandParams",
    \\  "type": "object",
    \\  "required": ["threadId", "command"],
    \\  "properties": {
    \\    "threadId": { "type": "string" },
    \\    "command": { "type": "string" }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const THREAD_SHELL_COMMAND_RESPONSE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "ThreadShellCommandResponse",
    \\  "type": "object",
    \\  "additionalProperties": false
    \\}
    \\
;

const APP_SERVER_PROTOCOL_SCHEMA_BUNDLE =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "codex_app_server_protocol.schemas",
    \\  "$defs": {
    \\    "RequestId": {
    \\      "oneOf": [
    \\        { "type": "string" },
    \\        { "type": "integer" }
    \\      ]
    \\    },
    \\    "JSONRPCMessage": {
    \\      "oneOf": [
    \\        { "$ref": "#/$defs/JSONRPCRequest" },
    \\        { "$ref": "#/$defs/JSONRPCNotification" },
    \\        { "$ref": "#/$defs/JSONRPCResponse" },
    \\        { "$ref": "#/$defs/JSONRPCError" }
    \\      ]
    \\    },
    \\    "JSONRPCRequest": {
    \\      "type": "object",
    \\      "required": ["id", "method"],
    \\      "properties": {
    \\        "id": { "$ref": "#/$defs/RequestId" },
    \\        "method": { "type": "string" },
    \\        "params": true,
    \\        "trace": { "type": "object" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "JSONRPCNotification": {
    \\      "type": "object",
    \\      "required": ["method"],
    \\      "properties": {
    \\        "method": { "type": "string" },
    \\        "params": true
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "JSONRPCResponse": {
    \\      "type": "object",
    \\      "required": ["id", "result"],
    \\      "properties": {
    \\        "id": { "$ref": "#/$defs/RequestId" },
    \\        "result": true
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "JSONRPCError": {
    \\      "type": "object",
    \\      "required": ["id", "error"],
    \\      "properties": {
    \\        "id": { "$ref": "#/$defs/RequestId" },
    \\        "error": { "$ref": "#/$defs/JSONRPCErrorError" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "JSONRPCErrorError": {
    \\      "type": "object",
    \\      "required": ["code", "message"],
    \\      "properties": {
    \\        "code": { "type": "integer" },
    \\        "message": { "type": "string" },
    \\        "data": true
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "InitializeParams": {
    \\      "type": "object",
    \\      "required": ["clientInfo"],
    \\      "properties": {
    \\        "clientInfo": { "type": "object" },
    \\        "capabilities": { "type": ["object", "null"] }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "InitializeResponse": {
    \\      "type": "object",
    \\      "required": ["serverInfo", "capabilities"],
    \\      "properties": {
    \\        "serverInfo": { "type": "object" },
    \\        "capabilities": { "type": "object" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "AbsolutePathBuf": {
    \\      "type": "string"
    \\    },
    \\    "NetworkAccess": {
    \\      "enum": ["restricted", "enabled"],
    \\      "type": "string"
    \\    },
    \\    "SandboxPolicy": {
    \\      "oneOf": [
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": { "type": { "const": "dangerFullAccess" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": {
    \\            "type": { "const": "readOnly" },
    \\            "networkAccess": { "type": "boolean", "default": false }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": {
    \\            "type": { "const": "externalSandbox" },
    \\            "networkAccess": {
    \\              "allOf": [{ "$ref": "#/$defs/NetworkAccess" }],
    \\              "default": "restricted"
    \\            }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": {
    \\            "type": { "const": "workspaceWrite" },
    \\            "writableRoots": {
    \\              "type": "array",
    \\              "items": { "$ref": "#/$defs/AbsolutePathBuf" },
    \\              "default": []
    \\            },
    \\            "networkAccess": { "type": "boolean", "default": false },
    \\            "excludeTmpdirEnvVar": { "type": "boolean", "default": false },
    \\            "excludeSlashTmp": { "type": "boolean", "default": false }
    \\          },
    \\          "additionalProperties": true
    \\        }
    \\      ]
    \\    },
    \\    "FileSystemAccessMode": {
    \\      "enum": ["read", "write", "none"],
    \\      "type": "string"
    \\    },
    \\    "FileSystemSpecialPath": {
    \\      "oneOf": [
    \\        {
    \\          "type": "object",
    \\          "required": ["kind"],
    \\          "properties": { "kind": { "const": "root" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["kind"],
    \\          "properties": { "kind": { "const": "minimal" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["kind"],
    \\          "properties": {
    \\            "kind": { "const": "project_roots" },
    \\            "subpath": { "type": ["string", "null"] }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["kind"],
    \\          "properties": { "kind": { "const": "tmpdir" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["kind"],
    \\          "properties": { "kind": { "const": "slash_tmp" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["kind", "path"],
    \\          "properties": {
    \\            "kind": { "const": "unknown" },
    \\            "path": { "type": "string" },
    \\            "subpath": { "type": ["string", "null"] }
    \\          },
    \\          "additionalProperties": true
    \\        }
    \\      ]
    \\    },
    \\    "FileSystemPath": {
    \\      "oneOf": [
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "path"],
    \\          "properties": {
    \\            "type": { "const": "path" },
    \\            "path": { "$ref": "#/$defs/AbsolutePathBuf" }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "pattern"],
    \\          "properties": {
    \\            "type": { "const": "glob_pattern" },
    \\            "pattern": { "type": "string" }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "value"],
    \\          "properties": {
    \\            "type": { "const": "special" },
    \\            "value": { "$ref": "#/$defs/FileSystemSpecialPath" }
    \\          },
    \\          "additionalProperties": true
    \\        }
    \\      ]
    \\    },
    \\    "FileSystemSandboxEntry": {
    \\      "type": "object",
    \\      "required": ["path", "access"],
    \\      "properties": {
    \\        "path": { "$ref": "#/$defs/FileSystemPath" },
    \\        "access": { "$ref": "#/$defs/FileSystemAccessMode" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "PermissionProfileNetworkPermissions": {
    \\      "type": "object",
    \\      "required": ["enabled"],
    \\      "properties": {
    \\        "enabled": { "type": "boolean" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "PermissionProfileFileSystemPermissions": {
    \\      "oneOf": [
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "entries"],
    \\          "properties": {
    \\            "type": { "const": "restricted" },
    \\            "entries": {
    \\              "type": "array",
    \\              "items": { "$ref": "#/$defs/FileSystemSandboxEntry" }
    \\            },
    \\            "globScanMaxDepth": { "type": ["integer", "null"], "minimum": 1 }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": { "type": { "const": "unrestricted" } },
    \\          "additionalProperties": true
    \\        }
    \\      ]
    \\    },
    \\    "PermissionProfile": {
    \\      "oneOf": [
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "fileSystem", "network"],
    \\          "properties": {
    \\            "type": { "const": "managed" },
    \\            "fileSystem": { "$ref": "#/$defs/PermissionProfileFileSystemPermissions" },
    \\            "network": { "$ref": "#/$defs/PermissionProfileNetworkPermissions" }
    \\          },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type"],
    \\          "properties": { "type": { "const": "disabled" } },
    \\          "additionalProperties": true
    \\        },
    \\        {
    \\          "type": "object",
    \\          "required": ["type", "network"],
    \\          "properties": {
    \\            "type": { "const": "external" },
    \\            "network": { "$ref": "#/$defs/PermissionProfileNetworkPermissions" }
    \\          },
    \\          "additionalProperties": true
    \\        }
    \\      ]
    \\    },
    \\    "CommandExecParams": {
    \\      "type": "object",
    \\      "required": ["command"],
    \\      "properties": {
    \\        "command": { "type": "array", "items": { "type": "string" } },
    \\        "processId": { "type": ["string", "null"] },
    \\        "streamStdin": { "type": "boolean" },
    \\        "streamStdoutStderr": { "type": "boolean" },
    \\        "tty": { "type": "boolean" },
    \\        "sandboxPolicy": {
    \\          "oneOf": [
    \\            { "$ref": "#/$defs/SandboxPolicy" },
    \\            { "type": "null" }
    \\          ]
    \\        },
    \\        "permissionProfile": {
    \\          "oneOf": [
    \\            { "$ref": "#/$defs/PermissionProfile" },
    \\            { "type": "null" }
    \\          ]
    \\        }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "CommandExecResponse": {
    \\      "type": "object",
    \\      "required": ["exitCode", "stdout", "stderr"],
    \\      "properties": {
    \\        "exitCode": { "type": "integer" },
    \\        "stdout": { "type": "string" },
    \\        "stderr": { "type": "string" }
    \\      }
    \\    },
    \\    "CommandExecOutputDeltaNotification": {
    \\      "type": "object",
    \\      "required": ["processId", "stream", "deltaBase64", "capReached"],
    \\      "properties": {
    \\        "processId": { "type": "string" },
    \\        "stream": { "enum": ["stdout", "stderr"] },
    \\        "deltaBase64": { "type": "string" },
    \\        "capReached": { "type": "boolean" }
    \\      }
    \\    },
    \\    "ThreadLoadedListParams": {
    \\      "type": "object",
    \\      "properties": {
    \\        "cursor": { "type": ["string", "null"] },
    \\        "limit": { "type": ["integer", "null"], "minimum": 0, "maximum": 4294967295 }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "ThreadLoadedListResponse": {
    \\      "type": "object",
    \\      "required": ["data", "nextCursor"],
    \\      "properties": {
    \\        "data": { "type": "array", "items": { "type": "string" } },
    \\        "nextCursor": { "type": ["string", "null"] }
    \\      }
    \\    },
    \\    "ThreadUnsubscribeParams": {
    \\      "type": "object",
    \\      "required": ["threadId"],
    \\      "properties": {
    \\        "threadId": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "ThreadUnsubscribeStatus": {
    \\      "enum": ["notLoaded", "notSubscribed", "unsubscribed"]
    \\    },
    \\    "ThreadUnsubscribeResponse": {
    \\      "type": "object",
    \\      "required": ["status"],
    \\      "properties": {
    \\        "status": { "$ref": "#/$defs/ThreadUnsubscribeStatus" }
    \\      }
    \\    },
    \\    "ThreadCompactStartParams": {
    \\      "type": "object",
    \\      "required": ["threadId"],
    \\      "properties": {
    \\        "threadId": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "ThreadCompactStartResponse": {
    \\      "type": "object",
    \\      "additionalProperties": false
    \\    },
    \\    "ThreadShellCommandParams": {
    \\      "type": "object",
    \\      "required": ["threadId", "command"],
    \\      "properties": {
    \\        "threadId": { "type": "string" },
    \\        "command": { "type": "string" }
    \\      },
    \\      "additionalProperties": true
    \\    },
    \\    "ThreadShellCommandResponse": {
    \\      "type": "object",
    \\      "additionalProperties": false
    \\    }
    \\  }
    \\}
    \\
;

const ROLLOUT_LINE_JSON_SCHEMA =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "title": "RolloutLine",
    \\  "type": "object",
    \\  "required": ["timestamp", "type", "payload"],
    \\  "properties": {
    \\    "timestamp": {
    \\      "type": "string"
    \\    },
    \\    "type": {
    \\      "type": "string",
    \\      "enum": ["session_meta", "response_item", "compacted", "turn_context", "event_msg"]
    \\    },
    \\    "payload": {
    \\      "type": "object"
    \\    }
    \\  },
    \\  "additionalProperties": true
    \\}
    \\
;

const APP_SERVER_JSON_SCHEMA_FILES = [_]SchemaFile{
    .{ .name = "RequestId.json", .contents = REQUEST_ID_JSON_SCHEMA },
    .{ .name = "JSONRPCMessage.json", .contents = JSONRPC_MESSAGE_JSON_SCHEMA },
    .{ .name = "JSONRPCRequest.json", .contents = JSONRPC_REQUEST_JSON_SCHEMA },
    .{ .name = "JSONRPCNotification.json", .contents = JSONRPC_NOTIFICATION_JSON_SCHEMA },
    .{ .name = "JSONRPCResponse.json", .contents = JSONRPC_RESPONSE_JSON_SCHEMA },
    .{ .name = "JSONRPCError.json", .contents = JSONRPC_ERROR_JSON_SCHEMA },
    .{ .name = "JSONRPCErrorError.json", .contents = JSONRPC_ERROR_ERROR_JSON_SCHEMA },
    .{ .name = "InitializeParams.json", .contents = INITIALIZE_PARAMS_JSON_SCHEMA },
    .{ .name = "InitializeResponse.json", .contents = INITIALIZE_RESPONSE_JSON_SCHEMA },
    .{ .name = "CommandExecTerminalSize.json", .contents = COMMAND_EXEC_TERMINAL_SIZE_JSON_SCHEMA },
    .{ .name = "AbsolutePathBuf.json", .contents = ABSOLUTE_PATH_BUF_JSON_SCHEMA },
    .{ .name = "NetworkAccess.json", .contents = NETWORK_ACCESS_JSON_SCHEMA },
    .{ .name = "SandboxPolicy.json", .contents = SANDBOX_POLICY_JSON_SCHEMA },
    .{ .name = "FileSystemAccessMode.json", .contents = FILE_SYSTEM_ACCESS_MODE_JSON_SCHEMA },
    .{ .name = "FileSystemSpecialPath.json", .contents = FILE_SYSTEM_SPECIAL_PATH_JSON_SCHEMA },
    .{ .name = "FileSystemPath.json", .contents = FILE_SYSTEM_PATH_JSON_SCHEMA },
    .{ .name = "FileSystemSandboxEntry.json", .contents = FILE_SYSTEM_SANDBOX_ENTRY_JSON_SCHEMA },
    .{ .name = "PermissionProfileNetworkPermissions.json", .contents = PERMISSION_PROFILE_NETWORK_PERMISSIONS_JSON_SCHEMA },
    .{ .name = "PermissionProfileFileSystemPermissions.json", .contents = PERMISSION_PROFILE_FILE_SYSTEM_PERMISSIONS_JSON_SCHEMA },
    .{ .name = "PermissionProfile.json", .contents = PERMISSION_PROFILE_JSON_SCHEMA },
    .{ .name = "CommandExecParams.json", .contents = COMMAND_EXEC_PARAMS_JSON_SCHEMA },
    .{ .name = "CommandExecResponse.json", .contents = COMMAND_EXEC_RESPONSE_JSON_SCHEMA },
    .{ .name = "CommandExecWriteParams.json", .contents = COMMAND_EXEC_WRITE_PARAMS_JSON_SCHEMA },
    .{ .name = "CommandExecWriteResponse.json", .contents = COMMAND_EXEC_WRITE_RESPONSE_JSON_SCHEMA },
    .{ .name = "CommandExecTerminateParams.json", .contents = COMMAND_EXEC_TERMINATE_PARAMS_JSON_SCHEMA },
    .{ .name = "CommandExecTerminateResponse.json", .contents = COMMAND_EXEC_TERMINATE_RESPONSE_JSON_SCHEMA },
    .{ .name = "CommandExecResizeParams.json", .contents = COMMAND_EXEC_RESIZE_PARAMS_JSON_SCHEMA },
    .{ .name = "CommandExecResizeResponse.json", .contents = COMMAND_EXEC_RESIZE_RESPONSE_JSON_SCHEMA },
    .{ .name = "CommandExecOutputDeltaNotification.json", .contents = COMMAND_EXEC_OUTPUT_DELTA_NOTIFICATION_JSON_SCHEMA },
    .{ .name = "ThreadLoadedListParams.json", .contents = THREAD_LOADED_LIST_PARAMS_JSON_SCHEMA },
    .{ .name = "ThreadLoadedListResponse.json", .contents = THREAD_LOADED_LIST_RESPONSE_JSON_SCHEMA },
    .{ .name = "ThreadUnsubscribeParams.json", .contents = THREAD_UNSUBSCRIBE_PARAMS_JSON_SCHEMA },
    .{ .name = "ThreadUnsubscribeStatus.json", .contents = THREAD_UNSUBSCRIBE_STATUS_JSON_SCHEMA },
    .{ .name = "ThreadUnsubscribeResponse.json", .contents = THREAD_UNSUBSCRIBE_RESPONSE_JSON_SCHEMA },
    .{ .name = "ThreadCompactStartParams.json", .contents = THREAD_COMPACT_START_PARAMS_JSON_SCHEMA },
    .{ .name = "ThreadCompactStartResponse.json", .contents = THREAD_COMPACT_START_RESPONSE_JSON_SCHEMA },
    .{ .name = "ThreadShellCommandParams.json", .contents = THREAD_SHELL_COMMAND_PARAMS_JSON_SCHEMA },
    .{ .name = "ThreadShellCommandResponse.json", .contents = THREAD_SHELL_COMMAND_RESPONSE_JSON_SCHEMA },
    .{ .name = "codex_app_server_protocol.schemas.json", .contents = APP_SERVER_PROTOCOL_SCHEMA_BUNDLE },
    .{ .name = "codex_app_server_protocol.v2.schemas.json", .contents = APP_SERVER_PROTOCOL_SCHEMA_BUNDLE },
};

const APP_SERVER_TS_FILES = [_]SchemaFile{
    .{ .name = "RequestId.ts", .contents = REQUEST_ID_TS },
    .{ .name = "JSONRPCMessage.ts", .contents = JSONRPC_MESSAGE_TS },
    .{ .name = "JSONRPCRequest.ts", .contents = JSONRPC_REQUEST_TS },
    .{ .name = "JSONRPCNotification.ts", .contents = JSONRPC_NOTIFICATION_TS },
    .{ .name = "JSONRPCResponse.ts", .contents = JSONRPC_RESPONSE_TS },
    .{ .name = "JSONRPCError.ts", .contents = JSONRPC_ERROR_TS },
    .{ .name = "JSONRPCErrorError.ts", .contents = JSONRPC_ERROR_ERROR_TS },
    .{ .name = "InitializeParams.ts", .contents = INITIALIZE_PARAMS_TS },
    .{ .name = "InitializeResponse.ts", .contents = INITIALIZE_RESPONSE_TS },
    .{ .name = "ClientRequest.ts", .contents = CLIENT_REQUEST_TS },
    .{ .name = "ClientResponse.ts", .contents = CLIENT_RESPONSE_TS },
    .{ .name = "ServerNotification.ts", .contents = SERVER_NOTIFICATION_TS },
    .{ .name = "index.ts", .contents = INDEX_TS },
    .{ .name = "AbsolutePathBuf.ts", .contents = ABSOLUTE_PATH_BUF_TS },
    .{ .name = "v2/index.ts", .contents = V2_INDEX_TS },
    .{ .name = "v2/CommandExecTerminalSize.ts", .contents = COMMAND_EXEC_TERMINAL_SIZE_TS },
    .{ .name = "v2/CommandExecOutputStream.ts", .contents = COMMAND_EXEC_OUTPUT_STREAM_TS },
    .{ .name = "v2/NetworkAccess.ts", .contents = NETWORK_ACCESS_TS },
    .{ .name = "v2/SandboxPolicy.ts", .contents = SANDBOX_POLICY_TS },
    .{ .name = "v2/FileSystemAccessMode.ts", .contents = FILE_SYSTEM_ACCESS_MODE_TS },
    .{ .name = "v2/FileSystemSpecialPath.ts", .contents = FILE_SYSTEM_SPECIAL_PATH_TS },
    .{ .name = "v2/FileSystemPath.ts", .contents = FILE_SYSTEM_PATH_TS },
    .{ .name = "v2/FileSystemSandboxEntry.ts", .contents = FILE_SYSTEM_SANDBOX_ENTRY_TS },
    .{ .name = "v2/PermissionProfileNetworkPermissions.ts", .contents = PERMISSION_PROFILE_NETWORK_PERMISSIONS_TS },
    .{ .name = "v2/PermissionProfileFileSystemPermissions.ts", .contents = PERMISSION_PROFILE_FILE_SYSTEM_PERMISSIONS_TS },
    .{ .name = "v2/PermissionProfile.ts", .contents = PERMISSION_PROFILE_TS },
    .{ .name = "v2/CommandExecParams.ts", .contents = COMMAND_EXEC_PARAMS_TS },
    .{ .name = "v2/CommandExecResponse.ts", .contents = COMMAND_EXEC_RESPONSE_TS },
    .{ .name = "v2/CommandExecWriteParams.ts", .contents = COMMAND_EXEC_WRITE_PARAMS_TS },
    .{ .name = "v2/CommandExecWriteResponse.ts", .contents = COMMAND_EXEC_WRITE_RESPONSE_TS },
    .{ .name = "v2/CommandExecTerminateParams.ts", .contents = COMMAND_EXEC_TERMINATE_PARAMS_TS },
    .{ .name = "v2/CommandExecTerminateResponse.ts", .contents = COMMAND_EXEC_TERMINATE_RESPONSE_TS },
    .{ .name = "v2/CommandExecResizeParams.ts", .contents = COMMAND_EXEC_RESIZE_PARAMS_TS },
    .{ .name = "v2/CommandExecResizeResponse.ts", .contents = COMMAND_EXEC_RESIZE_RESPONSE_TS },
    .{ .name = "v2/CommandExecOutputDeltaNotification.ts", .contents = COMMAND_EXEC_OUTPUT_DELTA_NOTIFICATION_TS },
    .{ .name = "v2/ThreadLoadedListParams.ts", .contents = THREAD_LOADED_LIST_PARAMS_TS },
    .{ .name = "v2/ThreadLoadedListResponse.ts", .contents = THREAD_LOADED_LIST_RESPONSE_TS },
    .{ .name = "v2/ThreadUnsubscribeParams.ts", .contents = THREAD_UNSUBSCRIBE_PARAMS_TS },
    .{ .name = "v2/ThreadUnsubscribeStatus.ts", .contents = THREAD_UNSUBSCRIBE_STATUS_TS },
    .{ .name = "v2/ThreadUnsubscribeResponse.ts", .contents = THREAD_UNSUBSCRIBE_RESPONSE_TS },
    .{ .name = "v2/ThreadCompactStartParams.ts", .contents = THREAD_COMPACT_START_PARAMS_TS },
    .{ .name = "v2/ThreadCompactStartResponse.ts", .contents = THREAD_COMPACT_START_RESPONSE_TS },
    .{ .name = "v2/ThreadShellCommandParams.ts", .contents = THREAD_SHELL_COMMAND_PARAMS_TS },
    .{ .name = "v2/ThreadShellCommandResponse.ts", .contents = THREAD_SHELL_COMMAND_RESPONSE_TS },
};

fn writeAppServerTs(allocator: std.mem.Allocator, out_dir: []const u8, prettier: ?[]const u8, experimental: bool) !void {
    _ = prettier;
    _ = experimental;
    const io = std.Io.Threaded.global_single_threaded.io();
    const v2_out_dir = try std.fs.path.join(allocator, &.{ out_dir, "v2" });
    defer allocator.free(v2_out_dir);
    try std.Io.Dir.cwd().createDirPath(io, v2_out_dir);
    try writeSchemaFiles(allocator, out_dir, &APP_SERVER_TS_FILES);
}

fn writeAppServerJsonSchemas(allocator: std.mem.Allocator, out_dir: []const u8, experimental: bool) !void {
    _ = experimental;
    try writeSchemaFiles(allocator, out_dir, &APP_SERVER_JSON_SCHEMA_FILES);
}

fn writeRolloutLineJsonSchema(allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const files = [_]SchemaFile{.{ .name = "RolloutLine.json", .contents = ROLLOUT_LINE_JSON_SCHEMA }};
    try writeSchemaFiles(allocator, out_dir, &files);
}

fn writeSchemaFiles(allocator: std.mem.Allocator, out_dir: []const u8, files: []const SchemaFile) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    for (files) |file| {
        const schema_path = try std.fs.path.join(allocator, &.{ out_dir, file.name });
        defer allocator.free(schema_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = schema_path, .data = file.contents });
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
            try writePreResponseNotificationsStdout(self.allocator, &state);
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStdoutLine(payload);
            }
            try queueExternalFsWatchNotifications(self.allocator, &state);
            try writePendingNotificationsStdout(self.allocator, &state);
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
            try writePreResponseNotificationsStream(self.allocator, &state, &writer.interface);
            if (response) |payload| {
                defer self.allocator.free(payload);
                try writeStreamLine(&writer.interface, payload);
            }
            try queueExternalFsWatchNotifications(self.allocator, &state);
            try writePendingNotificationsStream(self.allocator, &state, &writer.interface);
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
    if (std.mem.eql(u8, method, "fuzzyFileSearch")) {
        return try handleFuzzyFileSearch(allocator, id_value.?, object.get("params"));
    }
    if (isThreadMethod(method)) {
        return try handleThreadMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isFuzzyFileSearchSessionMethod(method)) {
        return try handleFuzzyFileSearchSessionMethod(allocator, state, id_value.?, method, object.get("params"));
    }
    if (isMarketplaceMethod(method)) {
        return try handleMarketplaceMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isPluginMethod(method)) {
        return try handlePluginMethod(allocator, state, id_value.?, method, object.get("params"));
    }
    if (std.mem.eql(u8, method, "hooks/list")) {
        return try handleHooksList(allocator, id_value.?, object.get("params"));
    }
    if (std.mem.eql(u8, method, "skills/list")) {
        return try handleSkillsList(allocator, state, id_value.?, object.get("params"));
    }
    if (std.mem.eql(u8, method, "skills/config/write")) {
        return try handleSkillsConfigWrite(allocator, state, id_value.?, object.get("params"));
    }
    if (isFsMethod(method)) {
        return try handleFsMethod(allocator, state, id_value.?, method, object.get("params"));
    }
    if (isCommandExecMethod(method)) {
        return try handleCommandExecMethod(allocator, state, id_value.?, method, object.get("params"));
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
    if (isCollaborationModeMethod(method)) {
        return try handleCollaborationModeMethod(allocator, id_value.?, method, object.get("params"));
    }
    if (isExperimentalFeatureMethod(method)) {
        return try handleExperimentalFeatureMethod(allocator, state, id_value.?, method, object.get("params"));
    }
    if (isMcpServerMethod(method)) {
        return try handleMcpServerMethod(allocator, id_value.?, method, object.get("params"));
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
        memory_reset.clearMemoryStateDb(allocator, state_path) catch |err| {
            return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to clear memory state db", err);
        };
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

fn handleFuzzyFileSearch(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch params must be an object");

    const query_value = params.object.get("query") orelse return renderJsonRpcError(allocator, id_value, -32602, "query must be a string");
    if (query_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "query must be a string");

    const roots = parseFuzzyFileSearchRoots(allocator, params.object.get("roots")) catch |err| switch (err) {
        error.InvalidFuzzyFileSearchRoots => return renderJsonRpcError(allocator, id_value, -32602, "roots must be an array of strings"),
        else => return err,
    };
    defer allocator.free(roots);

    if (params.object.get("cancellationToken")) |value| {
        if (value != .null and value != .string) {
            return renderJsonRpcError(allocator, id_value, -32602, "cancellationToken must be a string or null");
        }
    }

    var results = try fuzzy_file_search.search(allocator, query_value.string, roots);
    defer results.deinit(allocator);

    const result = try renderFuzzyFileSearchResult(allocator, results);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn parseFuzzyFileSearchRoots(allocator: std.mem.Allocator, roots_value: ?std.json.Value) ![]const []const u8 {
    const value = roots_value orelse return error.InvalidFuzzyFileSearchRoots;
    if (value != .array) return error.InvalidFuzzyFileSearchRoots;
    const roots = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(roots);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidFuzzyFileSearchRoots;
        roots[index] = item.string;
    }
    return roots;
}

fn renderFuzzyFileSearchResult(allocator: std.mem.Allocator, results: fuzzy_file_search.Results) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"files\":[");
    for (results.files, 0..) |file, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendFuzzyFileSearchMatch(allocator, &out, file);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn isThreadMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "thread/loaded/list") or
        std.mem.eql(u8, method, "thread/unsubscribe") or
        std.mem.eql(u8, method, "thread/compact/start") or
        std.mem.eql(u8, method, "thread/shellCommand");
}

fn handleThreadMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "thread/loaded/list")) {
        if (validateThreadLoadedListParams(params_value)) |message| {
            return renderJsonRpcError(allocator, id_value, -32602, message);
        }
        return renderJsonRpcResult(allocator, id_value, "{\"data\":[],\"nextCursor\":null}");
    }
    if (std.mem.eql(u8, method, "thread/unsubscribe")) {
        const object = parseThreadObjectParams(params_value) catch |err| switch (err) {
            error.InvalidThreadParams => return renderThreadObjectParamsError(allocator, id_value, method),
        };
        const thread_id = requiredThreadIdParam(object) catch |err| switch (err) {
            error.MissingThreadId => return renderJsonRpcError(allocator, id_value, -32602, "threadId must be a string"),
        };
        if (!isUuidString(thread_id)) {
            return renderInvalidThreadId(allocator, id_value, thread_id);
        }
        return renderJsonRpcResult(allocator, id_value, "{\"status\":\"notLoaded\"}");
    }
    if (std.mem.eql(u8, method, "thread/compact/start")) {
        const object = parseThreadObjectParams(params_value) catch |err| switch (err) {
            error.InvalidThreadParams => return renderThreadObjectParamsError(allocator, id_value, method),
        };
        const thread_id = requiredThreadIdParam(object) catch |err| switch (err) {
            error.MissingThreadId => return renderJsonRpcError(allocator, id_value, -32602, "threadId must be a string"),
        };
        if (!isUuidString(thread_id)) {
            return renderInvalidThreadId(allocator, id_value, thread_id);
        }
        return renderThreadNotFound(allocator, id_value, thread_id);
    }
    if (std.mem.eql(u8, method, "thread/shellCommand")) {
        const object = parseThreadObjectParams(params_value) catch |err| switch (err) {
            error.InvalidThreadParams => return renderThreadObjectParamsError(allocator, id_value, method),
        };
        const thread_id = requiredThreadIdParam(object) catch |err| switch (err) {
            error.MissingThreadId => return renderJsonRpcError(allocator, id_value, -32602, "threadId must be a string"),
        };
        const command_value = object.get("command") orelse return renderJsonRpcError(allocator, id_value, -32602, "command must be a string");
        if (command_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "command must be a string");
        if (std.mem.trim(u8, command_value.string, " \t\r\n").len == 0) {
            return renderJsonRpcError(allocator, id_value, -32600, "command must not be empty");
        }
        if (!isUuidString(thread_id)) {
            return renderInvalidThreadId(allocator, id_value, thread_id);
        }
        return renderThreadNotFound(allocator, id_value, thread_id);
    }
    return renderParsedButNotImplemented(allocator, id_value, method);
}

fn parseThreadObjectParams(params_value: ?std.json.Value) !std.json.ObjectMap {
    const params = params_value orelse return error.InvalidThreadParams;
    if (params != .object) return error.InvalidThreadParams;
    return params.object;
}

fn requiredThreadIdParam(object: std.json.ObjectMap) ![]const u8 {
    const thread_id = object.get("threadId") orelse return error.MissingThreadId;
    if (thread_id != .string) return error.MissingThreadId;
    return thread_id.string;
}

fn renderThreadObjectParamsError(allocator: std.mem.Allocator, id_value: std.json.Value, method: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "{s} params must be an object", .{method});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32602, message);
}

fn renderInvalidThreadId(allocator: std.mem.Allocator, id_value: std.json.Value, thread_id: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "invalid thread id: {s}", .{thread_id});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32600, message);
}

fn renderThreadNotFound(allocator: std.mem.Allocator, id_value: std.json.Value, thread_id: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "thread not found: {s}", .{thread_id});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32600, message);
}

fn validateThreadLoadedListParams(params_value: ?std.json.Value) ?[]const u8 {
    const params = params_value orelse return null;
    if (params == .null) return null;
    if (params != .object) return "thread/loaded/list params must be an object";
    if (params.object.get("cursor")) |value| {
        if (value != .null and value != .string) return "cursor must be a string or null";
    }
    if (params.object.get("limit")) |value| {
        switch (value) {
            .null => {},
            .integer => |integer| if (integer < 0 or integer > std.math.maxInt(u32)) return "limit must be a non-negative integer or null",
            else => return "limit must be a non-negative integer or null",
        }
    }
    return null;
}

fn isFuzzyFileSearchSessionMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "fuzzyFileSearch/sessionStart") or
        std.mem.eql(u8, method, "fuzzyFileSearch/sessionUpdate") or
        std.mem.eql(u8, method, "fuzzyFileSearch/sessionStop");
}

fn handleFuzzyFileSearchSessionMethod(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "fuzzyFileSearch/sessionStart")) {
        return handleFuzzyFileSearchSessionStart(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "fuzzyFileSearch/sessionUpdate")) {
        return handleFuzzyFileSearchSessionUpdate(allocator, state, id_value, params_value);
    }
    return handleFuzzyFileSearchSessionStop(allocator, state, id_value, params_value);
}

fn handleFuzzyFileSearchSessionStart(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionStart params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionStart params must be an object");

    const session_id = parseSessionIdParam(params.object) catch |err| switch (err) {
        error.MissingFuzzySessionId => return renderJsonRpcError(allocator, id_value, -32602, "sessionId must be a string"),
        error.EmptyFuzzySessionId => return renderJsonRpcError(allocator, id_value, -32600, "sessionId must not be empty"),
    };
    const roots = parseFuzzyFileSearchRootsOwned(allocator, params.object.get("roots")) catch |err| switch (err) {
        error.InvalidFuzzyFileSearchRoots => return renderJsonRpcError(allocator, id_value, -32602, "roots must be an array of strings"),
        else => return err,
    };
    var roots_moved = false;
    errdefer if (!roots_moved) freeStringSliceList(allocator, roots);

    const owned_session_id = try allocator.dupe(u8, session_id);
    var session_id_moved = false;
    errdefer if (!session_id_moved) allocator.free(owned_session_id);
    const entry = FuzzySearchSessionEntry{
        .session_id = owned_session_id,
        .roots = roots,
    };
    if (findFuzzySearchSessionIndex(state, session_id)) |index| {
        var existing = state.fuzzy_search_sessions.items[index];
        state.fuzzy_search_sessions.items[index] = entry;
        session_id_moved = true;
        roots_moved = true;
        existing.deinit(allocator);
    } else {
        try state.fuzzy_search_sessions.append(allocator, entry);
        session_id_moved = true;
        roots_moved = true;
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFuzzyFileSearchSessionUpdate(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionUpdate params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionUpdate params must be an object");

    const session_id = parseSessionIdParam(params.object) catch return renderJsonRpcError(allocator, id_value, -32602, "sessionId must be a string");
    const query_value = params.object.get("query") orelse return renderJsonRpcError(allocator, id_value, -32602, "query must be a string");
    if (query_value != .string) return renderJsonRpcError(allocator, id_value, -32602, "query must be a string");

    const index = findFuzzySearchSessionIndex(state, session_id) orelse {
        const message = try std.fmt.allocPrint(allocator, "fuzzy file search session not found: {s}", .{session_id});
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    };
    const session = state.fuzzy_search_sessions.items[index];

    var results = try fuzzy_file_search.search(allocator, query_value.string, session.roots);
    defer results.deinit(allocator);

    const updated = try renderFuzzyFileSearchSessionUpdatedNotification(allocator, session.session_id, query_value.string, results);
    var updated_moved = false;
    errdefer if (!updated_moved) allocator.free(updated);
    try state.pending_notifications.append(allocator, updated);
    updated_moved = true;

    const completed = try renderFuzzyFileSearchSessionCompletedNotification(allocator, session.session_id);
    var completed_moved = false;
    errdefer if (!completed_moved) allocator.free(completed);
    try state.pending_notifications.append(allocator, completed);
    completed_moved = true;

    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFuzzyFileSearchSessionStop(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionStop params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "fuzzyFileSearch/sessionStop params must be an object");

    const session_id = parseSessionIdParam(params.object) catch return renderJsonRpcError(allocator, id_value, -32602, "sessionId must be a string");
    if (findFuzzySearchSessionIndex(state, session_id)) |index| {
        var removed = state.fuzzy_search_sessions.orderedRemove(index);
        removed.deinit(allocator);
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn parseSessionIdParam(object: std.json.ObjectMap) ![]const u8 {
    const session_id = object.get("sessionId") orelse return error.MissingFuzzySessionId;
    if (session_id != .string) return error.MissingFuzzySessionId;
    if (session_id.string.len == 0) return error.EmptyFuzzySessionId;
    return session_id.string;
}

fn parseFuzzyFileSearchRootsOwned(allocator: std.mem.Allocator, roots_value: ?std.json.Value) ![]const []const u8 {
    const borrowed = try parseFuzzyFileSearchRoots(allocator, roots_value);
    defer allocator.free(borrowed);
    const roots = try allocator.alloc([]const u8, borrowed.len);
    var filled: usize = 0;
    errdefer {
        for (roots[0..filled]) |root| allocator.free(root);
        allocator.free(roots);
    }
    for (borrowed, 0..) |root, index| {
        roots[index] = try allocator.dupe(u8, root);
        filled = index + 1;
    }
    return roots;
}

fn freeStringSliceList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn findFuzzySearchSessionIndex(state: *const AppServerState, session_id: []const u8) ?usize {
    for (state.fuzzy_search_sessions.items, 0..) |session, index| {
        if (std.mem.eql(u8, session.session_id, session_id)) return index;
    }
    return null;
}

fn renderFuzzyFileSearchSessionUpdatedNotification(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    query: []const u8,
    results: fuzzy_file_search.Results,
) ![]const u8 {
    const session_id_json = try std.json.Stringify.valueAlloc(allocator, session_id, .{});
    defer allocator.free(session_id_json);
    const query_json = try std.json.Stringify.valueAlloc(allocator, query, .{});
    defer allocator.free(query_json);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"fuzzyFileSearch/sessionUpdated\",\"params\":{\"sessionId\":");
    try out.appendSlice(allocator, session_id_json);
    try out.appendSlice(allocator, ",\"query\":");
    try out.appendSlice(allocator, query_json);
    try out.appendSlice(allocator, ",\"files\":[");
    for (results.files, 0..) |file, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendFuzzyFileSearchMatch(allocator, &out, file);
    }
    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
}

fn renderFuzzyFileSearchSessionCompletedNotification(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const session_id_json = try std.json.Stringify.valueAlloc(allocator, session_id, .{});
    defer allocator.free(session_id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"fuzzyFileSearch/sessionCompleted\",\"params\":{{\"sessionId\":{s}}}}}",
        .{session_id_json},
    );
}

fn appendFuzzyFileSearchMatch(allocator: std.mem.Allocator, out: *std.ArrayList(u8), file: fuzzy_file_search.Match) !void {
    const root_json = try std.json.Stringify.valueAlloc(allocator, file.root, .{});
    defer allocator.free(root_json);
    const path_json = try std.json.Stringify.valueAlloc(allocator, file.path, .{});
    defer allocator.free(path_json);
    const match_type_json = try std.json.Stringify.valueAlloc(allocator, file.match_type.jsonLabel(), .{});
    defer allocator.free(match_type_json);
    const file_name_json = try std.json.Stringify.valueAlloc(allocator, file.file_name, .{});
    defer allocator.free(file_name_json);

    try out.appendSlice(allocator, "{\"root\":");
    try out.appendSlice(allocator, root_json);
    try out.appendSlice(allocator, ",\"path\":");
    try out.appendSlice(allocator, path_json);
    try out.appendSlice(allocator, ",\"match_type\":");
    try out.appendSlice(allocator, match_type_json);
    try out.appendSlice(allocator, ",\"file_name\":");
    try out.appendSlice(allocator, file_name_json);
    try out.appendSlice(allocator, ",\"score\":");
    try appendInt(allocator, out, file.score);
    try out.appendSlice(allocator, ",\"indices\":[");
    for (file.indices, 0..) |value, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendInt(allocator, out, value);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buffer: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try out.appendSlice(allocator, rendered);
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
        return handleMarketplaceAdd(allocator, id_value, params_value.?);
    } else if (std.mem.eql(u8, method, "marketplace/remove")) {
        if (validateMarketplaceRemoveParams(params_value)) |message| {
            return try renderJsonRpcError(allocator, id_value, -32602, message);
        }
        return handleMarketplaceRemove(allocator, id_value, params_value.?);
    } else if (std.mem.eql(u8, method, "marketplace/upgrade")) {
        if (validateMarketplaceUpgradeParams(params_value)) |message| {
            return try renderJsonRpcError(allocator, id_value, -32602, message);
        }
        return handleMarketplaceUpgrade(allocator, id_value, params_value);
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "app-server method {s} is parsed but not implemented yet",
        .{method},
    );
    defer allocator.free(message);
    return try renderJsonRpcError(allocator, id_value, -32603, message);
}

fn handleMarketplaceAdd(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: std.json.Value) ![]const u8 {
    const object = params_value.object;
    const source = object.get("source").?.string;
    const ref_name = optionalStringField(object, "refName");
    const sparse_paths = try optionalStringArray(allocator, object, "sparsePaths");
    defer allocator.free(sparse_paths);

    const codex_home = resolveCodexHome(allocator) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to resolve CODEX_HOME", err);
    };
    defer allocator.free(codex_home);

    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to read config.toml", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const add = marketplace_config.addMarketplace(allocator, codex_home, config_bytes orelse "", source, ref_name, sparse_paths) catch |err| {
        return renderMarketplaceAddError(allocator, id_value, err);
    };
    defer add.deinit(allocator);

    config.writeConfigTomlFile(config_path, add.updated_config) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to write config.toml", err);
    };

    const result = try renderMarketplaceAddResult(allocator, add.marketplace_name, add.installed_root, add.already_added);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleMarketplaceRemove(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: std.json.Value) ![]const u8 {
    const marketplace_name = params_value.object.get("marketplaceName").?.string;
    const codex_home = resolveCodexHome(allocator) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to resolve CODEX_HOME", err);
    };
    defer allocator.free(codex_home);

    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to read config.toml", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const removed = marketplace_config.removeMarketplace(allocator, codex_home, config_bytes orelse "", marketplace_name) catch |err| {
        return renderMarketplaceRemoveError(allocator, id_value, marketplace_name, err);
    };
    defer removed.deinit(allocator);

    config.writeConfigTomlFile(config_path, removed.updated_config) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to write config.toml", err);
    };

    const result = try renderMarketplaceRemoveResult(allocator, removed.marketplace_name, removed.installed_root);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handleMarketplaceUpgrade(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const marketplace_name = if (params_value) |value| optionalStringField(value.object, "marketplaceName") else null;
    const codex_home = resolveCodexHome(allocator) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to resolve CODEX_HOME", err);
    };
    defer allocator.free(codex_home);

    const config_path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to read config.toml", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const upgraded = marketplace_config.upgradeMarketplaces(allocator, codex_home, config_bytes orelse "", marketplace_name) catch |err| {
        return renderMarketplaceUpgradeError(allocator, id_value, marketplace_name, err);
    };
    defer upgraded.deinit(allocator);

    if (upgraded.upgraded_roots.len > 0) {
        config.writeConfigTomlFile(config_path, upgraded.updated_config) catch |err| {
            return try renderJsonRpcErrorForFailure(allocator, id_value, "failed to write config.toml", err);
        };
    }

    const result = try renderMarketplaceUpgradeResult(allocator, upgraded);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn optionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    return value.string;
}

fn optionalStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) ![]const []const u8 {
    const value = object.get(field) orelse return allocator.alloc([]const u8, 0);
    if (value == .null) return allocator.alloc([]const u8, 0);
    var values = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        values[index] = item.string;
    }
    return values;
}

fn renderMarketplaceAddError(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror) ![]const u8 {
    return switch (err) {
        error.InvalidMarketplaceSourceFormat => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace source format; expected owner/repo, a git URL, or a local marketplace path"),
        error.MarketplaceSourceEmpty => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: marketplace source must not be empty"),
        error.RefUnsupportedForLocalSource => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: --ref is only supported for git marketplace sources"),
        error.SparseUnsupportedForLocalSource => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: --sparse is only supported for git marketplace sources"),
        error.InvalidLocalMarketplaceSource => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: failed to resolve local marketplace source path"),
        error.LocalMarketplaceSourceMustBeDirectory => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: local marketplace source must be a directory, not a file"),
        error.InvalidMarketplaceRoot => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace root"),
        error.InvalidMarketplaceName => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace name"),
        error.ReservedMarketplaceName => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: marketplace 'openai-curated' is reserved and cannot be added from this source"),
        error.MarketplaceAlreadyAddedDifferentSource => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: marketplace is already added from a different source; remove it before adding this source"),
        error.GitCommandFailed => renderJsonRpcError(allocator, id_value, -32603, "failed to clone marketplace git source"),
        else => renderJsonRpcErrorForFailure(allocator, id_value, "failed to add marketplace", err),
    };
}

fn renderMarketplaceUpgradeError(allocator: std.mem.Allocator, id_value: std.json.Value, marketplace_name: ?[]const u8, err: anyerror) ![]const u8 {
    return switch (err) {
        error.MarketplaceNotConfiguredAsGit => blk: {
            const name = marketplace_name orelse "";
            const message = try std.fmt.allocPrint(allocator, "Invalid request: marketplace `{s}` is not configured as a Git marketplace", .{name});
            defer allocator.free(message);
            break :blk renderJsonRpcError(allocator, id_value, -32600, message);
        },
        else => renderJsonRpcErrorForFailure(allocator, id_value, "failed to upgrade marketplace", err),
    };
}

fn renderMarketplaceRemoveError(allocator: std.mem.Allocator, id_value: std.json.Value, marketplace_name: []const u8, err: anyerror) ![]const u8 {
    return switch (err) {
        error.InvalidMarketplaceName => renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace name"),
        error.UnknownMarketplace => blk: {
            const message = try std.fmt.allocPrint(allocator, "marketplace `{s}` is not configured or installed", .{marketplace_name});
            defer allocator.free(message);
            break :blk renderJsonRpcError(allocator, id_value, -32600, message);
        },
        else => renderJsonRpcErrorForFailure(allocator, id_value, "failed to remove marketplace", err),
    };
}

fn renderMarketplaceAddResult(allocator: std.mem.Allocator, marketplace_name: []const u8, installed_root: []const u8, already_added: bool) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"marketplaceName\":");
    try appendJsonString(allocator, &result, marketplace_name);
    try result.appendSlice(allocator, ",\"installedRoot\":");
    try appendJsonString(allocator, &result, installed_root);
    try result.appendSlice(allocator, ",\"alreadyAdded\":");
    try result.appendSlice(allocator, if (already_added) "true" else "false");
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn renderMarketplaceRemoveResult(allocator: std.mem.Allocator, marketplace_name: []const u8, installed_root: ?[]const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"marketplaceName\":");
    try appendJsonString(allocator, &result, marketplace_name);
    try result.appendSlice(allocator, ",\"installedRoot\":");
    if (installed_root) |path| {
        try appendJsonString(allocator, &result, path);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn renderMarketplaceUpgradeResult(allocator: std.mem.Allocator, upgraded: marketplace_config.UpgradeResult) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"selectedMarketplaces\":");
    try appendJsonStringArray(allocator, &result, upgraded.selected_marketplaces);
    try result.appendSlice(allocator, ",\"upgradedRoots\":");
    try appendJsonStringArray(allocator, &result, upgraded.upgraded_roots);
    try result.appendSlice(allocator, ",\"errors\":[");
    for (upgraded.errors, 0..) |failure, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try result.appendSlice(allocator, "{\"marketplaceName\":");
        try appendJsonString(allocator, &result, failure.marketplace_name);
        try result.appendSlice(allocator, ",\"message\":");
        try appendJsonString(allocator, &result, failure.message);
        try result.appendSlice(allocator, "}");
    }
    try result.appendSlice(allocator, "]}");
    return result.toOwnedSlice(allocator);
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
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "plugin/list")) {
        return handlePluginList(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/read")) {
        return handlePluginRead(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/skill/read")) {
        return handlePluginSkillRead(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/share/save")) {
        return handlePluginShareSave(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/share/updateTargets")) {
        return handlePluginShareUpdateTargets(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/share/list")) {
        return handlePluginShareList(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/share/delete")) {
        return handlePluginShareDelete(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/install")) {
        return handlePluginInstall(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "plugin/uninstall")) {
        return handlePluginUninstall(allocator, state, id_value, params_value);
    }

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

fn handlePluginSkillRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parsePluginSkillReadParams(params_value) catch |err| switch (err) {
        error.InvalidPluginSkillReadParams => return renderJsonRpcError(allocator, id_value, -32602, "plugin/skill/read params must be an object"),
        error.InvalidPluginSkillReadRemoteMarketplaceName => return renderJsonRpcError(allocator, id_value, -32602, "remoteMarketplaceName must be a string"),
        error.InvalidPluginSkillReadRemotePluginId => return renderJsonRpcError(allocator, id_value, -32602, "remotePluginId must be a string"),
        error.InvalidPluginSkillReadSkillName => return renderJsonRpcError(allocator, id_value, -32602, "skillName must be a string"),
    };
    if (!remote_plugin.isKnownRemoteMarketplace(params.remote_marketplace_name)) {
        const message = try std.fmt.allocPrint(allocator, "unknown remote plugin marketplace: {s}", .{params.remote_marketplace_name});
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }
    if (!remote_plugin.isValidRemotePluginId(params.remote_plugin_id)) {
        const message = try std.fmt.allocPrint(allocator, "invalid remote plugin id: {s}", .{params.remote_plugin_id});
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }
    if (params.skill_name.len == 0) {
        return renderJsonRpcError(allocator, id_value, -32600, "invalid remote plugin skill name: cannot be empty");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/skill/read failed to load config", err);
    };
    defer cfg.deinit(allocator);

    const config_path = config.configTomlPath(allocator, cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/skill/read failed to load config", err);
    };
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/skill/read failed to load config", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);
    if (!plugin_config.pluginsFeatureEnabled(config_bytes orelse "")) {
        const message = try std.fmt.allocPrint(
            allocator,
            "remote plugin skill read is not enabled for marketplace {s}",
            .{params.remote_marketplace_name},
        );
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }

    var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
        error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to read remote plugin skill details"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/skill/read failed to load auth", err),
    };
    defer credentials.deinit(allocator);
    switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
        .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to read remote plugin skill details"),
    }

    const result = remote_plugin.fetchSkillReadJson(allocator, cfg.chatgpt_base_url, credentials, params.remote_plugin_id, params.skill_name) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/skill/read failed to fetch remote plugin skill details", err);
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

const ParsedPluginSkillReadParams = struct {
    remote_marketplace_name: []const u8,
    remote_plugin_id: []const u8,
    skill_name: []const u8,
};

fn parsePluginSkillReadParams(params_value: ?std.json.Value) !ParsedPluginSkillReadParams {
    const params = params_value orelse return error.InvalidPluginSkillReadParams;
    if (params != .object) return error.InvalidPluginSkillReadParams;
    const object = params.object;
    const remote_marketplace_name = stringFieldForPluginParams(object, "remoteMarketplaceName") orelse return error.InvalidPluginSkillReadRemoteMarketplaceName;
    const remote_plugin_id = stringFieldForPluginParams(object, "remotePluginId") orelse return error.InvalidPluginSkillReadRemotePluginId;
    const skill_name = stringFieldForPluginParams(object, "skillName") orelse return error.InvalidPluginSkillReadSkillName;
    return .{
        .remote_marketplace_name = remote_marketplace_name,
        .remote_plugin_id = remote_plugin_id,
        .skill_name = skill_name,
    };
}

fn handlePluginShareSave(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (validatePluginShareSaveParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }
    const params = parsePluginShareSaveParams(params_value);
    if (!std.fs.path.isAbsolute(params.plugin_path)) {
        return renderJsonRpcError(allocator, id_value, -32600, FS_ABSOLUTE_PATH_MESSAGE);
    }
    if (params.remote_plugin_id) |remote_plugin_id| {
        if (!remote_plugin.isValidRemotePluginId(remote_plugin_id)) {
            return renderJsonRpcError(allocator, id_value, -32600, "invalid remote plugin id");
        }
        if (params.discoverability != null or params.share_targets != null) {
            return renderJsonRpcError(
                allocator,
                id_value,
                -32600,
                "discoverability and shareTargets are only supported when creating a plugin share; use plugin/share/updateTargets to update share targets",
            );
        }
    }

    var context = loadRemotePluginShareContext(allocator) catch |err| {
        return renderRemotePluginShareContextError(allocator, id_value, "plugin/share/save", err);
    };
    defer context.deinit(allocator);

    const result = remote_plugin.saveShareJson(
        allocator,
        context.cfg.chatgpt_base_url,
        context.credentials,
        context.cfg.codex_home,
        params.plugin_path,
        params.remote_plugin_id,
        params.discoverability,
        params.share_targets,
    ) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/share/save failed to save remote plugin share", err);
    };
    defer allocator.free(result);
    clearSkillsListCache(allocator, state);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handlePluginShareList(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (validateOptionalObjectParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }

    var context = loadRemotePluginShareContext(allocator) catch |err| {
        return renderRemotePluginShareContextError(allocator, id_value, "plugin/share/list", err);
    };
    defer context.deinit(allocator);

    const result = remote_plugin.fetchShareListJson(allocator, context.cfg.chatgpt_base_url, context.credentials, context.cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/share/list failed to list remote plugin shares", err);
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handlePluginShareUpdateTargets(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (validatePluginShareUpdateTargetsParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }
    const params = parsePluginShareUpdateTargetsParams(params_value);
    if (!remote_plugin.isValidRemotePluginId(params.remote_plugin_id)) {
        return renderJsonRpcError(allocator, id_value, -32600, "invalid remote plugin id");
    }

    var context = loadRemotePluginShareContext(allocator) catch |err| {
        return renderRemotePluginShareContextError(allocator, id_value, "plugin/share/updateTargets", err);
    };
    defer context.deinit(allocator);

    const result = remote_plugin.updateShareTargetsJson(allocator, context.cfg.chatgpt_base_url, context.credentials, params.remote_plugin_id, params.share_targets) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/share/updateTargets failed to update remote plugin share targets", err);
    };
    defer allocator.free(result);
    clearSkillsListCache(allocator, state);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn handlePluginShareDelete(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    if (validatePluginShareDeleteParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }
    const remote_plugin_id = parsePluginShareDeleteParams(params_value);
    if (!remote_plugin.isValidRemotePluginId(remote_plugin_id)) {
        return renderJsonRpcError(allocator, id_value, -32600, "invalid remote plugin id");
    }

    var context = loadRemotePluginShareContext(allocator) catch |err| {
        return renderRemotePluginShareContextError(allocator, id_value, "plugin/share/delete", err);
    };
    defer context.deinit(allocator);

    remote_plugin.deleteShare(allocator, context.cfg.chatgpt_base_url, context.credentials, context.cfg.codex_home, remote_plugin_id) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/share/delete failed to delete remote plugin share", err);
    };
    clearSkillsListCache(allocator, state);
    return renderJsonRpcResult(allocator, id_value, "{}");
}

const RemotePluginShareContext = struct {
    cfg: config.Config,
    credentials: auth_mod.Credentials,

    fn deinit(self: *RemotePluginShareContext, allocator: std.mem.Allocator) void {
        self.credentials.deinit(allocator);
        self.cfg.deinit(allocator);
    }
};

fn loadRemotePluginShareContext(allocator: std.mem.Allocator) !RemotePluginShareContext {
    var cfg = try config.loadWithOptions(allocator, .{});
    errdefer cfg.deinit(allocator);

    const config_path = try config.configTomlPath(allocator, cfg.codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    if (!plugin_config.pluginsFeatureEnabled(config_bytes orelse "")) {
        return error.RemotePluginShareFeatureDisabled;
    }

    var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
        error.NoUsableAuth => return error.RemotePluginShareAuthRequired,
        else => return err,
    };
    errdefer credentials.deinit(allocator);
    switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
        .api_key, .local_oss => return error.RemotePluginShareAuthRequired,
    }

    return .{ .cfg = cfg, .credentials = credentials };
}

fn renderRemotePluginShareContextError(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    err: anyerror,
) ![]const u8 {
    if (err == error.RemotePluginShareFeatureDisabled) {
        return renderJsonRpcError(allocator, id_value, -32600, "plugin sharing is not enabled");
    }
    if (err == error.RemotePluginShareAuthRequired) {
        return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to share plugins");
    }

    const context = try std.fmt.allocPrint(allocator, "{s} failed to load remote plugin share context", .{method});
    defer allocator.free(context);
    return renderJsonRpcErrorForFailure(allocator, id_value, context, err);
}

const ParsedPluginShareUpdateTargetsParams = struct {
    remote_plugin_id: []const u8,
    share_targets: []const std.json.Value,
};

const ParsedPluginShareSaveParams = struct {
    plugin_path: []const u8,
    remote_plugin_id: ?[]const u8,
    discoverability: ?[]const u8,
    share_targets: ?[]const std.json.Value,
};

fn parsePluginShareSaveParams(params_value: ?std.json.Value) ParsedPluginShareSaveParams {
    const object = params_value.?.object;
    const remote_plugin_id = optionalStringFieldForPluginParams(object, "remotePluginId");
    const discoverability = optionalStringFieldForPluginParams(object, "discoverability");
    const share_targets = if (object.get("shareTargets")) |value|
        if (value == .null) null else value.array.items
    else
        null;
    return .{
        .plugin_path = object.get("pluginPath").?.string,
        .remote_plugin_id = remote_plugin_id,
        .discoverability = discoverability,
        .share_targets = share_targets,
    };
}

fn parsePluginShareUpdateTargetsParams(params_value: ?std.json.Value) ParsedPluginShareUpdateTargetsParams {
    const params = params_value.?;
    const object = params.object;
    return .{
        .remote_plugin_id = object.get("remotePluginId").?.string,
        .share_targets = object.get("shareTargets").?.array.items,
    };
}

fn parsePluginShareDeleteParams(params_value: ?std.json.Value) []const u8 {
    return params_value.?.object.get("remotePluginId").?.string;
}

fn handlePluginInstall(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parsePluginReadParams(params_value) catch |err| switch (err) {
        error.InvalidPluginReadParams => return renderJsonRpcError(allocator, id_value, -32602, "plugin/install params must be an object"),
        error.InvalidPluginReadPluginName => return renderJsonRpcError(allocator, id_value, -32602, "pluginName must be a string"),
        error.InvalidPluginReadSource => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugin/install requires exactly one of marketplacePath or remoteMarketplaceName"),
        error.InvalidPluginReadMarketplacePath => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: marketplacePath must be an absolute path"),
    };

    if (params.remote_marketplace_name) |remote_marketplace_name| {
        if (!remote_plugin.isValidRemotePluginId(params.plugin_name)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "invalid remote plugin id: {s}; only ASCII letters, digits, `_`, `-`, and `~` are allowed",
                .{params.plugin_name},
            );
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }

        var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to load config", err);
        };
        defer cfg.deinit(allocator);
        const config_path = config.configTomlPath(allocator, cfg.codex_home) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to load config", err);
        };
        defer allocator.free(config_path);
        const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to load config", err);
        };
        defer if (config_bytes) |bytes| allocator.free(bytes);
        if (!plugin_config.pluginsFeatureEnabled(config_bytes orelse "")) {
            const message = try std.fmt.allocPrint(
                allocator,
                "remote plugin install is not enabled for marketplace {s}",
                .{remote_marketplace_name},
            );
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }

        var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
            error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to install remote plugin"),
            else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to load auth", err),
        };
        defer credentials.deinit(allocator);
        switch (credentials.mode) {
            .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
            .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to install remote plugin"),
        }

        const install_result = remote_plugin.install(
            allocator,
            cfg.chatgpt_base_url,
            credentials,
            cfg.codex_home,
            params.plugin_name,
        ) catch |err| switch (err) {
            error.RemotePluginDisabledByAdmin => {
                const message = try std.fmt.allocPrint(allocator, "remote plugin {s} is disabled by admin", .{params.plugin_name});
                defer allocator.free(message);
                return renderJsonRpcError(allocator, id_value, -32600, message);
            },
            error.RemotePluginNotAvailable => {
                const message = try std.fmt.allocPrint(allocator, "remote plugin {s} is not available for install", .{params.plugin_name});
                defer allocator.free(message);
                return renderJsonRpcError(allocator, id_value, -32600, message);
            },
            error.RemotePluginInsecureBundleDownloadUrl => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: remote plugin bundle URL must use HTTPS"),
            else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to install remote plugin", err),
        };
        defer install_result.deinit(allocator);
        clearSkillsListCache(allocator, state);
        return renderJsonRpcResult(allocator, id_value, install_result.response_json);
    }

    const marketplace_path = params.marketplace_path.?;
    const codex_home = resolveCodexHome(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed", err);
    };
    defer allocator.free(codex_home);

    const config_path = config.configTomlPath(allocator, codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed", err);
    };
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const install = plugin_list.installLocalPlugin(allocator, codex_home, config_bytes orelse "", marketplace_path, params.plugin_name) catch |err| switch (err) {
        plugin_list.InstallError.InvalidMarketplaceFile => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace file"),
        plugin_list.InstallError.PluginNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Invalid request: plugin `{s}` was not found", .{params.plugin_name});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        },
        plugin_list.InstallError.MissingPluginManifest => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: missing or invalid plugin.json"),
        plugin_list.InstallError.PluginsDisabled => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugins are disabled"),
        plugin_list.InstallError.UnsupportedInstallSource => return renderJsonRpcError(allocator, id_value, -32603, "plugin/install source is parsed but not implemented yet"),
        plugin_list.InstallError.PluginNotAvailable => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugin is not available for install"),
        plugin_list.InstallError.InvalidPluginId => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid plugin id"),
        plugin_list.InstallError.PluginNameMismatch => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugin.json name does not match marketplace plugin name"),
        plugin_list.InstallError.InvalidPluginVersion => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid plugin version"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed", err),
    };
    defer install.deinit(allocator);

    config.writeConfigTomlFile(config_path, install.updated_config) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/install failed to write config", err);
    };
    clearSkillsListCache(allocator, state);
    return renderJsonRpcResult(allocator, id_value, install.response_json);
}

fn handlePluginUninstall(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parsePluginUninstallParams(params_value) catch |err| switch (err) {
        error.InvalidPluginUninstallParams => return renderJsonRpcError(allocator, id_value, -32602, "plugin/uninstall params must be an object"),
        error.InvalidPluginUninstallPluginId => return renderJsonRpcError(allocator, id_value, -32602, "pluginId must be a string"),
    };
    const remote_plugin_id = remote_plugin.isValidRemotePluginId(params.plugin_id);
    if (!remote_plugin_id and !plugin_config.isValidPluginId(params.plugin_id)) {
        return renderJsonRpcError(allocator, id_value, -32600, "invalid remote plugin id");
    }
    if (!remote_plugin_id) {
        handleLocalPluginUninstall(allocator, params.plugin_id) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to uninstall plugin", err);
        };
        clearSkillsListCache(allocator, state);
        return renderJsonRpcResult(allocator, id_value, "{}");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to load config", err);
    };
    defer cfg.deinit(allocator);

    const config_path = config.configTomlPath(allocator, cfg.codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to load config", err);
    };
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to load config", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);
    if (!plugin_config.pluginsFeatureEnabled(config_bytes orelse "")) {
        return renderJsonRpcError(allocator, id_value, -32600, "remote plugin uninstall is not enabled");
    }

    var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
        error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to uninstall remote plugin"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to load auth", err),
    };
    defer credentials.deinit(allocator);
    switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
        .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to uninstall remote plugin"),
    }

    remote_plugin.uninstall(allocator, cfg.chatgpt_base_url, credentials, cfg.codex_home, params.plugin_id) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/uninstall failed to uninstall remote plugin", err);
    };
    clearSkillsListCache(allocator, state);
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleLocalPluginUninstall(allocator: std.mem.Allocator, plugin_id: []const u8) !void {
    var cfg = try config.loadWithOptions(allocator, .{});
    defer cfg.deinit(allocator);

    const plugin_base_root = (try plugin_config.localPluginBaseRoot(allocator, cfg.codex_home, plugin_id)) orelse return error.InvalidPluginId;
    defer allocator.free(plugin_base_root);
    try deletePathIfPresent(allocator, plugin_base_root);

    const config_path = try config.configTomlPath(allocator, cfg.codex_home);
    defer allocator.free(config_path);
    const config_bytes = try config.readConfigTomlFile(allocator, config_path);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const updated_config = try plugin_config.removePluginConfig(allocator, config_bytes orelse "", plugin_id);
    defer allocator.free(updated_config);
    if (!std.mem.eql(u8, updated_config, config_bytes orelse "")) {
        try config.writeConfigTomlFile(config_path, updated_config);
    }
}

fn deletePathIfPresent(allocator: std.mem.Allocator, path: []const u8) !void {
    const metadata = (try statPathNoFollow(allocator, path)) orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const mode: u32 = @intCast(metadata.mode);
    if (std.c.S.ISDIR(mode)) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    } else {
        try std.Io.Dir.deleteFileAbsolute(io, path);
    }
}

const ParsedPluginUninstallParams = struct {
    plugin_id: []const u8,
};

fn parsePluginUninstallParams(params_value: ?std.json.Value) !ParsedPluginUninstallParams {
    const params = params_value orelse return error.InvalidPluginUninstallParams;
    if (params != .object) return error.InvalidPluginUninstallParams;
    const plugin_id = stringFieldForPluginParams(params.object, "pluginId") orelse return error.InvalidPluginUninstallPluginId;
    return .{ .plugin_id = plugin_id };
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

fn handlePluginList(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parsePluginListParams(allocator, params_value) catch |err| switch (err) {
        error.InvalidPluginListParams => return renderJsonRpcError(allocator, id_value, -32602, "plugin/list params must be an object"),
        error.InvalidPluginListCwds => return renderJsonRpcError(allocator, id_value, -32602, "cwds must be an array of strings or null"),
        error.InvalidPluginListCwdPath => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugin/list cwds must be absolute paths"),
        error.InvalidPluginListMarketplaceKinds => return renderJsonRpcError(allocator, id_value, -32602, "marketplaceKinds must be an array of strings or null"),
        error.InvalidPluginListMarketplaceKind => return renderJsonRpcError(allocator, id_value, -32602, "unknown marketplace kind"),
        else => return err,
    };
    defer params.deinit(allocator);

    const codex_home = resolveCodexHome(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/list failed", err);
    };
    defer allocator.free(codex_home);

    const config_path = config.configTomlPath(allocator, codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/list failed", err);
    };
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/list failed", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);
    const raw_config_bytes = config_bytes orelse "";

    var remote_marketplaces_json: ?[]const u8 = null;
    defer if (remote_marketplaces_json) |json| allocator.free(json);
    if (plugin_config.pluginsFeatureEnabled(raw_config_bytes)) {
        const remote_sources = params.remoteSources(raw_config_bytes);
        if (!remote_sources.isEmpty()) {
            remote_marketplaces_json = fetchRemotePluginListMarketplaces(allocator, codex_home, remote_sources) catch null;
        }
    }

    const result = plugin_list.renderResponseWithRemoteMarketplaces(allocator, codex_home, raw_config_bytes, params.cwds, params.include_local(), remote_marketplaces_json) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/list failed", err);
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn parsePluginListParams(allocator: std.mem.Allocator, params_value: ?std.json.Value) !ParsedPluginListParams {
    const params = params_value orelse return .{ .cwds = try allocator.alloc([]const u8, 0), .marketplace_kinds = .{} };
    if (params == .null) return .{ .cwds = try allocator.alloc([]const u8, 0), .marketplace_kinds = .{} };
    if (params != .object) return error.InvalidPluginListParams;

    const cwds = try parsePluginListCwds(allocator, params.object.get("cwds"));
    errdefer allocator.free(cwds);
    const marketplace_kinds = try parsePluginListMarketplaceKinds(params.object.get("marketplaceKinds"));
    return .{ .cwds = cwds, .marketplace_kinds = marketplace_kinds };
}

fn parsePluginListCwds(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const []const u8 {
    const value = value_opt orelse return allocator.alloc([]const u8, 0);
    if (value == .null) return allocator.alloc([]const u8, 0);
    if (value != .array) return error.InvalidPluginListCwds;
    const cwds = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(cwds);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidPluginListCwds;
        if (item.string.len == 0 or !std.fs.path.isAbsolute(item.string)) return error.InvalidPluginListCwdPath;
        cwds[index] = item.string;
    }
    return cwds;
}

fn parsePluginListMarketplaceKinds(value_opt: ?std.json.Value) !PluginListMarketplaceKinds {
    const value = value_opt orelse return .{};
    if (value == .null) return .{};
    if (value != .array) return error.InvalidPluginListMarketplaceKinds;
    var kinds = PluginListMarketplaceKinds{ .explicit = true, .include_local = false };
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidPluginListMarketplaceKinds;
        if (!isPluginMarketplaceKind(item.string)) return error.InvalidPluginListMarketplaceKind;
        if (std.mem.eql(u8, item.string, "local")) kinds.include_local = true;
        if (std.mem.eql(u8, item.string, "workspace-directory")) kinds.include_workspace_directory = true;
        if (std.mem.eql(u8, item.string, "shared-with-me")) kinds.include_shared_with_me = true;
    }
    return kinds;
}

fn fetchRemotePluginListMarketplaces(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    remote_sources: remote_plugin.MarketplaceSources,
) ![]const u8 {
    var cfg = try config.loadWithOptions(allocator, .{});
    defer cfg.deinit(allocator);

    var credentials = try auth_mod.load(allocator, codex_home);
    defer credentials.deinit(allocator);
    switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
        .api_key, .local_oss => return error.RemotePluginUnsupportedAuthMode,
    }

    return remote_plugin.fetchMarketplacesJson(allocator, cfg.chatgpt_base_url, credentials, remote_sources);
}

fn handlePluginRead(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parsePluginReadParams(params_value) catch |err| switch (err) {
        error.InvalidPluginReadParams => return renderJsonRpcError(allocator, id_value, -32602, "plugin/read params must be an object"),
        error.InvalidPluginReadPluginName => return renderJsonRpcError(allocator, id_value, -32602, "pluginName must be a string"),
        error.InvalidPluginReadSource => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugin/read requires exactly one of marketplacePath or remoteMarketplaceName"),
        error.InvalidPluginReadMarketplacePath => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: marketplacePath must be an absolute path"),
    };

    if (params.remote_marketplace_name) |remote_marketplace_name| {
        if (!remote_plugin.isValidRemotePluginId(params.plugin_name)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "invalid remote plugin id: {s}; only ASCII letters, digits, `_`, `-`, and `~` are allowed",
                .{params.plugin_name},
            );
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }

        var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed to load config", err);
        };
        defer cfg.deinit(allocator);

        const config_path = config.configTomlPath(allocator, cfg.codex_home) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed to load config", err);
        };
        defer allocator.free(config_path);
        const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed to load config", err);
        };
        defer if (config_bytes) |bytes| allocator.free(bytes);
        if (!plugin_config.pluginsFeatureEnabled(config_bytes orelse "")) {
            const message = try std.fmt.allocPrint(
                allocator,
                "remote plugin read is not enabled for marketplace {s}",
                .{remote_marketplace_name},
            );
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        }

        var credentials = auth_mod.load(allocator, cfg.codex_home) catch |err| switch (err) {
            error.NoUsableAuth => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to read remote plugin details"),
            else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed to load auth", err),
        };
        defer credentials.deinit(allocator);
        switch (credentials.mode) {
            .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
            .api_key, .local_oss => return renderJsonRpcError(allocator, id_value, -32602, "chatgpt authentication required to read remote plugin details"),
        }

        const result = remote_plugin.fetchReadJson(allocator, cfg.chatgpt_base_url, credentials, params.plugin_name) catch |err| {
            return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed to fetch remote plugin details", err);
        };
        defer allocator.free(result);
        return renderJsonRpcResult(allocator, id_value, result);
    }
    const marketplace_path = params.marketplace_path.?;

    const codex_home = resolveCodexHome(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed", err);
    };
    defer allocator.free(codex_home);

    const config_path = config.configTomlPath(allocator, codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed", err);
    };
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const result = plugin_list.renderReadResponse(allocator, codex_home, config_bytes orelse "", marketplace_path, params.plugin_name) catch |err| switch (err) {
        plugin_list.ReadError.InvalidMarketplaceFile => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: invalid marketplace file"),
        plugin_list.ReadError.PluginNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Invalid request: plugin `{s}` was not found", .{params.plugin_name});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32600, message);
        },
        plugin_list.ReadError.MissingPluginManifest => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: missing or invalid plugin.json"),
        plugin_list.ReadError.PluginsDisabled => return renderJsonRpcError(allocator, id_value, -32600, "Invalid request: plugins are disabled"),
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "plugin/read failed", err),
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

const ParsedPluginReadParams = struct {
    plugin_name: []const u8,
    marketplace_path: ?[]const u8,
    remote_marketplace_name: ?[]const u8,
};

fn parsePluginReadParams(params_value: ?std.json.Value) !ParsedPluginReadParams {
    const params = params_value orelse return error.InvalidPluginReadParams;
    if (params != .object) return error.InvalidPluginReadParams;
    const object = params.object;
    const plugin_name = stringFieldForPluginParams(object, "pluginName") orelse return error.InvalidPluginReadPluginName;
    const marketplace_path = optionalStringForPluginParams(object, "marketplacePath") catch return error.InvalidPluginReadParams;
    const remote_marketplace_name = optionalStringForPluginParams(object, "remoteMarketplaceName") catch return error.InvalidPluginReadParams;
    if ((marketplace_path == null and remote_marketplace_name == null) or (marketplace_path != null and remote_marketplace_name != null)) {
        return error.InvalidPluginReadSource;
    }
    if (marketplace_path) |path| {
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidPluginReadMarketplacePath;
    }
    return .{
        .plugin_name = plugin_name,
        .marketplace_path = marketplace_path,
        .remote_marketplace_name = remote_marketplace_name,
    };
}

fn stringFieldForPluginParams(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn optionalStringFieldForPluginParams(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    return value.string;
}

fn optionalStringForPluginParams(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidOptionalPluginString;
    return value.string;
}

const ParsedPluginListParams = struct {
    cwds: []const []const u8,
    marketplace_kinds: PluginListMarketplaceKinds,

    fn include_local(self: ParsedPluginListParams) bool {
        return self.marketplace_kinds.include_local;
    }

    fn remoteSources(self: ParsedPluginListParams, config_bytes: []const u8) remote_plugin.MarketplaceSources {
        var sources = remote_plugin.MarketplaceSources{};
        if (!self.marketplace_kinds.explicit and plugin_config.remotePluginFeatureEnabled(config_bytes)) {
            sources.global = true;
        }
        sources.workspace_directory = self.marketplace_kinds.include_workspace_directory;
        sources.shared_with_me = self.marketplace_kinds.include_shared_with_me;
        return sources;
    }

    fn deinit(self: ParsedPluginListParams, allocator: std.mem.Allocator) void {
        allocator.free(self.cwds);
    }
};

const PluginListMarketplaceKinds = struct {
    explicit: bool = false,
    include_local: bool = true,
    include_workspace_directory: bool = false,
    include_shared_with_me: bool = false,
};

const ParsedSkillsListParams = struct {
    cwds: []const []const u8,
    extra_roots_by_cwd: []skills_list.ExtraRootsForCwd,
    force_reload: bool = false,

    fn deinit(self: ParsedSkillsListParams, allocator: std.mem.Allocator) void {
        allocator.free(self.cwds);
        for (self.extra_roots_by_cwd) |entry| allocator.free(entry.roots);
        allocator.free(self.extra_roots_by_cwd);
    }
};

const ParsedHooksListParams = struct {
    cwds: []const []const u8,

    fn deinit(self: ParsedHooksListParams, allocator: std.mem.Allocator) void {
        allocator.free(self.cwds);
    }
};

const SkillsListRequestCwds = struct {
    values: []const []const u8,
    owned: bool = false,

    fn deinit(self: SkillsListRequestCwds, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
    }
};

fn handleHooksList(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parseHooksListParams(allocator, params_value) catch |err| switch (err) {
        error.InvalidHooksListParams => return renderJsonRpcError(allocator, id_value, -32602, "hooks/list params must be an object"),
        error.InvalidHooksListCwds => return renderJsonRpcError(allocator, id_value, -32602, "cwds must be an array of strings or null"),
        else => return err,
    };
    defer params.deinit(allocator);

    const codex_home = resolveCodexHome(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "hooks/list failed", err);
    };
    defer allocator.free(codex_home);

    var result = hooks_list.list(allocator, codex_home, params.cwds) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "hooks/list failed", err);
    };
    defer result.deinit(allocator);

    const rendered = try hooks_list.renderResponse(allocator, result);
    defer allocator.free(rendered);
    return renderJsonRpcResult(allocator, id_value, rendered);
}

fn parseHooksListParams(allocator: std.mem.Allocator, params_value: ?std.json.Value) !ParsedHooksListParams {
    const empty = ParsedHooksListParams{ .cwds = &.{} };
    const params = params_value orelse return empty;
    if (params == .null) return empty;
    if (params != .object) return error.InvalidHooksListParams;
    const cwds = try parseOptionalStringArray(allocator, params.object.get("cwds"), error.InvalidHooksListCwds);
    return .{ .cwds = cwds };
}

fn handleSkillsList(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parseSkillsListParams(allocator, params_value) catch |err| switch (err) {
        error.InvalidSkillsListParams => return renderJsonRpcError(allocator, id_value, -32602, "skills/list params must be an object"),
        error.InvalidSkillsListCwds => return renderJsonRpcError(allocator, id_value, -32602, "cwds must be an array of strings or null"),
        error.InvalidSkillsListForceReload => return renderJsonRpcError(allocator, id_value, -32602, "forceReload must be a boolean or null"),
        error.InvalidSkillsListExtraRoots => return renderJsonRpcError(allocator, id_value, -32602, "perCwdExtraUserRoots must be an array or null"),
        error.InvalidSkillsListExtraRootEntry => return renderJsonRpcError(allocator, id_value, -32602, "perCwdExtraUserRoots entries must include cwd and extraUserRoots"),
        error.InvalidSkillsListExtraRootPath => return renderJsonRpcError(allocator, id_value, -32602, "skills/list extraUserRoots paths must be absolute"),
        else => return err,
    };
    defer params.deinit(allocator);

    const request_cwds = resolveSkillsListRequestCwds(allocator, params.cwds) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "skills/list failed", err);
    };
    defer request_cwds.deinit(allocator);

    if (!params.force_reload) {
        if (try renderCachedSkillsListResponse(allocator, state, request_cwds.values)) |cached_result| {
            defer allocator.free(cached_result);
            return renderJsonRpcResult(allocator, id_value, cached_result);
        }
    }

    var listed = skills_list.list(allocator, request_cwds.values, params.extra_roots_by_cwd) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "skills/list failed", err);
    };
    defer listed.deinit(allocator);
    try registerSkillWatchRoots(allocator, state, listed, params.extra_roots_by_cwd);
    try updateSkillsListCache(allocator, state, listed);

    const result = try renderSkillsListResponse(allocator, listed);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn resolveSkillsListRequestCwds(allocator: std.mem.Allocator, cwds: []const []const u8) !SkillsListRequestCwds {
    if (cwds.len != 0) return .{ .values = cwds };

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    errdefer allocator.free(cwd);
    const values = try allocator.alloc([]const u8, 1);
    values[0] = cwd;
    return .{ .values = values, .owned = true };
}

fn parseSkillsListParams(allocator: std.mem.Allocator, params_value: ?std.json.Value) !ParsedSkillsListParams {
    const empty = ParsedSkillsListParams{ .cwds = &.{}, .extra_roots_by_cwd = &.{} };
    const params = params_value orelse return empty;
    if (params == .null) return empty;
    if (params != .object) return error.InvalidSkillsListParams;

    if (params.object.get("forceReload")) |force_reload| {
        if (force_reload != .null and force_reload != .bool) return error.InvalidSkillsListForceReload;
    }
    const force_reload = if (params.object.get("forceReload")) |value|
        value == .bool and value.bool
    else
        false;

    const cwds = try parseOptionalStringArray(allocator, params.object.get("cwds"), error.InvalidSkillsListCwds);
    errdefer allocator.free(cwds);
    const extra_roots = try parseSkillsListExtraRoots(allocator, params.object.get("perCwdExtraUserRoots"));
    errdefer {
        for (extra_roots) |entry| allocator.free(entry.roots);
        allocator.free(extra_roots);
    }

    return .{ .cwds = cwds, .extra_roots_by_cwd = extra_roots, .force_reload = force_reload };
}

fn parseOptionalStringArray(
    allocator: std.mem.Allocator,
    value_opt: ?std.json.Value,
    comptime invalid_error: anyerror,
) ![]const []const u8 {
    const value = value_opt orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return invalid_error;
    const items = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(items);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return invalid_error;
        items[index] = item.string;
    }
    return items;
}

fn parseSkillsListExtraRoots(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]skills_list.ExtraRootsForCwd {
    const value = value_opt orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidSkillsListExtraRoots;

    const entries = try allocator.alloc(skills_list.ExtraRootsForCwd, value.array.items.len);
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| allocator.free(entry.roots);
    }

    for (value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidSkillsListExtraRootEntry;
        const cwd_value = item.object.get("cwd") orelse return error.InvalidSkillsListExtraRootEntry;
        const roots_value = item.object.get("extraUserRoots") orelse return error.InvalidSkillsListExtraRootEntry;
        if (cwd_value != .string or roots_value != .array) return error.InvalidSkillsListExtraRootEntry;

        const roots = try allocator.alloc([]const u8, roots_value.array.items.len);
        errdefer allocator.free(roots);
        for (roots_value.array.items, 0..) |root_value, root_index| {
            if (root_value != .string) return error.InvalidSkillsListExtraRootEntry;
            if (!std.fs.path.isAbsolute(root_value.string)) return error.InvalidSkillsListExtraRootPath;
            roots[root_index] = root_value.string;
        }
        entries[index] = .{ .cwd = cwd_value.string, .roots = roots };
        initialized += 1;
    }

    return entries;
}

fn renderSkillsListResponse(allocator: std.mem.Allocator, result: skills_list.Result) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");
    for (result.entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendSkillsListEntryJson(allocator, &out, entry);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendSkillsListEntryJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: skills_list.Entry) !void {
    const cwd_json = try std.json.Stringify.valueAlloc(allocator, entry.cwd, .{});
    defer allocator.free(cwd_json);
    try out.appendSlice(allocator, "{\"cwd\":");
    try out.appendSlice(allocator, cwd_json);
    try out.appendSlice(allocator, ",\"skills\":[");
    for (entry.skills, 0..) |skill, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendSkillMetadataJson(allocator, out, skill);
    }
    try out.appendSlice(allocator, "],\"errors\":[");
    for (entry.errors, 0..) |skill_error, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendSkillErrorJson(allocator, out, skill_error);
    }
    try out.appendSlice(allocator, "]}");
}

fn renderCachedSkillsListResponse(
    allocator: std.mem.Allocator,
    state: *const AppServerState,
    cwds: []const []const u8,
) !?[]const u8 {
    if (cwds.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");
    for (cwds, 0..) |cwd, index| {
        const cached = findSkillsListCacheEntry(state, cwd) orelse return null;
        if (index > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, cached.entry_json);
    }
    try out.appendSlice(allocator, "]}");
    return try out.toOwnedSlice(allocator);
}

fn updateSkillsListCache(allocator: std.mem.Allocator, state: *AppServerState, result: skills_list.Result) !void {
    for (result.entries) |entry| {
        var entry_json = std.ArrayList(u8).empty;
        errdefer entry_json.deinit(allocator);
        try appendSkillsListEntryJson(allocator, &entry_json, entry);
        const owned_entry_json = try entry_json.toOwnedSlice(allocator);
        errdefer allocator.free(owned_entry_json);

        if (findSkillsListCacheEntryIndex(state, entry.cwd)) |index| {
            allocator.free(state.skills_list_cache.items[index].entry_json);
            state.skills_list_cache.items[index].entry_json = owned_entry_json;
            continue;
        }

        const owned_cwd = try allocator.dupe(u8, entry.cwd);
        errdefer allocator.free(owned_cwd);
        try state.skills_list_cache.append(allocator, .{
            .cwd = owned_cwd,
            .entry_json = owned_entry_json,
        });
    }
}

fn findSkillsListCacheEntry(state: *const AppServerState, cwd: []const u8) ?SkillsListCacheEntry {
    if (findSkillsListCacheEntryIndex(state, cwd)) |index| return state.skills_list_cache.items[index];
    return null;
}

fn findSkillsListCacheEntryIndex(state: *const AppServerState, cwd: []const u8) ?usize {
    for (state.skills_list_cache.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.cwd, cwd)) return index;
    }
    return null;
}

fn clearSkillsListCache(allocator: std.mem.Allocator, state: *AppServerState) void {
    for (state.skills_list_cache.items) |*entry| entry.deinit(allocator);
    state.skills_list_cache.clearRetainingCapacity();
}

fn appendSkillMetadataJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), skill: skills_list.Skill) !void {
    const name_json = try std.json.Stringify.valueAlloc(allocator, skill.name, .{});
    defer allocator.free(name_json);
    const description_json = try std.json.Stringify.valueAlloc(allocator, skill.description, .{});
    defer allocator.free(description_json);
    const path_json = try std.json.Stringify.valueAlloc(allocator, skill.path, .{});
    defer allocator.free(path_json);
    const scope_json = try std.json.Stringify.valueAlloc(allocator, skill.scope, .{});
    defer allocator.free(scope_json);

    try out.appendSlice(allocator, "{\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    if (skill.short_description) |short_description| {
        const short_description_json = try std.json.Stringify.valueAlloc(allocator, short_description, .{});
        defer allocator.free(short_description_json);
        try out.appendSlice(allocator, ",\"shortDescription\":");
        try out.appendSlice(allocator, short_description_json);
    }
    if (skill.interface) |interface| {
        try out.appendSlice(allocator, ",\"interface\":");
        try appendSkillInterfaceJson(allocator, out, interface);
    }
    if (skill.dependencies) |dependencies| {
        try out.appendSlice(allocator, ",\"dependencies\":");
        try appendSkillDependenciesJson(allocator, out, dependencies);
    }
    try out.appendSlice(allocator, ",\"path\":");
    try out.appendSlice(allocator, path_json);
    try out.appendSlice(allocator, ",\"scope\":");
    try out.appendSlice(allocator, scope_json);
    try out.appendSlice(allocator, ",\"enabled\":");
    try out.appendSlice(allocator, if (skill.enabled) "true}" else "false}");
}

fn appendSkillInterfaceJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), interface: skills_list.SkillInterface) !void {
    try out.append(allocator, '{');
    var first = true;
    try appendOptionalJsonStringField(allocator, out, &first, "displayName", interface.display_name);
    try appendOptionalJsonStringField(allocator, out, &first, "shortDescription", interface.short_description);
    try appendOptionalJsonStringField(allocator, out, &first, "iconSmall", interface.icon_small);
    try appendOptionalJsonStringField(allocator, out, &first, "iconLarge", interface.icon_large);
    try appendOptionalJsonStringField(allocator, out, &first, "brandColor", interface.brand_color);
    try appendOptionalJsonStringField(allocator, out, &first, "defaultPrompt", interface.default_prompt);
    try out.append(allocator, '}');
}

fn appendSkillDependenciesJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), dependencies: skills_list.SkillDependencies) !void {
    try out.appendSlice(allocator, "{\"tools\":[");
    for (dependencies.tools, 0..) |tool, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendSkillToolDependencyJson(allocator, out, tool);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendSkillToolDependencyJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tool: skills_list.SkillToolDependency) !void {
    const type_json = try std.json.Stringify.valueAlloc(allocator, tool.kind, .{});
    defer allocator.free(type_json);
    const value_json = try std.json.Stringify.valueAlloc(allocator, tool.value, .{});
    defer allocator.free(value_json);
    try out.appendSlice(allocator, "{\"type\":");
    try out.appendSlice(allocator, type_json);
    try out.appendSlice(allocator, ",\"value\":");
    try out.appendSlice(allocator, value_json);
    var first = false;
    try appendOptionalJsonStringField(allocator, out, &first, "description", tool.description);
    try appendOptionalJsonStringField(allocator, out, &first, "transport", tool.transport);
    try appendOptionalJsonStringField(allocator, out, &first, "command", tool.command);
    try appendOptionalJsonStringField(allocator, out, &first, "url", tool.url);
    try out.append(allocator, '}');
}

fn appendOptionalJsonStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    comptime field_name: []const u8,
    value_opt: ?[]const u8,
) !void {
    const value = value_opt orelse return;
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    if (first.*) {
        first.* = false;
    } else {
        try out.append(allocator, ',');
    }
    try out.appendSlice(allocator, "\"" ++ field_name ++ "\":");
    try out.appendSlice(allocator, value_json);
}

fn appendSkillErrorJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), skill_error: skills_list.SkillError) !void {
    const path_json = try std.json.Stringify.valueAlloc(allocator, skill_error.path, .{});
    defer allocator.free(path_json);
    const message_json = try std.json.Stringify.valueAlloc(allocator, skill_error.message, .{});
    defer allocator.free(message_json);
    try out.appendSlice(allocator, "{\"path\":");
    try out.appendSlice(allocator, path_json);
    try out.appendSlice(allocator, ",\"message\":");
    try out.appendSlice(allocator, message_json);
    try out.appendSlice(allocator, "}");
}

fn registerSkillWatchRoots(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    result: skills_list.Result,
    extra_roots_by_cwd: []const skills_list.ExtraRootsForCwd,
) !void {
    for (result.entries) |entry| {
        const codex_repo_root = try std.fs.path.join(allocator, &.{ entry.cwd, ".codex", "skills" });
        defer allocator.free(codex_repo_root);
        try appendSkillWatchRoot(allocator, state, codex_repo_root);

        const agents_repo_root = try std.fs.path.join(allocator, &.{ entry.cwd, ".agents", "skills" });
        defer allocator.free(agents_repo_root);
        try appendSkillWatchRoot(allocator, state, agents_repo_root);

        if (resolveCodexHome(allocator)) |codex_home| {
            defer allocator.free(codex_home);
            const user_root = try std.fs.path.join(allocator, &.{ codex_home, "skills" });
            defer allocator.free(user_root);
            try appendSkillWatchRoot(allocator, state, user_root);
        } else |_| {}

        for (extra_roots_by_cwd) |extra| {
            if (!std.mem.eql(u8, extra.cwd, entry.cwd)) continue;
            for (extra.roots) |root| try appendSkillWatchRoot(allocator, state, root);
        }

        for (entry.skills) |skill| {
            const root = std.fs.path.dirname(skill.path) orelse continue;
            try appendSkillWatchRoot(allocator, state, root);
        }
    }
}

fn appendSkillWatchRoot(allocator: std.mem.Allocator, state: *AppServerState, root: []const u8) !void {
    for (state.skill_watch_roots.items) |existing| {
        if (std.mem.eql(u8, existing, root)) return;
    }
    const owned = try allocator.dupe(u8, root);
    errdefer allocator.free(owned);
    try state.skill_watch_roots.append(allocator, owned);
}

fn queueSkillsChangedNotificationForPath(allocator: std.mem.Allocator, state: *AppServerState, changed_path: []const u8) !void {
    for (state.skill_watch_roots.items) |root| {
        if (pathIsSameOrDescendant(root, changed_path)) {
            try queueSkillsChangedNotification(allocator, state);
            return;
        }
    }
}

fn queueSkillsChangedNotification(allocator: std.mem.Allocator, state: *AppServerState) !void {
    clearSkillsListCache(allocator, state);
    const notification = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"method\":\"skills/changed\",\"params\":{}}");
    errdefer allocator.free(notification);
    try state.pending_notifications.append(
        allocator,
        notification,
    );
}

const ParsedSkillsConfigWriteParams = struct {
    selector: skills_list.ConfigSelector,
    enabled: bool,
};

fn handleSkillsConfigWrite(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "skills/config/write params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "skills/config/write params must be an object");

    const parsed = parseSkillsConfigWriteParams(params.object) catch |err| switch (err) {
        error.InvalidSkillsConfigSelector => return renderJsonRpcError(allocator, id_value, -32602, "skills/config/write requires exactly one of path or name"),
        error.InvalidSkillsConfigPath => return renderJsonRpcError(allocator, id_value, -32602, "path must be an absolute string or null"),
        error.InvalidSkillsConfigEnabled => return renderJsonRpcError(allocator, id_value, -32602, "enabled must be a boolean"),
    };

    const config_path = try resolveDefaultConfigWritePath(allocator);
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "skills/config/write failed to read config", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const updated = skills_list.updateSkillConfigToml(
        allocator,
        config_bytes orelse "",
        parsed.selector,
        parsed.enabled,
    ) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "skills/config/write failed to update config", err);
    };
    defer allocator.free(updated);

    config.writeConfigTomlFile(config_path, updated) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "skills/config/write failed to write config", err);
    };
    try queueSkillsChangedNotification(allocator, state);

    const result = try std.fmt.allocPrint(allocator, "{{\"effectiveEnabled\":{s}}}", .{if (parsed.enabled) "true" else "false"});
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn parseSkillsConfigWriteParams(object: std.json.ObjectMap) !ParsedSkillsConfigWriteParams {
    const enabled_value = object.get("enabled") orelse return error.InvalidSkillsConfigEnabled;
    if (enabled_value != .bool) return error.InvalidSkillsConfigEnabled;

    const path_opt = switch (optionalStringOrNull(object, "path")) {
        .invalid => return error.InvalidSkillsConfigPath,
        .value => |value| value,
        .missing => null,
    };
    const name_opt = switch (optionalStringOrNull(object, "name")) {
        .invalid => return error.InvalidSkillsConfigSelector,
        .value => |value| value,
        .missing => null,
    };

    const selector = if (path_opt) |path| blk: {
        if (name_opt != null) return error.InvalidSkillsConfigSelector;
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidSkillsConfigPath;
        break :blk skills_list.ConfigSelector{ .path = path };
    } else if (name_opt) |name| blk: {
        if (std.mem.trim(u8, name, " \t\r\n").len == 0) return error.InvalidSkillsConfigSelector;
        break :blk skills_list.ConfigSelector{ .name = name };
    } else return error.InvalidSkillsConfigSelector;

    return .{ .selector = selector, .enabled = enabled_value.bool };
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
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "fs/readFile")) return handleFsReadFile(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/writeFile")) return handleFsWriteFile(allocator, state, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/createDirectory")) return handleFsCreateDirectory(allocator, state, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/getMetadata")) return handleFsGetMetadata(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/readDirectory")) return handleFsReadDirectory(allocator, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/remove")) return handleFsRemove(allocator, state, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/copy")) return handleFsCopy(allocator, state, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/watch")) return handleFsWatch(allocator, state, id_value, params_value);
    if (std.mem.eql(u8, method, "fs/unwatch")) return handleFsUnwatch(allocator, state, id_value, params_value);
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

fn handleFsWriteFile(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
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
    try queueFsChangedNotifications(allocator, state, path);
    try queueSkillsChangedNotificationForPath(allocator, state, path);
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCreateDirectory(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
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
    try queueFsChangedNotifications(allocator, state, path);
    try queueSkillsChangedNotificationForPath(allocator, state, path);
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

fn handleFsRemove(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
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
    try queueFsChangedNotifications(allocator, state, path);
    try queueSkillsChangedNotificationForPath(allocator, state, path);
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsCopy(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
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
    try queueFsChangedNotifications(allocator, state, destination_path);
    try queueSkillsChangedNotificationForPath(allocator, state, destination_path);
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn handleFsWatch(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/watch")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const watch_id = switch (requiredStringFieldValue(object, "watchId", "fs/watch requires string watchId")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const path = switch (requiredAbsolutePathField(object, "path")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (findFsWatchIndex(state, watch_id) != null) {
        const message = try std.fmt.allocPrint(allocator, "watchId already exists: {s}", .{watch_id});
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }

    const path_json = try std.json.Stringify.valueAlloc(allocator, path, .{});
    defer allocator.free(path_json);
    const result = try std.fmt.allocPrint(allocator, "{{\"path\":{s}}}", .{path_json});
    defer allocator.free(result);
    const response = try renderJsonRpcResult(allocator, id_value, result);
    errdefer allocator.free(response);

    const watch_id_owned = try allocator.dupe(u8, watch_id);
    errdefer allocator.free(watch_id_owned);
    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);
    var snapshot = try captureFsWatchSnapshot(allocator, path);
    errdefer deinitFsWatchSnapshot(allocator, &snapshot);
    try state.fs_watches.append(allocator, .{
        .watch_id = watch_id_owned,
        .path = path_owned,
        .snapshot = snapshot,
    });
    return response;
}

fn handleFsUnwatch(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (fsObjectParams(params_value, "fs/unwatch")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const watch_id = switch (requiredStringFieldValue(object, "watchId", "fs/unwatch requires string watchId")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    if (findFsWatchIndex(state, watch_id)) |index| {
        var removed = state.fs_watches.orderedRemove(index);
        removed.deinit(allocator);
    }
    return renderJsonRpcResult(allocator, id_value, "{}");
}

fn findFsWatchIndex(state: *const AppServerState, watch_id: []const u8) ?usize {
    for (state.fs_watches.items, 0..) |watch, index| {
        if (std.mem.eql(u8, watch.watch_id, watch_id)) return index;
    }
    return null;
}

fn queueFsChangedNotifications(allocator: std.mem.Allocator, state: *AppServerState, changed_path: []const u8) !void {
    for (state.fs_watches.items) |*watch| {
        if (!fsWatchMatches(allocator, watch.path, changed_path)) continue;
        const notification = try renderFsChangedNotification(allocator, watch.watch_id, changed_path);
        errdefer allocator.free(notification);
        var next_snapshot = try captureFsWatchSnapshot(allocator, watch.path);
        errdefer deinitFsWatchSnapshot(allocator, &next_snapshot);
        try state.pending_notifications.append(allocator, notification);
        deinitFsWatchSnapshot(allocator, &watch.snapshot);
        watch.snapshot = next_snapshot;
    }
}

fn queueExternalFsWatchNotifications(allocator: std.mem.Allocator, state: *AppServerState) !void {
    if (state.fs_watches.items.len == 0) return;
    for (state.fs_watches.items) |*watch| {
        var next_snapshot = try captureFsWatchSnapshot(allocator, watch.path);
        errdefer deinitFsWatchSnapshot(allocator, &next_snapshot);

        var changed_paths = std.ArrayList([]const u8).empty;
        defer changed_paths.deinit(allocator);
        try collectFsWatchSnapshotChanges(allocator, &changed_paths, watch.snapshot.items, next_snapshot.items);

        if (changed_paths.items.len > 0) {
            const notification = try renderFsChangedNotificationForPaths(allocator, watch.watch_id, changed_paths.items);
            errdefer allocator.free(notification);
            try state.pending_notifications.append(allocator, notification);
        }

        deinitFsWatchSnapshot(allocator, &watch.snapshot);
        watch.snapshot = next_snapshot;
    }
}

fn fsWatchMatches(allocator: std.mem.Allocator, watch_path: []const u8, changed_path: []const u8) bool {
    if (std.mem.eql(u8, watch_path, changed_path)) return true;
    const metadata = statPathFollow(allocator, watch_path) catch return false;
    const stat = metadata orelse return false;
    const mode: u32 = @intCast(stat.mode);
    return std.c.S.ISDIR(mode) and pathIsSameOrDescendant(watch_path, changed_path);
}

fn renderFsChangedNotification(allocator: std.mem.Allocator, watch_id: []const u8, changed_path: []const u8) ![]const u8 {
    const changed_paths = [_][]const u8{changed_path};
    return renderFsChangedNotificationForPaths(allocator, watch_id, &changed_paths);
}

fn renderFsChangedNotificationForPaths(
    allocator: std.mem.Allocator,
    watch_id: []const u8,
    changed_paths: []const []const u8,
) ![]const u8 {
    const watch_id_json = try std.json.Stringify.valueAlloc(allocator, watch_id, .{});
    defer allocator.free(watch_id_json);

    var paths_json = std.ArrayList(u8).empty;
    defer paths_json.deinit(allocator);
    try paths_json.append(allocator, '[');
    for (changed_paths, 0..) |changed_path, index| {
        if (index > 0) try paths_json.append(allocator, ',');
        const changed_path_json = try std.json.Stringify.valueAlloc(allocator, changed_path, .{});
        defer allocator.free(changed_path_json);
        try paths_json.appendSlice(allocator, changed_path_json);
    }
    try paths_json.append(allocator, ']');

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"fs/changed\",\"params\":{{\"watchId\":{s},\"changedPaths\":{s}}}}}",
        .{ watch_id_json, paths_json.items },
    );
}

fn captureFsWatchSnapshot(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(FsWatchSnapshotEntry) {
    var snapshot = std.ArrayList(FsWatchSnapshotEntry).empty;
    errdefer deinitFsWatchSnapshot(allocator, &snapshot);
    try appendFsWatchSnapshotEntry(allocator, &snapshot, path);
    return snapshot;
}

fn appendFsWatchSnapshotEntry(
    allocator: std.mem.Allocator,
    snapshot: *std.ArrayList(FsWatchSnapshotEntry),
    path: []const u8,
) !void {
    const metadata = try statPathNoFollowForWatch(allocator, path);

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    if (metadata) |stat| {
        const mode: u32 = @intCast(stat.mode);
        try snapshot.append(allocator, .{
            .path = owned_path,
            .kind = fsWatchSnapshotKindFromMode(mode),
            .mode = mode,
            .size = @intCast(stat.size),
            .modified_at_ns = timespecToUnixNs(stat.mtime()),
        });
        if (!std.c.S.ISDIR(mode)) return;
    } else {
        try snapshot.append(allocator, .{
            .path = owned_path,
            .kind = .missing,
            .mode = 0,
            .size = 0,
            .modified_at_ns = 0,
        });
        return;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (true) {
        const entry = (iter.next(io) catch return) orelse break;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendFsWatchSnapshotEntry(allocator, snapshot, child_path);
    }
}

fn statPathNoFollowForWatch(allocator: std.mem.Allocator, path: []const u8) !?std.c.Stat {
    return statPathNoFollow(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

fn fsWatchSnapshotKindFromMode(mode: u32) FsWatchSnapshotKind {
    if (std.c.S.ISDIR(mode)) return .directory;
    if (std.c.S.ISREG(mode)) return .file;
    if (std.c.S.ISLNK(mode)) return .symlink;
    return .other;
}

fn collectFsWatchSnapshotChanges(
    allocator: std.mem.Allocator,
    changed_paths: *std.ArrayList([]const u8),
    previous: []const FsWatchSnapshotEntry,
    current: []const FsWatchSnapshotEntry,
) !void {
    for (current) |current_entry| {
        const previous_entry = findFsWatchSnapshotEntry(previous, current_entry.path) orelse {
            try changed_paths.append(allocator, current_entry.path);
            continue;
        };
        if (!fsWatchSnapshotMetadataEqual(previous_entry, current_entry)) {
            try changed_paths.append(allocator, current_entry.path);
        }
    }
    for (previous) |previous_entry| {
        if (findFsWatchSnapshotEntry(current, previous_entry.path) == null) {
            try changed_paths.append(allocator, previous_entry.path);
        }
    }
}

fn findFsWatchSnapshotEntry(entries: []const FsWatchSnapshotEntry, path: []const u8) ?FsWatchSnapshotEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn fsWatchSnapshotMetadataEqual(left: FsWatchSnapshotEntry, right: FsWatchSnapshotEntry) bool {
    return left.kind == right.kind and
        left.mode == right.mode and
        left.size == right.size and
        left.modified_at_ns == right.modified_at_ns;
}

fn deinitFsWatchSnapshot(allocator: std.mem.Allocator, snapshot: *std.ArrayList(FsWatchSnapshotEntry)) void {
    for (snapshot.items) |*entry| entry.deinit(allocator);
    snapshot.deinit(allocator);
    snapshot.* = .empty;
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

fn isCommandExecMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "command/exec") or
        std.mem.eql(u8, method, "command/exec/write") or
        std.mem.eql(u8, method, "command/exec/terminate") or
        std.mem.eql(u8, method, "command/exec/resize");
}

fn handleCommandExecMethod(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "command/exec")) {
        return handleCommandExec(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "command/exec/write")) {
        return handleCommandExecWrite(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "command/exec/terminate")) {
        return handleCommandExecTerminate(allocator, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "command/exec/resize")) {
        return handleCommandExecResize(allocator, id_value, params_value);
    }
    return try renderJsonRpcError(allocator, id_value, -32601, "unknown command exec method");
}

const COMMAND_EXEC_DEFAULT_OUTPUT_BYTES_CAP = 64 * 1024;
const COMMAND_EXEC_DEFAULT_TIMEOUT_MS: i64 = 30_000;
const COMMAND_EXEC_TIMEOUT_EXIT_CODE: i32 = 124;

const CommandExecSandbox = struct {
    mode: config.SandboxMode,
    writable_roots: []const []const u8 = &.{},
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,

    fn deinit(self: *CommandExecSandbox, allocator: std.mem.Allocator) void {
        allocator.free(self.writable_roots);
        self.* = .{ .mode = .workspace_write };
    }
};

const CommandExecPermissionProfileSummary = struct {
    root_read: bool = false,
    root_write: bool = false,
    non_root_read: bool = false,
    project_roots_write: bool = false,
    path_writable_roots: std.ArrayList([]const u8) = .empty,
    unsupported: bool = false,

    fn deinit(self: *CommandExecPermissionProfileSummary, allocator: std.mem.Allocator) void {
        self.path_writable_roots.deinit(allocator);
    }
};

fn handleCommandExec(allocator: std.mem.Allocator, state: *AppServerState, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "command/exec params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "command/exec params must be an object");
    const object = params.object;

    const command_value = object.get("command") orelse return renderJsonRpcError(allocator, id_value, -32602, "command must be an array");
    if (command_value != .array) return renderJsonRpcError(allocator, id_value, -32602, "command must be an array");
    if (command_value.array.items.len == 0) return renderJsonRpcError(allocator, id_value, -32600, "command must not be empty");

    const command = try allocator.alloc([]const u8, command_value.array.items.len);
    defer allocator.free(command);
    for (command_value.array.items, 0..) |item, index| {
        if (item != .string) return renderJsonRpcError(allocator, id_value, -32602, "command entries must be strings");
        command[index] = item.string;
    }

    const process_id = commandExecOptionalString(object, "processId") catch {
        return renderJsonRpcError(allocator, id_value, -32602, "processId must be a string or null");
    };

    const tty = commandExecOptionalBool(object, "tty", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "tty must be a boolean");
    };
    const stream_stdin = commandExecOptionalBool(object, "streamStdin", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "streamStdin must be a boolean");
    };
    const stream_stdout_stderr = commandExecOptionalBool(object, "streamStdoutStderr", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "streamStdoutStderr must be a boolean");
    };
    if (object.get("size")) |size| {
        if (size != .null and !tty) return renderJsonRpcError(allocator, id_value, -32602, "command/exec size requires tty: true");
    }
    if ((tty or stream_stdin or stream_stdout_stderr) and process_id == null) {
        return renderJsonRpcError(allocator, id_value, -32600, "command/exec tty or streaming requires a client-supplied processId");
    }
    if (tty or stream_stdin) {
        return renderJsonRpcError(allocator, id_value, -32603, "command/exec stdin streaming and tty modes are parsed but not implemented yet");
    }
    const stream_output = stream_stdout_stderr;

    const disable_output_cap = commandExecOptionalBool(object, "disableOutputCap", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "disableOutputCap must be a boolean");
    };
    const output_bytes_cap = commandExecOptionalUsize(object, "outputBytesCap", "outputBytesCap must be a non-negative integer or null") catch |err| {
        return commandExecNumberError(allocator, id_value, err, "outputBytesCap must be a non-negative integer or null");
    };
    if (disable_output_cap and output_bytes_cap != null) {
        return renderJsonRpcError(allocator, id_value, -32602, "command/exec cannot set both outputBytesCap and disableOutputCap");
    }

    const disable_timeout = commandExecOptionalBool(object, "disableTimeout", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "disableTimeout must be a boolean");
    };
    const timeout_ms = commandExecOptionalU64(object, "timeoutMs", "timeoutMs must be a non-negative integer or null") catch |err| {
        return commandExecNumberError(allocator, id_value, err, "timeoutMs must be a non-negative integer or null");
    };
    if (disable_timeout and timeout_ms != null) {
        return renderJsonRpcError(allocator, id_value, -32602, "command/exec cannot set both timeoutMs and disableTimeout");
    }
    const timeout_ms_i64: i64 = if (timeout_ms) |value|
        std.math.cast(i64, value) orelse return renderJsonRpcError(allocator, id_value, -32602, "timeoutMs must be a non-negative integer or null")
    else
        COMMAND_EXEC_DEFAULT_TIMEOUT_MS;

    const cwd = commandExecOptionalString(object, "cwd") catch |err| switch (err) {
        error.InvalidCommandExecString => return renderJsonRpcError(allocator, id_value, -32602, "cwd must be a string or null"),
    };

    const has_permission_profile = object.get("permissionProfile") != null and object.get("permissionProfile").? != .null;
    const sandbox_policy_value = object.get("sandboxPolicy");
    if (has_permission_profile and sandbox_policy_value != null and sandbox_policy_value.? != .null) {
        return renderJsonRpcError(allocator, id_value, -32600, "`permissionProfile` cannot be combined with `sandboxPolicy`");
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "command/exec failed to load config", err);
    };
    defer cfg.deinit(allocator);

    var command_sandbox = if (has_permission_profile)
        parseCommandExecPermissionProfile(allocator, object.get("permissionProfile").?, cfg.sandbox_mode) catch |err| switch (err) {
            error.InvalidCommandExecPermissionProfile => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile must be an object or null"),
            error.InvalidCommandExecPermissionProfileType => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.type must be disabled, managed, or external"),
            error.InvalidCommandExecPermissionProfileNetwork => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.network.enabled must be a boolean"),
            error.InvalidCommandExecPermissionProfileFileSystem => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.fileSystem must be an object"),
            error.InvalidCommandExecPermissionProfileFileSystemType => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.fileSystem.type must be restricted or unrestricted"),
            error.InvalidCommandExecPermissionProfileEntries => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.fileSystem.entries must be an array"),
            error.InvalidCommandExecPermissionProfileGlobScanMaxDepth => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile.fileSystem.globScanMaxDepth must be a positive integer or null"),
            error.InvalidCommandExecPermissionProfileEntry => return renderJsonRpcError(allocator, id_value, -32602, "permissionProfile file-system entries must include object path/access fields"),
            error.UnsupportedCommandExecPermissionProfile => return renderJsonRpcError(allocator, id_value, -32603, "command/exec permissionProfile shape is parsed but not implemented yet"),
            else => return err,
        }
    else
        parseCommandExecSandboxPolicy(allocator, sandbox_policy_value, cfg.sandbox_mode) catch |err| switch (err) {
            error.InvalidCommandExecSandboxPolicy => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy must be an object or null"),
            error.InvalidCommandExecSandboxPolicyType => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.type must be dangerFullAccess, readOnly, externalSandbox, or workspaceWrite"),
            error.InvalidCommandExecSandboxPolicyNetworkAccess => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.networkAccess must be a boolean"),
            error.InvalidCommandExecSandboxPolicyExternalNetworkAccess => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.networkAccess must be restricted or enabled"),
            error.InvalidCommandExecSandboxPolicyExcludeTmpdirEnvVar => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.excludeTmpdirEnvVar must be a boolean"),
            error.InvalidCommandExecSandboxPolicyExcludeSlashTmp => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.excludeSlashTmp must be a boolean"),
            error.InvalidCommandExecWritableRoots => return renderJsonRpcError(allocator, id_value, -32602, "sandboxPolicy.writableRoots must be an array of absolute strings"),
            else => return err,
        };
    defer command_sandbox.deinit(allocator);

    const sandbox_cwd = if (cwd) |path|
        try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator)
    else
        null;
    defer if (sandbox_cwd) |path| allocator.free(path);

    var sandboxed_argv: ?sandbox_mod.SandboxedArgv = null;
    defer if (sandboxed_argv) |*wrapped| wrapped.deinit(allocator);
    const effective_argv = if (sandbox_mod.shouldSandbox(command_sandbox.mode)) blk: {
        sandboxed_argv = try sandbox_mod.wrapArgvWithCwdOptions(allocator, command_sandbox.mode, command, command_sandbox.writable_roots, sandbox_cwd, command_sandbox.include_cwd_write_root, command_sandbox.network_enabled);
        break :blk sandboxed_argv.?.argv;
    } else command;

    var child_env: ?std.process.Environ.Map = null;
    defer if (child_env) |*map| map.deinit();
    if (object.get("env")) |env_value| {
        if (env_value != .null) {
            child_env = commandExecEnvironment(allocator, env_value) catch |err| switch (err) {
                error.InvalidCommandExecEnv => return renderJsonRpcError(allocator, id_value, -32602, "env must be an object or null"),
                error.InvalidCommandExecEnvKey => return renderJsonRpcError(allocator, id_value, -32602, "env keys must be non-empty strings without NUL or '='"),
                error.InvalidCommandExecEnvValue => return renderJsonRpcError(allocator, id_value, -32602, "env values must be strings or null"),
                else => return err,
            };
        }
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const run_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const effective_output_cap: ?usize = if (disable_output_cap) null else output_bytes_cap orelse COMMAND_EXEC_DEFAULT_OUTPUT_BYTES_CAP;
    const env_map = if (child_env) |*map| map else null;

    var result = runCommandExecProcess(allocator, &io_instance, effective_argv, run_cwd, env_map, if (disable_timeout) null else timeout_ms_i64, effective_output_cap) catch |err| switch (err) {
        else => return renderJsonRpcErrorForFailure(allocator, id_value, "command/exec failed", err),
    };
    defer result.deinit(allocator);

    if (stream_output) {
        try queueCommandExecOutputDeltas(
            allocator,
            state,
            process_id.?,
            result.stdout,
            result.stderr,
            result.stdout_observed_len,
            result.stderr_observed_len,
            effective_output_cap,
        );
    }

    const stdout_response = if (stream_output) "" else commandExecCappedOutput(result.stdout, effective_output_cap);
    const stderr_response = if (stream_output) "" else commandExecCappedOutput(result.stderr, effective_output_cap);
    return renderCommandExecResponse(allocator, id_value, result.exit_code, stdout_response, stderr_response);
}

const CommandExecRunResult = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    stdout_observed_len: usize,
    stderr_observed_len: usize,

    fn deinit(self: *CommandExecRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = .{ .exit_code = 0, .stdout = "", .stderr = "", .stdout_observed_len = 0, .stderr_observed_len = 0 };
    }
};

fn runCommandExecProcess(
    allocator: std.mem.Allocator,
    io_instance: *std.Io.Threaded,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*std.process.Environ.Map,
    timeout_ms: ?i64,
    output_bytes_cap: ?usize,
) !CommandExecRunResult {
    var child = try std.process.spawn(io_instance.io(), .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var child_alive = true;
    errdefer if (child_alive) child.kill(io_instance.io());

    var stdout = std.ArrayList(u8).empty;
    errdefer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    errdefer stderr.deinit(allocator);
    var stdout_observed_len: usize = 0;
    var stderr_observed_len: usize = 0;

    const started = std.Io.Timestamp.now(io_instance.io(), .awake);
    while (true) {
        if (pollCommandExecChild(&child)) |term| {
            child_alive = false;
            try drainCommandExecOutput(io_instance, allocator, &child, &stdout, &stderr, &stdout_observed_len, &stderr_observed_len, output_bytes_cap);
            return finishCommandExecRunResult(allocator, commandExecExitCode(term), &stdout, &stderr, stdout_observed_len, stderr_observed_len);
        }

        _ = try readCommandExecPipeChunk(io_instance, allocator, child.stdout, &stdout, &stdout_observed_len, output_bytes_cap, 2);
        _ = try readCommandExecPipeChunk(io_instance, allocator, child.stderr, &stderr, &stderr_observed_len, output_bytes_cap, 2);

        if (timeout_ms) |limit| {
            if (elapsedCommandExecMilliseconds(io_instance.io(), started) >= @as(u64, @intCast(limit))) {
                child.kill(io_instance.io());
                child_alive = false;
                try drainCommandExecOutput(io_instance, allocator, &child, &stdout, &stderr, &stdout_observed_len, &stderr_observed_len, output_bytes_cap);
                return finishCommandExecRunResult(allocator, COMMAND_EXEC_TIMEOUT_EXIT_CODE, &stdout, &stderr, stdout_observed_len, stderr_observed_len);
            }
        }
    }
}

fn finishCommandExecRunResult(
    allocator: std.mem.Allocator,
    exit_code: i32,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: usize,
    stderr_observed_len: usize,
) !CommandExecRunResult {
    const stdout_owned = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_owned);
    const stderr_owned = try stderr.toOwnedSlice(allocator);
    return .{
        .exit_code = exit_code,
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .stdout_observed_len = stdout_observed_len,
        .stderr_observed_len = stderr_observed_len,
    };
}

fn drainCommandExecOutput(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    stdout_observed_len: *usize,
    stderr_observed_len: *usize,
    output_bytes_cap: ?usize,
) !void {
    var empty_rounds: usize = 0;
    while (empty_rounds < 2) {
        var made_progress = false;
        made_progress = try readCommandExecPipeChunk(io_instance, allocator, child.stdout, stdout, stdout_observed_len, output_bytes_cap, 1) or made_progress;
        made_progress = try readCommandExecPipeChunk(io_instance, allocator, child.stderr, stderr, stderr_observed_len, output_bytes_cap, 1) or made_progress;
        if (made_progress) {
            empty_rounds = 0;
        } else {
            empty_rounds += 1;
        }
    }
}

fn readCommandExecPipeChunk(
    io_instance: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    maybe_file: ?std.Io.File,
    output: *std.ArrayList(u8),
    observed_len: *usize,
    output_bytes_cap: ?usize,
    timeout_ms: u64,
) !bool {
    const file = maybe_file orelse return false;
    var buffer: [4096]u8 = undefined;
    const result = io_instance.io().operateTimeout(.{ .file_read_streaming = .{
        .file = file,
        .data = &.{buffer[0..]},
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    const count = result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => return false,
        error.WouldBlock => return false,
        else => return err,
    };
    if (count == 0) return false;
    observed_len.* += count;
    const bytes = buffer[0..count];
    if (output_bytes_cap) |cap| {
        const remaining = cap -| output.items.len;
        try output.appendSlice(allocator, bytes[0..@min(bytes.len, remaining)]);
    } else {
        try output.appendSlice(allocator, bytes);
    }
    return true;
}

fn pollCommandExecChild(child: *std.process.Child) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    var status: c_int = 0;
    const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (result == 0) return null;
    if (result < 0) return null;
    child.id = null;

    const status_u: u32 = @intCast(status);
    if (std.c.W.IFEXITED(status_u)) return .{ .exited = std.c.W.EXITSTATUS(status_u) };
    if (std.c.W.IFSIGNALED(status_u)) return .{ .signal = std.c.W.TERMSIG(status_u) };
    if (std.c.W.IFSTOPPED(status_u)) return .{ .stopped = std.c.W.STOPSIG(status_u) };
    return .{ .unknown = status_u };
}

fn elapsedCommandExecMilliseconds(io: std.Io, started: std.Io.Timestamp) u64 {
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    if (elapsed.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
}

fn renderCommandExecResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
) ![]const u8 {
    const stdout_json = try std.json.Stringify.valueAlloc(allocator, stdout, .{});
    defer allocator.free(stdout_json);
    const stderr_json = try std.json.Stringify.valueAlloc(allocator, stderr, .{});
    defer allocator.free(stderr_json);
    const response = try std.fmt.allocPrint(
        allocator,
        "{{\"exitCode\":{d},\"stdout\":{s},\"stderr\":{s}}}",
        .{ exit_code, stdout_json, stderr_json },
    );
    defer allocator.free(response);
    return renderJsonRpcResult(allocator, id_value, response);
}

fn handleCommandExecWrite(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (commandExecObjectParams(params_value, "command/exec/write")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const process_id = switch (commandExecRequiredStringField(object, "processId", "processId must be a string")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const close_stdin = commandExecOptionalBool(object, "closeStdin", false) catch |err| {
        return commandExecBoolError(allocator, id_value, err, "closeStdin must be a boolean");
    };

    const delta_base64 = commandExecOptionalString(object, "deltaBase64") catch |err| switch (err) {
        error.InvalidCommandExecString => return renderJsonRpcError(allocator, id_value, -32602, "deltaBase64 must be a string or null"),
    };
    if (delta_base64 == null and !close_stdin) {
        return renderJsonRpcError(allocator, id_value, -32602, "command/exec/write requires deltaBase64 or closeStdin");
    }
    if (delta_base64) |value| {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "invalid deltaBase64: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32602, message);
        };
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        std.base64.standard.Decoder.decode(decoded, value) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "invalid deltaBase64: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return renderJsonRpcError(allocator, id_value, -32602, message);
        };
    }
    return renderNoActiveCommandExec(allocator, id_value, process_id);
}

fn handleCommandExecTerminate(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (commandExecObjectParams(params_value, "command/exec/terminate")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const process_id = switch (commandExecRequiredStringField(object, "processId", "processId must be a string")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    return renderNoActiveCommandExec(allocator, id_value, process_id);
}

fn handleCommandExecResize(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const object = switch (commandExecObjectParams(params_value, "command/exec/resize")) {
        .object => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const process_id = switch (commandExecRequiredStringField(object, "processId", "processId must be a string")) {
        .value => |value| value,
        .message => |message| return renderJsonRpcError(allocator, id_value, -32602, message),
    };
    const size_value = object.get("size") orelse return renderJsonRpcError(allocator, id_value, -32602, "size must be an object");
    if (size_value != .object) return renderJsonRpcError(allocator, id_value, -32602, "size must be an object");
    _ = commandExecRequiredPositiveU16(size_value.object, "rows") catch |err| switch (err) {
        error.InvalidCommandExecTerminalSize => return renderJsonRpcError(allocator, id_value, -32602, "command/exec size rows and cols must be greater than 0"),
    };
    _ = commandExecRequiredPositiveU16(size_value.object, "cols") catch |err| switch (err) {
        error.InvalidCommandExecTerminalSize => return renderJsonRpcError(allocator, id_value, -32602, "command/exec size rows and cols must be greater than 0"),
    };
    return renderNoActiveCommandExec(allocator, id_value, process_id);
}

const CommandExecObjectParams = union(enum) {
    object: std.json.ObjectMap,
    message: []const u8,
};

const CommandExecStringField = union(enum) {
    value: []const u8,
    message: []const u8,
};

fn commandExecObjectParams(params_value: ?std.json.Value, method: []const u8) CommandExecObjectParams {
    const params = params_value orelse return .{ .message = commandExecParamsMessage(method) };
    if (params != .object) return .{ .message = commandExecParamsMessage(method) };
    return .{ .object = params.object };
}

fn commandExecParamsMessage(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "command/exec/write")) return "command/exec/write params must be an object";
    if (std.mem.eql(u8, method, "command/exec/terminate")) return "command/exec/terminate params must be an object";
    if (std.mem.eql(u8, method, "command/exec/resize")) return "command/exec/resize params must be an object";
    return "command/exec params must be an object";
}

fn commandExecRequiredStringField(object: std.json.ObjectMap, field: []const u8, message: []const u8) CommandExecStringField {
    const value = object.get(field) orelse return .{ .message = message };
    if (value != .string) return .{ .message = message };
    return .{ .value = value.string };
}

fn commandExecRequiredPositiveU16(object: std.json.ObjectMap, field: []const u8) !u16 {
    const value = object.get(field) orelse return error.InvalidCommandExecTerminalSize;
    const integer = switch (value) {
        .integer => |raw| raw,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch return error.InvalidCommandExecTerminalSize,
        else => return error.InvalidCommandExecTerminalSize,
    };
    if (integer <= 0) return error.InvalidCommandExecTerminalSize;
    return std.math.cast(u16, integer) orelse error.InvalidCommandExecTerminalSize;
}

fn renderNoActiveCommandExec(allocator: std.mem.Allocator, id_value: std.json.Value, process_id: []const u8) ![]const u8 {
    const process_id_json = try std.json.Stringify.valueAlloc(allocator, process_id, .{});
    defer allocator.free(process_id_json);
    const message = try std.fmt.allocPrint(allocator, "no active command/exec for process id {s}", .{process_id_json});
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32600, message);
}

fn queueCommandExecOutputDeltas(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    process_id: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    stdout_observed_len: usize,
    stderr_observed_len: usize,
    output_bytes_cap: ?usize,
) !void {
    if (stdout_observed_len > 0) {
        try queueCommandExecOutputDelta(allocator, state, process_id, "stdout", stdout, stdout_observed_len, output_bytes_cap);
    }
    if (stderr_observed_len > 0) {
        try queueCommandExecOutputDelta(allocator, state, process_id, "stderr", stderr, stderr_observed_len, output_bytes_cap);
    }
}

fn queueCommandExecOutputDelta(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    process_id: []const u8,
    stream: []const u8,
    bytes: []const u8,
    observed_len: usize,
    output_bytes_cap: ?usize,
) !void {
    const capped = commandExecCappedOutput(bytes, output_bytes_cap);
    const cap_reached = commandExecOutputCapReached(observed_len, output_bytes_cap);

    const encoded_len = std.base64.standard.Encoder.calcSize(capped.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, capped);

    const process_id_json = try std.json.Stringify.valueAlloc(allocator, process_id, .{});
    defer allocator.free(process_id_json);
    const stream_json = try std.json.Stringify.valueAlloc(allocator, stream, .{});
    defer allocator.free(stream_json);
    const delta_json = try std.json.Stringify.valueAlloc(allocator, encoded, .{});
    defer allocator.free(delta_json);

    const notification = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"command/exec/outputDelta\",\"params\":{{\"processId\":{s},\"stream\":{s},\"deltaBase64\":{s},\"capReached\":{s}}}}}",
        .{ process_id_json, stream_json, delta_json, if (cap_reached) "true" else "false" },
    );
    errdefer allocator.free(notification);
    try state.pre_response_notifications.append(allocator, notification);
}

fn commandExecCappedOutput(bytes: []const u8, output_bytes_cap: ?usize) []const u8 {
    const cap = output_bytes_cap orelse return bytes;
    return bytes[0..@min(bytes.len, cap)];
}

fn commandExecOutputCapReached(observed_len: usize, output_bytes_cap: ?usize) bool {
    const cap = output_bytes_cap orelse return false;
    return observed_len >= cap;
}

fn commandExecExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        .unknown => |code| @intCast(code),
    };
}

fn commandExecOptionalBool(object: std.json.ObjectMap, field: []const u8, default: bool) !bool {
    const value = object.get(field) orelse return default;
    if (value == .null) return default;
    if (value != .bool) return error.InvalidCommandExecBool;
    return value.bool;
}

fn commandExecOptionalString(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidCommandExecString;
    return value.string;
}

fn commandExecOptionalUsize(object: std.json.ObjectMap, field: []const u8, message: []const u8) !?usize {
    if (try commandExecOptionalU64(object, field, message)) |value| {
        return std.math.cast(usize, value) orelse error.InvalidCommandExecNumber;
    }
    return null;
}

fn commandExecOptionalU64(object: std.json.ObjectMap, field: []const u8, message: []const u8) !?u64 {
    _ = message;
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    return switch (value) {
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidCommandExecNumber;
            break :blk @intCast(integer);
        },
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch return error.InvalidCommandExecNumber,
        else => error.InvalidCommandExecNumber,
    };
}

fn commandExecBoolError(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror, message: []const u8) ![]const u8 {
    return switch (err) {
        error.InvalidCommandExecBool => renderJsonRpcError(allocator, id_value, -32602, message),
        else => err,
    };
}

fn commandExecNumberError(allocator: std.mem.Allocator, id_value: std.json.Value, err: anyerror, message: []const u8) ![]const u8 {
    return switch (err) {
        error.InvalidCommandExecNumber => renderJsonRpcError(allocator, id_value, -32602, message),
        else => err,
    };
}

fn parseCommandExecPermissionProfile(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    default_mode: config.SandboxMode,
) !CommandExecSandbox {
    if (value == .null) return .{ .mode = default_mode, .writable_roots = try allocator.alloc([]const u8, 0) };
    if (value != .object) return error.InvalidCommandExecPermissionProfile;

    const type_value = value.object.get("type") orelse return error.InvalidCommandExecPermissionProfileType;
    if (type_value != .string) return error.InvalidCommandExecPermissionProfileType;

    if (std.mem.eql(u8, type_value.string, "disabled")) {
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0) };
    }
    if (std.mem.eql(u8, type_value.string, "external")) {
        const network_enabled = try parseCommandExecPermissionNetwork(value.object.get("network"));
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0), .network_enabled = network_enabled };
    }
    if (!std.mem.eql(u8, type_value.string, "managed")) {
        return error.InvalidCommandExecPermissionProfileType;
    }

    const network_enabled = try parseCommandExecPermissionNetwork(value.object.get("network"));
    const file_system_value = value.object.get("fileSystem") orelse return error.InvalidCommandExecPermissionProfileFileSystem;
    if (file_system_value != .object) return error.InvalidCommandExecPermissionProfileFileSystem;
    const file_system_type = file_system_value.object.get("type") orelse return error.InvalidCommandExecPermissionProfileFileSystemType;
    if (file_system_type != .string) return error.InvalidCommandExecPermissionProfileFileSystemType;

    if (std.mem.eql(u8, file_system_type.string, "unrestricted")) {
        try validateCommandExecPermissionProfileGlobScanMaxDepth(file_system_value.object);
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0) };
    }
    if (!std.mem.eql(u8, file_system_type.string, "restricted")) {
        return error.InvalidCommandExecPermissionProfileFileSystemType;
    }
    try validateCommandExecPermissionProfileGlobScanMaxDepth(file_system_value.object);

    const entries_value = file_system_value.object.get("entries") orelse return error.InvalidCommandExecPermissionProfileEntries;
    if (entries_value != .array) return error.InvalidCommandExecPermissionProfileEntries;

    var summary = CommandExecPermissionProfileSummary{};
    defer summary.deinit(allocator);
    for (entries_value.array.items) |entry| {
        try addCommandExecPermissionProfileEntry(allocator, &summary, entry);
    }

    if (summary.unsupported or (summary.non_root_read and !summary.root_read)) return error.UnsupportedCommandExecPermissionProfile;
    if (summary.root_write) {
        if (!summary.root_read) return error.UnsupportedCommandExecPermissionProfile;
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0) };
    }
    if (summary.project_roots_write or summary.path_writable_roots.items.len > 0) {
        if (!summary.root_read) return error.UnsupportedCommandExecPermissionProfile;
        const roots = try summary.path_writable_roots.toOwnedSlice(allocator);
        summary.path_writable_roots = .empty;
        return .{ .mode = .workspace_write, .writable_roots = roots, .include_cwd_write_root = summary.project_roots_write, .network_enabled = network_enabled };
    }
    if (summary.root_read) {
        return .{ .mode = .read_only, .writable_roots = try allocator.alloc([]const u8, 0), .network_enabled = network_enabled };
    }
    return error.UnsupportedCommandExecPermissionProfile;
}

fn parseCommandExecPermissionNetwork(value: ?std.json.Value) !bool {
    const network = value orelse return error.InvalidCommandExecPermissionProfileNetwork;
    if (network != .object) return error.InvalidCommandExecPermissionProfileNetwork;
    const enabled = network.object.get("enabled") orelse return error.InvalidCommandExecPermissionProfileNetwork;
    if (enabled != .bool) return error.InvalidCommandExecPermissionProfileNetwork;
    return enabled.bool;
}

fn validateCommandExecPermissionProfileGlobScanMaxDepth(object: std.json.ObjectMap) !void {
    const value = object.get("globScanMaxDepth") orelse return;
    if (value == .null) return;
    const depth = switch (value) {
        .integer => |integer| blk: {
            if (integer <= 0) return error.InvalidCommandExecPermissionProfileGlobScanMaxDepth;
            break :blk @as(u64, @intCast(integer));
        },
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidCommandExecPermissionProfileGlobScanMaxDepth,
        else => return error.InvalidCommandExecPermissionProfileGlobScanMaxDepth,
    };
    if (depth == 0) return error.InvalidCommandExecPermissionProfileGlobScanMaxDepth;
}

fn addCommandExecPermissionProfileEntry(
    allocator: std.mem.Allocator,
    summary: *CommandExecPermissionProfileSummary,
    value: std.json.Value,
) !void {
    if (value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const path = value.object.get("path") orelse return error.InvalidCommandExecPermissionProfileEntry;
    const access_value = value.object.get("access") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (access_value != .string) return error.InvalidCommandExecPermissionProfileEntry;

    if (std.mem.eql(u8, access_value.string, "none")) {
        summary.unsupported = true;
        return;
    }
    if (std.mem.eql(u8, access_value.string, "read")) {
        if (commandExecPermissionPathIsRoot(path) catch |err| switch (err) {
            error.InvalidCommandExecPermissionProfileEntry => return err,
        }) {
            summary.root_read = true;
        } else {
            summary.non_root_read = true;
        }
        return;
    }
    if (!std.mem.eql(u8, access_value.string, "write")) {
        return error.InvalidCommandExecPermissionProfileEntry;
    }

    if (try commandExecPermissionPathIsRoot(path)) {
        summary.root_write = true;
        return;
    }
    if (try commandExecPermissionPathIsProjectRoots(path)) {
        summary.project_roots_write = true;
        return;
    }
    if (try commandExecPermissionPathAbsolute(path)) |absolute_path| {
        try summary.path_writable_roots.append(allocator, absolute_path);
        return;
    }
    summary.unsupported = true;
}

fn commandExecPermissionPathIsRoot(value: std.json.Value) !bool {
    const special = try commandExecPermissionSpecialPathKind(value);
    return if (special) |kind| std.mem.eql(u8, kind, "root") else false;
}

fn commandExecPermissionPathIsProjectRoots(value: std.json.Value) !bool {
    if (value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const type_value = value.object.get("type") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (type_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    if (!std.mem.eql(u8, type_value.string, "special")) return false;
    const special_value = value.object.get("value") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (special_value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const kind_value = special_value.object.get("kind") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (kind_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    if (!std.mem.eql(u8, kind_value.string, "project_roots") and !std.mem.eql(u8, kind_value.string, "current_working_directory")) return false;
    if (special_value.object.get("subpath")) |subpath| {
        if (subpath != .null) return false;
    }
    return true;
}

fn commandExecPermissionSpecialPathKind(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const type_value = value.object.get("type") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (type_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    if (!std.mem.eql(u8, type_value.string, "special")) return null;
    const special_value = value.object.get("value") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (special_value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const kind_value = special_value.object.get("kind") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (kind_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    return kind_value.string;
}

fn commandExecPermissionPathAbsolute(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.InvalidCommandExecPermissionProfileEntry;
    const type_value = value.object.get("type") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (type_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    if (!std.mem.eql(u8, type_value.string, "path")) return null;
    const path_value = value.object.get("path") orelse return error.InvalidCommandExecPermissionProfileEntry;
    if (path_value != .string) return error.InvalidCommandExecPermissionProfileEntry;
    if (!std.fs.path.isAbsolute(path_value.string)) return error.InvalidCommandExecPermissionProfileEntry;
    return path_value.string;
}

fn parseCommandExecSandboxPolicy(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    default_mode: config.SandboxMode,
) !CommandExecSandbox {
    const policy = value orelse return defaultCommandExecSandbox(allocator, default_mode);
    if (policy == .null) return defaultCommandExecSandbox(allocator, default_mode);
    if (policy != .object) return error.InvalidCommandExecSandboxPolicy;

    const type_value = policy.object.get("type") orelse return error.InvalidCommandExecSandboxPolicyType;
    if (type_value != .string) return error.InvalidCommandExecSandboxPolicyType;
    if (std.mem.eql(u8, type_value.string, "dangerFullAccess")) {
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0) };
    }
    if (std.mem.eql(u8, type_value.string, "readOnly")) {
        const network_enabled = try parseCommandExecSandboxPolicyNetworkAccess(policy.object);
        return .{ .mode = .read_only, .writable_roots = try allocator.alloc([]const u8, 0), .network_enabled = network_enabled };
    }
    if (std.mem.eql(u8, type_value.string, "externalSandbox")) {
        const network_enabled = try parseCommandExecExternalSandboxPolicyNetworkAccess(policy.object);
        return .{ .mode = .danger_full_access, .writable_roots = try allocator.alloc([]const u8, 0), .network_enabled = network_enabled };
    }
    if (!std.mem.eql(u8, type_value.string, "workspaceWrite")) return error.InvalidCommandExecSandboxPolicyType;

    const writable_roots = try parseCommandExecWorkspaceWriteRoots(allocator, policy.object);
    const network_enabled = try parseCommandExecSandboxPolicyNetworkAccess(policy.object);
    return .{ .mode = .workspace_write, .writable_roots = writable_roots, .network_enabled = network_enabled };
}

fn defaultCommandExecSandbox(allocator: std.mem.Allocator, mode: config.SandboxMode) !CommandExecSandbox {
    const writable_roots = if (mode == .workspace_write)
        try buildCommandExecWorkspaceWriteRoots(allocator, &.{}, commandExecCurrentAbsoluteEnv("TMPDIR"), "/tmp")
    else
        try allocator.alloc([]const u8, 0);
    return .{ .mode = mode, .writable_roots = writable_roots };
}

fn parseCommandExecSandboxPolicyNetworkAccess(object: std.json.ObjectMap) !bool {
    const value = object.get("networkAccess") orelse return false;
    if (value == .null) return false;
    if (value != .bool) return error.InvalidCommandExecSandboxPolicyNetworkAccess;
    return value.bool;
}

fn parseCommandExecExternalSandboxPolicyNetworkAccess(object: std.json.ObjectMap) !bool {
    const value = object.get("networkAccess") orelse return false;
    if (value == .null) return false;
    if (value != .string) return error.InvalidCommandExecSandboxPolicyExternalNetworkAccess;
    if (std.mem.eql(u8, value.string, "restricted")) return false;
    if (std.mem.eql(u8, value.string, "enabled")) return true;
    return error.InvalidCommandExecSandboxPolicyExternalNetworkAccess;
}

fn parseCommandExecWorkspaceWriteRoots(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const explicit_roots = try parseCommandExecWritableRoots(allocator, object);
    defer allocator.free(explicit_roots);

    const exclude_tmpdir = try parseCommandExecSandboxPolicyBool(
        object,
        "excludeTmpdirEnvVar",
        error.InvalidCommandExecSandboxPolicyExcludeTmpdirEnvVar,
    );
    const exclude_slash_tmp = try parseCommandExecSandboxPolicyBool(
        object,
        "excludeSlashTmp",
        error.InvalidCommandExecSandboxPolicyExcludeSlashTmp,
    );
    const tmpdir_root = if (!exclude_tmpdir) commandExecCurrentAbsoluteEnv("TMPDIR") else null;
    const slash_tmp_root: ?[]const u8 = if (!exclude_slash_tmp) "/tmp" else null;

    return buildCommandExecWorkspaceWriteRoots(allocator, explicit_roots, tmpdir_root, slash_tmp_root);
}

fn buildCommandExecWorkspaceWriteRoots(
    allocator: std.mem.Allocator,
    explicit_roots: []const []const u8,
    tmpdir_root: ?[]const u8,
    slash_tmp_root: ?[]const u8,
) ![]const []const u8 {
    var root_count = explicit_roots.len;
    if (tmpdir_root != null) root_count += 1;
    if (slash_tmp_root != null) root_count += 1;

    const roots = try allocator.alloc([]const u8, root_count);
    @memcpy(roots[0..explicit_roots.len], explicit_roots);
    var index = explicit_roots.len;
    if (tmpdir_root) |root| {
        roots[index] = root;
        index += 1;
    }
    if (slash_tmp_root) |root| {
        roots[index] = root;
    }
    return roots;
}

fn parseCommandExecSandboxPolicyBool(
    object: std.json.ObjectMap,
    field: []const u8,
    comptime invalid_error: anyerror,
) !bool {
    const value = object.get(field) orelse return false;
    if (value == .null) return false;
    if (value != .bool) return invalid_error;
    return value.bool;
}

fn commandExecCurrentAbsoluteEnv(comptime name: []const u8) ?[]const u8 {
    const c_name: [*:0]const u8 = name ++ "\x00";
    const raw = std.c.getenv(c_name) orelse return null;
    const value = std.mem.span(raw);
    if (value.len == 0 or !std.fs.path.isAbsolute(value)) return null;
    return value;
}

fn parseCommandExecWritableRoots(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const value = object.get("writableRoots") orelse return allocator.alloc([]const u8, 0);
    if (value == .null) return allocator.alloc([]const u8, 0);
    if (value != .array) return error.InvalidCommandExecWritableRoots;
    const roots = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(roots);
    for (value.array.items, 0..) |item, index| {
        if (item != .string or !std.fs.path.isAbsolute(item.string)) return error.InvalidCommandExecWritableRoots;
        roots[index] = item.string;
    }
    return roots;
}

fn commandExecEnvironment(allocator: std.mem.Allocator, value: std.json.Value) !std.process.Environ.Map {
    if (value == .null) return error.InvalidCommandExecEnv;
    if (value != .object) return error.InvalidCommandExecEnv;

    var child_env = std.process.Environ.Map.init(allocator);
    errdefer child_env.deinit();

    try putCurrentEnvIfPresent(&child_env, "PATH");
    try putCurrentEnvIfPresent(&child_env, "HOME");
    try putCurrentEnvIfPresent(&child_env, "USER");
    try putCurrentEnvIfPresent(&child_env, "TMPDIR");
    try putCurrentEnvIfPresent(&child_env, "SHELL");
    try putCurrentEnvIfPresent(&child_env, "CODEX_HOME");

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.process.Environ.Map.validateKeyForPut(key)) return error.InvalidCommandExecEnvKey;
        switch (entry.value_ptr.*) {
            .null => _ = child_env.swapRemove(key),
            .string => |string| try child_env.put(key, string),
            else => return error.InvalidCommandExecEnvValue,
        }
    }

    return child_env;
}

fn putCurrentEnvIfPresent(child_env: *std.process.Environ.Map, comptime name: []const u8) !void {
    const c_name: [*:0]const u8 = name ++ "\x00";
    const value = std.c.getenv(c_name) orelse return;
    try child_env.put(name, std.mem.span(value));
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

fn timespecToUnixNs(value: std.c.timespec) i64 {
    return @as(i64, @intCast(value.sec)) * std.time.ns_per_s + @as(i64, @intCast(value.nsec));
}

fn isConfigMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "config/read") or
        std.mem.eql(u8, method, "config/value/write") or
        std.mem.eql(u8, method, "config/batchWrite") or
        std.mem.eql(u8, method, "configRequirements/read");
}

fn handleConfigMethod(
    allocator: std.mem.Allocator,
    state: *AppServerState,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "config/read")) {
        return handleConfigRead(allocator, state, id_value, params_value);
    }
    if (std.mem.eql(u8, method, "config/value/write")) {
        const response = try handleConfigValueWrite(allocator, id_value, params_value);
        clearSkillsListCache(allocator, state);
        return response;
    }
    if (std.mem.eql(u8, method, "config/batchWrite")) {
        const response = try handleConfigBatchWrite(allocator, id_value, params_value);
        clearSkillsListCache(allocator, state);
        return response;
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
    var requirements = loadConfigRequirementsReadRequirements(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "configRequirements/read failed to load config requirements", err);
    };
    defer requirements.deinit(allocator);
    const result = try renderConfigRequirementsReadResponse(allocator, requirements);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

const ConfigRequirementsReadRequirements = struct {
    allowed_approval_policies: ?config.StringList = null,
    allowed_approvals_reviewers: ?config.StringList = null,
    allowed_sandbox_modes: ?config.StringList = null,
    allowed_web_search_modes: ?config.StringList = null,
    feature_requirements: ?FeatureRequirementList = null,
    hooks: ?config_requirements_hooks.ManagedHooksRequirements = null,
    enforce_residency: ?[]const u8 = null,
    network: ?NetworkRequirements = null,

    fn deinit(self: *ConfigRequirementsReadRequirements, allocator: std.mem.Allocator) void {
        if (self.allowed_approval_policies) |*value| value.deinit(allocator);
        if (self.allowed_approvals_reviewers) |*value| value.deinit(allocator);
        if (self.allowed_sandbox_modes) |*value| value.deinit(allocator);
        if (self.allowed_web_search_modes) |*value| value.deinit(allocator);
        if (self.feature_requirements) |*value| value.deinit(allocator);
        if (self.hooks) |*value| value.deinit(allocator);
        if (self.enforce_residency) |value| allocator.free(value);
        if (self.network) |*value| value.deinit(allocator);
        self.* = .{};
    }

    fn isEmpty(self: ConfigRequirementsReadRequirements) bool {
        return self.allowed_approval_policies == null and
            self.allowed_approvals_reviewers == null and
            self.allowed_sandbox_modes == null and
            self.allowed_web_search_modes == null and
            self.feature_requirements == null and
            self.hooks == null and
            self.enforce_residency == null and
            self.network == null;
    }

    fn mergeUnset(self: *ConfigRequirementsReadRequirements, other: *ConfigRequirementsReadRequirements) void {
        if (self.allowed_approval_policies == null) {
            self.allowed_approval_policies = other.allowed_approval_policies;
            other.allowed_approval_policies = null;
        }
        if (self.allowed_approvals_reviewers == null) {
            self.allowed_approvals_reviewers = other.allowed_approvals_reviewers;
            other.allowed_approvals_reviewers = null;
        }
        if (self.allowed_sandbox_modes == null) {
            self.allowed_sandbox_modes = other.allowed_sandbox_modes;
            other.allowed_sandbox_modes = null;
        }
        if (self.allowed_web_search_modes == null) {
            self.allowed_web_search_modes = other.allowed_web_search_modes;
            other.allowed_web_search_modes = null;
        }
        if (self.feature_requirements == null) {
            self.feature_requirements = other.feature_requirements;
            other.feature_requirements = null;
        }
        if (self.hooks == null) {
            self.hooks = other.hooks;
            other.hooks = null;
        }
        if (self.enforce_residency == null) {
            self.enforce_residency = other.enforce_residency;
            other.enforce_residency = null;
        }
        if (self.network == null) {
            self.network = other.network;
            other.network = null;
        }
    }
};

const FeatureRequirement = struct {
    name: []const u8,
    enabled: bool,
};

const FeatureRequirementList = struct {
    items: []FeatureRequirement,

    fn deinit(self: *FeatureRequirementList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item.name);
        allocator.free(self.items);
        self.items = &.{};
    }
};

const NetworkPermissionEntry = struct {
    key: []const u8,
    value: []const u8,
};

const NetworkPermissionEntryList = struct {
    items: []NetworkPermissionEntry,

    fn deinit(self: *NetworkPermissionEntryList, allocator: std.mem.Allocator) void {
        for (self.items) |item| deinitNetworkPermissionEntry(allocator, item);
        allocator.free(self.items);
        self.items = &.{};
    }
};

const NetworkRequirements = struct {
    enabled: ?bool = null,
    http_port: ?u16 = null,
    socks_port: ?u16 = null,
    allow_upstream_proxy: ?bool = null,
    dangerously_allow_non_loopback_proxy: ?bool = null,
    dangerously_allow_all_unix_sockets: ?bool = null,
    domains: ?NetworkPermissionEntryList = null,
    managed_allowed_domains_only: ?bool = null,
    unix_sockets: ?NetworkPermissionEntryList = null,
    allow_local_binding: ?bool = null,

    fn deinit(self: *NetworkRequirements, allocator: std.mem.Allocator) void {
        if (self.domains) |*value| value.deinit(allocator);
        if (self.unix_sockets) |*value| value.deinit(allocator);
        self.* = .{};
    }

    fn isEmpty(self: NetworkRequirements) bool {
        return self.enabled == null and
            self.http_port == null and
            self.socks_port == null and
            self.allow_upstream_proxy == null and
            self.dangerously_allow_non_loopback_proxy == null and
            self.dangerously_allow_all_unix_sockets == null and
            self.domains == null and
            self.managed_allowed_domains_only == null and
            self.unix_sockets == null and
            self.allow_local_binding == null;
    }
};

const ApprovalsReviewer = enum {
    user,
    auto_review,

    fn parse(value: []const u8) !ApprovalsReviewer {
        if (std.mem.eql(u8, value, "user")) return .user;
        if (std.mem.eql(u8, value, "auto_review") or std.mem.eql(u8, value, "guardian_subagent")) return .auto_review;
        return error.InvalidApprovalsReviewer;
    }

    fn label(self: ApprovalsReviewer) []const u8 {
        return switch (self) {
            .user => "user",
            .auto_review => "guardian_subagent",
        };
    }
};

fn loadConfigRequirementsReadRequirements(allocator: std.mem.Allocator) !ConfigRequirementsReadRequirements {
    var requirements = try loadSystemConfigRequirements(allocator);
    errdefer requirements.deinit(allocator);

    var legacy_requirements = try loadLegacyManagedConfigRequirements(allocator);
    defer legacy_requirements.deinit(allocator);
    requirements.mergeUnset(&legacy_requirements);

    return requirements;
}

fn loadSystemConfigRequirements(allocator: std.mem.Allocator) !ConfigRequirementsReadRequirements {
    const path = try systemRequirementsPath(allocator);
    defer allocator.free(path);

    const bytes = try config.readConfigTomlFile(allocator, path);
    defer if (bytes) |payload| allocator.free(payload);
    const payload = bytes orelse return .{};

    var requirements = ConfigRequirementsReadRequirements{};
    errdefer requirements.deinit(allocator);

    requirements.allowed_approval_policies = try parseAllowedRequirementList(allocator, payload, "allowed_approval_policies", .approval_policy);
    requirements.allowed_approvals_reviewers = try parseAllowedRequirementList(allocator, payload, "allowed_approvals_reviewers", .approvals_reviewer);
    requirements.allowed_sandbox_modes = try parseAllowedRequirementList(allocator, payload, "allowed_sandbox_modes", .sandbox_mode);
    requirements.allowed_web_search_modes = try parseAllowedRequirementList(allocator, payload, "allowed_web_search_modes", .web_search_mode);
    requirements.feature_requirements = try parseFeatureRequirements(allocator, payload);
    requirements.hooks = try config_requirements_hooks.parse(allocator, payload);
    requirements.enforce_residency = try parseResidencyRequirement(allocator, payload);
    requirements.network = try parseNetworkRequirements(allocator, payload);

    return requirements;
}

fn loadLegacyManagedConfigRequirements(allocator: std.mem.Allocator) !ConfigRequirementsReadRequirements {
    const path = try managedConfigPath(allocator);
    defer allocator.free(path);

    const bytes = try config.readConfigTomlFile(allocator, path);
    defer if (bytes) |payload| allocator.free(payload);
    const payload = bytes orelse return .{};

    var requirements = ConfigRequirementsReadRequirements{};
    errdefer requirements.deinit(allocator);

    if (try config.topLevelStringValue(allocator, payload, "approval_policy")) |value| {
        defer allocator.free(value);
        const approval_policy = try config.ApprovalPolicy.parse(value);
        requirements.allowed_approval_policies = try stringListFromLabels(allocator, &.{approval_policy.label()});
    }
    if (try config.topLevelStringValue(allocator, payload, "approvals_reviewer")) |value| {
        defer allocator.free(value);
        const approvals_reviewer = try ApprovalsReviewer.parse(value);
        requirements.allowed_approvals_reviewers = switch (approvals_reviewer) {
            .user => try stringListFromLabels(allocator, &.{"user"}),
            .auto_review => try stringListFromLabels(allocator, &.{ "guardian_subagent", "user" }),
        };
    }
    if (try config.topLevelStringValue(allocator, payload, "sandbox_mode")) |value| {
        defer allocator.free(value);
        const sandbox_mode = try config.SandboxMode.parse(value);
        requirements.allowed_sandbox_modes = switch (sandbox_mode) {
            .read_only => try stringListFromLabels(allocator, &.{"read-only"}),
            .workspace_write => try stringListFromLabels(allocator, &.{ "read-only", "workspace-write" }),
            .danger_full_access => try stringListFromLabels(allocator, &.{ "read-only", "danger-full-access" }),
        };
    }
    return requirements;
}

const RequirementListKind = enum {
    approval_policy,
    approvals_reviewer,
    sandbox_mode,
    web_search_mode,
};

fn parseAllowedRequirementList(
    allocator: std.mem.Allocator,
    payload: []const u8,
    key: []const u8,
    kind: RequirementListKind,
) !?config.StringList {
    var raw = try config.topLevelStringArrayValue(allocator, payload, key) orelse return null;
    defer raw.deinit(allocator);

    var disabled_present = false;
    for (raw.items) |value| {
        if (std.mem.eql(u8, try requirementLabel(kind, value), config.WebSearchMode.disabled.label())) {
            disabled_present = true;
        }
    }

    const extra_disabled: usize = if (kind == .web_search_mode and !disabled_present) 1 else 0;
    var labels = try allocator.alloc([]const u8, raw.items.len + extra_disabled);
    var copied: usize = 0;
    errdefer {
        for (labels[0..copied]) |label| allocator.free(label);
        allocator.free(labels);
    }

    for (raw.items, 0..) |value, index| {
        labels[index] = try allocator.dupe(u8, try requirementLabel(kind, value));
        copied += 1;
    }
    if (extra_disabled == 1) {
        labels[raw.items.len] = try allocator.dupe(u8, config.WebSearchMode.disabled.label());
        copied += 1;
    }
    return .{ .items = labels };
}

fn requirementLabel(kind: RequirementListKind, value: []const u8) ![]const u8 {
    return switch (kind) {
        .approval_policy => (try config.ApprovalPolicy.parse(value)).label(),
        .approvals_reviewer => (try ApprovalsReviewer.parse(value)).label(),
        .sandbox_mode => (try config.SandboxMode.parse(value)).label(),
        .web_search_mode => (try config.WebSearchMode.parse(value)).label(),
    };
}

fn parseFeatureRequirements(allocator: std.mem.Allocator, payload: []const u8) !?FeatureRequirementList {
    var entries = std.ArrayList(FeatureRequirement).empty;
    errdefer {
        deinitFeatureRequirementItems(allocator, entries.items);
        entries.deinit(allocator);
    }

    try appendFeatureRequirementsSection(allocator, payload, "features", &entries);
    try appendFeatureRequirementsSection(allocator, payload, "feature_requirements", &entries);

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }

    const items = try entries.toOwnedSlice(allocator);
    std.mem.sort(FeatureRequirement, items, {}, featureRequirementLessThan);
    return .{ .items = items };
}

fn appendFeatureRequirementsSection(
    allocator: std.mem.Allocator,
    payload: []const u8,
    section_name: []const u8,
    entries: *std.ArrayList(FeatureRequirement),
) !void {
    var in_section = false;
    var iter = std.mem.splitScalar(u8, payload, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = isExactTomlSection(line, section_name);
            continue;
        }
        if (!in_section) continue;
        if (try parseFeatureRequirementLine(allocator, line)) |entry| {
            errdefer allocator.free(entry.name);
            try entries.append(allocator, entry);
        }
    }
}

fn parseFeatureRequirementLine(allocator: std.mem.Allocator, line: []const u8) !?FeatureRequirement {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const raw_key = std.mem.trim(u8, line[0..eq], " \t");
    const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (raw_key.len == 0) return error.InvalidFeatureRequirement;

    const enabled = if (std.mem.eql(u8, raw_value, "true"))
        true
    else if (std.mem.eql(u8, raw_value, "false"))
        false
    else
        return error.InvalidFeatureRequirement;

    const name = try parseTomlKeyName(allocator, raw_key);
    return .{ .name = name, .enabled = enabled };
}

fn parseTomlKeyName(allocator: std.mem.Allocator, raw_key: []const u8) ![]const u8 {
    if (raw_key.len > 0 and raw_key[0] == '"') {
        return try config.parseTomlString(allocator, raw_key) orelse error.InvalidFeatureRequirement;
    }
    return allocator.dupe(u8, raw_key);
}

fn isExactTomlSection(line: []const u8, section_name: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    return std.mem.eql(u8, name, section_name);
}

fn featureRequirementLessThan(_: void, lhs: FeatureRequirement, rhs: FeatureRequirement) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn deinitFeatureRequirementItems(allocator: std.mem.Allocator, items: []FeatureRequirement) void {
    for (items) |item| allocator.free(item.name);
}

fn parseResidencyRequirement(allocator: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    const value = try config.topLevelStringValue(allocator, payload, "enforce_residency") orelse return null;
    errdefer allocator.free(value);
    if (!std.mem.eql(u8, value, "us")) return error.InvalidResidencyRequirement;
    return value;
}

fn parseNetworkRequirements(allocator: std.mem.Allocator, payload: []const u8) !?NetworkRequirements {
    const section = "experimental_network";
    var network = NetworkRequirements{
        .enabled = config.sectionBoolValue(payload, section, "enabled"),
        .http_port = try sectionU16Value(payload, section, "http_port"),
        .socks_port = try sectionU16Value(payload, section, "socks_port"),
        .allow_upstream_proxy = config.sectionBoolValue(payload, section, "allow_upstream_proxy"),
        .dangerously_allow_non_loopback_proxy = config.sectionBoolValue(payload, section, "dangerously_allow_non_loopback_proxy"),
        .dangerously_allow_all_unix_sockets = config.sectionBoolValue(payload, section, "dangerously_allow_all_unix_sockets"),
        .managed_allowed_domains_only = config.sectionBoolValue(payload, section, "managed_allowed_domains_only"),
        .allow_local_binding = config.sectionBoolValue(payload, section, "allow_local_binding"),
    };
    errdefer network.deinit(allocator);

    network.domains = try parseNetworkDomainRequirements(allocator, payload);
    network.unix_sockets = try parseNetworkUnixSocketRequirements(allocator, payload);

    if (network.isEmpty()) return null;
    return network;
}

fn parseNetworkDomainRequirements(allocator: std.mem.Allocator, payload: []const u8) !?NetworkPermissionEntryList {
    var canonical = try parseNetworkPermissionSection(allocator, payload, "experimental_network.domains", .domain);
    errdefer if (canonical) |*value| value.deinit(allocator);

    var allowed_domains = try config.sectionStringArrayValue(allocator, payload, "experimental_network", "allowed_domains");
    defer if (allowed_domains) |*value| value.deinit(allocator);
    var denied_domains = try config.sectionStringArrayValue(allocator, payload, "experimental_network", "denied_domains");
    defer if (denied_domains) |*value| value.deinit(allocator);

    if (canonical != null and (allowed_domains != null or denied_domains != null)) {
        return error.InvalidNetworkRequirement;
    }
    if (canonical) |value| return value;

    var entries = std.ArrayList(NetworkPermissionEntry).empty;
    errdefer {
        deinitNetworkPermissionEntries(allocator, entries.items);
        entries.deinit(allocator);
    }
    if (allowed_domains) |list| {
        for (list.items) |domain| try putNetworkPermissionEntryFromParts(allocator, &entries, domain, "allow");
    }
    if (denied_domains) |list| {
        for (list.items) |domain| try putNetworkPermissionEntryFromParts(allocator, &entries, domain, "deny");
    }
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }
    const items = try entries.toOwnedSlice(allocator);
    std.mem.sort(NetworkPermissionEntry, items, {}, networkPermissionEntryLessThan);
    return .{ .items = items };
}

fn parseNetworkUnixSocketRequirements(allocator: std.mem.Allocator, payload: []const u8) !?NetworkPermissionEntryList {
    var canonical = try parseNetworkPermissionSection(allocator, payload, "experimental_network.unix_sockets", .unix_socket);
    errdefer if (canonical) |*value| value.deinit(allocator);

    var allow_unix_sockets = try config.sectionStringArrayValue(allocator, payload, "experimental_network", "allow_unix_sockets");
    defer if (allow_unix_sockets) |*value| value.deinit(allocator);

    if (canonical != null and allow_unix_sockets != null) {
        return error.InvalidNetworkRequirement;
    }
    if (canonical) |value| return value;

    var entries = std.ArrayList(NetworkPermissionEntry).empty;
    errdefer {
        deinitNetworkPermissionEntries(allocator, entries.items);
        entries.deinit(allocator);
    }
    if (allow_unix_sockets) |list| {
        for (list.items) |path| try putNetworkPermissionEntryFromParts(allocator, &entries, path, "allow");
    }
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }
    const items = try entries.toOwnedSlice(allocator);
    std.mem.sort(NetworkPermissionEntry, items, {}, networkPermissionEntryLessThan);
    return .{ .items = items };
}

const NetworkPermissionKind = enum {
    domain,
    unix_socket,
};

fn parseNetworkPermissionSection(
    allocator: std.mem.Allocator,
    payload: []const u8,
    section_name: []const u8,
    kind: NetworkPermissionKind,
) !?NetworkPermissionEntryList {
    var entries = std.ArrayList(NetworkPermissionEntry).empty;
    errdefer {
        deinitNetworkPermissionEntries(allocator, entries.items);
        entries.deinit(allocator);
    }

    var in_section = false;
    var iter = std.mem.splitScalar(u8, payload, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = isExactTomlSection(line, section_name);
            continue;
        }
        if (!in_section) continue;
        if (try parseNetworkPermissionLine(allocator, line, kind)) |entry| {
            var owned_entry = entry;
            errdefer deinitNetworkPermissionEntry(allocator, owned_entry);
            try putOwnedNetworkPermissionEntry(allocator, &entries, &owned_entry);
        }
    }

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }
    const items = try entries.toOwnedSlice(allocator);
    std.mem.sort(NetworkPermissionEntry, items, {}, networkPermissionEntryLessThan);
    return .{ .items = items };
}

fn parseNetworkPermissionLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    kind: NetworkPermissionKind,
) !?NetworkPermissionEntry {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const raw_key = std.mem.trim(u8, line[0..eq], " \t");
    const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (raw_key.len == 0) return error.InvalidNetworkRequirement;

    const value = try config.parseTomlString(allocator, raw_value) orelse return error.InvalidNetworkRequirement;
    errdefer allocator.free(value);
    try validateNetworkPermission(value, kind);

    const key = parseTomlKeyName(allocator, raw_key) catch |err| switch (err) {
        error.InvalidFeatureRequirement, error.InvalidTomlString => return error.InvalidNetworkRequirement,
        else => return err,
    };
    errdefer allocator.free(key);
    return .{ .key = key, .value = value };
}

fn validateNetworkPermission(value: []const u8, kind: NetworkPermissionKind) !void {
    switch (kind) {
        .domain => {
            if (std.mem.eql(u8, value, "allow") or std.mem.eql(u8, value, "deny")) return;
        },
        .unix_socket => {
            if (std.mem.eql(u8, value, "allow") or std.mem.eql(u8, value, "none")) return;
        },
    }
    return error.InvalidNetworkRequirement;
}

fn putNetworkPermissionEntryFromParts(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(NetworkPermissionEntry),
    key: []const u8,
    value: []const u8,
) !void {
    var entry = NetworkPermissionEntry{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    };
    errdefer deinitNetworkPermissionEntry(allocator, entry);
    try putOwnedNetworkPermissionEntry(allocator, entries, &entry);
}

fn putOwnedNetworkPermissionEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(NetworkPermissionEntry),
    entry: *NetworkPermissionEntry,
) !void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, existing.key, entry.key)) {
            deinitNetworkPermissionEntry(allocator, existing.*);
            existing.* = entry.*;
            entry.* = .{ .key = &.{}, .value = &.{} };
            return;
        }
    }
    try entries.append(allocator, entry.*);
    entry.* = .{ .key = &.{}, .value = &.{} };
}

fn deinitNetworkPermissionEntry(allocator: std.mem.Allocator, entry: NetworkPermissionEntry) void {
    if (entry.key.len > 0) allocator.free(entry.key);
    if (entry.value.len > 0) allocator.free(entry.value);
}

fn deinitNetworkPermissionEntries(allocator: std.mem.Allocator, entries: []NetworkPermissionEntry) void {
    for (entries) |entry| deinitNetworkPermissionEntry(allocator, entry);
}

fn networkPermissionEntryLessThan(_: void, lhs: NetworkPermissionEntry, rhs: NetworkPermissionEntry) bool {
    return std.mem.lessThan(u8, lhs.key, rhs.key);
}

fn sectionU16Value(bytes: []const u8, section_name: []const u8, key: []const u8) !?u16 {
    var in_section = false;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = isExactTomlSection(line, section_name);
            continue;
        }
        if (!in_section) continue;
        if (tomlValueForKey(line, key)) |value| {
            return std.fmt.parseUnsigned(u16, value, 10) catch error.InvalidNetworkRequirement;
        }
    }
    return null;
}

fn tomlValueForKey(line: []const u8, key: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    return std.mem.trim(u8, line[eq + 1 ..], " \t");
}

fn stringListFromLabels(allocator: std.mem.Allocator, labels: []const []const u8) !config.StringList {
    const items = try allocator.alloc([]const u8, labels.len);
    var copied: usize = 0;
    errdefer {
        for (items[0..copied]) |item| allocator.free(item);
        allocator.free(items);
    }
    for (labels, 0..) |label, index| {
        items[index] = try allocator.dupe(u8, label);
        copied += 1;
    }
    return .{ .items = items };
}

fn managedConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, MANAGED_CONFIG_PATH_ENV_VAR)) |path| {
        if (path.len > 0) return path;
        allocator.free(path);
    }
    if (builtin.os.tag == .windows) {
        const codex_home = try resolveCodexHome(allocator);
        defer allocator.free(codex_home);
        return std.fs.path.join(allocator, &.{ codex_home, "managed_config.toml" });
    }
    return allocator.dupe(u8, UNIX_MANAGED_CONFIG_SYSTEM_PATH);
}

fn systemRequirementsPath(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, SYSTEM_REQUIREMENTS_PATH_ENV_VAR)) |path| {
        if (path.len > 0) return path;
        allocator.free(path);
    }
    if (builtin.os.tag == .windows) {
        const codex_home = try resolveCodexHome(allocator);
        defer allocator.free(codex_home);
        return std.fs.path.join(allocator, &.{ codex_home, "requirements.toml" });
    }
    return allocator.dupe(u8, UNIX_SYSTEM_REQUIREMENTS_PATH);
}

fn systemConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, SYSTEM_CONFIG_PATH_ENV_VAR)) |path| {
        if (path.len > 0) return path;
        allocator.free(path);
    }
    if (builtin.os.tag == .windows) {
        const codex_home = try resolveCodexHome(allocator);
        defer allocator.free(codex_home);
        return std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    }
    return allocator.dupe(u8, UNIX_SYSTEM_CONFIG_PATH);
}

fn renderConfigRequirementsReadResponse(allocator: std.mem.Allocator, requirements: ConfigRequirementsReadRequirements) ![]const u8 {
    if (requirements.isEmpty()) return allocator.dupe(u8, "{\"requirements\":null}");

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"requirements\":{");
    var first = true;
    if (requirements.allowed_approval_policies) |approval_policies| {
        try appendJsonFieldName(allocator, &result, &first, "allowedApprovalPolicies");
        try appendJsonStringArray(allocator, &result, approval_policies.items);
    }
    if (requirements.allowed_approvals_reviewers) |approvals_reviewers| {
        try appendJsonFieldName(allocator, &result, &first, "allowedApprovalsReviewers");
        try appendJsonStringArray(allocator, &result, approvals_reviewers.items);
    }
    if (requirements.allowed_sandbox_modes) |sandbox_modes| {
        try appendJsonFieldName(allocator, &result, &first, "allowedSandboxModes");
        try appendJsonStringArray(allocator, &result, sandbox_modes.items);
    }
    if (requirements.allowed_web_search_modes) |web_search_modes| {
        try appendJsonFieldName(allocator, &result, &first, "allowedWebSearchModes");
        try appendJsonStringArray(allocator, &result, web_search_modes.items);
    }
    if (requirements.feature_requirements) |feature_requirements| {
        try appendJsonFieldName(allocator, &result, &first, "featureRequirements");
        try appendFeatureRequirementsObject(allocator, &result, feature_requirements);
    }
    if (requirements.hooks) |hooks| {
        try appendJsonFieldName(allocator, &result, &first, "hooks");
        try appendManagedHooksRequirementsObject(allocator, &result, hooks);
    }
    if (requirements.enforce_residency) |enforce_residency| {
        try appendJsonFieldName(allocator, &result, &first, "enforceResidency");
        try appendJsonString(allocator, &result, enforce_residency);
    }
    if (requirements.network) |network| {
        try appendJsonFieldName(allocator, &result, &first, "network");
        try appendNetworkRequirementsObject(allocator, &result, network);
    }
    try result.appendSlice(allocator, "}}");
    return result.toOwnedSlice(allocator);
}

fn appendFeatureRequirementsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    feature_requirements: FeatureRequirementList,
) !void {
    try result.appendSlice(allocator, "{");
    for (feature_requirements.items, 0..) |entry, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try appendJsonString(allocator, result, entry.name);
        try result.appendSlice(allocator, ":");
        try result.appendSlice(allocator, if (entry.enabled) "true" else "false");
    }
    try result.appendSlice(allocator, "}");
}

fn appendManagedHooksRequirementsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    hooks: config_requirements_hooks.ManagedHooksRequirements,
) !void {
    var first = true;
    try result.appendSlice(allocator, "{");
    if (hooks.managed_dir) |value| try appendJsonStringField(allocator, result, &first, "managedDir", value);
    if (hooks.windows_managed_dir) |value| try appendJsonStringField(allocator, result, &first, "windowsManagedDir", value);
    for (config_requirements_hooks.EVENT_ORDER) |event| {
        try appendJsonFieldName(allocator, result, &first, event.configLabel());
        try appendHookMatcherGroupsArray(allocator, result, hooks.events[event.index()]);
    }
    try result.appendSlice(allocator, "}");
}

fn appendHookMatcherGroupsArray(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    groups: config_requirements_hooks.MatcherGroupList,
) !void {
    try result.appendSlice(allocator, "[");
    for (groups.items, 0..) |group, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try appendHookMatcherGroupObject(allocator, result, group);
    }
    try result.appendSlice(allocator, "]");
}

fn appendHookMatcherGroupObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    group: config_requirements_hooks.MatcherGroup,
) !void {
    var first = true;
    try result.appendSlice(allocator, "{");
    if (group.matcher) |matcher| try appendJsonStringField(allocator, result, &first, "matcher", matcher);
    try appendJsonFieldName(allocator, result, &first, "hooks");
    try result.appendSlice(allocator, "[");
    for (group.hooks, 0..) |hook, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try appendHookHandlerObject(allocator, result, hook);
    }
    try result.appendSlice(allocator, "]}");
}

fn appendHookHandlerObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    hook: config_requirements_hooks.HookHandler,
) !void {
    var first = true;
    try result.appendSlice(allocator, "{");
    try appendJsonStringField(allocator, result, &first, "type", hook.kind.label());
    if (hook.kind == .command) {
        if (hook.command) |command| try appendJsonStringField(allocator, result, &first, "command", command);
        if (hook.timeout_sec) |timeout_sec| try appendJsonU64Field(allocator, result, &first, "timeoutSec", timeout_sec);
        try appendJsonBoolField(allocator, result, &first, "async", hook.async_handler);
        if (hook.status_message) |status_message| try appendJsonStringField(allocator, result, &first, "statusMessage", status_message);
    }
    try result.appendSlice(allocator, "}");
}

fn appendNetworkRequirementsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    network: NetworkRequirements,
) !void {
    var first = true;
    try result.appendSlice(allocator, "{");
    if (network.enabled) |value| try appendJsonBoolField(allocator, result, &first, "enabled", value);
    if (network.http_port) |value| try appendJsonU16Field(allocator, result, &first, "httpPort", value);
    if (network.socks_port) |value| try appendJsonU16Field(allocator, result, &first, "socksPort", value);
    if (network.allow_upstream_proxy) |value| try appendJsonBoolField(allocator, result, &first, "allowUpstreamProxy", value);
    if (network.dangerously_allow_non_loopback_proxy) |value| try appendJsonBoolField(allocator, result, &first, "dangerouslyAllowNonLoopbackProxy", value);
    if (network.dangerously_allow_all_unix_sockets) |value| try appendJsonBoolField(allocator, result, &first, "dangerouslyAllowAllUnixSockets", value);
    if (network.domains) |domains| {
        try appendJsonFieldName(allocator, result, &first, "domains");
        try appendNetworkPermissionMap(allocator, result, domains);
    }
    if (network.managed_allowed_domains_only) |value| try appendJsonBoolField(allocator, result, &first, "managedAllowedDomainsOnly", value);
    if (network.domains) |domains| {
        if (hasNetworkPermissionEntries(domains, "allow")) {
            try appendJsonFieldName(allocator, result, &first, "allowedDomains");
            try appendNetworkPermissionKeysArray(allocator, result, domains, "allow");
        }
        if (hasNetworkPermissionEntries(domains, "deny")) {
            try appendJsonFieldName(allocator, result, &first, "deniedDomains");
            try appendNetworkPermissionKeysArray(allocator, result, domains, "deny");
        }
    }
    if (network.unix_sockets) |unix_sockets| {
        try appendJsonFieldName(allocator, result, &first, "unixSockets");
        try appendNetworkPermissionMap(allocator, result, unix_sockets);
        if (hasNetworkPermissionEntries(unix_sockets, "allow")) {
            try appendJsonFieldName(allocator, result, &first, "allowUnixSockets");
            try appendNetworkPermissionKeysArray(allocator, result, unix_sockets, "allow");
        }
    }
    if (network.allow_local_binding) |value| try appendJsonBoolField(allocator, result, &first, "allowLocalBinding", value);
    try result.appendSlice(allocator, "}");
}

fn appendNetworkPermissionMap(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    entries: NetworkPermissionEntryList,
) !void {
    try result.appendSlice(allocator, "{");
    for (entries.items, 0..) |entry, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try appendJsonString(allocator, result, entry.key);
        try result.appendSlice(allocator, ":");
        try appendJsonString(allocator, result, entry.value);
    }
    try result.appendSlice(allocator, "}");
}

fn hasNetworkPermissionEntries(entries: NetworkPermissionEntryList, permission: []const u8) bool {
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.value, permission)) return true;
    }
    return false;
}

fn appendNetworkPermissionKeysArray(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    entries: NetworkPermissionEntryList,
    permission: []const u8,
) !void {
    var first = true;
    try result.appendSlice(allocator, "[");
    for (entries.items) |entry| {
        if (!std.mem.eql(u8, entry.value, permission)) continue;
        if (first) {
            first = false;
        } else {
            try result.appendSlice(allocator, ",");
        }
        try appendJsonString(allocator, result, entry.key);
    }
    try result.appendSlice(allocator, "]");
}

fn appendJsonU16Field(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: u16,
) !void {
    try appendJsonFieldName(allocator, result, first, name);
    const value_json = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(value_json);
    try result.appendSlice(allocator, value_json);
}

fn appendJsonU64Field(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: u64,
) !void {
    try appendJsonFieldName(allocator, result, first, name);
    const value_json = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(value_json);
    try result.appendSlice(allocator, value_json);
}

const ConfigRawEdit = struct {
    key_path: []const u8,
    value: std.json.Value,
    merge_strategy: ConfigMergeStrategy,
};

const ConfigMergeStrategy = enum {
    replace,
    upsert,
};

fn handleConfigValueWrite(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "config/value/write params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "config/value/write params must be an object");

    const edit = parseConfigWriteEdit(params.object) catch |err| switch (err) {
        error.InvalidConfigKeyPathParam => return renderJsonRpcError(allocator, id_value, -32602, "keyPath must be a non-empty string"),
        error.MissingConfigWriteValue => return renderJsonRpcError(allocator, id_value, -32602, "value is required"),
        error.InvalidConfigMergeStrategy => return renderJsonRpcError(allocator, id_value, -32602, "mergeStrategy must be replace or upsert"),
    };

    return handleConfigWriteEdits(allocator, id_value, params.object, &.{edit}, "config/value/write");
}

fn handleConfigBatchWrite(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = params_value orelse return renderJsonRpcError(allocator, id_value, -32602, "config/batchWrite params must be an object");
    if (params != .object) return renderJsonRpcError(allocator, id_value, -32602, "config/batchWrite params must be an object");

    const edits_value = params.object.get("edits") orelse return renderJsonRpcError(allocator, id_value, -32602, "edits must be an array");
    if (edits_value != .array) return renderJsonRpcError(allocator, id_value, -32602, "edits must be an array");

    if (params.object.get("reloadUserConfig")) |reload_user_config| {
        if (reload_user_config != .null and reload_user_config != .bool) {
            return renderJsonRpcError(allocator, id_value, -32602, "reloadUserConfig must be a boolean or null");
        }
    }

    const edits = try allocator.alloc(ConfigRawEdit, edits_value.array.items.len);
    defer allocator.free(edits);

    for (edits_value.array.items, 0..) |edit_value, index| {
        if (edit_value != .object) return renderJsonRpcError(allocator, id_value, -32602, "edits entries must be objects");
        edits[index] = parseConfigWriteEdit(edit_value.object) catch |err| switch (err) {
            error.InvalidConfigKeyPathParam => return renderJsonRpcError(allocator, id_value, -32602, "edits entries must include a non-empty keyPath string"),
            error.MissingConfigWriteValue => return renderJsonRpcError(allocator, id_value, -32602, "edits entries must include value"),
            error.InvalidConfigMergeStrategy => return renderJsonRpcError(allocator, id_value, -32602, "edits entries must use mergeStrategy replace or upsert"),
        };
    }

    return handleConfigWriteEdits(allocator, id_value, params.object, edits, "config/batchWrite");
}

fn parseConfigWriteEdit(object: std.json.ObjectMap) !ConfigRawEdit {
    const key_path_value = object.get("keyPath") orelse return error.InvalidConfigKeyPathParam;
    if (key_path_value != .string or key_path_value.string.len == 0) return error.InvalidConfigKeyPathParam;

    const value = object.get("value") orelse return error.MissingConfigWriteValue;

    const merge_strategy_value = object.get("mergeStrategy") orelse return error.InvalidConfigMergeStrategy;
    if (merge_strategy_value != .string) return error.InvalidConfigMergeStrategy;
    if (!std.mem.eql(u8, merge_strategy_value.string, "replace") and !std.mem.eql(u8, merge_strategy_value.string, "upsert")) {
        return error.InvalidConfigMergeStrategy;
    }

    return .{
        .key_path = key_path_value.string,
        .value = value,
        .merge_strategy = if (std.mem.eql(u8, merge_strategy_value.string, "replace")) .replace else .upsert,
    };
}

fn handleConfigWriteEdits(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    params: std.json.ObjectMap,
    edits: []const ConfigRawEdit,
    method_name: []const u8,
) ![]const u8 {
    const expected_version = switch (optionalStringOrNull(params, "expectedVersion")) {
        .value => |string| string,
        .missing => null,
        .invalid => return renderJsonRpcError(allocator, id_value, -32602, "expectedVersion must be a string or null"),
    };

    const config_path = resolveConfigWritePath(allocator, params.get("filePath")) catch |err| switch (err) {
        error.InvalidConfigWritePath => return renderJsonRpcError(allocator, id_value, -32602, "filePath must be a non-empty string or null"),
        else => return err,
    };
    defer allocator.free(config_path);

    const current_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "{s} failed to read config", .{method_name});
        defer allocator.free(message);
        return renderJsonRpcErrorForFailure(allocator, id_value, message, err);
    };
    defer if (current_bytes) |bytes| allocator.free(bytes);

    if (expected_version) |expected| {
        const current_version = try configVersionAlloc(allocator, current_bytes orelse "");
        defer allocator.free(current_version);
        if (!std.mem.eql(u8, current_version, expected)) {
            return renderJsonRpcError(allocator, id_value, -32602, "config version conflict");
        }
    }

    var updated: []const u8 = try allocator.dupe(u8, current_bytes orelse "");
    defer allocator.free(updated);

    for (edits) |edit| {
        const next = applyConfigWriteEdit(allocator, updated, edit) catch |err| switch (err) {
            error.UnsupportedConfigWriteValue => return renderJsonRpcError(allocator, id_value, -32602, "value must be a TOML-compatible value"),
            error.InvalidConfigKeyPath => return renderJsonRpcError(allocator, id_value, -32602, "keyPath must be a supported TOML key path"),
            else => return err,
        };
        allocator.free(updated);
        updated = next;
    }

    config.writeConfigTomlFile(config_path, updated) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "{s} failed to write config", .{method_name});
        defer allocator.free(message);
        return renderJsonRpcErrorForFailure(allocator, id_value, message, err);
    };

    const version = try configVersionAlloc(allocator, updated);
    defer allocator.free(version);
    const result = try renderConfigWriteResponse(allocator, config_path, version);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn applyConfigWriteEdit(allocator: std.mem.Allocator, bytes: []const u8, edit: ConfigRawEdit) ![]const u8 {
    if (edit.value == .null) {
        return config.removeTomlValueForKeyPath(allocator, bytes, edit.key_path);
    }

    if (edit.value == .object and try shouldApplyConfigTableObjectWrite(bytes, edit.key_path, edit.value.object)) {
        return applyConfigTableObjectWrite(allocator, bytes, edit);
    }

    const raw_value = renderTomlValue(allocator, edit.value) catch |err| switch (err) {
        error.UnsupportedConfigWriteValue => return error.UnsupportedConfigWriteValue,
        else => return err,
    };
    defer allocator.free(raw_value);

    return config.updateTomlRawValueForKeyPath(allocator, bytes, edit.key_path, raw_value);
}

const ConfigObjectLeafWrite = struct {
    key_path: []const u8,
    raw_value: []const u8,

    fn deinit(self: ConfigObjectLeafWrite, allocator: std.mem.Allocator) void {
        allocator.free(self.key_path);
        allocator.free(self.raw_value);
    }
};

fn applyConfigTableObjectWrite(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    edit: ConfigRawEdit,
) ![]const u8 {
    var writes = std.ArrayList(ConfigObjectLeafWrite).empty;
    defer {
        for (writes.items) |item| item.deinit(allocator);
        writes.deinit(allocator);
    }
    try collectConfigObjectLeafWrites(allocator, &writes, edit.key_path, edit.value.object);

    var updated = if (edit.merge_strategy == .replace)
        try config.removeTomlTableForKeyPath(allocator, bytes, edit.key_path)
    else
        try allocator.dupe(u8, bytes);
    errdefer allocator.free(updated);

    for (writes.items) |write| {
        const next = try config.updateTomlRawValueForKeyPath(allocator, updated, write.key_path, write.raw_value);
        allocator.free(updated);
        updated = next;
    }
    return updated;
}

fn shouldApplyConfigTableObjectWrite(
    bytes: []const u8,
    key_path: []const u8,
    object: std.json.ObjectMap,
) !bool {
    if (std.mem.eql(u8, key_path, "hooks.state")) return false;
    if (!configObjectKeysAreBare(object)) return false;
    return std.mem.startsWith(u8, key_path, "mcp_servers.") or
        std.mem.startsWith(u8, key_path, "model_providers.") or
        try config.tomlHasSectionForKeyPath(bytes, key_path);
}

fn configObjectKeysAreBare(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isBareTomlKeySegment(entry.key_ptr.*)) return false;
        if (entry.value_ptr.* == .object and !configObjectKeysAreBare(entry.value_ptr.*.object)) return false;
    }
    return true;
}

fn isBareTomlKeySegment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

fn collectConfigObjectLeafWrites(
    allocator: std.mem.Allocator,
    writes: *std.ArrayList(ConfigObjectLeafWrite),
    prefix: []const u8,
    object: std.json.ObjectMap,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const child_key_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        errdefer allocator.free(child_key_path);

        if (entry.value_ptr.* == .object and configObjectHasEntries(entry.value_ptr.*.object)) {
            try collectConfigObjectLeafWrites(allocator, writes, child_key_path, entry.value_ptr.*.object);
            allocator.free(child_key_path);
            continue;
        }

        const raw_value = renderTomlValue(allocator, entry.value_ptr.*) catch |err| switch (err) {
            error.UnsupportedConfigWriteValue => return error.UnsupportedConfigWriteValue,
            else => return err,
        };
        errdefer allocator.free(raw_value);
        try writes.append(allocator, .{ .key_path = child_key_path, .raw_value = raw_value });
    }
}

fn configObjectHasEntries(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    return iterator.next() != null;
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
    var cwd: ?[]const u8 = null;
    if (params) |object| {
        if (object.get("includeLayers")) |value| {
            if (value != .bool) return renderJsonRpcError(allocator, id_value, -32602, "includeLayers must be a boolean");
            include_layers = value.bool;
        }
        if (object.get("cwd")) |value| {
            if (value != .null and value != .string) return renderJsonRpcError(allocator, id_value, -32602, "cwd must be a string or null");
            if (value == .string) {
                if (!std.fs.path.isAbsolute(value.string)) {
                    return renderJsonRpcError(allocator, id_value, -32602, "cwd must be an absolute path or null");
                }
                cwd = value.string;
            }
        }
    }

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to load config", err);
    };
    defer cfg.deinit(allocator);
    var feature_overrides = features_cmd.loadFeatureOverridesForProfile(allocator, cfg.codex_home, cfg.active_profile) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to load feature config", err);
    };
    defer feature_overrides.deinit(allocator);

    const config_path = try config.configTomlPath(allocator, cfg.codex_home);
    defer allocator.free(config_path);
    const config_bytes = config.readConfigTomlFile(allocator, config_path) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to read user config", err);
    };
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var user_layer = try loadConfigReadUserLayer(allocator, config_path, config_bytes orelse "", cfg.active_profile);
    defer user_layer.deinit(allocator);

    var managed_layer = loadConfigReadManagedLayer(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to read managed config", err);
    };
    defer if (managed_layer) |*layer| layer.deinit(allocator);

    var system_layer = loadConfigReadSystemLayer(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to read system config", err);
    };
    defer system_layer.deinit(allocator);

    var project_layers = loadConfigReadProjectLayers(allocator, cwd, cfg.codex_home, config_bytes) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "config/read failed to read project config", err);
    };
    defer project_layers.deinit(allocator);

    const result = try renderConfigReadResponse(allocator, cfg, feature_overrides, state.runtime_feature_enablement, include_layers, managed_layer, project_layers, user_layer, system_layer);
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn optionalConfigReadParams(params_value: ?std.json.Value) OptionalObjectParams {
    const params = params_value orelse return .empty;
    if (params == .null) return .empty;
    if (params != .object) return .{ .message = "config/read params must be an object" };
    return .{ .object = params.object };
}

const OptionalStringField = union(enum) {
    value: ?[]const u8,
    missing,
    invalid,
};

fn optionalStringOrNull(object: std.json.ObjectMap, field: []const u8) OptionalStringField {
    const value = object.get(field) orelse return .missing;
    if (value == .null) return .{ .value = null };
    if (value != .string) return .invalid;
    return .{ .value = value.string };
}

fn resolveConfigWritePath(allocator: std.mem.Allocator, file_path_value: ?std.json.Value) ![]const u8 {
    if (file_path_value) |value| {
        if (value == .null) return resolveDefaultConfigWritePath(allocator);
        if (value != .string or value.string.len == 0) return error.InvalidConfigWritePath;
        if (!std.fs.path.isAbsolute(value.string)) return error.InvalidConfigWritePath;
        return allocator.dupe(u8, value.string);
    }
    return resolveDefaultConfigWritePath(allocator);
}

fn resolveDefaultConfigWritePath(allocator: std.mem.Allocator) ![]const u8 {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    return config.configTomlPath(allocator, codex_home);
}

fn renderTomlValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]const u8 {
    return switch (value) {
        .string => |string| renderTomlString(allocator, string),
        .bool => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
        .integer => |integer| std.fmt.allocPrint(allocator, "{}", .{integer}),
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |number| allocator.dupe(u8, number),
        .array => |array| renderTomlArray(allocator, array.items),
        .object => |object| renderTomlInlineTable(allocator, object),
        else => error.UnsupportedConfigWriteValue,
    };
}

fn renderTomlArray(allocator: std.mem.Allocator, values: []std.json.Value) anyerror![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    errdefer rendered.deinit(allocator);
    try rendered.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try rendered.appendSlice(allocator, ", ");
        const item = try renderTomlValue(allocator, value);
        defer allocator.free(item);
        try rendered.appendSlice(allocator, item);
    }
    try rendered.append(allocator, ']');
    return rendered.toOwnedSlice(allocator);
}

fn renderTomlInlineTable(allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    errdefer rendered.deinit(allocator);
    try rendered.append(allocator, '{');

    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| {
        if (index > 0) try rendered.appendSlice(allocator, ", ");
        const key = try renderTomlString(allocator, entry.key_ptr.*);
        defer allocator.free(key);
        try rendered.appendSlice(allocator, key);
        try rendered.appendSlice(allocator, " = ");
        const value = try renderTomlValue(allocator, entry.value_ptr.*);
        defer allocator.free(value);
        try rendered.appendSlice(allocator, value);
        index += 1;
    }

    try rendered.append(allocator, '}');
    return rendered.toOwnedSlice(allocator);
}

fn renderTomlString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    errdefer rendered.deinit(allocator);
    try rendered.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try rendered.appendSlice(allocator, "\\\""),
            '\\' => try rendered.appendSlice(allocator, "\\\\"),
            '\n' => try rendered.appendSlice(allocator, "\\n"),
            '\r' => try rendered.appendSlice(allocator, "\\r"),
            '\t' => try rendered.appendSlice(allocator, "\\t"),
            else => try rendered.append(allocator, byte),
        }
    }
    try rendered.append(allocator, '"');
    return rendered.toOwnedSlice(allocator);
}

fn configVersionAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const prefix = "sha256:";
    var out = try allocator.alloc(u8, prefix.len + digest.len * 2);
    @memcpy(out[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[prefix.len + index * 2] = hex[byte >> 4];
        out[prefix.len + index * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

fn renderConfigWriteResponse(allocator: std.mem.Allocator, file_path: []const u8, version: []const u8) ![]const u8 {
    const path_json = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(path_json);
    const version_json = try std.json.Stringify.valueAlloc(allocator, version, .{});
    defer allocator.free(version_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"version\":{s},\"filePath\":{s},\"overriddenMetadata\":null}}",
        .{ version_json, path_json },
    );
}

fn renderConfigReadResponse(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    config_feature_overrides: features_cmd.FeatureOverrides,
    runtime_feature_enablement: features_cmd.FeatureOverrides,
    include_layers: bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"config\":{");
    var first = true;
    const system_model = if (system_layer) |layer| layer.model else null;
    const model = if (managed_layer) |layer| layer.model orelse project_layers.model() orelse configReadUserOrSystemString(cfg.model, user_layer, "model", system_model) else project_layers.model() orelse configReadUserOrSystemString(cfg.model, user_layer, "model", system_model);
    try appendJsonStringField(allocator, &result, &first, "model", model);
    try appendJsonMaybeStringField(allocator, &result, &first, "profile", cfg.active_profile);
    const system_approval_policy = if (system_layer) |layer| layer.approval_policy else null;
    const approval_policy = if (managed_layer) |layer| layer.approval_policy orelse project_layers.approvalPolicy() orelse configReadUserOrSystemApprovalPolicy(cfg.approval_policy, user_layer, system_approval_policy) else project_layers.approvalPolicy() orelse configReadUserOrSystemApprovalPolicy(cfg.approval_policy, user_layer, system_approval_policy);
    try appendJsonStringField(allocator, &result, &first, "approval_policy", approval_policy.label());
    const system_sandbox_mode = if (system_layer) |layer| layer.sandbox_mode else null;
    const sandbox_mode = if (managed_layer) |layer| layer.sandbox_mode orelse project_layers.sandboxMode() orelse configReadUserOrSystemSandboxMode(cfg.sandbox_mode, user_layer, system_sandbox_mode) else project_layers.sandboxMode() orelse configReadUserOrSystemSandboxMode(cfg.sandbox_mode, user_layer, system_sandbox_mode);
    try appendJsonStringField(allocator, &result, &first, "sandbox_mode", sandbox_mode.label());
    try appendConfigReadSandboxWorkspaceWriteField(allocator, &result, &first, effectiveConfigReadSandboxWorkspaceWrite(managed_layer, project_layers, user_layer, system_layer));
    const system_web_search_mode = if (system_layer) |layer| layer.web_search_mode else null;
    const managed_web_search_mode = if (managed_layer) |layer| layer.web_search_mode else null;
    const web_search_mode = managed_web_search_mode orelse project_layers.webSearchMode() orelse configReadUserOrSystemWebSearchMode(cfg.web_search_mode, user_layer, system_web_search_mode);
    try appendJsonMaybeStringField(allocator, &result, &first, "web_search", if (web_search_mode) |mode| mode.label() else null);
    try appendConfigReadToolsField(allocator, &result, &first, effectiveConfigReadTools(managed_layer, project_layers, user_layer, system_layer));
    var apps = try effectiveConfigReadApps(allocator, managed_layer, project_layers, user_layer, system_layer);
    defer if (apps) |*value| value.deinit(allocator);
    try appendConfigReadAppsField(allocator, &result, &first, apps);
    const system_model_reasoning_effort = if (system_layer) |layer| layer.model_reasoning_effort else null;
    const managed_model_reasoning_effort = if (managed_layer) |layer| layer.model_reasoning_effort else null;
    const model_reasoning_effort = managed_model_reasoning_effort orelse project_layers.modelReasoningEffort() orelse configReadUserOrSystemReasoningEffort(cfg.model_reasoning_effort, user_layer, system_model_reasoning_effort);
    try appendJsonMaybeStringField(allocator, &result, &first, "model_reasoning_effort", if (model_reasoning_effort) |effort| effort.label() else null);
    const system_service_tier = if (system_layer) |layer| layer.service_tier else null;
    const managed_service_tier = if (managed_layer) |layer| layer.service_tier else null;
    const service_tier = managed_service_tier orelse project_layers.serviceTier() orelse configReadUserOrSystemMaybeString(cfg.service_tier, user_layer, "service_tier", system_service_tier);
    try appendJsonMaybeStringField(allocator, &result, &first, "service_tier", service_tier);
    try appendJsonMaybeStringField(allocator, &result, &first, "oss_provider", cfg.oss_provider);
    try appendJsonStringField(allocator, &result, &first, "openai_base_url", cfg.openai_base_url);
    try appendJsonStringField(allocator, &result, &first, "chatgpt_base_url", cfg.chatgpt_base_url);
    try appendConfigReadFeaturesField(allocator, &result, &first, config_feature_overrides, runtime_feature_enablement);
    try result.appendSlice(allocator, "},\"origins\":");
    try appendConfigReadOrigins(allocator, &result, managed_layer, project_layers, user_layer, system_layer);
    try result.appendSlice(allocator, ",\"layers\":");
    try appendConfigReadLayers(allocator, &result, cfg, include_layers, managed_layer, project_layers, user_layer, system_layer);
    try result.appendSlice(allocator, "}");

    return result.toOwnedSlice(allocator);
}

const ConfigReadManagedLayer = struct {
    file_path: []const u8,
    version: []const u8,
    origin_keys: []const []const u8,
    model: ?[]const u8 = null,
    approval_policy: ?config.ApprovalPolicy = null,
    sandbox_mode: ?config.SandboxMode = null,
    web_search_mode: ?config.WebSearchMode = null,
    model_reasoning_effort: ?config.ReasoningEffort = null,
    service_tier: ?[]const u8 = null,
    tools: ConfigReadTools = .{},
    apps: ConfigReadApps = ConfigReadApps.empty(),
    sandbox_workspace_write: ConfigReadSandboxWorkspaceWrite = .{},

    fn deinit(self: *ConfigReadManagedLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.version);
        if (self.model) |value| allocator.free(value);
        if (self.service_tier) |value| allocator.free(value);
        for (self.origin_keys) |key| allocator.free(key);
        if (self.origin_keys.len > 0) allocator.free(self.origin_keys);
        self.tools.deinit(allocator);
        self.apps.deinit(allocator);
        self.sandbox_workspace_write.deinit(allocator);
    }

    fn hasOriginKey(self: ConfigReadManagedLayer, key: []const u8) bool {
        for (self.origin_keys) |origin_key| {
            if (std.mem.eql(u8, origin_key, key)) return true;
        }
        return false;
    }

    fn hasSandboxWorkspaceWriteRoot(self: ConfigReadManagedLayer) bool {
        return self.sandbox_workspace_write.writable_roots != null;
    }

    fn hasToolsAllowedDomains(self: ConfigReadManagedLayer) bool {
        return configReadToolsHasAllowedDomains(self.tools);
    }
};

const ConfigReadProjectLayer = struct {
    dot_codex_folder: []const u8,
    version: []const u8,
    origin_keys: []const []const u8,
    model: ?[]const u8,
    approval_policy: ?config.ApprovalPolicy,
    sandbox_mode: ?config.SandboxMode,
    web_search_mode: ?config.WebSearchMode,
    model_reasoning_effort: ?config.ReasoningEffort,
    service_tier: ?[]const u8,
    tools: ConfigReadTools,
    apps: ConfigReadApps,
    sandbox_workspace_write: ConfigReadSandboxWorkspaceWrite = .{},

    fn deinit(self: *ConfigReadProjectLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.dot_codex_folder);
        allocator.free(self.version);
        if (self.model) |value| allocator.free(value);
        if (self.service_tier) |value| allocator.free(value);
        for (self.origin_keys) |key| allocator.free(key);
        if (self.origin_keys.len > 0) allocator.free(self.origin_keys);
        self.tools.deinit(allocator);
        self.apps.deinit(allocator);
        self.sandbox_workspace_write.deinit(allocator);
    }
};

const ConfigReadSystemLayer = struct {
    file_path: []const u8,
    version: []const u8,
    origin_keys: []const []const u8,
    model: ?[]const u8,
    approval_policy: ?config.ApprovalPolicy,
    sandbox_mode: ?config.SandboxMode,
    web_search_mode: ?config.WebSearchMode,
    model_reasoning_effort: ?config.ReasoningEffort,
    service_tier: ?[]const u8,
    tools: ConfigReadTools,
    apps: ConfigReadApps,
    sandbox_workspace_write: ConfigReadSandboxWorkspaceWrite = .{},

    fn deinit(self: *ConfigReadSystemLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.version);
        if (self.model) |value| allocator.free(value);
        if (self.service_tier) |value| allocator.free(value);
        for (self.origin_keys) |key| allocator.free(key);
        if (self.origin_keys.len > 0) allocator.free(self.origin_keys);
        self.tools.deinit(allocator);
        self.apps.deinit(allocator);
        self.sandbox_workspace_write.deinit(allocator);
    }
};

fn configReadUserOrSystemString(
    user_value: []const u8,
    user_layer: ?ConfigReadUserLayer,
    key: []const u8,
    system_value: ?[]const u8,
) []const u8 {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, key) else false) return user_value;
    return system_value orelse user_value;
}

fn configReadUserOrSystemMaybeString(
    user_value: ?[]const u8,
    user_layer: ?ConfigReadUserLayer,
    key: []const u8,
    system_value: ?[]const u8,
) ?[]const u8 {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, key) else false) return user_value;
    return system_value orelse user_value;
}

fn configReadUserOrSystemApprovalPolicy(
    user_value: config.ApprovalPolicy,
    user_layer: ?ConfigReadUserLayer,
    system_value: ?config.ApprovalPolicy,
) config.ApprovalPolicy {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, "approval_policy") else false) return user_value;
    return system_value orelse user_value;
}

fn configReadUserOrSystemSandboxMode(
    user_value: config.SandboxMode,
    user_layer: ?ConfigReadUserLayer,
    system_value: ?config.SandboxMode,
) config.SandboxMode {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, "sandbox_mode") else false) return user_value;
    return system_value orelse user_value;
}

fn configReadUserOrSystemWebSearchMode(
    user_value: ?config.WebSearchMode,
    user_layer: ?ConfigReadUserLayer,
    system_value: ?config.WebSearchMode,
) ?config.WebSearchMode {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, "web_search") else false) return user_value;
    return system_value orelse user_value;
}

fn configReadUserOrSystemReasoningEffort(
    user_value: ?config.ReasoningEffort,
    user_layer: ?ConfigReadUserLayer,
    system_value: ?config.ReasoningEffort,
) ?config.ReasoningEffort {
    if (if (user_layer) |layer| configReadUserLayerHasOriginKey(layer, "model_reasoning_effort") else false) return user_value;
    return system_value orelse user_value;
}

const ConfigReadProjectLayers = struct {
    items: []ConfigReadProjectLayer,

    fn empty() ConfigReadProjectLayers {
        return .{ .items = &.{} };
    }

    fn deinit(self: *ConfigReadProjectLayers, allocator: std.mem.Allocator) void {
        for (self.items) |*layer| layer.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }

    fn model(self: ConfigReadProjectLayers) ?[]const u8 {
        for (self.items) |layer| {
            if (layer.model) |value| return value;
        }
        return null;
    }

    fn approvalPolicy(self: ConfigReadProjectLayers) ?config.ApprovalPolicy {
        for (self.items) |layer| {
            if (layer.approval_policy) |policy| return policy;
        }
        return null;
    }

    fn sandboxMode(self: ConfigReadProjectLayers) ?config.SandboxMode {
        for (self.items) |layer| {
            if (layer.sandbox_mode) |mode| return mode;
        }
        return null;
    }

    fn webSearchMode(self: ConfigReadProjectLayers) ?config.WebSearchMode {
        for (self.items) |layer| {
            if (layer.web_search_mode) |mode| return mode;
        }
        return null;
    }

    fn modelReasoningEffort(self: ConfigReadProjectLayers) ?config.ReasoningEffort {
        for (self.items) |layer| {
            if (layer.model_reasoning_effort) |effort| return effort;
        }
        return null;
    }

    fn serviceTier(self: ConfigReadProjectLayers) ?[]const u8 {
        for (self.items) |layer| {
            if (layer.service_tier) |value| return value;
        }
        return null;
    }

    fn tools(self: ConfigReadProjectLayers) ConfigReadTools {
        var merged = ConfigReadTools{};
        for (self.items) |layer| {
            mergeConfigReadTools(&merged, layer.tools);
        }
        return merged;
    }

    fn sandboxWorkspaceWrite(self: ConfigReadProjectLayers) ConfigReadSandboxWorkspaceWrite {
        var sandbox = ConfigReadSandboxWorkspaceWrite{};
        for (self.items) |layer| {
            const layer_sandbox = layer.sandbox_workspace_write;
            if (layer_sandbox.present) sandbox.present = true;
            if (sandbox.writable_roots == null) {
                if (layer_sandbox.writable_roots) |roots| sandbox.writable_roots = roots;
            }
            if (!sandbox.network_access_present and layer_sandbox.network_access_present) {
                sandbox.network_access = layer_sandbox.network_access;
                sandbox.network_access_present = true;
            }
            if (!sandbox.exclude_tmpdir_env_var_present and layer_sandbox.exclude_tmpdir_env_var_present) {
                sandbox.exclude_tmpdir_env_var = layer_sandbox.exclude_tmpdir_env_var;
                sandbox.exclude_tmpdir_env_var_present = true;
            }
            if (!sandbox.exclude_slash_tmp_present and layer_sandbox.exclude_slash_tmp_present) {
                sandbox.exclude_slash_tmp = layer_sandbox.exclude_slash_tmp;
                sandbox.exclude_slash_tmp_present = true;
            }
        }
        return sandbox;
    }

    fn hasOriginKey(self: ConfigReadProjectLayers, key: []const u8) bool {
        return configReadProjectSliceHasOriginKey(self.items, key);
    }

    fn hasSandboxWorkspaceWriteRoot(self: ConfigReadProjectLayers) bool {
        for (self.items) |layer| {
            if (layer.sandbox_workspace_write.writable_roots != null) return true;
        }
        return false;
    }

    fn hasToolsAllowedDomains(self: ConfigReadProjectLayers) bool {
        return configReadProjectSliceHasToolsAllowedDomains(self.items);
    }
};

const ConfigReadUserLayer = struct {
    file_path: []const u8,
    version: []const u8,
    origin_keys: []const []const u8,
    tools: ConfigReadTools,
    apps: ConfigReadApps,
    sandbox_workspace_write: ConfigReadSandboxWorkspaceWrite,

    fn deinit(self: *ConfigReadUserLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        for (self.origin_keys) |key| allocator.free(key);
        allocator.free(self.origin_keys);
        self.tools.deinit(allocator);
        self.apps.deinit(allocator);
        self.sandbox_workspace_write.deinit(allocator);
    }
};

fn loadConfigReadUserLayer(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    bytes: []const u8,
    active_profile: ?[]const u8,
) !ConfigReadUserLayer {
    const origin_keys = try collectConfigReadUserOriginKeys(allocator, bytes, active_profile);
    errdefer {
        for (origin_keys) |key| allocator.free(key);
        allocator.free(origin_keys);
    }
    var tools = try loadConfigReadTools(allocator, bytes);
    errdefer tools.deinit(allocator);
    var apps = try loadConfigReadApps(allocator, bytes);
    errdefer apps.deinit(allocator);
    var sandbox_workspace_write = try loadConfigReadSandboxWorkspaceWrite(allocator, bytes);
    errdefer sandbox_workspace_write.deinit(allocator);
    const version = try configVersionAlloc(allocator, bytes);
    errdefer allocator.free(version);
    return .{
        .file_path = config_path,
        .version = version,
        .origin_keys = origin_keys,
        .tools = tools,
        .apps = apps,
        .sandbox_workspace_write = sandbox_workspace_write,
    };
}

const ConfigReadTools = struct {
    present: bool = false,
    web_search: ?ConfigReadWebSearchTool = null,
    view_image: ?bool = null,

    fn deinit(self: *ConfigReadTools, allocator: std.mem.Allocator) void {
        if (self.web_search) |*tool| tool.deinit(allocator);
    }
};

const ConfigReadWebSearchTool = struct {
    context_size: ?[]const u8 = null,
    allowed_domains: ?config.StringList = null,
    location: ?ConfigReadWebSearchLocation = null,

    fn deinit(self: *ConfigReadWebSearchTool, allocator: std.mem.Allocator) void {
        if (self.context_size) |value| allocator.free(value);
        if (self.allowed_domains) |*domains| domains.deinit(allocator);
        if (self.location) |*location| location.deinit(allocator);
    }
};

const ConfigReadWebSearchLocation = struct {
    country: ?[]const u8 = null,
    region: ?[]const u8 = null,
    city: ?[]const u8 = null,
    timezone: ?[]const u8 = null,

    fn deinit(self: *ConfigReadWebSearchLocation, allocator: std.mem.Allocator) void {
        if (self.country) |value| allocator.free(value);
        if (self.region) |value| allocator.free(value);
        if (self.city) |value| allocator.free(value);
        if (self.timezone) |value| allocator.free(value);
    }
};

const ConfigReadApps = struct {
    default_config: ?ConfigReadAppsDefault = null,
    items: []ConfigReadApp,

    fn empty() ConfigReadApps {
        return .{ .items = &.{} };
    }

    fn isEmpty(self: ConfigReadApps) bool {
        return self.default_config == null and self.items.len == 0;
    }

    fn deinit(self: *ConfigReadApps, allocator: std.mem.Allocator) void {
        for (self.items) |*app| app.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

const ConfigReadAppsDefault = struct {
    enabled: bool = true,
    enabled_present: bool = false,
    destructive_enabled: bool = true,
    destructive_enabled_present: bool = false,
    open_world_enabled: bool = true,
    open_world_enabled_present: bool = false,
};

const ConfigReadApp = struct {
    name: []const u8,
    enabled: bool = true,
    has_enabled: bool = false,
    destructive_enabled: ?bool = null,
    open_world_enabled: ?bool = null,
    default_tools_approval_mode: ?[]const u8 = null,
    default_tools_enabled: ?bool = null,
    tools: std.ArrayList(ConfigReadAppTool) = .empty,

    fn deinit(self: *ConfigReadApp, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_tools_approval_mode) |value| allocator.free(value);
        for (self.tools.items) |*tool| tool.deinit(allocator);
        self.tools.deinit(allocator);
    }
};

const ConfigReadAppTool = struct {
    name: []const u8,
    enabled: ?bool = null,
    approval_mode: ?[]const u8 = null,

    fn deinit(self: *ConfigReadAppTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.approval_mode) |value| allocator.free(value);
    }
};

const ConfigReadSandboxWorkspaceWrite = struct {
    present: bool = false,
    writable_roots: ?config.StringList = null,
    network_access: bool = false,
    network_access_present: bool = false,
    exclude_tmpdir_env_var: bool = false,
    exclude_tmpdir_env_var_present: bool = false,
    exclude_slash_tmp: bool = false,
    exclude_slash_tmp_present: bool = false,

    fn deinit(self: *ConfigReadSandboxWorkspaceWrite, allocator: std.mem.Allocator) void {
        if (self.writable_roots) |*roots| roots.deinit(allocator);
    }
};

fn effectiveConfigReadSandboxWorkspaceWrite(
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) ?ConfigReadSandboxWorkspaceWrite {
    const managed = if (managed_layer) |layer| layer.sandbox_workspace_write else ConfigReadSandboxWorkspaceWrite{};
    const project = project_layers.sandboxWorkspaceWrite();
    const user = if (user_layer) |layer| layer.sandbox_workspace_write else ConfigReadSandboxWorkspaceWrite{};
    const system = if (system_layer) |layer| layer.sandbox_workspace_write else ConfigReadSandboxWorkspaceWrite{};
    if (!managed.present and !project.present and !user.present and !system.present) return null;

    return .{
        .present = true,
        .writable_roots = managed.writable_roots orelse project.writable_roots orelse user.writable_roots orelse system.writable_roots,
        .network_access = if (managed.network_access_present) managed.network_access else if (project.network_access_present) project.network_access else if (user.network_access_present) user.network_access else system.network_access,
        .network_access_present = managed.network_access_present or project.network_access_present or user.network_access_present or system.network_access_present,
        .exclude_tmpdir_env_var = if (managed.exclude_tmpdir_env_var_present) managed.exclude_tmpdir_env_var else if (project.exclude_tmpdir_env_var_present) project.exclude_tmpdir_env_var else if (user.exclude_tmpdir_env_var_present) user.exclude_tmpdir_env_var else system.exclude_tmpdir_env_var,
        .exclude_tmpdir_env_var_present = managed.exclude_tmpdir_env_var_present or project.exclude_tmpdir_env_var_present or user.exclude_tmpdir_env_var_present or system.exclude_tmpdir_env_var_present,
        .exclude_slash_tmp = if (managed.exclude_slash_tmp_present) managed.exclude_slash_tmp else if (project.exclude_slash_tmp_present) project.exclude_slash_tmp else if (user.exclude_slash_tmp_present) user.exclude_slash_tmp else system.exclude_slash_tmp,
        .exclude_slash_tmp_present = managed.exclude_slash_tmp_present or project.exclude_slash_tmp_present or user.exclude_slash_tmp_present or system.exclude_slash_tmp_present,
    };
}

fn effectiveConfigReadTools(
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) ?ConfigReadTools {
    var tools = ConfigReadTools{};
    if (managed_layer) |layer| mergeConfigReadTools(&tools, layer.tools);
    mergeConfigReadTools(&tools, project_layers.tools());
    if (user_layer) |layer| mergeConfigReadTools(&tools, layer.tools);
    if (system_layer) |layer| mergeConfigReadTools(&tools, layer.tools);
    if (!tools.present) return null;
    return tools;
}

fn effectiveConfigReadApps(
    allocator: std.mem.Allocator,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) !?ConfigReadApps {
    var default_config: ?ConfigReadAppsDefault = null;
    var items = std.ArrayList(ConfigReadApp).empty;
    errdefer {
        for (items.items) |*app| app.deinit(allocator);
        items.deinit(allocator);
    }

    if (managed_layer) |layer| try mergeConfigReadApps(allocator, &default_config, &items, layer.apps);
    for (project_layers.items) |layer| try mergeConfigReadApps(allocator, &default_config, &items, layer.apps);
    if (user_layer) |layer| try mergeConfigReadApps(allocator, &default_config, &items, layer.apps);
    if (system_layer) |layer| try mergeConfigReadApps(allocator, &default_config, &items, layer.apps);
    if (default_config == null and items.items.len == 0) return null;

    return .{
        .default_config = default_config,
        .items = if (items.items.len == 0) &.{} else try items.toOwnedSlice(allocator),
    };
}

fn mergeConfigReadApps(
    allocator: std.mem.Allocator,
    default_config: *?ConfigReadAppsDefault,
    items: *std.ArrayList(ConfigReadApp),
    source: ConfigReadApps,
) !void {
    if (source.default_config) |source_default| {
        if (default_config.* == null) default_config.* = ConfigReadAppsDefault{};
        mergeConfigReadAppsDefault(&default_config.*.?, source_default);
    }
    for (source.items) |source_app| {
        const target_app = try ensureConfigReadApp(allocator, items, source_app.name);
        try mergeConfigReadApp(allocator, target_app, source_app);
    }
}

fn mergeConfigReadAppsDefault(target: *ConfigReadAppsDefault, source: ConfigReadAppsDefault) void {
    if (!target.enabled_present and source.enabled_present) {
        target.enabled = source.enabled;
        target.enabled_present = true;
    }
    if (!target.destructive_enabled_present and source.destructive_enabled_present) {
        target.destructive_enabled = source.destructive_enabled;
        target.destructive_enabled_present = true;
    }
    if (!target.open_world_enabled_present and source.open_world_enabled_present) {
        target.open_world_enabled = source.open_world_enabled;
        target.open_world_enabled_present = true;
    }
}

fn ensureConfigReadApp(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConfigReadApp),
    name: []const u8,
) !*ConfigReadApp {
    if (findConfigReadAppIndex(items.items, name)) |index| return &items.items[index];
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try items.append(allocator, .{ .name = owned_name });
    return &items.items[items.items.len - 1];
}

fn mergeConfigReadApp(
    allocator: std.mem.Allocator,
    target: *ConfigReadApp,
    source: ConfigReadApp,
) !void {
    if (!target.has_enabled and source.has_enabled) {
        target.enabled = source.enabled;
        target.has_enabled = true;
    }
    if (target.destructive_enabled == null) target.destructive_enabled = source.destructive_enabled;
    if (target.open_world_enabled == null) target.open_world_enabled = source.open_world_enabled;
    if (target.default_tools_enabled == null) target.default_tools_enabled = source.default_tools_enabled;
    if (target.default_tools_approval_mode == null) {
        if (source.default_tools_approval_mode) |value| {
            target.default_tools_approval_mode = try allocator.dupe(u8, value);
        }
    }
    for (source.tools.items) |source_tool| {
        const target_tool = try ensureConfigReadAppTool(allocator, &target.tools, source_tool.name);
        try mergeConfigReadAppTool(allocator, target_tool, source_tool);
    }
}

fn ensureConfigReadAppTool(
    allocator: std.mem.Allocator,
    tools: *std.ArrayList(ConfigReadAppTool),
    name: []const u8,
) !*ConfigReadAppTool {
    if (findConfigReadAppToolIndex(tools.items, name)) |index| return &tools.items[index];
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try tools.append(allocator, .{ .name = owned_name });
    return &tools.items[tools.items.len - 1];
}

fn mergeConfigReadAppTool(
    allocator: std.mem.Allocator,
    target: *ConfigReadAppTool,
    source: ConfigReadAppTool,
) !void {
    if (target.enabled == null) target.enabled = source.enabled;
    if (target.approval_mode == null) {
        if (source.approval_mode) |value| {
            target.approval_mode = try allocator.dupe(u8, value);
        }
    }
}

fn mergeConfigReadTools(target: *ConfigReadTools, source: ConfigReadTools) void {
    if (source.present) target.present = true;
    if (target.view_image == null) target.view_image = source.view_image;
    if (source.web_search) |source_web_search| {
        if (target.web_search == null) target.web_search = ConfigReadWebSearchTool{};
        mergeConfigReadWebSearchTool(&target.web_search.?, source_web_search);
    }
}

fn mergeConfigReadWebSearchTool(target: *ConfigReadWebSearchTool, source: ConfigReadWebSearchTool) void {
    if (target.context_size == null) target.context_size = source.context_size;
    if (target.allowed_domains == null) target.allowed_domains = source.allowed_domains;
    if (source.location) |source_location| {
        if (target.location == null) target.location = ConfigReadWebSearchLocation{};
        mergeConfigReadWebSearchLocation(&target.location.?, source_location);
    }
}

fn mergeConfigReadWebSearchLocation(target: *ConfigReadWebSearchLocation, source: ConfigReadWebSearchLocation) void {
    if (target.country == null) target.country = source.country;
    if (target.region == null) target.region = source.region;
    if (target.city == null) target.city = source.city;
    if (target.timezone == null) target.timezone = source.timezone;
}

fn loadConfigReadTools(allocator: std.mem.Allocator, bytes: []const u8) !ConfigReadTools {
    var tools = ConfigReadTools{};
    errdefer tools.deinit(allocator);

    if (configReadSectionHasKey(bytes, "tools", "web_search")) {
        tools.present = true;
    }
    if (config.sectionBoolValue(bytes, "tools", "view_image")) |value| {
        tools.view_image = value;
        tools.present = true;
    }
    if (try loadConfigReadWebSearchTool(allocator, bytes)) |web_search| {
        tools.web_search = web_search;
        tools.present = true;
    }

    return tools;
}

fn appendConfigReadToolsOriginKeys(
    allocator: std.mem.Allocator,
    origin_keys: *std.ArrayList([]const u8),
    tools: ConfigReadTools,
) !void {
    if (tools.web_search) |web_search| {
        if (web_search.context_size != null) {
            try appendUniqueOriginKey(allocator, origin_keys, "tools.web_search.context_size");
        }
        if (web_search.allowed_domains) |domains| {
            for (domains.items, 0..) |_, index| {
                const key = try std.fmt.allocPrint(allocator, "tools.web_search.allowed_domains.{d}", .{index});
                defer allocator.free(key);
                try appendUniqueOriginKey(allocator, origin_keys, key);
            }
        }
        if (web_search.location) |location| {
            if (location.country != null) {
                try appendUniqueOriginKey(allocator, origin_keys, "tools.web_search.location.country");
            }
            if (location.region != null) {
                try appendUniqueOriginKey(allocator, origin_keys, "tools.web_search.location.region");
            }
            if (location.city != null) {
                try appendUniqueOriginKey(allocator, origin_keys, "tools.web_search.location.city");
            }
            if (location.timezone != null) {
                try appendUniqueOriginKey(allocator, origin_keys, "tools.web_search.location.timezone");
            }
        }
    }
    if (tools.view_image != null) {
        try appendUniqueOriginKey(allocator, origin_keys, "tools.view_image");
    }
}

fn loadConfigReadWebSearchTool(allocator: std.mem.Allocator, bytes: []const u8) !?ConfigReadWebSearchTool {
    if (!configReadSectionExists(bytes, "tools.web_search")) return null;

    var tool = ConfigReadWebSearchTool{};
    errdefer tool.deinit(allocator);

    if (try config.sectionStringValue(allocator, bytes, "tools.web_search", "context_size")) |value| {
        errdefer allocator.free(value);
        if (!isConfigReadWebSearchContextSize(value)) return error.InvalidConfigReadWebSearchContextSize;
        tool.context_size = value;
    }
    if (try config.sectionStringArrayValue(allocator, bytes, "tools.web_search", "allowed_domains")) |domains| {
        tool.allowed_domains = domains;
    }
    if (configReadSectionRawValue(bytes, "tools.web_search", "location")) |raw_location| {
        tool.location = try parseConfigReadWebSearchLocation(allocator, raw_location);
    }

    return tool;
}

fn isConfigReadWebSearchContextSize(value: []const u8) bool {
    return std.mem.eql(u8, value, "low") or
        std.mem.eql(u8, value, "medium") or
        std.mem.eql(u8, value, "high");
}

fn parseConfigReadWebSearchLocation(allocator: std.mem.Allocator, raw: []const u8) !ConfigReadWebSearchLocation {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '{') return error.InvalidConfigReadWebSearchLocation;
    const close_index = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return error.InvalidConfigReadWebSearchLocation;
    const body = trimmed[1..close_index];

    var location = ConfigReadWebSearchLocation{};
    errdefer location.deinit(allocator);

    var field_start: usize = 0;
    while (try nextConfigReadInlineTableField(body, &field_start)) |field_raw| {
        const field = std.mem.trim(u8, field_raw, " \t\r\n");
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidConfigReadWebSearchLocation;
        const key = std.mem.trim(u8, field[0..eq], " \t\r\n");
        if (!configReadWebSearchLocationKeySupported(key)) continue;

        const value_rhs = std.mem.trim(u8, field[eq + 1 ..], " \t\r\n");
        const value = try config.parseTomlString(allocator, value_rhs) orelse return error.InvalidConfigReadWebSearchLocation;
        errdefer allocator.free(value);
        if (std.mem.eql(u8, key, "country")) {
            if (location.country) |existing| allocator.free(existing);
            location.country = value;
        } else if (std.mem.eql(u8, key, "region")) {
            if (location.region) |existing| allocator.free(existing);
            location.region = value;
        } else if (std.mem.eql(u8, key, "city")) {
            if (location.city) |existing| allocator.free(existing);
            location.city = value;
        } else if (std.mem.eql(u8, key, "timezone")) {
            if (location.timezone) |existing| allocator.free(existing);
            location.timezone = value;
        }
    }

    return location;
}

fn nextConfigReadInlineTableField(body: []const u8, start: *usize) !?[]const u8 {
    while (start.* < body.len and (body[start.*] == ',' or body[start.*] == ' ' or body[start.*] == '\t' or body[start.*] == '\r' or body[start.*] == '\n')) {
        start.* += 1;
    }
    if (start.* >= body.len) return null;

    const field_start = start.*;
    var index = start.*;
    var in_string = false;
    var escaped = false;
    var bracket_depth: usize = 0;
    while (index < body.len) : (index += 1) {
        const byte = body[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '[') {
            bracket_depth += 1;
        } else if (byte == ']') {
            if (bracket_depth == 0) return error.InvalidConfigReadInlineTable;
            bracket_depth -= 1;
        } else if (byte == ',' and bracket_depth == 0) {
            start.* = index + 1;
            return body[field_start..index];
        }
    }
    if (in_string or escaped or bracket_depth != 0) return error.InvalidConfigReadInlineTable;

    start.* = index;
    return body[field_start..index];
}

fn configReadWebSearchLocationKeySupported(key: []const u8) bool {
    return std.mem.eql(u8, key, "country") or
        std.mem.eql(u8, key, "region") or
        std.mem.eql(u8, key, "city") or
        std.mem.eql(u8, key, "timezone");
}

fn configReadSectionExists(bytes: []const u8, section_name: []const u8) bool {
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (configReadLineIsExactSection(line, section_name)) return true;
    }
    return false;
}

fn configReadSectionHasKey(bytes: []const u8, section_name: []const u8, key: []const u8) bool {
    return configReadSectionRawValue(bytes, section_name, key) != null;
}

fn configReadSectionRawValue(bytes: []const u8, section_name: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = configReadLineIsExactSection(line, section_name);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn configReadLineIsExactSection(line: []const u8, section_name: []const u8) bool {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    return std.mem.eql(u8, section, section_name);
}

fn loadConfigReadApps(allocator: std.mem.Allocator, bytes: []const u8) !ConfigReadApps {
    var apps = std.ArrayList(ConfigReadApp).empty;
    errdefer {
        for (apps.items) |*app| app.deinit(allocator);
        apps.deinit(allocator);
    }

    var default_config: ?ConfigReadAppsDefault = null;
    var in_default_section = false;
    var current_app_index: ?usize = null;
    var current_tool_app_index: ?usize = null;
    var current_tool_index: ?usize = null;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_default_section = false;
            current_app_index = null;
            current_tool_app_index = null;
            current_tool_index = null;
            if (try parseConfigReadAppToolSection(allocator, line)) |section| {
                var owned_app_name: ?[]const u8 = section.app_name;
                var owned_tool_name: ?[]const u8 = section.tool_name;
                errdefer if (owned_app_name) |value| allocator.free(value);
                errdefer if (owned_tool_name) |value| allocator.free(value);

                if (std.mem.eql(u8, section.app_name, "_default")) {
                    allocator.free(section.app_name);
                    allocator.free(section.tool_name);
                    continue;
                }

                current_tool_app_index = findConfigReadAppIndex(apps.items, section.app_name);
                if (current_tool_app_index == null) {
                    try apps.append(allocator, .{ .name = section.app_name });
                    current_tool_app_index = apps.items.len - 1;
                    owned_app_name = null;
                }
                if (owned_app_name) |value| {
                    allocator.free(value);
                    owned_app_name = null;
                }

                const app_index = current_tool_app_index.?;
                current_tool_index = findConfigReadAppToolIndex(apps.items[app_index].tools.items, section.tool_name);
                if (current_tool_index == null) {
                    try apps.items[app_index].tools.append(allocator, .{ .name = section.tool_name });
                    current_tool_index = apps.items[app_index].tools.items.len - 1;
                    owned_tool_name = null;
                }
                if (owned_tool_name) |value| {
                    allocator.free(value);
                    owned_tool_name = null;
                }
                continue;
            }
            if (try parseConfigReadAppSectionName(allocator, line)) |name| {
                var owned_name: ?[]const u8 = name;
                errdefer if (owned_name) |value| allocator.free(value);
                if (std.mem.eql(u8, name, "_default")) {
                    default_config = default_config orelse ConfigReadAppsDefault{};
                    in_default_section = true;
                    allocator.free(name);
                    continue;
                }
                current_app_index = findConfigReadAppIndex(apps.items, name);
                if (current_app_index == null) {
                    try apps.append(allocator, .{ .name = name });
                    current_app_index = apps.items.len - 1;
                    owned_name = null;
                }
                if (owned_name) |value| allocator.free(value);
            }
            continue;
        }

        if (in_default_section) {
            try applyConfigReadAppsDefaultLine(&default_config.?, line);
            continue;
        }
        if (current_tool_app_index) |app_index| {
            if (current_tool_index) |tool_index| {
                try applyConfigReadAppToolLine(allocator, &apps.items[app_index].tools.items[tool_index], line);
                continue;
            }
        }
        const app_index = current_app_index orelse continue;
        try applyConfigReadAppLine(allocator, &apps.items[app_index], line);
    }

    if (apps.items.len == 0 and default_config == null) return ConfigReadApps.empty();
    return .{
        .default_config = default_config,
        .items = if (apps.items.len == 0) &.{} else try apps.toOwnedSlice(allocator),
    };
}

fn parseConfigReadAppSectionName(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "apps.";
    if (!std.mem.startsWith(u8, section, prefix)) return null;
    const raw_name = section[prefix.len..];
    return parseConfigReadAppPathComponent(allocator, raw_name);
}

const ConfigReadAppToolSection = struct {
    app_name: []const u8,
    tool_name: []const u8,
};

fn parseConfigReadAppToolSection(allocator: std.mem.Allocator, line: []const u8) !?ConfigReadAppToolSection {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "apps.";
    if (!std.mem.startsWith(u8, section, prefix)) return null;
    const marker = ".tools.";
    const marker_index = std.mem.indexOf(u8, section, marker) orelse return null;
    const raw_app_name = section[prefix.len..marker_index];
    const raw_tool_name = section[marker_index + marker.len ..];
    const app_name = (try parseConfigReadAppPathComponent(allocator, raw_app_name)) orelse return null;
    errdefer allocator.free(app_name);
    const tool_name = (try parseConfigReadAppPathComponent(allocator, raw_tool_name)) orelse {
        allocator.free(app_name);
        return null;
    };
    return .{ .app_name = app_name, .tool_name = tool_name };
}

fn parseConfigReadAppPathComponent(allocator: std.mem.Allocator, raw_name: []const u8) !?[]const u8 {
    if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '.') != null) return null;
    if (raw_name[0] == '"') {
        return try config.parseTomlString(allocator, raw_name) orelse error.InvalidConfigReadAppSection;
    }
    return @as(?[]const u8, try allocator.dupe(u8, raw_name));
}

fn findConfigReadAppIndex(apps: []const ConfigReadApp, name: []const u8) ?usize {
    for (apps, 0..) |app, index| {
        if (std.mem.eql(u8, app.name, name)) return index;
    }
    return null;
}

fn findConfigReadAppToolIndex(tools: []const ConfigReadAppTool, name: []const u8) ?usize {
    for (tools, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, name)) return index;
    }
    return null;
}

fn applyConfigReadAppsDefaultLine(default_config: *ConfigReadAppsDefault, line: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "enabled")) {
        default_config.enabled = try parseConfigReadBool(rhs);
        default_config.enabled_present = true;
    } else if (std.mem.eql(u8, key, "destructive_enabled")) {
        default_config.destructive_enabled = try parseConfigReadBool(rhs);
        default_config.destructive_enabled_present = true;
    } else if (std.mem.eql(u8, key, "open_world_enabled")) {
        default_config.open_world_enabled = try parseConfigReadBool(rhs);
        default_config.open_world_enabled_present = true;
    }
}

fn applyConfigReadAppToolLine(allocator: std.mem.Allocator, tool: *ConfigReadAppTool, line: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "enabled")) {
        tool.enabled = try parseConfigReadBool(rhs);
    } else if (std.mem.eql(u8, key, "approval_mode")) {
        const value = try config.parseTomlString(allocator, rhs) orelse return error.InvalidConfigReadAppToolApproval;
        errdefer allocator.free(value);
        if (!isConfigReadAppToolApproval(value)) return error.InvalidConfigReadAppToolApproval;
        if (tool.approval_mode) |existing| allocator.free(existing);
        tool.approval_mode = value;
    }
}

fn applyConfigReadAppLine(allocator: std.mem.Allocator, app: *ConfigReadApp, line: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "enabled")) {
        app.enabled = try parseConfigReadBool(rhs);
        app.has_enabled = true;
    } else if (std.mem.eql(u8, key, "destructive_enabled")) {
        app.destructive_enabled = try parseConfigReadBool(rhs);
    } else if (std.mem.eql(u8, key, "open_world_enabled")) {
        app.open_world_enabled = try parseConfigReadBool(rhs);
    } else if (std.mem.eql(u8, key, "default_tools_enabled")) {
        app.default_tools_enabled = try parseConfigReadBool(rhs);
    } else if (std.mem.eql(u8, key, "default_tools_approval_mode")) {
        const value = try config.parseTomlString(allocator, rhs) orelse return error.InvalidConfigReadAppToolApproval;
        errdefer allocator.free(value);
        if (!isConfigReadAppToolApproval(value)) return error.InvalidConfigReadAppToolApproval;
        if (app.default_tools_approval_mode) |existing| allocator.free(existing);
        app.default_tools_approval_mode = value;
    }
}

fn parseConfigReadBool(rhs: []const u8) !bool {
    if (std.mem.eql(u8, rhs, "true")) return true;
    if (std.mem.eql(u8, rhs, "false")) return false;
    return error.InvalidConfigReadBool;
}

fn isConfigReadAppToolApproval(value: []const u8) bool {
    return std.mem.eql(u8, value, "auto") or
        std.mem.eql(u8, value, "prompt") or
        std.mem.eql(u8, value, "approve");
}

fn loadConfigReadManagedLayer(allocator: std.mem.Allocator) !?ConfigReadManagedLayer {
    const file_path = try managedConfigPath(allocator);
    errdefer allocator.free(file_path);
    const bytes = try config.readConfigTomlFile(allocator, file_path);
    const payload = bytes orelse {
        allocator.free(file_path);
        return null;
    };
    defer allocator.free(payload);

    var origin_keys = std.ArrayList([]const u8).empty;
    errdefer {
        for (origin_keys.items) |key| allocator.free(key);
        origin_keys.deinit(allocator);
    }

    var model: ?[]const u8 = null;
    errdefer if (model) |value| allocator.free(value);
    var approval_policy: ?config.ApprovalPolicy = null;
    var sandbox_mode: ?config.SandboxMode = null;
    var web_search_mode: ?config.WebSearchMode = null;
    var model_reasoning_effort: ?config.ReasoningEffort = null;
    var service_tier: ?[]const u8 = null;
    errdefer if (service_tier) |value| allocator.free(value);
    var tools = ConfigReadTools{};
    errdefer tools.deinit(allocator);
    var apps = ConfigReadApps.empty();
    errdefer apps.deinit(allocator);

    if (try config.topLevelStringValue(allocator, payload, "model")) |value| {
        model = value;
        try appendUniqueOriginKey(allocator, &origin_keys, "model");
    }
    if (try config.topLevelStringValue(allocator, payload, "approval_policy")) |value| {
        defer allocator.free(value);
        approval_policy = try config.ApprovalPolicy.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "approval_policy");
    }
    if (try config.topLevelStringValue(allocator, payload, "sandbox_mode")) |value| {
        defer allocator.free(value);
        sandbox_mode = try config.SandboxMode.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "sandbox_mode");
    }
    if (try config.topLevelStringValue(allocator, payload, "web_search")) |value| {
        defer allocator.free(value);
        web_search_mode = try config.WebSearchMode.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "web_search");
    }
    if (try config.topLevelStringValue(allocator, payload, "model_reasoning_effort")) |value| {
        defer allocator.free(value);
        model_reasoning_effort = try config.ReasoningEffort.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "model_reasoning_effort");
    }
    if (try config.topLevelStringValue(allocator, payload, "service_tier")) |value| {
        defer allocator.free(value);
        service_tier = try config.normalizeServiceTier(allocator, value);
        try appendUniqueOriginKey(allocator, &origin_keys, "service_tier");
    }
    tools = try loadConfigReadTools(allocator, payload);
    try appendConfigReadToolsOriginKeys(allocator, &origin_keys, tools);
    apps = try loadConfigReadApps(allocator, payload);

    var sandbox_workspace_write = try loadConfigReadSandboxWorkspaceWrite(allocator, payload);
    errdefer sandbox_workspace_write.deinit(allocator);
    try appendConfigReadSandboxWorkspaceOriginKeys(allocator, &origin_keys, sandbox_workspace_write);

    const owned_origin_keys = if (origin_keys.items.len > 0)
        try origin_keys.toOwnedSlice(allocator)
    else
        &.{};

    return .{
        .file_path = file_path,
        .version = try configVersionAlloc(allocator, payload),
        .origin_keys = owned_origin_keys,
        .model = model,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .model_reasoning_effort = model_reasoning_effort,
        .service_tier = service_tier,
        .tools = tools,
        .apps = apps,
        .sandbox_workspace_write = sandbox_workspace_write,
    };
}

fn loadConfigReadSystemLayer(allocator: std.mem.Allocator) !ConfigReadSystemLayer {
    const file_path = try systemConfigPath(allocator);
    errdefer allocator.free(file_path);
    const bytes = try config.readConfigTomlFile(allocator, file_path);
    const payload = bytes orelse "";
    defer if (bytes) |owned| allocator.free(owned);

    var origin_keys = std.ArrayList([]const u8).empty;
    errdefer {
        for (origin_keys.items) |key| allocator.free(key);
        origin_keys.deinit(allocator);
    }

    var model: ?[]const u8 = null;
    errdefer if (model) |value| allocator.free(value);
    var approval_policy: ?config.ApprovalPolicy = null;
    var sandbox_mode: ?config.SandboxMode = null;
    var web_search_mode: ?config.WebSearchMode = null;
    var model_reasoning_effort: ?config.ReasoningEffort = null;
    var service_tier: ?[]const u8 = null;
    errdefer if (service_tier) |value| allocator.free(value);
    var tools = ConfigReadTools{};
    errdefer tools.deinit(allocator);
    var apps = ConfigReadApps.empty();
    errdefer apps.deinit(allocator);

    if (try config.topLevelStringValue(allocator, payload, "model")) |value| {
        model = value;
        try appendUniqueOriginKey(allocator, &origin_keys, "model");
    }
    if (try config.topLevelStringValue(allocator, payload, "approval_policy")) |value| {
        defer allocator.free(value);
        approval_policy = try config.ApprovalPolicy.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "approval_policy");
    }
    if (try config.topLevelStringValue(allocator, payload, "sandbox_mode")) |value| {
        defer allocator.free(value);
        sandbox_mode = try config.SandboxMode.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "sandbox_mode");
    }
    if (try config.topLevelStringValue(allocator, payload, "web_search")) |value| {
        defer allocator.free(value);
        web_search_mode = try config.WebSearchMode.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "web_search");
    }
    if (try config.topLevelStringValue(allocator, payload, "model_reasoning_effort")) |value| {
        defer allocator.free(value);
        model_reasoning_effort = try config.ReasoningEffort.parse(value);
        try appendUniqueOriginKey(allocator, &origin_keys, "model_reasoning_effort");
    }
    if (try config.topLevelStringValue(allocator, payload, "service_tier")) |value| {
        defer allocator.free(value);
        service_tier = try config.normalizeServiceTier(allocator, value);
        try appendUniqueOriginKey(allocator, &origin_keys, "service_tier");
    }
    tools = try loadConfigReadTools(allocator, payload);
    try appendConfigReadToolsOriginKeys(allocator, &origin_keys, tools);
    apps = try loadConfigReadApps(allocator, payload);

    var sandbox_workspace_write = try loadConfigReadSandboxWorkspaceWrite(allocator, payload);
    errdefer sandbox_workspace_write.deinit(allocator);
    try appendConfigReadSandboxWorkspaceOriginKeys(allocator, &origin_keys, sandbox_workspace_write);

    const owned_origin_keys = if (origin_keys.items.len > 0)
        try origin_keys.toOwnedSlice(allocator)
    else
        &.{};

    return .{
        .file_path = file_path,
        .version = try configVersionAlloc(allocator, payload),
        .origin_keys = owned_origin_keys,
        .model = model,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .model_reasoning_effort = model_reasoning_effort,
        .service_tier = service_tier,
        .tools = tools,
        .apps = apps,
        .sandbox_workspace_write = sandbox_workspace_write,
    };
}

fn loadConfigReadSandboxWorkspaceWrite(allocator: std.mem.Allocator, bytes: []const u8) !ConfigReadSandboxWorkspaceWrite {
    var sandbox = ConfigReadSandboxWorkspaceWrite{};
    errdefer sandbox.deinit(allocator);

    if (try config.sectionStringArrayValue(allocator, bytes, "sandbox_workspace_write", "writable_roots")) |roots| {
        sandbox.writable_roots = roots;
        sandbox.present = true;
    }
    if (config.sectionBoolValue(bytes, "sandbox_workspace_write", "network_access")) |value| {
        sandbox.network_access = value;
        sandbox.network_access_present = true;
        sandbox.present = true;
    }
    if (config.sectionBoolValue(bytes, "sandbox_workspace_write", "exclude_tmpdir_env_var")) |value| {
        sandbox.exclude_tmpdir_env_var = value;
        sandbox.exclude_tmpdir_env_var_present = true;
        sandbox.present = true;
    }
    if (config.sectionBoolValue(bytes, "sandbox_workspace_write", "exclude_slash_tmp")) |value| {
        sandbox.exclude_slash_tmp = value;
        sandbox.exclude_slash_tmp_present = true;
        sandbox.present = true;
    }
    if (configReadSectionExists(bytes, "sandbox_workspace_write")) {
        sandbox.present = true;
    }

    if (configReadTopLevelRawValue(bytes, "sandbox_workspace_write")) |raw| {
        try applyConfigReadSandboxWorkspaceInline(allocator, &sandbox, raw);
        sandbox.present = true;
    }

    return sandbox;
}

fn appendConfigReadSandboxWorkspaceOriginKeys(
    allocator: std.mem.Allocator,
    origin_keys: *std.ArrayList([]const u8),
    sandbox: ConfigReadSandboxWorkspaceWrite,
) !void {
    if (sandbox.writable_roots) |roots| {
        for (roots.items, 0..) |_, index| {
            const key = try std.fmt.allocPrint(allocator, "sandbox_workspace_write.writable_roots.{d}", .{index});
            defer allocator.free(key);
            try appendUniqueOriginKey(allocator, origin_keys, key);
        }
    }
    if (sandbox.network_access_present) {
        try appendUniqueOriginKey(allocator, origin_keys, "sandbox_workspace_write.network_access");
    }
    if (sandbox.exclude_tmpdir_env_var_present) {
        try appendUniqueOriginKey(allocator, origin_keys, "sandbox_workspace_write.exclude_tmpdir_env_var");
    }
    if (sandbox.exclude_slash_tmp_present) {
        try appendUniqueOriginKey(allocator, origin_keys, "sandbox_workspace_write.exclude_slash_tmp");
    }
}

fn applyConfigReadSandboxWorkspaceInline(
    allocator: std.mem.Allocator,
    sandbox: *ConfigReadSandboxWorkspaceWrite,
    raw: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len < 2 or trimmed[0] != '{') return error.InvalidConfigReadSandboxWorkspaceWrite;
    const close_index = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return error.InvalidConfigReadSandboxWorkspaceWrite;
    const body = trimmed[1..close_index];

    var field_start: usize = 0;
    while (try nextConfigReadInlineTableField(body, &field_start)) |field_raw| {
        const field = std.mem.trim(u8, field_raw, " \t\r\n");
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidConfigReadSandboxWorkspaceWrite;
        const key = std.mem.trim(u8, field[0..eq], " \t\r\n\"");
        const rhs = std.mem.trim(u8, field[eq + 1 ..], " \t\r\n");
        if (std.mem.eql(u8, key, "writable_roots")) {
            const roots = try config.parseTomlStringArray(allocator, rhs) orelse return error.InvalidConfigReadSandboxWorkspaceWrite;
            if (sandbox.writable_roots) |*existing| existing.deinit(allocator);
            sandbox.writable_roots = roots;
        } else if (std.mem.eql(u8, key, "network_access")) {
            sandbox.network_access = try parseConfigReadBool(rhs);
            sandbox.network_access_present = true;
        } else if (std.mem.eql(u8, key, "exclude_tmpdir_env_var")) {
            sandbox.exclude_tmpdir_env_var = try parseConfigReadBool(rhs);
            sandbox.exclude_tmpdir_env_var_present = true;
        } else if (std.mem.eql(u8, key, "exclude_slash_tmp")) {
            sandbox.exclude_slash_tmp = try parseConfigReadBool(rhs);
            sandbox.exclude_slash_tmp_present = true;
        }
    }
}

fn configReadTopLevelRawValue(bytes: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

const ConfigReadSection = enum {
    top_level,
    active_profile,
    other,
};

fn collectConfigReadUserOriginKeys(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    active_profile: ?[]const u8,
) ![]const []const u8 {
    var keys = std.ArrayList([]const u8).empty;
    errdefer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }

    var section: ConfigReadSection = .top_level;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = configReadSectionForLine(line, active_profile);
            continue;
        }
        if (section != .top_level and section != .active_profile) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!isConfigReadOriginField(key)) continue;
        if (section == .active_profile and std.mem.eql(u8, key, "profile")) continue;
        try appendUniqueOriginKey(allocator, &keys, key);
    }

    return keys.toOwnedSlice(allocator);
}

fn loadConfigReadProjectLayers(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    codex_home: []const u8,
    user_config_bytes: ?[]const u8,
) !ConfigReadProjectLayers {
    const project_cwd = cwd orelse return ConfigReadProjectLayers.empty();
    const user_bytes = user_config_bytes orelse return ConfigReadProjectLayers.empty();
    var trusted_ancestors = try configReadTrustedProjectAncestors(allocator, project_cwd, user_bytes);
    defer trusted_ancestors.deinit(allocator);
    if (trusted_ancestors.items.len == 0) return ConfigReadProjectLayers.empty();

    var layers = std.ArrayList(ConfigReadProjectLayer).empty;
    errdefer {
        for (layers.items) |*layer| layer.deinit(allocator);
        layers.deinit(allocator);
    }

    for (trusted_ancestors.items) |ancestor| {
        if (try loadConfigReadProjectLayer(allocator, ancestor, codex_home)) |layer| {
            try layers.append(allocator, layer);
        }
    }
    if (layers.items.len == 0) return ConfigReadProjectLayers.empty();
    return .{ .items = try layers.toOwnedSlice(allocator) };
}

fn configReadTrustedProjectAncestors(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    user_config_bytes: []const u8,
) !std.ArrayList([]const u8) {
    var ancestors = std.ArrayList([]const u8).empty;
    errdefer ancestors.deinit(allocator);

    var current = cwd;
    while (true) {
        try ancestors.append(allocator, current);
        if (try configReadProjectTrusted(allocator, user_config_bytes, current)) return ancestors;
        current = std.fs.path.dirname(current) orelse break;
    }

    ancestors.clearRetainingCapacity();
    return ancestors;
}

fn loadConfigReadProjectLayer(
    allocator: std.mem.Allocator,
    layer_cwd: []const u8,
    codex_home: []const u8,
) !?ConfigReadProjectLayer {
    const dot_codex_folder = try std.fs.path.join(allocator, &.{ layer_cwd, ".codex" });
    errdefer allocator.free(dot_codex_folder);
    if (std.mem.eql(u8, dot_codex_folder, codex_home)) {
        allocator.free(dot_codex_folder);
        return null;
    }

    var dot_codex_dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dot_codex_folder, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            allocator.free(dot_codex_folder);
            return null;
        },
        else => return err,
    };
    dot_codex_dir.close(std.Io.Threaded.global_single_threaded.io());

    const project_config_path = try std.fs.path.join(allocator, &.{ dot_codex_folder, "config.toml" });
    defer allocator.free(project_config_path);

    const project_config_bytes = try config.readConfigTomlFile(allocator, project_config_path);
    defer if (project_config_bytes) |bytes| allocator.free(bytes);
    const bytes = project_config_bytes orelse "";
    const version = try configVersionAlloc(allocator, bytes);
    errdefer allocator.free(version);

    var origin_keys = std.ArrayList([]const u8).empty;
    errdefer {
        for (origin_keys.items) |key| allocator.free(key);
        origin_keys.deinit(allocator);
    }
    var model: ?[]const u8 = null;
    errdefer if (model) |value| allocator.free(value);
    var approval_policy: ?config.ApprovalPolicy = null;
    var sandbox_mode: ?config.SandboxMode = null;
    var web_search_mode: ?config.WebSearchMode = null;
    var model_reasoning_effort: ?config.ReasoningEffort = null;
    var service_tier: ?[]const u8 = null;
    errdefer if (service_tier) |value| allocator.free(value);
    var tools = ConfigReadTools{};
    errdefer tools.deinit(allocator);
    var apps = ConfigReadApps.empty();
    errdefer apps.deinit(allocator);
    var sandbox_workspace_write = ConfigReadSandboxWorkspaceWrite{};
    errdefer sandbox_workspace_write.deinit(allocator);
    if (project_config_bytes) |config_bytes| {
        if (try config.topLevelStringValue(allocator, config_bytes, "model")) |value| {
            model = value;
            try appendUniqueOriginKey(allocator, &origin_keys, "model");
        }
        if (try config.topLevelStringValue(allocator, config_bytes, "approval_policy")) |value| {
            defer allocator.free(value);
            approval_policy = try config.ApprovalPolicy.parse(value);
            try appendUniqueOriginKey(allocator, &origin_keys, "approval_policy");
        }
        if (try config.topLevelStringValue(allocator, config_bytes, "sandbox_mode")) |value| {
            defer allocator.free(value);
            sandbox_mode = try config.SandboxMode.parse(value);
            try appendUniqueOriginKey(allocator, &origin_keys, "sandbox_mode");
        }
        if (try config.topLevelStringValue(allocator, config_bytes, "web_search")) |value| {
            defer allocator.free(value);
            web_search_mode = try config.WebSearchMode.parse(value);
            try appendUniqueOriginKey(allocator, &origin_keys, "web_search");
        }
        if (try config.topLevelStringValue(allocator, config_bytes, "model_reasoning_effort")) |value| {
            defer allocator.free(value);
            model_reasoning_effort = try config.ReasoningEffort.parse(value);
            try appendUniqueOriginKey(allocator, &origin_keys, "model_reasoning_effort");
        }
        if (try config.topLevelStringValue(allocator, config_bytes, "service_tier")) |value| {
            defer allocator.free(value);
            service_tier = try config.normalizeServiceTier(allocator, value);
            try appendUniqueOriginKey(allocator, &origin_keys, "service_tier");
        }
        tools = try loadConfigReadTools(allocator, config_bytes);
        try appendConfigReadToolsOriginKeys(allocator, &origin_keys, tools);
        apps = try loadConfigReadApps(allocator, config_bytes);
        sandbox_workspace_write = try loadConfigReadSandboxWorkspaceWrite(allocator, config_bytes);
        try appendConfigReadSandboxWorkspaceOriginKeys(allocator, &origin_keys, sandbox_workspace_write);
    }
    const owned_origin_keys = if (origin_keys.items.len > 0)
        try origin_keys.toOwnedSlice(allocator)
    else
        &.{};

    return .{
        .dot_codex_folder = dot_codex_folder,
        .version = version,
        .origin_keys = owned_origin_keys,
        .model = model,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .model_reasoning_effort = model_reasoning_effort,
        .service_tier = service_tier,
        .tools = tools,
        .apps = apps,
        .sandbox_workspace_write = sandbox_workspace_write,
    };
}

fn configReadProjectTrusted(allocator: std.mem.Allocator, user_config_bytes: []const u8, cwd: []const u8) !bool {
    const trust_level = try config.namedSectionStringValue(allocator, user_config_bytes, "projects.", cwd, "trust_level");
    defer if (trust_level) |value| allocator.free(value);
    return if (trust_level) |value| std.mem.eql(u8, value, "trusted") else false;
}

fn configReadSectionForLine(line: []const u8, active_profile: ?[]const u8) ConfigReadSection {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return .other;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.indexOfScalar(u8, section, '.') == null) return .other;
    if (active_profile) |profile| {
        const prefix = "profiles.";
        if (std.mem.startsWith(u8, section, prefix)) {
            const profile_name = section[prefix.len..];
            if (profileSectionNameMatches(profile_name, profile)) return .active_profile;
        }
    }
    return .other;
}

fn profileSectionNameMatches(raw_name: []const u8, profile: []const u8) bool {
    if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"') {
        return std.mem.eql(u8, raw_name[1 .. raw_name.len - 1], profile);
    }
    return std.mem.eql(u8, raw_name, profile);
}

fn isConfigReadOriginField(key: []const u8) bool {
    return std.mem.eql(u8, key, "model") or
        std.mem.eql(u8, key, "profile") or
        std.mem.eql(u8, key, "approval_policy") or
        std.mem.eql(u8, key, "sandbox_mode") or
        std.mem.eql(u8, key, "web_search") or
        std.mem.eql(u8, key, "model_reasoning_effort") or
        std.mem.eql(u8, key, "service_tier") or
        std.mem.eql(u8, key, "oss_provider") or
        std.mem.eql(u8, key, "openai_base_url") or
        std.mem.eql(u8, key, "chatgpt_base_url");
}

fn appendUniqueOriginKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]const u8),
    key: []const u8,
) !void {
    for (keys.items) |existing| {
        if (std.mem.eql(u8, existing, key)) return;
    }
    try keys.append(allocator, try allocator.dupe(u8, key));
}

fn appendConfigReadOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) !void {
    try result.append(allocator, '{');
    var first = true;
    if (managed_layer) |layer| {
        for (layer.origin_keys) |key| {
            try appendConfigReadManagedOrigin(allocator, result, &first, layer, key);
        }
        try appendConfigReadManagedAppsOrigins(allocator, result, &first, layer);
    }
    for (project_layers.items, 0..) |layer, index| {
        for (layer.origin_keys) |key| {
            if (isConfigReadSandboxWorkspaceRootOriginKey(key)) {
                if (if (managed_layer) |managed| managed.hasSandboxWorkspaceWriteRoot() else false) continue;
                if (configReadProjectSliceHasSandboxWorkspaceWriteRoot(project_layers.items[0..index])) continue;
            } else if (isConfigReadToolsAllowedDomainsOriginKey(key)) {
                if (if (managed_layer) |managed| managed.hasToolsAllowedDomains() else false) continue;
                if (configReadProjectSliceHasToolsAllowedDomains(project_layers.items[0..index])) continue;
            } else {
                if (if (managed_layer) |managed| managed.hasOriginKey(key) else false) continue;
                if (configReadProjectSliceHasOriginKey(project_layers.items[0..index], key)) continue;
            }
            try appendConfigReadProjectOrigin(allocator, result, &first, layer, key);
        }
        try appendConfigReadProjectAppsOrigins(allocator, result, &first, managed_layer, project_layers.items[0..index], layer);
    }
    if (user_layer) |layer| {
        for (layer.origin_keys) |key| {
            if (if (managed_layer) |managed| managed.hasOriginKey(key) else false) continue;
            if (project_layers.hasOriginKey(key)) continue;
            try appendConfigReadUserOrigin(allocator, result, &first, layer, key);
        }
        try appendConfigReadUserToolsOrigins(allocator, result, &first, managed_layer, project_layers, layer);
        try appendConfigReadUserAppsOrigins(allocator, result, &first, managed_layer, project_layers, layer);
        try appendConfigReadUserSandboxWorkspaceOrigins(allocator, result, &first, managed_layer, project_layers, layer);
    }
    if (system_layer) |layer| {
        for (layer.origin_keys) |key| {
            if (isConfigReadSandboxWorkspaceRootOriginKey(key)) {
                if (if (managed_layer) |managed| managed.hasSandboxWorkspaceWriteRoot() else false) continue;
                if (project_layers.hasSandboxWorkspaceWriteRoot()) continue;
                if (if (user_layer) |user| user.sandbox_workspace_write.writable_roots != null else false) continue;
            } else if (isConfigReadToolsAllowedDomainsOriginKey(key)) {
                if (if (managed_layer) |managed| managed.hasToolsAllowedDomains() else false) continue;
                if (project_layers.hasToolsAllowedDomains()) continue;
                if (if (user_layer) |user| configReadUserLayerHasToolsAllowedDomains(user) else false) continue;
            } else {
                if (if (managed_layer) |managed| managed.hasOriginKey(key) else false) continue;
                if (project_layers.hasOriginKey(key)) continue;
                if (if (user_layer) |user| configReadUserLayerHasOriginKey(user, key) else false) continue;
            }
            try appendConfigReadSystemOrigin(allocator, result, &first, layer, key);
        }
        try appendConfigReadSystemAppsOrigins(allocator, result, &first, managed_layer, project_layers, user_layer, layer);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadUserToolsOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
) !void {
    if (layer.tools.web_search) |web_search| {
        if (web_search.context_size != null) {
            try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.web_search.context_size");
        }
        if (web_search.allowed_domains) |domains| {
            for (domains.items, 0..) |_, index| {
                const key = try std.fmt.allocPrint(allocator, "tools.web_search.allowed_domains.{d}", .{index});
                defer allocator.free(key);
                try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, key);
            }
        }
        if (web_search.location) |location| {
            if (location.country != null) {
                try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.web_search.location.country");
            }
            if (location.region != null) {
                try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.web_search.location.region");
            }
            if (location.city != null) {
                try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.web_search.location.city");
            }
            if (location.timezone != null) {
                try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.web_search.location.timezone");
            }
        }
    }
    if (layer.tools.view_image != null) {
        try appendConfigReadUserToolOrigin(allocator, result, first, managed_layer, project_layers, layer, "tools.view_image");
    }
}

fn appendConfigReadUserToolOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
    key: []const u8,
) !void {
    if (isConfigReadToolsAllowedDomainsOriginKey(key) and (if (managed_layer) |managed| managed.hasToolsAllowedDomains() else false)) return;
    if (if (managed_layer) |managed| managed.hasOriginKey(key) else false) return;
    if (isConfigReadToolsAllowedDomainsOriginKey(key) and project_layers.hasToolsAllowedDomains()) return;
    if (project_layers.hasOriginKey(key)) return;
    try appendConfigReadUserOrigin(allocator, result, first, layer, key);
}

fn appendConfigReadManagedAppsOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadManagedLayer,
) !void {
    if (layer.apps.default_config) |default_config| {
        if (default_config.enabled_present) {
            try appendConfigReadManagedOrigin(allocator, result, first, layer, "apps._default.enabled");
        }
        if (default_config.destructive_enabled_present) {
            try appendConfigReadManagedOrigin(allocator, result, first, layer, "apps._default.destructive_enabled");
        }
        if (default_config.open_world_enabled_present) {
            try appendConfigReadManagedOrigin(allocator, result, first, layer, "apps._default.open_world_enabled");
        }
    }
    for (layer.apps.items) |app| {
        if (app.has_enabled) {
            try appendConfigReadManagedAppOrigin(allocator, result, first, layer, app.name, "enabled");
        }
        if (app.destructive_enabled != null) {
            try appendConfigReadManagedAppOrigin(allocator, result, first, layer, app.name, "destructive_enabled");
        }
        if (app.open_world_enabled != null) {
            try appendConfigReadManagedAppOrigin(allocator, result, first, layer, app.name, "open_world_enabled");
        }
        if (app.default_tools_approval_mode != null) {
            try appendConfigReadManagedAppOrigin(allocator, result, first, layer, app.name, "default_tools_approval_mode");
        }
        if (app.default_tools_enabled != null) {
            try appendConfigReadManagedAppOrigin(allocator, result, first, layer, app.name, "default_tools_enabled");
        }
        for (app.tools.items) |tool| {
            if (tool.enabled != null) {
                try appendConfigReadManagedAppToolOrigin(allocator, result, first, layer, app.name, tool.name, "enabled");
            }
            if (tool.approval_mode != null) {
                try appendConfigReadManagedAppToolOrigin(allocator, result, first, layer, app.name, tool.name, "approval_mode");
            }
        }
    }
}

fn appendConfigReadManagedAppOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadManagedLayer,
    app_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.{s}", .{ app_name, field });
    defer allocator.free(key);
    try appendConfigReadManagedOrigin(allocator, result, first, layer, key);
}

fn appendConfigReadManagedAppToolOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadManagedLayer,
    app_name: []const u8,
    tool_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.tools.{s}.{s}", .{ app_name, tool_name, field });
    defer allocator.free(key);
    try appendConfigReadManagedOrigin(allocator, result, first, layer, key);
}

fn appendConfigReadUserAppsOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
) !void {
    if (layer.apps.default_config) |default_config| {
        if (default_config.enabled_present) {
            try appendConfigReadUserAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, layer, "apps._default.enabled");
        }
        if (default_config.destructive_enabled_present) {
            try appendConfigReadUserAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, layer, "apps._default.destructive_enabled");
        }
        if (default_config.open_world_enabled_present) {
            try appendConfigReadUserAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, layer, "apps._default.open_world_enabled");
        }
    }
    for (layer.apps.items) |app| {
        if (app.has_enabled) {
            try appendConfigReadUserAppOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, "enabled");
        }
        if (app.destructive_enabled != null) {
            try appendConfigReadUserAppOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, "destructive_enabled");
        }
        if (app.open_world_enabled != null) {
            try appendConfigReadUserAppOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, "open_world_enabled");
        }
        if (app.default_tools_approval_mode != null) {
            try appendConfigReadUserAppOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, "default_tools_approval_mode");
        }
        if (app.default_tools_enabled != null) {
            try appendConfigReadUserAppOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, "default_tools_enabled");
        }
        for (app.tools.items) |tool| {
            if (tool.enabled != null) {
                try appendConfigReadUserAppToolOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, tool.name, "enabled");
            }
            if (tool.approval_mode != null) {
                try appendConfigReadUserAppToolOrigin(allocator, result, first, managed_layer, project_layers, layer, app.name, tool.name, "approval_mode");
            }
        }
    }
}

fn appendConfigReadProjectAppsOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    higher_layers: []const ConfigReadProjectLayer,
    layer: ConfigReadProjectLayer,
) !void {
    if (layer.apps.default_config) |default_config| {
        if (default_config.enabled_present) {
            try appendConfigReadProjectAppOriginIfVisible(allocator, result, first, managed_layer, higher_layers, layer, "apps._default.enabled");
        }
        if (default_config.destructive_enabled_present) {
            try appendConfigReadProjectAppOriginIfVisible(allocator, result, first, managed_layer, higher_layers, layer, "apps._default.destructive_enabled");
        }
        if (default_config.open_world_enabled_present) {
            try appendConfigReadProjectAppOriginIfVisible(allocator, result, first, managed_layer, higher_layers, layer, "apps._default.open_world_enabled");
        }
    }
    for (layer.apps.items) |app| {
        if (app.has_enabled) {
            try appendConfigReadProjectAppOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, "enabled");
        }
        if (app.destructive_enabled != null) {
            try appendConfigReadProjectAppOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, "destructive_enabled");
        }
        if (app.open_world_enabled != null) {
            try appendConfigReadProjectAppOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, "open_world_enabled");
        }
        if (app.default_tools_approval_mode != null) {
            try appendConfigReadProjectAppOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, "default_tools_approval_mode");
        }
        if (app.default_tools_enabled != null) {
            try appendConfigReadProjectAppOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, "default_tools_enabled");
        }
        for (app.tools.items) |tool| {
            if (tool.enabled != null) {
                try appendConfigReadProjectAppToolOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, tool.name, "enabled");
            }
            if (tool.approval_mode != null) {
                try appendConfigReadProjectAppToolOrigin(allocator, result, first, managed_layer, higher_layers, layer, app.name, tool.name, "approval_mode");
            }
        }
    }
}

fn appendConfigReadProjectAppOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    higher_layers: []const ConfigReadProjectLayer,
    layer: ConfigReadProjectLayer,
    app_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.{s}", .{ app_name, field });
    defer allocator.free(key);
    try appendConfigReadProjectAppOriginIfVisible(allocator, result, first, managed_layer, higher_layers, layer, key);
}

fn appendConfigReadProjectAppToolOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    higher_layers: []const ConfigReadProjectLayer,
    layer: ConfigReadProjectLayer,
    app_name: []const u8,
    tool_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.tools.{s}.{s}", .{ app_name, tool_name, field });
    defer allocator.free(key);
    try appendConfigReadProjectAppOriginIfVisible(allocator, result, first, managed_layer, higher_layers, layer, key);
}

fn appendConfigReadProjectAppOriginIfVisible(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    higher_layers: []const ConfigReadProjectLayer,
    layer: ConfigReadProjectLayer,
    key: []const u8,
) !void {
    if (if (managed_layer) |managed| try configReadAppsHasOriginKey(allocator, managed.apps, key) else false) return;
    if (try configReadProjectSliceHasAppsOriginKey(allocator, higher_layers, key)) return;
    try appendConfigReadProjectOrigin(allocator, result, first, layer, key);
}

fn appendConfigReadSystemAppsOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    layer: ConfigReadSystemLayer,
) !void {
    if (layer.apps.default_config) |default_config| {
        if (default_config.enabled_present) {
            try appendConfigReadSystemAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, user_layer, layer, "apps._default.enabled");
        }
        if (default_config.destructive_enabled_present) {
            try appendConfigReadSystemAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, user_layer, layer, "apps._default.destructive_enabled");
        }
        if (default_config.open_world_enabled_present) {
            try appendConfigReadSystemAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, user_layer, layer, "apps._default.open_world_enabled");
        }
    }
    for (layer.apps.items) |app| {
        if (app.has_enabled) {
            try appendConfigReadSystemAppOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, "enabled");
        }
        if (app.destructive_enabled != null) {
            try appendConfigReadSystemAppOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, "destructive_enabled");
        }
        if (app.open_world_enabled != null) {
            try appendConfigReadSystemAppOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, "open_world_enabled");
        }
        if (app.default_tools_approval_mode != null) {
            try appendConfigReadSystemAppOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, "default_tools_approval_mode");
        }
        if (app.default_tools_enabled != null) {
            try appendConfigReadSystemAppOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, "default_tools_enabled");
        }
        for (app.tools.items) |tool| {
            if (tool.enabled != null) {
                try appendConfigReadSystemAppToolOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, tool.name, "enabled");
            }
            if (tool.approval_mode != null) {
                try appendConfigReadSystemAppToolOrigin(allocator, result, first, managed_layer, project_layers, user_layer, layer, app.name, tool.name, "approval_mode");
            }
        }
    }
}

fn appendConfigReadSystemAppOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    layer: ConfigReadSystemLayer,
    app_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.{s}", .{ app_name, field });
    defer allocator.free(key);
    try appendConfigReadSystemAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, user_layer, layer, key);
}

fn appendConfigReadSystemAppToolOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    layer: ConfigReadSystemLayer,
    app_name: []const u8,
    tool_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.tools.{s}.{s}", .{ app_name, tool_name, field });
    defer allocator.free(key);
    try appendConfigReadSystemAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, user_layer, layer, key);
}

fn appendConfigReadSystemAppOriginIfVisible(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    layer: ConfigReadSystemLayer,
    key: []const u8,
) !void {
    if (if (managed_layer) |managed| try configReadAppsHasOriginKey(allocator, managed.apps, key) else false) return;
    if (try configReadProjectSliceHasAppsOriginKey(allocator, project_layers.items, key)) return;
    if (if (user_layer) |user| try configReadAppsHasOriginKey(allocator, user.apps, key) else false) return;
    try appendConfigReadSystemOrigin(allocator, result, first, layer, key);
}

fn appendConfigReadUserAppOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
    app_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.{s}", .{ app_name, field });
    defer allocator.free(key);
    try appendConfigReadUserAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, layer, key);
}

fn appendConfigReadUserAppToolOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
    app_name: []const u8,
    tool_name: []const u8,
    field: []const u8,
) !void {
    const key = try std.fmt.allocPrint(allocator, "apps.{s}.tools.{s}.{s}", .{ app_name, tool_name, field });
    defer allocator.free(key);
    try appendConfigReadUserAppOriginIfVisible(allocator, result, first, managed_layer, project_layers, layer, key);
}

fn appendConfigReadUserAppOriginIfVisible(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
    key: []const u8,
) !void {
    if (if (managed_layer) |managed| try configReadAppsHasOriginKey(allocator, managed.apps, key) else false) return;
    if (try configReadProjectSliceHasAppsOriginKey(allocator, project_layers.items, key)) return;
    try appendConfigReadUserOrigin(allocator, result, first, layer, key);
}

fn configReadProjectSliceHasAppsOriginKey(
    allocator: std.mem.Allocator,
    layers: []const ConfigReadProjectLayer,
    key: []const u8,
) !bool {
    for (layers) |layer| {
        if (try configReadAppsHasOriginKey(allocator, layer.apps, key)) return true;
    }
    return false;
}

fn configReadAppsHasOriginKey(
    allocator: std.mem.Allocator,
    apps: ConfigReadApps,
    key: []const u8,
) !bool {
    if (apps.default_config) |default_config| {
        if (default_config.enabled_present and std.mem.eql(u8, key, "apps._default.enabled")) return true;
        if (default_config.destructive_enabled_present and std.mem.eql(u8, key, "apps._default.destructive_enabled")) return true;
        if (default_config.open_world_enabled_present and std.mem.eql(u8, key, "apps._default.open_world_enabled")) return true;
    }
    for (apps.items) |app| {
        if (app.has_enabled and try configReadAppFieldOriginKeyMatches(allocator, key, app.name, "enabled")) return true;
        if (app.destructive_enabled != null and try configReadAppFieldOriginKeyMatches(allocator, key, app.name, "destructive_enabled")) return true;
        if (app.open_world_enabled != null and try configReadAppFieldOriginKeyMatches(allocator, key, app.name, "open_world_enabled")) return true;
        if (app.default_tools_approval_mode != null and try configReadAppFieldOriginKeyMatches(allocator, key, app.name, "default_tools_approval_mode")) return true;
        if (app.default_tools_enabled != null and try configReadAppFieldOriginKeyMatches(allocator, key, app.name, "default_tools_enabled")) return true;
        for (app.tools.items) |tool| {
            if (tool.enabled != null and try configReadAppToolFieldOriginKeyMatches(allocator, key, app.name, tool.name, "enabled")) return true;
            if (tool.approval_mode != null and try configReadAppToolFieldOriginKeyMatches(allocator, key, app.name, tool.name, "approval_mode")) return true;
        }
    }
    return false;
}

fn configReadAppFieldOriginKeyMatches(
    allocator: std.mem.Allocator,
    key: []const u8,
    app_name: []const u8,
    field: []const u8,
) !bool {
    const candidate = try std.fmt.allocPrint(allocator, "apps.{s}.{s}", .{ app_name, field });
    defer allocator.free(candidate);
    return std.mem.eql(u8, key, candidate);
}

fn configReadAppToolFieldOriginKeyMatches(
    allocator: std.mem.Allocator,
    key: []const u8,
    app_name: []const u8,
    tool_name: []const u8,
    field: []const u8,
) !bool {
    const candidate = try std.fmt.allocPrint(allocator, "apps.{s}.tools.{s}.{s}", .{ app_name, tool_name, field });
    defer allocator.free(candidate);
    return std.mem.eql(u8, key, candidate);
}

fn appendConfigReadUserSandboxWorkspaceOrigins(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    layer: ConfigReadUserLayer,
) !void {
    if (layer.sandbox_workspace_write.writable_roots) |roots| {
        if (!(if (managed_layer) |managed| managed.hasSandboxWorkspaceWriteRoot() else false) and !project_layers.hasSandboxWorkspaceWriteRoot()) {
            for (roots.items, 0..) |_, index| {
                const key = try std.fmt.allocPrint(allocator, "sandbox_workspace_write.writable_roots.{d}", .{index});
                defer allocator.free(key);
                try appendConfigReadUserOrigin(allocator, result, first, layer, key);
            }
        }
    }
    if (layer.sandbox_workspace_write.network_access_present) {
        if (!(if (managed_layer) |managed| managed.hasOriginKey("sandbox_workspace_write.network_access") else false) and !project_layers.hasOriginKey("sandbox_workspace_write.network_access")) {
            try appendConfigReadUserOrigin(allocator, result, first, layer, "sandbox_workspace_write.network_access");
        }
    }
    if (layer.sandbox_workspace_write.exclude_tmpdir_env_var_present) {
        if (!(if (managed_layer) |managed| managed.hasOriginKey("sandbox_workspace_write.exclude_tmpdir_env_var") else false) and !project_layers.hasOriginKey("sandbox_workspace_write.exclude_tmpdir_env_var")) {
            try appendConfigReadUserOrigin(allocator, result, first, layer, "sandbox_workspace_write.exclude_tmpdir_env_var");
        }
    }
    if (layer.sandbox_workspace_write.exclude_slash_tmp_present) {
        if (!(if (managed_layer) |managed| managed.hasOriginKey("sandbox_workspace_write.exclude_slash_tmp") else false) and !project_layers.hasOriginKey("sandbox_workspace_write.exclude_slash_tmp")) {
            try appendConfigReadUserOrigin(allocator, result, first, layer, "sandbox_workspace_write.exclude_slash_tmp");
        }
    }
}

fn configReadProjectSliceHasOriginKey(layers: []const ConfigReadProjectLayer, key: []const u8) bool {
    for (layers) |layer| {
        for (layer.origin_keys) |project_key| {
            if (std.mem.eql(u8, project_key, key)) return true;
        }
    }
    return false;
}

fn configReadUserLayerHasOriginKey(layer: ConfigReadUserLayer, key: []const u8) bool {
    for (layer.origin_keys) |origin_key| {
        if (std.mem.eql(u8, origin_key, key)) return true;
    }
    if (std.mem.eql(u8, key, "sandbox_workspace_write.network_access")) return layer.sandbox_workspace_write.network_access_present;
    if (std.mem.eql(u8, key, "sandbox_workspace_write.exclude_tmpdir_env_var")) return layer.sandbox_workspace_write.exclude_tmpdir_env_var_present;
    if (std.mem.eql(u8, key, "sandbox_workspace_write.exclude_slash_tmp")) return layer.sandbox_workspace_write.exclude_slash_tmp_present;
    return configReadToolsHasOriginKey(layer.tools, key);
}

fn configReadToolsHasOriginKey(tools: ConfigReadTools, key: []const u8) bool {
    if (std.mem.eql(u8, key, "tools.web_search.context_size")) {
        return if (tools.web_search) |web_search| web_search.context_size != null else false;
    }
    if (isConfigReadToolsAllowedDomainsOriginKey(key)) return configReadToolsHasAllowedDomains(tools);
    if (std.mem.eql(u8, key, "tools.web_search.location.country")) {
        return if (tools.web_search) |web_search| if (web_search.location) |location| location.country != null else false else false;
    }
    if (std.mem.eql(u8, key, "tools.web_search.location.region")) {
        return if (tools.web_search) |web_search| if (web_search.location) |location| location.region != null else false else false;
    }
    if (std.mem.eql(u8, key, "tools.web_search.location.city")) {
        return if (tools.web_search) |web_search| if (web_search.location) |location| location.city != null else false else false;
    }
    if (std.mem.eql(u8, key, "tools.web_search.location.timezone")) {
        return if (tools.web_search) |web_search| if (web_search.location) |location| location.timezone != null else false else false;
    }
    if (std.mem.eql(u8, key, "tools.view_image")) return tools.view_image != null;
    return false;
}

fn configReadUserLayerHasToolsAllowedDomains(layer: ConfigReadUserLayer) bool {
    return configReadToolsHasAllowedDomains(layer.tools);
}

fn configReadToolsHasAllowedDomains(tools: ConfigReadTools) bool {
    if (tools.web_search) |web_search| {
        return web_search.allowed_domains != null;
    }
    return false;
}

fn configReadProjectSliceHasSandboxWorkspaceWriteRoot(layers: []const ConfigReadProjectLayer) bool {
    for (layers) |layer| {
        if (layer.sandbox_workspace_write.writable_roots != null) return true;
    }
    return false;
}

fn configReadProjectSliceHasToolsAllowedDomains(layers: []const ConfigReadProjectLayer) bool {
    for (layers) |layer| {
        if (layer.tools.web_search) |web_search| {
            if (web_search.allowed_domains != null) return true;
        }
    }
    return false;
}

fn isConfigReadSandboxWorkspaceRootOriginKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "sandbox_workspace_write.writable_roots.");
}

fn isConfigReadToolsAllowedDomainsOriginKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "tools.web_search.allowed_domains.");
}

fn appendConfigReadManagedOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadManagedLayer,
    key: []const u8,
) !void {
    try appendConfigReadOriginName(allocator, result, first, key);
    try appendConfigReadManagedSource(allocator, result, layer.file_path);
    try appendConfigReadOriginVersion(allocator, result, layer.version);
}

fn appendConfigReadProjectOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadProjectLayer,
    key: []const u8,
) !void {
    try appendConfigReadOriginName(allocator, result, first, key);
    try appendConfigReadProjectSource(allocator, result, layer.dot_codex_folder);
    try appendConfigReadOriginVersion(allocator, result, layer.version);
}

fn appendConfigReadSystemOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadSystemLayer,
    key: []const u8,
) !void {
    try appendConfigReadOriginName(allocator, result, first, key);
    try appendConfigReadSystemSource(allocator, result, layer.file_path);
    try appendConfigReadOriginVersion(allocator, result, layer.version);
}

fn appendConfigReadUserOrigin(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadUserLayer,
    key: []const u8,
) !void {
    try appendConfigReadOriginName(allocator, result, first, key);
    try appendConfigReadUserSource(allocator, result, layer.file_path);
    try appendConfigReadOriginVersion(allocator, result, layer.version);
}

fn appendConfigReadOriginName(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try result.append(allocator, ',');
    }
    const key_json = try std.json.Stringify.valueAlloc(allocator, key, .{});
    defer allocator.free(key_json);
    try result.appendSlice(allocator, key_json);
    try result.appendSlice(allocator, ":{\"name\":");
}

fn appendConfigReadOriginVersion(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    version: []const u8,
) !void {
    try result.appendSlice(allocator, ",\"version\":");
    const version_json = try std.json.Stringify.valueAlloc(allocator, version, .{});
    defer allocator.free(version_json);
    try result.appendSlice(allocator, version_json);
    try result.append(allocator, '}');
}

fn appendConfigReadLayers(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    cfg: config.Config,
    include_layers: bool,
    managed_layer: ?ConfigReadManagedLayer,
    project_layers: ConfigReadProjectLayers,
    user_layer: ?ConfigReadUserLayer,
    system_layer: ?ConfigReadSystemLayer,
) !void {
    if (!include_layers) {
        try result.appendSlice(allocator, "null");
        return;
    }

    try result.append(allocator, '[');
    var first = true;
    if (managed_layer) |layer| {
        try appendConfigReadManagedLayer(allocator, result, &first, layer);
    }
    for (project_layers.items) |layer| {
        try appendConfigReadProjectLayer(allocator, result, &first, layer);
    }
    if (user_layer) |layer| {
        try appendConfigReadUserLayer(allocator, result, &first, cfg, layer);
    }
    if (system_layer) |layer| {
        try appendConfigReadSystemLayer(allocator, result, &first, layer);
    }
    try result.append(allocator, ']');
}

fn appendConfigReadManagedLayer(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadManagedLayer,
) !void {
    try appendConfigReadLayerStart(allocator, result, first);
    try appendConfigReadManagedSource(allocator, result, layer.file_path);
    try result.appendSlice(allocator, ",\"version\":");
    const version_json = try std.json.Stringify.valueAlloc(allocator, layer.version, .{});
    defer allocator.free(version_json);
    try result.appendSlice(allocator, version_json);
    try result.appendSlice(allocator, ",\"config\":");
    try appendConfigReadManagedLayerConfig(allocator, result, layer);
    try result.append(allocator, '}');
}

fn appendConfigReadProjectLayer(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadProjectLayer,
) !void {
    try appendConfigReadLayerStart(allocator, result, first);
    try appendConfigReadProjectSource(allocator, result, layer.dot_codex_folder);
    try result.appendSlice(allocator, ",\"version\":");
    const version_json = try std.json.Stringify.valueAlloc(allocator, layer.version, .{});
    defer allocator.free(version_json);
    try result.appendSlice(allocator, version_json);
    try result.appendSlice(allocator, ",\"config\":");
    try appendConfigReadProjectLayerConfig(allocator, result, layer);
    try result.append(allocator, '}');
}

fn appendConfigReadUserLayer(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    cfg: config.Config,
    layer: ConfigReadUserLayer,
) !void {
    try appendConfigReadLayerStart(allocator, result, first);
    try appendConfigReadUserSource(allocator, result, layer.file_path);
    try result.appendSlice(allocator, ",\"version\":");
    const version_json = try std.json.Stringify.valueAlloc(allocator, layer.version, .{});
    defer allocator.free(version_json);
    try result.appendSlice(allocator, version_json);
    try result.appendSlice(allocator, ",\"config\":");
    try appendConfigReadUserLayerConfig(allocator, result, cfg, layer);
    try result.append(allocator, '}');
}

fn appendConfigReadSystemLayer(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    layer: ConfigReadSystemLayer,
) !void {
    try appendConfigReadLayerStart(allocator, result, first);
    try appendConfigReadSystemSource(allocator, result, layer.file_path);
    try result.appendSlice(allocator, ",\"version\":");
    const version_json = try std.json.Stringify.valueAlloc(allocator, layer.version, .{});
    defer allocator.free(version_json);
    try result.appendSlice(allocator, version_json);
    try result.appendSlice(allocator, ",\"config\":");
    try appendConfigReadSystemLayerConfig(allocator, result, layer);
    try result.append(allocator, '}');
}

fn appendConfigReadLayerStart(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try result.append(allocator, ',');
    }
    try result.appendSlice(allocator, "{\"name\":");
}

fn appendConfigReadProjectSource(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    dot_codex_folder: []const u8,
) !void {
    const folder_json = try std.json.Stringify.valueAlloc(allocator, dot_codex_folder, .{});
    defer allocator.free(folder_json);
    try result.appendSlice(allocator, "{\"type\":\"project\",\"dotCodexFolder\":");
    try result.appendSlice(allocator, folder_json);
    try result.append(allocator, '}');
}

fn appendConfigReadUserSource(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    file_path: []const u8,
) !void {
    const file_json = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(file_json);
    try result.appendSlice(allocator, "{\"type\":\"user\",\"file\":");
    try result.appendSlice(allocator, file_json);
    try result.append(allocator, '}');
}

fn appendConfigReadSystemSource(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    file_path: []const u8,
) !void {
    const file_json = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(file_json);
    try result.appendSlice(allocator, "{\"type\":\"system\",\"file\":");
    try result.appendSlice(allocator, file_json);
    try result.append(allocator, '}');
}

fn appendConfigReadManagedSource(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    file_path: []const u8,
) !void {
    const file_json = try std.json.Stringify.valueAlloc(allocator, file_path, .{});
    defer allocator.free(file_json);
    try result.appendSlice(allocator, "{\"type\":\"legacyManagedConfigTomlFromFile\",\"file\":");
    try result.appendSlice(allocator, file_json);
    try result.append(allocator, '}');
}

fn appendConfigReadProjectLayerConfig(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    layer: ConfigReadProjectLayer,
) !void {
    try result.append(allocator, '{');
    var first = true;
    for (layer.origin_keys) |key| {
        if (std.mem.eql(u8, key, "model")) {
            if (layer.model) |value| try appendJsonStringField(allocator, result, &first, key, value);
        } else if (std.mem.eql(u8, key, "approval_policy")) {
            if (layer.approval_policy) |policy| try appendJsonStringField(allocator, result, &first, key, policy.label());
        } else if (std.mem.eql(u8, key, "sandbox_mode")) {
            if (layer.sandbox_mode) |mode| try appendJsonStringField(allocator, result, &first, key, mode.label());
        } else if (std.mem.eql(u8, key, "web_search")) {
            if (layer.web_search_mode) |mode| try appendJsonStringField(allocator, result, &first, key, mode.label());
        } else if (std.mem.eql(u8, key, "model_reasoning_effort")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, if (layer.model_reasoning_effort) |effort| effort.label() else null);
        } else if (std.mem.eql(u8, key, "service_tier")) {
            if (layer.service_tier) |value| try appendJsonStringField(allocator, result, &first, key, value);
        }
    }
    if (layer.sandbox_workspace_write.present) {
        try appendJsonFieldName(allocator, result, &first, "sandbox_workspace_write");
        try appendConfigReadSandboxWorkspaceWriteObject(allocator, result, layer.sandbox_workspace_write);
    }
    if (layer.tools.present) {
        try appendJsonFieldName(allocator, result, &first, "tools");
        try appendConfigReadToolsObject(allocator, result, layer.tools);
    }
    if (!layer.apps.isEmpty()) {
        try appendJsonFieldName(allocator, result, &first, "apps");
        try appendConfigReadAppsObject(allocator, result, layer.apps);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadManagedLayerConfig(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    layer: ConfigReadManagedLayer,
) !void {
    try result.append(allocator, '{');
    var first = true;
    if (layer.model) |value| try appendJsonStringField(allocator, result, &first, "model", value);
    if (layer.approval_policy) |policy| try appendJsonStringField(allocator, result, &first, "approval_policy", policy.label());
    if (layer.sandbox_mode) |mode| try appendJsonStringField(allocator, result, &first, "sandbox_mode", mode.label());
    if (layer.web_search_mode) |mode| try appendJsonStringField(allocator, result, &first, "web_search", mode.label());
    if (layer.model_reasoning_effort) |effort| try appendJsonStringField(allocator, result, &first, "model_reasoning_effort", effort.label());
    if (layer.service_tier) |value| try appendJsonStringField(allocator, result, &first, "service_tier", value);
    if (layer.sandbox_workspace_write.present) {
        try appendJsonFieldName(allocator, result, &first, "sandbox_workspace_write");
        try appendConfigReadSandboxWorkspaceWriteObject(allocator, result, layer.sandbox_workspace_write);
    }
    if (layer.tools.present) {
        try appendJsonFieldName(allocator, result, &first, "tools");
        try appendConfigReadToolsObject(allocator, result, layer.tools);
    }
    if (!layer.apps.isEmpty()) {
        try appendJsonFieldName(allocator, result, &first, "apps");
        try appendConfigReadAppsObject(allocator, result, layer.apps);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadSystemLayerConfig(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    layer: ConfigReadSystemLayer,
) !void {
    try result.append(allocator, '{');
    var first = true;
    for (layer.origin_keys) |key| {
        if (std.mem.eql(u8, key, "model")) {
            if (layer.model) |value| try appendJsonStringField(allocator, result, &first, key, value);
        } else if (std.mem.eql(u8, key, "approval_policy")) {
            if (layer.approval_policy) |policy| try appendJsonStringField(allocator, result, &first, key, policy.label());
        } else if (std.mem.eql(u8, key, "sandbox_mode")) {
            if (layer.sandbox_mode) |mode| try appendJsonStringField(allocator, result, &first, key, mode.label());
        } else if (std.mem.eql(u8, key, "web_search")) {
            if (layer.web_search_mode) |mode| try appendJsonStringField(allocator, result, &first, key, mode.label());
        } else if (std.mem.eql(u8, key, "model_reasoning_effort")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, if (layer.model_reasoning_effort) |effort| effort.label() else null);
        } else if (std.mem.eql(u8, key, "service_tier")) {
            if (layer.service_tier) |value| try appendJsonStringField(allocator, result, &first, key, value);
        }
    }
    if (layer.sandbox_workspace_write.present) {
        try appendJsonFieldName(allocator, result, &first, "sandbox_workspace_write");
        try appendConfigReadSandboxWorkspaceWriteObject(allocator, result, layer.sandbox_workspace_write);
    }
    if (layer.tools.present) {
        try appendJsonFieldName(allocator, result, &first, "tools");
        try appendConfigReadToolsObject(allocator, result, layer.tools);
    }
    if (!layer.apps.isEmpty()) {
        try appendJsonFieldName(allocator, result, &first, "apps");
        try appendConfigReadAppsObject(allocator, result, layer.apps);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadUserLayerConfig(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    cfg: config.Config,
    layer: ConfigReadUserLayer,
) !void {
    try result.append(allocator, '{');
    var first = true;
    for (layer.origin_keys) |key| {
        if (std.mem.eql(u8, key, "model")) {
            try appendJsonStringField(allocator, result, &first, key, cfg.model);
        } else if (std.mem.eql(u8, key, "profile")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, cfg.active_profile);
        } else if (std.mem.eql(u8, key, "approval_policy")) {
            try appendJsonStringField(allocator, result, &first, key, cfg.approval_policy.label());
        } else if (std.mem.eql(u8, key, "sandbox_mode")) {
            try appendJsonStringField(allocator, result, &first, key, cfg.sandbox_mode.label());
        } else if (std.mem.eql(u8, key, "web_search")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, if (cfg.web_search_mode) |mode| mode.label() else null);
        } else if (std.mem.eql(u8, key, "model_reasoning_effort")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, if (cfg.model_reasoning_effort) |effort| effort.label() else null);
        } else if (std.mem.eql(u8, key, "service_tier")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, cfg.service_tier);
        } else if (std.mem.eql(u8, key, "oss_provider")) {
            try appendJsonMaybeStringField(allocator, result, &first, key, cfg.oss_provider);
        } else if (std.mem.eql(u8, key, "openai_base_url")) {
            try appendJsonStringField(allocator, result, &first, key, cfg.openai_base_url);
        } else if (std.mem.eql(u8, key, "chatgpt_base_url")) {
            try appendJsonStringField(allocator, result, &first, key, cfg.chatgpt_base_url);
        }
    }
    if (layer.tools.present) {
        try appendJsonFieldName(allocator, result, &first, "tools");
        try appendConfigReadToolsObject(allocator, result, layer.tools);
    }
    if (!layer.apps.isEmpty()) {
        try appendJsonFieldName(allocator, result, &first, "apps");
        try appendConfigReadAppsObject(allocator, result, layer.apps);
    }
    if (layer.sandbox_workspace_write.present) {
        try appendJsonFieldName(allocator, result, &first, "sandbox_workspace_write");
        try appendConfigReadSandboxWorkspaceWriteObject(allocator, result, layer.sandbox_workspace_write);
    }
    try result.append(allocator, '}');
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

fn appendJsonMaybeBoolField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: ?bool,
) !void {
    try appendJsonFieldName(allocator, result, first, name);
    if (value) |boolean| {
        try result.appendSlice(allocator, if (boolean) "true" else "false");
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn appendJsonBoolField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: bool,
) !void {
    try appendJsonFieldName(allocator, result, first, name);
    try result.appendSlice(allocator, if (value) "true" else "false");
}

fn appendConfigReadToolsField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    tools: ?ConfigReadTools,
) !void {
    try appendJsonFieldName(allocator, result, first, "tools");
    if (tools) |value| {
        if (!value.present) {
            try result.appendSlice(allocator, "null");
            return;
        }
        try appendConfigReadToolsObject(allocator, result, value);
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn appendConfigReadToolsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    tools: ConfigReadTools,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonFieldName(allocator, result, &first, "web_search");
    if (tools.web_search) |web_search| {
        try appendConfigReadWebSearchTool(allocator, result, web_search);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try appendJsonMaybeBoolField(allocator, result, &first, "view_image", tools.view_image);
    try result.append(allocator, '}');
}

fn appendConfigReadWebSearchTool(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    web_search: ConfigReadWebSearchTool,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonMaybeStringField(allocator, result, &first, "context_size", web_search.context_size);
    try appendJsonFieldName(allocator, result, &first, "allowed_domains");
    if (web_search.allowed_domains) |domains| {
        try appendJsonStringArray(allocator, result, domains.items);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try appendJsonFieldName(allocator, result, &first, "location");
    if (web_search.location) |location| {
        try appendConfigReadWebSearchLocation(allocator, result, location);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.append(allocator, '}');
}

fn appendConfigReadWebSearchLocation(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    location: ConfigReadWebSearchLocation,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonMaybeStringField(allocator, result, &first, "country", location.country);
    try appendJsonMaybeStringField(allocator, result, &first, "region", location.region);
    try appendJsonMaybeStringField(allocator, result, &first, "city", location.city);
    try appendJsonMaybeStringField(allocator, result, &first, "timezone", location.timezone);
    try result.append(allocator, '}');
}

fn appendConfigReadAppsField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    apps: ?ConfigReadApps,
) !void {
    try appendJsonFieldName(allocator, result, first, "apps");
    if (apps) |value| {
        if (value.isEmpty()) {
            try result.appendSlice(allocator, "null");
            return;
        }
        try appendConfigReadAppsObject(allocator, result, value);
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn appendConfigReadAppsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    apps: ConfigReadApps,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonFieldName(allocator, result, &first, "_default");
    if (apps.default_config) |default_config| {
        try appendConfigReadAppsDefaultObject(allocator, result, default_config);
    } else {
        try result.appendSlice(allocator, "null");
    }
    for (apps.items) |app| {
        try appendJsonFieldName(allocator, result, &first, app.name);
        try appendConfigReadAppObject(allocator, result, app);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadAppsDefaultObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    default_config: ConfigReadAppsDefault,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonBoolField(allocator, result, &first, "enabled", default_config.enabled);
    try appendJsonBoolField(allocator, result, &first, "destructive_enabled", default_config.destructive_enabled);
    try appendJsonBoolField(allocator, result, &first, "open_world_enabled", default_config.open_world_enabled);
    try result.append(allocator, '}');
}

fn appendConfigReadSandboxWorkspaceWriteField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    sandbox: ?ConfigReadSandboxWorkspaceWrite,
) !void {
    try appendJsonFieldName(allocator, result, first, "sandbox_workspace_write");
    if (sandbox) |value| {
        if (!value.present) {
            try result.appendSlice(allocator, "null");
            return;
        }
        try appendConfigReadSandboxWorkspaceWriteObject(allocator, result, value);
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn appendConfigReadSandboxWorkspaceWriteObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    sandbox: ConfigReadSandboxWorkspaceWrite,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonFieldName(allocator, result, &first, "writable_roots");
    if (sandbox.writable_roots) |roots| {
        try appendJsonStringArray(allocator, result, roots.items);
    } else {
        try result.appendSlice(allocator, "[]");
    }
    try appendJsonBoolField(allocator, result, &first, "network_access", sandbox.network_access);
    try appendJsonBoolField(allocator, result, &first, "exclude_tmpdir_env_var", sandbox.exclude_tmpdir_env_var);
    try appendJsonBoolField(allocator, result, &first, "exclude_slash_tmp", sandbox.exclude_slash_tmp);
    try result.append(allocator, '}');
}

fn appendConfigReadAppObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    app: ConfigReadApp,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonBoolField(allocator, result, &first, "enabled", app.enabled);
    try appendJsonMaybeBoolField(allocator, result, &first, "destructive_enabled", app.destructive_enabled);
    try appendJsonMaybeBoolField(allocator, result, &first, "open_world_enabled", app.open_world_enabled);
    try appendJsonMaybeStringField(allocator, result, &first, "default_tools_approval_mode", app.default_tools_approval_mode);
    try appendJsonMaybeBoolField(allocator, result, &first, "default_tools_enabled", app.default_tools_enabled);
    try appendJsonFieldName(allocator, result, &first, "tools");
    if (app.tools.items.len > 0) {
        try appendConfigReadAppToolsObject(allocator, result, app.tools.items);
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.append(allocator, '}');
}

fn appendConfigReadAppToolsObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    tools: []const ConfigReadAppTool,
) !void {
    try result.append(allocator, '{');
    var first = true;
    for (tools) |tool| {
        try appendJsonFieldName(allocator, result, &first, tool.name);
        try appendConfigReadAppToolObject(allocator, result, tool);
    }
    try result.append(allocator, '}');
}

fn appendConfigReadAppToolObject(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    tool: ConfigReadAppTool,
) !void {
    try result.append(allocator, '{');
    var first = true;
    try appendJsonMaybeBoolField(allocator, result, &first, "enabled", tool.enabled);
    try appendJsonMaybeStringField(allocator, result, &first, "approval_mode", tool.approval_mode);
    try result.append(allocator, '}');
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
    if (std.mem.eql(u8, login_type, "apiKey")) {
        return handleAccountLoginStartApiKey(allocator, id_value, object);
    }
    if (std.mem.eql(u8, login_type, "chatgptAuthTokens")) {
        return handleAccountLoginStartChatGptAuthTokens(allocator, id_value, object);
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "account/login/start type {s} is parsed but not implemented yet",
        .{login_type},
    );
    defer allocator.free(message);
    return renderJsonRpcError(allocator, id_value, -32603, message);
}

fn handleAccountLoginStartApiKey(allocator: std.mem.Allocator, id_value: std.json.Value, object: std.json.ObjectMap) ![]const u8 {
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
    return renderResultWithLoginNotifications(allocator, response, "apikey", null);
}

fn handleAccountLoginStartChatGptAuthTokens(allocator: std.mem.Allocator, id_value: std.json.Value, object: std.json.ObjectMap) ![]const u8 {
    const access_token_value = object.get("accessToken") orelse return renderJsonRpcError(allocator, id_value, -32602, "accessToken must be a non-empty string");
    if (access_token_value != .string or access_token_value.string.len == 0) {
        return renderJsonRpcError(allocator, id_value, -32602, "accessToken must be a non-empty string");
    }

    const account_id_value = object.get("chatgptAccountId") orelse return renderJsonRpcError(allocator, id_value, -32602, "chatgptAccountId must be a non-empty string");
    if (account_id_value != .string or account_id_value.string.len == 0) {
        return renderJsonRpcError(allocator, id_value, -32602, "chatgptAccountId must be a non-empty string");
    }

    const plan_type = blk: {
        const value = object.get("chatgptPlanType") orelse break :blk null;
        if (value == .null) break :blk null;
        if (value != .string) return renderJsonRpcError(allocator, id_value, -32602, "chatgptPlanType must be a string or null");
        break :blk value.string;
    };

    var cfg = config.loadWithOptions(allocator, .{}) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/login/start failed to load config", err);
    };
    defer cfg.deinit(allocator);

    auth_mod.saveChatGptAuthTokensJson(allocator, cfg.codex_home, access_token_value.string, account_id_value.string) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "account/login/start failed to save ChatGPT auth tokens", err);
    };

    const response = try renderJsonRpcResult(allocator, id_value, "{\"type\":\"chatgptAuthTokens\"}");
    defer allocator.free(response);
    return renderResultWithLoginNotifications(allocator, response, "chatgptAuthTokens", plan_type);
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
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
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
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {},
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
        .api_key, .chatgpt, .chatgpt_auth_tokens => if (credentials.token.len == 0)
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
        .chatgpt_auth_tokens => "chatgptAuthTokens",
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
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => {
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

fn renderResultWithLoginNotifications(
    allocator: std.mem.Allocator,
    response: []const u8,
    auth_mode: []const u8,
    plan_type: ?[]const u8,
) ![]const u8 {
    const auth_mode_json = try std.json.Stringify.valueAlloc(allocator, auth_mode, .{});
    defer allocator.free(auth_mode_json);
    const plan_type_json = if (plan_type) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(plan_type_json);

    return std.fmt.allocPrint(
        allocator,
        "{s}\n{{\"method\":\"account/login/completed\",\"params\":{{\"loginId\":null,\"success\":true,\"error\":null}}}}\n{{\"method\":\"account/updated\",\"params\":{{\"authMode\":{s},\"planType\":{s}}}}}",
        .{ response, auth_mode_json, plan_type_json },
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
    var include_hidden = false;
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
        include_hidden = switch (optionalBoolFieldValue(object, "includeHidden", false, true)) {
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

    const total = modelListTotal(include_hidden);
    if (start > total) {
        const message = try std.fmt.allocPrint(allocator, "cursor {d} exceeds total models {d}", .{ start, total });
        defer allocator.free(message);
        return renderJsonRpcError(allocator, id_value, -32600, message);
    }

    const effective_limit = @min(@max(limit orelse total, 1), total);
    const end = @min(start + effective_limit, total);

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"data\":[");
    var visible_index: usize = 0;
    var emitted = false;
    const default_slug = model_catalog.defaultModel().slug;
    for (model_catalog.bundled_models) |model| {
        if (!include_hidden and model.hidden()) continue;
        if (visible_index >= start and visible_index < end) {
            if (emitted) try result.appendSlice(allocator, ",");
            try appendAppServerModelJson(allocator, &result, model, std.mem.eql(u8, model.slug, default_slug));
            emitted = true;
        }
        visible_index += 1;
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

fn modelListTotal(include_hidden: bool) usize {
    var total: usize = 0;
    for (model_catalog.bundled_models) |model| {
        if (include_hidden or !model.hidden()) total += 1;
    }
    return total;
}

fn appendAppServerModelJson(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    model: model_catalog.Entry,
    is_default: bool,
) !void {
    try result.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, result, model.slug);
    try result.appendSlice(allocator, ",\"model\":");
    try appendJsonString(allocator, result, model.slug);
    try result.appendSlice(allocator, ",\"upgrade\":");
    if (model.upgrade) |upgrade| try appendJsonString(allocator, result, upgrade.model) else try result.appendSlice(allocator, "null");
    try result.appendSlice(allocator, ",\"upgradeInfo\":");
    if (model.upgrade) |upgrade| {
        try result.appendSlice(allocator, "{\"model\":");
        try appendJsonString(allocator, result, upgrade.model);
        try result.appendSlice(allocator, ",\"upgradeCopy\":");
        try appendOptionalJsonString(allocator, result, upgrade.upgrade_copy);
        try result.appendSlice(allocator, ",\"modelLink\":");
        try appendOptionalJsonString(allocator, result, upgrade.model_link);
        try result.appendSlice(allocator, ",\"migrationMarkdown\":");
        try appendOptionalJsonString(allocator, result, upgrade.migration_markdown);
        try result.appendSlice(allocator, "}");
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, ",\"availabilityNux\":");
    if (model.availability_nux) |nux| {
        try result.appendSlice(allocator, "{\"message\":");
        try appendJsonString(allocator, result, nux.message);
        try result.appendSlice(allocator, "}");
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, ",\"displayName\":");
    try appendJsonString(allocator, result, model.display_name);
    try result.appendSlice(allocator, ",\"description\":");
    try appendJsonString(allocator, result, model.description);
    try result.appendSlice(allocator, ",\"hidden\":");
    try result.appendSlice(allocator, if (model.hidden()) "true" else "false");
    try result.appendSlice(allocator, ",\"supportedReasoningEfforts\":[");
    for (model.supported_reasoning_levels, 0..) |reasoning, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try result.appendSlice(allocator, "{\"reasoningEffort\":");
        try appendJsonString(allocator, result, reasoning.effort);
        try result.appendSlice(allocator, ",\"description\":");
        try appendJsonString(allocator, result, reasoning.description);
        try result.appendSlice(allocator, "}");
    }
    try result.appendSlice(allocator, "],\"defaultReasoningEffort\":");
    try appendJsonString(allocator, result, model.default_reasoning_level);
    try result.appendSlice(allocator, ",\"inputModalities\":");
    try appendJsonStringArray(allocator, result, model.input_modalities);
    try result.appendSlice(allocator, ",\"supportsPersonality\":");
    try result.appendSlice(allocator, if (model.supports_personality) "true" else "false");
    try result.appendSlice(allocator, ",\"additionalSpeedTiers\":");
    try appendJsonStringArray(allocator, result, model.additional_speed_tiers);
    try result.appendSlice(allocator, ",\"serviceTiers\":[");
    for (model.service_tiers, 0..) |tier, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try result.appendSlice(allocator, "{\"id\":");
        try appendJsonString(allocator, result, tier.id);
        try result.appendSlice(allocator, ",\"name\":");
        try appendJsonString(allocator, result, tier.name);
        try result.appendSlice(allocator, ",\"description\":");
        try appendJsonString(allocator, result, tier.description);
        try result.appendSlice(allocator, "}");
    }
    try result.appendSlice(allocator, "],\"isDefault\":");
    try result.appendSlice(allocator, if (is_default) "true" else "false");
    try result.appendSlice(allocator, "}");
}

fn appendJsonString(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: []const u8) !void {
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    try result.appendSlice(allocator, value_json);
}

fn appendOptionalJsonString(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |payload| {
        try appendJsonString(allocator, result, payload);
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn appendJsonStringArray(allocator: std.mem.Allocator, result: *std.ArrayList(u8), values: []const []const u8) !void {
    try result.appendSlice(allocator, "[");
    for (values, 0..) |value, index| {
        if (index > 0) try result.appendSlice(allocator, ",");
        try appendJsonString(allocator, result, value);
    }
    try result.appendSlice(allocator, "]");
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

fn isCollaborationModeMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "collaborationMode/list");
}

fn handleCollaborationModeMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "collaborationMode/list")) {
        return handleCollaborationModeList(allocator, id_value, params_value);
    }
    return renderJsonRpcError(allocator, id_value, -32601, "unknown collaboration mode method");
}

fn handleCollaborationModeList(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (validateOptionalObjectParams(params_value)) |message| {
        return renderJsonRpcError(allocator, id_value, -32602, message);
    }

    const result =
        \\{"data":[{"name":"Plan","mode":"plan","model":null,"reasoning_effort":"medium"},{"name":"Default","mode":"default","model":null,"reasoning_effort":null}]}
    ;
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
    var feature_overrides = features_cmd.loadFeatureOverridesForProfile(allocator, cfg.codex_home, cfg.active_profile) catch |err| {
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

const McpStatusParams = struct {
    cursor: ?usize = null,
    limit: ?usize = null,
};

fn isMcpServerMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "config/mcpServer/reload") or
        std.mem.eql(u8, method, "mcpServerStatus/list");
}

fn handleMcpServerMethod(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    method: []const u8,
    params_value: ?std.json.Value,
) ![]const u8 {
    if (std.mem.eql(u8, method, "config/mcpServer/reload")) {
        if (params_value) |params| {
            if (params != .null and params != .object) {
                return renderJsonRpcError(allocator, id_value, -32602, "config/mcpServer/reload params must be an object, null, or omitted");
            }
        }
        return renderJsonRpcResult(allocator, id_value, "{}");
    }
    if (std.mem.eql(u8, method, "mcpServerStatus/list")) {
        return handleMcpServerStatusList(allocator, id_value, params_value);
    }
    return renderJsonRpcError(allocator, id_value, -32601, "unknown MCP server method");
}

fn handleMcpServerStatusList(allocator: std.mem.Allocator, id_value: std.json.Value, params_value: ?std.json.Value) ![]const u8 {
    const params = parseMcpStatusParams(params_value) catch |err| switch (err) {
        error.InvalidMcpStatusParams => return renderJsonRpcError(allocator, id_value, -32602, "mcpServerStatus/list params must be an object"),
        error.InvalidMcpStatusCursor => return renderJsonRpcError(allocator, id_value, -32602, "invalid cursor"),
        error.InvalidMcpStatusLimit => return renderJsonRpcError(allocator, id_value, -32602, "limit must be a non-negative integer or null"),
        error.InvalidMcpStatusDetail => return renderJsonRpcError(allocator, id_value, -32602, "detail must be full, toolsAndAuthOnly, or null"),
    };

    const codex_home = resolveCodexHome(allocator) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "mcpServerStatus/list failed to resolve CODEX_HOME", err);
    };
    defer allocator.free(codex_home);

    var servers = mcp_cmd.loadServers(allocator, codex_home) catch |err| {
        return renderJsonRpcErrorForFailure(allocator, id_value, "mcpServerStatus/list failed to load MCP servers", err);
    };
    defer servers.deinit(allocator);
    std.mem.sort(mcp_cmd.McpServer, servers.items.items, {}, mcpServerNameLessThan);

    const result = renderMcpServerStatusListResponse(allocator, servers, params) catch |err| switch (err) {
        error.McpStatusCursorOutOfRange => return renderJsonRpcError(allocator, id_value, -32602, "cursor exceeds total MCP servers"),
        else => return err,
    };
    defer allocator.free(result);
    return renderJsonRpcResult(allocator, id_value, result);
}

fn mcpServerNameLessThan(_: void, lhs: mcp_cmd.McpServer, rhs: mcp_cmd.McpServer) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn parseMcpStatusParams(params_value: ?std.json.Value) !McpStatusParams {
    const params = params_value orelse return .{};
    if (params == .null) return .{};
    if (params != .object) return error.InvalidMcpStatusParams;

    var parsed = McpStatusParams{};
    if (params.object.get("cursor")) |cursor| {
        if (cursor == .null) {
            parsed.cursor = null;
        } else if (cursor == .string) {
            parsed.cursor = std.fmt.parseUnsigned(usize, cursor.string, 10) catch return error.InvalidMcpStatusCursor;
        } else {
            return error.InvalidMcpStatusCursor;
        }
    }
    if (params.object.get("limit")) |limit| {
        if (limit == .null) {
            parsed.limit = null;
        } else if (limit == .integer and limit.integer >= 0) {
            parsed.limit = @intCast(limit.integer);
        } else {
            return error.InvalidMcpStatusLimit;
        }
    }
    if (params.object.get("detail")) |detail| {
        if (detail == .null) {
            return parsed;
        }
        if (detail != .string) return error.InvalidMcpStatusDetail;
        if (!std.mem.eql(u8, detail.string, "full") and !std.mem.eql(u8, detail.string, "toolsAndAuthOnly")) {
            return error.InvalidMcpStatusDetail;
        }
    }
    return parsed;
}

fn renderMcpServerStatusListResponse(
    allocator: std.mem.Allocator,
    servers: mcp_cmd.McpServers,
    params: McpStatusParams,
) ![]const u8 {
    const total = servers.items.items.len;
    const start = params.cursor orelse 0;
    if (start > total) return error.McpStatusCursorOutOfRange;
    const limit = @max(params.limit orelse total, 1);
    const effective_limit = @min(limit, total);
    const remaining = total - start;
    const end = start + @min(effective_limit, remaining);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"data\":[");
    for (servers.items.items[start..end], 0..) |server, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendMcpServerStatusJson(allocator, &out, server);
    }
    try out.appendSlice(allocator, "],\"nextCursor\":");
    if (end < total) {
        const next_cursor = try std.fmt.allocPrint(allocator, "{d}", .{end});
        defer allocator.free(next_cursor);
        const next_cursor_json = try std.json.Stringify.valueAlloc(allocator, next_cursor, .{});
        defer allocator.free(next_cursor_json);
        try out.appendSlice(allocator, next_cursor_json);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

fn appendMcpServerStatusJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), server: mcp_cmd.McpServer) !void {
    const name_json = try std.json.Stringify.valueAlloc(allocator, server.name, .{});
    defer allocator.free(name_json);
    const auth_status = try mcpAuthStatus(allocator, server);
    defer allocator.free(auth_status);
    const auth_status_json = try std.json.Stringify.valueAlloc(allocator, auth_status, .{});
    defer allocator.free(auth_status_json);

    try out.appendSlice(allocator, "{\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"tools\":{},\"resources\":[],\"resourceTemplates\":[],\"authStatus\":");
    try out.appendSlice(allocator, auth_status_json);
    try out.appendSlice(allocator, "}");
}

fn mcpAuthStatus(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) ![]const u8 {
    if (server.kind == .streamable_http and server.bearer_token_env_var != null) {
        if (try envVarIsSet(allocator, server.bearer_token_env_var.?)) {
            return allocator.dupe(u8, "bearerToken");
        }
        return allocator.dupe(u8, "notLoggedIn");
    }
    return allocator.dupe(u8, "unsupported");
}

fn envVarIsSet(allocator: std.mem.Allocator, name: []const u8) !bool {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    return std.c.getenv(name_z.ptr) != null;
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

fn writePreResponseNotificationsStdout(allocator: std.mem.Allocator, state: *AppServerState) !void {
    var notifications = state.pre_response_notifications;
    state.pre_response_notifications = .empty;
    defer freePendingNotifications(allocator, &notifications);
    for (notifications.items) |payload| {
        try writeStdoutLine(payload);
    }
}

fn writePreResponseNotificationsStream(allocator: std.mem.Allocator, state: *AppServerState, writer: *std.Io.Writer) !void {
    var notifications = state.pre_response_notifications;
    state.pre_response_notifications = .empty;
    defer freePendingNotifications(allocator, &notifications);
    for (notifications.items) |payload| {
        try writeStreamLine(writer, payload);
    }
}

fn writePendingNotificationsStdout(allocator: std.mem.Allocator, state: *AppServerState) !void {
    var notifications = state.pending_notifications;
    state.pending_notifications = .empty;
    defer freePendingNotifications(allocator, &notifications);
    for (notifications.items) |payload| {
        try writeStdoutLine(payload);
    }
}

fn writePendingNotificationsStream(allocator: std.mem.Allocator, state: *AppServerState, writer: *std.Io.Writer) !void {
    var notifications = state.pending_notifications;
    state.pending_notifications = .empty;
    defer freePendingNotifications(allocator, &notifications);
    for (notifications.items) |payload| {
        try writeStreamLine(writer, payload);
    }
}

fn freePendingNotifications(allocator: std.mem.Allocator, notifications: *std.ArrayList([]const u8)) void {
    for (notifications.items) |payload| allocator.free(payload);
    notifications.deinit(allocator);
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

pub fn remoteRejectionLabel(args: []const []const u8) []const u8 {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return "app-server";
        if (optionConsumesValue(arg)) {
            if (index + 1 >= args.len) return "app-server";
            index += 1;
            continue;
        }
        if (optionHasInlineValue(arg) or std.mem.eql(u8, arg, "--analytics-default-enabled")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return "app-server";
        if (subcommandLabel(arg)) |label| return label;
        return "app-server";
    }
    return "app-server";
}

fn optionConsumesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--listen") or
        std.mem.eql(u8, arg, "--ws-auth") or
        std.mem.eql(u8, arg, "--ws-token-file") or
        std.mem.eql(u8, arg, "--ws-token-sha256") or
        std.mem.eql(u8, arg, "--ws-shared-secret-file") or
        std.mem.eql(u8, arg, "--ws-issuer") or
        std.mem.eql(u8, arg, "--ws-audience") or
        std.mem.eql(u8, arg, "--ws-max-clock-skew-seconds");
}

fn optionHasInlineValue(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--listen=") or
        std.mem.startsWith(u8, arg, "--ws-auth=") or
        std.mem.startsWith(u8, arg, "--ws-token-file=") or
        std.mem.startsWith(u8, arg, "--ws-token-sha256=") or
        std.mem.startsWith(u8, arg, "--ws-shared-secret-file=") or
        std.mem.startsWith(u8, arg, "--ws-issuer=") or
        std.mem.startsWith(u8, arg, "--ws-audience=") or
        std.mem.startsWith(u8, arg, "--ws-max-clock-skew-seconds=");
}

fn subcommandLabel(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "proxy")) return "app-server proxy";
    if (std.mem.eql(u8, arg, "generate-ts")) return "app-server generate-ts";
    if (std.mem.eql(u8, arg, "generate-json-schema")) return "app-server generate-json-schema";
    if (std.mem.eql(u8, arg, "generate-internal-json-schema")) return "app-server generate-internal-json-schema";
    return null;
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

test "app-server remote rejection labels known subcommands" {
    try std.testing.expectEqualStrings("app-server", remoteRejectionLabel(&.{}));
    try std.testing.expectEqualStrings("app-server proxy", remoteRejectionLabel(&.{"proxy"}));
    try std.testing.expectEqualStrings(
        "app-server proxy",
        remoteRejectionLabel(&.{ "--listen", "off", "proxy" }),
    );
    try std.testing.expectEqualStrings(
        "app-server generate-internal-json-schema",
        remoteRejectionLabel(&.{ "--listen=off", "generate-internal-json-schema" }),
    );
    try std.testing.expectEqualStrings(
        "app-server generate-ts",
        remoteRejectionLabel(&.{ "--ws-auth", "capability-token", "generate-ts" }),
    );
    try std.testing.expectEqualStrings("app-server", remoteRejectionLabel(&.{"--help"}));
}

test "config/read user origin keys include active profile scalars" {
    const allocator = std.testing.allocator;
    const keys = try collectConfigReadUserOriginKeys(allocator,
        \\model = "base-model"
        \\profile = "work"
        \\approval_policy = "on-request"
        \\
        \\[features]
        \\apps = false
        \\
        \\[profiles.work]
        \\model = "profile-model"
        \\sandbox_mode = "danger-full-access"
        \\profile = "ignored-profile-key"
        \\
        \\[profiles.work.features]
        \\goals = true
        \\
        \\[profiles.other]
        \\service_tier = "flex"
        \\
    , "work");
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 4), keys.len);
    try std.testing.expectEqualStrings("model", keys[0]);
    try std.testing.expectEqualStrings("profile", keys[1]);
    try std.testing.expectEqualStrings("approval_policy", keys[2]);
    try std.testing.expectEqualStrings("sandbox_mode", keys[3]);
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

test "app-server marketplace methods validate params" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const invalid_source_add = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"add\",\"method\":\"marketplace/add\",\"params\":{\"source\":\"not-valid\",\"refName\":\"main\",\"sparsePaths\":[\"plugins/foo\"]}}",
    );
    defer allocator.free(invalid_source_add.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_source_add.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_source_add.?, "invalid marketplace source format") != null);

    const valid_remove = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"remove\",\"method\":\"marketplace/remove\",\"params\":{\"marketplaceName\":\"debug\"}}",
    );
    defer allocator.free(valid_remove.?);
    try std.testing.expect(std.mem.indexOf(u8, valid_remove.?, "\"code\":-32600") != null);

    const valid_upgrade = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"upgrade\",\"method\":\"marketplace/upgrade\",\"params\":{\"marketplaceName\":\"unit-missing-marketplace\"}}",
    );
    defer allocator.free(valid_upgrade.?);
    try std.testing.expect(std.mem.indexOf(u8, valid_upgrade.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid_upgrade.?, "is not configured as a Git marketplace") != null);

    const invalid_add = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-add\",\"method\":\"marketplace/add\",\"params\":{\"refName\":\"main\"}}",
    );
    defer allocator.free(invalid_add.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_add.?, "\"code\":-32602") != null);
}

test "app-server plugin methods validate params" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const invalid_remote_install = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"plugin-install\",\"method\":\"plugin/install\",\"params\":{\"remoteMarketplaceName\":\"openai-curated\",\"pluginName\":\"bad/plugin\"}}",
    );
    defer allocator.free(invalid_remote_install.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_remote_install.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_remote_install.?, "invalid remote plugin id") != null);

    const invalid_read = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-read\",\"method\":\"plugin/read\",\"params\":{\"pluginName\":\"gmail\"}}",
    );
    defer allocator.free(invalid_read.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_read.?, "\"code\":-32600") != null);

    const invalid_read_sources = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-read-sources\",\"method\":\"plugin/read\",\"params\":{\"marketplacePath\":\"/tmp/marketplace.json\",\"remoteMarketplaceName\":\"debug\",\"pluginName\":\"gmail\"}}",
    );
    defer allocator.free(invalid_read_sources.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_read_sources.?, "\"code\":-32600") != null);

    const invalid_skill_id = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-skill-id\",\"method\":\"plugin/skill/read\",\"params\":{\"remoteMarketplaceName\":\"chatgpt-global\",\"remotePluginId\":\"plugins/Plugin_123\",\"skillName\":\"plan-work\"}}",
    );
    defer allocator.free(invalid_skill_id.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_skill_id.?, "\"code\":-32600") != null);

    const invalid_skill_name = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-skill-name\",\"method\":\"plugin/skill/read\",\"params\":{\"remoteMarketplaceName\":\"chatgpt-global\",\"remotePluginId\":\"plugins~Plugin_123\",\"skillName\":\"\"}}",
    );
    defer allocator.free(invalid_skill_name.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_skill_name.?, "\"code\":-32600") != null);

    const relative_share_path = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"relative-plugin-share-path\",\"method\":\"plugin/share/save\",\"params\":{\"pluginPath\":\"relative-plugin\"}}",
    );
    defer allocator.free(relative_share_path.?);
    try std.testing.expect(std.mem.indexOf(u8, relative_share_path.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, relative_share_path.?, "AbsolutePathBuf deserialized without a base path") != null);

    const invalid_share_save_policy = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-share-policy\",\"method\":\"plugin/share/save\",\"params\":{\"pluginPath\":\"/tmp/plugins/gmail\",\"remotePluginId\":\"plugins~Plugin_123\",\"discoverability\":\"PRIVATE\"}}",
    );
    defer allocator.free(invalid_share_save_policy.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_share_save_policy.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_share_save_policy.?, "discoverability and shareTargets are only supported") != null);

    const invalid_share_id = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-share-id\",\"method\":\"plugin/share/delete\",\"params\":{\"remotePluginId\":\"plugins/Plugin_123\"}}",
    );
    defer allocator.free(invalid_share_id.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_share_id.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_share_id.?, "invalid remote plugin id") != null);

    const invalid_uninstall_id = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-uninstall-id\",\"method\":\"plugin/uninstall\",\"params\":{\"pluginId\":\"linear/../../oops\"}}",
    );
    defer allocator.free(invalid_uninstall_id.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_uninstall_id.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_uninstall_id.?, "invalid remote plugin id") != null);

    const invalid_kind = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-list\",\"method\":\"plugin/list\",\"params\":{\"marketplaceKinds\":[\"unexpected\"]}}",
    );
    defer allocator.free(invalid_kind.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid_kind.?, "\"code\":-32602") != null);

    const relative_cwd = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-plugin-list-cwd\",\"method\":\"plugin/list\",\"params\":{\"cwds\":[\"relative-root\"]}}",
    );
    defer allocator.free(relative_cwd.?);
    try std.testing.expect(std.mem.indexOf(u8, relative_cwd.?, "\"code\":-32600") != null);
}

test "app-server fuzzy file search sessions emit update and complete notifications" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "alpha.txt",
        .data = "contents",
    });
    const root = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(root);
    const root_json = try std.json.Stringify.valueAlloc(allocator, root, .{});
    defer allocator.free(root_json);

    var state = AppServerState{};
    defer state.deinit(allocator);

    const start_line = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"session-start\",\"method\":\"fuzzyFileSearch/sessionStart\",\"params\":{{\"sessionId\":\"session-1\",\"roots\":[{s}]}}}}",
        .{root_json},
    );
    defer allocator.free(start_line);
    const start = try handleJsonRpcLine(allocator, &state, start_line);
    defer allocator.free(start.?);
    try std.testing.expect(std.mem.indexOf(u8, start.?, "\"result\":{}") != null);

    const update = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"session-update\",\"method\":\"fuzzyFileSearch/sessionUpdate\",\"params\":{\"sessionId\":\"session-1\",\"query\":\"ALP\"}}",
    );
    defer allocator.free(update.?);
    try std.testing.expect(std.mem.indexOf(u8, update.?, "\"result\":{}") != null);
    try std.testing.expectEqual(@as(usize, 2), state.pending_notifications.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.pending_notifications.items[0], "\"method\":\"fuzzyFileSearch/sessionUpdated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.pending_notifications.items[0], "\"sessionId\":\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.pending_notifications.items[0], "\"query\":\"ALP\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.pending_notifications.items[0], "\"path\":\"alpha.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.pending_notifications.items[1], "\"method\":\"fuzzyFileSearch/sessionCompleted\"") != null);

    const stop = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"session-stop\",\"method\":\"fuzzyFileSearch/sessionStop\",\"params\":{\"sessionId\":\"session-1\"}}",
    );
    defer allocator.free(stop.?);
    try std.testing.expect(std.mem.indexOf(u8, stop.?, "\"result\":{}") != null);

    const missing_update = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"session-missing\",\"method\":\"fuzzyFileSearch/sessionUpdate\",\"params\":{\"sessionId\":\"session-1\",\"query\":\"alp\"}}",
    );
    defer allocator.free(missing_update.?);
    try std.testing.expect(std.mem.indexOf(u8, missing_update.?, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_update.?, "fuzzy file search session not found: session-1") != null);
}

test "app-server hooks list validates params" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const invalid = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-hooks-list\",\"method\":\"hooks/list\",\"params\":[]}",
    );
    defer allocator.free(invalid.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid.?, "\"code\":-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid.?, "hooks/list params must be an object") != null);
}

test "app-server collaboration mode list returns built-in presets" {
    const allocator = std.testing.allocator;
    var state = AppServerState{};
    defer state.deinit(allocator);

    const response = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"collaboration-modes\",\"method\":\"collaborationMode/list\",\"params\":{}}",
    );
    defer allocator.free(response.?);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.?, .{});
    defer parsed.deinit();

    const data = parsed.value.object.get("result").?.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), data.len);

    const plan = data[0].object;
    try std.testing.expectEqualStrings("Plan", plan.get("name").?.string);
    try std.testing.expectEqualStrings("plan", plan.get("mode").?.string);
    try std.testing.expect(plan.get("model").? == .null);
    try std.testing.expectEqualStrings("medium", plan.get("reasoning_effort").?.string);

    const default = data[1].object;
    try std.testing.expectEqualStrings("Default", default.get("name").?.string);
    try std.testing.expectEqualStrings("default", default.get("mode").?.string);
    try std.testing.expect(default.get("model").? == .null);
    try std.testing.expect(default.get("reasoning_effort").? == .null);

    const invalid = try handleJsonRpcLine(
        allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":\"bad-collaboration-modes\",\"method\":\"collaborationMode/list\",\"params\":[]}",
    );
    defer allocator.free(invalid.?);
    try std.testing.expect(std.mem.indexOf(u8, invalid.?, "\"code\":-32602") != null);
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
