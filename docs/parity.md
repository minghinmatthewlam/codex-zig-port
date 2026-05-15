# Codex CLI Parity Tracker

Status values:

- `planned`: not implemented in Zig yet
- `partial`: implemented enough for a demo or narrow flow
- `covered`: implemented and verified against the affected product surface

Current app-server `hooks/list` coverage: user `$CODEX_HOME/config.toml`,
`$CODEX_HOME/hooks.json`, per-cwd `.codex/config.toml`, and per-cwd
`.codex/hooks.json` command hooks, Rust-shaped `cwds` params and JSON fields,
default command timeouts, source metadata, user `hooks.state` enable/trust
metadata from inline and table TOML shapes, malformed `hooks.json` warnings, and
mixed `hooks.json` / TOML representation warnings, plus `[features].hooks`
gating. Enabled local plugin-cache command hooks are listed when `[features]`
enables `plugins` and `plugin_hooks`. Managed hooks and full config-layer parity
remain planned.

Current app-server `config/read` coverage includes user `tools` config for
`[tools.web_search]` `context_size`, `allowed_domains`, inline `location`, and
`[tools]` `view_image`, including user origins/layers and the Rust-compatible
ignored bool-only `[tools] web_search = true` shape. Trusted project tool
layers now cover the same supported fields with project-over-user leaf
precedence. System tool layers now cover those supported fields below
user/project layers, including bool-only user web-search fallthrough to lower
system tool fields. Legacy managed tool layers now cover those supported
fields above user/project/system layers, including array-root replacement and
nested web-search fallthrough.

Current app-server `config/read` coverage also includes first-level user
`[apps.NAME]` config for `enabled`, `destructive_enabled`,
`open_world_enabled`, `default_tools_approval_mode`, and
`default_tools_enabled`, plus user `[apps._default]` `enabled`,
`destructive_enabled`, and `open_world_enabled` defaults, including user
origins/layers. Per-app `[apps.NAME.tools.TOOL]` `enabled` and
`approval_mode` overrides are also returned with user origins/layers. Trusted
project and system app layers now cover the same supported fields with
project-over-user-over-system precedence, including per-app tool fallthrough,
origins, and layer reads. Legacy managed app layers now cover those supported
fields above user/project/system layers, including per-app tool fallthrough,
origins, and layer reads.

Current app-server `config/read` coverage also includes user
`sandbox_workspace_write` settings for table and inline-object TOML shapes:
`writable_roots`, `network_access`, `exclude_tmpdir_env_var`, and
`exclude_slash_tmp`, including user origins/layers and post-`config/batchWrite`
reads. Legacy managed config reads now cover top-level `model`,
`approval_policy`, `sandbox_mode`, `web_search`, `model_reasoning_effort`, and
`service_tier`, plus managed `sandbox_workspace_write` leaf precedence over
user roots and booleans. Trusted project
`sandbox_workspace_write` reads now cover table and inline-object TOML shapes
with project-over-user leaf precedence across nested project stacks. System
config reads now cover the same supported scalar fields as trusted project
config (`model`, `approval_policy`, `sandbox_mode`, `web_search`,
`model_reasoning_effort`, and `service_tier`) plus table-form
`sandbox_workspace_write`, with system-below-user and system-below-project leaf
precedence. Layer reads also preserve required empty user and system layers
when the corresponding config files are absent.

Current app-server `config/read` scalar coverage also includes
`forced_chatgpt_workspace_id` and `forced_login_method` in the effective config,
origins, and user/project/system/legacy-managed layers, matching the account
login validation surface.

Current app-server TypeScript and JSON Schema generation coverage includes the
minimal JSON-RPC envelope, client-notification, and initialize helper files plus
top-level primitive TypeScript helpers for IDs, modalities, reasoning,
verbosity, and web-search config plus top-level fuzzy-file-search TypeScript
artifacts, and top-level legacy conversation-summary, git-diff/auth-status
TypeScript artifacts. It
also covers command-exec request, response, follow-up, terminal-size,
sandbox-policy, permission-profile, active/selection/overlay
permission-profile helpers, filesystem-path helper, absolute-path,
network-access, and output-delta notification artifacts,
experimental process request, response, terminal-size, stream, and lifecycle
notification artifacts,
concrete turn envelope artifacts for `Turn`, `TurnStatus`, `TurnItemsView`,
`TurnError`, `CodexErrorInfo`, `NonSteerableTurnKind`, and turn
start/completion payloads with permissive `ThreadItem` contents,
`ErrorNotification` artifacts and the top-level server-notification `"error"`
variant, `ThreadClosedNotification` artifacts and the top-level
server-notification `"thread/closed"` variant, plus diagnostic
warning/notice notification artifacts for `WarningNotification`,
`GuardianWarningNotification`, `DeprecationNoticeNotification`, and
`ConfigWarningNotification` with `TextPosition` / `TextRange` helpers, plus
`WindowsWorldWritableWarningNotification`, hook run summary artifacts, and
`HookStartedNotification` / `HookCompletedNotification` server-notification
artifacts, plus turn diff/plan update notification artifacts, item-stream plan,
command-execution, file-change, reasoning delta, and context-compaction
notification artifacts, raw response-item notification artifacts, server-request,
MCP progress/startup-status, and remote-control status notification artifacts,
approval auto-review notification artifacts, and model reroute/verification
notification artifacts, plus thread realtime notification artifacts,
model-provider capabilities read artifacts, thread token-usage notification
artifacts, collaboration-mode list and collaboration-agent helper artifacts, and
model-list catalog artifacts,
app-list catalog artifacts, marketplace/plugin request, response, detail, share,
source, policy, and marketplace helper TypeScript artifacts, config/review
client-request TypeScript artifacts, config read/write/requirements TypeScript artifacts
including app-tool config, managed-hook requirements, and network requirements
helpers,
server-request TypeScript artifacts, plus
experimental-feature list/enablement artifacts,
memory-reset response, memory citation, Git info, command execution
source/status, patch-apply status, hook metadata/error/prompt-fragment,
skill metadata/scope/error, MCP status alias, model, session-source,
web-search action, review-start response, and thread helper artifacts,
git-diff-to-remote and fuzzy-file-search JSON Schema artifacts,
hooks-list artifacts, skills list/config artifacts, account
read/auth/login/refresh/rate-limit/nudge artifacts, filesystem RPC artifacts,
MCP config reload artifacts, and MCP server status artifacts, in standalone
files and the bundled schema `$defs`.
For TypeScript file names, the Zig generator covers the complete Rust-named
`app-server-protocol/schema/typescript` set observed in the adjacent Rust
checkout at comparison time; the remaining Zig-only files are compatibility
aliases or legacy artifacts, not Rust-missing files.
For JSON Schema file names, the Zig generator now emits `v1/` initialize
aliases and `v2/` aliases for every implemented flat schema that already
matches a Rust versioned filename, while preserving flat compatibility outputs.
It also emits the current top-level aggregate JSON Schema artifacts for
`ClientRequest`, `ServerRequest`, `ServerNotification`, and
`DynamicToolCallResponse`.
MCP server status JSON Schema generation includes both the Zig-native
`McpServerStatusList*` names and Rust-compatible `v2/ListMcpServerStatus*`
aliases.
Review-start and MCP-refresh JSON Schema generation now includes
`v2/ReviewStartParams`, `v2/ReviewStartResponse`, and
`v2/McpServerRefreshResponse`.
Config JSON Schema generation now includes the `v2/ConfigRead*`,
`v2/ConfigWriteResponse`, `v2/ConfigValueWriteParams`,
`v2/ConfigBatchWriteParams`, and `v2/ConfigRequirementsReadResponse`
artifacts, with opaque config values where full config-manager schema parity is
still planned.
Marketplace and plugin JSON Schema generation now includes the remaining
`v2/Marketplace*` and `v2/Plugin*` request/response artifacts, including plugin
list/read/install/share shapes and marketplace add/remove/upgrade shapes.
Full Rust generator parity remains planned.

Current app-server stdio/Unix/websocket JSON-RPC handling accepts well-formed
standalone client response and error envelopes for server-request replies and
ignores unmatched request IDs until full pending server-request tracking is
implemented. Unix-socket and websocket app-server listeners keep accepting
sequential clients after a client disconnects, including connection-local
subscription cleanup, the direct `unix://` listener, default control socket,
app-server proxy, and hidden stdio-to-UDS relay smoke paths.

Additional app-server error-notification generation coverage: the generated
TypeScript and JSON Schema artifacts now include `ErrorNotification` with
`TurnError`, `willRetry`, `threadId`, and `turnId`, exported through `v2/index.ts`
and included in the top-level `ServerNotification` `"error"` union variant.
Synchronous `turn/start` provider failures now also emit `"error"` notifications
with `willRetry: false`; retrying stream errors and the full async failed-turn
notification lifecycle remain planned.

Additional app-server warning-notification generation coverage: generated
TypeScript and JSON Schema artifacts now include `WarningNotification`,
`GuardianWarningNotification`, `DeprecationNoticeNotification`,
`ConfigWarningNotification`, `WindowsWorldWritableWarningNotification`,
`TextPosition`, and `TextRange`, exported through `v2/index.ts` and included in
the top-level `ServerNotification` `"warning"`, `"guardianWarning"`,
`"deprecationNotice"`, `"configWarning"`, and
`"windows/worldWritableWarning"` union variants. Runtime emission for those
warning and notice notifications mostly remains planned; runtime emission is
now covered for `deprecationNotice` on deprecated
`experimental_instructions_file` config and legacy feature keys, and for
generic `warning` notifications on config-enabled under-development features
and deprecated `on-failure` approval-policy configuration during app-server
thread startup, plus user/plugin hook-load warnings during app-server thread
startup. Runtime `configWarning` emission is covered on app-server
`initialize` for untrusted project-local `.codex` folders whose config, hooks,
and exec policies are disabled until the project is trusted, and for trusted
project-local config files that contain unsupported root keys ignored for
safety. It also covers malformed user and trusted project-local execpolicy
rules with Rust-shaped `"Error parsing rules; custom rules not applied."`
summaries while leaving untrusted project-local rules quiet; other Rust
config-warning sources remain planned.

Additional app-server hook-notification generation coverage: generated
TypeScript and JSON Schema artifacts now include `HookExecutionMode`,
`HookOutputEntryKind`, `HookOutputEntry`, `HookRunStatus`, `HookScope`,
`HookRunSummary`, `HookStartedNotification`, and `HookCompletedNotification`.
They are exported through `v2/index.ts` and included in the top-level
`ServerNotification` `"hook/started"` and `"hook/completed"` union variants.
Runtime emission for hook lifecycle notifications remains planned.

Additional app-server turn-update notification generation coverage: generated
TypeScript and JSON Schema artifacts now include `TurnDiffUpdatedNotification`,
`TurnPlanStepStatus`, `TurnPlanStep`, and `TurnPlanUpdatedNotification`,
exported through `v2/index.ts` and included in the top-level
`ServerNotification` `"turn/diff/updated"` and `"turn/plan/updated"` union
variants. Runtime `turn/plan/updated` emission is now covered for
app-server `turn/start` turns that receive a model-requested `update_plan`
tool call through the shared session loop. Runtime `turn/diff/updated`
emission is now covered for app-server `turn/start` turns that run a
successful model-requested `apply_patch` edit in a git-backed loaded thread
cwd, including opt-out handling. Broader diff timing and plan-update timing
parity remain planned.

Additional app-server item-stream notification generation coverage: generated
TypeScript and JSON Schema artifacts now include `PlanDeltaNotification`,
`CommandExecutionOutputDeltaNotification`, `TerminalInteractionNotification`,
`FileChangeOutputDeltaNotification`, `PatchChangeKind`, `FileUpdateChange`, and
`FileChangePatchUpdatedNotification`, exported through `v2/index.ts` and
included in the top-level `ServerNotification` `"item/plan/delta"`,
`"item/commandExecution/outputDelta"`,
`"item/commandExecution/terminalInteraction"`,
`"item/fileChange/outputDelta"`, and `"item/fileChange/patchUpdated"` union
variants. Runtime `item/commandExecution/outputDelta` emission is now covered
for the model-visible output from model-requested shell tools during app-server
`turn/start`. Runtime `item/commandExecution/terminalInteraction` emission is
now covered for successful model-requested `write_stdin` calls during app-server
`turn/start`. Runtime `item/fileChange/patchUpdated` emission is now covered
for successful model-requested `apply_patch` edits during app-server
`turn/start`. Runtime emission for the remaining current item-stream
notifications remains planned; the legacy file-change output-delta notification
is generation-covered for source compatibility even though the Rust app server
no longer emits it.

Additional app-server raw response-item notification generation coverage:
generated TypeScript and JSON Schema artifacts now include
`RawResponseItemCompletedNotification`, exported through `v2/index.ts` and
included in the top-level `ServerNotification`
`"rawResponseItem/completed"` union variant. The generated TypeScript surface
also includes the top-level `ResponseItem` union and helper artifacts for
content items, function-call outputs, local shell calls, reasoning items,
resources, settings, and tools. Runtime `rawResponseItem/completed` emission is
now covered for raw `response.output_item.done` items observed during
app-server `turn/start` turns through the shared session loop, including
opt-out handling. JSON Schema parity and runtime coverage for the full raw
response-item graph remain planned.

