const std = @import("std");

const env = @import("env.zig");
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

pub const StartupStatus = enum {
    starting,
    ready,
    failed,

    pub fn label(self: StartupStatus) []const u8 {
        return switch (self) {
            .starting => "starting",
            .ready => "ready",
            .failed => "failed",
        };
    }
};

pub const StartupStatusCallback = struct {
    ctx: *anyopaque,
    on_startup_status: *const fn (ctx: *anyopaque, server_name: []const u8, status: StartupStatus, error_message: ?[]const u8) anyerror!void,
};

pub const LoadCatalogOptions = struct {
    startup_status_callback: ?StartupStatusCallback = null,
};

pub const CallOutput = struct {
    summary: []const u8,
    output: []const u8,

    pub fn deinit(self: CallOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.output);
    }
};

pub const ElicitationRequest = struct {
    server_name: []const u8,
    request_id_json: []const u8,
    params_json: []const u8,
};

pub const ElicitationResponse = struct {
    result_json: []const u8,

    pub fn deinit(self: ElicitationResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.result_json);
    }
};

pub const ElicitationCallback = struct {
    ctx: *anyopaque,
    on_elicitation_requested: *const fn (ctx: *anyopaque, request: ElicitationRequest) anyerror!ElicitationResponse,
};

pub const CallToolOptions = struct {
    elicitation_callback: ?ElicitationCallback = null,
};

pub const McpJsonRpcErrorPayload = struct {
    code: i64,
    message: []const u8,
    data_json: ?[]const u8 = null,

    pub fn deinit(self: McpJsonRpcErrorPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.data_json) |data| allocator.free(data);
    }
};

pub const JsonRpcMethodResult = union(enum) {
    result_json: []const u8,
    rpc_error: McpJsonRpcErrorPayload,

    pub fn deinit(self: JsonRpcMethodResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .result_json => |json| allocator.free(json),
            .rpc_error => |payload| payload.deinit(allocator),
        }
    }

    pub fn intoResultJson(self: JsonRpcMethodResult, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .result_json => |json| json,
            .rpc_error => |payload| {
                payload.deinit(allocator);
                return error.McpJsonRpcError;
            },
        };
    }
};

const ResourceInventoryKind = enum {
    resources,
    resource_templates,

    fn method(self: ResourceInventoryKind) []const u8 {
        return switch (self) {
            .resources => "resources/list",
            .resource_templates => "resources/templates/list",
        };
    }

    fn primaryItemsKey(self: ResourceInventoryKind) []const u8 {
        return switch (self) {
            .resources => "resources",
            .resource_templates => "resourceTemplates",
        };
    }

    fn alternateItemsKey(self: ResourceInventoryKind) ?[]const u8 {
        return switch (self) {
            .resources => null,
            .resource_templates => "resource_templates",
        };
    }

    fn responseItemsKey(self: ResourceInventoryKind) []const u8 {
        return switch (self) {
            .resources => "resources",
            .resource_templates => "resourceTemplates",
        };
    }

    fn secondRequiredString(self: ResourceInventoryKind) []const u8 {
        return switch (self) {
            .resources => "uri",
            .resource_templates => "uriTemplate",
        };
    }
};

pub const ServerStatusInventoryJson = struct {
    tools: []const u8,
    resources: []const u8,
    resource_templates: []const u8,

    pub fn empty(allocator: std.mem.Allocator) !ServerStatusInventoryJson {
        const tools = try allocator.dupe(u8, "{}");
        errdefer allocator.free(tools);
        const resources = try allocator.dupe(u8, "[]");
        errdefer allocator.free(resources);
        const resource_templates = try allocator.dupe(u8, "[]");
        return .{
            .tools = tools,
            .resources = resources,
            .resource_templates = resource_templates,
        };
    }

    pub fn deinit(self: ServerStatusInventoryJson, allocator: std.mem.Allocator) void {
        allocator.free(self.tools);
        allocator.free(self.resources);
        allocator.free(self.resource_templates);
    }
};

pub fn isResourceToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "list_mcp_resources") or
        std.mem.eql(u8, name, "list_mcp_resource_templates") or
        std.mem.eql(u8, name, "read_mcp_resource");
}

pub fn loadCatalog(allocator: std.mem.Allocator, codex_home: []const u8) !Catalog {
    return loadCatalogWithOptions(allocator, codex_home, .{});
}

pub fn loadCatalogWithOptions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    options: LoadCatalogOptions,
) !Catalog {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);

    var specs = std.ArrayList(ToolSpec).empty;
    errdefer {
        for (specs.items) |spec| spec.deinit(allocator);
        specs.deinit(allocator);
    }

    for (servers.items.items) |server| {
        if (!server.enabled) continue;
        if (options.startup_status_callback) |callback| {
            try callback.on_startup_status(callback.ctx, server.name, .starting, null);
        }
        appendServerTools(allocator, codex_home, server, &specs) catch |err| {
            std.debug.print("[mcp] failed to list tools for {s}: {s}\n", .{ server.name, @errorName(err) });
            if (options.startup_status_callback) |callback| {
                try callback.on_startup_status(callback.ctx, server.name, .failed, @errorName(err));
            }
            continue;
        };
        if (options.startup_status_callback) |callback| {
            try callback.on_startup_status(callback.ctx, server.name, .ready, null);
        }
    }

    return .{ .tools = try specs.toOwnedSlice(allocator) };
}

pub fn callTool(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    spec: ToolSpec,
    arguments_json: []const u8,
) !CallOutput {
    return callToolWithOptions(allocator, codex_home, spec, arguments_json, .{});
}

pub fn callToolWithOptions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    spec: ToolSpec,
    arguments_json: []const u8,
    options: CallToolOptions,
) !CallOutput {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(spec.server_name) orelse return error.McpServerNotFound;
    if (!server.enabled) return error.McpServerUnavailable;
    return switch (server.kind) {
        .stdio => callServerTool(allocator, server.*, spec.raw_tool_name, arguments_json, options),
        .streamable_http => callHttpServerTool(allocator, codex_home, server.*, spec.raw_tool_name, arguments_json),
        else => error.McpServerUnavailable,
    };
}

pub fn readResource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    uri: []const u8,
) ![]const u8 {
    const outcome = try readResourceJsonRpc(allocator, codex_home, server_name, uri);
    return outcome.intoResultJson(allocator);
}

