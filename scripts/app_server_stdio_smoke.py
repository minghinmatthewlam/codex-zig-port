#!/usr/bin/env python3
import base64
import io
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_OMIT = object()


def remote_plugin_bundle_bytes() -> bytes:
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        for name, data in {
            "linear/.codex-plugin/plugin.json": json.dumps(
                {"name": "linear", "version": "1.2.3"},
                separators=(",", ":"),
            ).encode("utf-8"),
            "linear/skills/plan-work/SKILL.md": b"# Plan Work\n",
        }.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return out.getvalue()


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


class AddCreditsNudgeBackendHandler(BaseHTTPRequestHandler):
    requests: list[dict[str, object]] = []
    status_code: int = 200

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length).decode("utf-8")
        AddCreditsNudgeBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
                "content_type": self.headers.get("Content-Type"),
                "body": json.loads(body),
            }
        )
        if self.path != "/api/codex/accounts/send_add_credits_nudge_email":
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(AddCreditsNudgeBackendHandler.status_code)
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        return


class PluginBackendHandler(BaseHTTPRequestHandler):
    requests: list[dict[str, object]] = []

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body_bytes = self.rfile.read(content_length)
        body_json = json.loads(body_bytes.decode("utf-8")) if body_bytes else None
        upload_url_path = "/backend-api/public/plugins/workspace/upload-url"
        finalize_create_path = "/backend-api/public/plugins/workspace"
        finalize_update_path = (
            "/backend-api/public/plugins/workspace/"
            "plugins~Plugin_00000000000000000000000000000000"
        )
        uninstall_path = (
            "/backend-api/plugins/"
            "plugins~Plugin_00000000000000000000000000000000"
            "/uninstall"
        )
        install_path = (
            "/backend-api/ps/plugins/"
            "plugins~Plugin_00000000000000000000000000000000"
            "/install"
        )
        if self.path == upload_url_path:
            PluginBackendHandler.requests.append(
                {
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "account_id": self.headers.get("ChatGPT-Account-Id"),
                    "content_type": self.headers.get("Content-Type"),
                    "body": body_json,
                }
            )
            body = json.dumps(
                {
                    "file_id": "file_123",
                    "upload_url": f"http://{self.headers['Host']}/upload/file_123",
                    "etag": "upload-etag-123",
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == finalize_create_path or self.path == finalize_update_path:
            PluginBackendHandler.requests.append(
                {
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "account_id": self.headers.get("ChatGPT-Account-Id"),
                    "content_type": self.headers.get("Content-Type"),
                    "body": body_json,
                }
            )
            body = json.dumps(
                {
                    "plugin_id": "plugins~Plugin_11111111111111111111111111111111",
                    "share_url": "https://chatgpt.example/plugins/share/share-key-save",
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        PluginBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
            }
        )
        if self.path == uninstall_path:
            body = json.dumps(
                {
                    "id": "plugins~Plugin_00000000000000000000000000000000",
                    "enabled": False,
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == install_path:
            body = json.dumps(
                {
                    "id": "plugins~Plugin_00000000000000000000000000000000",
                    "enabled": True,
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body_bytes = self.rfile.read(content_length)
        upload_path = "/upload/file_123"
        if self.path == upload_path:
            PluginBackendHandler.requests.append(
                {
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "account_id": self.headers.get("ChatGPT-Account-Id"),
                    "content_type": self.headers.get("Content-Type"),
                    "x_ms_blob_type": self.headers.get("x-ms-blob-type"),
                    "body_len": len(body_bytes),
                    "body_magic": list(body_bytes[:2]),
                }
            )
            self.send_response(201)
            self.end_headers()
            return

        body_text = body_bytes.decode("utf-8")
        body_json = json.loads(body_text) if body_text else None
        PluginBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
                "body": body_json,
            }
        )
        update_path = (
            "/backend-api/public/plugins/"
            "plugins~Plugin_00000000000000000000000000000000"
            "/shares"
        )
        if self.path != update_path:
            self.send_response(404)
            self.end_headers()
            return

        body = json.dumps(
            {
                "principals": [
                    {
                        "principal_type": "user",
                        "principal_id": "user-1",
                        "name": "Gavin",
                    }
                ]
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self) -> None:
        PluginBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
            }
        )
        delete_path = (
            "/backend-api/public/plugins/workspace/"
            "plugins~Plugin_00000000000000000000000000000000"
        )
        if self.path != delete_path:
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        PluginBackendHandler.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "account_id": self.headers.get("ChatGPT-Account-Id"),
            }
        )
        detail_path = (
            "/backend-api/ps/plugins/"
            "plugins~Plugin_00000000000000000000000000000000"
        )
        detail_with_downloads_path = detail_path + "?includeDownloadUrls=true"
        bundle_path = "/bundles/linear.tar.gz"
        list_path = "/backend-api/ps/plugins/list?scope=GLOBAL&limit=200"
        installed_path = "/backend-api/ps/plugins/installed?scope=GLOBAL"
        workspace_created_path = "/backend-api/ps/plugins/workspace/created?limit=200"
        workspace_installed_path = "/backend-api/ps/plugins/installed?scope=WORKSPACE"
        skill_path = (
            "/backend-api/ps/plugins/"
            "plugins~Plugin_00000000000000000000000000000000"
            "/skills/plan-work"
        )
        if self.path == bundle_path:
            body = remote_plugin_bundle_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == detail_path or self.path == detail_with_downloads_path or self.path == list_path:
            plugin = {
                "id": "plugins~Plugin_00000000000000000000000000000000",
                "name": "linear",
                "scope": "GLOBAL",
                "installation_policy": "AVAILABLE",
                "authentication_policy": "ON_USE",
                "status": "ENABLED",
                "release": {
                    "display_name": "Linear",
                    "description": "Track work in Linear",
                    "app_ids": ["gmail"],
                    "keywords": ["issue-tracking", "project management"],
                    "interface": {
                        "short_description": "Plan and track work",
                        "capabilities": ["Read", "Write"],
                        "logo_url": "https://example.com/linear.png",
                        "screenshot_urls": ["https://example.com/linear-shot.png"],
                    },
                    "skills": [
                        {
                            "name": "plan-work",
                            "description": "Plan work from Linear issues",
                            "plugin_release_skill_id": "skill-1",
                            "interface": {
                                "display_name": "Plan Work",
                                "short_description": "Create a plan from issues",
                            },
                        }
                    ],
                },
            }
            if self.path == detail_with_downloads_path:
                plugin["release"]["version"] = "1.2.3"
                plugin["release"]["bundle_download_url"] = (
                    f"http://{self.headers['Host']}/bundles/linear.tar.gz"
                )
        workspace_plugin = {
            "id": "plugins~Plugin_00000000000000000000000000000000",
            "name": "linear",
            "scope": "WORKSPACE",
            "creator_account_user_id": "user-owner",
            "creator_name": "Owner",
            "share_url": "https://chatgpt.example/plugins/share/share-key-1",
            "share_principals": [
                {
                    "principal_type": "user",
                    "principal_id": "user-owner",
                    "role": "owner",
                    "name": "Owner",
                },
                {
                    "principal_type": "user",
                    "principal_id": "user-reader",
                    "role": "reader",
                    "name": "Reader",
                },
            ],
            "installation_policy": "AVAILABLE",
            "authentication_policy": "ON_USE",
            "status": "ENABLED",
            "release": {
                "display_name": "Linear",
                "description": "Track work in Linear",
                "app_ids": [],
                "keywords": ["workspace"],
                "interface": {
                    "short_description": "Plan and track workspace work",
                    "capabilities": ["Read"],
                },
                "skills": [],
            },
        }
        if self.path == detail_path or self.path == detail_with_downloads_path:
            body = json.dumps(
                plugin,
                separators=(",", ":"),
            ).encode("utf-8")
        elif self.path == list_path:
            body = json.dumps(
                {
                    "plugins": [plugin],
                    "pagination": {"limit": 200, "next_page_token": None},
                },
                separators=(",", ":"),
            ).encode("utf-8")
        elif self.path == installed_path:
            body = json.dumps(
                {
                    "plugins": [
                        {
                            "id": "plugins~Plugin_00000000000000000000000000000000",
                            "name": "linear",
                            "scope": "GLOBAL",
                            "installation_policy": "AVAILABLE",
                            "authentication_policy": "ON_USE",
                            "release": {
                                "display_name": "Linear",
                                "description": "Track work in Linear",
                                "app_ids": ["gmail"],
                                "keywords": ["issue-tracking", "project management"],
                                "interface": {
                                    "short_description": "Plan and track work",
                                    "capabilities": ["Read", "Write"],
                                    "logo_url": "https://example.com/linear.png",
                                    "screenshot_urls": ["https://example.com/linear-shot.png"],
                                },
                                "skills": [],
                            },
                            "enabled": False,
                            "disabled_skill_names": ["plan-work"],
                        }
                    ],
                    "pagination": {"limit": 50, "next_page_token": None},
                },
                separators=(",", ":"),
            ).encode("utf-8")
        elif self.path == workspace_created_path:
            body = json.dumps(
                {
                    "plugins": [workspace_plugin],
                    "pagination": {"limit": 200, "next_page_token": None},
                },
                separators=(",", ":"),
            ).encode("utf-8")
        elif self.path == workspace_installed_path:
            installed_workspace_plugin = dict(workspace_plugin)
            installed_workspace_plugin["enabled"] = True
            installed_workspace_plugin["disabled_skill_names"] = []
            body = json.dumps(
                {
                    "plugins": [installed_workspace_plugin],
                    "pagination": {"limit": 50, "next_page_token": None},
                },
                separators=(",", ":"),
            ).encode("utf-8")
        elif self.path == skill_path:
            body = json.dumps(
                {
                    "plugin_id": "plugins~Plugin_00000000000000000000000000000000",
                    "name": "plan-work",
                    "skill_md_contents": "# Plan Work\n\nUse Linear issues to create a plan.",
                },
                separators=(",", ":"),
            ).encode("utf-8")
        else:
            self.send_response(404)
            self.end_headers()
            return

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


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=repo,
        env=clean_git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )


def git_output(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        env=clean_git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def clean_git_env() -> dict[str, str]:
    git_env = os.environ.copy()
    git_env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    git_env["GIT_CONFIG_NOSYSTEM"] = "1"
    return git_env


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
        ),
        encoding="utf-8",
    )
    root.joinpath("plugins", plugin_name, ".codex-plugin", "plugin.json").write_text(
        json.dumps(
            {
                "name": plugin_name,
                "interface": {
                    "displayName": f"{plugin_name.title()} Plugin",
                },
            }
        ),
        encoding="utf-8",
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
        ),
        encoding="utf-8",
    )


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


