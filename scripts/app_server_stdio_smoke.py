#!/usr/bin/env python3
import base64
import io
import json
import os
import queue
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_OMIT = object()

EXPECTED_REALTIME_VOICES = {
    "v1": [
        "juniper",
        "maple",
        "spruce",
        "ember",
        "vale",
        "breeze",
        "arbor",
        "sol",
        "cove",
    ],
    "v2": [
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "sage",
        "shimmer",
        "verse",
        "marin",
        "cedar",
    ],
    "defaultV1": "cove",
    "defaultV2": "marin",
}
EXPECTED_REALTIME_VOICE_ENUM = sorted(
    EXPECTED_REALTIME_VOICES["v1"] + EXPECTED_REALTIME_VOICES["v2"]
)
EXPECTED_REALTIME_AUDIO_CHUNK = {
    "data": "BQYH",
    "sampleRate": 24000,
    "numChannels": 1,
    "samplesPerChannel": 480,
    "itemId": None,
}


class TurnResponsesHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.request_paths.append(self.path)
        self.server.request_bodies.append(json.loads(body))
        payload = self.server.response_payloads.pop(0) if self.server.response_payloads else (
            b'data: {"type":"response.output_text.delta","delta":"app turn reply"}\n\n'
            b"data: [DONE]\n\n"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        return


class TurnResponsesServer(ThreadingHTTPServer):
    request_paths: list[str]
    request_bodies: list[dict]
    response_payloads: list[bytes]


def start_turn_responses_server() -> tuple[TurnResponsesServer, str]:
    server = TurnResponsesServer(("127.0.0.1", 0), TurnResponsesHandler)
    server.request_paths = []
    server.request_bodies = []
    server.response_payloads = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


def toml_quoted_key(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


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


class CommandExecNetworkHandler(BaseHTTPRequestHandler):
    requests: list[str] = []

    def do_GET(self) -> None:
        CommandExecNetworkHandler.requests.append(self.path)
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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


def assert_thread_started_notification(notification: dict, expected_thread: dict) -> None:
    assert notification["jsonrpc"] == "2.0"
    assert notification["method"] == "thread/started"
    notification_thread = notification["params"]["thread"]
    expected_notification_thread = dict(expected_thread)
    expected_notification_thread["turns"] = []
    assert notification_thread == expected_notification_thread


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

    write_line({"jsonrpc": "2.0", "id": "loaded-threads", "method": "thread/loaded/list"})
    loaded_threads = read_line()
    assert loaded_threads == {
        "jsonrpc": "2.0",
        "id": "loaded-threads",
        "result": {"data": [], "nextCursor": None},
    }

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "loaded-threads-paged",
            "method": "thread/loaded/list",
            "params": {"cursor": "thread_123", "limit": 1},
        }
    )
    loaded_threads_paged = read_line()
    assert loaded_threads_paged["id"] == "loaded-threads-paged"
    assert loaded_threads_paged["result"] == {"data": [], "nextCursor": None}

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-loaded-threads",
            "method": "thread/loaded/list",
            "params": {"limit": -1},
        }
    )
    bad_loaded_threads = read_line()
    assert bad_loaded_threads["id"] == "bad-loaded-threads"
    assert bad_loaded_threads["error"]["code"] == -32602
    assert "limit must be a non-negative integer or null" in bad_loaded_threads["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "too-large-loaded-threads-limit",
            "method": "thread/loaded/list",
            "params": {"limit": 4294967296},
        }
    )
    too_large_loaded_threads_limit = read_line()
    assert too_large_loaded_threads_limit["id"] == "too-large-loaded-threads-limit"
    assert too_large_loaded_threads_limit["error"]["code"] == -32602
    assert (
        "limit must be a non-negative integer or null"
        in too_large_loaded_threads_limit["error"]["message"]
    )

    with tempfile.TemporaryDirectory(prefix="codex-zig-thread-start-", dir="/tmp") as thread_cwd:
        thread_cwd_real = os.path.realpath(thread_cwd)
        write_line(
            {
                "jsonrpc": "2.0",
                "id": "thread-start",
                "method": "thread/start",
                "params": {
                    "cwd": thread_cwd,
                    "model": "gpt-test",
                    "modelProvider": "mock_provider",
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "sandbox": "danger-full-access",
                    "ephemeral": True,
                    "threadSource": "user",
                },
            }
        )
        thread_start = read_line()
        assert thread_start["id"] == "thread-start"
        start_result = thread_start["result"]
        started_thread = start_result["thread"]
        thread_id = started_thread["id"]
        assert isinstance(thread_id, str)
        assert len(thread_id) == 36
        assert started_thread["sessionId"] == thread_id
        assert started_thread["preview"] == ""
        assert started_thread["ephemeral"] is True
        assert started_thread["status"] == {"type": "idle"}
        assert started_thread["path"] is None
        assert started_thread["cwd"] == thread_cwd_real
        assert started_thread["source"] == "appServer"
        assert started_thread["threadSource"] == "user"
        assert started_thread["turns"] == []
        assert start_result["model"] == "gpt-test"
        assert start_result["modelProvider"] == "mock_provider"
        assert start_result["cwd"] == thread_cwd_real
        assert start_result["approvalPolicy"] == "never"
        assert start_result["approvalsReviewer"] == "user"
        assert start_result["sandbox"] == {"type": "dangerFullAccess"}
        assert_thread_started_notification(read_line(), started_thread)

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "loaded-threads-after-start",
                "method": "thread/loaded/list",
            }
        )
        loaded_threads_after_start = read_line()
        assert loaded_threads_after_start["id"] == "loaded-threads-after-start"
        assert loaded_threads_after_start["result"] == {
            "data": [thread_id],
            "nextCursor": None,
        }

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "thread-fork",
                "method": "thread/fork",
                "params": {
                    "threadId": thread_id,
                    "model": "gpt-fork",
                    "ephemeral": True,
                    "threadSource": "user",
                },
            }
        )
        thread_fork = read_line()
        assert thread_fork["id"] == "thread-fork"
        fork_result = thread_fork["result"]
        forked_thread = fork_result["thread"]
        forked_thread_id = forked_thread["id"]
        assert isinstance(forked_thread_id, str)
        assert len(forked_thread_id) == 36
        assert forked_thread_id != thread_id
        assert forked_thread["sessionId"] == forked_thread_id
        assert forked_thread["forkedFromId"] == thread_id
        assert forked_thread["preview"] == started_thread["preview"]
        assert forked_thread["ephemeral"] is True
        assert forked_thread["path"] is None
        assert forked_thread["source"] == "appServer"
        assert forked_thread["threadSource"] == "user"
        assert forked_thread["turns"] == []
        assert fork_result["model"] == "gpt-fork"
        assert fork_result["modelProvider"] == "mock_provider"
        assert_thread_started_notification(read_line(), forked_thread)

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "loaded-threads-after-fork",
                "method": "thread/loaded/list",
            }
        )
        loaded_threads_after_fork = read_line()
        assert loaded_threads_after_fork["id"] == "loaded-threads-after-fork"
        assert loaded_threads_after_fork["result"] == {
            "data": sorted([thread_id, forked_thread_id]),
            "nextCursor": None,
        }

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "thread-fork-missing",
                "method": "thread/fork",
                "params": {"threadId": "00000000-0000-0000-0000-000000000012"},
            }
        )
        thread_fork_missing = read_line()
        assert thread_fork_missing["id"] == "thread-fork-missing"
        assert thread_fork_missing["error"]["code"] == -32600
        assert (
            "thread not found: 00000000-0000-0000-0000-000000000012"
            in thread_fork_missing["error"]["message"]
        )

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "thread-fork-invalid",
                "method": "thread/fork",
                "params": {"threadId": "not-a-uuid"},
            }
        )
        thread_fork_invalid = read_line()
        assert thread_fork_invalid["id"] == "thread-fork-invalid"
        assert thread_fork_invalid["error"]["code"] == -32600
        assert "invalid thread id: not-a-uuid" in thread_fork_invalid["error"]["message"]

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "read-started-thread",
                "method": "thread/read",
                "params": {"threadId": thread_id, "includeTurns": False},
            }
        )
        read_started_thread = read_line()
        assert read_started_thread["id"] == "read-started-thread"
        assert read_started_thread["result"]["thread"]["id"] == thread_id
        assert read_started_thread["result"]["thread"]["status"] == {"type": "idle"}

        write_line(
            {
                "jsonrpc": "2.0",
                "id": "unsubscribe-started-thread",
                "method": "thread/unsubscribe",
                "params": {"threadId": thread_id},
            }
        )
        unsubscribe_started_thread = read_line()
        assert unsubscribe_started_thread["id"] == "unsubscribe-started-thread"
        assert unsubscribe_started_thread["result"] == {"status": "notSubscribed"}

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-list-empty",
            "method": "thread/list",
            "params": {
                "cursor": None,
                "limit": 2,
                "sortKey": "updated_at",
                "sortDirection": "asc",
                "modelProviders": ["openai"],
                "sourceKinds": ["cli", "appServer"],
                "archived": False,
                "cwd": ["/tmp"],
                "useStateDbOnly": True,
                "searchTerm": "demo",
            },
        }
    )
    thread_list_empty = read_line()
    assert thread_list_empty == {
        "jsonrpc": "2.0",
        "id": "thread-list-empty",
        "result": {"data": [], "nextCursor": None, "backwardsCursor": None},
    }

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-thread-list-sort",
            "method": "thread/list",
            "params": {"sortKey": "createdAt"},
        }
    )
    bad_thread_list_sort = read_line()
    assert bad_thread_list_sort["id"] == "bad-thread-list-sort"
    assert bad_thread_list_sort["error"]["code"] == -32602
    assert "sortKey must be created_at or updated_at" in bad_thread_list_sort["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-thread-list-state-db-only",
            "method": "thread/list",
            "params": {"useStateDbOnly": None},
        }
    )
    bad_thread_list_state_db_only = read_line()
    assert bad_thread_list_state_db_only["id"] == "bad-thread-list-state-db-only"
    assert bad_thread_list_state_db_only["error"]["code"] == -32602
    assert (
        "useStateDbOnly must be a boolean"
        in bad_thread_list_state_db_only["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-unsubscribe",
            "method": "thread/unsubscribe",
            "params": {"threadId": "00000000-0000-0000-0000-000000000001"},
        }
    )
    thread_unsubscribe = read_line()
    assert thread_unsubscribe == {
        "jsonrpc": "2.0",
        "id": "thread-unsubscribe",
        "result": {"status": "notLoaded"},
    }

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-thread-unsubscribe",
            "method": "thread/unsubscribe",
            "params": {},
        }
    )
    bad_thread_unsubscribe = read_line()
    assert bad_thread_unsubscribe["id"] == "bad-thread-unsubscribe"
    assert bad_thread_unsubscribe["error"]["code"] == -32602
    assert "threadId must be a string" in bad_thread_unsubscribe["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "invalid-thread-unsubscribe",
            "method": "thread/unsubscribe",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    invalid_thread_unsubscribe = read_line()
    assert invalid_thread_unsubscribe["id"] == "invalid-thread-unsubscribe"
    assert invalid_thread_unsubscribe["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in invalid_thread_unsubscribe["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-thread-archive",
            "method": "thread/archive",
            "params": {},
        }
    )
    bad_thread_archive = read_line()
    assert bad_thread_archive["id"] == "bad-thread-archive"
    assert bad_thread_archive["error"]["code"] == -32602
    assert "threadId must be a string" in bad_thread_archive["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "invalid-thread-archive",
            "method": "thread/archive",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    invalid_thread_archive = read_line()
    assert invalid_thread_archive["id"] == "invalid-thread-archive"
    assert invalid_thread_archive["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in invalid_thread_archive["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-archive-missing",
            "method": "thread/archive",
            "params": {"threadId": "00000000-0000-0000-0000-000000000013"},
        }
    )
    thread_archive_missing = read_line()
    assert thread_archive_missing["id"] == "thread-archive-missing"
    assert thread_archive_missing["error"]["code"] == -32600
    assert (
        "no rollout found for thread id 00000000-0000-0000-0000-000000000013"
        in thread_archive_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "bad-thread-unarchive",
            "method": "thread/unarchive",
            "params": {},
        }
    )
    bad_thread_unarchive = read_line()
    assert bad_thread_unarchive["id"] == "bad-thread-unarchive"
    assert bad_thread_unarchive["error"]["code"] == -32602
    assert "threadId must be a string" in bad_thread_unarchive["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "invalid-thread-unarchive",
            "method": "thread/unarchive",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    invalid_thread_unarchive = read_line()
    assert invalid_thread_unarchive["id"] == "invalid-thread-unarchive"
    assert invalid_thread_unarchive["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in invalid_thread_unarchive["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-unarchive-missing",
            "method": "thread/unarchive",
            "params": {"threadId": "00000000-0000-0000-0000-000000000014"},
        }
    )
    thread_unarchive_missing = read_line()
    assert thread_unarchive_missing["id"] == "thread-unarchive-missing"
    assert thread_unarchive_missing["error"]["code"] == -32600
    assert (
        "no archived rollout found for thread id 00000000-0000-0000-0000-000000000014"
        in thread_unarchive_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-compact-missing",
            "method": "thread/compact/start",
            "params": {"threadId": "00000000-0000-0000-0000-000000000002"},
        }
    )
    thread_compact_missing = read_line()
    assert thread_compact_missing["id"] == "thread-compact-missing"
    assert thread_compact_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000002"
        in thread_compact_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-compact-invalid",
            "method": "thread/compact/start",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_compact_invalid = read_line()
    assert thread_compact_invalid["id"] == "thread-compact-invalid"
    assert thread_compact_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_compact_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-shell-empty",
            "method": "thread/shellCommand",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000003",
                "command": "   ",
            },
        }
    )
    thread_shell_empty = read_line()
    assert thread_shell_empty["id"] == "thread-shell-empty"
    assert thread_shell_empty["error"]["code"] == -32600
    assert "command must not be empty" in thread_shell_empty["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-shell-invalid",
            "method": "thread/shellCommand",
            "params": {"threadId": "not-a-uuid", "command": "echo hello"},
        }
    )
    thread_shell_invalid = read_line()
    assert thread_shell_invalid["id"] == "thread-shell-invalid"
    assert thread_shell_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_shell_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-shell-missing",
            "method": "thread/shellCommand",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000003",
                "command": "echo hello",
            },
        }
    )
    thread_shell_missing = read_line()
    assert thread_shell_missing["id"] == "thread-shell-missing"
    assert thread_shell_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000003"
        in thread_shell_missing["error"]["message"]
    )

    guardian_event = {
        "id": "guardian-1",
        "turn_id": "turn-1",
        "status": "denied",
        "risk_level": "high",
        "user_authorization": "low",
        "rationale": "requires approval",
        "decision_source": "agent",
        "action": {
            "type": "command",
            "source": "shell",
            "command": "echo hello",
            "cwd": "/tmp",
        },
    }
    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-guardian-approval-missing",
            "method": "thread/approveGuardianDeniedAction",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000015",
                "event": guardian_event,
            },
        }
    )
    thread_guardian_approval_missing = read_line()
    assert thread_guardian_approval_missing["id"] == "thread-guardian-approval-missing"
    assert thread_guardian_approval_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000015"
        in thread_guardian_approval_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-guardian-approval-invalid-event",
            "method": "thread/approveGuardianDeniedAction",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000015",
                "event": {"id": "guardian-1"},
            },
        }
    )
    thread_guardian_approval_invalid_event = read_line()
    assert (
        thread_guardian_approval_invalid_event["id"]
        == "thread-guardian-approval-invalid-event"
    )
    assert thread_guardian_approval_invalid_event["error"]["code"] == -32600
    assert (
        "invalid Guardian denial event"
        in thread_guardian_approval_invalid_event["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-guardian-approval-missing-event",
            "method": "thread/approveGuardianDeniedAction",
            "params": {"threadId": "00000000-0000-0000-0000-000000000015"},
        }
    )
    thread_guardian_approval_missing_event = read_line()
    assert (
        thread_guardian_approval_missing_event["id"]
        == "thread-guardian-approval-missing-event"
    )
    assert thread_guardian_approval_missing_event["error"]["code"] == -32602
    assert (
        "event must be a Guardian denial event"
        in thread_guardian_approval_missing_event["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-guardian-approval-invalid-thread",
            "method": "thread/approveGuardianDeniedAction",
            "params": {"threadId": "not-a-uuid", "event": guardian_event},
        }
    )
    thread_guardian_approval_invalid_thread = read_line()
    assert (
        thread_guardian_approval_invalid_thread["id"]
        == "thread-guardian-approval-invalid-thread"
    )
    assert thread_guardian_approval_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_guardian_approval_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-background-clean-invalid",
            "method": "thread/backgroundTerminals/clean",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_background_clean_invalid = read_line()
    assert thread_background_clean_invalid["id"] == "thread-background-clean-invalid"
    assert thread_background_clean_invalid["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_background_clean_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-background-clean-missing",
            "method": "thread/backgroundTerminals/clean",
            "params": {"threadId": "00000000-0000-0000-0000-000000000004"},
        }
    )
    thread_background_clean_missing = read_line()
    assert thread_background_clean_missing["id"] == "thread-background-clean-missing"
    assert thread_background_clean_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000004"
        in thread_background_clean_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-increment-elicitation-invalid",
            "method": "thread/increment_elicitation",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_increment_elicitation_invalid = read_line()
    assert (
        thread_increment_elicitation_invalid["id"]
        == "thread-increment-elicitation-invalid"
    )
    assert thread_increment_elicitation_invalid["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_increment_elicitation_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-increment-elicitation-missing",
            "method": "thread/increment_elicitation",
            "params": {"threadId": "00000000-0000-0000-0000-000000000005"},
        }
    )
    thread_increment_elicitation_missing = read_line()
    assert (
        thread_increment_elicitation_missing["id"]
        == "thread-increment-elicitation-missing"
    )
    assert thread_increment_elicitation_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000005"
        in thread_increment_elicitation_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-decrement-elicitation-invalid",
            "method": "thread/decrement_elicitation",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_decrement_elicitation_invalid = read_line()
    assert (
        thread_decrement_elicitation_invalid["id"]
        == "thread-decrement-elicitation-invalid"
    )
    assert thread_decrement_elicitation_invalid["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_decrement_elicitation_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-decrement-elicitation-missing",
            "method": "thread/decrement_elicitation",
            "params": {"threadId": "00000000-0000-0000-0000-000000000006"},
        }
    )
    thread_decrement_elicitation_missing = read_line()
    assert (
        thread_decrement_elicitation_missing["id"]
        == "thread-decrement-elicitation-missing"
    )
    assert thread_decrement_elicitation_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000006"
        in thread_decrement_elicitation_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-rollback-zero",
            "method": "thread/rollback",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000007",
                "numTurns": 0,
            },
        }
    )
    thread_rollback_zero = read_line()
    assert thread_rollback_zero["id"] == "thread-rollback-zero"
    assert thread_rollback_zero["error"]["code"] == -32600
    assert "numTurns must be >= 1" in thread_rollback_zero["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-rollback-invalid",
            "method": "thread/rollback",
            "params": {"threadId": "not-a-uuid", "numTurns": 1},
        }
    )
    thread_rollback_invalid = read_line()
    assert thread_rollback_invalid["id"] == "thread-rollback-invalid"
    assert thread_rollback_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_rollback_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-rollback-missing",
            "method": "thread/rollback",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000007",
                "numTurns": 1,
            },
        }
    )
    thread_rollback_missing = read_line()
    assert thread_rollback_missing["id"] == "thread-rollback-missing"
    assert thread_rollback_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000007"
        in thread_rollback_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-inject-invalid",
            "method": "thread/inject_items",
            "params": {"threadId": "not-a-uuid", "items": []},
        }
    )
    thread_inject_items_invalid = read_line()
    assert thread_inject_items_invalid["id"] == "thread-inject-invalid"
    assert thread_inject_items_invalid["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_inject_items_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-inject-items-invalid",
            "method": "thread/inject_items",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000008",
                "items": {},
            },
        }
    )
    thread_inject_items_shape = read_line()
    assert thread_inject_items_shape["id"] == "thread-inject-items-invalid"
    assert thread_inject_items_shape["error"]["code"] == -32602
    assert "items must be an array" in thread_inject_items_shape["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-inject-items-missing",
            "method": "thread/inject_items",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000008",
                "items": [],
            },
        }
    )
    thread_inject_items_missing = read_line()
    assert thread_inject_items_missing["id"] == "thread-inject-items-missing"
    assert thread_inject_items_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000008"
        in thread_inject_items_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-name-empty",
            "method": "thread/name/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000009",
                "name": "   ",
            },
        }
    )
    thread_name_empty = read_line()
    assert thread_name_empty["id"] == "thread-name-empty"
    assert thread_name_empty["error"]["code"] == -32600
    assert "thread name must not be empty" in thread_name_empty["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-name-invalid",
            "method": "thread/name/set",
            "params": {"threadId": "not-a-uuid", "name": "Demo"},
        }
    )
    thread_name_invalid = read_line()
    assert thread_name_invalid["id"] == "thread-name-invalid"
    assert thread_name_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_name_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-name-missing",
            "method": "thread/name/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000009",
                "name": "Demo",
            },
        }
    )
    thread_name_missing = read_line()
    assert thread_name_missing["id"] == "thread-name-missing"
    assert thread_name_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000009"
        in thread_name_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-memory-mode-invalid-mode",
            "method": "thread/memoryMode/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000010",
                "mode": "unknown",
            },
        }
    )
    thread_memory_mode_invalid_mode = read_line()
    assert thread_memory_mode_invalid_mode["id"] == "thread-memory-mode-invalid-mode"
    assert thread_memory_mode_invalid_mode["error"]["code"] == -32602
    assert (
        "mode must be enabled or disabled"
        in thread_memory_mode_invalid_mode["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-memory-mode-invalid",
            "method": "thread/memoryMode/set",
            "params": {"threadId": "not-a-uuid", "mode": "enabled"},
        }
    )
    thread_memory_mode_invalid = read_line()
    assert thread_memory_mode_invalid["id"] == "thread-memory-mode-invalid"
    assert thread_memory_mode_invalid["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_memory_mode_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-memory-mode-missing",
            "method": "thread/memoryMode/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000010",
                "mode": "disabled",
            },
        }
    )
    thread_memory_mode_missing = read_line()
    assert thread_memory_mode_missing["id"] == "thread-memory-mode-missing"
    assert thread_memory_mode_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000010"
        in thread_memory_mode_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-enable-feature",
            "method": "experimentalFeature/enablement/set",
            "params": {"enablement": {"goals": True}},
        }
    )
    thread_goal_enable_feature = read_line()
    assert thread_goal_enable_feature["id"] == "thread-goal-enable-feature"
    assert thread_goal_enable_feature["result"]["enablement"] == {"goals": True}

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-invalid-params",
            "method": "thread/goal/set",
            "params": [],
        }
    )
    thread_goal_set_invalid_params = read_line()
    assert thread_goal_set_invalid_params["id"] == "thread-goal-set-invalid-params"
    assert thread_goal_set_invalid_params["error"]["code"] == -32602
    assert (
        "thread/goal/set params must be an object"
        in thread_goal_set_invalid_params["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-empty-objective",
            "method": "thread/goal/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "objective": "   ",
            },
        }
    )
    thread_goal_set_empty_objective = read_line()
    assert thread_goal_set_empty_objective["id"] == "thread-goal-set-empty-objective"
    assert thread_goal_set_empty_objective["error"]["code"] == -32600
    assert (
        "goal objective must not be empty"
        in thread_goal_set_empty_objective["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-invalid-status",
            "method": "thread/goal/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "status": "done",
            },
        }
    )
    thread_goal_set_invalid_status = read_line()
    assert thread_goal_set_invalid_status["id"] == "thread-goal-set-invalid-status"
    assert thread_goal_set_invalid_status["error"]["code"] == -32600
    assert (
        "goal status must be active, paused, budgetLimited, complete, or null"
        in thread_goal_set_invalid_status["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-invalid-budget",
            "method": "thread/goal/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "objective": "ship the zig port",
                "tokenBudget": 0,
            },
        }
    )
    thread_goal_set_invalid_budget = read_line()
    assert thread_goal_set_invalid_budget["id"] == "thread-goal-set-invalid-budget"
    assert thread_goal_set_invalid_budget["error"]["code"] == -32600
    assert (
        "goal budgets must be positive when provided"
        in thread_goal_set_invalid_budget["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-invalid-thread",
            "method": "thread/goal/set",
            "params": {
                "threadId": "not-a-uuid",
                "objective": "ship the zig port",
                "status": "active",
                "tokenBudget": 1000,
            },
        }
    )
    thread_goal_set_invalid_thread = read_line()
    assert thread_goal_set_invalid_thread["id"] == "thread-goal-set-invalid-thread"
    assert thread_goal_set_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_goal_set_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-set-missing",
            "method": "thread/goal/set",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "objective": "ship the zig port",
                "status": "active",
                "tokenBudget": 1000,
            },
        }
    )
    thread_goal_set_missing = read_line()
    assert thread_goal_set_missing["id"] == "thread-goal-set-missing"
    assert thread_goal_set_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000011"
        in thread_goal_set_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-get-missing",
            "method": "thread/goal/get",
            "params": {"threadId": "00000000-0000-0000-0000-000000000011"},
        }
    )
    thread_goal_get_missing = read_line()
    assert thread_goal_get_missing["id"] == "thread-goal-get-missing"
    assert thread_goal_get_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000011"
        in thread_goal_get_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-goal-clear-missing",
            "method": "thread/goal/clear",
            "params": {"threadId": "00000000-0000-0000-0000-000000000011"},
        }
    )
    thread_goal_clear_missing = read_line()
    assert thread_goal_clear_missing["id"] == "thread-goal-clear-missing"
    assert thread_goal_clear_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000011"
        in thread_goal_clear_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-metadata-no-git-info",
            "method": "thread/metadata/update",
            "params": {"threadId": "00000000-0000-0000-0000-000000000011"},
        }
    )
    thread_metadata_no_git_info = read_line()
    assert thread_metadata_no_git_info["id"] == "thread-metadata-no-git-info"
    assert thread_metadata_no_git_info["error"]["code"] == -32600
    assert (
        "gitInfo must include at least one field"
        in thread_metadata_no_git_info["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-metadata-empty-sha",
            "method": "thread/metadata/update",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "gitInfo": {"sha": "   "},
            },
        }
    )
    thread_metadata_empty_sha = read_line()
    assert thread_metadata_empty_sha["id"] == "thread-metadata-empty-sha"
    assert thread_metadata_empty_sha["error"]["code"] == -32600
    assert (
        "gitInfo.sha must not be empty"
        in thread_metadata_empty_sha["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-metadata-invalid",
            "method": "thread/metadata/update",
            "params": {"threadId": "not-a-uuid", "gitInfo": {"branch": "main"}},
        }
    )
    thread_metadata_invalid = read_line()
    assert thread_metadata_invalid["id"] == "thread-metadata-invalid"
    assert thread_metadata_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_metadata_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-metadata-missing",
            "method": "thread/metadata/update",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000011",
                "gitInfo": {"originUrl": "https://example.test/repo.git"},
            },
        }
    )
    thread_metadata_missing = read_line()
    assert thread_metadata_missing["id"] == "thread-metadata-missing"
    assert thread_metadata_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000011"
        in thread_metadata_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-read-invalid-include-turns",
            "method": "thread/read",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000012",
                "includeTurns": "yes",
            },
        }
    )
    thread_read_invalid_include_turns = read_line()
    assert thread_read_invalid_include_turns["id"] == "thread-read-invalid-include-turns"
    assert thread_read_invalid_include_turns["error"]["code"] == -32602
    assert (
        "includeTurns must be a boolean"
        in thread_read_invalid_include_turns["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-read-invalid",
            "method": "thread/read",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_read_invalid = read_line()
    assert thread_read_invalid["id"] == "thread-read-invalid"
    assert thread_read_invalid["error"]["code"] == -32600
    assert "invalid thread id: not-a-uuid" in thread_read_invalid["error"]["message"]

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-read-missing",
            "method": "thread/read",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000012",
                "includeTurns": True,
            },
        }
    )
    thread_read_missing = read_line()
    assert thread_read_missing["id"] == "thread-read-missing"
    assert thread_read_missing["error"]["code"] == -32600
    assert (
        "thread not loaded: 00000000-0000-0000-0000-000000000012"
        in thread_read_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-turns-list-invalid-sort",
            "method": "thread/turns/list",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000013",
                "sortDirection": "ascending",
            },
        }
    )
    thread_turns_list_invalid_sort = read_line()
    assert thread_turns_list_invalid_sort["id"] == "thread-turns-list-invalid-sort"
    assert thread_turns_list_invalid_sort["error"]["code"] == -32602
    assert (
        "sortDirection must be asc or desc"
        in thread_turns_list_invalid_sort["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-turns-list-invalid-limit",
            "method": "thread/turns/list",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000013",
                "limit": -1,
            },
        }
    )
    thread_turns_list_invalid_limit = read_line()
    assert thread_turns_list_invalid_limit["id"] == "thread-turns-list-invalid-limit"
    assert thread_turns_list_invalid_limit["error"]["code"] == -32602
    assert (
        "limit must be a non-negative integer or null"
        in thread_turns_list_invalid_limit["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-turns-list-invalid-thread",
            "method": "thread/turns/list",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_turns_list_invalid_thread = read_line()
    assert thread_turns_list_invalid_thread["id"] == "thread-turns-list-invalid-thread"
    assert thread_turns_list_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_turns_list_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-turns-list-missing",
            "method": "thread/turns/list",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000013",
                "cursor": None,
                "limit": 3,
                "sortDirection": "asc",
            },
        }
    )
    thread_turns_list_missing = read_line()
    assert thread_turns_list_missing["id"] == "thread-turns-list-missing"
    assert thread_turns_list_missing["error"]["code"] == -32600
    assert (
        "thread not loaded: 00000000-0000-0000-0000-000000000013"
        in thread_turns_list_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-list-voices-invalid",
            "method": "thread/realtime/listVoices",
            "params": [],
        }
    )
    thread_realtime_list_voices_invalid = read_line()
    assert (
        thread_realtime_list_voices_invalid["id"]
        == "thread-realtime-list-voices-invalid"
    )
    assert thread_realtime_list_voices_invalid["error"]["code"] == -32602
    assert (
        "thread/realtime/listVoices params must be an object"
        in thread_realtime_list_voices_invalid["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-list-voices",
            "method": "thread/realtime/listVoices",
            "params": {},
        }
    )
    thread_realtime_list_voices = read_line()
    assert thread_realtime_list_voices["id"] == "thread-realtime-list-voices"
    assert thread_realtime_list_voices["result"]["voices"] == EXPECTED_REALTIME_VOICES

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-start-invalid-params",
            "method": "thread/realtime/start",
            "params": [],
        }
    )
    thread_realtime_start_invalid_params = read_line()
    assert (
        thread_realtime_start_invalid_params["id"]
        == "thread-realtime-start-invalid-params"
    )
    assert thread_realtime_start_invalid_params["error"]["code"] == -32602
    assert (
        "thread/realtime/start params must be an object"
        in thread_realtime_start_invalid_params["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-start-invalid-output",
            "method": "thread/realtime/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000017",
                "outputModality": "video",
            },
        }
    )
    thread_realtime_start_invalid_output = read_line()
    assert (
        thread_realtime_start_invalid_output["id"]
        == "thread-realtime-start-invalid-output"
    )
    assert thread_realtime_start_invalid_output["error"]["code"] == -32602
    assert (
        "outputModality must be text or audio"
        in thread_realtime_start_invalid_output["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-start-invalid-transport",
            "method": "thread/realtime/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000017",
                "outputModality": "audio",
                "transport": {"type": "webrtc"},
            },
        }
    )
    thread_realtime_start_invalid_transport = read_line()
    assert (
        thread_realtime_start_invalid_transport["id"]
        == "thread-realtime-start-invalid-transport"
    )
    assert thread_realtime_start_invalid_transport["error"]["code"] == -32602
    assert (
        "transport.sdp must be a string"
        in thread_realtime_start_invalid_transport["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-start-invalid-thread",
            "method": "thread/realtime/start",
            "params": {
                "threadId": "not-a-uuid",
                "outputModality": "audio",
                "prompt": None,
                "realtimeSessionId": None,
                "transport": {"type": "websocket"},
                "voice": "marin",
            },
        }
    )
    thread_realtime_start_invalid_thread = read_line()
    assert (
        thread_realtime_start_invalid_thread["id"]
        == "thread-realtime-start-invalid-thread"
    )
    assert thread_realtime_start_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_realtime_start_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-start-missing",
            "method": "thread/realtime/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000017",
                "outputModality": "audio",
                "prompt": "hello",
                "realtimeSessionId": "session-1",
                "transport": {"type": "webrtc", "sdp": "v=0\\r\\n"},
                "voice": "marin",
            },
        }
    )
    thread_realtime_start_missing = read_line()
    assert thread_realtime_start_missing["id"] == "thread-realtime-start-missing"
    assert thread_realtime_start_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000017"
        in thread_realtime_start_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-stop-invalid-params",
            "method": "thread/realtime/stop",
            "params": [],
        }
    )
    thread_realtime_stop_invalid_params = read_line()
    assert (
        thread_realtime_stop_invalid_params["id"]
        == "thread-realtime-stop-invalid-params"
    )
    assert thread_realtime_stop_invalid_params["error"]["code"] == -32602
    assert (
        "thread/realtime/stop params must be an object"
        in thread_realtime_stop_invalid_params["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-stop-invalid-thread",
            "method": "thread/realtime/stop",
            "params": {"threadId": "not-a-uuid"},
        }
    )
    thread_realtime_stop_invalid_thread = read_line()
    assert (
        thread_realtime_stop_invalid_thread["id"]
        == "thread-realtime-stop-invalid-thread"
    )
    assert thread_realtime_stop_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_realtime_stop_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-stop-missing",
            "method": "thread/realtime/stop",
            "params": {"threadId": "00000000-0000-0000-0000-000000000014"},
        }
    )
    thread_realtime_stop_missing = read_line()
    assert thread_realtime_stop_missing["id"] == "thread-realtime-stop-missing"
    assert thread_realtime_stop_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000014"
        in thread_realtime_stop_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-text-invalid-params",
            "method": "thread/realtime/appendText",
            "params": [],
        }
    )
    thread_realtime_append_text_invalid_params = read_line()
    assert (
        thread_realtime_append_text_invalid_params["id"]
        == "thread-realtime-append-text-invalid-params"
    )
    assert thread_realtime_append_text_invalid_params["error"]["code"] == -32602
    assert (
        "thread/realtime/appendText params must be an object"
        in thread_realtime_append_text_invalid_params["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-text-invalid-text",
            "method": "thread/realtime/appendText",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000015",
                "text": 123,
            },
        }
    )
    thread_realtime_append_text_invalid_text = read_line()
    assert (
        thread_realtime_append_text_invalid_text["id"]
        == "thread-realtime-append-text-invalid-text"
    )
    assert thread_realtime_append_text_invalid_text["error"]["code"] == -32602
    assert (
        "text must be a string"
        in thread_realtime_append_text_invalid_text["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-text-invalid-thread",
            "method": "thread/realtime/appendText",
            "params": {"threadId": "not-a-uuid", "text": "hello"},
        }
    )
    thread_realtime_append_text_invalid_thread = read_line()
    assert (
        thread_realtime_append_text_invalid_thread["id"]
        == "thread-realtime-append-text-invalid-thread"
    )
    assert thread_realtime_append_text_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_realtime_append_text_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-text-missing",
            "method": "thread/realtime/appendText",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000015",
                "text": "hello",
            },
        }
    )
    thread_realtime_append_text_missing = read_line()
    assert (
        thread_realtime_append_text_missing["id"]
        == "thread-realtime-append-text-missing"
    )
    assert thread_realtime_append_text_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000015"
        in thread_realtime_append_text_missing["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-audio-invalid-params",
            "method": "thread/realtime/appendAudio",
            "params": [],
        }
    )
    thread_realtime_append_audio_invalid_params = read_line()
    assert (
        thread_realtime_append_audio_invalid_params["id"]
        == "thread-realtime-append-audio-invalid-params"
    )
    assert thread_realtime_append_audio_invalid_params["error"]["code"] == -32602
    assert (
        "thread/realtime/appendAudio params must be an object"
        in thread_realtime_append_audio_invalid_params["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-audio-invalid-audio",
            "method": "thread/realtime/appendAudio",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000016",
                "audio": "not-a-chunk",
            },
        }
    )
    thread_realtime_append_audio_invalid_audio = read_line()
    assert (
        thread_realtime_append_audio_invalid_audio["id"]
        == "thread-realtime-append-audio-invalid-audio"
    )
    assert thread_realtime_append_audio_invalid_audio["error"]["code"] == -32602
    assert (
        "audio must be an object"
        in thread_realtime_append_audio_invalid_audio["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-audio-invalid-sample-rate",
            "method": "thread/realtime/appendAudio",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000016",
                "audio": {
                    **EXPECTED_REALTIME_AUDIO_CHUNK,
                    "sampleRate": -1,
                },
            },
        }
    )
    thread_realtime_append_audio_invalid_sample_rate = read_line()
    assert (
        thread_realtime_append_audio_invalid_sample_rate["id"]
        == "thread-realtime-append-audio-invalid-sample-rate"
    )
    assert thread_realtime_append_audio_invalid_sample_rate["error"]["code"] == -32602
    assert (
        "audio.sampleRate must be a non-negative integer"
        in thread_realtime_append_audio_invalid_sample_rate["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-audio-invalid-thread",
            "method": "thread/realtime/appendAudio",
            "params": {
                "threadId": "not-a-uuid",
                "audio": EXPECTED_REALTIME_AUDIO_CHUNK,
            },
        }
    )
    thread_realtime_append_audio_invalid_thread = read_line()
    assert (
        thread_realtime_append_audio_invalid_thread["id"]
        == "thread-realtime-append-audio-invalid-thread"
    )
    assert thread_realtime_append_audio_invalid_thread["error"]["code"] == -32600
    assert (
        "invalid thread id: not-a-uuid"
        in thread_realtime_append_audio_invalid_thread["error"]["message"]
    )

    write_line(
        {
            "jsonrpc": "2.0",
            "id": "thread-realtime-append-audio-missing",
            "method": "thread/realtime/appendAudio",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000016",
                "audio": EXPECTED_REALTIME_AUDIO_CHUNK,
            },
        }
    )
    thread_realtime_append_audio_missing = read_line()
    assert (
        thread_realtime_append_audio_missing["id"]
        == "thread-realtime-append-audio-missing"
    )
    assert thread_realtime_append_audio_missing["error"]["code"] == -32600
    assert (
        "thread not found: 00000000-0000-0000-0000-000000000016"
        in thread_realtime_append_audio_missing["error"]["message"]
    )


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


