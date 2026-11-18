#!/usr/bin/env python3
"""Spike 0b: enable mode 2048, and for each in-band size report compare it with the PTY size at that instant."""
import os, sys, termios, tty, select, re, time
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
os.write(1, b"\x1b[?2048h"); buf = b""; out = []; t0 = time.time()
while time.time() - t0 < float(sys.argv[1] if len(sys.argv) > 1 else 12):
    r, _, _ = select.select([fd], [], [], 0.5)
    if not r: continue
    buf += os.read(fd, 1024)
    for m in re.finditer(rb"\x1b\[48;(\d+);(\d+);(\d+);(\d+)t", buf):
        sz = os.get_terminal_size(fd)
        rows, cols = int(m.group(1)), int(m.group(2))
        out.append(f"report={cols}x{rows} pty={sz.columns}x{sz.lines} match={(cols, rows) == (sz.columns, sz.lines)}")
    buf = buf[buf.rfind(b"t") + 1:] if out else buf
os.write(1, b"\x1b[?2048l"); termios.tcsetattr(fd, termios.TCSADRAIN, old)
open("/tmp/c0b-2048.txt", "w").write("\n".join(out) + "\n"); print("\n".join(out) or "no reports")