pub fn readResourceJsonRpc(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    uri: []const u8,
) !JsonRpcMethodResult {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(server_name) orelse return error.McpServerNotFound;
    if (!server.enabled) return error.McpServerUnavailable;
    return switch (server.kind) {
        .stdio => readServerResourceJsonRpc(allocator, server.*, uri),
        .streamable_http => readHttpServerResourceJsonRpc(allocator, codex_home, server.*, uri),
        else => error.McpServerUnavailable,
    };
}

pub fn callResourceTool(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
) !CallOutput {
    if (std.mem.eql(u8, tool_name, "list_mcp_resources")) {
        const output = try listResourcesForModel(allocator, codex_home, arguments_json, .resources);
        errdefer allocator.free(output);
        return .{
            .summary = try allocator.dupe(u8, "mcp resources listed"),
            .output = output,
        };
    }
    if (std.mem.eql(u8, tool_name, "list_mcp_resource_templates")) {
        const output = try listResourcesForModel(allocator, codex_home, arguments_json, .resource_templates);
        errdefer allocator.free(output);
        return .{
            .summary = try allocator.dupe(u8, "mcp resource templates listed"),
            .output = output,
        };
    }
    if (std.mem.eql(u8, tool_name, "read_mcp_resource")) {
        const output = try readResourceForModel(allocator, codex_home, arguments_json);
        errdefer allocator.free(output);
        return .{
            .summary = try allocator.dupe(u8, "mcp resource read"),
            .output = output,
        };
    }
    return error.UnknownMcpResourceTool;
}

fn listResourcesForModel(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    arguments_json: []const u8,
    kind: ResourceInventoryKind,
) ![]const u8 {
    var parsed_args = try parseArgumentsObject(allocator, arguments_json);
    defer parsed_args.deinit();
    const args = parsed_args.value.object;
    const server_name = try normalizedOptionalString(allocator, args, "server");
    defer if (server_name) |value| allocator.free(value);
    const cursor = try normalizedOptionalString(allocator, args, "cursor");
    defer if (cursor) |value| allocator.free(value);

    if (cursor != null and server_name == null) return error.McpCursorRequiresServer;

    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);

    if (server_name) |name| {
        const server = servers.get(name) orelse return error.McpServerNotFound;
        if (!server.enabled) return error.McpServerUnavailable;
        return switch (server.kind) {
            .stdio => listResourcesForModelStdioServer(allocator, server.*, cursor, kind),
            .streamable_http => listResourcesForModelHttpServer(allocator, codex_home, server.*, cursor, kind),
            else => error.McpServerUnavailable,
        };
    }

    std.mem.sort(mcp_cmd.McpServer, servers.items.items, {}, mcpServerNameLessThan);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    const key_json = try std.json.Stringify.valueAlloc(allocator, kind.responseItemsKey(), .{});
    defer allocator.free(key_json);
    try out.appendSlice(allocator, key_json);
    try out.appendSlice(allocator, ":[");

    var first = true;
    for (servers.items.items) |server| {
        if (!server.enabled) continue;
        appendAllModelResourceItems(allocator, codex_home, &out, server, kind, &first) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
    }

    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn listResourcesForModelStdioServer(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    cursor: ?[]const u8,
    kind: ResourceInventoryKind,
) ![]const u8 {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();
    try client.initialize();
    var next_id: i64 = 2;
    var page = try listModelResourcePage(allocator, &client, &next_id, server.name, kind, cursor);
    defer page.deinit(allocator);
    return renderModelResourcePageEnvelope(allocator, server.name, kind, page);
}

fn listResourcesForModelHttpServer(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    cursor: ?[]const u8,
    kind: ResourceInventoryKind,
) ![]const u8 {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();
    try client.initialize();
    var next_id: i64 = 2;
    var page = try listModelResourcePageHttp(allocator, &client, &next_id, server.name, kind, cursor);
    defer page.deinit(allocator);

    return renderModelResourcePageEnvelope(allocator, server.name, kind, page);
}

