# Codex Zig Port

This repository is an independent Zig reimplementation of the Codex CLI.
The Rust Codex checkout at `~/dev/codex` is a behavioral reference only:
runtime code in this repository must not import, link to, or shell out to the
original implementation.

This is an unofficial project and is not affiliated with or endorsed by OpenAI.

## Open Source Status

This repository is public under the MIT License. It is pre-release software:
many surfaces are intentionally marked partial until they are implemented and
verified against the real CLI, TUI, or app-server behavior.

Contributions should follow `CONTRIBUTING.md`, security reports should follow
`SECURITY.md`, and conduct expectations are in `.github/CODE_OF_CONDUCT.md`.
Do not include real credentials, `auth.json`, private prompts, or local session
transcripts in public issues or pull requests.

## First Milestone

The first demo slice targets macOS and focuses on the interactive CLI surface:

- launch an interactive terminal UI with `zig build run`
- accept an optional initial prompt with `codex-zig [PROMPT]`
- use alternate-screen terminal mode by default and preserve inline scrollback
  with the Rust-compatible `--no-alt-screen` flag
- attach local image files to the first interactive prompt with `-i/--image`
- reuse local Codex auth from `$CODEX_HOME/auth.json` or `~/.codex/auth.json`
- refresh expired or stale ChatGPT auth tokens from stored refresh tokens
- manage basic auth with `login status`, `login --with-api-key`,
  `login --with-access-token`, `login --device-auth`, and `logout`
- send a Responses API turn
- stream assistant text deltas in the interactive TUI
- set the `priority` service tier for later turns with `/fast`
- include discovered `AGENTS.md` project instructions in API turns
- create a repository guide through interactive `/init`
- compact an interactive session into a continuation summary with `/compact`
- inspect effective interactive configuration and local config source status with `/debug-config`
- inspect current built-in key bindings with `/keymap`
- toggle plan-only prompts with `/plan`
- render plan-mode `<proposed_plan>` blocks without leaking markup
- manage ordered terminal-title items with `/title`
- configure status-line preview items with `/statusline`
- choose a syntax theme with `/theme`
- select a communication personality with `/personality`
- set and persist the current thread title with `/rename`
- enable native Responses web search with `--search` or `web_search = "live"`
- accept modern `exec_command` tool calls for one-shot command execution and
  PTY-backed `write_stdin` session input
- accept `update_plan` tool calls and surface task progress in the TUI
- run explicit local TUI shell commands with `!COMMAND`
- execute basic `shell` / `shell_command` tool calls after user confirmation
- run a command through the macOS Seatbelt sandbox with `sandbox macos`
- check `prefix_rule` execpolicy files against a command with
  `execpolicy check`, including `match` / `not_match` examples,
  `network_rule` validation, and absolute host executable resolution
- apply focused `apply_patch` file edits after user confirmation
- discover and execute configured stdio MCP tools as `mcp__server__tool` calls
- copy the last assistant response from the interactive TUI with `/copy`
- toggle copy-friendly transcript output from the interactive TUI with `/raw`
- toggle the in-memory Vim composer mode indicator with `/vim`
- include file contents in the next interactive prompt with `/mention`
- ask a question in an ephemeral fork with `/side`
- inspect configured MCP servers from the interactive TUI with `/mcp`
- accept app-server MCP config reload requests and list server status with
  `config/mcpServer/reload` and `mcpServerStatus/list`, including enabled
  local plugin-cache `.mcp.json` server entries
- list local app-server plugin marketplaces with `plugin/list`, including
  repo/home marketplace manifests, manifest metadata, and installed/enabled
  state from `$CODEX_HOME`
- list remote app-server plugin marketplaces with `plugin/list`, including
  ChatGPT global, workspace directory, and shared-with-me catalog sources
- read local app-server plugin details with `plugin/read` for marketplace-backed
  local plugins, including summary metadata, manifest description, skills,
  hooks, app ids, and MCP server names
- install local and git-backed app-server plugins with `plugin/install`,
  including cache copy, git-subdir sparse checkout, config enablement, and
  Rust-shaped auth-policy responses
- install remote app-server plugins with `plugin/install`, including bundle
  download, versioned cache writes, cloud install mutation, and Rust-shaped
  auth-policy responses
