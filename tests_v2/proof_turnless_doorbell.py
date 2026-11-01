#!/usr/bin/env python3
"""v2 guest proof (C11-555): a panel whose harness reports no turn edges still
gets later mail. After the first doorbell ring, mail that arrives in the same
idle period rings again once the 300 s once-per-idle floor lifts. A control
panel with turn edges, busy in a journal turn after its ring, is not rung.

Two fake agents (`fixture_turnless_agent.py`) hold raw-mode Claude-style
composers and register through `claude-hook session-start`. Takes about six
minutes. Live socket test: run only in a sandbox guest
(scripts/sandbox-tests-v2.sh tests_v2/proof_turnless_doorbell.py). Named proof_ so the default tests_v2 sweep skips it.
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
DOORBELL = "c11 mail waiting: run c11 mailbox recv --ack"
FLOOR = 300


def _panel_row(c: cmux, workspace_id: str, panel_id: str) -> dict:
    rows = (c._call("panel.list", {"workspace_id": workspace_id}) or {}).get("panels") or []
    for row in rows:
        if str(row.get("id")).upper() == panel_id.upper():
            return row
    return {}


def _workspace_of(c: cmux, panel_id: str) -> str:
    """Socket-created panels land where c11 puts them, not in a workspace
    the caller just made (agents cannot select a workspace)."""
    for _index, ws, _title, _selected in c.list_workspaces():
        if _panel_row(c, ws, panel_id):
            return ws
    return ""


def _wait(predicate, timeout_s: float, label: str):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    raise cmuxError(f"Timed out waiting for {label}")


def _records(log: Path) -> list:
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line.strip()]


def _rings(log: Path) -> list:
    return [r for r in _records(log) if r.get("event") == "submit" and r.get("line") == DOORBELL]


def _run_in_panel(c: cmux, panel_id: str, cli: str, args: str, out: Path, timeout_s: float = 20) -> dict:
    done = out.with_suffix(".done")
    for stale in (out, done):
        stale.unlink(missing_ok=True)
    line = (f"{shlex.quote(cli)} {args} > {shlex.quote(str(out))} 2>&1; "
            f"echo $? > {shlex.quote(str(done))}\n")
    c.send_surface(panel_id, line)
    _wait(done.exists, timeout_s, args)
    return {"status": int(done.read_text().strip() or "-1"), "output": out.read_text()}


def _send(c: cmux, sender: str, cli: str, to: str, body: str, scratch: Path) -> str:
    sent = _run_in_panel(c, sender, cli, f"mailbox send --to {to} {shlex.quote(body)}",
                         scratch / f"send-{to}-{int(time.time() * 1000)}.txt")
    if sent["status"] != 0:
        raise cmuxError(f"mailbox send to {to} failed: {sent}")
    return sent["output"].strip().splitlines()[0]


def main() -> int:
    cli = find_cli_binary()
    fixture = Path(__file__).parent / "fixture_turnless_agent.py"
    scratch = Path(tempfile.mkdtemp(prefix="c11-555-"))
    logs = {"turnless": scratch / "turnless.jsonl", "control": scratch / "control.jsonl"}
    started = time.time()

    def stamp(message: str) -> None:
        print(f"[{time.time() - started:7.1f}s] {message}", flush=True)

    with cmux(SOCKET_PATH) as c:
        sender = c.new_surface(panel_type="terminal")
        panels = {"turnless": c.new_surface(panel_type="terminal"),
                  "control": c.new_surface(panel_type="terminal")}
        for name, panel in [("sender", sender)] + list(panels.items()):
            home = _wait(lambda p=panel: _workspace_of(c, p), 15, f"{name} workspace")
            _wait(lambda p=panel, w=home: _panel_row(c, w, p).get("tty"), 30, f"{name} shell tty")
        time.sleep(1.5)

        for mode, panel in panels.items():
            c._call("panel.set_metadata", {"panel_id": panel, "metadata": {
                "title": f"C11-555 {mode}",
                "mailbox.address": f"c11-555-{mode}",
                "mailbox.delivery": "stdin",
            }})
            c.send_surface(panel, f"python3 {shlex.quote(str(fixture))} --mode {mode} "
                                  f"--log {shlex.quote(str(logs[mode]))} --cli {shlex.quote(cli)}\n")
        c._call("panel.set_metadata", {"panel_id": sender, "metadata": {
            "title": "C11-555 sender", "mailbox.address": "c11-555-sender"}})
        for mode in panels:
            ready = _wait(lambda m=mode: next((r for r in _records(logs[m]) if r.get("event") == "ready"), None),
                          30, f"{mode} fake agent registration")
            stamp(f"{mode} ready: {ready}")
            if ready.get("hook") != 0:
                raise cmuxError(f"{mode} session-start hook failed: {ready}")
        for mode, panel in panels.items():
            c._call("panel.set_metadata", {"panel_id": panel, "metadata": {"terminal_type": "claude-code"}})
        time.sleep(2)

        first = {mode: _send(c, sender, cli, f"c11-555-{mode}", f"first for {mode}", scratch) for mode in panels}
        stamp(f"first mail sent: {first}")
        for mode in panels:
            _wait(lambda m=mode: _rings(logs[m]), 30, f"first ring on {mode}")
        ring1 = {mode: _rings(logs[mode])[0]["t"] for mode in panels}
        stamp(f"first rings at +{ring1['turnless'] - started:.1f}s (turnless), "
              f"+{ring1['control'] - started:.1f}s (control)")

        time.sleep(3)
        second = {mode: _send(c, sender, cli, f"c11-555-{mode}", f"second for {mode}", scratch) for mode in panels}
        stamp(f"second mail sent: {second}")

        deadline = ring1["turnless"] + FLOOR + 25
        _wait(lambda: len(_rings(logs["turnless"])) >= 2, max(1, deadline - time.time()),
              "the second ring on the turn-less panel")
        ring2 = _rings(logs["turnless"])[1]["t"]
        gap = ring2 - ring1["turnless"]
        stamp(f"turn-less second ring {gap:.1f}s after its first")
        if gap < FLOOR - 1:
            raise cmuxError(f"turn-less panel re-rang before the floor: {gap:.1f}s")

        time.sleep(5)
        control_rings = _rings(logs["control"])
        stamp(f"control rings after the floor: {len(control_rings)}")

        for mode in panels:
            for label, ids in (("second", second),):
                trace = _run_in_panel(c, sender, cli, f"mailbox trace {ids[mode]}",
                                      scratch / f"trace-{mode}-{label}.txt")
                print(f"--- trace {mode} {label} {ids[mode]}\n{trace['output']}", flush=True)
            print(f"--- fake log {mode}\n{logs[mode].read_text()}", flush=True)

        if len(control_rings) != 1:
            raise cmuxError(f"control panel was rung {len(control_rings)} times; expected exactly 1")

    print(f"PASS: turn-less panel re-rang new mail {gap:.1f}s after its first ring; "
          "the busy turn-edge control was rung once only", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
