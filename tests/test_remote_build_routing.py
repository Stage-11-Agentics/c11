#!/usr/bin/env python3
"""Behavioral transport/overlay/result tests. Run on Atlas; no Xcode required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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
                                      launch=False, host="atlas")

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
                    artifacts = home / "c11-builds/fixture/artifacts" / manifest["invocation"]
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
        source = home / "c11-builds/fixture/source"
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
            held = remote.held_heads(["bash", "-c"])
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
            held = remote.held_heads(["bash", "-c"])
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
        shutil.rmtree(home / "c11-builds/mirrors")
        with patch.dict(os.environ, HOME=str(home)):
            held = remote.held_heads(["bash", "-c"])
        self.assertEqual(held["parent"], [git(self.worktree, "rev-parse", "HEAD")])
        self.assertEqual(held["ghostty"], [git(self.worktree / "ghostty", "rev-parse", "HEAD")])
        self.advance("after migration")
        _, manifest = self.stage(home, held)
        self.assertEqual(manifest["bundles"], {"parent": "incremental"})

    def test_reload_build_failure_does_not_stage_or_launch_existing_app(self):
        scripts = self.base / "scripts"
        scripts.mkdir()
        for name in ("reload.sh", "with-build-lock.sh"):
            (scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
            (scripts / name).chmod(0o755)
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
                                         C11_BUILD_LOCK_DIR=str(self.base / "lock")), capture_output=True)
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertEqual((app / "sentinel").read_text(), "existing")

    def test_remote_selected_test_executes_and_failure_is_separate_from_compile(self):
        scripts = self.worktree / "scripts"
        scripts.mkdir()
        wrapper = scripts / "test-unit-local.sh"
        wrapper.write_text("#!/bin/sh\n[ \"$1\" = test ] || exit 88\n"
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
        artifacts = home / "c11-builds/fixture/artifacts" / manifest["invocation"]
        result = json.loads((artifacts / "result.json").read_text())
        self.assertEqual(result["compile"], "ok")
        self.assertEqual(result["tests"], "failed")
        self.assertEqual((artifacts / "tests.xcresult/failure.txt").read_text(), "diagnostic")
        # Exercise the client's failed-request retrieval with the emitted artifacts.
        for name in ("remote_build.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *'python3 -c'*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit 65;; esac\n")
        (fake / "rsync").write_text("#!/bin/sh\nfor last do :; done\ncase \"$*\" in *atlas:c11-builds/fixture/artifacts/*) cp -R \"$TEST_ARTIFACTS/.\" \"$last\";; esac\n")
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
        source = home / "c11-builds/fixture/source"
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

    def test_remote_failure_preserves_local_app_and_never_launches(self):
        # Fake transports exercise the actual client failure path, not source structure.
        fixture_scripts = self.worktree / "scripts"
        fixture_scripts.mkdir()
        for name in ("remote_build.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (fixture_scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        fake = self.base / "fake"
        fake.mkdir()
        (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *'python3 -c'*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit 23;; esac\n")
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
                (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *'python3 -c'*) echo '{}'; exit 0;; *mkdir*) exit 0;; *) exit " + str(status) + ";; esac\n")
                with patch.object(remote, "__file__", str(fixture_scripts / "remote_build.py")), \
                        patch.dict(os.environ, {"HOME": str(home), "PATH": str(fake) + ":" + os.environ["PATH"],
                                                "LAUNCH_MARKER": str(marker)}):
                    self.assertEqual(remote.client(self.args), status)
        self.assertEqual((app / "sentinel").read_text(), "old artifact")
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
