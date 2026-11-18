#!/usr/bin/env python3
"""C11H-130: fail when a change puts a known friend-share blocker into what c11 ships.

Atin's ruling (C11.md, 2026-11-02): main stays shareable with a friend at all times. This
check scans what a friend receives (the app's resources, the skills an agent can install,
the Swift that becomes the app's strings, the installer and the friend's install guide) for
things that only make sense on Atin's machines: his home paths and contact, his machine
names, his tailnet, Stage 11's private hosts, and the build host's build and artifact folders.

    scripts/check-shareable.py [--root <repo>]

Exit 0 when clean, 1 with one line per finding, 2 when the check itself can't run
(a bad allowlist or MANIFEST.json, a crash). A deliberate match goes in
scripts/shareable-allowlist.txt as `path<TAB>the whole line, stripped<TAB>reason`. Each
entry admits exactly one line; an entry that matches no line, or more than one, fails too.
"""
import argparse
import hashlib
import json
import os
import re
import sys


def word_hash(word):
    return hashlib.sha256(word.lower().encode("utf-8")).hexdigest()[:16]


# The operator's machine and place names and two contact words, kept as SHA-256 prefixes of the
# lowercased word so this public script names none of them (C11H-284). A hash of a short word
# hides it from a search of the tree, not from a guess, and that is all it is for. To add one:
#     python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].lower().encode()).hexdigest()[:16])' <word>
# A name of two or three words is hashed run together ("Some Lab" is "somelab").
MACHINE_WORDS = frozenset({
    "d6f12e4e2cb4b9fb", "4f28d7537769ee73", "5050ef19954be743", "e16e594c2c24d0bd", "49b8ebd7fa9eb7ec"})
# The build host and the other machines and places, which only the strict public-tree check
# blocks: the friend-share scan allows them as plain words (check-public-tree.py --strict).
STRICT_MACHINE_WORDS = frozenset({"7c82602500857aa6", "d292237213123931", "294aa8d75483b833", "b07ec327d75c9759"})
CONTACT_WORDS = frozenset({"a9c5221fb9c39d95", "256e94b123216bf9"})
# The first word of each name above that is two words run together, so a whole file can be
# ruled out from its set of words before any line is read.
# Every spelling a name's first word takes ("Name's Lab" and "Names Lab" both).
FIRST_WORDS = frozenset({"28561c6b68fca875", "f7bab6b255bfc08c", "eeacb567c63b51ac"})
ALNUM = re.compile(r"[a-z0-9]+")


class Hit:
    """The part of a line a word list matched, shaped like the re.Match the callers read."""
    __slots__ = ("string", "begin", "end_")

    def __init__(self, string, begin, end):
        self.string, self.begin, self.end_ = string, begin, end

    def group(self, index=0):
        return self.string[self.begin:self.end_]

    def start(self):
        return self.begin

    def end(self):
        return self.end_


class Words:
    """Finds words whose hash is in a set, as whole tokens.

    A token is a run of letters and digits, plus `joiners` (with "-_", c11-x-link.sh or
    x_slots.py stays one token, an identifier rather than the word). Trailing digits are dropped
    before hashing (name17 is name), and two or three tokens one space, apostrophe or dot apart
    are also tried run together (Name's Lab, name.me).
    """

    def __init__(self, hashes, joiners=""):
        self.hashes = frozenset(hashes)
        self.token = re.compile(r"[A-Za-z0-9%s]+" % re.escape(joiners))
        self.cache = {}
        self.firsts = {}
        self.only = None

    def hit(self, word):
        word = word.lower()
        found = self.cache.get(word)
        if found is None:
            bare = word.rstrip("0123456789")
            found = word_hash(word) in self.hashes or (bare != word and bare and word_hash(bare) in self.hashes)
            self.cache[word] = found
        return found

    def might_match(self, text):
        """False when no line of text can match. Otherwise True, and until the next call
        finditer reads only lines holding one of the words that made it True."""
        found = set()
        for word in set(ALNUM.findall(text.lower())):
            first = self.firsts.get(word)
            if first is None:
                first = self.firsts[word] = word_hash(word) in FIRST_WORDS
            if first or self.hit(word):
                found.add(word)
        self.only = re.compile(r"(?<![A-Za-z0-9])(?:%s)" % "|".join(re.escape(w) for w in sorted(found)),
                               re.IGNORECASE) if found else False
        return bool(found)

    def finditer(self, line):
        if self.only is False or (self.only is not None and not self.only.search(line)):
            return
        tokens = list(self.token.finditer(line))
        i = 0
        while i < len(tokens):
            for n in (3, 2, 1):
                run = tokens[i:i + n]
                if len(run) < n:
                    continue
                if n > 1 and any(line[a.end():b.start()] not in (" ", "'", "\u2019", ".")
                                 for a, b in zip(run, run[1:])):
                    continue
                if self.hit("".join(t.group(0) for t in run)):
                    yield Hit(line, run[0].start(), run[-1].end())
                    i += n
                    break
            else:
                i += 1


