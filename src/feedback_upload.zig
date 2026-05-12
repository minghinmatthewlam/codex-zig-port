const std = @import("std");

const env = @import("env.zig");
const feedback_diagnostics = @import("feedback_diagnostics.zig");

const DEFAULT_SENTRY_DSN =
    "https://ae32ed50620d7a7792c1ce5df38b3e3e@o33249.ingest.us.sentry.io/4510195390611458";
const TEST_SENTRY_DSN_ENV = "CODEX_TEST_FEEDBACK_SENTRY_DSN";
const USER_AGENT = "codex-zig-port/0.0.1";
const CLI_VERSION = "0.0.1";

pub const UploadRequest = struct {
    classification: []const u8,
    reason: ?[]const u8,
    thread_id: []const u8,
    include_logs: bool,
    log_bytes: []const u8 = "",
    extra_log_files: []const []const u8 = &.{},
    tags: ?*const std.json.ObjectMap = null,
    metadata_tags: []const Tag = &.{},
    session_source: ?[]const u8 = "cli",
};

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

const SentryDsn = struct {
    raw: []const u8,
    scheme: []const u8,
    public_key: []const u8,
    authority: []const u8,
    path_prefix: []const u8,
    project_id: []const u8,
};

pub fn upload(allocator: std.mem.Allocator, request: UploadRequest) !void {
    const owned_dsn = try env.getOwned(allocator, TEST_SENTRY_DSN_ENV);
    defer if (owned_dsn) |dsn| allocator.free(dsn);
    const dsn_text = owned_dsn orelse DEFAULT_SENTRY_DSN;

    const dsn = try parseSentryDsn(dsn_text);
    const url = try sentryEnvelopeUrl(allocator, dsn);
    defer allocator.free(url);
    const envelope = try buildEnvelope(allocator, dsn, request);
    defer allocator.free(envelope);
    try postEnvelope(allocator, url, envelope);
}

fn parseSentryDsn(dsn: []const u8) !SentryDsn {
    const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.InvalidFeedbackSentryDsn;
    const scheme = dsn[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http")) {
        return error.InvalidFeedbackSentryDsn;
    }

    const after_scheme = dsn[scheme_end + 3 ..];
    const at_index = std.mem.indexOfScalar(u8, after_scheme, '@') orelse return error.InvalidFeedbackSentryDsn;
    const key_part = after_scheme[0..at_index];
    const public_key_end = std.mem.indexOfScalar(u8, key_part, ':') orelse key_part.len;
    const public_key = key_part[0..public_key_end];
    if (public_key.len == 0) return error.InvalidFeedbackSentryDsn;

    const host_and_path = after_scheme[at_index + 1 ..];
    const slash_index = std.mem.indexOfScalar(u8, host_and_path, '/') orelse return error.InvalidFeedbackSentryDsn;
    const authority = host_and_path[0..slash_index];
    if (authority.len == 0) return error.InvalidFeedbackSentryDsn;

    const path = host_and_path[slash_index..];
    const project_start = (std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidFeedbackSentryDsn) + 1;
    const project_id = path[project_start..];
    if (project_id.len == 0) return error.InvalidFeedbackSentryDsn;
    const path_prefix = path[0 .. project_start - 1];

    return .{
        .raw = dsn,
        .scheme = scheme,
        .public_key = public_key,
        .authority = authority,
        .path_prefix = path_prefix,
        .project_id = project_id,
    };
}

fn sentryEnvelopeUrl(allocator: std.mem.Allocator, dsn: SentryDsn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}://{s}{s}/api/{s}/envelope/?sentry_key={s}&sentry_version=7&sentry_client=codex-zig-port%2F0.0.1",
        .{ dsn.scheme, dsn.authority, dsn.path_prefix, dsn.project_id, dsn.public_key },
    );
}

