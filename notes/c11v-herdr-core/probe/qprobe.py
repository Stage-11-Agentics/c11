import os, sys, termios, tty, select, time
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
def ask(name, q, wait=0.45):
    os.write(1, q); buf=b""; t0=time.time()
    while time.time()-t0 < wait:
        r,_,_ = select.select([fd],[],[],0.05)
        if r: buf += os.read(fd, 4096)
    return name, buf
qs = [("DA1", b"\x1b[c"), ("DA2", b"\x1b[>c"), ("XTVERSION", b"\x1b[>q"), ("DSR6n", b"\x1b[6n"), ("OSC11bg", b"\x1b]11;?\x07"), ("OSC10fg", b"\x1b]10;?\x07"), ("OSC4pal", b"\x1b]4;1;?\x07"), ("kitty?u", b"\x1b[?u"), ("XTGETTCAP", b"\x1bP+q544e\x1b\\"), ("DECRQSS", b"\x1bP$qm\x1b\\"), ("OSC52read", b"\x1b]52;c;?\x07"), ("CSI14t", b"\x1b[14t"), ("CSI16t", b"\x1b[16t"), ("CSI18t", b"\x1b[18t"), ("DECRQM2004", b"\x1b[?2004$p"), ("996n", b"\x1b[?996n"), ("7501?", b"\x1b]7501;?\x1b\\"), ("XTSMGRAPHICS", b"\x1b[?2;1;0S")]
results = [ask(*x) for x in qs]
termios.tcsetattr(fd, termios.TCSADRAIN, old)
for n,b in results: print(f"QP {n}: {'answered' if b else 'NO-REPLY'} {b!r}")
print("QPEND")
