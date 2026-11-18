#!/usr/bin/env python3
"""hcx: probes against an isolated herdr-core (framed protocol). Usage: hcx.py <cmd> [args]
Env: HC_SOCK (socket path). Commands:
  paint <terminal> [history]      attach, dump the first paint (repr + summary), detach
  queries <terminal>              attach as a silent viewer and record what passes through while a probe script runs in the terminal
  flood <terminal> <seconds>      attach, consume slowly (no credit) while the program floods; report repaint frames
  tput <terminal> <path>          attach, run 'cat path' in the terminal via DATA, measure MiB/s delivered to the viewer
  lat <terminal> <n>              keystroke echo RTT through core+holder
  run <json>                      terminal.run with params json; prints result
  call <method> <json>            any plain call
"""
import socket, struct, json, time, sys, statistics, select, os
SOCK = os.environ.get("HC_SOCK", "/tmp/c11hcx/herdr-core/c11x.sock")
DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS = range(6)

class Conn:
    def __init__(self, framed=True):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(SOCK)
        self.buf = b""; self.id = 0
        self.hello = self.call_plain("hello", {"framed": framed, "generation": 1})
    def call_plain(self, m, p):
        self.id += 1
        self.s.sendall((json.dumps({"jsonrpc":"2.0","id":self.id,"method":m,"params":p})+"\n").encode())
        while b"\n" not in self.buf: self.buf += self.s.recv(65536)
        line, self.buf = self.buf.split(b"\n", 1); return json.loads(line)
    def send_frame(self, ch, kind, payload=b""):
        self.s.sendall(struct.pack("<IBI", ch, kind, len(payload)) + payload)
    def read_frame(self, timeout=5):
        while len(self.buf) < 9 or len(self.buf) < 9 + struct.unpack("<I", self.buf[5:9])[0]:
            r,_,_ = select.select([self.s],[],[],timeout)
            if not r: return None
            d = self.s.recv(1<<20)
            if not d: return None
            self.buf += d
        ch, kind, n = struct.unpack("<IBI", self.buf[:9]); p = self.buf[9:9+n]; self.buf = self.buf[9+n:]
        return ch, kind, p
    def call(self, m, p):
        self.id += 1; my = self.id
        self.send_frame(0, DATA, json.dumps({"jsonrpc":"2.0","id":my,"method":m,"params":p}).encode())
        while True:
            f = self.read_frame()
            if f is None: raise SystemExit("timeout on "+m)
            if f[0]==0:
                msg = json.loads(f[2])
                if msg.get("id")==my: return msg
    def attach(self, term, cols=100, rows=30, history=0, display=None, observe=False):
        p = {"terminal":term,"cols":cols,"rows":rows,"history":history,"observe":observe}
        if display: p["display"]=display
        r = self.call("terminal.attach", p)
        if "error" in r: raise SystemExit("attach error: "+json.dumps(r["error"]))
        return r["result"]["channel"]

def drain(c, ch, timeout=0.3, credit=True, max_bytes=None):
    out=[]; closed=None; got=0
    while True:
        f = c.read_frame(timeout)
        if f is None: break
        if f[0]==ch and f[1]==DATA:
            out.append(f[2]); got+=len(f[2])
            if credit: c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
            if max_bytes and got>=max_bytes: break
        elif f[0]==ch and f[1]==CLOSE: closed=f[2]; break
    return b"".join(out), closed

def summarize(fp):
    import re
    seqs = re.findall(rb"\x1b\[[0-9;?=>!]*[A-Za-z@`~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[PX_^][^\x1b]*\x1b\\|\x1b[()][A-Za-z0-9]", fp)
    from collections import Counter
    kinds = Counter()
    for s in seqs:
        if s.startswith(b"\x1b["):
            m = re.match(rb"\x1b\[([?=>!]?)[0-9;]*([A-Za-z@`~])", s); kinds[("CSI "+m.group(1).decode()+m.group(2).decode()) if m else "CSI?"]+=1
        elif s.startswith(b"\x1b]"):
            kinds["OSC "+s[2:].split(b";")[0][:6].decode(errors="replace")]+=1
        else: kinds[s[:2].decode(errors="replace")]+=1
    text = re.sub(rb"\x1b\[[0-9;?=>!]*[A-Za-z@`~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[PX_^][^\x1b]*\x1b\\|\x1b[()][A-Za-z0-9]", b"", fp)
    return kinds, text

