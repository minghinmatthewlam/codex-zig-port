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

const HostExecutable = struct {
    name: []const u8,
    paths: []const []const u8,

    fn deinit(self: HostExecutable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }
};

const NetworkRuleProtocol = enum {
    http,
    https,
    socks5_tcp,
    socks5_udp,
};

const NetworkRule = struct {
    host: []const u8,
    protocol: NetworkRuleProtocol,
    decision: Decision,
    justification: ?[]const u8 = null,

    fn deinit(self: NetworkRule, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        if (self.justification) |justification| allocator.free(justification);
    }
};

const Examples = []const []const []const u8;

const ParsedPrefixRule = struct {
    rule: PrefixRule,
    match_examples: ?Examples = null,
    not_match_examples: ?Examples = null,
};

const PendingExampleValidation = struct {
    rule_start: usize,
    rule_end: usize,
    match_examples: ?Examples = null,
    not_match_examples: ?Examples = null,

    fn deinit(self: PendingExampleValidation, allocator: std.mem.Allocator) void {
        if (self.match_examples) |examples| freeExamples(allocator, examples);
        if (self.not_match_examples) |examples| freeExamples(allocator, examples);
    }
};

const RuleMatch = struct {
    rule: *const PrefixRule,
    matched_prefix: []const []const u8,
    resolved_program: ?[]const u8 = null,
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
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);

    for (options.rule_paths.items) |path| {
        const contents = try readRulesFile(allocator, path);
        defer allocator.free(contents);
        try parsePolicy(allocator, contents, &rules, &host_executables, &network_rules);
    }

    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        options.command.items,
        .{
            .pretty = options.pretty,
            .resolve_host_executables = options.resolve_host_executables,
        },
    );
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
    try cli_utils.writeStdout("\n");
}

pub fn validateRulesFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const contents = try readRulesFile(allocator, path);
    defer allocator.free(contents);

    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);

    try parsePolicy(allocator, contents, &rules, &host_executables, &network_rules);
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
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);
    try parsePolicy(allocator, contents, rules, &host_executables, &network_rules);
}

fn parsePolicy(
    allocator: std.mem.Allocator,
    contents: []const u8,
    rules: *std.ArrayList(PrefixRule),
    host_executables: *std.ArrayList(HostExecutable),
    network_rules: *std.ArrayList(NetworkRule),
) !void {
    var pos: usize = 0;
    var pending_validations = std.ArrayList(PendingExampleValidation).empty;
    defer {
        for (pending_validations.items) |validation| validation.deinit(allocator);
        pending_validations.deinit(allocator);
    }
    while (findPolicyCallOpen(contents, pos)) |call| {
        const close_index = try findMatchingParen(contents, call.open_index);
        const body = contents[call.open_index + 1 .. close_index];
        switch (call.kind) {
            .prefix_rule => {
                var parsed = try parsePrefixRule(allocator, body);
                var rule_appended = false;
                var examples_appended = false;
                errdefer {
                    if (!rule_appended) parsed.rule.deinit(allocator);
                    if (!examples_appended) {
                        if (parsed.match_examples) |examples| freeExamples(allocator, examples);
                        if (parsed.not_match_examples) |examples| freeExamples(allocator, examples);
                    }
                }
                const rule_start = rules.items.len;
                try rules.append(allocator, parsed.rule);
                rule_appended = true;
                try pending_validations.append(allocator, .{
                    .rule_start = rule_start,
                    .rule_end = rules.items.len,
                    .match_examples = parsed.match_examples,
                    .not_match_examples = parsed.not_match_examples,
                });
                examples_appended = true;
            },
            .host_executable => {
                const host_executable = try parseHostExecutable(allocator, body);
                errdefer host_executable.deinit(allocator);
                try upsertHostExecutable(allocator, host_executables, host_executable);
            },
            .network_rule => {
                const network_rule = try parseNetworkRule(allocator, body);
                errdefer network_rule.deinit(allocator);
                try network_rules.append(allocator, network_rule);
            },
        }
        pos = close_index + 1;
    }
    try validatePendingExamples(rules.items, host_executables.items, pending_validations.items);
}

