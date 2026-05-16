#!/usr/bin/env python3
import base64
import difflib
import hashlib
import json
import os
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPLETION_SHELLS = ("bash", "elvish", "fish", "powershell", "zsh")
COMPLETION_REQUIRED_VALUES = (
    "app-server",
    "completion",
    "execpolicy",
    "remote-control",
    "remote-fork",
    "--remote-auth-token-env",
    "--remote-control-bind",
    "bash elvish fish powershell zsh",
    "untrusted on-failure on-request never",
    "read-only workspace-write danger-full-access",
    "lmstudio ollama",
)


def header_value(headers: dict[str, str], name: str) -> Optional[str]:
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return None


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def child_process_statuses(parent_pid: int) -> list[str]:
    result = subprocess.run(
        ["ps", "-o", "pid=,ppid=,stat=,command=", "-A"],
        text=True,
        stdout=subprocess.PIPE,
        check=True,
    )
    statuses: list[str] = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) >= 3 and parts[1] == str(parent_pid):
            statuses.append(line)
    return statuses


def assert_no_zombie_children(parent_pid: int) -> None:
    zombies = [line for line in child_process_statuses(parent_pid) if line.split(None, 3)[2].startswith("Z")]
    assert zombies == []


def wait_for_exec_server_websocket_bind(proc: subprocess.Popen[str], timeout: float) -> tuple[str, int]:
    assert proc.stderr is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"exec-server exited before websocket bind: {proc.stderr.read()}")
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
    raise AssertionError("timed out waiting for exec-server websocket bind address")


def wait_for_exec_server_file(path: Path, proc: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        if proc.poll() is not None:
            raise AssertionError(f"exec-server exited while waiting for {path}")
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}")


def websocket_http_status(host: str, port: int, path: str) -> int:
    with socket.create_connection((host, port), timeout=5) as client:
        client.sendall(
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n".encode(
                "ascii"
            )
        )
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        status_line = data.split(b"\r\n", 1)[0].decode("ascii")
        return int(status_line.split()[1])


class ExecServerSmokeWebSocket:
    def __init__(self, host: str, port: int) -> None:
        self.sock = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        self.sock.sendall(
            (
                f"GET / HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode("ascii")
        )
        response = self._recv_until(b"\r\n\r\n")
        status_line = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line:
            raise AssertionError(f"websocket handshake failed: {response!r}")
        response_lower = response.lower()
        if b"connection: upgrade" not in response_lower:
            raise AssertionError(f"websocket handshake missing upgrade connection: {response!r}")
        expected_accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        expected_header = f"sec-websocket-accept: {expected_accept}".lower().encode("ascii")
        if expected_header not in response_lower:
            raise AssertionError(f"websocket accept mismatch: {response!r}")

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        finally:
            self.sock.close()

    def write_json(self, payload: dict) -> None:
        self._send_frame(0x1, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def read_json(self) -> dict:
        payload = self._read_frame()
        if payload is None:
            raise AssertionError("websocket closed before response")
        return json.loads(payload.decode("utf-8"))

    def _recv_until(self, delimiter: bytes) -> bytes:
        data = b""
        while delimiter not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    def _recv_exact(self, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise AssertionError("websocket closed unexpectedly")
            data += chunk
        return data

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        if len(payload) <= 125:
            header.append(0x80 | len(payload))
        elif len(payload) <= 0xFFFF:
            header.append(0x80 | 126)
            header.extend(len(payload).to_bytes(2, "big"))
        else:
            header.append(0x80 | 127)
            header.extend(len(payload).to_bytes(8, "big"))
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def _read_frame(self) -> bytes | None:
        first, second = self._recv_exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = int.from_bytes(self._recv_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._recv_exact(8), "big")
        masked = (second & 0x80) != 0
        mask = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            return None
        if opcode != 0x1:
            raise AssertionError(f"unexpected websocket opcode {opcode}")
        return payload


def dump_header_value(headers: list[dict[str, str]], name: str) -> Optional[str]:
    for header in headers:
        if header.get("name", "").lower() == name.lower():
            return header.get("value")
    return None


class ExecResponsesHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        payload = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.request_paths.append(self.path)
        self.server.request_bodies.append(json.loads(body))
        self.server.request_headers.append(dict(self.headers.items()))
        status = self.server.response_statuses.pop(0) if self.server.response_statuses else 200
        delay = self.server.response_delays.pop(0) if self.server.response_delays else 0
        if delay:
            time.sleep(delay)
        if status == 401:
            payload = b"unauthorized"
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        chunks = self.server.response_chunks.pop(0) if self.server.response_chunks else None
        if chunks is not None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for payload, chunk_delay in chunks:
                self.wfile.write(f"{len(payload):x}\r\n".encode())
                self.wfile.write(payload)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                if chunk_delay:
                    time.sleep(chunk_delay)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        payload = self.server.response_payloads.pop(0) if self.server.response_payloads else default_exec_response_payload()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class ExecResponsesServer(ThreadingHTTPServer):
    request_paths: list[str]
    request_bodies: list[dict]
    request_headers: list[dict[str, str]]
    response_statuses: list[int]
    response_payloads: list[bytes]
    response_chunks: list[list[tuple[bytes, float]]]
    response_delays: list[float]


class McpOAuthDiscoveryHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.server.request_paths.append(self.path)
        if self.path == "/.well-known/oauth-authorization-server/mcp":
            payload = json.dumps(
                {
                    "authorization_endpoint": f"{self.server.base_url}/oauth/authorize",
                    "token_endpoint": f"{self.server.base_url}/oauth/token",
                    "scopes_supported": ["read", "write"],
                },
                separators=(",", ":"),
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        payload = b"not found"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class McpOAuthDiscoveryServer(ThreadingHTTPServer):
    request_paths: list[str]
    base_url: str


class StreamableMcpToolHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.server.request_paths.append(self.path)
        self.server.request_headers.append(dict(self.headers.items()))
        self.server.request_bodies.append({"method": "GET"})
        payload = self.server.pending_stream_responses.pop(0)
        encoded = b"event: message\ndata: " + json.dumps(
            payload, separators=(",", ":")
        ).encode() + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Mcp-Session-Id", self.server.session_id)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_DELETE(self) -> None:
        self.server.request_paths.append(self.path)
        self.server.request_headers.append(dict(self.headers.items()))
        self.server.request_bodies.append({"method": "DELETE"})
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        request = json.loads(body)
        self.server.request_paths.append(self.path)
        self.server.request_headers.append(dict(self.headers.items()))
        self.server.request_bodies.append(request)

        method = request.get("method")
        request_id = request.get("id")
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "initialize":
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "protocolVersion": "2025-03-26",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "streamable-tool-smoke", "version": "0.1.0"},
                    },
                }
            )
            return
        if method == "tools/list":
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "tools": [
                            {
                                "name": "echo",
                                "description": "Echo a message from streamable HTTP.",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {"message": {"type": "string"}},
                                    "additionalProperties": False,
                                },
                            }
                        ]
                    },
                }
            )
            return
        if method == "tools/call":
            params = request.get("params", {})
            arguments = params.get("arguments", {})
            message = arguments.get("message", "") if isinstance(arguments, dict) else ""
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [{"type": "text", "text": f"http echo: {message}"}],
                        "structuredContent": {"transport": "streamable_http"},
                        "isError": False,
                    },
                }
            )
            return
        if method == "resources/list":
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "resources": [
                            {
                                "uri": "https://remote.example/resource.md",
                                "name": "remote-resource",
                                "description": "Remote MCP resource.",
                                "mimeType": "text/markdown",
                            }
                        ],
                        "nextCursor": None,
                    },
                }
            )
            return
        if method == "resources/templates/list":
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "resourceTemplates": [
                            {
                                "uriTemplate": "https://remote.example/{slug}.md",
                                "name": "remote-template",
                                "description": "Remote MCP template.",
                            }
                        ],
                        "nextCursor": None,
                    },
                }
            )
            return
        if method == "resources/read":
            uri = request.get("params", {}).get("uri")
            self.write_or_defer(
                method,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "contents": [
                            {
                                "uri": uri,
                                "mimeType": "text/markdown",
                                "text": "remote resource body",
                            }
                        ]
                    },
                }
            )
            return
        self.write_or_defer(
            method,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unknown method: {method}"},
            }
        )

    def write_or_defer(self, method: str, payload: dict) -> None:
        if method in self.server.deferred_methods:
            self.server.pending_stream_responses.append(payload)
            self.send_response(202)
            self.send_header("Mcp-Session-Id", self.server.session_id)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.write_rpc(payload)

    def write_rpc(self, payload: dict) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", self.server.session_id)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class StreamableMcpToolServer(ThreadingHTTPServer):
    request_paths: list[str]
    request_headers: list[dict[str, str]]
    request_bodies: list[dict]
    deferred_methods: set[str]
    pending_stream_responses: list[dict]
    session_id: str


def default_exec_response_payload() -> bytes:
    return (
        b'data: {"type":"response.output_text.delta","delta":"stored reply"}\n\n'
        b"data: [DONE]\n\n"
    )


def function_call_response_payload(call_id: str, name: str, arguments: dict) -> bytes:
    event = {
        "type": "response.output_item.done",
        "item": {
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": json.dumps(arguments, separators=(",", ":")),
        },
    }
    return f"data: {json.dumps(event, separators=(',', ':'))}\n\ndata: [DONE]\n\n".encode()


def start_exec_responses_server() -> tuple[ExecResponsesServer, str]:
    server = ExecResponsesServer(("127.0.0.1", 0), ExecResponsesHandler)
    server.request_paths = []
    server.request_bodies = []
    server.request_headers = []
    server.response_statuses = []
    server.response_payloads = []
    server.response_chunks = []
    server.response_delays = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


def start_mcp_oauth_discovery_server() -> tuple[McpOAuthDiscoveryServer, str]:
    server = McpOAuthDiscoveryServer(("127.0.0.1", 0), McpOAuthDiscoveryHandler)
    server.request_paths = []
    server.base_url = f"http://127.0.0.1:{server.server_port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"{server.base_url}/mcp"


def start_streamable_mcp_tool_server() -> tuple[StreamableMcpToolServer, str]:
    server = StreamableMcpToolServer(("127.0.0.1", 0), StreamableMcpToolHandler)
    server.request_paths = []
    server.request_headers = []
    server.request_bodies = []
    server.deferred_methods = set()
    server.pending_stream_responses = []
    server.session_id = "streamable-session-1"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}/mcp"


