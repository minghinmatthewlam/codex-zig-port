const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const feature_registry = @import("feature_registry.zig");
const model_catalog = @import("model_catalog.zig");

pub const MIN_BACKGROUND_TERMINAL_EMPTY_POLL_TIMEOUT_MS: u64 = 5_000;
pub const DEFAULT_BACKGROUND_TERMINAL_MAX_TIMEOUT_MS: u64 = 300_000;
pub const INSTALLATION_ID_FILENAME = "installation_id";

const INSTALLATION_ID_MAX_BYTES = 4096;
const INSTALLATION_ID_PERMISSIONS: std.Io.File.Permissions = @enumFromInt(0o644);

pub const Config = struct {
    codex_home: []const u8,
    ignore_user_config: bool = false,
    active_profile: ?[]const u8,
    model: []const u8,
    review_model: ?[]const u8 = null,
    model_context_window: ?i64 = null,
    model_auto_compact_token_limit: ?i64 = null,
    model_provider_id: ?[]const u8 = null,
    model_provider_requires_openai_auth: bool = true,
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
    approvals_reviewer: ApprovalsReviewer = .user,
    sandbox_mode: SandboxMode,
    web_search_mode: ?WebSearchMode,
    model_reasoning_effort: ?ReasoningEffort,
    model_reasoning_summary: ?ReasoningSummary = null,
    model_verbosity: ?Verbosity = null,
    service_tier: ?[]const u8,
    syntax_theme: ?[]const u8,
    personality: ?Personality,
    realtime_audio_microphone: ?[]const u8 = null,
    realtime_audio_speaker: ?[]const u8 = null,
    base_instructions: ?[]const u8 = null,
    developer_instructions: ?[]const u8 = null,
    compact_prompt: ?[]const u8 = null,
    forced_login_method: ?ForcedLoginMethod = null,
    forced_chatgpt_workspace_id: ?[]const u8 = null,
    cli_auth_credentials_store_mode: AuthCredentialsStoreMode = .file,
    tui_status_line: ?StringList,
    tui_terminal_title: ?StringList,
    tui_alternate_screen: AltScreenMode,
    background_terminal_max_timeout: u64 = DEFAULT_BACKGROUND_TERMINAL_MAX_TIMEOUT_MS,
    bypass_hook_trust: bool = false,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        if (self.active_profile) |value| allocator.free(value);
        allocator.free(self.model);
        if (self.review_model) |value| allocator.free(value);
        if (self.model_provider_id) |value| allocator.free(value);
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
        if (self.realtime_audio_microphone) |value| allocator.free(value);
        if (self.realtime_audio_speaker) |value| allocator.free(value);
        if (self.base_instructions) |value| allocator.free(value);
        if (self.developer_instructions) |value| allocator.free(value);
        if (self.compact_prompt) |value| allocator.free(value);
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
    profile_v2: ?[]const u8 = null,
    ignore_user_config: bool = false,
    strict_config: bool = false,
};

pub const RuntimeOverrides = struct {
    model: ?[]const u8 = null,
    review_model: ?[]const u8 = null,
    model_context_window: ?i64 = null,
    model_auto_compact_token_limit: ?i64 = null,
    model_provider_id: ?[]const u8 = null,
    openai_base_url: ?[]const u8 = null,
    chatgpt_base_url: ?[]const u8 = null,
    oss_provider: ?[]const u8 = null,
    approval_policy: ?ApprovalPolicy = null,
    approvals_reviewer: ?ApprovalsReviewer = null,
    sandbox_mode: ?SandboxMode = null,
    web_search_mode: ?WebSearchMode = null,
    service_tier: ?[]const u8 = null,
    model_reasoning_summary: ?ReasoningSummary = null,
    model_verbosity: ?Verbosity = null,
    syntax_theme: ?[]const u8 = null,
    personality: ?Personality = null,
    base_instructions: ?[]const u8 = null,
    developer_instructions: ?[]const u8 = null,
    compact_prompt: ?[]const u8 = null,
    tui_alternate_screen: ?AltScreenMode = null,
    bypass_hook_trust: ?bool = null,
};

pub fn mergeRuntimeOverrides(base: RuntimeOverrides, overrides: RuntimeOverrides) RuntimeOverrides {
    var merged = base;
    if (overrides.model) |value| merged.model = value;
    if (overrides.review_model) |value| merged.review_model = value;
    if (overrides.model_context_window) |value| merged.model_context_window = value;
    if (overrides.model_auto_compact_token_limit) |value| merged.model_auto_compact_token_limit = value;
    if (overrides.model_provider_id) |value| merged.model_provider_id = value;
    if (overrides.openai_base_url) |value| merged.openai_base_url = value;
    if (overrides.chatgpt_base_url) |value| merged.chatgpt_base_url = value;
    if (overrides.oss_provider) |value| merged.oss_provider = value;
    if (overrides.approval_policy) |value| merged.approval_policy = value;
    if (overrides.approvals_reviewer) |value| merged.approvals_reviewer = value;
    if (overrides.sandbox_mode) |value| merged.sandbox_mode = value;
    if (overrides.web_search_mode) |value| merged.web_search_mode = value;
    if (overrides.service_tier) |value| merged.service_tier = value;
    if (overrides.model_reasoning_summary) |value| merged.model_reasoning_summary = value;
    if (overrides.model_verbosity) |value| merged.model_verbosity = value;
    if (overrides.syntax_theme) |value| merged.syntax_theme = value;
    if (overrides.personality) |value| merged.personality = value;
    if (overrides.base_instructions) |value| merged.base_instructions = value;
    if (overrides.developer_instructions) |value| merged.developer_instructions = value;
    if (overrides.compact_prompt) |value| merged.compact_prompt = value;
    if (overrides.tui_alternate_screen) |value| merged.tui_alternate_screen = value;
    if (overrides.bypass_hook_trust) |value| merged.bypass_hook_trust = value;
    return merged;
}

pub const SandboxPermissionProfile = struct {
    mode: SandboxMode,
    additional_writable_roots: StringList,
    read_denied_roots: StringList,
    read_denied_globs: StringList,
    include_cwd_write_root: bool = true,
    network_enabled: bool = true,
    exclude_tmpdir_env_var: bool = true,
    exclude_slash_tmp: bool = true,

    pub fn deinit(self: *SandboxPermissionProfile, allocator: std.mem.Allocator) void {
        self.additional_writable_roots.deinit(allocator);
        self.read_denied_roots.deinit(allocator);
        self.read_denied_globs.deinit(allocator);
    }
};