def run_thread_started_opt_out_smoke(binary: Path) -> None:
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
                "id": "initialize",
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "app-server-smoke", "version": "0"},
                    "capabilities": {
                        "optOutNotificationMethods": ["thread/started"],
                    },
                },
            },
        )
        initialized = read_json_line(proc, 5)
        assert initialized["id"] == "initialize"

        write_json_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": "thread-start-opted-out",
                "method": "thread/start",
                "params": {"ephemeral": True},
            },
        )
        started = read_json_line(proc, 5)
        assert started["id"] == "thread-start-opted-out"
        thread_id = started["result"]["thread"]["id"]

        write_json_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": "loaded-after-opted-out-start",
                "method": "thread/loaded/list",
            },
        )
        loaded = read_json_line(proc, 5)
        assert loaded["id"] == "loaded-after-opted-out-start"
        assert loaded["result"] == {"data": [thread_id], "nextCursor": None}

        assert proc.stdin is not None
        proc.stdin.close()
        proc.wait(timeout=5)
        if proc.returncode != 0:
            raise AssertionError(f"app-server exited {proc.returncode}: {proc.stderr.read()}")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def run_turn_start_rpc_smoke(binary: Path) -> None:
    server, base_url = start_turn_responses_server()
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-turn-start-", dir="/tmp"))
    try:
        codex_home.joinpath("config.toml").write_text(
            f'openai_base_url = "{base_url}"\nmodel = "gpt-turn-smoke"\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["OPENAI_API_KEY"] = "test-api-key"
        env.pop("CODEX_ACCESS_TOKEN", None)

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
                    "id": "initialize",
                    "method": "initialize",
                    "params": {
                        "clientInfo": {"name": "app-server-smoke", "version": "0"},
                        "capabilities": {},
                    },
                },
            )
            assert read_json_line(proc, 5)["id"] == "initialize"

            with tempfile.TemporaryDirectory(prefix="codex-zig-turn-start-cwd-", dir="/tmp") as cwd:
                write_json_line(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": "thread-start-for-turn",
                        "method": "thread/start",
                        "params": {
                            "cwd": cwd,
                            "approvalPolicy": "never",
                            "sandbox": "danger-full-access",
                        },
                    },
                )
                thread_start = read_json_line(proc, 5)
                assert thread_start["id"] == "thread-start-for-turn"
                thread = thread_start["result"]["thread"]
                thread_id = thread["id"]
                rollout_path = Path(thread["path"])
                assert rollout_path.name == f"rollout-{thread_id}.jsonl"
                assert_thread_started_notification(read_json_line(proc, 5), thread)

                prompt = "hello from app-server turn"
                write_json_line(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": "turn-start",
                        "method": "turn/start",
                        "params": {
                            "threadId": thread_id,
                            "input": [{"type": "text", "text": prompt}],
                        },
                    },
                )
                turn_start = read_json_line(proc, 5)
                assert turn_start["id"] == "turn-start"
                turn = turn_start["result"]["turn"]
                assert turn["id"] == "turn-0"
                assert turn["status"] == "inProgress"
                assert turn["items"] == []
                assert turn["itemsView"] == "notLoaded"
                assert turn["startedAt"] is None
                started = read_json_line(proc, 5)
                assert started["method"] == "turn/started"
                assert started["params"]["threadId"] == thread_id
                assert started["params"]["turn"]["id"] == "turn-0"
                assert started["params"]["turn"]["status"] == "inProgress"
                user_item_started = read_json_line(proc, 5)
                assert user_item_started["method"] == "item/started"
                assert user_item_started["params"]["threadId"] == thread_id
                assert user_item_started["params"]["turnId"] == "turn-0"
                assert isinstance(user_item_started["params"]["startedAtMs"], int)
                user_item = user_item_started["params"]["item"]
                assert user_item["type"] == "userMessage"
                assert user_item["id"] == "item-0"
                assert user_item["content"][0]["text"] == prompt
                user_item_completed = read_json_line(proc, 5)
                assert user_item_completed["method"] == "item/completed"
                assert user_item_completed["params"]["threadId"] == thread_id
                assert user_item_completed["params"]["turnId"] == "turn-0"
                assert isinstance(user_item_completed["params"]["completedAtMs"], int)
                assert user_item_completed["params"]["item"] == user_item
                agent_item_started = read_json_line(proc, 5)
                assert agent_item_started["method"] == "item/started"
                assert agent_item_started["params"]["threadId"] == thread_id
                assert agent_item_started["params"]["turnId"] == "turn-0"
                assert isinstance(agent_item_started["params"]["startedAtMs"], int)
                agent_item = agent_item_started["params"]["item"]
                assert agent_item["type"] == "agentMessage"
                assert agent_item["id"] == "item-1"
                assert agent_item["text"] == "app turn reply"
                agent_delta = read_json_line(proc, 5)
                assert agent_delta["method"] == "item/agentMessage/delta"
                assert agent_delta["params"] == {
                    "threadId": thread_id,
                    "turnId": "turn-0",
                    "itemId": "item-1",
                    "delta": "app turn reply",
                }
                agent_item_completed = read_json_line(proc, 5)
                assert agent_item_completed["method"] == "item/completed"
                assert agent_item_completed["params"]["threadId"] == thread_id
                assert agent_item_completed["params"]["turnId"] == "turn-0"
                assert isinstance(agent_item_completed["params"]["completedAtMs"], int)
                assert agent_item_completed["params"]["item"] == agent_item
                completed = read_json_line(proc, 5)
                assert completed["method"] == "turn/completed"
                assert completed["params"]["threadId"] == thread_id
                assert completed["params"]["turn"]["id"] == "turn-0"
                assert completed["params"]["turn"]["status"] == "completed"

                assert server.request_paths == ["/responses"]
                request = server.request_bodies[0]
                assert request["model"] == "gpt-turn-smoke"
                assert request["input"][0]["content"][0]["text"] == prompt

                write_json_line(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": "thread-read-after-turn",
                        "method": "thread/read",
                        "params": {"threadId": thread_id, "includeTurns": True},
                    },
                )
                read_after_turn = read_json_line(proc, 5)
                assert read_after_turn["id"] == "thread-read-after-turn"
                loaded_thread = read_after_turn["result"]["thread"]
                assert loaded_thread["preview"] == prompt
                assert loaded_thread["turns"][0]["items"][0]["content"][0]["text"] == prompt
                assert loaded_thread["turns"][1]["items"][0]["text"] == "app turn reply"
                stored = rollout_path.read_text(encoding="utf-8")
                assert prompt in stored
                assert "app turn reply" in stored

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
        server.shutdown()
        server.server_close()
        shutil.rmtree(codex_home, ignore_errors=True)


