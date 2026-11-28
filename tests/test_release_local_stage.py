#!/usr/bin/env python3
"""Runtime proof that `scripts/release-local.sh --stage` publishes nothing, and
that its plain real and dry runs make the same external calls as the baseline's.

Each case runs the real script in a throwaway git sandbox: a bare repository as
origin, a fake pristine build reused with --reuse-build, --host local, and the
signing-keychain mode (a dummy keychain file and a fake unlock helper), with
every platform tool replaced by tests/fixtures/release_local_tools.py, which
records each call. `/usr/bin/codesign` is reached by absolute path, so BASH_ENV
defines a function of that name that calls the fake. HOME and TMPDIR are the
sandbox; nothing touches the network, a keychain, GitHub or the operator's home.
macOS only; under 20 s (the plain runs go in parallel).

    python3 tests/test_release_local_stage.py

The plain runs are compared with the script at C11_RELEASE_LOCAL_BASELINE
(default origin/main), skipped when that ref is missing. A change that means to
alter what a plain run calls points it at a ref that already carries the change.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import hashlib
import json
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
FIXTURE = REPO / "tests" / "fixtures" / "release_local_tools.py"
BASELINE = os.environ.get("C11_RELEASE_LOCAL_BASELINE", "origin/main")
SCRIPT = "scripts/release-local.sh"
REPO_SLUG = "Stage-11-Agentics/c11"
SPARKLE_PUBLIC_KEY = "naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk="
VERSION, BUILD = "9.8.7", "987"
TAG = f"v{VERSION}"
ASSET_NAMES = sorted([
    "c11-macos.dmg", "appcast.xml", "c11d-remote-darwin-arm64", "c11d-remote-darwin-amd64",
    "c11d-remote-linux-arm64", "c11d-remote-linux-amd64", "c11d-remote-checksums.txt",
    "c11d-remote-manifest.json",
])
PATH_TOOLS = ("gh", "codesign", "xcrun", "spctl", "security", "npx", "swift", "openssl", "lipo", "git",
              "curl", "sentry-cli", "go", "ssh", "rsync", "pkill", "killall")
SCRIPT_STUBS = ("scripts/build_remote_daemon_release_assets.sh", "scripts/fetch-sparkle-tools.sh",
                "scripts/sparkle_generate_appcast.sh", "scripts/c11-remote-artifacts.sh",
                "scripts/remote-build.sh", "tests/test_cli_version_memory_guard.py")
COPIED = ("scripts/extract-release-notes.sh", "scripts/release_asset_guard.js", "c11.entitlements")
REAL_TOOLS = {name: shutil.which(name) for name in ("git", "jq", "node")}
RUN_TIMEOUT_S = 25


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_subcommand(argv):
    index = 0
    while index < len(argv) and argv[index].startswith("-"):
        index += 2 if argv[index] in ("-C", "-c") else 1
    return argv[index] if index < len(argv) else ""


def gh_is_read_only(argv):
    if argv[:2] in (["auth", "status"], ["run", "list"]):
        return True
    writes = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"}
    return argv[:1] == ["api"] and not writes & set(argv)


def publishing_calls(calls):
    """Every call that tags, pushes, writes GitHub, uploads, or reads the Sentry token."""
    bad = []
    for call in calls:
        tool, argv = call["tool"], call["argv"]
        if (tool == "git" and git_subcommand(argv) in ("tag", "push")
                or tool == "gh" and not gh_is_read_only(argv)
                or tool in ("sentry-cli", "curl", "ssh", "rsync", "remote-build.sh")
                or tool == "security" and "c11-sentry-auth-token" in argv):
            bad.append(call)
    return bad


def wrapper(name):
    return (f"#!{sys.executable} -ISB\n"
            "import sys\n"
            f"sys.path.insert(0, {str(FIXTURE.parent)!r})\n"
            "import release_local_tools\n"
            f"release_local_tools.main({name!r})\n")


def write_exec(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class Run:
    def __init__(self, code, output, pid, calls):
        self.code, self.output, self.pid, self.calls = code, output, pid, calls


class Sandbox:
    """One throwaway release checkout, its origin, fake tools and fake build."""

    def __init__(self, base, script_text):
        self.root = Path(os.path.realpath(base))
        self.repo, self.origin = self.root / "repo", self.root / "origin.git"
        self.home, self.tmp, self.state = self.root / "home", self.root / "tmp", self.root / "state"
        self.bin, self.realbin = self.root / "bin", self.root / "realbin"
        for folder in (self.home, self.tmp, self.state, self.bin, self.realbin, self.state / "sparkle-bin"):
            folder.mkdir(parents=True)
        self.git_env = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.home), "TMPDIR": str(self.tmp),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2026-11-27T12:00:00+0000", "GIT_COMMITTER_DATE": "2026-11-27T12:00:00+0000",
        }
        self.tools()
        self.checkout(script_text)
        self.pristine()
        self.keychain = self.home / "signing.keychain-db"
        self.keychain.write_bytes(b"not a keychain")
        self.helper = self.home / "bin" / "release_keychain.sh"
        write_exec(self.helper, wrapper("release_keychain.sh"))
        self.bash_env = self.state / "bash_env.sh"
        self.bash_env.write_text('/usr/bin/codesign() { codesign "$@"; }\n')
        self.set_gh({"releases": [{"id": 900, "tag_name": "v0.9.0", "draft": False, "prerelease": False,
                                   "assets": []}], "latest": "v0.9.0", "next_id": 1000, "fail": []})

    # ------------------------------------------------------------ setup --
    def git(self, *args, cwd=None):
        return subprocess.run([REAL_TOOLS["git"], *args], cwd=cwd or self.repo, env=self.git_env, check=True,
                              text=True, capture_output=True).stdout.strip()

    def tools(self):
        for name in PATH_TOOLS:
            write_exec(self.bin / name, wrapper(name))
        write_exec(self.state / "sparkle-bin" / "generate_keys", wrapper("generate_keys"))
        for name in ("jq", "node"):
            (self.realbin / name).symlink_to(REAL_TOOLS[name])
        (self.realbin / "python3").symlink_to(sys.executable)

    def checkout(self, script_text):
        write_exec(self.repo / SCRIPT, script_text)
        for rel in COPIED:
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.repo / rel)
        for rel in SCRIPT_STUBS:
            write_exec(self.repo / rel, wrapper(Path(rel).name))
        (self.repo / "CHANGELOG.md").write_text(
            f"# Changelog\n\n## [{VERSION}] - 2026-11-27\n\n- Fixture release.\n\n## [0.9.0] - 2026-01-01\n\n- Old.\n")
        pbx = self.repo / "GhosttyTabs.xcodeproj" / "project.pbxproj"
        pbx.parent.mkdir()
        pbx.write_text("".join(f"\t\t\t\tMARKETING_VERSION = {VERSION};\n\t\t\t\tCURRENT_PROJECT_VERSION = {BUILD};\n"
                               for _ in range(2)))
        (self.repo / ".gitignore").write_text("build-release-local/\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "fixture release checkout")
        self.head = self.git("rev-parse", "HEAD")
        self.git("init", "-q", "--bare", "-b", "main", str(self.origin), cwd=self.root)
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")

    def pristine(self):
        out = self.repo / "build-release-local" / TAG / "pristine"
        contents = out / "c11.app" / "Contents"
        info = {
            "CFBundleIdentifier": "com.stage11.c11", "CFBundleExecutable": "c11", "CFBundleName": "c11",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD,
            "C11Commit": self.head[:9], "DTXcode": "2630", "DTSDKName": "macosx26.2",
        }
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        for rel in ("MacOS/c11", "Resources/bin/c11", "Resources/bin/ghostty", "Helpers/herdr-core"):
            write_exec(contents / rel, f"fake arm64 {rel}\n")
        (contents / "Resources" / "hc-pin.json").write_text('{"executableSHA256":"unsealed","version":"0.1"}\n')
        (out / "dsyms" / "c11.app.dSYM" / "Contents").mkdir(parents=True)
        (out / "dsyms" / "c11.app.dSYM" / "Contents" / "Info.plist").write_text("dsym\n")
        (out / "build-identity.json").write_text(json.dumps({
            "head": self.head, "invocation": "fixture", "host": "local", "products": "fixture",
            "unsigned_exec_sha256": sha256(contents / "MacOS" / "c11"), "xcode": "26.3", "dirty": False,
        }))

    def tag(self, where, commit=None):
        """Tag `commit` (default HEAD) locally, on origin, or both."""
        commit = commit or self.head
        if where in ("local", "both"):
            self.git("-c", "tag.gpgsign=false", "tag", "-a", TAG, "-m", TAG, commit)
        if where == "both":
            self.git("push", "-q", "origin", f"refs/tags/{TAG}")
        if where == "origin":
            self.git("push", "-q", "origin", f"{commit}:refs/tags/{TAG}")

    def other_commit(self):
        return self.git("commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "another commit")

    def set_gh(self, state):
        (self.state / "gh.json").write_text(json.dumps(state))

    def gh_state(self):
        return json.loads((self.state / "gh.json").read_text())

    def releases_seen(self):
        """The fake GitHub's releases and latest, without digests (the DMG embeds this sandbox's HEAD)."""
        state = self.gh_state()
        return state["latest"], [(r["tag_name"], r["draft"], sorted((a["name"], a["size"]) for a in r["assets"]))
                                 for r in state["releases"]]

    # -------------------------------------------------------------- run --
    @property
    def out(self):
        return self.repo / "build-release-local" / TAG

    def run(self, *args):
        calls = self.state / "calls.jsonl"
        if calls.exists():
            calls.unlink()
        env = {
            "PATH": f"{self.bin}:{self.realbin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home), "TMPDIR": str(self.tmp), "LANG": "en_US.UTF-8",
            "BASH_ENV": str(self.bash_env), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "RELEASE_STUB_STATE": str(self.state), "RELEASE_STUB_REAL_GIT": REAL_TOOLS["git"],
            "C11_SIGNING_KEYCHAIN": str(self.keychain), "C11_SIGNING_KEYCHAIN_HELPER": str(self.helper),
        }
        proc = subprocess.Popen(["/bin/bash", str(self.repo / SCRIPT), "--host", "local", "--reuse-build", *args],
                                cwd=self.repo, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            output, _ = proc.communicate(timeout=RUN_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)  # only the sandbox's own process group
            output, _ = proc.communicate()
            raise AssertionError(f"release-local.sh {' '.join(args)} timed out:\n{output}")
        lines = calls.read_text().splitlines() if calls.exists() else []
        return Run(proc.returncode, output, proc.pid, [json.loads(line) for line in lines])

    def normalized(self, run):
        """Calls with sandbox paths, HEAD, the run's pid and mktemp suffixes made stable.

        The daemon asset build runs in the background, so its call is split out
        and compared on its own instead of by position."""
        def norm(text):
            text = text.replace(str(self.root), "<SANDBOX>")
            text = text.replace(self.head, "<HEAD>").replace(self.head[:9], "<HEAD9>")
            text = re.sub(r"(c11-exec|c11-sparkle-key)\.[A-Za-z0-9]+", r"\1.XXXXXX", text)
            return "<PID>" if text == str(run.pid) else text

        main, background = [], []
        for call in run.calls:
            entry = {"tool": call["tool"], "argv": [norm(a) for a in call["argv"]], "cwd": norm(call["cwd"]),
                     "env": {k: norm(v) for k, v in call["env"].items()}}
            (background if call["tool"] == "build_remote_daemon_release_assets.sh" else main).append(entry)
        return main, background


def calls_of(run, tool, *prefix):
    return [c for c in run.calls if c["tool"] == tool and c["argv"][:len(prefix)] == list(prefix)]


@unittest.skipUnless(sys.platform == "darwin", "release-local.sh is macOS only (PlistBuddy, ditto, plutil)")
@unittest.skipUnless(all(REAL_TOOLS.values()), "needs git, jq and node on PATH")
class ReleaseLocalStageTests(unittest.TestCase):
    def sandbox(self, script_text=None):
        tmp = tempfile.TemporaryDirectory(prefix="c11-release-local-")
        self.addCleanup(tmp.cleanup)
        return Sandbox(tmp.name, script_text if script_text is not None else (REPO / SCRIPT).read_text())

    def assert_refused_before_build(self, box, run, message):
        self.assertNotEqual(run.code, 0, run.output)
        self.assertIn(message, run.output)
        self.assertNotIn("finished OK", run.output)
        self.assertFalse((box.out / "stage").exists(), "a refused stage left a stage folder")
        self.assertEqual(publishing_calls(run.calls), [], run.output)
        self.assertEqual(calls_of(run, "xcrun", "notarytool", "submit"), [])
        self.assertEqual([c for c in run.calls if c["tool"] == "codesign" and "--sign" in c["argv"]], [])

    # 1 ----------------------------------------------------------------------
    def test_stage_signs_notarizes_and_publishes_nothing(self):
        box = self.sandbox()
        origin_refs = box.git("for-each-ref", cwd=box.origin)
        run = box.run("--stage", TAG)
        self.assertEqual(run.code, 0, run.output)
        self.assertIn(f"==== release-local {TAG} STAGE RUN finished OK", run.output)

        self.assertEqual(publishing_calls(run.calls), [], "a stage run called a publishing tool")
        for call in calls_of(run, "gh"):
            self.assertTrue(gh_is_read_only(call["argv"]), call)
        self.assertEqual(box.git("tag", "-l"), "")
        self.assertEqual(box.git("for-each-ref", cwd=box.origin), origin_refs)
        self.assertEqual([r["tag_name"] for r in box.gh_state()["releases"]], ["v0.9.0"])

        # It is a real release's tail: release identity, both notarizations, the c11mux key.
        submits = calls_of(run, "xcrun", "notarytool", "submit")
        self.assertEqual([Path(c["argv"][2]).name for c in submits], ["c11-notary.zip", "c11-macos.dmg"])
        self.assertGreaterEqual(len([c for c in run.calls if c["tool"] == "codesign" and "--sign" in c["argv"]]), 4)
        self.assertEqual(len([c for c in calls_of(run, "security", "find-generic-password")
                              if "https://sparkle-project.org" in c["argv"]]), 1)
        verify = [c for c in calls_of(run, "swift") if c["argv"][0].endswith("verify_sparkle_appcast.swift")]
        self.assertEqual([c["argv"][3] for c in verify], [SPARKLE_PUBLIC_KEY])

        stage = box.out / "stage"
        self.assertEqual(sorted(p.name for p in stage.iterdir()), sorted(ASSET_NAMES + ["c11.app", "stage.json"]))
        record = json.loads((stage / "stage.json").read_text())
        self.assertEqual((record["tag"], record["version"], record["build"], record["head"]),
                         (TAG, VERSION, BUILD, box.head))
        self.assertEqual(sorted(a["name"] for a in record["assets"]), ASSET_NAMES)
        for asset in record["assets"]:
            staged = stage / asset["name"]
            self.assertEqual(asset["sha256"], sha256(staged), asset["name"])
            self.assertEqual(asset["size"], staged.stat().st_size, asset["name"])
        self.assertEqual(sha256(stage / "c11-macos.dmg"), sha256(box.out / "c11-macos.dmg"))
        self.assertTrue((stage / "c11-macos.dmg").read_bytes().endswith(b"STUB-NOTARIZATION-TICKET\n"),
                        "staged DMG is not the stapled one")
        self.assertEqual(record["appcast_verify"]["shortVersionString"], VERSION)
        self.assertEqual(record["appcast_verify"]["version"], BUILD)

        app = stage / "c11.app" / "Contents"
        self.assertTrue((app / "CodeResources").exists(), "staged app is not the stapled one")
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["SUPublicEDKey"], SPARKLE_PUBLIC_KEY)
        self.assertIn("C11RemoteDaemonManifestJSON", info)
        helper_sha = sha256(app / "Helpers" / "herdr-core")
        self.assertEqual(json.loads((app / "Resources" / "hc-pin.json").read_text())["executableSHA256"], helper_sha)
        self.assertEqual(record["hc_pin_executable_sha256"], helper_sha)

    # 2 ----------------------------------------------------------------------
    def test_stage_refuses_when_a_release_exists(self):
        for draft in (True, False):
            with self.subTest(draft=draft):
                box = self.sandbox()
                state = box.gh_state()
                state["releases"].append({"id": 950, "tag_name": TAG, "draft": draft, "prerelease": False,
                                          "assets": []})
                box.set_gh(state)
                run = box.run("--stage", TAG)
                self.assert_refused_before_build(box, run, f"a GitHub release for {TAG} already exists")

    def test_stage_stops_when_the_release_lookup_fails(self):
        box = self.sandbox()
        state = box.gh_state()
        state["fail"] = ["releases-list"]
        box.set_gh(state)
        run = box.run("--stage", TAG)
        self.assert_refused_before_build(box, run, "could not list releases on GitHub")

    def test_stage_refuses_a_tag_at_another_commit(self):
        for where in ("local", "origin"):
            with self.subTest(where=where):
                box = self.sandbox()
                other = box.other_commit()
                box.tag(where, other)
                run = box.run("--stage", TAG)
                self.assert_refused_before_build(box, run, f"{TAG} exists {'locally' if where == 'local' else 'on origin'} at {other}")

    # 3 ----------------------------------------------------------------------
    def test_stage_and_dry_run_exclude_each_other(self):
        box = self.sandbox()
        for args in (("--stage", "--dry-run", TAG), ("--dry-run", "--stage", TAG)):
            with self.subTest(args=args):
                run = box.run(*args)
                self.assertEqual(run.code, 2, run.output)
                self.assertIn("--stage and --dry-run exclude each other", run.output)
                self.assertEqual(run.calls, [])
                self.assertFalse((box.repo / "build-release-local" / TAG / "release-local.log").exists())

    # 4 ----------------------------------------------------------------------
    def test_plain_runs_call_what_the_baseline_calls(self):
        branch_text = (REPO / SCRIPT).read_text()
        shown = subprocess.run(["git", "-C", str(REPO), "show", f"{BASELINE}:{SCRIPT}"], text=True,
                               capture_output=True)
        if shown.returncode != 0:
            self.skipTest(f"baseline {BASELINE} is not available here")
        # An identical baseline (this script after it merges) needs no second run.
        scripts = [("branch", branch_text)] + ([("baseline", shown.stdout)] if shown.stdout != branch_text else [])
        cases = [(label, text, mode) for mode in ((TAG,), ("--dry-run", TAG)) for label, text in scripts]
        boxes = [self.sandbox(text) for _, text, _ in cases]
        for box in boxes:
            box.tag("both")
        with ThreadPoolExecutor(max_workers=len(cases)) as pool:
            runs = list(pool.map(lambda pair: pair[0].run(*pair[1]), zip(boxes, [m for _, _, m in cases])))
        results = {(label, mode): (box, run) for (label, _, mode), box, run in zip(cases, boxes, runs)}

        for mode, finished in (((TAG,), "REAL RUN"), (("--dry-run", TAG), "DRY RUN")):
            with self.subTest(mode=finished):
                for label, _ in scripts:
                    run = results[label, mode][1]
                    self.assertEqual(run.code, 0, f"{label}:\n{run.output}")
                    self.assertIn(f"==== release-local {TAG} {finished} finished OK", run.output)
                if ("baseline", mode) not in results:
                    continue
                (base_box, base), (branch_box, branch) = results["baseline", mode], results["branch", mode]
                base_main, base_bg = base_box.normalized(base)
                branch_main, branch_bg = branch_box.normalized(branch)
                self.assertEqual(branch_bg, base_bg)
                for index, (got, want) in enumerate(zip(branch_main, base_main)):
                    self.assertEqual(got, want, f"call {index} differs from {BASELINE}'s")
                common = min(len(branch_main), len(base_main))
                self.assertEqual(len(branch_main), len(base_main),
                                 f"only one side makes these calls: {(branch_main + base_main)[common:][:3]}")
                self.assertEqual(branch_box.releases_seen(), base_box.releases_seen())

        # The detector sees publishing: the plain real run tags nothing but does
        # every other thing a stage run must never do.
        _, real = results["branch", (TAG,)]
        seen = publishing_calls(real.calls)
        self.assertTrue(calls_of(real, "gh", "release", "create"))
        self.assertTrue([c for c in seen if c["tool"] == "gh" and "PATCH" in c["argv"]])
        self.assertTrue(calls_of(real, "gh", "workflow", "run"))
        self.assertTrue(calls_of(real, "sentry-cli"))
        self.assertTrue(calls_of(real, "curl"))
        self.assertTrue([c for c in seen if c["tool"] == "security"])
        self.assertTrue(all(c in seen for c in calls_of(real, "gh", "release")))


if __name__ == "__main__":
    unittest.main()
