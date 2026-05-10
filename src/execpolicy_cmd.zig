const std = @import("std");

const cli_utils = @import("cli_utils.zig");

const Decision = enum {
    allow,
    prompt,
    forbidden,

    fn label(self: Decision) []const u8 {
        return switch (self) {
            .allow => "allow",
            .prompt => "prompt",
            .forbidden => "forbidden",
        };
    }

    fn rank(self: Decision) u8 {
        return switch (self) {
            .allow => 0,
            .prompt => 1,
            .forbidden => 2,
        };
    }
};

const PatternToken = struct {
    alternatives: []const []const u8,

    fn deinit(self: PatternToken, allocator: std.mem.Allocator) void {
        for (self.alternatives) |alternative| allocator.free(alternative);
        allocator.free(self.alternatives);
    }
};

const PrefixRule = struct {
    pattern: []PatternToken,
    decision: Decision,
    justification: ?[]const u8 = null,

    fn deinit(self: PrefixRule, allocator: std.mem.Allocator) void {
        for (self.pattern) |token| token.deinit(allocator);
        allocator.free(self.pattern);
        if (self.justification) |justification| allocator.free(justification);
    }
};

const RuleMatch = struct {
    rule: *const PrefixRule,
    matched_prefix: []const []const u8,
};

const CheckOptions = struct {
    rule_paths: std.ArrayList([]const u8) = .empty,
    command: std.ArrayList([]const u8) = .empty,
    pretty: bool = false,
    resolve_host_executables: bool = false,
    help: bool = false,

    fn deinit(self: *CheckOptions, allocator: std.mem.Allocator) void {
        self.rule_paths.deinit(allocator);
        self.command.deinit(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        printHelp();
        return error.MissingExecPolicySubcommand;
    };
    if (isHelpFlag(subcommand)) {
        printHelp();
        return;
    }
    if (!std.mem.eql(u8, subcommand, "check")) return error.UnknownExecPolicySubcommand;
    try runCheck(allocator, args);
}

fn runCheck(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var options = try parseCheckOptions(allocator, args);
    defer options.deinit(allocator);
    if (options.help) {
        printCheckHelp();
        return;
    }
    if (options.rule_paths.items.len == 0) return error.MissingExecPolicyRules;
    if (options.command.items.len == 0) return error.MissingExecPolicyCommand;

    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);

    for (options.rule_paths.items) |path| {
        const contents = try readRulesFile(allocator, path);
        defer allocator.free(contents);
        try parseRules(allocator, contents, &rules);
    }

    const rendered = try evaluateRules(allocator, rules.items, options.command.items, options.pretty);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
    try cli_utils.writeStdout("\n");

    _ = options.resolve_host_executables;
}

fn parseCheckOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !CheckOptions {
    var options = CheckOptions{};
    errdefer options.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            try collectCommand(arg, args, &options.command, allocator, false);
            break;
        }
        if (isHelpFlag(arg)) {
            options.help = true;
            return options;
        }
        if (std.mem.eql(u8, arg, "--rules") or std.mem.eql(u8, arg, "-r")) {
            try options.rule_paths.append(allocator, args.next() orelse return error.MissingExecPolicyRulesPath);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--rules=")) {
            const path = arg["--rules=".len..];
            if (path.len == 0) return error.MissingExecPolicyRulesPath;
            try options.rule_paths.append(allocator, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "--pretty")) {
            options.pretty = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--resolve-host-executables")) {
            options.resolve_host_executables = true;
            continue;
        }
        try collectCommand(arg, args, &options.command, allocator, true);
        break;
    }

    return options;
}

fn collectCommand(
    first: []const u8,
    args: *std.process.Args.Iterator,
    command: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    include_first: bool,
) !void {
    if (include_first) try command.append(allocator, first);
    while (args.next()) |arg| {
        try command.append(allocator, arg);
    }
}

fn readRulesFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        allocator,
        .limited(1024 * 1024),
    );
}

