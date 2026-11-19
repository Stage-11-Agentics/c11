#!/usr/bin/env python3
"""rx.py <out>: put this tty in raw mode and append every byte read to <out>.
Acceptance matrix T2.20, T6.x: compare what a program received with what c11 reported.
<out>.idx gets one line per read: monotonic ns, byte count. Ctrl-] (0x1d) alone ends it."""
import os, sys, termios, time, tty
out = sys.argv[1]
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
try:
    os.write(1, b"RX READY\r\n")
    with open(out, "ab", buffering=0) as f, open(out + ".idx", "a") as ix:
        while True:
            b = os.read(fd, 65536)
            if not b or b == b"\x1d": break
            f.write(b); ix.write(f"{time.monotonic_ns()} {len(b)}\n"); ix.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
