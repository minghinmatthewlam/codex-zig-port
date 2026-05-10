const std = @import("std");

const STATE_FILE_NAME = "state.json";

const ThreadMetadata = struct {
    agent_path: ?[]const u8 = null,
    nickname: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    spawn: ?SpawnMetadata = null,
};

const SpawnMetadata = struct {
    parent_thread_id: []const u8,
    agent_path: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    agent_role: ?[]const u8 = null,
};

const Reducer = struct {
    allocator: std.mem.Allocator,
    bundle_dir: []const u8,
    trace_id: []const u8,
    rollout_id: []const u8,
    root_thread_id: []const u8,
    started_at_unix_ms: i64,
    ended_at_unix_ms: ?i64 = null,
    status: []const u8 = "running",
    threads: std.json.ObjectMap = .{},
    codex_turns: std.json.ObjectMap = .{},
    inference_calls: std.json.ObjectMap = .{},
    raw_payloads: std.json.ObjectMap = .{},

    fn init(
        allocator: std.mem.Allocator,
        bundle_dir: []const u8,
        manifest: std.json.ObjectMap,
    ) !Reducer {
        return .{
            .allocator = allocator,
            .bundle_dir = try allocator.dupe(u8, bundle_dir),
            .trace_id = try allocator.dupe(u8, try stringField(manifest, "trace_id")),
            .rollout_id = try allocator.dupe(u8, try stringField(manifest, "rollout_id")),
            .root_thread_id = try allocator.dupe(u8, try stringField(manifest, "root_thread_id")),
            .started_at_unix_ms = try integerField(manifest, "started_at_unix_ms"),
        };
    }

    fn applyEvent(self: *Reducer, event: std.json.ObjectMap) !void {
        const seq_i64 = try integerField(event, "seq");
        const seq: u64 = @intCast(seq_i64);
        const wall_time_unix_ms = try integerField(event, "wall_time_unix_ms");
        const payload = try objectField(event, "payload");
        try self.collectRawPayloadRefs(.{ .object = payload });

        const event_type = try stringField(payload, "type");
        if (std.mem.eql(u8, event_type, "rollout_started")) {
            if (stringField(payload, "trace_id")) |trace_id| {
                self.trace_id = try self.allocator.dupe(u8, trace_id);
            } else |_| {}
            if (stringField(payload, "root_thread_id")) |thread_id| {
                self.root_thread_id = try self.allocator.dupe(u8, thread_id);
            } else |_| {}
            return;
        }
        if (std.mem.eql(u8, event_type, "rollout_ended")) {
            self.status = try self.allocator.dupe(u8, try statusString(payload, "status"));
            self.ended_at_unix_ms = wall_time_unix_ms;
            return;
        }
        if (std.mem.eql(u8, event_type, "thread_started")) {
            try self.startThread(seq, wall_time_unix_ms, payload);
            return;
        }
        if (std.mem.eql(u8, event_type, "thread_ended")) {
            try self.endThread(seq, wall_time_unix_ms, payload);
            return;
        }
        if (std.mem.eql(u8, event_type, "codex_turn_started")) {
            try self.startCodexTurn(seq, wall_time_unix_ms, payload);
            return;
        }
        if (std.mem.eql(u8, event_type, "codex_turn_ended")) {
            try self.endCodexTurn(seq, wall_time_unix_ms, payload);
            return;
        }
        if (std.mem.eql(u8, event_type, "inference_started")) {
            try self.startInference(seq, wall_time_unix_ms, payload);
            return;
        }
        if (std.mem.eql(u8, event_type, "inference_completed")) {
            try self.completeInference(seq, wall_time_unix_ms, payload, "completed");
            return;
        }
        if (std.mem.eql(u8, event_type, "inference_failed")) {
            try self.completeInference(seq, wall_time_unix_ms, payload, "failed");
            return;
        }
        if (std.mem.eql(u8, event_type, "inference_cancelled")) {
            try self.completeInference(seq, wall_time_unix_ms, payload, "cancelled");
            return;
        }
    }

    fn startThread(self: *Reducer, seq: u64, wall_time_unix_ms: i64, payload: std.json.ObjectMap) !void {
        const thread_id = try stringField(payload, "thread_id");
        var agent_path = try stringField(payload, "agent_path");
        var nickname: ?[]const u8 = null;
        var default_model: ?[]const u8 = null;
        var spawn: ?SpawnMetadata = null;

        if (payload.get("metadata_payload")) |metadata_value| {
            if (metadata_value == .object) {
                const metadata = try self.readThreadMetadata(metadata_value.object);
                if (metadata.agent_path) |value| agent_path = value;
                if (metadata.nickname) |value| nickname = value;
                if (metadata.default_model) |value| default_model = value;
                if (metadata.spawn) |value| {
                    spawn = value;
                    if (value.agent_path) |spawn_path| agent_path = spawn_path;
                }
            }
        }

        var object: std.json.ObjectMap = .{};
        try putString(self.allocator, &object, "thread_id", thread_id);
        try putString(self.allocator, &object, "agent_path", agent_path);
        try putOptionalString(self.allocator, &object, "nickname", nickname);
        try object.put(self.allocator, "origin", try self.threadOrigin(thread_id, agent_path, spawn));
        try object.put(self.allocator, "execution", try executionWindow(self.allocator, wall_time_unix_ms, seq, null, null, "running"));
        try putOptionalString(self.allocator, &object, "default_model", default_model);
        try object.put(self.allocator, "conversation_item_ids", emptyArray(self.allocator));

        try self.threads.put(self.allocator, try self.allocator.dupe(u8, thread_id), .{ .object = object });
    }

    fn endThread(self: *Reducer, seq: u64, wall_time_unix_ms: i64, payload: std.json.ObjectMap) !void {
        const thread_id = try stringField(payload, "thread_id");
        const status = rolloutStatusToExecution(try statusString(payload, "status"));
        const thread = self.threads.getPtr(thread_id) orelse return error.UnknownTraceThread;
        const object = objectValuePtr(thread) orelse return error.InvalidTraceThread;
        const execution = object.getPtr("execution") orelse return error.InvalidTraceThread;
        const execution_object = objectValuePtr(execution) orelse return error.InvalidTraceThread;
        try execution_object.put(self.allocator, "ended_at_unix_ms", .{ .integer = wall_time_unix_ms });
        try execution_object.put(self.allocator, "ended_seq", .{ .integer = @intCast(seq) });
        try putString(self.allocator, execution_object, "status", status);
    }

    fn startCodexTurn(self: *Reducer, seq: u64, wall_time_unix_ms: i64, payload: std.json.ObjectMap) !void {
        const turn_id = try stringField(payload, "codex_turn_id");
        const thread_id = try stringField(payload, "thread_id");

        var object: std.json.ObjectMap = .{};
        try putString(self.allocator, &object, "codex_turn_id", turn_id);
        try putString(self.allocator, &object, "thread_id", thread_id);
        try object.put(self.allocator, "execution", try executionWindow(self.allocator, wall_time_unix_ms, seq, null, null, "running"));
        try object.put(self.allocator, "input_item_ids", emptyArray(self.allocator));
        try self.codex_turns.put(self.allocator, try self.allocator.dupe(u8, turn_id), .{ .object = object });
    }

    fn endCodexTurn(self: *Reducer, seq: u64, wall_time_unix_ms: i64, payload: std.json.ObjectMap) !void {
        const turn_id = try stringField(payload, "codex_turn_id");
        const status = try statusString(payload, "status");
        const turn = self.codex_turns.getPtr(turn_id) orelse return error.UnknownTraceTurn;
        const object = objectValuePtr(turn) orelse return error.InvalidTraceTurn;
        const execution = object.getPtr("execution") orelse return error.InvalidTraceTurn;
        const execution_object = objectValuePtr(execution) orelse return error.InvalidTraceTurn;
        try execution_object.put(self.allocator, "ended_at_unix_ms", .{ .integer = wall_time_unix_ms });
        try execution_object.put(self.allocator, "ended_seq", .{ .integer = @intCast(seq) });
        try putString(self.allocator, execution_object, "status", status);
    }

    fn startInference(self: *Reducer, seq: u64, wall_time_unix_ms: i64, payload: std.json.ObjectMap) !void {
        const inference_id = try stringField(payload, "inference_call_id");
        const thread_id = try stringField(payload, "thread_id");
        const turn_id = try stringField(payload, "codex_turn_id");
        const request_payload = try objectField(payload, "request_payload");

        var object: std.json.ObjectMap = .{};
        try putString(self.allocator, &object, "inference_call_id", inference_id);
        try putString(self.allocator, &object, "thread_id", thread_id);
        try putString(self.allocator, &object, "codex_turn_id", turn_id);
        try object.put(self.allocator, "execution", try executionWindow(self.allocator, wall_time_unix_ms, seq, null, null, "running"));
        try putString(self.allocator, &object, "model", try stringField(payload, "model"));
        try putString(self.allocator, &object, "provider_name", try stringField(payload, "provider_name"));
        try object.put(self.allocator, "response_id", .null);
        try object.put(self.allocator, "upstream_request_id", .null);
        try object.put(self.allocator, "request_item_ids", emptyArray(self.allocator));
        try object.put(self.allocator, "response_item_ids", emptyArray(self.allocator));
        try object.put(self.allocator, "tool_call_ids_started_by_response", emptyArray(self.allocator));
        try object.put(self.allocator, "usage", .null);
        try putString(self.allocator, &object, "raw_request_payload_id", try stringField(request_payload, "raw_payload_id"));
        try object.put(self.allocator, "raw_response_payload_id", .null);

        try self.inference_calls.put(self.allocator, try self.allocator.dupe(u8, inference_id), .{ .object = object });
    }

    fn completeInference(
        self: *Reducer,
        seq: u64,
        wall_time_unix_ms: i64,
        payload: std.json.ObjectMap,
        status: []const u8,
    ) !void {
        const inference_id = try stringField(payload, "inference_call_id");
        const inference = self.inference_calls.getPtr(inference_id) orelse return error.UnknownTraceInference;
        const object = objectValuePtr(inference) orelse return error.InvalidTraceInference;
        const execution = object.getPtr("execution") orelse return error.InvalidTraceInference;
        const execution_object = objectValuePtr(execution) orelse return error.InvalidTraceInference;
        try execution_object.put(self.allocator, "ended_at_unix_ms", .{ .integer = wall_time_unix_ms });
        try execution_object.put(self.allocator, "ended_seq", .{ .integer = @intCast(seq) });
        try putString(self.allocator, execution_object, "status", status);
        if (optionalStringField(payload, "response_id")) |response_id| {
            try putString(self.allocator, object, "response_id", response_id);
        }
        if (optionalStringField(payload, "upstream_request_id")) |request_id| {
            try putString(self.allocator, object, "upstream_request_id", request_id);
        }
        if (payload.get("response_payload")) |response_payload| {
            if (response_payload == .object) {
                try putString(self.allocator, object, "raw_response_payload_id", try stringField(response_payload.object, "raw_payload_id"));
            }
        } else if (payload.get("partial_response_payload")) |partial_response_payload| {
            if (partial_response_payload == .object) {
                try putString(self.allocator, object, "raw_response_payload_id", try stringField(partial_response_payload.object, "raw_payload_id"));
            }
        }
    }

    fn threadOrigin(
        self: *Reducer,
        thread_id: []const u8,
        agent_path: []const u8,
        spawn: ?SpawnMetadata,
    ) !std.json.Value {
        var object: std.json.ObjectMap = .{};
        if (spawn) |value| {
            const task_name = value.task_name orelse taskNameFromAgentPath(agent_path);
            const agent_role = value.agent_role orelse "";
            try putString(self.allocator, &object, "type", "spawned");
            try putString(self.allocator, &object, "parent_thread_id", value.parent_thread_id);
            const edge_id = try std.fmt.allocPrint(self.allocator, "edge:spawn:{s}:{s}", .{ value.parent_thread_id, thread_id });
            try object.put(self.allocator, "spawn_edge_id", .{ .string = edge_id });
            try putString(self.allocator, &object, "task_name", task_name);
            try putString(self.allocator, &object, "agent_role", agent_role);
        } else {
            try putString(self.allocator, &object, "type", "root");
        }
        return .{ .object = object };
    }

    fn readThreadMetadata(self: *Reducer, raw_payload_ref: std.json.ObjectMap) !ThreadMetadata {
        const payload_path = try self.payloadPath(try stringField(raw_payload_ref, "path"));
        defer self.allocator.free(payload_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            payload_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return .{};
        const object = parsed.value.object;
        var metadata = ThreadMetadata{
            .agent_path = try dupeOptional(self.allocator, optionalStringField(object, "agent_path")),
            .nickname = try dupeOptional(self.allocator, optionalStringField(object, "nickname")),
            .default_model = try dupeOptional(self.allocator, optionalStringField(object, "model")),
        };
        if (threadSpawnObject(object)) |spawn_object| {
            const parent_thread_id = optionalStringField(spawn_object, "parent_thread_id") orelse return metadata;
            metadata.spawn = .{
                .parent_thread_id = try self.allocator.dupe(u8, parent_thread_id),
                .agent_path = try dupeOptional(self.allocator, optionalStringField(spawn_object, "agent_path") orelse metadata.agent_path),
                .task_name = try dupeOptional(self.allocator, optionalStringField(spawn_object, "task_name") orelse optionalStringField(object, "task_name")),
                .agent_role = try dupeOptional(self.allocator, optionalStringField(spawn_object, "agent_role") orelse optionalStringField(object, "agent_role")),
            };
        }
        return metadata;
    }

    fn payloadPath(self: *Reducer, relative_path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(relative_path)) return error.UnsafeTracePayloadPath;
        var components = std.mem.splitScalar(u8, relative_path, '/');
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return error.UnsafeTracePayloadPath;
        }
        return std.fs.path.join(self.allocator, &.{ self.bundle_dir, relative_path });
    }

    fn collectRawPayloadRefs(self: *Reducer, value: std.json.Value) !void {
        switch (value) {
            .object => |object| {
                if (isRawPayloadRef(object)) {
                    try self.addRawPayloadRef(object);
                }
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    try self.collectRawPayloadRefs(entry.value_ptr.*);
                }
            },
            .array => |array| {
                for (array.items) |item| {
                    try self.collectRawPayloadRefs(item);
                }
            },
            else => {},
        }
    }

    fn addRawPayloadRef(self: *Reducer, raw_payload_ref: std.json.ObjectMap) !void {
        const raw_payload_id = try stringField(raw_payload_ref, "raw_payload_id");
        if (self.raw_payloads.get(raw_payload_id) != null) return;

        var object: std.json.ObjectMap = .{};
        try putString(self.allocator, &object, "raw_payload_id", raw_payload_id);
        try object.put(self.allocator, "kind", try cloneKindValue(self.allocator, raw_payload_ref.get("kind") orelse return error.InvalidRawPayloadRef));
        try putString(self.allocator, &object, "path", try stringField(raw_payload_ref, "path"));
        try self.raw_payloads.put(self.allocator, try self.allocator.dupe(u8, raw_payload_id), .{ .object = object });
    }

    fn render(self: *Reducer, output_allocator: std.mem.Allocator) ![]const u8 {
        var root: std.json.ObjectMap = .{};
        try root.put(self.allocator, "schema_version", .{ .integer = 1 });
        try putString(self.allocator, &root, "trace_id", self.trace_id);
        try putString(self.allocator, &root, "rollout_id", self.rollout_id);
        try root.put(self.allocator, "started_at_unix_ms", .{ .integer = self.started_at_unix_ms });
        if (self.ended_at_unix_ms) |ended_at| {
            try root.put(self.allocator, "ended_at_unix_ms", .{ .integer = ended_at });
        } else {
            try root.put(self.allocator, "ended_at_unix_ms", .null);
        }
        try putString(self.allocator, &root, "status", self.status);
        try putString(self.allocator, &root, "root_thread_id", self.root_thread_id);
        try root.put(self.allocator, "threads", .{ .object = self.threads });
        try root.put(self.allocator, "codex_turns", .{ .object = self.codex_turns });
        try root.put(self.allocator, "conversation_items", emptyObject());
        try root.put(self.allocator, "inference_calls", .{ .object = self.inference_calls });
        try root.put(self.allocator, "code_cells", emptyObject());
        try root.put(self.allocator, "tool_calls", emptyObject());
        try root.put(self.allocator, "terminal_sessions", emptyObject());
        try root.put(self.allocator, "terminal_operations", emptyObject());
        try root.put(self.allocator, "compactions", emptyObject());
        try root.put(self.allocator, "compaction_requests", emptyObject());
        try root.put(self.allocator, "interaction_edges", emptyObject());
        try root.put(self.allocator, "raw_payloads", .{ .object = self.raw_payloads });
        return std.json.Stringify.valueAlloc(output_allocator, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    }
};

