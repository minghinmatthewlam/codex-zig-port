#!/usr/bin/env python3
import json
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import time
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


def exercise_json_rpc(write_line, read_line) -> None:
    write_line(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "app-server-smoke", "version": "0"},
                "capabilities": {},
            },
        }
    )
    initialize = read_line()
    assert initialize["jsonrpc"] == "2.0"
    assert initialize["id"] == 1
    assert initialize["result"]["serverInfo"]["name"] == "codex-zig-app-server"
    assert isinstance(initialize["result"]["capabilities"], dict)

    write_line({"jsonrpc": "2.0", "id": "missing", "method": "codex/unknown"})
    missing = read_line()
    assert missing["id"] == "missing"
    assert missing["error"]["code"] == -32601
    assert "unsupported app-server method" in missing["error"]["message"]


def run_stdio_smoke(binary: Path) -> None:
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
        exercise_json_rpc(
            lambda payload: write_json_line(proc, payload),
            lambda: read_json_line(proc, 5),
        )

        assert proc.stdin is not None
        proc.stdin.close()
        proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def wait_for_socket(socket_path: Path, proc: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if socket_path.exists():
            return
        if proc.poll() is not None:
            raise AssertionError(f"app-server exited before socket appeared: {proc.stderr.read()}")
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for Unix socket: {socket_path}")


def read_json_line_from_socket(reader) -> dict:
    line = reader.readline()
    if not line:
        raise AssertionError("app-server closed Unix socket before response")
    return json.loads(line)


def write_json_line_to_socket(writer, payload: dict) -> None:
    writer.write(json.dumps(payload, separators=(",", ":")) + "\n")
    writer.flush()


def exercise_unix_socket(binary: Path, listen_url: str, socket_path: Path, env: dict[str, str] | None = None) -> None:
    proc = subprocess.Popen(
        [str(binary), "app-server", "--listen", listen_url],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        wait_for_socket(socket_path, proc, 5)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(str(socket_path))
            with client.makefile("r", encoding="utf-8", newline="\n") as reader:
                with client.makefile("w", encoding="utf-8", newline="\n") as writer:
                    exercise_json_rpc(
                        lambda payload: write_json_line_to_socket(writer, payload),
                        lambda: read_json_line_from_socket(reader),
                    )
        proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def run_unix_path_smoke(binary: Path) -> None:
    socket_dir = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-", dir="/tmp"))
    try:
        socket_path = socket_dir / "app-server.sock"
        exercise_unix_socket(binary, f"unix://{socket_path}", socket_path)
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)


def run_unix_default_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-home-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        socket_path = codex_home / "app-server-control" / "app-server-control.sock"
        exercise_unix_socket(binary, "unix://", socket_path, env=env)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_proxy_smoke(binary: Path) -> None:
    socket_dir = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-proxy-", dir="/tmp"))
    try:
        socket_path = socket_dir / "app-server.sock"
        server = subprocess.Popen(
            [str(binary), "app-server", "--listen", f"unix://{socket_path}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        proxy = None
        try:
            wait_for_socket(socket_path, server, 5)
            proxy = subprocess.Popen(
                [str(binary), "app-server", "proxy", "--sock", str(socket_path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            exercise_json_rpc(
                lambda payload: write_json_line(proxy, payload),
                lambda: read_json_line(proxy, 5),
            )
            assert proxy.stdin is not None
            proxy.stdin.close()
            proxy.wait(timeout=5)
            if proxy.returncode != 0:
                raise AssertionError(
                    f"app-server proxy exited {proxy.returncode}: {proxy.stderr.read()}"
                )
            server.wait(timeout=5)
            if server.returncode != 0:
                raise AssertionError(
                    f"app-server exited {server.returncode}: {server.stderr.read()}"
                )
        finally:
            if proxy is not None and proxy.poll() is None:
                proxy.kill()
                proxy.wait(timeout=5)
            if server.poll() is None:
                server.kill()
                server.wait(timeout=5)
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)


def run_unix_refuses_regular_file_smoke(binary: Path) -> None:
    socket_dir = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-file-", dir="/tmp"))
    try:
        socket_path = socket_dir / "not-a-socket"
        socket_path.write_text("keep me", encoding="utf-8")
        proc = subprocess.run(
            [str(binary), "app-server", "--listen", f"unix://{socket_path}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert proc.returncode != 0
        assert "AppServerUnixSocketPathExists" in proc.stderr
        assert socket_path.read_text(encoding="utf-8") == "keep me"
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_stdio_smoke(binary)
    print("app-server-stdio-e2e: ok")
    run_unix_path_smoke(binary)
    print("app-server-unix-path-e2e: ok")
    run_unix_default_smoke(binary)
    print("app-server-unix-default-e2e: ok")
    run_proxy_smoke(binary)
    print("app-server-proxy-e2e: ok")
    run_unix_refuses_regular_file_smoke(binary)
    print("app-server-unix-regular-file-e2e: ok")


if __name__ == "__main__":
    main()
