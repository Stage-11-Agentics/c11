# Direct PTY echo RTT (no hc): zsh -l in a PTY, 'a' -> echo 'a'. Optionally N flood PTYs running yes, drained by threads.
import os, pty, sys, time, select, threading, signal
def spawn(argv):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    return pid, fd
def reader(fd, stop):
    while not stop.is_set():
        r,_,_ = select.select([fd],[],[],0.2)
        if r:
            try:
                if not os.read(fd, 65536): break
            except OSError: break
nflood = int(sys.argv[1]); n = int(sys.argv[2])
stop = threading.Event(); floods=[]
for i in range(nflood):
    pid, fd = spawn(["/bin/sh","-c","yes | head -c 2000000000"]); floods.append((pid,fd))
    threading.Thread(target=reader, args=(fd,stop), daemon=True).start()
pid, fd = spawn(["/bin/zsh","-l"]); time.sleep(1.5)
def drain(t=0.3):
    while True:
        r,_,_=select.select([fd],[],[],t)
        if not r: return
        os.read(fd,65536)
drain(); os.write(fd, b"\x15"); drain(0.2)
samples=[]
for i in range(n):
    if i % 60 == 59: os.write(fd, b"\x15"); drain(0.05)
    t0=time.perf_counter_ns(); os.write(fd, b"a"); got=b""
    while b"a" not in got:
        r,_,_=select.select([fd],[],[],2)
        if not r: raise SystemExit("no echo")
        got+=os.read(fd,4096)
    samples.append((time.perf_counter_ns()-t0)/1000)
samples.sort(); q=lambda p: samples[int(len(samples)*p)-1]
print(f"direct PTY zsh echo RTT us (floods={nflood}): n={n} p50={q(.5):.1f} p90={q(.9):.1f} p99={q(.99):.1f} max={samples[-1]:.1f}")
stop.set()
for p,f in floods: 
    try: os.killpg(os.getpgid(p), signal.SIGKILL)
    except Exception: os.kill(p, signal.SIGKILL)
os.write(fd, b"\x15exit\r"); time.sleep(0.3)
try: os.kill(pid, signal.SIGKILL)
except Exception: pass
