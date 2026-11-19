#!/usr/bin/env python3
"""Offline relay check for the Linux c11: runs it against a private hc core with no c11 app on the other end.

    tools/linux-cli/relay-offline-test.py <path to c11> <hc core socket ending /.local/share/c11/run/c11.sock>

What it proves without the app: `c11 relay-pickup` reads a pickup document, deletes it and exports the credential;
the relayed verbs (rename-panel, set-description, raise-flag, mailbox send, mailbox recv --ack) write a signed request
into a relay slot, wait out the claim bound, cancel it, and report `relay_unreachable`; telemetry (set-status) lands in
the spool instead. A real round trip needs c11 on the Mac claiming the slot (C11H-191's end-to-end proof).
"""
import json, os, secrets, socket, subprocess, sys, time, uuid

c11, sock_path = sys.argv[1], sys.argv[2]


class HC:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.n = 0
        assert self.call("hello", {"generation": 1})["generation"] == 1

    def call(self, method, params):
        self.n += 1
        self.f.write((json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n").encode())
        self.f.flush()
        while True:
            msg = json.loads(self.f.readline())
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg["result"]

    def get(self, name):
        r = self.call("doc.get", {"name": name})
        return r.get("value"), r.get("version")

    def set(self, name, value, version):
        return self.call("doc.set", {"name": name, "value": value, "version": version})


hc = HC(sock_path)
panel, workspace, creation = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
link = secrets.token_hex(8)
key, pad = secrets.token_bytes(32), secrets.token_bytes(32)
masked = bytes(a ^ b for a, b in zip(key, pad))
pickup_name = "c11h.relay.k." + creation.replace("-", "")[:16]
_, v = hc.get(pickup_name)
hc.set(pickup_name, {"p": 2, "lk": link, "creation": creation, "m": masked.hex()}, v or 0)

env = {k: v for k, v in os.environ.items() if not k.startswith(("C11", "CMUX", "HC_"))}
env.update({"C11_RELAY_HC_SOCKET": sock_path, "C11_RELAY_SESSION": "c11", "C11_PANEL_ID": panel,
            "C11_WORKSPACE_ID": workspace, "HC_TERMINAL_ID": "linuxbox/t99", "C11_RELAY_CLAIM_MS": "300"})
results = []


def run(name, args, extra=None, expect=None):
    e = dict(env, **(extra or {}))
    t = time.monotonic()
    p = subprocess.run([c11] + args, env=e, capture_output=True, text=True, timeout=60)
    ms = int((time.monotonic() - t) * 1000)
    out = (p.stdout + p.stderr).strip().replace("\n", " | ")
    ok = expect(p, out) if expect else True
    results.append((name, ok, ms, p.returncode, out[:220]))
    return p, out


# 1. relay-pickup: exports the credential and deletes the document
p, out = run("relay-pickup", ["relay-pickup"], {"C11_RELAY_PICKUP": f"{link}:{creation}:{pad.hex()}"},
             lambda p, o: f"export C11_RELAY_AUTH='2:{link}:{creation}:{key.hex()}'" == p.stdout.strip())
gone = hc.get(pickup_name)[0] is None
results.append(("pickup document deleted", gone, 0, 0, ""))
env["C11_RELAY_AUTH"] = f"2:{link}:{creation}:{key.hex()}"

unreachable = lambda p, o: p.returncode != 0 and "relay_unreachable" in o
for name, args in [("rename-panel", ["rename-panel", "--panel", panel, "Linuxbox relay test"]),
                   ("set-description", ["set-description", "--panel", panel, "offline relay test"]),
                   ("raise-flag", ["raise-flag", "--panel", panel, "offline relay test"]),
                   ("mailbox send", ["mailbox", "send", "--to", "client-vela-setup", "offline relay test"]),
                   ("mailbox recv --ack", ["mailbox", "recv", "--ack"])]:
    run(name, args, expect=unreachable)

# Every slot is free again: each unclaimed request was cancelled by compare-and-set
busy = [i for i in range(32) if hc.get("c11h.relay.r%02d" % i)[0] not in (None, {}, "")]
results.append(("slots cancelled", not busy, 0, 0, f"busy slots: {busy}" if busy else ""))

# Telemetry spools when unclaimed (the core's documents outlive it, so count what this run adds)
def spool_records():
    doc = hc.get("c11h.relay.spool")[0] or {}
    return doc.get("records", []) if isinstance(doc, dict) else [], doc


before, _ = spool_records()
run("set-status (spools)", ["set-status", "linuxbox", "offline", "--panel", panel],
    expect=lambda p, o: p.returncode != 0 and "spool" in o.lower())
records, spool = spool_records()
added = len(records) - len(before)
results.append(("spool holds the record", added == 1, 0, 0, f"{added} new record(s), protocol {spool.get('p')}"))

w = max(len(r[0]) for r in results)
for name, ok, ms, rc, out in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name:<{w}}  {ms:>5} ms  rc={rc}  {out}")
sys.exit(0 if all(r[1] for r in results) else 1)
