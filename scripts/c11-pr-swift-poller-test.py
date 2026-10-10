#!/usr/bin/env python3
"""Hermetic behaviour tests for the c11 PR Swift poller. No Atlas, no network."""

from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("c11_pr_swift_poller", ROOT / "c11-pr-swift-poller.py")
poller = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(poller)

SHA_A = "a" * 40
SHA_B = "b" * 40
GITLINK = "c" * 40


def pr(number=7, sha=SHA_A, ref="feature", repo=poller.REPO_ID, name=poller.REPO_NAME,
       state="open", repo_value="present", number_value="present"):
    obj = {
        "state": state,
        "head": {
            "sha": sha,
            "ref": ref,
            "repo": {"id": repo, "full_name": name},
        },
        "base": {
            "sha": "d" * 40,
            "ref": "main",
            "repo": {"id": repo, "full_name": name},
        },
    }
    if number_value == "present":
        obj["number"] = number
    elif number_value != "missing":
        obj["number"] = number_value
    if repo_value is None:
        obj["head"]["repo"] = None
        obj["base"]["repo"] = None
    elif repo_value != "present":
        obj["head"]["repo"] = repo_value
        obj["base"]["repo"] = repo_value
    return obj


class Result:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class World:
    def __init__(self, body=None, status=200, headers=None):
        self.body = [] if body is None else body
        self.http_status = status
        self.headers = {} if headers is None else dict(headers)
        self.pull_body = None
        self.tip = SHA_A
        self.ref = "feature"
        self.guest_names = []
        self.held_slots = set()
        self.now = 1_000_000.0
        self.mono = 0.0
        self.sleeps = []
        self.lists = 0
        self.page_urls = []
        self.pages = {}
        self.git_args = []
        self.spawned = []
        self.posts = []
        self.exits = [0]
        self.last_exit = 0
        self.build_log = "HealthFlagsTests\n** TEST SUCCEEDED **\nExecuted 2 tests\n"
        self.worktree = "/work"
        self.statuses = {}
        self.kill_log = []
        self.alive = {}
        self.scope = True
        self.toolchain = True
        self.kit = "ok"

    def time(self):
        return self.now

    def monotonic(self):
        return self.mono

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds
        self.mono += seconds

    def list_page(self, headers):
        self.lists += 1
        self.list_headers = headers
        return {"status": self.http_status, "headers": dict(self.headers), "body": self.body}

    def list_page_url(self, url):
        self.page_urls.append(url)
        return self.pages[url]

    def pull(self, number):
        if self.pull_body is not None:
            return self.pull_body
        for obj in self.body:
            if type(obj) is dict and obj.get("number") == number:
                return obj
        return None

    def ls_remote(self, ref):
        return "%s\trefs/heads/%s\n" % (self.tip, ref)

    def guests(self):
        return list(self.guest_names)

    def slot_held(self, number):
        return number in self.held_slots

    def group_alive(self, pgid):
        if pgid in self.alive:
            return self.alive[pgid]
        return poller.group_alive(pgid)

    def killpg(self, pgid, sig):
        self.kill_log.append((pgid, sig))
        if pgid in self.alive and sig == signal.SIGKILL:
            self.alive[pgid] = False
        elif pgid not in self.alive:
            os.killpg(pgid, sig)

    def git(self, args, cwd):
        poller.assert_git_args(args)
        self.git_args.append((list(args), str(cwd)))
        if args[0] == "rev-parse" and args[1] == "HEAD":
            if str(cwd) != str(self.worktree):
                return Result(0, GITLINK + "\n")
            return Result(0, SHA_A + "\n")
        if args[0] == "rev-parse" and ":" in args[1]:
            return Result(0, GITLINK + "\n")
        if args[0] == "status":
            return Result(0, self.statuses.get(str(cwd), ""))
        return Result(0, "")

    def status(self, cwd):
        return self.statuses.get(str(cwd), "")

    def ghosttykit(self, sha):
        return self.kit

    def toolchain_ok(self):
        return self.toolchain

    def build_argv(self, worktree, derived, result):
        return poller.xcodebuild_argv(worktree, derived, result)

    def spawn(self, command):
        self.spawned.append(command)
        code = self.exits.pop(0) if self.exits else 0
        return code

    def post_status(self, body):
        self.posts.append(body)

    def scope_ok(self):
        return self.scope


