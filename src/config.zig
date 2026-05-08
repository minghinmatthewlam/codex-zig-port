const std = @import("std");
const env = @import("env.zig");

pub const Config = struct {
    codex_home: []const u8,
    model: []const u8,
    openai_base_url: []const u8,
    chatgpt_base_url: []const u8,
    installation_id: []const u8,
    approval_policy: ApprovalPolicy,
    sandbox_mode: SandboxMode,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_home);
        allocator.free(self.model);
        allocator.free(self.openai_base_url);
        allocator.free(self.chatgpt_base_url);
        allocator.free(self.installation_id);
    }
};

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

const BaseUrls = struct {
    openai: []const u8,
    chatgpt: []const u8,
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const codex_home = try resolveCodexHome(allocator);
    errdefer allocator.free(codex_home);

    const model = try resolveModel(allocator, codex_home);
    errdefer allocator.free(model);

    const base_urls = try resolveBaseUrls(allocator, codex_home);
    errdefer allocator.free(base_urls.openai);
    errdefer allocator.free(base_urls.chatgpt);

    const installation_id = try readOptionalFileTrimmed(allocator, codex_home, "installation_id", "unknown-zig-port");
    errdefer allocator.free(installation_id);

    const approval_policy = try resolveApprovalPolicy(allocator, codex_home);
    const sandbox_mode = try resolveSandboxMode(allocator, codex_home);

    return .{
        .codex_home = codex_home,
        .model = model,
        .openai_base_url = base_urls.openai,
        .chatgpt_base_url = base_urls.chatgpt,
        .installation_id = installation_id,
        .approval_policy = approval_policy,
        .sandbox_mode = sandbox_mode,
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

fn resolveModel(allocator: std.mem.Allocator, codex_home: []const u8) ![]const u8 {
    if (try env.getOwned(allocator, "CODEX_ZIG_MODEL")) |value| {
        return value;
    }

    if (try readTopLevelStringFromConfig(allocator, codex_home, "model")) |model| {
        return model;
    }

    return allocator.dupe(u8, "gpt-5.2-codex");
}

fn resolveBaseUrls(allocator: std.mem.Allocator, codex_home: []const u8) !BaseUrls {
    if (try env.getOwned(allocator, "CODEX_ZIG_BASE_URL")) |value| {
        errdefer allocator.free(value);
        return .{
            .openai = value,
            .chatgpt = try allocator.dupe(u8, value),
        };
    }

    const openai = if (try readTopLevelStringFromConfig(allocator, codex_home, "openai_base_url")) |value|
        value
    else
        try allocator.dupe(u8, "https://api.openai.com/v1");
    errdefer allocator.free(openai);

    const chatgpt = if (try readTopLevelStringFromConfig(allocator, codex_home, "chatgpt_base_url")) |value|
        value
    else
        try allocator.dupe(u8, "https://chatgpt.com/backend-api/codex");

    return .{ .openai = openai, .chatgpt = chatgpt };
}

fn resolveApprovalPolicy(allocator: std.mem.Allocator, codex_home: []const u8) !ApprovalPolicy {
    if (try env.getOwned(allocator, "CODEX_ZIG_APPROVAL_POLICY")) |value| {
        defer allocator.free(value);
        return ApprovalPolicy.parse(value);
    }

    if (try readTopLevelStringFromConfig(allocator, codex_home, "approval_policy")) |value| {
        defer allocator.free(value);
        return ApprovalPolicy.parse(value);
    }

    return .on_request;
}

fn resolveSandboxMode(allocator: std.mem.Allocator, codex_home: []const u8) !SandboxMode {
    if (try env.getOwned(allocator, "CODEX_ZIG_SANDBOX_MODE")) |value| {
        defer allocator.free(value);
        return SandboxMode.parse(value);
    }

    if (try readTopLevelStringFromConfig(allocator, codex_home, "sandbox_mode")) |value| {
        defer allocator.free(value);
        return SandboxMode.parse(value);
    }

    return .workspace_write;
}

fn readTopLevelStringFromConfig(allocator: std.mem.Allocator, codex_home: []const u8, key: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ codex_home, "config.toml" });
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 256)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;
        if (!std.mem.startsWith(u8, line, key)) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '"') {
            const end = std.mem.indexOfScalar(u8, rhs[1..], '"') orelse continue;
            return try allocator.dupe(u8, rhs[1 .. 1 + end]);
        }
    }
    return null;
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
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "config.toml", .data = "model = \"demo-model\" # trailing comment\n[other]\nmodel = \"ignored\"\n" });
    const cwd_path = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_path);
    const model = try readTopLevelStringFromConfig(allocator, cwd_path, "model");
    defer allocator.free(model.?);
    try std.testing.expectEqualStrings("demo-model", model.?);
}

test "approval and sandbox labels parse config strings" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "config.toml",
        .data =
        \\approval_policy = "never"
        \\sandbox_mode = "read-only"
        \\
        ,
    });
    const cwd_path = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(cwd_path);

    try std.testing.expectEqual(ApprovalPolicy.never, try resolveApprovalPolicy(allocator, cwd_path));
    try std.testing.expectEqual(SandboxMode.read_only, try resolveSandboxMode(allocator, cwd_path));
    try std.testing.expectEqualStrings("on-request", ApprovalPolicy.on_request.label());
    try std.testing.expectEqualStrings("danger-full-access", SandboxMode.danger_full_access.label());
}
