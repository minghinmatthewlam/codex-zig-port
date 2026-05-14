const std = @import("std");
const env = @import("env.zig");
const model_catalog = @import("model_catalog.zig");

pub const Config = struct {
    codex_home: []const u8,
    active_profile: ?[]const u8,
    model: []const u8,
    openai_base_url: []const u8,
    chatgpt_base_url: []const u8,
    model_provider_wire_api: ModelProviderWireApi = .responses,
    model_provider_env_key: ?[]const u8 = null,
    model_provider_bearer_token: ?[]const u8 = null,
    model_provider_auth_command: ?ProviderAuthCommand = null,
    model_provider_query_params: ?StringMap = null,
    model_provider_http_headers: ?StringMap = null,
    model_provider_env_http_headers: ?StringMap = null,
    oss_provider: ?[]const u8,
    installation_id: []const u8,
    approval_policy: ApprovalPolicy,
    sandbox_mode: SandboxMode,
    web_search_mode: ?WebSearchMode,
    model_reasoning_effort: ?ReasoningEffort,
    model_reasoning_summary: ?ReasoningSummary = null,
    service_tier: ?[]const u8,
    syntax_theme: ?[]const u8,
    personality: ?Personality,
    forced_login_method: ?ForcedLoginMethod = null,
    forced_chatgpt_workspace_id: ?[]const u8 = null,
    tui_status_line: ?StringList,
    tui_terminal_title: ?StringList,
    tui_alternate_screen: AltScreenMode,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        if (self.active_profile) |value| allocator.free(value);
        allocator.free(self.model);
        allocator.free(self.openai_base_url);
        allocator.free(self.chatgpt_base_url);
        if (self.model_provider_env_key) |value| allocator.free(value);
        if (self.model_provider_bearer_token) |value| allocator.free(value);
        if (self.model_provider_auth_command) |*value| value.deinit(allocator);
        if (self.model_provider_query_params) |*value| value.deinit(allocator);
        if (self.model_provider_http_headers) |*value| value.deinit(allocator);
        if (self.model_provider_env_http_headers) |*value| value.deinit(allocator);
        if (self.oss_provider) |value| allocator.free(value);
        allocator.free(self.installation_id);
        if (self.service_tier) |value| allocator.free(value);
        if (self.syntax_theme) |value| allocator.free(value);
        if (self.forced_chatgpt_workspace_id) |value| allocator.free(value);
        if (self.tui_status_line) |*value| value.deinit(allocator);
        if (self.tui_terminal_title) |*value| value.deinit(allocator);
    }
};

pub const StringList = struct {
    items: []const []const u8,

    pub fn deinit(self: *StringList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.items = &.{};
    }

    pub fn clone(self: StringList, allocator: std.mem.Allocator) !StringList {
        const items = try allocator.alloc([]const u8, self.items.len);
        errdefer allocator.free(items);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |item| allocator.free(item);
        }
        for (self.items, 0..) |item, index| {
            items[index] = try allocator.dupe(u8, item);
            copied += 1;
        }
        return .{ .items = items };
    }
};

pub const ProviderAuthCommand = struct {
    command: []const u8,
    args: StringList,
    cwd: ?[]const u8 = null,
    timeout_ms: u64 = 5000,
    refresh_interval_ms: u64 = 300_000,

    pub fn deinit(self: *ProviderAuthCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.args.deinit(allocator);
        if (self.cwd) |value| allocator.free(value);
    }

    pub fn clone(self: ProviderAuthCommand, allocator: std.mem.Allocator) !ProviderAuthCommand {
        const command = try allocator.dupe(u8, self.command);
        errdefer allocator.free(command);
        var args = try self.args.clone(allocator);
        errdefer args.deinit(allocator);
        const cwd = if (self.cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);
        return .{
            .command = command,
            .args = args,
            .cwd = cwd,
            .timeout_ms = self.timeout_ms,
            .refresh_interval_ms = self.refresh_interval_ms,
        };
    }
};

pub const StringMapEntry = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: StringMapEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

fn cloneStringMapEntry(allocator: std.mem.Allocator, entry: StringMapEntry) !StringMapEntry {
    const key = try allocator.dupe(u8, entry.key);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, entry.value);
    return .{ .key = key, .value = value };
}

pub const StringMap = struct {
    entries: []StringMapEntry,

    pub fn deinit(self: *StringMap, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.entries = &.{};
    }

    pub fn clone(self: StringMap, allocator: std.mem.Allocator) !StringMap {
        const entries = try allocator.alloc(StringMapEntry, self.entries.len);
        errdefer allocator.free(entries);
        var copied: usize = 0;
        errdefer {
            for (entries[0..copied]) |entry| entry.deinit(allocator);
        }
        for (self.entries, 0..) |entry, index| {
            entries[index] = try cloneStringMapEntry(allocator, entry);
            copied += 1;
        }
        return .{ .entries = entries };
    }
};

pub const LoadOptions = struct {
    profile: ?[]const u8 = null,
    ignore_user_config: bool = false,
};

pub const RuntimeOverrides = struct {
    model: ?[]const u8 = null,
    openai_base_url: ?[]const u8 = null,
    chatgpt_base_url: ?[]const u8 = null,
    oss_provider: ?[]const u8 = null,
    approval_policy: ?ApprovalPolicy = null,
    sandbox_mode: ?SandboxMode = null,
    web_search_mode: ?WebSearchMode = null,
    service_tier: ?[]const u8 = null,
    model_reasoning_summary: ?ReasoningSummary = null,
    syntax_theme: ?[]const u8 = null,
    personality: ?Personality = null,
    tui_alternate_screen: ?AltScreenMode = null,
};

pub const SandboxPermissionProfile = struct {
    mode: SandboxMode,
    additional_writable_roots: StringList,
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,

    pub fn deinit(self: *SandboxPermissionProfile, allocator: std.mem.Allocator) void {
        self.additional_writable_roots.deinit(allocator);
    }
};

pub const AltScreenMode = enum {
    auto,
    always,
    never,

    pub fn parse(value: []const u8) !AltScreenMode {
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(value, "never")) return .never;
        return error.InvalidAltScreenMode;
    }

    pub fn label(self: AltScreenMode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .always => "always",
            .never => "never",
        };
    }
};

pub fn loadModelProviderId(allocator: std.mem.Allocator, profile: ?[]const u8) !?[]const u8 {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const config_view = ConfigView{ .bytes = config_bytes orelse "" };
    const active_profile = try resolveActiveProfile(allocator, config_view, profile);
    defer if (active_profile) |value| allocator.free(value);

    return resolveModelProviderId(allocator, config_view, active_profile);
}

pub fn loadModelProviderRequiresOpenAiAuth(allocator: std.mem.Allocator, profile: ?[]const u8) !bool {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const config_view = ConfigView{ .bytes = config_bytes orelse "" };
    const active_profile = try resolveActiveProfile(allocator, config_view, profile);
    defer if (active_profile) |value| allocator.free(value);

    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);

    return resolveModelProviderRequiresOpenAiAuth(config_view, model_provider);
}

pub fn applyRuntimeOverrides(
    cfg: *Config,
    allocator: std.mem.Allocator,
    overrides: RuntimeOverrides,
) !void {
    if (overrides.model) |model| {
        const next_model = try allocator.dupe(u8, model);
        allocator.free(cfg.model);
        cfg.model = next_model;
    }
    if (overrides.openai_base_url) |openai_base_url| {
        const next_openai_base_url = try allocator.dupe(u8, openai_base_url);
        allocator.free(cfg.openai_base_url);
        cfg.openai_base_url = next_openai_base_url;
    }
    if (overrides.chatgpt_base_url) |chatgpt_base_url| {
        const next_chatgpt_base_url = try allocator.dupe(u8, chatgpt_base_url);
        allocator.free(cfg.chatgpt_base_url);
        cfg.chatgpt_base_url = next_chatgpt_base_url;
    }
    if (overrides.oss_provider) |oss_provider| {
        const next_oss_provider = try allocator.dupe(u8, oss_provider);
        if (cfg.oss_provider) |existing| allocator.free(existing);
        cfg.oss_provider = next_oss_provider;
    }
    if (overrides.approval_policy) |approval_policy| {
        cfg.approval_policy = approval_policy;
    }
    if (overrides.sandbox_mode) |sandbox_mode| {
        cfg.sandbox_mode = sandbox_mode;
    }
    if (overrides.web_search_mode) |web_search_mode| {
        cfg.web_search_mode = web_search_mode;
    }
    if (overrides.service_tier) |service_tier| {
        const next_service_tier = try normalizeServiceTier(allocator, service_tier);
        if (cfg.service_tier) |existing| allocator.free(existing);
        cfg.service_tier = next_service_tier;
    }
    if (overrides.syntax_theme) |syntax_theme| {
        const next_syntax_theme = try allocator.dupe(u8, syntax_theme);
        if (cfg.syntax_theme) |existing| allocator.free(existing);
        cfg.syntax_theme = next_syntax_theme;
    }
    if (overrides.personality) |personality| {
        cfg.personality = personality;
    }
    if (overrides.model_reasoning_summary) |summary| {
        cfg.model_reasoning_summary = summary;
    }
    if (overrides.tui_alternate_screen) |mode| {
        cfg.tui_alternate_screen = mode;
    }
}

pub fn applyRawConfigOverride(
    runtime_overrides: *RuntimeOverrides,
    profile_override: *?[]const u8,
    raw: []const u8,
) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidConfigOverride;
    const key = std.mem.trim(u8, raw[0..eq], " \t");
    const value = trimConfigOverrideValue(raw[eq + 1 ..]);
    if (key.len == 0) return error.InvalidConfigOverride;

    if (std.mem.eql(u8, key, "profile")) {
        profile_override.* = value;
    } else if (std.mem.eql(u8, key, "model")) {
        runtime_overrides.model = value;
    } else if (std.mem.eql(u8, key, "openai_base_url")) {
        runtime_overrides.openai_base_url = value;
    } else if (std.mem.eql(u8, key, "chatgpt_base_url")) {
        runtime_overrides.chatgpt_base_url = value;
    } else if (std.mem.eql(u8, key, "oss_provider")) {
        runtime_overrides.oss_provider = value;
    } else if (std.mem.eql(u8, key, "approval_policy")) {
        runtime_overrides.approval_policy = try ApprovalPolicy.parse(value);
    } else if (std.mem.eql(u8, key, "sandbox_mode")) {
        runtime_overrides.sandbox_mode = try SandboxMode.parse(value);
    } else if (std.mem.eql(u8, key, "web_search")) {
        runtime_overrides.web_search_mode = try WebSearchMode.parse(value);
    } else if (std.mem.eql(u8, key, "service_tier")) {
        runtime_overrides.service_tier = value;
    } else if (std.mem.eql(u8, key, "syntax_theme")) {
        runtime_overrides.syntax_theme = value;
    } else if (std.mem.eql(u8, key, "personality")) {
        runtime_overrides.personality = try Personality.parse(value);
    } else if (std.mem.eql(u8, key, "model_reasoning_summary")) {
        runtime_overrides.model_reasoning_summary = try ReasoningSummary.parse(value);
    } else if (std.mem.eql(u8, key, "tui.alternate_screen") or std.mem.eql(u8, key, "tui_alternate_screen")) {
        runtime_overrides.tui_alternate_screen = try AltScreenMode.parse(value);
    }
}