Additional app-server model-notification generation coverage: generated
TypeScript and JSON Schema artifacts now include `ModelRerouteReason`,
`ModelReroutedNotification`, `ModelVerification`, and
`ModelVerificationNotification`, exported through `v2/index.ts` and included in
the top-level `ServerNotification` `"model/rerouted"` and
`"model/verification"` union variants. Runtime emission is now covered for
Responses HTTP response headers or stream-reported model headers that differ
from the requested model, and for `response.metadata`
`openai_verification_recommendation` entries observed during app-server
`turn/start`.

Additional app-server reasoning and compaction notification generation coverage:
generated TypeScript and JSON Schema artifacts now include
`ReasoningSummaryTextDeltaNotification`,
`ReasoningSummaryPartAddedNotification`, `ReasoningTextDeltaNotification`, and
`ContextCompactedNotification`, exported through `v2/index.ts` and included in
the top-level `ServerNotification` `"item/reasoning/summaryTextDelta"`,
`"item/reasoning/summaryPartAdded"`, `"item/reasoning/textDelta"`, and
`"thread/compacted"` union variants. Runtime emission for the deprecated
`thread/compacted` notification is now covered after successful loaded-thread
`thread/compact/start` compactions. Runtime emission is now covered for
`item/reasoning/summaryPartAdded`, `item/reasoning/summaryTextDelta`, and
`item/reasoning/textDelta` events observed during app-server `turn/start`
Responses streams. Broader reasoning item lifecycle parity remains planned.

Additional app-server control/status notification generation coverage: generated
TypeScript and JSON Schema artifacts now include
`ServerRequestResolvedNotification`, `McpToolCallProgressNotification`,
`McpServerStartupState`, `McpServerStatusUpdatedNotification`,
`RemoteControlConnectionStatus`, and
`RemoteControlStatusChangedNotification`, exported through `v2/index.ts` and
included in the top-level `ServerNotification` `"serverRequest/resolved"`,
`"item/mcpToolCall/progress"`, `"mcpServer/startupStatus/updated"`, and
`"remoteControl/status/changed"` union variants. Runtime emission is now
covered for `mcpServer/startupStatus/updated` starting, ready, and failed
notifications while app-server `turn/start` discovers configured MCP tools.
Runtime emission is also covered for `item/mcpToolCall/progress` calling and
completed notifications around configured MCP tools invoked during app-server
`turn/start`. Runtime emission for the remaining control/status notifications
remains planned.

Additional app-server server-request generation coverage: generated TypeScript
artifacts now include the top-level `ServerRequest` union for
`"item/commandExecution/requestApproval"`,
`"item/fileChange/requestApproval"`, `"item/tool/requestUserInput"`,
`"mcpServer/elicitation/request"`, `"item/permissions/requestApproval"`,
`"item/tool/call"`, `"account/chatgptAuthTokens/refresh"`,
`"applyPatchApproval"`, and `"execCommandApproval"`. The request-side helper
artifacts cover legacy patch and exec approval params, command/file/permission
approval request params, dynamic tool-call params, request-user-input question
and option params, network approval/policy helpers, and the MCP elicitation
request envelope. JSON Schema generation now includes the legacy
`ApplyPatchApprovalParams` and `ExecCommandApprovalParams` helper files plus
the v2 command/file/permission approval, dynamic tool-call, request-user-input,
and MCP elicitation request param helper files. Stable-client filtering is
covered for `item/commandExecution/requestApproval.additionalPermissions` when
a command-approval server request is rendered. Runtime handling for these
request surfaces remains planned.

Additional app-server dynamic/MCP helper generation coverage: generated
TypeScript artifacts now include dynamic tool-call output, response, status,
and tool-spec helpers plus MCP auth, refresh, call status, call error, and call
result helpers, all exported through `v2/index.ts`. Runtime dynamic-tool and
MCP lifecycle behavior remains planned.

Additional app-server server-request response generation coverage: generated
TypeScript and JSON Schema artifacts now include legacy
`ApplyPatchApprovalResponse`, `ExecCommandApprovalResponse`, `ReviewDecision`,
root network policy helper types, and v2 response helpers for command-execution
approvals, file-change approvals, request-user-input answers, permissions
approvals, and MCP elicitations.

Additional app-server MCP elicitation schema generation coverage: generated
TypeScript artifacts now include the full v2 `McpElicitation*` primitive helper
graph used by form-mode `mcpServer/elicitation/request` payloads, including
string, number, boolean, single-select, multi-select, titled enum, and legacy
enum schema helpers. Runtime elicitation dispatch and JSON Schema parity remain
planned.

Additional app-server approval auto-review notification generation coverage:
generated TypeScript artifacts now include the Guardian review/action helper
types plus `ItemGuardianApprovalReviewStartedNotification` and
`ItemGuardianApprovalReviewCompletedNotification`. JSON Schema artifacts include
the two notification payloads with embedded Guardian review/action definitions,
and the top-level `ServerNotification` union now covers
`"item/autoApprovalReview/started"` and
`"item/autoApprovalReview/completed"`. Runtime emission for approval
auto-review notifications remains planned.

Additional app-server realtime notification generation coverage: generated
TypeScript and JSON Schema artifacts now include
`ThreadRealtimeStartedNotification`, `ThreadRealtimeItemAddedNotification`,
`ThreadRealtimeTranscriptDeltaNotification`,
`ThreadRealtimeTranscriptDoneNotification`,
`ThreadRealtimeOutputAudioDeltaNotification`, `ThreadRealtimeSdpNotification`,
`ThreadRealtimeErrorNotification`, and `ThreadRealtimeClosedNotification`,
exported through `v2/index.ts` and included in the top-level
`ServerNotification` `"thread/realtime/started"`,
`"thread/realtime/itemAdded"`, `"thread/realtime/transcript/delta"`,
`"thread/realtime/transcript/done"`, `"thread/realtime/outputAudio/delta"`,
`"thread/realtime/sdp"`, `"thread/realtime/error"`, and
`"thread/realtime/closed"` union variants. Runtime emission for realtime
notifications remains planned.

Additional app-server account generation coverage: `account/read`,
`getAuthStatus`, `account/login/start`, `account/login/cancel`,
`account/logout`, `account/rateLimits/read`,
`account/sendAddCreditsNudgeEmail`, `account/login/completed`,
`account/rateLimits/updated`, and `account/updated` now have generated
TypeScript and JSON Schema artifacts for OpenAI auth modes, ChatGPT plan types,
API key / ChatGPT / Bedrock account variants, refresh params, legacy auth-token
status responses, login/cancel/logout envelopes, ChatGPT auth-token refresh
payloads, rate-limit snapshots, add-credits nudge request/status payloads, and
account notification payloads.

Additional account login validation coverage: app-server `account/login/start`
now loads `forced_login_method` and `forced_chatgpt_workspace_id` from the
effective config, rejects disabled API-key, ChatGPT, and external
ChatGPT-token login attempts with Rust-shaped invalid-request errors, and
rejects external ChatGPT auth tokens that target the wrong forced workspace.
It also preserves Rust's externally managed auth guard by rejecting API-key,
browser, and device-code login attempts while external ChatGPT auth tokens are
active. Browser and device-code active ChatGPT login flows remain planned.

Additional app-server filesystem generation coverage: `fs/readFile`,
`fs/writeFile`, `fs/createDirectory`, `fs/getMetadata`, `fs/readDirectory`,
`fs/remove`, `fs/copy`, `fs/watch`, `fs/unwatch`, and `fs/changed` now have
generated TypeScript and JSON Schema artifacts for absolute path params, base64
payloads, empty mutation responses, metadata responses, directory entries, watch
params/responses, and change-notification payloads.

Additional app-server hooks generation coverage: `hooks/list` now has generated
TypeScript and JSON Schema artifacts for optional `cwds` params, response
entries, hook errors, command hook rows, event/source/trust enums, and the
current Rust-shaped `data` response envelope.

Additional app-server skills generation coverage: `skills/list`,
`skills/config/write`, and `skills/changed` now have generated TypeScript and
JSON Schema artifacts for list params, per-cwd extra roots, skill metadata,
interface and dependency blocks, list errors, config write params/responses, and
the empty change-notification payload.

Additional app-server MCP status generation coverage: `mcpServerStatus/list`
now has generated TypeScript and JSON Schema artifacts for cursor, limit, and
detail params, paginated `data` / `nextCursor` responses, MCP server rows with
`name`, raw stdio and streamable HTTP tool snapshots, raw stdio and streamable
HTTP resource/resource-template snapshots in full detail mode, empty
resource/resource-template snapshots in `toolsAndAuthOnly` mode, and Rust-shaped
`authStatus` enum values for unsupported, not-logged-in, bearer-token, and OAuth
states. Strict live refresh and status notifications remain planned.

Additional app-server MCP resource coverage: `mcpServer/resource/read` now has
generated TypeScript and JSON Schema artifacts for optional nullable `threadId`,
required `server` / `uri` params, shared text/blob `ResourceContent`, and
`contents` responses. The runtime supports config-backed stdio and streamable
HTTP MCP resource reads without a thread or with an already-loaded `threadId`,
uses bearer-token env vars or file-backed OAuth access tokens for HTTP servers
when configured, includes configured static and env-backed HTTP headers,
reuses `Mcp-Session-Id` response headers after HTTP
initialize, sends best-effort streamable HTTP session teardown requests, validates
missing/invalid params, preserves Rust-shaped invalid/missing thread errors, and
returns unavailable errors for disabled servers. MCP server JSON-RPC errors are
forwarded with their original code, message, and data payload. Streamable HTTP
JSON-RPC requests can also receive responses from GET SSE streams after accepted
POSTs. True thread-owned MCP runtime context and persistent streamable HTTP
server notification streams remain planned.

Additional app-server MCP tool-call coverage: `mcpServer/tool/call` now has
generated TypeScript and JSON Schema artifacts for required `threadId`,
`server`, and `tool` params, optional `arguments` and `_meta`, and Rust-shaped
tool result fields. The runtime validates loaded thread ids, injects the
loaded `threadId` into object `_meta`, calls config-backed stdio and
streamable HTTP MCP tools, and passes object and non-object JSON `arguments`
through to the MCP server while preserving `content`, `structuredContent`,
`isError`, and `_meta` responses. Streamable HTTP calls include configured
static and env-backed HTTP headers, reuse `Mcp-Session-Id` response headers
after initialize, and send best-effort session teardown requests. Streamable
HTTP requests can receive JSON-RPC responses from
GET SSE streams after accepted POSTs, and MCP server JSON-RPC errors are
forwarded with their original code, message, and data payload. True thread-owned
MCP runtime reuse, persistent streamable HTTP server notification streams,
elicitation, and progress remain planned.

Additional app-server MCP OAuth-login coverage: `mcpServer/oauth/login` now has
generated TypeScript and JSON Schema artifacts for required `name`, optional
nullable `scopes`, optional nullable `timeoutSecs`, and `authorizationUrl`
responses plus `mcpServer/oauthLogin/completed` notifications. The runtime
validates request shape, missing configured servers, and non-streamable HTTP
servers with Rust-shaped errors. The actual browser OAuth login flow remains
planned and currently returns an explicit not-implemented error for configured
streamable HTTP servers.

Additional CLI MCP OAuth coverage: `codex-zig mcp login NAME` now validates
configured servers, streamable HTTP transport requirements, and
comma-separated `--scopes` values before returning an explicit not-implemented
browser-flow error for configured streamable HTTP servers. `codex-zig mcp
logout NAME` validates configured streamable HTTP servers and removes matching
file-backed OAuth credentials from `$CODEX_HOME/.credentials.json` using
Rust's fallback credential key format, and on macOS also deletes matching
keychain-backed credentials from service `Codex MCP Credentials` for
`mcp_oauth_credentials_store = "auto"` or `"keyring"`. `codex-zig mcp list`
reports Rust-shaped auth-status labels and JSON enum names for stdio,
bearer-token, file-backed OAuth, macOS keychain-backed OAuth, and HTTP
OAuth-discovery not-logged-in servers. Browser OAuth login completion,
cross-platform keyring backends, and full app-server OAuth login completion
remain planned.

Additional model-facing MCP coverage: Responses turns now advertise configured
stdio and streamable HTTP MCP tools plus the `list_mcp_resources`,
`list_mcp_resource_templates`, and `read_mcp_resource` function tools. The
runtime lists resources and templates from configured stdio and streamable HTTP
MCP servers, supports explicit-server pagination cursors, aggregates all enabled
stdio and streamable HTTP servers when no server is specified, reads
config-backed stdio and streamable HTTP resources, discovers streamable HTTP
tool specs, executes streamable HTTP tool calls with bearer-token or file-backed
OAuth auth, reuses `Mcp-Session-Id` response headers within each streamable HTTP
client operation, includes configured static and env-backed HTTP headers, sends
best-effort session teardown requests, forwards MCP server JSON-RPC errors with
their original code, message, and data payload, and loops the resulting outputs
back through the shared session tool path. Streamable HTTP requests can receive
JSON-RPC responses from GET SSE streams after accepted POSTs. Persistent
streamable HTTP server notification streams and true thread-owned MCP runtime
reuse remain planned.

