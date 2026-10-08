#!/usr/bin/env python3
"""Embed the markdown fixtures into index.html between the fixture markers.

Run after editing a fixture or the specimen:  python3 embed.py
The page must work from file://, so the markdown rides inside the page.
"""
import html
import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
FIX = HERE.parent / "fixtures"

# (doc id, tab number, tab title, repo path shown in the description bar, source file, writer)
DOCS = [
    ("messaging", 12, "messaging design", "docs/c11-messaging-primitive-design.md", FIX / "c11-messaging-primitive-design.md", "builder"),
    ("mailbox", 13, "mailbox guide", "docs/c11-mailbox-guide.md", FIX / "c11-mailbox-guide.md", "docs"),
    ("browser", 14, "browser port spec", "docs/agent-browser-port-spec.md", FIX / "agent-browser-port-spec.md", "planner"),
    ("plan", 15, "C11-184 plan", ".lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md", FIX / "task_01KYMTXQVWCXCF0TGN5ZWG341E.md", "orchestrator"),
    ("skill", 16, "markdown skill", "skills/c11-markdown/SKILL.md", FIX / "c11-markdown-SKILL.md", "maintainer"),
    ("specimen", 17, "reader specimen", "docs/design-prototypes/markdown-viewer/reader/specimen.md", HERE / "specimen.md", "cairn"),
]

parts = []
for doc_id, num, title, path, src, writer in DOCS:
    text = src.read_text(encoding="utf-8").replace("</script", "<\\/script")
    meta = json.dumps({"id": doc_id, "num": num, "title": title, "path": path, "writer": writer})
    parts.append(
        f'<script type="text/markdown" id="doc-{doc_id}" data-meta="{html.escape(meta)}">\n{text}</script>'
    )

block = "<!-- fixtures:begin -->\n" + "\n".join(parts) + "\n<!-- fixtures:end -->"
page = HERE / "index.html"
src = page.read_text(encoding="utf-8")
new, n = re.subn(r"<!-- fixtures:begin -->.*?<!-- fixtures:end -->", lambda m: block, src, flags=re.S)
if n != 1:
    raise SystemExit("fixture markers not found in index.html")
page.write_text(new, encoding="utf-8")
print(f"embedded {len(DOCS)} docs into {page.name}")