def run_git_diff_to_remote_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-git-diff-", dir="/tmp"))
    codex_home = root / "codex-home"
    remote = root / "remote.git"
    repo = root / "repo"
    try:
        codex_home.mkdir()
        repo.mkdir()
        git(root, "init", "--bare", str(remote))
        git(repo, "init")
        git(repo, "config", "user.email", "test@example.com")
        git(repo, "config", "user.name", "Test User")
        (repo / "test.txt").write_text("base\n", encoding="utf-8")
        git(repo, "add", "test.txt")
        git(repo, "commit", "-m", "initial")
        git(repo, "branch", "-M", "main")
        git(repo, "remote", "add", "origin", str(remote))
        git(repo, "push", "-u", "origin", "main")
        remote_sha = git_output(repo, "rev-parse", "origin/main")

        (repo / "test.txt").write_text("modified\n", encoding="utf-8")
        (repo / "untracked.txt").write_text("new\n", encoding="utf-8")

        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)

        diff_response = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "git-diff", "method": "gitDiffToRemote", "params": {"cwd": str(repo)}},
            env,
        )
        assert diff_response["id"] == "git-diff"
        assert diff_response["result"]["sha"] == remote_sha
        diff = diff_response["result"]["diff"]
        assert "diff --git a/test.txt b/test.txt" in diff
        assert "+modified" in diff
        assert "diff --git a/untracked.txt b/untracked.txt" in diff
        assert "+new" in diff

        invalid_params = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "git-diff-invalid-params", "method": "gitDiffToRemote", "params": {}},
            env,
        )
        assert invalid_params["id"] == "git-diff-invalid-params"
        assert invalid_params["error"]["code"] == -32602

        missing_repo = root / "missing-repo"
        missing_repo.mkdir()
        missing = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "git-diff-missing",
                "method": "gitDiffToRemote",
                "params": {"cwd": str(missing_repo)},
            },
            env,
        )
        assert missing["id"] == "git-diff-missing"
        assert missing["error"]["code"] == -32602
        assert "failed to compute git diff to remote" in missing["error"]["message"]
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_fuzzy_file_search_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-fuzzy-search-", dir="/tmp"))
    codex_home = root / "codex-home"
    search_root = root / "search-root"
    try:
        codex_home.mkdir()
        search_root.mkdir()
        (search_root / "alpha.txt").write_text("file match\n", encoding="utf-8")
        (search_root / "beta.txt").write_text("not a match\n", encoding="utf-8")
        (search_root / "alpha_dir").mkdir()

        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)

        search = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "fuzzy-search",
                "method": "fuzzyFileSearch",
                "params": {"query": "alp", "roots": [str(search_root)], "cancellationToken": "search-1"},
            },
            env,
        )
        assert search["id"] == "fuzzy-search"
        files = search["result"]["files"]
        by_path = {item["path"]: item for item in files}
        assert by_path["alpha.txt"]["root"] == str(search_root)
        assert by_path["alpha.txt"]["match_type"] == "file"
        assert by_path["alpha.txt"]["file_name"] == "alpha.txt"
        assert isinstance(by_path["alpha.txt"]["score"], int)
        assert by_path["alpha.txt"]["score"] > 0
        assert by_path["alpha.txt"]["indices"] == [0, 1, 2]
        assert by_path["alpha_dir"]["root"] == str(search_root)
        assert by_path["alpha_dir"]["match_type"] == "directory"
        assert by_path["alpha_dir"]["file_name"] == "alpha_dir"
        assert isinstance(by_path["alpha_dir"]["score"], int)
        assert by_path["alpha_dir"]["score"] > 0
        assert "beta.txt" not in by_path

        empty_query = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "fuzzy-empty-query",
                "method": "fuzzyFileSearch",
                "params": {"query": "", "roots": [str(search_root)], "cancellationToken": None},
            },
            env,
        )
        assert empty_query["id"] == "fuzzy-empty-query"
        assert empty_query["result"] == {"files": []}

        invalid_roots = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "fuzzy-invalid-roots",
                "method": "fuzzyFileSearch",
                "params": {"query": "alp", "roots": "not-a-list"},
            },
            env,
        )
        assert invalid_roots["id"] == "fuzzy-invalid-roots"
        assert invalid_roots["error"]["code"] == -32602

        invalid_token = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "fuzzy-invalid-token",
                "method": "fuzzyFileSearch",
                "params": {"query": "alp", "roots": [str(search_root)], "cancellationToken": 7},
            },
            env,
        )
        assert invalid_token["id"] == "fuzzy-invalid-token"
        assert invalid_token["error"]["code"] == -32602

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
                    "id": "fuzzy-session-start",
                    "method": "fuzzyFileSearch/sessionStart",
                    "params": {"sessionId": "session-1", "roots": [str(search_root)]},
                },
            )
            session_start = read_json_line(proc, 5)
            assert session_start["id"] == "fuzzy-session-start"
            assert session_start["result"] == {}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "fuzzy-session-update",
                    "method": "fuzzyFileSearch/sessionUpdate",
                    "params": {"sessionId": "session-1", "query": "ALP"},
                },
            )
            session_update = read_json_line(proc, 5)
            assert session_update["id"] == "fuzzy-session-update"
            assert session_update["result"] == {}
            updated = read_json_line(proc, 5)
            assert updated["method"] == "fuzzyFileSearch/sessionUpdated"
            assert updated["params"]["sessionId"] == "session-1"
            assert updated["params"]["query"] == "ALP"
            by_session_path = {item["path"]: item for item in updated["params"]["files"]}
            assert by_session_path["alpha.txt"]["root"] == str(search_root)
            assert by_session_path["alpha.txt"]["indices"] == [0, 1, 2]
            completed = read_json_line(proc, 5)
            assert completed == {
                "jsonrpc": "2.0",
                "method": "fuzzyFileSearch/sessionCompleted",
                "params": {"sessionId": "session-1"},
            }

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "fuzzy-session-empty-update",
                    "method": "fuzzyFileSearch/sessionUpdate",
                    "params": {"sessionId": "session-1", "query": "zzzz"},
                },
            )
            empty_update = read_json_line(proc, 5)
            assert empty_update["id"] == "fuzzy-session-empty-update"
            assert empty_update["result"] == {}
            empty_updated = read_json_line(proc, 5)
            assert empty_updated["method"] == "fuzzyFileSearch/sessionUpdated"
            assert empty_updated["params"] == {"sessionId": "session-1", "query": "zzzz", "files": []}
            empty_completed = read_json_line(proc, 5)
            assert empty_completed["method"] == "fuzzyFileSearch/sessionCompleted"
            assert empty_completed["params"]["sessionId"] == "session-1"

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "fuzzy-session-stop",
                    "method": "fuzzyFileSearch/sessionStop",
                    "params": {"sessionId": "session-1"},
                },
            )
            session_stop = read_json_line(proc, 5)
            assert session_stop["id"] == "fuzzy-session-stop"
            assert session_stop["result"] == {}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "fuzzy-session-missing",
                    "method": "fuzzyFileSearch/sessionUpdate",
                    "params": {"sessionId": "session-1", "query": "alp"},
                },
            )
            missing_session = read_json_line(proc, 5)
            assert missing_session["id"] == "fuzzy-session-missing"
            assert missing_session["error"]["code"] == -32600
            assert missing_session["error"]["message"] == "fuzzy file search session not found: session-1"

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
        shutil.rmtree(root, ignore_errors=True)