fn renderModelResourcePageEnvelope(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    kind: ResourceInventoryKind,
    page: ModelResourcePage,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const server_json = try std.json.Stringify.valueAlloc(allocator, server_name, .{});
    defer allocator.free(server_json);
    const key_json = try std.json.Stringify.valueAlloc(allocator, kind.responseItemsKey(), .{});
    defer allocator.free(key_json);

    try out.appendSlice(allocator, "{\"server\":");
    try out.appendSlice(allocator, server_json);
    try out.append(allocator, ',');
    try out.appendSlice(allocator, key_json);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, page.items);
    if (page.next_cursor) |next_cursor| {
        const cursor_json = try std.json.Stringify.valueAlloc(allocator, next_cursor, .{});
        defer allocator.free(cursor_json);
        try out.appendSlice(allocator, ",\"nextCursor\":");
        try out.appendSlice(allocator, cursor_json);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendAllModelResourceItems(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    out: *std.ArrayList(u8),
    server: mcp_cmd.McpServer,
    kind: ResourceInventoryKind,
    first: *bool,
) !void {
    if (server.kind == .streamable_http) {
        return appendAllModelResourceItemsHttp(allocator, codex_home, out, server, kind, first);
    }
    if (server.kind != .stdio) return error.McpServerUnavailable;
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();
    try client.initialize();
    var next_id: i64 = 2;
    var seen_cursors = std.ArrayList([]const u8).empty;
    defer {
        for (seen_cursors.items) |seen| allocator.free(seen);
        seen_cursors.deinit(allocator);
    }
    var cursor: ?[]const u8 = null;
    while (true) {
        var page = try listModelResourcePage(allocator, &client, &next_id, server.name, kind, cursor);
        defer page.deinit(allocator);
        try appendJsonArrayItems(allocator, out, page.items, first);
        const next_cursor = page.next_cursor orelse break;
        for (seen_cursors.items) |seen| {
            if (std.mem.eql(u8, seen, next_cursor)) return error.InvalidMcpResponse;
        }
        const cursor_copy = try allocator.dupe(u8, next_cursor);
        errdefer allocator.free(cursor_copy);
        try seen_cursors.append(allocator, cursor_copy);
        cursor = cursor_copy;
    }
}

fn appendAllModelResourceItemsHttp(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    out: *std.ArrayList(u8),
    server: mcp_cmd.McpServer,
    kind: ResourceInventoryKind,
    first: *bool,
) !void {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();
    try client.initialize();
    var next_id: i64 = 2;
    var seen_cursors = std.ArrayList([]const u8).empty;
    defer {
        for (seen_cursors.items) |seen| allocator.free(seen);
        seen_cursors.deinit(allocator);
    }
    var cursor: ?[]const u8 = null;
    while (true) {
        var page = try listModelResourcePageHttp(allocator, &client, &next_id, server.name, kind, cursor);
        defer page.deinit(allocator);
        try appendJsonArrayItems(allocator, out, page.items, first);
        const next_cursor = page.next_cursor orelse break;
        for (seen_cursors.items) |seen| {
            if (std.mem.eql(u8, seen, next_cursor)) return error.InvalidMcpResponse;
        }
        const cursor_copy = try allocator.dupe(u8, next_cursor);
        errdefer allocator.free(cursor_copy);
        try seen_cursors.append(allocator, cursor_copy);
        cursor = cursor_copy;
    }
}

const ModelResourcePage = struct {
    items: []const u8,
    next_cursor: ?[]const u8,

    fn deinit(self: ModelResourcePage, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        if (self.next_cursor) |cursor| allocator.free(cursor);
    }
};

fn listModelResourcePage(
    allocator: std.mem.Allocator,
    client: *StdioClient,
    next_id: *i64,
    server_name: []const u8,
    kind: ResourceInventoryKind,
    cursor: ?[]const u8,
) !ModelResourcePage {
    const params = if (cursor) |cursor_value|
        try buildCursorParams(allocator, cursor_value)
    else
        null;
    defer if (params) |params_json| allocator.free(params_json);

    const id = next_id.*;
    next_id.* += 1;
    var response = try client.request(id, kind.method(), params);
    defer response.deinit();
    return parseModelResourcePage(allocator, server_name, kind, response.value);
}

fn listModelResourcePageHttp(
    allocator: std.mem.Allocator,
    client: *HttpClient,
    next_id: *i64,
    server_name: []const u8,
    kind: ResourceInventoryKind,
    cursor: ?[]const u8,
) !ModelResourcePage {
    const params = if (cursor) |cursor_value|
        try buildCursorParams(allocator, cursor_value)
    else
        null;
    defer if (params) |params_json| allocator.free(params_json);

    const id = next_id.*;
    next_id.* += 1;
    var response = try client.request(id, kind.method(), params);
    defer response.deinit();
    return parseModelResourcePage(allocator, server_name, kind, response.value);
}

fn parseModelResourcePage(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    kind: ResourceInventoryKind,
    response_value: std.json.Value,
) !ModelResourcePage {
    const result = try jsonRpcResultValue(response_value);
    if (result != .object) return error.InvalidMcpResponse;
    const items = result.object.get(kind.primaryItemsKey()) orelse if (kind.alternateItemsKey()) |key|
        result.object.get(key) orelse return error.InvalidMcpResponse
    else
        return error.InvalidMcpResponse;
    if (items != .array) return error.InvalidMcpResponse;

    const rendered = try renderModelResourceItems(allocator, server_name, items, kind);
    errdefer allocator.free(rendered);

    const next_cursor_value = result.object.get("nextCursor") orelse result.object.get("next_cursor") orelse null;
    const next_cursor = if (next_cursor_value) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .string) return error.InvalidMcpResponse;
        break :blk try allocator.dupe(u8, value.string);
    } else null;

    return .{ .items = rendered, .next_cursor = next_cursor };
}

fn renderModelResourceItems(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    items: std.json.Value,
    kind: ResourceInventoryKind,
) ![]const u8 {
    if (items != .array) return error.InvalidMcpResponse;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (items.array.items) |item| {
        if (!isStatusItemWithRequiredStrings(item, "name", kind.secondRequiredString())) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendModelResourceItem(allocator, &out, server_name, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendJsonArrayItems(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    items_json: []const u8,
    first: *bool,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, items_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidMcpResponse;
    for (parsed.value.array.items) |item| {
        if (!first.*) try out.append(allocator, ',');
        first.* = false;
        const item_json = try std.json.Stringify.valueAlloc(allocator, item, .{});
        defer allocator.free(item_json);
        try out.appendSlice(allocator, item_json);
    }
}

fn appendModelResourceItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    server_name: []const u8,
    item: std.json.Value,
) !void {
    if (item != .object) return error.InvalidMcpResponse;
    const server_json = try std.json.Stringify.valueAlloc(allocator, server_name, .{});
    defer allocator.free(server_json);
    try out.appendSlice(allocator, "{\"server\":");
    try out.appendSlice(allocator, server_json);
    var iter = item.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "server")) continue;
        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        const value_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(value_json);
        try out.append(allocator, ',');
        try out.appendSlice(allocator, key_json);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, value_json);
    }
    try out.append(allocator, '}');
}

fn readResourceForModel(allocator: std.mem.Allocator, codex_home: []const u8, arguments_json: []const u8) ![]const u8 {
    var parsed_args = try parseArgumentsObject(allocator, arguments_json);
    defer parsed_args.deinit();
    const args = parsed_args.value.object;
    const server_name = try normalizedRequiredString(allocator, args, "server");
    defer allocator.free(server_name);
    const uri = try normalizedRequiredString(allocator, args, "uri");
    defer allocator.free(uri);

    const resource_json = try readResource(allocator, codex_home, server_name, uri);
    defer allocator.free(resource_json);
    var parsed_resource = try std.json.parseFromSlice(std.json.Value, allocator, resource_json, .{});
    defer parsed_resource.deinit();
    if (parsed_resource.value != .object) return error.InvalidMcpResponse;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const server_json = try std.json.Stringify.valueAlloc(allocator, server_name, .{});
    defer allocator.free(server_json);
    const uri_json = try std.json.Stringify.valueAlloc(allocator, uri, .{});
    defer allocator.free(uri_json);
    try out.appendSlice(allocator, "{\"server\":");
    try out.appendSlice(allocator, server_json);
    try out.appendSlice(allocator, ",\"uri\":");
    try out.appendSlice(allocator, uri_json);
    var iter = parsed_resource.value.object.iterator();
    while (iter.next()) |entry| {
        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        const value_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(value_json);
        try out.append(allocator, ',');
        try out.appendSlice(allocator, key_json);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, value_json);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn parseArgumentsObject(allocator: std.mem.Allocator, arguments_json: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, arguments_json, " \t\r\n");
    const bytes = if (trimmed.len == 0) "{}" else trimmed;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpToolArguments;
    return parsed;
}

