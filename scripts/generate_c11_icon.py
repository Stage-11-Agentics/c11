#!/usr/bin/env python3
"""Generate the c11mux Stage 11 app icon at every macOS-required size.

Source art: design/c11mux-lattice-icon-source.png — Hyperfuturistic
lattice (white on black), from Gregorovitch art.

Produces:
  Assets.xcassets/AppIcon.appiconset/*.png            (stable)
  Assets.xcassets/AppIcon-Debug.appiconset/*.png      (gold DEV banner, 70% alpha)
  Assets.xcassets/AppIcon-Nightly.appiconset/*.png    (purple NIGHTLY banner)
  Assets.xcassets/AppIcon-Staging.appiconset/*.png    (dim STAGING banner)
  Assets.xcassets/AppIconLight.imageset/AppIconLight.png
  Assets.xcassets/AppIconDark.imageset/AppIconDark.png

Also updates each appiconset's Contents.json.
"""

from __future__ import annotations

import json
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(REPO, "Assets.xcassets")
SOURCE_IMAGE = os.path.join(REPO, "design", "c11mux-lattice-icon-source.png")

GOLD = (201, 168, 76, 255)
SURFACE = (0, 0, 0, 255)
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

# Emit the imageset PNGs at 1024px for crisp in-app rendering.
IMAGESET_SIZE = 1024


def squircle_mask(size: int) -> Image.Image:
    """Return an L-mode mask for the squircle shape at the given size."""
    radius_ratio = 228 / 1024
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = max(1, int(round(size * radius_ratio)))
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


_source_cache: Image.Image | None = None


def _load_source() -> Image.Image:
    global _source_cache
    if _source_cache is None:
        img = Image.open(SOURCE_IMAGE).convert("RGBA")
        # Square it (should already be square, but guard anyway).
        w, h = img.size
        if w != h:
            side = min(w, h)
            left = (w - side) // 2
            top = (h - side) // 2
            img = img.crop((left, top, left + side, top + side))
        _source_cache = img
    return _source_cache


def render_simplified_glyph(size: int) -> Image.Image:
    """Render a pared-down hub-and-spokes glyph for tiny sizes (≤32px physical).

    Captures the lattice's cross-diamond topology: a solid central cube with
    four cardinal arms ending in smaller caps. Survives the menu-bar size
    where the full lattice blurs out.
    """
    supersample = 8 if size <= 16 else 4
    ss = size * supersample

    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    radius = max(1, int(round(ss * 228 / 1024)))
    draw.rounded_rectangle((0, 0, ss - 1, ss - 1), radius=radius, fill=SURFACE)

    cx = ss / 2.0
    cy = ss / 2.0
    body_half = ss * 0.18   # central cube: 36% of side
    arm_half = ss * 0.055   # arm thickness
    arm_reach = ss * 0.36   # distance from center to arm tip
    cap_half = ss * 0.10    # end-cap cube: 20% of side

    # Central cube.
    draw.rectangle(
        (cx - body_half, cy - body_half, cx + body_half, cy + body_half),
        fill=WHITE,
    )
    # Arms + caps at N/S/E/W.
    def rect(x0, y0, x1, y1):
        draw.rectangle((min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)), fill=WHITE)

    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        if dx == 0:
            rect(cx - arm_half, cy + dy * body_half, cx + arm_half, cy + dy * arm_reach)
            cap_cx, cap_cy = cx, cy + dy * arm_reach
        else:
            rect(cx + dx * body_half, cy - arm_half, cx + dx * arm_reach, cy + arm_half)
            cap_cx, cap_cy = cx + dx * arm_reach, cy
        rect(cap_cx - cap_half, cap_cy - cap_half, cap_cx + cap_half, cap_cy + cap_half)

    return canvas.resize((size, size), Image.LANCZOS)


def render_icon(size: int) -> Image.Image:
    """Composite the lattice source onto a squircle-masked black tile at `size`.

    For ≤32px physical pixels the full lattice blurs into noise, so fall back
    to a simplified glyph that preserves the cross-diamond topology.
    """
    if size <= 32:
        return render_simplified_glyph(size)

    supersample = 4 if size <= 128 else 2
    ss = size * supersample

    # Squircle-shaped black surface.
    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    radius = max(1, int(round(ss * 228 / 1024)))
    draw.rounded_rectangle((0, 0, ss - 1, ss - 1), radius=radius, fill=SURFACE)

    # Resize the lattice source to fit inside the squircle. The source
    # already carries its own black background + padding, so we just
    # paint it across the full squircle and let the squircle mask trim
    # the corners.
    lattice = _load_source().resize((ss, ss), Image.LANCZOS)
    mask = squircle_mask(ss)
    canvas.paste(lattice, (0, 0), mask)

    # Downsample to the target size.
    return canvas.resize((size, size), Image.LANCZOS)


