const std = @import("std");

const config = @import("config.zig");
const features_cmd = @import("features_cmd.zig");

const version = "0.0.1";

const Command = enum {
    tui,
    exec,
    status,
    list,
    apply,
    diff,

    fn label(self: Command) []const u8 {
        return switch (self) {
            .tui => "cloud",
            .exec => "cloud exec",
            .status => "cloud status",
            .list => "cloud list",
            .apply => "cloud apply",
            .diff => "cloud diff",
        };
    }
};

const ExecOptions = struct {
    query: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    attempts: usize = 1,
    attempts_provided: bool = false,
    branch: ?[]const u8 = null,
};

const ListOptions = struct {
    environment: ?[]const u8 = null,
    limit: i64 = 20,
    limit_provided: bool = false,
    cursor: ?[]const u8 = null,
    json: bool = false,
    json_provided: bool = false,
};

const TaskAttemptOptions = struct {
    task_id: ?[]const u8 = null,
    attempt: ?usize = null,
};

pub const ParsedOptions = struct {
    command: Command = .tui,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    exec: ExecOptions = .{},
    status_task_id: ?[]const u8 = null,
    list: ListOptions = .{},
    task_attempt: TaskAttemptOptions = .{},

    pub fn deinit(self: *ParsedOptions, allocator: std.mem.Allocator) void {
        self.feature_overrides.deinit(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    if (try maybePrintHelpOrVersion(allocator, raw_args.items)) return;

    var parsed = try parseArgSlice(allocator, raw_args.items);
    defer parsed.deinit(allocator);

    std.debug.print(
        "codex-zig {s} parsed Rust-compatible options, but Codex Cloud tasks are not implemented yet\n",
        .{parsed.command.label()},
    );
    return error.CloudCommandNotImplemented;
}

const ParseMode = struct {
    validate_required: bool = true,
    validate_global_values: bool = true,
};

fn maybePrintHelpOrVersion(allocator: std.mem.Allocator, args: []const []const u8) !bool {
    if (args.len == 0) return false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "help")) {
            var parsed = parseArgSliceForHelp(allocator, args[0..index]) catch continue;
            defer parsed.deinit(allocator);
            if (parsed.command != .tui) continue;
            const target_args = args[index + 1 ..];
            if (target_args.len == 0) {
                printHelp();
                return true;
            }
            if (target_args.len == 1) {
                try printSubcommandHelp(target_args[0]);
                return true;
            }
            return error.UnexpectedCloudHelpArgument;
        }
        if (isHelpFlag(arg)) {
            var parsed = parseArgSliceForHelp(allocator, args[0..index]) catch return false;
            defer parsed.deinit(allocator);
            printHelpForCommand(parsed.command);
            return true;
        }
        if (isVersionFlag(arg)) {
            var parsed = parseArgSliceForHelp(allocator, args[0..index]) catch return false;
            defer parsed.deinit(allocator);
            if (parsed.command != .tui) return false;
            printVersion();
            return true;
        }
    }
    return false;
}

fn parseArgSlice(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    return parseArgSliceWithMode(allocator, args, .{});
}

fn parseArgSliceForHelp(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    return parseArgSliceWithMode(allocator, args, .{
        .validate_required = false,
        .validate_global_values = false,
    });
}

fn parseArgSliceWithMode(allocator: std.mem.Allocator, args: []const []const u8, mode: ParseMode) !ParsedOptions {
    var parsed = ParsedOptions{};
    errdefer parsed.deinit(allocator);

    var profile: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try parseGlobalOption(allocator, args, &index, &parsed, &profile, mode)) continue;
        if (std.mem.eql(u8, arg, "--")) return error.UnknownCloudSubcommand;
        if (subcommandFromArg(arg)) |command| {
            parsed.command = command;
            index += 1;
            try parseSubcommandArgs(allocator, args, &index, &parsed, &profile, mode);
            return parsed;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
        return error.UnknownCloudSubcommand;
    }
    return parsed;
}

