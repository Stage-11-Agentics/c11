#!/usr/bin/env python3
"""PermissionRequest stdout and unreachable-socket spool for the built CLI.

Run on the build host with C11_CLI_BIN pointing at this branch's built CLI.
"""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

WORKSPACE = "11111111-1111-4111-8111-111111111111"
TAB = "22222222-2222-4222-8222-222222222222"
BUNDLE = "com.stage11.c11.permission-test"


def env_for(root: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
    env.update(
        HOME=str(root),
        CFFIXED_USER_HOME=str(root),
        CMUX_BUNDLE_ID=BUNDLE,
        CMUX_CLI_SENTRY_DISABLED="1",
        CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
        CMUX_CLAUDE_HOOK_STATE_PATH=str(root / "state.json"),
    )
    return env


def run_hook(cli: str, root: Path, socket_path: str, payload: dict) -> subprocess.CompletedProcess:
    started = time.monotonic()
    result = subprocess.run(
        [cli, "--socket", socket_path, "claude-hook", "permission-request",
         "--workspace", WORKSPACE, "--tab", TAB],
        env=env_for(root),
        text=True,
        capture_output=True,
        input=json.dumps(payload),
        timeout=2,
    )
    result.elapsed = time.monotonic() - started  # type: ignore[attr-defined]
    return result


def assert_empty_object(stdout: str) -> None:
    assert stdout.strip() == "{}", stdout
    parsed = json.loads(stdout)
    assert parsed == {}
    for forbidden in ("decision", "behavior", "allow", "deny"):
        assert forbidden not in stdout, stdout


def spool_files(root: Path) -> list[Path]:
    spool = root / "Library" / "Application Support" / "c11" / "journal" / BUNDLE / "spool"
    if not spool.is_dir():
        return []
    return [path for path in spool.iterdir() if path.name.endswith(".ready")]


def main() -> None:
    cli = os.environ["C11_CLI_BIN"]
    payload = {
        "session_id": "sess-1",
        "tool_name": "Bash",
        "tool_use_id": "tool-1",
        "tool_input": {"command": "SENTINEL-INPUT"},
        "tool_response": "SENTINEL-RESPONSE",
    }
    with tempfile.TemporaryDirectory(prefix="c11-permission-", dir="/tmp") as temporary:
        root = Path(temporary)
        missing = str(root / "missing.sock")
        result = run_hook(cli, root, missing, payload)
        assert result.returncode == 0, result.stderr
        assert result.elapsed < 0.75, result.elapsed
        assert_empty_object(result.stdout)
        files = spool_files(root)
        assert len(files) == 1, files
        body = files[0].read_text(encoding="utf-8")
        assert "SENTINEL-INPUT" not in body and "SENTINEL-RESPONSE" not in body, body
        for forbidden in ("decision", "behavior", "allow", "deny"):
            assert forbidden not in body, body
        draft = json.loads(body)
        assert draft["kind"] == "agent.approval.requested"
        assert draft["native_event"] == "PermissionRequest"
        assert draft["tool_class"] == "other"
        assert draft["request_id"] == "tool-1"
        assert draft["reason_code"] is None
        assert draft["is_child"] is False
        assert set(draft) <= {
            "schema_version", "event_id", "kind", "emitted_at_ms", "occurred_at_ms", "time_quality",
            "tab_id", "workspace_id", "session_id", "agent_kind", "is_child", "parent_session_id",
            "source", "adapter", "adapter_version", "native_event", "turn_id", "request_id",
            "tool_class", "reason_code", "signal", "resolution",
        }

        ask_root = root / "ask"
        ask_root.mkdir()
        ask = run_hook(cli, ask_root, str(ask_root / "missing.sock"), {**payload, "tool_name": "AskUserQuestion"})
        assert ask.returncode == 0, ask.stderr
        assert ask.elapsed < 0.75, ask.elapsed
        assert_empty_object(ask.stdout)
        assert spool_files(ask_root) == []

        calls = []

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                for line in self.rfile:
                    command = line.decode().strip()
                    if command.startswith("auth "):
                        self.wfile.write(b"OK\n")
                        self.wfile.flush()
                        continue
                    if command.startswith("{"):
                        request = json.loads(command)
                        if request["method"] == "system.capabilities":
                            response = {"id": request["id"], "ok": True, "result": {
                                "methods": ["tab.list", "agent.event.append"]}}
                            self.wfile.write((json.dumps(response) + "\n").encode())
                            self.wfile.flush()
                            continue
                        calls.append(request)
                        response = {"id": request["id"], "ok": True, "result": {
                            "event_id": request["params"]["event"]["event_id"], "sequence": len(calls),
                            "committed_at_ms": 1, "replayed": False, "projection_effect": "applied"}}
                        self.wfile.write((json.dumps(response) + "\n").encode())
                    else:
                        calls.append(command)
                        self.wfile.write(b"OK\n")
                    self.wfile.flush()

        live_root = root / "live"
        live_root.mkdir()
        address = str(live_root / "peer.sock")
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            calls.clear()
            live = run_hook(cli, live_root, address, payload)
            assert live.returncode == 0, live.stderr
            assert_empty_object(live.stdout)
            appends = [c for c in calls if isinstance(c, dict)]
            assert len(appends) == 1, calls
            assert appends[0]["params"]["event"]["kind"] == "agent.approval.requested"
            legacy = [c for c in calls if isinstance(c, str)]
            assert not any(c.startswith(("clear_notifications ", "set_status ", "report_agent_activity ")) for c in legacy), legacy
            calls.clear()
            skipped = run_hook(cli, live_root, address, {**payload, "tool_name": "ExitPlanMode"})
            assert skipped.returncode == 0, skipped.stderr
            assert_empty_object(skipped.stdout)
            assert [c for c in calls if isinstance(c, dict)] == []
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)
    print("PASS permission-request stdout, spool, and non-answering append")


if __name__ == "__main__":
    main()