fn parsePolicyWithHosts(
    allocator: std.mem.Allocator,
    contents: []const u8,
    rules: *std.ArrayList(PrefixRule),
    host_executables: *std.ArrayList(HostExecutable),
) !void {
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);
    try parsePolicy(allocator, contents, rules, host_executables, &network_rules);
}

const PolicyCallKind = enum {
    prefix_rule,
    host_executable,
    network_rule,
};

const PolicyCall = struct {
    kind: PolicyCallKind,
    open_index: usize,
};

fn findPolicyCallOpen(contents: []const u8, start: usize) ?PolicyCall {
    var pos = start;
    var quote: ?u8 = null;
    var escaped = false;
    while (pos < contents.len) {
        const c = contents[pos];
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == active_quote) {
                quote = null;
            }
            pos += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            pos += 1;
            continue;
        }
        if (c == '#') {
            while (pos < contents.len and contents[pos] != '\n') : (pos += 1) {}
            continue;
        }
        if (matchPolicyCall(contents, pos, "prefix_rule")) |open_index| {
            return .{ .kind = .prefix_rule, .open_index = open_index };
        }
        if (matchPolicyCall(contents, pos, "host_executable")) |open_index| {
            return .{ .kind = .host_executable, .open_index = open_index };
        }
        if (matchPolicyCall(contents, pos, "network_rule")) |open_index| {
            return .{ .kind = .network_rule, .open_index = open_index };
        }
        pos += 1;
    }
    return null;
}

fn matchPolicyCall(contents: []const u8, pos: usize, name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, contents[pos..], name)) return null;
    const before_ok = pos == 0 or !isIdentifierChar(contents[pos - 1]);
    const after_name = pos + name.len;
    const after_ok = after_name >= contents.len or !isIdentifierChar(contents[after_name]);
    if (!before_ok or !after_ok) return null;
    var next = after_name;
    skipWhitespace(contents, &next);
    if (next < contents.len and contents[next] == '(') return next;
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

fn parsePrefixRule(allocator: std.mem.Allocator, body: []const u8) !ParsedPrefixRule {
    var pattern: ?[]PatternToken = null;
    errdefer if (pattern) |owned| deinitPattern(allocator, owned);
    var decision: Decision = .allow;
    var justification: ?[]const u8 = null;
    errdefer if (justification) |owned| allocator.free(owned);
    var match_examples: ?Examples = null;
    errdefer if (match_examples) |owned| freeExamples(allocator, owned);
    var not_match_examples: ?Examples = null;
    errdefer if (not_match_examples) |owned| freeExamples(allocator, owned);

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
        if (std.mem.eql(u8, assignment.key, "match")) {
            if (match_examples != null) return error.DuplicateExecPolicyField;
            match_examples = try parseExamplesValue(allocator, assignment.value);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "not_match")) {
            if (not_match_examples != null) return error.DuplicateExecPolicyField;
            not_match_examples = try parseExamplesValue(allocator, assignment.value);
            continue;
        }
    }

    return .{
        .rule = .{
            .pattern = pattern orelse return error.MissingExecPolicyPattern,
            .decision = decision,
            .justification = justification,
        },
        .match_examples = match_examples,
        .not_match_examples = not_match_examples,
    };
}

fn parseHostExecutable(allocator: std.mem.Allocator, body: []const u8) !HostExecutable {
    var name: ?[]const u8 = null;
    errdefer if (name) |owned| allocator.free(owned);
    var paths: ?[]const []const u8 = null;
    errdefer if (paths) |owned| freeStringList(allocator, owned);

    var pos: usize = 0;
    while (try nextAssignment(body, &pos)) |assignment| {
        if (std.mem.eql(u8, assignment.key, "name")) {
            if (name != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            errdefer allocator.free(parsed);
            try validateHostExecutableName(parsed);
            name = parsed;
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "paths")) {
            if (paths != null) return error.DuplicateExecPolicyField;
            paths = try parseStringListValue(allocator, assignment.value, true);
            continue;
        }
    }

    const host_name = name orelse return error.MissingHostExecutableName;
    const host_paths = paths orelse return error.MissingHostExecutablePaths;
    for (host_paths) |path| {
        try validateHostExecutablePath(host_name, path);
    }
    return .{
        .name = host_name,
        .paths = host_paths,
    };
}

