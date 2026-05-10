const std = @import("std");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const input_images = @import("input_images.zig");
const review = @import("review.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const workdir = @import("workdir.zig");

const ExecArgs = struct {
    auto_approve: bool = false,
    ephemeral: bool = false,
    skip_git_repo_check: bool = false,
    removed_full_auto: bool = false,
    dangerously_bypass_approvals_and_sandbox: bool = false,
    ignore_user_config: bool = false,
    ignore_rules: bool = false,
    json: bool = false,
    config_overrides: config.RuntimeOverrides = .{},
    config_profile: ?[]const u8 = null,
    help: bool = false,
    last_message_file: ?[]const u8 = null,
    output_schema_file: ?[]const u8 = null,
    image_files: std.ArrayList([]const u8) = .empty,
    model: ?[]const u8 = null,
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    approval_policy: ?config.ApprovalPolicy = null,
    sandbox_mode: ?config.SandboxMode = null,
    profile: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    resume_target: ?[]const u8 = null,
    resume_all: bool = false,
    review_mode: bool = false,
    review_args: std.ArrayList([]const u8) = .empty,
    prompt: ?[]const u8 = null,
    read_stdin: bool = false,

    fn deinit(self: ExecArgs, allocator: std.mem.Allocator) void {
        if (self.last_message_file) |path| allocator.free(path);
        if (self.output_schema_file) |path| allocator.free(path);
        for (self.image_files.items) |path| allocator.free(path);
        var image_files = self.image_files;
        image_files.deinit(allocator);
        if (self.model) |model| allocator.free(model);
        if (self.oss_provider) |provider| allocator.free(provider);
        if (self.profile) |profile| allocator.free(profile);
        if (self.cwd) |cwd| allocator.free(cwd);
        for (self.additional_writable_roots.items) |root| allocator.free(root);
        var additional_writable_roots = self.additional_writable_roots;
        additional_writable_roots.deinit(allocator);
        if (self.resume_target) |target| allocator.free(target);
        var review_args = self.review_args;
        review_args.deinit(allocator);
        if (self.prompt) |prompt| allocator.free(prompt);
    }
};

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    try runWithOptions(allocator, args, .{});
}

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    var parsed = try parseArgs(allocator, raw_args.items);
    defer parsed.deinit(allocator);
    if (parsed.profile == null) {
        if (options.profile) |profile| {
            parsed.profile = try allocator.dupe(u8, profile);
        } else if (parsed.config_profile) |profile| {
            parsed.profile = try allocator.dupe(u8, profile);
        }
    }

    if (parsed.help) {
        printHelp();
        return;
    }

    if (parsed.removed_full_auto) {
        try cli_utils.writeStderr("warning: `--full-auto` is deprecated; use `--sandbox workspace-write` instead.\n");
    }

    const effective_oss = options.oss or parsed.oss;
    const effective_oss_provider = parsed.oss_provider orelse options.oss_provider;
    const effective_cwd = parsed.cwd orelse options.cwd;
    if (effective_cwd) |cwd| try workdir.change(cwd);

    if (parsed.review_mode) {
        try review.runRawArgsWithOptions(allocator, parsed.review_args.items, .{
            .profile = parsed.profile,
            .runtime_overrides = mergedReviewOverrides(options.runtime_overrides, parsed),
            .oss = effective_oss,
            .oss_provider = effective_oss_provider,
            .ignore_user_config = parsed.ignore_user_config,
            .skip_git_repo_check = parsed.skip_git_repo_check or parsed.dangerously_bypass_approvals_and_sandbox,
        });
        return;
    }

    const stdin_is_tty = isStdinTty();
    if (parsed.prompt == null and !parsed.read_stdin and stdin_is_tty) {
        try cli_utils.writeStderr("No prompt provided. Either specify one as an argument or pipe the prompt into stdin.\n");
        return error.MissingExecPrompt;
    }
    const should_append_piped_stdin = !stdin_is_tty and !parsed.read_stdin and parsed.prompt != null and parsed.resume_target == null;
    const should_read_stdin = parsed.read_stdin or parsed.prompt == null or should_append_piped_stdin;

    const additional_writable_roots = try cli_utils.mergeStringSlices(
        allocator,
        options.additional_writable_roots,
        parsed.additional_writable_roots.items,
    );
    defer allocator.free(additional_writable_roots);

    const prompt = if (should_read_stdin) prompt: {
        if (should_append_piped_stdin) {
            try cli_utils.writeStderr("Reading additional input from stdin...\n");
        } else if (parsed.prompt == null and !parsed.read_stdin) {
            try cli_utils.writeStderr("Reading prompt from stdin...\n");
        }
        break :prompt try readPromptFromStdin(allocator, parsed.prompt, !should_append_piped_stdin);
    } else try allocator.dupe(u8, parsed.prompt.?);
    defer allocator.free(prompt);

    var cfg = try config.loadWithOptions(allocator, .{
        .profile = parsed.profile,
        .ignore_user_config = parsed.ignore_user_config,
    });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, options.runtime_overrides);
    try config.applyRuntimeOverrides(&cfg, allocator, parsed.config_overrides);
    if (parsed.model) |model| {
        try config.applyRuntimeOverrides(&cfg, allocator, .{ .model = model });
    }
    if (parsed.approval_policy) |approval_policy| cfg.approval_policy = approval_policy;
    if (parsed.sandbox_mode) |sandbox_mode| cfg.sandbox_mode = sandbox_mode;
    if (effective_oss) {
        const explicit_model = options.runtime_overrides.model != null or
            parsed.config_overrides.model != null or
            parsed.model != null;
        try config.applyOssMode(&cfg, allocator, effective_oss_provider, explicit_model);
    }
    try workdir.enforceTrustedGitRepository(allocator, parsed.skip_git_repo_check or parsed.dangerously_bypass_approvals_and_sandbox);

    var credentials = if (effective_oss)
        try auth.localOssCredentials(allocator)
    else
        try auth.loadForConfig(allocator, &cfg);
    defer credentials.deinit(allocator);

    var output_schema = try loadOutputSchema(allocator, parsed.output_schema_file);
    defer output_schema.deinit();
    var loaded_images = try input_images.load(allocator, parsed.image_files.items);
    defer loaded_images.deinit(allocator);

    var transcript = session.Transcript{};
    defer transcript.deinit(allocator);

    var session_path: ?[]const u8 = null;
    defer if (session_path) |path| allocator.free(path);
    if (!parsed.ephemeral) {
        if (parsed.resume_target) |target| {
            session_path = try session_store.resolveResumePath(allocator, cfg.codex_home, target);
            const loaded = try session_store.loadTranscript(allocator, session_path.?);
            transcript.deinit(allocator);
            transcript = loaded;
        } else {
            session_path = try session_store.createSessionPath(allocator, cfg.codex_home);
        }
    }

    const answer = try session.runTurnWithOptions(allocator, cfg, credentials, &transcript, prompt, .{
        .auto_approve = parsed.auto_approve,
        .prompt_for_approval = false,
        .json_events = parsed.json,
        .additional_writable_roots = additional_writable_roots,
        .output_schema = output_schema.value(),
        .input_images = loaded_images.data_urls,
    });
    defer allocator.free(answer);

    if (session_path) |path| {
        try session_store.saveTranscript(allocator, path, &transcript);
    }

    if (parsed.last_message_file) |path| {
        try writeFile(path, answer);
    }

    if (!parsed.json) {
        try cli_utils.writeStdout(answer);
        if (answer.len == 0 or answer[answer.len - 1] != '\n') {
            try cli_utils.writeStdout("\n");
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ExecArgs {
    var parsed = ExecArgs{};
    errdefer parsed.deinit(allocator);

    var prompt_parts = std.ArrayList([]const u8).empty;
    defer prompt_parts.deinit(allocator);

    var index: usize = 0;
    var end_options = false;
    var resume_mode = false;
    var resume_target_set = false;
    var approval_policy_requested = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--auto-approve")) {
            parsed.auto_approve = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo"))) {
            if (parsed.removed_full_auto) return error.ConflictingExecOptions;
            if (approval_policy_requested) return error.ConflictingExecOptions;
            parsed.dangerously_bypass_approvals_and_sandbox = true;
            parsed.approval_policy = .never;
            parsed.sandbox_mode = .danger_full_access;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.model) |existing| {
                allocator.free(existing);
                parsed.model = null;
            }
            parsed.model = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--model=")) {
            if (parsed.model) |existing| {
                allocator.free(existing);
                parsed.model = null;
            }
            parsed.model = try allocator.dupe(u8, arg["--model=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--oss")) {
            parsed.oss = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--local-provider")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            try setOssProvider(allocator, &parsed, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--local-provider=")) {
            try setOssProvider(allocator, &parsed, arg["--local-provider=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--ephemeral")) {
            parsed.ephemeral = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--skip-git-repo-check")) {
            parsed.skip_git_repo_check = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--full-auto")) {
            if (parsed.dangerously_bypass_approvals_and_sandbox) return error.ConflictingExecOptions;
            parsed.removed_full_auto = true;
            parsed.sandbox_mode = .workspace_write;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--ignore-user-config")) {
            parsed.ignore_user_config = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--ignore-rules")) {
            parsed.ignore_rules = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            try config.applyRawConfigOverride(&parsed.config_overrides, &parsed.config_profile, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--config=")) {
            try config.applyRawConfigOverride(&parsed.config_overrides, &parsed.config_profile, arg["--config=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--color")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            try parseColor(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--color=")) {
            try parseColor(arg["--color=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.cwd) |existing| {
                allocator.free(existing);
                parsed.cwd = null;
            }
            parsed.cwd = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--cd=")) {
            if (parsed.cwd) |existing| {
                allocator.free(existing);
                parsed.cwd = null;
            }
            parsed.cwd = try allocator.dupe(u8, arg["--cd=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            try parsed.additional_writable_roots.append(allocator, try allocator.dupe(u8, args[index]));
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--add-dir=")) {
            try parsed.additional_writable_roots.append(allocator, try allocator.dupe(u8, arg["--add-dir=".len..]));
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a"))) {
            if (parsed.dangerously_bypass_approvals_and_sandbox) return error.ConflictingExecOptions;
            approval_policy_requested = true;
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (parsed.dangerously_bypass_approvals_and_sandbox) return error.ConflictingExecOptions;
            approval_policy_requested = true;
            parsed.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--approval-policy")) {
            if (parsed.dangerously_bypass_approvals_and_sandbox) return error.ConflictingExecOptions;
            approval_policy_requested = true;
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (parsed.dangerously_bypass_approvals_and_sandbox) return error.ConflictingExecOptions;
            approval_policy_requested = true;
            parsed.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--sandbox")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            parsed.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--sandbox=")) {
            parsed.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.profile) |existing| {
                allocator.free(existing);
                parsed.profile = null;
            }
            parsed.profile = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--profile=")) {
            if (parsed.profile) |existing| {
                allocator.free(existing);
                parsed.profile = null;
            }
            parsed.profile = try allocator.dupe(u8, arg["--profile=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--experimental-json"))) {
            parsed.json = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--output-last-message") or std.mem.eql(u8, arg, "-o"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.last_message_file) |existing| {
                allocator.free(existing);
                parsed.last_message_file = null;
            }
            parsed.last_message_file = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--output-last-message=")) {
            if (parsed.last_message_file) |existing| {
                allocator.free(existing);
                parsed.last_message_file = null;
            }
            parsed.last_message_file = try allocator.dupe(u8, arg["--output-last-message=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--output-schema")) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            if (parsed.output_schema_file) |existing| {
                allocator.free(existing);
                parsed.output_schema_file = null;
            }
            parsed.output_schema_file = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--output-schema=")) {
            if (parsed.output_schema_file) |existing| {
                allocator.free(existing);
                parsed.output_schema_file = null;
            }
            parsed.output_schema_file = try allocator.dupe(u8, arg["--output-schema=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i"))) {
            index += 1;
            if (index >= args.len) return error.MissingExecOptionValue;
            try input_images.appendFiles(allocator, &parsed.image_files, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendFiles(allocator, &parsed.image_files, arg["--image=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            parsed.help = true;
            continue;
        }
        if (!end_options and resume_mode and std.mem.eql(u8, arg, "--last")) {
            try setResumeTarget(allocator, &parsed, "last");
            resume_target_set = true;
            continue;
        }
        if (!end_options and resume_mode and std.mem.eql(u8, arg, "--all")) {
            parsed.resume_all = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            std.debug.print("unknown exec option: {s}\n", .{arg});
            return error.UnknownExecOption;
        }

        if (!end_options and !resume_mode and prompt_parts.items.len == 0 and std.mem.eql(u8, arg, "resume")) {
            resume_mode = true;
            continue;
        }
        if (!end_options and !resume_mode and prompt_parts.items.len == 0 and std.mem.eql(u8, arg, "review")) {
            parsed.review_mode = true;
            index += 1;
            while (index < args.len) : (index += 1) {
                try parsed.review_args.append(allocator, args[index]);
            }
            break;
        }

        if (resume_mode and !resume_target_set) {
            try setResumeTarget(allocator, &parsed, arg);
            resume_target_set = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-") and prompt_parts.items.len == 0) {
            parsed.read_stdin = true;
        } else {
            try prompt_parts.append(allocator, arg);
        }
    }

    if (resume_mode and !resume_target_set) {
        try setResumeTarget(allocator, &parsed, "last");
    }

    if (prompt_parts.items.len > 0) {
        parsed.prompt = try cli_utils.joinWithSpaces(allocator, prompt_parts.items);
    }
    if (parsed.removed_full_auto) {
        parsed.sandbox_mode = .workspace_write;
    }

    return parsed;
}

fn mergedReviewOverrides(base: config.RuntimeOverrides, parsed: ExecArgs) config.RuntimeOverrides {
    var merged = base;
    mergeRuntimeOverrides(&merged, parsed.config_overrides);
    if (parsed.model) |model| merged.model = model;
    if (parsed.approval_policy) |approval_policy| merged.approval_policy = approval_policy;
    if (parsed.sandbox_mode) |sandbox_mode| merged.sandbox_mode = sandbox_mode;
    return merged;
}

fn mergeRuntimeOverrides(target: *config.RuntimeOverrides, source: config.RuntimeOverrides) void {
    if (source.model) |value| target.model = value;
    if (source.openai_base_url) |value| target.openai_base_url = value;
    if (source.chatgpt_base_url) |value| target.chatgpt_base_url = value;
    if (source.oss_provider) |value| target.oss_provider = value;
    if (source.approval_policy) |value| target.approval_policy = value;
    if (source.sandbox_mode) |value| target.sandbox_mode = value;
    if (source.web_search_mode) |value| target.web_search_mode = value;
    if (source.service_tier) |value| target.service_tier = value;
    if (source.syntax_theme) |value| target.syntax_theme = value;
    if (source.personality) |value| target.personality = value;
    if (source.tui_alternate_screen) |value| target.tui_alternate_screen = value;
}

fn setResumeTarget(allocator: std.mem.Allocator, parsed: *ExecArgs, target: []const u8) !void {
    if (parsed.resume_target) |existing| allocator.free(existing);
    parsed.resume_target = try allocator.dupe(u8, target);
}

fn setOssProvider(allocator: std.mem.Allocator, parsed: *ExecArgs, provider: []const u8) !void {
    if (parsed.oss_provider) |existing| {
        allocator.free(existing);
        parsed.oss_provider = null;
    }
    parsed.oss_provider = try allocator.dupe(u8, provider);
}

fn parseColor(value: []const u8) !void {
    if (std.mem.eql(u8, value, "auto") or
        std.mem.eql(u8, value, "always") or
        std.mem.eql(u8, value, "never"))
    {
        return;
    }
    return error.InvalidExecColor;
}

fn isStdinTty() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.File.stdin().isTty(io) catch false;
}

fn readPromptFromStdin(allocator: std.mem.Allocator, prefix: ?[]const u8, required: bool) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &buffer);
    const stdin_text = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stdin_text);

    if (std.mem.trim(u8, stdin_text, " \t\r\n").len == 0) {
        allocator.free(stdin_text);
        if (!required) {
            const text = prefix orelse "";
            return allocator.dupe(u8, text);
        }
        std.debug.print("No prompt provided via stdin.\n", .{});
        return error.MissingExecPrompt;
    }

    if (prefix) |text| {
        var combined = std.ArrayList(u8).empty;
        errdefer combined.deinit(allocator);
        try combined.appendSlice(allocator, text);
        try combined.appendSlice(allocator, "\n\n<stdin>\n");
        try combined.appendSlice(allocator, stdin_text);
        if (stdin_text[stdin_text.len - 1] != '\n') {
            try combined.append(allocator, '\n');
        }
        try combined.appendSlice(allocator, "</stdin>");
        allocator.free(stdin_text);
        return combined.toOwnedSlice(allocator);
    }

    return stdin_text;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = bytes,
    });
}

