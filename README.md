# Codex Zig Port

[![CI](https://github.com/minghinmatthewlam/codex-zig-port/actions/workflows/ci.yml/badge.svg)](https://github.com/minghinmatthewlam/codex-zig-port/actions/workflows/ci.yml)

This repository is an independent Zig reimplementation of the Codex CLI.
A local Rust Codex checkout can be used as a behavioral reference only:
runtime code in this repository must not import, link to, shell out to, or copy
source from the original implementation.

This is an unofficial project and is not affiliated with or endorsed by OpenAI.

## Open Source Status

This repository is public under the MIT License. It is pre-release software:
many surfaces are intentionally marked partial until they are implemented and
verified against the real CLI, TUI, or app-server behavior.

Contributions should follow `CONTRIBUTING.md`, security reports should follow
`SECURITY.md`, and conduct expectations are in `.github/CODE_OF_CONDUCT.md`.
Do not include real credentials, `auth.json`, private prompts, or local session
transcripts in public issues or pull requests.
The current public-readiness audit is tracked in `docs/oss-readiness.md`.

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
  PTY-backed `write_stdin` session input, including Rust-shaped yield bounds
  and `background_terminal_max_timeout`
- accept `update_plan` tool calls and surface task progress in the TUI
- run explicit local TUI shell commands with `!COMMAND`
- execute basic `shell` / `shell_command` tool calls after user confirmation
- run a command through the macOS Seatbelt sandbox with `sandbox macos`,
  including Rust built-ins and supported custom `[permissions]` profiles
  for parsed Seatbelt-only socket/denial flags
- check `prefix_rule` execpolicy files against a command with
  `execpolicy check`, including `match` / `not_match` examples,
  `network_rule` validation, and absolute host executable resolution
- apply focused `apply_patch` file edits after user confirmation
- discover and execute configured stdio and streamable HTTP MCP tools as
  `mcp__server__tool` calls, including streamable HTTP MCP session-id reuse and
  configured static/env HTTP headers, JSON-RPC responses delivered over GET SSE
  streams after accepted POSTs, plus best-effort session teardown
- expose model-facing `list_mcp_resources`, `list_mcp_resource_templates`, and
  `read_mcp_resource` tools for configured stdio and streamable HTTP MCP
  servers
- copy the last assistant response from the interactive TUI with `/copy`
- toggle copy-friendly transcript output from the interactive TUI with `/raw`
- toggle the in-memory Vim composer mode indicator with `/vim`
- include file contents in the next interactive prompt with `/mention`
- ask a question in an ephemeral fork with `/side`
- inspect configured MCP servers from the interactive TUI with `/mcp`
- accept app-server MCP config reload requests and list server status with
  `config/mcpServer/reload` and `mcpServerStatus/list`, including enabled
  local plugin-cache `.mcp.json` server entries plus raw stdio and streamable
  HTTP tool, resource, and resource-template inventory plus streamable HTTP
  bearer-token, file-backed OAuth, and OAuth-discovery not-logged-in auth state
- read resources with and without loaded thread IDs, and call tools on
  configured stdio and streamable HTTP MCP servers through app-server
  `mcpServer/resource/read` and `mcpServer/tool/call`, including streamable
  HTTP configured static/env headers, GET SSE responses after accepted POSTs,
  and forwarded MCP JSON-RPC error code/message/data payloads
- validate app-server MCP OAuth login requests with `mcpServer/oauth/login`,
  including generated completion notification artifacts, Rust-shaped
  configured-server checks, and explicit not-implemented errors for the browser
  OAuth flow
- validate CLI MCP OAuth login requests with `codex-zig mcp login`, including
  configured-server, streamable HTTP, and comma-separated scope checks before
  returning the explicit not-implemented browser-flow error
- remove file-backed and macOS keychain-backed MCP OAuth credentials for
  streamable HTTP servers with `codex-zig mcp logout`
- report bearer-token, file-backed OAuth, macOS keychain-backed OAuth, and
  OAuth-discovery not-logged-in state from `codex-zig mcp list`
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
- run a minimal exec-server stdio/websocket JSON-RPC transport with a Rust-shaped
  `initialize` handshake, detached websocket `resumeSessionId` reconnects,
  pipe-backed and macOS PTY-backed `tty`
  `process/start` / `process/read` / `process/write` / `process/terminate`
  lifecycle, `envPolicy`-based child environment filtering and overlays, Unix
  `arg0` process titles, filesystem read/write/mkdir/metadata/list/copy/remove
  RPCs with supported filesystem sandbox contexts, buffered executor-side
  `http/request` RPCs for built-in HTTP methods with buffered and streamed
  timeout handling plus streamed response body-delta notifications over stdio
  and websockets,
  registry-backed remote executor registration through `--remote` /
  `--executor-id` with bearer-token auth plus local `ws://` and loopback
  self-signed or public-CA `wss://` rendezvous serving
- run a minimal app-server JSON-RPC transport over stdio or Unix sockets with
  an `initialize` handshake, keeping Unix socket listeners alive for sequential
  clients
- generate minimal app-server TypeScript bindings and JSON Schema bundles with
  `app-server generate-ts -o DIR [--experimental]` and
  `app-server generate-json-schema -o DIR [--experimental]`, including
  command-exec request, response, follow-up, and output-delta notification
  shapes in the public generated artifacts, plus the hidden internal
  `RolloutLine.json` schema with
  `app-server generate-internal-json-schema -o DIR`
- handle app-server filesystem JSON-RPC methods for read, write, mkdir,
  metadata, directory listing, remove, and copy
- watch app-server filesystem mutations and request-boundary external file
  changes with `fs/watch`, `fs/unwatch`, and `fs/changed` notifications on the
  same JSON-RPC connection
- answer app-server model catalog and provider-capability JSON-RPC methods
- compute legacy app-server `gitDiffToRemote` responses against a remote branch
- answer legacy app-server `fuzzyFileSearch` requests with local file and
  directory matches plus connection-local `fuzzyFileSearch/session*`
  notifications
- report app-server account state with `account/read` for no-auth, API-key,
  ChatGPT, Bedrock, custom no-auth provider, and local-OSS cases
- report legacy app-server auth status with `getAuthStatus`
- start app-server API-key and external ChatGPT-token login with
  `account/login/start`, respect forced account-login config, and emit account
  login/update notifications
- handle app-server login cancellation requests with `account/login/cancel`
- read app-server account rate limits with `account/rateLimits/read`
- notify workspace owners about credit or usage-limit issues with
  `account/sendAddCreditsNudgeEmail`
- remove app-server auth with `account/logout` and emit `account/updated`
- read app-server config basics plus effective feature flags, user
  config-origin/layer metadata, user sandbox workspace settings, user tools
  and apps config including app defaults, forced account-login config, policy
  flags, and per-app tool overrides, trusted project-stack scalar, tool, app,
  and sandbox workspace layers, system scalar/tool/app/sandbox workspace
  precedence, required empty user/system layers, and legacy managed
  scalar/tool/app/sandbox overrides with `config/read`
- write app-server config scalar, array, object, and null-clearing values with
  `config/value/write`
- merge and replace existing app-server TOML table objects with
  `config/value/write`
- apply multiple app-server config edits in one file write with
  `config/batchWrite`, including table-object merge/replace behavior
- report absent, system `requirements.toml`, and legacy managed config
  requirements with `configRequirements/read`, including system feature and
  managed hook requirements, residency requirements, plus network scalar,
  domain, and socket requirements
- clear memory directories and SQLite memory-state rows with `memory/reset`
- list app-server collaboration mode presets with `collaborationMode/list`
- list app-server experimental feature metadata and patch process-local runtime
  feature enablement
- proxy stdio JSON-RPC to the app-server Unix control socket with
  `app-server proxy`
- accept Rust-compatible app-server `--analytics-default-enabled`, run plain
  websocket JSON-RPC, reject Origin-bearing websocket requests, and enforce
  websocket capability-token auth from `--ws-token-file` or `--ws-token-sha256`
  plus HS256 signed-bearer auth with exp/nbf/issuer/audience validation, keeping
  websocket listeners alive for sequential clients with connection-local state
  reset
- apply the latest PR diff from a Codex agent task with `apply` / `a`
- send tool output back to the model
- review current changes from the interactive TUI with `/review`
- run narrow non-interactive `review --uncommitted`, `review --base`, and
  `review --commit` flows, plus custom review instructions from argv or stdin,
  including Rust-compatible `exec review` dispatch with exec-level `--cd`
  handling
- run non-interactive `exec` prompts from argv, explicit `-`, or piped stdin,
  including prompt-plus-piped-context requests
- enforce Rust-compatible non-interactive `exec` and `review` Git-repository
  checks, with `--skip-git-repo-check` and dangerous bypass exceptions on
  `exec`, including for `exec review`
- reject conflicting approval-policy flags when dangerous bypass mode is set
- inspect known feature flags with `features list`
- enable or disable known feature flags and Rust legacy aliases for one
  invocation with root `--enable/--disable`
- persist feature flags and Rust legacy aliases globally or per profile with
  `features enable|disable`, including Rust-like root clearing for default-off
  flags, under-development warnings for direct root enables, and app-server
  startup warnings for config-enabled under-development features plus
  deprecation notices for legacy feature keys
- emit app-server startup deprecation notices for
  `experimental_instructions_file`
- emit app-server startup warnings for deprecated `on-failure` approval-policy
  configuration
- emit app-server startup warnings for user/plugin hook-load warnings
- emit app-server `initialize` config warnings when project-local `.codex`
  config, hooks, and exec policies are disabled until the project is trusted,
  for ignored unsupported project-local config keys, and for malformed user or
  trusted project-local execpolicy rules
- emit app-server `turn/plan/updated` notifications when `turn/start` runs a
  model-requested `update_plan` tool call
- emit app-server `turn/diff/updated` notifications when `turn/start` runs a
  successful model-requested `apply_patch` edit in a git-backed loaded thread
  cwd
- emit app-server `item/fileChange/patchUpdated` notifications when
  `turn/start` runs successful model-requested `apply_patch` edits
- emit app-server `item/commandExecution/outputDelta` notifications when
  `turn/start` runs model-requested shell tools
- emit app-server `item/commandExecution/terminalInteraction` notifications
  when `turn/start` writes stdin to model-started terminal sessions
- clean model-started app-server PTY sessions through
  `thread/backgroundTerminals/clean` for clients with `experimentalApi`
- require `initialize.params.capabilities.experimentalApi` for implemented
  Rust experimental app-server request methods, including `memory/reset`,
  `thread/goal/*`, `thread/memoryMode/set`, `thread/turns/list`,
  `thread/realtime/*`, `thread/backgroundTerminals/clean`, `process/*`,
  `collaborationMode/list`, and `fuzzyFileSearch/session*`
- require `initialize.params.capabilities.experimentalApi` for implemented
  Rust experimental app-server request fields on `thread/start`,
  `thread/resume`, `thread/fork`, `turn/start`, `turn/steer`,
  `command/exec`, and `account/login/start`
- suppress implemented Rust experimental app-server server notifications,
  including `thread/goal/*` and `process/*`, until the client enables
  `experimentalApi`
- include experimental `permissionProfile` and `activePermissionProfile`
  fields on `thread/start`, `thread/resume`, and `thread/fork` responses only
  after the client enables `experimentalApi`
- emit app-server `rawResponseItem/completed` notifications for raw Responses
  output items observed during `turn/start`
- emit app-server reasoning stream notifications for Responses reasoning
  events observed during `turn/start`
- emit app-server model reroute and verification notifications for Responses
  model metadata observed during `turn/start`
- emit app-server `item/mcpToolCall/progress` notifications around configured
  MCP tool calls during `turn/start`
- emit app-server MCP startup status notifications while `turn/start`
  discovers configured MCP tools
- emit app-server `thread/compacted` notifications after successful loaded
  thread compactions
- root app-server `turn/start` model-requested shell tools and `apply_patch`
  edits in the loaded thread cwd when the tool call does not provide an
  explicit workdir
- run a minimal interactive remote app-server TUI over `--remote unix://PATH`,
  loopback `--remote ws://HOST:PORT`, or TLS `--remote wss://HOST:PORT` for
  new threads, remote resume/fork pickers, `resume --last`, explicit
  `resume TARGET`, explicit
  `fork ID|PATH`, `fork --last`, text/local-image turns, and websocket
  capability-token auth via `--remote-auth-token-env`
- start a minimal local remote-control server with `--remote-control`,
  `--remote-control-bind`, or runtime `/remote-control [start|stop]`, exposing
  controller/viewer browser links, `/api/state`, live `/api/events`
  server-sent state snapshots, and controller-only `/api/message` prompt
  submission into the running TUI
- accept interactive override flags after `resume` and `fork`, including model,
  profile, cwd, image, approval, sandbox, OSS, remote, and no-alt-screen
  settings
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
- parse the planned Rust top-level `remote-control` command's config and
  feature options, while still reporting headless app-server remote
  control as unimplemented
- parse the experimental `cloud` / `cloud-tasks` command family, including
  `exec`, `status`, `list`, `apply`, and `diff` options, while still reporting
  Codex Cloud task runtime execution as unimplemented
- print general or command-specific help with `help [COMMAND]`
- generate shell completion scripts for bash, elvish, fish, powershell, and zsh

Long-term exact parity is tracked in `docs/parity.md`.

## License

This project is licensed under the MIT License. See `LICENSE`.

## Requirements

The first milestone is developed and verified on macOS. Other Unix-like
platforms may build, but they are not yet part of the supported verification
matrix.

- Zig `0.16.0`
- Python 3 for smoke-test harnesses
- SQLite development headers/library available to the system linker
- Git for repository-aware exec, review, and plugin-marketplace smokes

On macOS with Xcode Command Line Tools installed, the SQLite and Git
requirements are normally already available.

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
runtime feature toggles through `features list`, profile-scoped feature
persistence, Rust legacy feature aliases, direct under-development enable
warnings, app-server startup warnings for config-enabled under-development
features, suppression with `suppress_unstable_features_warning = true`, legacy
feature-key deprecation notices, deprecated `experimental_instructions_file`
notices, deprecated `on-failure` approval-policy warnings, initialize-time
project-local config warnings for disabled project config and ignored
unsupported keys plus malformed user/trusted project execpolicy rules,
hook-load startup warnings, and root default-off feature clearing, checks
`help [COMMAND]`,
verifies exact generated shell completion output for bash, elvish, fish,
powershell, and zsh, verifies
`execpolicy check` prefix-rule JSON output, `match` / `not_match` validation,
`network_rule` validation, and resolved host executable JSON output,
interactive remote app-server flag parsing/rejection plus real
`--remote unix://PATH` and loopback `--remote ws://HOST:PORT` TUI turns through
a running app-server, verifies planned-but-unimplemented Rust top-level command
stubs plus the `remote-control` and `cloud` command families' Rust-shaped
option parsing and positional-argument rejection, verifies local remote-control
flag parsing/rejection, runtime
`/remote-control [start|stop]`, and a PTY-driven local `/api/message`
submission into the running TUI while a live `/api/events` stream observes the
updated transcript, verifies session-local
`resume` / `fork` override parsing,
verifies local and git-backed `plugin marketplace`
add/repeat/upgrade/remove config mutation,
verifies `debug clear-memories` against temporary memory roots with symlink-root
rejection and SQLite state-db row cleanup, checks the debug app-server
send-message-v2 turn stream against a mock Responses backend, verifies
`debug trace-reduce` lifecycle replay against a temporary trace
bundle, runs the top-level `apply` command against a mock ChatGPT task backend
and temporary git repository, then drives
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
`CODEX_HOME/app-server-control/app-server-control.sock` socket, including
sequential client connections after the first client disconnects. The same
smoke script also proxies JSON-RPC over `app-server proxy --sock`, verifies the
hidden `stdio-to-uds` relay command with a persistent Unix listener, verifies
app-server local and git-backed
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
raw stdio tool/resource/resource-template inventory, bearer-token,
file-backed OAuth, and OAuth-discovery not-logged-in auth reporting,
config-backed stdio resource reads with and without loaded thread IDs,
loaded-thread stdio tool calls including non-object argument pass-through, and
app-server streamable HTTP MCP resource reads and tool calls with bearer-token
and file-backed OAuth auth plus streamable HTTP MCP session-id and teardown
headers and GET SSE responses after accepted POSTs,
model-facing stdio and streamable HTTP MCP resource
list/template/read tool calls, verifies model-facing streamable HTTP MCP tool
discovery and execution with bearer-token auth plus session-id and teardown
headers and GET SSE responses after accepted POSTs, verifies
CLI MCP OAuth login validation, file-backed MCP OAuth logout, and macOS
keychain-backed MCP OAuth logout for streamable HTTP servers, verifies
CLI MCP auth-status reporting for bearer-token, file-backed OAuth, macOS
keychain-backed OAuth, and OAuth-discovery not-logged-in servers, verifies
exec-server filesystem read, write, metadata, directory listing, copy, remove,
and sandbox-context behavior against a temporary directory, verifies
app-server filesystem read, write, metadata, directory listing, copy, and remove
behavior against a temporary directory, verifies app-server filesystem watch
notifications for in-process file mutations, direct external file mutations,
and unwatch cleanup,
verifies app-server buffered `command/exec` for stdout/stderr capture,
capture-time independent output-cap truncation, timeout exit-code responses
with captured pre-timeout output, cwd and environment overrides, nonzero exit
responses, supported `permissionProfile`
execution shapes using Rust-shaped `fileSystem` / `network.enabled` payloads,
managed permission-profile network enabled/restricted behavior,
`streamStdoutStderr` output-delta notifications, external permission-profile
and external sandbox-policy execution, sandbox-policy `networkAccess`
enforcement, stdio stdin streaming, PTY sessions, active PTY resize,
workspace-write sandbox-policy temp-root defaults and exclude
flags, implicit workspace-write temp-root defaults, required streaming
`processId` validation, and follow-up command session validation/inactive-process
errors,
verifies app-server `process/spawn` execution, output/exited notifications,
active stdio streamed-output and stdin sessions, duplicate active handle
rejection, active `process/kill`, macOS PTY sessions with `process/resizePty`,
and non-stdio transport rejection for process stdin/TTY sessions,
checks app-server model catalog, provider-capability, collaboration-mode-list,
app-list empty and enabled local plugin app manifest catalogs,
git-diff-to-remote, fuzzy-file-search one-shot scoring/order and session notifications,
account-read, get-auth-status,
account-logout, account-login, account-login-cancel, account-rate-limits,
account-add-credits-nudge, config-read with user origin/layer metadata, user
sandbox workspace settings, tools/apps config including app defaults, policy
flags, and per-app tool overrides, trusted project scalar, tool, app, and
sandbox workspace layers, system scalar/tool/app/sandbox workspace
precedence, required empty user/system layers, and legacy managed
scalar/tool/app/sandbox overrides,
config-value-write including table-object merge/replace behavior,
config-batch-write including table-object merge/replace behavior, and
config-requirements RPCs against temporary config homes, including system
requirements precedence and legacy managed-config requirements, and a mock
backend, checks app-server experimental
feature listing and runtime
enablement patching against temporary config homes, verifies websocket
sequential-client lifecycle and connection-local subscription reset, verifies
app-server
TypeScript/JSON Schema generation including command-exec request/response,
follow-up, and output-delta notification artifacts, verifies the hidden
internal `RolloutLine.json` schema generator, and checks app-server flag
compatibility for analytics defaults plus websocket transport,
capability-token auth, and signed-bearer auth. It also runs
CLI smokes for profile-scoped feature enablement writes and reads, `exec review`
dispatch with `--cd`, equals-form exec options, piped-stdin exec prompts, the
exec Git-repository guard, `exec resume` option placement, yolo
approval-policy conflicts, and removed
`--full-auto` compatibility, plus rejection of the removed top-level
`marketplace` namespace and sandbox built-in permission-profile execution.
App-server smokes cover profile-scoped feature enablement writes and reads. Run
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
codex-zig resume last -m gpt-5.5 --sandbox workspace-write
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
`[model_providers.<name>].base_url`, `wire_api`, `env_key`,
`experimental_bearer_token`, `query_params`, `http_headers`, and
`env_http_headers` for custom providers. It also supports section-form
`[model_providers.<name>.auth]` and inline `auth = { ... }` `command`, `args`,
`cwd`, `timeout_ms`, and `refresh_interval_ms` for command-backed bearer tokens.
The current port supports Responses wire API providers, rejects the removed
`wire_api = "chat"` setting, and rejects command-auth combinations that Rust
marks invalid. Command-backed provider tokens are cached while fresh, rerun
after `refresh_interval_ms` before a later request, and force-refreshed once on
401 before retrying the request.

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
codex-zig sandbox macos --permissions-profile :workspace --cd . -- /bin/echo ok
codex-zig sandbox macos --permissions-profile custom-profile --cd . -- /bin/echo ok
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
