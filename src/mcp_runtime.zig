const std = @import("std");

const mcp_cmd = @import("mcp_cmd.zig");

pub const ToolSpec = struct {
    server_name: []const u8,
    raw_tool_name: []const u8,
    callable_name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,

    pub fn deinit(self: ToolSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.server_name);
        allocator.free(self.raw_tool_name);
        allocator.free(self.callable_name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

pub const Catalog = struct {
    tools: []ToolSpec,

    pub fn deinit(self: Catalog, allocator: std.mem.Allocator) void {
        for (self.tools) |tool| tool.deinit(allocator);
        allocator.free(self.tools);
    }

    pub fn find(self: Catalog, callable_name: []const u8) ?ToolSpec {
        for (self.tools) |tool| {
            if (std.mem.eql(u8, tool.callable_name, callable_name)) return tool;
        }
        return null;
    }
};

pub const CallOutput = struct {
    summary: []const u8,
    output: []const u8,

    pub fn deinit(self: CallOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.output);
    }
};

pub fn loadCatalog(allocator: std.mem.Allocator, codex_home: []const u8) !Catalog {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);

    var specs = std.ArrayList(ToolSpec).empty;
    errdefer {
        for (specs.items) |spec| spec.deinit(allocator);
        specs.deinit(allocator);
    }

    for (servers.items.items) |server| {
        if (!server.enabled or server.kind != .stdio) continue;
        appendServerTools(allocator, server, &specs) catch |err| {
            std.debug.print("[mcp] failed to list tools for {s}: {s}\n", .{ server.name, @errorName(err) });
            continue;
        };
    }

    return .{ .tools = try specs.toOwnedSlice(allocator) };
}

pub fn callTool(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    spec: ToolSpec,
    arguments_json: []const u8,
) !CallOutput {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(spec.server_name) orelse return error.McpServerNotFound;
    if (!server.enabled or server.kind != .stdio) return error.McpServerUnavailable;
    return callServerTool(allocator, server.*, spec.raw_tool_name, arguments_json);
}

pub fn readResource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    uri: []const u8,
) ![]const u8 {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(server_name) orelse return error.McpServerNotFound;
    if (!server.enabled or server.kind != .stdio) return error.McpServerUnavailable;
    return readServerResource(allocator, server.*, uri);
}

pub fn callToolByName(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) ![]const u8 {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(server_name) orelse return error.McpServerNotFound;
    if (!server.enabled or server.kind != .stdio) return error.McpServerUnavailable;
    return callServerToolJson(allocator, server.*, raw_tool_name, arguments_json, meta_json);
}

pub fn serverToolsStatusJson(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) ![]const u8 {
    if (!server.enabled or server.kind != .stdio) return allocator.dupe(u8, "{}");
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    var response = try client.request(2, "tools/list", null);
    defer response.deinit();

    const result = response.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;
    const tools = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (tools != .array) return error.InvalidMcpResponse;
    return renderStatusTools(allocator, tools);
}

fn appendServerTools(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    specs: *std.ArrayList(ToolSpec),
) !void {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    var response = try client.request(2, "tools/list", null);
    defer response.deinit();

    const result = response.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;
    const tools_value = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (tools_value != .array) return error.InvalidMcpResponse;

    for (tools_value.array.items) |tool_value| {
        if (tool_value != .object) continue;
        const name_value = tool_value.object.get("name") orelse continue;
        if (name_value != .string or name_value.string.len == 0) continue;

        const description = if (tool_value.object.get("description")) |description_value|
            if (description_value == .string) description_value.string else ""
        else
            "";
        const input_schema_json = if (tool_value.object.get("inputSchema")) |schema_value|
            try std.json.Stringify.valueAlloc(allocator, schema_value, .{})
        else
            try allocator.dupe(u8, "{\"type\":\"object\"}");
        errdefer allocator.free(input_schema_json);

        const callable_name = try canonicalToolName(allocator, server.name, name_value.string);
        errdefer allocator.free(callable_name);

        const server_name = try allocator.dupe(u8, server.name);
        errdefer allocator.free(server_name);
        const raw_tool_name = try allocator.dupe(u8, name_value.string);
        errdefer allocator.free(raw_tool_name);
        const description_copy = try allocator.dupe(u8, description);
        errdefer allocator.free(description_copy);

        try specs.append(allocator, .{
            .server_name = server_name,
            .raw_tool_name = raw_tool_name,
            .callable_name = callable_name,
            .description = description_copy,
            .input_schema_json = input_schema_json,
        });
    }
}

