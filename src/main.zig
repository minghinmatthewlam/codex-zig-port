const std = @import("std");
const builtin = @import("builtin");

const apply_command = @import("apply_command.zig");
const app_cmd = @import("app_cmd.zig");
const app_server_cmd = @import("app_server_cmd.zig");
const api = @import("api.zig");
const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const cloud_cmd = @import("cloud_cmd.zig");
const completion_cmd = @import("completion_cmd.zig");
const config = @import("config.zig");
const debug_cmd = @import("debug_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const env = @import("env.zig");
const exec = @import("exec.zig");
const exec_server_cmd = @import("exec_server_cmd.zig");
const execpolicy_cmd = @import("execpolicy_cmd.zig");
const features_cmd = @import("features_cmd.zig");
const git_diff = @import("git_diff.zig");
const input_images = @import("input_images.zig");
const login = @import("login.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const mcp_server_cmd = @import("mcp_server_cmd.zig");
const plugin_cmd = @import("plugin_cmd.zig");
const remote_control_cmd = @import("remote_control_cmd.zig");
const remote_fork = @import("remote_fork.zig");
const responses_api_proxy = @import("responses_api_proxy.zig");
const review = @import("review.zig");
const sandbox = @import("sandbox.zig");
const sandbox_cmd = @import("sandbox_cmd.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");
const update_cmd = @import("update_cmd.zig");
const workdir = @import("workdir.zig");

const version = "0.0.1";

const CliOverrides = struct {
    profile: ?[]const u8 = null,
    profile_v2: ?[]const u8 = null,
    runtime: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
    no_alt_screen: bool = false,
    explicit_approval_policy: bool = false,
    remote: ?[]const u8 = null,
    remote_auth_token_env: ?[]const u8 = null,
    local_remote_control: bool = false,
    remote_control_bind: ?[]const u8 = null,
    strict_config: bool = false,
    unknown_config_override: ?[]const u8 = null,

    fn deinit(self: *CliOverrides, allocator: std.mem.Allocator) void {
        if (self.unknown_config_override) |field| allocator.free(field);
    }
};

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch |err| {
        switch (err) {
            error.RemovedModelProviderChatWireApi => std.debug.print(
                "error: `wire_api = \"chat\"` is no longer supported. Set `wire_api = \"responses\"` in your provider config.\n",
                .{},
            ),
            error.InvalidModelProviderWireApi => std.debug.print(
                "error: unsupported model provider `wire_api`; supported values: responses\n",
                .{},
            ),
            error.ModelProviderAuthConflict => std.debug.print(
                "error: provider command auth cannot be combined with `env_key`, `experimental_bearer_token`, or `requires_openai_auth = true`\n",
                .{},
            ),
            error.UpdateUnavailableDebugBuild => std.debug.print(
                "error: `codex update` is not available in debug builds. Install a release build of Codex to use this command.\n",
                .{},
            ),
            error.UpdateInstallMethodUnknown => std.debug.print(
                "error: Could not detect the Codex installation method. Please update manually: https://developers.openai.com/codex/cli/\n",
                .{},
            ),
            error.UpdateCommandFailed => std.debug.print(
                "error: update command failed\n",
                .{},
            ),
            error.DoctorChecksFailed => {},
            error.ResponsesApiProxyHelpRequested => std.process.exit(0),
            error.ResponsesApiProxyMissingApiKey => std.debug.print(
                "error: API key must be provided via stdin (e.g. printenv OPENAI_API_KEY | codex responses-api-proxy)\n",
                .{},
            ),
            error.ResponsesApiProxyInvalidApiKey => std.debug.print(
                "error: API key may only contain ASCII letters, numbers, '-' or '_'\n",
                .{},
            ),
            error.ResponsesApiProxyApiKeyTooLarge => std.debug.print(
                "error: API key is too large to fit in the 1024-byte buffer\n",
                .{},
            ),
            error.InvalidResponsesApiProxyUpstreamUrl => std.debug.print(
                "error: upstream URL must include a host\n",
                .{},
            ),
            error.RemoteControlHelpRequested => std.process.exit(0),
            error.RemoteControlStateDbUnavailable => std.debug.print(
                "error: no transport configured; remote control disabled because sqlite state db is unavailable\n",
                .{},
            ),
            error.AppServerDaemonCommandFailed => {},
            error.ExecServerCommandFailed => {},
            error.HookStoppedTurn => {},
            error.StrictConfigUnknownField => {},
            error.StrictConfigUnsupportedForSubcommand => {},
            error.UnexpectedPromptArgument => {},
            error.ProfileV2UnsupportedCommand => std.debug.print(
                "Error: --profile-v2 only applies to runtime commands: `codex`, `codex exec`, `codex review`, `codex resume`, `codex fork`, and `codex debug prompt-input`.\n",
                .{},
            ),
            error.InvalidProfileV2Name => std.debug.print(
                "error: invalid --profile-v2 value; pass a plain name such as `work`\n",
                .{},
            ),
            error.ProfileV2LegacyProfileConflict => std.debug.print(
                "error: selected profile-v2 cannot also exist as a legacy [profiles.<name>] section in config.toml\n",
                .{},
            ),
            error.InvalidMcpServerTransport => std.debug.print(
                "error: invalid transport\n",
                .{},
            ),
            error.McpStdioUnsupportedUrl => std.debug.print(
                "error: url is not supported for stdio\n",
                .{},
            ),
            error.McpStdioUnsupportedBearerTokenEnvVar => std.debug.print(
                "error: bearer_token_env_var is not supported for stdio\n",
                .{},
            ),
            error.McpStdioUnsupportedBearerToken => std.debug.print(
                "error: bearer_token is not supported for stdio\n",
                .{},
            ),
            error.McpStdioUnsupportedHttpHeaders => std.debug.print(
                "error: http_headers is not supported for stdio\n",
                .{},
            ),
            error.McpStdioUnsupportedEnvHttpHeaders => std.debug.print(
                "error: env_http_headers is not supported for stdio\n",
                .{},
            ),
            error.McpStdioUnsupportedOauthResource => std.debug.print(
                "error: oauth_resource is not supported for stdio\n",
                .{},
            ),
            error.McpStreamableHttpUnsupportedArgs => std.debug.print(
                "error: args is not supported for streamable_http\n",
                .{},
            ),
            error.McpStreamableHttpUnsupportedEnv => std.debug.print(
                "error: env is not supported for streamable_http\n",
                .{},
            ),
            error.McpStreamableHttpUnsupportedEnvVars => std.debug.print(
                "error: env_vars is not supported for streamable_http\n",
                .{},
            ),
            error.McpStreamableHttpUnsupportedCwd => std.debug.print(
                "error: cwd is not supported for streamable_http\n",
                .{},
            ),
            error.McpStreamableHttpUnsupportedBearerToken => std.debug.print(
                "error: bearer_token is not supported for streamable_http\n",
                .{},
            ),
            error.HelpSubcommandInvalid => {},
            else => std.debug.print("error: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn mainInner(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var additional_writable_roots = std.ArrayList([]const u8).empty;
    defer additional_writable_roots.deinit(allocator);
    var initial_image_files = std.ArrayList([]const u8).empty;
    defer {
        for (initial_image_files.items) |path| allocator.free(path);
        initial_image_files.deinit(allocator);
    }
    var root_config_child_args = std.ArrayList([]const u8).empty;
    defer root_config_child_args.deinit(allocator);
    var runtime_feature_overrides = features_cmd.FeatureOverrides{};
    defer runtime_feature_overrides.deinit(allocator);

    var overrides = CliOverrides{};
    defer overrides.deinit(allocator);
    var cmd_opt: ?[]const u8 = null;
    var forced_initial_prompt: ?[]const u8 = null;
    defer if (forced_initial_prompt) |prompt| allocator.free(prompt);
    var approval_policy_requested = false;
    var dangerous_bypass_requested = false;
    var conflicting_cli_options = false;
    var cwd_applied = false;
    var pending_arg: ?[]const u8 = null;
    const tail_has_help_or_version = try processArgsTailHasHelpOrVersion(allocator, init.minimal.args);
    while (true) {
        const arg = if (pending_arg) |value| arg: {
            pending_arg = null;
            break :arg value;
        } else args.next() orelse break;
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            overrides.profile = try nextRootOptionValue(&args, error.MissingProfileOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            overrides.profile = arg["--profile=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile-v2")) {
            const value = try nextRootOptionValue(&args, error.MissingProfileOptionValue);
            try config.validateProfileV2Name(value);
            overrides.profile_v2 = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile-v2=")) {
            const value = arg["--profile-v2=".len..];
            try config.validateProfileV2Name(value);
            overrides.profile_v2 = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C")) {
            overrides.cwd = try nextRootOptionValue(&args, error.MissingCdOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cd=")) {
            overrides.cwd = arg["--cd=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--add-dir")) {
            try additional_writable_roots.append(allocator, try nextRootOptionValue(&args, error.MissingAddDirOptionValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            try additional_writable_roots.append(allocator, arg["--add-dir=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            const raw = try nextRootOptionValue(&args, error.MissingConfigOptionValue);
            if (!tail_has_help_or_version) {
                try config.rememberStrictConfigUnknownOverride(allocator, &overrides.unknown_config_override, raw);
                try config.applyRawConfigOverride(
                    &overrides.runtime,
                    &overrides.profile,
                    raw,
                );
            }
            try root_config_child_args.append(allocator, arg);
            try root_config_child_args.append(allocator, raw);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            const raw = arg["--config=".len..];
            if (!tail_has_help_or_version) {
                try config.rememberStrictConfigUnknownOverride(allocator, &overrides.unknown_config_override, raw);
                try config.applyRawConfigOverride(
                    &overrides.runtime,
                    &overrides.profile,
                    raw,
                );
            }
            try root_config_child_args.append(allocator, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            overrides.runtime.model = try nextRootOptionValue(&args, error.MissingModelOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            overrides.runtime.model = arg["--model=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            const first_value = args.next() orelse return error.MissingImageOptionValue;
            pending_arg = input_images.appendVariadicFilesFromIterator(allocator, &initial_image_files, &args, first_value) catch |err| switch (err) {
                error.MissingImageValue => return error.MissingImageOptionValue,
                else => return err,
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            pending_arg = try input_images.appendVariadicFilesFromIteratorAfterValue(allocator, &initial_image_files, &args, arg["--image=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--enable")) {
            const feature = try nextRootOptionValue(&args, error.MissingFeatureName);
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, feature, true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            const feature = try nextRootOptionValue(&args, error.MissingFeatureName);
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, feature, false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.eql(u8, arg, "--oss")) {
            overrides.oss = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--local-provider")) {
            overrides.oss_provider = try nextRootOptionValue(&args, error.MissingLocalProviderOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--local-provider=")) {
            overrides.oss_provider = arg["--local-provider=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a")) {
            if (dangerous_bypass_requested) conflicting_cli_options = true;
            approval_policy_requested = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(try nextRootOptionValue(&args, error.MissingApprovalOptionValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (dangerous_bypass_requested) conflicting_cli_options = true;
            approval_policy_requested = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--approval-policy")) {
            if (dangerous_bypass_requested) conflicting_cli_options = true;
            approval_policy_requested = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(try nextRootOptionValue(&args, error.MissingApprovalOptionValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (dangerous_bypass_requested) conflicting_cli_options = true;
            approval_policy_requested = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(try nextRootOptionValue(&args, error.MissingSandboxOptionValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo")) {
            if (approval_policy_requested) conflicting_cli_options = true;
            dangerous_bypass_requested = true;
            overrides.runtime.approval_policy = .never;
            overrides.runtime.sandbox_mode = .danger_full_access;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust")) {
            overrides.runtime.bypass_hook_trust = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-config")) {
            overrides.strict_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--search")) {
            overrides.runtime.web_search_mode = .live;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            overrides.remote = try nextRootOptionValue(&args, error.MissingRemoteOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            overrides.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-auth-token-env")) {
            overrides.remote_auth_token_env = try nextRootOptionValue(&args, error.MissingRemoteAuthTokenEnvOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-auth-token-env=")) {
            overrides.remote_auth_token_env = arg["--remote-auth-token-env=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control")) {
            overrides.local_remote_control = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control-bind")) {
            overrides.remote_control_bind = try nextRootOptionValue(&args, error.MissingRemoteControlBindOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-control-bind=")) {
            overrides.remote_control_bind = arg["--remote-control-bind=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            overrides.no_alt_screen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            if (args.next()) |first| {
                forced_initial_prompt = try joinInitialPrompt(allocator, first, &args);
            }
            break;
        }
        if (isHelpFlag(arg) or isVersionFlag(arg)) {
            cmd_opt = arg;
            break;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownCliOption;
        }
        cmd_opt = arg;
        break;
    }
    overrides.additional_writable_roots = additional_writable_roots.items;
    const prompt_fallback_command = if (cmd_opt) |cmd|
        !isKnownRootCommand(cmd) and !isHelpFlag(cmd) and !isVersionFlag(cmd)
    else
        false;
    const defer_semantic_checks = tail_has_help_or_version or prompt_fallback_command;
    if (!defer_semantic_checks and conflicting_cli_options) return error.ConflictingCliOptions;
    if (!defer_semantic_checks and overrides.strict_config) {
        if (cmd_opt) |cmd| {
            if (strictConfigUnsupportedSubcommandName(cmd)) |subcommand| {
                return rejectStrictConfigForSubcommand(subcommand);
            }
        }
        if (overrides.unknown_config_override) |field| return config.failStrictConfigUnknownCliOverride(field);
    }
    if (!defer_semantic_checks and overrides.profile_v2 != null) {
        if (cmd_opt) |cmd| {
            if (profileV2UnsupportedSubcommandName(cmd) != null) {
                return error.ProfileV2UnsupportedCommand;
            }
        }
    }
    const dispatch_strict_config = overrides.strict_config and !defer_semantic_checks;
    const dispatch_unknown_config_override: ?[]const u8 = if (defer_semantic_checks) null else overrides.unknown_config_override;

    const should_apply_cwd = if (cmd_opt) |cmd|
        rootCommandAppliesCwdBeforeDispatch(cmd)
    else
        true;
    if (!defer_semantic_checks and should_apply_cwd) {
        if (overrides.cwd) |cwd| {
            try workdir.change(cwd);
            cwd_applied = true;
        }
    }

    if (forced_initial_prompt) |initial_prompt| {
        try runTuiWithImages(allocator, initial_image_files.items, .{
            .profile = overrides.profile,
            .profile_v2 = overrides.profile_v2,
            .runtime_overrides = overrides.runtime,
            .oss = overrides.oss,
            .oss_provider = overrides.oss_provider,
            .additional_writable_roots = overrides.additional_writable_roots,
            .initial_prompt = initial_prompt,
            .no_alt_screen = overrides.no_alt_screen,
            .remote = overrides.remote,
            .remote_auth_token_env = overrides.remote_auth_token_env,
            .local_remote_control = overrides.local_remote_control,
            .remote_control_bind = overrides.remote_control_bind,
            .feature_overrides = runtime_feature_overrides,
            .strict_config = overrides.strict_config,
        });
        return;
    }

    if (cmd_opt) |cmd| {
        if (isHelpFlag(cmd)) {
            try printHelp();
            return;
        }
        if (isVersionFlag(cmd)) {
            printVersion();
            return;
        }
        if (!defer_semantic_checks and commandRejectsRootRemote(cmd)) {
            if (std.mem.eql(u8, cmd, "app-server") and hasRootInteractiveOnlyFlags(overrides)) {
                var remaining = try collectRemainingArgs(allocator, &args);
                defer remaining.deinit(allocator);
                try rejectRemoteModeForSubcommand(
                    overrides.remote,
                    overrides.remote_auth_token_env,
                    overrides.local_remote_control,
                    overrides.remote_control_bind,
                    app_server_cmd.remoteRejectionLabel(remaining.items),
                );
            }
            try rejectRemoteModeForSubcommand(
                overrides.remote,
                overrides.remote_auth_token_env,
                overrides.local_remote_control,
                overrides.remote_control_bind,
                cmd,
            );
        }
        if (std.mem.eql(u8, cmd, "auth-status")) {
            if (args.next()) |value| {
                if (isHelpFlag(value)) {
                    printAuthStatusHelp();
                    return;
                }
                return error.UnknownAuthStatusOption;
            }
            try runAuthStatus(allocator, overrides);
            return;
        }
        if (std.mem.eql(u8, cmd, "login")) {
            try login.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "logout")) {
            if (args.next()) |value| {
                if (isHelpFlag(value)) {
                    printLogoutHelp();
                    return;
                }
                return error.UnknownLogoutOption;
            }
            try login.runLogout(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "doctor")) {
            try doctor_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .feature_overrides = runtime_feature_overrides,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .version = version,
                .strict_config = dispatch_strict_config,
                .unknown_config_override = dispatch_unknown_config_override,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "review")) {
            try review.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .profile_v2 = overrides.profile_v2,
                .runtime_overrides = overrides.runtime,
                .feature_overrides = runtime_feature_overrides,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .strict_config = dispatch_strict_config,
                .unknown_config_override = dispatch_unknown_config_override,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "sandbox")) {
            try sandbox_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .cwd = overrides.cwd,
                .additional_writable_roots = overrides.additional_writable_roots,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "features")) {
            try features_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = runtime_feature_overrides,
            });
            return;
        }
        if (isCloudCommand(cmd)) {
            try cloud_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "completion")) {
            try completion_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "debug")) {
            try debug_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .profile_v2 = overrides.profile_v2,
                .runtime_overrides = overrides.runtime,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "execpolicy")) {
            try execpolicy_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "mcp")) {
            try mcp_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "app-server")) {
            try app_server_cmd.runWithOptions(allocator, &args, .{
                .runtime_overrides = overrides.runtime,
                .feature_overrides = runtime_feature_overrides,
                .child_global_args = root_config_child_args.items,
                .bypass_hook_trust = overrides.runtime.bypass_hook_trust orelse false,
                .strict_config = dispatch_strict_config,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "plugin")) {
            try plugin_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "app")) {
            try app_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "update")) {
            try runUpdateCommand(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "responses-api-proxy")) {
            try responses_api_proxy.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "exec-server")) {
            try exec_server_cmd.runWithOptions(allocator, &args, .{
                .strict_config = dispatch_strict_config,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "remote-control")) {
            try remote_control_cmd.runWithOptions(allocator, &args, .{
                .feature_overrides = runtime_feature_overrides,
                .child_global_args = root_config_child_args.items,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "stdio-to-uds")) {
            try runStdioToUdsCommand(allocator, &args);
            return;
        }
        if (isApplyCommand(cmd)) {
            try apply_command.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "help")) {
            try runHelpCommand(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "mcp-server")) {
            try mcp_server_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .additional_writable_roots = overrides.additional_writable_roots,
                .strict_config = dispatch_strict_config,
            });
            return;
        }
        if (isExecCommand(cmd)) {
            try exec.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .profile_v2 = overrides.profile_v2,
                .runtime_overrides = overrides.runtime,
                .feature_overrides = runtime_feature_overrides,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .cwd = overrides.cwd,
                .additional_writable_roots = overrides.additional_writable_roots,
                .explicit_approval_policy = overrides.explicit_approval_policy,
                .strict_config = dispatch_strict_config,
                .unknown_config_override = dispatch_unknown_config_override,
            });
            return;
        }
        if (std.mem.eql(u8, cmd, "remote-fork")) {
            var remaining = try collectRemainingArgs(allocator, &args);
            defer remaining.deinit(allocator);
            var parsed = try parseRemoteForkCommandArgs(allocator, remaining.items);
            defer parsed.deinit(allocator);
            if (parsed.help) {
                printRemoteForkHelp();
                return;
            }
            var launch = try prepareSessionLaunchOptions(allocator, overrides, runtime_feature_overrides, initial_image_files.items, parsed);
            defer launch.deinit(allocator);
            var imported = try remote_fork.importRemoteFork(allocator, parsed.target.?);
            defer imported.deinit(allocator);

            var options = launch.tui_options;
            options.fork_target = imported.thread_id;
            options.fork_show_all = true;
            try runTuiWithImages(allocator, launch.image_files, options);
            return;
        }
        if (std.mem.eql(u8, cmd, "resume")) {
            var remaining = try collectRemainingArgs(allocator, &args);
            defer remaining.deinit(allocator);
            var parsed = try parseSessionCommandArgs(allocator, remaining.items, true);
            defer parsed.deinit(allocator);
            if (parsed.help) {
                printResumeHelp();
                return;
            }
            var launch = try prepareSessionLaunchOptions(allocator, overrides, runtime_feature_overrides, initial_image_files.items, parsed);
            defer launch.deinit(allocator);
            if (parsed.last) {
                var options = launch.tui_options;
                options.resume_target = "last";
                try runTuiWithImages(allocator, launch.image_files, options);
                return;
            }
            if (parsed.target) |target| {
                var options = launch.tui_options;
                options.resume_target = target;
                try runTuiWithImages(allocator, launch.image_files, options);
            } else {
                var options = launch.tui_options;
                options.resume_picker = true;
                options.resume_show_all = parsed.show_all;
                try runTuiWithImages(allocator, launch.image_files, options);
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "fork")) {
            var remaining = try collectRemainingArgs(allocator, &args);
            defer remaining.deinit(allocator);
            var parsed = try parseSessionCommandArgs(allocator, remaining.items, false);
            defer parsed.deinit(allocator);
            if (parsed.help) {
                printForkHelp();
                return;
            }
            var launch = try prepareSessionLaunchOptions(allocator, overrides, runtime_feature_overrides, initial_image_files.items, parsed);
            defer launch.deinit(allocator);
            if (parsed.last) {
                var options = launch.tui_options;
                options.fork_target = "last";
                try runTuiWithImages(allocator, launch.image_files, options);
                return;
            }
            if (parsed.target) |target| {
                var options = launch.tui_options;
                options.fork_target = target;
                try runTuiWithImages(allocator, launch.image_files, options);
            } else {
                var options = launch.tui_options;
                options.fork_picker = true;
                options.fork_show_all = parsed.show_all;
                try runTuiWithImages(allocator, launch.image_files, options);
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "sessions")) {
            const limit_arg = args.next();
            if (limit_arg) |value| {
                if (isHelpFlag(value)) {
                    printSessionsHelp();
                    return;
                }
            }
            try runSessions(allocator, limit_arg, overrides.profile, overrides.strict_config);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-demo")) {
            try runMockDemo(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-apply-patch")) {
            try runMockApplyPatch(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-policy-demo")) {
            try runMockPolicyDemo(allocator);
            return;
        }
        if (std.mem.eql(u8, cmd, "mock-sandbox-demo")) {
            try runMockSandboxDemo(allocator, overrides.additional_writable_roots);
            return;
        }
        var prompt_tail = try collectRemainingArgs(allocator, &args);
        defer prompt_tail.deinit(allocator);
        const tail_action = try parseRootPromptTail(
            allocator,
            prompt_tail.items,
            &overrides,
            &runtime_feature_overrides,
            &additional_writable_roots,
            &initial_image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        );
        overrides.additional_writable_roots = additional_writable_roots.items;
        if (tail_action) |action| {
            switch (action) {
                .help => try printHelp(),
                .version => printVersion(),
            }
            return;
        }
        if (conflicting_cli_options) return error.ConflictingCliOptions;
        if (overrides.strict_config) {
            if (overrides.unknown_config_override) |field| return config.failStrictConfigUnknownCliOverride(field);
        }
        if (!cwd_applied) {
            if (overrides.cwd) |cwd| {
                try workdir.change(cwd);
                cwd_applied = true;
            }
        }
        const initial_prompt = try allocator.dupe(u8, cmd);
        defer allocator.free(initial_prompt);
        try runTuiWithImages(allocator, initial_image_files.items, .{
            .profile = overrides.profile,
            .profile_v2 = overrides.profile_v2,
            .runtime_overrides = overrides.runtime,
            .oss = overrides.oss,
            .oss_provider = overrides.oss_provider,
            .additional_writable_roots = overrides.additional_writable_roots,
            .initial_prompt = initial_prompt,
            .no_alt_screen = overrides.no_alt_screen,
            .remote = overrides.remote,
            .remote_auth_token_env = overrides.remote_auth_token_env,
            .local_remote_control = overrides.local_remote_control,
            .remote_control_bind = overrides.remote_control_bind,
            .feature_overrides = runtime_feature_overrides,
            .strict_config = overrides.strict_config,
        });
        return;
    }

    try runTuiWithImages(allocator, initial_image_files.items, .{
        .profile = overrides.profile,
        .profile_v2 = overrides.profile_v2,
        .runtime_overrides = overrides.runtime,
        .oss = overrides.oss,
        .oss_provider = overrides.oss_provider,
        .additional_writable_roots = overrides.additional_writable_roots,
        .no_alt_screen = overrides.no_alt_screen,
        .remote = overrides.remote,
        .remote_auth_token_env = overrides.remote_auth_token_env,
        .local_remote_control = overrides.local_remote_control,
        .remote_control_bind = overrides.remote_control_bind,
        .feature_overrides = runtime_feature_overrides,
        .strict_config = overrides.strict_config,
    });
}

fn runTuiWithImages(
    allocator: std.mem.Allocator,
    image_files: []const []const u8,
    options: tui.Options,
) !void {
    if (options.remote != null) {
        const image_paths = try resolveImageFiles(allocator, image_files);
        defer freeStringSlice(allocator, image_paths);
        var next_options = options;
        next_options.initial_input_image_paths = image_paths;
        try tui.runWithOptions(allocator, next_options);
        return;
    }

    var loaded_images = try input_images.load(allocator, image_files);
    defer loaded_images.deinit(allocator);

    var next_options = options;
    next_options.initial_input_images = loaded_images.data_urls;
    try tui.runWithOptions(allocator, next_options);
}

fn resolveImageFiles(allocator: std.mem.Allocator, image_files: []const []const u8) ![]const []const u8 {
    if (image_files.len == 0) return &.{};

    const resolved = try allocator.alloc([]const u8, image_files.len);
    errdefer allocator.free(resolved);
    var count: usize = 0;
    errdefer {
        for (resolved[0..count]) |path| allocator.free(path);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    for (image_files) |path| {
        const real_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        defer allocator.free(real_path);
        resolved[count] = try allocator.dupe(u8, real_path);
        count += 1;
    }
    return resolved;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

fn nextRootOptionValue(args: *std.process.Args.Iterator, missing_error: anyerror) ![]const u8 {
    const value = args.next() orelse return missing_error;
    if (isRootPromptOptionValueBoundary(value)) {
        if (isKnownRootOptionBoundary(value)) return missing_error;
        return error.UnknownCliOption;
    }
    return value;
}

fn processArgsTailHasHelpOrVersion(allocator: std.mem.Allocator, process_args: std.process.Args) !bool {
    var scan = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer scan.deinit();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    while (scan.next()) |arg| {
        try argv.append(allocator, arg);
    }
    if (argv.items.len <= 1) return false;
    return rootArgsTailHasHelpOrVersion(allocator, argv.items[1..]);
}

fn rootArgsTailHasHelpOrVersion(allocator: std.mem.Allocator, args: []const []const u8) !bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg) or isVersionFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--")) return false;

        if (rootOptionConsumesSingleValue(arg)) {
            index += 1;
            if (index >= args.len) return false;
            if (isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (rootOptionHasInlineValue(arg) or rootOptionIsBoolean(arg)) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            var next = index + 1;
            var consumed = false;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
                consumed = true;
            }
            if (!consumed) return false;
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            var next = index + 1;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
            }
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;

        return try rootCommandTailHasHelpOrVersion(allocator, arg, args[index + 1 ..]);
    }
    return false;
}

fn rootCommandTailHasHelpOrVersion(allocator: std.mem.Allocator, cmd: []const u8, tail: []const []const u8) !bool {
    if (std.mem.eql(u8, cmd, "sandbox")) return sandboxTailHasHelp(tail);
    if (isExecCommand(cmd)) return try exec.tailHasHelpOrVersion(allocator, tail);
    if (std.mem.eql(u8, cmd, "app-server")) return app_server_cmd.tailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "plugin")) return pluginTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "mcp")) return mcp_cmd.tailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "debug")) return debugTailHasHelp(tail);
    if (isCloudCommand(cmd)) return try cloud_cmd.tailHasHelpOrVersion(allocator, tail);
    if (std.mem.eql(u8, cmd, "login")) return loginTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "help")) return true;
    if (std.mem.startsWith(u8, cmd, "mock-")) return false;
    if (!isKnownRootCommand(cmd)) return promptFallbackTailHasHelpOrVersion(tail);
    if (std.mem.eql(u8, cmd, "auth-status") or
        std.mem.eql(u8, cmd, "logout") or
        std.mem.eql(u8, cmd, "update") or
        std.mem.eql(u8, cmd, "stdio-to-uds"))
    {
        return noArgumentTailHasHelp(tail);
    }
    if (std.mem.eql(u8, cmd, "completion")) return completionTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "doctor")) return doctorTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "review")) return reviewTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "features")) return featuresTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "execpolicy")) return execpolicyTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "app")) return appTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "responses-api-proxy")) return responsesApiProxyTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "exec-server")) return execServerTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "remote-control")) return remoteControlTailHasHelp(tail);
    if (isApplyCommand(cmd)) return applyTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "mcp-server")) return mcpServerTailHasHelp(tail);
    if (std.mem.eql(u8, cmd, "resume")) return sessionCommandTailHasHelp(allocator, tail, true);
    if (std.mem.eql(u8, cmd, "fork")) return sessionCommandTailHasHelp(allocator, tail, false);
    if (std.mem.eql(u8, cmd, "remote-fork")) return remoteForkTailHasHelp(allocator, tail);
    if (std.mem.eql(u8, cmd, "sessions")) return noArgumentTailHasHelp(tail);
    return false;
}

