#!/usr/bin/env python3
"""Atlas-only admission: slot 1 for the poller, three fleet lanes on slots 3-5.

Ordinary with-build-lock.sh stays single-slot. Every remote build ships its own
copy of this script, so older copies run beside this one on the same lock
files: slot 2 is their only fleet lane, and under sustained load above 40 they
also take slot 1 (fleet) or slot 2 (poller) as a guard. This copy never takes
slot 2, so it cannot starve them. It has no load gate; it records the load in
one statistics row per admitted build instead.

`atlas_build_slots.py --tag-floor <slug> [--floor-gib N]` is the free-space
floor (C11H-368). remote_build.py runs it on the build host before it copies
anything for a build. A tag with no build folder yet costs about 10 GiB, so it
is refused (exit 73, one admission row) while free space is under the floor
plus the margin. The refusal names the tags that could be pruned. A tag that
already has its folder always builds, and nothing is ever deleted here.
"""
from datetime import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

FLEET_SLOTS = (3, 4, 5)  # Slot 2 belongs to older copies of this script.
LEGACY_FLEET_SLOT = 2
FLEET_CAP = 3  # Fleet builds at once across slots 2-5, older copies included.
STATS_LOCK_SECONDS = 1.0

# The free-space floor. A new tag needs FLOOR_GIB + MARGIN_GIB free; the requester's
# C11_BUILD_HOST_FLOOR_GIB (logged by remote_build.py) replaces FLOOR_GIB for one build.
FLOOR_GIB = 30.0
MARGIN_GIB = 10.0  # About one fleet tag: its build folder plus its app DerivedData.
# A tag folder born this recently, whose first build holds its admission lock now, is a new tag
# whose caches are still being written: it holds a margin too. The lock is the live signal; a
# missing admission row alone is not (an older copy, or a skipped row, may write none).
RESERVE_SECONDS = 2 * 3600
TAG_FLOOR_REFUSED = 73  # EX_CANTCREAT: the new tag's caches can't be created.
SIZE_SECONDS = 60.0  # Sizing the candidates is bounded; past it a size reads "unknown".
TINY_GIB = 0.1  # A candidate this small frees nothing worth a prune; it is listed after the rest.
GIB = 1024 ** 3
# Never offered for pruning, whatever their age. The build folder and DerivedData c11-<name>
# are what the refusal lists. The lanes' folders and the Tart goldens live outside them, but
# they are named here so a wider scan can never offer them either.
MIRRORS = "mirrors"
PROTECTED = {
    MIRRORS: "the shared git mirrors every tag stages from",
    "c11-captain": "the Merge Captain's gate tag",
    "c11h-b": "the release cache",
    "fu-371r": "the PR Swift poller's slug (scripts/c11-pr-swift-poller.py)",
    "c11-poller": "the PR Swift poller's folder",
    "astra-466": "the main backstop's slug (scripts/c11-main-backstop.py)",
    "c11-main-backstop": "the main backstop's folder",
    "c11-perf-lane": "the perf lane's slug and folder",
    "c11-host-tests": "the host-tests lane's slug and folder",
    "c11-guest-runs": "the guest lanes' folder",
}
PROTECTED_PREFIXES = {
    "c11-sandbox-golden": "the Tart goldens",
    "c11h-sandbox-golden": "the agent guest images (scripts/c11-guest-image.sh)",
}
# Also protected: any tag that holds a release-mode cache (see protected_tag).


def try_lock(file):
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def load_average():
    # A file override makes the statistics executable in hermetic fixtures.
    if os.environ.get("C11_ATLAS_LOAD_FILE"):
        try:
            return float(Path(os.environ["C11_ATLAS_LOAD_FILE"]).read_text())
        except (OSError, ValueError):
            return None
    return round(os.getloadavg()[0], 2)


def stamp(epoch):
    return {"local": datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="seconds"),
            "epoch": round(epoch, 3)}


