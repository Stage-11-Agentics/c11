#!/usr/bin/env python3
"""Turn xcodebuild 'incorrect argument label' errors into @callee suggestions.

  suggest.py BUILD_LOG
Prints `@callee<TAB>Name<TAB>keep|rename` lines to paste into the pass table:
  keep   = declaration was left alone, call sites must keep the old label
  rename = declaration was renamed, call sites must follow
Other error classes are printed as-is for hand fixes.
"""
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rename

pat = re.compile(r"^(/[^:]+):(\d+):(\d+): error: incorrect argument label in call \(have '([^']*)', expected '([^']*)'\)")
seen, others = {}, []
for line in open(sys.argv[1], errors="replace"):
    m = pat.match(line)
    if not m:
        if ": error:" in line:
            others.append(line.strip()[:240])
        continue
    path, ln, col, have, exp = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5)
    src = open(path, encoding="utf-8").read().split("\n")
    off = sum(len(l) + 1 for l in src[:ln - 1]) + col - 1
    text = "\n".join(src)
    # find the first label (in the call's parens) at/after the error column
    i = off
    while i < len(text) and text[i] != "(":
        i += 1
    callee = rename.callee_name(text, i + 1) if i < len(text) else None
    hs, es = have.rstrip(":").split(":"), exp.rstrip(":").split(":")
    diff = [(h, e) for h, e in zip(hs, es) if h != e]
    if not callee or not diff:
        others.append(f"{path}:{ln}:{col} callee={callee} have={have} expected={exp}")
        continue
    seen.setdefault((callee, "keep" if True else ""), set()).add(diff[0])
for (callee, _), diffs in sorted(seen.items()):
    print(f"@callee\t{callee}\tkeep\t# labels differ: {sorted(diffs)}")
for o in sorted(set(others)):
    print("# other:", o)