fn parseSubcommandArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    parsed: *ParsedOptions,
    profile: *?[]const u8,
    mode: ParseMode,
) !void {
    while (index.* < args.len) : (index.* += 1) {
        if (try parseGlobalOption(allocator, args, index, parsed, profile, mode)) continue;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--")) {
            index.* += 1;
            try parsePositionalOnlyArgs(args, index, parsed);
            break;
        }
        switch (parsed.command) {
            .tui => unreachable,
            .exec => try parseExecArg(args, index, parsed, arg),
            .status => try parseStatusArg(parsed, arg),
            .list => try parseListArg(args, index, parsed, arg),
            .apply, .diff => try parseTaskAttemptArg(args, index, parsed, arg),
        }
    }

    if (!mode.validate_required) return;
    switch (parsed.command) {
        .tui => {},
        .exec => {
            if (parsed.exec.environment == null) return error.MissingCloudEnvironment;
        },
        .status => {
            if (parsed.status_task_id == null) return error.MissingCloudTaskId;
        },
        .list => {},
        .apply, .diff => {
            if (parsed.task_attempt.task_id == null) return error.MissingCloudTaskId;
        },
    }
}

fn parsePositionalOnlyArgs(args: []const []const u8, index: *usize, parsed: *ParsedOptions) !void {
    while (index.* < args.len) : (index.* += 1) {
        const arg = args[index.*];
        switch (parsed.command) {
            .tui, .list => return error.UnexpectedCloudArgument,
            .exec => try parseExecPositional(parsed, arg),
            .status => try parseStatusPositional(parsed, arg),
            .apply, .diff => try parseTaskAttemptPositional(parsed, arg),
        }
    }
}

fn parseGlobalOption(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    parsed: *ParsedOptions,
    profile: *?[]const u8,
    mode: ParseMode,
) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
        const value = try takeValue(args, index, error.MissingConfigOptionValue);
        if (mode.validate_global_values) {
            try config.applyRawConfigOverride(&parsed.runtime_overrides, profile, value);
        }
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--config=")) {
        if (mode.validate_global_values) {
            try config.applyRawConfigOverride(&parsed.runtime_overrides, profile, arg["--config=".len..]);
        }
        return true;
    }
    if (std.mem.eql(u8, arg, "--enable")) {
        const feature = try takeValue(args, index, error.MissingFeatureName);
        if (mode.validate_global_values) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, feature, true);
        }
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--enable=")) {
        if (mode.validate_global_values) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--enable=".len..], true);
        }
        return true;
    }
    if (std.mem.eql(u8, arg, "--disable")) {
        const feature = try takeValue(args, index, error.MissingFeatureName);
        if (mode.validate_global_values) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, feature, false);
        }
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--disable=")) {
        if (mode.validate_global_values) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--disable=".len..], false);
        }
        return true;
    }
    return false;
}

fn parseExecArg(args: []const []const u8, index: *usize, parsed: *ParsedOptions, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "--env")) {
        if (parsed.exec.environment != null) return error.DuplicateCloudEnvironment;
        parsed.exec.environment = try takeValue(args, index, error.MissingCloudEnvironment);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--env=")) {
        if (parsed.exec.environment != null) return error.DuplicateCloudEnvironment;
        parsed.exec.environment = arg["--env=".len..];
        return;
    }
    if (std.mem.eql(u8, arg, "--attempts")) {
        if (parsed.exec.attempts_provided) return error.DuplicateCloudAttempts;
        parsed.exec.attempts_provided = true;
        parsed.exec.attempts = try parseAttempts(try takeValue(args, index, error.MissingCloudAttempts));
        return;
    }
    if (std.mem.startsWith(u8, arg, "--attempts=")) {
        if (parsed.exec.attempts_provided) return error.DuplicateCloudAttempts;
        parsed.exec.attempts_provided = true;
        parsed.exec.attempts = try parseAttempts(arg["--attempts=".len..]);
        return;
    }
    if (std.mem.eql(u8, arg, "--branch")) {
        if (parsed.exec.branch != null) return error.DuplicateCloudBranch;
        parsed.exec.branch = try takeValue(args, index, error.MissingCloudBranch);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--branch=")) {
        if (parsed.exec.branch != null) return error.DuplicateCloudBranch;
        parsed.exec.branch = arg["--branch=".len..];
        return;
    }
    if (std.mem.eql(u8, arg, "-")) {
        try parseExecPositional(parsed, arg);
        return;
    }
    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
    try parseExecPositional(parsed, arg);
}