pub fn loadSandboxPermissionProfile(allocator: std.mem.Allocator, profile: []const u8) !SandboxPermissionProfile {
    if (try resolveBuiltInSandboxPermissionProfile(allocator, profile)) |builtin_profile| return builtin_profile;

    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    const bytes = config_bytes orelse return error.SandboxPermissionProfileUnsupported;

    return (ConfigView{ .bytes = bytes }).resolveCustomSandboxPermissionProfile(allocator, profile);
}

fn resolveBuiltInSandboxPermissionProfile(allocator: std.mem.Allocator, profile: []const u8) !?SandboxPermissionProfile {
    const mode: SandboxMode = if (std.mem.eql(u8, profile, ":read-only"))
        .read_only
    else if (std.mem.eql(u8, profile, ":workspace"))
        .workspace_write
    else if (std.mem.eql(u8, profile, ":danger-no-sandbox"))
        .danger_full_access
    else
        return null;

    return .{
        .mode = mode,
        .additional_writable_roots = .{ .items = try allocator.alloc([]const u8, 0) },
    };
}

fn trimConfigOverrideValue(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == value[value.len - 1] and (value[0] == '"' or value[0] == '\'')) {
        return value[1 .. value.len - 1];
    }
    return value;
}

pub const ApprovalPolicy = enum {
    untrusted,
    on_failure,
    on_request,
    never,

    pub fn label(self: ApprovalPolicy) []const u8 {
        return switch (self) {
            .untrusted => "untrusted",
            .on_failure => "on-failure",
            .on_request => "on-request",
            .never => "never",
        };
    }

    pub fn parse(value: []const u8) !ApprovalPolicy {
        if (std.mem.eql(u8, value, "untrusted") or std.mem.eql(u8, value, "unless-trusted")) return .untrusted;
        if (std.mem.eql(u8, value, "on-failure") or std.mem.eql(u8, value, "on_failure")) return .on_failure;
        if (std.mem.eql(u8, value, "on-request") or std.mem.eql(u8, value, "on_request")) return .on_request;
        if (std.mem.eql(u8, value, "never")) return .never;
        return error.InvalidApprovalPolicy;
    }
};

pub const ModelProviderWireApi = enum {
    responses,

    pub fn label(self: ModelProviderWireApi) []const u8 {
        return switch (self) {
            .responses => "responses",
        };
    }

    pub fn parse(value: []const u8) !ModelProviderWireApi {
        if (std.mem.eql(u8, value, "responses")) return .responses;
        if (std.mem.eql(u8, value, "chat")) return error.RemovedModelProviderChatWireApi;
        return error.InvalidModelProviderWireApi;
    }
};

pub const SandboxMode = enum {
    read_only,
    workspace_write,
    danger_full_access,

    pub fn label(self: SandboxMode) []const u8 {
        return switch (self) {
            .read_only => "read-only",
            .workspace_write => "workspace-write",
            .danger_full_access => "danger-full-access",
        };
    }

    pub fn parse(value: []const u8) !SandboxMode {
        if (std.mem.eql(u8, value, "read-only") or std.mem.eql(u8, value, "read_only")) return .read_only;
        if (std.mem.eql(u8, value, "workspace-write") or std.mem.eql(u8, value, "workspace_write")) return .workspace_write;
        if (std.mem.eql(u8, value, "danger-full-access") or std.mem.eql(u8, value, "danger_full_access")) return .danger_full_access;
        return error.InvalidSandboxMode;
    }
};

pub const WebSearchMode = enum {
    disabled,
    cached,
    live,

    pub fn label(self: WebSearchMode) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .cached => "cached",
            .live => "live",
        };
    }

    pub fn externalWebAccess(self: WebSearchMode) ?bool {
        return switch (self) {
            .disabled => null,
            .cached => false,
            .live => true,
        };
    }

    pub fn parse(value: []const u8) !WebSearchMode {
        if (std.mem.eql(u8, value, "disabled")) return .disabled;
        if (std.mem.eql(u8, value, "cached")) return .cached;
        if (std.mem.eql(u8, value, "live")) return .live;
        return error.InvalidWebSearchMode;
    }
};

pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn label(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .none => "none",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }

    pub fn parse(value: []const u8) !ReasoningEffort {
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.eql(u8, value, "minimal")) return .minimal;
        if (std.mem.eql(u8, value, "low")) return .low;
        if (std.mem.eql(u8, value, "medium")) return .medium;
        if (std.mem.eql(u8, value, "high")) return .high;
        if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
        return error.InvalidReasoningEffort;
    }
};

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,
    none,

    pub fn label(self: ReasoningSummary) []const u8 {
        return switch (self) {
            .auto => "auto",
            .concise => "concise",
            .detailed => "detailed",
            .none => "none",
        };
    }

    pub fn parse(value: []const u8) !ReasoningSummary {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "concise")) return .concise;
        if (std.mem.eql(u8, value, "detailed")) return .detailed;
        if (std.mem.eql(u8, value, "none")) return .none;
        return error.InvalidReasoningSummary;
    }
};

pub const Personality = enum {
    none,
    friendly,
    pragmatic,

    pub fn label(self: Personality) []const u8 {
        return switch (self) {
            .none => "none",
            .friendly => "friendly",
            .pragmatic => "pragmatic",
        };
    }

    pub fn parse(value: []const u8) !Personality {
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(value, "friendly")) return .friendly;
        if (std.ascii.eqlIgnoreCase(value, "pragmatic")) return .pragmatic;
        return error.InvalidPersonality;
    }

    pub fn description(self: Personality) []const u8 {
        return switch (self) {
            .none => "No personality instructions.",
            .friendly => "Warm, collaborative, and helpful.",
            .pragmatic => "Concise, task-focused, and direct.",
        };
    }
};

pub const ForcedLoginMethod = enum {
    chatgpt,
    api,

    pub fn parse(value: []const u8) !ForcedLoginMethod {
        if (std.mem.eql(u8, value, "chatgpt")) return .chatgpt;
        if (std.mem.eql(u8, value, "api")) return .api;
        return error.InvalidForcedLoginMethod;
    }

    pub fn label(self: ForcedLoginMethod) []const u8 {
        return switch (self) {
            .chatgpt => "chatgpt",
            .api => "api",
        };
    }
};

pub const OssProvider = enum {
    lmstudio,
    ollama,

    pub fn parse(value: []const u8) !OssProvider {
        if (std.mem.eql(u8, value, "lmstudio")) return .lmstudio;
        if (std.mem.eql(u8, value, "ollama")) return .ollama;
        if (std.mem.eql(u8, value, "ollama-chat")) return error.RemovedOllamaChatProvider;
        return error.InvalidOssProvider;
    }

    pub fn label(self: OssProvider) []const u8 {
        return switch (self) {
            .lmstudio => "lmstudio",
            .ollama => "ollama",
        };
    }

    pub fn defaultModel(self: OssProvider) []const u8 {
        return switch (self) {
            .lmstudio => "openai/gpt-oss-20b",
            .ollama => "gpt-oss:20b",
        };
    }

    fn defaultPort(self: OssProvider) u16 {
        return switch (self) {
            .lmstudio => 1234,
            .ollama => 11434,
        };
    }
};

pub fn applyOssMode(
    cfg: *Config,
    allocator: std.mem.Allocator,
    provider_override: ?[]const u8,
    explicit_model: bool,
) !void {
    const provider_name = provider_override orelse cfg.oss_provider orelse return error.NoDefaultOssProviderConfigured;
    const provider = try OssProvider.parse(provider_name);

    const next_base_url = try resolveOssBaseUrl(allocator, provider);
    allocator.free(cfg.openai_base_url);
    cfg.openai_base_url = next_base_url;

    if (!explicit_model) {
        const next_model = try allocator.dupe(u8, provider.defaultModel());
        allocator.free(cfg.model);
        cfg.model = next_model;
    }
}

fn resolveOssBaseUrl(allocator: std.mem.Allocator, provider: OssProvider) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_OSS_BASE_URL")) |base_url| {
        if (std.mem.trim(u8, base_url, " \t\r\n").len > 0) return base_url;
        allocator.free(base_url);
    }

    const port = if (try env.getOwned(allocator, "CODEX_OSS_PORT")) |raw_port| blk: {
        defer allocator.free(raw_port);
        const trimmed = std.mem.trim(u8, raw_port, " \t\r\n");
        if (trimmed.len == 0) break :blk provider.defaultPort();
        break :blk try std.fmt.parseInt(u16, trimmed, 10);
    } else provider.defaultPort();

    return std.fmt.allocPrint(allocator, "http://localhost:{d}/v1", .{port});
}

pub fn webSearchLabel(mode: ?WebSearchMode) []const u8 {
    if (mode) |value| return value.label();
    return "unset";
}

const BaseUrls = struct {
    openai: []const u8,
    chatgpt: []const u8,
};

pub fn load(allocator: std.mem.Allocator) !Config {
    return loadWithOptions(allocator, .{});
}

pub fn loadFeedbackEnabled(allocator: std.mem.Allocator) !bool {
    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    return feedbackEnabledFromConfigBytes(config_bytes orelse "");
}

pub fn loadWithOptions(allocator: std.mem.Allocator, options: LoadOptions) !Config {
    const codex_home = try resolveCodexHome(allocator);
    errdefer allocator.free(codex_home);

    const config_bytes = if (options.ignore_user_config)
        null
    else
        try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const config_view = ConfigView{ .bytes = config_bytes orelse "" };

    const active_profile = try resolveActiveProfile(allocator, config_view, options.profile);
    errdefer if (active_profile) |profile| allocator.free(profile);
    if (active_profile) |profile| {
        if (!options.ignore_user_config and !config_view.hasProfile(profile)) return error.ConfigProfileNotFound;
    }

    const model = try resolveModel(allocator, config_view, active_profile);
    errdefer allocator.free(model);

    const base_urls = try resolveBaseUrls(allocator, config_view, active_profile);
    errdefer allocator.free(base_urls.openai);
    errdefer allocator.free(base_urls.chatgpt);

    const model_provider_wire_api = try resolveModelProviderWireApi(allocator, config_view, active_profile);

    var model_provider_auth = try resolveModelProviderAuth(allocator, config_view, active_profile);
    errdefer model_provider_auth.deinit(allocator);
    var model_provider_query_params = try resolveModelProviderQueryParams(allocator, config_view, active_profile);
    errdefer if (model_provider_query_params) |*value| value.deinit(allocator);
    var provider_headers = try resolveModelProviderHeaders(allocator, config_view, active_profile);
    errdefer provider_headers.deinit(allocator);

    const oss_provider = try resolveOssProvider(allocator, config_view, active_profile);
    errdefer if (oss_provider) |provider| allocator.free(provider);

    const installation_id = try readOptionalFileTrimmed(allocator, codex_home, "installation_id", "unknown-zig-port");
    errdefer allocator.free(installation_id);

    const approval_policy = try resolveApprovalPolicy(allocator, config_view, active_profile);
    const sandbox_mode = try resolveSandboxMode(allocator, config_view, active_profile);
    const web_search_mode = try resolveWebSearchMode(allocator, config_view, active_profile);
    const model_reasoning_effort = try resolveModelReasoningEffort(allocator, config_view, active_profile);
    const model_reasoning_summary = try resolveModelReasoningSummary(allocator, config_view, active_profile);
    const service_tier = try resolveServiceTier(allocator, config_view, active_profile);
    errdefer if (service_tier) |value| allocator.free(value);
    const syntax_theme = try resolveSyntaxTheme(allocator, config_view, active_profile);
    errdefer if (syntax_theme) |value| allocator.free(value);
    const personality = try resolvePersonality(allocator, config_view, active_profile);
    const forced_login_method = try resolveForcedLoginMethod(allocator, config_view, active_profile);
    const forced_chatgpt_workspace_id = try resolveForcedChatGptWorkspaceId(allocator, config_view, active_profile);
    errdefer if (forced_chatgpt_workspace_id) |value| allocator.free(value);
    var tui_status_line = try resolveTuiStringArray(allocator, config_view, "status_line");
    errdefer if (tui_status_line) |*value| value.deinit(allocator);
    var tui_terminal_title = try resolveTuiStringArray(allocator, config_view, "terminal_title");
    errdefer if (tui_terminal_title) |*value| value.deinit(allocator);
    const tui_alternate_screen = try resolveTuiAlternateScreen(allocator, config_view);

    return .{
        .codex_home = codex_home,
        .active_profile = active_profile,
        .model = model,
        .openai_base_url = base_urls.openai,
        .chatgpt_base_url = base_urls.chatgpt,
        .model_provider_wire_api = model_provider_wire_api,
        .model_provider_env_key = model_provider_auth.env_key,
        .model_provider_bearer_token = model_provider_auth.bearer_token,
        .model_provider_auth_command = model_provider_auth.command,
        .model_provider_query_params = model_provider_query_params,
        .model_provider_http_headers = provider_headers.http_headers,
        .model_provider_env_http_headers = provider_headers.env_http_headers,
        .oss_provider = oss_provider,
        .installation_id = installation_id,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .model_reasoning_effort = model_reasoning_effort,
        .model_reasoning_summary = model_reasoning_summary,
        .service_tier = service_tier,
        .syntax_theme = syntax_theme,
        .personality = personality,
        .forced_login_method = forced_login_method,
        .forced_chatgpt_workspace_id = forced_chatgpt_workspace_id,
        .tui_status_line = tui_status_line,
        .tui_terminal_title = tui_terminal_title,
        .tui_alternate_screen = tui_alternate_screen,
    };
}

