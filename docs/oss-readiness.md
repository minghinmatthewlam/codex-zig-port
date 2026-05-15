# OSS Readiness

Last checked: 2026-05-15.

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
- Security settings: GitHub API checks through 2026-05-15 show secret scanning,
  push protection, Dependabot security updates, and private vulnerability
  reporting enabled. GitHub reports non-provider pattern scanning and secret
  validity checks as disabled. The current token received 404s from the
  code-scanning, secret-scanning alert, and Dependabot alert list endpoints, so
  this pass did not record a fresh alert count. CodeQL Python code scanning is
  configured; the latest completed pre-current-slice CodeQL run `25911164524`
  passed for `bee6089 Document app-server root feature overrides`.
- Repository rules: the branch-protection API reports `main` is unprotected and
  the repository rulesets API returns zero rulesets.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS with a direct Zig 0.16.0
  install from `ziglang.org` rather than a deprecated Node-based setup action.
  Checked pre-current-slice push run `25911164502` passed for
  `bee6089 Document app-server root feature overrides`; prior push runs
  `25910352507` and `25908888054` also passed for runtime and session slash
  command slices. Local pre-push verification for the current config write
  override metadata slice included Python compilation, whitespace checks,
  `zig build`, focused config write override metadata smoke,
  `zig build test --summary all`, full app-server stdio smoke,
  `zig build e2e --summary all`, and `codex review --uncommitted`.
- Source hygiene: current tracked-file scans after the local config write
  override metadata slice found no provider-shaped tokens, GitHub tokens, Slack
  tokens, AWS access keys, or private-key blocks in tracked files;
  the only current match is this document's historical dummy
  `sk-proj-1234567890ABCDE` note. `git ls-files -o --exclude-standard` returned
  no untracked public files. Ignored-file scans only found local build output,
  Python bytecode, ignored demo scratch files, and ignored local `plans/`
  content. `gitleaks` was not installed on the local machine during the latest
  check, so the local scan used repository `git grep` patterns plus GitHub's
  enabled secret-scanning state.
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
