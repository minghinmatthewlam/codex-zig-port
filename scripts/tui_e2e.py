#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pty
import select
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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


def start_mock_server(port: int) -> MockResponsesServer:
    server = MockResponsesServer(("127.0.0.1", port), MockResponsesHandler)
    server.request_count = 0
    server.request_bodies = []
    server.get_paths = []
    server.get_headers = []
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
    if "codex-zig --remote ws://HOST:PORT" not in root_result.stderr:
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
    for command in ['commands="a ', "app-server", "apply", "cloud-tasks", "remote-control"]:
        if command not in completion_result.stdout:
            raise AssertionError(
                f"expected {command} in bash completion:\n{completion_result.stdout}"
            )


def run_unimplemented_command_smoke(
    binary: Path,
    env: dict[str, str],
    workspace: Path,
) -> None:
    for command in [
        "remote-control",
        "app",
        "update",
        "cloud",
        "cloud-tasks",
        "responses-api-proxy",
        "exec-server",
    ]:
        result = subprocess.run(
            [str(binary), command],
            cwd=workspace,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError(f"{command} unexpectedly succeeded")
        if "parsed but not implemented yet" not in result.stderr:
            raise AssertionError(
                f"expected not-implemented message for {command}:\n{result.stderr}"
            )


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
    remote_result = subprocess.run(
        [
            str(binary),
            "--remote",
            "ws://127.0.0.1:4500",
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
    if remote_result.returncode == 0:
        raise AssertionError("remote TUI smoke unexpectedly succeeded")
    if "remote app-server TUI is parsed but not implemented yet" not in remote_result.stderr:
        raise AssertionError(
            f"expected remote not-implemented message:\n{remote_result.stderr}"
        )

    resume_result = subprocess.run(
        [
            str(binary),
            "resume",
            "--remote=ws://127.0.0.1:4500",
            "--last",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if resume_result.returncode == 0:
        raise AssertionError("remote resume smoke unexpectedly succeeded")
    if "remote app-server TUI is parsed but not implemented yet" not in resume_result.stderr:
        raise AssertionError(
            f"expected remote resume not-implemented message:\n{resume_result.stderr}"
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

    local_remote_result = subprocess.run(
        [
            str(binary),
            "--remote-control",
            "--remote-control-bind",
            "127.0.0.1:0",
            "--no-alt-screen",
        ],
        cwd=workspace,
        env=remote_env,
        text=True,
        capture_output=True,
        check=False,
    )
    if local_remote_result.returncode == 0:
        raise AssertionError("local remote-control smoke unexpectedly succeeded")
    if "local remote control is parsed but not implemented yet" not in local_remote_result.stderr:
        raise AssertionError(
            f"expected local remote-control not-implemented message:\n{local_remote_result.stderr}"
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
    if "remote app-server TUI is parsed but not implemented yet" not in resume_result.stderr:
        raise AssertionError(
            f"expected resume remote not-implemented message:\n{resume_result.stderr}"
        )

    fork_result = subprocess.run(
        [
            str(binary),
            "fork",
            "--all",
            "--yolo",
            "--no-alt-screen",
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
    if "remote app-server TUI is parsed but not implemented yet" not in fork_result.stderr:
        raise AssertionError(
            f"expected fork remote not-implemented message:\n{fork_result.stderr}"
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
            run_session_command_option_smoke(binary, env, workspace)
            run_unimplemented_command_smoke(binary, env, workspace)
            run_plugin_marketplace_smoke(binary, env, workspace)
            run_debug_clear_memories_smoke(binary, env, workspace)
            run_debug_stub_smoke(binary, env, workspace, port)
            run_initial_image_smoke(binary, env, workspace, port, server)
            run_apply_command_smoke(binary, env, workspace, port, server)

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
