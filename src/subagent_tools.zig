const std = @import("std");

const features_cmd = @import("features_cmd.zig");

pub const multi_agent_v1_namespace = "multi_agent_v1";
pub const multi_agent_v1_namespace_description = "Tools for spawning and managing sub-agents.";

pub const V1ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

const collab_input_items_schema_json =
    \\{"type":"array","description":"Structured input items for text, images, local images, skills, and mentions.","items":{"type":"object","properties":{"type":{"type":"string","description":"Input item type: text, image, local_image, skill, or mention."},"text":{"type":"string","description":"Text content when type is text."},"image_url":{"type":"string","description":"Image URL when type is image."},"path":{"type":"string","description":"Path when type is local_image or skill, or structured mention target when type is mention."},"name":{"type":"string","description":"Display name when type is skill or mention."}},"additionalProperties":false}}
;

pub const v1_tool_specs = [_]V1ToolSpec{
    .{
        .name = "spawn_agent",
        .description = "Spawn a sub-agent for a scoped parallel task only when the user explicitly asks for sub-agents, delegation, or parallel agent work. The child inherits the current model unless model is set. Decide what work stays local before delegating.",
        .parameters_json =
        \\{"type":"object","properties":{"message":{"type":"string","description":"Initial plain-text task for the new agent. Use either message or items."},"items":
        ++ collab_input_items_schema_json ++
            \\,"agent_type":{"type":"string","description":"Optional sub-agent role."},"fork_context":{"type":"boolean","description":"When true, fork the current thread history into the new agent before sending the initial prompt."},"model":{"type":"string","description":"Optional model override for the new agent. Omit to inherit the parent model."},"reasoning_effort":{"type":"string","description":"Optional reasoning effort override for the new agent."},"service_tier":{"type":"string","description":"Optional service tier override for the new agent."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "send_input",
        .description = "Send a message to an existing agent. Use interrupt=true only when the agent's current work should be redirected immediately.",
        .parameters_json =
        \\{"type":"object","properties":{"target":{"type":"string","description":"Agent id to message, from spawn_agent."},"message":{"type":"string","description":"Plain-text message to send to the agent."},"items":
        ++ collab_input_items_schema_json ++
            \\,"interrupt":{"type":"boolean","description":"When true, interrupt the agent's current task; otherwise queue the message."}},"required":["target"],"additionalProperties":false}
        ,
    },
    .{
        .name = "resume_agent",
        .description = "Resume a previously closed agent by id so it can receive send_input and wait_agent calls.",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Agent id to resume."}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "wait_agent",
        .description = "Wait for agents to reach a final status. Returns final statuses keyed by agent id, or an empty status object on timeout.",
        .parameters_json =
        \\{"type":"object","properties":{"targets":{"type":"array","description":"Agent ids to wait on. Pass multiple ids to wait for whichever finishes first.","items":{"type":"string"}},"timeout_ms":{"type":"number","description":"Optional timeout in milliseconds."}},"required":["targets"],"additionalProperties":false}
        ,
    },
    .{
        .name = "close_agent",
        .description = "Close an agent and open descendants when they are no longer needed, returning the target's previous status before shutdown was requested.",
        .parameters_json =
        \\{"type":"object","properties":{"target":{"type":"string","description":"Agent id to close, from spawn_agent."}},"required":["target"],"additionalProperties":false}
        ,
    },
};

const v1_common_search_text =
    "multi_agent_v1 subagent sub-agent agent agents delegation delegate parallel worker explorer";

pub fn v1ToolSearchEnabled(feature_overrides: features_cmd.FeatureOverrides) bool {
    const multi_agent_enabled = feature_overrides.get("multi_agent") orelse true;
    const multi_agent_v2_enabled = feature_overrides.get("multi_agent_v2") orelse false;
    return multi_agent_enabled and !multi_agent_v2_enabled;
}

pub fn appendToolSearchSourceDescription(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "- Multi-agent tools: spawn and manage sub-agents.\n");
}

pub fn scoreV1ToolSearch(query: []const u8, tool: V1ToolSpec) usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        if (containsAsciiIgnoreCase(v1_common_search_text, token)) score += token.len;
        if (containsAsciiIgnoreCase(tool.name, token)) score += token.len * 4;
        if (containsAsciiIgnoreCase(tool.description, token)) score += token.len * 3;
        if (containsAsciiIgnoreCase(tool.parameters_json, token)) score += token.len * 2;
    }
    if (containsAsciiIgnoreCase(tool.name, query)) score += query.len * 4;
    if (containsAsciiIgnoreCase(tool.description, query)) score += query.len * 3;
    if (containsAsciiIgnoreCase(tool.parameters_json, query)) score += query.len * 2;
    return score;
}

pub fn appendV1NamespaceJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tool_indexes: []const usize) !void {
    const namespace_name_json = try std.json.Stringify.valueAlloc(allocator, multi_agent_v1_namespace, .{});
    defer allocator.free(namespace_name_json);
    const namespace_description_json = try std.json.Stringify.valueAlloc(allocator, multi_agent_v1_namespace_description, .{});
    defer allocator.free(namespace_description_json);

    try out.appendSlice(allocator, "{\"type\":\"namespace\",\"name\":");
    try out.appendSlice(allocator, namespace_name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, namespace_description_json);
    try out.appendSlice(allocator, ",\"tools\":[");
    for (tool_indexes, 0..) |tool_index, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendV1ToolJson(allocator, out, v1_tool_specs[tool_index]);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendV1ToolJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tool: V1ToolSpec) !void {
    const name_json = try std.json.Stringify.valueAlloc(allocator, tool.name, .{});
    defer allocator.free(name_json);
    const description_json = try std.json.Stringify.valueAlloc(allocator, tool.description, .{});
    defer allocator.free(description_json);

    try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    try out.appendSlice(allocator, ",\"strict\":false,\"defer_loading\":true,\"parameters\":");
    try out.appendSlice(allocator, tool.parameters_json);
    try out.append(allocator, '}');
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}