fn parseRules(
    allocator: std.mem.Allocator,
    contents: []const u8,
    rules: *std.ArrayList(PrefixRule),
) !void {
    var pos: usize = 0;
    while (findPrefixRuleOpen(contents, pos)) |open_index| {
        const close_index = try findMatchingParen(contents, open_index);
        const body = contents[open_index + 1 .. close_index];
        const rule = try parsePrefixRule(allocator, body);
        errdefer rule.deinit(allocator);
        try rules.append(allocator, rule);
        pos = close_index + 1;
    }
}

fn findPrefixRuleOpen(contents: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < contents.len) {
        const found = std.mem.indexOfPos(u8, contents, pos, "prefix_rule") orelse return null;
        const before_ok = found == 0 or !isIdentifierChar(contents[found - 1]);
        const after_name = found + "prefix_rule".len;
        const after_ok = after_name >= contents.len or !isIdentifierChar(contents[after_name]);
        if (before_ok and after_ok) {
            var next = after_name;
            skipWhitespace(contents, &next);
            if (next < contents.len and contents[next] == '(') return next;
        }
        pos = after_name;
    }
    return null;
}

fn findMatchingParen(contents: []const u8, open_index: usize) !usize {
    var depth: usize = 0;
    var pos = open_index;
    var quote: ?u8 = null;
    var escaped = false;
    while (pos < contents.len) : (pos += 1) {
        const c = contents[pos];
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == active_quote) {
                quote = null;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#') {
            while (pos < contents.len and contents[pos] != '\n') : (pos += 1) {}
            if (pos >= contents.len) break;
            continue;
        }
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) return error.UnbalancedExecPolicyRule;
            depth -= 1;
            if (depth == 0) return pos;
        }
    }
    return error.UnbalancedExecPolicyRule;
}

fn parsePrefixRule(allocator: std.mem.Allocator, body: []const u8) !PrefixRule {
    var pattern: ?[]PatternToken = null;
    errdefer if (pattern) |owned| deinitPattern(allocator, owned);
    var decision: Decision = .allow;
    var justification: ?[]const u8 = null;
    errdefer if (justification) |owned| allocator.free(owned);

    var pos: usize = 0;
    while (try nextAssignment(body, &pos)) |assignment| {
        if (std.mem.eql(u8, assignment.key, "pattern")) {
            if (pattern != null) return error.DuplicateExecPolicyField;
            pattern = try parsePattern(allocator, assignment.value);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "decision")) {
            const label = try parseOwnedString(allocator, assignment.value);
            defer allocator.free(label);
            decision = try parseDecision(label);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "justification")) {
            if (justification != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            errdefer allocator.free(parsed);
            if (parsed.len == 0) return error.EmptyExecPolicyJustification;
            justification = parsed;
            continue;
        }
    }

    return .{
        .pattern = pattern orelse return error.MissingExecPolicyPattern,
        .decision = decision,
        .justification = justification,
    };
}

const Assignment = struct {
    key: []const u8,
    value: []const u8,
};

fn nextAssignment(contents: []const u8, pos: *usize) !?Assignment {
    skipAssignmentTrivia(contents, pos);
    if (pos.* >= contents.len) return null;
    const key_start = pos.*;
    while (pos.* < contents.len and isIdentifierChar(contents[pos.*])) : (pos.* += 1) {}
    if (pos.* == key_start) return error.InvalidExecPolicyRule;
    const key = contents[key_start..pos.*];
    skipWhitespace(contents, pos);
    if (pos.* >= contents.len or contents[pos.*] != '=') return error.InvalidExecPolicyRule;
    pos.* += 1;
    skipWhitespace(contents, pos);
    const value_start = pos.*;
    const value_end = try scanAssignmentValue(contents, pos);
    return .{
        .key = std.mem.trim(u8, key, " \t\r\n"),
        .value = std.mem.trim(u8, contents[value_start..value_end], " \t\r\n"),
    };
}