pub const SandboxPermissionProfileOptions = struct {
    allow_read_denied_globs: bool = false,
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

pub const AuthCredentialsStoreMode = enum {
    file,
    keyring,
    auto,
    ephemeral,

    pub fn parse(value: []const u8) !AuthCredentialsStoreMode {
        if (std.mem.eql(u8, value, "file")) return .file;
        if (std.mem.eql(u8, value, "keyring")) return .keyring;
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "ephemeral")) return .ephemeral;
        return error.InvalidAuthCredentialsStoreMode;
    }

    pub fn label(self: AuthCredentialsStoreMode) []const u8 {
        return switch (self) {
            .file => "file",
            .keyring => "keyring",
            .auto => "auto",
            .ephemeral => "ephemeral",
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
    if (overrides.review_model) |review_model| {
        const next_review_model = try allocator.dupe(u8, review_model);
        if (cfg.review_model) |existing| allocator.free(existing);
        cfg.review_model = next_review_model;
    }
    if (overrides.model_context_window) |value| {
        cfg.model_context_window = value;
    }
    if (overrides.model_auto_compact_token_limit) |value| {
        cfg.model_auto_compact_token_limit = value;
    }
    if (overrides.model_provider_id) |model_provider_id| {
        try applyModelProviderOverride(cfg, allocator, model_provider_id);
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
    if (overrides.approvals_reviewer) |approvals_reviewer| {
        cfg.approvals_reviewer = approvals_reviewer;
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
    if (overrides.model_verbosity) |verbosity| {
        cfg.model_verbosity = verbosity;
    }
    if (overrides.base_instructions) |base_instructions| {
        const next_base_instructions = try allocator.dupe(u8, base_instructions);
        if (cfg.base_instructions) |existing| allocator.free(existing);
        cfg.base_instructions = next_base_instructions;
    }
    if (overrides.developer_instructions) |developer_instructions| {
        const next_developer_instructions = try allocator.dupe(u8, developer_instructions);
        if (cfg.developer_instructions) |existing| allocator.free(existing);
        cfg.developer_instructions = next_developer_instructions;
    }
    if (overrides.compact_prompt) |compact_prompt| {
        const next_compact_prompt = try allocator.dupe(u8, compact_prompt);
        if (cfg.compact_prompt) |existing| allocator.free(existing);
        cfg.compact_prompt = next_compact_prompt;
    }
    if (overrides.tui_alternate_screen) |mode| {
        cfg.tui_alternate_screen = mode;
    }
    if (overrides.bypass_hook_trust) |value| {
        cfg.bypass_hook_trust = value;
    }
}

fn applyModelProviderOverride(
    cfg: *Config,
    allocator: std.mem.Allocator,
    model_provider_id: []const u8,
) !void {
    const config_bytes = if (cfg.ignore_user_config)
        null
    else
        try readConfigToml(allocator, cfg.codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    const config_view = ConfigView{ .bytes = config_bytes orelse "" };
    const active_profile = cfg.active_profile;
    const provider_id: ?[]const u8 = model_provider_id;

    const next_model_provider_id = try allocator.dupe(u8, model_provider_id);
    errdefer allocator.free(next_model_provider_id);
    const next_requires_openai_auth = resolveModelProviderRequiresOpenAiAuth(config_view, provider_id);
    const next_base_urls = try resolveBaseUrlsForProvider(allocator, config_view, active_profile, provider_id);
    errdefer allocator.free(next_base_urls.openai);
    errdefer allocator.free(next_base_urls.chatgpt);
    const next_wire_api = try resolveModelProviderWireApiForProvider(allocator, config_view, provider_id);
    var next_auth = try resolveModelProviderAuthForProvider(allocator, config_view, provider_id);
    errdefer next_auth.deinit(allocator);
    var next_query_params = try resolveModelProviderQueryParamsForProvider(allocator, config_view, provider_id);
    errdefer if (next_query_params) |*value| value.deinit(allocator);
    var next_headers = try resolveModelProviderHeadersForProvider(allocator, config_view, provider_id);
    errdefer next_headers.deinit(allocator);

    if (cfg.model_provider_id) |existing| allocator.free(existing);
    cfg.model_provider_id = next_model_provider_id;
    cfg.model_provider_requires_openai_auth = next_requires_openai_auth;

    allocator.free(cfg.openai_base_url);
    cfg.openai_base_url = next_base_urls.openai;
    allocator.free(cfg.chatgpt_base_url);
    cfg.chatgpt_base_url = next_base_urls.chatgpt;
    cfg.model_provider_wire_api = next_wire_api;

    if (cfg.model_provider_env_key) |existing| allocator.free(existing);
    cfg.model_provider_env_key = next_auth.env_key;
    next_auth.env_key = null;
    if (cfg.model_provider_bearer_token) |existing| allocator.free(existing);
    cfg.model_provider_bearer_token = next_auth.bearer_token;
    next_auth.bearer_token = null;
    if (cfg.model_provider_auth_command) |*existing| existing.deinit(allocator);
    cfg.model_provider_auth_command = next_auth.command;
    next_auth.command = null;

    if (cfg.model_provider_query_params) |*existing| existing.deinit(allocator);
    cfg.model_provider_query_params = next_query_params;
    next_query_params = null;

    if (cfg.model_provider_http_headers) |*existing| existing.deinit(allocator);
    cfg.model_provider_http_headers = next_headers.http_headers;
    next_headers.http_headers = null;
    if (cfg.model_provider_env_http_headers) |*existing| existing.deinit(allocator);
    cfg.model_provider_env_http_headers = next_headers.env_http_headers;
    next_headers.env_http_headers = null;
}

pub fn applyRawConfigOverride(
    runtime_overrides: *RuntimeOverrides,
    profile_override: *?[]const u8,
    raw: []const u8,
) !void {
    const eq = tomlAssignmentEqualsIndex(raw) orelse return error.InvalidConfigOverride;
    const key = try rawConfigOverrideKey(raw);
    const value = trimConfigOverrideValue(raw[eq + 1 ..]);
    if (key.len == 0) return error.InvalidConfigOverride;

    if (std.mem.eql(u8, key, "profile")) {
        profile_override.* = value;
    } else if (std.mem.eql(u8, key, "model")) {
        runtime_overrides.model = value;
    } else if (std.mem.eql(u8, key, "review_model")) {
        runtime_overrides.review_model = value;
    } else if (std.mem.eql(u8, key, "model_context_window")) {
        runtime_overrides.model_context_window = std.fmt.parseInt(i64, value, 10) catch return error.InvalidConfigOverride;
    } else if (std.mem.eql(u8, key, "model_auto_compact_token_limit")) {
        runtime_overrides.model_auto_compact_token_limit = std.fmt.parseInt(i64, value, 10) catch return error.InvalidConfigOverride;
    } else if (std.mem.eql(u8, key, "model_provider")) {
        runtime_overrides.model_provider_id = value;
    } else if (std.mem.eql(u8, key, "openai_base_url")) {
        runtime_overrides.openai_base_url = value;
    } else if (std.mem.eql(u8, key, "chatgpt_base_url")) {
        runtime_overrides.chatgpt_base_url = value;
    } else if (std.mem.eql(u8, key, "oss_provider")) {
        runtime_overrides.oss_provider = value;
    } else if (std.mem.eql(u8, key, "approval_policy")) {
        runtime_overrides.approval_policy = try ApprovalPolicy.parse(value);
    } else if (std.mem.eql(u8, key, "approvals_reviewer")) {
        runtime_overrides.approvals_reviewer = try ApprovalsReviewer.parse(value);
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
    } else if (std.mem.eql(u8, key, "instructions") or std.mem.eql(u8, key, "base_instructions")) {
        runtime_overrides.base_instructions = value;
    } else if (std.mem.eql(u8, key, "developer_instructions")) {
        runtime_overrides.developer_instructions = value;
    } else if (std.mem.eql(u8, key, "compact_prompt")) {
        runtime_overrides.compact_prompt = value;
    } else if (std.mem.eql(u8, key, "model_reasoning_summary")) {
        runtime_overrides.model_reasoning_summary = try ReasoningSummary.parse(value);
    } else if (std.mem.eql(u8, key, "model_verbosity")) {
        runtime_overrides.model_verbosity = try Verbosity.parse(value);
    } else if (std.mem.eql(u8, key, "tui.alternate_screen") or std.mem.eql(u8, key, "tui_alternate_screen")) {
        runtime_overrides.tui_alternate_screen = try AltScreenMode.parse(value);
    }
}

pub fn rawConfigOverrideUnknownField(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const key = try rawConfigOverrideKey(raw);
    if (!strictConfigOverridePathAllowed(key)) return try allocator.dupe(u8, key);
    if (try strictConfigInlineTableUnknownField(allocator, key, raw)) |field| return field;
    return null;
}

pub fn rememberStrictConfigUnknownOverride(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    raw: []const u8,
) !void {
    if (try rawConfigOverrideUnknownField(allocator, raw)) |field| {
        if (destination.* == null) {
            destination.* = field;
        } else {
            allocator.free(field);
        }
    }
}

pub fn failStrictConfigUnknownCliOverride(field: []const u8) error{StrictConfigUnknownField} {
    std.debug.print("error loading config: unknown configuration field `{s}` in -c/--config override\n", .{field});
    return error.StrictConfigUnknownField;
}

fn rawConfigOverrideKey(raw: []const u8) ![]const u8 {
    const eq = tomlAssignmentEqualsIndex(raw) orelse return error.InvalidConfigOverride;
    const key = std.mem.trim(u8, raw[0..eq], " \t");
    if (key.len == 0) return error.InvalidConfigOverride;
    return key;
}

pub fn loadSandboxPermissionProfile(allocator: std.mem.Allocator, profile: []const u8) !SandboxPermissionProfile {
    return loadSandboxPermissionProfileWithOptions(allocator, profile, .{});
}

pub fn loadSandboxPermissionProfileWithOptions(
    allocator: std.mem.Allocator,
    profile: []const u8,
    options: SandboxPermissionProfileOptions,
) !SandboxPermissionProfile {
    if (try resolveBuiltInSandboxPermissionProfile(allocator, profile)) |builtin_profile| return builtin_profile;

    const codex_home = try resolveCodexHome(allocator);
    defer allocator.free(codex_home);
    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);
    const bytes = config_bytes orelse return error.SandboxPermissionProfileUnsupported;

    return (ConfigView{ .bytes = bytes }).resolveCustomSandboxPermissionProfileWithOptions(allocator, profile, options);
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

    const additional_writable_roots = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(additional_writable_roots);
    const read_denied_roots = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(read_denied_roots);
    const read_denied_globs = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(read_denied_globs);

    return .{
        .mode = mode,
        .additional_writable_roots = .{ .items = additional_writable_roots },
        .read_denied_roots = .{ .items = read_denied_roots },
        .read_denied_globs = .{ .items = read_denied_globs },
        .network_enabled = mode == .danger_full_access,
        .exclude_tmpdir_env_var = mode != .workspace_write,
        .exclude_slash_tmp = mode != .workspace_write,
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

pub const ApprovalsReviewer = enum {
    user,
    auto_review,

    pub fn label(self: ApprovalsReviewer) []const u8 {
        return switch (self) {
            .user => "user",
            .auto_review => "guardian_subagent",
        };
    }

    pub fn parse(value: []const u8) !ApprovalsReviewer {
        if (std.mem.eql(u8, value, "user")) return .user;
        if (std.mem.eql(u8, value, "auto_review") or std.mem.eql(u8, value, "guardian_subagent")) return .auto_review;
        return error.InvalidApprovalsReviewer;
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

pub const Verbosity = enum {
    low,
    medium,
    high,

    pub fn label(self: Verbosity) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }

    pub fn parse(value: []const u8) !Verbosity {
        if (std.mem.eql(u8, value, "low")) return .low;
        if (std.mem.eql(u8, value, "medium")) return .medium;
        if (std.mem.eql(u8, value, "high")) return .high;
        return error.InvalidVerbosity;
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
    errdefer allocator.free(next_base_url);
    const next_model = if (!explicit_model) try allocator.dupe(u8, provider.defaultModel()) else null;

    clearModelProviderRequestMetadata(allocator, cfg);
    allocator.free(cfg.openai_base_url);
    cfg.openai_base_url = next_base_url;
    if (next_model) |model| {
        allocator.free(cfg.model);
        cfg.model = model;
    }
}

fn clearModelProviderRequestMetadata(allocator: std.mem.Allocator, cfg: *Config) void {
    if (cfg.model_provider_id) |value| allocator.free(value);
    cfg.model_provider_id = null;
    cfg.model_provider_requires_openai_auth = false;
    cfg.model_provider_wire_api = .responses;

    if (cfg.model_provider_env_key) |value| allocator.free(value);
    cfg.model_provider_env_key = null;

    if (cfg.model_provider_bearer_token) |value| allocator.free(value);
    cfg.model_provider_bearer_token = null;

    if (cfg.model_provider_auth_command) |*value| value.deinit(allocator);
    cfg.model_provider_auth_command = null;

    if (cfg.model_provider_query_params) |*value| value.deinit(allocator);
    cfg.model_provider_query_params = null;

    if (cfg.model_provider_http_headers) |*value| value.deinit(allocator);
    cfg.model_provider_http_headers = null;

    if (cfg.model_provider_env_http_headers) |*value| value.deinit(allocator);
    cfg.model_provider_env_http_headers = null;
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

    const base_config_bytes = if (options.ignore_user_config)
        null
    else
        try readConfigToml(allocator, codex_home);
    defer if (base_config_bytes) |bytes| allocator.free(bytes);

    const profile_v2_config_bytes = if (options.ignore_user_config or options.profile_v2 == null)
        null
    else
        try readProfileV2ConfigToml(allocator, codex_home, options.profile_v2.?);
    defer if (profile_v2_config_bytes) |bytes| allocator.free(bytes);

    const base_config_view = ConfigView{ .bytes = base_config_bytes orelse "" };
    const config_view = if (profile_v2_config_bytes) |bytes|
        ConfigView{ .bytes = bytes, .fallback = &base_config_view }
    else
        base_config_view;

    const active_profile = try resolveActiveProfile(allocator, config_view, options.profile);
    errdefer if (active_profile) |profile| allocator.free(profile);
    if (active_profile) |profile| {
        if (!options.ignore_user_config and !config_view.hasProfile(profile)) return error.ConfigProfileNotFound;
    }

    const model = try resolveModel(allocator, config_view, active_profile);
    errdefer allocator.free(model);
    const review_model = try resolveReviewModel(allocator, config_view);
    errdefer if (review_model) |value| allocator.free(value);
    const model_context_window = try resolveModelContextWindow(config_view);
    const model_auto_compact_token_limit = try resolveModelAutoCompactTokenLimit(config_view);
    const model_provider_id = try resolveModelProviderId(allocator, config_view, active_profile);
    errdefer if (model_provider_id) |value| allocator.free(value);
    const model_provider_requires_openai_auth = resolveModelProviderRequiresOpenAiAuth(config_view, model_provider_id);

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

    const installation_id = try resolveInstallationId(allocator, codex_home);
    errdefer allocator.free(installation_id);

    const approval_policy = try resolveApprovalPolicy(allocator, config_view, active_profile);
    const approvals_reviewer = try resolveApprovalsReviewer(allocator, config_view, active_profile);
    const sandbox_mode = try resolveSandboxMode(allocator, config_view, active_profile);
    const web_search_mode = try resolveWebSearchMode(allocator, config_view, active_profile);
    const model_reasoning_effort = try resolveModelReasoningEffort(allocator, config_view, active_profile);
    const model_reasoning_summary = try resolveModelReasoningSummary(allocator, config_view, active_profile);
    const model_verbosity = try resolveModelVerbosity(allocator, config_view, active_profile);
    const service_tier = try resolveServiceTier(allocator, config_view, active_profile);
    errdefer if (service_tier) |value| allocator.free(value);
    const syntax_theme = try resolveSyntaxTheme(allocator, config_view, active_profile);
    errdefer if (syntax_theme) |value| allocator.free(value);
    const personality = try resolvePersonality(allocator, config_view, active_profile);
    const realtime_audio_microphone = try resolveRealtimeAudioDevice(allocator, config_view, "microphone");
    errdefer if (realtime_audio_microphone) |value| allocator.free(value);
    const realtime_audio_speaker = try resolveRealtimeAudioDevice(allocator, config_view, "speaker");
    errdefer if (realtime_audio_speaker) |value| allocator.free(value);
    const base_instructions = try resolveBaseInstructions(allocator, config_view, active_profile);
    errdefer if (base_instructions) |value| allocator.free(value);
    const developer_instructions = try resolveDeveloperInstructions(allocator, config_view, active_profile);
    errdefer if (developer_instructions) |value| allocator.free(value);
    const compact_prompt = try resolveCompactPrompt(allocator, config_view, active_profile);
    errdefer if (compact_prompt) |value| allocator.free(value);
    const forced_login_method = try resolveForcedLoginMethod(allocator, config_view, active_profile);
    const forced_chatgpt_workspace_id = try resolveForcedChatGptWorkspaceId(allocator, config_view, active_profile);
    errdefer if (forced_chatgpt_workspace_id) |value| allocator.free(value);
    const cli_auth_credentials_store_mode = try resolveCliAuthCredentialsStoreMode(allocator, config_view);
    var tui_status_line = try resolveTuiStringArray(allocator, config_view, "status_line");
    errdefer if (tui_status_line) |*value| value.deinit(allocator);
    var tui_terminal_title = try resolveTuiStringArray(allocator, config_view, "terminal_title");
    errdefer if (tui_terminal_title) |*value| value.deinit(allocator);
    const tui_alternate_screen = try resolveTuiAlternateScreen(allocator, config_view);
    const background_terminal_max_timeout = try resolveBackgroundTerminalMaxTimeout(config_view);
    if (options.strict_config) {
        if (try config_view.strictConfigUnknownField(allocator)) |field| {
            defer allocator.free(field);
            std.debug.print("error loading config: unknown configuration field `{s}`\n", .{field});
            return error.StrictConfigUnknownField;
        }
    }

    return .{
        .codex_home = codex_home,
        .ignore_user_config = options.ignore_user_config,
        .active_profile = active_profile,
        .model = model,
        .review_model = review_model,
        .model_context_window = model_context_window,
        .model_auto_compact_token_limit = model_auto_compact_token_limit,
        .model_provider_id = model_provider_id,
        .model_provider_requires_openai_auth = model_provider_requires_openai_auth,
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
        .approvals_reviewer = approvals_reviewer,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .model_reasoning_effort = model_reasoning_effort,
        .model_reasoning_summary = model_reasoning_summary,
        .model_verbosity = model_verbosity,
        .service_tier = service_tier,
        .syntax_theme = syntax_theme,
        .personality = personality,
        .realtime_audio_microphone = realtime_audio_microphone,
        .realtime_audio_speaker = realtime_audio_speaker,
        .base_instructions = base_instructions,
        .developer_instructions = developer_instructions,
        .compact_prompt = compact_prompt,
        .forced_login_method = forced_login_method,
        .forced_chatgpt_workspace_id = forced_chatgpt_workspace_id,
        .cli_auth_credentials_store_mode = cli_auth_credentials_store_mode,
        .tui_status_line = tui_status_line,
        .tui_terminal_title = tui_terminal_title,
        .tui_alternate_screen = tui_alternate_screen,
        .background_terminal_max_timeout = background_terminal_max_timeout,
        .bypass_hook_trust = false,
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

pub fn resolveInstallationId(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, codex_home);

    const path = try std.fs.path.join(allocator, &.{ codex_home, INSTALLATION_ID_FILENAME });
    defer allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(
        io,
        path,
        .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = false,
            .permissions = INSTALLATION_ID_PERMISSIONS,
        },
    );
    defer file.close(io);
    try file.setPermissions(io, INSTALLATION_ID_PERMISSIONS);

    const file_len = try file.length(io);
    const read_len: usize = @intCast(@min(file_len, INSTALLATION_ID_MAX_BYTES));
    const bytes = try allocator.alloc(u8, read_len);
    defer allocator.free(bytes);
    const bytes_read = try file.readPositionalAll(io, bytes, 0);
    const trimmed = std.mem.trim(u8, bytes[0..bytes_read], " \t\r\n");
    if (trimmed.len != 0) {
        if (canonicalUuidString(allocator, trimmed)) |existing| return existing else |err| switch (err) {
            error.InvalidUuidString => {},
            else => return err,
        }
    }

    const generated = try generateUuidString(allocator);
    errdefer allocator.free(generated);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, generated, 0);
    try file.sync(io);
    return generated;
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

fn resolveReviewModel(allocator: std.mem.Allocator, config_view: ConfigView) !?[]const u8 {
    return config_view.getTopLevelString(allocator, "review_model");
}

fn resolveBaseInstructions(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    if (active_profile) |profile| {
        if (try config_view.getProfileString(allocator, profile, "instructions")) |value| {
            return value;
        }
        if (try config_view.getProfileString(allocator, profile, "base_instructions")) |value| {
            return value;
        }
    }
    if (try config_view.getTopLevelString(allocator, "instructions")) |value| {
        return value;
    }
    return config_view.getTopLevelString(allocator, "base_instructions");
}

fn resolveDeveloperInstructions(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    return config_view.getScopedString(allocator, active_profile, "developer_instructions");
}

fn resolveCompactPrompt(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?[]const u8 {
    return config_view.getScopedString(allocator, active_profile, "compact_prompt");
}

fn resolveModelContextWindow(config_view: ConfigView) !?i64 {
    return config_view.getTopLevelI64("model_context_window");
}

fn resolveModelAutoCompactTokenLimit(config_view: ConfigView) !?i64 {
    return config_view.getTopLevelI64("model_auto_compact_token_limit");
}

fn resolveBaseUrls(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !BaseUrls {
    const model_provider = try resolveModelProviderId(allocator, config_view, active_profile);
    defer if (model_provider) |value| allocator.free(value);
    return resolveBaseUrlsForProvider(allocator, config_view, active_profile, model_provider);
}

fn resolveBaseUrlsForProvider(
    allocator: std.mem.Allocator,
    config_view: ConfigView,
    active_profile: ?[]const u8,
    model_provider: ?[]const u8,
) !BaseUrls {
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
    return resolveModelProviderWireApiForProvider(allocator, config_view, model_provider);
}

fn resolveModelProviderWireApiForProvider(allocator: std.mem.Allocator, config_view: ConfigView, model_provider: ?[]const u8) !ModelProviderWireApi {
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
    return resolveModelProviderAuthForProvider(allocator, config_view, model_provider);
}

fn resolveModelProviderAuthForProvider(allocator: std.mem.Allocator, config_view: ConfigView, model_provider: ?[]const u8) !ModelProviderAuth {
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
    return resolveModelProviderHeadersForProvider(allocator, config_view, model_provider);
}

fn resolveModelProviderHeadersForProvider(allocator: std.mem.Allocator, config_view: ConfigView, model_provider: ?[]const u8) !ModelProviderHeaders {
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
    return resolveModelProviderQueryParamsForProvider(allocator, config_view, model_provider);
}

fn resolveModelProviderQueryParamsForProvider(allocator: std.mem.Allocator, config_view: ConfigView, model_provider: ?[]const u8) !?StringMap {
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

fn resolveApprovalsReviewer(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !ApprovalsReviewer {
    if (try env.getOwned(allocator, "CODEX_ZIG_APPROVALS_REVIEWER")) |value| {
        defer allocator.free(value);
        return ApprovalsReviewer.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "approvals_reviewer")) |value| {
        defer allocator.free(value);
        return ApprovalsReviewer.parse(value);
    }

    return .user;
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

fn resolveModelVerbosity(allocator: std.mem.Allocator, config_view: ConfigView, active_profile: ?[]const u8) !?Verbosity {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL_VERBOSITY")) |value| {
        defer allocator.free(value);
        return try Verbosity.parse(value);
    }

    if (try config_view.getScopedString(allocator, active_profile, "model_verbosity")) |value| {
        defer allocator.free(value);
        return try Verbosity.parse(value);
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

fn resolveRealtimeAudioDevice(allocator: std.mem.Allocator, config_view: ConfigView, key: []const u8) !?[]const u8 {
    return config_view.getSectionString(allocator, "audio", key);
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

fn resolveCliAuthCredentialsStoreMode(allocator: std.mem.Allocator, config_view: ConfigView) !AuthCredentialsStoreMode {
    const value = try config_view.getTopLevelString(allocator, "cli_auth_credentials_store");
    defer if (value) |owned| allocator.free(owned);
    return AuthCredentialsStoreMode.parse(value orelse "file");
}

fn resolveTuiStringArray(allocator: std.mem.Allocator, config_view: ConfigView, key: []const u8) !?StringList {
    return config_view.getSectionStringArray(allocator, "tui", key);
}

fn resolveTuiAlternateScreen(allocator: std.mem.Allocator, config_view: ConfigView) !AltScreenMode {
    const value = try config_view.getSectionString(allocator, "tui", "alternate_screen") orelse return .auto;
    defer allocator.free(value);
    return AltScreenMode.parse(value);
}

fn resolveBackgroundTerminalMaxTimeout(config_view: ConfigView) !u64 {
    const timeout = (try config_view.getTopLevelU64("background_terminal_max_timeout")) orelse DEFAULT_BACKGROUND_TERMINAL_MAX_TIMEOUT_MS;
    return @max(timeout, MIN_BACKGROUND_TERMINAL_EMPTY_POLL_TIMEOUT_MS);
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

fn readProfileV2ConfigToml(allocator: std.mem.Allocator, codex_home: []const u8, profile_v2: []const u8) !?[]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.config.toml", .{profile_v2});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ codex_home, file_name });
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

pub fn topLevelI64Value(bytes: []const u8, key: []const u8) !?i64 {
    return (ConfigView{ .bytes = bytes }).getTopLevelI64(key);
}

pub fn scopedStringValue(allocator: std.mem.Allocator, bytes: []const u8, profile: ?[]const u8, key: []const u8) !?[]const u8 {
    return (ConfigView{ .bytes = bytes }).getScopedString(allocator, profile, key);
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

pub fn loadTuiPet(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    return sectionStringValue(allocator, bytes orelse "", "tui", "pet");
}

pub fn persistTuiPet(allocator: std.mem.Allocator, codex_home: []const u8, name: []const u8) !void {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    const updated = try updateTomlStringValue(allocator, bytes orelse "", .{ .section = "tui" }, "pet", name);
    defer allocator.free(updated);
    try writeConfigToml(allocator, codex_home, updated);
}

pub fn persistRealtimeAudioDevice(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    key: []const u8,
    name: ?[]const u8,
) !void {
    const bytes = try readConfigToml(allocator, codex_home);
    defer if (bytes) |value| allocator.free(value);

    const updated = if (name) |value|
        try updateTomlStringValue(allocator, bytes orelse "", .{ .section = "audio" }, key, value)
    else blk: {
        const key_path = try std.fmt.allocPrint(allocator, "audio.{s}", .{key});
        defer allocator.free(key_path);
        break :blk try removeTomlValueForKeyPath(allocator, bytes orelse "", key_path);
    };
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
        if (!try configDirExists(io, parent)) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn configDirExists(io: std.Io, path: []const u8) !bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };
    defer dir.close(io);
    return true;
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
    const eq = tomlAssignmentEqualsIndex(trimmed) orelse return false;
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

const TomlMultilineScanState = struct {
    in_multiline_basic_string: bool = false,
    in_multiline_literal_string: bool = false,
    container_depth: usize = 0,
    in_container_basic_string: bool = false,
    in_container_literal_string: bool = false,
    container_escaped: bool = false,

    fn skipBodyLine(self: *TomlMultilineScanState, line: []const u8) bool {
        if (self.in_multiline_basic_string) {
            if (std.mem.indexOf(u8, line, "\"\"\"") != null) {
                self.in_multiline_basic_string = false;
            }
            return true;
        }
        if (self.in_multiline_literal_string) {
            if (std.mem.indexOf(u8, line, "'''") != null) {
                self.in_multiline_literal_string = false;
            }
            return true;
        }
        if (self.container_depth > 0) {
            self.observeContainerLine(line);
            return true;
        }
        return false;
    }

    fn observeLine(self: *TomlMultilineScanState, line: []const u8) void {
        const eq = tomlAssignmentEqualsIndex(line) orelse return;
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.startsWith(u8, rhs, "\"\"\"")) {
            if (std.mem.indexOf(u8, rhs[3..], "\"\"\"") == null) {
                self.in_multiline_basic_string = true;
            }
            return;
        }
        if (std.mem.startsWith(u8, rhs, "'''")) {
            if (std.mem.indexOf(u8, rhs[3..], "'''") == null) {
                self.in_multiline_literal_string = true;
            }
            return;
        }
        self.observeContainerLine(rhs);
    }

    fn observeContainerLine(self: *TomlMultilineScanState, line: []const u8) void {
        for (line) |byte| {
            if (self.in_container_basic_string) {
                if (self.container_escaped) {
                    self.container_escaped = false;
                } else if (byte == '\\') {
                    self.container_escaped = true;
                } else if (byte == '"') {
                    self.in_container_basic_string = false;
                }
                continue;
            }
            if (self.in_container_literal_string) {
                if (byte == '\'') self.in_container_literal_string = false;
                continue;
            }
            switch (byte) {
                '#' => break,
                '"' => self.in_container_basic_string = true,
                '\'' => self.in_container_literal_string = true,
                '[', '{' => self.container_depth += 1,
                ']', '}' => {
                    if (self.container_depth > 0) self.container_depth -= 1;
                },
                else => {},
            }
        }
    }
};

const ConfigView = struct {
    bytes: []const u8,
    fallback: ?*const ConfigView = null,

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
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (in_section) {
                if (try stringValueForKey(allocator, line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getSectionString(allocator, section_name, key);
        return null;
    }

    fn getSectionStringArray(
        self: ConfigView,
        allocator: std.mem.Allocator,
        section_name: []const u8,
        key: []const u8,
    ) !?StringList {
        var in_section = false;
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (in_section) {
                if (try stringArrayValueForKey(allocator, line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getSectionStringArray(allocator, section_name, key);
        return null;
    }

    fn getSectionBool(
        self: ConfigView,
        section_name: []const u8,
        key: []const u8,
    ) ?bool {
        var in_section = false;
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (in_section) {
                if (boolValueForKey(line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getSectionBool(section_name, key);
        return null;
    }

    fn getSectionU64(
        self: ConfigView,
        section_name: []const u8,
        key: []const u8,
    ) !?u64 {
        var in_section = false;
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (in_section) {
                if (try u64ValueForKey(line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getSectionU64(section_name, key);
        return null;
    }

    fn getTopLevelString(self: ConfigView, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        var line_start: usize = 0;
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            defer line_start += line_raw.len + 1;
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try stringValueForKeyAt(allocator, self.bytes, line_start, line_raw, key)) |value| return value;
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getTopLevelString(allocator, key);
        return null;
    }

    fn getTopLevelStringArray(self: ConfigView, allocator: std.mem.Allocator, key: []const u8) !?StringList {
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try stringArrayValueForKey(allocator, line, key)) |value| return value;
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getTopLevelStringArray(allocator, key);
        return null;
    }

    fn getTopLevelU64(self: ConfigView, key: []const u8) !?u64 {
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try u64ValueForKey(line, key)) |value| return value;
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getTopLevelU64(key);
        return null;
    }

    fn getTopLevelI64(self: ConfigView, key: []const u8) !?i64 {
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') break;
            if (try i64ValueForKey(line, key)) |value| return value;
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getTopLevelI64(key);
        return null;
    }

    fn getProfileString(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: []const u8,
        key: []const u8,
    ) !?[]const u8 {
        var in_profile = false;
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        var line_start: usize = 0;
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            defer line_start += line_raw.len + 1;
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_profile = isProfileSection(line, profile);
                continue;
            }
            if (in_profile) {
                if (try stringValueForKeyAt(allocator, self.bytes, line_start, line_raw, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getProfileString(allocator, profile, key);
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

        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                if (in_section) break;
                in_section = isExactSection(line, section_name);
                continue;
            }
            if (in_section) {
                if (try stringMapEntryForLine(allocator, line)) |entry| {
                    try entries.append(allocator, entry);
                }
            }
            multiline.observeLine(line);
        }
        if (entries.items.len == 0) {
            entries.deinit(allocator);
            entries = .empty;
            if (self.fallback) |fallback| return fallback.getSectionStringMap(allocator, section_name);
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
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, "model_providers.", provider);
                continue;
            }
            if (in_provider) {
                if (try inlineTableValueForKey(allocator, line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getModelProviderInlineTable(allocator, provider, key);
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
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, section_prefix, section_name);
                continue;
            }
            if (in_provider) {
                if (try stringValueForKey(allocator, line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getNamedSectionString(allocator, section_prefix, section_name, key);
        return null;
    }

    fn getModelProviderBool(
        self: ConfigView,
        provider: []const u8,
        key: []const u8,
    ) ?bool {
        var in_provider = false;
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_provider = isNamedSection(line, "model_providers.", provider);
                continue;
            }
            if (in_provider) {
                if (boolValueForKey(line, key)) |value| return value;
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.getModelProviderBool(provider, key);
        return null;
    }

    fn resolveCustomSandboxPermissionProfile(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: []const u8,
    ) !SandboxPermissionProfile {
        return self.resolveCustomSandboxPermissionProfileWithOptions(allocator, profile, .{});
    }

    fn resolveCustomSandboxPermissionProfileWithOptions(
        self: ConfigView,
        allocator: std.mem.Allocator,
        profile: []const u8,
        options: SandboxPermissionProfileOptions,
    ) !SandboxPermissionProfile {
        var state = CustomSandboxPermissionProfileState{
            .allow_read_denied_globs = options.allow_read_denied_globs,
        };
        errdefer state.deinit(allocator);

        var saw_filesystem = false;
        var saw_network = false;
        var network_enabled: ?bool = null;
        var network_unsupported = false;
        var in_filesystem = false;
        var in_network = false;

        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
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
            multiline.observeLine(line);
        }

        if (!saw_filesystem and !saw_network) {
            if (self.fallback) |fallback| return fallback.resolveCustomSandboxPermissionProfileWithOptions(allocator, profile, options);
        }
        if (!saw_filesystem or !saw_network or network_enabled == null or network_unsupported) {
            return error.SandboxPermissionProfileUnsupported;
        }
        return state.toSandboxPermissionProfile(allocator, network_enabled.?);
    }

    fn strictConfigUnknownField(self: ConfigView, allocator: std.mem.Allocator) !?[]const u8 {
        var section: []const u8 = "";
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (tomlSectionName(line)) |name| {
                section = name;
                if (!strictConfigSectionAllowed(section)) return try allocator.dupe(u8, section);
                continue;
            }
            if (tomlAssignmentKey(line)) |key| {
                const field = if (section.len == 0)
                    try allocator.dupe(u8, key)
                else
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section, key });
                errdefer allocator.free(field);
                if (!strictConfigPathAllowed(field)) return field;
                if (try strictConfigInlineTableUnknownField(allocator, field, line)) |inline_field| {
                    allocator.free(field);
                    return inline_field;
                }
                allocator.free(field);
            }
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.strictConfigUnknownField(allocator);
        return null;
    }

    fn hasProfile(self: ConfigView, profile: []const u8) bool {
        var multiline = TomlMultilineScanState{};
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (multiline.skipBodyLine(line_raw)) continue;
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[' and isProfileOrNestedSection(line, profile)) return true;
            multiline.observeLine(line);
        }
        if (self.fallback) |fallback| return fallback.hasProfile(profile);
        return false;
    }
};

fn tomlSectionName(line: []const u8) ?[]const u8 {
    if (line.len >= 4 and std.mem.startsWith(u8, line, "[[")) {
        const close = tomlHeaderCloseIndex(line, 2, true) orelse return null;
        if (!tomlHeaderRemainderAllowed(line[close + 2 ..])) return null;
        return std.mem.trim(u8, line[2..close], " \t");
    }
    if (line.len >= 2 and line[0] == '[') {
        const close = tomlHeaderCloseIndex(line, 1, false) orelse return null;
        if (!tomlHeaderRemainderAllowed(line[close + 1 ..])) return null;
        return std.mem.trim(u8, line[1..close], " \t");
    }
    return null;
}

fn tomlHeaderCloseIndex(line: []const u8, start: usize, array_table: bool) ?usize {
    var index = start;
    var in_quote = false;
    var escaped = false;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (in_quote) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_quote = false;
            }
            continue;
        }
        if (byte == '#') return null;
        if (byte == '"') {
            in_quote = true;
            continue;
        }
        if (array_table) {
            if (byte == ']' and index + 1 < line.len and line[index + 1] == ']') return index;
        } else if (byte == ']') {
            return index;
        }
    }
    return null;
}

fn tomlHeaderRemainderAllowed(rest: []const u8) bool {
    const trimmed = std.mem.trim(u8, rest, " \t\r");
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn strictConfigSectionAllowed(section: []const u8) bool {
    return strictConfigPathAllowed(section);
}

fn strictConfigPathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    if (strictConfigRootPathAllowed(path)) return true;
    const first = tomlDottedPathFirstSegment(path) orelse return false;
    if (first.rest.len == 0) return false;
    if (tomlSegmentMatches(first.raw, "features")) return strictConfigFeaturePathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "profiles")) return strictConfigProfilePathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "model_providers")) return strictConfigModelProviderPathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "mcp_servers")) return strictConfigMcpServerPathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "tui")) return strictConfigTuiPathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "sandbox_workspace_write")) return strictConfigSandboxWorkspaceWritePathAllowed(first.rest);
    if (tomlSegmentMatches(first.raw, "history")) return strictConfigLeafPathAllowed(first.rest, &[_][]const u8{ "persistence", "max_bytes" });
    if (tomlSegmentMatches(first.raw, "audio")) return strictConfigLeafPathAllowed(first.rest, &[_][]const u8{ "microphone", "speaker" });
    if (tomlSegmentMatches(first.raw, "analytics")) return strictConfigLeafPathAllowed(first.rest, &[_][]const u8{"enabled"});
    if (tomlSegmentMatches(first.raw, "feedback")) return strictConfigLeafPathAllowed(first.rest, &[_][]const u8{"enabled"});
    if (tomlSegmentMatches(first.raw, "notice")) return strictConfigNoticePathAllowed(first.rest);
    for (strict_config_opaque_roots) |root| {
        if (strictConfigOpaqueRootPathAllowed(path, root)) return true;
    }
    return false;
}

fn strictConfigOverridePathAllowed(path: []const u8) bool {
    if (std.mem.eql(u8, path, "tui_alternate_screen")) return true;
    return strictConfigPathAllowed(path);
}

const strict_config_opaque_roots = [_][]const u8{
    "desktop",
    "permissions",
    "sandbox",
    "tools",
    "hooks",
    "projects",
    "plugins",
    "marketplaces",
    "apps",
    "notifications",
    "external_agents",
    "experimental_network",
    "shell_environment_policy",
    "debug",
    "tool_suggest",
    "agents",
    "memories",
    "skills",
    "audio",
    "realtime",
    "experimental_thread_store",
    "ghost_snapshot",
    "otel",
    "windows",
};

fn strictConfigRootPathAllowed(path: []const u8) bool {
    const known = [_][]const u8{
        "profile",
        "model",
        "review_model",
        "model_context_window",
        "model_auto_compact_token_limit",
        "model_auto_compact_token_limit_scope",
        "model_provider",
        "openai_base_url",
        "chatgpt_base_url",
        "oss_provider",
        "approval_policy",
        "approvals_reviewer",
        "auto_review",
        "sandbox_mode",
        "sandbox_workspace_write",
        "default_permissions",
        "web_search",
        "model_reasoning_effort",
        "plan_mode_reasoning_effort",
        "model_reasoning_summary",
        "model_verbosity",
        "model_supports_reasoning_summaries",
        "model_catalog_json",
        "service_tier",
        "syntax_theme",
        "personality",
        "instructions",
        "base_instructions",
        "developer_instructions",
        "include_permissions_instructions",
        "include_apps_instructions",
        "include_collaboration_mode_instructions",
        "include_environment_context",
        "model_instructions_file",
        "compact_prompt",
        "forced_login_method",
        "forced_chatgpt_workspace_id",
        "cli_auth_credentials_store",
        "mcp_oauth_credentials_store",
        "mcp_oauth_callback_port",
        "mcp_oauth_callback_url",
        "project_doc_max_bytes",
        "project_doc_fallback_filenames",
        "tool_output_token_limit",
        "background_terminal_max_timeout",
        "allow_login_shell",
        "notify",
        "js_repl_node_path",
        "js_repl_node_module_dirs",
        "zsh_path",
        "sqlite_home",
        "log_dir",
        "file_opener",
        "hide_agent_reasoning",
        "show_raw_agent_reasoning",
        "apps_mcp_product_sku",
        "experimental_realtime_ws_base_url",
        "experimental_realtime_ws_model",
        "experimental_realtime_ws_backend_prompt",
        "experimental_realtime_ws_startup_context",
        "experimental_realtime_start_instructions",
        "experimental_thread_config_endpoint",
        "experimental_thread_store_endpoint",
        "experimental_compact_prompt_file",
        "experimental_use_unified_exec_tool",
        "project_root_markers",
        "check_for_update_on_startup",
        "disable_paste_burst",
        "suppress_unstable_features_warning",
        "features",
        "profiles",
        "model_providers",
        "mcp_servers",
        "tools",
        "tui",
        "hooks",
        "projects",
        "permissions",
        "sandbox",
        "plugins",
        "marketplaces",
        "apps",
        "analytics",
        "feedback",
        "history",
        "notifications",
        "external_agents",
        "experimental_network",
        "shell_environment_policy",
        "debug",
        "tool_suggest",
        "agents",
        "memories",
        "skills",
        "audio",
        "realtime",
        "experimental_thread_store",
        "ghost_snapshot",
        "desktop",
        "otel",
        "windows",
        "notice",
    };
    return stringInList(path, &known);
}

fn strictConfigFeaturePathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    const key = tomlDottedPathFirstSegment(path) orelse return false;
    if (!strictConfigFeatureKeyKnown(key.raw)) return false;
    if (key.rest.len == 0) return true;
    return strictConfigFeatureConfigPathAllowed(key.raw, key.rest);
}

fn strictConfigFeatureConfigPathAllowed(raw_key: []const u8, path: []const u8) bool {
    if (tomlSegmentMatches(raw_key, "multi_agent_v2")) {
        return strictConfigLeafPathAllowed(path, &[_][]const u8{
            "enabled",
            "max_concurrent_threads_per_session",
            "min_wait_timeout_ms",
            "max_wait_timeout_ms",
            "default_wait_timeout_ms",
            "usage_hint_enabled",
            "usage_hint_text",
            "root_agent_usage_hint_text",
            "subagent_usage_hint_text",
            "tool_namespace",
            "hide_spawn_agent_metadata",
            "non_code_mode_only",
        });
    }
    if (tomlSegmentMatches(raw_key, "apps_mcp_path_override")) {
        return strictConfigLeafPathAllowed(path, &[_][]const u8{ "enabled", "path" });
    }
    if (tomlSegmentMatches(raw_key, "network_proxy")) {
        if (strictConfigMapLeafPathAllowed(path, "domains")) return true;
        if (strictConfigMapLeafPathAllowed(path, "unix_sockets")) return true;
        return strictConfigLeafPathAllowed(path, &[_][]const u8{
            "enabled",
            "proxy_url",
            "enable_socks5",
            "socks_url",
            "enable_socks5_udp",
            "allow_upstream_proxy",
            "dangerously_allow_non_loopback_proxy",
            "dangerously_allow_all_unix_sockets",
            "mode",
            "domains",
            "unix_sockets",
            "allow_local_binding",
        });
    }
    return false;
}

fn strictConfigProfilePathAllowed(path: []const u8) bool {
    const profile = tomlDottedPathFirstSegment(path) orelse return false;
    if (profile.rest.len == 0) return true;
    const nested = profile.rest;
    const nested_first = tomlDottedPathFirstSegment(nested) orelse return false;
    if (tomlSegmentMatches(nested_first.raw, "features")) {
        return nested_first.rest.len == 0 or strictConfigFeaturePathAllowed(nested_first.rest);
    }
    return strictConfigPathAllowed(nested);
}

fn strictConfigModelProviderPathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    const provider = tomlDottedPathFirstSegment(path) orelse return false;
    if (provider.rest.len == 0) return true;
    const nested = provider.rest;
    if (strictConfigMapLeafPathAllowed(nested, "query_params") or
        strictConfigMapLeafPathAllowed(nested, "http_headers") or
        strictConfigMapLeafPathAllowed(nested, "env_http_headers"))
    {
        return true;
    }
    if (strictConfigKnownSubtablePathAllowed(nested, "auth", &[_][]const u8{ "command", "args", "cwd", "timeout_ms", "refresh_interval_ms" })) {
        return true;
    }
    const known = [_][]const u8{
        "base_url",
        "wire_api",
        "env_key",
        "experimental_bearer_token",
        "requires_openai_auth",
        "query_params",
        "http_headers",
        "env_http_headers",
        "auth",
    };
    return strictConfigLeafPathAllowed(nested, &known);
}

fn strictConfigMcpServerPathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    const server = tomlDottedPathFirstSegment(path) orelse return false;
    if (server.rest.len == 0) return true;
    const nested = server.rest;
    if (strictConfigMapLeafPathAllowed(nested, "env") or
        strictConfigMapLeafPathAllowed(nested, "http_headers") or
        strictConfigMapLeafPathAllowed(nested, "env_http_headers"))
    {
        return true;
    }
    if (strictConfigKnownSubtablePathAllowed(nested, "identity", &[_][]const u8{ "command", "url" })) {
        return true;
    }
    const known = [_][]const u8{
        "command",
        "args",
        "env",
        "cwd",
        "url",
        "bearer_token",
        "bearer_token_env_var",
        "http_headers",
        "env_http_headers",
        "env_vars",
        "scopes",
        "enabled",
        "disabled",
        "required",
        "startup_timeout_sec",
        "tool_timeout_sec",
        "oauth_resource",
        "identity",
    };
    return strictConfigLeafPathAllowed(nested, &known);
}

fn strictConfigSandboxWorkspaceWritePathAllowed(path: []const u8) bool {
    return strictConfigLeafPathAllowed(path, &[_][]const u8{
        "writable_roots",
        "network_access",
        "exclude_tmpdir_env_var",
        "exclude_slash_tmp",
    });
}

fn strictConfigTuiPathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    if (strictConfigMapLeafPathAllowed(path, "keymap") or
        strictConfigMapLeafPathAllowed(path, "model_availability_nux"))
    {
        return true;
    }
    return strictConfigLeafPathAllowed(path, &[_][]const u8{
        "notifications",
        "notification_method",
        "notification_condition",
        "animations",
        "show_tooltips",
        "vim_mode_default",
        "raw_output_mode",
        "alternate_screen",
        "status_line",
        "status_line_use_colors",
        "terminal_title",
        "theme",
        "pet",
        "pet_anchor",
        "session_picker_view",
        "keymap",
        "model_availability_nux",
        "terminal_resize_reflow_max_rows",
    });
}

fn strictConfigNoticePathAllowed(path: []const u8) bool {
    if (path.len == 0) return false;
    if (strictConfigMapLeafPathAllowed(path, "external_config_migration")) return true;
    return strictConfigLeafPathAllowed(path, &[_][]const u8{
        "hide_full_access_warning",
        "hide_world_writable_warning",
        "fast_default_opt_out",
        "hide_rate_limit_model_nudge",
        "hide_gpt5_1_migration_prompt",
        "hide_gpt-5.1-codex-max_migration_prompt",
        "external_config_migration",
    });
}

fn strictConfigLeafPathAllowed(path: []const u8, known: anytype) bool {
    const segment = tomlDottedPathFirstSegment(path) orelse return false;
    return segment.rest.len == 0 and stringInList(segment.raw, known);
}

fn strictConfigMapLeafPathAllowed(path: []const u8, table: []const u8) bool {
    const first = tomlDottedPathFirstSegment(path) orelse return false;
    if (!tomlSegmentMatches(first.raw, table)) return false;
    if (first.rest.len == 0) return true;
    const leaf = tomlDottedPathFirstSegment(first.rest) orelse return false;
    return leaf.rest.len == 0;
}

fn strictConfigKnownSubtablePathAllowed(path: []const u8, table: []const u8, known: anytype) bool {
    const first = tomlDottedPathFirstSegment(path) orelse return false;
    if (!tomlSegmentMatches(first.raw, table)) return false;
    if (first.rest.len == 0) return true;
    return strictConfigLeafPathAllowed(first.rest, known);
}

fn strictConfigInlineTableUnknownField(
    allocator: std.mem.Allocator,
    field: []const u8,
    line: []const u8,
) anyerror!?[]const u8 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    const contents = try parseInlineTableContents(allocator, rhs) orelse return null;
    defer allocator.free(contents);
    return try strictConfigInlineTableContentsUnknownField(allocator, field, contents);
}

fn strictConfigInlineTableContentsUnknownField(
    allocator: std.mem.Allocator,
    parent: []const u8,
    contents: []const u8,
) anyerror!?[]const u8 {
    var start: usize = 0;
    var index: usize = 0;
    var in_string = false;
    var escaped = false;
    var array_depth: usize = 0;
    var table_depth: usize = 0;
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
            if (byte == '{') {
                table_depth += 1;
                continue;
            }
            if (byte == '}') {
                if (table_depth == 0) return error.InvalidTomlInlineTable;
                table_depth -= 1;
                continue;
            }
            if (byte != ',' or array_depth != 0 or table_depth != 0) continue;
        }

        const entry = std.mem.trim(u8, contents[start..index], " \t\r\n");
        start = index + 1;
        if (entry.len == 0) continue;
        const key = tomlAssignmentKey(entry) orelse continue;
        const child = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent, key });
        errdefer allocator.free(child);
        if (!strictConfigPathAllowed(child)) return child;
        if (try strictConfigInlineTableUnknownField(allocator, child, entry)) |unknown| {
            allocator.free(child);
            return unknown;
        }
        allocator.free(child);
    }
    if (in_string or array_depth != 0 or table_depth != 0) return error.InvalidTomlInlineTable;
    return null;
}

