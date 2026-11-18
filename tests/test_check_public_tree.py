#!/usr/bin/env python3
"""C11H-268, C11H-284: scripts/check-public-tree.py blocks what public c11 must not carry. Strict (the
default) blocks every kind; --inherit passes what public c11 already publishes, measured against a
baseline branch in a fixture repo."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Planted values, built in pieces so this public file holds none of them whole.
BOARD_HOST = "lattice." + "stage11.ai"
BUILD_HOST = "At" + "las"
BUILD_HOST_LC = "at" + "las"
HOME_USER = "Users/" + "atin"
LAPTOP = "Hyper" + "ion"
PROJECTS_TILDE = "~/Projects/" + "Stage11"
RUN_DIR = "c11h-" + "run"  # c11-2.0:keep (a 1.x folder name the check must catch)


ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-public-tree.py"
TOKEN = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
TAILNET_IP = "100.101." + "2.3"
TAILNET_HOST = "box.tail1234." + "ts.net"
PRIVATE_HOST = "pi" + "ne." + "stage11.ai"
NEW_EMAIL = "someone.private" + "@gmail.com"
HELLO = "hello@" + "stage11.ai"

# What public c11's own tree already carries, by kind.
BASELINE = {
    "AGENTS.md": ("Builds run on " + BUILD_HOST + ": ssh " + BUILD_HOST_LC + ", from /" + HOME_USER
                  + "/Projects/Stage11/code/c11.\n"
                  + LAPTOP + " is the laptop. Mail " + HELLO + "; the board is " + BOARD_HOST + ".\n"),
    "Sources/Telemetry.swift": 'let key = "phc_publicProjectKeyThatIsMeantToShip"\n',
    "scripts/fixture.py": 'SAMPLE = "100.100.' + '1.2"  # a test address\n',
}


class CheckPublicTreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-public-tree-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git("init", "-q", "-b", "base")
        for rel, text in BASELINE.items():
            self.write(rel, text)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "base")
        self.git("checkout", "-q", "-b", "head")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root)] + list(args), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def write(self, rel, text, track=True):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if track and (self.root / ".git").exists():
            self.git("add", rel)

    def run_check(self, baseline="base", strict=False, extra=(), gitleaks=False):
        env = dict(os.environ, C11_PUBLIC_TREE_TERMS=os.devnull)
        bar = [] if strict else ["--inherit", "--baseline", baseline]
        proc = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root)] + bar
                              + ([] if gitleaks else ["--no-gitleaks"]) + list(extra), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30)
        return proc.returncode, proc.stdout + proc.stderr

    def make_clean(self):
        """The fixture tree with nothing any bar blocks."""
        self.write("AGENTS.md", "Builds run elsewhere.\n")
        self.write("scripts/fixture.py", "SAMPLE = 1\n")

    def assert_clean(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        return out

    def assert_flags(self, rel, text, needle):
        self.write(rel, "fine\n" + text + "\n")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("%s:2:" % rel, out)
        self.assertIn(needle, out)
        return out

    def test_public_c11_kinds_stay_green(self):
        self.write("docs/new.md", "On " + LAPTOP + ", open " + PROJECTS_TILDE + "/code/c11 and ssh " + BUILD_HOST_LC + ".\n"
                                  "Write to " + HELLO + " or see " + BOARD_HOST + ".\n"
                                  "Mail a@example.com, ssh me@studio.lan, https://key@o1.ingest.sentry.io/1.\n")
        out = self.assert_clean()
        self.assertIn("inherited: operator's home path or contact", out)
        self.assertIn("inherited: operator's machine or place", out)

    def test_a_large_tree_is_scanned_in_parallel_and_misses_nothing(self):
        # C11H-337: past 200 files the scan runs in a process pool; a plant in any file still blocks.
        for i in range(260):
            self.write("Sources/Gen%03d.swift" % i, "let value%d = %d\n" % (i, i))
        self.write("Sources/Gen131.swift", "let host = \"%s\"\n" % TAILNET_HOST)
        self.write("Sources/Gen259.swift", "// built on " + BUILD_HOST + "\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.assertIn("Sources/Gen131.swift:1: tailnet host or address", out)
        self.assertIn("Sources/Gen259.swift:1: operator's machine or place", out)
        self.assertNotIn("Gen130", out)

    def test_planted_tailnet_address_fails(self):
        self.assert_flags("skills/c11/SKILL.md", "reach %s first" % TAILNET_IP, "tailnet host or address")
        self.write("skills/c11/SKILL.md", "ssh %s\n" % TAILNET_HOST)
        code, out = self.run_check()
        self.assertEqual(code, 1, out)

    def test_planted_github_token_fails_without_printing_it(self):
        out = self.assert_flags("scripts/deploy.sh", "export GH_TOKEN=" + TOKEN, "secret")
        self.assertNotIn(TOKEN, out)

    def test_a_non_ascii_letter_before_a_plant_does_not_hide_it(self):
        # U+0130 lowercases to two code points; offsets taken from text.lower() once slid past it.
        for rel, text, kind in [("docs/a.txt", "İstanbul\n%s\n" % TAILNET_IP, "tailnet host or address"),
                                ("docs/b.txt", "İstanbul GH_TOKEN=%s\n" % TOKEN, "secret"),
                                ("docs/c.txt", "İİİİ\nİ then %s\n" % PRIVATE_HOST, "Stage 11 host")]:
            self.write(rel, text)
            code, out = self.run_check()
            self.assertEqual(code, 1, out)
            self.assertIn(rel + ":", out)
            self.assertIn(kind, out)
            self.git("rm", "-q", "--cached", rel)

    def test_a_term_whose_letter_folds_to_ascii_matches_itself_and_its_case_variant(self):
        kelvin = "\u212a"  # KELVIN SIGN, which lowercases to an ASCII k
        terms = self.root.parent / (self.root.name + "-terms-k.txt")
        self.addCleanup(lambda: terms.exists() and terms.unlink())
        for term, content in [(kelvin + "elvin Labs", kelvin + "elvin Labs"),   # the exact term
                              ("Kelvin Labs", kelvin + "ELVIN LABS"),           # its case variant
                              (kelvin + "elvin Labs", "kelvin labs")]:
            terms.write_text(term + "\n", encoding="utf-8")
            self.write("docs/k.txt", "İ first\n" + content + "\n")
            proc = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), "--inherit", "--baseline", "base",
                                   "--no-gitleaks", "--terms", str(terms)], text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=30)
            self.assertEqual(proc.returncode, 1, (term, content, proc.stdout + proc.stderr))
            self.assertIn("docs/k.txt:2: private term", proc.stdout)

    def test_line_numbers_count_newlines_only(self):
        # U+2028 and a form feed are not line breaks to git or gitleaks; the reported line must agree.
        self.write("docs/sep.txt", "a\u2028b\x0cc\n%s\n" % TAILNET_IP)
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("docs/sep.txt:2: tailnet host or address", out)

    def test_a_non_ascii_private_term_is_found_in_any_case(self):
        terms = self.root.parent / (self.root.name + "-terms-u.txt")
        terms.write_text("Zoë Ångström\n", encoding="utf-8")
        self.addCleanup(terms.unlink)
        self.write("docs/d.txt", "İ\nmet ZOË ÅNGSTRÖM today\n")
        proc = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), "--inherit", "--baseline", "base",
                               "--no-gitleaks", "--terms", str(terms)], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("docs/d.txt:2: private term", proc.stdout)

    def test_planted_private_host_and_new_email_fail(self):
        self.assert_flags("docs/x.md", "push to https://%s/repo" % PRIVATE_HOST, "Stage 11 host")
        self.assert_flags("docs/y.md", "write to " + NEW_EMAIL, "email address")

    def test_a_kind_public_c11_lacks_still_blocks(self):
        self.write("AGENTS.md", "Builds run elsewhere.\n")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-am", "no kinds")
        code, out = self.run_check(baseline="head")
        self.assertEqual(code, 0, out)
        self.write("docs/z.md", "fine\nOn " + LAPTOP + "\n")
        code, out = self.run_check(baseline="head")
        self.assertEqual(code, 1, out)
        self.assertIn("operator's machine or place", out)

    def test_a_strict_line_public_c11_already_ships_is_inherited(self):
        self.write("scripts/fixture.py", BASELINE["scripts/fixture.py"] + "OTHER = 1\n")
        self.assert_clean()
        self.write("scripts/other.py", BASELINE["scripts/fixture.py"])
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("scripts/other.py:1:", out)

    def test_operations_paths_block(self):
        self.write("notes/" + RUN_DIR + "/status.md", "run state\n")
        self.write("tools/friend-downloads/wrangler.toml", "name = 'x'\n")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("notes/" + RUN_DIR + "/status.md: operations material", out)
        self.assertIn("tools/friend-downloads/wrangler.toml: operations material", out)

    def test_allowlist_admits_a_line_and_an_unused_entry_fails(self):
        self.make_clean()
        self.write("tests/t.py", "fine\nreach %s first\n" % TAILNET_IP)
        self.write("scripts/public-tree-allowlist.txt",
                   "tests/t.py\treach %s first\ta planted fixture\n" % TAILNET_IP, track=False)
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 0, out)
        self.write("tests/t.py", "fine\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.assertIn("allowlist entry matched no line", out)
        code, out = self.run_check()  # --inherit doesn't judge the strict bar's entries
        self.assertEqual(code, 0, out)

    def test_private_terms_come_from_a_private_file(self):
        terms = self.root.parent / (self.root.name + "-terms.txt")
        terms.write_text("# clients\nAcme Widgets\n", encoding="utf-8")
        self.addCleanup(terms.unlink)
        self.write("design/mock.html", "fine\n{ name: 'acme-widgets', mission: 'Acme Widgets engagement.' }\n")
        proc = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), "--inherit", "--baseline", "base",
                               "--no-gitleaks", "--terms", str(terms)], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("design/mock.html:2: private term", proc.stdout)
        # A client name blocks even on a line the baseline already ships.
        self.write("AGENTS.md", BASELINE["AGENTS.md"] + "Acme Widgets\n")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-am", "leak")
        proc = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), "--inherit", "--baseline", "head",
                               "--no-gitleaks", "--terms", str(terms)], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30)
        self.assertIn("AGENTS.md:3: private term", proc.stdout)
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("client and people names not checked", out)

    # C11H-284: strict, the default and the gate before the public push.

    def test_strict_blocks_every_kind_the_1x_bar_inherits(self):
        self.make_clean()
        self.write("docs/new.md", "fine\nOn " + LAPTOP + ", open " + PROJECTS_TILDE + "/code/c11.\n"
                                  "Then ssh " + BUILD_HOST_LC + " and write to " + HELLO + " or see " + BOARD_HOST + ".\n")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-am", "kinds")
        code, out = self.run_check(baseline="head")
        self.assertEqual(code, 0, out)  # the 1.x bar: public c11 already carries all of it
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        for kind in ("docs/new.md:2: operator's machine or place", "docs/new.md:2: operator's home path or contact",
                     "docs/new.md:3: private machine used as a host", "docs/new.md:3: email address",
                     "docs/new.md:3: Stage 11 host"):
            self.assertIn(kind, out)

    def test_strict_names_the_build_host_but_not_identifiers_or_vendored_text(self):
        self.make_clean()
        self.write("docs/a.md", "fine\nBuilds run on " + BUILD_HOST + "'s slots.\n")
        self.write("docs/b.md", "HC" + BUILD_HOST + "Link reads c11-" + BUILD_HOST_LC + "-link.sh and "
                   + BUILD_HOST_LC + "_slots.py\n")
        self.write("Resources/markdown-viewer/vendor/lib.js", "// a texture " + BUILD_HOST_LC + "\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.assertIn("docs/a.md:2: operator's machine or place", out)
        self.assertNotIn("docs/b.md", out)
        self.assertNotIn("vendor/lib.js", out)

    def test_strict_needs_no_baseline_and_an_allowlist_line_admits_a_match(self):
        self.make_clean()
        self.write("tests/t.py", "fine\nhost = '" + LAPTOP + "'\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.assertNotIn("nothing was measured", out)
        self.write("scripts/public-tree-allowlist.txt",
                   "tests/t.py\thost = '" + LAPTOP + "'\ta sample name\n", track=False)
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 0, out)
        self.assertIn("ok", out)

    def test_strict_finds_every_spelling_of_a_two_word_place_through_the_file_prefilter(self):
        # The whole-file word prefilter must pass each spelling on to the line scan (Review 1, finding 2).
        lab = "Ger" + "mans"
        for text in ("Hosted at " + lab + " Lab.", "Hosted at " + lab[:-1] + "'s Lab.", "Hosted at " + lab + "Lab.",
                     "See atin" + ".me for more."):
            with self.subTest(text=text):
                self.make_clean()
                self.write("AGENTS.md", text + "\n")
                code, out = self.run_check(strict=True)
                self.assertEqual(code, 1, out)
                self.assertIn("AGENTS.md:1:", out)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is not installed")
    def test_a_dedicated_gitleaks_rule_still_blocks_in_a_vendored_file(self):
        # Vendored files skip only gitleaks' generic rule (Review 1, finding 1).
        self.make_clean()
        self.write("Resources/markdown-viewer/vendor/probe.js",
                   'const key = "' + "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc" + '";\n')
        code, out = self.run_check(strict=True, gitleaks=True)
        self.assertEqual(code, 1, out)
        self.assertIn("vendor/probe.js:1: gitleaks", out)

    def test_an_allowlist_line_may_quote_a_tsv_row(self):
        self.make_clean()
        row = "c11Tests/X/testY\t" + BUILD_HOST_LC + "\tskipped on the build route"
        self.write("scripts/q.tsv", row + "\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.write("scripts/public-tree-allowlist.txt", "scripts/q.tsv\t" + row + "\ta legacy scope name\n", track=False)
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 0, out)

    def test_pending_path_blocks_unless_allowed(self):
        self.make_clean()
        self.write("notes/c11-2.0/PROGRESS.md", "run state on " + LAPTOP + "\n")
        code, out = self.run_check(strict=True)
        self.assertEqual(code, 1, out)
        self.assertIn("notes/c11-2.0/: pending, 1 files", out)
        code, out = self.run_check(strict=True, extra=["--allow-pending"])
        self.assertEqual(code, 0, out)
        self.assertIn("allowed by --allow-pending", out)

    def test_strict_and_inherit_together_cannot_run(self):
        code, out = self.run_check(extra=["--strict"])
        self.assertEqual(code, 2, out)

    def test_missing_baseline_cannot_pass(self):
        code, out = self.run_check(baseline="c11/main")
        self.assertEqual(code, 2, out)
        self.assertIn("nothing was measured", out)


if __name__ == "__main__":
    unittest.main()
