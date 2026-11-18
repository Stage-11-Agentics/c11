#!/usr/bin/env python3
"""Generate c11h's paired Ghostty terminal themes from design/themes/c11h-themes.html.

Inputs are each prototype block's effective --term-* values (a block that leaves one
unset inherits the :root value, as the page renders it) and its `.prompt .caret` colour.
ANSI: red, green, yellow, blue as given; magenta is the prototype's pink and bright
magenta its violet; cyan is the accent where the accent is itself cyan, else the midpoint
of green and blue; white is the foreground eased toward dim; bright black is dim; the other
bright colours are a step lighter in OKLCH. Every normal colour keeps 4.5:1 on the
background (raised a little if it would not).

    python3 design/themes/gen-terminal-themes.py Resources/ghostty/themes
"""
import math
import sys

ROOT = dict(green="#6fcf6f", blue="#7fb0ff", pink="#f25c8c", yellow="#e2c85a", red="#ff6b6b", violet="#b48cff")

THEMES = {
    # name: block values, caret, cyan source ("accent" when the accent is itself cyan)
    "c11h-datasheet-mono": dict(bg="#111214", fg=("#ffffff", 0.92), dim=("#ffffff", 0.46), caret="#FFFFFF",
                                display="Datasheet Mono"),
    "c11h-terminal-grid": dict(bg="#0b0b0c", fg="#c8c8c4", dim="#6a6b6e", green="#9aa8a0", blue="#9fb3c8",
                               pink="#c9a2b4", yellow="#c8b58a", violet="#b1a6c8", caret="#ff6a1f",
                               display="Terminal Grid"),
    "c11h-outrun-horizon": dict(bg="#0b0716", fg="#e6def7", dim="#7f72a6", green="#7ff0c4", blue="#7fd4ff",
                                pink="#ff3f8e", yellow="#ffcf6a", violet="#c99bff", caret="#ff3f8e",
                                cyan="#2DE2E6", display="Outrun Horizon"),
    "c11h-nocturne": dict(bg="#07080a", fg="#d6d9de", dim="#5b606a", green="#8fd1a8", blue="#7fb0ff",
                          pink="#e38aa6", yellow="#e0c27a", violet="#b4a0e8", caret="#c9d6ea",
                          display="Nocturne"),
    "c11h-bigboard": dict(bg="#05070a", fg="#cfdbe3", dim="#52677a", green="#3ddc84", blue="#6fb6ff",
                          pink="#ff7a9e", yellow="#ffb224", violet="#b4a0e8", caret="#3ddc84",
                          display="Big Board"),
}


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rgb_to_hex(c):
    return "#" + "".join(f"{max(0, min(255, round(v * 255))):02x}" for v in c)


def over(fg, alpha, bg):
    f, b = hex_to_rgb(fg), hex_to_rgb(bg)
    return rgb_to_hex(tuple(alpha * x + (1 - alpha) * y for x, y in zip(f, b)))


def mix(a, b, t):
    x, y = hex_to_rgb(a), hex_to_rgb(b)
    return rgb_to_hex(tuple((1 - t) * p + t * q for p, q in zip(x, y)))


def lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def delin(v):
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def luminance(h):
    r, g, b = (lin(v) for v in hex_to_rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def to_oklch(h):
    r, g, b = (lin(v) for v in hex_to_rgb(h))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(A, B), math.atan2(B, A)


def from_oklch(L, C, H):
    A, B = C * math.cos(H), C * math.sin(H)
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (r, g, b)


def lighter(h, step=0.07):
    """A step lighter in OKLCH lightness, hue kept; chroma eased only to stay in sRGB."""
    L, C, H = to_oklch(h)
    L = min(1.0, L + step)
    while True:
        r, g, b = from_oklch(L, C, H)
        if all(-1e-4 <= v <= 1 + 1e-4 for v in (r, g, b)) or C < 1e-4:
            return rgb_to_hex(tuple(delin(max(0.0, min(1.0, v))) for v in (r, g, b)))
        C *= 0.97


def build(name, t):
    bg = t["bg"]
    flat = lambda v: over(v[0], v[1], bg) if isinstance(v, tuple) else v
    fg, dim = flat(t["fg"]), flat(t["dim"])
    green, blue = t.get("green", ROOT["green"]), t.get("blue", ROOT["blue"])
    pink, yellow = t.get("pink", ROOT["pink"]), t.get("yellow", ROOT["yellow"])
    red, violet = t.get("red", ROOT["red"]), t.get("violet", ROOT["violet"])
    cyan = t.get("cyan") or mix(green, blue, 0.5)
    white = mix(fg, dim, 0.2)
    normal = [mix(bg, fg, 0.18), red, green, yellow, blue, pink, cyan, white]
    adjusted = []
    for i in range(1, 8):
        c = normal[i]
        while contrast(c, bg) < 4.5:
            c = lighter(c, 0.01)
        if c != normal[i]:
            adjusted.append((i, normal[i], c))
        normal[i] = c
    bright = [dim] + [lighter(c) for c in normal[1:5]] + [violet, lighter(normal[6]), lighter(fg, 0.05)]
    palette = normal + bright
    return dict(bg=bg, fg=fg, palette=palette, cursor=t["caret"], adjusted=adjusted,
                selection=mix(bg, fg, 0.24), display=t["display"])


def render(name, th):
    lines = [f"# c11h {th['display']}: paired with the {th['display']} chrome theme (design/themes/gen-terminal-themes.py)"]
    lines += [f"palette = {i}={c}" for i, c in enumerate(th["palette"])]
    lines += [
        f"background = {th['bg']}",
        f"foreground = {th['fg']}",
        f"cursor-color = {th['cursor']}",
        f"cursor-text = {th['bg']}",
        f"selection-background = {th['selection']}",
        f"selection-foreground = {th['fg']}",
    ]
    return "\n".join(lines) + "\n"


def report(name, th):
    bg = th["bg"]
    print(f"== {name}  bg {bg}  fg {th['fg']} ({contrast(th['fg'], bg):.2f})")
    for i, c in enumerate(th["palette"]):
        print(f"  {i:2d} {c}  {contrast(c, bg):5.2f}")
    print(f"  cursor {th['cursor']} text-on-cursor {contrast(bg, th['cursor']):.2f}  selection {th['selection']} fg-on-sel {contrast(th['fg'], th['selection']):.2f}")
    for i, before, after in th["adjusted"]:
        print(f"  adjusted {i}: {before} -> {after}")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else None
    for name, t in THEMES.items():
        th = build(name, t)
        report(name, th)
        if out:
            with open(f"{out}/{name}", "w") as handle:
                handle.write(render(name, th))
