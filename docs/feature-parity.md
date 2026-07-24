# Feature Parity Gap List

Last checked: 2026-06-04.

This file tracks user-facing feature parity against the local Rust Codex CLI
reference, not CI, release, OSS hygiene, byte-for-byte fixture parity, or
purely internal generator parity. The current reference is:

- Rust checkout: `/Users/matthewlam/dev/codex` at
  `5381240f57fe326b13bc81325f3c61596592fc7a`
- Installed Rust CLI: `codex-cli 0.145.0`
- Zig checkout: `b32b51ab1c496d8b778581f6c60d9a1284fefdb9`
- Zig CLI: `codex-zig 0.0.1`

The source evidence for this pass was the Rust and Zig root help output,
targeted subcommand help output, Rust CLI command definitions in
`codex-rs/cli/src/main.rs`, Rust TUI slash-command definitions in
`codex-rs/tui/src/slash_command.rs`, Zig command dispatch in `src/main.zig`,
Zig TUI help in `src/tui.zig`, and the broader narrative tracker in
`docs/parity.md`. App-server turn input-size parity was checked against
Rust's `turn_processor.rs`, `protocol/v2/turn.rs`, and
`MAX_USER_INPUT_TEXT_CHARS` definition, then verified through the Zig stdio
app-server smoke.

## Priority Rules

- P0: Blocks believable macOS daily-driver feature parity.
- P1: Important user-facing parity, but a narrower CLI/TUI daily-driver can
  still work without it.
- P2: Useful parity or product polish that should follow the P0/P1 runtime
  gaps.
- Excluded: tests, CI, release/deployment, branch protection, code signing,
  byte-for-byte fixtures, and internal-only generator parity unless a generated
  artifact is required by a user-facing desktop or remote-control flow.

## P0 Gaps

### TUI and Active-Turn Lifecycle

- Implement true active-turn runtime state across interactive TUI and
  app-server loaded threads. Current Zig turn execution is still largely
  synchronous; Rust supports active turn state, interruption, steering, richer
  lifecycle events, and same-turn control. App-server `turn/start` now sends
  the normal-turn response, active status, and `turn/started` notification
  before provider completion, and `turn/start` / `turn/steer` now enforce
  Rust's 1 MiB text-character input limit with structured `input_too_large`
  JSON-RPC errors. Regular app-server turns can now accept `turn/steer` while a
  server-request approval, permission request, or `request_user_input` prompt is
  pending; accepted steer input is injected into the same model turn after the
  pending tool/request result. True async turn state, provider-flight steering,
  and broad same-turn control remain open.
- Local and remote TUI prompt submission now enforce the same 1 MiB
  text-character input limit before starting a model turn, with friendly
  terminal errors and pending image attachments preserved on rejection. Current
  coverage includes local normal input, initial prompts, defensive local
  remote-control submissions, `/side` / `/btw` args, custom `/review` args,
  remote initial prompts, and remote stdin prompts including oversized
  multibyte input that must be drained without exiting the TUI.
- Local TUI exit now silently terminates process-owned background terminals,
  matching Rust's shutdown cleanup for unified exec processes. Remaining TUI
  lifecycle gaps include robust user interruption and steering, queued input
  while a turn is running, `/compact` interactions, active tool interruption,
  and async background-process status depth.
- Basic local TUI `/experimental` coverage is implemented as a text-mode
  feature browser/toggler: it lists Rust menu-visible experimental features
  with effective enabled state, menu label, description, and config key, and
  `/experimental enable|disable FEATURE` persists the active profile config.
  Rich Rust popup keyboard navigation and live feature application remain part
  of the broader TUI popup/config-persistence depth buckets.
- Basic local TUI `/apps` coverage is implemented as a text-mode app catalog
  for local plugin-provided apps: it lists enabled/installed state, id,
  description, install URL, and contributing plugins. Rust's rich app popup,
  remote directory refresh, auth/link flows, and `$` insertion remain part of
  the plugin/app TUI depth buckets.
- Basic local TUI `/plugins` coverage is implemented as a text-mode local
  marketplace catalog for the current working directory: it lists marketplace
  display names, paths, installed/available counts, plugin enabled/installed
  state, id, short/long description, category, capabilities, keywords, and
  load errors. Rust's rich tabbed popup, search, install/uninstall, marketplace
  add/remove/upgrade, remote catalogs, details, app auth, and share management
  remain in the plugin TUI depth buckets.
