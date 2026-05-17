const std = @import("std");

pub const ReasoningLevel = struct {
    effort: []const u8,
    description: []const u8,
};

pub const Upgrade = struct {
    model: []const u8,
    upgrade_copy: ?[]const u8 = null,
    model_link: ?[]const u8 = null,
    migration_markdown: ?[]const u8 = null,
};

pub const AvailabilityNux = struct {
    message: []const u8,
};

pub const ServiceTier = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Entry = struct {
    slug: []const u8,
    display_name: []const u8,
    description: []const u8,
    default_reasoning_level: []const u8,
    supported_reasoning_levels: []const ReasoningLevel,
    input_modalities: []const []const u8,
    supports_parallel_tool_calls: bool = true,
    supported_in_api: bool = true,
    visibility: []const u8 = "list",
    priority: u32,
    availability_nux: ?AvailabilityNux = null,
    upgrade: ?Upgrade = null,
    supports_personality: bool = false,
    support_verbosity: bool = false,
    default_verbosity: ?[]const u8 = null,
    additional_speed_tiers: []const []const u8 = &.{},
    service_tiers: []const ServiceTier = &.{},

    pub fn hidden(self: Entry) bool {
        return !std.mem.eql(u8, self.visibility, "list");
    }
};

const standard_reasoning_levels = [_]ReasoningLevel{
    .{ .effort = "low", .description = "Fast responses with lighter reasoning" },
    .{ .effort = "medium", .description = "Balances speed and reasoning depth for everyday tasks" },
    .{ .effort = "high", .description = "Greater reasoning depth for complex problems" },
    .{ .effort = "xhigh", .description = "Extra high reasoning depth for complex problems" },
};

const gpt_5_2_reasoning_levels = [_]ReasoningLevel{
    .{ .effort = "low", .description = "Balances speed with some reasoning; useful for straightforward queries and short explanations" },
    .{ .effort = "medium", .description = "Provides a solid balance of reasoning depth and latency for general-purpose tasks" },
    .{ .effort = "high", .description = "Maximizes reasoning depth for complex or ambiguous problems" },
    .{ .effort = "xhigh", .description = "Extra high reasoning for complex problems" },
};

const text_image_modalities = [_][]const u8{ "text", "image" };
const fast_speed_tiers = [_][]const u8{"fast"};

const gpt_5_5_nux =
    "GPT-5.5 is now available in Codex. It's our strongest agentic coding model yet, built to reason through large codebases, check assumptions with tools, and keep going until the work is done.\n\n" ++
    "Learn more: https://openai.com/index/introducing-gpt-5-5/\n\n";

const gpt_5_4_migration =
    "Introducing GPT-5.4\n\n" ++
    "Codex just got an upgrade with GPT-5.4, our most capable model for professional work. It outperforms prior models while being more token efficient, with notable improvements on long-running tasks, tool calling, computer use, and frontend development.\n\n" ++
    "Learn more: https://openai.com/index/introducing-gpt-5-4\n\n" ++
    "You can always keep using GPT-5.3-Codex if you prefer.\n";

pub const bundled_models = [_]Entry{
    .{
        .slug = "gpt-5.5",
        .display_name = "GPT-5.5",
        .description = "Frontier model for complex coding, research, and real-world work.",
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 0,
        .availability_nux = .{ .message = gpt_5_5_nux },
        .support_verbosity = true,
        .default_verbosity = "low",
        .additional_speed_tiers = fast_speed_tiers[0..],
    },
    .{
        .slug = "gpt-5.4",
        .display_name = "gpt-5.4",
        .description = "Strong model for everyday coding.",
        .default_reasoning_level = "xhigh",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 2,
        .support_verbosity = true,
        .default_verbosity = "low",
        .additional_speed_tiers = fast_speed_tiers[0..],
    },
    .{
        .slug = "gpt-5.4-mini",
        .display_name = "GPT-5.4-Mini",
        .description = "Small, fast, and cost-efficient model for simpler coding tasks.",
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 4,
        .support_verbosity = true,
        .default_verbosity = "medium",
    },
    .{
        .slug = "gpt-5.3-codex",
        .display_name = "gpt-5.3-codex",
        .description = "Coding-optimized model.",
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 6,
        .support_verbosity = true,
        .default_verbosity = "low",
        .upgrade = .{ .model = "gpt-5.4", .migration_markdown = gpt_5_4_migration },
    },
    .{
        .slug = "gpt-5.2",
        .display_name = "gpt-5.2",
        .description = "Optimized for professional work and long-running agents.",
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = gpt_5_2_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 10,
        .support_verbosity = true,
        .default_verbosity = "low",
        .upgrade = .{ .model = "gpt-5.4", .migration_markdown = gpt_5_4_migration },
    },
    .{
        .slug = "codex-auto-review",
        .display_name = "Codex Auto Review",
        .description = "Automatic approval review model for Codex.",
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .visibility = "hide",
        .priority = 29,
        .support_verbosity = true,
        .default_verbosity = "low",
    },
};

pub fn defaultModel() Entry {
    for (bundled_models) |model| {
        if (!model.hidden()) return model;
    }
    return bundled_models[0];
}

pub fn bundledModel(slug: []const u8) ?Entry {
    for (bundled_models) |model| {
        if (std.mem.eql(u8, model.slug, slug)) return model;
    }
    return null;
}

pub fn configuredModel(slug: []const u8, description: []const u8) Entry {
    return .{
        .slug = slug,
        .display_name = slug,
        .description = description,
        .default_reasoning_level = "medium",
        .supported_reasoning_levels = standard_reasoning_levels[0..],
        .input_modalities = text_image_modalities[0..],
        .priority = 0,
    };
}
