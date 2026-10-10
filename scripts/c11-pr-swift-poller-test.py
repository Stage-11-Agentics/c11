#!/usr/bin/env python3
"""Hermetic behaviour tests for the c11 PR Swift poller. No Atlas, no network."""

from __future__ import annotations

import hashlib
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
import unittest.mock
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
        self.reported = {}
        self.head = SHA_A
        self.sub_heads = {}
        self.gitlinks = {}
        self.missing_kits = set()
        self.tips = {}
        self.fail_fetch = set()
        self.resolved = {}

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
        return "%s\trefs/heads/%s\n" % (self.tips.get(ref, self.tip), ref)

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
            try:
                os.killpg(pgid, sig)
            except (ProcessLookupError, PermissionError):
                pass

    def git(self, args, cwd):
        poller.assert_git_args(args)
        self.git_args.append((list(args), str(cwd)))
        if args[0] == "fetch" and self.fail_fetch.intersection(args):
            return Result(1, "")
        if args[0] == "show":
            return Result(0, self.resolved.get(args[1].split(":", 1)[0], ""))
        if args[0] == "checkout":
            self.head = args[-1]
        if args[0] == "reset" and len(args) > 2:
            self.sub_heads[str(cwd)] = args[2]
        if args[0] == "rev-parse" and args[1] == "HEAD":
            if str(cwd) != str(self.worktree):
                return Result(0, self.sub_heads.get(str(cwd), GITLINK) + "\n")
            return Result(0, self.head + "\n")
        if args[0] == "rev-parse" and ":" in args[1]:
            sha, path = args[1].split(":", 1)
            gitlink = self.gitlinks.get(sha, GITLINK) if path == "ghostty" else GITLINK
            return Result(0, gitlink + "\n")
        if args[0] == "status":
            return Result(0, self.statuses.get(str(cwd), ""))
        return Result(0, "")

    def status(self, cwd):
        return self.statuses.get(str(cwd), "")

    def ghosttykit(self, gitlink):
        if gitlink in self.missing_kits:
            return "ghosttykit_missing"
        return self.kit

    def kit_available(self, gitlink):
        return gitlink not in self.missing_kits

    def toolchain_ok(self):
        return self.toolchain

    def build_argv(self, worktree, derived, result):
        return poller.xcodebuild_argv(worktree, derived, result)

    def spawn(self, command, log_path=None):
        self.spawned.append(command)
        code = self.exits.pop(0) if self.exits else 0
        return code

    def post_status(self, body):
        self.posts.append(body)
        return {"status": 201, "headers": {}, "body": {}}

    def head_status(self, sha):
        return self.reported.get(sha)

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
        self.assertEqual(outcome, "idle")
        self.assertIn("superseded", [item.get("decision") for item in _decisions(self.root)])
        self.assertEqual(supervisor.fetches, [])
        self.assertEqual(supervisor.spawns, [])
        logged = (self.root / "state" / "decisions.jsonl").read_text()
        self.assertIn(SHA_A, logged)
        self.assertNotIn(SHA_B, logged)

    def test_force_push_after_ls_remote_still_fetches_captured_sha(self):
        world = World(body=[pr(sha=SHA_A)])
        world.tip = SHA_A

        def ls_remote(ref, _world=world):
            text = "%s\trefs/heads/%s\n" % (_world.tip, ref)
            _world.tip = SHA_B
            return text

        world.ls_remote = ls_remote
        supervisor, _outcome = run(world, self.root)
        self.assertEqual(world.tip, SHA_B)
        fetched = [args for args, _cwd in world.git_args if args[0] == "fetch"]
        parent = [args for args in fetched if poller.PARENT_URL in args]
        self.assertEqual(len(parent), 1)
        self.assertIn(SHA_A, parent[0])
        self.assertNotIn(SHA_B, parent[0])
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
        self.assertEqual(world.sleeps[0], 5)
        self.assertEqual(world.posts[-1]["state"], "error")
        self.assertEqual(world.posts[-1]["description"], "yielded to Atlas work")
        self.assertEqual(world.kill_log[0], (4242, signal.SIGTERM))
        self.assertEqual(world.kill_log[-1], (4242, signal.SIGKILL))
        self.assertFalse(world.group_alive(4242))

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
        github = FakeGitHub(self.root)
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
        env = child_env(self.root, github)
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
        github = FakeGitHub(self.root)
        env = child_env(self.root, github, tip=SHA_B)
        sentinel = self.root / "should-not-run"
        result = subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "child", "--root", str(self.root),
             "--exec", sys.executable, "-c", "open(%r,'w').write('ran')" % str(sentinel)],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertNotIn("pending", _events(self.root))
        self.assertEqual(github.statuses(), [])

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
        import plistlib
        launch_path = plistlib.loads(rendered.encode())["EnvironmentVariables"]["PATH"].split(":")
        self.assertEqual(launch_path[0], "/opt/homebrew/bin")
        self.assertIn("/usr/bin", launch_path)
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

    def test_child_without_credentials_does_not_exec(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current.json").write_text(json.dumps({
            "attempt_id": "attempt", "invocation": 1, "pr": 7, "sha": SHA_A, "ref": "feature",
        }))
        sentinel = self.root / "should-not-run"
        env = dict(os.environ)
        env.pop("C11_POLLER_CONFIG_DIR", None)
        env.pop("C11_POLLER_FAKE_HTTP", None)
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
        self.assertEqual(seen["mints"], 2)
        self.assertEqual(seen["lists"], 4)
        third = client.pull(7)
        self.assertEqual(third["status"], 401)
        self.assertEqual(seen["mints"], 3)


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
        return True

    def remove_gh_config(self):
        self.calls.append("remove_gh_config")


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


APP_ID = 99
INSTALLATION_ID = 7
SUCCESS_BUILD = 'print("HealthFlagsTests"); print("Executed 1 test"); print("** TEST SUCCEEDED **")'
_KEY = {}


def _write_exec(path, text):
    path.write_text(textwrap.dedent(text).lstrip("\n"))
    path.chmod(0o755)