fn validateHostExecutableName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyHostExecutableName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidHostExecutableName;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidHostExecutableName;
}

fn validateHostExecutablePath(name: []const u8, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidHostExecutablePath;
    if (!std.mem.eql(u8, std.fs.path.basename(path), name)) return error.InvalidHostExecutablePath;
}

fn upsertHostExecutable(
    allocator: std.mem.Allocator,
    host_executables: *std.ArrayList(HostExecutable),
    host_executable: HostExecutable,
) !void {
    for (host_executables.items) |*existing| {
        if (std.mem.eql(u8, existing.name, host_executable.name)) {
            existing.deinit(allocator);
            existing.* = host_executable;
            return;
        }
    }
    try host_executables.append(allocator, host_executable);
}

fn parseNetworkRule(allocator: std.mem.Allocator, body: []const u8) !NetworkRule {
    var host: ?[]const u8 = null;
    errdefer if (host) |owned| allocator.free(owned);
    var protocol: ?NetworkRuleProtocol = null;
    var decision: ?Decision = null;
    var justification: ?[]const u8 = null;
    errdefer if (justification) |owned| allocator.free(owned);

    var pos: usize = 0;
    while (try nextAssignment(body, &pos)) |assignment| {
        if (std.mem.eql(u8, assignment.key, "host")) {
            if (host != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            defer allocator.free(parsed);
            host = try normalizeNetworkRuleHost(allocator, parsed);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "protocol")) {
            if (protocol != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            defer allocator.free(parsed);
            protocol = try parseNetworkRuleProtocol(parsed);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "decision")) {
            if (decision != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            defer allocator.free(parsed);
            decision = try parseNetworkRuleDecision(parsed);
            continue;
        }
        if (std.mem.eql(u8, assignment.key, "justification")) {
            if (justification != null) return error.DuplicateExecPolicyField;
            const parsed = try parseOwnedString(allocator, assignment.value);
            errdefer allocator.free(parsed);
            if (std.mem.trim(u8, parsed, " \t\r\n").len == 0) return error.EmptyExecPolicyJustification;
            justification = parsed;
            continue;
        }
    }

    return .{
        .host = host orelse return error.MissingNetworkRuleHost,
        .protocol = protocol orelse return error.MissingNetworkRuleProtocol,
        .decision = decision orelse return error.MissingNetworkRuleDecision,
        .justification = justification,
    };
}

fn parseNetworkRuleProtocol(raw: []const u8) !NetworkRuleProtocol {
    if (std.mem.eql(u8, raw, "http")) return .http;
    if (std.mem.eql(u8, raw, "https")) return .https;
    if (std.mem.eql(u8, raw, "https_connect")) return .https;
    if (std.mem.eql(u8, raw, "http-connect")) return .https;
    if (std.mem.eql(u8, raw, "socks5_tcp")) return .socks5_tcp;
    if (std.mem.eql(u8, raw, "socks5_udp")) return .socks5_udp;
    return error.InvalidNetworkRuleProtocol;
}

fn parseNetworkRuleDecision(raw: []const u8) !Decision {
    if (std.mem.eql(u8, raw, "deny")) return .forbidden;
    return parseDecision(raw);
}

fn normalizeNetworkRuleHost(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var host = std.mem.trim(u8, raw, " \t\r\n");
    if (host.len == 0) return error.EmptyNetworkRuleHost;
    if (std.mem.indexOf(u8, host, "://") != null) return error.InvalidNetworkRuleHost;
    if (std.mem.indexOfScalar(u8, host, '/') != null) return error.InvalidNetworkRuleHost;
    if (std.mem.indexOfScalar(u8, host, '?') != null) return error.InvalidNetworkRuleHost;
    if (std.mem.indexOfScalar(u8, host, '#') != null) return error.InvalidNetworkRuleHost;

    if (host[0] == '[') {
        const close_index = std.mem.indexOfScalar(u8, host, ']') orelse return error.InvalidNetworkRuleHost;
        const rest = host[close_index + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return error.InvalidNetworkRuleHost;
            const port = rest[1..];
            if (port.len == 0 or !allAsciiDigits(port)) return error.InvalidNetworkRuleHost;
        }
        host = host[1..close_index];
    } else if (std.mem.count(u8, host, ":") == 1) {
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
            const candidate = host[0..colon];
            const port = host[colon + 1 ..];
            if (candidate.len > 0 and port.len > 0 and allAsciiDigits(port)) {
                host = candidate;
            }
        }
    }

    host = std.mem.trim(u8, std.mem.trimEnd(u8, host, "."), " \t\r\n");
    if (host.len == 0) return error.EmptyNetworkRuleHost;
    if (std.mem.indexOfScalar(u8, host, '*') != null) return error.WildcardNetworkRuleHost;
    if (containsWhitespace(host)) return error.InvalidNetworkRuleHost;

    const normalized = try allocator.alloc(u8, host.len);
    for (host, 0..) |byte, index| {
        normalized[index] = std.ascii.toLower(byte);
    }
    return normalized;
}

