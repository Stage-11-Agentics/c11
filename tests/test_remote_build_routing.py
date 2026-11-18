#!/usr/bin/env python3
"""Behavioral transport/overlay/result tests. Run on the build host; no Xcode required."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import argparse
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("remote_build", ROOT / "scripts/remote_build.py")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], stderr=subprocess.DEVNULL).decode().strip()


def repository(path):
    path.mkdir()
    git(path, "init", "-q")
    git(path, "config", "user.name", "Fixture")
    git(path, "config", "user.email", "fixture@example.invalid")
    (path / "tracked").write_text("initial")
    git(path, "add", ".")
    git(path, "commit", "-qm", "fixture")


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.parent = self.base / "parent"
        repository(self.parent)
        for name in ("ghostty", "vendor/bonsplit"):
            module = self.base / name.replace("/", "-")
            repository(module)
            git(self.parent, "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(module), name)
        git(self.parent, "commit", "-qam", "modules")
        self.worktree = self.base / "worktree"
        git(self.parent, "worktree", "add", "-q", "-b", "delegator", str(self.worktree))
        git(self.worktree, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive")
        self.payload = self.base / "payload"
        self.payload.mkdir()
        self.args = argparse.Namespace(tag="fixture", mode="debug", extra=[], clean=False, wmo=False, universal=False,
                                      launch=False, host="studio", no_host_quarantine=False)

    def test_worktree_bundles_overlay_bytes_deletion_mode_and_symlink(self):
        self.assertTrue((self.worktree / ".git").read_text().startswith("gitdir:"))
        (self.worktree / "tracked").unlink()
        script = self.worktree / "new executable"
        script.write_text("first")
        script.chmod(0o755)
        (self.worktree / "link").symlink_to("new executable")
        manifest = remote.snapshot(self.worktree, self.payload, self.args)
        clone = self.base / "clone"
        git(self.base, "clone", "-q", str(self.payload / "parent.bundle"), str(clone))
        self.assertEqual(git(clone, "rev-parse", "HEAD"), manifest["head"])
        remote.apply_overlay(clone, self.payload, manifest)
        self.assertFalse((clone / "tracked").exists())
        self.assertEqual((clone / "new executable").read_text(), "first")
        self.assertEqual((clone / "new executable").stat().st_mode & 0o777, 0o755)
        self.assertEqual(os.readlink(clone / "link"), "new executable")
        before = next(x["sha256"] for x in manifest["overlay"] if x["path"] == "new executable")
        script.write_text("second")
        another = self.base / "payload2"
        another.mkdir()
        changed = remote.snapshot(self.worktree, another, self.args)
        after = next(x["sha256"] for x in changed["overlay"] if x["path"] == "new executable")
        self.assertNotEqual(before, after)

    def test_tampered_overlay_refuses(self):
        (self.worktree / "tracked").write_text("changed")
        manifest = remote.snapshot(self.worktree, self.payload, self.args)
        (self.payload / "overlay/tracked").write_text("tampered")
        clone = self.base / "clone"
        git(self.base, "clone", "-q", str(self.payload / "parent.bundle"), str(clone))
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            remote.apply_overlay(clone, self.payload, manifest)

    def test_dirty_submodule_refuses(self):
        (self.worktree / "ghostty/tracked").write_text("different")
        with self.assertRaisesRegex(ValueError, "must be provisioned, clean"):
            remote.snapshot(self.worktree, self.payload, self.args)

    def test_toolchain_refusal_returns_three_and_keeps_result_and_previous_app(self):
        real_run = remote.run
        for tool in ("xcodebuild", "zig"):
            for failure in ("missing", "unusable", "wrong-version", "empty-version"):
                with self.subTest(tool=tool, failure=failure):
                    case = self.base / (tool + "-" + failure)
                    case.mkdir()
                    payload = case / "payload"
                    payload.mkdir()
                    manifest = remote.snapshot(self.worktree, payload, self.args)
                    fake = case / "tools"
                    fake.mkdir()
                    for name, version in (("xcodebuild", "Xcode 26.3"), ("zig", "0.15.2")):
                        path = fake / name
                        if name == tool and failure == "missing":
                            continue
                        if name == tool and failure == "unusable":
                            path.write_text("#!/bin/sh\necho unavailable >&2\nexit 51\n")
                        else:
                            if name == tool:
                                version = "unsupported version" if failure == "wrong-version" else ""
                            path.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
                        path.chmod(0o755)
                    home = case / "home"
                    previous = home / "Library/Developer/Xcode/DerivedData/c11-fixture/Build/Products/Debug/c11 DEV fixture.app"
                    previous.mkdir(parents=True)
                    (previous / "sentinel").write_text("previous app")
                    def run_fixture(args, **kwargs):
                        if str(args[0]) in ("xcodebuild", "zig"):
                            args = [fake / str(args[0]), *args[1:]]
                        return real_run(args, **kwargs)
                    with patch.dict(os.environ, HOME=str(home)), patch.object(remote, "run", run_fixture):
                        self.assertEqual(remote.remote(payload, locked=True), 3)
                    artifacts = home / remote.BUILD_DIR / "fixture/artifacts" / manifest["invocation"]
                    result = json.loads((artifacts / "result.json").read_text())
                    self.assertFalse(result["ok"])
                    self.assertEqual(result["compile"], "failed")
                    self.assertIn("error", result)
                    self.assertNotIn("app", result)
                    self.assertFalse((artifacts / "build.log").exists())
                    self.assertEqual((previous / "sentinel").read_text(), "previous app")

    def stage(self, home, held=None):
        """Snapshot against held heads, then prepare source on the fixture host up to the toolchain check."""
        payload = Path(tempfile.mkdtemp(dir=self.base))
        manifest = remote.snapshot(self.worktree, payload, self.args, held)
        real_run = remote.run
        def no_toolchain(args, **kwargs):
            if str(args[0]) == "xcodebuild":
                raise OSError("fixture has no toolchain")
            return real_run(args, **kwargs)
        with patch.dict(os.environ, HOME=str(home)), patch.object(remote, "run", no_toolchain):
            self.assertEqual(remote.remote(payload, locked=True), 3)
        source = home / remote.BUILD_DIR / "fixture/source"
        self.assertEqual(git(source, "rev-parse", "HEAD"), manifest["head"])
        for name, sha in manifest["submodules"].items():
            self.assertEqual(git(source / name, "rev-parse", "HEAD"), sha)
        return payload, manifest

    def advance(self, text):
        (self.worktree / "tracked").write_text(text)
        git(self.worktree, "commit", "-qam", text)

    def test_new_head_bundles_only_commits_the_host_mirror_lacks(self):
        home = self.base / "host"
        home.mkdir()
        payload, first = self.stage(home)
        self.assertEqual(first["bundles"], {"parent": "full", "ghostty": "full", "vendor-bonsplit": "full"})
        with patch.dict(os.environ, HOME=str(home)):
            held = remote.held_heads(remote.Transport("local"))
        self.assertEqual(held, {"parent": [first["head"]], "ghostty": [first["submodules"]["ghostty"]],
                                "vendor-bonsplit": [first["submodules"]["vendor/bonsplit"]]})
        self.advance("child of a held head")
        payload, second = self.stage(home, held)
        # Unchanged submodules send nothing; the parent bundle requires the held head.
        self.assertEqual(second["bundles"], {"parent": "incremental"})
        self.assertEqual(sorted(p.name for p in payload.glob("*.bundle")), ["parent.bundle"])
        verify = subprocess.run(["git", "-C", str(self.worktree), "bundle", "verify", str(payload / "parent.bundle")],
                                capture_output=True, text=True)
        self.assertIn(first["head"], verify.stdout + verify.stderr)
        self.assertEqual(git(self.worktree, "rev-list", "--count", first["head"] + "..HEAD"), "1")
        # The same head again uploads no bundle at all; the host publishes it from its mirror.
        with patch.dict(os.environ, HOME=str(home)):
            held = remote.held_heads(remote.Transport("local"))
        payload, third = self.stage(home, held)
        self.assertEqual(third["bundles"], {})
        self.assertEqual(list(payload.glob("*.bundle")), [])

    def test_no_shared_base_falls_back_to_full_bundles(self):
        unknown = {"parent": ["f" * 40, "not-a-sha"], "ghostty": ["e" * 40]}
        home = self.base / "fresh-host"
        home.mkdir()
        payload, manifest = self.stage(home, unknown)
        self.assertEqual(manifest["bundles"], {"parent": "full", "ghostty": "full", "vendor-bonsplit": "full"})
        verify = subprocess.run(["git", "-C", str(self.worktree), "bundle", "verify", str(payload / "parent.bundle")],
                                capture_output=True, text=True)
        self.assertIn("records a complete history", verify.stdout + verify.stderr)

    def test_host_refuses_a_bundle_or_head_its_mirror_cannot_complete(self):
        donor = self.base / "donor"
        donor.mkdir()
        _, first = self.stage(donor)
        self.advance("needs the base")
        held = {"parent": [first["head"]]}
        payload = self.base / "incremental"
        payload.mkdir()
        manifest = remote.snapshot(self.worktree, payload, self.args, held)
        self.assertEqual(manifest["bundles"]["parent"], "incremental")
        empty = self.base / "empty-host"
        empty.mkdir()
        with patch.dict(os.environ, HOME=str(empty)):
            with self.assertRaisesRegex(ValueError, "lacks " + manifest["head"]):
                remote.mirror_head(payload, manifest, "parent", manifest["head"])
            manifest["bundles"] = {}
            with self.assertRaisesRegex(ValueError, "lacks " + manifest["head"]):
                remote.mirror_head(payload, manifest, "parent", manifest["head"])

    def test_new_mirror_adopts_heads_of_existing_host_checkouts(self):
        home = self.base / "legacy-host"
        home.mkdir()
        self.stage(home)
        # A host from before mirrors has only its per-tag checkouts.
        shutil.rmtree(home / remote.BUILD_DIR / "mirrors")
        with patch.dict(os.environ, HOME=str(home)):
            held = remote.held_heads(remote.Transport("local"))
        self.assertEqual(held["parent"], [git(self.worktree, "rev-parse", "HEAD")])
        self.assertEqual(held["ghostty"], [git(self.worktree / "ghostty", "rev-parse", "HEAD")])
        self.advance("after migration")
        _, manifest = self.stage(home, held)
        self.assertEqual(manifest["bundles"], {"parent": "incremental"})

    def test_overlapping_requests_for_one_new_head_both_publish_it(self):
        home = self.base / "shared-host"
        home.mkdir()
        self.stage(home)
        with patch.dict(os.environ, HOME=str(home)):
            held = remote.held_heads(remote.Transport("local"))
        self.advance("one head, two tags")
        mirror = home / remote.BUILD_DIR / "mirrors/parent.git"
        ready, release = self.base / "ready", self.base / "release"
        os.mkfifo(ready)
        os.mkfifo(release)
        # The first request pauses inside Git's ref transaction for the new head.
        hook = mirror / "hooks/reference-transaction"
        hook.write_text("#!" + sys.executable + "\nimport os,sys\n"
                        "if sys.argv[1] == 'prepared' and os.environ.get('ACTOR') == 'first':\n"
                        "    open(os.environ['READY'], 'w').write('ready')\n"
                        "    open(os.environ['RELEASE']).read()\n")
        hook.chmod(0o755)
        payloads = []
        for tag in ("tag-a", "tag-b"):
            payload = self.base / tag
            payload.mkdir()
            manifest = remote.snapshot(self.worktree, payload, self.args, held)
            manifest.update(tag=tag, slug=tag)
            (payload / "identity.json").write_text(json.dumps(manifest))
            payloads.append(payload)
        self.assertEqual(manifest["bundles"], {"parent": "incremental"})
        # A contended mirror lock announces itself on stdout before blocking, so the
        # test observes the second request waiting instead of guessing with a sleep.
        child = ("import fcntl,importlib.util,sys\nfrom pathlib import Path\nflock=fcntl.flock\n"
                 "def announce(f, op):\n"
                 "    try: return flock(f, op | fcntl.LOCK_NB)\n"
                 "    except BlockingIOError: print('waiting', flush=True); return flock(f, op)\n"
                 "fcntl.flock=announce\n"
                 "s=importlib.util.spec_from_file_location('r', sys.argv[1])\n"
                 "r=importlib.util.module_from_spec(s); s.loader.exec_module(r)\nrun=r.run\n"
                 "def stop(args, **kw):\n"
                 "    if str(args[0]) == 'xcodebuild': raise OSError('fixture stops before the toolchain')\n"
                 "    return run(args, **kw)\n"
                 "r.run=stop\nsys.exit(r.remote(Path(sys.argv[2]), locked=True))\n")
        env = dict(os.environ, HOME=str(home), READY=str(ready), RELEASE=str(release))
        command = [sys.executable, "-c", child, str(ROOT / "scripts/remote_build.py")]
        first = subprocess.Popen([*command, payloads[0]], env=dict(env, ACTOR="first"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(ready.read_text(), "ready")
            second = subprocess.Popen([*command, payloads[1]], env=dict(env, ACTOR="second"),
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(second.stdout.readline(), "waiting\n")
        finally:
            release.write_text("go")
            first.communicate()
        out, err = second.communicate()
        self.assertEqual((first.returncode, second.returncode), (3, 3), out + err)
        self.assertEqual(git(mirror, "rev-parse", "refs/c11/" + manifest["head"]), manifest["head"])
        for tag in ("tag-a", "tag-b"):
            self.assertEqual(git(home / remote.BUILD_DIR / tag / "source", "rev-parse", "HEAD"), manifest["head"])

    def test_interrupted_mirror_initialization_is_rebuilt(self):
        home = self.base / "interrupted-host"
        mirrors = home / remote.BUILD_DIR / "mirrors"
        (mirrors / "parent.git").mkdir(parents=True)
        (mirrors / "ghostty.git/objects").mkdir(parents=True)
        (mirrors / "vendor-bonsplit.git.init").mkdir()
        with patch.dict(os.environ, HOME=str(home), GIT_CEILING_DIRECTORIES=str(self.base)):
            held = remote.held_heads(remote.Transport("local"))
            self.assertEqual(held, {"parent": [], "ghostty": [], "vendor-bonsplit": []})
            for repo in held:
                self.assertEqual(git(mirrors / (repo + ".git"), "rev-parse", "--is-bare-repository"), "true")
            self.assertFalse((mirrors / "vendor-bonsplit.git.init").exists())
            _, manifest = self.stage(home, held)
            self.assertEqual(manifest["bundles"], {"parent": "full", "ghostty": "full", "vendor-bonsplit": "full"})
        # An interruption after use is recovered by the request that publishes the head.
        shutil.rmtree(mirrors / "ghostty.git")
        (mirrors / "ghostty.git").mkdir()
        with patch.dict(os.environ, HOME=str(home), GIT_CEILING_DIRECTORIES=str(self.base)):
            self.advance("after a damaged module mirror")
            payload = self.base / "rebuild"
            payload.mkdir()
            manifest = remote.snapshot(self.worktree, payload, self.args, {"ghostty": []})
            remote.mirror_head(payload, manifest, "ghostty", manifest["submodules"]["ghostty"])
            # The rebuilt mirror adopted the head the fixture checkout already had.
            self.assertEqual(remote.held_heads(remote.Transport("local"))["ghostty"], [manifest["submodules"]["ghostty"]])

    def test_reload_build_failure_does_not_stage_or_launch_existing_app(self):
        scripts = self.base / "scripts"
        scripts.mkdir()
        for name in ("reload.sh", "with-build-lock.sh"):
            (scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
            (scripts / name).chmod(0o755)
        # reload.sh sources its c11 dev-link helpers (#17); copy them so the
        # script reaches the build step under test instead of failing to source.
        (scripts / "lib").mkdir()
        for helper in ("c11-dev-shims.sh", "c11-user-paths.sh"):
            (scripts / "lib" / helper).write_bytes((ROOT / "scripts" / "lib" / helper).read_bytes())
        (scripts / "assert-ghosttykit.sh").write_text("#!/bin/sh\nexit 0\n")
        (scripts / "assert-ghosttykit.sh").chmod(0o755)
        fake = self.base / "fake"
        fake.mkdir()
        (fake / "xcodebuild").write_text("#!/bin/sh\necho '** BUILD FAILED **'\nexit 29\n")
        (fake / "xcodebuild").chmod(0o755)
        derived = self.base / "derived"
        app = derived / "Build/Products/Debug/c11 DEV fixture.app"
        app.mkdir(parents=True)
        (app / "sentinel").write_text("existing")
        result = subprocess.run([str(scripts / "reload.sh"), "--tag", "fixture", "--no-launch",
                                 "--derived-data", str(derived)], cwd=self.base,
                                env=dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
                                         C11_BUILD_LOCK_DIR=str(self.base / "lock"),
                                         C11_DEV_RUNTIME_DIR=str(self.base / "runtime")), capture_output=True)
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertEqual((app / "sentinel").read_text(), "existing")

    def test_remote_selected_test_executes_and_failure_is_separate_from_compile(self):
        scripts = self.worktree / "scripts"
        scripts.mkdir()
        (scripts / "host-test-quarantine.tsv").write_text("")
        wrapper = scripts / "test-unit-local.sh"
        wrapper.write_text("#!/bin/sh\n[ \"$1\" = test ] || exit 88\n"
                           "echo \"parallel-workers=${C11_TEST_PARALLEL_WORKERS:-none}\"\n"
                           "echo \"derived-data=$C11_TEST_DERIVED_DATA\"\n"
                           "while [ $# -gt 0 ]; do\n"
                           "  if [ \"$1\" = -resultBundlePath ]; then\n"
                           "    mkdir -p \"$2\"; printf diagnostic > \"$2/failure.txt\"; break\n"
                           "  fi\n  shift\ndone\n"
                           "echo 'Test Suite Fixture started'\n"
                           "echo 'Executed 1 test'\n"
                           "echo '** TEST FAILED **'\nexit 65\n")
        wrapper.chmod(0o755)
        self.args.mode = "test"
        self.args.extra = ["-only-testing:c11LogicTests/Fixture", "-resultBundlePath", "failure.xcresult"]
        manifest = remote.snapshot(self.worktree, self.payload, self.args)
        home = self.base / "home"
        home.mkdir()
        build_root = (home / "cache.noindex").resolve()
        build_root.mkdir()
        (home / remote.BUILD_DIR).symlink_to(build_root)
        fake = self.base / "fake"
        fake.mkdir()
        for name, value in (("xcodebuild", "Xcode 26.3"), ("zig", "0.15.2")):
            path = fake / name
            path.write_text("#!/bin/sh\necho '" + value + "'\n")
            path.chmod(0o755)
        # Manifest points at fake tool directory; the real build wrapper is never called.
        manifest["zig_dir"] = str(fake)
        (self.payload / "identity.json").write_text(json.dumps(manifest))
        with patch.dict(os.environ, HOME=str(home)):
            self.assertEqual(remote.remote(self.payload, locked=True), 65)
        artifacts = home / remote.BUILD_DIR / "fixture/artifacts" / manifest["invocation"]
        result = json.loads((artifacts / "result.json").read_text())
        self.assertEqual(result["compile"], "ok")
        self.assertEqual(result["tests"], "failed")
        self.assertIn("parallel-workers=8", (artifacts / "build.log").read_text())
        self.assertIn("derived-data=" + str(build_root / "fixture/derived-test"), (artifacts / "build.log").read_text())
        self.assertEqual((artifacts / "tests.xcresult/failure.txt").read_text(), "diagnostic")
        # Exercise the client's failed-request retrieval with the emitted artifacts.
        for name in ("remote_build.py", "host_test_quarantine.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *--tag-floor*) exit 0;; *--held-heads*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit 65;; esac\n")
        (fake / "rsync").write_text("#!/bin/sh\nfor last do :; done\ncase \"$*\" in *studio:" + remote.BUILD_DIR +
                                    "/fixture/artifacts/*) cp -R \"$TEST_ARTIFACTS/.\" \"$last\";; esac\n")
        for name in ("ssh", "rsync"):
            (fake / name).chmod(0o755)
        with patch.object(remote, "__file__", str(scripts / "remote_build.py")), \
                patch.dict(os.environ, HOME=str(home), PATH=str(fake) + ":" + os.environ["PATH"],
                           TEST_ARTIFACTS=str(artifacts)):
            self.assertEqual(remote.client(self.args), 65)
        retrieved = list((self.worktree / "build-remote").glob("*/tests.xcresult/failure.txt"))
        self.assertEqual(len(retrieved), 1)
        self.assertEqual(retrieved[0].read_text(), "diagnostic")
        # Reuse the tag after a gitlink changes. Its old bundle origin cannot
        # supply the new module commit; the explicit new module bundle must.
        source = home / remote.BUILD_DIR / "fixture/source"
        git(source, "config", "fetch.recurseSubmodules", "true")
        module = self.worktree / "ghostty"
        git(module, "config", "user.name", "Fixture")
        git(module, "config", "user.email", "fixture@example.invalid")
        (module / "tracked").write_text("new module commit")
        git(module, "commit", "-qam", "advance module")
        git(self.worktree, "add", "ghostty")
        git(self.worktree, "commit", "-qm", "advance gitlink")
        again = self.base / "again"
        again.mkdir()
        updated = remote.snapshot(self.worktree, again, self.args)
        updated["zig_dir"] = str(fake)
        (again / "identity.json").write_text(json.dumps(updated))
        with patch.dict(os.environ, HOME=str(home)):
            self.assertEqual(remote.remote(again, locked=True), 65)
        self.assertEqual(git(source / "ghostty", "rev-parse", "HEAD"), updated["submodules"]["ghostty"])
        self.assertEqual((artifacts / "tests.xcresult/failure.txt").read_text(), "diagnostic")

    def _remote_test_build(self, wrapper_body):
        scripts = self.worktree / "scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "host-test-quarantine.tsv").write_text("")
        wrapper = scripts / "test-unit-local.sh"
        wrapper.write_text(wrapper_body)
        wrapper.chmod(0o755)
        self.args.mode = "test-build"
        self.args.extra = []
        manifest = remote.snapshot(self.worktree, self.payload, self.args)
        home = self.base / "home"
        home.mkdir(exist_ok=True)
        fake = self.base / "fake"
        fake.mkdir(exist_ok=True)
        for name, value in (("xcodebuild", "Xcode 26.3"), ("zig", "0.15.2")):
            path = fake / name
            path.write_text("#!/bin/sh\necho '" + value + "'\n")
            path.chmod(0o755)
        manifest["zig_dir"] = str(fake)
        (self.payload / "identity.json").write_text(json.dumps(manifest))
        with patch.dict(os.environ, HOME=str(home)):
            code = remote.remote(self.payload, locked=True)
        artifacts = home / remote.BUILD_DIR / "fixture/artifacts" / manifest["invocation"]
        return code, json.loads((artifacts / "result.json").read_text()), (artifacts / "build.log").read_text()

    def test_test_build_compiles_test_targets_and_runs_nothing(self):
        # The wrapper refuses any action but build-for-testing, and records the
        # scheme: host tests may not launch an app on the host (CLAUDE.md).
        code, result, log = self._remote_test_build(
            "#!/bin/sh\n[ \"$1\" = build-for-testing ] || exit 88\n"
            "[ $# -eq 1 ] || exit 89\n"
            "echo \"scheme=$C11_TEST_SCHEME\"\n"
            "echo '** TEST BUILD SUCCEEDED **'\n")
        self.assertEqual(code, 0)
        self.assertEqual(result["compile"], "ok")
        self.assertEqual(result["tests"], "na")
        self.assertNotIn("app", result)
        self.assertIn("scheme=c11-unit", log)

    def test_test_build_without_success_marker_fails(self):
        code, result, _ = self._remote_test_build("#!/bin/sh\nexit 0\n")
        self.assertNotEqual(code, 0)
        self.assertFalse(result["ok"])
        self.assertIn("TEST BUILD SUCCEEDED", result["error"])

    def test_kit_route_requires_native_test_marker_and_returns_hashed_archive(self):
        scripts = self.worktree / "scripts"
        scripts.mkdir()
        wrapper = scripts / "build-ghosttykit-admitted.py"
        self.args.mode = "ghosttykit"
        fake = self.base / "kit-tools"
        fake.mkdir()
        for name, value in (("xcodebuild", "Xcode 26.3"), ("zig", "0.15.2")):
            path = fake / name
            path.write_text("#!/bin/sh\necho '" + value + "'\n")
            path.chmod(0o755)
        home = self.base / "kit-home"
        home.mkdir()
        for index, marker in enumerate(["", "C11_GHOSTTY_TEST_OK tests=3"]):
            wrapper.write_text("import pathlib,sys\n"
                               "(pathlib.Path(sys.argv[1])/'GhosttyKit.xcframework.tar.gz').write_bytes(b'fixture-kit')\n"
                               f"print({marker!r})\n")
            payload = self.base / f"kit-payload-{index}"
            payload.mkdir()
            manifest = remote.snapshot(self.worktree, payload, self.args)
            manifest["zig_dir"] = str(fake)
            (payload / "identity.json").write_text(json.dumps(manifest))
            with patch.dict(os.environ, HOME=str(home)):
                code = remote.remote(payload, locked=True)
            artifacts = home / remote.BUILD_DIR / "fixture/artifacts" / manifest["invocation"]
            result = json.loads((artifacts / "result.json").read_text())
            self.assertEqual(code, 0 if marker else 4)
            self.assertEqual(result["ok"], bool(marker))
            self.assertNotIn("app", result)
            if marker:
                self.assertEqual(result["tests"], "ok")
                self.assertEqual(result["kit_sha256"], remote.digest(artifacts / result["kit"]))

    def test_logic_scheme_enables_parallel_workers_in_local_wrapper(self):
        scripts = self.base / "local-wrapper" / "scripts"
        scripts.mkdir(parents=True)
        for name in ("test-unit-local.sh", "with-build-lock.sh"):
            target = scripts / name
            target.write_bytes((ROOT / "scripts" / name).read_bytes())
            target.chmod(0o755)
        (scripts / "assert-ghosttykit.sh").write_text("#!/bin/sh\nexit 0\n")
        (scripts / "assert-ghosttykit.sh").chmod(0o755)
        fake = self.base / "fake-xcode"
        fake.mkdir()
        xcodebuild = fake / "xcodebuild"
        xcodebuild.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n")
        xcodebuild.chmod(0o755)
        capture = self.base / "xcodebuild-args"
        result = subprocess.run(
            [str(scripts / "test-unit-local.sh"), "test", "-only-testing:c11LogicTests/Example"],
            cwd=self.base,
            env=dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
                     C11_BUILD_LOCK="0", C11_TEST_SCHEME="c11-logic",
                     C11_TEST_PARALLEL_WORKERS="8", CAPTURE=str(capture)),
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = capture.read_text().splitlines()
        self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "YES")
        self.assertEqual(args[args.index("-parallel-testing-worker-count") + 1], "8")
        self.assertIn("-only-testing:c11LogicTests/Example", args)

    def test_remote_gate_record_captures_one_host_measurement(self):
        scripts = self.worktree / "scripts"
        scripts.mkdir()
        (scripts / "host-test-quarantine.tsv").write_text("")
        wrapper = scripts / "test-unit-local.sh"
        wrapper.write_text("#!/bin/sh\n"
                           "echo \"Test Suite 'All tests' started at now\"\n"
                           "sleep 0.25\n"
                           "result=\"$C11_TEST_DERIVED_DATA/Logs/Test/Parallel.xcresult\"\n"
                           "mkdir -p \"$result\"\n"
                           "echo 'Test session results, code coverage, and logs:'\n"
                           "printf '\\t%s\\n' \"$result\"\n"
                           "echo '** TEST SUCCEEDED **'\n"
                           "# Parallel xcodebuild output has no Executed N tests summary.\n")
        wrapper.chmod(0o755)
        self.args.mode = "test"
        self.args.extra = ["-only-testing:c11LogicTests/FixtureTests"]
        manifest = remote.snapshot(self.worktree, self.payload, self.args)

        fake = self.base / "tools"
        fake.mkdir()
        for name, version in (("xcodebuild", "Xcode 26.3"), ("zig", "0.15.2")):
            tool = fake / name
            tool.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
            tool.chmod(0o755)
        summary = {"result": "Passed", "passedTests": 3090, "failedTests": 0,
                   "skippedTests": 3, "totalTestCount": 3093}
        xcresulttool = fake / "xcrun"
        xcresulttool.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(summary) + "'\n")
        xcresulttool.chmod(0o755)
        manifest["zig_dir"] = str(fake)
        (self.payload / "identity.json").write_text(json.dumps(manifest))
        for name in ("atlas_build_slots.py", "with-build-lock.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.payload / name)

        home = self.base / "home"
        home.mkdir()
        slots = self.base / "slots"
        load = self.base / "load"
        load.write_text("0")
        env = {
            "HOME": str(home),
            "PATH": os.environ["PATH"],
            "C11_ATLAS_SLOTS_DIR": str(slots),
            "C11_ATLAS_LOAD_FILE": str(load),
            "C11_ATLAS_SLOT_POLL_SECONDS": "0.02",
            "C11_BUILD_LOCK_TIMEOUT": "3",
        }
        started_before = datetime.now().astimezone()
        with patch.dict(os.environ, env):
            self.assertEqual(remote.remote(self.payload), 0)
        finished_after = datetime.now().astimezone()

        artifacts = home / remote.BUILD_DIR / "fixture/artifacts" / manifest["invocation"]
        result = json.loads((artifacts / "result.json").read_text())
        gates = [json.loads(line) for line in (home / remote.BUILD_DIR / "gates.jsonl").read_text().splitlines()]
        self.assertTrue(result["ok"])
        self.assertEqual(result["tests"], "ok")
        self.assertEqual(len(gates), 1)
        gate = gates[0]
        self.assertEqual(set(gate), {
            "tag", "mode", "head", "slot_wait_seconds", "build_seconds",
            "test_seconds", "result", "invocation_id",
            "started", "test_args",
        })
        started = datetime.fromisoformat(gate["started"])
        self.assertIsNotNone(started.utcoffset())
        self.assertLessEqual(started_before, started)
        self.assertLessEqual(started, finished_after)
        self.assertEqual(gate["test_args"], ["-only-testing:c11LogicTests/FixtureTests"])
        self.assertEqual(gate["tag"], "fixture")
        self.assertEqual(gate["mode"], "test")
        self.assertEqual(gate["head"], manifest["head"])
        self.assertEqual(gate["invocation_id"], manifest["invocation"])
        self.assertEqual(gate["result"], "success")
        self.assertGreater(gate["test_seconds"], 0.0)
        self.assertGreaterEqual(gate["build_seconds"], 0.0)
        self.assertGreaterEqual(gate["slot_wait_seconds"], 0.0)
        self.assertEqual(result["test_seconds"], gate["test_seconds"])

    def test_xcresult_zero_executed_tests_is_failure(self):
        bundle = self.base / "Empty.xcresult"
        bundle.mkdir()
        fake = self.base / "xcresulttool"
        fake.mkdir()
        summary = {"result": "Passed", "passedTests": 0, "failedTests": 0,
                   "skippedTests": 0, "totalTestCount": 0}
        tool = fake / "xcrun"
        tool.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(summary) + "'\n")
        tool.chmod(0o755)
        build_log = "Test session results, code coverage, and logs:\n\t" + str(bundle) + "\n** TEST SUCCEEDED **"

        with self.assertRaisesRegex(ValueError, "executed zero tests"):
            remote.require_test_success(build_log, self.base, {"PATH": str(fake)})

    def test_local_host_runs_the_same_admitted_build_command_in_place(self):
        # --host local must reach remote() through the same command as ssh does, so the
        # build takes the same atlas_build_slots admission, only without the ssh hop.
        fixture_scripts = self.worktree / "scripts"
        fixture_scripts.mkdir()
        for name in ("remote_build.py", "host_test_quarantine.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (fixture_scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        fake = self.base / "fake"
        fake.mkdir()
        record = self.base / "record"
        # ssh: answer the held-heads probe and mkdir; record the build command, then fail it.
        (fake / "ssh").write_text(
            "#!/bin/sh\ncase \"$*\" in *--tag-floor*) exit 0;; *--held-heads*) echo '{}'; exit 0;; *mkdir*) exit 0;; esac\n"
            "for last; do :; done\nprintf 'ssh|%s\\n' \"$last\" >>\"$RECORD\"\nexit 23\n")
        (fake / "rsync").write_text("#!/bin/sh\nexit 0\n")
        # python3 on the local path: answer held-heads, record cwd and the build command, fail it.
        real_rsync = shutil.which("rsync")
        # It also leaves an artifact where the host's remote() would, so retrieval is checked.
        (fake / "python3").write_text(
            "#!/bin/sh\ncase \"$*\" in *--tag-floor*) exit 0;; *--held-heads*) cat >/dev/null; echo '{}'; exit 0;; esac\n"
            "printf 'local|%s|python3 %s\\n' \"$PWD\" \"$*\" >>\"$RECORD\"\n"
            "rel=$(echo \"$*\" | sed 's/.*--remote //'); slug=$(echo \"$rel\" | cut -d/ -f2); inv=$(basename \"$rel\")\n"
            "dir=\"" + remote.BUILD_DIR + "/$slug/artifacts/$inv\"; mkdir -p \"$dir\" && echo artifact >\"$dir/marker.txt\"\n"
            "exit 23\n")
        for path in fake.iterdir():
            path.chmod(0o755)
        home = self.base / "home"
        home.mkdir()
        env = {"HOME": str(home), "PATH": str(fake) + ":" + os.environ["PATH"], "RECORD": str(record)}
        with patch.object(remote, "__file__", str(fixture_scripts / "remote_build.py")), patch.dict(os.environ, env):
            self.args.host = "studio"
            self.assertEqual(remote.client(self.args), 23)
            # The local path copies the payload for real, so give it the real rsync.
            (fake / "rsync").unlink()
            (fake / "rsync").symlink_to(real_rsync)
            self.args.host = "local"
            self.assertEqual(remote.client(self.args), 23)
        lines = record.read_text().splitlines()
        self.assertEqual(len(lines), 2, lines)
        ssh_command = lines[0].split("|", 1)[1]
        _, local_cwd, local_command = lines[1].split("|", 2)
        normalize = lambda command: __import__("re").sub(r"[0-9a-f]{32}", "<invocation>", command)
        self.assertIn("remote_build.py --remote", ssh_command)
        self.assertEqual(normalize(local_command), normalize(ssh_command))
        self.assertEqual(os.path.realpath(local_cwd), os.path.realpath(home))
        retrieved = list((self.worktree / "build-remote").glob("*/marker.txt"))
        self.assertEqual(len(retrieved), 1, "local retrieval copies the artifacts' contents, not a nested directory")
        staged = list((home / remote.BUILD_DIR).glob("*/incoming/*/remote_build.py"))
        self.assertEqual(len(staged), 1, "the local transport stages the payload under $HOME like the host")
        self.assertEqual(staged[0].read_bytes(), (ROOT / "scripts/remote_build.py").read_bytes())

    def test_remote_failure_preserves_local_app_and_never_launches(self):
        # Fake transports exercise the actual client failure path, not source structure.
        fixture_scripts = self.worktree / "scripts"
        fixture_scripts.mkdir()
        for name in ("remote_build.py", "host_test_quarantine.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (fixture_scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        fake = self.base / "fake"
        fake.mkdir()
        (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *--tag-floor*) exit 0;; *--held-heads*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit 23;; esac\n")
        (fake / "rsync").write_text("#!/bin/sh\nexit 0\n")
        (fake / "open").write_text("#!/bin/sh\ntouch \"$LAUNCH_MARKER\"\nexit 99\n")
        for path in fake.iterdir():
            path.chmod(0o755)
        home = self.base / "home"
        app = home / "Library/Developer/Xcode/DerivedData/c11-fixture/Build/Products/Debug/c11 DEV fixture.app"
        app.mkdir(parents=True)
        (app / "sentinel").write_text("old artifact")
        marker = self.base / "launched"
        self.args.launch = True
        for status in (23, 3):
            with self.subTest(status=status):
                (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *--tag-floor*) exit 0;; *--held-heads*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit " + str(status) + ";; esac\n")
                with patch.object(remote, "__file__", str(fixture_scripts / "remote_build.py")), \
                        patch.dict(os.environ, {"HOME": str(home), "PATH": str(fake) + ":" + os.environ["PATH"],
                                                "LAUNCH_MARKER": str(marker)}):
                    self.assertEqual(remote.client(self.args), status)
        self.assertEqual((app / "sentinel").read_text(), "old artifact")
        self.assertFalse(marker.exists())

    def floor_client(self, free_gib, slots_script=None, fakes=None, **env):
        """Run the fixture worktree's remote_build.py on --host local against a fake home and free-space reading."""
        scripts = self.worktree / "scripts"
        scripts.mkdir(exist_ok=True)
        for name in ("remote_build.py", "host_test_quarantine.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        (scripts / "with-build-lock.sh").chmod(0o755)
        if slots_script is not None:
            (scripts / "atlas_build_slots.py").write_text(slots_script)
        fake = self.base / "fake"
        fake.mkdir(exist_ok=True)
        for name, text in (fakes or {}).items():
            (fake / name).write_text(text)
            (fake / name).chmod(0o755)
        self.copied = self.base / "copied"
        # Any copy to the host is recorded and fails; a refused tag must never reach it.
        (fake / "rsync").write_text("#!/bin/sh\necho \"$*\" >>\"$COPIED\"\nexit 97\n")
        (fake / "rsync").chmod(0o755)
        self.home = self.base / "home"
        (self.home / remote.BUILD_DIR).mkdir(parents=True, exist_ok=True)
        free = self.base / "free"
        free.write_text(str(free_gib * 1024 ** 3))
        run_env = {k: v for k, v in os.environ.items() if k not in ("C11_ATLAS_ADMISSION_LOG", remote.FLOOR_OVERRIDE_ENV)}
        run_env.update(HOME=str(self.home), PATH=str(fake) + ":" + os.environ["PATH"], COPIED=str(self.copied),
                       C11_ATLAS_FREE_BYTES_FILE=str(free), C11_ATLAS_SLOTS_DIR=str(self.base / "slots"), **env)
        return subprocess.run([sys.executable, str(scripts / "remote_build.py"), "--host", "local", "--tag", "fixture"],
                              cwd=self.worktree, env=run_env, capture_output=True, text=True, timeout=60)

    def floor_rows(self):
        log = self.home / remote.BUILD_DIR / "admission.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_a_new_tag_under_the_floor_is_refused_before_anything_is_copied(self):
        result = self.floor_client(12)
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertIn("refused new tag fixture: 12.0 GiB free", result.stderr)
        self.assertIn("nothing was copied", result.stderr)
        self.assertFalse((self.home / remote.BUILD_DIR / "fixture").exists(), "a refused tag leaves no folder")
        self.assertFalse(self.copied.exists(), "nothing reached the host")
        self.assertFalse((self.worktree / "build-remote").exists())
        self.assertNotIn("staged", result.stdout)
        [row] = self.floor_rows()
        self.assertEqual((row["tag"], row["reason"], row["exit_code"]), ("fixture", "tag_floor", 73))

    def test_a_warm_tag_under_the_floor_goes_on_to_stage(self):
        warm = self.base / "home" / remote.BUILD_DIR / "fixture"
        warm.mkdir(parents=True)
        os.utime(warm, (time.time() - 86400,) * 2)
        result = self.floor_client(1)
        # Past the floor, staging reaches the (failing) copy to the host.
        self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
        self.assertNotIn("refused", result.stderr)
        self.assertTrue(self.copied.exists())
        self.assertEqual(self.floor_rows(), [])

    def test_the_floor_override_is_logged_and_reaches_the_host(self):
        result = self.floor_client(500, C11_BUILD_HOST_FLOOR_GIB="100000")
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        log = (self.home / ".local/state/c11/build-host-floor-overrides.log").read_text().splitlines()
        self.assertEqual(len(log), 1, log)
        self.assertRegex(log[0], r"context=remote-build tag=fixture head=[0-9a-f]+ floor_gib=100000$")
        self.assertIn("build-host floor overridden to 100000 GiB", result.stderr)
        [row] = self.floor_rows()
        self.assertEqual((row["floor_gib"], row["floor_override"]), (100000.0, True))
        self.assertFalse(self.copied.exists())

    def test_an_override_that_cannot_be_logged_stops_before_host_contact(self):
        log = self.base / "home/.local/state/c11/build-host-floor-overrides.log"
        log.mkdir(parents=True)  # a folder where the log should be: the append fails
        result = self.floor_client(500, C11_BUILD_HOST_FLOOR_GIB="100000")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("override not logged", result.stderr)
        self.assertEqual(self.floor_rows(), [], "the floor check never ran")
        self.assertFalse((self.home / remote.BUILD_DIR / "mirrors").exists(), "held-heads never ran")
        self.assertFalse(self.copied.exists())

    def test_a_broken_floor_check_warns_and_builds(self):
        # Only the check's refusal (73) stops a build; any other failure is a broken measurement.
        result = self.floor_client(1, slots_script="import sys\nsys.exit(5)\n")
        self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
        self.assertIn("the build host's floor check failed (exit 5); building without it", result.stderr)
        self.assertTrue(self.copied.exists(), "the build went on to stage")

    def test_a_held_heads_failure_keeps_the_refusal(self):
        real = sys.executable
        python = ("#!/bin/sh\ncase \"$*\" in *--held-heads*) cat >/dev/null; exit 9;; esac\n"
                  "exec " + shlex.quote(real) + " \"$@\"\n")
        result = self.floor_client(12, fakes={"python3": python})
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertIn("refused new tag fixture", result.stderr)
        self.assertFalse(self.copied.exists())

    def test_a_bad_floor_override_is_refused_before_any_host_contact(self):
        fake = self.base / "fake"
        fake.mkdir()
        contacted = self.base / "contacted"
        for name in ("ssh", "rsync"):
            (fake / name).write_text("#!/bin/sh\necho \"$*\" >>\"$CONTACTED\"\nexit 99\n")
            (fake / name).chmod(0o755)
        for value in ("lots", "-5", "nan"):
            env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], CONTACTED=str(contacted),
                       C11_BUILD_HOST_FLOOR_GIB=value)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/remote_build.py"), "--host", "studio",
                                     "--tag", "fixture"], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("C11_BUILD_HOST_FLOOR_GIB takes a number of GiB", result.stderr)
        self.assertFalse(contacted.exists())

    def test_snapshot_refuses_host_selectors_before_writing_a_manifest(self):
        # A c11Tests selector used to snapshot and ship. It now raises before
        # identity.json exists, so the host never receives a test action.
        inventory = self.worktree / "scripts" / "host-test-quarantine.tsv"
        inventory.parent.mkdir()
        inventory.write_text("c11Tests/ExampleTests/testSelected\tatlas\tExplicitly selected.\n")
        self.args.mode = "test"
        self.args.extra = ["-only-testing:c11Tests/ExampleTests/testSelected"]
        with self.assertRaisesRegex(ValueError, "sandbox-up.sh"):
            remote.snapshot(self.worktree, self.payload, self.args)
        self.assertFalse((self.payload / "identity.json").exists())

    def test_default_logic_selector_skips_logic_quarantine_only(self):
        inventory = self.worktree / "scripts" / "host-test-quarantine.tsv"
        inventory.parent.mkdir()
        logic_method = "c11LogicTests/ExampleLogicTests/testRemoteOnly"
        host_method = "c11Tests/ExampleHostTests/testRemoteOnly"
        inventory.write_text(
            f"{logic_method}\tremote\tLogic suite build-host limitation.\n"
            f"{host_method}\tremote\tHost limitation.\n"
        )
        self.args.mode = "test"
        self.args.no_host_quarantine = False
        self.args.extra = []
        manifest = remote.snapshot(self.worktree, self.payload, self.args)

        self.assertEqual(manifest["test_scheme"], "c11-logic")
        self.assertEqual(manifest["test_args"][0], "-only-testing:c11LogicTests")
        self.assertIn("-skip-testing:" + logic_method, manifest["test_args"])
        self.assertNotIn("-skip-testing:" + host_method, manifest["test_args"])
        quarantine = {row["test_id"]: row for row in manifest["host_test_quarantine"]}
        self.assertNotIn(host_method, quarantine)
        self.assertTrue(quarantine[logic_method]["auto_skipped"])
        self.assertFalse(quarantine[logic_method]["explicitly_selected"])

    def test_logic_suite_applies_only_logic_quarantine_and_exact_selection_runs(self):
        inventory = self.worktree / "scripts" / "host-test-quarantine.tsv"
        inventory.parent.mkdir()
        selected = "c11LogicTests/ExampleLogicTests/testSelected"
        atlas_only = "c11LogicTests/ExampleLogicTests/testRemoteOnly"
        host_only = "c11Tests/ExampleHostTests/testRemoteOnly"
        inventory.write_text(
            f"{selected}\tatlas\tExplicitly selected.\n"
            f"{atlas_only}\tatlas\tAtlas limitation.\n"
            f"{host_only}\tatlas\tHost limitation.\n"
        )
        self.args.mode = "test"
        self.args.no_host_quarantine = False
        self.args.extra = ["-only-testing:" + selected]
        manifest = remote.snapshot(self.worktree, self.payload, self.args)

        self.assertEqual(manifest["test_scheme"], "c11-logic")
        self.assertNotIn("-skip-testing:" + selected, manifest["test_args"])
        self.assertIn("-skip-testing:" + atlas_only, manifest["test_args"])
        self.assertNotIn("-skip-testing:" + host_only, manifest["test_args"])


