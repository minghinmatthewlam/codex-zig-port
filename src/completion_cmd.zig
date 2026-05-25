const std = @import("std");

const cli_utils = @import("cli_utils.zig");

const top_level_commands =
    "a app app-server apply auth-status cloud cloud-tasks completion debug doctor e exec exec-server execpolicy features fork help login logout mcp mcp-server plugin remote-control remote-fork review resume sandbox sessions update";
const global_options =
    "--help -h --version -V --profile -p --profile-v2 --cd -C --add-dir --config -c --strict-config --model -m --image -i --enable --disable --oss --local-provider --ask-for-approval -a --approval-policy --sandbox -s --dangerously-bypass-approvals-and-sandbox --yolo --dangerously-bypass-hook-trust --search --remote --remote-auth-token-env --remote-control --remote-control-bind --no-alt-screen";
const shells = "bash elvish fish powershell zsh";
const elvish_top_level_commands =
    "'a' 'app' 'app-server' 'apply' 'auth-status' 'cloud' 'cloud-tasks' 'completion' 'debug' 'doctor' 'e' 'exec' 'exec-server' 'execpolicy' 'features' 'fork' 'help' 'login' 'logout' 'mcp' 'mcp-server' 'plugin' 'remote-control' 'remote-fork' 'review' 'resume' 'sandbox' 'sessions' 'update'";
const elvish_global_options =
    "'--help' '-h' '--version' '-V' '--profile' '-p' '--profile-v2' '--cd' '-C' '--add-dir' '--config' '-c' '--strict-config' '--model' '-m' '--image' '-i' '--enable' '--disable' '--oss' '--local-provider' '--ask-for-approval' '-a' '--approval-policy' '--sandbox' '-s' '--dangerously-bypass-approvals-and-sandbox' '--yolo' '--dangerously-bypass-hook-trust' '--search' '--remote' '--remote-auth-token-env' '--remote-control' '--remote-control-bind' '--no-alt-screen'";
const elvish_shells = "'bash' 'elvish' 'fish' 'powershell' 'zsh'";

const Shell = enum {
    bash,
    elvish,
    fish,
    powershell,
    zsh,

    fn parse(value: []const u8) !Shell {
        if (std.mem.eql(u8, value, "bash")) return .bash;
        if (std.mem.eql(u8, value, "elvish")) return .elvish;
        if (std.mem.eql(u8, value, "fish")) return .fish;
        if (std.mem.eql(u8, value, "powershell")) return .powershell;
        if (std.mem.eql(u8, value, "zsh")) return .zsh;
        return error.UnknownCompletionShell;
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    if (helpPreflight(raw_args.items)) {
        printHelp();
        return;
    }

    const shell = if (raw_args.items.len > 0) try Shell.parse(raw_args.items[0]) else Shell.bash;
    if (raw_args.items.len > 1) return error.UnexpectedCompletionArgument;

    const rendered = try renderCompletion(allocator, shell);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
}

fn helpPreflight(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (isHelpFlag(args[0])) return true;
    if (Shell.parse(args[0])) |_| {
        return args.len > 1 and isHelpFlag(args[1]);
    } else |_| {
        return false;
    }
}

fn renderCompletion(allocator: std.mem.Allocator, shell: Shell) ![]const u8 {
    return switch (shell) {
        .bash => renderBash(allocator),
        .elvish => renderElvish(allocator),
        .fish => renderFish(allocator),
        .powershell => renderPowerShell(allocator),
        .zsh => renderZsh(allocator),
    };
}

fn renderBash(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# bash completion for codex-zig
        \\_codex_zig() {{
        \\    local cur prev
        \\    COMPREPLY=()
        \\    cur="${{COMP_WORDS[COMP_CWORD]}}"
        \\    prev="${{COMP_WORDS[COMP_CWORD-1]}}"
        \\    local commands="{s}"
        \\    local global_options="{s}"
        \\    case "$prev" in
        \\        completion)
        \\            COMPREPLY=( $(compgen -W "{s}" -- "$cur") )
        \\            return
        \\            ;;
        \\        --ask-for-approval|-a|--approval-policy)
        \\            COMPREPLY=( $(compgen -W "untrusted on-failure on-request never" -- "$cur") )
        \\            return
        \\            ;;
        \\        --sandbox|-s)
        \\            COMPREPLY=( $(compgen -W "read-only workspace-write danger-full-access" -- "$cur") )
        \\            return
        \\            ;;
        \\        --local-provider)
        \\            COMPREPLY=( $(compgen -W "lmstudio ollama" -- "$cur") )
        \\            return
        \\            ;;
        \\    esac
        \\    if [[ $COMP_CWORD == 1 ]]; then
        \\        COMPREPLY=( $(compgen -W "$commands $global_options" -- "$cur") )
        \\        return
        \\    fi
        \\    COMPREPLY=( $(compgen -W "$global_options" -- "$cur") )
        \\}}
        \\complete -F _codex_zig codex-zig
        \\
    , .{ top_level_commands, global_options, shells });
}

