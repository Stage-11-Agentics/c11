#!/usr/bin/env python3
"""ruler.py: a stand-in for vim's ruler that needs no key. On start and on every SIGWINCH it clears the screen and draws
`W=<cols> H=<rows>` padded with spaces to the last column, which holds `|`, on the first line and the last line.
If the panel's picture is stale (a 4-column gap) the `|` index and the W value disagree. Ctrl-C ends it. Acceptance T5.1."""
import os, shutil, signal, sys, time
def draw(*_):
    c, r = shutil.get_terminal_size()
    line = (f"W={c} H={r}").ljust(c - 1) + "|"
    sys.stdout.write("\x1b[2J\x1b[H" + line + "\x1b[%d;1H" % r + line)
    sys.stdout.flush()
signal.signal(signal.SIGWINCH, draw); draw()
while True: time.sleep(0.2)
