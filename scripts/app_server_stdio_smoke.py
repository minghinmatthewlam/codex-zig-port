#!/usr/bin/env python3
import base64
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_OMIT = object()


class RateLimitBackendHandler(BaseHTTPRequestHandler):
    requests: list[dict[str, object]] = []

    def do_GET(self) -> None:
        RateLimitBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
            }
        )
        if self.path != "/api/codex/usage":
            self.send_response(404)
            self.end_headers()
            return

        body = json.dumps(
            {
                "plan_type": "pro",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 42,
                        "limit_window_seconds": 300,
                        "reset_at": 123,
                    },
                    "secondary_window": {
                        "used_percent": 84,
                        "limit_window_seconds": 3600,
                        "reset_at": 456,
                    },
                },
                "additional_rate_limits": [
                    {
                        "limit_name": "codex_other",
                        "metered_feature": "codex_other",
                        "rate_limit": {
                            "primary_window": {
                                "used_percent": 70,
                                "limit_window_seconds": 900,
                                "reset_at": 789,
                            }
                        },
                    }
                ],
                "credits": {"has_credits": True, "unlimited": False, "balance": "9.99"},
                "rate_limit_reached_type": {"kind": "workspace_member_credits_depleted"},
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def read_json_line(proc: subprocess.Popen[str], timeout: float) -> dict:
    try:
        assert proc.stdout is not None
        line_queue: queue.Queue[str] = queue.Queue(maxsize=1)

        def read_line() -> None:
            line_queue.put(proc.stdout.readline())

        threading.Thread(target=read_line, daemon=True).start()
        line = line_queue.get(timeout=timeout)
    except queue.Empty:
        stderr = proc.stderr.read() if proc.poll() is not None else ""
        raise AssertionError(f"timed out waiting for app-server response\n{stderr}")

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


def request_stdio_app_server(binary: Path, payload: dict, env: dict[str, str]) -> dict:
    proc = subprocess.Popen(
        [str(binary), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        write_json_line(proc, payload)
        response = read_json_line(proc, 5)
        assert proc.stdin is not None
        proc.stdin.close()
        proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        return response
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def assert_empty_dir(path: Path) -> None:
    if not path.is_dir():
        raise AssertionError(f"expected directory to exist: {path}")
    entries = list(path.iterdir())
    if entries:
        raise AssertionError(f"expected empty directory {path}, saw {entries!r}")


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


def run_memory_reset_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-memory-", dir="/tmp"))
    try:
        memories = codex_home / "memories"
        rollout_summaries = memories / "rollout_summaries"
        extensions = codex_home / "memories_extensions"
        rollout_summaries.mkdir(parents=True)
        extensions.mkdir()
        (memories / "MEMORY.md").write_text("stale memory index\n")
        (rollout_summaries / "rollout.md").write_text("stale rollout\n")
        (extensions / "scratch.txt").write_text("stale extension\n")

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        response = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "memory-reset", "method": "memory/reset"},
            env,
        )
        assert response["id"] == "memory-reset"
        assert response["result"] == {}
        assert_empty_dir(memories)
        assert_empty_dir(extensions)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)

    state_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-memory-state-", dir="/tmp"))
    try:
        memories = state_home / "memories"
        memories.mkdir()
        memory_file = memories / "MEMORY.md"
        memory_file.write_text("keep until full reset is implemented\n")
        (state_home / "state_5.sqlite").write_text("placeholder\n")

        env = os.environ.copy()
        env["CODEX_HOME"] = str(state_home)
        response = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "state-db", "method": "memory/reset"},
            env,
        )
        assert response["id"] == "state-db"
        assert response["error"]["code"] == -32603
        assert "memory-state clearing is not implemented yet" in response["error"]["message"]
        assert memory_file.read_text() == "keep until full reset is implemented\n"
    finally:
        shutil.rmtree(state_home, ignore_errors=True)

    symlink_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-memory-symlink-", dir="/tmp"))
    try:
        target = symlink_home / "outside"
        target.mkdir()
        target_file = target / "keep.txt"
        target_file.write_text("keep\n")
        (symlink_home / "memories").symlink_to(target, target_is_directory=True)

        env = os.environ.copy()
        env["CODEX_HOME"] = str(symlink_home)
        response = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "symlink", "method": "memory/reset"},
            env,
        )
        assert response["id"] == "symlink"
        assert response["error"]["code"] == -32603
        assert "SymlinkedMemoryRoot" in response["error"]["message"]
        assert target_file.read_text() == "keep\n"
    finally:
        shutil.rmtree(symlink_home, ignore_errors=True)


