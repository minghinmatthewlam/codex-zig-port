const std = @import("std");

const cli_utils = @import("cli_utils.zig");

const top_level_commands =
    "a app app-server apply auth-status cloud cloud-tasks completion debug e exec exec-server execpolicy features fork help login logout mcp mcp-server plugin remote-control review resume sandbox sessions update";
const global_options =
    "--help -h --version -V --profile -p --cd -C --add-dir --config -c --model -m --image -i --enable --disable --oss --local-provider --ask-for-approval -a --approval-policy --sandbox -s --dangerously-bypass-approvals-and-sandbox --yolo --search --remote --remote-auth-token-env --no-alt-screen";
const shells = "bash elvish fish powershell zsh";
const elvish_top_level_commands =
    "'a' 'app' 'app-server' 'apply' 'auth-status' 'cloud' 'cloud-tasks' 'completion' 'debug' 'e' 'exec' 'exec-server' 'execpolicy' 'features' 'fork' 'help' 'login' 'logout' 'mcp' 'mcp-server' 'plugin' 'remote-control' 'review' 'resume' 'sandbox' 'sessions' 'update'";
const elvish_global_options =
    "'--help' '-h' '--version' '-V' '--profile' '-p' '--cd' '-C' '--add-dir' '--config' '-c' '--model' '-m' '--image' '-i' '--enable' '--disable' '--oss' '--local-provider' '--ask-for-approval' '-a' '--approval-policy' '--sandbox' '-s' '--dangerously-bypass-approvals-and-sandbox' '--yolo' '--search' '--remote' '--remote-auth-token-env' '--no-alt-screen'";
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
    const first = args.next();
    if (first) |arg| {
        if (isHelpFlag(arg)) {
            printHelp();
            return;
        }
    }

    const shell = if (first) |arg| try Shell.parse(arg) else Shell.bash;
    if (args.next() != null) return error.UnexpectedCompletionArgument;

    const rendered = try renderCompletion(allocator, shell);
    defer allocator.free(rendered);
    try cli_utils.writeStdout(rendered);
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
        "complete -c codex-zig -s C -l cd -r -d 'Use working root'\n",
        "complete -c codex-zig -l add-dir -r -d 'Add writable root'\n",
        "complete -c codex-zig -s c -l config -r -d 'Override config key'\n",
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
        "complete -c codex-zig -l search -d 'Enable live web search'\n",
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
        \\        '(-C --cd)'{{-C,--cd}}'[Use working root]:directory:_files -/' \
        \\        '--add-dir[Add writable root]:directory:_files -/' \
        \\        '(-c --config)'{{-c,--config}}'[Override config key]:key=value:' \
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
        \\        '--search[Enable live web search]' \
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "remote-control") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--remote-auth-token-env") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "powershell") != null);
}

test "completion renders fish command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .fish);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "complete -c codex-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "__fish_seen_subcommand_from completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "bash elvish fish powershell zsh") != null);
}

test "completion renders zsh command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .zsh);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "#compdef codex-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shells=(bash elvish fish powershell zsh)") != null);
}

test "completion renders powershell command and shell values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .powershell);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "$shells = 'bash elvish fish powershell zsh'.Split(' ')") != null);
}

test "completion renders elvish quoted command values" {
    const allocator = std.testing.allocator;
    const rendered = try renderCompletion(allocator, .elvish);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "edit:completion:arg-completer[codex-zig]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'--help'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "put 'bash' 'elvish' 'fish' 'powershell' 'zsh'") != null);
}

test "completion parses supported shell names" {
    try std.testing.expectEqual(Shell.bash, try Shell.parse("bash"));
    try std.testing.expectEqual(Shell.zsh, try Shell.parse("zsh"));
    try std.testing.expectError(error.UnknownCompletionShell, Shell.parse("unknown"));
}
