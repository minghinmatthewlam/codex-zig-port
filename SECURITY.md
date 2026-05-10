# Security Policy

This repository is public and independent. Do not open public issues or pull
requests that include credentials, auth files, private prompts, session
transcripts, local filesystem details, or working exploit details.

## Supported Versions

This project is pre-release. Security fixes target the `main` branch.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting from the repository Security tab:

https://github.com/minghinmatthewlam/codex-zig-port/security/advisories/new

Include:

- the affected command, protocol, or config surface
- the smallest safe reproduction you can share
- expected impact
- relevant version, commit, platform, and Zig version
- redacted logs or terminal output, if useful

The maintainer will triage privately, prepare a fix when needed, and publish
public details only after sensitive information has been removed.

## Secret Exposure

If you accidentally publish a token, revoke it with the provider first. Then
use private vulnerability reporting with the affected file path and commit so
the repository can be checked without spreading the secret further.
