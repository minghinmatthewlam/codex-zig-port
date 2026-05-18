const std = @import("std");
const builtin = @import("builtin");

const cli_utils = @import("cli_utils.zig");
const plugin_config = @import("plugin_config.zig");
const env = @import("env.zig");

pub const ServerKind = enum { unknown, stdio, streamable_http };

pub const McpOAuthCredentialsStore = enum { auto, file, keyring };
const mcp_oauth_keyring_service = "Codex MCP Credentials";
const security_binary = "/usr/bin/security";

pub const McpAuthStatus = enum {
    unsupported,
    not_logged_in,
    bearer_token,
    oauth,

    fn display(self: McpAuthStatus) []const u8 {
        return switch (self) {
            .unsupported => "Unsupported",
            .not_logged_in => "Not logged in",
            .bearer_token => "Bearer token",
            .oauth => "OAuth",
        };
    }

    fn json(self: McpAuthStatus) []const u8 {
        return switch (self) {
            .unsupported => "Unsupported",
            .not_logged_in => "NotLoggedIn",
            .bearer_token => "BearerToken",
            .oauth => "OAuth",
        };
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: KeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const McpServer = struct {
    name: []const u8,
    kind: ServerKind = .unknown,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    bearer_token_env_var: ?[]const u8 = null,
    enabled: bool = true,
    args: std.ArrayList([]const u8) = .empty,
    env_vars: std.ArrayList(KeyValue) = .empty,
    http_headers: std.ArrayList(KeyValue) = .empty,
    env_http_headers: std.ArrayList(KeyValue) = .empty,
    scopes: std.ArrayList([]const u8) = .empty,
    oauth_resource: ?[]const u8 = null,

    pub fn deinit(self: *McpServer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.command) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        if (self.bearer_token_env_var) |value| allocator.free(value);
        if (self.oauth_resource) |value| allocator.free(value);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        for (self.env_vars.items) |entry| entry.deinit(allocator);
        self.env_vars.deinit(allocator);
        for (self.http_headers.items) |entry| entry.deinit(allocator);
        self.http_headers.deinit(allocator);
        for (self.env_http_headers.items) |entry| entry.deinit(allocator);
        self.env_http_headers.deinit(allocator);
        for (self.scopes.items) |scope| allocator.free(scope);
        self.scopes.deinit(allocator);
    }
};

pub const McpServers = struct {
    items: std.ArrayList(McpServer) = .empty,

    pub fn deinit(self: *McpServers, allocator: std.mem.Allocator) void {
        for (self.items.items) |*server| server.deinit(allocator);
        self.items.deinit(allocator);
    }

    pub fn findIndex(self: McpServers, name: []const u8) ?usize {
        for (self.items.items, 0..) |server, index| {
            if (std.mem.eql(u8, server.name, name)) return index;
        }
        return null;
    }

    pub fn get(self: McpServers, name: []const u8) ?*McpServer {
        const index = self.findIndex(name) orelse return null;
        return &self.items.items[index];
    }

    fn getOrAdd(self: *McpServers, allocator: std.mem.Allocator, name: []const u8) !*McpServer {
        if (self.findIndex(name)) |index| return &self.items.items[index];
        try self.items.append(allocator, .{ .name = try allocator.dupe(u8, name) });
        return &self.items.items[self.items.items.len - 1];
    }

    pub fn remove(self: *McpServers, allocator: std.mem.Allocator, name: []const u8) bool {
        const index = self.findIndex(name) orelse return false;
        var removed = self.items.orderedRemove(index);
        removed.deinit(allocator);
        return true;
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }
    try runArgs(allocator, raw_args.items);
}

fn runArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or isHelpFlag(args[0])) {
        printHelp();
        return;
    }

    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    var servers = try parseServers(allocator, config_bytes orelse "");
    defer servers.deinit(allocator);

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "list")) {
        try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
        try runList(allocator, codex_home, config_bytes orelse "", servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "get")) {
        try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
        try runGet(allocator, servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        try runAdd(allocator, codex_home, config_bytes orelse "", &servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try runRemove(allocator, codex_home, config_bytes orelse "", &servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "login")) {
        try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
        try runLogin(allocator, codex_home, config_bytes orelse "", servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "logout")) {
        try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
        try runLogout(allocator, codex_home, config_bytes orelse "", servers, args[1..]);
    } else {
        return error.UnknownMcpSubcommand;
    }
}

pub fn loadServers(allocator: std.mem.Allocator, codex_home: []const u8) !McpServers {
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    return loadServersFromConfig(allocator, codex_home, config_bytes orelse "");
}

pub fn loadServersFromConfig(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8) !McpServers {
    var servers = try parseServers(allocator, config_bytes);
    errdefer servers.deinit(allocator);
    try appendPluginMcpServers(allocator, codex_home, config_bytes, &servers);
    return servers;
}

pub fn renderStatus(allocator: std.mem.Allocator, codex_home: []const u8, verbose: bool) ![]const u8 {
    var servers = try loadServers(allocator, codex_home);
    defer servers.deinit(allocator);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    if (servers.items.items.len == 0) {
        try output.appendSlice(allocator, "mcp: no servers configured\n");
        return output.toOwnedSlice(allocator);
    }

    try output.appendSlice(allocator, "mcp servers:\n");
    for (servers.items.items) |server| {
        if (verbose) {
            try appendVerboseServerStatus(allocator, &output, server);
        } else {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, server.name);
            try output.append(allocator, '\t');
            try output.appendSlice(allocator, kindLabel(server));
            try output.append(allocator, '\t');
            try output.appendSlice(allocator, statusLabel(server.enabled));
            try output.append(allocator, '\n');
        }
    }

    return output.toOwnedSlice(allocator);
}

fn runList(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8, servers: McpServers, args: []const []const u8) !void {
    var json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (isHelpFlag(arg)) {
            printListHelp();
            return;
        } else {
            return error.UnknownMcpListOption;
        }
    }

    if (json) {
        const rendered = try renderJsonList(allocator, codex_home, config_bytes, servers);
        defer allocator.free(rendered);
        try cli_utils.writeStdout(rendered);
        return;
    }

    if (servers.items.items.len == 0) {
        try cli_utils.writeStdout("No MCP servers configured yet. Try `codex-zig mcp add my-tool -- my-command`.\n");
        return;
    }
    for (servers.items.items) |server| {
        const auth_status = try mcpAuthStatusForServer(allocator, codex_home, config_bytes, server);
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}\t{s}\t{s}\t{s}\n",
            .{ server.name, kindLabel(server), statusLabel(server.enabled), auth_status.display() },
        );
        defer allocator.free(line);
        try cli_utils.writeStdout(line);
    }
}

fn runGet(allocator: std.mem.Allocator, servers: McpServers, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingMcpServerName;
    const name = args[0];
    var json = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (isHelpFlag(arg)) {
            printGetHelp();
            return;
        } else {
            return error.UnknownMcpGetOption;
        }
    }
    const server = servers.get(name) orelse return error.McpServerNotFound;
    if (json) {
        const rendered = try renderJsonServer(allocator, server.*);
        defer allocator.free(rendered);
        try cli_utils.writeStdout(rendered);
        try cli_utils.writeStdout("\n");
        return;
    }
    try printServer(allocator, server.*);
}

fn runAdd(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    original_config: []const u8,
    servers: *McpServers,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.MissingMcpServerName;
    const name = args[0];
    try validateServerName(name);

    var parsed = McpServer{ .name = try allocator.dupe(u8, name) };
    var parsed_moved = false;
    errdefer if (!parsed_moved) parsed.deinit(allocator);

    var index: usize = 1;
    var saw_command_separator = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            saw_command_separator = true;
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--url")) {
            index += 1;
            if (index >= args.len) return error.MissingMcpOptionValue;
            if (parsed.kind == .stdio) return error.ConflictingMcpTransports;
            parsed.kind = .streamable_http;
            if (parsed.url) |existing| allocator.free(existing);
            parsed.url = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--url=")) {
            if (parsed.kind == .stdio) return error.ConflictingMcpTransports;
            parsed.kind = .streamable_http;
            if (parsed.url) |existing| allocator.free(existing);
            parsed.url = try allocator.dupe(u8, arg["--url=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--bearer-token-env-var")) {
            index += 1;
            if (index >= args.len) return error.MissingMcpOptionValue;
            if (parsed.bearer_token_env_var) |existing| allocator.free(existing);
            parsed.bearer_token_env_var = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--bearer-token-env-var=")) {
            if (parsed.bearer_token_env_var) |existing| allocator.free(existing);
            parsed.bearer_token_env_var = try allocator.dupe(u8, arg["--bearer-token-env-var=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--env")) {
            index += 1;
            if (index >= args.len) return error.MissingMcpOptionValue;
            try appendEnvPair(allocator, &parsed, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--env=")) {
            try appendEnvPair(allocator, &parsed, arg["--env=".len..]);
            continue;
        }
        if (isHelpFlag(arg)) {
            printAddHelp();
            return;
        }
        return error.UnknownMcpAddOption;
    }

    if (saw_command_separator) {
        if (parsed.kind == .streamable_http) return error.ConflictingMcpTransports;
        if (index >= args.len) return error.MissingMcpCommand;
        parsed.kind = .stdio;
        parsed.command = try allocator.dupe(u8, args[index]);
        index += 1;
        while (index < args.len) : (index += 1) {
            try parsed.args.append(allocator, try allocator.dupe(u8, args[index]));
        }
    }

    if (parsed.kind == .unknown) return error.MissingMcpTransport;
    if (parsed.kind == .streamable_http and parsed.url == null) return error.MissingMcpUrl;
    if (parsed.kind == .stdio and parsed.command == null) return error.MissingMcpCommand;

    if (servers.remove(allocator, name)) {}
    try servers.items.append(allocator, parsed);
    parsed_moved = true;

    try writeServersConfig(allocator, codex_home, original_config, servers.*);
    const message = try std.fmt.allocPrint(allocator, "Added global MCP server '{s}'.\n", .{name});
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn runRemove(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    original_config: []const u8,
    servers: *McpServers,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.MissingMcpServerName;
    if (args.len > 1) return error.UnexpectedMcpArgument;
    const name = args[0];
    try validateServerName(name);
    const removed = servers.remove(allocator, name);
    if (removed) try writeServersConfig(allocator, codex_home, original_config, servers.*);
    const message = if (removed)
        try std.fmt.allocPrint(allocator, "Removed global MCP server '{s}'.\n", .{name})
    else
        try std.fmt.allocPrint(allocator, "No MCP server named '{s}' found.\n", .{name});
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn runLogin(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8, servers: McpServers, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingMcpServerName;
    if (isHelpFlag(args[0])) {
        printLoginHelp();
        return;
    }
    const name = args[0];
    try validateServerName(name);

    var explicit_scopes = std.ArrayList([]const u8).empty;
    defer {
        for (explicit_scopes.items) |scope| allocator.free(scope);
        explicit_scopes.deinit(allocator);
    }
    var explicit_scopes_present = false;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            printLoginHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--scopes")) {
            index += 1;
            if (index >= args.len) return error.MissingMcpOptionValue;
            try replaceMcpOAuthScopesCsv(allocator, &explicit_scopes, args[index]);
            explicit_scopes_present = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--scopes=")) {
            try replaceMcpOAuthScopesCsv(allocator, &explicit_scopes, arg["--scopes=".len..]);
            explicit_scopes_present = true;
            continue;
        }
        return error.UnknownMcpLoginOption;
    }

    const server = servers.get(name) orelse {
        const message = try std.fmt.allocPrint(allocator, "No MCP server named '{s}' found.\n", .{name});
        defer allocator.free(message);
        try cli_utils.writeStderr(message);
        return error.McpServerNotFound;
    };
    if (server.kind != .streamable_http or server.url == null) {
        try cli_utils.writeStderr("OAuth login is only supported for streamable HTTP servers.\n");
        return error.McpOAuthLoginRequiresHttp;
    }

    const resolved_scopes = if (explicit_scopes_present) explicit_scopes.items else server.scopes.items;
    try performMcpOAuthLogin(allocator, codex_home, config_bytes, server.*, resolved_scopes);
    const message = try std.fmt.allocPrint(allocator, "Successfully logged in to MCP server '{s}'.\n", .{name});
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn runLogout(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    servers: McpServers,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.MissingMcpServerName;
    if (args.len > 1) return error.UnexpectedMcpArgument;
    const name = args[0];
    try validateServerName(name);

    const server = servers.get(name) orelse return error.McpServerNotFound;
    if (server.kind != .streamable_http) return error.McpOAuthLogoutRequiresHttp;
    const url = server.url orelse return error.McpOAuthLogoutRequiresHttp;

    const store_mode = parseMcpOAuthCredentialsStore(config_bytes);
    const removed = try deleteMcpOAuthCredentials(allocator, codex_home, store_mode, name, url);
    const message = if (removed)
        try std.fmt.allocPrint(allocator, "Removed OAuth credentials for '{s}'.\n", .{name})
    else
        try std.fmt.allocPrint(allocator, "No OAuth credentials stored for '{s}'.\n", .{name});
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn validateMcpOAuthScopes(raw: []const u8) !void {
    var start: usize = 0;
    while (start <= raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, ',') orelse raw.len;
        const scope = std.mem.trim(u8, raw[start..end], " \t\r\n");
        if (scope.len == 0) return error.InvalidMcpOAuthScopes;
        if (end == raw.len) break;
        start = end + 1;
    }
}

fn replaceMcpOAuthScopesCsv(allocator: std.mem.Allocator, scopes: *std.ArrayList([]const u8), raw: []const u8) !void {
    try validateMcpOAuthScopes(raw);
    for (scopes.items) |scope| allocator.free(scope);
    scopes.clearRetainingCapacity();

    var start: usize = 0;
    while (start <= raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, ',') orelse raw.len;
        const scope = std.mem.trim(u8, raw[start..end], " \t\r\n");
        try scopes.append(allocator, try allocator.dupe(u8, scope));
        if (end == raw.len) break;
        start = end + 1;
    }
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| return value;
    const home = try env.getOwned(allocator, "HOME") orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

pub fn readConfigToml(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 512)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn parseMcpOAuthCredentialsStore(config_bytes: []const u8) McpOAuthCredentialsStore {
    var in_top_level = true;
    var start: usize = 0;
    while (start < config_bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, config_bytes, start, '\n') orelse config_bytes.len;
        const raw_line = config_bytes[start..end];
        start = if (end < config_bytes.len) end + 1 else config_bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_top_level = false;
            continue;
        }
        if (!in_top_level) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "mcp_oauth_credentials_store")) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, value, "\"file\"")) return .file;
        if (std.mem.eql(u8, value, "\"keyring\"")) return .keyring;
        if (std.mem.eql(u8, value, "\"auto\"")) return .auto;
    }
    return .auto;
}

