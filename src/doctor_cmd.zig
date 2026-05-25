const std = @import("std");
const builtin = @import("builtin");

const auth = @import("auth.zig");
const cli_utils = @import("cli_utils.zig");
const config = @import("config.zig");
const env = @import("env.zig");
const features_cmd = @import("features_cmd.zig");
const memory_reset = @import("memory_reset.zig");
const mcp_cmd = @import("mcp_cmd.zig");
const sqlite = @import("sqlite.zig");
const update_cmd = @import("update_cmd.zig");

pub const Options = struct {
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    version: []const u8 = "0.0.1",
    strict_config: bool = false,
    unknown_config_override: ?[]const u8 = null,
};

const ParsedArgs = struct {
    json: bool = false,
    summary: bool = false,
    all: bool = false,
    no_color: bool = false,
    ascii: bool = false,
    help: bool = false,
    profile: ?[]const u8 = null,
    runtime_overrides: config.RuntimeOverrides = .{},
    feature_overrides: features_cmd.FeatureOverrides = .{},
    oss: bool = false,
    oss_provider: ?[]const u8 = null,
    strict_config: bool = false,
    unknown_config_override: ?[]const u8 = null,

    fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.unknown_config_override) |field| allocator.free(field);
        self.feature_overrides.deinit(allocator);
    }
};

const Status = enum {
    ok,
    warning,
    fail,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warning => "warning",
            .fail => "fail",
        };
    }

    fn marker(self: Status) []const u8 {
        return switch (self) {
            .ok => "[ok]",
            .warning => "[!!]",
            .fail => "[XX]",
        };
    }
};

const Detail = struct {
    key: []const u8,
    value: []const u8,
};

const Issue = struct {
    severity: Status,
    cause: []const u8,
    measured: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    remedy: ?[]const u8 = null,
    fields: []const []const u8 = &.{},
};

const Check = struct {
    id: []const u8,
    category: []const u8,
    status: Status,
    summary: []const u8,
    details: std.ArrayList(Detail) = .empty,
    issues: std.ArrayList(Issue) = .empty,
    remediation: ?[]const u8 = null,
    duration_ms: u64 = 0,

    fn init(id: []const u8, category: []const u8, status: Status, summary: []const u8) Check {
        return .{
            .id = id,
            .category = category,
            .status = status,
            .summary = summary,
        };
    }

    fn addDetail(self: *Check, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.details.append(allocator, .{
            .key = key,
            .value = try allocator.dupe(u8, value),
        });
    }

    fn addDetailFmt(
        self: *Check,
        allocator: std.mem.Allocator,
        key: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.details.append(allocator, .{
            .key = key,
            .value = try std.fmt.allocPrint(allocator, format, args),
        });
    }

    fn addIssue(self: *Check, allocator: std.mem.Allocator, issue: Issue) !void {
        try self.issues.append(allocator, issue);
    }
};

const Report = struct {
    schema_version: u32 = 1,
    generated_at: []const u8,
    overall_status: Status,
    codex_version: []const u8,
    checks: []const Check,
};

const StatusCounts = struct {
    ok: usize,
    warning: usize,
    fail: usize,
};

const ConfigLoad = struct {
    cfg: ?config.Config = null,
    err: ?anyerror = null,
    codex_home: ?[]const u8 = null,
    cwd: []const u8,
};

const PathHealth = enum {
    ok,
    missing,
    inaccessible,
};

const PathInspection = struct {
    rendered: []const u8,
    health: PathHealth,
    error_name: ?[]const u8 = null,
};

const CommandProbe = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    fn deinit(self: *const CommandProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn success(self: CommandProbe) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

const AppServerRuntimeStatus = struct {
    status: Status,
    summary: []const u8,
    detail: []const u8,
    remediation: ?[]const u8 = null,
};

const RolloutStats = struct {
    files: u64 = 0,
    total_bytes: u64 = 0,
    error_name: ?[]const u8 = null,

    fn averageBytes(self: RolloutStats) u64 {
        return if (self.files == 0) 0 else self.total_bytes / self.files;
    }
};

pub fn runWithOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var argv = std.ArrayList([]const u8).empty;
    while (args.next()) |arg| try argv.append(scratch, arg);

    var parsed = try parseArgs(scratch, argv.items, options);
    defer parsed.deinit(scratch);

    if (parsed.help) {
        printHelp();
        return;
    }

    const report = try buildReport(scratch, parsed, options.version);
    const rendered = if (parsed.json)
        try renderJsonReport(scratch, report)
    else
        try renderHumanReport(scratch, report, parsed);
    try cli_utils.writeStdout(rendered);

    if (report.overall_status == .fail) return error.DoctorChecksFailed;
}

pub fn printHelp() void {
    std.debug.print(
        \\Diagnose local Codex installation, config, auth, and runtime health
        \\
        \\Usage:
        \\  codex-zig doctor [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <key=value>
        \\                          Override a supported config value
        \\      --strict-config     Error on unknown config fields
        \\      --json              Emit a redacted machine-readable report
        \\      --enable FEATURE    Enable a feature for this invocation
        \\      --summary           Only show grouped rows and final counts
        \\      --all               Expand long lists in detailed human output
        \\      --disable FEATURE   Disable a feature for this invocation
        \\      --no-color          Disable ANSI color in human output
        \\      --ascii             Use ASCII labels and separators
        \\  -h, --help              Print help
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8, options: Options) !ParsedArgs {
    var parsed = ParsedArgs{
        .profile = options.profile,
        .runtime_overrides = options.runtime_overrides,
        .feature_overrides = try options.feature_overrides.clone(allocator),
        .oss = options.oss,
        .oss_provider = options.oss_provider,
        .strict_config = options.strict_config,
        .unknown_config_override = if (options.unknown_config_override) |field| try allocator.dupe(u8, field) else null,
    };
    errdefer parsed.deinit(allocator);

    if (helpPreflight(argv)) {
        parsed.help = true;
        return parsed;
    }

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (isHelpFlag(arg)) {
            parsed.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary")) {
            parsed.summary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            parsed.all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            parsed.no_color = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ascii")) {
            parsed.ascii = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-config")) {
            parsed.strict_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= argv.len) return error.MissingConfigOptionValue;
            try config.rememberStrictConfigUnknownOverride(allocator, &parsed.unknown_config_override, argv[index]);
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, argv[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            const raw = arg["--config=".len..];
            try config.rememberStrictConfigUnknownOverride(allocator, &parsed.unknown_config_override, raw);
            try config.applyRawConfigOverride(&parsed.runtime_overrides, &parsed.profile, raw);
            continue;
        }
        if (std.mem.eql(u8, arg, "--enable")) {
            index += 1;
            if (index >= argv.len) return error.MissingFeatureName;
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, argv[index], true);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--enable=")) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--enable=".len..], true);
            continue;
        }
        if (std.mem.eql(u8, arg, "--disable")) {
            index += 1;
            if (index >= argv.len) return error.MissingFeatureName;
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, argv[index], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--disable=")) {
            try features_cmd.putRuntimeToggle(allocator, &parsed.feature_overrides, arg["--disable=".len..], false);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownDoctorOption;
        return error.UnexpectedDoctorArgument;
    }

    if (parsed.strict_config and !parsed.help) {
        if (parsed.unknown_config_override) |field| return config.failStrictConfigUnknownCliOverride(field);
    }

    return parsed;
}

fn helpPreflight(argv: []const []const u8) bool {
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
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
        if (std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--enable") or
            std.mem.eql(u8, arg, "--disable"))
        {
            index += 1;
            if (index >= argv.len or optionValueBoundary(argv[index])) return false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=") or
            std.mem.startsWith(u8, arg, "--enable=") or
            std.mem.startsWith(u8, arg, "--disable="))
        {
            continue;
        }
        return false;
    }
    return false;
}

