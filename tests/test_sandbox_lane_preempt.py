#!/usr/bin/env python3
"""An owner's sandbox-up preempts the host-test lane within one wall-clock deadline.

Runs the real scripts/sandbox-up.sh (and, where named, the real lane's Guest.boot in its own
process) against a stand-in tart under a throwaway HOME. No VM, real tart or ~/.c11-sandbox state
is touched. The fake `tart set` fails for owner clones, so a sandbox-up run stops right after its
clone: reaching that clone means the owner got the guest back.
"""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SANDBOX_UP = REPO / "scripts" / "sandbox-up.sh"
LANE = REPO / "scripts" / "c11-host-tests.py"
C11_A, C11_B = "c11-sandbox-golden", "c11-sandbox-golden-b"
YIELD_S = int(os.environ.get("C11_TEST_LANE_YIELD_S", "6"))  # 30 is the real default
SLACK_S = 1.5  # process start-up and teardown around the deadline, beyond the owner's clone

FAKE_TART = r'''#!/usr/bin/env python3
import json, os, sys, time
state = os.environ["FAKE_TART_STATE"]
def load():
    return json.load(open(state))
def save(vms):
    tmp = state + ".%d" % os.getpid()
    json.dump(vms, open(tmp, "w")); os.replace(tmp, state)
open(os.environ["FAKE_TART_CALLS"], "a").write(json.dumps(sys.argv[1:]) + "\n")
open(os.environ["FAKE_TART_PIDS"], "a").write("%d\n" % os.getpid())
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
target = sys.argv[2] if len(sys.argv) > 2 else ""
lane_vm = target.startswith("c11-ht-") or (cmd == "clone" and sys.argv[3].startswith("c11-ht-"))
hang = float(os.environ.get("FAKE_TART_HANG_" + cmd.upper(), "0"))
if lane_vm and hang:
    time.sleep(hang)
vms = load()
if cmd == "list":
    print("Source Name Disk Size Accessed State")
    for name, st in vms.items():
        print(f"local {name} 50 32 now {st}")
elif cmd == "clone":
    marker = os.environ.get("FAKE_OWNER_CLONE_TIME")
    if marker and sys.argv[3].startswith("c11-sb-"):
        open(marker, "w").write(str(time.time()))
    spans = os.environ.get("FAKE_OWNER_CLONE_SPANS")
    if spans and sys.argv[3].startswith("c11-sb-"):
        started = time.time()
        time.sleep(float(os.environ.get("FAKE_OWNER_CLONE_S", "0")))
        open(spans, "a").write("%f %f %s\n" % (started, time.time(), sys.argv[3]))
    vms[sys.argv[3]] = "stopped"; save(vms)
elif cmd == "set":
    if not target.startswith("c11-ht-"):
        sys.exit(1)  # an owner run stops right after its clone
elif cmd == "delete":
    vms.pop(target, None); save(vms)
elif cmd == "stop":
    if target in vms:
        vms[target] = "stopped"; save(vms)
elif cmd == "run":
    vms[sys.argv[-1]] = "running"; save(vms)
    time.sleep(300)
elif cmd == "ip":
    sys.exit(1)
else:
    sys.exit(f"fake tart: unsupported {cmd}")
'''

LANE_HELPER = r'''
import importlib.util, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("lane", sys.argv[1])
lane = importlib.util.module_from_spec(spec); spec.loader.exec_module(lane)
guest = lane.Guest("20261115T040000-aaaaaa", Path(sys.argv[2]), {}, Path(sys.argv[2]))
try:
    guest.boot(time.monotonic() + 600)
except InterruptedError:
    print("YIELDED", flush=True)
finally:
    guest.teardown()
'''

LANE_VM = "c11-ht-20261115t040000-aaaaaa"


