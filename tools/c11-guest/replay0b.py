#!/usr/bin/env python3
"""Spike 0b: replay a captured ANSI log at about RATE bytes/s, forever (or for SECONDS)."""
import sys, time, os
path, rate = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 50000
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
data = open(path, "rb").read(); chunk = rate // 20; i = 0; t0 = time.time(); n = 0
while time.time() - t0 < secs:
    piece = data[i:i + chunk]; i += chunk
    if i >= len(data): i = 0
    os.write(1, piece); n += len(piece)
    target = t0 + n / rate; d = target - time.time()
    if d > 0: time.sleep(d)
