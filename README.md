# Codex Zig Port

This repository is an independent Zig reimplementation of the Codex CLI.
The Rust Codex checkout at `~/dev/codex` is a behavioral reference only:
runtime code in this repository must not import, link to, or shell out to the
original implementation.

## First Milestone

The first demo slice targets macOS and focuses on the interactive CLI surface:

- launch an interactive terminal UI with `zig build run`
- accept an optional initial prompt with `codex-zig [PROMPT]`
- reuse local Codex auth from `$CODEX_HOME/auth.json` or `~/.codex/auth.json`
- refresh expired or stale ChatGPT auth tokens from stored refresh tokens
- manage basic auth with `login status`, `login --with-api-key`,
  `login --with-access-token`, `login --device-auth`, and `logout`
- send a Responses API turn
- stream assistant text deltas in the interactive TUI
- include discovered `AGENTS.md` project instructions in API turns
- create a repository guide through interactive `/init`
- compact an interactive session into a continuation summary with `/compact`
- enable native Responses web search with `--search` or `web_search = "live"`
- accept modern `exec_command` tool calls for one-shot command execution and
  PTY-backed `write_stdin` session input
- execute basic `shell` / `shell_command` tool calls after user confirmation
- run a command through the macOS Seatbelt sandbox with `sandbox macos`
- apply focused `apply_patch` file edits after user confirmation
- discover and execute configured stdio MCP tools as `mcp__server__tool` calls
- run a stdio MCP server with `codex` and `codex-reply` tools plus per-call
  `model`, `cwd`, `approval-policy`, and `sandbox` overrides
- send tool output back to the model
- review current changes from the interactive TUI with `/review`
- run narrow non-interactive `review --uncommitted`, `review --base`, and
  `review --commit` flows
- inspect known feature flags with `features list`

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
`chatgpt_base_url`, `approval_policy`, `sandbox_mode`, `oss_provider`, and
`profile` from top-level keys in `$CODEX_HOME/config.toml`. It also supports
`[profiles.<name>]` sections for those same fields and reads
`[model_providers.<name>].base_url` for custom Responses-compatible providers.

```sh
codex-zig --profile work auth-status
codex-zig -m gpt-5.5 -a never -s danger-full-access
codex-zig --cd ~/dev/my-project
codex-zig --add-dir ~/scratch
codex-zig -c model=gpt-5.5
codex-zig exec -c sandbox_mode=read-only "say hello"
codex-zig --oss --local-provider lmstudio
codex-zig --search
codex-zig --version
codex-zig exec --profile work "say hello"
codex-zig exec resume --all last "continue"
codex-zig exec --image screenshot.png "describe this"
codex-zig sandbox macos -- /bin/echo ok
codex-zig features list
codex-zig features enable goals
codex-zig features disable goals
codex-zig mcp list
codex-zig mcp add docs -- node ./server.js
codex-zig mcp add remote --url https://example.com/mcp
codex-zig mcp-server
codex-zig review --uncommitted
codex-zig review --base main
codex-zig review --commit HEAD
```

`CODEX_ZIG_PROFILE` selects a profile. `CODEX_ZIG_MODEL` overrides the model.
`CODEX_ZIG_MODEL_PROVIDER` selects a configured model provider.
`CODEX_ZIG_BASE_URL` overrides both API base URLs for local testing.
`CODEX_ZIG_WEB_SEARCH` overrides web search mode with `disabled`, `cached`, or
`live`.
`CODEX_OSS_BASE_URL` or `CODEX_OSS_PORT` override the local OSS Responses endpoint.
The Rust-compatible `-c/--config key=value` path currently accepts supported
scalar keys: `profile`, `model`, `openai_base_url`, `chatgpt_base_url`,
`oss_provider`, `approval_policy`, `sandbox_mode`, and `web_search`.