class HostTestSelectorTests(unittest.TestCase):
    def args(self, mode="test", extra=None):
        return argparse.Namespace(mode=mode, extra=[] if extra is None else list(extra))

    def test_no_selector_defaults_to_the_logic_suite(self):
        args = self.args(extra=["-resultBundlePath", "out.xcresult"])
        remote.apply_host_test_policy(args)
        self.assertEqual(args.extra, ["-only-testing:c11LogicTests", "-resultBundlePath", "out.xcresult"])
        remote.apply_host_test_policy(args)
        self.assertEqual(args.extra, ["-only-testing:c11LogicTests", "-resultBundlePath", "out.xcresult"])

    def test_logic_selector_is_unchanged(self):
        extra = ["-only-testing:c11LogicTests/ExampleLogicTests/testSelected", "-resultBundlePath", "out.xcresult"]
        args = self.args(extra=extra)
        remote.apply_host_test_policy(args)
        self.assertEqual(args.extra, extra)

    def test_host_selector_is_refused(self):
        args = self.args(extra=["-only-testing:c11Tests/ExampleTests/testHost"])
        with self.assertRaisesRegex(ValueError, "no Xcode") as raised:
            remote.apply_host_test_policy(args)
        message = str(raised.exception)
        self.assertIn("-only-testing:c11Tests/ExampleTests/testHost", message)
        self.assertIn("sandbox-up.sh", message)
        self.assertIn("sandbox-tests-v2.sh", message)
        self.assertIn("compile-only", message)

    def test_ui_test_selector_is_refused(self):
        args = self.args(extra=["-only-testing:c11UITests/ExampleUITests"])
        with self.assertRaisesRegex(ValueError, "c11UITests"):
            remote.apply_host_test_policy(args)

    def test_mixed_selectors_are_refused(self):
        args = self.args(extra=[
            "-only-testing:c11LogicTests/ExampleLogicTests",
            "-only-testing:c11Tests/ExampleTests/testHost",
        ])
        with self.assertRaisesRegex(ValueError, "c11Tests/ExampleTests/testHost"):
            remote.apply_host_test_policy(args)
        self.assertEqual(args.extra[0], "-only-testing:c11LogicTests/ExampleLogicTests")

    def test_unknown_target_is_refused(self):
        args = self.args(extra=["-only-testing:SomeOtherTarget/Example"])
        with self.assertRaisesRegex(ValueError, "SomeOtherTarget/Example"):
            remote.apply_host_test_policy(args)

    def test_other_modes_do_not_inject_a_selector(self):
        for mode in ("debug", "test-build", "release", "ghosttykit"):
            args = self.args(mode=mode, extra=[])
            remote.apply_host_test_policy(args)
            self.assertEqual(args.extra, [], mode)

    def test_refused_invocation_ships_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            fake = base / "bin"
            fake.mkdir()
            shipped = base / "shipped"
            (fake / "ssh").write_text("#!/bin/sh\necho shipped > \"$SHIPPED\"\nexit 99\n")
            (fake / "rsync").write_text("#!/bin/sh\necho shipped > \"$SHIPPED\"\nexit 99\n")
            for name in ("ssh", "rsync"):
                (fake / name).chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], SHIPPED=str(shipped),
                       C11_REMOTE_HOST="studio")
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/remote_build.py"),
                 "--tag", "c11-orch2", "--mode", "test", "--",
                 "-only-testing:c11Tests/ExampleTests/testHost"],
                env=env, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertFalse(shipped.exists())
        self.assertNotIn("staged", result.stdout)
        self.assertIn("sandbox-up.sh", result.stderr)
        self.assertIn("no Xcode", result.stderr)


class QuarantineInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        self.inventory = self.root / "scripts" / "host-test-quarantine.tsv"

    def test_exact_methods_and_reasons_are_returned(self):
        self.inventory.write_text(
            "# exact host test methods\n"
            "c11Tests/ExampleTests/testFirst\tall\tReason one.\n"
            "c11Tests/ExampleTests/testSecond\tremote\tReason two.\n"
            "c11Tests/ExampleTests/testThird\tatlas\tAn older inventory's name for remote.\n"
        )
        self.assertEqual(
            remote.read_host_test_quarantine(self.root),
            [
                {"test_id": "c11Tests/ExampleTests/testFirst", "scope": "all", "reason": "Reason one."},
                {"test_id": "c11Tests/ExampleTests/testSecond", "scope": "remote", "reason": "Reason two."},
                {"test_id": "c11Tests/ExampleTests/testThird", "scope": "remote",
                 "reason": "An older inventory's name for remote."},
            ],
        )

    def test_the_real_inventory_stays_readable_by_the_installed_poller_and_backstop(self):
        # The PR poller and main backstop installed on the build host parse the scope with their own
        # 1.x copies, which know only "all" and remote's 1.x name. Until both are updated, the file
        # keeps that name (every reader here takes it as remote), or each gate reports the inventory
        # unreadable (C11H-284).
        installed = {"all", "at" + "las"}
        for line in (ROOT / "scripts" / "host-test-quarantine.tsv").read_text().splitlines():
            if line and not line.startswith("#"):
                self.assertIn(line.split("\t")[1], installed, line)
        self.assertEqual({row["scope"] for row in remote.read_host_test_quarantine(ROOT)}, {"all", "remote"})

    def test_ci_actions_skip_all_scope_and_keep_remote_scope_running(self):
        helper = ROOT / "scripts" / "host_test_quarantine.py"
        output = subprocess.check_output(
            [sys.executable, str(helper), "--ci-actions"], text=True
        )
        actions = {
            fields[1]: fields[0]
            for line in output.splitlines()
            if (fields := line.split("\t", 3))
        }
        self.assertEqual(actions[
            "c11Tests/WindowCloseShortcutTests/testCmdWClosesAuxiliaryWindowInsteadOfMainTerminalPanel"
        ], "run")
        self.assertEqual(actions[
            "c11Tests/GhosttySurfaceOverlayTests/testSearchOverlayFocusesSearchFieldAfterDeferredAttach"
        ], "run")
        for test_id in (
            "c11LogicTests/FullDiskAccessProbeTests/testProbeKickRunsExtraAttemptOutOfBand",
            "c11LogicTests/MailboxPanelMailTests/testWarmScanOfFiveThousandEnvelopesParsesNothingAgain",
            "c11LogicTests/MailboxReceiptStatusTests/testFiveThousandEnvelopeQueryIsBounded",
        ):
            self.assertEqual(actions[test_id], "run")
        self.assertEqual(actions[
            "c11Tests/GhosttyBackquoteRegressionTests/testShiftBackquoteEscFallbackSendsLiteralTilde"
        ], "skip")

    def test_class_selector_is_rejected(self):
        self.inventory.write_text("c11Tests/ExampleTests\tall\tA class is too broad.\n")
        with self.assertRaisesRegex(ValueError, "exact c11Tests or c11LogicTests method"):
            remote.read_host_test_quarantine(self.root)

    def test_missing_reason_is_rejected(self):
        self.inventory.write_text("c11Tests/ExampleTests/testFirst\tall\t \n")
        with self.assertRaisesRegex(ValueError, "one-line reason"):
            remote.read_host_test_quarantine(self.root)

    def test_unknown_scope_is_rejected(self):
        self.inventory.write_text("c11Tests/ExampleTests/testFirst\tmacos\tWrong scope.\n")
        with self.assertRaisesRegex(ValueError, "scope must be all or remote"):
            remote.read_host_test_quarantine(self.root)

    def test_duplicate_selector_is_rejected(self):
        self.inventory.write_text(
            "c11Tests/ExampleTests/testFirst\tall\tFirst reason.\n"
            "c11Tests/ExampleTests/testFirst\tatlas\tSecond reason.\n"
        )
        with self.assertRaisesRegex(ValueError, "duplicate host quarantine selector"):
            remote.read_host_test_quarantine(self.root)