const McpOAuthCallbackConfig = struct {
    port: ?u16 = null,
    url: ?[]const u8 = null,

    fn deinit(self: *McpOAuthCallbackConfig, allocator: std.mem.Allocator) void {
        if (self.url) |value| allocator.free(value);
    }
};

fn parseMcpOAuthCallbackConfig(allocator: std.mem.Allocator, config_bytes: []const u8) !McpOAuthCallbackConfig {
    var parsed = McpOAuthCallbackConfig{};
    errdefer parsed.deinit(allocator);

    var in_top_level = true;
    var start: usize = 0;
    while (start < config_bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, config_bytes, start, '\n') orelse config_bytes.len;
        const raw_line = config_bytes[start..end];
        start = if (end < config_bytes.len) end + 1 else config_bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_top_level = false;
            continue;
        }
        if (!in_top_level) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "mcp_oauth_callback_port")) {
            const port = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidMcpOAuthCallbackPort;
            if (port == 0) return error.InvalidMcpOAuthCallbackPort;
            parsed.port = port;
        } else if (std.mem.eql(u8, key, "mcp_oauth_callback_url")) {
            const url = (try parseTomlString(allocator, value)) orelse return error.InvalidMcpOAuthCallbackUrl;
            errdefer allocator.free(url);
            _ = std.Uri.parse(url) catch return error.InvalidMcpOAuthCallbackUrl;
            if (parsed.url) |existing| allocator.free(existing);
            parsed.url = url;
        }
    }

    return parsed;
}

fn deleteMcpOAuthCredentials(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: McpOAuthCredentialsStore,
    server_name: []const u8,
    server_url: []const u8,
) !bool {
    if (store_mode == .file) {
        return deleteMcpOAuthFileCredentials(allocator, codex_home, server_name, server_url);
    }

    const keyring_removed = deleteMcpOAuthKeyringCredentials(allocator, server_name, server_url) catch |err| switch (err) {
        error.UnsupportedMcpOAuthKeyring => if (store_mode == .auto) false else return err,
        else => return err,
    };
    const file_removed = try deleteMcpOAuthFileCredentials(allocator, codex_home, server_name, server_url);
    return keyring_removed or file_removed;
}

fn mcpOAuthKeyringSupported() bool {
    return builtin.os.tag == .macos;
}

fn hasMcpOAuthKeyringCredentials(allocator: std.mem.Allocator, server_name: []const u8, server_url: []const u8) !bool {
    if (!mcpOAuthKeyringSupported()) return error.UnsupportedMcpOAuthKeyring;

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);
    const argv = [_][]const u8{ security_binary, "find-generic-password", "-s", mcp_oauth_keyring_service, "-a", key };
    var result = try runSecurityCommand(allocator, argv[0..]);
    defer result.deinit(allocator);
    return classifySecurityGenericPasswordResult(result.term);
}

fn deleteMcpOAuthKeyringCredentials(allocator: std.mem.Allocator, server_name: []const u8, server_url: []const u8) !bool {
    if (!mcpOAuthKeyringSupported()) return error.UnsupportedMcpOAuthKeyring;

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);
    const argv = [_][]const u8{ security_binary, "delete-generic-password", "-s", mcp_oauth_keyring_service, "-a", key };
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
            else => error.McpOAuthKeyringUnavailable,
        },
        else => error.McpOAuthKeyringUnavailable,
    };
}

fn deleteMcpOAuthFileCredentials(allocator: std.mem.Allocator, codex_home: []const u8, server_name: []const u8, server_url: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ codex_home, ".credentials.json" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidMcpOAuthCredentialsFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpOAuthCredentialsFile;

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');

    var found = false;
    var kept: usize = 0;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, key)) {
            found = true;
            continue;
        }
        if (kept > 0) try output.append(allocator, ',');
        try appendJsonString(allocator, &output, entry.key_ptr.*);
        try output.append(allocator, ':');
        const rendered_value = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(rendered_value);
        try output.appendSlice(allocator, rendered_value);
        kept += 1;
    }
    try output.append(allocator, '}');

    if (!found) {
        output.deinit(allocator);
        return false;
    }
    if (kept == 0) {
        output.deinit(allocator);
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return true;
    }

    const rendered = try output.toOwnedSlice(allocator);
    defer allocator.free(rendered);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = rendered });
    return true;
}

fn hasMcpOAuthFileCredentials(allocator: std.mem.Allocator, codex_home: []const u8, server_name: []const u8, server_url: []const u8) !bool {
    const access_token = try readMcpOAuthFileAccessToken(allocator, codex_home, server_name, server_url);
    defer if (access_token) |token| allocator.free(token);
    return access_token != null;
}

pub fn readMcpOAuthFileAccessToken(allocator: std.mem.Allocator, codex_home: []const u8, server_name: []const u8, server_url: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, ".credentials.json" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidMcpOAuthCredentialsFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpOAuthCredentialsFile;

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);
    const entry = parsed.value.object.get(key) orelse return null;
    if (entry != .object) return error.InvalidMcpOAuthCredentialsFile;
    const access_token = entry.object.get("access_token") orelse return null;
    if (access_token != .string or access_token.string.len == 0) return null;
    return try allocator.dupe(u8, access_token.string);
}

pub fn readMcpOAuthAccessToken(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    server_name: []const u8,
    server_url: []const u8,
) !?[]const u8 {
    switch (parseMcpOAuthCredentialsStore(config_bytes)) {
        .auto => {
            if (mcpOAuthKeyringSupported()) {
                if (readMcpOAuthKeyringAccessToken(allocator, server_name, server_url) catch null) |token| return token;
            }
            return readMcpOAuthFileAccessToken(allocator, codex_home, server_name, server_url);
        },
        .file => return readMcpOAuthFileAccessToken(allocator, codex_home, server_name, server_url),
        .keyring => return readMcpOAuthKeyringAccessToken(allocator, server_name, server_url),
    }
}

fn readMcpOAuthKeyringAccessToken(allocator: std.mem.Allocator, server_name: []const u8, server_url: []const u8) !?[]const u8 {
    if (!mcpOAuthKeyringSupported()) return error.UnsupportedMcpOAuthKeyring;

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);
    const argv = [_][]const u8{ security_binary, "find-generic-password", "-w", "-s", mcp_oauth_keyring_service, "-a", key };
    var result = try runSecurityCommand(allocator, argv[0..]);
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {
                const serialized = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (serialized.len == 0) return null;
                return readMcpOAuthStoredTokensAccessToken(allocator, serialized);
            },
            44 => return null,
            else => return error.McpOAuthKeyringUnavailable,
        },
        else => return error.McpOAuthKeyringUnavailable,
    }
}

fn readMcpOAuthStoredTokensAccessToken(allocator: std.mem.Allocator, serialized: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, serialized, .{}) catch return error.InvalidMcpOAuthCredentials;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpOAuthCredentials;

    if (parsed.value.object.get("access_token")) |top_level_access_token| {
        if (top_level_access_token == .string and top_level_access_token.string.len > 0) {
            return try allocator.dupe(u8, top_level_access_token.string);
        }
    }

    const token_response = parsed.value.object.get("token_response") orelse return null;
    if (token_response != .object) return error.InvalidMcpOAuthCredentials;
    const access_token = token_response.object.get("access_token") orelse return null;
    if (access_token != .string or access_token.string.len == 0) return null;
    return try allocator.dupe(u8, access_token.string);
}

pub fn mcpAuthStatusForServer(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8, server: McpServer) !McpAuthStatus {
    if (!server.enabled) return .unsupported;
    if (server.kind != .streamable_http) return .unsupported;
    if (server.bearer_token_env_var != null) return .bearer_token;
    const url = server.url orelse return .unsupported;

    switch (parseMcpOAuthCredentialsStore(config_bytes)) {
        .auto => {
            if (mcpOAuthKeyringSupported() and (hasMcpOAuthKeyringCredentials(allocator, server.name, url) catch false)) return .oauth;
            if (try hasMcpOAuthFileCredentials(allocator, codex_home, server.name, url)) return .oauth;
        },
        .file => {
            if (try hasMcpOAuthFileCredentials(allocator, codex_home, server.name, url)) return .oauth;
        },
        .keyring => {
            if (!mcpOAuthKeyringSupported()) return .unsupported;
            const has_keyring_credentials = hasMcpOAuthKeyringCredentials(allocator, server.name, url) catch return .unsupported;
            if (has_keyring_credentials) return .oauth;
        },
    }

    if (streamableHttpSupportsOAuth(allocator, url) catch false) return .not_logged_in;
    return .unsupported;
}