pub fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_HOME")) |value| {
        return value;
    }

    const home = (try env.getOwned(allocator, "HOME")) orelse return error.MissingHome;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn resolveActiveProfile(allocator: std.mem.Allocator, config_view: ConfigView, override_profile: ?[]const u8) !?[]const u8 {
    if (override_profile) |value| {
        const profile = try allocator.dupe(u8, value);
        return profile;
    }
    if (try env.getOwned(allocator, "CODEX_ZIG_PROFILE")) |value| {
        return value;
    }
    return config_view.getScopedString(allocator, null, "profile");
}

fn resolveModel(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL")) |value| {
        return value;
    }

    if (try config_view.getScopedString(allocator, active_profile, "model")) |model| {
        return model;
    }

    return allocator.dupe(u8, model_catalog.defaultModel().slug);
}

fn resolveBaseUrls(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !BaseUrls {
    if (try env.getOwned(allocator, "CODEX_ZIG_BASE_URL")) |value| {
        errdefer allocator.free(value);
        return .{
            .openai = value,
            .chatgpt = try allocator.dupe(u8, value),
        };
    }

    var explicit_openai = try config_view.getScopedString(allocator, active_profile, "openai_base_url");
    errdefer if (explicit_openai) |value| allocator.free(value);
    var explicit_chatgpt = try config_view.getScopedString(allocator, active_profile, "chatgpt_base_url");
    errdefer if (explicit_chatgpt) |value| allocator.free(value);

    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    const provider_base_url = if (model_provider) |provider|
        try config_view.getModelProviderString(allocator, provider, "base_url")
    else
        null;
    defer if (provider_base_url) |value| allocator.free(value);

    const openai = if (explicit_openai) |value| blk: {
        explicit_openai = null;
        break :blk value;
    } else if (provider_base_url) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, "https://api.openai.com/v1");
    errdefer allocator.free(openai);

    const chatgpt = if (explicit_chatgpt) |value| blk: {
        explicit_chatgpt = null;
        break :blk value;
    } else if (provider_base_url) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex");

    return .{ .openai = openai, .chatgpt = chatgpt };
}

fn resolveModelProviderId(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL_PROVIDER")) |value| {
        return value;
    }
    return config_view.getScopedString(allocator, active_profile, "model_provider");
}

fn resolveModelProviderRequiresOpenAiAuth(config_view: ConfigView, model_provider: ?[]const u8) bool {
    const provider = model_provider orelse return true;
    if (config_view.getModelProviderBool(provider, "requires_openai_auth")) |requires_openai_auth| {
        return requires_openai_auth;
    }
    if (std.mem.eql(u8, provider, "openai")) return true;
    return false;
}

fn resolveModelProviderWireApi(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !ModelProviderWireApi {
    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    const provider = model_provider orelse return .responses;

    const wire_api = try config_view.getModelProviderString(allocator, provider, "wire_api");
    defer if (wire_api) |value| allocator.free(value);
    const value = wire_api orelse return .responses;
    return ModelProviderWireApi.parse(value);
}

const ModelProviderAuth = struct {
    env_key: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
    command: ?ProviderAuthCommand = null,

    fn deinit(self: *ModelProviderAuth, allocator: std.mem.Allocator) void {
        if (self.env_key) |value| allocator.free(value);
        if (self.bearer_token) |value| allocator.free(value);
        if (self.command) |*value| value.deinit(allocator);
    }
};

const ModelProviderHeaders = struct {
    http_headers: ?StringMap = null,
    env_http_headers: ?StringMap = null,

    fn deinit(self: *ModelProviderHeaders, allocator: std.mem.Allocator) void {
        if (self.http_headers) |*value| value.deinit(allocator);
        if (self.env_http_headers) |*value| value.deinit(allocator);
    }
};

fn resolveModelProviderAuth(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !ModelProviderAuth {
    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    const provider = model_provider orelse return .{};

    const env_key = try config_view.getModelProviderString(allocator, provider, "env_key");
    errdefer if (env_key) |value| allocator.free(value);
    const bearer_token = try config_view.getModelProviderString(allocator, provider, "experimental_bearer_token");
    errdefer if (bearer_token) |value| allocator.free(value);
    var command = try config_view.getModelProviderAuthCommand(allocator, provider);
    errdefer if (command) |*value| value.deinit(allocator);
    if (command != null and (env_key != null or bearer_token != null or (config_view.getModelProviderBool(provider, "requires_openai_auth") orelse false))) {
        return error.ModelProviderAuthConflict;
    }

    return .{
        .env_key = env_key,
        .bearer_token = bearer_token,
        .command = command,
    };
}

fn resolveModelProviderHeaders(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !ModelProviderHeaders {
    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    const provider = model_provider orelse return .{};

    var http_headers = try config_view.getModelProviderStringMap(allocator, provider, "http_headers");
    errdefer if (http_headers) |*value| value.deinit(allocator);
    var env_http_headers = try config_view.getModelProviderStringMap(allocator, provider, "env_http_headers");
    errdefer if (env_http_headers) |*value| value.deinit(allocator);

    return .{
        .http_headers = http_headers,
        .env_http_headers = env_http_headers,
    };
}

fn resolveModelProviderQueryParams(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?StringMap {
    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    const provider = model_provider orelse return null;

    return config_view.getModelProviderStringMap(allocator, provider, "query_params");
}

fn resolveOssProvider(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    return config_view.getScopedString(allocator, active_profile, "oss_provider");
}

fn resolveApprovalPolicy(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !ApprovalPolicy {
    if (try env.getOwned(allocator, "CODEX_ZIG_APPROVAL_POLICY")) |value| {
        defer allocator.free(value);
        return ApprovalPolicy.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "approval_policy")) |value| {
        defer allocator.free(value);
        return ApprovalPolicy.parse(value);
    }

    return .on_request;
}

fn resolveSandboxMode(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !SandboxMode {
    if (try env.getOwned(allocator, "CODEX_ZIG_SANDBOX_MODE")) |value| {
        defer allocator.free(value);
        return SandboxMode.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "sandbox_mode")) |value| {
        defer allocator.free(value);
        return SandboxMode.parse(value);
    }

    return .workspace_write;
}

fn resolveWebSearchMode(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?WebSearchMode {
    if (try env.getOwned(allocator, "CODEX_ZIG_WEB_SEARCH")) |value| {
        defer allocator.free(value);
        return try WebSearchMode.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "web_search")) |value| {
        defer allocator.free(value);
        return try WebSearchMode.parse(value);
    }

    return null;
}

fn resolveModelReasoningEffort(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?ReasoningEffort {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL_REASONING_EFFORT")) |value| {
        defer allocator.free(value);
        return try ReasoningEffort.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "model_reasoning_effort")) |value| {
        defer allocator.free(value);
        return try ReasoningEffort.parse(value);
    }

    return null;
}

fn resolveModelReasoningSummary(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?ReasoningSummary {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL_REASONING_SUMMARY")) |value| {
        defer allocator.free(value);
        return try ReasoningSummary.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "model_reasoning_summary")) |value| {
        defer allocator.free(value);
        return try ReasoningSummary.parse(value);
    }

    return null;
}

fn resolveServiceTier(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_SERVICE_TIER")) |value| {
        defer allocator.free(value);
        return try normalizeServiceTier(allocator, value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "service_tier")) |value| {
        defer allocator.free(value);
        return try normalizeServiceTier(allocator, value);
    }

    return null;
}

fn resolveSyntaxTheme(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_SYNTAX_THEME")) |value| {
        return value;
    }

    if (try config_view.getSectionString(allocator, "tui", "theme")) |value| {
        return value;
    }

    return config_view.getScopedString(allocator, active_profile, "syntax_theme");
}

fn resolvePersonality(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?Personality {
    if (try env.getOwned(allocator, "CODEX_ZIG_PERSONALITY")) |value| {
        defer allocator.free(value);
        return try Personality.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "personality")) |value| {
        defer allocator.free(value);
        return try Personality.parse(value);
    }

    return .pragmatic;
}

fn resolveForcedLoginMethod(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?ForcedLoginMethod {
    if (try config_view.getScopedString(allocator, active_profile, "forced_login_method")) |value| {
        defer allocator.free(value);
        return try ForcedLoginMethod.parse(value);
    }

    return null;
}

fn resolveForcedChatGptWorkspaceId(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    if (try config_view.getScopedString(allocator, active_profile, "forced_chatgpt_workspace_id")) |value| {
        defer allocator.free(value);
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return null;
        return @as(?[]const u8, try allocator.dupe(u8, trimmed));
    }

    return null;
}

fn resolveTuiStringArray(allocator: std.mem.Allocator, config_view: ConfigView, key: []const u8) !?StringList {
    return config_view.getSectionStringArray(allocator, "tui", key);
}

fn resolveTuiAlternateScreen(allocator: std.mem.Allocator, config_view: ConfigView) !AltScreenMode {
    const value = try config_view.getSectionString(allocator, "tui", "alternate_screen") orelse return .auto;
    defer allocator.free(value);
    return AltScreenMode.parse(value);
}

fn feedbackEnabledFromConfigBytes(bytes: []const u8) bool {
    return (ConfigView{ .bytes = bytes }).getSectionBool("feedback", "enabled") orelse true;
}

pub fn normalizeServiceTier(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "fast") or std.ascii.eqlIgnoreCase(trimmed, "priority")) {
        return allocator.dupe(u8, "priority");
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "flex")) {
        return allocator.dupe(u8, "flex");
    }
    return allocator.dupe(u8, trimmed);
}