const LoadedOutputSchema = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn deinit(self: *LoadedOutputSchema) void {
        if (self.parsed) |*parsed| parsed.deinit();
    }

    fn value(self: *const LoadedOutputSchema) ?std.json.Value {
        if (self.parsed) |*parsed| return parsed.value;
        return null;
    }
};

fn loadOutputSchema(allocator: std.mem.Allocator, path_opt: ?[]const u8) !LoadedOutputSchema {
    const path = path_opt orelse return .{};
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);

    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) };
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig exec [OPTIONS] [PROMPT]
        \\  codex-zig exec [OPTIONS] -
        \\  codex-zig exec [OPTIONS] resume [--all] [last|ID|PATH] PROMPT
        \\  codex-zig exec [OPTIONS] review [REVIEW_OPTIONS]
        \\
        \\Options:
        \\  --auto-approve          Run requested tools without prompting
        \\  --yolo                  Danger: approval=never and sandbox=danger-full-access
        \\  -m, --model MODEL       Override the model
        \\  --oss                   Use a local open-source provider
        \\  --local-provider NAME   Local OSS provider: lmstudio or ollama
        \\  --ephemeral             Do not save or resume a session file
        \\  --skip-git-repo-check   Allow exec outside a Git repository
        \\  --ignore-user-config    Do not load CODEX_HOME/config.toml
        \\  --ignore-rules          Accepted for Rust CLI compatibility
        \\  -c, --config key=value  Override a supported config value
        \\  --color MODE            auto, always, or never
        \\  -C, --cd DIR            Use DIR as the working root
        \\  --add-dir DIR           Allow workspace-write shell tools to write DIR
        \\  -a, --ask-for-approval MODE
        \\                          untrusted, on-failure, on-request, or never
        \\  --approval-policy MODE  Alias for --ask-for-approval
        \\  -s, --sandbox MODE      read-only, workspace-write, or danger-full-access
        \\  -p, --profile PROFILE   Select a config profile
        \\  --json                  Emit JSONL events instead of plain final text
        \\  -o, --output-last-message FILE
        \\                          Write final answer to FILE
        \\  --output-schema FILE    Send a JSON Schema for the final response
        \\  -i, --image FILE        Attach local image file(s); comma-separated values accepted
        \\
    , .{});
}

