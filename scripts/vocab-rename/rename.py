#!/usr/bin/env python3
"""Token-aware Swift identifier renamer (C11-248).

Applies a TSV symbol table of whole-identifier renames to Swift sources.

  rename.py apply <table.tsv> [--root DIR] [--dry-run] [--no-git]

Table format (one entry per line, `#` comments and blank lines ignored):

  old<TAB>new[<TAB>glob[,glob...][<TAB>fallback[<TAB>flags]]]
                                        identifier rename; optional repo-relative
                                        globs restrict where it applies (prefix a
                                        glob with `!` to exclude). If `new` already
                                        occurs in the same member (a shadowing
                                        hazard), `fallback` is used there instead;
                                        with no usable fallback the token is left
                                        alone and reported as COLLISION. Flag
                                        `noimplicit` skips enum case declarations and
                                        leading-dot implicit members (`.tabs`);
                                        `labelonly` renames only call-site argument
                                        labels; `recvmgr` renames only on a receiver named
                                        like a manager (`workspaceManager.tabs`).
  @path<TAB>old<TAB>new                 file or directory rename (git mv, then
                                        project.pbxproj path edits)
  @keep<TAB>glob<TAB>regex<TAB>name,name  in files matching glob, members whose source
                                        text matches regex keep those old names
                                        (vendor/leaf use that shares a generic name)
  @taint<TAB>glob<TAB>rhs-regex<TAB>name=target,...
                                        in matching files, names whose binding site
                                        (let/for/guard/param) derives from the regex
                                        (a bonsplit value) are renamed per member
  @receiver<TAB>Type.                    members accessed as `Type.name` always follow the rename,
                                        even in files the globs exclude
  @fix<TAB>file<TAB>old text<TAB>new text   exact one-off text edit applied after the renames
                                        (\\n = newline); must match exactly once, else
                                        the run reports FIXUP STALE and exits non-zero
  @delete<TAB>file<TAB>exact line       delete that whole line (stripped compare)
                                        from the file, if present

Rules:
  * Only identifier tokens are touched: never string-literal contents, never
    comments. Identifiers inside string interpolations `\\( ... )` ARE renamed.
  * Exact, case-sensitive whole-token match. `$old` (property-wrapper
    projection) follows `old`.
  * A token qualified by a vendor receiver (`Bonsplit.`, `bonsplitController.`,
    `controller.`) is never renamed.
  * Cases of implicit-raw-value `String` enums are pinned: `case a` -> `case b = "a"`.
  * Codable properties/cases without CodingKeys that get renamed are reported as
    CODABLE hazards (pin by hand, record as `# manual:` in the table).
  * Idempotent: re-running on renamed code is a no-op. A table whose `new`
    name is also an `old` name (without disjoint globs) is rejected.
  * Never edits vendor/ or ghostty/.
"""
import fnmatch
import os
import re
import subprocess
import sys

SCAN_DIRS = ["Sources", "CLI", "c11Tests", "c11UITests"]
SKIP_PARTS = ("/vendor/", "/ghostty/")
IDENT_START = re.compile(r"[A-Za-z_\u0080-￿]")
IDENT_CHAR = re.compile(r"[A-Za-z0-9_\u0080-￿]")


def load_table(path):
    renames = {}  # old -> list of (new, [globs])
    paths = []
    deletes = []
    keeps = []
    callees = {}  # callee/type name -> "keep" | "rename"
    taints = []  # (glob, regex, {name: target})
    receivers = []  # member receivers whose members always follow the rename (e.g. "GhosttyNotificationKey.")
    fixes = []  # (file, old text, new text): exact one-off edits, written as \\n for newlines
    with open(path, encoding="utf-8") as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if cols[0] == "@receiver":
                receivers.append(cols[1])
                continue
            if cols[0] == "@fix":
                if len(cols) != 4:
                    sys.exit(f"{path}:{ln}: @fix needs file, old, new")
                fixes.append((cols[1], cols[2].replace("\\n", "\n"), cols[3].replace("\\n", "\n")))
                continue
            if cols[0] == "@taint":
                if len(cols) != 4:
                    sys.exit(f"{path}:{ln}: @taint needs glob, rhs-regex, name=target,...")
                taints.append((cols[1], cols[2], dict(x.split("=") for x in cols[3].split(","))))
                continue
            if cols[0] == "@callee":
                if len(cols) != 3 or cols[2] not in ("keep", "rename"):
                    sys.exit(f"{path}:{ln}: @callee needs name and keep|rename")
                callees[cols[1]] = cols[2]
                continue
            if cols[0] == "@keep":
                if len(cols) not in (4, 5):
                    sys.exit(f"{path}:{ln}: @keep needs glob, regex, names[, exempt names]")
                keeps.append((cols[1], cols[2], cols[3], cols[4] if len(cols) == 5 else ""))
                continue
            if cols[0] == "@delete":
                if len(cols) != 3:
                    sys.exit(f"{path}:{ln}: @delete needs file and line")
                deletes.append((cols[1], cols[2]))
                continue
            if cols[0] == "@path":
                if len(cols) != 3:
                    sys.exit(f"{path}:{ln}: @path needs old and new")
                paths.append((cols[1], cols[2]))
                continue
            if len(cols) < 2:
                sys.exit(f"{path}:{ln}: need old<TAB>new")
            globs = [g for g in (cols[2].split(",") if len(cols) > 2 else []) if g]
            fallback = cols[3] if len(cols) > 3 and cols[3] else None
            flags = set(cols[4].split(",")) if len(cols) > 4 and cols[4] else set()
            renames.setdefault(cols[0], []).append((cols[1], globs, fallback, flags))
    return renames, paths, deletes, keeps, callees, taints, fixes, receivers


