#!/usr/bin/env python3
"""Behavioral tests of the hc PATH shim; never run a real hc or c11 binary."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


class HCManagedShimTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="c11-shim-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.managed = self.root / "managed"
        self.real = self.root / "real"
        self.managed.mkdir()
        self.real.mkdir()
        source = Path(__file__).resolve().parents[1] / "Resources/bin/hc"
        self.wrapper = self.managed / "hc"
        shutil.copy2(source, self.wrapper)
        self.record = self.root / "record.json"
        for name, target in [("managed", self.managed / "c11"), ("real", self.real / "hc")]:
            target.write_text(
                "#!/usr/bin/python3\nimport json,os,sys\n"
                f"json.dump({{'target': {name!r}, 'args':sys.argv[1:],'env':dict(os.environ)}},open(os.environ['RECORD'],'w'))\n"
            )
            target.chmod(0o755)
        self.env = {
            "PATH": f"{self.managed}:{self.real}:/usr/bin:/bin",
            "HOME": str(self.root), "RECORD": str(self.record),
            "C11_HC_SESSION": "c11-unit", "C11_HC_SOCKET": "/owned-hc.sock",
            "HC_SESSION": "c11-unit", "HC_SOCKET": "/owned-hc.sock",
            "C11_SOCKET_PATH": str(self.root / "app.sock"),
        }

    def call(self, *args, **env):
        return subprocess.run([str(self.wrapper), *args], env={**self.env, **env},
                              text=True, capture_output=True, timeout=3)

    def test_foreign_session_falls_through_with_original_arguments_and_identity(self):
        args = ["update", "a b", "$(must_not_execute)", "--"]
        result = self.call(*args, HC_SESSION="default")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["target"], "real")
        self.assertEqual(record["args"], args)
        self.assertEqual(record["env"]["HC_SESSION"], "default")
        self.assertEqual(record["env"]["HC_SOCKET"], "/owned-hc.sock")

    def test_foreign_socket_falls_through_even_with_owned_session_name(self):
        result = self.call("server", "start", HC_SOCKET="/foreign.sock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["target"], "real")

    def test_owned_tuple_uses_bundle_cli_and_never_real_hc(self):
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(self.env["C11_SOCKET_PATH"])
        result = self.call("run", "--", "sh", "-c", "echo x y")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["target"], "managed")
        self.assertEqual(record["args"], ["hc", "run", "--", "sh", "-c", "echo x y"])

    def test_dead_app_for_owned_tuple_never_falls_through_or_autostarts(self):
        result = self.call("server", "status")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hc_managed_runtime", result.stderr)
        self.assertFalse(self.record.exists())

    def test_no_owned_marker_and_wrapper_alias_both_fall_through_without_recursion(self):
        alias = self.root / "alias"
        alias.mkdir()
        (alias / "hc").symlink_to(self.wrapper)
        result = self.call("--help", C11_HC_SESSION="", PATH=f"{self.managed}:{alias}:{self.real}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["target"], "real")


if __name__ == "__main__":
    unittest.main()
