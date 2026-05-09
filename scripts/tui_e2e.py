#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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


def has_tool_output(items: list[object], call_id: str) -> bool:
    return any(
        isinstance(item, dict)
        and item.get("type") == "function_call_output"
        and item.get("call_id") == call_id
        for item in items
    )


class MockResponsesHandler(BaseHTTPRequestHandler):
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
        if "create the demo file" in latest_prompt and has_tool_output(
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


def start_mock_server(port: int) -> MockResponsesServer:
    server = MockResponsesServer(("127.0.0.1", port), MockResponsesHandler)
    server.request_count = 0
    server.request_bodies = []
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
            workspace = Path(home) / "workspace"
            workspace.mkdir()
            demo_file = workspace / "codex_zig_tui_file.txt"
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

            master_fd, slave_fd = pty.openpty()
            env = os.environ.copy()
            env["CODEX_HOME"] = home
            env["CODEX_ZIG_COPY_COMMAND"] = str(copy_command)
            env.setdefault("TERM", "xterm-256color")
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

            mark = len(output)
            send_line(master_fd, "/status")
            wait_for(master_fd, output, b"status:", 5, mark)
            wait_for(master_fd, output, b"service tier: unset", 5, mark)
            wait_for(master_fd, output, b"raw output:  off", 5, mark)
            wait_for(master_fd, output, b"vim:         off", 5, mark)
            wait_for(master_fd, output, b"tools:", 5, mark)

            mark = len(output)
            send_line(master_fd, "/debug-config")
            wait_for(master_fd, output, b"/debug-config", 5, mark)
            wait_for(master_fd, output, b"effective config:", 5, mark)
            wait_for(master_fd, output, b"config layers: not yet implemented", 5, mark)

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
            wait_for(master_fd, output, b"history: showing 4 of 4 items", 5, mark)
            wait_for(master_fd, output, b"tool call: exec_command", 5, mark)
            wait_for(master_fd, output, b"#4 assistant:", 5, mark)
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
            wait_for(master_fd, output, b"history: showing 8 of 8 items", 5, mark)
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
            send_line(master_fd, "/quit")
            wait_for(master_fd, output, b"bye", 5, mark)
            read_available(master_fd, output)
            exit_code = proc.wait(timeout=5)
            if exit_code != 0:
                raise AssertionError(f"codex-zig exited with {exit_code}")

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
