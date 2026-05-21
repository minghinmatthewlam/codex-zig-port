#!/usr/bin/env python3
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


def stdout_line_queue(proc: subprocess.Popen[str]) -> queue.Queue[str]:
    assert proc.stdout is not None
    line_queue: queue.Queue[str] = queue.Queue()

    def read_lines() -> None:
        while True:
            line = proc.stdout.readline()
            line_queue.put(line)
            if not line:
                break

    threading.Thread(target=read_lines, daemon=True).start()
    return line_queue


def write_json_line(proc: subprocess.Popen[str], payload: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def read_json_line(
    proc: subprocess.Popen[str],
    line_queue: queue.Queue[str],
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            stderr = proc.stderr.read() if proc.stderr is not None else ""
            raise AssertionError(f"app-server exited {proc.returncode}: {stderr}")
        try:
            line = line_queue.get(timeout=0.1)
        except queue.Empty:
            continue
        if not line:
            stderr = proc.stderr.read() if proc.stderr is not None else ""
            raise AssertionError(f"app-server closed stdout: {stderr}")
        return json.loads(line)
    raise TimeoutError("timed out waiting for app-server JSON-RPC output")


def read_response(
    proc: subprocess.Popen[str],
    line_queue: queue.Queue[str],
    request_id: str,
    timeout: float = 20.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        message = read_json_line(proc, line_queue, max(0.1, deadline - time.monotonic()))
        if message.get("id") == request_id:
            return message
    raise TimeoutError(f"timed out waiting for response {request_id}")


def request(
    proc: subprocess.Popen[str],
    line_queue: queue.Queue[str],
    request_id: str,
    method: str,
    params: dict[str, Any] | None = None,
    timeout: float = 20.0,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
    }
    if params is not None:
        payload["params"] = params
    write_json_line(proc, payload)
    return read_response(proc, line_queue, request_id, timeout)


def real_computer_use_cache() -> Path:
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    cache = codex_home / "plugins" / "cache" / "openai-bundled" / "computer-use"
    if not cache.is_dir():
        raise AssertionError(f"computer-use plugin cache not found: {cache}")
    if not any((child / ".mcp.json").is_file() for child in cache.iterdir() if child.is_dir()):
        raise AssertionError(f"computer-use plugin cache has no versioned .mcp.json: {cache}")
    return cache


def configure_temp_codex_home(temp_home: Path, computer_use_cache: Path) -> None:
    plugin_parent = temp_home / "plugins" / "cache" / "openai-bundled"
    plugin_parent.mkdir(parents=True)
    os.symlink(computer_use_cache, plugin_parent / "computer-use")
    (temp_home / "config.toml").write_text(
        "\n".join(
            [
                "[features]",
                "plugins = true",
                "",
                '[plugins."computer-use@openai-bundled"]',
                "enabled = true",
                "",
            ]
        ),
        encoding="utf-8",
    )


def tool_names(status: dict[str, Any]) -> list[str]:
    servers = status["result"]["data"]
    computer_use = next(server for server in servers if server["name"] == "computer-use")
    tools = computer_use["tools"]
    if not isinstance(tools, dict):
        raise AssertionError(f"unexpected computer-use tools payload: {tools!r}")
    return sorted(tools.keys())


def choose_non_destructive_tool(names: list[str]) -> str:
    for candidate in ("get_app_state", "list_apps"):
        if candidate in names:
            return candidate
    raise AssertionError(f"expected get_app_state or list_apps in computer-use tools: {names}")


def run_smoke(binary: Path) -> None:
    computer_use_cache = real_computer_use_cache()
    temp_home = Path(tempfile.mkdtemp(prefix="codex-zig-real-computer-use-", dir="/tmp"))
    try:
        configure_temp_codex_home(temp_home, computer_use_cache)
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_home)
        proc = subprocess.Popen(
            [str(binary), "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        line_queue = stdout_line_queue(proc)
        try:
            initialized = request(
                proc,
                line_queue,
                "initialize",
                "initialize",
                {
                    "clientInfo": {"name": "real-computer-use-smoke", "version": "0"},
                    "capabilities": {
                        "experimentalApi": True,
                        "optOutNotificationMethods": [
                            "thread/started",
                            "configWarning",
                            "mcpServer/startupStatus/updated",
                        ],
                    },
                },
            )
            assert initialized["id"] == "initialize"

            status = request(
                proc,
                line_queue,
                "mcp-status",
                "mcpServerStatus/list",
                {"detail": "toolsAndAuthOnly"},
                timeout=30.0,
            )
            names = tool_names(status)
            selected_tool = choose_non_destructive_tool(names)

            thread_start = request(
                proc,
                line_queue,
                "thread-start",
                "thread/start",
                {"ephemeral": True},
                timeout=30.0,
            )
            thread_id = thread_start["result"]["thread"]["id"]

            tool_call = request(
                proc,
                line_queue,
                "computer-use-tool-call",
                "mcpServer/tool/call",
                {
                    "threadId": thread_id,
                    "server": "computer-use",
                    "tool": selected_tool,
                    "arguments": {},
                },
                timeout=30.0,
            )
            if "error" in tool_call:
                raise AssertionError(f"computer-use tool call failed: {tool_call['error']}")
            result = tool_call["result"]
            if not isinstance(result, dict) or "content" not in result:
                raise AssertionError(f"unexpected computer-use tool result: {result!r}")

            print("real-computer-use-mcp-tool-smoke: ok")
            print(
                json.dumps(
                    {
                        "codex_home": str(temp_home),
                        "plugin_cache": str(computer_use_cache),
                        "tool_count": len(names),
                        "tool_called": selected_tool,
                    },
                    sort_keys=True,
                )
            )
            assert proc.stdin is not None
            proc.stdin.close()
            proc.wait(timeout=5)
            if proc.returncode != 0:
                stderr = proc.stderr.read() if proc.stderr is not None else ""
                raise AssertionError(f"app-server exited {proc.returncode}: {stderr}")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        shutil.rmtree(temp_home, ignore_errors=True)


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_smoke(binary)


if __name__ == "__main__":
    main()
