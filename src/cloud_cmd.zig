const std = @import("std");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const features_cmd = @import("features_cmd.zig");
const git_apply = @import("git_apply.zig");

const version = "0.0.1";
const default_cloud_base_url = "https://chatgpt.com/backend-api/codex";

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
    profile: ?[]const u8 = null,
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

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    return runWithOptions(allocator, args, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    if (try maybePrintHelpOrVersion(allocator, raw_args.items)) return;

    var parsed = try parseArgSlice(allocator, raw_args.items);
    defer parsed.deinit(allocator);
    if (parsed.profile == null) parsed.profile = options.profile;
    parsed.runtime_overrides = mergeRuntimeOverrides(options.runtime_overrides, parsed.runtime_overrides);

    switch (parsed.command) {
        .exec => return runExec(allocator, parsed),
        .list => return runList(allocator, parsed),
        .status => return runStatus(allocator, parsed),
        .apply => return runApply(allocator, parsed),
        .diff => return runDiff(allocator, parsed),
        .tui => return reportRuntimeNotImplemented(parsed.command),
    }
}

fn mergeRuntimeOverrides(base: config.RuntimeOverrides, command: config.RuntimeOverrides) config.RuntimeOverrides {
    var merged = base;
    if (command.model) |value| merged.model = value;
    if (command.openai_base_url) |value| merged.openai_base_url = value;
    if (command.chatgpt_base_url) |value| merged.chatgpt_base_url = value;
    if (command.oss_provider) |value| merged.oss_provider = value;
    if (command.approval_policy) |value| merged.approval_policy = value;
    if (command.sandbox_mode) |value| merged.sandbox_mode = value;
    if (command.web_search_mode) |value| merged.web_search_mode = value;
    if (command.service_tier) |value| merged.service_tier = value;
    if (command.model_reasoning_summary) |value| merged.model_reasoning_summary = value;
    if (command.syntax_theme) |value| merged.syntax_theme = value;
    if (command.personality) |value| merged.personality = value;
    if (command.tui_alternate_screen) |value| merged.tui_alternate_screen = value;
    return merged;
}

const TaskStatus = enum {
    pending,
    ready,
    applied,
    err,

    fn display(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "PENDING",
            .ready => "READY",
            .applied => "APPLIED",
            .err => "ERROR",
        };
    }

    fn jsonLabel(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .ready => "ready",
            .applied => "applied",
            .err => "error",
        };
    }
};

const DiffSummary = struct {
    files_changed: usize = 0,
    lines_added: usize = 0,
    lines_removed: usize = 0,
};

const TaskSummary = struct {
    id: []const u8,
    title: []const u8,
    status: TaskStatus,
    updated_at: f64,
    environment_id: ?[]const u8 = null,
    environment_label: ?[]const u8 = null,
    summary: DiffSummary = .{},
    is_review: bool = false,
    attempt_total: ?usize = null,

    fn deinit(self: TaskSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.environment_id) |value| allocator.free(value);
        if (self.environment_label) |value| allocator.free(value);
    }
};

const TaskListPage = struct {
    tasks: std.ArrayList(TaskSummary) = .empty,
    cursor: ?[]const u8 = null,

    fn deinit(self: *TaskListPage, allocator: std.mem.Allocator) void {
        for (self.tasks.items) |task| task.deinit(allocator);
        self.tasks.deinit(allocator);
        if (self.cursor) |cursor| allocator.free(cursor);
    }
};

const CloudRuntime = struct {
    cfg: config.Config,
    credentials: auth.Credentials,
    base_url: []const u8,

    fn deinit(self: *CloudRuntime, allocator: std.mem.Allocator) void {
        self.cfg.deinit(allocator);
        self.credentials.deinit(allocator);
        allocator.free(self.base_url);
    }
};

fn reportRuntimeNotImplemented(command: Command) !void {
    std.debug.print(
        "codex-zig {s} parsed Rust-compatible options, but Codex Cloud tasks are not implemented yet\n",
        .{command.label()},
    );
    return error.CloudCommandNotImplemented;
}

fn runExec(allocator: std.mem.Allocator, parsed: ParsedOptions) !void {
    const raw_environment = parsed.exec.environment orelse return error.MissingCloudEnvironment;
    const environment = std.mem.trim(u8, raw_environment, " \t\r\n");
    if (environment.len == 0) return error.MissingCloudEnvironment;

    const prompt = try resolveExecPrompt(allocator, parsed.exec.query);
    defer allocator.free(prompt);

    const git_ref = try resolveExecGitRef(allocator, parsed.exec.branch);
    defer allocator.free(git_ref);

    const starting_diff = try env.getOwned(allocator, "CODEX_STARTING_DIFF");
    defer if (starting_diff) |value| allocator.free(value);
    const body = try buildCreateTaskBody(allocator, environment, prompt, git_ref, parsed.exec.attempts, starting_diff);
    defer allocator.free(body);

    var runtime = try initRuntime(allocator, parsed);
    defer runtime.deinit(allocator);

    const url = try buildTasksCollectionUrl(allocator, runtime.base_url);
    defer allocator.free(url);
    const response = try postCloudTasks(allocator, runtime, url, body);
    defer allocator.free(response);

    const task_id = try parseCreatedTaskId(allocator, response);
    defer allocator.free(task_id);
    const browser_url = try taskUrl(allocator, runtime.base_url, task_id);
    defer allocator.free(browser_url);

    const rendered = try std.fmt.allocPrint(allocator, "{s}\n", .{browser_url});
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
}

fn runList(allocator: std.mem.Allocator, parsed: ParsedOptions) !void {
    var runtime = try initRuntime(allocator, parsed);
    defer runtime.deinit(allocator);

    const url = try buildListUrl(allocator, runtime.base_url, parsed.list);
    defer allocator.free(url);
    const body = try fetchCloudTasks(allocator, runtime, url);
    defer allocator.free(body);

    var page = try parseTaskListPage(allocator, body);
    defer page.deinit(allocator);

    if (parsed.list.json) {
        const rendered = try renderTaskListJson(allocator, runtime.base_url, page);
        defer allocator.free(rendered);
        try cli_utils.writeStdout(rendered);
        return;
    }

    const rendered = try renderTaskList(allocator, runtime.base_url, page);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
}

