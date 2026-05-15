const std = @import("std");

const config = @import("config.zig");
const session_store = @import("session_store.zig");

const RemoteForkPayload = struct {
    protocolVersion: u64,
    threadId: []const u8,
    cwd: []const u8,
    rolloutFileName: []const u8,
    rolloutJsonl: []const u8,
};

const RemoteForkBundle = struct {
    thread_id: []const u8,
    cwd: []const u8,
    rollout_file_name: []const u8,
    rollout_jsonl: []const u8,

    fn deinit(self: *RemoteForkBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_id);
        allocator.free(self.cwd);
        allocator.free(self.rollout_file_name);
        allocator.free(self.rollout_jsonl);
    }
};

pub const Import = struct {
    thread_id: []const u8,
    imported_path: []const u8,

    pub fn deinit(self: *Import, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_id);
        allocator.free(self.imported_path);
    }
};

pub fn importRemoteFork(allocator: std.mem.Allocator, code: []const u8) !Import {
    const response_body = try fetchRemoteForkBundleBytes(allocator, code);
    defer allocator.free(response_body);

    var bundle = try parseRemoteForkBundle(allocator, response_body);
    defer bundle.deinit(allocator);

    const codex_home = try config.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    return importBundleToCodexHome(allocator, &bundle, codex_home);
}

fn fetchRemoteForkBundleBytes(allocator: std.mem.Allocator, code: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, code, "http://")) {
        return error.RemoteForkClaimUrlMustBeHttp;
    }

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-port/0.0.1" });

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = code },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.RemoteForkHttpStatus;
    }

    return response_body.toOwnedSlice();
}

fn parseRemoteForkBundle(allocator: std.mem.Allocator, bytes: []const u8) !RemoteForkBundle {
    var parsed = try std.json.parseFromSlice(RemoteForkPayload, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.protocolVersion != 1) {
        return error.UnsupportedRemoteForkProtocolVersion;
    }

    const thread_id = try allocator.dupe(u8, parsed.value.threadId);
    errdefer allocator.free(thread_id);
    const cwd = try allocator.dupe(u8, parsed.value.cwd);
    errdefer allocator.free(cwd);
    const rollout_file_name = try allocator.dupe(u8, parsed.value.rolloutFileName);
    errdefer allocator.free(rollout_file_name);
    const rollout_jsonl = try allocator.dupe(u8, parsed.value.rolloutJsonl);
    errdefer allocator.free(rollout_jsonl);

    return .{
        .thread_id = thread_id,
        .cwd = cwd,
        .rollout_file_name = rollout_file_name,
        .rollout_jsonl = rollout_jsonl,
    };
}

fn importBundleToCodexHome(
    allocator: std.mem.Allocator,
    bundle: *const RemoteForkBundle,
    codex_home: []const u8,
) !Import {
    if (!session_store.isUuidLike(bundle.thread_id)) {
        return error.InvalidRemoteForkThreadId;
    }
    try validateRolloutFileName(bundle.rollout_file_name, bundle.thread_id);

    const imports_dir = try std.fs.path.join(allocator, &.{ codex_home, "sessions", "remote-forks" });
    defer allocator.free(imports_dir);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, imports_dir);

    const imported_path = try std.fs.path.join(allocator, &.{ imports_dir, bundle.rollout_file_name });
    errdefer allocator.free(imported_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = imported_path, .data = bundle.rollout_jsonl });

    const thread_id = try allocator.dupe(u8, bundle.thread_id);
    errdefer allocator.free(thread_id);

    return .{
        .thread_id = thread_id,
        .imported_path = imported_path,
    };
}

fn validateRolloutFileName(file_name: []const u8, thread_id: []const u8) !void {
    if (std.mem.indexOfScalar(u8, file_name, '/') != null or
        std.mem.indexOfScalar(u8, file_name, '\\') != null)
    {
        return error.RemoteForkRolloutFileNameHasPathSeparator;
    }
    if (!std.mem.startsWith(u8, file_name, "rollout-") or
        !std.mem.endsWith(u8, file_name, ".jsonl"))
    {
        return error.RemoteForkRolloutFileNameInvalid;
    }

    const suffix_len = thread_id.len + ".jsonl".len;
    if (file_name.len < suffix_len) return error.RemoteForkRolloutFileNameThreadMismatch;
    const thread_start = file_name.len - suffix_len;
    const thread_end = file_name.len - ".jsonl".len;
    if (!std.mem.eql(u8, file_name[thread_start..thread_end], thread_id)) {
        return error.RemoteForkRolloutFileNameThreadMismatch;
    }
}

test "parse remote fork bundle validates protocol and fields" {
    const allocator = std.testing.allocator;
    const bytes =
        \\{"protocolVersion":1,"threadId":"00000000-0000-4000-8000-000000000456","cwd":"/tmp/codex","rolloutFileName":"rollout-2026-05-11T00-00-00-00000000-0000-4000-8000-000000000456.jsonl","rolloutJsonl":"rollout contents"}
    ;

    var bundle = try parseRemoteForkBundle(allocator, bytes);
    defer bundle.deinit(allocator);

    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000456", bundle.thread_id);
    try std.testing.expectEqualStrings("/tmp/codex", bundle.cwd);
    try std.testing.expectEqualStrings(
        "rollout-2026-05-11T00-00-00-00000000-0000-4000-8000-000000000456.jsonl",
        bundle.rollout_file_name,
    );
    try std.testing.expectEqualStrings("rollout contents", bundle.rollout_jsonl);
}

test "parse remote fork bundle rejects unsupported protocol" {
    const allocator = std.testing.allocator;
    const bytes =
        \\{"protocolVersion":2,"threadId":"00000000-0000-4000-8000-000000000456","cwd":"/tmp/codex","rolloutFileName":"rollout-2026-05-11T00-00-00-00000000-0000-4000-8000-000000000456.jsonl","rolloutJsonl":"rollout contents"}
    ;

    try std.testing.expectError(error.UnsupportedRemoteForkProtocolVersion, parseRemoteForkBundle(allocator, bytes));
}

test "import bundle writes rollout under remote forks" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const thread_id = "00000000-0000-4000-8000-000000000456";
    const bundle = RemoteForkBundle{
        .thread_id = thread_id,
        .cwd = "/tmp/codex",
        .rollout_file_name = "rollout-2026-05-11T00-00-00-00000000-0000-4000-8000-000000000456.jsonl",
        .rollout_jsonl = "rollout contents",
    };

    var imported = try importBundleToCodexHome(allocator, &bundle, codex_home);
    defer imported.deinit(allocator);

    try std.testing.expectEqualStrings(thread_id, imported.thread_id);
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        imported.imported_path,
        allocator,
        .limited(1024),
    );
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("rollout contents", contents);
}

test "import bundle rejects path traversal file name" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const codex_home = try dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(codex_home);

    const bundle = RemoteForkBundle{
        .thread_id = "00000000-0000-4000-8000-000000000456",
        .cwd = "/tmp/codex",
        .rollout_file_name = "../rollout-2026-05-11T00-00-00-00000000-0000-4000-8000-000000000456.jsonl",
        .rollout_jsonl = "rollout contents",
    };

    try std.testing.expectError(
        error.RemoteForkRolloutFileNameHasPathSeparator,
        importBundleToCodexHome(allocator, &bundle, codex_home),
    );
}