class TestPhaseObservationTests(unittest.TestCase):
    def test_markers_split_between_reads_include_the_final_flush(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.touch()
            chunks = iter([
                ("Test Suite 'All te", None),
                ("sts' started at now\n", None),
                ("test body\n", None),
                ("** TEST SUC", None),
                ("CEEDED **\n", 0),
            ])

            class Process:
                def poll(self):
                    chunk, status = next(chunks)
                    with log.open("a") as output:
                        output.write(chunk)
                    return status

            with patch.object(remote.time, "monotonic", side_effect=[10, 11, 12, 13, 14]), \
                    patch.object(remote.time, "sleep"):
                self.assertEqual(remote.observe_test_phase(Process(), log), 3.0)


class DevHostsTests(unittest.TestCase):
    """The host comes from --host, then the environment, then ~/.config/c11/dev-hosts; never a default."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.config = Path(self.tmp.name) / "dev-hosts"
        self.config.write_text("# sample\nC11_REMOTE_HOST=old\n  C11_REMOTE_HOST = studio  \n#C11_REMOTE_HOST=commented\n"
                               "C11_SANDBOX_HOST=local\n")
        self.env = {k: v for k, v in os.environ.items() if k not in ("C11_REMOTE_HOST", "C11_SANDBOX_HOST")}
        self.env["C11_DEV_HOSTS"] = str(self.config)

    def tearDown(self):
        self.tmp.cleanup()

    def shell(self, key, env):
        return subprocess.run(["bash", "-c", 'source "$1"; c11_dev_host "$2" --host', "-",
                               str(ROOT / "scripts/dev-hosts.sh"), key], env=env, capture_output=True, text=True)

    def python(self, key, env):
        return subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import dev_hosts; "
                               "print(dev_hosts.dev_host(sys.argv[2], '--host'))", str(ROOT / "scripts"), key],
                              env=env, capture_output=True, text=True)

    def test_both_readers_take_the_environment_then_the_file(self):
        for read in (self.shell, self.python):
            self.assertEqual(read("C11_REMOTE_HOST", self.env).stdout, "studio\n")
            self.assertEqual(read("C11_SANDBOX_HOST", self.env).stdout, "local\n")
            self.assertEqual(read("C11_REMOTE_HOST", {**self.env, "C11_REMOTE_HOST": "envhost"}).stdout, "envhost\n")

    def test_unset_fails_naming_the_variable(self):
        env = {**self.env, "C11_DEV_HOSTS": str(Path(self.tmp.name) / "missing")}
        want = ("C11_SIGNING_HOST is unset: pass --host, export it, or add C11_SIGNING_HOST=<ssh host> to "
                + env["C11_DEV_HOSTS"] + "\n")
        for read in (self.shell, self.python):
            proc = read("C11_SIGNING_HOST", env)
            self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (2, "", want))

    def test_remote_build_without_a_host_exits_2_naming_c11_remote_host(self):
        env = {**self.env, "C11_DEV_HOSTS": str(Path(self.tmp.name) / "missing")}
        proc = subprocess.run([sys.executable, str(ROOT / "scripts/remote_build.py"), "--tag", "fixture"],
                              env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertTrue(proc.stderr.startswith("C11_REMOTE_HOST is unset: pass --host"), proc.stderr)


class CliPointerTests(unittest.TestCase):
    """C11H-364 L21: after a debug build, `c11-dev` runs the CLI that build installed, and no
    pointer is ever written through a link or into another account's file. Everything lives in
    this test's own temporary root; the /tmp name is passed explicitly."""

    SHIMS = ROOT / "scripts/lib/c11-dev-shims.sh"
    PATHS = ROOT / "scripts/lib/c11-user-paths.sh"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.runtime = self.base / "runtime" / "c11"
        self.legacy = self.base / "shared-tmp" / "c11-last-cli-path"
        self.legacy.parent.mkdir()
        (self.base / "links").mkdir()
        environment = patch.dict(os.environ, {
            "C11_DEV_RUNTIME_DIR": str(self.runtime),
            "C11_DEV_LINK_DIR": str(self.base / "links"),
            "C11_DEV_SHIM_DIR": str(self.base / "bin"),
        })
        environment.start()
        self.addCleanup(environment.stop)

    def fake_cli(self, name, word):
        path = self.base / name
        path.write_text(f"#!/bin/sh\necho {word}\n")
        path.chmod(0o755)
        return path

    def run_shim(self):
        return subprocess.run([str(self.base / "bin/c11-dev")], capture_output=True, text=True, timeout=10)

    def test_shim_runs_the_cli_remote_build_published(self):
        old, new = self.fake_cli("old-c11", "OLD"), self.fake_cli("new-c11", "NEW")
        subprocess.run(["bash", "-c", 'source "$1"; install_c11_dev_cli_links "$2"', "_", str(self.SHIMS), str(old)],
                       check=True, timeout=20)
        self.assertEqual(self.run_shim().stdout.strip(), "OLD")

        remote.publish_cli_pointer(new, legacy=self.legacy)

        result = self.run_shim()
        self.assertEqual(result.stdout.strip(), "NEW", result.stderr)
        pointer = self.runtime / "c11-last-cli-path"
        self.assertEqual(pointer.read_text(), f"{new}\n")
        self.assertEqual(stat.S_IMODE(os.lstat(pointer).st_mode), 0o600)
        self.assertEqual(self.legacy.read_text(), f"{new}\n")

    def test_a_link_at_the_tmp_pointer_is_replaced_not_written_through(self):
        victim = self.base / "victim"
        victim.write_text("victim\n")
        self.legacy.symlink_to(victim)

        remote.publish_cli_pointer(self.base / "new-c11", legacy=self.legacy)

        self.assertEqual(victim.read_text(), "victim\n")
        info = os.lstat(self.legacy)
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(self.legacy.read_text(), f"{self.base / 'new-c11'}\n")

    def test_a_pointer_another_uid_owns_is_left_alone(self):
        self.runtime.mkdir(parents=True, mode=0o700)
        mine = self.runtime / "c11-last-cli-path"
        for path in (mine, self.legacy):
            path.write_text("/theirs/c11\n")

        written = remote.publish_cli_pointer(self.base / "new-c11", legacy=self.legacy, uid=os.getuid() + 4242)

        self.assertEqual(written, [])
        for path in (mine, self.legacy):
            self.assertEqual(path.read_text(), "/theirs/c11\n")

    def test_folder_is_the_one_the_shell_library_resolves(self):
        with patch.dict(os.environ):
            os.environ.pop("C11_DEV_RUNTIME_DIR")
            shell = subprocess.run(["bash", "-c", 'source "$1"; c11_user_runtime_dir', "_", str(self.PATHS)],
                                   capture_output=True, text=True, timeout=10, check=True).stdout.strip()
            self.assertEqual(str(remote.c11_user_runtime_dir()), shell)


if __name__ == "__main__":
    unittest.main()