- Basic local TUI `/memories` coverage is implemented as a text-mode memory
  settings surface: it reports feature enablement, current `use_memories` and
  `generate_memories` settings, persists feature enable/disable and the two
  memory toggles to `config.toml`, and can clear local memory files through the
  existing reset implementation. Rust's rich popup and confirmation UI remain
  planned TUI depth.
- Basic local TUI `/ide` coverage is implemented for the daily-driver surface:
  `/ide`, `/ide on`, `/ide off`, and `/ide status` toggle or report IDE
  context, enabling connects to the local Codex IPC Unix socket, fetches
  Rust-shaped `ide-context`, and prefixes subsequent local prompts with active
  file, active selection, open tabs, and the shared
  `## My request for Codex:` delimiter. Rust's rich status indicator, Windows
  pipe transport, and deeper transcript replay/display trimming remain planned
  TUI depth.
- Basic local and remote TUI `/approve` coverage is implemented for the empty
  recent-denials state: the command is recognized, listed in help, rejects
  inline args with usage, and prints Rust's no-denials guidance. Selecting and
  approving stored auto-review denials remains under the broader guardian retry
  and active-turn lifecycle buckets.
- Basic local and remote TUI `/feedback` coverage is implemented as a
  text-mode flow: `/feedback` lists the Rust categories, explicit
  `/feedback <category> [--logs|--no-logs] [note...]` submits feedback, local
  mode uploads directly with optional rollout-log attachment, and remote mode
  routes through app-server `feedback/upload`. Rust's rich category picker,
  consent popup, note editor, ring-buffer log capture, and employee-specific
  routing UI remain planned depth.
- Basic local TUI `/pets` / `/pet` coverage is implemented as a text-mode
  config flow: `/pets` lists the Rust built-in pet ids and current selection,
  `/pets <id>` persists `[tui].pet`, and `/pet hide` persists the disabled pet
  state. Rust's graphics capability detection, rich picker, preview image, asset
  download/cache, custom-pet rendering, and ambient terminal image lifecycle
  remain planned depth.
- Basic local TUI `/settings` coverage is implemented for the Rust realtime
  audio settings surface when `realtime_conversation` is enabled: it shows the
  current microphone/speaker selection and persists `[audio].microphone` /
  `[audio].speaker`, including clearing back to the system default. Rust's rich
  device picker, live device enumeration, and restart-active-audio prompt remain
  planned depth.
- Basic local TUI `/realtime` coverage is implemented behind Rust's
  `realtime_conversation` feature gate: `/help` shows the command only when the
  feature is enabled, `/realtime` toggles local active/inactive state,
  `/realtime start|stop|status` reports the current microphone/speaker
  selection, and `/status` reflects the local realtime state. Rust's actual
  microphone capture, speaker playback, websocket/WebRTC session startup,
  realtime transcript mirroring, and active-turn integration remain planned
  realtime backend depth.
- Basic local TUI `/agent` and `/subagents` coverage is implemented as a
  text-mode entry point for Rust's subagent picker surface: the commands are
  listed in `/help`, report the no-agent state, and respect the `multi_agent`
  feature gate. The stable v1 multi-agent tool discovery surface is now
  exposed through capability-gated, client-executed `tool_search`, returning
  the Rust-shaped `multi_agent_v1` namespace with `spawn_agent`, `send_input`,
  `resume_agent`, `wait_agent`, and `close_agent`; the local TUI now carries a
  basic in-process v1 runtime where `spawn_agent` runs a child turn and returns
  a UUID v7-shaped agent id, `wait_agent` reports the completed child status,
  `send_input` can continue an existing child, `close_agent` marks it shutdown,
  `resume_agent` reopens a shutdown child for follow-up input, and `/agent`
  lists created agents. Local TUI,
  app-server loaded threads, and `mcp-server` `codex-reply` sessions keep this
  runtime in memory across turns; non-stateful turns without a runtime do not
  advertise the subagent tools. Child turns strip parent-scoped callbacks before
  running so child plan/goal/tool progress cannot mutate the parent thread.
  `spawn_agent` exposes Rust-shaped inherited-model guidance and bundled
  model/reasoning/service-tier override summaries in its model-facing tool
  description, applies requested service-tier child overrides, and non-forked
  spawns also apply requested model and reasoning-effort overrides with bundled
  model-catalog defaulting/validation, including unsupported inherited
  service-tier filtering. Full-history forks still reject `agent_type`, model,
  and reasoning-effort overrides like Rust. `spawn_agent` and `send_input`
  structured `items` now pass text plus URL-backed `image`, readable
  `local_image`, registered local `skill`, and structured `mention` content into child
  turns while retaining Rust-shaped previews for `/agent` listings; unreadable
  local images become model-visible read-error placeholders instead of aborting
  the tool call, readable registered skills become Rust-shaped `<skill>` user
  fragments, unregistered skill paths become model-visible read-error
  placeholders, and mentions are preserved as explicit model-visible targets.
  This local runtime still rejects `agent_type` role overrides until that Rust
  behavior is implemented rather than silently dropping it.
  Rust's background concurrent execution, persisted subagent threads, picker
  navigation, thread switching, lifecycle notifications/hooks, full model-catalog
  dynamic cache/remote fallback for child overrides, role config, full
  app/plugin activation from mention items, and v2 runtime behavior remain part
  of the broader subagent runtime bucket.
