#!/usr/bin/env python3
"""Generate pass-p6.tsv: test class, function and file names that use the old vocabulary for a c11 concept.

  gen-p6.py [--root DIR] [--out FILE]

A test name changes only when the thing it names was renamed: the test body (class, or function) mentions an
identifier a pass renamed away from the same old word (Surface/Panel -> Tab, Pane -> Area, TabManager ->
WorkspaceManager), and it does not touch the Ghostty surface, an AppKit panel or a Bonsplit pane. The evidence
is re-derived by `check-evidence` (class `Test`). c11UITests drive the app by strings and have no subject
identifiers to point at, so they keep their names.
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rename

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
KEEP_CLASS = re.compile(r"Ghostty|Bonsplit")


def matching_brace(src, lx, open_pos):
    depth = 0
    for pos, c in lx.events:
        if pos < open_pos or c not in "{}":
            continue
        depth += 1 if c == "{" else -1
        if depth == 0:
            return pos
    return len(src)


def scan_file(path):
    src = open(path, encoding="utf-8").read()
    lx = rename.Lexer(src)
    lx.scan(0, False)
    idents = [(a, b, src[a:b]) for a, b in lx.idents]
    classes = []
    for m in re.finditer(r"\bclass\s+(\w+)\s*:\s*([\w, .]*)\{", src):
        if "XCTestCase" not in m.group(2):
            continue
        end = matching_brace(src, lx, m.end() - 1)
        funcs = []
        for fm in re.finditer(r"\bfunc\s+(test\w*)\s*\(", src[m.end():end]):
            fpos = m.end() + fm.start()
            ob = src.find("{", m.end() + fm.end())
            fend = matching_brace(src, lx, ob)
            funcs.append((fm.group(1), {t for a, b, t in idents if ob <= a < fend}))
        classes.append((m.group(1), {t for a, b, t in idents if m.end() <= a < end}, funcs))
    return src, {t for _, _, t in idents}, classes


def mapped(name, words):
    """Apply the vocabulary map to `name` for the given old words only."""
    out = name
    for old, new in rename.TEST_WORDS:
        if rename.test_word_of(old) in words:
            out = re.sub(old + r"(?![a-z])", new, out)
    return out.replace("TabTab", "Tab")


NEW_WORD = {"Surface": "Tab", "Panel": "Tab", "Pane": "Area", "TabManager": "WorkspaceManager"}


def names_both_words(name, word):
    """`testRenameAcceptsEitherSurfaceOrTabId`: the old word and its replacement both appear, apart from each other, so the
    test is about the legacy alias and the old word is the point. (`SurfaceTab...` is one compound: the new word follows.)"""
    new = NEW_WORD[word]
    if new == "WorkspaceManager":
        return False
    stripped = re.sub(word + r"(?:s)?" + new, "", name)
    return bool(re.search(new + r"(?![a-z])", stripped)) and bool(re.search(word, stripped))


def evidenced_words(name, tokens, pairs):
    _, words = rename.test_new_name(name)
    return [w for w in words if not names_both_words(name, w) and rename.test_evidenced(name, tokens, w, pairs)]


def main(argv):
    root = ROOT
    if "--root" in argv:
        root = os.path.abspath(argv[argv.index("--root") + 1])
    out_path = argv[argv.index("--out") + 1] if "--out" in argv else os.path.join(HERE, "pass-p6.tsv")
    tables = argv[argv.index("--tables") + 1] if "--tables" in argv else HERE
    pairs = rename.renamed_new_names(tables)
    tdir = os.path.join(root, "c11Tests")
    files = sorted(f for f in os.listdir(tdir) if f.endswith(".swift"))
    parsed = {f: scan_file(os.path.join(tdir, f)) for f in files}
    all_classes = {c for f in files for c, _, _ in parsed[f][2]}
    class_rows, func_rows, path_rows, skipped = {}, [], [], []
    for f in files:
        src, ftokens, classes = parsed[f]
        file_words = set()
        func_decisions = {}  # name -> set of new names (or None) across the file's classes
        for cname, ctokens, funcs in classes:
            words = [] if KEEP_CLASS.search(cname) else evidenced_words(cname, ctokens, pairs)
            if words:
                new = mapped(cname, words)
                if new != cname and new not in all_classes and class_rows.get(cname, new) == new:
                    class_rows[cname] = new
                    file_words.update(words)
                else:
                    skipped.append((f, cname, "collision"))
            elif rename.test_new_name(cname)[0]:
                skipped.append((f, cname, "no evidence or a Ghostty/Bonsplit/AppKit subject"))
            for fname, ftok in funcs:
                fw = evidenced_words(fname, ftok, pairs)
                nn = mapped(fname, fw) if fw else None
                if nn == fname:
                    nn = None
                func_decisions.setdefault(fname, set()).add(nn)
        for fname, decisions in sorted(func_decisions.items()):
            if None in decisions or len(decisions) != 1:
                if rename.test_new_name(fname)[0] and decisions != {None}:
                    skipped.append((f, fname, "same name decided differently in the file"))
                continue
            func_rows.append((f, fname, next(iter(decisions))))
        stem = os.path.splitext(f)[0]
        words = [w for w in rename.test_new_name(stem)[1] if w in file_words]
        if words:
            nstem = mapped(stem, words)
            if nstem != stem and not os.path.exists(os.path.join(tdir, nstem + ".swift")):
                path_rows.append((f"c11Tests/{f}", f"c11Tests/{nstem}.swift"))
    # function names must stay unique inside their class after the rename
    for f, o, n in list(func_rows):
        for cname, _, funcs in parsed[f][2]:
            names = {x for x, _ in funcs}
            if o in names and n in names:
                func_rows.remove((f, o, n))
                skipped.append((f, o, "collision"))
                break
    out = ["# Pass p6: test class, function and file names that follow the renamed subject. Generated by gen-p6.py.",
           "# Columns: old<TAB>new<TAB>globs<TAB>fallback<TAB>flags (ev:Test); @path rows carry ev:Test too"]
    for o, n in sorted(class_rows.items()):
        out.append("\t".join([o, n, "c11Tests/*", "", "ev:Test"]))
    for f, o, n in func_rows:
        out.append("\t".join([o, n, f"c11Tests/{f}", "", "ev:Test,nomember"]))
    for o, n in path_rows:
        out.append("\t".join(["@path", o, n, "ev:Test"]))
    with open(out_path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"classes={len(class_rows)} functions={len(func_rows)} files={len(path_rows)} kept-with-old-words={len(skipped)} -> {out_path}")
    return class_rows, func_rows, path_rows, skipped


if __name__ == "__main__":
    main(sys.argv)
