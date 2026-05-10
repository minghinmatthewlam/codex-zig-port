const std = @import("std");

const apply_command = @import("apply_command.zig");
const app_server_cmd = @import("app_server_cmd.zig");
const api = @import("api.zig");
const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const completion_cmd = @import("completion_cmd.zig");
const config = @import("config.zig");
const debug_cmd = @import("debug_cmd.zig");
const env = @import("env.zig");
const exec = @import("exec.zig");
const execpolicy_cmd = @import("execpolicy_cmd.zig");
const features_cmd = @import("features_cmd.zig");
const git_diff = @import("git_diff.zig");
const input_images = @import("input_images.zig");
const login = @import("login.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const mcp_server_cmd = @import("mcp_server_cmd.zig");
const plugin_cmd = @import("plugin_cmd.zig");
const review = @import("review.zig");
const sandbox = @import("sandbox.zig");
const sandbox_cmd = @import("sandbox_cmd.zig");
const session = @import("session.zig");
const session_store = @import("session_store.zig");
const tools = @import("tools.zig");
const tui = @import("tui.zig");
const workdir = @import("workdir.zig");

const version = "0.0.1";

const CliOverrides = struct {
    profile: ?[]const u8 = null,
    runtime: config.RuntimeOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    additional_writable_roots: []const []const u8 = &.{},
    no_alt_screen: bool = false,
    remote: ?[]const u8 = null,
    remote_auth_token_env: ?[]const u8 = null,
    local_remote_control: bool = false,
    remote_control_bind: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
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
    var runtime_feature_overrides = features_cmd.FeatureOverrides{};
    defer runtime_feature_overrides.deinit(allocator);

    var overrides = CliOverrides{};
    var cmd_opt: ?[]const u8 = null;
    var forced_initial_prompt: ?[]const u8 = null;
    defer if (forced_initial_prompt) |prompt| allocator.free(prompt);
    var approval_policy_requested = false;
    var dangerous_bypass_requested = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            overrides.profile = args.next() orelse return error.MissingProfileOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            overrides.profile = arg["--profile=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C")) {
            overrides.cwd = args.next() orelse return error.MissingCdOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cd=")) {
            overrides.cwd = arg["--cd=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--add-dir")) {
            try additional_writable_roots.append(allocator, args.next() orelse return error.MissingAddDirOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            try additional_writable_roots.append(allocator, arg["--add-dir=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            try config.applyRawConfigOverride(
                &overrides.runtime,
                &overrides.profile,
                args.next() orelse return error.MissingConfigOptionValue,
            );
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            try config.applyRawConfigOverride(
                &overrides.runtime,
                &overrides.profile,
                arg["--config=".len..],
            );
            continue;
        }
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            overrides.runtime.model = args.next() orelse return error.MissingModelOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            overrides.runtime.model = arg["--model=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            try input_images.appendFiles(allocator, &initial_image_files, args.next() orelse return error.MissingImageOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendFiles(allocator, &initial_image_files, arg["--image=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--enable")) {
            try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, args.next() orelse return error.MissingFeatureName, true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, args.next() orelse return error.MissingFeatureName, false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            try features_cmd.putRuntimeToggle(allocator, &runtime_feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.eql(u8, arg, "--oss")) {
            overrides.oss = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--local-provider")) {
            overrides.oss_provider = args.next() orelse return error.MissingLocalProviderOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--local-provider=")) {
            overrides.oss_provider = arg["--local-provider=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(args.next() orelse return error.MissingApprovalOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--approval-policy")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(args.next() orelse return error.MissingApprovalOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            overrides.runtime.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(args.next() orelse return error.MissingSandboxOptionValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            overrides.runtime.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo")) {
            if (approval_policy_requested) return error.ConflictingCliOptions;
            dangerous_bypass_requested = true;
            overrides.runtime.approval_policy = .never;
            overrides.runtime.sandbox_mode = .danger_full_access;
            continue;
        }
        if (std.mem.eql(u8, arg, "--search")) {
            overrides.runtime.web_search_mode = .live;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            overrides.remote = args.next() orelse return error.MissingRemoteOptionValue;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            overrides.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-auth-token-env")) {
            overrides.remote_auth_token_env = args.next() orelse return error.MissingRemoteAuthTokenEnvOptionValue;
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
            overrides.remote_control_bind = args.next() orelse return error.MissingRemoteControlBindOptionValue;
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

    const should_apply_cwd = if (cmd_opt) |cmd|
        !isExecCommand(cmd) and
            !std.mem.eql(u8, cmd, "sandbox") and
            !isHelpFlag(cmd) and
            !isVersionFlag(cmd)
    else
        true;
    if (should_apply_cwd) {
        if (overrides.cwd) |cwd| try workdir.change(cwd);
    }

    if (forced_initial_prompt) |initial_prompt| {
        try runTuiWithImages(allocator, initial_image_files.items, .{
            .profile = overrides.profile,
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
        if (commandRejectsRootRemote(cmd)) {
            if (std.mem.eql(u8, cmd, "app-server") and hasRootInteractiveOnlyFlags(overrides)) {
                var remaining = try collectRemainingArgs(allocator, &args);
                defer remaining.deinit(allocator);
                try rejectRemoteModeForSubcommand(
                    overrides.remote,
                    overrides.remote_auth_token_env,
                    overrides.local_remote_control,
                    overrides.remote_control_bind,
                    appServerRemoteRejectionLabel(remaining.items),
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
        if (std.mem.eql(u8, cmd, "review")) {
            try review.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
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
        if (std.mem.eql(u8, cmd, "completion")) {
            try completion_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "debug")) {
            try debug_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
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
            try app_server_cmd.run(allocator, &args);
            return;
        }
        if (std.mem.eql(u8, cmd, "plugin")) {
            try plugin_cmd.run(allocator, &args);
            return;
        }
        if (isRemovedTopLevelCommand(cmd)) {
            return error.RemovedTopLevelCommand;
        }
        if (isKnownUnimplementedCommand(cmd)) {
            try runKnownUnimplementedCommand(cmd, &args);
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
            try runHelpCommand(&args);
            return;
        }
        if (std.mem.eql(u8, cmd, "mcp-server")) {
            try mcp_server_cmd.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .additional_writable_roots = overrides.additional_writable_roots,
            });
            return;
        }
        if (isExecCommand(cmd)) {
            try exec.runWithOptions(allocator, &args, .{
                .profile = overrides.profile,
                .runtime_overrides = overrides.runtime,
                .oss = overrides.oss,
                .oss_provider = overrides.oss_provider,
                .cwd = overrides.cwd,
                .additional_writable_roots = overrides.additional_writable_roots,
            });
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
            var launch = try prepareSessionLaunchOptions(allocator, overrides, initial_image_files.items, parsed);
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
            var launch = try prepareSessionLaunchOptions(allocator, overrides, initial_image_files.items, parsed);
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
            try runSessions(allocator, limit_arg, overrides.profile);
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
        const initial_prompt = try joinInitialPrompt(allocator, cmd, &args);
        defer allocator.free(initial_prompt);
        try runTuiWithImages(allocator, initial_image_files.items, .{
            .profile = overrides.profile,
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
        });
        return;
    }

    try runTuiWithImages(allocator, initial_image_files.items, .{
        .profile = overrides.profile,
        .runtime_overrides = overrides.runtime,
        .oss = overrides.oss,
        .oss_provider = overrides.oss_provider,
        .additional_writable_roots = overrides.additional_writable_roots,
        .no_alt_screen = overrides.no_alt_screen,
        .remote = overrides.remote,
        .remote_auth_token_env = overrides.remote_auth_token_env,
        .local_remote_control = overrides.local_remote_control,
        .remote_control_bind = overrides.remote_control_bind,
    });
}

fn runTuiWithImages(
    allocator: std.mem.Allocator,
    image_files: []const []const u8,
    options: tui.Options,
) !void {
    var loaded_images = try input_images.load(allocator, image_files);
    defer loaded_images.deinit(allocator);

    var next_options = options;
    next_options.initial_input_images = loaded_images.data_urls;
    try tui.runWithOptions(allocator, next_options);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
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

fn commandRejectsRootRemote(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "auth-status") or
        std.mem.eql(u8, cmd, "login") or
        std.mem.eql(u8, cmd, "logout") or
        std.mem.eql(u8, cmd, "review") or
        std.mem.eql(u8, cmd, "sandbox") or
        std.mem.eql(u8, cmd, "features") or
        std.mem.eql(u8, cmd, "completion") or
        std.mem.eql(u8, cmd, "debug") or
        std.mem.eql(u8, cmd, "execpolicy") or
        std.mem.eql(u8, cmd, "mcp") or
        std.mem.eql(u8, cmd, "app-server") or
        std.mem.eql(u8, cmd, "plugin") or
        isKnownUnimplementedCommand(cmd) or
        std.mem.eql(u8, cmd, "stdio-to-uds") or
        std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "mcp-server") or
        std.mem.eql(u8, cmd, "sessions") or
        std.mem.eql(u8, cmd, "mock-demo") or
        std.mem.eql(u8, cmd, "mock-apply-patch") or
        std.mem.eql(u8, cmd, "mock-policy-demo") or
        std.mem.eql(u8, cmd, "mock-sandbox-demo") or
        isExecCommand(cmd) or
        isApplyCommand(cmd);
}

fn appServerRemoteRejectionLabel(args: []const []const u8) []const u8 {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return "app-server";
        if (appServerOptionConsumesValue(arg)) {
            if (index + 1 >= args.len) return "app-server";
            index += 1;
            continue;
        }
        if (appServerOptionHasInlineValue(arg) or std.mem.eql(u8, arg, "--analytics-default-enabled")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return "app-server";
        if (appServerSubcommandLabel(arg)) |label| return label;
        return "app-server";
    }
    return "app-server";
}

fn appServerOptionConsumesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--listen") or
        std.mem.eql(u8, arg, "--ws-auth") or
        std.mem.eql(u8, arg, "--ws-token-file") or
        std.mem.eql(u8, arg, "--ws-token-sha256") or
        std.mem.eql(u8, arg, "--ws-shared-secret-file") or
        std.mem.eql(u8, arg, "--ws-issuer") or
        std.mem.eql(u8, arg, "--ws-audience") or
        std.mem.eql(u8, arg, "--ws-max-clock-skew-seconds");
}

fn appServerOptionHasInlineValue(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--listen=") or
        std.mem.startsWith(u8, arg, "--ws-auth=") or
        std.mem.startsWith(u8, arg, "--ws-token-file=") or
        std.mem.startsWith(u8, arg, "--ws-token-sha256=") or
        std.mem.startsWith(u8, arg, "--ws-shared-secret-file=") or
        std.mem.startsWith(u8, arg, "--ws-issuer=") or
        std.mem.startsWith(u8, arg, "--ws-audience=") or
        std.mem.startsWith(u8, arg, "--ws-max-clock-skew-seconds=");
}

fn appServerSubcommandLabel(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "proxy")) return "app-server proxy";
    if (std.mem.eql(u8, arg, "generate-ts")) return "app-server generate-ts";
    if (std.mem.eql(u8, arg, "generate-json-schema")) return "app-server generate-json-schema";
    if (std.mem.eql(u8, arg, "generate-internal-json-schema")) return "app-server generate-internal-json-schema";
    return null;
}

fn isKnownUnimplementedCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "remote-control") or
        std.mem.eql(u8, cmd, "app") or
        std.mem.eql(u8, cmd, "update") or
        std.mem.eql(u8, cmd, "cloud") or
        std.mem.eql(u8, cmd, "cloud-tasks") or
        std.mem.eql(u8, cmd, "responses-api-proxy") or
        std.mem.eql(u8, cmd, "exec-server");
}

fn isRemovedTopLevelCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "marketplace");
}

fn runKnownUnimplementedCommand(cmd: []const u8, args: *std.process.Args.Iterator) !void {
    if (args.next()) |arg| {
        if (isHelpFlag(arg)) {
            printKnownUnimplementedHelp(cmd);
            return;
        }
    }
    std.debug.print("codex-zig {s} is parsed but not implemented yet\n", .{cmd});
    return error.CliCommandNotImplemented;
}

fn printKnownUnimplementedHelp(cmd: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  codex-zig {s} [ARGS]
        \\
        \\This Rust CLI command is recognized by the Zig port but is not implemented yet.
        \\
    , .{cmd});
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

fn runHelpCommand(args: *std.process.Args.Iterator) !void {
    const target = args.next() orelse {
        try printHelp();
        return;
    };
    if (args.next() != null) return error.UnexpectedHelpArgument;
    if (isHelpFlag(target) or std.mem.eql(u8, target, "help")) {
        try printHelp();
    } else if (isExecCommand(target)) {
        exec.printHelp();
    } else if (isApplyCommand(target)) {
        apply_command.printHelp();
    } else if (std.mem.eql(u8, target, "review")) {
        review.printHelp();
    } else if (std.mem.eql(u8, target, "login")) {
        login.printLoginHelp();
    } else if (std.mem.eql(u8, target, "logout")) {
        printLogoutHelp();
    } else if (std.mem.eql(u8, target, "mcp")) {
        mcp_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "mcp-server")) {
        mcp_server_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "app-server")) {
        app_server_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "plugin")) {
        plugin_cmd.printHelp();
    } else if (isKnownUnimplementedCommand(target)) {
        printKnownUnimplementedHelp(target);
    } else if (std.mem.eql(u8, target, "completion")) {
        completion_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "sandbox")) {
        sandbox_cmd.printHelp();
    } else if (std.mem.eql(u8, target, "debug")) {
        debug_cmd.printHelp();
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
    } else if (std.mem.eql(u8, target, "sessions")) {
        printSessionsHelp();
    } else {
        return error.UnknownHelpCommand;
    }
}