fn buildEnvelope(allocator: std.mem.Allocator, dsn: SentryDsn, request: UploadRequest) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"dsn\":");
    try appendJsonString(allocator, &out, dsn.raw);
    try out.appendSlice(allocator, "}\n{\"type\":\"event\"}\n");
    try appendEventJson(allocator, &out, request);
    try out.appendSlice(allocator, "\n");

    if (request.include_logs) {
        try appendAttachment(allocator, &out, "codex-logs.log", request.log_bytes);
        if (try feedback_diagnostics.attachmentTextFromEnv(allocator)) |diagnostics_text| {
            defer allocator.free(diagnostics_text);
            try appendAttachment(allocator, &out, feedback_diagnostics.attachment_filename, diagnostics_text);
        }
    }

    for (request.extra_log_files, 0..) |path, index| {
        if (stringAppearsBefore(request.extra_log_files, index, path)) continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            allocator,
            .unlimited,
        ) catch continue;
        defer allocator.free(bytes);
        try appendAttachment(allocator, &out, std.fs.path.basename(path), bytes);
    }

    return out.toOwnedSlice(allocator);
}

fn stringAppearsBefore(values: []const []const u8, end: usize, needle: []const u8) bool {
    for (values[0..end]) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn appendEventJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), request: UploadRequest) !void {
    const title = try std.fmt.allocPrint(
        allocator,
        "[{s}]: Codex session {s}",
        .{ displayClassification(request.classification), request.thread_id },
    );
    defer allocator.free(title);

    try out.appendSlice(allocator, "{\"level\":");
    try appendJsonString(allocator, out, levelForClassification(request.classification));
    try out.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, out, title);
    try out.appendSlice(allocator, ",\"tags\":{");
    try appendTagsJson(allocator, out, request);
    try out.appendSlice(allocator, "}");

    if (request.reason) |reason| {
        try out.appendSlice(allocator, ",\"exception\":{\"values\":[{\"type\":");
        try appendJsonString(allocator, out, title);
        try out.appendSlice(allocator, ",\"value\":");
        try appendJsonString(allocator, out, reason);
        try out.appendSlice(allocator, "}]}");
    }

    try out.appendSlice(allocator, "}");
}

fn appendTagsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), request: UploadRequest) !void {
    var first = true;
    try appendTag(allocator, out, &first, "thread_id", request.thread_id);
    try appendTag(allocator, out, &first, "classification", request.classification);
    try appendTag(allocator, out, &first, "cli_version", CLI_VERSION);
    if (request.session_source) |source| try appendTag(allocator, out, &first, "session_source", source);
    if (request.reason) |reason| try appendTag(allocator, out, &first, "reason", reason);

    if (request.tags) |tags| {
        var iter = tags.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (isReservedTag(key)) continue;
            if (entry.value_ptr.* != .string) continue;
            try appendTag(allocator, out, &first, key, entry.value_ptr.*.string);
        }
    }

    for (request.metadata_tags) |tag| {
        if (isReservedTag(tag.key)) continue;
        if (clientTagsContain(request.tags, tag.key)) continue;
        try appendTag(allocator, out, &first, tag.key, tag.value);
    }
}

fn clientTagsContain(tags: ?*const std.json.ObjectMap, key: []const u8) bool {
    const object = tags orelse return false;
    return object.get(key) != null;
}

fn appendTag(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try out.appendSlice(allocator, ",");
    first.* = false;
    try appendJsonString(allocator, out, key);
    try out.appendSlice(allocator, ":");
    try appendJsonString(allocator, out, value);
}

fn isReservedTag(key: []const u8) bool {
    return std.mem.eql(u8, key, "thread_id") or
        std.mem.eql(u8, key, "classification") or
        std.mem.eql(u8, key, "cli_version") or
        std.mem.eql(u8, key, "session_source") or
        std.mem.eql(u8, key, "reason");
}

fn appendAttachment(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    filename: []const u8,
    bytes: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"type\":\"attachment\",\"filename\":");
    try appendJsonString(allocator, out, filename);
    try out.appendSlice(allocator, ",\"content_type\":\"text/plain\",\"length\":");
    const length_text = try std.fmt.allocPrint(allocator, "{d}", .{bytes.len});
    defer allocator.free(length_text);
    try out.appendSlice(allocator, length_text);
    try out.appendSlice(allocator, "}\n");
    try out.appendSlice(allocator, bytes);
    try out.appendSlice(allocator, "\n");
}

