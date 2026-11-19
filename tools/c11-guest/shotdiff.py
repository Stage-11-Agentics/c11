#!/usr/bin/env python3
"""shotdiff.py <a.png> <b.png> [x0 y0 x1 y1 as fractions]: print the count of pixels whose colour differs by more than 40 summed channel
units between two same-size screenshots, optionally only inside a fractional box. Host-side (uses sips to get an uncompressed BMP).
Used where a row says "overlay visible" / "match highlighted": a change in the expected region is machine-checkable evidence."""
import struct, subprocess, sys, tempfile, os
def bmp(path):
    t = tempfile.mktemp(suffix=".bmp")
    subprocess.run(["/usr/bin/sips", "-s", "format", "bmp", path, "--out", t], capture_output=True, check=True)
    d = open(t, "rb").read(); os.unlink(t)
    off = struct.unpack_from("<I", d, 10)[0]; w, h = struct.unpack_from("<ii", d, 18); bpp = struct.unpack_from("<H", d, 28)[0]
    return d, off, w, abs(h), bpp // 8, h < 0
bbox_mode = "--bbox" in sys.argv
args = [x for x in sys.argv[1:] if x != "--bbox"]
a, b = args[0], args[1]
box = [float(x) for x in args[2:6]] if len(args) >= 6 else [0, 0, 1, 1]
da, off, w, h, bp, topdown = bmp(a); db, offb, wb, hb, bpb, _ = bmp(b)
if (w, h) != (wb, hb): print(f"size-differs {w}x{h} vs {wb}x{hb}"); sys.exit(2)
stride_a = (w * bp + 3) & ~3
n = 0; xs = []; ys = []
for y in range(int(box[1] * h), int(box[3] * h)):
    ra = off + y * stride_a; rb = offb + y * stride_a
    for x in range(int(box[0] * w), int(box[2] * w)):
        pa = da[ra + x * bp: ra + x * bp + 3]; pb = db[rb + x * bp: rb + x * bp + 3]
        if sum(abs(p - q) for p, q in zip(pa, pb)) > 40: n += 1; xs.append(x); ys.append(y)
if bbox_mode:
    print("none" if not xs else " ".join("%.4f" % v for v in (min(xs) / w, min(ys) / h, (max(xs) + 1) / w, (max(ys) + 1) / h)))
else:
    print(n)
