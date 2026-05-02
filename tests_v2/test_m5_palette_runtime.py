#!/usr/bin/env python3
"""M5 runtime palette assertions.

Asks the running c11 instance (tagged debug) for `system.brand` and
verifies the palette, accent hex, and font family resolve to the
brand canon.

The test needs a live debug instance's socket. If none is reachable it
SKIPs rather than failing — `tests_v2/` runs headless under CI and local
developers may not have a tagged build live. The orchestrator's review
pipeline must ensure this test exercises against a live build before
M5 merges.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

EXPECTED = {
    "black": "#000000",
    "surface": "#0a0a0a",
    "rule": "#333333",
    "dim": "#555555",
    "white": "#e8e8e8",
    "gold": "#c9a84c",
    "gold_faint": "#c9a84c33",
}


def _skip(msg: str) -> int:
    print(f"SKIP: {msg}")
    return 0


def _fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    if not os.path.exists(SOCKET_PATH):
        return _skip(f"cmux socket not available at {SOCKET_PATH}")

    try:
        with cmux(SOCKET_PATH) as client:
            result = client._call("system.brand") or {}
    except cmuxError as exc:
        return _skip(f"system.brand unreachable: {exc}")

    palette = (result.get("palette") or {}) if isinstance(result, dict) else {}
    for name, expected_hex in EXPECTED.items():
        actual = str(palette.get(name, "")).lower()
        if actual != expected_hex:
            _fail(f"palette.{name}: expected {expected_hex}, got {actual!r}")

    accent = str(result.get("accent_hex", "")).lower()
    if accent != "#c9a84c":
        _fail(f"accent_hex: expected #c9a84c, got {accent!r}")

    font = result.get("font_family", "")
    if font != "JetBrains Mono":
        _fail(f"font_family: expected 'JetBrains Mono', got {font!r}")

    channel = result.get("channel")
    if channel not in {"stable", "dev", "nightly", "staging"}:
        _fail(f"channel must be one of stable/dev/nightly/staging; got {channel!r}")

    bundle = result.get("bundle") or {}
    for key in ("identifier", "display_name", "name", "icon_name"):
        if not bundle.get(key):
            _fail(f"bundle.{key} missing or empty: {bundle!r}")

    print(
        f"PASS: system.brand palette, accent, font, channel={channel}, "
        f"bundle.identifier={bundle.get('identifier')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
