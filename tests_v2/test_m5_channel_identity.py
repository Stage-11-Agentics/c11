#!/usr/bin/env python3
"""M5 channel identity — verifies the running bundle reports the right
channel and bundle identifier via `system.brand`.

The channel must be derivable from the bundle identifier suffix:
  com.stage11.c11              -> stable
  com.stage11.c11.debug.<tag>  -> dev
  com.stage11.c11.nightly      -> nightly
  com.stage11.c11.staging      -> staging

Launch contexts (reload.sh --tag / reloads.sh / CI nightly) are not
launched from this test; it asserts whatever instance is currently
listening on the probed socket. If no socket is live, SKIP.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

IDENTIFIER_RE = re.compile(
    r"^com\.stage11\.c11(\.(?P<suffix>debug(\.[A-Za-z0-9_.-]+)?|nightly|staging))?$"
)

EXPECTED_CHANNEL_BY_SUFFIX = {
    None: "stable",
    "nightly": "nightly",
    "staging": "staging",
}


def _skip(msg: str) -> int:
    print(f"SKIP: {msg}")
    return 0


def _fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _expected_channel(identifier: str) -> str | None:
    m = IDENTIFIER_RE.match(identifier)
    if m is None:
        return None
    suffix = m.group("suffix")
    if suffix is None:
        return "stable"
    if suffix.startswith("debug"):
        return "dev"
    return EXPECTED_CHANNEL_BY_SUFFIX.get(suffix)


def main() -> int:
    if not os.path.exists(SOCKET_PATH):
        return _skip(f"cmux socket not available at {SOCKET_PATH}")

    try:
        with cmux(SOCKET_PATH) as client:
            brand = client._call("system.brand") or {}
    except cmuxError as exc:
        return _skip(f"system.brand unreachable: {exc}")

    bundle = (brand.get("bundle") or {}) if isinstance(brand, dict) else {}
    identifier = str(bundle.get("identifier") or "")
    channel = str(brand.get("channel") or "")
    icon_name = str(bundle.get("icon_name") or "")

    if not IDENTIFIER_RE.match(identifier):
        _fail(
            f"CFBundleIdentifier {identifier!r} does not match "
            f"^com.stage11.c11(.debug(.<tag>)?|.nightly|.staging)?$"
        )

    expected = _expected_channel(identifier)
    if channel != expected:
        _fail(
            f"channel mismatch for bundle {identifier}: "
            f"got {channel!r}, expected {expected!r}"
        )

    valid_icons = {"AppIcon", "AppIcon-Debug", "AppIcon-Nightly", "AppIcon-Staging"}
    if icon_name not in valid_icons:
        _fail(f"CFBundleIconName must be one of {sorted(valid_icons)}; got {icon_name!r}")

    display_name = str(bundle.get("display_name") or "")
    if not display_name.startswith("c11"):
        _fail(f"CFBundleDisplayName must start with 'c11'; got {display_name!r}")

    print(
        f"PASS: channel={channel} for bundle={identifier} icon={icon_name} "
        f"display_name={display_name!r}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