def add_banner(
    icon: Image.Image,
    text: str,
    color: tuple[int, int, int, int],
) -> Image.Image:
    """Overlay a bottom-edge channel banner (DEV/NIGHTLY/STAGING).

    Skipped at sizes where no text fits — at those sizes the colored band
    would only cover the bottom cap of the simplified hub-and-spokes glyph
    with no added channel signal.
    """
    icon = icon.copy().convert("RGBA")
    w, h = icon.size
    if h < 64:
        return icon

    banner_h = max(8, int(round(h * 0.18)))
    banner_y = h - banner_h

    # Banner alpha = squircle silhouette ∩ bottom band.
    mask = squircle_mask(w)
    band = Image.new("L", (w, h), 0)
    ImageDraw.Draw(band).rectangle((0, banner_y, w, h), fill=255)
    banner_alpha = ImageChops.multiply(mask, band)

    banner_rgba = Image.new("RGBA", icon.size, color)
    banner_rgba.putalpha(banner_alpha)
    composed = Image.alpha_composite(icon, banner_rgba)

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


def write_appiconset(set_name: str, transform) -> None:
    """Render each size into Assets.xcassets/<set_name>.appiconset/."""
    out_dir = os.path.join(ASSETS, f"{set_name}.appiconset")
    os.makedirs(out_dir, exist_ok=True)

    for filename, pixel_size in SIZES:
        base_icon = render_icon(pixel_size)
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
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
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


def write_imagesets() -> None:
    """Render the runtime imagesets used by the in-app icon picker
    (Sources/cmuxApp.swift references "AppIconLight" / "AppIconDark")."""
    base = render_icon(IMAGESET_SIZE)
    targets = [
        ("AppIconLight.imageset", "AppIconLight.png"),
        ("AppIconDark.imageset", "AppIconDark.png"),
    ]
    for dirname, filename in targets:
        out_dir = os.path.join(ASSETS, dirname)
        os.makedirs(out_dir, exist_ok=True)
        base.save(os.path.join(out_dir, filename), "PNG")
        contents = {
            "images": [{"filename": filename, "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        }
        with open(os.path.join(out_dir, "Contents.json"), "w", encoding="utf-8") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")
        print(f"  Wrote {dirname}/{filename}")


def write_icon_format() -> None:
    """Write the Xcode 16 .icon format source + config.

    The .icon format composites a source image into the macOS icon
    chrome (squircle, shadows, glass). We provide the pre-masked
    lattice tile at 1024px and let Xcode handle the rest.
    """
    icon_dir = os.path.join(REPO, "AppIcon.icon")
    assets_dir = os.path.join(icon_dir, "Assets")
    os.makedirs(assets_dir, exist_ok=True)

    # Purge old source assets.
    for name in os.listdir(assets_dir):
        if name.endswith(".png"):
            os.remove(os.path.join(assets_dir, name))

    base = render_icon(IMAGESET_SIZE)
    source_name = "c11mux-lattice.png"
    base.save(os.path.join(assets_dir, source_name), "PNG")

    icon_config = {
        "fill": "automatic",
        "groups": [
            {
                "layers": [
                    {
                        "glass": False,
                        "image-name": source_name,
                        "name": "c11mux-lattice",
                        "position": {
                            "scale": 1,
                            "translation-in-points": [0, 0],
                        },
                    }
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.5},
            }
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared",
        },
    }
    with open(os.path.join(icon_dir, "icon.json"), "w", encoding="utf-8") as f:
        json.dump(icon_config, f, indent=2)
        f.write("\n")
    print(f"  Wrote AppIcon.icon/Assets/{source_name} + icon.json")


def write_icns() -> None:
    """Generate design/c11mux.icns from the base AppIcon PNGs using iconutil."""
    import shutil
    import subprocess
    import tempfile

    src_set = os.path.join(ASSETS, "AppIcon.appiconset")
    pairs = [
        ("16.png", "icon_16x16.png"),
        ("16@2x.png", "icon_16x16@2x.png"),
        ("32.png", "icon_32x32.png"),
        ("32@2x.png", "icon_32x32@2x.png"),
        ("128.png", "icon_128x128.png"),
        ("128@2x.png", "icon_128x128@2x.png"),
        ("256.png", "icon_256x256.png"),
        ("256@2x.png", "icon_256x256@2x.png"),
        ("512.png", "icon_512x512.png"),
        ("512@2x.png", "icon_512x512@2x.png"),
    ]

    out_icns = os.path.join(REPO, "design", "c11mux.icns")
    with tempfile.TemporaryDirectory() as tmp:
        iconset_dir = os.path.join(tmp, "c11mux.iconset")
        os.makedirs(iconset_dir)
        for src_name, dst_name in pairs:
            shutil.copy2(
                os.path.join(src_set, src_name),
                os.path.join(iconset_dir, dst_name),
            )
        result = subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", out_icns],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(
                f"  iconutil failed: {result.stderr.strip()}",
                file=sys.stderr,
            )
            return
    print(f"  Wrote design/c11mux.icns")


def main() -> int:
    if not os.path.exists(SOURCE_IMAGE):
        print(f"error: source image not found at {SOURCE_IMAGE}", file=sys.stderr)
        return 1
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
    write_imagesets()
    write_icon_format()
    write_icns()
    return 0


if __name__ == "__main__":
    sys.exit(main())