def run(world, root):
    supervisor = poller.Supervisor(root, world)
    outcome = supervisor.poll_once()
    return supervisor, outcome


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_rejected_objects_do_not_fetch_or_build(self):
        samples = {
            "fork-id": pr(repo=9),
            "fork-name": pr(name="someone/c11"),
            "null-repo": pr(repo_value=None),
            "bool-id": pr(repo=True),
            "string-id": pr(repo="1212901838"),
            "bool-number": pr(number_value=True),
            "missing-number": pr(number_value="missing"),
            "push-event": {"ref": "refs/heads/main", "after": SHA_A},
            "pull-merge-ref": pr(ref="refs/pull/1/merge"),
            "closed": pr(state="closed"),
        }
        for name, obj in samples.items():
            with self.subTest(name=name):
                world = World(body=[obj])
                supervisor, _outcome = run(world, self.root / name)
                self.assertEqual(supervisor.fetches, [], name)
                self.assertEqual(supervisor.spawns, [], name)

    def test_force_push_before_ls_remote_keeps_captured_sha(self):
        world = World(body=[pr(sha=SHA_A)])
        world.pull_body = pr(sha=SHA_A)
        world.tip = SHA_B
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "superseded")
        self.assertEqual(supervisor.fetches, [])
        self.assertEqual(supervisor.spawns, [])
        logged = (self.root / "state" / "decisions.jsonl").read_text()
        self.assertIn(SHA_A, logged)
        self.assertNotIn(SHA_B, logged)

    def test_force_push_after_ls_remote_still_fetches_captured_sha(self):
        world = World(body=[pr(sha=SHA_A)])
        world.tip = SHA_A
        supervisor, _outcome = run(world, self.root)
        fetched = [args for args, _cwd in world.git_args if args[0] == "fetch"]
        parent = [args for args in fetched if poller.PARENT_URL in args]
        self.assertEqual(len(parent), 1)
        self.assertIn(SHA_A, parent[0])
        for args in fetched:
            self.assertNotIn(SHA_B, args)
        self.assertEqual(supervisor.spawns[0]["sha"], SHA_A)

    def test_closure_while_queued_does_not_fetch(self):
        world = World(body=[pr()])
        world.guest_names = ["c11-sb-held"]
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-start")
        self.assertEqual(supervisor.fetches, [])
        supervisor.not_before = 0
        world.guest_names = []
        world.body = []
        world.pull_body = {"status": 404}
        supervisor.poll_once()
        self.assertEqual(supervisor.fetches, [])
        self.assertEqual(supervisor.spawns, [])

    def test_repo_change_while_queued_does_not_fetch(self):
        world = World(body=[pr()])
        world.guest_names = ["c11-sb-held"]
        supervisor, _outcome = run(world, self.root)
        supervisor.not_before = 0
        world.guest_names = []
        world.body = []
        world.pull_body = pr(repo=9)
        supervisor.poll_once()
        self.assertEqual(supervisor.fetches, [])
        self.assertEqual(supervisor.spawns, [])

    def test_304_without_a_valid_body_builds_nothing_and_clears_etag(self):
        world = World(status=304, headers={"ETag": '"abc"'})
        store = self.root / "state"
        store.mkdir()
        (store / "list.json").write_text('{"etag": "\\"abc\\""}\n')
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "etag-cleared")
        self.assertFalse((store / "list.json").exists())
        self.assertEqual(supervisor.spawns, [])

    def test_304_with_a_stored_body_reuses_it(self):
        world = World(status=304, headers={"ETag": '"abc"', "X-RateLimit-Remaining": "4000"})
        poller.save_list_store(self.root / "state" / "list.json", '"abc"', [pr()])
        world.pull_body = pr()
        supervisor, _outcome = run(world, self.root)
        self.assertEqual(supervisor.spawns[0]["sha"], SHA_A)

    def test_pagination_stops_at_ten_and_does_not_treat_absence_as_closure(self):
        first = pr(number=1)
        headers = {"Link": '<https://example.test/pulls?page=2>; rel="next"'}
        world = World(body=[first], headers=headers)
        for page in range(2, 12):
            link = ""
            if page < 11:
                link = '<https://example.test/pulls?page=%s>; rel="next"' % (page + 1)
            world.pages["https://example.test/pulls?page=%s" % page] = {
                "status": 200,
                "headers": {"Link": link} if link else {},
                "body": [pr(number=page)],
            }
        world.guest_names = ["c11-sb-held"]
        supervisor, _outcome = run(world, self.root)
        self.assertEqual(len(world.page_urls), 9)
        self.assertNotIn("https://example.test/pulls?page=11", world.page_urls)
        text = (self.root / "state" / "decisions.jsonl").read_text()
        self.assertIn("pr_list_truncated", text)
        supervisor.not_before = 0
        world.body = [pr(number=2)]
        world.headers = {}
        world.pages = {}
        world.guest_names = []
        world.pull_body = {"status": 404}
        supervisor.poll_once()
        self.assertEqual(supervisor.fetches, [])
        self.assertTrue(any(item.get("decision") == "revoked" for item in _decisions(self.root)))

    def test_inverting_the_repo_id_guard_is_red_then_restored(self):
        foreign = pr(repo=999)
        world = World(body=[foreign])
        supervisor, _outcome = run(world, self.root / "green")
        self.assertEqual(supervisor.fetches, [])
        original = poller.REPO_ID
        try:
            poller.REPO_ID = 999
            red_world = World(body=[foreign])
            red, _outcome = run(red_world, self.root / "red")
            self.assertTrue(red.fetches)
            self.assertIn(poller.PARENT_URL, red.fetches[0])
        finally:
            poller.REPO_ID = original
        self.assertEqual(poller.REPO_ID, 1212901838)
        restored, _outcome = run(World(body=[foreign]), self.root / "restored")
        self.assertEqual(restored.fetches, [])


class CapacityAndRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_guest_present_does_not_start(self):
        world = World(body=[pr()])
        world.guest_names = ["c11-sb-demo"]
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-start")
        self.assertEqual(supervisor.spawns, [])
        self.assertEqual(supervisor.fetches, [])

    def test_held_slot_does_not_start(self):
        world = World(body=[pr()])
        world.held_slots.add(1)
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-start")
        self.assertEqual(supervisor.spawns, [])

    def test_guest_or_other_slot_mid_build_kills_and_posts_error(self):
        held = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            record = {"pgid": held.pid, "slot": 1, "sha": SHA_A, "pr": 7}
            world = World()
            world.guest_names = ["c11-sb-appeared"]
            supervisor = poller.Supervisor(self.root, world)
            reason = supervisor.watch(record)
            self.assertEqual(reason, "guest")
            self.assertEqual(held.wait(timeout=2), -signal.SIGTERM)
            self.assertEqual(world.posts[-1]["state"], "error")
            self.assertEqual(world.posts[-1]["description"], "yielded to Atlas work")
        finally:
            _kill(held.pid)

        held = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            record = {"pgid": held.pid, "slot": 1, "sha": SHA_A, "pr": 7}
            world = World()
            world.held_slots.add(2)
            supervisor = poller.Supervisor(self.root / "slot", world)
            reason = supervisor.watch(record)
            self.assertEqual(reason, "slot")
            self.assertEqual(held.wait(timeout=2), -signal.SIGTERM)
            self.assertEqual(world.posts[-1]["description"], "yielded to Atlas work")
        finally:
            _kill(held.pid)

    def test_watch_checks_every_five_seconds_until_the_build_exits(self):
        world = World()
        world.alive[4242] = True
        supervisor = poller.Supervisor(self.root, world)
        seen = {"n": 0}

        def running():
            seen["n"] += 1
            return seen["n"] <= 2

        reason = supervisor.watch_while(running, {"pgid": 4242, "slot": 1, "sha": SHA_A, "pr": 7})
        self.assertIsNone(reason)
        self.assertEqual(poller.YIELD_INTERVAL_S, 5)
        self.assertEqual(world.sleeps, [5, 5])
        self.assertEqual(world.posts, [])

    def test_watch_stops_when_a_guest_appears(self):
        world = World()
        world.alive[4242] = True
        supervisor = poller.Supervisor(self.root, world)
        seen = {"n": 0}

        def running():
            seen["n"] += 1
            if seen["n"] >= 2:
                world.guest_names = ["c11-sb-appeared"]
            return True

        reason = supervisor.watch_while(running, {"pgid": 4242, "slot": 1, "sha": SHA_A, "pr": 7})
        self.assertEqual(reason, "guest")
        self.assertEqual(world.sleeps, [5])
        self.assertEqual(world.posts[-1]["state"], "error")
        self.assertEqual(world.posts[-1]["description"], "yielded to Atlas work")
        self.assertEqual(world.kill_log[-1], (4242, signal.SIGTERM))

    def test_free_lock_clears_a_dead_group_only(self):
        dead = subprocess.Popen(["sleep", "30"], start_new_session=True)
        dead.kill()
        dead.wait(timeout=5)
        poller.write_running(self.root, {"pgid": dead.pid, "attempt_id": "a", "invocation": 1})
        self.assertEqual(poller.recover(self.root), "ready")
        self.assertFalse(poller.running_path(self.root).exists())

    def test_held_lock_without_a_pgid_stays_stuck_and_does_not_poll(self):
        lock = self.root / "state" / "running.lock"
        lock.parent.mkdir(parents=True)
        holder = subprocess.Popen(
            [sys.executable, "-c", textwrap.dedent("""
                import fcntl, os, time, sys
                fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
                fcntl.flock(fd, fcntl.LOCK_EX)
                time.sleep(30)
            """), str(lock)],
        )
        try:
            time.sleep(0.2)
            world = World(body=[pr()])
            supervisor, outcome = run(world, self.root)
            self.assertEqual(outcome, "stuck")
            self.assertEqual(world.lists, 0)
            self.assertEqual(supervisor.spawns, [])
            self.assertTrue(supervisor.disarmed)
        finally:
            holder.kill()
            holder.wait(timeout=5)

    def test_kill_uses_term_then_kill_after_ten_seconds(self):
        clock = {"now": 0.0}
        signals = []

        def alive(_pgid):
            return signal.SIGKILL not in [item[1] for item in signals]

        def kill(pgid, sig):
            signals.append((clock["now"], sig))

        def sleep(seconds):
            clock["now"] += seconds

        gone = poller.kill_until_esrch(4321, alive, kill, sleep, lambda: clock["now"], 10, 60)
        self.assertTrue(gone)
        self.assertEqual(signals[0][1], signal.SIGTERM)
        self.assertGreaterEqual(signals[1][0], 10)
        self.assertEqual(signals[1][1], signal.SIGKILL)

    def test_group_that_survives_the_budget_stays_stuck_without_clearing(self):
        poller.write_running(self.root, {"pgid": 4242, "attempt_id": "a", "invocation": 1})
        clock = {"now": 0.0}
        outcome = poller.recover(
            self.root,
            alive=lambda _pgid: True,
            kill=lambda *_: None,
            sleep=lambda seconds: clock.__setitem__("now", clock["now"] + seconds),
            monotonic=lambda: clock["now"],
            term_grace=10,
            budget=60,
        )
        self.assertEqual(outcome, "stuck")
        self.assertTrue(poller.running_path(self.root).exists())

    def test_descendant_survives_a_free_lock_until_esrch(self):
        state = self.root / "state"
        state.mkdir()
        current = {
            "attempt_id": "attempt",
            "invocation": 1,
            "pr": 7,
            "sha": SHA_A,
            "ref": "feature",
        }
        (state / "current.json").write_text(json.dumps(current))
        (self.root / "harness.json").write_text(json.dumps({
            "pr": pr(),
            "ls_remote": "%s\trefs/heads/feature\n" % SHA_A,
        }))
        launcher = self.root / "launcher.py"
        grandchild = self.root / "grandchild.py"
        marker = self.root / "held.json"
        grand_pid = self.root / "grand.pid"
        launcher.write_text(textwrap.dedent("""
            import json, os, subprocess, sys, time
            want = os.stat(sys.argv[1])
            found = None
            for number in range(3, 256):
                try:
                    info = os.fstat(number)
                except OSError:
                    continue
                if info.st_ino == want.st_ino and info.st_dev == want.st_dev:
                    found = number
                    break
            if found is None:
                sys.exit("lock fd was not inherited across exec")
            os.read(found, 0)
            open(sys.argv[2], "w").write(json.dumps({"fd": found, "pgid": os.getpgrp()}))
            subprocess.Popen([sys.executable, sys.argv[3], sys.argv[4]], close_fds=True)
            while True:
                time.sleep(30)
        """))
        grandchild.write_text(textwrap.dedent("""
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            open(sys.argv[1], "w").write("%s %s" % (os.getpid(), os.getpgrp()))
            while True:
                time.sleep(30)
        """))
        env = dict(os.environ)
        env["C11_POLLER_TEST"] = "1"
        child = subprocess.Popen(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "child",
             "--root", str(self.root), "--exec", sys.executable, str(launcher), str(state / "running.lock"), str(marker), str(grandchild), str(grand_pid)],
            env=env,
        )
        supervisor = subprocess.Popen(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "hold-supervisor", "--root", str(self.root)],
            env=env,
        )
        try:
            _wait_for(marker)
            held = json.loads(marker.read_text())
            self.assertGreater(held["fd"], 2)
            self.assertFalse(poller.lock_is_free(state / "running.lock"))
            _wait_for(grand_pid)
            grand = int(grand_pid.read_text().split()[0])
            grand_pgid = int(grand_pid.read_text().split()[1])
            recorded = poller.read_running(self.root)
            self.assertEqual(recorded["pgid"], held["pgid"])
            os.kill(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
            os.kill(supervisor.pid, signal.SIGTERM)
            supervisor.wait(timeout=5)
            self.assertTrue(poller.lock_is_free(state / "running.lock"))
            self.assertTrue(_alive(grand))
            self.assertTrue(poller.running_path(self.root).exists())
            quiet = World(body=[pr()], headers={"X-RateLimit-Remaining": "4000"})
            quiet.alive[recorded["pgid"]] = True

            def quiet_kill(pgid, sig, _quiet=quiet):
                _quiet.kill_log.append((pgid, sig))

            quiet.killpg = quiet_kill
            restarted, outcome = run(quiet, self.root)
            self.assertEqual(outcome, "stuck")
            self.assertEqual(restarted.fetches, [])
            self.assertEqual(restarted.spawns, [])
            self.assertEqual(poller.read_running(self.root)["pgid"], recorded["pgid"])
            self.assertEqual(grand_pgid, recorded["pgid"])
            self.assertTrue(_alive(grand))
            self.assertTrue(poller.group_alive(recorded["pgid"]))
            prior = len(_events(self.root))
            restart = subprocess.Popen(
                [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "recover", "--root", str(self.root)],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            # The in-process restart already logged probe-alive. Wait for the
            # CLI's own probe, then kill the grandchild. Clearing before that
            # probe is the failure this fixture exists to catch.
            _wait_for_event(self.root, "probe-alive", after=prior)
            fresh = _events(self.root)[prior:]
            self.assertNotIn("cleared", fresh)
            self.assertNotIn("cleared-stale", fresh)
            self.assertTrue(poller.running_path(self.root).exists())
            self.assertEqual(poller.read_running(self.root)["pgid"], recorded["pgid"])
            self.assertTrue(_alive(grand))
            os.kill(grand, signal.SIGKILL)
            try:
                out, err = restart.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                restart.kill()
                out, err = restart.communicate()
                self.fail("recover did not finish after the grandchild died: %s %s" % (out, err))
            self.assertEqual(restart.returncode, 0, err)
            self.assertEqual(out.strip(), "ready")
            self.assertFalse(_alive(grand))
            self.assertFalse(poller.running_path(self.root).exists())
            self.assertIn("cleared", _events(self.root)[prior:])
            self.assertNotIn("cleared-stale", _events(self.root)[prior:])
        finally:
            for proc in (child, supervisor):
                if proc.poll() is None:
                    proc.kill()
            if grand_pid.exists():
                text = grand_pid.read_text().split()
                if text:
                    _kill(int(text[0]))

    def test_child_does_not_exec_when_the_second_revalidate_moves(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current.json").write_text(json.dumps({
            "attempt_id": "attempt", "invocation": 1, "pr": 7, "sha": SHA_A, "ref": "feature",
        }))
        (self.root / "harness.json").write_text(json.dumps({
            "pr": pr(sha=SHA_A),
            "ls_remote": "%s\trefs/heads/feature\n" % SHA_B,
        }))
        sentinel = self.root / "should-not-run"
        env = dict(os.environ)
        env["C11_POLLER_TEST"] = "1"
        result = subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "child", "--root", str(self.root),
             "--exec", sys.executable, "-c", "open(%r,'w').write('ran')" % str(sentinel)],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 3)
        self.assertFalse(sentinel.exists())
        self.assertNotIn("pending", _events(self.root))

    def test_spawn_goes_through_atlas_build_slots(self):
        world = World(body=[pr()])
        supervisor, _outcome = run(world, self.root)
        command = supervisor.spawns[0]["command"]
        self.assertEqual(Path(command[1]).name, "atlas_build_slots.py")
        self.assertEqual(command[2], "fu-371r")
        self.assertIn("child", command)
        slots = tempfile.TemporaryDirectory()
        try:
            env = dict(os.environ)
            env["C11_ATLAS_SLOTS_DIR"] = slots.name
            env["C11_ATLAS_SLOT_POLL_SECONDS"] = "0.1"
            result = subprocess.run(
                [sys.executable, str(ROOT / "atlas_build_slots.py"), "fu-371r", sys.executable, "-c", "print('slot-child')"],
                env=env, capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[atlas-slots] acquired slot=", result.stdout)
            self.assertIn("slot-child", result.stdout)
        finally:
            slots.cleanup()

    def test_cache_retry_uses_a_fresh_directory(self):
        world = World(body=[pr()])
        world.exits = [1, 0]
        world.build_log = "failed\n"
        supervisor, _outcome = run(world, self.root)
        self.assertEqual(len(supervisor.spawns), 2)
        self.assertNotEqual(supervisor.spawns[0]["result"], supervisor.spawns[1]["result"])
        self.assertTrue(supervisor.spawns[0]["result"].endswith("-1"))
        self.assertTrue(supervisor.spawns[1]["result"].endswith("-2"))
        with self.assertRaises(FileExistsError):
            first = Path(supervisor.spawns[0]["result"])
            first.mkdir(parents=True)
            attempt_id = first.name.rsplit("-", 1)[0]
            poller.result_directory(self.root / "state", attempt_id, 1)


class WorkspaceTests(unittest.TestCase):
    def test_submodule_residue_skips_and_clean_removes_it(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            parent, sub = _git_pair(Path(tmp.name))
            planted = parent / "ghostty" / "untracked.txt"
            planted.write_text("dirt\n")
            dirty = poller.porcelain_paths(poller.run_git(
                ["status", "--porcelain=v1", "--ignored"], parent / "ghostty").stdout)
            self.assertFalse(poller.residue_ok([], [dirty], False))
            self.assertTrue(poller.clean_worktree(poller.run_git, parent))
            self.assertFalse(planted.exists())
            parent_status = poller.porcelain_paths(poller.run_git(
                ["status", "--porcelain=v1", "--ignored"], parent).stdout)
            sub_status = poller.porcelain_paths(poller.run_git(
                ["status", "--porcelain=v1", "--ignored"], parent / "ghostty").stdout)
            self.assertTrue(poller.residue_ok(parent_status, [sub_status], False))
            self.assertTrue(sub.exists())
        finally:
            tmp.cleanup()

    def test_ghosttykit_rejects_a_path_outside_the_cache(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            cache = Path(tmp.name) / "cache"
            outside = Path(tmp.name) / "outside"
            kit = outside / "GhosttyKit.xcframework"
            kit.mkdir(parents=True)
            link = cache / ("a" * 40)
            link.mkdir(parents=True)
            (link / "GhosttyKit.xcframework").symlink_to(kit)
            work = Path(tmp.name) / "work"
            work.mkdir()
            self.assertEqual(poller.link_ghosttykit(cache, "a" * 40, work), "ghosttykit_missing")
            real = cache / ("b" * 40) / "GhosttyKit.xcframework"
            real.mkdir(parents=True)
            self.assertEqual(poller.link_ghosttykit(cache, "b" * 40, work), "ok")
        finally:
            tmp.cleanup()


class PollingAndCredentialTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_retry_after_is_uncapped_and_builds_nothing(self):
        world = World(status=429, headers={"Retry-After": "7200", "X-RateLimit-Remaining": "0"})
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-build")
        self.assertEqual(supervisor.spawns, [])
        self.assertGreaterEqual(supervisor.not_before - 1_000_000, 7200)
        lists = world.lists
        supervisor.poll_once()
        self.assertEqual(world.lists, lists)
        self.assertEqual(world.sleeps[-1], 7200)

    def test_low_remaining_backs_off_until_reset(self):
        world = World(
            body=[pr(), pr(number=8), pr(number=9)],
            headers={"X-RateLimit-Remaining": "1", "X-RateLimit-Reset": "1005000"},
        )
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "backoff")
        self.assertEqual(supervisor.fetches, [])
        self.assertEqual(supervisor.spawns, [])
        self.assertGreaterEqual(supervisor.not_before, 1_005_000)

    def test_authenticated_remaining_does_not_wait_just_because_the_bucket_is_small(self):
        world = World(
            body=[pr()],
            headers={"X-RateLimit-Limit": "60", "X-RateLimit-Remaining": "59", "X-RateLimit-Reset": "1005000"},
        )
        supervisor, _outcome = run(world, self.root)
        self.assertTrue(supervisor.spawns)
        self.assertLess(supervisor.not_before, 1_005_000)

    def test_scope_must_be_exactly_c11_and_rotation_keeps_the_old_key(self):
        self.assertFalse(poller.scope_exact([]))
        self.assertFalse(poller.scope_exact([
            {"id": poller.REPO_ID, "full_name": poller.REPO_NAME},
            {"id": 1, "full_name": "other/repo"},
        ]))
        self.assertFalse(poller.scope_exact([{"id": True, "full_name": poller.REPO_NAME}]))
        self.assertTrue(poller.scope_exact([{"id": poller.REPO_ID, "full_name": poller.REPO_NAME}]))
        keys = self.root / "keys"
        keys.mkdir()
        (keys / "private-key.pem").write_text("old\n")
        (keys / "private-key.pem.new").write_text("new\n")
        seen = []

        def authenticates(path):
            seen.append(path.name)
            return path.name == "private-key.pem.new"

        self.assertEqual(poller.rotate_swap(keys, authenticates), "swapped")
        self.assertEqual((keys / "private-key.pem").read_text(), "new\n")
        self.assertEqual((keys / "private-key.pem.old").read_text(), "old\n")
        with self.assertRaises(RuntimeError):
            poller.rotate_drop_old(keys, lambda _path: True)
        self.assertTrue((keys / "private-key.pem.old").exists())
        self.assertEqual(poller.rotate_drop_old(keys, lambda _path: False), "dropped")
        self.assertFalse((keys / "private-key.pem.old").exists())

    def test_teardown_follows_recorded_stages(self):
        actor = Actor()
        unknown = poller.teardown(["app_installed", "mystery"], actor)
        self.assertEqual(unknown["action"], "reconcile")
        self.assertEqual(actor.calls, [])
        actor.absence = False
        stopped = poller.teardown(["app_installed", "key_placed"], actor)
        self.assertEqual(stopped["action"], "stop")
        self.assertNotIn("remove_key", actor.calls)
        actor = Actor()
        done = poller.teardown(["plist_installed", "key_placed"], actor)
        self.assertEqual(done["action"], "done")
        self.assertNotIn("uninstall_app", actor.calls)
        self.assertIn("remove_key", actor.calls)
        actor = Actor()
        done = poller.teardown(["plist_installed", "app_installed", "key_placed"], actor)
        self.assertEqual(actor.calls, [
            "bootout", "processes_gone", "remove_plist", "uninstall_app", "absence_ok", "remove_key",
            "remove_local_state",
        ])

    def test_plist_template_is_not_bootstrapped(self):
        text = (ROOT / "launchd" / "com.stage11.c11-pr-swift-poller.plist.in").read_text()
        self.assertIn("@HOME@", text)
        rendered = poller.render_plist("/Users/example")
        self.assertNotIn("@HOME@", rendered)
        self.assertIn("com.stage11.c11-pr-swift-poller", rendered)
        self.assertIn("/Users/example/c11-poller", rendered)
        result = subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "supervise", "--root", str(self.root)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not armed", result.stderr)

    def test_poller_path_inside_the_worktree_is_refused(self):
        self.assertTrue(poller.layout_inside_worktree("/tmp/work/bin/poller.py", "/tmp/work"))
        self.assertFalse(poller.layout_inside_worktree("/tmp/c11-poller/bin/poller.py", "/tmp/work"))

    def test_status_description_and_budget(self):
        state, description = poller.classify_result(
            "HealthFlagsTests\n** TEST SUCCEEDED **\nExecuted 1 test\n", 15)
        self.assertEqual((state, description), ("success", "15s"))
        state, description = poller.classify_result(
            "HealthFlagsTests\n** TEST SUCCEEDED **\nExecuted 1 test\n", 121)
        self.assertEqual(state, "failure")
        self.assertEqual(description, "budget 121s")
        body = poller.status_body(SHA_A, "error", "yielded to Atlas work")
        self.assertLessEqual(len(body["description"]), 140)
        self.assertEqual(body["context"], "c11/pr-swift")

    def test_second_supervisor_does_not_poll(self):
        world = World(body=[pr()])
        first = poller.Supervisor(self.root, world)
        held = first.hold_supervisor_lock()
        self.assertIsNotNone(held)
        try:
            second, outcome = run(world, self.root)
            self.assertEqual(outcome, "busy")
            self.assertEqual(world.lists, 0)
            self.assertEqual(second.spawns, [])
        finally:
            os.close(held)

    def test_running_guest_parse(self):
        text = "Source Name Status\nlocal c11-sb-one running\nlocal c11-sb-two stopped\nlocal other running\n"
        self.assertEqual(poller.running_guests(text), ["c11-sb-one"])

    def test_timeout_builds_nothing_without_disarming(self):
        world = World(status=0)
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-build")
        self.assertEqual(supervisor.spawns, [])
        self.assertFalse(supervisor.disarmed)

    def test_unauthorized_builds_nothing_and_disarms(self):
        world = World(status=401)
        supervisor, outcome = run(world, self.root)
        self.assertEqual(outcome, "no-build")
        self.assertEqual(supervisor.spawns, [])
        self.assertTrue(supervisor.disarmed)

    def test_child_without_the_harness_does_not_exec(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current.json").write_text(json.dumps({
            "attempt_id": "attempt", "invocation": 1, "pr": 7, "sha": SHA_A, "ref": "feature",
        }))
        sentinel = self.root / "should-not-run"
        env = dict(os.environ)
        env.pop("C11_POLLER_TEST", None)
        env["HOME"] = str(self.root)
        result = subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "child", "--root", str(self.root),
             "--exec", sys.executable, "-c", "open(%r,'w').write('ran')" % str(sentinel)],
            env=env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(sentinel.exists())
        self.assertNotIn("pending", _events(self.root))

    def test_failed_pending_does_not_exec(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current.json").write_text(json.dumps({
            "attempt_id": "attempt", "invocation": 1, "pr": 7, "sha": SHA_A, "ref": "feature",
        }))
        sentinel = self.root / "should-not-run"
        driver = self.root / "driver.py"
        driver.write_text(textwrap.dedent("""
            import importlib.util, sys
            spec = importlib.util.spec_from_file_location("poller", sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            root, sentinel = sys.argv[2], sys.argv[3]
            code = module.child_main(
                root,
                [sys.executable, "-c", "open(%r, 'w').write('ran')" % sentinel],
                lambda _root: (True, "revalidated", None),
                lambda _current: False,
            )
            raise SystemExit(code)
        """))
        result = subprocess.run(
            [sys.executable, str(driver), str(ROOT / "c11-pr-swift-poller.py"), str(self.root), str(sentinel)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertNotIn("pending", _events(self.root))

    def test_pending_status_says_build_started(self):
        calls = []

        def transport(_method, url, _headers, body):
            calls.append({"url": url, "body": body})
            return {"status": 201, "headers": {}, "body": {}}

        client = poller.AppClient(1, 2, self.root / "unused.pem", transport, sign=lambda *_: b"sig")
        client.scoped = True
        client.narrowed_token = "narrowed"
        response = poller.post_build_pending(client, {"sha": SHA_A})
        self.assertEqual(response["status"], 201)
        self.assertEqual(calls[-1]["body"]["state"], "pending")
        self.assertEqual(calls[-1]["body"]["description"], "build started")
        self.assertEqual(calls[-1]["body"]["context"], "c11/pr-swift")
        self.assertNotIn("sha", calls[-1]["body"])
        self.assertTrue(calls[-1]["url"].endswith("/statuses/" + SHA_A))

    def test_build_env_omits_tokens_and_socket(self):
        os.environ["GITHUB_TOKEN"] = "secret-token"
        os.environ["C11_SOCKET"] = "/tmp/c11.sock"
        try:
            env = poller.build_env()
        finally:
            os.environ.pop("GITHUB_TOKEN", None)
            os.environ.pop("C11_SOCKET", None)
        self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn("GH_TOKEN", env)
        self.assertNotIn("C11_SOCKET", env)
        self.assertNotIn("C11_BUILD_LOCK", env)
        self.assertNotIn("secret-token", env.values())
        self.assertIn("DEVELOPER_DIR", env)

    def test_scope_token_is_unnarrowed_and_status_token_is_narrowed(self):
        key = self.root / "private-key.pem"
        subprocess.check_call(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(key)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        token = poller.mint_jwt(99, key, 1_700_000_000, poller.openssl_sign)
        header, payload, signature = token.split(".")
        claims = json.loads(poller.b64url_decode(payload))
        self.assertEqual(claims["iss"], "99")
        self.assertEqual(claims["exp"] - claims["iat"], 600)
        public = self.root / "public.pem"
        signature_file = self.root / "sig.bin"
        signature_file.write_bytes(poller.b64url_decode(signature))
        subprocess.check_call(
            ["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        verified = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signature_file)],
            input=("%s.%s" % (header, payload)).encode(),
            capture_output=True,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

        calls = []
        minted = {"n": 0}

        def transport(method, url, headers, body):
            calls.append({"method": method, "url": url, "headers": headers, "body": body})
            if url.endswith("/access_tokens"):
                minted["n"] += 1
                name = "unscoped" if body == {} else "narrowed-%s" % minted["n"]
                return {"status": 201, "headers": {}, "body": {"token": name}}
            if url.endswith("/installation/repositories?per_page=100"):
                if calls[-1]["headers"]["Authorization"] != "Bearer unscoped":
                    return {"status": 401, "headers": {}, "body": {}}
                return {"status": 200, "headers": {}, "body": {
                    "total_count": 1,
                    "repositories": [{"id": poller.REPO_ID, "full_name": poller.REPO_NAME}],
                }}
            if url.endswith("/statuses/" + SHA_A):
                return {"status": 201, "headers": {}, "body": {"state": body["state"]}}
            return {"status": 500, "headers": {}, "body": {}}

        env_token = "ghp_should_not_be_sent"
        os.environ["GITHUB_TOKEN"] = env_token
        try:
            client = poller.AppClient(99, 7, key, transport, now=lambda: 1_700_000_000, sign=lambda data, _path: poller.openssl_sign(data, key))
            self.assertTrue(client.verify_scope())
            self.assertEqual(client.mints[0], {})
            self.assertNotIn("repositories", client.mints[0])
            self.assertNotIn("permissions", client.mints[0])
            self.assertEqual(client.mints[1], {"repositories": ["c11"]})
            posted = client.post_status_body({"sha": SHA_A, "state": "success", "description": "15s"})
            self.assertEqual(posted["status"], 201)
            self.assertNotIn("sha", calls[-1]["body"])
            self.assertEqual(calls[-1]["headers"]["Authorization"], "Bearer narrowed-2")
            for call in calls:
                self.assertNotIn(env_token, call["headers"].get("Authorization", ""))
                if "/app/installations/" in call["url"]:
                    self.assertTrue(call["url"].endswith("/access_tokens"))
                    self.assertEqual(call["method"], "POST")
        finally:
            os.environ.pop("GITHUB_TOKEN", None)

        self.assertRaises(poller.ScopeStop, poller.AppClient.from_config, self.root / "missing")

    def test_expired_token_mints_once(self):
        seen = {"mints": 0, "lists": 0}

        def transport(method, url, headers, body):
            if url.endswith("/access_tokens"):
                seen["mints"] += 1
                return {"status": 201, "headers": {}, "body": {"token": "tok-%s" % seen["mints"]}}
            if "/pulls/" in url:
                seen["lists"] += 1
                if seen["lists"] == 1:
                    return {"status": 401, "headers": {}, "body": {}}
                if seen["lists"] == 2:
                    return {"status": 200, "headers": {}, "body": pr()}
                return {"status": 401, "headers": {}, "body": {}}
            return {"status": 500, "headers": {}, "body": {}}

        client = poller.AppClient(1, 2, self.root / "unused.pem", transport, sign=lambda *_: b"sig")
        client.scoped = True
        client.narrowed_token = "stale"
        first = client.pull(7)
        self.assertEqual(first["status"], 200)
        self.assertEqual(seen["mints"], 1)
        second = client.pull(7)
        self.assertEqual(second["status"], 401)
        self.assertEqual(seen["mints"], 1)


class Actor:
    def __init__(self):
        self.calls = []
        self.absence = True
        self.gone = True

    def bootout(self):
        self.calls.append("bootout")

    def processes_gone(self):
        self.calls.append("processes_gone")
        return self.gone

    def remove_plist(self):
        self.calls.append("remove_plist")

    def uninstall_app(self):
        self.calls.append("uninstall_app")

    def absence_ok(self):
        self.calls.append("absence_ok")
        return self.absence

    def remove_key(self):
        self.calls.append("remove_key")

    def remove_local_state(self):
        self.calls.append("remove_local_state")


def _decisions(root):
    path = Path(root) / "state" / "decisions.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def _events(root):
    path = Path(root) / "state" / "events.jsonl"
    if not path.exists():
        return []
    return [json.loads(line)["event"] for line in path.read_text().splitlines() if line]


def _wait_for(path, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if Path(path).exists() and Path(path).stat().st_size > 0:
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for %s" % path)


def _wait_for_event(root, name, timeout=10, after=0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if name in _events(root)[after:]:
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for %s in %s" % (name, _events(root)[after:]))


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _kill(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _git_pair(tmp):
    parent = tmp / "parent"
    sub = tmp / "sub"
    for path in (parent, sub):
        path.mkdir()
        subprocess.check_call(["git", "init"], cwd=path, stdout=subprocess.DEVNULL)
        subprocess.check_call(["git", "config", "user.email", "t@example.com"], cwd=path)
        subprocess.check_call(["git", "config", "user.name", "t"], cwd=path)
    (sub / "f").write_text("s\n")
    subprocess.check_call(["git", "add", "f"], cwd=sub)
    subprocess.check_call(["git", "commit", "-m", "s"], cwd=sub, stdout=subprocess.DEVNULL)
    (parent / "README").write_text("p\n")
    subprocess.check_call(["git", "add", "README"], cwd=parent)
    subprocess.check_call(["git", "commit", "-m", "p"], cwd=parent, stdout=subprocess.DEVNULL)
    subprocess.check_call(
        ["git", "-c", "protocol.file.allow=always", "submodule", "add", str(sub), "ghostty"],
        cwd=parent, stdout=subprocess.DEVNULL,
    )
    subprocess.check_call(["git", "commit", "-m", "sub"], cwd=parent, stdout=subprocess.DEVNULL)
    return parent, sub


if __name__ == "__main__":
    unittest.main(verbosity=2)