fn callServerTool(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    raw_tool_name: []const u8,
    arguments_json: []const u8,
) !CallOutput {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    const params = try buildCallToolParams(allocator, raw_tool_name, arguments_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    const result = response.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;

    const output = try renderCallResult(allocator, result);
    errdefer allocator.free(output);
    const is_error = if (result.object.get("isError")) |value| value == .bool and value.bool else false;
    const summary = try std.fmt.allocPrint(
        allocator,
        "mcp {s}.{s}{s}",
        .{ server.name, raw_tool_name, if (is_error) " error" else "" },
    );
    errdefer allocator.free(summary);

    return .{
        .summary = summary,
        .output = output,
    };
}

fn readServerResource(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    uri: []const u8,
) ![]const u8 {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    const params = try buildReadResourceParams(allocator, uri);
    defer allocator.free(params);
    var response = try client.request(2, "resources/read", params);
    defer response.deinit();

    const result = response.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;
    return renderResourceReadResult(allocator, result);
}

fn callServerToolJson(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) ![]const u8 {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    const params = try buildCallToolParamsWithMeta(allocator, raw_tool_name, arguments_json, meta_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    const result = response.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;
    return renderToolCallResult(allocator, result);
}

const StdioClient = struct {
    allocator: std.mem.Allocator,
    io_instance: std.Io.Threaded,
    child: std.process.Child,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    argv: SpawnArgv,

    fn start(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) !StdioClient {
        var io_instance: std.Io.Threaded = .init(allocator, .{});
        errdefer io_instance.deinit();

        const argv = try buildSpawnArgv(allocator, server);
        errdefer argv.deinit(allocator);

        var child = try std.process.spawn(io_instance.io(), .{
            .argv = argv.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io_instance.io());

        return .{
            .allocator = allocator,
            .io_instance = io_instance,
            .child = child,
            .stdin_file = child.stdin.?,
            .stdout_file = child.stdout.?,
            .argv = argv,
        };
    }

    fn deinit(self: *StdioClient) void {
        self.child.kill(self.io_instance.io());
        self.argv.deinit(self.allocator);
        self.io_instance.deinit();
    }

    fn initialize(self: *StdioClient) !void {
        const params =
            \\{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"codex-zig","version":"0.0.1"}}
        ;
        var response = try self.request(1, "initialize", params);
        defer response.deinit();
        try self.notify("notifications/initialized", null);
    }

    fn request(
        self: *StdioClient,
        id: i64,
        method: []const u8,
        params_json: ?[]const u8,
    ) !std.json.Parsed(std.json.Value) {
        const payload = try buildRequestPayload(self.allocator, id, method, params_json);
        defer self.allocator.free(payload);
        try self.writeLine(payload);
        return try self.readResponse(id);
    }

    fn notify(self: *StdioClient, method: []const u8, params_json: ?[]const u8) !void {
        const payload = try buildNotificationPayload(self.allocator, method, params_json);
        defer self.allocator.free(payload);
        try self.writeLine(payload);
    }

    fn writeLine(self: *StdioClient, payload: []const u8) !void {
        try self.stdin_file.writeStreamingAll(self.io_instance.io(), payload);
        try self.stdin_file.writeStreamingAll(self.io_instance.io(), "\n");
    }

    fn readResponse(self: *StdioClient, id: i64) !std.json.Parsed(std.json.Value) {
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            const line = try self.readLine();
            defer self.allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch continue;
            errdefer parsed.deinit();
            if (!isResponseForId(parsed.value, id)) {
                parsed.deinit();
                continue;
            }
            if (parsed.value.object.get("error")) |_| return error.McpJsonRpcError;
            return parsed;
        }
        return error.McpResponseNotFound;
    }

    fn readLine(self: *StdioClient) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (out.items.len < 1024 * 1024) {
            var byte: [1]u8 = undefined;
            const count = self.readByteWithTimeout(byte[0..]) catch |err| switch (err) {
                error.EndOfStream => return error.McpUnexpectedEof,
                error.Timeout => return error.McpTimeout,
                else => return err,
            };
            if (count == 0) continue;
            if (byte[0] == '\n') return out.toOwnedSlice(self.allocator);
            try out.append(self.allocator, byte[0]);
        }
        return error.McpResponseTooLarge;
    }

    fn readByteWithTimeout(self: *StdioClient, buffer: []u8) !usize {
        const result = try self.io_instance.io().operateTimeout(.{ .file_read_streaming = .{
            .file = self.stdout_file,
            .data = &.{buffer},
        } }, .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(5_000),
            .clock = .awake,
        } });
        return result.file_read_streaming;
    }
};

const SpawnArgv = struct {
    argv: []const []const u8,
    owned: []const []const u8,

    fn deinit(self: SpawnArgv, allocator: std.mem.Allocator) void {
        for (self.owned) |value| allocator.free(value);
        allocator.free(self.owned);
        allocator.free(self.argv);
    }
};

