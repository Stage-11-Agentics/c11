#!/usr/bin/env python3
"""Filesystem/process-seam tests; never install, signal or execute a real hc."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/c11-install-remote-hc.py"
spec = importlib.util.spec_from_file_location("remote_hc_installer", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class FakeSigner:
    """A process seam models codesign's requirements, not source text."""

    def __init__(self, case):
        self.case = case
        self.calls = []
        self.mutate = None
        self.app = dict(apple=True, team="UKQ4QALWD4", identifier="com.stage11.c11")
        self.helper = dict(apple=True, team="UKQ4QALWD4", identifier="com.stage11.c11.herdr-core")

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        self.case.assertEqual(argv[0], "/usr/bin/codesign")
        for flag in ("--verify", "--strict", "--all-architectures", "--test-requirement"):
            self.case.assertIn(flag, argv)
        target = self.app if argv[-1].endswith(".app") else self.helper
        requirement = argv[argv.index("--test-requirement") + 1]
        valid = target["apple"]
        if "anchor apple generic" not in requirement:
            valid = True  # A self-signed team would pass a missing-anchor mutant.
        if "identifier" in requirement:
            valid = valid and ('identifier "%s"' % target["identifier"]) in requirement
        if "subject.OU" in requirement:
            valid = valid and ('subject.OU] = "%s"' % target["team"]) in requirement
        if self.mutate:
            self.mutate(argv)
        return subprocess.CompletedProcess(argv, 0 if valid else 1, b"", b"")


def file_state(path):
    info = path.stat()
    return (info.st_ino, info.st_mtime_ns, stat.S_IMODE(info.st_mode), path.read_bytes())


class RemoteHCInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-remote-hc-")
        self.root = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.make_writable)
        self.home = self.root / "home"
        self.home.mkdir()
        self.app = self.root / "c11.app"
        self.helper = self.app / "Contents/Helpers/herdr-core"
        self.helper.parent.mkdir(parents=True)
        # If the installer accidentally executes its payload, this leaves proof.
        self.marker = self.root / "executed"
        self.payload = ('#!/bin/sh\necho executed > "%s"\n' % self.marker).encode()
        self.helper.write_bytes(self.payload)
        self.helper.chmod(0o755)
        self.manifest = self.app / "Contents/Resources/hc-pin.json"
        self.manifest.parent.mkdir()
        self.record = {"version": "0.1.16", "protocolGeneration": 1,
                       "sourceSHA256": "5" * 64,
                       "executableSHA256": hashlib.sha256(self.payload).hexdigest()}
        self.save_manifest()
        self.signer = FakeSigner(self)
        self.dest = (self.home / ".local/share/c11/hc"
                     / ("0.1.16-" + self.record["executableSHA256"][:12]) / "herdr-core")
        self.config = self.home / ".local/share/c11/config/herdr-core/config.toml"

    def make_writable(self):
        for base, dirs, files in os.walk(self.root, followlinks=False):
            for name in [base] + [str(Path(base) / n) for n in dirs + files]:
                path = Path(name)
                if not path.is_symlink():
                    path.chmod(path.stat().st_mode | stat.S_IWUSR)

    def save_manifest(self):
        self.manifest.write_text(json.dumps(self.record))

    def install(self):
        return installer.install(self.app, self.home, run=self.signer)

    def assert_refused(self, reason=None):
        with self.assertRaises((installer.InstallError, OSError)) as raised:
            self.install()
        if reason:
            self.assertIn(reason, str(raised.exception))
        self.assertFalse(self.marker.exists(), "the helper must never execute")
        return raised

    def test_install_is_locked_private_and_repeat_is_inode_and_mtime_noop(self):
        result = self.install()
        self.assertEqual(result["status"], "installed")
        self.assertEqual(result["path"], str(self.dest))
        self.assertEqual(result["sha256"], hashlib.sha256(self.payload).hexdigest())
        self.assertEqual(self.dest.read_bytes(), self.payload)
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE(self.dest.parent.stat().st_mode), 0o555)
        self.assertEqual(self.config.read_bytes(), b'headless = "200x120"\n')
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        for path in (self.config.parent, self.config.parent.parent):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        before = (file_state(self.dest), file_state(self.config), self.dest.parent.stat().st_mtime_ns)
        second = self.install()
        self.assertEqual(second["status"], "unchanged")
        self.assertFalse(second["config_changed"])
        self.assertEqual(before, (file_state(self.dest), file_state(self.config), self.dest.parent.stat().st_mtime_ns))
        self.assertEqual(len(self.signer.calls), 4)
        self.assertFalse(self.marker.exists())

    def test_config_replacement_is_atomic_and_does_not_touch_shared_config(self):
        shared = self.home / ".config/herdr-core/config.toml"
        shared.parent.mkdir(parents=True)
        shared.write_text('headless = "10x10"\n')
        shared_before = file_state(shared)
        self.config.parent.mkdir(parents=True)
        self.config.write_text("old config")
        with self.config.open("rb") as old:
            old_inode = os.fstat(old.fileno()).st_ino
            self.install()
            self.assertEqual(old.read(), b"old config")
            self.assertNotEqual(self.config.stat().st_ino, old_inode)
        self.assertEqual(file_state(shared), shared_before)

    def test_fixed_trust_rejects_unsigned_self_signed_wrong_team_and_wrong_identifiers(self):
        for target in (self.signer.app, self.signer.helper):
            for key, bad in (("apple", False), ("team", "ATTACKER01"), ("identifier", "unrelated.tool")):
                with self.subTest(target=target.copy(), field=key):
                    previous = target[key]
                    target[key] = bad
                    self.assert_refused("signature")
                    self.assertEqual(list(self.home.iterdir()), [])
                    target[key] = previous

    def test_shipped_hash_admits_known_bytes_without_signature(self):
        self.signer.app["apple"] = False
        self.signer.helper["apple"] = False
        with mock.patch.object(installer, "SHIPPED_HELPER_SHA256", {self.record["executableSHA256"]}):
            self.install()
        self.assertEqual(self.signer.calls, [])
        self.assertEqual(self.dest.read_bytes(), self.payload)

    def test_even_shipped_hash_requires_matching_actual_bytes(self):
        self.helper.write_bytes(b"untrusted substituted bytes")
        with mock.patch.object(installer, "SHIPPED_HELPER_SHA256", {self.record["executableSHA256"]}):
            self.assert_refused("manifest")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_manifest_validation_and_non_executable_helper_refuse_before_writes(self):
        good = self.record.copy()
        cases = [("version", "../escape"), ("version", "."), ("protocolGeneration", True),
                 ("protocolGeneration", 0), ("sourceSHA256", "bad"), ("executableSHA256", "0" * 64)]
        for key, value in cases:
            with self.subTest(field=key, value=value):
                self.record = dict(good, **{key: value})
                self.save_manifest()
                self.assert_refused("manifest" if key == "executableSHA256" else "hc-pin.json")
                self.assertEqual(list(self.home.iterdir()), [])
        self.record = good
        self.save_manifest()
        self.helper.chmod(0o644)
        self.assert_refused("executable")

    def test_duplicate_oversized_and_missing_manifest_are_refused(self):
        self.manifest.write_text('{"version":"1","version":"2"}')
        self.assert_refused("duplicate")
        self.manifest.write_bytes(b" " * (installer.MANIFEST_MAX_BYTES + 1))
        self.assert_refused("size limit")
        self.manifest.unlink()
        self.assert_refused()
        self.assertEqual(list(self.home.iterdir()), [])

    def test_signature_time_mutations_cannot_change_the_bytes_or_manifest(self):
        for mutate in ("replace helper", "in-place helper", "replace manifest", "replace parent"):
            with self.subTest(mutation=mutate):
                def change(argv):
                    if argv[-1].endswith(".app"):
                        return
                    if mutate == "replace helper":
                        self.helper.unlink()
                        self.helper.write_bytes(self.payload)
                    elif mutate == "in-place helper":
                        self.helper.write_bytes(self.payload)
                    elif mutate == "replace manifest":
                        self.manifest.unlink()
                        self.save_manifest()
                    else:
                        moved = self.helper.parent.with_name("original")
                        self.helper.parent.rename(moved)
                        shutil.copytree(moved, self.helper.parent)
                self.signer.mutate = change
                self.assert_refused("changed")
                self.assertEqual(list(self.home.iterdir()), [])
                self.signer.mutate = None
                self.helper.chmod(0o755)

    def test_source_symlinks_and_nonregular_files_are_refused(self):
        for path in (self.helper, self.manifest):
            with self.subTest(path=path):
                data, mode = path.read_bytes(), path.stat().st_mode
                backing = self.root / "backing"
                backing.write_bytes(data)
                path.unlink()
                path.symlink_to(backing)
                self.assert_refused()
                path.unlink()
                os.mkfifo(path)
                self.assert_refused("not regular")
                path.unlink()
                path.write_bytes(data)
                path.chmod(mode)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_destination_symlink_ancestors_are_refused_before_any_write(self):
        suffixes = (".local", ".local/share", ".local/share/c11", ".local/share/c11/hc",
                    str(self.dest.parent.relative_to(self.home)), ".local/share/c11/config",
                    ".local/share/c11/config/herdr-core")
        target = self.root / "elsewhere"
        target.mkdir()
        for suffix in suffixes:
            with self.subTest(ancestor=suffix):
                link = self.home / suffix
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(target, target_is_directory=True)
                self.assert_refused("directory")
                self.assertEqual(list(target.iterdir()), [])
                link.unlink()
                shutil.rmtree(self.home)
                self.home.mkdir()
        real_home = self.home.with_name("real-home")
        self.home.rename(real_home)
        self.home.symlink_to(real_home, target_is_directory=True)
        self.assert_refused("directory")
        self.assertEqual(list(real_home.iterdir()), [])

    def test_destination_non_directory_and_wrong_owner_are_refused(self):
        (self.home / ".local").write_text("not a directory")
        self.assert_refused("directory")
        (self.home / ".local").unlink()
        with mock.patch.object(installer.os, "getuid", return_value=os.getuid() + 1):
            self.assert_refused("not owned")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_destination_files_cannot_be_symlinks_or_nonregular(self):
        for path in (self.dest, self.config):
            path.parent.mkdir(parents=True, exist_ok=True)
            for kind in ("symlink", "fifo", "directory"):
                with self.subTest(path=path, kind=kind):
                    if kind == "symlink":
                        path.symlink_to(self.helper)
                    elif kind == "fifo":
                        os.mkfifo(path)
                    else:
                        path.mkdir()
                    self.assert_refused()
                    if kind == "directory":
                        path.rmdir()
                    else:
                        path.unlink()
            shutil.rmtree(self.home / ".local")

    def test_hash_key_collision_never_replaces_existing_helper(self):
        self.dest.parent.mkdir(parents=True)
        self.dest.write_bytes(b"already serving, mismatched bytes")
        before = file_state(self.dest)
        self.assert_refused("different hash")
        self.assertEqual(before, file_state(self.dest))
        self.assertFalse(self.config.exists())

    def test_existing_incomplete_key_is_refused(self):
        self.dest.parent.mkdir(parents=True)
        self.assert_refused("no helper")
        self.assertEqual(list(self.dest.parent.iterdir()), [])

    def test_existing_matching_bytes_are_locked_without_replacing_files(self):
        self.dest.parent.mkdir(parents=True)
        self.dest.write_bytes(self.payload)
        self.dest.chmod(0o755)
        self.config.parent.mkdir(parents=True)
        self.config.write_bytes(b'headless = "200x120"\n')
        self.config.chmod(0o644)
        before = (self.dest.stat().st_ino, self.dest.stat().st_mtime_ns,
                  self.config.stat().st_ino, self.config.stat().st_mtime_ns)
        self.install()
        self.assertEqual(before, (self.dest.stat().st_ino, self.dest.stat().st_mtime_ns,
                                 self.config.stat().st_ino, self.config.stat().st_mtime_ns))
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE(self.dest.parent.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_relative_traversal_and_symlinked_source_ancestors_are_refused(self):
        for app, home in ((Path("relative.app"), self.home),
                          (self.app, Path("relative")),
                          (self.app, self.home / ".." / "home")):
            with self.subTest(app=app, home=home):
                with self.assertRaises(installer.InstallError):
                    installer.install(app, home, run=self.signer)
        moved = self.helper.parent.with_name("moved")
        self.helper.parent.rename(moved)
        self.helper.parent.symlink_to(moved, target_is_directory=True)
        self.assert_refused("directory")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_staged_copy_is_hashed_before_publication(self):
        original = installer.write_all
        def corrupt(fd, data):
            original(fd, b"X" * len(data))
        with mock.patch.object(installer, "write_all", side_effect=corrupt):
            self.assert_refused("copied helper hash")
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.config.exists())

    def test_source_change_during_copy_refuses_publication(self):
        original = installer.write_all
        def change(fd, data):
            original(fd, data)
            self.helper.write_bytes(self.payload)
        with mock.patch.object(installer, "write_all", side_effect=change):
            self.assert_refused("changed")
        self.assertFalse(self.dest.exists())

    def test_config_appearing_after_preflight_is_not_replaced(self):
        original = installer.temporary_file
        count = 0
        def appeared(parent):
            nonlocal count
            result = original(parent)
            count += 1
            if count == 2:
                self.config.write_bytes(b"concurrent config")
            return result
        with mock.patch.object(installer, "temporary_file", side_effect=appeared):
            self.assert_refused("appeared")
        self.assertEqual(self.config.read_bytes(), b"concurrent config")
        self.assertEqual(self.dest.read_bytes(), self.payload)

    def test_helper_appearing_at_publication_is_not_replaced(self):
        original = installer.os.link
        def appeared(*args, **kwargs):
            self.dest.write_bytes(b"concurrent serving file")
            return original(*args, **kwargs)
        with mock.patch.object(installer.os, "link", side_effect=appeared):
            self.assert_refused()
        self.assertEqual(self.dest.read_bytes(), b"concurrent serving file")
        self.assertFalse(self.config.exists())

    def test_link_install_from_routes_to_trust_check_before_any_write(self):
        link = SCRIPT.with_name("c11-atlas-link.sh")
        env = dict(os.environ, HOME=str(self.home))
        proc = subprocess.run([str(link), "install", "--from", str(self.app)],
                              env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("signature", proc.stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertFalse(self.marker.exists())
        for args in (["--from"], ["--from", str(self.app), "--pin", "0.1.16"]):
            proc = subprocess.run([str(link), "install", *args], env=env,
                                  capture_output=True, text=True, timeout=5)
            self.assertEqual(proc.returncode, 2, proc.stderr)
            self.assertIn("needs one app path", proc.stderr)

    def test_cli_cannot_override_trust_with_environment_or_path(self):
        fake = self.root / "codesign"
        fake.write_text('#!/bin/sh\necho bypass > "%s"\nexit 0\n' % self.marker)
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(self.root), C11_CODESIGN=str(fake),
                   C11_TRUSTED_TEAM="ATTACKER01", C11_SKIP_SIGNATURE="1")
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "--from", str(self.app),
                               "--home", str(self.home)], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
