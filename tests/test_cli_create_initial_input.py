#!/usr/bin/env python3
"""C11-280 executable CLI create-input fixture against an isolated JSON socket.

Requires C11_CLI=/absolute/path/to/the/exact/built/c11. No app, terminal, or
production socket is used. The fake server observes requests and returns queued
receipts; this proves CLI delivery/rendering, not shell execution.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


WORKSPACE = "11111111-1111-4111-8111-111111111111"
AREA = "22222222-2222-4222-8222-222222222222"
TAB = "33333333-3333-4333-8333-333333333333"
METHODS = {
    "new-workspace": "workspace.create",
    "new-split": "panel.split",
    "new-area": "area.create",
    "new-panel": "panel.create",
}


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        with self.server.observations_lock:
            self.server.connections += 1
        while line := self.rfile.readline():
            # The CLI may authenticate/probe through the legacy transport
            # before JSON discovery. Like the other fake-server fixtures,
            # acknowledge it without logging possible credential bytes.
            if not line.startswith(b"{"):
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue
            request = json.loads(line)
            method = request["method"]
            params = request.get("params", {})
            with self.server.observations_lock:
                self.server.calls.append((method, params))
            ok = True
            if method == "system.capabilities":
                payload = {"methods": ["panel.list", *METHODS.values()],
                           "features": [{"id": "create.initial_input", "version": 1},
                                        {"id": "vocabulary.workspace_area_panel", "version": 1}]}
            elif method in METHODS.values():
                payload = {"workspace_id": WORKSPACE, "workspace_ref": "workspace:1"}
                if method != "workspace.create":
                    payload.update({"panel_id": TAB, "panel_ref": "panel:3",
                                    "area_id": AREA, "area_ref": "area:2",
                                    "type": params.get("type", "terminal")})
                if "initial_input" in params:
                    payload["initial_input"] = "queued"
            else:
                ok = False
                payload = {"code": "method_not_found", "message": f"Unexpected request: {method}"}
            response = {"id": request.get("id"), "ok": ok, "result" if ok else "error": payload}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str) -> None:
        self.observations_lock = threading.Lock()
        self.calls = []
        self.connections = 0
        super().__init__(path, Handler)

    def observations(self) -> tuple[list[tuple[str, dict]], int]:
        with self.observations_lock:
            return list(self.calls), self.connections


def main() -> int:
    try:
        configured_cli = os.environ.get("C11_CLI")
        assert configured_cli, "Set C11_CLI to the exact built native CLI"
        cli = Path(configured_cli).expanduser().resolve(strict=True)
        assert os.access(cli, os.X_OK), "C11_CLI is not executable"
        with tempfile.TemporaryDirectory(prefix="c11280-") as directory:
            root = Path(directory)
            path = str(root / "fake.sock")
            absent_path = str(root / "absent.sock")
            (root / "home" / ".config").mkdir(parents=True)
            base = {key: value for key, value in os.environ.items()
                    if not key.startswith(("C11_", "CMUX_", "DYLD_"))}
            base.update({"HOME": str(root / "home"),
                         "XDG_CONFIG_HOME": str(root / "home" / ".config")})
            server = Server(path)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()

            def run(args: list[str], *, json_output: bool = False, socket_path: str = path) -> subprocess.CompletedProcess[str]:
                flags = ["--json", "--id-format", "uuids"] if json_output else []
                return subprocess.run([str(cli), "--socket", socket_path, *flags, *args],
                                      env=fake_server_env(socket_path, base), stdin=subprocess.DEVNULL,
                                      text=True, capture_output=True, timeout=10, check=False)

            def arguments(command: str, panel_type: str | None = None) -> list[str]:
                args = [command]
                if command == "new-split":
                    args += ["down", "--workspace", WORKSPACE, "--panel", TAB]
                elif command in ("new-area", "new-panel"):
                    args += ["--workspace", WORKSPACE]
                    if command == "new-panel":
                        args += ["--area", AREA]
                    if panel_type is not None:
                        args += ["--type", panel_type]
                return args

            def require_creation(command: str, args: list[str], raw: str | None,
                                 *, json_output: bool) -> None:
                previous, _ = server.observations()
                result = run(args, json_output=json_output)
                assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
                calls, _ = server.observations()
                calls = calls[len(previous):]
                # Discovery is allowed, but exactly one create request owns
                # the input. In particular, workspace.create must never be
                # followed by the old panel.send_text (or any second mutation).
                creations = [(method, params) for method, params in calls if method != "system.capabilities"]
                assert len(creations) == 1 and creations[0][0] == METHODS[command], calls
                assert all(method in ("system.capabilities", METHODS[command]) for method, _ in calls), calls
                params = creations[0][1]
                assert "initial_command" not in params, params
                queued = raw is not None and bool(raw.strip())
                if queued:
                    expected = raw if raw.endswith("\r") else raw + "\r"
                    assert params.get("initial_input", "").encode("utf-8") == expected.encode("utf-8"), params
                else:
                    assert "initial_input" not in params, params
                if json_output:
                    payload = json.loads(result.stdout)
                    assert (payload.get("initial_input") == "queued") == queued, payload
                    if not queued:
                        assert "initial_input" not in payload, payload
                else:
                    assert result.stdout.startswith("OK "), result.stdout
                    assert ("input=queued" in result.stdout) == queued, result.stdout

            def require_rejection(args: list[str], tokens: tuple[str, ...]) -> None:
                before_calls, before_connections = server.observations()
                for socket_path in (path, absent_path):
                    result = run(args, socket_path=socket_path)
                    assert result.returncode != 0, (args, result.stdout)
                    assert all(token in result.stderr for token in tokens), (args, result.stderr)
                    assert not result.stdout.strip(), (args, result.stdout)
                calls, connections = server.observations()
                assert calls == before_calls and connections == before_connections, (
                    "Rejected create must not even connect to the socket", args, calls, connections
                )

            try:
                body = "  printf '%s' " + r"literal\n" + " 日本語 🪨 café\n trailing  "
                for command in METHODS:
                    panel_types = (None, "terminal") if command in ("new-area", "new-panel") else (None,)
                    for panel_type in panel_types:
                        args = arguments(command, panel_type)
                        # A --command value can itself spell another CLI flag.
                        # It remains literal input, including help and routing
                        # names, rather than changing the create invocation.
                        for raw in (body, body + "\r", "--layout", "--type", "--help",
                                    "--command", "--workspace", "-h"):
                            for json_output in (False, True):
                                require_creation(command, [*args, "--command", raw], raw,
                                                 json_output=json_output)
                        for raw in ("", " \t\r\n "):
                            for json_output in (False, True):
                                require_creation(command, [*args, "--command", raw], raw,
                                                 json_output=json_output)
                        require_creation(command, args, None, json_output=True)
                    print(f"PASS: {command} sends exact input once and renders queued/absent receipts")

                for command in ("new-panel", "new-area"):
                    for panel_type in ("browser", "markdown"):
                        require_rejection([*arguments(command, panel_type), "--command", body],
                                          ("--command", panel_type))
                require_rejection(["new-workspace", "--layout", "missing-fixture-layout", "--command", body],
                                  ("--command", "--layout"))
                for command in METHODS:
                    require_rejection([*arguments(command), "--command"], ("--command", "requires"))
                print("PASS: nonterminal/layout/missing-value errors precede every connection and mutation")
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=2)
        return 0
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