Current app-server `command/exec` coverage includes buffered command execution,
capture-time independent stdout/stderr output-cap truncation, disabled output
caps, timeout exit-code responses with captured pre-timeout output,
`streamStdoutStderr` output-delta notifications, stdio app-server deferred
command sessions with client-supplied `processId`, active `command/exec/write`
stdin streaming, macOS PTY-backed `tty` command sessions with output deltas and
active `command/exec/resize`, and active `command/exec/terminate` handling,
plus Rust-shaped validation for
request environment merge/override/null-unset behavior, negative
`timeoutMs` values, output-cap/timeout disable conflicts, streaming `processId`
requirements, terminal size rows and columns, and
`command/exec/write|terminate|resize` follow-up params. Buffered execution also
accepts supported Rust-shaped `permissionProfile` payloads using
`fileSystem`, `network.enabled`, and `globScanMaxDepth` for disabled,
root-read-only, managed-unrestricted, project-roots workspace-write, absolute
writable-root, and external profiles, with command-cwd sandbox rooting for
project roots.
Supported `externalSandbox` policies also run through the explicit unsandboxed
external-sandbox path. Unsupported
profile entries return explicit not-implemented errors rather than weakening
sandbox behavior. Permission-profile network policy is enforced for supported
macOS sandbox-backed managed profiles, including enabled and restricted network
smoke coverage; `sandboxPolicy.networkAccess` is enforced for supported
read-only/workspace-write policies, including the Rust-shaped default network
deny, and workspace-write `sandboxPolicy` temp-root defaults plus
`excludeTmpdirEnvVar` / `excludeSlashTmp` flags are enforced; implicit
config-driven workspace-write command execution uses the same default temp
roots. Non-stdio deferred command responses, non-stdio PTY lifecycle routing,
and full Rust async command session parity remain planned. Inactive follow-up
calls still return Rust-shaped inactive-process errors. Empty `processId` values
on follow-up calls preserve Rust validation order: payload/size errors win
first, otherwise the inactive-command error includes the empty id.

Current app-server experimental `process/*` coverage includes generated
TypeScript and JSON Schema artifacts for `process/spawn`,
`process/writeStdin`, `process/kill`, `process/resizePty`,
`process/outputDelta`, and `process/exited`. Runtime coverage supports
synchronous non-PTY `process/spawn` execution with required absolute `cwd`,
environment merge/override/null-unset behavior, default/null/explicit output
caps, default/null/explicit timeouts, Rust-shaped negative timeout validation,
post-response `process/outputDelta` notifications for `streamStdoutStderr`, and
post-response `process/exited` notifications for non-stdio transports. Stdio
app-server runtime coverage also supports active async `process/spawn` sessions
for `streamStdoutStderr`, `streamStdin`, and macOS `tty`, active
`process/writeStdin`, duplicate active-handle rejection, active `process/kill`,
active `process/resizePty`, streamed process output deltas, and process-exit
notifications. Unix-socket and websocket transports reject process
stdin/TTY sessions with an explicit stdio-only error while still supporting
synchronous non-PTY process execution. Empty
`processHandle` values on follow-up calls preserve Rust validation order:
payload/size errors win first, otherwise the inactive-process error includes
the empty handle. Non-stdio async process lifecycle routing and broader Rust
process lifecycle polish remain planned.

Current app-server Windows sandbox RPC coverage includes generated TypeScript
and JSON Schema artifacts for `windowsSandbox/readiness`,
`windowsSandbox/setupStart`, `windowsSandbox/setupCompleted`, setup modes, and
readiness states. Runtime coverage returns Rust-shaped non-Windows readiness
(`notConfigured`) and accepts setup-start requests by returning `{ started:
true }` before emitting a post-response `windowsSandbox/setupCompleted`
notification with the Rust-shaped non-Windows setup failure for the requested
mode. Full Windows setup execution, config persistence, and Windows readiness
state detection remain planned.

Current app-server `feedback/upload` coverage includes generated TypeScript and
JSON Schema artifacts for `FeedbackUploadParams` and
`FeedbackUploadResponse`. Runtime coverage validates the request object,
required `classification` and `includeLogs` fields, optional nullable
`reason`, `threadId`, `extraLogFiles`, and `tags`, Rust-shaped UUID validation
for `threadId`, and `[feedback].enabled = false` rejection with the Rust
configuration error. Enabled feedback requests now build and send a
Sentry-compatible envelope with event classification, level, reason, reserved
tag protection, optional generated `no-active-thread-<uuid>` thread IDs,
cached-auth `account_id` and `chatgpt_user_id` metadata when available,
SQLite-backed `codex-logs.log` content from the root and currently loaded
descendant thread IDs when `includeLogs` is true, state-DB open/closed spawned
descendant thread discovery for feedback logs, loaded and state-DB-resolved
root/descendant thread rollout JSONL attachments, root saved-session rollout
fallback, Rust-shaped proxy environment connectivity diagnostics, and readable
de-duplicated `extraLogFiles` attachments.
The smoke suite proves the upload path against a local Sentry DSN override
(`CODEX_TEST_FEEDBACK_SENTRY_DSN`) rather than sending test reports to the
production DSN, and seeds Rust-shaped `logs_2.sqlite` rows to verify scoped and
latest-process threadless feedback logs are attached. It also seeds
`state_5.sqlite` `thread_spawn_edges` and `threads.rollout_path` rows to verify
persisted open and closed descendants are included, and sets `HTTPS_PROXY` to
verify `codex-connectivity-diagnostics.txt` is attached only when logs are
included. Full Rust feedback ring-buffer capture and guardian rollout
attachment collection remain planned.

