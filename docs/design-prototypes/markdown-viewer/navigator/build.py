#!/usr/bin/env python3
"""Build navigator/index.html: embed the five fixtures (with a few added cross-links) into template.html.

Run: python3 docs/design-prototypes/markdown-viewer/navigator/build.py
"""
import html
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE.parent / "fixtures"

# fixture file -> (virtual repo path, short tab title, "edited" age)
CORPUS = [
    ("c11-mailbox-guide.md", "docs/c11-mailbox-guide.md", "mailbox guide", "4m"),
    ("c11-messaging-primitive-design.md", "docs/c11-messaging-primitive-design.md", "messaging design", "2d"),
    ("agent-browser-port-spec.md", "docs/agent-browser-port-spec.md", "browser port spec", "8mo"),
    ("task_01KYMTXQVWCXCF0TGN5ZWG341E.md", ".lattice/notes/task_01KYMTXQVWCXCF0TGN5ZWG341E.md", "C11-184 plan", "6d"),
    ("c11-markdown-SKILL.md", "skills/c11-markdown/SKILL.md", "markdown skill", "3w"),
]

# Cross-links added to the embedded copies only (fixtures on disk are untouched).
# Each (old, new) must match exactly once.
ADDED_LINKS = {
    "c11-mailbox-guide.md": [
        ("see `docs/c11-messaging-primitive-design.md`.",
         "see [`docs/c11-messaging-primitive-design.md`](c11-messaging-primitive-design.md)."),
        ("the inbox directory is still keyed on the recipient's title.",
         "the inbox directory is still keyed on the recipient's title. The same stable-handle rule governs the browser port; see [Object/Handle Semantics](agent-browser-port-spec.md#objecthandle-semantics)."),
    ],
    "c11-messaging-primitive-design.md": [
        ("- Surface addressing via **surface names** (from CMUX-11 nameable-panes metadata); no separate mailbox-alias layer",
         "- Surface addressing via **surface names** (from CMUX-11 nameable-panes metadata); no separate mailbox-alias layer (operator detail: [Addressing](c11-mailbox-guide.md#addressing-stable-handles-and-the-title-fallback))"),
        ("### Envelope schema (v1, LOCKED)\n",
         "### Envelope schema (v1, LOCKED)\n\nOperator-facing field notes live in the [mailbox guide](c11-mailbox-guide.md#envelope-schema-v1-locked).\n"),
        ("Every dispatch event appends one NDJSON line to `$C11_STATE/mailboxes/_dispatch.log`:",
         "Every dispatch event appends one NDJSON line to `$C11_STATE/mailboxes/_dispatch.log` (field reference: [Dispatch log](c11-mailbox-guide.md#dispatch-log-_dispatchlog)):"),
    ],
    "c11-markdown-SKILL.md": [
        ("This is the right default unless the operator explicitly asks for separate files.",
         "This is the right default unless the operator explicitly asks for separate files. To hand the trail file to the next agent, send its path over the mailbox ([durable handoff](../../docs/c11-mailbox-guide.md#durable-handoff))."),
        ("| [references/live-reload.md](references/live-reload.md) | File watching behavior, atomic writes, edge cases |",
         "| [references/live-reload.md](references/live-reload.md) | File watching behavior, atomic writes, edge cases |\n| [C11-184 plan](../../.lattice/notes/task_01KYMTXQVWCXCF0TGN5ZWG341E.md#implementation-phases) | A real Lattice plan as a markdown surface: phases, task lists |"),
    ],
    "task_01KYMTXQVWCXCF0TGN5ZWG341E.md": [
        ("### Phase 6 — localization and skill contract\n",
         "### Phase 6 — localization and skill contract\n\nStaged-section precedent: the [c11-markdown skill](../../skills/c11-markdown/SKILL.md#always-title--description-per-surface).\n"),
    ],
}


def main():
    blocks = []
    for i, (fname, path, short, ago) in enumerate(CORPUS):
        text = (FIX / fname).read_text()
        for old, new in ADDED_LINKS.get(fname, []):
            n = text.count(old)
            assert n == 1, f"{fname}: expected 1 match for {old[:60]!r}, got {n}"
            text = text.replace(old, new)
        assert "</script" not in text.lower(), fname
        blocks.append(
            f'<script type="text/markdown" id="doc-{i}" data-path="{html.escape(path)}" '
            f'data-short="{html.escape(short)}" data-ago="{ago}">\n{text}</script>'
        )
    tpl = (HERE / "template.html").read_text()
    assert "<!--__CORPUS__-->" in tpl
    out = tpl.replace("<!--__CORPUS__-->", "\n".join(blocks))
    (HERE / "index.html").write_text(out)
    print(f"wrote {HERE / 'index.html'} ({len(out):,} bytes)")


if __name__ == "__main__":
    main()
