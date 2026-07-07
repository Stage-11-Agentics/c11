#!/usr/bin/env python3
"""C11-165 COR-1: empty/absent surface refs on write commands are rejected
(empty_ref / missing_ref) and never default to the operator-focused surface.

Autonomous verification for EVALUATION row COR-1. Runs against a tagged build's
socket (C11_SOCKET / CMUX_SOCKET). Per C11-165 plan §8.12 this test FAILS (not
skips) when it cannot reach its socket — a vacuous green would hide a regression.

Matrix per v2 write method: empty surface ref -> empty_ref; absent ref ->
missing_ref; and a valid write on a control surface still succeeds AND the
control surface's metadata is unchanged by the rejected calls (no write lands).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def _expect_code(c: cmux, method: str, params: dict, want_code: str) -> None:
    try:
        c._call(method, params)
    except cmuxError as e:
        got = str(e).split(":", 1)[0].strip()
        _must(got == want_code,
              f"{method} {params}: expected {want_code}, got '{got}' ({e})")
        return
    raise AssertionError(f"{method} {params}: expected {want_code}, but call succeeded")


def main() -> int:
    sock = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET")
    if not sock or not os.path.exists(sock):
        # FAIL, do not skip (plan §8.12): a missing socket must not read green.
        print(f"FAIL: no reachable c11 socket (C11_SOCKET/CMUX_SOCKET={sock!r})")
        return 1

    c = cmux(socket_path=sock)
    c.connect()

    # Control surface with a known baseline write (positive control).
    surface_id = c.new_surface()
    c._call("surface.set_metadata",
            {"surface_id": surface_id, "metadata": {"role": "cor1-control"}})
    before = c._call("surface.get_metadata", {"surface_id": surface_id}) or {}
    baseline_role = (before.get("metadata") or {}).get("role")
    _must(baseline_role == "cor1-control", f"baseline write failed: {before}")

    # --- v2 write matrix: empty_ref (present-but-empty) + missing_ref (absent) ---
    cases = [
        ("surface.set_metadata", {"metadata": {"role": "STOMP"}}, "surface_id"),
        ("surface.clear_metadata", {"keys": ["role"]}, "surface_id"),
        ("surface.trigger_flash", {}, "surface_id"),
        ("pane.set_metadata", {"metadata": {"role": "STOMP"}}, "pane_id"),
        ("pane.clear_metadata", {"keys": ["role"]}, "pane_id"),
        ("surface.action", {"action": "rename", "title": "STOMP"}, "surface_id"),
    ]
    for method, base, pin in cases:
        _expect_code(c, method, {**base, pin: ""}, "empty_ref")      # present-but-empty
        _expect_code(c, method, {**base, pin: "   "}, "empty_ref")   # whitespace
        _expect_code(c, method, dict(base), "missing_ref")           # absent

    # A coarser workspace-only ref must NOT satisfy a surface-pinned write.
    ws = c._call("workspace.current") or {}
    ws_id = ws.get("workspace_id")
    if ws_id:
        _expect_code(c, "surface.set_metadata",
                     {"workspace_id": ws_id, "metadata": {"role": "STOMP"}}, "missing_ref")

    # No rejected call may have landed on the control surface.
    after = c._call("surface.get_metadata", {"surface_id": surface_id}) or {}
    _must((after.get("metadata") or {}).get("role") == "cor1-control",
          f"a rejected write mutated the control surface: {after}")

    # Positive control: a valid explicit write still succeeds.
    c._call("surface.set_metadata",
            {"surface_id": surface_id, "metadata": {"role": "cor1-ok"}})
    final = c._call("surface.get_metadata", {"surface_id": surface_id}) or {}
    _must((final.get("metadata") or {}).get("role") == "cor1-ok",
          f"valid explicit write did not land: {final}")

    print("PASS: COR-1 empty/absent surface-ref rejection matrix")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as e:
        print(f"FAIL: {e}")
        sys.exit(1)
