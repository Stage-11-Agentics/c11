#!/usr/bin/env python3
"""List every "c11h" a user can see in a built c11 2.0 app (C11H-265).

    python3 scripts/c11-2.0-visible-check.py <path/to/c11.app> [--json]

Looks where a user reads text: Info.plist strings, the compiled Localizable
strings of every locale, bundled theme names, the bundled skills, the CLI's
help, unknown-verb and guide output (every page), and `c11 version`. The CLI
runs with an empty HOME and no socket, so it never reaches a running app.

Exit 0 when nothing is found, 1 when something is, 2 on a usage error, 3 when
something that must be read could not be (a CLI that fails or prints nothing, an
unreadable strings file): the check never passes on output it did not see.
`c11h` as the name of the hidden CLI alias file (`bin/c11h`) is not text a user
reads and is not reported. Lines that merely carry a ticket id (`C11H-123`) are
not reported either.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

HIT = re.compile(r"c11h", re.I)
# Verbs whose --help runs another program (absent here); their text is read from the source.
EXTERNAL_HELP = {"claude-teams"}
TICKET = re.compile(r"\bC11H-\d+")
# The c11h sidecar skill folds into the c11 skill in WS7 (C11H plan, workstream 7).
KNOWN_ELSEWHERE = ("skills/c11h/",)


# Messages that must name c11h: they tell a c11h user to quit c11h before 2.0 brings their
# state over (C11H-266). Allowed by key name; any other "c11h" in a string still fails.
ALLOWED_KEYS = {
    "migration.gate.goBack": "tells the user to quit c11 and open the c11h they came from",
    "migration.gate.legacyStillRunning": "tells the user to quit the c11h that is still running",
    "migration.gate.waiting": "says c11h is still quitting and c11 opens once it has",
}


def hits(text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        if HIT.search(TICKET.sub("", line)):
            out.append(line.strip()[:200])
    return out


def walk_strings(value, path=""):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from walk_strings(v, f"{path}.{k}" if path else k)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from walk_strings(v, f"{path}[{i}]")


class Unverified(Exception):
    """Output that should exist could not be read: the check fails closed."""


def run_cli(cli: str, args: list[str], home: str, expect_failure: bool = False) -> str:
    # A socket path no app listens on, so no command reaches a running c11.
    dead = f"/tmp/c11-visible-check-{os.getpid()}.sock"
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "dumb",
           "C11_SOCKET_PATH": dead, "C11_SOCKET": dead, "CMUX_SOCKET_PATH": dead}
    try:
        p = subprocess.run([cli, *args], env=env, capture_output=True, text=True, timeout=20)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise Unverified(f"c11 {' '.join(args)}: {exc}")
    out = p.stdout + p.stderr
    if (p.returncode != 0) != expect_failure or not out.strip():
        raise Unverified(f"c11 {' '.join(args)}: exit {p.returncode}, {len(out)} bytes of output")
    return out


def read_strings(path: str) -> dict:
    """A compiled .strings/.stringsdict (binary or XML plist) or a text-format .strings file."""
    with open(path, "rb") as fh:
        raw = fh.read()
    try:
        return plistlib.loads(raw)
    except Exception:
        pass
    for encoding in ("utf-16", "utf-8"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise Unverified(f"{path}: unreadable strings file")
    if text.lstrip().startswith("<?xml"):  # an XML plist in UTF-16
        body = text.lstrip().split("?>", 1)[1]
        return plistlib.loads(('<?xml version="1.0" encoding="UTF-8"?>' + body).encode("utf-8"))
    pairs = re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text)
    if not pairs and text.strip():
        raise Unverified(f"{path}: no strings parsed")
    return dict(pairs)


def main() -> int:
    try:
        return check()
    except Unverified as exc:
        print(f"c11-2.0-visible-check: UNVERIFIED: {exc}", file=sys.stderr)
        return 3


def check() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].endswith(".app"):
        print(__doc__, file=sys.stderr)
        return 2
    app = os.path.abspath(sys.argv[1])
    as_json = "--json" in sys.argv
    res = os.path.join(app, "Contents", "Resources")
    found: dict[str, list[str]] = {}
    warnings: dict[str, list[str]] = {}

    def add(section: str, items: list[str], known: bool = False):
        if items:
            (warnings if known else found).setdefault(section, []).extend(items)

    # Bundle name and Info.plist.
    if HIT.search(os.path.basename(app)):
        add("app name", [os.path.basename(app)])
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as fh:
        info = plistlib.load(fh)
    # LSEnvironment holds a Debug build's repo path (C11_REPO_ROOT); a Release bundle has none.
    add("Info.plist", [f"{k}: {v}" for k, v in walk_strings(info)
                       if (HIT.search(v) or HIT.search(k)) and not k.startswith("LSEnvironment.")])

    # Localized strings, every locale.
    for entry in sorted(os.listdir(res)):
        if not entry.endswith(".lproj"):
            continue
        for name in sorted(os.listdir(os.path.join(res, entry))):
            full = os.path.join(res, entry, name)
            if name.endswith(".strings") or name.endswith(".stringsdict"):
                data = read_strings(full)
                add(f"{entry}/{name}", [f"{k}: {v}"[:200] for k, v in walk_strings(data)
                                    if hits(v) and k not in ALLOWED_KEYS])

    # Bundled theme names a picker shows.
    for folder in ("c11-themes", os.path.join("ghostty", "themes")):
        d = os.path.join(res, folder)
        if os.path.isdir(d):
            add(f"themes ({folder})", [n for n in sorted(os.listdir(d)) if HIT.search(n)])

    # Bundled skills.
    skills = os.path.join(res, "skills")
    for dirpath, _, files in os.walk(skills):
        for name in files:
            if not name.endswith(".md"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, res)
            text = open(full, encoding="utf-8", errors="replace").read()
            lines = hits(text)
            known = rel.startswith(KNOWN_ELSEWHERE)
            if HIT.search(rel):
                lines = [f"(path) {rel}"] + lines
            add(rel, lines, known=known)

    # The CLI: help, every guide page, version, an unknown verb, per-command help.
    cli = os.path.join(res, "bin", "c11")
    with tempfile.TemporaryDirectory() as home:
        outputs = {
            "c11 --help": run_cli(cli, ["--help"], home),
            "c11 version": run_cli(cli, ["version"], home),
            "c11 guide": run_cli(cli, ["guide"], home),
            "c11 no-such-verb --help": run_cli(cli, ["no-such-verb", "--help"], home),
        }
        pages = os.path.join(skills, "c11", "references")
        if os.path.isdir(pages):
            for name in sorted(os.listdir(pages)):
                if name.endswith(".md"):
                    page = name[:-3]
                    outputs[f"c11 guide {page}"] = run_cli(cli, ["guide", page], home)
        verbs = set(re.findall(r"^\s{2,}([a-z][a-z0-9-]+)\b", outputs["c11 --help"], re.M))
        if len(verbs) < 10:
            raise Unverified(f"c11 --help listed {len(verbs)} verbs")
        for verb in sorted(verbs - EXTERNAL_HELP):
            outputs[f"c11 {verb} --help"] = run_cli(cli, [verb, "--help"], home)
        for label, text in outputs.items():
            add(label, hits(text))
        # The hidden alias runs this build and still never says its own name.
        alias = os.path.join(res, "bin", "c11h")
        if os.path.exists(alias):
            add("c11h no-such-verb --help (alias)", hits(run_cli(alias, ["no-such-verb", "--help"], home)))

    report = {"app": app, "found": found, "known_elsewhere": warnings,
              "count": sum(len(v) for v in found.values())}
    if as_json:
        print(json.dumps(report, indent=1))
    else:
        for section, items in found.items():
            print(f"== {section} ({len(items)})")
            for item in items[:40]:
                print("   " + item)
        for section, items in warnings.items():
            print(f"-- {section}: {len(items)} (owned by another workstream)")
        print(f"c11-2.0-visible-check: {report['count']} visible c11h in {len(found)} places"
              + (f"; {sum(len(v) for v in warnings.values())} in other workstreams' files" if warnings else ""))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
