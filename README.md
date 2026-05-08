# Codex Zig Port

This repository is an independent Zig reimplementation of the Codex CLI.
The Rust Codex checkout at `~/dev/codex` is a behavioral reference only:
runtime code in this repository must not import, link to, or shell out to the
original implementation.

## First Milestone

The first demo slice targets macOS and focuses on the interactive CLI surface:

- launch an interactive terminal UI with `zig build run`
- reuse local Codex auth from `$CODEX_HOME/auth.json` or `~/.codex/auth.json`
- manage basic auth with `login status`, `login --with-api-key`, `login --device-auth`,
  and `logout`
- send a Responses API turn
- stream assistant text deltas in the interactive TUI
- include discovered `AGENTS.md` project instructions in API turns
- enable native Responses web search with `--search` or `web_search = "live"`
- execute basic `shell` / `shell_command` tool calls after user confirmation
- apply focused `apply_patch` file edits after user confirmation
- send tool output back to the model

Long-term exact parity is tracked in `docs/parity.md`.

## Build

```sh
zig build
zig build test
zig build run
```

The project currently targets Zig `0.16.0`.

## Auth

`codex-zig` reuses the same `$CODEX_HOME/auth.json` file as the Rust CLI. The
current Zig auth surface supports:

```sh
codex-zig login status
codex-zig login --with-api-key
codex-zig login --device-auth
codex-zig logout
```

`login --device-auth` implements the ChatGPT device-code flow directly in Zig.
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

The port reads `model`, `openai_base_url`, `chatgpt_base_url`,
`approval_policy`, `sandbox_mode`, and `profile` from top-level keys in
`$CODEX_HOME/config.toml`. It also supports `[profiles.<name>]` sections for
those same fields.

```sh
codex-zig --profile work auth-status
codex-zig -m gpt-5.5 -a never -s danger-full-access
codex-zig --cd ~/dev/my-project
codex-zig --add-dir ~/scratch
codex-zig --search
codex-zig exec --profile work "say hello"
```

`CODEX_ZIG_PROFILE` selects a profile. `CODEX_ZIG_MODEL` overrides the model.
`CODEX_ZIG_BASE_URL` overrides both API base URLs for local testing.
`CODEX_ZIG_WEB_SEARCH` overrides web search mode with `disabled`, `cached`, or
`live`.
