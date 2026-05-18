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

pub fn extractPlanText(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
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
        if (in_plan) {
            try plan.appendSlice(allocator, line);
            try plan.append(allocator, '\n');
        }
    }

    if (!saw_plan) return null;
    const plan_text = std.mem.trim(u8, plan.items, " \t\r\n");
    if (plan_text.len == 0) return try allocator.dupe(u8, "");

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, plan_text);
    try output.append(allocator, '\n');
    return try output.toOwnedSlice(allocator);
}

pub fn stripPlanBlocks(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var visible = std.ArrayList(u8).empty;
    defer visible.deinit(allocator);

    var in_plan = false;
    var index: usize = 0;
    while (index < text.len) {
        const line_start = index;
        while (index < text.len and text[index] != '\n') : (index += 1) {}
        const line_without_newline = text[line_start..index];
        if (index < text.len and text[index] == '\n') index += 1;
        const line_with_newline = text[line_start..index];

        const trimmed = std.mem.trim(u8, line_without_newline, " \t\r");
        if (std.mem.eql(u8, trimmed, open_tag)) {
            in_plan = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, close_tag)) {
            in_plan = false;
            continue;
        }
        if (!in_plan) try visible.appendSlice(allocator, line_with_newline);
    }

    const visible_text = std.mem.trim(u8, visible.items, " \t\r\n");
    return allocator.dupe(u8, visible_text);
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

test "extracts proposed plan text" {
    const allocator = std.testing.allocator;
    const extracted = (try extractPlanText(allocator, "Intro\n<proposed_plan>\n1. Inspect\n2. Verify\n</proposed_plan>\nOutro\n")).?;
    defer allocator.free(extracted);

    try std.testing.expectEqualStrings("1. Inspect\n2. Verify\n", extracted);
}

test "extracts empty proposed plan block" {
    const allocator = std.testing.allocator;
    const extracted = (try extractPlanText(allocator, "<proposed_plan>\n</proposed_plan>\n")).?;
    defer allocator.free(extracted);

    try std.testing.expectEqualStrings("", extracted);
}

test "returns null when proposed plan is absent" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try extractPlanText(allocator, "plain response\n")) == null);
}

test "strips proposed plan block from visible text" {
    const allocator = std.testing.allocator;
    const stripped = try stripPlanBlocks(allocator, "Intro\n<proposed_plan>\n1. Inspect\n</proposed_plan>\nOutro");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("Intro\nOutro", stripped);
}

test "strips unterminated proposed plan block" {
    const allocator = std.testing.allocator;
    const stripped = try stripPlanBlocks(allocator, "Intro\n<proposed_plan>\n1. Inspect\n");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("Intro", stripped);
}

test "strips whitespace-only visible text around proposed plan block" {
    const allocator = std.testing.allocator;
    const stripped = try stripPlanBlocks(allocator, "\n<proposed_plan>\n1. Inspect\n</proposed_plan>\n");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("", stripped);
}
