#!/usr/bin/env python3
"""C11-317: capture `--help` behavior of every c11 CLI command for before/after diffs.

    scripts/cli-help-snapshot.py <c11-binary> <out-dir> [<swift-source-dir>]

For each command word (usage text, `case "x"` arms in the CLI sources, and the
two-word forms the usage text lists) it records exit code, stdout and stderr of
`c11 <cmd> --help` and `c11 help <cmd>`, plus the global forms. The binary runs
with a scrubbed environment and no reachable socket. Snapshot the pre-change
binary and the post-change binary, then `diff -r` the two directories.
"""
import os
import re
import subprocess
import sys


def command_words(binary, src_dir):
    env = scrubbed_env("/nonexistent/c11.sock")
    usage = subprocess.run([binary, "--help"], capture_output=True, text=True, env=env, timeout=20).stdout
    words = set()
    in_commands = False
    for line in usage.splitlines():
        if re.match(r"^[A-Z][A-Za-z ]+:$", line.strip()) and not line.startswith(" "):
            in_commands = line.strip() == "Commands:"
            continue
        if in_commands and line.startswith("  ") and not line.startswith("   "):
            toks = line.split()
            if toks and re.match(r"^[a-z][a-z0-9-]*$", toks[0]):
                words.add((toks[0],))
                if len(toks) > 1 and re.match(r"^[a-z][a-z0-9-]*$", toks[1]):
                    words.add((toks[0], toks[1]))
    for name in sorted(os.listdir(src_dir)):
        if not name.endswith(".swift"):
            continue
        text = open(os.path.join(src_dir, name)).read()
        for m in re.finditer(r"^\s*case ((?:\"[a-z][a-z0-9-]*\"(?:,\s*)?)+):", text, re.M):
            for w in re.findall(r"\"([a-z][a-z0-9-]*)\"", m.group(1)):
                words.add((w,))
    return sorted(words)


def scrubbed_env(socket):
    return {
        "HOME": "/nonexistent-home",
        "PATH": "/usr/bin:/bin",
        "C11_SOCKET_PATH": socket,
        "C11_QUIET_DISCOVERY": "1",
        "LANG": "en_US.UTF-8",
    }


def run(binary, argv):
    try:
        p = subprocess.run([binary] + argv, capture_output=True, text=True, env=scrubbed_env("/nonexistent/c11.sock"), timeout=20, stdin=subprocess.DEVNULL)
        addr = lambda t: re.sub(r"0x[0-9a-f]{6,}", "0xADDR", t)  # object addresses differ per run
        return "exit=%d\n--- stdout\n%s--- stderr\n%s" % (p.returncode, addr(p.stdout), addr(p.stderr))
    except subprocess.TimeoutExpired:
        return "TIMEOUT\n"


def main():
    binary, out_dir = os.path.abspath(sys.argv[1]), sys.argv[2]
    src_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "CLI")
    os.makedirs(out_dir, exist_ok=True)
    cases = {
        "global--help": ["--help"],
        "global-h": ["-h"],
        "global-help": ["help"],
        "global-version": ["--version"],
        "global-noargs": [],
        "global-unknown": ["definitely-not-a-command"],
    }
    for w in command_words(binary, src_dir):
        key = "__".join(w)
        cases["cmd-%s--help" % key] = list(w) + ["--help"]
        cases["cmd-%s-h" % key] = list(w) + ["-h"]
        cases["help-%s" % key] = ["help"] + list(w)
    for name, argv in sorted(cases.items()):
        with open(os.path.join(out_dir, name + ".txt"), "w") as fh:
            fh.write("argv=%r\n" % (argv,))
            fh.write(run(binary, argv))
    print("%d invocations -> %s" % (len(cases), out_dir))


main()