fn allAsciiDigits(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn containsWhitespace(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte)) return true;
    }
    return false;
}

fn validatePendingExamples(
    rules: []const PrefixRule,
    host_executables: []const HostExecutable,
    validations: []const PendingExampleValidation,
) !void {
    for (validations) |validation| {
        const scoped_rules = rules[validation.rule_start..validation.rule_end];
        if (validation.match_examples) |examples| {
            for (examples) |example| {
                if (!anyRuleMatches(scoped_rules, host_executables, example)) return error.ExecPolicyExampleDidNotMatch;
            }
        }
        if (validation.not_match_examples) |examples| {
            for (examples) |example| {
                if (anyRuleMatches(scoped_rules, host_executables, example)) return error.ExecPolicyExampleDidMatch;
            }
        }
    }
}

fn anyRuleMatches(
    rules: []const PrefixRule,
    host_executables: []const HostExecutable,
    command: []const []const u8,
) bool {
    for (rules) |rule| {
        if (ruleMatches(rule, command, null)) return true;
    }
    if (command.len == 0) return false;
    const program = command[0];
    if (!std.fs.path.isAbsolute(program)) return false;
    const basename = std.fs.path.basename(program);
    if (basename.len == 0) return false;
    if (!hostExecutableAllows(host_executables, basename, program)) return false;
    for (rules) |rule| {
        if (ruleMatches(rule, command, basename)) return true;
    }
    return false;
}

