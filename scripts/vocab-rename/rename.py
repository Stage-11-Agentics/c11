#!/usr/bin/env python3
"""Token-aware Swift identifier renamer (C11-248).

Applies a TSV symbol table of whole-identifier renames to Swift sources.

  rename.py apply <table.tsv> [--root DIR] [--dry-run] [--no-git]
  rename.py check-leaf <table.tsv> [--root DIR]   # zero hits required after pass 1
  rename.py check-domains [--root DIR]            # table-independent gate: Ghostty / Bonsplit leaf / c11 names
  rename.py check-evidence <log.tsv> <base> <head> # every renamed token must be in the pass's evidence log
  rename.py check-literals [--allow F]            # string literals that still name a renamed identifier
  rename.py check-rows <table.tsv> <base> [log]   # the renames landed: new names present and declared

Table format (one entry per line, `#` comments and blank lines ignored):

  old<TAB>new[<TAB>glob[,glob...][<TAB>fallback[<TAB>flags]]]
                                        identifier rename; optional repo-relative
                                        globs restrict where it applies (prefix a
                                        glob with `!` to exclude). If `new` already
                                        occurs in the same member (a shadowing
                                        hazard), `fallback` is used there instead;
                                        with no usable fallback the token is left
                                        alone and reported as COLLISION. Flag
                                        `nomember` skips `x.name` member accesses (not `self.`, unless `noprop`); `noprop` skips stored property
                                        declarations; `nolabel` skips call-site labels
                                        unless the callee is `@callee rename`;
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
  @taint<TAB>glob<TAB>rhs-regex<TAB>name=target,...[<TAB>region-regex[<TAB>exclude-regex]]
                                        in matching files, names whose binding site
                                        (let/for/guard/param) derives from the regex
                                        (a bonsplit value) are renamed per member
  @novendor<TAB>glob<TAB>receiver       in these files `receiver` (e.g. `controller.`) is not a Bonsplit value
  @regionrename<TAB>glob<TAB>region-regex<TAB>old=new[,old=new]
                                        rename `old` to `new` inside the members whose text matches the
                                        regex (a local that survived pass 1 because its scope collided)
  @callee<TAB>name<TAB>keep|rename|keep:label,label
                                        call labels of `name` keep their old spelling, follow the renamed
                                        declaration, or (keep:) keep only the listed labels
  @receiver<TAB>Type.                    members accessed as `Type.name` always follow the rename,
                                        even in files the globs exclude
  @fix<TAB>file<TAB>old text<TAB>new text   exact one-off text edit applied after the renames
                                        (\\n = newline); must match exactly once, else
                                        the run reports FIXUP STALE and exits non-zero
  @fixall<TAB>file<TAB>old<TAB>new       like @fix, but replaces every occurrence (at least one)
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
import collections
import fnmatch
import glob
import os
import re
import subprocess
import sys

SCAN_DIRS = ["Sources", "CLI", "c11Tests", "c11UITests"]
SKIP_PARTS = ("/vendor/", "/ghostty/")
IDENT_START = re.compile(r"[A-Za-z_\u0080-￿]")
IDENT_CHAR = re.compile(r"[A-Za-z0-9_\u0080-￿]")


PATH_EVIDENCE = {}  # (old path, new path) -> evidence class, for @path rows that carry one
SNIP = {}  # name -> the binding statement that taints it (evidence site of the last find_tainted call)
EVIDENCE = []  # (file, line, old, new, class, site): every renamed token with the evidence class its rule declared


def _ev_class(flags):
    """`ev:T` / `ev:M` / `ev:L` / `ev:Leaf` ... in a rule's flags or options; UNPROVEN when the rule declares none."""
    return next((f[3:] for f in flags if f.startswith("ev:")), "UNPROVEN")


NOVENDOR = []  # (glob, receiver): files where a receiver name such as `controller.` is not a Bonsplit controller


def load_table(path):
    renames = {}  # old -> list of (new, [globs])
    paths = []
    deletes = []
    keeps = []
    callees = {}  # callee/type name -> "keep" | "rename"
    taints = []  # (glob, rhs regex, {name: target}, region regex, exclude regex, options{keep,funcs,props})
    receivers = []  # member receivers whose members always follow the rename (e.g. "GhosttyNotificationKey.")
    fixes = []  # (file, old text, new text): exact one-off edits, written as \\n for newlines
    region_renames = []  # (glob, region regex, {old: new}): rename within the members whose text matches
    with open(path, encoding="utf-8") as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if cols[0] == "@receiver":
                receivers.append(cols[1])
                continue
            if cols[0] in ("@fix", "@fixall"):
                if len(cols) != 4:
                    sys.exit(f"{path}:{ln}: {cols[0]} needs file, old, new")
                fixes.append((cols[1], cols[2].replace("\\n", "\n"), cols[3].replace("\\n", "\n"), cols[0] == "@fixall"))
                continue
            if cols[0] == "@novendor":
                if len(cols) != 3:
                    sys.exit(f"{path}:{ln}: @novendor needs glob and receiver")
                NOVENDOR.append((cols[1], cols[2]))
                continue
            if cols[0] == "@regionrename":
                if len(cols) != 4:
                    sys.exit(f"{path}:{ln}: @regionrename needs glob, region-regex, old=new[,old=new]")
                region_renames.append((cols[1], cols[2], dict(x.split("=") for x in cols[3].split(","))))
                continue
            if cols[0] == "@taint":
                if len(cols) not in (4, 5, 6, 7):
                    sys.exit(f"{path}:{ln}: @taint needs glob, rhs-regex, name=target,...[, region-regex[, exclude-regex[, options]]]")
                taints.append((cols[1], cols[2], dict(x.split("=") for x in cols[3].split(",")),
                               cols[4] if len(cols) > 4 else "", cols[5] if len(cols) > 5 else "",
                               set(cols[6].split(",")) if len(cols) > 6 and cols[6] else set()))
                continue
            if cols[0] == "@callee":
                if len(cols) != 3 or not (cols[2] in ("keep", "rename") or cols[2].startswith("keep:")):
                    sys.exit(f"{path}:{ln}: @callee needs name and keep|rename|keep:label,label")
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
                if len(cols) not in (3, 4):
                    sys.exit(f"{path}:{ln}: @path needs old and new")
                paths.append((cols[1], cols[2]))
                if len(cols) == 4 and cols[3].startswith("ev:"):
                    PATH_EVIDENCE[(cols[1], cols[2])] = cols[3][3:]  # a file move that carries an evidence class
                continue
            if len(cols) < 2:
                sys.exit(f"{path}:{ln}: need old<TAB>new")
            globs = [g for g in (cols[2].split(",") if len(cols) > 2 else []) if g]
            fallback = cols[3] if len(cols) > 3 and cols[3] else None
            flags = set(cols[4].split(",")) if len(cols) > 4 and cols[4] else set()
            renames.setdefault(cols[0], []).append((cols[1], globs, fallback, flags))
    return renames, paths, deletes, keeps, callees, taints, fixes, receivers, region_renames


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
        self.parens = []  # (pos, "(" | ")") in code regions
        self.strings = []  # (start, end) of the literal text of every string literal, interpolations excluded

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
                self.parens.append((i, "("))
                i += 1
                continue
            if c == ")":
                if in_interp and depth == 0:
                    return i + 1
                depth -= 1
                self.parens.append((i, ")"))
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
        seg = i
        while i < n:
            if s.startswith(esc, i):
                k = i + len(esc)
                if k < n and s[k] == "(":
                    self.strings.append((seg, i))
                    i = self.scan(k + 1, True)
                    seg = i
                else:
                    i = k + 1
                continue
            if s.startswith(closer, i):
                self.strings.append((seg, i))
                return i + len(closer)
            if not multi and s[i] == "\n":
                self.strings.append((seg, i))
                return i  # unterminated; bail to keep lexing sane
            i += 1
        self.strings.append((seg, n))
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
            # a type declared inside a function body is part of that member: it opens no region of its own
            is_type = is_type and all(stack)
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


def decl_label(src, a, b):
    """(start, end) of the external label in front of the parameter name at [a,b) of a func/init declaration
    (`f(conversationsByPanelId conversationsByTabId: T)`), or None."""
    if not re.match(r"[ \t]*:", src[b:b + 40]):
        return None
    m = re.search(r"([(,]\s*)([A-Za-z_]\w*)[ \t]+$", src[max(0, a - 200):a])
    if not m:
        return None
    start = a - (len(m.group(0)) - len(m.group(1)))
    # the label must open a parameter of a func/init declaration: test it as a parameter name of its own
    if not is_func_decl_param(src[:start + len(m.group(2))] + ":", start, start + len(m.group(2))):
        return None
    return start, start + len(m.group(2))


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
    if m and (m.group(1)[0].isupper() or re.match(r"ghostty_\w+$|\w+_[tes]$", m.group(1))):
        return False  # declaration: `name: Type` (including C types such as ghostty_surface_t)
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
TYPE_HEAD = re.compile(
    r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+|\w+(?:\([^)]*\))?\s+)*(?:class|struct|enum|extension|protocol|actor)\s+"
    r"(?!func\b|var\b|let\b|init\b|subscript\b|final\b)[A-Za-z_]")
CLOSURE_PARAMS = re.compile(r"\s*(?:\[[^\]]*\]\s*)?(?:\(([^)]*)\)|([\w, ]+?))(?:\s*->\s*[^\n{]+?)?\s+in\b")


class Block:
    __slots__ = ("open", "close", "parent", "header", "header_start", "own", "children", "is_type", "_desc", "inparen")

    def __init__(self, open_, parent, header, header_start, seg=""):
        self.open, self.close, self.parent = open_, None, parent
        self.header, self.header_start = header, header_start
        self.own, self.children = set(), []
        self.is_type = bool(TYPE_HEAD.search("\n".join(seg.split("\n")[-6:])))
        self.inparen = False
        self._desc = None


class Scopes:
    """Lexical block scopes of one Swift file: which names are bound locally where."""

    def __init__(self, src, lx):
        self.src = src
        self.blocks, stack, last = [], [], -1
        pdepth = 0
        merged = sorted(lx.events + lx.parens)
        for pos, ch in merged:
            if ch == "(":
                pdepth += 1
                continue
            if ch == ")":
                pdepth -= 1
                continue
            if ch == "{" and pdepth > 0:
                # a closure argument: not a statement boundary, keeps the surrounding statement's header
                blk = Block(pos, stack[-1] if stack else None, "", pos, "")
                if stack:
                    stack[-1].children.append(blk)
                self.blocks.append(blk)
                stack.append(blk)
                blk.inparen = True
                continue
            if ch == "}" and stack and getattr(stack[-1], "inparen", False):
                blk = stack.pop()
                blk.close = pos
                self._bind(blk)
                continue
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
                blk = Block(pos, stack[-1] if stack else None, header, hstart, seg)
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


KEPT_PROPERTY_NAMES = set()  # `noprop` names that some file declares as a stored property (filled by main)


def collect_kept_props(root, renames):
    """Names with a `noprop` rule that any file declares as a stored property."""
    names = {old for old, lst in renames.items() if any("noprop" in fl for _n, _g, _f, fl in lst)}
    found = set()
    if not names:
        return found
    for full in swift_files(root):
        src = open(full, encoding="utf-8").read()
        lx = Lexer(src)
        lx.scan(0, False)
        bodies = type_bodies(src, lx)
        for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
            props, _ = declared_names(src, inside)
            found |= {src[a:b] for a, b in props} & names
    return found


def _has_local_binding(text, name):
    """True if `text` binds `name` locally: let/var, for/case patterns, closure or function parameters."""
    n = re.escape(name)
    pats = [rf"\b(?:let|var)\s+(?:\(?[\w, ]*\b)?{n}\b", rf"\bfor\s+(?:\(?[\w, ]*\b)?{n}\b[\w, ]*\)?\s+in\b",
            rf"\{{[^}}\n]*\b{n}\b[^}}\n]*\bin\b", rf"\bfunc\s+\w+\s*\([^)]*\b{n}\s*:", rf"\binit\s*\([^)]*\b{n}\s*:"]
    return any(re.search(pt, text) for pt in pats)


