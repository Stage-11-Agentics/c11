#!/usr/bin/env python3
"""Exercise real process admission/nested locks with tiny fixture commands."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SlotsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, C11_ATLAS_SLOTS_DIR=str(self.base / "slots"),
                        C11_ATLAS_SLOT_POLL_SECONDS="0.02", C11_BUILD_LOCK_TIMEOUT="3")
        self.env.pop("C11_BUILD_LOCK", None)
        self.load = self.base / "load"
        self.load.write_text("0")
        self.env["C11_ATLAS_LOAD_FILE"] = str(self.load)
        self.log = self.base / "events"
        self.command = [sys.executable, "-c", "import os,time,json; "
                        f"p={str(self.log)!r}; "
                        "f=open(p,'a'); f.write(json.dumps({'edge':'start','slot':os.environ.get('C11_ATLAS_BUILD_SLOT'),"
                        "'wait':os.environ.get('C11_ATLAS_SLOT_WAIT_SECONDS'),'time':time.time()})+'\\n'); f.flush(); "
                        "time.sleep(float(os.environ.get('C11_TEST_BUILD_SECONDS','.25'))); "
                        "f.write(json.dumps({'edge':'end','time':time.time()})+'\\n'); f.close()"]

    def start(self, tag, poller=False, nested=False):
        command = self.command
        if nested:
            command = [str(ROOT / "scripts/with-build-lock.sh"), *command]
        admission = [sys.executable, str(ROOT / "scripts/atlas_build_slots.py"), tag]
        if poller:
            admission.append("--poller")
        return subprocess.Popen([*admission, str(ROOT / "scripts/with-build-lock.sh"), *command], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def finish(self, processes):
        for p in processes:
            _, error = p.communicate(timeout=10)
            self.assertEqual(p.returncode, 0, error.decode())
        active = peak = 0
        for event in sorted([json.loads(x) for x in self.log.read_text().splitlines()], key=lambda x: x["time"]):
            active += 1 if event["edge"] == "start" else -1
            peak = max(peak, active)
        return peak

    def test_two_slots_and_third_waits(self):
        self.assertEqual(self.finish([
            self.start("poller", poller=True), self.start("owner-a"), self.start("owner-b"),
        ]), 2)
        starts = [json.loads(line) for line in self.log.read_text().splitlines() if '"edge": "start"' in line]
        self.assertEqual(sorted(event["slot"] for event in starts), ["1", "2", "2"])

    def test_same_tag_serializes_even_with_two_slots(self):
        self.assertEqual(self.finish([self.start("same", poller=True), self.start("same")]), 1)

    def test_sustained_high_load_allows_fleet_when_poller_slot_is_idle(self):
        self.load.write_text("45")
        self.env["C11_ATLAS_HIGH_LOAD_SECONDS"] = "0"
        owner = self.start("owner")
        self.assertEqual(self.finish([owner]), 1)
        starts = [json.loads(line) for line in self.log.read_text().splitlines() if '"edge": "start"' in line]
        self.assertEqual([event["slot"] for event in starts], ["2"])

    def test_sustained_high_load_serializes_fleet_against_poller(self):
        self.load.write_text("45")
        self.env["C11_ATLAS_HIGH_LOAD_SECONDS"] = "0"
        poller = self.start("poller", poller=True)
        deadline = time.monotonic() + 2
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.log.exists(), "poller should acquire slot 1 before starting the owner")
        owner = self.start("owner")
        self.assertEqual(self.finish([poller, owner]), 1)
        events = sorted([json.loads(line) for line in self.log.read_text().splitlines()], key=lambda x: x["time"])
        starts = [event for event in events if event["edge"] == "start"]
        self.assertEqual(sorted(event["slot"] for event in starts), ["1", "2"])
        self.assertEqual([event["edge"] for event in events], ["start", "end", "start", "end"])

    def test_sustained_high_load_poller_waits_for_fleet_already_on_slot_two(self):
        self.env["C11_TEST_BUILD_SECONDS"] = "1.5"
        owner = self.start("owner")
        deadline = time.monotonic() + 2
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(self.log.exists(), "fleet build should acquire slot 2 before load rises")
        self.load.write_text("45")
        self.env["C11_ATLAS_HIGH_LOAD_SECONDS"] = "0"
        self.env["C11_TEST_BUILD_SECONDS"] = ".25"
        poller = self.start("poller", poller=True)
        self.assertEqual(self.finish([owner, poller]), 1)
        events = sorted([json.loads(line) for line in self.log.read_text().splitlines()], key=lambda x: x["time"])
        starts = [event for event in events if event["edge"] == "start"]
        self.assertEqual([event["slot"] for event in starts], ["2", "1"])
        self.assertGreaterEqual(float(starts[1]["wait"]), 0.5)
        self.assertEqual([event["edge"] for event in events], ["start", "end", "start", "end"])

    def test_nested_lock_does_not_deadlock(self):
        self.assertEqual(self.finish([self.start("nested", nested=True)]), 1)

    def test_slot_wait_seconds_are_forwarded_to_the_build(self):
        root = Path(self.env["C11_ATLAS_SLOTS_DIR"])
        root.mkdir()
        held = []
        for number in (1, 2):
            lock = (root / ("slot-%d.lock" % number)).open("a+")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held.append(lock)
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts/atlas_build_slots.py"), "wait",
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


if __name__ == "__main__":
    unittest.main()