fn streamableHttpSupportsOAuth(allocator: std.mem.Allocator, url: []const u8) !bool {
    var candidates = try discoveryUrls(allocator, url);
    defer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit(allocator);
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "MCP-Protocol-Version", .value = "2024-11-05" },
        .{ .name = "Accept", .value = "application/json" },
    };

    for (candidates.items) |candidate| {
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();
        const result = client.fetch(.{
            .location = .{ .url = candidate },
            .method = .GET,
            .response_writer = &response_body.writer,
            .extra_headers = &headers,
        }) catch continue;
        if (result.status != .ok) continue;
        const body = response_body.written();
        if (oauthDiscoveryMetadataIsSupported(allocator, body) catch false) return true;
    }
    return false;
}

fn discoveryUrls(allocator: std.mem.Allocator, url: []const u8) !std.ArrayList([]const u8) {
    var candidates = std.ArrayList([]const u8).empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit(allocator);
    }

    const scheme = std.mem.indexOf(u8, url, "://") orelse return error.InvalidMcpOAuthDiscoveryUrl;
    const authority_start = scheme + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    const origin = url[0..path_start];
    const raw_path = if (path_start < url.len) url[path_start..] else "";
    const path_without_query = if (std.mem.indexOfScalar(u8, raw_path, '?')) |query| raw_path[0..query] else raw_path;
    const trimmed = std.mem.trim(u8, path_without_query, "/");
    const canonical = "/.well-known/oauth-authorization-server";

    if (trimmed.len == 0) {
        try candidates.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, canonical }));
        return candidates;
    }

    try appendUniqueDiscoveryUrl(allocator, &candidates, origin, canonical, trimmed, .canonical_then_path);
    try appendUniqueDiscoveryUrl(allocator, &candidates, origin, canonical, trimmed, .path_then_canonical);
    try appendUniqueDiscoveryUrl(allocator, &candidates, origin, canonical, trimmed, .canonical);
    return candidates;
}

const DiscoveryUrlKind = enum { canonical_then_path, path_then_canonical, canonical };

fn appendUniqueDiscoveryUrl(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList([]const u8),
    origin: []const u8,
    canonical: []const u8,
    trimmed_path: []const u8,
    kind: DiscoveryUrlKind,
) !void {
    const candidate = switch (kind) {
        .canonical_then_path => try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ origin, canonical, trimmed_path }),
        .path_then_canonical => try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ origin, trimmed_path, canonical }),
        .canonical => try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, canonical }),
    };
    errdefer allocator.free(candidate);
    for (candidates.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) {
            allocator.free(candidate);
            return;
        }
    }
    try candidates.append(allocator, candidate);
}

fn oauthDiscoveryMetadataIsSupported(allocator: std.mem.Allocator, body: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const authorization_endpoint = parsed.value.object.get("authorization_endpoint") orelse return false;
    const token_endpoint = parsed.value.object.get("token_endpoint") orelse return false;
    return authorization_endpoint == .string and token_endpoint == .string;
}

const McpOAuthMetadata = struct {
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *McpOAuthMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization_endpoint);
        allocator.free(self.token_endpoint);
        if (self.registration_endpoint) |value| allocator.free(value);
        for (self.scopes_supported.items) |scope| allocator.free(scope);
        self.scopes_supported.deinit(allocator);
    }
};

const McpOAuthClientRegistration = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,

    fn deinit(self: *McpOAuthClientRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        if (self.client_secret) |value| allocator.free(value);
    }
};

const McpOAuthTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at_ms: ?u64 = null,
    scopes: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *McpOAuthTokens, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
        for (self.scopes.items) |scope| allocator.free(scope);
        self.scopes.deinit(allocator);
    }
};

pub const McpOAuthLoginHandle = struct {
    codex_home: []const u8,
    store_mode: McpOAuthCredentialsStore,
    server: McpServer,
    callback_server: std.Io.net.Server,
    redirect_uri: []const u8,
    callback_path: []const u8,
    token_endpoint: []const u8,
    registration: McpOAuthClientRegistration,
    code_verifier: []const u8,
    state: []const u8,
    authorization_url: []const u8,

    pub fn deinit(self: *McpOAuthLoginHandle, allocator: std.mem.Allocator) void {
        self.callback_server.deinit(std.Io.Threaded.global_single_threaded.io());
        allocator.free(self.codex_home);
        self.server.deinit(allocator);
        allocator.free(self.redirect_uri);
        allocator.free(self.callback_path);
        allocator.free(self.token_endpoint);
        self.registration.deinit(allocator);
        allocator.free(self.code_verifier);
        allocator.free(self.state);
        allocator.free(self.authorization_url);
    }

    pub fn waitAndSave(self: *McpOAuthLoginHandle, allocator: std.mem.Allocator, timeout_secs: ?i64) !void {
        const server_url = self.server.url orelse return error.McpOAuthLoginRequiresHttp;
        const code = try waitForMcpOAuthCallback(allocator, &self.callback_server, self.callback_path, self.state, timeout_secs);
        defer allocator.free(code);

        var tokens = try exchangeMcpOAuthCodeForTokens(
            allocator,
            self.server,
            self.token_endpoint,
            code,
            self.redirect_uri,
            self.registration.client_id,
            self.registration.client_secret,
            self.code_verifier,
        );
        defer tokens.deinit(allocator);

        try saveMcpOAuthCredentials(allocator, self.codex_home, self.store_mode, self.server.name, server_url, self.registration.client_id, tokens);
    }
};

const McpOAuthHttpHeaders = struct {
    headers: std.ArrayList(std.http.Header) = .empty,
    owned_values: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *McpOAuthHttpHeaders, allocator: std.mem.Allocator) void {
        for (self.owned_values.items) |value| allocator.free(value);
        self.owned_values.deinit(allocator);
        self.headers.deinit(allocator);
    }
};

const McpOAuthHttpResponse = struct {
    status: std.http.Status,
    body: []const u8,

    fn deinit(self: *const McpOAuthHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const PkceCodes = struct {
    code_verifier: []const u8,
    code_challenge: []const u8,

    fn deinit(self: *PkceCodes, allocator: std.mem.Allocator) void {
        allocator.free(self.code_verifier);
        allocator.free(self.code_challenge);
    }
};

fn performMcpOAuthLogin(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    server: McpServer,
    requested_scopes: []const []const u8,
) !void {
    var handle = try startMcpOAuthLoginReturnUrl(allocator, codex_home, config_bytes, server, requested_scopes, true);
    defer handle.deinit(allocator);

    try printMcpOAuthPrompt(allocator, server.name, handle.authorization_url);
    if (!try shouldSkipMcpOAuthBrowser(allocator)) {
        openBrowser(allocator, handle.authorization_url) catch |err| {
            std.debug.print("warning: could not open browser automatically: {s}\n", .{@errorName(err)});
        };
    }

    try handle.waitAndSave(allocator, null);
}

pub fn startMcpOAuthLoginReturnUrl(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    server: McpServer,
    requested_scopes: []const []const u8,
    discover_when_empty: bool,
) !McpOAuthLoginHandle {
    _ = server.url orelse return error.McpOAuthLoginRequiresHttp;

    var metadata = try discoverMcpOAuthMetadata(allocator, server);
    defer metadata.deinit(allocator);

    var resolved_scopes = try resolveMcpOAuthLoginScopes(allocator, requested_scopes, metadata.scopes_supported.items, discover_when_empty);
    defer {
        for (resolved_scopes.items) |scope| allocator.free(scope);
        resolved_scopes.deinit(allocator);
    }

    var callback_config = try parseMcpOAuthCallbackConfig(allocator, config_bytes);
    defer callback_config.deinit(allocator);

    var callback_server = try bindMcpOAuthCallbackServer(callback_config.port, callback_config.url);
    errdefer callback_server.deinit(std.Io.Threaded.global_single_threaded.io());

    const redirect_uri = try mcpOAuthRedirectUri(allocator, &callback_server, callback_config.url);
    errdefer allocator.free(redirect_uri);
    const callback_path = try mcpOAuthCallbackPathFromRedirectUri(allocator, redirect_uri);
    errdefer allocator.free(callback_path);

    const registration_endpoint = metadata.registration_endpoint orelse return error.MissingMcpOAuthRegistrationEndpoint;
    var registration = try registerMcpOAuthClient(allocator, server, registration_endpoint, redirect_uri);
    errdefer registration.deinit(allocator);

    var pkce = try generateMcpOAuthPkce(allocator);
    defer pkce.deinit(allocator);
    const code_verifier = try allocator.dupe(u8, pkce.code_verifier);
    errdefer allocator.free(code_verifier);

    const state = try randomUrlSafe(allocator, 32);
    errdefer allocator.free(state);

    const authorization_url = try buildMcpOAuthAuthorizationUrl(
        allocator,
        metadata.authorization_endpoint,
        registration.client_id,
        redirect_uri,
        pkce,
        state,
        resolved_scopes.items,
        server.oauth_resource,
    );
    errdefer allocator.free(authorization_url);

    const token_endpoint = try allocator.dupe(u8, metadata.token_endpoint);
    errdefer allocator.free(token_endpoint);
    const codex_home_owned = try allocator.dupe(u8, codex_home);
    errdefer allocator.free(codex_home_owned);
    var server_owned = try cloneMcpServer(allocator, server);
    errdefer server_owned.deinit(allocator);

    return .{
        .codex_home = codex_home_owned,
        .store_mode = parseMcpOAuthCredentialsStore(config_bytes),
        .server = server_owned,
        .callback_server = callback_server,
        .redirect_uri = redirect_uri,
        .callback_path = callback_path,
        .token_endpoint = token_endpoint,
        .registration = registration,
        .code_verifier = code_verifier,
        .state = state,
        .authorization_url = authorization_url,
    };
}

fn discoverMcpOAuthMetadata(allocator: std.mem.Allocator, server: McpServer) !McpOAuthMetadata {
    const url = server.url orelse return error.McpOAuthLoginRequiresHttp;
    var candidates = try discoveryUrls(allocator, url);
    defer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit(allocator);
    }

    for (candidates.items) |candidate| {
        var response = mcpOAuthFetch(allocator, server, .GET, candidate, null, null) catch continue;
        defer response.deinit(allocator);
        if (!statusIsSuccess(response.status)) continue;
        return parseMcpOAuthMetadata(allocator, response.body) catch continue;
    }
    return error.McpOAuthDiscoveryFailed;
}

fn parseMcpOAuthMetadata(allocator: std.mem.Allocator, body: []const u8) !McpOAuthMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpOAuthDiscoveryMetadata;
    const object = parsed.value.object;
    const authorization_endpoint = jsonStringField(object, "authorization_endpoint") orelse return error.InvalidMcpOAuthDiscoveryMetadata;
    const token_endpoint = jsonStringField(object, "token_endpoint") orelse return error.InvalidMcpOAuthDiscoveryMetadata;

    var metadata = McpOAuthMetadata{
        .authorization_endpoint = try allocator.dupe(u8, authorization_endpoint),
        .token_endpoint = try allocator.dupe(u8, token_endpoint),
    };
    errdefer metadata.deinit(allocator);
    if (jsonStringField(object, "registration_endpoint")) |registration_endpoint| {
        metadata.registration_endpoint = try allocator.dupe(u8, registration_endpoint);
    }
    try appendJsonStringArray(allocator, &metadata.scopes_supported, object.get("scopes_supported"));
    return metadata;
}

fn resolveMcpOAuthLoginScopes(
    allocator: std.mem.Allocator,
    requested_scopes: []const []const u8,
    discovered_scopes: []const []const u8,
    discover_when_empty: bool,
) !std.ArrayList([]const u8) {
    var resolved = std.ArrayList([]const u8).empty;
    errdefer {
        for (resolved.items) |scope| allocator.free(scope);
        resolved.deinit(allocator);
    }
    const source = if (requested_scopes.len > 0 or !discover_when_empty) requested_scopes else discovered_scopes;
    for (source) |scope| {
        try resolved.append(allocator, try allocator.dupe(u8, scope));
    }
    return resolved;
}