def rewrite(src, rel, renames, report=None, keep_rules=None, callees=None, receivers=None):
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    keeps = [(set(n.split(',')), re.compile(rx), set(x.split(',')) if x else set()) for g, rx, n, x in (keep_rules or []) if any(fnmatch.fnmatch(rel, gg) for gg in g.split(","))]
    kept_cache = {}
    prop_owner = {}  # token start of a stored property declaration -> owning type name
    member_decl = {}  # token start of any member declaration (property, case, func) -> (owner, signature)
    pin_enum = {}   # token start -> old name, for implicit-raw String enum cases
    case_decl = set()  # token starts of enum case declarations
    hazard_pos = {}  # token start -> description, Codable property/case
    bodies = type_bodies(src, lx)
    for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
        mh = None
        for mh in re.finditer(rf"\b{kind}\s+{re.escape(name or '')}\b", header):
            pass
        h = header[mh.start():] if mh else header  # the declaration itself, not text that precedes it
        is_codable = re.search(r"\b(Codable|Encodable|Decodable)\b", h) is not None
        raw_string = kind == "enum" and re.search(r"\benum\s+\w+\s*(?:<[^>\n]*>)?\s*:\s*(?:[\w.]+\s*,\s*)*String\b", h) is not None
        props, cases = declared_names(src, inside)
        case_decl.update(a for a, _ in cases)
        for a, _ in props:
            prop_owner[a] = name
        for a, b in props + cases:
            member_decl[a] = (name, _decl_statement(src, a, b).strip()[:100])
        for k, (a, b) in enumerate(inside):
            if src[a:b] == "func" and k + 1 < len(inside) and src[b:inside[k + 1][0]].strip() == "":
                na = inside[k + 1][0]
                member_decl[na] = (name, src[a:a + 160].split("{")[0].strip()[:100])
        has_ck = any(src[a:b] == "CodingKeys" for a, b in inside)
        if raw_string:
            for a, b in cases:
                tail = src[b:b + 40].lstrip(" ")
                if not tail.startswith("="):
                    pin_enum[a] = src[a:b]
        elif is_codable and not has_ck:
            for a, b in props + (cases if kind == "enum" else []):
                hazard_pos[a] = f"{kind} {name}"
    prop_names = {src[a:b] for a in prop_owner for b in [next((y for x, y in lx.idents if x == a), a)]}
    label_kept_names = prop_names | KEPT_PROPERTY_NAMES
    scopes = Scopes(src, lx)
    type_spans = [(op, cl) for kind, name, header, op, cl in bodies if cl is not None]
    protected = set()  # (region, name): parameters of `keep` callees keep their name through the body
    if callees:
        for (a, b), r in zip(lx.idents, reg):
            if src[a:b] in renames and not is_call_label(src, a, b) and is_func_decl_param(src, a, b):
                if callees.get(callee_name(src, a) or "") == "keep":
                    protected.add((r, src[a:b]))
    force_fb = set()  # (region, name) pairs whose every occurrence takes the fallback (a shorthand binder must match)
    for attempt in (0, 1):
        used_fb = set()
        elog = []
        out, last, count = [], 0, 0
        for (a, b), r in zip(lx.idents, reg):
            if a < last:
                continue  # consumed by the edit before it (a parameter name dropped for its label)
            tok = src[a:b]
            lst = renames.get(tok)
            if not lst or tok in KEEP_FUNC_NAMES:
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
            vendor_recv = tuple(v for v in VENDOR_RECEIVERS
                                if not any(v == rcv and glob_match(rel, g.split(",")) for g, rcv in NOVENDOR))
            if pre.endswith(vendor_recv) or pre.endswith("@objc("):
                continue  # vendor member / ObjC runtime name (an external contract)
            is_label = is_call_label(src, a, b)
            is_param = (not is_label) and is_func_decl_param(src, a, b)
            # the external label of a declared parameter (`f(tabs panels: [P])`): a label never shadows anything
            decl_inner = None
            if not is_label and not is_param:
                mi = re.match(r"[ \t]+([A-Za-z_]\w*)[ \t]*:", src[b:b + 120])
                if mi:
                    lab = decl_label(src, b + mi.start(1), b + mi.end(1))
                    if lab and lab[0] == a:
                        decl_inner = (b + mi.start(1), b + mi.end(1))
            rule = None
            if callees:
                if is_label or is_param:
                    rule = callees.get(callee_name(src, a) or "")
                elif a in prop_owner:
                    rule = callees.get(prop_owner[a])
            if rule == "keep" or (rule and rule.startswith("keep:") and tok in rule[5:].split(",")):
                continue
            member = a >= 1 and src[a - 1] == "." and not is_implicit_member(src, a)
            mgr_member = member and RECV_MGR.search(src[max(0, a - 80):a - 1] + ".") is not None
            blocked = None
            if "labelonly" in flags or "recvmgr" in flags:
                ok = ("labelonly" in flags and is_label and not vendor_callee(src, a)) or (
                    "recvmgr" in flags and RECV_MGR.search(src[max(0, a - 80):a]) is not None)
                if not ok:
                    blocked = "leaf"
            if blocked is None and "nomember" in flags and member and (src[max(0, a - 5):a] != "self." or "noprop" in flags):
                blocked = "member"  # `x.name`: a vendor member, not a binding of this file
            if blocked is None and "noprop" in flags and a >= 1 and src[a - 1] == ".":
                blocked = "dot"  # `.name`, member or implicit: the name belongs to a kept declaration
            if blocked is None and "noprop" in flags and (a in prop_owner or a in case_decl):
                blocked = "prop"  # a stored property declaration keeps its name, with every `x.name` use of it
            if blocked is None and "noprop" in flags and not member and not is_label and tok in prop_names:
                blocked = "propfile"  # the file declares a property of this name: every bare use may be that property
            if blocked is None and "memberonly" in flags and not (a >= 1 and src[a - 1] == ".") and a not in case_decl:
                blocked = "notmember"  # only `.name` uses and the enum case declaration follow this rename
            if blocked is None and "nolabel" in flags and is_label:
                blocked = "label"  # call-site label: follows its declaration only when the callee is `@callee rename`
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
            # `(windowId: UUID, panelId: UUID)` in a return type: an element label, never a local or a member use
            ls_ = src.rfind("\n", 0, a) + 1
            is_tuple_label = (not is_param and src[b:b + 1] == ":" and re.search(r"[(,]\s*$", src[max(ls_, a - 60):a]) is not None
                              and "->" in src[ls_:a])
            implicit = a >= 1 and src[a - 1] == "."  # `.tab(let id)`: an implicit member is never shadowed by a local
            if blocked is None and not member and not implicit and not is_label and not is_tuple_label and decl_inner is None:
                clash, local = scopes.conflict(a, tok, new)
                if (r, tok) in force_fb and fallback and not is_param and local:
                    new, clash = fallback, False
                    used_fb.add((r, tok))
                if clash:
                    if not local and not is_param and any(op < a < cl for op, cl in type_spans):
                        new = "self." + new  # a member use: qualify so a same-named local cannot capture it
                    elif is_param:
                        inner = fallback if fallback and not scopes.conflict(a, tok, fallback)[0] else tok
                        new = f"{new} {inner}"  # `func f(newLabel inner: T)`: label follows the rename, body keeps a safe name
                    elif fallback and not scopes.conflict(a, tok, fallback)[0]:
                        new = fallback
                        used_fb.add((r, tok))
                    elif not local and not is_param:
                        blocked = "collision"  # outside a type `self.` does not exist: leave it
                        if rule != "rename" and report is not None:
                            report.append(f"COLLISION {rel}:{src.count(chr(10), 0, a) + 1} {tok} -> {new} (free function; left as is)")
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
            logged_old = tok
            if decl_inner is not None and src[decl_inner[0]:decl_inner[1]] == new:
                logged_old = f"{tok} {new}"
                b = decl_inner[1]  # `openPanelMatches openPanelMatches:` -> `openPanelMatches:`
            if a in hazard_pos and report is not None:
                line = src.count("\n", 0, a) + 1
                report.append(f"CODABLE {rel}:{line} {tok} -> {new} in {hazard_pos[a]} (no CodingKeys: pin the old key by hand)")
            cls_ = _ev_class(flags)
            site_ = ""
            if cls_ in ("M", "Leaf"):
                if a in member_decl:
                    site_ = "owner=%s; %s" % member_decl[a]
                else:
                    cls_ = "Muse" if cls_ == "M" else "Leafuse"
            elog.append((rel, src.count("\n", 0, a) + 1, logged_old, new, cls_, site_))
            last = b
            count += 1
        out.append(src[last:])
        if attempt or not (used_fb - force_fb):
            break
        force_fb = used_fb
    EVIDENCE.extend(elog)
    return "".join(out), count



TAINT_TYPE = (r"(?:ExternalTab\w*|ExternalPaneNode|TabID|\[TabID\]|Set<TabID>|\[TabID\]\??|TabID\?|Bonsplit\.Tab|\[Bonsplit\.Tab\]|Bonsplit\.Tab\?|"
              r"TabInfo|\[TabInfo\]|\(TabID\) ->)")


def _open_depth(frag):
    """Net count of delimiters a text fragment leaves open."""
    return sum(frag.count(c) for c in "({[") - sum(frag.count(c) for c in ")}]")


def _statement_tail(text, i, depth=0):
    """Text from `i` to the end of the expression it continues: stops at an unbalanced closer, or at a
    newline at depth 0 whose next non-blank character does not continue the chain with `.`.
    `depth` seeds the nesting already open at `i` (a leaf-source match such as `tabs(inPane:` ends
    inside its call)."""
    j = i
    n = len(text)
    while j < n:
        ch = text[j]
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
            if depth < 0:
                break
        elif ch == "\n" and depth == 0:
            k = j + 1
            while k < n and text[k] in " \t\n":
                k += 1
            if k >= n or text[k] != ".":
                break
        j += 1
    return text[i:j]