fn noArgumentTailHasHelp(args: []const []const u8) bool {
    return args.len > 0 and isHelpFlag(args[0]);
}

fn completionTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (completionShellNameIsValid(args[0])) {
        return args.len > 1 and isHelpFlag(args[1]);
    }
    return false;
}

fn completionShellNameIsValid(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "bash") or
        std.mem.eql(u8, arg, "elvish") or
        std.mem.eql(u8, arg, "fish") or
        std.mem.eql(u8, arg, "powershell") or
        std.mem.eql(u8, arg, "zsh");
}

fn promptFallbackTailHasHelpOrVersion(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg) or isVersionFlag(arg)) return true;

        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            var next = index + 1;
            var consumed = false;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
                consumed = true;
            }
            if (!consumed) return false;
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            var next = index + 1;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
            }
            index = next - 1;
            continue;
        }
        if (rootOptionConsumesSingleValue(arg)) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (rootOptionHasInlineValue(arg) or rootOptionIsBoolean(arg)) continue;
        return false;
    }
    return false;
}

const TailOptionScan = enum {
    not_handled,
    valid,
    invalid,
};

fn scanConfigFeatureTailOption(
    args: []const []const u8,
    index: *usize,
    arg: []const u8,
    accept_features: bool,
) TailOptionScan {
    if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
        index.* += 1;
        if (index.* >= args.len or isRootPromptOptionValueBoundary(args[index.*])) return .invalid;
        return .valid;
    }
    if (std.mem.startsWith(u8, arg, "--config=")) {
        _ = arg["--config=".len..];
        return .valid;
    }
    if (!accept_features) return .not_handled;
    if (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable")) {
        index.* += 1;
        if (index.* >= args.len or isRootPromptOptionValueBoundary(args[index.*])) return .invalid;
        return .valid;
    }
    if (std.mem.startsWith(u8, arg, "--enable=")) {
        return .valid;
    }
    if (std.mem.startsWith(u8, arg, "--disable=")) {
        return .valid;
    }
    return .not_handled;
}