- read remote app-server plugin details with `plugin/read`, including catalog
  metadata, installed/enabled state, disabled remote skills, app ids, and
  remote source summaries
- read remote app-server plugin skill Markdown with `plugin/skill/read`
- create, list, retarget, and delete remote app-server plugin shares with
  `plugin/share/save`, `plugin/share/list`, `plugin/share/updateTargets`, and
  `plugin/share/delete`
- uninstall local and remote app-server plugins with `plugin/uninstall`,
  including local cache/config cleanup and remote cloud mutation
- run a stdio MCP server with `codex` and `codex-reply` tools plus per-call
  `model`, `cwd`, `approval-policy`, and `sandbox` overrides
- run a minimal app-server JSON-RPC transport over stdio or Unix sockets with
  an `initialize` handshake
- handle app-server filesystem JSON-RPC methods for read, write, mkdir,
  metadata, directory listing, remove, and copy
- watch app-server filesystem mutations with `fs/watch`, `fs/unwatch`, and
  `fs/changed` notifications on the same JSON-RPC connection
- answer app-server model catalog and provider-capability JSON-RPC methods
- compute legacy app-server `gitDiffToRemote` responses against a remote branch
- answer legacy app-server `fuzzyFileSearch` requests with local file and
  directory matches plus connection-local `fuzzyFileSearch/session*`
  notifications
- report app-server account state with `account/read` for no-auth, API-key,
  ChatGPT, Bedrock, custom no-auth provider, and local-OSS cases
- report legacy app-server auth status with `getAuthStatus`
- start app-server API-key and external ChatGPT-token login with
  `account/login/start` and emit account login/update notifications
- handle app-server login cancellation requests with `account/login/cancel`
- read app-server account rate limits with `account/rateLimits/read`
- notify workspace owners about credit or usage-limit issues with
  `account/sendAddCreditsNudgeEmail`
- remove app-server auth with `account/logout` and emit `account/updated`
- read app-server config basics plus effective feature flags with `config/read`
- write app-server config scalar, array, object, and null-clearing values with
  `config/value/write`
- apply multiple app-server config edits in one file write with
  `config/batchWrite`
- report absent managed config requirements with `configRequirements/read`
- list app-server collaboration mode presets with `collaborationMode/list`
- list app-server experimental feature metadata and patch process-local runtime
  feature enablement
- proxy stdio JSON-RPC to the app-server Unix control socket with
  `app-server proxy`
- accept Rust-compatible app-server `--analytics-default-enabled` and websocket
  auth flags while websocket transport remains unimplemented
- apply the latest PR diff from a Codex agent task with `apply` / `a`
- send tool output back to the model
- review current changes from the interactive TUI with `/review`
- run narrow non-interactive `review --uncommitted`, `review --base`, and
  `review --commit` flows, including Rust-compatible `exec review` dispatch
- run non-interactive `exec` prompts from argv, explicit `-`, or piped stdin,
  including prompt-plus-piped-context requests
- enforce Rust-compatible non-interactive `exec` Git-repository checks, with
  `--skip-git-repo-check` and dangerous bypass exceptions
- inspect known feature flags with `features list`
- enable or disable known feature flags for one invocation with root
  `--enable/--disable`
- persist feature flags globally or per profile with `features enable|disable`
- parse Rust-compatible interactive remote app-server flags with `--remote` and
  `--remote-auth-token-env` while remote TUI transport remains unimplemented
- add local and git-backed marketplace sources, upgrade configured Git
  marketplaces, and remove configured marketplaces with `plugin marketplace`,
  mutating `$CODEX_HOME/config.toml`
- list user and per-cwd project command hooks from `config.toml` and
  `hooks.json` with app-server `hooks/list`, including user hook-state
  enable/trust metadata and enabled local plugin-cache hooks
- list local app-server skills from repo, user, and per-cwd extra roots with
  `skills/list`, including enabled local plugin-cache skill roots,
  `forceReload` cache refreshes, and `agents/openai.yaml` interface/dependency metadata plus
  `skills/config/write` enablement toggles
- recognize planned Rust top-level commands like `remote-control`, `cloud`,
  `exec-server`, and `update` without treating them as prompt text
- print general or command-specific help with `help [COMMAND]`

Long-term exact parity is tracked in `docs/parity.md`.

## License

This project is licensed under the MIT License. See `LICENSE`.

## Build