fn strictConfigOpaqueRootPathAllowed(path: []const u8, root: []const u8) bool {
    const first = tomlDottedPathFirstSegment(path) orelse return false;
    return tomlSegmentMatches(first.raw, root);
}

const TomlDottedPathSegment = struct {
    raw: []const u8,
    rest: []const u8,
};

fn tomlDottedPathFirstSegment(path: []const u8) ?TomlDottedPathSegment {
    if (path.len == 0) return null;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '"') {
            const close = tomlBasicStringClosingQuoteIndex(path[index..]) orelse return null;
            index += close;
            continue;
        }
        if (path[index] == '.') {
            return .{ .raw = path[0..index], .rest = path[index + 1 ..] };
        }
    }
    return .{ .raw = path, .rest = "" };
}

fn tomlSegmentMatches(segment: []const u8, expected: []const u8) bool {
    if (tomlQuotedNameMatches(segment, expected)) return true;
    return std.mem.eql(u8, segment, expected);
}

fn stringInList(value: []const u8, values: anytype) bool {
    for (values) |item| {
        if (tomlSegmentMatches(value, item)) return true;
    }
    return false;
}

fn strictConfigFeatureKeyKnown(key: []const u8) bool {
    if (key.len >= 2 and key[0] == '"') {
        const close = tomlBasicStringClosingQuoteIndex(key) orelse return false;
        if (close + 1 != key.len) return false;
        for (feature_registry.FeatureSpec.all) |feature| {
            if (tomlBasicStringContentMatches(key[1..close], feature.key)) return true;
        }
        return false;
    }
    return feature_registry.isKnownFeature(key);
}