fn runStatus(allocator: std.mem.Allocator, parsed: ParsedOptions) !void {
    const raw_task_id = parsed.status_task_id orelse return error.MissingCloudTaskId;
    const task_id = try normalizeTaskId(allocator, raw_task_id);
    defer allocator.free(task_id);

    var runtime = try initRuntime(allocator, parsed);
    defer runtime.deinit(allocator);

    const url = try buildTaskUrl(allocator, runtime.base_url, task_id);
    defer allocator.free(url);
    const body = try fetchCloudTasks(allocator, runtime, url);
    defer allocator.free(body);

    var task = try parseTaskDetailsSummary(allocator, task_id, body);
    defer task.deinit(allocator);

    const rendered = try renderTaskStatus(allocator, task, false);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);

    if (task.status != .ready) return error.CloudTaskNotReady;
}

fn runDiff(allocator: std.mem.Allocator, parsed: ParsedOptions) !void {
    const raw_task_id = parsed.task_attempt.task_id orelse return error.MissingCloudTaskId;
    if (parsed.task_attempt.attempt) |attempt| {
        if (attempt != 1) return error.CloudAttemptRuntimeUnsupported;
    }
    const task_id = try normalizeTaskId(allocator, raw_task_id);
    defer allocator.free(task_id);

    var runtime = try initRuntime(allocator, parsed);
    defer runtime.deinit(allocator);

    const url = try buildTaskUrl(allocator, runtime.base_url, task_id);
    defer allocator.free(url);
    const body = try fetchCloudTasks(allocator, runtime, url);
    defer allocator.free(body);

    const diff = try extractUnifiedDiffForAttempt(allocator, body, 1);
    defer allocator.free(diff);
    try cli_utils.writeStdout(diff);
}

fn runApply(allocator: std.mem.Allocator, parsed: ParsedOptions) !void {
    const raw_task_id = parsed.task_attempt.task_id orelse return error.MissingCloudTaskId;
    if (parsed.task_attempt.attempt) |attempt| {
        if (attempt != 1) return error.CloudAttemptRuntimeUnsupported;
    }
    const task_id = try normalizeTaskId(allocator, raw_task_id);
    defer allocator.free(task_id);

    var runtime = try initRuntime(allocator, parsed);
    defer runtime.deinit(allocator);

    const url = try buildTaskUrl(allocator, runtime.base_url, task_id);
    defer allocator.free(url);
    const body = try fetchCloudTasks(allocator, runtime, url);
    defer allocator.free(body);

    const diff = try extractUnifiedDiffForAttempt(allocator, body, 1);
    defer allocator.free(diff);
    if (!git_apply.isUnifiedDiff(diff)) return error.InvalidCloudTaskDiff;

    var result = try git_apply.applyUnifiedDiff(allocator, diff);
    defer result.deinit(allocator);

    try cli_utils.writeStdout(result.stdout);
    try cli_utils.writeStderr(result.stderr);

    const summary = diffSummaryFromDiff(diff);
    if (result.exit_code == 0) {
        const message = try std.fmt.allocPrint(
            allocator,
            "Applied task {s} locally ({d} file{s})\n",
            .{ task_id, summary.files_changed, if (summary.files_changed == 1) "" else "s" },
        );
        defer allocator.free(message);
        try cli_utils.writeStdout(message);
        return;
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "Apply failed for task {s} ({d} file{s})\n",
        .{ task_id, summary.files_changed, if (summary.files_changed == 1) "" else "s" },
    );
    defer allocator.free(message);
    try cli_utils.writeStdout(message);
    return error.CloudTaskApplyFailed;
}

fn resolveExecPrompt(allocator: std.mem.Allocator, query: ?[]const u8) ![]const u8 {
    if (query) |value| {
        if (!std.mem.eql(u8, value, "-")) return allocator.dupe(u8, value);
    } else if (isStdinTty()) {
        return error.MissingCloudQuery;
    } else {
        try cli_utils.writeStderr("Reading query from stdin...\n");
    }

    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdin_text = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stdin_text);
    if (std.mem.trim(u8, stdin_text, " \t\r\n").len == 0) {
        allocator.free(stdin_text);
        return error.MissingCloudQuery;
    }
    return stdin_text;
}

fn isStdinTty() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.File.stdin().isTty(io) catch false;
}

