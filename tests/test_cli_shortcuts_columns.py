#!/usr/bin/env python3
"""C11-489: `c11 shortcuts list` sizes its columns to the widest row.

Runs the built CLI against a fake socket, with no app. Run with C11_CLI_BIN
pointing at a CLI built from the change under test.
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


def row(action: str, display: str, combo: str, **extra) -> dict:
    return {"action": action, "label": action, "display": display, "shortcut": combo,
            "default_display": display, "default_shortcut": combo, "customized": False, **extra}


# The 32-character name that broke the fixed 32-column layout, one longer still,
# and a display wider than the old 8-column minimum.
ROWS = [
    row("toggle-sidebar", "⌘B", "cmd+b"),
    row("show-browser-java-script-console", "⌥⌘C", "opt+cmd+c"),
    row("a-synthetic-action-name-wider-than-thirty-two", "⌃⌥⇧⌘RETURN", "ctrl+opt+shift+cmd+return"),
    row("open-browser", "⇧⌘L", "shift+cmd+l", customized=True, default_display="⌘L"),
]


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            text = line.decode().strip()
            if not text.startswith("{"):
                response = "OK"
            else:
                request = json.loads(text)
                method = request["method"]
                ok = True
                if method == "system.capabilities":
                    payload = {"methods": ["settings.shortcuts.list", "settings.shortcuts.set"],
                               "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
                elif method == "settings.shortcuts.list":
                    payload = {"shortcuts": ROWS}
                elif method == "settings.shortcuts.set":
                    payload = {**ROWS[1], "previous": "opt+cmd+c", "conflicts": ["toggle-sidebar"]}
                else:
                    ok = False
                    payload = {"code": "method_not_found", "message": f"Unexpected {method}"}
                response = json.dumps({"id": request["id"], "ok": ok, "result" if ok else "error": payload})
            self.wfile.write((response + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def column_starts(line: str, fields: list[str]) -> list[int]:
    starts, offset = [], 0
    for field in fields:
        index = line.index(field, offset)
        starts.append(index)
        offset = index + len(field)
    return starts


def main() -> int:
    cli = os.environ.get("C11_CLI_BIN")
    if not cli or not Path(cli).is_file() or not os.access(cli, os.X_OK):
        raise SystemExit("Set C11_CLI_BIN to the CLI built from this change.")
    with tempfile.TemporaryDirectory(prefix="c11keys-") as directory:
        path = str(Path(directory) / "fake.sock")
        server = Server(path, Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()

        def run(*args: str) -> list[str]:
            proc = subprocess.run([cli, "--socket", path, *args], env=fake_server_env(path),
                                  text=True, capture_output=True, timeout=10)
            assert proc.returncode == 0, (args, proc.returncode, proc.stdout, proc.stderr)
            return proc.stdout.splitlines()

        try:
            lines = run("shortcuts", "list")
            assert len(lines) == len(ROWS), lines
            starts = [column_starts(line, [r["action"], r["display"], r["shortcut"]])
                      for line, r in zip(lines, ROWS)]
            assert all(s[0] == 0 for s in starts), lines
            assert len({s[1] for s in starts}) == 1, ("display column misaligned", lines)
            assert len({s[2] for s in starts}) == 1, ("combo column misaligned", lines)
            widest = max(len(r["action"]) for r in ROWS)
            assert starts[0][1] == widest + 2, ("action column not sized to the widest action", lines)
            assert starts[0][2] == starts[0][1] + max(len(r["display"]) for r in ROWS) + 2, lines
            assert lines[3].endswith("shift+cmd+l  (default ⌘L)"), lines[3]

            lines = run("shortcuts", "set", "show-browser-java-script-console", "opt+cmd+c")
            assert lines[0] == "show-browser-java-script-console  ⌥⌘C  opt+cmd+c", lines
            assert lines[1].startswith("warning: ⌥⌘C is also bound to toggle-sidebar"), lines
        finally:
            server.shutdown()
            server.server_close()
    print("PASS: shortcuts list columns fit the widest row")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
