#!/usr/bin/env python3
"""latp.py <terminal> <n>: keystroke echo round trip through an hc core's attach stream.
Env HC_SOCK = the core's socket. Attaches to <terminal> (e.g. studio/t2 running `cat`), sends one
byte 'a' at a time, times until it comes back, clears the line with ^U every 40 keys.
Prints every sample in ms and p50 / p95 / p99 / max. Adapted from c11-ops notes/c11v-herdr-core/probe/hcx.py."""
import json, os, select, socket, statistics, struct, sys, time
SOCK = os.environ["HC_SOCK"]; DATA, CREDIT, CLOSE = 0, 1, 2
term, n = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_UNIX); s.connect(SOCK); buf = b""
def line_call(m, p, i):
    global buf
    s.sendall((json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n").encode())
    while b"\n" not in buf: buf += s.recv(65536)
    l, buf = buf.split(b"\n", 1); return json.loads(l)
def frame(ch, kind, payload=b""): s.sendall(struct.pack("<IBI", ch, kind, len(payload)) + payload)
def read_frame(timeout):
    global buf
    while len(buf) < 9 or len(buf) < 9 + struct.unpack("<I", buf[5:9])[0]:
        r, _, _ = select.select([s], [], [], timeout)
        if not r: return None
        d = s.recv(1 << 20)
        if not d: return None
        buf += d
    ch, kind, ln = struct.unpack("<IBI", buf[:9]); p = buf[9:9 + ln]; buf = buf[9 + ln:]; return ch, kind, p
hello = line_call("hello", {"framed": True, "generation": 1}, 1)
if "error" in hello: sys.exit("hello: " + json.dumps(hello["error"]))
frame(0, DATA, json.dumps({"jsonrpc": "2.0", "id": 2, "method": "terminal.attach",
      "params": {"terminal": term, "cols": 100, "rows": 30, "history": 0}}).encode())
ch = None
while ch is None:
    f = read_frame(20)
    if f is None: sys.exit("attach: no reply in 20 s")
    if f[0] == 0:
        m = json.loads(f[2])
        if m.get("id") == 2:
            if "error" in m: sys.exit("attach: " + json.dumps(m["error"]))
            ch = m["result"]["channel"]
def drain(t):
    while True:
        f = read_frame(t)
        if f is None: return
        if f[0] == ch and f[1] == DATA: frame(ch, CREDIT, struct.pack("<I", len(f[2])))
drain(1.0); frame(ch, DATA, b"\x15"); drain(0.5)
ms = []
for i in range(n):
    if i and i % 40 == 0: frame(ch, DATA, b"\x15"); drain(0.2)
    t0 = time.perf_counter_ns(); frame(ch, DATA, b"a"); got = b""
    while b"a" not in got:
        f = read_frame(5)
        if f is None: sys.exit(f"no echo for key {i}")
        if f[0] == ch and f[1] == DATA: got += f[2]; frame(ch, CREDIT, struct.pack("<I", len(f[2])))
    ms.append((time.perf_counter_ns() - t0) / 1e6); time.sleep(0.05)
frame(ch, DATA, b"\x15"); frame(ch, CLOSE)
srt = sorted(ms); q = lambda p: srt[max(0, int(round(len(srt) * p)) - 1)]
print("samples_ms " + " ".join(f"{x:.2f}" for x in ms))
print(f"echo RTT ms: n={len(ms)} p50={statistics.median(ms):.2f} p95={q(.95):.2f} p99={q(.99):.2f} max={srt[-1]:.2f}")