fn resolveExecGitRef(allocator: std.mem.Allocator, branch_override: ?[]const u8) ![]const u8 {
    if (branch_override) |branch| {
        const trimmed = std.mem.trim(u8, branch, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }

    const current_branch = try currentGitBranch(allocator);
    defer if (current_branch) |branch| allocator.free(branch);
    const default_branch = if (current_branch == null) try defaultGitBranch(allocator) else null;
    defer if (default_branch) |branch| allocator.free(branch);
    return chooseExecGitRef(allocator, null, current_branch, default_branch);
}

fn chooseExecGitRef(
    allocator: std.mem.Allocator,
    branch_override: ?[]const u8,
    current_branch: ?[]const u8,
    default_branch: ?[]const u8,
) ![]const u8 {
    if (branch_override) |branch| {
        const trimmed = std.mem.trim(u8, branch, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (current_branch) |branch| {
        const trimmed = std.mem.trim(u8, branch, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (default_branch) |branch| {
        const trimmed = std.mem.trim(u8, branch, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    return allocator.dupe(u8, "main");
}

fn currentGitBranch(allocator: std.mem.Allocator) !?[]const u8 {
    const stdout = (try runCloudGit(allocator, &.{ "git", "branch", "--show-current" })) orelse return null;
    defer allocator.free(stdout);
    const branch = std.mem.trim(u8, stdout, " \t\r\n");
    if (branch.len == 0) return null;
    return try allocator.dupe(u8, branch);
}

fn defaultGitBranch(allocator: std.mem.Allocator) !?[]const u8 {
    if (try runCloudGit(allocator, &.{ "git", "remote" })) |stdout| {
        defer allocator.free(stdout);
        var remotes = try prioritizedRemoteNames(allocator, stdout);
        defer remotes.deinit(allocator);
        for (remotes.items) |remote| {
            if (try remoteSymbolicHeadBranch(allocator, remote)) |branch| return branch;
            if (try remoteShowHeadBranch(allocator, remote)) |branch| return branch;
        }
    }

    for ([_][]const u8{ "main", "master" }) |candidate| {
        const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{candidate});
        defer allocator.free(ref);
        const stdout = (try runCloudGit(allocator, &.{ "git", "rev-parse", "--verify", "--quiet", ref })) orelse continue;
        allocator.free(stdout);
        return try allocator.dupe(u8, candidate);
    }

    return null;
}

fn prioritizedRemoteNames(allocator: std.mem.Allocator, stdout: []const u8) !std.ArrayList([]const u8) {
    var remotes = std.ArrayList([]const u8).empty;
    errdefer remotes.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const remote = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, remote, "origin")) {
            try remotes.append(allocator, remote);
        }
    }

    lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const remote = std.mem.trim(u8, line, " \t\r\n");
        if (remote.len == 0 or std.mem.eql(u8, remote, "origin")) continue;
        try remotes.append(allocator, remote);
    }

    return remotes;
}

fn remoteSymbolicHeadBranch(allocator: std.mem.Allocator, remote: []const u8) !?[]const u8 {
    const remote_head = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/HEAD", .{remote});
    defer allocator.free(remote_head);
    const stdout = (try runCloudGit(allocator, &.{ "git", "symbolic-ref", "--quiet", remote_head })) orelse return null;
    defer allocator.free(stdout);
    const ref = std.mem.trim(u8, stdout, " \t\r\n");
    return symbolicRemoteHeadBranch(allocator, remote, ref);
}

fn symbolicRemoteHeadBranch(allocator: std.mem.Allocator, remote: []const u8, ref: []const u8) !?[]const u8 {
    const prefix = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/", .{remote});
    defer allocator.free(prefix);
    if (std.mem.startsWith(u8, ref, prefix)) {
        const name = ref[prefix.len..];
        if (name.len > 0 and !std.mem.eql(u8, name, "HEAD")) return try allocator.dupe(u8, name);
    }
    if (std.mem.lastIndexOfScalar(u8, ref, '/')) |index| {
        const name = ref[index + 1 ..];
        if (name.len > 0) return try allocator.dupe(u8, name);
    }
    return null;
}

fn remoteShowHeadBranch(allocator: std.mem.Allocator, remote: []const u8) !?[]const u8 {
    const stdout = (try runCloudGit(allocator, &.{ "git", "remote", "show", remote })) orelse return null;
    defer allocator.free(stdout);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const prefix = "HEAD branch:";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const name = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
        if (name.len > 0) return try allocator.dupe(u8, name);
    }
    return null;
}

fn runCloudGit(allocator: std.mem.Allocator, argv: []const []const u8) !?[]const u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var child_env = try cloudGitEnvironment(allocator);
    defer child_env.deinit();

    const result = std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .environ_map = &child_env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |err| switch (err) {
        error.Timeout => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    return result.stdout;
}

fn cloudGitEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();

    var index: usize = 0;
    while (std.c.environ[index]) |entry_ptr| : (index += 1) {
        const entry = std.mem.span(entry_ptr);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        try result.put(key, entry[eq + 1 ..]);
    }
    try result.put("GIT_OPTIONAL_LOCKS", "0");
    try result.put("GIT_TERMINAL_PROMPT", "0");
    return result;
}

fn buildCreateTaskBody(
    allocator: std.mem.Allocator,
    environment: []const u8,
    prompt: []const u8,
    git_ref: []const u8,
    attempts: usize,
    starting_diff: ?[]const u8,
) ![]const u8 {
    const environment_json = try std.json.Stringify.valueAlloc(allocator, environment, .{});
    defer allocator.free(environment_json);
    const prompt_json = try std.json.Stringify.valueAlloc(allocator, prompt, .{});
    defer allocator.free(prompt_json);
    const git_ref_json = try std.json.Stringify.valueAlloc(allocator, git_ref, .{});
    defer allocator.free(git_ref_json);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "{{\"new_task\":{{\"environment_id\":{s},\"branch\":{s},\"run_environment_in_qa_mode\":false}},\"input_items\":[{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"content_type\":\"text\",\"text\":{s}}}]}}",
        .{ environment_json, git_ref_json, prompt_json },
    );
    if (starting_diff) |diff| {
        if (diff.len > 0) {
            const diff_json = try std.json.Stringify.valueAlloc(allocator, diff, .{});
            defer allocator.free(diff_json);
            try out.print(
                allocator,
                ",{{\"type\":\"pre_apply_patch\",\"output_diff\":{{\"diff\":{s}}}}}",
                .{diff_json},
            );
        }
    }
    try out.append(allocator, ']');
    if (attempts > 1) {
        try out.print(allocator, ",\"metadata\":{{\"best_of_n\":{d}}}", .{attempts});
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn parseCreatedTaskId(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCloudTaskResponse;

    if (objectField(parsed.value, "task")) |task| {
        if (valueString(objectField(task, "id"))) |id| {
            if (id.len > 0) return allocator.dupe(u8, id);
        }
    }
    if (valueString(objectField(parsed.value, "id"))) |id| {
        if (id.len > 0) return allocator.dupe(u8, id);
    }
    return error.InvalidCloudTaskResponse;
}

fn initRuntime(allocator: std.mem.Allocator, parsed: ParsedOptions) !CloudRuntime {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = parsed.profile });
    errdefer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, parsed.runtime_overrides);

    var credentials = try auth.load(allocator, cfg.codex_home);
    errdefer credentials.deinit(allocator);
    if (credentials.mode != .chatgpt and credentials.mode != .chatgpt_auth_tokens and credentials.mode != .agent_identity) {
        return error.ChatGptBackendAuthRequired;
    }
    if (credentials.account_id == null) return error.MissingChatGptAccountId;

    const raw_base_url = try resolveCloudBaseUrl(allocator, cfg, parsed);
    defer allocator.free(raw_base_url);
    const base_url = try normalizeCloudBackendBaseUrl(allocator, raw_base_url);
    errdefer allocator.free(base_url);
    if (std.mem.trim(u8, base_url, " \t\r\n/").len == 0) return error.InvalidCloudBaseUrl;

    return .{
        .cfg = cfg,
        .credentials = credentials,
        .base_url = base_url,
    };
}

fn resolveCloudBaseUrl(allocator: std.mem.Allocator, cfg: config.Config, parsed: ParsedOptions) ![]const u8 {
    const cloud_env = try env.getOwned(allocator, "CODEX_CLOUD_TASKS_BASE_URL");
    defer if (cloud_env) |value| allocator.free(value);
    const global_env = try env.getOwned(allocator, "CODEX_ZIG_BASE_URL");
    defer if (global_env) |value| allocator.free(value);
    const config_base = try explicitChatGptBaseUrlFromConfig(allocator, cfg.codex_home, cfg.active_profile);
    defer if (config_base) |value| allocator.free(value);

    return selectCloudBaseUrl(
        allocator,
        cloud_env,
        parsed.runtime_overrides.chatgpt_base_url,
        global_env,
        config_base,
    );
}