fn optionValueBoundary(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn buildReport(allocator: std.mem.Allocator, args: ParsedArgs, codex_version: []const u8) !Report {
    var checks = std.ArrayList(Check).empty;

    const cfg_load = try loadConfigForDoctor(allocator, args);

    try checks.append(allocator, try installationCheck(allocator, codex_version));
    try checks.append(allocator, try runtimeCheck(allocator, codex_version));
    try checks.append(allocator, try searchCheck(allocator));
    try checks.append(allocator, try configCheck(allocator, cfg_load, args));
    try checks.append(allocator, try authCheck(allocator, cfg_load));
    try checks.append(allocator, try mcpCheck(allocator, cfg_load));
    try checks.append(allocator, try sandboxCheck(allocator, cfg_load));
    try checks.append(allocator, try updatesCheck(allocator));
    try checks.append(allocator, try networkCheck(allocator));
    try checks.append(allocator, try appServerCheck(allocator, cfg_load));
    try checks.append(allocator, try terminalCheck(allocator));
    try checks.append(allocator, try stateCheck(allocator, cfg_load));

    const generated_at = try std.fmt.allocPrint(allocator, "{d}s since unix epoch", .{currentUnixSeconds()});
    return .{
        .generated_at = generated_at,
        .overall_status = overallStatus(checks.items),
        .codex_version = codex_version,
        .checks = try checks.toOwnedSlice(allocator),
    };
}

fn loadConfigForDoctor(allocator: std.mem.Allocator, args: ParsedArgs) !ConfigLoad {
    const cwd = std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator) catch try allocator.dupeZ(u8, ".");
    const codex_home = config.resolveCodexHome(allocator) catch null;
    var loaded = config.loadWithOptions(allocator, .{ .profile = args.profile, .strict_config = args.strict_config }) catch |err| {
        return .{
            .err = err,
            .codex_home = codex_home,
            .cwd = cwd,
        };
    };
    config.applyRuntimeOverrides(&loaded, allocator, args.runtime_overrides) catch |err| {
        return .{
            .err = err,
            .codex_home = codex_home,
            .cwd = cwd,
        };
    };
    if (args.oss) {
        config.applyOssMode(&loaded, allocator, args.oss_provider, args.runtime_overrides.model != null) catch |err| {
            return .{
                .err = err,
                .codex_home = codex_home,
                .cwd = cwd,
            };
        };
    }
    return .{
        .cfg = loaded,
        .codex_home = loaded.codex_home,
        .cwd = cwd,
    };
}

fn installationCheck(allocator: std.mem.Allocator, codex_version: []const u8) !Check {
    var check = Check.init("installation", "install", .ok, "installation context is readable");
    try check.addDetail(allocator, "version", codex_version);

    const io = std.Io.Threaded.global_single_threaded.io();
    const exe = std.process.executablePathAlloc(io, allocator) catch null;
    if (exe) |path| {
        try check.addDetail(allocator, "current executable", path);
    } else {
        check.status = .warning;
        check.summary = "current executable could not be resolved";
        try check.addDetail(allocator, "current executable", "unknown");
    }

    if (try update_cmd.detectCurrentUpdateAction(allocator)) |action| {
        try check.addDetail(allocator, "update action", action.commandString());
    } else {
        check.status = .warning;
        check.summary = "installation method is not detected";
        try check.addDetail(allocator, "update action", "unknown");
        check.remediation = "Update this build manually when a newer Codex version is needed.";
    }
    return check;
}

fn runtimeCheck(allocator: std.mem.Allocator, codex_version: []const u8) !Check {
    var check = Check.init("runtime.provenance", "runtime", .ok, "running Zig port");
    try check.addDetail(allocator, "version", codex_version);
    try check.addDetailFmt(allocator, "platform", "{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    try check.addDetail(allocator, "build mode", @tagName(builtin.mode));
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.process.executablePathAlloc(io, allocator)) |exe| {
        try check.addDetail(allocator, "current executable", exe);
    } else |_| {
        try check.addDetail(allocator, "current executable", "unknown");
    }
    return check;
}

fn searchCheck(allocator: std.mem.Allocator) !Check {
    var check = Check.init("runtime.search", "search", .ok, "search is OK (system)");
    try check.addDetail(allocator, "search provider", "system");
    try check.addDetail(allocator, "search command", "rg");
    const rg_path = resolveCommandOnPath(allocator, "rg") catch |err| {
        check.status = .warning;
        check.summary = "search command could not be verified";
        try check.addDetailFmt(allocator, "search command readiness", "{s}", .{@errorName(err)});
        check.remediation = "Install ripgrep or repair the bundled Codex package.";
        return check;
    };
    try check.addDetail(allocator, "search command resolved", rg_path);
    var probe = runCommandProbe(allocator, &.{ rg_path, "--version" }) catch |err| {
        check.status = .warning;
        check.summary = "search command could not be verified";
        try check.addDetailFmt(allocator, "search command readiness", "{s}", .{@errorName(err)});
        check.remediation = "Install ripgrep or repair the bundled Codex package.";
        return check;
    };
    defer probe.deinit(allocator);

    if (probe.success()) {
        try check.addDetail(allocator, "search command readiness", firstNonEmptyLine(probe.stdout) orelse "rg version unknown");
    } else {
        check.status = .warning;
        check.summary = "search command could not be verified";
        if (firstNonEmptyLine(probe.stderr) orelse firstNonEmptyLine(probe.stdout)) |line| {
            try check.addDetailFmt(allocator, "search command readiness", "exited with {s}: {s}", .{ try childTermLabel(allocator, probe.term), line });
        } else {
            try check.addDetailFmt(allocator, "search command readiness", "exited with {s}", .{try childTermLabel(allocator, probe.term)});
        }
        check.remediation = "Install ripgrep or repair the bundled Codex package.";
    }
    return check;
}

fn configCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad, args: ParsedArgs) !Check {
    if (cfg_load.err) |err| {
        var check = Check.init("config.load", "config", .fail, "config failed to load");
        if (cfg_load.codex_home) |home| try check.addDetail(allocator, "CODEX_HOME", home);
        try check.addDetail(allocator, "cwd", cfg_load.cwd);
        try check.addDetail(allocator, "error", @errorName(err));
        check.remediation = "Fix config.toml or select an existing profile.";
        try check.addIssue(allocator, .{
            .severity = .fail,
            .cause = "configuration could not be loaded",
            .measured = @errorName(err),
            .remedy = "Fix the reported configuration error and rerun `codex doctor`.",
        });
        return check;
    }

    const cfg = cfg_load.cfg.?;
    var check = Check.init("config.load", "config", .ok, "config loaded");
    try check.addDetail(allocator, "CODEX_HOME", cfg.codex_home);
    try check.addDetail(allocator, "cwd", cfg_load.cwd);
    try check.addDetail(allocator, "model", cfg.model);
    try check.addDetail(allocator, "model provider", cfg.model_provider_id orelse "openai");
    if (cfg.log_dir) |log_dir| try check.addDetail(allocator, "log dir", log_dir);
    if (cfg.sqlite_home) |sqlite_home| try check.addDetail(allocator, "sqlite home", sqlite_home);
    try check.addDetail(allocator, "approval policy", cfg.approval_policy.label());
    try check.addDetail(allocator, "sandbox mode", cfg.sandbox_mode.label());
    try check.addDetail(allocator, "web search", if (cfg.web_search_mode) |mode| mode.label() else "default");
    try check.addDetail(allocator, "auth storage mode", cfg.cli_auth_credentials_store_mode.label());
    try check.addDetail(allocator, "active profile", cfg.active_profile orelse "default");
    try check.addDetailFmt(allocator, "feature flag overrides", "{d}", .{args.feature_overrides.items.items.len});
    return check;
}

