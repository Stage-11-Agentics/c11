#!/usr/bin/env python3
"""Exercise real process admission/nested locks with tiny fixture commands."""
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
        self.load = self.base / "load"
        self.load.write_text("0")
        self.env["C11_ATLAS_LOAD_FILE"] = str(self.load)
        self.log = self.base / "events"
        self.command = [sys.executable, "-c", "import os,time,json; "
                        f"p={str(self.log)!r}; "
                        "f=open(p,'a'); f.write(json.dumps({'edge':'start','slot':os.environ.get('C11_ATLAS_BUILD_SLOT'),"
                        "'time':time.time()})+'\\n'); f.flush(); time.sleep(.25); "
                        "f.write(json.dumps({'edge':'end','time':time.time()})+'\\n'); f.close()"]

    def start(self, tag, nested=False):
        command = self.command
        if nested:
            command = [str(ROOT / "scripts/with-build-lock.sh"), *command]
        return subprocess.Popen([sys.executable, str(ROOT / "scripts/atlas_build_slots.py"), tag,
                                 str(ROOT / "scripts/with-build-lock.sh"), *command], env=self.env,
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
        self.assertEqual(self.finish([self.start(t) for t in ("a", "b", "c")]), 2)

    def test_same_tag_serializes_even_with_two_slots(self):
        self.assertEqual(self.finish([self.start("same"), self.start("same")]), 1)

    def test_sustained_high_load_one_slot_then_recovers(self):
        self.load.write_text("45")
        self.env["C11_ATLAS_HIGH_LOAD_SECONDS"] = "0"
        self.assertEqual(self.finish([self.start("a"), self.start("b")]), 1)
        self.log.unlink()
        self.load.write_text("20")
        self.assertEqual(self.finish([self.start("a"), self.start("b")]), 2)

    def test_nested_lock_does_not_deadlock(self):
        self.assertEqual(self.finish([self.start("nested", nested=True)]), 1)

    def test_default_local_lock_remains_single_slot(self):
        env = dict(self.env, C11_BUILD_LOCK_DIR=str(self.base / "local-lock"))
        env.pop("C11_ATLAS_BUILD_SLOT", None)
        env.pop("C11_ATLAS_LOCK_OWNER", None)
        processes = [subprocess.Popen([str(ROOT / "scripts/with-build-lock.sh"), *self.command], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for _ in range(2)]
        self.assertEqual(self.finish(processes), 1)


if __name__ == "__main__":
    unittest.main()