fn selectCloudBaseUrl(
    allocator: std.mem.Allocator,
    cloud_env: ?[]const u8,
    command_chatgpt_base_url: ?[]const u8,
    global_env: ?[]const u8,
    config_chatgpt_base_url: ?[]const u8,
) ![]const u8 {
    if (cloud_env) |value| return allocator.dupe(u8, value);
    if (command_chatgpt_base_url) |value| return allocator.dupe(u8, value);
    if (global_env) |value| return allocator.dupe(u8, value);
    if (config_chatgpt_base_url) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, default_cloud_base_url);
}

fn explicitChatGptBaseUrlFromConfig(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    active_profile: ?[]const u8,
) !?[]const u8 {
    const path = try config.configTomlPath(allocator, codex_home);
    defer allocator.free(path);

    const bytes = try config.readConfigTomlFile(allocator, path);
    defer if (bytes) |value| allocator.free(value);
    return explicitChatGptBaseUrlFromConfigBytes(allocator, bytes orelse "", active_profile);
}

fn explicitChatGptBaseUrlFromConfigBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    active_profile: ?[]const u8,
) !?[]const u8 {
    return config.scopedStringValue(allocator, bytes, active_profile, "chatgpt_base_url");
}

fn fetchCloudTasks(allocator: std.mem.Allocator, runtime: CloudRuntime, url: []const u8) ![]const u8 {
    return requestCloudTasks(allocator, runtime, .GET, url, null);
}

fn postCloudTasks(allocator: std.mem.Allocator, runtime: CloudRuntime, url: []const u8, body: []const u8) ![]const u8 {
    return requestCloudTasks(allocator, runtime, .POST, url, body);
}

fn requestCloudTasks(
    allocator: std.mem.Allocator,
    runtime: CloudRuntime,
    method: std.http.Method,
    url: []const u8,
    request_body: ?[]const u8,
) ![]const u8 {
    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    const auth_header = try auth.authorizationHeader(allocator, runtime.credentials);
    defer allocator.free(auth_header);
    try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "codex-zig-cloud/0.0.1" });
    try headers.append(allocator, .{ .name = "ChatGPT-Account-ID", .value = runtime.credentials.account_id.? });
    if (runtime.credentials.fedramp) {
        try headers.append(allocator, .{ .name = "X-OpenAI-Fedramp", .value = "true" });
    }

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io_instance.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .response_writer = &response_body.writer,
        .extra_headers = headers.items,
        .payload = request_body,
    });

    const body = try response_body.toOwnedSlice();
    errdefer allocator.free(body);
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        std.debug.print("Codex Cloud request failed with status {d}: {s}\n", .{ @intFromEnum(result.status), body });
        return error.CloudRequestFailed;
    }
    return body;
}

fn buildTasksCollectionUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    return cloudTasksPathBase(allocator, base_url);
}

fn buildListUrl(allocator: std.mem.Allocator, base_url: []const u8, options: ListOptions) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const path_base = try cloudTasksPathBase(allocator, base_url);
    defer allocator.free(path_base);
    try out.print(allocator, "{s}/list?task_filter=current&limit={d}", .{
        path_base,
        options.limit,
    });
    if (options.cursor) |cursor| {
        try out.appendSlice(allocator, "&cursor=");
        try percentEncode(allocator, &out, cursor);
    }
    if (options.environment) |environment| {
        try out.appendSlice(allocator, "&environment_id=");
        try percentEncode(allocator, &out, environment);
    }
    return out.toOwnedSlice(allocator);
}

fn buildTaskUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const path_base = try cloudTasksPathBase(allocator, base_url);
    defer allocator.free(path_base);
    try out.appendSlice(allocator, path_base);
    try out.append(allocator, '/');
    try percentEncode(allocator, &out, task_id);
    return out.toOwnedSlice(allocator);
}

fn cloudTasksPathBase(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const normalized = try normalizeCloudBackendBaseUrl(allocator, base_url);
    defer allocator.free(normalized);
    const trimmed = std.mem.trimEnd(u8, normalized, "/");
    if (std.mem.indexOf(u8, trimmed, "/backend-api") != null) {
        return std.fmt.allocPrint(allocator, "{s}/wham/tasks", .{trimmed});
    }
    if (std.mem.indexOf(u8, trimmed, "/api/codex") != null) {
        return std.fmt.allocPrint(allocator, "{s}/tasks", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}/api/codex/tasks", .{trimmed});
}

fn normalizeCloudBackendBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n/");
    if (trimmed.len == 0) return error.InvalidCloudBaseUrl;
    const backend_codex_suffix = "/backend-api/codex";
    if (std.mem.endsWith(u8, trimmed, backend_codex_suffix)) {
        return allocator.dupe(u8, trimmed[0 .. trimmed.len - "/codex".len]);
    }
    if ((std.mem.startsWith(u8, trimmed, "https://chatgpt.com") or
        std.mem.startsWith(u8, trimmed, "https://chat.openai.com")) and
        std.mem.indexOf(u8, trimmed, "/backend-api") == null)
    {
        return std.fmt.allocPrint(allocator, "{s}/backend-api", .{trimmed});
    }
    return allocator.dupe(u8, trimmed);
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[@as(usize, byte >> 4)]);
            try out.append(allocator, hex[@as(usize, byte & 0x0f)]);
        }
    }
}

fn parseTaskListPage(allocator: std.mem.Allocator, body: []const u8) !TaskListPage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCloudTaskResponse;

    const items = objectField(parsed.value, "items") orelse objectField(parsed.value, "tasks") orelse return error.InvalidCloudTaskResponse;
    if (items != .array) return error.InvalidCloudTaskResponse;

    var page = TaskListPage{};
    errdefer page.deinit(allocator);
    for (items.array.items) |item| {
        if (item != .object) return error.InvalidCloudTaskResponse;
        try page.tasks.append(allocator, try parseTaskSummaryValue(allocator, null, item));
    }

    if (objectField(parsed.value, "cursor")) |cursor| {
        if (cursor == .string and cursor.string.len > 0) {
            page.cursor = try allocator.dupe(u8, cursor.string);
        }
    }
    return page;
}