def run_thread_resume_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-resume-", dir="/tmp"))
    try:
        resume_thread_id = "11111111-1111-4111-8111-111111111111"
        sessions_dir = codex_home / "sessions" / "zig"
        sessions_dir.mkdir(parents=True)
        rollout_path = sessions_dir / f"rollout-{resume_thread_id}.jsonl"
        rollout_path.write_text(
            "\n".join(
                [
                    json.dumps(
                        {"type": "metadata", "title": "Resume Smoke"},
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        {
                            "type": "message",
                            "role": "user",
                            "content_type": "input_text",
                            "text": "saved hello",
                        },
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        {
                            "type": "message",
                            "role": "assistant",
                            "content_type": "output_text",
                            "text": "saved hi",
                        },
                        separators=(",", ":"),
                    ),
                    "",
                ]
            ),
            encoding="utf-8",
        )
        rust_thread_id = "22222222-2222-4222-8222-222222222222"
        rust_sessions_dir = codex_home / "sessions" / "2025" / "01" / "05"
        rust_sessions_dir.mkdir(parents=True)
        rust_rollout_path = (
            rust_sessions_dir
            / f"rollout-2025-01-05T12-00-00-{rust_thread_id}.jsonl"
        )
        rust_rollout_path.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "timestamp": "2025-01-05T12:00:00Z",
                            "type": "session_meta",
                            "payload": {
                                "id": rust_thread_id,
                                "timestamp": "2025-01-05T12:00:00Z",
                                "cwd": "/",
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
                            "timestamp": "2025-01-05T12:00:00Z",
                            "type": "response_item",
                            "payload": {
                                "type": "message",
                                "role": "user",
                                "content": [
                                    {
                                        "type": "input_text",
                                        "text": "rust rollout hello",
                                    }
                                ],
                            },
                        },
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        {
                            "timestamp": "2025-01-05T12:00:00Z",
                            "type": "event_msg",
                            "payload": {
                                "type": "token_count",
                                "info": {
                                    "total_token_usage": {
                                        "input_tokens": 120,
                                        "cached_input_tokens": 20,
                                        "output_tokens": 30,
                                        "reasoning_output_tokens": 10,
                                        "total_tokens": 150,
                                    },
                                    "last_token_usage": {
                                        "input_tokens": 70,
                                        "cached_input_tokens": 10,
                                        "output_tokens": 20,
                                        "reasoning_output_tokens": 5,
                                        "total_tokens": 90,
                                    },
                                    "model_context_window": 200000,
                                },
                                "rate_limits": None,
                            },
                        },
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        {
                            "timestamp": "2025-01-05T12:00:00Z",
                            "type": "event_msg",
                            "payload": {
                                "type": "user_message",
                                "message": "rust rollout hello",
                                "kind": "plain",
                            },
                        },
                        separators=(",", ":"),
                    ),
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
        try:
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume",
                    "method": "thread/resume",
                    "params": {
                        "threadId": resume_thread_id,
                        "model": "gpt-resume",
                        "modelProvider": "mock_provider",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                        "sandbox": "danger-full-access",
                    },
                },
            )
            resumed = read_json_line(proc, 5)
            assert resumed["id"] == "thread-resume"
            resume_result = resumed["result"]
            resumed_thread = resume_result["thread"]
            assert resumed_thread["id"] == resume_thread_id
            assert resumed_thread["sessionId"] == resume_thread_id
            assert resumed_thread["preview"] == "saved hello"
            assert resumed_thread["source"] == "cli"
            assert resumed_thread["name"] == "Resume Smoke"
            assert resumed_thread["path"] == os.path.realpath(rollout_path)
            assert resumed_thread["status"] == {"type": "idle"}
            assert resumed_thread["turns"][0]["items"][0]["type"] == "userMessage"
            assert (
                resumed_thread["turns"][0]["items"][0]["content"][0]["text"]
                == "saved hello"
            )
            assert resumed_thread["turns"][1]["items"][0]["type"] == "agentMessage"
            assert resumed_thread["turns"][1]["items"][0]["text"] == "saved hi"
            assert resume_result["model"] == "gpt-resume"
            assert resume_result["modelProvider"] == "mock_provider"
            assert resume_result["approvalPolicy"] == "never"
            assert resume_result["sandbox"] == {"type": "dangerFullAccess"}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "loaded-threads-after-resume",
                    "method": "thread/loaded/list",
                },
            )
            loaded = read_json_line(proc, 5)
            assert loaded["id"] == "loaded-threads-after-resume"
            assert loaded["result"] == {"data": [resume_thread_id], "nextCursor": None}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-read-default-turns",
                    "method": "thread/read",
                    "params": {"threadId": resume_thread_id},
                },
            )
            read_default = read_json_line(proc, 5)
            assert read_default["id"] == "thread-read-default-turns"
            assert read_default["result"]["thread"]["turns"] == []

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-read-include-turns",
                    "method": "thread/read",
                    "params": {"threadId": resume_thread_id, "includeTurns": True},
                },
            )
            read_with_turns = read_json_line(proc, 5)
            assert read_with_turns["id"] == "thread-read-include-turns"
            assert (
                read_with_turns["result"]["thread"]["turns"][0]["items"][0]["content"][0]["text"]
                == "saved hello"
            )

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-turns-list-page-one",
                    "method": "thread/turns/list",
                    "params": {"threadId": resume_thread_id, "limit": 1},
                },
            )
            turns_page_one = read_json_line(proc, 5)
            assert turns_page_one["id"] == "thread-turns-list-page-one"
            page_one = turns_page_one["result"]
            assert page_one["data"][0]["id"] == "turn-1"
            assert page_one["data"][0]["items"][0]["type"] == "agentMessage"
            assert page_one["data"][0]["items"][0]["text"] == "saved hi"
            assert page_one["nextCursor"] is not None
            next_cursor = json.loads(page_one["nextCursor"])
            assert next_cursor == {"turnId": "turn-1", "includeAnchor": False}
            assert page_one["backwardsCursor"] is not None
            backwards_cursor = json.loads(page_one["backwardsCursor"])
            assert backwards_cursor == {"turnId": "turn-1", "includeAnchor": True}

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-turns-list-page-two",
                    "method": "thread/turns/list",
                    "params": {
                        "threadId": resume_thread_id,
                        "cursor": page_one["nextCursor"],
                        "limit": 1,
                    },
                },
            )
            turns_page_two = read_json_line(proc, 5)
            assert turns_page_two["id"] == "thread-turns-list-page-two"
            page_two = turns_page_two["result"]
            assert page_two["data"][0]["id"] == "turn-0"
            assert (
                page_two["data"][0]["items"][0]["content"][0]["text"]
                == "saved hello"
            )
            assert page_two["nextCursor"] is None
            assert json.loads(page_two["backwardsCursor"]) == {
                "turnId": "turn-0",
                "includeAnchor": True,
            }

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-turns-list-ascending",
                    "method": "thread/turns/list",
                    "params": {
                        "threadId": resume_thread_id,
                        "limit": 2,
                        "sortDirection": "asc",
                    },
                },
            )
            turns_ascending = read_json_line(proc, 5)
            assert turns_ascending["id"] == "thread-turns-list-ascending"
            assert [turn["id"] for turn in turns_ascending["result"]["data"]] == [
                "turn-0",
                "turn-1",
            ]
            assert turns_ascending["result"]["nextCursor"] is None
            assert json.loads(turns_ascending["result"]["backwardsCursor"]) == {
                "turnId": "turn-0",
                "includeAnchor": True,
            }

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-turns-list-invalid-cursor",
                    "method": "thread/turns/list",
                    "params": {"threadId": resume_thread_id, "cursor": "not-json"},
                },
            )
            invalid_cursor = read_json_line(proc, 5)
            assert invalid_cursor["id"] == "thread-turns-list-invalid-cursor"
            assert invalid_cursor["error"]["code"] == -32600
            assert "invalid cursor: not-json" in invalid_cursor["error"]["message"]

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-turns-list-stale-cursor",
                    "method": "thread/turns/list",
                    "params": {
                        "threadId": resume_thread_id,
                        "cursor": json.dumps(
                            {"turnId": "missing-turn", "includeAnchor": False},
                            separators=(",", ":"),
                        ),
                    },
                },
            )
            stale_cursor = read_json_line(proc, 5)
            assert stale_cursor["id"] == "thread-turns-list-stale-cursor"
            assert stale_cursor["error"]["code"] == -32600
            assert (
                "invalid cursor: anchor turn is no longer present"
                in stale_cursor["error"]["message"]
            )

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-fork-include-turns",
                    "method": "thread/fork",
                    "params": {"threadId": resume_thread_id},
                },
            )
            fork_included = read_json_line(proc, 5)
            assert fork_included["id"] == "thread-fork-include-turns"
            fork_included_thread = fork_included["result"]["thread"]
            assert fork_included_thread["forkedFromId"] == resume_thread_id
            assert (
                fork_included_thread["turns"][0]["items"][0]["content"][0]["text"]
                == "saved hello"
            )
            assert_thread_started_notification(read_json_line(proc, 5), fork_included_thread)

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-fork-by-path",
                    "method": "thread/fork",
                    "params": {
                        "threadId": "not-a-valid-thread-id",
                        "path": str(rollout_path),
                        "model": "gpt-path-fork",
                    },
                },
            )
            fork_by_path = read_json_line(proc, 5)
            assert fork_by_path["id"] == "thread-fork-by-path"
            fork_by_path_result = fork_by_path["result"]
            fork_by_path_thread = fork_by_path_result["thread"]
            assert fork_by_path_thread["id"] != resume_thread_id
            assert fork_by_path_thread["forkedFromId"] == resume_thread_id
            assert fork_by_path_thread["preview"] == "saved hello"
            assert fork_by_path_thread["source"] == "appServer"
            assert (
                fork_by_path_thread["turns"][0]["items"][0]["content"][0]["text"]
                == "saved hello"
            )
            assert fork_by_path_result["model"] == "gpt-path-fork"
            assert_thread_started_notification(read_json_line(proc, 5), fork_by_path_thread)

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-fork-exclude-turns",
                    "method": "thread/fork",
                    "params": {
                        "threadId": resume_thread_id,
                        "excludeTurns": True,
                        "ephemeral": True,
                    },
                },
            )
            fork_excluded = read_json_line(proc, 5)
            assert fork_excluded["id"] == "thread-fork-exclude-turns"
            forked_thread = fork_excluded["result"]["thread"]
            forked_thread_id = forked_thread["id"]
            assert forked_thread["forkedFromId"] == resume_thread_id
            assert forked_thread["turns"] == []
            assert_thread_started_notification(read_json_line(proc, 5), forked_thread)

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-fork-turns-list",
                    "method": "thread/turns/list",
                    "params": {"threadId": forked_thread_id, "limit": 1},
                },
            )
            fork_turns = read_json_line(proc, 5)
            assert fork_turns["id"] == "thread-fork-turns-list"
            assert fork_turns["result"]["data"][0]["id"] == "turn-1"
            assert fork_turns["result"]["data"][0]["items"][0]["text"] == "saved hi"

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-by-path-exclude-turns",
                    "method": "thread/resume",
                    "params": {
                        "threadId": "ignored-when-path-is-set",
                        "path": str(rollout_path),
                        "excludeTurns": True,
                    },
                },
            )
            resumed_by_path = read_json_line(proc, 5)
            assert resumed_by_path["id"] == "thread-resume-by-path-exclude-turns"
            assert resumed_by_path["result"]["thread"]["id"] == resume_thread_id
            assert resumed_by_path["result"]["thread"]["turns"] == []

            history_text = "Hello from in-memory history"
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-by-history",
                    "method": "thread/resume",
                    "params": {
                        "threadId": "not-a-valid-thread-id",
                        "path": str(codex_home / "missing-rollout.jsonl"),
                        "history": [
                            {
                                "type": "message",
                                "role": "user",
                                "content": [
                                    {
                                        "type": "input_text",
                                        "text": history_text,
                                    }
                                ],
                            }
                        ],
                        "model": "gpt-history",
                        "modelProvider": "mock_provider",
                    },
                },
            )
            resumed_by_history = read_json_line(proc, 5)
            assert resumed_by_history["id"] == "thread-resume-by-history"
            history_result = resumed_by_history["result"]
            history_thread = history_result["thread"]
            history_thread_id = history_thread["id"]
            assert isinstance(history_thread_id, str)
            assert len(history_thread_id) == 36
            assert history_thread["preview"] == history_text
            assert history_thread["source"] == "appServer"
            assert history_thread["path"] is not None
            assert history_thread["turns"][0]["items"][0]["content"][0]["text"] == history_text
            assert history_result["model"] == "gpt-history"
            assert history_result["modelProvider"] == "mock_provider"

            excluded_history_text = "Hidden in-memory history"
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-by-history-exclude-turns",
                    "method": "thread/resume",
                    "params": {
                        "threadId": resume_thread_id,
                        "history": [
                            {
                                "type": "message",
                                "role": "user",
                                "content": [
                                    {
                                        "type": "input_text",
                                        "text": excluded_history_text,
                                    }
                                ],
                            }
                        ],
                        "excludeTurns": True,
                    },
                },
            )
            history_excluded = read_json_line(proc, 5)
            assert history_excluded["id"] == "thread-resume-by-history-exclude-turns"
            history_excluded_thread = history_excluded["result"]["thread"]
            assert history_excluded_thread["preview"] == excluded_history_text
            assert history_excluded_thread["turns"] == []

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-history-turns-list",
                    "method": "thread/turns/list",
                    "params": {
                        "threadId": history_excluded_thread["id"],
                        "limit": 1,
                    },
                },
            )
            history_turns = read_json_line(proc, 5)
            assert history_turns["id"] == "thread-resume-history-turns-list"
            assert (
                history_turns["result"]["data"][0]["items"][0]["content"][0]["text"]
                == excluded_history_text
            )

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-empty-history",
                    "method": "thread/resume",
                    "params": {
                        "threadId": resume_thread_id,
                        "history": [],
                    },
                },
            )
            empty_history = read_json_line(proc, 5)
            assert empty_history["id"] == "thread-resume-empty-history"
            assert empty_history["error"]["code"] == -32600
            assert "history must not be empty" in empty_history["error"]["message"]

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-rust-rollout-by-id",
                    "method": "thread/resume",
                    "params": {"threadId": rust_thread_id},
                },
            )
            rust_resumed = read_json_line(proc, 5)
            assert rust_resumed["id"] == "thread-resume-rust-rollout-by-id"
            rust_thread = rust_resumed["result"]["thread"]
            assert rust_thread["id"] == rust_thread_id
            assert rust_thread["sessionId"] == rust_thread_id
            assert rust_thread["preview"] == "rust rollout hello"
            assert rust_thread["source"] == "cli"
            assert rust_thread["threadSource"] == "user"
            assert rust_thread["modelProvider"] == "mock_provider"
            assert rust_thread["cwd"] == "/"
            assert rust_thread["cliVersion"] == "0.0.0"
            assert rust_thread["path"] == os.path.realpath(rust_rollout_path)
            assert (
                rust_thread["turns"][0]["items"][0]["content"][0]["text"]
                == "rust rollout hello"
            )
            rust_usage = read_json_line(proc, 5)
            assert rust_usage["method"] == "thread/tokenUsage/updated"
            rust_usage_params = rust_usage["params"]
            assert rust_usage_params["threadId"] == rust_thread_id
            assert rust_usage_params["turnId"] == rust_thread["turns"][0]["id"]
            assert rust_usage_params["tokenUsage"]["total"]["totalTokens"] == 150
            assert rust_usage_params["tokenUsage"]["total"]["inputTokens"] == 120
            assert rust_usage_params["tokenUsage"]["total"]["cachedInputTokens"] == 20
            assert rust_usage_params["tokenUsage"]["total"]["outputTokens"] == 30
            assert rust_usage_params["tokenUsage"]["total"]["reasoningOutputTokens"] == 10
            assert rust_usage_params["tokenUsage"]["last"]["totalTokens"] == 90
            assert rust_usage_params["tokenUsage"]["modelContextWindow"] == 200000

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-fork-rust-rollout-by-path",
                    "method": "thread/fork",
                    "params": {
                        "threadId": "not-a-valid-thread-id",
                        "path": str(rust_rollout_path),
                    },
                },
            )
            rust_fork = read_json_line(proc, 5)
            assert rust_fork["id"] == "thread-fork-rust-rollout-by-path"
            rust_fork_thread = rust_fork["result"]["thread"]
            assert rust_fork_thread["forkedFromId"] == rust_thread_id
            assert rust_fork_thread["preview"] == "rust rollout hello"
            assert rust_fork_thread["modelProvider"] == "mock_provider"
            assert (
                rust_fork_thread["turns"][0]["items"][0]["content"][0]["text"]
                == "rust rollout hello"
            )
            rust_fork_usage = read_json_line(proc, 5)
            assert rust_fork_usage["method"] == "thread/tokenUsage/updated"
            assert rust_fork_usage["params"]["threadId"] == rust_fork_thread["id"]
            assert rust_fork_usage["params"]["turnId"] == rust_fork_thread["turns"][0]["id"]
            assert rust_fork_usage["params"]["tokenUsage"]["total"]["totalTokens"] == 150
            assert_thread_started_notification(read_json_line(proc, 5), rust_fork_thread)

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-excluded-turns-list",
                    "method": "thread/turns/list",
                    "params": {"threadId": resume_thread_id, "limit": 1},
                },
            )
            excluded_resume_turns = read_json_line(proc, 5)
            assert excluded_resume_turns["id"] == "thread-resume-excluded-turns-list"
            assert excluded_resume_turns["result"]["data"][0]["id"] == "turn-1"

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-resume-missing",
                    "method": "thread/resume",
                    "params": {"threadId": "missing-resume"},
                },
            )
            missing = read_json_line(proc, 5)
            assert missing["id"] == "thread-resume-missing"
            assert missing["error"]["code"] == -32600
            assert "no rollout found for thread id missing-resume" in missing["error"]["message"]

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


def run_goal_feature_gate_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-goals-", dir="/tmp"))
    try:
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
        try:
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "thread-goal-get-disabled",
                    "method": "thread/goal/get",
                    "params": {"threadId": "00000000-0000-0000-0000-000000000011"},
                },
            )
            thread_goal_get_disabled = read_json_line(proc, 5)
            assert thread_goal_get_disabled["id"] == "thread-goal-get-disabled"
            assert thread_goal_get_disabled["error"]["code"] == -32600
            assert (
                "goals feature is disabled"
                in thread_goal_get_disabled["error"]["message"]
            )
            assert proc.stdin is not None
            proc.stdin.close()
            proc.wait(timeout=5)
            if proc.returncode != 0:
                raise AssertionError(
                    f"app-server exited {proc.returncode}: {proc.stderr.read()}"
                )
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        shutil.rmtree(codex_home, ignore_errors=True)


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
        memory_file.write_text("stale state-backed memory\n")
        state_db = seed_memory_state_db(state_home)

        env = os.environ.copy()
        env["CODEX_HOME"] = str(state_home)
        response = request_stdio_app_server(
            binary,
            {"jsonrpc": "2.0", "id": "state-db", "method": "memory/reset"},
            env,
        )
        assert response["id"] == "state-db"
        assert response["result"] == {}
        assert_empty_dir(memories)
        assert sqlite_count(state_db, "SELECT COUNT(*) FROM stage1_outputs") == 0
        assert (
            sqlite_count(
                state_db,
                "SELECT COUNT(*) FROM jobs WHERE kind = 'memory_stage1' OR kind = 'memory_consolidate_global'",
            )
            == 0
        )
        assert sqlite_count(state_db, "SELECT COUNT(*) FROM jobs WHERE kind = 'unrelated'") == 1
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
        (search_root / "abc").write_text("prefix non-match\n", encoding="utf-8")
        (search_root / "abcde").write_text("spread match\n", encoding="utf-8")
        (search_root / "abexy").write_text("best match\n", encoding="utf-8")
        (search_root / "sub").mkdir()
        (search_root / "sub" / "abce").write_text("nested match\n", encoding="utf-8")

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

        sorted_search = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "fuzzy-search-sorted",
                "method": "fuzzyFileSearch",
                "params": {"query": "abe", "roots": [str(search_root)]},
            },
            env,
        )
        assert sorted_search["id"] == "fuzzy-search-sorted"
        assert sorted_search["result"]["files"] == [
            {
                "root": str(search_root),
                "path": "abexy",
                "match_type": "file",
                "file_name": "abexy",
                "score": 84,
                "indices": [0, 1, 2],
            },
            {
                "root": str(search_root),
                "path": "sub/abce",
                "match_type": "file",
                "file_name": "abce",
                "score": 72,
                "indices": [4, 5, 7],
            },
            {
                "root": str(search_root),
                "path": "abcde",
                "match_type": "file",
                "file_name": "abcde",
                "score": 71,
                "indices": [0, 1, 4],
            },
        ]

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

        git_source.joinpath("plugins", "git-sample", "VERSION").write_text(
            "v2\n", encoding="utf-8"
        )
        git(git_source, "add", ".")
        git(git_source, "commit", "-m", "upgrade")
        upgraded_sha = git_output(git_source, "rev-parse", "release")

        upgraded = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-upgrade-git",
                "method": "marketplace/upgrade",
                "params": {"marketplaceName": "git-debug"},
            },
            env,
        )
        assert upgraded["id"] == "marketplace-upgrade-git"
        assert upgraded["result"] == {
            "selectedMarketplaces": ["git-debug"],
            "upgradedRoots": [str(expected_git_root)],
            "errors": [],
        }
        assert (
            expected_git_root.joinpath("plugins", "git-sample", "VERSION").read_text(
                encoding="utf-8"
            )
            == "v2\n"
        )
        config_text = codex_home.joinpath("config.toml").read_text(encoding="utf-8")
        assert f'last_revision = "{upgraded_sha}"' in config_text
        metadata = json.loads(
            expected_git_root.joinpath(".codex-marketplace-install.json").read_text(
                encoding="utf-8"
            )
        )
        assert metadata == {
            "source_type": "git",
            "source": git_url,
            "ref_name": "release",
            "sparse_paths": [".agents", "plugins/git-sample"],
            "revision": upgraded_sha,
        }

        repeated_upgrade = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "marketplace-upgrade-git-repeat",
                "method": "marketplace/upgrade",
                "params": {"marketplaceName": "git-debug"},
            },
            env,
        )
        assert repeated_upgrade["id"] == "marketplace-upgrade-git-repeat"
        assert repeated_upgrade["result"] == {
            "selectedMarketplaces": ["git-debug"],
            "upgradedRoots": [],
            "errors": [],
        }

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

        time.sleep(0.02)
        watched_file.write_text("external contents changed", encoding="utf-8")
        external_trigger = rpc(
            "fs-watch-external-trigger",
            "fs/getMetadata",
            {"path": str(watched_file)},
        )
        assert external_trigger["id"] == "fs-watch-external-trigger"
        assert external_trigger["result"]["isFile"] is True

        external_for_dir = read_json_line(proc, 5)
        external_for_file = read_json_line(proc, 5)
        external_notifications_by_watch = {
            external_for_dir["params"]["watchId"]: external_for_dir,
            external_for_file["params"]["watchId"]: external_for_file,
        }
        assert sorted(external_notifications_by_watch) == ["watch-dir", "watch-file"]
        assert external_notifications_by_watch["watch-dir"]["method"] == "fs/changed"
        assert external_notifications_by_watch["watch-dir"]["params"]["changedPaths"] == [
            str(watched_file)
        ]
        assert external_notifications_by_watch["watch-file"]["method"] == "fs/changed"
        assert external_notifications_by_watch["watch-file"]["params"]["changedPaths"] == [
            str(watched_file)
        ]

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