fn doctorTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--json") or
            std.mem.eql(u8, arg, "--summary") or
            std.mem.eql(u8, arg, "--all") or
            std.mem.eql(u8, arg, "--no-color") or
            std.mem.eql(u8, arg, "--ascii") or
            std.mem.eql(u8, arg, "--strict-config"))
        {
            continue;
        }
        switch (scanConfigFeatureTailOption(args, &index, arg, true)) {
            .valid => continue,
            .invalid => return false,
            .not_handled => {},
        }
        return false;
    }
    return false;
}

fn reviewTailHasHelp(args: []const []const u8) bool {
    var uncommitted = false;
    var base = false;
    var commit = false;
    var commit_title = false;
    var read_stdin = false;
    var prompt_parts = false;
    var end_options = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and isHelpFlag(arg)) return true;
        if (!end_options) {
            switch (scanConfigFeatureTailOption(args, &index, arg, true)) {
                .valid => continue,
                .invalid => return false,
                .not_handled => {},
            }
        }
        if (!end_options and std.mem.eql(u8, arg, "--strict-config")) continue;
        if (!end_options and std.mem.eql(u8, arg, "--uncommitted")) {
            uncommitted = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--base") or std.mem.eql(u8, arg, "--commit") or std.mem.eql(u8, arg, "--title"))) {
            const option = arg;
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            if (std.mem.eql(u8, option, "--base")) base = true;
            if (std.mem.eql(u8, option, "--commit")) commit = true;
            if (std.mem.eql(u8, option, "--title")) commit_title = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--base=")) {
            base = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--commit=")) {
            commit = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--title=")) {
            commit_title = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "-") and !prompt_parts) {
            read_stdin = true;
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-")) return false;
        if (prompt_parts or read_stdin) return false;
        prompt_parts = true;
    }

    var target_count: usize = 0;
    if (uncommitted) target_count += 1;
    if (base) target_count += 1;
    if (commit) target_count += 1;
    if (read_stdin) target_count += 1;
    if (prompt_parts) target_count += 1;
    if (target_count > 1) return false;
    if (commit_title and !commit) return false;
    return false;
}

fn featuresTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (std.mem.eql(u8, args[0], "list")) return featuresListTailHasHelp(args[1..]);
    if (std.mem.eql(u8, args[0], "enable") or std.mem.eql(u8, args[0], "disable")) {
        if (args.len < 2) return false;
        if (isHelpFlag(args[1])) return true;
        return !std.mem.startsWith(u8, args[1], "-") and args.len > 2 and isHelpFlag(args[2]);
    }
    return false;
}

fn featuresListTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            continue;
        }
        return false;
    }
    return false;
}

fn execpolicyTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (!std.mem.eql(u8, args[0], "check")) return false;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--rules") or std.mem.eql(u8, arg, "-r")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--rules=")) continue;
        if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "--resolve-host-executables")) continue;
        return false;
    }
    return false;
}

fn appTailHasHelp(args: []const []const u8) bool {
    var path_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--download-url")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--download-url=")) continue;
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (path_seen) return false;
        path_seen = true;
    }
    return false;
}

fn responsesApiProxyTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--http-shutdown")) continue;
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            if (!responsesApiProxyPortIsValid(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            if (!responsesApiProxyPortIsValid(arg["--port=".len..])) return false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--server-info") or
            std.mem.eql(u8, arg, "--upstream-url") or
            std.mem.eql(u8, arg, "--dump-dir"))
        {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--server-info=") or
            std.mem.startsWith(u8, arg, "--upstream-url=") or
            std.mem.startsWith(u8, arg, "--dump-dir="))
        {
            continue;
        }
        return false;
    }
    return false;
}

fn responsesApiProxyPortIsValid(value: []const u8) bool {
    if (value.len == 0) return false;
    _ = std.fmt.parseUnsigned(u16, value, 10) catch return false;
    return true;
}

fn execServerTailHasHelp(args: []const []const u8) bool {
    var listen = false;
    var remote = false;
    var executor_id = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--strict-config")) continue;
        if (std.mem.eql(u8, arg, "--listen") or
            std.mem.eql(u8, arg, "--remote") or
            std.mem.eql(u8, arg, "--executor-id") or
            std.mem.eql(u8, arg, "--name"))
        {
            const option = arg;
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            if (std.mem.eql(u8, option, "--listen")) listen = true;
            if (std.mem.eql(u8, option, "--remote")) remote = true;
            if (std.mem.eql(u8, option, "--executor-id")) executor_id = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            listen = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            remote = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--executor-id=")) {
            executor_id = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--name=")) {
            continue;
        }
        return false;
    }
    if (listen and remote) return false;
    if (remote and !executor_id) return false;
    return false;
}

fn remoteControlTailHasHelp(args: []const []const u8) bool {
    var command_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "help")) {
            if (command_seen) return false;
            return index + 1 == args.len or
                (index + 2 == args.len and (remoteControlCommandNameIsValid(args[index + 1]) or std.mem.eql(u8, args[index + 1], "help")));
        }
        if (std.mem.eql(u8, arg, "--json")) continue;
        switch (scanConfigFeatureTailOption(args, &index, arg, true)) {
            .valid => continue,
            .invalid => return false,
            .not_handled => {},
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (!remoteControlCommandNameIsValid(arg) or command_seen) return false;
        command_seen = true;
    }
    return false;
}

fn remoteControlCommandNameIsValid(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "start") or std.mem.eql(u8, arg, "stop");
}

fn applyTailHasHelp(args: []const []const u8) bool {
    var task_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        switch (scanConfigFeatureTailOption(args, &index, arg, false)) {
            .valid => continue,
            .invalid => return false,
            .not_handled => {},
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (task_seen) return false;
        task_seen = true;
    }
    return false;
}

fn mcpServerTailHasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--strict-config")) continue;
        return false;
    }
    return false;
}

fn sessionCommandTailHasHelp(allocator: std.mem.Allocator, args: []const []const u8, allow_include_non_interactive: bool) !bool {
    var parsed = parseSessionCommandArgs(allocator, args, allow_include_non_interactive) catch return false;
    defer parsed.deinit(allocator);
    return parsed.help;
}

fn remoteForkTailHasHelp(allocator: std.mem.Allocator, args: []const []const u8) !bool {
    var parsed = parseRemoteForkCommandArgs(allocator, args) catch return false;
    defer parsed.deinit(allocator);
    return parsed.help;
}

fn debugHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (std.mem.eql(u8, args[0], "app-server")) return debugAppServerHelpPathIsValid(args[1..]);
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "help") or
        std.mem.eql(u8, args[0], "prompt-input") or
        std.mem.eql(u8, args[0], "models") or
        std.mem.eql(u8, args[0], "trace-reduce") or
        std.mem.eql(u8, args[0], "clear-memories");
}

fn debugAppServerHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "help") or
        std.mem.eql(u8, args[0], "send-message-v2");
}

fn debugTailHasHelp(args: []const []const u8) bool {
    if (debugNestedHelpTailIsValid(args)) return true;
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (std.mem.eql(u8, args[0], "app-server")) {
        return debugAppServerTailHasHelp(args[1..]);
    }
    if (std.mem.eql(u8, args[0], "prompt-input")) return debugPromptInputTailHasHelp(args[1..]);
    if (std.mem.eql(u8, args[0], "models")) return debugModelsTailHasHelp(args[1..]);
    if (std.mem.eql(u8, args[0], "trace-reduce")) return debugTraceReduceTailHasHelp(args[1..]);
    if (std.mem.eql(u8, args[0], "clear-memories")) return debugNoArgumentTailHasHelp(args[1..]);
    return false;
}

fn debugNestedHelpTailIsValid(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (!std.mem.eql(u8, args[0], "help")) return false;
    return debugHelpPathIsValid(args[1..]);
}

fn debugAppServerTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (std.mem.eql(u8, args[0], "help")) return debugAppServerHelpPathIsValid(args[1..]);
    if (std.mem.eql(u8, args[0], "send-message-v2")) {
        return args.len > 1 and isHelpFlag(args[1]);
    }
    return false;
}

fn debugPromptInputTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            var next = index + 1;
            var consumed = false;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
                consumed = true;
            }
            if (!consumed) return false;
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            var next = index + 1;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
            }
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
    }
    return false;
}

fn debugModelsTailHasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--bundled")) continue;
        return false;
    }
    return false;
}

fn debugTraceReduceTailHasHelp(args: []const []const u8) bool {
    var bundle_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) continue;
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (bundle_seen) return false;
        bundle_seen = true;
    }
    return false;
}

fn debugNoArgumentTailHasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        return false;
    }
    return false;
}

fn pluginHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (std.mem.eql(u8, args[0], "marketplace")) return pluginMarketplaceHelpPathIsValid(args[1..]);
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "help") or
        std.mem.eql(u8, args[0], "add") or
        std.mem.eql(u8, args[0], "list") or
        std.mem.eql(u8, args[0], "remove");
}

fn pluginMarketplaceHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "help") or
        std.mem.eql(u8, args[0], "add") or
        std.mem.eql(u8, args[0], "list") or
        std.mem.eql(u8, args[0], "upgrade") or
        std.mem.eql(u8, args[0], "remove");
}

fn cloudHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "exec") or
        std.mem.eql(u8, args[0], "status") or
        std.mem.eql(u8, args[0], "list") or
        std.mem.eql(u8, args[0], "apply") or
        std.mem.eql(u8, args[0], "diff");
}

fn pluginTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const subcommand = args[0];
    if (isHelpFlag(subcommand)) return true;
    if (std.mem.eql(u8, subcommand, "help")) return pluginHelpPathIsValid(args[1..]);
    if (std.mem.eql(u8, subcommand, "add") or std.mem.eql(u8, subcommand, "remove")) {
        return pluginSelectorTailHasHelp(args[1..]);
    }
    if (std.mem.eql(u8, subcommand, "list")) return pluginListTailHasHelp(args[1..]);
    if (std.mem.eql(u8, subcommand, "marketplace")) return pluginMarketplaceTailHasHelp(args[1..]);
    return false;
}

fn pluginSelectorTailHasHelp(args: []const []const u8) bool {
    var plugin_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--marketplace=") or
            (std.mem.startsWith(u8, arg, "-m") and arg.len > "-m".len))
        {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (plugin_seen) return false;
        plugin_seen = true;
    }
    return false;
}

fn pluginListTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--marketplace=") or
            (std.mem.startsWith(u8, arg, "-m") and arg.len > "-m".len))
        {
            continue;
        }
        return false;
    }
    return false;
}

fn pluginMarketplaceTailHasHelp(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const subcommand = args[0];
    if (isHelpFlag(subcommand)) return true;
    if (std.mem.eql(u8, subcommand, "help")) return pluginMarketplaceHelpPathIsValid(args[1..]);
    if (std.mem.eql(u8, subcommand, "add")) return pluginMarketplaceAddTailHasHelp(args[1..]);
    if (std.mem.eql(u8, subcommand, "list")) return pluginNoArgumentTailHasHelp(args[1..]);
    if (std.mem.eql(u8, subcommand, "upgrade")) return pluginSingleArgumentTailHasHelp(args[1..], true);
    if (std.mem.eql(u8, subcommand, "remove")) return pluginSingleArgumentTailHasHelp(args[1..], false);
    return false;
}

fn pluginMarketplaceAddTailHasHelp(args: []const []const u8) bool {
    var source_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--ref") or std.mem.eql(u8, arg, "--sparse")) {
            index += 1;
            if (index >= args.len) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ref=") or std.mem.startsWith(u8, arg, "--sparse=")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (source_seen) return false;
        source_seen = true;
    }
    return false;
}

fn pluginNoArgumentTailHasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        return false;
    }
    return false;
}

fn pluginSingleArgumentTailHasHelp(args: []const []const u8, allow_help_after_argument: bool) bool {
    var argument_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return !argument_seen or allow_help_after_argument;
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (argument_seen) return false;
        argument_seen = true;
    }
    return false;
}

fn loginTailHasHelp(args: []const []const u8) bool {
    var status = false;
    var login_mode_count: u8 = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "status")) {
            status = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-api-key") or
            std.mem.eql(u8, arg, "--with-access-token") or
            std.mem.eql(u8, arg, "--device-auth"))
        {
            login_mode_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental_issuer") or
            std.mem.eql(u8, arg, "--experimental_client-id"))
        {
            index += 1;
            if (index >= args.len) return false;
            continue;
        }
        return false;
    }
    if (login_mode_count > 1) return false;
    if (status and login_mode_count > 0) return false;
    return false;
}