def glob_match(rel, globs):
    if not globs:
        return True
    inc = [g for g in globs if not g.startswith("!")]
    exc = [g[1:] for g in globs if g.startswith("!")]
    if any(fnmatch.fnmatch(rel, g) for g in exc):
        return False
    return not inc or any(fnmatch.fnmatch(rel, g) for g in inc)


def validate(renames):
    news = {e[0] for lst in renames.values() for e in lst}
    clash = news & set(renames)
    if clash:
        sys.exit("table chains renames (new name is also an old name): " + ", ".join(sorted(clash)))
    for old, lst in renames.items():
        for n, *_ in lst:
            if n == old:
                sys.exit(f"identity rename: {old}")


class Lexer:
    """Finds identifier tokens in code regions of a Swift file."""

    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.idents = []  # (start, end)
        self.events = []  # (pos, "{" | "}" | ";") in code regions

    def scan(self, i, in_interp):
        s, n = self.s, self.n
        depth = 0
        while i < n:
            c = s[i]
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "/" and i + 1 < n and s[i + 1] == "*":
                i = self.skip_block_comment(i)
                continue
            if c == "#" or c == '"':
                j = i
                while j < n and s[j] == "#":
                    j += 1
                if j < n and s[j] == '"':
                    i = self.string(i, j - i, j)
                    continue
                i += 1
                continue
            if c in "{};":
                self.events.append((i, c))
                i += 1
                continue
            if c == "(":
                depth += 1
                i += 1
                continue
            if c == ")":
                if in_interp and depth == 0:
                    return i + 1
                depth -= 1
                i += 1
                continue
            if c.isdigit():
                j = i + 1
                while j < n and (s[j].isalnum() or s[j] == "_"):
                    j += 1
                i = j
                continue
            if c == "`":
                j = s.find("`", i + 1)
                if j > 0 and "\n" not in s[i:j]:
                    self.idents.append((i + 1, j))
                    i = j + 1
                    continue
            if IDENT_START.match(c):
                j = i + 1
                while j < n and IDENT_CHAR.match(s[j]):
                    j += 1
                self.idents.append((i, j))
                i = j
                continue
            i += 1
        return i

    def skip_block_comment(self, i):
        s, n = self.s, self.n
        depth = 0
        while i < n:
            if s.startswith("/*", i):
                depth += 1
                i += 2
            elif s.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def string(self, start, hashes, quote_at):
        """Skip a string literal starting at `start`; recurse into interpolations."""
        s, n = self.s, self.n
        multi = s.startswith('"""', quote_at)
        i = quote_at + (3 if multi else 1)
        closer = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        while i < n:
            if s.startswith(esc, i):
                k = i + len(esc)
                if k < n and s[k] == "(":
                    i = self.scan(k + 1, True)
                else:
                    i = k + 1
                continue
            if s.startswith(closer, i):
                return i + len(closer)
            if not multi and s[i] == "\n":
                return i  # unterminated; bail to keep lexing sane
            i += 1
        return n


VENDOR_RECEIVERS = ("TabLayoutSettings.Mode.", "Bonsplit.", "bonsplitController.", "bonsplitController?.", "controller.")
TYPE_KEYWORDS = {"class", "struct", "enum", "extension", "protocol", "actor"}