fn scanAssignmentValue(contents: []const u8, pos: *usize) !usize {
    var square_depth: usize = 0;
    var paren_depth: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    while (pos.* < contents.len) : (pos.* += 1) {
        const c = contents[pos.*];
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == active_quote) {
                quote = null;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#' and square_depth == 0 and paren_depth == 0) return pos.*;
        if (c == '[') {
            square_depth += 1;
            continue;
        }
        if (c == ']') {
            if (square_depth == 0) return error.UnbalancedExecPolicyRule;
            square_depth -= 1;
            continue;
        }
        if (c == '(') {
            paren_depth += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth == 0) return error.UnbalancedExecPolicyRule;
            paren_depth -= 1;
            continue;
        }
        if (c == ',' and square_depth == 0 and paren_depth == 0) {
            const end = pos.*;
            pos.* += 1;
            return end;
        }
    }
    return contents.len;
}

fn skipAssignmentTrivia(contents: []const u8, pos: *usize) void {
    while (pos.* < contents.len) {
        const c = contents[pos.*];
        if (c == ',' or std.ascii.isWhitespace(c)) {
            pos.* += 1;
            continue;
        }
        if (c == '#') {
            while (pos.* < contents.len and contents[pos.*] != '\n') : (pos.* += 1) {}
            continue;
        }
        break;
    }
}

fn parsePattern(allocator: std.mem.Allocator, value: []const u8) ![]PatternToken {
    var parser = ValueParser{ .allocator = allocator, .input = value };
    try parser.expect('[');
    var tokens = std.ArrayList(PatternToken).empty;
    errdefer {
        deinitPattern(allocator, tokens.items);
        tokens.deinit(allocator);
    }

    while (true) {
        parser.skipTrivia();
        if (parser.consume(']')) break;
        const token = try parser.parsePatternToken();
        errdefer token.deinit(allocator);
        try tokens.append(allocator, token);
        parser.skipTrivia();
        if (parser.consume(',')) continue;
        if (parser.consume(']')) break;
        return error.ExpectedExecPolicyPatternSeparator;
    }
    parser.skipTrivia();
    if (!parser.isEof()) return error.UnexpectedExecPolicyPatternInput;
    if (tokens.items.len == 0) return error.EmptyExecPolicyPattern;
    return tokens.toOwnedSlice(allocator);
}

fn deinitPattern(allocator: std.mem.Allocator, pattern: []PatternToken) void {
    for (pattern) |token| token.deinit(allocator);
    allocator.free(pattern);
}

const ValueParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn isEof(self: ValueParser) bool {
        return self.pos >= self.input.len;
    }

    fn skipTrivia(self: *ValueParser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                while (self.pos < self.input.len and self.input[self.pos] != '\n') : (self.pos += 1) {}
                continue;
            }
            break;
        }
    }

    fn expect(self: *ValueParser, expected: u8) !void {
        self.skipTrivia();
        if (self.pos >= self.input.len or self.input[self.pos] != expected) return error.UnexpectedExecPolicyPatternInput;
        self.pos += 1;
    }

    fn consume(self: *ValueParser, expected: u8) bool {
        self.skipTrivia();
        if (self.pos < self.input.len and self.input[self.pos] == expected) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn parsePatternToken(self: *ValueParser) !PatternToken {
        self.skipTrivia();
        if (self.pos >= self.input.len) return error.ExpectedExecPolicyPatternToken;
        if (self.input[self.pos] == '[') return .{ .alternatives = try self.parseStringList() };

        const string = try self.parseString();
        errdefer self.allocator.free(string);
        const alternatives = try self.allocator.alloc([]const u8, 1);
        alternatives[0] = string;
        return .{ .alternatives = alternatives };
    }

    fn parseStringList(self: *ValueParser) ![]const []const u8 {
        try self.expect('[');
        var values = std.ArrayList([]const u8).empty;
        errdefer {
            for (values.items) |value| self.allocator.free(value);
            values.deinit(self.allocator);
        }
        while (true) {
            self.skipTrivia();
            if (self.consume(']')) break;
            const string = try self.parseString();
            errdefer self.allocator.free(string);
            try values.append(self.allocator, string);
            self.skipTrivia();
            if (self.consume(',')) continue;
            if (self.consume(']')) break;
            return error.ExpectedExecPolicyPatternSeparator;
        }
        if (values.items.len == 0) return error.EmptyExecPolicyAlternative;
        return values.toOwnedSlice(self.allocator);
    }

    fn parseString(self: *ValueParser) ![]const u8 {
        self.skipTrivia();
        if (self.pos >= self.input.len) return error.ExpectedExecPolicyString;
        const quote = self.input[self.pos];
        if (quote != '"' and quote != '\'') return error.ExpectedExecPolicyString;
        self.pos += 1;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (c == quote) {
                self.pos += 1;
                return out.toOwnedSlice(self.allocator);
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnterminatedExecPolicyString;
                const escaped = self.input[self.pos];
                const decoded: u8 = switch (escaped) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => escaped,
                };
                try out.append(self.allocator, decoded);
                continue;
            }
            try out.append(self.allocator, c);
        }
        return error.UnterminatedExecPolicyString;
    }
};

