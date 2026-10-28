#!/usr/bin/env python3
"""v2 regression (C11-490, C11-491): a terminal panel moved to another
workspace keeps its metadata, attention and tty, and the shell it was running
still identifies and mails as that panel, though its C11_WORKSPACE_ID names
the workspace it started in.

Live socket test: run only in a sandbox guest (scripts/sandbox-tests-v2.sh).
"""

import json
import os
import shlex
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _panel_row(c: cmux, workspace_id: str, panel_id: str) -> dict:
    rows = (c._call("panel.list", {"workspace_id": workspace_id}) or {}).get("panels") or []
    for row in rows:
        if str(row.get("id")).upper() == panel_id.upper():
            return row
    return {}


def _wait(predicate, timeout_s: float, label: str):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for {label}")


def _metadata(c: cmux, panel_id: str) -> tuple[dict, dict]:
    res = c._call("panel.get_metadata", {"panel_id": panel_id, "include_sources": True}) or {}
    metadata = dict(res.get("metadata") or {})
    metadata.pop("journal", None)   # a live projection, not stored metadata
    return metadata, dict(res.get("metadata_sources") or {})


def _run_in_panel(c: cmux, panel_id: str, cli: str, args: str, out: Path) -> dict:
    """Type one CLI call into the panel's own shell; its result lands in `out`."""
    done = out.with_suffix(".done")
    for stale in (out, done):
        stale.unlink(missing_ok=True)
    line = (f"{shlex.quote(cli)} {args} > {shlex.quote(str(out))} 2>&1; "
            f"echo $? > {shlex.quote(str(done))}\n")
    c.send_surface(panel_id, line)
    _wait(done.exists, 15, f"{args} in the moved panel")
    return {"status": int(done.read_text().strip() or "-1"), "output": out.read_text()}


def main() -> int:
    cli = find_cli_binary()
    scratch = Path(tempfile.mkdtemp(prefix="c11-491-"))
    with cmux(SOCKET_PATH) as c:
        start_ws = c.new_workspace()
        mover = c.list_surfaces(start_ws)[0][1]
        recipient = c.new_surface(panel_type="terminal")
        recipient_ws = next(ws for _i, ws, _t, _s in c.list_workspaces()
                            if _panel_row(c, ws, recipient))
        tty = _wait(lambda: _panel_row(c, start_ws, mover).get("tty"), 20, "the mover's shell tty")
        _wait(lambda: _panel_row(c, recipient_ws, recipient).get("tty"), 20, "the recipient's shell tty")

        c._call("panel.set_metadata", {"panel_id": mover, "metadata": {
            "title": "Move fixer",
            "description": "Carrying metadata across a move",
            "model": "claude-opus-5-5",
            "mailbox.address": "c11-move-fixer",
            "mailbox.delivery": "stdin",
            "custom.note": {"kept": True},
        }})
        c._call("panel.set_metadata", {"panel_id": recipient, "metadata": {
            "title": "Move recipient", "mailbox.address": "c11-move-recipient",
        }})
        c._call("flag.raise", {"surface_id": mover, "reason": "Need a call on the move", "by": "operator"})
        c._call("flag.delegate", {"surface_id": mover, "by": "agent", "caller_surface_id": recipient})
        # Agent detection classifies the shell shortly after its tty report
        # and again after the move; let it settle so "before" is complete.
        _wait(lambda: _metadata(c, mover)[0].get("terminal_type"), 20, "agent detection of the mover's shell")
        before, before_sources = _metadata(c, mover)
        if before.get("flag") != "Need a call on the move" or before.get("delegated") is not True:
            raise cmuxError(f"Setup did not flag and delegate the mover: {before}")

        live_ws = c.new_workspace()
        c.move_surface(mover, workspace=live_ws, focus=False)
        _wait(lambda: _panel_row(c, live_ws, mover), 5, "the mover in its new workspace")

        # C11-490: every key, its source and timestamp, the flag and the tty.
        after, after_sources = _metadata(c, mover)
        if after != before:
            raise cmuxError(f"Metadata changed across the move:\nbefore={before}\nafter={after}")
        if after_sources != before_sources:
            raise cmuxError(f"Sources changed across the move:\nbefore={before_sources}\nafter={after_sources}")
        if after.get("delegated_by", "").upper() != recipient.upper():
            raise cmuxError(f"Delegate owner lost: {after}")
        moved_tty = _panel_row(c, live_ws, mover).get("tty")
        if moved_tty != tty:
            raise cmuxError(f"tty lost across the move: before={tty!r} after={moved_tty!r}")

        # C11-491: the moved shell still has the start workspace in its env.
        env = _run_in_panel(c, mover, "/usr/bin/printenv", "C11_WORKSPACE_ID", scratch / "env.txt")
        if env["output"].strip().upper() != start_ws.upper():
            raise cmuxError(f"Expected the moved shell to keep its start workspace: {env}")

        ident = _run_in_panel(c, mover, cli, "--id-format both identify --json", scratch / "identify.json")
        if ident["status"] != 0:
            raise cmuxError(f"identify failed in the moved panel: {ident}")
        caller = json.loads(ident["output"]).get("caller") or {}
        if str(caller.get("workspace_id", "")).upper() != live_ws.upper():
            raise cmuxError(f"identify kept the stale workspace: {caller}")
        if str(caller.get("panel_id") or caller.get("surface_id") or "").upper() != mover.upper():
            raise cmuxError(f"identify found no caller panel: {caller}")

        name = _run_in_panel(c, mover, cli, "mailbox panel-name", scratch / "name.txt")
        if name["status"] != 0 or name["output"].strip() != "Move fixer":
            raise cmuxError(f"mailbox panel-name failed in the moved panel: {name}")

        body = "hello from a moved panel"
        sent = _run_in_panel(c, mover, cli, f"mailbox send --to c11-move-recipient {shlex.quote(body)}",
                             scratch / "send.txt")
        if sent["status"] != 0:
            raise cmuxError(f"mailbox send failed in the moved panel: {sent}")

        def delivered():
            inbox = _run_in_panel(c, recipient, cli, "mailbox recv --peek", scratch / "recv.txt")
            return inbox if body in inbox["output"] else None
        inbox = _wait(delivered, 20, "the recipient to receive the moved panel's mail")
        if "c11-move-fixer" not in inbox["output"]:
            raise cmuxError(f"Envelope from is not the mover's address: {inbox}")

        screen = _run_in_panel(c, mover, cli, "read-screen", scratch / "screen.txt")
        if screen["status"] != 0 or "read-screen" not in screen["output"]:
            raise cmuxError(f"read-screen failed in the moved panel: {screen}")

        for ws in (start_ws, live_ws):
            try:
                c.close_workspace(ws)
            except cmuxError:
                pass

    print("PASS: a moved panel keeps its metadata, attention and tty, and its shell identifies and mails as itself")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
