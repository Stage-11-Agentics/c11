#!/usr/bin/env python3
"""Behavioral tests for scripts/c11-release.sh. They do not unlock a keychain."""

import datetime
import hashlib
import json
import shutil
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = Path(os.environ.get("C11_RELEASE_BIN", ROOT / "scripts" / "c11-release.sh"))
BUNDLE = "com.stage11.c11"
LEGACY_BUNDLE = "com.stage11.c11h"  # c11-2.0:keep (the retired bundle release never signs)
PASSWORD = "test-pass-not-real"


def write_app(path: Path, bundle_id: str, extra=None):
    mac = path / "Contents" / "MacOS"
    mac.mkdir(parents=True)
    (mac / "c11").write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 16)
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "c11",
        "CFBundleExecutable": "c11",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1",
        "CFBundleVersion": "1",
        "SUFeedURL": "https://example.invalid/appcast.xml",
        "SUPublicEDKey": "not-a-real-key",
    }
    if extra:
        info.update(extra)
    with (path / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)


HEAD = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short=9", "HEAD"],
                      check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-release-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.artifact = self.root / "out" / "c11-macos.zip"
        self.security_log = self.root / "security.log"
        self.codesign_log = self.root / "codesign.log"
        self.passfile = self.root / "pass"
        self.passfile.write_text(PASSWORD + "\n", encoding="utf-8")
        self.keychain = self.root / "dummy.keychain-db"
        self.keychain.write_bytes(b"dummy")
        self.security = self.root / "security"
        self.codesign = self.root / "codesign"
        self.xcrun = self.root / "xcrun"
        self.xcrun_log = self.root / "xcrun.log"
        self.security_ok = (
            "#!/bin/bash\n"
            "printf '%s\\n' \"$1\" >> " + repr(str(self.security_log)) + "\n"
            "if [[ \"$1\" == \"show-keychain-info\" ]]; then exit 99; fi\n"
            "secret=$(cat " + repr(str(self.passfile)) + ")\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$arg\" == \"$secret\" ]]; then printf 'password-argv\\n' >> "
            + repr(str(self.security_log)) + "; fi\n"
            "done\n"
            "exit 0\n"
        )
        self.codesign_ok = (
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> " + repr(str(self.codesign_log)) + "\n"
            "exit 0\n"
        )
        self.success_tools()

    def env(self, **extra):
        env = os.environ.copy()
        env.update(
            C11_ARTIFACT=str(self.artifact),
            C11_BUILD_ROOT=str(self.root / "builds"),
            C11_SECURITY=str(self.security),
            C11_CODESIGN=str(self.codesign),
            C11_KEYCHAIN=str(self.keychain),
            C11_KEYCHAIN_PASS_FILE=str(self.passfile),
            C11_XCRUN=str(self.xcrun),
            C11_STAPLE_SLEEP="0",
        )
        env.update(extra)
        return env

    def run_release(self, args, env=None):
        return subprocess.run(
            [str(RELEASE), *args],
            env=env or self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def pristine(self, name, bundle_id, extra=None):
        app = (self.root / "builds" / "c11-b" / "derived-release"
               / "Build" / "Products" / "Release" / name)
        write_app(app, bundle_id, extra)
        return app

    def test_help_does_not_build(self):
        proc = self.run_release(["--help"])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("--build", proc.stdout)
        self.assertNotIn(PASSWORD, proc.stdout + proc.stderr)
        self.assertFalse(self.security_log.exists())

    def test_no_args_does_not_build(self):
        proc = self.run_release([])
        self.assertEqual(proc.returncode, 2)
        self.assertFalse(self.artifact.exists())

    def test_build_refuses_the_retired_bundle_before_unlock(self):
        self.pristine("c11.app", LEGACY_BUNDLE)
        builder = self.root / "atlas-build"
        builder.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        builder.chmod(0o755)
        proc = self.run_release(
            ["--build"],
            env=self.env(C11_ATLAS_BUILD=str(builder), C11_SIGN_DRY="0"),
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to sign bundle id %s" % LEGACY_BUNDLE, proc.stderr)
        self.assertFalse(self.security_log.exists())
        self.assertFalse(self.codesign_log.exists())
        self.assertFalse(self.artifact.exists())
        self.assertNotIn(PASSWORD, proc.stdout + proc.stderr)

    def test_build_picks_c11_app_when_the_retired_app_is_beside_it(self):
        old = self.pristine("c11h.app", LEGACY_BUNDLE, {"C11Fixture": "from-c11h"})  # c11-2.0:keep
        self.pristine("c11.app", BUNDLE, {"C11Fixture": "from-c11", "C11Commit": HEAD})
        builder = self.root / "atlas-build"
        log = self.root / "builder.log"
        builder.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" > " + repr(str(log)) + "\nexit 0\n",
            encoding="utf-8",
        )
        builder.chmod(0o755)
        proc = self.run_release(
            ["--build"],
            env=self.env(C11_ATLAS_BUILD=str(builder), C11_SIGN_DRY="1"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        command = log.read_text(encoding="utf-8")
        self.assertIn("--tag c11-b --mode release --clean --wmo --universal", command)
        self.assertNotIn("c11-rel", command)
        self.assertFalse(self.security_log.exists())
        self.assertNotIn(PASSWORD, proc.stdout + proc.stderr)
        with zipfile.ZipFile(self.artifact) as archive:
            plist_name = next(name for name in archive.namelist() if name.endswith("c11.app/Contents/Info.plist"))
            info = plistlib.loads(archive.read(plist_name))
        self.assertEqual(info["CFBundleIdentifier"], BUNDLE)
        self.assertEqual(info["C11Fixture"], "from-c11")
        left = plistlib.loads((old / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(left["CFBundleIdentifier"], LEGACY_BUNDLE)
        self.assertEqual(left["C11Fixture"], "from-c11h")  # c11-2.0:keep

    def fake_atlas(self):
        builder = self.root / "atlas-build"
        builder.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        builder.chmod(0o755)
        return builder

    def test_build_refuses_a_product_from_another_commit_before_unlock(self):
        for stamp in ("0000000aa", None):
            with self.subTest(stamp=stamp):
                extra = {"C11Commit": stamp} if stamp else None
                app = self.pristine("c11.app", BUNDLE, extra)
                try:
                    proc = self.run_release(
                        ["--build"],
                        env=self.env(C11_ATLAS_BUILD=str(self.fake_atlas()), C11_SIGN_DRY="0"),
                    )
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertIn("HEAD is " + HEAD, proc.stderr)
                    self.assertFalse(self.security_log.exists())
                    self.assertFalse(self.codesign_log.exists())
                    self.assertFalse(self.artifact.exists())
                finally:
                    shutil.rmtree(app)
                    for leftover in (self.security_log, self.codesign_log, self.artifact):
                        if leftover.exists():
                            leftover.unlink()

    def test_identity_record_names_the_build_and_the_zip(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE, {"C11Commit": "abc123def", "CFBundleVersion": "77"})
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        record = Path(str(self.artifact) + ".identity.txt").read_text(encoding="utf-8")
        rows = dict(line.split("=", 1) for line in record.splitlines())
        self.assertEqual(rows["bundle_id"], BUNDLE)
        self.assertEqual(rows["commit"], "abc123def")
        self.assertEqual(rows["build"], "77")
        self.assertEqual(rows["c11_version"], "1")
        self.assertEqual(rows["release"], "c11 1 (build 77)")
        self.assertEqual(rows["zip_sha256"], hashlib.sha256(self.artifact.read_bytes()).hexdigest())
        self.assertNotIn("notary_id", rows)
        sha = Path(str(self.artifact) + ".sha256").read_text(encoding="utf-8")
        self.assertEqual(sha, "%s  c11-macos.zip\n" % rows["zip_sha256"])
        check = subprocess.run(["shasum", "-a", "256", "-c", self.artifact.name + ".sha256"],
                               cwd=self.artifact.parent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_identity_names_the_build_by_its_c11_version_line(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE, {"CFBundleShortVersionString": "1.7.6", "CFBundleVersion": "145.4",
                                "C11Version": "1.7.6-h4"})
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = dict(line.split("=", 1) for line in
                    Path(str(self.artifact) + ".identity.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(rows["release"], "c11 1.7.6-h4 (build 145.4)")
        self.assertEqual(rows["c11_version"], "1.7.6-h4")
        self.assertEqual(rows["version"], "1.7.6")
        # An unexpanded setting is not a version: the plain version stands in.
        unexpanded = self.root / "unexpanded" / "c11.app"
        write_app(unexpanded, BUNDLE, {"CFBundleShortVersionString": "1.7.6", "CFBundleVersion": "145",
                                       "C11Version": "$(MARKETING_VERSION)-h4"})
        proc = self.run_release(["--sign-app", str(unexpanded)], env=self.env(C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = dict(line.split("=", 1) for line in
                    Path(str(self.artifact) + ".identity.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(rows["release"], "c11 1.7.6 (build 145)")

    def test_identity_failure_publishes_no_zip(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE, {"C11Commit": "abc123def"})
        # A directory where the record's temp file goes makes the write fail.
        Path(str(self.artifact) + ".identity.txt.incoming").mkdir(parents=True)
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("identity.txt", proc.stderr)
        self.assertNotIn("artifact ", proc.stdout)
        self.assertFalse(self.artifact.exists())

    def test_sign_app_refuses_an_app_carrying_the_builders_home(self):
        home = self.root / "builder-home"
        home.mkdir()
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        exe = app / "Contents" / "MacOS" / "c11"
        clean = exe.read_bytes()
        exe.write_bytes(clean + (str(home) + "/derived/checkouts/libwebp/enc.c\x00").encode())
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1", HOME=str(home)))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("carries the builder's home path", proc.stderr)
        self.assertIn("Contents/MacOS/c11: 1 strings with %s/" % home, proc.stderr)
        self.assertNotIn("sign-dry", proc.stdout)
        self.assertFalse(self.artifact.exists())

        exe.write_bytes(clean)
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1", HOME=str(home)))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("sign-dry", proc.stdout)

    def test_sign_app_refuses_staging_and_signs_a_c11_app_dry(self):
        staging = self.root / "staging.app"
        write_app(staging, BUNDLE, {"LSEnvironment": {"C11_SOCKET_PATH": "/tmp/c11.sock"}})
        proc = self.run_release(["--sign-app", str(staging)], env=self.env(C11_SIGN_DRY="1"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("LSEnvironment", proc.stderr)
        self.assertFalse(self.artifact.exists())

        app = self.root / "C11h.app"
        write_app(app, BUNDLE)
        proc = self.run_release(["--sign-app", str(app)], env=self.env(C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("sign-dry", proc.stdout)
        self.assertIn(str(self.artifact), proc.stdout)
        self.assertFalse(self.security_log.exists())
        source = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(source["SUFeedURL"], "https://example.invalid/appcast.xml")
        with zipfile.ZipFile(self.artifact) as archive:
            names = archive.namelist()
            plist_name = next(name for name in names if name.endswith("c11.app/Contents/Info.plist"))
            script_name = next(name for name in names if name.endswith("c11-install.sh"))
            info = plistlib.loads(archive.read(plist_name))
            script = archive.read(script_name)
            guide = archive.read(next(name for name in names if name.endswith("c11/README.md")))
        self.assertEqual(info["CFBundleIdentifier"], BUNDLE)
        # C11H-130: the friend's install guide is in the zip, byte for byte.
        self.assertEqual(guide, (ROOT / "docs" / "c11-friend-install.md").read_bytes())
        # c11 2.0 keeps updating: c11's feed and the pinned release key, not the build's.
        self.assertEqual(info["SUFeedURL"], "https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml")
        self.assertEqual(info["SUPublicEDKey"], "naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk=")
        self.assertIn(b"com.stage11.c11", script)
        mode = self.artifact.stat().st_mode
        self.assertTrue(mode & stat.S_IRUSR)

    def test_a_guide_with_placeholders_ships_with_a_warning(self):
        # C11H-130: a zip cut before Atin fills the guide's open decisions says so.
        app = self.root / "C11h.app"
        write_app(app, BUNDLE)
        for text, warned in (("# Guide\n> **PLACEHOLDER (Atin):** x\n", True), ("# Guide\nAll set.\n", False)):
            guide = self.root / "guide.md"
            guide.write_text(text, encoding="utf-8")
            proc = self.run_release(["--sign-app", str(app)],
                                    env=self.env(C11_SIGN_DRY="1", C11_FRIEND_GUIDE=str(guide)))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual("PLACEHOLDER blocks" in proc.stderr, warned)
            with zipfile.ZipFile(self.artifact) as archive:
                readme = next(name for name in archive.namelist() if name.endswith("c11/README.md"))
                self.assertEqual(archive.read(readme), text.encode("utf-8"))

    def test_the_bundled_core_is_signed_alone_and_its_signed_hash_sealed_before_the_app(self):
        """C11H-66: --deep gives the helper the app's entitlements; it is signed
        again alone (hardened, no entitlements), its new hash goes into
        hc-pin.json, and the app is signed last without --deep."""
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        helpers = app / "Contents" / "Helpers"
        helpers.mkdir()
        (helpers / "herdr-core").write_bytes(b"\xcf\xfa\xed\xfe core")
        (helpers / "herdr-core").chmod(0o755)
        resources = app / "Contents" / "Resources"
        resources.mkdir()
        (resources / "hc-pin.json").write_text(
            '{"version":"0.1.16","protocolGeneration":1,"sourceSHA256":"%s","executableSHA256":"%s"}'
            % ("5" * 64, "0" * 64), encoding="utf-8")
        self._tool(self.codesign,
                   "#!/bin/bash\n"
                   "printf '%s\\n' \"$*\" >> " + repr(str(self.codesign_log)) + "\n"
                   "for last; do :; done\n"
                   "case \"$1 $last\" in --force*/herdr-core) printf 'SIG' >> \"$last\" ;; esac\n"
                   "exit 0\n")
        proc = self.run_release(["--sign-app", str(app)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = self.codesign_log.read_text(encoding="utf-8").splitlines()
        deep = next(i for i, c in enumerate(calls) if "--deep" in c and "--verify" not in c)
        helper = next(i for i, c in enumerate(calls) if c.endswith("/Contents/Helpers/herdr-core"))
        verify = next(i for i, c in enumerate(calls) if c.startswith("--verify"))
        last_app = max(i for i, c in enumerate(calls) if c.endswith("c11.app") and not c.startswith("--verify"))
        self.assertLess(deep, helper)
        self.assertLess(helper, last_app)
        self.assertLess(last_app, verify)
        self.assertNotIn("--entitlements", calls[helper])
        self.assertIn("--options runtime", calls[helper])
        self.assertNotIn("--deep", calls[last_app])
        with zipfile.ZipFile(self.artifact) as archive:
            names = archive.namelist()
            core = archive.read(next(n for n in names if n.endswith("Contents/Helpers/herdr-core")))
            record = json.loads(archive.read(next(n for n in names if n.endswith("Contents/Resources/hc-pin.json"))))
        self.assertTrue(core.endswith(b"SIG"))
        self.assertEqual(record["executableSHA256"], hashlib.sha256(core).hexdigest())
        self.assertEqual(record["sourceSHA256"], "5" * 64)

    def success_tools(self):
        self._tool(self.security, self.security_ok)
        self._tool(self.codesign, self.codesign_ok)
        self.fake_xcrun()

    def fake_xcrun(self, notary_status="Accepted", staple_rc=0, validate_rc=0):
        # Records every call; submits nothing. "staple" leaves a marker inside
        # the app so a test can see whether the zip carries the stapled app.
        self._tool(
            self.xcrun,
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> " + repr(str(self.xcrun_log)) + "\n"
            "secret=$(cat " + repr(str(self.passfile)) + ")\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$arg\" == \"$secret\" ]]; then printf 'password-argv\\n' >> "
            + repr(str(self.xcrun_log)) + "; fi\n"
            "done\n"
            "case \"$1 $2\" in\n"
            "  'notarytool submit')\n"
            "    [[ -s \"$3\" ]] || exit 64\n"
            "    printf '{\"id\":\"fake-sub-1\",\"status\":\"%s\"}\\n' " + repr(notary_status) + "\n"
            "    [[ " + repr(notary_status) + " == Accepted ]] && exit 0 || exit 69 ;;\n"
            "  'notarytool log') printf '{\"issues\":[]}\\n' > \"${@: -1}\"; exit 0 ;;\n"
            "  'stapler staple')\n"
            "    [[ " + str(staple_rc) + " -eq 0 ]] || exit " + str(staple_rc) + "\n"
            "    printf ticket > \"$3/Contents/fake-staple-ticket\"; exit 0 ;;\n"
            "  'stapler validate')\n"
            "    [[ " + str(validate_rc) + " -eq 0 ]] || exit " + str(validate_rc) + "\n"
            "    [[ -f \"$3/Contents/fake-staple-ticket\" ]] && exit 0 || exit 65 ;;\n"
            "esac\n"
            "exit 70\n",
        )

    def xcrun_calls(self):
        if not self.xcrun_log.exists():
            return []
        return self.xcrun_log.read_text(encoding="utf-8").splitlines()

    def notarize_env(self, **extra):
        return self.env(C11_NOTARIZE_GO="1", **extra)

    def _tool(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def failing_security(self, command):
        self._tool(
            self.security,
            "#!/bin/bash\n"
            "printf '%s\\n' \"$1\" >> " + repr(str(self.security_log)) + "\n"
            "if [[ \"$1\" == \"show-keychain-info\" ]]; then exit 99; fi\n"
            "secret=$(cat " + repr(str(self.passfile)) + ")\n"
            "for arg in \"$@\"; do\n"
            "  if [[ \"$arg\" == \"$secret\" ]]; then printf 'password-argv\\n' >> "
            + repr(str(self.security_log)) + "; fi\n"
            "done\n"
            "if [[ \"$1\" == " + repr(command) + " ]]; then printf '%s\\n' \"$secret\" >&2; exit 73; fi\n"
            "exit 0\n",
        )

    def failing_codesign(self, first_arg):
        self._tool(
            self.codesign,
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> " + repr(str(self.codesign_log)) + "\n"
            "secret=$(cat " + repr(str(self.passfile)) + ")\n"
            "if [[ \"$1\" == " + repr(first_arg) + " ]]; then printf '%s\\n' \"$secret\" >&2; exit 73; fi\n"
            "exit 0\n",
        )

    def assert_failed_release(self, proc):
        combined = proc.stdout + proc.stderr
        self.assertNotEqual(proc.returncode, 0, combined)
        self.assertNotIn("artifact ", proc.stdout)
        self.assertFalse(self.artifact.exists())
        self.assertNotIn(PASSWORD, combined)
        self.assertIn("<redacted>", proc.stderr)
        commands = self.security_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("lock-keychain", commands)

    def test_fake_security_never_prints_the_password_or_inspects_the_keychain(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        proc = self.run_release(["--sign-app", str(app)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        combined = proc.stdout + proc.stderr
        self.assertNotIn(PASSWORD, combined)
        self.assertNotIn("show-keychain-info", self.security_log.read_text(encoding="utf-8"))
        commands = self.security_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("unlock-keychain", commands)
        self.assertIn("set-key-partition-list", commands)
        self.assertIn("lock-keychain", commands)
        self.assertIn("password-argv", commands)
        self.assertEqual(commands[-1], "lock-keychain")
        self.assertTrue(self.artifact.exists())
        signed = self.codesign_log.read_text(encoding="utf-8")
        self.assertIn("--verify", signed)
        self.assertIn("--deep", signed)
        self.assertIn("--timestamp", signed)
        self.assertIn("runtime", signed)

    def test_signing_tool_failures_publish_nothing_and_relock(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        cases = (
            ("unlock-keychain", None),
            ("set-key-partition-list", None),
            (None, "--force"),
            (None, "--verify"),
        )
        for security_fail, codesign_fail in cases:
            with self.subTest(security=security_fail, codesign=codesign_fail):
                self.security_log.unlink(missing_ok=True)
                self.codesign_log.unlink(missing_ok=True)
                if self.artifact.exists():
                    self.artifact.unlink()
                self.success_tools()
                if security_fail:
                    self.failing_security(security_fail)
                if codesign_fail:
                    self.failing_codesign(codesign_fail)
                proc = self.run_release(["--sign-app", str(app)])
                self.assert_failed_release(proc)
                self.assertIn("c11-release: command failed:", proc.stderr)

    def test_failed_relock_after_a_successful_sign_publishes_nothing(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.failing_security("lock-keychain")
        proc = self.run_release(["--sign-app", str(app)])
        self.assert_failed_release(proc)
        self.assertIn("c11-release: could not lock the release keychain", proc.stderr)
        self.assertNotIn("c11-release: command failed:", proc.stderr)

    def test_failed_sign_and_failed_relock_report_both(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.failing_security("lock-keychain")
        self.failing_codesign("--force")
        proc = self.run_release(["--sign-app", str(app)])
        self.assert_failed_release(proc)
        self.assertIn("c11-release: command failed: codesign", proc.stderr)
        self.assertIn("c11-release: could not lock the release keychain", proc.stderr)

    def test_archive_failure_removes_a_partial_zip(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        fake = self.root / "ditto"
        self._tool(
            fake,
            "#!/bin/bash\n"
            "if [[ \"$1\" == \"-c\" ]]; then\n"
            "  dest=\"${@: -1}\"\n"
            "  parent=$(dirname \"$dest\")\n"
            "  mkdir -p \"$parent\"\n"
            "  printf partial > \"$dest\"\n"
            "  exit 73\n"
            "fi\n"
            "exec /usr/bin/ditto \"$@\"\n",
        )
        env = self.env(C11_SIGN_DRY="1")
        env["PATH"] = str(self.root) + os.pathsep + env["PATH"]
        proc = self.run_release(["--sign-app", str(app)], env=env)
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("could not write", proc.stderr)
        self.assertNotIn("artifact ", proc.stdout)
        self.assertFalse(self.artifact.exists())

    def test_c11_keychain_switch_stops_until_configured(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        proc = self.run_release(
            ["--sign-app", str(app)],
            env=self.env(C11_RELEASE_KEYCHAIN="c11"),
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not configured", proc.stderr)
        self.assertFalse(self.security_log.exists())

    def test_notarize_without_go_does_not_submit(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        proc = self.run_release(
            ["--sign-app", str(app), "--notarize"],
            env=self.env(C11_SIGN_DRY="1"),
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Orchestrator", proc.stderr)
        self.assertNotIn("notarytool", proc.stdout + proc.stderr)

    def test_notarize_without_go_stops_before_build_and_unlock(self):
        self.pristine("c11.app", BUNDLE, {"C11Commit": HEAD})
        log = self.root / "builder.log"
        builder = self.root / "atlas-build"
        self._tool(builder, "#!/bin/sh\nprintf built > " + repr(str(log)) + "\nexit 0\n")
        proc = self.run_release(["--build", "--notarize"], env=self.env(C11_ATLAS_BUILD=str(builder)))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("C11_NOTARIZE_GO=1", proc.stderr)
        self.assertFalse(log.exists())
        self.assertFalse(self.security_log.exists())
        self.assertFalse(self.codesign_log.exists())
        self.assertEqual(self.xcrun_calls(), [])
        self.assertFalse(self.artifact.exists())

    def test_notarize_staples_the_app_before_the_zip_and_records_the_ticket(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE, {"C11Commit": "abc123def"})
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        combined = proc.stdout + proc.stderr
        self.assertNotIn(PASSWORD, combined)
        self.assertIn("notarization fake-sub-1: Accepted", proc.stdout)
        calls = self.xcrun_calls()
        self.assertNotIn("password-argv", calls)
        self.assertEqual([c.split()[:2] for c in calls],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])
        submit = calls[0].split()
        self.assertEqual(submit[submit.index("--keychain-profile") + 1], "acetate-notary")
        self.assertEqual(submit[submit.index("--keychain") + 1], str(self.keychain))
        self.assertIn("--wait", submit)
        # The keychain was unlocked for signing and again for the submission,
        # and is locked at the end.
        sec = self.security_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(sec.count("unlock-keychain"), 2)
        self.assertEqual(sec.count("lock-keychain"), 2)
        self.assertEqual(sec[-1], "lock-keychain")
        with zipfile.ZipFile(self.artifact) as archive:
            names = archive.namelist()
        self.assertIn("c11/c11.app/Contents/fake-staple-ticket", names)
        rows = dict(line.split("=", 1) for line in
                    Path(str(self.artifact) + ".identity.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(rows["notary_id"], "fake-sub-1")
        self.assertEqual(rows["notary_status"], "Accepted")
        self.assertEqual(rows["stapled"], "yes")
        self.assertEqual(rows["zip_sha256"], hashlib.sha256(self.artifact.read_bytes()).hexdigest())
        self.assertFalse(Path(str(self.artifact) + ".notary-log.json").exists())

    def test_dry_notarize_submits_nothing_and_writes_a_plain_identity(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        proc = self.run_release(["--sign-app", str(app), "--notarize"],
                                env=self.notarize_env(C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("notarize-dry", proc.stdout)
        self.assertEqual(self.xcrun_calls(), [])
        self.assertFalse(self.security_log.exists())
        record = Path(str(self.artifact) + ".identity.txt").read_text(encoding="utf-8")
        self.assertNotIn("notary_", record)

    def test_profile_override_reaches_notarytool(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        proc = self.run_release(["--sign-app", str(app), "--notarize"],
                                env=self.notarize_env(C11_NOTARY_PROFILE="other-profile"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        submit = self.xcrun_calls()[0].split()
        self.assertEqual(submit[submit.index("--keychain-profile") + 1], "other-profile")

    def test_rejected_notarization_keeps_the_log_publishes_nothing_and_relocks(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.fake_xcrun(notary_status="Invalid")
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("notarization failed: Invalid", proc.stderr)
        self.assertNotIn(PASSWORD, proc.stdout + proc.stderr)
        self.assertNotIn("artifact ", proc.stdout)
        self.assertFalse(self.artifact.exists())
        self.assertFalse(Path(str(self.artifact) + ".identity.txt").exists())
        self.assertFalse(Path(str(self.artifact) + ".sha256").exists())
        self.assertTrue(Path(str(self.artifact) + ".notary-log.json").exists())
        calls = [c.split()[:2] for c in self.xcrun_calls()]
        self.assertEqual(calls, [["notarytool", "submit"], ["notarytool", "log"]])
        self.assertEqual(self.security_log.read_text(encoding="utf-8").splitlines()[-1], "lock-keychain")

    def test_staple_failure_publishes_nothing(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.fake_xcrun(staple_rc=68)
        proc = self.run_release(["--sign-app", str(app), "--notarize"],
                                env=self.notarize_env(C11_STAPLE_TRIES="2"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("stapler staple failed after 2 attempts", proc.stderr)
        self.assertFalse(self.artifact.exists())
        self.assertEqual([c.split()[:2] for c in self.xcrun_calls()],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "staple"]])

    def assert_nothing_published(self):
        for suffix in ("", ".identity.txt", ".sha256"):
            self.assertFalse(Path(str(self.artifact) + suffix).exists(), suffix)

    def test_validate_failure_after_a_good_staple_publishes_nothing(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.fake_xcrun(validate_rc=65)
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("stapler validate failed", proc.stderr)
        self.assertNotIn("artifact ", proc.stdout)
        self.assert_nothing_published()
        self.assertEqual([c.split()[:2] for c in self.xcrun_calls()],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])

    def test_failed_relock_after_the_submission_publishes_nothing(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        # The signing relock (first lock) works; the post-submission relock fails.
        self._tool(
            self.security,
            "#!/bin/bash\n"
            "printf '%s\\n' \"$1\" >> " + repr(str(self.security_log)) + "\n"
            "if [[ \"$1\" == lock-keychain ]] && [[ $(grep -c '^lock-keychain$' "
            + repr(str(self.security_log)) + ") -ge 2 ]]; then exit 52; fi\n"
            "exit 0\n",
        )
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("could not lock the release keychain", proc.stderr)
        self.assertNotIn("artifact ", proc.stdout)
        self.assert_nothing_published()
        # Accepted, but never stapled or zipped while the keychain stayed unlocked.
        self.assertEqual([c.split()[:2] for c in self.xcrun_calls()], [["notarytool", "submit"]])
        self.assertEqual(self.security_log.read_text(encoding="utf-8").splitlines().count("lock-keychain"), 2)

    def test_failed_unlock_for_notarization_submits_nothing(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        # The second unlock (for the submission) fails; the first (signing) works.
        self._tool(
            self.security,
            "#!/bin/bash\n"
            "printf '%s\\n' \"$1\" >> " + repr(str(self.security_log)) + "\n"
            "if [[ \"$1\" == unlock-keychain ]] && [[ $(grep -c '^unlock-keychain$' "
            + repr(str(self.security_log)) + ") -ge 2 ]]; then exit 51; fi\n"
            "exit 0\n",
        )
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.xcrun_calls(), [])
        self.assertFalse(self.artifact.exists())
        self.assertEqual(self.security_log.read_text(encoding="utf-8").splitlines()[-1], "lock-keychain")

    def timing_records(self):
        log = self.artifact.parent / "release-timing.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def test_a_notarized_run_records_each_step_in_order(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE, {"C11Commit": "abc123def", "C11Version": "1.8.0-h9"})
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        [record] = self.timing_records()
        self.assertEqual(list(record["steps"]), ["stage", "sign", "notarize", "staple", "zip"])
        self.assertEqual((record["result"], record["exit"], record["failed_step"]), ("ok", 0, None))
        self.assertEqual((record["mode"], record["notarize"]), ("sign-app", True))
        self.assertEqual((record["c11_version"], record["commit"]), ("1.8.0-h9", "abc123def"))
        self.assertGreaterEqual(record["total_s"], sum(record["steps"].values()) - 0.5)
        # Local time with its offset, never a bare UTC stamp.
        self.assertRegex(record["started"], r"[+-]\d\d:\d\d$")
        self.assertIn("timing stage=", proc.stdout)

    def test_a_failed_staple_is_the_failed_step_and_the_exit_status_survives(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        self.fake_xcrun(staple_rc=1)
        proc = self.run_release(["--sign-app", str(app), "--notarize"], env=self.notarize_env())
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(self.artifact.exists())
        [record] = self.timing_records()
        self.assertEqual((record["result"], record["failed_step"]), ("failed", "staple"))
        self.assertEqual(record["exit"], proc.returncode)
        self.assertNotIn("zip", record["steps"])

    def test_a_build_records_the_atlas_compile_time_apart_from_the_slot_wait(self):
        self.pristine("c11.app", BUNDLE, {"C11Commit": HEAD})
        gates = self.root / "builds" / "gates.jsonl"
        started = datetime.datetime.now().astimezone().isoformat()
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], check=True, text=True,
                              stdout=subprocess.PIPE).stdout.strip()
        mine = {"tag": "c11-b", "mode": "release", "head": head, "started": started}
        rows = [dict(mine, build_seconds=212.4, slot_wait_seconds=3.2),
                # Rows land when a build ends: an older build, another commit,
                # a test build and another tag finished after this one.
                dict(mine, started="2026-01-01T00:00:00-08:00", build_seconds=999.0),
                dict(mine, head="0" * 40, build_seconds=7.0),
                dict(mine, mode="test", build_seconds=8.0),
                dict(mine, tag="other", build_seconds=5.0)]
        gates.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        proc = self.run_release(["--build"], env=self.env(C11_ATLAS_BUILD=str(self.fake_atlas()),
                                                         C11_SIGN_DRY="1"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        [record] = self.timing_records()
        self.assertEqual(list(record["steps"])[:3], ["build", "locate", "stage"])
        self.assertEqual((record["atlas_compile_s"], record["atlas_slot_wait_s"]), (212.4, 3.2))

    def test_a_commit_refusal_is_recorded_as_the_locate_step(self):
        self.pristine("c11.app", BUNDLE, {"C11Commit": "0000000aa"})
        proc = self.run_release(["--build"], env=self.env(C11_ATLAS_BUILD=str(self.fake_atlas()),
                                                         C11_SIGN_DRY="1"))
        self.assertNotEqual(proc.returncode, 0)
        [record] = self.timing_records()
        self.assertEqual((record["result"], record["failed_step"]), ("failed", "locate"))

    def test_an_unwritable_timing_log_never_changes_the_release(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        blocker = self.root / "not-a-dir"
        blocker.write_text("", encoding="utf-8")
        proc = self.run_release(["--sign-app", str(app)],
                                env=self.env(C11_SIGN_DRY="1", C11_TIMING_LOG=str(blocker / "log.jsonl")))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(self.artifact.exists())
        self.assertIn("could not write the timing log", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_every_macho_in_resources_bin_is_signed_and_scripts_are_not(self):
        app = self.root / "c11.app"
        write_app(app, BUNDLE)
        bin_dir = app / "Contents" / "Resources" / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "c11").write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 16)
        (bin_dir / "helper").write_bytes(b"\xca\xfe\xba\xbe" + b"\x00" * 16)
        (bin_dir / "c11h").write_text("#!/bin/sh\nexec c11 \"$@\"\n", encoding="utf-8")  # c11-2.0:keep (the hidden alias)
        (bin_dir / "._c11").write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 16)
        proc = self.run_release(["--sign-app", str(app)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        signed = [line.split()[-1] for line in
                  self.codesign_log.read_text(encoding="utf-8").splitlines() if "--force" in line]
        self.assertIn("Contents/Resources/bin/c11", [p for p in signed if p.endswith("bin/c11")][0])
        self.assertTrue(any(p.endswith("Contents/Resources/bin/helper") for p in signed), signed)
        self.assertFalse(any(p.endswith("Contents/Resources/bin/c11h") for p in signed), signed)  # c11-2.0:keep
        self.assertFalse(any(p.endswith("bin/._c11") for p in signed), signed)
        self.assertTrue(signed[-1].endswith("c11.app"), signed)


if __name__ == "__main__":
    unittest.main()
