const std = @import("std");

const open_tag = "<proposed_plan>";
const close_tag = "</proposed_plan>";

pub fn renderPlanMode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(allocator);
    var plan = std.ArrayList(u8).empty;
    defer plan.deinit(allocator);

    var in_plan = false;
    var saw_plan = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, open_tag)) {
            in_plan = true;
            saw_plan = true;
            plan.clearRetainingCapacity();
            continue;
        }
        if (std.mem.eql(u8, trimmed, close_tag)) {
            in_plan = false;
            continue;
        }

        const target = if (in_plan) &plan else &visible;
        try target.appendSlice(allocator, line);
        try target.append(allocator, '\n');
    }

    if (!saw_plan) return allocator.dupe(u8, text);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const visible_text = std.mem.trim(u8, visible.items, " \t\r\n");
    if (visible_text.len > 0) {
        try output.appendSlice(allocator, visible_text);
        try output.appendSlice(allocator, "\n\n");
    }
    try output.appendSlice(allocator, "proposed plan:\n");
    const plan_text = std.mem.trim(u8, plan.items, " \t\r\n");
    if (plan_text.len > 0) {
        try output.appendSlice(allocator, plan_text);
        try output.append(allocator, '\n');
    } else {
        try output.appendSlice(allocator, "<empty>\n");
    }

    return output.toOwnedSlice(allocator);
}

test "renders proposed plan block without tags" {
    const allocator = std.testing.allocator;
    const rendered = try renderPlanMode(allocator, "Intro\n<proposed_plan>\n1. Inspect\n2. Verify\n</proposed_plan>\nOutro\n");
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Intro\nOutro\n\nproposed plan:\n1. Inspect\n2. Verify\n", rendered);
}

test "leaves normal text unchanged" {
    const allocator = std.testing.allocator;
    const rendered = try renderPlanMode(allocator, "plain response\n");
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("plain response\n", rendered);
}

test "preserves tag lines with extra text" {
    const allocator = std.testing.allocator;
    const rendered = try renderPlanMode(allocator, "  <proposed_plan> extra\n");
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("  <proposed_plan> extra\n", rendered);
}

test "renders unterminated proposed plan block" {
    const allocator = std.testing.allocator;
    const rendered = try renderPlanMode(allocator, "<proposed_plan>\n- step 1\n");
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("proposed plan:\n- step 1\n", rendered);
}
