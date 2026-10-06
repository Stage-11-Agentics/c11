#!/usr/bin/env python3
"""Regression (C11-337 R1 review): browser panel switch/close by index act on the
indexed panel, never on the context panel the request names in `surface_id`.

Both the panel CLI and the v0.67 CLI send `{surface_id: <context>, index: N}`. If
the context ever leaked into the explicit target (`tab_id`), `close N` would close
the context panel instead of panel N.

Run against a tagged build's socket:
  C11_SOCKET=/tmp/c11-debug-<tag>.sock C11_CLI=<tagged CLI> python3 tests_v2/test_browser_panel_index_target.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary  # type: ignore[import]


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "/tmp/c11-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _browser_ids(client: cmux, ws: str) -> list[str]:
    res = client._call("browser.panel.list", {"workspace_id": ws}) or {}
    rows = sorted(res.get("panels") or [], key=lambda row: row.get("index", 0))
    return [str(row["id"]) for row in rows]


def _new_browser(client: cmux, ws: str) -> str:
    res = client._call("browser.panel.new", {"workspace_id": ws, "url": "about:blank"}) or {}
    panel = str(res.get("panel_id") or "")
    _must(bool(panel), f"browser.panel.new returned no panel_id: {res}")
    return panel


def main() -> int:
    cli = find_cli_binary()
    created: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            ws = str((client._call("workspace.create") or {}).get("workspace_id") or "")
            _must(bool(ws), "workspace.create returned no workspace_id")
            created.append(ws)
            context = _new_browser(client, ws)

            # Socket, both method spellings: close B by index while naming A as context.
            for method in ("browser.panel.close", "browser.tab.close"):
                target = _new_browser(client, ws)
                time.sleep(0.2)
                ids = _browser_ids(client, ws)
                _must(context in ids and target in ids, f"setup: {ids}")
                res = client._call(method, {"workspace_id": ws, "surface_id": context, "index": ids.index(target)}) or {}
                time.sleep(0.2)
                after = _browser_ids(client, ws)
                _must(target not in after, f"{method} by index should close the indexed panel: {res} {after}")
                _must(context in after, f"{method} by index must keep the context panel: {res} {after}")

            # Precedence: an explicit target beats the index, and the context never wins.
            for method in ("browser.panel.close", "browser.tab.close"):
                explicit = _new_browser(client, ws)
                indexed = _new_browser(client, ws)
                time.sleep(0.2)
                ids = _browser_ids(client, ws)
                res = client._call(method, {"workspace_id": ws, "surface_id": context,
                                            "target_panel_id": explicit, "index": ids.index(indexed)}) or {}
                time.sleep(0.2)
                after = _browser_ids(client, ws)
                _must(explicit not in after, f"{method}: explicit target_panel_id should be closed: {res} {after}")
                _must(indexed in after and context in after,
                      f"{method}: the indexed and context panels must stay: {res} {after}")
                client._call("browser.panel.close", {"workspace_id": ws, "target_panel_id": indexed})

            # Socket, both method spellings: switch to B by index while naming A as context.
            target = _new_browser(client, ws)
            time.sleep(0.2)
            for method in ("browser.panel.switch", "browser.tab.switch"):
                ids = _browser_ids(client, ws)
                res = client._call(method, {"workspace_id": ws, "surface_id": context, "index": ids.index(target)}) or {}
                _must(res.get("panel_id") == target, f"{method} by index should select the indexed panel: {res}")
                _must(res.get("tab_id") == target and "surface_id" not in res, f"{method} result keys: {res}")

            # CLI: `c11 browser <context> panel close <index>` (and the tab-era spelling).
            for verb in ("panel", "tab"):
                victim = _new_browser(client, ws)
                time.sleep(0.2)
                ids = _browser_ids(client, ws)
                proc = subprocess.run(
                    [cli, "--socket", SOCKET_PATH, "browser", context, verb, "close", str(ids.index(victim))],
                    capture_output=True, text=True, check=False,
                )
                _must(proc.returncode == 0, f"browser {verb} close failed: {proc.stdout} {proc.stderr}")
                time.sleep(0.2)
                after = _browser_ids(client, ws)
                _must(victim not in after and context in after,
                      f"`browser <ctx> {verb} close <i>` closed the wrong panel: {after}")

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

    print("PASS: browser panel switch/close by index act on the indexed panel, not the context panel")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