fn authCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad) !Check {
    if (cfg_load.cfg == null) {
        var check = Check.init("auth.credentials", "auth", .warning, "auth check skipped because config failed");
        check.remediation = "Fix config loading first.";
        return check;
    }

    const cfg = cfg_load.cfg.?;
    const openai_api_key = try envPresent(allocator, "OPENAI_API_KEY");
    const access_token = try envPresent(allocator, "CODEX_ACCESS_TOKEN");
    var env_names = std.ArrayList([]const u8).empty;
    if (access_token) try env_names.append(allocator, "CODEX_ACCESS_TOKEN");
    if (openai_api_key) try env_names.append(allocator, "OPENAI_API_KEY");

    var check = Check.init("auth.credentials", "auth", .ok, "auth is configured");
    try check.addDetail(allocator, "auth env vars present", try joinOrNone(allocator, env_names.items));
    try check.addDetail(allocator, "auth storage mode", cfg.cli_auth_credentials_store_mode.label());
    try check.addDetail(allocator, "provider requires OpenAI auth", boolString(cfg.model_provider_requires_openai_auth));

    if (try providerAuthCheck(allocator, &cfg, &check)) {
        return check;
    }

    const stored = auth.loadActiveStoredWithMode(allocator, cfg.codex_home, cfg.cli_auth_credentials_store_mode) catch |err| {
        check.status = .fail;
        check.summary = "stored auth could not be read";
        try check.addDetail(allocator, "stored auth error", @errorName(err));
        check.remediation = "Run `codex login` or repair the configured auth store.";
        return check;
    };
    if (stored) |credentials| {
        if (!credentialsUsable(credentials)) {
            const env_source = runtimeEnvAuthSource(access_token, openai_api_key);
            check.status = if (env_source != null) .warning else .fail;
            check.summary = if (env_source != null)
                "auth is provided by environment, but stored credentials are incomplete"
            else
                "stored credentials are incomplete";
            try check.addDetail(allocator, "auth source", env_source orelse "stored credentials incomplete");
            check.remediation = "Run `codex login` again or provide a supported auth env var.";
            try check.addIssue(allocator, .{
                .severity = check.status,
                .cause = "stored credentials are missing usable token material",
                .measured = credentials.describe(),
                .expected = "non-empty stored token",
                .remedy = "Run `codex login` again or set OPENAI_API_KEY.",
            });
            return check;
        }
        try check.addDetail(allocator, "auth source", credentials.describe());
        return check;
    }
    if (runtimeEnvAuthSource(access_token, openai_api_key)) |source| {
        try check.addDetail(allocator, "auth source", source);
        return check;
    }

    check.status = .fail;
    check.summary = "no Codex credentials were found";
    try check.addDetail(allocator, "auth source", "none");
    check.remediation = "Run `codex login` or provide a supported auth env var.";
    try check.addIssue(allocator, .{
        .severity = .fail,
        .cause = "no usable auth was found for the active model provider",
        .measured = "missing auth.json and supported auth env vars",
        .expected = "stored credentials, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN",
        .remedy = "Run `codex login` or set OPENAI_API_KEY.",
    });
    return check;
}

fn providerAuthCheck(allocator: std.mem.Allocator, cfg: *const config.Config, check: *Check) !bool {
    if (cfg.model_provider_env_key) |key| {
        const present = try envPresentDynamicTrimmed(allocator, key);
        try check.addDetailFmt(allocator, "provider auth env var", "{s} ({s})", .{ key, if (present) "present" else "missing" });
        if (!present) {
            check.status = .fail;
            check.summary = "active model provider auth env var is missing";
            try check.addDetail(allocator, "auth source", "none");
            check.remediation = try std.fmt.allocPrint(allocator, "Set {s} for the active model provider.", .{key});
            try check.addIssue(allocator, .{
                .severity = .fail,
                .cause = "active model provider auth env var is missing",
                .measured = "missing",
                .expected = key,
                .remedy = check.remediation,
            });
            return true;
        }
        check.summary = "auth is provided by the active model provider";
        try check.addDetail(allocator, "auth source", "provider auth env var");
        return true;
    }

    if (cfg.model_provider_bearer_token) |token| {
        const present = std.mem.trim(u8, token, " \t\r\n").len > 0;
        try check.addDetail(allocator, "provider bearer token", if (present) "configured" else "empty");
        if (!present) {
            check.status = .fail;
            check.summary = "active model provider bearer token is empty";
            try check.addDetail(allocator, "auth source", "none");
            check.remediation = "Set a non-empty experimental_bearer_token for the active model provider.";
            try check.addIssue(allocator, .{
                .severity = .fail,
                .cause = "active model provider bearer token is empty",
                .measured = "empty",
                .expected = "non-empty bearer token",
                .remedy = check.remediation,
            });
            return true;
        }
        check.summary = "auth is provided by the active model provider";
        try check.addDetail(allocator, "auth source", "provider bearer token");
        return true;
    }

    if (cfg.model_provider_auth_command) |command| {
        try check.addDetail(allocator, "provider auth command", command.command);
        var credentials = auth.loadProviderCommandCredentials(allocator, command) catch |err| {
            check.status = .fail;
            check.summary = "active model provider auth command failed";
            try check.addDetail(allocator, "provider auth command error", @errorName(err));
            try check.addDetail(allocator, "auth source", "none");
            check.remediation = "Fix the active model provider auth command.";
            try check.addIssue(allocator, .{
                .severity = .fail,
                .cause = "active model provider auth command failed",
                .measured = @errorName(err),
                .expected = "command returns usable credentials",
                .remedy = check.remediation,
            });
            return true;
        };
        defer credentials.deinit(allocator);
        check.summary = "auth is provided by the active model provider";
        try check.addDetail(allocator, "auth source", "provider auth command");
        return true;
    }

    if (!cfg.model_provider_requires_openai_auth) {
        check.summary = "OpenAI auth is not required for the active model provider";
        try check.addDetail(allocator, "auth source", "provider auth not required");
        return true;
    }

    return false;
}

fn mcpCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad) !Check {
    if (cfg_load.cfg == null) {
        var check = Check.init("mcp.config", "mcp", .warning, "MCP check skipped because config failed");
        check.remediation = "Fix config loading first.";
        return check;
    }

    const cfg = cfg_load.cfg.?;
    const servers = mcp_cmd.loadServers(allocator, cfg.codex_home) catch |err| {
        var check = Check.init("mcp.config", "mcp", .warning, "MCP configuration could not be fully loaded");
        try check.addDetail(allocator, "error", @errorName(err));
        check.remediation = "Inspect `codex mcp list` and repair invalid MCP config.";
        return check;
    };

    var stdio_count: usize = 0;
    var http_count: usize = 0;
    var disabled_count: usize = 0;
    for (servers.items.items) |server| {
        if (!server.enabled) disabled_count += 1;
        switch (server.kind) {
            .stdio => stdio_count += 1,
            .streamable_http => http_count += 1,
            .unknown => {},
        }
    }

    var check = Check.init("mcp.config", "mcp", .ok, "MCP configuration is locally parseable");
    try check.addDetailFmt(allocator, "configured servers", "{d}", .{servers.items.items.len});
    try check.addDetailFmt(allocator, "disabled servers", "{d}", .{disabled_count});
    try check.addDetailFmt(allocator, "stdio servers", "{d}", .{stdio_count});
    try check.addDetailFmt(allocator, "streamable_http servers", "{d}", .{http_count});
    return check;
}

fn sandboxCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad) !Check {
    if (cfg_load.cfg == null) {
        var check = Check.init("sandbox.helpers", "sandbox", .warning, "sandbox check skipped because config failed");
        check.remediation = "Fix config loading first.";
        return check;
    }

    const cfg = cfg_load.cfg.?;
    var check = Check.init("sandbox.helpers", "sandbox", .ok, "sandbox configuration is readable");
    try check.addDetail(allocator, "approval policy", cfg.approval_policy.label());
    try check.addDetail(allocator, "filesystem sandbox", cfg.sandbox_mode.label());
    try check.addDetail(allocator, "network sandbox", if (cfg.sandbox_mode == .read_only) "disabled by default" else "controlled by sandbox policy");
    return check;
}

fn updatesCheck(allocator: std.mem.Allocator) !Check {
    var check = Check.init("updates.status", "updates", .ok, "update configuration is locally inspectable");
    if (try update_cmd.detectCurrentUpdateAction(allocator)) |action| {
        try check.addDetail(allocator, "update action", action.commandString());
    } else {
        check.status = .warning;
        check.summary = "update method is unknown";
        try check.addDetail(allocator, "update action", "unknown");
        check.remediation = "Update this build manually.";
    }
    return check;
}

fn networkCheck(allocator: std.mem.Allocator) !Check {
    var names = std.ArrayList([]const u8).empty;
    inline for (&.{ "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy" }) |name| {
        if (try envPresent(allocator, name)) try names.append(allocator, name);
    }
    var check = Check.init("network.env", "network", .ok, "network-related environment looks readable");
    try check.addDetail(allocator, "proxy env vars", try joinOrNone(allocator, names.items));
    inline for (&.{ "CODEX_CA_CERTIFICATE", "SSL_CERT_FILE" }) |name| {
        if (try env.getOwned(allocator, name)) |value| {
            try recordCustomCaEnvPath(allocator, &check, name, value);
        }
    }
    return check;
}

