#!/usr/bin/env python3
import argparse
import base64
import errno
import hashlib
import json
import os
import pty
import select
import shutil
import socket
import ssl
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ALT_SCREEN_ENTER = b"\x1b[?1049h"
ALT_SCREEN_LEAVE = b"\x1b[?1049l"


APPLY_TASK_DIFF = """diff --git a/scripts/fibonacci.js b/scripts/fibonacci.js
new file mode 100644
index 0000000..1d92452
--- /dev/null
+++ b/scripts/fibonacci.js
@@ -0,0 +1,12 @@
+#!/usr/bin/env node
+
+function fibonacci(n) {
+  if (n < 0) throw new Error("n must be non-negative");
+  if (n <= 1) return n;
+  let prev = 0;
+  let curr = 1;
+  for (let i = 2; i <= n; i++) {
+    [prev, curr] = [curr, prev + curr];
+  }
+  return curr;
+}
"""


def seed_memory_state_db(codex_home: Path) -> Path:
    db_path = codex_home / "state_5.sqlite"
    with sqlite3.connect(db_path) as db:
        db.executescript(
            """
            CREATE TABLE stage1_outputs (thread_id TEXT PRIMARY KEY, raw_memory TEXT);
            CREATE TABLE jobs (kind TEXT, job_key TEXT, status TEXT);
            INSERT INTO stage1_outputs (thread_id, raw_memory)
            VALUES ('thread-1', 'raw memory');
            INSERT INTO jobs (kind, job_key, status)
            VALUES
                ('memory_stage1', 'thread-1', 'completed'),
                ('memory_consolidate_global', 'global', 'completed'),
                ('unrelated', 'keep', 'completed');
            """
        )
    return db_path


def sqlite_count(db_path: Path, query: str) -> int:
    with sqlite3.connect(db_path) as db:
        row = db.execute(query).fetchone()
    assert row is not None
    return int(row[0])


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def sse(*events: dict) -> bytes:
    body = "".join(
        f"data: {json.dumps(event, separators=(',', ':'))}\n" for event in events
    )
    return (body + "data: [DONE]\n").encode()


def latest_user_text(items: list[object]) -> str:
    latest = ""
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message" or item.get("role") != "user":
            continue
        parts = item.get("content", [])
        if not isinstance(parts, list):
            continue
        texts = [
            part.get("text", "")
            for part in parts
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        ]
        latest = "\n".join(texts)
    return latest


def latest_user_images(items: list[object]) -> list[str]:
    latest: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message" or item.get("role") != "user":
            continue
        parts = item.get("content", [])
        if not isinstance(parts, list):
            continue
        latest = [
            part.get("image_url", "")
            for part in parts
            if isinstance(part, dict)
            and part.get("type") == "input_image"
            and isinstance(part.get("image_url"), str)
        ]
    return latest


def has_tool_output(items: list[object], call_id: str) -> bool:
    return any(
        isinstance(item, dict)
        and item.get("type") == "function_call_output"
        and item.get("call_id") == call_id
        for item in items
    )


class MockResponsesHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.server.request_count += 1
        self.server.get_paths.append(self.path)
        self.server.get_headers.append(dict(self.headers.items()))

        if self.path == "/wham/tasks/task-apply":
            payload = json.dumps(
                {
                    "current_diff_task_turn": {
                        "output_items": [
                            {"type": "message", "content": []},
                            {
                                "type": "pr",
                                "output_diff": {"diff": APPLY_TASK_DIFF},
                            },
                        ]
                    }
                },
                separators=(",", ":"),
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path == "/remote-fork-claim" and self.server.remote_fork_bundle:
            payload = self.server.remote_fork_bundle
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        payload = b'{"error":"not found"}'
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length)
        try:
            request = json.loads(raw_body)
        except json.JSONDecodeError:
            request = {}

        items = request.get("input", [])
        if not isinstance(items, list):
            items = []
        latest_prompt = latest_user_text(items)
        latest_images = latest_user_images(items)
        if "describe attached image" in latest_prompt and latest_images:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "image received\n",
                },
            )
        elif "describe attached image" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "image missing\n",
                },
            )
        elif "summarize the mentioned file" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "mentioned file received\n",
                },
            )
        elif "draft a plan" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": (
                        "Plan intro\n"
                        "<proposed_plan>\n"
                        "1. Inspect the repo\n"
                        "2. Patch the feature\n"
                        "3. Verify the TUI\n"
                        "</proposed_plan>\n"
                        "Plan outro\n"
                    ),
                },
            )
        elif "side question" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "side answer\n",
                },
            )
        elif "long remote answer" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "long remote answer start\n"
                    + ("x" * 70000)
                    + "\nlong remote answer tail\n",
                },
            )
        elif "Summarize this conversation" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "compact summary\n",
                },
            )
        elif "track this checklist" in latest_prompt and has_tool_output(
            items, "call-tui-e2e-plan"
        ):
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "plan tracked\n",
                },
            )
        elif "track this checklist" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "I'll track it.\n",
                },
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "function_call",
                        "call_id": "call-tui-e2e-plan",
                        "name": "update_plan",
                        "arguments": json.dumps(
                            {
                                "explanation": "Demo progress",
                                "plan": [
                                    {"step": "Inspect repo", "status": "completed"},
                                    {"step": "Patch feature", "status": "in_progress"},
                                    {"step": "Verify behavior", "status": "pending"},
                                ],
                            },
                            separators=(",", ":"),
                        ),
                    },
                },
            )
        elif "create the demo file" in latest_prompt and has_tool_output(
            items, "call-tui-e2e-2"
        ):
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "demo file created\n",
                },
            )
        elif "create the demo file" in latest_prompt:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "I'll patch in the demo file.\n",
                },
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "function_call",
                        "call_id": "call-tui-e2e-2",
                        "name": "apply_patch",
                        "arguments": json.dumps(
                            {
                                "patch": (
                                    "*** Begin Patch\n"
                                    "*** Add File: codex_zig_tui_file.txt\n"
                                    "+created by codex-zig tui e2e\n"
                                    "*** End Patch"
                                )
                            },
                            separators=(",", ":"),
                        ),
                    },
                },
            )
        elif has_tool_output(items, "call-tui-e2e-1"):
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "background terminal started\n",
                },
            )
        else:
            payload = sse(
                {
                    "type": "response.output_text.delta",
                    "delta": "I'll start a background command.\n",
                },
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "function_call",
                        "call_id": "call-tui-e2e-1",
                        "name": "exec_command",
                        "arguments": json.dumps(
                            {
                                "cmd": "printf READY; sleep 30",
                                "tty": True,
                                "yield_time_ms": 1000,
                                "max_output_tokens": 2000,
                            },
                            separators=(",", ":"),
                        ),
                    },
                },
            )

        self.server.request_count += 1
        self.server.request_bodies.append(request)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class MockResponsesServer(ThreadingHTTPServer):
    request_count: int
    request_bodies: list[dict]
    get_paths: list[str]
    get_headers: list[dict[str, str]]
    remote_fork_bundle: bytes


def start_mock_server(port: int) -> MockResponsesServer:
    server = MockResponsesServer(("127.0.0.1", port), MockResponsesHandler)
    server.request_count = 0
    server.request_bodies = []
    server.get_paths = []
    server.get_headers = []
    server.remote_fork_bundle = b""
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def read_available(master_fd: int, output: bytearray, timeout: float = 0.05) -> None:
    while True:
        readable, _, _ = select.select([master_fd], [], [], timeout)
        if not readable:
            return
        try:
            chunk = os.read(master_fd, 8192)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return
            raise
        if not chunk:
            return
        output.extend(chunk)
        timeout = 0


def wait_for(
    master_fd: int,
    output: bytearray,
    needle: bytes,
    timeout: float,
    start: int = 0,
) -> None:
    deadline = time.monotonic() + timeout
    while needle not in output[start:]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"timed out waiting for {needle!r}\n\n{rendered}")
        readable, _, _ = select.select([master_fd], [], [], min(0.2, remaining))
        if not readable:
            continue
        try:
            chunk = os.read(master_fd, 8192)
        except OSError as exc:
            if exc.errno == errno.EIO:
                rendered = output.decode(errors="replace")
                raise AssertionError(f"process exited before {needle!r}\n\n{rendered}")
            raise
        if not chunk:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"process closed before {needle!r}\n\n{rendered}")
        output.extend(chunk)


def send_line(master_fd: int, line: str) -> None:
    os.write(master_fd, line.encode() + b"\n")


def wait_for_path(path: Path, proc: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        if proc.poll() is not None:
            stderr = proc.stderr.read() if proc.stderr else ""
            raise AssertionError(f"process exited before {path} appeared:\n{stderr}")
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}")


def wait_for_websocket_bind(proc: subprocess.Popen[str], timeout: float) -> tuple[str, int]:
    assert proc.stderr is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"app-server exited before websocket bind: {proc.stderr.read()}")
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([proc.stderr], [], [], min(remaining, 0.05))
        if not ready:
            continue
        line = proc.stderr.readline()
        if line:
            for token in line.split():
                if not token.startswith("ws://"):
                    continue
                host, port_text = token.removeprefix("ws://").rsplit(":", 1)
                return host, int(port_text)
    raise AssertionError("timed out waiting for websocket bind address")


def generate_localhost_self_signed_cert(root: Path) -> tuple[Path, Path]:
    cert_path = root / "localhost.crt"
    key_path = root / "localhost.key"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(key_path),
            "-out",
            str(cert_path),
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return cert_path, key_path


def remote_control_link(output: bytearray, marker: str, start: int = 0) -> str:
    rendered = output[start:].decode(errors="replace")
    for line in rendered.splitlines():
        if marker in line:
            return line.split(marker, 1)[1].strip()
    full_output = output.decode(errors="replace")
    raise AssertionError(f"remote-control link {marker!r} not found:\n\n{full_output}")


def remote_control_url(output: bytearray, start: int = 0) -> str:
    return remote_control_link(output, "Controller link:", start)


def remote_control_share_url(output: bytearray, start: int = 0) -> str:
    return remote_control_link(output, "Share link:", start)


def remote_control_request(control_url: str, method: str, path: str, body: bytes = b"") -> str:
    parsed = urlparse(control_url)
    token = parse_qs(parsed.query).get("token", [None])[0]
    if not parsed.port or not token:
        raise AssertionError(f"invalid remote-control URL: {control_url}")
    target = f"{path}?token={token}"
    headers = [
        f"{method} {target} HTTP/1.1",
        "Host: 127.0.0.1",
        "Connection: close",
    ]
    if body:
        headers.append("Content-Type: application/json")
        headers.append(f"Content-Length: {len(body)}")
    request = ("\r\n".join(headers) + "\r\n\r\n").encode() + body
    with socket.create_connection(("127.0.0.1", parsed.port), timeout=2) as sock:
        sock.sendall(request)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode(errors="replace")


def remote_control_state(control_url: str) -> dict[str, object]:
    response = remote_control_request(control_url, "GET", "/api/state")
    if not response.startswith("HTTP/1.1 200 OK"):
        raise AssertionError(f"unexpected remote-control state response:\n{response}")
    _, _, body = response.partition("\r\n\r\n")
    return json.loads(body)


def remote_control_event_stream(control_url: str) -> tuple[socket.socket, bytes]:
    parsed = urlparse(control_url)
    token = parse_qs(parsed.query).get("token", [None])[0]
    if not parsed.port or not token:
        raise AssertionError(f"invalid remote-control URL: {control_url}")
    target = f"/api/events?token={token}"
    request = (
        "\r\n".join(
            [
                f"GET {target} HTTP/1.1",
                "Host: 127.0.0.1",
                "Accept: text/event-stream",
                "Connection: close",
            ]
        )
        + "\r\n\r\n"
    ).encode()
    sock = socket.create_connection(("127.0.0.1", parsed.port), timeout=2)
    sock.settimeout(2)
    sock.sendall(request)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            sock.close()
            raise AssertionError("remote-control event stream closed before headers")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    head_text = head.decode(errors="replace")
    if not head_text.startswith("HTTP/1.1 200 OK"):
        sock.close()
        raise AssertionError(f"unexpected remote-control event stream headers:\n{head_text}")
    if "Content-Type: text/event-stream" not in head_text:
        sock.close()
        raise AssertionError(f"remote-control event stream missing content-type:\n{head_text}")
    return sock, body


def read_remote_control_state_event(
    sock: socket.socket,
    buffer: bytes,
    timeout: float,
) -> tuple[dict[str, object], bytes]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if b"\n\n" in buffer:
            block, _, buffer = buffer.partition(b"\n\n")
            event_name = "message"
            data_lines: list[str] = []
            for line in block.decode(errors="replace").splitlines():
                if line.startswith("event:"):
                    event_name = line.split(":", 1)[1].strip()
                elif line.startswith("data:"):
                    data_lines.append(line.split(":", 1)[1].lstrip())
            if event_name != "state":
                continue
            return json.loads("\n".join(data_lines)), buffer
        remaining = max(0.05, deadline - time.monotonic())
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            raise AssertionError("remote-control event stream closed unexpectedly")
        buffer += chunk
    raise AssertionError("timed out waiting for remote-control state event")


def post_remote_control_message(control_url: str, message: str) -> None:
    body = json.dumps({"message": message}, separators=(",", ":")).encode()
    response = remote_control_request(control_url, "POST", "/api/message", body)
    if not response.startswith("HTTP/1.1 202 Accepted"):
        raise AssertionError(f"unexpected remote-control message response:\n{response}")


def post_remote_control_messages_concurrently(control_url: str, messages: list[str]) -> None:
    errors: list[str] = []

    def worker(message: str) -> None:
        try:
            post_remote_control_message(control_url, message)
        except BaseException as exc:
            errors.append(f"{message}: {exc}")

    threads = [threading.Thread(target=worker, args=(message,)) for message in messages]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if errors:
        raise AssertionError("concurrent remote-control POST failed:\n" + "\n".join(errors))