fn normalizedOptionalString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidMcpToolArguments;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn normalizedRequiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const u8 {
    return (try normalizedOptionalString(allocator, object, key)) orelse error.MissingMcpToolArgument;
}

fn mcpServerNameLessThan(_: void, lhs: mcp_cmd.McpServer, rhs: mcp_cmd.McpServer) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

pub fn callToolByName(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) ![]const u8 {
    const outcome = try callToolByNameJsonRpc(allocator, codex_home, server_name, raw_tool_name, arguments_json, meta_json);
    return outcome.intoResultJson(allocator);
}

pub fn callToolByNameJsonRpc(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) !JsonRpcMethodResult {
    return callToolByNameJsonRpcWithOptions(allocator, codex_home, server_name, raw_tool_name, arguments_json, meta_json, .{});
}

pub fn callToolByNameJsonRpcWithOptions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server_name: []const u8,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
    options: CallToolOptions,
) !JsonRpcMethodResult {
    var servers = try mcp_cmd.loadServers(allocator, codex_home);
    defer servers.deinit(allocator);
    const server = servers.get(server_name) orelse return error.McpServerNotFound;
    if (!server.enabled) return error.McpServerUnavailable;
    return switch (server.kind) {
        .stdio => callServerToolJsonRpc(allocator, server.*, raw_tool_name, arguments_json, meta_json, options),
        .streamable_http => callHttpServerToolJsonRpc(allocator, codex_home, server.*, raw_tool_name, arguments_json, meta_json),
        else => error.McpServerUnavailable,
    };
}

pub fn serverStatusInventoryJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    include_resource_inventory: bool,
) !ServerStatusInventoryJson {
    if (!server.enabled) return ServerStatusInventoryJson.empty(allocator);
    return switch (server.kind) {
        .stdio => serverStatusInventoryJsonStdio(allocator, server, include_resource_inventory),
        .streamable_http => serverStatusInventoryJsonHttp(allocator, codex_home, server, include_resource_inventory),
        else => ServerStatusInventoryJson.empty(allocator),
    };
}

fn serverStatusInventoryJsonStdio(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    include_resource_inventory: bool,
) !ServerStatusInventoryJson {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    var next_id: i64 = 2;

    const tools_json = listStatusTools(allocator, &client, &next_id) catch try allocator.dupe(u8, "{}");
    errdefer allocator.free(tools_json);

    const resources_json = if (include_resource_inventory)
        listStatusResources(allocator, &client, &next_id) catch try allocator.dupe(u8, "[]")
    else
        try allocator.dupe(u8, "[]");
    errdefer allocator.free(resources_json);

    const resource_templates_json = if (include_resource_inventory)
        listStatusResourceTemplates(allocator, &client, &next_id) catch try allocator.dupe(u8, "[]")
    else
        try allocator.dupe(u8, "[]");

    return .{
        .tools = tools_json,
        .resources = resources_json,
        .resource_templates = resource_templates_json,
    };
}

fn serverStatusInventoryJsonHttp(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    include_resource_inventory: bool,
) !ServerStatusInventoryJson {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();

    try client.initialize();
    var next_id: i64 = 2;

    const tools_json = listStatusTools(allocator, &client, &next_id) catch try allocator.dupe(u8, "{}");
    errdefer allocator.free(tools_json);

    const resources_json = if (include_resource_inventory)
        listStatusResources(allocator, &client, &next_id) catch try allocator.dupe(u8, "[]")
    else
        try allocator.dupe(u8, "[]");
    errdefer allocator.free(resources_json);

    const resource_templates_json = if (include_resource_inventory)
        listStatusResourceTemplates(allocator, &client, &next_id) catch try allocator.dupe(u8, "[]")
    else
        try allocator.dupe(u8, "[]");

    return .{
        .tools = tools_json,
        .resources = resources_json,
        .resource_templates = resource_templates_json,
    };
}

fn appendServerTools(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    specs: *std.ArrayList(ToolSpec),
) !void {
    if (server.kind == .streamable_http) return appendHttpServerTools(allocator, codex_home, server, specs);
    if (server.kind != .stdio) return error.McpServerUnavailable;
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    var response = try client.request(2, "tools/list", null);
    defer response.deinit();

    const result = try jsonRpcResultValue(response.value);
    if (result != .object) return error.InvalidMcpResponse;
    const tools_value = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (tools_value != .array) return error.InvalidMcpResponse;
    try appendToolSpecsFromToolsValue(allocator, server, tools_value, specs);
}

