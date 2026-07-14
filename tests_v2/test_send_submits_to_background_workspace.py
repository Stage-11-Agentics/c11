#!/usr/bin/env python3
"""C11-173: `c11 send` must actually submit — including into a background workspace.

The defect this pins: `send` typed the payload with synthetic key events and then
submitted with a synthesized `NSEvent` Return. NSEvent synthesis needs a window,
and a pane in a *non-selected* workspace is portal-detached (no window), so the
Return was silently dropped. `send` returned OK, the text sat in the composer,
and a fleet of background agents looked briefed while none had received anything.

Multi-line payloads failed a second way: each embedded newline became a Return
key event, so the payload fragmented into one submission per line.

Run against a live tagged build's socket:
    C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_send_submits_to_background_workspace.py
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


def _wait_for(c: cmux, ws: str, surface: str, needle: str, timeout_s: float = 8.0) -> str:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        last = _screen(c, ws, surface)
        if needle in last:
            return last
        time.sleep(0.15)
    raise cmuxError(f"Timed out waiting for {needle!r}; last screen:\n{last}")


def _new_shell_workspace(c: cmux) -> tuple[str, str]:
    ws = str((c._call("workspace.create") or {}).get("workspace_id") or "")
    _must(bool(ws), "workspace.create returned no workspace_id")
    time.sleep(0.4)
    surfaces = (c._call("surface.list", {"workspace_id": ws}) or {}).get("surfaces") or []
    _must(bool(surfaces), f"No surfaces in workspace {ws}")
    surface = str(surfaces[0].get("id") or "")
    _must(bool(surface), "surface.list returned surface without id")
    return ws, surface


def _select(c: cmux, ws: str) -> None:
    c._call("workspace.select", {"workspace_id": ws})
    time.sleep(0.5)


def test_send_submits_into_a_background_workspace(c: cmux) -> None:
    """The fleet case: the target agent's workspace is not the one on screen."""
    target_ws, target_surface = _new_shell_workspace(c)
    other_ws, _ = _new_shell_workspace(c)
    try:
        # Put the *other* workspace on screen so the target is portal-detached.
        _select(c, other_ws)

        c._call("surface.send_text", {
            "workspace_id": target_ws, "surface_id": target_surface,
            "text": "expr 41000 + 1", "submit": True,
        })
        # 41001 never appears in the typed source: seeing it proves a Return landed.
        _wait_for(c, target_ws, target_surface, "41001")
        print("PASS: send submitted into a background (non-selected) workspace")
    finally:
        for ws in (target_ws, other_ws):
            try:
                c.close_workspace(ws)
            except Exception:
                pass


def test_multiline_payload_does_not_submit_line_by_line(c: cmux) -> None:
    """An embedded newline is payload content, not a submit.

    `send` used to type the payload as synthetic key events, turning every
    embedded `\\n` into a Return — so a multi-line brief fragmented into one
    submission per line (in Claude Code: one turn per line). Delivered as a
    paste, the whole payload lands in the composer and nothing runs until the
    submit Return arrives.

    `expr` is the probe: its *result* appears on screen only if that line was
    actually submitted, and never appears in the typed source.
    """
    ws, surface = _new_shell_workspace(c)
    other_ws, _ = _new_shell_workspace(c)
    try:
        _select(c, other_ws)  # target is in the background, as agents are
        c._call("surface.send_text", {
            "workspace_id": ws, "surface_id": surface,
            "text": "expr 20000 + 1\nexpr 30000 + 1", "submit": False,
        })
        # Both lines must sit in the composer, unexecuted.
        _wait_for(c, ws, surface, "expr 30000 + 1")
        time.sleep(1.0)
        screen = _screen(c, ws, surface)
        _must(
            "20001" not in screen,
            f"First line executed on its own: the embedded newline acted as a submit.\n{screen}",
        )

        # One explicit Return submits the payload the caller actually sent.
        c._call("surface.send_key", {"workspace_id": ws, "surface_id": surface, "key": "enter"})
        screen = _wait_for(c, ws, surface, "30001")
        _must("20001" in screen, f"First line of the payload was lost:\n{screen}")
        print("PASS: multi-line payload stayed whole; one Return submitted it")
    finally:
        for w in (ws, other_ws):
            try:
                c.close_workspace(w)
            except Exception:
                pass


def test_send_key_space_writes_a_space(c: cmux) -> None:
    """`send-key space` was a silent no-op: keycode-only printable keys encode to
    zero bytes in Ghostty's legacy encoder."""
    ws, surface = _new_shell_workspace(c)
    try:
        c._call("surface.send_text", {
            "workspace_id": ws, "surface_id": surface,
            "text": "echo SPACE", "submit": False,
        })
        _wait_for(c, ws, surface, "echo SPACE")
        c._call("surface.send_key", {"workspace_id": ws, "surface_id": surface, "key": "space"})
        time.sleep(0.4)
        c._call("surface.send_text", {
            "workspace_id": ws, "surface_id": surface,
            "text": "KEY_OK", "submit": True,
        })
        # "echo SPACE KEY_OK" prints "SPACE KEY_OK"; without the space the shell
        # would echo "SPACEKEY_OK" instead.
        _wait_for(c, ws, surface, "SPACE KEY_OK")
        print("PASS: send-key space emitted a space")
    finally:
        try:
            c.close_workspace(ws)
        except Exception:
            pass


def test_unresolvable_surface_ref_errors_instead_of_hitting_the_focused_pane(c: cmux) -> None:
    """A stale ref used to fall back to `ws.focusedPanelId` — the payload landed in
    whatever pane happened to be focused, usually the caller's own."""
    ws, surface = _new_shell_workspace(c)
    try:
        _select(c, ws)
        errored = False
        try:
            c._call("surface.send_text", {
                "workspace_id": ws, "surface_id": "surface:99999",
                "text": "echo STALE_REF_MISROUTE", "submit": True,
            })
        except Exception:
            errored = True
        _must(errored, "send_text with an unresolvable surface ref should error, not fall back")
        time.sleep(1.0)
        screen = _screen(c, ws, surface)
        _must(
            "STALE_REF_MISROUTE" not in screen,
            f"Stale ref was misrouted into the focused pane:\n{screen}",
        )

        # Same for an empty ref.
        errored = False
        try:
            c._call("surface.send_text", {
                "workspace_id": ws, "surface_id": "",
                "text": "echo EMPTY_REF_MISROUTE", "submit": True,
            })
        except Exception:
            errored = True
        _must(errored, "send_text with an empty surface_id should error, not fall back")
        time.sleep(1.0)
        screen = _screen(c, ws, surface)
        _must(
            "EMPTY_REF_MISROUTE" not in screen,
            f"Empty ref was misrouted into the focused pane:\n{screen}",
        )
        print("PASS: empty and stale surface refs error instead of misrouting")
    finally:
        try:
            c.close_workspace(ws)
        except Exception:
            pass


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        test_send_submits_into_a_background_workspace(c)
        test_multiline_payload_does_not_submit_line_by_line(c)
        test_send_key_space_writes_a_space(c)
        test_unresolvable_surface_ref_errors_instead_of_hitting_the_focused_pane(c)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