fn parseTaskDetailsSummary(allocator: std.mem.Allocator, task_id: []const u8, body: []const u8) !TaskSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCloudTaskResponse;

    var task = try parseTaskSummaryValue(allocator, task_id, parsed.value);
    errdefer task.deinit(allocator);
    if (task.summary.files_changed == 0 and task.summary.lines_added == 0 and task.summary.lines_removed == 0) {
        if (extractUnifiedDiff(allocator, body)) |diff| {
            defer allocator.free(diff);
            task.summary = diffSummaryFromDiff(diff);
        } else |_| {}
    }
    return task;
}

fn parseTaskSummaryValue(allocator: std.mem.Allocator, fallback_id: ?[]const u8, raw: std.json.Value) !TaskSummary {
    const task_value = objectField(raw, "task") orelse raw;
    if (task_value != .object) return error.InvalidCloudTaskResponse;

    const id_source = valueString(objectField(task_value, "id")) orelse fallback_id orelse return error.InvalidCloudTaskResponse;
    const title_source = valueString(objectField(task_value, "title")) orelse "<untitled>";
    const status_display = objectField(raw, "task_status_display") orelse objectField(task_value, "task_status_display");

    return .{
        .id = try allocator.dupe(u8, id_source),
        .title = try allocator.dupe(u8, title_source),
        .status = taskStatusFromDisplay(status_display),
        .updated_at = valueNumber(objectField(task_value, "updated_at")) orelse
            valueNumber(objectField(task_value, "created_at")) orelse
            latestTurnTimestamp(status_display) orelse
            0,
        .environment_id = try dupOptionalString(allocator, valueString(objectField(task_value, "environment_id"))),
        .environment_label = try dupOptionalString(allocator, envLabelFromDisplay(status_display)),
        .summary = diffSummaryFromDisplay(status_display),
        .is_review = valueBool(objectField(task_value, "is_review")) orelse pullRequestsPresent(task_value),
        .attempt_total = attemptTotalFromDisplay(status_display),
    };
}

fn extractUnifiedDiff(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCloudTaskResponse;

    if (objectField(parsed.value, "current_diff_task_turn")) |turn| {
        if (try extractDiffFromTurn(allocator, turn)) |diff| return diff;
    }
    if (objectField(parsed.value, "current_assistant_turn")) |turn| {
        if (try extractDiffFromTurn(allocator, turn)) |diff| return diff;
    }
    return error.NoCloudTaskDiff;
}

fn extractUnifiedDiffForAttempt(allocator: std.mem.Allocator, body: []const u8, attempt: usize) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCloudTaskResponse;

    var saw_other_attempt = false;
    if (objectField(parsed.value, "current_diff_task_turn")) |turn| {
        if (try turnMatchesAttempt(turn, attempt)) {
            if (try extractDiffFromTurn(allocator, turn)) |diff| return diff;
        } else {
            saw_other_attempt = true;
        }
    }
    if (objectField(parsed.value, "current_assistant_turn")) |turn| {
        if (try turnMatchesAttempt(turn, attempt)) {
            if (try extractDiffFromTurn(allocator, turn)) |diff| return diff;
        } else {
            saw_other_attempt = true;
        }
    }
    if (saw_other_attempt) return error.CloudAttemptRuntimeUnsupported;
    return error.NoCloudTaskDiff;
}

fn extractDiffFromTurn(allocator: std.mem.Allocator, turn: std.json.Value) !?[]const u8 {
    if (turn == .null) return null;
    if (turn != .object) return error.InvalidCloudTaskResponse;
    const items = objectField(turn, "output_items") orelse return null;
    if (items != .array) return error.InvalidCloudTaskResponse;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const kind = valueString(objectField(item, "type")) orelse continue;
        if (std.mem.eql(u8, kind, "output_diff")) {
            if (valueString(objectField(item, "diff"))) |diff| {
                if (diff.len > 0) return try allocator.dupe(u8, diff);
            }
        }
        if (std.mem.eql(u8, kind, "pr")) {
            const output_diff = objectField(item, "output_diff") orelse continue;
            if (valueString(objectField(output_diff, "diff"))) |diff| {
                if (diff.len > 0) return try allocator.dupe(u8, diff);
            }
        }
    }
    return null;
}

fn turnMatchesAttempt(turn: std.json.Value, attempt: usize) !bool {
    if (turn == .null) return false;
    if (turn != .object) return error.InvalidCloudTaskResponse;
    if (turnAttemptPlacement(objectField(turn, "attempt_placement"))) |placement| {
        return placement == attempt;
    }
    if (turnHasSiblingAttempts(turn)) return false;
    return attempt == 1;
}

fn turnAttemptPlacement(value: ?std.json.Value) ?usize {
    const actual = value orelse return null;
    const number: i64 = switch (actual) {
        .integer => |raw| raw,
        .float => |raw| @as(i64, @intFromFloat(raw)),
        .number_string => |bytes| std.fmt.parseInt(i64, bytes, 10) catch return null,
        else => return null,
    };
    if (number <= 0) return null;
    return @intCast(number);
}

fn turnHasSiblingAttempts(turn: std.json.Value) bool {
    const siblings = objectField(turn, "sibling_turn_ids") orelse return false;
    return siblings == .array and siblings.array.items.len > 0;
}

fn renderTaskList(allocator: std.mem.Allocator, base_url: []const u8, page: TaskListPage) ![]const u8 {
    if (page.tasks.items.len == 0) return allocator.dupe(u8, "No tasks found.\n");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (page.tasks.items, 0..) |task, index| {
        const url = try taskUrl(allocator, base_url, task.id);
        defer allocator.free(url);
        try out.appendSlice(allocator, url);
        try out.append(allocator, '\n');
        const status = try renderTaskStatus(allocator, task, true);
        defer allocator.free(status);
        try out.appendSlice(allocator, status);
        if (index + 1 < page.tasks.items.len) try out.append(allocator, '\n');
    }
    if (page.cursor) |cursor| {
        try out.print(allocator, "\nTo fetch the next page, run codex cloud list --cursor='{s}'\n", .{cursor});
    }
    return out.toOwnedSlice(allocator);
}