pub fn configTomlPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
}

fn readConfigToml(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try configTomlPath(allocator, codex_home);
    defer allocator.free(path);

    return readConfigTomlFile(allocator, path);
}

pub fn readConfigTomlFile(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn topLevelStringValue(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) !?[]const u8 {
    return (ConfigView{ .bytes = bytes }).getTopLevelString(allocator, key);
}

pub fn topLevelStringArrayValue(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) !?StringList {
    return (ConfigView{ .bytes = bytes }).getTopLevelStringArray(allocator, key);
}

pub fn namedSectionStringValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    section_prefix: []const u8,
    section_name: []const u8,
    key: []const u8,
) !?[]const u8 {
    return (ConfigView{ .bytes = bytes }).getNamedSectionString(allocator, section_prefix, section_name, key);
}

pub fn sectionStringValue(allocator: std.mem.Allocator, bytes: []const u8, section_name: []const u8, key: []const u8) !?[]const u8 {
    return (ConfigView{ .bytes = bytes }).getSectionString(allocator, section_name, key);
}

pub fn sectionStringArrayValue(allocator: std.mem.Allocator, bytes: []const u8, section_name: []const u8, key: []const u8) !?StringList {
    return (ConfigView{ .bytes = bytes }).getSectionStringArray(allocator, section_name, key);
}

pub fn sectionBoolValue(bytes: []const u8, section_name: []const u8, key: []const u8) ?bool {
    return (ConfigView{ .bytes = bytes }).getSectionBool(section_name, key);
}

pub fn persistTuiTheme(allocator: std.mem.Allocator, codex_home: []const u8, name: []const u8) !void {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    const updated = try updateTomlStringValue(allocator, bytes orelse "", .{ .section = "tui" }, "theme", name);
    defer allocator.free(updated);
    try writeConfigToml(allocator, codex_home, updated);
}

pub fn persistPersonality(allocator: std.mem.Allocator, codex_home: []const u8, active_profile: ?[]const u8, personality: Personality) !void {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    const section = if (active_profile) |profile| TomlEditSection{ .profile = profile } else TomlEditSection.top_level;
    const updated = try updateTomlStringValue(allocator, bytes orelse "", section, "personality", personality.label());
    defer allocator.free(updated);
    try writeConfigToml(allocator, codex_home, updated);
}

pub fn persistTuiStatusLine(allocator: std.mem.Allocator, codex_home: []const u8, ids: []const []const u8) !void {
    try persistTuiStringArray(allocator, codex_home, "status_line", ids);
}

pub fn persistTuiTerminalTitle(allocator: std.mem.Allocator, codex_home: []const u8, ids: []const []const u8) !void {
    try persistTuiStringArray(allocator, codex_home, "terminal_title", ids);
}

fn persistTuiStringArray(allocator: std.mem.Allocator, codex_home: []const u8, key: []const u8, values: []const []const u8) !void {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    const updated = try updateTomlStringArrayValue(allocator, bytes orelse "", .{ .section = "tui" }, key, values);
    defer allocator.free(updated);
    try writeConfigToml(allocator, codex_home, updated);
}

fn writeConfigToml(allocator: std.mem.Allocator, codex_home: []const u8, bytes: []const u8) !void {
    const path = try configTomlPath(allocator, codex_home);
    defer allocator.free(path);
    try writeConfigTomlFile(path, bytes);
}

pub fn writeConfigTomlFile(path: []const u8, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

const TomlEditSection = union(enum) {
    top_level,
    section: []const u8,
    profile: []const u8,
};

fn updateTomlStringValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    section: TomlEditSection,
    key: []const u8,
    value: []const u8,
) ![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);
    try appendTomlStringLiteral(allocator, &rendered, value);
    return updateTomlRawValue(allocator, bytes, section, key, rendered.items);
}

fn updateTomlStringArrayValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    section: TomlEditSection,
    key: []const u8,
    values: []const []const u8,
) ![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);
    try appendTomlStringArrayLiteral(allocator, &rendered, values);
    return updateTomlRawValue(allocator, bytes, section, key, rendered.items);
}

pub fn updateTomlRawValueForKeyPath(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    key_path: []const u8,
    raw_value: []const u8,
) ![]const u8 {
    const target = try parseTomlKeyPath(key_path);
    return updateTomlRawValue(allocator, bytes, target.section, target.key, raw_value);
}

pub fn removeTomlValueForKeyPath(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    key_path: []const u8,
) ![]const u8 {
    const target = try parseTomlKeyPath(key_path);
    return removeTomlValue(allocator, bytes, target.section, target.key);
}

pub fn removeTomlTableForKeyPath(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    key_path: []const u8,
) ![]const u8 {
    _ = try parseTomlKeyPath(key_path);
    const without_value = try removeTomlValueForKeyPath(allocator, bytes, key_path);
    defer allocator.free(without_value);
    return removeTomlSectionsForKeyPath(allocator, without_value, key_path);
}

pub fn tomlHasSectionForKeyPath(bytes: []const u8, key_path: []const u8) !bool {
    _ = try parseTomlKeyPath(key_path);
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (tomlSectionMatchesKeyPath(trimmed, key_path)) return true;
    }
    return false;
}

const ParsedTomlKeyPath = struct {
    section: TomlEditSection,
    key: []const u8,
};

fn parseTomlKeyPath(key_path: []const u8) !ParsedTomlKeyPath {
    if (key_path.len == 0) return error.InvalidConfigKeyPath;
    if (std.mem.indexOf(u8, key_path, "..") != null) return error.InvalidConfigKeyPath;
    if (key_path[0] == '.' or key_path[key_path.len - 1] == '.') return error.InvalidConfigKeyPath;

    if (std.mem.lastIndexOfScalar(u8, key_path, '.')) |index| {
        return .{
            .section = .{ .section = key_path[0..index] },
            .key = key_path[index + 1 ..],
        };
    }
    return .{ .section = .top_level, .key = key_path };
}

fn updateTomlRawValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    section: TomlEditSection,
    key: []const u8,
    raw_value: []const u8,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var in_target = section == .top_level;
    var saw_target = section == .top_level;
    var wrote_key = false;

    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_target and !wrote_key) {
                try appendTomlRawLine(allocator, &output, key, raw_value);
                wrote_key = true;
            }
            in_target = tomlSectionMatches(trimmed, section);
            saw_target = saw_target or in_target;
        }

        if (in_target and tomlKeyMatches(trimmed, key)) {
            try appendTomlRawLine(allocator, &output, key, raw_value);
            wrote_key = true;
            continue;
        }

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    if (!saw_target) {
        try ensureTomlTrailingGap(allocator, &output);
        try appendTomlSectionHeader(allocator, &output, section);
        saw_target = true;
    }
    if (saw_target and !wrote_key) {
        try appendTomlRawLine(allocator, &output, key, raw_value);
    }

    return output.toOwnedSlice(allocator);
}

fn removeTomlValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    section: TomlEditSection,
    key: []const u8,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var in_target = section == .top_level;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_target = tomlSectionMatches(trimmed, section);
        }
        if (in_target and tomlKeyMatches(trimmed, key)) continue;

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn removeTomlSectionsForKeyPath(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    key_path: []const u8,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var skip_section = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line_raw = bytes[start..end];
        start = if (end < bytes.len) end + 1 else bytes.len;

        const line_without_comment = if (std.mem.indexOfScalar(u8, line_raw, '#')) |index| line_raw[0..index] else line_raw;
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            skip_section = tomlSectionMatchesKeyPath(trimmed, key_path);
        }
        if (skip_section) continue;

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn tomlSectionMatches(line: []const u8, section: TomlEditSection) bool {
    return switch (section) {
        .top_level => false,
        .section => |name| isExactSection(line, name),
        .profile => |profile| isProfileSection(line, profile),
    };
}

fn isExactSection(line: []const u8, name: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    return std.mem.eql(u8, section, name);
}

fn tomlSectionMatchesKeyPath(line: []const u8, key_path: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    if (line.len >= "[[]]".len and line[1] == '[') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, section, key_path)) return true;
    return section.len > key_path.len and
        std.mem.startsWith(u8, section, key_path) and
        section[key_path.len] == '.';
}

fn tomlKeyMatches(trimmed: []const u8, key: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] == '[') return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
    return std.mem.eql(u8, lhs, key);
}

fn ensureTomlTrailingGap(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }
    if (output.items.len > 0) try output.append(allocator, '\n');
}

fn appendTomlSectionHeader(allocator: std.mem.Allocator, output: *std.ArrayList(u8), section: TomlEditSection) !void {
    switch (section) {
        .top_level => {},
        .section => |name| {
            try output.append(allocator, '[');
            try output.appendSlice(allocator, name);
            try output.appendSlice(allocator, "]\n");
        },
        .profile => |profile| {
            try output.appendSlice(allocator, "[profiles.");
            try appendTomlStringLiteral(allocator, output, profile);
            try output.appendSlice(allocator, "]\n");
        },
    }
}

fn appendTomlRawLine(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, raw_value: []const u8) !void {
    try output.appendSlice(allocator, key);
    try output.appendSlice(allocator, " = ");
    try output.appendSlice(allocator, raw_value);
    try output.append(allocator, '\n');
}

fn appendTomlStringArrayLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), values: []const []const u8) !void {
    try output.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try appendTomlStringLiteral(allocator, output, value);
    }
    try output.append(allocator, ']');
}

fn appendTomlStringLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
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