fn renderElvish(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# elvish completion for codex-zig
        \\edit:completion:arg-completer[codex-zig] = {{|@words|
        \\    var candidates = [{s} {s}]
        \\    if (> (count $words) 1) {{
        \\        if (== $words[1] completion) {{
        \\            put {s}
        \\            return
        \\        }}
        \\    }}
        \\    put $@candidates
        \\}}
        \\
    , .{ elvish_top_level_commands, elvish_global_options, elvish_shells });
}

fn renderFish(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# fish completion for codex-zig\n");
    try out.appendSlice(allocator, "complete -c codex-zig -f\n");
    try out.appendSlice(allocator, "complete -c codex-zig -n '__fish_use_subcommand' -a '");
    try out.appendSlice(allocator, top_level_commands);
    try out.appendSlice(allocator, "'\n");
    try out.appendSlice(allocator, "complete -c codex-zig -n '__fish_seen_subcommand_from completion' -a '");
    try out.appendSlice(allocator, shells);
    try out.appendSlice(allocator, "'\n");
    try appendFishOptions(allocator, &out);
    return out.toOwnedSlice(allocator);
}

fn appendFishOptions(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const lines = [_][]const u8{
        "complete -c codex-zig -s h -l help -d 'Print help'\n",
        "complete -c codex-zig -s V -l version -d 'Print version'\n",
        "complete -c codex-zig -s p -l profile -r -d 'Select config profile'\n",
        "complete -c codex-zig -l profile-v2 -r -d 'Layer profile config'\n",
        "complete -c codex-zig -s C -l cd -r -d 'Use working root'\n",
        "complete -c codex-zig -l add-dir -r -d 'Add writable root'\n",
        "complete -c codex-zig -s c -l config -r -d 'Override config key'\n",
        "complete -c codex-zig -l strict-config -d 'Error on unknown config fields'\n",
        "complete -c codex-zig -s m -l model -r -d 'Override model'\n",
        "complete -c codex-zig -s i -l image -r -d 'Attach image to first interactive prompt'\n",
        "complete -c codex-zig -l enable -r -d 'Enable feature for this invocation'\n",
        "complete -c codex-zig -l disable -r -d 'Disable feature for this invocation'\n",
        "complete -c codex-zig -l oss -d 'Use local OSS provider'\n",
        "complete -c codex-zig -l local-provider -xa 'lmstudio ollama' -d 'Select local provider'\n",
        "complete -c codex-zig -s a -l ask-for-approval -xa 'untrusted on-failure on-request never' -d 'Approval policy'\n",
        "complete -c codex-zig -l approval-policy -xa 'untrusted on-failure on-request never' -d 'Approval policy'\n",
        "complete -c codex-zig -s s -l sandbox -xa 'read-only workspace-write danger-full-access' -d 'Sandbox mode'\n",
        "complete -c codex-zig -l yolo -d 'Disable approvals and sandbox'\n",
        "complete -c codex-zig -l dangerously-bypass-hook-trust -d 'Run enabled hooks without persisted hook trust'\n",
        "complete -c codex-zig -l search -d 'Enable live web search'\n",
        "complete -c codex-zig -l remote -r -d 'Connect interactive TUI to remote app-server'\n",
        "complete -c codex-zig -l remote-auth-token-env -r -d 'Read remote app-server token from env'\n",
        "complete -c codex-zig -l remote-control -d 'Start local remote-control server'\n",
        "complete -c codex-zig -l remote-control-bind -r -d 'Bind local remote-control server'\n",
        "complete -c codex-zig -l no-alt-screen -d 'Disable alternate-screen TUI mode'\n",
    };
    for (lines) |line| try out.appendSlice(allocator, line);
}

fn renderPowerShell(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# PowerShell completion for codex-zig
        \\Register-ArgumentCompleter -Native -CommandName 'codex-zig' -ScriptBlock {{
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $commands = '{s}'.Split(' ')
        \\    $globalOptions = '{s}'.Split(' ')
        \\    $shells = '{s}'.Split(' ')
        \\    $tokens = @($commandAst.CommandElements | ForEach-Object {{ $_.ToString() }})
        \\    $values = if ($tokens.Count -ge 2 -and $tokens[1] -eq 'completion') {{ $shells }} else {{ $commands + $globalOptions }}
        \\    $values |
        \\        Where-Object {{ $_ -like "$wordToComplete*" }} |
        \\        ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}
        \\}}
        \\
    , .{ top_level_commands, global_options, shells });
}