def regions(src, lx):
    """Assign each identifier a region id.

    A region is one member of a type body (or one file-level declaration): from
    the end of the previous member to the end of this member's braces. Used to
    detect a renamed local colliding with an identifier already in scope.
    """
    ev = lx.events
    ids = lx.idents
    # kind of each "{": type body or other
    stack = [True]  # file level behaves like a type body
    region = 0
    boundaries = []  # (pos, new_region_id)
    last_boundary = -1
    ident_i = 0
    for pos, ch in ev:
        if ch == "{":
            # identifiers since last boundary event
            is_type = False
            k = ident_i
            # scan identifiers between last_boundary and pos
            for a, b in ids:
                if a <= last_boundary:
                    continue
                if a >= pos:
                    break
                if src[a:b] in TYPE_KEYWORDS:
                    is_type = True
                    break
            stack.append(is_type)
            if is_type:
                region += 1
                boundaries.append((pos, region))
            last_boundary = pos
        elif ch == "}":
            if len(stack) > 1:
                was_type = stack.pop()
                if was_type or stack[-1]:
                    region += 1
                    boundaries.append((pos, region))
            last_boundary = pos
        else:  # ";"
            last_boundary = pos
    # map identifier -> region via sorted boundaries
    import bisect
    bpos = [b[0] for b in boundaries]
    bid = [b[1] for b in boundaries]
    out = []
    for a, _ in ids:
        j = bisect.bisect_right(bpos, a)
        out.append(0 if j == 0 else bid[j - 1])
    spans = {0: (0, bpos[0] if bpos else len(src))}
    for k, (pos, rid) in enumerate(boundaries):
        spans[rid] = (pos, boundaries[k + 1][0] if k + 1 < len(boundaries) else len(src))
    return out, spans


def type_bodies(src, lx):
    """[(kind, name, header, open_pos, close_pos)] for every type declaration."""
    ev, ids = lx.events, lx.idents
    out, stack = [], []  # stack entries: None or index into out
    last_boundary = -1
    for pos, ch in ev:
        if ch == "{":
            kind = name = None
            header = ""
            for k, (a, b) in enumerate(ids):
                if a <= last_boundary:
                    continue
                if a >= pos:
                    break
                if src[a:b] in TYPE_KEYWORDS and kind is None:
                    kind = src[a:b]
                    if k + 1 < len(ids):
                        name = src[ids[k + 1][0]:ids[k + 1][1]]
                    header = src[last_boundary + 1:pos]
            if kind:
                out.append([kind, name, header, pos, None])
                stack.append(len(out) - 1)
            else:
                stack.append(None)
            last_boundary = pos
        elif ch == "}":
            if stack:
                top = stack.pop()
                if top is not None:
                    out[top][4] = pos
            last_boundary = pos
        else:
            last_boundary = pos
    return [tuple(x) for x in out if x[4] is not None]


def own_depth_idents(src, lx, bodies):
    """For each type body, idents directly inside it (brace depth 0 relative)."""
    ev = lx.events
    res = []
    for kind, name, header, op, cl in bodies:
        depth = 0
        evs = [(p, c) for p, c in ev if op < p <= cl]
        inside = []
        ei = 0
        for a, b in lx.idents:
            if a <= op or a >= cl:
                continue
            while ei < len(evs) and evs[ei][0] < a:
                if evs[ei][1] == "{":
                    depth += 1
                elif evs[ei][1] == "}":
                    depth -= 1
                ei += 1
            if depth == 0:
                inside.append((a, b))
        res.append(inside)
    return res


CASE_AFTER = re.compile(r"\s*(\(|=|,|$|\n)")


def declared_names(src, inside):
    """(props, cases) declared directly in a body, as lists of (start, end)."""
    props, cases = [], []
    for k, (a, b) in enumerate(inside):
        w = src[a:b]
        if w in ("let", "var") and k + 1 < len(inside):
            na, nb = inside[k + 1]
            if src[b:na].strip() == "":
                props.append((na, nb))
        elif w == "case" and k + 1 < len(inside):
            na, nb = inside[k + 1]
            if src[b:na].strip() == "":
                cases.append((na, nb))
                # `case a, b, c` : following idents after commas at same level
                j = nb
                while True:
                    m = re.match(r"(\([^)]*\))?\s*(=\s*[^,\n]+)?\s*,\s*", src[j:j + 400])
                    if not m or m.end() == 0:
                        break
                    nxt = [(x, y) for x, y in inside if x >= j + m.end()][:1]
                    if not nxt or src[j + m.end():nxt[0][0]].strip() != "":
                        break
                    cases.append(nxt[0])
                    j = nxt[0][1]
    return props, cases


RECV_MGR = re.compile(r"(?:[Mm]anager|TM|\btm)[?!]?\s*\.\s*$")
TYPE_START = re.compile(r"\s*(?:inout\s+|@escaping\s+|any\s+|some\s+)*(?:\[\s*)*([A-Za-z_][\w.]*)(<[^>]*>)?([?!]?)\s*([,)\]:=\n{]|->|$)")