fn appendToolSpecsFromToolsValue(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    tools_value: std.json.Value,
    specs: *std.ArrayList(ToolSpec),
) !void {
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
    options: CallToolOptions,
) !CallOutput {
    var client = try StdioClient.startWithOptions(allocator, server, .{ .elicitation_callback = options.elicitation_callback });
    defer client.deinit();

    try client.initialize();
    const params = try buildCallToolParams(allocator, raw_tool_name, arguments_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    const result = try jsonRpcResultValue(response.value);
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

fn callHttpServerTool(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    raw_tool_name: []const u8,
    arguments_json: []const u8,
) !CallOutput {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();

    try client.initialize();
    const params = try buildCallToolParams(allocator, raw_tool_name, arguments_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    const result = try jsonRpcResultValue(response.value);
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

fn appendHttpServerTools(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    specs: *std.ArrayList(ToolSpec),
) !void {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();

    try client.initialize();
    var response = try client.request(2, "tools/list", null);
    defer response.deinit();

    const result = try jsonRpcResultValue(response.value);
    if (result != .object) return error.InvalidMcpResponse;
    const tools_value = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (tools_value != .array) return error.InvalidMcpResponse;
    try appendToolSpecsFromToolsValue(allocator, server, tools_value, specs);
}

fn readServerResourceJsonRpc(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    uri: []const u8,
) !JsonRpcMethodResult {
    var client = try StdioClient.start(allocator, server);
    defer client.deinit();

    try client.initialize();
    const params = try buildReadResourceParams(allocator, uri);
    defer allocator.free(params);
    var response = try client.request(2, "resources/read", params);
    defer response.deinit();

    return renderJsonRpcMethodResult(allocator, response.value, .resource_read);
}

fn callServerToolJsonRpc(
    allocator: std.mem.Allocator,
    server: mcp_cmd.McpServer,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
    options: CallToolOptions,
) !JsonRpcMethodResult {
    var client = try StdioClient.startWithOptions(allocator, server, .{ .elicitation_callback = options.elicitation_callback });
    defer client.deinit();

    try client.initialize();
    const params = try buildCallToolParamsWithMeta(allocator, raw_tool_name, arguments_json, meta_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    return renderJsonRpcMethodResult(allocator, response.value, .tool_call);
}

fn readHttpServerResourceJsonRpc(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    uri: []const u8,
) !JsonRpcMethodResult {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();

    try client.initialize();
    const params = try buildReadResourceParams(allocator, uri);
    defer allocator.free(params);
    var response = try client.request(2, "resources/read", params);
    defer response.deinit();

    return renderJsonRpcMethodResult(allocator, response.value, .resource_read);
}

fn callHttpServerToolJsonRpc(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
    raw_tool_name: []const u8,
    arguments_json: ?[]const u8,
    meta_json: ?[]const u8,
) !JsonRpcMethodResult {
    var client = try HttpClient.start(allocator, codex_home, server);
    defer client.close();

    try client.initialize();
    const params = try buildCallToolParamsWithMeta(allocator, raw_tool_name, arguments_json, meta_json);
    defer allocator.free(params);
    var response = try client.request(2, "tools/call", params);
    defer response.deinit();

    return renderJsonRpcMethodResult(allocator, response.value, .tool_call);
}

const StdioClient = struct {
    allocator: std.mem.Allocator,
    server_name: []const u8,
    io_instance: std.Io.Threaded,
    child: std.process.Child,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    argv: SpawnArgv,
    elicitation_callback: ?ElicitationCallback,

    const Options = struct {
        elicitation_callback: ?ElicitationCallback = null,
    };

    fn start(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) !StdioClient {
        return startWithOptions(allocator, server, .{});
    }

    fn startWithOptions(allocator: std.mem.Allocator, server: mcp_cmd.McpServer, options: Options) !StdioClient {
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
            .server_name = server.name,
            .io_instance = io_instance,
            .child = child,
            .stdin_file = child.stdin.?,
            .stdout_file = child.stdout.?,
            .argv = argv,
            .elicitation_callback = options.elicitation_callback,
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
        _ = try jsonRpcResultValue(response.value);
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
                if (try self.handleServerRequest(parsed.value)) {
                    parsed.deinit();
                    continue;
                }
                parsed.deinit();
                continue;
            }
            return parsed;
        }
        return error.McpResponseNotFound;
    }

    fn handleServerRequest(self: *StdioClient, value: std.json.Value) !bool {
        if (value != .object) return false;
        const object = value.object;
        const id_value = object.get("id") orelse return false;
        if (!isJsonRpcIdValue(id_value)) return false;
        const method_value = object.get("method") orelse return false;
        if (method_value != .string) return false;

        const id_json = try std.json.Stringify.valueAlloc(self.allocator, id_value, .{});
        defer self.allocator.free(id_json);

        if (std.mem.eql(u8, method_value.string, "elicitation/create")) {
            const params_json = if (object.get("params")) |params_value|
                try std.json.Stringify.valueAlloc(self.allocator, params_value, .{})
            else
                try self.allocator.dupe(u8, "{}");
            defer self.allocator.free(params_json);

            var result = if (self.elicitation_callback) |callback|
                try callback.on_elicitation_requested(callback.ctx, .{
                    .server_name = self.server_name,
                    .request_id_json = id_json,
                    .params_json = params_json,
                })
            else
                ElicitationResponse{ .result_json = try self.allocator.dupe(u8, "{\"action\":\"decline\"}") };
            defer result.deinit(self.allocator);

            const response = try buildResponsePayloadWithIdJson(self.allocator, id_json, result.result_json);
            defer self.allocator.free(response);
            try self.writeLine(response);
            return true;
        }

        const response = try buildErrorPayloadWithIdJson(self.allocator, id_json, -32601, "Method not found");
        defer self.allocator.free(response);
        try self.writeLine(response);
        return true;
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

const HttpClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    authorization_header: ?[]const u8,
    extra_headers: std.ArrayList(mcp_cmd.KeyValue),
    session_id: ?[]const u8,

    const Response = struct {
        status: u16,
        body: []const u8,

        fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
        }
    };

    fn start(allocator: std.mem.Allocator, codex_home: []const u8, server: mcp_cmd.McpServer) !HttpClient {
        const url = server.url orelse return error.MissingMcpUrl;
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);

        const authorization_header = try mcpAuthorizationHeader(allocator, codex_home, server);
        errdefer if (authorization_header) |header| allocator.free(header);
        var extra_headers = try configuredHttpHeaders(allocator, server);
        errdefer {
            for (extra_headers.items) |entry| entry.deinit(allocator);
            extra_headers.deinit(allocator);
        }

        return .{
            .allocator = allocator,
            .url = url_copy,
            .authorization_header = authorization_header,
            .extra_headers = extra_headers,
            .session_id = null,
        };
    }

    fn close(self: *HttpClient) void {
        self.deleteSession() catch {};
        self.deinit();
    }

    fn deinit(self: *HttpClient) void {
        if (self.session_id) |session_id| self.allocator.free(session_id);
        if (self.authorization_header) |header| self.allocator.free(header);
        for (self.extra_headers.items) |entry| entry.deinit(self.allocator);
        self.extra_headers.deinit(self.allocator);
        self.allocator.free(self.url);
    }

    fn initialize(self: *HttpClient) !void {
        const params =
            \\{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"codex-zig","version":"0.0.1"}}
        ;
        var response = try self.request(1, "initialize", params);
        defer response.deinit();
        _ = try jsonRpcResultValue(response.value);
        const notification = try buildNotificationPayload(self.allocator, "notifications/initialized", null);
        defer self.allocator.free(notification);
        const notification_response = try self.postJson(notification);
        defer notification_response.deinit(self.allocator);
    }

    fn request(
        self: *HttpClient,
        id: i64,
        method: []const u8,
        params_json: ?[]const u8,
    ) !std.json.Parsed(std.json.Value) {
        const payload = try buildRequestPayload(self.allocator, id, method, params_json);
        defer self.allocator.free(payload);
        const response = try self.postJson(payload);
        defer response.deinit(self.allocator);
        if (response.status == 202 or response.status == 204) {
            return self.getStreamResponse(id);
        }
        return parseHttpResponse(self.allocator, response.body, id);
    }

    fn postJson(self: *HttpClient, payload: []const u8) !Response {
        return self.sendHttp(.POST, payload);
    }

    fn deleteSession(self: *HttpClient) !void {
        if (self.session_id == null) return;
        const response = self.sendHttp(.DELETE, null) catch |err| switch (err) {
            error.McpHttpMethodNotAllowed => return,
            else => |e| return e,
        };
        response.deinit(self.allocator);
    }

    fn sendHttp(self: *HttpClient, method: std.http.Method, payload: ?[]const u8) !Response {
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(self.allocator);
        if (method == .GET or payload != null) {
            try headers.append(self.allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        }
        if (payload != null) {
            try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });
        }
        try headers.append(self.allocator, .{ .name = "MCP-Protocol-Version", .value = "2025-03-26" });
        try headers.append(self.allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
        if (self.session_id) |session_id| {
            try headers.append(self.allocator, .{ .name = "Mcp-Session-Id", .value = session_id });
        }
        for (self.extra_headers.items) |header| {
            try headers.append(self.allocator, .{ .name = header.key, .value = header.value });
        }
        if (self.authorization_header) |authorization| {
            try headers.append(self.allocator, .{ .name = "Authorization", .value = authorization });
        }

        var io_instance: std.Io.Threaded = .init(self.allocator, .{});
        defer io_instance.deinit();

        var client = std.http.Client{ .allocator = self.allocator, .io = io_instance.io() };
        defer client.deinit();

        const uri = try std.Uri.parse(self.url);
        var req = try client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
        });
        defer req.deinit();

        if (payload) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
            var request_body = try req.sendBodyUnflushed(&.{});
            try request_body.writer.writeAll(body);
            try request_body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var response_head_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&response_head_buffer);
        try self.captureSessionId(response.head);

        const status = @intFromEnum(response.head.status);
        if (method == .DELETE and status == 405) return error.McpHttpMethodNotAllowed;
        if (status < 200 or status >= 300) return error.McpHttpStatus;

        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (response.head.content_encoding != .identity) self.allocator.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&response_body.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{
            .status = status,
            .body = try response_body.toOwnedSlice(),
        };
    }

    fn getStreamResponse(self: *HttpClient, id: i64) !std.json.Parsed(std.json.Value) {
        if (self.session_id == null) return error.McpResponseNotFound;
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(self.allocator);
        try headers.append(self.allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        try headers.append(self.allocator, .{ .name = "MCP-Protocol-Version", .value = "2025-03-26" });
        try headers.append(self.allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
        if (self.session_id) |session_id| {
            try headers.append(self.allocator, .{ .name = "Mcp-Session-Id", .value = session_id });
        }
        for (self.extra_headers.items) |header| {
            try headers.append(self.allocator, .{ .name = header.key, .value = header.value });
        }
        if (self.authorization_header) |authorization| {
            try headers.append(self.allocator, .{ .name = "Authorization", .value = authorization });
        }

        var io_instance: std.Io.Threaded = .init(self.allocator, .{});
        defer io_instance.deinit();

        var client = std.http.Client{ .allocator = self.allocator, .io = io_instance.io() };
        defer client.deinit();

        const uri = try std.Uri.parse(self.url);
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
        });
        defer req.deinit();
        try req.sendBodiless();

        var response_head_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&response_head_buffer);
        try self.captureSessionId(response.head);

        const status: u16 = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) return error.McpHttpStatus;

        const content_type = response.head.content_type;
        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (response.head.content_encoding != .identity) self.allocator.free(decompress_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        if (content_type) |value| {
            if (std.mem.startsWith(u8, value, "application/json")) {
                _ = reader.streamRemaining(&response_body.writer) catch |err| switch (err) {
                    error.ReadFailed => return response.bodyErr().?,
                    else => |e| return e,
                };
                return parseHttpResponse(self.allocator, response_body.written(), id);
            }
        }
        return parseSseResponseFromReader(self.allocator, reader, id) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
    }

    fn captureSessionId(self: *HttpClient, head: std.http.Client.Response.Head) !void {
        var iter = head.iterateHeaders();
        while (iter.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            const trimmed = std.mem.trim(u8, header.value, " \t\r\n");
            if (trimmed.len == 0) return;
            const session_id = try self.allocator.dupe(u8, trimmed);
            errdefer self.allocator.free(session_id);
            if (self.session_id) |old| self.allocator.free(old);
            self.session_id = session_id;
            return;
        }
    }
};

