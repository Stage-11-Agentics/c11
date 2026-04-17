#!/usr/bin/env python3
"""Generate docs/assets/c11mux-header.png.

720x240 void-surface header. Gold spike on the left, a faint gold rule,
and the word 'c11mux' set in JetBrains Mono Medium at ~80px on the right.
Falls back to a system bold monospace face if JetBrains Mono is not
installed on the build machine — the PNG is a rendered artifact, not a
source-of-truth string, so the visual register matters more than the
exact glyph file.
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "docs", "assets", "c11mux-header.png")

W, H = 720, 240
SURFACE = (10, 10, 10, 255)
GOLD = (201, 168, 76, 255)
GOLD_FAINT = (201, 168, 76, 0x33)
WHITE = (232, 232, 232, 255)


def _load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        os.path.join(REPO, "Resources", "Fonts", "JetBrainsMono-Medium.ttf"),
        os.path.join(REPO, "Resources", "Fonts", "JetBrainsMono-Regular.ttf"),
        "/Library/Fonts/JetBrainsMono-Medium.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def main() -> int:
    img = Image.new("RGBA", (W, H), SURFACE)
    draw = ImageDraw.Draw(img, "RGBA")

    # Gold-faint horizontal rule across the middle band (top + bottom hairlines).
    draw.rectangle((32, 118, W - 32, 119), fill=GOLD_FAINT)
    draw.rectangle((32, 121, W - 32, 122), fill=GOLD_FAINT)

    # Spike icon on the left — same proportions as the 1024 icon, rendered
    # into a 160x160 tile centered vertically.
    tile = 160
    tx, ty = 56, (H - tile) // 2
    # Squircle
    radius = int(round(tile * 228 / 1024))
    draw.rounded_rectangle(
        (tx, ty, tx + tile - 1, ty + tile - 1), radius=radius, fill=(0, 0, 0, 255)
    )
    draw.rounded_rectangle(
        (tx + 2, ty + 2, tx + tile - 3, ty + tile - 3),
        radius=max(1, radius - 2),
        outline=GOLD_FAINT,
        width=1,
    )
    # Spike wedge
    cx = tx + tile / 2
    top_y = ty + tile * 0.20
    bot_y = ty + tile * 0.80
    base_half = tile * 0.04
    tip_half = tile * 0.008
    draw.polygon(
        [
            (cx, top_y),
            (cx + tip_half, top_y + 1),
            (cx + base_half, bot_y),
            (cx - base_half, bot_y),
            (cx - tip_half, top_y + 1),
        ],
        fill=GOLD,
    )

    # Wordmark
    font = _load_font(80)
    text = "c11mux"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    wx = tx + tile + 48 - bbox[0]
    wy = (H - th) // 2 - bbox[1]
    draw.text((wx, wy), text, font=font, fill=WHITE)

    # Gold "." accent trailing the wordmark.
    dot_r = 6
    dot_cx = wx + tw + 24
    dot_cy = wy + th - dot_r
    draw.ellipse(
        (dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r), fill=GOLD
    )

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, "PNG", optimize=True)
    print(f"Wrote {OUT} ({W}x{H})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