fn parseExecPositional(parsed: *ParsedOptions, arg: []const u8) !void {
    if (parsed.exec.query != null) return error.UnexpectedCloudArgument;
    parsed.exec.query = arg;
}

fn parseStatusArg(parsed: *ParsedOptions, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "-")) {
        try parseStatusPositional(parsed, arg);
        return;
    }
    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
    try parseStatusPositional(parsed, arg);
}

fn parseStatusPositional(parsed: *ParsedOptions, arg: []const u8) !void {
    if (parsed.status_task_id != null) return error.UnexpectedCloudArgument;
    parsed.status_task_id = arg;
}

fn parseListArg(args: []const []const u8, index: *usize, parsed: *ParsedOptions, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "--env")) {
        if (parsed.list.environment != null) return error.DuplicateCloudEnvironment;
        parsed.list.environment = try takeValue(args, index, error.MissingCloudEnvironment);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--env=")) {
        if (parsed.list.environment != null) return error.DuplicateCloudEnvironment;
        parsed.list.environment = arg["--env=".len..];
        return;
    }
    if (std.mem.eql(u8, arg, "--limit")) {
        if (parsed.list.limit_provided) return error.DuplicateCloudLimit;
        parsed.list.limit_provided = true;
        parsed.list.limit = try parseLimit(try takeValue(args, index, error.MissingCloudLimit));
        return;
    }
    if (std.mem.startsWith(u8, arg, "--limit=")) {
        if (parsed.list.limit_provided) return error.DuplicateCloudLimit;
        parsed.list.limit_provided = true;
        parsed.list.limit = try parseLimit(arg["--limit=".len..]);
        return;
    }
    if (std.mem.eql(u8, arg, "--cursor")) {
        if (parsed.list.cursor != null) return error.DuplicateCloudCursor;
        parsed.list.cursor = try takeValue(args, index, error.MissingCloudCursor);
        return;
    }
    if (std.mem.startsWith(u8, arg, "--cursor=")) {
        if (parsed.list.cursor != null) return error.DuplicateCloudCursor;
        parsed.list.cursor = arg["--cursor=".len..];
        return;
    }
    if (std.mem.eql(u8, arg, "--json")) {
        if (parsed.list.json_provided) return error.DuplicateCloudJson;
        parsed.list.json_provided = true;
        parsed.list.json = true;
        return;
    }
    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
    return error.UnexpectedCloudArgument;
}

fn parseTaskAttemptArg(args: []const []const u8, index: *usize, parsed: *ParsedOptions, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "--attempt")) {
        if (parsed.task_attempt.attempt != null) return error.DuplicateCloudAttempt;
        parsed.task_attempt.attempt = try parseAttempts(try takeValue(args, index, error.MissingCloudAttempt));
        return;
    }
    if (std.mem.startsWith(u8, arg, "--attempt=")) {
        if (parsed.task_attempt.attempt != null) return error.DuplicateCloudAttempt;
        parsed.task_attempt.attempt = try parseAttempts(arg["--attempt=".len..]);
        return;
    }
    if (std.mem.eql(u8, arg, "-")) {
        try parseTaskAttemptPositional(parsed, arg);
        return;
    }
    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
    try parseTaskAttemptPositional(parsed, arg);
}