```sh
zig build
zig build test
zig build run
```

The project currently targets Zig `0.16.0`.

## Verification

Run the repeatable checks:

```sh
zig build test
zig build e2e
```

The `e2e` step starts a local mock Responses server, launches the real
`zig-out/bin/codex-zig` binary in a pseudo-terminal, verifies top-level
`-i/--image` initial-prompt attachment on the interactive path, verifies
runtime feature toggles through `features list`, checks `help [COMMAND]`, verifies
`execpolicy check` prefix-rule JSON output, `match` / `not_match` validation,
`network_rule` validation, and resolved host executable JSON output,
interactive remote app-server flag parsing/rejection, verifies planned-but-unimplemented
Rust top-level command stubs, verifies local and git-backed `plugin marketplace`
add/repeat/upgrade/remove config mutation,
verifies `debug clear-memories` against temporary memory roots with symlink-root
and state-db partial-reset rejection, checks planned debug app-server and
trace-reducer stubs, runs the top-level `apply` command against a mock ChatGPT
task backend and temporary git repository, then drives
`/help`, `/status`,
`/debug-config` effective values plus config-source status, `/keymap`, `/plan` tool omission and proposed-plan rendering, `/title` item selection and persistence, `/statusline`, `/theme`, `/personality`, persisted `/rename` metadata, `/sessions`, `/fast`, `/copy`, `/raw`, `/vim`, `/mention`, `/side`, `/mcp`, `!COMMAND`, `/model`, `/permissions`, `/history`, model-requested `update_plan`, `exec_command`, and
`apply_patch` tool calls with approval, `/ps`, `/clean`, and `/quit`, then checks
the captured terminal transcript, API request count, propagated model override,
propagated service tier, and the file created in the temporary workspace. It
also launches the TUI without `--no-alt-screen` to verify alternate-screen
enter/leave escape sequences, checks `tui.alternate_screen = "never"` stays
inline, then launches `codex-zig app-server` as a subprocess and verifies
newline-delimited JSON-RPC initialize requests and unsupported-method errors
over stdio, verifies `memory/reset` against temporary memory roots plus
partial-reset refusal cases, then checks an explicit Unix socket and the default
`CODEX_HOME/app-server-control/app-server-control.sock` socket. The same smoke
script also proxies JSON-RPC over `app-server proxy --sock`, verifies the
hidden `stdio-to-uds` relay command, verifies app-server local and git-backed
marketplace add/list/repeat/upgrade/remove RPC behavior, including git revision
metadata, local app-server
`plugin/list` marketplace discovery from repo, home, and configured local roots, remote
`plugin/list` catalog fetching, remote `plugin/read` detail fetching, remote
`plugin/skill/read` Markdown fetching, remote plugin share save/list/update/delete
behavior, local `plugin/uninstall` cache/config cleanup, remote
`plugin/uninstall` cache cleanup, local and pinned git-subdir `plugin/install`
cache/config writes, remote `plugin/install` bundle cache writes and cloud mutation,
and local `plugin/read` details for skills, hooks, apps, and MCP servers,
verifies app-server hooks-list discovery for user and
project `config.toml` / `hooks.json` command hooks, enabled local plugin-cache
command hooks, persisted user hook state, and malformed JSON warnings, verifies
app-server
skills-list discovery for repo, user, extra, and enabled local plugin-cache
skill roots plus `forceReload` cache behavior, `agents/openai.yaml`
interface/dependency metadata, and `skills/changed` invalidations for in-process skill and config
mutations, verifies
app-server MCP server status pagination, enabled local plugin-cache MCP entries,
and bearer-token auth reporting, verifies
app-server filesystem read, write, metadata, directory listing, copy, and remove
behavior against a temporary directory, verifies app-server filesystem watch
notifications for in-process file mutations and unwatch cleanup,
checks app-server model catalog, provider-capability, collaboration-mode-list,
git-diff-to-remote, fuzzy-file-search one-shot and session notifications,
account-read, get-auth-status,
account-logout, account-login, account-login-cancel, account-rate-limits,
account-add-credits-nudge, config-read, config-value-write, config-batch-write,
and config-requirements RPCs against temporary config homes and a
mock backend, checks app-server experimental feature listing and runtime
enablement patching against temporary config homes, and checks app-server flag
compatibility for analytics defaults plus websocket auth parsing. It also runs
CLI smokes for profile-scoped feature enablement writes and reads, `exec review`
dispatch, equals-form exec options, piped-stdin exec prompts, and the exec
Git-repository guard. App-server smokes cover profile-scoped feature enablement
writes and reads. Run
`scripts/tui_e2e.py --show-output` directly when you want to inspect the
terminal transcript.

