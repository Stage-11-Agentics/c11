#!/usr/bin/env python3
"""Exercise history CLI parsing/output against a fake socket, with no app.

Run with C11_CLI_BIN pointing at a CLI built from the change under test.
Fixtures are synthetic; no live session or persisted history is touched.
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


def entry(number: int, current: bool = False) -> dict:
    return {
        "workspace_id": "11111111-1111-4111-8111-111111111111",
        "workspace_ref": "workspace:1", "workspace_title": "Example workspace",
        "panel_id": f"22222222-2222-4222-8222-{number:012d}",
        "panel_ref": f"panel:{number}", "title": f"Example {number}",
        "type": "terminal", "seen_at": "2026-10-01T22:00:00Z",
        "dwell_seconds": 2.0, "current": current,
    }


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            text = line.decode().strip()
            if not text.startswith("{"):
                self.server.calls.append((text, {}))
                response = "OK"
            else:
                request = json.loads(text)
                method, params = request["method"], request.get("params", {})
                self.server.calls.append((method, params))
                ok = True
                if method == "system.capabilities":
                    payload = {"methods": ["panel.list", "history.list", "history.back", "history.forward"],
                               "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
                elif method == "history.list":
                    payload = copy.deepcopy(self.server.history)
                    payload["entries"] = payload["entries"][-params.get("limit", 50):]
                elif method in ("history.back", "history.forward"):
                    if self.server.navigation_error:
                        ok = False
                        payload = {"code": "not_found", "message": self.server.navigation_error}
                    else:
                        payload = {**entry(2, True), "position": 1}
                else:
                    ok = False
                    payload = {"code": "method_not_found", "message": f"Unexpected {method}"}
                response = json.dumps({"id": request["id"], "ok": ok,
                                       "result" if ok else "error": payload})
            self.wfile.write((response + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str) -> None:
        self.calls = []
        self.navigation_error = None
        self.history = {
            "threshold_seconds": 1.0, "cap": 200, "total": 3,
            "position": 1, "back_count": 1, "forward_count": 1,
            "entries": [entry(1), entry(2, True), entry(3)],
        }
        super().__init__(path, Handler)


def main() -> int:
    cli = os.environ.get("C11_CLI_BIN")
    if not cli or not Path(cli).is_file() or not os.access(cli, os.X_OK):
        raise SystemExit("Set C11_CLI_BIN to the CLI built from this change.")
    with tempfile.TemporaryDirectory(prefix="c11hist-") as directory:
        path = str(Path(directory) / "fake.sock")
        server = Server(path)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def run(*args: str, success: bool = True) -> subprocess.CompletedProcess:
            server.calls.clear()
            proc = subprocess.run(
                [cli, "--socket", path, "--password", "synthetic-password", *args],
                env=fake_server_env(path), text=True, capture_output=True, timeout=10,
            )
            assert (proc.returncode == 0) == success, (args, proc.returncode, proc.stdout, proc.stderr)
            assert all(method != "window.focus" for method, _ in server.calls), server.calls
            return proc

        try:
            expected = {**server.history, "entries": server.history["entries"][-2:]}
            for args in (("--json", "history", "--limit", "2"),
                         ("history", "list", "--limit", "2", "--json"),
                         ("--window", "window:99", "history", "--json", "--limit", "2")):
                assert json.loads(run(*args).stdout) == expected
                assert server.calls[0][0] == "auth synthetic-password", server.calls
                assert server.calls[-1] == ("history.list", {"limit": 2}), server.calls
            out = run("history", "--limit", "2").stdout.splitlines()
            assert out == ["3 entries, showing 2, position 1",
                           "panel:2  Example 2  2.0s  2026-10-01T22:00:00Z  ←",
                           "panel:3  Example 3  2.0s  2026-10-01T22:00:00Z"], out
            for action in ("back", "forward"):
                out = run("--window", "window:99", "history", action).stdout
                assert out == "panel:2  Example 2\n", out
                assert server.calls[-1] == (f"history.{action}", {}), server.calls
                assert json.loads(run("history", action, "--json").stdout) == {**entry(2, True), "position": 1}
                out = run("history", action, "--limit", "2", success=False)
                assert "limit applies to history listing" in out.stderr, out.stderr
                assert not any(m.startswith("history.") for m, _ in server.calls), server.calls
                server.navigation_error = f"No {'earlier' if action == 'back' else 'later'} focus history entry"
                out = run("history", action, success=False)
                assert out.returncode == 1 and server.navigation_error in out.stderr, out.stderr
                server.navigation_error = None
            for value in ("0", "201", "1.5", "null", "abc"):
                out = run("history", "--limit", value, success=False)
                assert "limit must be an integer from 1 to 200" in out.stderr, out.stderr
                assert not any(m.startswith("history.") for m, _ in server.calls), server.calls
            out = run("history", "--limit", success=False)
            assert "limit must be an integer from 1 to 200" in out.stderr
            for args in (("history", "sideways"), ("history", "back", "forward"), ("history", "--unknown")):
                run(*args, success=False)
                assert not any(m.startswith("history.") for m, _ in server.calls), server.calls
            run("history")
            assert server.calls[-1] == ("history.list", {}), server.calls
            server.history = {**server.history, "entries": [], "total": 0, "position": None,
                              "back_count": 0, "forward_count": 0}
            assert run("history").stdout == "No focus history.\n"
            assert json.loads(run("history", "--json").stdout) == server.history
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        proc = subprocess.run([cli, "--socket", path, "history", "--help"],
                              env=fake_server_env(path), text=True, capture_output=True, timeout=10)
        assert proc.returncode == 0 and "Usage: c11 history" in proc.stdout, (proc.stdout, proc.stderr)
    print("PASS: history CLI fake-socket parsing, rendering, navigation and focus preservation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