def _find_tainted_once(text, rx, names, exclude=None, skip=frozenset(), funcs=False, bindonly=False, leaftype=True, assigns=False):
    """Names (from `names`) bound in `text` to a value whose binding statement matches `rx`.

    A binding site is `let/var/guard let/if let/for NAME ... = <rhs>` (the rhs may continue on up to
    three `.chained` lines), a name annotated with a leaf type, or a closure parameter in a statement
    that already mentions a tainted name.
    """
    tainted = set()
    names = [n for n in names if n in text]  # cheap filter: only names that occur in this member
    for name in names:
        n = re.escape(name)
        pats = [
            rf"\b(?:let|var)\s+{n}\b[^=\n]*=\s*[^\n]*(?:\n\s*\.[^\n]*){{0,3}}",
            rf"\b(?:guard|if)\s+(?:let|var)\s+{n}\b[^=\n]*=\s*[^\n]*(?:\n\s*\.[^\n]*){{0,3}}",
            rf"\bfor\s+(?:\(?[\w, ]*\b)?{n}\b[\w, ]*\)?\s+in\s+[^\n{{]*",
        ]
        if assigns:  # `NAME = <rhs>` re-assignments carry the source too
            pats.append(rf"(?<![.\w]){n}\s*=(?!=)\s*[^\n]*(?:\n\s*[.?][^\n]*){{0,3}}")
        for pt in pats:
            for m in re.finditer(pt, text):
                if text.find(name, m.start()) in skip:
                    continue  # the declaration of a stored property: it keeps its name
                stmt = m.group(0).replace(name, " ", 1)  # the bound name is not part of its own source
                if re.search(r"(?:\[|,|\bweak|\bunowned)\s*$", text[max(0, m.start() - 12):m.start()]) and "]" in stmt:
                    stmt = stmt[:stmt.index("]")]  # a capture list `[weak NAME = expr] in ...`: the source ends at `]`
                if rx.search(stmt) and not (exclude and exclude.search(stmt)):
                    tainted.add(name)
                    SNIP.setdefault(name, m.group(0).strip()[:140])
        if bindonly:
            continue  # only `let/guard let/for NAME = <source>` binding statements count
        for mt in re.finditer(rf"\b{n}\s*:\s*{TAINT_TYPE}", text) if leaftype else ():
            if mt.start() not in skip:
                tainted.add(name)
                SNIP.setdefault(name, mt.group(0).strip()[:140])
        # a name annotated with a type the rule recognizes: `NAME: [TabID: UUID]`, `NAME: ghostty_surface_t?`
        for mt in re.finditer(rf"\b{n}\s*:\s*([^,)=\n{{]+)", text):
            ann = mt.group(1).lstrip()
            if not re.match(r"[A-Z\[(@]|(?:any|some|inout)\s|ghostty_\w+|\w+_[tes]\b", ann) or re.match(r"[\w.]+\(", ann):
                continue  # `label: expression` / `label: Type(args)` at a call site, not a type annotation
            if mt.start() not in skip and rx.search(mt.group(1)) and not (exclude and exclude.search(mt.group(1))):
                tainted.add(name)
                SNIP.setdefault(name, mt.group(0).strip()[:140])
        if funcs:  # `func NAME(... ghostty_surface_t ...) -> ...`: the signature carries the domain
            for mt in re.finditer(rf"\bfunc\s+{n}\b[^{{]{{0,600}}", text):
                if rx.search(mt.group(0)):
                    tainted.add(name)
                    SNIP.setdefault(name, mt.group(0).strip()[:140])
    if bindonly:
        return tainted
    # Direct closure binders: `leaf.map { tab in ... }`, `.first(where: { t in ... })`, `sorted(by: { a, b in ... })`.
    # The statement that continues from a leaf-source match (to the end of its call chain) is scanned for
    # closure parameter lists naming one of `names`.
    for m in rx.finditer(text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        seed = max(0, _open_depth(text[line_start:m.end()]))  # delimiters still open at the end of the match
        seg = _statement_tail(text, m.end(), seed)
        for cm in re.finditer(r"\{\s*(?:\[[^\]]*\]\s*)?\(?([\w, ]+?)\)?\s+in\b", seg):
            for p_ in re.split(r"\s*,\s*", cm.group(1).strip()):
                if p_ in names:
                    tainted.add(p_)
                    SNIP.setdefault(p_, (text[max(0, m.start() - 40):m.end()] + seg[:cm.end()]).strip()[:140])
    changed = True
    while changed:
        changed = False
        for name in names:
            if name in tainted:
                continue
            n = re.escape(name)
            for m in re.finditer(rf"\{{\s*(?:\[[^\]]*\]\s*)?\(?[\w, ]*\b{n}\b[\w, ]*\)?\s+in\b", text):
                line_start = text.rfind("\n", 0, m.start()) + 1
                stmt = text[max(0, line_start - 200):m.start()]
                if any(re.search(rf"\b{re.escape(t)}\b", stmt) for t in tainted):
                    tainted.add(name)
                    SNIP.setdefault(name, "via " + stmt.strip()[-100:])
                    changed = True
                    break
    return tainted


def find_tainted(text, rx, names, extra=(), exclude=None, skip=frozenset(), funcs=False, bindonly=False, onehop=False, leaftype=True, assigns=False):
    """`_find_tainted_once`, closed under iteration: a binding whose source expression mentions an
    already-tainted name (or one of `extra`, the leaf spellings such as `bonsplitTabs`) is tainted too."""
    tainted = _find_tainted_once(text, rx, names, exclude, skip, funcs, bindonly, leaftype, assigns)
    if bindonly:
        return tainted
    hops = 0
    while True:
        words = sorted(set(tainted) | set(extra))
        if not words or (onehop and hops >= 1):
            return tainted
        rx2 = re.compile(rx.pattern + r"|(?<![.\w])(?:" + "|".join(re.escape(w) for w in words) + r")\b")
        grown = _find_tainted_once(text, rx2, names, exclude, skip, funcs, bindonly, leaftype, assigns)
        if grown <= tainted:
            return tainted
        tainted |= grown
        hops += 1


KEEP_SENTINEL = "__C11KEEP__"  # appended by a `keep` taint so the generic renames skip the token; stripped afterwards
LEAF_PROP_NAMES = set()  # names of `props` taint targets that some file declares as a leaf-typed property (filled by main)


KEEP_FUNC_NAMES = set()  # functions a `keep,funcs` taint protects: declaration and every call keep the name


def collect_keep_funcs(root, taint_rules):
    """Functions whose every declaration has a signature the `keep,funcs` rules recognize (a name that is also
    declared with a non-matching signature elsewhere is ambiguous and is left to the generic rename)."""
    rules = [(re.compile(rx), mp, re.compile(ex) if ex else None) for g, rx, mp, rr, ex, opts in taint_rules if {"keep", "funcs"} <= opts]
    if not rules:
        return set()
    match, other = set(), set()
    for full in swift_files(root):
        src = open(full, encoding="utf-8").read()
        for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\b[^{]{0,600}", src):
            name = m.group(1)
            for rx, mp, ex in rules:
                if name in mp:
                    (match if rx.search(m.group(0)) and not (ex and ex.search(m.group(0))) else other).add(name)
    return match - other


def collect_keep_labels(root, taint_rules):
    """{function name: {labels}} for functions with a parameter whose type a `keep` rule recognizes and whose name
    (or label) the rule protects: the call sites keep that label (`f(_ x: Int, surface: ghostty_surface_t)`)."""
    rules = [(re.compile(rx), mp) for g, rx, mp, rr, ex, opts in taint_rules if "keep" in opts]
    out = {}
    if not rules:
        return out
    for full in swift_files(root):
        src = open(full, encoding="utf-8").read()
        for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\(([^{]*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->|\{|$)", src):
            for pm in re.finditer(r"(?:(\w+)\s+)?(\w+)\s*:\s*([^,]+)", m.group(2)):
                label = pm.group(1) or pm.group(2)
                for rx, mp in rules:
                    if label in mp and rx.search(pm.group(3)):
                        out.setdefault(m.group(1), set()).add(label)
    return out


def strip_keep(text):
    return text.replace(KEEP_SENTINEL, "")


def _mask_comments(text):
    """Blank out comment text (same length) so doc comments never count as a binding's evidence."""
    return re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def _decl_statement(src, a, b):
    """The declaration line of the property whose name token is at [a, b)."""
    ls = src.rfind("\n", 0, a) + 1
    le = src.find("\n", b)
    return src[ls:(len(src) if le < 0 else le)]


def collect_leaf_props(root, taint_rules):
    """Property names declared (anywhere) with a type or initializer a `props`/`keep` rule recognizes, per rule,
    minus names that some other declaration of the same name does not match (those are ambiguous and are not
    renamed across files)."""
    rules = [(re.compile(rx), mp, re.compile(ex) if ex else None) for g, rx, mp, rr, ex, opts in taint_rules if opts & {"props", "keep"}]
    if not rules:
        return set()
    leaf = [set() for _ in rules]
    other = [set() for _ in rules]
    for full in swift_files(root):
        src = open(full, encoding="utf-8").read()
        lx = Lexer(src)
        lx.scan(0, False)
        bodies = type_bodies(src, lx)
        for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
            for a, b in declared_names(src, inside)[0]:
                tok = src[a:b]
                decl = _decl_statement(src, a, b)
                for i, (rx, mp, ex) in enumerate(rules):
                    if tok in mp:
                        (leaf if rx.search(decl) and not (ex and ex.search(decl)) else other)[i].add(tok)
    out = set()
    for i in range(len(rules)):
        out |= leaf[i] - other[i]
    return out


def is_return_tuple_label(src, a, b):
    """`name:` directly inside the parenthesised tuple of a `-> (...)` return type: a label members reach as `.name`."""
    if not re.match(r"\s*:", src[b:b + 4]):
        return False
    depth, i = 0, a - 1
    while i >= 0 and a - i < 600:
        c = src[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                return re.search(r"->\s*$", src[max(0, i - 8):i]) is not None
            depth -= 1
        elif c in "{};":
            return False
        i -= 1
    return False


def taint_pass(src, rel, taint_rules, report=None):
    """Rename names that are bound to leaf values (by their binding site), per member.

    Rule options: `keep` (the target is the name itself, protected from the generic renames),
    `funcs` (a function whose signature matches carries the domain), `props` (a leaf-typed stored
    property is renamed with every use of it).
    """
    rules = [(re.compile(rx), mp, re.compile(rr) if rr else None, re.compile(ex) if ex else None, opts)
             for g, rx, mp, rr, ex, opts in taint_rules if glob_match(rel, g.split(","))]
    if not rules:
        return src, 0
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    edits = {}  # token start -> (end, text); the first rule to claim a token wins
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        by_region.setdefault(r, []).append((a, b))
    # stored property declarations keep their names unless a `props` rule recognizes them as leaf values
    bodies = type_bodies(src, lx)
    prop_decl_pos = set()
    file_props = {}  # property name -> declaration start, for every stored property
    for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
        for a, b in declared_names(src, inside)[0]:
            prop_decl_pos.add(a)
            file_props[src[a:b]] = a
    leaf_prop_here = set()
    for rx, mp, rr, ex, opts in rules:
        if not opts & {"props", "keep"}:
            continue
        for tok, a in file_props.items():
            if tok in mp:
                decl = _decl_statement(src, a, a + len(tok))
                if rx.search(decl) and not (ex and ex.search(decl)):
                    leaf_prop_here.add((tok, id(mp)))
    for rule_i, (rx, mp, rr, ex, opts) in enumerate(rules):
        def target(tok):
            t = mp[tok]
            return tok + KEEP_SENTINEL if t == "@keep" else t
        props_here = {tok for tok, mid in leaf_prop_here if mid == id(mp)}
        # a leaf property is renamed everywhere in its file, `x.name` uses included, and in other files by `.name`
        if opts & {"props", "keep"}:
            for (a, b) in lx.idents:
                tok = src[a:b]
                member = a >= 1 and src[a - 1] == "."
                if tok in mp and ((tok in props_here) or (member and tok in LEAF_PROP_NAMES and not is_call_label(src, a, b))):
                    if not is_call_label(src, a, b) and a not in edits:
                        if tok in props_here:
                            edits[a] = (b, target(tok), _ev_class(opts), _decl_statement(src, file_props[tok], file_props[tok] + len(tok)).strip()[:140])
                        else:  # a `.name` use in a file that does not declare it: the declaration elsewhere is the evidence
                            edits[a] = (b, target(tok), _ev_class(opts) + "use", "")
        for r, toks in by_region.items():
            a0, b0 = spans[r]
            text = _mask_comments(src[a0:b0])
            if rr is not None and not rr.search(text):
                continue
            skip = frozenset(p - a0 for p in prop_decl_pos if a0 <= p < b0)
            SNIP.clear()
            extra_words = set() if "noextra" in opts else set(v for v in mp.values() if v != "@keep")
            tainted = find_tainted(text, rx, mp, extra_words, ex, skip, "funcs" in opts, "bindonly" in opts, "onehop" in opts, "noleaftype" not in opts)
            tainted -= props_here  # already renamed file-wide
            if not tainted:
                continue
            # a call label is not a binding, and a qualified member (`ws.terminalPanel(for:)`) cannot be shadowed by a local
            present = collections.Counter(src[a:b] for a, b in toks if not is_call_label(src, a, b) and not (a >= 1 and src[a - 1] == "."))
            # `f(panelsToWrite tabsToWrite: T)` whose name takes its label's spelling: the duplicate name is dropped
            collapse = {}
            for a, b in toks:
                tok = src[a:b]
                if tok in tainted and a not in prop_decl_pos and mp[tok] != "@keep":
                    lab = decl_label(src, a, b)
                    if lab and src[lab[0]:lab[1]] == target(tok):
                        collapse[a] = lab
            for a, (la, lb) in collapse.items():
                present[src[la:lb]] -= 1
            present = {t for t, n in present.items() if n > 0}
            for a, b in toks:
                tok = src[a:b]
                if tok in tainted and a not in prop_decl_pos and not (a >= 1 and src[a - 1] == ".") and not is_call_label(src, a, b) \
                        and not is_return_tuple_label(src, a, b):
                    if a in edits:
                        continue
                    tgt = target(tok)
                    if tgt in present and tgt != tok and mp[tok] != "@keep":
                        if report is not None:
                            report.append(f"TAINT-COLLISION {rel}:{src.count(chr(10), 0, a) + 1} {tok} -> {tgt}")
                        continue
                    if a in collapse:
                        la, lb = collapse[a]
                        edits[lb] = (b, "", _ev_class(opts), SNIP.get(tok, ""))
                        EVIDENCE.append((rel, src.count("\n", 0, a) + 1, src[la:b], src[la:lb], _ev_class(opts), SNIP.get(tok, "")))
                        continue
                    if is_func_decl_param(src, a, b) and mp[tok] != "@keep" and "relabel" not in opts:
                        tgt = f"{tok} {tgt}"  # `f(panel: P)` -> `f(panel tab: P)`: the call-site label keeps its spelling
                    edits[a] = (b, tgt, _ev_class(opts), SNIP.get(tok, ""))
    if not edits:
        return src, 0
    out, last = [], 0
    for a in sorted(edits):
        b, t, cls, site = edits[a]
        if a < last:
            continue
        out.append(src[last:a])
        out.append(t)
        if t and not t.endswith(KEEP_SENTINEL):  # a dropped duplicate name (empty text) was logged as `label name` -> `label`
            EVIDENCE.append((rel, src.count("\n", 0, a) + 1, src[a:b], t, cls, site))
        last = b
    out.append(src[last:])
    return "".join(out), sum(1 for a in edits if not edits[a][1].endswith(KEEP_SENTINEL))


def check_leaf(src, rel, taint_rules, renames, report):
    """Report bindings that carry a workspace name although their binding site matches a leaf rule.

    Independent of the apply pass: every identifier containing `workspace` (any case) is a candidate
    name, not just the renamed family, so a leaf binding the pass did not know about is caught too.
    """
    hits = 0
    # every short collision spelling the table can emit (`ws`, ...) is a candidate workspace name too
    fallbacks = {fb for lst in renames.values() for _new, _globs, fb, _fl in lst if fb}
    # the generic spelling each tainted name would have received (`tabId` for `surfaceId`, ...)
    generic = {new for g, rx, mp, rr, ex, opts in taint_rules for old in mp for new, _gl, _fb, _fl in renames.get(old, [])}
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        by_region.setdefault(r, []).append((a, b))
    for g, rx, mp, rr, ex, opts in taint_rules:
        if opts & {"keep"} or not glob_match(rel, g.split(",")):
            continue
        rxc = re.compile(rx)
        exc = re.compile(ex) if ex else None
        rrc = re.compile(rr) if rr else None
        for r, toks in by_region.items():
            a0, b0 = spans[r]
            text = src[a0:b0]
            if rrc is not None and not rrc.search(text):
                continue
            names = sorted({src[a:b] for a, b in toks
                            if (re.search(r"(?i)workspace", src[a:b]) and src[a:b] != "Workspace") or src[a:b] in fallbacks
                            or src[a:b] in generic})
            if not names:
                continue
            for name in sorted(find_tainted(text, rxc, names, set(mp.values()), exc)):
                for a, b in toks:
                    if src[a:b] == name and not (a >= 1 and src[a - 1] == "."):
                        report.append(f"LEAF-MISNAME {rel}:{src.count(chr(10), 0, a) + 1} {name} (binding matches the {g.split(',')[0]} leaf rule)")
                        hits += 1
                        break
    return hits


def region_rename_pass(src, rel, region_rules):
    """Rename tokens inside the members (regions) whose text matches the rule's region regex."""
    rules = [(re.compile(rr), mp) for g, rr, mp in region_rules if glob_match(rel, g.split(","))]
    if not rules:
        return src, 0
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    edits = []
    for (a, b), r in zip(lx.idents, reg):
        a0, b0 = spans[r]
        tok = src[a:b]
        for rr, mp in rules:
            if tok in mp and not (a >= 1 and src[a - 1] == ".") and rr.search(src[a0:b0]) and not is_call_label(src, a, b):
                edits.append((a, b, mp[tok]))
                break
    if not edits:
        return src, 0
    out, last = [], 0
    for a, b, t in sorted(edits):
        out.append(src[last:a])
        out.append(t)
        EVIDENCE.append((rel, src.count("\n", 0, a) + 1, src[a:b], t, "X", "explicit region rule"))
        last = b
    out.append(src[last:])
    return "".join(out), len(edits)


def codable_pin_pass(src, rel, renames):
    """Insert `enum CodingKeys` for Codable types without one whose stored properties get renamed, so
    every key stays at its on-disk name (renamed properties map to their old key, others to themselves)."""
    lx = Lexer(src)
    lx.scan(0, False)
    bodies = type_bodies(src, lx)
    edits = []
    for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
        if kind not in ("struct", "class") or cl is None:
            continue
        mh = None
        for mh in re.finditer(rf"\b{kind}\s+{re.escape(name or '')}\b", header):
            pass
        h = header[mh.start():] if mh else header
        if not re.search(r"\b(Codable|Encodable|Decodable)\b", h) or any(src[a:b] == "CodingKeys" for a, b in inside):
            continue
        props, _ = declared_names(src, inside)
        stored = []
        for a, b in props:
            ls = src.rfind("\n", 0, a) + 1
            le = src.find("\n", b)
            le = len(src) if le < 0 else le
            if re.search(r"\b(static|class|lazy)\b", src[ls:a]) or "{" in src[b:le]:
                continue  # not a stored instance property
            stored.append(src[a:b])
        pins = []
        for n in stored:
            new = None
            for cand, globs, fb, fl in renames.get(n, []):
                if glob_match(rel, globs):
                    new = None if "noprop" in fl else cand  # a kept property keeps its key too
                    break
            pins.append((new or n, n))
        if not any(new != old for new, old in pins):
            continue
        indent = re.match(r"\s*", src[src.rfind("\n", 0, op) + 1:op]).group(0) + "    "
        lines = [f"{indent}// C11-248: persisted keys keep their on-disk names.",
                 f"{indent}enum CodingKeys: String, CodingKey {{"]
        for new, old in pins:
            lines.append(f"{indent}    case {new} = \"{old}\"" if new != old else f"{indent}    case {new}")
        lines.append(f"{indent}}}")
        edits.append((src.rfind("\n", 0, cl) + 1, "\n" + "\n".join(lines) + "\n"))
    if not edits:
        return src, 0
    out, last = [], 0
    for pos, text in sorted(edits):
        out.append(src[last:pos])
        out.append(text)
        last = pos
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
        was_dir = os.path.isdir(o)
        if dry:
            continue
        os.makedirs(os.path.dirname(nw), exist_ok=True)
        if use_git:
            subprocess.check_call(["git", "mv", o, nw], cwd=root)
        else:
            os.rename(o, nw)
        changed += 1
        if was_dir:  # file references are group-relative: `path = Panels/X.swift`
            pbx_text = re.sub(r"(path = )" + re.escape(os.path.basename(old)) + r"/", lambda m: m.group(1) + os.path.basename(new) + "/", pbx_text)
        # pbxproj: replace the full relative path and, for files, the basename
        # token in comments/ids. Path references use `path = <rel to group>;`.
        pbx_text = pbx_text.replace(old, new)
        ob, nb = os.path.basename(old), os.path.basename(new)
        if ob != nb:
            pbx_text = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(ob) + r"(?![A-Za-z0-9_])", nb, pbx_text)
    if changed and not dry:
        open(pbx, "w", encoding="utf-8").write(pbx_text)
    return changed


# ---- independent domain gate (`check-domains`): defined here, not derived from any pass table ----------------
DOMAIN_GHOSTTY = (r"\bghostty_surface_\w+|\bGhosttySurface\w*|\bTerminalSurface(?:Registry)?\b|\bIOSurface\w*|"
                  r"\blayer\??\.contents\b|\.runtimeSurface\b|\bGhosttyNSView\b|"
                  r"=\s*(?:self\.)?surface\b(?![\w.(])(?!\s*[.(])|"
                  # the raw handle read out of a wrapper, and the entry points that resolve or wait for one
                  r"\.surface\.surface\b(?!\s*[!=<>]=)|\.initialSurface\b|\bwaitForTerminalSurface\w*|\bresolveTerminalSurface\w*|"
                  r"\bliveSurface\b|\binitialSurface\b")
LEAF_LABEL_DECLS = set()  # external labels of our own functions whose parameter is a Bonsplit TabID (filled by check_domains_main)
GHOSTTY_RETURNING = set()  # names of functions declared to return the Ghostty handle or wrapper (filled by check_domains_main)
DOMAIN_LEAF = (r"\btabs\(\s*inPane:|\bselectedTab\(\s*inPane:|\ballTabIds\b|"
               r"\bbonsplitController\??\.(?:tabs|selectedTab|allTabIds|tab\(|createTab\b)|\bcreateTab\(|"
               r"\bsurfaceIdFromPanelId\b|\bbonsplitTabIdFrom(?:Tab|Panel)Id\b|\bBonsplit\.Tab\b|\bTabInfo\b|\bTabID\b|"
               r"\b\w*[pP]ane\.(?:tabs|selectedTabId)\b|\bExternalPaneNode\b|\bExternalTab\w*|"
               r"\blayout\.panes\b|\b\w*BonsplitTab\w*\b|\bbonsplitTab\w*\b")
DOMAIN_LEAF_EXCLUDE = (r"=\s*(?:[\w?!.()]*\.)?(?:tabIdFromBonsplitTabId|panelIdFromBonsplitTabId|panelIdFromSurfaceId)\b|"
                       # c11 resolvers that take a Bonsplit id as an argument and return a c11 tab or id
                       r"=\s*(?![\w?!.()]*bonsplitController)(?:[\w?!.()]*\.)?(?:tab|terminalTab|browserTab|markdownTab|tabID|tabId|sessionTabID|newTab\w*|"
                       r"panel|terminalPanel|browserPanel|markdownPanel|panelID|panelId|sessionPanelID|newPanel\w*)\s*\(|"
                       r"=\s*(?:self\.)?create(?:Tab|Panel)\s*\(|"
                       r"\bbonsplitTabIdTo(?:Tab|Panel)Id\b|"
                       r"\.(?:map|compactMap|flatMap|reduce|enumerated)\b(?!\s*\{\s*\$0\.id\s*\})")
DOMAIN_C11 = (r"\bnew(?:Terminal|Browser|Markdown)(?:Panel|Surface|Tab)\w*\(|\.(?:panels|surfaces|tabs)\[|"
              r"\b(?:terminalPanel|browserPanel|markdownPanel|terminalTab|browserTab|markdownTab)\(for\b|"
              r"\b(?:TerminalPanel|BrowserPanel|MarkdownPanel|TerminalTab|BrowserTab|MarkdownTab|TabContent|Panel)\b|"
              r"=\s*(?:[\w?!.()]*\.)?(?:tabIdFromBonsplitTabId|panelIdFromBonsplitTabId|panelIdFromSurfaceId)\b")
DOMAIN_GHOSTTY_LIFECYCLE = (r"createTab|teardownTab|releaseTabForTesting|allTabs|runtimeTab\w*|recordRuntimeTabCreation|"
                            r"requestBackgroundTabStartIfNeeded|backgroundTabStartQueued|tabLog\w*|sendTextToTab|"
                            r"hasTab(?![A-Z])|waitForTerminalTab\w*|resolveTerminalTab\w*|initialTab|liveTab|"
                            r"createPanel|teardownPanel|releasePanelForTesting|allPanels|runtimePanel\w*|recordRuntimePanelCreation|"
                            r"requestBackgroundPanelStartIfNeeded|backgroundPanelStartQueued|panelLog\w*|sendTextToPanel|"
                            r"hasPanel(?![A-Z])|waitForTerminalPanel\w*|resolveTerminalPanel\w*|initialPanel|livePanel")
# pane domain: a Bonsplit PaneID value is a Bonsplit pane and never carries the c11 area name
DOMAIN_PANE_LEAF = (r"\bPaneID\b|\bPaneState\b|\bExternalPaneNode\b|\bPaneGeometry\b|\bPaneBounds\b|\binPane\s*:|"
                    r"\bbonsplitController\??\.(?:focusedPaneId|allPaneIds|selectedPane\w*|pane\(|paneIds)\b|\bfocusedPaneId\b|\ballPaneIds\b")
DOMAIN_PANE_LEAF_EXCLUDE = r"\.(?:map|compactMap|flatMap|reduce)\b(?!\s*\{\s*\$0\.id\s*\})"
# geometry: a CGFloat/CGRect measure named `area` (width * height, intersection areas)
DOMAIN_GEOMETRY = (r":\s*CGFloat\b|\bCGRect\b|\bNSRect\b|\bCGSize\b|\.intersection\(|[\w.]*\bwidth\s*\*\s*[\w.]*\bheight\b|"
                   r"[\w.]*\bheight\s*\*\s*[\w.]*\bwidth\b")
DOMAIN_AREA_TYPE = r"\b(?:Area[A-Z]\w*|\w+Area[A-Z]\w*|SessionAreaLayoutSnapshot)\s*[({.]|:\s*(?:\w+\.)?(?:Area[A-Z]\w*|\w*Area(?:Spec|Box|Interaction\w*|MetadataStore))\b"
_AREA_SEGMENT = re.compile(r"(?:^|[a-z0-9])[Aa]rea(?:s|Id|Ids|ID|IDs|UUID)?(?=[A-Z]|$)")


def _is_area_name(name):
    return name[0].islower() and bool(_AREA_SEGMENT.search(name)) and not re.search(r"(?i)safe|tracking|overflow|content|text|intersection|portalHost|threshold", name)


# the c11 leaf word in either spelling: `tab` (C11-248) and `panel` (C11-337)
_TAB_SEGMENT = re.compile(r"(?:^|[a-z0-9])(?:[Tt]ab|[Pp]anel)(?:s|Id|Ids|ID|IDs|Raw)?(?=[A-Z]|$)")


def _is_c11_tab_name(name):
    return (name[0].islower() and bool(_TAB_SEGMENT.search(name)) and "onsplit" not in name and "External" not in name
            and not re.search(r"(Count|Index|Offset|Ordinal)$|^for[A-Z]|^(has|is|should|can)[A-Z]", name))


def _is_loose_tab_name(name):
    """Like _is_c11_tab_name but also the readiness and derived names (hasTab, shouldWaitForTab, exitTabHasTabBeforeCtrlD)."""
    return (name[0].islower() and bool(_TAB_SEGMENT.search(name)) and "onsplit" not in name and "External" not in name
            and not re.search(r"(Count|Index|Offset|Ordinal)$|^for[A-Z]", name))


def _is_bonsplit_tab_name(name):
    return "onsplitTab" in name and name[0].islower()


def check_domains(src, rel, report):
    """Bindings in the wrong naming domain, judged by their own type or source (no table involved):
    A  a tab-named binding typed/sourced from the Ghostty surface or IOSurface domain
    B  a c11 tab-named binding (tab, tabId, newTabId, ...) typed/sourced from a Bonsplit leaf
    C  a bonsplitTab*-named binding sourced from a c11 tab"""
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        by_region.setdefault(r, []).append((a, b))
    gh_rx = DOMAIN_GHOSTTY + (r"|\b(?:" + "|".join(sorted(map(re.escape, GHOSTTY_RETURNING))) + r")\s*\(" if GHOSTTY_RETURNING else "")
    gh, leaf, c11 = re.compile(gh_rx), re.compile(DOMAIN_LEAF), re.compile(DOMAIN_C11)
    ready = re.compile(DOMAIN_GHOSTTY + r"|\.surface\.surface\s*!=\s*nil")
    leaf_ex = re.compile(DOMAIN_LEAF_EXCLUDE)
    counts = {"A": 0, "B": 0, "C": 0, "D": 0, "E": 0}
    pane_leaf, pane_ex = re.compile(DOMAIN_PANE_LEAF), re.compile(DOMAIN_PANE_LEAF_EXCLUDE)
    geometry, area_type = re.compile(DOMAIN_GEOMETRY), re.compile(DOMAIN_AREA_TYPE)
    for r, toks in by_region.items():
        a0_, b0_ = spans[r]
        text_ = src[a0_:b0_]
        area_names = sorted({src[a:b] for a, b in toks if _is_area_name(src[a:b])})
        if area_names:
            # D: an area-named binding that holds a Bonsplit pane
            for name in sorted(find_tainted(text_, pane_leaf, area_names, (), pane_ex, frozenset(), False, False, False, False)):
                for a, b in toks:
                    if src[a:b] == name and not (a >= 1 and src[a - 1] == "."):
                        report.append(f"DOMAIN-LEAK-D {rel}:{src.count(chr(10), 0, a) + 1} {name} (a Bonsplit pane named for the c11 area)")
                        counts["D"] += 1
                        break
            # E: one name bound to a geometry measure and to a c11 area in the same member
            geo = find_tainted(text_, geometry, area_names, (), None, frozenset(), False, False, False, False)
            both = geo & find_tainted(text_, area_type, area_names, (), None, frozenset(), False, False, False, False)
            for name in sorted(both):
                for a, b in toks:
                    if src[a:b] == name and not (a >= 1 and src[a - 1] == "."):
                        report.append(f"DOMAIN-LEAK-E {rel}:{src.count(chr(10), 0, a) + 1} {name} (geometry and c11 area share a name)")
                        counts["E"] += 1
                        break
        a0, b0 = spans[r]
        text = src[a0:b0]
        names = {src[a:b] for a, b in toks}
        probes = (("A", gh, None, sorted(n for n in names if _is_loose_tab_name(n) and not re.match(r"(?:has|is|should)[A-Z]", n))),
                  ("A", ready, None, sorted(n for n in names if _is_loose_tab_name(n) and re.match(r"(?:has|is|should)[A-Z]", n))),
                  ("B", leaf, leaf_ex, sorted(n for n in names if _is_c11_tab_name(n))),
                  ("C", c11, None, sorted(n for n in names if _is_bonsplit_tab_name(n))))
        for dom, rx, ex, cand in probes:
            if not cand:
                continue
            for name in sorted(find_tainted(text, rx, cand, (), ex, frozenset(), False, dom == "C", False, True, dom == "A")):
                for a, b in toks:
                    if src[a:b] == name and not (a >= 1 and src[a - 1] == "."):
                        report.append(f"DOMAIN-LEAK-{dom} {rel}:{src.count(chr(10), 0, a) + 1} {name}")
                        counts[dom] += 1
                        break
    # a `should`/`wait` flag that guards a block touching the Ghostty handle (`if shouldWaitForTab { ... waitForTerminal... }`)
    for m in re.finditer(r"\bif\s+((?:should|wait)\w*)\s*\{", src):
        if _is_loose_tab_name(m.group(1)) and (gh.search(src[m.end():m.end() + 900]) or re.search(r"\bwaitForTerminal\w*", src[m.end():m.end() + 900])):
            report.append(f"DOMAIN-LEAK-A {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (guards a Ghostty readiness wait)")
            counts["A"] += 1
    # a tab-named function that returns the Ghostty handle or wrapper objects (`func resolveTab(...) -> ghostty_surface_t?`)
    for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\([^{]*?\)\s*(?:async\s*)?(?:throws\s*)?->\s*([^{\n]+)", src):
        if _is_c11_tab_name(m.group(1)) and gh.search(m.group(2)):
            report.append(f"DOMAIN-LEAK-A {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (returns a Ghostty value)")
            counts["A"] += 1
    # a tab-named function whose parameter is the Ghostty handle or wrapper (`func fontSize(_ tab: ghostty_surface_t)`)
    for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\(([^{]*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->|\{)", src):
        if _is_c11_tab_name(m.group(1)) and re.search(r"ghostty_surface_\w+|\bTerminalSurface\b", m.group(2)):
            report.append(f"DOMAIN-LEAK-A {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (takes a Ghostty value)")
            counts["A"] += 1
    # a c11-named function that returns Bonsplit leaf values (`tabIdsToLeft(...) -> [TabID]`)
    for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\([^{]*?\)\s*(?:async\s*)?(?:throws\s*)?->\s*(?:\[TabID\]|Set<TabID>|TabID|\[Bonsplit\.Tab\]|Bonsplit\.Tab)\??\s*[{\n]", src):
        if _is_c11_tab_name(m.group(1)) or re.search(r"^[a-z]\w*(?:Tab|Surface|Panel)Ids?(?:[A-Z]|$)", m.group(1)):
            if "onsplit" not in m.group(1):
                report.append(f"DOMAIN-LEAK-B {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (returns Bonsplit leaf values)")
                counts["B"] += 1
    # an external label with the c11 spelling in front of a Bonsplit-typed parameter (`f(forTabId bonsplitTabId: TabID)`)
    for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\(([^{]*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->|\{)", src):
        for pm in re.finditer(r"(?:^|,)\s*((?:for|of|with|from|to)(?:Tab|Surface|Panel)\w*)\s+\w+\s*:\s*(?:\[TabID\]|Set<TabID>|TabID|\[Bonsplit\.Tab\]|Bonsplit\.Tab)\??", m.group(2)):
            report.append(f"DOMAIN-LEAK-B {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)}({pm.group(1)}:) (c11 label for a Bonsplit id)")
            counts["B"] += 1
    # ... and the call sites that hand it a Bonsplit value under that label
    for m in re.finditer(r"\b((?:for|of|with|from|to)(?:Tab|Surface|Panel)\w*)\s*:\s*[\w.?!]*[bB]onsplit\w*(?:\.id)?\s*[,)]", src):
        if m.group(1) not in LEAF_LABEL_DECLS:  # only labels of our own functions that take a leaf-typed parameter
            continue
        report.append(f"DOMAIN-LEAK-B {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)}: (c11 label on a Bonsplit argument)")
        counts["B"] += 1
    # UUID-typed Bonsplit entry points must say so at the call site: `locateBonsplitTab(bonsplitTabId:)`
    for m in re.finditer(r"\bfunc\s+(\w*Bonsplit\w*)\s*\(([^{]*?)\)\s*(?:->|\{)", src):
        if re.search(r"(?:^|[(,\s])tabId\s*:\s*UUID", m.group(2)):
            report.append(f"DOMAIN-LEAK-B {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (c11 spelling for a Bonsplit id)")
            counts["B"] += 1
    if rel.endswith("GhosttyTerminalView.swift"):  # lifecycle names of the Ghostty handle never take the tab spelling
        for m in re.finditer(r"\b(?:func|var|let)\s+(" + DOMAIN_GHOSTTY_LIFECYCLE + r")\b", src):
            report.append(f"DOMAIN-LEAK-A {rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)} (Ghostty handle lifecycle)")
            counts["A"] += 1
    return counts


def check_domains_main(argv):
    """rename.py check-domains [--root DIR]: exit 1 if any binding sits in the wrong naming domain."""
    root = argv[argv.index("--root") + 1] if "--root" in argv else os.getcwd()
    report, total = [], {"A": 0, "B": 0, "C": 0, "D": 0, "E": 0}
    GHOSTTY_RETURNING.clear()
    LEAF_LABEL_DECLS.clear()
    base_gh = re.compile(DOMAIN_GHOSTTY)
    for full in swift_files(root):  # functions that return the Ghostty handle are sources too (`resolveSurface(from:)`)
        text = open(full, encoding="utf-8").read()
        for m in re.finditer(r"\bfunc\s+[A-Za-z_]\w*\s*(?:<[^>]*>)?\(([^{]*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->|\{)", text):
            for pm in re.finditer(r"(?:^|,)\s*((?:for|of|with|from|to)(?:Tab|Surface|Panel)\w*)\s+\w+\s*:\s*(?:\[TabID\]|Set<TabID>|TabID|\[Bonsplit\.Tab\]|Bonsplit\.Tab)\??", m.group(1)):
                LEAF_LABEL_DECLS.add(pm.group(1))
        for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\([^{]*?\)\s*(?:async\s*)?(?:throws\s*)?->\s*([^{\n]+)", text):
            if re.match(r"\s*(?:ghostty_surface_t|TerminalSurface)\??\s*$", m.group(2)) and not _is_loose_tab_name(m.group(1)):
                GHOSTTY_RETURNING.add(m.group(1))
    for full in sorted(swift_files(root)):
        rel = os.path.relpath(full, root)
        for k, v in check_domains(open(full, encoding="utf-8").read(), rel, report).items():
            total[k] += v
    for line in report:
        print(line)
    print(f"domain leaks: A(ghostty)={total['A']} B(bonsplit leaf)={total['B']} C(c11 from bonsplitTab*)={total['C']} "
          f"D(bonsplit pane)={total['D']} E(geometry)={total['E']}")
    return 1 if report else 0


def literal_old_names(tables_dir):
    """Old spellings the pass tables and evidence logs renamed: camel/Pascal-case identifiers of 6+ characters
    (a plain word such as `surface` or `pane` is too common in prose to judge by spelling). Passes are read in order,
    and a name a later pass brought back (2b's `BrowserPanel` -> `BrowserTab`, r8a's `BrowserTab` -> `BrowserPanel`)
    is current again, not old."""
    per_tag = {}
    for path in sorted(glob.glob(os.path.join(tables_dir, "pass-*.tsv"))):
        if path.endswith(".hand.tsv"):
            continue  # appended to its generated table
        tag = os.path.basename(path)[5:-4]
        renames, paths, deletes, keeps, callees, taints, fixes, receivers, region_renames = load_table(path)
        pairs = per_tag.setdefault(tag, [])
        for o, lst in renames.items():
            if lst and lst[0][0] != o:
                pairs.append((o, lst[0][0]))
        if os.path.exists(os.path.join(tables_dir, f"evidence-{tag}.tsv")):
            continue  # the log records what the taint rules actually renamed; their candidate lists are wider
        for g, rx, mp, rr, ex, opts in taints:
            for o, n in mp.items():
                if n != "@keep" and n != o:
                    pairs.append((o, n))
    for path in sorted(glob.glob(os.path.join(tables_dir, "evidence-*.tsv"))):
        tag = os.path.basename(path)[9:-4]
        pairs = per_tag.setdefault(tag, [])
        for line in open(path, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and cols[2] and cols[2] != cols[3].split()[-1]:
                pairs.append((cols[2], cols[3].split()[-1]))
    old = {}
    for tag in sorted(per_tag, key=lambda t: (t.startswith("r8"), t)):  # C11-248's passes, then C11-337's
        news = set()
        for o, n in per_tag[tag]:
            old.setdefault(o, f"pass {tag}")
            news.add(n)
        for n in news:
            if n in old and old[n] != f"pass {tag}":
                del old[n]  # renamed back by this pass: the current spelling again
    return {o: w for o, w in old.items() if re.fullmatch(r"[A-Za-z_]\w{5,}", o) and re.search(r"[a-z][A-Z]|^[A-Z][a-z]+[A-Z]", o)}


def check_literals_main(argv):
    """rename.py check-literals [--root DIR] [--allow FILE]

    Every string literal in Sources/, CLI/ and c11Tests/ that contains, as a whole identifier, a name a pass table
    renamed (including the merged passes) is a hit: a runtime-name use (reflection, NSClassFromString, selectors,
    accessibility ids, debug titles) must follow the rename, a wire or persisted key stays. Reviewed hits live in
    the allow file (TSV: file glob, old name, class, reason); anything else fails the run."""
    root = argv[argv.index("--root") + 1] if "--root" in argv else os.getcwd()
    allow_path = argv[argv.index("--allow") + 1] if "--allow" in argv else os.path.join(os.path.dirname(os.path.abspath(__file__)), "literals-reviewed.tsv")
    tables = argv[argv.index("--tables") + 1] if "--tables" in argv else os.path.dirname(os.path.abspath(__file__))
    old = literal_old_names(tables)
    allow = []
    if os.path.exists(allow_path):
        for line in open(allow_path, encoding="utf-8"):
            if line.strip() and not line.startswith("#"):
                cols = line.rstrip("\n").split("\t")
                if len(cols) >= 3:
                    allow.append((cols[0], cols[1], cols[2]))
    rx = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(sorted(map(re.escape, old), key=len, reverse=True)) + r")(?![A-Za-z0-9_])")
    hits, reviewed = [], collections.Counter()
    for full in sorted(swift_files(root)):
        rel = os.path.relpath(full, root)  # c11UITests too: they look elements up by the app's accessibility ids
        src = open(full, encoding="utf-8").read()
        lx = Lexer(src)
        lx.scan(0, False)
        for a, b in lx.strings:
            text = src[a:b]
            for m in rx.finditer(text):
                name = m.group(1)
                line = src.count("\n", 0, a + m.start()) + 1
                cls = next((c for g, n, c in allow if n == name and fnmatch.fnmatch(rel, g)), None)
                if cls:
                    reviewed[cls] += 1
                else:
                    hits.append((rel, line, name, old[name], text.strip()[:100]))
    for rel, line, name, tag, text in hits:
        print(f"LITERAL {rel}:{line} {name} ({tag}) in \"{text}\"")
    print(f"literal hits: {len(hits)} unreviewed; reviewed: " + (", ".join(f"{k}={v}" for k, v in sorted(reviewed.items())) or "none"))
    return 1 if hits else 0


def _tokens(line):
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line)


STRUCTURAL = re.compile(r"^\s*(?:// C11-248: persisted keys keep[^\n]*|enum CodingKeys: String, CodingKey \{|case \w+( = \"[^\"]+\")?(, \w+)*|\}|)\s*$")


def _align(a, b, old_path, new_path, logged):
    """Pair the identifier tokens that differ between two token lists; (pairs, unalignable chunks)."""
    import difflib
    pairs, bad = [], []
    if len(a) == len(b):  # a line-for-line rename changes tokens in place
        return [(x, y) for x, y in zip(a, b) if x != y], bad
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if tag == "insert" and i1 > 0:
            pairs.append((a[i1 - 1], a[i1 - 1] + " " + " ".join(b[j1:j2])))
        elif tag == "delete" and i1 > 0 and j1 > 0 and b[j1 - 1] == a[i1 - 1]:
            pairs.append((a[i1 - 1] + " " + " ".join(a[i1:i2]), a[i1 - 1]))  # a parameter name dropped for its label
        elif tag == "replace" and (i2 - i1) == (j2 - j1):
            pairs.extend(zip(a[i1:i2], b[j1:j2]))
        else:
            bad.append((tag, a[i1:i2], b[j1:j2]))
    return pairs, bad


def _merge_params(tokens, logged, old_path, new_path):
    """`label name` where the log records `label` -> `label name`: one renamed token (a parameter that keeps its label)."""
    out, i = [], 0
    while i < len(tokens):
        if i + 1 < len(tokens) and any((f, tokens[i], tokens[i] + " " + tokens[i + 1]) in logged for f in (old_path, new_path)):
            out.append(tokens[i] + " " + tokens[i + 1])
            i += 2
        else:
            out.append(tokens[i])
            i += 1
    return out


_MERGED = {}


def _merged_olds(logged):
    """(file, `label name`) for every logged rename whose old side is two tokens (a dropped parameter name)."""
    key = id(logged)
    if key not in _MERGED:
        _MERGED.clear()
        _MERGED[key] = {(f, o) for f, o, n in logged if " " in o}
    return _MERGED[key]


def _merge_dropped(tokens, logged, old_path, new_path):
    """`label name` where the log records `label name` -> `label`: a parameter name dropped for its label (one token)."""
    out, i = [], 0
    while i < len(tokens):
        pair = tokens[i] + " " + tokens[i + 1] if i + 1 < len(tokens) else None
        if pair and any((f, pair) in _merged_olds(logged) for f in (old_path, new_path)):
            out.append(tokens[i] + " " + tokens[i + 1])
            i += 2
        else:
            out.append(tokens[i])
            i += 1
    return out


def check_evidence_main(argv):
    """rename.py check-evidence <evidence.tsv> <base-ref> <head-ref>

    Prove every rename: each identifier token that changed between the refs must appear in the pass's evidence
    log (written by `apply --evidence-log`) under the same old and new spelling, with an evidence class other
    than UNPROVEN. Added and deleted lines that are not CodingKeys pins are listed for review.
    """
    log, base, head = argv[2], argv[3], argv[4]
    if os.path.basename(log).startswith("evidence-r8"):
        use_test_vocab("r8")
    logged, classes, entries = {}, {}, []
    for line in open(log, encoding="utf-8"):
        f, ln, old, new, cls, site = (line.rstrip("\n").split("\t") + [""])[:6]
        logged.setdefault((f, old, new), set()).add(cls)
        classes[cls] = classes.get(cls, 0) + 1
        entries.append((f, ln, old, new, cls, site))
    cmd = ["git", "diff", "--find-renames=10%", "-U0", base] + ([] if head == "WORKTREE" else [head]) + ["--", "Sources", "CLI", "c11Tests"]
    diff = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    import difflib
    unproven, structural, proven, unalignable = [], [], 0, []
    old_path = new_path = None
    minus, plus = [], []

    def flush():
        nonlocal proven
        if not minus and not plus:
            return
        if len(minus) != len(plus):
            for ln in minus + plus:
                if not STRUCTURAL.match(ln):
                    structural.append((new_path, ln.strip()[:90]))
            return
        for m, p in zip(minus, plus):
            if m == p:
                continue
            pin = re.match(r'(\s*case\s+)(\w+)(\s*=\s*)"(\w+)"', p)
            if pin and (logged.get((old_path, pin.group(4), pin.group(2))) or logged.get((new_path, pin.group(4), pin.group(2)))) \
                    and not re.search(r'=\s*"', m):
                p = p[:pin.end(2)] + p[pin.end():]  # the pinned raw value is the old spelling, kept on purpose

            def unlogged(pairs):
                return sum(1 for o, n in pairs if not (logged.get((old_path, o, n)) or logged.get((new_path, o, n))))
            best = None
            for a in (_tokens(m), _merge_dropped(_tokens(m), logged, old_path, new_path)):
                for b in (_tokens(p), _merge_params(_tokens(p), logged, old_path, new_path)):
                    pairs, bad = _align(a, b, old_path, new_path, logged)
                    score = (len(bad), unlogged(pairs), -len(pairs))
                    if best is None or score < best[0]:
                        best = (score, pairs, bad)
            _, pairs, bad = best
            for o, n in pairs:
                cls = logged.get((old_path, o, n)) or logged.get((new_path, o, n))
                if cls and cls != {"UNPROVEN"}:
                    proven += 1
                else:
                    unproven.append((new_path, o, n))
            if bad:
                unalignable.append((new_path, m.strip()[:90]))

    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            flush()
            minus, plus = [], []
            m = re.match(r"diff --git a/(\S+) b/(\S+)", line)
            old_path, new_path = m.group(1), m.group(2)
        elif line.startswith("@@"):
            flush()
            minus, plus = [], []
        elif line.startswith("-") and not line.startswith("---"):
            minus.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            plus.append(line[1:])
    flush()
    # the classes themselves are re-derived from the tree, not trusted from the log
    classless = verify_classes(entries, head, os.path.dirname(os.path.abspath(log)))
    for f, ln, o, n, why in classless[:80]:
        print(f"UNPROVEN-CLASS {f}:{ln} {o} -> {n}: {why}")
    for f, o, n in unproven[:80]:
        print(f"UNPROVEN {f} {o} -> {n}")
    for f, t in unalignable[:40]:
        print(f"UNALIGNED {f}: {t}")
    # lines the pass table deletes on purpose (`@fix` rows), compared after the pass's own renames
    fix_lines = set()
    if len(argv) > 5:
        for line in open(argv[5], encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if cols[0] in ("@fix", "@fixall") and len(cols) >= 4:
                for part in (cols[2], cols[3]):
                    fix_lines.update(x.strip() for x in part.replace("\\n", "\n").split("\n") if x.strip())
            elif cols[0] == "@delete" and len(cols) >= 3:
                fix_lines.add(cols[2].strip())
    rmap = {o: n for (f_, o, n) in logged}
    def renamed(t):
        return re.sub(r"[A-Za-z_]\w*", lambda m: rmap.get(m.group(0), m.group(0)), t).strip()
    structural = [(f, t) for f, t in structural if renamed(t) not in fix_lines and t.strip() not in fix_lines]
    for f, t in structural[:40]:
        print(f"STRUCTURAL {f}: {t}")
    print("evidence classes in the log: " + ", ".join(f"{k}={v}" for k, v in sorted(classes.items())))
    print(f"renamed tokens proven: {proven}; unproven: {len(unproven)}; unaligned hunks: {len(unalignable)}; "
          f"unexplained added/deleted lines: {len(structural)}; unproven classes: {len(classless)}")
    return 1 if unproven or unalignable or classless or structural else 0


# ---- test names (P6): a test class, function or file is renamed when the thing it names was renamed
TEST_WORDS = [("TabManager", "WorkspaceManager"), ("Surfaces", "Tabs"), ("Surface", "Tab"), ("Panels", "Tabs"), ("Panel", "Tab"),
              ("Panes", "Areas"), ("Pane", "Area")]
TEST_OLD_RX = {"TabManager": r"tabmanager", "Surface": r"surface", "Panel": r"panel", "Pane": r"pane(?!l)"}
# a body that touches the Ghostty surface, an AppKit panel or a Bonsplit pane is about that domain, not about the c11 concept
TEST_DOMAIN_RX = {"Surface": r"\bTerminalSurface\b|\bGhosttySurface\w*|ghostty_surface_\w+|\bIOSurface\w*|\.surface\.surface\b|\.runtimeSurface\b",
                  "Panel": r"\bNS(?:Open|Save)?Panel\b|\bNSPanel\b|\bWKOpenPanelParameters\b",
                  "Pane": r"\bPaneID\b|\bbonsplitController\b|\binPane\b|\bfocusedPaneId\b|\ballPaneIds\b|\bBonsplit\.",
                  "TabManager": r"(?!x)x"}


# C11-337 R8 (pass r8c): Tab -> Panel. `use_test_vocab("r8")` switches the three tables above; renamed subjects are then
# read from the r8 passes only (`TEST_TABLES`), and only from names that are types or members, not short locals.
TEST_VOCABS = {
    "c11-248": (list(TEST_WORDS), dict(TEST_OLD_RX), dict(TEST_DOMAIN_RX), None),
    "r8": ([("Tabs", "Panels"), ("Tab", "Panel")],
           {"Tab": r"(?-i:(?<![a-z])[tT]abs?(?![a-z])|[a-z]Tabs?(?![a-z]))"},
           # the Tab key and workspace-meaning sidebar names: a body about them is not about the c11 panel
           {"Tab": r"\bkVK_Tab\b|\binsertTab\b|\binsertBacktab\b|\bNSTabView\w*|\bsidebar_activeTab\w*|\bactiveTab(?:Fill|Rail)\w*"},
           ("r8a", "r8b")),
}
TEST_TABLES = None  # pass tags whose renames count as test evidence (None: every pass)


def use_test_vocab(name):
    global TEST_TABLES
    words, old_rx, dom_rx, tables = TEST_VOCABS[name]
    TEST_WORDS[:] = words
    TEST_OLD_RX.clear()
    TEST_OLD_RX.update(old_rx)
    TEST_DOMAIN_RX.clear()
    TEST_DOMAIN_RX.update(dom_rx)
    TEST_TABLES = tables


def test_word_of(word):
    return {"Surfaces": "Surface", "Panels": "Panel", "Panes": "Pane", "Tabs": "Tab"}.get(word, word)


def test_new_name(name):
    """Apply the vocabulary map to the old-word segments of a test name: (new name, [old words]) or (None, [])."""
    words = []
    out = name
    for old, new in TEST_WORDS:
        # a segment is delimited by case changes, digits and underscores; `Pane` must not eat `Panel`
        rx = re.compile(r"(?<![A-Za-z])" + old + r"(?![a-z])") if old[0].isupper() else None
        pat = re.compile(old + r"(?![a-z])")
        if pat.search(out):
            words.append(test_word_of(old))
            out = pat.sub(new, out)
    out = out.replace("TabTab", "Tab").replace("PanelPanel", "Panel")
    return (out, words) if out != name else (None, [])


def renamed_new_names(tables_dir):
    """{new name: old name} for every identifier the pass tables and evidence logs renamed (old-word spellings only)."""
    pairs = {}
    def wanted(path, prefix):
        tag = os.path.basename(path)[len(prefix):-4]
        return TEST_TABLES is None or tag in TEST_TABLES
    def subject(old):  # r8: a type or member name, not a short local (`tabA`, `tabId`)
        return TEST_TABLES is None or (len(old) >= 8 and bool(re.search(r"^[A-Z]|[a-z][A-Z]\w*[A-Z]", old)))
    for path in sorted(glob.glob(os.path.join(tables_dir, "pass-*.tsv"))):
        if not wanted(path, "pass-") or path.endswith(".hand.tsv"):
            continue
        renames = load_table(path)[0]
        for o, lst in renames.items():
            for n, *_ in lst:
                if n != o and subject(o):
                    pairs.setdefault(n, o)
    for path in sorted(glob.glob(os.path.join(tables_dir, "evidence-*.tsv"))):
        if not wanted(path, "evidence-"):
            continue
        for line in open(path, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and cols[2] and cols[3] and cols[2] != cols[3].split()[-1] and " " not in cols[2]:
                if TEST_TABLES is not None and cols[4] == "L":
                    continue
                if subject(cols[2]):
                    pairs.setdefault(cols[3].split()[-1], cols[2])
    return pairs


def _name_segments(name):
    return re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+", name[4:] if name.startswith("test") else name)


def test_name_evidence(name, word, pairs):
    """The test name starts with (two or more segments of) the old name of a renamed identifier, and that shared
    prefix carries the old word: it plainly names the renamed subject (`BrowserPaneDropRoutingTests`)."""
    segs = _name_segments(name)
    rx = re.compile(TEST_OLD_RX[word], re.I)
    for old in set(pairs.values()):
        osegs = _name_segments(old)
        n = 0
        while n < len(segs) and n < len(osegs) and segs[n] == osegs[n]:
            n += 1
        if n >= 2 and rx.search("".join(segs[:n])):
            return old
    return None


def test_evidenced(name, tokens, word, pairs):
    """('body', token) / ('name', old identifier) / None: why `word` in this test name may follow the rename."""
    if test_name_evidence(name, word, pairs):
        return ("name", test_name_evidence(name, word, pairs))
    ev = test_evidence(tokens, word, pairs)
    if ev and not any(re.search(TEST_DOMAIN_RX[word], t) for t in tokens):
        return ("body", ev[0])
    return None


def test_evidence(src_tokens, word, pairs):
    """Identifiers in a test body that a pass renamed away from `word`: the subject the test names was renamed."""
    rx = re.compile(TEST_OLD_RX[word], re.I)
    return sorted(t for t in src_tokens if t in pairs and rx.search(pairs[t]) and not rx.search(t))


LEAF_TYPE_RX = r"(?:\[TabID\]|Set<TabID>|TabID|\[Bonsplit\.Tab\]|Bonsplit\.Tab)"
LEAF_EVIDENCE = (r"\bTabID\b|Bonsplit\.Tab\b|[bB]onsplit|\bExternalTab|\bTabInfo\b|\bselectedTab\(|\btabs\(inPane|"
                 r"\bcreateTab\(|\.createTab\b|\bcontroller\.|\bcontroller\b")


def verify_classes(entries, head, logdir="."):
    """Re-derive each logged class from the tree: T needs a type declaration of the new name, M a declaration of the
    new name on a tab-domain type (or Workspace/WorkspaceManager) outside the Ghostty wrapper, L a binding statement
    that names a tab-domain type, API or member."""
    root = os.getcwd()
    if head != "WORKTREE":
        import tempfile
        root = tempfile.mkdtemp()
        tar = subprocess.run(["git", "archive", head, "Sources", "CLI", "c11Tests"], capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", root], input=tar, check=True)
    types, decls = {}, {}
    for full in swift_files(root):
        rel = os.path.relpath(full, root)
        if rel.startswith("c11UITests"):
            continue
        src = open(full, encoding="utf-8").read()
        lx = Lexer(src)
        lx.scan(0, False)
        bodies = type_bodies(src, lx)
        for (kind, name, header, op, cl), inside in zip(bodies, own_depth_idents(src, lx, bodies)):
            if cl is None or not name:
                continue
            if kind != "extension":
                types[name] = kind
            props, cases = declared_names(src, inside)
            for a, b in props + cases:
                decls.setdefault(src[a:b], []).append((name, _decl_statement(src, a, b)))
            for k, (a, b) in enumerate(inside):
                if src[a:b] == "func" and k + 1 < len(inside) and src[b:inside[k + 1][0]].strip() == "":
                    decls.setdefault(src[inside[k + 1][0]:inside[k + 1][1]], []).append((name, src[a:a + 600].split("{")[0]))
    prev_t = set()
    for lp in sorted(glob.glob(os.path.join(logdir, "evidence-*.tsv"))):  # every pass's tab-domain types, new and old spelling
        for line in open(lp, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4 and cols[4] == "T":
                prev_t.update((cols[2], cols[3]))
    new_types = {n for f, ln, o, n, c, s in entries if c == "T"} | prev_t
    old_domain = {o for f, ln, o, n, c, s in entries if c in ("T", "M")}
    tab_owners = new_types | {o for f, ln, o, n, c, s in entries if c == "T"} | {"Workspace", "WorkspaceManager", "Panel", "TerminalPanel", "BrowserPanel", "MarkdownPanel",
                              "TabContent", "TerminalTab", "BrowserTab", "MarkdownTab"}
    ghost = re.compile(r"\bghostty_surface_\w+|\bGhosttySurface\w*|\bTerminalSurface(?:Registry)?\b|\bIOSurface\w*")
    bad, direct_names, pending, curated = [], {}, [], {}
    test_pairs = renamed_new_names(logdir) if any(e[4] == "Test" for e in entries) else {}
    leaf_names, leaf_pending = {}, []
    for f, ln, o, n, cls, site in entries:
        n1 = n.split()[-1]
        if cls == "T":
            if n1 not in types:
                bad.append((f, ln, o, n, "no type declaration of the new name"))
        elif cls == "M":
            m = re.match(r"owner=(\w+); (.*)", site)
            if not m or m.group(1) not in tab_owners or ghost.search(m.group(2)):
                bad.append((f, ln, o, n, "member declared outside the tab domain or with a Ghostty signature: " + site[:70]))
        elif cls == "Leaf":
            if site.startswith("owner="):  # a declaration: its signature must carry a Bonsplit leaf type
                if not re.search(r"\bTabID\b|Bonsplit\.Tab\b", site):
                    bad.append((f, ln, o, n, "declaration with no Bonsplit leaf type: " + site[:70]))
            elif re.search(LEAF_EVIDENCE, site) or re.search(r"\b(?:let|var)\s+\w+\s*:\s*" + LEAF_TYPE_RX, site):
                leaf_names.setdefault(f, set()).add(o.split()[0])
            else:
                leaf_pending.append((f, ln, o, n, site))
        elif cls == "Leafuse":
            if not any(re.search(r"\bTabID\b|Bonsplit\.Tab\b", sig) for owner, sig in decls.get(n1, [])):
                bad.append((f, ln, o, n, "use of a name with no leaf-typed declaration"))
        elif cls == "Test":
            # the new test name is declared in the file, and the file's body names a subject a pass renamed away from the old word
            full = os.path.join(root, f)
            text = open(full, encoding="utf-8").read() if os.path.exists(full) else ""
            if not re.search(r"\b(?:class|func)\s+" + re.escape(n1) + r"\b", text) and "@path" not in site:
                bad.append((f, ln, o, n, "the renamed test is not declared in the file"))
            else:
                _, words = test_new_name(o)
                toks = set(re.findall(r"[A-Za-z_]\w*", text))
                if words and not any(test_evidenced(o, toks, w, test_pairs) for w in words):
                    bad.append((f, ln, o, n, "no renamed subject found in the test file for " + "/".join(words)))
        elif cls in ("F", "X"):
            curated[cls] = curated.get(cls, 0) + 1
        elif cls == "Muse":
            if not any(owner in tab_owners and not ghost.search(sig) for owner, sig in decls.get(n1, [])):
                bad.append((f, ln, o, n, "use of a member with no tab-domain declaration"))
        elif cls == "L":
            toks = set(re.findall(r"[A-Za-z_]\w*", site))
            direct = not ghost.search(site) and bool(toks & (old_domain | tab_owners) or re.search(r"new(?:Terminal|Browser|Markdown)|tabIdFromBonsplitTabId|\.(?:panels|surfaces)\[|\b(?:terminal|browser|markdown)?[pP]anel\(for\b|\b(?:Terminal|Browser|Markdown)Panel\b", site))
            if direct:
                direct_names.setdefault(f, set()).add(o.split()[0])
            else:
                pending.append((f, ln, o, n, site, toks))
    progress = True
    while progress and leaf_pending:  # a Bonsplit value flowing through other bindings of the same file: each step is evidenced
        progress = False
        for item in list(leaf_pending):
            f, ln, o, n, site = item
            if set(re.findall(r"[A-Za-z_]\w*", site)) & leaf_names.get(f, set()):
                leaf_names[f].add(o.split()[0])
                leaf_pending.remove(item)
                progress = True
    for f, ln, o, n, site in leaf_pending:
        bad.append((f, ln, o, n, "binding statement shows no Bonsplit evidence: " + site[:70]))
    for f, ln, o, n, site, toks in pending:  # at most one hop from a directly evidenced binding of the same file
        if ghost.search(site) or not (toks & direct_names.get(f, set())):
            bad.append((f, ln, o, n, "binding statement shows no tab-domain evidence: " + site[:70]))
    return bad




def _code_tokens(text):
    lx = Lexer(text)
    lx.scan(0, False)
    return [text[a:b] for a, b in lx.idents]


def _declared_names(text):
    """Every name the file declares: types, members, locals and cases, and the parameter labels and names of its
    declared functions (strings and comments masked)."""
    lx = Lexer(text)
    lx.scan(0, False)
    masked = list(text)
    for a, b in lx.strings:
        masked[a:b] = " " * (b - a)
    code = "".join(masked)
    out = set(re.findall(r"\b(?:func|var|let|case|class|struct|enum|protocol|typealias|actor)\s+([A-Za-z_]\w*)", code))
    for m in re.finditer(r"\b(?:func\s+[A-Za-z_]\w*|init[?!]?)\s*(?:<[^>{}]*>)?\(", code):
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"(": 1, ")": -1}.get(code[i], 0)
            i += 1
        for pm in re.finditer(r"(?:^|[(,])\s*([A-Za-z_]\w*)(?:\s+([A-Za-z_]\w*))?\s*:", code[m.end() - 1:i]):
            out.update(x for x in pm.groups() if x)
    return out


def check_rows_main(argv):
    """rename.py check-rows <table.tsv> <base-ref> [<evidence.tsv>]

    The renames landed under their new names (not only that the old word is gone):
      NOT-LANDED  a file a row is scoped to held the old name before the pass and holds no new name after it
      UNDECLARED  a row's new name is used after the pass but declared nowhere, while the old name was declared before
                  (a use followed the rename and its declaration did not: the declaration's file was out of scope)
      MISSING     an evidence-log entry whose new name is not in its file after the pass
    """
    import tempfile
    table, base = argv[2], argv[3]
    log = argv[4] if len(argv) > 4 else None
    renames, paths, *_ = load_table(table)
    root = os.getcwd()
    btmp = tempfile.mkdtemp(prefix="vr-base-")
    tar = subprocess.run(["git", "archive", base, *SCAN_DIRS], capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", btmp], input=tar, check=True)

    def moved(rel):
        for old, new in paths:
            if rel == old or rel.startswith(old + "/"):
                rel = new + rel[len(old):]
        return rel

    btext = {os.path.relpath(f, btmp): open(f, encoding="utf-8").read() for f in swift_files(btmp)}
    htext = {os.path.relpath(f, root): open(f, encoding="utf-8").read() for f in swift_files(root)}
    btok = {rel: set(_code_tokens(t)) for rel, t in btext.items()}
    htok = {rel: set(_code_tokens(t)) for rel, t in htext.items()}
    bdecl = set().union(*(_declared_names(t) for t in btext.values()))
    hdecl = set().union(*(_declared_names(t) for t in htext.values()))
    hall = set().union(*htok.values()) if htok else set()
    bad = []
    for old, lst in renames.items():
        for new, globs, fallback, flags in lst:
            scoped = [rel for rel in btext if glob_match(rel, globs) and old in btok[rel]]
            for rel in scoped:
                head = htok.get(moved(rel), set())
                if new not in head and (not fallback or fallback not in head) and old in head:
                    bad.append(f"NOT-LANDED {moved(rel)} {old} -> {new}")
            if new in hall and old in bdecl and new not in hdecl:
                bad.append(f"UNDECLARED {new} (was {old}): used after the pass, declared nowhere")
    if log and os.path.exists(log):
        seen = set()
        for line in open(log, encoding="utf-8"):
            f, ln, old, new, cls, site = (line.rstrip("\n").split("\t") + [""] * 6)[:6]
            n1 = new.split()[-1].removeprefix("self.") if new else ""
            if (f, n1) in seen or not n1 or n1 == old or site == "@path":  # a moved file's stem is not a token
                continue
            seen.add((f, n1))
            if f in htok and n1 not in htok[f] and not (cls == "F" and n1 in htext[f]):  # a curated @fix may edit a string
                bad.append(f"MISSING {f} {n1} (logged from {old})")
    for line in bad[:120]:
        print(line)
    print(f"rows landed: {len(bad)} problems ({sum(len(l) for l in renames.values())} rows checked)")
    return 1 if bad else 0


def check_main(argv):
    """rename.py check-leaf <table.tsv> [--root DIR]: exit 1 if any leaf binding carries a workspace name."""
    table = argv[2]
    root = argv[argv.index("--root") + 1] if "--root" in argv else os.getcwd()
    renames, paths, deletes, keeps, callees, taints, fixes, receivers, region_renames = load_table(table)
    report = []
    for full in sorted(swift_files(root)):
        rel = os.path.relpath(full, root)
        check_leaf(open(full, encoding="utf-8").read(), rel, taints, renames, report)
    for line in report:
        print(line)
    print(f"leaf misnames: {len(report)}")
    return 1 if report else 0


def main(argv):
    if len(argv) >= 5 and argv[1] == "check-evidence":
        return check_evidence_main(argv)
    if len(argv) >= 4 and argv[1] == "check-rows":
        return check_rows_main(argv)
    if len(argv) >= 2 and argv[1] == "check-literals":
        return check_literals_main(argv)
    if len(argv) >= 2 and argv[1] == "check-domains":
        return check_domains_main(argv)
    if len(argv) >= 3 and argv[1] == "check-leaf":
        return check_main(argv)
    if len(argv) < 3 or argv[1] != "apply":
        print(__doc__)
        return 2
    table = argv[2]
    root = os.getcwd()
    dry = "--dry-run" in argv
    use_git = "--no-git" not in argv
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    renames, paths, deletes, keeps, callees, taints, fixes, receivers, region_renames = load_table(table)
    validate(renames)
    # a row scoped to a file that is not in the tree on entry renames nothing there: the declaration it was meant for
    # keeps its old name while its uses elsewhere follow (C11-337 R8: rows written against post-pass paths)
    named = [(g, o) for o, lst in renames.items() for _n, gl, _f, _fl in lst for g in gl]
    named += [(g, "@regionrename") for gl, _rr, _mp in region_renames for g in gl.split(",")]
    named += [(rel, "@fix") for rel, *_ in fixes]
    stale_globs = sorted({(g.lstrip("!"), o) for g, o in named
                          if g.lstrip("!") and not any(c in g for c in "*?[") and not os.path.exists(os.path.join(root, g.lstrip("!")))})
    for g, o in stale_globs:
        print(f"GLOB STALE {g} ({o}): no such file on entry")
    if stale_globs and not dry:
        print(f"{len(stale_globs)} rows name files that do not exist: fix the table", file=sys.stderr)
        return 3
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
    KEPT_PROPERTY_NAMES.update(collect_kept_props(root, renames))
    LEAF_PROP_NAMES.update(collect_leaf_props(root, taints))
    KEEP_FUNC_NAMES.update(collect_keep_funcs(root, taints))
    for fname, labels in collect_keep_labels(root, taints).items():
        callees.setdefault(fname, "keep:" + ",".join(sorted(labels)))
    total_files = total_hits = 0
    report = []
    for full in sorted(swift_files(root)):
        rel = os.path.relpath(full, root)
        src = open(full, encoding="utf-8").read()
        src, npin = codable_pin_pass(src, rel, renames)
        if npin:
            print(f"  [codingkeys] {rel}: {npin} type(s) pinned")
        src, nt = taint_pass(src, rel, taints, report)
        src, nr = region_rename_pass(src, rel, region_renames)
        new, n = rewrite(src, rel, renames, report, keeps, callees, receivers)
        new = strip_keep(new)
        n += nt
        if n:
            total_files += 1
            total_hits += n
            print(f"{n:6d}  {rel}")
            if not dry:
                open(full, "w", encoding="utf-8").write(new)
    stale = 0
    for rel, old, new, every in fixes:
        full = os.path.join(root, rel)
        text = open(full, encoding="utf-8").read() if os.path.exists(full) else ""
        if new in text and old not in text:
            continue  # already applied
        if text.count(old) != 1 and not (every and text.count(old) > 1):
            print(f"FIXUP STALE {rel}: {old[:70]!r} found {text.count(old)}x")
            stale += 1
            continue
        print(f"  [fix] {rel}: {old[:60]!r}")
        if not dry:
            open(full, "w", encoding="utf-8").write(text.replace(old, new))
        # a curated one-off edit: each identifier it changes is logged (class F) with the row as its site
        import difflib
        ta, tb = re.findall(r"[A-Za-z_]\w*", old), re.findall(r"[A-Za-z_]\w*", new)
        if len(ta) == len(tb):
            for o_, n_ in zip(ta, tb):
                if o_ != n_:
                    EVIDENCE.append((rel, 0, o_, n_, "F", "curated @fix row"))
        else:
            for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=ta, b=tb, autojunk=False).get_opcodes():
                if tag == "replace" and (i2 - i1) == (j2 - j1):
                    for o_, n_ in zip(ta[i1:i2], tb[j1:j2]):
                        EVIDENCE.append((rel, 0, o_, n_, "F", "curated @fix row"))
    for line in report:
        print(line)
    print(f"identifiers renamed: {total_hits} in {total_files} files; collisions left: {len(report)}")
    if stale:
        print(f"{stale} stale @fix entries: the code drifted; update the table", file=sys.stderr)
        return 3
    moved = {}
    if paths:
        # Paths after contents: edits above are by path as it was on entry.
        n = apply_paths(root, paths, dry, use_git)
        print(f"paths renamed: {n}")
        moved = {o: nw for o, nw in paths if not dry and os.path.exists(os.path.join(root, nw)) and o.endswith(".swift")}
    for (o, nw), cls in PATH_EVIDENCE.items():  # a moved file is evidence too: stem old -> stem new
        so, sn = os.path.splitext(os.path.basename(o))[0], os.path.splitext(os.path.basename(nw))[0]
        if so != sn:
            EVIDENCE.append((o, 0, so, sn, cls, "@path"))
    # entries are logged under the file's final path
    EVIDENCE[:] = [(moved.get(r, r), ln, a, b, c, sd) for r, ln, a, b, c, sd in EVIDENCE]
    if "--evidence-log" in argv and not dry:
        with open(argv[argv.index("--evidence-log") + 1], "w", encoding="utf-8") as fh:
            for rel_, ln_, old_, new_, cls_, site_ in sorted(set(EVIDENCE)):
                fh.write(f"{rel_}\t{ln_}\t{old_}\t{new_}\t{cls_}\t{site_.replace(chr(9), ' ').replace(chr(10), ' ')}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
