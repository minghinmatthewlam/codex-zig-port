# Contributing

This is an independent, unofficial Zig reimplementation of the Codex CLI.
Changes should keep parity claims honest: if a feature is partial, document the
covered behavior and the remaining gaps in `docs/parity.md`.

## Setup

Install Zig `0.16.0`, then run:

```sh
zig build
zig fmt --check build.zig build.zig.zon src/*.zig
zig build test
zig build e2e
```

The `e2e` step launches the rebuilt `codex-zig` binary through the local smoke
harness. For auth, app-server, or config work, use a temporary `CODEX_HOME`
instead of your real `~/.codex` directory.

## Change Guidelines

- Keep commits small and focused.
- Prefer behavior-compatible implementations over broad rewrites.
- Treat upstream Codex source as a behavioral reference. Do not copy source,
  generated assets, or fixtures into this repository without preserving the
  required license and notice files.
- Update `README.md` or `docs/parity.md` when a user-visible surface changes.
- Add or extend a smoke test when the change affects CLI, TUI, app-server, auth,
  config, MCP, plugin, or filesystem behavior.
- Do not commit tokens, `auth.json`, session transcripts, `.zig-cache/`,
  `zig-out/`, or local demo artifacts.

## Pull Requests

Include:

- what changed
- why it changed
- which parity surface it affects
- the verification commands you ran
