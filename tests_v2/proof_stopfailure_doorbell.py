#!/usr/bin/env python3
"""v2 guest proof (C11H-237): a Claude seat whose turn ends in an API error
(StopFailure) is rung for the mail that waited through that turn.

One fake Claude agent (`fixture_turnless_agent.py --mode stopfailure`) holds a
raw-mode Claude-style composer, registers through the real `claude-hook
session-start`, and runs the real `claude-hook` for each command the proof
writes to its control file. The sequence is the incident's: prompt-submit,
prompt-submit, mail arrives (held), stop-failure (rung within the normal ring
delay). The ring's own Return is the next prompt-submit, so mail after it is
held again until the next StopFailure rings it. While mail is held,
`mailbox status` and `fleet --json` name the open journal turn.

A local panel only: a guest has no linked machine. The remote route is covered
by the logic tests (StopFailureDoorbellTests). Live socket test: run only in a
sandbox guest (scripts/sandbox-tests-v2.sh tests_v2/proof_stopfailure_doorbell.py).
About a minute. Named proof_ so the default tests_v2 sweep skips it.
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
from proof_turnless_doorbell import DOORBELL, _panel_row, _records, _rings, _run_in_panel, _send, _wait, _workspace_of

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
RING_DELAY = 10  # the focused-panel quiet window is 3 s; an unfocused ring is immediate
HOLD = 6


def main() -> int:
    cli = find_cli_binary()
    fixture = Path(__file__).parent / "fixture_turnless_agent.py"
    scratch = Path(tempfile.mkdtemp(prefix="c11-237-"))
    log, control = scratch / "agent.jsonl", scratch / "control.txt"
    started = time.time()
    result = {"checks": {}}

    def stamp(message: str) -> None:
        print(f"[{time.time() - started:6.1f}s] {message}", flush=True)

    def check(name: str, ok: bool, **detail) -> None:
        result["checks"][name] = {"pass": bool(ok), **detail}
        stamp(f"{'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:500]}")

    def command(*words: str) -> None:
        with open(control, "a", encoding="utf-8") as handle:
            handle.write(" ".join(words) + "\n")
        want = len([w for w in control.read_text().splitlines() if w.strip()])
        _wait(lambda: len([r for r in _records(log) if r.get("event") == "hook"]) >= want, 15, " ".join(words))

    def cli_out(sender: str, args: str, name: str) -> str:
        return _run_in_panel(c, sender, cli, args, scratch / name)["output"]

    with cmux(SOCKET_PATH) as c:
        sender = c.new_surface(panel_type="terminal")
        agent = c.new_surface(panel_type="terminal")
        for name, panel in (("sender", sender), ("agent", agent)):
            home = _wait(lambda p=panel: _workspace_of(c, p), 15, f"{name} workspace")
            _wait(lambda p=panel, w=home: _panel_row(c, w, p).get("tty"), 30, f"{name} shell tty")
        time.sleep(1.5)
        c._call("panel.set_metadata", {"panel_id": agent, "metadata": {
            "title": "C11H-237 agent", "mailbox.address": "c11-237-agent", "mailbox.delivery": "stdin"}})
        c._call("panel.set_metadata", {"panel_id": sender, "metadata": {
            "title": "C11H-237 sender", "mailbox.address": "c11-237-sender"}})
        c.send_surface(agent, f"python3 {shlex.quote(str(fixture))} --mode stopfailure --log {shlex.quote(str(log))} "
                              f"--cli {shlex.quote(cli)} --control {shlex.quote(str(control))} --max-seconds 240\n")
        ready = _wait(lambda: next((r for r in _records(log) if r.get("event") == "ready"), None), 30, "agent ready")
        if ready.get("hook") != 0:
            raise cmuxError(f"session-start hook failed: {ready}")
        c._call("panel.set_metadata", {"panel_id": agent, "metadata": {"terminal_type": "claude-code"}})
        time.sleep(2)

        # The incident's turn: two prompt submits, mail arrives, nothing rings.
        command("prompt-submit", "p1")
        command("prompt-submit", "p2")
        first = _send(c, sender, cli, "c11-237-agent", "first, during the turn", scratch)
        time.sleep(HOLD)
        check("held_during_turn", not _rings(log), rings=len(_rings(log)))
        status_text = cli_out(sender, f"mailbox status {first}", "status-held.txt")
        status_json = json.loads(cli_out(sender, f"--json mailbox status {first}", "status-held.json"))
        row = (status_json.get("recipients") or [{}])[0]
        check("status_names_the_open_turn",
              "pending" in status_text and "the agent's journal shows a turn open since" in status_text
              and row.get("wait_reason") == "journal_turn" and isinstance(row.get("pending_seconds"), int)
              and "body" not in row,
              text=status_text.strip().splitlines()[-3:], wait_reason=row.get("wait_reason"),
              pending_seconds=row.get("pending_seconds"))
        fleet = json.loads(cli_out(sender, "--json fleet", "fleet.json"))
        unread = next((p.get("mailbox_unread") for p in fleet.get("panels", [])
                       if str(p.get("panel_id", "")).upper() == agent.upper()), None)
        check("fleet_names_the_open_turn", bool(unread) and unread.get("reason") == "journal_turn"
              and str(unread.get("reason_text", "")).startswith("the agent's journal shows a turn open"), unread=unread)

        # The turn ends in an API error: the waiting mail rings within the normal delay.
        failed_at = time.time()
        command("stop-failure", "p2")
        try:
            _wait(lambda: _rings(log), RING_DELAY, "the ring after the StopFailure")
        except cmuxError:
            pass
        rings = _rings(log)
        check("rung_after_stopfailure", len(rings) == 1,
              rings=len(rings), latency_s=round(rings[0]["t"] - failed_at, 2) if rings else None)

        # The ring's Return is the next prompt-submit: new mail is held again.
        second = _send(c, sender, cli, "c11-237-agent", "second, during the next turn", scratch)
        time.sleep(HOLD)
        check("next_turn_holds", len(_rings(log)) == 1, rings=len(_rings(log)))
        failed_again = time.time()
        command("stop-failure", "r1")
        try:
            _wait(lambda: len(_rings(log)) >= 2, RING_DELAY, "the second ring")
        except cmuxError:
            pass
        rings = _rings(log)
        check("next_stopfailure_rings_once", len(rings) == 2,
              rings=len(rings), latency_s=round(rings[1]["t"] - failed_again, 2) if len(rings) > 1 else None)

        for envelope in (first, second):
            print(f"--- trace {envelope}\n" + cli_out(sender, f"mailbox trace {envelope}", f"trace-{envelope}.txt"),
                  flush=True)
        print(f"--- agent log\n{log.read_text()}", flush=True)
        c.send_key_surface(agent, "ctrl+c") if hasattr(c, "send_key_surface") else None

    failed = [k for k, v in result["checks"].items() if not v["pass"]]
    print("C11H237-RESULT " + json.dumps({"result": "fail" if failed else "pass", "failed": failed, **result}),
          flush=True)
    if failed:
        raise cmuxError(f"failed: {failed}")
    print("PASS: a StopFailure rings the mail that waited through the turn; the next turn holds again", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