| Rust surface | Zig status | Notes |
| --- | --- | --- |
| `cli` base interactive command | partial | First milestone launches `codex-zig` interactive loop, accepts an optional initial prompt, rejects unknown top-level flags, supports `--` before prompt text, exposes `help [COMMAND]`, includes top-level `apply` / `a`, includes `remote-fork CODE` for Rust-compatible local HTTP fork-claim imports, includes `update` help, Rust-compatible debug-build rejection, and release-build install-method detection for npm, bun, Homebrew, and standalone layouts, includes `app [PATH]` help plus macOS Codex Desktop open/install command parity, includes `exec-server --listen stdio` with a Rust-shaped JSON-RPC `initialize` response, non-tty `process/start`, `process/read`, `process/write`, and `process/terminate` lifecycle, plus explicit partial-parity errors for resume handshakes, tty processes, envPolicy, default websocket, and remote registration modes, includes hidden `responses-api-proxy` loopback forwarding for `POST /v1/responses` with stdin bearer auth, server-info output, HTTP shutdown, streaming response forwarding, and JSON dump output with sensitive-header redaction, recognizes planned Rust top-level commands (`remote-control`, `cloud` / `cloud-tasks`) with explicit not-implemented errors, rejects the removed Rust top-level `marketplace` namespace, and supports global `-m/--model`, `-i/--image`, `--enable`, `--disable`, `--oss`, `--local-provider`, `-p/--profile`, `-c/--config`, `-a/--ask-for-approval`, `-s/--sandbox`, `-C/--cd`, `--add-dir`, `--search`, `--remote`, `--remote-auth-token-env`, `--remote-control`, `--remote-control-bind`, `--no-alt-screen`, `--version`, and `--yolo` overrides, including Rust-compatible rejection when dangerous bypass is combined with an explicit approval policy. Remote app-server flags and local remote-control flags are parsed and rejected for non-interactive subcommands; `--remote unix://PATH` plus loopback `--remote ws://HOST:PORT` run a minimal remote TUI against an app-server for new text/local-image turns, remote resume/fork pickers, `resume --last`, explicit `resume TARGET`, explicit `fork ID|PATH`, `fork --last`, and websocket capability-token auth through `--remote-auth-token-env`; and `--remote-control` starts a minimal local HTTP controller with `/api/state` plus controller-only `/api/message` prompt submission into the running TUI. `wss://` remote TUI and the full Rust phone UI/SSE/fork surface remain planned. Full command behavior parity is planned. |
| `tui` terminal UI | partial | Current UI is a simple terminal surface with composer/transcript/tool status, alternate-screen enter/leave by default with `--no-alt-screen` inline mode, streamed assistant text deltas, `!COMMAND` local shell execution, and local `/help`, `/init`, `/compact`, `/status`, `/debug-config`, `/keymap`, `/plan`, `/title`, `/statusline`, `/theme`, `/personality`, `/rename`, `/model`, `/fast`, `/permissions`, `/approval`, `/sandbox`, `/history`, `/mention`, `/side`, `/rollout`, `/sessions`, `/diff`, `/copy`, `/raw`, `/vim`, `/mcp`, `/ps`, `/stop`, `/clean`, `/logout`, `/review`, `/clear`, `/new`, `/resume`, `/fork`, `/quit`, and `/exit` commands. `scripts/tui_e2e.py` drives the rebuilt binary in a pseudo-terminal against a mock Responses server for top-level `-i/--image` initial-prompt attachments, interactive help/status, effective config display with local config-source status, keymap listing/debug, plan-mode requests that omit tools and render `<proposed_plan>` blocks without leaking tags, `update_plan` checklist rendering with `task-progress` status/title items, ordered terminal-title item rendering with OSC output/clearing and persistence to `[tui].terminal_title`, text-mode status-line item previews and persistence to `[tui].status_line`, syntax-theme listing/selection and persistence to `[tui].theme`, personality listing/selection and persistence with request instructions, persisted thread renaming and session-list title display, service-tier toggling, last-response copying, raw output toggling, Vim mode toggling, pending file mentions injected into API requests, ephemeral `/side` turns that leave the main transcript unchanged, MCP status, explicit local shell commands, model and permissions updates, history rendering, approved `exec_command` and `apply_patch` calls, real file creation in a temporary workspace, background terminal cleanup through `/clean`, fresh-launch preference loading, and API request coverage. Full Rust config layer stack rendering, configurable keymaps, rich alternate-screen layout, transcript overlay, slash popup, resize behavior, true syntax highlighting, rich plan implementation picker UI, rich status/title picker UI, and snapshots are planned. |
| `login` / local auth reuse | partial | Reads `$CODEX_HOME/auth.json` / `~/.codex/auth.json`, ChatGPT bearer token, ChatGPT account header, refreshes expired ChatGPT access-token JWTs or auth last refreshed more than 8 days ago with stored refresh tokens, supports Rust-compatible browser callback login, `agent_identity` access-token auth, API-key fallback, `CODEX_ACCESS_TOKEN`, `login status`, `login --with-api-key`, `login --with-access-token`, `login --device-auth`, and file-backed `logout`. Workspace restrictions, token-exchange API key persistence, OAuth revoke, keyring storage, and full refresh error taxonomy are planned. |
| `core` Responses agent loop | partial | Sends Responses API requests, appends discovered `AGENTS.md` / `AGENTS.override.md` project docs to instructions, can expose the native `web_search` tool in cached/live mode, advertises configured stdio and streamable HTTP MCP tools as function tools, exposes model-facing stdio and streamable HTTP MCP resource tools (`list_mcp_resources`, `list_mcp_resource_templates`, and `read_mcp_resource`), exposes built-in `update_plan`, parses text deltas and function calls, optionally streams text deltas to callers, loops tool output back, and supports manual TUI compaction into a continuation summary. Automatic compaction, remote compaction protocol parity, rollout persistence, model catalog, goals, subagents, and advanced prompts are planned. |
| `tools` shell execution | partial | Supports minimal `exec_command`, `write_stdin`, `shell`, and `shell_command` calls with approval policy decisions, cwd/workdir, timeout, stdout/stderr capture, truncation, PTY-backed `tty=true` sessions on macOS, Rust-shaped unified exec yield-time bounds including configurable empty `write_stdin` background-terminal polls, and macOS `sandbox-exec` wrapping for read-only/workspace-write shell processes. Full PTY lifecycle polish, hooks, and unified exec lifecycle events are planned. |
| `config` | partial | Resolves Codex home, installation id, model/base URL, `model_provider` with `[model_providers.<name>].base_url`, provider `wire_api`, provider `env_key`, provider `experimental_bearer_token`, provider `query_params`, provider `http_headers` / `env_http_headers`, and section-form or inline-table command auth including `refresh_interval_ms`, `approval_policy`, `sandbox_mode`, `web_search`, `model_reasoning_effort`, `service_tier`, `[tui].theme`, `[tui].status_line`, `[tui].terminal_title`, `[tui].alternate_screen`, legacy `syntax_theme`, `personality`, `oss_provider`, `background_terminal_max_timeout`, supported custom `[permissions]` profiles, and active profile selection from env/config. Model-facing CLI paths use configured provider env-key, bearer-token, or command-backed auth before stored Codex auth; the CLI smoke verifies `exec` sends the provider env-key token to the configured provider base URL, routes `wire_api = "responses"` to `/responses`, appends configured provider query params to the request URL, attaches configured static and env-backed provider headers, rejects removed `wire_api = "chat"` before issuing a request, uses section-form plus inline command-auth stdout as a bearer token, caches command-auth tokens while fresh, proactively reruns command auth after `refresh_interval_ms`, reruns command auth after a 401 and retries with the refreshed token, and rejects Rust-invalid command-auth conflicts. Supports top-level `profile`, `[profiles.<name>]`, global `--profile`, `exec --profile`, `exec --ignore-user-config`, and Rust-compatible `-c/--config key=value` for supported scalar fields the Zig port currently understands. App-server config writes accept optional `filePath` only when it resolves to the user `config.toml`, reject non-user absolute paths, and return Rust-shaped `okOverridden` metadata when supported user scalar writes are masked by legacy managed config. Full TOML config stack, full custom permissions-profile enforcement, full project config stack, full override metadata, and full managed/cloud requirements enforcement are planned. |
| `features` | partial | Supports `codex-zig features list` with the current Rust feature keys, stages, default states, simple `[features]` boolean overrides from `config.toml`, profile-scoped `[profiles.NAME.features]` overrides, Rust legacy aliases such as `collab` / `memory_tool` mapped onto canonical effective feature state, root/list-local runtime `--enable/--disable FEATURE` overrides, root app-server feature overrides through `experimentalFeature/list` and `config/read`, and `features enable|disable FEATURE` writes to either the top-level `[features]` table or profile-scoped feature table when root `--profile NAME` is set. Direct root enables of under-development feature keys print the Rust-shaped unstable warning, while profile-scoped enables stay quiet; root disables of direct default-off feature keys clear the key instead of pinning `false`. App-server thread startup now emits Rust-shaped `warning` notifications for config-enabled under-development features, honors `suppress_unstable_features_warning = true`, and emits `deprecationNotice` notifications for legacy feature keys in config. Managed requirements remain planned. |
| `execpolicy` | partial | Supports `codex-zig execpolicy check --rules PATH COMMAND...` with repeated `-r/--rules` files, `--pretty`, Rust-shaped `matchedRules` / `prefixRuleMatch` JSON, strictest matched decision selection, `prefix_rule(pattern = [...], decision = "...", justification = "...", match = [...], not_match = [...])`, shell-string and token-array example validation scoped to the declaring `prefix_rule` with host executable resolution enabled, `network_rule(host = "...", protocol = "...", decision = "...", justification = "...")` parsing and validation, `host_executable(name = "...", paths = [...])`, `--resolve-host-executables` basename fallback gated by host executable allowlists, string tokens, nested token alternatives, default `allow` decisions, no-match responses without a top-level decision, and command-specific help. App-server `initialize` emits `configWarning` notifications for malformed user-level and trusted project-local `.rules` files while keeping untrusted project-local rules suppressed. The CLI smoke runs the rebuilt binary against temporary policy files and verifies forbidden `git push` output, valid and invalid `match` / `not_match` examples including cross-rule validation failures, valid and invalid `network_rule` parsing, plus resolved `/usr/bin/git status` output. Full Starlark evaluation, additional execpolicy builtins, and full config-layer execpolicy parity are still planned. |
| `completion` | partial | Supports `codex-zig completion [bash|elvish|fish|powershell|zsh]`, defaulting to bash, with Zig-native completion script generation for the current port command surface. `zig build e2e` runs the rebuilt binary and compares exact generated output for all supported shells against committed snapshots. Byte-for-byte clap completion parity is still planned. |
| `mcp` | partial | Supports `codex-zig mcp list|get|add|remove` for global `$CODEX_HOME/config.toml` stdio and streamable HTTP server entries, including JSON output for list/get with streamable HTTP `http_headers` and `env_http_headers`, `mcp get` masked human display for static headers, `mcp list` auth-status reporting for stdio, bearer-token, file-backed OAuth, macOS keychain-backed OAuth, and HTTP OAuth-discovery not-logged-in servers, and enabled local plugin-cache `.mcp.json` entries when plugins are enabled. Runtime stdio and streamable HTTP MCP tool discovery and `tools/call` execution work through the shared Responses session loop, model-facing stdio and streamable HTTP MCP `list_mcp_resources`, `list_mcp_resource_templates`, and `read_mcp_resource` calls work through the shared session loop, streamable HTTP MCP clients include configured static/env HTTP headers, reuse `Mcp-Session-Id` response headers after initialize, can receive JSON-RPC responses from GET SSE streams after accepted POSTs, and send best-effort session teardown requests, app-server `mcpServerStatus/list` includes raw tool, resource, and resource-template snapshots for configured stdio and streamable HTTP servers, app-server `mcpServer/resource/read` can read text/blob resources from configured stdio and streamable HTTP MCP servers without a thread or after validating an already-loaded `threadId`, app-server `mcpServer/tool/call` can call config-backed stdio and streamable HTTP MCP tools for already-loaded threads with thread-id `_meta` injection and object/non-object argument pass-through, `codex-zig mcp login` validates configured server, streamable HTTP, and `--scopes` shape before returning the current explicit browser-flow not-implemented error, and `codex-zig mcp logout` removes matching file-backed OAuth credentials plus macOS keychain-backed OAuth credentials for configured streamable HTTP servers. `codex-zig mcp-server` exposes a stdio MCP server with `initialize`, `ping`, `tools/list`, and `tools/call` for `codex` plus in-process `codex-reply` thread continuation, including per-call `model`, `cwd`, `approval-policy`, and `sandbox` handling. Browser OAuth login completion, cross-platform keyring backends, live plugin MCP startup/tool discovery, elicitation, true thread-owned MCP runtime reuse, persistent streamable HTTP server notification streams, and exact MCP server parity are planned. |
| `plugin marketplace` | partial | Supports `codex-zig plugin marketplace add` for local marketplace directories and git marketplace sources, including GitHub shorthand normalization, `--ref`, sparse paths, manifest validation, `$CODEX_HOME/.tmp/marketplaces` installs, `$CODEX_HOME/config.toml` mutation, and already-added reporting; supports `upgrade [NAME]` for configured Git marketplaces with remote revision checks, installed-root replacement, `last_revision` config updates, `.codex-marketplace-install.json` metadata, already-up-to-date reporting, and per-marketplace failure reporting; supports `remove` for configured marketplace tables or installed cache roots. App-server `marketplace/add`, `marketplace/remove`, and `marketplace/upgrade` cover the same local and git-backed marketplace config mutation behavior, and app-server `plugin/list` lists configured local marketplace roots, local repo/home marketplace manifests, local and basic git plugin sources, manifest metadata, installed/enabled state from `$CODEX_HOME`, feature gating, invalid marketplace load errors, absolute-cwd validation, and remote `chatgpt-global`, `workspace-directory`, and `shared-with-me` catalogs from the configured ChatGPT backend with installed/enabled state, pagination, installed-only global entries, default remote feature gating, explicit marketplace-kind handling, and auth/error fallback to local-only results. App-server `plugin/read` reads marketplace-backed local plugin summary metadata, manifest descriptions, skills with config-driven enabled state, command hook summaries, app ids, and MCP server names, and reads remote plugin details from the configured ChatGPT backend with catalog metadata, remote source summaries, installed/enabled state, disabled remote skills, basic app-id summaries, and workspace share context. App-server `plugin/skill/read` validates remote marketplace/plugin/skill params, requires ChatGPT-style auth, fetches remote skill Markdown from the configured ChatGPT backend, and returns Rust-shaped `contents`. App-server `plugin/share/save` archives local workspace plugin shares, requests upload URLs, uploads gzip tar payloads, finalizes shares with discoverability and targets, and records local path mappings; `plugin/share/list` lists created workspace shares with installed state and local path mappings; `plugin/share/updateTargets` updates share targets and returns Rust-shaped principals; and `plugin/share/delete` deletes remote shares plus local path mappings. App-server local `plugin/install` installs local and git-backed marketplace sources, including `git-subdir` sparse checkouts, into the plugin cache, persists enabled config entries, and returns Rust-shaped auth-policy responses. App-server remote `plugin/install` fetches detail with bundle download URLs, rejects disabled or unavailable plugins, downloads gzip tar bundles over HTTPS or explicit loopback test URLs, rejects unsafe archive paths and symlinks, writes versioned cache entries, posts the ChatGPT backend install mutation, and returns Rust-shaped auth-policy responses. App-server local `plugin/uninstall` validates Rust-shaped local plugin ids, removes the local plugin cache root, clears the matching config table and child tables, and is idempotent. App-server remote `plugin/uninstall` fetches detail for the cache namespace, posts the ChatGPT backend uninstall mutation, validates disabled mutation responses, and removes current plus legacy local cache roots. Full marketplace update/cache parity, remote catalog cache synchronization, product-gated local detail parity, full app auth lookups, and full plugin cache parity are planned. |
| `apply-patch` | partial | Exposes an `apply_patch` function tool with approval and a Zig-native parser for add, update, delete, move-to, multiple hunks, EOF markers, padded markers, no-newline replacements, blank context lines, Rust-compatible leading blank update spacers, Rust-compatible heredoc-wrapped patch arguments, Rust-compatible root-local absolute add/update/delete/move paths, Rust-compatible `@@ context` search-window disambiguation, Rust-compatible `*** End of File` tail-only matching, Rust-compatible fuzzy line matching after exact matching fails, including trailing-whitespace, trimmed-whitespace, and normalized Unicode punctuation/odd-space matches, Rust-compatible `Add File` overwrite behavior for existing regular files, early missing/trailing end-patch rejection before filesystem mutation, early empty-update hunk rejection before target file reads, early malformed marked-update hunk rejection, and delete-hunk body rejection before filesystem mutation. The PTY TUI E2E verifies an approved model-requested add-file patch creates the expected file on disk. Full grammar and fixture parity are still planned. |
| `apply` ChatGPT task diffs | partial | Supports `codex-zig apply TASK_ID` and alias `codex-zig a TASK_ID`, loads backend ChatGPT or agent-identity auth, fetches `/wham/tasks/TASK_ID`, extracts the first PR `output_diff.diff`, and applies it in the current repository root with `git apply --3way`. `zig build e2e` verifies the rebuilt CLI against a mock ChatGPT task backend and temporary git repository. Rust's detailed `codex_git_utils` result parsing, conflict path summaries, revert/preflight helpers, and deeper fixture parity are planned. |
| `exec` non-interactive mode | partial | Supports `codex-zig exec` and visible Rust-compatible alias `codex-zig e` with `[--auto-approve] [--ephemeral] [--skip-git-repo-check] [--ignore-user-config] [--ignore-rules] [-c key=value] [--color MODE] [-m MODEL] [--oss] [--local-provider NAME] [-p PROFILE] [-a MODE] [-s MODE] [-C DIR] [--add-dir DIR] [--json] [-o FILE] [--output-last-message FILE] [--output-schema FILE] [-i IMAGE] [PROMPT|-]`, Rust-compatible equals forms for long options including `--approval-policy=MODE` and `--output-last-message=FILE`, root exec prompt reads from piped stdin when no prompt is provided, prompt-plus-piped-stdin root exec appends stdin in Rust-compatible `<stdin>` context markup, non-interactive exec and `exec review` refuse non-Git working directories unless `--skip-git-repo-check` or dangerous bypass is set, dangerous bypass conflicts with explicit approval-policy flags, hidden Rust-compatible `--full-auto` migration warning, `codex-zig exec resume [--all] [last|ID|PATH] PROMPT` using the shared session/tool loop with exec options accepted after `resume`, and `codex-zig exec review ...` dispatch to the shared review command after applying exec-level `--cd` and runtime overrides. Full event parity, image resizing/normalization, and additional Rust exec flags are planned. |
| `review` non-interactive mode | partial | Supports `codex-zig review --uncommitted`, `codex-zig review --base BRANCH`, `codex-zig review --commit SHA [--title TITLE]`, custom review instructions from argv or `-` stdin, trusted Git-repository checks, and Rust-shaped `codex-zig exec review ...` routing through the shared Responses turn path. Structured review JSON and full Rust review event parity are planned. |
| `debug` | partial | Supports `codex-zig debug prompt-input [-i FILE] [PROMPT]` to render the model-visible Responses input list without making an API call, including local image attachments, `codex-zig debug models [--bundled]` for a Zig-native model catalog snapshot, and `codex-zig debug clear-memories` to clear `$CODEX_HOME/memories`, `$CODEX_HOME/memories_extensions`, `stage1_outputs`, and memory pipeline `jobs` rows while preserving root directories, symlink-root protections, and unrelated state-db jobs. Hidden `debug trace-reduce [-o FILE] TRACE_BUNDLE` writes Rust-shaped reduced `state.json` for stable rollout lifecycle, thread lifecycle, Codex turn lifecycle, inference lifecycle metadata, and raw payload refs from local trace bundles. `debug app-server send-message-v2 USER_MESSAGE` now spawns the local app-server over stdio, initializes the experimental client, starts a thread, sends a `turn/start` text message, prints JSON-RPC responses and notifications, and waits for the matching `turn/completed` notification. Online model refresh, full Rust app-server debug-test client option parity, full rollout conversation/tool/code-cell/compaction/agent trace reduction, and byte-for-byte reducer parity are planned. |
| `sandbox` macOS seatbelt | partial | Parses `read-only`, `workspace-write`, and `danger-full-access`; shell processes run through `/usr/bin/sandbox-exec` on macOS for read-only/workspace-write, `--add-dir` expands workspace-write shell writable roots, and `codex-zig sandbox macos|seatbelt [OPTIONS] -- COMMAND` exposes the same Zig seatbelt wrapper from the CLI. Rust-compatible `sandbox linux|landlock` and `sandbox windows` platform subcommands are recognized at parse time and return explicit unsupported-platform errors in the current port; sandbox `--full-auto` is rejected as a removed option. Rust permission-profile sandbox flags are parsed and validated, including `-C/--cd` and `--include-managed-config` requiring `--permissions-profile`; the built-in `:read-only`, `:workspace`, and `:danger-no-sandbox` profiles are applied to macOS sandbox construction from the CLI; and custom `[permissions]` profiles that lower to the current root-read/workspace-write seatbelt model are applied, including project-root and absolute writable roots plus full network enable/disable. The macOS-only Rust `--allow-unix-socket` and `--log-denials` flags are parsed and return explicit unsupported errors instead of being treated as unknown flags or silently ignored. Full custom profile filesystem enforcement for narrow reads and deny entries, restricted custom-profile network allow-list policy, managed requirements enforcement, network proxy policy, and full socket/denial logging parity are still planned. In-process `apply_patch` still uses conservative preflight/path checks instead of process sandboxing. |
| `resume` / `fork` / session store | partial | Writes Zig-native JSONL transcripts under `$CODEX_HOME/sessions/zig/`, starts `codex-zig resume` and `codex-zig fork` with numbered pickers, supports `resume --last`, `resume --all`, `resume --include-non-interactive`, `fork --last`, `fork --all`, `resume|fork [ID|PATH|last]`, `remote-fork CODE` imports Rust-compatible protocol-version-1 local HTTP claim bundles into `$CODEX_HOME/sessions/remote-forks/` and starts a TUI fork from the imported thread ID, Rust-compatible interactive overrides after `resume` / `fork` / `remote-fork` such as model, profile, cwd, images, approval policy, sandbox mode, OSS provider, remote flags, local remote-control flags, and no-alt-screen, and `codex-zig exec resume --all ...`, lists saved sessions through `codex-zig sessions [N]` and `/sessions [n]`, and supports `/resume` and `/fork` inside the TUI. The shared session loader also accepts basic Rust rollout JSONL envelopes under `$CODEX_HOME/sessions/YYYY/MM/DD/` and imported remote-fork rollouts for app-server resume/fork. Full Rust rollout browsing, state-db metadata, app-server fork metadata, cwd filtering, non-interactive session filtering, and rich browsing UI are planned. |
| app server / desktop app / cloud tasks | partial | Supports `codex-zig app [PATH] [--download-url URL]` on macOS to open an existing Codex Desktop app or download/install the DMG when missing, supports `codex-zig app-server [--listen URL]`, Rust-compatible parsing for `stdio://`, `off`, `unix://`, `unix://PATH`, and `ws://IP:PORT`, accepts `--analytics-default-enabled`, parses and validates Rust-compatible websocket auth flags (`--ws-auth`, `--ws-token-file`, `--ws-token-sha256`, `--ws-shared-secret-file`, `--ws-issuer`, `--ws-audience`, `--ws-max-clock-skew-seconds`), runs JSON-RPC over stdio, Unix sockets, or websocket text frames with `initialize`, `memory/reset`, `thread/start` in-memory loaded-thread creation, `thread/resume` Zig session JSONL, basic Rust rollout JSONL, and in-memory history loading, `thread/fork` in-memory loaded-thread plus Zig-native and basic Rust rollout transcript-path forking, `thread/loaded/list` stateful loaded-thread responses, `thread/read`, `thread/list`, and `thread/turns/list` loaded-thread reads, thread metadata/lifecycle RPCs (`thread/archive`, `thread/unarchive`, `thread/rollback`, `thread/inject_items`, `thread/name/set`, `thread/memoryMode/set`, and `thread/metadata/update`), `thread/goal/set|get|clear`, `thread/approveGuardianDeniedAction`, `thread/unsubscribe` connection-local subscribed/unsubscribed/not-subscribed/not-loaded responses, and `thread/compact/start`, `thread/shellCommand`, `thread/backgroundTerminals/clean`, `thread/increment_elicitation`, and `thread/decrement_elicitation` loaded-thread validation plus implemented loaded-thread compaction, shell-command, background-terminal-clean, and elicitation-counter behavior, app-server filesystem `fs/readFile`, `fs/writeFile`, `fs/createDirectory`, `fs/getMetadata`, `fs/readDirectory`, `fs/remove`, and `fs/copy`, model catalog `model/list` over bundled picker presets, enabled local plugin app catalog `app/list`, collaboration mode presets, provider capabilities `modelProvider/capabilities/read`, account state `account/read`, legacy remote diff `gitDiffToRemote`, legacy local file search `fuzzyFileSearch`, legacy auth status `getAuthStatus`, legacy `getConversationSummary` summary lookups for loaded threads and local rollout paths, API-key and external ChatGPT-token login through `account/login/start`, login cancellation through `account/login/cancel`, account rate-limit fetches through `account/rateLimits/read`, workspace-owner nudge emails through `account/sendAddCreditsNudgeEmail`, account removal `account/logout` with `account/updated` notification, partial config reads through `config/read`, config writes through `config/value/write`, multi-edit config writes through `config/batchWrite`, system `requirements.toml` core allow-list, feature, hooks, residency, and network fields and legacy managed-config requirements through `configRequirements/read`, external-agent config detection/import through `externalAgentConfig/detect` and `externalAgentConfig/import`, experimental feature catalog `experimentalFeature/list`, process-local runtime feature enablement patches through `experimentalFeature/enablement/set`, local skill discovery through `skills/list`, skill enablement writes through `skills/config/write`, connection-local skill invalidation through `skills/changed`, accepted MCP config reload requests through `config/mcpServer/reload`, MCP server status listing through `mcpServerStatus/list`, filesystem watch registration through `fs/watch`, watch removal through `fs/unwatch`, in-process and request-boundary external mutation notifications through `fs/changed`, buffered one-off command execution through `command/exec`, synchronous experimental process execution through `process/spawn` with `process/outputDelta` and `process/exited` notifications plus stdio async `process/spawn` streamed-output, stdin, and TTY sessions with active `process/writeStdin`, `process/kill`, and `process/resizePty`, local and remote marketplace listing through `plugin/list` including configured local marketplace roots, local and remote plugin detail reads through `plugin/read`, remote plugin skill detail reads through `plugin/skill/read`, remote plugin share save, listing, target updates, and deletion through `plugin/share/save|list|updateTargets|delete`, local and remote plugin installation through `plugin/install`, local plugin cache/config removal and remote plugin uninstall mutation plus cache cleanup through `plugin/uninstall`, local and git-backed `marketplace/add`, `marketplace/remove`, and `marketplace/upgrade` config/cache mutation, and remaining `plugin/*` not-implemented responses, plus JSON-RPC errors for unsupported request methods, supports `codex-zig app-server proxy [--sock SOCKET_PATH]`, hidden `codex-zig stdio-to-uds SOCKET_PATH` for stdio-to-Unix-socket JSON-RPC relay, `codex-zig app-server generate-ts -o DIR [--experimental]` for TypeScript bindings covering initialize, command exec, process RPC, and the implemented app-server request/response surface, `codex-zig app-server generate-json-schema -o DIR [--experimental]` for JSON-RPC envelope, command-exec, process RPC, and the implemented app-server request/response schemas, and hidden `codex-zig app-server generate-internal-json-schema -o DIR` for a minimal `RolloutLine.json` schema. `gitDiffToRemote` covers closest remote SHA selection for ordinary origin-backed repos, tracked working-tree diffs, untracked file diffs, invalid params, and missing-repo errors; `fuzzyFileSearch` covers one-shot local file/directory subsequence matching, Rust-compatible ASCII path scoring/order/indices for ordinary paths, empty query results, cancellation token shape validation, invalid params, JSON field compatibility, composed/decomposed Latin accent folding with Rust-compatible character indices for UTF-8 paths, and connection-local `fuzzyFileSearch/sessionStart|sessionUpdate|sessionStop` notifications while broader Unicode normalization, request cancellation, and true async streaming are still planned; `thread/start` covers in-memory loaded-thread creation, Rust-shaped start responses, ephemeral starts, persistent rollout-path assignment, generated bindings, JSON schemas, and start/fork `thread/started` notifications with opt-out filtering while Rust state-db rollout metadata and full async turn execution parity remain planned; `thread/loaded/list` covers nullable or object params, cursor/limit shape validation, and stateful Rust-shaped `data` / `nextCursor` response fields; `thread/unsubscribe` covers `threadId` UUID validation, Rust-shaped `notLoaded` responses for unknown threads, connection-local `unsubscribed` responses for threads subscribed through start/resume/fork, and `notSubscribed` for repeat or never-subscribed loaded threads; `thread/compact/start`, `thread/shellCommand`, `thread/backgroundTerminals/clean`, `thread/increment_elicitation`, and `thread/decrement_elicitation` cover `threadId` UUID validation, Rust-shaped `thread not found` responses for unloaded threads, shell-command empty command validation, and implemented loaded-thread compaction, shell-command, background-terminal-clean, and elicitation-counter behavior; `skills/list` covers Rust-shaped params, default cwd fallback, repo/user/per-cwd extra/enabled local plugin skill roots, plugin skill name prefixing from plugin manifests, SKILL.md frontmatter name/description/shortDescription extraction, `agents/openai.yaml` interface and tool-dependency metadata, config-driven `enabled` state by name or absolute path, connection-local cwd result caching until `forceReload`, connection-local `skills/changed` cache invalidations for app-server skill-root mutations and skills config writes, invalid skill-file errors, and malformed-param errors while policy metadata, kernel-backed external skill watching, debouncing, and full multi-layer cache parity are still planned; `skills/config/write` covers name/path selector validation, disabled `[[skills.config]]` persistence in `$CODEX_HOME/config.toml`, enabled-removal toggles, and Rust-shaped `effectiveEnabled` responses; `mcpServerStatus/list` covers configured plus enabled local plugin-cache `.mcp.json` server names, sorting, pagination, `detail` validation, `resourceTemplates` casing, raw stdio and streamable HTTP tool/resource snapshots, empty resource/resource-template snapshots in `toolsAndAuthOnly` mode, and bearer-token auth status from environment variables while strict live refresh, live MCP startup, OAuth login/logout, and status notifications are still planned; `fs/watch`/`fs/unwatch` covers connection-local watch IDs, duplicate watch rejection, absolute-path validation, Rust-shaped `fs/changed` notifications for filesystem mutations made through the same app-server connection, request-boundary external change polling after direct filesystem mutations, and unwatch cleanup while kernel-backed async change detection and debouncing are still planned; `command/exec` covers buffered argv execution with stdout/stderr capture, `streamStdoutStderr` output-delta notifications for commands that run to completion, cwd and environment overrides, nonzero exit responses, output caps, timeouts, default or explicit `dangerFullAccess`/`readOnly`/`workspaceWrite` sandbox policy handling, supported `externalSandbox` policy handling, supported `permissionProfile` mappings for disabled, root-read-only, managed-unrestricted, project-roots workspace-write, absolute writable roots, and external profiles, plus explicit not-implemented responses for unsupported permission-profile entries while non-stdio deferred command responses and full command-exec lifecycle parity are still planned; `process/*` covers synchronous non-PTY `process/spawn`, output/exited notifications, output caps, timeouts, cwd/env validation, stdio async streamed-output, stdin, and TTY process sessions, active write/kill/resize follow-ups, duplicate active handles, and non-stdio stdin/TTY rejection while broader async process lifecycle parity remains planned; `model/list` covers bundled picker ordering, hidden filtering via `includeHidden`, pagination cursors, default markers, upgrade metadata, availability nux, speed-tier arrays, and configured-model isolation while online refresh/cache metadata is still planned; `app/list` covers empty no-manifest pages, enabled local plugin `.app.json` rows from plugin cache, home, and loaded-thread cwd marketplaces, simple app enabled flags, pagination cursors, optional params, and loaded-thread validation while ChatGPT connector directory loading and accessible-app merging remain planned; `collaborationMode/list` covers the built-in Plan and Default presets with Rust-shaped `mode`, `model`, and `reasoning_effort` fields; `account/read` covers no-auth, API-key, stored ChatGPT id-token metadata, external ChatGPT-token metadata, Bedrock, custom no-auth provider, and local-OSS states; `getAuthStatus` covers no-auth, API-key token inclusion/omission, stored ChatGPT access tokens, external ChatGPT auth tokens, agent identity token omission, custom no-auth providers, local-OSS, nullable params, and invalid param errors; `account/login/start` covers API-key and external ChatGPT-token login with `account/login/completed` and `account/updated` notifications; `account/login/cancel` validates login IDs and returns `notFound` while app-server ChatGPT browser and device-code active login flows are still unimplemented; `account/rateLimits/read` covers ChatGPT/agent-identity backend fetching, response mapping, no-auth/API-key rejection, and invalid params; `account/sendAddCreditsNudgeEmail` covers ChatGPT/agent-identity backend posting, `sent` and `cooldown_active` status mapping, no-auth/API-key rejection, invalid params, and backend-failure JSON-RPC errors; app-server ChatGPT browser/device-code login is planned. `config/read` currently returns the Zig port's effective core config fields, effective feature flags including profile-scoped feature overrides, Rust-shaped user `config.toml` origins for supported scalar fields, trusted project-stack `.codex/config.toml` origins/layers for supported scalar fields (`model`, `approval_policy`, `sandbox_mode`, `web_search`, `model_reasoning_effort`, and `service_tier`) and supported `tools` and `apps` fields between a trusted project root and an absolute child `cwd`, legacy managed-config scalar/tool/app/sandbox origins and layers ahead of lower-precedence layers, required empty user/system layers, system config scalar/tool/app/sandbox origins and layers below user/project layers, and project-before-user layers when `includeLayers` is true; `config/value/write` covers supported TOML key paths with scalar, array, inline-object, existing table-object merge/replace, and null-clearing values, `replace`/`upsert` validation, optional `filePath` limited to the user `config.toml`, SHA-256 `expectedVersion` conflicts, and Rust-shaped write responses; `config/batchWrite` covers multiple in-memory edits persisted with one file write plus existing table-object merge/replace, optional `filePath` limited to the user `config.toml`, SHA-256 `expectedVersion` conflicts, `reloadUserConfig` shape validation, inline-object values used by hook state writes, null-clearing values, and Rust-shaped write responses. Hot reload notifications for loaded threads, full override metadata, full config-manager validation, system/full-project/managed layer fidelity, nested-field origins, full cloud/MDM requirements, app/plugin requirement fields, and managed requirements enforcement are still planned; `configRequirements/read` reads system `requirements.toml` core allow-list fields (`allowed_approval_policies`, `allowed_approvals_reviewers`, `allowed_sandbox_modes`, `allowed_web_search_modes`), top-level `enforce_residency`, `[hooks]` managed directories and command/prompt/agent matcher groups, basic `[experimental_network]` scalar booleans and ports, canonical domain and Unix-socket permission maps, and legacy domain/socket allow-list arrays, plus `[features]` and `[feature_requirements]` booleans and then lets Rust-compatible legacy `managed_config.toml` fields `approval_policy`, `approvals_reviewer`, and `sandbox_mode` fill unset managed allow-list responses; it returns `requirements: null` when none are configured. `memory/reset` uses the same directory-clearing safety rules and SQLite row cleanup as `debug clear-memories`. `unix://` listens on `CODEX_HOME/app-server-control/app-server-control.sock`; `unix://PATH` listens on the requested socket path. `zig build e2e` launches the rebuilt binary, verifies profile-scoped features CLI and app-server behavior, and verifies stdio, memory reset, thread-start loaded-thread creation, disk-backed Zig and basic Rust rollout plus in-memory-history thread-resume loading, in-memory plus Zig-native and basic Rust rollout path thread-fork creation, stateful loaded-thread listing/read/turns-list/unsubscribe, and compact/shell-command/background-terminal-clean/elicitation-counter empty-runtime behavior, local and git-backed marketplace add/list/repeat/upgrade/remove RPC behavior, plugin-list marketplace discovery, local plugin-read details, remote plugin-list catalogs, remote plugin-read details, remote plugin-skill reads, remote plugin-share save/list/update/delete behavior, local, pinned git-subdir, and remote plugin-install cache writes, local plugin-install config writes, local plugin-uninstall cache/config cleanup, and remote plugin-uninstall cache cleanup against a mock backend, skills-list discovery/config writes/change notifications, MCP server status listing including enabled local plugin-cache `.mcp.json` entries and streamable HTTP inventory snapshots, MCP resource/tool success and JSON-RPC error forwarding for stdio, streamable HTTP POST, and streamable HTTP GET SSE responses, filesystem watch notifications including external direct-file mutation polling, filesystem RPC behavior against a temporary directory, buffered command-exec RPC behavior, process RPC behavior, model catalog, app-list enabled local plugin app catalog, collaboration-mode-list, git-diff-to-remote, fuzzy-file-search, account-read, get-auth-status, account-logout, account-login, account-login-cancel, account-rate-limits, account-add-credits-nudge, config-read including trusted project scalar/tool/app layers, required empty user/system layers, system scalar/tool/app/sandbox config precedence, and legacy managed scalar/tool/app/sandbox overrides, config-value-write including table-object merge/replace, config-batchWrite including table-object merge/replace, external-agent config detect/import migration behavior including local plugin imports, and config-requirements RPC behavior against temporary config homes including system `requirements.toml` precedence, feature requirements, hooks requirements, residency requirements, network domain/socket requirements, and legacy managed config requirements, experimental feature list and runtime enablement behavior against temporary config homes, explicit Unix socket, default Unix socket, app-server proxy, stdio-to-uds, websocket transport, TypeScript and JSON schema generation, and app-server flag-compatibility handshakes. Kernel-backed asynchronous filesystem watch notifications, broader Unicode-normalized fuzzy scoring, request cancellation, and true async fuzzy file-search streaming, remaining account RPC/login parity, remaining remote thread-store lifecycle APIs and active-turn tracking, full connector app-list parity, full config layer/origin fidelity, full external-agent config migration parity, managed config requirements enforcement, full live MCP status parity, online model refresh/cache parity, full TypeScript generation parity, full public schema parity, full internal schema parity, broader desktop app protocol parity, and cloud task flows are planned. |

