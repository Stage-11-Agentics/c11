#!/usr/bin/env python3
"""C11H-130: scripts/check-shareable.py fails on a friend-share blocker and passes a clean tree."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Planted private values, built in pieces so this public file holds none of them whole (C11H-284).
BUILDS_DIR = "c11-" + "builds"
BUILD_HOST_LC = "at" + "las"
ENCODED_HOME = "-Users-" + "atin-"
FORGE_HOST = "forgejo." + "stage11.ai"
HOME_USER = "Users/" + "atin"
HOME_USER2 = "Users/" + "atin" + "woodard"
HOME_USER3 = "users/" + "Atin"
LAPTOP = "Hyper" + "ion"
LAPTOP_LC = "hyper" + "ion"
PF_DIR = "c11h-" + "pf"  # c11-2.0:keep (a 1.x folder name the check must catch)
PHONE = "hop" + "lite17"
PRIVATE_HOST = "pi" + "ne." + "stage11.ai"
PROJECTS = "$HOME/Projects/" + "Stage11"
RUN_DIR = "c11h-" + "run"  # c11-2.0:keep (a 1.x folder name the check must catch)
TILDE_USER = "~" + "atin"


ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-shareable.py"


class CheckShareableTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-shareable-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.write("Resources/welcome.md", "Welcome to c11. Visit https://www." + "stage11.ai or hello@" + "stage11.ai.\n")
        self.write("Sources/App.swift", 'let greeting = "hello"\n')
        self.write("CLI/Main.swift", "let x = 1\n")
        self.write("scripts/c11-install.sh", "#!/bin/sh\necho ok\n")
        self.write("skills/MANIFEST.json", json.dumps({"installable": ["c11"]}))
        self.write("skills/c11/SKILL.md", "Open a terminal with --on <machine>.\n")
        self.write("skills/c11/SKILL.md", "c11 differs from c11.\n")
        self.write("docs/c11-friend-install.md", "# Installing c11 on your Mac\n")
        self.write("scripts/shareable-allowlist.txt", "# none\n")

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self, root=None):
        args = [sys.executable, str(CHECK)]
        if root is not False:
            args += ["--root", str(root or self.root)]
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def assert_clean(self):
        proc = self.run_check()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def assert_flags(self, rel, text, needle, line=2):
        self.write(rel, "fine\n" + text + "\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("%s:%d:" % (rel, line), proc.stdout)
        self.assertIn(needle, proc.stdout)

    def test_clean_tree_passes_public_brand(self):
        self.assert_clean()

    def test_each_known_blocker_fails(self):
        cases = [
            ("Resources/bin/claude", "# cache in /" + HOME_USER2 + "/.cache", "home path"),
            ("Resources/bin/claude", "cd " + TILDE_USER + "/src", "home path"),
            ("Resources/bin/claude", "see /" + HOME_USER3 + "/notes", "home path"),
            ("skills/c11/SKILL.md", "cd " + PROJECTS + "/code", "home path"),
            ("skills/c11/SKILL.md", "slug " + ENCODED_HOME + "Projects-x", "home path"),
            ("Resources/welcome.md", "Your terminals live on " + LAPTOP + ".", "Atin's machines"),
            ("Resources/welcome.md", "pair with " + PHONE, "Atin's machines"),
            ("skills/c11/SKILL.md", "c11 new-panel --on " + BUILD_HOST_LC, "a private machine used as a host"),
            ("skills/c11/SKILL.md", "ssh " + BUILD_HOST_LC + " 'ls'", "a private machine used as a host"),
            ("skills/c11/SKILL.md", "ssh -o BatchMode=yes me@" + BUILD_HOST_LC + " true", "a private machine used as a host"),
            ("skills/c11/SKILL.md", "c11 new-area --on=" + BUILD_HOST_LC, "a private machine used as a host"),
            ("Resources/bin/claude", 'root="' + HOME_USER + '/src"', "home path"),
            ("skills/c11/SKILL.md", "ssh box.tail1234.ts.net", "tailnet"),
            ("skills/c11/SKILL.md", "reach 100.101.2.3 first", "tailnet"),
            ("Resources/Blueprints/x.json", '"url": "https://' + FORGE_HOST + '/x"', "isn't public"),
            ("Resources/Blueprints/x.json", '"url": "https://' + PRIVATE_HOST + '/x"', "isn't public"),
            ("scripts/c11-install.sh", "unzip ~/" + RUN_DIR + "/artifacts/c11.zip", "build or artifact folder"),
            ("scripts/c11-install.sh", "ls ~/" + BUILDS_DIR, "build or artifact folder"),
            ("docs/c11-friend-install.md", "copy it from ~/" + PF_DIR, "build or artifact folder"),
            ("Sources/App.swift", 'let host = "' + LAPTOP + '"', "Atin's machines"),
        ]
        for rel, text, needle in cases:
            with self.subTest(text=text):
                self.setUp()
                self.assert_flags(rel, text, needle)

    def test_swift_comments_are_skipped_but_string_contents_are_not(self):
        self.write("Sources/App.swift",
                   "/// e.g. /" + HOME_USER + "/Projects/c11 -> -Users-" + "atin\n"
                   "let x = 1 // measured on " + LAPTOP + "\n"
                   'let url = "https://example.com" // fine\n')
        self.assert_clean()
        self.assert_flags("Sources/App.swift", 'let s = "see //' + LAPTOP + '" ', "Atin's machines")

    def test_swift_multiline_string_lines_are_scanned_even_when_they_start_with_slashes(self):
        self.write("Sources/App.swift",
                   'let js = """\n'
                   "// open /" + HOME_USER + "/Projects/x\n"
                   '"""\n'
                   "// after the literal: /" + HOME_USER + " is a comment again\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Sources/App.swift:2:", proc.stdout)
        self.assertNotIn("Sources/App.swift:4:", proc.stdout)

    def test_a_stray_triple_quote_in_a_comment_does_not_flip_string_tracking(self):
        self.write("Sources/App.swift",
                   '/// docs with """ in them\n'
                   'let f = """\n'
                   "// /" + HOME_USER + "/inside-the-string\n"
                   '"""\n'
                   "/* a block about " + LAPTOP + " */ // and a comment\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Sources/App.swift:3:", proc.stdout)

    def test_atlas_as_a_swift_case_or_label_is_fine(self):
        self.write("Sources/App.swift", "case " + BUILD_HOST_LC + ":\nlet x = Browser(" + BUILD_HOST_LC + ": true)\n")
        self.assert_clean()

    def test_a_new_skill_is_scanned_without_being_listed(self):
        self.assert_flags("skills/brand-new/SKILL.md", "ssh " + BUILD_HOST_LC + " make", "a private machine used as a host")

    def test_a_manifest_without_installable_skills_fails(self):
        self.write("skills/MANIFEST.json", "{}")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("no installable list", proc.stderr)

    def test_vendored_files_and_maintainer_skills_are_not_scanned(self):
        self.write("Resources/markdown-viewer/vendor/lib.js", "// built on " + LAPTOP_LC + "\n")
        self.write("Resources/ghostty/themes/Night", "# by atin" + "@example\n")
        self.write("skills/c11-hotload/SKILL.md", "ssh " + BUILD_HOST_LC + " 'make'\n")
        self.assert_clean()

    def test_shipped_ghostty_config_and_shell_comments_are_scanned(self):
        self.assert_flags("Resources/ghostty/c11-default.conf", "# tuned on " + LAPTOP, "Atin's machines")
        self.setUp()
        self.assert_flags("Resources/bin/codex", "# verified on " + LAPTOP, "Atin's machines")

    def test_a_missing_scope_path_fails(self):
        (self.root / "scripts" / "c11-install.sh").unlink()
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("scripts/c11-install.sh: scope path missing", proc.stdout)

    def test_allowlist_admits_exactly_one_whole_line_and_only_its_own_text(self):
        line = 'static let hostSample = "' + LAPTOP + '"'
        self.write("Sources/App.swift", "    " + line + "\n")
        self.write("scripts/shareable-allowlist.txt", "Sources/App.swift\t%s\tsizes the chip\n" % line)
        self.assert_clean()

        # A second blocker on the admitted line is still reported.
        self.write("Sources/App.swift", line + "  // \n" + 'let p = "/' + HOME_USER + '"\n')
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Sources/App.swift:2:", proc.stdout)

        # The same line twice: an entry admits one line only.
        self.write("Sources/App.swift", line + "\n" + line + "\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("matched 2", proc.stdout)

        # Gone: the entry is stale.
        self.write("Sources/App.swift", "let x = 1\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("matched 0", proc.stdout)

    def test_allowlist_rejects_short_or_partial_entries(self):
        self.write("Sources/App.swift", 'let a = "' + LAPTOP + '"; let b = 2\n')
        self.write("scripts/shareable-allowlist.txt", "Sources/App.swift\t" + LAPTOP + "\tr\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("at least", proc.stderr)
        self.write("scripts/shareable-allowlist.txt", 'Sources/App.swift\tlet a = "' + LAPTOP + '";\tpart of the line\n')
        proc = self.run_check()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Sources/App.swift:1:", proc.stdout)

    def test_malformed_allowlist_line_fails(self):
        self.write("scripts/shareable-allowlist.txt", "Sources/App.swift only-two-fields\n")
        proc = self.run_check()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("path<TAB>the whole line", proc.stderr)

    def test_this_repo_is_shareable(self):
        # The guard blocks (Atin, 2026-11-03), so main itself must pass.
        proc = self.run_check(root=False)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    # The gate (scripts/shareable-gate.sh) through both wrappers: blocking by default, an
    # explicit override that is printed and logged, and a tool failure never read as clean.
    def wrapper_tree(self):
        (self.root / "scripts").mkdir(exist_ok=True)
        shutil.copy(CHECK, self.root / "scripts" / "check-shareable.py")
        for name in ("remote-build.sh", "shareable-gate.sh", "check-skill-card-size.py", "check-public-tree.py"):
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
            (self.root / "scripts" / name).chmod(0o755)
        self.write("scripts/remote_build.py", "print('stub remote build ran')\n")
        if not (self.root / "skills" / "c11" / "SKILL.md").exists():
            self.write("skills/c11/SKILL.md", "# c11\n")  # pre-push also checks the card's size
        (self.root / ".githooks").mkdir(exist_ok=True)
        shutil.copy(ROOT / ".githooks" / "pre-push", self.root / ".githooks" / "pre-push")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.log = self.root / "override.log"

    def run_wrapper(self, which, override=None, stdin="", terms=None):
        env = dict(os.environ)
        env.pop("C11_SHAREABLE_OVERRIDE", None)
        env.pop("C11_PUBLIC_TREE_TERMS", None)
        if terms is not None:
            env["C11_PUBLIC_TREE_TERMS"] = str(terms)
        env["C11_SHAREABLE_LOG"] = str(self.log)
        if override is not None:
            env["C11_SHAREABLE_OVERRIDE"] = override
        if which == "remote-build":
            argv = ["bash", str(self.root / "scripts" / "remote-build.sh")]
        else:
            argv = ["bash", str(self.root / ".githooks" / "pre-push"), "origin", "git@example:x.git"]
        return subprocess.run(argv, cwd=str(self.root), env=env, input=stdin, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    PUSH = "refs/heads/x %s refs/heads/x %s\n" % ("a" * 40, "0" * 40)

    def test_wrappers_pass_a_clean_tree(self):
        self.wrapper_tree()
        proc = self.run_wrapper("remote-build")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("stub remote build ran", proc.stdout)
        self.assertEqual(self.run_wrapper("pre-push", stdin=self.PUSH).returncode, 0)
        self.assertFalse(self.log.exists())

    def test_wrappers_block_a_finding(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        for which in ("remote-build", "pre-push"):
            with self.subTest(which=which):
                proc = self.run_wrapper(which, stdin=self.PUSH)
                self.assertEqual(proc.returncode, 1, proc.stderr)
                self.assertIn("Blocked", proc.stderr)
                self.assertNotIn("stub remote build ran", proc.stdout)
                # An empty or blank override is no override.
                self.assertEqual(self.run_wrapper(which, override="  ", stdin=self.PUSH).returncode, 1)
        self.assertFalse(self.log.exists())

    # C11H-337: the gate runs the strict public-tree check too, so a machine name in a file
    # check-shareable doesn't scan, or a private term, blocks before a build or a push.
    def track(self, rel, text):
        self.write(rel, text)
        subprocess.run(["git", "-C", str(self.root), "add", rel], check=True)

    def test_wrappers_block_a_public_tree_finding(self):
        self.wrapper_tree()
        self.track("notes/measure.md", "fine\nRan on " + BUILD_HOST_LC.capitalize() + " overnight.\n")
        self.assertEqual(self.run_check().returncode, 0, "check-shareable alone passes this tree")
        for which in ("remote-build", "pre-push"):
            with self.subTest(which=which):
                proc = self.run_wrapper(which, stdin=self.PUSH)
                self.assertEqual(proc.returncode, 1, proc.stderr)
                self.assertIn("check-public-tree found public-tree blockers. Blocked.", proc.stderr)
                self.assertIn("notes/measure.md:2: operator's machine or place", proc.stderr)
                self.assertNotIn("stub remote build ran", proc.stdout)

    def test_private_terms_block_and_their_absence_is_said(self):
        self.wrapper_tree()
        self.track("c11Tests/GroupTests.swift", 'let name = "Zorblax web"\n')
        terms = self.root.parent / (self.root.name + "-terms.txt")
        terms.write_text("zorblax\n", encoding="utf-8")
        self.addCleanup(terms.unlink)
        proc = self.run_wrapper("remote-build", terms=terms)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("c11Tests/GroupTests.swift:1: private term", proc.stderr)
        self.assertNotIn("were NOT checked", proc.stderr)
        proc = self.run_wrapper("remote-build")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("client and people names were NOT checked", proc.stderr)

    def test_an_override_logs_a_public_tree_finding(self):
        self.wrapper_tree()
        self.track("notes/measure.md", "Ran on " + BUILD_HOST_LC.capitalize() + ".\n")
        proc = self.run_wrapper("remote-build", override="a sample machine word, long enough")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        row = self.log.read_text(encoding="utf-8")
        self.assertIn("check=check-public-tree found public-tree blockers", row)
        self.assertIn("findings=notes/measure.md:1: operator's machine or place", row)

    def test_an_override_proceeds_and_is_logged(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        proc = self.run_wrapper("remote-build", override=LAPTOP + " is a moon in this example")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("stub remote build ran", proc.stdout)
        self.assertIn("OVERRIDDEN: " + LAPTOP + " is a moon in this example", proc.stderr)
        proc = self.run_wrapper("pre-push", override="same false alarm", stdin=self.PUSH)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(rows), 2)
        self.assertIn("context=remote-build", rows[0])
        self.assertIn("reason=" + LAPTOP + " is a moon in this example", rows[0])
        self.assertIn("context=pre-push", rows[1])
        self.assertIn("head=", rows[1])

    def test_the_retired_override_counts_only_when_the_current_one_is_unset(self):
        # C11H-265: the old names are a fallback; a current name that is set, even empty, wins.
        legacy = "C11H_SHAREABLE_"  # c11-2.0:keep
        cases = [
            ("absent", None, 0, "reason=the legacy reason, long enough"),
            ("empty", "", 1, None),
            ("blank", "   ", 1, None),
            ("set", "the current reason, long enough", 0, "reason=the current reason, long enough"),
        ]
        for name, current, code, logged in cases:
            with self.subTest(case=name):
                self.wrapper_tree()
                self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
                if self.log.exists():
                    self.log.unlink()
                env = dict(os.environ)
                for key in ("C11_SHAREABLE_OVERRIDE", "C11_SHAREABLE_LOG"):
                    env.pop(key, None)
                env[legacy + "OVERRIDE"] = "the legacy reason, long enough"
                env[legacy + "LOG"] = str(self.log)
                if current is not None:
                    env["C11_SHAREABLE_OVERRIDE"] = current
                proc = subprocess.run(["bash", str(self.root / "scripts" / "remote-build.sh")], cwd=str(self.root),
                                      env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                self.assertEqual(proc.returncode, code, proc.stderr)
                if logged:
                    text = self.log.read_text(encoding="utf-8")
                    self.assertIn(logged, text)
                    self.assertEqual(text.count("reason="), 1)
                else:
                    self.assertNotIn("stub remote build ran", proc.stdout)

    def test_an_override_records_what_it_let_through(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        self.run_wrapper("remote-build", override=LAPTOP + " is a moon in this example")
        row = self.log.read_text(encoding="utf-8")
        self.assertIn("findings=skills/c11/SKILL.md:1:", row)
        self.assertEqual(len(row.splitlines()), 1)

    def test_a_short_override_is_no_override(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        proc = self.run_wrapper("remote-build", override="1")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("at least 12 characters", proc.stderr)
        self.assertFalse(self.log.exists())

    def test_an_override_that_cannot_be_logged_does_not_proceed(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        blocker = self.root / "not-a-dir"
        blocker.write_text("x", encoding="utf-8")
        self.log = blocker / "override.log"
        proc = self.run_wrapper("remote-build", override=LAPTOP + " is a moon in this example")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("Override NOT logged", proc.stderr)
        self.assertNotIn("stub remote build ran", proc.stdout)

    def test_a_missing_check_or_gate_blocks(self):
        self.wrapper_tree()
        (self.root / "scripts" / "check-shareable.py").unlink()
        proc = self.run_wrapper("remote-build")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("is missing, so nothing was verified", proc.stderr)
        (self.root / "scripts" / "shareable-gate.sh").unlink()
        for which in ("remote-build", "pre-push"):
            with self.subTest(which=which):
                proc = self.run_wrapper(which, override="a long enough reason", stdin=self.PUSH)
                self.assertNotEqual(proc.returncode, 0, proc.stderr)
                self.assertNotIn("stub remote build ran", proc.stdout)

    def test_pre_push_skips_deletes_and_tags(self):
        self.wrapper_tree()
        self.write("skills/c11/SKILL.md", "on " + LAPTOP + "\n")
        delete = "(delete) %s refs/heads/x %s\n" % ("0" * 40, "a" * 40)
        tag = "refs/tags/v1 %s refs/tags/v1 %s\n" % ("a" * 40, "0" * 40)
        for stdin in (delete, tag):
            proc = self.run_wrapper("pre-push", stdin=stdin)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("check-shareable", proc.stderr)

    def test_a_guard_that_cannot_run_blocks_and_says_so(self):
        self.wrapper_tree()
        self.write("skills/MANIFEST.json", "{}")
        proc = self.run_wrapper("remote-build")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("failed to run (exit 2)", proc.stderr)
        self.assertNotIn("found friend-share blockers", proc.stderr)
        proc = self.run_wrapper("remote-build", override="config change in flight")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("failed to run (exit 2), so nothing was verified", self.log.read_text(encoding="utf-8"))

if __name__ == "__main__":
    unittest.main()