fn cloneMcpServer(allocator: std.mem.Allocator, server: McpServer) !McpServer {
    var cloned = McpServer{
        .name = try allocator.dupe(u8, server.name),
        .kind = server.kind,
    };
    errdefer cloned.deinit(allocator);
    if (server.command) |value| cloned.command = try allocator.dupe(u8, value);
    if (server.url) |value| cloned.url = try allocator.dupe(u8, value);
    if (server.bearer_token_env_var) |value| cloned.bearer_token_env_var = try allocator.dupe(u8, value);
    cloned.enabled = server.enabled;
    if (server.oauth_resource) |value| cloned.oauth_resource = try allocator.dupe(u8, value);
    for (server.args.items) |arg| try appendClonedString(allocator, &cloned.args, arg);
    for (server.env_vars.items) |entry| try appendClonedKeyValue(allocator, &cloned.env_vars, entry);
    for (server.http_headers.items) |entry| try appendClonedKeyValue(allocator, &cloned.http_headers, entry);
    for (server.env_http_headers.items) |entry| try appendClonedKeyValue(allocator, &cloned.env_http_headers, entry);
    for (server.scopes.items) |scope| try appendClonedString(allocator, &cloned.scopes, scope);
    return cloned;
}

fn appendClonedString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn appendClonedKeyValue(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(KeyValue),
    entry: KeyValue,
) !void {
    const key = try allocator.dupe(u8, entry.key);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, entry.value);
    errdefer allocator.free(value);
    try list.append(allocator, .{ .key = key, .value = value });
}

fn registerMcpOAuthClient(
    allocator: std.mem.Allocator,
    server: McpServer,
    registration_endpoint: []const u8,
    redirect_uri: []const u8,
) !McpOAuthClientRegistration {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .client_name = "Codex",
        .redirect_uris = .{redirect_uri},
        .grant_types = .{"authorization_code"},
        .response_types = .{"code"},
        .token_endpoint_auth_method = "none",
    }, .{});
    defer allocator.free(payload);

    var response = try mcpOAuthFetch(allocator, server, .POST, registration_endpoint, "application/json", payload);
    defer response.deinit(allocator);
    if (!statusIsSuccess(response.status)) return error.McpOAuthClientRegistrationFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpOAuthClientRegistrationFailed;
    const client_id = jsonStringField(parsed.value.object, "client_id") orelse return error.McpOAuthClientRegistrationFailed;
    var registered = McpOAuthClientRegistration{ .client_id = try allocator.dupe(u8, client_id) };
    errdefer registered.deinit(allocator);
    if (jsonStringField(parsed.value.object, "client_secret")) |client_secret| {
        registered.client_secret = try allocator.dupe(u8, client_secret);
    }
    return registered;
}

fn exchangeMcpOAuthCodeForTokens(
    allocator: std.mem.Allocator,
    server: McpServer,
    token_endpoint: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8,
    code_verifier: []const u8,
) !McpOAuthTokens {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendFormField(allocator, &body, "grant_type", "authorization_code");
    try appendFormField(allocator, &body, "code", code);
    try appendFormField(allocator, &body, "redirect_uri", redirect_uri);
    try appendFormField(allocator, &body, "client_id", client_id);
    try appendFormField(allocator, &body, "code_verifier", code_verifier);
    if (client_secret) |secret| try appendFormField(allocator, &body, "client_secret", secret);

    var response = try mcpOAuthFetch(allocator, server, .POST, token_endpoint, "application/x-www-form-urlencoded", body.items);
    defer response.deinit(allocator);
    if (!statusIsSuccess(response.status)) return error.McpOAuthTokenExchangeFailed;

    return parseMcpOAuthTokenResponse(allocator, response.body);
}

fn parseMcpOAuthTokenResponse(allocator: std.mem.Allocator, body: []const u8) !McpOAuthTokens {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpOAuthTokenExchangeFailed;
    const object = parsed.value.object;
    const access_token = jsonStringField(object, "access_token") orelse return error.McpOAuthTokenExchangeFailed;
    var tokens = McpOAuthTokens{ .access_token = try allocator.dupe(u8, access_token) };
    errdefer tokens.deinit(allocator);
    if (jsonStringField(object, "refresh_token")) |refresh_token| {
        tokens.refresh_token = try allocator.dupe(u8, refresh_token);
    }
    if (oauthJsonUnsigned(object.get("expires_in"))) |expires_in| {
        const now_ms: u64 = @intCast(currentUnixMilliseconds());
        tokens.expires_at_ms = now_ms + expires_in * std.time.ms_per_s;
    }
    if (jsonStringField(object, "scope")) |scope_text| {
        try appendSpaceSeparatedScopes(allocator, &tokens.scopes, scope_text);
    }
    return tokens;
}

fn saveMcpOAuthCredentials(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    store_mode: McpOAuthCredentialsStore,
    server_name: []const u8,
    server_url: []const u8,
    client_id: []const u8,
    tokens: McpOAuthTokens,
) !void {
    // The Zig runtime currently reads file-backed MCP OAuth tokens. Use the
    // fallback file for auto mode until full keyring-backed runtime parity lands.
    switch (store_mode) {
        .file, .auto => try saveMcpOAuthFileCredentials(allocator, codex_home, server_name, server_url, client_id, tokens),
        .keyring => try saveMcpOAuthKeyringCredentials(allocator, server_name, server_url, client_id, tokens),
    }
}

fn saveMcpOAuthFileCredentials(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    server_url: []const u8,
    client_id: []const u8,
    tokens: McpOAuthTokens,
) !void {
    const path = try std.fs.path.join(allocator, &.{ codex_home, ".credentials.json" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (bytes) |owned| allocator.free(owned);

    var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_opt) |*parsed| parsed.deinit();
    if (bytes) |existing| {
        parsed_opt = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch return error.InvalidMcpOAuthCredentialsFile;
        if (parsed_opt.?.value != .object) return error.InvalidMcpOAuthCredentialsFile;
    }

    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var wrote: usize = 0;
    if (parsed_opt) |parsed| {
        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
            if (wrote > 0) try output.append(allocator, ',');
            try appendJsonString(allocator, &output, entry.key_ptr.*);
            try output.append(allocator, ':');
            const rendered_value = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
            defer allocator.free(rendered_value);
            try output.appendSlice(allocator, rendered_value);
            wrote += 1;
        }
    }
    if (wrote > 0) try output.append(allocator, ',');
    try appendJsonString(allocator, &output, key);
    try output.append(allocator, ':');
    try appendMcpOAuthFallbackEntryJson(allocator, &output, server_name, server_url, client_id, tokens);
    try output.append(allocator, '}');

    const rendered = try output.toOwnedSlice(allocator);
    defer allocator.free(rendered);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), codex_home);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = rendered });
}

fn saveMcpOAuthKeyringCredentials(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    server_url: []const u8,
    client_id: []const u8,
    tokens: McpOAuthTokens,
) !void {
    if (!mcpOAuthKeyringSupported()) return error.UnsupportedMcpOAuthKeyring;
    const key = try computeMcpOAuthStoreKey(allocator, server_name, server_url);
    defer allocator.free(key);
    const serialized = try renderMcpOAuthStoredTokensJson(allocator, server_name, server_url, client_id, tokens);
    defer allocator.free(serialized);
    const argv = [_][]const u8{ security_binary, "add-generic-password", "-U", "-s", mcp_oauth_keyring_service, "-a", key, "-w", serialized };
    var result = try runSecurityCommand(allocator, argv[0..]);
    defer result.deinit(allocator);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.McpOAuthKeyringUnavailable;
}

fn appendMcpOAuthFallbackEntryJson(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    server_name: []const u8,
    server_url: []const u8,
    client_id: []const u8,
    tokens: McpOAuthTokens,
) !void {
    try output.append(allocator, '{');
    try output.appendSlice(allocator, "\"server_name\":");
    try appendJsonString(allocator, output, server_name);
    try output.appendSlice(allocator, ",\"server_url\":");
    try appendJsonString(allocator, output, server_url);
    try output.appendSlice(allocator, ",\"client_id\":");
    try appendJsonString(allocator, output, client_id);
    try output.appendSlice(allocator, ",\"access_token\":");
    try appendJsonString(allocator, output, tokens.access_token);
    if (tokens.expires_at_ms) |expires_at| {
        try output.appendSlice(allocator, ",\"expires_at\":");
        try appendUnsigned(allocator, output, expires_at);
    }
    if (tokens.refresh_token) |refresh_token| {
        try output.appendSlice(allocator, ",\"refresh_token\":");
        try appendJsonString(allocator, output, refresh_token);
    }
    if (tokens.scopes.items.len > 0) {
        try output.appendSlice(allocator, ",\"scopes\":");
        try appendJsonStringArrayValue(allocator, output, tokens.scopes.items);
    }
    try output.append(allocator, '}');
}

fn renderMcpOAuthStoredTokensJson(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    server_url: []const u8,
    client_id: []const u8,
    tokens: McpOAuthTokens,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    try output.appendSlice(allocator, "\"server_name\":");
    try appendJsonString(allocator, &output, server_name);
    try output.appendSlice(allocator, ",\"url\":");
    try appendJsonString(allocator, &output, server_url);
    try output.appendSlice(allocator, ",\"client_id\":");
    try appendJsonString(allocator, &output, client_id);
    try output.appendSlice(allocator, ",\"token_response\":{\"access_token\":");
    try appendJsonString(allocator, &output, tokens.access_token);
    try output.appendSlice(allocator, ",\"token_type\":\"Bearer\"");
    if (tokens.expires_at_ms) |expires_at| {
        const now_ms: u64 = @intCast(currentUnixMilliseconds());
        const expires_in = if (expires_at > now_ms) @divTrunc(expires_at - now_ms, std.time.ms_per_s) else 0;
        try output.appendSlice(allocator, ",\"expires_in\":");
        try appendUnsigned(allocator, &output, expires_in);
    }
    if (tokens.refresh_token) |refresh_token| {
        try output.appendSlice(allocator, ",\"refresh_token\":");
        try appendJsonString(allocator, &output, refresh_token);
    }
    if (tokens.scopes.items.len > 0) {
        const scope_text = try joinScopes(allocator, tokens.scopes.items, " ");
        defer allocator.free(scope_text);
        try output.appendSlice(allocator, ",\"scope\":");
        try appendJsonString(allocator, &output, scope_text);
    }
    try output.append(allocator, '}');
    if (tokens.expires_at_ms) |expires_at| {
        try output.appendSlice(allocator, ",\"expires_at\":");
        try appendUnsigned(allocator, &output, expires_at);
    }
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

fn mcpOAuthFetch(
    allocator: std.mem.Allocator,
    server: McpServer,
    method: std.http.Method,
    url: []const u8,
    content_type: ?[]const u8,
    payload: ?[]const u8,
) !McpOAuthHttpResponse {
    var headers = try buildMcpOAuthHttpHeaders(allocator, server, content_type);
    defer headers.deinit(allocator);

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &response_body.writer,
        .extra_headers = headers.headers.items,
    });
    return .{ .status = result.status, .body = try response_body.toOwnedSlice() };
}

fn buildMcpOAuthHttpHeaders(
    allocator: std.mem.Allocator,
    server: McpServer,
    content_type: ?[]const u8,
) !McpOAuthHttpHeaders {
    var headers = McpOAuthHttpHeaders{};
    errdefer headers.deinit(allocator);
    try headers.headers.append(allocator, .{ .name = "MCP-Protocol-Version", .value = "2024-11-05" });
    try headers.headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (content_type) |value| try headers.headers.append(allocator, .{ .name = "Content-Type", .value = value });
    for (server.http_headers.items) |entry| {
        try headers.headers.append(allocator, .{ .name = entry.key, .value = entry.value });
    }
    for (server.env_http_headers.items) |entry| {
        const value = try env.getOwnedDynamic(allocator, entry.value) orelse continue;
        errdefer allocator.free(value);
        try headers.owned_values.append(allocator, value);
        try headers.headers.append(allocator, .{ .name = entry.key, .value = value });
    }
    return headers;
}

