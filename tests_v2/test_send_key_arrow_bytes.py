#!/usr/bin/env python3
"""v0.54.0 BUG 1: `c11 send-key <arrow>` must deliver the correct PTY bytes.

Before the fix, `surface.send_key` only knew ctrl-*, enter, tab, escape and
backspace; every arrow/navigation name returned `invalid_params: Unknown key`.
This test drives a real pane: it runs a tiny raw-mode reader that first resets
DECCKM (normal cursor keys, so arrows encode as CSI and the assertion is
mode-deterministic), reads one key's bytes, and prints them hex-encoded. We
then send each arrow and assert the exact escape sequence reached the PTY.

Run against a live tagged build's socket:
    C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_send_key_arrow_bytes.py
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get("C11_SOCKET", "/tmp/cmux-debug.sock")

# Normal-mode (DECCKM off) cursor-key escape sequences.
ARROW_BYTES = {
    "up": "1b5b41",     # ESC [ A
    "down": "1b5b42",   # ESC [ B
    "right": "1b5b43",  # ESC [ C
    "left": "1b5b44",   # ESC [ D
}

# A reader that forces normal cursor-key mode, prints READY, then reports the
# next key's raw bytes as `GOT:<hex>`. Kept as a one-liner so it pastes cleanly.
READER = (
    "python3 -c \""
    "import sys,os,tty,termios;"
    "sys.stdout.write('\\x1b[?1lREADY\\n');sys.stdout.flush();"
    "fd=sys.stdin.fileno();old=termios.tcgetattr(fd);tty.setraw(fd);"
    "d=os.read(fd,8);"
    "termios.tcsetattr(fd,termios.TCSADRAIN,old);"
    "sys.stdout.write('GOT:'+d.hex()+'\\n');sys.stdout.flush()\""
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_text(c: cmux, ws: str, surface: str, needle: str, timeout_s: float = 6.0) -> str:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        payload = c._call("surface.read_text", {"workspace_id": ws, "surface_id": surface}) or {}
        last = str(payload.get("text") or "")
        if needle in last:
            return last
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r}; last screen:\n{last}")


def test_arrow_keys_emit_csi_bytes(c: cmux) -> None:
    ws = str((c._call("workspace.create") or {}).get("workspace_id") or "")
    _must(bool(ws), "workspace.create returned no workspace_id")
    try:
        time.sleep(0.3)
        surfaces = (c._call("surface.list", {"workspace_id": ws}) or {}).get("surfaces") or []
        _must(bool(surfaces), f"No surfaces in workspace {ws}")
        surface = str(surfaces[0].get("id") or "")
        _must(bool(surface), "surface.list returned surface without id")

        for name, expected_hex in ARROW_BYTES.items():
            # Start a fresh reader for each key so the pane returns to a clean
            # prompt between assertions.
            c._call("surface.send_text", {
                "workspace_id": ws, "surface_id": surface,
                "text": READER + "\n",
            })
            _wait_for_text(c, ws, surface, "READY", timeout_s=8.0)
            # Small settle so the reader is blocked in os.read before the key.
            time.sleep(0.25)

            c._call("surface.send_key", {
                "workspace_id": ws, "surface_id": surface, "key": name,
            })

            screen = _wait_for_text(c, ws, surface, "GOT:", timeout_s=6.0)
            marker = f"GOT:{expected_hex}"
            _must(
                marker in screen,
                f"send-key {name!r} expected {marker!r} on PTY; screen:\n{screen}",
            )
            print(f"PASS: send-key {name} -> {expected_hex}")
            # Let the prompt redraw before the next iteration.
            time.sleep(0.2)
    finally:
        try:
            c.close_workspace(ws)
        except Exception:
            pass

    print("PASS: test_arrow_keys_emit_csi_bytes")


def test_unknown_key_still_rejected(c: cmux) -> None:
    """The error path must stay intact: a bogus key name is rejected."""
    try:
        c.send_key("definitely-not-a-key")
    except cmuxError as exc:
        _must("Unknown key" in str(exc), f"Unexpected error for bad key: {exc}")
        print("PASS: test_unknown_key_still_rejected")
        return
    raise cmuxError("Expected send-key with a bogus name to raise Unknown key")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        test_arrow_keys_emit_csi_bytes(c)
        test_unknown_key_still_rejected(c)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