cmd = sys.argv[1]
if cmd == "paint":
    term = sys.argv[2]; hist = int(sys.argv[3]) if len(sys.argv)>3 else 0
    c = Conn(); ch = c.attach(term, history=hist, display={"fg":"#e0e0e0","bg":"#101010","cursor":"#ffffff","cell":[9,18]})
    fp, closed = drain(c, ch, 0.6)
    kinds, text = summarize(fp)
    print("first paint bytes:", len(fp)); print("head:", repr(fp[:400])); print("tail:", repr(fp[-300:]))
    print("sequence kinds:", dict(kinds))
    print("--- text (ctrl stripped, first 1200) ---"); print(text[:1200].decode(errors="replace"))
    c.send_frame(ch, CLOSE)
elif cmd == "queries":
    term = sys.argv[2]
    c = Conn(); ch = c.attach(term, display={"fg":"#e0e0e0","bg":"#101010","cursor":"#ffffff","cell":[9,18]})
    drain(c, ch, 0.5)
    # the probe script runs in the terminal; we only record what reaches the viewer and never answer
    script = sys.argv[3]
    c.send_frame(ch, DATA, (script+"\r").encode())
    out, closed = drain(c, ch, 1.5)
    import re
    print("viewer saw bytes:", len(out))
    for name, pat in [("DA1 CSI c", rb"\x1b\[c"), ("DA2 CSI >c", rb"\x1b\[>c"), ("XTVERSION CSI >q", rb"\x1b\[>0?q"), ("DSR 6n", rb"\x1b\[6n"), ("OSC11 bg?", rb"\x1b\]11;\?"), ("kitty ?u", rb"\x1b\[\?u"), ("XTGETTCAP", rb"\x1bP\+q"), ("DECRQSS", rb"\x1bP\$q"), ("OSC52 read", rb"\x1b\]52;c;\?"), ("CSI 14t", rb"\x1b\[14t"), ("CSI 16t", rb"\x1b\[16t"), ("CSI 18t", rb"\x1b\[18t"), ("DECRQM 2004", rb"\x1b\[\?2004\$p"), ("996n colorscheme", rb"\x1b\[\?996n"), ("OSC7501?", rb"\x1b\]7501;\?")]:
        print(f"  passed to viewer: {name}: {bool(re.search(pat, out))}")
    print("--- raw (last 1500) ---"); print(repr(out[-1500:]))
    c.send_frame(ch, CLOSE)
elif cmd == "flood":
    term = sys.argv[2]; secs = float(sys.argv[3])
    c = Conn(); ch = c.attach(term); drain(c, ch, 0.4)
    c.send_frame(ch, DATA, b"yes | head -c 200000000; echo FLOODDONE\r")
    t0=time.time(); got=0; frames=0; repaints=0; first=None
    # consume slowly: 16 KiB per 5 ms ~ 3 MB/s, crediting what we read
    while time.time()-t0 < secs:
        f = c.read_frame(0.5)
        if f is None: continue
        if f[0]==ch and f[1]==DATA:
            frames+=1; got+=len(f[2])
            if b"\x1b[!p" in f[2]: repaints+=1; first = first or (time.time()-t0, got)
            time.sleep(0.005)
            c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
    print(f"viewer consumed {got/1e6:.1f} MB in {frames} frames over {secs}s; repaint frames seen: {repaints}; first repaint at {first}")
    c.send_frame(ch, DATA, b"\x03"); drain(c, ch, 0.5)
    c.send_frame(ch, CLOSE)
