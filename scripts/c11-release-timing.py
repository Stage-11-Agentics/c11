#!/usr/bin/env python3
"""Print the c11 release timing log: one row per run of c11-release.sh or
the friend publisher (friend-downloads/publish.py in the private c11-ops repo), newest last, with each step's seconds.

    scripts/c11-release-timing.py                  # the log on this machine
    scripts/c11-release-timing.py --ssh HOST       # the build host's log, read from here
    scripts/c11-release-timing.py -n 20 --json     # the raw records

Times print in this machine's local time. The log is release-timing.jsonl beside
the release zip (C11_ARTIFACT's folder on the build host); both scripts append to it.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

DEFAULT_LOG = "c11h-run/artifacts/c11/release-timing.jsonl"  # under $HOME
RELEASE_STEPS = ["build", "locate", "stage", "sign", "notarize", "staple", "zip"]
PUBLISH_STEPS = ["verify", "shareable", "upload", "flip"]


def read_lines(args):
    if args.ssh:
        path = args.log or DEFAULT_LOG
        proc = subprocess.run(["ssh", args.ssh, "cat", path], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        if proc.returncode != 0:
            sys.exit("c11-release-timing: could not read %s:%s (%s)" % (args.ssh, path, proc.stderr.strip()))
        return proc.stdout.splitlines()
    path = args.log or os.path.join(os.path.expanduser("~"), DEFAULT_LOG)
    if not os.path.isfile(path):
        sys.exit("c11-release-timing: no log at %s (releases run on the build host: try --ssh <build host>)" % path)
    with open(path, encoding="utf-8") as handle:
        return handle.read().splitlines()


def seconds(value):
    if value is None:
        return "-"
    return "%.0f" % value if value >= 100 else "%.1f" % value


def main():
    parser = argparse.ArgumentParser(description="Print the c11 release timing log.")
    parser.add_argument("-n", "--count", type=int, default=10, help="newest runs to show, 0 for all (default 10)")
    parser.add_argument("--log", help="the log (default ~/%s)" % DEFAULT_LOG)
    parser.add_argument("--ssh", metavar="HOST", help="read the log on HOST over ssh")
    parser.add_argument("--json", action="store_true", help="print the raw records")
    args = parser.parse_args()

    records = []
    for line in read_lines(args):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            records.append(record)
    if args.count > 0:
        records = records[-args.count:]
    if args.json:
        for record in records:
            print(json.dumps(record))
        return

    steps = RELEASE_STEPS + PUBLISH_STEPS
    header = ["started", "script", "mode", "release", "result", "total"] + steps + ["failed"]
    rows = []
    for r in records:
        when = datetime.datetime.fromtimestamp(r.get("started_epoch", 0)).strftime("%b %d %I:%M %p")
        script = "publish" if r.get("script") == "c11-friend-publish" else "release"
        mode = r.get("mode", "")
        if r.get("notarize"):
            mode += "+notarize"
        if r.get("dry"):
            mode += " (dry)"
        release = r.get("c11_version") or r.get("commit") or "-"
        build = r.get("steps", {}).get("build")
        cells = [when, script, mode, release, r.get("result", ""), seconds(r.get("total_s"))]
        for name in steps:
            value = r.get("steps", {}).get(name)
            text = seconds(value)
            if name == "build" and build is not None and "atlas_compile_s" in r:
                text += " (%s+%s)" % (seconds(r.get("atlas_slot_wait_s", 0)), seconds(r["atlas_compile_s"]))
            cells.append(text)
        cells.append(r.get("failed_step") or "")
        rows.append(cells)
    widths = [max(len(str(row[i])) for row in [header] + rows) for i in range(len(header))]
    numeric = set(range(5, len(header) - 1))
    for row in [header] + rows:
        print("  ".join(str(cell).rjust(widths[i]) if i in numeric else str(cell).ljust(widths[i])
                        for i, cell in enumerate(row)).rstrip())
    if not rows:
        print("(no runs recorded yet)")
    print("seconds; build shows (slot wait + build-host compile) when the build host recorded them")


if __name__ == "__main__":
    main()
