#!/usr/bin/env python3
"""Decisions of the host-test lane (scripts/c11-host-tests.py), run with stand-in tart and lattice.

No VM, build, real tart or board is touched: tart and lattice are file-driven fakes on a
throwaway HOME, and the guest's yield watcher deletes only the fake VM.
"""
import importlib.util
import json
import os
import pathlib
import signal
import sys
import tempfile
import threading
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
TMP = tempfile.TemporaryDirectory()
T = pathlib.Path(TMP.name)
os.environ["C11_HOST_TESTS_SANDBOX_ROOT"] = str(T / "sandbox")
os.environ["C11_HOST_TESTS_TART"] = str(T / "tart")
os.environ["C11_HOST_TESTS_LATTICE"] = str(T / "lattice")

FAKE_TART = r'''#!/usr/bin/env python3
import json, os, sys
state = os.environ["FAKE_TART_STATE"]
vms = json.load(open(state))
def dump(vms, _f):  # atomic, so a concurrent `list` never reads a half-written file
    tmp = state + ".%d" % os.getpid()
    json.dump(vms, open(tmp, "w")); os.replace(tmp, state)
open(os.environ["FAKE_TART_CALLS"], "a").write(json.dumps(sys.argv[1:]) + "\n")
cmd = sys.argv[1]
marker = os.environ.get("FAKE_TART_DELAY_FIRST_LIST")
if cmd == "list" and marker and not os.path.exists(marker):
    open(marker, "w").close()
    import time; time.sleep(3)
if cmd == "list":
    print("Source Name Disk Size Accessed State")
    for name, st in vms.items():
        print(f"local {name} 50 32 now {st}")
elif cmd == "delete":
    vms.pop(sys.argv[2], None); dump(vms, None)
elif cmd == "clone":
    vms[sys.argv[3]] = "stopped"; dump(vms, None)
elif cmd == "stop":
    if sys.argv[2] in vms:
        vms[sys.argv[2]] = "stopped"; dump(vms, None)
elif cmd == "run":
    vms[sys.argv[-1]] = "running"; dump(vms, None)
    import time; time.sleep(120)
elif cmd == "ip":
    sys.exit(1)  # never gets an address: the guest phase runs out of time
'''

FAKE_LATTICE = r'''#!/usr/bin/env python3
import json, os, sys, time
open(os.environ["FAKE_LATTICE_CALLS"], "a").write(json.dumps(sys.argv[1:]) + "\n")
time.sleep(float(os.environ.get("FAKE_LATTICE_SLEEP_" + sys.argv[1].upper(), "0")))
if sys.argv[1] == "list":
    tag = sys.argv[sys.argv.index("--tag") + 1]
    tasks = json.load(open(os.environ["FAKE_LATTICE_TASKS"])).get(tag, [])
    print(json.dumps({"ok": True, "data": tasks}))
elif sys.argv[1] == "create":
    print(json.dumps({"ok": True, "data": {"short_id": "C11H-900"}}))
else:
    print(json.dumps({"ok": True, "data": {}}))
'''

for name, body in (("tart", FAKE_TART), ("lattice", FAKE_LATTICE)):
    (T / name).write_text(body)
    (T / name).chmod(0o755)

spec = importlib.util.spec_from_file_location("lane", HERE / "c11-host-tests.py")
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

A, B, C = "a" * 40, "b" * 40, "c" * 40


class TipDecision(unittest.TestCase):
    def test_new_tip_runs(self):
        self.assertEqual(lane.tip_decision([{"tip": A, "state": "success"}], B, ["Sources/X.swift"], False), "run")

    def test_tested_tip_is_unchanged(self):
        self.assertEqual(lane.tip_decision([{"tip": A, "state": "failure"}], A, [], False), "unchanged")

    def test_docs_only_advance_skips(self):
        self.assertEqual(lane.tip_decision([{"tip": A, "state": "success"}], B,
                                           ["docs/x.md", "AGENTS.md", "notes/y.txt"], False), "docs-only")

    def test_markdown_that_reaches_the_app_or_tests_is_not_docs(self):
        last = [{"tip": A, "state": "success"}]
        self.assertEqual(lane.tip_decision(last, B, ["c11Tests/Fixtures/workspace-blueprints/x.md"], False), "run")
        self.assertEqual(lane.tip_decision(last, B, ["skills/c11/SKILL.md"], False), "run")

    def test_dry_run_rows_never_mark_a_tip(self):
        rows = [{"tip": A, "state": "success"}, {"tip": B, "state": "failure", "dry_run": True}]
        self.assertEqual(lane.tip_decision(rows, B, ["Sources/X.swift"], False), "run")
        self.assertEqual(lane.infra_count([{"tip": B, "state": "error", "dry_run": True}] * 3, B), 0)

    def test_mixed_advance_runs(self):
        self.assertEqual(lane.tip_decision([{"tip": A, "state": "success"}], B,
                                           ["docs/x.md", "c11Tests/FooTests.swift"], False), "run")

    def test_three_infra_errors_cap_a_tip(self):
        rows = [{"tip": A, "state": "success"}] + [{"tip": B, "state": "error"}] * 3
        self.assertEqual(lane.tip_decision(rows, B, ["Sources/X.swift"], False), "infra-capped")
        self.assertEqual(lane.tip_decision(rows, B, ["Sources/X.swift"], True), "run")

    def test_yielded_runs_do_not_count_as_tested(self):
        rows = [{"tip": A, "state": "success"}, {"tip": B, "state": "yielded"}]
        self.assertEqual(lane.tip_decision(rows, B, ["Sources/X.swift"], False), "run")