fn buildSpawnArgv(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) !SpawnArgv {
    const command = server.command orelse return error.MissingMcpCommand;
    const env_prefix_len: usize = if (server.env_vars.items.len > 0) 1 + server.env_vars.items.len else 0;
    const argv = try allocator.alloc([]const u8, env_prefix_len + 1 + server.args.items.len);
    errdefer allocator.free(argv);

    const owned = try allocator.alloc([]const u8, server.env_vars.items.len);
    errdefer allocator.free(owned);

    var index: usize = 0;
    var owned_count: usize = 0;
    errdefer {
        for (owned[0..owned_count]) |value| allocator.free(value);
    }

    if (server.env_vars.items.len > 0) {
        argv[index] = "/usr/bin/env";
        index += 1;
        for (server.env_vars.items) |entry| {
            const assignment = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value });
            owned[owned_count] = assignment;
            owned_count += 1;
            argv[index] = assignment;
            index += 1;
        }
    }

    argv[index] = command;
    index += 1;
    for (server.args.items) |arg| {
        argv[index] = arg;
        index += 1;
    }

    return .{ .argv = argv, .owned = owned[0..owned_count] };
}

fn buildRequestPayload(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]const u8 {
    const method_json = try std.json.Stringify.valueAlloc(allocator, method, .{});
    defer allocator.free(method_json);
    if (params_json) |params| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{s},\"params\":{s}}}",
            .{ id, method_json, params },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{s}}}",
        .{ id, method_json },
    );
}

fn buildNotificationPayload(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: ?[]const u8,
) ![]const u8 {
    const method_json = try std.json.Stringify.valueAlloc(allocator, method, .{});
    defer allocator.free(method_json);
    if (params_json) |params| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}",
            .{ method_json, params },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":{s}}}",
        .{method_json},
    );
}

fn buildCallToolParams(allocator: std.mem.Allocator, raw_tool_name: []const u8, arguments_json: []const u8) ![]const u8 {
    return buildCallToolParamsWithMeta(allocator, raw_tool_name, arguments_json, null);
}

