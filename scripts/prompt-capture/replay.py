#!/usr/bin/env python3
"""Replay raw pty bytes into a cell grid and emit the prompt-region window
the native reader (ghostty prompt_region.zig, anchor .cursor) would capture:
9 rows above the cursor, 6 below, every column, faint/italic/truecolor bits.

usage: replay.py RAW COLS ROWS [--upto BYTES] [--json]

Supports what Claude Code and Grok emit: SGR (faint, italic, inverse, truecolor),
cursor moves, erase, scroll regions and SU/SD, and the alternate screen.
Other private sequences are ignored. Check a replay against `c11 read-screen`.
"""
import json, re, sys, unicodedata

class Cell:
    __slots__ = ("ch", "faint", "italic", "fg", "bg", "inverse")
    def __init__(self, ch="", faint=False, italic=False, fg=None, bg=None, inverse=False):
        self.ch, self.faint, self.italic, self.fg, self.bg, self.inverse = ch, faint, italic, fg, bg, inverse

class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = self.blank()
        self.wrap = [False] * rows
        self.cont = [False] * rows
        self.x = self.y = 0
        self.pending = False
        self.top, self.bot = 0, rows - 1
        self.saved = (0, 0)

    def blank(self):
        return [[Cell() for _ in range(self.cols)] for _ in range(self.rows)]