def disposable_key(dest):
    """One throwaway RSA key per test run, copied where the App config expects it."""
    if "pem" not in _KEY:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "key.pem"
            subprocess.check_call(
                ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            _KEY["pem"] = path.read_bytes()
    dest.write_bytes(_KEY["pem"])
    dest.chmod(0o600)


def route(method, match, *responses, suffix=False):
    entry = {"method": method, "responses": list(responses)}
    entry["suffix" if suffix else "url"] = match
    return entry


class FakeGitHub:
    """A disposable App config under HOME plus routes for poller.fixture_transport."""

    def __init__(self, root, prs=None):
        self.root = Path(root)
        self.dir = self.root / "http"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.config = self.root / ".config" / "c11-pr-swift"
        self.config.mkdir(parents=True, exist_ok=True)
        disposable_key(self.config / "private-key.pem")
        (self.config / "app.json").write_text(json.dumps({"app_id": APP_ID, "installation_id": INSTALLATION_ID}))
        self.routes = []
        self.set_prs([pr()] if prs is None else prs)

    def set_prs(self, prs, list_headers=None):
        headers = {"X-RateLimit-Remaining": "4000", "ETag": "\"list\""} if list_headers is None else list_headers
        self.routes = [
            route("POST", "/access_tokens", {"status": 201, "body": {"token": "fixture-installation-token"}}),
            route("GET", "/installation/repositories", {"status": 200, "body": {
                "total_count": 1,
                "repositories": [{"id": poller.REPO_ID, "full_name": poller.REPO_NAME}],
            }}),
            route("GET", "/pulls?state", {"status": 200, "headers": headers, "body": prs}),
        ]
        for obj in prs:
            self.routes.append(route("GET", "/pulls/%s" % obj["number"], {"status": 200, "body": obj}, suffix=True))
        self.routes += [
            route("GET", "/status", {"status": 200, "body": {"state": "pending", "statuses": []}}, suffix=True),
            route("POST", "/statuses/", {"status": 201, "body": {}}),
            route("GET", "/app", {"status": 200, "body": {"id": APP_ID}}, suffix=True),
            route("GET", "/app/installations?", {"status": 200, "body": [{"id": INSTALLATION_ID}]}),
            route("DELETE", "/app/installations/%s" % INSTALLATION_ID, {"status": 204, "body": None}, suffix=True),
        ]
        self.write()

    def put(self, method, match, *responses, suffix=False):
        """Replace the route with this method and match, or add it first."""
        key = "suffix" if suffix else "url"
        for index, item in enumerate(self.routes):
            if item.get("method") == method and item.get(key) == match:
                self.routes[index] = route(method, match, *responses, suffix=suffix)
                break
        else:
            self.routes.insert(0, route(method, match, *responses, suffix=suffix))
        self.write()

    def write(self):
        temporary = self.dir / "routes.json.tmp"
        temporary.write_text(json.dumps(self.routes))
        os.replace(temporary, self.dir / "routes.json")

    def requests(self):
        path = self.dir / "requests.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line]

    def statuses(self):
        return [(item["body"]["state"], item["body"]["description"])
                for item in self.requests() if item["method"] == "POST" and "/statuses/" in item["url"]]


def git_shim(root, worktree, tip=SHA_A):
    """A git stand-in for fetch, rev-parse, status and ls-remote. Returns its env."""
    spec = Path(root) / "git-spec.json"
    spec.write_text(json.dumps({"worktree": str(worktree), "sha": SHA_A, "gitlink": GITLINK, "tip": tip}))
    shim = Path(root) / "git-shim"
    _write_exec(shim, """
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path
        spec = json.loads(Path(os.environ["C11_POLLER_GIT_SPEC"]).read_text())
        args = sys.argv[1:]
        cwd = str(Path(os.getcwd()).resolve())
        work = str(Path(spec["worktree"]).resolve())
        if args[:1] == ["ls-remote"]:
            sys.stdout.write(spec["tip"] + "\\t" + args[-1] + "\\n")
        elif args[:1] == ["rev-parse"] and len(args) > 1 and args[1] == "HEAD":
            sys.stdout.write((spec["sha"] if cwd == work else spec["gitlink"]) + "\\n")
        elif args[:1] == ["rev-parse"] and len(args) > 1 and ":" in args[1]:
            sys.stdout.write(spec["gitlink"] + "\\n")
        elif args[:1] == ["status"] and cwd == work:
            sys.stdout.write("?? GhosttyKit.xcframework\\n")
        raise SystemExit(0)
    """)
    return {"C11_POLLER_GIT": str(shim), "C11_POLLER_GIT_SPEC": str(spec)}


def child_env(root, github, tip=SHA_A):
    env = dict(os.environ)
    env.pop("C11_POLLER_CONFIG_DIR", None)
    env["HOME"] = str(root)
    env["C11_POLLER_FAKE_HTTP"] = str(github.dir)
    env.update(git_shim(root, Path(root) / "work", tip=tip))
    return env


class ReviewRegressionTests(unittest.TestCase):
    """The review probes, plus the inventory cases those probes do not spell out."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_queue_advances_after_success(self):
        world = World(body=[pr(), pr(number=8)])
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        world.now += 26
        supervisor.poll_once()
        current = json.loads((self.root / "state" / "current.json").read_text())
        self.assertEqual(current["pr"], 8)

    def test_next_cycle_does_not_reuse_result_path(self):
        world = World(body=[pr()])
        spawn = world.spawn

        def run_spawn(command, log_path=None):
            current = json.loads((self.root / "state" / "current.json").read_text())
            Path(current["result"]).mkdir(parents=True)
            return spawn(command)

        world.spawn = run_spawn
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        world.now += 26
        supervisor.poll_once()

    def test_budget_excludes_terminal_post(self):
        """Orchestrator ruling: slot acquisition to build end; posting is reported apart."""
        world = World(body=[pr()])
        spawn = world.spawn
        post = world.post_status

        def run_spawn(command, log_path=None):
            poller.write_running(self.root, {"pgid": 99999999, "acquired_at": world.now})
            world.now += 119
            return spawn(command)

        def deliver(body):
            world.now += 5
            return post(body)

        world.spawn = run_spawn
        world.post_status = deliver
        poller.Supervisor(self.root, world).poll_once()
        self.assertEqual(len(world.posts), 1)
        self.assertEqual((world.posts[-1]["state"], world.posts[-1]["description"]), ("success", "119s"))
        result = [item for item in _decisions(self.root) if item.get("decision") == "result"][-1]
        self.assertEqual(result["build_seconds"], 119)
        self.assertEqual(result["post_seconds"], 5)

    def test_build_over_budget_fails_once(self):
        world = World(body=[pr()])
        spawn = world.spawn

        def run_spawn(command, log_path=None):
            poller.write_running(self.root, {"pgid": 99999999, "acquired_at": world.now})
            world.now += 121
            return spawn(command)

        world.spawn = run_spawn
        poller.Supervisor(self.root, world).poll_once()
        self.assertEqual([(item["state"], item["description"]) for item in world.posts], [("failure", "budget 121s")])

    def test_status_post_retries_honour_retry_after(self):
        world = World(body=[pr()])
        replies = [
            {"status": 503, "headers": {"retry-after": "30"}, "body": {}},
            {"status": 503, "headers": {"Retry-After": "45"}, "body": {}},
            {"status": 201, "headers": {}, "body": {}},
        ]
        post = world.post_status
        world.post_status = lambda body: (post(body), replies.pop(0))[1]
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        self.assertEqual(world.sleeps[-2:], [30, 45])
        self.assertTrue(supervisor.delivered)
        self.assertEqual(supervisor.reported, {7: SHA_A})

    def test_budget_excludes_slot_queue(self):
        world = World(body=[pr()])
        spawn = world.spawn

        def run_spawn(command, log_path=None):
            world.now += 130
            poller.write_running(self.root, {"pgid": 99999999, "acquired_at": world.now})
            world.now += 5
            return spawn(command)

        world.spawn = run_spawn
        poller.Supervisor(self.root, world).poll_once()
        self.assertEqual(world.posts[-1]["state"], "success", str(world.posts[-1]))

    def test_failed_terminal_post_is_not_a_delivered_result(self):
        world = World(body=[pr()])
        world.post_status = lambda _body: {"status": 503, "body": {}, "headers": {}}
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        events = _decisions(self.root)
        self.assertFalse(any(item.get("decision") == "result" and item.get("state") == "success" for item in events), str(events[-1]))
        self.assertEqual([item.get("decision") for item in events].count("status_undelivered"), 1)
        self.assertEqual(world.sleeps[-2:], [1, 2])
        self.assertEqual(supervisor.reported, {})
        self.assertFalse((self.root / "state" / "undelivered.json").exists())

    def test_second_page_retry_after(self):
        url = "https://example.test/page2"
        world = World(body=[pr()], headers={"Link": "<%s>; rel=\"next\"" % url})
        world.pages[url] = {"status": 429, "headers": {"Retry-After": "7200"}, "body": {}}
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        self.assertGreaterEqual(supervisor.not_before, world.now + 7200)

    def test_last_page_remaining(self):
        url = "https://example.test/page2"
        world = World(body=[pr()], headers={"Link": "<%s>; rel=\"next\"" % url, "X-RateLimit-Remaining": "10"})
        world.pages[url] = {
            "status": 200,
            "headers": {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1007200"},
            "body": [],
        }
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        self.assertEqual(supervisor.spawns, [])

    def test_lowercase_rate_headers(self):
        world = World(body=[pr()], headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1007200"})
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        self.assertEqual(supervisor.spawns, [])

    def test_later_page_timeout_backs_off_without_disarming(self):
        url = "https://example.test/page2"
        world = World(body=[pr()], headers={"Link": "<%s>; rel=\"next\"" % url})
        world.pages[url] = {"status": 0, "headers": {}, "body": None}
        supervisor = poller.Supervisor(self.root, world)
        outcome = supervisor.poll_once()
        self.assertEqual(outcome, "no-build")
        self.assertFalse(supervisor.disarmed)
        self.assertEqual(supervisor.spawns, [])
        self.assertGreaterEqual(supervisor.not_before, world.now + poller.CADENCE_S)

    def test_wide_installation_stops_before_narrowed_token(self):
        self._assert_scope_stops({
            "total_count": 2,
            "repositories": [
                {"id": poller.REPO_ID, "full_name": poller.REPO_NAME},
                {"id": 1, "full_name": "other/repo"},
            ],
        }, 200)

    def test_wrong_repo_id_stops_before_narrowed_token(self):
        self._assert_scope_stops({
            "total_count": 1,
            "repositories": [{"id": 1, "full_name": "other/repo"}],
        }, 200)

    def test_malformed_inventory_stops_before_narrowed_token(self):
        self._assert_scope_stops(["not-a-repository-list"], 200)

    def test_inventory_error_stops_before_narrowed_token(self):
        self._assert_scope_stops({}, 500)

    def _assert_scope_stops(self, body, status):
        calls = []

        def transport(method, url, headers, payload):
            calls.append((method, url, payload))
            if url.endswith("/access_tokens"):
                return {"status": 201, "body": {"token": "fake"}, "headers": {}}
            return {"status": status, "body": body, "headers": {}}

        client = poller.AppClient(1, 2, self.root / "unused", transport, sign=lambda *_: b"sig")
        with self.assertRaises(poller.ScopeStop):
            client.verify_scope()
        self.assertEqual(len([item for item in calls if item[1].endswith("/access_tokens")]), 1)
        self.assertFalse(any(item[1].endswith("/statuses/" + SHA_A) for item in calls))

    def test_second_token_expiry_refreshes(self):
        seen = {"mints": 0, "pulls": 0}

        def transport(method, url, headers, body):
            if url.endswith("/access_tokens"):
                seen["mints"] += 1
                return {"status": 201, "body": {"token": "tok-%s" % seen["mints"]}, "headers": {}}
            seen["pulls"] += 1
            return {"status": 401 if seen["pulls"] % 2 else 200, "body": pr(), "headers": {}}

        client = poller.AppClient(1, 2, self.root / "unused", transport, sign=lambda *_: b"sig")
        client.scoped = True
        client.narrowed_token = "initial"
        self.assertEqual(client.pull(7)["status"], 200)
        self.assertEqual(client.pull(7)["status"], 200)
        self.assertEqual(seen["mints"], 2)

    def test_revoked_child_does_not_post_or_retry(self):
        world = World(body=[pr()])
        github = FakeGitHub(self.root, prs=[pr(sha=SHA_B)])
        env = child_env(self.root, github, tip=SHA_B)

        def spawn(command, log_path=None):
            world.spawned.append(command)
            return subprocess.run(command[3:], env=env, capture_output=True, text=True, timeout=10).returncode

        world.spawn = spawn
        poller.Supervisor(self.root, world).poll_once()
        self.assertEqual(world.posts, [], str(world.posts))
        self.assertEqual(github.statuses(), [])
        self.assertEqual(len(world.spawned), 1)

    def test_running_sha_change_cancels_group(self):
        world = World(body=[pr(sha=SHA_B)])
        world.pull_body = pr(sha=SHA_B)
        world.alive[4242] = True
        supervisor = poller.Supervisor(self.root, world)
        supervisor.watch({"pgid": 4242, "slot": 1, "sha": SHA_A, "ref": "feature", "pr": 7})
        self.assertTrue(world.kill_log)
        self.assertFalse(world.group_alive(4242))

    def test_yield_waits_for_group_absence(self):
        marker = self.root / "ready"
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).touch(); time.sleep(30)",
             str(marker)],
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 3
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            world = World()
            world.guest_names = ["c11-sb-review"]
            supervisor = poller.Supervisor(self.root, world)
            supervisor.watch({"pgid": child.pid, "slot": 1, "sha": SHA_A, "pr": 7})
            self.assertFalse(poller.group_alive(child.pid), str(world.posts))
        finally:
            _kill(child.pid)
            child.wait(timeout=3)

    def test_missing_ghosttykit_does_not_block_the_queue(self):
        """Live on Atlas: one head without a GhosttyKit cache entry starved the rest."""
        missing = "e" * 40
        world = World(body=[pr(), pr(number=8, sha=SHA_B, ref="other")])
        world.tips["other"] = SHA_B
        world.gitlinks[SHA_A] = missing
        world.missing_kits.add(missing)
        supervisor = poller.Supervisor(self.root, world)

        def parent_fetches(sha):
            return [args for args, _cwd in world.git_args if args[0] == "fetch" and poller.PARENT_URL in args and sha in args]

        supervisor.poll_once()
        self.assertEqual(supervisor.spawns, [])
        self.assertEqual(_decisions(self.root)[-1]["gitlink"], missing)
        world.now += 26
        supervisor.poll_once()
        self.assertEqual([item["sha"] for item in supervisor.spawns], [SHA_B])
        world.now += 26
        supervisor.poll_once()
        self.assertEqual(len(supervisor.spawns), 1)
        self.assertEqual(len(parent_fetches(SHA_A)), 1)
        world.missing_kits.clear()
        world.now += 26
        supervisor.poll_once()
        self.assertEqual([item["sha"] for item in supervisor.spawns], [SHA_B, SHA_A])

    def test_a_head_that_cannot_be_fetched_goes_to_the_back(self):
        world = World(body=[pr(), pr(number=8, sha=SHA_B, ref="other")])
        world.tips["other"] = SHA_B
        world.fail_fetch.add(SHA_A)
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        self.assertEqual(supervisor.spawns, [])
        world.now += 26
        supervisor.poll_once()
        self.assertEqual([item["sha"] for item in supervisor.spawns], [SHA_B])

    def _derived_paths(self, supervisor):
        return [Path(spawn["command"][spawn["command"].index("-derivedDataPath") + 1]) for spawn in supervisor.spawns]

    def test_derived_data_is_keyed_by_the_dependency_set(self):
        """Live on Atlas: Sparkle 2.9.3 (main) and 2.8.1 (old heads) shared one DerivedData."""
        world = World(body=[pr(), pr(number=8, sha=SHA_B, ref="other"), pr(number=9, sha="f" * 40, ref="third")])
        world.tips.update({"other": SHA_B, "third": "f" * 40})
        world.resolved = {SHA_A: "sparkle 2.9.3", SHA_B: "sparkle 2.8.1", "f" * 40: "sparkle 2.9.3"}
        supervisor = poller.Supervisor(self.root, world)
        for _ in range(3):
            supervisor.poll_once()
            world.now += 26
        paths = self._derived_paths(supervisor)
        expected_new = poller.dependency_key(["sparkle 2.9.3"] * 2, [GITLINK, GITLINK])
        expected_old = poller.dependency_key(["sparkle 2.8.1"] * 2, [GITLINK, GITLINK])
        self.assertEqual(paths, [
            self.root / "cache" / ("DerivedData-" + expected_new),
            self.root / "cache" / ("DerivedData-" + expected_old),
            self.root / "cache" / ("DerivedData-" + expected_new),
        ])
        self.assertNotEqual(expected_new, expected_old)
        self.assertNotEqual(poller.dependency_key(["x"], ["c" * 40]), poller.dependency_key(["x"], ["d" * 40]))
        self.assertEqual([item["deps"] for item in _decisions(self.root) if item.get("decision") == "result"],
                         [expected_new, expected_old, expected_new])

    def test_derived_data_keeps_the_three_most_recent_and_logs_the_prune(self):
        cache = self.root / "cache"
        names = ["DerivedData", "DerivedData-000000000001", "DerivedData-000000000002", "DerivedData-000000000003"]
        for age, name in enumerate(reversed(names)):
            (cache / name / "Build").mkdir(parents=True)
            stamp = 1_000_000 - 100 * (age + 1)
            os.utime(cache / name, (stamp, stamp))
        world = World(body=[pr()])
        supervisor = poller.Supervisor(self.root, world)
        supervisor.poll_once()
        current = self._derived_paths(supervisor)[0].name
        left = sorted(path.name for path in cache.iterdir())
        self.assertEqual(left, sorted([current, "DerivedData-000000000003", "DerivedData-000000000002"]))
        pruned = [item for item in _decisions(self.root) if item.get("decision") == "cache-pruned"]
        self.assertEqual(sorted(pruned[-1]["removed"]), ["DerivedData", "DerivedData-000000000001"])
        self.assertEqual(pruned[-1]["kept"][0], current)

    def test_decisions_keep_the_last_two_hundred_lines(self):
        world = World()
        supervisor = poller.Supervisor(self.root, world)
        for number in range(205):
            supervisor.log(decision="note", n=number)
        lines = (self.root / "state" / "decisions.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), 200)
        self.assertEqual(json.loads(lines[0])["n"], 5)
        self.assertEqual(json.loads(lines[-1])["n"], 204)


class RuntimeHarness(unittest.TestCase):
    """The real supervise and teardown commands.

    Fake GitHub at the HTTP transport (real AppClient, real JWT signing with a
    disposable key), shims for git, tart and zig, a harmless xcodebuild
    stand-in, private slot locks, and real short-lived processes.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.slots = self.root / "slots"
        self.slots.mkdir()
        self.work = self.root / "work"
        (self.work / "ghostty").mkdir(parents=True)
        (self.work / "vendor" / "bonsplit").mkdir(parents=True)
        self.kit = self.root / "kit" / GITLINK / "GhosttyKit.xcframework"
        self.kit.mkdir(parents=True)
        self.load = self.root / "load.txt"
        self.load.write_text("1\n")
        self.github = FakeGitHub(self.root)
        self.git_env = git_shim(self.root, self.work)
        self._shims()
        self.build(SUCCESS_BUILD)
        self.home_key = Path.home() / ".config" / "c11-pr-swift" / "private-key.pem"
        self.home_key_existed = self.home_key.exists()
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
        self.assertEqual(self.home_key.exists(), self.home_key_existed)
        self.tmp.cleanup()

    def _shims(self):
        self.tart_bin = self.root / "tart-shim"
        _write_exec(self.tart_bin, """
            #!/usr/bin/env python3
            import os, sys
            flag = os.environ.get("C11_POLLER_GUEST_FLAG")
            if flag and os.path.exists(flag):
                sys.stdout.write("local c11-sb-demo running\\n")
            elif os.environ.get("C11_POLLER_TART_MODE") == "guest":
                sys.stdout.write("local c11-sb-demo running\\n")
            else:
                sys.stdout.write("local c11-sb-demo stopped\\n")
            raise SystemExit(0)
        """)
        self.zig_bin = self.root / "zig-shim"
        _write_exec(self.zig_bin, """
            #!/usr/bin/env python3
            import sys
            if sys.argv[1:] == ["version"]:
                sys.stdout.write("0.15.2\\n")
            raise SystemExit(0)
        """)

    def build(self, body):
        """The xcodebuild stand-in. It gets the real argv and the build env."""
        shim = self.root / "xcodebuild-shim"
        shim.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, signal, sys, time\n"
            "ROOT = pathlib.Path(%r)\n"
            "with open(ROOT / 'argv.jsonl', 'a') as handle: handle.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            % str(self.root) + textwrap.dedent(body).strip() + "\n"
        )
        shim.chmod(0o755)
        self.xcodebuild = shim

    def _enable(self):
        state = self.root / "state"
        state.mkdir(parents=True, exist_ok=True)
        (state / "enabled.json").write_text(json.dumps({"enabled": True, "worktree": str(self.work)}) + "\n")

    def _env(self, **extra):
        env = os.environ.copy()
        for key in ("C11_POLLER_CONFIG_DIR", "C11_BUILD_LOCK", "GITHUB_TOKEN", "GH_TOKEN"):
            env.pop(key, None)
        env.update(self.git_env)
        env["HOME"] = str(self.root)
        env["C11_POLLER_FAKE_HTTP"] = str(self.github.dir)
        env["C11_POLLER_TART"] = str(self.tart_bin)
        env["C11_POLLER_ZIG"] = str(self.zig_bin)
        env["C11_POLLER_XCODEBUILD"] = str(self.xcodebuild)
        env["C11_POLLER_KIT_CACHE"] = str(self.root / "kit")
        env["C11_POLLER_CADENCE_S"] = "0.05"
        env["C11_ATLAS_SLOTS_DIR"] = str(self.slots)
        env["C11_ATLAS_LOAD_FILE"] = str(self.load)
        env["C11_ATLAS_SLOT_POLL_SECONDS"] = "0.05"
        env.update(extra)
        return env

    def _argv(self, cycles):
        argv = [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "supervise", "--root", str(self.root)]
        if cycles is not None:
            argv += ["--cycles", str(cycles)]
        return argv

    def _supervise(self, env=None, timeout=30, cycles=1):
        return subprocess.run(self._argv(cycles), env=env or self._env(), capture_output=True, text=True, timeout=timeout)

    def _start(self, env=None, cycles=1):
        proc = subprocess.Popen(self._argv(cycles), env=env or self._env(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(proc)
        return proc

    def _results(self):
        return [item for item in _decisions(self.root) if item.get("decision") == "result"]

    def _teardown(self, **extra):
        return subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "teardown", "--root", str(self.root)],
            env=self._env(**extra), capture_output=True, text=True, timeout=20,
        )

    def _stages(self, stages):
        state = self.root / "state"
        state.mkdir(exist_ok=True)
        (state / "stages.json").write_text(json.dumps(stages) + "\n")