- Basic local TUI `/skills` and `/hooks` list views are covered: `/skills`
  lists discovered repo/user/plugin skills with enabled state and load errors,
  and `/hooks` lists discovered lifecycle command hooks with event, source,
  enabled/trust state, matcher/status details, warnings, and load errors.
  Richer Rust popup UI, `$`/`@` insertion flow, skills enable/disable
  management, hook trust toggles, hook event drill-downs, startup hook review,
  and active-turn hook rendering remain in the TUI lifecycle/depth buckets.
- Local `/goal` basic set/view/edit-hint/clear/pause/resume handling is covered
  in the Zig TUI when the `goals` feature is enabled, and non-empty
  `/btw <prompt>` is covered as a side-conversation alias. Richer goal
  picker/editor flows, budget accounting, active-turn integration, remote
  goal-store parity, and empty side-conversation UI parity remain under the
  active-turn and session-store buckets.
- Replace the simple slash-command handling with Rust-like command popup and
  argument flows where they materially affect usability: model picker,
  permissions picker, keymap flow, plan flow, status/title pickers, session
  pickers, file mentions, skill mentions, and attached image handling during
  queued commands.
- Fill rich transcript/rendering gaps that users see during real work:
  command cells, approval overlays, hook events, MCP cells, plan cards,
  markdown/diff rendering, resize behavior, and richer inline/alternate-screen
  layout.

### Root CLI Command and Flag Coverage

- Basic `codex doctor` command routing is implemented in Zig with Rust-shaped
  help, human output, JSON top-level fields, grouped check rows, and
  `--json`, `--summary`, `--all`, `--no-color`, `--ascii`, `-c/--config`,
  `--enable`, and `--disable` parsing, plus real `rg` readiness probing,
  Rust-shaped install context details for package-layout and standalone release
  installs, package-manager provenance details, inherited package-manager env
  suppression for dev builds, PATH entry reporting, npm global-root mismatch
  diagnostics, package-layout bundled `rg` detection
  through `codex-path`, standalone bundled `rg` detection through
  `codex-resources`, custom-CA env path validation, config-backed `log_dir` and
  `sqlite_home` reporting, read-only runtime SQLite DB integrity probes for
  state/log/goals, active/archived rollout file stats, standalone release-cache
  entry-count reporting for standalone installs, Rust-shaped human notes
  for large rollout storage, unrestricted sandbox/network posture, and mixed
  ChatGPT/API-key auth signals, bounded active-provider HTTP reachability probes
  for the base URL and provider models route, bounded Responses WebSocket
  handshake probes for provider-enabled `responses` endpoints with
  auth-mode/header diagnostics plus immediate close-frame code/reason warnings,
  and passive app-server daemon mode, pid, settings, update-loop path, and
  control-socket reachability reporting. Doctor-local
  `--strict-config` is rejected like Rust while root `--strict-config doctor` remains supported.
  Remaining doctor parity is exact diagnostic depth: minor install-provenance
  edge-case wording/status details and richer live background-daemon probes are
  deeper than the current bounded Zig checks.
- Root interactive/resume/fork, exec, and review support for
  `--strict-config` is implemented for user `config.toml` unknown fields and
  `-c/--config` unknown override fields, including unknown feature keys,
  nested MCP/provider fields, Rust-supported `doctor`, `mcp-server`,
  `app-server`, and `exec-server` propagation, root unsupported-subcommand
  rejection, and app-server subcommand rejection. Remaining strict-config depth
  is full config-layer coverage across every user/project/system/managed layer.