fn mcpAuthorizationHeader(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    server: mcp_cmd.McpServer,
) !?[]const u8 {
    if (server.bearer_token_env_var) |name| {
        const token = try env.getOwnedDynamic(allocator, name) orelse return error.McpServerUnavailable;
        defer allocator.free(token);
        return try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    }

    const url = server.url orelse return null;
    if (try mcp_cmd.readMcpOAuthFileAccessToken(allocator, codex_home, server.name, url)) |token| {
        defer allocator.free(token);
        return try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    }
    return null;
}

fn configuredHttpHeaders(allocator: std.mem.Allocator, server: mcp_cmd.McpServer) !std.ArrayList(mcp_cmd.KeyValue) {
    var headers = std.ArrayList(mcp_cmd.KeyValue).empty;
    errdefer {
        for (headers.items) |entry| entry.deinit(allocator);
        headers.deinit(allocator);
    }

    for (server.http_headers.items) |entry| {
        try appendConfiguredHeader(allocator, &headers, entry.key, entry.value);
    }
    for (server.env_http_headers.items) |entry| {
        const value = try env.getOwnedDynamic(allocator, entry.value) orelse return error.McpServerUnavailable;
        errdefer allocator.free(value);
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        try headers.append(allocator, .{ .key = key, .value = value });
    }
    return headers;
}