class Either:
    def __init__(self, *finders):
        self.finders = finders

    def might_match(self, text):
        # Every finder prepares (no short circuit), so none reads lines with a stale filter.
        results = [f.might_match(text) if hasattr(f, "might_match") else True for f in self.finders]
        return any(results)

    def finditer(self, line):
        for finder in self.finders:
            yield from finder.finditer(line)


class SshTarget:
    """A private machine used as a host: ssh ... <it>, --on <it>, --host <it>, machine add <it>."""
    PREFIX = re.compile(r"\bssh\b|--on[=\s]+|--host[=\s]+|machine add\s+", re.IGNORECASE)
    AFTER = re.compile(r"[\s@]([A-Za-z0-9]+)")
    AT = re.compile(r"[A-Za-z0-9]+")

    def __init__(self, words):
        self.words = words

    def finditer(self, line):
        for m in self.PREFIX.finditer(line):
            if m.group(0).lower() == "ssh":
                for w in self.AFTER.finditer(line, m.end()):
                    if self.words.hit(w.group(1)):
                        yield Hit(line, m.start(), w.end())
                        break
            else:
                w = self.AT.match(line, m.end())
                if w and self.words.hit(w.group(0)):
                    yield Hit(line, m.start(), w.end())


PATTERNS = [
    ("a home path or contact of Atin's",
     Either(re.compile(r"(?<![A-Za-z])users?[/-]atin\w*|~atin\w*|\batin@"
                       r"|(?:~|\$HOME|\$\{HOME\})/Projects/(?:Stage11|Gregorovich)", re.IGNORECASE),
            Words(CONTACT_WORDS))),
    ("one of Atin's machines or places", Words(MACHINE_WORDS)),
    ("a private machine used as a host", SshTarget(Words(MACHINE_WORDS | STRICT_MACHINE_WORDS))),
    ("a tailnet host or address",
     re.compile(r"\.ts\.net\b|\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b|\bfd7a:115c:a1e0:",
                re.IGNORECASE)),
    ("a Stage 11 host that isn't public", re.compile(r"\b(?!www\.)[\w-]+\.stage11\.ai\b", re.IGNORECASE)),
    # c11-builds, -release and -poller only as a path segment (~/c11-builds, $HOME/c11-poller/bin),
    # not the script of the same stem or its message prefix (c11-release.sh, "c11-release: ...").
    ("a build host's build or artifact folder",
     re.compile(r"\bc11h-(?:run|pf)\b|\bc11h-builds\.noindex|(?<=/)c11-(?:builds|release|poller)(?![\w.-])")),
]

# What a friend receives. Every entry must exist, so a rename can't switch the scan off.
REQUIRED = ["Resources", "Sources", "CLI", "scripts/c11-install.sh", "skills/MANIFEST.json",
            "docs/c11-friend-install.md"]
OPTIONAL = []
# Third-party files we bundle but don't write.
SKIP_DIRS = {
    os.path.join("Resources", "markdown-viewer", "vendor"),
    os.path.join("Resources", "ghostty", "themes"),
    os.path.join("Resources", "ghostty", "terminfo"),
}
MAX_BYTES = 8 * 1024 * 1024
MIN_ALLOW_TEXT = 12


# Maintainer skills: copied into the bundle with the rest of skills/, but nothing installs
# them for a user (not in MANIFEST.json's installable list, not c11). Every other skill
# directory is scanned, so a new skill is covered by default.
MAINTAINER_SKILLS = {"c11-hotload", "release", "c11-full-review", "c11-workspace-review", "opencode-plugins"}


def config_error(message):
    print("check-shareable: " + message, file=sys.stderr)
    sys.exit(2)


def skills_in_scope(root):
    with open(os.path.join(root, "skills", "MANIFEST.json"), encoding="utf-8") as handle:
        installable = json.load(handle).get("installable")
    if not isinstance(installable, list) or not installable:
        config_error("skills/MANIFEST.json has no installable list")
    leaked = sorted(MAINTAINER_SKILLS & set(installable))
    if leaked:
        config_error("maintainer skills are now installable: %s; scan them" % ", ".join(leaked))
    skills = os.path.join(root, "skills")
    return [os.path.join("skills", name) for name in sorted(os.listdir(skills))
            if name not in MAINTAINER_SKILLS and os.path.isdir(os.path.join(skills, name))]


