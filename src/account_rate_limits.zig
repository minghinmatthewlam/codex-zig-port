const std = @import("std");

const auth = @import("auth.zig");

const BackendRateLimitStatusPayload = struct {
    plan_type: []const u8 = "unknown",
    rate_limit: ?BackendRateLimitStatusDetails = null,
    additional_rate_limits: ?[]BackendAdditionalRateLimitDetails = null,
    credits: ?BackendCreditStatusDetails = null,
    rate_limit_reached_type: ?BackendRateLimitReachedDetails = null,
};

const BackendRateLimitStatusDetails = struct {
    primary_window: ?BackendRateLimitWindowSnapshot = null,
    secondary_window: ?BackendRateLimitWindowSnapshot = null,
};

const BackendRateLimitWindowSnapshot = struct {
    used_percent: i64 = 0,
    limit_window_seconds: i64 = 0,
    reset_at: i64 = 0,
};

const BackendCreditStatusDetails = struct {
    has_credits: bool = false,
    unlimited: bool = false,
    balance: ?[]const u8 = null,
};

const BackendRateLimitReachedDetails = struct {
    kind: []const u8 = "unknown",
};

const BackendAdditionalRateLimitDetails = struct {
    limit_name: []const u8,
    metered_feature: []const u8,
    rate_limit: ?BackendRateLimitStatusDetails = null,
};

pub fn fetchJson(allocator: std.mem.Allocator, base_url: []const u8, credentials: auth.Credentials) ![]const u8 {
    const url = try rateLimitsUrl(allocator, base_url);
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    const auth_header = try auth.authorizationHeader(allocator, credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.AppServerRateLimitsHttpStatus;
    }

    const bytes = try response_body.toOwnedSlice();
    defer allocator.free(bytes);
    return renderResponseJson(allocator, bytes);
}

fn rateLimitsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    const normalized = if ((std.mem.startsWith(u8, trimmed, "https://chatgpt.com") or
        std.mem.startsWith(u8, trimmed, "https://chat.openai.com")) and
        std.mem.indexOf(u8, trimmed, "/backend-api") == null)
        try std.fmt.allocPrint(allocator, "{s}/backend-api", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(normalized);

    const suffix = if (std.mem.indexOf(u8, normalized, "/backend-api") != null)
        "wham/usage"
    else
        "api/codex/usage";
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalized, suffix });
}

fn renderResponseJson(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(BackendRateLimitStatusPayload, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const payload = parsed.value;

    const primary = try renderSnapshotJson(
        allocator,
        "codex",
        null,
        payload.rate_limit,
        payload.credits,
        mapBackendPlanType(payload.plan_type),
        mapRateLimitReachedType(payload.rate_limit_reached_type),
    );
    defer allocator.free(primary);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"rateLimits\":");
    try result.appendSlice(allocator, primary);
    try result.appendSlice(allocator, ",\"rateLimitsByLimitId\":{");
    var first_limit = true;
    try appendJsonFieldName(allocator, &result, &first_limit, "codex");
    try result.appendSlice(allocator, primary);

    if (payload.additional_rate_limits) |limits| {
        for (limits) |limit| {
            const snapshot = try renderSnapshotJson(
                allocator,
                limit.metered_feature,
                limit.limit_name,
                limit.rate_limit,
                null,
                mapBackendPlanType(payload.plan_type),
                null,
            );
            defer allocator.free(snapshot);
            try appendJsonFieldName(allocator, &result, &first_limit, limit.metered_feature);
            try result.appendSlice(allocator, snapshot);
        }
    }

    try result.appendSlice(allocator, "}}");
    return result.toOwnedSlice(allocator);
}