fn appServerCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad) !Check {
    const home = if (cfg_load.cfg) |cfg| cfg.codex_home else cfg_load.codex_home orelse ".";
    const control_socket = try std.fs.path.join(allocator, &.{ home, "app-server-control", "app-server-control.sock" });
    const daemon_dir = try std.fs.path.join(allocator, &.{ home, "app-server-daemon" });
    const pid_file = try std.fs.path.join(allocator, &.{ daemon_dir, "app-server.pid" });
    const settings_file = try std.fs.path.join(allocator, &.{ daemon_dir, "settings.json" });
    const updater_pid_file = try std.fs.path.join(allocator, &.{ daemon_dir, "app-server-updater.pid" });

    var check = Check.init("app_server.status", "app-server", .ok, "background server status is locally inspectable");
    const control_socket_inspection = try inspectPath(allocator, control_socket);
    const daemon_dir_inspection = try inspectPath(allocator, daemon_dir);
    const pid_file_inspection = try inspectPath(allocator, pid_file);
    const settings_file_inspection = try inspectPath(allocator, settings_file);
    const updater_pid_file_inspection = try inspectPath(allocator, updater_pid_file);
    try recordAppServerPathInspection(allocator, &check, "control socket", control_socket_inspection);
    try recordAppServerPathInspection(allocator, &check, "daemon state dir", daemon_dir_inspection);
    try check.addDetail(allocator, "mode", if (settings_file_inspection.health == .ok) "persistent" else "ephemeral");
    try recordAppServerPathInspection(allocator, &check, "pid file", pid_file_inspection);
    try recordAppServerPathInspection(allocator, &check, "settings", settings_file_inspection);

    const runtime_status = try appServerRuntimeStatus(control_socket, control_socket_inspection.health);
    if (check.status != .fail) {
        check.status = runtime_status.status;
        check.summary = runtime_status.summary;
        if (runtime_status.remediation) |remediation| check.remediation = remediation;
    }
    try check.addDetail(allocator, "status", runtime_status.detail);
    try recordAppServerPathInspection(allocator, &check, "update-loop pid file", updater_pid_file_inspection);
    return check;
}

fn recordAppServerPathInspection(allocator: std.mem.Allocator, check: *Check, key: []const u8, inspection: PathInspection) !void {
    try check.addDetail(allocator, key, inspection.rendered);
    if (inspection.health != .inaccessible) return;

    check.status = .fail;
    check.summary = "background server paths are not inspectable";
    const cause = try std.fmt.allocPrint(allocator, "{s} is not readable", .{key});
    try check.addIssue(allocator, .{
        .severity = .fail,
        .cause = cause,
        .measured = inspection.error_name,
        .expected = "readable app-server state path",
        .remedy = "Fix CODEX_HOME permissions or repair the affected app-server path.",
        .fields = try allocator.dupe([]const u8, &.{key}),
    });
    check.remediation = "Fix CODEX_HOME permissions or repair the affected app-server path.";
}

fn terminalCheck(allocator: std.mem.Allocator) !Check {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
    var check = Check.init("terminal.env", "terminal", .ok, "terminal metadata was detected");
    if (!stdin_tty and !stdout_tty and !stderr_tty) {
        check.summary = "terminal streams are not TTYs";
    }
    try check.addDetail(allocator, "stdin is terminal", boolString(stdin_tty));
    try check.addDetail(allocator, "stdout is terminal", boolString(stdout_tty));
    try check.addDetail(allocator, "stderr is terminal", boolString(stderr_tty));
    inline for (&.{ "TERM", "TERM_PROGRAM", "COLORTERM", "NO_COLOR" }) |name| {
        if (try env.getOwned(allocator, name)) |value| try check.addDetail(allocator, name, value);
    }
    return check;
}

fn stateCheck(allocator: std.mem.Allocator, cfg_load: ConfigLoad) !Check {
    const home = if (cfg_load.cfg) |cfg| cfg.codex_home else cfg_load.codex_home orelse ".";
    var check = Check.init("state.paths", "state", .ok, "state paths and databases are inspectable");
    try addStatePathDetail(allocator, &check, "CODEX_HOME", home);
    const log_dir = try doctorLogDir(allocator, cfg_load, home);
    const sqlite_home = try doctorSqliteHome(allocator, cfg_load, home);
    try addStatePathDetail(allocator, &check, "log dir", log_dir);
    try addStatePathDetail(allocator, &check, "sqlite home", sqlite_home);
    try addRuntimeDbDetail(allocator, &check, "state DB", try runtimeDbPath(allocator, sqlite_home, memory_reset.state_db_filename));
    try addRuntimeDbDetail(allocator, &check, "log DB", try runtimeDbPath(allocator, sqlite_home, memory_reset.logs_db_filename));
    try addRuntimeDbDetail(allocator, &check, "goals DB", try resolveGoalsDbPath(allocator, sqlite_home));
    try addRolloutStatsDetails(allocator, &check, home);
    return check;
}

fn doctorLogDir(allocator: std.mem.Allocator, cfg_load: ConfigLoad, codex_home: []const u8) ![]const u8 {
    if (cfg_load.cfg) |cfg| if (cfg.log_dir) |path| return path;
    return std.fs.path.join(allocator, &.{ codex_home, "log" });
}

fn doctorSqliteHome(allocator: std.mem.Allocator, cfg_load: ConfigLoad, codex_home: []const u8) ![]const u8 {
    if (cfg_load.cfg) |cfg| if (cfg.sqlite_home) |path| return path;
    return config.resolveSqliteHomeEnvOrDefault(allocator, codex_home);
}

fn runtimeDbPath(allocator: std.mem.Allocator, sqlite_home: []const u8, filename: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ sqlite_home, filename });
}

fn addStatePathDetail(allocator: std.mem.Allocator, check: *Check, key: []const u8, path: []const u8) !void {
    const inspection = try inspectPath(allocator, path);
    try recordStatePathInspection(allocator, check, key, inspection);
}

fn addRuntimeDbDetail(allocator: std.mem.Allocator, check: *Check, label: []const u8, path: []const u8) !void {
    const inspection = try inspectPath(allocator, path);
    try recordStatePathInspection(allocator, check, label, inspection);

    const integrity_key = try std.fmt.allocPrint(allocator, "{s} integrity", .{label});
    if (inspection.health != .ok) {
        try check.addDetail(allocator, integrity_key, switch (inspection.health) {
            .missing => "skipped (missing)",
            .inaccessible => "skipped (inaccessible)",
            .ok => unreachable,
        });
        return;
    }
    if (!pathIsRegularFile(path)) {
        try check.addDetail(allocator, integrity_key, "skipped (missing)");
        return;
    }

    const integrity = sqliteIntegritySummary(allocator, path) catch |err| {
        check.status = .fail;
        check.summary = "state database integrity check failed";
        try check.addDetailFmt(allocator, integrity_key, "{s}", .{@errorName(err)});
        check.remediation = "Back up CODEX_HOME, then remove or repair the affected SQLite database.";
        try check.addIssue(allocator, .{
            .severity = .fail,
            .cause = try std.fmt.allocPrint(allocator, "{s} integrity check failed", .{label}),
            .measured = @errorName(err),
            .expected = "SQLite integrity_check returns ok",
            .remedy = "Back up CODEX_HOME, then remove or repair the affected SQLite database.",
            .fields = try allocator.dupe([]const u8, &.{integrity_key}),
        });
        return;
    };
    try check.addDetail(allocator, integrity_key, integrity);
    if (!std.mem.eql(u8, integrity, "ok")) {
        check.status = .fail;
        check.summary = "state database integrity check failed";
        check.remediation = "Back up CODEX_HOME, then remove or repair the affected SQLite database.";
        try check.addIssue(allocator, .{
            .severity = .fail,
            .cause = try std.fmt.allocPrint(allocator, "{s} integrity check failed", .{label}),
            .measured = integrity,
            .expected = "SQLite integrity_check returns ok",
            .remedy = "Back up CODEX_HOME, then remove or repair the affected SQLite database.",
            .fields = try allocator.dupe([]const u8, &.{integrity_key}),
        });
    }
}

fn pathIsRegularFile(path: []const u8) bool {
    const metadata = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return metadata.kind == .file;
}

fn sqliteIntegritySummary(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const db = try sqlite.openReadOnly(allocator, path);
    defer sqlite.close(db);

    const statement = try sqlite.prepare(allocator, db, "PRAGMA integrity_check");
    defer sqlite.finalize(statement);

    var rows = std.ArrayList([]const u8).empty;
    defer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    while (true) {
        switch (sqlite.step(statement)) {
            sqlite.SQLITE_ROW => try rows.append(allocator, try sqlite.columnTextOwned(allocator, statement, 0)),
            sqlite.SQLITE_DONE => break,
            else => return error.SqliteIntegrityCheckFailed,
        }
    }

    if (rows.items.len == 1 and std.mem.eql(u8, rows.items[0], "ok")) return allocator.dupe(u8, "ok");
    return joinOrNone(allocator, rows.items);
}