def append_stats(row):
    """Append one admission row; measurement never changes the build result."""
    path = Path(os.environ.get("C11_ATLAS_ADMISSION_LOG",
                               Path.home() / "c11-builds" / "admission.jsonl"))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as log:
            # A stalled writer must not hold the build slot: wait briefly, then skip.
            deadline = time.monotonic() + STATS_LOCK_SECONDS
            while not try_lock(log):
                if time.monotonic() >= deadline:
                    print(f"[atlas-slots] admission stats log busy; skipped one row: {path}", file=sys.stderr)
                    return
                time.sleep(0.05)
            log.write(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n")
    except OSError as error:
        print(f"[atlas-slots] could not append admission stats: {error}", file=sys.stderr)


def take_fleet_lane(root, slots):
    """Take a free lane of 3-5 while fewer than FLEET_CAP of slots 2-5 are held.

    The gate makes count-and-take atomic among current copies. Older copies
    take slot 2 without it, so one of them can briefly make four.
    """
    with (root / "fleet-admission.lock").open("a+") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        held = 0
        with (root / ("slot-" + str(LEGACY_FLEET_SLOT) + ".lock")).open("a+") as legacy:
            for probe in (legacy, *slots.values()):
                if try_lock(probe):
                    fcntl.flock(probe.fileno(), fcntl.LOCK_UN)
                else:
                    held += 1
        if held >= FLEET_CAP:
            return None
        for n, slot in slots.items():
            if try_lock(slot):
                return n
    return None


def builds_root():
    return Path.home() / "c11-builds"


def derived_data_root():
    return Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"


def free_bytes(path):
    """Free bytes on the volume holding `path`, as df reports them; None when unreadable."""
    # A file override makes the floor executable in hermetic fixtures (no real disk is read).
    if os.environ.get("C11_ATLAS_FREE_BYTES_FILE"):
        try:
            return float(Path(os.environ["C11_ATLAS_FREE_BYTES_FILE"]).read_text())
        except (OSError, ValueError):
            return None
    try:
        info = os.statvfs(path)
    except OSError:
        return None
    return float(info.f_bavail * info.f_frsize)


def protected_tag(name, builds, derived):
    """Whether a tag is never offered for pruning (PROTECTED, PROTECTED_PREFIXES, release caches)."""
    if name in PROTECTED or any(name.startswith(prefix) for prefix in PROTECTED_PREFIXES):
        return True
    # Release mode keeps derived-release in the tag folder; the local route keeps its copy beside it.
    return (builds / name / "derived-release").exists() or (derived / ("remote-release-" + name)).exists()


def last_admissions(path):
    """The newest admission per tag in admission.jsonl, as a stamp; refused or timed-out rows don't count."""
    latest = {}
    try:
        with path.open(encoding="utf-8", errors="replace") as log:
            for line in log:
                try:
                    row = json.loads(line)
                    tag, admitted = row["tag"], row["admitted"]
                    epoch = float(admitted["epoch"])
                except (ValueError, TypeError, KeyError):
                    continue
                if isinstance(tag, str) and (tag not in latest or epoch > latest[tag]["epoch"]):
                    latest[tag] = {"epoch": epoch, "local": admitted.get("local")}
    except OSError:
        pass
    return latest


def tag_sizes(paths):
    """GiB per tag, summed over its folders by parallel `du -sk`; None when a size is unknown."""
    running = []
    for tag, folders in paths.items():
        for folder in folders:
            try:
                running.append((tag, subprocess.Popen(["du", "-sk", str(folder)], stdout=subprocess.PIPE,
                                                      stderr=subprocess.DEVNULL)))
            except OSError:
                running.append((tag, None))
    try:
        bound = float(os.environ.get("C11_ATLAS_SIZE_SECONDS", SIZE_SECONDS))
    except ValueError:
        bound = SIZE_SECONDS
    deadline = time.monotonic() + bound
    sizes = {tag: 0.0 for tag in paths}
    for tag, process in running:
        kib = None
        if process is not None:
            try:
                # A du that finished by the deadline is still read, however late its turn comes.
                out, _ = process.communicate(timeout=max(0.1, deadline - time.monotonic()))
                kib = int(out.split()[0])
            except subprocess.TimeoutExpired:
                process.kill()  # Our own du child, by its handle.
                process.communicate()
            except (ValueError, IndexError):
                pass
        if kib is None or sizes[tag] is None:
            sizes[tag] = None
        else:
            sizes[tag] += kib * 1024 / GIB
    return sizes


def slots_root():
    return Path(os.environ.get("C11_ATLAS_SLOTS_DIR", "/tmp/c11-atlas-build-slots"))


def tag_building(slug):
    """Whether a build holds this tag's admission lock now (queued on a slot or building)."""
    try:
        with (slots_root() / ("tag-" + slug + ".lock")).open("r") as lock:  # never creates one
            if not try_lock(lock):
                return True
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    return False


def new_tags_in_flight(builds, slug, log_path, now):
    """Other tags born in the last RESERVE_SECONDS whose first build holds their admission lock now."""
    recent = {}
    if builds.is_dir():
        for entry in builds.iterdir():
            if entry.name in (slug, MIRRORS):
                continue
            try:
                info = entry.stat()  # A tag folder may be a link; its target's birth counts.
            except OSError:
                continue
            born = getattr(info, "st_birthtime", info.st_ctime)
            if stat.S_ISDIR(info.st_mode) and now - born < RESERVE_SECONDS and tag_building(entry.name):
                recent[entry.name] = born
    if not recent:
        return []
    # A finished build since the folder's birth means this lock holder is a later build, not the first.
    admitted = last_admissions(log_path)  # Rows are written when a build finishes.
    return sorted(tag for tag, born in recent.items() if tag not in admitted or admitted[tag]["epoch"] < born)


def prune_candidates(builds, derived, log_path):
    """Every unprotected tag with a build folder or an app DerivedData: oldest admission first,
    tags building now last."""
    folders = {}
    if builds.is_dir():
        for entry in builds.iterdir():
            if entry.is_dir():  # A tag folder may be a link to another volume or folder.
                folders.setdefault(entry.name, []).append(entry.resolve())
    if derived.is_dir():
        for entry in derived.iterdir():
            if entry.name.startswith("c11-") and len(entry.name) > 4 and entry.is_dir():
                folders.setdefault(entry.name[4:], []).append(entry.resolve())
    folders = {tag: paths for tag, paths in folders.items() if not protected_tag(tag, builds, derived)}
    sizes = tag_sizes(folders)
    admitted = last_admissions(log_path)
    candidates = [{"tag": tag, "gib": None if sizes[tag] is None else round(sizes[tag], 3),
                   "last_admitted": admitted[tag]["local"] if tag in admitted else None,
                   "epoch": admitted[tag]["epoch"] if tag in admitted else None, "building": tag_building(tag)}
                  for tag in folders]
    # Building now last, tiny ones just before them, the rest never-admitted first, then oldest.
    candidates.sort(key=lambda c: (c["building"], c["gib"] is not None and c["gib"] < TINY_GIB,
                                   c["epoch"] is not None, c["epoch"] or 0.0, c["tag"]))
    return candidates


def describe_candidate(candidate):
    size = "size unknown" if candidate["gib"] is None else f"{candidate['gib']:.1f} GiB"
    if candidate["epoch"] is None:
        when = "never admitted"
    else:
        when = "last admitted " + datetime.fromtimestamp(candidate["epoch"]).strftime("%Y-%m-%d %H:%M")
    if candidate["building"]:
        when += ", building now"
    return f"  {candidate['tag']:<28} {size:>12}  {when}"


def tag_floor(slug, floor_gib=None):
    """Refuse a build that would create a new tag while free space is under floor + margin."""
    queued = time.time()
    started = time.monotonic()
    builds, derived = builds_root(), derived_data_root()
    if (builds / slug).is_dir():
        return 0  # A warm tag reuses its caches; it always builds.
    floor = FLOOR_GIB if floor_gib is None else floor_gib
    log_path = Path(os.environ.get("C11_ATLAS_ADMISSION_LOG", builds / "admission.jsonl"))
    try:
        pending = new_tags_in_flight(builds, slug, log_path, queued)
    except Exception as error:  # A listing problem must not stop every build; the plain floor still holds.
        print(f"[atlas-slots] could not count new tags in flight: {error}", file=sys.stderr)
        pending = []
    threshold = floor + MARGIN_GIB * (1 + len(pending))
    free = free_bytes(builds if builds.is_dir() else Path.home())
    if free is None:
        print(f"[atlas-slots] could not read the build host's free space; admitting new tag {slug} "
              "without the floor check", file=sys.stderr)
        return 0
    free_gib = free / GIB
    if free_gib >= threshold:
        return 0
    shown = math.floor(free_gib * 10) / 10  # Rounded down, so a refusal never prints the threshold.
    try:
        candidates = prune_candidates(builds, derived, log_path)
    except Exception as error:  # The refusal and its row still stand without the list.
        print(f"[atlas-slots] could not list the tags here: {error}", file=sys.stderr)
        candidates = []
    in_flight = (f", plus {MARGIN_GIB:g} for each new tag on its first build now: {', '.join(pending)}"
                 if pending else "")
    lines = [f"[atlas-slots] refused new tag {slug}: {shown:.1f} GiB free on the build host, under the "
             f"{threshold:.10g} GiB a new tag needs (floor {floor:.10g}"
             f"{' overridden' if floor_gib is not None else ''} + margin {MARGIN_GIB:g}{in_flight}). "
             "Nothing was copied or built for this tag."]
    if candidates:
        lines.append("[atlas-slots] tags here that could be pruned, oldest admission first "
                     f"(under {TINY_GIB:g} GiB, then building now, last):")
        lines.extend(describe_candidate(candidate) for candidate in candidates)
    else:
        lines.append("[atlas-slots] no tag here can be offered for pruning; every cache is protected.")
    lines.append("[atlas-slots] Prune a finished tag (both caches: its build folder and DerivedData c11-<tag>; "
                 "skills/c11-hotload/SKILL.md, Tag hygiene), or reuse an existing tag with --tag.")
    lines.append("[atlas-slots] For a deliberate new tag (a release cut), set C11_BUILD_HOST_FLOOR_GIB=<GiB> "
                 "on the requester; every use is logged.")
    print("\n".join(lines), file=sys.stderr, flush=True)
    append_stats({"tag": slug, "role": "fleet", "reason": "tag_floor", "queued": stamp(queued),
                  "finished": stamp(time.time()), "slot": None, "wait_seconds": 0.0,
                  "exit_code": TAG_FLOOR_REFUSED, "free_gib": shown, "threshold_gib": threshold,
                  "floor_gib": floor, "margin_gib": MARGIN_GIB, "floor_override": floor_gib is not None,
                  "pending_new_tags": pending,
                  "check_seconds": round(time.monotonic() - started, 3),
                  "candidates": [{k: c[k] for k in ("tag", "gib", "last_admitted", "building")}
                                 for c in candidates]})
    return TAG_FLOOR_REFUSED


def valid_slug(slug):
    return bool(slug) and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in slug)