class GuestGate(unittest.TestCase):
    def test_free(self):
        self.assertIsNone(lane.guest_gate([], 3600, 5.0, 100))

    def test_any_running_guest_blocks(self):
        self.assertIn("c11-sb-x", lane.guest_gate(["c11-sb-x"], None, 1.0, 100))

    def test_recent_sandbox_activity_blocks(self):
        self.assertIsNotNone(lane.guest_gate([], 60, 1.0, 100))

    def test_load_and_disk_block(self):
        self.assertIsNotNone(lane.guest_gate([], None, 41.0, 100))
        self.assertIsNotNone(lane.guest_gate([], None, 1.0, 20))


class ReportAction(unittest.TestCase):
    red = [{"short_id": "C11H-500", "status": "backlog"}]

    def test_first_red_creates(self):
        self.assertEqual(lane.report_action("failure", A, [], [], [])["op"], "create")

    def test_red_with_open_ticket_comments(self):
        act = lane.report_action("failure", A, [], self.red, [])
        self.assertEqual((act["op"], act["task"]), ("comment", "C11H-500"))

    def test_only_the_first_green_after_red_comments(self):
        red_then_green = [{"tip": A, "state": "failure"}, {"tip": B, "state": "success"}]
        self.assertTrue(lane.report_action("success", B, red_then_green, self.red, [])["green"])
        across_docs = [{"tip": A, "state": "failure"}, {"tip": B, "state": "skipped-docs"}, {"tip": C, "state": "success"}]
        self.assertTrue(lane.report_action("success", C, across_docs, self.red, [])["green"])
        green_again = red_then_green + [{"tip": C, "state": "success"}]
        self.assertIsNone(lane.report_action("success", C, green_again, self.red, []))
        self.assertIsNone(lane.report_action("success", B, red_then_green, [], []))

    def test_every_third_infra_error_in_a_row_reports(self):
        rows = [{"tip": A, "state": "error"}]
        self.assertIsNone(lane.report_action("error", A, rows * 2, [], []))
        self.assertEqual(lane.report_action("error", A, rows * 3, [], [])["tag"], lane.INFRA_TAG)
        self.assertIsNone(lane.report_action("error", A, rows * 4, [], []))

    def test_infra_errors_count_across_tips(self):
        # A lane that fails once at every new tip never trips the per-tip cap, but still reaches the board.
        rows = [{"tip": A, "state": "success"}, {"tip": A, "state": "error"}, {"tip": B, "state": "error"},
                {"tip": C, "state": "error"}]
        self.assertEqual(lane.report_action("error", C, rows, [], [])["tag"], lane.INFRA_TAG)
        self.assertIsNone(lane.report_action("error", C, rows[:3], [], []))

    def test_closed_tickets_are_not_open(self):
        tasks = [{"short_id": "C11H-1", "status": "done"}, {"short_id": "C11H-2", "status": "cancelled"}]
        self.assertEqual(lane.open_tickets(tasks), [])


