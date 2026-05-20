# OSS Readiness

Last checked: 2026-05-20.

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
- Security settings: GitHub API checks through 2026-05-20 show secret scanning,
  push protection, and Dependabot security updates enabled. GitHub reports
  non-provider pattern scanning and secret validity checks as disabled.
  `SECURITY.md` is exposed through the repository security-policy URL. CodeQL
  Python code scanning is configured; checked CodeQL run `26157868444` passed
  on pushed head `f466097d75196c0593e4786999139320784017e0`.
  Open-alert queries for
  CodeQL, Dependabot, and secret scanning returned empty arrays after the
  token-shaped smoke-fixture cleanup. Historical CodeQL alerts remain visible
  through the API as fixed.
- Repository rules: the branch-protection API reports `main` is unprotected and
  the repository rulesets API returns zero rulesets.
- CI: GitHub Actions runs formatting, Python smoke-script compilation, unit
  tests, and product-surface smoke tests on macOS with a direct Zig 0.16.0
  install from `ziglang.org` rather than a deprecated Node-based setup action.
  It also runs the repository OSS secret-scan script. Checked push run
  `26157868443` passed on pushed head
  `f466097d75196c0593e4786999139320784017e0`.
- Fresh public clone proof: a clean HTTPS clone from
  `https://github.com/minghinmatthewlam/codex-zig-port` at pushed head
  `f466097d75196c0593e4786999139320784017e0` passed `python3 -m py_compile`
  for the app-server, CLI, OSS secret-scan, and TUI smoke scripts,
  `python3 scripts/oss_secret_scan.py`, `zig fmt --check build.zig
  build.zig.zon src/*.zig`, `zig build`, `zig build test`, and
  `zig build e2e`.
- Source hygiene: the current CI and fresh-public-clone scans found no
  high-confidence OpenAI, Anthropic, GitHub, AWS, Google, or Slack token
  patterns and no private-key blocks in tracked source, scripts, docs, tests,
  or GitHub metadata. A broad secret-word scan is expectedly noisy because this
  repository implements auth flows, so the actionable local check uses
  `scripts/oss_secret_scan.py` high-confidence credential patterns plus
  GitHub's enabled secret scanning.
  `gitleaks`, `trufflehog`, and the local CodeQL CLI were not installed on the
  local machine during the latest check, so the local scan used the repository
  script plus GitHub's enabled secret scanning and CodeQL runs.
- Package boundary: `build.zig.zon` lists only source, test, script, and public
  documentation paths so local ignored artifacts are not part of a Zig package.

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
- A manual release playbook now exists in `docs/release.md`; release
  automation, code signing, notarization, and cross-platform binary publishing
  are not implemented yet.
- CI currently verifies macOS only because the first milestone targets macOS.
- Exact CLI, TUI, app-server, MCP, and cloud-task parity remains incomplete; use
  `docs/parity.md` as the source of truth before making compatibility claims.