def walk(root, rel):
    full = os.path.join(root, rel)
    if os.path.isfile(full):
        yield rel
        return
    for dirpath, dirnames, filenames in os.walk(full):
        reldir = os.path.relpath(dirpath, root)
        dirnames[:] = sorted(d for d in dirnames if os.path.join(reldir, d) not in SKIP_DIRS)
        for name in sorted(filenames):
            yield os.path.join(reldir, name)


def files_in(root):
    missing = []
    scope = list(REQUIRED) + skills_in_scope(root)
    for rel in scope:
        if not os.path.exists(os.path.join(root, rel)):
            missing.append(rel)
    scope += [rel for rel in OPTIONAL if os.path.exists(os.path.join(root, rel))]
    files = []
    for rel in scope:
        files.extend(walk(root, rel))
    return files, missing


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return None
    if b"\0" in data:
        return None
    return data.decode("utf-8", "replace")


def swift_code_lines(text):
    """Yield (number, text) for what a Swift file ships: code and string contents, not comments.

    A line inside a multi-line string literal is shipped text even when it starts with //.
    Outside one, a // comment (on its own or after code) is dropped; a // inside a "..."
    string is kept. Block comments are rare enough here to scan as text.
    """
    in_multiline = False
    for number, line in enumerate(text.splitlines(), 1):
        if in_multiline:
            yield number, line
            if line.count('"""') % 2 == 1:
                in_multiline = False
            continue
        code = strip_swift_comment(line)
        if code.count('"""') % 2 == 1:
            in_multiline = True
        yield number, code


def strip_swift_comment(line):
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def lines_of(rel, text):
    if rel.endswith(".swift"):
        return swift_code_lines(text)
    # Comments in scripts, docs and resources ship as text, so they are scanned.
    return enumerate(text.splitlines(), 1)


def load_allowlist(path):
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            # The quoted line may hold tabs (a TSV row): the path ends at the first tab and the
            # reason starts after the last.
            head, _, rest = line.partition("\t")
            text, _, reason = rest.rpartition("\t")
            parts = [head, text, reason]
            if "\t" not in rest or not all(p.strip() for p in parts):
                config_error("%s:%d: want path<TAB>the whole line, stripped<TAB>reason"
                                 % (path, number))
            if len(parts[1].strip()) < MIN_ALLOW_TEXT:
                config_error("%s:%d: allowlist text must be the whole line (at least %d characters)"
                                 % (path, number, MIN_ALLOW_TEXT))
            entries.append({"path": parts[0], "text": parts[1].strip(), "line": number, "hits": 0})
    return entries


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--allowlist")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    allow_path = args.allowlist or os.path.join(root, "scripts", "shareable-allowlist.txt")
    allow = load_allowlist(allow_path)

    files, missing = files_in(root)
    findings = ["%s: scope path missing; update scripts/check-shareable.py if it moved" % rel for rel in missing]
    scanned = 0
    for rel in files:
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        scanned += 1
        active = [(label, p) for label, p in PATTERNS if not hasattr(p, "might_match") or p.might_match(text)]
        for number, line in lines_of(rel, text):
            matches = [(label, m.group(0)) for label, pattern in active for m in pattern.finditer(line)]
            if not matches:
                continue
            entry = next((e for e in allow if e["path"] == rel and e["text"] == line.strip()), None)
            if entry is not None:
                entry["hits"] += 1
            if entry is not None:
                continue
            for label, found in matches:
                findings.append("%s:%d: %s (%r)" % (rel, number, label, found))

    allow_rel = os.path.relpath(allow_path, root)
    for e in allow:
        if e["hits"] != 1:
            findings.append("%s:%d: allowlist entry must match exactly one line, matched %d: %s"
                            % (allow_rel, e["line"], e["hits"], e["path"]))
    for line in findings:
        print("check-shareable: " + line)
    if findings:
        print("check-shareable: %d finding(s). main stays shareable with a friend (C11.md, 2026-11-02): "
              "remove the private name, or add the whole line with a reason to scripts/shareable-allowlist.txt."
              % len(findings))
        return 1
    print("check-shareable: ok, %d files" % scanned)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as error:  # a crash is not a finding
        print("check-shareable: failed to run: %r" % (error,), file=sys.stderr)
        sys.exit(2)