fn resolveGoalsDbPath(allocator: std.mem.Allocator, sqlite_home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ sqlite_home, "goals_1.sqlite" });
}

fn addRolloutStatsDetails(allocator: std.mem.Allocator, check: *Check, codex_home: []const u8) !void {
    const active_root = try std.fs.path.join(allocator, &.{ codex_home, "sessions" });
    const archived_root = try std.fs.path.join(allocator, &.{ codex_home, "archived_sessions" });
    try addRolloutStatsDetail(allocator, check, "active rollout files", active_root);
    try addRolloutStatsDetail(allocator, check, "archived rollout files", archived_root);
}

fn addRolloutStatsDetail(allocator: std.mem.Allocator, check: *Check, label: []const u8, root: []const u8) !void {
    const stats = collectRolloutStats(allocator, root);
    if (stats.error_name) |err| {
        try check.addDetailFmt(allocator, label, "scan failed ({s})", .{err});
        check.status = .fail;
        check.summary = "state paths are not inspectable";
        check.remediation = "Fix CODEX_HOME permissions or repair the affected state path.";
        const cause = try std.fmt.allocPrint(allocator, "{s} could not be scanned", .{label});
        try check.addIssue(allocator, .{
            .severity = .fail,
            .cause = cause,
            .measured = err,
            .expected = "readable rollout session tree",
            .remedy = "Fix CODEX_HOME permissions or repair the affected state path.",
            .fields = try allocator.dupe([]const u8, &.{label}),
        });
    } else {
        try check.addDetailFmt(allocator, label, "{d} files, {d} total bytes, {d} average bytes", .{
            stats.files,
            stats.total_bytes,
            stats.averageBytes(),
        });
    }
}

fn collectRolloutStats(allocator: std.mem.Allocator, root: []const u8) RolloutStats {
    var stats = RolloutStats{};
    collectRolloutStatsInner(allocator, root, &stats);
    return stats;
}

fn collectRolloutStatsInner(allocator: std.mem.Allocator, path: []const u8, stats: *RolloutStats) void {
    if (stats.error_name != null) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            stats.error_name = @errorName(err);
            return;
        },
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| {
        stats.error_name = @errorName(err);
        return;
    }) |entry| {
        const child = std.fs.path.join(allocator, &.{ path, entry.name }) catch |err| {
            stats.error_name = @errorName(err);
            return;
        };
        defer allocator.free(child);
        const stat = dir.statFile(io, entry.name, .{}) catch |err| {
            stats.error_name = @errorName(err);
            return;
        };
        switch (stat.kind) {
            .directory => collectRolloutStatsInner(allocator, child, stats),
            .file => if (isRolloutFileName(entry.name)) {
                stats.files += 1;
                stats.total_bytes +|= stat.size;
            },
            else => {},
        }
    }
}

fn isRolloutFileName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "rollout-") and std.mem.endsWith(u8, name, ".jsonl");
}

fn recordStatePathInspection(allocator: std.mem.Allocator, check: *Check, key: []const u8, inspection: PathInspection) !void {
    try check.addDetail(allocator, key, inspection.rendered);
    if (inspection.health != .inaccessible) return;

    check.status = .fail;
    check.summary = "state paths are not inspectable";
    const cause = try std.fmt.allocPrint(allocator, "{s} is not readable", .{key});
    try check.addIssue(allocator, .{
        .severity = .fail,
        .cause = cause,
        .measured = inspection.error_name,
        .expected = "readable state path",
        .remedy = "Fix CODEX_HOME permissions or repair the affected state path.",
        .fields = try allocator.dupe([]const u8, &.{key}),
    });
    check.remediation = "Fix CODEX_HOME permissions or repair the affected state path.";
}

fn overallStatus(checks: []const Check) Status {
    var has_warning = false;
    for (checks) |check| {
        if (check.status == .fail) return .fail;
        if (check.status == .warning) has_warning = true;
    }
    return if (has_warning) .warning else .ok;
}

fn renderJsonReport(allocator: std.mem.Allocator, report: Report) ![]const u8 {
    var root: std.json.ObjectMap = .{};
    try root.put(allocator, "schemaVersion", .{ .integer = report.schema_version });
    try putString(allocator, &root, "generatedAt", report.generated_at);
    try putString(allocator, &root, "overallStatus", report.overall_status.label());
    try putString(allocator, &root, "codexVersion", report.codex_version);

    var checks_object: std.json.ObjectMap = .{};
    for (report.checks) |check| {
        try checks_object.put(allocator, try allocator.dupe(u8, check.id), .{ .object = try checkJsonObject(allocator, check) });
    }
    try root.put(allocator, "checks", .{ .object = checks_object });

    const rendered = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    return try std.fmt.allocPrint(allocator, "{s}\n", .{rendered});
}

fn checkJsonObject(allocator: std.mem.Allocator, check: Check) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .{};
    try putString(allocator, &object, "id", check.id);
    try putString(allocator, &object, "category", check.category);
    try putString(allocator, &object, "status", check.status.label());
    try putString(allocator, &object, "summary", check.summary);

    var details: std.json.ObjectMap = .{};
    for (check.details.items) |detail| {
        try putRedactedString(allocator, &details, detail.key, detail.value);
    }
    try object.put(allocator, "details", .{ .object = details });

    if (check.issues.items.len > 0) {
        var issues = std.json.Array.init(allocator);
        for (check.issues.items) |issue| {
            try issues.append(try issueJsonValue(allocator, issue));
        }
        try object.put(allocator, "issues", .{ .array = issues });
    }

    try putOptionalRedactedString(allocator, &object, "remediation", check.remediation);
    try object.put(allocator, "durationMs", .{ .integer = @intCast(check.duration_ms) });
    return object;
}

fn issueJsonValue(allocator: std.mem.Allocator, issue: Issue) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try putString(allocator, &object, "severity", issue.severity.label());
    try putRedactedString(allocator, &object, "cause", issue.cause);
    try putOptionalRedactedString(allocator, &object, "measured", issue.measured);
    try putOptionalRedactedString(allocator, &object, "expected", issue.expected);
    try putOptionalRedactedString(allocator, &object, "remedy", issue.remedy);
    var fields = std.json.Array.init(allocator);
    for (issue.fields) |field| {
        try fields.append(.{ .string = try allocator.dupe(u8, field) });
    }
    try object.put(allocator, "fields", .{ .array = fields });
    return .{ .object = object };
}

fn renderHumanReport(allocator: std.mem.Allocator, report: Report, args: ParsedArgs) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(allocator, "Codex Doctor v{s}", .{report.codex_version});
    if (detailValue(report, "runtime", "platform")) |platform| {
        try out.print(allocator, " - {s}", .{platform});
    }
    try out.appendSlice(allocator, "\n\n");

    const groups = [_]struct {
        title: []const u8,
        keys: []const []const u8,
    }{
        .{ .title = "Environment", .keys = &.{ "runtime", "install", "search", "terminal", "state" } },
        .{ .title = "Configuration", .keys = &.{ "config", "auth", "mcp", "sandbox" } },
        .{ .title = "Updates", .keys = &.{"updates"} },
        .{ .title = "Connectivity", .keys = &.{ "network", "websocket", "reachability" } },
        .{ .title = "Background Server", .keys = &.{"app-server"} },
    };

    var wrote_group = false;
    for (groups) |group| {
        if (!groupHasChecks(report, group.keys)) continue;
        if (wrote_group) try out.append(allocator, '\n');
        wrote_group = true;
        try out.print(allocator, "{s}\n", .{group.title});
        for (group.keys) |key| {
            for (report.checks) |check| {
                if (!std.mem.eql(u8, check.category, key)) continue;
                try out.print(allocator, "  {s} {s:<12} {s}\n", .{ check.status.marker(), check.category, check.summary });
                if (!args.summary) {
                    for (check.details.items) |detail| {
                        try out.print(allocator, "       {s:<24} {s}\n", .{ detail.key, detail.value });
                    }
                    if (check.remediation) |remediation| {
                        try out.print(allocator, "       remedy                   {s}\n", .{remediation});
                    }
                }
            }
        }
    }

    const counts = statusCounts(report.checks);
    const separator = if (args.ascii) "-------------------------------------------------------------" else "-------------------------------------------------------------";
    try out.print(allocator, "\n{s}\n", .{separator});
    try out.print(
        allocator,
        "{d} ok | {d} warn | {d} fail {s}\n\n",
        .{ counts.ok, counts.warning, counts.fail, overallHumanLabel(report.overall_status) },
    );
    if (args.summary) {
        try out.appendSlice(allocator, "Run codex doctor without --summary for detailed diagnostics.\n--all expand truncated lists  --json redacted report\n");
    } else {
        try out.appendSlice(allocator, "--summary compact output  --all expand truncated lists\n--json redacted report\n");
    }
    return out.toOwnedSlice(allocator);
}

