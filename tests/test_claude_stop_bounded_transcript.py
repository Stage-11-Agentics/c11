#!/usr/bin/env python3
"""B028: exercise the built CLI Stop route with an isolated socket and state.

Run on Atlas with C11_CLI_BIN naming the CLI built from this checkout. No app,
real conversation, or operator socket is used. Swift logic tests measure the
read cap; this fixture proves that the executable uses that reader and fallback.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

from fake_server_env import fake_server_env

WORKSPACE = "11111111-1111-4111-8111-111111111111"
TAB = "22222222-2222-4222-8222-222222222222"
SESSION = "synthetic-stop-session"


def record(text: str, role: str = "assistant") -> bytes:
    return (json.dumps({"message": {"role": role, "content": text}}) + "\n").encode()


def main() -> None:
    cli = os.environ.get("C11_CLI_BIN")
    assert cli and Path(cli).is_file() and os.access(cli, os.X_OK), "Set C11_CLI_BIN to the current built CLI"
    cli = str(Path(cli).resolve())
    commands: list[str] = []

    class Handler(socketserver.StreamRequestHandler):
        def handle(self) -> None:
            for raw in self.rfile:
                command = raw.decode().strip()
                # A machine may have a saved local socket password. Accept the
                # normal handshake without retaining credential bytes in evidence.
                if command.startswith("auth "):
                    self.wfile.write(b"OK\n")
                    self.wfile.flush()
                    continue
                commands.append(command)
                if command.startswith(("report_agent_activity ", "notify_target ", "set_status ")):
                    self.wfile.write(b"OK\n")
                else:
                    self.wfile.write(b"ERROR: unexpected fixture command\n")
                self.wfile.flush()

    with tempfile.TemporaryDirectory(prefix="c11-stop-", dir="/tmp") as temporary:
        root = Path(temporary)
        socket_path = str(root / "app.sock")
        state_path = root / "sessions.json"
        transcript = root / "synthetic.jsonl"
        # Remove inherited c11 options as well as all live identity/socket refs.
        base_env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("C11_", "CMUX_"))}
        env = fake_server_env(socket_path, base=base_env)
        env.update({
            "CMUX_CLAUDE_HOOK_STATE_PATH": str(state_path),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        })
        server = socketserver.ThreadingUnixStreamServer(socket_path, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            def stop(expected_subtitle: str, expected_body: str) -> None:
                now = time.time()
                state_path.write_text(json.dumps({"version": 1, "sessions": {SESSION: {
                    "sessionId": SESSION, "workspaceId": WORKSPACE, "surfaceId": TAB,
                    "cwd": "/tmp/synthetic-project", "lastSubtitle": "saved subtitle",
                    "lastBody": "saved body", "startedAt": now, "updatedAt": now,
                }}}))
                before = len(commands)
                result = subprocess.run(
                    [cli, "--socket", socket_path, "claude-hook", "stop",
                     "--workspace", WORKSPACE, "--tab", TAB],
                    input=json.dumps({"session_id": SESSION, "transcript_path": str(transcript)}),
                    cwd=root, env=env, text=True, capture_output=True, timeout=10,
                )
                assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
                assert result.stdout.strip() == "OK", result.stdout
                expected = f"notify_target {WORKSPACE} {TAB} Claude Code|{expected_subtitle}|{expected_body}"
                notifications = [command for command in commands[before:] if command.startswith("notify_target ")]
                assert notifications == [expected], notifications
                saved = json.loads(state_path.read_text())["sessions"][SESSION]
                assert saved["lastSubtitle"] == expected_subtitle, saved
                assert saved["lastBody"] == expected_body, saved

            filler = record("x" * 1024, role="user") * 4096
            transcript.write_bytes(filler + record(" Finished\n\t synthetic   fixture "))
            stop("Completed in synthetic-project", "Finished synthetic fixture")
            print("PASS: multi-megabyte transcript preserves Stop notification and saved summary")

            transcript.write_bytes(record("outside the tail") + filler)
            fallback = "Claude session completed in synthetic-project. Last: saved body"
            stop("Completed", fallback)
            print("PASS: assistant older than the cap uses the session-record fallback")

            transcript.write_bytes(filler + record("z" * 200_000))
            stop("Completed in synthetic-project", "z" * 119 + "…")
            print("PASS: long assistant inside the cap preserves 120-character truncation")

            transcript.write_bytes(record("z" * 300_000))
            stop("Completed", fallback)
            print("PASS: oversized assistant uses the existing fallback")

            transcript.unlink()
            stop("Completed", fallback)
            print("PASS: missing transcript does not fail Stop")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)
            assert not worker.is_alive(), "fixture server did not stop"


if __name__ == "__main__":
    main()
