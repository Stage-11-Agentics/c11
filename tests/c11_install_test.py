#!/usr/bin/env python3
"""Behavioral tests for scripts/c11-install.sh. They use a fake home."""

import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL = Path(os.environ.get("C11_INSTALL_BIN", ROOT / "scripts" / "c11-install.sh"))
BUNDLE = "com.stage11.c11"
FAKE_PID = "2000000001"
shlex_quote = shlex.quote
LEGACY_BUNDLE = "com.stage11.c11h"  # c11-2.0:keep (the retired app the installer never touches)


def write_app(path: Path, bundle_id: str, build_id: str, extra=None):
    mac = path / "Contents" / "MacOS"
    res = path / "Contents" / "Resources" / "bin"
    mac.mkdir(parents=True)
    res.mkdir(parents=True)
    (mac / "c11").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (res / "c11").write_text(build_id, encoding="utf-8")
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "c11",
        "CFBundleExecutable": "c11",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": build_id,
        "CFBundleVersion": "1",
    }
    if extra:
        info.update(extra)
    with (path / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)


def seed_c11(home: Path):
    prefs = home / "Library" / "Preferences"
    support = home / "Library" / "Application Support" / "c11"
    agents = home / ".config" / "c11" / "agents"
    prefs.mkdir(parents=True)
    support.mkdir(parents=True)
    agents.mkdir(parents=True)
    (support / "themes").mkdir()
    (support / "themes" / "paper.theme").write_text("paper", encoding="utf-8")
    (support / "agent-configs.json").write_text('{"library":"kept"}\n', encoding="utf-8")
    (support / "socket-control-password").write_text("secret", encoding="utf-8")
    (support / "last-socket-path").write_text("/tmp/c11.sock", encoding="utf-8")
    (support / "c11.sock").write_text("socket", encoding="utf-8")
    (support / "session-com.stage11.c11.json").write_text("{}", encoding="utf-8")
    (agents / "claude.json").write_text('{"shared":true}\n', encoding="utf-8")
    source = {
        "sidebarTintHex": "#112233",
        "attention.flagKinds.v1": "custom-kind",
        "SUFeedURL": "https://example.invalid/appcast.xml",
        "cmux.sparkle.automaticChecksMigration.v2": 1,
        "socketPath": "/tmp/c11.sock",
        "lastSocketPath": "/tmp/c11-last-socket-path",
        "cmuxPortBase": 9100,
        "cmuxPortRange": 10,
        "sendAnonymousTelemetry": True,
        "c11.sidebar.backgroundDark": "off",
    }
    with (prefs / "com.stage11.c11.plist").open("wb") as handle:
        plistlib.dump(source, handle)
    return source


def freeze(path: Path):
    for root, dirs, files in os.walk(path):
        for name in files:
            file_path = Path(root) / name
            mode = file_path.stat().st_mode
            file_path.chmod(mode & ~stat.S_IWUSR & ~stat.S_IWGRP & ~stat.S_IWOTH)
        for name in dirs:
            dir_path = Path(root) / name
            mode = dir_path.stat().st_mode
            dir_path.chmod(mode & ~stat.S_IWUSR & ~stat.S_IWGRP & ~stat.S_IWOTH)


