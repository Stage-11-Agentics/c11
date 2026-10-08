#!/usr/bin/env python3
"""Skew (C11-337 R1): a v0.67 CLI against a panel app reuses the refs it prints.

v0.67 only knows `tab:N` refs. Its `tree` / `identify` use the unchanged method
names `system.tree` / `system.identify`, and it sends `caller: {tab_id}` when it
runs inside a terminal; the app answers that shape with `tab:N` generic refs, so
the CLI can feed its own tree output back into `--tab`.

Needs the v0.67 CLI binary: C11_V067_CLI=/Applications/c11.app/Contents/Resources/bin/c11
(prints SKIP and exits 0 when unset).

  C11_SOCKET=/tmp/c11-debug-<tag>.sock C11_V067_CLI=... python3 tests_v2/test_vocabulary_v067_cli_refs.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "/tmp/c11-debug.sock")
OLD_CLI = os.environ.get("C11_V067_CLI", "")
ID_ENV = ("C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID",
          "CMUX_SURFACE_ID", "C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _old(args: list[str], caller: str, ws: str) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if k not in ID_ENV}
    # The v0.67 shape: a terminal's caller env, read as C11_TAB_ID / CMUX_WORKSPACE_ID.
    env.update({"C11_TAB_ID": caller, "CMUX_WORKSPACE_ID": ws, "CMUX_CLI_SENTRY_DISABLED": "1"})
    return subprocess.run([OLD_CLI, "--socket", SOCKET_PATH, *args], capture_output=True, text=True,
                          check=False, env=env, timeout=60)


def _tree_panel_rows(node: object) -> list[dict]:
    rows: list[dict] = []
    if isinstance(node, dict):
        # The app emits `panels` only (C11-345); v0.67's tree copies the app's area node
        # through, so the panel rows arrive under `panels` with their `tab:N` echo.
        for key in ("panels", "tabs", "surfaces"):
            for row in node.get(key) or []:
                if isinstance(row, dict) and row.get("ref"):
                    rows.append(row)
        for child in node.values():
            if isinstance(child, (dict, list)):
                rows.extend(_tree_panel_rows(child))
    elif isinstance(node, list):
        for child in node:
            rows.extend(_tree_panel_rows(child))
    return rows


def main() -> int:
    if not OLD_CLI or not os.path.exists(OLD_CLI):
        print("SKIP: set C11_V067_CLI to a v0.67.0 c11 CLI")
        return 0
    created: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            ws = str((client._call("workspace.create") or {}).get("workspace_id") or "")
            _must(bool(ws), "workspace.create returned no workspace_id")
            created.append(ws)
            panels = (client._call("panel.list", {"workspace_id": ws}) or {}).get("panels") or []
            caller = str(panels[0]["id"])
            target = str((client._call("panel.create", {"workspace_id": ws}) or {}).get("panel_id") or "")
            _must(bool(target), "panel.create returned no panel_id")
            time.sleep(0.3)

            proc = _old(["--json", "--id-format", "both", "tree", "--workspace", ws], caller, ws)
            _must(proc.returncode == 0, f"v0.67 tree --json failed: {proc.stdout} {proc.stderr}")
            rows = _tree_panel_rows(json.loads(proc.stdout))
            _must(rows, f"v0.67 tree --json listed no panels: {proc.stdout[:400]}")
            for row in rows:
                _must(str(row["ref"]).startswith("tab:"), f"v0.67 tree should see tab:N refs, got {row['ref']!r}")
            target_ref = next(str(r["ref"]) for r in rows if str(r.get("id")) == target)

            text = _old(["tree", "--no-layout", "--workspace", ws], caller, ws)
            _must(text.returncode == 0 and "panel:" not in text.stdout,
                  f"v0.67 tree text should print tab:N refs: {text.stdout!r} {text.stderr!r}")

            # identify carries no generic `ref`; its tab_ref pair is completion's job, not the echo's.

            # Feed the tree's own ref back in.
            renamed = _old(["rename-tab", "--workspace", ws, "--tab", target_ref, "v067-roundtrip"], caller, ws)
            _must(renamed.returncode == 0, f"v0.67 rename-tab {target_ref} failed: {renamed.stdout} {renamed.stderr}")
            titles = {str(p["id"]): p.get("title") for p in (client._call("panel.list", {"workspace_id": ws}) or {}).get("panels") or []}
            _must(titles.get(target) == "v067-roundtrip", f"rename via tree ref missed the panel: {titles}")
            sent = _old(["send", "--workspace", ws, "--tab", target_ref, "echo v067-roundtrip"], caller, ws)
            _must(sent.returncode == 0, f"v0.67 send --tab {target_ref} failed: {sent.stdout} {sent.stderr}")
            title = _old(["get-titlebar-state", "--workspace", ws, "--tab", target_ref], caller, ws)
            _must(title.returncode == 0 and "v067-roundtrip" in title.stdout,
                  f"v0.67 get-titlebar-state {target_ref}: {title.stdout} {title.stderr}")

            client._call("workspace.close", {"workspace_id": ws})
            created.clear()
    finally:
        if created:
            try:
                with cmux(SOCKET_PATH) as cleanup:
                    for ws in created:
                        cleanup._call("workspace.close", {"workspace_id": ws})
            except Exception:
                pass
    print("PASS: a v0.67 CLI sees tab:N refs in its own tree and reuses them against a panel app")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
