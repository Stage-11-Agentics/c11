#!/usr/bin/env python3
"""Executable backstop acceptance: real git history, slot contention and gate subprocesses."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("c11-main-backstop.py")
spec = importlib.util.spec_from_file_location("backstop", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SHA = "a" * 40


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)
    return path


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "state").mkdir()

    def test_main_history_coalesces_and_refuses_rewrites(self):
        def g(repo, *args):
            return subprocess.run(["/usr/bin/git", "-C", str(repo), *args], check=True,
                                  text=True, capture_output=True).stdout.strip()
        remotes = {}
        for name, url in (("parent", m.poller.PARENT_URL), ("ghostty", m.poller.GHOSTTY_URL),
                          ("bonsplit", m.poller.BONSPLIT_URL)):
            repo = self.root / name
            repo.mkdir()
            g(repo, "init", "-b", "main")
            g(repo, "config", "user.name", "Fixture")
            g(repo, "config", "user.email", "fixture@example.invalid")
            (repo / "content").write_text(name)
            g(repo, "add", ".")
            g(repo, "commit", "-m", "initial")
            remotes[url] = repo
        parent = remotes[m.poller.PARENT_URL]
        for name, url in m.poller.GITLINKS:
            g(parent, "update-index", "--add", "--cacheinfo", "160000," + g(remotes[url], "rev-parse", "HEAD") + "," + name)
        g(parent, "commit", "-m", "submodules")
        expected = g(parent, "rev-parse", "HEAD")
        calls = []
        def transport(repo, *args):
            m.poller.assert_git_args(args)
            calls.append(args)
            translated = [str(remotes[a]) if a in remotes else a for a in args]
            out = subprocess.run(["/usr/bin/git", *translated], cwd=repo, check=True,
                                 text=True, capture_output=True).stdout.strip()
            if args[0] == "clone":
                g(Path(args[-1]), "remote", "set-url", "origin", m.poller.PARENT_URL)
            return out
        with patch.object(m, "git", transport), patch.object(m.poller, "link_ghosttykit", return_value="ok"):
            _, first = m.prepare(self.root)
            self.assertEqual(first, expected)
            for step in ("second", "third"):
                (parent / "content").write_text(step)
                g(parent, "add", "content")
                g(parent, "commit", "-m", step)
            _, latest = m.prepare(self.root)
            self.assertEqual(latest, g(parent, "rev-parse", "HEAD"))
            self.assertNotEqual(first, latest)
            g(parent, "reset", "--hard", first)
            with self.assertRaisesRegex(RuntimeError, "rewound"):
                m.prepare(self.root)
        self.assertFalse(any("refs/pull" in str(a) for a in calls))

    def test_fork_never_queues_and_missing_status_yields(self):
        repo = {"id": m.poller.REPO_ID, "full_name": m.poller.REPO_NAME}
        row = {"number": 1, "state": "open", "base": {"repo": repo},
               "head": {"repo": repo, "sha": SHA, "ref": "feature"}}
        with patch.object(m, "api", side_effect=[[row], {"statuses": []}]):
            self.assertTrue(m.pr_work_pending())
        row["head"]["repo"] = {"id": 1, "full_name": "someone/fork"}
        with patch.object(m, "api", return_value=[row]) as api:
            self.assertFalse(m.pr_work_pending())
            self.assertEqual(api.call_count, 1)
        with self.assertRaises(m.poller.OriginRefused):
            m.git(None, "fetch", "https://example.invalid/fork.git", SHA)

    def test_child_revalidates_after_preparation(self):
        for changed_main in (False, True):
            attempt = self.root / ("changed" if changed_main else "priority")
            attempt.mkdir()
            checks = [False, False] if changed_main else [False, True]
            with patch.dict(os.environ, {"C11_ATLAS_BUILD_SLOT": "1"}), \
                 patch.object(m, "guest_running", return_value=False), \
                 patch.object(m, "pr_work_pending", side_effect=checks), \
                 patch.object(m, "prepare", return_value=(self.root, SHA)), \
                 patch.object(m, "remote_tip", return_value="b" * 40 if changed_main else SHA), \
                 patch.object(m, "gate", return_value=("success", [])) as gate:
                m.child(self.root, attempt)
            self.assertEqual(m.read(attempt / "result.json")["state"], "deferred")
            gate.assert_not_called()

    def gate_fixture(self, exit_code=0, count=3):
        repo = self.root / "repo"
        repo.mkdir(exist_ok=True)
        (repo / "scripts").mkdir(exist_ok=True)
        (repo / "scripts/host-test-quarantine.tsv").write_text("")
        executable(repo / "scripts/with-build-lock.sh", '#!/bin/sh\nexec "$@"\n')
        executable(repo / "scripts/test-unit-local.sh", '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
p.mkdir()
(p/'summary.json').write_text(json.dumps({'result': 'Passed', 'totalTestCount': COUNT, 'skippedTests': 0, 'failedTests': 0}))
'''.replace("COUNT", str(count)))
        fake = executable(repo / "xcodebuild", '#!/bin/sh\nexit ' + str(exit_code) + '\n')
        for name in ("test_cli_ssh_shell_bootstrap.py", "test_cli_focus_history.py", "test_cli_window_scope.py",
                     "test_cli_activity_analysis.py", "test_mailbox_body_cli.py"):
            executable(repo / "tests" / name, "#!/usr/bin/env python3\n")
        executable(repo / "tests_v2/test_send_raw_and_flags.py", "#!/usr/bin/env python3\n")
        executable(repo / "tests/test_shell_git_watchers.sh", "#!/bin/sh\nexit 0\n")
        return repo, fake

    def test_gate_runs_all_stages_and_classifies_real_exit_and_zero_tests(self):
        for label, code, count, expected in (("green", 0, 3, "success"), ("build-red", 65, 3, "failure"),
                                              ("zero-tests", 0, 0, "failure")):
            repo, fake = self.gate_fixture(code, count)
            attempt = self.root / label
            attempt.mkdir()
            with patch.dict(os.environ, {"C11_ATLAS_BUILD_SLOT": "1", "C11_BUILD_LOCK_DIR": str(self.root / "lock")}), \
                 patch.object(m, "git", return_value=SHA), patch.object(m.poller, "XCODEBUILD", str(fake)), \
                 patch.object(m.poller, "xcresult_summary", side_effect=lambda p: m.read(p / "summary.json")):
                state, stages = m.gate(self.root, repo, SHA, attempt)
            self.assertEqual(state, expected)
            if label == "green":
                self.assertEqual(len(stages), 10)
                self.assertEqual({r["stage"] for r in stages if r["summary"]}, {"logic", "host"})

    def cycle_fixture(self):
        slots = self.root / "slots"
        env = m.poller.build_env()
        env.update(C11_ATLAS_SLOTS_DIR=str(slots), C11_ATLAS_LOAD_LIMIT="9999", C11_ATLAS_SLOT_POLL_SECONDS="0.1")
        self.fixture_env = env
        driver = self.root / "child.py"
        driver.write_text('''import importlib.util, pathlib, sys, time
s=importlib.util.spec_from_file_location('b', SCRIPT)
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.guest_running=lambda: False
m.pr_work_pending=lambda: False
m.prepare=lambda root: (root, 'a'*40)
m.remote_tip=lambda: 'a'*40
def gate(root, repo, sha, attempt):
    (root/'started').write_text('yes')
    time.sleep(float((root/'duration').read_text()))
    return 'success', []
m.gate=gate
sys.exit(m.main())
'''.replace("SCRIPT", repr(str(SCRIPT))))
        (self.root / "duration").write_text("0")
        real_popen = subprocess.Popen
        def popen(argv, **kwargs):
            argv = list(argv)
            if len(argv) > 2 and argv[1] == str(m.SLOTS) and str(SCRIPT) in argv:
                argv[argv.index(str(SCRIPT))] = str(driver)
            return real_popen(argv, **kwargs)
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(m, "SLOTS", SCRIPT.with_name("atlas_build_slots.py")))
        stack.enter_context(patch.object(m.poller, "build_env", side_effect=lambda: dict(env)))
        stack.enter_context(patch.object(m, "guest_running", return_value=False))
        stack.enter_context(patch.object(m, "remote_tip", return_value=SHA))
        stack.enter_context(patch.object(m.subprocess, "Popen", side_effect=popen))
        return slots

    def test_slot_contention_and_dry_run_no_posts(self):
        slots = self.cycle_fixture()
        slots.mkdir()
        import fcntl
        with (slots / "slot-1.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(m, "pr_work_pending", return_value=False), patch.object(m, "post") as post:
                self.assertEqual(m.cycle(self.root), "deferred")
                self.assertFalse((self.root / "started").exists())
                post.assert_not_called()
        with patch.object(m, "pr_work_pending", return_value=False), patch.object(m, "post") as post:
            self.assertEqual(m.cycle(self.root), "success")
            post.assert_not_called()
        self.assertTrue((self.root / "started").exists())

    def test_running_backstop_yields_to_pr_demand(self):
        self.cycle_fixture()
        (self.root / "duration").write_text("20")
        waiting = []
        requested = []
        marker = self.root / "poller-started"
        def demand():
            if not (self.root / "started").exists():
                return False
            if not waiting:
                requested.append(time.time())
                waiting.append(subprocess.Popen([
                    "/usr/bin/python3", str(m.SLOTS), "fixture-pr", "--poller",
                    "/usr/bin/python3", "-c",
                    "import pathlib,time; pathlib.Path(%r).write_text(str(time.time()))" % str(marker),
                ], env=self.fixture_env, stdout=subprocess.DEVNULL))
            return True
        try:
            with patch.object(m, "CADENCE", 0), patch.object(m, "pr_work_pending", side_effect=demand):
                self.assertEqual(m.cycle(self.root), "deferred")
            self.assertEqual(len(waiting), 1)
            waiting[0].wait(timeout=5)
            elapsed = float(marker.read_text()) - requested[0]
            print("PR demand to admitted poller: %.3fs" % elapsed)
            self.assertGreaterEqual(elapsed, 0)
            self.assertLess(elapsed, 15)
            self.assertFalse((self.root / "state/running.json").exists())
        finally:
            for process in waiting:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_status_context_and_elapsed_are_not_failure(self):
        with patch.object(m, "api") as api:
            m.post({"sha": SHA, "state": "success", "seconds": 999})
            self.assertIn("context=c11/main-atlas", api.call_args.args)
            self.assertIn("state=success", api.call_args.args)
            api.reset_mock()
            m.post({"sha": SHA, "state": "deferred", "seconds": 1})
            api.assert_not_called()

    def test_service_stages_main_bytes_even_from_a_feature_checkout(self):
        spec = importlib.util.spec_from_file_location("service", SCRIPT.with_name("c11-main-backstop-service.py"))
        service = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(service)
        repo = self.root / "source"
        repo.mkdir()
        def git(*args):
            return subprocess.run(["/usr/bin/git", "-C", str(repo), *args], check=True,
                                  capture_output=True, text=True).stdout.strip()
        git("init", "-b", "main")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (repo / "scripts").mkdir()
        for name in service.FILES:
            (repo / "scripts" / name).write_text("main controller")
        git("add", ".")
        git("commit", "-m", "main")
        main = git("rev-parse", "HEAD")
        git("checkout", "-b", "feature")
        for name in service.FILES:
            (repo / "scripts" / name).write_text("unmerged controller")
        git("commit", "-am", "feature")
        destination = self.root / "staged"
        destination.mkdir()
        real_run = service.run
        def transport(argv, **kwargs):
            self.assertIn(service.URL, argv)
            return real_run([str(repo) if arg == service.URL else arg for arg in argv], **kwargs)
        with patch.object(service, "run", side_effect=transport):
            self.assertEqual(service.stage(repo, destination), main)
        for name in service.FILES:
            self.assertEqual((destination / name).read_text(), "main controller")
        self.assertEqual(m.read(destination / "manifest.json")["sha"], main)

    def test_service_install_update_rollback_teardown_leaves_poller(self):
        spec = importlib.util.spec_from_file_location("service", SCRIPT.with_name("c11-main-backstop-service.py"))
        service = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(service)
        owned = self.root / "c11-main-backstop"
        poller = self.root / "c11-poller"
        poller.mkdir()
        (poller / "untouched").write_text("poller")
        loaded = False
        calls = []
        def launchctl(*args):
            nonlocal loaded
            calls.append(args)
            if args[0] == "print" and not loaded:
                raise subprocess.CalledProcessError(113, args)
            if args[0] == "bootstrap":
                loaded = True
            if args[0] == "bootout":
                loaded = False
            self.assertFalse(any(service.LABEL.replace("main-backstop", "pr-swift-poller") in a for a in args))
            return "running" if loaded else ""
        revision = [0]
        def stage(source, dest):
            revision[0] += 1
            (dest / "c11-main-backstop.py").write_text(str(revision[0]))
            return str(revision[0])
        def recovery(argv, **kwargs):
            self.assertFalse(loaded, "recovery must follow bootout")
            self.assertIn(str(owned), argv)
            return "ready"
        with patch.object(service, "ROOT", owned), patch.object(service.Path, "home", return_value=self.root), \
             patch.object(service, "launchctl", side_effect=launchctl), \
             patch.object(service, "stage", side_effect=stage), patch.object(service, "run", side_effect=recovery):
            for mode in ("install", "update", "rollback", "teardown"):
                with patch.object(sys, "argv", ["service", mode, "--source", str(self.root)]):
                    service.main()
                if mode == "update":
                    self.assertEqual((owned / "bin/c11-main-backstop.py").read_text(), "2")
                if mode == "rollback":
                    self.assertEqual((owned / "bin/c11-main-backstop.py").read_text(), "1")
        self.assertFalse(owned.exists())
        self.assertFalse(loaded)
        self.assertEqual((poller / "untouched").read_text(), "poller")


if __name__ == "__main__":
    unittest.main(verbosity=2)