const SandboxFilesystemAccess = enum {
    read,
    write,
    none,
};

const CustomSandboxPermissionProfileState = struct {
    allow_read_denied_globs: bool = false,
    root_read: bool = false,
    project_roots_write: bool = false,
    unsupported: bool = false,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    read_denied_roots: std.ArrayList([]const u8) = .empty,
    read_denied_globs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CustomSandboxPermissionProfileState, allocator: std.mem.Allocator) void {
        for (self.additional_writable_roots.items) |root| allocator.free(root);
        self.additional_writable_roots.deinit(allocator);
        for (self.read_denied_roots.items) |root| allocator.free(root);
        self.read_denied_roots.deinit(allocator);
        for (self.read_denied_globs.items) |pattern| allocator.free(pattern);
        self.read_denied_globs.deinit(allocator);
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
        const additional_writable_roots = try self.additional_writable_roots.toOwnedSlice(allocator);
        errdefer freeStringSliceItems(allocator, additional_writable_roots);
        const read_denied_roots = try self.read_denied_roots.toOwnedSlice(allocator);
        errdefer freeStringSliceItems(allocator, read_denied_roots);
        const read_denied_globs = try self.read_denied_globs.toOwnedSlice(allocator);
        errdefer freeStringSliceItems(allocator, read_denied_globs);

        return .{
            .mode = mode,
            .additional_writable_roots = .{ .items = additional_writable_roots },
            .read_denied_roots = .{ .items = read_denied_roots },
            .read_denied_globs = .{ .items = read_denied_globs },
            .include_cwd_write_root = self.project_roots_write,
            .network_enabled = network_enabled,
        };
    }
};

