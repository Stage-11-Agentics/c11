#!/usr/bin/env python3
"""C11H-265: the c11 2.0 rename codemod on a small fixture repository.

Runs scripts/c11-2.0-rename.py against a temporary git checkout: the rename, the
names it must keep (ticket ids, wire and stored names, the hidden alias), a rerun
that changes nothing, and the forwarding shim's variable translation.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "c11-2.0-rename.py"
OLD = "c11" + "h"          # spelled apart so the codemod never rewrites this file's fixtures
OLD_UP = "C11" + "H"


class RenameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-rename-")
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text, mode=0o644):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)

    def run_codemod(self, *extra):
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), *extra],
                              capture_output=True, text=True, timeout=60)

    def test_renames_what_it_should_keeps_what_it_must_and_reruns_as_a_no_op(self):
        self.write("Sources/Thing.swift", "\n".join([
            f'let bundle = "com.stage11.{OLD}"',
            f"struct {OLD_UP}Relay {{}}",
            f'let env = "{OLD_UP}_RELAY_BIN"',
            f'let ticket = "{OLD_UP}-123"',
            f'let label = "{OLD}-relay-2 request"',
            f'let key = ext["{OLD}"]',
            f'let prefix = "{OLD}.show."',
            f'let alias = "Resources/bin/{OLD}"',
            f'let legacy = "{OLD}" // c11-2.0:legacy',
            "",
        ]))
        self.write(f"scripts/{OLD}-install.sh", "#!/bin/sh\necho installer\n", 0o755)
        self.write("notes/history.md", f"{OLD} history\n")
        proc = self.run_codemod()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        text = (self.root / "Sources/Thing.swift").read_text()
        for renamed in ['"com.stage11.c11"', "struct C11Relay", '"C11_RELAY_BIN"']:
            self.assertIn(renamed, text)
        for kept in [f"{OLD_UP}-123", f"{OLD}-relay-2 request", f'ext["{OLD}"]', f'"{OLD}.show."',
                     f"bin/{OLD}\"", f'"{OLD}" // c11-2.0:legacy']:
            self.assertIn(kept, text)
        self.assertEqual((self.root / "notes/history.md").read_text(), f"{OLD} history\n")
        self.assertTrue((self.root / "scripts/c11-install.sh").exists())
        self.assertIn("c11-2.0:shim", (self.root / f"scripts/{OLD}-install.sh").read_text())
        again = self.run_codemod("--check")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("0 files changed", again.stdout)

    def test_migration_gate_strings_keep_their_old_name_by_key(self):
        def entry(key, value):
            return (f'    "{key}": {{\n      "localizations": {{\n        "en": {{\n          "stringUnit": {{\n'
                    f'            "value": "{value}"\n          }}\n        }}\n      }}\n    }}')
        text = ('{\n  "strings": {\n' + entry("migration.gate.waiting", f"{OLD} is still quitting") + ",\n"
                + entry("other.key", f"open {OLD}") + "\n  }\n}\n")
        self.write("Resources/Localizable.xcstrings", text)
        self.assertEqual(self.run_codemod().returncode, 0)
        out = (self.root / "Resources/Localizable.xcstrings").read_text()
        self.assertIn(f"{OLD} is still quitting", out)
        self.assertIn("open c11\"", out)
        self.assertNotIn(f"open {OLD}", out)

    def test_the_shim_translates_old_variables_and_the_current_name_wins(self):
        self.write(f"scripts/{OLD}-install.sh", "#!/bin/sh\necho old\n", 0o755)
        self.assertEqual(self.run_codemod().returncode, 0)
        (self.root / "scripts/c11-install.sh").write_text(
            '#!/bin/sh\nprintf "%s|%s|%s" "$C11_APP_PATH" "$C11_HOME" "$C11_HC_ROOT"\n')
        env = {"PATH": "/usr/bin:/bin", f"{OLD_UP}_APP_PATH": "/x y/c11.app",
               f"{OLD_UP}_HOME": "/h;echo injected", f"{OLD_UP}_HC_ROOT": "old", "C11_HC_ROOT": "new"}
        out = subprocess.run(["sh", str(self.root / f"scripts/{OLD}-install.sh")], env=env,
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(out.stdout, "/x y/c11.app|/h;echo injected|new", out.stderr)


if __name__ == "__main__":
    unittest.main()