def run_marketplace_rpc_smoke(binary: Path) -> None:
    env = os.environ.copy()
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-marketplace-", dir="/tmp"))
    codex_home = root / "codex-home"
    source = root / "marketplace-source"
    git_source = root / "marketplace-git-source"
    git_config = root / "gitconfig"
    git_url = "https://github.com/owner/repo.git"
    try:
        codex_home.mkdir()
        write_marketplace_fixture(source, "debug", "sample")
        write_git_marketplace_fixture(git_source, "git-debug", "git-sample")
        write_git_url_rewrite_config(git_config, git_url, git_source)
        env["CODEX_HOME"] = str(codex_home)
        env["GIT_CONFIG_GLOBAL"] = str(git_config)
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        expected_source = str(source.resolve())

        added = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-add-local",
                "method": "marketplace/add",
                "params": {"source": str(source)},
            },
            env,
        )
        assert added["id"] == "marketplace-add-local"
        assert added["result"] == {
            "marketplaceName": "debug",
            "installedRoot": expected_source,
            "alreadyAdded": False,
        }
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert "[marketplaces.debug]" in config_text
        assert 'source_type = "local"' in config_text
        assert expected_source in config_text

        repeated = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-add-local-repeat",
                "method": "marketplace/add",
                "params": {"source": str(source)},
            },
            env,
        )
        assert repeated["id"] == "marketplace-add-local-repeat"
        assert repeated["result"]["alreadyAdded"] is True

        listed = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-list-configured",
                "method": "plugin/list",
                "params": {},
            },
            env,
        )
        assert listed["id"] == "marketplace-list-configured"
        assert listed["result"]["marketplaces"][0]["name"] == "debug"
        assert listed["result"]["marketplaces"][0]["plugins"][0]["id"] == "sample@debug"

        removed = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-remove-local",
                "method": "marketplace/remove",
                "params": {"marketplaceName": "debug"},
            },
            env,
        )
        assert removed["id"] == "marketplace-remove-local"
        assert removed["result"] == {"marketplaceName": "debug", "installedRoot": None}
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert "[marketplaces.debug]" not in config_text

        unknown_remove = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-remove-unknown",
                "method": "marketplace/remove",
                "params": {"marketplaceName": "debug"},
            },
            env,
        )
        assert unknown_remove["id"] == "marketplace-remove-unknown"
        assert unknown_remove["error"]["code"] == -32600

        git_added = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-add-git",
                "method": "marketplace/add",
                "params": {
                    "source": "owner/repo",
                    "refName": "release",
                    "sparsePaths": [".agents", "plugins/git-sample"],
                },
            },
            env,
        )
        expected_git_root = codex_home / ".tmp" / "marketplaces" / "git-debug"
        assert git_added["id"] == "marketplace-add-git"
        if "result" not in git_added:
            raise AssertionError(f"expected git marketplace add result: {git_added!r}")
        assert git_added["result"] == {
            "marketplaceName": "git-debug",
            "installedRoot": str(expected_git_root),
            "alreadyAdded": False,
        }
        assert expected_git_root.joinpath(
            "plugins", "git-sample", ".codex-plugin", "plugin.json"
        ).is_file()
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert "[marketplaces.git-debug]" in config_text
        assert 'source_type = "git"' in config_text
        assert f'source = "{git_url}"' in config_text
        assert 'ref = "release"' in config_text
        assert 'sparse_paths = [".agents", "plugins/git-sample"]' in config_text

        git_repeated = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-add-git-repeat",
                "method": "marketplace/add",
                "params": {
                    "source": "owner/repo",
                    "refName": "release",
                    "sparsePaths": [".agents", "plugins/git-sample"],
                },
            },
            env,
        )
        assert git_repeated["id"] == "marketplace-add-git-repeat"
        assert git_repeated["result"]["alreadyAdded"] is True
        assert git_repeated["result"]["installedRoot"] == str(expected_git_root)

        git_listed = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-list-git",
                "method": "plugin/list",
                "params": {},
            },
            env,
        )
        assert git_listed["id"] == "marketplace-list-git"
        git_marketplaces = [
            marketplace
            for marketplace in git_listed["result"]["marketplaces"]
            if marketplace["name"] == "git-debug"
        ]
        assert len(git_marketplaces) == 1
        assert git_marketplaces[0]["plugins"][0]["id"] == "git-sample@git-debug"

        git_removed = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-remove-git",
                "method": "marketplace/remove",
                "params": {"marketplaceName": "git-debug"},
            },
            env,
        )
        assert git_removed["id"] == "marketplace-remove-git"
        assert git_removed["result"] == {
            "marketplaceName": "git-debug",
            "installedRoot": str(expected_git_root),
        }
        assert not expected_git_root.exists()

        upgrade = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-upgrade",
                "method": "marketplace/upgrade",
                "params": {"marketplaceName": None},
            },
            env,
        )
        assert upgrade["id"] == "marketplace-upgrade"
        assert upgrade["error"]["code"] == -32603
        assert "marketplace/upgrade is parsed but not implemented yet" in upgrade["error"]["message"]

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
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_plugin_rpc_smoke(binary: Path) -> None:
    env = os.environ.copy()
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-plugins-", dir="/tmp"))
    codex_home = root / "codex-home"
    repo = root / "repo"
    plugin_root = repo / "plugins" / "enabled-plugin"
    installed_root = (
        codex_home
        / "plugins"
        / "cache"
        / "local-market"
        / "enabled-plugin"
        / "local"
    )
    try:
        codex_home.mkdir()
        repo.joinpath(".agents", "plugins").mkdir(parents=True)
        plugin_root.joinpath(".codex-plugin").mkdir(parents=True)
        plugin_root.joinpath("skills", "thread-summarizer").mkdir(parents=True)
        plugin_root.joinpath("hooks").mkdir()
        installed_root.joinpath(".codex-plugin").mkdir(parents=True)
        codex_home.joinpath("config.toml").write_text(
            """[features]
plugins = true
plugin_hooks = true

[[skills.config]]
name = "enabled-plugin:thread-summarizer"
enabled = false

[plugins."enabled-plugin@local-market"]
enabled = true

[plugins."enabled-plugin@local-market".mcp_servers.demo]
command = "demo-server"
""",
            encoding="utf-8",
        )
        repo.joinpath(".agents", "plugins", "marketplace.json").write_text(
            json.dumps(
                {
                    "name": "local-market",
                    "interface": {"displayName": "Local Marketplace"},
                    "plugins": [
                        {
                            "name": "enabled-plugin",
                            "source": {
                                "source": "local",
                                "path": "./plugins/enabled-plugin",
                            },
                            "category": "Developer tools",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        plugin_root.joinpath(".codex-plugin", "plugin.json").write_text(
            json.dumps(
                {
                    "name": "enabled-plugin",
                    "keywords": ["api-key", "developer tools"],
                    "interface": {
                        "displayName": "Enabled Plugin",
                        "shortDescription": "Plugin list smoke fixture",
                        "capabilities": ["Write"],
                        "defaultPrompt": "Use the enabled plugin",
                    },
                }
            ),
            encoding="utf-8",
        )
        plugin_root.joinpath("skills", "thread-summarizer", "SKILL.md").write_text(
            """---
name: thread-summarizer
description: Summarize plugin smoke threads
---

# Thread Summarizer
""",
            encoding="utf-8",
        )
        plugin_root.joinpath("hooks", "hooks.json").write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [
                            {
                                "hooks": [
                                    {"type": "command", "command": "echo plugin startup"}
                                ]
                            }
                        ],
                        "PreToolUse": [
                            {
                                "hooks": [
                                    {"type": "command", "command": "echo plugin pre tool"}
                                ]
                            }
                        ],
                    }
                }
            ),
            encoding="utf-8",
        )
        plugin_root.joinpath(".app.json").write_text(
            json.dumps({"apps": {"gmail": {"id": "gmail", "name": "Gmail"}}}),
            encoding="utf-8",
        )
        plugin_root.joinpath(".mcp.json").write_text(
            json.dumps({"mcpServers": {"demo": {"command": "demo-server"}}}),
            encoding="utf-8",
        )
        installed_root.joinpath(".codex-plugin", "plugin.json").write_text(
            json.dumps({"name": "enabled-plugin"}),
            encoding="utf-8",
        )

        env["CODEX_HOME"] = str(codex_home)
        plugin_list = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-list",
                "method": "plugin/list",
                "params": {
                    "cwds": [str(repo)],
                    "marketplaceKinds": ["local"],
                },
            },
            env,
        )
        assert plugin_list["id"] == "plugin-list"
        result = plugin_list["result"]
        assert result["marketplaceLoadErrors"] == []
        assert result["featuredPluginIds"] == []
        assert len(result["marketplaces"]) == 1
        marketplace = result["marketplaces"][0]
        assert marketplace["name"] == "local-market"
        assert marketplace["path"] == str(repo / ".agents" / "plugins" / "marketplace.json")
        assert marketplace["interface"]["displayName"] == "Local Marketplace"
        assert len(marketplace["plugins"]) == 1
        plugin = marketplace["plugins"][0]
        assert plugin["id"] == "enabled-plugin@local-market"
        assert plugin["source"] == {"type": "local", "path": str(plugin_root)}
        assert plugin["installed"] is True
        assert plugin["enabled"] is True
        assert plugin["installPolicy"] == "AVAILABLE"
        assert plugin["authPolicy"] == "ON_INSTALL"
        assert plugin["availability"] == "AVAILABLE"
        assert plugin["interface"]["displayName"] == "Enabled Plugin"
        assert plugin["interface"]["category"] == "Developer tools"
        assert plugin["interface"]["defaultPrompt"] == ["Use the enabled plugin"]
        assert plugin["keywords"] == ["api-key", "developer tools"]

        plugin_read = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-read",
                "method": "plugin/read",
                "params": {
                    "marketplacePath": str(repo / ".agents" / "plugins" / "marketplace.json"),
                    "remoteMarketplaceName": None,
                    "pluginName": "enabled-plugin",
                },
            },
            env,
        )
        assert plugin_read["id"] == "plugin-read"
        detail = plugin_read["result"]["plugin"]
        assert detail["marketplaceName"] == "local-market"
        assert detail["marketplacePath"] == str(
            repo / ".agents" / "plugins" / "marketplace.json"
        )
        assert detail["summary"]["id"] == "enabled-plugin@local-market"
        assert detail["summary"]["installed"] is True
        assert detail["summary"]["enabled"] is True
        assert detail["summary"]["interface"]["displayName"] == "Enabled Plugin"
        assert detail["description"] is None
        assert len(detail["skills"]) == 1
        assert detail["skills"][0]["name"] == "enabled-plugin:thread-summarizer"
        assert detail["skills"][0]["description"] == "Summarize plugin smoke threads"
        assert detail["skills"][0]["enabled"] is False
        assert detail["hooks"] == [
            {
                "key": "enabled-plugin@local-market:hooks/hooks.json:pre_tool_use:0:0",
                "eventName": "preToolUse",
            },
            {
                "key": "enabled-plugin@local-market:hooks/hooks.json:session_start:0:0",
                "eventName": "sessionStart",
            },
        ]
        assert detail["apps"] == [
            {
                "id": "gmail",
                "name": "Gmail",
                "description": None,
                "installUrl": "https://chatgpt.com/apps/gmail/gmail",
                "needsAuth": True,
            }
        ]
        assert detail["mcpServers"] == ["demo"]

        plugin_uninstall = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-uninstall-local",
                "method": "plugin/uninstall",
                "params": {"pluginId": "enabled-plugin@local-market"},
            },
            env,
        )
        assert plugin_uninstall["id"] == "plugin-uninstall-local"
        assert plugin_uninstall["result"] == {}
        assert not (
            codex_home / "plugins" / "cache" / "local-market" / "enabled-plugin"
        ).exists()
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert '[plugins."enabled-plugin@local-market"]' not in config_text
        assert (
            '[plugins."enabled-plugin@local-market".mcp_servers.demo]'
            not in config_text
        )

        plugin_uninstall_again = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-uninstall-local-again",
                "method": "plugin/uninstall",
                "params": {"pluginId": "enabled-plugin@local-market"},
            },
            env,
        )
        assert plugin_uninstall_again["id"] == "plugin-uninstall-local-again"
        assert plugin_uninstall_again["result"] == {}

        installable_root = repo / "plugins" / "installable-plugin"
        installable_root.joinpath(".codex-plugin").mkdir(parents=True)
        installable_root.joinpath("skills", "installer").mkdir(parents=True)
        installable_root.joinpath(".codex-plugin", "plugin.json").write_text(
            json.dumps(
                {
                    "name": "installable-plugin",
                    "version": "1.2.3",
                    "interface": {"displayName": "Installable Plugin"},
                }
            ),
            encoding="utf-8",
        )
        installable_root.joinpath("skills", "installer", "SKILL.md").write_text(
            "# Installer\n",
            encoding="utf-8",
        )
        repo.joinpath(".agents", "plugins", "marketplace.json").write_text(
            json.dumps(
                {
                    "name": "local-market",
                    "plugins": [
                        {
                            "name": "installable-plugin",
                            "source": {
                                "source": "local",
                                "path": "./plugins/installable-plugin",
                            },
                            "policy": {"authentication": "ON_USE"},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        plugin_install = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-install-local",
                "method": "plugin/install",
                "params": {
                    "marketplacePath": str(
                        repo / ".agents" / "plugins" / "marketplace.json"
                    ),
                    "remoteMarketplaceName": None,
                    "pluginName": "installable-plugin",
                },
            },
            env,
        )
        assert plugin_install["id"] == "plugin-install-local"
        assert plugin_install["result"] == {
            "authPolicy": "ON_USE",
            "appsNeedingAuth": [],
        }
        installed_installable = (
            codex_home
            / "plugins"
            / "cache"
            / "local-market"
            / "installable-plugin"
            / "1.2.3"
        )
        assert installed_installable.joinpath(".codex-plugin", "plugin.json").is_file()
        assert installed_installable.joinpath("skills", "installer", "SKILL.md").is_file()
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert '[plugins."installable-plugin@local-market"]' in config_text
        assert "enabled = true" in config_text

        git_remote = root / "git-plugin-source"
        git_plugin_root = git_remote / "plugins" / "git-installable"
        git_plugin_root.joinpath(".codex-plugin").mkdir(parents=True)
        git_plugin_root.joinpath("skills", "git-installer").mkdir(parents=True)
        git_plugin_root.joinpath(".codex-plugin", "plugin.json").write_text(
            json.dumps(
                {
                    "name": "git-installable",
                    "version": "2.3.4",
                    "interface": {"displayName": "Git Installable"},
                }
            ),
            encoding="utf-8",
        )
        git_plugin_root.joinpath("skills", "git-installer", "SKILL.md").write_text(
            "# Git Installer\n",
            encoding="utf-8",
        )
        git(git_remote, "init")
        git(git_remote, "config", "user.email", "codex-test@example.com")
        git(git_remote, "config", "user.name", "Codex Test")
        git(git_remote, "add", ".")
        git(git_remote, "commit", "-m", "initial")
        git_sha = git_output(git_remote, "rev-parse", "HEAD")
        repo.joinpath(".agents", "plugins", "marketplace.json").write_text(
            json.dumps(
                {
                    "name": "local-market",
                    "plugins": [
                        {
                            "name": "git-installable",
                            "source": {
                                "source": "git-subdir",
                                "url": str(git_remote),
                                "path": "plugins/git-installable",
                                "sha": git_sha,
                            },
                            "policy": {"authentication": "ON_USE"},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        git_plugin_install = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-install-git",
                "method": "plugin/install",
                "params": {
                    "marketplacePath": str(
                        repo / ".agents" / "plugins" / "marketplace.json"
                    ),
                    "remoteMarketplaceName": None,
                    "pluginName": "git-installable",
                },
            },
            env,
        )
        assert git_plugin_install["id"] == "plugin-install-git"
        assert git_plugin_install["result"] == {
            "authPolicy": "ON_USE",
            "appsNeedingAuth": [],
        }
        installed_git_plugin = (
            codex_home
            / "plugins"
            / "cache"
            / "local-market"
            / "git-installable"
            / "2.3.4"
        )
        assert installed_git_plugin.joinpath(".codex-plugin", "plugin.json").is_file()
        assert installed_git_plugin.joinpath(
            "skills", "git-installer", "SKILL.md"
        ).is_file()
        assert not (
            codex_home
            / "plugins"
            / ".marketplace-plugin-source-staging"
            / "local-market"
            / "git-installable"
        ).exists()
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert '[plugins."git-installable@local-market"]' in config_text
    finally:
        shutil.rmtree(root, ignore_errors=True)

    server, base_url = start_plugin_backend()
    remote_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-plugin-remote-", dir="/tmp"))
    try:
        remote_home.joinpath("config.toml").write_text(
            f"""chatgpt_base_url = "{base_url}/backend-api"

[features]
plugins = true
remote_plugin = true
""",
            encoding="utf-8",
        )
        access_token = encode_unsigned_jwt({"exp": 4_102_444_800})
        id_token = encode_unsigned_jwt(
            {
                "https://api.openai.com/auth": {
                    "chatgpt_account_id": "acct_123",
                },
            }
        )
        remote_home.joinpath("auth.json").write_text(
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
        remote_env = os.environ.copy()
        remote_env.pop("OPENAI_API_KEY", None)
        remote_env.pop("CODEX_ACCESS_TOKEN", None)
        remote_env["CODEX_HOME"] = str(remote_home)
        remote_env["CODEX_TEST_ALLOW_HTTP_REMOTE_PLUGIN_BUNDLE_DOWNLOADS"] = "1"
        remote_plugin_list = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "remote-plugin-list",
                "method": "plugin/list",
                "params": {},
            },
            remote_env,
        )
        assert remote_plugin_list["id"] == "remote-plugin-list"
        assert "result" in remote_plugin_list, remote_plugin_list
        remote_marketplaces = remote_plugin_list["result"]["marketplaces"]
        assert len(remote_marketplaces) == 1, {
            "response": remote_plugin_list,
            "backend_requests": PluginBackendHandler.requests,
        }
        remote_marketplace = remote_marketplaces[0]
        assert remote_marketplace["name"] == "chatgpt-global"
        assert remote_marketplace["path"] is None
        assert remote_marketplace["interface"] == {"displayName": "ChatGPT Plugins"}
        assert len(remote_marketplace["plugins"]) == 1
        listed_plugin = remote_marketplace["plugins"][0]
        assert listed_plugin["id"] == "plugins~Plugin_00000000000000000000000000000000"
        assert listed_plugin["name"] == "linear"
        assert listed_plugin["source"] == {"type": "remote"}
        assert listed_plugin["installed"] is True
        assert listed_plugin["enabled"] is False
        assert listed_plugin["installPolicy"] == "AVAILABLE"
        assert listed_plugin["authPolicy"] == "ON_USE"
        assert listed_plugin["availability"] == "AVAILABLE"
        assert listed_plugin["interface"]["displayName"] == "Linear"
        assert listed_plugin["interface"]["shortDescription"] == "Plan and track work"
        assert listed_plugin["keywords"] == ["issue-tracking", "project management"]
        assert PluginBackendHandler.requests == [
            {
                "path": "/backend-api/ps/plugins/list?scope=GLOBAL&limit=200",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": "/backend-api/ps/plugins/installed?scope=GLOBAL",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
        ]
        PluginBackendHandler.requests = []

        remote_plugin_read = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "remote-plugin-read",
                "method": "plugin/read",
                "params": {
                    "remoteMarketplaceName": "chatgpt-global",
                    "pluginName": "plugins~Plugin_00000000000000000000000000000000",
                },
            },
            remote_env,
        )
        assert remote_plugin_read["id"] == "remote-plugin-read"
        remote_detail = remote_plugin_read["result"]["plugin"]
        assert remote_detail["marketplaceName"] == "chatgpt-global"
        assert remote_detail["marketplacePath"] is None
        assert remote_detail["description"] == "Track work in Linear"
        remote_summary = remote_detail["summary"]
        assert remote_summary["id"] == "plugins~Plugin_00000000000000000000000000000000"
        assert remote_summary["name"] == "linear"
        assert remote_summary["shareContext"] is None
        assert remote_summary["source"] == {"type": "remote"}
        assert remote_summary["installed"] is True
        assert remote_summary["enabled"] is False
        assert remote_summary["installPolicy"] == "AVAILABLE"
        assert remote_summary["authPolicy"] == "ON_USE"
        assert remote_summary["availability"] == "AVAILABLE"
        assert remote_summary["interface"]["displayName"] == "Linear"
        assert remote_summary["interface"]["shortDescription"] == "Plan and track work"
        assert remote_summary["interface"]["capabilities"] == ["Read", "Write"]
        assert remote_summary["interface"]["logoUrl"] == "https://example.com/linear.png"
        assert remote_summary["interface"]["screenshotUrls"] == [
            "https://example.com/linear-shot.png"
        ]
        assert remote_summary["keywords"] == ["issue-tracking", "project management"]
        assert remote_detail["skills"] == [
            {
                "name": "plan-work",
                "description": "Plan work from Linear issues",
                "shortDescription": "Create a plan from issues",
                "interface": {
                    "displayName": "Plan Work",
                    "shortDescription": "Create a plan from issues",
                    "iconSmall": None,
                    "iconLarge": None,
                    "brandColor": None,
                    "defaultPrompt": None,
                },
                "path": None,
                "enabled": False,
            }
        ]
        assert remote_detail["hooks"] == []
        assert remote_detail["apps"] == [
            {
                "id": "gmail",
                "name": "gmail",
                "description": None,
                "installUrl": "https://chatgpt.com/apps/gmail/gmail",
                "needsAuth": True,
            }
        ]
        assert remote_detail["mcpServers"] == []

        plugin_skill_read = request_stdio_app_server(
            binary,
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
            remote_env,
        )
        assert plugin_skill_read["id"] == "plugin-skill-read"
        assert plugin_skill_read["result"] == {
            "contents": "# Plan Work\n\nUse Linear issues to create a plan."
        }
        assert PluginBackendHandler.requests == [
            {
                "path": (
                    "/backend-api/ps/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": "/backend-api/ps/plugins/installed?scope=GLOBAL",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": (
                    "/backend-api/ps/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                    "/skills/plan-work"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            }
        ]

        invalid_skill = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-skill-read-invalid",
                "method": "plugin/skill/read",
                "params": {
                    "remoteMarketplaceName": "chatgpt-global",
                    "remotePluginId": "plugins~Plugin_00000000000000000000000000000000",
                    "skillName": "",
                },
            },
            remote_env,
        )
        assert invalid_skill["id"] == "plugin-skill-read-invalid"
        assert invalid_skill["error"]["code"] == -32600

        PluginBackendHandler.requests = []
        remote_plugin_install = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "remote-plugin-install",
                "method": "plugin/install",
                "params": {
                    "remoteMarketplaceName": "caller-marketplace-is-ignored",
                    "pluginName": "plugins~Plugin_00000000000000000000000000000000",
                },
            },
            remote_env,
        )
        assert remote_plugin_install["id"] == "remote-plugin-install"
        assert remote_plugin_install["result"] == {
            "authPolicy": "ON_USE",
            "appsNeedingAuth": [],
        }
        installed_remote = (
            remote_home
            / "plugins"
            / "cache"
            / "chatgpt-global"
            / "linear"
            / "1.2.3"
        )
        assert installed_remote.joinpath(".codex-plugin", "plugin.json").is_file()
        assert installed_remote.joinpath("skills", "plan-work", "SKILL.md").is_file()
        assert PluginBackendHandler.requests == [
            {
                "path": (
                    "/backend-api/ps/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                    "?includeDownloadUrls=true"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": "/bundles/linear.tar.gz",
                "authorization": None,
                "account_id": None,
            },
            {
                "path": (
                    "/backend-api/ps/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                    "/install"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
        ]

        share_source = remote_home / "share-source"
        share_source.joinpath(".codex-plugin").mkdir(parents=True)
        share_source.joinpath("skills", "draft").mkdir(parents=True)
        share_source.joinpath(".codex-plugin", "plugin.json").write_text(
            json.dumps(
                {
                    "name": "share-source",
                    "interface": {"displayName": "Share Source"},
                }
            ),
            encoding="utf-8",
        )
        share_source.joinpath("skills", "draft", "SKILL.md").write_text(
            "# Draft\n",
            encoding="utf-8",
        )
        PluginBackendHandler.requests = []
        plugin_share_save = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-share-save",
                "method": "plugin/share/save",
                "params": {
                    "pluginPath": str(share_source),
                    "remotePluginId": None,
                    "discoverability": "PRIVATE",
                    "shareTargets": [
                        {"principalType": "user", "principalId": "user-1"},
                        {"principalType": "workspace", "principalId": "workspace-1"},
                    ],
                },
            },
            remote_env,
        )
        assert plugin_share_save["id"] == "plugin-share-save"
        assert plugin_share_save["result"] == {
            "remotePluginId": "plugins~Plugin_11111111111111111111111111111111",
            "shareUrl": "https://chatgpt.example/plugins/share/share-key-save",
        }

        share_mapping = remote_home / ".tmp" / "plugin-share-local-paths-v1.json"
        saved_mapping = json.loads(share_mapping.read_text(encoding="utf-8"))
        assert saved_mapping == {
            "localPluginPathsByRemotePluginId": {
                "plugins~Plugin_11111111111111111111111111111111": str(share_source)
            }
        }
        assert len(PluginBackendHandler.requests) == 3
        assert PluginBackendHandler.requests[0] == {
            "path": "/backend-api/public/plugins/workspace/upload-url",
            "authorization": f"Bearer {access_token}",
            "account_id": "acct_123",
            "content_type": "application/json",
            "body": {
                "filename": "share-source.tar.gz",
                "mime_type": "application/gzip",
                "size_bytes": PluginBackendHandler.requests[0]["body"]["size_bytes"],
            },
        }
        assert PluginBackendHandler.requests[0]["body"]["size_bytes"] > 10
        assert PluginBackendHandler.requests[1]["path"] == "/upload/file_123"
        assert PluginBackendHandler.requests[1]["authorization"] is None
        assert PluginBackendHandler.requests[1]["account_id"] is None
        assert PluginBackendHandler.requests[1]["content_type"] == "application/gzip"
        assert PluginBackendHandler.requests[1]["x_ms_blob_type"] == "BlockBlob"
        assert PluginBackendHandler.requests[1]["body_len"] == PluginBackendHandler.requests[0]["body"]["size_bytes"]
        assert PluginBackendHandler.requests[1]["body_magic"] == [0x1F, 0x8B]
        assert PluginBackendHandler.requests[2] == {
            "path": "/backend-api/public/plugins/workspace",
            "authorization": f"Bearer {access_token}",
            "account_id": "acct_123",
            "content_type": "application/json",
            "body": {
                "file_id": "file_123",
                "etag": "upload-etag-123",
                "discoverability": "PRIVATE",
                "share_targets": [
                    {"principal_type": "user", "principal_id": "user-1"},
                    {"principal_type": "workspace", "principal_id": "workspace-1"},
                ],
            },
        }

        share_mapping.parent.mkdir(exist_ok=True)
        local_shared_plugin = remote_home / "shared-linear"
        share_mapping.write_text(
            json.dumps(
                {
                    "localPluginPathsByRemotePluginId": {
                        "plugins~Plugin_00000000000000000000000000000000": str(
                            local_shared_plugin
                        )
                    }
                }
            ),
            encoding="utf-8",
        )
        PluginBackendHandler.requests = []
        plugin_share_list = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-share-list",
                "method": "plugin/share/list",
                "params": {},
            },
            remote_env,
        )
        assert plugin_share_list["id"] == "plugin-share-list"
        share_items = plugin_share_list["result"]["data"]
        assert len(share_items) == 1
        share_item = share_items[0]
        assert share_item["shareUrl"] == "https://chatgpt.example/plugins/share/share-key-1"
        assert share_item["localPluginPath"] == str(local_shared_plugin)
        share_summary = share_item["plugin"]
        assert share_summary["id"] == "plugins~Plugin_00000000000000000000000000000000"
        assert share_summary["name"] == "linear"
        assert share_summary["source"] == {"type": "remote"}
        assert share_summary["installed"] is True
        assert share_summary["enabled"] is True
        assert share_summary["shareContext"] == {
            "remotePluginId": "plugins~Plugin_00000000000000000000000000000000",
            "shareUrl": "https://chatgpt.example/plugins/share/share-key-1",
            "creatorAccountUserId": "user-owner",
            "creatorName": "Owner",
            "shareTargets": [
                {
                    "principalType": "user",
                    "principalId": "user-reader",
                    "name": "Reader",
                }
            ],
        }
        assert PluginBackendHandler.requests == [
            {
                "path": "/backend-api/ps/plugins/workspace/created?limit=200",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": "/backend-api/ps/plugins/installed?scope=WORKSPACE",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
        ]

        PluginBackendHandler.requests = []
        plugin_share_update = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-share-update",
                "method": "plugin/share/updateTargets",
                "params": {
                    "remotePluginId": "plugins~Plugin_00000000000000000000000000000000",
                    "shareTargets": [
                        {"principalType": "user", "principalId": "user-1"}
                    ],
                },
            },
            remote_env,
        )
        assert plugin_share_update["id"] == "plugin-share-update"
        assert plugin_share_update["result"] == {
            "principals": [
                {
                    "principalType": "user",
                    "principalId": "user-1",
                    "name": "Gavin",
                }
            ]
        }
        assert PluginBackendHandler.requests == [
            {
                "path": (
                    "/backend-api/public/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                    "/shares"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
                "body": {
                    "targets": [
                        {"principal_type": "user", "principal_id": "user-1"}
                    ]
                },
            }
        ]

        PluginBackendHandler.requests = []
        plugin_share_delete = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "plugin-share-delete",
                "method": "plugin/share/delete",
                "params": {
                    "remotePluginId": "plugins~Plugin_00000000000000000000000000000000"
                },
            },
            remote_env,
        )
        assert plugin_share_delete["id"] == "plugin-share-delete"
        assert plugin_share_delete["result"] == {}
        assert not share_mapping.exists()
        assert PluginBackendHandler.requests == [
            {
                "path": (
                    "/backend-api/public/plugins/workspace/"
                    "plugins~Plugin_00000000000000000000000000000000"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            }
        ]

        current_cache = (
            remote_home
            / "plugins"
            / "cache"
            / "chatgpt-global"
            / "linear"
            / "1.0.0"
            / ".codex-plugin"
        )
        legacy_cache = (
            remote_home
            / "plugins"
            / "cache"
            / "chatgpt-global"
            / "plugins~Plugin_00000000000000000000000000000000"
            / "local"
            / ".codex-plugin"
        )
        current_cache.mkdir(parents=True)
        legacy_cache.mkdir(parents=True)
        current_cache.joinpath("plugin.json").write_text(
            json.dumps({"name": "linear", "version": "1.0.0"}),
            encoding="utf-8",
        )
        legacy_cache.joinpath("plugin.json").write_text(
            json.dumps({"name": "linear"}),
            encoding="utf-8",
        )
        PluginBackendHandler.requests = []
        remote_plugin_uninstall = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "remote-plugin-uninstall",
                "method": "plugin/uninstall",
                "params": {
                    "pluginId": "plugins~Plugin_00000000000000000000000000000000"
                },
            },
            remote_env,
        )
        assert remote_plugin_uninstall["id"] == "remote-plugin-uninstall"
        assert remote_plugin_uninstall["result"] == {}
        assert not (remote_home / "plugins" / "cache" / "chatgpt-global" / "linear").exists()
        assert not (
            remote_home
            / "plugins"
            / "cache"
            / "chatgpt-global"
            / "plugins~Plugin_00000000000000000000000000000000"
        ).exists()
        assert PluginBackendHandler.requests == [
            {
                "path": (
                    "/backend-api/ps/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
            {
                "path": (
                    "/backend-api/plugins/"
                    "plugins~Plugin_00000000000000000000000000000000"
                    "/uninstall"
                ),
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
            },
        ]
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(remote_home, ignore_errors=True)

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


def run_hooks_list_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-hooks-", dir="/tmp"))
    codex_home = root / "codex-home"
    config_path = codex_home / "config.toml"
    user_hooks_json = codex_home / "hooks.json"
    plugin_root = codex_home / "plugins" / "cache" / "test" / "demo" / "local"
    plugin_hooks_json = plugin_root / "hooks" / "hooks.json"
    cwd = root / "repo"
    project_config = cwd / ".codex" / "config.toml"
    project_hooks_json = cwd / ".codex" / "hooks.json"
    try:
        codex_home.mkdir()
        (plugin_root / ".codex-plugin").mkdir(parents=True)
        (plugin_root / "hooks").mkdir()
        project_config.parent.mkdir(parents=True)
        user_hooks_json.write_text(
            json.dumps(
                {
                    "hooks": {
                        "PreToolUse": [
                            {
                                "matcher": "Read",
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": "echo user json hook",
                                        "timeout": 7,
                                        "statusMessage": "running user json hook",
                                    }
                                ],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        config_path.write_text(
            "\n".join(
                [
                    "[features]",
                    "hooks = true",
                    "plugins = true",
                    "plugin_hooks = true",
                    "",
                    '[plugins."demo@test"]',
                    "enabled = true",
                    "",
                    "[hooks]",
                    "",
                    "[[hooks.PreToolUse]]",
                    'matcher = "Bash"',
                    "",
                    "[[hooks.PreToolUse.hooks]]",
                    'type = "command"',
                    'command = "python3 /tmp/listed-hook.py"',
                    "timeout = 5",
                    'statusMessage = "running listed hook"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (plugin_root / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "demo"}),
            encoding="utf-8",
        )
        plugin_hooks_json.write_text(
            json.dumps(
                {
                    "hooks": {
                        "PreToolUse": [
                            {
                                "matcher": "Bash",
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": "echo plugin hook",
                                        "timeout": 7,
                                        "statusMessage": "running plugin hook",
                                    }
                                ],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        project_hooks_json.write_text(
            json.dumps(
                {
                    "hooks": {
                        "PostToolUse": [
                            {
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": "echo project json hook",
                                    }
                                ],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        project_config.write_text(
            "\n".join(
                [
                    "[features]",
                    "hooks = true",
                    "",
                    "[hooks]",
                    "",
                    "[[hooks.UserPromptSubmit]]",
                    "",
                    "[[hooks.UserPromptSubmit.hooks]]",
                    'type = "command"',
                    'command = "echo project hook"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)

        hooks = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "hooks-list",
                "method": "hooks/list",
                "params": {"cwds": [str(cwd)]},
            },
            env,
        )
        assert hooks["id"] == "hooks-list"
        assert len(hooks["result"]["data"]) == 1
        entry = hooks["result"]["data"][0]
        assert entry["cwd"] == str(cwd)
        assert len(entry["warnings"]) == 2
        assert "loading hooks from both" in entry["warnings"][0]
        assert str(user_hooks_json.resolve()) in entry["warnings"][0]
        assert str(config_path.resolve()) in entry["warnings"][0]
        assert "prefer a single representation" in entry["warnings"][0]
        assert "loading hooks from both" in entry["warnings"][1]
        assert str(project_hooks_json.resolve()) in entry["warnings"][1]
        assert str(project_config.resolve()) in entry["warnings"][1]
        assert "prefer a single representation" in entry["warnings"][1]
        assert entry["errors"] == []
        assert len(entry["hooks"]) == 5

        user_json_hook = entry["hooks"][0]
        assert user_json_hook["eventName"] == "preToolUse"
        assert user_json_hook["handlerType"] == "command"
        assert user_json_hook["matcher"] == "Read"
        assert user_json_hook["command"] == "echo user json hook"
        assert user_json_hook["timeoutSec"] == 7
        assert user_json_hook["statusMessage"] == "running user json hook"
        assert user_json_hook["sourcePath"] == str(user_hooks_json.resolve())
        assert user_json_hook["source"] == "user"
        assert user_json_hook["pluginId"] is None
        assert user_json_hook["displayOrder"] == 0
        assert user_json_hook["enabled"] is True
        assert user_json_hook["isManaged"] is False
        assert user_json_hook["trustStatus"] == "untrusted"
        assert user_json_hook["currentHash"].startswith("sha256:")
        assert len(user_json_hook["currentHash"]) == len("sha256:") + 64

        user_config_hook = entry["hooks"][1]
        assert user_config_hook["eventName"] == "preToolUse"
        assert user_config_hook["handlerType"] == "command"
        assert user_config_hook["matcher"] == "Bash"
        assert user_config_hook["command"] == "python3 /tmp/listed-hook.py"
        assert user_config_hook["timeoutSec"] == 5
        assert user_config_hook["statusMessage"] == "running listed hook"
        assert user_config_hook["sourcePath"] == str(config_path.resolve())
        assert user_config_hook["source"] == "user"
        assert user_config_hook["pluginId"] is None
        assert user_config_hook["displayOrder"] == 1
        assert user_config_hook["enabled"] is True
        assert user_config_hook["isManaged"] is False
        assert user_config_hook["trustStatus"] == "untrusted"
        assert user_config_hook["currentHash"].startswith("sha256:")
        assert len(user_config_hook["currentHash"]) == len("sha256:") + 64

        project_json_hook = entry["hooks"][2]
        assert project_json_hook["eventName"] == "postToolUse"
        assert project_json_hook["matcher"] is None
        assert project_json_hook["command"] == "echo project json hook"
        assert project_json_hook["timeoutSec"] == 600
        assert project_json_hook["statusMessage"] is None
        assert project_json_hook["sourcePath"] == str(project_hooks_json.resolve())
        assert project_json_hook["source"] == "project"
        assert project_json_hook["displayOrder"] == 2

        project_hook = entry["hooks"][3]
        assert project_hook["eventName"] == "userPromptSubmit"
        assert project_hook["matcher"] is None
        assert project_hook["command"] == "echo project hook"
        assert project_hook["timeoutSec"] == 600
        assert project_hook["statusMessage"] is None
        assert project_hook["sourcePath"] == str(project_config.resolve())
        assert project_hook["source"] == "project"
        assert project_hook["displayOrder"] == 3

        plugin_hook = entry["hooks"][4]
        assert plugin_hook["key"] == "demo@test:hooks/hooks.json:pre_tool_use:0:0"
        assert plugin_hook["eventName"] == "preToolUse"
        assert plugin_hook["handlerType"] == "command"
        assert plugin_hook["matcher"] == "Bash"
        assert plugin_hook["command"] == "echo plugin hook"
        assert plugin_hook["timeoutSec"] == 7
        assert plugin_hook["statusMessage"] == "running plugin hook"
        assert plugin_hook["sourcePath"] == str(plugin_hooks_json.resolve())
        assert plugin_hook["source"] == "plugin"
        assert plugin_hook["pluginId"] == "demo@test"
        assert plugin_hook["displayOrder"] == 4
        assert plugin_hook["enabled"] is True
        assert plugin_hook["isManaged"] is False
        assert plugin_hook["trustStatus"] == "untrusted"
        assert plugin_hook["currentHash"].startswith("sha256:")
        assert len(plugin_hook["currentHash"]) == len("sha256:") + 64

        def write_hook_state(request_id: str, state: dict[str, object]) -> None:
            response = request_stdio_app_server(
                binary,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "config/batchWrite",
                    "params": {
                        "edits": [
                            {
                                "keyPath": "hooks.state",
                                "value": state,
                                "mergeStrategy": "upsert",
                            }
                        ],
                        "reloadUserConfig": True,
                        "expectedVersion": None,
                    },
                },
                env,
            )
            assert response["id"] == request_id
            assert response["result"]["status"] == "ok"

        def list_user_hook(request_id: str) -> dict:
            response = request_stdio_app_server(
                binary,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "hooks/list",
                    "params": {"cwds": [str(cwd)]},
                },
                env,
            )
            assert response["id"] == request_id
            return response["result"]["data"][0]["hooks"][1]

        user_hook = user_config_hook
        write_hook_state("hooks-state-disable", {user_hook["key"]: {"enabled": False}})
        disabled_user_hook = list_user_hook("hooks-list-disabled")
        assert disabled_user_hook["key"] == user_hook["key"]
        assert disabled_user_hook["enabled"] is False
        assert disabled_user_hook["trustStatus"] == "untrusted"

        write_hook_state(
            "hooks-state-trust",
            {
                user_hook["key"]: {
                    "enabled": True,
                    "trusted_hash": user_hook["currentHash"],
                }
            },
        )
        trusted_user_hook = list_user_hook("hooks-list-trusted")
        assert trusted_user_hook["key"] == user_hook["key"]
        assert trusted_user_hook["enabled"] is True
        assert trusted_user_hook["trustStatus"] == "trusted"

        write_hook_state(
            "hooks-state-modified",
            {
                user_hook["key"]: {
                    "trusted_hash": (
                        "sha256:"
                        "0000000000000000000000000000000000000000000000000000000000000000"
                    ),
                }
            },
        )
        modified_user_hook = list_user_hook("hooks-list-modified")
        assert modified_user_hook["key"] == user_hook["key"]
        assert modified_user_hook["trustStatus"] == "modified"

        config_path.write_text(
            "\n".join(
                [
                    "[hooks]",
                    "",
                    f'[hooks.state."{user_hook["key"]}"]',
                    "enabled = false",
                    f'trusted_hash = "{user_hook["currentHash"]}"',
                    "",
                    "[[hooks.PreToolUse]]",
                    'matcher = "Bash"',
                    "",
                    "[[hooks.PreToolUse.hooks]]",
                    'type = "command"',
                    'command = "python3 /tmp/listed-hook.py"',
                    "timeout = 5",
                    'statusMessage = "running listed hook"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        table_state_user_hook = list_user_hook("hooks-list-table-state")
        assert table_state_user_hook["key"] == user_hook["key"]
        assert table_state_user_hook["enabled"] is False
        assert table_state_user_hook["trustStatus"] == "trusted"

        project_hooks_json.write_text("{ not-json", encoding="utf-8")
        json_warning = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "hooks-list-json-warning",
                "method": "hooks/list",
                "params": {"cwds": [str(cwd)]},
            },
            env,
        )
        assert json_warning["id"] == "hooks-list-json-warning"
        warnings = json_warning["result"]["data"][0]["warnings"]
        assert len(warnings) == 2
        assert "loading hooks from both" in warnings[0]
        assert "failed to parse hooks config" in warnings[1]
        assert str(project_hooks_json) in warnings[1]

        invalid = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "hooks-invalid",
                "method": "hooks/list",
                "params": [],
            },
            env,
        )
        assert invalid["id"] == "hooks-invalid"
        assert invalid["error"]["code"] == -32602
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_skills_list_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-skills-", dir="/tmp"))
    codex_home = root / "codex-home"
    config_path = codex_home / "config.toml"
    cwd = root / "repo"
    repo_skill = cwd / ".codex" / "skills" / "repo-skill"
    plugin_root = codex_home / "plugins" / "cache" / "test" / "sample" / "local"
    plugin_skill = plugin_root / "skills" / "plugin-search"
    extra_root = root / "extra-skills"
    user_skill = extra_root / "user-skill"
    invalid_skill = extra_root / "invalid-skill"
    late_root = root / "late-extra-skills"
    late_skill = late_root / "late-extra-skill"
    try:
        codex_home.mkdir()
        repo_skill.mkdir(parents=True)
        (plugin_root / ".codex-plugin").mkdir(parents=True)
        plugin_skill.mkdir(parents=True)
        user_skill.mkdir(parents=True)
        invalid_skill.mkdir(parents=True)
        config_path.write_text(
            "\n".join(
                [
                    "[features]",
                    "plugins = true",
                    "",
                    '[plugins."sample@test"]',
                    "enabled = true",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        (repo_skill / "SKILL.md").write_text(
            "\n".join(
                [
                    "---",
                    "name: repo-skill",
                    "description: Repo skill description",
                    'short_description: "Repo short"',
                    "---",
                    "Use this repo skill.",
                ]
            ),
            encoding="utf-8",
        )
        (plugin_root / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "sample"}),
            encoding="utf-8",
        )
        (plugin_skill / "SKILL.md").write_text(
            "\n".join(
                [
                    "---",
                    "name: plugin-search",
                    "description: Plugin skill description",
                    "---",
                    "Use this plugin-provided skill.",
                ]
            ),
            encoding="utf-8",
        )
        (user_skill / "SKILL.md").write_text(
            "\n".join(
                [
                    "---",
                    "name: user-skill",
                    "description: User skill description",
                    "---",
                    "Use this user skill.",
                ]
            ),
            encoding="utf-8",
        )
        (user_skill / "agents").mkdir()
        (user_skill / "agents" / "openai.yaml").write_text(
            json.dumps(
                {
                    "interface": {
                        "display_name": "User Skill",
                        "short_description": "  User   short  ",
                        "icon_small": "./assets/small.svg",
                        "brand_color": "#3B82F6",
                        "default_prompt": "  Use   user skill ",
                    },
                    "dependencies": {
                        "tools": [
                            {
                                "type": "env_var",
                                "value": "USER_SKILL_TOKEN",
                                "description": "User skill token",
                            },
                            {
                                "type": "mcp",
                                "value": "user-mcp",
                                "transport": "streamable_http",
                                "url": "https://example.com/mcp",
                            },
                        ]
                    },
                }
            ),
            encoding="utf-8",
        )
        (invalid_skill / "SKILL.md").write_text(
            "\n".join(
                [
                    "---",
                    "name: invalid-skill",
                    "---",
                    "Missing description.",
                ]
            ),
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)

        skills = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-list",
                "method": "skills/list",
                "params": {
                    "cwds": [str(cwd)],
                    "forceReload": True,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(extra_root)]}
                    ],
                },
            },
            env,
        )
        assert skills["id"] == "skills-list"
        assert len(skills["result"]["data"]) == 1
        entry = skills["result"]["data"][0]
        assert entry["cwd"] == str(cwd)
        by_name = {skill["name"]: skill for skill in entry["skills"]}
        assert by_name["repo-skill"]["description"] == "Repo skill description"
        assert by_name["repo-skill"]["shortDescription"] == "Repo short"
        assert by_name["repo-skill"]["scope"] == "repo"
        assert by_name["repo-skill"]["enabled"] is True
        assert by_name["repo-skill"]["path"] == str((repo_skill / "SKILL.md").resolve())
        assert by_name["sample:plugin-search"]["description"] == "Plugin skill description"
        assert by_name["sample:plugin-search"]["scope"] == "user"
        assert by_name["sample:plugin-search"]["enabled"] is True
        assert by_name["sample:plugin-search"]["path"] == str((plugin_skill / "SKILL.md").resolve())
        assert by_name["user-skill"]["description"] == "User skill description"
        assert by_name["user-skill"]["scope"] == "user"
        assert by_name["user-skill"]["path"] == str((user_skill / "SKILL.md").resolve())
        assert by_name["user-skill"]["interface"] == {
            "displayName": "User Skill",
            "shortDescription": "User short",
            "iconSmall": str((user_skill / "assets" / "small.svg").resolve()),
            "brandColor": "#3B82F6",
            "defaultPrompt": "Use user skill",
        }
        assert by_name["user-skill"]["dependencies"] == {
            "tools": [
                {
                    "type": "env_var",
                    "value": "USER_SKILL_TOKEN",
                    "description": "User skill token",
                },
                {
                    "type": "mcp",
                    "value": "user-mcp",
                    "transport": "streamable_http",
                    "url": "https://example.com/mcp",
                },
            ]
        }
        assert any("missing description" in error["message"] for error in entry["errors"])
        assert any(error["path"] == str(invalid_skill / "SKILL.md") for error in entry["errors"])

        proc = subprocess.Popen(
            [str(binary), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:

            def rpc(request_id: str, method: str, params: dict) -> dict:
                write_json_line(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "method": method,
                        "params": params,
                    },
                )
                response = read_json_line(proc, 5)
                assert response["id"] == request_id
                return response

            cached_initial = rpc(
                "skills-cache-initial",
                "skills/list",
                {"cwds": [str(cwd)], "forceReload": True},
            )
            initial_names = {
                skill["name"]
                for skill in cached_initial["result"]["data"][0]["skills"]
            }
            assert "late-extra-skill" not in initial_names

            late_skill.mkdir(parents=True)
            (late_skill / "SKILL.md").write_text(
                "\n".join(
                    [
                        "---",
                        "name: late-extra-skill",
                        "description: Late extra skill",
                        "---",
                        "Added after the initial cached skills/list request.",
                    ]
                ),
                encoding="utf-8",
            )

            cached_without_reload = rpc(
                "skills-cache-without-reload",
                "skills/list",
                {
                    "cwds": [str(cwd)],
                    "forceReload": False,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(late_root)]}
                    ],
                },
            )
            cached_names = {
                skill["name"]
                for skill in cached_without_reload["result"]["data"][0]["skills"]
            }
            assert "late-extra-skill" not in cached_names

            config_write_response = rpc(
                "skills-cache-config-write",
                "config/value/write",
                {
                    "keyPath": "model",
                    "value": "gpt-cache-smoke",
                    "mergeStrategy": "replace",
                },
            )
            assert "version" in config_write_response["result"]

            after_config_write = rpc(
                "skills-cache-after-config-write",
                "skills/list",
                {
                    "cwds": [str(cwd)],
                    "forceReload": False,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(late_root)]}
                    ],
                },
            )
            after_config_write_names = {
                skill["name"]
                for skill in after_config_write["result"]["data"][0]["skills"]
            }
            assert "late-extra-skill" in after_config_write_names

            reloaded = rpc(
                "skills-cache-force-reload",
                "skills/list",
                {
                    "cwds": [str(cwd)],
                    "forceReload": True,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(late_root)]}
                    ],
                },
            )
            reloaded_names = {
                skill["name"]
                for skill in reloaded["result"]["data"][0]["skills"]
            }
            assert "late-extra-skill" in reloaded_names

            watched_list = rpc(
                "skills-list-watch-roots",
                "skills/list",
                {
                    "cwds": [str(cwd)],
                    "forceReload": True,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(extra_root)]}
                    ],
                },
            )
            assert watched_list["result"]["data"][0]["cwd"] == str(cwd)

            updated_skill = "\n".join(
                [
                    "---",
                    "name: repo-skill",
                    "description: Repo skill description updated",
                    "---",
                    "Updated by app-server fs/writeFile.",
                ]
            ).encode("utf-8")
            write_response = rpc(
                "skills-changed-write",
                "fs/writeFile",
                {
                    "path": str(repo_skill / "SKILL.md"),
                    "dataBase64": base64.b64encode(updated_skill).decode("ascii"),
                },
            )
            assert write_response["result"] == {}
            changed = read_json_line(proc, 5)
            assert changed == {
                "jsonrpc": "2.0",
                "method": "skills/changed",
                "params": {},
            }

            config_notify = rpc(
                "skills-config-notify",
                "skills/config/write",
                {"name": "notify-only-skill", "enabled": False},
            )
            assert config_notify["result"]["effectiveEnabled"] is False
            config_changed = read_json_line(proc, 5)
            assert config_changed == {
                "jsonrpc": "2.0",
                "method": "skills/changed",
                "params": {},
            }
        finally:
            if proc.stdin is not None:
                proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

        disable_repo_skill = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-config-disable-name",
                "method": "skills/config/write",
                "params": {"name": "repo-skill", "enabled": False},
            },
            env,
        )
        assert disable_repo_skill["id"] == "skills-config-disable-name"
        assert disable_repo_skill["result"]["effectiveEnabled"] is False
        config_contents = config_path.read_text(encoding="utf-8")
        assert 'name = "repo-skill"' in config_contents
        assert "enabled = false" in config_contents

        skills_after_name_disable = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-list-after-name-disable",
                "method": "skills/list",
                "params": {
                    "cwds": [str(cwd)],
                    "forceReload": True,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(extra_root)]}
                    ],
                },
            },
            env,
        )
        disabled_by_name = {
            skill["name"]: skill
            for skill in skills_after_name_disable["result"]["data"][0]["skills"]
        }
        assert disabled_by_name["repo-skill"]["enabled"] is False
        assert disabled_by_name["user-skill"]["enabled"] is True

        enable_repo_skill = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-config-enable-name",
                "method": "skills/config/write",
                "params": {"name": "repo-skill", "enabled": True},
            },
            env,
        )
        assert enable_repo_skill["id"] == "skills-config-enable-name"
        assert enable_repo_skill["result"]["effectiveEnabled"] is True

        disable_user_skill_path = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-config-disable-path",
                "method": "skills/config/write",
                "params": {"path": str(user_skill / "SKILL.md"), "enabled": False},
            },
            env,
        )
        assert disable_user_skill_path["id"] == "skills-config-disable-path"
        assert disable_user_skill_path["result"]["effectiveEnabled"] is False
        config_contents = config_path.read_text(encoding="utf-8")
        assert f'path = "{(user_skill / "SKILL.md").resolve()}"' in config_contents

        skills_after_path_disable = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-list-after-path-disable",
                "method": "skills/list",
                "params": {
                    "cwds": [str(cwd)],
                    "forceReload": True,
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": [str(extra_root)]}
                    ],
                },
            },
            env,
        )
        disabled_by_path = {
            skill["name"]: skill
            for skill in skills_after_path_disable["result"]["data"][0]["skills"]
        }
        assert disabled_by_path["repo-skill"]["enabled"] is True
        assert disabled_by_path["user-skill"]["enabled"] is False

        invalid_config_selector = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-config-invalid-selector",
                "method": "skills/config/write",
                "params": {"name": "repo-skill", "path": str(repo_skill / "SKILL.md"), "enabled": False},
            },
            env,
        )
        assert invalid_config_selector["id"] == "skills-config-invalid-selector"
        assert invalid_config_selector["error"]["code"] == -32602

        invalid_cwds = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-invalid-cwds",
                "method": "skills/list",
                "params": {"cwds": "not-a-list"},
            },
            env,
        )
        assert invalid_cwds["id"] == "skills-invalid-cwds"
        assert invalid_cwds["error"]["code"] == -32602

        invalid_force_reload = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-invalid-force-reload",
                "method": "skills/list",
                "params": {"forceReload": "yes"},
            },
            env,
        )
        assert invalid_force_reload["id"] == "skills-invalid-force-reload"
        assert invalid_force_reload["error"]["code"] == -32602

        invalid_extra_root = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "skills-invalid-extra-root",
                "method": "skills/list",
                "params": {
                    "cwds": [str(cwd)],
                    "perCwdExtraUserRoots": [
                        {"cwd": str(cwd), "extraUserRoots": ["relative-skills"]}
                    ],
                },
            },
            env,
        )
        assert invalid_extra_root["id"] == "skills-invalid-extra-root"
        assert invalid_extra_root["error"]["code"] == -32602
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_mcp_server_status_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-mcp-status-", dir="/tmp"))
    config_path = codex_home / "config.toml"
    plugin_root = codex_home / "plugins" / "cache" / "test" / "sample" / "local"
    try:
        plugin_root.mkdir(parents=True)
        (plugin_root / ".mcp.json").write_text(
            "\n".join(
                [
                    "{",
                    '  "mcpServers": {',
                    '    "plugin_remote": {',
                    '      "type": "http",',
                    '      "url": "https://plugin.example/mcp",',
                    '      "bearerTokenEnvVar": "PLUGIN_MCP_TOKEN"',
                    "    }",
                    "  }",
                    "}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        config_path.write_text(
            "\n".join(
                [
                    "[features]",
                    "plugins = true",
                    "",
                    '[plugins."sample@test"]',
                    "enabled = true",
                    "",
                    "[mcp_servers.docs]",
                    'command = "docs-server"',
                    'args = ["--stdio"]',
                    "",
                    "[mcp_servers.logged_out]",
                    'url = "https://example.com/no-token"',
                    'bearer_token_env_var = "MISSING_MCP_TOKEN"',
                    "",
                    "[mcp_servers.remote]",
                    'url = "https://example.com/mcp"',
                    'bearer_token_env_var = "TEST_MCP_TOKEN"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["PLUGIN_MCP_TOKEN"] = "plugin-token"
        env["TEST_MCP_TOKEN"] = "test-token"
        env.pop("MISSING_MCP_TOKEN", None)

        reload_response = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-reload",
                "method": "config/mcpServer/reload",
                "params": {},
            },
            env,
        )
        assert reload_response["id"] == "mcp-reload"
        assert reload_response["result"] == {}

        first_page = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-first-page",
                "method": "mcpServerStatus/list",
                "params": {"limit": 2, "detail": "toolsAndAuthOnly"},
            },
            env,
        )
        assert first_page["id"] == "mcp-status-first-page"
        assert first_page["result"]["nextCursor"] == "2"
        first_entries = first_page["result"]["data"]
        assert [entry["name"] for entry in first_entries] == ["docs", "logged_out"]
        assert first_entries[0]["tools"] == {}
        assert first_entries[0]["resources"] == []
        assert first_entries[0]["resourceTemplates"] == []
        assert first_entries[0]["authStatus"] == "unsupported"
        assert first_entries[1]["authStatus"] == "notLoggedIn"

        second_page = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-second-page",
                "method": "mcpServerStatus/list",
                "params": {"cursor": "2", "limit": 2},
            },
            env,
        )
        assert second_page["id"] == "mcp-status-second-page"
        assert second_page["result"]["nextCursor"] is None
        second_entries = second_page["result"]["data"]
        assert [entry["name"] for entry in second_entries] == ["plugin_remote", "remote"]
        assert second_entries[0]["authStatus"] == "bearerToken"
        assert second_entries[0]["tools"] == {}
        assert second_entries[0]["resources"] == []
        assert second_entries[0]["resourceTemplates"] == []
        assert second_entries[1]["authStatus"] == "bearerToken"
        assert second_entries[1]["tools"] == {}
        assert second_entries[1]["resources"] == []
        assert second_entries[1]["resourceTemplates"] == []

        zero_limit = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-zero-limit",
                "method": "mcpServerStatus/list",
                "params": {"limit": 0},
            },
            env,
        )
        assert zero_limit["id"] == "mcp-status-zero-limit"
        assert zero_limit["result"]["nextCursor"] == "1"
        assert [entry["name"] for entry in zero_limit["result"]["data"]] == ["docs"]

        invalid_cursor = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-invalid-cursor",
                "method": "mcpServerStatus/list",
                "params": {"cursor": "bad"},
            },
            env,
        )
        assert invalid_cursor["id"] == "mcp-status-invalid-cursor"
        assert invalid_cursor["error"]["code"] == -32602

        invalid_cursor_range = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-invalid-cursor-range",
                "method": "mcpServerStatus/list",
                "params": {"cursor": "9"},
            },
            env,
        )
        assert invalid_cursor_range["id"] == "mcp-status-invalid-cursor-range"
        assert invalid_cursor_range["error"]["code"] == -32602

        invalid_limit = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-invalid-limit",
                "method": "mcpServerStatus/list",
                "params": {"limit": -1},
            },
            env,
        )
        assert invalid_limit["id"] == "mcp-status-invalid-limit"
        assert invalid_limit["error"]["code"] == -32602

        invalid_detail = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-status-invalid-detail",
                "method": "mcpServerStatus/list",
                "params": {"detail": "minimal"},
            },
            env,
        )
        assert invalid_detail["id"] == "mcp-status-invalid-detail"
        assert invalid_detail["error"]["code"] == -32602

        invalid_reload = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "mcp-reload-invalid-params",
                "method": "config/mcpServer/reload",
                "params": "bad",
            },
            env,
        )
        assert invalid_reload["id"] == "mcp-reload-invalid-params"
        assert invalid_reload["error"]["code"] == -32602
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


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


