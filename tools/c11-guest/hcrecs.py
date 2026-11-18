#!/usr/bin/env python3
"""hcrecs.py <hc binary> [--all]: the session's hc terminals as full records (C11H-31). GUEST SIDE: guest.sh's `hcrecs` verb runs
it with the hc environment (HC_SESSION, HC_SOCKET) already set; the host self-test runs it against a fake hc.

`hc ls --json` (hc 0.1.16) prints a short row per terminal: address, agent, cwd, state, turn. No labels and no pid (cli.rs
`short`; real output in evidence/C11H-24/guest/diag/panel.txt), so nothing can join a terminal to a c11 panel from it.
`hc get <address> --json` prints the whole record, labels and pid included (real output: evidence/C11H-13/guest/ticker-get.json).
This lists with `ls` and then reads each terminal with `get`.

Prints `{"terminals": [...], "hidden_finished": n, "source": "hc ls + hc get"}`, the shape of `hc ls --json`, so readers of
`hc ls` read it unchanged. Each terminal is its get record, with ls's address kept; a terminal whose get fails keeps its ls row
plus "get_error". Exit: hc ls's own exit code and stderr when ls fails (no core socket, no core), else 0.
"""
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

GET_TIMEOUT_S = 10


def hc(binary, *args, timeout=20):
    return subprocess.run([binary, *args], capture_output=True, text=True, timeout=timeout)


def record(binary, row):
    addr = row.get("address")
    if not addr:
        return dict(row, get_error="no address in hc ls")
    try:
        r = hc(binary, "get", str(addr), "--json", timeout=GET_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return dict(row, get_error=f"hc get {addr} over {GET_TIMEOUT_S} s")
    try:
        rec = json.loads(r.stdout, strict=False) if r.returncode == 0 else None
    except ValueError:
        rec = None
    if not isinstance(rec, dict) or "error" in rec:
        why = (r.stderr or r.stdout or f"exit {r.returncode}").strip().splitlines()
        return dict(row, get_error=(why[-1] if why else f"exit {r.returncode}")[:200])
    return {**row, **rec, "address": addr}


def main(argv):
    if len(argv) < 2:
        print("usage: hcrecs.py <hc binary> [--all]", file=sys.stderr)
        return 2
    binary, extra = argv[1], (["--all"] if "--all" in argv[2:] else [])
    ls = hc(binary, "ls", "--json", *extra)
    if ls.returncode != 0:
        sys.stderr.write(ls.stderr or ls.stdout)
        return ls.returncode
    try:
        d = json.loads(ls.stdout, strict=False)
    except ValueError:
        print(f"hc ls gave no JSON: {ls.stdout[:200]!r}", file=sys.stderr)
        return 1
    rows = [t for t in d.get("terminals", []) if isinstance(t, dict)] if isinstance(d, dict) else []
    with ThreadPoolExecutor(max_workers=8) as pool:
        terms = list(pool.map(lambda t: record(binary, t), rows))
    out = {"terminals": terms, "hidden_finished": d.get("hidden_finished"), "source": "hc ls + hc get"}
    if isinstance(d, dict) and "machines" in d:
        out["machines"] = d["machines"]
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
