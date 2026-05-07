# Codex Zig Port

This repository is an independent Zig reimplementation of the Codex CLI.
The Rust Codex checkout at `~/dev/codex` is a behavioral reference only:
runtime code in this repository must not import, link to, or shell out to the
original implementation.

## First Milestone

The first demo slice targets macOS and focuses on the interactive CLI surface:

- launch an interactive terminal UI with `zig build run`
- reuse local Codex auth from `$CODEX_HOME/auth.json` or `~/.codex/auth.json`
- send a Responses API turn
- execute basic `shell` / `shell_command` tool calls after user confirmation
- send tool output back to the model

Long-term exact parity is tracked in `docs/parity.md`.

## Build

```sh
zig build
zig build test
zig build run
```

The project currently targets Zig `0.16.0`.