## Auth

`codex-zig` reuses the same `$CODEX_HOME/auth.json` file as the Rust CLI. The
current Zig auth surface supports:

```sh
codex-zig login status
codex-zig login
codex-zig login --with-api-key
codex-zig login --with-access-token
codex-zig login --device-auth
codex-zig logout
```

`login` starts a local browser OAuth callback flow on macOS and writes the
resulting ChatGPT tokens to `auth.json`. `login --device-auth` implements the
ChatGPT device-code fallback directly in Zig.
`login --with-access-token` stores the token in the Rust CLI-compatible
`agent_identity` auth shape; full upstream JWT/JWKS verification and
agent-task authorization are still tracked as parity work. `CODEX_ACCESS_TOKEN`
can also provide the access token without writing `auth.json`.
`logout` removes the selected `CODEX_HOME/auth.json`; it does not yet revoke
OAuth tokens server-side.

## Sessions

Interactive and non-interactive turns save Zig-native JSONL transcripts under
`$CODEX_HOME/sessions/zig/`.

```sh
codex-zig sessions
codex-zig resume
codex-zig resume --last
codex-zig resume <session-id>
codex-zig fork
codex-zig fork --last
codex-zig fork <session-id>
```

## Configuration

The port reads `model`, `model_provider`, `openai_base_url`,
`chatgpt_base_url`, `approval_policy`, `sandbox_mode`, `oss_provider`,
`personality`, and `profile` from top-level keys in
`$CODEX_HOME/config.toml`. It also supports `[profiles.<name>]` sections for
those same fields, reads `[tui].theme`, `[tui].status_line`,
`[tui].terminal_title`, and `[tui].alternate_screen` for TUI preferences, and reads
`[model_providers.<name>].base_url` for custom Responses-compatible providers.

```sh
codex-zig --profile work auth-status
codex-zig -m gpt-5.5 -a never -s danger-full-access
codex-zig -i screenshot.png "describe this"
codex-zig --cd ~/dev/my-project
codex-zig --add-dir ~/scratch
codex-zig -c model=gpt-5.5
codex-zig exec -c sandbox_mode=read-only "say hello"
codex-zig --oss --local-provider lmstudio
codex-zig --search
codex-zig --enable goals features list
codex-zig --disable shell_tool features list
codex-zig help exec
codex-zig --no-alt-screen
codex-zig --version
codex-zig exec --profile work "say hello"
codex-zig exec --skip-git-repo-check "say hello"
printf 'say hello' | codex-zig exec
printf 'extra context' | codex-zig exec "summarize"
codex-zig exec resume --all last "continue"
codex-zig exec --image screenshot.png "describe this"
codex-zig sandbox macos -- /bin/echo ok
codex-zig features list
codex-zig features enable goals
codex-zig features disable goals
codex-zig --profile work features enable goals
codex-zig mcp list
codex-zig mcp add docs -- node ./server.js
codex-zig mcp add remote --url https://example.com/mcp
codex-zig mcp-server
codex-zig app-server
codex-zig review --uncommitted
codex-zig review --base main
codex-zig review --commit HEAD
codex-zig exec review --uncommitted
```

`CODEX_ZIG_PROFILE` selects a profile. `CODEX_ZIG_MODEL` overrides the model.
`CODEX_ZIG_MODEL_PROVIDER` selects a configured model provider.
`CODEX_ZIG_BASE_URL` overrides both API base URLs for local testing.
`CODEX_ZIG_WEB_SEARCH` overrides web search mode with `disabled`, `cached`, or
`live`.
`CODEX_OSS_BASE_URL` or `CODEX_OSS_PORT` override the local OSS Responses endpoint.
The Rust-compatible `-c/--config key=value` path currently accepts supported
scalar keys: `profile`, `model`, `openai_base_url`, `chatgpt_base_url`,
`oss_provider`, `approval_policy`, `sandbox_mode`, `web_search`, and
`tui.alternate_screen`.