fn renderTaskStatus(allocator: std.mem.Allocator, task: TaskSummary, indent: bool) ![]const u8 {
    const prefix = if (indent) "  " else "";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const relative = try formatRelativeTime(allocator, task.updated_at);
    defer allocator.free(relative);
    const summary = try renderSummaryLine(allocator, task.summary);
    defer allocator.free(summary);
    try out.print(allocator, "{s}[{s}] {s}\n", .{ prefix, task.status.display(), task.title });
    if (task.environment_label orelse task.environment_id) |environment| {
        try out.print(allocator, "{s}{s} - {s}\n", .{ prefix, environment, relative });
    } else {
        try out.print(allocator, "{s}{s}\n", .{ prefix, relative });
    }
    try out.print(allocator, "{s}{s}\n", .{ prefix, summary });
    return out.toOwnedSlice(allocator);
}

fn renderTaskListJson(allocator: std.mem.Allocator, base_url: []const u8, page: TaskListPage) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"tasks\":[");
    for (page.tasks.items, 0..) |task, index| {
        if (index > 0) try out.append(allocator, ',');
        const id_json = try std.json.Stringify.valueAlloc(allocator, task.id, .{});
        defer allocator.free(id_json);
        const url = try taskUrl(allocator, base_url, task.id);
        defer allocator.free(url);
        const url_json = try std.json.Stringify.valueAlloc(allocator, url, .{});
        defer allocator.free(url_json);
        const title_json = try std.json.Stringify.valueAlloc(allocator, task.title, .{});
        defer allocator.free(title_json);
        const status_json = try std.json.Stringify.valueAlloc(allocator, task.status.jsonLabel(), .{});
        defer allocator.free(status_json);
        const updated_at = try formatUpdatedAt(allocator, task.updated_at);
        defer allocator.free(updated_at);
        const updated_json = try std.json.Stringify.valueAlloc(allocator, updated_at, .{});
        defer allocator.free(updated_json);
        try out.print(
            allocator,
            "{{\"id\":{s},\"url\":{s},\"title\":{s},\"status\":{s},\"updated_at\":{s},",
            .{ id_json, url_json, title_json, status_json, updated_json },
        );
        try appendOptionalStringJson(allocator, &out, "environment_id", task.environment_id);
        try out.append(allocator, ',');
        try appendOptionalStringJson(allocator, &out, "environment_label", task.environment_label);
        try out.print(
            allocator,
            ",\"summary\":{{\"files_changed\":{d},\"lines_added\":{d},\"lines_removed\":{d}}},\"is_review\":{},",
            .{ task.summary.files_changed, task.summary.lines_added, task.summary.lines_removed, task.is_review },
        );
        if (task.attempt_total) |attempt_total| {
            try out.print(allocator, "\"attempt_total\":{d}}}", .{attempt_total});
        } else {
            try out.appendSlice(allocator, "\"attempt_total\":null}");
        }
    }
    try out.appendSlice(allocator, "],\"cursor\":");
    if (page.cursor) |cursor| {
        const cursor_json = try std.json.Stringify.valueAlloc(allocator, cursor, .{});
        defer allocator.free(cursor_json);
        try out.appendSlice(allocator, cursor_json);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn appendOptionalStringJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    try out.print(allocator, "{s}:", .{name_json});
    if (value) |actual| {
        const value_json = try std.json.Stringify.valueAlloc(allocator, actual, .{});
        defer allocator.free(value_json);
        try out.appendSlice(allocator, value_json);
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn renderSummaryLine(allocator: std.mem.Allocator, summary: DiffSummary) ![]const u8 {
    if (summary.files_changed == 0 and summary.lines_added == 0 and summary.lines_removed == 0) {
        return allocator.dupe(u8, "no diff");
    }
    return std.fmt.allocPrint(
        allocator,
        "+{d}/-{d} - {d} file{s}",
        .{
            summary.lines_added,
            summary.lines_removed,
            summary.files_changed,
            if (summary.files_changed == 1) "" else "s",
        },
    );
}

fn taskUrl(allocator: std.mem.Allocator, base_url: []const u8, task_id: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.indexOf(u8, trimmed, "/backend-api")) |index| {
        return std.fmt.allocPrint(allocator, "{s}/codex/tasks/{s}", .{ trimmed[0..index], task_id });
    }
    if (std.mem.indexOf(u8, trimmed, "/api/codex")) |index| {
        return std.fmt.allocPrint(allocator, "{s}/codex/tasks/{s}", .{ trimmed[0..index], task_id });
    }
    if (std.mem.endsWith(u8, trimmed, "/codex")) {
        return std.fmt.allocPrint(allocator, "{s}/tasks/{s}", .{ trimmed, task_id });
    }
    return std.fmt.allocPrint(allocator, "{s}/codex/tasks/{s}", .{ trimmed, task_id });
}

fn normalizeTaskId(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const without_fragment = if (std.mem.indexOfScalar(u8, raw, '#')) |index| raw[0..index] else raw;
    const without_query = if (std.mem.indexOfScalar(u8, without_fragment, '?')) |index| without_fragment[0..index] else without_fragment;
    const after_slash = if (std.mem.lastIndexOfScalar(u8, without_query, '/')) |index| without_query[index + 1 ..] else without_query;
    const trimmed = std.mem.trim(u8, after_slash, " \t\r\n");
    if (trimmed.len == 0) return error.MissingCloudTaskId;
    return allocator.dupe(u8, trimmed);
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn valueString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    if (actual != .string) return null;
    return actual.string;
}

fn valueBool(value: ?std.json.Value) ?bool {
    const actual = value orelse return null;
    if (actual != .bool) return null;
    return actual.bool;
}

fn valueNumber(value: ?std.json.Value) ?f64 {
    const actual = value orelse return null;
    return switch (actual) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .number_string => |bytes| std.fmt.parseFloat(f64, bytes) catch null,
        else => null,
    };
}

fn dupOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const actual = value orelse return null;
    return try allocator.dupe(u8, actual);
}

fn taskStatusFromDisplay(display: ?std.json.Value) TaskStatus {
    if (display) |value| {
        if (objectField(value, "latest_turn_status_display")) |latest| {
            if (valueString(objectField(latest, "turn_status"))) |status| {
                if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) return .err;
                if (std.mem.eql(u8, status, "completed")) return .ready;
                if (std.mem.eql(u8, status, "in_progress") or std.mem.eql(u8, status, "pending")) return .pending;
            }
        }
        if (valueString(objectField(value, "state"))) |state| {
            if (std.mem.eql(u8, state, "ready")) return .ready;
            if (std.mem.eql(u8, state, "applied")) return .applied;
            if (std.mem.eql(u8, state, "error")) return .err;
            if (std.mem.eql(u8, state, "pending")) return .pending;
        }
    }
    return .pending;
}

