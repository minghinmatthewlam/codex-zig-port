#!/usr/bin/env python3
import json
import selectors
import subprocess
import sys
from pathlib import Path


def read_json_line(proc: subprocess.Popen[str], timeout: float) -> dict:
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        events = selector.select(timeout)
    finally:
        selector.close()
    if not events:
        stderr = proc.stderr.read() if proc.poll() is not None else ""
        raise AssertionError(f"timed out waiting for app-server response\n{stderr}")
    line = proc.stdout.readline()
    if not line:
        stderr = proc.stderr.read()
        raise AssertionError(f"app-server closed stdout before response\n{stderr}")
    return json.loads(line)


def write_json_line(proc: subprocess.Popen[str], payload: dict) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def run_smoke(binary: Path) -> None:
    if not binary.exists():
        raise FileNotFoundError(f"binary not found: {binary}; run `zig build` first")

    proc = subprocess.Popen(
        [str(binary), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        write_json_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "app-server-smoke", "version": "0"},
                    "capabilities": {},
                },
            },
        )
        initialize = read_json_line(proc, 5)
        assert initialize["jsonrpc"] == "2.0"
        assert initialize["id"] == 1
        assert initialize["result"]["serverInfo"]["name"] == "codex-zig-app-server"
        assert isinstance(initialize["result"]["capabilities"], dict)

        write_json_line(
            proc,
            {"jsonrpc": "2.0", "id": "missing", "method": "codex/unknown"},
        )
        missing = read_json_line(proc, 5)
        assert missing["id"] == "missing"
        assert missing["error"]["code"] == -32601
        assert "unsupported app-server method" in missing["error"]["message"]

        assert proc.stdin is not None
        proc.stdin.close()
        proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_smoke(binary)
    print("app-server-stdio-e2e: ok")


if __name__ == "__main__":
    main()