fn sandboxTailHasHelp(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "help")) return sandboxHelpPathIsValid(args[index + 1 ..]);

        switch (scanConfigFeatureTailOption(args, &index, arg, true)) {
            .valid => continue,
            .invalid => return false,
            .not_handled => {},
        }
        if (std.mem.startsWith(u8, arg, "-")) return false;
        if (!sandbox_cmd.isKindName(arg)) return false;
        if (!sandboxKindTailHasHelp(args[index + 1 ..])) return false;
        return true;
    }
    return false;
}

fn sandboxHelpPathIsValid(args: []const []const u8) bool {
    if (args.len == 0) return true;
    if (args.len > 1) return false;
    return std.mem.eql(u8, args[0], "help") or sandbox_cmd.isKindName(args[0]);
}

fn sandboxKindTailHasHelp(args: []const []const u8) bool {
    var end_options = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and isHelpFlag(arg)) return true;

        if (!end_options) {
            switch (scanConfigFeatureTailOption(args, &index, arg, true)) {
                .valid => continue,
                .invalid => return false,
                .not_handled => {},
            }
        }
        if (!end_options and sandboxKindOptionConsumesSingleValue(arg)) {
            index += 1;
            if (index >= args.len) return false;
            if (isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (!end_options and (sandboxKindOptionHasInlineValue(arg) or sandboxKindOptionIsBoolean(arg))) {
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-")) return false;
        return false;
    }
    return false;
}

fn sandboxKindOptionConsumesSingleValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--permissions-profile") or
        std.mem.eql(u8, arg, "--allow-unix-socket") or
        std.mem.eql(u8, arg, "--cd") or
        std.mem.eql(u8, arg, "-C");
}

fn sandboxKindOptionHasInlineValue(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--permissions-profile=") or
        std.mem.startsWith(u8, arg, "--allow-unix-socket=") or
        std.mem.startsWith(u8, arg, "--cd=");
}

fn sandboxKindOptionIsBoolean(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--include-managed-config") or
        std.mem.eql(u8, arg, "--log-denials");
}

fn rootOptionConsumesSingleValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--profile") or
        std.mem.eql(u8, arg, "-p") or
        std.mem.eql(u8, arg, "--profile-v2") or
        std.mem.eql(u8, arg, "--cd") or
        std.mem.eql(u8, arg, "-C") or
        std.mem.eql(u8, arg, "--add-dir") or
        std.mem.eql(u8, arg, "--config") or
        std.mem.eql(u8, arg, "-c") or
        std.mem.eql(u8, arg, "--model") or
        std.mem.eql(u8, arg, "-m") or
        std.mem.eql(u8, arg, "--enable") or
        std.mem.eql(u8, arg, "--disable") or
        std.mem.eql(u8, arg, "--local-provider") or
        std.mem.eql(u8, arg, "--ask-for-approval") or
        std.mem.eql(u8, arg, "-a") or
        std.mem.eql(u8, arg, "--approval-policy") or
        std.mem.eql(u8, arg, "--sandbox") or
        std.mem.eql(u8, arg, "-s") or
        std.mem.eql(u8, arg, "--remote") or
        std.mem.eql(u8, arg, "--remote-auth-token-env") or
        std.mem.eql(u8, arg, "--remote-control-bind");
}

fn rootOptionHasInlineValue(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--profile=") or
        std.mem.startsWith(u8, arg, "--profile-v2=") or
        std.mem.startsWith(u8, arg, "--cd=") or
        std.mem.startsWith(u8, arg, "--add-dir=") or
        std.mem.startsWith(u8, arg, "--config=") or
        std.mem.startsWith(u8, arg, "--model=") or
        std.mem.startsWith(u8, arg, "--enable=") or
        std.mem.startsWith(u8, arg, "--disable=") or
        std.mem.startsWith(u8, arg, "--local-provider=") or
        std.mem.startsWith(u8, arg, "--ask-for-approval=") or
        std.mem.startsWith(u8, arg, "--approval-policy=") or
        std.mem.startsWith(u8, arg, "--sandbox=") or
        std.mem.startsWith(u8, arg, "--remote=") or
        std.mem.startsWith(u8, arg, "--remote-auth-token-env=") or
        std.mem.startsWith(u8, arg, "--remote-control-bind=");
}

fn rootOptionIsBoolean(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--oss") or
        std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or
        std.mem.eql(u8, arg, "--yolo") or
        std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust") or
        std.mem.eql(u8, arg, "--strict-config") or
        std.mem.eql(u8, arg, "--search") or
        std.mem.eql(u8, arg, "--remote-control") or
        std.mem.eql(u8, arg, "--no-alt-screen");
}

fn isKnownRootOptionBoundary(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--") or
        isHelpFlag(arg) or
        isVersionFlag(arg) or
        rootOptionConsumesSingleValue(arg) or
        rootOptionHasInlineValue(arg) or
        rootOptionIsBoolean(arg) or
        std.mem.eql(u8, arg, "--image") or
        std.mem.eql(u8, arg, "-i") or
        std.mem.startsWith(u8, arg, "--image=");
}

fn hasRootInteractiveOnlyFlags(overrides: CliOverrides) bool {
    return overrides.remote != null or
        overrides.remote_auth_token_env != null or
        overrides.local_remote_control or
        overrides.remote_control_bind != null;
}

fn isExecCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "exec") or std.mem.eql(u8, cmd, "e");
}

fn isApplyCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "apply") or std.mem.eql(u8, cmd, "a");
}

fn isCloudCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "cloud") or std.mem.eql(u8, cmd, "cloud-tasks");
}

fn isKnownRootCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "auth-status") or
        std.mem.eql(u8, cmd, "login") or
        std.mem.eql(u8, cmd, "logout") or
        std.mem.eql(u8, cmd, "doctor") or
        std.mem.eql(u8, cmd, "review") or
        std.mem.eql(u8, cmd, "sandbox") or
        std.mem.eql(u8, cmd, "features") or
        std.mem.eql(u8, cmd, "completion") or
        std.mem.eql(u8, cmd, "debug") or
        std.mem.eql(u8, cmd, "execpolicy") or
        isCloudCommand(cmd) or
        std.mem.eql(u8, cmd, "mcp") or
        std.mem.eql(u8, cmd, "app") or
        std.mem.eql(u8, cmd, "app-server") or
        std.mem.eql(u8, cmd, "exec-server") or
        std.mem.eql(u8, cmd, "remote-control") or
        std.mem.eql(u8, cmd, "plugin") or
        std.mem.eql(u8, cmd, "update") or
        std.mem.eql(u8, cmd, "responses-api-proxy") or
        std.mem.eql(u8, cmd, "stdio-to-uds") or
        std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "mcp-server") or
        std.mem.eql(u8, cmd, "remote-fork") or
        std.mem.eql(u8, cmd, "resume") or
        std.mem.eql(u8, cmd, "fork") or
        std.mem.eql(u8, cmd, "sessions") or
        std.mem.eql(u8, cmd, "mock-demo") or
        std.mem.eql(u8, cmd, "mock-apply-patch") or
        std.mem.eql(u8, cmd, "mock-policy-demo") or
        std.mem.eql(u8, cmd, "mock-sandbox-demo") or
        isExecCommand(cmd) or
        isApplyCommand(cmd);
}

fn rootCommandAppliesCwdBeforeDispatch(cmd: []const u8) bool {
    return isKnownRootCommand(cmd) and
        !isHelpFlag(cmd) and
        !isVersionFlag(cmd) and
        !isExecCommand(cmd) and
        !std.mem.eql(u8, cmd, "sandbox");
}

fn commandRejectsRootRemote(cmd: []const u8) bool {
    if (std.mem.eql(u8, cmd, "resume")) return false;
    if (std.mem.eql(u8, cmd, "fork")) return false;
    if (std.mem.eql(u8, cmd, "remote-fork")) return false;
    return isKnownRootCommand(cmd);
}

fn strictConfigUnsupportedSubcommandName(cmd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "auth-status") or
        std.mem.eql(u8, cmd, "doctor") or
        std.mem.eql(u8, cmd, "review") or
        std.mem.eql(u8, cmd, "app-server") or
        std.mem.eql(u8, cmd, "exec-server") or
        std.mem.eql(u8, cmd, "mcp-server") or
        std.mem.eql(u8, cmd, "resume") or
        std.mem.eql(u8, cmd, "fork") or
        std.mem.eql(u8, cmd, "remote-fork") or
        std.mem.eql(u8, cmd, "sessions") or
        isExecCommand(cmd))
    {
        return null;
    }
    if (std.mem.eql(u8, cmd, "sandbox")) return "sandbox";
    if (std.mem.eql(u8, cmd, "features")) return "features";
    if (std.mem.eql(u8, cmd, "completion")) return "completion";
    if (std.mem.eql(u8, cmd, "debug")) return "debug";
    if (std.mem.eql(u8, cmd, "execpolicy")) return "execpolicy";
    if (isCloudCommand(cmd)) return cmd;
    if (std.mem.eql(u8, cmd, "mcp")) return "mcp";
    if (std.mem.eql(u8, cmd, "app")) return "app";
    if (std.mem.eql(u8, cmd, "remote-control")) return "remote-control";
    if (std.mem.eql(u8, cmd, "plugin")) return "plugin";
    if (std.mem.eql(u8, cmd, "login")) return "login";
    if (std.mem.eql(u8, cmd, "logout")) return "logout";
    if (std.mem.eql(u8, cmd, "update")) return "update";
    if (std.mem.eql(u8, cmd, "responses-api-proxy")) return "responses-api-proxy";
    if (std.mem.eql(u8, cmd, "stdio-to-uds")) return "stdio-to-uds";
    if (std.mem.eql(u8, cmd, "help")) return "help";
    if (isApplyCommand(cmd)) return "apply";
    if (std.mem.startsWith(u8, cmd, "mock-")) return cmd;
    return null;
}

fn rejectStrictConfigForSubcommand(subcommand: []const u8) error{StrictConfigUnsupportedForSubcommand} {
    std.debug.print("`--strict-config` is not supported for `codex-zig {s}`\n", .{subcommand});
    return error.StrictConfigUnsupportedForSubcommand;
}

fn profileV2UnsupportedSubcommandName(cmd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "review") or
        std.mem.eql(u8, cmd, "resume") or
        std.mem.eql(u8, cmd, "fork") or
        std.mem.eql(u8, cmd, "remote-fork") or
        std.mem.eql(u8, cmd, "debug") or
        isExecCommand(cmd))
    {
        return null;
    }
    if (std.mem.eql(u8, cmd, "auth-status")) return "auth-status";
    if (std.mem.eql(u8, cmd, "doctor")) return "doctor";
    if (std.mem.eql(u8, cmd, "sandbox")) return "sandbox";
    if (std.mem.eql(u8, cmd, "features")) return "features";
    if (std.mem.eql(u8, cmd, "completion")) return "completion";
    if (std.mem.eql(u8, cmd, "execpolicy")) return "execpolicy";
    if (isCloudCommand(cmd)) return cmd;
    if (std.mem.eql(u8, cmd, "mcp")) return "mcp";
    if (std.mem.eql(u8, cmd, "app")) return "app";
    if (std.mem.eql(u8, cmd, "app-server")) return "app-server";
    if (std.mem.eql(u8, cmd, "exec-server")) return "exec-server";
    if (std.mem.eql(u8, cmd, "remote-control")) return "remote-control";
    if (std.mem.eql(u8, cmd, "plugin")) return "plugin";
    if (std.mem.eql(u8, cmd, "login")) return "login";
    if (std.mem.eql(u8, cmd, "logout")) return "logout";
    if (std.mem.eql(u8, cmd, "update")) return "update";
    if (std.mem.eql(u8, cmd, "responses-api-proxy")) return "responses-api-proxy";
    if (std.mem.eql(u8, cmd, "stdio-to-uds")) return "stdio-to-uds";
    if (std.mem.eql(u8, cmd, "mcp-server")) return "mcp-server";
    if (std.mem.eql(u8, cmd, "sessions")) return "sessions";
    if (isApplyCommand(cmd)) return "apply";
    if (std.mem.startsWith(u8, cmd, "mock-")) return cmd;
    return null;
}

fn rejectRemoteModeForSubcommand(
    remote: ?[]const u8,
    remote_auth_token_env: ?[]const u8,
    local_remote_control: bool,
    remote_control_bind: ?[]const u8,
    subcommand: []const u8,
) !void {
    if (remote) |value| {
        std.debug.print(
            "`--remote {s}` is only supported for interactive TUI commands, not `codex-zig {s}`\n",
            .{ value, subcommand },
        );
        return error.RemoteModeUnsupportedForSubcommand;
    }
    if (remote_auth_token_env != null) {
        std.debug.print(
            "`--remote-auth-token-env` is only supported for interactive TUI commands, not `codex-zig {s}`\n",
            .{subcommand},
        );
        return error.RemoteModeUnsupportedForSubcommand;
    }
    if (local_remote_control or remote_control_bind != null) {
        std.debug.print(
            "`--remote-control` is only supported for interactive TUI commands, not `codex-zig {s}`\n",
            .{subcommand},
        );
        return error.RemoteControlUnsupportedForSubcommand;
    }
}

fn runHelpCommand(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var targets = try collectRemainingArgs(allocator, args);
    defer targets.deinit(allocator);

    const target = if (targets.items.len > 0) targets.items[0] else {
        try printHelp();
        return;
    };
    if (isHelpFlag(target)) {
        failRootHelpSubcommand(target, .root);
        return error.HelpSubcommandInvalid;
    }
    if (isCloudCommand(target)) {
        try cloud_cmd.printHelpForArgs(targets.items[1..]);
        return;
    }
    if (std.mem.eql(u8, target, "sandbox")) {
        try sandbox_cmd.printHelpForArgs(targets.items[1..]);
        return;
    }
    if (std.mem.eql(u8, target, "help")) {
        if (targets.items.len > 1) {
            failRootHelpSubcommand(targets.items[1], .help_cmd);
            return error.HelpSubcommandInvalid;
        }
        printHelpCommandHelp();
        return;
    }
    if (isExecCommand(target)) {
        try exec.printHelpForArgs(targets.items[1..]);
        return;
    }
    if (std.mem.eql(u8, target, "debug")) {
        try debug_cmd.printHelpForArgs(targets.items[1..]);
        return;
    }
    if (std.mem.eql(u8, target, "mcp")) {
        try mcp_cmd.printHelpForArgs(targets.items[1..]);
        return;
    }
    if (std.mem.eql(u8, target, "plugin")) {
        try plugin_cmd.printHelpForArgs(targets.items[1..]);
        return;
    }

    try requireSingleHelpTarget(targets.items);
    if (isApplyCommand(target)) {
        apply_command.printHelp();
    } else if (std.mem.eql(u8, target, "review")) {
        review.printHelp();
    } else if (std.mem.eql(u8, target, "login")) {
        login.printLoginHelp();
    } else if (std.mem.eql(u8, target, "logout")) {
        printLogoutHelp();
    } else if (std.mem.eql(u8, target, "doctor")) {
        doctor_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "mcp-server")) {
        mcp_server_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "app-server")) {
        app_server_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "app")) {
        app_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "update")) {
        printUpdateHelp();
    } else if (std.mem.eql(u8, target, "responses-api-proxy")) {
        responses_api_proxy.printHelp();
    } else if (std.mem.eql(u8, target, "exec-server")) {
        exec_server_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "remote-control")) {
        remote_control_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "completion")) {
        completion_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "execpolicy")) {
        execpolicy_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "features")) {
        features_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "auth-status")) {
        printAuthStatusHelp();
    } else if (std.mem.eql(u8, target, "resume")) {
        printResumeHelp();
    } else if (std.mem.eql(u8, target, "fork")) {
        printForkHelp();
    } else if (std.mem.eql(u8, target, "remote-fork")) {
        printRemoteForkHelp();
    } else if (std.mem.eql(u8, target, "sessions")) {
        printSessionsHelp();
    } else {
        return error.UnknownHelpCommand;
    }
}