fn diffSummaryFromDisplay(display: ?std.json.Value) DiffSummary {
    const latest = if (display) |value| objectField(value, "latest_turn_status_display") else null;
    const diff_stats = if (latest) |value| objectField(value, "diff_stats") else null;
    const stats = diff_stats orelse return .{};
    return .{
        .files_changed = positiveUsize(objectField(stats, "files_modified")),
        .lines_added = positiveUsize(objectField(stats, "lines_added")),
        .lines_removed = positiveUsize(objectField(stats, "lines_removed")),
    };
}

fn diffSummaryFromDiff(diff: []const u8) DiffSummary {
    var summary = DiffSummary{};
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            summary.files_changed += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "@@")) {
            continue;
        }
        if (line.len == 0) continue;
        if (line[0] == '+') summary.lines_added += 1;
        if (line[0] == '-') summary.lines_removed += 1;
    }
    if (summary.files_changed == 0 and std.mem.trim(u8, diff, " \t\r\n").len > 0) summary.files_changed = 1;
    return summary;
}

fn positiveUsize(value: ?std.json.Value) usize {
    const actual = value orelse return 0;
    const number: i64 = switch (actual) {
        .integer => |raw| raw,
        .float => |raw| @as(i64, @intFromFloat(raw)),
        .number_string => |bytes| std.fmt.parseInt(i64, bytes, 10) catch 0,
        else => return 0,
    };
    if (number <= 0) return 0;
    return @intCast(number);
}

fn latestTurnTimestamp(display: ?std.json.Value) ?f64 {
    const latest = if (display) |value| objectField(value, "latest_turn_status_display") else null;
    if (latest) |value| {
        return valueNumber(objectField(value, "updated_at")) orelse valueNumber(objectField(value, "created_at"));
    }
    return null;
}

fn envLabelFromDisplay(display: ?std.json.Value) ?[]const u8 {
    const value = display orelse return null;
    return valueString(objectField(value, "environment_label"));
}

fn attemptTotalFromDisplay(display: ?std.json.Value) ?usize {
    const latest = if (display) |value| objectField(value, "latest_turn_status_display") else null;
    const siblings = if (latest) |value| objectField(value, "sibling_turn_ids") else null;
    const actual = siblings orelse return null;
    if (actual != .array) return null;
    return actual.array.items.len + 1;
}

fn pullRequestsPresent(value: std.json.Value) bool {
    const prs = objectField(value, "pull_requests") orelse return false;
    return prs == .array and prs.array.items.len > 0;
}

fn formatRelativeTime(allocator: std.mem.Allocator, updated_at: f64) ![]const u8 {
    if (updated_at <= 0) return allocator.dupe(u8, "unknown time");
    const updated_secs: i64 = @intFromFloat(@floor(updated_at));
    const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
    const now_secs: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
    const delta = now_secs - updated_secs;
    if (delta < 60) return allocator.dupe(u8, "just now");
    if (delta < 3600) return std.fmt.allocPrint(allocator, "{d}m ago", .{@divTrunc(delta, 60)});
    if (delta < 86400) return std.fmt.allocPrint(allocator, "{d}h ago", .{@divTrunc(delta, 3600)});
    return std.fmt.allocPrint(allocator, "{d}d ago", .{@divTrunc(delta, 86400)});
}

fn formatUpdatedAt(allocator: std.mem.Allocator, updated_at: f64) ![]const u8 {
    if (updated_at <= 0) return allocator.dupe(u8, "1970-01-01T00:00:00Z");
    const updated_secs: u64 = @as(u64, @intFromFloat(@floor(updated_at)));
    return auth.rfc3339FromSeconds(allocator, updated_secs);
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
            parsed.profile = profile;
            return parsed;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCloudOption;
        return error.UnknownCloudSubcommand;
    }
    parsed.profile = profile;
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

