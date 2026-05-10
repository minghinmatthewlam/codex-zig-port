const std = @import("std");

const config = @import("config.zig");

pub const EVENT_COUNT = 8;

pub const Event = enum {
    pre_tool_use,
    permission_request,
    post_tool_use,
    pre_compact,
    post_compact,
    session_start,
    user_prompt_submit,
    stop,

    pub fn configLabel(self: Event) []const u8 {
        return switch (self) {
            .pre_tool_use => "PreToolUse",
            .permission_request => "PermissionRequest",
            .post_tool_use => "PostToolUse",
            .pre_compact => "PreCompact",
            .post_compact => "PostCompact",
            .session_start => "SessionStart",
            .user_prompt_submit => "UserPromptSubmit",
            .stop => "Stop",
        };
    }

    pub fn index(self: Event) usize {
        return switch (self) {
            .pre_tool_use => 0,
            .permission_request => 1,
            .post_tool_use => 2,
            .pre_compact => 3,
            .post_compact => 4,
            .session_start => 5,
            .user_prompt_submit => 6,
            .stop => 7,
        };
    }
};

pub const EVENT_ORDER = [_]Event{
    .pre_tool_use,
    .permission_request,
    .post_tool_use,
    .pre_compact,
    .post_compact,
    .session_start,
    .user_prompt_submit,
    .stop,
};

pub const HookHandlerKind = enum {
    command,
    prompt,
    agent,

    pub fn label(self: HookHandlerKind) []const u8 {
        return switch (self) {
            .command => "command",
            .prompt => "prompt",
            .agent => "agent",
        };
    }
};

pub const HookHandler = struct {
    kind: HookHandlerKind,
    command: ?[]const u8 = null,
    timeout_sec: ?u64 = null,
    async_handler: bool = false,
    status_message: ?[]const u8 = null,

    fn deinit(self: HookHandler, allocator: std.mem.Allocator) void {
        if (self.command) |value| allocator.free(value);
        if (self.status_message) |value| allocator.free(value);
    }
};

pub const MatcherGroup = struct {
    matcher: ?[]const u8 = null,
    hooks: []HookHandler = &.{},

    fn deinit(self: MatcherGroup, allocator: std.mem.Allocator) void {
        if (self.matcher) |value| allocator.free(value);
        for (self.hooks) |hook| hook.deinit(allocator);
        allocator.free(self.hooks);
    }
};