def run_filesystem_watch_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-fs-watch-", dir="/tmp"))
    env = os.environ.copy()
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
        watched_dir = root / "watched"
        watched_dir.mkdir()
        watched_file = watched_dir / "note.txt"
        payload_base64 = base64.b64encode(b"watched contents").decode("ascii")

        watch = rpc(
            "fs-watch",
            "fs/watch",
            {"watchId": "watch-dir", "path": str(watched_dir)},
        )
        assert watch["id"] == "fs-watch"
        assert watch["result"] == {"path": str(watched_dir)}

        duplicate = rpc(
            "fs-watch-duplicate",
            "fs/watch",
            {"watchId": "watch-dir", "path": str(watched_dir)},
        )
        assert duplicate["id"] == "fs-watch-duplicate"
        assert duplicate["error"]["code"] == -32602
        assert "watchId already exists" in duplicate["error"]["message"]

        write = rpc(
            "fs-watch-write",
            "fs/writeFile",
            {"path": str(watched_file), "dataBase64": payload_base64},
        )
        assert write["id"] == "fs-watch-write"
        assert write["result"] == {}

        changed = read_json_line(proc, 5)
        assert changed["jsonrpc"] == "2.0"
        assert changed["method"] == "fs/changed"
        assert changed["params"] == {
            "watchId": "watch-dir",
            "changedPaths": [str(watched_file)],
        }

        file_watch = rpc(
            "fs-watch-file",
            "fs/watch",
            {"watchId": "watch-file", "path": str(watched_file)},
        )
        assert file_watch["id"] == "fs-watch-file"
        assert file_watch["result"] == {"path": str(watched_file)}

        rewrite = rpc(
            "fs-watch-rewrite",
            "fs/writeFile",
            {"path": str(watched_file), "dataBase64": payload_base64},
        )
        assert rewrite["id"] == "fs-watch-rewrite"
        assert rewrite["result"] == {}

        changed_for_dir = read_json_line(proc, 5)
        changed_for_file = read_json_line(proc, 5)
        notifications_by_watch = {
            changed_for_dir["params"]["watchId"]: changed_for_dir,
            changed_for_file["params"]["watchId"]: changed_for_file,
        }
        assert sorted(notifications_by_watch) == ["watch-dir", "watch-file"]
        assert notifications_by_watch["watch-dir"]["method"] == "fs/changed"
        assert notifications_by_watch["watch-dir"]["params"]["changedPaths"] == [str(watched_file)]
        assert notifications_by_watch["watch-file"]["method"] == "fs/changed"
        assert notifications_by_watch["watch-file"]["params"]["changedPaths"] == [str(watched_file)]

        invalid_watch_path = rpc(
            "fs-watch-relative",
            "fs/watch",
            {"watchId": "watch-relative", "path": "relative"},
        )
        assert invalid_watch_path["id"] == "fs-watch-relative"
        assert invalid_watch_path["error"]["code"] == -32602

        invalid_unwatch = rpc("fs-unwatch-invalid", "fs/unwatch", {"watchId": 12})
        assert invalid_unwatch["id"] == "fs-unwatch-invalid"
        assert invalid_unwatch["error"]["code"] == -32602

        unwatch_dir = rpc("fs-unwatch-dir", "fs/unwatch", {"watchId": "watch-dir"})
        assert unwatch_dir["id"] == "fs-unwatch-dir"
        assert unwatch_dir["result"] == {}

        unwatch_file = rpc("fs-unwatch-file", "fs/unwatch", {"watchId": "watch-file"})
        assert unwatch_file["id"] == "fs-unwatch-file"
        assert unwatch_file["result"] == {}

        post_unwatch = rpc(
            "fs-post-unwatch-write",
            "fs/writeFile",
            {"path": str(watched_file), "dataBase64": payload_base64},
        )
        assert post_unwatch["id"] == "fs-post-unwatch-write"
        assert post_unwatch["result"] == {}

        try:
            extra = read_json_line(proc, 0.25)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"unexpected fs/changed notification after unwatch: {extra!r}")
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
        default_models = rpc("model-list-default", "model/list", {"limit": 2})
        assert default_models["id"] == "model-list-default"
        assert default_models["result"]["nextCursor"] == "2"
        assert len(default_models["result"]["data"]) == 2
        default_model = default_models["result"]["data"][0]
        assert default_model["id"] == "gpt-5.5"
        assert default_model["model"] == "gpt-5.5"
        assert default_model["isDefault"] is True
        assert default_model["hidden"] is False
        assert default_model["defaultReasoningEffort"] == "medium"
        assert default_model["inputModalities"] == ["text", "image"]
        assert default_model["additionalSpeedTiers"] == ["fast"]
        assert "GPT-5.5 is now available" in default_model["availabilityNux"]["message"]
        assert default_models["result"]["data"][1]["id"] == "gpt-5.4"
        assert default_models["result"]["data"][1]["isDefault"] is False

        hidden_models = rpc(
            "model-list-hidden",
            "model/list",
            {"limit": 10, "includeHidden": True},
        )
        assert hidden_models["id"] == "model-list-hidden"
        assert hidden_models["result"]["nextCursor"] is None
        assert any(item["id"] == "codex-auto-review" and item["hidden"] for item in hidden_models["result"]["data"])

        second_page = rpc("model-list-second-page", "model/list", {"limit": 2, "cursor": "2"})
        assert second_page["id"] == "model-list-second-page"
        assert second_page["result"]["nextCursor"] == "4"
        assert [item["id"] for item in second_page["result"]["data"]] == ["gpt-5.4-mini", "gpt-5.3-codex"]
        assert second_page["result"]["data"][1]["upgrade"] == "gpt-5.4"
        assert second_page["result"]["data"][1]["upgradeInfo"]["model"] == "gpt-5.4"

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
        assert configured_models["result"]["data"][0]["model"] == "gpt-5.5"
        assert "gpt-test" not in [item["model"] for item in configured_models["result"]["data"]]

        cursor_end = rpc("model-list-cursor-end", "model/list", {"cursor": "5"})
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


