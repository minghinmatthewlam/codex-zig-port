const std = @import("std");

const auth = @import("auth.zig");

const seconds_per_day = 24 * 60 * 60;

const TokenUsageProfile = struct {
    stats: TokenUsageProfileStats,
};

const TokenUsageProfileStats = struct {
    lifetime_tokens: ?i64 = null,
    peak_daily_tokens: ?i64 = null,
    longest_running_turn_sec: ?i64 = null,
    current_streak_days: ?i64 = null,
    longest_streak_days: ?i64 = null,
    daily_usage_buckets: ?[]TokenUsageProfileDailyBucket = null,
};

const TokenUsageProfileDailyBucket = struct {
    start_date: []const u8,
    tokens: i64,
};

const BackendWorkspaceMessagesResponse = struct {
    messages: ?[]BackendWorkspaceMessage = null,
};

const BackendWorkspaceMessage = struct {
    message_id: []const u8,
    message_type: []const u8,
    message_body: []const u8,
    created_at: ?[]const u8 = null,
    archived_at: ?[]const u8 = null,
};

const ConsumeRateLimitResetCreditResponse = struct {
    code: []const u8,
};

const HttpFetchResult = struct {
    status: std.http.Status,
    body: []const u8,

    fn deinit(self: HttpFetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn fetchTokenUsageJson(allocator: std.mem.Allocator, base_url: []const u8, credentials: auth.Credentials) ![]const u8 {
    const url = try backendUrl(allocator, base_url, "api/codex/profiles/me", "wham/profiles/me");
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    try appendBackendHeaders(allocator, &headers, credentials, &auth_header);

    const response = try fetchBackend(allocator, url, .GET, headers.items, null);
    defer response.deinit(allocator);
    if (!isSuccess(response.status)) return error.AppServerAccountUsageHttpStatus;

    return renderTokenUsageJson(allocator, response.body);
}

pub fn fetchWorkspaceMessagesJson(allocator: std.mem.Allocator, base_url: []const u8, credentials: auth.Credentials) ![]const u8 {
    const url = try backendUrl(allocator, base_url, "api/codex/workspace-messages", "wham/workspace-messages");
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    try appendBackendHeaders(allocator, &headers, credentials, &auth_header);
    try headers.append(allocator, .{ .name = "Cache-Control", .value = "no-store" });

    const response = try fetchBackend(allocator, url, .GET, headers.items, null);
    defer response.deinit(allocator);
    if (response.status == .not_found) return allocator.dupe(u8, "{\"featureEnabled\":false,\"messages\":[]}");
    if (!isSuccess(response.status)) return error.AppServerWorkspaceMessagesHttpStatus;

    return renderWorkspaceMessagesJson(allocator, response.body, true);
}

pub fn consumeRateLimitResetCreditJson(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    credentials: auth.Credentials,
    idempotency_key: []const u8,
    credit_id: ?[]const u8,
) ![]const u8 {
    const url = try backendUrl(
        allocator,
        base_url,
        "api/codex/rate-limit-reset-credits/consume",
        "wham/rate-limit-reset-credits/consume",
    );
    defer allocator.free(url);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    try appendBackendHeaders(allocator, &headers, credentials, &auth_header);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });

    const idempotency_json = try std.json.Stringify.valueAlloc(allocator, idempotency_key, .{});
    defer allocator.free(idempotency_json);
    const body = if (credit_id) |id| blk: {
        const credit_id_json = try std.json.Stringify.valueAlloc(allocator, id, .{});
        defer allocator.free(credit_id_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"redeem_request_id\":{s},\"credit_id\":{s}}}",
            .{ idempotency_json, credit_id_json },
        );
    } else try std.fmt.allocPrint(allocator, "{{\"redeem_request_id\":{s}}}", .{idempotency_json});
    defer allocator.free(body);

    const response = try fetchBackend(allocator, url, .POST, headers.items, body);
    defer response.deinit(allocator);
    if (!isSuccess(response.status)) return error.AppServerRateLimitResetConsumeHttpStatus;

    var parsed = try std.json.parseFromSlice(ConsumeRateLimitResetCreditResponse, allocator, response.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const outcome = mapResetCreditOutcome(parsed.value.code) orelse return error.InvalidAccountRateLimitResetOutcome;
    return std.fmt.allocPrint(allocator, "{{\"outcome\":\"{s}\"}}", .{outcome});
}

fn fetchBackend(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    headers: []const std.http.Header,
    payload: ?[]const u8,
) !HttpFetchResult {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &response_body.writer,
        .extra_headers = headers,
    });

    return .{
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
    };
}