test "cloud command normalizes backend and browser task URLs" {
    const allocator = std.testing.allocator;

    const normalized_default = try normalizeCloudBackendBaseUrl(allocator, "https://chatgpt.com/backend-api/codex/");
    defer allocator.free(normalized_default);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api", normalized_default);

    const normalized_host = try normalizeCloudBackendBaseUrl(allocator, "https://chatgpt.com/");
    defer allocator.free(normalized_host);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api", normalized_host);

    const list_url = try buildListUrl(allocator, "https://chatgpt.com/backend-api/codex/", .{ .limit = 2 });
    defer allocator.free(list_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/wham/tasks/list?task_filter=current&limit=2", list_url);

    const task_api_url = try buildTaskUrl(allocator, "https://chatgpt.com/backend-api/codex/", "task 1");
    defer allocator.free(task_api_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/wham/tasks/task%201", task_api_url);

    const plain_api_url = try buildTaskUrl(allocator, "https://api.example.com", "task_3");
    defer allocator.free(plain_api_url);
    try std.testing.expectEqualStrings("https://api.example.com/api/codex/tasks/task_3", plain_api_url);

    const browser_url = try taskUrl(allocator, "https://chatgpt.com/backend-api", "task_1");
    defer allocator.free(browser_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/codex/tasks/task_1", browser_url);

    const codex_api_browser_url = try taskUrl(allocator, "https://api.example.com/api/codex", "task_2");
    defer allocator.free(codex_api_browser_url);
    try std.testing.expectEqualStrings("https://api.example.com/codex/tasks/task_2", codex_api_browser_url);
}

test "cloud base URL ignores model provider fallback" {
    const allocator = std.testing.allocator;

    const default_base = try selectCloudBaseUrl(allocator, null, null, null, null);
    defer allocator.free(default_base);
    try std.testing.expectEqualStrings(default_cloud_base_url, default_base);

    const global_env = try selectCloudBaseUrl(allocator, null, null, "http://127.0.0.1:9000", null);
    defer allocator.free(global_env);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", global_env);

    const command_override = try selectCloudBaseUrl(
        allocator,
        null,
        "http://127.0.0.1:9001",
        "http://127.0.0.1:9000",
        "https://config.example/backend-api",
    );
    defer allocator.free(command_override);
    try std.testing.expectEqualStrings("http://127.0.0.1:9001", command_override);

    const cloud_env = try selectCloudBaseUrl(
        allocator,
        "http://127.0.0.1:9002",
        "http://127.0.0.1:9001",
        "http://127.0.0.1:9000",
        "https://config.example/backend-api",
    );
    defer allocator.free(cloud_env);
    try std.testing.expectEqualStrings("http://127.0.0.1:9002", cloud_env);

    const provider_only =
        \\model_provider = "custom"
        \\
        \\[model_providers.custom]
        \\base_url = "https://proxy.example/v1"
        \\
    ;
    const ignored_provider = try explicitChatGptBaseUrlFromConfigBytes(allocator, provider_only, null);
    try std.testing.expect(ignored_provider == null);

    const explicit_top_level =
        \\model_provider = "custom"
        \\chatgpt_base_url = "https://cloud.example/backend-api"
        \\
        \\[model_providers.custom]
        \\base_url = "https://proxy.example/v1"
        \\
    ;
    const top_level = try explicitChatGptBaseUrlFromConfigBytes(allocator, explicit_top_level, null);
    defer allocator.free(top_level.?);
    try std.testing.expectEqualStrings("https://cloud.example/backend-api", top_level.?);

    const profile_override =
        \\chatgpt_base_url = "https://base.example/backend-api"
        \\
        \\[profiles.work]
        \\chatgpt_base_url = "https://profile.example/backend-api"
        \\
    ;
    const profile_value = try explicitChatGptBaseUrlFromConfigBytes(allocator, profile_override, "work");
    defer allocator.free(profile_value.?);
    try std.testing.expectEqualStrings("https://profile.example/backend-api", profile_value.?);
}

test "cloud exec builds task creation body" {
    const allocator = std.testing.allocator;

    const body = try buildCreateTaskBody(allocator, "env-1", "write tests", "feature/cloud", 3, null);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const new_task = objectField(parsed.value, "new_task").?;
    try std.testing.expectEqualStrings("env-1", valueString(objectField(new_task, "environment_id")).?);
    try std.testing.expectEqualStrings("feature/cloud", valueString(objectField(new_task, "branch")).?);
    try std.testing.expectEqual(false, valueBool(objectField(new_task, "run_environment_in_qa_mode")).?);

    const metadata = objectField(parsed.value, "metadata").?;
    try std.testing.expectEqual(@as(i64, 3), objectField(metadata, "best_of_n").?.integer);

    const items = objectField(parsed.value, "input_items").?;
    try std.testing.expectEqual(@as(usize, 1), items.array.items.len);
    const message = items.array.items[0];
    try std.testing.expectEqualStrings("message", valueString(objectField(message, "type")).?);
    try std.testing.expectEqualStrings("user", valueString(objectField(message, "role")).?);
}

test "cloud exec body includes explicit starting diff item" {
    const allocator = std.testing.allocator;

    const body = try buildCreateTaskBody(allocator, "env-1", "write tests", "feature/cloud", 1, "diff --git a/a b/a\n");
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const items = objectField(parsed.value, "input_items").?;
    try std.testing.expectEqual(@as(usize, 2), items.array.items.len);
    const patch = items.array.items[1];
    try std.testing.expectEqualStrings("pre_apply_patch", valueString(objectField(patch, "type")).?);
}

test "cloud exec parses created task ids" {
    const allocator = std.testing.allocator;

    const nested = try parseCreatedTaskId(allocator, "{\"task\":{\"id\":\"task-nested\"}}");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("task-nested", nested);

    const top_level = try parseCreatedTaskId(allocator, "{\"id\":\"task-top\"}");
    defer allocator.free(top_level);
    try std.testing.expectEqualStrings("task-top", top_level);

    try std.testing.expectError(error.InvalidCloudTaskResponse, parseCreatedTaskId(allocator, "{\"task\":{}}"));
}

test "cloud exec git ref honors branch override" {
    const allocator = std.testing.allocator;

    const branch = try chooseExecGitRef(allocator, " feature/cloud ", null, null);
    defer allocator.free(branch);
    try std.testing.expectEqualStrings("feature/cloud", branch);

    const current = try chooseExecGitRef(allocator, null, "feature/current", "default-main");
    defer allocator.free(current);
    try std.testing.expectEqualStrings("feature/current", current);

    const default = try chooseExecGitRef(allocator, null, null, "develop");
    defer allocator.free(default);
    try std.testing.expectEqualStrings("develop", default);

    const fallback = try chooseExecGitRef(allocator, null, null, null);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("main", fallback);
}

test "cloud exec default branch probes origin before other remotes" {
    const allocator = std.testing.allocator;

    var remotes = try prioritizedRemoteNames(allocator, "upstream\n origin \nfork\n");
    defer remotes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), remotes.items.len);
    try std.testing.expectEqualStrings("origin", remotes.items[0]);
    try std.testing.expectEqualStrings("upstream", remotes.items[1]);
    try std.testing.expectEqualStrings("fork", remotes.items[2]);
}

test "cloud exec remote symbolic head preserves branch path" {
    const allocator = std.testing.allocator;

    const branch = (try symbolicRemoteHeadBranch(allocator, "origin", "refs/remotes/origin/release/v1")).?;
    defer allocator.free(branch);
    try std.testing.expectEqualStrings("release/v1", branch);

    const fallback = (try symbolicRemoteHeadBranch(allocator, "origin", "refs/heads/main")).?;
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("main", fallback);
}

test "cloud diff refuses non-first current attempt" {
    const allocator = std.testing.allocator;

    const first_attempt_body =
        \\{"current_diff_task_turn":{"attempt_placement":1,"output_items":[{"type":"output_diff","diff":"diff --git a/a b/a\n"}]}}
    ;
    const first_attempt_diff = try extractUnifiedDiffForAttempt(allocator, first_attempt_body, 1);
    defer allocator.free(first_attempt_diff);
    try std.testing.expectEqualStrings("diff --git a/a b/a\n", first_attempt_diff);

    const second_attempt_body =
        \\{"current_diff_task_turn":{"attempt_placement":2,"sibling_turn_ids":["turn-1"],"output_items":[{"type":"output_diff","diff":"diff --git a/b b/b\n"}]}}
    ;
    try std.testing.expectError(error.CloudAttemptRuntimeUnsupported, extractUnifiedDiffForAttempt(allocator, second_attempt_body, 1));
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