fn freeStringSliceItems(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn recordSandboxFilesystemLine(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    line: []const u8,
) !void {
    const eq = tomlAssignmentEqualsIndex(line) orelse return;
    const raw_key = std.mem.trim(u8, line[0..eq], " \t");
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (raw_key.len == 0) return;
    if (std.mem.eql(u8, raw_key, "glob_scan_max_depth")) {
        const depth = std.fmt.parseUnsigned(u64, tomlScalarWithoutInlineComment(rhs), 10) catch {
            state.unsupported = true;
            return;
        };
        if (depth == 0) state.unsupported = true;
        return;
    }

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
            try recordSandboxReadDenyRoot(allocator, state, path, subpath);
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

fn recordSandboxReadDenyRoot(
    allocator: std.mem.Allocator,
    state: *CustomSandboxPermissionProfileState,
    path: []const u8,
    subpath: ?[]const u8,
) !void {
    if (try sandboxPermissionProfileDenyGlobPattern(allocator, path, subpath)) |pattern| {
        errdefer allocator.free(pattern);
        if (!state.allow_read_denied_globs) {
            state.unsupported = true;
            allocator.free(pattern);
            return;
        }
        try state.read_denied_globs.append(allocator, pattern);
        return;
    }

    const root = try sandboxPermissionProfileRootPath(allocator, path, subpath) orelse {
        state.unsupported = true;
        return;
    };
    errdefer allocator.free(root);
    try state.read_denied_roots.append(allocator, root);
}

fn sandboxPermissionProfileDenyGlobPattern(
    allocator: std.mem.Allocator,
    path: []const u8,
    subpath: ?[]const u8,
) !?[]const u8 {
    if (subpath) |child| {
        if (!containsSandboxGlobChars(child)) return null;
        if (!isSafeRelativeTomlGlobSubpath(child)) return null;
        if (std.mem.eql(u8, path, ":project_roots")) {
            return try allocator.dupe(u8, child);
        }
        if (std.fs.path.isAbsolute(path)) {
            return try std.fs.path.join(allocator, &.{ path, child });
        }
        return null;
    }

    if (!containsSandboxGlobChars(path)) return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return try allocator.dupe(u8, path);
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

fn sandboxPermissionProfileRootPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    subpath: ?[]const u8,
) !?[]const u8 {
    if (subpath) |child| {
        if (!isSafeRelativeTomlSubpath(child)) return null;
        if (std.mem.eql(u8, path, ":project_roots")) {
            return try allocator.dupe(u8, child);
        }
        if (std.fs.path.isAbsolute(path)) {
            return if (std.mem.eql(u8, child, "."))
                try allocator.dupe(u8, path)
            else
                try std.fs.path.join(allocator, &.{ path, child });
        }
        return null;
    }

    if (std.mem.eql(u8, path, ":project_roots")) {
        return try allocator.dupe(u8, ".");
    }
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }
    return null;
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

fn isSafeRelativeTomlGlobSubpath(subpath: []const u8) bool {
    if (subpath.len == 0 or std.fs.path.isAbsolute(subpath)) return false;
    var iter = std.mem.splitScalar(u8, subpath, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn containsSandboxGlobChars(path: []const u8) bool {
    for (path) |byte| {
        if (byte == '*' or byte == '?' or byte == '[' or byte == ']') return true;
    }
    return false;
}

fn tomlAssignmentKey(line: []const u8) ?[]const u8 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (lhs.len == 0) return null;
    return lhs;
}

fn tomlAssignmentEqualsIndex(line: []const u8) ?usize {
    var in_basic_string = false;
    var in_literal_string = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (in_basic_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_basic_string = false;
            }
            continue;
        }
        if (in_literal_string) {
            if (byte == '\'') in_literal_string = false;
            continue;
        }
        switch (byte) {
            '#' => return null,
            '"' => in_basic_string = true,
            '\'' => in_literal_string = true,
            '=' => return index,
            else => {},
        }
    }
    return null;
}

fn isPermissionsProfileSection(line: []const u8, profile: []const u8, subsection: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "permissions.";
    if (!std.mem.startsWith(u8, section, prefix)) return false;
    const remainder = section[prefix.len..];

    if (remainder.len >= 2 and remainder[0] == '"') {
        const close = tomlBasicStringClosingQuoteIndex(remainder) orelse return false;
        if (!tomlBasicStringContentMatches(remainder[1..close], profile)) return false;
        const suffix = remainder[close + 1 ..];
        return suffix.len == subsection.len + 1 and suffix[0] == '.' and std.mem.eql(u8, suffix[1..], subsection);
    }

    return remainder.len == profile.len + subsection.len + 1 and
        std.mem.startsWith(u8, remainder, profile) and
        remainder[profile.len] == '.' and
        std.mem.eql(u8, remainder[profile.len + 1 ..], subsection);
}

fn stringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlStringValue(allocator, rhs);
}

fn stringValueForKeyAt(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    line_start: usize,
    line: []const u8,
    key: []const u8,
) !?[]const u8 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs_start = @min(line_start + eq + 1, bytes.len);
    return parseTomlStringValue(allocator, bytes[rhs_start..]);
}

fn stringMapEntryForLine(allocator: std.mem.Allocator, line: []const u8) !?StringMapEntry {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
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
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (rhs.len < 2 or rhs[0] != '{') return null;
    const end = std.mem.lastIndexOfScalar(u8, rhs, '}') orelse return error.InvalidTomlInlineTable;
    return try allocator.dupe(u8, std.mem.trim(u8, rhs[1..end], " \t\r\n"));
}

fn stringArrayValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?StringList {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlStringArray(allocator, rhs);
}

fn boolValueForKey(line: []const u8, key: []const u8) ?bool {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, rhs, "true")) return true;
    if (std.mem.eql(u8, rhs, "false")) return false;
    return null;
}

fn u64ValueForKey(line: []const u8, key: []const u8) !?u64 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return std.fmt.parseUnsigned(u64, rhs, 10) catch error.InvalidTomlInteger;
}

fn i64ValueForKey(line: []const u8, key: []const u8) !?i64 {
    const eq = tomlAssignmentEqualsIndex(line) orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = tomlScalarWithoutInlineComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));
    return std.fmt.parseInt(i64, rhs, 10) catch error.InvalidTomlInteger;
}

fn tomlScalarWithoutInlineComment(rhs: []const u8) []const u8 {
    const comment = std.mem.indexOfScalar(u8, rhs, '#') orelse return rhs;
    return std.mem.trim(u8, rhs[0..comment], " \t\r");
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
        const escaped = tomlBasicStringEscapedByte(rhs[index]) orelse return error.InvalidTomlString;
        try output.append(allocator, escaped);
    }

    return error.InvalidTomlString;
}

