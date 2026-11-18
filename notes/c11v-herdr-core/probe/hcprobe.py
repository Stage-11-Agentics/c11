import socket, struct, json, time, sys, statistics, select
SOCK = "/tmp/c11hc/herdr-core/c11spike.sock"
DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS = range(6)

class Conn:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(SOCK)
        self.buf = b""; self.id = 0
        self.call_plain("hello", {"framed": True, "generation": 1})
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

def drain(c, ch, out, timeout=0.3):
    while True:
        f = c.read_frame(timeout)
        if f is None: return
        if f[0]==ch and f[1]==DATA:
            out.append(f[2]); c.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
        elif f[0]==ch and f[1]==CLOSE: out.append(b"<CLOSE>"+f[2]); return

mode = sys.argv[1]
c = Conn()
r = c.call("terminal.attach", {"terminal":"t1","cols":100,"rows":30,"history":50})
print("attach ->", json.dumps(r)[:300])
ch = r["result"]["channel"]
first = []; drain(c, ch, first, 0.5)
fp = b"".join(first); print("first paint bytes:", len(fp)); print("first paint tail:", repr(fp[-300:]))
if mode == "raw":
    probe = b"printf '\\033]7;file://probe/tmp/x\\007\\033]8;;https://example.com\\007LINK\\033]8;;\\007 \\033[38;2;1;2;3mTRUECOLOR\\033[0m\\n'\r"
    c.send_frame(ch, DATA, probe); out=[]; drain(c, ch, out, 0.8); o=b"".join(out)
    for tag,needle in [("OSC 7 passthrough", b"\x1b]7;file://probe/tmp/x"), ("OSC 8 passthrough", b"\x1b]8;;https://example.com"), ("truecolor SGR verbatim", b"\x1b[38;2;1;2;3m")]:
        print(f"{tag}: {needle in o}")
    print("raw sample:", repr(o[-260:]))
elif mode == "lat":
    c.send_frame(ch, DATA, b"\x15"); drain(c, ch, [], 0.3)
    samples=[]
    for i in range(int(sys.argv[2]) if len(sys.argv)>2 else 2000):
        if i % 60 == 59: c.send_frame(ch, DATA, b"\x15"); drain(c, ch, [], 0.05)
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