fn groupHasChecks(report: Report, keys: []const []const u8) bool {
    for (keys) |key| {
        for (report.checks) |check| {
            if (std.mem.eql(u8, check.category, key)) return true;
        }
    }
    return false;
}

fn detailValue(report: Report, category: []const u8, key: []const u8) ?[]const u8 {
    for (report.checks) |check| {
        if (!std.mem.eql(u8, check.category, category)) continue;
        for (check.details.items) |detail| {
            if (std.mem.eql(u8, detail.key, key)) return detail.value;
        }
    }
    return null;
}

fn statusCounts(checks: []const Check) StatusCounts {
    var counts = StatusCounts{
        .ok = 0,
        .warning = 0,
        .fail = 0,
    };
    for (checks) |check| {
        switch (check.status) {
            .ok => counts.ok += 1,
            .warning => counts.warning += 1,
            .fail => counts.fail += 1,
        }
    }
    return counts;
}

fn overallHumanLabel(status: Status) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warning => "degraded",
        .fail => "failed",
    };
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putOptionalString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try putString(allocator, object, key, text);
    } else {
        try object.put(allocator, key, .null);
    }
}

fn putRedactedString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putString(allocator, object, key, try redactJsonText(allocator, value));
}

fn putOptionalRedactedString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try putRedactedString(allocator, object, key, text);
    } else {
        try object.put(allocator, key, .null);
    }
}

fn redactJsonText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var index: usize = 0;
    while (index < text.len) {
        if ((text[index] == '/' and isLocalPathStart(text, index)) or isWindowsPathStart(text, index)) {
            try out.appendSlice(allocator, "<redacted-path>");
            index = localPathEnd(text, index);
            continue;
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isLocalPathStart(text: []const u8, index: usize) bool {
    if (index > 0) {
        const previous = text[index - 1];
        if (!isPathBoundary(previous) or previous == '/') return false;
    }
    return index + 1 < text.len and !isPathTerminator(text[index + 1]);
}

fn isWindowsPathStart(text: []const u8, index: usize) bool {
    if (index > 0 and !isPathBoundary(text[index - 1])) return false;
    if (index + 2 < text.len and std.ascii.isAlphabetic(text[index]) and text[index + 1] == ':' and isWindowsSeparator(text[index + 2])) {
        return true;
    }
    if (index + 2 < text.len and isWindowsSeparator(text[index]) and isWindowsSeparator(text[index + 1]) and !isPathTerminator(text[index + 2])) {
        return true;
    }
    return false;
}

fn isWindowsSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn isPathBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '=' or byte == '(' or byte == '[' or byte == '{' or byte == '"' or byte == '\'';
}

fn localPathEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (isPathTerminator(text[index])) return index;
        if (isPathStatusSuffixStart(text, index)) return index;
    }
    return index;
}

fn isPathTerminator(byte: u8) bool {
    return byte == '"' or byte == '\'' or byte == ',' or byte == ';';
}

fn isPathStatusSuffixStart(text: []const u8, index: usize) bool {
    return std.ascii.isWhitespace(text[index]) and
        index + 1 < text.len and
        text[index + 1] == '(';
}

fn envPresent(allocator: std.mem.Allocator, comptime name: []const u8) !bool {
    const value = try env.getOwned(allocator, name);
    return if (value) |text| text.len > 0 else false;
}

fn envPresentDynamicTrimmed(allocator: std.mem.Allocator, name: []const u8) !bool {
    const value = try env.getOwnedDynamic(allocator, name);
    return if (value) |text| std.mem.trim(u8, text, " \t\r\n").len > 0 else false;
}

fn joinOrNone(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    if (values.len == 0) return allocator.dupe(u8, "none");
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn boolString(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn credentialsUsable(credentials: auth.Credentials) bool {
    return switch (credentials.mode) {
        .chatgpt,
        .chatgpt_auth_tokens,
        .agent_identity,
        .api_key,
        => std.mem.trim(u8, credentials.token, " \t\r\n").len > 0,
        .local_oss,
        .provider_no_auth,
        => true,
    };
}

fn runtimeEnvAuthSource(access_token: bool, openai_api_key: bool) ?[]const u8 {
    if (access_token) return "CODEX_ACCESS_TOKEN";
    if (openai_api_key) return "OPENAI_API_KEY";
    return null;
}

fn inspectPath(allocator: std.mem.Allocator, path: []const u8) !PathInspection {
    const io = std.Io.Threaded.global_single_threaded.io();
    const metadata = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .rendered = try std.fmt.allocPrint(allocator, "{s} (missing)", .{path}),
            .health = .missing,
        },
        else => return .{
            .rendered = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ path, @errorName(err) }),
            .health = .inaccessible,
            .error_name = @errorName(err),
        },
    };

    return .{
        .rendered = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ path, if (metadata.kind == .directory) "dir" else "file" }),
        .health = .ok,
    };
}

fn runCommandProbe(allocator: std.mem.Allocator, argv: []const []const u8) !CommandProbe {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();

    const result = try std.process.run(allocator, io_instance.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(5_000),
            .clock = .awake,
        } },
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn resolveCommandOnPath(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return try allocator.dupe(u8, command);
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, command, '\\') != null) return try allocator.dupe(u8, command);

    const path_env = try env.getOwned(allocator, "PATH") orelse return error.PathNotSet;
    defer allocator.free(path_env);
    var parts = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    const io = std.Io.Threaded.global_single_threaded.io();
    while (parts.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (try resolveCommandInDir(allocator, io, dir, command)) |candidate| return candidate;
    }
    return error.FileNotFound;
}

fn resolveCommandInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    command: []const u8,
) !?[]const u8 {
    if (try executableFileCandidate(allocator, io, dir, command)) |candidate| return candidate;
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, command, '.') == null) {
        inline for (&.{ ".exe", ".cmd", ".bat", ".com" }) |extension| {
            const with_extension = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, extension });
            defer allocator.free(with_extension);
            if (try executableFileCandidate(allocator, io, dir, with_extension)) |candidate| return candidate;
        }
    }
    return null;
}

fn executableFileCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    command: []const u8,
) !?[]const u8 {
    const candidate = try std.fs.path.join(allocator, &.{ dir, command });
    const metadata = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileNotFound, error.NotDir => {
            allocator.free(candidate);
            return null;
        },
        else => return err,
    };
    if (metadata.kind != .file) {
        allocator.free(candidate);
        return null;
    }
    std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileNotFound => {
            allocator.free(candidate);
            return null;
        },
        else => return err,
    };
    return candidate;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[start..end], " \t\r");
        if (line.len > 0) return line;
        start = if (end < text.len) end + 1 else text.len;
    }
    return null;
}

fn childTermLabel(allocator: std.mem.Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(allocator, "status {d}", .{code}),
        .signal => |signal| std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(signal)}),
        .unknown => |code| std.fmt.allocPrint(allocator, "unknown {d}", .{code}),
    };
}

fn recordCustomCaEnvPath(allocator: std.mem.Allocator, check: *Check, name: []const u8, path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const metadata = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        check.status = .warning;
        check.summary = "custom CA env var points at an unreadable path";
        try check.addDetailFmt(allocator, name, "{s} ({s})", .{ path, @errorName(err) });
        check.remediation = "Fix custom CA certificate paths or unset the affected environment variable.";
        return;
    };

    if (metadata.kind != .file) {
        check.status = .warning;
        check.summary = "custom CA env var does not point at a file";
        try check.addDetailFmt(allocator, name, "not a file {s}", .{path});
        check.remediation = "Set the custom CA environment variable to a readable certificate file.";
        return;
    }

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        check.status = .warning;
        check.summary = "custom CA env var points at an unreadable file";
        try check.addDetailFmt(allocator, name, "{s} ({s})", .{ path, @errorName(err) });
        check.remediation = "Fix custom CA certificate file permissions or unset the affected environment variable.";
        return;
    };
    defer file.close(io);
    try check.addDetailFmt(allocator, name, "readable file {s}", .{path});
}

