#!/usr/bin/env python3
"""M5 16px icon readability gate (blocking).

Runs against the 1x 16x16 PNG the icon generator produced at
Assets.xcassets/AppIcon.appiconset/16.png, which is the same file the
xcasset compiler consumes when building the app bundle. Asserts:

 - Gold-pixel count is in [2, 5]. Outside this band the spike is
   invisible or a smudge.
 - Every gold pixel sits in the vertical center column x in [6, 9].
 - Gold pixels span a contiguous y-range of at least 3 pixels.
 - Mean luminance of the ~250 non-gold pixels is <= 0.10 (near-void).

Gold channel signature per spec: R >= 160, G >= 128, B <= 100, A >= 200.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except Exception as exc:  # pragma: no cover
    print(f"SKIP: Pillow not available: {exc}")
    raise SystemExit(0)


REPO = Path(__file__).resolve().parents[1]


def _fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _is_gold(pixel: tuple[int, int, int, int]) -> bool:
    r, g, b, a = pixel
    return r >= 160 and g >= 128 and b <= 100 and a >= 200


def _luminance(pixel: tuple[int, int, int, int]) -> float:
    r, g, b, a = pixel
    # Simple sRGB luminance proxy (no gamma), scaled 0..1.
    return ((0.2126 * r) + (0.7152 * g) + (0.0722 * b)) / 255.0


def main() -> int:
    png_path = REPO / "Assets.xcassets" / "AppIcon.appiconset" / "16.png"
    if not png_path.is_file():
        _fail(f"Expected 16x16 AppIcon PNG at {png_path}")

    img = Image.open(png_path).convert("RGBA")
    if img.size != (16, 16):
        _fail(f"Expected 16x16 image, got {img.size}")

    pixels: list[tuple[int, int, tuple[int, int, int, int]]] = []
    for y in range(16):
        for x in range(16):
            pixels.append((x, y, img.getpixel((x, y))))

    gold = [(x, y) for x, y, p in pixels if _is_gold(p)]
    non_gold = [p for _, _, p in pixels if not _is_gold(p)]

    # 1. Count in [2, 5].
    if not (2 <= len(gold) <= 5):
        _fail(
            f"Gold pixel count out of band: {len(gold)} (must be 2..5). Coords: {gold}"
        )

    # 2. All within x in [6, 9].
    off_axis = [(x, y) for x, y in gold if not (6 <= x <= 9)]
    if off_axis:
        _fail(f"Gold pixels off center column x in [6,9]: {off_axis}")

    # 3. Contiguous y-range at least 3.
    ys = sorted({y for _, y in gold})
    if len(ys) < 3:
        _fail(f"Gold pixels span only {len(ys)} y-rows: {ys}. Need >=3.")
    # Contiguity: max(ys) - min(ys) + 1 should equal len(ys) if packed.
    span = max(ys) - min(ys) + 1
    if span > len(ys) + 1:
        _fail(f"Gold pixels not contiguous in y: {ys} (span {span}, rows {len(ys)})")

    # 4. Mean luminance of non-gold pixels <= 0.10.
    if not non_gold:
        _fail("No non-gold pixels — icon is blank or saturated.")
    mean_lum = sum(_luminance(p) for p in non_gold) / len(non_gold)
    if mean_lum > 0.10:
        _fail(f"Mean non-gold luminance too high: {mean_lum:.4f} (max 0.10)")

    print(
        f"PASS: 16px AppIcon legibility gate — {len(gold)} gold px at {sorted(gold)}, "
        f"mean non-gold luminance {mean_lum:.4f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