fn expectPolicyParseError(
    allocator: std.mem.Allocator,
    expected_error: anyerror,
    contents: []const u8,
) !void {
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);

    try std.testing.expectError(
        expected_error,
        parsePolicy(allocator, contents, &rules, &host_executables, &network_rules),
    );
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
        var token_appended = false;
        errdefer if (!token_appended) token.deinit(allocator);
        try tokens.append(allocator, token);
        token_appended = true;
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
        if (self.input[self.pos] == '[') return .{ .alternatives = try self.parseStringList(false) };

        const string = try self.parseString();
        errdefer self.allocator.free(string);
        const alternatives = try self.allocator.alloc([]const u8, 1);
        alternatives[0] = string;
        return .{ .alternatives = alternatives };
    }

    fn parseStringList(self: *ValueParser, allow_empty: bool) ![]const []const u8 {
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
            var string_appended = false;
            errdefer if (!string_appended) self.allocator.free(string);
            try values.append(self.allocator, string);
            string_appended = true;
            self.skipTrivia();
            if (self.consume(',')) continue;
            if (self.consume(']')) break;
            return error.ExpectedExecPolicyPatternSeparator;
        }
        if (!allow_empty and values.items.len == 0) return error.EmptyExecPolicyAlternative;
        return values.toOwnedSlice(self.allocator);
    }

    fn parseExamples(self: *ValueParser) !?Examples {
        try self.expect('[');
        var examples = std.ArrayList([]const []const u8).empty;
        errdefer {
            for (examples.items) |example| freeStringList(self.allocator, example);
            examples.deinit(self.allocator);
        }
        while (true) {
            self.skipTrivia();
            if (self.consume(']')) break;
            const example = try self.parseExample();
            var example_appended = false;
            errdefer if (!example_appended) freeStringList(self.allocator, example);
            try examples.append(self.allocator, example);
            example_appended = true;
            self.skipTrivia();
            if (self.consume(',')) continue;
            if (self.consume(']')) break;
            return error.ExpectedExecPolicyExampleSeparator;
        }
        if (examples.items.len == 0) {
            examples.deinit(self.allocator);
            return null;
        }
        return try examples.toOwnedSlice(self.allocator);
    }

    fn parseExample(self: *ValueParser) ![]const []const u8 {
        self.skipTrivia();
        if (self.pos >= self.input.len) return error.ExpectedExecPolicyExample;
        if (self.input[self.pos] == '[') return self.parseStringList(false);

        const raw = try self.parseString();
        defer self.allocator.free(raw);
        return parseShellWords(self.allocator, raw);
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

fn parseStringListValue(allocator: std.mem.Allocator, value: []const u8, allow_empty: bool) ![]const []const u8 {
    var parser = ValueParser{ .allocator = allocator, .input = value };
    const strings = try parser.parseStringList(allow_empty);
    errdefer freeStringList(allocator, strings);
    parser.skipTrivia();
    if (!parser.isEof()) return error.UnexpectedExecPolicyStringInput;
    return strings;
}

fn parseExamplesValue(allocator: std.mem.Allocator, value: []const u8) !?Examples {
    var parser = ValueParser{ .allocator = allocator, .input = value };
    const examples = try parser.parseExamples();
    errdefer if (examples) |owned| freeExamples(allocator, owned);
    parser.skipTrivia();
    if (!parser.isEof()) return error.UnexpectedExecPolicyExampleInput;
    return examples;
}

fn parseShellWords(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var words = std.ArrayList([]const u8).empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    var escaped = false;
    var has_token = false;

    for (raw) |byte| {
        if (escaped) {
            try current.append(allocator, byte);
            has_token = true;
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            has_token = true;
            continue;
        }
        if (quote) |active_quote| {
            if (byte == active_quote) {
                quote = null;
            } else {
                try current.append(allocator, byte);
            }
            has_token = true;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            has_token = true;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            if (has_token) {
                try appendShellWord(allocator, &words, current.items);
                current.clearRetainingCapacity();
                has_token = false;
            }
            continue;
        }
        try current.append(allocator, byte);
        has_token = true;
    }

    if (escaped) return error.InvalidExecPolicyExample;
    if (quote != null) return error.InvalidExecPolicyExample;
    if (has_token) try appendShellWord(allocator, &words, current.items);
    if (words.items.len == 0) return error.EmptyExecPolicyExample;
    return words.toOwnedSlice(allocator);
}

fn appendShellWord(allocator: std.mem.Allocator, words: *std.ArrayList([]const u8), word: []const u8) !void {
    const owned = try allocator.dupe(u8, word);
    errdefer allocator.free(owned);
    try words.append(allocator, owned);
}

fn parseDecision(label: []const u8) !Decision {
    if (std.mem.eql(u8, label, "allow")) return .allow;
    if (std.mem.eql(u8, label, "prompt")) return .prompt;
    if (std.mem.eql(u8, label, "forbidden")) return .forbidden;
    return error.UnknownExecPolicyDecision;
}

const EvaluateOptions = struct {
    pretty: bool = false,
    resolve_host_executables: bool = false,
};

fn evaluateRules(
    allocator: std.mem.Allocator,
    rules: []const PrefixRule,
    host_executables: []const HostExecutable,
    command: []const []const u8,
    options: EvaluateOptions,
) ![]const u8 {
    var matches = std.ArrayList(RuleMatch).empty;
    defer matches.deinit(allocator);
    var owned_prefixes = std.ArrayList([]const []const u8).empty;
    defer {
        for (owned_prefixes.items) |prefix| allocator.free(prefix);
        owned_prefixes.deinit(allocator);
    }

    try appendExactMatches(allocator, rules, command, &matches);
    if (matches.items.len == 0 and options.resolve_host_executables) {
        try appendHostExecutableMatches(
            allocator,
            rules,
            host_executables,
            command,
            &matches,
            &owned_prefixes,
        );
    }

    const decision = strictestDecision(matches.items);
    if (options.pretty) return renderPretty(allocator, decision, matches.items);
    return renderCompact(allocator, decision, matches.items);
}

fn appendExactMatches(
    allocator: std.mem.Allocator,
    rules: []const PrefixRule,
    command: []const []const u8,
    matches: *std.ArrayList(RuleMatch),
) !void {
    for (rules) |*rule| {
        if (!ruleMatches(rule.*, command[0..], null)) continue;
        try matches.append(allocator, .{
            .rule = rule,
            .matched_prefix = command[0..rule.pattern.len],
        });
    }
}

fn appendHostExecutableMatches(
    allocator: std.mem.Allocator,
    rules: []const PrefixRule,
    host_executables: []const HostExecutable,
    command: []const []const u8,
    matches: *std.ArrayList(RuleMatch),
    owned_prefixes: *std.ArrayList([]const []const u8),
) !void {
    if (command.len == 0) return;
    const program = command[0];
    if (!std.fs.path.isAbsolute(program)) return;
    const basename = std.fs.path.basename(program);
    if (basename.len == 0) return;
    if (!hostExecutableAllows(host_executables, basename, program)) return;

    for (rules) |*rule| {
        if (!ruleMatches(rule.*, command, basename)) continue;
        const matched_prefix = try allocator.alloc([]const u8, rule.pattern.len);
        errdefer allocator.free(matched_prefix);
        matched_prefix[0] = basename;
        for (1..rule.pattern.len) |index| {
            matched_prefix[index] = command[index];
        }
        try matches.append(allocator, .{
            .rule = rule,
            .matched_prefix = matched_prefix,
            .resolved_program = program,
        });
        try owned_prefixes.append(allocator, matched_prefix);
    }
}

fn hostExecutableAllows(host_executables: []const HostExecutable, basename: []const u8, program: []const u8) bool {
    for (host_executables) |host_executable| {
        if (!std.mem.eql(u8, host_executable.name, basename)) continue;
        for (host_executable.paths) |path| {
            if (std.mem.eql(u8, path, program)) return true;
        }
        return false;
    }
    return true;
}

fn strictestDecision(matches: []const RuleMatch) ?Decision {
    var decision: ?Decision = null;
    for (matches) |match| {
        if (decision == null or match.rule.decision.rank() > decision.?.rank()) {
            decision = match.rule.decision;
        }
    }
    return decision;
}

fn ruleMatches(rule: PrefixRule, command: []const []const u8, resolved_first: ?[]const u8) bool {
    if (rule.pattern.len > command.len) return false;
    if (rule.pattern.len == 0) return false;
    for (rule.pattern, 0..) |token, index| {
        const command_token = if (index == 0) resolved_first orelse command[index] else command[index];
        if (!tokenMatches(token, command_token)) return false;
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
    if (match.resolved_program) |program| {
        try out.appendSlice(allocator, ",\"resolvedProgram\":");
        try appendJsonString(allocator, out, program);
    }
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
    if (match.resolved_program) |program| {
        try out.appendSlice(allocator, ",\n");
        try out.appendSlice(allocator, "        \"resolvedProgram\": ");
        try appendJsonString(allocator, out, program);
    }
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

fn deinitHostExecutables(allocator: std.mem.Allocator, host_executables: []HostExecutable) void {
    for (host_executables) |host_executable| host_executable.deinit(allocator);
}

fn deinitNetworkRules(allocator: std.mem.Allocator, network_rules: []NetworkRule) void {
    for (network_rules) |network_rule| network_rule.deinit(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeExamples(allocator: std.mem.Allocator, examples: Examples) void {
    for (examples) |example| freeStringList(allocator, example);
    allocator.free(examples);
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
        \\                          Match absolute program paths through basename
        \\                          rules, gated by host_executable entries.
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
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
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
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
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
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
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
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"prompt\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"bash\",\"-c\"],\"decision\":\"allow\"}},{\"prefixRuleMatch\":{\"matchedPrefix\":[\"bash\",\"-c\"],\"decision\":\"prompt\"}}]}",
        rendered,
    );
}

test "execpolicy parser validates match and not match examples" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(
        \\    pattern = ["git", "status"],
        \\    match = [["git", "status"], "git 'status'"],
        \\    not_match = [["git", "commit"], "git commit"],
        \\)
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const status = [_][]const u8{ "git", "status" };
    const status_rendered = try evaluateRules(allocator, rules.items, &.{}, status[0..], .{});
    defer allocator.free(status_rendered);
    try std.testing.expectEqualStrings(
        "{\"decision\":\"allow\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"status\"],\"decision\":\"allow\"}}]}",
        status_rendered,
    );

    const commit = [_][]const u8{ "git", "commit" };
    const commit_rendered = try evaluateRules(allocator, rules.items, &.{}, commit[0..], .{});
    defer allocator.free(commit_rendered);
    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", commit_rendered);
}

test "execpolicy parser rejects failing match examples" {
    const allocator = std.testing.allocator;
    try expectPolicyParseError(
        allocator,
        error.ExecPolicyExampleDidNotMatch,
        \\prefix_rule(pattern = ["git", "status"], match = [["git", "commit"]])
        ,
    );
}

test "execpolicy parser validates match examples against declaring rule only" {
    const allocator = std.testing.allocator;
    try expectPolicyParseError(
        allocator,
        error.ExecPolicyExampleDidNotMatch,
        \\prefix_rule(pattern = ["git", "commit"], match = [["git", "status"]])
        \\prefix_rule(pattern = ["git", "status"])
        ,
    );
}

test "execpolicy parser rejects matching not match examples" {
    const allocator = std.testing.allocator;
    try expectPolicyParseError(
        allocator,
        error.ExecPolicyExampleDidMatch,
        \\prefix_rule(pattern = ["git"], not_match = ["git status"])
        ,
    );
}

test "execpolicy parser validates not match examples against declaring rule only" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git", "commit"], not_match = [["git", "status"]])
        \\prefix_rule(pattern = ["git", "status"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    const command = [_][]const u8{ "git", "status" };
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"allow\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"status\"],\"decision\":\"allow\"}}]}",
        rendered,
    );
}

test "execpolicy parser validates examples with host executable resolution" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(
        \\    pattern = ["git", "status"],
        \\    match = [["/usr/bin/git", "status"]],
        \\    not_match = [["/opt/homebrew/bin/git", "status"]],
        \\)
        \\host_executable(name = "git", paths = ["/usr/bin/git"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"allow\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"status\"],\"decision\":\"allow\",\"resolvedProgram\":\"/usr/bin/git\"}}]}",
        rendered,
    );
}

test "execpolicy parser ignores comments and quoted prefix rule text" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\# prefix_rule(pattern = ["git", "push"], decision = "forbidden")
        \\message = "prefix_rule(pattern = [\"rm\"], decision = \"forbidden\")"
        \\prefix_rule(pattern = ["git", "status"], decision = "allow")
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    try parseRules(allocator, rules_bytes, &rules);

    try std.testing.expectEqual(@as(usize, 1), rules.items.len);
    const command = [_][]const u8{ "git", "push" };
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", rendered);
}

test "execpolicy parser accepts and normalizes network rules" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\network_rule(host = "API.GITHUB.COM:443", protocol = "https_connect", decision = "deny")
        \\network_rule(host = "Example.COM.", protocol = "http-connect", decision = "allow")
        \\network_rule(host = "[::1]:8080", protocol = "socks5_udp", decision = "prompt", justification = "ipv6")
        \\prefix_rule(pattern = ["curl"], decision = "prompt")
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    var network_rules = std.ArrayList(NetworkRule).empty;
    defer network_rules.deinit(allocator);
    defer deinitNetworkRules(allocator, network_rules.items);
    try parsePolicy(allocator, rules_bytes, &rules, &host_executables, &network_rules);

    try std.testing.expectEqual(@as(usize, 3), network_rules.items.len);
    try std.testing.expectEqualStrings("api.github.com", network_rules.items[0].host);
    try std.testing.expectEqual(NetworkRuleProtocol.https, network_rules.items[0].protocol);
    try std.testing.expectEqual(Decision.forbidden, network_rules.items[0].decision);
    try std.testing.expectEqualStrings("example.com", network_rules.items[1].host);
    try std.testing.expectEqual(NetworkRuleProtocol.https, network_rules.items[1].protocol);
    try std.testing.expectEqual(Decision.allow, network_rules.items[1].decision);
    try std.testing.expectEqualStrings("::1", network_rules.items[2].host);
    try std.testing.expectEqual(NetworkRuleProtocol.socks5_udp, network_rules.items[2].protocol);
    try std.testing.expectEqual(Decision.prompt, network_rules.items[2].decision);
    try std.testing.expectEqualStrings("ipv6", network_rules.items[2].justification.?);

    const command = [_][]const u8{"curl"};
    const rendered = try evaluateRules(allocator, rules.items, &.{}, command[0..], .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"prompt\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"curl\"],\"decision\":\"prompt\"}}]}",
        rendered,
    );
}

test "execpolicy parser rejects invalid network rules" {
    const allocator = std.testing.allocator;

    try expectPolicyParseError(
        allocator,
        error.WildcardNetworkRuleHost,
        \\network_rule(host = "*", protocol = "http", decision = "allow")
        ,
    );

    try expectPolicyParseError(
        allocator,
        error.InvalidNetworkRuleHost,
        \\network_rule(host = "https://api.github.com", protocol = "https", decision = "allow")
        ,
    );

    try expectPolicyParseError(
        allocator,
        error.InvalidNetworkRuleProtocol,
        \\network_rule(host = "api.github.com", protocol = "ftp", decision = "allow")
        ,
    );
}

test "execpolicy check resolves allowed host executable paths" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git", "status"], decision = "prompt")
        \\host_executable(name = "git", paths = ["/usr/bin/git"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"prompt\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"status\"],\"decision\":\"prompt\",\"resolvedProgram\":\"/usr/bin/git\"}}]}",
        rendered,
    );
}

test "execpolicy check allows basename fallback without host executable mapping" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git", "status"], decision = "prompt")
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"prompt\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"git\",\"status\"],\"decision\":\"prompt\",\"resolvedProgram\":\"/usr/bin/git\"}}]}",
        rendered,
    );
}

