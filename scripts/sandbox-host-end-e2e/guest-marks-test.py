#!/usr/bin/env python3
"""Fixture tests for guest.py's marks collector (mode=marks, C11H-321).

Runs the real `marks_collect` against an in-memory resumed guest on a fake
clock: no app, socket, subprocess or guest. A valid run passes every check;
each broken observation fails the one check that names it.

    python3 scripts/sandbox-host-end-e2e/guest-marks-test.py
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))


def load_guest():
    spec = importlib.util.spec_from_file_location("c11h321_guest", os.path.join(HERE, "guest.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROLES = [("expired", False), ("warm", True), ("expired", True), ("warm", False), ("none", False), ("expired", False)]
OPENCODE = "OPENCODE-PANEL"


class FakeGuest:
    """Six resumed stubs and the ended opencode panel, drawn as the fixed app draws them. Warm caches expire at
    exactly seeded + TTL (the harness seeds on a whole second)."""

    def __init__(self, guest, variant):
        self.g, self.variant = guest, variant
        self.t = 1_000_000.0
        self.launched = self.t
        self.seeded = self.t - 60
        self.cold_at = self.seeded + guest.MARKS_TTL
        self.panels = [{"panel": f"P{i}", "workspace": "W", "conversation": f"conv-{i}", "cwd": "/w", "visible": i < 2,
                        "role": role, "start_idle": idle} for i, (role, idle) in enumerate(ROLES)]
        self.resume_at = {p["panel"]: self.launched + 5 + 1.5 * i for i, p in enumerate(self.panels)}
        self.probe = {"state": None, "at": None}

    def sleep(self, seconds):
        self.t += seconds

    def lifecycle(self, p):
        t, started = self.t, self.resume_at[p["panel"]]
        if t < started:
            return "idle"
        if p["panel"] == "P0" and self.probe["state"] == "working":
            return "working"
        if p["panel"] == "P0" and self.probe["state"] == "idle":
            return "cold" if t >= self.probe["at"] + 4 else "idle"
        if p["role"] == "expired":
            return "cold" if t >= started + 5 else "working"
        rest = started if p["start_idle"] else started + 120
        if t < rest:
            return "working"
        if p["role"] == "warm" and t >= self.cold_at:
            return "cold"
        return "idle"

    def ended(self):
        """hc reports the opencode terminal ended a moment after the launch (never, when unresolved)."""
        return self.variant != "unresolved" and self.t >= self.launched + 1

    def opencode_lifecycle(self):
        if self.variant == "missing":
            return None
        if self.variant == "working" or not self.ended():
            return "working"  # the working it was restored with, until hc reports the end
        if self.variant == "lateworking" and self.launched + 60 <= self.t < self.launched + 64:
            return "working"
        return "idle"

    def fleet_rows(self, meta):
        rows = {p["panel"]: {"lifecycle": self.lifecycle(p), "prompt_cache": {"state": "cold"}} for p in self.panels}
        lifecycle = self.opencode_lifecycle()
        if lifecycle is not None:
            rows[OPENCODE] = {"lifecycle": lifecycle}
        return rows

    def hc_diag(self, meta, check=False):
        rows = [{"panel_id": p["panel"], "lifecycle": "live"} for p in self.panels]
        if self.variant != "nodiag":
            rows.append({"panel_id": OPENCODE, "lifecycle": "ended" if self.ended() else "unresolved"})
        return {"panels": rows}

    def ledger(self):
        rows = []
        for p in self.panels:
            conversation = p["conversation"]
            if self.variant == "wrongresume" and p["panel"] == "P3":
                conversation = "conv-someone-else"
            if self.t >= self.resume_at[p["panel"]]:
                rows.append({"event": "start", "ts": self.resume_at[p["panel"]], "panel": p["panel"],
                             "argv": ["--settings", "x", "--resume", conversation]})
        return rows

    def send_text(self, meta, p, text, budget=20):
        assert p["panel"] == "P0", p
        self.probe = {"state": "working" if text.endswith("WORK") else "idle", "at": self.t}

    def install(self, state_dir):
        g = self.g
        g.STATE = state_dir
        g.save("meta.json", {"cli": "c11", "socket": "/dev/null"})
        g.save("panels.json", self.panels)
        g.save("marks.json", {"seeded_at": self.seeded, "opencode": {"panel": OPENCODE, "workspace": "W2"}})
        g.save("marks-persisted.json", {"panel": True, "activity": "working"})
        g.save("relaunch.json", {"launched_at": self.launched})
        g.now = lambda: self.t
        g.time = types.SimpleNamespace(sleep=self.sleep, time=lambda: self.t)
        g.fleet_rows = self.fleet_rows
        g.hc_diag = self.hc_diag
        g.ledger = self.ledger
        g.send_text = self.send_text
        g.shot = lambda name: None


def run(variant):
    guest = load_guest()
    fake = FakeGuest(guest, variant)
    with tempfile.TemporaryDirectory() as state:
        fake.install(state)
        with contextlib.redirect_stdout(io.StringIO()):
            guest.marks_collect([])
        return guest.load("summary.json")


CASES = {
    "ok": [],                                         # restored working only until hc reports the end
    "missing": ["ended_opencode_never_working"],      # the opencode panel never in fleet
    "nodiag": ["ended_opencode_never_working"],       # hc diagnostics do not list it
    "unresolved": ["ended_opencode_never_working"],   # reconnecting, never reported ended
    "working": ["ended_opencode_never_working"],      # the 2026-11-15 phantom working
    "lateworking": ["ended_opencode_never_working"],  # working again after the end was reported
    "wrongresume": ["resumed_every_stub"],            # a stub resumed with another conversation
}


def main():
    failures = []
    for variant, expected in CASES.items():
        summary = run(variant)
        if summary["failed"] != expected:
            failures.append(f"{variant}: expected failed={expected}, got {summary['failed']}")
        print(f"{'ok  ' if summary['failed'] == expected else 'FAIL'} {variant}: failed={summary['failed']}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
