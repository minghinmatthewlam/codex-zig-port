# OSS Readiness

Last checked: 2026-05-17.

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
- Security settings: GitHub API checks through 2026-05-17 show secret scanning,
  push protection, and Dependabot security updates enabled. GitHub reports
  non-provider pattern scanning and secret validity checks as disabled. The
  repository API did not return a private-vulnerability-reporting status in the
  latest check. CodeQL Python code scanning is configured; the latest completed
  CodeQL run `25978845292` passed for `Document remote-control browser events`.
- Repository rules: the branch-protection API reports `main` is unprotected and
  the repository rulesets API returns zero rulesets.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS with a direct Zig 0.16.0
  install from `ziglang.org` rather than a deprecated Node-based setup action.
  Checked push run `25978845314` passed for `Document remote-control browser
  events`. Local pre-push verification for the current remote-control browser
  events slice included Python compilation, whitespace checks, `zig build`,
  focused local remote-control SSE smoke, `zig build test --summary all`,
  `zig build e2e --summary all`, and iterative `codex review --uncommitted`.
- Source hygiene: current tracked-file scans after the remote-control browser
  events slice found no high-confidence OpenAI, GitHub, AWS, or Slack token
  patterns and no private-key blocks. Broad secret-word matches are limited to
  source variable names and fixed dummy credentials in smoke coverage.
  `gitleaks` was not installed on the local machine during the latest check, so
  the local scan used repository `rg` patterns plus GitHub's enabled
  secret-scanning state.
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