class RuntimeIntegrationTests(RuntimeHarness):
    # B1: gates.

    def test_disabled_file_still_exits_2(self):
        state = self.root / "state"
        state.mkdir()
        (state / "enabled.json").write_text('{"enabled": false}\n')
        result = self._supervise()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not armed", result.stderr)
        self.assertFalse((state / "decisions.jsonl").exists())
        self.assertEqual(self.github.requests(), [])

    def test_layout_inside_the_worktree_exits_2(self):
        state = self.root / "state"
        state.mkdir()
        (state / "enabled.json").write_text(json.dumps({"enabled": True, "worktree": str(ROOT.parent)}) + "\n")
        result = self._supervise()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("worktree", result.stderr)
        self.assertFalse((state / "decisions.jsonl").exists())
        self.assertEqual(self.github.requests(), [])

    def test_guest_at_start_does_not_fetch(self):
        self._enable()
        result = self._supervise(self._env(C11_POLLER_TART_MODE="guest"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "argv.jsonl").exists())
        self.assertTrue(any(item.get("decision") == "no-start" and item.get("reason") == "guest" for item in _decisions(self.root)))
        self.assertNotIn("spawn", _events(self.root))

    def test_held_slot_at_start_does_not_fetch(self):
        self._enable()
        lock = self.slots / "slot-1.lock"
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(30)",
             str(lock)],
        )
        self.procs.append(holder)
        deadline = time.time() + 3
        while time.time() < deadline and not poller.slot_held(self.slots, 1):
            time.sleep(0.05)
        self.assertTrue(poller.slot_held(self.slots, 1))
        result = self._supervise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "argv.jsonl").exists())
        self.assertTrue(any(item.get("decision") == "no-start" and item.get("reason") == "slot" for item in _decisions(self.root)))

    # B1: build output, budget fields, GhosttyKit.

    def test_build_output_becomes_the_status(self):
        self._enable()
        result = self._supervise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.github.statuses(), [("pending", "build started"), ("success", self._results()[-1]["description"])])
        decided = self._results()[-1]
        self.assertEqual(decided["state"], "success")
        self.assertEqual(decided["description"], "%ss" % int(decided["build_seconds"]))
        self.assertIn("post_seconds", decided)
        argv = json.loads((self.root / "argv.jsonl").read_text().splitlines()[0])
        bundle = Path(argv[argv.index("-resultBundlePath") + 1])
        self.assertEqual(bundle.parent, self.root / "state" / "results")
        self.assertIn("** TEST SUCCEEDED **", (bundle.parent / (bundle.name + ".log")).read_text())
        self.assertIn("-only-testing:c11LogicTests/HealthFlagsTests", argv)
        key = poller.dependency_key(["", ""], [GITLINK, GITLINK])
        self.assertEqual(Path(argv[argv.index("-derivedDataPath") + 1]), self.root / "cache" / ("DerivedData-" + key))
        self.assertEqual(decided["deps"], key)
        requests = self.github.requests()
        self.assertTrue(all(item["auth"] == "jwt" for item in requests if item["url"].endswith("/access_tokens")))
        self.assertTrue(all(item["auth"] == "token" for item in requests if "/statuses/" in item["url"]))
        self.assertNotIn("fixture-installation-token", (self.root / "state" / "decisions.jsonl").read_text())

    def test_failed_build_retries_once_then_posts_failure(self):
        self._enable()
        self.build('print("** TEST FAILED **"); sys.exit(65)')
        result = self._supervise()
        self.assertEqual(result.returncode, 0, result.stderr)
        bundles = [json.loads(line) for line in (self.root / "argv.jsonl").read_text().splitlines()]
        paths = [argv[argv.index("-resultBundlePath") + 1] for argv in bundles]
        self.assertEqual(len(paths), 2)
        self.assertTrue(paths[0].endswith("-1") and paths[1].endswith("-2"))
        self.assertEqual(paths[0][:-2], paths[1][:-2])
        self.assertEqual([state for state, _ in self.github.statuses()], ["pending", "pending", "failure"])

    def test_stale_module_posts_error_without_a_retry(self):
        """Belt: the stale-module signature is the cache's fault, never the PR's."""
        self._enable()
        self.build("""
            print("<unknown>:0: error: file '/x/Sparkle.framework/Headers/SPUUpdater.h' has been modified since the module file '/x/Sparkle.pcm' was built: size changed")
            print("** TEST FAILED **")
            sys.exit(65)
        """)
        result = self._supervise(cycles=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / "argv.jsonl").read_text().splitlines()), 1)
        self.assertEqual(self.github.statuses(), [("pending", "build started"), ("error", "cache: stale module")])
        decisions = [item.get("decision") for item in _decisions(self.root)]
        self.assertEqual(decisions.count("cache-fault"), 1)
        self.assertFalse(any(item.get("state") == "failure" for item in _decisions(self.root)))

    def test_ghosttykit_links_from_the_ghostty_gitlink(self):
        self._enable()
        self.kit.rmdir()
        (self.root / "kit" / SHA_A / "GhosttyKit.xcframework").mkdir(parents=True)
        result = self._supervise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "argv.jsonl").exists())
        self.assertTrue(any(item.get("decision") == "ghosttykit_missing" and item.get("gitlink") == GITLINK
                            for item in _decisions(self.root)))
        self.kit.mkdir(parents=True)
        result = self._supervise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "argv.jsonl").exists())
        self.assertEqual((self.work / "GhosttyKit.xcframework").resolve(), self.kit.resolve())

    # B1 and B3: the running build stops on a guest, the other slot, or a new head.

    def test_guest_during_the_build_stops_the_group(self):
        self._enable()
        flag = self.root / "guest-flag"
        ready = self.root / "child-ready"
        self.build("pathlib.Path(%r).touch(); pathlib.Path(%r).write_text(str(os.getpgrp())); time.sleep(40)" % (str(flag), str(ready)))
        proc = self._start(self._env(C11_POLLER_GUEST_FLAG=str(flag)))
        _wait_for(ready, timeout=20)
        _out, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 0, err)
        self.assertFalse(poller.group_alive(int(ready.read_text())))
        self.assertTrue(any(item.get("decision") == "yielded" and item.get("reason") == "guest" for item in _decisions(self.root)))
        self.assertEqual(self.github.statuses()[-1], ("error", "yielded to Atlas work"))

    def test_other_slot_during_the_build_stops_the_group(self):
        self._enable()
        ready = self.root / "child-ready"
        self.build("pathlib.Path(%r).write_text(str(os.getpgrp())); time.sleep(40)" % str(ready))
        proc = self._start()
        _wait_for(ready, timeout=20)
        import fcntl
        lock = os.open(self.slots / "slot-2.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            _out, err = proc.communicate(timeout=30)
        finally:
            os.close(lock)
        self.assertEqual(proc.returncode, 0, err)
        self.assertFalse(poller.group_alive(int(ready.read_text())))
        self.assertTrue(any(item.get("decision") == "yielded" and item.get("reason") == "slot" for item in _decisions(self.root)))

    def test_sha_change_kills_until_the_group_is_absent(self):
        self._enable()
        ready = self.root / "child-ready"
        routes = self.github.dir / "routes.json"
        spec = Path(self.git_env["C11_POLLER_GIT_SPEC"])
        self.build("""
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            routes = json.loads(pathlib.Path(%r).read_text())
            for item in routes:
                if item.get("suffix") == "/pulls/7":
                    item["responses"][0]["body"]["head"]["sha"] = %r
            pathlib.Path(%r).with_suffix(".tmp").write_text(json.dumps(routes))
            os.replace(pathlib.Path(%r).with_suffix(".tmp"), %r)
            spec = json.loads(pathlib.Path(%r).read_text())
            spec["tip"] = %r
            pathlib.Path(%r).write_text(json.dumps(spec))
            pathlib.Path(%r).write_text(str(os.getpgrp()))
            time.sleep(60)
        """ % (str(routes), SHA_B, str(routes), str(routes), str(routes), str(spec), SHA_B, str(spec), str(ready)))
        proc = self._start()
        _wait_for(ready, timeout=20)
        _out, err = proc.communicate(timeout=40)
        self.assertEqual(proc.returncode, 0, err)
        self.assertFalse(poller.group_alive(int(ready.read_text())))
        self.assertEqual(self.github.statuses()[-1], ("failure", "superseded"))

    # B2: the queue and reported heads live in one process; a restart asks GitHub.

    def test_queue_advances_between_cycles_in_one_process(self):
        self._enable()
        self.github.set_prs([pr(), pr(number=8, ref="other")])
        trace = self.root / "trace"
        self.build("""
            current = json.loads((ROOT / "state" / "current.json").read_text())
            with open(%r, "a") as handle: handle.write(str(current["pr"]) + "\\n")
            %s
        """ % (str(trace), SUCCESS_BUILD))
        result = self._supervise(cycles=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["7", "8"])
        results = self._results()
        self.assertEqual([(item["pr"], item["state"]) for item in results], [(7, "success"), (8, "success")])

    def test_restart_skips_a_head_already_reported(self):
        self._enable()
        self.github.put("GET", "/status", {"status": 200, "body": {"state": "success", "statuses": [
            {"context": "c11/pr-swift", "state": "success", "description": "21s"},
        ]}}, suffix=True)
        result = self._supervise(cycles=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "argv.jsonl").exists())
        self.assertEqual(self.github.statuses(), [])
        self.assertEqual([item.get("decision") for item in _decisions(self.root)].count("already-reported"), 1)

    # B4: no outbox. Three tries, then the next cycle builds the head again.

    def test_undelivered_status_is_rebuilt_next_cycle(self):
        self._enable()
        busy = {"status": 503, "headers": {"Retry-After": "0"}, "body": {}}
        ok = {"status": 201, "body": {}}
        self.github.put("POST", "/statuses/", ok, busy, busy, busy, ok, ok)
        result = self._supervise(cycles=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        decisions = [item.get("decision") for item in _decisions(self.root)]
        self.assertLess(decisions.index("status_undelivered"), decisions.index("result"))
        self.assertEqual([state for state, _ in self.github.statuses()],
                         ["pending", "success", "success", "success", "pending", "success"])
        bundles = [json.loads(line) for line in (self.root / "argv.jsonl").read_text().splitlines()]
        paths = {argv[argv.index("-resultBundlePath") + 1] for argv in bundles}
        self.assertEqual(len(paths), 2)
        self.assertFalse((self.root / "state" / "undelivered.json").exists())

    # B6: the deadline is held by the running process.

    def test_retry_after_holds_the_running_process(self):
        self._enable()
        self.github.put("GET", "/pulls?state", {"status": 429, "headers": {"retry-after": "7200"}, "body": {}})
        proc = self._start(cycles=None)
        deadline = time.time() + 15
        while time.time() < deadline and not any(item.get("decision") == "sleep" for item in _decisions(self.root)):
            time.sleep(0.05)
        slept = [item for item in _decisions(self.root) if item.get("decision") == "sleep"]
        self.assertTrue(slept, _decisions(self.root))
        self.assertGreaterEqual(slept[0]["seconds"], 7199)
        time.sleep(1.0)
        self.assertIsNone(proc.poll())
        lists = [item for item in self.github.requests() if "/pulls?state" in item["url"]]
        self.assertEqual(len(lists), 1)
        proc.terminate()
        proc.wait(timeout=5)

    # B1: teardown against the App API and the process table.

    def test_teardown_deletes_the_installation_then_removes_the_key(self):
        self._stages(["app_installed", "key_placed"])
        self.github.put("GET", "/app/installations?", {"status": 200, "body": []})
        result = self._teardown()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["removed"], ["app_installed", "key_placed"])
        self.assertFalse((self.github.config / "private-key.pem").exists())
        calls = [(item["method"], item["url"].split("api.github.com")[-1], item["auth"]) for item in self.github.requests()]
        self.assertEqual(calls, [
            ("DELETE", "/app/installations/7", "jwt"),
            ("GET", "/app", "jwt"),
            ("GET", "/app/installations?per_page=100", "jwt"),
        ])

    def test_teardown_keeps_the_key_while_the_installation_is_listed(self):
        self._stages(["app_installed", "key_placed"])
        result = self._teardown()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"action": "stop", "removed": []})
        self.assertTrue((self.github.config / "private-key.pem").exists())

    def test_rejected_key_or_other_app_is_not_proof_of_absence(self):
        """An empty installation list proves nothing unless GET /app shows this App."""
        self._stages(["app_installed", "key_placed"])
        self.github.put("GET", "/app/installations?", {"status": 200, "body": []})
        for identity in ({"status": 401, "body": {}}, {"status": 200, "body": {"id": APP_ID + 1}}):
            with self.subTest(identity=identity["status"]):
                self.github.put("GET", "/app", identity, suffix=True)
                result = self._teardown()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertTrue((self.github.config / "private-key.pem").exists())

    def test_loaded_service_stops_before_the_key(self):
        plist = self.root / "agent.plist"
        plist.write_text("plist\n")
        launch = self.root / "launchctl-shim"
        _write_exec(launch, "#!/bin/sh\nexit 0\n")
        self._stages(["plist_installed", "key_placed"])
        result = self._teardown(C11_POLLER_LAUNCHCTL=str(launch), C11_POLLER_PLIST=str(plist))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue((self.github.config / "private-key.pem").exists())
        self.assertTrue(plist.exists())

    def test_unloaded_service_with_a_live_build_group_stops(self):
        plist = self.root / "agent.plist"
        plist.write_text("plist\n")
        launch = self.root / "launchctl-shim"
        _write_exec(launch, "#!/bin/sh\n[ \"$1\" = print ] && exit 113\nexit 0\n")
        self._stages(["plist_installed", "key_placed"])
        build = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.procs.append(build)
        poller.write_running(self.root, {"pgid": build.pid})
        env = dict(C11_POLLER_LAUNCHCTL=str(launch), C11_POLLER_PLIST=str(plist))
        result = self._teardown(**env)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue((self.github.config / "private-key.pem").exists())
        self.assertTrue(plist.exists())
        build.kill()
        build.wait(timeout=5)
        result = self._teardown(**env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.github.config / "private-key.pem").exists())
        self.assertFalse(plist.exists())