pub fn reduceBundle(allocator: std.mem.Allocator, bundle_dir: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const manifest_path = try std.fs.path.join(scratch, &.{ bundle_dir, "manifest.json" });
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        manifest_path,
        scratch,
        .limited(1024 * 1024),
    );
    var manifest = try std.json.parseFromSlice(std.json.Value, scratch, manifest_bytes, .{});
    defer manifest.deinit();
    if (manifest.value != .object) return error.InvalidTraceManifest;

    var reducer = try Reducer.init(scratch, bundle_dir, manifest.value.object);
    const trace_path = try std.fs.path.join(scratch, &.{ bundle_dir, "trace.jsonl" });
    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        trace_path,
        scratch,
        .limited(64 * 1024 * 1024),
    );

    var lines = std.mem.splitScalar(u8, trace_bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, scratch, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidTraceEvent;
        try reducer.applyEvent(parsed.value.object);
    }

    return reducer.render(allocator);
}

pub fn reduceBundleToFile(allocator: std.mem.Allocator, bundle_dir: []const u8, output_path_opt: ?[]const u8) ![]const u8 {
    const output_path = if (output_path_opt) |path|
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ bundle_dir, STATE_FILE_NAME });
    errdefer allocator.free(output_path);

    const rendered = try reduceBundle(allocator, bundle_dir);
    defer allocator.free(rendered);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = output_path,
        .data = rendered,
    });
    return output_path;
}