def run_command_exec_rpc_smoke(binary: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-command-exec-", dir="/tmp"))
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-command-exec-home-", dir="/tmp"))
    workspace_codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-command-exec-workspace-home-", dir="/tmp"))
    network_server: ThreadingHTTPServer | None = None
    try:
        codex_home.joinpath("config.toml").write_text(
            'sandbox_mode = "danger-full-access"\n',
            encoding="utf-8",
        )
        workspace_codex_home.joinpath("config.toml").write_text(
            'sandbox_mode = "workspace-write"\n',
            encoding="utf-8",
        )
        cwd = root / "cwd"
        cwd.mkdir()
        command_tmpdir = root / "command-tmpdir"
        command_tmpdir.mkdir()
        slash_tmp_target = Path("/tmp") / f"{root.name}-slash-tmp.txt"
        if slash_tmp_target.exists():
            slash_tmp_target.unlink()
        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env["TMPDIR"] = str(command_tmpdir)
        network_server, network_url = start_command_exec_network_backend()
        network_probe = (
            "import sys, urllib.request; "
            "sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=2).read().decode())"
        )

        success = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-success",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", "printf stdout; printf stderr >&2"],
                    "sandboxPolicy": {"type": "dangerFullAccess"},
                },
            },
            env,
        )
        assert success["id"] == "command-exec-success"
        assert success["result"] == {
            "exitCode": 0,
            "stdout": "stdout",
            "stderr": "stderr",
        }

        cwd_env = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-cwd-env",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", 'printf "%s|%s" "$PWD" "$COMMAND_EXEC_TOKEN"'],
                    "cwd": str(cwd),
                    "env": {"COMMAND_EXEC_TOKEN": "token-value"},
                },
            },
            env,
        )
        assert cwd_env["id"] == "command-exec-cwd-env"
        assert cwd_env["result"]["exitCode"] == 0
        assert cwd_env["result"]["stdout"] == f"{cwd.resolve()}|token-value"
        assert cwd_env["result"]["stderr"] == ""

        sandbox_policy_tmpdir_default = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-tmpdir-default",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        'printf tmpdir > "$TMPDIR/tmpdir-ok.txt" && printf tmpdir-ok',
                    ],
                    "cwd": str(cwd),
                    "env": {},
                    "sandboxPolicy": {"type": "workspaceWrite"},
                },
            },
            env,
        )
        assert sandbox_policy_tmpdir_default["id"] == "command-exec-sandbox-policy-tmpdir-default"
        assert sandbox_policy_tmpdir_default["result"] == {
            "exitCode": 0,
            "stdout": "tmpdir-ok",
            "stderr": "",
        }
        assert command_tmpdir.joinpath("tmpdir-ok.txt").read_text(encoding="utf-8") == "tmpdir"

        sandbox_policy_slash_tmp_default = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-slash-tmp-default",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        f"printf slash-tmp > {slash_tmp_target} && printf slash-tmp-ok",
                    ],
                    "cwd": str(cwd),
                    "sandboxPolicy": {"type": "workspaceWrite"},
                },
            },
            env,
        )
        assert sandbox_policy_slash_tmp_default["id"] == "command-exec-sandbox-policy-slash-tmp-default"
        assert sandbox_policy_slash_tmp_default["result"] == {
            "exitCode": 0,
            "stdout": "slash-tmp-ok",
            "stderr": "",
        }
        assert slash_tmp_target.read_text(encoding="utf-8") == "slash-tmp"
        slash_tmp_target.unlink()

        sandbox_policy_tmpdir_excluded = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-tmpdir-excluded",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        'printf blocked > "$TMPDIR/tmpdir-blocked.txt"',
                    ],
                    "cwd": str(cwd),
                    "env": {},
                    "sandboxPolicy": {
                        "type": "workspaceWrite",
                        "excludeTmpdirEnvVar": True,
                        "excludeSlashTmp": True,
                    },
                },
            },
            env,
        )
        assert sandbox_policy_tmpdir_excluded["id"] == "command-exec-sandbox-policy-tmpdir-excluded"
        assert sandbox_policy_tmpdir_excluded["result"]["exitCode"] != 0
        assert sandbox_policy_tmpdir_excluded["result"]["stdout"] == ""
        assert not command_tmpdir.joinpath("tmpdir-blocked.txt").exists()

        sandbox_policy_slash_tmp_excluded = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-slash-tmp-excluded",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", f"printf blocked > {slash_tmp_target}"],
                    "cwd": str(cwd),
                    "sandboxPolicy": {"type": "workspaceWrite", "excludeSlashTmp": True},
                },
            },
            env,
        )
        assert sandbox_policy_slash_tmp_excluded["id"] == "command-exec-sandbox-policy-slash-tmp-excluded"
        assert sandbox_policy_slash_tmp_excluded["result"]["exitCode"] != 0
        assert sandbox_policy_slash_tmp_excluded["result"]["stdout"] == ""
        assert not slash_tmp_target.exists()

        workspace_env = env.copy()
        workspace_env["CODEX_HOME"] = str(workspace_codex_home)
        implicit_workspace_write = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-implicit-workspace-write-temp-roots",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        f'printf cfg-tmp > "$TMPDIR/config-tmpdir.txt" && printf cfg-slash > {slash_tmp_target} && printf implicit-workspace',
                    ],
                    "cwd": str(cwd),
                    "env": {},
                },
            },
            workspace_env,
        )
        assert implicit_workspace_write["id"] == "command-exec-implicit-workspace-write-temp-roots"
        assert implicit_workspace_write["result"] == {
            "exitCode": 0,
            "stdout": "implicit-workspace",
            "stderr": "",
        }
        assert command_tmpdir.joinpath("config-tmpdir.txt").read_text(encoding="utf-8") == "cfg-tmp"
        assert slash_tmp_target.read_text(encoding="utf-8") == "cfg-slash"
        slash_tmp_target.unlink()

        sandbox_policy_bad_type = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-bad-type",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "sandboxPolicy": {"type": "unsupported"},
                },
            },
            env,
        )
        assert sandbox_policy_bad_type["id"] == "command-exec-sandbox-policy-bad-type"
        assert sandbox_policy_bad_type["error"]["code"] == -32602
        assert "externalSandbox" in sandbox_policy_bad_type["error"]["message"]

        sandbox_policy_external_bad_network = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-external-bad-network",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "sandboxPolicy": {"type": "externalSandbox", "networkAccess": "invalid"},
                },
            },
            env,
        )
        assert sandbox_policy_external_bad_network["id"] == "command-exec-sandbox-policy-external-bad-network"
        assert sandbox_policy_external_bad_network["error"]["code"] == -32602
        assert "networkAccess" in sandbox_policy_external_bad_network["error"]["message"]

        sandbox_policy_external = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-external",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", "printf external-sandbox"],
                    "sandboxPolicy": {"type": "externalSandbox", "networkAccess": "enabled"},
                },
            },
            env,
        )
        assert sandbox_policy_external["id"] == "command-exec-sandbox-policy-external"
        assert sandbox_policy_external["result"] == {
            "exitCode": 0,
            "stdout": "external-sandbox",
            "stderr": "",
        }

        sandbox_policy_network_enabled = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-network-enabled",
                "method": "command/exec",
                "params": {
                    "command": [sys.executable, "-c", network_probe, network_url],
                    "sandboxPolicy": {"type": "readOnly", "networkAccess": True},
                },
            },
            env,
        )
        assert sandbox_policy_network_enabled["id"] == "command-exec-sandbox-policy-network-enabled"
        assert sandbox_policy_network_enabled["result"] == {
            "exitCode": 0,
            "stdout": "ok\n",
            "stderr": "",
        }
        assert CommandExecNetworkHandler.requests == ["/"]

        sandbox_policy_network_default = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-network-default",
                "method": "command/exec",
                "params": {
                    "command": [sys.executable, "-c", network_probe, network_url],
                    "sandboxPolicy": {"type": "readOnly"},
                },
            },
            env,
        )
        assert sandbox_policy_network_default["id"] == "command-exec-sandbox-policy-network-default"
        assert sandbox_policy_network_default["result"]["exitCode"] != 0
        assert sandbox_policy_network_default["result"]["stdout"] == ""
        assert CommandExecNetworkHandler.requests == ["/"]

        sandbox_policy_network_restricted = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-sandbox-policy-network-restricted",
                "method": "command/exec",
                "params": {
                    "command": [sys.executable, "-c", network_probe, network_url],
                    "sandboxPolicy": {"type": "workspaceWrite", "networkAccess": False},
                },
            },
            env,
        )
        assert sandbox_policy_network_restricted["id"] == "command-exec-sandbox-policy-network-restricted"
        assert sandbox_policy_network_restricted["result"]["exitCode"] != 0
        assert sandbox_policy_network_restricted["result"]["stdout"] == ""
        assert CommandExecNetworkHandler.requests == ["/"]

        root_read_only_permission_profile = {
            "type": "managed",
            "fileSystem": {
                "type": "restricted",
                "globScanMaxDepth": 1,
                "entries": [
                    {
                        "path": {"type": "special", "value": {"kind": "root"}},
                        "access": "read",
                    }
                ],
            },
            "network": {"enabled": False},
        }
        root_read_only_network_enabled_permission_profile = dict(
            root_read_only_permission_profile,
            network={"enabled": True},
        )
        disabled_permission_profile = {
            "type": "disabled",
        }
        external_permission_profile = {
            "type": "external",
            "network": {"enabled": True},
        }
        project_roots_write_permission_profile = {
            "type": "managed",
            "fileSystem": {
                "type": "restricted",
                "entries": [
                    {
                        "path": {"type": "special", "value": {"kind": "root"}},
                        "access": "read",
                    },
                    {
                        "path": {"type": "special", "value": {"kind": "project_roots"}},
                        "access": "write",
                    },
                ],
            },
            "network": {"enabled": False},
        }
        absolute_writable_root = root / "absolute-writable"
        absolute_writable_root.mkdir()
        absolute_write_permission_profile = {
            "type": "managed",
            "fileSystem": {
                "type": "restricted",
                "entries": [
                    {
                        "path": {"type": "special", "value": {"kind": "root"}},
                        "access": "read",
                    },
                    {
                        "path": {"type": "path", "path": str(absolute_writable_root)},
                        "access": "write",
                    },
                ],
            },
            "network": {"enabled": False},
        }

        permission_profile_bad_glob_depth = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-bad-glob-depth",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "permissionProfile": {
                        "type": "managed",
                        "fileSystem": {
                            "type": "restricted",
                            "globScanMaxDepth": 0,
                            "entries": [
                                {
                                    "path": {
                                        "type": "special",
                                        "value": {"kind": "root"},
                                    },
                                    "access": "read",
                                }
                            ],
                        },
                        "network": {"enabled": False},
                    },
                },
            },
            env,
        )
        assert permission_profile_bad_glob_depth["id"] == "command-exec-permission-profile-bad-glob-depth"
        assert permission_profile_bad_glob_depth["error"]["code"] == -32602
        assert "globScanMaxDepth" in permission_profile_bad_glob_depth["error"]["message"]

        permission_profile_disabled = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-disabled",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", "printf profile-disabled"],
                    "permissionProfile": disabled_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_disabled["id"] == "command-exec-permission-profile-disabled"
        assert permission_profile_disabled["result"] == {
            "exitCode": 0,
            "stdout": "profile-disabled",
            "stderr": "",
        }

        permission_profile_external = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-external",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", "printf profile-external"],
                    "permissionProfile": external_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_external["id"] == "command-exec-permission-profile-external"
        assert permission_profile_external["result"] == {
            "exitCode": 0,
            "stdout": "profile-external",
            "stderr": "",
        }

        read_only_target = root / "readonly-blocked.txt"
        permission_profile_read_only = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-read-only",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", f"printf nope > {read_only_target}"],
                    "permissionProfile": root_read_only_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_read_only["id"] == "command-exec-permission-profile-read-only"
        assert permission_profile_read_only["result"]["exitCode"] != 0
        assert not read_only_target.exists()

        child_cwd = cwd / "child"
        child_cwd.mkdir()
        permission_profile_project_roots = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-project-roots",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        "printf child > child.txt && ! printf parent > ../parent.txt && printf project-roots",
                    ],
                    "cwd": str(child_cwd),
                    "permissionProfile": project_roots_write_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_project_roots["id"] == "command-exec-permission-profile-project-roots"
        assert permission_profile_project_roots["result"]["exitCode"] == 0
        assert permission_profile_project_roots["result"]["stdout"] == "project-roots"
        assert child_cwd.joinpath("child.txt").read_text(encoding="utf-8") == "child"
        assert not cwd.joinpath("parent.txt").exists()

        permission_profile_absolute_root = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-absolute-root",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        f"printf absolute > {absolute_writable_root / 'ok.txt'} && ! printf child > child-denied.txt && printf absolute-root",
                    ],
                    "cwd": str(child_cwd),
                    "permissionProfile": absolute_write_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_absolute_root["id"] == "command-exec-permission-profile-absolute-root"
        assert permission_profile_absolute_root["result"]["exitCode"] == 0
        assert permission_profile_absolute_root["result"]["stdout"] == "absolute-root"
        assert absolute_writable_root.joinpath("ok.txt").read_text(encoding="utf-8") == "absolute"
        assert not child_cwd.joinpath("child-denied.txt").exists()

        permission_profile_network_enabled = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-network-enabled",
                "method": "command/exec",
                "params": {
                    "command": [sys.executable, "-c", network_probe, network_url],
                    "permissionProfile": root_read_only_network_enabled_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_network_enabled["id"] == "command-exec-permission-profile-network-enabled"
        assert permission_profile_network_enabled["result"] == {
            "exitCode": 0,
            "stdout": "ok\n",
            "stderr": "",
        }
        assert CommandExecNetworkHandler.requests == ["/", "/"]

        permission_profile_network_restricted = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-network-restricted",
                "method": "command/exec",
                "params": {
                    "command": [sys.executable, "-c", network_probe, network_url],
                    "permissionProfile": root_read_only_permission_profile,
                },
            },
            env,
        )
        assert permission_profile_network_restricted["id"] == "command-exec-permission-profile-network-restricted"
        assert permission_profile_network_restricted["result"]["exitCode"] != 0
        assert permission_profile_network_restricted["result"]["stdout"] == ""
        assert CommandExecNetworkHandler.requests == ["/", "/"]

        permission_profile_with_sandbox_policy = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-conflict",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "permissionProfile": root_read_only_permission_profile,
                    "sandboxPolicy": {"type": "dangerFullAccess"},
                },
            },
            env,
        )
        assert permission_profile_with_sandbox_policy["id"] == "command-exec-permission-profile-conflict"
        assert permission_profile_with_sandbox_policy["error"]["code"] == -32600
        assert "cannot be combined" in permission_profile_with_sandbox_policy["error"]["message"]

        unsupported_permission_profile = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-permission-profile-unsupported",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "permissionProfile": {
                        "type": "managed",
                        "fileSystem": {
                            "type": "restricted",
                            "entries": [
                                {
                                    "path": {"type": "glob_pattern", "pattern": "**/*.env"},
                                    "access": "none",
                                }
                            ],
                        },
                        "network": {"enabled": False},
                    },
                },
            },
            env,
        )
        assert unsupported_permission_profile["id"] == "command-exec-permission-profile-unsupported"
        assert unsupported_permission_profile["error"]["code"] == -32603
        assert "permissionProfile shape" in unsupported_permission_profile["error"]["message"]

        null_env = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-null-env",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "null-env"],
                    "env": None,
                },
            },
            env,
        )
        assert null_env["id"] == "command-exec-null-env"
        assert null_env["result"] == {
            "exitCode": 0,
            "stdout": "null-env\n",
            "stderr": "",
        }

        nonzero = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-nonzero",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/sh", "-c", "printf failure >&2; exit 7"],
                },
            },
            env,
        )
        assert nonzero["id"] == "command-exec-nonzero"
        assert nonzero["result"] == {
            "exitCode": 7,
            "stdout": "",
            "stderr": "failure",
        }

        buffered_cap = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-buffered-cap",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        "printf abcdef && printf uvwxyz >&2",
                    ],
                    "outputBytesCap": 5,
                },
            },
            env,
        )
        assert buffered_cap["id"] == "command-exec-buffered-cap"
        assert buffered_cap["result"] == {
            "exitCode": 0,
            "stdout": "abcde",
            "stderr": "uvwxy",
        }

        buffered_zero_cap = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-buffered-zero-cap",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        "printf stdout && printf stderr >&2",
                    ],
                    "outputBytesCap": 0,
                },
            },
            env,
        )
        assert buffered_zero_cap["id"] == "command-exec-buffered-zero-cap"
        assert buffered_zero_cap["result"] == {
            "exitCode": 0,
            "stdout": "",
            "stderr": "",
        }

        timeout_response = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-timeout",
                "method": "command/exec",
                "params": {
                    "command": [
                        "/bin/sh",
                        "-c",
                        "printf before-timeout && printf timeout-err >&2; sleep 1",
                    ],
                    "timeoutMs": 10,
                },
            },
            env,
        )
        assert timeout_response["id"] == "command-exec-timeout"
        assert timeout_response["result"] == {
            "exitCode": 124,
            "stdout": "before-timeout",
            "stderr": "timeout-err",
        }

        empty_command = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-empty",
                "method": "command/exec",
                "params": {"command": []},
            },
            env,
        )
        assert empty_command["id"] == "command-exec-empty"
        assert empty_command["error"]["code"] == -32600
        assert "command must not be empty" in empty_command["error"]["message"]

        bad_env = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-bad-env",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "env": {"COMMAND_EXEC_TOKEN": 1},
                },
            },
            env,
        )
        assert bad_env["id"] == "command-exec-bad-env"
        assert bad_env["error"]["code"] == -32602
        assert "env values must be strings or null" in bad_env["error"]["message"]

        streaming_missing_process_id = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-streaming-missing-process-id",
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "unused"],
                    "streamStdoutStderr": True,
                },
            },
            env,
        )
        assert streaming_missing_process_id["id"] == "command-exec-streaming-missing-process-id"
        assert streaming_missing_process_id["error"]["code"] == -32600
        assert "requires a client-supplied processId" in streaming_missing_process_id["error"]["message"]

        streaming_proc = subprocess.Popen(
            [str(binary), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            write_json_line(
                streaming_proc,
                {
                    "jsonrpc": "2.0",
                    "id": "command-exec-streaming",
                    "method": "command/exec",
                    "params": {
                        "command": [
                            "/bin/sh",
                            "-c",
                            "printf stream-out && printf stream-err >&2",
                        ],
                        "streamStdoutStderr": True,
                        "processId": "proc-1",
                    },
                },
            )
            streaming_stdout_delta = read_json_line(streaming_proc, 5)
            streaming_stderr_delta = read_json_line(streaming_proc, 5)
            streaming_response = read_json_line(streaming_proc, 5)
            assert streaming_stdout_delta["method"] == "command/exec/outputDelta"
            assert streaming_stdout_delta["params"]["processId"] == "proc-1"
            assert streaming_stdout_delta["params"]["stream"] == "stdout"
            assert (
                base64.b64decode(streaming_stdout_delta["params"]["deltaBase64"])
                == b"stream-out"
            )
            assert streaming_stdout_delta["params"]["capReached"] is False
            assert streaming_stderr_delta["method"] == "command/exec/outputDelta"
            assert streaming_stderr_delta["params"]["processId"] == "proc-1"
            assert streaming_stderr_delta["params"]["stream"] == "stderr"
            assert (
                base64.b64decode(streaming_stderr_delta["params"]["deltaBase64"])
                == b"stream-err"
            )
            assert streaming_stderr_delta["params"]["capReached"] is False
            assert streaming_response["id"] == "command-exec-streaming"
            assert streaming_response["result"] == {
                "exitCode": 0,
                "stdout": "",
                "stderr": "",
            }
            write_json_line(
                streaming_proc,
                {
                    "jsonrpc": "2.0",
                    "id": "command-exec-streaming-cap",
                    "method": "command/exec",
                    "params": {
                        "command": ["/bin/sh", "-c", "printf capped-output"],
                        "streamStdoutStderr": True,
                        "processId": "proc-cap",
                        "outputBytesCap": 6,
                    },
                },
            )
            streaming_cap_delta = read_json_line(streaming_proc, 5)
            streaming_cap_response = read_json_line(streaming_proc, 5)
            assert streaming_cap_delta["method"] == "command/exec/outputDelta"
            assert streaming_cap_delta["params"]["processId"] == "proc-cap"
            assert streaming_cap_delta["params"]["stream"] == "stdout"
            assert (
                base64.b64decode(streaming_cap_delta["params"]["deltaBase64"])
                == b"capped"
            )
            assert streaming_cap_delta["params"]["capReached"] is True
            assert streaming_cap_response["id"] == "command-exec-streaming-cap"
            assert streaming_cap_response["result"] == {
                "exitCode": 0,
                "stdout": "",
                "stderr": "",
            }
            write_json_line(
                streaming_proc,
                {
                    "jsonrpc": "2.0",
                    "id": "command-exec-streaming-zero-cap",
                    "method": "command/exec",
                    "params": {
                        "command": ["/bin/sh", "-c", "printf zero-cap"],
                        "streamStdoutStderr": True,
                        "processId": "proc-zero-cap",
                        "outputBytesCap": 0,
                    },
                },
            )
            streaming_zero_cap_delta = read_json_line(streaming_proc, 5)
            streaming_zero_cap_response = read_json_line(streaming_proc, 5)
            assert streaming_zero_cap_delta["method"] == "command/exec/outputDelta"
            assert streaming_zero_cap_delta["params"]["processId"] == "proc-zero-cap"
            assert streaming_zero_cap_delta["params"]["stream"] == "stdout"
            assert (
                base64.b64decode(streaming_zero_cap_delta["params"]["deltaBase64"])
                == b""
            )
            assert streaming_zero_cap_delta["params"]["capReached"] is True
            assert streaming_zero_cap_response["id"] == "command-exec-streaming-zero-cap"
            assert streaming_zero_cap_response["result"] == {
                "exitCode": 0,
                "stdout": "",
                "stderr": "",
            }
            write_json_line(
                streaming_proc,
                {
                    "jsonrpc": "2.0",
                    "id": "command-exec-streaming-timeout",
                    "method": "command/exec",
                    "params": {
                        "command": [
                            sys.executable,
                            "-c",
                            "import sys, time; sys.stdout.write('stream-timeout'); sys.stdout.flush(); time.sleep(1)",
                        ],
                        "streamStdoutStderr": True,
                        "processId": "proc-timeout",
                        "timeoutMs": 100,
                    },
                },
            )
            streaming_timeout_delta = read_json_line(streaming_proc, 5)
            streaming_timeout_response = read_json_line(streaming_proc, 5)
            assert streaming_timeout_delta["method"] == "command/exec/outputDelta"
            assert streaming_timeout_delta["params"]["processId"] == "proc-timeout"
            assert streaming_timeout_delta["params"]["stream"] == "stdout"
            assert (
                base64.b64decode(streaming_timeout_delta["params"]["deltaBase64"])
                == b"stream-timeout"
            )
            assert streaming_timeout_delta["params"]["capReached"] is False
            assert streaming_timeout_response["id"] == "command-exec-streaming-timeout"
            assert streaming_timeout_response["result"] == {
                "exitCode": 124,
                "stdout": "",
                "stderr": "",
            }
            assert streaming_proc.stdin is not None
            streaming_proc.stdin.close()
            streaming_proc.wait(timeout=5)
            if streaming_proc.returncode != 0:
                raise AssertionError(
                    f"app-server exited {streaming_proc.returncode}: {streaming_proc.stderr.read()}"
                )
        finally:
            if streaming_proc.poll() is None:
                streaming_proc.kill()
                streaming_proc.wait(timeout=5)

        missing_write_payload = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-write-empty",
                "method": "command/exec/write",
                "params": {"processId": "proc-1"},
            },
            env,
        )
        assert missing_write_payload["id"] == "command-exec-write-empty"
        assert missing_write_payload["error"]["code"] == -32602
        assert "requires deltaBase64 or closeStdin" in missing_write_payload["error"]["message"]

        bad_write_delta = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-write-bad-base64",
                "method": "command/exec/write",
                "params": {"processId": "proc-1", "deltaBase64": "not base64"},
            },
            env,
        )
        assert bad_write_delta["id"] == "command-exec-write-bad-base64"
        assert bad_write_delta["error"]["code"] == -32602
        assert "invalid deltaBase64" in bad_write_delta["error"]["message"]

        followup = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-write",
                "method": "command/exec/write",
                "params": {"processId": "proc-1", "deltaBase64": "", "closeStdin": True},
            },
            env,
        )
        assert followup["id"] == "command-exec-write"
        assert followup["error"]["code"] == -32600
        assert 'no active command/exec for process id "proc-1"' in followup["error"]["message"]

        terminate = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-terminate",
                "method": "command/exec/terminate",
                "params": {"processId": "proc-1"},
            },
            env,
        )
        assert terminate["id"] == "command-exec-terminate"
        assert terminate["error"]["code"] == -32600
        assert 'no active command/exec for process id "proc-1"' in terminate["error"]["message"]

        bad_resize = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-resize-bad-size",
                "method": "command/exec/resize",
                "params": {"processId": "proc-1", "size": {"rows": 0, "cols": 80}},
            },
            env,
        )
        assert bad_resize["id"] == "command-exec-resize-bad-size"
        assert bad_resize["error"]["code"] == -32602
        assert "rows and cols must be greater than 0" in bad_resize["error"]["message"]

        resize = request_stdio_app_server(
            binary,
            {
                "jsonrpc": "2.0",
                "id": "command-exec-resize",
                "method": "command/exec/resize",
                "params": {"processId": "proc-1", "size": {"rows": 24, "cols": 80}},
            },
            env,
        )
        assert resize["id"] == "command-exec-resize"
        assert resize["error"]["code"] == -32600
        assert 'no active command/exec for process id "proc-1"' in resize["error"]["message"]
    finally:
        if network_server is not None:
            network_server.shutdown()
            network_server.server_close()
        if "slash_tmp_target" in locals() and slash_tmp_target.exists():
            slash_tmp_target.unlink()
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(codex_home, ignore_errors=True)
        shutil.rmtree(workspace_codex_home, ignore_errors=True)


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
    workspace = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-project-", dir="/tmp"))
    project_dot_codex = workspace / ".codex"
    project_dot_codex.mkdir(parents=True)
    (project_dot_codex / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-project"',
                'approval_policy = "on-request"',
                'sandbox_mode = "workspace-write"',
                'web_search = "cached"',
                'model_reasoning_effort = "high"',
                'service_tier = "fast"',
                "",
                "[sandbox_workspace_write]",
                'writable_roots = ["/tmp/codex-zig-project-root"]',
                "network_access = false",
                "",
                "[tools.web_search]",
                'context_size = "low"',
                'location = { region = "NY" }',
                "",
                "[tools]",
                "view_image = true",
                "",
                "[apps.app1]",
                'default_tools_approval_mode = "approve"',
                "",
                "[apps.app1.tools.search]",
                'approval_mode = "prompt"',
                "",
                "[apps.app3]",
                "enabled = false",
                "",
                "[apps.app3.tools.deploy]",
                "enabled = true",
                "",
            ]
        ),
        encoding="utf-8",
    )
    child_workspace = workspace / "child"
    child_dot_codex = child_workspace / ".codex"
    child_dot_codex.mkdir(parents=True)
    (child_dot_codex / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-child"',
                'approval_policy = "on-failure"',
                'model_reasoning_effort = "low"',
                'service_tier = "flex"',
                'sandbox_workspace_write = { exclude_tmpdir_env_var = true }',
                "",
                "[tools.web_search]",
                'allowed_domains = ["child.example"]',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (codex_home / "config.toml").write_text(
        "\n".join(
            [
                'model = "gpt-config"',
                'profile = "work"',
                'approval_policy = "never"',
                'sandbox_mode = "danger-full-access"',
                'web_search = "live"',
                'service_tier = "flex"',
                "",
                "[sandbox_workspace_write]",
                'writable_roots = ["/tmp/codex-zig-user-root"]',
                "network_access = true",
                "exclude_slash_tmp = true",
                "",
                "[tools.web_search]",
                'context_size = "high"',
                'allowed_domains = ["example.com"]',
                'location = { country = "US", city = "New York, NY", timezone = "America/New_York" }',
                "",
                "[tools]",
                "view_image = false",
                "",
                "[apps._default]",
                "enabled = false",
                "destructive_enabled = false",
                "open_world_enabled = true",
                "",
                "[apps.app1]",
                "enabled = false",
                "destructive_enabled = false",
                "open_world_enabled = true",
                'default_tools_approval_mode = "prompt"',
                "default_tools_enabled = false",
                "",
                "[apps.app1.tools.search]",
                "enabled = true",
                'approval_mode = "approve"',
                "",
                "[features]",
                "apps = false",
                "",
                "[profiles.work.features]",
                "goals = true",
                "",
                "[projects]",
                f'[projects."{toml_quoted_key(str(workspace))}"]',
                'trust_level = "trusted"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    managed_config_path = codex_home / "managed_config.toml"
    env["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = str(managed_config_path)
    system_config_path = codex_home / "system_config.toml"
    system_requirements_path = codex_home / "system_requirements.toml"
    env["CODEX_APP_SERVER_SYSTEM_REQUIREMENTS_PATH"] = str(system_requirements_path)
    system_config_path.write_text(
        "\n".join(
            [
                'model = "gpt-system"',
                'approval_policy = "on-failure"',
                'sandbox_mode = "read-only"',
                'web_search = "cached"',
                'model_reasoning_effort = "medium"',
                'service_tier = "fast"',
                "",
                "[sandbox_workspace_write]",
                'writable_roots = ["/tmp/codex-zig-system-root"]',
                "network_access = false",
                "exclude_tmpdir_env_var = true",
                "",
                "[tools.web_search]",
                'context_size = "low"',
                'allowed_domains = ["system.example"]',
                'location = { region = "CA" }',
                "",
                "[tools]",
                "view_image = true",
                "",
                "[apps._default]",
                "open_world_enabled = false",
                "",
                "[apps.app1]",
                "default_tools_enabled = true",
                "",
                "[apps.app1.tools.summarize]",
                "enabled = false",
                "",
                "[apps.app2]",
                "enabled = false",
                'default_tools_approval_mode = "approve"',
                "",
                "[apps.app2.tools.export]",
                'approval_mode = "prompt"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    env["CODEX_APP_SERVER_SYSTEM_CONFIG_PATH"] = str(system_config_path)
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
        assert config_body["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-user-root"],
            "network_access": True,
            "exclude_tmpdir_env_var": True,
            "exclude_slash_tmp": True,
        }
        assert config_body["web_search"] == "live"
        assert config_body["model_reasoning_effort"] == "medium"
        assert config_body["service_tier"] == "flex"
        assert config_body["tools"] == {
            "web_search": {
                "context_size": "high",
                "allowed_domains": ["example.com"],
                "location": {
                    "country": "US",
                    "region": "CA",
                    "city": "New York, NY",
                    "timezone": "America/New_York",
                },
            },
            "view_image": False,
        }
        expected_apps = {
            "_default": {
                "enabled": False,
                "destructive_enabled": False,
                "open_world_enabled": True,
            },
            "app1": {
                "enabled": False,
                "destructive_enabled": False,
                "open_world_enabled": True,
                "default_tools_approval_mode": "prompt",
                "default_tools_enabled": False,
                "tools": {
                    "search": {
                        "enabled": True,
                        "approval_mode": "approve",
                    },
                    "summarize": {
                        "enabled": False,
                        "approval_mode": None,
                    },
                },
            },
            "app2": {
                "enabled": False,
                "destructive_enabled": None,
                "open_world_enabled": None,
                "default_tools_approval_mode": "approve",
                "default_tools_enabled": None,
                "tools": {
                    "export": {
                        "enabled": None,
                        "approval_mode": "prompt",
                    },
                },
            },
        }
        assert config_body["apps"] == expected_apps, json.dumps(config_body["apps"], indent=2, sort_keys=True)
        assert config_body["features"]["apps"] is False
        assert config_body["features"]["goals"] is True
        assert config_body["features"]["memories"] is False
        config_path = str(codex_home / "config.toml")
        origins = config_read["result"]["origins"]
        for key in [
            "model",
            "profile",
            "approval_policy",
            "sandbox_mode",
            "sandbox_workspace_write.writable_roots.0",
            "sandbox_workspace_write.network_access",
            "sandbox_workspace_write.exclude_slash_tmp",
            "web_search",
            "service_tier",
            "tools.web_search.context_size",
            "tools.web_search.allowed_domains.0",
            "tools.web_search.location.country",
            "tools.web_search.location.city",
            "tools.web_search.location.timezone",
            "tools.view_image",
            "apps._default.enabled",
            "apps._default.destructive_enabled",
            "apps._default.open_world_enabled",
            "apps.app1.enabled",
            "apps.app1.destructive_enabled",
            "apps.app1.open_world_enabled",
            "apps.app1.default_tools_approval_mode",
            "apps.app1.default_tools_enabled",
            "apps.app1.tools.search.enabled",
            "apps.app1.tools.search.approval_mode",
        ]:
            assert origins[key]["name"] == {"type": "user", "file": config_path}
            assert origins[key]["version"].startswith("sha256:")
        system_source = {"type": "system", "file": str(system_config_path)}
        assert origins["model_reasoning_effort"]["name"] == system_source
        assert origins["model_reasoning_effort"]["version"].startswith("sha256:")
        assert origins["sandbox_workspace_write.exclude_tmpdir_env_var"]["name"] == system_source
        assert origins["sandbox_workspace_write.exclude_tmpdir_env_var"]["version"].startswith("sha256:")
        assert origins["tools.web_search.location.region"]["name"] == system_source
        assert origins["tools.web_search.location.region"]["version"].startswith("sha256:")
        for key in [
            "apps.app1.tools.summarize.enabled",
            "apps.app2.enabled",
            "apps.app2.default_tools_approval_mode",
            "apps.app2.tools.export.approval_mode",
        ]:
            assert origins[key]["name"] == system_source
            assert origins[key]["version"].startswith("sha256:")
        layers = config_read["result"]["layers"]
        assert len(layers) == 2
        assert layers[0]["name"] == {"type": "user", "file": config_path}
        assert layers[0]["version"] == origins["model"]["version"]
        assert layers[0]["config"] == {
            "model": "gpt-config",
            "profile": "work",
            "approval_policy": "never",
            "sandbox_mode": "danger-full-access",
            "sandbox_workspace_write": {
                "writable_roots": ["/tmp/codex-zig-user-root"],
                "network_access": True,
                "exclude_tmpdir_env_var": False,
                "exclude_slash_tmp": True,
            },
            "web_search": "live",
            "service_tier": "flex",
            "tools": {
                "web_search": {
                    "context_size": "high",
                    "allowed_domains": ["example.com"],
                    "location": {
                        "country": "US",
                        "region": None,
                        "city": "New York, NY",
                        "timezone": "America/New_York",
                    },
                },
                "view_image": False,
            },
            "apps": {
                "_default": {
                    "enabled": False,
                    "destructive_enabled": False,
                    "open_world_enabled": True,
                },
                "app1": {
                    "enabled": False,
                    "destructive_enabled": False,
                    "open_world_enabled": True,
                    "default_tools_approval_mode": "prompt",
                    "default_tools_enabled": False,
                    "tools": {
                        "search": {
                            "enabled": True,
                            "approval_mode": "approve",
                        },
                    },
                },
            },
        }
        assert layers[1]["name"] == system_source
        assert layers[1]["version"] == origins["sandbox_workspace_write.exclude_tmpdir_env_var"]["version"]
        assert layers[1]["config"] == {
            "model": "gpt-system",
            "approval_policy": "on-failure",
            "sandbox_mode": "read-only",
            "web_search": "cached",
            "model_reasoning_effort": "medium",
            "service_tier": "priority",
            "sandbox_workspace_write": {
                "writable_roots": ["/tmp/codex-zig-system-root"],
                "network_access": False,
                "exclude_tmpdir_env_var": True,
                "exclude_slash_tmp": False,
            },
            "tools": {
                "web_search": {
                    "context_size": "low",
                    "allowed_domains": ["system.example"],
                    "location": {
                        "country": None,
                        "region": "CA",
                        "city": None,
                        "timezone": None,
                    },
                },
                "view_image": True,
            },
            "apps": {
                "_default": {
                    "enabled": True,
                    "destructive_enabled": True,
                    "open_world_enabled": False,
                },
                "app1": {
                    "enabled": True,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": None,
                    "default_tools_enabled": True,
                    "tools": {
                        "summarize": {
                            "enabled": False,
                            "approval_mode": None,
                        },
                    },
                },
                "app2": {
                    "enabled": False,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": "approve",
                    "default_tools_enabled": None,
                    "tools": {
                        "export": {
                            "enabled": None,
                            "approval_mode": "prompt",
                        },
                    },
                },
            },
        }

        project_config_read = rpc(
            "config-read-project",
            "config/read",
            {"includeLayers": True, "cwd": str(workspace)},
        )
        assert project_config_read["id"] == "config-read-project"
        project_config_body = project_config_read["result"]["config"]
        assert project_config_body["model"] == "gpt-project"
        assert project_config_body["approval_policy"] == "on-request"
        assert project_config_body["sandbox_mode"] == "workspace-write"
        assert project_config_body["web_search"] == "cached"
        assert project_config_body["model_reasoning_effort"] == "high"
        assert project_config_body["service_tier"] == "priority"
        assert project_config_body["tools"] == {
            "web_search": {
                "context_size": "low",
                "allowed_domains": ["example.com"],
                "location": {
                    "country": "US",
                    "region": "NY",
                    "city": "New York, NY",
                    "timezone": "America/New_York",
                },
            },
            "view_image": True,
        }
        assert project_config_body["apps"] == {
            "_default": {
                "enabled": False,
                "destructive_enabled": False,
                "open_world_enabled": True,
            },
            "app1": {
                "enabled": False,
                "destructive_enabled": False,
                "open_world_enabled": True,
                "default_tools_approval_mode": "approve",
                "default_tools_enabled": False,
                "tools": {
                    "search": {
                        "enabled": True,
                        "approval_mode": "prompt",
                    },
                    "summarize": {
                        "enabled": False,
                        "approval_mode": None,
                    },
                },
            },
            "app3": {
                "enabled": False,
                "destructive_enabled": None,
                "open_world_enabled": None,
                "default_tools_approval_mode": None,
                "default_tools_enabled": None,
                "tools": {
                    "deploy": {
                        "enabled": True,
                        "approval_mode": None,
                    },
                },
            },
            "app2": {
                "enabled": False,
                "destructive_enabled": None,
                "open_world_enabled": None,
                "default_tools_approval_mode": "approve",
                "default_tools_enabled": None,
                "tools": {
                    "export": {
                        "enabled": None,
                        "approval_mode": "prompt",
                    },
                },
            },
        }
        assert project_config_body["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-project-root"],
            "network_access": False,
            "exclude_tmpdir_env_var": True,
            "exclude_slash_tmp": True,
        }
        assert project_config_body["profile"] == "work"
        project_source = {
            "type": "project",
            "dotCodexFolder": str(project_dot_codex),
        }
        project_origins = project_config_read["result"]["origins"]
        for key in [
            "model",
            "approval_policy",
            "sandbox_mode",
            "web_search",
            "model_reasoning_effort",
            "service_tier",
            "tools.web_search.context_size",
            "tools.web_search.location.region",
            "tools.view_image",
            "apps.app1.default_tools_approval_mode",
            "apps.app1.tools.search.approval_mode",
            "apps.app3.enabled",
            "apps.app3.tools.deploy.enabled",
            "sandbox_workspace_write.writable_roots.0",
            "sandbox_workspace_write.network_access",
        ]:
            assert project_origins[key]["name"] == project_source
            assert project_origins[key]["version"].startswith("sha256:")
        for key in [
            "tools.web_search.allowed_domains.0",
            "tools.web_search.location.country",
            "tools.web_search.location.city",
            "tools.web_search.location.timezone",
            "apps._default.enabled",
            "apps._default.destructive_enabled",
            "apps._default.open_world_enabled",
            "apps.app1.enabled",
            "apps.app1.destructive_enabled",
            "apps.app1.open_world_enabled",
            "apps.app1.default_tools_enabled",
            "apps.app1.tools.search.enabled",
        ]:
            assert project_origins[key]["name"] == {"type": "user", "file": config_path}
            assert project_origins[key]["version"].startswith("sha256:")
        assert project_origins["profile"]["name"] == {"type": "user", "file": config_path}
        assert project_origins["sandbox_workspace_write.exclude_slash_tmp"]["name"] == {
            "type": "user",
            "file": config_path,
        }
        assert project_origins["sandbox_workspace_write.exclude_tmpdir_env_var"]["name"] == system_source
        for key in [
            "apps.app1.tools.summarize.enabled",
            "apps.app2.enabled",
            "apps.app2.default_tools_approval_mode",
            "apps.app2.tools.export.approval_mode",
        ]:
            assert project_origins[key]["name"] == system_source
            assert project_origins[key]["version"].startswith("sha256:")
        project_layers = project_config_read["result"]["layers"]
        assert len(project_layers) == 3
        assert project_layers[0]["name"] == project_source
        assert project_layers[0]["version"] == project_origins["model_reasoning_effort"]["version"]
        assert project_layers[0]["config"] == {
            "model": "gpt-project",
            "approval_policy": "on-request",
            "sandbox_mode": "workspace-write",
            "web_search": "cached",
            "model_reasoning_effort": "high",
            "service_tier": "priority",
            "sandbox_workspace_write": {
                "writable_roots": ["/tmp/codex-zig-project-root"],
                "network_access": False,
                "exclude_tmpdir_env_var": False,
                "exclude_slash_tmp": False,
            },
            "tools": {
                "web_search": {
                    "context_size": "low",
                    "allowed_domains": None,
                    "location": {
                        "country": None,
                        "region": "NY",
                        "city": None,
                        "timezone": None,
                    },
                },
                "view_image": True,
            },
            "apps": {
                "_default": None,
                "app1": {
                    "enabled": True,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": "approve",
                    "default_tools_enabled": None,
                    "tools": {
                        "search": {
                            "enabled": None,
                            "approval_mode": "prompt",
                        },
                    },
                },
                "app3": {
                    "enabled": False,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": None,
                    "default_tools_enabled": None,
                    "tools": {
                        "deploy": {
                            "enabled": True,
                            "approval_mode": None,
                        },
                    },
                },
            },
        }
        assert project_layers[1]["name"] == {"type": "user", "file": config_path}
        assert project_layers[2]["name"] == system_source

        nested_project_config_read = rpc(
            "config-read-nested-project",
            "config/read",
            {"includeLayers": True, "cwd": str(child_workspace)},
        )
        assert nested_project_config_read["id"] == "config-read-nested-project"
        nested_config_body = nested_project_config_read["result"]["config"]
        assert nested_config_body["model"] == "gpt-child"
        assert nested_config_body["approval_policy"] == "on-failure"
        assert nested_config_body["sandbox_mode"] == "workspace-write"
        assert nested_config_body["web_search"] == "cached"
        assert nested_config_body["model_reasoning_effort"] == "low"
        assert nested_config_body["service_tier"] == "flex"
        assert nested_config_body["tools"] == {
            "web_search": {
                "context_size": "low",
                "allowed_domains": ["child.example"],
                "location": {
                    "country": "US",
                    "region": "NY",
                    "city": "New York, NY",
                    "timezone": "America/New_York",
                },
            },
            "view_image": True,
        }
        assert nested_config_body["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-project-root"],
            "network_access": False,
            "exclude_tmpdir_env_var": True,
            "exclude_slash_tmp": True,
        }
        assert nested_config_body["profile"] == "work"
        child_project_source = {
            "type": "project",
            "dotCodexFolder": str(child_dot_codex),
        }
        nested_origins = nested_project_config_read["result"]["origins"]
        assert nested_origins["model"]["name"] == child_project_source
        assert nested_origins["approval_policy"]["name"] == child_project_source
        assert nested_origins["sandbox_mode"]["name"] == project_source
        assert nested_origins["web_search"]["name"] == project_source
        assert nested_origins["tools.web_search.context_size"]["name"] == project_source
        assert nested_origins["tools.web_search.location.region"]["name"] == project_source
        assert nested_origins["tools.view_image"]["name"] == project_source
        assert nested_origins["tools.web_search.allowed_domains.0"]["name"] == child_project_source
        assert nested_origins["model_reasoning_effort"]["name"] == child_project_source
        assert nested_origins["service_tier"]["name"] == child_project_source
        assert nested_origins["sandbox_workspace_write.writable_roots.0"]["name"] == project_source
        assert nested_origins["sandbox_workspace_write.network_access"]["name"] == project_source
        assert nested_origins["sandbox_workspace_write.exclude_tmpdir_env_var"]["name"] == child_project_source
        assert nested_origins["sandbox_workspace_write.exclude_slash_tmp"]["name"] == {
            "type": "user",
            "file": config_path,
        }
        assert nested_origins["profile"]["name"] == {"type": "user", "file": config_path}
        nested_layers = nested_project_config_read["result"]["layers"]
        assert len(nested_layers) == 4
        assert nested_layers[0]["name"] == child_project_source
        assert nested_layers[0]["config"] == {
            "model": "gpt-child",
            "approval_policy": "on-failure",
            "model_reasoning_effort": "low",
            "service_tier": "flex",
            "sandbox_workspace_write": {
                "writable_roots": [],
                "network_access": False,
                "exclude_tmpdir_env_var": True,
                "exclude_slash_tmp": False,
            },
            "tools": {
                "web_search": {
                    "context_size": None,
                    "allowed_domains": ["child.example"],
                    "location": None,
                },
                "view_image": None,
            },
        }
        assert nested_layers[1]["name"] == project_source
        assert nested_layers[1]["config"] == {
            "model": "gpt-project",
            "approval_policy": "on-request",
            "sandbox_mode": "workspace-write",
            "web_search": "cached",
            "model_reasoning_effort": "high",
            "service_tier": "priority",
            "sandbox_workspace_write": {
                "writable_roots": ["/tmp/codex-zig-project-root"],
                "network_access": False,
                "exclude_tmpdir_env_var": False,
                "exclude_slash_tmp": False,
            },
            "tools": {
                "web_search": {
                    "context_size": "low",
                    "allowed_domains": None,
                    "location": {
                        "country": None,
                        "region": "NY",
                        "city": None,
                        "timezone": None,
                    },
                },
                "view_image": True,
            },
            "apps": {
                "_default": None,
                "app1": {
                    "enabled": True,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": "approve",
                    "default_tools_enabled": None,
                    "tools": {
                        "search": {
                            "enabled": None,
                            "approval_mode": "prompt",
                        },
                    },
                },
                "app3": {
                    "enabled": False,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": None,
                    "default_tools_enabled": None,
                    "tools": {
                        "deploy": {
                            "enabled": True,
                            "approval_mode": None,
                        },
                    },
                },
            },
        }
        assert nested_layers[2]["name"] == {"type": "user", "file": config_path}
        assert nested_layers[3]["name"] == system_source

        managed_config_path.write_text(
            "\n".join(
                [
                    'model = "gpt-managed"',
                    'approval_policy = "on-request"',
                    'web_search = "disabled"',
                    'model_reasoning_effort = "low"',
                    'service_tier = "priority"',
                    "",
                    "[sandbox_workspace_write]",
                    'writable_roots = ["/tmp/codex-zig-managed-root"]',
                    "network_access = false",
                    "exclude_tmpdir_env_var = true",
                    "",
                    "[tools.web_search]",
                    'allowed_domains = ["managed.example"]',
                    'location = { country = "JP" }',
                    "",
                    "[tools]",
                    "view_image = true",
                    "",
                    "[apps._default]",
                    "enabled = true",
                    "",
                    "[apps.app1]",
                    "enabled = true",
                    'default_tools_approval_mode = "auto"',
                    "",
                    "[apps.app1.tools.search]",
                    'approval_mode = "auto"',
                    "",
                    "[apps.app4]",
                    "destructive_enabled = false",
                    "",
                    "[apps.app4.tools.deploy]",
                    "enabled = false",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        managed_config_read = rpc(
            "config-read-managed",
            "config/read",
            {"includeLayers": True, "cwd": str(codex_home)},
        )
        assert managed_config_read["id"] == "config-read-managed"
        managed_config_body = managed_config_read["result"]["config"]
        assert managed_config_body["model"] == "gpt-managed"
        assert managed_config_body["approval_policy"] == "on-request"
        assert managed_config_body["sandbox_mode"] == "danger-full-access"
        assert managed_config_body["web_search"] == "disabled"
        assert managed_config_body["model_reasoning_effort"] == "low"
        assert managed_config_body["service_tier"] == "priority"
        assert managed_config_body["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-managed-root"],
            "network_access": False,
            "exclude_tmpdir_env_var": True,
            "exclude_slash_tmp": True,
        }
        assert managed_config_body["tools"] == {
            "web_search": {
                "context_size": "high",
                "allowed_domains": ["managed.example"],
                "location": {
                    "country": "JP",
                    "region": "CA",
                    "city": "New York, NY",
                    "timezone": "America/New_York",
                },
            },
            "view_image": True,
        }
        assert managed_config_body["apps"] == {
            "_default": {
                "enabled": True,
                "destructive_enabled": False,
                "open_world_enabled": True,
            },
            "app1": {
                "enabled": True,
                "destructive_enabled": False,
                "open_world_enabled": True,
                "default_tools_approval_mode": "auto",
                "default_tools_enabled": False,
                "tools": {
                    "search": {
                        "enabled": True,
                        "approval_mode": "auto",
                    },
                    "summarize": {
                        "enabled": False,
                        "approval_mode": None,
                    },
                },
            },
            "app4": {
                "enabled": True,
                "destructive_enabled": False,
                "open_world_enabled": None,
                "default_tools_approval_mode": None,
                "default_tools_enabled": None,
                "tools": {
                    "deploy": {
                        "enabled": False,
                        "approval_mode": None,
                    },
                },
            },
            "app2": {
                "enabled": False,
                "destructive_enabled": None,
                "open_world_enabled": None,
                "default_tools_approval_mode": "approve",
                "default_tools_enabled": None,
                "tools": {
                    "export": {
                        "enabled": None,
                        "approval_mode": "prompt",
                    },
                },
            },
        }
        managed_source = {
            "type": "legacyManagedConfigTomlFromFile",
            "file": str(managed_config_path),
        }
        managed_origins = managed_config_read["result"]["origins"]
        for key in [
            "model",
            "approval_policy",
            "web_search",
            "model_reasoning_effort",
            "service_tier",
            "sandbox_workspace_write.writable_roots.0",
            "sandbox_workspace_write.network_access",
            "sandbox_workspace_write.exclude_tmpdir_env_var",
            "tools.web_search.allowed_domains.0",
            "tools.web_search.location.country",
            "tools.view_image",
            "apps._default.enabled",
            "apps.app1.enabled",
            "apps.app1.default_tools_approval_mode",
            "apps.app1.tools.search.approval_mode",
            "apps.app4.destructive_enabled",
            "apps.app4.tools.deploy.enabled",
        ]:
            assert managed_origins[key]["name"] == managed_source
            assert managed_origins[key]["version"].startswith("sha256:")
        for key in [
            "profile",
            "sandbox_mode",
            "sandbox_workspace_write.exclude_slash_tmp",
            "tools.web_search.context_size",
            "tools.web_search.location.city",
            "tools.web_search.location.timezone",
            "apps._default.destructive_enabled",
            "apps._default.open_world_enabled",
            "apps.app1.destructive_enabled",
            "apps.app1.open_world_enabled",
            "apps.app1.default_tools_enabled",
            "apps.app1.tools.search.enabled",
        ]:
            assert managed_origins[key]["name"] == {"type": "user", "file": config_path}
            assert managed_origins[key]["version"].startswith("sha256:")
        assert managed_origins["tools.web_search.location.region"]["name"] == system_source
        assert managed_origins["tools.web_search.location.region"]["version"].startswith("sha256:")
        for key in [
            "apps.app1.tools.summarize.enabled",
            "apps.app2.enabled",
            "apps.app2.default_tools_approval_mode",
            "apps.app2.tools.export.approval_mode",
        ]:
            assert managed_origins[key]["name"] == system_source
            assert managed_origins[key]["version"].startswith("sha256:")
        managed_layers = managed_config_read["result"]["layers"]
        assert len(managed_layers) == 3
        assert managed_layers[0]["name"] == managed_source
        assert managed_layers[0]["version"] == managed_origins["model"]["version"]
        assert managed_layers[0]["config"] == {
            "model": "gpt-managed",
            "approval_policy": "on-request",
            "web_search": "disabled",
            "model_reasoning_effort": "low",
            "service_tier": "priority",
            "sandbox_workspace_write": {
                "writable_roots": ["/tmp/codex-zig-managed-root"],
                "network_access": False,
                "exclude_tmpdir_env_var": True,
                "exclude_slash_tmp": False,
            },
            "tools": {
                "web_search": {
                    "context_size": None,
                    "allowed_domains": ["managed.example"],
                    "location": {
                        "country": "JP",
                        "region": None,
                        "city": None,
                        "timezone": None,
                    },
                },
                "view_image": True,
            },
            "apps": {
                "_default": {
                    "enabled": True,
                    "destructive_enabled": True,
                    "open_world_enabled": True,
                },
                "app1": {
                    "enabled": True,
                    "destructive_enabled": None,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": "auto",
                    "default_tools_enabled": None,
                    "tools": {
                        "search": {
                            "enabled": None,
                            "approval_mode": "auto",
                        },
                    },
                },
                "app4": {
                    "enabled": True,
                    "destructive_enabled": False,
                    "open_world_enabled": None,
                    "default_tools_approval_mode": None,
                    "default_tools_enabled": None,
                    "tools": {
                        "deploy": {
                            "enabled": False,
                            "approval_mode": None,
                        },
                    },
                },
            },
        }
        assert managed_layers[1]["name"] == {"type": "user", "file": config_path}
        assert managed_layers[1]["config"]["model"] == "gpt-config"
        assert managed_layers[1]["config"]["approval_policy"] == "never"
        assert managed_layers[1]["config"]["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-user-root"],
            "network_access": True,
            "exclude_tmpdir_env_var": False,
            "exclude_slash_tmp": True,
        }
        assert managed_layers[2]["name"] == system_source
        managed_config_path.unlink()

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

        system_requirements_path.write_text(
            "\n".join(
                [
                    'allowed_approval_policies = ["on-request"]',
                    'allowed_sandbox_modes = ["danger-full-access"]',
                    'allowed_web_search_modes = ["cached"]',
                    'enforce_residency = "us"',
                    "",
                    "[features]",
                    "apps = false",
                    "goals = true",
                    "",
                    "[hooks]",
                    'managed_dir = "/tmp/codex-managed-hooks"',
                    "windows_managed_dir = 'C:\\codex\\hooks'",
                    "",
                    "[[hooks.PreToolUse]]",
                    'matcher = "^Bash$"',
                    "",
                    "[[hooks.PreToolUse.hooks]]",
                    'type = "command"',
                    'command = "python3 /tmp/codex-managed-hooks/pre.py"',
                    "timeout = 10",
                    "async = true",
                    'statusMessage = "checking managed hook"',
                    "",
                    "[[hooks.SessionStart]]",
                    "",
                    "[[hooks.SessionStart.hooks]]",
                    'type = "prompt"',
                    "",
                    "[[hooks.Stop]]",
                    "",
                    "[[hooks.Stop.hooks]]",
                    'type = "agent"',
                    "",
                    "[experimental_network]",
                    "enabled = true",
                    "http_port = 19080",
                    "socks_port = 19081",
                    "allow_upstream_proxy = false",
                    "dangerously_allow_non_loopback_proxy = true",
                    "dangerously_allow_all_unix_sockets = false",
                    "managed_allowed_domains_only = true",
                    "allow_local_binding = true",
                    "",
                    "[experimental_network.domains]",
                    '"api.openai.com" = "allow"',
                    '"blocked.example.com" = "deny"',
                    "",
                    "[experimental_network.unix_sockets]",
                    '"/tmp/codex-zig.sock" = "allow"',
                    '"/tmp/blocked.sock" = "none"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        managed_config_path.write_text(
            "\n".join(
                [
                    'approval_policy = "never"',
                    'approvals_reviewer = "auto_review"',
                    'sandbox_mode = "workspace-write"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        config_requirements_managed = rpc_without_params(
            "config-requirements-read-managed",
            "configRequirements/read",
        )
        assert config_requirements_managed["id"] == "config-requirements-read-managed"
        assert config_requirements_managed["result"] == {
            "requirements": {
                "allowedApprovalPolicies": ["on-request"],
                "allowedApprovalsReviewers": ["guardian_subagent", "user"],
                "allowedSandboxModes": ["danger-full-access"],
                "allowedWebSearchModes": ["cached", "disabled"],
                "featureRequirements": {"apps": False, "goals": True},
                "hooks": {
                    "managedDir": "/tmp/codex-managed-hooks",
                    "windowsManagedDir": "C:\\codex\\hooks",
                    "PreToolUse": [
                        {
                            "matcher": "^Bash$",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "python3 /tmp/codex-managed-hooks/pre.py",
                                    "timeoutSec": 10,
                                    "async": True,
                                    "statusMessage": "checking managed hook",
                                }
                            ],
                        }
                    ],
                    "PermissionRequest": [],
                    "PostToolUse": [],
                    "PreCompact": [],
                    "PostCompact": [],
                    "SessionStart": [{"hooks": [{"type": "prompt"}]}],
                    "UserPromptSubmit": [],
                    "Stop": [{"hooks": [{"type": "agent"}]}],
                },
                "enforceResidency": "us",
                "network": {
                    "enabled": True,
                    "httpPort": 19080,
                    "socksPort": 19081,
                    "allowUpstreamProxy": False,
                    "dangerouslyAllowNonLoopbackProxy": True,
                    "dangerouslyAllowAllUnixSockets": False,
                    "domains": {
                        "api.openai.com": "allow",
                        "blocked.example.com": "deny",
                    },
                    "managedAllowedDomainsOnly": True,
                    "allowedDomains": ["api.openai.com"],
                    "deniedDomains": ["blocked.example.com"],
                    "unixSockets": {
                        "/tmp/blocked.sock": "none",
                        "/tmp/codex-zig.sock": "allow",
                    },
                    "allowUnixSockets": ["/tmp/codex-zig.sock"],
                    "allowLocalBinding": True,
                },
            }
        }

        system_requirements_path.write_text(
            "\n".join(
                [
                    "[experimental_network]",
                    'allowed_domains = ["api.legacy.example", "shared.example"]',
                    'denied_domains = ["blocked.legacy.example", "shared.example"]',
                    'allow_unix_sockets = ["/tmp/legacy.sock"]',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        config_requirements_legacy_network = rpc_without_params(
            "config-requirements-read-legacy-network",
            "configRequirements/read",
        )
        assert config_requirements_legacy_network["id"] == "config-requirements-read-legacy-network"
        assert config_requirements_legacy_network["result"] == {
            "requirements": {
                "allowedApprovalPolicies": ["never"],
                "allowedApprovalsReviewers": ["guardian_subagent", "user"],
                "allowedSandboxModes": ["read-only", "workspace-write"],
                "network": {
                    "domains": {
                        "api.legacy.example": "allow",
                        "blocked.legacy.example": "deny",
                        "shared.example": "deny",
                    },
                    "allowedDomains": ["api.legacy.example"],
                    "deniedDomains": ["blocked.legacy.example", "shared.example"],
                    "unixSockets": {"/tmp/legacy.sock": "allow"},
                    "allowUnixSockets": ["/tmp/legacy.sock"],
                },
            }
        }

        system_requirements_path.unlink()
        config_requirements_legacy = rpc_without_params(
            "config-requirements-read-legacy",
            "configRequirements/read",
        )
        assert config_requirements_legacy["id"] == "config-requirements-read-legacy"
        assert config_requirements_legacy["result"] == {
            "requirements": {
                "allowedApprovalPolicies": ["never"],
                "allowedApprovalsReviewers": ["guardian_subagent", "user"],
                "allowedSandboxModes": ["read-only", "workspace-write"],
            }
        }

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
        assert after_features["goals"] is True
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

        (codex_home / "config.toml").write_text(
            "\n".join(
                [
                    "[tools]",
                    "web_search = true",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        bool_tool_config = rpc("config-read-bool-web-search-tool", "config/read", {})
        assert bool_tool_config["id"] == "config-read-bool-web-search-tool"
        assert bool_tool_config["result"]["config"]["tools"] == {
            "web_search": {
                "context_size": "low",
                "allowed_domains": ["system.example"],
                "location": {
                    "country": None,
                    "region": "CA",
                    "city": None,
                    "timezone": None,
                },
            },
            "view_image": True,
        }
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
        shutil.rmtree(workspace, ignore_errors=True)


def run_config_read_empty_layers_rpc_smoke(binary: Path) -> None:
    codex_home = Path(tempfile.mkdtemp(prefix="codex-zig-app-server-config-empty-", dir="/tmp"))
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = str(codex_home / "missing-managed.toml")
    system_config_path = codex_home / "missing-system.toml"
    env["CODEX_APP_SERVER_SYSTEM_CONFIG_PATH"] = str(system_config_path)
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
                "id": "config-read-empty-layers",
                "method": "config/read",
                "params": {"includeLayers": True},
            },
        )
        config_read = read_json_line(proc, 5)
        assert config_read["id"] == "config-read-empty-layers"
        result = config_read["result"]
        assert result["origins"] == {}
        assert result["config"]["tools"] is None
        assert result["config"]["apps"] is None
        user_source = {"type": "user", "file": str(codex_home / "config.toml")}
        system_source = {"type": "system", "file": str(system_config_path)}
        layers = result["layers"]
        assert len(layers) == 2
        assert layers[0]["name"] == user_source
        assert layers[0]["version"].startswith("sha256:")
        assert layers[0]["config"] == {}
        assert layers[1]["name"] == system_source
        assert layers[1]["version"].startswith("sha256:")
        assert layers[1]["config"] == {}
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
    config_path.write_text(
        "\n".join(
            [
                'model = "gpt-old"',
                "",
                "[features]",
                "goals = false",
                "",
                "[mcp_servers.linear]",
                'bearer_token_env_var = "TOKEN"',
                'name = "linear"',
                'url = "https://linear.example"',
                "",
                "[mcp_servers.linear.env_http_headers]",
                'existing = "keep"',
                "",
                "[mcp_servers.linear.http_headers]",
                'alpha = "a"',
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

        table_upsert = rpc(
            "config-write-table-upsert",
            "config/value/write",
            {
                "filePath": str(config_path),
                "keyPath": "mcp_servers.linear",
                "value": {
                    "bearer_token_env_var": "NEW_TOKEN",
                    "http_headers": {
                        "alpha": "updated",
                        "beta": "b",
                    },
                    "name": "linear",
                    "url": "https://linear.example",
                },
                "mergeStrategy": "upsert",
                "expectedVersion": write_feature["result"]["version"],
            },
        )
        assert table_upsert["id"] == "config-write-table-upsert"
        assert table_upsert["result"]["status"] == "ok"
        upserted_contents = config_path.read_text(encoding="utf-8")
        assert 'bearer_token_env_var = "NEW_TOKEN"' in upserted_contents
        assert '[mcp_servers.linear.env_http_headers]\nexisting = "keep"' in upserted_contents
        assert 'alpha = "updated"' in upserted_contents
        assert 'beta = "b"' in upserted_contents

        table_replace = rpc(
            "config-write-table-replace",
            "config/value/write",
            {
                "filePath": str(config_path),
                "keyPath": "mcp_servers.linear",
                "value": {
                    "bearer_token_env_var": "REPLACED_TOKEN",
                    "http_headers": {
                        "alpha": "replaced",
                    },
                    "name": "linear",
                    "url": "https://linear.example",
                },
                "mergeStrategy": "replace",
                "expectedVersion": table_upsert["result"]["version"],
            },
        )
        assert table_replace["id"] == "config-write-table-replace"
        assert table_replace["result"]["status"] == "ok"
        replaced_contents = config_path.read_text(encoding="utf-8")
        assert 'bearer_token_env_var = "REPLACED_TOKEN"' in replaced_contents
        assert 'alpha = "replaced"' in replaced_contents
        assert "[mcp_servers.linear.env_http_headers]" not in replaced_contents
        assert 'existing = "keep"' not in replaced_contents
        assert 'beta = "b"' not in replaced_contents

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
        "\n".join(
            [
                'model = "gpt-old"',
                'approval_policy = "on-request"',
                "",
                "[features]",
                "goals = false",
                "",
                "[mcp_servers.linear]",
                'bearer_token_env_var = "TOKEN"',
                'name = "linear"',
                'url = "https://linear.example"',
                "",
                "[mcp_servers.linear.env_http_headers]",
                'existing = "keep"',
                "",
                "[mcp_servers.linear.http_headers]",
                'alpha = "a"',
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
                    {
                        "keyPath": "mcp_servers.linear",
                        "value": {
                            "bearer_token_env_var": "NEW_TOKEN",
                            "http_headers": {
                                "alpha": "updated",
                                "beta": "b",
                            },
                            "name": "linear",
                            "url": "https://linear.example",
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
        assert 'bearer_token_env_var = "NEW_TOKEN"' in contents
        assert '[mcp_servers.linear.env_http_headers]\nexisting = "keep"' in contents
        assert 'alpha = "updated"' in contents
        assert 'beta = "b"' in contents
        assert "approval_policy" not in contents

        batch_with_version = rpc(
            "config-batch-write-version",
            "config/batchWrite",
            {
                "filePath": str(config_path),
                "edits": [
                    {"keyPath": "sandbox_mode", "value": "workspace-write", "mergeStrategy": "replace"},
                    {
                        "keyPath": "sandbox_workspace_write",
                        "value": {
                            "writable_roots": ["/tmp/codex-zig-batch-root"],
                            "network_access": False,
                            "exclude_tmpdir_env_var": True,
                            "exclude_slash_tmp": True,
                        },
                        "mergeStrategy": "replace",
                    },
                    {
                        "keyPath": "mcp_servers.linear",
                        "value": {
                            "bearer_token_env_var": "REPLACED_TOKEN",
                            "http_headers": {
                                "alpha": "replaced",
                            },
                            "name": "linear",
                            "url": "https://linear.example",
                        },
                        "mergeStrategy": "replace",
                    },
                ],
                "expectedVersion": batch["result"]["version"],
            },
        )
        assert batch_with_version["id"] == "config-batch-write-version"
        assert batch_with_version["result"]["status"] == "ok"

        after_versioned_batch = rpc("config-read-after-versioned-batch", "config/read", {})
        assert after_versioned_batch["id"] == "config-read-after-versioned-batch"
        assert after_versioned_batch["result"]["config"]["sandbox_mode"] == "workspace-write"
        assert after_versioned_batch["result"]["config"]["sandbox_workspace_write"] == {
            "writable_roots": ["/tmp/codex-zig-batch-root"],
            "network_access": False,
            "exclude_tmpdir_env_var": True,
            "exclude_slash_tmp": True,
        }
        replaced_contents = config_path.read_text(encoding="utf-8")
        assert 'bearer_token_env_var = "REPLACED_TOKEN"' in replaced_contents
        assert 'alpha = "replaced"' in replaced_contents
        assert "[mcp_servers.linear.env_http_headers]" not in replaced_contents
        assert 'existing = "keep"' not in replaced_contents
        assert 'beta = "b"' not in replaced_contents

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


def start_command_exec_network_backend() -> tuple[ThreadingHTTPServer, str]:
    CommandExecNetworkHandler.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), CommandExecNetworkHandler)
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

            access_token = encode_unsigned_jwt(
                {
                    "email": "external@example.com",
                    "https://api.openai.com/auth": {
                        "chatgpt_plan_type": "pro",
                        "chatgpt_account_id": "acct_external",
                    },
                }
            )
            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "login-auth-tokens",
                    "method": "account/login/start",
                    "params": {
                        "type": "chatgptAuthTokens",
                        "accessToken": access_token,
                        "chatgptAccountId": "acct_external",
                        "chatgptPlanType": "pro",
                    },
                },
            )
            auth_tokens_login = read_json_line(proc, 5)
            assert auth_tokens_login["id"] == "login-auth-tokens"
            assert auth_tokens_login["result"] == {"type": "chatgptAuthTokens"}

            auth_tokens_completed = read_json_line(proc, 5)
            assert auth_tokens_completed == {
                "method": "account/login/completed",
                "params": {"loginId": None, "success": True, "error": None},
            }

            auth_tokens_updated = read_json_line(proc, 5)
            assert auth_tokens_updated == {
                "method": "account/updated",
                "params": {"authMode": "chatgptAuthTokens", "planType": "pro"},
            }

            auth_json = json.loads((codex_home / "auth.json").read_text(encoding="utf-8"))
            assert auth_json["auth_mode"] == "chatgptAuthTokens"
            assert auth_json["tokens"] == {
                "id_token": access_token,
                "access_token": access_token,
                "refresh_token": "",
                "account_id": "acct_external",
            }
            assert isinstance(auth_json["last_refresh"], str)

            write_json_line(proc, {"jsonrpc": "2.0", "id": "after-auth-token-login", "method": "account/read"})
            after_auth_token_login = read_json_line(proc, 5)
            assert after_auth_token_login["id"] == "after-auth-token-login"
            assert after_auth_token_login["result"] == {
                "account": {"type": "chatgpt", "email": "external@example.com", "planType": "pro"},
                "requiresOpenaiAuth": True,
            }

            write_json_line(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": "auth-token-status",
                    "method": "getAuthStatus",
                    "params": {"includeToken": True},
                },
            )
            auth_token_status = read_json_line(proc, 5)
            assert auth_token_status["id"] == "auth-token-status"
            assert auth_token_status["result"] == {
                "authMethod": "chatgptAuthTokens",
                "authToken": access_token,
                "requiresOpenaiAuth": True,
            }

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
                    "id": "missing-auth-token",
                    "method": "account/login/start",
                    "params": {"type": "chatgptAuthTokens", "chatgptAccountId": "acct_external"},
                },
            )
            missing_auth_token = read_json_line(proc, 5)
            assert missing_auth_token["id"] == "missing-auth-token"
            assert missing_auth_token["error"]["code"] == -32602

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
            "\n".join(
                [
                    'profile = "work"',
                    "[features]",
                    "apps = true",
                    "goals = false",
                    "[profiles.work.features]",
                    "apps = false",
                    "goals = true",
                    "",
                ]
            ),
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


def run_internal_json_schema_smoke(binary: Path) -> None:
    out_dir = Path(tempfile.mkdtemp(prefix="codex-zig-internal-schema-", dir="/tmp"))
    try:
        proc = subprocess.run(
            [
                str(binary),
                "app-server",
                "generate-internal-json-schema",
                "-o",
                str(out_dir),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        schema_path = out_dir / "RolloutLine.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        assert schema["title"] == "RolloutLine"
        assert schema["required"] == ["timestamp", "type", "payload"]
        assert schema["properties"]["timestamp"]["type"] == "string"
        assert schema["properties"]["payload"]["type"] == "object"
        assert schema["properties"]["type"]["enum"] == [
            "session_meta",
            "response_item",
            "compacted",
            "turn_context",
            "event_msg",
        ]

        missing_out = subprocess.run(
            [str(binary), "app-server", "generate-internal-json-schema"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert missing_out.returncode != 0
        assert "MissingAppServerGenerateInternalJsonSchemaOutDir" in missing_out.stderr
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


def run_json_schema_smoke(binary: Path) -> None:
    out_dir = Path(tempfile.mkdtemp(prefix="codex-zig-json-schema-", dir="/tmp"))
    try:
        proc = subprocess.run(
            [
                str(binary),
                "app-server",
                "generate-json-schema",
                "--out",
                str(out_dir),
                "--experimental",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr

        request_id = json.loads((out_dir / "RequestId.json").read_text(encoding="utf-8"))
        assert request_id["title"] == "RequestId"
        assert request_id["oneOf"][0]["type"] == "string"
        assert request_id["oneOf"][1]["type"] == "integer"

        request = json.loads((out_dir / "JSONRPCRequest.json").read_text(encoding="utf-8"))
        assert request["title"] == "JSONRPCRequest"
        assert request["required"] == ["id", "method"]
        assert request["properties"]["id"]["$ref"] == "RequestId.json"

        initialize = json.loads((out_dir / "InitializeParams.json").read_text(encoding="utf-8"))
        assert initialize["title"] == "InitializeParams"
        assert initialize["required"] == ["clientInfo"]

        command_exec = json.loads((out_dir / "CommandExecParams.json").read_text(encoding="utf-8"))
        assert command_exec["title"] == "CommandExecParams"
        assert command_exec["required"] == ["command"]
        assert command_exec["properties"]["command"]["items"]["type"] == "string"
        assert command_exec["properties"]["sandboxPolicy"]["oneOf"][0]["$ref"] == "SandboxPolicy.json"
        assert command_exec["properties"]["permissionProfile"]["oneOf"][0]["$ref"] == "PermissionProfile.json"
        absolute_path = json.loads((out_dir / "AbsolutePathBuf.json").read_text(encoding="utf-8"))
        assert absolute_path["title"] == "AbsolutePathBuf"
        assert absolute_path["type"] == "string"
        network_access = json.loads((out_dir / "NetworkAccess.json").read_text(encoding="utf-8"))
        assert network_access["enum"] == ["restricted", "enabled"]
        sandbox_policy = json.loads((out_dir / "SandboxPolicy.json").read_text(encoding="utf-8"))
        external_policy = sandbox_policy["oneOf"][2]
        assert external_policy["properties"]["type"]["const"] == "externalSandbox"
        assert (
            external_policy["properties"]["networkAccess"]["allOf"][0]["$ref"]
            == "NetworkAccess.json"
        )
        workspace_policy = sandbox_policy["oneOf"][3]
        assert workspace_policy["properties"]["type"]["const"] == "workspaceWrite"
        assert workspace_policy["properties"]["writableRoots"]["items"]["$ref"] == "AbsolutePathBuf.json"
        assert workspace_policy["properties"]["writableRoots"]["default"] == []
        filesystem_path = json.loads((out_dir / "FileSystemPath.json").read_text(encoding="utf-8"))
        assert filesystem_path["oneOf"][0]["properties"]["path"]["$ref"] == "AbsolutePathBuf.json"
        assert filesystem_path["oneOf"][2]["properties"]["value"]["$ref"] == "FileSystemSpecialPath.json"
        filesystem_entry = json.loads(
            (out_dir / "FileSystemSandboxEntry.json").read_text(encoding="utf-8")
        )
        assert filesystem_entry["properties"]["path"]["$ref"] == "FileSystemPath.json"
        assert filesystem_entry["properties"]["access"]["$ref"] == "FileSystemAccessMode.json"
        permission_profile_file_system = json.loads(
            (out_dir / "PermissionProfileFileSystemPermissions.json").read_text(
                encoding="utf-8"
            )
        )
        assert (
            permission_profile_file_system["oneOf"][0]["properties"]["entries"]["items"]["$ref"]
            == "FileSystemSandboxEntry.json"
        )
        assert (
            "globScanMaxDepth"
            in permission_profile_file_system["oneOf"][0]["properties"]
        )
        permission_profile_network = json.loads(
            (out_dir / "PermissionProfileNetworkPermissions.json").read_text(
                encoding="utf-8"
            )
        )
        assert permission_profile_network["required"] == ["enabled"]
        permission_profile = json.loads((out_dir / "PermissionProfile.json").read_text(encoding="utf-8"))
        assert permission_profile["title"] == "PermissionProfile"
        managed_profile = permission_profile["oneOf"][0]
        assert managed_profile["required"] == ["type", "fileSystem", "network"]
        assert (
            managed_profile["properties"]["fileSystem"]["$ref"]
            == "PermissionProfileFileSystemPermissions.json"
        )
        assert (
            managed_profile["properties"]["network"]["$ref"]
            == "PermissionProfileNetworkPermissions.json"
        )
        command_exec_output_delta = json.loads(
            (out_dir / "CommandExecOutputDeltaNotification.json").read_text(
                encoding="utf-8"
            )
        )
        assert command_exec_output_delta["title"] == "CommandExecOutputDeltaNotification"
        assert command_exec_output_delta["properties"]["stream"]["enum"] == [
            "stdout",
            "stderr",
        ]
        command_exec_write_response = json.loads(
            (out_dir / "CommandExecWriteResponse.json").read_text(encoding="utf-8")
        )
        assert command_exec_write_response["title"] == "CommandExecWriteResponse"
        assert command_exec_write_response["additionalProperties"] is False
        thread_loaded_list = json.loads(
            (out_dir / "ThreadLoadedListParams.json").read_text(encoding="utf-8")
        )
        assert thread_loaded_list["title"] == "ThreadLoadedListParams"
        assert thread_loaded_list["properties"]["limit"]["maximum"] == 4294967295
        thread_loaded_list_response = json.loads(
            (out_dir / "ThreadLoadedListResponse.json").read_text(encoding="utf-8")
        )
        assert thread_loaded_list_response["required"] == ["data", "nextCursor"]
        thread_start_params_schema = json.loads(
            (out_dir / "ThreadStartParams.json").read_text(encoding="utf-8")
        )
        assert thread_start_params_schema["title"] == "ThreadStartParams"
        assert thread_start_params_schema["properties"]["approvalPolicy"]["enum"] == [
            "untrusted",
            "on-failure",
            "on-request",
            "never",
            None,
        ]
        thread_start_response_schema = json.loads(
            (out_dir / "ThreadStartResponse.json").read_text(encoding="utf-8")
        )
        assert thread_start_response_schema["required"][0] == "thread"
        thread_started_notification_schema = json.loads(
            (out_dir / "ThreadStartedNotification.json").read_text(encoding="utf-8")
        )
        assert thread_started_notification_schema["title"] == "ThreadStartedNotification"
        assert thread_started_notification_schema["required"] == ["thread"]
        turn_start_params_schema = json.loads(
            (out_dir / "TurnStartParams.json").read_text(encoding="utf-8")
        )
        assert turn_start_params_schema["required"] == ["threadId", "input"]
        assert turn_start_params_schema["properties"]["input"]["type"] == "array"
        turn_start_response_schema = json.loads(
            (out_dir / "TurnStartResponse.json").read_text(encoding="utf-8")
        )
        assert turn_start_response_schema["required"] == ["turn"]
        turn_started_notification_schema = json.loads(
            (out_dir / "TurnStartedNotification.json").read_text(encoding="utf-8")
        )
        assert turn_started_notification_schema["required"] == ["threadId", "turn"]
        turn_completed_notification_schema = json.loads(
            (out_dir / "TurnCompletedNotification.json").read_text(encoding="utf-8")
        )
        assert turn_completed_notification_schema["required"] == ["threadId", "turn"]
        item_started_notification_schema = json.loads(
            (out_dir / "ItemStartedNotification.json").read_text(encoding="utf-8")
        )
        assert item_started_notification_schema["required"] == [
            "item",
            "threadId",
            "turnId",
            "startedAtMs",
        ]
        item_completed_notification_schema = json.loads(
            (out_dir / "ItemCompletedNotification.json").read_text(encoding="utf-8")
        )
        assert item_completed_notification_schema["required"] == [
            "item",
            "threadId",
            "turnId",
            "completedAtMs",
        ]
        agent_message_delta_notification_schema = json.loads(
            (out_dir / "AgentMessageDeltaNotification.json").read_text(encoding="utf-8")
        )
        assert agent_message_delta_notification_schema["required"] == [
            "threadId",
            "turnId",
            "itemId",
            "delta",
        ]
        thread_resume_params_schema = json.loads(
            (out_dir / "ThreadResumeParams.json").read_text(encoding="utf-8")
        )
        assert thread_resume_params_schema["required"] == ["threadId"]
        assert thread_resume_params_schema["properties"]["history"]["type"] == [
            "array",
            "null",
        ]
        assert thread_resume_params_schema["properties"]["path"]["type"] == [
            "string",
            "null",
        ]
        thread_resume_response_schema = json.loads(
            (out_dir / "ThreadResumeResponse.json").read_text(encoding="utf-8")
        )
        assert thread_resume_response_schema["required"][0] == "thread"
        thread_fork_params_schema = json.loads(
            (out_dir / "ThreadForkParams.json").read_text(encoding="utf-8")
        )
        assert thread_fork_params_schema["required"] == ["threadId"]
        assert thread_fork_params_schema["properties"]["path"]["type"] == [
            "string",
            "null",
        ]
        assert thread_fork_params_schema["properties"]["excludeTurns"]["type"] == "boolean"
        thread_fork_response_schema = json.loads(
            (out_dir / "ThreadForkResponse.json").read_text(encoding="utf-8")
        )
        assert thread_fork_response_schema["required"][0] == "thread"
        thread_unsubscribe = json.loads(
            (out_dir / "ThreadUnsubscribeParams.json").read_text(encoding="utf-8")
        )
        assert thread_unsubscribe["required"] == ["threadId"]
        thread_unsubscribe_status = json.loads(
            (out_dir / "ThreadUnsubscribeStatus.json").read_text(encoding="utf-8")
        )
        assert thread_unsubscribe_status["enum"] == [
            "notLoaded",
            "notSubscribed",
            "unsubscribed",
        ]
        thread_archive = json.loads(
            (out_dir / "ThreadArchiveParams.json").read_text(encoding="utf-8")
        )
        assert thread_archive["required"] == ["threadId"]
        thread_archive_response = json.loads(
            (out_dir / "ThreadArchiveResponse.json").read_text(encoding="utf-8")
        )
        assert thread_archive_response["additionalProperties"] is False
        thread_unarchive = json.loads(
            (out_dir / "ThreadUnarchiveParams.json").read_text(encoding="utf-8")
        )
        assert thread_unarchive["required"] == ["threadId"]
        thread_unarchive_response = json.loads(
            (out_dir / "ThreadUnarchiveResponse.json").read_text(encoding="utf-8")
        )
        assert thread_unarchive_response["required"] == ["thread"]
        assert thread_unarchive_response["additionalProperties"] is False
        thread_compact_start = json.loads(
            (out_dir / "ThreadCompactStartParams.json").read_text(encoding="utf-8")
        )
        assert thread_compact_start["required"] == ["threadId"]
        thread_compact_start_response = json.loads(
            (out_dir / "ThreadCompactStartResponse.json").read_text(encoding="utf-8")
        )
        assert thread_compact_start_response["additionalProperties"] is False
        thread_shell_command = json.loads(
            (out_dir / "ThreadShellCommandParams.json").read_text(encoding="utf-8")
        )
        assert thread_shell_command["required"] == ["threadId", "command"]
        thread_shell_command_response = json.loads(
            (out_dir / "ThreadShellCommandResponse.json").read_text(encoding="utf-8")
        )
        assert thread_shell_command_response["additionalProperties"] is False
        thread_guardian_approval = json.loads(
            (out_dir / "ThreadApproveGuardianDeniedActionParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_guardian_approval["required"] == ["threadId", "event"]
        assert (
            "GuardianAssessmentEvent"
            in thread_guardian_approval["properties"]["event"]["description"]
        )
        thread_guardian_approval_response = json.loads(
            (
                out_dir / "ThreadApproveGuardianDeniedActionResponse.json"
            ).read_text(encoding="utf-8")
        )
        assert thread_guardian_approval_response["additionalProperties"] is False
        thread_background_clean = json.loads(
            (out_dir / "ThreadBackgroundTerminalsCleanParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_background_clean["required"] == ["threadId"]
        thread_background_clean_response = json.loads(
            (out_dir / "ThreadBackgroundTerminalsCleanResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_background_clean_response["additionalProperties"] is False
        thread_increment_elicitation = json.loads(
            (out_dir / "ThreadIncrementElicitationParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_increment_elicitation["required"] == ["threadId"]
        thread_increment_elicitation_response = json.loads(
            (out_dir / "ThreadIncrementElicitationResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_increment_elicitation_response["required"] == ["count", "paused"]
        thread_decrement_elicitation = json.loads(
            (out_dir / "ThreadDecrementElicitationParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_decrement_elicitation["required"] == ["threadId"]
        thread_decrement_elicitation_response = json.loads(
            (out_dir / "ThreadDecrementElicitationResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_decrement_elicitation_response["required"] == ["count", "paused"]
        sort_direction = json.loads(
            (out_dir / "SortDirection.json").read_text(encoding="utf-8")
        )
        assert sort_direction["enum"] == ["asc", "desc"]
        thread_sort_key = json.loads(
            (out_dir / "ThreadSortKey.json").read_text(encoding="utf-8")
        )
        assert thread_sort_key["enum"] == ["created_at", "updated_at"]
        thread_source_kind = json.loads(
            (out_dir / "ThreadSourceKind.json").read_text(encoding="utf-8")
        )
        assert "subAgentThreadSpawn" in thread_source_kind["enum"]
        thread_rollback = json.loads(
            (out_dir / "ThreadRollbackParams.json").read_text(encoding="utf-8")
        )
        assert thread_rollback["required"] == ["threadId", "numTurns"]
        assert thread_rollback["properties"]["numTurns"]["maximum"] == 4294967295
        thread_rollback_response = json.loads(
            (out_dir / "ThreadRollbackResponse.json").read_text(encoding="utf-8")
        )
        assert thread_rollback_response["required"] == ["thread"]
        assert thread_rollback_response["additionalProperties"] is False
        thread_list = json.loads(
            (out_dir / "ThreadListParams.json").read_text(encoding="utf-8")
        )
        assert thread_list["properties"]["limit"]["maximum"] == 4294967295
        assert thread_list["properties"]["useStateDbOnly"]["type"] == "boolean"
        thread_list_response = json.loads(
            (out_dir / "ThreadListResponse.json").read_text(encoding="utf-8")
        )
        assert thread_list_response["required"] == [
            "data",
            "nextCursor",
            "backwardsCursor",
        ]
        assert thread_list_response["additionalProperties"] is False
        thread_inject_items = json.loads(
            (out_dir / "ThreadInjectItemsParams.json").read_text(encoding="utf-8")
        )
        assert thread_inject_items["required"] == ["threadId", "items"]
        assert thread_inject_items["properties"]["items"]["type"] == "array"
        thread_inject_items_response = json.loads(
            (out_dir / "ThreadInjectItemsResponse.json").read_text(encoding="utf-8")
        )
        assert thread_inject_items_response["additionalProperties"] is False
        thread_set_name = json.loads(
            (out_dir / "ThreadSetNameParams.json").read_text(encoding="utf-8")
        )
        assert thread_set_name["required"] == ["threadId", "name"]
        assert thread_set_name["properties"]["name"]["type"] == "string"
        thread_set_name_response = json.loads(
            (out_dir / "ThreadSetNameResponse.json").read_text(encoding="utf-8")
        )
        assert thread_set_name_response["additionalProperties"] is False
        thread_goal_status = json.loads(
            (out_dir / "ThreadGoalStatus.json").read_text(encoding="utf-8")
        )
        assert thread_goal_status["enum"] == [
            "active",
            "paused",
            "budgetLimited",
            "complete",
        ]
        thread_goal = json.loads(
            (out_dir / "ThreadGoal.json").read_text(encoding="utf-8")
        )
        assert thread_goal["required"] == [
            "threadId",
            "objective",
            "status",
            "tokenBudget",
            "tokensUsed",
            "timeUsedSeconds",
            "createdAt",
            "updatedAt",
        ]
        thread_goal_set = json.loads(
            (out_dir / "ThreadGoalSetParams.json").read_text(encoding="utf-8")
        )
        assert thread_goal_set["required"] == ["threadId"]
        assert thread_goal_set["properties"]["tokenBudget"]["type"] == [
            "integer",
            "null",
        ]
        thread_goal_set_response = json.loads(
            (out_dir / "ThreadGoalSetResponse.json").read_text(encoding="utf-8")
        )
        assert thread_goal_set_response["properties"]["goal"]["$ref"] == (
            "#/$defs/ThreadGoal"
        )
        thread_goal_get = json.loads(
            (out_dir / "ThreadGoalGetParams.json").read_text(encoding="utf-8")
        )
        assert thread_goal_get["required"] == ["threadId"]
        thread_goal_get_response = json.loads(
            (out_dir / "ThreadGoalGetResponse.json").read_text(encoding="utf-8")
        )
        assert thread_goal_get_response["required"] == ["goal"]
        thread_goal_clear = json.loads(
            (out_dir / "ThreadGoalClearParams.json").read_text(encoding="utf-8")
        )
        assert thread_goal_clear["required"] == ["threadId"]
        thread_goal_clear_response = json.loads(
            (out_dir / "ThreadGoalClearResponse.json").read_text(encoding="utf-8")
        )
        assert thread_goal_clear_response["required"] == ["cleared"]
        thread_memory_mode = json.loads(
            (out_dir / "ThreadMemoryMode.json").read_text(encoding="utf-8")
        )
        assert thread_memory_mode["enum"] == ["enabled", "disabled"]
        realtime_voice = json.loads(
            (out_dir / "RealtimeVoice.json").read_text(encoding="utf-8")
        )
        assert realtime_voice["enum"] == EXPECTED_REALTIME_VOICE_ENUM
        realtime_output_modality = json.loads(
            (out_dir / "RealtimeOutputModality.json").read_text(encoding="utf-8")
        )
        assert realtime_output_modality["enum"] == ["text", "audio"]
        realtime_voices_list = json.loads(
            (out_dir / "RealtimeVoicesList.json").read_text(encoding="utf-8")
        )
        assert realtime_voices_list["required"] == [
            "v1",
            "v2",
            "defaultV1",
            "defaultV2",
        ]
        assert (
            realtime_voices_list["properties"]["v1"]["items"]["$ref"]
            == "#/$defs/RealtimeVoice"
        )
        thread_memory_mode_set = json.loads(
            (out_dir / "ThreadMemoryModeSetParams.json").read_text(encoding="utf-8")
        )
        assert thread_memory_mode_set["required"] == ["threadId", "mode"]
        assert thread_memory_mode_set["properties"]["mode"]["enum"] == [
            "enabled",
            "disabled",
        ]
        thread_memory_mode_set_response = json.loads(
            (out_dir / "ThreadMemoryModeSetResponse.json").read_text(encoding="utf-8")
        )
        assert thread_memory_mode_set_response["additionalProperties"] is False
        thread_metadata_git_info = json.loads(
            (out_dir / "ThreadMetadataGitInfoUpdateParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_metadata_git_info["properties"]["sha"]["type"] == [
            "string",
            "null",
        ]
        thread_metadata_update = json.loads(
            (out_dir / "ThreadMetadataUpdateParams.json").read_text(encoding="utf-8")
        )
        assert thread_metadata_update["required"] == ["threadId"]
        assert "gitInfo" in thread_metadata_update["properties"]
        thread_metadata_update_response = json.loads(
            (out_dir / "ThreadMetadataUpdateResponse.json").read_text(encoding="utf-8")
        )
        assert thread_metadata_update_response["required"] == ["thread"]
        assert thread_metadata_update_response["additionalProperties"] is False
        thread_read = json.loads(
            (out_dir / "ThreadReadParams.json").read_text(encoding="utf-8")
        )
        assert thread_read["required"] == ["threadId"]
        assert thread_read["properties"]["includeTurns"]["type"] == "boolean"
        assert thread_read["properties"]["includeTurns"]["default"] is False
        thread_read_response = json.loads(
            (out_dir / "ThreadReadResponse.json").read_text(encoding="utf-8")
        )
        assert thread_read_response["required"] == ["thread"]
        assert thread_read_response["additionalProperties"] is False
        thread_turns_list = json.loads(
            (out_dir / "ThreadTurnsListParams.json").read_text(encoding="utf-8")
        )
        assert thread_turns_list["required"] == ["threadId"]
        assert thread_turns_list["properties"]["limit"]["maximum"] == 4294967295
        assert "sortDirection" in thread_turns_list["properties"]
        thread_turns_list_response = json.loads(
            (out_dir / "ThreadTurnsListResponse.json").read_text(encoding="utf-8")
        )
        assert thread_turns_list_response["required"] == [
            "data",
            "nextCursor",
            "backwardsCursor",
        ]
        assert thread_turns_list_response["additionalProperties"] is False
        thread_realtime_list_voices = json.loads(
            (out_dir / "ThreadRealtimeListVoicesParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_list_voices["type"] == "object"
        thread_realtime_list_voices_response = json.loads(
            (out_dir / "ThreadRealtimeListVoicesResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_list_voices_response["required"] == ["voices"]
        assert (
            thread_realtime_list_voices_response["properties"]["voices"]["$ref"]
            == "#/$defs/RealtimeVoicesList"
        )
        thread_realtime_start_transport = json.loads(
            (out_dir / "ThreadRealtimeStartTransport.json").read_text(
                encoding="utf-8"
            )
        )
        assert len(thread_realtime_start_transport["oneOf"]) == 2
        thread_realtime_start = json.loads(
            (out_dir / "ThreadRealtimeStartParams.json").read_text(encoding="utf-8")
        )
        assert thread_realtime_start["required"] == ["threadId", "outputModality"]
        assert (
            thread_realtime_start["properties"]["outputModality"]["$ref"]
            == "#/$defs/RealtimeOutputModality"
        )
        thread_realtime_start_response = json.loads(
            (out_dir / "ThreadRealtimeStartResponse.json").read_text(encoding="utf-8")
        )
        assert thread_realtime_start_response["additionalProperties"] is False
        thread_realtime_stop = json.loads(
            (out_dir / "ThreadRealtimeStopParams.json").read_text(encoding="utf-8")
        )
        assert thread_realtime_stop["required"] == ["threadId"]
        assert thread_realtime_stop["properties"]["threadId"]["type"] == "string"
        thread_realtime_stop_response = json.loads(
            (out_dir / "ThreadRealtimeStopResponse.json").read_text(encoding="utf-8")
        )
        assert thread_realtime_stop_response["additionalProperties"] is False
        thread_realtime_append_text = json.loads(
            (out_dir / "ThreadRealtimeAppendTextParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_append_text["required"] == ["threadId", "text"]
        assert thread_realtime_append_text["properties"]["threadId"]["type"] == "string"
        assert thread_realtime_append_text["properties"]["text"]["type"] == "string"
        thread_realtime_append_text_response = json.loads(
            (out_dir / "ThreadRealtimeAppendTextResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_append_text_response["additionalProperties"] is False
        thread_realtime_audio_chunk = json.loads(
            (out_dir / "ThreadRealtimeAudioChunk.json").read_text(encoding="utf-8")
        )
        assert thread_realtime_audio_chunk["required"] == [
            "data",
            "numChannels",
            "sampleRate",
        ]
        assert thread_realtime_audio_chunk["properties"]["sampleRate"]["maximum"] == 4294967295
        assert thread_realtime_audio_chunk["properties"]["numChannels"]["maximum"] == 65535
        thread_realtime_append_audio = json.loads(
            (out_dir / "ThreadRealtimeAppendAudioParams.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_append_audio["required"] == ["threadId", "audio"]
        assert (
            thread_realtime_append_audio["properties"]["audio"]["$ref"]
            == "#/$defs/ThreadRealtimeAudioChunk"
        )
        thread_realtime_append_audio_response = json.loads(
            (out_dir / "ThreadRealtimeAppendAudioResponse.json").read_text(
                encoding="utf-8"
            )
        )
        assert thread_realtime_append_audio_response["additionalProperties"] is False

        bundle = json.loads(
            (out_dir / "codex_app_server_protocol.schemas.json").read_text(encoding="utf-8")
        )
        assert bundle["title"] == "codex_app_server_protocol.schemas"
        assert "JSONRPCMessage" in bundle["$defs"]
        assert "InitializeResponse" in bundle["$defs"]
        assert "CommandExecParams" in bundle["$defs"]
        assert "CommandExecOutputDeltaNotification" in bundle["$defs"]
        assert "ThreadLoadedListParams" in bundle["$defs"]
        assert "ThreadUnsubscribeResponse" in bundle["$defs"]
        assert "ThreadArchiveResponse" in bundle["$defs"]
        assert "ThreadUnarchiveResponse" in bundle["$defs"]
        assert "ThreadCompactStartResponse" in bundle["$defs"]
        assert "ThreadShellCommandResponse" in bundle["$defs"]
        assert "ThreadApproveGuardianDeniedActionResponse" in bundle["$defs"]
        assert "ThreadBackgroundTerminalsCleanResponse" in bundle["$defs"]
        assert "ThreadIncrementElicitationResponse" in bundle["$defs"]
        assert "ThreadDecrementElicitationResponse" in bundle["$defs"]
        assert "ThreadRollbackResponse" in bundle["$defs"]
        assert "ThreadListResponse" in bundle["$defs"]
        assert "ThreadInjectItemsResponse" in bundle["$defs"]
        assert "ThreadSetNameResponse" in bundle["$defs"]
        assert "ThreadGoal" in bundle["$defs"]
        assert "ThreadGoalStatus" in bundle["$defs"]
        assert "ThreadGoalSetResponse" in bundle["$defs"]
        assert "ThreadGoalGetResponse" in bundle["$defs"]
        assert "ThreadGoalClearResponse" in bundle["$defs"]
        assert "ThreadMemoryModeSetResponse" in bundle["$defs"]
        assert "ThreadMetadataUpdateResponse" in bundle["$defs"]
        assert "ThreadReadResponse" in bundle["$defs"]
        assert "ThreadTurnsListResponse" in bundle["$defs"]
        assert "RealtimeVoice" in bundle["$defs"]
        assert "RealtimeOutputModality" in bundle["$defs"]
        assert "RealtimeVoicesList" in bundle["$defs"]
        assert "ThreadRealtimeListVoicesResponse" in bundle["$defs"]
        assert "ThreadRealtimeStartResponse" in bundle["$defs"]
        assert "ThreadRealtimeStopResponse" in bundle["$defs"]
        assert "ThreadRealtimeAppendTextResponse" in bundle["$defs"]
        assert "ThreadRealtimeAudioChunk" in bundle["$defs"]
        assert "ThreadRealtimeAppendAudioResponse" in bundle["$defs"]
        assert bundle["$defs"]["SandboxPolicy"]["oneOf"][2]["properties"]["type"]["const"] == "externalSandbox"
        assert (
            bundle["$defs"]["SandboxPolicy"]["oneOf"][3]["properties"]["writableRoots"]["items"]["$ref"]
            == "#/$defs/AbsolutePathBuf"
        )
        assert (
            bundle["$defs"]["PermissionProfile"]["oneOf"][0]["properties"]["fileSystem"]["$ref"]
            == "#/$defs/PermissionProfileFileSystemPermissions"
        )
        assert (
            bundle["$defs"]["CommandExecParams"]["properties"]["sandboxPolicy"]["oneOf"][0]["$ref"]
            == "#/$defs/SandboxPolicy"
        )
        assert (
            bundle["$defs"]["CommandExecParams"]["properties"]["permissionProfile"]["oneOf"][0]["$ref"]
            == "#/$defs/PermissionProfile"
        )
        assert "ThreadStartParams" in bundle["$defs"]
        assert "ThreadStartResponse" in bundle["$defs"]
        assert bundle["$defs"]["ThreadStartParams"]["properties"]["threadSource"]["enum"] == [
            "user",
            "subagent",
            "memory_consolidation",
            None,
        ]
        assert "TurnStartParams" in bundle["$defs"]
        assert "TurnStartResponse" in bundle["$defs"]
        assert "TurnStartedNotification" in bundle["$defs"]
        assert "TurnCompletedNotification" in bundle["$defs"]
        assert "ItemStartedNotification" in bundle["$defs"]
        assert "ItemCompletedNotification" in bundle["$defs"]
        assert "AgentMessageDeltaNotification" in bundle["$defs"]
        assert "ThreadResumeParams" in bundle["$defs"]
        assert bundle["$defs"]["ThreadResumeParams"]["properties"]["history"]["type"] == [
            "array",
            "null",
        ]
        assert "ThreadResumeResponse" in bundle["$defs"]
        assert "ThreadForkParams" in bundle["$defs"]
        assert bundle["$defs"]["ThreadForkParams"]["properties"]["path"]["type"] == [
            "string",
            "null",
        ]
        assert "ThreadForkResponse" in bundle["$defs"]
        v2_bundle = json.loads(
            (out_dir / "codex_app_server_protocol.v2.schemas.json").read_text(encoding="utf-8")
        )
        assert v2_bundle["$defs"]["JSONRPCMessage"] == bundle["$defs"]["JSONRPCMessage"]
        assert v2_bundle["$defs"]["CommandExecResponse"] == bundle["$defs"]["CommandExecResponse"]
        assert (
            v2_bundle["$defs"]["ThreadUnsubscribeResponse"]
            == bundle["$defs"]["ThreadUnsubscribeResponse"]
        )

        missing_out = subprocess.run(
            [str(binary), "app-server", "generate-json-schema"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert missing_out.returncode != 0
        assert "MissingAppServerGenerateJsonSchemaOutDir" in missing_out.stderr
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


def run_typescript_generation_smoke(binary: Path) -> None:
    out_dir = Path(tempfile.mkdtemp(prefix="codex-zig-typescript-", dir="/tmp"))
    try:
        proc = subprocess.run(
            [
                str(binary),
                "app-server",
                "generate-ts",
                "--out",
                str(out_dir),
                "--experimental",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr

        request_id = (out_dir / "RequestId.ts").read_text(encoding="utf-8")
        assert request_id.startswith("// GENERATED CODE! DO NOT MODIFY BY HAND!")
        assert "export type RequestId = string | number;" in request_id

        initialize = (out_dir / "InitializeParams.ts").read_text(encoding="utf-8")
        assert "export interface InitializeParams" in initialize
        assert "clientInfo: ClientInfo;" in initialize

        absolute_path = (out_dir / "AbsolutePathBuf.ts").read_text(encoding="utf-8")
        assert "export type AbsolutePathBuf = string;" in absolute_path

        client_request = (out_dir / "ClientRequest.ts").read_text(encoding="utf-8")
        assert 'method: "initialize";' in client_request
        assert "params: InitializeParams;" in client_request
        assert 'method: "command/exec";' in client_request
        assert "params: CommandExecParams;" in client_request
        assert 'method: "command/exec/write";' in client_request
        assert "params: CommandExecWriteParams;" in client_request
        assert 'method: "thread/start";' in client_request
        assert "params?: ThreadStartParams | null;" in client_request
        assert 'method: "turn/start";' in client_request
        assert "params: TurnStartParams;" in client_request
        assert 'method: "thread/resume";' in client_request
        assert "params: ThreadResumeParams;" in client_request
        assert 'method: "thread/fork";' in client_request
        assert "params: ThreadForkParams;" in client_request
        assert 'method: "thread/loaded/list";' in client_request
        assert "params?: ThreadLoadedListParams | null;" in client_request
        assert 'method: "thread/unsubscribe";' in client_request
        assert "params: ThreadUnsubscribeParams;" in client_request
        assert 'method: "thread/archive";' in client_request
        assert "params: ThreadArchiveParams;" in client_request
        assert 'method: "thread/unarchive";' in client_request
        assert "params: ThreadUnarchiveParams;" in client_request
        assert 'method: "thread/compact/start";' in client_request
        assert "params: ThreadCompactStartParams;" in client_request
        assert 'method: "thread/shellCommand";' in client_request
        assert "params: ThreadShellCommandParams;" in client_request
        assert 'method: "thread/approveGuardianDeniedAction";' in client_request
        assert (
            "params: ThreadApproveGuardianDeniedActionParams;" in client_request
        )
        assert 'method: "thread/backgroundTerminals/clean";' in client_request
        assert "params: ThreadBackgroundTerminalsCleanParams;" in client_request
        assert 'method: "thread/increment_elicitation";' in client_request
        assert "params: ThreadIncrementElicitationParams;" in client_request
        assert 'method: "thread/decrement_elicitation";' in client_request
        assert "params: ThreadDecrementElicitationParams;" in client_request
        assert 'method: "thread/rollback";' in client_request
        assert "params: ThreadRollbackParams;" in client_request
        assert 'method: "thread/list";' in client_request
        assert "params: ThreadListParams;" in client_request
        assert 'method: "thread/inject_items";' in client_request
        assert "params: ThreadInjectItemsParams;" in client_request
        assert 'method: "thread/name/set";' in client_request
        assert "params: ThreadSetNameParams;" in client_request
        assert 'method: "thread/goal/set";' in client_request
        assert "params: ThreadGoalSetParams;" in client_request
        assert 'method: "thread/goal/get";' in client_request
        assert "params: ThreadGoalGetParams;" in client_request
        assert 'method: "thread/goal/clear";' in client_request
        assert "params: ThreadGoalClearParams;" in client_request
        assert 'method: "thread/memoryMode/set";' in client_request
        assert "params: ThreadMemoryModeSetParams;" in client_request
        assert 'method: "thread/metadata/update";' in client_request
        assert "params: ThreadMetadataUpdateParams;" in client_request
        assert 'method: "thread/read";' in client_request
        assert "params: ThreadReadParams;" in client_request
        assert 'method: "thread/turns/list";' in client_request
        assert "params: ThreadTurnsListParams;" in client_request
        assert 'method: "thread/realtime/listVoices";' in client_request
        assert "params: ThreadRealtimeListVoicesParams;" in client_request
        assert 'method: "thread/realtime/start";' in client_request
        assert "params: ThreadRealtimeStartParams;" in client_request
        assert 'method: "thread/realtime/stop";' in client_request
        assert "params: ThreadRealtimeStopParams;" in client_request
        assert 'method: "thread/realtime/appendText";' in client_request
        assert "params: ThreadRealtimeAppendTextParams;" in client_request
        assert 'method: "thread/realtime/appendAudio";' in client_request
        assert "params: ThreadRealtimeAppendAudioParams;" in client_request
        server_notification = (out_dir / "ServerNotification.ts").read_text(
            encoding="utf-8"
        )
        assert 'method: "thread/started";' in server_notification
        assert "params: ThreadStartedNotification;" in server_notification
        assert 'method: "turn/started";' in server_notification
        assert "params: TurnStartedNotification;" in server_notification
        assert 'method: "turn/completed";' in server_notification
        assert "params: TurnCompletedNotification;" in server_notification
        assert 'method: "item/started";' in server_notification
        assert "params: ItemStartedNotification;" in server_notification
        assert 'method: "item/completed";' in server_notification
        assert "params: ItemCompletedNotification;" in server_notification
        assert 'method: "item/agentMessage/delta";' in server_notification
        assert "params: AgentMessageDeltaNotification;" in server_notification
        client_response = (out_dir / "ClientResponse.ts").read_text(encoding="utf-8")
        assert 'method: "thread/start";' in client_response
        assert "result: ThreadStartResponse;" in client_response
        assert 'method: "turn/start";' in client_response
        assert "result: TurnStartResponse;" in client_response
        assert 'method: "thread/resume";' in client_response
        assert "result: ThreadResumeResponse;" in client_response
        assert 'method: "thread/fork";' in client_response
        assert "result: ThreadForkResponse;" in client_response
        assert 'method: "thread/archive";' in client_response
        assert "result: ThreadArchiveResponse;" in client_response
        assert 'method: "thread/unarchive";' in client_response
        assert "result: ThreadUnarchiveResponse;" in client_response
        assert 'method: "thread/compact/start";' in client_response
        assert "result: ThreadCompactStartResponse;" in client_response
        assert 'method: "thread/shellCommand";' in client_response
        assert "result: ThreadShellCommandResponse;" in client_response
        assert 'method: "thread/approveGuardianDeniedAction";' in client_response
        assert (
            "result: ThreadApproveGuardianDeniedActionResponse;" in client_response
        )
        assert 'method: "thread/backgroundTerminals/clean";' in client_response
        assert "result: ThreadBackgroundTerminalsCleanResponse;" in client_response
        assert 'method: "thread/increment_elicitation";' in client_response
        assert "result: ThreadIncrementElicitationResponse;" in client_response
        assert 'method: "thread/decrement_elicitation";' in client_response
        assert "result: ThreadDecrementElicitationResponse;" in client_response
        assert 'method: "thread/rollback";' in client_response
        assert "result: ThreadRollbackResponse;" in client_response
        assert 'method: "thread/list";' in client_response
        assert "result: ThreadListResponse;" in client_response
        assert 'method: "thread/inject_items";' in client_response
        assert "result: ThreadInjectItemsResponse;" in client_response
        assert 'method: "thread/name/set";' in client_response
        assert "result: ThreadSetNameResponse;" in client_response
        assert 'method: "thread/goal/set";' in client_response
        assert "result: ThreadGoalSetResponse;" in client_response
        assert 'method: "thread/goal/get";' in client_response
        assert "result: ThreadGoalGetResponse;" in client_response
        assert 'method: "thread/goal/clear";' in client_response
        assert "result: ThreadGoalClearResponse;" in client_response
        assert 'method: "thread/memoryMode/set";' in client_response
        assert "result: ThreadMemoryModeSetResponse;" in client_response
        assert 'method: "thread/metadata/update";' in client_response
        assert "result: ThreadMetadataUpdateResponse;" in client_response
        assert 'method: "thread/read";' in client_response
        assert "result: ThreadReadResponse;" in client_response
        assert 'method: "thread/turns/list";' in client_response
        assert "result: ThreadTurnsListResponse;" in client_response
        assert 'method: "thread/realtime/listVoices";' in client_response
        assert "result: ThreadRealtimeListVoicesResponse;" in client_response
        assert 'method: "thread/realtime/start";' in client_response
        assert "result: ThreadRealtimeStartResponse;" in client_response
        assert 'method: "thread/realtime/stop";' in client_response
        assert "result: ThreadRealtimeStopResponse;" in client_response
        assert 'method: "thread/realtime/appendText";' in client_response
        assert "result: ThreadRealtimeAppendTextResponse;" in client_response
        assert 'method: "thread/realtime/appendAudio";' in client_response
        assert "result: ThreadRealtimeAppendAudioResponse;" in client_response

        command_exec = (out_dir / "v2" / "CommandExecParams.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface CommandExecParams" in command_exec
        assert "command: string[]" in command_exec
        assert "sandboxPolicy?: SandboxPolicy | null;" in command_exec
        assert "permissionProfile?: PermissionProfile | null;" in command_exec
        permission_profile = (out_dir / "v2" / "PermissionProfile.ts").read_text(
            encoding="utf-8"
        )
        assert 'type: "managed"' in permission_profile
        assert 'type: "disabled"' in permission_profile
        assert 'type: "external"' in permission_profile
        assert "fileSystem: PermissionProfileFileSystemPermissions;" in permission_profile
        assert "network: PermissionProfileNetworkPermissions;" in permission_profile
        permission_profile_network = (
            out_dir / "v2" / "PermissionProfileNetworkPermissions.ts"
        ).read_text(encoding="utf-8")
        assert "enabled: boolean;" in permission_profile_network
        permission_profile_file_system = (
            out_dir / "v2" / "PermissionProfileFileSystemPermissions.ts"
        ).read_text(encoding="utf-8")
        assert "globScanMaxDepth?: number;" in permission_profile_file_system
        filesystem_entry = (out_dir / "v2" / "FileSystemSandboxEntry.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface FileSystemSandboxEntry" in filesystem_entry
        filesystem_path = (out_dir / "v2" / "FileSystemPath.ts").read_text(
            encoding="utf-8"
        )
        assert 'import type { AbsolutePathBuf } from "../AbsolutePathBuf";' in filesystem_path
        assert "path: AbsolutePathBuf" in filesystem_path
        filesystem_special_path = (
            out_dir / "v2" / "FileSystemSpecialPath.ts"
        ).read_text(encoding="utf-8")
        assert 'kind: "project_roots"; subpath: string | null' in filesystem_special_path
        sandbox_policy = (out_dir / "v2" / "SandboxPolicy.ts").read_text(encoding="utf-8")
        assert 'type: "workspaceWrite"' in sandbox_policy
        assert 'import type { AbsolutePathBuf } from "../AbsolutePathBuf";' in sandbox_policy
        assert "writableRoots: AbsolutePathBuf[]" in sandbox_policy
        assert "networkAccess: boolean;" in sandbox_policy
        assert "networkAccess: NetworkAccess" in sandbox_policy
        command_exec_delta = (
            out_dir / "v2" / "CommandExecOutputDeltaNotification.ts"
        ).read_text(encoding="utf-8")
        assert "export interface CommandExecOutputDeltaNotification" in command_exec_delta
        assert "deltaBase64: string;" in command_exec_delta
        assert (
            out_dir / "v2" / "CommandExecWriteResponse.ts"
        ).read_text(encoding="utf-8").startswith("// GENERATED CODE! DO NOT MODIFY BY HAND!")
        thread_loaded_list = (
            out_dir / "v2" / "ThreadLoadedListResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadLoadedListResponse" in thread_loaded_list
        assert "nextCursor: string | null;" in thread_loaded_list
        thread_start_params = (out_dir / "v2" / "ThreadStartParams.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface ThreadStartParams" in thread_start_params
        assert "model?: string | null;" in thread_start_params
        assert (
            'threadSource?: "user" | "subagent" | "memory_consolidation" | null;'
            in thread_start_params
        )
        thread_start_response = (out_dir / "v2" / "ThreadStartResponse.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface ThreadStartResponse" in thread_start_response
        assert "thread: unknown;" in thread_start_response
        assert "modelProvider: string;" in thread_start_response
        thread_started_notification = (
            out_dir / "v2" / "ThreadStartedNotification.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadStartedNotification" in thread_started_notification
        assert "thread: unknown;" in thread_started_notification
        turn_start_params = (out_dir / "v2" / "TurnStartParams.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface TurnStartParams" in turn_start_params
        assert "threadId: string;" in turn_start_params
        assert "input: unknown[];" in turn_start_params
        turn_start_response = (out_dir / "v2" / "TurnStartResponse.ts").read_text(
            encoding="utf-8"
        )
        assert "turn: unknown;" in turn_start_response
        turn_started_notification = (
            out_dir / "v2" / "TurnStartedNotification.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in turn_started_notification
        assert "turn: unknown;" in turn_started_notification
        turn_completed_notification = (
            out_dir / "v2" / "TurnCompletedNotification.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in turn_completed_notification
        assert "turn: unknown;" in turn_completed_notification
        item_started_notification = (
            out_dir / "v2" / "ItemStartedNotification.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ItemStartedNotification" in item_started_notification
        assert "item: unknown;" in item_started_notification
        assert "threadId: string;" in item_started_notification
        assert "turnId: string;" in item_started_notification
        assert "startedAtMs: number;" in item_started_notification
        item_completed_notification = (
            out_dir / "v2" / "ItemCompletedNotification.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ItemCompletedNotification" in item_completed_notification
        assert "item: unknown;" in item_completed_notification
        assert "threadId: string;" in item_completed_notification
        assert "turnId: string;" in item_completed_notification
        assert "completedAtMs: number;" in item_completed_notification
        agent_message_delta_notification = (
            out_dir / "v2" / "AgentMessageDeltaNotification.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface AgentMessageDeltaNotification"
            in agent_message_delta_notification
        )
        assert "threadId: string;" in agent_message_delta_notification
        assert "turnId: string;" in agent_message_delta_notification
        assert "itemId: string;" in agent_message_delta_notification
        assert "delta: string;" in agent_message_delta_notification
        thread_resume_params = (out_dir / "v2" / "ThreadResumeParams.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface ThreadResumeParams" in thread_resume_params
        assert "threadId: string;" in thread_resume_params
        assert "history?: unknown[] | null;" in thread_resume_params
        assert "path?: string | null;" in thread_resume_params
        assert "excludeTurns?: boolean;" in thread_resume_params
        thread_resume_response = (
            out_dir / "v2" / "ThreadResumeResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadResumeResponse" in thread_resume_response
        assert "thread: unknown;" in thread_resume_response
        thread_fork_params = (out_dir / "v2" / "ThreadForkParams.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface ThreadForkParams" in thread_fork_params
        assert "threadId: string;" in thread_fork_params
        assert "path?: string | null;" in thread_fork_params
        assert "ephemeral?: boolean;" in thread_fork_params
        assert "excludeTurns?: boolean;" in thread_fork_params
        thread_fork_response = (out_dir / "v2" / "ThreadForkResponse.ts").read_text(
            encoding="utf-8"
        )
        assert "export interface ThreadForkResponse" in thread_fork_response
        assert "thread: unknown;" in thread_fork_response
        thread_unsubscribe = (
            out_dir / "v2" / "ThreadUnsubscribeResponse.ts"
        ).read_text(encoding="utf-8")
        assert "status: ThreadUnsubscribeStatus;" in thread_unsubscribe
        thread_unsubscribe_status = (
            out_dir / "v2" / "ThreadUnsubscribeStatus.ts"
        ).read_text(encoding="utf-8")
        assert '"notLoaded" | "notSubscribed" | "unsubscribed"' in thread_unsubscribe_status
        thread_archive = (
            out_dir / "v2" / "ThreadArchiveParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_archive
        thread_archive_response = (
            out_dir / "v2" / "ThreadArchiveResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadArchiveResponse {}" in thread_archive_response
        thread_unarchive = (
            out_dir / "v2" / "ThreadUnarchiveParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_unarchive
        thread_unarchive_response = (
            out_dir / "v2" / "ThreadUnarchiveResponse.ts"
        ).read_text(encoding="utf-8")
        assert "thread: unknown;" in thread_unarchive_response
        thread_compact_start = (
            out_dir / "v2" / "ThreadCompactStartParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_compact_start
        thread_compact_start_response = (
            out_dir / "v2" / "ThreadCompactStartResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadCompactStartResponse {}" in thread_compact_start_response
        thread_shell_command = (
            out_dir / "v2" / "ThreadShellCommandParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_shell_command
        assert "command: string;" in thread_shell_command
        thread_shell_command_response = (
            out_dir / "v2" / "ThreadShellCommandResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadShellCommandResponse {}" in thread_shell_command_response
        thread_guardian_approval = (
            out_dir / "v2" / "ThreadApproveGuardianDeniedActionParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_guardian_approval
        assert "event: unknown;" in thread_guardian_approval
        assert "GuardianAssessmentEvent" in thread_guardian_approval
        thread_guardian_approval_response = (
            out_dir / "v2" / "ThreadApproveGuardianDeniedActionResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface ThreadApproveGuardianDeniedActionResponse {}"
            in thread_guardian_approval_response
        )
        thread_background_clean = (
            out_dir / "v2" / "ThreadBackgroundTerminalsCleanParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_background_clean
        thread_background_clean_response = (
            out_dir / "v2" / "ThreadBackgroundTerminalsCleanResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface ThreadBackgroundTerminalsCleanResponse {}"
            in thread_background_clean_response
        )
        thread_increment_elicitation = (
            out_dir / "v2" / "ThreadIncrementElicitationResponse.ts"
        ).read_text(encoding="utf-8")
        assert "count: number;" in thread_increment_elicitation
        assert "paused: boolean;" in thread_increment_elicitation
        thread_decrement_elicitation = (
            out_dir / "v2" / "ThreadDecrementElicitationResponse.ts"
        ).read_text(encoding="utf-8")
        assert "count: number;" in thread_decrement_elicitation
        assert "paused: boolean;" in thread_decrement_elicitation
        thread_rollback = (
            out_dir / "v2" / "ThreadRollbackParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_rollback
        assert "numTurns: number;" in thread_rollback
        thread_rollback_response = (
            out_dir / "v2" / "ThreadRollbackResponse.ts"
        ).read_text(encoding="utf-8")
        assert "thread: unknown;" in thread_rollback_response
        sort_direction = (out_dir / "v2" / "SortDirection.ts").read_text(
            encoding="utf-8"
        )
        assert 'export type SortDirection = "asc" | "desc";' in sort_direction
        thread_sort_key = (out_dir / "v2" / "ThreadSortKey.ts").read_text(
            encoding="utf-8"
        )
        assert 'export type ThreadSortKey = "created_at" | "updated_at";' in thread_sort_key
        thread_source_kind = (out_dir / "v2" / "ThreadSourceKind.ts").read_text(
            encoding="utf-8"
        )
        assert "subAgentThreadSpawn" in thread_source_kind
        thread_list = (out_dir / "v2" / "ThreadListParams.ts").read_text(
            encoding="utf-8"
        )
        assert 'import type { SortDirection } from "./SortDirection";' in thread_list
        assert 'import type { ThreadSortKey } from "./ThreadSortKey";' in thread_list
        assert 'import type { ThreadSourceKind } from "./ThreadSourceKind";' in thread_list
        assert "sortKey?: ThreadSortKey | null;" in thread_list
        assert "sortDirection?: SortDirection | null;" in thread_list
        assert "sourceKinds?: ThreadSourceKind[] | null;" in thread_list
        assert "useStateDbOnly?: boolean;" in thread_list
        thread_list_response = (
            out_dir / "v2" / "ThreadListResponse.ts"
        ).read_text(encoding="utf-8")
        assert "data: unknown[];" in thread_list_response
        assert "nextCursor: string | null;" in thread_list_response
        assert "backwardsCursor: string | null;" in thread_list_response
        thread_inject_items = (
            out_dir / "v2" / "ThreadInjectItemsParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_inject_items
        assert "items: unknown[];" in thread_inject_items
        thread_inject_items_response = (
            out_dir / "v2" / "ThreadInjectItemsResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadInjectItemsResponse {}" in thread_inject_items_response
        thread_set_name = (out_dir / "v2" / "ThreadSetNameParams.ts").read_text(
            encoding="utf-8"
        )
        assert "threadId: string;" in thread_set_name
        assert "name: string;" in thread_set_name
        thread_set_name_response = (
            out_dir / "v2" / "ThreadSetNameResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadSetNameResponse {}" in thread_set_name_response
        thread_goal_status = (
            out_dir / "v2" / "ThreadGoalStatus.ts"
        ).read_text(encoding="utf-8")
        assert (
            'export type ThreadGoalStatus = "active" | "paused" | "budgetLimited" | "complete";'
            in thread_goal_status
        )
        thread_goal = (out_dir / "v2" / "ThreadGoal.ts").read_text(
            encoding="utf-8"
        )
        assert 'import type { ThreadGoalStatus } from "./ThreadGoalStatus";' in thread_goal
        assert "tokenBudget: number | null;" in thread_goal
        assert "tokensUsed: number;" in thread_goal
        thread_goal_set = (
            out_dir / "v2" / "ThreadGoalSetParams.ts"
        ).read_text(encoding="utf-8")
        assert "objective?: string | null;" in thread_goal_set
        assert "status?: ThreadGoalStatus | null;" in thread_goal_set
        assert "tokenBudget?: number | null;" in thread_goal_set
        thread_goal_set_response = (
            out_dir / "v2" / "ThreadGoalSetResponse.ts"
        ).read_text(encoding="utf-8")
        assert "goal: ThreadGoal;" in thread_goal_set_response
        thread_goal_get = (
            out_dir / "v2" / "ThreadGoalGetParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_goal_get
        thread_goal_get_response = (
            out_dir / "v2" / "ThreadGoalGetResponse.ts"
        ).read_text(encoding="utf-8")
        assert "goal: ThreadGoal | null;" in thread_goal_get_response
        thread_goal_clear = (
            out_dir / "v2" / "ThreadGoalClearParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_goal_clear
        thread_goal_clear_response = (
            out_dir / "v2" / "ThreadGoalClearResponse.ts"
        ).read_text(encoding="utf-8")
        assert "cleared: boolean;" in thread_goal_clear_response
        thread_memory_mode = (out_dir / "ThreadMemoryMode.ts").read_text(
            encoding="utf-8"
        )
        assert 'export type ThreadMemoryMode = "enabled" | "disabled";' in thread_memory_mode
        thread_memory_mode_set = (
            out_dir / "v2" / "ThreadMemoryModeSetParams.ts"
        ).read_text(encoding="utf-8")
        assert (
            'import type { ThreadMemoryMode } from "../ThreadMemoryMode";'
            in thread_memory_mode_set
        )
        assert "threadId: string;" in thread_memory_mode_set
        assert "mode: ThreadMemoryMode;" in thread_memory_mode_set
        thread_memory_mode_set_response = (
            out_dir / "v2" / "ThreadMemoryModeSetResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface ThreadMemoryModeSetResponse {}"
            in thread_memory_mode_set_response
        )
        thread_metadata_git_info = (
            out_dir / "v2" / "ThreadMetadataGitInfoUpdateParams.ts"
        ).read_text(encoding="utf-8")
        assert "sha?: string | null;" in thread_metadata_git_info
        assert "branch?: string | null;" in thread_metadata_git_info
        assert "originUrl?: string | null;" in thread_metadata_git_info
        thread_metadata_update = (
            out_dir / "v2" / "ThreadMetadataUpdateParams.ts"
        ).read_text(encoding="utf-8")
        assert (
            'import type { ThreadMetadataGitInfoUpdateParams } from "./ThreadMetadataGitInfoUpdateParams";'
            in thread_metadata_update
        )
        assert "threadId: string;" in thread_metadata_update
        assert (
            "gitInfo?: ThreadMetadataGitInfoUpdateParams | null;"
            in thread_metadata_update
        )
        thread_metadata_update_response = (
            out_dir / "v2" / "ThreadMetadataUpdateResponse.ts"
        ).read_text(encoding="utf-8")
        assert "thread: unknown;" in thread_metadata_update_response
        thread_read = (out_dir / "v2" / "ThreadReadParams.ts").read_text(
            encoding="utf-8"
        )
        assert "threadId: string;" in thread_read
        assert "includeTurns: boolean;" in thread_read
        thread_read_response = (out_dir / "v2" / "ThreadReadResponse.ts").read_text(
            encoding="utf-8"
        )
        assert "thread: unknown;" in thread_read_response
        thread_turns_list = (
            out_dir / "v2" / "ThreadTurnsListParams.ts"
        ).read_text(encoding="utf-8")
        assert 'import type { SortDirection } from "./SortDirection";' in thread_turns_list
        assert "threadId: string;" in thread_turns_list
        assert "cursor?: string | null;" in thread_turns_list
        assert "limit?: number | null;" in thread_turns_list
        assert "sortDirection?: SortDirection | null;" in thread_turns_list
        thread_turns_list_response = (
            out_dir / "v2" / "ThreadTurnsListResponse.ts"
        ).read_text(encoding="utf-8")
        assert "data: unknown[];" in thread_turns_list_response
        assert "nextCursor: string | null;" in thread_turns_list_response
        assert "backwardsCursor: string | null;" in thread_turns_list_response
        realtime_voice = (out_dir / "RealtimeVoice.ts").read_text(encoding="utf-8")
        assert 'export type RealtimeVoice = "alloy"' in realtime_voice
        assert '"verse"' in realtime_voice
        realtime_output_modality = (
            out_dir / "RealtimeOutputModality.ts"
        ).read_text(encoding="utf-8")
        assert 'export type RealtimeOutputModality = "text" | "audio";' in realtime_output_modality
        realtime_voices_list = (out_dir / "RealtimeVoicesList.ts").read_text(
            encoding="utf-8"
        )
        assert 'import type { RealtimeVoice } from "./RealtimeVoice";' in realtime_voices_list
        assert "v1: RealtimeVoice[];" in realtime_voices_list
        assert "defaultV2: RealtimeVoice;" in realtime_voices_list
        thread_realtime_list_voices = (
            out_dir / "v2" / "ThreadRealtimeListVoicesParams.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadRealtimeListVoicesParams {}" in thread_realtime_list_voices
        thread_realtime_list_voices_response = (
            out_dir / "v2" / "ThreadRealtimeListVoicesResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            'import type { RealtimeVoicesList } from "../RealtimeVoicesList";'
            in thread_realtime_list_voices_response
        )
        assert "voices: RealtimeVoicesList;" in thread_realtime_list_voices_response
        thread_realtime_start_transport = (
            out_dir / "v2" / "ThreadRealtimeStartTransport.ts"
        ).read_text(encoding="utf-8")
        assert 'type: "websocket"' in thread_realtime_start_transport
        assert 'type: "webrtc";' in thread_realtime_start_transport
        assert "sdp: string;" in thread_realtime_start_transport
        thread_realtime_start = (
            out_dir / "v2" / "ThreadRealtimeStartParams.ts"
        ).read_text(encoding="utf-8")
        assert 'import type { RealtimeOutputModality } from "../RealtimeOutputModality";' in thread_realtime_start
        assert "outputModality: RealtimeOutputModality;" in thread_realtime_start
        assert "transport?: ThreadRealtimeStartTransport | null;" in thread_realtime_start
        thread_realtime_start_response = (
            out_dir / "v2" / "ThreadRealtimeStartResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadRealtimeStartResponse {}" in thread_realtime_start_response
        thread_realtime_stop = (
            out_dir / "v2" / "ThreadRealtimeStopParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_realtime_stop
        thread_realtime_stop_response = (
            out_dir / "v2" / "ThreadRealtimeStopResponse.ts"
        ).read_text(encoding="utf-8")
        assert "export interface ThreadRealtimeStopResponse {}" in thread_realtime_stop_response
        thread_realtime_append_text = (
            out_dir / "v2" / "ThreadRealtimeAppendTextParams.ts"
        ).read_text(encoding="utf-8")
        assert "threadId: string;" in thread_realtime_append_text
        assert "text: string;" in thread_realtime_append_text
        thread_realtime_append_text_response = (
            out_dir / "v2" / "ThreadRealtimeAppendTextResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface ThreadRealtimeAppendTextResponse {}"
            in thread_realtime_append_text_response
        )
        thread_realtime_audio_chunk = (
            out_dir / "v2" / "ThreadRealtimeAudioChunk.ts"
        ).read_text(encoding="utf-8")
        assert "data: string;" in thread_realtime_audio_chunk
        assert "sampleRate: number;" in thread_realtime_audio_chunk
        assert "samplesPerChannel: number | null;" in thread_realtime_audio_chunk
        assert "itemId: string | null;" in thread_realtime_audio_chunk
        thread_realtime_append_audio = (
            out_dir / "v2" / "ThreadRealtimeAppendAudioParams.ts"
        ).read_text(encoding="utf-8")
        assert 'import type { ThreadRealtimeAudioChunk } from "./ThreadRealtimeAudioChunk";' in thread_realtime_append_audio
        assert "audio: ThreadRealtimeAudioChunk;" in thread_realtime_append_audio
        thread_realtime_append_audio_response = (
            out_dir / "v2" / "ThreadRealtimeAppendAudioResponse.ts"
        ).read_text(encoding="utf-8")
        assert (
            "export interface ThreadRealtimeAppendAudioResponse {}"
            in thread_realtime_append_audio_response
        )

        index = (out_dir / "index.ts").read_text(encoding="utf-8")
        assert 'export type { AbsolutePathBuf } from "./AbsolutePathBuf";' in index
        assert 'export type { ClientRequest } from "./ClientRequest";' in index
        assert 'export type { RealtimeOutputModality } from "./RealtimeOutputModality";' in index
        assert 'export type { RealtimeVoice } from "./RealtimeVoice";' in index
        assert 'export type { RealtimeVoicesList } from "./RealtimeVoicesList";' in index
        assert 'export type { ServerNotification } from "./ServerNotification";' in index
        assert 'export type { ThreadMemoryMode } from "./ThreadMemoryMode";' in index
        assert 'export * as v2 from "./v2";' in index
        v2_index = (out_dir / "v2" / "index.ts").read_text(encoding="utf-8")
        assert v2_index.startswith("// GENERATED CODE! DO NOT MODIFY BY HAND!")
        assert 'export type { CommandExecParams } from "./CommandExecParams";' in v2_index
        assert 'export type { PermissionProfile } from "./PermissionProfile";' in v2_index
        assert (
            'export type { ThreadStartedNotification } from "./ThreadStartedNotification";'
            in v2_index
        )
        assert 'export type { ThreadStartParams } from "./ThreadStartParams";' in v2_index
        assert 'export type { ThreadStartResponse } from "./ThreadStartResponse";' in v2_index
        assert 'export type { TurnStartParams } from "./TurnStartParams";' in v2_index
        assert 'export type { TurnStartResponse } from "./TurnStartResponse";' in v2_index
        assert (
            'export type { TurnStartedNotification } from "./TurnStartedNotification";'
            in v2_index
        )
        assert (
            'export type { TurnCompletedNotification } from "./TurnCompletedNotification";'
            in v2_index
        )
        assert (
            'export type { ItemStartedNotification } from "./ItemStartedNotification";'
            in v2_index
        )
        assert (
            'export type { ItemCompletedNotification } from "./ItemCompletedNotification";'
            in v2_index
        )
        assert (
            'export type { AgentMessageDeltaNotification } from "./AgentMessageDeltaNotification";'
            in v2_index
        )
        assert 'export type { ThreadResumeParams } from "./ThreadResumeParams";' in v2_index
        assert 'export type { ThreadResumeResponse } from "./ThreadResumeResponse";' in v2_index
        assert 'export type { ThreadForkParams } from "./ThreadForkParams";' in v2_index
        assert 'export type { ThreadForkResponse } from "./ThreadForkResponse";' in v2_index
        assert 'export type { ThreadLoadedListResponse } from "./ThreadLoadedListResponse";' in v2_index
        assert 'export type { ThreadUnsubscribeResponse } from "./ThreadUnsubscribeResponse";' in v2_index
        assert 'export type { ThreadArchiveParams } from "./ThreadArchiveParams";' in v2_index
        assert 'export type { ThreadArchiveResponse } from "./ThreadArchiveResponse";' in v2_index
        assert 'export type { ThreadUnarchiveParams } from "./ThreadUnarchiveParams";' in v2_index
        assert 'export type { ThreadUnarchiveResponse } from "./ThreadUnarchiveResponse";' in v2_index
        assert 'export type { ThreadCompactStartResponse } from "./ThreadCompactStartResponse";' in v2_index
        assert 'export type { ThreadShellCommandResponse } from "./ThreadShellCommandResponse";' in v2_index
        assert (
            'export type { ThreadApproveGuardianDeniedActionParams } from "./ThreadApproveGuardianDeniedActionParams";'
            in v2_index
        )
        assert (
            'export type { ThreadApproveGuardianDeniedActionResponse } from "./ThreadApproveGuardianDeniedActionResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadBackgroundTerminalsCleanResponse } from "./ThreadBackgroundTerminalsCleanResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadIncrementElicitationResponse } from "./ThreadIncrementElicitationResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadDecrementElicitationResponse } from "./ThreadDecrementElicitationResponse";'
            in v2_index
        )
        assert 'export type { ThreadInjectItemsParams } from "./ThreadInjectItemsParams";' in v2_index
        assert 'export type { ThreadRollbackResponse } from "./ThreadRollbackResponse";' in v2_index
        assert 'export type { SortDirection } from "./SortDirection";' in v2_index
        assert 'export type { ThreadSortKey } from "./ThreadSortKey";' in v2_index
        assert 'export type { ThreadSourceKind } from "./ThreadSourceKind";' in v2_index
        assert 'export type { ThreadListParams } from "./ThreadListParams";' in v2_index
        assert 'export type { ThreadListResponse } from "./ThreadListResponse";' in v2_index
        assert 'export type { ThreadInjectItemsResponse } from "./ThreadInjectItemsResponse";' in v2_index
        assert 'export type { ThreadSetNameParams } from "./ThreadSetNameParams";' in v2_index
        assert 'export type { ThreadSetNameResponse } from "./ThreadSetNameResponse";' in v2_index
        assert 'export type { ThreadGoal } from "./ThreadGoal";' in v2_index
        assert 'export type { ThreadGoalStatus } from "./ThreadGoalStatus";' in v2_index
        assert 'export type { ThreadGoalSetParams } from "./ThreadGoalSetParams";' in v2_index
        assert 'export type { ThreadGoalSetResponse } from "./ThreadGoalSetResponse";' in v2_index
        assert 'export type { ThreadGoalGetParams } from "./ThreadGoalGetParams";' in v2_index
        assert 'export type { ThreadGoalGetResponse } from "./ThreadGoalGetResponse";' in v2_index
        assert 'export type { ThreadGoalClearParams } from "./ThreadGoalClearParams";' in v2_index
        assert 'export type { ThreadGoalClearResponse } from "./ThreadGoalClearResponse";' in v2_index
        assert (
            'export type { ThreadMemoryModeSetParams } from "./ThreadMemoryModeSetParams";'
            in v2_index
        )
        assert (
            'export type { ThreadMemoryModeSetResponse } from "./ThreadMemoryModeSetResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadMetadataGitInfoUpdateParams } from "./ThreadMetadataGitInfoUpdateParams";'
            in v2_index
        )
        assert (
            'export type { ThreadMetadataUpdateParams } from "./ThreadMetadataUpdateParams";'
            in v2_index
        )
        assert (
            'export type { ThreadMetadataUpdateResponse } from "./ThreadMetadataUpdateResponse";'
            in v2_index
        )
        assert 'export type { ThreadReadParams } from "./ThreadReadParams";' in v2_index
        assert 'export type { ThreadReadResponse } from "./ThreadReadResponse";' in v2_index
        assert 'export type { ThreadTurnsListParams } from "./ThreadTurnsListParams";' in v2_index
        assert 'export type { ThreadTurnsListResponse } from "./ThreadTurnsListResponse";' in v2_index
        assert (
            'export type { ThreadRealtimeListVoicesParams } from "./ThreadRealtimeListVoicesParams";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeListVoicesResponse } from "./ThreadRealtimeListVoicesResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeStartParams } from "./ThreadRealtimeStartParams";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeStartResponse } from "./ThreadRealtimeStartResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeStartTransport } from "./ThreadRealtimeStartTransport";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeStopParams } from "./ThreadRealtimeStopParams";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeStopResponse } from "./ThreadRealtimeStopResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeAppendTextParams } from "./ThreadRealtimeAppendTextParams";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeAppendTextResponse } from "./ThreadRealtimeAppendTextResponse";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeAudioChunk } from "./ThreadRealtimeAudioChunk";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeAppendAudioParams } from "./ThreadRealtimeAppendAudioParams";'
            in v2_index
        )
        assert (
            'export type { ThreadRealtimeAppendAudioResponse } from "./ThreadRealtimeAppendAudioResponse";'
            in v2_index
        )
        assert (
            'export type { CommandExecOutputDeltaNotification } from "./CommandExecOutputDeltaNotification";'
            in v2_index
        )

        missing_out = subprocess.run(
            [str(binary), "app-server", "generate-ts"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
        assert missing_out.returncode != 0
        assert "MissingAppServerGenerateTsOutDir" in missing_out.stderr
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


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

    remote_proxy = subprocess.run(
        [
            str(binary),
            "--remote-auth-token-env",
            "CODEX_REMOTE_AUTH_TOKEN",
            "app-server",
            "proxy",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert remote_proxy.returncode != 0
    assert "codex-zig app-server proxy" in remote_proxy.stderr
    assert "RemoteModeUnsupportedForSubcommand" in remote_proxy.stderr

    remote_internal_schema = subprocess.run(
        [
            str(binary),
            "--remote-auth-token-env",
            "CODEX_REMOTE_AUTH_TOKEN",
            "app-server",
            "generate-internal-json-schema",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    assert remote_internal_schema.returncode != 0
    assert "codex-zig app-server generate-internal-json-schema" in remote_internal_schema.stderr
    assert "RemoteModeUnsupportedForSubcommand" in remote_internal_schema.stderr


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_stdio_smoke(binary)
    print("app-server-stdio-e2e: ok")
    run_thread_started_opt_out_smoke(binary)
    print("app-server-thread-started-opt-out-e2e: ok")
    run_turn_start_rpc_smoke(binary)
    print("app-server-turn-start-rpc-e2e: ok")
    run_thread_resume_rpc_smoke(binary)
    print("app-server-thread-resume-rpc-e2e: ok")
    run_goal_feature_gate_smoke(binary)
    print("app-server-goal-feature-gate-e2e: ok")
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
    run_command_exec_rpc_smoke(binary)
    print("app-server-command-exec-rpc-e2e: ok")
    run_model_rpc_smoke(binary)
    print("app-server-model-rpc-e2e: ok")
    run_collaboration_mode_rpc_smoke(binary)
    print("app-server-collaboration-mode-rpc-e2e: ok")
    run_config_read_rpc_smoke(binary)
    run_config_read_empty_layers_rpc_smoke(binary)
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
    run_typescript_generation_smoke(binary)
    print("app-server-typescript-generation-e2e: ok")
    run_json_schema_smoke(binary)
    print("app-server-json-schema-e2e: ok")
    run_internal_json_schema_smoke(binary)
    print("app-server-internal-json-schema-e2e: ok")
    run_flag_compat_smoke(binary)
    print("app-server-flag-compat-e2e: ok")


if __name__ == "__main__":
    main()
