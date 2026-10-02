#!/usr/bin/env python3
"""Built hook regression: rejected/lost structural asks never enable legacy bodies."""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from test_feed_list_watch import require_guest

SENTINEL = "SYNTHETIC-FAILED-ASK-264"
WORKSPACE = "11111111-1111-4111-8111-111111111111"
TAB = "22222222-2222-4222-8222-222222222222"


def main():
    _, cli = require_guest()
    calls = []
    mode = "unsupported_version"

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                command = line.decode().strip()
                if command.startswith("auth "):
                    response = "OK"
                elif command.startswith("{"):
                    request = json.loads(command)
                    calls.append(request)
                    if request["method"] == "system.capabilities":
                        response = {"ok": True, "result": {"methods": ["tab.list", "agent.event.append"]}}
                    elif request["method"] == "agent.event.append":
                        if mode == "lost":
                            return
                        response = {"ok": False, "error": {"code": mode, "message": mode}}
                    else:
                        response = {"ok": True, "result": {}}
                    response = json.dumps(response)
                else:
                    calls.append(command)
                    response = "OK"
                try:
                    self.wfile.write((response + "\n").encode())
                    self.wfile.flush()
                except BrokenPipeError:
                    return

    with tempfile.TemporaryDirectory(prefix="c11-feed-hook-", dir="/tmp") as temporary:
        root = Path(temporary)
        address = str(root / "peer.sock")
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for mode in ("unsupported_version", "invalid_event", "idempotency_conflict", "expired", "lost", "method_not_found", "no-draft"):
                calls.clear()
                isolated = root / mode
                isolated.mkdir()
                # A regular file blocks the spool directory, forcing .lost after
                # the peer closes the append connection without acknowledging it.
                if mode == "lost":
                    (isolated / "Library").write_text("blocked synthetic spool")
                state = isolated / "sessions.json"
                env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
                env.update(HOME=str(isolated), CFFIXED_USER_HOME=str(isolated),
                           CMUX_BUNDLE_ID="com.stage11.c11.debug.feed-privacy",
                           CMUX_CLAUDE_HOOK_STATE_PATH=str(state),
                           CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1")
                payload = {"session_id": "synthetic-session", "tool_use_id": "synthetic-request",
                           "permission_mode": "bypassPermissions", "tool_name": "AskUserQuestion",
                           "tool_input": {"questions": [{"question": SENTINEL, "options": [{"label": "Synthetic option"}]}]}}
                if mode == "no-draft":
                    # The native request identity cannot form a bounded draft.
                    payload["tool_use_id"] = "x" * 129
                subprocess.run([cli, "--socket", address, "claude-hook", "pre-tool-use",
                                "--workspace", WORKSPACE, "--tab", TAB], input=json.dumps(payload),
                               env=env, capture_output=True, text=True, timeout=10)
                legacy = [c for c in calls if isinstance(c, str)]
                if mode != "no-draft":
                    assert any(isinstance(c, dict) and c["method"] == "agent.event.append" for c in calls), mode
                else:
                    assert not any(isinstance(c, dict) and c["method"] == "agent.event.append" for c in calls), calls
                if mode in ("method_not_found", "no-draft"):
                    assert any(c.startswith("notify_target ") and SENTINEL in c for c in legacy), calls
                    if mode == "method_not_found":
                        assert SENTINEL in state.read_text(), "confirmed legacy route did not persist its body"
                else:
                    assert SENTINEL not in json.dumps(calls), mode
                    assert not any(c.startswith(("notify_target ", "report_agent_activity ")) for c in legacy), mode
                    for saved in isolated.rglob("*"):
                        if saved.is_file():
                            assert SENTINEL.encode() not in saved.read_bytes(), (mode, saved)
                print(f"PASS hook privacy delivery={mode}")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)


if __name__ == "__main__":
    main()
