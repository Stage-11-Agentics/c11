#!/usr/bin/env python3
"""M5 built-bundle artifact assertions.

Reads the Debug build's .app bundle produced by `./scripts/reload.sh
--tag <tag>` (or CI equivalent). No source-tree reads. Assertions:

 1. CFBundleIdentifier matches the channel-suffix regex.
 2. CFBundleDisplayName starts with 'c11'.
 3. CFBundleIconName in {AppIcon, AppIcon-Debug, AppIcon-Nightly,
    AppIcon-Staging}.
 4. CFBundleShortVersionString matches ^\\d+\\.\\d+\\.\\d+$.
 5. Compiled asset catalog (Assets.car) contains icon renditions for
    the CFBundleIconName at sizes 16, 32, 128, 256, 512 at both 1x and
    2x (rendition pixel sizes 16, 32, 64, 128, 256, 512, 1024).

The 16px readability gate lives in its own test file
(`test_m5_icon_16px_render.py`) and runs against the stable
`Assets.xcassets/AppIcon.appiconset/16.png` — the channel-banner'd
variants (AppIcon-Debug/Nightly/Staging) intentionally overlay more
pixels for channel differentiation, so the raw spike gate is checked
against the stable asset only.
"""

from __future__ import annotations

import glob
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

IDENTIFIER_RE = re.compile(
    r"^com\.stage11\.c11(\.(debug(\.[A-Za-z0-9_.-]+)?|nightly|staging))?$"
)
VALID_ICON_NAMES = {"AppIcon", "AppIcon-Debug", "AppIcon-Nightly", "AppIcon-Staging"}
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")

EXPECTED_RENDITION_SIZES = {16, 32, 64, 128, 256, 512, 1024}


def _skip(msg: str) -> int:
    print(f"SKIP: {msg}")
    return 0


def _fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _find_app_bundle() -> Path | None:
    """Locate a built c11 .app bundle. Prefer tagged debug builds in
    /tmp/c11-*, then DerivedData."""
    env_override = os.environ.get("CMUX_APP_BUNDLE")
    if env_override and Path(env_override).is_dir():
        return Path(env_override)

    candidates: list[Path] = []
    patterns = [
        "/tmp/c11-*/Build/Products/Debug/c11*.app",
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/c11-*/Build/Products/Debug/c11*.app"),
    ]
    for pat in patterns:
        for p in glob.glob(pat):
            path = Path(p)
            if path.is_dir() and (path / "Contents" / "Info.plist").is_file():
                candidates.append(path)

    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def _read_plist(path: Path) -> dict:
    with path.open("rb") as f:
        return plistlib.load(f)


def _asset_renditions(assets_car: Path, icon_name: str) -> list[dict]:
    try:
        raw = subprocess.check_output(
            ["assetutil", "--info", str(assets_car)], stderr=subprocess.DEVNULL
        )
    except FileNotFoundError:
        raise RuntimeError("assetutil not available (requires Xcode command-line tools)")
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"assetutil failed: {exc}")
    data = json.loads(raw)
    return [d for d in data if d.get("Name") == icon_name and d.get("AssetType") == "Icon Image"]


def main() -> int:
    app = _find_app_bundle()
    if app is None:
        return _skip(
            "No c11 .app bundle found in /tmp/c11-*/ or DerivedData. "
            "Build with ./scripts/reload.sh --tag <tag> first."
        )

    info_plist = app / "Contents" / "Info.plist"
    plist = _read_plist(info_plist)

    identifier = str(plist.get("CFBundleIdentifier") or "")
    display_name = str(plist.get("CFBundleDisplayName") or "")
    icon_name = str(plist.get("CFBundleIconName") or "")
    short_version = str(plist.get("CFBundleShortVersionString") or "")

    if not IDENTIFIER_RE.match(identifier):
        _fail(
            f"CFBundleIdentifier {identifier!r} does not match "
            f"^com.stage11.c11(.debug(.<tag>)?|.nightly|.staging)?$"
        )
    if not display_name.startswith("c11"):
        _fail(f"CFBundleDisplayName must start with 'c11'; got {display_name!r}")
    if icon_name not in VALID_ICON_NAMES:
        _fail(f"CFBundleIconName must be in {sorted(VALID_ICON_NAMES)}; got {icon_name!r}")
    if not VERSION_RE.match(short_version):
        _fail(
            f"CFBundleShortVersionString {short_version!r} does not match ^\\d+\\.\\d+\\.\\d+$"
        )

    assets_car = app / "Contents" / "Resources" / "Assets.car"
    if not assets_car.is_file():
        _fail(f"Assets.car missing at {assets_car}")

    try:
        renditions = _asset_renditions(assets_car, icon_name)
    except RuntimeError as exc:
        return _skip(str(exc))

    if not renditions:
        _fail(f"No icon renditions for {icon_name} in {assets_car}")

    pixel_sizes = {int(r.get("PixelWidth") or 0) for r in renditions}
    missing = EXPECTED_RENDITION_SIZES - pixel_sizes
    if missing:
        _fail(
            f"Asset catalog missing pixel sizes for {icon_name}: {sorted(missing)} "
            f"(present: {sorted(pixel_sizes)})"
        )

    print(
        f"PASS: built-bundle artifacts — {app.name} "
        f"id={identifier} icon={icon_name} short_version={short_version} "
        f"renditions={sorted(pixel_sizes)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