const ConfigView = struct {
    bytes: []const u8,

    fn getScopedString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: ?[]const u8,
        key: []const u8,
    ) !?[]const u8 {
        if (profile) |name| {
            if (try self.getProfileString(allocator, name, key)) |value| {
                return value;
            }
        }
        return self.getTopLevelString(allocator, key);
    }

    fn getSectionString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        section_name: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        var in_section = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (!in_section) continue;
            if (try stringValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getSectionStringArray(
        self: ConfigView,
        allocator: std.mem.Allocator,
        section_name: []const u8,
        key: []const u8,
    ) !?StringList {
        var in_section = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (!in_section) continue;
            if (try stringArrayValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getSectionBool(
        self: ConfigView,
        section_name: []const u8,
        key: []const u8,
    ) ?bool {
        var in_section = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (!in_section) continue;
            if (boolValueForKey(line, key)) |value| return value;
        }
        return null;
    }

    fn getSectionU64(
        self: ConfigView,
        section_name: []const u8,
        key: []const u8,
    ) !?u64 {
        var in_section = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (!in_section) continue;
            if (try u64ValueForKey(line, key)) |value| return value;
        }
        return null;
    }

    fn getTopLevelString(self: ConfigView, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try stringValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getTopLevelStringArray(self: ConfigView, allocator: std.mem.Allocator, key: []const u8) !?StringList {
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try stringArrayValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getProfileString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        var in_profile = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_profile = isProfileSection(line, profile);
                continue;
            }
            if (!in_profile) continue;
            if (try stringValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getModelProviderString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        provider: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        return self.getNamedSectionString(allocator, "model_providers.", provider, key);
    }

    fn getModelProviderAuthCommand(
        self: ConfigView,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !?ProviderAuthCommand {
        const section_name = try modelProviderAuthSectionName(allocator, provider);
        defer allocator.free(section_name);

        const command_opt = try self.getSectionString(allocator, section_name, "command");
        if (command_opt == null) {
            const inline_auth = try self.getModelProviderInlineTable(allocator, provider, "auth");
            defer if (inline_auth) |value| allocator.free(value);
            if (inline_auth) |value| return try parseProviderAuthInlineTable(allocator, value);
            return null;
        }
        const command = command_opt.?;
        errdefer allocator.free(command);
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) return error.ModelProviderAuthCommandEmpty;

        var args = (try self.getSectionStringArray(allocator, section_name, "args")) orelse StringList{ .items = try allocator.alloc([]const u8, 0) };
        errdefer args.deinit(allocator);
        const cwd = try self.getSectionString(allocator, section_name, "cwd");
        errdefer if (cwd) |value| allocator.free(value);
        const timeout_ms = (try self.getSectionU64(section_name, "timeout_ms")) orelse 5000;
        if (timeout_ms == 0) return error.InvalidModelProviderAuthTimeout;
        const refresh_interval_ms = (try self.getSectionU64(section_name, "refresh_interval_ms")) orelse 300_000;

        return .{
            .command = command,
            .args = args,
            .cwd = cwd,
            .timeout_ms = timeout_ms,
            .refresh_interval_ms = refresh_interval_ms,
        };
    }

    fn getModelProviderStringMap(
        self: ConfigView,
        allocator: std.mem.Allocator,
        provider: []const u8,
        key: []const u8,
    ) !?StringMap {
        const section_name = try std.fmt.allocPrint(allocator, "model_providers.{s}.{s}", .{ provider, key });
        defer allocator.free(section_name);

        if (try self.getSectionStringMap(allocator, section_name)) |value| return value;
        const inline_table = try self.getModelProviderInlineTable(allocator, provider, key);
        defer if (inline_table) |value| allocator.free(value);
        if (inline_table) |value| return try parseStringMapInlineTable(allocator, value);
        return null;
    }

    fn getSectionStringMap(
        self: ConfigView,
        allocator: std.mem.Allocator,
        section_name: []const u8,
    ) !?StringMap {
        var in_section = false;
        var entries = std.ArrayList(StringMapEntry).empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                if (in_section) break;
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (!in_section) continue;
            if (try stringMapEntryForLine(allocator, line)) |entry| {
                try entries.append(allocator, entry);
            }
        }
        if (entries.items.len == 0) {
            entries.deinit(allocator);
            return null;
        }
        return .{ .entries = try entries.toOwnedSlice(allocator) };
    }

    fn getModelProviderInlineTable(
        self: ConfigView,
        allocator: std.mem.Allocator,
        provider: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        var in_provider = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, "model_providers.", provider);
                continue;
            }
            if (!in_provider) continue;
            if (try inlineTableValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getNamedSectionString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        section_prefix: []const u8,
        section_name: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        var in_provider = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, section_prefix, section_name);
                continue;
            }
            if (!in_provider) continue;
            if (try stringValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn getModelProviderBool(
        self: ConfigView,
        provider: []const u8,
        key: []const u8,
    ) ?bool {
        var in_provider = false;
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, "model_providers.", provider);
                continue;
            }
            if (!in_provider) continue;
            if (boolValueForKey(line, key)) |value| return value;
        }
        return null;
    }

    fn resolveCustomSandboxPermissionProfile(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: []const u8,
    ) !SandboxPermissionProfile {
        var state = CustomSandboxPermissionProfileState{};
        errdefer state.deinit(allocator);

        var saw_filesystem = false;
        var saw_network = false;
        var network_enabled: ?bool = null;
        var network_unsupported = false;
        var in_filesystem = false;
        var in_network = false;

        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_filesystem = isPermissionsProfileSection(line, profile, "filesystem");
                in_network = isPermissionsProfileSection(line, profile, "network");
                saw_filesystem = saw_filesystem or in_filesystem;
                saw_network = saw_network or in_network;
                continue;
            }

            if (in_filesystem) {
                try recordSandboxFilesystemLine(allocator, &state, line);
            } else if (in_network) {
                if (boolValueForKey(line, "enabled")) |enabled| {
                    network_enabled = enabled;
                } else if (tomlAssignmentKey(line) != null) {
                    network_unsupported = true;
                }
            }
        }

        if (!saw_filesystem or !saw_network or network_enabled == null or network_unsupported) {
            return error.SandboxPermissionProfileUnsupported;
        }
        return state.toSandboxPermissionProfile(allocator, network_enabled.?);
    }

    fn hasProfile(self: ConfigView, profile: []const u8) bool {
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[' and isProfileOrNestedSection(line, profile)) return true;
        }
        return false;
    }
};

const SandboxFilesystemAccess = enum {
    read,
    write,
    none,
};

const CustomSandboxPermissionProfileState = struct {
    root_read: bool = false,
    project_roots_write: bool = false,
    unsupported: bool = false,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CustomSandboxPermissionProfileState, allocator: std.mem.Allocator) void {
        for (self.additional_writable_roots.items) |root| allocator.free(root);
        self.additional_writable_roots.deinit(allocator);
    }

    fn toSandboxPermissionProfile(
        self: *CustomSandboxPermissionProfileState,
        allocator: std.mem.Allocator,
        network_enabled: bool,
    ) !SandboxPermissionProfile {
        if (self.unsupported or !self.root_read) return error.SandboxPermissionProfileUnsupported;

        const mode: SandboxMode = if (self.project_roots_write or self.additional_writable_roots.items.len > 0)
            .workspace_write
        else
            .read_only;
        return .{
            .mode = mode,
            .additional_writable_roots = .{ .items = try self.additional_writable_roots.toOwnedSlice(allocator) },
            .include_cwd_write_root = self.project_roots_write,
            .network_enabled = network_enabled,
        };
    }
};

fn recordSandboxFilesystemLine(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    line: []const u8,
) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const raw_key = std.mem.trim(u8, line[0..eq], " \t");
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (raw_key.len == 0) return;

    const path = try parseTomlKey(allocator, raw_key);
    defer allocator.free(path);

    if (try parseTomlString(allocator, rhs)) |raw_access| {
        defer allocator.free(raw_access);
        const access = parseSandboxFilesystemAccess(raw_access) orelse {
            state.unsupported = true;
            return;
        };
        try recordSandboxFilesystemAccess(allocator, state, path, null, access);
        return;
    }

    const inline_contents = try parseInlineTableContents(allocator, rhs) orelse {
        state.unsupported = true;
        return;
    };
    defer allocator.free(inline_contents);
    var scoped = (try parseStringMapInlineTable(allocator, inline_contents)) orelse {
        state.unsupported = true;
        return;
    };
    defer scoped.deinit(allocator);
    for (scoped.entries) |entry| {
        const access = parseSandboxFilesystemAccess(entry.value) orelse {
            state.unsupported = true;
            continue;
        };
        try recordSandboxFilesystemAccess(allocator, state, path, entry.key, access);
    }
}

fn recordSandboxFilesystemAccess(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    path: []const u8,
    subpath: ?[]const u8,
    access: SandboxFilesystemAccess,
) !void {
    switch (access) {
        .none => {
            state.unsupported = true;
        },
        .read => {
            if (subpath == null and std.mem.eql(u8, path, ":root")) {
                state.root_read = true;
            }
        },
        .write => {
            if (subpath) |child| {
                try recordScopedSandboxWrite(allocator, state, path, child);
            } else if (std.mem.eql(u8, path, ":root")) {
                state.unsupported = true;
            } else if (std.mem.eql(u8, path, ":project_roots")) {
                state.project_roots_write = true;
            } else if (std.fs.path.isAbsolute(path)) {
                try appendWritableRoot(allocator, state, path);
            } else {
                state.unsupported = true;
            }
        },
    }
}

fn recordScopedSandboxWrite(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    path: []const u8,
    subpath: []const u8,
) !void {
    if (!isSafeRelativeTomlSubpath(subpath)) {
        state.unsupported = true;
        return;
    }
    if (std.mem.eql(u8, path, ":project_roots")) {
        if (std.mem.eql(u8, subpath, ".")) {
            state.project_roots_write = true;
        } else {
            try appendWritableRoot(allocator, state, subpath);
        }
        return;
    }
    if (std.fs.path.isAbsolute(path)) {
        const root = if (std.mem.eql(u8, subpath, "."))
            try allocator.dupe(u8, path)
        else
            try std.fs.path.join(allocator, &.{ path, subpath });
        errdefer allocator.free(root);
        try state.additional_writable_roots.append(allocator, root);
        return;
    }
    state.unsupported = true;
}

fn appendWritableRoot(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    root: []const u8,
) !void {
    const owned = try allocator.dupe(u8, root);
    errdefer allocator.free(owned);
    try state.additional_writable_roots.append(allocator, owned);
}

fn parseSandboxFilesystemAccess(value: []const u8) ?SandboxFilesystemAccess {
    if (std.mem.eql(u8, value, "read")) return .read;
    if (std.mem.eql(u8, value, "write")) return .write;
    if (std.mem.eql(u8, value, "none")) return .none;
    return null;
}

fn parseInlineTableContents(allocator: std.mem.Allocator, rhs: []const u8) !?[]const u8 {
    if (rhs.len < 2 or rhs[0] != '{') return null;
    const end = std.mem.lastIndexOfScalar(u8, rhs, '}') orelse return error.InvalidTomlInlineTable;
    return try allocator.dupe(u8, std.mem.trim(u8, rhs[1..end], " \t\r\n"));
}

fn isSafeRelativeTomlSubpath(subpath: []const u8) bool {
    if (std.mem.eql(u8, subpath, ".")) return true;
    if (subpath.len == 0 or std.fs.path.isAbsolute(subpath)) return false;
    var iter = std.mem.splitScalar(u8, subpath, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn tomlAssignmentKey(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (lhs.len == 0) return null;
    return lhs;
}

fn isPermissionsProfileSection(line: []const u8, profile: []const u8, subsection: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "permissions.";
    if (!std.mem.startsWith(u8, section, prefix)) return false;
    const remainder = section[prefix.len..];

    if (remainder.len >= 2 and remainder[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, remainder, 1, '"') orelse return false;
        if (!std.mem.eql(u8, remainder[1..close], profile)) return false;
        const suffix = remainder[close + 1 ..];
        return suffix.len == subsection.len + 1 and suffix[0] == '.' and std.mem.eql(u8, suffix[1..], subsection);
    }

    return remainder.len == profile.len + subsection.len + 1 and
        std.mem.startsWith(u8, remainder, profile) and
        remainder[profile.len] == '.' and
        std.mem.eql(u8, remainder[profile.len + 1 ..], subsection);
}

fn stringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlString(allocator, rhs);
}

fn stringMapEntryForLine(allocator: std.mem.Allocator, line: []const u8) !?StringMapEntry {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const raw_key = std.mem.trim(u8, line[0..eq], " \t");
    if (raw_key.len == 0) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const value = try parseTomlString(allocator, rhs) orelse return null;
    errdefer allocator.free(value);
    const key = try parseTomlKey(allocator, raw_key);
    return .{ .key = key, .value = value };
}

fn parseTomlKey(allocator: std.mem.Allocator, raw_key: []const u8) ![]const u8 {
    if (raw_key.len >= 2 and raw_key[0] == '"') {
        if (try parseTomlString(allocator, raw_key)) |value| return value;
        return error.InvalidTomlString;
    }
    return allocator.dupe(u8, raw_key);
}

fn inlineTableValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (rhs.len < 2 or rhs[0] != '{') return null;
    const end = std.mem.lastIndexOfScalar(u8, rhs, '}') orelse return error.InvalidTomlInlineTable;
    return try allocator.dupe(u8, std.mem.trim(u8, rhs[1..end], " \t\r\n"));
}