def wait_for_remote_control_stop(control_url: str, timeout: float) -> None:
    parsed = urlparse(control_url)
    if not parsed.port:
        raise AssertionError(f"invalid remote-control URL: {control_url}")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", parsed.port), timeout=0.1):
                pass
        except OSError:
            return
        time.sleep(0.05)
    raise AssertionError("remote-control server still accepts connections after TUI exit")


def wait_for_remote_control_messages(
    control_url: str,
    user_text: str,
    assistant_text: str,
    timeout: float,
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    last_state: dict[str, object] = {}
    while time.monotonic() < deadline:
        last_state = remote_control_state(control_url)
        messages = last_state.get("messages")
        if isinstance(messages, list):
            has_user = any(
                isinstance(message, dict)
                and message.get("role") == "user"
                and message.get("text") == user_text
                for message in messages
            )
            has_assistant = any(
                isinstance(message, dict)
                and message.get("role") == "assistant"
                and message.get("text") == assistant_text
                for message in messages
            )
            if has_user and has_assistant:
                return last_state
        time.sleep(0.05)
    raise AssertionError(f"remote-control state did not include completed turn: {last_state!r}")


def wait_for_remote_control_event_messages(
    sock: socket.socket,
    buffer: bytes,
    user_text: str,
    assistant_text: str,
    timeout: float,
) -> tuple[dict[str, object], bytes]:
    deadline = time.monotonic() + timeout
    last_state: dict[str, object] = {}
    while time.monotonic() < deadline:
        state, buffer = read_remote_control_state_event(sock, buffer, max(0.05, deadline - time.monotonic()))
        last_state = state
        messages = state.get("messages")
        if isinstance(messages, list):
            has_user = any(
                isinstance(message, dict)
                and message.get("role") == "user"
                and message.get("text") == user_text
                for message in messages
            )
            has_assistant = any(
                isinstance(message, dict)
                and message.get("role") == "assistant"
                and message.get("text") == assistant_text
                for message in messages
            )
            if has_user and has_assistant:
                return state, buffer
    raise AssertionError(f"remote-control event stream did not include completed turn: {last_state!r}")


def run_alt_screen_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
) -> None:
    alt_output = bytearray()
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        [
            str(binary),
            "-c",
            f"chatgpt_base_url=http://127.0.0.1:{port}",
        ],
        cwd=workspace,
        env=env,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
    os.close(slave_fd)
    try:
        wait_for(master_fd, alt_output, ALT_SCREEN_ENTER, 5)
        wait_for(master_fd, alt_output, b"Type /help for commands", 5)
        mark = len(alt_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, alt_output, ALT_SCREEN_LEAVE, 5, mark)
        exit_code = proc.wait(timeout=5)
        if exit_code != 0:
            rendered = alt_output.decode(errors="replace")
            raise AssertionError(
                f"alternate-screen smoke exited with {exit_code}\n\n{rendered}"
            )
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        os.close(master_fd)