test "exec args parse prompt and options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--auto-approve", "--skip-git-repo-check", "--full-auto", "--sandbox", "read-only", "--ignore-user-config", "--ignore-rules", "-c", "web_search=live", "--color", "never", "--json", "--profile", "work", "--oss", "--local-provider", "ollama", "-m", "gpt-test", "--cd", "/tmp/demo", "--add-dir", "/tmp/extra", "--image", "one.png,two.jpg", "-o", "last.txt", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.auto_approve);
    try std.testing.expect(parsed.skip_git_repo_check);
    try std.testing.expect(parsed.removed_full_auto);
    try std.testing.expect(parsed.ignore_user_config);
    try std.testing.expect(parsed.ignore_rules);
    try std.testing.expectEqual(config.SandboxMode.workspace_write, parsed.sandbox_mode.?);
    try std.testing.expectEqual(config.WebSearchMode.live, parsed.config_overrides.web_search_mode.?);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("work", parsed.profile.?);
    try std.testing.expect(parsed.oss);
    try std.testing.expectEqualStrings("ollama", parsed.oss_provider.?);
    try std.testing.expectEqualStrings("gpt-test", parsed.model.?);
    try std.testing.expectEqualStrings("/tmp/demo", parsed.cwd.?);
    try std.testing.expectEqualStrings("/tmp/extra", parsed.additional_writable_roots.items[0]);
    try std.testing.expectEqualStrings("one.png", parsed.image_files.items[0]);
    try std.testing.expectEqualStrings("two.jpg", parsed.image_files.items[1]);
    try std.testing.expectEqualStrings("last.txt", parsed.last_message_file.?);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args parse output schema" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--output-schema", "schema.json", "say", "json" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("schema.json", parsed.output_schema_file.?);
    try std.testing.expectEqualStrings("say json", parsed.prompt.?);
}

