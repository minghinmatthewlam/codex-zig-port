#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class ExecResponsesHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.request_bodies.append(json.loads(body))
        payload = (
            b'data: {"type":"response.output_text.delta","delta":"stored reply"}\n\n'
            b"data: [DONE]\n\n"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        return


class ExecResponsesServer(ThreadingHTTPServer):
    request_bodies: list[dict]


def start_exec_responses_server() -> tuple[ExecResponsesServer, str]:
    server = ExecResponsesServer(("127.0.0.1", 0), ExecResponsesHandler)
    server.request_bodies = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


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


def clean_git_env() -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


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

        contents = (codex_home / "config.toml").read_text(encoding="utf-8")
        assert "[profiles.\"work\".features]" in contents
        assert "goals = true" in contents
        assert "shell_tool = false" in contents

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

        profile_unsupported = subprocess.run(
            [
                str(binary.resolve()),
                "sandbox",
                "macos",
                "--permissions-profile",
                ":workspace",
                "--cd",
                str(temp_root),
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
        shutil.rmtree(temp_root, ignore_errors=True)


def main() -> None:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/codex-zig")
    run_features_profile_smoke(binary)
    run_execpolicy_smoke(binary)
    run_exec_review_smoke(binary)
    run_review_stdin_smoke(binary)
    run_exec_equals_options_smoke(binary)
    run_exec_resume_option_smoke(binary)
    run_exec_stdin_smoke(binary)
    run_exec_git_repo_check_smoke(binary)
    run_yolo_approval_conflict_smoke(binary)
    run_full_auto_compat_smoke(binary)
    run_removed_top_level_command_smoke(binary)
    run_sandbox_permission_profile_smoke(binary)
    print("cli-features-profile-e2e: ok")
    print("cli-execpolicy-e2e: ok")
    print("cli-exec-review-e2e: ok")
    print("cli-review-stdin-e2e: ok")
    print("cli-exec-options-e2e: ok")
    print("cli-exec-resume-options-e2e: ok")
    print("cli-exec-stdin-e2e: ok")
    print("cli-exec-git-check-e2e: ok")
    print("cli-yolo-approval-conflict-e2e: ok")
    print("cli-full-auto-compat-e2e: ok")
    print("cli-removed-top-level-e2e: ok")
    print("cli-sandbox-permission-profile-e2e: ok")


if __name__ == "__main__":
    main()