fn parseOwnedString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var parser = ValueParser{ .allocator = allocator, .input = value };
    const string = try parser.parseString();
    errdefer allocator.free(string);
    parser.skipTrivia();
    if (!parser.isEof()) return error.UnexpectedExecPolicyStringInput;
    return string;
}

fn parseDecision(label: []const u8) !Decision {
    if (std.mem.eql(u8, label, "allow")) return .allow;
    if (std.mem.eql(u8, label, "prompt")) return .prompt;
    if (std.mem.eql(u8, label, "forbidden")) return .forbidden;
    return error.UnknownExecPolicyDecision;
}

fn evaluateRules(
    allocator: std.mem.Allocator,
    rules: []const PrefixRule,
    command: []const []const u8,
    pretty: bool,
) ![]const u8 {
    var matches = std.ArrayList(RuleMatch).empty;
    defer matches.deinit(allocator);

    var decision: ?Decision = null;
    for (rules) |*rule| {
        if (!ruleMatches(rule.*, command)) continue;
        try matches.append(allocator, .{
            .rule = rule,
            .matched_prefix = command[0..rule.pattern.len],
        });
        if (decision == null or rule.decision.rank() > decision.?.rank()) {
            decision = rule.decision;
        }
    }

    if (pretty) return renderPretty(allocator, decision, matches.items);
    return renderCompact(allocator, decision, matches.items);
}

fn ruleMatches(rule: PrefixRule, command: []const []const u8) bool {
    if (rule.pattern.len > command.len) return false;
    for (rule.pattern, 0..) |token, index| {
        if (!tokenMatches(token, command[index])) return false;
    }
    return true;
}

fn tokenMatches(token: PatternToken, command_token: []const u8) bool {
    for (token.alternatives) |alternative| {
        if (std.mem.eql(u8, alternative, command_token)) return true;
    }
    return false;
}

fn renderCompact(
    allocator: std.mem.Allocator,
    decision: ?Decision,
    matches: []const RuleMatch,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    if (decision) |value| {
        try out.appendSlice(allocator, "\"decision\":");
        try appendJsonString(allocator, &out, value.label());
        try out.append(allocator, ',');
    }
    try out.appendSlice(allocator, "\"matchedRules\":[");
    for (matches, 0..) |match, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendCompactMatch(allocator, &out, match);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendCompactMatch(allocator: std.mem.Allocator, out: *std.ArrayList(u8), match: RuleMatch) !void {
    try out.appendSlice(allocator, "{\"prefixRuleMatch\":{\"matchedPrefix\":");
    try appendJsonStringArray(allocator, out, match.matched_prefix);
    try out.appendSlice(allocator, ",\"decision\":");
    try appendJsonString(allocator, out, match.rule.decision.label());
    if (match.rule.justification) |justification| {
        try out.appendSlice(allocator, ",\"justification\":");
        try appendJsonString(allocator, out, justification);
    }
    try out.appendSlice(allocator, "}}");
}

fn renderPretty(
    allocator: std.mem.Allocator,
    decision: ?Decision,
    matches: []const RuleMatch,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n");
    if (decision) |value| {
        try out.appendSlice(allocator, "  \"decision\": ");
        try appendJsonString(allocator, &out, value.label());
        try out.appendSlice(allocator, ",\n");
    }
    try out.appendSlice(allocator, "  \"matchedRules\": [");
    if (matches.len > 0) try out.append(allocator, '\n');
    for (matches, 0..) |match, index| {
        if (index > 0) try out.appendSlice(allocator, ",\n");
        try appendPrettyMatch(allocator, &out, match);
    }
    if (matches.len > 0) try out.appendSlice(allocator, "\n  ");
    try out.appendSlice(allocator, "]\n}");
    return out.toOwnedSlice(allocator);
}

fn appendPrettyMatch(allocator: std.mem.Allocator, out: *std.ArrayList(u8), match: RuleMatch) !void {
    try out.appendSlice(allocator, "    {\n");
    try out.appendSlice(allocator, "      \"prefixRuleMatch\": {\n");
    try out.appendSlice(allocator, "        \"matchedPrefix\": [");
    for (match.matched_prefix, 0..) |token, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try appendJsonString(allocator, out, token);
    }
    try out.appendSlice(allocator, "],\n");
    try out.appendSlice(allocator, "        \"decision\": ");
    try appendJsonString(allocator, out, match.rule.decision.label());
    if (match.rule.justification) |justification| {
        try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, "        \"justification\": ");
        try appendJsonString(allocator, out, justification);
        try out.appendSlice(allocator, "\n");
    } else {
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "      }\n");
    try out.appendSlice(allocator, "    }");
}

