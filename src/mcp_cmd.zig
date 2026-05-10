const std = @import("std");

const cli_utils = @import("cli_utils.zig");
const plugin_config = @import("plugin_config.zig");
const env = @import("env.zig");

pub const ServerKind = enum { unknown, stdio, streamable_http };

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

    pub fn deinit(self: *McpServer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.command) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        if (self.bearer_token_env_var) |value| allocator.free(value);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        for (self.env_vars.items) |entry| entry.deinit(allocator);
        self.env_vars.deinit(allocator);
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
        try runList(allocator, servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "get")) {
        try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
        try runGet(allocator, servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        try runAdd(allocator, codex_home, config_bytes orelse "", &servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try runRemove(allocator, codex_home, config_bytes orelse "", &servers, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "login") or std.mem.eql(u8, subcommand, "logout")) {
        try cli_utils.writeStdout("MCP OAuth login/logout is not implemented in the Zig port yet.\n");
        return error.UnsupportedMcpOAuth;
    } else {
        return error.UnknownMcpSubcommand;
    }
}

pub fn loadServers(allocator: std.mem.Allocator, codex_home: []const u8) !McpServers {
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    var servers = try parseServers(allocator, config_bytes orelse "");
    errdefer servers.deinit(allocator);
    try appendPluginMcpServers(allocator, codex_home, config_bytes orelse "", &servers);
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

fn runList(allocator: std.mem.Allocator, servers: McpServers, args: []const []const u8) !void {
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
        const rendered = try renderJsonList(allocator, servers);
        defer allocator.free(rendered);
        try cli_utils.writeStdout(rendered);
        return;
    }

    if (servers.items.items.len == 0) {
        try cli_utils.writeStdout("No MCP servers configured yet. Try `codex-zig mcp add my-tool -- my-command`.\n");
        return;
    }
    for (servers.items.items) |server| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}\t{s}\t{s}\n",
            .{ server.name, kindLabel(server), statusLabel(server.enabled) },
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

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| return value;
    const home = try env.getOwned(allocator, "HOME") orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn readConfigToml(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 512)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
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
        if (value) |arg| try server.args.append(allocator, arg);
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
            try output.append(allocator, '\n');
            try output.appendSlice(allocator, "[mcp_servers.");
            try output.appendSlice(allocator, server.name);
            try output.appendSlice(allocator, ".env]\n");
            for (server.env_vars.items) |entry| {
                try output.appendSlice(allocator, entry.key);
                try output.appendSlice(allocator, " = ");
                try appendTomlString(allocator, output, entry.value);
                try output.append(allocator, '\n');
            }
        }
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

fn renderJsonList(allocator: std.mem.Allocator, servers: McpServers) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "[\n");
    for (servers.items.items, 0..) |server, index| {
        if (index > 0) try output.appendSlice(allocator, ",\n");
        try output.appendSlice(allocator, "  ");
        const rendered = try renderJsonServer(allocator, server);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
    }
    try output.appendSlice(allocator, "\n]\n");
    return output.toOwnedSlice(allocator);
}

fn renderJsonServer(allocator: std.mem.Allocator, server: McpServer) ![]const u8 {
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
    try output.appendSlice(allocator, "}}");
    return output.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
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
        const body = try std.fmt.allocPrint(allocator, "  url: {s}\n  bearer_token_env_var: {s}\n", .{ server.url.?, token });
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
