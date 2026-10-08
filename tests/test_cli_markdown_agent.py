#!/usr/bin/env python3
"""Exercise markdown agent CLI requests and JSON watch framing on a fake socket."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


def main() -> None:
    cli = os.environ.get("C11_CLI") or os.environ.get("C11_CLI_BIN")
    if not cli:
        raise RuntimeError("Set C11_CLI to the candidate bundled CLI")

    with tempfile.TemporaryDirectory(prefix="c11-markdown-agent-") as directory:
        socket_path = str(Path(directory) / "fixture.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        server.listen(8)
        server.settimeout(0.1)
        stopped = threading.Event()
        requests: list[dict] = []
        errors: list[str] = []

        state = {
            "heading_path": ["Guide", "Install"],
            "lines": {"first": 8, "last": 14, "total": 40},
            "progress": 0.25,
            "minutes_left": 2,
            "size": "medium",
            "theme": {"choice": "system", "resolved": "light"},
            "typeface": {"choice": "theme", "resolved": "sans"},
            "font_scale": 1.2,
            "find": None,
            "selection": "selected text",
        }

        def response(request: dict, *, ok: bool = True, result=None, code="invalid_params", message="invalid") -> bytes:
            if ok:
                body = {"id": request["id"], "ok": True, "result": result or {}}
            else:
                body = {"id": request["id"], "ok": False, "error": {"code": code, "message": message}}
            return (json.dumps(body, separators=(",", ":")) + "\n").encode()

        def serve_connection(connection: socket.socket) -> None:
            try:
                with connection, connection.makefile("rwb") as stream:
                    for raw in stream:
                        if not raw.startswith(b"{"):
                            # Existing auth/compat probes; never log their text.
                            stream.write(b"OK\n")
                            stream.flush()
                            continue
                        request = json.loads(raw)
                        requests.append(request)
                        method = request.get("method")
                        params = request.get("params", {})
                        if method == "system.capabilities":
                            payload = {
                                "methods": ["panel.list", "system.capabilities"],
                                "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}],
                            }
                            stream.write(response(request, result=payload))
                            stream.flush()
                        elif method == "markdown.visible" and params.get("watch") is True:
                            stream.write(response(request, result=state))
                            stream.write(response(request, result={**state, "progress": 0.5, "lines": {"first": 20, "last": 26, "total": 40}}))
                            stream.flush()
                            return
                        elif method == "markdown.theme" and params.get("action") == "list":
                            stream.write(response(request, result={"themes": ["system", "light", "dark"], "current": "system"}))
                            stream.flush()
                        elif method == "markdown.typeface" and params.get("action") == "list":
                            stream.write(response(request, result={"typefaces": ["theme", "serif", "sans", "mono"], "current": "theme"}))
                            stream.flush()
                        elif method == "markdown.theme" and params.get("name") == "unknown":
                            stream.write(response(request, ok=False, message="Unknown markdown theme: unknown"))
                            stream.flush()
                        elif method == "markdown.typeface" and params.get("name") == "unknown":
                            stream.write(response(request, ok=False, message="Unknown markdown typeface: unknown"))
                            stream.flush()
                        else:
                            result = {
                                "panel_id": params.get("panel_id"),
                                "scrolled": True,
                                "heading": {"text": params.get("heading", "")},
                                "theme": params.get("name", "system"),
                                "typeface": params.get("name", "theme"),
                                "font_scale": params.get("scale", 1.0),
                                "path": "/tmp/fixture.md",
                                "opened": method == "markdown.open_external",
                                "applied": method in {"markdown.theme", "markdown.typeface", "markdown.font"},
                            }
                            stream.write(response(request, result=result))
                            stream.flush()
            except Exception as error:  # surfaced after the child exits
                errors.append(f"{type(error).__name__}: {error}")

        def accept_loop() -> None:
            while not stopped.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                thread = threading.Thread(target=serve_connection, args=(connection,), daemon=True)
                thread.start()

        listener = threading.Thread(target=accept_loop, daemon=True)
        listener.start()

        def run(*args: str) -> subprocess.CompletedProcess[str]:
            env = fake_server_env(socket_path)
            env.update(CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1", C11_QUIET_DISCOVERY="1")
            try:
                return subprocess.run([cli, "--socket", socket_path, *args], env=env, capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(
                    f"CLI timed out for {args}; stdout={error.stdout!r}; stderr={error.stderr!r}; requests={requests}; server_errors={errors}"
                ) from error

        try:
            panel = "panel:8"
            cases = [
                (
                    ["--json", "markdown", "scroll", "--panel", panel, "--heading", "Installation"],
                    "markdown.scroll",
                    {"panel_id": panel, "heading": "Installation"},
                ),
                (["markdown", "visible", "--panel", panel, "--json"], "markdown.visible", {"panel_id": panel, "watch": False}),
                (["--json", "markdown", "theme", "--panel", panel, "--list"], "markdown.theme", {"panel_id": panel, "action": "list"}),
                (
                    ["--json", "markdown", "theme", "--panel", panel, "--set", "dark"],
                    "markdown.theme",
                    {"panel_id": panel, "action": "set", "name": "dark"},
                ),
                (
                    ["--json", "markdown", "typeface", "--panel", panel, "--list"],
                    "markdown.typeface",
                    {"panel_id": panel, "action": "list"},
                ),
                (
                    ["--json", "markdown", "typeface", "--panel", panel, "--set", "mono"],
                    "markdown.typeface",
                    {"panel_id": panel, "action": "set", "name": "mono"},
                ),
                (["--json", "markdown", "font", "--panel", panel, "--scale", "1.4"], "markdown.font", {"panel_id": panel, "scale": 1.4}),
                (["--json", "markdown", "open-external", "--panel", panel], "markdown.open_external", {"panel_id": panel}),
            ]
            for args, expected_method, expected_params in cases:
                start = len(requests)
                result = run(*args)
                assert result.returncode == 0, (args, result.stderr, requests, errors)
                method_requests = [item for item in requests[start:] if item.get("method") != "system.capabilities"]
                assert len(method_requests) == 1 and method_requests[0]["method"] == expected_method, method_requests
                assert method_requests[0]["params"] == expected_params, method_requests[0]

            for args in [
                ["markdown", "scroll", "--heading", "Installation"],
                ["markdown", "visible", "--panel", panel],
                ["markdown", "visible", "--panel", "1", "--json"],
                ["markdown", "font", "--panel", panel, "--scale", "3.1"],
                ["markdown", "font", "--panel", panel, "--scale", "nan"],
                ["markdown", "font", "--panel", panel, "--scale", "0x1p0"],
            ]:
                start = len(requests)
                result = run(*args)
                assert result.returncode != 0, (args, result.stdout)
                assert not [item for item in requests[start:] if item.get("method", "").startswith("markdown.")], args
                if "--panel" in args and args[args.index("--panel") + 1] == "1":
                    assert not [item for item in requests[start:] if item.get("method") == "panel.list"], args

            for args, expected_method in [
                (["--json", "markdown", "theme", "--panel", panel, "--set", "unknown"], "markdown.theme"),
                (["--json", "markdown", "typeface", "--panel", panel, "--set", "unknown"], "markdown.typeface"),
            ]:
                start = len(requests)
                result = run(*args)
                assert result.returncode != 0 and "Unknown markdown" in result.stderr, (args, result.stderr)
                method_requests = [item for item in requests[start:] if item.get("method") == expected_method]
                assert len(method_requests) == 1 and method_requests[0]["params"]["action"] == "set", method_requests

            start = len(requests)
            result = run("--json", "markdown", "visible", "--panel", panel, "--watch")
            assert result.returncode == 0, result.stderr
            snapshots = [json.loads(line) for line in result.stdout.splitlines()]
            assert len(snapshots) == 2, snapshots
            assert snapshots[0]["progress"] == 0.25 and snapshots[1]["progress"] == 0.5, snapshots
            watch_requests = [item for item in requests[start:] if item.get("method") == "markdown.visible"]
            assert len(watch_requests) == 1 and watch_requests[0]["params"]["watch"] is True, watch_requests
            assert not errors, errors
            print("PASS: markdown agent CLI sends explicit panel targets and exact socket methods/params")
            print("PASS: invalid CLI scales and missing targets reject before markdown mutation; visible watch prints NDJSON")
        finally:
            stopped.set()
            listener.join(timeout=2)
            server.close()


if __name__ == "__main__":
    main()