IMPLICIT_AFTER_WORD = {"return", "case", "in", "if", "else", "default", "where", "while", "guard", "switch", "yield", "throw", "try", "await", "is", "as", "let", "var"}


def is_implicit_member(src, a):
    """True if the token at a is `.name` with no receiver (an implicit-member expression)."""
    if a < 1 or src[a - 1] != ".":
        return False
    j = a - 2
    while j >= 0 and src[j] in " \t":
        j -= 1
    if j >= 0 and src[j] == "\n":
        return False  # chained call on the next line
    if j < 0:
        return True
    c = src[j]
    if c == "?" and j >= 1 and src[j - 1] == "?":
        return True  # `x ?? .case`
    if c in ")]}?!>\\":
        return False
    if c.isalnum() or c == "_":
        k = j
        while k >= 0 and (src[k].isalnum() or src[k] == "_"):
            k -= 1
        return src[k + 1:j + 1] in IMPLICIT_AFTER_WORD
    return True


VENDOR_CALLEES = {"ScriptTab", "preloadTerminalPanelForDebugStress", "DebugStressTerminalLoadTarget", "moveBonsplitTab", "locateBonsplitSurface", "setLinkedHover", "createTab", "updateTab", "selectTab", "closeTab", "moveTab", "reorderTab", "tab", "tabs"}