fn appendBackendHeaders(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(std.http.Header),
    credentials: auth.Credentials,
    auth_header: *?[]const u8,
) !void {
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });
    if (credentials.mode == .agent_identity) {
        auth_header.* = try auth.authorizationHeader(allocator, credentials);
        try headers.append(allocator, .{ .name = "Authorization", .value = auth_header.*.? });
    }
    if (credentials.account_id) |account_id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_id });
    }
    if (credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }
}

fn backendUrl(allocator: std.mem.Allocator, base_url: []const u8, codex_path: []const u8, chatgpt_path: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    const normalized = if ((std.mem.startsWith(u8, trimmed, "https://chatgpt.com") or
        std.mem.startsWith(u8, trimmed, "https://chat.openai.com")) and
        std.mem.indexOf(u8, trimmed, "/backend-api") == null)
        try std.fmt.allocPrint(allocator, "{s}/backend-api", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(normalized);

    const suffix = if (std.mem.indexOf(u8, normalized, "/backend-api") != null) chatgpt_path else codex_path;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalized, suffix });
}

fn isSuccess(status: std.http.Status) bool {
    const code = @intFromEnum(status);
    return code >= 200 and code < 300;
}

fn renderTokenUsageJson(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(TokenUsageProfile, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const stats = parsed.value.stats;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"summary\":{");
    var first_summary = true;
    try appendNullableIntField(allocator, &result, &first_summary, "lifetimeTokens", stats.lifetime_tokens);
    try appendNullableIntField(allocator, &result, &first_summary, "peakDailyTokens", stats.peak_daily_tokens);
    try appendNullableIntField(allocator, &result, &first_summary, "longestRunningTurnSec", stats.longest_running_turn_sec);
    try appendNullableIntField(allocator, &result, &first_summary, "currentStreakDays", stats.current_streak_days);
    try appendNullableIntField(allocator, &result, &first_summary, "longestStreakDays", stats.longest_streak_days);
    try result.appendSlice(allocator, "},\"dailyUsageBuckets\":");
    if (stats.daily_usage_buckets) |buckets| {
        try result.appendSlice(allocator, "[");
        for (buckets, 0..) |bucket, index| {
            if (index != 0) try result.appendSlice(allocator, ",");
            const start_date_json = try std.json.Stringify.valueAlloc(allocator, bucket.start_date, .{});
            defer allocator.free(start_date_json);
            try result.print(allocator, "{{\"startDate\":{s},\"tokens\":{d}}}", .{ start_date_json, bucket.tokens });
        }
        try result.appendSlice(allocator, "]");
    } else {
        try result.appendSlice(allocator, "null");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn renderWorkspaceMessagesJson(allocator: std.mem.Allocator, body: []const u8, feature_enabled: bool) ![]const u8 {
    var parsed = try std.json.parseFromSlice(BackendWorkspaceMessagesResponse, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.print(allocator, "{{\"featureEnabled\":{},\"messages\":[", .{feature_enabled});
    const messages = parsed.value.messages orelse &.{};
    for (messages, 0..) |message, index| {
        if (index != 0) try result.appendSlice(allocator, ",");
        const message_id_json = try std.json.Stringify.valueAlloc(allocator, message.message_id, .{});
        defer allocator.free(message_id_json);
        const message_type_json = try std.json.Stringify.valueAlloc(allocator, mapWorkspaceMessageType(message.message_type), .{});
        defer allocator.free(message_type_json);
        const message_body_json = try std.json.Stringify.valueAlloc(allocator, message.message_body, .{});
        defer allocator.free(message_body_json);
        const created_at_json = try renderOptionalTimestamp(allocator, message.created_at);
        defer allocator.free(created_at_json);
        const archived_at_json = try renderOptionalTimestamp(allocator, message.archived_at);
        defer allocator.free(archived_at_json);
        try result.print(
            allocator,
            "{{\"messageId\":{s},\"messageType\":{s},\"messageBody\":{s},\"createdAt\":{s},\"archivedAt\":{s}}}",
            .{ message_id_json, message_type_json, message_body_json, created_at_json, archived_at_json },
        );
    }
    try result.appendSlice(allocator, "]}");
    return result.toOwnedSlice(allocator);
}

fn renderOptionalTimestamp(allocator: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    const timestamp = value orelse return allocator.dupe(u8, "null");
    const seconds = try parseRfc3339EpochSeconds(timestamp);
    return std.fmt.allocPrint(allocator, "{d}", .{seconds});
}

fn appendNullableIntField(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: ?i64,
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
    if (value) |number| {
        try result.print(allocator, "{d}", .{number});
    } else {
        try result.appendSlice(allocator, "null");
    }
}

fn mapWorkspaceMessageType(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "headline")) return "headline";
    if (std.mem.eql(u8, value, "announcement")) return "announcement";
    return "unknown";
}

fn mapResetCreditOutcome(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "reset")) return "reset";
    if (std.mem.eql(u8, value, "nothing_to_reset")) return "nothingToReset";
    if (std.mem.eql(u8, value, "no_credit")) return "noCredit";
    if (std.mem.eql(u8, value, "already_redeemed")) return "alreadyRedeemed";
    return null;
}