def run_marketplace_rpc_smoke(binary: Path) -> None:
    env = os.environ.copy()

    cases = [
        {
            "jsonrpc": "2.0",
            "id": "marketplace-add",
            "method": "marketplace/add",
            "params": {
                "source": "owner/repo",
                "refName": "main",
                "sparsePaths": ["plugins/foo"],
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "marketplace-remove",
            "method": "marketplace/remove",
            "params": {"marketplaceName": "debug"},
        },
        {
            "jsonrpc": "2.0",
            "id": "marketplace-upgrade",
            "method": "marketplace/upgrade",
            "params": {"marketplaceName": None},
        },
    ]
    for payload in cases:
        response = request_stdio_app_server(binary, payload, env)
        assert response["id"] == payload["id"]
        assert response["error"]["code"] == -32603
        assert (
            f"app-server method {payload['method']} is parsed but not implemented yet"
            in response["error"]["message"]
        )

    invalid = request_stdio_app_server(
        binary,
        {
            "jsonrpc": "2.0",
            "id": "marketplace-add-invalid",
            "method": "marketplace/add",
            "params": {"refName": "main"},
        },
        env,
    )
    assert invalid["id"] == "marketplace-add-invalid"
    assert invalid["error"]["code"] == -32602


def run_plugin_rpc_smoke(binary: Path) -> None:
    env = os.environ.copy()
    cases = [
        {
            "jsonrpc": "2.0",
            "id": "plugin-list",
            "method": "plugin/list",
            "params": {
                "cwds": ["/tmp/repo"],
                "marketplaceKinds": ["local", "workspace-directory", "shared-with-me"],
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-read",
            "method": "plugin/read",
            "params": {
                "marketplacePath": "/tmp/marketplace.json",
                "remoteMarketplaceName": None,
                "pluginName": "gmail",
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-skill-read",
            "method": "plugin/skill/read",
            "params": {
                "remoteMarketplaceName": "chatgpt-global",
                "remotePluginId": "plugins~Plugin_00000000000000000000000000000000",
                "skillName": "plan-work",
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-share-save",
            "method": "plugin/share/save",
            "params": {
                "pluginPath": "/tmp/plugins/gmail",
                "remotePluginId": None,
                "discoverability": "PRIVATE",
                "shareTargets": [{"principalType": "user", "principalId": "user-1"}],
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-share-update",
            "method": "plugin/share/updateTargets",
            "params": {
                "remotePluginId": "plugins~Plugin_00000000000000000000000000000000",
                "shareTargets": [
                    {"principalType": "workspace", "principalId": "workspace-1"}
                ],
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-share-list",
            "method": "plugin/share/list",
            "params": {},
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-share-delete",
            "method": "plugin/share/delete",
            "params": {
                "remotePluginId": "plugins~Plugin_00000000000000000000000000000000"
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-install",
            "method": "plugin/install",
            "params": {"remoteMarketplaceName": "openai-curated", "pluginName": "gmail"},
        },
        {
            "jsonrpc": "2.0",
            "id": "plugin-uninstall",
            "method": "plugin/uninstall",
            "params": {"pluginId": "gmail@openai-curated"},
        },
    ]
    for payload in cases:
        response = request_stdio_app_server(binary, payload, env)
        assert response["id"] == payload["id"]
        assert response["error"]["code"] == -32603
        assert (
            f"app-server method {payload['method']} is parsed but not implemented yet"
            in response["error"]["message"]
        )

    invalid_read = request_stdio_app_server(
        binary,
        {
            "jsonrpc": "2.0",
            "id": "plugin-read-invalid",
            "method": "plugin/read",
            "params": {"marketplacePath": "/tmp/marketplace.json"},
        },
        env,
    )
    assert invalid_read["id"] == "plugin-read-invalid"
    assert invalid_read["error"]["code"] == -32602


def run_filesystem_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-fs-", dir="/tmp"))
    env = os.environ.copy()

    def rpc(request_id: str, method: str, params: dict) -> dict:
        return request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
            env,
        )

    try:
        nested_dir = root / "nested"
        file_path = nested_dir / "hello.txt"
        copied_file = root / "hello-copy.txt"
        copied_dir = root / "nested-copy"
        payload = b"hello from app-server fs"
        payload_base64 = base64.b64encode(payload).decode("ascii")

        created = rpc("fs-create", "fs/createDirectory", {"path": str(nested_dir)})
        assert created["id"] == "fs-create"
        assert created["result"] == {}
        assert nested_dir.is_dir()

        written = rpc(
            "fs-write",
            "fs/writeFile",
            {"path": str(file_path), "dataBase64": payload_base64},
        )
        assert written["id"] == "fs-write"
        assert written["result"] == {}
        assert file_path.read_bytes() == payload

        read = rpc("fs-read", "fs/readFile", {"path": str(file_path)})
        assert read["id"] == "fs-read"
        assert base64.b64decode(read["result"]["dataBase64"]) == payload

        metadata = rpc("fs-metadata", "fs/getMetadata", {"path": str(file_path)})
        assert metadata["id"] == "fs-metadata"
        assert metadata["result"]["isFile"] is True
        assert metadata["result"]["isDirectory"] is False
        assert metadata["result"]["isSymlink"] is False
        assert isinstance(metadata["result"]["createdAtMs"], int)
        assert metadata["result"]["modifiedAtMs"] > 0

        file_copy = rpc(
            "fs-copy-file",
            "fs/copy",
            {"sourcePath": str(file_path), "destinationPath": str(copied_file)},
        )
        assert file_copy["id"] == "fs-copy-file"
        assert file_copy["result"] == {}
        assert copied_file.read_bytes() == payload

        dir_copy = rpc(
            "fs-copy-dir",
            "fs/copy",
            {
                "sourcePath": str(nested_dir),
                "destinationPath": str(copied_dir),
                "recursive": True,
            },
        )
        assert dir_copy["id"] == "fs-copy-dir"
        assert dir_copy["result"] == {}
        assert (copied_dir / "hello.txt").read_bytes() == payload

        listed = rpc("fs-list", "fs/readDirectory", {"path": str(root)})
        assert listed["id"] == "fs-list"
        entries = {entry["fileName"]: entry for entry in listed["result"]["entries"]}
        assert entries["nested"]["isDirectory"] is True
        assert entries["hello-copy.txt"]["isFile"] is True
        assert entries["nested-copy"]["isDirectory"] is True

        removed = rpc("fs-remove", "fs/remove", {"path": str(copied_dir)})
        assert removed["id"] == "fs-remove"
        assert removed["result"] == {}
        assert not copied_dir.exists()

        missing_removed = rpc("fs-remove-missing", "fs/remove", {"path": str(copied_dir)})
        assert missing_removed["id"] == "fs-remove-missing"
        assert missing_removed["result"] == {}

        watch = rpc(
            "fs-watch",
            "fs/watch",
            {"watchId": "watch-1", "path": str(nested_dir)},
        )
        assert watch["id"] == "fs-watch"
        assert watch["error"]["code"] == -32603
        assert "fs/watch is parsed but not implemented yet" in watch["error"]["message"]

        unwatch = rpc("fs-unwatch", "fs/unwatch", {"watchId": "watch-1"})
        assert unwatch["id"] == "fs-unwatch"
        assert unwatch["error"]["code"] == -32603
        assert "fs/unwatch is parsed but not implemented yet" in unwatch["error"]["message"]

        relative = rpc("fs-relative", "fs/readFile", {"path": "relative.txt"})
        assert relative["id"] == "fs-relative"
        assert relative["error"]["code"] == -32602
        assert "AbsolutePathBuf deserialized without a base path" in relative["error"]["message"]

        invalid_base64 = rpc(
            "fs-invalid-base64",
            "fs/writeFile",
            {"path": str(file_path), "dataBase64": "not base64"},
        )
        assert invalid_base64["id"] == "fs-invalid-base64"
        assert invalid_base64["error"]["code"] == -32602
        assert "valid base64 dataBase64" in invalid_base64["error"]["message"]
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_model_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-model-", dir="/tmp"))

    def rpc(request_id: str, method: str, params: dict) -> dict:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        return request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
            env,
        )

    try:
        default_models = rpc("model-list-default", "model/list", {"limit": 1})
        assert default_models["id"] == "model-list-default"
        assert default_models["result"]["nextCursor"] is None
        assert len(default_models["result"]["data"]) == 1
        default_model = default_models["result"]["data"][0]
        assert default_model["id"] == "gpt-5.2-codex"
        assert default_model["model"] == "gpt-5.2-codex"
        assert default_model["isDefault"] is True
        assert default_model["hidden"] is False
        assert default_model["defaultReasoningEffort"] == "medium"
        assert default_model["inputModalities"] == ["text", "image"]

        default_capabilities = rpc(
            "model-capabilities-default",
            "modelProvider/capabilities/read",
            {},
        )
        assert default_capabilities["id"] == "model-capabilities-default"
        assert default_capabilities["result"] == {
            "namespaceTools": True,
            "imageGeneration": True,
            "webSearch": True,
        }

        (codex_home / "config.toml").write_text('model = "gpt-test"\n', encoding="utf-8")
        configured_models = rpc("model-list-configured", "model/list", {})
        assert configured_models["id"] == "model-list-configured"
        assert configured_models["result"]["data"][0]["model"] == "gpt-test"

        cursor_end = rpc("model-list-cursor-end", "model/list", {"cursor": "1"})
        assert cursor_end["id"] == "model-list-cursor-end"
        assert cursor_end["result"]["data"] == []
        assert cursor_end["result"]["nextCursor"] is None

        invalid_cursor = rpc("model-list-invalid-cursor", "model/list", {"cursor": "bad"})
        assert invalid_cursor["id"] == "model-list-invalid-cursor"
        assert invalid_cursor["error"]["code"] == -32600
        assert invalid_cursor["error"]["message"] == "invalid cursor: bad"

        (codex_home / "config.toml").write_text(
            'profile = "bedrock"\n[profiles.bedrock]\nmodel_provider = "amazon-bedrock"\n',
            encoding="utf-8",
        )
        bedrock_capabilities = rpc(
            "model-capabilities-bedrock",
            "modelProvider/capabilities/read",
            {},
        )
        assert bedrock_capabilities["id"] == "model-capabilities-bedrock"
        assert bedrock_capabilities["result"] == {
            "namespaceTools": False,
            "imageGeneration": False,
            "webSearch": False,
        }
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_config_read_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-config-", dir="/tmp"))
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-config"',
                'approval_policy = "never"',
                'sandbox_mode = "danger-full-access"',
                'web_search = "live"',
                'service_tier = "flex"',
                "",
                "[features]",
                "apps = false",
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    proc = subprocess.Popen(
        [str(binary), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

    def rpc(request_id: str, method: str, params: dict) -> dict:
        write_json_line(
            proc,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        )
        return read_json_line(proc, 5)

    def rpc_without_params(request_id: str, method: str) -> dict:
        write_json_line(proc, {"jsonrpc": "2.0", "id": request_id, "method": method})
        return read_json_line(proc, 5)

    try:
        config_read = rpc("config-read", "config/read", {"includeLayers": True, "cwd": str(codex_home)})
        assert config_read["id"] == "config-read"
        config_body = config_read["result"]["config"]
        assert config_body["model"] == "gpt-config"
        assert config_body["approval_policy"] == "never"
        assert config_body["sandbox_mode"] == "danger-full-access"
        assert config_body["web_search"] == "live"
        assert config_body["service_tier"] == "flex"
        assert config_body["features"]["apps"] is False
        assert config_body["features"]["memories"] is False
        assert config_read["result"]["origins"] == {}
        assert config_read["result"]["layers"] == []

        config_requirements = rpc_without_params(
            "config-requirements-read",
            "configRequirements/read",
        )
        assert config_requirements["id"] == "config-requirements-read"
        assert config_requirements["result"] == {"requirements": None}

        config_requirements_null = rpc(
            "config-requirements-read-null",
            "configRequirements/read",
            None,
        )
        assert config_requirements_null["id"] == "config-requirements-read-null"
        assert config_requirements_null["result"] == {"requirements": None}

        feature_enablement = rpc(
            "config-feature-enable",
            "experimentalFeature/enablement/set",
            {"enablement": {"apps": True, "memories": True}},
        )
        assert feature_enablement["id"] == "config-feature-enable"
        assert feature_enablement["result"]["enablement"] == {"apps": True, "memories": True}

        after_enablement = rpc("config-read-after-enable", "config/read", {})
        after_features = after_enablement["result"]["config"]["features"]
        assert after_features["apps"] is False
        assert after_features["memories"] is True
        assert after_enablement["result"]["layers"] is None

        invalid_params = rpc("config-read-invalid", "config/read", {"includeLayers": "yes"})
        assert invalid_params["id"] == "config-read-invalid"
        assert invalid_params["error"]["code"] == -32602

        invalid_requirements_params = rpc(
            "config-requirements-invalid",
            "configRequirements/read",
            {"includeLayers": True},
        )
        assert invalid_requirements_params["id"] == "config-requirements-invalid"
        assert invalid_requirements_params["error"]["code"] == -32602
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        shutil.rmtree(codex_home, ignore_errors=True)


def encode_unsigned_jwt(payload: dict) -> str:
    def encode(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")

    header = encode(json.dumps({"alg": "none", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    body = encode(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = encode(b"signature")
    return f"{header}.{body}.{signature}"


def start_rate_limit_backend() -> tuple[ThreadingHTTPServer, str]:
    RateLimitBackendHandler.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), RateLimitBackendHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


def run_account_read_rpc_smoke(binary: Path) -> None:
    def request(codex_home: Path, request_id: str, params_marker: object, extra_env: dict[str, str] | None = None) -> dict:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        if extra_env:
            env.update(extra_env)
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "account/read"}
        if params_marker is not _OMIT:
            payload["params"] = params_marker
        return request_stdio_app_server(binary, payload, env)

    no_auth_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-none-", dir="/tmp"))
    api_key_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-api-", dir="/tmp"))
    chatgpt_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-chatgpt-", dir="/tmp"))
    bedrock_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-bedrock-", dir="/tmp"))
    custom_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-custom-", dir="/tmp"))
    oss_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-oss-", dir="/tmp"))
    try:
        no_auth = request(no_auth_home, "account-no-auth", _OMIT)
        assert no_auth["id"] == "account-no-auth"
        assert no_auth["result"] == {"account": None, "requiresOpenaiAuth": True}

        api_key = request(api_key_home, "account-api-key", {}, {"OPENAI_API_KEY": "test-api-key"})
        assert api_key["id"] == "account-api-key"
        assert api_key["result"] == {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}

        id_token = encode_unsigned_jwt(
            {
                "email": "user@example.com",
                "https://api.openai.com/auth": {
                    "chatgpt_plan_type": "pro",
                    "chatgpt_account_id": "acct_123",
                },
            }
        )
        (chatgpt_home / "auth.json").write_text(
            json.dumps(
                {
                    "auth_mode": "chatgpt",
                    "tokens": {
                        "id_token": id_token,
                        "access_token": "chatgpt-access-token",
                        "refresh_token": "chatgpt-refresh-token",
                        "account_id": "acct_123",
                    },
                }
            ),
            encoding="utf-8",
        )
        chatgpt = request(chatgpt_home, "account-chatgpt", {"refreshToken": False})
        assert chatgpt["id"] == "account-chatgpt"
        assert chatgpt["result"] == {
            "account": {"type": "chatgpt", "email": "user@example.com", "planType": "pro"},
            "requiresOpenaiAuth": True,
        }

        (bedrock_home / "config.toml").write_text('model_provider = "amazon-bedrock"\n', encoding="utf-8")
        bedrock = request(bedrock_home, "account-bedrock", None)
        assert bedrock["id"] == "account-bedrock"
        assert bedrock["result"] == {
            "account": {"type": "amazonBedrock"},
            "requiresOpenaiAuth": False,
        }

        (custom_home / "config.toml").write_text(
            '\n'.join(
                [
                    'model_provider = "custom-provider"',
                    "",
                    "[model_providers.custom-provider]",
                    'base_url = "https://proxy.example/v1"',
                    'wire_api = "responses"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        custom = request(custom_home, "account-custom", {})
        assert custom["id"] == "account-custom"
        assert custom["result"] == {"account": None, "requiresOpenaiAuth": False}

        (oss_home / "config.toml").write_text('oss_provider = "ollama"\n', encoding="utf-8")
        oss = request(oss_home, "account-oss", {})
        assert oss["id"] == "account-oss"
        assert oss["result"] == {"account": None, "requiresOpenaiAuth": False}

        invalid = request(no_auth_home, "account-invalid", {"refreshToken": "yes"})
        assert invalid["id"] == "account-invalid"
        assert invalid["error"]["code"] == -32602
    finally:
        shutil.rmtree(no_auth_home, ignore_errors=True)
        shutil.rmtree(api_key_home, ignore_errors=True)
        shutil.rmtree(chatgpt_home, ignore_errors=True)
        shutil.rmtree(bedrock_home, ignore_errors=True)
        shutil.rmtree(custom_home, ignore_errors=True)
        shutil.rmtree(oss_home, ignore_errors=True)


def run_account_logout_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-logout-", dir="/tmp"))
    try:
        (codex_home / "auth.json").write_text(
            json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "test-api-key"}),
            encoding="utf-8",
        )

        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        proc = subprocess.Popen(
            [str(binary), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            write_json_line(proc, {"jsonrpc": "2.0", "id": "before", "method": "account/read"})
            before = read_json_line(proc, 5)
            assert before["id"] == "before"
            assert before["result"] == {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}

            write_json_line(proc, {"jsonrpc": "2.0", "id": "logout", "method": "account/logout"})
            logout = read_json_line(proc, 5)
            assert logout["id"] == "logout"
            assert logout["result"] == {}

            notification = read_json_line(proc, 5)
            assert notification == {
                "method": "account/updated",
                "params": {"authMode": None, "planType": None},
            }
            assert not (codex_home / "auth.json").exists()

            write_json_line(proc, {"jsonrpc": "2.0", "id": "after", "method": "account/read"})
            after = read_json_line(proc, 5)
            assert after["id"] == "after"
            assert after["result"] == {"account": None, "requiresOpenaiAuth": True}

            write_json_line(proc, {"jsonrpc": "2.0", "id": "invalid-logout", "method": "account/logout", "params": {}})
            invalid = read_json_line(proc, 5)
            assert invalid["id"] == "invalid-logout"
            assert invalid["error"]["code"] == -32602

            assert proc.stdin is not None
            proc.stdin.close()
            proc.wait(timeout=5)
            if proc.returncode != 0:
                raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_account_login_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-login-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        proc = subprocess.Popen(
            [str(binary), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "login",
                    "method": "account/login/start",
                    "params": {"type": "apiKey", "apiKey": "test-api-key"},
                },
            )
            login = read_json_line(proc, 5)
            assert login["id"] == "login"
            assert login["result"] == {"type": "apiKey"}

            completed = read_json_line(proc, 5)
            assert completed == {
                "method": "account/login/completed",
                "params": {"loginId": None, "success": True, "error": None},
            }

            updated = read_json_line(proc, 5)
            assert updated == {
                "method": "account/updated",
                "params": {"authMode": "apikey", "planType": None},
            }

            auth_json = json.loads((codex_home / "auth.json").read_text(encoding="utf-8"))
            assert auth_json == {"auth_mode": "apikey", "OPENAI_API_KEY": "test-api-key"}

            write_json_line(proc, {"jsonrpc": "2.0", "id": "after-login", "method": "account/read"})
            after = read_json_line(proc, 5)
            assert after["id"] == "after-login"
            assert after["result"] == {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "missing-api-key",
                    "method": "account/login/start",
                    "params": {"type": "apiKey"},
                },
            )
            missing_api_key = read_json_line(proc, 5)
            assert missing_api_key["id"] == "missing-api-key"
            assert missing_api_key["error"]["code"] == -32602

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "unsupported-login",
                    "method": "account/login/start",
                    "params": {"type": "chatgpt"},
                },
            )
            unsupported = read_json_line(proc, 5)
            assert unsupported["id"] == "unsupported-login"
            assert unsupported["error"]["code"] == -32603

            assert proc.stdin is not None
            proc.stdin.close()
            proc.wait(timeout=5)
            if proc.returncode != 0:
                raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_account_login_cancel_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-account-login-cancel-", dir="/tmp"))
    try:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        proc = subprocess.Popen(
            [str(binary), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            valid_login_ids = [
                "00000000-0000-0000-0000-000000000000",
                "00000000000000000000000000000000",
                "{00000000-0000-0000-0000-000000000000}",
                "urn:uuid:00000000-0000-0000-0000-000000000000",
            ]
            for index, login_id in enumerate(valid_login_ids):
                request_id = f"cancel-missing-{index}"
                write_json_line(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "method": "account/login/cancel",
                        "params": {"loginId": login_id},
                    },
                )
                cancel = read_json_line(proc, 5)
                assert cancel["id"] == request_id
                assert cancel["result"] == {"status": "notFound"}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "cancel-invalid-id",
                    "method": "account/login/cancel",
                    "params": {"loginId": "not-a-uuid"},
                },
            )
            invalid_id = read_json_line(proc, 5)
            assert invalid_id["id"] == "cancel-invalid-id"
            assert invalid_id["error"]["code"] == -32602
            assert "invalid login id" in invalid_id["error"]["message"]

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "cancel-invalid-params",
                    "method": "account/login/cancel",
                    "params": None,
                },
            )
            invalid_params = read_json_line(proc, 5)
            assert invalid_params["id"] == "cancel-invalid-params"
            assert invalid_params["error"]["code"] == -32602

            assert proc.stdin is not None
            proc.stdin.close()
            proc.wait(timeout=5)
            if proc.returncode != 0:
                raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


def run_account_rate_limits_rpc_smoke(binary: Path) -> None:
    def request(codex_home: Path, request_id: str, params_marker: object) -> dict:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "account/rateLimits/read"}
        if params_marker is not _OMIT:
            payload["params"] = params_marker
        return request_stdio_app_server(binary, payload, env)

    server, base_url = start_rate_limit_backend()
    chatgpt_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-rate-limits-chatgpt-", dir="/tmp"))
    no_auth_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-rate-limits-none-", dir="/tmp"))
    api_key_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-rate-limits-api-", dir="/tmp"))
    try:
        access_token = encode_unsigned_jwt({"exp": 4_102_444_800})
        id_token = encode_unsigned_jwt(
            {
                "https://api.openai.com/auth": {
                    "chatgpt_account_id": "acct_123",
                },
            }
        )
        (chatgpt_home / "config.toml").write_text(f'chatgpt_base_url = "{base_url}"\n', encoding="utf-8")
        (chatgpt_home / "auth.json").write_text(
            json.dumps(
                {
                    "auth_mode": "chatgpt",
                    "tokens": {
                        "id_token": id_token,
                        "access_token": access_token,
                        "refresh_token": "refresh-token",
                        "account_id": "acct_123",
                    },
                }
            ),
            encoding="utf-8",
        )
        rate_limits = request(chatgpt_home, "rate-limits", _OMIT)
        assert rate_limits["id"] == "rate-limits"
        result = rate_limits["result"]
        primary = result["rateLimits"]
        assert primary == {
            "limitId": "codex",
            "limitName": None,
            "primary": {"usedPercent": 42, "windowDurationMins": 5, "resetsAt": 123},
            "secondary": {"usedPercent": 84, "windowDurationMins": 60, "resetsAt": 456},
            "credits": {"hasCredits": True, "unlimited": False, "balance": "9.99"},
            "planType": "pro",
            "rateLimitReachedType": "workspace_member_credits_depleted",
        }
        assert result["rateLimitsByLimitId"]["codex"] == primary
        assert result["rateLimitsByLimitId"]["codex_other"] == {
            "limitId": "codex_other",
            "limitName": "codex_other",
            "primary": {"usedPercent": 70, "windowDurationMins": 15, "resetsAt": 789},
            "secondary": None,
            "credits": None,
            "planType": "pro",
            "rateLimitReachedType": None,
        }
        assert RateLimitBackendHandler.requests == [
            {
                "path": "/api/codex/usage",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            }
        ]

        no_auth = request(no_auth_home, "rate-limits-no-auth", _OMIT)
        assert no_auth["id"] == "rate-limits-no-auth"
        assert no_auth["error"]["code"] == -32602
        assert "codex account authentication required" in no_auth["error"]["message"]

        (api_key_home / "auth.json").write_text(
            json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "test-api-key"}),
            encoding="utf-8",
        )
        api_key = request(api_key_home, "rate-limits-api-key", None)
        assert api_key["id"] == "rate-limits-api-key"
        assert api_key["error"]["code"] == -32602
        assert "chatgpt authentication required" in api_key["error"]["message"]

        invalid = request(chatgpt_home, "rate-limits-invalid", {})
        assert invalid["id"] == "rate-limits-invalid"
        assert invalid["error"]["code"] == -32602
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(chatgpt_home, ignore_errors=True)
        shutil.rmtree(no_auth_home, ignore_errors=True)
        shutil.rmtree(api_key_home, ignore_errors=True)


def run_experimental_feature_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-features-", dir="/tmp"))
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    proc = subprocess.Popen(
        [str(binary), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

    def rpc(request_id: str, method: str, params: dict) -> dict:
        write_json_line(
            proc,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        )
        return read_json_line(proc, 5)

    try:
        first_page = rpc(
            "feature-list-first-page",
            "experimentalFeature/list",
            {"limit": 3},
        )
        assert first_page["id"] == "feature-list-first-page"
        assert len(first_page["result"]["data"]) == 3
        assert first_page["result"]["nextCursor"] == "3"
        first_feature = first_page["result"]["data"][0]
        assert set(first_feature) == {
            "name",
            "stage",
            "displayName",
            "description",
            "announcement",
            "enabled",
            "defaultEnabled",
        }

        second_page = rpc(
            "feature-list-second-page",
            "experimentalFeature/list",
            {"cursor": first_page["result"]["nextCursor"], "limit": 2},
        )
        assert second_page["id"] == "feature-list-second-page"
        assert len(second_page["result"]["data"]) == 2

        invalid_cursor = rpc(
            "feature-list-invalid-cursor",
            "experimentalFeature/list",
            {"cursor": "bad"},
        )
        assert invalid_cursor["id"] == "feature-list-invalid-cursor"
        assert invalid_cursor["error"]["code"] == -32600
        assert invalid_cursor["error"]["message"] == "invalid cursor: bad"

        (codex_home / "config.toml").write_text(
            "[features]\napps = false\ngoals = true\n",
            encoding="utf-8",
        )
        all_features = rpc("feature-list-all", "experimentalFeature/list", {})
        assert all_features["id"] == "feature-list-all"
        by_name = {item["name"]: item for item in all_features["result"]["data"]}
        assert by_name["apps"]["enabled"] is False
        assert by_name["apps"]["defaultEnabled"] is True
        assert by_name["goals"]["enabled"] is True
        assert by_name["goals"]["stage"] == "beta"
        assert by_name["goals"]["displayName"] == "goals"

        set_enablement = rpc(
            "feature-enable-set",
            "experimentalFeature/enablement/set",
            {"enablement": {"apps": True, "memories": True, "tool_call_mcp_elicitation": False}},
        )
        assert set_enablement["id"] == "feature-enable-set"
        assert set_enablement["result"]["enablement"] == {
            "apps": True,
            "memories": True,
            "tool_call_mcp_elicitation": False,
        }

        after_enablement = rpc("feature-list-after-enable", "experimentalFeature/list", {})
        after_by_name = {item["name"]: item for item in after_enablement["result"]["data"]}
        assert after_by_name["apps"]["enabled"] is False
        assert after_by_name["memories"]["enabled"] is True
        assert after_by_name["tool_call_mcp_elicitation"]["enabled"] is False

        empty_enablement = rpc(
            "feature-enable-empty",
            "experimentalFeature/enablement/set",
            {"enablement": {}},
        )
        assert empty_enablement["id"] == "feature-enable-empty"
        assert empty_enablement["result"]["enablement"] == {}

        invalid_enablement = rpc(
            "feature-enable-invalid",
            "experimentalFeature/enablement/set",
            {"enablement": {"apps": "yes"}},
        )
        assert invalid_enablement["id"] == "feature-enable-invalid"
        assert invalid_enablement["error"]["code"] == -32602

        unsupported_enablement = rpc(
            "feature-enable-unsupported",
            "experimentalFeature/enablement/set",
            {"enablement": {"personality": False}},
        )
        assert unsupported_enablement["id"] == "feature-enable-unsupported"
        assert unsupported_enablement["error"]["code"] == -32600
        assert "unsupported feature enablement `personality`" in unsupported_enablement["error"]["message"]

        unknown_enablement = rpc(
            "feature-enable-unknown",
            "experimentalFeature/enablement/set",
            {"enablement": {"not_real": True}},
        )
        assert unknown_enablement["id"] == "feature-enable-unknown"
        assert unknown_enablement["error"]["code"] == -32600
        assert unknown_enablement["error"]["message"] == "invalid feature enablement `not_real`"
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
        shutil.rmtree(codex_home, ignore_errors=True)


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


def run_relay_smoke(binary: Path, relay_args_for_socket) -> None:
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
                [str(binary), *relay_args_for_socket(socket_path)],
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


def run_proxy_smoke(binary: Path) -> None:
    run_relay_smoke(
        binary,
        lambda socket_path: ["app-server", "proxy", "--sock", str(socket_path)],
    )


def run_stdio_to_uds_smoke(binary: Path) -> None:
    run_relay_smoke(binary, lambda socket_path: ["stdio-to-uds", str(socket_path)])


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


def run_flag_compat_smoke(binary: Path) -> None:
    analytics = subprocess.run(
        [str(binary), "app-server", "--analytics-default-enabled", "--listen", "off"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert analytics.returncode == 0
    assert analytics.stdout == "app-server transport: off\n"

    digest = "ab" * 32
    capability = subprocess.run(
        [
            str(binary),
            "app-server",
            "--listen",
            "ws://127.0.0.1:4500",
            "--ws-auth",
            "capability-token",
            "--ws-token-sha256",
            digest,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert capability.returncode != 0
    assert "AppServerListenTransportNotImplemented" in capability.stderr
    assert "UnknownAppServerOption" not in capability.stderr

    signed_bearer = subprocess.run(
        [
            str(binary),
            "app-server",
            "--listen",
            "ws://127.0.0.1:4500",
            "--ws-auth",
            "signed-bearer-token",
            "--ws-shared-secret-file",
            "/tmp/codex-app-server-secret",
            "--ws-issuer",
            "issuer",
            "--ws-audience",
            "audience",
            "--ws-max-clock-skew-seconds",
            "9",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert signed_bearer.returncode != 0
    assert "AppServerListenTransportNotImplemented" in signed_bearer.stderr
    assert "UnknownAppServerOption" not in signed_bearer.stderr

    missing_mode = subprocess.run(
        [str(binary), "app-server", "--listen", "off", "--ws-token-sha256", digest],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert missing_mode.returncode != 0
    assert "AppServerWebsocketAuthModeRequired" in missing_mode.stderr


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_stdio_smoke(binary)
    print("app-server-stdio-e2e: ok")
    run_memory_reset_smoke(binary)
    print("app-server-memory-reset-e2e: ok")
    run_marketplace_rpc_smoke(binary)
    print("app-server-marketplace-rpc-e2e: ok")
    run_plugin_rpc_smoke(binary)
    print("app-server-plugin-rpc-e2e: ok")
    run_filesystem_rpc_smoke(binary)
    print("app-server-filesystem-rpc-e2e: ok")
    run_model_rpc_smoke(binary)
    print("app-server-model-rpc-e2e: ok")
    run_config_read_rpc_smoke(binary)
    print("app-server-config-read-rpc-e2e: ok")
    run_account_read_rpc_smoke(binary)
    print("app-server-account-read-rpc-e2e: ok")
    run_account_logout_rpc_smoke(binary)
    print("app-server-account-logout-rpc-e2e: ok")
    run_account_login_rpc_smoke(binary)
    print("app-server-account-login-rpc-e2e: ok")
    run_account_login_cancel_rpc_smoke(binary)
    print("app-server-account-login-cancel-rpc-e2e: ok")
    run_account_rate_limits_rpc_smoke(binary)
    print("app-server-account-rate-limits-rpc-e2e: ok")
    run_experimental_feature_rpc_smoke(binary)
    print("app-server-experimental-feature-rpc-e2e: ok")
    run_unix_path_smoke(binary)
    print("app-server-unix-path-e2e: ok")
    run_unix_default_smoke(binary)
    print("app-server-unix-default-e2e: ok")
    run_proxy_smoke(binary)
    print("app-server-proxy-e2e: ok")
    run_stdio_to_uds_smoke(binary)
    print("stdio-to-uds-e2e: ok")
    run_unix_refuses_regular_file_smoke(binary)
    print("app-server-unix-regular-file-e2e: ok")
    run_flag_compat_smoke(binary)
    print("app-server-flag-compat-e2e: ok")


if __name__ == "__main__":
    main()
