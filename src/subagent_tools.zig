const std = @import("std");

const features_cmd = @import("features_cmd.zig");
const model_catalog = @import("model_catalog.zig");

pub const multi_agent_v1_namespace = "multi_agent_v1";
pub const multi_agent_v1_namespace_description = "Tools for spawning and managing sub-agents.";
const spawn_agent_tool_name = "spawn_agent";
const spawn_agent_inherited_model_guidance = "Spawned agents inherit your current model by default. Omit `model` to use that preferred default; set `model` only when an explicit override is needed.";
const spawn_agent_model_override_description = "Optional model override for the new agent. Leave unset to inherit the same model as the parent, which is the preferred default. Only set this when the user explicitly asks for a different model or the task clearly requires one.";
const spawn_agent_service_tier_override_description = "Optional service tier override for the new agent. Leave unset unless the user explicitly asks for one.";
const max_model_overrides_in_spawn_agent_description = 5;

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
        .name = spawn_agent_tool_name,
        .description = "Spawn a sub-agent for a scoped parallel task only when the user explicitly asks for sub-agents, delegation, or parallel agent work. The child inherits the current model unless model is set. Decide what work stays local before delegating.",
        .parameters_json =
        \\{"type":"object","properties":{"message":{"type":"string","description":"Initial plain-text task for the new agent. Use either message or items."},"items":
        ++ collab_input_items_schema_json ++
            \\,"agent_type":{"type":"string","description":"Optional sub-agent role."},"fork_context":{"type":"boolean","description":"When true, fork the current thread history into the new agent before sending the initial prompt."},"model":{"type":"string","description":"
        ++ spawn_agent_model_override_description ++
            \\"},"reasoning_effort":{"type":"string","description":"Optional reasoning effort override for the new agent."},"service_tier":{"type":"string","description":"
        ++ spawn_agent_service_tier_override_description ++
            \\"}},"additionalProperties":false}
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
        if (std.mem.eql(u8, tool.name, spawn_agent_tool_name)) {
            score += scoreSpawnAgentModelOverrideToken(token);
        }
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
    var owned_description: ?[]const u8 = null;
    defer if (owned_description) |description| allocator.free(description);
    const description = if (std.mem.eql(u8, tool.name, spawn_agent_tool_name)) blk: {
        owned_description = try spawnAgentDescription(allocator);
        break :blk owned_description.?;
    } else tool.description;
    const description_json = try std.json.Stringify.valueAlloc(allocator, description, .{});
    defer allocator.free(description_json);

    try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
    try out.appendSlice(allocator, name_json);
    try out.appendSlice(allocator, ",\"description\":");
    try out.appendSlice(allocator, description_json);
    try out.appendSlice(allocator, ",\"strict\":false,\"defer_loading\":true,\"parameters\":");
    try out.appendSlice(allocator, tool.parameters_json);
    try out.append(allocator, '}');
}

fn spawnAgentDescription(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(
        allocator,
        "Spawn a sub-agent for a well-scoped task. " ++
            spawn_agent_inherited_model_guidance ++
            "\nThis spawn_agent tool provides you access to sub-agents that inherit your current model by default. Do not set the `model` field unless the user explicitly asks for a different model or there is a clear task-specific reason. You should follow the rules and guidelines below to use this tool.\n\n" ++
            "Only use `spawn_agent` if and only if the user explicitly asks for sub-agents, delegation, or parallel agent work.\n" ++
            "Requests for depth, thoroughness, research, investigation, or detailed codebase analysis do not count as permission to spawn.\n" ++
            "Agent-role guidance below only helps choose which agent to use after spawning is already authorized; it never authorizes spawning by itself.\n\n",
    );

    var visible_count: usize = 0;
    for (model_catalog.bundled_models) |model| {
        if (model.hidden()) continue;
        if (visible_count == 0) {
            try out.appendSlice(allocator, "Available model overrides (optional; inherited parent model is preferred):");
        }
        if (visible_count >= max_model_overrides_in_spawn_agent_description) break;
        try out.append(allocator, '\n');
        try appendSpawnAgentModelDescription(allocator, &out, model);
        visible_count += 1;
    }
    if (visible_count == 0) {
        try out.appendSlice(allocator, "No picker-visible model overrides are currently loaded.");
    }
    return out.toOwnedSlice(allocator);
}

fn appendSpawnAgentModelDescription(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    model: model_catalog.Entry,
) !void {
    try out.appendSlice(allocator, "- `");
    try out.appendSlice(allocator, model.slug);
    try out.appendSlice(allocator, "`: ");
    try out.appendSlice(allocator, model.description);
    if (model.supported_reasoning_levels.len > 0) {
        try out.appendSlice(allocator, " Reasoning efforts: ");
        for (model.supported_reasoning_levels, 0..) |reasoning, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, reasoning.effort);
            if (std.mem.eql(u8, reasoning.effort, model.default_reasoning_level)) {
                try out.appendSlice(allocator, " (default)");
            }
        }
        try out.append(allocator, '.');
    }
    if (model.service_tiers.len > 0) {
        try out.appendSlice(allocator, " Service tiers: ");
        for (model.service_tiers, 0..) |tier, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, tier.id);
        }
        try out.append(allocator, '.');
    }
}

fn scoreSpawnAgentModelOverrideToken(token: []const u8) usize {
    var score: usize = 0;
    var visible_count: usize = 0;
    for (model_catalog.bundled_models) |model| {
        if (model.hidden()) continue;
        if (visible_count >= max_model_overrides_in_spawn_agent_description) break;
        score += scoreSearchText(model.slug, token, 6);
        for (model.supported_reasoning_levels) |reasoning| {
            score += scoreSearchText(reasoning.effort, token, 3);
        }
        for (model.service_tiers) |tier| {
            score += scoreSearchText(tier.id, token, 4);
        }
        visible_count += 1;
    }
    return score;
}

fn scoreSearchText(haystack: []const u8, needle: []const u8, weight: usize) usize {
    if (containsAsciiIgnoreCase(haystack, needle)) return needle.len * weight;
    return 0;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}