fn executionWindow(
    allocator: std.mem.Allocator,
    started_at_unix_ms: i64,
    started_seq: u64,
    ended_at_unix_ms: ?i64,
    ended_seq: ?u64,
    status: []const u8,
) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(allocator, "started_at_unix_ms", .{ .integer = started_at_unix_ms });
    try object.put(allocator, "started_seq", .{ .integer = @intCast(started_seq) });
    if (ended_at_unix_ms) |value| {
        try object.put(allocator, "ended_at_unix_ms", .{ .integer = value });
    } else {
        try object.put(allocator, "ended_at_unix_ms", .null);
    }
    if (ended_seq) |value| {
        try object.put(allocator, "ended_seq", .{ .integer = @intCast(value) });
    } else {
        try object.put(allocator, "ended_seq", .null);
    }
    try putString(allocator, &object, "status", status);
    return .{ .object = object };
}

fn emptyArray(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn emptyObject() std.json.Value {
    return .{ .object = .{} };
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putOptionalString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try putString(allocator, object, key, text);
    } else {
        try object.put(allocator, key, .null);
    }
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn cloneKindValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidRawPayloadRef;
    const kind_type = try stringField(value.object, "type");
    var object: std.json.ObjectMap = .{};
    try putString(allocator, &object, "type", kind_type);
    if (value.object.get("value")) |kind_value| {
        if (kind_value == .string) try putString(allocator, &object, "value", kind_value.string);
    }
    return .{ .object = object };
}