fn requireSingleHelpTarget(targets: []const []const u8) !void {
    if (targets.len != 1) return error.UnexpectedHelpArgument;
}

const RootHelpUsage = enum {
    root,
    help_cmd,
};

fn failRootHelpSubcommand(subcommand: []const u8, usage: RootHelpUsage) void {
    if (builtin.is_test) return;
    cli_utils.printUnrecognizedSubcommand(subcommand, switch (usage) {
        .root => "Usage: codex-zig [OPTIONS] [PROMPT]\n       codex-zig [OPTIONS] <COMMAND> [ARGS]",
        .help_cmd => "Usage: codex-zig help [COMMAND]...",
    }, usage == .root);
}

fn joinInitialPrompt(
    allocator: std.mem.Allocator,
    first: []const u8,
    args: *std.process.Args.Iterator,
) ![]const u8 {
    var rest = try collectRemainingArgs(allocator, args);
    defer rest.deinit(allocator);
    return joinInitialPromptParts(allocator, first, rest.items);
}

const RootPromptFlagAction = enum {
    help,
    version,
};

fn parseRootPromptTail(
    allocator: std.mem.Allocator,
    tail: []const []const u8,
    overrides: *CliOverrides,
    feature_overrides: *features_cmd.FeatureOverrides,
    additional_writable_roots: *std.ArrayList([]const u8),
    image_files: *std.ArrayList([]const u8),
    root_config_child_args: *std.ArrayList([]const u8),
    approval_policy_requested: *bool,
    dangerous_bypass_requested: *bool,
) !?RootPromptFlagAction {
    var conflicting_cli_options = false;
    const tail_has_help_or_version = promptFallbackTailHasHelpOrVersion(tail);
    var index: usize = 0;
    while (index < tail.len) : (index += 1) {
        const arg = tail[index];
        if (std.mem.eql(u8, arg, "--")) {
            if (index + 1 < tail.len) return rejectUnexpectedPromptArgument(tail[index + 1]);
            if (conflicting_cli_options) return error.ConflictingCliOptions;
            return null;
        }
        if (isHelpFlag(arg)) return .help;
        if (isVersionFlag(arg)) return .version;
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            overrides.profile = try nextRootPromptOptionValue(tail, &index, error.MissingProfileOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            overrides.profile = arg["--profile=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile-v2")) {
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingProfileOptionValue);
            try config.validateProfileV2Name(value);
            overrides.profile_v2 = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile-v2=")) {
            const value = arg["--profile-v2=".len..];
            try config.validateProfileV2Name(value);
            overrides.profile_v2 = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C")) {
            overrides.cwd = try nextRootPromptOptionValue(tail, &index, error.MissingCdOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cd=")) {
            overrides.cwd = arg["--cd=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--add-dir")) {
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingAddDirOptionValue);
            try additional_writable_roots.append(allocator, value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            try additional_writable_roots.append(allocator, arg["--add-dir=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            const raw = try nextRootPromptOptionValue(tail, &index, error.MissingConfigOptionValue);
            if (!tail_has_help_or_version) {
                try config.rememberStrictConfigUnknownOverride(allocator, &overrides.unknown_config_override, raw);
                try config.applyRawConfigOverride(&overrides.runtime, &overrides.profile, raw);
            }
            try root_config_child_args.append(allocator, arg);
            try root_config_child_args.append(allocator, raw);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            const raw = arg["--config=".len..];
            if (!tail_has_help_or_version) {
                try config.rememberStrictConfigUnknownOverride(allocator, &overrides.unknown_config_override, raw);
                try config.applyRawConfigOverride(&overrides.runtime, &overrides.profile, raw);
            }
            try root_config_child_args.append(allocator, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            overrides.runtime.model = try nextRootPromptOptionValue(tail, &index, error.MissingModelOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            overrides.runtime.model = arg["--model=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            input_images.appendVariadicFiles(allocator, image_files, tail, &index) catch |err| switch (err) {
                error.MissingImageValue => return error.MissingImageOptionValue,
                else => return err,
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendVariadicFilesAfterValue(allocator, image_files, tail, &index, arg["--image=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--enable")) {
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingFeatureName);
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, feature_overrides, value, true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingFeatureName);
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, feature_overrides, value, false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            if (!tail_has_help_or_version) try features_cmd.putRuntimeToggle(allocator, feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.eql(u8, arg, "--oss")) {
            overrides.oss = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--local-provider")) {
            overrides.oss_provider = try nextRootPromptOptionValue(tail, &index, error.MissingLocalProviderOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--local-provider=")) {
            overrides.oss_provider = arg["--local-provider=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--approval-policy")) {
            if (dangerous_bypass_requested.*) conflicting_cli_options = true;
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingApprovalOptionValue);
            approval_policy_requested.* = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (dangerous_bypass_requested.*) conflicting_cli_options = true;
            approval_policy_requested.* = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (dangerous_bypass_requested.*) conflicting_cli_options = true;
            approval_policy_requested.* = true;
            overrides.explicit_approval_policy = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            const value = try nextRootPromptOptionValue(tail, &index, error.MissingSandboxOptionValue);
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(value);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo")) {
            if (approval_policy_requested.*) conflicting_cli_options = true;
            dangerous_bypass_requested.* = true;
            overrides.runtime.approval_policy = .never;
            overrides.runtime.sandbox_mode = .danger_full_access;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust")) {
            overrides.runtime.bypass_hook_trust = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-config")) {
            overrides.strict_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--search")) {
            overrides.runtime.web_search_mode = .live;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            overrides.remote = try nextRootPromptOptionValue(tail, &index, error.MissingRemoteOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            overrides.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-auth-token-env")) {
            overrides.remote_auth_token_env = try nextRootPromptOptionValue(tail, &index, error.MissingRemoteAuthTokenEnvOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-auth-token-env=")) {
            overrides.remote_auth_token_env = arg["--remote-auth-token-env=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control")) {
            overrides.local_remote_control = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control-bind")) {
            overrides.remote_control_bind = try nextRootPromptOptionValue(tail, &index, error.MissingRemoteControlBindOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-control-bind=")) {
            overrides.remote_control_bind = arg["--remote-control-bind=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            overrides.no_alt_screen = true;
            continue;
        }
        return rejectUnexpectedPromptArgument(arg);
    }
    if (conflicting_cli_options) return error.ConflictingCliOptions;
    return null;
}

fn nextRootPromptOptionValue(tail: []const []const u8, index: *usize, missing_error: anyerror) ![]const u8 {
    index.* += 1;
    if (index.* >= tail.len) return missing_error;
    const value = tail[index.*];
    if (isRootPromptOptionValueBoundary(value)) {
        if (isKnownRootOptionBoundary(value)) return missing_error;
        return rejectUnexpectedPromptArgument(value);
    }
    return value;
}

fn isRootPromptOptionValueBoundary(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--")) return true;
    return std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-");
}

fn rejectUnexpectedPromptArgument(arg: []const u8) error{UnexpectedPromptArgument} {
    if (!builtin.is_test) {
        std.debug.print(
            \\error: unexpected argument '{s}' found
            \\
            \\Usage: codex-zig [OPTIONS] [PROMPT]
            \\       codex-zig [OPTIONS] <COMMAND> [ARGS]
            \\
            \\For more information, try '--help'.
            \\
        , .{arg});
    }
    return error.UnexpectedPromptArgument;
}

fn joinInitialPromptParts(
    allocator: std.mem.Allocator,
    first: []const u8,
    rest: []const []const u8,
) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, first);
    try parts.appendSlice(allocator, rest);
    return cli_utils.joinWithSpaces(allocator, parts.items);
}

fn runStdioToUdsCommand(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const socket_path = args.next() orelse {
        printStdioToUdsHelp();
        return error.MissingStdioToUdsSocketPath;
    };
    if (isHelpFlag(socket_path)) {
        printStdioToUdsHelp();
        return;
    }
    if (args.next() != null) return error.UnexpectedStdioToUdsArgument;
    try app_server_cmd.runStdioToUnixSocket(allocator, socket_path);
}

fn runUpdateCommand(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    if (args.next()) |value| {
        if (isHelpFlag(value)) {
            printUpdateHelp();
            return;
        }
        return error.UnexpectedUpdateArgument;
    }

    if (builtin.mode == .Debug) {
        return error.UpdateUnavailableDebugBuild;
    }
    const action = (try update_cmd.detectCurrentUpdateAction(allocator)) orelse return error.UpdateInstallMethodUnknown;
    try update_cmd.runAction(allocator, action);
}

fn printStdioToUdsHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig stdio-to-uds SOCKET_PATH
        \\
        \\Relays newline-delimited JSON-RPC between stdio and a Unix socket.
        \\
    , .{});
}

const SessionCommandArgs = struct {
    target: ?[]const u8 = null,
    initial_prompt: ?[]const u8 = null,
    last: bool = false,
    show_all: bool = false,
    include_non_interactive: bool = false,
    profile: ?[]const u8 = null,
    profile_v2: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    unknown_config_override: ?[]const u8 = null,
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: std.ArrayList([]const u8) = .empty,
    image_files: std.ArrayList([]const u8) = .empty,
    no_alt_screen: bool = false,
    remote: ?[]const u8 = null,
    remote_auth_token_env: ?[]const u8 = null,
    local_remote_control: bool = false,
    remote_control_bind: ?[]const u8 = null,
    strict_config: bool = false,
    help: bool = false,

    fn deinit(self: *SessionCommandArgs, allocator: std.mem.Allocator) void {
        if (self.unknown_config_override) |field| allocator.free(field);
        self.additional_writable_roots.deinit(allocator);
        for (self.image_files.items) |path| allocator.free(path);
        self.image_files.deinit(allocator);
    }
};

const SessionLaunchOptions = struct {
    image_files: []const []const u8,
    tui_options: tui.Options,
    owned_initial_prompt: ?[]const u8 = null,

    fn deinit(self: *SessionLaunchOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.image_files);
        allocator.free(self.tui_options.additional_writable_roots);
        if (self.owned_initial_prompt) |prompt| allocator.free(prompt);
    }
};

fn collectRemainingArgs(
    allocator: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) !std.ArrayList([]const u8) {
    var remaining = std.ArrayList([]const u8).empty;
    errdefer remaining.deinit(allocator);
    while (args.next()) |arg| {
        try remaining.append(allocator, arg);
    }
    return remaining;
}

fn prepareSessionLaunchOptions(
    allocator: std.mem.Allocator,
    overrides: CliOverrides,
    feature_overrides: features_cmd.FeatureOverrides,
    initial_image_files: []const []const u8,
    parsed: SessionCommandArgs,
) !SessionLaunchOptions {
    const effective_strict_config = overrides.strict_config or parsed.strict_config;
    if (effective_strict_config) {
        if (overrides.unknown_config_override) |field| return config.failStrictConfigUnknownCliOverride(field);
        if (parsed.unknown_config_override) |field| return config.failStrictConfigUnknownCliOverride(field);
    }

    if (parsed.cwd) |cwd| try workdir.change(cwd);

    const image_files = try cli_utils.mergeStringSlices(allocator, initial_image_files, parsed.image_files.items);
    errdefer allocator.free(image_files);

    const additional_writable_roots = try cli_utils.mergeStringSlices(
        allocator,
        overrides.additional_writable_roots,
        parsed.additional_writable_roots.items,
    );
    errdefer allocator.free(additional_writable_roots);

    const initial_prompt = try sessionLaunchInitialPrompt(allocator, parsed);
    errdefer if (initial_prompt.owned) |prompt| allocator.free(prompt);

    return .{
        .image_files = image_files,
        .owned_initial_prompt = initial_prompt.owned,
        .tui_options = .{
            .profile = parsed.profile orelse overrides.profile,
            .profile_v2 = parsed.profile_v2 orelse overrides.profile_v2,
            .runtime_overrides = config.mergeRuntimeOverrides(overrides.runtime, parsed.runtime_overrides),
            .oss = overrides.oss or parsed.oss,
            .oss_provider = parsed.oss_provider orelse overrides.oss_provider,
            .additional_writable_roots = additional_writable_roots,
            .initial_prompt = initial_prompt.value,
            .no_alt_screen = overrides.no_alt_screen or parsed.no_alt_screen,
            .remote = parsed.remote orelse overrides.remote,
            .remote_auth_token_env = parsed.remote_auth_token_env orelse overrides.remote_auth_token_env,
            .local_remote_control = overrides.local_remote_control or parsed.local_remote_control,
            .remote_control_bind = parsed.remote_control_bind orelse overrides.remote_control_bind,
            .feature_overrides = feature_overrides,
            .strict_config = effective_strict_config,
        },
    };
}

const SessionInitialPrompt = struct {
    value: ?[]const u8,
    owned: ?[]const u8 = null,
};

fn sessionLaunchInitialPrompt(allocator: std.mem.Allocator, parsed: SessionCommandArgs) !SessionInitialPrompt {
    if (!parsed.last or parsed.target == null) return .{ .value = parsed.initial_prompt };

    const target = parsed.target.?;
    const prompt = parsed.initial_prompt orelse return .{ .value = target };
    const parts = [_][]const u8{ target, prompt };
    const joined = try cli_utils.joinWithSpaces(allocator, parts[0..]);
    return .{ .value = joined, .owned = joined };
}

const SessionParseOptions = struct {
    allow_include_non_interactive: bool,
    help_positionals: u8 = 2,
};

fn parseSessionCommandArgs(allocator: std.mem.Allocator, args: []const []const u8, allow_include_non_interactive: bool) !SessionCommandArgs {
    return parseSessionCommandArgsWithOptions(allocator, args, .{ .allow_include_non_interactive = allow_include_non_interactive });
}

fn parseSessionCommandArgsWithOptions(allocator: std.mem.Allocator, args: []const []const u8, options: SessionParseOptions) !SessionCommandArgs {
    var parsed = SessionCommandArgs{};
    errdefer parsed.deinit(allocator);

    if (try sessionHelpPreflight(args, options)) {
        parsed.help = true;
        return parsed;
    }

    var approval_policy_requested = false;
    var dangerous_bypass_requested = false;
    var index: usize = 0;
    var end_options = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
            continue;
        }
        if (!end_options and isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--last")) {
            parsed.last = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--all")) {
            parsed.show_all = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--include-non-interactive")) {
            if (!options.allow_include_non_interactive) return error.UnknownSessionCommandOption;
            parsed.include_non_interactive = true;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p"))) {
            if (index + 1 >= args.len) return error.MissingProfileOptionValue;
            index += 1;
            parsed.profile = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--profile=")) {
            parsed.profile = arg["--profile=".len..];
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--profile-v2")) {
            if (index + 1 >= args.len) return error.MissingProfileOptionValue;
            index += 1;
            try config.validateProfileV2Name(args[index]);
            parsed.profile_v2 = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--profile-v2=")) {
            const value = arg["--profile-v2=".len..];
            try config.validateProfileV2Name(value);
            parsed.profile_v2 = value;
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c"))) {
            if (index + 1 >= args.len) return error.MissingConfigOptionValue;
            index += 1;
            try config.rememberStrictConfigUnknownOverride(allocator, &parsed.unknown_config_override, args[index]);
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--config=")) {
            const raw = arg["--config=".len..];
            try config.rememberStrictConfigUnknownOverride(allocator, &parsed.unknown_config_override, raw);
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, raw);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m"))) {
            if (index + 1 >= args.len) return error.MissingModelOptionValue;
            index += 1;
            parsed.runtime_overrides.model = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--model=")) {
            parsed.runtime_overrides.model = arg["--model=".len..];
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i"))) {
            input_images.appendVariadicFiles(allocator, &parsed.image_files, args, &index) catch |err| switch (err) {
                error.MissingImageValue => return error.MissingImageOptionValue,
                else => return err,
            };
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendVariadicFilesAfterValue(allocator, &parsed.image_files, args, &index, arg["--image=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C"))) {
            if (index + 1 >= args.len) return error.MissingCdOptionValue;
            index += 1;
            parsed.cwd = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--cd=")) {
            parsed.cwd = arg["--cd=".len..];
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--add-dir")) {
            if (index + 1 >= args.len) return error.MissingAddDirOptionValue;
            index += 1;
            try parsed.additional_writable_roots.append(allocator, args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--add-dir=")) {
            try parsed.additional_writable_roots.append(allocator, arg["--add-dir=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--oss")) {
            parsed.oss = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--local-provider")) {
            if (index + 1 >= args.len) return error.MissingLocalProviderOptionValue;
            index += 1;
            parsed.oss_provider = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--local-provider=")) {
            parsed.oss_provider = arg["--local-provider=".len..];
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a"))) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            if (index + 1 >= args.len) return error.MissingApprovalOptionValue;
            approval_policy_requested = true;
            index += 1;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--approval-policy")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            if (index + 1 >= args.len) return error.MissingApprovalOptionValue;
            approval_policy_requested = true;
            index += 1;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s"))) {
            if (index + 1 >= args.len) return error.MissingSandboxOptionValue;
            index += 1;
            parsed.runtime_overrides.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--sandbox=")) {
            parsed.runtime_overrides.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (!end_options and (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo"))) {
            if (approval_policy_requested) return error.ConflictingCliOptions;
            dangerous_bypass_requested = true;
            parsed.runtime_overrides.approval_policy = .never;
            parsed.runtime_overrides.sandbox_mode = .danger_full_access;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust")) {
            parsed.runtime_overrides.bypass_hook_trust = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--strict-config")) {
            parsed.strict_config = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--search")) {
            parsed.runtime_overrides.web_search_mode = .live;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--no-alt-screen")) {
            parsed.no_alt_screen = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--remote")) {
            if (index + 1 >= args.len) return error.MissingRemoteOptionValue;
            index += 1;
            parsed.remote = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--remote=")) {
            parsed.remote = arg["--remote=".len..];
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--remote-auth-token-env")) {
            if (index + 1 >= args.len) return error.MissingRemoteAuthTokenEnvOptionValue;
            index += 1;
            parsed.remote_auth_token_env = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--remote-auth-token-env=")) {
            parsed.remote_auth_token_env = arg["--remote-auth-token-env=".len..];
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--remote-control")) {
            parsed.local_remote_control = true;
            continue;
        }
        if (!end_options and std.mem.eql(u8, arg, "--remote-control-bind")) {
            if (index + 1 >= args.len) return error.MissingRemoteControlBindOptionValue;
            index += 1;
            parsed.remote_control_bind = args[index];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "--remote-control-bind=")) {
            parsed.remote_control_bind = arg["--remote-control-bind=".len..];
            continue;
        }
        if (!end_options and std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownSessionCommandOption;
        }
        if (parsed.target == null) {
            parsed.target = arg;
            continue;
        }
        if (parsed.initial_prompt == null) {
            parsed.initial_prompt = arg;
            continue;
        }
        return error.UnexpectedSessionCommandArgument;
    }
    return parsed;
}

fn sessionHelpPreflight(args: []const []const u8, options: SessionParseOptions) !bool {
    var positional_count: u8 = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
        if (std.mem.eql(u8, arg, "--last") or
            std.mem.eql(u8, arg, "--all") or
            std.mem.eql(u8, arg, "--oss") or
            std.mem.eql(u8, arg, "--search") or
            std.mem.eql(u8, arg, "--no-alt-screen") or
            std.mem.eql(u8, arg, "--remote-control") or
            std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or
            std.mem.eql(u8, arg, "--yolo") or
            std.mem.eql(u8, arg, "--dangerously-bypass-hook-trust") or
            std.mem.eql(u8, arg, "--strict-config"))
        {
            continue;
        }
        if (options.allow_include_non_interactive and std.mem.eql(u8, arg, "--include-non-interactive")) continue;
        if (std.mem.eql(u8, arg, "--profile-v2")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            try config.validateProfileV2Name(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile-v2=")) {
            try config.validateProfileV2Name(arg["--profile-v2=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--ask-for-approval") or
            std.mem.eql(u8, arg, "-a") or
            std.mem.eql(u8, arg, "--approval-policy"))
        {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            _ = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            _ = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--approval-policy=")) {
            _ = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            _ = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            _ = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile") or
            std.mem.eql(u8, arg, "-p") or
            std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--model") or
            std.mem.eql(u8, arg, "-m") or
            std.mem.eql(u8, arg, "--cd") or
            std.mem.eql(u8, arg, "-C") or
            std.mem.eql(u8, arg, "--add-dir") or
            std.mem.eql(u8, arg, "--local-provider") or
            std.mem.eql(u8, arg, "--remote") or
            std.mem.eql(u8, arg, "--remote-auth-token-env") or
            std.mem.eql(u8, arg, "--remote-control-bind"))
        {
            index += 1;
            if (index >= args.len or isRootPromptOptionValueBoundary(args[index])) return false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            var next = index + 1;
            var consumed = false;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
                consumed = true;
            }
            if (!consumed) return false;
            index = next - 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            var next = index + 1;
            while (next < args.len) : (next += 1) {
                if (isRootPromptOptionValueBoundary(args[next])) break;
            }
            index = next - 1;
            continue;
        }
        if (rootOptionHasInlineValue(arg)) continue;
        if (std.mem.startsWith(u8, arg, "-")) return false;
        positional_count += 1;
        if (positional_count > options.help_positionals) return false;
    }
    return false;
}

fn parseRemoteForkCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) !SessionCommandArgs {
    var parsed = try parseSessionCommandArgsWithOptions(allocator, args, .{
        .allow_include_non_interactive = false,
        .help_positionals = 1,
    });
    errdefer parsed.deinit(allocator);

    if (parsed.initial_prompt != null) return error.UnexpectedSessionCommandArgument;
    if (parsed.help) return parsed;
    if (parsed.last or parsed.show_all or parsed.include_non_interactive) {
        return error.UnknownRemoteForkOption;
    }
    if (parsed.target == null) {
        return error.MissingRemoteForkCode;
    }
    return parsed;
}

fn printHelp() !void {
    std.debug.print(
        \\Codex Zig
        \\
        \\Usage:
        \\  codex-zig              Start interactive TUI
        \\  codex-zig resume       Pick a saved Zig session to resume
        \\  codex-zig resume --last
        \\                          Resume the latest saved Zig session
        \\  codex-zig resume ID|PATH|last
        \\                          Start interactive TUI from a saved session
        \\  codex-zig fork         Pick a saved Zig session to fork
        \\  codex-zig fork --last
        \\                          Fork the latest saved Zig session
        \\  codex-zig fork ID|PATH|last
        \\                          Start interactive TUI from a forked session
        \\  codex-zig remote-fork CODE
        \\                          Import a remote fork claim and start a fork
        \\  codex-zig sessions [N] List saved Zig sessions
        \\  codex-zig exec PROMPT  Run one non-interactive turn
        \\  codex-zig e PROMPT     Alias for exec
        \\  codex-zig apply TASK_ID
        \\                          Apply the latest diff from a Codex agent task
        \\  codex-zig a TASK_ID    Alias for apply
        \\  codex-zig login        Sign in with ChatGPT browser auth
        \\  codex-zig login status Show login status
        \\  codex-zig logout       Remove local Codex auth
        \\  codex-zig review --uncommitted
        \\                          Run a non-interactive code review
        \\  codex-zig sandbox macos -- COMMAND
        \\                          Run a command under macOS Seatbelt
        \\  codex-zig features list
        \\                          List known feature flags
        \\  codex-zig completion [SHELL]
        \\                          Generate shell completion scripts
        \\  codex-zig debug prompt-input [PROMPT]
        \\                          Print model-visible input JSON
        \\  codex-zig execpolicy check --rules PATH COMMAND...
        \\                          Check execpolicy files against a command
        \\  codex-zig mcp list
        \\                          List configured MCP servers
        \\  codex-zig mcp-server
        \\                          Run Codex as a stdio MCP server
        \\  codex-zig app-server
        \\                          Run the app-server JSON-RPC stdio transport
        \\  codex-zig app [PATH]
        \\                          Open a workspace in Codex Desktop
        \\  codex-zig update       Update Codex to the latest version
        \\  codex-zig cloud [COMMAND]
        \\                          Browse Codex Cloud tasks
        \\  codex-zig exec-server --listen stdio
        \\                          Run the exec-server stdio JSON-RPC transport
        \\  codex-zig plugin <COMMAND>
        \\  codex-zig remote-control
        \\                          Headless app-server remote control
        \\  codex-zig auth-status  Check local Codex auth reuse
        \\  codex-zig doctor       Diagnose local installation and config
        \\  codex-zig help [COMMAND]
        \\                          Print general or command-specific help
        \\  codex-zig --profile NAME ...
        \\                          Select a config profile for the command
        \\  codex-zig --cd DIR ...
        \\                          Use DIR as the working root
        \\  codex-zig --add-dir DIR ...
        \\                          Allow workspace-write shell tools to write DIR
        \\  codex-zig --profile-v2 NAME ...
        \\                          Layer CODEX_HOME/NAME.config.toml over base config
        \\  codex-zig -c key=value ...
        \\                          Override a supported config value
        \\  codex-zig --strict-config ...
        \\                          Error on unknown config fields
        \\  codex-zig -m MODEL ...
        \\                          Override model for the command
        \\  codex-zig -i FILE ...
        \\                          Attach image file(s) to the first interactive prompt
        \\  codex-zig --enable FEATURE ...
        \\                          Enable a feature for this invocation
        \\  codex-zig --disable FEATURE ...
        \\                          Disable a feature for this invocation
        \\  codex-zig --oss --local-provider lmstudio ...
        \\                          Use a local OSS provider
        \\  codex-zig -a MODE ...
        \\                          Override approval policy
        \\  codex-zig -s MODE ...
        \\                          Override sandbox mode
        \\  codex-zig --yolo ...
        \\                          Danger: approval=never and sandbox=danger-full-access
        \\  codex-zig --dangerously-bypass-approvals-and-sandbox ...
        \\                          Alias for --yolo
        \\  codex-zig --dangerously-bypass-hook-trust ...
        \\                          Run enabled hooks without persisted hook trust
        \\  codex-zig --search ...
        \\                          Enable live web search for Responses turns
        \\  codex-zig --remote unix://PATH
        \\                          Connect interactive TUI to a Unix app-server
        \\  codex-zig --remote-auth-token-env ENV_VAR
        \\                          Read bearer token env var for remote app-server
        \\  codex-zig --remote-control
        \\                          Start local remote-control server mode
        \\  codex-zig --remote-control-bind ADDR
        \\                          Bind local remote-control server
        \\  codex-zig --no-alt-screen
        \\                          Disable alternate-screen TUI mode
        \\  codex-zig --version
        \\                          Print version and exit
        \\  codex-zig mock-demo    Run deterministic local tool demo
        \\  codex-zig mock-apply-patch
        \\                          Run deterministic apply_patch demo
        \\  codex-zig mock-policy-demo
        \\                          Run deterministic approval/sandbox demo
        \\  codex-zig mock-sandbox-demo
        \\                          Run deterministic macOS sandbox demo
        \\
        \\Environment:
        \\  CODEX_HOME             Override Codex home (default: ~/.codex)
        \\  CODEX_ACCESS_TOKEN     Use an access token without auth.json
        \\  CODEX_ZIG_MODEL        Override model
        \\  CODEX_ZIG_BASE_URL     Override API base URL
        \\  CODEX_ZIG_APPROVAL_POLICY
        \\                         Override approval policy
        \\  CODEX_ZIG_SANDBOX_MODE Override sandbox mode
        \\  CODEX_ZIG_WEB_SEARCH   Override web search mode: disabled, cached, live
        \\  CODEX_OSS_BASE_URL     Override local OSS Responses base URL
        \\  CODEX_OSS_PORT         Override local OSS provider port
        \\
    , .{});
}

fn printVersion() void {
    std.debug.print("codex-zig {s}\n", .{version});
}

fn printHelpCommandHelp() void {
    std.debug.print(
        \\Print this message or the help of the given subcommand(s)
        \\
        \\Usage: codex-zig help [COMMAND]...
        \\
        \\Arguments:
        \\  [COMMAND]...  Print help for the subcommand(s)
        \\
    , .{});
}

fn printAuthStatusHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig auth-status
        \\
        \\Shows the selected Codex home, profile, model, auth source, approval policy,
        \\sandbox mode, web search setting, and API base URL.
        \\
    , .{});
}

fn printLogoutHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig logout
        \\
        \\Removes the selected auth store entry.
        \\
    , .{});
}

