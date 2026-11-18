#!/usr/bin/env python3
"""Spike 0b: terminal queries from inside a panel. Prints each reply and how long it took.
A reply that took ~3000 ms timed out (nobody answered)."""
import os, sys, termios, tty, select, time
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
def q(s, idle=0.4, total=3.0):
    os.write(1, s.encode()); out = b""; t0 = time.time()
    while time.time() - t0 < total:
        r, _, _ = select.select([fd], [], [], idle if out else total - (time.time() - t0))
        if not r: break
        out += os.read(fd, 4096)
    return out, (time.time() - t0) * 1000
names = sys.argv[1:] or ["DA1", "DSR", "KITTY", "OSC10", "OSC11", "OSC4", "XTGETTCAP", "OSC52R", "XTVERSION", "CSI18t", "CSI16t"]
Q = {"DA1": "\x1b[c", "DSR": "\x1b[6n", "KITTY": "\x1b[?u", "OSC10": "\x1b]10;?\x07", "OSC11": "\x1b]11;?\x07",
     "OSC4": "\x1b]4;1;?\x07", "XTGETTCAP": "\x1bP+q544e;636f6c6f7273\x1b\\", "OSC52R": "\x1b]52;c;?\x07",
     "XTVERSION": "\x1b[>q", "XTTN": "\x1bP+q544e\x1b\\", "XTTWO": "\x1bP+q544e\x1b\\\x1bP+q636f6c6f7273\x1b\\", "CSI18t": "\x1b[18t", "CSI16t": "\x1b[16t"}
res = []
for n in names:
    r, ms = q(Q[n]); res.append(f"Q {n} ms={ms:.0f} reply={r!r}")
termios.tcsetattr(fd, termios.TCSADRAIN, old)
text = "\n".join(res)
open("/tmp/c0b-q.txt", "a").write(time.strftime("%H:%M:%S ") + " ".join(sys.argv[1:]) + "\n" + text + "\n")
print(text.replace("\\x1b", "ESC"))
