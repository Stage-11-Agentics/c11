#!/usr/bin/env python3
"""Bring names outside Swift along with a pass.

  sync-test-lists.py <pass table>

Every pass: the file column of literals-reviewed.tsv follows the table's @path rows (a moved file keeps its reviews).
A test-name pass (p6, r8c) also rewrites, from its class, function and @path rows (`ev:Test`):
  .github/workflows/*.yml and scripts/*.sh   `c11Tests/<Class>[/<test>]` and `c11LogicTests/<Class>[/<test>]` ids
  scripts/c11-27-split-tests.rb              the test file names it assigns to c11LogicTests
"""
import glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def main(argv):
    table = argv[1]
    classes, funcs, files = {}, {}, {}
    for line in open(table, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if not cols[0] or cols[0].startswith("#"):
            continue
        flags = cols[-1].split(",") if len(cols) > 3 else []
        if "ev:Test" not in flags:
            continue  # test names only; other moves are read below for literals-reviewed.tsv
        if cols[0] == "@path":
            files[os.path.basename(cols[1])] = os.path.basename(cols[2])
        elif len(cols) > 2 and cols[0].startswith("test"):
            funcs.setdefault(cols[0], {})[cols[2]] = cols[1]  # function renames are per file
        elif len(cols) > 1:
            classes[cols[0]] = cols[1]
    # a function row is scoped to its file; the file's classes say which `Class/test` ids it may rewrite
    class_of_file = {}
    for path in glob.glob(os.path.join(ROOT, "c11Tests", "*.swift")):
        rel = os.path.relpath(path, ROOT)
        src = open(path, encoding="utf-8").read()
        for m in re.finditer(r"\bclass\s+(\w+)\s*:", src):
            class_of_file.setdefault(m.group(1), set()).add(rel)
    changed = 0
    reviewed = os.path.join(HERE, "literals-reviewed.tsv")
    moves = []
    for line in open(table, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if cols[0] == "@path" and len(cols) >= 3:
            moves.append((cols[1], cols[2]))
    if moves and os.path.exists(reviewed):
        out = []
        for line in open(reviewed, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if not line.startswith("#") and len(cols) > 1:
                for old, new in moves:  # files first, then the directories that hold them (table order)
                    if cols[0] == old or cols[0].startswith(old + "/"):
                        cols[0] = new + cols[0][len(old):]
                line = "\t".join(cols) + "\n"
            out.append(line)
        text = "".join(out)
        if text != open(reviewed, encoding="utf-8").read():
            open(reviewed, "w", encoding="utf-8").write(text)
            print("  [reviewed] literals-reviewed.tsv follows the moved files")
    if not classes and not funcs and not files:
        return 0
    targets = glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")) + glob.glob(os.path.join(ROOT, "scripts", "*.sh"))

    def test_id(m):
        target, cls, test = m.group(1), m.group(2), m.group(3)
        new_cls = classes.get(cls, cls)
        if test:
            name = test[1:]
            for f, new in funcs.get(name, {}).items():
                fname = os.path.basename(f)
                if any(os.path.basename(x) in (fname, files.get(fname, fname)) for x in class_of_file.get(new_cls, ()) | class_of_file.get(cls, set())):
                    name = new
            return f"{target}/{new_cls}/{name}"
        return f"{target}/{new_cls}"

    for path in targets:
        text = open(path, encoding="utf-8").read()
        new = re.sub(r"\b(c11Tests|c11LogicTests)/(\w+)(/\w+)?", test_id, text)
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
            print(f"  [tests] {os.path.relpath(path, ROOT)}")
            changed += 1
    rb = os.path.join(ROOT, "scripts", "c11-27-split-tests.rb")
    if os.path.exists(rb):
        text = open(rb, encoding="utf-8").read()
        new = re.sub(r"(?<![\w/])(\w+\.swift)\b", lambda m: files.get(m.group(1), m.group(1)), text)
        if new != text:
            open(rb, "w", encoding="utf-8").write(new)
            print("  [tests] scripts/c11-27-split-tests.rb")
            changed += 1
    print(f"test lists updated: {changed} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