fn printUpdateHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig update
        \\
        \\Updates Codex to the latest version when the current installation method is supported.
        \\
    , .{});
}

fn printResumeHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig resume
        \\  codex-zig resume [--all] [--include-non-interactive] [--remote ADDR]
        \\  codex-zig resume --last [--all] [--include-non-interactive] [--remote ADDR]
        \\  codex-zig resume ID|PATH|last [PROMPT]
        \\
        \\Without a target, opens a numbered picker for saved Zig sessions.
        \\--all, --include-non-interactive, and remote flags are accepted for Rust CLI compatibility.
        \\
    , .{});
}

fn printForkHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig fork
        \\  codex-zig fork [--all] [--remote ADDR]
        \\  codex-zig fork --last [--all] [--remote ADDR]
        \\  codex-zig fork ID|PATH|last [PROMPT]
        \\
        \\Without a target, opens a numbered picker for saved Zig sessions.
        \\--all and remote flags are accepted for Rust CLI compatibility.
        \\
    , .{});
}

fn printRemoteForkHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig remote-fork CODE
        \\  codex-zig remote-fork CODE [--remote ADDR]
        \\
        \\Imports a Rust-compatible remote fork claim bundle and starts a local forked session.
        \\For the current local demo, CODE must be an http:// claim URL.
        \\
    , .{});
}

