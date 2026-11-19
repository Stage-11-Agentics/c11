#!/usr/bin/env python3
"""Exercise real process admission/nested locks with tiny fixture commands."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/atlas_build_slots.py"
# Older requesters still ship this one-lane copy to the build host with every build.
ONE_LANE_SCRIPT = ROOT / "tests/fixtures/atlas_build_slots_one_lane.py"


class SlotsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.stats = self.base / "admission.jsonl"
        self.env = dict(os.environ, C11_ATLAS_SLOTS_DIR=str(self.base / "slots"),
                        C11_ATLAS_SLOT_POLL_SECONDS="0.02", C11_BUILD_LOCK_TIMEOUT="3",
                        C11_ATLAS_ADMISSION_LOG=str(self.stats))
        self.env.pop("C11_BUILD_LOCK", None)
        self.load = self.base / "load"
        self.load.write_text("0")
        self.env["C11_ATLAS_LOAD_FILE"] = str(self.load)
        self.log = self.base / "events"
        self.command = [sys.executable, "-c", "import os,time,json; "
                        f"p={str(self.log)!r}; s=os.environ.get('C11_ATLAS_BUILD_SLOT'); "
                        "f=open(p,'a'); f.write(json.dumps({'edge':'start','slot':s,'pid':os.getpid(),"
                        "'wait':os.environ.get('C11_ATLAS_SLOT_WAIT_SECONDS'),'time':time.time()})+'\\n'); f.flush(); "
                        "time.sleep(float(os.environ.get('C11_TEST_BUILD_SECONDS','.25'))); "
                        "f.write(json.dumps({'edge':'end','slot':s,'time':time.time()})+'\\n'); f.close()"]

    def start(self, tag, poller=False, nested=False, script=SCRIPT, seconds=".25"):
        command = self.command
        if nested:
            command = [str(ROOT / "scripts/with-build-lock.sh"), *command]
        admission = [sys.executable, str(script), tag]
        if poller:
            admission.append("--poller")
        return subprocess.Popen([*admission, str(ROOT / "scripts/with-build-lock.sh"), *command],
                                env=dict(self.env, C11_TEST_BUILD_SECONDS=seconds),
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def events(self):
        if not self.log.exists():
            return []
        return sorted([json.loads(x) for x in self.log.read_text().splitlines()], key=lambda x: x["time"])

    def starts(self):
        return [event for event in self.events() if event["edge"] == "start"]

    def wait_for_starts(self, count):
        deadline = time.monotonic() + 3
        while len(self.starts()) < count and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(len(self.starts()), count, "builds did not start in time")

    def finish(self, processes, fleet_only=False):
        for p in processes:
            _, error = p.communicate(timeout=10)
            self.assertEqual(p.returncode, 0, error.decode())
        active = peak = 0
        for event in self.events():
            if fleet_only and event["slot"] == "1":
                continue
            active += 1 if event["edge"] == "start" else -1
            peak = max(peak, active)
        return peak

    def test_three_fleet_lanes_and_a_fourth_waits(self):
        processes = [self.start("poller", poller=True)]
        processes += [self.start("owner-" + name) for name in "abcd"]
        self.assertEqual(self.finish(processes, fleet_only=True), 3)
        self.assertEqual(self.finish([]), 4)
        starts = self.starts()
        self.assertEqual(sorted(event["slot"] for event in starts[:4]), ["1", "3", "4", "5"])
        self.assertNotIn("2", [event["slot"] for event in starts], "slot 2 is the older copies' lane")
        self.assertGreater(max(float(event["wait"]) for event in starts), 0.1, "the fourth fleet build waited")

    def test_same_tag_serializes_with_free_lanes(self):
        self.assertEqual(self.finish([self.start("same"), self.start("same")]), 1)

    def test_every_build_appends_one_statistics_row(self):
        self.load.write_text("7.5")
        before = time.time()
        self.finish([self.start("owner")])
        rows = [json.loads(line) for line in self.stats.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual((row["tag"], row["role"], row["slot"], row["exit_code"]), ("owner", "fleet", 3, 0))
        self.assertEqual((row["load_at_admission"], row["load_at_finish"]), (7.5, 7.5))
        for edge in ("queued", "admitted", "finished"):
            self.assertIsNotNone(datetime.fromisoformat(row[edge]["local"]).utcoffset())
            self.assertGreaterEqual(row[edge]["epoch"], before - 1)
        self.assertLessEqual(row["queued"]["epoch"], row["admitted"]["epoch"])
        self.assertGreaterEqual(row["build_seconds"], 0.25)
        self.assertGreaterEqual(row["wait_seconds"], 0.0)

    def test_busy_statistics_log_skips_the_row_instead_of_holding_the_slot(self):
        with self.stats.open("a") as log:
            fcntl.flock(log, fcntl.LOCK_EX)
            started = time.monotonic()
            process = self.start("owner")
            _, error = process.communicate(timeout=5)
            elapsed = time.monotonic() - started
        self.assertEqual(process.returncode, 0, error.decode())
        self.assertIn(b"skipped one row", error)
        self.assertLess(elapsed, 2.5)
        self.assertEqual(self.stats.read_text(), "")

    def test_one_lane_build_on_slot_two_counts_toward_three(self):
        old = self.start("old-a", script=ONE_LANE_SCRIPT, seconds="1")
        self.wait_for_starts(1)
        current = [self.start("owner-a", seconds="1"), self.start("owner-b", seconds="1")]
        self.wait_for_starts(3)
        third = self.start("owner-c")
        self.assertEqual(self.finish([old, *current, third]), 3)
        starts = self.starts()
        self.assertEqual([starts[0]["slot"], *sorted(event["slot"] for event in starts[1:3])], ["2", "3", "4"])
        first_end = min(event["time"] for event in self.events() if event["edge"] == "end")
        self.assertIn(starts[3]["slot"], ("3", "4", "5"))
        self.assertGreaterEqual(starts[3]["time"], first_end, "the third current build waited for a finish")

    def test_one_lane_waiter_gets_slot_two_while_current_builds_keep_arriving(self):
        old = self.start("old-a", script=ONE_LANE_SCRIPT, seconds=".5")
        self.wait_for_starts(1)
        current = [self.start("owner-" + name, seconds="1.5") for name in "abc"]
        self.wait_for_starts(3)
        late = [self.start("owner-d"), self.start("old-b", script=ONE_LANE_SCRIPT)]
        self.finish([old, *current, *late])
        starts = self.starts()
        old_b = [event for event in starts[1:] if event["slot"] == "2"]
        self.assertEqual(len(old_b), 1, "current copies never take slot 2")
        first_current_end = min(e["time"] for e in self.events() if e["edge"] == "end" and e["slot"] != "2")
        self.assertLess(old_b[0]["time"], first_current_end, "the older waiter was not starved")

    def test_cancelled_build_writes_one_statistics_row(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name):
                self.stats.unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                process = self.start("cancel-" + signum.name.lower(), seconds="5")
                self.wait_for_starts(1)
                child = self.starts()[0]["pid"]
                try:
                    process.send_signal(signum)
                    # wait(), not communicate(): the orphaned fake build still holds stderr.
                    process.wait(timeout=5)
                    process.stderr.close()
                    self.assertEqual(process.returncode, -signum)
                    rows = [json.loads(line) for line in self.stats.read_text().splitlines()]
                    self.assertEqual(len(rows), 1)
                    self.assertEqual((rows[0]["signal"], rows[0]["exit_code"], rows[0]["slot"]),
                                     (signum.name, -signum, 3))
                    if signum == signal.SIGTERM:
                        # As before: the surviving build keeps its inherited slot lock.
                        with (Path(self.env["C11_ATLAS_SLOTS_DIR"]) / "slot-3.lock").open("a+") as lock:
                            with self.assertRaises(BlockingIOError):
                                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_one_lane_poller_at_high_load_does_not_wait_for_current_lanes(self):
        # Accepted mixed-version behavior: the older poller guards only slots 1 and 2.
        current = self.start("owner", seconds="1")
        self.wait_for_starts(1)
        self.load.write_text("45")
        self.env["C11_ATLAS_HIGH_LOAD_SECONDS"] = "0"
        old = self.start("poller", poller=True, script=ONE_LANE_SCRIPT)
        self.assertEqual(self.finish([current, old]), 2)
        self.assertEqual([event["slot"] for event in self.starts()], ["3", "1"])

    def test_nested_lock_does_not_deadlock(self):
        self.assertEqual(self.finish([self.start("nested", nested=True)]), 1)

    def test_slot_wait_seconds_are_forwarded_to_the_build(self):
        root = Path(self.env["C11_ATLAS_SLOTS_DIR"])
        root.mkdir()
        held = []
        for number in (3, 4, 5):
            lock = (root / ("slot-%d.lock" % number)).open("a+")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held.append(lock)
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "wait",
             str(ROOT / "scripts/with-build-lock.sh"), *self.command],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertIn(b"[atlas-slots] waiting", process.stdout.readline())
        finally:
            for lock in held:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock.close()
        self.finish([process])
        event = json.loads(self.log.read_text().splitlines()[0])
        self.assertGreater(float(event["wait"]), 0.0)

    def local_lock_processes(self):
        env = dict(self.env, C11_BUILD_LOCK_DIR=str(self.base / "local-lock"))
        env.pop("C11_ATLAS_BUILD_SLOT", None)
        env.pop("C11_ATLAS_LOCK_OWNER", None)
        return [subprocess.Popen([str(ROOT / "scripts/with-build-lock.sh"), *self.command], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for _ in range(2)]

    def test_default_local_lock_remains_single_slot(self):
        self.assertEqual(self.finish(self.local_lock_processes()), 1)

    def test_local_lock_fails_promptly_when_python_is_broken(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        shim = bin_dir / "python3"
        shim.write_text("#!/bin/sh\nexit 1\n")
        shim.chmod(0o755)
        env = dict(self.env, PATH=str(bin_dir) + os.pathsep + self.env["PATH"],
                   C11_BUILD_LOCK_DIR=str(self.base / "broken-python-lock"),
                   C11_BUILD_LOCK_TIMEOUT="30")
        result = subprocess.run([str(ROOT / "scripts/with-build-lock.sh"), *self.command],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("python3", result.stderr)
        self.assertIn("atomic directory acquisition", result.stderr)
        self.assertFalse(self.log.exists(), "broken lock dependency must not run the protected command")

    def test_local_lock_rejects_a_second_creator_when_mkdir_reports_success(self):
        # Model the observed utility behavior: both creators return success.
        # The lock must use the atomic filesystem result, not this utility.
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        shim = bin_dir / "mkdir"
        shim.write_text(f"#!{sys.executable}\nimport os, sys\nos.makedirs(sys.argv[1], exist_ok=True)\n")
        shim.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.assertEqual(self.finish(self.local_lock_processes()), 1)


GIB = 1024 ** 3


class TagFloorTests(unittest.TestCase):
    """The new-tag floor on a fake home tree and a fake free-space reading; no real disk is read."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.builds = self.home / "c11-builds"
        self.derived = self.home / "Library/Developer/Xcode/DerivedData"
        self.builds.mkdir(parents=True)
        self.derived.mkdir(parents=True)
        self.free = Path(self.tmp.name) / "free"
        self.log = self.builds / "admission.jsonl"
        self.slots = Path(self.tmp.name) / "slots"
        self.slots.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), C11_ATLAS_FREE_BYTES_FILE=str(self.free),
                        C11_ATLAS_SLOTS_DIR=str(self.slots))
        self.env.pop("C11_ATLAS_ADMISSION_LOG", None)

    def tag(self, name, kib=0, derived_kib=0, release=False, admitted=None, born=None):
        folder = self.builds / name
        (folder / "source").mkdir(parents=True)
        (folder / "source" / "blob").write_bytes(b"x" * kib * 1024)
        if release:
            (folder / "derived-release").mkdir()
        # A tag folder is born days ago unless a test says otherwise; on APFS an earlier time
        # moves the birth time back.
        born = time.time() - 3 * 86400 if born is None else born
        os.utime(folder, (born, born))
        if derived_kib:
            (self.derived / ("c11-" + name)).mkdir()
            (self.derived / ("c11-" + name) / "blob").write_bytes(b"x" * derived_kib * 1024)
        if admitted is not None:
            row = {"tag": name, "role": "fleet", "slot": 3,
                   "admitted": {"epoch": admitted, "local": datetime.fromtimestamp(admitted).astimezone().isoformat()}}
            with self.log.open("a") as log:
                log.write(json.dumps(row) + "\n")

    def floor(self, slug, free_gib, *extra):
        self.free.write_text(str(free_gib * GIB))
        return subprocess.run([sys.executable, str(SCRIPT), "--tag-floor", slug, *extra],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def rows(self):
        if not self.log.exists():
            return []
        return [row for row in map(json.loads, self.log.read_text().splitlines()) if row.get("reason")]

    def test_a_new_tag_under_floor_plus_margin_is_refused_with_its_candidates(self):
        self.tag("c11-orch4", kib=2048, derived_kib=1024, admitted=time.time() - 7200)
        self.tag("c11-orch9", kib=1024, admitted=time.time() - 60)
        self.tag("c11-orch2", admitted=time.time() - 99999)
        # c11-orch2 is building now: its admission lock is held, as a running build holds it.
        building = (self.slots / "tag-c11-orch2.lock").open("a+")
        self.addCleanup(building.close)
        fcntl.flock(building, fcntl.LOCK_EX)
        (self.slots / "tag-c11-orch9.lock").touch()  # a free lock: not building
        self.tag("stale-seat")  # a folder no admission row names
        (self.derived / "c11-dd-only").mkdir()  # an app DerivedData with no build folder
        # Never candidates, however old: the gate tag, the release cache, a release-mode
        # cache, the mirrors, a lane's slug and the goldens.
        for name in ("c11-captain", "c11h-b", "mirrors", "fu-371r", "c11-host-tests", "c11-sandbox-golden-b",
                     "c11h-sandbox-golden"):
            self.tag(name, admitted=time.time() - 99999)
        self.tag("rel-cut", release=True)
        (self.derived / "remote-release-local-rel").mkdir()
        self.tag("local-rel")
        result = self.floor("c11-new", 39.5)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("39.5 GiB free", result.stderr)
        self.assertIn("under the 40 GiB a new tag needs (floor 30 + margin 10)", result.stderr)
        listed = [line.split()[0] for line in result.stderr.splitlines() if line.startswith("  ")]
        # Never-admitted first, then oldest admission first, and a tag building now last.
        self.assertEqual(listed, ["dd-only", "stale-seat", "c11-orch4", "c11-orch9", "c11-orch2"])
        self.assertIn("building now", next(line for line in result.stderr.splitlines() if line.startswith("  c11-orch2")))
        self.assertNotIn("building now", next(line for line in result.stderr.splitlines() if line.startswith("  c11-orch9")))
        self.assertFalse((self.slots / "tag-c11-orch4.lock").exists(), "the check creates no lock file")
        orch4 = next(line for line in result.stderr.splitlines() if line.startswith("  c11-orch4"))
        self.assertIn("0.0 GiB", orch4)
        self.assertIn("last admitted ", orch4)
        self.assertIn("reuse an existing tag", result.stderr)
        self.assertFalse((self.builds / "c11-new").exists(), "a refusal creates no tag folder")
        [row] = self.rows()
        self.assertEqual(row["tag"], "c11-new")
        self.assertEqual(row["reason"], "tag_floor")
        self.assertEqual((row["exit_code"], row["wait_seconds"], row["slot"]), (73, 0.0, None))
        self.assertEqual((row["free_gib"], row["threshold_gib"], row["floor_gib"], row["margin_gib"]),
                         (39.5, 40.0, 30.0, 10.0))
        self.assertFalse(row["floor_override"])
        self.assertEqual([c["tag"] for c in row["candidates"]], listed)
        sizes = {c["tag"]: c["gib"] for c in row["candidates"]}
        # Its build folder (2 MiB) and its app DerivedData (1 MiB) are both counted.
        self.assertEqual((sizes["c11-orch4"], sizes["c11-orch9"]), (0.003, 0.001))
        self.assertIsNone(row["candidates"][0]["last_admitted"])
        self.assertIsNotNone(row["candidates"][2]["last_admitted"])
        self.assertEqual([c["building"] for c in row["candidates"]], [False, False, False, False, True])
        self.assertGreaterEqual(row["check_seconds"], 0)

    def test_a_warm_tag_builds_under_the_floor(self):
        self.tag("c11-orch12")
        link_target = self.home / "elsewhere/c11h-t12"
        link_target.mkdir(parents=True)
        (self.builds / "c11h-t12").symlink_to(link_target)  # a tag folder kept on another path
        for slug in ("c11-orch12", "c11h-t12"):
            result = self.floor(slug, 1)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows(), [])

    def test_a_new_tag_at_or_over_the_threshold_builds(self):
        for free in (40, 41):
            result = self.floor("c11-new", free)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows(), [])
        self.assertFalse((self.builds / "c11-new").exists(), "the check itself creates nothing")

    def test_the_floor_override_replaces_the_floor_and_is_recorded(self):
        result = self.floor("c11-new", 10, "--floor-gib", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.floor("c11-new", 500, "--floor-gib", "100000")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("floor 100000 overridden + margin 10", result.stderr)
        [row] = self.rows()
        self.assertEqual((row["floor_gib"], row["threshold_gib"], row["floor_override"]), (100000.0, 100010.0, True))

    def hold(self, slug):
        """Hold a tag's admission lock, as a running build does; released at cleanup or by close()."""
        lock = (self.slots / ("tag-" + slug + ".lock")).open("a+")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)
        return lock

    def test_new_tags_whose_first_build_holds_its_lock_each_hold_a_margin(self):
        now = time.time()
        self.tag("c11-a", born=now)  # new, its first build running now
        first = self.hold("c11-a")
        self.tag("c11-b", born=now - 600, admitted=now - 60)  # new, a later build running now
        self.hold("c11-b")
        self.tag("c11-c", born=now - 3 * 3600)  # building, but born too long ago
        self.hold("c11-c")
        self.tag("c11-d", born=now - 600, admitted=now - 5000)  # pruned, recreated, first build running
        self.hold("c11-d")
        self.tag("c11-e", born=now)  # new, but nothing holds its lock: staging, or a first attempt that died
        # A new tag whose first build ran to completion under an older copy, which writes no row.
        self.tag("legacy-seat", born=now)
        load = Path(self.tmp.name) / "load"
        load.write_text("0")
        legacy = subprocess.run([sys.executable, str(ONE_LANE_SCRIPT), "legacy-seat", "true"],
                                env=dict(self.env, C11_ATLAS_LOAD_FILE=str(load)), capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertTrue((self.slots / "tag-legacy-seat.lock").exists(), "the older copy took the tag lock")
        result = self.floor("c11-new", 59.9)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("under the 60 GiB a new tag needs (floor 30 + margin 10, plus 10 for each new tag "
                      "on its first build now: c11-a, c11-d)", result.stderr)
        [row] = self.rows()
        self.assertEqual((row["pending_new_tags"], row["threshold_gib"]), (["c11-a", "c11-d"], 60.0))
        self.assertEqual(self.floor("c11-new", 60).returncode, 0)
        first.close()  # c11-a's first build ends: its reservation goes with its lock
        self.assertEqual(self.floor("c11-new", 50).returncode, 0, "only c11-d still holds a margin")

    def test_an_unreadable_free_space_reading_admits_with_a_warning(self):
        self.free.write_text("not a number")
        result = subprocess.run([sys.executable, str(SCRIPT), "--tag-floor", "c11-new"], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not read the build host's free space; admitting new tag c11-new", result.stderr)
        self.assertEqual(self.rows(), [])
        self.assertFalse((self.builds / "c11-new").exists())

    def test_sizing_is_bounded_and_a_stalled_size_reads_unknown(self):
        self.tag("c11-orch4", admitted=time.time() - 7200)
        self.tag("c11-orch9", derived_kib=4)
        fake = Path(self.tmp.name) / "bin"
        fake.mkdir()
        pids = Path(self.tmp.name) / "du-pids"
        (fake / "du").write_text("#!/bin/sh\necho $$ >>\"$DU_PIDS\"\nexec sleep 30\n")
        (fake / "du").chmod(0o755)
        self.free.write_text(str(5 * GIB))
        started = time.monotonic()
        result = subprocess.run([sys.executable, str(SCRIPT), "--tag-floor", "c11-new"],
                                env=dict(self.env, PATH=str(fake) + os.pathsep + self.env["PATH"],
                                         C11_ATLAS_SIZE_SECONDS="0.5", DU_PIDS=str(pids)),
                                capture_output=True, text=True, timeout=20)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertLess(elapsed, 3, "the refusal waits at most the sizing bound")
        listed = [line for line in result.stderr.splitlines() if line.startswith("  ")]
        self.assertEqual(len(listed), 2, result.stderr)
        self.assertTrue(all("size unknown" in line for line in listed), listed)
        self.assertEqual([c["gib"] for c in self.rows()[0]["candidates"]], [None, None])
        recorded = pids.read_text().split()
        self.assertEqual(len(recorded), 3, "one du per folder: two build folders and one DerivedData")
        alive = subprocess.run(["ps", "-o", "pid=", "-p", ",".join(recorded)], capture_output=True, text=True)
        self.assertEqual(alive.stdout.strip(), "", "every stalled du is gone with the refusal")

    def test_tiny_candidates_sink_below_the_rest(self):
        self.tag("c11-big", kib=200 * 1024, admitted=time.time() - 60)
        self.tag("c11-tiny", admitted=time.time() - 99999)
        self.tag("c11-busy", kib=200 * 1024, admitted=time.time() - 99999)
        self.hold("c11-busy")
        result = self.floor("c11-new", 5)
        listed = [line.split()[0] for line in result.stderr.splitlines() if line.startswith("  ")]
        self.assertEqual(listed, ["c11-big", "c11-tiny", "c11-busy"])

    def test_no_candidates_says_so(self):
        self.tag("c11-captain")
        result = self.floor("c11-new", 5)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("no tag here can be offered for pruning", result.stderr)
        self.assertEqual(self.rows()[0]["candidates"], [])

    def test_bad_arguments_are_refused(self):
        for extra in (["--floor-gib", "-1"], ["--floor-gib", "nan"], ["--floor-gib", "x"], ["--other", "1"]):
            result = self.floor("c11-new", 100, *extra)
            self.assertNotIn(result.returncode, (0, 73), (extra, result.stderr))
        self.assertNotIn(self.floor("Bad/Slug", 100).returncode, (0, 73))


if __name__ == "__main__":
    unittest.main()
