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
  Checked push run `25864096047` passed for
  `a7fd78d Document terminal interaction coverage`; prior push runs
  `25863630822`, `25863144266`, `25862794523`, and `25862306400` also passed
  for the patch-update, MCP progress, command output, and MCP startup-status
  notification slices. Local pre-push verification for the latest slice included
  Python compilation, whitespace checks, `zig build`, the focused app-server
  terminal-interaction smoke, `zig build test`, and `zig build e2e`.
- Source hygiene: current tracked-file scans after the terminal-interaction
  notification commits found no provider-shaped tokens, GitHub tokens, Slack
  tokens, AWS access keys, private-key blocks, or JWT-shaped blobs.
  Keyword/path scans found public docs, test fixtures, mocked auth/token flows
  such as `test-api-key`, and temporary-path examples rather than checked-in
  local credentials. Current ignored-file scans only found local build output,
  Python bytecode, ignored demo scratch files, and ignored local `plans/`
  content; provider-shaped secret scans over ignored non-build files also found
  no matches. Git-history regex scans found no real provider-shaped secrets,
  private-key blocks, or JWT-shaped blobs; the only provider-shaped history
  match is the old dummy `sk-proj-1234567890ABCDE` test fixture added by commit
  `820d156` and removed by commit `0383594`, and it is not present at `HEAD`.
  `gitleaks` was not installed on the local machine during the latest check, so
  the local scan used repository `rg` and `git grep` patterns.
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