fn renderSnapshotJson(
    allocator: std.mem.Allocator,
    limit_id: []const u8,
    limit_name: ?[]const u8,
    rate_limit: ?BackendRateLimitStatusDetails,
    credits: ?BackendCreditStatusDetails,
    plan_type: []const u8,
    reached_type: ?[]const u8,
) ![]const u8 {
    const limit_id_json = try std.json.Stringify.valueAlloc(allocator, limit_id, .{});
    defer allocator.free(limit_id_json);
    const limit_name_json = if (limit_name) |name|
        try std.json.Stringify.valueAlloc(allocator, name, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(limit_name_json);
    const primary_json = try renderWindowJson(allocator, if (rate_limit) |value| value.primary_window else null);
    defer allocator.free(primary_json);
    const secondary_json = try renderWindowJson(allocator, if (rate_limit) |value| value.secondary_window else null);
    defer allocator.free(secondary_json);
    const credits_json = try renderCreditsJson(allocator, credits);
    defer allocator.free(credits_json);
    const plan_type_json = try std.json.Stringify.valueAlloc(allocator, plan_type, .{});
    defer allocator.free(plan_type_json);
    const reached_type_json = if (reached_type) |value|
        try std.json.Stringify.valueAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(reached_type_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"limitId\":{s},\"limitName\":{s},\"primary\":{s},\"secondary\":{s},\"credits\":{s},\"planType\":{s},\"rateLimitReachedType\":{s}}}",
        .{ limit_id_json, limit_name_json, primary_json, secondary_json, credits_json, plan_type_json, reached_type_json },
    );
}

fn renderWindowJson(allocator: std.mem.Allocator, window: ?BackendRateLimitWindowSnapshot) ![]const u8 {
    const value = window orelse return allocator.dupe(u8, "null");
    const window_duration_mins: ?i64 = if (value.limit_window_seconds > 0)
        @divTrunc(value.limit_window_seconds + 59, 60)
    else
        null;
    const window_duration_json = if (window_duration_mins) |minutes|
        try std.fmt.allocPrint(allocator, "{d}", .{minutes})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(window_duration_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"usedPercent\":{d},\"windowDurationMins\":{s},\"resetsAt\":{d}}}",
        .{ value.used_percent, window_duration_json, value.reset_at },
    );
}

fn renderCreditsJson(allocator: std.mem.Allocator, credits: ?BackendCreditStatusDetails) ![]const u8 {
    const value = credits orelse return allocator.dupe(u8, "null");
    const balance_json = if (value.balance) |balance|
        try std.json.Stringify.valueAlloc(allocator, balance, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(balance_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"hasCredits\":{},\"unlimited\":{},\"balance\":{s}}}",
        .{ value.has_credits, value.unlimited, balance_json },
    );
}

fn appendJsonFieldName(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
) !void {
    if (first.*) {
        first.* = false;
    } else {
        try result.appendSlice(allocator, ",");
    }
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    try result.appendSlice(allocator, name_json);
    try result.appendSlice(allocator, ":");
}

fn mapBackendPlanType(plan_type: []const u8) []const u8 {
    if (std.mem.eql(u8, plan_type, "education")) return "edu";
    if (std.mem.eql(u8, plan_type, "guest") or
        std.mem.eql(u8, plan_type, "free_workspace") or
        std.mem.eql(u8, plan_type, "quorum") or
        std.mem.eql(u8, plan_type, "k12"))
    {
        return "unknown";
    }
    if (std.mem.eql(u8, plan_type, "free") or
        std.mem.eql(u8, plan_type, "go") or
        std.mem.eql(u8, plan_type, "plus") or
        std.mem.eql(u8, plan_type, "pro") or
        std.mem.eql(u8, plan_type, "prolite") or
        std.mem.eql(u8, plan_type, "team") or
        std.mem.eql(u8, plan_type, "self_serve_business_usage_based") or
        std.mem.eql(u8, plan_type, "business") or
        std.mem.eql(u8, plan_type, "enterprise_cbp_usage_based") or
        std.mem.eql(u8, plan_type, "enterprise") or
        std.mem.eql(u8, plan_type, "edu"))
    {
        return plan_type;
    }
    return "unknown";
}

fn mapRateLimitReachedType(value: ?BackendRateLimitReachedDetails) ?[]const u8 {
    const details = value orelse return null;
    if (std.mem.eql(u8, details.kind, "rate_limit_reached") or
        std.mem.eql(u8, details.kind, "workspace_owner_credits_depleted") or
        std.mem.eql(u8, details.kind, "workspace_member_credits_depleted") or
        std.mem.eql(u8, details.kind, "workspace_owner_usage_limit_reached") or
        std.mem.eql(u8, details.kind, "workspace_member_usage_limit_reached"))
    {
        return details.kind;
    }
    return null;
}