fn appServerRuntimeStatus(
    control_socket: []const u8,
    socket_health: PathHealth,
) !AppServerRuntimeStatus {
    return switch (socket_health) {
        .missing => .{
            .status = .ok,
            .summary = "background server is not running",
            .detail = "not running",
        },
        .inaccessible => .{
            .status = .fail,
            .summary = "background server paths are not inspectable",
            .detail = "unknown (control socket inaccessible)",
            .remediation = "Fix CODEX_HOME permissions or repair the affected app-server path.",
        },
        .ok => if (unixSocketConnects(control_socket)) |connects| blk: {
            if (connects) break :blk .{
                .status = .ok,
                .summary = "background server is running",
                .detail = "running",
            };
            break :blk .{
                .status = .warning,
                .summary = "background server socket is stale or unreachable",
                .detail = "stale or unreachable",
                .remediation = "Run `codex app-server daemon version` for more details.",
            };
        } else .{
            .status = .ok,
            .summary = "background server status is locally inspectable",
            .detail = "control socket present",
        },
    };
}

fn unixSocketConnects(socket_path: []const u8) ?bool {
    if (builtin.os.tag == .windows) return null;

    const Sockaddr = extern union {
        any: std.posix.sockaddr,
        un: std.posix.sockaddr.un,
    };

    const fd = while (true) {
        const rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(std.posix.fd_t, @intCast(rc)),
            .INTR => continue,
            else => return null,
        }
    };
    defer _ = std.c.close(fd);

    var storage = std.mem.zeroes(Sockaddr);
    if (socket_path.len >= storage.un.path.len) return false;
    storage.un.family = std.posix.AF.UNIX;
    @memcpy(storage.un.path[0..socket_path.len], socket_path);
    storage.un.path[socket_path.len] = 0;
    const address_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + socket_path.len + 1);

    while (true) {
        switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, address_len))) {
            .SUCCESS => return true,
            .INTR => continue,
            .ACCES, .PERM => return false,
            else => return false,
        }
    }
}

fn currentUnixSeconds() i64 {
    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real);
    return @intCast(now.toSeconds());
}

test "doctor parses Rust command flags" {
    const allocator = std.testing.allocator;
    var parsed = try parseArgs(allocator, &.{
        "--json",
        "--summary",
        "--all",
        "--no-color",
        "--ascii",
        "-c",
        "model=gpt-test",
        "--enable",
        "goals",
        "--disable=memories",
    }, .{});
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.summary);
    try std.testing.expect(parsed.all);
    try std.testing.expect(parsed.no_color);
    try std.testing.expect(parsed.ascii);
    try std.testing.expectEqualStrings("gpt-test", parsed.runtime_overrides.model.?);
    try std.testing.expectEqual(true, parsed.feature_overrides.get("goals").?);
    try std.testing.expectEqual(false, parsed.feature_overrides.get("memories").?);
}

test "doctor JSON report uses Rust-shaped top-level fields and checks map" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var check = Check.init("runtime.provenance", "runtime", .ok, "running Zig port");
    try check.addDetail(scratch, "platform", "macos-aarch64");
    const checks = try scratch.dupe(Check, &.{check});
    const report = Report{
        .generated_at = "1s since unix epoch",
        .overall_status = .ok,
        .codex_version = "0.0.1",
        .checks = checks,
    };

    const rendered = try renderJsonReport(scratch, report);
    const parsed = try std.json.parseFromSlice(std.json.Value, scratch, rendered, .{});
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings("ok", root.get("overallStatus").?.string);
    try std.testing.expect(root.get("checks").?.object.get("runtime.provenance") != null);
}

test "doctor human summary hides detail rows" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var check = Check.init("runtime.provenance", "runtime", .ok, "running Zig port");
    try check.addDetail(scratch, "platform", "macos-aarch64");
    const checks = try scratch.dupe(Check, &.{check});
    const report = Report{
        .generated_at = "1s since unix epoch",
        .overall_status = .ok,
        .codex_version = "0.0.1",
        .checks = checks,
    };

    const rendered = try renderHumanReport(scratch, report, .{ .summary = true });
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Codex Doctor v0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "platform") == null);
}

test "doctor JSON redacts local paths" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var check = Check.init("state.paths", "state", .fail, "state paths are inspectable");
    try check.addDetail(scratch, "CODEX_HOME", "/Users/alice/.codex (dir)");
    try check.addDetail(scratch, "space home", "/tmp/codex doctor space/state_5.sqlite (file)");
    try check.addDetail(scratch, "windows home", "C:\\Users\\alice\\.codex");
    try check.addDetail(scratch, "unc home", "\\\\server\\share\\alice\\.codex");
    try check.addDetail(scratch, "update action", "npm install -g @openai/codex");
    try check.addIssue(scratch, .{
        .severity = .fail,
        .cause = "failed to read /Users/alice/.codex/state_5.sqlite",
        .measured = "/Users/alice/.codex/state_5.sqlite",
        .expected = "/Users/alice/.codex",
        .remedy = "Fix /Users/alice/.codex permissions.",
    });
    check.remediation = "Inspect /Users/alice/.codex.";
    const checks = try scratch.dupe(Check, &.{check});
    const report = Report{
        .generated_at = "1s since unix epoch",
        .overall_status = .fail,
        .codex_version = "0.0.1",
        .checks = checks,
    };

    const rendered = try renderJsonReport(scratch, report);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/Users/alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "codex doctor space") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "C:\\\\Users\\\\alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\\\\\\\\server\\\\share\\\\alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<redacted-path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "@openai/codex") != null);
}

test "doctor auth source matches runtime env priority" {
    try std.testing.expectEqualStrings("CODEX_ACCESS_TOKEN", runtimeEnvAuthSource(true, true).?);
    try std.testing.expectEqualStrings("CODEX_ACCESS_TOKEN", runtimeEnvAuthSource(true, false).?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", runtimeEnvAuthSource(false, true).?);
    try std.testing.expect(runtimeEnvAuthSource(false, false) == null);
}

test "doctor state path access errors fail the state check" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var check = Check.init("state.paths", "state", .ok, "state paths are inspectable");
    try addStatePathDetail(scratch, &check, "sessions dir", "/definitely-missing-codex-zig-doctor-test-path");
    try std.testing.expectEqual(Status.ok, check.status);

    try recordStatePathInspection(scratch, &check, "log dir", .{
        .rendered = "/Users/alice/.codex/log (AccessDenied)",
        .health = .inaccessible,
        .error_name = "AccessDenied",
    });

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("state paths are not inspectable", check.summary);
    try std.testing.expect(check.issues.items.len == 1);
}

