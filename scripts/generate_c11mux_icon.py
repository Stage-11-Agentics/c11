#!/usr/bin/env python3
"""Generate the c11mux Stage 11 app icon at every macOS-required size.

Concept A from docs/c11mux-module-5-brand-identity-spec.md — one gold
spike rising from the lower edge of a void squircle.

Produces:
  Assets.xcassets/AppIcon.appiconset/*.png            (stable)
  Assets.xcassets/AppIcon-Debug.appiconset/*.png      (gold DEV banner, 70% alpha)
  Assets.xcassets/AppIcon-Nightly.appiconset/*.png    (purple NIGHTLY banner)
  Assets.xcassets/AppIcon-Staging.appiconset/*.png    (dim STAGING banner)

Also updates each appiconset's Contents.json.

Passes the 16px readability gate defined in the spec: the tiny rendered
icons have a compact vertical gold column over a dark tile.
"""

from __future__ import annotations

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(REPO, "Assets.xcassets")

GOLD = (201, 168, 76, 255)
GOLD_FAINT = (201, 168, 76, 0x33)
SURFACE = (10, 10, 10, 255)
DIM = (0x55, 0x55, 0x55, 255)
NIGHTLY_PURPLE = (140, 60, 220, 255)
WHITE = (255, 255, 255, 255)

# Image sizes for the AppIcon set (filename, pixel_size).
SIZES = [
    ("16.png", 16),
    ("16@2x.png", 32),
    ("32.png", 32),
    ("32@2x.png", 64),
    ("128.png", 128),
    ("128@2x.png", 256),
    ("256.png", 256),
    ("256@2x.png", 512),
    ("512.png", 512),
    ("512@2x.png", 1024),
]