pub const MatcherGroupList = struct {
    items: []MatcherGroup = &.{},

    fn deinit(self: *MatcherGroupList, allocator: std.mem.Allocator) void {
        for (self.items) |group| group.deinit(allocator);
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub const ManagedHooksRequirements = struct {
    managed_dir: ?[]const u8 = null,
    windows_managed_dir: ?[]const u8 = null,
    events: [EVENT_COUNT]MatcherGroupList,

    pub fn init() ManagedHooksRequirements {
        var events: [EVENT_COUNT]MatcherGroupList = undefined;
        for (&events) |*event| event.* = .{};
        return .{ .events = events };
    }

    pub fn deinit(self: *ManagedHooksRequirements, allocator: std.mem.Allocator) void {
        if (self.managed_dir) |value| allocator.free(value);
        if (self.windows_managed_dir) |value| allocator.free(value);
        for (&self.events) |*event| event.deinit(allocator);
        self.* = ManagedHooksRequirements.init();
    }

    fn isEmpty(self: ManagedHooksRequirements) bool {
        if (self.managed_dir != null or self.windows_managed_dir != null) return false;
        for (self.events) |event| {
            if (event.items.len > 0) return false;
        }
        return true;
    }
};

const GroupBuilder = struct {
    event: Event,
    matcher: ?[]const u8 = null,
    hooks: std.ArrayList(HookHandler) = .empty,

    fn deinit(self: *GroupBuilder, allocator: std.mem.Allocator) void {
        if (self.matcher) |value| allocator.free(value);
        for (self.hooks.items) |hook| hook.deinit(allocator);
        self.hooks.deinit(allocator);
        self.* = .{ .event = .pre_tool_use };
    }
};

const PartialHandler = struct {
    type_name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    timeout_sec: ?u64 = null,
    async_handler: bool = false,
    status_message: ?[]const u8 = null,

    fn deinit(self: *PartialHandler, allocator: std.mem.Allocator) void {
        if (self.type_name) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.status_message) |value| allocator.free(value);
        self.* = .{};
    }
};

const Section = enum {
    none,
    hooks_root,
    group,
    hook,
};

const HookHeader = struct {
    kind: enum { group, hook },
    event: Event,
};

pub fn parse(allocator: std.mem.Allocator, payload: []const u8) !?ManagedHooksRequirements {
    var result = ManagedHooksRequirements.init();
    errdefer result.deinit(allocator);

    var groups = std.ArrayList(GroupBuilder).empty;
    defer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    var current_group_index: ?usize = null;
    var current_handler: ?PartialHandler = null;
    defer if (current_handler) |*handler| handler.deinit(allocator);

    var section: Section = .none;
    var iter = std.mem.splitScalar(u8, payload, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (parseHookHeader(line)) |header| {
            try flushPartialHandler(allocator, &groups, current_group_index, &current_handler);
            switch (header.kind) {
                .group => {
                    try groups.append(allocator, .{ .event = header.event });
                    current_group_index = groups.items.len - 1;
                    section = .group;
                },
                .hook => {
                    if (current_group_index == null or groups.items[current_group_index.?].event != header.event) {
                        try groups.append(allocator, .{ .event = header.event });
                        current_group_index = groups.items.len - 1;
                    }
                    current_handler = .{};
                    section = .hook;
                },
            }
            continue;
        }

        if (isTomlHeader(line)) {
            try flushPartialHandler(allocator, &groups, current_group_index, &current_handler);
            current_group_index = null;
            section = if (isExactSection(line, "hooks")) .hooks_root else .none;
            continue;
        }

        switch (section) {
            .hooks_root => try updateRootFromLine(allocator, &result, line),
            .group => if (current_group_index) |index| {
                if (try tomlStringValueForKey(allocator, line, "matcher")) |matcher| {
                    if (groups.items[index].matcher) |previous| allocator.free(previous);
                    groups.items[index].matcher = matcher;
                }
            },
            .hook => if (current_handler) |*handler| {
                try updatePartialHandlerFromLine(allocator, handler, line);
            },
            .none => {},
        }
    }

    try flushPartialHandler(allocator, &groups, current_group_index, &current_handler);
    try finishGroups(allocator, groups.items, &result);

    if (result.isEmpty()) return null;
    return result;
}

fn updateRootFromLine(allocator: std.mem.Allocator, result: *ManagedHooksRequirements, line: []const u8) !void {
    if (try tomlStringValueForKey(allocator, line, "managed_dir")) |value| {
        replaceOptionalString(allocator, &result.managed_dir, value);
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "windows_managed_dir")) |value| {
        replaceOptionalString(allocator, &result.windows_managed_dir, value);
    }
}

fn updatePartialHandlerFromLine(allocator: std.mem.Allocator, handler: *PartialHandler, line: []const u8) !void {
    if (try tomlStringValueForKey(allocator, line, "type")) |value| {
        replaceOptionalString(allocator, &handler.type_name, value);
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "command")) |value| {
        replaceOptionalString(allocator, &handler.command, value);
        return;
    }
    if (try tomlStringValueForKey(allocator, line, "statusMessage")) |value| {
        replaceOptionalString(allocator, &handler.status_message, value);
        return;
    }
    if (tomlUnsignedValueForKey(line, "timeout")) |value| {
        handler.timeout_sec = value;
        return;
    }
    if (tomlUnsignedValueForKey(line, "timeoutSec")) |value| {
        handler.timeout_sec = value;
        return;
    }
    if (tomlBoolValueForKey(line, "async")) |value| {
        handler.async_handler = value;
    }
}

fn flushPartialHandler(
    allocator: std.mem.Allocator,
    groups: *std.ArrayList(GroupBuilder),
    current_group_index: ?usize,
    current_handler: *?PartialHandler,
) !void {
    if (current_handler.* == null) return;
    var handler = current_handler.*.?;
    current_handler.* = null;
    defer handler.deinit(allocator);

    const group_index = current_group_index orelse return error.InvalidHooksRequirement;
    const kind = parseHookHandlerKind(handler.type_name orelse return error.InvalidHooksRequirement) orelse return error.InvalidHooksRequirement;
    var owned = HookHandler{
        .kind = kind,
        .timeout_sec = handler.timeout_sec,
        .async_handler = handler.async_handler,
    };
    switch (kind) {
        .command => {
            owned.command = handler.command orelse return error.InvalidHooksRequirement;
            handler.command = null;
            owned.status_message = handler.status_message;
            handler.status_message = null;
        },
        .prompt, .agent => {},
    }
    errdefer owned.deinit(allocator);
    try groups.items[group_index].hooks.append(allocator, owned);
}