pub fn parseTomlStringValue(allocator: std.mem.Allocator, rhs_raw: []const u8) !?[]const u8 {
    const rhs = std.mem.trim(u8, rhs_raw, " \t");
    if (std.mem.startsWith(u8, rhs, "\"\"\"")) return try parseTomlMultilineBasicString(allocator, rhs);
    return parseTomlString(allocator, rhs);
}

fn parseTomlMultilineBasicString(allocator: std.mem.Allocator, rhs: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, rhs, "\"\"\"")) return error.InvalidTomlString;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var index: usize = 3;
    if (index < rhs.len and rhs[index] == '\n') {
        index += 1;
    } else if (index + 1 < rhs.len and rhs[index] == '\r' and rhs[index + 1] == '\n') {
        index += 2;
    }

    while (index < rhs.len) : (index += 1) {
        if (index + 2 < rhs.len and std.mem.eql(u8, rhs[index .. index + 3], "\"\"\"")) {
            return output.toOwnedSlice(allocator);
        }
        const byte = rhs[index];
        if (byte != '\\') {
            try output.append(allocator, byte);
            continue;
        }

        index += 1;
        if (index >= rhs.len) return error.InvalidTomlString;
        if (rhs[index] == '\n') {
            while (index + 1 < rhs.len and (rhs[index + 1] == ' ' or rhs[index + 1] == '\t' or rhs[index + 1] == '\r' or rhs[index + 1] == '\n')) {
                index += 1;
            }
            continue;
        }
        if (rhs[index] == '\r' and index + 1 < rhs.len and rhs[index + 1] == '\n') {
            index += 1;
            while (index + 1 < rhs.len and (rhs[index + 1] == ' ' or rhs[index + 1] == '\t' or rhs[index + 1] == '\r' or rhs[index + 1] == '\n')) {
                index += 1;
            }
            continue;
        }
        const escaped = tomlBasicStringEscapedByte(rhs[index]) orelse return error.InvalidTomlString;
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
            const escaped = tomlBasicStringEscapedByte(rhs[index]) orelse return error.InvalidTomlStringArray;
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
    return tomlQuotedNameAndDotMatches(remainder, profile);
}

fn isNamedSection(line: []const u8, prefix: []const u8, name: []const u8) bool {
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (!std.mem.startsWith(u8, section, prefix)) return false;
    const raw_name = section[prefix.len..];
    if (tomlQuotedNameMatches(raw_name, name)) return true;
    return std.mem.eql(u8, raw_name, name);
}

fn tomlQuotedNameAndDotMatches(raw: []const u8, name: []const u8) bool {
    const end_quote = tomlBasicStringClosingQuoteIndex(raw) orelse return false;
    if (end_quote + 1 >= raw.len or raw[end_quote + 1] != '.') return false;
    return tomlBasicStringContentMatches(raw[1..end_quote], name);
}

fn tomlQuotedNameMatches(raw: []const u8, name: []const u8) bool {
    const end_quote = tomlBasicStringClosingQuoteIndex(raw) orelse return false;
    if (end_quote != raw.len - 1) return false;
    return tomlBasicStringContentMatches(raw[1..end_quote], name);
}

fn tomlBasicStringClosingQuoteIndex(raw: []const u8) ?usize {
    if (raw.len < 2 or raw[0] != '"') return null;
    var index: usize = 1;
    var escaped = false;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') return index;
    }
    return null;
}

fn tomlBasicStringContentMatches(raw: []const u8, expected: []const u8) bool {
    var raw_index: usize = 0;
    var expected_index: usize = 0;
    while (raw_index < raw.len) {
        const decoded = if (raw[raw_index] == '\\') decoded: {
            raw_index += 1;
            if (raw_index >= raw.len) return false;
            break :decoded tomlBasicStringEscapedByte(raw[raw_index]) orelse return false;
        } else raw[raw_index];

        if (expected_index >= expected.len or expected[expected_index] != decoded) return false;
        expected_index += 1;
        raw_index += 1;
    }
    return expected_index == expected.len;
}

fn tomlBasicStringEscapedByte(byte: u8) ?u8 {
    return switch (byte) {
        '"' => '"',
        '\\' => '\\',
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => null,
    };
}

fn modelProviderAuthSectionName(allocator: std.mem.Allocator, provider: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "model_providers.{s}.auth", .{provider});
}

fn generateUuidString(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 36);
    var out_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            out[out_index] = '-';
            out_index += 1;
        }
        out[out_index] = hex[byte >> 4];
        out[out_index + 1] = hex[byte & 0x0f];
        out_index += 2;
    }
    return out;
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

fn canonicalUuidString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (!isUuidString(value)) return error.InvalidUuidString;

    const raw = switch (value.len) {
        38 => value[1..37],
        45 => value[9..],
        else => value,
    };

    var hex: [32]u8 = undefined;
    var hex_index: usize = 0;
    for (raw) |byte| {
        if (byte == '-') continue;
        if (hex_index >= hex.len) return error.InvalidUuidString;
        hex[hex_index] = std.ascii.toLower(byte);
        hex_index += 1;
    }
    if (hex_index != hex.len) return error.InvalidUuidString;

    var canonical: [36]u8 = undefined;
    var input_index: usize = 0;
    for (&canonical, 0..) |*byte, index| {
        switch (index) {
            8, 13, 18, 23 => byte.* = '-',
            else => {
                byte.* = hex[input_index];
                input_index += 1;
            },
        }
    }
    return allocator.dupe(u8, canonical[0..]);
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
            8, 13, 18, 23 => {
                if (byte != '-') return false;
            },
            else => if (!std.ascii.isHex(byte)) return false,
        }
    }
    return true;
}

test "installation id generates and persists uuid" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const codex_home = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(codex_home);

    const installation_id = try resolveInstallationId(allocator, codex_home);
    defer allocator.free(installation_id);
    try std.testing.expect(isUuidString(installation_id));

    const persisted = try dir.dir.readFileAlloc(io, INSTALLATION_ID_FILENAME, allocator, .limited(1024));
    defer allocator.free(persisted);
    try std.testing.expectEqualStrings(installation_id, persisted);

    const reused = try resolveInstallationId(allocator, codex_home);
    defer allocator.free(reused);
    try std.testing.expectEqualStrings(installation_id, reused);
}

test "installation id canonicalizes existing uuid" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{
        .sub_path = INSTALLATION_ID_FILENAME,
        .data = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\n",
    });

    const codex_home = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(codex_home);
    const installation_id = try resolveInstallationId(allocator, codex_home);
    defer allocator.free(installation_id);
    try std.testing.expectEqualStrings("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", installation_id);
}

test "installation id rewrites invalid contents" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{
        .sub_path = INSTALLATION_ID_FILENAME,
        .data = "not-a-uuid",
    });

    const codex_home = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(codex_home);
    const installation_id = try resolveInstallationId(allocator, codex_home);
    defer allocator.free(installation_id);
    try std.testing.expect(isUuidString(installation_id));

    const persisted = try dir.dir.readFileAlloc(io, INSTALLATION_ID_FILENAME, allocator, .limited(1024));
    defer allocator.free(persisted);
    try std.testing.expectEqualStrings(installation_id, persisted);
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
        \\approvals_reviewer = "auto_review"
        \\sandbox_mode = "read-only"
        \\
        ,
    };

    try std.testing.expectEqual(ApprovalPolicy.never, try resolveApprovalPolicy(allocator, view, null));
    try std.testing.expectEqual(ApprovalsReviewer.auto_review, try resolveApprovalsReviewer(allocator, view, null));
    try std.testing.expectEqual(SandboxMode.read_only, try resolveSandboxMode(allocator, view, null));
    try std.testing.expectEqualStrings("on-request", ApprovalPolicy.on_request.label());
    try std.testing.expectEqualStrings("guardian_subagent", ApprovalsReviewer.auto_review.label());
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

test "sandbox permission profile preserves concrete read deny roots" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\":project_roots" = { "secret" = "none" }
        \\"/tmp/codex-private" = "none"
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        ,
    };

    var profile = try view.resolveCustomSandboxPermissionProfile(allocator, "demo");
    defer profile.deinit(allocator);

    try std.testing.expectEqual(SandboxMode.read_only, profile.mode);
    try std.testing.expectEqual(@as(usize, 2), profile.read_denied_roots.items.len);
    try std.testing.expectEqualStrings("secret", profile.read_denied_roots.items[0]);
    try std.testing.expectEqualStrings("/tmp/codex-private", profile.read_denied_roots.items[1]);
}

test "sandbox permission profile preserves deny globs when enabled" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\glob_scan_max_depth = 2
        \\":root" = "read"
        \\":project_roots" = { "**/*.secret" = "none" }
        \\"/tmp/codex-private" = { "*.token" = "none" }
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        ,
    };

    var profile = try view.resolveCustomSandboxPermissionProfileWithOptions(allocator, "demo", .{
        .allow_read_denied_globs = true,
    });
    defer profile.deinit(allocator);

    try std.testing.expectEqual(SandboxMode.read_only, profile.mode);
    try std.testing.expectEqual(@as(usize, 2), profile.read_denied_globs.items.len);
    try std.testing.expectEqualStrings("**/*.secret", profile.read_denied_globs.items[0]);
    try std.testing.expectEqualStrings("/tmp/codex-private/*.token", profile.read_denied_globs.items[1]);
}

test "sandbox permission profile decodes quoted profile section escapes" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\[permissions."demo \"team".filesystem]
        \\":root" = "read"
        \\":project_roots" = "write"
        \\
        \\[permissions."demo \"team".network]
        \\enabled = false
        \\
        ,
    };

    var profile = try view.resolveCustomSandboxPermissionProfile(allocator, "demo \"team");
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

    const deny_glob_default = ConfigView{
        .bytes =
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\":project_roots" = { "**/*.secret" = "none" }
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        ,
    };
    try std.testing.expectError(error.SandboxPermissionProfileUnsupported, deny_glob_default.resolveCustomSandboxPermissionProfile(allocator, "demo"));
}

test "profile values override top-level config values" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\profile = "work"
        \\model = "base-model"
        \\oss_provider = "ollama"
        \\approval_policy = "on-request"
        \\approvals_reviewer = "user"
        \\sandbox_mode = "read-only"
        \\web_search = "cached"
        \\model_reasoning_effort = "low"
        \\model_verbosity = "low"
        \\service_tier = "flex"
        \\syntax_theme = "github"
        \\personality = "friendly"
        \\forced_login_method = "api"
        \\forced_chatgpt_workspace_id = "base-workspace"
        \\cli_auth_credentials_store = "keyring"
        \\chatgpt_base_url = "https://base.example/codex"
        \\
        \\[audio]
        \\microphone = "USB Mic"
        \\speaker = "Desk Speakers"
        \\
        \\[profiles.work]
        \\model = "profile-model"
        \\oss_provider = "lmstudio"
        \\approval_policy = "never"
        \\approvals_reviewer = "guardian_subagent"
        \\sandbox_mode = "danger-full-access"
        \\web_search = "live"
        \\model_reasoning_effort = "high"
        \\model_verbosity = "high"
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
    try std.testing.expectEqual(ApprovalsReviewer.auto_review, try resolveApprovalsReviewer(allocator, view, active_profile.?));
    try std.testing.expectEqual(SandboxMode.danger_full_access, try resolveSandboxMode(allocator, view, active_profile.?));
    try std.testing.expectEqual(WebSearchMode.live, (try resolveWebSearchMode(allocator, view, active_profile.?)).?);
    try std.testing.expectEqual(ReasoningEffort.high, (try resolveModelReasoningEffort(allocator, view, active_profile.?)).?);
    try std.testing.expectEqual(Verbosity.high, (try resolveModelVerbosity(allocator, view, active_profile.?)).?);
    const service_tier = try resolveServiceTier(allocator, view, active_profile.?);
    defer allocator.free(service_tier.?);
    try std.testing.expectEqualStrings("priority", service_tier.?);
    const syntax_theme = try resolveSyntaxTheme(allocator, view, active_profile.?);
    defer allocator.free(syntax_theme.?);
    try std.testing.expectEqualStrings("dracula", syntax_theme.?);
    try std.testing.expectEqual(Personality.pragmatic, (try resolvePersonality(allocator, view, active_profile.?)).?);
    const microphone = try resolveRealtimeAudioDevice(allocator, view, "microphone");
    defer allocator.free(microphone.?);
    try std.testing.expectEqualStrings("USB Mic", microphone.?);
    const speaker = try resolveRealtimeAudioDevice(allocator, view, "speaker");
    defer allocator.free(speaker.?);
    try std.testing.expectEqualStrings("Desk Speakers", speaker.?);
    try std.testing.expectEqual(ForcedLoginMethod.chatgpt, (try resolveForcedLoginMethod(allocator, view, active_profile.?)).?);
    const forced_workspace = try resolveForcedChatGptWorkspaceId(allocator, view, active_profile.?);
    defer allocator.free(forced_workspace.?);
    try std.testing.expectEqualStrings("profile-workspace", forced_workspace.?);
    try std.testing.expectEqual(AuthCredentialsStoreMode.keyring, try resolveCliAuthCredentialsStoreMode(allocator, view));
    try std.testing.expectEqual(@as(?bool, true), WebSearchMode.live.externalWebAccess());
    try std.testing.expectEqual(@as(?bool, false), WebSearchMode.cached.externalWebAccess());
    try std.testing.expect(WebSearchMode.disabled.externalWebAccess() == null);
}