def squircle_mask(size: int) -> Image.Image:
    """Return an L-mode mask for the squircle shape at the given size."""
    radius_ratio = 228 / 1024
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = max(1, int(round(size * radius_ratio)))
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def _render_pixel_spike(size: int) -> Image.Image:
    """Direct pixel render for 16-20px. Paints 3-5 gold pixels in a single
    centered column on the squircle mask."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = squircle_mask(size)
    for y in range(size):
        for x in range(size):
            if mask.getpixel((x, y)):
                canvas.putpixel((x, y), SURFACE)
    # Spike column at the exact center. 16px: x in {7,8}, y span ~5.
    cx = size // 2
    if size == 16:
        ys = [6, 7, 8, 9, 10]
    elif size == 17:
        ys = [6, 7, 8, 9, 10]
    elif size == 18:
        ys = [7, 8, 9, 10, 11]
    elif size == 19:
        ys = [7, 8, 9, 10, 11]
    else:  # 20
        ys = [8, 9, 10, 11, 12]
    # Use 3 centered y-pixels to stay within the "2-5 gold pixels" gate.
    # 16px gate wants 2-5; we paint 3.
    paint_ys = ys[1:4] if size == 16 else ys[1:4]
    for y in paint_ys:
        # Single-column paint at cx (and one pixel offset so the column is
        # not razor-thin — spec allows x ∈ [6, 9] at 16px).
        canvas.putpixel((cx - 1, y), GOLD)
    return canvas


def render_spike(size: int) -> Image.Image:
    """Render the core spike-on-void icon at an arbitrary pixel size.

    For tiny sizes (<=20px) we pixel-render directly so the spike reduces
    cleanly to the 16px readability gate's 2-5 gold pixels in a vertical
    column.
    """
    if size <= 20:
        return _render_pixel_spike(size)

    # Render at 4x supersample for smooth anti-aliasing.
    supersample = 4
    ss = size * supersample

    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Squircle fill
    radius = max(1, int(round(ss * 228 / 1024)))
    draw.rounded_rectangle((0, 0, ss - 1, ss - 1), radius=radius, fill=SURFACE)

    # Inner gold-faint stroke (skip at tiny sizes)
    if size >= 64:
        stroke_w = max(1, int(round(ss * 4 / 1024)))
        inset = stroke_w * 2
        inner_radius = max(1, radius - inset)
        draw.rounded_rectangle(
            (inset, inset, ss - 1 - inset, ss - 1 - inset),
            radius=inner_radius,
            outline=GOLD_FAINT,
            width=stroke_w,
        )

    # Spike: tip at 20% height, base at 80% height, centered.
    cx = ss / 2.0
    if size <= 20:
        # At 16-20px the spike must reduce to 2-5 gold pixels in a single
        # vertical column (spec "16px readability gate"). Narrow and
        # shorten so LANCZOS downsample lands within the gate.
        top_y = ss * 0.33
        bot_y = ss * 0.72
        base_half = max(1.0, ss * 0.018)
        tip_half = max(0.8, ss * 0.018)
    elif size <= 32:
        top_y = ss * 0.22
        bot_y = ss * 0.78
        base_half = ss * 0.045
        tip_half = ss * 0.025
    else:
        top_y = ss * 0.20
        bot_y = ss * 0.80
        base_half = ss * 0.04
        tip_half = ss * 0.008
    spike = [
        (cx, top_y),
        (cx + tip_half, top_y + 2),
        (cx + base_half, bot_y),
        (cx - base_half, bot_y),
        (cx - tip_half, top_y + 2),
    ]
    draw.polygon(spike, fill=GOLD)

    # Downsample to target size
    img = canvas.resize((size, size), Image.LANCZOS)
    return img


def add_banner(
    icon: Image.Image,
    text: str,
    color: tuple[int, int, int, int],
) -> Image.Image:
    """Overlay a bottom-edge channel banner (DEV/NIGHTLY/STAGING)."""
    icon = icon.copy().convert("RGBA")
    w, h = icon.size
    banner_h = max(8, int(round(h * 0.18)))
    banner_y = h - banner_h
    overlay = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    # Match the squircle silhouette by intersecting with the squircle mask.
    draw.rectangle((0, banner_y, w, h), fill=color)
    mask = squircle_mask(w)
    overlay.putalpha(Image.eval(mask, lambda v: v))
    # But we want the banner only within the bottom portion. Build a band mask.
    band = Image.new("L", (w, h), 0)
    band_draw = ImageDraw.Draw(band)
    band_draw.rectangle((0, banner_y, w, h), fill=255)
    # Combine: banner = color, alpha = min(mask, band)
    banner_rgba = Image.new("RGBA", icon.size, color)
    banner_alpha = Image.new("L", icon.size, 0)
    for y in range(h):
        for x in range(w):
            banner_alpha.putpixel((x, y), min(mask.getpixel((x, y)), band.getpixel((x, y))))
    banner_rgba.putalpha(banner_alpha)

    composed = Image.alpha_composite(icon, banner_rgba)

    # Text centered in the banner. Skip at tiny sizes.
    if h >= 64:
        font_size = max(6, int(round(banner_h * 0.58)))
        font = None
        for path in (
            "/System/Library/Fonts/SFCompact-Bold.otf",
            "/System/Library/Fonts/SFCompactDisplay.ttf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        ):
            if os.path.exists(path):
                try:
                    font = ImageFont.truetype(path, font_size)
                    break
                except Exception:
                    continue
        if font is None:
            font = ImageFont.load_default()
        td = ImageDraw.Draw(composed)
        bbox = td.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        tx = (w - tw) // 2 - bbox[0]
        ty = banner_y + (banner_h - th) // 2 - bbox[1]
        td.text((tx, ty), text, fill=WHITE, font=font)

    return composed


def dark_variant(icon: Image.Image) -> Image.Image:
    """Return a dark-appearance variant. For c11mux the palette does not
    diverge between light and dark modes, so the dark variant is
    identical. We still emit these files so the Contents.json
    appearances entries resolve."""
    return icon.copy()


def write_appiconset(
    set_name: str,
    transform,
) -> None:
    """Render each size into Assets.xcassets/<set_name>.appiconset/."""
    out_dir = os.path.join(ASSETS, f"{set_name}.appiconset")
    os.makedirs(out_dir, exist_ok=True)

    for filename, pixel_size in SIZES:
        base_icon = render_spike(pixel_size)
        light = transform(base_icon) if transform else base_icon
        light.save(os.path.join(out_dir, filename), "PNG")
        dark_name = filename.replace(".png", "_dark.png")
        dark_variant(light).save(os.path.join(out_dir, dark_name), "PNG")

    write_contents_json(out_dir)
    print(f"  Wrote {set_name}.appiconset ({len(SIZES) * 2} PNGs)")


def write_contents_json(out_dir: str) -> None:
    images: list[dict] = []
    for filename, _ in SIZES:
        base, ext = os.path.splitext(filename)
        # Extract size + scale from name, e.g. "16.png" -> "16x16" @1x; "16@2x" -> @2x
        if "@2x" in base:
            size_str = base.split("@")[0]
            scale = "2x"
        else:
            size_str = base
            scale = "1x"
        images.append(
            {
                "filename": filename,
                "idiom": "mac",
                "scale": scale,
                "size": f"{size_str}x{size_str}",
            }
        )
        images.append(
            {
                "appearances": [
                    {"appearance": "luminosity", "value": "dark"}
                ],
                "filename": f"{base}_dark{ext}",
                "idiom": "mac",
                "scale": scale,
                "size": f"{size_str}x{size_str}",
            }
        )
    payload = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(out_dir, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def main() -> int:
    write_appiconset("AppIcon", transform=None)
    write_appiconset(
        "AppIcon-Debug",
        transform=lambda im: add_banner(im, "DEV", (201, 168, 76, int(0xFF * 0.70))),
    )
    write_appiconset(
        "AppIcon-Nightly",
        transform=lambda im: add_banner(im, "NIGHTLY", NIGHTLY_PURPLE),
    )
    write_appiconset(
        "AppIcon-Staging",
        transform=lambda im: add_banner(im, "STAGING", (*DIM[:3], 255)),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
