#!/usr/bin/env python3
"""Behavioral transport/overlay/result tests. Run on Atlas; no Xcode required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
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
                           "echo 'Test Suite Fixture started'\n"
                           "echo 'Executed 1 test'\n"
                           "echo '** TEST FAILED **'\nexit 65\n")
        wrapper.chmod(0o755)
        self.args.mode = "test"
        self.args.extra = ["-only-testing:c11LogicTests/Fixture"]
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
        result = json.loads((home / "c11-builds/fixture/artifacts" / manifest["invocation"] / "result.json").read_text())
        self.assertEqual(result["compile"], "ok")
        self.assertEqual(result["tests"], "failed")

    def test_remote_failure_preserves_local_app_and_never_launches(self):
        # Fake transports exercise the actual client failure path, not source structure.
        fixture_scripts = self.worktree / "scripts"
        fixture_scripts.mkdir()
        for name in ("remote_build.py", "atlas_build_slots.py", "with-build-lock.sh"):
            (fixture_scripts / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        fake = self.base / "fake"
        fake.mkdir()
        (fake / "ssh").write_text("#!/bin/sh\ncase \"$*\" in *mkdir*) exit 0;; *) exit 23;; esac\n")
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
        with patch.object(remote, "__file__", str(fixture_scripts / "remote_build.py")), \
                patch.dict(os.environ, {"HOME": str(home), "PATH": str(fake) + ":" + os.environ["PATH"],
                                        "LAUNCH_MARKER": str(marker)}):
            self.assertEqual(remote.client(self.args), 23)
        self.assertEqual((app / "sentinel").read_text(), "old artifact")
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
