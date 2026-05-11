#!/usr/bin/env python3
import difflib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
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
            self.write_rpc(
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
            self.write_rpc(
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
            self.write_rpc(
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
            self.write_rpc(
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
            self.write_rpc(
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
            self.write_rpc(
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
        self.write_rpc(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unknown method: {method}"},
            }
        )

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
                ]
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["OPENAI_API_KEY"] = "test-api-key"
        env["RESOURCE_HTTP_MCP_TOKEN"] = "resource-http-token"
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
            "initialize",
            "notifications/initialized",
            "resources/list",
            "initialize",
            "notifications/initialized",
            "resources/templates/list",
            "initialize",
            "notifications/initialized",
            "resources/read",
        ]
        for index in (0, 3, 6, 9):
            assert header_value(mcp_server.request_headers[index], "Mcp-Session-Id") is None
        for index in (1, 2, 4, 5, 7, 8, 10, 11):
            assert (
                header_value(mcp_server.request_headers[index], "Mcp-Session-Id")
                == "streamable-session-1"
            )
        assert mcp_server.request_headers[2]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[5]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[8]["Authorization"] == "Bearer resource-http-token"
        assert mcp_server.request_headers[11]["Authorization"] == "Bearer resource-http-token"
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
            "initialize",
            "notifications/initialized",
            "tools/call",
        ]
        assert header_value(mcp_server.request_headers[0], "Mcp-Session-Id") is None
        assert header_value(mcp_server.request_headers[3], "Mcp-Session-Id") is None
        for index in (1, 2, 4, 5):
            assert (
                header_value(mcp_server.request_headers[index], "Mcp-Session-Id")
                == "streamable-session-1"
            )
        assert mcp_server.request_bodies[-1]["params"]["arguments"] == {
            "message": "hello from http mcp"
        }
        assert mcp_server.request_headers[2]["Authorization"] == "Bearer streamable-token"
        assert mcp_server.request_headers[-1]["Authorization"] == "Bearer streamable-token"
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
        assert listed_entries["bearer"]["auth_status"] == "BearerToken"
        assert listed_entries["docs"]["auth_status"] == "Unsupported"

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
    run_mcp_oauth_logout_smoke(binary)
    run_exec_git_repo_check_smoke(binary)
    run_yolo_approval_conflict_smoke(binary)
    run_full_auto_compat_smoke(binary)
    run_removed_top_level_command_smoke(binary)
    run_sandbox_permission_profile_smoke(binary)
    run_debug_trace_reduce_smoke(binary)
    print("cli-completion-snapshot-e2e: ok")
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
    print("cli-mcp-oauth-logout-e2e: ok")
    print("cli-exec-git-check-e2e: ok")
    print("cli-yolo-approval-conflict-e2e: ok")
    print("cli-full-auto-compat-e2e: ok")
    print("cli-removed-top-level-e2e: ok")
    print("cli-sandbox-permission-profile-e2e: ok")
    print("cli-debug-trace-reduce-e2e: ok")


if __name__ == "__main__":
    main()
