#!/usr/bin/env python3
"""c11 2.0 identity codemod (C11H-265).

Rewrites a git checkout of c11h's main so it carries c11's identity
(docs/c11-2.0-identity.md is the map). Deterministic and idempotent: run it
on its own output and nothing changes. It edits the working tree only; review
the diff and commit it yourself.

    python3 scripts/c11-2.0-rename.py [--root <checkout>] [--check] [--report <file>]

--check   change nothing; exit 1 if a run would change anything.
--sync-branch <ref>
          bring the current branch (cut before the rename) onto <ref>, a main that
          already carries it: merge the commit before the rename, run the exact
          codemod that made it on this branch, commit, merge the generated rename
          commit (where a hunk differs, this branch's side is the codemod's output on
          its own work, so it wins), then merge <ref>. Stops at the first conflict,
          which is then only where this branch and the hand edits on <ref> touch the
          same lines. One command:

              git fetch origin && python3 scripts/c11-2.0-rename.py --sync-branch origin/main

          (from a branch that predates the rename, take the script from main:
           python3 <(git show origin/main:scripts/c11-2.0-rename.py) --sync-branch origin/main)
--report  write the run's findings (renames, per-rule counts, lines that
          contrasted c11 with c11h and need a human look, anything left) as JSON.

Lines carrying `c11-2.0:legacy` or `c11-2.0:keep`, and every line between
`c11-2.0:begin-keep` and `c11-2.0:end-keep`, are never rewritten; that is how
the hand-edit commit keeps c11h's old names (C11Identity.Legacy, aliases).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

# --------------------------------------------------------------------------
# Scope

# Never rewritten or renamed: history, other workstreams' files, this run's own docs.
EXCLUDE_PREFIXES = (
    "notes/",
    "plans/",
    "design/",
    "docs/archive/",
    "docs/c11-2.0-",
    "skills/c11h/",          # WS7 folds the sidecar into the c11 skill
    "Sources/Migration/",    # C11H-266: first-launch migration reads the old names on purpose
    "tools/c11h-proofs/",    # WS6 (C11H-268) moves these to the private ops repo
    "tools/c11h-validator/",
    "c11Tests/Fixtures/hosttransport/",  # bytes the bus measured; a rename changes their sizes
    "scripts/c11-2.0-",
    "tests/c11_2_0_",
    ".lattice",
    "ghostty/",
    "vendor/",
)
EXCLUDE_FILES = {
    "CHANGELOG.md",          # history
    "AGENTS.md",             # WS7
    "C11.md",                # WS7
    "README.md",             # Atin's voice
    "NOTICE",                # WS7: its lineage names the c11h line by that name
}

# Path renames that are not the plain token rule.
PATH_OVERRIDES = {
    "skills/c11/references/c11h.md": "skills/c11/references/persistence.md",
}
# Paths that keep their name (the hidden `c11h` CLI alias).
PATH_KEEP = {
    "Resources/bin/c11h",
}
# Old entry points that stay as forwarding shims after their script is renamed:
# installed apps, zips already sent and other machines still call these names.
SHIMS = {
    "scripts/c11h-atlas-link.sh": "scripts/c11-atlas-link.sh",
    "scripts/c11h-atlas-relay.sh": "scripts/c11-atlas-relay.sh",
    "scripts/c11h-install.sh": "scripts/c11-install.sh",
    "scripts/c11h-install-remote-hc.py": "scripts/c11-install-remote-hc.py",
}
SHIM_MARKER = "c11-2.0:shim"

# --------------------------------------------------------------------------
# Protected text: masked before the rules run, restored after.

KEEP_LINE = re.compile(r"c11-2\.0:(?:legacy|keep|shim)")
# A region between these markers is kept whole (the hand-written Legacy enum).
KEEP_BEGIN = re.compile(r"c11-2\.0:begin-keep")
KEEP_END = re.compile(r"c11-2\.0:end-keep")

# Localizable.xcstrings values can't carry a marker, so these keys are kept whole, by key:
# the migration gate's messages tell a c11h user to quit c11h before 2.0 moves their
# state over, and must keep naming it (C11H-285).
KEEP_XCSTRINGS_KEY = re.compile(r"migration\.gate\.")
XCSTRINGS_KEY_LINE = re.compile(r'^    "([^"]+)": \{')

KEEP_PATTERNS = [
    re.compile(r"\bC11H-\d+"),                     # ticket ids
    re.compile(r"//\s*c11h:"),                     # divergence markers
    re.compile(r"c11h\.relay\.[A-Za-z0-9_.]*"),    # relay slot and method names (wire)
    re.compile(r"\"c11h\.relay\.?\""),
    re.compile(r"c11h-relay-2 [a-z]+"),            # relay credential and MAC labels: term, request, reply, refusal (wire)
    re.compile(r"c11h\.show\.(?=[\"<])"),           # hc document prefix of Show records (stored on terminals)
    re.compile(r"c11h-show-record"),               # Show record signature label (stored)
    re.compile(r"ext\.c11h"),                      # cbus envelope extension (wire)
    re.compile(r"(?:[eE]xt\??|\)\??)\[\s*\"c11h\"\s*\]"),  # ...as an envelope key: ext["c11h"], keptExt["c11h"], (…)?["c11h"]
    re.compile(r"forKey: \"c11h\""),
    re.compile(r"\"c11h\"\s*:\s*[\[{]"),               # ...and as a JSON key in fixtures
    re.compile(r"\\\"c11h\\\"\s*:"),                    # ...and escaped inside a JSON string
    re.compile(r"\"c11h\.recovered\""),            # stored session metadata key
    re.compile(r"c11h\.recovered"),
    re.compile(r"c11h-sandbox-golden[A-Za-z0-9_-]*"),  # build-host guest image names
    re.compile(r"/opt/c11h\b"),                    # guest image tool root
    re.compile(r"bin/c11h(?![-A-Za-z0-9_.])"),     # the hidden CLI alias file beside bin/c11 (app and relay kit)
    re.compile(r"c11h-run\b"),                     # the run's operations folder (~/c11h-run)
    re.compile(r"c11h-(?:proofs|validator)\b"),     # trees archived in the private ops repo (WS6)
    re.compile(r"c11h-pf\b"),                      # private operator folders the shareable gate blocks
    re.compile(r"c11h-builds\b"),
    re.compile(r"c11h-\(\?:run\|pf\)"),            # ...and the gate's own pattern for them
    re.compile(r"github\.com[:/]Stage-11-Agentics/c11h\b"),
    re.compile(r"Stage-11-Agentics/c11h\b"),       # the repo's own name, until WS6 moves it
]

# Per-file literals that are wire or stored keys.
FILE_KEEP_PATTERNS = {
    "Sources/Transport/Bus/CbusWire.swift": [re.compile(r"\"c11h\"")],
    "Sources/Transport/Bus/BusHostTransport.swift": [re.compile(r"\"c11h\"")],
    "Sources/Mailbox/MailboxEnvelope.swift": [re.compile(r"relayKey = \"c11h\"")],
    "Sources/HC/HCContract.swift": [re.compile(r"static let app = \"c11h\.app\"")],
    # The pbxproj keeps the `c11h` alias file reference (PATH_KEEP).
    "GhosttyTabs.xcodeproj/project.pbxproj": [
        re.compile(r"Resources/bin/c11h\""),
        re.compile(r"/\* c11h \*/"),
        re.compile(r"/\* c11h in Copy CLI \*/"),
    ],
}

# --------------------------------------------------------------------------
# Structured edits: specific files, run before the token rules.

SPARKLE_KEYS = """\t<key>SUAutomaticallyUpdate</key>
\t<false/>
\t<key>SUEnableAutomaticChecks</key>
\t<true/>
\t<key>SUFeedURL</key>
\t<string>https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml</string>
\t<key>SUScheduledCheckInterval</key>
\t<integer>86400</integer>
\t<key>SUSendProfileInfo</key>
\t<false/>
"""


def edit_info_plist(text: str) -> str:
    # The -hN version line retires: CFBundleVersion is the plain build number.
    text = re.sub(r"\$\(CURRENT_PROJECT_VERSION\)\.\d+", "$(CURRENT_PROJECT_VERSION)", text)
    text = re.sub(
        r"[ \t]*<!-- C11H-50:.*?-->\n[ \t]*<key>C11HVersion</key>\n[ \t]*<string>[^<]*</string>\n",
        "", text, flags=re.S)
    text = re.sub(r"[ \t]*<key>C11HVersion</key>\n[ \t]*<string>[^<]*</string>\n", "", text)
    # c11's Sparkle settings and feed, as c11 1.x ships them: replace whatever is there.
    text = re.sub(r"\t<key>(?:SUAutomaticallyUpdate|SUEnableAutomaticChecks|SUFeedURL|"
                  r"SUScheduledCheckInterval|SUSendProfileInfo)</key>\n\t<[^\n]*\n", "", text)
    if "\t<key>SUPublicEDKey</key>" in text:
        text = text.replace("\t<key>SUPublicEDKey</key>", SPARKLE_KEYS + "\t<key>SUPublicEDKey</key>", 1)
    return text


def edit_pbxproj(text: str) -> str:
    text = re.sub(r"MARKETING_VERSION = [0-9.]+;", "MARKETING_VERSION = 2.0.0;", text)
    text = re.sub(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = 200;", text)
    return text


STRUCTURED = {
    "Resources/Info.plist": edit_info_plist,
    "GhosttyTabs.xcodeproj/project.pbxproj": edit_pbxproj,
}

# --------------------------------------------------------------------------
# Token rules, in order. Case-sensitive on purpose: `C11Host` is not `C11H`.

ENV_OVERRIDES = {
    "C11H_SOCKET": "C11_PROOF_SOCKET",
    "C11H_TAG": "C11_GUEST_TAG",
    "C11H_C11_APP": "C11_REF_APP",
    "C11H_C11_CLI": "C11_REF_CLI",
    "C11H_C11_RELEASE_KEYCHAIN": "C11_REF_RELEASE_KEYCHAIN",
    "C11H_C11_RELEASE_KEYCHAIN_PASS": "C11_REF_RELEASE_KEYCHAIN_PASS",
    "C11H_EXPECTED_C11_VERSION": "C11_EXPECTED_VERSION",
    "C11H_EXPECTED_C11_BUILD": "C11_EXPECTED_BUILD",
    "C11H_DOMAIN": "C11_LEGACY_DOMAIN",
}

RULES: list[tuple[str, re.Pattern, object]] = [
    # The c11 guide page that described c11h is `persistence` now.
    ("guide-page", re.compile(r"(?<=guide )c11h(?![a-z0-9-])"), "persistence"),
    ("env-override",
     re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(sorted(ENV_OVERRIDES, key=len, reverse=True)) + r")(?![A-Z0-9_])"),
     lambda m: ENV_OVERRIDES[m.group(1)]),
    ("env", re.compile(r"(?:(?<![A-Za-z0-9])|(?<=\\[bnt]))C11H_"), "C11_"),
    ("bundle-id", re.compile(r"com\.stage11\.c11h(?![a-z0-9])"), "com.stage11.c11"),
    ("type", re.compile(r"C11H(?=[A-Z][a-z])"), "C11"),
    ("camel", re.compile(r"(?:(?<![A-Za-z0-9])|(?<=\\[bnt]))c11h(?=[A-Z])"), "c11"),
    ("word", re.compile(r"(?:(?<![A-Za-z0-9])|(?<=\\[bnt]))c11h(?![a-z0-9])"), "c11"),
    ("upper-word", re.compile(r"(?:(?<![A-Za-z0-9])|(?<=\\[bnt]))C11H(?![A-Za-z0-9_-])"), "C11"),
    ("upper-scheme", re.compile(r"C11H(?=-SHOW\b)"), "C11"),
    ("upper-suffix", re.compile(r"(?<=[a-z])C11H(?![A-Za-z0-9_-])"), "C11"),
]

# Exact one-line patches on the renamed text, for spots where the token rules
# alone would make two names one (a Set literal with a duplicate traps at run
# time). Each is applied once; a rerun finds its result and skips it.
PATCHES = {
    "Sources/PanelLinkFormat.swift": [(
        'static let acceptedSchemes: Set<String> = ["c11", "c11"]',
        'static let acceptedSchemes: Set<String> = ["c11", "c11h"] // c11-2.0:keep (c11h:// is a hidden alias)',
    )],
    "Sources/Mailbox/MailboxBodyLinks.swift": [(
        'private static let barePrefixes = ["c11://", "c11://", "http://", "https://"]',
        'private static let barePrefixes = ["c11://", "c11h://", "http://", "https://"] // c11-2.0:keep (hidden alias)',
    )],
}

# A bracketed literal with the same string twice, made by the rename.
DUP_LITERAL = re.compile(r"\[([^\[\]]*)\]")


def duplicate_literals(line: str) -> bool:
    for m in DUP_LITERAL.finditer(line):
        items = re.findall(r'"([^"\\]*)"', m.group(1))
        if len(items) > 1 and len(items) != len(set(items)):
            return True
    return False


# What a rewritten file must no longer contain (outside protected text).
LEFTOVER = re.compile(r"c11h|C11H(?![-0-9]|ost)")
# A line naming both lines of the product before the rewrite: after it, the
# two may have become one and the logic may now contradict itself.
CONTRAST = re.compile(r"(?<![A-Za-z0-9])c11(?![a-z0-9h])|com\.stage11\.c11(?![a-z0-9])|/c11\.app|c11 DEV")


def mask(text: str, patterns: list[re.Pattern], keep_keys: bool = False) -> tuple[str, list[str]]:
    saved: list[str] = []

    def stash(m: re.Match) -> str:
        saved.append(m.group(0))
        return f"\x00{len(saved) - 1}\x00"

    out_lines = []
    in_block = False
    in_key = False
    for line in text.split("\n"):
        if keep_keys:
            m = XCSTRINGS_KEY_LINE.match(line)
            if m:
                in_key = bool(KEEP_XCSTRINGS_KEY.match(m.group(1)))
            elif line.startswith("    }"):
                kept_close = in_key
                in_key = False
                if kept_close:
                    saved.append(line)
                    out_lines.append(f"\x00{len(saved) - 1}\x00")
                    continue
            if in_key:
                saved.append(line)
                out_lines.append(f"\x00{len(saved) - 1}\x00")
                continue
        if KEEP_BEGIN.search(line):
            in_block = True
        if in_block or KEEP_LINE.search(line):
            if KEEP_END.search(line):
                in_block = False
            saved.append(line)
            out_lines.append(f"\x00{len(saved) - 1}\x00")
            continue
        for pat in patterns:
            line = pat.sub(stash, line)
        out_lines.append(line)
    return "\n".join(out_lines), saved


def unmask(text: str, saved: list[str]) -> str:
    return re.sub(r"\x00(\d+)\x00", lambda m: saved[int(m.group(1))], text)


def rewrite_tokens(text: str, counts: dict[str, int]) -> str:
    for name, pat, repl in RULES:
        text, n = pat.subn(repl, text)
        if n:
            counts[name] = counts.get(name, 0) + n
    return text


def rename_path(path: str) -> str:
    if path in PATH_KEEP:
        return path
    if path in PATH_OVERRIDES:
        return PATH_OVERRIDES[path]
    return rewrite_tokens(path, {})


def excluded(path: str) -> bool:
    return path in EXCLUDE_FILES or path.startswith(EXCLUDE_PREFIXES)


def is_text(data: bytes) -> bool:
    if b"\x00" in data:
        return False
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def shim_text(old: str, new: str) -> str:
    target = os.path.basename(new)
    if old.endswith(".py"):
        return (f"#!/usr/bin/env python3\n# {SHIM_MARKER}: the old name; runs {target}.\n"
                "import os, sys\n"
                f"here = os.path.dirname(os.path.abspath(__file__))\n"
                f"os.execv(sys.executable, [sys.executable, os.path.join(here, {target!r})] + sys.argv[1:])\n")
    old = "C11H_"
    return (f"#!/bin/sh\n# {SHIM_MARKER}: the old name, kept for installed apps and other machines; runs {target}.\n"
            f"# Its old variable names still work: {old}<x> fills C11_<x> when that is unset. {SHIM_MARKER}\n"
            f"for _v in $(env | sed -n 's/^{old}\\([A-Za-z0-9_]*\\)=.*/\\1/p'); do # {SHIM_MARKER}\n"
            f'  eval "[ -n \\"\\${{C11_$_v+x}}\\" ] || {{ C11_$_v=\\"\\${{{old}$_v}}\\"; export C11_$_v; }}" # {SHIM_MARKER}\n'
            f"done\n"
            f'exec "$(cd "$(dirname "$0")" && pwd)/{target}" "$@"\n')


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True).stdout


def json_duplicate_keys(text: str) -> list[str]:
    dupes: list[str] = []

    def hook(pairs):
        seen = set()
        for k, _ in pairs:
            if k in seen:
                dupes.append(k)
            seen.add(k)
        return dict(pairs)

    json.loads(text, object_pairs_hook=hook)
    return dupes


GENERATED_SUBJECT = "generated by scripts/c11-2.0-rename.py"


def submodule_paths(root: str) -> list[str]:
    p = subprocess.run(["git", "-C", root, "config", "-f", ".gitmodules", "--get-regexp", r"\.path$"],
                       capture_output=True, text=True)
    return [line.split(None, 1)[1] for line in p.stdout.splitlines() if " " in line]


def sync_branch(root: str, ref: str) -> int:
    """Bring a pre-rename branch onto a main that carries the rename."""
    def run(*cmd: str, check: bool = True) -> subprocess.CompletedProcess:
        p = subprocess.run(["git", "-C", root, *cmd], capture_output=True, text=True)
        if check and p.returncode != 0:
            sys.stderr.write(p.stdout + p.stderr)
            sys.exit(f"c11-2.0-rename: git {' '.join(cmd)} failed; resolve, commit, and rerun the same command")
        return p
    if run("status", "--porcelain").stdout.strip():
        return print("c11-2.0-rename: commit or stash your changes first", file=sys.stderr) or 2
    gen = run("log", "--format=%H", "--fixed-strings", f"--grep={GENERATED_SUBJECT}", "-n", "1", ref).stdout.strip()
    if not gen:
        return print(f"c11-2.0-rename: {ref} carries no rename commit", file=sys.stderr) or 2
    base = run("rev-parse", gen + "^").stdout.strip()
    branch = run("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if run("merge-base", "--is-ancestor", gen, "HEAD", check=False).returncode != 0:
        if run("merge-base", "--is-ancestor", base, "HEAD", check=False).returncode != 0:
            print(f"c11-2.0-rename: merging {base[:9]}, the commit before the rename")
            run("merge", "--no-edit", base)
        script = run("show", f"{gen}:scripts/c11-2.0-rename.py").stdout
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as fh:
            fh.write(script)
        p = subprocess.run([sys.executable, fh.name, "--root", root], text=True)
        os.unlink(fh.name)
        if p.returncode != 0:
            return p.returncode
        # Stage what the codemod changed, never a submodule: a checkout behind its
        # gitlink would otherwise be committed as a revert of the pointer.
        run("add", "-A", "--", ".", *[f":!{p}" for p in submodule_paths(root)])
        if run("diff", "--cached", "--quiet", check=False).returncode != 0:
            run("commit", "-q", "-m", f"c11 2.0 rename applied to {branch} ({GENERATED_SUBJECT} at {gen[:9]})")
        # The generated commit is this codemod's output on the base; this branch now
        # holds the same codemod's output on base plus its own work. Where a hunk
        # differs, this branch's side is the right one by construction.
        print(f"c11-2.0-rename: merging the generated rename {gen[:9]}")
        run("merge", "--no-edit", "-X", "ours", gen)
    print(f"c11-2.0-rename: merging {ref}")
    run("merge", "--no-edit", ref)
    print(f"c11-2.0-rename: {branch} is on {ref}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report")
    ap.add_argument("--sync-branch", metavar="REF")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if args.sync_branch:
        return sync_branch(root, args.sync_branch)

    files = [f for f in git(root, "ls-files", "-z").split("\0") if f]
    tracked = set(files)
    report = {"renamed": [], "shims": [], "rules": {}, "contrast": [], "leftover": [],
              "duplicates": [], "patches": 0, "errors": []}
    changes = 0

    # 1. File renames (the token rule on the path, so references and files agree).
    plan: list[tuple[str, str]] = []
    for path in files:
        if excluded(path) or not os.path.lexists(os.path.join(root, path)):
            continue
        new = rename_path(path)
        if new == path:
            continue
        if path in SHIMS and SHIM_MARKER in open(os.path.join(root, path), errors="replace").read():
            continue  # already a shim from an earlier run
        if new in tracked or os.path.lexists(os.path.join(root, new)):
            report["errors"].append(f"rename target exists: {path} -> {new}")
            continue
        plan.append((path, new))
    if report["errors"]:
        return finish(report, args, 2)
    for old, new in plan:
        changes += 1
        report["renamed"].append([old, new])
        if args.check:
            continue
        os.makedirs(os.path.dirname(os.path.join(root, new)) or root, exist_ok=True)
        git(root, "mv", old, new)
        if old in SHIMS:
            with open(os.path.join(root, old), "w") as fh:
                fh.write(shim_text(old, new))
            os.chmod(os.path.join(root, old), 0o755)
            git(root, "add", old)
            report["shims"].append(old)
    renamed = dict(plan)

    # 2. Content.
    for path in files:
        if excluded(path):
            continue
        cur = renamed.get(path, path)
        full = os.path.join(root, cur if not args.check else path)
        if not os.path.isfile(full) or os.path.islink(full):
            continue
        data = open(full, "rb").read()
        if not is_text(data):
            continue
        text = data.decode("utf-8")
        orig = text
        if path in STRUCTURED:
            text = STRUCTURED[path](text)
        masked, saved = mask(text, KEEP_PATTERNS + FILE_KEEP_PATTERNS.get(path, []),
                             keep_keys=path.endswith(".xcstrings"))
        before_lines = masked.split("\n")
        counts: dict[str, int] = {}
        masked = rewrite_tokens(masked, counts)
        for rule, n in counts.items():
            report["rules"][rule] = report["rules"].get(rule, 0) + n
        after_lines = masked.split("\n")
        for i, (b, a) in enumerate(zip(before_lines, after_lines)):
            if b != a and CONTRAST.search(b):
                report["contrast"].append(f"{cur}:{i + 1}: {unmask(a, saved).strip()[:200]}")
            if LEFTOVER.search(a):
                report["leftover"].append(f"{cur}:{i + 1}: {unmask(a, saved).strip()[:200]}")
        text = unmask(masked, saved)
        for old_line, new_line in PATCHES.get(cur, []):
            if old_line in text:
                text = text.replace(old_line, new_line)
                report["patches"] += 1
            elif new_line not in text:
                report["errors"].append(f"{cur}: patch did not apply: {old_line}")
        for i, (b, a) in enumerate(zip(orig.split("\n"), text.split("\n"))):
            if b != a and duplicate_literals(a) and not duplicate_literals(b):
                report["duplicates"].append(f"{cur}:{i + 1}: {a.strip()[:200]}")
        if cur.endswith(".xcstrings") or cur.endswith(".json"):
            try:
                dupes = json_duplicate_keys(text)
                if dupes:
                    report["errors"].append(f"{cur}: duplicate keys after rename: {dupes[:10]}")
            except json.JSONDecodeError as exc:
                report["errors"].append(f"{cur}: invalid JSON after rename: {exc}")
        if text != orig:
            changes += 1
            if not args.check:
                with open(full, "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)

    report["changed_files"] = changes
    code = 2 if report["errors"] else (1 if args.check and changes else 0)
    return finish(report, args, code)


def finish(report: dict, args, code: int) -> int:
    if args.report:
        with open(args.report, "w") as fh:
            json.dump(report, fh, indent=1)
    print(f"c11-2.0-rename: {report.get('changed_files', 0)} files changed, "
          f"{len(report['renamed'])} renamed, {len(report['shims'])} shims, "
          f"rules {report['rules']}, {len(report['contrast'])} contrast lines, "
          f"{len(report['leftover'])} leftover, {report['patches']} patches, "
          f"{len(report['duplicates'])} duplicate literals, {len(report['errors'])} errors"
          + (" (check only)" if args.check else ""))
    for err in report["errors"]:
        print("error: " + err, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