Additional remote TUI slash-command coverage: remote app-server TUI sessions now
support `/status`, `/model [MODEL]`, `/fast [on|off|status]`, `/personality`,
`/sessions [N]`, `/resume [TARGET|last]`, and `/fork [TARGET|last]` against the
remote app-server thread APIs. The PTY TUI E2E covers status printing, remote
runtime override updates for model, service tier, and personality, remote
session listing, in-session remote fork, and in-session remote resume while
preserving the remote transcript history.

Additional app-server websocket transport coverage: `app-server --listen
ws://127.0.0.1:0` now binds a plain websocket listener, reports the actual
bound URL, serves `/readyz` and `/healthz` on the same listener, and exchanges
JSON-RPC requests/responses as websocket text frames. It rejects requests with
an `Origin` header and enforces `--ws-auth capability-token` from either
`--ws-token-file` or `--ws-token-sha256` against `Authorization: Bearer ...`
during upgrade. It also enforces `--ws-auth signed-bearer-token` with trimmed
shared-secret files, HS256 JWT signature verification, exp/nbf clock-skew
checks, and optional issuer/audience checks during upgrade. Sequential
websocket clients now preserve process-local loaded threads while resetting
connection-local subscriptions after disconnect. Graceful shutdown parity
remains planned.

Additional app-server config reload coverage: `config/batchWrite` honors
`reloadUserConfig` for already-loaded threads by refreshing default-derived
model, model provider, service tier, approval policy, sandbox mode, and
reasoning effort from the latest config while preserving explicit per-thread
overrides. Full hot-reload notifications and full config-manager parity remain
planned.

