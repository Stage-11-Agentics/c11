#!/usr/bin/env python3
"""List identifiers (code tokens only) with per-file counts, for building tables.

  idents.py [--match REGEX] [--files]    # prints  count  ident  [files]
"""
import os, re, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
import rename

def collect(root="."):
    per = collections.defaultdict(collections.Counter)  # ident -> file -> n
    for f in rename.swift_files(root):
        src = open(f, encoding="utf-8").read()
        lx = rename.Lexer(src); lx.scan(0, False)
        rel = os.path.relpath(f, root)
        for a, b in lx.idents:
            per[src[a:b]][rel] += 1
    return per

if __name__ == "__main__":
    rx = re.compile(sys.argv[sys.argv.index("--match") + 1]) if "--match" in sys.argv else None
    per = collect()
    for ident, c in sorted(per.items(), key=lambda kv: -sum(kv[1].values())):
        if rx and not rx.search(ident):
            continue
        extra = ""
        if "--files" in sys.argv:
            extra = "  " + ", ".join(f"{os.path.basename(k)}:{v}" for k, v in c.most_common(6))
        print(f"{sum(c.values()):6d}  {ident}{extra}")