class SandboxLanePreempt(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.t = t
        self.home = t / "home"
        (self.home / ".ssh").mkdir(parents=True)
        (self.home / ".ssh" / "c11-sandbox").write_text("not a key\n")
        self.root = self.home / ".c11-sandbox"
        self.owned = self.root / "host-tests" / "owned"
        self.owned.mkdir(parents=True)
        self.tart = t / "tart"
        self.tart.write_text(FAKE_TART)
        self.tart.chmod(0o755)
        self.state = t / "vms.json"
        self.calls = t / "calls.jsonl"
        self.calls.write_text("")
        self.fake_pids = t / "fake-tart-pids"
        self.fake_pids.write_text("")
        app = t / "Probe.app" / "Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_text("<plist/>\n")
        self.app = t / "Probe.app"
        self.vms(**{C11_A: "stopped", C11_B: "stopped"})
        self.children = []

    def tearDown(self):
        for proc in self.children:
            if proc.poll() is None:
                os.kill(proc.pid, signal.SIGCONT)
                proc.kill()
            proc.wait()
            if proc.stdout is not None:
                proc.stdout.close()
        # No stand-in tart (a lane's in-flight clone runs in its own session) outlives the test:
        # kill each recorded fake by PID, after checking it is still this test's fake.
        for pid in {int(p) for p in self.fake_pids.read_text().split()}:
            cmd = subprocess.run(["/bin/ps", "-o", "command=", "-p", str(pid)],
                                 capture_output=True, text=True).stdout
            if str(self.tart) in cmd:
                os.kill(pid, signal.SIGKILL)
        self.tmp.cleanup()

    def vms(self, **vms):
        self.state.write_text(json.dumps(vms))

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "FAKE_"))}
        env.update(HOME=str(self.home), C11_SANDBOX_HOST="local", C11_SANDBOX_TART_BIN=str(self.tart),
                   FAKE_TART_STATE=str(self.state), FAKE_TART_CALLS=str(self.calls),
                   FAKE_TART_PIDS=str(self.fake_pids),
                   C11_SANDBOX_LANE_YIELD_S=str(YIELD_S), C11_HOST_TESTS_SANDBOX_ROOT=str(self.root),
                   C11_HOST_TESTS_TART=str(self.tart))
        env.update(extra)
        return env

    @staticmethod
    def identity(pid):
        def ps(field):  # read as the lane records it: pinned locale and zone
            return subprocess.run(["/bin/ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True,
                                  env=dict(os.environ, LC_ALL="C", TZ="UTC0")).stdout.strip()
        return {"start": ps("lstart"), "command": ps("command")}

    def claim(self, vm, pid, lane_identity=False, producer=None):
        """A claim as the lane writes it. Without lane_identity the PID is unproven, as a stale or
        reused one is: sandbox-up may never signal it."""
        row = {"vm": vm, "root": str(self.t), "pid": pid}
        if lane_identity:
            row["lane"] = self.identity(pid)
        if producer is not None:
            row["producer_pid"] = producer
            row["producer"] = self.identity(producer)
        (self.owned / f"{vm}.json").write_text(json.dumps(row))

    def fake_lane(self):
        """A live process whose command line is a lane's, as a claim's lane PID must be."""
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", "c11-host-tests.py"])
        self.children.append(proc)
        # A real lane writes its claim long after exec; wait until this one has exec'd too.
        self.wait_for(lambda: "c11-host-tests" in subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(proc.pid)], capture_output=True, text=True).stdout, 10)
        return proc.pid

    def sleeper(self):
        proc = subprocess.Popen(["/bin/sleep", "300"])
        self.children.append(proc)
        return proc.pid

    def run_up(self, run_id, *args, **extra):
        started = time.monotonic()
        out = subprocess.run([str(SANDBOX_UP), run_id, str(self.app), *args], env=self.env(**extra),
                             capture_output=True, text=True, timeout=120)
        return out, time.monotonic() - started

    def all_calls(self):
        return [c for c in map(json.loads, self.calls.read_text().splitlines()) if c]

    def calls_of(self, cmd):
        return [c[1:] for c in self.all_calls() if c[0] == cmd]

    def wait_for(self, predicate, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        self.fail("condition not reached")

    def start_lane(self, **extra):
        """The real lane's Guest.boot, stuck in `tart clone` while it holds clone.lock."""
        proc = subprocess.Popen([sys.executable, "-c", LANE_HELPER, str(LANE), str(self.t)],
                                env=self.env(FAKE_TART_HANG_CLONE="300", **extra),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.children.append(proc)
        lock_run = self.root / "clone.lock" / "run"
        self.wait_for(lambda: lock_run.exists() and lock_run.read_text().strip() == "host-tests"
                      and [C11_A, LANE_VM] in self.calls_of("clone"))
        return proc

    # -- the lane cooperates

    def test_an_owner_arriving_while_the_lane_clones_under_the_lock_gets_it_within_the_deadline(self):
        lane = self.start_lane()
        out, elapsed = self.run_up("own1")
        self.assertIn([C11_A, "c11-sb-own1"], self.calls_of("clone"), out.stderr)
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)
        self.assertIn("YIELDED", lane.communicate(timeout=30)[0])
        self.assertFalse((self.owned / f"{LANE_VM}.json").exists())

    def test_a_running_lane_guest_that_yields_is_waited_for(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", LANE_VM: "running"})
        self.claim(LANE_VM, self.fake_lane(), lane_identity=True)
        request = self.root / "lane-yield" / LANE_VM

        def lane():  # the lane's watcher: on its yield request, delete its own VM and claim
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if request.exists():
                    vms = json.loads(self.state.read_text())
                    vms.pop(LANE_VM, None)
                    self.state.write_text(json.dumps(vms))
                    (self.owned / f"{LANE_VM}.json").unlink()
                    return
                time.sleep(0.1)

        worker = threading.Thread(target=lane)
        worker.start()
        out, elapsed = self.run_up("own2")
        worker.join()
        self.assertIn([C11_A, "c11-sb-own2"], self.calls_of("clone"), out.stderr)
        self.assertNotIn([LANE_VM], self.calls_of("delete"), out.stderr)
        self.assertLess(elapsed, YIELD_S, out.stderr)

    # -- the lane does not cooperate

    def test_a_hung_lane_holding_the_lock_loses_it_at_the_deadline(self):
        lane = self.start_lane()
        os.kill(lane.pid, signal.SIGSTOP)
        out, elapsed = self.run_up("own3")
        self.assertIn([C11_A, "c11-sb-own3"], self.calls_of("clone"), out.stderr)
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)

    def test_a_running_lane_guest_that_does_not_yield_is_deleted_by_the_deadline(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", LANE_VM: "running"})
        self.claim(LANE_VM, self.sleeper())
        out, elapsed = self.run_up("own4")
        self.assertIn([LANE_VM], self.calls_of("delete"), out.stderr)
        self.assertIn([C11_A, "c11-sb-own4"], self.calls_of("clone"), out.stderr)
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)

    def test_unresponsive_tart_cannot_stretch_the_deadline(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", LANE_VM: "running"})
        self.claim(LANE_VM, self.sleeper())
        out, elapsed = self.run_up("own5", FAKE_TART_HANG_STOP="300", FAKE_TART_HANG_DELETE="300")
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)
        self.assertIn([LANE_VM, "--timeout", "1"], self.calls_of("stop"), out.stderr)

    def test_takeover_cancels_the_inflight_clone_before_owner_admission(self):
        # A lane frozen mid-clone: its 9 s clone would land after the owner is admitted unless the
        # takeover stops that producer first. Watch past the old clone's completion window.
        lane = subprocess.Popen([sys.executable, "-c", LANE_HELPER, str(LANE), str(self.t)],
                                env=self.env(FAKE_TART_HANG_CLONE="9"),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.children.append(lane)
        self.wait_for(lambda: [C11_A, LANE_VM] in self.calls_of("clone"))
        os.kill(lane.pid, signal.SIGSTOP)
        out, elapsed = self.run_up("lateclone")
        self.assertIn([C11_A, "c11-sb-lateclone"], self.calls_of("clone"), out.stderr)
        time.sleep(max(0.0, 10.5 - elapsed))
        self.assertNotIn(LANE_VM, json.loads(self.state.read_text()))

    def test_one_deadline_includes_forced_cleanup_after_lock_takeover(self):
        lane = self.start_lane()
        os.kill(lane.pid, signal.SIGSTOP)
        marker = self.t / "owner-clone-time"
        out, _ = self.run_up("strictbound", FAKE_TART_HANG_STOP="3", FAKE_TART_HANG_DELETE="3",
                             FAKE_OWNER_CLONE_TIME=str(marker))
        self.assertTrue(marker.exists(), out.stderr)
        requested = (self.root / "lane-yield" / LANE_VM).stat().st_mtime
        until_clone = float(marker.read_text()) - requested
        print(f"request to owner clone {until_clone:.2f}s, deadline {YIELD_S}s", file=sys.stderr)
        self.assertLessEqual(until_clone, YIELD_S, out.stderr)

    def test_no_cleanup_step_runs_once_the_budget_is_spent(self):
        # Two unresponsive lane guests and a tart that hangs: the first guest's cleanup spends the
        # whole budget, so the second's must not get any fresh time.
        second = "c11-ht-20261115t040000-bbbbbb"
        self.vms(**{C11_A: "stopped", C11_B: "stopped", LANE_VM: "running", second: "running"})
        self.claim(LANE_VM, self.sleeper())
        self.claim(second, self.sleeper())
        out, elapsed = self.run_up("spent", FAKE_TART_HANG_STOP="30", FAKE_TART_HANG_DELETE="30",
                                   FAKE_TART_HANG_LIST="0")
        self.assertLess(elapsed, YIELD_S + 0.5, out.stderr)

    def test_a_claim_whose_pid_now_runs_something_else_does_not_hold_up_the_owner(self):
        sleeper = self.sleeper()
        self.claim(LANE_VM, sleeper)  # a reused PID: alive, but not a lane
        out, elapsed = self.run_up("reused")
        self.assertIn([C11_A, "c11-sb-reused"], self.calls_of("clone"), out.stderr)
        self.assertLess(elapsed, 2.5, out.stderr)
        self.assertEqual(os.waitpid(sleeper, os.WNOHANG), (0, 0), "the reused PID's process was signalled")

    def unrelated_reader(self, filename):
        path = self.t / filename
        path.write_text("diagnostic log\n")
        proc = subprocess.Popen(["/usr/bin/tail", "-f", str(path)], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        self.children.append(proc)
        self.wait_for(lambda: str(path) in subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(proc.pid)], capture_output=True, text=True).stdout)
        return proc

    def test_reused_lane_pid_does_not_kill_an_unrelated_log_reader(self):
        reader = self.unrelated_reader("c11-host-tests.log")
        self.claim(LANE_VM, reader.pid)  # a stale lane PID now belongs to an ordinary diagnostic reader
        out, _ = self.run_up("stale-reader")
        self.assertIsNone(reader.poll(), "unrelated tail process was killed by lane takeover\n" + out.stderr)

    def test_reused_producer_pid_does_not_kill_an_unrelated_log_reader(self):
        reader = self.unrelated_reader(LANE_VM + ".log")
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        self.claim(LANE_VM, dead.pid)
        path = self.owned / (LANE_VM + ".json")
        claim = json.loads(path.read_text())
        claim["producer_pid"] = reader.pid
        path.write_text(json.dumps(claim))
        out, _ = self.run_up("stale-producer")
        self.assertIsNone(reader.poll(), "unrelated tail process was killed as a VM producer\n" + out.stderr)

    def test_reused_lane_pid_held_by_a_python_reader_of_the_lane_log_is_not_killed(self):
        log = self.t / "c11-host-tests.py.log"
        log.write_text("lane log\n")
        reader = subprocess.Popen([sys.executable, "-c", "import sys, time; open(sys.argv[1]); time.sleep(300)",
                                   str(log)])
        self.children.append(reader)
        self.wait_for(lambda: str(log) in subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(reader.pid)], capture_output=True, text=True).stdout)
        self.claim(LANE_VM, reader.pid)
        out, _ = self.run_up("pyreader")
        self.assertIsNone(reader.poll(), "a python reader of the lane log was killed\n" + out.stderr)

    def test_two_owners_at_a_hung_lane_never_hold_the_lock_together(self):
        lane = self.start_lane()
        os.kill(lane.pid, signal.SIGSTOP)
        spans = self.t / "owner-clone-spans"
        # twin-b's forced stop of the lane VM is slow, so its takeover ends after twin-a already
        # holds the lock: it must not remove twin-a's lock.
        owners = [subprocess.Popen([str(SANDBOX_UP), run_id, str(self.app)],
                                   env=self.env(FAKE_OWNER_CLONE_SPANS=str(spans), FAKE_OWNER_CLONE_S="2",
                                                FAKE_TART_HANG_STOP=hang),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                  for run_id, hang in (("twin-a", "0"), ("twin-b", "1.5"))]
        errs = [o.communicate(timeout=120)[1] for o in owners]
        rows = sorted(tuple(float(x) for x in line.split()[:2]) for line in spans.read_text().splitlines())
        self.assertEqual(len(rows), 2, errs)
        (_, first_end), (second_start, _) = rows
        self.assertGreaterEqual(second_start, first_end, "two owners cloned under the lock at once\n" + "\n".join(errs))

    def test_a_recorded_lane_whose_start_time_changed_is_never_signalled(self):
        reader = self.unrelated_reader("c11-host-tests-reused.log")
        self.claim(LANE_VM, reader.pid, lane_identity=True)
        path = self.owned / (LANE_VM + ".json")
        claim = json.loads(path.read_text())
        claim["lane"]["start"] = "Mon Jan  1 00:00:00 2026"  # same PID and command, another process
        path.write_text(json.dumps(claim))
        out, _ = self.run_up("restarted")
        self.assertIsNone(reader.poll(), out.stderr)

    def test_an_owner_in_another_time_zone_and_locale_still_stops_the_genuine_lane(self):
        # The lane records its identity under one environment (launchd), the owner compares under
        # its own shell's: a different TZ or LANG must not make the genuine lane look like a stranger.
        lane = self.start_lane(TZ="Pacific/Kiritimati", LANG="en_US.UTF-8")
        os.kill(lane.pid, signal.SIGSTOP)
        producer = json.loads((self.owned / f"{LANE_VM}.json").read_text()).get("producer_pid")
        out, elapsed = self.run_up("elsewhere", TZ="America/New_York", LANG="ja_JP.UTF-8", LC_ALL="ja_JP.UTF-8")
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)
        self.assertIsNotNone(lane.poll(), "the recorded lane survived an owner in another zone\n" + out.stderr)
        st = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(producer)], capture_output=True, text=True).stdout
        self.assertTrue(st.strip() == "" or st.strip().startswith("Z"), "the recorded producer survived: " + st)

    def test_the_genuine_recorded_lane_and_producer_are_stopped_within_the_deadline(self):
        lane = self.start_lane()
        os.kill(lane.pid, signal.SIGSTOP)
        claim = json.loads((self.owned / f"{LANE_VM}.json").read_text())
        producer = claim.get("producer_pid")
        self.assertTrue(producer and claim.get("producer") and claim.get("lane"), claim)
        out, elapsed = self.run_up("genuine")
        self.assertIn([C11_A, "c11-sb-genuine"], self.calls_of("clone"), out.stderr)
        self.assertLess(elapsed, YIELD_S + SLACK_S, out.stderr)
        self.assertIsNotNone(lane.poll(), "the recorded lane survived the takeover\n" + out.stderr)
        st = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(producer)], capture_output=True, text=True).stdout
        self.assertTrue(st.strip() == "" or st.strip().startswith("Z"), "the recorded producer survived: " + st)

    # -- ownership

    def test_a_claim_never_authorizes_touching_a_golden_or_an_owner_guest(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", "c11-sb-other": "running"})
        self.claim(C11_A, self.sleeper())
        self.claim("c11-sb-other", self.sleeper())
        out, _ = self.run_up("forged", "--allow-second")
        touched = [c[0] for c in self.calls_of("stop") + self.calls_of("delete")]
        self.assertNotIn(C11_A, touched, out.stderr)
        self.assertNotIn("c11-sb-other", touched, out.stderr)

    def test_a_lane_named_vm_without_a_claim_is_never_touched(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", "c11-ht-not-recorded": "running"})
        out, _ = self.run_up("own6")
        self.assertIn("a guest is already running", out.stderr)
        self.assertNotIn(["c11-ht-not-recorded"], self.calls_of("delete"))
        self.assertEqual([c for c in self.calls_of("stop") if c[0] == "c11-ht-not-recorded"], [])

    def test_a_running_lane_guest_holds_the_first_golden_serial(self):
        # A lane guest always clones the first golden: a second owner guest must take golden B.
        self.vms(**{C11_A: "stopped", C11_B: "stopped", "c11-ht-not-recorded": "running"})
        out, _ = self.run_up("own8", "--allow-second")
        self.assertEqual(self.calls_of("clone"), [[C11_B, "c11-sb-own8"]], out.stderr)

    def test_an_owner_guest_is_never_preempted(self):
        self.vms(**{C11_A: "stopped", C11_B: "stopped", "c11-sb-other": "running"})
        out, _ = self.run_up("own7")
        self.assertIn("a guest is already running", out.stderr)
        self.assertEqual(self.calls_of("clone"), [])
        self.assertNotIn(["c11-sb-other"], self.calls_of("delete"))


if __name__ == "__main__":
    unittest.main()