fn parseTaskAttemptPositional(parsed: *ParsedOptions, arg: []const u8) !void {
    if (parsed.task_attempt.task_id != null) return error.UnexpectedCloudArgument;
    parsed.task_attempt.task_id = arg;
}

fn takeValue(args: []const []const u8, index: *usize, err: anyerror) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return err;
    if (std.mem.startsWith(u8, args[index.*], "-") and !std.mem.eql(u8, args[index.*], "-")) return err;
    return args[index.*];
}

fn parseAttempts(value: []const u8) !usize {
    const digits = if (value.len > 1 and value[0] == '+') value[1..] else value;
    const parsed = std.fmt.parseUnsigned(usize, digits, 10) catch return error.InvalidCloudAttempts;
    if (parsed < 1 or parsed > 4) return error.InvalidCloudAttempts;
    return parsed;
}

fn parseLimit(value: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidCloudLimit;
    if (parsed < 1 or parsed > 20) return error.InvalidCloudLimit;
    return parsed;
}

fn subcommandFromArg(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "exec")) return .exec;
    if (std.mem.eql(u8, arg, "status")) return .status;
    if (std.mem.eql(u8, arg, "list")) return .list;
    if (std.mem.eql(u8, arg, "apply")) return .apply;
    if (std.mem.eql(u8, arg, "diff")) return .diff;
    return null;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

pub fn printHelp() void {
    std.debug.print(
        \\[EXPERIMENTAL] Browse tasks from Codex Cloud and apply changes locally
        \\
        \\Usage:
        \\  codex-zig cloud [OPTIONS] [COMMAND]
        \\
        \\Commands:
        \\  exec    Submit a new Codex Cloud task without launching the TUI
        \\  status  Show the status of a Codex Cloud task
        \\  list    List Codex Cloud tasks
        \\  apply   Apply the diff for a Codex Cloud task locally
        \\  diff    Show the unified diff for a Codex Cloud task
        \\  help    Print this message or the help of the given subcommand(s)
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\          Override a configuration value that would otherwise be loaded
        \\          from ~/.codex/config.toml. Dotted paths override nested values.
        \\
        \\      --enable <FEATURE>
        \\          Enable a feature for this invocation.
        \\
        \\      --disable <FEATURE>
        \\          Disable a feature for this invocation.
        \\
        \\  -h, --help
        \\          Print help.
        \\
        \\  -V, --version
        \\          Print version.
        \\
    , .{});
}

fn printSubcommandHelp(command: []const u8) !void {
    const parsed = subcommandFromArg(command) orelse return error.UnknownCloudSubcommand;
    printHelpForCommand(parsed);
}