def callee_name(src, a):
    """Identifier before the `(` that encloses position a, or None."""
    depth, i = 0, a - 1
    while i >= 0:
        c = src[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                j = i - 1
                while j >= 0 and src[j] in " \t":
                    j -= 1
                e = j + 1
                while j >= 0 and (src[j].isalnum() or src[j] == "_"):
                    j -= 1
                return src[j + 1:e] or None
            depth -= 1
        i -= 1
    return None


def vendor_callee(src, a):
    """Name of the callee whose argument list contains the label at a (best effort)."""
    depth, i = 0, a - 1
    while i >= 0:
        c = src[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                j = i - 1
                while j >= 0 and (src[j].isalnum() or src[j] == "_"):
                    j -= 1
                return src[j + 1:i] in VENDOR_CALLEES
            depth -= 1
        i -= 1
    return False


def is_func_decl_param(src, a, b):
    """True if the token at [a,b) is a parameter name `name: Type` in a func/init declaration."""
    j = b
    while j < len(src) and src[j] in " \t":
        j += 1
    if j >= len(src) or src[j] != ":":
        return False
    i = a - 1
    while i >= 0 and src[i] in " \t\n":
        i -= 1
    if i < 0 or src[i] not in "(,":
        return False
    depth, k = 0, a - 1
    while k >= 0:
        c = src[k]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                break
            depth -= 1
        k -= 1
    if k < 0:
        return False
    m = re.search(r"(?:\b(?:func|case)\s+[A-Za-z_]\w*\s*(?:<[^>]*>)?|\binit[?!]?\s*(?:<[^>]*>)?)\s*$", src[max(0, k - 120):k])
    return m is not None


def is_call_label(src, a, b):
    """True if the token at [a,b) is an argument label of a call (not a binding)."""
    j = b
    while j < len(src) and src[j] in " \t":
        j += 1
    if j >= len(src) or src[j] != ":":
        return False
    i = a - 1
    while i >= 0 and src[i] in " \t\n":
        i -= 1
    if i < 0 or src[i] not in "(,":
        return False
    rest = src[j + 1:j + 160]
    m = TYPE_START.match(rest)
    if m and m.group(1)[0].isupper():
        return False  # declaration: `name: Type`
    if re.match(r"\s*(\(|\[\s*\]|\[\s*[A-Z][\w.]*\s*(:\s*[A-Z][\w.]*\s*)?\])", rest) and False:
        return False
    return True



_BIND_LET = re.compile(r"\b(?:let|var)\s+(?:\(([^)]*)\)|([A-Za-z_]\w*))")
_BIND_FOR = re.compile(r"\bfor\s+(?:\(([^)]*)\)|([A-Za-z_]\w*))\s+in\b")
_BIND_CLOSURE = re.compile(r"\{\s*(?:\[[^\]]*\]\s*)?(?:\(([^)]*)\)|([\w, ]+?))(?:\s*->\s*[\w?!.<>\[\]]+)?\s+in\b")
_BIND_FUNC = re.compile(r"\b(?:func\s+[A-Za-z_]\w*|init[?!]?)\s*(?:<[^>]*>)?\(([^)]*)\)")


def bound_names(text):
    """Names bound locally (let/var/for/closure params/func params) somewhere in `text`."""
    names = set()
    def add(group):
        for part in re.split(r"[,\s]+", group or ""):
            part = part.strip("()")
            if re.fullmatch(r"[A-Za-z_]\w*", part):
                names.add(part)
    for rx in (_BIND_LET, _BIND_FOR, _BIND_CLOSURE):
        for m in rx.finditer(text):
            add(m.group(1))
            add(m.group(2))
    for m in _BIND_FUNC.finditer(text):
        depth, cur, parts = 0, "", []
        for ch in m.group(1):
            if ch in "([<":
                depth += 1
            elif ch in ")]>":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur)
                cur = ""
            else:
                cur += ch
        parts.append(cur)
        for part in parts:
            head = part.split(":")[0].split()
            if head:
                names.add(head[-1])
    return names


HEADER_START = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+|(?:private|fileprivate|internal|public|open|static|final|override|mutating|"
    r"nonisolated|class|lazy|required|convenience)\s+)*(?:func|init|subscript|if|else|for|while|catch|case|do|"
    r"repeat|get|set|willSet|didSet|deinit|switch)\b")
TYPE_HEAD = re.compile(r"\b(?:class|struct|enum|extension|protocol|actor)\b")
CLOSURE_PARAMS = re.compile(r"\s*(?:\[[^\]]*\]\s*)?(?:\(([^)]*)\)|([\w, ]+?))(?:\s*->\s*[^\n{]+?)?\s+in\b")


class Block:
    __slots__ = ("open", "close", "parent", "header", "header_start", "own", "children", "is_type", "_desc")

    def __init__(self, open_, parent, header, header_start):
        self.open, self.close, self.parent = open_, None, parent
        self.header, self.header_start = header, header_start
        self.own, self.children = set(), []
        self.is_type = bool(TYPE_HEAD.search(header))
        self._desc = None


class Scopes:
    """Lexical block scopes of one Swift file: which names are bound locally where."""

    def __init__(self, src, lx):
        self.src = src
        self.blocks, stack, last = [], [], -1
        for pos, ch in lx.events:
            if ch == "{":
                seg_start = last + 1
                seg = src[seg_start:pos]
                header, hstart = "", pos
                offset = 0
                lines = seg.split("\n")
                for i, line in enumerate(lines):
                    if HEADER_START.match(line):
                        header = "\n".join(lines[i:])
                        hstart = seg_start + offset
                        break
                    offset += len(line) + 1
                blk = Block(pos, stack[-1] if stack else None, header, hstart)
                if stack:
                    stack[-1].children.append(blk)
                self.blocks.append(blk)
                stack.append(blk)
                last = pos
            elif ch == "}":
                if stack:
                    blk = stack.pop()
                    blk.close = pos
                    self._bind(blk)
                last = pos
            else:
                last = pos
        for blk in stack:  # unbalanced (shouldn't happen): treat as closed at EOF
            blk.close = len(src)
            self._bind(blk)
        self.blocks.sort(key=lambda b: b.open)
        self.opens = [b.open for b in self.blocks]

    def _bind(self, blk):
        if blk.is_type:
            return
        src = self.src
        names = set(bound_names(blk.header)) if blk.header else set()
        m = CLOSURE_PARAMS.match(src[blk.open + 1:blk.open + 300])
        if m:
            for grp in (m.group(1), m.group(2)):
                for part in re.split(r"[,\s]+", grp or ""):
                    part = part.strip("()")
                    if re.fullmatch(r"[A-Za-z_]\w*", part):
                        names.add(part)
        pieces, cur = [], blk.open + 1
        for ch in sorted(blk.children, key=lambda c: c.header_start):
            pieces.append(src[cur:ch.header_start])
            cur = ch.close + 1
        pieces.append(src[cur:blk.close])
        direct = "".join(pieces)
        for m in _BIND_LET.finditer(direct):
            for grp in (m.group(1), m.group(2)):
                for part in re.split(r"[,\s]+", grp or ""):
                    part = part.strip("()")
                    if re.fullmatch(r"[A-Za-z_]\w*", part):
                        names.add(part)
        blk.own = names

    def innermost(self, p):
        import bisect
        i = bisect.bisect_right(self.opens, p) - 1
        blk = self.blocks[i] if i >= 0 else None
        while blk is not None and not (blk.open < p < blk.close):
            blk = blk.parent
        # a token in a block's header (parameters, for/if bindings) belongs to that block
        pool = blk.children if blk is not None else [b for b in self.blocks if b.parent is None]
        for ch in pool:
            if ch.header_start <= p < ch.open and ch.header:
                return ch
        return blk

    def _desc(self, blk):
        if blk._desc is None:
            acc = set()
            for ch in blk.children:
                acc |= ch.own
                acc |= self._desc(ch)
            blk._desc = acc
        return blk._desc

    def conflict(self, p, tok, new):
        """(conflicts, tok_is_local): would renaming `tok` at p to `new` clash with a local binding?"""
        blk = self.innermost(p)
        chain, b = [], blk
        while b is not None:
            chain.append(b)
            b = b.parent
        binder = next((c for c in chain if tok in c.own), None)
        names = set()
        if binder is not None:
            for c in chain[chain.index(binder):]:
                names |= c.own
            names |= self._desc(binder)
        else:
            for c in chain:
                names |= c.own
        return (new in names), binder is not None


def rewrite(src, rel, renames, report=None, keep_rules=None, callees=None, receivers=None):
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    keeps = [(set(n.split(',')), re.compile(rx), set(x.split(',')) if x else set()) for g, rx, n, x in (keep_rules or []) if any(fnmatch.fnmatch(rel, gg) for gg in g.split(","))]
    kept_cache = {}
    prop_owner = {}  # token start of a stored property declaration -> owning type name
    pin_enum = {}   # token start -> old name, for implicit-raw String enum cases
    case_decl = set()  # token starts of enum case declarations
    hazard_pos = {}  # token start -> description, Codable property/case
    bodies = type_bodies(src, lx)
    for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
        h = header
        is_codable = re.search(r"\b(Codable|Encodable|Decodable)\b", h) is not None
        raw_string = kind == "enum" and re.search(r":\s*(?:[\w.,\s]*?\b)?String\b", h) is not None
        props, cases = declared_names(src, inside)
        case_decl.update(a for a, _ in cases)
        for a, _ in props:
            prop_owner[a] = name
        has_ck = any(src[a:b] == "CodingKeys" for a, b in inside)
        if raw_string:
            for a, b in cases:
                tail = src[b:b + 40].lstrip(" ")
                if not tail.startswith("="):
                    pin_enum[a] = src[a:b]
        elif is_codable and not has_ck:
            for a, b in props + (cases if kind == "enum" else []):
                hazard_pos[a] = f"{kind} {name}"
    scopes = Scopes(src, lx)
    protected = set()  # (region, name): parameters of `keep` callees keep their name through the body
    if callees:
        for (a, b), r in zip(lx.idents, reg):
            if src[a:b] in renames and not is_call_label(src, a, b) and is_func_decl_param(src, a, b):
                if callees.get(callee_name(src, a) or "") == "keep":
                    protected.add((r, src[a:b]))
    out, last, count = [], 0, 0
    for (a, b), r in zip(lx.idents, reg):
        tok = src[a:b]
        lst = renames.get(tok)
        if not lst:
            continue
        if (r, tok) in protected and not (a >= 1 and src[a - 1] == "."):
            continue
        new, fallback, flags = None, None, set()
        for cand, globs, fb, fl in lst:
            if glob_match(rel, globs):
                new, fallback, flags = cand, fb, fl
                break
        if new is None and receivers and lst and a >= 1 and src[a - 1] == "." and any(src[:a].endswith(rc) for rc in receivers):
            new, fallback, flags = lst[0][0], lst[0][2], set()  # member of a renamed c11 type
        if new is None and callees and lst:
            if is_call_label(src, a, b) and callees.get(callee_name(src, a) or "") == "rename":
                new, fallback, flags = lst[0][0], lst[0][2], set()  # follows its renamed declaration
        if new is None:
            continue
        pre = src[max(0, a - 40):a]
        if pre.endswith(VENDOR_RECEIVERS) or pre.endswith("@objc("):
            continue  # vendor member / ObjC runtime name (an external contract)
        is_label = is_call_label(src, a, b)
        is_param = (not is_label) and is_func_decl_param(src, a, b)
        rule = None
        if callees:
            if is_label or is_param:
                rule = callees.get(callee_name(src, a) or "")
            elif a in prop_owner:
                rule = callees.get(prop_owner[a])
        if rule == "keep":
            continue
        member = a >= 1 and src[a - 1] == "." and not is_implicit_member(src, a)
        mgr_member = member and RECV_MGR.search(src[max(0, a - 80):a - 1] + ".") is not None
        blocked = None
        if "labelonly" in flags or "recvmgr" in flags:
            ok = ("labelonly" in flags and is_label and not vendor_callee(src, a)) or (
                "recvmgr" in flags and RECV_MGR.search(src[max(0, a - 80):a]) is not None)
            if not ok:
                blocked = "leaf"
        if blocked is None and "noimplicit" in flags and a in case_decl:
            blocked = "case"
        if blocked is None and "noimplicit" in flags and is_implicit_member(src, a):
            blocked = "implicit"
        if blocked is None and keeps and not mgr_member:
            for names, rx, exempt in keeps:
                if tok in exempt and (member or (is_label and vendor_callee(src, a) is not True)):
                    continue  # member access / c11 call label: follow the declaration
                if tok in names:
                    key = (id(rx), r)
                    if key not in kept_cache:
                        a0, b0 = spans[r]
                        kept_cache[key] = bool(rx.search(src[a0:b0]))
                    if kept_cache[key]:
                        blocked = "keep"
                        break
        if blocked is None and not member and not is_label:
            clash, local = scopes.conflict(a, tok, new)
            if clash:
                if not local and not is_param:
                    new = "self." + new  # a member use: qualify so a same-named local cannot capture it
                elif is_param:
                    inner = fallback if fallback and not scopes.conflict(a, tok, fallback)[0] else tok
                    new = f"{new} {inner}"  # `func f(newLabel inner: T)`: label follows the rename, body keeps a safe name
                elif fallback and not scopes.conflict(a, tok, fallback)[0]:
                    new = fallback
                else:
                    blocked = "collision"
                    if rule != "rename" and report is not None:
                        line = src.count("\n", 0, a) + 1
                        report.append(f"COLLISION {rel}:{line} {tok} -> {new} (already in scope; left as is)")
        if blocked is not None:
            if rule == "rename":
                if is_param:
                    new = f"{new} {tok}"
                # call labels and properties: follow the declaration
            else:
                continue
        out.append(src[last:a])
        if a in pin_enum:
            out.append(f'{new} = "{pin_enum[a]}"')
        else:
            out.append(new)
        if a in hazard_pos and report is not None:
            line = src.count("\n", 0, a) + 1
            report.append(f"CODABLE {rel}:{line} {tok} -> {new} in {hazard_pos[a]} (no CodingKeys: pin the old key by hand)")
        last = b
        count += 1
    out.append(src[last:])
    return "".join(out), count



TAINT_TYPE = r"(?:TabID|\[TabID\]|Set<TabID>|Bonsplit\.Tab|\[Bonsplit\.Tab\]|\(TabID\) ->)"


def taint_pass(src, rel, taint_rules, report=None):
    """Rename names that are bound to bonsplit leaf values (by their binding site), per member.

    A binding site is `let/var/guard let/if let/for NAME ... = <rhs>` whose rhs matches the rule's
    regex, a parameter/variable annotated with a bonsplit type, or a closure parameter in a
    statement that mentions an already-tainted name.
    """
    rules = [(re.compile(rx), mp) for g, rx, mp in taint_rules if any(fnmatch.fnmatch(rel, gg) for gg in g.split(","))]
    if not rules:
        return src, 0
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    edits = []
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        by_region.setdefault(r, []).append((a, b))
    for r, toks in by_region.items():
        a0, b0 = spans[r]
        text = src[a0:b0]
        for rx, mp in rules:
            tainted = set()
            for name in mp:
                n = re.escape(name)
                pats = [
                    rf"\b(?:let|var)\s+{n}\b[^=\n]*=\s*[^\n]*(?:\n\s*\.[^\n]*){{0,3}}",
                    rf"\b(?:guard|if)\s+(?:let|var)\s+{n}\b[^=\n]*=\s*[^\n]*(?:\n\s*\.[^\n]*){{0,3}}",
                    rf"\bfor\s+(?:\(?[\w, ]*\b)?{n}\b[\w, ]*\)?\s+in\s+[^\n{{]*",
                ]
                for pt in pats:
                    for m in re.finditer(pt, text):
                        if rx.search(m.group(0)):
                            tainted.add(name)
                if re.search(rf"\b{n}\s*:\s*{TAINT_TYPE}", text) or re.search(rf"\b(?:let|var)\s+{n}\s*:\s*{TAINT_TYPE}", text):
                    tainted.add(name)
            # closure params following a tainted name in the same statement
            changed = True
            while changed:
                changed = False
                for name in mp:
                    if name in tainted:
                        continue
                    n = re.escape(name)
                    for m in re.finditer(rf"\{{\s*(?:\[[^\]]*\]\s*)?\(?[\w, ]*\b{n}\b[\w, ]*\)?\s+in\b", text):
                        line_start = text.rfind("\n", 0, m.start()) + 1
                        stmt = text[max(0, line_start - 200):m.start()]
                        if any(re.search(rf"\b{re.escape(t)}\b", stmt) for t in tainted):
                            tainted.add(name)
                            changed = True
                            break
            if not tainted:
                continue
            present = {src[a:b] for a, b in toks}
            for a, b in toks:
                tok = src[a:b]
                if tok in tainted and not (a >= 1 and src[a - 1] == ".") and not is_call_label(src, a, b):
                    tgt = mp[tok]
                    if tgt in present and tgt != tok:
                        if report is not None:
                            report.append(f"TAINT-COLLISION {rel}:{src.count(chr(10), 0, a) + 1} {tok} -> {tgt}")
                        continue
                    edits.append((a, b, tgt))
    if not edits:
        return src, 0
    edits.sort()
    out, last = [], 0
    for a, b, t in edits:
        if a < last:
            continue
        out.append(src[last:a])
        out.append(t)
        last = b
    out.append(src[last:])
    return "".join(out), len(edits)


def swift_files(root):
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        for dp, dn, fn in os.walk(base):
            for f in fn:
                if f.endswith(".swift"):
                    full = os.path.join(dp, f)
                    if any(p in full for p in SKIP_PARTS):
                        continue
                    yield full


def apply_paths(root, paths, dry, use_git):
    pbx = os.path.join(root, "GhosttyTabs.xcodeproj/project.pbxproj")
    pbx_text = open(pbx, encoding="utf-8").read()
    changed = 0
    for old, new in paths:
        o, nw = os.path.join(root, old), os.path.join(root, new)
        if not os.path.exists(o):
            if os.path.exists(nw):
                continue  # already renamed
            print(f"  [path] missing both {old} and {new}", file=sys.stderr)
            continue
        print(f"  [path] {old} -> {new}")
        if dry:
            continue
        os.makedirs(os.path.dirname(nw), exist_ok=True)
        if use_git:
            subprocess.check_call(["git", "mv", o, nw], cwd=root)
        else:
            os.rename(o, nw)
        changed += 1
        # pbxproj: replace the full relative path and, for files, the basename
        # token in comments/ids. Path references use `path = <rel to group>;`.
        pbx_text = pbx_text.replace(old, new)
        ob, nb = os.path.basename(old), os.path.basename(new)
        if ob != nb:
            pbx_text = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(ob) + r"(?![A-Za-z0-9_])", nb, pbx_text)
    if changed and not dry:
        open(pbx, "w", encoding="utf-8").write(pbx_text)
    return changed