test "exec args parse resume last prompt" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--json", "resume", "last", "say", "again" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("last", parsed.resume_target.?);
    try std.testing.expectEqualStrings("say again", parsed.prompt.?);
}

test "exec args parse resume --last stdin" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "resume", "--last", "--all", "-" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("last", parsed.resume_target.?);
    try std.testing.expect(parsed.resume_all);
    try std.testing.expect(parsed.read_stdin);
}

test "exec args reject --all outside resume mode" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--all", "say", "hello" };

    try std.testing.expectError(error.UnknownExecOption, parseArgs(allocator, argv[0..]));
}

test "exec args parse ephemeral" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--ephemeral", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.ephemeral);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args keep resume literal after end options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--", "resume", "this", "prompt" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.resume_target == null);
    try std.testing.expectEqualStrings("resume this prompt", parsed.prompt.?);
}

test "exec args parse review subcommand" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--json", "--model", "gpt-test", "review", "--uncommitted" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.review_mode);
    try std.testing.expectEqualStrings("gpt-test", parsed.model.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.review_args.items.len);
    try std.testing.expectEqualStrings("--uncommitted", parsed.review_args.items[0]);
    try std.testing.expect(parsed.prompt == null);
}

test "exec args keep review literal after end options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--", "review", "--uncommitted" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(!parsed.review_mode);
    try std.testing.expectEqualStrings("review --uncommitted", parsed.prompt.?);
}