fn buildCallToolParamsWithMeta(
    allocator: std.mem.Allocator,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) ![]const u8 {
    const name_json = try std.json.Stringify.valueAlloc(allocator, raw_tool_name, .{});
    defer allocator.free(name_json);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"name\":");
    try out.appendSlice(allocator, name_json);

    if (arguments_json) |arguments| {
        const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
        const args_bytes = if (trimmed.len == 0) "{}" else trimmed;
        var parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, args_bytes, .{});
        defer parsed_args.deinit();
        if (parsed_args.value != .object) return error.InvalidMcpToolArguments;
        const args_json = try std.json.Stringify.valueAlloc(allocator, parsed_args.value, .{});
        defer allocator.free(args_json);
        try out.appendSlice(allocator, ",\"arguments\":");
        try out.appendSlice(allocator, args_json);
    }
    if (meta_json) |meta| {
        try out.appendSlice(allocator, ",\"_meta\":");
        try out.appendSlice(allocator, meta);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn buildReadResourceParams(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const uri_json = try std.json.Stringify.valueAlloc(allocator, uri, .{});
    defer allocator.free(uri_json);
    return std.fmt.allocPrint(allocator, "{{\"uri\":{s}}}", .{uri_json});
}

fn isResponseForId(value: std.json.Value, id: i64) bool {
    if (value != .object) return false;
    const id_value = value.object.get("id") orelse return false;
    return switch (id_value) {
        .integer => |number| number == id,
        .float => |number| number == @as(f64, @floatFromInt(id)),
        else => false,
    };
}

fn renderCallResult(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    const text = try renderTextContent(allocator, result);
    defer allocator.free(text);
    if (text.len > 0) return allocator.dupe(u8, text);
    return std.json.Stringify.valueAlloc(allocator, result, .{});
}

fn renderResourceReadResult(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    if (result != .object) return error.InvalidMcpResponse;
    const contents = result.object.get("contents") orelse return error.InvalidMcpResponse;
    if (contents != .array) return error.InvalidMcpResponse;
    const contents_json = try std.json.Stringify.valueAlloc(allocator, contents, .{});
    defer allocator.free(contents_json);
    return std.fmt.allocPrint(allocator, "{{\"contents\":{s}}}", .{contents_json});
}

fn renderStatusTools(allocator: std.mem.Allocator, tools: std.json.Value) ![]const u8 {
    if (tools != .array) return error.InvalidMcpResponse;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    for (tools.array.items) |tool| {
        if (tool != .object) continue;
        const name = tool.object.get("name") orelse continue;
        if (name != .string or name.string.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        const name_json = try std.json.Stringify.valueAlloc(allocator, name.string, .{});
        defer allocator.free(name_json);
        const tool_json = try std.json.Stringify.valueAlloc(allocator, tool, .{});
        defer allocator.free(tool_json);
        try out.appendSlice(allocator, name_json);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, tool_json);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn renderToolCallResult(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    if (result != .object) return error.InvalidMcpResponse;
    const content = result.object.get("content") orelse return error.InvalidMcpResponse;
    if (content != .array) return error.InvalidMcpResponse;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const content_json = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(content_json);
    try out.appendSlice(allocator, "{\"content\":");
    try out.appendSlice(allocator, content_json);

    if (result.object.get("structuredContent")) |structured_content| {
        if (structured_content != .null) {
            const json = try std.json.Stringify.valueAlloc(allocator, structured_content, .{});
            defer allocator.free(json);
            try out.appendSlice(allocator, ",\"structuredContent\":");
            try out.appendSlice(allocator, json);
        }
    }
    if (result.object.get("isError")) |is_error| {
        if (is_error == .bool) {
            try out.appendSlice(allocator, if (is_error.bool) ",\"isError\":true" else ",\"isError\":false");
        } else if (is_error != .null) {
            return error.InvalidMcpResponse;
        }
    }
    if (result.object.get("_meta")) |meta| {
        if (meta != .null) {
            const json = try std.json.Stringify.valueAlloc(allocator, meta, .{});
            defer allocator.free(json);
            try out.appendSlice(allocator, ",\"_meta\":");
            try out.appendSlice(allocator, json);
        }
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn renderTextContent(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    if (result != .object) return allocator.dupe(u8, "");
    const content = result.object.get("content") orelse return allocator.dupe(u8, "");
    if (content != .array) return allocator.dupe(u8, "");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (content.array.items) |item| {
        if (item != .object) continue;
        const item_type = item.object.get("type") orelse continue;
        if (item_type != .string or !std.mem.eql(u8, item_type.string, "text")) continue;
        const text = item.object.get("text") orelse continue;
        if (text != .string or text.string.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, text.string);
    }
    return out.toOwnedSlice(allocator);
}

pub fn canonicalToolName(allocator: std.mem.Allocator, server_name: []const u8, tool_name: []const u8) ![]const u8 {
    const safe_server = try sanitizedName(allocator, server_name);
    defer allocator.free(safe_server);
    const safe_tool = try sanitizedName(allocator, tool_name);
    defer allocator.free(safe_tool);
    return std.fmt.allocPrint(allocator, "mcp__{s}__{s}", .{ safe_server, safe_tool });
}

fn sanitizedName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '_');
        }
    }
    if (out.items.len == 0) try out.append(allocator, '_');
    return out.toOwnedSlice(allocator);
}

test "mcp canonical tool names sanitize server and tool" {
    const allocator = std.testing.allocator;
    const name = try canonicalToolName(allocator, "server.one", "tool-two");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("mcp__server_one__tool_two", name);
}

test "mcp call result renders text content" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"text\",\"text\":\"alpha\"},{\"type\":\"text\",\"text\":\"beta\"}]}",
        .{},
    );
    defer parsed.deinit();

    const rendered = try renderCallResult(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("alpha\nbeta", rendered);
}

test "mcp resource read result keeps contents only" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"contents\":[{\"uri\":\"test://resource\",\"mimeType\":\"text/markdown\",\"text\":\"body\"}],\"extra\":true}",
        .{},
    );
    defer parsed.deinit();

    const rendered = try renderResourceReadResult(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"contents\":[{\"uri\":\"test://resource\",\"mimeType\":\"text/markdown\",\"text\":\"body\"}]}",
        rendered,
    );
}

test "mcp status tools are keyed by raw tool name" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"tools\":[{\"name\":\"look-up.raw\",\"description\":\"Look up test data.\",\"inputSchema\":{\"type\":\"object\"}},{\"description\":\"missing name\"}]}",
        .{},
    );
    defer parsed.deinit();

    const rendered = try renderStatusTools(allocator, parsed.value.object.get("tools").?);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"look-up.raw\":{\"name\":\"look-up.raw\",\"description\":\"Look up test data.\",\"inputSchema\":{\"type\":\"object\"}}}",
        rendered,
    );
}

test "mcp tool call result keeps app-server response fields" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"structuredContent\":{\"ok\":true},\"isError\":false,\"_meta\":{\"cursor\":\"next\"},\"extra\":true}",
        .{},
    );
    defer parsed.deinit();

    const rendered = try renderToolCallResult(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"structuredContent\":{\"ok\":true},\"isError\":false,\"_meta\":{\"cursor\":\"next\"}}",
        rendered,
    );
}