fn finishGroups(allocator: std.mem.Allocator, groups: []GroupBuilder, result: *ManagedHooksRequirements) !void {
    var lists: [EVENT_COUNT]std.ArrayList(MatcherGroup) = undefined;
    for (&lists) |*list| list.* = .empty;
    errdefer {
        for (&lists) |*list| {
            for (list.items) |group| group.deinit(allocator);
            list.deinit(allocator);
        }
    }

    for (groups) |*group| {
        const hooks = try group.hooks.toOwnedSlice(allocator);
        group.hooks = .empty;
        var owned_group = MatcherGroup{
            .matcher = group.matcher,
            .hooks = hooks,
        };
        group.matcher = null;
        errdefer owned_group.deinit(allocator);
        try lists[group.event.index()].append(allocator, owned_group);
    }

    for (&lists, 0..) |*list, index| {
        result.events[index].items = try list.toOwnedSlice(allocator);
    }
}

fn parseHookHeader(line: []const u8) ?HookHeader {
    if (line.len < 4 or !std.mem.startsWith(u8, line, "[[") or !std.mem.endsWith(u8, line, "]]")) return null;
    const inner = std.mem.trim(u8, line[2 .. line.len - 2], " \t\r");
    if (!std.mem.startsWith(u8, inner, "hooks.")) return null;
    const rest = inner["hooks.".len..];
    if (std.mem.endsWith(u8, rest, ".hooks")) {
        const event = eventFromConfigLabel(rest[0 .. rest.len - ".hooks".len]) orelse return null;
        return .{ .kind = .hook, .event = event };
    }
    const event = eventFromConfigLabel(rest) orelse return null;
    return .{ .kind = .group, .event = event };
}

fn eventFromConfigLabel(label: []const u8) ?Event {
    for (EVENT_ORDER) |event| {
        if (std.mem.eql(u8, label, event.configLabel())) return event;
    }
    return null;
}

fn parseHookHandlerKind(value: []const u8) ?HookHandlerKind {
    if (std.mem.eql(u8, value, "command")) return .command;
    if (std.mem.eql(u8, value, "prompt")) return .prompt;
    if (std.mem.eql(u8, value, "agent")) return .agent;
    return null;
}

fn isTomlHeader(line: []const u8) bool {
    return line.len > 0 and line[0] == '[';
}

fn isExactSection(line: []const u8, section_name: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[1] == '[' or line[line.len - 1] != ']') return false;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    return std.mem.eql(u8, name, section_name);
}

fn tomlStringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const rhs = tomlRawValueForKey(line, key) orelse return null;
    return try parseTomlStringValue(allocator, rhs) orelse error.InvalidHooksRequirement;
}

fn tomlRawValueForKey(line: []const u8, key: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    return std.mem.trim(u8, line[eq + 1 ..], " \t");
}

fn tomlBoolValueForKey(line: []const u8, key: []const u8) ?bool {
    const rhs = tomlRawValueForKey(line, key) orelse return null;
    const value = stripInlineComment(rhs);
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn tomlUnsignedValueForKey(line: []const u8, key: []const u8) ?u64 {
    const rhs = tomlRawValueForKey(line, key) orelse return null;
    return std.fmt.parseUnsigned(u64, stripInlineComment(rhs), 10) catch null;
}

fn parseTomlStringValue(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"') {
        return config.parseTomlString(allocator, trimmed);
    }
    if (trimmed[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '\'') orelse return error.InvalidHooksRequirement;
        const value = try allocator.dupe(u8, trimmed[1..end]);
        return @as(?[]const u8, value);
    }
    return null;
}

fn stripInlineComment(raw: []const u8) []const u8 {
    const value = if (std.mem.indexOfScalar(u8, raw, '#')) |index| raw[0..index] else raw;
    return std.mem.trim(u8, value, " \t");
}

fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, value: []const u8) void {
    if (slot.*) |previous| allocator.free(previous);
    slot.* = value;
}