test "review model resolves from top-level config" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model = "base-model"
        \\review_model = "review-model"
        \\
        ,
    };

    const review_model = try resolveReviewModel(allocator, view);
    defer allocator.free(review_model.?);
    try std.testing.expectEqualStrings("review-model", review_model.?);
}

test "cli auth credentials store resolves from top-level config" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(AuthCredentialsStoreMode.file, try resolveCliAuthCredentialsStoreMode(allocator, .{ .bytes = "" }));
    try std.testing.expectEqual(AuthCredentialsStoreMode.auto, try resolveCliAuthCredentialsStoreMode(allocator, .{ .bytes = "cli_auth_credentials_store = \"auto\"\n" }));
    try std.testing.expectEqual(AuthCredentialsStoreMode.ephemeral, try resolveCliAuthCredentialsStoreMode(allocator, .{ .bytes = "cli_auth_credentials_store = \"ephemeral\"\n" }));
    try std.testing.expectError(
        error.InvalidAuthCredentialsStoreMode,
        resolveCliAuthCredentialsStoreMode(allocator, .{ .bytes = "cli_auth_credentials_store = \"unknown\"\n" }),
    );
}

test "model context limits resolve from top-level config" {
    const view = ConfigView{
        .bytes =
        \\model_context_window = 128000 # tokens
        \\model_auto_compact_token_limit = 96_000 # tokens
        \\
        ,
    };

    try std.testing.expectEqual(@as(?i64, 128000), try resolveModelContextWindow(view));
    try std.testing.expectEqual(@as(?i64, 96000), try resolveModelAutoCompactTokenLimit(view));
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

    const with_pet = try updateTomlStringValue(
        allocator,
        "[tui]\ntheme = \"custom-demo\"\n",
        .{ .section = "tui" },
        "pet",
        "dewey",
    );
    defer allocator.free(with_pet);
    try std.testing.expect(std.mem.indexOf(u8, with_pet, "pet = \"dewey\"") != null);

    const with_audio = try updateTomlStringValue(
        allocator,
        "[audio]\nspeaker = \"Desk Speakers\"\n",
        .{ .section = "audio" },
        "microphone",
        "USB Mic",
    );
    defer allocator.free(with_audio);
    try std.testing.expect(std.mem.indexOf(u8, with_audio, "microphone = \"USB Mic\"") != null);

    const without_audio_microphone = try removeTomlValueForKeyPath(allocator, with_audio, "audio.microphone");
    defer allocator.free(without_audio_microphone);
    try std.testing.expect(std.mem.indexOf(u8, without_audio_microphone, "microphone =") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_audio_microphone, "speaker = \"Desk Speakers\"") != null);
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

test "quoted named section escapes are decoded" {
    const allocator = std.testing.allocator;
    const trust_level = try namedSectionStringValue(
        allocator,
        \\[projects."/tmp/a\"b\\c"]
        \\trust_level = "trusted"
        \\
    ,
        "projects.",
        "/tmp/a\"b\\c",
        "trust_level",
    );
    try std.testing.expect(trust_level != null);
    defer allocator.free(trust_level.?);
    try std.testing.expectEqualStrings("trusted", trust_level.?);
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

test "quoted nested profile section escapes are decoded" {
    const view = ConfigView{
        .bytes =
        \\[profiles."team \"a".features]
        \\goals = true
        \\
        ,
    };

    try std.testing.expect(view.hasProfile("team \"a"));
    try std.testing.expect(!view.hasProfile("team \\\"a"));
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

test "background terminal max timeout defaults and clamps to empty poll floor" {
    try std.testing.expectEqual(
        DEFAULT_BACKGROUND_TERMINAL_MAX_TIMEOUT_MS,
        try resolveBackgroundTerminalMaxTimeout(.{ .bytes = "" }),
    );
    try std.testing.expectEqual(
        @as(u64, 10_000),
        try resolveBackgroundTerminalMaxTimeout(.{ .bytes = "background_terminal_max_timeout = 10000\n" }),
    );
    try std.testing.expectEqual(
        MIN_BACKGROUND_TERMINAL_EMPTY_POLL_TIMEOUT_MS,
        try resolveBackgroundTerminalMaxTimeout(.{ .bytes = "background_terminal_max_timeout = 1\n" }),
    );
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
    try applyRawConfigOverride(&runtime, &profile, "review_model=gpt-review");
    try applyRawConfigOverride(&runtime, &profile, "model_context_window=128000");
    try applyRawConfigOverride(&runtime, &profile, "model_auto_compact_token_limit=96000");
    try applyRawConfigOverride(&runtime, &profile, "model_provider=mock-provider");
    try applyRawConfigOverride(&runtime, &profile, "openai_base_url='http://127.0.0.1:1'");
    try applyRawConfigOverride(&runtime, &profile, "chatgpt_base_url=http://127.0.0.1:2");
    try applyRawConfigOverride(&runtime, &profile, "oss_provider=ollama");
    try applyRawConfigOverride(&runtime, &profile, "approval_policy=never");
    try applyRawConfigOverride(&runtime, &profile, "approvals_reviewer=auto_review");
    try applyRawConfigOverride(&runtime, &profile, "sandbox_mode=read-only");
    try applyRawConfigOverride(&runtime, &profile, "web_search=live");
    try applyRawConfigOverride(&runtime, &profile, "service_tier=fast");
    try applyRawConfigOverride(&runtime, &profile, "syntax_theme=dracula");
    try applyRawConfigOverride(&runtime, &profile, "personality=friendly");
    try applyRawConfigOverride(&runtime, &profile, "instructions=custom base");
    try applyRawConfigOverride(&runtime, &profile, "developer_instructions=custom developer");
    try applyRawConfigOverride(&runtime, &profile, "compact_prompt=custom compact");
    try applyRawConfigOverride(&runtime, &profile, "model_reasoning_summary=detailed");
    try applyRawConfigOverride(&runtime, &profile, "model_verbosity=high");
    try applyRawConfigOverride(&runtime, &profile, "tui.alternate_screen=never");
    try applyRawConfigOverride(&runtime, &profile, "unsupported.key=true");

    try std.testing.expectEqualStrings("work", profile.?);
    try std.testing.expectEqualStrings("gpt-test", runtime.model.?);
    try std.testing.expectEqualStrings("gpt-review", runtime.review_model.?);
    try std.testing.expectEqual(@as(i64, 128000), runtime.model_context_window.?);
    try std.testing.expectEqual(@as(i64, 96000), runtime.model_auto_compact_token_limit.?);
    try std.testing.expectEqualStrings("mock-provider", runtime.model_provider_id.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1", runtime.openai_base_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:2", runtime.chatgpt_base_url.?);
    try std.testing.expectEqualStrings("ollama", runtime.oss_provider.?);
    try std.testing.expectEqual(ApprovalPolicy.never, runtime.approval_policy.?);
    try std.testing.expectEqual(ApprovalsReviewer.auto_review, runtime.approvals_reviewer.?);
    try std.testing.expectEqual(SandboxMode.read_only, runtime.sandbox_mode.?);
    try std.testing.expectEqual(WebSearchMode.live, runtime.web_search_mode.?);
    try std.testing.expectEqualStrings("fast", runtime.service_tier.?);
    try std.testing.expectEqualStrings("dracula", runtime.syntax_theme.?);
    try std.testing.expectEqual(Personality.friendly, runtime.personality.?);
    try std.testing.expectEqualStrings("custom base", runtime.base_instructions.?);
    try std.testing.expectEqualStrings("custom developer", runtime.developer_instructions.?);
    try std.testing.expectEqualStrings("custom compact", runtime.compact_prompt.?);
    try std.testing.expectEqual(ReasoningSummary.detailed, runtime.model_reasoning_summary.?);
    try std.testing.expectEqual(Verbosity.high, runtime.model_verbosity.?);
    try std.testing.expectEqual(AltScreenMode.never, runtime.tui_alternate_screen.?);
}

test "raw cli config override rejects missing assignment" {
    var runtime = RuntimeOverrides{};
    var profile: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidConfigOverride, applyRawConfigOverride(&runtime, &profile, "model"));
}

test "raw cli config override reports strict unknown fields" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "model=gpt-test"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.goals=true"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.apps=true"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.apply_patch_freeform=true"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.multi_agent_v2.enabled=true"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.apps_mcp_path_override.path=\"/tmp/apps-mcp\""));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features.network_proxy.domains.\"api.example.com\"=\"allow\""));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "mcp_servers.local.command=echo"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "mcp_servers.\"local.test\".command=echo"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "mcp_servers.\"foo=bar\".command=echo"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "mcp_servers.local.scopes=[\"read\"]"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "mcp_servers.local.env_vars=[\"TOKEN\"]"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "model_providers.mock.http_headers.\"x-api.key\"=\"value\""));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "sandbox_workspace_write.network_access=true"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "tui.theme=dracula"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "tui_alternate_screen=never"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features={goals=true}"));
    try std.testing.expectEqual(null, try rawConfigOverrideUnknownField(allocator, "features={multi_agent_v2={enabled=true}}"));
    const foo = (try rawConfigOverrideUnknownField(allocator, "foo=bar")).?;
    defer allocator.free(foo);
    try std.testing.expectEqualStrings("foo", foo);
    const feature = (try rawConfigOverrideUnknownField(allocator, "features.nope=true")).?;
    defer allocator.free(feature);
    try std.testing.expectEqualStrings("features.nope", feature);
    const nested_feature = (try rawConfigOverrideUnknownField(allocator, "features.nope.goals=true")).?;
    defer allocator.free(nested_feature);
    try std.testing.expectEqualStrings("features.nope.goals", nested_feature);
    const inline_feature = (try rawConfigOverrideUnknownField(allocator, "features={nope=true}")).?;
    defer allocator.free(inline_feature);
    try std.testing.expectEqualStrings("features.nope", inline_feature);
    const mcp = (try rawConfigOverrideUnknownField(allocator, "mcp_servers.local.unknown_key=true")).?;
    defer allocator.free(mcp);
    try std.testing.expectEqualStrings("mcp_servers.local.unknown_key", mcp);
    const tui = (try rawConfigOverrideUnknownField(allocator, "tui.unknown_key=true")).?;
    defer allocator.free(tui);
    try std.testing.expectEqualStrings("tui.unknown_key", tui);
    const inline_provider_auth = (try rawConfigOverrideUnknownField(allocator, "model_providers.mock.auth={bogus=true}")).?;
    defer allocator.free(inline_provider_auth);
    try std.testing.expectEqualStrings("model_providers.mock.auth.bogus", inline_provider_auth);
}

test "strict config scan accepts known and opaque desktop fields" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\model = "gpt-test"
        \\
        \\[features] # comment
        \\goals = true
        \\apps = true
        \\apply_patch_freeform = true
        \\
        \\[features.multi_agent_v2]
        \\enabled = true
        \\max_concurrent_threads_per_session = 4
        \\usage_hint_text = "Use focused workers."
        \\
        \\[features.apps_mcp_path_override]
        \\path = "/tmp/apps-mcp"
        \\
        \\[features.network_proxy]
        \\enabled = true
        \\mode = "limited"
        \\
        \\[features.network_proxy.domains]
        \\"api.example.com" = "allow"
        \\
        \\[features.network_proxy.unix_sockets]
        \\"/tmp/proxy.sock" = "allow"
        \\
        \\[profiles."team.a".features]
        \\shell_tool = true
        \\
        \\[profiles."team.a".features.multi_agent_v2]
        \\enabled = true
        \\
        \\[tui] # comment
        \\theme = "dracula"
        \\alternate_screen = "never"
        \\
        \\[mcp_servers.local]
        \\command = "echo"
        \\args = [
        \\  "--foo=bar",
        \\]
        \\env_vars = ["TOKEN"]
        \\scopes = ["read"]
        \\
        \\[mcp_servers."local.test".env]
        \\TOKEN = "value"
        \\
        \\[model_providers.mock]
        \\base_url = "http://127.0.0.1:1/v1"
        \\wire_api = "responses"
        \\
        \\[model_providers."mock.v1".auth]
        \\command = "print-token"
        \\timeout_ms = 1000
        \\
        \\[model_providers.inline]
        \\auth = { command = "print-token", args = ["--json"], timeout_ms = 1000 }
        \\
        \\[permissions.demo.filesystem]
        \\":root" = "read"
        \\
        \\[permissions.demo.network]
        \\enabled = true
        \\
        \\[sandbox_workspace_write]
        \\writable_roots = ["/tmp/codex-extra"]
        \\network_access = true
        \\exclude_tmpdir_env_var = false
        \\exclude_slash_tmp = false
        \\
        \\[hooks.on_turn_start]
        \\command = "echo"
        \\
        \\[skills."local.skill"]
        \\path = "."
        \\
        \\[desktop]
        \\appearanceTheme = "dark"
        \\
        \\[desktop.workspace]
        \\collapsed = true
        \\
        ,
    };

    try std.testing.expectEqual(null, try view.strictConfigUnknownField(allocator));
}