class Summarize(unittest.TestCase):
    def test_failures_keep_their_failure_text(self):
        st, _, failures, _ = lane.summarize({"result": "Failed", "totalTestCount": 3, "passedTests": 2,
                                             "failedTests": 1, "skippedTests": 0,
                                             "testFailures": [{"targetName": "c11Tests",
                                                               "testIdentifierString": "FooTests/testBar()",
                                                               "failureText": "XCTAssertEqual failed: (\"7\") is not (\"8\")\nsecond line"}]})
        self.assertEqual(st, "failure")
        self.assertEqual(failures, ['c11Tests/FooTests/testBar() :: XCTAssertEqual failed: ("7") is not ("8")'])

    def test_report_text_carries_timing_overflow_and_the_infra_log_tail(self):
        row = {"state": "failure", "tip": A, "started": "now", "reason": "45 failed tests", "run_dir": "/x",
               "build_seconds": 9.2, "test_seconds": 371, "counts": {},
               "failures": [f"c11Tests/T/test{i}() :: boom {i}" for i in range(45)]}
        text = lane.report_text(row)
        self.assertIn("build 9.2 s, test 371 s", text)
        self.assertIn("boom 39", text)
        self.assertNotIn("boom 40", text)
        self.assertIn("… and 5 more (see evidence)", text)
        infra = {"state": "error", "tip": A, "started": "now", "reason": "guest: x", "run_dir": "/x",
                 "log_tail": ["first", "xcodebuild: error: distinctive-tail-9931"]}
        self.assertIn("distinctive-tail-9931", lane.report_text(infra))

    def test_zero_executed_is_failure_and_missing_is_error(self):
        self.assertEqual(lane.summarize({"result": "Passed", "totalTestCount": 2, "passedTests": 0,
                                         "failedTests": 0, "skippedTests": 2})[0], "failure")
        self.assertEqual(lane.summarize(None)[0], "error")


def claim(vm, root, pid, identity=None):
    """A claim as the lane writes it; `identity` defaults to the PID's current identity."""
    lane.claims_dir().mkdir(parents=True, exist_ok=True)
    ident = lane.process_identity(pid) if identity is None else identity
    (lane.claims_dir() / f"{vm}.json").write_text(json.dumps({"vm": vm, "root": str(root), "pid": pid,
                                                              "lane": ident}))


def fake_tart(vms):
    state, calls = T / "vms.json", T / "tart-calls.jsonl"
    state.write_text(json.dumps(vms))
    calls.write_text("")
    os.environ.update(FAKE_TART_STATE=str(state), FAKE_TART_CALLS=str(calls))
    return state, calls


def tart_calls(calls):
    return [json.loads(l) for l in calls.read_text().splitlines()]


def dead_pid():
    import subprocess
    p = subprocess.Popen(["/usr/bin/true"])
    p.wait()
    return p.pid


class Board(unittest.TestCase):
    def setUp(self):
        self.root = T / "root"
        (self.root / "board").mkdir(parents=True, exist_ok=True)
        self.calls = T / "lattice-calls.jsonl"
        self.calls.write_text("")
        os.environ["FAKE_LATTICE_CALLS"] = str(self.calls)
        self.tasks = T / "tasks.json"
        self.tasks.write_text(json.dumps({}))
        os.environ["FAKE_LATTICE_TASKS"] = str(self.tasks)
        self.records = T / "records-board.jsonl"
        self.records.unlink(missing_ok=True)
        for k in ("FAKE_LATTICE_SLEEP_LIST", "FAKE_LATTICE_SLEEP_CREATE"):
            os.environ.pop(k, None)
        lane.BOARD_TIMEOUT_S = 1

    def row(self, state, run_id="r1"):
        return {"run_id": run_id, "state": state, "tip": A, "started": "now", "reason": "r", "counts": {},
                "failures": ['c11Tests/X/testY() :: XCTAssertTrue failed - distinctive-marker-4471'], "run_dir": "/x"}

    def calls_of(self):
        return [json.loads(l) for l in self.calls.read_text().splitlines()]

    def test_red_creates_a_tagged_bug_as_the_lane_with_failure_text(self):
        act = lane.report(self.root, self.row("failure"), [], dry_run=False)
        self.assertEqual(act["task"], "C11H-900")
        create = [c for c in self.calls_of() if c[0] == "create"][0]
        self.assertIn(lane.RED_TAG, create)
        self.assertEqual(create[create.index("--actor") + 1], "agent:c11-host-tests")
        self.assertIn("distinctive-marker-4471", create[create.index("--description") + 1])

    def test_dry_run_writes_nothing_to_the_board(self):
        act = lane.report(self.root, self.row("failure"), [], dry_run=True)
        self.assertTrue(act["dry_run"])
        self.assertEqual(self.calls_of(), [])

    def test_a_board_list_timeout_keeps_the_red_result_and_leaves_it_pending(self):
        os.environ["FAKE_LATTICE_SLEEP_LIST"] = "3"
        row = self.row("failure")
        self.assertEqual(lane.finish(self.root, row, [], self.records, False), 1)
        rows = lane.read_jsonl(self.records)
        self.assertEqual(rows[0]["state"], "failure")
        self.assertEqual(rows[1]["board"]["op"], "unavailable")
        self.assertEqual([r["run_id"] for r in lane.board_pending(rows)], ["r1"])

    def test_a_board_create_timeout_keeps_the_red_result_and_leaves_it_pending(self):
        os.environ["FAKE_LATTICE_SLEEP_CREATE"] = "3"
        row = self.row("failure")
        lane.finish(self.root, row, [], self.records, False)
        rows = lane.read_jsonl(self.records)
        self.assertEqual(rows[0]["state"], "failure")
        self.assertIn("error", rows[1]["board"])
        self.assertEqual([r["run_id"] for r in lane.board_pending(rows)], ["r1"])