fn bindMcpOAuthCallbackServer(callback_port: ?u16, callback_url: ?[]const u8) !std.Io.net.Server {
    const io = std.Io.Threaded.global_single_threaded.io();
    const port = callback_port orelse 0;
    var address = try std.Io.net.IpAddress.parse(mcpOAuthCallbackBindHost(callback_url), port);
    return address.listen(io, .{ .reuse_address = true });
}

fn mcpOAuthCallbackBindHost(callback_url: ?[]const u8) []const u8 {
    const url = callback_url orelse return "127.0.0.1";
    const parsed = std.Uri.parse(url) catch return "127.0.0.1";
    const host_component = parsed.host orelse return "127.0.0.1";
    const host = uriComponentBytes(host_component);
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1"))
    {
        return "127.0.0.1";
    }
    return "0.0.0.0";
}

fn mcpOAuthRedirectUri(
    allocator: std.mem.Allocator,
    server: *const std.Io.net.Server,
    callback_url: ?[]const u8,
) ![]const u8 {
    if (callback_url) |url| return allocator.dupe(u8, url);
    const callback_port = server.socket.address.getPort();
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{callback_port});
}

fn mcpOAuthCallbackPathFromRedirectUri(allocator: std.mem.Allocator, redirect_uri: []const u8) ![]const u8 {
    const parsed = std.Uri.parse(redirect_uri) catch return error.InvalidMcpOAuthCallbackUrl;
    const raw_path = uriComponentBytes(parsed.path);
    if (raw_path.len == 0) return allocator.dupe(u8, "/");
    return allocator.dupe(u8, raw_path);
}

fn uriComponentBytes(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |value| value,
    };
}

fn waitForMcpOAuthCallback(
    allocator: std.mem.Allocator,
    server: *std.Io.net.Server,
    expected_path: []const u8,
    expected_state: []const u8,
    timeout_secs: ?i64,
) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const deadline_ms = mcpOAuthCallbackDeadlineMs(timeout_secs);
    while (true) {
        if (deadline_ms) |deadline| {
            const remaining_ms = deadline - currentUnixMilliseconds();
            if (remaining_ms <= 0) return error.McpOAuthCallbackTimeout;
            if (!try pollMcpOAuthCallbackServer(server, remaining_ms)) return error.McpOAuthCallbackTimeout;
        }
        var stream = try server.accept(io);
        defer stream.close(io);

        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var http_server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            else => return err,
        };

        if (try handleMcpOAuthCallbackRequest(allocator, &request, expected_path, expected_state)) |code| return code;
    }
}

fn mcpOAuthCallbackDeadlineMs(timeout_secs: ?i64) ?i64 {
    const raw_secs = timeout_secs orelse return null;
    const secs = @max(raw_secs, 1);
    const max_secs = @divTrunc(std.math.maxInt(i64), std.time.ms_per_s);
    if (secs >= max_secs) return std.math.maxInt(i64);
    return currentUnixMilliseconds() + secs * std.time.ms_per_s;
}

fn pollMcpOAuthCallbackServer(server: *std.Io.net.Server, timeout_ms: i64) !bool {
    const poll_timeout: i32 = if (timeout_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(timeout_ms);
    var fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL),
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, poll_timeout);
    if (ready == 0) return false;
    const revents: u16 = @bitCast(fds[0].revents);
    const terminal_events = @as(u16, @intCast(std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL));
    if ((revents & terminal_events) != 0) return error.McpOAuthCallbackServerClosed;
    const readable_events = @as(u16, @intCast(std.posix.POLL.IN));
    return (revents & readable_events) != 0;
}

fn handleMcpOAuthCallbackRequest(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    expected_path: []const u8,
    expected_state: []const u8,
) !?[]const u8 {
    const path, const query = splitTarget(request.head.target);
    if (!std.mem.eql(u8, path, expected_path)) {
        try respondText(request, .not_found, "Not Found\n");
        return null;
    }
    const callback_state = try queryParam(allocator, query, "state");
    defer if (callback_state) |value| allocator.free(value);
    if (callback_state == null or !std.mem.eql(u8, callback_state.?, expected_state)) {
        try respondText(request, .bad_request, "State mismatch\n");
        return error.McpOAuthStateMismatch;
    }
    const error_code = try queryParam(allocator, query, "error");
    defer if (error_code) |value| allocator.free(value);
    if (error_code) |value| {
        const description = try queryParam(allocator, query, "error_description");
        defer if (description) |text| allocator.free(text);
        const message = if (description) |text|
            try std.fmt.allocPrint(allocator, "OAuth login failed: {s}\n", .{text})
        else
            try std.fmt.allocPrint(allocator, "OAuth login failed: {s}\n", .{value});
        defer allocator.free(message);
        try respondText(request, .bad_request, message);
        return error.McpOAuthProviderError;
    }
    const code = try queryParam(allocator, query, "code");
    if (code == null or code.?.len == 0) {
        defer if (code) |value| allocator.free(value);
        try respondText(request, .bad_request, "Missing authorization code\n");
        return error.MissingMcpOAuthAuthorizationCode;
    }
    try respondText(
        request,
        .ok,
        "<!doctype html><meta charset=\"utf-8\"><title>MCP login complete</title><h1>MCP login complete</h1><p>You can return to the terminal.</p>",
    );
    return code.?;
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

fn buildMcpOAuthAuthorizationUrl(
    allocator: std.mem.Allocator,
    authorization_endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    pkce: PkceCodes,
    state: []const u8,
    scopes: []const []const u8,
    oauth_resource: ?[]const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, authorization_endpoint);
    try appendQueryParam(allocator, &out, "response_type", "code");
    try appendQueryParam(allocator, &out, "client_id", client_id);
    try appendQueryParam(allocator, &out, "redirect_uri", redirect_uri);
    try appendQueryParam(allocator, &out, "code_challenge", pkce.code_challenge);
    try appendQueryParam(allocator, &out, "code_challenge_method", "S256");
    try appendQueryParam(allocator, &out, "state", state);
    if (scopes.len > 0) {
        const scope_text = try joinScopes(allocator, scopes, " ");
        defer allocator.free(scope_text);
        try appendQueryParam(allocator, &out, "scope", scope_text);
    }
    if (oauth_resource) |resource| {
        if (std.mem.trim(u8, resource, " \t\r\n").len > 0) {
            try appendQueryParam(allocator, &out, "resource", resource);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendQueryParam(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    const separator: u8 = if (std.mem.indexOfScalar(u8, out.items, '?') == null) '?' else '&';
    try out.append(allocator, separator);
    try percentEncode(allocator, out, name);
    try out.append(allocator, '=');
    try percentEncode(allocator, out, value);
}

fn appendFormField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '&');
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

fn generateMcpOAuthPkce(allocator: std.mem.Allocator) !PkceCodes {
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
    if (builtin.os.tag != .macos) return;
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

fn printMcpOAuthPrompt(allocator: std.mem.Allocator, server_name: []const u8, authorization_url: []const u8) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "Authorize `{s}` by opening this URL in your browser:\n{s}\n\n",
        .{ server_name, authorization_url },
    );
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
}

fn shouldSkipMcpOAuthBrowser(allocator: std.mem.Allocator) !bool {
    const value = try env.getOwned(allocator, "CODEX_MCP_OAUTH_SKIP_BROWSER") orelse return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn appendSpaceSeparatedScopes(allocator: std.mem.Allocator, scopes: *std.ArrayList([]const u8), text: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (parts.next()) |scope| {
        try scopes.append(allocator, try allocator.dupe(u8, scope));
    }
}

fn joinScopes(allocator: std.mem.Allocator, scopes: []const []const u8, separator: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (scopes, 0..) |scope, index| {
        if (index > 0) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, scope);
    }
    return out.toOwnedSlice(allocator);
}

fn appendJsonStringArrayValue(allocator: std.mem.Allocator, output: *std.ArrayList(u8), values: []const []const u8) !void {
    try output.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendJsonString(allocator, output, value);
    }
    try output.append(allocator, ']');
}

fn oauthJsonUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch null,
        .string => |text| std.fmt.parseUnsigned(u64, text, 10) catch null,
        else => null,
    };
}

fn statusIsSuccess(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

fn currentUnixMilliseconds() i64 {
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    return @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
}

fn computeMcpOAuthStoreKey(allocator: std.mem.Allocator, server_name: []const u8, server_url: []const u8) ![]const u8 {
    const url_json = try std.json.Stringify.valueAlloc(allocator, server_url, .{});
    defer allocator.free(url_json);
    const payload = try std.fmt.allocPrint(allocator, "{{\"headers\":{{}},\"type\":\"http\",\"url\":{s}}}", .{url_json});
    defer allocator.free(payload);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = "0123456789abcdef";
    var prefix: [16]u8 = undefined;
    for (digest[0..8], 0..) |byte, index| {
        prefix[index * 2] = hex[byte >> 4];
        prefix[index * 2 + 1] = hex[byte & 0x0f];
    }
    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ server_name, prefix[0..] });
}

fn writeServersConfig(allocator: std.mem.Allocator, codex_home: []const u8, original_config: []const u8, servers: McpServers) !void {
    const updated = try renderUpdatedConfig(allocator, original_config, servers);
    defer allocator.free(updated);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, codex_home);
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = updated });
}

fn parseServers(allocator: std.mem.Allocator, bytes: []const u8) !McpServers {
    var servers = McpServers{};
    errdefer servers.deinit(allocator);

    var current_name: ?[]const u8 = null;
    var current_subtable: ?[]const u8 = null;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const section = parseMcpSection(line);
            current_name = section.name;
            current_subtable = section.subtable;
            continue;
        }
        const name = current_name orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        var server = try servers.getOrAdd(allocator, name);
        if (current_subtable) |subtable| {
            if (std.mem.eql(u8, subtable, "env")) {
                if (try parseTomlString(allocator, value)) |env_value| {
                    errdefer allocator.free(env_value);
                    try server.env_vars.append(allocator, .{
                        .key = try allocator.dupe(u8, key),
                        .value = env_value,
                    });
                }
            } else if (std.mem.eql(u8, subtable, "http_headers")) {
                try appendTomlKeyValue(allocator, &server.http_headers, key, value);
            } else if (std.mem.eql(u8, subtable, "env_http_headers")) {
                try appendTomlKeyValue(allocator, &server.env_http_headers, key, value);
            }
            continue;
        }
        if (std.mem.eql(u8, key, "command")) {
            if (try parseTomlString(allocator, value)) |command| {
                if (server.command) |existing| allocator.free(existing);
                server.command = command;
                server.kind = .stdio;
            }
        } else if (std.mem.eql(u8, key, "url")) {
            if (try parseTomlString(allocator, value)) |url| {
                if (server.url) |existing| allocator.free(existing);
                server.url = url;
                server.kind = .streamable_http;
            }
        } else if (std.mem.eql(u8, key, "bearer_token_env_var")) {
            if (try parseTomlString(allocator, value)) |token_env| {
                if (server.bearer_token_env_var) |existing| allocator.free(existing);
                server.bearer_token_env_var = token_env;
            }
        } else if (std.mem.eql(u8, key, "oauth_resource")) {
            if (try parseTomlString(allocator, value)) |resource| {
                if (server.oauth_resource) |existing| allocator.free(existing);
                server.oauth_resource = resource;
            }
        } else if (std.mem.eql(u8, key, "scopes")) {
            try replaceTomlStringArray(allocator, &server.scopes, value);
        } else if (std.mem.eql(u8, key, "http_headers")) {
            try appendTomlInlineKeyValueTable(allocator, &server.http_headers, value);
        } else if (std.mem.eql(u8, key, "env_http_headers")) {
            try appendTomlInlineKeyValueTable(allocator, &server.env_http_headers, value);
        } else if (std.mem.eql(u8, key, "enabled")) {
            if (std.mem.eql(u8, value, "true")) server.enabled = true;
            if (std.mem.eql(u8, value, "false")) server.enabled = false;
        } else if (std.mem.eql(u8, key, "args")) {
            try replaceArgs(allocator, server, value);
        }
    }
    return servers;
}

