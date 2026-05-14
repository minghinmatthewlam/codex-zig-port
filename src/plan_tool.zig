const std = @import("std");

pub const Status = enum {
    pending,
    in_progress,
    completed,

    pub fn parse(raw: []const u8) ?Status {
        if (std.ascii.eqlIgnoreCase(raw, "pending")) return .pending;
        if (std.ascii.eqlIgnoreCase(raw, "in_progress") or std.ascii.eqlIgnoreCase(raw, "in-progress")) return .in_progress;
        if (std.ascii.eqlIgnoreCase(raw, "completed") or std.ascii.eqlIgnoreCase(raw, "complete")) return .completed;
        return null;
    }

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[>]",
            .completed => "[x]",
        };
    }

    pub fn id(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
    }
};

pub const Item = struct {
    step: []const u8,
    status: Status,

    fn deinit(self: Item, allocator: std.mem.Allocator) void {
        allocator.free(self.step);
    }
};

pub const State = struct {
    explanation: ?[]const u8 = null,
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.explanation) |value| allocator.free(value);
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = .{};
    }

    pub fn clone(self: *const State, allocator: std.mem.Allocator) !State {
        var copy = State{};
        errdefer copy.deinit(allocator);
        if (self.explanation) |value| copy.explanation = try allocator.dupe(u8, value);
        for (self.items.items) |item| {
            const step = try allocator.dupe(u8, item.step);
            errdefer allocator.free(step);
            try copy.items.append(allocator, .{ .step = step, .status = item.status });
        }
        return copy;
    }

    pub fn completedCount(self: *const State) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.status == .completed) count += 1;
        }
        return count;
    }

    pub fn progressLabel(self: *const State, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.items.items.len == 0) return null;
        const label = try std.fmt.allocPrint(allocator, "Tasks {d}/{d}", .{ self.completedCount(), self.items.items.len });
        return label;
    }

    pub fn render(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "plan:\n");
        if (self.explanation) |explanation| {
            if (explanation.len > 0) {
                try output.appendSlice(allocator, "  ");
                try output.appendSlice(allocator, explanation);
                try output.append(allocator, '\n');
            }
        }
        if (self.items.items.len == 0) {
            try output.appendSlice(allocator, "  <empty>\n");
            return output.toOwnedSlice(allocator);
        }
        for (self.items.items) |item| {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, item.status.label());
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, item.step);
            try output.append(allocator, '\n');
        }
        return output.toOwnedSlice(allocator);
    }
};

pub const UpdateResult = struct {
    applied: bool,
    summary: []const u8,
    output: []const u8,

    pub fn deinit(self: UpdateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.output);
    }
};

const UpdateArgs = struct {
    explanation: ?[]const u8 = null,
    plan: []const ItemArg,
};

const ItemArg = struct {
    step: []const u8,
    status: []const u8,
};

pub fn applyUpdate(allocator: std.mem.Allocator, state: *State, args_json: []const u8) !UpdateResult {
    var parsed = std.json.parseFromSlice(UpdateArgs, allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return invalidResult(allocator, "invalid update_plan arguments");
    };
    defer parsed.deinit();

    var next = State{};
    var next_moved = false;
    errdefer if (!next_moved) next.deinit(allocator);

    if (parsed.value.explanation) |explanation| {
        const trimmed = std.mem.trim(u8, explanation, " \t\r\n");
        if (trimmed.len > 0) {
            next.explanation = try allocator.dupe(u8, trimmed);
        }
    }

    var in_progress_count: usize = 0;
    for (parsed.value.plan) |raw_item| {
        const step = std.mem.trim(u8, raw_item.step, " \t\r\n");
        if (step.len == 0) {
            next.deinit(allocator);
            next_moved = true;
            return invalidResult(allocator, "invalid update_plan item: empty step");
        }
        const status = Status.parse(raw_item.status) orelse {
            next.deinit(allocator);
            next_moved = true;
            return invalidResult(allocator, "invalid update_plan item: unknown status");
        };
        if (status == .in_progress) in_progress_count += 1;
        const owned_step = try allocator.dupe(u8, step);
        errdefer allocator.free(owned_step);
        try next.items.append(allocator, .{ .step = owned_step, .status = status });
    }
    if (in_progress_count > 1) {
        next.deinit(allocator);
        next_moved = true;
        return invalidResult(allocator, "invalid update_plan: multiple in_progress items");
    }

    state.deinit(allocator);
    state.* = next;
    next_moved = true;

    const summary = try std.fmt.allocPrint(allocator, "plan updated {d}/{d}", .{ state.completedCount(), state.items.items.len });
    errdefer allocator.free(summary);
    const output = try state.render(allocator);
    errdefer allocator.free(output);
    return .{ .applied = true, .summary = summary, .output = output };
}

fn invalidResult(allocator: std.mem.Allocator, message: []const u8) !UpdateResult {
    return .{
        .applied = false,
        .summary = try allocator.dupe(u8, "invalid plan"),
        .output = try allocator.dupe(u8, message),
    };
}

test "applies update_plan state and renders progress" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);

    var result = try applyUpdate(allocator, &state,
        \\{"explanation":"Demo progress","plan":[{"step":"Inspect repo","status":"completed"},{"step":"Patch feature","status":"in_progress"},{"step":"Verify","status":"pending"}]}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("plan updated 1/3", result.summary);
    try std.testing.expect(result.applied);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[x] Inspect repo") != null);

    const progress = (try state.progressLabel(allocator)).?;
    defer allocator.free(progress);
    try std.testing.expectEqualStrings("Tasks 1/3", progress);
}

test "rejects invalid update_plan status without mutating state" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);

    var result = try applyUpdate(allocator, &state,
        \\{"plan":[{"step":"A","status":"completed"},{"step":"B","status":"in_progress"},{"step":"C","status":"in_progress"}]}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("invalid plan", result.summary);
    try std.testing.expect(!result.applied);
    try std.testing.expectEqual(@as(usize, 0), state.items.items.len);
}