fn joinInitialPrompt(
    allocator: std.mem.Allocator,
    first: []const u8,
    args: *std.process.Args.Iterator,
) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, first);
    while (args.next()) |arg| {
        try parts.append(allocator, arg);
    }
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
    last: bool = false,
    show_all: bool = false,
    include_non_interactive: bool = false,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
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
    help: bool = false,

    fn deinit(self: *SessionCommandArgs, allocator: std.mem.Allocator) void {
        self.additional_writable_roots.deinit(allocator);
        for (self.image_files.items) |path| allocator.free(path);
        self.image_files.deinit(allocator);
    }
};

const SessionLaunchOptions = struct {
    image_files: []const []const u8,
    tui_options: tui.Options,

    fn deinit(self: *SessionLaunchOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.image_files);
        allocator.free(self.tui_options.additional_writable_roots);
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
    initial_image_files: []const []const u8,
    parsed: SessionCommandArgs,
) !SessionLaunchOptions {
    if (parsed.cwd) |cwd| try workdir.change(cwd);

    const image_files = try cli_utils.mergeStringSlices(allocator, initial_image_files, parsed.image_files.items);
    errdefer allocator.free(image_files);

    const additional_writable_roots = try cli_utils.mergeStringSlices(
        allocator,
        overrides.additional_writable_roots,
        parsed.additional_writable_roots.items,
    );
    errdefer allocator.free(additional_writable_roots);

    return .{
        .image_files = image_files,
        .tui_options = .{
            .profile = parsed.profile orelse overrides.profile,
            .runtime_overrides = mergeRuntimeOverrides(overrides.runtime, parsed.runtime_overrides),
            .oss = overrides.oss or parsed.oss,
            .oss_provider = parsed.oss_provider orelse overrides.oss_provider,
            .additional_writable_roots = additional_writable_roots,
            .no_alt_screen = overrides.no_alt_screen or parsed.no_alt_screen,
            .remote = parsed.remote orelse overrides.remote,
            .remote_auth_token_env = parsed.remote_auth_token_env orelse overrides.remote_auth_token_env,
            .local_remote_control = overrides.local_remote_control or parsed.local_remote_control,
            .remote_control_bind = parsed.remote_control_bind orelse overrides.remote_control_bind,
        },
    };
}

