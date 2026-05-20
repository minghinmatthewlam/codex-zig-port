const std = @import("std");

pub const fallback_message = "Reviewer failed to output a response.";

pub const output_schema_json =
    \\{
    \\  "type": "object",
    \\  "additionalProperties": false,
    \\  "properties": {
    \\    "findings": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "additionalProperties": false,
    \\        "properties": {
    \\          "title": { "type": "string" },
    \\          "body": { "type": "string" },
    \\          "confidence_score": { "type": "number" },
    \\          "priority": { "type": "integer" },
    \\          "code_location": {
    \\            "type": "object",
    \\            "additionalProperties": false,
    \\            "properties": {
    \\              "absolute_file_path": { "type": "string" },
    \\              "line_range": {
    \\                "type": "object",
    \\                "additionalProperties": false,
    \\                "properties": {
    \\                  "start": { "type": "integer" },
    \\                  "end": { "type": "integer" }
    \\                },
    \\                "required": ["start", "end"]
    \\              }
    \\            },
    \\            "required": ["absolute_file_path", "line_range"]
    \\          }
    \\        },
    \\        "required": ["title", "body", "confidence_score", "priority", "code_location"]
    \\      }
    \\    },
    \\    "overall_correctness": {
    \\      "type": "string",
    \\      "enum": ["patch is correct", "patch is incorrect"]
    \\    },
    \\    "overall_explanation": { "type": "string" },
    \\    "overall_confidence_score": { "type": "number" }
    \\  },
    \\  "required": ["findings", "overall_correctness", "overall_explanation", "overall_confidence_score"]
    \\}
;

pub fn parseOutputSchema(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, output_schema_json, .{});
}

pub fn renderText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, fallback_message);
    if (try renderJsonText(allocator, trimmed)) |rendered| return rendered;
    if (std.mem.indexOfScalar(u8, trimmed, '{')) |start| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, '}')) |end| {
            if (start < end) {
                if (try renderJsonText(allocator, trimmed[start .. end + 1])) |rendered| return rendered;
            }
        }
    }
    return allocator.dupe(u8, trimmed);
}

pub fn renderJsonText(allocator: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    return try renderJsonValue(allocator, parsed.value);
}

pub fn renderJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    if (value != .object) return null;
    const object = value.object;
    const explanation_value = object.get("overall_explanation") orelse return null;
    if (explanation_value != .string) return null;
    const findings_value = object.get("findings") orelse return null;
    if (findings_value != .array) return null;

    var out = std.ArrayList(u8).empty;
    var out_moved = false;
    defer if (!out_moved) out.deinit(allocator);
    const explanation = std.mem.trim(u8, explanation_value.string, " \t\r\n");
    if (explanation.len > 0) try out.appendSlice(allocator, explanation);
    if (findings_value.array.items.len > 0) {
        if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
        if (findings_value.array.items.len > 1) {
            try out.appendSlice(allocator, "Full review comments:");
        } else {
            try out.appendSlice(allocator, "Review comment:");
        }
        for (findings_value.array.items) |finding_value| {
            if (finding_value != .object) return null;
            const finding = finding_value.object;
            const title = jsonStringField(finding, "title") orelse return null;
            const body = jsonStringField(finding, "body") orelse return null;
            const location_value = finding.get("code_location") orelse return null;
            if (location_value != .object) return null;
            const location = location_value.object;
            const path = jsonStringField(location, "absolute_file_path") orelse return null;
            const line_range_value = location.get("line_range") orelse return null;
            if (line_range_value != .object) return null;
            const line_range = line_range_value.object;
            const start = jsonIntegerField(line_range, "start") orelse return null;
            const end = jsonIntegerField(line_range, "end") orelse return null;

            try out.appendSlice(allocator, "\n\n- ");
            try out.appendSlice(allocator, title);
            try out.appendSlice(allocator, " - ");
            try out.appendSlice(allocator, path);
            try out.append(allocator, ':');
            try appendInt(allocator, &out, start);
            try out.append(allocator, '-');
            try appendInt(allocator, &out, end);
            if (body.len > 0) {
                var lines = std.mem.splitScalar(u8, body, '\n');
                while (lines.next()) |line| {
                    try out.appendSlice(allocator, "\n  ");
                    try out.appendSlice(allocator, line);
                }
            }
        }
    }
    if (out.items.len == 0) return @as(?[]const u8, try allocator.dupe(u8, fallback_message));
    const rendered = try out.toOwnedSlice(allocator);
    out_moved = true;
    return @as(?[]const u8, rendered);
}

fn jsonStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonIntegerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

test "review output schema parses" {
    var schema = try parseOutputSchema(std.testing.allocator);
    defer schema.deinit();

    try std.testing.expectEqualStrings("object", schema.value.object.get("type").?.string);
    try std.testing.expect(schema.value.object.get("required").?.array.items.len == 4);
}

test "renders structured review output with findings" {
    const structured =
        \\{"findings":[{"title":"[P2] Tighten check","body":"This is actionable.","confidence_score":0.9,"priority":2,"code_location":{"absolute_file_path":"/tmp/example.zig","line_range":{"start":12,"end":14}}}],"overall_correctness":"patch is correct","overall_explanation":"Looks correct","overall_confidence_score":0.8}
    ;

    const rendered = try renderText(std.testing.allocator, structured);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "Looks correct\n\nReview comment:\n\n- [P2] Tighten check - /tmp/example.zig:12-14\n  This is actionable.",
        rendered,
    );
}

test "render falls back to original text when structured output is partial" {
    const malformed =
        \\{"overall_explanation":"Looks partial","findings":[{"title":"Missing body"}]}
    ;

    const rendered = try renderText(std.testing.allocator, malformed);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(malformed, rendered);
}