fn printSessionsHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig sessions
        \\  codex-zig sessions N
        \\
        \\Lists saved Zig sessions, newest first. N limits the number shown.
        \\
    , .{});
}

fn runSessions(allocator: std.mem.Allocator, limit_arg: ?[]const u8, profile: ?[]const u8, strict_config: bool) !void {
    const limit = if (limit_arg) |value| try std.fmt.parseUnsigned(usize, value, 10) else 10;
    var cfg = try config.loadWithOptions(allocator, .{ .profile = profile, .strict_config = strict_config });
    defer cfg.deinit(allocator);

    try session_store.printSessionList(allocator, cfg.codex_home, limit);
}

fn runAuthStatus(allocator: std.mem.Allocator, overrides: CliOverrides) !void {
    var cfg = try config.loadWithOptions(allocator, .{
        .profile = overrides.profile,
        .strict_config = overrides.strict_config,
    });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, overrides.runtime);
    var credentials = try auth.loadForConfig(allocator, &cfg);
    defer credentials.deinit(allocator);

    std.debug.print("codex_home: {s}\n", .{cfg.codex_home});
    std.debug.print("active_profile: {s}\n", .{cfg.active_profile orelse "<none>"});
    std.debug.print("model: {s}\n", .{cfg.model});
    std.debug.print("auth: {s}\n", .{credentials.describe()});
    std.debug.print("approval_policy: {s}\n", .{cfg.approval_policy.label()});
    std.debug.print("sandbox_mode: {s}\n", .{cfg.sandbox_mode.label()});
    std.debug.print("web_search: {s}\n", .{config.webSearchLabel(cfg.web_search_mode)});
    std.debug.print("service_tier: {s}\n", .{cfg.service_tier orelse "<none>"});
    std.debug.print("api_base_url: {s}\n", .{switch (credentials.mode) {
        .chatgpt, .chatgpt_auth_tokens, .agent_identity => cfg.chatgpt_base_url,
        .api_key, .local_oss, .provider_no_auth => cfg.openai_base_url,
    }});
    if (credentials.account_id) |account_id| {
        std.debug.print("chatgpt_account_id: {s}\n", .{account_id});
    }
}

fn runMockDemo(allocator: std.mem.Allocator) !void {
    const call = api.FunctionCall{
        .call_id = "call_mock_shell",
        .name = "shell_command",
        .arguments = "{\"command\":\"printf zig-port-ok > codex_zig_mock_demo.txt\"}",
    };
    const result = try tools.runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);

    std.debug.print("tool: {s}\n", .{result.summary});
    std.debug.print("output: {s}\n", .{result.output});

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "codex_zig_mock_demo.txt", allocator, .limited(1024));
    defer allocator.free(content);
    if (!std.mem.eql(u8, content, "zig-port-ok")) {
        return error.MockDemoFileMismatch;
    }
}

fn runMockApplyPatch(allocator: std.mem.Allocator) !void {
    const demo_file = "codex_zig_apply_patch_demo.txt";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), demo_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const call = api.FunctionCall{
        .call_id = "call_mock_apply_patch",
        .name = "apply_patch",
        .arguments =
        \\{"patch":"*** Begin Patch\n*** Add File: codex_zig_apply_patch_demo.txt\n+zig-apply-patch-ok\n*** End Patch"}
        ,
    };
    const result = try tools.runFunctionCall(allocator, call, .{ .auto_approve = true });
    defer result.deinit(allocator);

    std.debug.print("tool: {s}\n", .{result.summary});
    std.debug.print("output: {s}\n", .{result.output});

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), demo_file, allocator, .limited(1024));
    defer allocator.free(content);
    if (!std.mem.eql(u8, content, "zig-apply-patch-ok\n")) {
        return error.MockApplyPatchFileMismatch;
    }
}

fn runMockPolicyDemo(allocator: std.mem.Allocator) !void {
    const blocked_file = "codex_zig_policy_blocked.txt";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), blocked_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const read_call = api.FunctionCall{
        .call_id = "call_mock_read_policy",
        .name = "shell_command",
        .arguments = "{\"command\":\"pwd\"}",
    };
    const read_result = try tools.runFunctionCall(allocator, read_call, .{
        .approval_policy = .untrusted,
        .sandbox_mode = .read_only,
        .prompt_for_approval = false,
    });
    defer read_result.deinit(allocator);
    if (!std.mem.startsWith(u8, read_result.summary, "exit ")) return error.MockPolicyReadMismatch;

    const write_call = api.FunctionCall{
        .call_id = "call_mock_write_policy",
        .name = "apply_patch",
        .arguments =
        \\{"patch":"*** Begin Patch\n*** Add File: codex_zig_policy_blocked.txt\n+should-not-write\n*** End Patch"}
        ,
    };
    const write_result = try tools.runFunctionCall(allocator, write_call, .{
        .approval_policy = .on_failure,
        .sandbox_mode = .read_only,
        .auto_approve = true,
    });
    defer write_result.deinit(allocator);
    if (!std.mem.eql(u8, write_result.summary, "blocked by sandbox")) return error.MockPolicyWriteMismatch;
    if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), blocked_file, allocator, .limited(1024))) |bytes| {
        defer allocator.free(bytes);
        return error.MockPolicyBlockedFileCreated;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    std.debug.print("read: {s}\n", .{read_result.summary});
    std.debug.print("write: {s}\n", .{write_result.summary});
    std.debug.print("policy: ok\n", .{});
}

fn runMockSandboxDemo(allocator: std.mem.Allocator, additional_writable_roots: []const []const u8) !void {
    const allowed_file = "codex_zig_sandbox_allowed.txt";
    const blocked_file = "/tmp/codex_zig_sandbox_blocked.txt";
    const extra_file = if (additional_writable_roots.len > 0)
        try std.fs.path.join(allocator, &.{ additional_writable_roots[0], "codex_zig_sandbox_extra.txt" })
    else
        null;
    defer if (extra_file) |path| allocator.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, allowed_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(io, blocked_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (extra_file) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    const call = api.FunctionCall{
        .call_id = "call_mock_sandbox",
        .name = "shell_command",
        .arguments = if (extra_file) |path|
            try std.fmt.allocPrint(
                allocator,
                "{{\"command\":\"printf workspace-ok > codex_zig_sandbox_allowed.txt; printf extra > {s}; printf outside > /tmp/codex_zig_sandbox_blocked.txt\"}}",
                .{path},
            )
        else
            "{\"command\":\"printf workspace-ok > codex_zig_sandbox_allowed.txt; printf outside > /tmp/codex_zig_sandbox_blocked.txt\"}",
    };
    defer if (extra_file != null) allocator.free(call.arguments);
    const result = try tools.runFunctionCall(allocator, call, .{
        .approval_policy = .never,
        .sandbox_mode = .workspace_write,
        .additional_writable_roots = additional_writable_roots,
        .auto_approve = true,
    });
    defer result.deinit(allocator);

    if (std.mem.eql(u8, result.summary, "exit 0")) return error.MockSandboxOutsideWriteAllowed;

    const allowed = try std.Io.Dir.cwd().readFileAlloc(io, allowed_file, allocator, .limited(1024));
    defer allocator.free(allowed);
    if (!std.mem.eql(u8, allowed, "workspace-ok")) return error.MockSandboxAllowedWriteMismatch;

    if (extra_file) |path| {
        const extra = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
        defer allocator.free(extra);
        if (!std.mem.eql(u8, extra, "extra")) return error.MockSandboxExtraWriteMismatch;
    }

    if (std.Io.Dir.cwd().readFileAlloc(io, blocked_file, allocator, .limited(1024))) |blocked| {
        defer allocator.free(blocked);
        return error.MockSandboxBlockedFileCreated;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.debug.print("sandbox: {s}\n", .{result.summary});
    std.debug.print("workspace-write: ok\n", .{});
    if (extra_file != null) std.debug.print("add-dir: ok\n", .{});
    std.debug.print("outside-write: blocked\n", .{});
}

test {
    _ = api;
    _ = auth;
    _ = cli_utils;
    _ = completion_cmd;
    _ = config;
    _ = debug_cmd;
    _ = env;
    _ = exec;
    _ = git_diff;
    _ = login;
    _ = remote_fork;
    _ = review;
    _ = sandbox;
    _ = session;
    _ = session_store;
    _ = tools;
    _ = tui;
    _ = workdir;
}

test "join initial prompt consumes remaining args" {
    const allocator = std.testing.allocator;
    const parts = [_][]const u8{ "hello", "from", "prompt" };

    const prompt = try cli_utils.joinWithSpaces(allocator, parts[0..]);
    defer allocator.free(prompt);

    try std.testing.expectEqualStrings("hello from prompt", prompt);
}

test "exec command alias matches exec" {
    try std.testing.expect(isExecCommand("exec"));
    try std.testing.expect(isExecCommand("e"));
    try std.testing.expect(!isExecCommand("review"));
}

test "session command flags parse resume compatibility options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--all", "--include-non-interactive", "--last", "--profile-v2", "team", "--strict-config" };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.show_all);
    try std.testing.expect(parsed.include_non_interactive);
    try std.testing.expect(parsed.last);
    try std.testing.expectEqualStrings("team", parsed.profile_v2.?);
    try std.testing.expect(parsed.strict_config);
    try std.testing.expect(parsed.target == null);
}

test "session command flags reject path-like profile v2 names" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--profile-v2", "../team" };
    try std.testing.expectError(error.InvalidProfileV2Name, parseSessionCommandArgs(allocator, argv[0..], true));
}

test "session command help preflight validates typed option values" {
    const allocator = std.testing.allocator;

    const invalid_profile = [_][]const u8{ "--profile-v2", "../team", "--help" };
    try std.testing.expectError(error.InvalidProfileV2Name, parseSessionCommandArgs(allocator, invalid_profile[0..], true));

    const invalid_approval = [_][]const u8{ "--ask-for-approval", "bogus", "--help" };
    try std.testing.expectError(error.InvalidApprovalPolicy, parseSessionCommandArgs(allocator, invalid_approval[0..], true));

    const invalid_sandbox = [_][]const u8{ "--sandbox=bogus", "--help" };
    try std.testing.expectError(error.InvalidSandboxMode, parseSessionCommandArgs(allocator, invalid_sandbox[0..], true));

    const semantic_config = [_][]const u8{ "--strict-config", "-c", "foo.bar=1", "--help" };
    var parsed = try parseSessionCommandArgs(allocator, semantic_config[0..], true);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.help);
}

test "session command flags parse remote compatibility options" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "--remote",
        "ws://127.0.0.1:4500",
        "--remote-auth-token-env=CODEX_REMOTE_AUTH_TOKEN",
        "--last",
    };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.last);
    try std.testing.expectEqualStrings("ws://127.0.0.1:4500", parsed.remote.?);
    try std.testing.expectEqualStrings("CODEX_REMOTE_AUTH_TOKEN", parsed.remote_auth_token_env.?);
}

test "session command flags merge interactive overrides" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "sid",
        "--oss",
        "--local-provider=ollama",
        "--search",
        "--sandbox",
        "workspace-write",
        "--ask-for-approval",
        "on-request",
        "-m",
        "gpt-5.1-test",
        "-p",
        "work",
        "-C",
        "/tmp/workspace",
        "--add-dir",
        "/tmp/extra",
        "-i",
        "/tmp/a.png",
        "/tmp/b.png",
        "-c",
        "review_model=gpt-session-review",
        "--dangerously-bypass-hook-trust",
        "--no-alt-screen",
    };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("sid", parsed.target.?);
    try std.testing.expect(parsed.oss);
    try std.testing.expectEqualStrings("ollama", parsed.oss_provider.?);
    try std.testing.expectEqual(config.WebSearchMode.live, parsed.runtime_overrides.web_search_mode.?);
    try std.testing.expectEqual(config.SandboxMode.workspace_write, parsed.runtime_overrides.sandbox_mode.?);
    try std.testing.expectEqual(config.ApprovalPolicy.on_request, parsed.runtime_overrides.approval_policy.?);
    try std.testing.expectEqual(true, parsed.runtime_overrides.bypass_hook_trust.?);
    try std.testing.expectEqualStrings("gpt-5.1-test", parsed.runtime_overrides.model.?);
    try std.testing.expectEqualStrings("gpt-session-review", parsed.runtime_overrides.review_model.?);
    try std.testing.expectEqualStrings("work", parsed.profile.?);
    try std.testing.expectEqualStrings("/tmp/workspace", parsed.cwd.?);
    try std.testing.expectEqualStrings("/tmp/extra", parsed.additional_writable_roots.items[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.image_files.items.len);
    try std.testing.expectEqualStrings("/tmp/a.png", parsed.image_files.items[0]);
    try std.testing.expectEqualStrings("/tmp/b.png", parsed.image_files.items[1]);
    try std.testing.expect(parsed.no_alt_screen);
}

test "session command flags remember first unknown config override" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "-c",
        "features.nope=true",
        "--config=mcp_servers.local.command=echo",
        "-c",
        "foo=bar",
    };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("features.nope", parsed.unknown_config_override.?);
    try std.testing.expect(parsed.target == null);
}

test "session command variadic images stop at separator before target" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--image", "/tmp/a.png", "/tmp/b.png", "--", "last" };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("last", parsed.target.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.image_files.items.len);
    try std.testing.expectEqualStrings("/tmp/a.png", parsed.image_files.items[0]);
    try std.testing.expectEqualStrings("/tmp/b.png", parsed.image_files.items[1]);
}

