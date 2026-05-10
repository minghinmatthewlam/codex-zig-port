# Security Policy

## Supported Versions

This project is pre-release. Security fixes target the `main` branch.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if it is available for this
repository. If it is not available, open a minimal public issue that says you
have a security report, but do not include exploit details, tokens, private
paths, or credentials in the issue.

Useful reports include:

- token or credential exposure
- unsafe handling of `CODEX_HOME`, `auth.json`, or session files
- sandbox escape or unintended filesystem access
- command execution behavior that bypasses approval or sandbox policy
- app-server, MCP, or auth flows that leak secrets

Please include the affected command or workflow, the expected behavior, and the
smallest reproduction you can share safely.