test "exec args parse approval and sandbox options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--approval-policy=never", "--sandbox", "read-only", "--output-last-message=last.txt", "say", "hello" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(config.ApprovalPolicy.never, parsed.approval_policy.?);
    try std.testing.expectEqual(config.SandboxMode.read_only, parsed.sandbox_mode.?);
    try std.testing.expectEqualStrings("last.txt", parsed.last_message_file.?);
    try std.testing.expectEqualStrings("say hello", parsed.prompt.?);
}

test "exec args reject full auto with yolo" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--full-auto", "--yolo", "say", "nope" };
    try std.testing.expectError(error.ConflictingExecOptions, parseArgs(allocator, argv[0..]));
}

test "exec args reject yolo with approval policy" {
    const allocator = std.testing.allocator;

    const yolo_first = [_][]const u8{ "--yolo", "--approval-policy=never", "say", "nope" };
    try std.testing.expectError(error.ConflictingExecOptions, parseArgs(allocator, yolo_first[0..]));

    const approval_first = [_][]const u8{ "--ask-for-approval", "never", "--yolo", "say", "nope" };
    try std.testing.expectError(error.ConflictingExecOptions, parseArgs(allocator, approval_first[0..]));
}

test "exec args parse stdin sentinel with context prompt" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "-", "summarize", "this" };
    const parsed = try parseArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.read_stdin);
    try std.testing.expectEqualStrings("summarize this", parsed.prompt.?);
}