fn parseSessionCommandArgs(allocator: std.mem.Allocator, args: []const []const u8, allow_include_non_interactive: bool) !SessionCommandArgs {
    var parsed = SessionCommandArgs{};
    errdefer parsed.deinit(allocator);

    var approval_policy_requested = false;
    var dangerous_bypass_requested = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--last")) {
            parsed.last = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            parsed.show_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--include-non-interactive")) {
            if (!allow_include_non_interactive) return error.UnknownSessionCommandOption;
            parsed.include_non_interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            if (index + 1 >= args.len) return error.MissingProfileOptionValue;
            index += 1;
            parsed.profile = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--profile=")) {
            parsed.profile = arg["--profile=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (index + 1 >= args.len) return error.MissingConfigOptionValue;
            index += 1;
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, arg["--config=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (index + 1 >= args.len) return error.MissingModelOptionValue;
            index += 1;
            parsed.runtime_overrides.model = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            parsed.runtime_overrides.model = arg["--model=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-i")) {
            if (index + 1 >= args.len) return error.MissingImageOptionValue;
            index += 1;
            try input_images.appendFiles(allocator, &parsed.image_files, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--image=")) {
            try input_images.appendFiles(allocator, &parsed.image_files, arg["--image=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cd") or std.mem.eql(u8, arg, "-C")) {
            if (index + 1 >= args.len) return error.MissingCdOptionValue;
            index += 1;
            parsed.cwd = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cd=")) {
            parsed.cwd = arg["--cd=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--add-dir")) {
            if (index + 1 >= args.len) return error.MissingAddDirOptionValue;
            index += 1;
            try parsed.additional_writable_roots.append(allocator, args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            try parsed.additional_writable_roots.append(allocator, arg["--add-dir=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--oss")) {
            parsed.oss = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--local-provider")) {
            if (index + 1 >= args.len) return error.MissingLocalProviderOptionValue;
            index += 1;
            parsed.oss_provider = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--local-provider=")) {
            parsed.oss_provider = arg["--local-provider=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--ask-for-approval") or std.mem.eql(u8, arg, "-a")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            if (index + 1 >= args.len) return error.MissingApprovalOptionValue;
            approval_policy_requested = true;
            index += 1;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ask-for-approval=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(arg["--ask-for-approval=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--approval-policy")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            if (index + 1 >= args.len) return error.MissingApprovalOptionValue;
            approval_policy_requested = true;
            index += 1;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--approval-policy=")) {
            if (dangerous_bypass_requested) return error.ConflictingCliOptions;
            approval_policy_requested = true;
            parsed.runtime_overrides.approval_policy = try config.ApprovalPolicy.parse(arg["--approval-policy=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "-s")) {
            if (index + 1 >= args.len) return error.MissingSandboxOptionValue;
            index += 1;
            parsed.runtime_overrides.sandbox_mode = try config.SandboxMode.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            parsed.runtime_overrides.sandbox_mode = try config.SandboxMode.parse(arg["--sandbox=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox") or std.mem.eql(u8, arg, "--yolo")) {
            if (approval_policy_requested) return error.ConflictingCliOptions;
            dangerous_bypass_requested = true;
            parsed.runtime_overrides.approval_policy = .never;
            parsed.runtime_overrides.sandbox_mode = .danger_full_access;
            continue;
        }
        if (std.mem.eql(u8, arg, "--search")) {
            parsed.runtime_overrides.web_search_mode = .live;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            parsed.no_alt_screen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote")) {
            if (index + 1 >= args.len) return error.MissingRemoteOptionValue;
            index += 1;
            parsed.remote = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote=")) {
            parsed.remote = arg["--remote=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-auth-token-env")) {
            if (index + 1 >= args.len) return error.MissingRemoteAuthTokenEnvOptionValue;
            index += 1;
            parsed.remote_auth_token_env = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-auth-token-env=")) {
            parsed.remote_auth_token_env = arg["--remote-auth-token-env=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control")) {
            parsed.local_remote_control = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-control-bind")) {
            if (index + 1 >= args.len) return error.MissingRemoteControlBindOptionValue;
            index += 1;
            parsed.remote_control_bind = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--remote-control-bind=")) {
            parsed.remote_control_bind = arg["--remote-control-bind=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownSessionCommandOption;
        }
        if (parsed.target != null) return error.UnexpectedSessionCommandArgument;
        parsed.target = arg;
    }
    return parsed;
}

fn mergeRuntimeOverrides(base: config.RuntimeOverrides, session_overrides: config.RuntimeOverrides) config.RuntimeOverrides {
    var merged = base;
    if (session_overrides.model) |value| merged.model = value;
    if (session_overrides.openai_base_url) |value| merged.openai_base_url = value;
    if (session_overrides.chatgpt_base_url) |value| merged.chatgpt_base_url = value;
    if (session_overrides.oss_provider) |value| merged.oss_provider = value;
    if (session_overrides.approval_policy) |value| merged.approval_policy = value;
    if (session_overrides.sandbox_mode) |value| merged.sandbox_mode = value;
    if (session_overrides.web_search_mode) |value| merged.web_search_mode = value;
    if (session_overrides.service_tier) |value| merged.service_tier = value;
    if (session_overrides.syntax_theme) |value| merged.syntax_theme = value;
    if (session_overrides.personality) |value| merged.personality = value;
    if (session_overrides.tui_alternate_screen) |value| merged.tui_alternate_screen = value;
    return merged;
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
        \\  codex-zig cloud        Recognized; not implemented yet
        \\  codex-zig exec-server  Recognized; not implemented yet
        \\  codex-zig plugin marketplace <COMMAND>
        \\  codex-zig remote-control
        \\                          Recognized; not implemented yet
        \\  codex-zig auth-status  Check local Codex auth reuse
        \\  codex-zig help [COMMAND]
        \\                          Print general or command-specific help
        \\  codex-zig --profile NAME ...
        \\                          Select a config profile for the command
        \\  codex-zig --cd DIR ...
        \\                          Use DIR as the working root
        \\  codex-zig --add-dir DIR ...
        \\                          Allow workspace-write shell tools to write DIR
        \\  codex-zig -c key=value ...
        \\                          Override a supported config value
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
        \\  codex-zig --search ...
        \\                          Enable live web search for Responses turns
        \\  codex-zig --remote ws://HOST:PORT
        \\                          Parse remote app-server target for interactive TUI
        \\  codex-zig --remote-auth-token-env ENV_VAR
        \\                          Read bearer token env var for remote app-server
        \\  codex-zig --remote-control
        \\                          Parse local remote-control server mode
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
        \\Removes the selected CODEX_HOME/auth.json file.
        \\
    , .{});
}

fn printResumeHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig resume
        \\  codex-zig resume [--all] [--include-non-interactive] [--remote ADDR]
        \\  codex-zig resume --last [--all] [--include-non-interactive] [--remote ADDR]
        \\  codex-zig resume ID|PATH|last
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
        \\  codex-zig fork ID|PATH|last
        \\
        \\Without a target, opens a numbered picker for saved Zig sessions.
        \\--all and remote flags are accepted for Rust CLI compatibility.
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

fn runSessions(allocator: std.mem.Allocator, limit_arg: ?[]const u8, profile: ?[]const u8) !void {
    const limit = if (limit_arg) |value| try std.fmt.parseUnsigned(usize, value, 10) else 10;
    var cfg = try config.loadWithOptions(allocator, .{ .profile = profile });
    defer cfg.deinit(allocator);

    try session_store.printSessionList(allocator, cfg.codex_home, limit);
}

fn runAuthStatus(allocator: std.mem.Allocator, overrides: CliOverrides) !void {
    var cfg = try config.loadWithOptions(allocator, .{ .profile = overrides.profile });
    defer cfg.deinit(allocator);
    try config.applyRuntimeOverrides(&cfg, allocator, overrides.runtime);
    var credentials = try auth.load(allocator, cfg.codex_home);
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
        .api_key, .local_oss => cfg.openai_base_url,
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
    const argv = [_][]const u8{ "--all", "--include-non-interactive", "--last" };
    var parsed = try parseSessionCommandArgs(allocator, argv[0..], true);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.show_all);
    try std.testing.expect(parsed.include_non_interactive);
    try std.testing.expect(parsed.last);
    try std.testing.expect(parsed.target == null);
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
        "/tmp/a.png,/tmp/b.png",
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
    try std.testing.expectEqualStrings("gpt-5.1-test", parsed.runtime_overrides.model.?);
    try std.testing.expectEqualStrings("work", parsed.profile.?);
    try std.testing.expectEqualStrings("/tmp/workspace", parsed.cwd.?);
    try std.testing.expectEqualStrings("/tmp/extra", parsed.additional_writable_roots.items[0]);
    try std.testing.expectEqualStrings("/tmp/a.png", parsed.image_files.items[0]);
    try std.testing.expectEqualStrings("/tmp/b.png", parsed.image_files.items[1]);
    try std.testing.expect(parsed.no_alt_screen);
}

test "session command flags parse target and reject extra target" {
    const allocator = std.testing.allocator;
    const target_argv = [_][]const u8{"session-id"};
    var target = try parseSessionCommandArgs(allocator, target_argv[0..], false);
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("session-id", target.target.?);

    const extra_argv = [_][]const u8{ "one", "two" };
    try std.testing.expectError(error.UnexpectedSessionCommandArgument, parseSessionCommandArgs(allocator, extra_argv[0..], true));
}

test "fork session command rejects include non interactive" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"--include-non-interactive"};
    try std.testing.expectError(error.UnknownSessionCommandOption, parseSessionCommandArgs(allocator, argv[0..], false));
}

test "root remote is only accepted for interactive commands" {
    try std.testing.expect(commandRejectsRootRemote("exec"));
    try std.testing.expect(commandRejectsRootRemote("app-server"));
    try std.testing.expect(commandRejectsRootRemote("plugin"));
    try std.testing.expect(commandRejectsRootRemote("remote-control"));
    try std.testing.expect(!commandRejectsRootRemote("resume"));
    try std.testing.expect(!commandRejectsRootRemote("fork"));
    try std.testing.expect(!commandRejectsRootRemote("write this prompt"));
}

test "app-server remote rejection labels known subcommands" {
    try std.testing.expectEqualStrings("app-server", appServerRemoteRejectionLabel(&.{}));
    try std.testing.expectEqualStrings("app-server proxy", appServerRemoteRejectionLabel(&.{"proxy"}));
    try std.testing.expectEqualStrings(
        "app-server proxy",
        appServerRemoteRejectionLabel(&.{ "--listen", "off", "proxy" }),
    );
    try std.testing.expectEqualStrings(
        "app-server generate-internal-json-schema",
        appServerRemoteRejectionLabel(&.{ "--listen=off", "generate-internal-json-schema" }),
    );
    try std.testing.expectEqualStrings(
        "app-server generate-ts",
        appServerRemoteRejectionLabel(&.{ "--ws-auth", "capability-token", "generate-ts" }),
    );
    try std.testing.expectEqualStrings("app-server", appServerRemoteRejectionLabel(&.{"--help"}));
}

test "known unimplemented Rust commands are recognized" {
    try std.testing.expect(isKnownUnimplementedCommand("remote-control"));
    try std.testing.expect(isKnownUnimplementedCommand("app"));
    try std.testing.expect(isKnownUnimplementedCommand("update"));
    try std.testing.expect(isKnownUnimplementedCommand("cloud"));
    try std.testing.expect(isKnownUnimplementedCommand("cloud-tasks"));
    try std.testing.expect(isKnownUnimplementedCommand("responses-api-proxy"));
    try std.testing.expect(isKnownUnimplementedCommand("exec-server"));
    try std.testing.expect(!isKnownUnimplementedCommand("plugin"));
    try std.testing.expect(!isKnownUnimplementedCommand("write this prompt"));
}

test "removed top-level Rust commands are rejected" {
    try std.testing.expect(isRemovedTopLevelCommand("marketplace"));
    try std.testing.expect(!isRemovedTopLevelCommand("plugin"));
    try std.testing.expect(!isRemovedTopLevelCommand("write this prompt"));
}