GH_TOKEN_FIXTURE = "gho_fixture0token0not0real"


class GhModeTests(RuntimeHarness):
    """gh mode: the Atlas gh login, read through a fake `gh` on PATH."""

    def setUp(self):
        super().setUp()
        (self.github.config / "app.json").unlink()
        (self.github.config / "credential.json").write_text(json.dumps({"mode": "gh"}))
        self.github.put("GET", "/repos/Stage-11-Agentics/c11", {"status": 200, "body": {
            "id": poller.REPO_ID, "full_name": poller.REPO_NAME, "permissions": {"push": True},
        }}, suffix=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.gh_calls = self.root / "gh-calls"
        self.fake_gh(ok_calls=None)
        self.gh_login = self.root / ".config" / "gh" / "hosts.yml"
        self.gh_login.parent.mkdir(parents=True)
        self.gh_login.write_text("github.com:\n    user: fixture\n")

    def fake_gh(self, ok_calls):
        """Answers `gh auth token` with the fixture token; after ok_calls answers, fails."""
        _write_exec(self.bin / "gh", """
            #!/usr/bin/env python3
            import os, sys
            calls = %r
            with open(calls, "a") as handle:
                handle.write(" ".join(sys.argv[1:]) + " env=" + str(bool(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))) + "\\n")
            used = sum(1 for _ in open(calls))
            limit = %r
            if sys.argv[1:3] != ["auth", "token"] or (limit is not None and used > limit):
                sys.stderr.write("gh: not logged in\\n")
                raise SystemExit(1)
            sys.stdout.write(%r + "\\n")
        """ % (str(self.gh_calls), ok_calls, GH_TOKEN_FIXTURE))

    def _env(self, **extra):
        env = super()._env(**extra)
        env["PATH"] = str(self.bin) + os.pathsep + env.get("PATH", "")
        env["GH_TOKEN"] = "env-token-must-not-be-used"
        return env

    def _all_text(self):
        texts = []
        for path in self.root.rglob("*"):
            if path.is_file() and path.name != "gh" and path.suffix != ".pem":
                texts.append(path.read_text(errors="replace"))
        return "\n".join(texts)

    def test_gh_mode_posts_with_the_login_token(self):
        self._enable()
        result = self._supervise(cycles=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([state for state, _ in self.github.statuses()], ["pending", "success"])
        requests = self.github.requests()
        self.assertFalse(any("/access_tokens" in item["url"] for item in requests))
        digest = hashlib.sha256(GH_TOKEN_FIXTURE.encode()).hexdigest()
        self.assertTrue(requests)
        self.assertTrue(all(item["bearer_sha256"] == digest for item in requests), requests)
        self.assertEqual(requests[0]["url"], "https://api.github.com/repos/Stage-11-Agentics/c11")
        calls = self.gh_calls.read_text().splitlines()
        self.assertTrue(all(line == "auth token --hostname github.com env=False" for line in calls), calls)
        self.assertGreaterEqual(len(calls), len(requests))
        self.assertNotIn(GH_TOKEN_FIXTURE, self._all_text() + result.stdout + result.stderr)
        self.assertEqual(self.gh_login.read_text(), "github.com:\n    user: fixture\n")

    def test_gh_failure_skips_and_logs_without_disarming(self):
        self._enable()
        self.fake_gh(ok_calls=0)
        result = self._supervise(cycles=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        decisions = [item.get("decision") for item in _decisions(self.root)]
        self.assertEqual(decisions.count("credential-unavailable"), 2, decisions)
        self.assertNotIn("scope-stop", decisions)
        self.assertEqual(self.github.requests(), [])
        self.assertFalse((self.root / "argv.jsonl").exists())

    def test_gh_failure_after_scope_skips_the_cycle(self):
        self._enable()
        self.fake_gh(ok_calls=1)
        result = self._supervise(cycles=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("credential-unavailable", [item.get("decision") for item in _decisions(self.root)])
        self.assertEqual([item["url"] for item in self.github.requests()], ["https://api.github.com/repos/Stage-11-Agentics/c11"])
        self.assertFalse((self.root / "argv.jsonl").exists())

    def test_gh_scope_needs_c11_with_push(self):
        self._enable()
        bodies = {
            "no-push": {"id": poller.REPO_ID, "full_name": poller.REPO_NAME, "permissions": {"push": False}},
            "other-id": {"id": 1, "full_name": poller.REPO_NAME, "permissions": {"push": True}},
            "other-name": {"id": poller.REPO_ID, "full_name": "someone/c11", "permissions": {"push": True}},
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                self.github.put("GET", "/repos/Stage-11-Agentics/c11", {"status": 200, "body": body}, suffix=True)
                (self.github.dir / "requests.jsonl").unlink(missing_ok=True)
                result = self._supervise(cycles=1)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(_decisions(self.root)[-1]["decision"], "scope-stop")
                self.assertEqual(len(self.github.requests()), 1)
        self.assertFalse((self.root / "argv.jsonl").exists())

    def fail_gh_when(self, condition):
        """Add a failure condition to the fake gh only; no production code is patched."""
        path = self.bin / "gh"
        text = path.read_text()
        path.write_text(text.replace("used = sum(1 for _ in open(calls))",
                                     "used = sum(1 for _ in open(calls))\n" + condition))

    def test_gh_failure_reading_combined_status_skips_build(self):
        """Review probe: the fourth gh call (the combined status) fails once."""
        self._enable()
        self.fail_gh_when("if used == 4:\n    sys.stderr.write('gh: temporary failure\\n')\n    raise SystemExit(1)")
        result = self._supervise(cycles=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "argv.jsonl").exists())
        self.assertEqual(self.github.statuses(), [])
        self.assertIn("credential-unavailable", [item.get("decision") for item in _decisions(self.root)])

    def test_gh_failure_reading_the_pr_keeps_it_queued(self):
        """The third gh call (PR detail before the build) fails: skip, not revoke."""
        self._enable()
        self.fail_gh_when("if used == 3:\n    raise SystemExit(1)")
        result = self._supervise(cycles=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        decisions = [item.get("decision") for item in _decisions(self.root)]
        self.assertIn("credential-unavailable", decisions)
        self.assertNotIn("revoked", decisions)
        self.assertEqual([state for state, _ in self.github.statuses()], ["pending", "success"])

    def test_gh_failure_during_watch_is_not_revocation(self):
        """Review probe: one gh failure after pending, while the build runs."""
        self._enable()
        requests = self.github.dir / "requests.jsonl"
        marker = self.root / "gh-failed-once"
        self.fail_gh_when(
            "import pathlib, json\n"
            "request_file = pathlib.Path(%r)\nmarker = pathlib.Path(%r)\n" % (str(requests), str(marker)) +
            "if request_file.exists() and not marker.exists():\n"
            "    records = [json.loads(line) for line in request_file.read_text().splitlines()]\n"
            "    if any(r['method'] == 'POST' and (r.get('body') or {}).get('state') == 'pending' for r in records):\n"
            "        marker.write_text('failed')\n"
            "        raise SystemExit(1)")
        self.build("time.sleep(12)\n" + SUCCESS_BUILD)
        result = self._supervise(cycles=1, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists(), "failure not injected")
        self.assertEqual([state for state, _ in self.github.statuses()], ["pending", "success"])
        self.assertTrue(any(item.get("decision") == "credential-unavailable" and item.get("during") == "watch"
                            for item in _decisions(self.root)))

    def test_teardown_does_not_claim_success_when_cache_removal_fails(self):
        """Review probe: an unwritable cache keeps the stage record and exits 2."""
        self._stages(["gh_configured"])
        cache = self.root / "cache"
        cache.mkdir()
        (cache / "retained").write_text("fixture")
        cache.chmod(0o500)
        try:
            result = self._teardown()
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertEqual(json.loads(result.stdout)["reason"], "local-state")
            self.assertTrue((self.root / "state" / "stages.json").exists())
            self.assertIn("local state not removed", result.stderr)
        finally:
            cache.chmod(0o700)
        result = self._teardown()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(cache.exists())
        self.assertFalse((self.root / "state").exists())

    def test_teardown_keeps_stages_when_the_state_directory_cannot_be_removed(self):
        """Review probe: the poller root at 0500 blocks the final rmdir of state/."""
        self._stages(["gh_configured"])
        record = self.root / "state" / "stages.json"
        before = record.read_text()
        self.root.chmod(0o500)
        try:
            result = self._teardown()
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["reason"], "local-state")
            self.assertTrue((self.root / "state").is_dir())
            self.assertEqual(record.read_text(), before)
        finally:
            self.root.chmod(0o700)
        result = self._teardown()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "state").exists())

    def test_child_with_a_failing_gh_refuses_before_pending(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current.json").write_text(json.dumps({
            "attempt_id": "attempt", "invocation": 1, "pr": 7, "sha": SHA_A, "ref": "feature",
        }))
        self.fake_gh(ok_calls=0)
        sentinel = self.root / "should-not-run"
        result = subprocess.run(
            [sys.executable, str(ROOT / "c11-pr-swift-poller.py"), "child", "--root", str(self.root),
             "--exec", sys.executable, "-c", "open(%r,'w').write('ran')" % str(sentinel)],
            env=self._env(), capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertIn("child-credential-failed", _events(self.root))
        self.assertEqual(self.github.statuses(), [])

    def test_gh_teardown_is_bootout_plus_state_removal(self):
        plist = self.root / "agent.plist"
        plist.write_text("plist\n")
        launch = self.root / "launchctl-shim"
        _write_exec(launch, "#!/bin/sh\n[ \"$1\" = print ] && exit 113\nexit 0\n")
        self._stages(["plist_installed", "gh_configured"])
        (self.root / "cache" / "DerivedData").mkdir(parents=True)
        result = self._teardown(C11_POLLER_LAUNCHCTL=str(launch), C11_POLLER_PLIST=str(plist))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["removed"], ["plist_installed", "gh_configured"])
        self.assertFalse(plist.exists())
        self.assertFalse((self.github.config / "credential.json").exists())
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / "cache").exists())
        self.assertEqual(self.github.requests(), [])
        self.assertEqual(self.gh_login.read_text(), "github.com:\n    user: fixture\n")

    def test_app_json_selects_app_mode(self):
        (self.github.config / "app.json").write_text(json.dumps({"app_id": APP_ID, "installation_id": INSTALLATION_ID}))
        with unittest.mock.patch.dict(os.environ, {"C11_POLLER_CONFIG_DIR": str(self.github.config)}):
            self.assertIsInstance(poller.make_client(), poller.AppClient)
            (self.github.config / "app.json").unlink()
            self.assertIsInstance(poller.make_client(), poller.GhClient)
            (self.github.config / "credential.json").unlink()
            self.assertRaises(poller.ScopeStop, poller.make_client)


if __name__ == "__main__":
    unittest.main(verbosity=2)