fn objectValuePtr(value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*object| object,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, field: []const u8) !std.json.ObjectMap {
    const value = object.get(field) orelse return error.MissingTraceField;
    if (value != .object) return error.InvalidTraceField;
    return value.object;
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.MissingTraceField;
    if (value != .string) return error.InvalidTraceField;
    return value.string;
}

fn optionalStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value == .string) return value.string;
    return null;
}

fn integerField(object: std.json.ObjectMap, field: []const u8) !i64 {
    const value = object.get(field) orelse return error.MissingTraceField;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidTraceField,
    };
}

fn statusString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = try stringField(object, field);
    if (std.mem.eql(u8, value, "running") or
        std.mem.eql(u8, value, "completed") or
        std.mem.eql(u8, value, "failed") or
        std.mem.eql(u8, value, "aborted") or
        std.mem.eql(u8, value, "cancelled"))
    {
        return value;
    }
    return error.InvalidTraceStatus;
}

fn rolloutStatusToExecution(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "completed")) return "completed";
    if (std.mem.eql(u8, status, "failed")) return "failed";
    if (std.mem.eql(u8, status, "aborted")) return "aborted";
    return "running";
}

fn isRawPayloadRef(object: std.json.ObjectMap) bool {
    return object.get("raw_payload_id") != null and object.get("kind") != null and object.get("path") != null;
}

fn threadSpawnObject(object: std.json.ObjectMap) ?std.json.ObjectMap {
    const session_source = object.get("session_source") orelse return null;
    if (session_source != .object) return null;
    const subagent = session_source.object.get("subagent") orelse return null;
    if (subagent != .object) return null;
    const thread_spawn = subagent.object.get("thread_spawn") orelse return null;
    if (thread_spawn != .object) return null;
    return thread_spawn.object;
}

fn taskNameFromAgentPath(agent_path: []const u8) []const u8 {
    var iterator = std.mem.splitBackwardsScalar(u8, agent_path, '/');
    while (iterator.next()) |segment| {
        if (segment.len > 0) return segment;
    }
    return agent_path;
}