fn appendPluginMcpServers(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    config_bytes: []const u8,
    servers: *McpServers,
) !void {
    if (!plugin_config.pluginsFeatureEnabled(config_bytes)) return;

    const plugin_ids = try plugin_config.enabledPluginIds(allocator, config_bytes);
    defer plugin_config.freeStringList(allocator, plugin_ids);
    for (plugin_ids) |plugin_id| {
        const plugin_root = (try plugin_config.localPluginRoot(allocator, codex_home, plugin_id)) orelse continue;
        defer allocator.free(plugin_root);
        try appendPluginMcpFile(allocator, plugin_root, servers);
    }
}

fn appendPluginMcpFile(allocator: std.mem.Allocator, plugin_root: []const u8, servers: *McpServers) !void {
    const path = try std.fs.path.join(allocator, &.{ plugin_root, ".mcp.json" });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return,
        error.OutOfMemory => return err,
        else => return,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const server_map = if (parsed.value.object.get("mcpServers")) |wrapped| blk: {
        if (wrapped != .object) return;
        break :blk wrapped.object;
    } else parsed.value.object;

    var iterator = server_map.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0 or name[0] == '$') continue;
        if (servers.findIndex(name) != null) continue;
        const server = try parsePluginMcpServer(allocator, name, entry.value_ptr.*);
        if (server) |value| {
            errdefer {
                var owned = value;
                owned.deinit(allocator);
            }
            try servers.items.append(allocator, value);
        }
    }
}

fn parsePluginMcpServer(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !?McpServer {
    if (value != .object) return null;
    var server = McpServer{ .name = try allocator.dupe(u8, name) };
    errdefer server.deinit(allocator);

    if (jsonStringField(value.object, "url")) |url| {
        server.kind = .streamable_http;
        server.url = try allocator.dupe(u8, url);
    }
    if (jsonStringField(value.object, "command")) |command| {
        server.kind = .stdio;
        server.command = try allocator.dupe(u8, command);
    }
    if (jsonStringField(value.object, "bearer_token_env_var")) |token_env| {
        server.bearer_token_env_var = try allocator.dupe(u8, token_env);
    } else if (jsonStringField(value.object, "bearerTokenEnvVar")) |token_env| {
        server.bearer_token_env_var = try allocator.dupe(u8, token_env);
    }
    if (jsonStringField(value.object, "oauth_resource")) |resource| {
        server.oauth_resource = try allocator.dupe(u8, resource);
    } else if (jsonStringField(value.object, "oauthResource")) |resource| {
        server.oauth_resource = try allocator.dupe(u8, resource);
    }
    try appendJsonStringArray(allocator, &server.scopes, value.object.get("scopes"));
    try appendJsonStringMap(allocator, &server.http_headers, value.object.get("http_headers"));
    try appendJsonStringMap(allocator, &server.http_headers, value.object.get("httpHeaders"));
    try appendJsonStringMap(allocator, &server.env_http_headers, value.object.get("env_http_headers"));
    try appendJsonStringMap(allocator, &server.env_http_headers, value.object.get("envHttpHeaders"));
    if (value.object.get("enabled")) |enabled| {
        if (enabled == .bool) server.enabled = enabled.bool;
    }
    if (value.object.get("args")) |args_value| {
        if (args_value == .array) {
            for (args_value.array.items) |item| {
                if (item == .string) try server.args.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }
    if (value.object.get("env")) |env_value| {
        if (env_value == .object) {
            var iterator = env_value.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                try server.env_vars.append(allocator, .{
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = try allocator.dupe(u8, entry.value_ptr.*.string),
                });
            }
        }
    }

    if (server.kind == .unknown) {
        server.deinit(allocator);
        return null;
    }
    return server;
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

const McpSection = struct {
    name: ?[]const u8 = null,
    subtable: ?[]const u8 = null,
};

fn parseMcpSection(line: []const u8) McpSection {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return .{};
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, section, "mcp_servers")) return .{};
    if (!std.mem.startsWith(u8, section, "mcp_servers.")) return .{};
    const rest = section["mcp_servers.".len..];
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        return .{ .name = rest[0..dot], .subtable = rest[dot + 1 ..] };
    }
    return .{ .name = rest };
}

fn replaceArgs(allocator: std.mem.Allocator, server: *McpServer, raw: []const u8) !void {
    for (server.args.items) |arg| allocator.free(arg);
    server.args.clearRetainingCapacity();

    try replaceTomlStringArray(allocator, &server.args, raw);
}

fn replaceTomlStringArray(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), raw: []const u8) !void {
    for (values.items) |value| allocator.free(value);
    values.clearRetainingCapacity();

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return;
    var index: usize = 1;
    while (index + 1 < trimmed.len) : (index += 1) {
        while (index < trimmed.len and (trimmed[index] == ' ' or trimmed[index] == '\t' or trimmed[index] == ',')) index += 1;
        if (index >= trimmed.len or trimmed[index] != '"') continue;
        const start = index;
        index += 1;
        while (index < trimmed.len) : (index += 1) {
            if (trimmed[index] == '\\') {
                index += 1;
                continue;
            }
            if (trimmed[index] == '"') break;
        }
        if (index >= trimmed.len) return;
        const value = try parseTomlString(allocator, trimmed[start .. index + 1]);
        if (value) |owned| try values.append(allocator, owned);
    }
}

fn appendEnvPair(allocator: std.mem.Allocator, server: *McpServer, raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidMcpEnv;
    const key = std.mem.trim(u8, raw[0..eq], " \t");
    if (key.len == 0) return error.InvalidMcpEnv;
    try server.env_vars.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, raw[eq + 1 ..]),
    });
}

fn appendTomlKeyValue(allocator: std.mem.Allocator, entries: *std.ArrayList(KeyValue), raw_key: []const u8, raw_value: []const u8) !void {
    const key = try parseTomlKey(allocator, raw_key);
    errdefer allocator.free(key);
    const value = (try parseTomlString(allocator, raw_value)) orelse {
        allocator.free(key);
        return;
    };
    errdefer allocator.free(value);
    try entries.append(allocator, .{
        .key = key,
        .value = value,
    });
}

fn appendTomlInlineKeyValueTable(allocator: std.mem.Allocator, entries: *std.ArrayList(KeyValue), raw_value: []const u8) !void {
    const contents = try parseInlineTableContents(allocator, raw_value) orelse return;
    defer allocator.free(contents);

    var start: usize = 0;
    while (start < contents.len) {
        const end = findTopLevelComma(contents, start) orelse contents.len;
        const next_start = if (end < contents.len) end + 1 else contents.len;

        const entry = std.mem.trim(u8, contents[start..end], " \t\r\n");
        if (entry.len == 0) {
            start = next_start;
            continue;
        }
        const eq = findTopLevelEquals(entry) orelse return error.InvalidTomlInlineTable;
        const key = std.mem.trim(u8, entry[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, entry[eq + 1 ..], " \t\r\n");
        if (key.len == 0) return error.InvalidTomlInlineTable;
        try appendTomlKeyValue(allocator, entries, key, value);
        start = next_start;
    }
}

fn appendJsonStringMap(allocator: std.mem.Allocator, entries: *std.ArrayList(KeyValue), value: ?std.json.Value) !void {
    const map = value orelse return;
    if (map != .object) return;
    var iterator = map.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try appendKeyValueCopy(allocator, entries, entry.key_ptr.*, entry.value_ptr.string);
    }
}

fn appendJsonStringArray(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array) return;
    for (array.array.items) |item| {
        if (item == .string) try values.append(allocator, try allocator.dupe(u8, item.string));
    }
}

fn appendKeyValueCopy(allocator: std.mem.Allocator, entries: *std.ArrayList(KeyValue), key: []const u8, value: []const u8) !void {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    try entries.append(allocator, .{ .key = key_copy, .value = value_copy });
}

fn renderUpdatedConfig(allocator: std.mem.Allocator, original_config: []const u8, servers: McpServers) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var skip_mcp = false;
    var start: usize = 0;
    while (start < original_config.len) {
        const end = std.mem.indexOfScalarPos(u8, original_config, start, '\n') orelse original_config.len;
        const raw_line = original_config[start..end];
        start = if (end < original_config.len) end + 1 else original_config.len;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            skip_mcp = std.mem.eql(u8, line, "[mcp_servers]") or std.mem.startsWith(u8, line, "[mcp_servers.");
        }
        if (!skip_mcp) {
            try output.appendSlice(allocator, raw_line);
            try output.append(allocator, '\n');
        }
    }
    while (output.items.len > 0 and (output.items[output.items.len - 1] == '\n' or output.items[output.items.len - 1] == '\r')) {
        _ = output.pop();
    }
    if (output.items.len > 0 and servers.items.items.len > 0) {
        try output.appendSlice(allocator, "\n\n");
    }
    try appendServersToml(allocator, &output, servers);
    return output.toOwnedSlice(allocator);
}

fn appendServersToml(allocator: std.mem.Allocator, output: *std.ArrayList(u8), servers: McpServers) !void {
    for (servers.items.items, 0..) |server, index| {
        if (index > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, "[mcp_servers.");
        try output.appendSlice(allocator, server.name);
        try output.appendSlice(allocator, "]\n");
        if (server.kind == .streamable_http) {
            try appendTomlStringField(allocator, output, "url", server.url.?);
            if (server.bearer_token_env_var) |token_env| try appendTomlStringField(allocator, output, "bearer_token_env_var", token_env);
            if (server.oauth_resource) |resource| try appendTomlStringField(allocator, output, "oauth_resource", resource);
            if (server.scopes.items.len > 0) {
                try output.appendSlice(allocator, "scopes = [");
                for (server.scopes.items, 0..) |scope, scope_index| {
                    if (scope_index > 0) try output.appendSlice(allocator, ", ");
                    try appendTomlString(allocator, output, scope);
                }
                try output.appendSlice(allocator, "]\n");
            }
        } else {
            try appendTomlStringField(allocator, output, "command", server.command.?);
            if (server.args.items.len > 0) {
                try output.appendSlice(allocator, "args = [");
                for (server.args.items, 0..) |arg, arg_index| {
                    if (arg_index > 0) try output.appendSlice(allocator, ", ");
                    try appendTomlString(allocator, output, arg);
                }
                try output.appendSlice(allocator, "]\n");
            }
        }
        if (!server.enabled) try output.appendSlice(allocator, "enabled = false\n");
        if (server.env_vars.items.len > 0) {
            try appendTomlKeyValueTable(allocator, output, server.name, "env", server.env_vars.items);
        }
        if (server.http_headers.items.len > 0) {
            try appendTomlKeyValueTable(allocator, output, server.name, "http_headers", server.http_headers.items);
        }
        if (server.env_http_headers.items.len > 0) {
            try appendTomlKeyValueTable(allocator, output, server.name, "env_http_headers", server.env_http_headers.items);
        }
    }
}

fn appendTomlKeyValueTable(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    server_name: []const u8,
    table_name: []const u8,
    entries: []const KeyValue,
) !void {
    try output.append(allocator, '\n');
    try output.appendSlice(allocator, "[mcp_servers.");
    try output.appendSlice(allocator, server_name);
    try output.append(allocator, '.');
    try output.appendSlice(allocator, table_name);
    try output.appendSlice(allocator, "]\n");
    for (entries) |entry| {
        try output.appendSlice(allocator, entry.key);
        try output.appendSlice(allocator, " = ");
        try appendTomlString(allocator, output, entry.value);
        try output.append(allocator, '\n');
    }
}

