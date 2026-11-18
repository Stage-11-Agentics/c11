#!/usr/bin/env python3
"""Emit a Swift `ClaudeCapture` fixture (c11Tests/PromptInputGuardTests.swift)
from raw pty bytes, as the native prompt-region reader returns it
(ghostty src/terminal/prompt_region.zig): the cursor window (9 rows above the
cursor, 6 below, top-down) and the bottom window (the last 16 rows,
bottom-up), each under the 4096-cell budget. A cursor window cut mid-row keeps
the cut row's cells with no row entry and is incomplete; a bottom window drops
the cut row and stays complete.

usage: fixtures.py NAME RAW COLS ROWS UPTO "doc comment" [--redact TEXT ...]

A row containing a --redact TEXT (an operator's status line: home path,
account labels) is replaced by a placeholder of the same width.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay as vt

MAX_CELLS = 4096
REDACTED = "  [status line redacted]"

def lit(text):
    out = []
    for ch in text:
        o = ord(ch)
        if ch == '"': out.append('\\"')
        elif ch == "\\": out.append("\\\\")
        elif o < 0x20 or o == 0xA0 or 0x7F <= o < 0xA0: out.append("\\u{%04X}" % o)
        else: out.append(ch)
    return "".join(out)

def text_expr(text):
    parts, i = [], 0
    while i < len(text):
        j = i
        while j < len(text) and text[j] == text[i]: j += 1
        if j - i >= 6:
            parts.append(f'r("{lit(text[i])}", {j - i})')
        elif parts and parts[-1].startswith('"'):
            parts[-1] = parts[-1][:-1] + lit(text[i:j]) + '"'
        else:
            parts.append(f'"{lit(text[i:j])}"')
        i = j
    return " + ".join(parts) if parts else '""'

def spans(cells):
    out, cur, txt = [], None, ""
    for c in cells:
        st = (c.faint, c.italic, c.fg, c.bg)
        if st != cur and txt:
            out.append((cur, txt)); txt = ""
        cur = st; txt += c.ch or " "
    if txt: out.append((cur, txt))
    rendered = []
    for (faint, italic, fg, bg), t in out:
        args = [text_expr(t)]
        if faint: args.append("faint: true")
        if italic: args.append("italic: true")
        if fg is not None: args.append("fg: 0x%06X" % fg)
        if bg is not None: args.append("bg: 0x%06X" % bg)
        rendered.append("S(" + ", ".join(args) + ")")
    return "[" + ", ".join(rendered) + "]"

def row_cells(s, y, redact):
    cells = [c for c in s.grid[y] if c.ch != "\x00spacer"]
    text = "".join(c.ch or " " for c in cells)
    if any(r in text for r in redact):
        return [vt.Cell(ch) for ch in REDACTED.ljust(len(cells))]
    return cells

def gen(name, raw, cols, rows, upto, doc, redact):
    t = vt.Term(cols, rows)
    t.feed(open(raw, "rb").read()[:upto])
    s, cy = t.s, t.s.y
    first, last = cy - min(cy, 9), min(rows - 1, cy + 6)
    budget, cursor_rows, partial = MAX_CELLS, [], None
    for y in range(first, last + 1):
        if cols > budget:
            partial = row_cells(s, y, redact)[:budget]
            break
        cursor_rows.append(y); budget -= cols
    budget, bottom = MAX_CELLS, []
    for y in range(rows - 1, max(-1, rows - 1 - 16), -1):
        if cols > budget: break
        bottom.insert(0, y); budget -= cols
    out = [f"    /// {doc}", f"    static let {name} = ClaudeCapture(cursorX: {s.x}, cursorY: {cy}, rows: ["]
    out += [f"        ({y}, {spans(row_cells(s, y, redact))})," for y in cursor_rows]
    if partial is None:
        out.append("    ])")
    else:
        out.append("    ], partialRow: " + spans(partial) + ",")
        out.append("    bottomRows: [")
        out += [f"        ({y}, {spans(row_cells(s, y, redact))})," for y in bottom]
        out.append("    ])")
    return "\n".join(out)

if __name__ == "__main__":
    a = sys.argv[1:]
    redact = [a[i + 1] for i, x in enumerate(a) if x == "--redact"]
    print(gen(a[0], a[1], int(a[2]), int(a[3]), int(a[4]), a[5], redact))
