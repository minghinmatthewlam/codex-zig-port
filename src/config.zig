const std = @import("std");
const env = @import("env.zig");

pub const Config = struct {
    codex_home: []const u8,
    active_profile: ?[]const u8,
    model: []const u8,
    openai_base_url: []const u8,
    chatgpt_base_url: []const u8,
    installation_id: []const u8,
    approval_policy: ApprovalPolicy,
    sandbox_mode: SandboxMode,
    web_search_mode: ?WebSearchMode,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        if (self.active_profile) |value| allocator.free(value);
        allocator.free(self.model);
        allocator.free(self.openai_base_url);
        allocator.free(self.chatgpt_base_url);
        allocator.free(self.installation_id);
    }
};

pub const LoadOptions = struct {
    profile: ?[]const u8 = null,
};

pub const RuntimeOverrides = struct {
    model: ?[]const u8 = null,
    approval_policy: ?ApprovalPolicy = null,
    sandbox_mode: ?SandboxMode = null,
    web_search_mode: ?WebSearchMode = null,
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
    if (overrides.approval_policy) |approval_policy| {
        cfg.approval_policy = approval_policy;
    }
    if (overrides.sandbox_mode) |sandbox_mode| {
        cfg.sandbox_mode = sandbox_mode;
    }
    if (overrides.web_search_mode) |web_search_mode| {
        cfg.web_search_mode = web_search_mode;
    }
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

    const config_bytes = try readConfigToml(allocator, codex_home);
    defer if (config_bytes) |bytes| allocator.free(bytes);

    const config_view = ConfigView{ .bytes = config_bytes orelse "" };

    const active_profile = try resolveActiveProfile(allocator, config_view, options.profile);
    errdefer if (active_profile) |profile| allocator.free(profile);
    if (active_profile) |profile| {
        if (!config_view.hasProfile(profile)) return error.ConfigProfileNotFound;
    }

    const model = try resolveModel(allocator, config_view, active_profile);
    errdefer allocator.free(model);

    const base_urls = try resolveBaseUrls(allocator, config_view, active_profile);
    errdefer allocator.free(base_urls.openai);
    errdefer allocator.free(base_urls.chatgpt);

    const installation_id = try readOptionalFileTrimmed(allocator, codex_home, "installation_id", "unknown-zig-port");
    errdefer allocator.free(installation_id);

    const approval_policy = try resolveApprovalPolicy(allocator, config_view, active_profile);
    const sandbox_mode = try resolveSandboxMode(allocator, config_view, active_profile);
    const web_search_mode = try resolveWebSearchMode(allocator, config_view, active_profile);

    return .{
        .codex_home = codex_home,
        .active_profile = active_profile,
        .model = model,
        .openai_base_url = base_urls.openai,
        .chatgpt_base_url = base_urls.chatgpt,
        .installation_id = installation_id,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
        .web_search_mode = web_search_mode,
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

    const openai = if (try config_view.getScopedString(allocator, active_profile, "openai_base_url")) |value|
        value
    else
        try allocator.dupe(u8, "https://api.openai.com/v1");
    errdefer allocator.free(openai);

    const chatgpt = if (try config_view.getScopedString(allocator, active_profile, "chatgpt_base_url")) |value|
        value
    else
        try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex");

    return .{ .openai = openai, .chatgpt = chatgpt };
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
    if (line.len < "[]".len or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (!std.mem.startsWith(u8, section, "profiles.")) return false;
    const raw_name = section["profiles.".len..];
    if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"') {
        return std.mem.eql(u8, raw_name[1 .. raw_name.len - 1], profile);
    }
    return std.mem.eql(u8, raw_name, profile);
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
        \\approval_policy = "on-request"
        \\sandbox_mode = "read-only"
        \\web_search = "cached"
        \\chatgpt_base_url = "https://base.example/codex"
        \\
        \\[profiles.work]
        \\model = "profile-model"
        \\approval_policy = "never"
        \\sandbox_mode = "danger-full-access"
        \\web_search = "live"
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

    try std.testing.expectEqual(ApprovalPolicy.never, try resolveApprovalPolicy(allocator, view, active_profile.?));
    try std.testing.expectEqual(SandboxMode.danger_full_access, try resolveSandboxMode(allocator, view, active_profile.?));
    try std.testing.expectEqual(WebSearchMode.live, (try resolveWebSearchMode(allocator, view, active_profile.?)).?);
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

test "toml string escapes are decoded" {
    const allocator = std.testing.allocator;
    const value = try parseTomlString(allocator, "\"hello\\n\\\"zig\\\"\"");
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings("hello\n\"zig\"", value.?);
}
