#!/usr/bin/env python3
"""v0.54.0 BUG 2: `c11 send` must deliver a separate, post-text submit Return.

`c11 send` types the text AND submits it. The text carries no embedded newline,
so the command can only run if a distinct Return key event is delivered *after*
the text. We assert that by sending an `expr` whose result does not appear in
the typed source: if the result shows up, a separate Return fired and submitted
the line. The mirror case (`--no-submit`) must leave the text unsubmitted until
an explicit `send-key enter` arrives.

Run against a live tagged build's socket:
    C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_send_submit_delivers_return.py
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get("C11_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _screen(c: cmux, ws: str, surface: str) -> str:
    payload = c._call("surface.read_text", {"workspace_id": ws, "surface_id": surface}) or {}
    return str(payload.get("text") or "")


def _wait_for(c: cmux, ws: str, surface: str, needle: str, timeout_s: float = 6.0) -> str:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        last = _screen(c, ws, surface)
        if needle in last:
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r}; last screen:\n{last}")


def _absent_after(c: cmux, ws: str, surface: str, needle: str, window_s: float = 1.5) -> None:
    deadline = time.time() + window_s
    while time.time() < deadline:
        if needle in _screen(c, ws, surface):
            raise cmuxError(f"{needle!r} appeared but should not have (premature submit)")
        time.sleep(0.1)


def _new_shell_surface(c: cmux) -> tuple[str, str]:
    ws = str((c._call("workspace.create") or {}).get("workspace_id") or "")
    _must(bool(ws), "workspace.create returned no workspace_id")
    time.sleep(0.3)
    surfaces = (c._call("surface.list", {"workspace_id": ws}) or {}).get("surfaces") or []
    _must(bool(surfaces), f"No surfaces in workspace {ws}")
    surface = str(surfaces[0].get("id") or "")
    _must(bool(surface), "surface.list returned surface without id")
    return ws, surface


def test_send_with_submit_executes_via_separate_return(c: cmux) -> None:
    ws, surface = _new_shell_surface(c)
    try:
        # Result (62675) never appears in the typed source text.
        c._call("surface.send_text", {
            "workspace_id": ws, "surface_id": surface,
            "text": "expr 62674 + 1", "submit": True,
        })
        _wait_for(c, ws, surface, "62675", timeout_s=6.0)
        print("PASS: send with submit delivered a separate post-text Return")
    finally:
        try:
            c.close_workspace(ws)
        except Exception:
            pass


def test_no_submit_holds_text_until_explicit_enter(c: cmux) -> None:
    ws, surface = _new_shell_surface(c)
    try:
        c._call("surface.send_text", {
            "workspace_id": ws, "surface_id": surface,
            "text": "expr 73736 + 1", "submit": False,
        })
        # The typed text must land in the composer/prompt...
        _wait_for(c, ws, surface, "expr 73736 + 1", timeout_s=6.0)
        # ...but must NOT execute (no result) without a Return.
        _absent_after(c, ws, surface, "73737", window_s=1.5)
        # An explicit send-key enter then submits it.
        c._call("surface.send_key", {"workspace_id": ws, "surface_id": surface, "key": "enter"})
        _wait_for(c, ws, surface, "73737", timeout_s=6.0)
        print("PASS: --no-submit held the line; explicit enter submitted it")
    finally:
        try:
            c.close_workspace(ws)
        except Exception:
            pass


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        test_send_with_submit_executes_via_separate_return(c)
        test_no_submit_holds_text_until_explicit_enter(c)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
