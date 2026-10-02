#!/usr/bin/env python3
"""Atlas-only two-slot admission; ordinary with-build-lock.sh stays single-slot."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def try_lock(file):
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def capacity(root):
    # The short gate serializes the shared load history, never a build.
    with (root / "admission.lock").open("a+") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        state_path = root / "load.json"
        try:
            state = json.loads(state_path.read_text())
        except (FileNotFoundError, ValueError):
            state = {}
        load = os.getloadavg()[0]
        # A file override makes the load policy executable in hermetic fixtures.
        if os.environ.get("C11_ATLAS_LOAD_FILE"):
            load = float(Path(os.environ["C11_ATLAS_LOAD_FILE"]).read_text())
        now = time.time()
        threshold = float(os.environ.get("C11_ATLAS_LOAD_LIMIT", "40"))
        duration = float(os.environ.get("C11_ATLAS_HIGH_LOAD_SECONDS", "60"))
        high_since = state.get("high_since", now) if load > threshold else None
        state_path.write_text(json.dumps({"high_since": high_since}) + "\n")
        return 1 if high_since is not None and now - high_since >= duration else 2


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: atlas_build_slots.py <tag-slug> <command> [args...]")
    root = Path(os.environ.get("C11_ATLAS_SLOTS_DIR", "/tmp/c11-atlas-build-slots"))
    root.mkdir(parents=True, exist_ok=True)
    slug = sys.argv[1]
    if not slug or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in slug):
        sys.exit("invalid Atlas build slug")
    timeout = float(os.environ.get("C11_BUILD_LOCK_TIMEOUT", "5400"))
    poll = float(os.environ.get("C11_ATLAS_SLOT_POLL_SECONDS", "2"))
    started = time.monotonic()
    last_report = -30.0
    with (root / ("tag-" + slug + ".lock")).open("a+") as tag:
        slots = [(root / ("slot-" + str(n) + ".lock")).open("a+") for n in (1, 2)]
        try:
            tag_owned = False
            while True:
                if not tag_owned:
                    tag_owned = try_lock(tag)
                limit = capacity(root)
                if tag_owned:
                    for n, slot in enumerate(slots[:limit], 1):
                        if try_lock(slot):
                            env = os.environ.copy()
                            env.pop("C11_BUILD_LOCK", None)
                            env.pop("C11_ATLAS_LOCK_OWNER", None)
                            env["C11_ATLAS_BUILD_SLOT"] = str(n)
                            env["C11_BUILD_LOCK_DIR"] = str(root / ("build-" + str(n)))
                            print(f"[atlas-slots] acquired slot={n} capacity={limit} tag={slug}", flush=True)
                            return subprocess.call(sys.argv[2:], env=env,
                                                   pass_fds=(tag.fileno(), slot.fileno()))
                waited = time.monotonic() - started
                if waited >= timeout:
                    print("[atlas-slots] admission timed out", file=sys.stderr)
                    return 75
                if waited - last_report >= 30:
                    print(f"[atlas-slots] waiting tag={slug} capacity={limit} elapsed={waited:.0f}s", flush=True)
                    last_report = waited
                time.sleep(poll)
        finally:
            for slot in slots:
                slot.close()


if __name__ == "__main__":
    sys.exit(main())