- Root and command-local feature config overrides now materialize into runtime
  feature overrides for the user-visible CLI surfaces that accept feature
  controls, including interactive/resume/fork, exec, review, apply, cloud,
  sandbox, doctor, plugin, remote-control, and app-server daemon flows. This
  covers flat `-c features.artifact=true`, nested `.enabled` leaves such as
  `features.multi_agent_v2.enabled=true`, and inline TOML tables such as
  `-c 'features={"artifact"=true}'` and
  `-c 'features={network_proxy={enabled=true}}'`; unknown flat boolean feature
  keys are ignored while invalid scalar or unsupported nested feature config
  payloads fail instead of being silently dropped. `features.apps_mcp_path_override.path`
  is now ported for persistent config and runtime `-c` overrides, including the
  host-owned `codex_apps` MCP URL consumer. Deeper Rust feature payloads such as
  `features.network_proxy.*` settings and non-toggle `multi_agent_v2` settings
  remain planned until their runtime consumers are ported.
- Root runtime surfaces now support current Rust `--profile
  <CONFIG_PROFILE_V2>` overlay semantics for interactive runs, `exec`,
  `review`, `resume`, `fork`, `mcp`, `sandbox`, and `debug prompt-input`;
  `exec --profile` also works locally. Unsupported subcommands reject the flag
  with the Rust-shaped runtime-scope error, obsolete `--profile-v2` is rejected,
  and overlay names are validated as Rust-style plain names instead of accepting
  path-like config filenames. Selecting an overlay name that still exists as a
  legacy `[profiles.NAME]` section in the base user config now rejects like
  Rust.
- Root and exec `--dangerously-bypass-hook-trust` parsing is implemented, and
  app-server plus non-interactive exec/review hook execution now runs enabled
  untrusted/modified hooks for that invocation while preserving disabled hook
  state.
- Root `help exec <subcommand>`, `help debug <subcommand>`,
  `help mcp <subcommand>`, `help plugin <subcommand>`, and
  `help cloud <subcommand>` now delegate to nested subcommand help for the
  implemented command families, matching Rust's nested `help` behavior on those
  surfaces.
- Unknown bare top-level names now follow Rust's prompt fallback instead of
  being treated as removed commands, including stale names such as
  `marketplace`. The common prompt-like `NAME --help|--version` forms also
  behave as root global flags before the fallback prompt launches, valid root
  interactive options after the prompt-like name are consumed as options, and
  extra bare arguments or unknown flags after a prompt-like name are rejected
  instead of being joined into a synthetic prompt.
- Root help/version handling now wins over semantic flag validation in the same
  user-visible cases as Rust, including unknown strict-config overrides,
  dangerous-bypass approval conflicts, invalid pre-help `-C` directories, and
  root remote flags on subcommand help paths.
- Root help and top-level shell completion discovery now track Rust's normal
  command surface more closely: the root help uses Rust's command-summary shape
  and no longer advertises Zig-only demo/session helper commands, while
  completions expose Rust-visible aliases plus hidden internal Rust command
  entries such as `responses-api-proxy` and `stdio-to-uds`; `help
  stdio-to-uds` now resolves like the command-local help path.
- App-server generator command discovery now matches the implemented Rust
  surface: `app-server --help` advertises `generate-ts` and
  `generate-json-schema`, generator-local `--help` prints command help, valid
  generator help tails defer root semantic checks such as invalid pre-help
  `-C` directories and root `--remote`, and missing option values such as
  `--out --help` still fail instead of printing help or writing files.
- App-server `help [COMMAND]...` routing is implemented for the root
  app-server command, `proxy`, public generator commands, hidden internal schema
  generation, `daemon`, daemon `help`, and daemon action commands. These help
  paths also defer root semantic checks before printing valid help or
  Rust-shaped invalid nested-subcommand errors with Clap-style exit status 2.
- App-server-local `-c/--config`, `--enable`, and `--disable` are accepted on
  the root app-server command, `proxy`, public generators, and hidden internal
  schema generation. Local feature/config overrides validate before execution,
  help paths skip unknown feature/config validation while preserving missing
  value errors, and local `-c` overrides are forwarded to daemon child launches.

### App-Server Daemon and Remote Control

