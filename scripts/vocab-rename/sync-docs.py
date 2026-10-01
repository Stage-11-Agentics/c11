#!/usr/bin/env python3
"""Rewrite source paths and type names that the passes renamed in the docs an agent reads first
(CLAUDE.md, docs/DEVELOPMENT.md, docs/adding-a-new-agent.md, docs/agent-registry-design.md).

  sync-docs.py            # reads the @path rows of pass-2a/2b tables plus the type renames below

Planning documents under docs/ and .lattice/ describe the code as it was when they were written and are left alone.
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DOCS = ["CLAUDE.md", "docs/DEVELOPMENT.md", "docs/adding-a-new-agent.md", "docs/agent-registry-design.md"]
TYPES = {"TabItemView": "WorkspaceRowView", "SurfaceSearchOverlay": "TabSearchOverlay",
         "SurfaceMetadataStore": "TabMetadataStore", "SurfaceTitleBarView": "TabTitleBarView"}


PHRASES = [("`@ObservedObject` (besides `tab`)", "`@ObservedObject` (besides `workspace`)"),
           ("Do not read `tabManager` or `notificationStore`", "Do not read `workspaceManager` or `notificationStore`")]


def path_rows():
    rows = []
    for t in ("pass-2a.tsv", "pass-2b.tsv"):
        for line in open(os.path.join(HERE, t), encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if cols[0] == "@path":
                rows.append((cols[1], cols[2]))
    return rows


def main():
    rows = path_rows()
    pairs = []
    for old, new in rows:
        pairs.append((old, new))
        pairs.append((os.path.relpath(old, "Sources"), os.path.relpath(new, "Sources")))  # `Panels/X.swift` in tables
        pairs.append((os.path.basename(old), os.path.basename(new)))
    # longest first so a full path wins over its basename
    pairs = sorted(set(pairs), key=lambda p: -len(p[0]))
    for doc in DOCS:
        path = os.path.join(ROOT, doc)
        text = open(path, encoding="utf-8").read()
        orig = text
        for old, new in pairs:
            text = re.sub(r"(?<![\w/])" + re.escape(old) + r"(?![\w])", new, text)
        for old, new in PHRASES:
            text = text.replace(old, new)
        for old, new in TYPES.items():
            text = re.sub(r"\b" + old + r"\b", new, text)
        if text != orig:
            open(path, "w", encoding="utf-8").write(text)
            print(f"  [docs] {doc}")


if __name__ == "__main__":
    main()
