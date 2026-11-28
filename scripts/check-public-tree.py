#!/usr/bin/env python3
"""C11H-268, C11H-284: fail when c11's tree holds something public c11 must not carry.

c11's main is the public Stage-11-Agentics/c11 repo's main (C11.md).

    scripts/check-public-tree.py [--root <repo>] [--allow-pending] [--no-gitleaks]
    scripts/check-public-tree.py --inherit [--baseline <ref>]

Strict (the default, and the gate before the public push; C11H-284): every kind below blocks,
whatever 1.x published. A deliberate match passes only by a whole-line entry in
scripts/public-tree-allowlist.txt. It needs no baseline ref, so it runs in any checkout.

- Tailnet hosts and addresses, and secrets (token shapes, and gitleaks when installed).
- Email addresses (sample and private-network domains aside) and Stage 11 hosts.
- The operator's home path and contact, the operator's machines and places (the build host
  included, which 1.x allowed), a private machine used as an ssh or --on host, and the build host's
  folders: check-shareable.py's rules, which keep the names as hashes so neither script names
  them. Third-party vendored files are exempt from the machine words, emails and gitleaks'
  generic-api-key rule (minified code trips it); every dedicated gitleaks rule, token-shaped secrets
  and tailnet addresses still block there.
- Operations material (OPS_PATHS) blocks as a path. A pending path (PENDING_PATHS) is material
  that moves to the private ops repo before the public push: it blocks too, unless
  --allow-pending, which prepping uses to see the rest of the tree.

--inherit is C11H-268's 1.x bar: measured against public c11's tree (--baseline, default
`origin/main`, else `c11/main` where a checkout names public c11 that way), kinds and values that
tree already carries are counted as inherited, not blocked.

Private terms (client and people names) can't be written into a public script, so they come
from a private file, one term per line, matched case-insensitively as whole words: --terms, or
C11_PUBLIC_TREE_TERMS, or public-tree-terms.txt in a c11-ops checkout beside this repo. They
always block. Without the file the check says so and skips them.

Exit 0 when clean, 1 with one line per finding, 2 when the check can't run (a missing
baseline in --inherit, a bad allowlist, a crash). An allowlist entry is
`path<TAB>the whole line, stripped<TAB>reason`; each entry admits exactly one line.
"""
import argparse
import importlib.util
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_BYTES = 8 * 1024 * 1024


def config_error(message):
    print("check-public-tree: " + message, file=sys.stderr)
    sys.exit(2)


