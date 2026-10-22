#!/usr/bin/env python3
"""Summarize collect output saved from run.sh: resumed count, startup audit
timings, and every panel that did not resume. Usage: summarize.py <file>..."""
import json
import sys

for f in sys.argv[1:]:
    text = open(f).read()
    decoder = json.JSONDecoder()
    objects, i = [], 0
    while (i := text.find("{", i)) != -1:
        try:
            obj, end = decoder.raw_decode(text, i)
        except ValueError:
            i += 1
            continue
        objects.append(obj)
        i = end
    d = next(o for o in reversed(objects) if "rows" in o)
    print(f.split("/")[-1], " | ".join(json.dumps(o) for o in objects if "rows" not in o))
    print("  resumed", d["resumed_on_screen"], "/", d["panels"], "mode", d["mode"])
    print("  audit", json.dumps(d["startup_audit"]))
    for r in d["rows"]:
        if not r["resumed_on_screen"]:
            print("   not resumed:", r["name"], r["decision"], r["skip_code"], r["reason"], r["ts"])