Additional app-server thread-start coverage: `thread/start` now creates an in-memory loaded thread, returns a Rust-shaped `ThreadStartResponse` with a full thread object, supports ephemeral starts without materializing a rollout file, gives persistent starts an absolute rollout path, feeds the created ID into `thread/loaded/list`, lets `thread/read` return the loaded thread, returns `notSubscribed` for unsubscribing a loaded but unsubscribed thread, emits a Rust-shaped `thread/started` notification after the response unless the connection opted out, includes the experimental `permissionProfile` / `activePermissionProfile` response fields only for experimental clients, and persists trusted project state for explicit elevated `cwd` starts so the same request and later starts load supported trusted `.codex/config.toml` project fields, including TOML-escaped project paths. Nested Git cwd and linked-worktree starts trust the repository root, while read-only/default starts do not persist project trust. TypeScript and JSON schema generation include the current `thread/start` request/response shape plus `ThreadStartedNotification`. Loaded-thread hot reload and full thread schema parity remain planned.

Additional app-server loaded-thread list coverage: `thread/loaded/list` now validates and canonicalizes cursors as UUIDs with Rust-shaped invalid-request errors, sorts loaded thread ids before pagination, treats missing-but-valid cursors as insertion points, clamps zero limits to one for non-empty results, and still returns an empty page before cursor validation when no threads are loaded.

Additional app-server thread unsubscribe coverage: `thread/start`, `thread/resume`, and `thread/fork` now mark the current app-server connection as subscribed to the loaded thread, so `thread/unsubscribe` returns `unsubscribed` once for that connection, `notSubscribed` after repeat unsubscribe calls, and `notLoaded` for missing loaded threads.

Additional app-server model-provider capabilities coverage: `modelProvider/capabilities/read` is included in current TypeScript and JSON schema generation with its optional params shape and Rust-shaped `namespaceTools`, `imageGeneration`, and `webSearch` response fields until broader model-provider protocol generation parity lands.

Additional app-server collaboration mode generation coverage: `collaborationMode/list` is included in current TypeScript and JSON schema generation with its optional params shape and Rust-shaped `data` entries for the built-in Plan and Default presets until broader collaboration-mode protocol generation parity lands.

Additional app-server model-list generation coverage: `model/list` is included in current TypeScript and JSON schema generation with cursor/limit/hidden params, Rust-shaped paginated `data`/`nextCursor` responses, and typed model catalog item fields for upgrade, availability nux, reasoning efforts, modalities, service tiers, and default markers until broader model catalog protocol generation parity lands.

Additional app-server app-list coverage: `app/list` validates Rust-shaped
optional `cursor`, `limit`, `threadId`, and `forceRefetch` params, returns an
empty Rust-shaped `data` / `nextCursor` page when no local plugin app manifests
are enabled, lists enabled local plugin `.app.json` manifests from plugin-cache
roots, `$CODEX_HOME` marketplaces, and already-loaded thread cwd marketplaces as
`AppInfo` rows, applies simple user `[apps._default]` / `[apps.NAME]` `enabled`
flags, paginates with
Rust-shaped `nextCursor` values and invalid-cursor errors, and includes
app-list request, response, app metadata, app summary, and `app/list/updated`
notification artifacts in TypeScript and JSON schema generation. Full ChatGPT
connector directory loading, accessible-app merging, app cache refreshes,
workspace-gated app availability, update notifications, and full config layer
fidelity remain planned.

Additional app-server experimental-feature generation coverage: `experimentalFeature/list` and `experimentalFeature/enablement/set` are included in current TypeScript and JSON schema generation with cursor/limit params, Rust-shaped paginated feature rows, runtime enablement maps, and enablement set params/responses until broader experimental feature protocol generation parity lands.

Additional app-server memory-reset generation coverage: `memory/reset` is included in current TypeScript and JSON schema generation as a no-params request with an empty Rust-shaped response object until broader app-server utility RPC generation parity lands.

Additional app-server git-diff-to-remote generation coverage: `gitDiffToRemote` is included in current TypeScript and JSON schema generation with required `cwd` params and Rust-shaped `sha`/`diff` response fields until broader legacy desktop utility RPC generation parity lands.

Additional app-server conversation-summary coverage: legacy `getConversationSummary` reads summaries for already-loaded threads by `conversationId` and local Zig/Rust rollout transcripts by `conversationId` or relative/absolute `rolloutPath`, returning Rust-shaped conversation ids, canonical paths, preview text, model provider, cwd, CLI version, session source, and git metadata when the transcript carries it. Generated TypeScript now includes the top-level session-source, conversation-summary, request, and response files plus `ClientRequest` / `ClientResponse` entries until full local/remote thread-store summary parity lands.

Additional app-server fuzzy-file-search runtime coverage: `fuzzyFileSearch` now folds common Latin accents and combining marks for composed and decomposed UTF-8 paths while returning original path character indices in result matches, matching Rust's UTF-32 matcher index contract for multibyte paths. It also honors local `.gitignore` files only when a git context exists, including common file, directory, wildcard, double-star zero-or-more-directory, negation, escaped leading `#`/`!`, escaped-space, escaped wildcard, and bracket character-class/range patterns used by Codex workspaces, while ignoring `.gitignore` files in non-git roots to match Rust's `require_git(true)` behavior. Repository-local `.git/info/exclude` files are honored for ordinary repo roots and worktree-style `.git` files with `gitdir:` plus `commondir` indirection. Global git excludes are honored from `core.excludesFile`, with fallback to XDG git ignore paths, only when a git context exists and below `.git/info/exclude` precedence. Local `.ignore` files are honored regardless of git context, with Rust-compatible precedence over `.gitignore`; `.gitignore` rules also override lower-precedence `.git/info/exclude` rules. Gitignore and git-info-exclude rules stop at nested `.git` repository boundaries while `.ignore` rules continue through those boundaries. Session updates suppress duplicate `sessionUpdated` and `sessionCompleted` notifications when a completed query is submitted again unchanged, cleared session queries emit blank snapshots, empty session ids match Rust's per-method validation behavior for start/update/stop, and concurrent session records keep independent roots and update state. Full `ignore`-crate parity for custom ignore files and remaining pattern grammar, plus broader Unicode normalization, request cancellation, and true async streaming remain planned.

Additional app-server fuzzy-file-search generation coverage: `fuzzyFileSearch`, `fuzzyFileSearch/sessionStart`, `fuzzyFileSearch/sessionUpdate`, `fuzzyFileSearch/sessionStop`, `fuzzyFileSearch/sessionUpdated`, and `fuzzyFileSearch/sessionCompleted` are included in current TypeScript and JSON schema generation with direct result files, session params/responses, match type/item shapes, and session notification payloads until broader legacy desktop utility RPC generation parity lands.