fn stringArrayValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?StringList {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlStringArray(allocator, rhs);
}

fn boolValueForKey(line: []const u8, key: []const u8) ?bool {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, rhs, "true")) return true;
    if (std.mem.eql(u8, rhs, "false")) return false;
    return null;
}

fn u64ValueForKey(line: []const u8, key: []const u8) !?u64 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return std.fmt.parseUnsigned(u64, rhs, 10) catch error.InvalidTomlInteger;
}

fn parseProviderAuthInlineTable(allocator: std.mem.Allocator, contents: []const u8) !?ProviderAuthCommand {
    var command: ?[]const u8 = null;
    errdefer if (command) |value| allocator.free(value);
    var args: ?StringList = null;
    errdefer if (args) |*value| value.deinit(allocator);
    var cwd: ?[]const u8 = null;
    errdefer if (cwd) |value| allocator.free(value);
    var timeout_ms: ?u64 = null;
    var refresh_interval_ms: ?u64 = null;

    var start: usize = 0;
    var index: usize = 0;
    var in_string = false;
    var escaped = false;
    var array_depth: usize = 0;
    while (index <= contents.len) : (index += 1) {
        const at_end = index == contents.len;
        if (!at_end) {
            const byte = contents[index];
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
                continue;
            }
            if (byte == '[') {
                array_depth += 1;
                continue;
            }
            if (byte == ']') {
                if (array_depth == 0) return error.InvalidTomlInlineTable;
                array_depth -= 1;
                continue;
            }
            if (byte != ',' or array_depth != 0) continue;
        }

        const entry = std.mem.trim(u8, contents[start..index], " \t\r\n");
        start = index + 1;
        if (entry.len == 0) continue;
        if (try stringValueForKey(allocator, entry, "command")) |value| {
            if (command) |existing| allocator.free(existing);
            command = value;
            continue;
        }
        if (try stringArrayValueForKey(allocator, entry, "args")) |value| {
            if (args) |*existing| existing.deinit(allocator);
            args = value;
            continue;
        }
        if (try stringValueForKey(allocator, entry, "cwd")) |value| {
            if (cwd) |existing| allocator.free(existing);
            cwd = value;
            continue;
        }
        if (try u64ValueForKey(entry, "timeout_ms")) |value| {
            timeout_ms = value;
            continue;
        }
        if (try u64ValueForKey(entry, "refresh_interval_ms")) |value| {
            refresh_interval_ms = value;
            continue;
        }
    }
    if (in_string or array_depth != 0) return error.InvalidTomlInlineTable;

    const owned_command = command orelse return null;
    command = null;
    errdefer allocator.free(owned_command);
    if (std.mem.trim(u8, owned_command, " \t\r\n").len == 0) return error.ModelProviderAuthCommandEmpty;
    const owned_args = if (args) |value| args: {
        args = null;
        break :args value;
    } else StringList{ .items = try allocator.alloc([]const u8, 0) };
    errdefer {
        var mutable_args = owned_args;
        mutable_args.deinit(allocator);
    }
    const owned_cwd = cwd;
    cwd = null;
    errdefer if (owned_cwd) |value| allocator.free(value);
    const resolved_timeout = timeout_ms orelse 5000;
    if (resolved_timeout == 0) return error.InvalidModelProviderAuthTimeout;
    const resolved_refresh_interval = refresh_interval_ms orelse 300_000;

    return .{
        .command = owned_command,
        .args = owned_args,
        .cwd = owned_cwd,
        .timeout_ms = resolved_timeout,
        .refresh_interval_ms = resolved_refresh_interval,
    };
}

fn parseStringMapInlineTable(allocator: std.mem.Allocator, contents: []const u8) !?StringMap {
    var entries = std.ArrayList(StringMapEntry).empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var start: usize = 0;
    var index: usize = 0;
    var in_string = false;
    var escaped = false;
    while (index <= contents.len) : (index += 1) {
        const at_end = index == contents.len;
        if (!at_end) {
            const byte = contents[index];
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
                continue;
            }
            if (byte != ',') continue;
        }

        const entry_line = std.mem.trim(u8, contents[start..index], " \t\r\n");
        start = index + 1;
        if (entry_line.len == 0) continue;
        if (try stringMapEntryForLine(allocator, entry_line)) |entry| {
            try entries.append(allocator, entry);
        }
    }
    if (in_string) return error.InvalidTomlInlineTable;
    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return null;
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn parseTomlString(allocator: std.mem.Allocator, rhs: []const u8) !?[]const u8 {
    if (rhs.len < 2 or rhs[0] != '"') return null;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 1;
    while (index < rhs.len) : (index += 1) {
        const byte = rhs[index];
        if (byte == '"') {
            const value = try output.toOwnedSlice(allocator);
            return value;
        }
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

pub fn parseTomlStringArray(allocator: std.mem.Allocator, rhs: []const u8) !?StringList {
    if (rhs.len == 0 or rhs[0] != '[') return null;

    var items = std.ArrayList([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var index: usize = 1;
    while (index < rhs.len) {
        while (index < rhs.len and (rhs[index] == ' ' or rhs[index] == '\t' or rhs[index] == '\r' or rhs[index] == '\n' or rhs[index] == ',')) : (index += 1) {}
        if (index >= rhs.len) return error.InvalidTomlStringArray;
        if (rhs[index] == ']') {
            return .{ .items = try items.toOwnedSlice(allocator) };
        }
        if (rhs[index] != '"') return error.InvalidTomlStringArray;

        index += 1;
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        while (index < rhs.len) : (index += 1) {
            const byte = rhs[index];
            if (byte == '"') {
                var value: ?[]const u8 = try output.toOwnedSlice(allocator);
                errdefer if (value) |owned| allocator.free(owned);
                try items.append(allocator, value.?);
                value = null;
                index += 1;
                break;
            }
            if (byte != '\\') {
                try output.append(allocator, byte);
                continue;
            }

            index += 1;
            if (index >= rhs.len) return error.InvalidTomlStringArray;
            const escaped: u8 = switch (rhs[index]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidTomlStringArray,
            };
            try output.append(allocator, escaped);
        } else return error.InvalidTomlStringArray;
    }

    return error.InvalidTomlStringArray;
}

fn isProfileSection(line: []const u8, profile: []const u8) bool {
    return isNamedSection(line, "profiles.", profile);
}

fn isProfileOrNestedSection(line: []const u8, profile: []const u8) bool {
    if (isProfileSection(line, profile)) return true;
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "profiles.";
    if (!std.mem.startsWith(u8, section, prefix)) return false;
    const remainder = section[prefix.len..];
    if (remainder.len >= profile.len + 1 and
        std.mem.startsWith(u8, remainder, profile) and
        remainder[profile.len] == '.')
    {
        return true;
    }
    if (remainder.len >= profile.len + 3 and
        remainder[0] == '"' and
        std.mem.eql(u8, remainder[1 .. 1 + profile.len], profile) and
        remainder[1 + profile.len] == '"' and
        remainder[2 + profile.len] == '.')
    {
        return true;
    }
    return false;
}

fn isNamedSection(line: []const u8, prefix: []const u8, name: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (!std.mem.startsWith(u8, section, prefix)) return false;
    const raw_name = section[prefix.len..];
    if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"') {
        return std.mem.eql(u8, raw_name[1 .. raw_name.len - 1], name);
    }
    return std.mem.eql(u8, raw_name, name);
}

fn modelProviderAuthSectionName(allocator: std.mem.Allocator, provider: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "model_providers.{s}.auth", .{provider});
}

fn readOptionalFileTrimmed(
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, fallback),
        else => return err,
    };
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback);
    return allocator.dupe(u8, trimmed);
}

test "top-level model is read from config" {
    const allocator = std.testing.allocator;
    const view = ConfigView{ .bytes = "model = \"demo-model\" # trailing comment\n[other]\nmodel = \"ignored\"\n" };
    const model = try view.getTopLevelString(allocator, "model");
    defer allocator.free(model.?);
    try std.testing.expectEqualStrings("demo-model", model.?);
}

test "approval and sandbox labels parse config strings" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\approval_policy = "never"
        \\sandbox_mode = "read-only"
        \\
        ,
    };

    try std.testing.expectEqual(ApprovalPolicy.never, try resolveApprovalPolicy(allocator, view, null));
    try std.testing.expectEqual(SandboxMode.read_only, try resolveSandboxMode(allocator, view, null));
    try std.testing.expectEqualStrings("on-request", ApprovalPolicy.on_request.label());
    try std.testing.expectEqualStrings("danger-full-access", SandboxMode.danger_full_access.label());
    try std.testing.expectEqual(WebSearchMode.live, try WebSearchMode.parse("live"));
    try std.testing.expectEqualStrings("cached", WebSearchMode.cached.label());
    try std.testing.expectEqual(ReasoningSummary.detailed, try ReasoningSummary.parse("detailed"));
    try std.testing.expectEqualStrings("concise", ReasoningSummary.concise.label());
    try std.testing.expectEqual(Personality.pragmatic, (try resolvePersonality(allocator, view, null)).?);
}

test "sandbox permission profile resolves supported custom workspace shape" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\":project_roots" = "write"
        \\"/tmp/codex-extra" = "write"
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        ,
    };

    var profile = try view.resolveCustomSandboxPermissionProfile(allocator, "demo");
    defer profile.deinit(allocator);

    try std.testing.expectEqual(SandboxMode.workspace_write, profile.mode);
    try std.testing.expect(profile.include_cwd_write_root);
    try std.testing.expect(profile.network_enabled);
    try std.testing.expectEqual(@as(usize, 1), profile.additional_writable_roots.items.len);
    try std.testing.expectEqualStrings("/tmp/codex-extra", profile.additional_writable_roots.items[0]);
}

test "sandbox permission profile supports disabled network" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\":project_roots" = "write"
        \\
        \\[permissions.demo.network]
        \\enabled = false
        \\
        ,
    };

    var profile = try view.resolveCustomSandboxPermissionProfile(allocator, "demo");
    defer profile.deinit(allocator);

    try std.testing.expectEqual(SandboxMode.workspace_write, profile.mode);
    try std.testing.expect(profile.include_cwd_write_root);
    try std.testing.expect(!profile.network_enabled);
}

test "sandbox permission profile rejects narrow read and restricted network shapes" {
    const allocator = std.testing.allocator;
    const narrow_read = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":minimal" = "read"
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        ,
    };
    try std.testing.expectError(error.SandboxPermissionProfileUnsupported, narrow_read.resolveCustomSandboxPermissionProfile(allocator, "demo"));

    const restricted_network = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\mode = "restricted"
        \\
        ,
    };
    try std.testing.expectError(error.SandboxPermissionProfileUnsupported, restricted_network.resolveCustomSandboxPermissionProfile(allocator, "demo"));
}