fn renderZsh(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\#compdef codex-zig
        \\# zsh completion for codex-zig
        \\_codex_zig() {{
        \\    local -a commands global_options shells
        \\    commands=({s})
        \\    global_options=({s})
        \\    shells=({s})
        \\    if [[ $words[2] == completion ]]; then
        \\        _describe 'shell' shells
        \\        return
        \\    fi
        \\    _arguments -C \
        \\        '(-h --help)'{{-h,--help}}'[Print help]' \
        \\        '(-V --version)'{{-V,--version}}'[Print version]' \
        \\        '(-p --profile)'{{-p,--profile}}'[Select config profile]:profile:' \
        \\        '--profile-v2[Layer profile config]:profile:' \
        \\        '(-C --cd)'{{-C,--cd}}'[Use working root]:directory:_files -/' \
        \\        '--add-dir[Add writable root]:directory:_files -/' \
        \\        '(-c --config)'{{-c,--config}}'[Override config key]:key=value:' \
        \\        '--strict-config[Error on unknown config fields]' \
        \\        '(-m --model)'{{-m,--model}}'[Override model]:model:' \
        \\        '(-i --image)'{{-i,--image}}'[Attach image to first interactive prompt]:file:_files' \
        \\        '--enable[Enable feature for this invocation]:feature:' \
        \\        '--disable[Disable feature for this invocation]:feature:' \
        \\        '--oss[Use local OSS provider]' \
        \\        '--local-provider[Select local provider]:(lmstudio ollama)' \
        \\        '(-a --ask-for-approval)'{{-a,--ask-for-approval}}'[Approval policy]:(untrusted on-failure on-request never)' \
        \\        '--approval-policy[Approval policy]:(untrusted on-failure on-request never)' \
        \\        '(-s --sandbox)'{{-s,--sandbox}}'[Sandbox mode]:(read-only workspace-write danger-full-access)' \
        \\        '--yolo[Disable approvals and sandbox]' \
        \\        '--dangerously-bypass-hook-trust[Run enabled hooks without persisted hook trust]' \
        \\        '--search[Enable live web search]' \
        \\        '--remote[Connect interactive TUI to remote app-server]:addr:' \
        \\        '--remote-auth-token-env[Read remote app-server token from env]:env:' \
        \\        '--remote-control[Start local remote-control server]' \
        \\        '--remote-control-bind[Bind local remote-control server]:addr:' \
        \\        '--no-alt-screen[Disable alternate-screen TUI mode]' \
        \\        '1:command:($commands)' \
        \\        '*::arg:_files'
        \\}}
        \\_codex_zig "$@"
        \\
    , .{ top_level_commands, global_options, shells });
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  codex-zig completion [SHELL]
        \\
        \\Shells:
        \\  bash, elvish, fish, powershell, zsh
        \\
        \\If SHELL is omitted, bash is used.
        \\
    , .{});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

test "completion renders bash by default shape" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .bash);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "complete -F _codex_zig codex-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cloud-tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "execpolicy") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "remote-control") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "remote-fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--profile-v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--strict-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--remote-auth-token-env") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--remote-control-bind") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "powershell") != null);
}

test "completion renders fish command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .fish);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "complete -c codex-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-l profile-v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-l strict-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "__fish_seen_subcommand_from completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "bash elvish fish powershell zsh") != null);
}

test "completion renders zsh command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .zsh);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "#compdef codex-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--profile-v2[Layer profile config]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--strict-config[Error on unknown config fields]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shells=(bash elvish fish powershell zsh)") != null);
}

test "completion renders powershell command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .powershell);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--profile-v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--strict-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "$shells = 'bash elvish fish powershell zsh'.Split(' ')") != null);
}

test "completion renders elvish quoted command values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .elvish);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "edit:completion:arg-completer[codex-zig]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'--help'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'--profile-v2'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'--strict-config'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'doctor'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "put 'bash' 'elvish' 'fish' 'powershell' 'zsh'") != null);
}

test "completion parses supported shell names" {
    try std.testing.expectEqual(Shell.bash, try Shell.parse("bash"));
    try std.testing.expectEqual(Shell.zsh, try Shell.parse("zsh"));
    try std.testing.expectError(error.UnknownCompletionShell, Shell.parse("unknown"));
}
