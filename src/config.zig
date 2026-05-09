const std = @import("std");
const env = @import("env.zig");

pub const Config = struct {
    codex_home: []const u8,
    active_profile: ?[]const u8,
    model: []const u8,
    openai_base_url: []const u8,
    chatgpt_base_url: []const u8,
    oss_provider: ?[]const u8,
    installation_id: []const u8,
    approval_policy: ApprovalPolicy,
    sandbox_mode: SandboxMode,
    web_search_mode: ?WebSearchMode,
    service_tier: ?[]const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        if (self.active_profile) |value| allocator.free(value);
        allocator.free(self.model);
        allocator.free(self.openai_base_url);
        allocator.free(self.chatgpt_base_url);
        if (self.oss_provider) |value| allocator.free(value);
        allocator.free(self.installation_id);
        if (self.service_tier) |value| allocator.free(value);
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
};

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
    }
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

    const oss_provider = try resolveOssProvider(allocator, config_view, active_profile);
    errdefer if (oss_provider) |provider| allocator.free(provider);

    const installation_id = try readOptionalFileTrimmed(allocator, codex_home, "installation_id", "unknown-zig-port");
    errdefer allocator.free(installation_id);

    const approval_policy = try resolveApprovalPolicy(allocator, config_view, active_profile);
    const sandbox_mode = try resolveSandboxMode(allocator, config_view, active_profile);
    const web_search_mode = try resolveWebSearchMode(allocator, config_view, active_profile);
    const service_tier = try resolveServiceTier(allocator, config_view, active_profile);
    errdefer if (service_tier) |value| allocator.free(value);

    return .{
        .codex_home = codex_home,
        .active_profile = active_profile,
        .model = model,
        .openai_base_url = base_urls.openai,
        .chatgpt_base_url = base_urls.chatgpt,
        .oss_provider = oss_provider,
        .installation_id = installation_id,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
        .service_tier = service_tier,
    };
}

fn resolveCodexHome(allocator: std.mem.Allocator) ![]const u8 {
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

    return allocator.dupe(u8, "gpt-5.2-codex");
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

fn readConfigToml(allocator: std.mem.Allocator, codex_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
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
            if (try stringValueForKey(allocator, line, key)) |value| return value;
        }
        return null;
    }

    fn hasProfile(self: ConfigView, profile: []const u8) bool {
        var iter = std.mem.splitScalar(u8, self.bytes, '\n');
        while (iter.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[' and isProfileSection(line, profile)) return true;
        }
        return false;
    }
};

fn stringValueForKey(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (!std.mem.eql(u8, lhs, key)) return null;
    const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
    return parseTomlString(allocator, rhs);
}

fn parseTomlString(allocator: std.mem.Allocator, rhs: []const u8) !?[]const u8 {
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

fn isProfileSection(line: []const u8, profile: []const u8) bool {
    return isNamedSection(line, "profiles.", profile);
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
        \\service_tier = "flex"
        \\chatgpt_base_url = "https://base.example/codex"
        \\
        \\[profiles.work]
        \\model = "profile-model"
        \\oss_provider = "lmstudio"
        \\approval_policy = "never"
        \\sandbox_mode = "danger-full-access"
        \\web_search = "live"
        \\service_tier = "fast"
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
    const service_tier = try resolveServiceTier(allocator, view, active_profile.?);
    defer allocator.free(service_tier.?);
    try std.testing.expectEqualStrings("priority", service_tier.?);
    try std.testing.expectEqual(@as(?bool, true), WebSearchMode.live.externalWebAccess());
    try std.testing.expectEqual(@as(?bool, false), WebSearchMode.cached.externalWebAccess());
    try std.testing.expect(WebSearchMode.disabled.externalWebAccess() == null);
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
        .service_tier = null,
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