- `codex app-server daemon` now exposes the Rust command family and covers
  safe no-daemon behavior plus live PID-backed daemon lifecycle when the
  managed standalone Codex path exists: `start`, `restart`, `stop`, and
  `version` spawn, probe, report, and terminate a real Unix-socket app-server.
  `bootstrap` reports the missing managed standalone install when absent, and
  when the managed path exists it writes daemon settings, replaces the managed
  app-server, starts the hidden PID-backed updater loop, supports
  `--remote-control`, and returns Rust-shaped `bootstrapped` JSON with
  `autoUpdateEnabled`, daemon path/version, socket path, CLI version, and
  running app-server version. `enable-remote-control` / `disable-remote-control` write
  `app-server-daemon/settings.json`, report running managed daemon metadata,
  and restart the managed daemon when the setting changes. Daemon command
  `-c/--config` and `--enable`/`--disable` options are forwarded into newly
  spawned managed app-server processes and preserved across setting-change
  restarts of that managed process. Remaining daemon exact-depth parity is the
  updater loop's live standalone installer refresh/reexec behavior.
- `codex remote-control start` now drives the managed daemon path when the
  standalone managed install exists: it enables the daemon remote-control
  setting, starts or reuses the PID-backed app-server, sends
  `remoteControl/enable` over the control socket, and prints Rust-shaped JSON
  or human readiness output with daemon app-server path/version details.
  `remote-control stop` routes through the daemon stop lifecycle and reports
  Rust-shaped JSON or human text. `app-server --remote-control` now reports
  `connecting`, includes remote-control identity fields backed by the persisted
  `CODEX_HOME/installation_id` UUID in status notifications, handles
  `remoteControl/enable|disable|status/read`, and
  exposes `remote_control` as enabled through app-server feature APIs.
  Normal config loading also creates/reuses the same persisted installation UUID
  instead of falling back to the old Zig placeholder.
  Remaining remote-control parity is the full Rust websocket/cloud connection
  backend behind the reported connecting status.
- App-server permission-profile coverage is implemented for desktop clients:
  `permissionProfile/list` returns Rust's three built-in permission profile ids
  first, includes system/user/trusted-project/legacy-managed
  `[permissions.<id>]` profiles with optional descriptions sorted by id,
  preserves layer precedence for duplicate profile ids, honors system or user
  project trust with user override, bounds discovery at Rust-style
  project-root markers (`project_root_markers`, default `.git`), skips
  explicitly untrusted child project layers, includes trusted project-local
  profiles when `cwd` is provided, honors linked-worktree main-root trust,
  supports cursor/limit pagination, and emits
  Rust-shaped invalid-cursor errors. `thread/start` and `turn/start`
  permission-profile selection accept Rust's profile-id string wire shape, use
  the same layer stack, and accept Rust's `:workspace_roots` filesystem key in
  supported root-read profiles while returning protocol-level `project_roots`
  entries.
- Close app-server active-turn feature gaps needed by desktop clients:
  real async turns, durable active-turn tracking, interruption, steering,
  server-request dispatch, remaining lifecycle notification depth, and
  non-stdio deferred command responses.

### Plugin CLI and TUI User Flows

- CLI `codex plugin add`, `codex plugin list`, and `codex plugin remove` are
  implemented for configured local/git-backed marketplace snapshots and
  Rust-compatible personal HOME marketplace roots,
  including `PLUGIN@MARKETPLACE` and `--marketplace` selectors, Rust-shaped
  listing tables, local plugin cache install, config enablement, and local
  cache/config removal. The plugin and plugin marketplace command families now
  accept Rust-visible `-c/--config`, `--enable`, and `--disable` options before
  or after the subcommand, with feature-gate overrides, help preflight, and
  missing-value behavior aligned to Rust; root and plugin-local config
  overrides now flow into marketplace source and plugin enabled-state config for
  list/add/marketplace-list surfaces. CLI `codex plugin marketplace list` lists
  configured and home marketplace roots, including roots whose plugin entries
  are filtered out or empty. Remaining CLI plugin parity is remote catalog/cache
  synchronization and full remote/plugin cache behavior.
- Implement richer TUI `/plugins` management and richer `/apps` flows,
  reusing the existing app-server plugin/app runtime where possible.
- App-server remote plugin share checkout is now implemented for the Rust
  `plugin/share/checkout` JSON-RPC method: it requires the `plugin_sharing`
  feature, validates Rust-shaped remote plugin IDs, checks out shared workspace
  bundles into the user's personal HOME plugin root, updates the personal
  marketplace manifest, records remote-to-local share mappings, and preserves
  local edits on repeated checkout.
- Close user-visible app-server plugin gaps that remain after CLI/TUI routing:
  remote catalog cache synchronization, plugin cache update parity, app auth
  lookups, and exact remote/local cache behavior.

## P1 Gaps

### Sessions, Threads, Resume, and Fork