test "strict config scan reports unknown nested fields" {
    const allocator = std.testing.allocator;

    const top_level = ConfigView{ .bytes = "unknown_key = true\n" };
    const top_level_field = (try top_level.strictConfigUnknownField(allocator)).?;
    defer allocator.free(top_level_field);
    try std.testing.expectEqualStrings("unknown_key", top_level_field);

    const feature = ConfigView{
        .bytes =
        \\[features]
        \\nope = true
        \\
        ,
    };
    const feature_field = (try feature.strictConfigUnknownField(allocator)).?;
    defer allocator.free(feature_field);
    try std.testing.expectEqualStrings("features.nope", feature_field);

    const nested_feature = ConfigView{
        .bytes =
        \\[features.nope]
        \\goals = true
        \\
        ,
    };
    const nested_feature_field = (try nested_feature.strictConfigUnknownField(allocator)).?;
    defer allocator.free(nested_feature_field);
    try std.testing.expectEqualStrings("features.nope", nested_feature_field);

    const feature_config = ConfigView{
        .bytes =
        \\[features.multi_agent_v2]
        \\nope = true
        \\
        ,
    };
    const feature_config_field = (try feature_config.strictConfigUnknownField(allocator)).?;
    defer allocator.free(feature_config_field);
    try std.testing.expectEqualStrings("features.multi_agent_v2.nope", feature_config_field);

    const profile_feature = ConfigView{
        .bytes =
        \\[profiles.work.features]
        \\nope = true
        \\
        ,
    };
    const profile_feature_field = (try profile_feature.strictConfigUnknownField(allocator)).?;
    defer allocator.free(profile_feature_field);
    try std.testing.expectEqualStrings("profiles.work.features.nope", profile_feature_field);

    const mcp = ConfigView{
        .bytes =
        \\[mcp_servers.local]
        \\unknown_key = true
        \\
        ,
    };
    const mcp_field = (try mcp.strictConfigUnknownField(allocator)).?;
    defer allocator.free(mcp_field);
    try std.testing.expectEqualStrings("mcp_servers.local.unknown_key", mcp_field);

    const tui = ConfigView{
        .bytes =
        \\[tui]
        \\unknown_key = true
        \\
        ,
    };
    const tui_field = (try tui.strictConfigUnknownField(allocator)).?;
    defer allocator.free(tui_field);
    try std.testing.expectEqualStrings("tui.unknown_key", tui_field);

    const dotted_provider = ConfigView{
        .bytes =
        \\model_provider = "mock"
        \\model_providers.mock.base_url = "http://127.0.0.1:1/v1"
        \\model_providers.mock.typo.base_url = "http://bad.example/v1"
        \\
        ,
    };
    const dotted_provider_field = (try dotted_provider.strictConfigUnknownField(allocator)).?;
    defer allocator.free(dotted_provider_field);
    try std.testing.expectEqualStrings("model_providers.mock.typo.base_url", dotted_provider_field);

    const inline_auth = ConfigView{
        .bytes =
        \\[model_providers.mock]
        \\auth = { command = "echo", bogus = true }
        \\
        ,
    };
    const inline_auth_field = (try inline_auth.strictConfigUnknownField(allocator)).?;
    defer allocator.free(inline_auth_field);
    try std.testing.expectEqualStrings("model_providers.mock.auth.bogus", inline_auth_field);

    const nested_map = ConfigView{
        .bytes =
        \\[mcp_servers.local.env.FOO]
        \\BAR = "value"
        \\
        ,
    };
    const nested_map_field = (try nested_map.strictConfigUnknownField(allocator)).?;
    defer allocator.free(nested_map_field);
    try std.testing.expectEqualStrings("mcp_servers.local.env.FOO.BAR", nested_map_field);
}

test "profile v2 config view falls back to base config" {
    const allocator = std.testing.allocator;
    const base = ConfigView{
        .bytes =
        \\model = "base-model"
        \\review_model = "base-review"
        \\sandbox_mode = "read-only"
        \\
        \\[profiles.work]
        \\model = "base-profile-model"
        \\
        \\[model_providers.base]
        \\base_url = "http://base.example/v1"
        \\
        ,
    };
    const overlay = ConfigView{
        .bytes =
        \\sandbox_mode = "danger-full-access"
        \\
        \\[profiles.work]
        \\model = "overlay-profile-model"
        \\
        ,
        .fallback = &base,
    };

    const model = (try overlay.getScopedString(allocator, "work", "model")).?;
    defer allocator.free(model);
    try std.testing.expectEqualStrings("overlay-profile-model", model);

    const review_model = (try overlay.getTopLevelString(allocator, "review_model")).?;
    defer allocator.free(review_model);
    try std.testing.expectEqualStrings("base-review", review_model);

    const sandbox_mode = try resolveSandboxMode(allocator, overlay, null);
    try std.testing.expectEqual(SandboxMode.danger_full_access, sandbox_mode);

    const base_url = (try overlay.getModelProviderString(allocator, "base", "base_url")).?;
    defer allocator.free(base_url);
    try std.testing.expectEqualStrings("http://base.example/v1", base_url);
}

test "runtime model_provider override refreshes provider settings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\[model_providers.mock]
        \\base_url = "http://127.0.0.1:7654/v1"
        \\env_key = "MOCK_PROVIDER_KEY"
        \\wire_api = "responses"
        \\requires_openai_auth = false
        \\
        ,
    });

    const codex_home_z = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(codex_home_z);
    const codex_home = try allocator.dupe(u8, codex_home_z);
    var cfg = Config{
        .codex_home = codex_home,
        .active_profile = null,
        .model = try allocator.dupe(u8, "gpt-test"),
        .model_provider_id = try allocator.dupe(u8, "openai"),
        .model_provider_requires_openai_auth = true,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .chatgpt_base_url = try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex"),
        .oss_provider = null,
        .installation_id = try allocator.dupe(u8, "install"),
        .approval_policy = .on_request,
        .approvals_reviewer = .user,
        .sandbox_mode = .workspace_write,
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

    try applyRuntimeOverrides(&cfg, allocator, .{ .model_provider_id = "mock" });

    try std.testing.expectEqualStrings("mock", cfg.model_provider_id.?);
    try std.testing.expect(!cfg.model_provider_requires_openai_auth);
    try std.testing.expectEqualStrings("http://127.0.0.1:7654/v1", cfg.openai_base_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:7654/v1", cfg.chatgpt_base_url);
    try std.testing.expectEqual(ModelProviderWireApi.responses, cfg.model_provider_wire_api);
    try std.testing.expectEqualStrings("MOCK_PROVIDER_KEY", cfg.model_provider_env_key.?);
}

test "runtime model_provider override honors ignored user config" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\[model_providers.mock]
        \\base_url = "http://ignored.example/v1"
        \\env_key = "IGNORED_PROVIDER_KEY"
        \\requires_openai_auth = false
        \\[model_providers.mock.http_headers]
        \\"X-Ignored" = "secret"
        \\
        ,
    });

    const codex_home_z = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(codex_home_z);
    const codex_home = try allocator.dupe(u8, codex_home_z);
    var cfg = Config{
        .codex_home = codex_home,
        .ignore_user_config = true,
        .active_profile = null,
        .model = try allocator.dupe(u8, "gpt-test"),
        .model_provider_id = null,
        .model_provider_requires_openai_auth = true,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .chatgpt_base_url = try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex"),
        .oss_provider = null,
        .installation_id = try allocator.dupe(u8, "install"),
        .approval_policy = .on_request,
        .approvals_reviewer = .user,
        .sandbox_mode = .workspace_write,
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

    try applyRuntimeOverrides(&cfg, allocator, .{ .model_provider_id = "mock" });

    try std.testing.expectEqualStrings("mock", cfg.model_provider_id.?);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", cfg.openai_base_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex", cfg.chatgpt_base_url);
    try std.testing.expect(cfg.model_provider_env_key == null);
    try std.testing.expect(cfg.model_provider_http_headers == null);
}

test "instructions config key resolves as base instructions" {
    const allocator = std.testing.allocator;
    const view = ConfigView{ .bytes = "instructions = \"custom base instructions\"\n" };

    const instructions = try resolveBaseInstructions(allocator, view, null);
    defer allocator.free(instructions.?);

    try std.testing.expectEqualStrings("custom base instructions", instructions.?);
}

test "multiline instruction config keys resolve" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\instructions = """
        \\Custom base.
        \\Second line."""
        \\developer_instructions = """
        \\Developer line."""
        \\compact_prompt = """
        \\Compact line."""
        \\
        ,
    };

    const instructions = try resolveBaseInstructions(allocator, view, null);
    defer allocator.free(instructions.?);
    const developer_instructions = try resolveDeveloperInstructions(allocator, view, null);
    defer allocator.free(developer_instructions.?);
    const compact_prompt = try resolveCompactPrompt(allocator, view, null);
    defer allocator.free(compact_prompt.?);

    try std.testing.expectEqualStrings("Custom base.\nSecond line.", instructions.?);
    try std.testing.expectEqualStrings("Developer line.", developer_instructions.?);
    try std.testing.expectEqualStrings("Compact line.", compact_prompt.?);
}

test "multiline string bodies are skipped while scanning config keys" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\instructions = """
        \\model = "embedded-model"
        \\[profiles.embedded]
        \\"""
        \\model = "real-model"
        \\
        ,
    };

    const model = try resolveModel(allocator, view, null);
    defer allocator.free(model);

    try std.testing.expectEqualStrings("real-model", model);
    try std.testing.expect(!view.hasProfile("embedded"));

    const strict_view = ConfigView{
        .bytes =
        \\instructions = '''
        \\foo = "bar"
        \\[bad.section]
        \\'''
        \\model = "real-model"
        \\
        ,
    };

    try std.testing.expectEqual(null, try strict_view.strictConfigUnknownField(allocator));
}

test "profile base instructions override top-level instructions alias" {
    const allocator = std.testing.allocator;
    const view = ConfigView{
        .bytes =
        \\instructions = "global instructions"
        \\
        \\[profiles.work]
        \\base_instructions = "profile base instructions"
        \\
        ,
    };

    const instructions = try resolveBaseInstructions(allocator, view, "work");
    defer allocator.free(instructions.?);

    try std.testing.expectEqualStrings("profile base instructions", instructions.?);
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
        .model_provider_id = try allocator.dupe(u8, "custom-provider"),
        .model_provider_requires_openai_auth = true,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .chatgpt_base_url = try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex"),
        .model_provider_env_key = try allocator.dupe(u8, "CUSTOM_PROVIDER_TOKEN"),
        .model_provider_bearer_token = try allocator.dupe(u8, "secret-token"),
        .oss_provider = try allocator.dupe(u8, "ollama"),
        .installation_id = try allocator.dupe(u8, "install"),
        .approval_policy = .never,
        .approvals_reviewer = .user,
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

    const command_args = try allocator.alloc([]const u8, 1);
    command_args[0] = try allocator.dupe(u8, "arg");
    cfg.model_provider_auth_command = .{
        .command = try allocator.dupe(u8, "provider-token"),
        .args = .{ .items = command_args },
    };

    const query_entries = try allocator.alloc(StringMapEntry, 1);
    query_entries[0] = .{
        .key = try allocator.dupe(u8, "api-version"),
        .value = try allocator.dupe(u8, "2025-04-01-preview"),
    };
    cfg.model_provider_query_params = .{ .entries = query_entries };

    const header_entries = try allocator.alloc(StringMapEntry, 1);
    header_entries[0] = .{
        .key = try allocator.dupe(u8, "Authorization"),
        .value = try allocator.dupe(u8, "Bearer profile-token"),
    };
    cfg.model_provider_http_headers = .{ .entries = header_entries };

    const env_header_entries = try allocator.alloc(StringMapEntry, 1);
    env_header_entries[0] = .{
        .key = try allocator.dupe(u8, "X-Tenant"),
        .value = try allocator.dupe(u8, "TENANT_ENV"),
    };
    cfg.model_provider_env_http_headers = .{ .entries = env_header_entries };

    try applyOssMode(&cfg, allocator, null, false);
    try std.testing.expectEqualStrings("gpt-oss:20b", cfg.model);
    try std.testing.expect(std.mem.endsWith(u8, cfg.openai_base_url, "/v1"));
    try std.testing.expect(cfg.model_provider_id == null);
    try std.testing.expect(!cfg.model_provider_requires_openai_auth);
    try std.testing.expect(cfg.model_provider_env_key == null);
    try std.testing.expect(cfg.model_provider_bearer_token == null);
    try std.testing.expect(cfg.model_provider_auth_command == null);
    try std.testing.expect(cfg.model_provider_query_params == null);
    try std.testing.expect(cfg.model_provider_http_headers == null);
    try std.testing.expect(cfg.model_provider_env_http_headers == null);

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

test "write config toml file writes through symlinked parent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDirPath(io, "real-home");
    try dir.dir.symLink(io, "real-home", "linked-home", .{ .is_directory = true });

    const temp_root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_root);
    const path = try std.fs.path.join(allocator, &.{ temp_root, "linked-home", "config.toml" });
    defer allocator.free(path);

    try writeConfigTomlFile(path, "model = \"gpt-symlink-parent\"\n");

    const written = try dir.dir.readFileAlloc(io, "real-home/config.toml", allocator, .limited(1024));
    defer allocator.free(written);
    try std.testing.expectEqualStrings("model = \"gpt-symlink-parent\"\n", written);
}

test "toml string escapes are decoded" {
    const allocator = std.testing.allocator;
    const value = try parseTomlString(allocator, "\"hello\\n\\\"zig\\\"\"");
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings("hello\n\"zig\"", value.?);
}