fn printHelpForCommand(command: Command) void {
    switch (command) {
        .tui => printHelp(),
        .exec => std.debug.print(
            \\Submit a new Codex Cloud task without launching the TUI
            \\
            \\Usage:
            \\  codex-zig cloud exec [OPTIONS] --env <ENV_ID> [QUERY]
            \\
            \\Arguments:
            \\  [QUERY]                 Task prompt to run in Codex Cloud
            \\
            \\Options:
            \\      --env <ENV_ID>      Target environment identifier
            \\      --attempts <N>      Number of assistant attempts (best-of-N) [default: 1]
            \\      --branch <BRANCH>   Git branch to run in Codex Cloud
            \\  -c, --config <key=value>
            \\      --enable <FEATURE>
            \\      --disable <FEATURE>
            \\  -h, --help              Print help.
            \\
        , .{}),
        .status => std.debug.print(
            \\Show the status of a Codex Cloud task
            \\
            \\Usage:
            \\  codex-zig cloud status [OPTIONS] <TASK_ID>
            \\
            \\Arguments:
            \\  <TASK_ID>               Codex Cloud task identifier to inspect
            \\
            \\Options:
            \\  -c, --config <key=value>
            \\      --enable <FEATURE>
            \\      --disable <FEATURE>
            \\  -h, --help              Print help.
            \\
        , .{}),
        .list => std.debug.print(
            \\List Codex Cloud tasks
            \\
            \\Usage:
            \\  codex-zig cloud list [OPTIONS]
            \\
            \\Options:
            \\      --env <ENV_ID>      Filter tasks by environment identifier
            \\      --limit <N>         Maximum number of tasks to return (1-20) [default: 20]
            \\      --cursor <CURSOR>   Pagination cursor returned by a previous call
            \\      --json              Emit JSON instead of plain text
            \\  -c, --config <key=value>
            \\      --enable <FEATURE>
            \\      --disable <FEATURE>
            \\  -h, --help              Print help.
            \\
        , .{}),
        .apply => std.debug.print(
            \\Apply the diff for a Codex Cloud task locally
            \\
            \\Usage:
            \\  codex-zig cloud apply [OPTIONS] <TASK_ID>
            \\
            \\Arguments:
            \\  <TASK_ID>               Codex Cloud task identifier to apply
            \\
            \\Options:
            \\      --attempt <N>       Attempt number to apply (1-based)
            \\  -c, --config <key=value>
            \\      --enable <FEATURE>
            \\      --disable <FEATURE>
            \\  -h, --help              Print help.
            \\
        , .{}),
        .diff => std.debug.print(
            \\Show the unified diff for a Codex Cloud task
            \\
            \\Usage:
            \\  codex-zig cloud diff [OPTIONS] <TASK_ID>
            \\
            \\Arguments:
            \\  <TASK_ID>               Codex Cloud task identifier to display
            \\
            \\Options:
            \\      --attempt <N>       Attempt number to display (1-based)
            \\  -c, --config <key=value>
            \\      --enable <FEATURE>
            \\      --disable <FEATURE>
            \\  -h, --help              Print help.
            \\
        , .{}),
    }
}

fn printVersion() void {
    std.debug.print("codex-zig-cloud {s}\n", .{version});
}

test "cloud command parses exec options" {
    const allocator = std.testing.allocator;
    const raw_args = [_][]const u8{
        "--enable",
        "goals",
        "exec",
        "--env",
        "env-id",
        "--attempts=4",
        "--branch",
        "feature",
        "write tests",
    };
    var parsed = try parseArgSlice(allocator, raw_args[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Command.exec, parsed.command);
    try std.testing.expectEqualStrings("env-id", parsed.exec.environment.?);
    try std.testing.expectEqual(@as(usize, 4), parsed.exec.attempts);
    try std.testing.expectEqualStrings("feature", parsed.exec.branch.?);
    try std.testing.expectEqualStrings("write tests", parsed.exec.query.?);
    try std.testing.expectEqual(true, parsed.feature_overrides.get("goals").?);
}

test "cloud command validates attempts and list limits" {
    const allocator = std.testing.allocator;
    const bad_attempts = [_][]const u8{ "exec", "--env", "env-id", "--attempts", "5" };
    try std.testing.expectError(error.InvalidCloudAttempts, parseArgSlice(allocator, bad_attempts[0..]));

    const bad_limit = [_][]const u8{ "list", "--limit=21" };
    try std.testing.expectError(error.InvalidCloudLimit, parseArgSlice(allocator, bad_limit[0..]));

    const plus_attempts = [_][]const u8{ "exec", "--env", "env-id", "--attempts", "+1" };
    var parsed = try parseArgSlice(allocator, plus_attempts[0..]);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.exec.attempts);
}

test "cloud command parses task subcommands" {
    const allocator = std.testing.allocator;

    const status_args = [_][]const u8{ "status", "task-1" };
    var status = try parseArgSlice(allocator, status_args[0..]);
    defer status.deinit(allocator);
    try std.testing.expectEqual(Command.status, status.command);
    try std.testing.expectEqualStrings("task-1", status.status_task_id.?);

    const diff_args = [_][]const u8{ "diff", "--attempt=2", "task-2" };
    var diff = try parseArgSlice(allocator, diff_args[0..]);
    defer diff.deinit(allocator);
    try std.testing.expectEqual(Command.diff, diff.command);
    try std.testing.expectEqual(@as(usize, 2), diff.task_attempt.attempt.?);
    try std.testing.expectEqualStrings("task-2", diff.task_attempt.task_id.?);
}