elif cmd == "tput":
    term = sys.argv[2]; path = sys.argv[3]
    c = Conn(); ch = c.attach(term, cols=200, rows=50); drain(c, ch, 0.4)
    size = os.path.getsize(path)
    c.send_frame(ch, DATA, f"cat {path}; echo TPUTDONE\r".encode())
    t0=time.time(); got=0; frames=0
    while True:
        f = c.read_frame(10)
        if f is None: print("timeout"); break
        if f[0]==ch and f[1]==DATA:
            frames+=1; got+=len(f[2]); c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
            if b"TPUTDONE" in f[2]: break
    dt=time.time()-t0
    print(f"delivered {got/2**20:.1f} MiB to viewer in {dt:.2f}s = {got/2**20/dt:.1f} MiB/s (file {size/2**20:.1f} MiB, {frames} frames)")
    c.send_frame(ch, CLOSE)
elif cmd == "lat":
    term = sys.argv[2]; n = int(sys.argv[3])
    c = Conn(); ch = c.attach(term); drain(c, ch, 0.4)
    c.send_frame(ch, DATA, b"\x15"); drain(c, ch, 0.3)
    samples=[]
    for i in range(n):
        if i % 60 == 59: c.send_frame(ch, DATA, b"\x15"); drain(c, ch, 0.05)
        t0=time.perf_counter_ns(); c.send_frame(ch, DATA, b"a")
        got=b""
        while b"a" not in got:
            f=c.read_frame(2)
            if f is None: raise SystemExit("no echo")
            if f[0]==ch and f[1]==DATA: got+=f[2]; c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
        samples.append((time.perf_counter_ns()-t0)/1000)
    c.send_frame(ch, DATA, b"\x15"); samples.sort()
    q=lambda p: samples[int(len(samples)*p)-1]
    print(f"echo RTT us: n={len(samples)} p50={q(.5):.1f} p90={q(.9):.1f} p99={q(.99):.1f} max={samples[-1]:.1f}")
    c.send_frame(ch, CLOSE)
elif cmd == "run":
    c = Conn(framed=False); print(json.dumps(c.call_plain("terminal.run", json.loads(sys.argv[2])))[:600])
elif cmd == "call":
    c = Conn(framed=False); print(json.dumps(c.call_plain(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv)>3 else {}))[:3000])
if cmd == "queries2":
    term = sys.argv[2]; script = sys.argv[3]
    c = Conn(); ch = c.attach(term, display={"fg":"#e0e0e0","bg":"#101010","cursor":"#ffffff","cell":[9,18]})
    drain(c, ch, 0.5)
    c.send_frame(ch, DATA, (script+"\r").encode())
    out=b""; t0=time.time()
    while time.time()-t0 < 20:
        f = c.read_frame(1.0)
        if f is None: continue
        if f[0]==ch and f[1]==DATA:
            out+=f[2]; c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
            if b"QPEND" in out: break
    import re
    print("viewer saw bytes:", len(out))
    for name, pat in [("DA1 CSI c", rb"\x1b\[c"), ("DA2 CSI >c", rb"\x1b\[>c"), ("XTVERSION CSI >q", rb"\x1b\[>q"), ("DSR 6n", rb"\x1b\[6n"), ("OSC11 bg?", rb"\x1b\]11;\?"), ("OSC10 fg?", rb"\x1b\]10;\?"), ("OSC4 pal?", rb"\x1b\]4;1;\?"), ("kitty ?u", rb"\x1b\[\?u"), ("XTGETTCAP", rb"\x1bP\+q"), ("DECRQSS", rb"\x1bP\$q"), ("OSC52 read", rb"\x1b\]52;c;\?"), ("CSI 14t", rb"\x1b\[14t"), ("CSI 16t", rb"\x1b\[16t"), ("CSI 18t", rb"\x1b\[18t"), ("DECRQM 2004", rb"\x1b\[\?2004\$p"), ("996n", rb"\x1b\[\?996n"), ("OSC7501?", rb"\x1b\]7501;\?"), ("XTSMGRAPHICS", rb"\x1b\[\?2;1;0S")]:
        print(f"  passed to viewer (unanswered by core): {name}: {bool(re.search(pat, out))}")
    c.send_frame(ch, CLOSE)