test "session command flags parse target and prompt and reject extra target" {
    const allocator = std.testing.allocator;
    const target_argv = [_][]const u8{"session-id"};
    var target = try parseSessionCommandArgs(allocator, target_argv[0..], false);
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("session-id", target.target.?);

    const prompt_argv = [_][]const u8{ "session-id", "follow-up prompt" };
    var prompt = try parseSessionCommandArgs(allocator, prompt_argv[0..], false);
    defer prompt.deinit(allocator);
    try std.testing.expectEqualStrings("session-id", prompt.target.?);
    try std.testing.expectEqualStrings("follow-up prompt", prompt.initial_prompt.?);

    const extra_argv = [_][]const u8{ "one", "two", "three" };
    try std.testing.expectError(error.UnexpectedSessionCommandArgument, parseSessionCommandArgs(allocator, extra_argv[0..], true));
}

test "session launch initial prompt carries last positionals" {
    const allocator = std.testing.allocator;

    const normal = try sessionLaunchInitialPrompt(allocator, .{
        .target = "session-id",
        .initial_prompt = "follow-up prompt",
    });
    defer if (normal.owned) |prompt| allocator.free(prompt);
    try std.testing.expectEqualStrings("follow-up prompt", normal.value.?);

    const last_target = try sessionLaunchInitialPrompt(allocator, .{
        .last = true,
        .target = "session-id",
    });
    defer if (last_target.owned) |prompt| allocator.free(prompt);
    try std.testing.expectEqualStrings("session-id", last_target.value.?);

    const last_prompt = try sessionLaunchInitialPrompt(allocator, .{
        .last = true,
        .target = "session-id",
        .initial_prompt = "follow-up prompt",
    });
    defer if (last_prompt.owned) |prompt| allocator.free(prompt);
    try std.testing.expectEqualStrings("session-id follow-up prompt", last_prompt.value.?);
}

test "fork session command rejects include non interactive" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--include-non-interactive"};
    try std.testing.expectError(error.UnknownSessionCommandOption, parseSessionCommandArgs(allocator, argv[0..], false));
}

test "remote fork command parses code and interactive overrides" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "--oss",
        "--no-alt-screen",
        "--remote=ws://127.0.0.1:4500",
        "http://127.0.0.1:1234/claim",
    };
    var parsed = try parseRemoteForkCommandArgs(allocator, argv[0..]);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.oss);
    try std.testing.expect(parsed.no_alt_screen);
    try std.testing.expectEqualStrings("ws://127.0.0.1:4500", parsed.remote.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/claim", parsed.target.?);
}

test "remote fork command requires a code and rejects session picker flags" {
    const allocator = std.testing.allocator;
    const no_code = [_][]const u8{"--oss"};
    try std.testing.expectError(error.MissingRemoteForkCode, parseRemoteForkCommandArgs(allocator, no_code[0..]));

    const all = [_][]const u8{ "--all", "http://127.0.0.1:1234/claim" };
    try std.testing.expectError(error.UnknownRemoteForkOption, parseRemoteForkCommandArgs(allocator, all[0..]));

    const prompt = [_][]const u8{ "http://127.0.0.1:1234/claim", "prompt" };
    try std.testing.expectError(error.UnexpectedSessionCommandArgument, parseRemoteForkCommandArgs(allocator, prompt[0..]));
}

test "root remote is only accepted for interactive commands" {
    try std.testing.expect(commandRejectsRootRemote("exec"));
    try std.testing.expect(commandRejectsRootRemote("app-server"));
    try std.testing.expect(commandRejectsRootRemote("app"));
    try std.testing.expect(commandRejectsRootRemote("exec-server"));
    try std.testing.expect(commandRejectsRootRemote("plugin"));
    try std.testing.expect(commandRejectsRootRemote("remote-control"));
    try std.testing.expect(commandRejectsRootRemote("cloud"));
    try std.testing.expect(commandRejectsRootRemote("cloud-tasks"));
    try std.testing.expect(commandRejectsRootRemote("doctor"));
    try std.testing.expect(commandRejectsRootRemote("sandbox"));
    try std.testing.expect(commandRejectsRootRemote("update"));
    try std.testing.expect(commandRejectsRootRemote("responses-api-proxy"));
    try std.testing.expect(!commandRejectsRootRemote("resume"));
    try std.testing.expect(!commandRejectsRootRemote("fork"));
    try std.testing.expect(!commandRejectsRootRemote("remote-fork"));
    try std.testing.expect(!commandRejectsRootRemote("write this prompt"));
}

test "root cwd is deferred for prompt fallback commands" {
    try std.testing.expect(rootCommandAppliesCwdBeforeDispatch("doctor"));
    try std.testing.expect(rootCommandAppliesCwdBeforeDispatch("resume"));
    try std.testing.expect(!rootCommandAppliesCwdBeforeDispatch("exec"));
    try std.testing.expect(!rootCommandAppliesCwdBeforeDispatch("sandbox"));
    try std.testing.expect(!rootCommandAppliesCwdBeforeDispatch("--help"));
    try std.testing.expect(!rootCommandAppliesCwdBeforeDispatch("marketplace"));
    try std.testing.expect(!rootCommandAppliesCwdBeforeDispatch("prompt-token"));
}

test "root semantic checks defer to help and version tails" {
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "sandbox", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "sandbox", "help", "macos" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "sandbox", "help", "help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "--enable", "definitely-not-a-feature", "macos", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "--config", "bogus", "macos", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--config", "bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "doctor", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "doctor", "--strict-config", "-c", "foo.bar=1", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "doctor", "--json", "--help", "--summary" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "doctor", "--config", "bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "doctor", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "doctor", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "review", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "review", "--strict-config", "-c", "foo.bar=1", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "review", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--base", "main", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--config", "bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--base=", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--uncommitted", "--base", "main", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "review", "--title", "summary", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "review", "--base", "bad\nref", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--version" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--image", "/tmp/a.png", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--color", "never", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--config", "approval_policy=bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "echo", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "resume", "--last", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "help", "review" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "status", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "status", "--help", "--no-browser" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "--with-api-key", "--device-auth", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "resume", "--last", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "resume", "--include-non-interactive", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "resume", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "fork", "--last", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "remote-fork", "--last", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec-server", "--strict-config", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec-server", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec-server", "--remote", "ws://127.0.0.1:2", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "plugin", "add", "--marketplace", "debug", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "plugin", "help", "marketplace", "add" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "help", "add" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "remove", "server", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "logout", "server", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "features", "list", "--enable", "apps", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "features", "list", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "features", "enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "debug", "prompt-input", "--image", "/tmp/a.png", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "debug", "app-server", "help", "send-message-v2" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "debug", "trace-reduce", "--output", "out.json", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "--session-source", "vscode", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "app-server", "--ws-auth", "capability-token", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "app-server", "--ws-max-clock-skew-seconds", "30", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "app-server", "proxy", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "app-server", "--strict-config", "proxy", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "proxy", "--sock", "/tmp/app.sock", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "app-server", "daemon", "bootstrap", "--remote-control", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "app-server", "--strict-config", "daemon", "bootstrap", "--remote-control", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "daemon", "bootstrap", "--remote-control", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "responses-api-proxy", "--port", "0", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "remote-control", "--enable", "definitely-not-a-feature", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "remote-control", "--config", "bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "cloud", "exec", "--env", "env-id", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "update", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "logout", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "completion", "zsh", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "apply", "--help", "--bad" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "apply", "--config", "bogus", "--help" }));
    try std.testing.expect(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--image", "/tmp/a.png", "prompt-token", "--help" }));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--model", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "debug", "trace-reduce", "--output", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "debug", "clear-memories", "--bundled", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "--session-source", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "generate-ts", "--out", "src", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "app-server", "daemon", "--remote-control", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "doctor", "--config", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "doctor", "unexpected", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sessions", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sessions", "--json", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sessions", "10", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "--bad", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "review", "--base", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "review", "one", "two", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "resume", "--sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "fork", "--profile-v2", "../bad", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "remote-fork", "--approval-policy", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--base", "main", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--color", "red", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "--yolo", "--approval-policy", "never", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "help", "--base" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "resume", "--base", "main", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "echo", "resume", "--last", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "debug", "--base", "main", "help", "models" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "sandbox", "help", "bogus" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "-C", "does-not-exist", "sandbox", "help", "macos", "extra" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "echo", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "echo", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--sandbox", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "sandbox", "macos", "--add-dir", "/tmp", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "exec", "review", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "cloud", "exec", "--version" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "cloud", "exec", "--color", "red", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "cloud", "exec", "--env", "env-id", "--attempts", "5", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "plugin", "add", "sample", "extra", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--strict-config", "-c", "foo.bar=1", "plugin", "add", "--marketplace", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "add", "server", "echo", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "remove", "server", "extra", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "mcp", "logout", "server", "extra", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "app-server", "--ws-auth", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "app-server", "--ws-max-clock-skew-seconds", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "responses-api-proxy", "--port", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "unexpected", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "--experimental_port", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "--remote", "ws://127.0.0.1:1", "login", "--experimental_port", "bogus", "--help" })));
    try std.testing.expect(!(try rootArgsTailHasHelpOrVersion(std.testing.allocator, &.{ "prompt-token", "--", "--help" })));
}

test "root strict config is rejected for unsupported subcommands" {
    try std.testing.expect(strictConfigUnsupportedSubcommandName("exec") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("e") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("review") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("doctor") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("app-server") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("exec-server") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("mcp-server") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("resume") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("fork") == null);
    try std.testing.expect(strictConfigUnsupportedSubcommandName("write this prompt") == null);
    try std.testing.expectEqualStrings("features", strictConfigUnsupportedSubcommandName("features").?);
    try std.testing.expectEqualStrings("cloud", strictConfigUnsupportedSubcommandName("cloud").?);
    try std.testing.expectEqualStrings("apply", strictConfigUnsupportedSubcommandName("apply").?);
}

test "root profile-v2 is restricted to runtime subcommands" {
    try std.testing.expect(profileV2UnsupportedSubcommandName("exec") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("e") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("review") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("resume") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("fork") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("debug") == null);
    try std.testing.expect(profileV2UnsupportedSubcommandName("write this prompt") == null);
    try std.testing.expectEqualStrings("doctor", profileV2UnsupportedSubcommandName("doctor").?);
    try std.testing.expectEqualStrings("sandbox", profileV2UnsupportedSubcommandName("sandbox").?);
    try std.testing.expectEqualStrings("apply", profileV2UnsupportedSubcommandName("apply").?);
}

test "root prompt fallback honors trailing global flags" {
    const allocator = std.testing.allocator;
    var overrides = CliOverrides{};
    defer overrides.deinit(allocator);
    var feature_overrides = features_cmd.FeatureOverrides{};
    defer feature_overrides.deinit(allocator);
    var additional_writable_roots = std.ArrayList([]const u8).empty;
    defer additional_writable_roots.deinit(allocator);
    var image_files = std.ArrayList([]const u8).empty;
    defer {
        for (image_files.items) |path| allocator.free(path);
        image_files.deinit(allocator);
    }
    var root_config_child_args = std.ArrayList([]const u8).empty;
    defer root_config_child_args.deinit(allocator);
    var approval_policy_requested = false;
    var dangerous_bypass_requested = false;

    try std.testing.expectEqual(
        RootPromptFlagAction.version,
        (try parseRootPromptTail(
            allocator,
            &.{ "--model", "gpt-test", "--version", "--help" },
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    try std.testing.expectEqualStrings("gpt-test", overrides.runtime.model.?);

    try std.testing.expectEqual(
        RootPromptFlagAction.help,
        (try parseRootPromptTail(
            allocator,
            &.{"-h"},
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    try std.testing.expect((try parseRootPromptTail(
        allocator,
        &.{ "--search", "--add-dir", "/tmp/extra", "-i", "/tmp/image-a.png", "/tmp/image-b.png" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    )) == null);
    try std.testing.expectEqual(config.WebSearchMode.live, overrides.runtime.web_search_mode.?);
    try std.testing.expectEqualStrings("/tmp/extra", additional_writable_roots.items[0]);
    try std.testing.expectEqualStrings("/tmp/image-a.png", image_files.items[0]);
    try std.testing.expectEqualStrings("/tmp/image-b.png", image_files.items[1]);

    try std.testing.expectError(error.UnexpectedPromptArgument, parseRootPromptTail(
        allocator,
        &.{ "add", "owner/repo", "--help" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.UnexpectedPromptArgument, parseRootPromptTail(
        allocator,
        &.{"-x"},
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.UnexpectedPromptArgument, parseRootPromptTail(
        allocator,
        &.{ "--", "--version" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.MissingCdOptionValue, parseRootPromptTail(
        allocator,
        &.{ "--cd", "--help" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.MissingModelOptionValue, parseRootPromptTail(
        allocator,
        &.{ "--model", "--version" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.MissingRemoteOptionValue, parseRootPromptTail(
        allocator,
        &.{ "--remote", "--no-alt-screen" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    try std.testing.expectError(error.UnexpectedPromptArgument, parseRootPromptTail(
        allocator,
        &.{ "--cd", "--bad" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
    approval_policy_requested = false;
    dangerous_bypass_requested = false;
    try std.testing.expectEqual(
        RootPromptFlagAction.help,
        (try parseRootPromptTail(
            allocator,
            &.{ "--yolo", "-a", "never", "--help" },
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    try std.testing.expectEqual(
        RootPromptFlagAction.help,
        (try parseRootPromptTail(
            allocator,
            &.{ "--config", "approval_policy=bogus", "--help" },
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    try std.testing.expectEqual(
        RootPromptFlagAction.help,
        (try parseRootPromptTail(
            allocator,
            &.{ "--enable", "definitely-not-a-feature", "--help" },
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    try std.testing.expectEqual(
        RootPromptFlagAction.version,
        (try parseRootPromptTail(
            allocator,
            &.{ "--enable", "definitely-not-a-feature", "--version" },
            &overrides,
            &feature_overrides,
            &additional_writable_roots,
            &image_files,
            &root_config_child_args,
            &approval_policy_requested,
            &dangerous_bypass_requested,
        )).?,
    );
    approval_policy_requested = false;
    dangerous_bypass_requested = false;
    try std.testing.expectError(error.ConflictingCliOptions, parseRootPromptTail(
        allocator,
        &.{ "--yolo", "-a", "never" },
        &overrides,
        &feature_overrides,
        &additional_writable_roots,
        &image_files,
        &root_config_child_args,
        &approval_policy_requested,
        &dangerous_bypass_requested,
    ));
}

test "session runtime override merge preserves model controls" {
    const merged = config.mergeRuntimeOverrides(.{}, .{
        .model_context_window = 128000,
        .model_auto_compact_token_limit = 96000,
        .model_reasoning_summary = .detailed,
        .model_verbosity = .high,
    });

    try std.testing.expectEqual(@as(i64, 128000), merged.model_context_window.?);
    try std.testing.expectEqual(@as(i64, 96000), merged.model_auto_compact_token_limit.?);
    try std.testing.expectEqual(config.ReasoningSummary.detailed, merged.model_reasoning_summary.?);
    try std.testing.expectEqual(config.Verbosity.high, merged.model_verbosity.?);
}
