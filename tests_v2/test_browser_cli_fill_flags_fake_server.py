#!/usr/bin/env python3
"""C11-345: `browser <panel> type|fill` consumes its flags before joining the text.

Regression: `c11 browser <panel> fill e11 "" --snapshot-after` used to send the text
"--snapshot-after" instead of clearing the field. The CLI is driven against an in-process
fake that speaks the v2 socket protocol, so this needs no app (and never touches the
operator's session or selected workspace). It checks the `browser.fill` / `browser.type`
requests the CLI actually sends, and what it prints.

Pinned:
- `--snapshot-after` and `--json` are flags wherever they appear, never text.
- An empty positional fills with "" (clears the field) and still honors `--snapshot-after`.
- After `--`, flag-like words are literal text (`type e11 -- --snapshot-after`).
- Unknown `--x` words stay text, as before.
- `type` with only flags is still rejected and sends nothing.

CLI binary: C11_CLI / CMUX_CLI_BIN, else the usual tests_v2 discovery.
Run: python3 tests_v2/test_browser_cli_fill_flags_fake_server.py
"""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError, find_cli_binary  # type: ignore[import]


PANEL = "44444444-4444-4444-8444-444444444441"
SNAPSHOT = "- textbox \"Name\" [ref=e11]"

ID_ENV_KEYS = (
    "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "C11_WORKSPACE_ID",
    "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
    "TMUX", "TMUX_PANE",
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


class FakeApp:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: List[Tuple[str, Dict[str, Any]]] = []

    def handle(self, method: str, params: Dict[str, Any]) -> Tuple[bool, Any]:
        with self.lock:
            self.requests.append((method, params))
        if method == "system.capabilities":
            return True, {
                "protocol": "cmux-socket",
                "version": 2,
                "methods": sorted(["system.ping", "system.capabilities", "browser.fill", "browser.type"]),
                "features": [{"id": "vocabulary.workspace_area_panel", "version": 1, "enabled": True}],
                "features_version": 1,
            }
        if method == "system.ping":
            return True, {"pong": True}
        if method in ("browser.fill", "browser.type"):
            out: Dict[str, Any] = {"panel_id": params.get("panel_id"), "ok": True}
            if params.get("snapshot_after"):
                out["post_action_snapshot"] = SNAPSHOT
            return True, out
        return False, {"code": "method_not_found", "message": f"fake app has no method {method}"}

    def calls(self, method: str) -> List[Dict[str, Any]]:
        with self.lock:
            return [p for m, p in self.requests if m == method]

    def browser_calls(self) -> List[Tuple[str, Dict[str, Any]]]:
        with self.lock:
            return [(m, p) for m, p in self.requests if m.startswith("browser.")]

    def reset(self) -> None:
        with self.lock:
            self.requests.clear()


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        app: FakeApp = self.server.app  # type: ignore[attr-defined]
        while True:
            line = self.rfile.readline()
            if not line:
                return
            text = line.decode("utf-8").strip()
            if text.startswith("{"):
                request = json.loads(text)
                ok, payload = app.handle(str(request.get("method")), request.get("params") or {})
                response: Dict[str, Any] = {"id": request.get("id"), "ok": ok}
                response["result" if ok else "error"] = payload
                out = json.dumps(response)
            else:
                out = "PONG" if text == "ping" else "OK"
            self.wfile.write((out + "\n").encode("utf-8"))
            self.wfile.flush()


class _Server(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, path: str, app: FakeApp) -> None:
        self.app = app
        super().__init__(path, _Handler)


def _resolve_cli() -> str:
    for key in ("C11_CLI", "CMUX_CLI_BIN", "CMUX_CLI"):
        value = os.environ.get(key)
        if value and os.path.isfile(value) and os.access(value, os.X_OK):
            return value
    return find_cli_binary()


def _run(cli: str, sock: str, args: Sequence[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    for key in ID_ENV_KEYS:
        env.pop(key, None)
    for key in ("CMUX_SOCKET_PATH", "C11_SOCKET_PATH", "CMUX_SOCKET", "C11_SOCKET"):
        env[key] = sock
    cmd = [cli, "--socket", sock, "browser", PANEL, *args]
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env, timeout=30)


def _one_call(app: FakeApp, args: Sequence[str]) -> Tuple[str, Dict[str, Any]]:
    calls = app.browser_calls()
    _must(len(calls) == 1, f"{list(args)}: expected exactly one browser request, got {calls}")
    return calls[0]


def check(
    cli: str,
    sock: str,
    app: FakeApp,
    args: Sequence[str],
    method: str,
    selector: str,
    text: str,
    snapshot_after: bool,
    json_output: bool,
) -> None:
    app.reset()
    proc = _run(cli, sock, args)
    _must(proc.returncode == 0, f"{list(args)}: exit={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}")
    sent_method, params = _one_call(app, args)
    _must(sent_method == method, f"{list(args)}: sent {sent_method}, expected {method}")
    _must(params.get("panel_id") == PANEL, f"{list(args)}: panel_id {params.get('panel_id')!r}")
    _must(params.get("selector") == selector, f"{list(args)}: selector {params.get('selector')!r}, expected {selector!r}")
    _must("text" in params and params["text"] == text,
          f"{list(args)}: text {params.get('text')!r}, expected {text!r}")
    _must(bool(params.get("snapshot_after")) == snapshot_after,
          f"{list(args)}: snapshot_after {params.get('snapshot_after')!r}, expected {snapshot_after}")

    stdout = proc.stdout.strip()
    if json_output:
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise cmuxError(f"{list(args)}: expected JSON output, got {stdout!r} ({exc})")
        _must(bool(payload.get("post_action_snapshot")) == snapshot_after,
              f"{list(args)}: JSON post_action_snapshot mismatch: {payload}")
    else:
        lines = stdout.splitlines()
        _must(bool(lines) and lines[0] == "OK", f"{list(args)}: expected text output starting with OK, got {stdout!r}")
        _must((SNAPSHOT in stdout) == snapshot_after, f"{list(args)}: snapshot presence mismatch in {stdout!r}")


def main() -> int:
    cli = _resolve_cli()
    with tempfile.TemporaryDirectory(prefix="c11-fill-flags-") as tmp:
        sock = str(Path(tmp) / "fake.sock")
        app = FakeApp()
        server = _Server(sock, app)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # The reported bug: empty fill + trailing --snapshot-after clears and snapshots.
            check(cli, sock, app, ["fill", "e11", "", "--snapshot-after"],
                  "browser.fill", "e11", "", snapshot_after=True, json_output=False)
            check(cli, sock, app, ["fill", "e11", "", "--snapshot-after", "--json"],
                  "browser.fill", "e11", "", snapshot_after=True, json_output=True)
            # --json not in trailing position is still a flag, not text.
            check(cli, sock, app, ["fill", "e11", "", "--json", "--snapshot-after"],
                  "browser.fill", "e11", "", snapshot_after=True, json_output=True)
            check(cli, sock, app, ["fill", "e11", "--snapshot-after"],
                  "browser.fill", "e11", "", snapshot_after=True, json_output=False)
            check(cli, sock, app, ["fill", "--selector", "e11", "--text", "", "--snapshot-after"],
                  "browser.fill", "e11", "", snapshot_after=True, json_output=False)
            check(cli, sock, app, ["fill", "e11", "Jane", "Doe"],
                  "browser.fill", "e11", "Jane Doe", snapshot_after=False, json_output=False)
            # Flags interleaved with multi-word text.
            check(cli, sock, app, ["type", "e11", "hello", "--snapshot-after", "world"],
                  "browser.type", "e11", "hello world", snapshot_after=True, json_output=False)
            # `--` escapes literal flag text.
            check(cli, sock, app, ["type", "e11", "--", "--snapshot-after"],
                  "browser.type", "e11", "--snapshot-after", snapshot_after=False, json_output=False)
            check(cli, sock, app, ["type", "e11", "--snapshot-after", "--", "--json"],
                  "browser.type", "e11", "--json", snapshot_after=True, json_output=False)
            check(cli, sock, app, ["fill", "--", "e11", "a", "--text", "b"],
                  "browser.fill", "e11", "a --text b", snapshot_after=False, json_output=False)
            # Unknown dashed words remain text.
            check(cli, sock, app, ["type", "e11", "--not-a-flag"],
                  "browser.type", "e11", "--not-a-flag", snapshot_after=False, json_output=False)

            # `type` with no text (only flags) is rejected and sends nothing.
            app.reset()
            proc = _run(cli, sock, ["type", "e11", "--snapshot-after"])
            _must(proc.returncode != 0, f"type with only flags should fail: {proc.stdout!r} {proc.stderr!r}")
            _must("requires text" in (proc.stdout + proc.stderr), f"unexpected error: {proc.stdout!r} {proc.stderr!r}")
            _must(not app.browser_calls(), f"type with only flags must not send: {app.browser_calls()}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    print("PASS: browser type/fill parse flags before joining text")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
