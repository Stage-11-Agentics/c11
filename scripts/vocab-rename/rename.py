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
                                        leading-dot implicit members (`.tabs`).
  @path<TAB>old<TAB>new                 file or directory rename (git mv, then
                                        project.pbxproj path edits)
  @keep<TAB>glob<TAB>regex<TAB>name,name  in files matching glob, members whose source
                                        text matches regex keep those old names
                                        (vendor/leaf use that shares a generic name)
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
    with open(path, encoding="utf-8") as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if cols[0] == "@keep":
                if len(cols) != 4:
                    sys.exit(f"{path}:{ln}: @keep needs glob, regex, names")
                keeps.append((cols[1], cols[2], cols[3]))
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
    return renames, paths, deletes, keeps


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


VENDOR_RECEIVERS = ("Bonsplit.", "bonsplitController.", "bonsplitController?.", "controller.")
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


TYPE_START = re.compile(r"\s*(?:inout\s+|@escaping\s+|any\s+|some\s+)*(?:\[\s*)*([A-Za-z_][\w.]*)(<[^>]*>)?([?!]?)\s*([,)\]:=\n{]|->|$)")


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


def rewrite(src, rel, renames, report=None, keep_rules=None):
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    keeps = [(set(n.split(',')), re.compile(rx)) for g, rx, n in (keep_rules or []) if fnmatch.fnmatch(rel, g)]
    kept_cache = {}
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
        has_ck = any(src[a:b] == "CodingKeys" for a, b in inside)
        if raw_string:
            for a, b in cases:
                tail = src[b:b + 40].lstrip(" ")
                if not tail.startswith("="):
                    pin_enum[a] = src[a:b]
        elif is_codable and not has_ck:
            for a, b in props + (cases if kind == "enum" else []):
                hazard_pos[a] = f"{kind} {name}"
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        if is_call_label(src, a, b):
            continue
        by_region.setdefault(r, set()).add(src[a:b])
    out, last, count = [], 0, 0
    for (a, b), r in zip(lx.idents, reg):
        tok = src[a:b]
        lst = renames.get(tok)
        if not lst:
            continue
        new, fallback, flags = None, None, set()
        for cand, globs, fb, fl in lst:
            if glob_match(rel, globs):
                new, fallback, flags = cand, fb, fl
                break
        if new is None:
            continue
        pre = src[max(0, a - 20):a]
        if pre.endswith(VENDOR_RECEIVERS):
            continue
        if "noimplicit" in flags and a in case_decl:
            continue  # enum case declaration: keep, its `.case` uses are kept too
        if "noimplicit" in flags and a >= 1 and src[a - 1] == "." and (a < 2 or not (src[a - 2].isalnum() or src[a - 2] in "_)]}?!>\\")):
            continue  # leading-dot implicit member (an enum case), not a property
        if keeps:
            skip = False
            for names, rx in keeps:
                if tok in names:
                    key = (id(rx), r)
                    if key not in kept_cache:
                        a0, b0 = spans[r]
                        kept_cache[key] = bool(rx.search(src[a0:b0]))
                    if kept_cache[key]:
                        skip = True
                        break
            if skip:
                continue
        present = by_region[r]
        if new in present and not is_call_label(src, a, b):
            if fallback and fallback not in present:
                new = fallback
            else:
                if report is not None:
                    line = src.count("\n", 0, a) + 1
                    report.append(f"COLLISION {rel}:{line} {tok} -> {new} (already in scope; left as is)")
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
    renames, paths, deletes, keeps = load_table(table)
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
        new, n = rewrite(src, rel, renames, report, keeps)
        if n:
            total_files += 1
            total_hits += n
            print(f"{n:6d}  {rel}")
            if not dry:
                open(full, "w", encoding="utf-8").write(new)
    for line in report:
        print(line)
    print(f"identifiers renamed: {total_hits} in {total_files} files; collisions left: {len(report)}")
    if paths:
        # Paths after contents: edits above are by path as it was on entry.
        n = apply_paths(root, paths, dry, use_git)
        print(f"paths renamed: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