def run_collaboration_mode_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-collaboration-", dir="/tmp"))

    def rpc(request_id: str, params: object = _OMIT) -> dict:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "collaborationMode/list"}
        if params is not _OMIT:
            payload["params"] = params
        return request_stdio_app_server(binary, payload, env)

    try:
        response = rpc("collaboration-mode-list", {})
        assert response["id"] == "collaboration-mode-list"
        assert response["result"]["data"] == [
            {
                "name": "Plan",
                "mode": "plan",
                "model": None,
                "reasoning_effort": "medium",
            },
            {
                "name": "Default",
                "mode": "default",
                "model": None,
                "reasoning_effort": None,
            },
        ]

        omitted = rpc("collaboration-mode-list-omitted")
        assert omitted["id"] == "collaboration-mode-list-omitted"
        assert omitted["result"] == response["result"]

        null_params = rpc("collaboration-mode-list-null", None)
        assert null_params["id"] == "collaboration-mode-list-null"
        assert null_params["result"] == response["result"]

        invalid = rpc("collaboration-mode-list-invalid", [])
        assert invalid["id"] == "collaboration-mode-list-invalid"
        assert invalid["error"]["code"] == -32602
        assert invalid["error"]["message"] == "params must be an object"
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


def run_config_value_write_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-config-write-", dir="/tmp"))
    config_path = codex_home / "config.toml"
    config_path.write_text('model = "gpt-old"\n\n[features]\ngoals = false\n', encoding="utf-8")
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

    def rpc(request_id: str, method: str, params: object) -> dict:
        write_json_line(
            proc,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        )
        return read_json_line(proc, 5)

    try:
        write_model = rpc(
            "config-write-model",
            "config/value/write",
            {
                "keyPath": "model",
                "value": "gpt-written",
                "mergeStrategy": "replace",
                "expectedVersion": None,
            },
        )
        assert write_model["id"] == "config-write-model"
        assert write_model["result"]["status"] == "ok"
        assert write_model["result"]["filePath"] == str(config_path)
        assert write_model["result"]["overriddenMetadata"] is None
        assert write_model["result"]["version"].startswith("sha256:")
        assert len(write_model["result"]["version"]) == len("sha256:") + 64

        after_model = rpc("config-read-after-model-write", "config/read", {})
        assert after_model["id"] == "config-read-after-model-write"
        assert after_model["result"]["config"]["model"] == "gpt-written"

        write_feature = rpc(
            "config-write-feature",
            "config/value/write",
            {
                "filePath": str(config_path),
                "keyPath": "features.goals",
                "value": True,
                "mergeStrategy": "upsert",
                "expectedVersion": write_model["result"]["version"],
            },
        )
        assert write_feature["id"] == "config-write-feature"
        assert write_feature["result"]["status"] == "ok"
        assert write_feature["result"]["filePath"] == str(config_path)

        after_feature = rpc("config-read-after-feature-write", "config/read", {})
        assert after_feature["id"] == "config-read-after-feature-write"
        assert after_feature["result"]["config"]["features"]["goals"] is True

        conflict = rpc(
            "config-write-conflict",
            "config/value/write",
            {
                "keyPath": "model",
                "value": "stale",
                "mergeStrategy": "replace",
                "expectedVersion": "sha256:stale",
            },
        )
        assert conflict["id"] == "config-write-conflict"
        assert conflict["error"]["code"] == -32602
        assert "config version conflict" in conflict["error"]["message"]

        invalid_value = rpc(
            "config-write-invalid-value",
            "config/value/write",
            {"keyPath": "model", "value": {"nested": None}, "mergeStrategy": "replace"},
        )
        assert invalid_value["id"] == "config-write-invalid-value"
        assert invalid_value["error"]["code"] == -32602

        invalid_merge = rpc(
            "config-write-invalid-merge",
            "config/value/write",
            {"keyPath": "model", "value": "gpt-test", "mergeStrategy": "append"},
        )
        assert invalid_merge["id"] == "config-write-invalid-merge"
        assert invalid_merge["error"]["code"] == -32602

        invalid_path = rpc(
            "config-write-invalid-path",
            "config/value/write",
            {"filePath": "relative.toml", "keyPath": "model", "value": "gpt-test", "mergeStrategy": "replace"},
        )
        assert invalid_path["id"] == "config-write-invalid-path"
        assert invalid_path["error"]["code"] == -32602
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


