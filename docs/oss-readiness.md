# OSS Readiness

Last checked: 2026-05-12.

This file records the public-readiness state for the repository. It is not a
parity tracker; implementation parity remains tracked in `docs/parity.md`.

## Current State

- GitHub repository: public at
  `https://github.com/minghinmatthewlam/codex-zig-port`
- Default branch: `main`
- License: MIT
- Community files: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `.github/CODE_OF_CONDUCT.md`, issue templates, PR template, and CODEOWNERS
- GitHub community profile: 100%
- Security settings: GitHub API checks on 2026-05-12 showed secret scanning,
  push protection, Dependabot security updates, and private vulnerability
  reporting enabled. GitHub reports non-provider pattern scanning and secret
  validity checks as disabled. Dependabot and secret-scanning alert APIs
  returned no open alerts.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS. Checked push run
  `25717457553` passed for
  `21ad42ac457c2286a932dc53ef045e3e3816aba0`.
- Source hygiene: current tracked-file scans found no provider-shaped tokens,
  GitHub tokens, Slack tokens, AWS access keys, private-key blocks,
  JWT-shaped blobs, unignored local auth/env files, or unignored local artifacts. Broad
  keyword/path scans only found test fixtures, docs, ignored local build output,
  and temporary-path examples. Git-history regex scans found no provider-shaped
  secrets, private-key blocks, or JWT-shaped blobs, and only an old dummy
  `sk-proj-*` test fixture that was removed by commit `0383594` plus current
  placeholder auth fixtures; no real secret material was identified.
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
- GitHub code scanning is not configured; the API returned no analysis.
- GitHub wiki/projects are enabled; disable them if the project does not plan
  to use those public surfaces.
- Consider enabling non-provider secret scanning patterns and validity checks if
  the repository settings plan supports them.
- CI currently emits a GitHub Actions annotation that `mlugg/setup-zig@v2`
  targets Node.js 20 while `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` forces Node 24;
  monitor or update the action when an updated runtime target is available.
- A release process for tags, changelogs, and binary artifacts is not defined.
- CI currently verifies macOS only because the first milestone targets macOS.
- Exact CLI, TUI, app-server, MCP, and cloud-task parity remains incomplete; use
  `docs/parity.md` as the source of truth before making compatibility claims.