- Bring resume/fork/list/read/archive/unarchive/rollback behavior closer to
  Rust state DB behavior. Local `thread/list` now covers active-vs-archived,
  provider/source/cwd/search, pagination, status, default interactive source
  filtering including Rust's `atlas`/`chatgpt` custom interactive sources,
  Rust structured custom/subagent source metadata from rollout files and local
  SQLite rows, source response shapes, and relative cwd normalization; remaining
  work is remote thread-store behavior and deeper state-DB/schema fidelity.
- Add richer resume/fork picker UI in the TUI, including Rust-like grouping,
  filtering, selected row details, cwd display, and remote/imported session
  handling.
- Implement remote thread-store read/list/archive/unarchive/name/metadata
  behavior where user-visible desktop or remote-control flows depend on it.
- Improve transcript fidelity for restored turns, tool outputs, local images,
  skill mentions, compaction, interrupted turns, and token usage attribution.

### MCP User Flows

- Implement thread-owned MCP runtime reuse instead of one-shot snapshots where
  Rust keeps live server state.
- Add persistent streamable HTTP server notification streams, progress,
  cancellation, startup/reload status accuracy, queued manager refreshes, and
  live status updates.
- Finish MCP server tool-call lifecycle parity through both model tools and
  app-server requests, including elicitation, approvals, errors, and
  notification ordering.
- Keep macOS keychain-backed OAuth behavior aligned with Rust, including edge
  cases around `auto` and `keyring` credential-store modes.

### Config and Requirements That Affect Users

- Finish full user/project/system/managed config-layer behavior for fields that
  affect CLI, TUI, tools, MCP, plugins, app-server, hooks, and sandboxing.
- Finish exact strict-config validation behavior across all config layers and
  command surfaces that Rust supports.
- Finish exact profile-overlay edge-case depth beyond the current user-config
  overlay on Rust runtime surfaces, especially where it intersects with the
  broader unfinished config-manager layer stack.
- Finish managed/cloud requirements enforcement for approval policy, reviewer,
  sandbox, network, hooks, apps, plugins, features, and residency where those
  requirements change user-visible behavior.

### Sandbox and Tool Permission Features

- Finish macOS custom permission-profile enforcement beyond the currently
  supported root/glob cases: narrow read allowlists, managed requirements,
  network allow-list policy, network proxy behavior, and recursive descendant
  denial tracking.
- Align command/tool approval flows with Rust for additional permission
  requests, auto-review denials, and guardian retry behavior.

### Cloud and Desktop Features

- Complete the remaining cloud task flows behind `codex cloud`: task creation,
  status/list, apply, diff, and TUI picker behavior against the current backend
  contract.
- Finish desktop app and remote-control user flows beyond launching/opening:
  phone fork/share flow, durable daemon control, and local browser controller
  parity.

## P2 Gaps

### Completion, Help, and Error Polish

- Bring nested completion output closer to Rust for all user-facing
  command/flag surfaces after the command set is complete.
- Normalize help/error behavior for implemented commands, especially hidden
  commands, aliases, and command-specific usage text.
- Finish hiding or documenting remaining Zig-only compatibility/helper commands
  outside normal Rust parity discovery surfaces.

### Debug and Diagnostic Tools

- Keep `debug models`, `debug prompt-input`, and `debug app-server` aligned
  with Rust behavior.
- Decide whether Zig-only `debug clear-memories` remains visible, hidden, or is
  aligned with the Rust hidden debug surface.
- Implement `doctor` before investing further in lower-value debug polish,
  because `doctor` is the visible user diagnostic entrypoint in Rust.

### Cross-Platform Feature Tail

- Linux and Windows sandbox command implementations are outside the macOS-first
  goal, but the commands should keep returning clear Rust-compatible
  unsupported-platform behavior until those platforms become in scope.
- Cross-platform keyring backends are outside the macOS-first feature goal
  unless they affect macOS `auto`/`keyring` behavior.

## Current Working Order

1. Root CLI command/flag parity: finish doctor diagnostic depth and remaining
   exact strict-config/profile-overlay edge-case depth.
2. Live app-server daemon lifecycle and remote-control command forms.
3. Active-turn/TUI lifecycle: interruption, steering, queued input, process
   tracking, and lifecycle notifications.
4. TUI slash-command feature gaps: remaining rich popup commands.
5. Rich plugin/app TUI management plus remaining remote/cache depth.
6. Session/thread store parity needed by resume/fork and desktop clients.
7. MCP lifecycle depth.
8. Cloud task feature completion.

This order favors visible feature holes before deeper exact-behavior polish.