def run_config_batch_write_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-config-batch-", dir="/tmp"))
    config_path = codex_home / "config.toml"
    config_path.write_text(
        'model = "gpt-old"\napproval_policy = "on-request"\n\n[features]\ngoals = false\n',
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

    def rpc(request_id: str, method: str, params: object) -> dict:
        write_json_line(
            proc,
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        )
        return read_json_line(proc, 5)

    try:
        batch = rpc(
            "config-batch-write",
            "config/batchWrite",
            {
                "edits": [
                    {"keyPath": "model", "value": "gpt-batch", "mergeStrategy": "replace"},
                    {"keyPath": "features.goals", "value": True, "mergeStrategy": "upsert"},
                    {"keyPath": "tui.status_line", "value": ["model", "cwd"], "mergeStrategy": "replace"},
                    {
                        "keyPath": "hooks.state",
                        "value": {
                            "hook-one": {"enabled": False},
                            "hook-two": {"trusted_hash": "hash-123"},
                        },
                        "mergeStrategy": "upsert",
                    },
                    {"keyPath": "approval_policy", "value": None, "mergeStrategy": "replace"},
                ],
                "reloadUserConfig": True,
                "expectedVersion": None,
            },
        )
        assert batch["id"] == "config-batch-write"
        assert batch["result"]["status"] == "ok"
        assert batch["result"]["filePath"] == str(config_path)
        assert batch["result"]["overriddenMetadata"] is None
        assert batch["result"]["version"].startswith("sha256:")

        after_batch = rpc("config-read-after-batch-write", "config/read", {})
        assert after_batch["id"] == "config-read-after-batch-write"
        assert after_batch["result"]["config"]["model"] == "gpt-batch"
        assert after_batch["result"]["config"]["features"]["goals"] is True

        contents = config_path.read_text(encoding="utf-8")
        assert 'status_line = ["model", "cwd"]' in contents
        assert 'state = {"hook-one" = {"enabled" = false}, "hook-two" = {"trusted_hash" = "hash-123"}}' in contents
        assert "approval_policy" not in contents

        batch_with_version = rpc(
            "config-batch-write-version",
            "config/batchWrite",
            {
                "filePath": str(config_path),
                "edits": [
                    {"keyPath": "sandbox_mode", "value": "workspace-write", "mergeStrategy": "replace"},
                ],
                "expectedVersion": batch["result"]["version"],
            },
        )
        assert batch_with_version["id"] == "config-batch-write-version"
        assert batch_with_version["result"]["status"] == "ok"

        after_versioned_batch = rpc("config-read-after-versioned-batch", "config/read", {})
        assert after_versioned_batch["id"] == "config-read-after-versioned-batch"
        assert after_versioned_batch["result"]["config"]["sandbox_mode"] == "workspace-write"

        conflict = rpc(
            "config-batch-conflict",
            "config/batchWrite",
            {
                "edits": [
                    {"keyPath": "model", "value": "stale", "mergeStrategy": "replace"},
                ],
                "expectedVersion": "sha256:stale",
            },
        )
        assert conflict["id"] == "config-batch-conflict"
        assert conflict["error"]["code"] == -32602
        assert "config version conflict" in conflict["error"]["message"]

        invalid_edits = rpc("config-batch-invalid-edits", "config/batchWrite", {"edits": {}})
        assert invalid_edits["id"] == "config-batch-invalid-edits"
        assert invalid_edits["error"]["code"] == -32602

        invalid_edit = rpc("config-batch-invalid-edit", "config/batchWrite", {"edits": [{"keyPath": "model"}]})
        assert invalid_edit["id"] == "config-batch-invalid-edit"
        assert invalid_edit["error"]["code"] == -32602

        invalid_reload = rpc(
            "config-batch-invalid-reload",
            "config/batchWrite",
            {
                "edits": [
                    {"keyPath": "model", "value": "gpt-test", "mergeStrategy": "replace"},
                ],
                "reloadUserConfig": "yes",
            },
        )
        assert invalid_reload["id"] == "config-batch-invalid-reload"
        assert invalid_reload["error"]["code"] == -32602

        invalid_path = rpc(
            "config-batch-invalid-path",
            "config/batchWrite",
            {
                "filePath": "relative.toml",
                "edits": [
                    {"keyPath": "model", "value": "gpt-test", "mergeStrategy": "replace"},
                ],
            },
        )
        assert invalid_path["id"] == "config-batch-invalid-path"
        assert invalid_path["error"]["code"] == -32602
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


def start_add_credits_nudge_backend(status_code: int = 200) -> tuple[ThreadingHTTPServer, str]:
    AddCreditsNudgeBackendHandler.requests = []
    AddCreditsNudgeBackendHandler.status_code = status_code
    server = ThreadingHTTPServer(("127.0.0.1", 0), AddCreditsNudgeBackendHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


def start_plugin_backend() -> tuple[ThreadingHTTPServer, str]:
    PluginBackendHandler.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), PluginBackendHandler)
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