def snapshot(path: Path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.exists():
        return "absent"
    rows = []
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            file_path = Path(root) / name
            rel = file_path.relative_to(path).as_posix()
            if file_path.is_symlink():
                rows.append("link %s %s" % (rel, os.readlink(file_path)))
            elif file_path.is_file():
                rows.append("file %s %s" % (rel, hashlib.sha256(file_path.read_bytes()).hexdigest()))
    return "\n".join(rows)


def load_plist(path: Path):
    with path.open("rb") as handle:
        return plistlib.load(handle)


class InstallTests(unittest.TestCase):
    def setUp(self):
        # macOS can refuse, for a while, to change a bundle whose executable ran,
        # so what cannot be removed yet is left in TMPDIR rather than failing.
        self.tmp = type("Tmp", (), {"name": tempfile.mkdtemp(prefix="c11-install-")})()
        self.addCleanup(lambda: shutil.rmtree(self.tmp.name, ignore_errors=True))
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.apps = Path(self.tmp.name) / "apps"
        self.apps.mkdir()
        self.dest = Path(self.tmp.name) / "Applications" / "c11.app"
        self.hc = self.home / ".local" / "share" / "c11" / "hc" / "0.1.16"
        self.hc.mkdir(parents=True)
        (self.hc / "herdr-core").write_text("pinned", encoding="utf-8")
        self.quit_log = Path(self.tmp.name) / "quit.log"
        self.stamp = Path(self.tmp.name) / "killed"
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        for name in ("killall", "pkill"):
            tool = self.bin / name
            tool.write_text(
                "#!/bin/sh\necho %s >> \"%s\"\nexit 99\n" % (name, self.stamp),
                encoding="utf-8",
            )
            tool.chmod(0o755)
        # C11H-100: a fake kill. It records each call with the installed app's build at that
        # moment and never signals anything; `-0` answers "alive" while the pid's countdown in
        # kill-state/ lasts ("forever" never ends). Test pids are above macOS's pid limit
        # (99998), so not even a real kill could reach a process.
        self.kill_log = Path(self.tmp.name) / "kill.log"
        self.kill_state = Path(self.tmp.name) / "kill-state"
        self.kill_state.mkdir()
        self.fake_kill = self.bin / "fake-kill"
        self.fake_kill.write_text(
            "#!/bin/sh\n"
            "build=$(cat %(dest)s/Contents/Resources/bin/c11 2>/dev/null || echo none)\n"
            "printf '%%s %%s build=%%s\\n' \"$1\" \"$2\" \"$build\" >> %(log)s\n"
            "[ \"$1\" = -0 ] || exit 0\n"
            "n=$(cat %(state)s/\"$2\" 2>/dev/null || echo 0)\n"
            "[ \"$n\" = forever ] && exit 0\n"
            "[ \"$n\" -gt 0 ] 2>/dev/null || exit 1\n"
            "echo $((n - 1)) > %(state)s/\"$2\"\n"
            % {"dest": shlex_quote(str(self.dest)), "log": shlex_quote(str(self.kill_log)),
               "state": shlex_quote(str(self.kill_state))},
            encoding="utf-8",
        )
        self.fake_kill.chmod(0o755)
        seed_c11(self.home)
        freeze(self.home / "Library" / "Application Support" / "c11")
        (self.home / "Library" / "Preferences" / "com.stage11.c11.plist").chmod(0o444)
        freeze(self.home / ".config")
        self.source_snapshot = self.source_state()
        self.hc_snapshot = snapshot(self.hc.parent.parent)

    def source_state(self):
        return "\n".join([
            snapshot(self.home / "Library" / "Application Support" / "c11"),
            snapshot(self.home / "Library" / "Preferences" / "com.stage11.c11.plist"),
            snapshot(self.home / ".config"),
        ])

    def env(self, **extra):
        env = os.environ.copy()
        env.update(
            C11_HOME=str(self.home),
            C11_APP_PATH=str(self.dest),
            C11_HC_ROOT=str(self.hc.parent.parent),
            C11_QUIT_MODE="record",
            C11_QUIT_LOG=str(self.quit_log),
            C11_KILL=str(self.fake_kill),
            PATH=str(self.bin) + os.pathsep + env.get("PATH", ""),
        )
        env.update(extra)
        return env

    def install(self, artifact, env=None, check=True):
        proc = subprocess.run(
            [str(INSTALL), str(artifact)],
            env=env or self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if check and proc.returncode != 0:
            self.fail("install failed (%s)\n%s\n%s" % (proc.returncode, proc.stdout, proc.stderr))
        return proc

    def make(self, name, bundle_id=BUNDLE, build_id="A"):
        path = self.apps / name
        write_app(path, bundle_id, build_id)
        return path

    def test_refuses_the_retired_bundle_and_app_path(self):
        proc = self.install(self.make("c11h.app", bundle_id=LEGACY_BUNDLE), check=False)  # c11-2.0:keep
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(LEGACY_BUNDLE, proc.stderr)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.quit_log.exists())
        self.assertFalse(self.stamp.exists())
        self.assertEqual(self.source_state(), self.source_snapshot)

        foreign = self.dest
        write_app(foreign, LEGACY_BUNDLE, "foreign")
        good = self.make("c11.app", build_id="A")
        proc = self.install(good, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual((foreign / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "foreign")

        proc = subprocess.run(
            [str(INSTALL), str(good)],
            env=self.env(C11_APP_PATH=str(Path(self.tmp.name) / "c11h.app")),  # c11-2.0:keep
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("c11h.app", proc.stderr)  # c11-2.0:keep

    # C11H-130: on a Mac without the Command Line Tools, /usr/bin/python3 is a stub that
    # opens macOS's install prompt. The installer refuses before it changes or runs anything.
    def fake_xcode_select(self, developer_dir=None):
        log = Path(self.tmp.name) / "xcode-select.log"
        tool = self.bin / "xcode-select"
        if developer_dir is None:
            body = "echo called >> %s\nexit 2\n" % shlex_quote(str(log))
        else:
            body = "echo called >> %s\necho %s\n" % (shlex_quote(str(log)), shlex_quote(str(developer_dir)))
        tool.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        tool.chmod(0o755)
        return tool, log

    def developer_dir(self, with_python):
        dev = Path(self.tmp.name) / ("dev-good" if with_python else "dev-stale")
        (dev / "usr" / "bin").mkdir(parents=True)
        if with_python:
            shim = dev / "usr" / "bin" / "python3"
            shim.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            shim.chmod(0o755)
        return dev

    def system_python_env(self, tool):
        if not os.access("/usr/bin/python3", os.X_OK):
            self.skipTest("no /usr/bin/python3 on this machine")
        return self.env(C11_XCODE_SELECT=str(tool),
                        PATH=os.pathsep.join([str(self.bin), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]))

    def assert_refused_untouched(self, proc, log):
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(proc.stderr.count("\n"), 1, proc.stderr)
        self.assertIn("xcode-select --install", proc.stderr)
        self.assertIn("Nothing was changed", proc.stderr)
        self.assertTrue(log.exists(), "the preflight never asked xcode-select")
        self.assertFalse(self.dest.exists())
        self.assertEqual(snapshot(self.home), self.home_before)

    def test_missing_command_line_tools_stops_before_anything_changes(self):
        good = self.make("c11.app", build_id="A")
        tool, log = self.fake_xcode_select()
        self.home_before = snapshot(self.home)
        proc = self.install(good, env=self.system_python_env(tool), check=False)
        self.assert_refused_untouched(proc, log)

    def test_stale_developer_dir_stops_before_anything_changes(self):
        good = self.make("c11.app", build_id="A")
        tool, log = self.fake_xcode_select(self.developer_dir(with_python=False))
        self.home_before = snapshot(self.home)
        proc = self.install(good, env=self.system_python_env(tool), check=False)
        self.assert_refused_untouched(proc, log)

    def test_working_command_line_tools_install(self):
        good = self.make("c11.app", build_id="A")
        tool, log = self.fake_xcode_select(self.developer_dir(with_python=True))
        proc = self.install(good, env=self.system_python_env(tool))
        self.assertTrue(log.exists())
        self.assertIn("installed", proc.stdout)

    def test_python_outside_usr_bin_skips_the_command_line_tools_check(self):
        good = self.make("c11.app", build_id="A")
        tool, log = self.fake_xcode_select()
        own = self.bin / "python3"
        own.write_text("#!/bin/sh\nexec %s \"$@\"\n" % shlex_quote(sys.executable), encoding="utf-8")
        own.chmod(0o755)
        proc = self.install(good, env=self.env(C11_XCODE_SELECT=str(tool)))
        self.assertFalse(log.exists(), "xcode-select ran for a python3 outside /usr/bin")
        self.assertIn("installed", proc.stdout)

    def test_first_install_on_a_mac_without_c11(self):
        # C11H-130: a friend who never had c11 or c11. Nothing to import, nothing of c11's
        # is created, and the app lands.
        fresh = Path(self.tmp.name) / "fresh-home"
        fresh.mkdir()
        good = self.make("c11.app", build_id="A")
        proc = self.install(good, env=self.env(C11_HOME=str(fresh),
                                               C11_HC_ROOT=str(fresh / ".local" / "share" / "c11" / "hc")))
        self.assertIn("installed", proc.stdout)
        self.assertTrue((self.dest / "Contents" / "Info.plist").exists())
        self.assertFalse((fresh / "Library" / "Application Support" / "c11").exists())
        self.assertFalse((fresh / "Library" / "Preferences" / "com.stage11.c11.plist").exists())

    def test_live_quit_queries_only_c11(self):
        query_log = Path(self.tmp.name) / "query.txt"
        fake = self.bin / "osascript"
        fake.write_text(
            "#!/bin/sh\nprintf '%%s\\n' \"$2\" >> %s\nexit 0\n" % repr(str(query_log)),
            encoding="utf-8",
        )
        fake.chmod(0o755)
        self.install(self.make("c11.app", build_id="A"))
        env = self.env(C11_QUIT_MODE="live", C11_OSASCRIPT=str(fake))
        env.pop("C11_QUIT_LOG", None)
        self.install(self.make("B.app", build_id="B"), env=env)
        query = query_log.read_text(encoding="utf-8")
        self.assertIn('bundle identifier is "com.stage11.c11"', query)
        self.assertNotIn("com.stage11.c11h\"", query)  # c11-2.0:keep
        self.assertNotIn("herdr", query)
        self.assertFalse(self.stamp.exists())
        self.assertFalse(self.kill_log.exists())

    def live_update_env(self, **extra):
        fake = self.bin / "osascript"
        fake.write_text("#!/bin/sh\necho %s\nexit 0\n" % FAKE_PID, encoding="utf-8")
        fake.chmod(0o755)
        env = self.env(C11_QUIT_MODE="live", C11_OSASCRIPT=str(fake), **extra)
        env.pop("C11_QUIT_LOG", None)
        return env

    def kill_calls(self):
        return self.kill_log.read_text(encoding="utf-8").splitlines() if self.kill_log.exists() else []

    def test_update_terms_c11hs_pid_and_swaps_only_after_it_exits(self):
        self.install(self.make("c11.app", build_id="A"))
        (self.kill_state / FAKE_PID).write_text("3", encoding="utf-8")
        proc = self.install(self.make("B.app", build_id="B"), env=self.live_update_env())
        calls = self.kill_calls()
        # TERM (c11's clean quit) to the queried pid, then probes until it is gone: three
        # answer alive, the fourth gone. No KILL, and the old app stays until then.
        self.assertEqual(calls, ["-TERM %s build=A" % FAKE_PID] + ["-0 %s build=A" % FAKE_PID] * 4)
        self.assertNotIn("did not quit", proc.stderr)
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "B")
        self.assertFalse(self.stamp.exists())

    def test_update_kills_only_after_the_bounded_wait(self):
        self.install(self.make("c11.app", build_id="A"))
        (self.kill_state / FAKE_PID).write_text("forever", encoding="utf-8")
        proc = self.install(self.make("B.app", build_id="B"), env=self.live_update_env(C11_QUIT_WAIT_TRIES="3"))
        calls = self.kill_calls()
        self.assertEqual(calls[0], "-TERM %s build=A" % FAKE_PID)
        self.assertEqual(calls[1:-1], ["-0 %s build=A" % FAKE_PID] * 4)
        self.assertEqual(calls[-1], "-KILL %s build=A" % FAKE_PID)
        self.assertIn("did not quit", proc.stderr)
        self.assertIn("reads as a crash", proc.stderr)
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "B")
        self.assertFalse(self.stamp.exists())

    def test_quit_wait_must_be_a_whole_number(self):
        self.install(self.make("c11.app", build_id="A"))
        (self.kill_state / FAKE_PID).write_text("3", encoding="utf-8")
        proc = self.install(self.make("B.app", build_id="B"),
                            env=self.live_update_env(C11_QUIT_WAIT_TRIES="20s"), check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("C11_QUIT_WAIT_TRIES must be a whole number", proc.stderr)
        self.assertEqual(self.kill_calls(), [])
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "A")

    def test_zip_and_trace_do_not_touch_other_tools(self):
        app = self.make("c11.app", build_id="A")
        folder = Path(self.tmp.name) / "payload"
        folder.mkdir()
        shutil.copytree(app, folder / "c11.app")
        archive = Path(self.tmp.name) / "c11.zip"
        subprocess.check_call(["ditto", "-c", "-k", "--keepParent", str(folder), str(archive)])
        trace = Path(self.tmp.name) / "trace.txt"
        proc = subprocess.run(
            ["bash", "-x", str(INSTALL), str(archive)],
            env=self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        trace.write_text(proc.stderr, encoding="utf-8")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("imported=no", proc.stdout)
        executed = [line for line in proc.stderr.splitlines() if line.startswith("+")]
        blob = "\n".join(executed)
        for banned in ("killall", "pkill", "show-keychain-info"):
            self.assertNotIn(banned, blob)
        self.assertFalse(any(re.search(r"(^|\s)defaults(\s|$)", line) for line in executed))
        self.assertFalse(self.stamp.exists())

    def test_query_failure_leaves_the_installed_app(self):
        self.install(self.make("c11.app", build_id="A"))
        fake = self.bin / "osascript"
        fake.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        fake.chmod(0o755)
        env = self.env(C11_QUIT_MODE="live", C11_OSASCRIPT=str(fake))
        env.pop("C11_QUIT_LOG", None)
        proc = self.install(self.make("B.app", build_id="B"), env=env, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("could not query processes for com.stage11.c11", proc.stderr)
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "A")
        self.assertEqual(list(self.dest.parent.glob("c11.app.*")), [])
        self.assertFalse(self.stamp.exists())

    def test_failed_copy_removes_the_partial_app(self):
        self.install(self.make("c11.app", build_id="A"))
        fake = self.bin / "ditto"
        fake.write_text(
            "#!/bin/sh\n"
            "dest=\"${@: -1}\"\n"
            "mkdir -p \"$dest\"\n"
            "printf partial > \"$dest/partial\"\n"
            "exit 1\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        proc = self.install(self.make("B.app", build_id="B"), check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "A")
        self.assertEqual(list(self.dest.parent.glob("c11.app.*")), [])
        self.assertFalse((self.dest / "partial").exists())

    def _unfreeze(self, path: Path):
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
        for root, dirs, files in os.walk(path):
            for name in dirs:
                dir_path = Path(root) / name
                dir_path.chmod(dir_path.stat().st_mode | stat.S_IWUSR)
            for name in files:
                file_path = Path(root) / name
                if file_path.is_symlink():
                    continue
                file_path.chmod(file_path.stat().st_mode | stat.S_IWUSR)

    def _relink_c11_settings(self):
        support = self.home / "Library" / "Application Support" / "c11"
        self._unfreeze(support)
        dot = self.home / "dotfiles"
        themes = dot / "themes"
        themes.mkdir(parents=True)
        (themes / "paper.theme").write_text("linked-paper", encoding="utf-8")
        (dot / "ink.theme").write_text("linked-ink", encoding="utf-8")
        (themes / "ink.theme").symlink_to(Path("..") / "ink.theme")
        shutil.rmtree(support / "themes")
        (support / "themes").symlink_to(themes)
        agent = dot / "agent-configs.json"
        agent.write_text('{"library":"linked"}\n', encoding="utf-8")
        (support / "agent-configs.json").unlink()
        (support / "agent-configs.json").symlink_to(agent)
        freeze(support)
        freeze(dot)
        self.source_snapshot = self.source_state()
        self.dot_snapshot = snapshot(dot)
        return support, dot

    def _assert_materialized_links(self, support, dot):
        dest = self.home / "Library" / "Application Support" / "c11"
        paper = dest / "themes" / "paper.theme"
        ink = dest / "themes" / "ink.theme"
        agent = dest / "agent-configs.json"
        self.assertFalse(paper.is_symlink())
        self.assertFalse(ink.is_symlink())
        self.assertFalse(agent.is_symlink())
        self.assertEqual(paper.read_text(encoding="utf-8"), "linked-paper")
        self.assertEqual(ink.read_text(encoding="utf-8"), "linked-ink")
        self.assertEqual(agent.read_text(encoding="utf-8"), '{"library":"linked"}\n')
        self.assertFalse((dest / "socket-control-password").exists())
        self.assertEqual(os.readlink(support / "themes"), str(dot / "themes"))
        self.assertEqual(os.readlink(support / "agent-configs.json"), str(dot / "agent-configs.json"))
        self.assertEqual(self.source_state(), self.source_snapshot)
        self.assertEqual(snapshot(dot), self.dot_snapshot)

    def test_no_argument_installs_the_app_beside_the_script(self):
        folder = Path(self.tmp.name) / "shipped"
        folder.mkdir()
        shutil.copytree(self.make("c11.app", build_id="A"), folder / "c11.app")
        script = folder / "c11-install.sh"
        shutil.copy2(INSTALL, script)
        script.chmod(0o755)
        proc = subprocess.run(
            [str(script)],
            env=self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("imported=no", proc.stdout)
        self.assertEqual((self.dest / "Contents" / "Resources" / "bin" / "c11").read_text(encoding="utf-8"), "A")

    # C11H-66: the bundled hc core.

    def bundled(self, name, build_id, helper=b"signed core", manifest_hash=None, manifest=True):
        app = self.make(name, build_id=build_id)
        helpers = app / "Contents" / "Helpers"
        if helper is not None:
            helpers.mkdir()
            (helpers / "herdr-core").write_bytes(helper)
            (helpers / "herdr-core").chmod(0o755)
        if manifest:
            record = {"version": "0.1.16", "protocolGeneration": 1, "sourceSHA256": "5" * 64,
                      "executableSHA256": manifest_hash or hashlib.sha256(helper or b"").hexdigest()}
            (app / "Contents" / "Resources" / "hc-pin.json").write_text(json.dumps(record), encoding="utf-8")
        return app

    def codesign_env(self, rc=0):
        tool = self.bin / "fake-codesign"
        log = Path(self.tmp.name) / "codesign.log"
        tool.write_text("#!/bin/sh\nprintf '%%s\\n' \"$*\" >> \"%s\"\nexit %d\n" % (log, rc), encoding="utf-8")
        tool.chmod(0o755)
        # TemporaryDirectory cannot remove a 0555 folder; registered after it, so this runs first.
        self.addCleanup(lambda: subprocess.run(["chmod", "-R", "u+w", self.tmp.name]))
        return self.env(C11_CODESIGN=str(tool)), log

    def test_bundled_core_is_locked_and_the_next_install_replaces_it(self):
        env, log = self.codesign_env()
        self.install(self.bundled("A.app", "A", helper=b"core A"), env=env)
        helpers = self.dest / "Contents" / "Helpers"
        self.assertEqual(stat.S_IMODE(helpers.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE((helpers / "herdr-core").stat().st_mode), 0o555)
        self.assertFalse(os.access(helpers, os.W_OK), "hc's update refuses when it cannot write here (S1)")
        self.assertIn("--verify --deep --strict", log.read_text(encoding="utf-8"))
        self.install(self.bundled("B.app", "B", helper=b"core B"), env=env)
        self.assertEqual((self.dest / "Contents" / "Helpers" / "herdr-core").read_bytes(), b"core B")
        self.assertEqual(stat.S_IMODE((self.dest / "Contents" / "Helpers").stat().st_mode), 0o555)
        leftovers = [p.name for p in self.dest.parent.iterdir() if p.name != "c11.app"]
        self.assertEqual(leftovers, [], "the locked previous app was removed")
        self.assertEqual(snapshot(self.hc.parent.parent), self.hc_snapshot, "the external pin is never written")

    def signed_cat(self):
        """An ad hoc signed copy of /bin/cat: a real Mach-O helper that lives while
        its stdin is open and ends by itself when the test closes it."""
        path = Path(self.tmp.name) / "cat-helper"
        shutil.copyfile("/bin/cat", path)
        path.chmod(0o755)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return path.read_bytes()

    def run_live_core(self, helper):
        """Runs the installed helper's file the way a live core would keep it in use,
        but never as a process that looks like one: it runs from a hard link named
        c11-test-core-<rand> outside any bundle, so name-based tools never match it
        and Gatekeeper never assesses it as an app's code. It ends when the test
        closes its stdin, at cleanup or after 20 s at most; nothing is signalled."""
        run = Path(self.tmp.name) / "run"
        run.mkdir(exist_ok=True)
        link = run / ("c11-test-core-%s" % os.urandom(3).hex())
        os.link(helper, link)
        live = subprocess.Popen([str(link)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        cap = threading.Timer(20, live.stdin.close)
        cap.daemon = True
        cap.start()
        def stop():
            cap.cancel()
            if not live.stdin.closed:
                live.stdin.close()
            live.wait(timeout=10)
        self.addCleanup(stop)
        return live, link, stop

    def retained_entries(self, root, inode):
        return [entry for entry in (root.iterdir() if root.exists() else [])
                if not entry.name.startswith("removed.")
                and (entry / "Contents" / "Helpers" / "herdr-core").exists()
                and (entry / "Contents" / "Helpers" / "herdr-core").stat().st_ino == inode]

    def test_an_update_keeps_the_helper_a_live_core_still_runs_until_it_ends(self):
        # sol on #118: deleting the old app took the file a running core executes,
        # so the new app could not verify that core. The update must keep that file,
        # inside the old app renamed whole into the retained root.
        env, _ = self.codesign_env()
        core_a = self.signed_cat()
        self.install(self.bundled("A.app", "A", helper=core_a), env=env)
        live, link, stop = self.run_live_core(self.dest / "Contents" / "Helpers" / "herdr-core")
        inode = link.stat().st_ino
        # The same helper bytes in the next build: a hash match does not keep the file alive.
        self.install(self.bundled("B.app", "B", helper=core_a), env=env)
        self.assertIsNone(live.poll(), "the live helper is still running")
        root = self.dest.parent / ".c11.app-helpers"
        kept = self.retained_entries(root, inode)
        self.assertEqual(len(kept), 1, "the file the live core runs is kept in exactly one retained app")
        entry = kept[0]
        self.assertNotEqual(entry.suffix, ".app", "a retained app is not an app to LaunchServices")
        helper = entry / "Contents" / "Helpers" / "herdr-core"
        self.assertEqual(hashlib.sha256(helper.read_bytes()).hexdigest(), hashlib.sha256(core_a).hexdigest())
        record = json.loads((entry / "Contents" / "Resources" / "hc-pin.json").read_text(encoding="utf-8"))
        self.assertEqual(record["executableSHA256"], hashlib.sha256(core_a).hexdigest(), "its sealed manifest stays with it")
        self.assertEqual(stat.S_IMODE((entry / "Contents" / "Helpers").stat().st_mode), 0o555, "still unwritable (S1)")
        self.assertEqual((self.dest / "Contents" / "Helpers" / "herdr-core").read_bytes(), core_a, "B is installed")
        self.assertNotEqual((self.dest / "Contents" / "Helpers" / "herdr-core").stat().st_ino, inode, "B is its own file")
        self.assertEqual(sorted(p.name for p in self.dest.parent.iterdir()), [".c11.app-helpers", "c11.app"])
        # Another update while it runs keeps it; B, whose helper nothing runs, is not kept.
        self.install(self.bundled("C.app", "C", helper=b"core C"), env=env)
        self.assertIsNone(live.poll(), "the live helper is still running")
        self.assertEqual([p.name for p in root.iterdir() if not p.name.startswith("removed.")], [entry.name])
        self.assertEqual(self.retained_entries(root, inode), [entry])
        stop()
        # Once it has ended, the next install prunes it, unless macOS refuses to
        # change that bundle yet: then the install still succeeds, says so, and a
        # later one prunes it.
        done = self.install(self.bundled("D.app", "D", helper=b"core D"), env=env)
        left = [p.name for p in root.iterdir()] if root.exists() else []
        if entry.name in left:
            self.assertRegex(done.stderr, "macOS refused to remove .*/%s " % re.escape(entry.name))
        self.assertEqual(sorted(p.name for p in self.dest.parent.iterdir() if p.name != ".c11.app-helpers"), ["c11.app"])
        self.assertEqual((self.dest / "Contents" / "Helpers" / "herdr-core").read_bytes(), b"core D")
        self.assertEqual(snapshot(self.hc.parent.parent), self.hc_snapshot, "the external pin is never written")

    def test_a_helper_that_is_not_its_manifests_file_is_refused_before_anything_changes(self):
        env, _ = self.codesign_env()
        self.install(self.bundled("A.app", "A", helper=b"core A"), env=env)
        cases = {
            "hash": self.bundled("bad.app", "X", helper=b"core X", manifest_hash="0" * 64),
            "no manifest": self.bundled("half.app", "Y", manifest=False),
            "no helper": self.bundled("half2.app", "Z", helper=None, manifest_hash="1" * 64),
        }
        for name, app in cases.items():
            with self.subTest(name):
                proc = self.install(app, env=env, check=False)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual((self.dest / "Contents" / "Helpers" / "herdr-core").read_bytes(), b"core A")

    def test_an_app_whose_signature_does_not_verify_is_refused(self):
        env, _ = self.codesign_env(rc=1)
        proc = self.install(self.bundled("A.app", "A"), env=env, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("signature does not verify", proc.stderr)
        self.assertFalse(self.dest.exists())

    def test_an_app_without_a_bundled_core_still_installs(self):
        env, log = self.codesign_env(rc=1)
        self.install(self.make("A.app", build_id="A"), env=env)
        self.assertFalse((self.dest / "Contents" / "Helpers").exists())
        self.assertFalse(log.exists(), "the transition's external-pin build is not signature-checked here")


if __name__ == "__main__":
    unittest.main()