class BoardRetry(unittest.TestCase):
    def test_an_undelivered_report_stays_pending_until_a_delivery_lands(self):
        failed = {"run_id": "r1", "tip": A, "state": "failure", "board": {"op": "pending"}}
        self.assertEqual(lane.board_pending([failed]), [failed])
        down = {"board_for": "r1", "board": {"op": "unavailable"}}
        self.assertEqual(lane.board_pending([failed, down]), [failed])
        up = {"board_for": "r1", "board": {"op": "create", "task": "C11H-9"}}
        self.assertEqual(lane.board_pending([failed, down, up]), [])

    def test_a_newer_delivered_result_never_hides_an_older_undelivered_red(self):
        red = {"run_id": "r1", "tip": A, "state": "failure", "board": {"op": "pending"}}
        red_down = {"board_for": "r1", "board": {"op": "unavailable"}}
        green = {"run_id": "r2", "tip": B, "state": "success", "board": {"op": "pending"}}
        green_up = {"board_for": "r2", "board": {"op": "none"}}
        later_red = {"run_id": "r3", "tip": C, "state": "failure", "board": {"op": "pending"}}
        later_up = {"board_for": "r3", "board": {"op": "create", "task": "C11H-10"}}
        rows = [red, red_down, green, green_up, later_red, later_up]
        self.assertEqual(lane.board_pending(rows), [red])