test "profile values override top-level config values" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\profile = "work"
        \\model = "base-model"
        \\oss_provider = "ollama"
        \\approval_policy = "on-request"
        \\sandbox_mode = "read-only"
        \\web_search = "cached"
        \\model_reasoning_effort = "low"
        \\service_tier = "flex"
        \\syntax_theme = "github"
        \\personality = "friendly"
        \\forced_login_method = "api"
        \\forced_chatgpt_workspace_id = "base-workspace"
        \\chatgpt_base_url = "https://base.example/codex"
        \\
        \\[profiles.work]
        \\model = "profile-model"
        \\oss_provider = "lmstudio"
        \\approval_policy = "never"
        \\sandbox_mode = "danger-full-access"
        \\web_search = "live"
        \\model_reasoning_effort = "high"
        \\service_tier = "fast"
        \\syntax_theme = "dracula"
        \\personality = "pragmatic"
        \\forced_login_method = "chatgpt"
        \\forced_chatgpt_workspace_id = "profile-workspace"
        \\chatgpt_base_url = "https://profile.example/codex"
        \\
        ,
    };

    try std.testing.expect(view.hasProfile("work"));

    const active_profile = try view.getTopLevelString(allocator, "profile");
    defer allocator.free(active_profile.?);
    try std.testing.expectEqualStrings("work", active_profile.?);

    const model = try view.getScopedString(allocator, active_profile.?, "model");
    defer allocator.free(model.?);
    try std.testing.expectEqualStrings("profile-model", model.?);

    const chatgpt_base_url = try view.getScopedString(allocator, active_profile.?, "chatgpt_base_url");
    defer allocator.free(chatgpt_base_url.?);
    try std.testing.expectEqualStrings("https://profile.example/codex", chatgpt_base_url.?);

    const oss_provider = try resolveOssProvider(allocator, view, active_profile.?);
    defer allocator.free(oss_provider.?);
    try std.testing.expectEqualStrings("lmstudio", oss_provider.?);

    try std.testing.expectEqual(ApprovalPolicy.never, try resolveApprovalPolicy(allocator, view, active_profile.?));
    try std.testing.expectEqual(SandboxMode.danger_full_access, try resolveSandboxMode(allocator, view, active_profile.?));
    try std.testing.expectEqual(WebSearchMode.live, (try resolveWebSearchMode(allocator, view, active_profile.?)).?);
    try std.testing.expectEqual(ReasoningEffort.high, (try resolveModelReasoningEffort(allocator, view, active_profile.?)).?);
    const service_tier = try resolveServiceTier(allocator, view, active_profile.?);
    defer allocator.free(service_tier.?);
    try std.testing.expectEqualStrings("priority", service_tier.?);
    const syntax_theme = try resolveSyntaxTheme(allocator, view, active_profile.?);
    defer allocator.free(syntax_theme.?);
    try std.testing.expectEqualStrings("dracula", syntax_theme.?);
    try std.testing.expectEqual(Personality.pragmatic, (try resolvePersonality(allocator, view, active_profile.?)).?);
    try std.testing.expectEqual(ForcedLoginMethod.chatgpt, (try resolveForcedLoginMethod(allocator, view, active_profile.?)).?);
    const forced_workspace = try resolveForcedChatGptWorkspaceId(allocator, view, active_profile.?);
    defer allocator.free(forced_workspace.?);
    try std.testing.expectEqualStrings("profile-workspace", forced_workspace.?);
    try std.testing.expectEqual(@as(?bool, true), WebSearchMode.live.externalWebAccess());
    try std.testing.expectEqual(@as(?bool, false), WebSearchMode.cached.externalWebAccess());
    try std.testing.expect(WebSearchMode.disabled.externalWebAccess() == null);
}

test "tui theme table overrides legacy syntax theme key" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\syntax_theme = "github"
        \\
        \\[tui]
        \\theme = "dracula"
        \\status_line = ["model-with-reasoning", "current-dir"]
        \\terminal_title = []
        \\alternate_screen = "never"
        \\
        ,
    };

    const syntax_theme = try resolveSyntaxTheme(allocator, view, null);
    defer allocator.free(syntax_theme.?);
    try std.testing.expectEqualStrings("dracula", syntax_theme.?);

    var status_line = (try resolveTuiStringArray(allocator, view, "status_line")).?;
    defer status_line.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), status_line.items.len);
    try std.testing.expectEqualStrings("model-with-reasoning", status_line.items[0]);
    try std.testing.expectEqualStrings("current-dir", status_line.items[1]);

    var terminal_title = (try resolveTuiStringArray(allocator, view, "terminal_title")).?;
    defer terminal_title.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), terminal_title.items.len);
    try std.testing.expectEqual(AltScreenMode.never, try resolveTuiAlternateScreen(allocator, view));
    try std.testing.expectEqualStrings("always", (try AltScreenMode.parse("ALWAYS")).label());
}

test "toml string update writes top-level section and profile values" {
    const allocator = std.testing.allocator;

    const with_theme = try updateTomlStringValue(
        allocator,
        "[mcp_servers.docs]\ncommand = \"docs-server\"\n",
        .{ .section = "tui" },
        "theme",
        "custom-demo",
    );
    defer allocator.free(with_theme);
    try std.testing.expect(std.mem.indexOf(u8, with_theme, "[mcp_servers.docs]\ncommand = \"docs-server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_theme, "[tui]\ntheme = \"custom-demo\"") != null);

    const replaced_theme = try updateTomlStringValue(
        allocator,
        "[tui]\ntheme = \"old\"\nstatus_line_use_colors = \"true\"\n",
        .{ .section = "tui" },
        "theme",
        "dracula",
    );
    defer allocator.free(replaced_theme);
    try std.testing.expect(std.mem.indexOf(u8, replaced_theme, "theme = \"old\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, replaced_theme, "[tui]\ntheme = \"dracula\"\nstatus_line_use_colors = \"true\"") != null);

    const with_top_level = try updateTomlStringValue(
        allocator,
        "[tui]\ntheme = \"custom-demo\"\n",
        .top_level,
        "personality",
        "friendly",
    );
    defer allocator.free(with_top_level);
    try std.testing.expect(std.mem.startsWith(u8, with_top_level, "personality = \"friendly\"\n[tui]"));

    const with_profile = try updateTomlStringValue(
        allocator,
        "model = \"base\"\n",
        .{ .profile = "team a" },
        "personality",
        "pragmatic",
    );
    defer allocator.free(with_profile);
    try std.testing.expect(std.mem.indexOf(u8, with_profile, "[profiles.\"team a\"]\npersonality = \"pragmatic\"") != null);

    const with_array = try updateTomlStringArrayValue(
        allocator,
        "[tui]\ntheme = \"custom-demo\"\n",
        .{ .section = "tui" },
        "status_line",
        &.{ "model-with-reasoning", "current-dir" },
    );
    defer allocator.free(with_array);
    try std.testing.expect(std.mem.indexOf(u8, with_array, "status_line = [\"model-with-reasoning\", \"current-dir\"]") != null);
}

test "toml table removal clears target and nested sections" {
    const allocator = std.testing.allocator;
    const updated = try removeTomlTableForKeyPath(allocator,
        \\model = "gpt-old"
        \\
        \\[mcp_servers.linear]
        \\name = "linear"
        \\
        \\[mcp_servers.linear.env_http_headers]
        \\existing = "keep"
        \\
        \\[mcp_servers.other]
        \\name = "other"
        \\
    , "mcp_servers.linear");
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "[mcp_servers.linear]") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[mcp_servers.linear.env_http_headers]") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "[mcp_servers.other]") != null);
    try std.testing.expect(try tomlHasSectionForKeyPath(updated, "mcp_servers.other"));
    try std.testing.expect(!try tomlHasSectionForKeyPath(updated, "mcp_servers.linear"));
}

test "quoted profile section names are supported" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[profiles."team a"]
        \\model = "quoted-profile-model"
        \\
        ,
    };

    try std.testing.expect(view.hasProfile("team a"));
    const model = try view.getScopedString(allocator, "team a", "model");
    defer allocator.free(model.?);
    try std.testing.expectEqualStrings("quoted-profile-model", model.?);
}

test "nested profile sections count as existing profiles" {
    const view = ConfigView{
        .bytes =
        \\[profiles."team a".features]
        \\goals = true
        \\[profiles.work.features]
        \\shell_tool = false
        \\
        ,
    };

    try std.testing.expect(view.hasProfile("team a"));
    try std.testing.expect(view.hasProfile("work"));
    try std.testing.expect(!view.hasProfile("other"));
}

test "model provider base url resolves from active provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "openai-custom"
        \\
        \\[model_providers.openai-custom]
        \\base_url = "https://proxy.example/v1"
        \\wire_api = "responses"
        \\
        ,
    };

    const base_urls = try resolveBaseUrls(allocator, view, null);
    defer allocator.free(base_urls.openai);
    defer allocator.free(base_urls.chatgpt);

    try std.testing.expectEqualStrings("https://proxy.example/v1", base_urls.openai);
    try std.testing.expectEqualStrings("https://proxy.example/v1", base_urls.chatgpt);
}

test "model provider wire api resolves from active provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "openai-custom"
        \\
        \\[model_providers.openai-custom]
        \\base_url = "https://proxy.example/v1"
        \\wire_api = "responses"
        \\
        ,
    };

    try std.testing.expectEqual(.responses, try resolveModelProviderWireApi(allocator, view, null));
}

test "model provider wire api rejects removed chat value" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "old-chat"
        \\
        \\[model_providers.old-chat]
        \\base_url = "https://proxy.example/v1"
        \\wire_api = "chat"
        \\
        ,
    };

    try std.testing.expectError(error.RemovedModelProviderChatWireApi, resolveModelProviderWireApi(allocator, view, null));
}

test "model provider wire api rejects unknown value" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "unknown-wire"
        \\
        \\[model_providers.unknown-wire]
        \\base_url = "https://proxy.example/v1"
        \\wire_api = "completions"
        \\
        ,
    };

    try std.testing.expectError(error.InvalidModelProviderWireApi, resolveModelProviderWireApi(allocator, view, null));
}

test "model provider auth requirement follows provider config" {
    const view = ConfigView{
        .bytes =
        \\model_provider = "openai-custom"
        \\
        \\[model_providers.openai-custom]
        \\base_url = "https://proxy.example/v1"
        \\wire_api = "responses"
        \\
        \\[model_providers.openai-required]
        \\base_url = "https://api.example/v1"
        \\requires_openai_auth = true
        \\
        ,
    };

    try std.testing.expect(resolveModelProviderRequiresOpenAiAuth(view, null));
    try std.testing.expect(resolveModelProviderRequiresOpenAiAuth(view, "openai"));
    try std.testing.expect(!resolveModelProviderRequiresOpenAiAuth(view, "amazon-bedrock"));
    try std.testing.expect(!resolveModelProviderRequiresOpenAiAuth(view, "openai-custom"));
    try std.testing.expect(resolveModelProviderRequiresOpenAiAuth(view, "openai-required"));
}

test "model provider auth fields resolve from active provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "env-provider"
        \\
        \\[model_providers.env-provider]
        \\base_url = "https://proxy.example/v1"
        \\env_key = "CORP_API_KEY"
        \\experimental_bearer_token = "configured-token"
        \\
        ,
    };

    var provider_auth = try resolveModelProviderAuth(allocator, view, null);
    defer provider_auth.deinit(allocator);

    try std.testing.expectEqualStrings("CORP_API_KEY", provider_auth.env_key.?);
    try std.testing.expectEqualStrings("configured-token", provider_auth.bearer_token.?);
}

