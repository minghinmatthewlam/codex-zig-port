# Codex CLI Parity Tracker

Status values:

- `planned`: not implemented in Zig yet
- `partial`: implemented enough for a demo or narrow flow
- `covered`: implemented and verified against the affected product surface

| Rust surface | Zig status | Notes |
| --- | --- | --- |
| `cli` base interactive command | partial | First milestone launches `codex-zig` interactive loop. Full flag/subcommand parity is planned. |
| `tui` terminal UI | partial | Current UI is a simple terminal surface with composer/transcript/tool status. Full alternate-screen layout, keymaps, slash commands, resize behavior, resume/fork, and snapshots are planned. |
| `login` / local auth reuse | partial | Reads `$CODEX_HOME/auth.json` / `~/.codex/auth.json`, ChatGPT bearer token, ChatGPT account header, API-key fallback. Fresh login and refresh are planned. |
| `core` Responses agent loop | partial | Sends Responses API requests, parses text deltas and function calls, loops tool output back. Context compaction, rollout persistence, model catalog, goals, subagents, and advanced prompts are planned. |
| `tools` shell execution | partial | Supports minimal `shell` and `shell_command` calls with confirmation, cwd, timeout, stdout/stderr capture, and truncation. Approval profiles, sandboxing, hooks, unified exec sessions, and apply_patch interception are planned. |
| `config` | partial | Resolves Codex home, installation id, and simple model/base URL config. Full TOML config stack and managed requirements are planned. |
| `mcp` | planned | Not in first milestone. |
| `apply-patch` | planned | Not in first milestone except via shell command if the user approves it. |
| `exec` non-interactive mode | planned | Not in first milestone. |
| `sandbox` macOS seatbelt | planned | First milestone uses explicit command confirmation but no seatbelt profile. |
| `resume` / `fork` / session store | planned | Not in first milestone. |
| app server / desktop app / cloud tasks | planned | Not in first milestone. |