def load_shareable():
    path = os.path.join(HERE, "check-shareable.py")
    spec = importlib.util.spec_from_file_location("check_shareable", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SHAREABLE = load_shareable()
SHARE = dict(SHAREABLE.PATTERNS)


def share(label):
    if label not in SHARE:
        config_error("check-shareable.py no longer has the rule %r; update KINDS" % label)
    return SHARE[label]


# Operations material, which lives in the private c11-ops repo (C11H-268). Any tracked file
# under one of these blocks, so a revert or a stray copy can't bring it back.
OPS_PATHS = {
    "tools/friend-downloads/": "the friend-download Worker (c11-ops friend-downloads/)",
    "scripts/c11-friend-publish.py": "the friend-download publisher (c11-ops friend-downloads/publish.py)",
    "docs/c11-friend-downloads.md": "the friend-download runbook (c11-ops friend-downloads/README.md)",
    "notes/c11h-run/": "the c11 run's notes and state (c11-ops notes/c11h-run/)",
    "tools/c11h-proofs/": "the c11 acceptance proofs (c11-ops tools/c11h-proofs/)",
    "tools/c11h-validator/": "the c11 acceptance validator (c11-ops tools/c11h-validator/)",
    "notes/c11v-herdr-core/": "the hc design notes and evidence (c11-ops notes/c11v-herdr-core/)",
}

# Material that moves to c11-ops before the public push, still in the tree while the 2.0 prep run
# writes it. Blocks unless --allow-pending; its contents aren't scanned.
PENDING_PATHS = {
    "notes/c11-2.0/": "the c11 2.0 prep run's notes (moves to c11-ops notes/c11-2.0/ before the public push)",
}

# Third-party files c11 bundles but doesn't write. Their words aren't the operator's (a word in
# a graphics library is not a machine) and their addresses are their authors' or minified noise, so strict skips
# those two kinds there; secrets and tailnet addresses are still checked.
VENDORED = tuple(d.replace(os.sep, "/") + "/" for d in SHAREABLE.SKIP_DIRS)
VENDORED_KINDS = ("operator's machine or place", "email address")
VENDORED_GITLEAKS_RULES = ("generic-api-key",)

EMAIL = re.compile(r"(?<![\w.+-])[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
# Reserved, sample and private-network domains (an ssh target such as me@studio.lan), and
# package@version or image@2x shapes.
EMAIL_IGNORED_DOMAIN = re.compile(
    r"(?:^|\.)(?:example\.(?:com|org|net)|example|invalid|test|local|localhost|lan|home\.arpa|internal)$"
    r"|^\d+x?\.", re.IGNORECASE)
# git@github.com and its kin are ssh URLs' users, not mailboxes.
EMAIL_IGNORED_USER = re.compile(r"^(?:no-?reply|noreply\+?.*|git)$", re.IGNORECASE)
STAGE11_HOST = re.compile(r"\b(?:[\w-]+\.)+stage11\.(?:ai|systems|dev|com|io|app|net|org)\b", re.IGNORECASE)

SECRET = re.compile(
    r"\bgh[pousr]_[A-Za-z0-9]{36}\b"
    r"|\bgithub_pat_[A-Za-z0-9_]{22,}"
    r"|\bsk-ant-[A-Za-z0-9_-]{20,}"
    r"|\bsk-(?:proj-)?[A-Za-z0-9]{32,}\b"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\bxox[abposr]-[A-Za-z0-9-]{10,}"
    r"|\bAIza[0-9A-Za-z_-]{35}\b"
    r"|\bglpat-[A-Za-z0-9_-]{20,}"
    r"|\bnpm_[A-Za-z0-9]{36}\b"
    r"|-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----")

# (kind, pattern, mode, triggers). mode: strict | value | kind (and absolute, for the private
# terms: no baseline exemption at all). A pattern with triggers runs only on a line whose
# Unicode-lowercased copy holds one of them; every match contains one, so a line without a trigger
# can't match (keeps a cold scan of both trees to seconds). None runs it on every line. Matches are
# judged per line, as check-shareable.py does.
KINDS = [
    ("tailnet host or address", share("a tailnet host or address"), "strict", ("ts.net", "100.", "fd7a:")),
    ("secret", SECRET, "strict",
     ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "sk-", "akia", "xox", "aiza", "glpat-", "npm_",
      "private key")),
    ("email address", EMAIL, "value", ("@",)),
    ("Stage 11 host", STAGE11_HOST, "value", ("stage11.",)),
    ("operator's home path or contact", share("a home path or contact of Atin's"), "kind", None),
    ("operator's machine or place", share("one of Atin's machines or places"), "kind", None),
    ("private machine used as a host", share("a private machine used as a host"), "kind",
     ("ssh", "--on", "--host", "machine add")),
    ("build host's build or artifact folder", share("a build host's build or artifact folder"), "kind",
     ("c11-", "c11h-")),  # c11-2.0:keep
]

# Strict only, in place of the machine kind above: every machine and place word, the build host
# included. A letter, digit, hyphen or underscore on either side makes it part of an identifier
# (a type, file or variable name, not a machine); a space, dot, colon, slash or quote doesn't.
STRICT_MACHINES = ("operator's machine or place",
                   SHAREABLE.Words(SHAREABLE.MACHINE_WORDS | SHAREABLE.STRICT_MACHINE_WORDS, joiners="_-"),
                   "strict", None)


def load_terms(path):
    """A strict kind for the private terms file, or None when there is no file."""
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        terms = [t.strip() for t in handle if t.strip() and not t.lstrip().startswith("#")]
    if not terms:
        return None
    pattern = re.compile(r"(?<![A-Za-z0-9])(?:%s)(?![A-Za-z0-9])" % "|".join(
        re.escape(t).replace(r"\ ", r"[\s_-]?") for t in sorted(terms, key=len, reverse=True)), re.IGNORECASE)
    triggers = tuple(sorted({t.split()[0].lower() for t in terms}))
    return ("private term", pattern, "absolute", triggers)


def git(root, *args, binary=False):
    proc = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout if binary else proc.stdout.decode("utf-8", "replace")


def decode(data):
    if data is None or len(data) > MAX_BYTES or b"\0" in data:
        return None
    return data.decode("utf-8", "replace")


def tracked_files(root):
    out = git(root, "ls-files", "-z", "--cached", binary=True)
    return [p.decode("utf-8", "replace") for p in out.split(b"\0") if p]


def read_worktree(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path) or os.path.islink(path):
        return None
    try:
        with open(path, "rb") as handle:
            if os.fstat(handle.fileno()).st_size > MAX_BYTES:
                return None
            return decode(handle.read())
    except OSError:
        return None


def _scan_file(job):
    """A pool worker: the matches in one tracked file, read where it lies (None when unreadable)."""
    root, rel = job
    text = read_worktree(root, rel)
    return rel, None if text is None else list(matches(text))


def scan_all(root, rels):
    """{rel: matches} for every readable file, spread over the cores. Forked workers inherit KINDS
    as main() set it up (the strict machines, the private terms); without fork it runs inline."""
    jobs = [(root, rel) for rel in rels]
    try:
        context = multiprocessing.get_context("fork")
    except ValueError:
        context = None
    if context is None or len(jobs) < 200:
        return dict(map(_scan_file, jobs))
    with context.Pool(min(8, os.cpu_count() or 1)) as pool:
        return dict(pool.imap_unordered(_scan_file, jobs, chunksize=16))


def baseline_blobs(root, ref):
    """Yield (path, text) for every text blob in the baseline tree, via one cat-file batch."""
    listing = git(root, "ls-tree", "-r", "-z", ref, binary=True)
    entries = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, sha = meta.split()
        if kind == b"blob" and mode != b"120000":
            entries.append((path.decode("utf-8", "replace"), sha.decode()))
    proc = subprocess.Popen(["git", "-C", root, "cat-file", "--batch"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE)
    proc.stdin.write("".join(sha + "\n" for _, sha in entries).encode())
    proc.stdin.close()
    for path, _ in entries:
        header = proc.stdout.readline().split()
        size = int(header[2])
        data = proc.stdout.read(size)
        proc.stdout.read(1)
        yield path, decode(data)
    proc.wait()


def matches(text):
    """Yield (line number, kind, mode, value) for every finding in a text.

    One original line at a time: its Unicode-lowercased copy decides which patterns run (a line
    without any of a kind's triggers can't match it), and the patterns run on that same original
    line, so a line number and a match never depend on another line's offsets.
    """
    # A kind none of whose triggers appears anywhere in the text can't match any line of it, so it is
    # dropped before the per-line loop (and before its might_match, which is the costly part).
    low_text = text.lower()
    kinds = [k for k in KINDS
             if (k[3] is None or any(t in low_text for t in k[3]))
             and (not hasattr(k[1], "might_match") or k[1].might_match(text))]
    for number, line in enumerate(text.split("\n"), 1):
        low = line.lower()
        for kind, pattern, mode, triggers in kinds:
            if triggers is not None and not any(t in low for t in triggers):
                continue
            for m in pattern.finditer(line):
                if kind == "email address":
                    user = m.group(0).split("@", 1)[0]
                    if EMAIL_IGNORED_DOMAIN.search(m.group(1)) or EMAIL_IGNORED_USER.match(user):
                        continue
                    if line[max(0, m.start() - 3):m.start()] == "://":
                        continue  # a URL's user part, not an address
                yield number, kind, mode, m.group(0)


def measure_baseline(root, ref):
    """The baseline's kinds (with the paths that carry each) and values."""
    kinds, values = {}, set()
    for path, text in baseline_blobs(root, ref):
        if text is None:
            continue
        for _, kind, mode, value in matches(text):
            if mode == "kind":
                kinds.setdefault(kind, set()).add(path)
            elif mode == "value":
                values.add((kind, value.lower()))
    return kinds, values


def start_gitleaks(root):
    """Start gitleaks over the tree in the background, or return None when it isn't installed."""
    exe = shutil.which("gitleaks")
    if not exe:
        return None
    tmp = tempfile.mkdtemp(prefix="c11-public-tree.")
    report = os.path.join(tmp, "gitleaks.json")
    proc = subprocess.Popen([exe, "dir", "--no-banner", "--log-level", "error", "--exit-code", "0",
                             "--report-format", "json", "--report-path", report, root],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return proc, tmp, report


def gitleaks_findings(started, root, files):
    """gitleaks' findings in tracked files: [(path, line number, rule)]."""
    proc, tmp, report = started
    try:
        _, err = proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError("gitleaks failed: %s" % err.decode("utf-8", "replace").strip()[:300])
        with open(report, encoding="utf-8") as handle:
            data = json.load(handle) or []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    tracked = set(files)
    found = []
    for item in data:
        rel = item.get("File", "")
        if os.path.isabs(rel):
            rel = os.path.relpath(rel, root)
        if rel in tracked:
            found.append((rel, int(item.get("StartLine") or 0), item.get("RuleID", "gitleaks")))
    return found


def under(rel, prefixes):
    for prefix in prefixes:
        if rel == prefix or (prefix.endswith("/") and rel.startswith(prefix)):
            return prefix
    return None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.dirname(HERE))
    parser.add_argument("--strict", action="store_true", help="every kind blocks (the default)")
    parser.add_argument("--inherit", action="store_true",
                        help="the 1.x bar: pass kinds and values public c11 already carries (needs --baseline)")
    parser.add_argument("--baseline",
                        help="with --inherit, public c11's tree to measure against "
                             "(default origin/main, else c11/main)")
    parser.add_argument("--allow-pending", action="store_true",
                        help="report PENDING_PATHS without failing on them (prep only; never for the push)")
    parser.add_argument("--allowlist")
    parser.add_argument("--no-gitleaks", action="store_true", help="skip gitleaks even when installed")
    parser.add_argument("--terms", help="private terms file (default: C11_PUBLIC_TREE_TERMS, or "
                                        "../c11-ops/public-tree-terms.txt beside the repo)")
    args = parser.parse_args(argv)
    if args.strict and args.inherit:
        config_error("--strict and --inherit are opposites; pass one")
    strict = not args.inherit
    if strict:
        KINDS[:] = [STRICT_MACHINES if k[0] == STRICT_MACHINES[0] else k for k in KINDS]
    root = os.path.abspath(args.root)
    terms_path = args.terms or os.environ.get("C11_PUBLIC_TREE_TERMS")
    if not terms_path:
        # Beside this checkout, or beside the main checkout when this is a worktree.
        bases = [root]
        try:
            common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
            bases.append(os.path.dirname(common))
        except RuntimeError:
            pass
        candidates = [os.path.join(os.path.dirname(b), "c11-ops", "public-tree-terms.txt") for b in bases]
        terms_path = next((c for c in candidates if os.path.isfile(c)), None)
    if args.terms and not os.path.isfile(args.terms):
        config_error("no terms file at %s" % args.terms)
    terms_kind = load_terms(terms_path)
    if terms_kind:
        KINDS.append(terms_kind)
    allow_path = args.allowlist or os.path.join(root, "scripts", "public-tree-allowlist.txt")
    allow = SHAREABLE.load_allowlist(allow_path)

    base_sha = None
    if not strict:
        for ref in [args.baseline] if args.baseline else ["origin/main", "c11/main"]:
            try:
                base_sha = git(root, "rev-parse", "--verify", ref + "^{tree}").strip()
            except RuntimeError:
                continue
            args.baseline = ref
            break
        if base_sha is None:
            config_error("baseline %s is missing, so nothing was measured (git fetch origin main)"
                         % (args.baseline or "origin/main (or c11/main)"))

    started = None if args.no_gitleaks else start_gitleaks(root)
    base_kinds, base_values = measure_baseline(root, base_sha) if not strict else ({}, set())
    base_lines = {}
    files = tracked_files(root)

    findings, inherited, pending, counts = [], {}, {}, {}

    def allowed(rel, text):
        entry = next((e for e in allow if e["path"] == rel and e["text"] == text.strip()), None)
        if entry is not None:
            entry["hits"] += 1
            return True
        return False

    def published_line(rel, text):
        """True when the identical line already ships at the same path in the baseline."""
        if strict:
            return False
        if rel not in base_lines:
            proc = subprocess.run(["git", "-C", root, "cat-file", "blob", "%s:%s" % (base_sha, rel)],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            data = decode(proc.stdout) if proc.returncode == 0 else None
            base_lines[rel] = set(l.strip() for l in data.split("\n")) if data else set()
        return text.strip() in base_lines[rel]

    scanned = 0
    file_texts = {}
    allow_rel = os.path.relpath(allow_path, root)
    scan = [rel for rel in files
            if rel != allow_rel and not under(rel, PENDING_PATHS) and not under(rel, OPS_PATHS)]
    scanned_hits = scan_all(root, scan)
    for rel in files:
        if rel == allow_rel:
            continue  # the allowlist quotes the lines it admits
        held = under(rel, PENDING_PATHS)
        if held:
            pending.setdefault(held, []).append(rel)
            continue
        ops = under(rel, OPS_PATHS)
        if ops:
            findings.append("%s: operations material: %s" % (rel, OPS_PATHS[ops]))
            continue
        text = read_worktree(root, rel)
        hits = scanned_hits.get(rel)
        if text is None or hits is None:
            continue
        scanned += 1
        file_texts[rel] = text
        if not hits:
            continue
        lines = text.split("\n")
        by_line = {}
        for number, kind, mode, value in hits:
            by_line.setdefault(number, []).append((kind, mode, value))
        for number in sorted(by_line):
            line = lines[number - 1] if number <= len(lines) else ""
            blocking = []
            for kind, mode, value in by_line[number]:
                if strict and kind in VENDORED_KINDS and rel.startswith(VENDORED):
                    continue
                if strict:
                    blocking.append((kind, value))
                elif mode == "kind" and kind in base_kinds:
                    inherited.setdefault(kind, set()).add(rel)
                elif mode == "value" and (kind, value.lower()) in base_values:
                    inherited.setdefault(kind, set()).add(rel)
                elif mode == "strict" and published_line(rel, line):
                    inherited.setdefault(kind, set()).add(rel)
                else:
                    blocking.append((kind, value))
            if blocking and not allowed(rel, line):
                for kind, value in blocking:
                    counts[kind] = counts.get(kind, 0) + 1
                    shown = value if kind != "secret" else value[:6] + "…"
                    findings.append("%s:%d: %s (%r)" % (rel, number, kind, shown))

    leaks = None if started is None else gitleaks_findings(started, root, files)
    for rel, number, rule in leaks or []:
        if rel == allow_rel or under(rel, OPS_PATHS) or under(rel, PENDING_PATHS):
            continue
        if strict and rel.startswith(VENDORED) and rule in VENDORED_GITLEAKS_RULES:
            continue  # minified third-party code trips the generic rule; dedicated secret rules still block
        text = file_texts.get(rel)
        lines = text.split("\n") if text else []
        line = lines[number - 1] if 0 < number <= len(lines) else ""
        if line and published_line(rel, line):
            inherited.setdefault("gitleaks " + rule, set()).add(rel)
            continue
        if line and allowed(rel, line):
            continue
        counts["gitleaks"] = counts.get("gitleaks", 0) + 1
        findings.append("%s:%d: gitleaks %s" % (rel, number, rule))

    def still_there(e):
        text = file_texts.get(e["path"])
        return text is not None and e["text"] in (l.strip() for l in text.split("\n"))

    for e in allow:
        # Without gitleaks, an entry for a line only gitleaks flags can't be hit; it is stale only
        # when its line is gone.
        # The allowlist is written for the strict bar, so --inherit doesn't judge unused entries.
        if strict and e["hits"] < 1 and (started is not None or not still_there(e)):
            findings.append("%s:%d: allowlist entry matched no line: %s" % (allow_rel, e["line"], e["path"]))

    base_files = {}
    for kind, paths in base_kinds.items():
        base_files[kind] = len(paths)
    for kind in sorted(inherited):
        note = " (public c11 carries this kind in %d files)" % base_files[kind] if kind in base_files else ""
        print("check-public-tree: inherited: %s in %d files%s" % (kind, len(inherited[kind]), note))
    if terms_kind is None:
        print("check-public-tree: no private terms file (c11-ops/public-tree-terms.txt); client and people names not checked")
    if started is None and not args.no_gitleaks:
        print("check-public-tree: gitleaks is not installed; secrets checked by token shape only")
    for prefix in sorted(pending):
        word = "pending (allowed by --allow-pending)" if args.allow_pending else "pending"
        line = "%s: %s, %d files: %s" % (prefix, word, len(pending[prefix]), PENDING_PATHS[prefix])
        if args.allow_pending:
            print("check-public-tree: " + line)
        else:
            findings.append(line)
    for line in findings:
        print("check-public-tree: " + line)
    bar = "strict" if strict else "against %s" % args.baseline
    if findings:
        if counts:
            print("check-public-tree: by kind: " + ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts)))
        print("check-public-tree: %d finding(s), %s. Remove or scrub them, move operations material to "
              "the private ops repo, or add the whole line with a reason to scripts/public-tree-allowlist.txt."
              % (len(findings), bar))
        return 1
    print("check-public-tree: ok, %d files, %s" % (scanned, bar))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as error:  # a crash is not a finding
        print("check-public-tree: failed to run: %r" % (error,), file=sys.stderr)
        sys.exit(2)