class Ownership(unittest.TestCase):
    def test_stop_never_touches_another_roots_active_guest(self):
        root_a, root_b = (T / "rootA").resolve(), (T / "rootB").resolve()
        (root_a / "state").mkdir(parents=True, exist_ok=True)
        vm_b = "c11-ht-rootb-active"
        state, calls = fake_tart({vm_b: "running"})
        claim(vm_b, root_b, os.getpid())  # B's run is alive
        lane.stop(root_a)
        self.assertNotIn(vm_b, [c[1] for c in tart_calls(calls) if c[0] in ("stop", "delete")])
        self.assertEqual(json.loads(state.read_text()), {vm_b: "running"})
        (lane.claims_dir() / f"{vm_b}.json").unlink()

    def test_stop_signals_the_recorded_run_only_while_it_is_that_process(self):
        import subprocess
        root = (T / "rootRun").resolve()
        (root / "state").mkdir(parents=True, exist_ok=True)
        fake_tart({})
        reader = subprocess.Popen(["/bin/sleep", "60"])  # holds the recorded PID, but is another process
        try:
            (root / "state" / "run.json").write_text(json.dumps({
                "pid": reader.pid, "root": str(root),
                "identity": {"start": "Mon Jan  1 00:00:00 2026", "command": "/usr/bin/python3 c11-host-tests.py"}}))
            lane.stop(root)
            self.assertIsNone(reader.poll(), "stop signalled a process that only reused the run's PID")
            (root / "state" / "run.json").write_text(json.dumps({
                "pid": reader.pid, "root": str(root), "identity": lane.process_identity(reader.pid)}))
            lane.stop(root)
            self.assertEqual(reader.wait(timeout=10), -15)  # the genuine recorded run gets TERM
        finally:
            if reader.poll() is None:
                reader.kill()
            reader.wait()

    def test_stop_never_signals_a_run_whose_start_time_alone_differs(self):
        import subprocess
        root = (T / "rootStart").resolve()
        (root / "state").mkdir(parents=True, exist_ok=True)
        fake_tart({})
        other = subprocess.Popen(["/bin/sleep", "60"])
        try:
            ident = lane.process_identity(other.pid)
            ident["start"] = "Mon Jan  1 00:00:00 2026"  # same PID and exact command line, another process
            (root / "state" / "run.json").write_text(json.dumps({"pid": other.pid, "root": str(root),
                                                                 "identity": ident}))
            lane.stop(root)
            self.assertIsNone(other.poll(), "stop signalled a process whose start time differs")
        finally:
            other.kill()
            other.wait()

    def test_stop_never_signals_a_run_with_no_recorded_identity(self):
        import subprocess
        root = (T / "rootNoIdentity").resolve()
        (root / "state").mkdir(parents=True, exist_ok=True)
        fake_tart({})
        other = subprocess.Popen(["/bin/sleep", "60"])
        try:
            (root / "state" / "run.json").write_text(json.dumps({"pid": other.pid, "root": str(root)}))
            lane.stop(root)
            self.assertIsNone(other.poll(), "stop signalled a PID with no recorded identity")
        finally:
            other.kill()
            other.wait()

    def test_stop_deletes_its_own_roots_orphan(self):
        root_a = (T / "rootA2").resolve()
        (root_a / "state").mkdir(parents=True, exist_ok=True)
        vm = "c11-ht-roota-orphan"
        state, calls = fake_tart({vm: "running"})
        claim(vm, root_a, dead_pid())
        lane.stop(root_a)
        self.assertEqual(json.loads(state.read_text()), {})
        self.assertFalse((lane.claims_dir() / f"{vm}.json").exists())

    def test_an_unrecorded_lane_named_vm_is_never_deleted(self):
        vm = "c11-ht-someone-elses"
        state, calls = fake_tart({vm: "running"})
        with self.assertRaises(RuntimeError):
            lane.delete_vm(vm)
        lane.sweep_orphans(T / "events.jsonl")
        self.assertEqual(json.loads(state.read_text()), {vm: "running"})
        for name in ("c11-sb-owner", "c11-sandbox-golden"):
            with self.assertRaises(RuntimeError):
                lane.delete_vm(name)

    def test_sweep_deletes_only_claims_whose_run_is_gone(self):
        live_vm, dead_vm, reused_vm = "c11-ht-live", "c11-ht-dead", "c11-ht-reused"
        state, calls = fake_tart({live_vm: "running", dead_vm: "stopped", reused_vm: "running"})
        claim(live_vm, T / "x", os.getpid())  # this test process runs c11-host-tests-test.py
        claim(dead_vm, T / "y", dead_pid())
        import subprocess
        other = subprocess.Popen(["/bin/sleep", "60"])  # a reused PID: alive, but another process
        claim(reused_vm, T / "z", other.pid, identity={"start": "Mon Jan  1 00:00:00 2026", "command": "x"})
        try:
            lane.sweep_orphans(T / "events.jsonl")
        finally:
            other.kill()
            other.wait()
        self.assertEqual(json.loads(state.read_text()), {live_vm: "running"})
        (lane.claims_dir() / f"{live_vm}.json").unlink()


class AbortRecording(unittest.TestCase):
    def setUp(self):
        self.records = T / "records-abort.jsonl"
        self.records.unlink(missing_ok=True)

    def test_a_signal_after_the_outcome_is_recorded_never_rewrites_it(self):
        row = {"run_id": "r9", "tip": A, "state": "failure", "finished": "now", "board": {"op": "pending"}}
        lane.append_jsonl(self.records, row)
        for signum in (signal.SIGTERM, signal.SIGALRM):
            self.assertEqual(lane.record_abort(T, dict(row), [row], self.records, False, lane.Abort(signum)), 1)
        rows = lane.read_jsonl(self.records)
        self.assertEqual(rows, [row])
        self.assertEqual([r["run_id"] for r in lane.board_pending(rows)], ["r9"])

    def test_a_signal_before_recording_records_a_stop(self):
        lane.record_abort(T, {"run_id": "r10", "tip": A}, [], self.records, False, lane.Abort(signal.SIGTERM))
        self.assertEqual(lane.read_jsonl(self.records)[-1]["state"], "stopped")


class CloneLockRelease(unittest.TestCase):
    def test_release_never_removes_a_lock_someone_else_took_over(self):
        lock = lane.CloneLock()
        lock.path.mkdir(parents=True, exist_ok=True)
        (lock.path / "pid").write_text("1\n")  # an owner's sandbox-up took it at its deadline
        lock.held = True
        lock.release()
        self.assertTrue(lock.path.exists())
        import shutil
        shutil.rmtree(lock.path)


