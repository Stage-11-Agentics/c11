#!/usr/bin/env python3
"""Behavioral tests for scripts/c11-bundle-hc.sh (C11H-66). A fake codesign
appends bytes, as a real signature changes the file; nothing is signed."""

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "scripts" / "c11-bundle-hc.sh"
COMMIT = "e07c2a1bedd62cf4787ee026ee23ee79c7d95491"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class BundleHCTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-bundle-hc-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.core = b"stock hc core\n"
        self.source = self.root / "hc-source.json"
        self.source.write_text(json.dumps({"version": "0.1.16", "ref": "v0.1.16", "commit": COMMIT,
                                           "sha256": sha(self.core), "protocolGeneration": 1}), encoding="utf-8")
        self.out = self.root / "hc-out"
        self.out.mkdir()
        self.write_build(self.core)
        self.cache = self.root / "cache"
        self.app = self.root / "c11.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        self.codesign_log = self.root / "codesign.log"
        self.codesign = self.root / "codesign"
        self.codesign.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> " + repr(str(self.codesign_log)) + "\n"
            "for last; do :; done\n"
            "printf 'SIGNED' >> \"$last\"\n", encoding="utf-8")
        self.codesign.chmod(0o755)

    def write_build(self, binary: bytes, **record):
        (self.out / "herdr-core").write_bytes(binary)
        fields = {"ref": "v0.1.16", "commit": COMMIT, "sha256": sha(binary), "signed": False}
        fields.update(record)
        (self.out / "build.json").write_text(json.dumps(fields), encoding="utf-8")

    def run_bundle(self, configuration="Debug"):
        env = os.environ.copy()
        env.update(C11_BUNDLE_APP=str(self.app), C11_HC_SOURCE_JSON=str(self.source), CONFIGURATION=configuration,
                   C11_HC_CACHE_DIR=str(self.cache), C11_HC_BUILD_OUT=str(self.out), C11_CODESIGN=str(self.codesign))
        return subprocess.run([str(BUNDLE)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    @property
    def helper(self):
        return self.app / "Contents" / "Helpers" / "herdr-core"

    @property
    def manifest(self):
        return self.app / "Contents" / "Resources" / "hc-pin.json"

    def test_bundles_the_pinned_build_signs_it_alone_and_records_the_signed_hash(self):
        proc = self.run_bundle("Release")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        signed = self.helper.read_bytes()
        self.assertEqual(signed, self.core + b"SIGNED")
        record = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(record, {"version": "0.1.16", "protocolGeneration": 1,
                                  "sourceSHA256": sha(self.core), "executableSHA256": sha(signed)})
        args = self.codesign_log.read_text(encoding="utf-8")
        self.assertIn("--options runtime", args)
        self.assertIn("--identifier com.stage11.c11.herdr-core", args)
        self.assertNotIn("--entitlements", args)
        self.assertNotIn("--deep", args)
        self.assertEqual((self.cache / sha(self.core) / "herdr-core").read_bytes(), self.core)
        again = self.run_bundle("Release")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.helper.read_bytes(), self.core + b"SIGNED", "a rebuild starts from the pinned bytes again")

    def test_another_build_is_refused(self):
        self.write_build(b"a different build\n")
        release = self.run_bundle("Release")
        self.assertNotEqual(release.returncode, 0)
        self.assertFalse(self.helper.exists())
        debug = self.run_bundle("Debug")
        self.assertEqual(debug.returncode, 0, debug.stderr)
        self.assertIn("uses the external pin", debug.stderr)
        self.assertFalse(self.helper.exists())
        self.assertFalse(self.manifest.exists())

    def test_a_build_record_naming_another_commit_or_a_signed_build_is_refused(self):
        for record in ({"commit": "0" * 40}, {"signed": True}):
            with self.subTest(record=record):
                self.write_build(self.core, **record)
                proc = self.run_bundle("Release")
                self.assertNotEqual(proc.returncode, 0)
                self.assertFalse(self.helper.exists())

    def test_a_poisoned_cache_is_refused_even_in_debug(self):
        cached = self.cache / sha(self.core) / "herdr-core"
        cached.parent.mkdir(parents=True)
        cached.write_bytes(b"not the pinned build\n")
        proc = self.run_bundle("Debug")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing", proc.stderr)
        self.assertFalse(self.helper.exists())

    def test_the_cache_alone_is_enough(self):
        cached = self.cache / sha(self.core) / "herdr-core"
        cached.parent.mkdir(parents=True)
        cached.write_bytes(self.core)
        (self.out / "herdr-core").unlink()
        proc = self.run_bundle("Release")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.helper.read_bytes(), self.core + b"SIGNED")


if __name__ == "__main__":
    unittest.main()
