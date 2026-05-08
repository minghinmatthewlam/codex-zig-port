# Codex CLI Parity Tracker

Status values:

- `planned`: not implemented in Zig yet
- `partial`: implemented enough for a demo or narrow flow
- `covered`: implemented and verified against the affected product surface

| Rust surface | Zig status | Notes |
| --- | --- | --- |
| `cli` base interactive command | partial | First milestone launches `codex-zig` interactive loop. Full flag/subcommand parity is planned. |
| `tui` terminal UI | partial | Current UI is a simple terminal surface with composer/transcript/tool status, streamed assistant text deltas, and local `/help`, `/status`, `/model`, `/permissions`, `/approval`, `/sandbox`, `/history`, `/rollout`, `/sessions`, `/diff`, `/clear`, `/new`, `/resume`, `/quit`, and `/exit` commands. Full alternate-screen layout, transcript overlay, keymaps, slash popup, resize behavior, fork, and snapshots are planned. |
| `login` / local auth reuse | partial | Reads `$CODEX_HOME/auth.json` / `~/.codex/auth.json`, ChatGPT bearer token, ChatGPT account header, API-key fallback, `login status`, `login --with-api-key`, `login --device-auth`, and file-backed `logout`. Browser callback login, access-token login, OAuth revoke, keyring storage, and refresh are planned. |
| `core` Responses agent loop | partial | Sends Responses API requests, parses text deltas and function calls, optionally streams text deltas to callers, and loops tool output back. Context compaction, rollout persistence, model catalog, goals, subagents, and advanced prompts are planned. |
| `tools` shell execution | partial | Supports minimal `shell` and `shell_command` calls with approval policy decisions, cwd, timeout, stdout/stderr capture, truncation, and macOS `sandbox-exec` wrapping for read-only/workspace-write shell processes. Hooks and unified exec sessions are planned. |
| `config` | partial | Resolves Codex home, installation id, model/base URL, `approval_policy`, and `sandbox_mode` from env/config. Full TOML config stack, profiles, and managed requirements are planned. |
| `mcp` | planned | Not in first milestone. |
| `apply-patch` | partial | Exposes an `apply_patch` function tool with approval and a Zig-native parser for add, update, delete, move-to, multiple hunks, EOF markers, padded markers, and no-newline replacements. Full grammar and fixture parity are still planned. |
| `exec` non-interactive mode | partial | Supports `codex-zig exec [--auto-approve] [--ephemeral] [--approval-policy MODE] [--sandbox MODE] [--json] [-o FILE] [PROMPT|-]` and `codex-zig exec resume [last|ID|PATH] PROMPT` using the shared session/tool loop. Review, schema output, and full event parity are planned. |
| `sandbox` macOS seatbelt | partial | Parses `read-only`, `workspace-write`, and `danger-full-access`; shell processes run through `/usr/bin/sandbox-exec` on macOS for read-only/workspace-write. In-process `apply_patch` still uses conservative preflight/path checks instead of process sandboxing. |
| `resume` / `fork` / session store | partial | Writes Zig-native JSONL transcripts under `$CODEX_HOME/sessions/zig/`, starts `codex-zig resume [ID|PATH|last]`, supports `codex-zig exec resume ...`, lists saved sessions through `codex-zig sessions [N]` and `/sessions [n]`, and supports `/resume` inside the TUI. Full Rust rollout path layout, metadata, fork semantics, and browsing UI are planned. |
| app server / desktop app / cloud tasks | planned | Not in first milestone. |