test "cloud command accepts single dash positionals" {
    const allocator = std.testing.allocator;

    const exec_args = [_][]const u8{ "exec", "--env", "env-id", "-" };
    var exec_parsed = try parseArgSlice(allocator, exec_args[0..]);
    defer exec_parsed.deinit(allocator);
    try std.testing.expectEqualStrings("-", exec_parsed.exec.query.?);

    const status_args = [_][]const u8{ "status", "-" };
    var status = try parseArgSlice(allocator, status_args[0..]);
    defer status.deinit(allocator);
    try std.testing.expectEqualStrings("-", status.status_task_id.?);
}

test "cloud command rejects missing required values" {
    const allocator = std.testing.allocator;

    const missing_env = [_][]const u8{ "exec", "prompt" };
    try std.testing.expectError(error.MissingCloudEnvironment, parseArgSlice(allocator, missing_env[0..]));

    const missing_task = [_][]const u8{"apply"};
    try std.testing.expectError(error.MissingCloudTaskId, parseArgSlice(allocator, missing_task[0..]));
}

test "cloud command honors terminator for dash-prefixed positionals" {
    const allocator = std.testing.allocator;

    const exec_args = [_][]const u8{ "exec", "--env", "env-id", "--", "--fix" };
    var exec_parsed = try parseArgSlice(allocator, exec_args[0..]);
    defer exec_parsed.deinit(allocator);
    try std.testing.expectEqual(Command.exec, exec_parsed.command);
    try std.testing.expectEqualStrings("--fix", exec_parsed.exec.query.?);

    const status_args = [_][]const u8{ "status", "--", "--task" };
    var status = try parseArgSlice(allocator, status_args[0..]);
    defer status.deinit(allocator);
    try std.testing.expectEqual(Command.status, status.command);
    try std.testing.expectEqualStrings("--task", status.status_task_id.?);
}

test "cloud command rejects option-looking missing values" {
    const allocator = std.testing.allocator;

    const missing_env = [_][]const u8{ "exec", "--env", "--attempts", "2" };
    try std.testing.expectError(error.MissingCloudEnvironment, parseArgSlice(allocator, missing_env[0..]));

    const missing_limit = [_][]const u8{ "list", "--limit", "--json" };
    try std.testing.expectError(error.MissingCloudLimit, parseArgSlice(allocator, missing_limit[0..]));
}

test "cloud command rejects duplicate singleton options" {
    const allocator = std.testing.allocator;

    const duplicate_env = [_][]const u8{ "exec", "--env", "one", "--env", "two" };
    try std.testing.expectError(error.DuplicateCloudEnvironment, parseArgSlice(allocator, duplicate_env[0..]));

    const duplicate_json = [_][]const u8{ "list", "--json", "--json" };
    try std.testing.expectError(error.DuplicateCloudJson, parseArgSlice(allocator, duplicate_json[0..]));
}

test "cloud help scan skips only real option values" {
    const allocator = std.testing.allocator;

    const missing_value_before_help = [_][]const u8{ "exec", "--env", "--attempts", "2", "--help" };
    try std.testing.expect(!try maybePrintHelpOrVersion(allocator, missing_value_before_help[0..]));

    const invalid_attempt_before_help = [_][]const u8{ "exec", "--env", "env-id", "--attempts", "5", "--help" };
    try std.testing.expect(!try maybePrintHelpOrVersion(allocator, invalid_attempt_before_help[0..]));

    const extra_arg_before_help = [_][]const u8{ "status", "task-id", "extra", "--help" };
    try std.testing.expect(!try maybePrintHelpOrVersion(allocator, extra_arg_before_help[0..]));
}
