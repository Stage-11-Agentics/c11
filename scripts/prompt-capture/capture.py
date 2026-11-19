#!/usr/bin/env python3
"""Run an agent TUI in a headless pty of a given size, record every output
byte to OUTDIR/raw.bin, and mark byte offsets (OUTDIR/marks.json) at each
stage: startup, idle after one turn, TYPED typed into the box, the box
cleared with Ctrl-U, `status check` typed. Replay a mark with
`replay.py OUTDIR/raw.bin COLS ROWS --upto <offset>`.

usage: capture.py OUTDIR COLS ROWS PROMPT TYPED [-- command ...]
The default command is `claude --model haiku`, run from the current directory.
Unset CLAUDE_CODE_CHILD_SESSION is applied so a Claude started from an agent
draws a normal session screen.
"""
import fcntl, json, os, pty, select, signal, struct, sys, termios, time

args = sys.argv[1:]
cmd = args[args.index("--") + 1:] if "--" in args else ["claude", "--model", "haiku"]
out, cols, rows, prompt, typed = args[0], int(args[1]), int(args[2]), args[3], args[4]
os.makedirs(out, exist_ok=True)
raw = open(os.path.join(out, "raw.bin"), "wb")
marks, size = {}, 0

pid, fd = pty.fork()
if pid == 0:
    os.environ.pop("CLAUDE_CODE_CHILD_SESSION", None)
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
os.kill(pid, signal.SIGWINCH)

def pump(seconds, quiet):
    """Read for up to `seconds`, returning after `quiet` seconds of silence."""
    global size
    end, last = time.time() + seconds, time.time()
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            raw.write(data); raw.flush(); size += len(data); last = time.time()
            if b"\x1b[c" in data:
                os.write(fd, b"\x1b[?62;22c")
        elif time.time() - last > quiet:
            return

def mark(name):
    marks[name] = size
    print(f"{name} {size}", flush=True)

pump(20, 6); mark("startup")
os.write(fd, prompt.encode()); pump(2, 1)
os.write(fd, b"\r"); pump(90, 15); pump(20, 8); mark("idle")
os.write(fd, typed.encode()); pump(4, 2); mark("typed")
os.write(fd, b"\x15"); pump(4, 2); mark("cleared")
os.write(fd, b"status check"); pump(4, 2); mark("draft")
json.dump(marks, open(os.path.join(out, "marks.json"), "w"), indent=1)
# Quit. Some TUIs exit on the first Ctrl-C, which closes the pty.
try:
    os.write(fd, b"\x15"); pump(3, 2)
    os.write(fd, b"\x03"); pump(2, 1); os.write(fd, b"\x03"); pump(3, 2)
except OSError:
    pass
try:
    os.kill(pid, signal.SIGTERM)
except ProcessLookupError:
    pass
