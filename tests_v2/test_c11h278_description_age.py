#!/usr/bin/env python3
"""C11H-278: a panel's description records when its text last changed.

Through the real CLI and socket:
1. `set-description` records `description_updated_at` (local time with offset)
   and `description_age_seconds`; `get-titlebar-state --json`, `tree --json`
   and `sidebar-state --json` all report it, and the socket agrees.
2. Re-setting the same text keeps the time; new text moves it.
3. The time survives a session save and restore (DEBUG harness). A failed save
   or load fails; only a build without the harness skips.

Requires C11_SOCKET + C11_CLI (the tagged build's `c11` binary).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402

LOCAL_STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _cli(cli: str, sock: str, args: list[str], parse: bool = True) -> dict:
    env = dict(os.environ)
    env["C11_SOCKET"] = sock
    env["CMUX_SOCKET"] = sock
    # `both` keeps each `id` beside its `ref` (the default `refs` drops ids).
    argv = [cli, "--id-format", "both"] + (["--json"] if parse else []) + args
    proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
    _must(proc.returncode == 0, f"c11 {' '.join(args)} failed rc={proc.returncode}: {proc.stderr[:300]}")
    return json.loads(proc.stdout) if parse else {}


def _tree_panel(tree: dict, surface_id: str) -> dict:
    for window in tree.get("windows") or []:
        for workspace in window.get("workspaces") or []:
            for pane in workspace.get("panes") or workspace.get("areas") or []:
                for surface in pane.get("surfaces") or pane.get("panels") or []:
                    if str(surface.get("id")).lower() == surface_id.lower():
                        return surface
    raise cmuxError(f"panel {surface_id} not in tree --json")


def _sidebar_entry(state: dict, surface_id: str) -> dict:
    for entry in state.get("descriptions") or []:
        if str(entry.get("panel_id")).lower() == surface_id.lower():
            return entry
    raise cmuxError(f"panel {surface_id} not in sidebar-state descriptions: {state.get('descriptions')}")


def main() -> int:
    sock = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET")
    cli = os.environ.get("C11_CLI") or os.environ.get("CMUXTERM_CLI")
    if not sock or not os.path.exists(sock):
        print(f"FAIL: no reachable c11 socket ({sock!r})")
        return 1
    if not cli or not (os.path.isfile(cli) and os.access(cli, os.X_OK)):
        print(f"FAIL: C11_CLI not set to an executable c11 binary ({cli!r})")
        return 1

    with cmux(sock) as c:
        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        try:
            current = c._call("panel.current", {"workspace_id": ws_id}) or {}
            surface_id = str(current.get("panel_id") or "")
            _must(bool(surface_id), f"panel.current returned no panel_id: {current}")
            target = ["--workspace", ws_id, "--panel", surface_id]

            # 1. A write records the time; every reader reports it.
            before = time.time()
            _cli(cli, sock, ["set-description"] + target + ["Auditing retry admission"], parse=False)
            bar = _cli(cli, sock, ["get-titlebar-state"] + target)
            stamp = bar.get("description_updated_at")
            _must(isinstance(stamp, str) and LOCAL_STAMP.match(stamp), f"titlebar stamp: {bar}")
            _must(isinstance(bar.get("description_age_seconds"), int) and bar["description_age_seconds"] <= 5,
                  f"titlebar age: {bar}")
            ts = float(bar.get("description_ts"))
            _must(before - 1 <= ts <= time.time() + 1, f"edit time {ts} outside the write window")

            socket_bar = c._call("panel.get_titlebar_state", {"panel_id": surface_id}) or {}
            _must(socket_bar.get("description_updated_at") == stamp, f"socket disagrees: {socket_bar}")

            tree = _cli(cli, sock, ["tree", "--workspace", ws_id])
            _must(_tree_panel(tree, surface_id).get("description_updated_at") == stamp, "tree --json stamp")

            sidebar = _cli(cli, sock, ["sidebar-state", "--workspace", ws_id])
            entry = _sidebar_entry(sidebar, surface_id)
            _must(entry.get("description_updated_at") == stamp and entry.get("description") == "Auditing retry admission",
                  f"sidebar-state entry: {entry}")

            # 2. Rewriting the same text keeps the time; new text moves it. (Same
            # text from another source is proven by the logic test
            # testSameDescriptionFromAnotherSourceKeepsItsEditTime: a lower
            # source is refused here before the rule is reached.)
            time.sleep(1.2)
            _cli(cli, sock, ["set-description"] + target + ["Auditing retry admission"], parse=False)
            same = c._call("panel.get_titlebar_state", {"panel_id": surface_id}) or {}
            _must(float(same.get("description_ts")) == ts, f"same text moved the edit time: {same}")
            _must(same.get("description_age_seconds", 0) >= 1, f"age did not grow: {same}")

            _cli(cli, sock, ["set-description"] + target + ["Verifying cancellation"], parse=False)
            moved = c._call("panel.get_titlebar_state", {"panel_id": surface_id}) or {}
            _must(float(moved.get("description_ts")) > ts, f"new text kept the old time: {moved}")
            edited = moved.get("description_updated_at")

            # 3. A session save and restore keeps it. Only a build without the
            # DEBUG harness may skip; a failed save or load fails the test.
            try:
                c._call("debug.session.save_and_load", {})
            except cmuxError as e:
                if not str(e).startswith("method_not_found:"):
                    raise cmuxError(f"session save/restore failed: {e}")
                print(f"SKIP persist case: no debug.session.save_and_load in this build ({e})")
                print("PASS: C11H-278 description edit time (record, report, same-text)")
                return 0
            restored = c._call("panel.get_titlebar_state", {"panel_id": surface_id}) or {}
            _must(restored.get("description_updated_at") == edited
                  and float(restored.get("description_ts")) == float(moved.get("description_ts")),
                  f"edit time lost in save/restore: before={moved} after={restored}")
        finally:
            c.close_workspace(ws_id)

    print("PASS: C11H-278 description edit time (record, report, same-text, persist)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except cmuxError as e:
        print(f"FAIL: {e}")
        raise SystemExit(1)
