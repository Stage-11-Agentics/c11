#!/usr/bin/env python3
"""Rewrite source paths and type names that the passes renamed in the docs an agent reads first
(CLAUDE.md, docs/DEVELOPMENT.md, docs/adding-a-new-agent.md, docs/agent-registry-design.md).

  sync-docs.py            # reads the @path rows of pass-2a/2b/3 tables plus the type renames below
  sync-docs.py r8a r8b r8c  # C11-337: only these passes' @path rows and type renames

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


PASSES = ("2a", "2b", "3")


def path_rows():
    rows = []
    for t in (f"pass-{p}.tsv" for p in PASSES):
        for line in open(os.path.join(HERE, t), encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if cols[0] == "@path":
                rows.append((cols[1], cols[2]))
    return rows


def type_rows():
    """Type renames of the evidence passes (ev:T rows) that the docs may name."""
    out = {}
    for t in ("pass-3.tsv",) if PASSES == ("2a", "2b", "3") else (f"pass-{p}.tsv" for p in PASSES):
        for line in open(os.path.join(HERE, t), encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and (cols[4] == "ev:T" or (cols[4] in ("ev:X", "ev:Test") and cols[0][:1].isupper())):
                scoped = any(g and not g.startswith("!") and not any(c in g for c in "*?[") for g in cols[2].split(","))
                if scoped or re.fullmatch(r"[A-Z][a-z]+", cols[0]):
                    continue  # a row scoped to named files (a generic `Tab` -> `PanelObject`), or a bare word such as `Tab`, is not a doc-wide type name
                out[cols[0]] = cols[1]
    return out


def main():
    global PASSES
    if len(sys.argv) > 1:
        PASSES = tuple(sys.argv[1:])
    rows = path_rows()
    pairs = []
    for old, new in rows:
        pairs.append((old, new))
        if old.endswith(".swift"):
            pairs.append((os.path.relpath(old, "Sources"), os.path.relpath(new, "Sources")))  # `Panels/X.swift` in tables
            pairs.append((os.path.basename(old), os.path.basename(new)))
        else:  # a directory: `Tabs/X.swift` in tables; a bare `Tabs` is also a prose word
            pairs.append((os.path.relpath(old, "Sources") + "/", os.path.relpath(new, "Sources") + "/"))
    # longest first so a full path wins over its basename
    pairs = sorted(set(pairs), key=lambda p: -len(p[0]))
    for doc in DOCS:
        path = os.path.join(ROOT, doc)
        text = open(path, encoding="utf-8").read()
        orig = text
        for old, new in pairs:
            text = re.sub(r"(?<![\w/])" + re.escape(old) + ("" if old.endswith("/") else r"(?![\w])"), new, text)
        for old, new in PHRASES if PASSES == ("2a", "2b", "3") else ():
            text = text.replace(old, new)
        for old, new in {**(TYPES if PASSES == ("2a", "2b", "3") else {}), **type_rows()}.items():
            text = re.sub(r"\b" + old + r"\b", new, text)
        if text != orig:
            open(path, "w", encoding="utf-8").write(text)
            print(f"  [docs] {doc}")


if __name__ == "__main__":
    main()