def make_exec_mock_env(temp_root: Path, base_url: str) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        f'openai_base_url = "{base_url}"\n',
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["OPENAI_API_KEY"] = "test-api-key"
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_env_key_env(temp_root: Path, base_url: str) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-provider-env"',
                'model_provider = "corp"',
                "",
                "[model_providers.corp]",
                f'base_url = "{base_url}"',
                'env_key = "CORP_API_KEY"',
                'wire_api = "responses"',
                'requires_openai_auth = false',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CORP_API_KEY"] = "provider-token"
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_wire_api_env(temp_root: Path, base_url: str, wire_api: str) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-provider-wire"',
                'model_provider = "corp"',
                "",
                "[model_providers.corp]",
                f'base_url = "{base_url}"',
                'env_key = "CORP_API_KEY"',
                f'wire_api = "{wire_api}"',
                'requires_openai_auth = false',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CORP_API_KEY"] = "provider-token"
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_headers_env(temp_root: Path, base_url: str) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-provider-headers"',
                'model_provider = "corp"',
                "",
                "[model_providers.corp]",
                f'base_url = "{base_url}"',
                'env_key = "CORP_API_KEY"',
                'wire_api = "responses"',
                'requires_openai_auth = false',
                'http_headers = { "X-Corp-Static" = "static-value" }',
                "",
                "[model_providers.corp.env_http_headers]",
                '"X-Corp-Env" = "CORP_HEADER_TOKEN"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CORP_API_KEY"] = "provider-token"
    env["CORP_HEADER_TOKEN"] = "env-header-value"
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_query_params_env(temp_root: Path, base_url: str) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-provider-query"',
                'model_provider = "corp"',
                "",
                "[model_providers.corp]",
                f'base_url = "{base_url}/custom"',
                'env_key = "CORP_API_KEY"',
                'wire_api = "responses"',
                'requires_openai_auth = false',
                'query_params = { "api-version" = "2025-04-01-preview", "deployment" = "codex-test" }',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CORP_API_KEY"] = "provider-token"
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_command_auth_env(
    temp_root: Path,
    base_url: str,
    inline_auth: bool = False,
    conflict_env_key: bool = False,
) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    auth_dir = temp_root / "provider-auth"
    auth_dir.mkdir()
    token_script = auth_dir / "print-token.sh"
    token_script.write_text("#!/bin/sh\nprintf '%s\\n' \"$1\"\n", encoding="utf-8")
    token_script.chmod(0o755)
    auth_config = (
        [
            (
                'auth = { command = "./print-token.sh", args = ["command-token"], '
                f'cwd = "{auth_dir}", timeout_ms = 5000 }}'
            ),
            "",
        ]
        if inline_auth
        else [
            "",
            "[model_providers.corp.auth]",
            'command = "./print-token.sh"',
            'args = ["command-token"]',
            f'cwd = "{auth_dir}"',
            "timeout_ms = 5000",
            "",
        ]
    )
    provider_config = [
        'model = "gpt-provider-command"',
        'model_provider = "corp"',
        "",
        "[model_providers.corp]",
        f'base_url = "{base_url}"',
        'wire_api = "responses"',
        'requires_openai_auth = false',
    ]
    if conflict_env_key:
        provider_config.append('env_key = "CORP_API_KEY"')
    (codex_home / "config.toml").write_text(
        "\n".join(provider_config + auth_config),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CORP_API_KEY"] = "conflicting-token"
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def make_exec_provider_command_auth_refresh_env(
    temp_root: Path,
    base_url: str,
    refresh_interval_ms: Optional[int] = None,
) -> dict[str, str]:
    codex_home = temp_root / "codex-home"
    codex_home.mkdir()
    auth_dir = temp_root / "provider-auth-refresh"
    auth_dir.mkdir()
    counter_file = auth_dir / "counter"
    token_script = auth_dir / "refresh-token.sh"
    token_script.write_text(
        "\n".join(
            [
                "#!/bin/sh",
                'if [ -f "$1" ]; then',
                "  printf '%s\\n' second-token",
                "else",
                "  printf '%s\\n' first-token",
                "  touch \"$1\"",
                "fi",
                "",
            ]
        ),
        encoding="utf-8",
    )
    token_script.chmod(0o755)
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-provider-command-refresh"',
                'model_provider = "corp"',
                "",
                "[model_providers.corp]",
                f'base_url = "{base_url}"',
                'wire_api = "responses"',
                'requires_openai_auth = false',
                "",
                "[model_providers.corp.auth]",
                'command = "./refresh-token.sh"',
                f'args = ["{counter_file}"]',
                f'cwd = "{auth_dir}"',
                "timeout_ms = 5000",
                *([] if refresh_interval_ms is None else [f"refresh_interval_ms = {refresh_interval_ms}"]),
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_ACCESS_TOKEN", None)
    return env


def clean_git_env() -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def run_completion_snapshot_smoke(binary: Path) -> None:
    snapshot_dir = REPO_ROOT / "tests" / "snapshots" / "completion"
    combined_output = []
    for shell in COMPLETION_SHELLS:
        result = subprocess.run(
            [str(binary), "completion", shell],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stderr == ""

        snapshot_path = snapshot_dir / f"{shell}.snap"
        expected = snapshot_path.read_text(encoding="utf-8")
        if result.stdout != expected:
            diff = "".join(
                difflib.unified_diff(
                    expected.splitlines(keepends=True),
                    result.stdout.splitlines(keepends=True),
                    fromfile=str(snapshot_path),
                    tofile=f"generated:{shell}",
                )
            )
            raise AssertionError(f"completion snapshot mismatch for {shell}:\n{diff}")

        combined_output.append(result.stdout)

    all_completion_text = "\n".join(combined_output)
    for value in COMPLETION_REQUIRED_VALUES:
        assert value in all_completion_text, f"expected {value!r} in completion snapshots"


def run_update_command_smoke(binary: Path) -> None:
    help_result = subprocess.run(
        [str(binary), "help", "update"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=True,
    )
    assert help_result.stdout == ""
    assert "codex-zig update" in help_result.stderr

    result = subprocess.run(
        [str(binary), "update"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    if result.returncode == 0:
        raise AssertionError("update unexpectedly succeeded in debug build")
    if "`codex update` is not available in debug builds" not in result.stderr:
        raise AssertionError(f"expected debug-build update message:\n{result.stderr}")
    if "parsed but not implemented yet" in result.stderr:
        raise AssertionError(f"update still used generic placeholder:\n{result.stderr}")


def run_exec_server_stdio_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-server-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_root / "codex-home")
        env["EXEC_SERVER_POLICY_PARENT"] = "parent"
        env["EXEC_SERVER_POLICY_SECRET_TOKEN"] = "secret"
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)

        help_result = subprocess.run(
            [str(binary.resolve()), "help", "exec-server"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert help_result.stdout == ""
        assert "codex-zig exec-server [--listen URL]" in help_result.stderr

        shell_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}

        default_proc = subprocess.Popen(
            [str(binary.resolve()), "exec-server"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        default_websocket = None
        try:
            host, port = wait_for_exec_server_websocket_bind(default_proc, 5)
            assert websocket_http_status(host, port, "/readyz") == 200
            assert websocket_http_status(host, port, "/healthz") == 200
            default_websocket = ExecServerSmokeWebSocket(host, port)
            default_websocket.write_json(
                {
                    "jsonrpc": "2.0",
                    "id": "websocket-init",
                    "method": "initialize",
                    "params": {"clientName": "cli-smoke-websocket"},
                }
            )
            websocket_init = default_websocket.read_json()
            assert websocket_init["id"] == "websocket-init"
            assert "sessionId" in websocket_init["result"]
            default_websocket.write_json({"jsonrpc": "2.0", "method": "initialized"})
            default_websocket.write_json(
                {
                    "jsonrpc": "2.0",
                    "id": "websocket-start",
                    "method": "process/start",
                    "params": {
                        "processId": "websocket-proc",
                        "argv": ["/bin/sh", "-c", "printf websocket-ok"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            websocket_start = default_websocket.read_json()
            assert websocket_start["id"] == "websocket-start"
            assert websocket_start["result"]["processId"] == "websocket-proc"
            default_websocket.write_json(
                {
                    "jsonrpc": "2.0",
                    "id": "websocket-read",
                    "method": "process/read",
                    "params": {"processId": "websocket-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            websocket_read = default_websocket.read_json()
            assert websocket_read["id"] == "websocket-read"
            websocket_output = b"".join(
                base64.b64decode(chunk["chunk"])
                for chunk in websocket_read["result"]["chunks"]
                if chunk["stream"] == "stdout"
            )
            assert websocket_output == b"websocket-ok"
            websocket_session_id = websocket_init["result"]["sessionId"]
            websocket_resume_marker = temp_root / "websocket-resume-drained"
            websocket_resume_script = (
                "import pathlib, sys, time; "
                "sys.stdout.write('R' * 2000000); "
                "sys.stdout.flush(); "
                f"pathlib.Path({str(websocket_resume_marker)!r}).write_text('drained', encoding='utf-8'); "
                "time.sleep(30)"
            )
            default_websocket.write_json(
                {
                    "jsonrpc": "2.0",
                    "id": "websocket-resume-start",
                    "method": "process/start",
                    "params": {
                        "processId": "websocket-resume-proc",
                        "argv": [sys.executable, "-c", websocket_resume_script],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            websocket_resume_start = default_websocket.read_json()
            assert websocket_resume_start["id"] == "websocket-resume-start"
            assert websocket_resume_start["result"]["processId"] == "websocket-resume-proc"
            default_websocket.close()
            default_websocket = None
            wait_for_exec_server_file(websocket_resume_marker, default_proc, 5)

            resumed_websocket = ExecServerSmokeWebSocket(host, port)
            try:
                resumed_websocket.write_json(
                    {
                        "jsonrpc": "2.0",
                        "id": "websocket-resume-init",
                        "method": "initialize",
                        "params": {
                            "clientName": "cli-smoke-websocket-resume",
                            "resumeSessionId": websocket_session_id,
                        },
                    }
                )
                websocket_resume_init = resumed_websocket.read_json()
                assert websocket_resume_init["id"] == "websocket-resume-init"
                assert websocket_resume_init["result"]["sessionId"] == websocket_session_id
                resumed_websocket.write_json({"jsonrpc": "2.0", "method": "initialized"})
                resumed_websocket.write_json(
                    {
                        "jsonrpc": "2.0",
                        "id": "websocket-resume-read",
                        "method": "process/read",
                        "params": {
                            "processId": "websocket-resume-proc",
                            "afterSeq": 0,
                            "maxBytes": 4096,
                            "waitMs": 0,
                        },
                    }
                )
                websocket_resume_read = resumed_websocket.read_json()
                assert websocket_resume_read["id"] == "websocket-resume-read"
                assert websocket_resume_read["result"]["failure"] is None
                assert websocket_resume_read["result"]["exited"] is False
                assert websocket_resume_read["result"]["closed"] is False
                resumed_websocket.write_json(
                    {
                        "jsonrpc": "2.0",
                        "id": "websocket-resume-terminate",
                        "method": "process/terminate",
                        "params": {"processId": "websocket-resume-proc"},
                    }
                )
                websocket_resume_terminate = resumed_websocket.read_json()
                assert websocket_resume_terminate["id"] == "websocket-resume-terminate"
                assert websocket_resume_terminate["result"]["running"] is True
            finally:
                resumed_websocket.close()
        finally:
            if default_websocket is not None:
                default_websocket.close()
            default_proc.terminate()
            try:
                default_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                default_proc.kill()
                default_proc.wait(timeout=5)

        invalid_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "http://127.0.0.1:0"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert invalid_result.returncode != 0
        assert "unsupported --listen URL" in invalid_result.stderr

        path_workspace = temp_root / "path-workspace"
        path_dir_bin = path_workspace / "path-dir-bin"
        path_shadow_bin = path_workspace / "path-shadow-bin"
        path_bin = path_workspace / "path-bin"
        path_workspace.mkdir()
        path_dir_bin.mkdir()
        path_shadow_bin.mkdir()
        path_bin.mkdir()
        path_dir_probe = path_dir_bin / "path-probe"
        path_dir_probe.mkdir()
        path_shadow_probe = path_shadow_bin / "path-probe"
        path_shadow_probe.write_text("#!/bin/sh\nprintf 'shadow\\n'\n", encoding="utf-8")
        path_shadow_probe.chmod(0o644)
        path_probe = path_bin / "path-probe"
        path_probe.symlink_to("/bin/pwd")
        requests = [
            {"jsonrpc": "2.0", "id": "invalid-init", "method": "initialize", "params": {}},
            {
                "jsonrpc": "2.0",
                "id": "resume-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke", "resumeSessionId": "missing-session"},
            },
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"clientName": "cli-smoke", "resumeSessionId": None},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {"jsonrpc": "2.0", "id": "unknown", "method": "missing/method", "params": {}},
            {
                "jsonrpc": "2.0",
                "id": "arg0-invalid",
                "method": "process/start",
                "params": {
                    "processId": "arg0-proc",
                    "argv": ["/bin/sh", "-c", "printf bad"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": {"bad": True},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "write-missing",
                "method": "process/write",
                "params": {"processId": "missing-proc", "chunk": ""},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-echo",
                "method": "process/start",
                "params": {
                    "processId": "echo-proc",
                    "argv": ["/bin/sh", "-c", "printf 'ready\\n'"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-echo",
                "method": "process/read",
                "params": {"processId": "echo-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "read-echo-closed",
                "method": "process/read",
                "params": {"processId": "echo-proc", "afterSeq": 1, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "restart-echo",
                "method": "process/start",
                "params": {
                    "processId": "echo-proc",
                    "argv": ["/bin/sh", "-c", "printf 'reused\\n'"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "reread-echo",
                "method": "process/read",
                "params": {"processId": "echo-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-path",
                "method": "process/start",
                "params": {
                    "processId": "path-proc",
                    "argv": ["path-probe"],
                    "cwd": str(path_workspace),
                    "env": {"PATH": f"path-dir-bin{os.pathsep}path-shadow-bin{os.pathsep}path-bin"},
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-path",
                "method": "process/read",
                "params": {"processId": "path-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-big",
                "method": "process/start",
                "params": {
                    "processId": "big-proc",
                    "argv": [sys.executable, "-c", "import sys; sys.stdout.write('A' * 10000)"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-big-limited",
                "method": "process/read",
                "params": {"processId": "big-proc", "afterSeq": 0, "maxBytes": 10, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-after-big",
                "method": "process/start",
                "params": {
                    "processId": "after-big-proc",
                    "argv": ["/bin/sh", "-c", "true"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-big-rest",
                "method": "process/read",
                "params": {"processId": "big-proc", "afterSeq": 1, "maxBytes": 20000, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-cat",
                "method": "process/start",
                "params": {
                    "processId": "cat-proc",
                    "argv": ["/bin/sh", "-c", "while IFS= read -r line; do printf 'echo:%s\\n' \"$line\"; done"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": True,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "duplicate-cat",
                "method": "process/start",
                "params": {
                    "processId": "cat-proc",
                    "argv": ["/bin/sh", "-c", "printf duplicate"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "write-cat",
                "method": "process/write",
                "params": {"processId": "cat-proc", "chunk": base64.b64encode(b"hello\n").decode("ascii")},
            },
            {
                "jsonrpc": "2.0",
                "id": "read-cat",
                "method": "process/read",
                "params": {"processId": "cat-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "terminate-cat",
                "method": "process/terminate",
                "params": {"processId": "cat-proc"},
            },
            {
                "jsonrpc": "2.0",
                "id": "again",
                "method": "initialize",
                "params": {"clientName": "cli-smoke"},
            },
        ]
        payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in requests)
        stdio_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert stdio_result.stderr == ""
        responses = [json.loads(line) for line in stdio_result.stdout.splitlines()]
        assert len(responses) == 23

        invalid_initialize = responses[0]
        assert invalid_initialize["id"] == "invalid-init"
        assert invalid_initialize["error"]["code"] == -32602
        assert "initialize params must include clientName" in invalid_initialize["error"]["message"]

        resume_initialize = responses[1]
        assert resume_initialize["id"] == "resume-init"
        assert resume_initialize["error"]["code"] == -32600
        assert "unknown session id missing-session" in resume_initialize["error"]["message"]

        initialize = responses[2]
        assert initialize["jsonrpc"] == "2.0"
        assert initialize["id"] == 1
        session_id = initialize["result"]["sessionId"]
        uuid.UUID(session_id)

        unknown = responses[3]
        assert unknown["id"] == "unknown"
        assert unknown["error"]["code"] == -32601
        assert "exec-server stub does not implement `missing/method` yet" in unknown["error"]["message"]

        arg0_invalid = responses[4]
        assert arg0_invalid["id"] == "arg0-invalid"
        assert arg0_invalid["error"]["code"] == -32602
        assert "process/start params must include processId" in arg0_invalid["error"]["message"]

        write_missing = responses[5]
        assert write_missing["id"] == "write-missing"
        assert write_missing["result"]["status"] == "unknownProcess"

        start_echo = responses[6]
        assert start_echo["id"] == "start-echo"
        assert start_echo["result"]["processId"] == "echo-proc"

        read_echo = responses[7]
        assert read_echo["id"] == "read-echo"
        echo_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in read_echo["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert echo_output == b"ready\n"

        read_echo_closed = responses[8]
        assert read_echo_closed["id"] == "read-echo-closed"
        assert read_echo_closed["result"]["exited"] is True
        assert read_echo_closed["result"]["closed"] is True
        assert read_echo_closed["result"]["exitCode"] == 0

        restart_echo = responses[9]
        assert restart_echo["id"] == "restart-echo"
        assert restart_echo["error"]["code"] == -32600
        assert "process echo-proc already exists" in restart_echo["error"]["message"]

        reread_echo = responses[10]
        assert reread_echo["id"] == "reread-echo"
        reread_echo_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in reread_echo["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert reread_echo_output == b"ready\n"

        start_path = responses[11]
        assert start_path["id"] == "start-path"
        assert start_path["result"]["processId"] == "path-proc"

        read_path = responses[12]
        assert read_path["id"] == "read-path"
        path_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in read_path["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert path_output == f"{path_workspace.resolve()}\n".encode()

        start_big = responses[13]
        assert start_big["id"] == "start-big"
        assert start_big["result"]["processId"] == "big-proc"

        read_big_limited = responses[14]
        assert read_big_limited["id"] == "read-big-limited"
        big_first = b"".join(base64.b64decode(chunk["chunk"]) for chunk in read_big_limited["result"]["chunks"])
        assert len(big_first) < 10000

        start_after_big = responses[15]
        assert start_after_big["id"] == "start-after-big"
        assert start_after_big["result"]["processId"] == "after-big-proc"

        read_big_rest = responses[16]
        assert read_big_rest["id"] == "read-big-rest"
        big_rest = b"".join(base64.b64decode(chunk["chunk"]) for chunk in read_big_rest["result"]["chunks"])
        assert big_first + big_rest == b"A" * 10000

        start_cat = responses[17]
        assert start_cat["id"] == "start-cat"
        assert start_cat["result"]["processId"] == "cat-proc"

        duplicate_cat = responses[18]
        assert duplicate_cat["id"] == "duplicate-cat"
        assert duplicate_cat["error"]["code"] == -32600
        assert "process cat-proc already exists" in duplicate_cat["error"]["message"]

        write_cat = responses[19]
        assert write_cat["id"] == "write-cat"
        assert write_cat["result"]["status"] == "accepted"

        read_cat = responses[20]
        assert read_cat["id"] == "read-cat"
        cat_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in read_cat["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert cat_output == b"echo:hello\n"

        terminate_cat = responses[21]
        assert terminate_cat["id"] == "terminate-cat"
        assert terminate_cat["result"]["running"] is True

        duplicate = responses[22]
        assert duplicate["id"] == "again"
        assert duplicate["error"]["code"] == -32600
        assert "initialize may only be sent once" in duplicate["error"]["message"]

        fs_root = temp_root / "exec-server-fs"
        fs_nested = fs_root / "nested"
        fs_file = fs_nested / "note.txt"
        fs_missing_recursive_copy = fs_nested / "note-missing-recursive-copy.txt"
        fs_copy_file = fs_nested / "note-copy.txt"
        fs_copy_dir = fs_root / "nested-copy"
        fs_payload_bytes = b"hello from filesystem rpc\n"
        fs_requests = [
            {
                "jsonrpc": "2.0",
                "id": "fs-before-init",
                "method": "fs/readFile",
                "params": {"path": str(fs_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-fs"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "fs-relative-path",
                "method": "fs/readFile",
                "params": {"path": "relative.txt"},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-mkdir",
                "method": "fs/createDirectory",
                "params": {"path": str(fs_nested)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-write",
                "method": "fs/writeFile",
                "params": {
                    "path": str(fs_file),
                    "dataBase64": base64.b64encode(fs_payload_bytes).decode("ascii"),
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-read",
                "method": "fs/readFile",
                "params": {"path": str(fs_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-metadata",
                "method": "fs/getMetadata",
                "params": {"path": str(fs_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-list",
                "method": "fs/readDirectory",
                "params": {"path": str(fs_nested)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-copy-file-missing-recursive",
                "method": "fs/copy",
                "params": {
                    "sourcePath": str(fs_file),
                    "destinationPath": str(fs_missing_recursive_copy),
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-copy-file",
                "method": "fs/copy",
                "params": {
                    "sourcePath": str(fs_file),
                    "destinationPath": str(fs_copy_file),
                    "recursive": False,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-read-copy",
                "method": "fs/readFile",
                "params": {"path": str(fs_copy_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-copy-dir-nonrecursive",
                "method": "fs/copy",
                "params": {
                    "sourcePath": str(fs_nested),
                    "destinationPath": str(fs_copy_dir),
                    "recursive": False,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-copy-dir-self-dotdot",
                "method": "fs/copy",
                "params": {
                    "sourcePath": str(fs_nested / ".." / "nested"),
                    "destinationPath": str(fs_nested),
                    "recursive": True,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-copy-dir",
                "method": "fs/copy",
                "params": {
                    "sourcePath": str(fs_nested),
                    "destinationPath": str(fs_copy_dir),
                    "recursive": True,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-list-copy-dir",
                "method": "fs/readDirectory",
                "params": {"path": str(fs_copy_dir)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-invalid-base64",
                "method": "fs/writeFile",
                "params": {"path": str(fs_file), "dataBase64": "not base64"},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-sandbox",
                "method": "fs/readFile",
                "params": {"path": str(fs_file), "sandbox": {}},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-remove-file",
                "method": "fs/remove",
                "params": {"path": str(fs_copy_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-remove-dir",
                "method": "fs/remove",
                "params": {"path": str(fs_copy_dir)},
            },
            {
                "jsonrpc": "2.0",
                "id": "fs-remove-missing",
                "method": "fs/remove",
                "params": {"path": str(fs_copy_dir), "force": False},
            },
        ]
        fs_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in fs_requests)
        fs_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=fs_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert fs_result.stderr == ""
        fs_responses = [json.loads(line) for line in fs_result.stdout.splitlines()]
        assert len(fs_responses) == 20
        fs_by_id = {response["id"]: response for response in fs_responses}
        assert fs_by_id["fs-before-init"]["error"]["code"] == -32600
        assert "client must call initialize before using filesystem methods" in fs_by_id["fs-before-init"]["error"]["message"]
        uuid.UUID(fs_by_id["fs-init"]["result"]["sessionId"])
        assert fs_by_id["fs-relative-path"]["error"]["code"] == -32602
        assert "AbsolutePathBuf deserialized without a base path" in fs_by_id["fs-relative-path"]["error"]["message"]
        assert fs_by_id["fs-mkdir"]["result"] == {}
        assert fs_by_id["fs-write"]["result"] == {}
        assert base64.b64decode(fs_by_id["fs-read"]["result"]["dataBase64"]) == fs_payload_bytes
        fs_metadata = fs_by_id["fs-metadata"]["result"]
        assert fs_metadata["isFile"] is True
        assert fs_metadata["isDirectory"] is False
        assert fs_metadata["isSymlink"] is False
        assert isinstance(fs_metadata["modifiedAtMs"], int)
        fs_entries = {entry["fileName"]: entry for entry in fs_by_id["fs-list"]["result"]["entries"]}
        assert fs_entries["note.txt"]["isFile"] is True
        assert fs_by_id["fs-copy-file-missing-recursive"]["error"]["code"] == -32602
        assert "recursive" in fs_by_id["fs-copy-file-missing-recursive"]["error"]["message"]
        assert fs_by_id["fs-copy-file"]["result"] == {}
        assert base64.b64decode(fs_by_id["fs-read-copy"]["result"]["dataBase64"]) == fs_payload_bytes
        assert fs_by_id["fs-copy-dir-nonrecursive"]["error"]["code"] == -32600
        assert "fs/copy requires recursive: true" in fs_by_id["fs-copy-dir-nonrecursive"]["error"]["message"]
        assert fs_by_id["fs-copy-dir-self-dotdot"]["error"]["code"] == -32600
        assert "fs/copy cannot copy a directory to itself" in fs_by_id["fs-copy-dir-self-dotdot"]["error"]["message"]
        assert fs_by_id["fs-copy-dir"]["result"] == {}
        fs_copy_entries = {entry["fileName"]: entry for entry in fs_by_id["fs-list-copy-dir"]["result"]["entries"]}
        assert fs_copy_entries["note.txt"]["isFile"] is True
        assert fs_by_id["fs-invalid-base64"]["error"]["code"] == -32600
        assert "fs/writeFile requires valid base64 dataBase64" in fs_by_id["fs-invalid-base64"]["error"]["message"]
        assert fs_by_id["fs-sandbox"]["error"]["code"] == -32600
        assert "direct filesystem operations do not accept sandbox context" in fs_by_id["fs-sandbox"]["error"]["message"]
        assert fs_by_id["fs-remove-file"]["result"] == {}
        assert not fs_copy_file.exists()
        assert fs_by_id["fs-remove-dir"]["result"] == {}
        assert not fs_copy_dir.exists()
        assert fs_by_id["fs-remove-missing"]["error"]["code"] == -32004

        if hasattr(os, "mkfifo") and hasattr(os, "symlink"):
            fs_edge_root = temp_root / "exec-server-fs-edges"
            fs_allowed = fs_edge_root / "allowed"
            fs_outside = fs_edge_root / "outside"
            fs_fifo_source = fs_edge_root / "fifo-source"
            fs_fifo_dest = fs_edge_root / "fifo-dest"
            try:
                fs_allowed.mkdir(parents=True)
                fs_outside.mkdir()
                fs_fifo_source.mkdir()
                (fs_allowed / "secret.txt").write_text("allowed", encoding="utf-8")
                (fs_edge_root / "secret.txt").write_text("root", encoding="utf-8")
                (fs_fifo_source / "note.txt").write_text("copy me", encoding="utf-8")
                os.symlink(fs_outside, fs_allowed / "link")
                os.mkfifo(fs_fifo_source / "named-pipe")
            except (NotImplementedError, OSError):
                shutil.rmtree(fs_edge_root, ignore_errors=True)
            else:
                fs_edge_requests = [
                    {
                        "jsonrpc": "2.0",
                        "id": "fs-edge-init",
                        "method": "initialize",
                        "params": {"clientName": "cli-smoke-fs-edges"},
                    },
                    {"jsonrpc": "2.0", "method": "initialized"},
                    {
                        "jsonrpc": "2.0",
                        "id": "fs-normalized-read",
                        "method": "fs/readFile",
                        "params": {"path": str(fs_allowed / "link" / ".." / "secret.txt")},
                    },
                    {
                        "jsonrpc": "2.0",
                        "id": "fs-copy-dir-with-fifo",
                        "method": "fs/copy",
                        "params": {
                            "sourcePath": str(fs_fifo_source),
                            "destinationPath": str(fs_fifo_dest),
                            "recursive": True,
                        },
                    },
                    {
                        "jsonrpc": "2.0",
                        "id": "fs-read-fifo-copy-note",
                        "method": "fs/readFile",
                        "params": {"path": str(fs_fifo_dest / "note.txt")},
                    },
                    {
                        "jsonrpc": "2.0",
                        "id": "fs-copy-standalone-fifo",
                        "method": "fs/copy",
                        "params": {
                            "sourcePath": str(fs_fifo_source / "named-pipe"),
                            "destinationPath": str(fs_edge_root / "fifo-copy"),
                            "recursive": False,
                        },
                    },
                ]
                fs_edge_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in fs_edge_requests)
                fs_edge_result = subprocess.run(
                    [str(binary.resolve()), "exec-server", "--listen", "stdio"],
                    cwd=temp_root,
                    env=env,
                    input=fs_edge_payload,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=True,
                )
                assert fs_edge_result.stderr == ""
                fs_edge_responses = [json.loads(line) for line in fs_edge_result.stdout.splitlines()]
                assert len(fs_edge_responses) == 5
                fs_edge_by_id = {response["id"]: response for response in fs_edge_responses}
                uuid.UUID(fs_edge_by_id["fs-edge-init"]["result"]["sessionId"])
                assert base64.b64decode(fs_edge_by_id["fs-normalized-read"]["result"]["dataBase64"]) == b"allowed"
                assert fs_edge_by_id["fs-copy-dir-with-fifo"]["result"] == {}
                assert base64.b64decode(fs_edge_by_id["fs-read-fifo-copy-note"]["result"]["dataBase64"]) == b"copy me"
                assert not (fs_fifo_dest / "named-pipe").exists()
                assert fs_edge_by_id["fs-copy-standalone-fifo"]["error"]["code"] == -32600
                assert "fs/copy only supports regular files" in fs_edge_by_id["fs-copy-standalone-fifo"]["error"]["message"]

        bash = shutil.which("bash") or "/bin/bash"
        arg0_requests = [
            {
                "jsonrpc": "2.0",
                "id": "arg0-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-arg0"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "start-arg0",
                "method": "process/start",
                "params": {
                    "processId": "arg0-proc",
                    "argv": [bash, "-c", "printf '%s\\n' \"$0\""],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": "custom-zero",
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-arg0",
                "method": "process/read",
                "params": {"processId": "arg0-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-arg0-piped",
                "method": "process/start",
                "params": {
                    "processId": "arg0-piped-proc",
                    "argv": [bash, "-c", "printf '%s:' \"$0\"; IFS= read -r line; printf '%s\\n' \"$line\""],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": True,
                    "arg0": "pipe-zero",
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "write-arg0-piped",
                "method": "process/write",
                "params": {"processId": "arg0-piped-proc", "chunk": base64.b64encode(b"hello\n").decode("ascii")},
            },
            {
                "jsonrpc": "2.0",
                "id": "read-arg0-piped",
                "method": "process/read",
                "params": {"processId": "arg0-piped-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
            {
                "jsonrpc": "2.0",
                "id": "start-arg0-stdin",
                "method": "process/start",
                "params": {
                    "processId": "arg0-stdin-proc",
                    "argv": [
                        sys.executable,
                        "-c",
                        (
                            "import os,stat; "
                            "mode=os.fstat(0).st_mode; "
                            "print('chr' if stat.S_ISCHR(mode) else 'fifo' if stat.S_ISFIFO(mode) else 'other')"
                        ),
                    ],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": "custom-python-zero",
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-arg0-stdin",
                "method": "process/read",
                "params": {"processId": "arg0-stdin-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
        ]
        arg0_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in arg0_requests)
        arg0_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=arg0_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert arg0_result.stderr == ""
        arg0_responses = [json.loads(line) for line in arg0_result.stdout.splitlines()]
        assert len(arg0_responses) == 8
        arg0_start = arg0_responses[1]
        assert arg0_start["id"] == "start-arg0"
        assert arg0_start["result"]["processId"] == "arg0-proc"
        arg0_read = arg0_responses[2]
        assert arg0_read["id"] == "read-arg0"
        arg0_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in arg0_read["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert arg0_output == b"custom-zero\n"
        arg0_piped_start = arg0_responses[3]
        assert arg0_piped_start["id"] == "start-arg0-piped"
        assert arg0_piped_start["result"]["processId"] == "arg0-piped-proc"
        arg0_piped_write = arg0_responses[4]
        assert arg0_piped_write["id"] == "write-arg0-piped"
        assert arg0_piped_write["result"]["status"] == "accepted"
        arg0_piped_read = arg0_responses[5]
        assert arg0_piped_read["id"] == "read-arg0-piped"
        arg0_piped_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in arg0_piped_read["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert arg0_piped_output == b"pipe-zero:hello\n"
        arg0_stdin_start = arg0_responses[6]
        assert arg0_stdin_start["id"] == "start-arg0-stdin"
        assert arg0_stdin_start["result"]["processId"] == "arg0-stdin-proc"
        arg0_stdin_read = arg0_responses[7]
        assert arg0_stdin_read["id"] == "read-arg0-stdin"
        arg0_stdin_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in arg0_stdin_read["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert arg0_stdin_output == b"chr\n"

        if sys.platform == "darwin":
            tty_proc = subprocess.Popen(
                [str(binary.resolve()), "exec-server", "--listen", "stdio"],
                cwd=temp_root,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            assert tty_proc.stdin is not None
            assert tty_proc.stdout is not None
            assert tty_proc.stderr is not None

            def write_tty(message: dict[str, object]) -> None:
                assert tty_proc.stdin is not None
                tty_proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
                tty_proc.stdin.flush()

            def read_tty_response() -> dict[str, object]:
                assert tty_proc.stdout is not None
                line = tty_proc.stdout.readline()
                if line == "":
                    raise AssertionError(f"exec-server tty smoke exited early: {tty_proc.stderr.read()}")
                return json.loads(line)

            try:
                write_tty(
                    {
                        "jsonrpc": "2.0",
                        "id": "tty-init",
                        "method": "initialize",
                        "params": {"clientName": "cli-smoke-tty"},
                    }
                )
                tty_init = read_tty_response()
                assert tty_init["id"] == "tty-init"
                assert "sessionId" in tty_init["result"]
                write_tty({"jsonrpc": "2.0", "method": "initialized"})
                write_tty(
                    {
                        "jsonrpc": "2.0",
                        "id": "start-tty",
                        "method": "process/start",
                        "params": {
                            "processId": "tty-proc",
                            "argv": [
                                bash,
                                "-c",
                                "printf 'TTY:%s:%s\\n' \"$0\" \"$(test -t 0 && echo yes || echo no)\"; IFS= read -r line; printf 'LINE:%s\\n' \"$line\"",
                            ],
                            "cwd": str(temp_root),
                            "env": shell_env,
                            "tty": True,
                            "pipeStdin": False,
                            "arg0": "tty-zero",
                        },
                    }
                )
                tty_start = read_tty_response()
                assert tty_start["id"] == "start-tty"
                assert tty_start["result"]["processId"] == "tty-proc"

                tty_after_seq = 0
                tty_output = b""
                tty_read_index = 0

                def read_tty_output() -> None:
                    nonlocal tty_after_seq, tty_output, tty_read_index
                    tty_read_index += 1
                    write_tty(
                        {
                            "jsonrpc": "2.0",
                            "id": f"read-tty-{tty_read_index}",
                            "method": "process/read",
                            "params": {"processId": "tty-proc", "afterSeq": tty_after_seq, "maxBytes": 4096, "waitMs": 2000},
                        }
                    )
                    tty_read = read_tty_response()
                    assert tty_read["id"] == f"read-tty-{tty_read_index}"
                    tty_chunks = tty_read["result"]["chunks"]
                    if tty_chunks:
                        assert {chunk["stream"] for chunk in tty_chunks} == {"pty"}
                        tty_output += b"".join(base64.b64decode(chunk["chunk"]) for chunk in tty_chunks)
                    tty_after_seq = max(tty_after_seq, tty_read["result"]["nextSeq"] - 1)

                for _ in range(5):
                    read_tty_output()
                    if b"TTY:tty-zero:yes" in tty_output:
                        break
                assert b"TTY:tty-zero:yes" in tty_output, tty_output

                write_tty(
                    {
                        "jsonrpc": "2.0",
                        "id": "write-tty",
                        "method": "process/write",
                        "params": {"processId": "tty-proc", "chunk": base64.b64encode(b"hello\r").decode("ascii")},
                    }
                )
                tty_write = read_tty_response()
                assert tty_write["id"] == "write-tty"
                assert tty_write["result"]["status"] == "accepted"

                for _ in range(5):
                    read_tty_output()
                    if b"LINE:hello" in tty_output:
                        break
                assert b"LINE:hello" in tty_output, tty_output
            finally:
                if tty_proc.stdin is not None:
                    tty_proc.stdin.close()
                try:
                    tty_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    tty_proc.terminate()
                    tty_proc.wait(timeout=2)
            assert tty_proc.stderr.read() == ""

        missing_cwd_requests = [
            {
                "jsonrpc": "2.0",
                "id": "missing-cwd-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-missing-cwd"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "start-missing-cwd",
                "method": "process/start",
                "params": {
                    "processId": "missing-cwd-proc",
                    "argv": ["/bin/echo", "hi"],
                    "cwd": str(temp_root / "missing-cwd"),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "start-missing-cwd-arg0",
                "method": "process/start",
                "params": {
                    "processId": "missing-cwd-arg0-proc",
                    "argv": ["/bin/echo", "hi"],
                    "cwd": str(temp_root / "missing-cwd"),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": "missing-cwd-zero",
                },
            },
        ]
        missing_cwd_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in missing_cwd_requests)
        missing_cwd_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=missing_cwd_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert missing_cwd_result.stderr == ""
        missing_cwd_responses = [json.loads(line) for line in missing_cwd_result.stdout.splitlines()]
        assert len(missing_cwd_responses) == 3
        missing_cwd = missing_cwd_responses[1]
        assert missing_cwd["id"] == "start-missing-cwd"
        assert missing_cwd["error"]["code"] == -32603
        assert "failed to start process missing-cwd-proc: FileNotFound" in missing_cwd["error"]["message"]
        missing_cwd_arg0 = missing_cwd_responses[2]
        assert missing_cwd_arg0["id"] == "start-missing-cwd-arg0"
        assert missing_cwd_arg0["error"]["code"] == -32603
        assert "failed to start process missing-cwd-arg0-proc: FileNotFound" in missing_cwd_arg0["error"]["message"]

        final_read_requests = [
            {
                "jsonrpc": "2.0",
                "id": "final-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-final-read"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "start-final",
                "method": "process/start",
                "params": {
                    "processId": "final-proc",
                    "argv": ["/bin/sh", "-c", "sleep 1; printf ok"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-final",
                "method": "process/read",
                "params": {"processId": "final-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 2000},
            },
        ]
        final_read_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in final_read_requests)
        final_read_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=final_read_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert final_read_result.stderr == ""
        final_read_responses = [json.loads(line) for line in final_read_result.stdout.splitlines()]
        assert len(final_read_responses) == 3
        final_read = final_read_responses[2]
        assert final_read["id"] == "read-final"
        final_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in final_read["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert final_output == b"ok"

        disconnect_pid_file = temp_root / "disconnect-child.pid"
        disconnect = subprocess.Popen(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert disconnect.stdin is not None
        assert disconnect.stdout is not None

        def write_disconnect(message: dict[str, object]) -> None:
            assert disconnect.stdin is not None
            disconnect.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            disconnect.stdin.flush()

        write_disconnect(
            {
                "jsonrpc": "2.0",
                "id": "disconnect-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-disconnect"},
            }
        )
        write_disconnect({"jsonrpc": "2.0", "method": "initialized"})
        write_disconnect(
            {
                "jsonrpc": "2.0",
                "id": "disconnect-start",
                "method": "process/start",
                "params": {
                    "processId": "disconnect-proc",
                    "argv": [
                        "/bin/sh",
                        "-c",
                        f"printf '%s\\n' \"$$\" > {shlex.quote(str(disconnect_pid_file))}; sleep 30",
                    ],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            }
        )
        disconnect_init = json.loads(disconnect.stdout.readline())
        assert disconnect_init["id"] == "disconnect-init"
        disconnect_start = json.loads(disconnect.stdout.readline())
        assert disconnect_start["id"] == "disconnect-start"
        for _ in range(50):
            if disconnect_pid_file.exists():
                break
            time.sleep(0.05)
        assert disconnect_pid_file.exists()
        disconnect_child_pid = int(disconnect_pid_file.read_text(encoding="utf-8").strip())
        write_disconnect(
            {
                "jsonrpc": "2.0",
                "id": "disconnect-read",
                "method": "process/read",
                "params": {"processId": "disconnect-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 5000},
            }
        )
        disconnect.stdout.close()
        disconnect.stdout = None
        disconnect.stdin.close()
        disconnect.stdin = None
        disconnected_at = time.monotonic()
        disconnect.wait(timeout=2)
        assert time.monotonic() - disconnected_at < 2
        disconnect_stderr = disconnect.stderr.read() if disconnect.stderr is not None else ""
        assert disconnect_stderr == ""
        time.sleep(0.2)
        if process_exists(disconnect_child_pid):
            os.kill(disconnect_child_pid, signal.SIGKILL)
            raise AssertionError("exec-server disconnect left a child process alive")

        argv0_requests = [
            {
                "jsonrpc": "2.0",
                "id": "argv0-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-argv0"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "start-argv0",
                "method": "process/start",
                "params": {
                    "processId": "argv0-proc",
                    "argv": ["sh", "-c", 'printf "%s" "$0"'],
                    "cwd": str(temp_root),
                    "env": {"PATH": "/bin:/usr/bin"},
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-argv0",
                "method": "process/read",
                "params": {"processId": "argv0-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
        ]
        argv0_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in argv0_requests)
        argv0_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=argv0_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert argv0_result.stderr == ""
        argv0_responses = [json.loads(line) for line in argv0_result.stdout.splitlines()]
        assert len(argv0_responses) == 3
        argv0_read = argv0_responses[2]
        assert argv0_read["id"] == "read-argv0"
        argv0_output = b"".join(
            base64.b64decode(chunk["chunk"])
            for chunk in argv0_read["result"]["chunks"]
            if chunk["stream"] == "stdout"
        )
        assert argv0_output == b"sh"

        silent_requests = [
            {
                "jsonrpc": "2.0",
                "id": "silent-init",
                "method": "initialize",
                "params": {"clientName": "cli-smoke-silent"},
            },
            {"jsonrpc": "2.0", "method": "initialized"},
            {
                "jsonrpc": "2.0",
                "id": "start-silent",
                "method": "process/start",
                "params": {
                    "processId": "silent-proc",
                    "argv": ["/bin/sh", "-c", "exec >/dev/null 2>&1; sleep 0.2"],
                    "cwd": str(temp_root),
                    "env": shell_env,
                    "tty": False,
                    "pipeStdin": False,
                    "arg0": None,
                },
            },
            {
                "jsonrpc": "2.0",
                "id": "read-silent",
                "method": "process/read",
                "params": {"processId": "silent-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
            },
        ]
        silent_payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in silent_requests)
        silent_result = subprocess.run(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            input=silent_payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert silent_result.stderr == ""
        silent_responses = [json.loads(line) for line in silent_result.stdout.splitlines()]
        assert len(silent_responses) == 3
        silent_read = silent_responses[2]
        assert silent_read["id"] == "read-silent"
        assert silent_read["result"]["chunks"] == []
        assert silent_read["result"]["exited"] is True
        assert silent_read["result"]["closed"] is True

        teardown_child_pid: Optional[int] = None
        interactive = subprocess.Popen(
            [str(binary.resolve()), "exec-server", "--listen", "stdio"],
            cwd=temp_root,
            env=env,
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert interactive.stdin is not None
            assert interactive.stdout is not None

            def read_interactive_response(timeout: float = 2.0) -> dict:
                assert interactive.stdout is not None
                ready, _, _ = select.select([interactive.stdout], [], [], timeout)
                if not ready:
                    raise AssertionError("timed out waiting for exec-server RPC response")
                line = interactive.stdout.readline()
                if not line:
                    raise AssertionError("exec-server closed before RPC response")
                return json.loads(line)

            def rpc(message: dict) -> dict:
                interactive.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
                interactive.stdin.flush()
                return read_interactive_response()

            assert rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "interactive-init",
                    "method": "initialize",
                    "params": {"clientName": "cli-smoke-interactive"},
                }
            )["result"]["sessionId"]
            start_before_initialized = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "start-before-initialized",
                    "method": "process/start",
                    "params": {
                        "processId": "start-before-initialized-proc",
                        "argv": ["/bin/sh", "-c", "true"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert start_before_initialized["error"]["code"] == -32600
            assert "initialized notification" in start_before_initialized["error"]["message"]
            interactive.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized"}) + "\n")
            interactive.stdin.flush()

            nul_env_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "nul-env-start",
                    "method": "process/start",
                    "params": {
                        "processId": "nul-env-proc",
                        "argv": ["/usr/bin/env"],
                        "cwd": str(temp_root),
                        "env": {"NUL_VALUE": "before\0after"},
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert nul_env_start["error"]["code"] == -32602
            assert "env values must be strings without NUL" in nul_env_start["error"]["message"]

            nul_argv_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "nul-argv-start",
                    "method": "process/start",
                    "params": {
                        "processId": "nul-argv-proc",
                        "argv": ["/bin/sh", "-c", "printf bad\0arg"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert nul_argv_start["error"]["code"] == -32602

            nul_cwd_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "nul-cwd-start",
                    "method": "process/start",
                    "params": {
                        "processId": "nul-cwd-proc",
                        "argv": ["/bin/sh", "-c", "printf bad"],
                        "cwd": str(temp_root) + "\0suffix",
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert nul_cwd_start["error"]["code"] == -32602

            default_path_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "default-path-start",
                    "method": "process/start",
                    "params": {
                        "processId": "default-path-proc",
                        "argv": ["true"],
                        "cwd": str(temp_root),
                        "env": {},
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert default_path_start["result"]["processId"] == "default-path-proc"
            default_path_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "default-path-read",
                    "method": "process/read",
                    "params": {"processId": "default-path-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 500},
                }
            )
            assert default_path_read["result"]["exited"] is True
            assert default_path_read["result"]["closed"] is True

            invalid_env_policy_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "invalid-env-policy-start",
                    "method": "process/start",
                    "params": {
                        "processId": "invalid-env-policy-proc",
                        "argv": ["/bin/sh", "-c", "printf bad"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "envPolicy": {"inherit": "all"},
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert invalid_env_policy_start["error"]["code"] == -32602
            assert "envPolicy must include inherit" in invalid_env_policy_start["error"]["message"]

            env_policy_script = (
                "import json, os; "
                "keys = ["
                "'EXEC_SERVER_POLICY_PARENT', "
                "'EXEC_SERVER_POLICY_SECRET_TOKEN', "
                "'POLICY_SET', "
                "'OVERLAY_ME', "
                "'REQUEST_ONLY', "
                "'PATH'"
                "]; "
                "print(json.dumps({key: os.environ.get(key) for key in keys}, sort_keys=True), flush=True)"
            )
            env_policy_start = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "env-policy-start",
                    "method": "process/start",
                    "params": {
                        "processId": "env-policy-proc",
                        "argv": [sys.executable, "-c", env_policy_script],
                        "cwd": str(temp_root),
                        "env": {"OVERLAY_ME": "request", "REQUEST_ONLY": "request"},
                        "envPolicy": {
                            "inherit": "all",
                            "ignoreDefaultExcludes": False,
                            "exclude": ["EXEC_SERVER_POLICY_PARENT"],
                            "set": {"POLICY_SET": "policy", "OVERLAY_ME": "policy"},
                            "includeOnly": ["PATH", "POLICY_*", "OVERLAY_*", "EXEC_SERVER_POLICY_*"],
                        },
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert env_policy_start["result"]["processId"] == "env-policy-proc"
            env_policy_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "env-policy-read",
                    "method": "process/read",
                    "params": {
                        "processId": "env-policy-proc",
                        "afterSeq": 0,
                        "maxBytes": 4096,
                        "waitMs": 1000,
                    },
                }
            )
            env_policy_output = b"".join(
                base64.b64decode(chunk["chunk"])
                for chunk in env_policy_read["result"]["chunks"]
                if chunk["stream"] == "stdout"
            )
            env_policy_values = json.loads(env_policy_output.decode("utf-8"))
            assert env_policy_values["EXEC_SERVER_POLICY_PARENT"] is None
            assert env_policy_values["EXEC_SERVER_POLICY_SECRET_TOKEN"] is None
            assert env_policy_values["POLICY_SET"] == "policy"
            assert env_policy_values["OVERLAY_ME"] == "request"
            assert env_policy_values["REQUEST_ONLY"] == "request"
            assert env_policy_values["PATH"]

            large_stdin_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "large-stdin-start",
                    "method": "process/start",
                    "params": {
                        "processId": "large-stdin-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            "import sys; data=sys.stdin.buffer.read(70000); print(len(data), flush=True)",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": True,
                        "arg0": None,
                    },
                }
            )
            assert large_stdin_started["result"]["processId"] == "large-stdin-proc"
            large_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "large-stdin-write",
                    "method": "process/write",
                    "params": {
                        "processId": "large-stdin-proc",
                        "chunk": base64.b64encode(b"x" * 70000).decode("ascii"),
                    },
                }
            )
            assert large_write["result"]["status"] == "accepted"
            large_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "large-stdin-read",
                    "method": "process/read",
                    "params": {"processId": "large-stdin-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            large_output = b"".join(
                base64.b64decode(chunk["chunk"])
                for chunk in large_read["result"]["chunks"]
                if chunk["stream"] == "stdout"
            )
            assert large_output == b"70000\n"

            queued_stdin_file = temp_root / "queued-stdin.txt"
            queued_stdin_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "queued-stdin-start",
                    "method": "process/start",
                    "params": {
                        "processId": "queued-stdin-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            (
                                "import pathlib, sys; "
                                "data=sys.stdin.buffer.read(70000); "
                                "line=sys.stdin.buffer.readline(); "
                                f"pathlib.Path({str(queued_stdin_file)!r}).write_text("
                                "'first:%d\\nsecond:%s' % (len(data), line.decode()), encoding='utf-8')"
                            ),
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": True,
                        "arg0": None,
                    },
                }
            )
            assert queued_stdin_started["result"]["processId"] == "queued-stdin-proc"
            queued_first_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "queued-stdin-write-1",
                    "method": "process/write",
                    "params": {
                        "processId": "queued-stdin-proc",
                        "chunk": base64.b64encode(b"x" * 70000).decode("ascii"),
                    },
                }
            )
            assert queued_first_write["result"]["status"] == "accepted"
            queued_second_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "queued-stdin-write-2",
                    "method": "process/write",
                    "params": {
                        "processId": "queued-stdin-proc",
                        "chunk": base64.b64encode(b"queued\n").decode("ascii"),
                    },
                }
            )
            assert queued_second_write["result"]["status"] == "accepted"
            for _ in range(50):
                if queued_stdin_file.exists():
                    break
                time.sleep(0.05)
            assert queued_stdin_file.read_text(encoding="utf-8") == "first:70000\nsecond:queued\n"

            no_output_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "no-output-start",
                    "method": "process/start",
                    "params": {
                        "processId": "no-output-proc",
                        "argv": ["/bin/sh", "-c", "true"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert no_output_started["result"]["processId"] == "no-output-proc"
            no_output_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "no-output-read",
                    "method": "process/read",
                    "params": {"processId": "no-output-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            assert no_output_read["result"]["closed"] is True
            assert no_output_read["result"]["nextSeq"] > 1

            for index in range(3):
                unreaped_start = rpc(
                    {
                        "jsonrpc": "2.0",
                        "id": f"unreaped-start-{index}",
                        "method": "process/start",
                        "params": {
                            "processId": f"unreaped-proc-{index}",
                            "argv": ["/bin/sh", "-c", "true"],
                            "cwd": str(temp_root),
                            "env": shell_env,
                            "tty": False,
                            "pipeStdin": False,
                            "arg0": None,
                        },
                    }
                )
                assert unreaped_start["result"]["processId"] == f"unreaped-proc-{index}"
            time.sleep(0.5)
            assert_no_zombie_children(interactive.pid)
            reused_after_idle_reap = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "unreaped-reuse",
                    "method": "process/start",
                    "params": {
                        "processId": "unreaped-proc-0",
                        "argv": ["/bin/sh", "-c", "true"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert reused_after_idle_reap["error"]["code"] == -32600
            assert "process unreaped-proc-0 already exists" in reused_after_idle_reap["error"]["message"]

            high_output_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "high-output-start",
                    "method": "process/start",
                    "params": {
                        "processId": "high-output-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            "import sys, time; sys.stdout.write('H' * 100000); sys.stdout.flush(); time.sleep(5)",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert high_output_started["result"]["processId"] == "high-output-proc"
            time.sleep(0.5)
            high_output_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "high-output-read",
                    "method": "process/read",
                    "params": {
                        "processId": "high-output-proc",
                        "afterSeq": 0,
                        "maxBytes": 200000,
                        "waitMs": 1000,
                    },
                }
            )
            high_output = b"".join(
                base64.b64decode(chunk["chunk"])
                for chunk in high_output_read["result"]["chunks"]
                if chunk["stream"] == "stdout"
            )
            assert high_output == b"H" * 100000
            assert high_output_read["result"]["closed"] is False
            high_output_stopped = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "high-output-stop",
                    "method": "process/terminate",
                    "params": {"processId": "high-output-proc"},
                }
            )
            assert high_output_stopped["result"]["running"] is True

            cap_process_count = 70
            for index in range(cap_process_count):
                capped_start = rpc(
                    {
                        "jsonrpc": "2.0",
                        "id": f"cap-start-{index}",
                        "method": "process/start",
                        "params": {
                            "processId": f"cap-proc-{index}",
                            "argv": ["/bin/sh", "-c", "true"],
                            "cwd": str(temp_root),
                            "env": shell_env,
                            "tty": False,
                            "pipeStdin": False,
                            "arg0": None,
                        },
                    }
                )
                assert capped_start["result"]["processId"] == f"cap-proc-{index}"
            for index in range(cap_process_count):
                capped_read = rpc(
                    {
                        "jsonrpc": "2.0",
                        "id": f"cap-read-{index}",
                        "method": "process/read",
                        "params": {
                            "processId": f"cap-proc-{index}",
                            "afterSeq": 0,
                            "maxBytes": 4096,
                            "waitMs": 1000,
                        },
                    }
                )
                if "error" in capped_read:
                    assert capped_read["error"]["code"] == -32600
                    assert f"unknown process id cap-proc-{index}" in capped_read["error"]["message"]
                else:
                    assert capped_read["result"]["closed"] is True
            capped_evicted = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "cap-read-evicted",
                    "method": "process/read",
                    "params": {"processId": "cap-proc-0", "afterSeq": 0, "maxBytes": 4096, "waitMs": 0},
                }
            )
            assert capped_evicted["error"]["code"] == -32600
            assert "unknown process id cap-proc-0" in capped_evicted["error"]["message"]

            long_read_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "long-read-start",
                    "method": "process/start",
                    "params": {
                        "processId": "long-read-proc",
                        "argv": ["/bin/sh", "-c", "sleep 5"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert long_read_started["result"]["processId"] == "long-read-proc"
            read_started_at = time.monotonic()
            interactive.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "long-read",
                        "method": "process/read",
                        "params": {"processId": "long-read-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 2000},
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            interactive.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "long-read-stop",
                        "method": "process/terminate",
                        "params": {"processId": "long-read-proc"},
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            interactive.stdin.flush()
            long_read_responses = [read_interactive_response() for _ in range(2)]
            assert time.monotonic() - read_started_at < 1.0
            assert {response["id"] for response in long_read_responses} == {"long-read", "long-read-stop"}
            long_read = next(response for response in long_read_responses if response["id"] == "long-read")
            long_read_stop = next(response for response in long_read_responses if response["id"] == "long-read-stop")
            assert long_read["result"]["chunks"] == []
            assert long_read["result"]["closed"] is False
            assert long_read_stop["result"]["running"] is True

            unrelated_read_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "unrelated-read-start",
                    "method": "process/start",
                    "params": {
                        "processId": "unrelated-read-proc",
                        "argv": ["/bin/sh", "-c", "sleep 5"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert unrelated_read_started["result"]["processId"] == "unrelated-read-proc"
            unrelated_started_at = time.monotonic()
            interactive.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "unrelated-read",
                        "method": "process/read",
                        "params": {
                            "processId": "unrelated-read-proc",
                            "afterSeq": 0,
                            "maxBytes": 4096,
                            "waitMs": 2000,
                        },
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            interactive.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "unrelated-start",
                        "method": "process/start",
                        "params": {
                            "processId": "unrelated-start-proc",
                            "argv": ["/bin/sh", "-c", "true"],
                            "cwd": str(temp_root),
                            "env": shell_env,
                            "tty": False,
                            "pipeStdin": False,
                            "arg0": None,
                        },
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            interactive.stdin.flush()
            unrelated_responses = [read_interactive_response() for _ in range(2)]
            assert time.monotonic() - unrelated_started_at < 1.0
            assert {response["id"] for response in unrelated_responses} == {"unrelated-read", "unrelated-start"}
            unrelated_stop = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "unrelated-read-stop",
                    "method": "process/terminate",
                    "params": {"processId": "unrelated-read-proc"},
                }
            )
            assert unrelated_stop["result"]["running"] is True

            blocked_write_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "blocked-write-start",
                    "method": "process/start",
                    "params": {
                        "processId": "blocked-write-proc",
                        "argv": ["/bin/sh", "-c", "sleep 5"],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": True,
                        "arg0": None,
                    },
                }
            )
            assert blocked_write_started["result"]["processId"] == "blocked-write-proc"
            blocked_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "blocked-write",
                    "method": "process/write",
                    "params": {
                        "processId": "blocked-write-proc",
                        "chunk": base64.b64encode(b"x" * 1024 * 1024).decode("ascii"),
                    },
                }
            )
            assert blocked_write["result"]["status"] == "accepted"
            blocked_second_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "blocked-write-queued",
                    "method": "process/write",
                    "params": {
                        "processId": "blocked-write-proc",
                        "chunk": base64.b64encode(b"queued").decode("ascii"),
                    },
                }
            )
            assert blocked_second_write["result"]["status"] == "accepted"
            blocked_overflow_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "blocked-write-overflow",
                    "method": "process/write",
                    "params": {
                        "processId": "blocked-write-proc",
                        "chunk": base64.b64encode(b"y" * (1024 * 1024 + 1)).decode("ascii"),
                    },
                }
            )
            assert blocked_overflow_write["error"]["code"] == -32603
            assert "stdin write queue is full" in blocked_overflow_write["error"]["message"]
            blocked_terminated = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "blocked-write-stop",
                    "method": "process/terminate",
                    "params": {"processId": "blocked-write-proc"},
                }
            )
            assert blocked_terminated["result"]["running"] is True

            descendant_stdin_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "descendant-stdin-start",
                    "method": "process/start",
                    "params": {
                        "processId": "descendant-stdin-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            (
                                "import subprocess, sys, time; "
                                "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], "
                                "stdin=sys.stdin); "
                                "time.sleep(0.2)"
                            ),
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": True,
                        "arg0": None,
                    },
                }
            )
            assert descendant_stdin_started["result"]["processId"] == "descendant-stdin-proc"
            descendant_stdin_write = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "descendant-stdin-write",
                    "method": "process/write",
                    "params": {
                        "processId": "descendant-stdin-proc",
                        "chunk": base64.b64encode(b"x" * 1024 * 1024).decode("ascii"),
                    },
                }
            )
            assert descendant_stdin_write["result"]["status"] == "accepted"
            time.sleep(0.4)
            descendant_read_started_at = time.monotonic()
            interactive.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": "descendant-stdin-read",
                        "method": "process/read",
                        "params": {
                            "processId": "descendant-stdin-proc",
                            "afterSeq": 0,
                            "maxBytes": 4096,
                            "waitMs": 500,
                        },
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            interactive.stdin.flush()
            descendant_read = read_interactive_response(timeout=1.0)
            assert time.monotonic() - descendant_read_started_at < 1.0
            assert descendant_read["result"]["exited"] is True
            assert descendant_read["result"]["closed"] is False
            descendant_stdin_stop = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "descendant-stdin-stop",
                    "method": "process/terminate",
                    "params": {"processId": "descendant-stdin-proc"},
                }
            )
            assert descendant_stdin_stop["result"]["running"] is True

            group_pid_file = temp_root / "process-group-child.pid"
            group_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "group-start",
                    "method": "process/start",
                    "params": {
                        "processId": "group-proc",
                        "argv": [
                            "/bin/sh",
                            "-c",
                            f"(trap '' TERM; sleep 30) & printf '%s\\n' \"$!\" > {shlex.quote(str(group_pid_file))}; wait",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert group_started["result"]["processId"] == "group-proc"
            for _ in range(50):
                if group_pid_file.exists():
                    break
                time.sleep(0.05)
            assert group_pid_file.exists()
            group_child_pid = int(group_pid_file.read_text(encoding="utf-8").strip())
            group_terminated = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "group-stop",
                    "method": "process/terminate",
                    "params": {"processId": "group-proc"},
                }
            )
            assert group_terminated["result"]["running"] is True
            time.sleep(0.2)
            if process_exists(group_child_pid):
                os.kill(group_child_pid, signal.SIGKILL)
                raise AssertionError("process/terminate left a child process alive")

            ignore_term_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "ignore-term-start",
                    "method": "process/start",
                    "params": {
                        "processId": "ignore-term-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            (
                                "import signal, sys, time; "
                                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                                "sys.stdout.write('ready\\n'); sys.stdout.flush(); "
                                "time.sleep(30)"
                            ),
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert ignore_term_started["result"]["processId"] == "ignore-term-proc"
            ignore_term_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "ignore-term-read",
                    "method": "process/read",
                    "params": {"processId": "ignore-term-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            ignore_term_output = b"".join(
                base64.b64decode(chunk["chunk"]) for chunk in ignore_term_read["result"]["chunks"]
            )
            assert ignore_term_output == b"ready\n"
            ignore_term_stop_started_at = time.monotonic()
            ignore_term_stopped = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "ignore-term-stop",
                    "method": "process/terminate",
                    "params": {"processId": "ignore-term-proc"},
                }
            )
            assert time.monotonic() - ignore_term_stop_started_at < 1.5
            assert ignore_term_stopped["result"]["running"] is True
            ignore_term_closed = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "ignore-term-closed",
                    "method": "process/read",
                    "params": {"processId": "ignore-term-proc", "afterSeq": 1, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            assert ignore_term_closed["result"]["closed"] is True
            assert ignore_term_closed["result"]["exitCode"] == -1

            redirected_pid_file = temp_root / "process-redirected-child.pid"
            redirected_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "redirected-start",
                    "method": "process/start",
                    "params": {
                        "processId": "redirected-proc",
                        "argv": [
                            "/bin/sh",
                            "-c",
                            f"(trap '' TERM; sleep 30) >/dev/null 2>&1 & printf '%s\\n' \"$!\" > {shlex.quote(str(redirected_pid_file))}; exit 0",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert redirected_started["result"]["processId"] == "redirected-proc"
            for _ in range(50):
                if redirected_pid_file.exists():
                    break
                time.sleep(0.05)
            assert redirected_pid_file.exists()
            redirected_child_pid = int(redirected_pid_file.read_text(encoding="utf-8").strip())
            redirected_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "redirected-read",
                    "method": "process/read",
                    "params": {"processId": "redirected-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 1000},
                }
            )
            assert redirected_read["result"]["exited"] is True
            assert redirected_read["result"]["closed"] is True
            time.sleep(0.2)
            if process_exists(redirected_child_pid):
                os.kill(redirected_child_pid, signal.SIGKILL)
                raise AssertionError("closed process session left a redirected child alive")

            started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "term-start",
                    "method": "process/start",
                    "params": {
                        "processId": "term-proc",
                        "argv": [
                            sys.executable,
                            "-c",
                            "import sys, time; sys.stdout.write('B' * 10000); sys.stdout.flush(); time.sleep(5)",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert started["result"]["processId"] == "term-proc"
            time.sleep(0.2)
            terminated = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "term-stop",
                    "method": "process/terminate",
                    "params": {"processId": "term-proc"},
                }
            )
            assert terminated["result"]["running"] is True
            read_after_terminate = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "term-read",
                    "method": "process/read",
                    "params": {"processId": "term-proc", "afterSeq": 0, "maxBytes": 20000, "waitMs": 0},
                }
            )
            terminated_output = b"".join(
                base64.b64decode(chunk["chunk"]) for chunk in read_after_terminate["result"]["chunks"]
            )
            assert terminated_output == b"B" * 10000
            assert read_after_terminate["result"]["closed"] is True
            assert read_after_terminate["result"]["exitCode"] == -1

            teardown_pid_file = temp_root / "process-teardown-child.pid"
            teardown_started = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "teardown-start",
                    "method": "process/start",
                    "params": {
                        "processId": "teardown-proc",
                        "argv": [
                            "/bin/sh",
                            "-c",
                            f"(trap '' TERM; sleep 30) & printf '%s\\n' \"$!\" > {shlex.quote(str(teardown_pid_file))}; exit 0",
                        ],
                        "cwd": str(temp_root),
                        "env": shell_env,
                        "tty": False,
                        "pipeStdin": False,
                        "arg0": None,
                    },
                }
            )
            assert teardown_started["result"]["processId"] == "teardown-proc"
            for _ in range(50):
                if teardown_pid_file.exists():
                    break
                time.sleep(0.05)
            assert teardown_pid_file.exists()
            teardown_child_pid = int(teardown_pid_file.read_text(encoding="utf-8").strip())
            teardown_read_started_at = time.monotonic()
            teardown_read = rpc(
                {
                    "jsonrpc": "2.0",
                    "id": "teardown-read",
                    "method": "process/read",
                    "params": {"processId": "teardown-proc", "afterSeq": 0, "maxBytes": 4096, "waitMs": 500},
                }
            )
            assert time.monotonic() - teardown_read_started_at < 1.0
            assert teardown_read["result"]["exited"] is True
            assert teardown_read["result"]["closed"] is False
        finally:
            if interactive.stdin is not None:
                interactive.stdin.close()
                interactive.stdin = None
            try:
                _, stderr = interactive.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                interactive.kill()
                _, stderr = interactive.communicate(timeout=5)
                raise AssertionError("exec-server did not exit after stdin closed")
            assert stderr == ""
            if teardown_child_pid is not None:
                time.sleep(0.2)
                if process_exists(teardown_child_pid):
                    os.kill(teardown_child_pid, signal.SIGKILL)
                    raise AssertionError("exec-server teardown left a child process alive")
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def run_app_command_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-app-command-", dir="/tmp"))
    try:
        home = temp_root / "home"
        fake_bin = temp_root / "bin"
        workspace = temp_root / "workspace"
        fake_app = home / "Applications" / "Codex.app"
        open_log = temp_root / "open-args.txt"
        home.mkdir()
        fake_bin.mkdir()
        workspace.mkdir()
        fake_app.mkdir(parents=True)
        fake_open = fake_bin / "open"
        fake_open.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$@\" > {shlex.quote(str(open_log))}\n",
            encoding="utf-8",
        )
        fake_open.chmod(0o755)

        help_result = subprocess.run(
            [str(binary.resolve()), "help", "app"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert help_result.stdout == ""
        assert "codex-zig app [PATH]" in help_result.stderr

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        env["CODEX_TEST_APP_OPEN_BIN"] = str(fake_open)
        result = subprocess.run(
            [str(binary.resolve()), "app", str(workspace)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(f"app command failed:\nstdout={result.stdout}\nstderr={result.stderr}")
        assert result.stdout == ""
        if "Opening Codex Desktop at " not in result.stderr:
            raise AssertionError(f"app command did not report opening desktop app:\n{result.stderr}")
        if "parsed but not implemented yet" in result.stderr:
            raise AssertionError(f"app command still used generic placeholder:\n{result.stderr}")

        open_args = open_log.read_text(encoding="utf-8").splitlines()
        assert open_args[0] == "-a", open_args
        assert open_args[1].endswith("/Codex.app"), open_args
        assert open_args[2] == str(workspace.resolve()), open_args
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def wait_for_json_file(path: Path, process: subprocess.Popen, timeout: float = 5.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return json.loads(path.read_text())
        if process.poll() is not None:
            stderr = process.stderr.read() if process.stderr else ""
            raise AssertionError(f"process exited before {path} appeared:\n{stderr}")
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}; process still running")


def wait_for_dump_files(dump_dir: Path, process: subprocess.Popen, expected_count: int, timeout: float = 5.0) -> tuple[list[Path], list[Path]]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        request_dumps = sorted(dump_dir.glob("*-request.json")) if dump_dir.exists() else []
        response_dumps = sorted(dump_dir.glob("*-response.json")) if dump_dir.exists() else []
        if len(request_dumps) == expected_count and len(response_dumps) == expected_count:
            return request_dumps, response_dumps
        if process.poll() is not None:
            stderr = process.stderr.read() if process.stderr else ""
            raise AssertionError(f"process exited before dump files appeared:\n{stderr}")
        time.sleep(0.05)
    existing = sorted(path.name for path in dump_dir.iterdir()) if dump_dir.exists() else []
    raise AssertionError(f"timed out waiting for dump files: {existing!r}")


def run_responses_api_proxy_smoke(binary: Path) -> None:
    help_result = subprocess.run(
        [str(binary), "help", "responses-api-proxy"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=True,
    )
    assert help_result.stdout == ""
    assert "codex-zig responses-api-proxy" in help_result.stderr

    with tempfile.TemporaryDirectory(prefix="codex-zig-responses-proxy.") as tmp:
        tmp_path = Path(tmp)
        upstream = ExecResponsesServer(("127.0.0.1", 0), ExecResponsesHandler)
        upstream.request_paths = []
        upstream.request_bodies = []
        upstream.request_headers = []
        upstream.response_statuses = []
        upstream.response_payloads = [b'{"ok":true}']
        upstream.response_chunks = []
        upstream.response_delays = []
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        try:
            upstream_url = f"http://127.0.0.1:{upstream.server_port}/upstream-responses"
            server_info = tmp_path / "server" / "info.json"
            dump_dir = tmp_path / "dumps"
            proxy = subprocess.Popen(
                [
                    str(binary),
                    "responses-api-proxy",
                    "--server-info",
                    str(server_info),
                    "--http-shutdown",
                    "--upstream-url",
                    upstream_url,
                    "--dump-dir",
                    str(dump_dir),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            assert proxy.stdin is not None
            proxy.stdin.write("sk-proxy_123\n")
            proxy.stdin.close()
            try:
                info = wait_for_json_file(server_info, proxy)
                port = info["port"]
                if not isinstance(port, int) or port <= 0:
                    raise AssertionError(f"invalid proxy port in server info: {info!r}")
                if not isinstance(info.get("pid"), int) or info["pid"] <= 0:
                    raise AssertionError(f"invalid proxy pid in server info: {info!r}")

                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/v1/responses",
                    data=b'{"model":"gpt-test","input":"hello"}',
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": "Bearer caller-token",
                        "Cookie": "session=caller-secret",
                        "X-Codex-Test": "proxy-smoke",
                    },
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=5) as response:
                    if response.status != 200:
                        raise AssertionError(f"unexpected proxy response status: {response.status}")
                    if response.read() != b'{"ok":true}':
                        raise AssertionError("unexpected proxy response body")

                if upstream.request_paths != ["/upstream-responses"]:
                    raise AssertionError(f"unexpected upstream paths: {upstream.request_paths!r}")
                if upstream.request_bodies != [{"model": "gpt-test", "input": "hello"}]:
                    raise AssertionError(f"unexpected upstream bodies: {upstream.request_bodies!r}")
                forwarded_auth = header_value(upstream.request_headers[0], "Authorization")
                if forwarded_auth != "Bearer sk-proxy_123":
                    raise AssertionError(f"proxy did not replace Authorization: {forwarded_auth!r}")
                if header_value(upstream.request_headers[0], "X-Codex-Test") != "proxy-smoke":
                    raise AssertionError(f"proxy did not forward custom headers: {upstream.request_headers[0]!r}")

                request_dumps, response_dumps = wait_for_dump_files(dump_dir, proxy, 1)
                request_dump = json.loads(request_dumps[0].read_text())
                response_dump = json.loads(response_dumps[0].read_text())
                if request_dump.get("method") != "POST" or request_dump.get("url") != "/v1/responses":
                    raise AssertionError(f"unexpected request dump route: {request_dump!r}")
                if request_dump.get("body") != {"model": "gpt-test", "input": "hello"}:
                    raise AssertionError(f"unexpected request dump body: {request_dump!r}")
                if dump_header_value(request_dump.get("headers", []), "Authorization") != "[REDACTED]":
                    raise AssertionError(f"request dump did not redact authorization: {request_dump!r}")
                if dump_header_value(request_dump.get("headers", []), "Cookie") != "[REDACTED]":
                    raise AssertionError(f"request dump did not redact cookie: {request_dump!r}")
                if response_dump.get("status") != 200:
                    raise AssertionError(f"unexpected response dump status: {response_dump!r}")
                if response_dump.get("body") != {"ok": True}:
                    raise AssertionError(f"unexpected response dump body: {response_dump!r}")

                first_chunk = b"data: first\n\n"
                second_chunk = b"data: second\n\n"
                upstream.response_chunks.append([(first_chunk, 1.5), (second_chunk, 0)])
                stream_request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/v1/responses",
                    data=b'{"model":"gpt-test","input":"stream"}',
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                stream_start = time.monotonic()
                with urllib.request.urlopen(stream_request, timeout=5) as response:
                    first = response.read(len(first_chunk))
                    first_elapsed = time.monotonic() - stream_start
                    if first != first_chunk:
                        raise AssertionError(f"unexpected first streamed chunk: {first!r}")
                    if first_elapsed > 1.0:
                        raise AssertionError(f"proxy buffered streamed response for {first_elapsed:.2f}s")
                    if response.read() != second_chunk:
                        raise AssertionError("unexpected remaining streamed response body")

                forbidden = urllib.request.Request(
                    f"http://127.0.0.1:{port}/not-responses",
                    data=b"{}",
                    method="POST",
                )
                try:
                    urllib.request.urlopen(forbidden, timeout=5)
                except urllib.error.HTTPError as error:
                    if error.code != 403:
                        raise AssertionError(f"unexpected forbidden status: {error.code}")
                else:
                    raise AssertionError("proxy accepted a non-/v1/responses request")

                with urllib.request.urlopen(f"http://127.0.0.1:{port}/shutdown", timeout=5) as response:
                    if response.status != 200:
                        raise AssertionError(f"unexpected shutdown status: {response.status}")
                proxy.wait(timeout=5)
                if proxy.returncode != 0:
                    stderr = proxy.stderr.read() if proxy.stderr else ""
                    raise AssertionError(f"proxy exited with {proxy.returncode}:\n{stderr}")
            finally:
                if proxy.poll() is None:
                    proxy.terminate()
                    proxy.wait(timeout=5)
        finally:
            upstream.shutdown()
            upstream.server_close()


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=repo,
        env=clean_git_env(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=True,
    )


def run_features_profile_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-cli-features-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)

        subprocess.run(
            [str(binary), "--profile", "work", "features", "enable", "goals"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        subprocess.run(
            [str(binary), "--profile", "work", "features", "disable", "shell_tool"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        profile_under_development = subprocess.run(
            [str(binary), "--profile", "work", "features", "enable", "code_mode"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert profile_under_development.stderr == ""

        contents = (codex_home / "config.toml").read_text(encoding="utf-8")
        assert "[profiles.\"work\".features]" in contents
        assert "goals = true" in contents
        assert "shell_tool = false" in contents
        assert "code_mode = true" in contents

        listed = subprocess.run(
            [str(binary), "--profile", "work", "features", "list"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        lines = listed.stdout.splitlines()
        assert any(line.startswith("goals ") and line.endswith(" true") for line in lines)
        assert any(line.startswith("shell_tool ") and line.endswith(" false") for line in lines)
        assert any(line.startswith("code_mode ") and line.endswith(" true") for line in lines)

        under_development = subprocess.run(
            [str(binary), "features", "enable", "code_mode"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "Enabled feature `code_mode` in config.toml." in under_development.stdout
        assert "Under-development features enabled: code_mode." in under_development.stderr

        subprocess.run(
            [str(binary), "features", "enable", "goals"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        subprocess.run(
            [str(binary), "features", "disable", "goals"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        contents = (codex_home / "config.toml").read_text(encoding="utf-8")
        assert "goals = false" not in contents

        subprocess.run(
            [str(binary), "features", "enable", "memory_tool"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        listed = subprocess.run(
            [str(binary), "features", "list"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        lines = listed.stdout.splitlines()
        assert any(line.startswith("memories ") and line.endswith(" true") for line in lines)
        contents = (codex_home / "config.toml").read_text(encoding="utf-8")
        assert "memory_tool = true" in contents

        listed = subprocess.run(
            [str(binary), "--disable", "collab", "features", "list"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        lines = listed.stdout.splitlines()
        assert any(line.startswith("multi_agent ") and line.endswith(" false") for line in lines)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_execpolicy_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-execpolicy-", dir="/tmp"))
    try:
        rules_path = temp_root / "policy.rules"
        rules_path.write_text(
            """
prefix_rule(
    pattern = ["git", "push"],
    decision = "forbidden",
    justification = "pushing is blocked in this repo",
)
network_rule(host = "API.GITHUB.COM:443", protocol = "https_connect", decision = "allow")
network_rule(host = "blocked.example.com", protocol = "https", decision = "deny")
""",
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(rules_path),
                "git",
                "push",
                "origin",
                "main",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert json.loads(result.stdout) == {
            "decision": "forbidden",
            "matchedRules": [
                {
                    "prefixRuleMatch": {
                        "matchedPrefix": ["git", "push"],
                        "decision": "forbidden",
                        "justification": "pushing is blocked in this repo",
                    }
                }
            ],
        }

        example_rules_path = temp_root / "examples.rules"
        example_rules_path.write_text(
            """
prefix_rule(
    pattern = ["git", "status"],
    match = [["git", "status"], "git 'status'"],
    not_match = [["git", "commit"], "git commit"],
)
""",
            encoding="utf-8",
        )
        example_result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(example_rules_path),
                "git",
                "status",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert json.loads(example_result.stdout) == {
            "decision": "allow",
            "matchedRules": [
                {
                    "prefixRuleMatch": {
                        "matchedPrefix": ["git", "status"],
                        "decision": "allow",
                    }
                }
            ],
        }

        resolved_rules_path = temp_root / "resolved.rules"
        resolved_rules_path.write_text(
            """
prefix_rule(pattern = ["git", "status"], decision = "prompt")
host_executable(name = "git", paths = ["/usr/bin/git"])
""",
            encoding="utf-8",
        )
        resolved_result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(resolved_rules_path),
                "--resolve-host-executables",
                "/usr/bin/git",
                "status",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert json.loads(resolved_result.stdout) == {
            "decision": "prompt",
            "matchedRules": [
                {
                    "prefixRuleMatch": {
                        "matchedPrefix": ["git", "status"],
                        "decision": "prompt",
                        "resolvedProgram": "/usr/bin/git",
                    }
                }
            ],
        }

        invalid_network_rules_path = temp_root / "invalid-network.rules"
        invalid_network_rules_path.write_text(
            """
network_rule(host = "*", protocol = "http", decision = "allow")
""",
            encoding="utf-8",
        )
        invalid_network_result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(invalid_network_rules_path),
                "curl",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert invalid_network_result.returncode != 0
        assert "WildcardNetworkRuleHost" in invalid_network_result.stderr

        invalid_example_rules_path = temp_root / "invalid-example.rules"
        invalid_example_rules_path.write_text(
            """
prefix_rule(pattern = ["git"], not_match = ["git status"])
""",
            encoding="utf-8",
        )
        invalid_example_result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(invalid_example_rules_path),
                "git",
                "status",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert invalid_example_result.returncode != 0
        assert "ExecPolicyExampleDidMatch" in invalid_example_result.stderr

        cross_rule_example_rules_path = temp_root / "cross-rule-example.rules"
        cross_rule_example_rules_path.write_text(
            """
prefix_rule(pattern = ["git", "commit"], match = [["git", "status"]])
prefix_rule(pattern = ["git", "status"])
""",
            encoding="utf-8",
        )
        cross_rule_example_result = subprocess.run(
            [
                str(binary),
                "execpolicy",
                "check",
                "--rules",
                str(cross_rule_example_rules_path),
                "git",
                "status",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert cross_rule_example_result.returncode != 0
        assert "ExecPolicyExampleDidNotMatch" in cross_rule_example_result.stderr

        help_result = subprocess.run(
            [str(binary), "help", "execpolicy"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "codex-zig execpolicy check --rules PATH" in help_result.stderr
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_review_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-review-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        help_result = subprocess.run(
            [str(binary), "exec", "review", "--help"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "codex-zig review --uncommitted" in help_result.stderr
        assert "--base BRANCH" in help_result.stderr

        exec_help_result = subprocess.run(
            [str(binary), "help", "exec"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "codex-zig exec [OPTIONS] review [REVIEW_OPTIONS]" in exec_help_result.stderr

        rejected = subprocess.run(
            [str(binary.resolve()), "exec", "review", "--uncommitted"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert rejected.returncode != 0
        assert "Not inside a trusted directory and --skip-git-repo-check was not specified." in rejected.stderr
        assert server.request_bodies == []

        repo = temp_root / "repo"
        repo.mkdir()
        git(repo, "init", "--quiet")
        (repo / "review.txt").write_text("new review target\n", encoding="utf-8")

        reviewed = subprocess.run(
            [str(binary.resolve()), "exec", "--cd", str(repo), "review", "--uncommitted"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert reviewed.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        prompt = server.request_bodies[0]["input"][-1]["content"][0]["text"]
        assert "Review the uncommitted changes below." in prompt
        assert "diff --git a/review.txt b/review.txt" in prompt
        assert "+new review target" in prompt
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_review_stdin_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-review-stdin-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        rejected = subprocess.run(
            [str(binary.resolve()), "review", "-"],
            cwd=temp_root,
            env=env,
            input="focus on public API regressions\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert rejected.returncode != 0
        assert "Not inside a trusted directory and --skip-git-repo-check was not specified." in rejected.stderr
        assert server.request_bodies == []

        repo = temp_root / "repo"
        repo.mkdir()
        git(repo, "init", "--quiet")

        reviewed = subprocess.run(
            [str(binary.resolve()), "review", "-"],
            cwd=repo,
            env=env,
            input="focus on public API regressions\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert reviewed.stdout == "stored reply\n"
        assert reviewed.stderr == "Reading review prompt from stdin...\n"
        assert len(server.request_bodies) == 1
        prompt = server.request_bodies[0]["input"][-1]["content"][0]["text"]
        assert "Review according to these instructions:" in prompt
        assert "focus on public API regressions" in prompt
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_equals_options_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-options-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        result = subprocess.run(
            [
                str(binary.resolve()),
                "exec",
                "--skip-git-repo-check",
                "--approval-policy=never",
                "--output-last-message=last.txt",
                "say",
                "hi",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert (temp_root / "last.txt").read_text(encoding="utf-8") == "stored reply"
        assert len(server.request_bodies) == 1
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "say hi"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_resume_option_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-resume-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        initial = subprocess.run(
            [
                str(binary.resolve()),
                "exec",
                "--skip-git-repo-check",
                "seed",
                "session",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert initial.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1

        resumed = subprocess.run(
            [
                str(binary.resolve()),
                "exec",
                "resume",
                "--last",
                "--skip-git-repo-check",
                "--model",
                "gpt-exec-resume",
                "-o",
                "resume-output.md",
                "continue",
                "please",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert resumed.stdout == "stored reply\n"
        assert (temp_root / "resume-output.md").read_text(encoding="utf-8") == "stored reply"
        assert len(server.request_bodies) == 2
        assert server.request_bodies[1]["model"] == "gpt-exec-resume"
        assert server.request_bodies[1]["input"][-1]["content"][0]["text"] == "continue please"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_stdin_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-stdin-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        stdin_only = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check"],
            cwd=temp_root,
            env=env,
            input="stdin only prompt",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert stdin_only.stdout == "stored reply\n"
        assert stdin_only.stderr == "Reading prompt from stdin...\n"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "stdin only prompt"

        prompt_with_context = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "summarize"],
            cwd=temp_root,
            env=env,
            input="extra context",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert prompt_with_context.stdout == "stored reply\n"
        assert prompt_with_context.stderr == "Reading additional input from stdin...\n"
        assert (
            server.request_bodies[1]["input"][-1]["content"][0]["text"]
            == "summarize\n\n<stdin>\nextra context\n</stdin>"
        )
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_env_key_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-env-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_provider_env_key_env(temp_root, base_url)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "provider", "auth"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_paths == ["/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-env"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "use provider auth"
        assert server.request_headers[0]["Authorization"] == "Bearer provider-token"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_wire_api_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-wire-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_provider_wire_api_env(temp_root, base_url, "responses")

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "provider", "wire"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_paths == ["/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-wire"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "use provider wire"

        invalid_root = temp_root / "invalid-wire"
        invalid_root.mkdir()
        invalid_env = make_exec_provider_wire_api_env(invalid_root, base_url, "chat")
        rejected = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "old", "wire"],
            cwd=temp_root,
            env=invalid_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert rejected.returncode != 0
        assert '`wire_api = "chat"` is no longer supported' in rejected.stderr
        assert len(server.request_bodies) == 1
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_headers_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-headers-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_provider_headers_env(temp_root, base_url)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "provider", "headers"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_paths == ["/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-headers"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "use provider headers"
        assert server.request_headers[0]["Authorization"] == "Bearer provider-token"
        assert server.request_headers[0]["X-Corp-Static"] == "static-value"
        assert server.request_headers[0]["X-Corp-Env"] == "env-header-value"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_query_params_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-query-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_provider_query_params_env(temp_root, base_url)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "provider", "query"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_paths == [
            "/custom/responses?api-version=2025-04-01-preview&deployment=codex-test"
        ]
        assert server.request_bodies[0]["model"] == "gpt-provider-query"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "use provider query"
        assert server.request_headers[0]["Authorization"] == "Bearer provider-token"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_command_auth_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-command-auth-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_provider_command_auth_env(temp_root, base_url)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "command", "auth"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_paths == ["/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-command"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "use command auth"
        assert server.request_headers[0]["Authorization"] == "Bearer command-token"

        inline_root = temp_root / "inline-auth"
        inline_root.mkdir()
        inline_env = make_exec_provider_command_auth_env(inline_root, base_url, inline_auth=True)
        inline_result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "inline", "command", "auth"],
            cwd=temp_root,
            env=inline_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert inline_result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 2
        assert server.request_paths == ["/responses", "/responses"]
        assert server.request_bodies[1]["model"] == "gpt-provider-command"
        assert server.request_bodies[1]["input"][-1]["content"][0]["text"] == "use inline command auth"
        assert server.request_headers[1]["Authorization"] == "Bearer command-token"

        conflict_root = temp_root / "conflict-auth"
        conflict_root.mkdir()
        conflict_env = make_exec_provider_command_auth_env(conflict_root, base_url, conflict_env_key=True)
        rejected = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "bad", "command", "auth"],
            cwd=temp_root,
            env=conflict_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert rejected.returncode != 0
        assert "provider command auth cannot be combined" in rejected.stderr
        assert len(server.request_bodies) == 2
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_command_auth_refresh_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-command-refresh-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    server.response_statuses = [401, 200]
    try:
        env = make_exec_provider_command_auth_refresh_env(temp_root, base_url)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "refresh", "command", "auth"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 2
        assert server.request_paths == ["/responses", "/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-command-refresh"
        assert server.request_bodies[1]["model"] == "gpt-provider-command-refresh"
        assert server.request_bodies[1]["input"][-1]["content"][0]["text"] == "refresh command auth"
        assert server.request_headers[0]["Authorization"] == "Bearer first-token"
        assert server.request_headers[1]["Authorization"] == "Bearer second-token"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_provider_command_auth_refresh_interval_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-provider-command-interval-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    server.response_payloads = [
        (
            b'data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call-1","name":"update_plan","arguments":"{\\"plan\\":[{\\"step\\":\\"wait\\",\\"status\\":\\"completed\\"}]}"}}\n\n'
            b"data: [DONE]\n\n"
        ),
        default_exec_response_payload(),
    ]
    server.response_delays = [1.1]
    try:
        env = make_exec_provider_command_auth_refresh_env(temp_root, base_url, refresh_interval_ms=1000)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "refresh", "before", "second", "request"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=True,
        )
        assert result.stdout == "stored reply\n"
        assert len(server.request_bodies) == 2
        assert server.request_paths == ["/responses", "/responses"]
        assert server.request_bodies[0]["model"] == "gpt-provider-command-refresh"
        assert server.request_bodies[1]["model"] == "gpt-provider-command-refresh"
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "refresh before second request"
        assert server.request_bodies[1]["input"][-1]["type"] == "function_call_output"
        assert server.request_headers[0]["Authorization"] == "Bearer first-token"
        assert server.request_headers[1]["Authorization"] == "Bearer second-token"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_mcp_resource_tools_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-mcp-resources-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    mcp_server, mcp_url = start_streamable_mcp_tool_server()
    server.response_payloads = [
        function_call_response_payload("call-resources", "list_mcp_resources", {}),
        function_call_response_payload("call-templates", "list_mcp_resource_templates", {"server": "docs"}),
        function_call_response_payload(
            "call-http-templates",
            "list_mcp_resource_templates",
            {"server": "remote-docs"},
        ),
        function_call_response_payload(
            "call-read",
            "read_mcp_resource",
            {"server": "docs", "uri": "file:///tmp/codex-resource.md"},
        ),
        function_call_response_payload(
            "call-http-read",
            "read_mcp_resource",
            {"server": "remote-docs", "uri": "https://remote.example/resource.md"},
        ),
        (
            b'data: {"type":"response.output_text.delta","delta":"resource done"}\n\n'
            b"data: [DONE]\n\n"
        ),
    ]
    codex_home = temp_root / "codex-home"
    server_path = temp_root / "resource_server.py"
    try:
        codex_home.mkdir()
        server_path.write_text(
            "\n".join(
                [
                    "import json",
                    "import sys",
                    "",
                    "def write(payload):",
                    "    sys.stdout.write(json.dumps(payload, separators=(',', ':')) + '\\n')",
                    "    sys.stdout.flush()",
                    "",
                    "for line in sys.stdin:",
                    "    if not line.strip():",
                    "        continue",
                    "    request = json.loads(line)",
                    "    method = request.get('method')",
                    "    if method == 'notifications/initialized':",
                    "        continue",
                    "    request_id = request.get('id')",
                    "    if method == 'initialize':",
                    "        write({",
                    "            'jsonrpc': '2.0',",
                    "            'id': request_id,",
                    "            'result': {",
                    "                'protocolVersion': '2025-03-26',",
                    "                'capabilities': {'tools': {}, 'resources': {}},",
                    "                'serverInfo': {'name': 'resource-smoke', 'version': '0.1.0'},",
                    "            },",
                    "        })",
                    "    elif method == 'tools/list':",
                    "        write({'jsonrpc': '2.0', 'id': request_id, 'result': {'tools': [], 'nextCursor': None}})",
                    "    elif method == 'resources/list':",
                    "        cursor = request.get('params', {}).get('cursor')",
                    "        if cursor == 'next':",
                    "            write({",
                    "                'jsonrpc': '2.0',",
                    "                'id': request_id,",
                    "                'result': {",
                    "                    'resources': [",
                    "                        {",
                    "                            'uri': 'file:///tmp/codex-resource-second.md',",
                    "                            'name': 'second-resource',",
                    "                            'mimeType': 'text/markdown',",
                    "                        }",
                    "                    ],",
                    "                    'nextCursor': None,",
                    "                },",
                    "            })",
                    "        else:",
                    "            write({",
                    "                'jsonrpc': '2.0',",
                    "                'id': request_id,",
                    "                'result': {",
                    "                    'resources': [",
                    "                        {",
                    "                            'uri': 'file:///tmp/codex-resource.md',",
                    "                            'name': 'primary-resource',",
                    "                            'description': 'Primary MCP resource.',",
                    "                            'mimeType': 'text/plain',",
                    "                        },",
                    "                        {'name': 'missing-uri'},",
                    "                    ],",
                    "                    'nextCursor': 'next',",
                    "                },",
                    "            })",
                    "    elif method == 'resources/templates/list':",
                    "        write({",
                    "            'jsonrpc': '2.0',",
                    "            'id': request_id,",
                    "            'result': {",
                    "                'resourceTemplates': [",
                    "                    {",
                    "                        'uriTemplate': 'file:///tmp/{name}.md',",
                    "                        'name': 'file-template',",
                    "                        'description': 'File template.',",
                    "                    },",
                    "                    {'name': 'missing-template'},",
                    "                ],",
                    "                'nextCursor': None,",
                    "            },",
                    "        })",
                    "    elif method == 'resources/read':",
                    "        uri = request.get('params', {}).get('uri')",
                    "        write({",
                    "            'jsonrpc': '2.0',",
                    "            'id': request_id,",
                    "            'result': {",
                    "                'contents': [",
                    "                    {",
                    "                        'uri': uri,",
                    "                        'mimeType': 'text/plain',",
                    "                        'text': 'resource body',",
                    "                    }",
                    "                ]",
                    "            },",
                    "        })",
                    "    else:",
                    "        write({",
                    "            'jsonrpc': '2.0',",
                    "            'id': request_id,",
                    "            'error': {'code': -32601, 'message': f'unknown method: {method}'},",
                    "        })",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    'model = "gpt-mcp-resources"',
                    f'openai_base_url = "{base_url}"',
                    "",
                    "[mcp_servers.docs]",
                    f"command = {json.dumps(sys.executable)}",
                    f"args = [{json.dumps(str(server_path))}]",
                    "",
                    "[mcp_servers.remote-docs]",
                    f"url = {json.dumps(mcp_url)}",
                    'bearer_token_env_var = "RESOURCE_HTTP_MCP_TOKEN"',
                    "",
                    "[mcp_servers.remote-docs.http_headers]",
                    '"X-Resource-Static" = "resource-static"',
                    "",
                    "[mcp_servers.remote-docs.env_http_headers]",
                    '"X-Resource-Env" = "RESOURCE_HTTP_MCP_HEADER"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["OPENAI_API_KEY"] = "test-api-key"
        env["RESOURCE_HTTP_MCP_TOKEN"] = "resource-http-token"
        env["RESOURCE_HTTP_MCP_HEADER"] = "resource-env"
        env.pop("CODEX_ACCESS_TOKEN", None)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "mcp", "resources"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=True,
        )
        assert result.stdout == "resource done\n"
        assert len(server.request_bodies) == 6
        first_tools = {tool.get("name") for tool in server.request_bodies[0]["tools"] if tool.get("type") == "function"}
        assert "list_mcp_resources" in first_tools
        assert "list_mcp_resource_templates" in first_tools
        assert "read_mcp_resource" in first_tools

        resources_output = json.loads(server.request_bodies[1]["input"][-1]["output"])
        assert resources_output["resources"] == [
            {
                "server": "docs",
                "uri": "file:///tmp/codex-resource.md",
                "name": "primary-resource",
                "description": "Primary MCP resource.",
                "mimeType": "text/plain",
            },
            {
                "server": "docs",
                "uri": "file:///tmp/codex-resource-second.md",
                "name": "second-resource",
                "mimeType": "text/markdown",
            },
            {
                "server": "remote-docs",
                "uri": "https://remote.example/resource.md",
                "name": "remote-resource",
                "description": "Remote MCP resource.",
                "mimeType": "text/markdown",
            },
        ]

        templates_output = json.loads(server.request_bodies[2]["input"][-1]["output"])
        assert templates_output == {
            "server": "docs",
            "resourceTemplates": [
                {
                    "server": "docs",
                    "uriTemplate": "file:///tmp/{name}.md",
                    "name": "file-template",
                    "description": "File template.",
                }
            ],
        }

        http_templates_output = json.loads(server.request_bodies[3]["input"][-1]["output"])
        assert http_templates_output == {
            "server": "remote-docs",
            "resourceTemplates": [
                {
                    "server": "remote-docs",
                    "uriTemplate": "https://remote.example/{slug}.md",
                    "name": "remote-template",
                    "description": "Remote MCP template.",
                }
            ],
        }

        read_output = json.loads(server.request_bodies[4]["input"][-1]["output"])
        assert read_output == {
            "server": "docs",
            "uri": "file:///tmp/codex-resource.md",
            "contents": [
                {
                    "uri": "file:///tmp/codex-resource.md",
                    "mimeType": "text/plain",
                    "text": "resource body",
                }
            ],
        }

        http_read_output = json.loads(server.request_bodies[5]["input"][-1]["output"])
        assert http_read_output == {
            "server": "remote-docs",
            "uri": "https://remote.example/resource.md",
            "contents": [
                {
                    "uri": "https://remote.example/resource.md",
                    "mimeType": "text/markdown",
                    "text": "remote resource body",
                }
            ],
        }
        assert [request["method"] for request in mcp_server.request_bodies] == [
            "initialize",
            "notifications/initialized",
            "tools/list",
            "DELETE",
            "initialize",
            "notifications/initialized",
            "resources/list",
            "DELETE",
            "initialize",
            "notifications/initialized",
            "resources/templates/list",
            "DELETE",
            "initialize",
            "notifications/initialized",
            "resources/read",
            "DELETE",
        ]
        for index in (0, 4, 8, 12):
            assert header_value(mcp_server.request_headers[index], "Mcp-Session-Id") is None
        for index in (1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15):
            assert (
                header_value(mcp_server.request_headers[index], "Mcp-Session-Id")
                == "streamable-session-1"
            )
        assert mcp_server.request_headers[2]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[3]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[6]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[7]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[10]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[11]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[14]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[15]["Authorization"] == "Bearer resource-http-token"
        for headers in mcp_server.request_headers:
            assert header_value(headers, "X-Resource-Static") == "resource-static"
            assert header_value(headers, "X-Resource-Env") == "resource-env"
    finally:
        server.shutdown()
        server.server_close()
        mcp_server.shutdown()
        mcp_server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_streamable_http_mcp_tool_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-http-mcp-tool-", dir="/tmp"))
    responses_server, base_url = start_exec_responses_server()
    mcp_server, mcp_url = start_streamable_mcp_tool_server()
    responses_server.response_payloads = [
        function_call_response_payload(
            "call-http-tool",
            "mcp__remote_tools__echo",
            {"message": "hello from http mcp"},
        ),
        (
            b'data: {"type":"response.output_text.delta","delta":"http mcp done"}\n\n'
            b"data: [DONE]\n\n"
        ),
    ]
    codex_home = temp_root / "codex-home"
    try:
        codex_home.mkdir()
        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    'model = "gpt-http-mcp-tool"',
                    f'openai_base_url = "{base_url}"',
                    "",
                    "[mcp_servers.remote-tools]",
                    f"url = {json.dumps(mcp_url)}",
                    'bearer_token_env_var = "STREAMABLE_MCP_TOKEN"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["OPENAI_API_KEY"] = "test-api-key"
        env["STREAMABLE_MCP_TOKEN"] = "streamable-token"
        env.pop("CODEX_ACCESS_TOKEN", None)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "http", "mcp", "tool"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=True,
        )
        assert result.stdout == "http mcp done\n"
        assert len(responses_server.request_bodies) == 2
        first_tools = {
            tool.get("name")
            for tool in responses_server.request_bodies[0]["tools"]
            if tool.get("type") == "function"
        }
        assert "mcp__remote_tools__echo" in first_tools
        tool_output = responses_server.request_bodies[1]["input"][-1]["output"]
        assert tool_output == "http echo: hello from http mcp"

        assert [request["method"] for request in mcp_server.request_bodies] == [
            "initialize",
            "notifications/initialized",
            "tools/list",
            "DELETE",
            "initialize",
            "notifications/initialized",
            "tools/call",
            "DELETE",
        ]
        assert header_value(mcp_server.request_headers[0], "Mcp-Session-Id") is None
        assert header_value(mcp_server.request_headers[4], "Mcp-Session-Id") is None
        for index in (1, 2, 3, 5, 6, 7):
            assert (
                header_value(mcp_server.request_headers[index], "Mcp-Session-Id")
                == "streamable-session-1"
            )
        assert mcp_server.request_bodies[-2]["params"]["arguments"] == {
            "message": "hello from http mcp"
        }
        assert mcp_server.request_headers[2]["Authorization"] == "Bearer streamable-token"
        assert mcp_server.request_headers[3]["Authorization"] == "Bearer streamable-token"
        assert mcp_server.request_headers[-1]["Authorization"] == "Bearer streamable-token"
    finally:
        responses_server.shutdown()
        responses_server.server_close()
        mcp_server.shutdown()
        mcp_server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_streamable_http_mcp_get_stream_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-http-mcp-get-", dir="/tmp"))
    responses_server, base_url = start_exec_responses_server()
    mcp_server, mcp_url = start_streamable_mcp_tool_server()
    mcp_server.deferred_methods = {"tools/call"}
    responses_server.response_payloads = [
        function_call_response_payload(
            "call-http-tool",
            "mcp__remote_tools__echo",
            {"message": "hello from get stream"},
        ),
        (
            b'data: {"type":"response.output_text.delta","delta":"http mcp get done"}\n\n'
            b"data: [DONE]\n\n"
        ),
    ]
    codex_home = temp_root / "codex-home"
    try:
        codex_home.mkdir()
        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    'model = "gpt-http-mcp-get"',
                    f'openai_base_url = "{base_url}"',
                    "",
                    "[mcp_servers.remote-tools]",
                    f"url = {json.dumps(mcp_url)}",
                    'bearer_token_env_var = "STREAMABLE_MCP_TOKEN"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["OPENAI_API_KEY"] = "test-api-key"
        env["STREAMABLE_MCP_TOKEN"] = "streamable-token"
        env.pop("CODEX_ACCESS_TOKEN", None)

        result = subprocess.run(
            [str(binary.resolve()), "exec", "--skip-git-repo-check", "use", "http", "mcp", "tool"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=True,
        )
        assert result.stdout == "http mcp get done\n"
        assert len(responses_server.request_bodies) == 2
        tool_output = responses_server.request_bodies[1]["input"][-1]["output"]
        assert tool_output == "http echo: hello from get stream"

        assert [request["method"] for request in mcp_server.request_bodies] == [
            "initialize",
            "notifications/initialized",
            "tools/list",
            "DELETE",
            "initialize",
            "notifications/initialized",
            "tools/call",
            "GET",
            "DELETE",
        ]
        assert header_value(mcp_server.request_headers[0], "Mcp-Session-Id") is None
        assert header_value(mcp_server.request_headers[4], "Mcp-Session-Id") is None
        for index in (1, 2, 3, 5, 6, 7, 8):
            assert (
                header_value(mcp_server.request_headers[index], "Mcp-Session-Id")
                == "streamable-session-1"
            )
        assert mcp_server.request_bodies[6]["params"]["arguments"] == {
            "message": "hello from get stream"
        }
        assert header_value(mcp_server.request_headers[7], "Accept") == (
            "application/json, text/event-stream"
        )
        assert header_value(mcp_server.request_headers[7], "Authorization") == (
            "Bearer streamable-token"
        )
        assert header_value(mcp_server.request_headers[8], "Authorization") == (
            "Bearer streamable-token"
        )
    finally:
        responses_server.shutdown()
        responses_server.server_close()
        mcp_server.shutdown()
        mcp_server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def mcp_oauth_store_key(name: str, url: str) -> str:
    payload = json.dumps(
        {"headers": {}, "type": "http", "url": url},
        separators=(",", ":"),
        sort_keys=True,
    )
    return f"{name}|{hashlib.sha256(payload.encode()).hexdigest()[:16]}"


def has_macos_security() -> bool:
    return sys.platform == "darwin" and Path("/usr/bin/security").exists()


def cleanup_mcp_oauth_keyring_entry(account: str) -> None:
    subprocess.run(
        [
            "/usr/bin/security",
            "delete-generic-password",
            "-s",
            "Codex MCP Credentials",
            "-a",
            account,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )


def run_mcp_oauth_logout_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-mcp-oauth-", dir="/tmp"))
    discovery_server, remote_url = start_mcp_oauth_discovery_server()
    try:
        codex_home = temp_root / "codex-home"
        codex_home.mkdir()
        other_url = "https://other.example/mcp"
        remote_key = mcp_oauth_store_key("remote", remote_url)
        other_key = mcp_oauth_store_key("other", other_url)
        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    'mcp_oauth_credentials_store = "file"',
                    "",
                    "[mcp_servers.remote]",
                    f'url = "{remote_url}"',
                    'http_headers = { "X-Remote-Static" = "remote-static" }',
                    'env_http_headers = { "X-Remote-Env" = "REMOTE_HEADER_ENV" }',
                    "",
                    "[mcp_servers.bearer]",
                    'url = "https://bearer.example/mcp"',
                    'bearer_token_env_var = "MCP_TOKEN"',
                    "",
                    "[mcp_servers.docs]",
                    'command = "docs-server"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (codex_home / ".credentials.json").write_text(
            json.dumps(
                {
                    remote_key: {
                        "server_name": "remote",
                        "server_url": remote_url,
                        "client_id": "client",
                        "access_token": "access",
                    },
                    other_key: {
                        "server_name": "other",
                        "server_url": other_url,
                        "client_id": "client",
                        "access_token": "other",
                    },
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)

        listed = subprocess.run(
            [str(binary.resolve()), "mcp", "list", "--json"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        listed_entries = {entry["name"]: entry for entry in json.loads(listed.stdout)}
        assert listed_entries["remote"]["auth_status"] == "OAuth"
        assert listed_entries["remote"]["transport"]["http_headers"] == {
            "X-Remote-Static": "remote-static"
        }
        assert listed_entries["remote"]["transport"]["env_http_headers"] == {
            "X-Remote-Env": "REMOTE_HEADER_ENV"
        }
        assert listed_entries["bearer"]["auth_status"] == "BearerToken"
        assert listed_entries["docs"]["auth_status"] == "Unsupported"

        get_remote_json = subprocess.run(
            [str(binary.resolve()), "mcp", "get", "remote", "--json"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        remote_json = json.loads(get_remote_json.stdout)
        assert remote_json["transport"]["http_headers"] == {
            "X-Remote-Static": "remote-static"
        }
        assert remote_json["transport"]["env_http_headers"] == {
            "X-Remote-Env": "REMOTE_HEADER_ENV"
        }

        get_remote_text = subprocess.run(
            [str(binary.resolve()), "mcp", "get", "remote"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "http_headers: X-Remote-Static=*****" in get_remote_text.stdout
        assert "env_http_headers: X-Remote-Env=REMOTE_HEADER_ENV" in (
            get_remote_text.stdout
        )

        listed_text = subprocess.run(
            [str(binary.resolve()), "mcp", "list"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "remote\tstreamable_http\tenabled\tOAuth" in listed_text.stdout
        assert "bearer\tstreamable_http\tenabled\tBearer token" in listed_text.stdout
        assert "docs\tstdio\tenabled\tUnsupported" in listed_text.stdout

        missing_login = subprocess.run(
            [str(binary.resolve()), "mcp", "login", "missing"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert missing_login.returncode != 0
        assert "No MCP server named 'missing' found." in missing_login.stderr

        stdio_login = subprocess.run(
            [str(binary.resolve()), "mcp", "login", "docs"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert stdio_login.returncode != 0
        assert "OAuth login is only supported for streamable HTTP servers." in (
            stdio_login.stderr
        )

        invalid_scopes_login = subprocess.run(
            [str(binary.resolve()), "mcp", "login", "remote", "--scopes", "read,"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert invalid_scopes_login.returncode != 0
        assert "error: InvalidMcpOAuthScopes" in invalid_scopes_login.stderr

        remote_login = subprocess.run(
            [
                str(binary.resolve()),
                "mcp",
                "login",
                "remote",
                "--scopes",
                "read,write",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert remote_login.returncode != 0
        assert remote_login.stdout == (
            "MCP OAuth login is not implemented in the Zig port yet.\n"
        )
        assert "error: UnsupportedMcpOAuth" in remote_login.stderr

        removed = subprocess.run(
            [str(binary.resolve()), "mcp", "logout", "remote"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert removed.stdout == "Removed OAuth credentials for 'remote'.\n"
        assert removed.stderr == ""
        credentials = json.loads((codex_home / ".credentials.json").read_text(encoding="utf-8"))
        assert remote_key not in credentials
        assert other_key in credentials

        relisted = subprocess.run(
            [str(binary.resolve()), "mcp", "list", "--json"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        relisted_entries = {entry["name"]: entry for entry in json.loads(relisted.stdout)}
        assert relisted_entries["remote"]["auth_status"] == "NotLoggedIn"
        assert "/.well-known/oauth-authorization-server/mcp" in discovery_server.request_paths

        missing = subprocess.run(
            [str(binary.resolve()), "mcp", "logout", "remote"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert missing.stdout == "No OAuth credentials stored for 'remote'.\n"
        assert missing.stderr == ""

        stdio_logout = subprocess.run(
            [str(binary.resolve()), "mcp", "logout", "docs"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert stdio_logout.returncode != 0
        assert "error: McpOAuthLogoutRequiresHttp" in stdio_logout.stderr

        if has_macos_security():
            keyring_name = f"keyring_{time.time_ns()}"
            keyring_key = mcp_oauth_store_key(keyring_name, remote_url)
            cleanup_mcp_oauth_keyring_entry(keyring_key)
            try:
                subprocess.run(
                    [
                        "/usr/bin/security",
                        "add-generic-password",
                        "-U",
                        "-s",
                        "Codex MCP Credentials",
                        "-a",
                        keyring_key,
                        "-w",
                        "temporary-keyring-smoke-token",
                        "-T",
                        "/usr/bin/security",
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=True,
                )

                keyring_home = temp_root / "keyring-home"
                keyring_home.mkdir()
                (keyring_home / "config.toml").write_text(
                    "\n".join(
                        [
                            'mcp_oauth_credentials_store = "keyring"',
                            "",
                            f"[mcp_servers.{keyring_name}]",
                            f'url = "{remote_url}"',
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )
                (keyring_home / ".credentials.json").write_text(
                    json.dumps(
                        {
                            keyring_key: {
                                "server_name": keyring_name,
                                "server_url": remote_url,
                                "client_id": "client",
                                "access_token": "fallback",
                            }
                        },
                        separators=(",", ":"),
                    ),
                    encoding="utf-8",
                )

                keyring_env = os.environ.copy()
                keyring_env["CODEX_HOME"] = str(keyring_home)
                keyring_env.pop("OPENAI_API_KEY", None)
                keyring_env.pop("CODEX_ACCESS_TOKEN", None)

                keyring_list = subprocess.run(
                    [str(binary.resolve()), "mcp", "list", "--json"],
                    cwd=temp_root,
                    env=keyring_env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=True,
                )
                keyring_entries = {
                    entry["name"]: entry for entry in json.loads(keyring_list.stdout)
                }
                assert keyring_entries[keyring_name]["auth_status"] == "OAuth"

                keyring_removed = subprocess.run(
                    [str(binary.resolve()), "mcp", "logout", keyring_name],
                    cwd=temp_root,
                    env=keyring_env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=True,
                )
                assert keyring_removed.stdout == (
                    f"Removed OAuth credentials for '{keyring_name}'.\n"
                )
                assert keyring_removed.stderr == ""
                assert not (keyring_home / ".credentials.json").exists()

                keyring_find = subprocess.run(
                    [
                        "/usr/bin/security",
                        "find-generic-password",
                        "-s",
                        "Codex MCP Credentials",
                        "-a",
                        keyring_key,
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=False,
                )
                assert keyring_find.returncode == 44

                keyring_missing = subprocess.run(
                    [str(binary.resolve()), "mcp", "logout", keyring_name],
                    cwd=temp_root,
                    env=keyring_env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=True,
                )
                assert keyring_missing.stdout == (
                    f"No OAuth credentials stored for '{keyring_name}'.\n"
                )
                assert keyring_missing.stderr == ""
            finally:
                cleanup_mcp_oauth_keyring_entry(keyring_key)
    finally:
        discovery_server.shutdown()
        discovery_server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_exec_git_repo_check_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-exec-git-check-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        rejected = subprocess.run(
            [str(binary.resolve()), "exec", "say", "hi"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert rejected.returncode != 0
        assert "Not inside a trusted directory and --skip-git-repo-check was not specified." in rejected.stderr
        assert server.request_bodies == []

        bypassed = subprocess.run(
            [str(binary.resolve()), "exec", "--dangerously-bypass-approvals-and-sandbox", "say", "hi"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert bypassed.stdout == "stored reply\n"
        assert len(server.request_bodies) == 1
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "say hi"
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_yolo_approval_conflict_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-yolo-conflict-", dir="/tmp"))
    try:
        root = subprocess.run(
            [
                str(binary.resolve()),
                "--dangerously-bypass-approvals-and-sandbox",
                "--ask-for-approval",
                "never",
                "--help",
            ],
            cwd=temp_root,
            env=os.environ.copy(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert root.returncode != 0
        assert "error: ConflictingCliOptions" in root.stderr

        exec_result = subprocess.run(
            [
                str(binary.resolve()),
                "exec",
                "--dangerously-bypass-approvals-and-sandbox",
                "--approval-policy=never",
                "say",
                "hi",
            ],
            cwd=temp_root,
            env=os.environ.copy(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert exec_result.returncode != 0
        assert "error: ConflictingExecOptions" in exec_result.stderr
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def run_full_auto_compat_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-full-auto-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)

        root_result = subprocess.run(
            [str(binary.resolve()), "--full-auto"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert root_result.returncode != 0
        assert "error: UnknownCliOption" in root_result.stderr

        exec_result = subprocess.run(
            [
                str(binary.resolve()),
                "exec",
                "--skip-git-repo-check",
                "--full-auto",
                "say",
                "hi",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert exec_result.stdout == "stored reply\n"
        assert (
            "warning: `--full-auto` is deprecated; use `--sandbox workspace-write` instead."
            in exec_result.stderr
        )
        assert len(server.request_bodies) == 1
        assert server.request_bodies[0]["input"][-1]["content"][0]["text"] == "say hi"

        sandbox_full_auto = subprocess.run(
            [str(binary.resolve()), "sandbox", "linux", "--full-auto", "--"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert sandbox_full_auto.returncode != 0
        assert "error: UnknownSandboxOption" in sandbox_full_auto.stderr

        linux_unsupported = subprocess.run(
            [str(binary.resolve()), "sandbox", "landlock", "--", "/bin/echo", "ok"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert linux_unsupported.returncode != 0
        assert "error: LinuxSandboxUnsupported" in linux_unsupported.stderr

        windows_unsupported = subprocess.run(
            [str(binary.resolve()), "sandbox", "windows", "--", "/bin/echo", "ok"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert windows_unsupported.returncode != 0
        assert "error: WindowsSandboxUnsupported" in windows_unsupported.stderr
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_removed_top_level_command_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-removed-top-level-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_root / "codex-home")
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)

        for args in (
            ("marketplace", "add", "owner/repo"),
            ("marketplace", "upgrade", "debug"),
            ("marketplace", "remove", "debug"),
        ):
            result = subprocess.run(
                [str(binary.resolve()), *args],
                cwd=temp_root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
            assert result.returncode != 0
            assert result.stdout == ""
            assert "error: RemovedTopLevelCommand" in result.stderr
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def run_sandbox_permission_profile_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-sandbox-profile-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_root / "codex-home")
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)

        help_result = subprocess.run(
            [str(binary.resolve()), "sandbox", "macos", "--help"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert "--permissions-profile NAME" in help_result.stderr
        assert "--include-managed-config" in help_result.stderr
        assert ":read-only" in help_result.stderr
        assert ":workspace" in help_result.stderr
        assert ":danger-no-sandbox" in help_result.stderr
        assert "--allow-unix-socket PATH" in help_result.stderr
        assert "--log-denials" in help_result.stderr

        socket_unsupported = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--allow-unix-socket",
                str(temp_root / "codex-browser-use"),
                "--",
                "/bin/echo",
                "ok",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert socket_unsupported.returncode != 0
        assert socket_unsupported.stdout == ""
        assert "error: SandboxAllowUnixSocketUnsupported" in socket_unsupported.stderr

        denials_unsupported = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--log-denials",
                "--",
                "/bin/echo",
                "ok",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert denials_unsupported.returncode != 0
        assert denials_unsupported.stdout == ""
        assert "error: SandboxLogDenialsUnsupported" in denials_unsupported.stderr

        cwd_without_profile = subprocess.run(
            [str(binary.resolve()), "sandbox", "macos", "--cd", str(temp_root), "--", "/bin/echo", "ok"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert cwd_without_profile.returncode != 0
        assert "error: MissingSandboxPermissionsProfile" in cwd_without_profile.stderr

        managed_without_profile = subprocess.run(
            [str(binary.resolve()), "sandbox", "macos", "--include-managed-config", "--", "/bin/echo", "ok"],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert managed_without_profile.returncode != 0
        assert "error: MissingSandboxPermissionsProfile" in managed_without_profile.stderr

        workspace = temp_root / "workspace"
        outside = temp_root / "outside"
        workspace.mkdir()
        outside.mkdir()

        read_only_denied = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                ":read-only",
                "--cd",
                str(workspace),
                "--",
                "/bin/sh",
                "-c",
                "printf nope > blocked.txt",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert read_only_denied.returncode != 0
        assert not (workspace / "blocked.txt").exists()

        workspace_allowed = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                ":workspace",
                "--include-managed-config",
                "--cd",
                str(workspace),
                "--",
                "/bin/sh",
                "-c",
                f"printf ok > allowed.txt; printf nope > {outside / 'blocked.txt'}",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert workspace_allowed.returncode != 0
        assert (workspace / "allowed.txt").read_text(encoding="utf-8") == "ok"
        assert not (outside / "blocked.txt").exists()

        no_sandbox = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                ":danger-no-sandbox",
                "--cd",
                str(workspace),
                "--",
                "/bin/sh",
                "-c",
                f"printf ok > danger.txt; printf outside > {outside / 'danger.txt'}",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert no_sandbox.stdout == ""
        assert (workspace / "danger.txt").read_text(encoding="utf-8") == "ok"
        assert (outside / "danger.txt").read_text(encoding="utf-8") == "outside"

        extra = temp_root / "extra"
        extra.mkdir()
        codex_home = Path(env["CODEX_HOME"])
        codex_home.mkdir(parents=True, exist_ok=True)
        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    "[permissions.custom-profile.filesystem]",
                    '":root" = "read"',
                    '":project_roots" = "write"',
                    f"{json.dumps(str(extra))} = \"write\"",
                    "",
                    "[permissions.custom-profile.network]",
                    "enabled = true",
                    "",
                    "[permissions.no-network-profile.filesystem]",
                    '":root" = "read"',
                    '":project_roots" = "write"',
                    "",
                    "[permissions.no-network-profile.network]",
                    "enabled = false",
                    "",
                    "[permissions.minimal-profile.filesystem]",
                    '":minimal" = "read"',
                    "",
                    "[permissions.minimal-profile.network]",
                    "enabled = true",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        custom_profile = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                "custom-profile",
                "--cd",
                str(workspace),
                "--",
                "/bin/sh",
                "-c",
                f"printf ok > custom.txt; printf extra > {extra / 'custom.txt'}; printf nope > {outside / 'custom-blocked.txt'}",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert custom_profile.returncode != 0
        assert (workspace / "custom.txt").read_text(encoding="utf-8") == "ok"
        assert (extra / "custom.txt").read_text(encoding="utf-8") == "extra"
        assert not (outside / "custom-blocked.txt").exists()

        network_probe = (
            "import urllib.request; "
            f"print(urllib.request.urlopen({base_url!r}, timeout=2).read().decode().strip())"
        )
        network_allowed = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                "custom-profile",
                "--cd",
                str(workspace),
                "--",
                sys.executable,
                "-c",
                network_probe,
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert network_allowed.stdout == "ok\n"

        network_blocked = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                "no-network-profile",
                "--cd",
                str(workspace),
                "--",
                sys.executable,
                "-c",
                network_probe,
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert network_blocked.returncode != 0
        assert network_blocked.stdout == ""

        profile_unsupported = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                "minimal-profile",
                "--cd",
                str(workspace),
                "--",
                "/bin/echo",
                "ok",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        assert profile_unsupported.returncode != 0
        assert "error: SandboxPermissionProfileUnsupported" in profile_unsupported.stderr
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_debug_app_server_send_message_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-debug-app-server-", dir="/tmp"))
    server, base_url = start_exec_responses_server()
    try:
        env = make_exec_mock_env(temp_root, base_url)
        result = subprocess.run(
            [
                str(binary.resolve()),
                "debug",
                "app-server",
                "send-message-v2",
                "debug app-server smoke",
            ],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=True,
        )
        assert result.stderr == ""
        assert "< initialize response:" in result.stdout
        assert "< thread/start response:" in result.stdout
        assert "< turn/start response:" in result.stdout
        assert '"method":"turn/started"' in result.stdout
        assert '"method":"item/agentMessage/delta"' in result.stdout
        assert '"delta":"stored reply"' in result.stdout
        assert '"method":"turn/completed"' in result.stdout
        assert len(server.request_bodies) == 1
        assert (
            server.request_bodies[0]["input"][-1]["content"][0]["text"]
            == "debug app-server smoke"
        )
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(temp_root, ignore_errors=True)


def run_debug_trace_reduce_smoke(binary: Path) -> None:
    temp_root = Path(tempfile.mkdtemp(prefix="codex-zig-cli-trace-reduce-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_root / "codex-home")
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)

        bundle = temp_root / "trace-bundle"
        payloads = bundle / "payloads"
        payloads.mkdir(parents=True)
        (bundle / "manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "trace_id": "trace-1",
                    "rollout_id": "rollout-1",
                    "root_thread_id": "thread-root",
                    "started_at_unix_ms": 1000,
                    "raw_event_log": "trace.jsonl",
                    "payloads_dir": "payloads",
                }
            ),
            encoding="utf-8",
        )
        (payloads / "1.json").write_text(
            json.dumps({"agent_path": "/root", "nickname": "Root", "model": "gpt-test"}),
            encoding="utf-8",
        )
        (payloads / "2.json").write_text(
            json.dumps({"model": "gpt-test", "input": []}),
            encoding="utf-8",
        )
        (payloads / "3.json").write_text(
            json.dumps({"response_id": "resp-1", "output": []}),
            encoding="utf-8",
        )

        metadata_payload = {
            "raw_payload_id": "raw_payload:1",
            "kind": {"type": "session_metadata"},
            "path": "payloads/1.json",
        }
        request_payload = {
            "raw_payload_id": "raw_payload:2",
            "kind": {"type": "inference_request"},
            "path": "payloads/2.json",
        }
        response_payload = {
            "raw_payload_id": "raw_payload:3",
            "kind": {"type": "inference_response"},
            "path": "payloads/3.json",
        }
        events = [
            {
                "schema_version": 1,
                "seq": 1,
                "wall_time_unix_ms": 1000,
                "rollout_id": "rollout-1",
                "thread_id": None,
                "codex_turn_id": None,
                "payload": {"type": "rollout_started", "trace_id": "trace-1", "root_thread_id": "thread-root"},
            },
            {
                "schema_version": 1,
                "seq": 2,
                "wall_time_unix_ms": 1010,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": None,
                "payload": {
                    "type": "thread_started",
                    "thread_id": "thread-root",
                    "agent_path": "/root",
                    "metadata_payload": metadata_payload,
                },
            },
            {
                "schema_version": 1,
                "seq": 3,
                "wall_time_unix_ms": 1020,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": "turn-1",
                "payload": {
                    "type": "codex_turn_started",
                    "codex_turn_id": "turn-1",
                    "thread_id": "thread-root",
                },
            },
            {
                "schema_version": 1,
                "seq": 4,
                "wall_time_unix_ms": 1030,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": "turn-1",
                "payload": {
                    "type": "inference_started",
                    "inference_call_id": "inference-1",
                    "thread_id": "thread-root",
                    "codex_turn_id": "turn-1",
                    "model": "gpt-test",
                    "provider_name": "test-provider",
                    "request_payload": request_payload,
                },
            },
            {
                "schema_version": 1,
                "seq": 5,
                "wall_time_unix_ms": 1040,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": "turn-1",
                "payload": {
                    "type": "inference_completed",
                    "inference_call_id": "inference-1",
                    "response_id": "resp-1",
                    "upstream_request_id": "req-1",
                    "response_payload": response_payload,
                },
            },
            {
                "schema_version": 1,
                "seq": 6,
                "wall_time_unix_ms": 1050,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": "turn-1",
                "payload": {"type": "codex_turn_ended", "codex_turn_id": "turn-1", "status": "completed"},
            },
            {
                "schema_version": 1,
                "seq": 7,
                "wall_time_unix_ms": 1060,
                "rollout_id": "rollout-1",
                "thread_id": "thread-root",
                "codex_turn_id": None,
                "payload": {"type": "thread_ended", "thread_id": "thread-root", "status": "completed"},
            },
            {
                "schema_version": 1,
                "seq": 8,
                "wall_time_unix_ms": 1070,
                "rollout_id": "rollout-1",
                "thread_id": None,
                "codex_turn_id": None,
                "payload": {"type": "rollout_ended", "status": "completed"},
            },
        ]
        (bundle / "trace.jsonl").write_text(
            "".join(json.dumps(event) + "\n" for event in events),
            encoding="utf-8",
        )

        output = temp_root / "reduced.json"
        result = subprocess.run(
            [str(binary.resolve()), "debug", "trace-reduce", "--output", str(output), str(bundle)],
            cwd=temp_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        )
        assert result.stdout == f"{output}\n"
        assert result.stderr == ""

        state = json.loads(output.read_text(encoding="utf-8"))
        assert state["schema_version"] == 1
        assert state["trace_id"] == "trace-1"
        assert state["rollout_id"] == "rollout-1"
        assert state["status"] == "completed"
        assert state["ended_at_unix_ms"] == 1070
        assert state["root_thread_id"] == "thread-root"
        assert state["threads"]["thread-root"]["agent_path"] == "/root"
        assert state["threads"]["thread-root"]["nickname"] == "Root"
        assert state["threads"]["thread-root"]["default_model"] == "gpt-test"
        assert state["threads"]["thread-root"]["origin"] == {"type": "root"}
        assert state["threads"]["thread-root"]["execution"]["status"] == "completed"
        assert state["codex_turns"]["turn-1"]["thread_id"] == "thread-root"
        assert state["codex_turns"]["turn-1"]["execution"]["status"] == "completed"
        inference = state["inference_calls"]["inference-1"]
        assert inference["response_id"] == "resp-1"
        assert inference["upstream_request_id"] == "req-1"
        assert inference["raw_request_payload_id"] == "raw_payload:2"
        assert inference["raw_response_payload_id"] == "raw_payload:3"
        assert inference["execution"]["status"] == "completed"
        assert state["raw_payloads"]["raw_payload:1"]["kind"] == {"type": "session_metadata"}
        assert state["raw_payloads"]["raw_payload:2"]["path"] == "payloads/2.json"
        assert state["raw_payloads"]["raw_payload:3"]["kind"] == {"type": "inference_response"}
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_completion_snapshot_smoke(binary)
    run_update_command_smoke(binary)
    run_exec_server_stdio_smoke(binary)
    run_app_command_smoke(binary)
    run_responses_api_proxy_smoke(binary)
    run_features_profile_smoke(binary)
    run_execpolicy_smoke(binary)
    run_exec_review_smoke(binary)
    run_review_stdin_smoke(binary)
    run_exec_equals_options_smoke(binary)
    run_exec_resume_option_smoke(binary)
    run_exec_stdin_smoke(binary)
    run_exec_provider_env_key_smoke(binary)
    run_exec_provider_wire_api_smoke(binary)
    run_exec_provider_headers_smoke(binary)
    run_exec_provider_query_params_smoke(binary)
    run_exec_provider_command_auth_smoke(binary)
    run_exec_provider_command_auth_refresh_smoke(binary)
    run_exec_provider_command_auth_refresh_interval_smoke(binary)
    run_exec_mcp_resource_tools_smoke(binary)
    run_exec_streamable_http_mcp_tool_smoke(binary)
    run_exec_streamable_http_mcp_get_stream_smoke(binary)
    run_mcp_oauth_logout_smoke(binary)
    run_exec_git_repo_check_smoke(binary)
    run_yolo_approval_conflict_smoke(binary)
    run_full_auto_compat_smoke(binary)
    run_removed_top_level_command_smoke(binary)
    run_sandbox_permission_profile_smoke(binary)
    run_debug_app_server_send_message_smoke(binary)
    run_debug_trace_reduce_smoke(binary)
    print("cli-completion-snapshot-e2e: ok")
    print("cli-update-e2e: ok")
    print("cli-exec-server-stdio-e2e: ok")
    print("cli-app-command-e2e: ok")
    print("cli-responses-api-proxy-e2e: ok")
    print("cli-features-profile-e2e: ok")
    print("cli-execpolicy-e2e: ok")
    print("cli-exec-review-e2e: ok")
    print("cli-review-stdin-e2e: ok")
    print("cli-exec-options-e2e: ok")
    print("cli-exec-resume-options-e2e: ok")
    print("cli-exec-stdin-e2e: ok")
    print("cli-exec-provider-env-key-e2e: ok")
    print("cli-exec-provider-wire-api-e2e: ok")
    print("cli-exec-provider-headers-e2e: ok")
    print("cli-exec-provider-query-params-e2e: ok")
    print("cli-exec-provider-command-auth-e2e: ok")
    print("cli-exec-provider-command-auth-refresh-e2e: ok")
    print("cli-exec-provider-command-auth-refresh-interval-e2e: ok")
    print("cli-exec-mcp-resource-tools-e2e: ok")
    print("cli-exec-streamable-http-mcp-tool-e2e: ok")
    print("cli-exec-streamable-http-mcp-get-stream-e2e: ok")
    print("cli-mcp-oauth-logout-e2e: ok")
    print("cli-exec-git-check-e2e: ok")
    print("cli-yolo-approval-conflict-e2e: ok")
    print("cli-full-auto-compat-e2e: ok")
    print("cli-removed-top-level-e2e: ok")
    print("cli-sandbox-permission-profile-e2e: ok")
    print("cli-debug-app-server-send-message-e2e: ok")
    print("cli-debug-trace-reduce-e2e: ok")


if __name__ == "__main__":
    main()