fn appendTomlStringField(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try output.appendSlice(allocator, key);
    try output.appendSlice(allocator, " = ");
    try appendTomlString(allocator, output, value);
    try output.append(allocator, '\n');
}

fn appendTomlString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
}

fn parseTomlKey(allocator: std.mem.Allocator, raw_key: []const u8) ![]const u8 {
    if (raw_key.len >= 2 and raw_key[0] == '"') {
        if (try parseTomlString(allocator, raw_key)) |value| return value;
        return error.InvalidTomlString;
    }
    return allocator.dupe(u8, raw_key);
}

fn parseInlineTableContents(allocator: std.mem.Allocator, rhs: []const u8) !?[]const u8 {
    if (rhs.len < 2 or rhs[0] != '{') return null;
    const end = std.mem.lastIndexOfScalar(u8, rhs, '}') orelse return error.InvalidTomlInlineTable;
    return try allocator.dupe(u8, std.mem.trim(u8, rhs[1..end], " \t\r\n"));
}

fn findTopLevelComma(value: []const u8, start: usize) ?usize {
    var in_string = false;
    var index = start;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (in_string) {
            if (byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == ',') {
            return index;
        }
    }
    return null;
}

fn findTopLevelEquals(value: []const u8) ?usize {
    var in_string = false;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (in_string) {
            if (byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '=') {
            return index;
        }
    }
    return null;
}

fn parseTomlString(allocator: std.mem.Allocator, rhs: []const u8) !?[]const u8 {
    if (rhs.len < 2 or rhs[0] != '"') return null;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 1;
    while (index < rhs.len) : (index += 1) {
        const byte = rhs[index];
        if (byte == '"') return try output.toOwnedSlice(allocator);
        if (byte != '\\') {
            try output.append(allocator, byte);
            continue;
        }
        index += 1;
        if (index >= rhs.len) return error.InvalidTomlString;
        const escaped: u8 = switch (rhs[index]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidTomlString,
        };
        try output.append(allocator, escaped);
    }
    return error.InvalidTomlString;
}

fn renderJsonList(allocator: std.mem.Allocator, codex_home: []const u8, config_bytes: []const u8, servers: McpServers) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "[\n");
    for (servers.items.items, 0..) |server, index| {
        if (index > 0) try output.appendSlice(allocator, ",\n");
        try output.appendSlice(allocator, "  ");
        const auth_status = try mcpAuthStatusForServer(allocator, codex_home, config_bytes, server);
        const rendered = try renderJsonServerWithAuthStatus(allocator, server, auth_status);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
    }
    try output.appendSlice(allocator, "\n]\n");
    return output.toOwnedSlice(allocator);
}

fn renderJsonServer(allocator: std.mem.Allocator, server: McpServer) ![]const u8 {
    return renderJsonServerWithAuthStatus(allocator, server, null);
}

fn renderJsonServerWithAuthStatus(allocator: std.mem.Allocator, server: McpServer, auth_status: ?McpAuthStatus) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"name\": ");
    try appendJsonString(allocator, &output, server.name);
    try output.appendSlice(allocator, ", \"enabled\": ");
    try output.appendSlice(allocator, if (server.enabled) "true" else "false");
    try output.appendSlice(allocator, ", \"transport\": {\"type\": ");
    try appendJsonString(allocator, &output, kindLabel(server));
    if (server.kind == .streamable_http) {
        try output.appendSlice(allocator, ", \"url\": ");
        try appendJsonString(allocator, &output, server.url.?);
        if (server.bearer_token_env_var) |token_env| {
            try output.appendSlice(allocator, ", \"bearer_token_env_var\": ");
            try appendJsonString(allocator, &output, token_env);
        }
        try output.appendSlice(allocator, ", \"http_headers\": ");
        try appendOptionalKeyValueJsonObject(allocator, &output, server.http_headers.items);
        try output.appendSlice(allocator, ", \"env_http_headers\": ");
        try appendOptionalKeyValueJsonObject(allocator, &output, server.env_http_headers.items);
    } else if (server.kind == .stdio) {
        try output.appendSlice(allocator, ", \"command\": ");
        try appendJsonString(allocator, &output, server.command.?);
        try output.appendSlice(allocator, ", \"args\": [");
        for (server.args.items, 0..) |arg, index| {
            if (index > 0) try output.appendSlice(allocator, ", ");
            try appendJsonString(allocator, &output, arg);
        }
        try output.append(allocator, ']');
    }
    try output.append(allocator, '}');
    if (auth_status) |status| {
        try output.appendSlice(allocator, ", \"auth_status\": ");
        try appendJsonString(allocator, &output, status.json());
    }
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

fn appendOptionalKeyValueJsonObject(allocator: std.mem.Allocator, output: *std.ArrayList(u8), entries: []const KeyValue) !void {
    if (entries.len == 0) {
        try output.appendSlice(allocator, "null");
        return;
    }
    try output.append(allocator, '{');
    for (entries, 0..) |entry, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try appendJsonString(allocator, output, entry.key);
        try output.appendSlice(allocator, ": ");
        try appendJsonString(allocator, output, entry.value);
    }
    try output.append(allocator, '}');
}

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(rendered);
    try output.appendSlice(allocator, rendered);
}

fn appendUnsigned(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: u64) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(rendered);
    try output.appendSlice(allocator, rendered);
}

fn printServer(allocator: std.mem.Allocator, server: McpServer) !void {
    const header = try std.fmt.allocPrint(allocator, "{s}\n  enabled: {s}\n  transport: {s}\n", .{
        server.name,
        statusLabel(server.enabled),
        kindLabel(server),
    });
    defer allocator.free(header);
    try cli_utils.writeStdout(header);
    if (server.kind == .streamable_http) {
        const token = server.bearer_token_env_var orelse "-";
        const http_headers = try headerDisplay(allocator, server.http_headers.items, true);
        defer allocator.free(http_headers);
        const env_http_headers = try headerDisplay(allocator, server.env_http_headers.items, false);
        defer allocator.free(env_http_headers);
        const body = try std.fmt.allocPrint(allocator, "  url: {s}\n  bearer_token_env_var: {s}\n  http_headers: {s}\n  env_http_headers: {s}\n", .{ server.url.?, token, http_headers, env_http_headers });
        defer allocator.free(body);
        try cli_utils.writeStdout(body);
    } else if (server.kind == .stdio) {
        const args_display = try cli_utils.joinWithSpaces(allocator, server.args.items);
        defer allocator.free(args_display);
        const body = try std.fmt.allocPrint(allocator, "  command: {s}\n  args: {s}\n", .{ server.command.?, if (args_display.len == 0) "-" else args_display });
        defer allocator.free(body);
        try cli_utils.writeStdout(body);
    }
}

fn appendVerboseServerStatus(allocator: std.mem.Allocator, output: *std.ArrayList(u8), server: McpServer) !void {
    try output.appendSlice(allocator, "  ");
    try output.appendSlice(allocator, server.name);
    try output.append(allocator, '\n');
    try output.appendSlice(allocator, "    enabled: ");
    try output.appendSlice(allocator, statusLabel(server.enabled));
    try output.append(allocator, '\n');
    try output.appendSlice(allocator, "    transport: ");
    try output.appendSlice(allocator, kindLabel(server));
    try output.append(allocator, '\n');

    if (server.kind == .streamable_http) {
        try output.appendSlice(allocator, "    url: ");
        try output.appendSlice(allocator, server.url orelse "-");
        try output.append(allocator, '\n');
        if (server.bearer_token_env_var) |token_env| {
            try output.appendSlice(allocator, "    bearer_token_env_var: ");
            try output.appendSlice(allocator, token_env);
            try output.append(allocator, '\n');
        }
        const http_headers = try headerDisplay(allocator, server.http_headers.items, true);
        defer allocator.free(http_headers);
        try output.appendSlice(allocator, "    http_headers: ");
        try output.appendSlice(allocator, http_headers);
        try output.append(allocator, '\n');
        const env_http_headers = try headerDisplay(allocator, server.env_http_headers.items, false);
        defer allocator.free(env_http_headers);
        try output.appendSlice(allocator, "    env_http_headers: ");
        try output.appendSlice(allocator, env_http_headers);
        try output.append(allocator, '\n');
        return;
    }

    if (server.kind == .stdio) {
        try output.appendSlice(allocator, "    command: ");
        try output.appendSlice(allocator, server.command orelse "-");
        try output.append(allocator, '\n');
        const args_display = try cli_utils.joinWithSpaces(allocator, server.args.items);
        defer allocator.free(args_display);
        try output.appendSlice(allocator, "    args: ");
        try output.appendSlice(allocator, if (args_display.len == 0) "-" else args_display);
        try output.append(allocator, '\n');
        if (server.env_vars.items.len > 0) {
            try output.appendSlice(allocator, "    env: ");
            try output.appendSlice(allocator, if (server.env_vars.items.len == 1) "1 variable" else "multiple variables");
            try output.append(allocator, '\n');
        }
    }
}

fn headerDisplay(allocator: std.mem.Allocator, entries: []const KeyValue, mask_values: bool) ![]const u8 {
    if (entries.len == 0) return allocator.dupe(u8, "-");

    const sorted = try allocator.dupe(KeyValue, entries);
    defer allocator.free(sorted);
    std.mem.sort(KeyValue, sorted, {}, keyValueLessThan);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (sorted, 0..) |entry, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, entry.key);
        try output.append(allocator, '=');
        if (mask_values) {
            try output.appendSlice(allocator, "*****");
        } else {
            try output.appendSlice(allocator, entry.value);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn keyValueLessThan(_: void, lhs: KeyValue, rhs: KeyValue) bool {
    return std.mem.lessThan(u8, lhs.key, rhs.key);
}

fn kindLabel(server: McpServer) []const u8 {
    return switch (server.kind) {
        .stdio => "stdio",
        .streamable_http => "streamable_http",
        .unknown => "unknown",
    };
}

fn statusLabel(enabled: bool) []const u8 {
    return if (enabled) "enabled" else "disabled";
}

fn validateServerName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidMcpServerName;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return error.InvalidMcpServerName;
    }
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig mcp list [--json]
        \\  codex-zig mcp get NAME [--json]
        \\  codex-zig mcp add NAME (--url URL | -- COMMAND...)
        \\  codex-zig mcp remove NAME
        \\  codex-zig mcp login NAME [--scopes SCOPE,SCOPE]
        \\  codex-zig mcp logout NAME
        \\
    , .{});
}

fn printListHelp() void {
    std.debug.print("Usage:\n  codex-zig mcp list [--json]\n", .{});
}

fn printGetHelp() void {
    std.debug.print("Usage:\n  codex-zig mcp get NAME [--json]\n", .{});
}

fn printAddHelp() void {
    std.debug.print("Usage:\n  codex-zig mcp add NAME (--url URL | -- COMMAND...)\n", .{});
}

fn printLoginHelp() void {
    std.debug.print("Usage:\n  codex-zig mcp login NAME [--scopes SCOPE,SCOPE]\n", .{});
}

test "mcp config parses and renders stdio and http servers" {
    const allocator = std.testing.allocator;
    const original =
        \\model = "demo"
        \\
        \\[mcp_servers.docs]
        \\command = "docs-server"
        \\args = ["--stdio"]
        \\
        \\[mcp_servers.docs.env]
        \\TOKEN = "abc"
        \\
        \\[mcp_servers.remote]
        \\url = "https://example.com/mcp"
        \\bearer_token_env_var = "TOKEN_ENV"
        \\enabled = false
        \\
    ;

    var servers = try parseServers(allocator, original);
    defer servers.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), servers.items.items.len);
    try std.testing.expectEqualStrings("docs-server", servers.get("docs").?.command.?);
    try std.testing.expectEqualStrings("--stdio", servers.get("docs").?.args.items[0]);
    try std.testing.expectEqualStrings("https://example.com/mcp", servers.get("remote").?.url.?);
    try std.testing.expect(!servers.get("remote").?.enabled);

    const rendered = try renderUpdatedConfig(allocator, original, servers);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "model = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mcp_servers.docs]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[mcp_servers.remote]") != null);
}