class Term:
    def __init__(self, cols, rows):
        self.primary = Screen(cols, rows)
        self.alt = Screen(cols, rows)
        self.s = self.primary
        self.reset_sgr()

    def reset_sgr(self):
        self.faint = self.italic = self.inverse = False
        self.fg = self.bg = None

    def sgr(self, params):
        ps = [int(p) if p else 0 for p in re.split(r"[;:]", params)] if params else [0]
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0: self.reset_sgr()
            elif p == 2: self.faint = True
            elif p == 22: self.faint = False
            elif p == 3: self.italic = True
            elif p == 23: self.italic = False
            elif p == 7: self.inverse = True
            elif p == 27: self.inverse = False
            elif p in (38, 48):
                if i + 1 < len(ps) and ps[i + 1] == 2 and i + 4 < len(ps):
                    v = (ps[i + 2] << 16) | (ps[i + 3] << 8) | ps[i + 4]
                    if p == 38: self.fg = v
                    else: self.bg = v
                    i += 4
                elif i + 1 < len(ps) and ps[i + 1] == 5:
                    if p == 38: self.fg = None
                    else: self.bg = None
                    i += 2
            elif p == 39: self.fg = None
            elif p == 49: self.bg = None
            elif 30 <= p <= 37 or 90 <= p <= 97: self.fg = None
            elif 40 <= p <= 47 or 100 <= p <= 107: self.bg = None
            i += 1

    def linefeed(self):
        s = self.s
        if s.y == s.bot:
            del s.grid[s.top]; s.grid.insert(s.bot, [Cell() for _ in range(s.cols)])
            del s.wrap[s.top]; s.wrap.insert(s.bot, False)
            del s.cont[s.top]; s.cont.insert(s.bot, False)
        elif s.y < s.rows - 1:
            s.y += 1

    def put(self, ch):
        s = self.s
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if unicodedata.combining(ch) or ch == "‍" or 0xFE00 <= ord(ch) <= 0xFE0F:
            px = max(0, s.x - 1)
            s.grid[s.y][px].ch += ch
            return
        if s.pending or s.x + w > s.cols:
            s.wrap[s.y] = True
            s.x = 0
            self.linefeed()
            s.cont[s.y] = True
            s.pending = False
        c = Cell(ch, self.faint, self.italic, self.fg, self.bg, self.inverse)
        s.grid[s.y][s.x] = c
        if w == 2 and s.x + 1 < s.cols:
            s.grid[s.y][s.x + 1] = Cell("\x00spacer")
        s.x += w
        if s.x >= s.cols:
            s.x = s.cols - 1
            s.pending = True

    def erase_cells(self, row, a, b):
        s = self.s
        for x in range(a, b):
            s.grid[row][x] = Cell(bg=self.bg)

    def csi(self, priv, params, inter, final):
        s = self.s
        if priv in ("<", ">", "="):
            return
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
        n = (nums[0] if nums and nums[0] else 1)
        if priv == "?":
            if final in "hl" and not inter:
                for m in nums:
                    if m in (1049, 1047, 47):
                        if final == "h" and self.s is self.primary:
                            self.primary.saved = (self.primary.x, self.primary.y)
                            self.s = self.alt
                            self.alt.grid = self.alt.blank()
                            self.alt.wrap = [False] * self.alt.rows
                            self.alt.cont = [False] * self.alt.rows
                            self.alt.x, self.alt.y = self.primary.x, self.primary.y
                        elif final == "l" and self.s is self.alt:
                            self.s = self.primary
                            self.s.x, self.s.y = self.s.saved
            return
        if inter:
            return
        s.pending = False if final in "HfABCDGdKJ" else s.pending
        if final == "m": self.sgr(params)
        elif final in "Hf":
            r = (nums[0] if len(nums) > 0 and nums[0] else 1) - 1
            c = (nums[1] if len(nums) > 1 and nums[1] else 1) - 1
            s.y, s.x = min(max(r, 0), s.rows - 1), min(max(c, 0), s.cols - 1)
        elif final == "A": s.y = max(s.top if s.y >= s.top else 0, s.y - n)
        elif final == "B": s.y = min(s.bot if s.y <= s.bot else s.rows - 1, s.y + n)
        elif final == "C": s.x = min(s.cols - 1, s.x + n)
        elif final == "D": s.x = max(0, s.x - n)
        elif final == "G": s.x = min(s.cols - 1, n - 1)
        elif final == "d": s.y = min(s.rows - 1, n - 1)
        elif final == "K":
            mode = nums[0] if nums else 0
            if mode == 0: self.erase_cells(s.y, s.x, s.cols)
            elif mode == 1: self.erase_cells(s.y, 0, s.x + 1)
            else: self.erase_cells(s.y, 0, s.cols)
            if mode in (0, 2): s.wrap[s.y] = False
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 0:
                self.erase_cells(s.y, s.x, s.cols)
                for r in range(s.y + 1, s.rows): self.erase_cells(r, 0, s.cols); s.wrap[r] = s.cont[r] = False
            elif mode == 1:
                for r in range(0, s.y): self.erase_cells(r, 0, s.cols)
                self.erase_cells(s.y, 0, s.x + 1)
            else:
                for r in range(s.rows): self.erase_cells(r, 0, s.cols); s.wrap[r] = s.cont[r] = False
        elif final in "ST":
            for _ in range(n):
                if final == "S":
                    del s.grid[s.top]; s.grid.insert(s.bot, [Cell(bg=self.bg) for _ in range(s.cols)])
                    del s.wrap[s.top]; s.wrap.insert(s.bot, False)
                    del s.cont[s.top]; s.cont.insert(s.bot, False)
                else:
                    del s.grid[s.bot]; s.grid.insert(s.top, [Cell(bg=self.bg) for _ in range(s.cols)])
                    del s.wrap[s.bot]; s.wrap.insert(s.top, False)
                    del s.cont[s.bot]; s.cont.insert(s.top, False)
        elif final == "r":
            t = (nums[0] if len(nums) > 0 and nums[0] else 1) - 1
            b = (nums[1] if len(nums) > 1 and nums[1] else s.rows) - 1
            s.top, s.bot = t, b
            s.x = s.y = 0

    def feed(self, data):
        text = data.decode("utf-8", errors="replace")
        i, n = 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= n: break
                nx = text[i + 1]
                if nx == "[":
                    m = re.compile(r"\x1b\[([<>?=]?)([0-9;:]*)([ -/]*)([@-~])").match(text, i)
                    if not m: i += 2; continue
                    self.csi(*m.groups()); i = m.end(); continue
                if nx in "]_P^":
                    j = i + 2
                    while j < n and text[j] != "\x07" and not (text[j] == "\x1b" and j + 1 < n and text[j + 1] == "\\"):
                        j += 1
                    i = j + (1 if j < n and text[j] == "\x07" else 2); continue
                if nx == "7": self.s.saved = (self.s.x, self.s.y); i += 2; continue
                if nx == "8": self.s.x, self.s.y = self.s.saved; self.s.pending = False; i += 2; continue
                if nx in "()*+": i += 3; continue
                i += 2; continue
            if ch == "\r": self.s.x = 0; self.s.pending = False
            elif ch == "\n": self.linefeed(); self.s.pending = False
            elif ch == "\b": self.s.x = max(0, self.s.x - 1); self.s.pending = False
            elif ch == "\t": self.s.x = min(self.s.cols - 1, (self.s.x // 8 + 1) * 8)
            elif ch == "\x07": pass
            elif ord(ch) < 0x20 or ch == "\x7f": pass
            else: self.put(ch)
            i += 1

def region(term):
    s = term.s
    first = s.y - min(s.y, 9)
    last = min(s.rows - 1, s.y + 6)
    rows = []
    for y in range(first, last + 1):
        cells = []
        for c in s.grid[y]:
            if c.ch == "\x00spacer":
                continue
            cells.append({"t": c.ch if c.ch else " ", "f": c.faint, "i": c.italic, "fg": c.fg, "bg": c.bg, "inv": c.inverse})
        rows.append({"y": y, "wrap": s.wrap[y], "cont": s.cont[y], "cells": cells})
    return {"cursorX": s.x, "cursorY": s.y, "pendingWrap": s.pending, "cols": s.cols, "rows": rows}

def show(reg):
    print(f"cursor x={reg['cursorX']} y={reg['cursorY']}")
    for r in reg["rows"]:
        line = ""
        for c in r["cells"]:
            line += c["t"]
        mark = ">" if r["y"] == reg["cursorY"] else " "
        styles = "".join("f" if c["f"] else ("i" if c["i"] else ("v" if c["inv"] else ".")) for c in r["cells"])
        print(f"{mark}{r['y']:3d} |{line.rstrip()}|")
        if any(ch != "." for ch in styles.rstrip(".")):
            print(f"     |{styles.rstrip('.')}|")

if __name__ == "__main__":
    raw, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    data = open(raw, "rb").read()
    if "--upto" in sys.argv:
        data = data[: int(sys.argv[sys.argv.index("--upto") + 1])]
    t = Term(cols, rows)
    t.feed(data)
    reg = region(t)
    if "--json" in sys.argv:
        print(json.dumps(reg))
    else:
        show(reg)
