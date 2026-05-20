# Release Playbook

The Zig port is pre-release software. Do not tag a public release until the
release notes clearly state which Codex CLI surfaces are complete, partial, or
not implemented.

## Versioning

- Keep `build.zig.zon` as the source of truth for the package version.
- Use `0.x.y` versions while the port is still parity-incomplete.
- Increment the minor version for user-visible command, TUI, app-server, or
  protocol additions.
- Increment the patch version for bug fixes, docs-only release updates, and
  verification-only hardening.

## Preflight

Run these checks from a clean worktree before creating a tag:

```sh
zig fmt --check build.zig build.zig.zon src/*.zig
python3 -m py_compile scripts/app_server_stdio_smoke.py scripts/cli_smoke.py scripts/tui_e2e.py
zig build --summary all
zig build test --summary all
zig build e2e --summary all
python3 scripts/cli_smoke.py zig-out/bin/codex-zig
python3 scripts/app_server_stdio_smoke.py
python3 scripts/tui_e2e.py zig-out/bin/codex-zig
git diff --check
```

If a check cannot be run locally, record the blocker in the release notes
instead of implying the release was fully verified.

## Changelog

Create release notes with these sections:

- Highlights: user-visible changes and the target audience.
- Compatibility: known Rust Codex parity gaps and behavior differences.
- Verification: exact commands, product-surface smokes, and CI run links.
- Security and OSS hygiene: secret-scan status, dependency/security alert
  status, and any public-readiness caveats.
- Contributors: merged pull requests and external contributors.

## Artifacts

For the current macOS-first milestone, build and attach at least:

- `codex-zig-<version>-macos-arm64.tar.gz`
- `codex-zig-<version>-macos-x86_64.tar.gz`
- `SHA256SUMS`

Each archive should contain `codex-zig`, `README.md`, `LICENSE`,
`SECURITY.md`, and `docs/parity.md`. Generate checksums after the archives are
final.

## Tagging

1. Confirm `main` is clean and synchronized with `origin/main`.
2. Update `build.zig.zon` and release notes in a focused commit.
3. Create an annotated tag named `v<version>`.
4. Push the commit and tag.
5. Create a GitHub release from the tag, attach artifacts, and paste the
   changelog.
6. Re-check the release page, artifact checksums, and CI status after publish.

Release automation, code signing, notarization, and cross-platform binary
publishing are not implemented yet.