class GuestDeadline(unittest.TestCase):
    def test_no_test_invocation_starts_after_a_late_copy(self):
        state, calls = fake_tart({})
        scripts, saved = [], {}

        def boot(self, deadline):
            claim(self.vm, T, os.getpid())
            return {"boot_seconds": 0}

        def ssh(self, script, timeout, check=True, stdout=None):
            scripts.append(script)
            import subprocess
            return subprocess.CompletedProcess([], 0, "", "")

        def push(self, parent, names, dest, timeout, excludes=()):
            time.sleep(2.5)  # a slow copy that ends past the 2 s ceiling

        for name, fn in (("boot", boot), ("ssh", ssh), ("push", push)):
            saved[name] = getattr(lane.Guest, name)
            setattr(lane.Guest, name, fn)
        saved_timeout, lane.GUEST_TIMEOUT_S = lane.GUEST_TIMEOUT_S, 2
        products = T / "products"
        (products / "Debug").mkdir(parents=True, exist_ok=True)
        try:
            timing = {}
            with self.assertRaises(TimeoutError):
                lane.run_guest("20261115T030000-dead11", T, products, T / "src", [], {}, timing, T)
        finally:
            for name, fn in saved.items():
                setattr(lane.Guest, name, fn)
            lane.GUEST_TIMEOUT_S = saved_timeout
        self.assertFalse(any("test-without-building" in s for s in scripts))
        self.assertFalse(any(p.name.endswith(".json") for p in lane.claims_dir().glob("c11-ht-20261115t030000*")))


class Yield(unittest.TestCase):
    def test_yield_request_deletes_the_lane_guest(self):
        guest = lane.Guest("20261115T010000-abcdef", T, {})
        state, calls = fake_tart({guest.vm: "running"})
        claim(guest.vm, T, os.getpid())
        watcher = threading.Thread(target=guest._watch_yield, daemon=True)
        watcher.start()
        lane.yield_path(guest.vm).parent.mkdir(parents=True, exist_ok=True)
        lane.yield_path(guest.vm).write_text("owner\n")
        watcher.join(10)
        self.assertTrue(guest.yielded)
        self.assertNotIn(guest.vm, json.loads(state.read_text()))
        self.assertFalse((lane.claims_dir() / f"{guest.vm}.json").exists())
        with self.assertRaises(InterruptedError):
            guest._check(time.monotonic() + 60)
        lane.yield_path(guest.vm).unlink()

    def test_yield_during_initial_inventory_does_not_leave_unowned_clone(self):
        run_id = "20261115T050000-abcdef"
        vm = lane.VM_PREFIX + run_id.lower()
        state, calls = fake_tart({"c11-sandbox-golden": "stopped"})
        marker = T / "inventory-started"
        os.environ["FAKE_TART_DELAY_FIRST_LIST"] = str(marker)

        def owner():  # asks for the guest while the lane's first inventory listing is still running
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            lane.yield_path(vm).parent.mkdir(parents=True, exist_ok=True)
            lane.yield_path(vm).write_text("owner\n")

        worker = threading.Thread(target=owner)
        worker.start()
        try:
            with self.assertRaises(InterruptedError):
                lane.run_guest(run_id, T, T, T, [], {}, {}, T)
        finally:
            worker.join(6)
            os.environ.pop("FAKE_TART_DELAY_FIRST_LIST", None)
        self.assertNotIn(vm, json.loads(state.read_text()))
        self.assertNotIn(["clone", "c11-sandbox-golden", vm], tart_calls(calls))
        self.assertFalse((lane.claims_dir() / f"{vm}.json").exists())

    def test_a_failed_guest_phase_still_deletes_the_guest(self):
        state, calls = fake_tart({"c11-sandbox-golden": "stopped"})
        run_dir = T / "run2"
        run_dir.mkdir(exist_ok=True)
        live, timing = {}, {}
        saved = lane.GUEST_TIMEOUT_S
        lane.GUEST_TIMEOUT_S = 3
        try:
            with self.assertRaises(TimeoutError):
                lane.run_guest("20261115T020000-abcdef", run_dir, T, T, [], live, timing, T)
        finally:
            lane.GUEST_TIMEOUT_S = saved
        vm = timing["vm"]
        self.assertEqual(json.loads(state.read_text()), {"c11-sandbox-golden": "stopped"})
        self.assertIn(["delete", vm], tart_calls(calls))
        self.assertNotIn("vm", live)
        self.assertFalse((lane.claims_dir() / f"{vm}.json").exists())


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        TMP.cleanup()