test "model provider command auth resolves from active provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "command-provider"
        \\
        \\[model_providers.command-provider]
        \\base_url = "https://proxy.example/v1"
        \\
        \\[model_providers.command-provider.auth]
        \\command = "./print-token"
        \\args = ["--scope", "codex"]
        \\cwd = "/tmp/provider-auth"
        \\timeout_ms = 1234
        \\refresh_interval_ms = 0
        \\
        ,
    };

    var provider_auth = try resolveModelProviderAuth(allocator, view, null);
    defer provider_auth.deinit(allocator);

    const command = provider_auth.command.?;
    try std.testing.expectEqualStrings("./print-token", command.command);
    try std.testing.expectEqual(@as(usize, 2), command.args.items.len);
    try std.testing.expectEqualStrings("--scope", command.args.items[0]);
    try std.testing.expectEqualStrings("codex", command.args.items[1]);
    try std.testing.expectEqualStrings("/tmp/provider-auth", command.cwd.?);
    try std.testing.expectEqual(@as(u64, 1234), command.timeout_ms);
    try std.testing.expectEqual(@as(u64, 0), command.refresh_interval_ms);
}

test "model provider command auth resolves from inline provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "command-provider"
        \\
        \\[model_providers.command-provider]
        \\base_url = "https://proxy.example/v1"
        \\auth = { command = "./print-token", args = ["--scope", "codex"], cwd = "/tmp/provider-auth", timeout_ms = 1234, refresh_interval_ms = 4321 }
        \\
        ,
    };

    var provider_auth = try resolveModelProviderAuth(allocator, view, null);
    defer provider_auth.deinit(allocator);

    const command = provider_auth.command.?;
    try std.testing.expectEqualStrings("./print-token", command.command);
    try std.testing.expectEqual(@as(usize, 2), command.args.items.len);
    try std.testing.expectEqualStrings("--scope", command.args.items[0]);
    try std.testing.expectEqualStrings("codex", command.args.items[1]);
    try std.testing.expectEqualStrings("/tmp/provider-auth", command.cwd.?);
    try std.testing.expectEqual(@as(u64, 1234), command.timeout_ms);
    try std.testing.expectEqual(@as(u64, 4321), command.refresh_interval_ms);
}

test "model provider command auth defaults refresh interval" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "command-provider"
        \\
        \\[model_providers.command-provider.auth]
        \\command = "./print-token"
        \\
        ,
    };

    var provider_auth = try resolveModelProviderAuth(allocator, view, null);
    defer provider_auth.deinit(allocator);

    const command = provider_auth.command.?;
    try std.testing.expectEqual(@as(u64, 5000), command.timeout_ms);
    try std.testing.expectEqual(@as(u64, 300_000), command.refresh_interval_ms);
}

test "model provider command auth rejects empty command" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "command-provider"
        \\
        \\[model_providers.command-provider.auth]
        \\command = ""
        \\
        ,
    };

    try std.testing.expectError(error.ModelProviderAuthCommandEmpty, resolveModelProviderAuth(allocator, view, null));
}

test "model provider command auth rejects auth conflicts" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "command-provider"
        \\
        \\[model_providers.command-provider]
        \\env_key = "CORP_API_KEY"
        \\requires_openai_auth = false
        \\
        \\[model_providers.command-provider.auth]
        \\command = "./print-token"
        \\
        ,
    };

    try std.testing.expectError(error.ModelProviderAuthConflict, resolveModelProviderAuth(allocator, view, null));
}

test "model provider headers resolve from provider tables and inline maps" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "header-provider"
        \\
        \\[model_providers.header-provider]
        \\base_url = "https://proxy.example/v1"
        \\env_http_headers = { "X-Env-Token" = "CORP_HEADER_TOKEN" }
        \\
        \\[model_providers.header-provider.http_headers]
        \\"X-Corp-Static" = "static-value"
        \\
        ,
    };

    var headers = try resolveModelProviderHeaders(allocator, view, null);
    defer headers.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), headers.http_headers.?.entries.len);
    try std.testing.expectEqualStrings("X-Corp-Static", headers.http_headers.?.entries[0].key);
    try std.testing.expectEqualStrings("static-value", headers.http_headers.?.entries[0].value);
    try std.testing.expectEqual(@as(usize, 1), headers.env_http_headers.?.entries.len);
    try std.testing.expectEqualStrings("X-Env-Token", headers.env_http_headers.?.entries[0].key);
    try std.testing.expectEqualStrings("CORP_HEADER_TOKEN", headers.env_http_headers.?.entries[0].value);
}

test "model provider query params resolve from provider table" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "query-provider"
        \\
        \\[model_providers.query-provider]
        \\base_url = "https://proxy.example/v1"
        \\
        \\[model_providers.query-provider.query_params]
        \\api-version = "2025-04-01-preview"
        \\"deployment-name" = "codex-test"
        \\
        ,
    };

    var query_params = try resolveModelProviderQueryParams(allocator, view, null);
    defer query_params.?.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), query_params.?.entries.len);
    try std.testing.expectEqualStrings("api-version", query_params.?.entries[0].key);
    try std.testing.expectEqualStrings("2025-04-01-preview", query_params.?.entries[0].value);
    try std.testing.expectEqualStrings("deployment-name", query_params.?.entries[1].key);
    try std.testing.expectEqualStrings("codex-test", query_params.?.entries[1].value);
}

test "feedback enabled defaults true and honors feedback table" {
    try std.testing.expect(feedbackEnabledFromConfigBytes(""));
    try std.testing.expect(feedbackEnabledFromConfigBytes(
        \\[feedback]
        \\enabled = true
        \\
    ));
    try std.testing.expect(!feedbackEnabledFromConfigBytes(
        \\[feedback]
        \\enabled = false
        \\
    ));
}

test "profile model provider overrides top-level provider" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model_provider = "base"
        \\
        \\[profiles.work]
        \\model_provider = "profile-provider"
        \\
        \\[model_providers.base]
        \\base_url = "https://base.example/v1"
        \\
        \\[model_providers.profile-provider]
        \\base_url = "https://profile.example/v1"
        \\
        ,
    };

    const base_urls = try resolveBaseUrls(allocator, view, "work");
    defer allocator.free(base_urls.openai);
    defer allocator.free(base_urls.chatgpt);

    try std.testing.expectEqualStrings("https://profile.example/v1", base_urls.openai);
    try std.testing.expectEqualStrings("https://profile.example/v1", base_urls.chatgpt);
}

test "raw cli config overrides map supported fields" {
    var runtime = RuntimeOverrides{};
    var profile: ?[]const u8 = null;

    try applyRawConfigOverride(&runtime, &profile, "profile=\"work\"");
    try applyRawConfigOverride(&runtime, &profile, "model=gpt-test");
    try applyRawConfigOverride(&runtime, &profile, "openai_base_url='http://127.0.0.1:1'");
    try applyRawConfigOverride(&runtime, &profile, "chatgpt_base_url=http://127.0.0.1:2");
    try applyRawConfigOverride(&runtime, &profile, "oss_provider=ollama");
    try applyRawConfigOverride(&runtime, &profile, "approval_policy=never");
    try applyRawConfigOverride(&runtime, &profile, "sandbox_mode=read-only");
    try applyRawConfigOverride(&runtime, &profile, "web_search=live");
    try applyRawConfigOverride(&runtime, &profile, "service_tier=fast");
    try applyRawConfigOverride(&runtime, &profile, "syntax_theme=dracula");
    try applyRawConfigOverride(&runtime, &profile, "personality=friendly");
    try applyRawConfigOverride(&runtime, &profile, "model_reasoning_summary=detailed");
    try applyRawConfigOverride(&runtime, &profile, "tui.alternate_screen=never");
    try applyRawConfigOverride(&runtime, &profile, "unsupported.key=true");

    try std.testing.expectEqualStrings("work", profile.?);
    try std.testing.expectEqualStrings("gpt-test", runtime.model.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1", runtime.openai_base_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:2", runtime.chatgpt_base_url.?);
    try std.testing.expectEqualStrings("ollama", runtime.oss_provider.?);
    try std.testing.expectEqual(ApprovalPolicy.never, runtime.approval_policy.?);
    try std.testing.expectEqual(SandboxMode.read_only, runtime.sandbox_mode.?);
    try std.testing.expectEqual(WebSearchMode.live, runtime.web_search_mode.?);
    try std.testing.expectEqualStrings("fast", runtime.service_tier.?);
    try std.testing.expectEqualStrings("dracula", runtime.syntax_theme.?);
    try std.testing.expectEqual(Personality.friendly, runtime.personality.?);
    try std.testing.expectEqual(ReasoningSummary.detailed, runtime.model_reasoning_summary.?);
    try std.testing.expectEqual(AltScreenMode.never, runtime.tui_alternate_screen.?);
}

test "raw cli config override rejects missing assignment" {
    var runtime = RuntimeOverrides{};
    var profile: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidConfigOverride, applyRawConfigOverride(&runtime, &profile, "model"));
}

test "service tier normalization maps fast aliases" {
    const allocator = std.testing.allocator;
    const fast = try normalizeServiceTier(allocator, "fast");
    defer allocator.free(fast);
    const priority = try normalizeServiceTier(allocator, "priority");
    defer allocator.free(priority);
    const flex = try normalizeServiceTier(allocator, "FLEX");
    defer allocator.free(flex);
    const custom = try normalizeServiceTier(allocator, "batch");
    defer allocator.free(custom);

    try std.testing.expectEqualStrings("priority", fast);
    try std.testing.expectEqualStrings("priority", priority);
    try std.testing.expectEqualStrings("flex", flex);
    try std.testing.expectEqualStrings("batch", custom);
}

test "oss mode applies local provider defaults" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .codex_home = try allocator.dupe(u8, "/tmp/codex-zig-test"),
        .active_profile = null,
        .model = try allocator.dupe(u8, "configured-model"),
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .chatgpt_base_url = try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex"),
        .oss_provider = try allocator.dupe(u8, "ollama"),
        .installation_id = try allocator.dupe(u8, "install"),
        .approval_policy = .never,
        .sandbox_mode = .read_only,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };
    defer cfg.deinit(allocator);

    try applyOssMode(&cfg, allocator, null, false);
    try std.testing.expectEqualStrings("gpt-oss:20b", cfg.model);
    try std.testing.expect(std.mem.endsWith(u8, cfg.openai_base_url, "/v1"));

    try applyOssMode(&cfg, allocator, "lmstudio", true);
    try std.testing.expectEqualStrings("gpt-oss:20b", cfg.model);
}

test "oss provider validation matches supported providers" {
    try std.testing.expectEqual(OssProvider.lmstudio, try OssProvider.parse("lmstudio"));
    try std.testing.expectEqual(OssProvider.ollama, try OssProvider.parse("ollama"));
    try std.testing.expectEqualStrings("openai/gpt-oss-20b", OssProvider.lmstudio.defaultModel());
    try std.testing.expectError(error.RemovedOllamaChatProvider, OssProvider.parse("ollama-chat"));
    try std.testing.expectError(error.InvalidOssProvider, OssProvider.parse("other"));
}

test "toml string escapes are decoded" {
    const allocator = std.testing.allocator;
    const value = try parseTomlString(allocator, "\"hello\\n\\\"zig\\\"\"");
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings("hello\n\"zig\"", value.?);
}