test "doctor runtime DB integrity errors fail state check" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.writeFile(io, .{
        .sub_path = "state_5.sqlite",
        .data = "not a sqlite database",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const state_path = try std.fs.path.join(scratch, &.{ root, "state_5.sqlite" });

    var check = Check.init("state.paths", "state", .ok, "state paths and databases are inspectable");
    try addRuntimeDbDetail(scratch, &check, "state DB", state_path);

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("state database integrity check failed", check.summary);
    try std.testing.expect(check.issues.items.len == 1);
    var found_integrity = false;
    for (check.details.items) |detail| {
        if (std.mem.eql(u8, detail.key, "state DB integrity")) found_integrity = true;
    }
    try std.testing.expect(found_integrity);
}

test "doctor state check probes configured sqlite home" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "codex-home/log");
    try dir.dir.createDirPath(io, "sqlite-home");
    try dir.dir.writeFile(io, .{
        .sub_path = "sqlite-home/state_5.sqlite",
        .data = "not a sqlite database",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_home = try std.fs.path.join(scratch, &.{ root, "codex-home" });
    const log_dir = try std.fs.path.join(scratch, &.{ codex_home, "log" });
    const sqlite_home = try std.fs.path.join(scratch, &.{ root, "sqlite-home" });

    const cfg = config.Config{
        .codex_home = codex_home,
        .log_dir = log_dir,
        .sqlite_home = sqlite_home,
        .active_profile = null,
        .model = "gpt-test",
        .openai_base_url = "https://api.openai.com/v1",
        .chatgpt_base_url = "https://chatgpt.com",
        .oss_provider = null,
        .installation_id = "test-installation",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
    };

    const check = try stateCheck(scratch, .{
        .cfg = cfg,
        .codex_home = codex_home,
        .cwd = root,
    });

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("state database integrity check failed", check.summary);
    var found_sqlite_home = false;
    var found_configured_state_db = false;
    for (check.details.items) |detail| {
        if (std.mem.eql(u8, detail.key, "sqlite home") and std.mem.indexOf(u8, detail.value, "sqlite-home") != null) {
            found_sqlite_home = true;
        }
        if (std.mem.eql(u8, detail.key, "state DB") and std.mem.indexOf(u8, detail.value, "sqlite-home/state_5.sqlite") != null) {
            found_configured_state_db = true;
        }
    }
    try std.testing.expect(found_sqlite_home);
    try std.testing.expect(found_configured_state_db);
}

test "doctor rollout stats count nested rollout files" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "sessions/2026/05/24");
    try dir.dir.writeFile(io, .{
        .sub_path = "sessions/2026/05/24/rollout-one.jsonl",
        .data = "abc",
    });
    try dir.dir.writeFile(io, .{
        .sub_path = "sessions/2026/05/24/not-rollout.jsonl",
        .data = "ignored",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try std.fs.path.join(scratch, &.{ root, "sessions" });

    const stats = collectRolloutStats(scratch, sessions_root);
    try std.testing.expect(stats.error_name == null);
    try std.testing.expectEqual(@as(u64, 1), stats.files);
    try std.testing.expectEqual(@as(u64, 3), stats.total_bytes);
    try std.testing.expectEqual(@as(u64, 3), stats.averageBytes());
}

test "doctor rollout stats non-directory root fails state check" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.writeFile(io, .{
        .sub_path = "sessions",
        .data = "not a directory",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try std.fs.path.join(scratch, &.{ root, "sessions" });

    var check = Check.init("state.paths", "state", .ok, "state paths and databases are inspectable");
    try addRolloutStatsDetail(scratch, &check, "active rollout files", sessions_root);

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("state paths are not inspectable", check.summary);
    try std.testing.expect(check.issues.items.len == 1);
}

test "doctor rollout stats scan errors fail state check" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.createDirPath(io, "sessions/blocked");
    try dir.dir.setFilePermissions(io, "sessions/blocked", std.Io.File.Permissions.fromMode(0o111), .{});
    defer dir.dir.setFilePermissions(io, "sessions/blocked", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try std.fs.path.join(scratch, &.{ root, "sessions" });

    var check = Check.init("state.paths", "state", .ok, "state paths and databases are inspectable");
    try addRolloutStatsDetail(scratch, &check, "active rollout files", sessions_root);

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("state paths are not inspectable", check.summary);
    try std.testing.expect(check.issues.items.len == 1);
}

test "doctor app-server access errors fail the app-server check" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var check = Check.init("app_server.status", "app-server", .ok, "background server status is locally inspectable");
    try recordAppServerPathInspection(scratch, &check, "control socket", .{
        .rendered = "/Users/alice/.codex/app-server-control/app-server-control.sock (AccessDenied)",
        .health = .inaccessible,
        .error_name = "AccessDenied",
    });

    try std.testing.expectEqual(Status.fail, check.status);
    try std.testing.expectEqualStrings("background server paths are not inspectable", check.summary);
    try std.testing.expect(check.issues.items.len == 1);
    try std.testing.expectEqualStrings("Fix CODEX_HOME permissions or repair the affected app-server path.", check.remediation.?);
}

test "doctor app-server status includes daemon metadata" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const check = try appServerCheck(scratch, .{
        .codex_home = root,
        .cwd = root,
    });

    try std.testing.expectEqual(Status.ok, check.status);
    try std.testing.expectEqualStrings("background server is not running", check.summary);

    var found_mode = false;
    var found_pid_file = false;
    var found_settings = false;
    var found_updater_pid = false;
    for (check.details.items) |detail| {
        if (std.mem.eql(u8, detail.key, "mode") and std.mem.eql(u8, detail.value, "ephemeral")) found_mode = true;
        if (std.mem.eql(u8, detail.key, "pid file") and std.mem.indexOf(u8, detail.value, "app-server.pid") != null) found_pid_file = true;
        if (std.mem.eql(u8, detail.key, "settings") and std.mem.indexOf(u8, detail.value, "settings.json") != null) found_settings = true;
        if (std.mem.eql(u8, detail.key, "update-loop pid file") and std.mem.indexOf(u8, detail.value, "app-server-updater.pid") != null) found_updater_pid = true;
    }
    try std.testing.expect(found_mode);
    try std.testing.expect(found_pid_file);
    try std.testing.expect(found_settings);
    try std.testing.expect(found_updater_pid);
}

test "doctor app-server runtime status distinguishes missing and stale sockets" {
    const missing = try appServerRuntimeStatus("/definitely-missing-codex-zig-doctor.sock", .missing);
    try std.testing.expectEqual(Status.ok, missing.status);
    try std.testing.expectEqualStrings("background server is not running", missing.summary);
    try std.testing.expectEqualStrings("not running", missing.detail);

    const stale = try appServerRuntimeStatus("/definitely-missing-codex-zig-doctor.sock", .ok);
    try std.testing.expectEqual(Status.warning, stale.status);
    try std.testing.expectEqualStrings("background server socket is stale or unreachable", stale.summary);
    try std.testing.expectEqualStrings("stale or unreachable", stale.detail);
    try std.testing.expect(stale.remediation != null);
}

test "doctor network check warns for invalid custom CA paths" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var check = Check.init("network.env", "network", .ok, "network-related environment looks readable");
    try recordCustomCaEnvPath(scratch, &check, "SSL_CERT_FILE", root);

    try std.testing.expectEqual(Status.warning, check.status);
    try std.testing.expectEqualStrings("custom CA env var does not point at a file", check.summary);
    var found = false;
    for (check.details.items) |detail| {
        if (std.mem.eql(u8, detail.key, "SSL_CERT_FILE") and std.mem.indexOf(u8, detail.value, "not a file") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "doctor auth check uses active ephemeral credentials" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try auth.saveApiKeyAuth(allocator, root, .ephemeral, "test-ephemeral-key");
    defer {
        _ = auth.logoutWithRevokeWithMode(allocator, root, .ephemeral) catch false;
    }

    const cfg = config.Config{
        .codex_home = root,
        .active_profile = null,
        .model = "gpt-test",
        .openai_base_url = "https://api.openai.com/v1",
        .chatgpt_base_url = "https://chatgpt.com",
        .oss_provider = null,
        .installation_id = "test-installation",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
        .cli_auth_credentials_store_mode = .file,
    };

    const check = try authCheck(scratch, .{
        .cfg = cfg,
        .codex_home = root,
        .cwd = root,
    });

    try std.testing.expectEqual(Status.ok, check.status);
    try std.testing.expectEqualStrings("auth is configured", check.summary);
    try std.testing.expect(check.details.items.len > 0);
    var found_source = false;
    for (check.details.items) |detail| {
        if (std.mem.eql(u8, detail.key, "auth source") and std.mem.eql(u8, detail.value, "API key")) {
            found_source = true;
        }
    }
    try std.testing.expect(found_source);
}

test "doctor flags blank stored credentials" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try dir.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"\"}",
    });
    const root = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const cfg = config.Config{
        .codex_home = root,
        .active_profile = null,
        .model = "gpt-test",
        .openai_base_url = "https://api.openai.com/v1",
        .chatgpt_base_url = "https://chatgpt.com",
        .oss_provider = null,
        .installation_id = "test-installation",
        .approval_policy = .on_request,
        .sandbox_mode = .workspace_write,
        .web_search_mode = null,
        .model_reasoning_effort = null,
        .service_tier = null,
        .syntax_theme = null,
        .personality = null,
        .tui_status_line = null,
        .tui_terminal_title = null,
        .tui_alternate_screen = .auto,
        .cli_auth_credentials_store_mode = .file,
    };

    const check = try authCheck(scratch, .{
        .cfg = cfg,
        .codex_home = root,
        .cwd = root,
    });

    try std.testing.expect(check.status != .ok);
    try std.testing.expect(
        std.mem.eql(u8, check.summary, "stored credentials are incomplete") or
            std.mem.eql(u8, check.summary, "auth is provided by environment, but stored credentials are incomplete"),
    );
    var found_issue = false;
    for (check.issues.items) |issue| {
        if (std.mem.eql(u8, issue.cause, "stored credentials are missing usable token material")) {
            found_issue = true;
        }
    }
    try std.testing.expect(found_issue);
}