Additional app-server MCP reload generation coverage: `config/mcpServer/reload` is included in current TypeScript and JSON schema generation with optional empty-object params and an empty Rust-shaped response object until broader MCP status protocol generation parity lands.

Additional app-server ClientRequest TypeScript union coverage: generated
TypeScript now includes the Rust-side `ClientRequest` methods for
`marketplace/add`, `marketplace/remove`, `marketplace/upgrade`, `plugin/list`,
`plugin/read`, `plugin/skill/read`, `plugin/share/save`,
`plugin/share/updateTargets`, `plugin/share/list`, `plugin/share/delete`,
`plugin/install`, `plugin/uninstall`, `review/start`, `config/read`,
`config/value/write`, `config/batchWrite`, and `configRequirements/read`, plus
their current param helper artifacts and `serde_json/JsonValue`. Standalone JSON
Schema files now cover the newly typed marketplace, plugin, config, and review
request params where the protocol carries params; full Rust schema parity
remains planned.

Additional app-server external-agent config coverage: `externalAgentConfig/detect`
now validates `includeHome` and nullable/array `cwds` params, detects
home-scoped Claude `settings.json` / `settings.local.json` `CONFIG` migrations
when supported values are missing from Codex `config.toml`, detects
home-scoped `.mcp.json` / `.claude.json` MCP server migrations into Codex
`config.toml`, detects home-scoped convertible hook migrations into Codex
`hooks.json`, detects home-scoped `CLAUDE.md` to `AGENTS.md` migrations when
the target is missing or empty, detects missing home-scoped Claude skill
directories under the sibling `.agents/skills` target, detects supported
home-scoped `.claude/commands/**/*.md` command templates as generated
command-skill migrations, detects supported home-scoped `.claude/agents/*.md`
subagents as generated agent TOML migrations, resolves project `cwds` to repo
roots, detects project-scoped `.claude/settings.json` /
`.claude/settings.local.json` `CONFIG` migrations into `.codex/config.toml`,
detects project `.mcp.json` / `.claude.json` MCP server migrations into
`.codex/config.toml`, detects project `.claude/settings*.json` hook migrations
into `.codex/hooks.json`, detects repo-root or `.claude/CLAUDE.md` migrations
into repo-root `AGENTS.md`, detects missing project `.claude/skills`
directories under `.agents/skills`, detects supported project
`.claude/commands/**/*.md` command templates as generated command-skill
migrations, detects supported project `.claude/agents/*.md` subagents as
generated agent TOML migrations, and detects home- and project-scoped enabled
plugins from local `extraKnownMarketplaces` sources that are not already
enabled in Codex user config, plus recent home-scoped external-agent session
JSONL files under `${HOME}/.claude/projects` with path/cwd/title details while
skipping missing-cwd, stale, unreadable, and already-imported current-content
sessions. `externalAgentConfig/import` validates
`migrationItems`, accepts an empty no-op import with an empty Rust-shaped
response, imports home- and project-scoped `CONFIG` items by translating
supported `env` scalar values into `[shell_environment_policy.set]`, local
settings overrides, and `sandbox.enabled = true` into
`sandbox_mode = "workspace-write"` without overwriting existing target keys,
imports home- and project-scoped MCP server config for supported stdio and
streamable HTTP entries while preserving existing target keys and skipping
unsupported env-placeholder forms, imports home- and project-scoped convertible
command hooks into Codex `hooks.json` while copying hook scripts and skipping
unsupported hook groups/handlers, imports home- and project-scoped `AGENTS_MD`
by rewriting Claude terms to Codex terms, copies missing home- and
project-scoped skill directories while rewriting `SKILL.md` text, imports home-
and project-scoped command templates as `source-command-*` skills while
skipping unsupported templates, imports supported home- and project-scoped
subagents with `permissionMode` / `effort` mappings, imports detected local
plugin marketplaces into user Codex config/cache, enables the selected plugins,
imports validated session details into `$CODEX_HOME/sessions/zig` using
Rust-shaped `response_item` rows plus `task_started`, `user_message`,
`agent_message`, `token_count`, and `task_complete` rollout events, preserves
the imported session title, replays the `<EXTERNAL SESSION IMPORTED>` marker
through `thread/read`, renders imported user/assistant/import-marker items as a
single completed turn through `thread/read` and `thread/turns/list`, records the
current source hash in `external_agent_session_imports.json`, refreshes
connection-local skill discovery caches for runtime-affecting imports, then emits
`externalAgentConfig/import/completed`. TypeScript and JSON schema generation
include the detect/import request and response shapes, migration item/detail
types, and the `externalAgentConfig/import/completed` notification shape.
Background session imports, large-session compaction before first follow-up,
remote/background plugin imports, loaded-thread runtime refresh, and richer
import progress notifications remain planned.

Additional app-server thread elicitation coverage: `thread/increment_elicitation` and `thread/decrement_elicitation` now track an in-memory out-of-band elicitation counter for already-loaded threads, return Rust-shaped `count` and `paused` response fields, preserve invalid/missing thread errors, and reject decrementing a zero counter with Rust's invalid-request message. Full timeout-pause integration with live command execution remains planned.

Additional app-server thread shell-command coverage: `thread/shellCommand`
now runs non-empty commands for already-loaded threads in the thread cwd with
the user shell, persists a Rust-shaped `<user_shell_command>` contextual record
into the loaded transcript, updates the thread preview/turn list, emits active
and idle `thread/status/changed` plus turn/user-message item lifecycle
notifications, and preserves invalid/missing thread errors. Full Rust async
shell progress streaming, cancellation, and active-turn auxiliary injection
remain planned.

Additional app-server background-terminal cleanup coverage:
`thread/backgroundTerminals/clean` now terminates model-facing PTY sessions
started by `exec_command` tool calls during `turn/start` for the loaded thread,
requires the Rust-shaped `experimentalApi` initialize capability, returns the
Rust-shaped empty response, and preserves invalid and missing-thread errors
when the capability is enabled. Per-terminal metadata and full Rust async
active-process tracking remain planned.

Additional app-server experimental API gating coverage: implemented request
methods marked experimental in the Rust protocol now require
`initialize.params.capabilities.experimentalApi = true`, with Rust-shaped
`<method> requires experimentalApi capability` errors when omitted. This covers
`memory/reset`, `thread/increment_elicitation`,
`thread/decrement_elicitation`, `thread/goal/*`, `thread/memoryMode/set`,
`thread/turns/list`, `thread/realtime/*`, `thread/backgroundTerminals/clean`,
`process/*`, `collaborationMode/list`, and `fuzzyFileSearch/session*`. The
same capability gate also covers implemented Rust experimental request fields
on `thread/start`, `thread/resume`, `thread/fork`, `turn/start`, `turn/steer`,
`command/exec`, and `account/login/start`, including granular `approvalPolicy`
variants, and suppresses implemented Rust experimental server notifications
such as `thread/goal/*` and `process/*` until the client opts in. Experimental
`thread/start`, `thread/resume`, and `thread/fork` response
`permissionProfile` / `activePermissionProfile` fields are likewise hidden from
stable clients and included for experimental clients. Experimental
server-request field filtering is covered for the command-execution approval
`additionalPermissions` field; full server-request runtime dispatch remains
planned.

Additional app-server turn-start coverage: `turn/start` now accepts text, URL-backed image, localImage, skill, and mention input for a loaded thread, including turns made only of structured skill/mention items. It preserves text input item arrays, `text_elements`, image URLs, local image paths, and skill/mention name/path pairs in user-message lifecycle notifications, runs the existing Responses turn loop with the thread transcript, roots model-requested shell tools and `apply_patch` edits in the loaded thread cwd when the tool call does not provide an explicit workdir, forwards URL-backed and readable local images as `input_image` request content, converts missing local images into model-visible error placeholders, injects readable local skill files as Rust-shaped `<skill>` user fragments, updates loaded-thread preview/turns, persists persistent Zig transcripts, returns a Rust-shaped `TurnStartResponse`, emits `turn/started`, text user-message `item/started` / `item/completed`, raw Responses output items as `rawResponseItem/completed`, final assistant-message `item/started`, `item/agentMessage/delta`, `item/completed`, and `turn/completed` notifications, and includes `turn/start`, `turn/started`, `turn/completed`, `item/started`, `item/completed`, `item/agentMessage/delta`, and the current `UserInput` union in generated TypeScript and JSON schemas. `turn/steer` and `turn/interrupt` are also parsed and generated: the current no-active-turn runtime validates loaded-thread ids, steer input, `expectedTurnId`, and `turnId`, returns Rust-shaped no-active-turn errors for loaded synchronous threads, and accepts the Rust startup-interrupt empty `turnId` response. The current Zig implementation is synchronous and flattens model-visible turn input into the stored transcript; full Rust async streaming, plugin/app mention capability injection, chunked deltas and tool/reasoning item lifecycles, real same-turn steering, async interruption, active-turn tracking, and full turn schema parity remain planned.

Additional app-server turn-start reasoning override coverage: `turn/start`
now accepts Rust-compatible `effort` overrides for already-loaded threads,
rejects invalid reasoning-effort labels before issuing a provider request,
stores the selected effort on the loaded-thread runtime state, and applies
that effort to the current and subsequent Responses requests. The
generated TypeScript and JSON schemas include `TurnStartParams.effort`. Rust
collaboration-mode precedence over explicit `model` / `effort` overrides is
covered separately below.

Additional app-server turn-start collaboration-mode override coverage:
`turn/start` now accepts Rust-compatible `collaborationMode` overrides for
already-loaded threads, validates mode/settings shape, applies mode model and
reasoning effort ahead of explicit `model` / `effort` params, fills built-in
developer instructions when `developer_instructions` is null, stores the mode
on loaded-thread runtime state for subsequent turns, and renders plan-mode
`<proposed_plan>` responses without raw tags. Explicit empty
`developer_instructions` clears the extra collaboration instruction block. The
generated TypeScript and JSON schemas include
`TurnStartParams.collaborationMode`.

Additional app-server turn-start approvals-reviewer override coverage:
`turn/start` now accepts Rust-compatible `approvalsReviewer` overrides for
already-loaded threads, rejects invalid reviewer labels before issuing a
provider request, stores the selected reviewer on the loaded-thread runtime
state, and preserves it across subsequent thread lifecycle responses. The
generated TypeScript and JSON schemas include
`TurnStartParams.approvalsReviewer`.

Additional app-server turn-start personality override coverage: `turn/start`
now accepts Rust-compatible `personality` overrides for already-loaded
threads, rejects invalid personality labels before issuing a provider request,
stores the selected personality on the loaded-thread runtime state, and applies
it to the current and subsequent Responses request instructions. The generated
TypeScript and JSON schemas include `TurnStartParams.personality`.

Additional app-server turn-start reasoning-summary override coverage:
`turn/start` now accepts Rust-compatible `summary` overrides for
already-loaded threads, rejects invalid reasoning-summary labels before
issuing a provider request, stores the selected summary mode on the
loaded-thread runtime state, and applies that summary mode to the current and
subsequent Responses requests. The generated TypeScript and JSON schemas
include `TurnStartParams.summary`.

Additional app-server turn-start sandbox-policy override coverage:
`turn/start` now accepts Rust-compatible `sandboxPolicy` objects that map
cleanly to the current loaded-thread sandbox modes, including
`externalSandbox` network-access hints lowered to the current
danger-full-access runtime mode. It rejects conflicts with the legacy
`sandbox` field before issuing a provider request, rejects rich root/network
variants the current runtime cannot preserve yet, stores the selected mode on
the loaded-thread runtime state, and preserves it across subsequent thread
lifecycle responses. The generated TypeScript and JSON schemas include
`TurnStartParams.sandboxPolicy`. Full preservation and enforcement of custom
writable roots and network-enabled non-external sandbox policies remain
planned.

Additional app-server turn-start permissions override coverage:
`turn/start` now accepts Rust-compatible `permissions` profile selections for
already-loaded threads, rejects conflicts with `sandbox` / `sandboxPolicy` and
invalid `additionalWritableRoot` modifications before issuing a provider
request, resolves supported built-in and custom permission profiles, stores the
selected sandbox profile on the loaded-thread runtime state, preserves it
across in-memory thread forks, and feeds the selected writable roots,
cwd-write-root inclusion, and network policy into model-requested shell tool
execution. Read-only profile selections with additional writable roots lower
to the current macOS workspace-write seatbelt representation with cwd writes
disabled. The generated TypeScript and JSON schemas include
`TurnStartParams.permissions`, `PermissionProfileSelectionParams`, and
`PermissionProfileModificationParams`. Full active-permission-profile response
metadata, project/system/managed config-manager profile resolution, restricted
network allow-list policy, and full custom filesystem profile enforcement
remain planned.

Additional app-server thread status coverage: `turn/start` now emits
Rust-shaped `thread/status/changed` notifications for the active state before
the turn lifecycle notifications and the idle state after turn completion,
and `thread/archive` emits `notLoaded` when archiving removes an already-loaded
thread. Provider `response.failed` events from `turn/start` now mark the loaded
thread `systemError`, emit an `"error"` notification with the same turn failure
message and `willRetry: false`, expose that status through loaded thread
reads/lists, and successful follow-up turns restore `idle`, honoring
`optOutNotificationMethods`.
`ThreadStatus` and
`ThreadStatus`, `ThreadStatusChangedNotification`, and
`ThreadClosedNotification` are included in generated TypeScript and JSON
schemas. Idle-timeout `thread/closed` unload transitions, richer error payload
serialization, and true async active-turn status tracking remain planned.