test "mcp oauth store key matches Rust fallback format" {
    const allocator = std.testing.allocator;
    const key = try computeMcpOAuthStoreKey(allocator, "remote", "https://example.com/mcp");
    defer allocator.free(key);
    try std.testing.expectEqualStrings("remote|6fe6427c8c9125c8", key);
}

test "mcp oauth file logout removes only matching credentials" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const remote_key = try computeMcpOAuthStoreKey(allocator, "remote", "https://example.com/mcp");
    defer allocator.free(remote_key);
    const other_key = try computeMcpOAuthStoreKey(allocator, "other", "https://other.example/mcp");
    defer allocator.free(other_key);

    const credentials = try std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"server_name\":\"remote\",\"server_url\":\"https://example.com/mcp\",\"client_id\":\"client\",\"access_token\":\"access\"}},\"{s}\":{{\"server_name\":\"other\",\"server_url\":\"https://other.example/mcp\",\"client_id\":\"client\",\"access_token\":\"other\"}}}}",
        .{ remote_key, other_key },
    );
    defer allocator.free(credentials);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = ".credentials.json",
        .data = credentials,
    });

    try std.testing.expect(try deleteMcpOAuthFileCredentials(allocator, codex_home, "remote", "https://example.com/mcp"));
    const updated = try dir.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".credentials.json", allocator, .limited(4096));
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, remote_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, other_key) != null);
    try std.testing.expect(!try deleteMcpOAuthFileCredentials(allocator, codex_home, "remote", "https://example.com/mcp"));
}

test "mcp oauth file logout deletes empty credentials file" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const remote_key = try computeMcpOAuthStoreKey(allocator, "remote", "https://example.com/mcp");
    defer allocator.free(remote_key);
    const credentials = try std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"server_name\":\"remote\",\"server_url\":\"https://example.com/mcp\",\"client_id\":\"client\",\"access_token\":\"access\"}}}}",
        .{remote_key},
    );
    defer allocator.free(credentials);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = ".credentials.json",
        .data = credentials,
    });

    try std.testing.expect(try deleteMcpOAuthFileCredentials(allocator, codex_home, "remote", "https://example.com/mcp"));
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.Io.Threaded.global_single_threaded.io(), ".credentials.json", .{}));
}

test "mcp oauth keyring security exit classification" {
    try std.testing.expect(try classifySecurityGenericPasswordResult(.{ .exited = 0 }));
    try std.testing.expect(!try classifySecurityGenericPasswordResult(.{ .exited = 44 }));
    try std.testing.expectError(error.McpOAuthKeyringUnavailable, classifySecurityGenericPasswordResult(.{ .exited = 1 }));
}

test "mcp oauth stored keyring tokens expose access token" {
    const allocator = std.testing.allocator;
    const access_token = try readMcpOAuthStoredTokensAccessToken(allocator,
        \\{"server_name":"remote","url":"https://example.com/mcp","client_id":"client","token_response":{"access_token":"keyring-access","token_type":"Bearer"}}
    );
    defer if (access_token) |token| allocator.free(token);
    try std.testing.expectEqualStrings("keyring-access", access_token.?);
}

test "mcp oauth access token auto falls back to file credentials" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const remote_key = try computeMcpOAuthStoreKey(allocator, "remote", "https://example.com/mcp");
    defer allocator.free(remote_key);
    const credentials = try std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"server_name\":\"remote\",\"server_url\":\"https://example.com/mcp\",\"client_id\":\"client\",\"access_token\":\"file-access\"}}}}",
        .{remote_key},
    );
    defer allocator.free(credentials);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = ".credentials.json",
        .data = credentials,
    });

    const access_token = try readMcpOAuthAccessToken(allocator, codex_home, "", "remote", "https://example.com/mcp");
    defer if (access_token) |token| allocator.free(token);
    try std.testing.expectEqualStrings("file-access", access_token.?);
}

test "mcp list auth status reports bearer and file oauth credentials" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const config_bytes =
        \\mcp_oauth_credentials_store = "file"
        \\
        \\[mcp_servers.remote]
        \\url = "https://example.com/mcp"
        \\
        \\[mcp_servers.bearer]
        \\url = "https://bearer.example/mcp"
        \\bearer_token_env_var = "MCP_TOKEN"
        \\
        \\[mcp_servers.docs]
        \\command = "docs-server"
        \\
    ;
    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const remote_key = try computeMcpOAuthStoreKey(allocator, "remote", "https://example.com/mcp");
    defer allocator.free(remote_key);
    const credentials = try std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"server_name\":\"remote\",\"server_url\":\"https://example.com/mcp\",\"client_id\":\"client\",\"access_token\":\"access\"}}}}",
        .{remote_key},
    );
    defer allocator.free(credentials);
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = ".credentials.json",
        .data = credentials,
    });

    var servers = try parseServers(allocator, config_bytes);
    defer servers.deinit(allocator);

    try std.testing.expectEqual(McpAuthStatus.oauth, try mcpAuthStatusForServer(allocator, codex_home, config_bytes, servers.get("remote").?.*));
    try std.testing.expectEqual(McpAuthStatus.bearer_token, try mcpAuthStatusForServer(allocator, codex_home, config_bytes, servers.get("bearer").?.*));
    try std.testing.expectEqual(McpAuthStatus.unsupported, try mcpAuthStatusForServer(allocator, codex_home, config_bytes, servers.get("docs").?.*));

    const rendered = try renderJsonList(allocator, codex_home, config_bytes, servers);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"auth_status\": \"OAuth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"auth_status\": \"BearerToken\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"auth_status\": \"Unsupported\"") != null);
}

test "mcp streamable http headers parse inline and render" {
    const allocator = std.testing.allocator;
    const config_bytes =
        \\[mcp_servers.remote]
        \\url = "https://example.com/mcp"
        \\http_headers = { "X-Remote-Static" = "remote,static", "X-Second" = "two" }
        \\env_http_headers = { "X-Remote-Env" = "REMOTE_HEADER_ENV" }
        \\
    ;

    var servers = try parseServers(allocator, config_bytes);
    defer servers.deinit(allocator);
    const remote = servers.get("remote").?;
    try std.testing.expectEqual(@as(usize, 2), remote.http_headers.items.len);
    try std.testing.expectEqualStrings("X-Remote-Static", remote.http_headers.items[0].key);
    try std.testing.expectEqualStrings("remote,static", remote.http_headers.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), remote.env_http_headers.items.len);
    try std.testing.expectEqualStrings("X-Remote-Env", remote.env_http_headers.items[0].key);
    try std.testing.expectEqualStrings("REMOTE_HEADER_ENV", remote.env_http_headers.items[0].value);

    const rendered = try renderJsonServer(allocator, remote.*);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"http_headers\": {\"X-Remote-Static\": \"remote,static\", \"X-Second\": \"two\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"env_http_headers\": {\"X-Remote-Env\": \"REMOTE_HEADER_ENV\"}") != null);

    const masked = try headerDisplay(allocator, remote.http_headers.items, true);
    defer allocator.free(masked);
    try std.testing.expectEqualStrings("X-Remote-Static=*****, X-Second=*****", masked);
}

test "mcp oauth discovery paths match Rust candidate order" {
    const allocator = std.testing.allocator;
    var root = try discoveryUrls(allocator, "https://example.com");
    defer {
        for (root.items) |candidate| allocator.free(candidate);
        root.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), root.items.len);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-authorization-server", root.items[0]);

    var nested = try discoveryUrls(allocator, "https://example.com/mcp/v1?ignored=true");
    defer {
        for (nested.items) |candidate| allocator.free(candidate);
        nested.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), nested.items.len);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-authorization-server/mcp/v1", nested.items[0]);
    try std.testing.expectEqualStrings("https://example.com/mcp/v1/.well-known/oauth-authorization-server", nested.items[1]);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-authorization-server", nested.items[2]);
}

test "mcp oauth discovery metadata requires authorization and token endpoints" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try oauthDiscoveryMetadataIsSupported(
        allocator,
        "{\"authorization_endpoint\":\"https://auth.example/authorize\",\"token_endpoint\":\"https://auth.example/token\"}",
    ));
    try std.testing.expect(!try oauthDiscoveryMetadataIsSupported(
        allocator,
        "{\"authorization_endpoint\":\"https://auth.example/authorize\"}",
    ));
    try std.testing.expect(!try oauthDiscoveryMetadataIsSupported(
        allocator,
        "{\"authorization_endpoint\":123,\"token_endpoint\":null}",
    ));
}

test "mcp config loads enabled plugin mcp servers" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "plugins/cache/test/sample/local");
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "config.toml",
        .data =
        \\[features]
        \\plugins = true
        \\
        \\[plugins."sample@test"]
        \\enabled = true
        \\
        \\[mcp_servers.docs]
        \\command = "docs-server"
        \\
        ,
    });
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "plugins/cache/test/sample/local/.mcp.json",
        .data =
        \\{
        \\  "mcpServers": {
        \\    "plugin_docs": {
        \\      "command": "plugin-mcp",
        \\      "args": ["--stdio"],
        \\      "env": {"PLUGIN_TOKEN": "abc"}
        \\    },
        \\    "plugin_remote": {
        \\      "type": "http",
        \\      "url": "https://plugin.example/mcp",
        \\      "bearerTokenEnvVar": "PLUGIN_MCP_TOKEN"
        \\    }
        \\  }
        \\}
        ,
    });
    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    var servers = try loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), servers.items.items.len);
    try std.testing.expectEqualStrings("docs-server", servers.get("docs").?.command.?);
    try std.testing.expectEqualStrings("plugin-mcp", servers.get("plugin_docs").?.command.?);
    try std.testing.expectEqualStrings("--stdio", servers.get("plugin_docs").?.args.items[0]);
    try std.testing.expectEqualStrings("PLUGIN_TOKEN", servers.get("plugin_docs").?.env_vars.items[0].key);
    try std.testing.expectEqualStrings("abc", servers.get("plugin_docs").?.env_vars.items[0].value);
    try std.testing.expectEqualStrings("https://plugin.example/mcp", servers.get("plugin_remote").?.url.?);
    try std.testing.expectEqualStrings("PLUGIN_MCP_TOKEN", servers.get("plugin_remote").?.bearer_token_env_var.?);
}

test "mcp server name validation" {
    try validateServerName("docs_1");
    try std.testing.expectError(error.InvalidMcpServerName, validateServerName("bad.name"));
}

test "mcp status renders terse and verbose configured servers" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "config.toml",
        .data =
        \\[mcp_servers.docs]
        \\command = "docs-server"
        \\args = ["--stdio"]
        \\enabled = false
        \\
        \\[mcp_servers.remote]
        \\url = "https://example.com/mcp"
        \\bearer_token_env_var = "TOKEN_ENV"
        \\
        ,
    });
    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const terse = try renderStatus(allocator, codex_home, false);
    defer allocator.free(terse);
    try std.testing.expect(std.mem.indexOf(u8, terse, "mcp servers:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, terse, "docs\tstdio\tdisabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, terse, "remote\tstreamable_http\tenabled") != null);

    const verbose = try renderStatus(allocator, codex_home, true);
    defer allocator.free(verbose);
    try std.testing.expect(std.mem.indexOf(u8, verbose, "command: docs-server") != null);
    try std.testing.expect(std.mem.indexOf(u8, verbose, "args: --stdio") != null);
    try std.testing.expect(std.mem.indexOf(u8, verbose, "url: https://example.com/mcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, verbose, "bearer_token_env_var: TOKEN_ENV") != null);
}