fn appendJsonStringArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    values: []const []const u8,
) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, value);
    }
    try out.append(allocator, ']');
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn deinitRules(allocator: std.mem.Allocator, rules: []PrefixRule) void {
    for (rules) |rule| rule.deinit(allocator);
}

fn skipWhitespace(contents: []const u8, pos: *usize) void {
    while (pos.* < contents.len and std.ascii.isWhitespace(contents[pos.*])) : (pos.* += 1) {}
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig execpolicy check --rules PATH [--pretty] [--resolve-host-executables] COMMAND...
        \\
        \\Commands:
        \\  check                  Check execpolicy files against a command.
        \\
    , .{});
}

fn printCheckHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig execpolicy check --rules PATH [--pretty] [--resolve-host-executables] COMMAND...
        \\
        \\Options:
        \\  -r, --rules PATH       Execpolicy rules file. Can be repeated.
        \\      --pretty           Pretty-print JSON output.
        \\      --resolve-host-executables
        \\                          Accepted for Rust CLI compatibility; full host
        \\                          executable resolution remains planned.
        \\
    , .{});
}

test "execpolicy check matches forbidden prefix rule" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(
        \\    pattern = ["git", "push"],
        \\    decision = "forbidden",
        \\)
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const command = [_][]const u8{ "git", "push", "origin", "main" };
    const rendered = try evaluateRules(allocator, rules.items, command[0..], false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"forbidden\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"push\"],\"decision\":\"forbidden\"}}]}",
        rendered,
    );
}

test "execpolicy check includes prefix rule justification" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(
        \\    pattern = ["git", "push"],
        \\    decision = "forbidden",
        \\    justification = "pushing is blocked in this repo",
        \\)
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const command = [_][]const u8{ "git", "push", "origin", "main" };
    const rendered = try evaluateRules(allocator, rules.items, command[0..], false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"forbidden\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"push\"],\"decision\":\"forbidden\",\"justification\":\"pushing is blocked in this repo\"}}]}",
        rendered,
    );
}

test "execpolicy check omits decision without matches" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(
        \\    pattern = ["git", "push"],
        \\    decision = "forbidden",
        \\)
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const command = [_][]const u8{ "git", "status" };
    const rendered = try evaluateRules(allocator, rules.items, command[0..], false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", rendered);
}

test "execpolicy check supports pattern alternatives and strictest decision" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = [["bash", "sh"], ["-c", "-l"]])
        \\prefix_rule(pattern = ["bash", "-c"], decision = "prompt")
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const command = [_][]const u8{ "bash", "-c", "echo hi" };
    const rendered = try evaluateRules(allocator, rules.items, command[0..], false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"prompt\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"bash\",\"-c\"],\"decision\":\"allow\"}},{\"prefixRuleMatch\":{\"matchedPrefix\":[\"bash\",\"-c\"],\"decision\":\"prompt\"}}]}",
        rendered,
    );
}
