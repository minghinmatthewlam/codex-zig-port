# OSS Readiness

Last checked: 2026-05-18.

This file records the public-readiness state for the repository. It is not a
parity tracker; implementation parity remains tracked in `docs/parity.md`.

## Current State

- GitHub repository: public at
  `https://github.com/minghinmatthewlam/codex-zig-port`
- Default branch: `main`
- License: MIT
- Community files: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `.github/CODE_OF_CONDUCT.md`, issue templates, PR template, and CODEOWNERS
- GitHub community profile: 100% by the repository community-profile API.
- Security settings: GitHub API checks through 2026-05-18 show secret scanning,
  push protection, and Dependabot security updates enabled. GitHub reports
  non-provider pattern scanning and secret validity checks as disabled.
  `SECURITY.md` is exposed through the repository security-policy URL. CodeQL
  Python code scanning is configured; the latest completed CodeQL run
  `26015863400` passed on pushed head
  `894fc13044d8d28cd88a433f820f8f1d9b690d47`. Open-alert queries for
  CodeQL, Dependabot, and secret scanning returned empty arrays. Historical
  CodeQL alerts remain visible through the API as fixed.
- Repository rules: the branch-protection API reports `main` is unprotected and
  the repository rulesets API returns zero rulesets.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS with a direct Zig 0.16.0
  install from `ziglang.org` rather than a deprecated Node-based setup action.
  Checked push run `26015863416` passed on pushed head
  `894fc13044d8d28cd88a433f820f8f1d9b690d47`. Local pre-push verification for
  the current app-server approval slice included `python3 -m py_compile
  scripts/app_server_stdio_smoke.py`, `zig fmt src/app_server_cmd.zig
  src/tools.zig`, `git diff --check`, focused app-server approval smoke,
  `zig build test --summary all`, `zig build e2e --summary all`, and `codex
  review --uncommitted`.
- Source hygiene: current tracked-file and hidden working-tree scans found no
  high-confidence OpenAI, GitHub, AWS, Google, or Slack token patterns and no
  private-key blocks. Broad secret-word matches are limited to source variable
  names, public documentation guardrails, runtime token-handling code, and fixed
  dummy credentials in smoke coverage. `gitleaks`, `trufflehog`, and the local
  CodeQL CLI were not installed on the local machine during the latest check, so
  the local scan used repository `rg` patterns plus GitHub's enabled secret
  scanning and CodeQL runs.
- Package boundary: `build.zig.zon` lists only source, test, script, and public
  documentation paths so local ignored artifacts are not part of a Zig package

## Public Guardrails

- Do not publish real `auth.json` files, `.credentials.json` files, API keys,
  access tokens, private prompts, local session transcripts, `.zig-cache/`,
  `zig-out/`, or demo scratch files.
- Keep parity claims tied to real verification. If a behavior is partial,
  describe both the covered surface and the remaining gaps in `docs/parity.md`.
- Treat upstream Codex source as a behavioral reference only. Do not copy source,
  generated assets, or fixtures without the required license and notice review.

## Known Follow-Ups

- Branch protection and repository rulesets are not enabled on `main` yet.
- GitHub wiki/projects are enabled; disable them if the project does not plan
  to use those public surfaces.
- Consider enabling non-provider secret scanning patterns and validity checks if
  the repository settings plan supports them.
- A release process for tags, changelogs, and binary artifacts is not defined.
- CI currently verifies macOS only because the first milestone targets macOS.
- Exact CLI, TUI, app-server, MCP, and cloud-task parity remains incomplete; use
  `docs/parity.md` as the source of truth before making compatibility claims.
