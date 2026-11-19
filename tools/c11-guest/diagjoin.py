#!/usr/bin/env python3
"""diagjoin.py: the kit's `diag` listing when C11_DIAG_VERB is unset (C11H-31). GUEST SIDE (guest.sh `diag`); host-tested.

Inputs (environment):
  C11_TREE    `c11 --id-format both tree --json`: the app's terminal panels (the walk the kit's tq uses)
  C11_HCRECS  the kit's `hcrecs --all`: hc terminals as full `hc get` records, each with the labels the app wrote
               (c11.panel=<panel UUID>, Sources/HC/HCManagedSession.swift) and the pid. `hc ls --json` itself prints no
               labels and no pid, so the join cannot use it.
  C11_HCDIAG  `c11 hc-diagnostics --json` (optional): per panel, panel_id, terminal, tty, pid, lifecycle, serving_build.
               Used for hc_build, and for tty/pid when the hc record has none; hc's own record decides the lifecycle.
  C11_DIAG_PS 0 = do not ask `ps` for a pid's tty (host self-test).

Prints {"panels": [{"panel", "ref", "terminal", "tty", "pid", "lifecycle", "hc_build", "source"}]}. lifecycle: live (an hc
terminal labelled for the panel is live), ended (only finished ones), unresolved (none: the plain-shell fallback, or a
terminal not yet created).
"""
import json
import os
import subprocess
import sys

ENDED = {"ended", "exited", "finished", "closed", "dead", "removed"}


def load(name, default):
    try:
        v = json.loads(os.environ.get(name) or "", strict=False)
        return v if isinstance(v, type(default)) else default
    except ValueError:
        return default


def labels(t):
    lab = t.get("labels") or {}
    if isinstance(lab, list):
        lab = dict(x.split("=", 1) for x in lab if isinstance(x, str) and "=" in x)
    return lab if isinstance(lab, dict) else {}


def panels(o, out):
    if isinstance(o, dict):
        if o.get("type") == "terminal" and "id" in o:
            out.append(o)
        for v in o.values():
            panels(v, out)
    elif isinstance(o, list):
        for v in o:
            panels(v, out)
    return out


def tty_of(pid):
    if not pid or os.environ.get("C11_DIAG_PS") == "0":
        return None
    r = subprocess.run(["/bin/ps", "-o", "tty=", "-p", str(pid)], capture_output=True, text=True)
    return r.stdout.strip() or None


def main():
    tree = load("C11_TREE", {})
    recs = load("C11_HCRECS", {}).get("terminals", [])
    diag = {str(p.get("panel_id", "")).upper(): p for p in load("C11_HCDIAG", {}).get("panels", []) if isinstance(p, dict)}
    by_panel = {}
    for t in recs:
        if not isinstance(t, dict):
            continue
        key = str(labels(t).get("c11.panel", "")).upper()
        if key:
            by_panel.setdefault(key, []).append(t)
    out = []
    for p in panels(tree, []):
        pid_key = str(p["id"]).upper()
        ts = by_panel.get(pid_key, [])
        live = [t for t in ts if str(t.get("state", "")).lower() == "live"]
        t = live[0] if live else (ts[-1] if ts else None)
        d = diag.get(pid_key, {})
        if t is None:
            lifecycle = "unresolved"
        elif live:
            lifecycle = "live"
        else:
            lifecycle = "ended" if str(t.get("state", "")).lower() in ENDED else str(t.get("state") or "unresolved")
        pid = (t or {}).get("pid") or d.get("pid")
        out.append({"panel": p["id"], "ref": p.get("ref"), "terminal": (t or {}).get("address"),
                    "tty": (tty_of(pid) if t and t.get("pid") else None) or d.get("tty"), "pid": pid,
                    "lifecycle": lifecycle, "hc_build": d.get("serving_build"),
                    "source": "tree+hc-get" + ("+hc-diagnostics" if d else "")})
    print(json.dumps({"panels": out}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