def main(argv):
    if len(argv) < 3 or argv[1] != "apply":
        print(__doc__)
        return 2
    table = argv[2]
    root = os.getcwd()
    dry = "--dry-run" in argv
    use_git = "--no-git" not in argv
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    renames, paths, deletes, keeps, callees, taints, fixes, receivers = load_table(table)
    validate(renames)
    for rel, text in deletes:
        full = os.path.join(root, rel)
        if not os.path.exists(full):
            continue
        lines = open(full, encoding="utf-8").read().split("\n")
        kept = [l for l in lines if l.strip() != text.strip()]
        if len(kept) != len(lines):
            print(f"  [delete] {rel}: {text.strip()}")
            if not dry:
                open(full, "w", encoding="utf-8").write("\n".join(kept))
    total_files = total_hits = 0
    report = []
    for full in sorted(swift_files(root)):
        rel = os.path.relpath(full, root)
        src = open(full, encoding="utf-8").read()
        src, nt = taint_pass(src, rel, taints, report)
        new, n = rewrite(src, rel, renames, report, keeps, callees, receivers)
        n += nt
        if n:
            total_files += 1
            total_hits += n
            print(f"{n:6d}  {rel}")
            if not dry:
                open(full, "w", encoding="utf-8").write(new)
    stale = 0
    for rel, old, new in fixes:
        full = os.path.join(root, rel)
        text = open(full, encoding="utf-8").read() if os.path.exists(full) else ""
        if new in text and old not in text:
            continue  # already applied
        if text.count(old) != 1:
            print(f"FIXUP STALE {rel}: {old[:70]!r} found {text.count(old)}x")
            stale += 1
            continue
        print(f"  [fix] {rel}: {old[:60]!r}")
        if not dry:
            open(full, "w", encoding="utf-8").write(text.replace(old, new))
    for line in report:
        print(line)
    print(f"identifiers renamed: {total_hits} in {total_files} files; collisions left: {len(report)}")
    if stale:
        print(f"{stale} stale @fix entries: the code drifted; update the table", file=sys.stderr)
        return 3
    if paths:
        # Paths after contents: edits above are by path as it was on entry.
        n = apply_paths(root, paths, dry, use_git)
        print(f"paths renamed: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