test "execpolicy check blocks basename fallback for explicit empty host mapping" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git", "status"], decision = "prompt")
        \\host_executable(name = "git", paths = [])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", rendered);
}

test "execpolicy check ignores host paths outside explicit allowlist" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git"], decision = "prompt")
        \\host_executable(name = "git", paths = ["/usr/bin/git"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/opt/homebrew/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", rendered);
}

test "execpolicy parser keeps the last host executable definition" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["git"], decision = "prompt")
        \\host_executable(name = "git", paths = ["/usr/bin/git"])
        \\host_executable(name = "git", paths = ["/opt/homebrew/bin/git"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("{\"matchedRules\":[]}", rendered);
}

test "execpolicy check keeps exact absolute matches ahead of host fallback" {
    const allocator = std.testing.allocator;
    const rules_bytes =
        \\prefix_rule(pattern = ["/usr/bin/git"], decision = "allow")
        \\prefix_rule(pattern = ["git"], decision = "prompt")
        \\host_executable(name = "git", paths = ["/usr/bin/git"])
    ;
    var rules = std.ArrayList(PrefixRule).empty;
    defer rules.deinit(allocator);
    defer deinitRules(allocator, rules.items);
    var host_executables = std.ArrayList(HostExecutable).empty;
    defer host_executables.deinit(allocator);
    defer deinitHostExecutables(allocator, host_executables.items);
    try parsePolicyWithHosts(allocator, rules_bytes, &rules, &host_executables);

    const command = [_][]const u8{ "/usr/bin/git", "status" };
    const rendered = try evaluateRules(
        allocator,
        rules.items,
        host_executables.items,
        command[0..],
        .{ .resolve_host_executables = true },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"decision\":\"allow\",\"matchedRules\":[{\"prefixRuleMatch\":{\"matchedPrefix\":[\"/usr/bin/git\"],\"decision\":\"allow\"}}]}",
        rendered,
    );
}