Additional app-server thread-resume coverage: `thread/resume` now loads Zig-native session JSONL files by thread id or explicit path, loads basic Rust rollout JSONL files by UUID or explicit path, resolves readable local `state_5.sqlite` `threads.rollout_path` rows by thread id, or starts from non-empty in-memory `history` with Rust's history-over-path/threadId precedence. It creates or replaces the process-local loaded thread, returns a Rust-shaped `ThreadResumeResponse`, restores preview/title/path/source/thread-source/model-provider/cwd/CLI-version fields available in the loaded transcript, applies state-DB model, model-provider, reasoning-effort, and Git metadata for resumed threads unless an explicit resume model/provider/reasoning override is present, includes the experimental permission-profile response fields only for experimental clients, replays persisted Rust `token_count` usage through `thread/tokenUsage/updated` when turns are included, can include simple transcript-derived turns or honor `excludeTurns` while retaining turns for `thread/turns/list`, feeds the loaded ID into `thread/loaded/list`, and is included in TypeScript and JSON schema generation along with the token-usage notification shape. Full state-db runtime metadata, live reattachment, interrupted-turn usage attribution, and full persisted thread schema parity remain planned.

Additional app-server thread-fork coverage: `thread/fork` now forks from a thread already loaded in the current app-server process, from an active or archived saved/state-DB rollout by `threadId`, or from a Zig-native/Rust rollout transcript `path`, returns a Rust-shaped `ThreadForkResponse`, preserves `forkedFromId`, carries supported explicit overrides into the forked thread, applies source state-DB model, model-provider, reasoning-effort, cwd, and Git metadata for thread-id source lookup, carries the stored sandbox permission profile into loaded-thread forks, copies loaded turn payloads, replays persisted Rust `token_count` usage through `thread/tokenUsage/updated` before `thread/started` when turns are included, honors `excludeTurns` while retaining turns for `thread/turns/list`, adds the fork to `thread/loaded/list`, emits a Rust-shaped `thread/started` notification after the response with copied turns omitted unless the connection opted out, includes the experimental permission-profile response fields only for experimental clients, and is included in TypeScript and JSON schema generation. Interrupted-turn usage attribution, remote thread-store lookup, and full path/thread-store/schema parity remain planned.

Additional app-server thread rollback coverage: `thread/rollback` validates `threadId` and `numTurns`, preserves Rust-shaped `numTurns must be >= 1` rejection, returns Rust-shaped `thread not found` responses for unloaded threads, rejects ephemeral loaded threads without persisted rollout history, rolls back persistent loaded threads by trimming the last requested user-message turns from the in-memory transcript, refreshes loaded-thread preview/turns, appends Rust-shaped `thread_rolled_back` markers for persistent Zig transcripts, reconstructs simple Zig/Rust transcript history through append-only rollback markers when loading sessions, and is included in current TypeScript and JSON schema generation as an opaque-thread response until full thread schema parity lands. Active-turn rejection, pending-rollback tracking, complete compaction/context reconstruction, and full thread schema parity remain planned.

Additional app-server loaded-thread compaction coverage:
`thread/compact/start` now validates and loads already-loaded threads, runs a
no-tools compact turn through the configured Responses provider, replaces and
persists the loaded transcript with a compacted summary, refreshes loaded-thread
preview/turns, and emits Rust-shaped `turn/*` plus `contextCompaction`
`item/started` / `item/completed` notifications, followed by the deprecated
`thread/compacted` notification. True async return-before-work semantics,
remote compaction variants, hooks, analytics, and complete
compaction/context reconstruction remain planned.

Additional app-server thread item-injection coverage: `thread/inject_items` validates `threadId` and `items` array shape, returns Rust-shaped `thread not found` responses for unloaded threads before response-item validation, appends supported raw message/function-call/function-call-output response items to already-loaded threads, persists the updated Zig transcript, includes injected items in subsequent `turn/start` model requests, and is included in current TypeScript and JSON schema generation as an opaque item-list request. Full raw response-item schema parity remains planned.

Additional app-server thread naming coverage: `thread/name/set` validates `threadId`, trims and rejects empty names with Rust-shaped errors, updates already-loaded threads, persists the Zig transcript title, indexes local loaded/saved/state-DB-rollout thread names in Rust-shaped `session_index.jsonl`, updates local state-DB `threads.title` rows when present, emits `thread/name/updated`, returns Rust-shaped `thread not found` responses for missing stored threads, and is included in current TypeScript and JSON schema generation along with the `thread/name/updated` notification type. Remote stored-thread metadata updates remain planned.

Additional app-server thread memory-mode coverage: `thread/memoryMode/set` validates `threadId` and the `enabled` / `disabled` mode enum, rejects ephemeral loaded threads, updates and persists already-loaded Zig threads, appends Rust-shaped `session_meta` memory-mode updates for local saved/state-DB-rollout threads while preserving state-DB-backed model-provider, cwd, and CLI-version metadata, updates local state-DB `threads.memory_mode` rows when present, returns Rust-shaped `thread not found` responses for missing stored threads, and is included in current TypeScript and JSON schema generation. Full memory pipeline integration remains planned.

Additional app-server thread metadata coverage: `thread/metadata/update` validates `threadId`, requires `gitInfo` to include at least one Git field, rejects empty string metadata fields with Rust-shaped errors, rejects ephemeral loaded threads, patches, persists, restores, and returns `gitInfo` for persistent loaded Zig threads with Rust-shaped trim/null semantics, appends Rust-shaped `session_meta` Git metadata updates for local saved/state-DB-rollout threads while preserving state-DB-backed memory-mode, model-provider, cwd, and CLI-version metadata, updates local state-DB `threads.git_*` rows when present, returns Rust-shaped `thread not found` responses for missing stored threads, and is included in current TypeScript and JSON schema generation with an opaque thread response until full thread schema parity lands. Remote stored-thread metadata updates remain planned.

Additional app-server thread read coverage: `thread/read` validates `threadId` and `includeTurns` when present, returns already-loaded threads, active saved Zig/Rust rollout files from `$CODEX_HOME/sessions`, archived saved Zig/Rust rollout files from `$CODEX_HOME/archived_sessions`, or local `state_5.sqlite` `threads.rollout_path` rows that point to readable rollout files by id with Rust-shaped thread objects and optional turns, applies local state-DB `title`, memory-mode, Git, timestamp, source, thread-source, agent nickname/role, model-provider, cwd, CLI-version, and first-user-message preview metadata columns when present for state-DB-backed read responses, renders loaded threads as `idle` and saved/state-DB-backed stored threads as `notLoaded`, rejects `includeTurns` for ephemeral loaded threads and for persistent loaded threads before the first materialized turn with Rust-shaped invalid-request messages, returns Rust-shaped `thread not loaded` responses for valid missing threads, and is included in current TypeScript and JSON schema generation with an opaque thread response until full thread schema parity lands. Remote thread-store reads and complete thread schema parity remain planned.

Additional app-server thread archive coverage: `thread/archive` validates `threadId`, moves active saved rollout files from `$CODEX_HOME/sessions` into `$CODEX_HOME/archived_sessions` while preserving their relative path, updates local state-DB `threads.rollout_path`, `archived`, `archived_at`, and update timestamps when present, removes matching process-local loaded-thread and subscription state, best-effort archives state-DB spawned descendants in Rust notification order, emits `thread/archived`, returns the Rust-shaped missing-rollout error for valid missing threads, and is included in current TypeScript and JSON schema generation along with `ThreadArchivedNotification`. Remote thread-store archive and full schema parity remain planned.

Additional app-server thread unarchive coverage: `thread/unarchive` validates `threadId`, moves archived saved rollout files from `$CODEX_HOME/archived_sessions` back into `$CODEX_HOME/sessions`, updates local state-DB `threads.rollout_path`, `archived`, `archived_at`, and update timestamps when present, refreshes matching loaded-thread path/status state when the thread is already loaded, returns the restored Rust-shaped thread object with turns omitted, emits `thread/unarchived`, returns the Rust-shaped missing-archived-rollout error for valid missing threads, and is included in current TypeScript and JSON schema generation with an opaque thread response plus `ThreadUnarchivedNotification` until full thread schema parity lands. Remote thread-store unarchive and full schema parity remain planned.

Additional app-server thread list coverage: `thread/list` validates cursor, limit, sorting, source/provider, archive, cwd, state-db, and search filters, returns currently loaded non-archived threads with Rust-shaped thread objects, scans active saved Zig/Rust/CLI/appServer rollout files from `$CODEX_HOME/sessions` and archived saved rollout files from `$CODEX_HOME/archived_sessions` with lightweight summary parsing, supports `useStateDbOnly` for local `state_5.sqlite` `threads.rollout_path` rows that point to readable rollout files, surfaces local state-DB `title`, Git, timestamp, source, thread-source, agent nickname/role, model-provider, cwd, CLI-version, first-user-message preview, archived-row metadata columns, and loaded-vs-not-loaded status for saved and state-DB-only list rows when present, supports loaded and saved source/provider/cwd/search filtering including Rust-shaped default provider filtering when `modelProviders` is omitted, plus Rust-shaped default and clamped limits, RFC3339 timestamp `nextCursor`, and millisecond-offset `backwardsCursor` pagination, and is included in current TypeScript and JSON schema generation with opaque thread items until full stored-thread schema parity lands. Remote thread-store listing and complete thread schema parity remain planned.

Additional app-server Guardian approval coverage: `thread/approveGuardianDeniedAction` validates `threadId` and the basic serialized Guardian assessment event envelope, returns Rust-shaped `thread not found` responses for missing loaded threads, returns an empty Rust-shaped response for valid loaded-thread approval requests, and is included in current TypeScript and JSON schema generation with an opaque event payload until full Guardian event dispatch/lifecycle schema parity lands.

Additional app-server thread turns-list coverage: `thread/turns/list` validates `threadId`, cursor, limit, and sort direction, paginates transcript-derived turns for threads already loaded in the current app-server process, active saved Zig/Rust rollout files from `$CODEX_HOME/sessions`, archived saved Zig/Rust rollout files from `$CODEX_HOME/archived_sessions`, or local `state_5.sqlite` `threads.rollout_path` rows that point to readable rollout files using Rust-shaped descending-by-default ordering, JSON cursors, `nextCursor`, and `backwardsCursor`, rejects ephemeral loaded threads and persistent loaded threads before the first materialized turn with Rust-shaped invalid-request messages, and returns Rust-shaped `thread not loaded` responses for valid missing threads. Full state-DB metadata listing, remote thread-store listing, live active-turn merging, token-usage replay, full turn reconstruction, and complete turn schema parity remain planned.

Additional app-server realtime voice list coverage: `thread/realtime/listVoices` validates object params, returns the Rust built-in v1/v2 realtime voice lists with default voices, and is included in current TypeScript and JSON schema generation until full realtime session lifecycle parity lands.

Additional app-server realtime stop coverage: `thread/realtime/stop` validates `threadId`, returns Rust-shaped `thread not found` responses for valid missing threads in the current no-thread runtime, and is included in current TypeScript and JSON schema generation until full realtime session lifecycle parity lands.

Additional app-server realtime text append coverage: `thread/realtime/appendText` validates `threadId` and text string params, returns Rust-shaped `thread not found` responses for valid missing threads in the current no-thread runtime, and is included in current TypeScript and JSON schema generation until full realtime session lifecycle parity lands.

Additional app-server realtime audio append coverage: `thread/realtime/appendAudio` validates `threadId` and realtime audio chunk params, returns Rust-shaped `thread not found` responses for valid missing threads in the current no-thread runtime, and is included in current TypeScript and JSON schema generation until full realtime session lifecycle parity lands.

Additional app-server realtime start coverage: `thread/realtime/start` validates `threadId`, output modality, prompt/session/voice, and realtime transport params, returns Rust-shaped `thread not found` responses for valid missing threads in the current no-thread runtime, and is included in current TypeScript and JSON schema generation until full loaded-thread realtime session lifecycle parity lands.

Additional app-server loaded-thread realtime feature coverage:
`thread/realtime/start`, `thread/realtime/stop`,
`thread/realtime/appendText`, and `thread/realtime/appendAudio` now reject
already-loaded threads with Rust's `thread {id} does not support realtime
conversation` error while the `realtime_conversation` feature is disabled. Full
feature-enabled realtime session start, append, stop, and notification lifecycle
remain planned.

Additional app-server goal coverage: `thread/goal/set`, `thread/goal/get`, and `thread/goal/clear` honor the `goals` feature gate, validate `threadId`, objective/status/token-budget params, reject ephemeral loaded threads, maintain process-local goal state for already-loaded persistent threads, emit `thread/goal/updated` and `thread/goal/cleared` notifications, return Rust-shaped `thread not found` responses for valid missing threads in the current no-store runtime, and include generated TypeScript and JSON schemas for the goal requests, responses, `thread/goal/updated`, and `thread/goal/cleared` until full state-db-backed goal parity lands.