def run_alt_screen_never_config_smoke(
    binary: Path,
    base_env: dict[str, str],
    workspace: Path,
    port: int,
) -> None:
    with tempfile.TemporaryDirectory(prefix="codex-zig-alt-screen-never.") as home:
        Path(home, "auth.json").write_text(
            json.dumps({"tokens": {"access_token": "alt-screen-token", "account_id": "acct"}})
        )
        Path(home, "config.toml").write_text('[tui]\nalternate_screen = "never"\n')
        env = base_env.copy()
        env["CODEX_HOME"] = home

        alt_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [
                str(binary),
                "-c",
                f"chatgpt_base_url=http://127.0.0.1:{port}",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        try:
            wait_for(master_fd, alt_output, b"Type /help for commands", 5)
            if ALT_SCREEN_ENTER in alt_output or ALT_SCREEN_LEAVE in alt_output:
                raise AssertionError('tui.alternate_screen = "never" emitted alternate-screen escapes')
            mark = len(alt_output)
            send_line(master_fd, "/quit")
            wait_for(master_fd, alt_output, b"bye", 5, mark)
            read_available(master_fd, alt_output)
            if ALT_SCREEN_ENTER in alt_output or ALT_SCREEN_LEAVE in alt_output:
                raise AssertionError('tui.alternate_screen = "never" emitted alternate-screen escapes')
            exit_code = proc.wait(timeout=5)
            if exit_code != 0:
                rendered = alt_output.decode(errors="replace")
                raise AssertionError(
                    f'alternate-screen "never" smoke exited with {exit_code}\n\n{rendered}'
                )
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            os.close(master_fd)


def run_initial_image_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    image_path = workspace / "tiny.png"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\ncodex-zig-image-smoke\n")
    start_requests = server.request_count

    image_output = bytearray()
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        [
            str(binary),
            "--no-alt-screen",
            "-c",
            f"chatgpt_base_url=http://127.0.0.1:{port}",
            "--image",
            str(image_path),
            "describe attached image",
        ],
        cwd=workspace,
        env=env,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
    os.close(slave_fd)
    try:
        wait_for(master_fd, image_output, b"image received", 8)
        mark = len(image_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, image_output, b"bye", 5, mark)
        exit_code = proc.wait(timeout=5)
        if exit_code != 0:
            rendered = image_output.decode(errors="replace")
            raise AssertionError(
                f"initial image smoke exited with {exit_code}\n\n{rendered}"
            )
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        os.close(master_fd)

    bodies = server.request_bodies[start_requests:]
    matching = [
        body
        for body in bodies
        if "describe attached image" in latest_user_text(body.get("input", []))
    ]
    if not matching:
        raise AssertionError("initial image smoke did not send the prompt request")
    images = latest_user_images(matching[-1].get("input", []))
    if len(images) != 1 or not images[0].startswith("data:image/png;base64,"):
        raise AssertionError(f"expected one PNG input_image, saw {images!r}")


def feature_state(output: str, key: str) -> str | None:
    for line in output.splitlines():
        parts = line.split()
        if parts and parts[0] == key:
            return parts[-1]
    return None


def run_feature_toggle_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    root_result = subprocess.run(
        [
            str(binary),
            "--enable",
            "goals",
            "--disable=shell_tool",
            "features",
            "list",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if feature_state(root_result.stdout, "goals") != "true":
        raise AssertionError(
            f"expected root --enable goals in feature list:\n{root_result.stdout}"
        )
    if feature_state(root_result.stdout, "shell_tool") != "false":
        raise AssertionError(
            f"expected root --disable shell_tool in feature list:\n{root_result.stdout}"
        )

    list_result = subprocess.run(
        [
            str(binary),
            "features",
            "list",
            "--enable=goals",
            "--disable",
            "shell_tool",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if feature_state(list_result.stdout, "goals") != "true":
        raise AssertionError(
            f"expected list --enable goals in feature list:\n{list_result.stdout}"
        )
    if feature_state(list_result.stdout, "shell_tool") != "false":
        raise AssertionError(
            f"expected list --disable shell_tool in feature list:\n{list_result.stdout}"
        )


def run_help_command_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    root_result = subprocess.run(
        [str(binary), "help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig help [COMMAND]" not in root_result.stderr:
        raise AssertionError(
            f"expected root help command in output:\n{root_result.stderr}"
        )
    if "codex-zig --remote unix://PATH" not in root_result.stderr:
        raise AssertionError(f"expected remote flag help output:\n{root_result.stderr}")
    if "codex-zig --remote-control" not in root_result.stderr:
        raise AssertionError(f"expected remote-control flag help output:\n{root_result.stderr}")

    exec_result = subprocess.run(
        [str(binary), "help", "exec"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig exec [OPTIONS] [PROMPT]" not in exec_result.stderr:
        raise AssertionError(f"expected exec help output:\n{exec_result.stderr}")

    apply_result = subprocess.run(
        [str(binary), "help", "apply"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig apply TASK_ID" not in apply_result.stderr:
        raise AssertionError(f"expected apply help output:\n{apply_result.stderr}")

    alias_result = subprocess.run(
        [str(binary), "help", "a"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig a TASK_ID" not in alias_result.stderr:
        raise AssertionError(f"expected apply alias help output:\n{alias_result.stderr}")

    completion_result = subprocess.run(
        [str(binary), "completion", "bash"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    for command in [
        'commands="a ',
        "app-server",
        "apply",
        "cloud-tasks",
        "remote-control",
        "remote-fork",
    ]:
        if command not in completion_result.stdout:
            raise AssertionError(
                f"expected {command} in bash completion:\n{completion_result.stdout}"
            )


def run_unimplemented_command_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    remote_help = subprocess.run(
        [str(binary), "remote-control", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Start a headless app-server with remote control enabled" not in remote_help.stderr:
        raise AssertionError(
            f"expected remote-control help output:\n{remote_help.stderr}"
        )

    remote_result = subprocess.run(
        [
            str(binary),
            "remote-control",
            "--disable",
            "remote_control",
            "--enable=goals",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if remote_result.returncode == 0:
        raise AssertionError("remote-control unexpectedly succeeded")
    if "headless app-server remote control is not implemented yet" not in remote_result.stderr:
        raise AssertionError(
            f"expected remote-control transport gap message:\n{remote_result.stderr}"
        )

    remote_positional_result = subprocess.run(
        [str(binary), "remote-control", "stop"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if remote_positional_result.returncode == 0:
        raise AssertionError("remote-control positional arg unexpectedly succeeded")
    if "UnexpectedRemoteControlArgument" not in remote_positional_result.stderr:
        raise AssertionError(
            f"expected remote-control positional-arg rejection:\n{remote_positional_result.stderr}"
        )

    cloud_help = subprocess.run(
        [str(binary), "cloud", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Browse tasks from Codex Cloud" not in cloud_help.stderr:
        raise AssertionError(f"expected cloud help output:\n{cloud_help.stderr}")
    if "exec    Submit a new Codex Cloud task" not in cloud_help.stderr:
        raise AssertionError(f"expected cloud exec subcommand in help:\n{cloud_help.stderr}")
    if "diff    Show the unified diff" not in cloud_help.stderr:
        raise AssertionError(f"expected cloud subcommands in help:\n{cloud_help.stderr}")

    cloud_alias_help = subprocess.run(
        [str(binary), "cloud-tasks", "help", "list"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Usage:" not in cloud_alias_help.stderr or "cloud list" not in cloud_alias_help.stderr:
        raise AssertionError(f"expected cloud alias list help:\n{cloud_alias_help.stderr}")

    cloud_global_help = subprocess.run(
        [str(binary), "cloud", "--enable", "goals", "help", "list"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Usage:" not in cloud_global_help.stderr or "cloud list" not in cloud_global_help.stderr:
        raise AssertionError(
            f"expected cloud help after global options:\n{cloud_global_help.stderr}"
        )

    cloud_exec = subprocess.run(
        [
            str(binary),
            "cloud",
            "exec",
            "--env",
            "env-id",
            "--attempts",
            "4",
            "--branch=feature",
            "--enable=goals",
            "write tests",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_exec.returncode == 0:
        raise AssertionError("cloud exec unexpectedly succeeded")
    if "codex-zig cloud exec parsed Rust-compatible options" not in cloud_exec.stderr:
        raise AssertionError(f"expected cloud exec parse message:\n{cloud_exec.stderr}")

    cloud_plus_attempt = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "env-id", "--attempts", "+1", "write tests"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_plus_attempt.returncode == 0:
        raise AssertionError("cloud exec with plus-prefixed attempt unexpectedly succeeded")
    if "codex-zig cloud exec parsed Rust-compatible options" not in cloud_plus_attempt.stderr:
        raise AssertionError(
            f"expected cloud exec plus-prefixed attempt to parse:\n{cloud_plus_attempt.stderr}"
        )

    cloud_stdin_query = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "env-id", "-"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_stdin_query.returncode == 0:
        raise AssertionError("cloud exec with stdin query marker unexpectedly succeeded")
    if "codex-zig cloud exec parsed Rust-compatible options" not in cloud_stdin_query.stderr:
        raise AssertionError(
            f"expected cloud exec stdin query marker to parse:\n{cloud_stdin_query.stderr}"
        )

    cloud_dash_query = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "env-id", "--", "--fix"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_dash_query.returncode == 0:
        raise AssertionError("cloud exec with dash-prefixed query unexpectedly succeeded")
    if "codex-zig cloud exec parsed Rust-compatible options" not in cloud_dash_query.stderr:
        raise AssertionError(
            f"expected cloud exec dash-prefixed query to parse:\n{cloud_dash_query.stderr}"
        )

    cloud_missing_env = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "--attempts", "2"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_missing_env.returncode == 0:
        raise AssertionError("cloud exec with missing env value unexpectedly succeeded")
    if "MissingCloudEnvironment" not in cloud_missing_env.stderr:
        raise AssertionError(
            f"expected cloud missing env validation error:\n{cloud_missing_env.stderr}"
        )

    cloud_exec_help = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "list", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "cloud exec" not in cloud_exec_help.stderr or "cloud list" in cloud_exec_help.stderr:
        raise AssertionError(
            f"expected cloud exec help despite option value named list:\n{cloud_exec_help.stderr}"
        )

    cloud_invalid_attempt_help = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "env-id", "--attempts", "5", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_invalid_attempt_help.returncode == 0:
        raise AssertionError("cloud exec invalid attempt before help unexpectedly succeeded")
    if "InvalidCloudAttempts" not in cloud_invalid_attempt_help.stderr:
        raise AssertionError(
            f"expected cloud invalid attempt before help to stay invalid:\n{cloud_invalid_attempt_help.stderr}"
        )

    cloud_unknown_option_help = subprocess.run(
        [str(binary), "cloud", "exec", "--env", "env-id", "--bogus", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_unknown_option_help.returncode == 0:
        raise AssertionError("cloud exec unknown option before help unexpectedly succeeded")
    if "UnknownCloudOption" not in cloud_unknown_option_help.stderr:
        raise AssertionError(
            f"expected cloud unknown option before help to stay invalid:\n{cloud_unknown_option_help.stderr}"
        )

    cloud_duplicate_limit = subprocess.run(
        [str(binary), "cloud", "list", "--limit", "2", "--limit", "3"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_duplicate_limit.returncode == 0:
        raise AssertionError("cloud list with duplicate limit unexpectedly succeeded")
    if "DuplicateCloudLimit" not in cloud_duplicate_limit.stderr:
        raise AssertionError(
            f"expected cloud duplicate limit validation error:\n{cloud_duplicate_limit.stderr}"
        )

    cloud_bad_attempts = subprocess.run(
        [str(binary), "cloud", "diff", "--attempt=5", "task-id"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if cloud_bad_attempts.returncode == 0:
        raise AssertionError("cloud diff with bad attempt unexpectedly succeeded")
    if "InvalidCloudAttempts" not in cloud_bad_attempts.stderr:
        raise AssertionError(
            f"expected cloud attempt validation error:\n{cloud_bad_attempts.stderr}"
        )


def run_remote_fork_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    thread_id = "00000000-0000-4000-8000-000000000456"
    rollout_file_name = f"rollout-2026-05-15T00-00-00-{thread_id}.jsonl"
    rollout_jsonl = "\n".join(
        [
            json.dumps(
                {
                    "timestamp": "2026-05-15T00:00:00Z",
                    "type": "session_meta",
                    "payload": {
                        "id": thread_id,
                        "timestamp": "2026-05-15T00:00:00Z",
                        "cwd": str(workspace),
                        "originator": "codex",
                        "cli_version": "0.0.0",
                        "source": "cli",
                        "thread_source": "user",
                        "model_provider": "mock_provider",
                    },
                },
                separators=(",", ":"),
            ),
            json.dumps(
                {
                    "timestamp": "2026-05-15T00:00:00Z",
                    "type": "response_item",
                    "payload": {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "remote hello"}],
                    },
                },
                separators=(",", ":"),
            ),
            "",
        ]
    )
    server.remote_fork_bundle = json.dumps(
        {
            "protocolVersion": 1,
            "threadId": thread_id,
            "cwd": str(workspace),
            "rolloutFileName": rollout_file_name,
            "rolloutJsonl": rollout_jsonl,
        },
        separators=(",", ":"),
    ).encode()

    remote_home = Path(env["CODEX_HOME"]) / "remote-fork-home"
    remote_env = env.copy()
    remote_env["CODEX_HOME"] = str(remote_home)
    result = subprocess.run(
        [
            str(binary),
            "--oss",
            "--local-provider=ollama",
            "--no-alt-screen",
            "remote-fork",
            f"http://127.0.0.1:{port}/remote-fork-claim",
        ],
        cwd=workspace,
        env=remote_env,
        input="",
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"remote-fork smoke failed with {result.returncode}:\n{result.stderr}"
        )

    imported_path = remote_home / "sessions" / "remote-forks" / rollout_file_name
    if imported_path.read_text() != rollout_jsonl:
        raise AssertionError(f"unexpected remote-fork import at {imported_path}")
    if "forked:" not in result.stderr or thread_id not in result.stderr:
        raise AssertionError(f"expected forked TUI output:\n{result.stderr}")
    if "remote-forks" not in result.stderr:
        raise AssertionError(f"expected remote-forks source path:\n{result.stderr}")
    if "/remote-fork-claim" not in server.get_paths:
        raise AssertionError(f"expected remote fork claim request, saw {server.get_paths!r}")


def write_marketplace_fixture(root: Path, name: str, plugin_name: str) -> None:
    root.joinpath(".agents", "plugins").mkdir(parents=True)
    root.joinpath("plugins", plugin_name, ".codex-plugin").mkdir(parents=True)
    root.joinpath(".agents", "plugins", "marketplace.json").write_text(
        json.dumps(
            {
                "name": name,
                "plugins": [
                    {
                        "name": plugin_name,
                        "source": {
                            "source": "local",
                            "path": f"./plugins/{plugin_name}",
                        },
                    }
                ],
            }
        )
    )
    root.joinpath("plugins", plugin_name, ".codex-plugin", "plugin.json").write_text(
        json.dumps({"name": plugin_name})
    )


def write_git_marketplace_fixture(root: Path, name: str, plugin_name: str) -> None:
    write_marketplace_fixture(root, name, plugin_name)
    git(root, "init")
    git(root, "config", "user.name", "Codex Zig Smoke")
    git(root, "config", "user.email", "codex-zig-smoke@example.invalid")
    git(root, "add", ".")
    git(root, "commit", "-m", "init")
    git(root, "branch", "-M", "release")


def write_git_url_rewrite_config(path: Path, source_url: str, repo: Path) -> None:
    path.write_text(
        "\n".join(
            [
                '[protocol "file"]',
                "    allow = always",
                f'[url "{repo.resolve().as_uri()}"]',
                f"    insteadOf = {source_url}",
                "",
            ]
        )
    )


def run_plugin_marketplace_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    root_help = subprocess.run(
        [str(binary), "plugin", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig plugin marketplace <COMMAND>" not in root_help.stderr:
        raise AssertionError(f"expected plugin root help output:\n{root_help.stderr}")

    help_command = subprocess.run(
        [str(binary), "help", "plugin"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig plugin marketplace <COMMAND>" not in help_command.stderr:
        raise AssertionError(f"expected help plugin output:\n{help_command.stderr}")

    marketplace_help = subprocess.run(
        [str(binary), "plugin", "marketplace", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig plugin marketplace <COMMAND>" not in marketplace_help.stderr:
        raise AssertionError(
            f"expected plugin marketplace help output:\n{marketplace_help.stderr}"
        )

    help_cases = [
        (["add", "--help"], "codex-zig plugin marketplace add"),
        (["upgrade", "--help"], "codex-zig plugin marketplace upgrade"),
        (["remove", "--help"], "codex-zig plugin marketplace remove"),
    ]
    for args, usage in help_cases:
        result = subprocess.run(
            [str(binary), "plugin", "marketplace", *args],
            cwd=workspace,
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
        if usage not in result.stderr:
            raise AssertionError(f"expected {usage} help output:\n{result.stderr}")

    source = workspace / "marketplace-source"
    git_source = workspace / "marketplace-git-source"
    git_config = workspace / "gitconfig"
    git_url = "https://github.com/owner/repo.git"
    write_marketplace_fixture(source, "debug", "sample")
    write_git_marketplace_fixture(git_source, "git-debug", "git-sample")
    write_git_url_rewrite_config(git_config, git_url, git_source)

    add = subprocess.run(
        [str(binary), "plugin", "marketplace", "add", str(source)],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Added marketplace `debug`" not in add.stderr:
        raise AssertionError(f"expected marketplace add output:\n{add.stderr}")
    config_text = Path(env["CODEX_HOME"], "config.toml").read_text()
    if "[marketplaces.debug]" not in config_text:
        raise AssertionError(f"expected marketplace config entry:\n{config_text}")

    repeated = subprocess.run(
        [str(binary), "plugin", "marketplace", "add", str(source)],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "is already added" not in repeated.stderr:
        raise AssertionError(f"expected marketplace already-added output:\n{repeated.stderr}")

    remove = subprocess.run(
        [str(binary), "plugin", "marketplace", "remove", "debug"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Removed marketplace `debug`." not in remove.stderr:
        raise AssertionError(f"expected marketplace remove output:\n{remove.stderr}")

    git_env = env.copy()
    git_env["GIT_CONFIG_GLOBAL"] = str(git_config)
    git_env["GIT_CONFIG_NOSYSTEM"] = "1"
    git_add = subprocess.run(
        [
            str(binary),
            "plugin",
            "marketplace",
            "add",
            "--ref",
            "release",
            "--sparse",
            ".agents",
            "--sparse",
            "plugins/git-sample",
            "owner/repo",
        ],
        cwd=workspace,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Added marketplace `git-debug`" not in git_add.stderr:
        raise AssertionError(f"expected git marketplace add output:\n{git_add.stderr}")
    if git_url not in git_add.stderr or "#release" not in git_add.stderr:
        raise AssertionError(f"expected git source display:\n{git_add.stderr}")
    git_root = Path(env["CODEX_HOME"], ".tmp", "marketplaces", "git-debug")
    if not git_root.joinpath("plugins", "git-sample", ".codex-plugin", "plugin.json").is_file():
        raise AssertionError(f"expected sparse git marketplace install at {git_root}")
    config_text = Path(env["CODEX_HOME"], "config.toml").read_text()
    for expected in [
        "[marketplaces.git-debug]",
        'source_type = "git"',
        f'source = "{git_url}"',
        'ref = "release"',
        'sparse_paths = [".agents", "plugins/git-sample"]',
    ]:
        if expected not in config_text:
            raise AssertionError(f"expected {expected!r} in config:\n{config_text}")

    git_repeated = subprocess.run(
        [
            str(binary),
            "plugin",
            "marketplace",
            "add",
            "--ref",
            "release",
            "--sparse",
            ".agents",
            "--sparse",
            "plugins/git-sample",
            "owner/repo",
        ],
        cwd=workspace,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "is already added" not in git_repeated.stderr:
        raise AssertionError(
            f"expected git marketplace already-added output:\n{git_repeated.stderr}"
        )

    git_source.joinpath("plugins", "git-sample", "VERSION").write_text("v2\n")
    git(git_source, "add", ".")
    git(git_source, "commit", "-m", "upgrade")
    upgraded_sha = git_output(git_source, "rev-parse", "release")

    git_upgrade = subprocess.run(
        [str(binary), "plugin", "marketplace", "upgrade", "git-debug"],
        cwd=workspace,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Upgraded marketplace `git-debug` to the latest configured revision." not in git_upgrade.stderr:
        raise AssertionError(f"expected git marketplace upgrade output:\n{git_upgrade.stderr}")
    if f"Installed marketplace root: {git_root}" not in git_upgrade.stderr:
        raise AssertionError(f"expected upgraded root output:\n{git_upgrade.stderr}")
    if git_root.joinpath("plugins", "git-sample", "VERSION").read_text() != "v2\n":
        raise AssertionError(f"expected upgraded git marketplace contents at {git_root}")
    config_text = Path(env["CODEX_HOME"], "config.toml").read_text()
    if f'last_revision = "{upgraded_sha}"' not in config_text:
        raise AssertionError(f"expected last_revision in config:\n{config_text}")
    metadata = json.loads(git_root.joinpath(".codex-marketplace-install.json").read_text())
    expected_metadata = {
        "source_type": "git",
        "source": git_url,
        "ref_name": "release",
        "sparse_paths": [".agents", "plugins/git-sample"],
        "revision": upgraded_sha,
    }
    if metadata != expected_metadata:
        raise AssertionError(f"unexpected marketplace install metadata: {metadata!r}")

    git_upgrade_repeat = subprocess.run(
        [str(binary), "plugin", "marketplace", "upgrade", "git-debug"],
        cwd=workspace,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Marketplace `git-debug` is already up to date." not in git_upgrade_repeat.stderr:
        raise AssertionError(
            f"expected git marketplace already-up-to-date output:\n{git_upgrade_repeat.stderr}"
        )

    git_remove = subprocess.run(
        [str(binary), "plugin", "marketplace", "remove", "git-debug"],
        cwd=workspace,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "Removed marketplace `git-debug`." not in git_remove.stderr:
        raise AssertionError(f"expected git marketplace remove output:\n{git_remove.stderr}")
    if git_root.exists():
        raise AssertionError(f"expected git marketplace root to be removed: {git_root}")


def assert_empty_dir(path: Path) -> None:
    if not path.is_dir():
        raise AssertionError(f"expected directory to exist: {path}")
    entries = list(path.iterdir())
    if entries:
        raise AssertionError(f"expected empty directory {path}, saw {entries!r}")


def run_debug_clear_memories_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    codex_home = Path(env["CODEX_HOME"])
    memories = codex_home / "memories"
    rollout_summaries = memories / "rollout_summaries"
    extensions = codex_home / "memories_extensions"
    rollout_summaries.mkdir(parents=True)
    extensions.mkdir()
    (memories / "MEMORY.md").write_text("stale memory index\n")
    (rollout_summaries / "rollout.md").write_text("stale rollout\n")
    (extensions / "scratch.txt").write_text("stale extension\n")

    help_result = subprocess.run(
        [str(binary), "debug", "clear-memories", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig debug clear-memories" not in help_result.stderr:
        raise AssertionError(
            f"expected debug clear-memories help output:\n{help_result.stderr}"
        )

    result = subprocess.run(
        [str(binary), "debug", "clear-memories"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "No state db found" not in result.stdout:
        raise AssertionError(f"expected no-state-db output:\n{result.stdout}")
    if "Cleared memory directories under" not in result.stdout:
        raise AssertionError(f"expected clear-directories output:\n{result.stdout}")
    assert_empty_dir(memories)
    assert_empty_dir(extensions)

    with tempfile.TemporaryDirectory(prefix="codex-zig-memory-state-db.") as state_home:
        state_env = env.copy()
        state_env["CODEX_HOME"] = state_home
        state_memories = Path(state_home) / "memories"
        state_memories.mkdir()
        state_memory_file = state_memories / "MEMORY.md"
        state_memory_file.write_text("stale state-backed memory\n")
        state_db = seed_memory_state_db(Path(state_home))

        state_result = subprocess.run(
            [str(binary), "debug", "clear-memories"],
            cwd=workspace,
            env=state_env,
            text=True,
            capture_output=True,
            check=True,
        )
        if "Cleared memory state from" not in state_result.stdout:
            raise AssertionError(
                f"expected state-db clear output:\n{state_result.stdout}"
            )
        assert_empty_dir(state_memories)
        if sqlite_count(state_db, "SELECT COUNT(*) FROM stage1_outputs") != 0:
            raise AssertionError("debug clear-memories left stage1 output rows")
        if (
            sqlite_count(
                state_db,
                "SELECT COUNT(*) FROM jobs WHERE kind = 'memory_stage1' OR kind = 'memory_consolidate_global'",
            )
            != 0
        ):
            raise AssertionError("debug clear-memories left memory job rows")
        if sqlite_count(state_db, "SELECT COUNT(*) FROM jobs WHERE kind = 'unrelated'") != 1:
            raise AssertionError("debug clear-memories removed unrelated jobs")

    with tempfile.TemporaryDirectory(prefix="codex-zig-memory-symlink.") as linked_home:
        linked_env = env.copy()
        linked_env["CODEX_HOME"] = linked_home
        target = Path(linked_home) / "outside"
        target.mkdir()
        target_file = target / "keep.txt"
        target_file.write_text("keep\n")
        (Path(linked_home) / "memories").symlink_to(target, target_is_directory=True)

        rejected = subprocess.run(
            [str(binary), "debug", "clear-memories"],
            cwd=workspace,
            env=linked_env,
            text=True,
            capture_output=True,
            check=False,
        )
        if rejected.returncode == 0:
            raise AssertionError("debug clear-memories accepted a symlinked root")
        if "SymlinkedMemoryRoot" not in rejected.stderr:
            raise AssertionError(
                f"expected symlinked-root rejection:\n{rejected.stderr}"
            )
        if target_file.read_text() != "keep\n":
            raise AssertionError("symlink rejection modified the target directory")


def run_debug_stub_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
) -> None:
    debug_env = env.copy()
    with tempfile.TemporaryDirectory(prefix="codex-zig-debug-app-server.") as debug_home:
        debug_env["CODEX_HOME"] = debug_home
        auth_source = Path(env["CODEX_HOME"]) / "auth.json"
        auth_target = Path(debug_home) / "auth.json"
        auth_target.write_text(auth_source.read_text(encoding="utf-8"), encoding="utf-8")

        app_server_help = subprocess.run(
            [str(binary), "debug", "app-server", "--help"],
            cwd=workspace,
            env=debug_env,
            text=True,
            capture_output=True,
            check=True,
        )
        if "codex-zig debug app-server send-message-v2" not in app_server_help.stderr:
            raise AssertionError(
                f"expected debug app-server help output:\n{app_server_help.stderr}"
            )

        send_message = subprocess.run(
            [
                str(binary),
                "-c",
                f"chatgpt_base_url=http://127.0.0.1:{port}",
                "debug",
                "app-server",
                "send-message-v2",
                "side question",
            ],
            cwd=workspace,
            env=debug_env,
            text=True,
            capture_output=True,
            check=True,
        )
        if "< turn/start response:" not in send_message.stdout:
            raise AssertionError(
                f"expected send-message-v2 turn response:\n{send_message.stdout}\n{send_message.stderr}"
            )
        if '"delta":"side answer\\n"' not in send_message.stdout:
            raise AssertionError(
                f"expected send-message-v2 streamed answer:\n{send_message.stdout}"
            )
        if '"method":"turn/completed"' not in send_message.stdout:
            raise AssertionError(
                f"expected send-message-v2 completion notification:\n{send_message.stdout}"
            )

    trace_help = subprocess.run(
        [str(binary), "debug", "trace-reduce", "--help"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    if "codex-zig debug trace-reduce" not in trace_help.stderr:
        raise AssertionError(
            f"expected debug trace-reduce help output:\n{trace_help.stderr}"
        )
    if "Replays stable rollout trace bundle lifecycle events into state JSON" not in trace_help.stderr:
        raise AssertionError(
            f"expected debug trace-reduce implemented help output:\n{trace_help.stderr}"
        )


def run_remote_flag_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    remote_env = env.copy()
    remote_env["CODEX_REMOTE_AUTH_TOKEN"] = "  remote-token  "
    insecure_token_result = subprocess.run(
        [
            str(binary),
            "--remote",
            "ws://example.com:4500",
            "--remote-auth-token-env",
            "CODEX_REMOTE_AUTH_TOKEN",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if insecure_token_result.returncode == 0:
        raise AssertionError("non-loopback ws remote auth token smoke unexpectedly succeeded")
    if "RemoteAuthTokenTransportUnsupported" not in insecure_token_result.stderr:
        raise AssertionError(
            "expected non-loopback ws remote auth token rejection:\n"
            f"{insecure_token_result.stderr}"
        )

    missing_token_result = subprocess.run(
        [
            str(binary),
            "--remote",
            "ws://127.0.0.1:4500",
            "--remote-auth-token-env",
            "CODEX_REMOTE_AUTH_TOKEN_MISSING",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if missing_token_result.returncode == 0:
        raise AssertionError("missing remote auth token smoke unexpectedly succeeded")
    if "RemoteAuthTokenEnvNotSet" not in missing_token_result.stderr:
        raise AssertionError(
            f"expected missing remote auth token validation failure:\n{missing_token_result.stderr}"
        )

    missing_remote_result = subprocess.run(
        [
            str(binary),
            "--remote-auth-token-env",
            "CODEX_REMOTE_AUTH_TOKEN",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if missing_remote_result.returncode == 0:
        raise AssertionError("remote auth token env without remote unexpectedly succeeded")
    if "RemoteAuthTokenEnvRequiresRemote" not in missing_remote_result.stderr:
        raise AssertionError(
            f"expected remote auth token env validation failure:\n{missing_remote_result.stderr}"
        )

    missing_local_remote_result = subprocess.run(
        [
            str(binary),
            "--remote-control-bind=127.0.0.1:0",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if missing_local_remote_result.returncode == 0:
        raise AssertionError("remote-control bind without flag unexpectedly succeeded")
    if "RemoteControlBindRequiresRemoteControl" not in missing_local_remote_result.stderr:
        raise AssertionError(
            f"expected local remote-control bind validation failure:\n{missing_local_remote_result.stderr}"
        )

    rejected_local_result = subprocess.run(
        [
            str(binary),
            "--remote-control",
            "exec",
            "hello",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if rejected_local_result.returncode == 0:
        raise AssertionError("remote-control non-interactive command unexpectedly succeeded")
    if "only supported for interactive TUI commands" not in rejected_local_result.stderr:
        raise AssertionError(
            f"expected non-interactive remote-control rejection:\n{rejected_local_result.stderr}"
        )

    rejected_result = subprocess.run(
        [
            str(binary),
            "--remote",
            "ws://127.0.0.1:4500",
            "exec",
            "hello",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if rejected_result.returncode == 0:
        raise AssertionError("remote non-interactive command unexpectedly succeeded")
    if "only supported for interactive TUI commands" not in rejected_result.stderr:
        raise AssertionError(
            f"expected non-interactive remote rejection:\n{rejected_result.stderr}"
        )

    unsupported_remote_override = subprocess.run(
        [
            str(binary),
            "--remote",
            "unix:///tmp/codex-zig-missing.sock",
            "--search",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if unsupported_remote_override.returncode == 0:
        raise AssertionError("unsupported remote override unexpectedly succeeded")
    if "remote app-server TUI does not support `--search` yet" not in unsupported_remote_override.stderr:
        raise AssertionError(
            "expected unsupported remote override rejection before connecting:\n"
            f"{unsupported_remote_override.stderr}"
        )


class WssRemoteTuiServer:
    def __init__(self, cert_path: Path, key_path: Path) -> None:
        self.cert_path = cert_path
        self.key_path = key_path
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.ready = threading.Event()
        self.error: BaseException | None = None
        self.requests: list[dict] = []
        self.headers: dict[str, str] = {}
        self.sock: ssl.SSLSocket | None = None

    @property
    def url(self) -> str:
        return f"wss://localhost:{self.port}"

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(timeout=5):
            raise AssertionError("timed out waiting for fake wss remote app-server")

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.listener.close()

    def join(self) -> None:
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError("fake wss remote app-server did not exit")
        if self.error is not None:
            raise AssertionError("fake wss remote app-server failed") from self.error

    def _serve(self) -> None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(self.cert_path), str(self.key_path))
        try:
            self.ready.set()
            raw_sock, _ = self.listener.accept()
            with context.wrap_socket(raw_sock, server_side=True) as conn:
                self.sock = conn
                conn.settimeout(5)
                request = self._recv_until(conn, b"\r\n\r\n")
                self.headers = self._parse_headers(request)
                if self.headers.get("authorization") != "Bearer super-secret-token":
                    raise AssertionError(f"unexpected wss auth header: {self.headers!r}")
                key = self.headers.get("sec-websocket-key")
                if key is None:
                    raise AssertionError(f"wss websocket request missing key: {request!r}")
                accept = base64.b64encode(
                    hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
                ).decode("ascii")
                conn.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n"
                        "\r\n"
                    ).encode("ascii")
                )
                while True:
                    payload = self._read_frame(conn)
                    if payload is None:
                        return
                    request_json = json.loads(payload.decode("utf-8"))
                    self.requests.append(request_json)
                    self._handle_request(conn, request_json)
        except (AssertionError, OSError, ssl.SSLError) as exc:
            if self.requests:
                return
            self.error = exc
        except BaseException as exc:
            self.error = exc

    def _handle_request(self, conn: ssl.SSLSocket, request: dict) -> None:
        request_id = request.get("id")
        method = request.get("method")
        if method == "initialize":
            self._write_json(conn, {"jsonrpc": "2.0", "id": request_id, "result": {}})
            return
        if method == "thread/start":
            self._write_json(
                conn,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"thread": {"id": "thread-wss-smoke"}},
                },
            )
            return
        if method == "turn/start":
            self._write_json(
                conn,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"turn": {"id": "turn-wss-smoke"}},
                },
            )
            self._write_json(
                conn,
                {
                    "jsonrpc": "2.0",
                    "method": "item/agentMessage/delta",
                    "params": {
                        "threadId": "thread-wss-smoke",
                        "turnId": "turn-wss-smoke",
                        "delta": "wss answer\n",
                    },
                },
            )
            self._write_json(
                conn,
                {
                    "jsonrpc": "2.0",
                    "method": "turn/completed",
                    "params": {
                        "threadId": "thread-wss-smoke",
                        "turn": {"id": "turn-wss-smoke"},
                    },
                },
            )
            return
        self._write_json(
            conn,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unsupported method {method}"},
            },
        )

    @staticmethod
    def _parse_headers(request: bytes) -> dict[str, str]:
        headers: dict[str, str] = {}
        for line in request.split(b"\r\n")[1:]:
            if not line:
                break
            name, value = line.decode("ascii").split(":", 1)
            headers[name.lower()] = value.strip()
        return headers

    @staticmethod
    def _recv_until(conn: ssl.SSLSocket, delimiter: bytes) -> bytes:
        data = b""
        while delimiter not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    @staticmethod
    def _recv_exact(conn: ssl.SSLSocket, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = conn.recv(size - len(data))
            if not chunk:
                raise AssertionError("wss remote websocket closed unexpectedly")
            data += chunk
        return data

    def _write_json(self, conn: ssl.SSLSocket, payload: dict) -> None:
        self._send_frame(conn, 0x1, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    @staticmethod
    def _send_frame(conn: ssl.SSLSocket, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        if len(payload) <= 125:
            header.append(len(payload))
        elif len(payload) <= 0xFFFF:
            header.append(126)
            header.extend(len(payload).to_bytes(2, "big"))
        else:
            header.append(127)
            header.extend(len(payload).to_bytes(8, "big"))
        conn.sendall(bytes(header) + payload)

    def _read_frame(self, conn: ssl.SSLSocket) -> bytes | None:
        first, second = self._recv_exact(conn, 2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = int.from_bytes(self._recv_exact(conn, 2), "big")
        elif length == 127:
            length = int.from_bytes(self._recv_exact(conn, 8), "big")
        masked = (second & 0x80) != 0
        mask = self._recv_exact(conn, 4) if masked else b""
        payload = self._recv_exact(conn, length)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            self._send_frame(conn, 0xA, payload)
            return self._read_frame(conn)
        if opcode != 0x1:
            raise AssertionError(f"unexpected wss remote websocket opcode {opcode}")
        return payload


def run_remote_websocket_tui_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    remote_home = Path(tempfile.mkdtemp(prefix="codex-zig-remote-ws-home-", dir="/tmp"))
    token_file = remote_home / "app-server-token"
    token_file.write_text("super-secret-token\n", encoding="utf-8")
    app_env = os.environ.copy()
    app_env["CODEX_HOME"] = str(remote_home)
    app_env["OPENAI_API_KEY"] = "remote-websocket-api-key"
    app_env.pop("CODEX_ACCESS_TOKEN", None)
    remote_home.joinpath("config.toml").write_text(
        f'openai_base_url = "http://127.0.0.1:{port}"\nmodel = "gpt-remote-websocket"\n',
        encoding="utf-8",
    )
    app_server = subprocess.Popen(
        [
            str(binary),
            "app-server",
            "--listen",
            "ws://127.0.0.1:0",
            "--ws-auth",
            "capability-token",
            "--ws-token-file",
            str(token_file),
        ],
        cwd=remote_home,
        env=app_env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    client = None
    master_fd = -1
    body_start = len(server.request_bodies)
    try:
        host, ws_port = wait_for_websocket_bind(app_server, 5)
        client_env = env.copy()
        client_env["CODEX_REMOTE_AUTH_TOKEN"] = "  super-secret-token  "
        output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "--remote",
                f"ws://{host}:{ws_port}",
                "--remote-auth-token-env",
                "CODEX_REMOTE_AUTH_TOKEN",
                "--no-alt-screen",
                "side question from remote websocket",
            ],
            cwd=workspace,
            env=client_env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, output, b"Codex Zig Remote", 5)
        wait_for(master_fd, output, b"side answer", 8)
        if b"parsed but not implemented yet" in output:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote websocket TUI still hit placeholder:\n\n{rendered}")
        mark = len(output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote websocket TUI smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        websocket_bodies = server.request_bodies[body_start:]
        if not any(
            "side question from remote websocket" in latest_user_text(body.get("input", []))
            for body in websocket_bodies
        ):
            rendered = json.dumps(websocket_bodies, indent=2, sort_keys=True)
            raise AssertionError(f"remote websocket TUI did not send prompt through app-server:\n\n{rendered}")
    finally:
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)
        if app_server.poll() is None:
            app_server.terminate()
            try:
                app_server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app_server.kill()
                app_server.wait(timeout=5)
        shutil.rmtree(remote_home, ignore_errors=True)


def run_remote_wss_tui_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-remote-wss-tui-", dir="/tmp"))
    cert_path, key_path = generate_localhost_self_signed_cert(temp_root)
    wss_server = WssRemoteTuiServer(cert_path, key_path)
    client = None
    master_fd = -1
    try:
        wss_server.start()
        client_env = env.copy()
        client_env["CODEX_REMOTE_AUTH_TOKEN"] = "  super-secret-token  "
        output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "--remote",
                wss_server.url,
                "--remote-auth-token-env",
                "CODEX_REMOTE_AUTH_TOKEN",
                "--no-alt-screen",
                "side question from remote wss",
            ],
            cwd=workspace,
            env=client_env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, output, b"Codex Zig Remote", 5)
        wait_for(master_fd, output, b"wss answer", 8)
        mark = len(output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote wss TUI smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        if not any(request.get("method") == "turn/start" for request in wss_server.requests):
            raise AssertionError(f"remote wss TUI did not send turn/start: {wss_server.requests!r}")
    finally:
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)
        wss_server.close()
        wss_server.join()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_local_remote_control_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    image_path = workspace / "remote-control-tiny.png"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\nremote-control-image-smoke\n")
    output = bytearray()
    proc = None
    master_fd = -1
    stalled_sock = None
    event_sock: socket.socket | None = None
    event_buffer = b""
    body_start = len(server.request_bodies)
    try:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [
                str(binary),
                "--remote-control",
                "--remote-control-bind",
                "127.0.0.1:0",
                "--no-alt-screen",
                "-c",
                f"chatgpt_base_url=http://127.0.0.1:{port}",
                "--image",
                str(image_path),
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, output, b"Remote control active", 5)
        control_url = remote_control_url(output)
        share_url = remote_control_share_url(output)

        state = remote_control_state(control_url)
        if state.get("status") != "Connected to Codex":
            raise AssertionError(f"unexpected remote-control state: {state!r}")

        viewer_body = json.dumps({"message": "viewer should not send"}, separators=(",", ":")).encode()
        viewer_response = remote_control_request(share_url, "POST", "/api/message", viewer_body)
        if not viewer_response.startswith("HTTP/1.1 403 Forbidden"):
            raise AssertionError(f"expected viewer POST to be read-only:\n{viewer_response}")

        event_sock, event_buffer = remote_control_event_stream(control_url)
        initial_event, event_buffer = read_remote_control_state_event(event_sock, event_buffer, 2)
        if initial_event.get("status") != "Connected to Codex":
            raise AssertionError(f"unexpected initial remote-control event: {initial_event!r}")
        event_sock.close()
        event_sock = None
        time.sleep(1)
        state_after_idle_event_close = remote_control_state(control_url)
        if state_after_idle_event_close.get("status") != "Connected to Codex":
            raise AssertionError(
                f"remote-control state failed after idle event close: {state_after_idle_event_close!r}"
            )

        event_sock, event_buffer = remote_control_event_stream(control_url)
        initial_event, event_buffer = read_remote_control_state_event(event_sock, event_buffer, 2)
        if initial_event.get("status") != "Connected to Codex":
            raise AssertionError(f"unexpected reopened remote-control event: {initial_event!r}")

        post_remote_control_message(control_url, "describe attached image")
        wait_for(master_fd, output, b"remote \xe2\x80\xba describe attached image", 5)
        wait_for(master_fd, output, b"image received", 8)

        state_after, event_buffer = wait_for_remote_control_event_messages(
            event_sock,
            event_buffer,
            "describe attached image",
            "image received",
            5,
        )
        polled_state_after = wait_for_remote_control_messages(
            control_url,
            "describe attached image",
            "image received",
            2,
        )
        messages = state_after.get("messages")
        if not isinstance(messages, list):
            raise AssertionError(f"remote-control state did not include messages: {state_after!r}")
        if polled_state_after.get("messages") != messages:
            raise AssertionError("remote-control event state diverged from /api/state")

        concurrent_prompts = ["side question one", "side question two"]
        concurrent_mark = len(output)
        post_remote_control_messages_concurrently(control_url, concurrent_prompts)
        for prompt in concurrent_prompts:
            wait_for(master_fd, output, f"remote \u203a {prompt}".encode(), 8, concurrent_mark)
            wait_for_remote_control_messages(control_url, prompt, "side answer", 8)

        parsed = urlparse(control_url)
        if not parsed.port:
            raise AssertionError(f"invalid remote-control URL: {control_url}")
        stalled_sock = socket.create_connection(("127.0.0.1", parsed.port), timeout=2)
        time.sleep(0.2)

        send_line(master_fd, "/quit")
        wait_for(master_fd, output, b"bye", 5)
        exit_code = proc.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"local remote-control TUI exited with {exit_code}\n\n{rendered}")
        wait_for_remote_control_stop(control_url, 3)
        os.close(master_fd)
        master_fd = -1

        local_bodies = server.request_bodies[body_start:]
        matching = [
            body
            for body in local_bodies
            if "describe attached image" in latest_user_text(body.get("input", []))
        ]
        if not matching:
            rendered = json.dumps(local_bodies, indent=2, sort_keys=True)
            raise AssertionError(f"local remote-control prompt did not reach Responses mock:\n\n{rendered}")
        local_prompts = [latest_user_text(body.get("input", [])) for body in local_bodies]
        for prompt in concurrent_prompts:
            if prompt not in local_prompts:
                rendered = json.dumps(local_prompts, indent=2)
                raise AssertionError(f"concurrent remote-control prompt was not preserved:\n\n{rendered}")
        images = latest_user_images(matching[-1].get("input", []))
        if len(images) != 1 or not images[0].startswith("data:image/png;base64,"):
            raise AssertionError(f"expected remote-control prompt to consume one PNG image, saw {images!r}")
    finally:
        if event_sock is not None:
            event_sock.close()
        if stalled_sock is not None:
            stalled_sock.close()
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)


def run_local_remote_control_slash_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    output = bytearray()
    proc = None
    master_fd = -1
    body_start = len(server.request_bodies)
    typed_prompt = "side question before slash remote control"
    remote_prompt = "side question from slash controller"
    try:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [
                str(binary),
                "--no-alt-screen",
                "-c",
                f"chatgpt_base_url=http://127.0.0.1:{port}",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        wait_for(master_fd, output, b"\xe2\x80\xba", 5)

        mark = len(output)
        send_line(master_fd, typed_prompt)
        wait_for(master_fd, output, b"side answer", 8, mark)

        start_mark = len(output)
        send_line(master_fd, "/remote-control")
        wait_for(master_fd, output, b"Remote control active", 5, start_mark)
        control_url = remote_control_url(output, start_mark)
        share_url = remote_control_share_url(output, start_mark)
        wait_for_remote_control_messages(control_url, typed_prompt, "side answer", 2)

        viewer_body = json.dumps({"message": "viewer should not send"}, separators=(",", ":")).encode()
        viewer_response = remote_control_request(share_url, "POST", "/api/message", viewer_body)
        if not viewer_response.startswith("HTTP/1.1 403 Forbidden"):
            raise AssertionError(f"expected slash-started viewer POST to be read-only:\n{viewer_response}")

        reshow_mark = len(output)
        send_line(master_fd, "/remote-control start")
        wait_for(master_fd, output, b"Remote control active", 5, reshow_mark)
        reshown_control_url = remote_control_url(output, reshow_mark)
        if reshown_control_url != control_url:
            raise AssertionError(
                f"/remote-control start created a second server:\n{control_url}\n{reshown_control_url}"
            )

        usage_mark = len(output)
        send_line(master_fd, "/remote-control nonsense")
        wait_for(master_fd, output, b"Usage: /remote-control [start|stop]", 5, usage_mark)
        remote_control_state(control_url)

        remote_mark = len(output)
        post_remote_control_message(control_url, remote_prompt)
        wait_for(master_fd, output, f"remote \u203a {remote_prompt}".encode(), 5, remote_mark)
        wait_for(master_fd, output, b"side answer", 8, remote_mark)
        wait_for_remote_control_messages(control_url, remote_prompt, "side answer", 5)

        stop_mark = len(output)
        send_line(master_fd, "/remote-control stop")
        wait_for(master_fd, output, b"Remote control stopped.", 5, stop_mark)
        wait_for_remote_control_stop(control_url, 3)

        quit_mark = len(output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, output, b"bye", 5, quit_mark)
        exit_code = proc.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"local remote-control slash TUI exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        local_prompts = [
            latest_user_text(body.get("input", []))
            for body in server.request_bodies[body_start:]
        ]
        for prompt in [typed_prompt, remote_prompt]:
            if prompt not in local_prompts:
                rendered = json.dumps(local_prompts, indent=2)
                raise AssertionError(f"slash remote-control prompt was not preserved:\n\n{rendered}")
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)


def run_remote_unix_tui_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    socket_dir = Path(tempfile.mkdtemp(prefix="codex-zig-remote-tui-sock-", dir="/tmp"))
    remote_home = Path(tempfile.mkdtemp(prefix="codex-zig-remote-tui-home-", dir="/tmp"))
    socket_path = socket_dir / "app-server.sock"
    image_path = workspace / "remote-large.png"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\n" + (b"remote-image-smoke" * 5000))
    start_requests = server.request_count

    app_env = os.environ.copy()
    app_env["CODEX_HOME"] = str(remote_home)
    app_env["OPENAI_API_KEY"] = "remote-tui-api-key"
    app_env.pop("CODEX_ACCESS_TOKEN", None)
    remote_home.joinpath("config.toml").write_text(
        f'openai_base_url = "http://127.0.0.1:{port}"\n'
        'model = "gpt-remote-tui"\n'
        'service_tier = "priority"\n',
        encoding="utf-8",
    )

    app_server = subprocess.Popen(
        [str(binary), "app-server", "--listen", f"unix://{socket_path}"],
        cwd=remote_home,
        env=app_env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = bytearray()
    client = None
    master_fd = -1
    try:
        wait_for_path(socket_path, app_server, 5)
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
                "--model",
                "gpt-remote-cli",
                "-c",
                "personality=friendly",
                "-c",
                "model_reasoning_summary=concise",
                "--image",
                image_path.name,
                "describe attached image from remote tui",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, output, b"Codex Zig Remote", 5)
        wait_for(master_fd, output, b"image received", 8)
        send_line(master_fd, "side question from remote tui")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "long remote answer")
        wait_for(master_fd, output, b"long remote answer tail", 8)
        send_line(master_fd, "/status")
        wait_for(master_fd, output, b"thread:", 5)
        send_line(master_fd, "/sessions 3")
        wait_for(master_fd, output, b"remote sessions:", 5)
        send_line(master_fd, "/model gpt-remote-slashed")
        wait_for(master_fd, output, b"model: gpt-remote-slashed", 5)
        send_line(master_fd, "side question from remote slash model")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/fast status")
        wait_for(master_fd, output, b"Fast mode is on.", 5)
        send_line(master_fd, "/fast")
        wait_for(master_fd, output, b"Fast mode is off.", 5)
        send_line(master_fd, "side question from remote slash learned fast off")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/fast on")
        wait_for(master_fd, output, b"Fast mode is on.", 5)
        send_line(master_fd, "side question from remote slash fast")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/fast off")
        wait_for(master_fd, output, b"Fast mode is off.", 5)
        send_line(master_fd, "side question from remote slash fast off")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/personality pragmatic")
        wait_for(master_fd, output, b"personality: pragmatic", 5)
        send_line(master_fd, "side question from remote slash personality")
        wait_for(master_fd, output, b"side answer", 8)
        os.write(master_fd, b"/fork\n1\n")
        wait_for(master_fd, output, b"forked remote thread:", 5)
        send_line(master_fd, "side question from remote slash picker fork")
        wait_for(master_fd, output, b"side answer", 8)
        os.write(master_fd, b"/resume\n1\n")
        wait_for(master_fd, output, b"resumed remote thread:", 5)
        send_line(master_fd, "side question from remote slash picker resume")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/fork last")
        wait_for(master_fd, output, b"forked remote thread:", 5)
        send_line(master_fd, "side question from remote slash fork")
        wait_for(master_fd, output, b"side answer", 8)
        send_line(master_fd, "/resume last")
        wait_for(master_fd, output, b"resumed remote thread:", 5)
        send_line(master_fd, "side question from remote slash resume")
        wait_for(master_fd, output, b"side answer", 8)
        if b"parsed but not implemented yet" in output:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote TUI still hit placeholder:\n\n{rendered}")
        mark = len(output)
        send_line(master_fd, "q")
        wait_for(master_fd, output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote TUI smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        resume_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "resume",
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
                "--last",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, resume_output, b"Codex Zig Remote", 5)
        send_line(master_fd, "side question from remote resume")
        wait_for(master_fd, resume_output, b"side answer", 8)
        mark = len(resume_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, resume_output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = resume_output.decode(errors="replace")
            raise AssertionError(f"remote TUI resume smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        fork_last_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "fork",
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
                "--last",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, fork_last_output, b"Codex Zig Remote", 5)
        send_line(master_fd, "side question from remote last-fork")
        wait_for(master_fd, fork_last_output, b"side answer", 8)
        mark = len(fork_last_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, fork_last_output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = fork_last_output.decode(errors="replace")
            raise AssertionError(f"remote TUI fork --last smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        session_files = sorted(remote_home.joinpath("sessions", "zig").glob("*.jsonl"))
        if not session_files:
            raise AssertionError("remote TUI smoke did not create a resumable session file")
        relative_session_path = workspace / "remote-relative-session.jsonl"
        shutil.copyfile(session_files[-1], relative_session_path)

        fork_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "fork",
                f"./{relative_session_path.name}",
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, fork_output, b"Codex Zig Remote", 5)
        send_line(master_fd, "side question from remote fork")
        wait_for(master_fd, fork_output, b"side answer", 8)
        mark = len(fork_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, fork_output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = fork_output.decode(errors="replace")
            raise AssertionError(f"remote TUI fork smoke exited with {exit_code}\n\n{rendered}")

        resume_picker_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "resume",
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, resume_picker_output, b"Codex Zig Remote", 5)
        wait_for(master_fd, resume_picker_output, b"resume sessions:", 5)
        send_line(master_fd, "1")
        wait_for(master_fd, resume_picker_output, b"\xe2\x80\xba", 5)
        send_line(master_fd, "side question from remote resume picker")
        wait_for(master_fd, resume_picker_output, b"side answer", 8)
        mark = len(resume_picker_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, resume_picker_output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = resume_picker_output.decode(errors="replace")
            raise AssertionError(f"remote TUI resume picker smoke exited with {exit_code}\n\n{rendered}")
        os.close(master_fd)
        master_fd = -1

        fork_picker_output = bytearray()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "fork",
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, fork_picker_output, b"Codex Zig Remote", 5)
        wait_for(master_fd, fork_picker_output, b"fork sessions:", 5)
        send_line(master_fd, "1")
        wait_for(master_fd, fork_picker_output, b"\xe2\x80\xba", 5)
        send_line(master_fd, "side question from remote fork picker")
        wait_for(master_fd, fork_picker_output, b"side answer", 8)
        send_line(master_fd, "/new unexpected")
        wait_for(master_fd, fork_picker_output, b"usage: /new", 5)
        send_line(master_fd, "/new")
        wait_for(master_fd, fork_picker_output, b"started remote thread:", 5)
        send_line(master_fd, "side question from remote slash new")
        wait_for(master_fd, fork_picker_output, b"side answer", 8)
        send_line(master_fd, "/clear unexpected")
        wait_for(master_fd, fork_picker_output, b"usage: /clear", 5)
        clear_mark = len(fork_picker_output)
        send_line(master_fd, "/clear")
        wait_for(master_fd, fork_picker_output, b"Codex Zig Remote", 5, clear_mark)
        wait_for(master_fd, fork_picker_output, b"started remote thread:", 5, clear_mark)
        send_line(master_fd, "side question from remote slash clear")
        wait_for(master_fd, fork_picker_output, b"side answer", 8)
        send_line(master_fd, "/model gpt-remote-compact")
        wait_for(master_fd, fork_picker_output, b"model: gpt-remote-compact", 5)
        send_line(master_fd, "/fast on")
        wait_for(master_fd, fork_picker_output, b"Fast mode is on.", 5)
        send_line(master_fd, "/personality friendly")
        wait_for(master_fd, fork_picker_output, b"personality: friendly", 5)
        send_line(master_fd, "/compact unexpected")
        wait_for(master_fd, fork_picker_output, b"usage: /compact", 5)
        send_line(master_fd, "/compact")
        wait_for(master_fd, fork_picker_output, b"compacted remote thread:", 8)
        send_line(master_fd, "side question from remote slash compact")
        wait_for(master_fd, fork_picker_output, b"side answer", 8)
        mark = len(fork_picker_output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, fork_picker_output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = fork_picker_output.decode(errors="replace")
            raise AssertionError(f"remote TUI fork picker smoke exited with {exit_code}\n\n{rendered}")
    finally:
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)
        if app_server.poll() is None:
            app_server.terminate()
            try:
                app_server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app_server.kill()
                app_server.wait(timeout=5)
        shutil.rmtree(socket_dir, ignore_errors=True)
        shutil.rmtree(remote_home, ignore_errors=True)

    bodies = server.request_bodies[start_requests:]
    matching = [
        body
        for body in bodies
        if "side question from remote tui" in latest_user_text(body.get("input", []))
    ]
    if not matching:
        rendered = output.decode(errors="replace")
        raise AssertionError(f"remote TUI did not send prompt through app-server:\n\n{rendered}")
    resume_matching = [
        body
        for body in bodies
        if "side question from remote resume" in latest_user_text(body.get("input", []))
    ]
    if not resume_matching:
        raise AssertionError("remote TUI resume did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(resume_matching[-1]):
        raise AssertionError("remote TUI resume did not include resumed transcript history")
    fork_last_matching = [
        body
        for body in bodies
        if "side question from remote last-fork" in latest_user_text(body.get("input", []))
    ]
    if not fork_last_matching:
        raise AssertionError("remote TUI fork --last did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(fork_last_matching[-1]):
        raise AssertionError("remote TUI fork --last did not include forked transcript history")
    fork_matching = [
        body
        for body in bodies
        if "side question from remote fork" in latest_user_text(body.get("input", []))
    ]
    if not fork_matching:
        raise AssertionError("remote TUI fork did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(fork_matching[-1]):
        raise AssertionError("remote TUI fork did not include forked transcript history")
    resume_picker_matching = [
        body
        for body in bodies
        if "side question from remote resume picker" in latest_user_text(body.get("input", []))
    ]
    if not resume_picker_matching:
        raise AssertionError("remote TUI resume picker did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(resume_picker_matching[-1]):
        raise AssertionError("remote TUI resume picker did not include resumed transcript history")
    fork_picker_matching = [
        body
        for body in bodies
        if "side question from remote fork picker" in latest_user_text(body.get("input", []))
    ]
    if not fork_picker_matching:
        raise AssertionError("remote TUI fork picker did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(fork_picker_matching[-1]):
        raise AssertionError("remote TUI fork picker did not include forked transcript history")
    slash_model_matching = [
        body
        for body in bodies
        if "side question from remote slash model" in latest_user_text(body.get("input", []))
    ]
    if not slash_model_matching:
        raise AssertionError("remote TUI slash model did not send prompt through app-server")
    if slash_model_matching[-1].get("model") != "gpt-remote-slashed":
        raise AssertionError(
            "remote TUI slash model did not update model override: "
            f"{slash_model_matching[-1].get('model')!r}"
        )
    slash_fast_matching = [
        body
        for body in bodies
        if latest_user_text(body.get("input", [])) == "side question from remote slash fast"
    ]
    if not slash_fast_matching:
        raise AssertionError("remote TUI slash fast did not send prompt through app-server")
    if slash_fast_matching[-1].get("service_tier") != "priority":
        raise AssertionError(
            "remote TUI slash fast did not update service tier: "
            f"{slash_fast_matching[-1].get('service_tier')!r}"
        )
    slash_learned_fast_off_matching = [
        body
        for body in bodies
        if latest_user_text(body.get("input", []))
        == "side question from remote slash learned fast off"
    ]
    if not slash_learned_fast_off_matching:
        raise AssertionError("remote TUI slash learned fast off did not send prompt through app-server")
    if slash_learned_fast_off_matching[-1].get("service_tier") is not None:
        raise AssertionError(
            "remote TUI slash learned fast off did not clear service tier: "
            f"{slash_learned_fast_off_matching[-1].get('service_tier')!r}"
        )
    slash_fast_off_matching = [
        body
        for body in bodies
        if latest_user_text(body.get("input", [])) == "side question from remote slash fast off"
    ]
    if not slash_fast_off_matching:
        raise AssertionError("remote TUI slash fast off did not send prompt through app-server")
    if slash_fast_off_matching[-1].get("service_tier") is not None:
        raise AssertionError(
            "remote TUI slash fast off did not clear service tier: "
            f"{slash_fast_off_matching[-1].get('service_tier')!r}"
        )
    slash_personality_matching = [
        body
        for body in bodies
        if "side question from remote slash personality"
        in latest_user_text(body.get("input", []))
    ]
    if not slash_personality_matching:
        raise AssertionError("remote TUI slash personality did not send prompt through app-server")
    personality_instructions = slash_personality_matching[-1].get("instructions", "")
    if "deeply pragmatic" not in personality_instructions:
        raise AssertionError("remote TUI slash personality did not update instructions")
    slash_fork_matching = [
        body
        for body in bodies
        if "side question from remote slash fork" in latest_user_text(body.get("input", []))
    ]
    if not slash_fork_matching:
        raise AssertionError("remote TUI slash fork did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(slash_fork_matching[-1]):
        raise AssertionError("remote TUI slash fork did not include forked transcript history")
    slash_picker_fork_matching = [
        body
        for body in bodies
        if "side question from remote slash picker fork" in latest_user_text(body.get("input", []))
    ]
    if not slash_picker_fork_matching:
        raise AssertionError("remote TUI slash picker fork did not send prompt through app-server")
    if "describe attached image from remote tui" not in json.dumps(slash_picker_fork_matching[-1]):
        raise AssertionError("remote TUI slash picker fork did not include forked transcript history")
    slash_resume_matching = [
        body
        for body in bodies
        if "side question from remote slash resume" in latest_user_text(body.get("input", []))
    ]
    if not slash_resume_matching:
        raise AssertionError("remote TUI slash resume did not send prompt through app-server")
    slash_picker_resume_matching = [
        body
        for body in bodies
        if "side question from remote slash picker resume" in latest_user_text(body.get("input", []))
    ]
    if not slash_picker_resume_matching:
        raise AssertionError("remote TUI slash picker resume did not send prompt through app-server")
    slash_new_matching = [
        body
        for body in bodies
        if "side question from remote slash new" in latest_user_text(body.get("input", []))
    ]
    if not slash_new_matching:
        raise AssertionError("remote TUI slash new did not send prompt through app-server")
    slash_new_body = json.dumps(slash_new_matching[-1])
    if "describe attached image from remote tui" in slash_new_body:
        raise AssertionError("remote TUI slash new carried transcript history from the previous thread")
    if "side question from remote fork picker" in slash_new_body:
        raise AssertionError("remote TUI slash new carried immediate pre-new transcript history")
    slash_clear_matching = [
        body
        for body in bodies
        if "side question from remote slash clear" in latest_user_text(body.get("input", []))
    ]
    if not slash_clear_matching:
        raise AssertionError("remote TUI slash clear did not send prompt through app-server")
    slash_clear_body = json.dumps(slash_clear_matching[-1])
    if "describe attached image from remote tui" in slash_clear_body:
        raise AssertionError("remote TUI slash clear carried transcript history from the previous thread")
    if "side question from remote slash new" in slash_clear_body:
        raise AssertionError("remote TUI slash clear carried immediate pre-clear transcript history")
    compact_runtime_matching = [
        body
        for body in bodies
        if latest_user_text(body.get("input", [])).startswith("Summarize this conversation")
    ]
    if not compact_runtime_matching:
        raise AssertionError("remote TUI did not send compact prompt through app-server")
    compact_runtime_body = compact_runtime_matching[-1]
    if compact_runtime_body.get("model") != "gpt-remote-compact":
        raise AssertionError("remote TUI slash compact did not use slash-updated model")
    if compact_runtime_body.get("service_tier") != "priority":
        raise AssertionError("remote TUI slash compact did not use slash-updated fast mode")
    compact_instructions = compact_runtime_body.get("instructions", "")
    if "supportive teammate" not in compact_instructions:
        raise AssertionError("remote TUI slash compact did not use slash-updated personality")
    slash_compact_matching = [
        body
        for body in bodies
        if "side question from remote slash compact" in latest_user_text(body.get("input", []))
    ]
    if not slash_compact_matching:
        raise AssertionError("remote TUI slash compact did not send prompt through app-server")
    slash_compact_body = json.dumps(slash_compact_matching[-1])
    if "Compacted conversation summary" not in slash_compact_body:
        raise AssertionError("remote TUI slash compact did not preserve the compacted summary")
    if "compact summary" not in slash_compact_body:
        raise AssertionError("remote TUI slash compact did not include the provider summary text")
    if "side question from remote slash clear" in slash_compact_body:
        raise AssertionError("remote TUI slash compact carried pre-compaction transcript history")
    image_matching = [
        body
        for body in bodies
        if "describe attached image from remote tui"
        in latest_user_text(body.get("input", []))
    ]
    if not image_matching:
        rendered = output.decode(errors="replace")
        raise AssertionError(f"remote TUI did not send image prompt through app-server:\n\n{rendered}")
    images = latest_user_images(image_matching[-1].get("input", []))
    if len(images) != 1 or not images[0].startswith("data:image/png;base64,"):
        raise AssertionError(f"expected one remote PNG input_image, saw {images!r}")
    if image_matching[-1].get("model") != "gpt-remote-cli":
        raise AssertionError(
            f"expected remote model override, saw {image_matching[-1].get('model')!r}"
        )
    reasoning = image_matching[-1].get("reasoning", {})
    if reasoning.get("summary") != "concise":
        raise AssertionError(f"expected remote summary override, saw {reasoning!r}")
    instructions = image_matching[-1].get("instructions", "")
    if "<personality_spec>" not in instructions:
        raise AssertionError("expected remote personality override in instructions")


class InitialPromptErrorRemoteServer:
    def __init__(self, socket_path: Path) -> None:
        self.socket_path = socket_path
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.ready = threading.Event()
        self.error: BaseException | None = None
        self.requests: list[dict] = []

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(timeout=5):
            raise AssertionError("timed out waiting for fake remote app-server")

    def join(self) -> None:
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError("fake remote app-server did not exit")
        if self.error is not None:
            raise AssertionError("fake remote app-server failed") from self.error

    def _serve(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(self.socket_path))
            sock.listen(1)
            self.ready.set()
            conn, _ = sock.accept()
            with conn:
                reader = conn.makefile("r", encoding="utf-8")
                writer = conn.makefile("w", encoding="utf-8")
                turn_starts = 0
                for line in reader:
                    request = json.loads(line)
                    self.requests.append(request)
                    method = request.get("method")
                    if method == "initialize":
                        self._write(writer, {"jsonrpc": "2.0", "id": request["id"], "result": {}})
                    elif method == "thread/start":
                        self._write(
                            writer,
                            {
                                "jsonrpc": "2.0",
                                "id": request["id"],
                                "result": {"thread": {"id": "thread-1"}},
                            },
                        )
                    elif method == "turn/start":
                        turn_starts += 1
                        if turn_starts == 1:
                            self._write(
                                writer,
                                {
                                    "jsonrpc": "2.0",
                                    "id": request["id"],
                                    "error": {
                                        "code": -32000,
                                        "message": "forced initial failure",
                                    },
                                },
                            )
                            continue
                        turn_id = f"turn-{turn_starts}"
                        self._write(
                            writer,
                            {
                                "jsonrpc": "2.0",
                                "id": request["id"],
                                "result": {"turn": {"id": turn_id}},
                            },
                        )
                        self._write(
                            writer,
                            {
                                "jsonrpc": "2.0",
                                "method": "item/agentMessage/delta",
                                "params": {
                                    "threadId": "thread-1",
                                    "turnId": turn_id,
                                    "delta": "retry answer\n",
                                },
                            },
                        )
                        self._write(
                            writer,
                            {
                                "jsonrpc": "2.0",
                                "method": "turn/completed",
                                "params": {"threadId": "thread-1", "turnId": turn_id},
                            },
                        )
        except BaseException as exc:
            self.error = exc
        finally:
            sock.close()

    @staticmethod
    def _write(writer, payload: dict) -> None:
        writer.write(json.dumps(payload, separators=(",", ":")) + "\n")
        writer.flush()


def run_remote_initial_prompt_error_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    socket_dir = Path(
        tempfile.mkdtemp(prefix="codex-zig-remote-error-sock-", dir="/tmp")
    )
    socket_path = socket_dir / "app-server.sock"
    server = InitialPromptErrorRemoteServer(socket_path)
    output = bytearray()
    client = None
    master_fd = -1
    try:
        server.start()
        master_fd, slave_fd = pty.openpty()
        client = subprocess.Popen(
            [
                str(binary),
                "--remote",
                f"unix://{socket_path}",
                "--no-alt-screen",
                "first prompt fails",
            ],
            cwd=workspace,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)
        wait_for(master_fd, output, b"remote app-server error: forced initial failure", 5)
        wait_for(master_fd, output, b"error: RemoteAppServerRequestFailed", 5)
        send_line(master_fd, "retry after initial failure")
        wait_for(master_fd, output, b"retry answer", 5)
        mark = len(output)
        send_line(master_fd, "/quit")
        wait_for(master_fd, output, b"bye", 5, mark)
        exit_code = client.wait(timeout=5)
        if exit_code != 0:
            rendered = output.decode(errors="replace")
            raise AssertionError(f"remote TUI error smoke exited with {exit_code}\n\n{rendered}")
        turn_prompts = [
            request["params"]["input"][0]["text"]
            for request in server.requests
            if request.get("method") == "turn/start"
        ]
        if turn_prompts != ["first prompt fails", "retry after initial failure"]:
            raise AssertionError(f"unexpected remote retry prompts: {turn_prompts!r}")
    finally:
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=5)
        if master_fd >= 0:
            os.close(master_fd)
        server.join()
        shutil.rmtree(socket_dir, ignore_errors=True)


def run_session_command_option_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    image_path = workspace / "resume-option.png"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\ncodex-zig-resume-option-smoke\n")
    extra_root = workspace / "extra-writable"
    extra_root.mkdir()

    resume_result = subprocess.run(
        [
            str(binary),
            "resume",
            "sid",
            "--oss",
            "--local-provider=ollama",
            "--search",
            "--sandbox",
            "workspace-write",
            "--ask-for-approval",
            "on-request",
            "-m",
            "gpt-resume",
            "-p",
            "work",
            "-C",
            str(workspace),
            "--add-dir",
            str(extra_root),
            "-i",
            str(image_path),
            "--remote=ws://127.0.0.1:4500",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if resume_result.returncode == 0:
        raise AssertionError("resume option-placement smoke unexpectedly succeeded")
    if "remote app-server TUI does not support `--profile` yet" not in resume_result.stderr:
        raise AssertionError(
            f"expected resume remote unsupported-option message:\n{resume_result.stderr}"
        )

    fork_result = subprocess.run(
        [
            str(binary),
            "fork",
            "--all",
            "--yolo",
            "--no-alt-screen",
            "--search",
            "--remote=ws://127.0.0.1:4500",
        ],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if fork_result.returncode == 0:
        raise AssertionError("fork option-placement smoke unexpectedly succeeded")
    if "remote app-server TUI does not support `--search` yet" not in fork_result.stderr:
        raise AssertionError(
            f"expected fork remote unsupported-option message:\n{fork_result.stderr}"
        )


def git(repo: Path, *args: str) -> None:
    git_env = os.environ.copy()
    git_env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    git_env["GIT_CONFIG_NOSYSTEM"] = "1"
    subprocess.run(
        ["git", *args],
        cwd=repo,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )


def git_output(repo: Path, *args: str) -> str:
    git_env = os.environ.copy()
    git_env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    git_env["GIT_CONFIG_NOSYSTEM"] = "1"
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        env=git_env,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def run_apply_command_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
    port: int,
    server: MockResponsesServer,
) -> None:
    repo = workspace / "apply-repo"
    repo.mkdir()
    git(repo, "init")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test User")
    (repo / "README.md").write_text("# Apply Smoke\n")
    git(repo, "add", "README.md")
    git(repo, "commit", "-m", "Initial commit")

    result = subprocess.run(
        [
            str(binary),
            "-c",
            f"chatgpt_base_url=http://127.0.0.1:{port}",
            "apply",
            "task-apply",
        ],
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    combined = result.stdout + result.stderr
    if "Successfully applied diff" not in combined:
        raise AssertionError(f"expected apply success output:\n{combined}")

    created = repo / "scripts" / "fibonacci.js"
    if not created.exists():
        raise AssertionError(f"expected apply command to create {created}")
    contents = created.read_text()
    if "function fibonacci(n)" not in contents or not contents.startswith(
        "#!/usr/bin/env node"
    ):
        raise AssertionError(f"unexpected applied file contents:\n{contents}")

    if "/wham/tasks/task-apply" not in server.get_paths:
        raise AssertionError(f"expected task fetch, saw {server.get_paths!r}")
    headers = server.get_headers[-1] if server.get_headers else {}
    if headers.get("ChatGPT-Account-ID") != "acct_tui_e2e":
        raise AssertionError(f"expected ChatGPT account header, saw {headers!r}")
    if headers.get("Authorization") != "Bearer tui-e2e-token":
        raise AssertionError(f"expected bearer auth header, saw {headers!r}")


def run_e2e(binary: Path) -> str:
    if not binary.exists():
        raise FileNotFoundError(f"binary not found: {binary}; run `zig build` first")

    port = free_port()
    server = start_mock_server(port)
    output = bytearray()
    proc = None
    master_fd = -1

    try:
        with tempfile.TemporaryDirectory(prefix="codex-zig-tui-e2e.") as home:
            auth_path = Path(home) / "auth.json"
            auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "access_token": "tui-e2e-token",
                            "account_id": "acct_tui_e2e",
                        }
                    }
                )
            )
            config_path = Path(home) / "config.toml"
            config_path.write_text(
                "\n".join(
                    [
                        "[mcp_servers.docs]",
                        'command = "docs-server"',
                        'args = ["--stdio"]',
                        "enabled = false",
                        "",
                        "[mcp_servers.remote]",
                        'url = "https://example.com/mcp"',
                        'bearer_token_env_var = "TOKEN_ENV"',
                        "",
                    ]
                )
            )
            themes_dir = Path(home) / "themes"
            themes_dir.mkdir()
            (themes_dir / "custom-demo.tmTheme").write_text("placeholder")
            workspace = Path(home) / "workspace"
            workspace.mkdir()
            demo_file = workspace / "codex_zig_tui_file.txt"
            mention_file = workspace / "mention_context.txt"
            mention_file.write_text("codex zig mention context\n")
            copy_capture = Path(home) / "copied.txt"
            copy_command = Path(home) / "copy_capture.py"
            copy_command.write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env python3",
                        "import pathlib",
                        "import sys",
                        f"pathlib.Path({str(copy_capture)!r}).write_text(sys.stdin.read())",
                        "",
                    ]
                )
            )
            copy_command.chmod(0o755)

            env = os.environ.copy()
            env["CODEX_HOME"] = home
            env["CODEX_ZIG_COPY_COMMAND"] = str(copy_command)
            env.setdefault("TERM", "xterm-256color")
            env.pop("ZELLIJ", None)
            env.pop("ZELLIJ_SESSION_NAME", None)

            run_feature_toggle_smoke(binary, env, workspace)
            run_help_command_smoke(binary, env, workspace)
            run_remote_flag_smoke(binary, env, workspace)
            run_local_remote_control_smoke(binary, env, workspace, port, server)
            run_local_remote_control_slash_smoke(binary, env, workspace, port, server)
            run_remote_websocket_tui_smoke(binary, env, workspace, port, server)
            run_remote_wss_tui_smoke(binary, env, workspace)
            run_remote_unix_tui_smoke(binary, env, workspace, port, server)
            run_remote_initial_prompt_error_smoke(binary, env, workspace)
            run_session_command_option_smoke(binary, env, workspace)
            run_unimplemented_command_smoke(binary, env, workspace)
            run_plugin_marketplace_smoke(binary, env, workspace)
            run_debug_clear_memories_smoke(binary, env, workspace)
            run_debug_stub_smoke(binary, env, workspace, port)
            run_initial_image_smoke(binary, env, workspace, port, server)
            run_apply_command_smoke(binary, env, workspace, port, server)
            run_remote_fork_smoke(binary, env, workspace, port, server)

            master_fd, slave_fd = pty.openpty()
            proc = subprocess.Popen(
                [
                    str(binary),
                    "--no-alt-screen",
                    "-c",
                    f"chatgpt_base_url=http://127.0.0.1:{port}",
                ],
                cwd=workspace,
                env=env,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
            )
            os.close(slave_fd)

            wait_for(master_fd, output, b"Type /help for commands", 8)

            mark = len(output)
            send_line(master_fd, "/help")
            wait_for(master_fd, output, b"commands:", 5, mark)
            wait_for(master_fd, output, b"/permissions", 5, mark)
            wait_for(master_fd, output, b"/title", 5, mark)
            wait_for(master_fd, output, b"/statusline", 5, mark)
            wait_for(master_fd, output, b"/theme", 5, mark)
            wait_for(master_fd, output, b"/personality", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"status:", 5, mark)
            wait_for(master_fd, output, b"service tier: unset", 5, mark)
            wait_for(master_fd, output, b"plan mode:   off", 5, mark)
            wait_for(master_fd, output, b"term title:  on", 5, mark)
            wait_for(master_fd, output, b"status line: <off>", 5, mark)
            wait_for(master_fd, output, b"theme:       catppuccin-mocha", 5, mark)
            wait_for(master_fd, output, b"personality: pragmatic", 5, mark)
            wait_for(master_fd, output, b"raw output:  off", 5, mark)
            wait_for(master_fd, output, b"vim:         off", 5, mark)
            wait_for(master_fd, output, b"tools:", 5, mark)

            mark = len(output)
            send_line(master_fd, "/rename Zig demo")
            wait_for(master_fd, output, b"renamed thread: Zig demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/title app-name thread-title")
            wait_for(master_fd, output, b"\x1b]0;codex | Zig demo\x07", 5, mark)
            wait_for(master_fd, output, b"terminal title: on", 5, mark)
            wait_for(master_fd, output, b"items: app-name, thread-title", 5, mark)
            wait_for(master_fd, output, b"preview: codex | Zig demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"title:       Zig demo", 5, mark)
            wait_for(master_fd, output, b"term title:  on", 5, mark)

            mark = len(output)
            send_line(master_fd, "/sessions 1")
            wait_for(master_fd, output, b"sessions: showing 1", 5, mark)
            wait_for(master_fd, output, b"Zig demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/resume last")
            wait_for(master_fd, output, b"\x1b]0;codex | Zig demo\x07", 5, mark)
            wait_for(master_fd, output, b"resumed:", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"title:       Zig demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/title off")
            wait_for(master_fd, output, b"\x1b]0;\x07", 5, mark)
            wait_for(master_fd, output, b"terminal title: off", 5, mark)

            mark = len(output)
            send_line(master_fd, "/statusline model project-name thread-title")
            wait_for(master_fd, output, b"status line: model, project-name, thread-title", 5, mark)
            wait_for(master_fd, output, b"preview:", 5, mark)
            wait_for(master_fd, output, b"Zig demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"status line: model, project-name, thread-title", 5, mark)

            mark = len(output)
            send_line(master_fd, "/theme")
            wait_for(master_fd, output, b"theme: catppuccin-mocha", 5, mark)

            mark = len(output)
            send_line(master_fd, "/theme list")
            wait_for(master_fd, output, b"themes:", 5, mark)
            wait_for(master_fd, output, b"* catppuccin-mocha", 5, mark)
            wait_for(master_fd, output, b"custom-demo (custom)", 5, mark)

            mark = len(output)
            send_line(master_fd, "/theme dracula")
            wait_for(master_fd, output, b"theme: dracula", 5, mark)

            mark = len(output)
            send_line(master_fd, "/theme custom-demo")
            wait_for(master_fd, output, b"theme: custom-demo", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"theme:       custom-demo", 5, mark)
            wait_for(master_fd, output, b"alt screen:   auto", 5, mark)

            mark = len(output)
            send_line(master_fd, "/personality list")
            wait_for(master_fd, output, b"personalities:", 5, mark)
            wait_for(master_fd, output, b"friendly - Warm, collaborative, and helpful.", 5, mark)
            wait_for(master_fd, output, b"pragmatic - Concise, task-focused, and direct.", 5, mark)

            mark = len(output)
            send_line(master_fd, "/personality friendly")
            wait_for(master_fd, output, b"personality: friendly", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"personality: friendly", 5, mark)

            mark = len(output)
            send_line(master_fd, "/debug-config")
            wait_for(master_fd, output, b"/debug-config", 5, mark)
            wait_for(master_fd, output, b"effective config:", 5, mark)
            wait_for(master_fd, output, b"alt_screen:     auto", 5, mark)
            wait_for(master_fd, output, b"syntax_theme:   custom-demo", 5, mark)
            wait_for(master_fd, output, b"personality:    friendly", 5, mark)
            wait_for(master_fd, output, b"config layers:", 5, mark)
            wait_for(master_fd, output, b"defaults:      built-in", 5, mark)
            wait_for(master_fd, output, b"user config:", 5, mark)
            wait_for(master_fd, output, b"config.toml (present)", 5, mark)
            wait_for(master_fd, output, b"profile:       <none> (not selected)", 5, mark)

            config_text = config_path.read_text()
            if "[tui]" not in config_text or 'theme = "custom-demo"' not in config_text:
                raise AssertionError(f"expected persisted tui theme in config.toml:\n{config_text}")
            if 'personality = "friendly"' not in config_text:
                raise AssertionError(f"expected persisted personality in config.toml:\n{config_text}")
            if 'terminal_title = []' not in config_text:
                raise AssertionError(f"expected disabled terminal title in config.toml:\n{config_text}")
            if 'status_line = ["model", "project-name", "thread-title"]' not in config_text:
                raise AssertionError(f"expected persisted status line in config.toml:\n{config_text}")
            if "[mcp_servers.docs]" not in config_text or "[mcp_servers.remote]" not in config_text:
                raise AssertionError(f"expected existing MCP config to be preserved:\n{config_text}")

            mark = len(output)
            send_line(master_fd, "/keymap")
            wait_for(master_fd, output, b"keymap:", 5, mark)
            wait_for(master_fd, output, b"!COMMAND", 5, mark)

            mark = len(output)
            send_line(master_fd, "/keymap debug")
            wait_for(master_fd, output, b"keymap debug:", 5, mark)
            wait_for(master_fd, output, b"configurable: false", 5, mark)
            wait_for(master_fd, output, b"alternate screen: supported", 5, mark)

            mark = len(output)
            send_line(master_fd, "/fast status")
            wait_for(master_fd, output, b"Fast mode is off.", 5, mark)

            mark = len(output)
            send_line(master_fd, "/fast on")
            wait_for(master_fd, output, b"Fast mode is on.", 5, mark)

            mark = len(output)
            send_line(master_fd, "/raw")
            wait_for(master_fd, output, b"raw output mode: on", 5, mark)

            mark = len(output)
            send_line(master_fd, "/statusline model,fast-mode,raw-output")
            wait_for(master_fd, output, b"status line: model, fast-mode, raw-output", 5, mark)
            wait_for(master_fd, output, b"preview:", 5, mark)
            wait_for(master_fd, output, b"fast", 5, mark)
            wait_for(master_fd, output, b"raw output", 5, mark)

            mark = len(output)
            send_line(master_fd, "/raw off")
            wait_for(master_fd, output, b"raw output mode: off", 5, mark)

            mark = len(output)
            send_line(master_fd, "/vim")
            wait_for(master_fd, output, b"vim mode: on", 5, mark)

            mark = len(output)
            send_line(master_fd, "/vim")
            wait_for(master_fd, output, b"vim mode: off", 5, mark)

            mark = len(output)
            send_line(master_fd, "/mcp")
            wait_for(master_fd, output, b"mcp servers:", 5, mark)
            wait_for(master_fd, output, b"docs\tstdio\tdisabled", 5, mark)
            wait_for(master_fd, output, b"remote\tstreamable_http\tenabled", 5, mark)

            mark = len(output)
            send_line(master_fd, "/mcp verbose")
            wait_for(master_fd, output, b"command: docs-server", 5, mark)
            wait_for(master_fd, output, b"url: https://example.com/mcp", 5, mark)

            mark = len(output)
            send_line(master_fd, "!printf bang-shell-ok")
            wait_for(master_fd, output, b"shell: exit 0", 5, mark)
            wait_for(master_fd, output, b"bang-shell-ok", 5, mark)

            mark = len(output)
            send_line(master_fd, "/model gpt-e2e")
            wait_for(master_fd, output, b"model: gpt-e2e", 5, mark)

            mark = len(output)
            send_line(master_fd, "/permissions approval=never sandbox=danger-full-access")
            wait_for(master_fd, output, b"approval: never", 5, mark)
            wait_for(master_fd, output, b"sandbox:  danger-full-access", 5, mark)

            mark = len(output)
            send_line(master_fd, "/permissions approval=on-request sandbox=workspace-write")
            wait_for(master_fd, output, b"approval: on-request", 5, mark)
            wait_for(master_fd, output, b"sandbox:  workspace-write", 5, mark)

            mark = len(output)
            send_line(master_fd, "/history 1")
            wait_for(master_fd, output, b"history: showing 0 of 0 items", 5, mark)
            wait_for(master_fd, output, b"<empty>", 5, mark)

            mark = len(output)
            send_line(master_fd, "/mention mention_context.txt")
            wait_for(master_fd, output, b"mentioned:", 5, mark)
            wait_for(master_fd, output, b"mention_context.txt", 5, mark)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"mentions:    1 pending", 5, mark)

            mark = len(output)
            send_line(master_fd, "summarize the mentioned file")
            wait_for(master_fd, output, b"mentioned file received", 8, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"mentions:    0 pending", 5, mark)

            mark = len(output)
            send_line(master_fd, "/side side question")
            wait_for(master_fd, output, b"side conversation:", 8, mark)
            wait_for(master_fd, output, b"side answer", 8, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/history 2")
            wait_for(master_fd, output, b"history: showing 2 of 2 items", 5, mark)
            wait_for(master_fd, output, b"mentioned file received", 5, mark)

            mark = len(output)
            send_line(master_fd, "track this checklist")
            wait_for(master_fd, output, b"[tool requested] update_plan", 8, mark)
            wait_for(master_fd, output, b"plan:", 5, mark)
            wait_for(master_fd, output, b"[x] Inspect repo", 5, mark)
            wait_for(master_fd, output, b"[>] Patch feature", 5, mark)
            wait_for(master_fd, output, b"[ ] Verify behavior", 5, mark)
            wait_for(master_fd, output, b"[tool result] plan updated 1/3", 8, mark)
            wait_for(master_fd, output, b"plan tracked", 8, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/statusline task-progress")
            wait_for(master_fd, output, b"status line: task-progress", 5, mark)
            wait_for(master_fd, output, b"preview: Tasks 1/3", 5, mark)

            mark = len(output)
            send_line(master_fd, "/title task-progress")
            wait_for(master_fd, output, b"\x1b]0;Tasks 1/3\x07", 5, mark)
            wait_for(master_fd, output, b"terminal title: on", 5, mark)
            wait_for(master_fd, output, b"items: task-progress", 5, mark)

            mark = len(output)
            send_line(master_fd, "/statusline model,fast-mode,raw-output")
            wait_for(master_fd, output, b"status line: model, fast-mode, raw-output", 5, mark)

            mark = len(output)
            send_line(master_fd, "start a background terminal")
            wait_for(master_fd, output, b"Tool approval required", 8, mark)
            wait_for(master_fd, output, b"Run this command? [y/N]", 5, mark)
            mark = len(output)
            send_line(master_fd, "y")
            wait_for(master_fd, output, b"[tool result] session 1000", 10, mark)
            wait_for(master_fd, output, b"background terminal started", 8, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/copy")
            wait_for(master_fd, output, b"copied ", 5, mark)
            expected_copy = "I'll start a background command.\nbackground terminal started\n"
            if copy_capture.read_text() != expected_copy:
                raise AssertionError(
                    f"unexpected copied content: {copy_capture.read_text()!r}"
                )

            mark = len(output)
            send_line(master_fd, "/history 4")
            wait_for(master_fd, output, b"history: showing 4 of 10 items", 5, mark)
            wait_for(master_fd, output, b"tool call: exec_command", 5, mark)
            wait_for(master_fd, output, b"#10 assistant:", 5, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/ps")
            wait_for(master_fd, output, b"background terminals:", 5, mark)
            wait_for(master_fd, output, b"1000. pty", 5, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "create the demo file")
            wait_for(master_fd, output, b"Tool approval required", 8, mark)
            wait_for(master_fd, output, b"Run this patch? [y/N]", 5, mark)
            mark = len(output)
            send_line(master_fd, "y")
            wait_for(master_fd, output, b"[tool result] patched +1 ~0 -0", 10, mark)
            wait_for(master_fd, output, b"demo file created", 8, mark)
            read_available(master_fd, output, 0.2)

            if not demo_file.exists():
                raise AssertionError(f"expected demo file to exist: {demo_file}")
            contents = demo_file.read_text()
            if contents != "created by codex-zig tui e2e\n":
                raise AssertionError(f"unexpected demo file contents: {contents!r}")

            mark = len(output)
            send_line(master_fd, "/history 8")
            wait_for(master_fd, output, b"history: showing 8 of 14 items", 5, mark)
            wait_for(master_fd, output, b"tool call: apply_patch", 5, mark)
            wait_for(master_fd, output, b"demo file created", 5, mark)
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/clean")
            wait_for(master_fd, output, b"stopped 1 background terminal(s)", 5, mark)

            mark = len(output)
            send_line(master_fd, "/ps")
            wait_for(master_fd, output, b"background terminals: none", 5, mark)

            mark = len(output)
            send_line(master_fd, "/plan on")
            wait_for(master_fd, output, b"plan mode: on", 5, mark)

            mark = len(output)
            send_line(master_fd, "draft a plan")
            wait_for(master_fd, output, b"Plan intro", 8, mark)
            wait_for(master_fd, output, b"proposed plan:", 8, mark)
            wait_for(master_fd, output, b"1. Inspect the repo", 8, mark)
            wait_for(master_fd, output, b"3. Verify the TUI", 8, mark)
            if b"<proposed_plan>" in output[mark:]:
                raise AssertionError("plan-mode transcript leaked <proposed_plan> tag")
            read_available(master_fd, output, 0.2)

            mark = len(output)
            send_line(master_fd, "/plan off")
            wait_for(master_fd, output, b"plan mode: off", 5, mark)

            mark = len(output)
            send_line(master_fd, "/title app-name thread-title")
            wait_for(master_fd, output, b"\x1b]0;codex | Zig demo\x07", 5, mark)
            wait_for(master_fd, output, b"terminal title: on", 5, mark)

            mark = len(output)
            send_line(master_fd, "/quit")
            wait_for(master_fd, output, b"bye", 5, mark)
            read_available(master_fd, output)
            exit_code = proc.wait(timeout=5)
            if exit_code != 0:
                raise AssertionError(f"codex-zig exited with {exit_code}")
            os.close(master_fd)
            master_fd = -1
            proc = None

            if ALT_SCREEN_ENTER in output or ALT_SCREEN_LEAVE in output:
                raise AssertionError("--no-alt-screen emitted alternate-screen escapes")
            run_alt_screen_smoke(binary, env, workspace, port)
            run_alt_screen_never_config_smoke(binary, env, workspace, port)

            master_fd, slave_fd = pty.openpty()
            proc = subprocess.Popen(
                [
                    str(binary),
                    "--no-alt-screen",
                    "-c",
                    f"chatgpt_base_url=http://127.0.0.1:{port}",
                ],
                cwd=workspace,
                env=env,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
            )
            os.close(slave_fd)

            wait_for(master_fd, output, b"Type /help for commands", 8, len(output))
            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"term title:  on", 5, mark)
            wait_for(master_fd, output, b"status line: model, fast-mode, raw-output", 5, mark)
            wait_for(master_fd, output, b"theme:       custom-demo", 5, mark)
            wait_for(master_fd, output, b"personality: friendly", 5, mark)
            mark = len(output)
            send_line(master_fd, "/quit")
            wait_for(master_fd, output, b"bye", 5, mark)
            read_available(master_fd, output)
            exit_code = proc.wait(timeout=5)
            if exit_code != 0:
                raise AssertionError(f"fresh codex-zig exited with {exit_code}")
            os.close(master_fd)
            master_fd = -1
            proc = None

        if server.request_count < 2:
            raise AssertionError(f"expected at least 2 API requests, saw {server.request_count}")
        models = [body.get("model") for body in server.request_bodies]
        if "gpt-e2e" not in models:
            raise AssertionError(f"expected model override in API requests, saw {models!r}")
        service_tiers = [body.get("service_tier") for body in server.request_bodies]
        if "priority" not in service_tiers:
            raise AssertionError(
                f"expected priority service tier in API requests, saw {service_tiers!r}"
            )
        user_texts = [
            latest_user_text(body.get("input", []))
            for body in server.request_bodies
            if isinstance(body.get("input", []), list)
        ]
        if not any("codex zig mention context" in text for text in user_texts):
            raise AssertionError("expected mentioned file content in an API request")
        plan_bodies = [
            body
            for body in server.request_bodies
            if "draft a plan" in latest_user_text(body.get("input", []))
        ]
        if not any(body.get("tools") == [] for body in plan_bodies):
            raise AssertionError("expected plan-mode request to omit tools")
        instructions = [
            body.get("instructions", "")
            for body in server.request_bodies
            if isinstance(body.get("instructions", ""), str)
        ]
        if not any("<personality_spec>" in text and "team morale" in text for text in instructions):
            raise AssertionError("expected friendly personality instructions in an API request")
        if ALT_SCREEN_ENTER in output or ALT_SCREEN_LEAVE in output:
            raise AssertionError("--no-alt-screen emitted alternate-screen escapes")
        return output.decode(errors="replace")
    finally:
        server.shutdown()
        server.server_close()
        if master_fd != -1:
            os.close(master_fd)
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex Zig TUI E2E in a PTY.")
    parser.add_argument(
        "--bin",
        default="zig-out/bin/codex-zig",
        help="Path to the codex-zig binary relative to repo root, or absolute.",
    )
    parser.add_argument(
        "--show-output",
        action="store_true",
        help="Print the captured terminal transcript after success.",
    )
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    binary = Path(args.bin)
    if not binary.is_absolute():
        binary = repo / binary

    transcript = run_e2e(binary)
    print("tui-e2e: ok")
    if args.show_output:
        print(transcript)
    return 0


if __name__ == "__main__":
    sys.exit(main())