def tag_floor_main(argv):
    usage = "usage: atlas_build_slots.py --tag-floor <tag-slug> [--floor-gib <GiB>]"
    if len(argv) not in (1, 3) or (len(argv) == 3 and argv[1] != "--floor-gib"):
        sys.exit(usage)
    if not valid_slug(argv[0]):
        sys.exit("invalid build-host build slug")
    floor = None
    if len(argv) == 3:
        try:
            floor = float(argv[2])
        except ValueError:
            floor = -1.0
        if not math.isfinite(floor) or floor < 0:
            sys.exit("--floor-gib takes a number of GiB, 0 or more")
    return tag_floor(argv[0], floor)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--tag-floor":
        return tag_floor_main(sys.argv[2:])
    if len(sys.argv) < 3:
        sys.exit("usage: atlas_build_slots.py <tag-slug> [--poller] <command> [args...]")
    root = slots_root()
    root.mkdir(parents=True, exist_ok=True)
    slug = sys.argv[1]
    poller = sys.argv[2] == "--poller"
    command_index = 3 if poller else 2
    if len(sys.argv) <= command_index:
        sys.exit("usage: atlas_build_slots.py <tag-slug> [--poller] <command> [args...]")
    if not valid_slug(slug):
        sys.exit("invalid build-host build slug")
    timeout = float(os.environ.get("C11_BUILD_LOCK_TIMEOUT", "5400"))
    poll = float(os.environ.get("C11_ATLAS_SLOT_POLL_SECONDS", "2"))
    queued = time.time()
    started = time.monotonic()
    last_report = -30.0
    row = {"tag": slug, "role": "poller" if poller else "fleet", "queued": stamp(queued)}
    with (root / ("tag-" + slug + ".lock")).open("a+") as tag:
        numbers = (1,) if poller else FLEET_SLOTS
        slots = {n: (root / ("slot-" + str(n) + ".lock")).open("a+") for n in numbers}
        try:
            tag_owned = False
            while True:
                if not tag_owned:
                    tag_owned = try_lock(tag)
                admitted = None
                if tag_owned:
                    if poller:
                        admitted = 1 if try_lock(slots[1]) else None
                    else:
                        admitted = take_fleet_lane(root, slots)
                if admitted is not None:
                    n, slot = admitted, slots[admitted]
                    waited = time.monotonic() - started
                    env = os.environ.copy()
                    env.pop("C11_BUILD_LOCK", None)
                    env.pop("C11_ATLAS_LOCK_OWNER", None)
                    env["C11_ATLAS_BUILD_SLOT"] = str(n)
                    env["C11_ATLAS_SLOT_WAIT_SECONDS"] = f"{waited:.3f}"
                    env["C11_BUILD_LOCK_DIR"] = str(root / ("build-" + str(n)))
                    if env.get("C11_ATLAS_SLOT_RECORD_PATH"):
                        try:
                            Path(env["C11_ATLAS_SLOT_RECORD_PATH"]).write_text(
                                json.dumps({"slot_wait_seconds": round(waited, 3)}) + "\n")
                        except OSError as error:
                            print(f"[atlas-slots] could not write slot timing: {error}", file=sys.stderr)
                    admitted = time.time()
                    row.update(slot=n, admitted=stamp(admitted), wait_seconds=round(waited, 3),
                               load_at_admission=load_average())
                    print(f"[atlas-slots] acquired slot={n} tag={slug}", flush=True)
                    written = []

                    def finish(code, signum=None):
                        if written:
                            return
                        written.append(True)
                        finished = time.time()
                        row.update(finished=stamp(finished), build_seconds=round(finished - admitted, 3),
                                   load_at_finish=load_average(), exit_code=code)
                        if signum is not None:
                            row["signal"] = signal.Signals(signum).name
                        append_stats(row)

                    def cancelled(signum, frame):
                        # Record the cancellation, then end exactly as the
                        # default action would: SIGINT still lets call() kill
                        # the child; SIGTERM and SIGHUP leave it and its
                        # inherited locks to finish on their own.
                        finish(-signum, signum)
                        if signum == signal.SIGINT:
                            signal.default_int_handler(signum, frame)
                        signal.signal(signum, signal.SIG_DFL)
                        os.kill(os.getpid(), signum)

                    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                        signal.signal(signum, cancelled)
                    code = subprocess.call(sys.argv[command_index:], env=env,
                                           pass_fds=(tag.fileno(), slot.fileno()))
                    finish(code)
                    return code
                waited = time.monotonic() - started
                if waited >= timeout:
                    print("[atlas-slots] admission timed out", file=sys.stderr)
                    row.update(slot=None, wait_seconds=round(waited, 3), load_at_finish=load_average(),
                               finished=stamp(time.time()), exit_code=75)
                    append_stats(row)
                    return 75
                if waited - last_report >= 30:
                    print(f"[atlas-slots] waiting tag={slug} elapsed={waited:.0f}s", flush=True)
                    last_report = waited
                time.sleep(poll)
        finally:
            for slot in slots.values():
                slot.close()


if __name__ == "__main__":
    sys.exit(main())