fn parseRfc3339EpochSeconds(value: []const u8) !i64 {
    if (value.len < "YYYY-MM-DDTHH:MM:SSZ".len) return error.InvalidRfc3339;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') {
        return error.InvalidRfc3339;
    }

    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);

    var end_index: usize = 19;
    if (end_index < value.len and value[end_index] == '.') {
        end_index += 1;
        const fraction_start = end_index;
        while (end_index < value.len and std.ascii.isDigit(value[end_index])) end_index += 1;
        if (end_index == fraction_start) return error.InvalidRfc3339;
    }

    var offset_seconds: i64 = 0;
    if (end_index < value.len and value[end_index] == 'Z' and end_index + 1 == value.len) {
        offset_seconds = 0;
    } else if (end_index + 6 == value.len and (value[end_index] == '+' or value[end_index] == '-')) {
        if (value[end_index + 3] != ':') return error.InvalidRfc3339;
        const offset_hours = try std.fmt.parseInt(i64, value[end_index + 1 .. end_index + 3], 10);
        const offset_minutes = try std.fmt.parseInt(i64, value[end_index + 4 .. end_index + 6], 10);
        if (offset_hours > 23 or offset_minutes > 59) return error.InvalidRfc3339;
        offset_seconds = offset_hours * 60 * 60 + offset_minutes * 60;
        if (value[end_index] == '-') offset_seconds = -offset_seconds;
    } else {
        return error.InvalidRfc3339;
    }

    const local_seconds = epochSecondsFromDate(year, month, day, hour, minute, second) orelse return error.InvalidRfc3339;
    return local_seconds - offset_seconds;
}

fn epochSecondsFromDate(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < std.time.epoch.epoch_year or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) {
        return null;
    }

    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month = std.time.epoch.getDaysInMonth(year, month_enum);
    if (day < 1 or day > days_in_month) return null;

    var days: i64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }

    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;

    return days * seconds_per_day + @as(i64, hour) * 60 * 60 + @as(i64, minute) * 60 + second;
}

test "account usage backend urls follow path style" {
    const allocator = std.testing.allocator;

    const codex_url = try backendUrl(allocator, "https://example.test/", "api/codex/profiles/me", "wham/profiles/me");
    defer allocator.free(codex_url);
    try std.testing.expectEqualStrings("https://example.test/api/codex/profiles/me", codex_url);

    const chatgpt_url = try backendUrl(allocator, "https://chatgpt.com/backend-api", "api/codex/profiles/me", "wham/profiles/me");
    defer allocator.free(chatgpt_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/wham/profiles/me", chatgpt_url);
}

test "account usage response maps stats to protocol shape" {
    const allocator = std.testing.allocator;
    const rendered = try renderTokenUsageJson(
        allocator,
        "{\"stats\":{\"lifetime_tokens\":12,\"peak_daily_tokens\":7,\"longest_running_turn_sec\":3,\"current_streak_days\":2,\"longest_streak_days\":5,\"daily_usage_buckets\":[{\"start_date\":\"2026-07-20\",\"tokens\":42}]}}",
    );
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"summary\":{\"lifetimeTokens\":12,\"peakDailyTokens\":7,\"longestRunningTurnSec\":3,\"currentStreakDays\":2,\"longestStreakDays\":5},\"dailyUsageBuckets\":[{\"startDate\":\"2026-07-20\",\"tokens\":42}]}",
        rendered,
    );
}

test "workspace messages map timestamps and unknown types" {
    const allocator = std.testing.allocator;
    const rendered = try renderWorkspaceMessagesJson(
        allocator,
        "{\"messages\":[{\"message_id\":\"m1\",\"message_type\":\"future\",\"message_body\":\"Body\",\"created_at\":\"2026-07-20T01:02:03Z\",\"archived_at\":\"2026-07-21T06:05:06+02:00\"}]}",
        true,
    );
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"featureEnabled\":true,\"messages\":[{\"messageId\":\"m1\",\"messageType\":\"unknown\",\"messageBody\":\"Body\",\"createdAt\":1784509323,\"archivedAt\":1784606706}]}",
        rendered,
    );
}
