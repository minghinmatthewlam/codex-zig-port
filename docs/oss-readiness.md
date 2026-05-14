# OSS Readiness

Last checked: 2026-05-14.

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
- Security settings: GitHub API checks on 2026-05-14 showed secret scanning,
  push protection, Dependabot security updates, and private vulnerability
  reporting enabled. GitHub reports non-provider pattern scanning and secret
  validity checks as disabled. Dependabot and secret-scanning alert APIs
  returned no open alerts; the code-scanning alerts API still reports no
  analysis and additionally requires broader hook-admin scope for this token.
- Repository rules: the branch-protection API reports `main` is unprotected and
  the repository rulesets API returns zero rulesets.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS with a direct Zig 0.16.0
  install from `ziglang.org` rather than a deprecated Node-based setup action.
  Checked push run `25837356714` passed for
  `852c4e3 Keep expected parser errors quiet in tests`.
- Source hygiene: current tracked-file scans found no provider-shaped tokens,
  GitHub tokens, Slack tokens, AWS access keys, private-key blocks,
  JWT-shaped blobs, unignored local auth/env files, or tracked local build
  artifacts. Current ignored-file scans only found local build output,
  Python bytecode, ignored demo scratch files, and ignored local `plans/`
  content. Broad keyword/path scans only found test fixtures, docs, ignored
  local build output, and temporary-path examples. Git-history regex scans found
  no provider-shaped secrets, private-key blocks, or JWT-shaped blobs, and only
  an old dummy `sk-proj-*` test fixture added by commit `820d156` and removed by
  commit `0383594`; no real secret material was identified.
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
- A release process for tags, changelogs, and binary artifacts is not defined.
- CI currently verifies macOS only because the first milestone targets macOS.
- Exact CLI, TUI, app-server, MCP, and cloud-task parity remains incomplete; use
  `docs/parity.md` as the source of truth before making compatibility claims.