fn appendConfiguredHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(mcp_cmd.KeyValue),
    key: []const u8,
    value: []const u8,
) !void {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    try headers.append(allocator, .{ .key = key_copy, .value = value_copy });
}

fn parseHttpResponse(allocator: std.mem.Allocator, body: []const u8, id: i64) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return error.McpResponseNotFound;
    if (std.mem.startsWith(u8, trimmed, "data:") or std.mem.startsWith(u8, trimmed, "event:")) {
        return parseSseResponse(allocator, trimmed, id);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    errdefer parsed.deinit();
    if (!isResponseForId(parsed.value, id)) return error.McpResponseNotFound;
    return parsed;
}

fn parseSseResponse(allocator: std.mem.Allocator, body: []const u8, id: i64) !std.json.Parsed(std.json.Value) {
    var event_data = std.ArrayList(u8).empty;
    defer event_data.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) {
            if (event_data.items.len == 0) continue;
            if (try parseSseEvent(allocator, event_data.items, id)) |parsed| return parsed;
            event_data.clearRetainingCapacity();
            continue;
        }
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) continue;
        if (event_data.items.len > 0) try event_data.append(allocator, '\n');
        try event_data.appendSlice(allocator, data);
    }

    if (event_data.items.len > 0) {
        if (try parseSseEvent(allocator, event_data.items, id)) |parsed| return parsed;
    }
    return error.McpResponseNotFound;
}

fn parseSseResponseFromReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    id: i64,
) !std.json.Parsed(std.json.Value) {
    var event_data = std.ArrayList(u8).empty;
    defer event_data.deinit(allocator);
    var line_data: std.Io.Writer.Allocating = .init(allocator);
    defer line_data.deinit();

    var observed_bytes: usize = 0;
    const max_observed_bytes = 8 * 1024 * 1024;
    while (true) {
        const remaining_limit = max_observed_bytes -| observed_bytes;
        const line_len = reader.streamDelimiterLimit(&line_data.writer, '\n', .limited(remaining_limit)) catch |err| switch (err) {
            error.StreamTooLong => return error.McpResponseTooLarge,
            else => |e| return e,
        };
        observed_bytes += line_len;
        const ended = blk: {
            _ = reader.peek(1) catch |err| switch (err) {
                error.EndOfStream => break :blk true,
                error.ReadFailed => return error.ReadFailed,
            };
            reader.toss(1);
            observed_bytes += 1;
            break :blk false;
        };

        const line = std.mem.trim(u8, line_data.written(), "\r");
        if (line.len == 0) {
            line_data.clearRetainingCapacity();
            if (event_data.items.len > 0) {
                if (try parseSseEvent(allocator, event_data.items, id)) |parsed| return parsed;
                event_data.clearRetainingCapacity();
            }
            if (ended) return error.McpResponseNotFound;
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trim(u8, line["data:".len..], " ");
            if (!std.mem.eql(u8, data, "[DONE]")) {
                if (event_data.items.len > 0) try event_data.append(allocator, '\n');
                try event_data.appendSlice(allocator, data);
            }
        }
        if (ended) {
            if (event_data.items.len > 0) {
                if (try parseSseEvent(allocator, event_data.items, id)) |parsed| return parsed;
            }
            return error.McpResponseNotFound;
        }
        line_data.clearRetainingCapacity();
    }
}

fn parseSseEvent(allocator: std.mem.Allocator, data: []const u8, id: i64) !?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0 or !std.mem.startsWith(u8, trimmed, "{")) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    errdefer parsed.deinit();
    if (!isResponseForId(parsed.value, id)) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

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