fn postEnvelope(allocator: std.mem.Allocator, url: []const u8, envelope: []const u8) !void {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/x-sentry-envelope" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = USER_AGENT });

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = envelope,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.FeedbackUploadHttpStatus;
    }
}

fn displayClassification(classification: []const u8) []const u8 {
    if (std.mem.eql(u8, classification, "bug")) return "Bug";
    if (std.mem.eql(u8, classification, "bad_result")) return "Bad result";
    if (std.mem.eql(u8, classification, "good_result")) return "Good result";
    if (std.mem.eql(u8, classification, "safety_check")) return "Safety check";
    return "Other";
}

fn levelForClassification(classification: []const u8) []const u8 {
    if (std.mem.eql(u8, classification, "bug")) return "error";
    if (std.mem.eql(u8, classification, "bad_result")) return "error";
    if (std.mem.eql(u8, classification, "safety_check")) return "error";
    return "info";
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const value_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(value_json);
    try out.appendSlice(allocator, value_json);
}

test "sentry dsn maps to envelope endpoint" {
    const allocator = std.testing.allocator;
    const dsn = try parseSentryDsn("http://public:secret@127.0.0.1:8080/prefix/42");
    const url = try sentryEnvelopeUrl(allocator, dsn);
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/prefix/api/42/envelope/?sentry_key=public&sentry_version=7&sentry_client=codex-zig-port%2F0.0.1",
        url,
    );
}

test "envelope event preserves reserved tags and attachments" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"thread_id":"wrong","classification":"wrong","reason":"wrong","client_tag":"ok"}
    , .{});
    defer parsed.deinit();

    const dsn = try parseSentryDsn("http://public@localhost/42");
    const request = UploadRequest{
        .classification = "bug",
        .reason = "actual reason",
        .thread_id = "00000000-0000-4000-8000-000000000123",
        .include_logs = true,
        .log_bytes = "ring log",
        .tags = &parsed.value.object,
        .metadata_tags = &.{.{ .key = "account_id", .value = "acct_actual" }},
    };
    const envelope = try buildEnvelope(allocator, dsn, request);
    defer allocator.free(envelope);

    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"thread_id\":\"00000000-0000-4000-8000-000000000123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"classification\":\"bug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"reason\":\"actual reason\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"client_tag\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"account_id\":\"acct_actual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"filename\":\"codex-logs.log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "ring log") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"thread_id\":\"wrong\"") == null);
}

test "client tags take precedence over metadata tags" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"account_id":"acct_client"}
    , .{});
    defer parsed.deinit();

    const dsn = try parseSentryDsn("http://public@localhost/42");
    const request = UploadRequest{
        .classification = "bug",
        .reason = null,
        .thread_id = "00000000-0000-4000-8000-000000000123",
        .include_logs = false,
        .tags = &parsed.value.object,
        .metadata_tags = &.{.{ .key = "account_id", .value = "acct_metadata" }},
    };
    const envelope = try buildEnvelope(allocator, dsn, request);
    defer allocator.free(envelope);

    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"account_id\":\"acct_client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "acct_metadata") == null);
}

test "extra log files are de-duplicated by path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/feedback.log", .{&tmp.sub_path});
    defer allocator.free(log_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "feedback.log", .data = "extra" });

    const dsn = try parseSentryDsn("http://public@localhost/42");
    const request = UploadRequest{
        .classification = "bug",
        .reason = null,
        .thread_id = "00000000-0000-4000-8000-000000000123",
        .include_logs = false,
        .extra_log_files = &.{ log_path, log_path },
    };
    const envelope = try buildEnvelope(allocator, dsn, request);
    defer allocator.free(envelope);

    const first = std.mem.indexOf(u8, envelope, "\"filename\":\"feedback.log\"") orelse return error.MissingFeedbackAttachment;
    const rest = envelope[first + 1 ..];
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"filename\":\"feedback.log\"") == null);
}
