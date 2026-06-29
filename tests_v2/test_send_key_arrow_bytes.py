#!/usr/bin/env python3
"""v0.54.0 BUG 1: `c11 send-key <arrow>` must deliver the correct PTY bytes.

Before the fix, `surface.send_key` only knew ctrl-*, enter, tab, escape and
backspace; every arrow/navigation name returned `invalid_params: Unknown key`.
This test drives a real pane: it runs a one-read raw reader that first resets
DECCKM (normal cursor keys, so arrows encode as CSI and the assertion is
mode-deterministic), reads one key's bytes via a single `dd` read syscall, and
prints them hex-encoded with `xxd`. We then send each arrow and assert the exact
escape sequence reached the PTY.

Run against a live tagged build's socket:
    C11_SOCKET=/tmp/c11-debug-<tag>.sock python3 tests_v2/test_send_key_arrow_bytes.py
"""

from __future__ import annotations

import os
import re
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

# Reader: force DECCKM-normal so arrows encode as CSI, print a readiness marker
# (split so the literal "RDYMARK" never appears in the source text we type —
# otherwise the readiness poll would match the unexecuted command echo), then do
# exactly one raw read and hex-dump it. `dd bs=16 count=1` is one read syscall,
# so it returns the whole escape sequence in a single chunk.
READER = (
    r"printf '\033[?1l'; printf 'RDY''MARK\n'; "
    r"stty raw -echo 2>/dev/null; dd bs=16 count=1 2>/dev/null | xxd -p; "
    r"stty sane 2>/dev/null"
)
READY_MARKER = "RDYMARK"


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
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r}; last screen:\n{last}")


def _captured_esc_hex(screen: str) -> str | None:
    """Return the CSI-looking hex token (starts with 1b) printed after the most
    recent readiness marker, so a prior iteration's capture can't leak in."""
    idx = screen.rfind(READY_MARKER)
    region = screen[idx:] if idx >= 0 else screen
    found = None
    for m in re.finditer(r"\b([0-9a-f]{4,})\b", region):
        if m.group(1).startswith("1b"):
            found = m.group(1)
    return found


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
            # Launch the reader with submit:False — the text carries its own
            # trailing newline to run, so we must NOT also dispatch the deferred
            # submit Return (that stray Return would be the byte the reader
            # captures instead of the arrow under test).
            c._call("surface.send_text", {
                "workspace_id": ws, "surface_id": surface,
                "text": READER + "\n", "submit": False,
            })
            _wait_for(c, ws, surface, READY_MARKER, timeout_s=8.0)
            # Small settle so the reader has entered its raw read before the key.
            time.sleep(0.4)

            c._call("surface.send_key", {
                "workspace_id": ws, "surface_id": surface, "key": name,
            })

            got = None
            deadline = time.time() + 6.0
            while time.time() < deadline:
                got = _captured_esc_hex(_screen(c, ws, surface))
                if got:
                    break
                time.sleep(0.1)
            _must(
                got == expected_hex,
                f"send-key {name!r} expected PTY bytes {expected_hex}, got {got!r}",
            )
            print(f"PASS: send-key {name} -> {expected_hex}")
            time.sleep(0.3)
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