fn buildResponsePayloadWithIdJson(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    result_json: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn buildErrorPayloadWithIdJson(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    code: i64,
    message: []const u8,
) ![]const u8 {
    const message_json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(message_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json, code, message_json },
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

fn buildCursorParams(allocator: std.mem.Allocator, cursor: []const u8) ![]const u8 {
    const cursor_json = try std.json.Stringify.valueAlloc(allocator, cursor, .{});
    defer allocator.free(cursor_json);
    return std.fmt.allocPrint(allocator, "{{\"cursor\":{s}}}", .{cursor_json});
}

fn isJsonRpcIdValue(value: std.json.Value) bool {
    return switch (value) {
        .string, .integer => true,
        else => false,
    };
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

fn jsonRpcResultValue(response_value: std.json.Value) !std.json.Value {
    if (response_value != .object) return error.InvalidMcpResponse;
    if (response_value.object.get("error")) |_| return error.McpJsonRpcError;
    return response_value.object.get("result") orelse error.InvalidMcpResponse;
}

fn parseMcpJsonRpcErrorPayload(
    allocator: std.mem.Allocator,
    response_value: std.json.Value,
) !?McpJsonRpcErrorPayload {
    if (response_value != .object) return null;
    const error_value = response_value.object.get("error") orelse return null;
    if (error_value != .object) return error.InvalidMcpResponse;
    const code = try parseMcpJsonRpcErrorCode(error_value.object.get("code") orelse return error.InvalidMcpResponse);
    const message_value = error_value.object.get("message") orelse return error.InvalidMcpResponse;
    if (message_value != .string) return error.InvalidMcpResponse;

    const message = try allocator.dupe(u8, message_value.string);
    errdefer allocator.free(message);
    const data_json = if (error_value.object.get("data")) |data|
        try std.json.Stringify.valueAlloc(allocator, data, .{})
    else
        null;
    errdefer if (data_json) |json| allocator.free(json);

    return .{
        .code = code,
        .message = message,
        .data_json = data_json,
    };
}

fn parseMcpJsonRpcErrorCode(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |code| code,
        .number_string => |code| std.fmt.parseInt(i64, code, 10) catch return error.InvalidMcpResponse,
        else => error.InvalidMcpResponse,
    };
}

const JsonRpcMethodResultKind = enum {
    resource_read,
    tool_call,
};

fn renderJsonRpcMethodResult(
    allocator: std.mem.Allocator,
    response_value: std.json.Value,
    kind: JsonRpcMethodResultKind,
) !JsonRpcMethodResult {
    if (try parseMcpJsonRpcErrorPayload(allocator, response_value)) |payload| {
        return .{ .rpc_error = payload };
    }

    const result = try jsonRpcResultValue(response_value);
    const result_json = switch (kind) {
        .resource_read => try renderResourceReadResult(allocator, result),
        .tool_call => try renderToolCallResult(allocator, result),
    };
    return .{ .result_json = result_json };
}

fn renderCallResult(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    const text = try renderTextContent(allocator, result);
    defer allocator.free(text);
    if (text.len > 0) return allocator.dupe(u8, text);
    return std.json.Stringify.valueAlloc(allocator, result, .{});
}

fn listStatusTools(allocator: std.mem.Allocator, client: anytype, next_id: *i64) ![]const u8 {
    const id = next_id.*;
    next_id.* += 1;
    var response = try client.request(id, "tools/list", null);
    defer response.deinit();
    return renderStatusToolsFromResponse(allocator, response.value);
}

fn renderStatusToolsFromResponse(allocator: std.mem.Allocator, response_value: std.json.Value) ![]const u8 {
    const result = try jsonRpcResultValue(response_value);
    if (result != .object) return error.InvalidMcpResponse;
    const tools = result.object.get("tools") orelse return error.InvalidMcpResponse;
    if (tools != .array) return error.InvalidMcpResponse;
    return renderStatusTools(allocator, tools);
}

fn listStatusResources(allocator: std.mem.Allocator, client: anytype, next_id: *i64) ![]const u8 {
    return listStatusItems(allocator, client, next_id, "resources/list", "resources", null, "name", "uri");
}

fn listStatusResourceTemplates(allocator: std.mem.Allocator, client: anytype, next_id: *i64) ![]const u8 {
    return listStatusItems(allocator, client, next_id, "resources/templates/list", "resourceTemplates", "resource_templates", "name", "uriTemplate");
}

fn listStatusItems(
    allocator: std.mem.Allocator,
    client: anytype,
    next_id: *i64,
    method: []const u8,
    primary_items_key: []const u8,
    alternate_items_key: ?[]const u8,
    first_required_string: []const u8,
    second_required_string: []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var seen_cursors = std.ArrayList([]const u8).empty;
    defer {
        for (seen_cursors.items) |cursor| allocator.free(cursor);
        seen_cursors.deinit(allocator);
    }

    try out.append(allocator, '[');
    var first_item = true;
    var cursor: ?[]const u8 = null;

    while (true) {
        const params = if (cursor) |cursor_value|
            try buildCursorParams(allocator, cursor_value)
        else
            null;
        defer if (params) |params_json| allocator.free(params_json);

        const id = next_id.*;
        next_id.* += 1;
        var response = try client.request(id, method, params);
        defer response.deinit();

        try appendStatusItemsFromResponse(
            allocator,
            &out,
            response.value,
            primary_items_key,
            alternate_items_key,
            first_required_string,
            second_required_string,
            &first_item,
        );

        const next_cursor = (try statusNextCursor(response.value)) orelse break;
        for (seen_cursors.items) |seen| {
            if (std.mem.eql(u8, seen, next_cursor)) return error.InvalidMcpResponse;
        }
        const cursor_copy = try allocator.dupe(u8, next_cursor);
        errdefer allocator.free(cursor_copy);
        try seen_cursors.append(allocator, cursor_copy);
        cursor = cursor_copy;
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendStatusItemsFromResponse(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    response_value: std.json.Value,
    primary_items_key: []const u8,
    alternate_items_key: ?[]const u8,
    first_required_string: []const u8,
    second_required_string: []const u8,
    first_item: *bool,
) !void {
    const result = try jsonRpcResultValue(response_value);
    if (result != .object) return error.InvalidMcpResponse;
    const items = result.object.get(primary_items_key) orelse if (alternate_items_key) |key|
        result.object.get(key) orelse return error.InvalidMcpResponse
    else
        return error.InvalidMcpResponse;
    if (items != .array) return error.InvalidMcpResponse;

    for (items.array.items) |item| {
        if (!isStatusItemWithRequiredStrings(item, first_required_string, second_required_string)) continue;
        if (!first_item.*) try out.append(allocator, ',');
        first_item.* = false;
        const item_json = try std.json.Stringify.valueAlloc(allocator, item, .{});
        defer allocator.free(item_json);
        try out.appendSlice(allocator, item_json);
    }
}

fn statusNextCursor(response_value: std.json.Value) !?[]const u8 {
    const result = try jsonRpcResultValue(response_value);
    if (result != .object) return error.InvalidMcpResponse;
    const next_cursor = result.object.get("nextCursor") orelse result.object.get("next_cursor") orelse return null;
    if (next_cursor == .null) return null;
    if (next_cursor != .string) return error.InvalidMcpResponse;
    return next_cursor.string;
}

fn isStatusItemWithRequiredStrings(item: std.json.Value, first_required_string: []const u8, second_required_string: []const u8) bool {
    if (item != .object) return false;
    const first = item.object.get(first_required_string) orelse return false;
    if (first != .string or first.string.len == 0) return false;
    const second = item.object.get(second_required_string) orelse return false;
    return second == .string and second.string.len > 0;
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

test "mcp http response parser reads SSE JSON-RPC events" {
    const allocator = std.testing.allocator;
    var parsed = try parseHttpResponse(
        allocator,
        "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n\ndata: [DONE]\n\n",
        2,
    );
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result == .object);
    const rendered = try renderToolCallResult(allocator, result);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}",
        rendered,
    );
}

test "mcp http response parser preserves JSON-RPC error payloads" {
    const allocator = std.testing.allocator;
    var parsed = try parseHttpResponse(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32002,\"message\":\"missing resource\",\"data\":{\"uri\":\"test://missing\"}}}",
        2,
    );
    defer parsed.deinit();

    const payload = (try parseMcpJsonRpcErrorPayload(allocator, parsed.value)).?;
    defer payload.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -32002), payload.code);
    try std.testing.expectEqualStrings("missing resource", payload.message);
    try std.testing.expectEqualStrings("{\"uri\":\"test://missing\"}", payload.data_json.?);
}

test "mcp http stream parser waits for matching SSE JSON-RPC id" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(
        "event: message\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ignored\":true}}\n\n" ++
            "event: message\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"from get\"}]}}\n\n",
    );
    var parsed = try parseSseResponseFromReader(allocator, &reader, 2);
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result == .object);
    const rendered = try renderToolCallResult(allocator, result);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"content\":[{\"type\":\"text\",\"text\":\"from get\"}]}",
        rendered,
    );
}
