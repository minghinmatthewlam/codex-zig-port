#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("OpenAI API key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b")),
    ("Anthropic API key", re.compile(r"\bsk-ant-api03-[A-Za-z0-9_-]{80,}\b")),
    ("GitHub token", re.compile(r"\bgh[oprsu]_[A-Za-z0-9_]{36,}\b")),
    ("GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9_]{59,}\b")),
    ("AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b")),
    (
        "private key block",
        re.compile(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"),
    ),
)


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    paths: list[Path] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        paths.append(REPO_ROOT / raw.decode("utf-8"))
    return paths


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def scan_file(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_bytes().decode("utf-8", errors="replace")

    findings: list[str] = []
    rel_path = path.relative_to(REPO_ROOT)
    for label, pattern in PATTERNS:
        for match in pattern.finditer(text):
            findings.append(f"{rel_path}:{line_number(text, match.start())}: {label}")
    return findings


def main() -> int:
    findings: list[str] = []
    for path in tracked_files():
        if not path.is_file():
            continue
        findings.extend(scan_file(path))

    if findings:
        print("High-confidence secret patterns found:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1

    print("oss-secret-scan: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