def run_get_auth_status_rpc_smoke(binary: Path) -> None:
    def request(codex_home: Path, request_id: str, params_marker: object, extra_env: dict[str, str] | None = None) -> dict:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        if extra_env:
            env.update(extra_env)
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "getAuthStatus"}
        if params_marker is not _OMIT:
            payload["params"] = params_marker
        return request_stdio_app_server(binary, payload, env)

    no_auth_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-none-", dir="/tmp"))
    api_key_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-api-", dir="/tmp"))
    chatgpt_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-chatgpt-", dir="/tmp"))
    agent_identity_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-agent-", dir="/tmp"))
    custom_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-custom-", dir="/tmp"))
    oss_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-auth-status-oss-", dir="/tmp"))
    try:
        no_auth = request(no_auth_home, "auth-status-none", {"includeToken": True, "refreshToken": None})
        assert no_auth["id"] == "auth-status-none"
        assert no_auth["result"] == {
            "authMethod": None,
            "authToken": None,
            "requiresOpenaiAuth": True,
        }

        api_key = request(api_key_home, "auth-status-api-key", {"includeToken": True}, {"OPENAI_API_KEY": "test-api-key"})
        assert api_key["id"] == "auth-status-api-key"
        assert api_key["result"] == {
            "authMethod": "apikey",
            "authToken": "test-api-key",
            "requiresOpenaiAuth": True,
        }

        api_key_no_token = request(
            api_key_home,
            "auth-status-api-key-no-token",
            {"refreshToken": False},
            {"OPENAI_API_KEY": "test-api-key"},
        )
        assert api_key_no_token["id"] == "auth-status-api-key-no-token"
        assert api_key_no_token["result"] == {
            "authMethod": "apikey",
            "authToken": None,
            "requiresOpenaiAuth": True,
        }

        access_token = encode_unsigned_jwt({"exp": 4_102_444_800})
        id_token = encode_unsigned_jwt(
            {
                "https://api.openai.com/auth": {
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
                        "access_token": access_token,
                        "refresh_token": "refresh-token",
                        "account_id": "acct_123",
                    },
                }
            ),
            encoding="utf-8",
        )
        chatgpt = request(chatgpt_home, "auth-status-chatgpt", {"includeToken": True, "refreshToken": False})
        assert chatgpt["id"] == "auth-status-chatgpt"
        assert chatgpt["result"] == {
            "authMethod": "chatgpt",
            "authToken": access_token,
            "requiresOpenaiAuth": True,
        }

        agent_token = encode_unsigned_jwt({"account_id": "acct_agent"})
        (agent_identity_home / "auth.json").write_text(
            json.dumps({"auth_mode": "agentIdentity", "agent_identity": agent_token}),
            encoding="utf-8",
        )
        agent_identity = request(agent_identity_home, "auth-status-agent", {"includeToken": True})
        assert agent_identity["id"] == "auth-status-agent"
        assert agent_identity["result"] == {
            "authMethod": "agentIdentity",
            "authToken": None,
            "requiresOpenaiAuth": True,
        }

        (custom_home / "config.toml").write_text(
            '\n'.join(
                [
                    'model_provider = "custom-provider"',
                    "",
                    "[model_providers.custom-provider]",
                    'base_url = "https://proxy.example/v1"',
                    'wire_api = "responses"',
                    'requires_openai_auth = false',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        custom = request(custom_home, "auth-status-custom", {"includeToken": True}, {"OPENAI_API_KEY": "test-api-key"})
        assert custom["id"] == "auth-status-custom"
        assert custom["result"] == {
            "authMethod": None,
            "authToken": None,
            "requiresOpenaiAuth": False,
        }

        (oss_home / "config.toml").write_text('oss_provider = "ollama"\n', encoding="utf-8")
        oss = request(oss_home, "auth-status-oss", _OMIT, {"OPENAI_API_KEY": "test-api-key"})
        assert oss["id"] == "auth-status-oss"
        assert oss["result"] == {
            "authMethod": None,
            "authToken": None,
            "requiresOpenaiAuth": False,
        }

        invalid_params = request(no_auth_home, "auth-status-invalid-params", [])
        assert invalid_params["id"] == "auth-status-invalid-params"
        assert invalid_params["error"]["code"] == -32602

        invalid_field = request(no_auth_home, "auth-status-invalid-field", {"includeToken": "yes"})
        assert invalid_field["id"] == "auth-status-invalid-field"
        assert invalid_field["error"]["code"] == -32602
    finally:
        shutil.rmtree(no_auth_home, ignore_errors=True)
        shutil.rmtree(api_key_home, ignore_errors=True)
        shutil.rmtree(chatgpt_home, ignore_errors=True)
        shutil.rmtree(agent_identity_home, ignore_errors=True)
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


def run_account_add_credits_nudge_rpc_smoke(binary: Path) -> None:
    def request(codex_home: Path, request_id: str, params_marker: object) -> dict:
        env = os.environ.copy()
        env.pop("OPENAI_API_KEY", None)
        env.pop("CODEX_ACCESS_TOKEN", None)
        env["CODEX_HOME"] = str(codex_home)
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "account/sendAddCreditsNudgeEmail"}
        if params_marker is not _OMIT:
            payload["params"] = params_marker
        return request_stdio_app_server(binary, payload, env)

    def write_chatgpt_home(codex_home: Path, base_url: str) -> str:
        access_token = encode_unsigned_jwt({"exp": 4_102_444_800})
        id_token = encode_unsigned_jwt(
            {
                "https://api.openai.com/auth": {
                    "chatgpt_account_id": "acct_123",
                },
            }
        )
        (codex_home / "config.toml").write_text(f'chatgpt_base_url = "{base_url}"\n', encoding="utf-8")
        (codex_home / "auth.json").write_text(
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
        return access_token

    def write_agent_identity_home(codex_home: Path, base_url: str) -> str:
        access_token = encode_unsigned_jwt({"account_id": "acct_agent"})
        (codex_home / "config.toml").write_text(f'chatgpt_base_url = "{base_url}"\n', encoding="utf-8")
        (codex_home / "auth.json").write_text(
            json.dumps({"auth_mode": "agentIdentity", "agent_identity": access_token}),
            encoding="utf-8",
        )
        return access_token

    chatgpt_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-chatgpt-", dir="/tmp"))
    agent_identity_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-agent-", dir="/tmp"))
    cooldown_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-cooldown-", dir="/tmp"))
    failure_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-failure-", dir="/tmp"))
    no_auth_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-none-", dir="/tmp"))
    api_key_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-add-credits-api-", dir="/tmp"))
    server: ThreadingHTTPServer | None = None
    cooldown_server: ThreadingHTTPServer | None = None
    failure_server: ThreadingHTTPServer | None = None
    try:
        server, base_url = start_add_credits_nudge_backend()
        access_token = write_chatgpt_home(chatgpt_home, base_url)
        sent = request(chatgpt_home, "add-credits-sent", {"creditType": "usage_limit"})
        assert sent["id"] == "add-credits-sent"
        assert sent["result"] == {"status": "sent"}
        assert AddCreditsNudgeBackendHandler.requests == [
            {
                "path": "/api/codex/accounts/send_add_credits_nudge_email",
                "authorization": f"Bearer {access_token}",
                "account_id": "acct_123",
                "content_type": "application/json",
                "body": {"credit_type": "usage_limit"},
            }
        ]

        agent_token = write_agent_identity_home(agent_identity_home, base_url)
        agent_sent = request(agent_identity_home, "add-credits-agent", {"creditType": "credits"})
        assert agent_sent["id"] == "add-credits-agent"
        assert agent_sent["result"] == {"status": "sent"}
        assert AddCreditsNudgeBackendHandler.requests[-1] == {
            "path": "/api/codex/accounts/send_add_credits_nudge_email",
            "authorization": f"Bearer {agent_token}",
            "account_id": "acct_agent",
            "content_type": "application/json",
            "body": {"credit_type": "credits"},
        }
        server.shutdown()
        server.server_close()
        server = None

        cooldown_server, cooldown_base_url = start_add_credits_nudge_backend(429)
        write_chatgpt_home(cooldown_home, cooldown_base_url)
        cooldown = request(cooldown_home, "add-credits-cooldown", {"creditType": "credits"})
        assert cooldown["id"] == "add-credits-cooldown"
        assert cooldown["result"] == {"status": "cooldown_active"}
        cooldown_server.shutdown()
        cooldown_server.server_close()
        cooldown_server = None

        failure_server, failure_base_url = start_add_credits_nudge_backend(500)
        write_chatgpt_home(failure_home, failure_base_url)
        failure = request(failure_home, "add-credits-failure", {"creditType": "credits"})
        assert failure["id"] == "add-credits-failure"
        assert failure["error"]["code"] == -32603
        assert "failed to notify workspace owner" in failure["error"]["message"]
        failure_server.shutdown()
        failure_server.server_close()
        failure_server = None

        no_auth = request(no_auth_home, "add-credits-no-auth", {"creditType": "credits"})
        assert no_auth["id"] == "add-credits-no-auth"
        assert no_auth["error"]["code"] == -32602
        assert "codex account authentication required" in no_auth["error"]["message"]

        (api_key_home / "auth.json").write_text(
            json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "test-api-key"}),
            encoding="utf-8",
        )
        api_key = request(api_key_home, "add-credits-api-key", {"creditType": "usage_limit"})
        assert api_key["id"] == "add-credits-api-key"
        assert api_key["error"]["code"] == -32602
        assert "chatgpt authentication required" in api_key["error"]["message"]

        invalid_type = request(no_auth_home, "add-credits-invalid-type", {"creditType": "tokens"})
        assert invalid_type["id"] == "add-credits-invalid-type"
        assert invalid_type["error"]["code"] == -32602

        invalid_params = request(no_auth_home, "add-credits-invalid-params", None)
        assert invalid_params["id"] == "add-credits-invalid-params"
        assert invalid_params["error"]["code"] == -32602
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        if cooldown_server is not None:
            cooldown_server.shutdown()
            cooldown_server.server_close()
        if failure_server is not None:
            failure_server.shutdown()
            failure_server.server_close()
        shutil.rmtree(chatgpt_home, ignore_errors=True)
        shutil.rmtree(agent_identity_home, ignore_errors=True)
        shutil.rmtree(cooldown_home, ignore_errors=True)
        shutil.rmtree(failure_home, ignore_errors=True)
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
    run_git_diff_to_remote_rpc_smoke(binary)
    print("app-server-git-diff-to-remote-rpc-e2e: ok")
    run_fuzzy_file_search_rpc_smoke(binary)
    print("app-server-fuzzy-file-search-rpc-e2e: ok")
    run_marketplace_rpc_smoke(binary)
    print("app-server-marketplace-rpc-e2e: ok")
    run_plugin_rpc_smoke(binary)
    print("app-server-plugin-rpc-e2e: ok")
    run_hooks_list_rpc_smoke(binary)
    print("app-server-hooks-list-rpc-e2e: ok")
    run_skills_list_rpc_smoke(binary)
    print("app-server-skills-list-rpc-e2e: ok")
    run_mcp_server_status_rpc_smoke(binary)
    print("app-server-mcp-server-status-rpc-e2e: ok")
    run_filesystem_rpc_smoke(binary)
    print("app-server-filesystem-rpc-e2e: ok")
    run_filesystem_watch_rpc_smoke(binary)
    print("app-server-filesystem-watch-rpc-e2e: ok")
    run_model_rpc_smoke(binary)
    print("app-server-model-rpc-e2e: ok")
    run_collaboration_mode_rpc_smoke(binary)
    print("app-server-collaboration-mode-rpc-e2e: ok")
    run_config_read_rpc_smoke(binary)
    print("app-server-config-read-rpc-e2e: ok")
    run_config_value_write_rpc_smoke(binary)
    print("app-server-config-value-write-rpc-e2e: ok")
    run_config_batch_write_rpc_smoke(binary)
    print("app-server-config-batch-write-rpc-e2e: ok")
    run_account_read_rpc_smoke(binary)
    print("app-server-account-read-rpc-e2e: ok")
    run_get_auth_status_rpc_smoke(binary)
    print("app-server-get-auth-status-rpc-e2e: ok")
    run_account_logout_rpc_smoke(binary)
    print("app-server-account-logout-rpc-e2e: ok")
    run_account_login_rpc_smoke(binary)
    print("app-server-account-login-rpc-e2e: ok")
    run_account_login_cancel_rpc_smoke(binary)
    print("app-server-account-login-cancel-rpc-e2e: ok")
    run_account_rate_limits_rpc_smoke(binary)
    print("app-server-account-rate-limits-rpc-e2e: ok")
    run_account_add_credits_nudge_rpc_smoke(binary)
    print("app-server-account-add-credits-nudge-rpc-e2e: ok")
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
