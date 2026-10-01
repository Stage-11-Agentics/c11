#!/usr/bin/env python3
"""Token-aware Swift identifier renamer (C11-248).

Applies a TSV symbol table of whole-identifier renames to Swift sources.

  rename.py apply <table.tsv> [--root DIR] [--dry-run] [--no-git]

Table format (one entry per line, `#` comments and blank lines ignored):

  old<TAB>new[<TAB>glob[,glob...][<TAB>fallback]]
                                        identifier rename; optional repo-relative
                                        globs restrict where it applies (prefix a
                                        glob with `!` to exclude). If `new` already
                                        occurs in the same member (a shadowing
                                        hazard), `fallback` is used there instead;
                                        with no usable fallback the token is left
                                        alone and reported as COLLISION.
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
  * A token qualified by `Bonsplit.` (the vendor module) is never renamed.
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
            renames.setdefault(cols[0], []).append((cols[1], globs, fallback))
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
    news = {n for lst in renames.values() for n, _, _ in lst}
    clash = news & set(renames)
    if clash:
        sys.exit("table chains renames (new name is also an old name): " + ", ".join(sorted(clash)))
    for old, lst in renames.items():
        for n, _, _ in lst:
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


def rewrite(src, rel, renames, report=None, keep_rules=None):
    lx = Lexer(src)
    lx.scan(0, False)
    reg, spans = regions(src, lx)
    keeps = [(set(n.split(',')), re.compile(rx)) for g, rx, n in (keep_rules or []) if fnmatch.fnmatch(rel, g)]
    kept_cache = {}
    by_region = {}
    for (a, b), r in zip(lx.idents, reg):
        by_region.setdefault(r, set()).add(src[a:b])
    out, last, count = [], 0, 0
    for (a, b), r in zip(lx.idents, reg):
        tok = src[a:b]
        lst = renames.get(tok)
        if not lst:
            continue
        new, fallback = None, None
        for cand, globs, fb in lst:
            if glob_match(rel, globs):
                new, fallback = cand, fb
                break
        if new is None:
            continue
        if src[max(0, a - 9):a] == "Bonsplit.":
            continue
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
        if new in present:
            if fallback and fallback not in present:
                new = fallback
            else:
                if report is not None:
                    line = src.count("\n", 0, a) + 1
                    report.append(f"COLLISION {rel}:{line} {tok} -> {new} (already in scope; left as is)")
                continue
        out.append(src[last:a])
        out.append(new)
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
