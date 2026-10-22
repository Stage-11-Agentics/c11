#!/usr/bin/env python3
"""Resources/bin/codex with the opt-in native mail route (C11-470).

Runs the real wrapper against a fake c11 CLI and a fake codex that records
its argv, in a pty so the launch counts as interactive. Proves the setting-off
launch is byte-identical to a launch without the setting, that the relay's
socket adds exactly `--remote unix://<socket>`, and that every way the relay
can be unavailable launches Codex unchanged.
Usage: python3 tests/test_codex_wrapper_native_mail.py
"""
from __future__ import annotations

import json
import os
import pty
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "codex"

# The fake c11: `ping` and lifecycle calls succeed; `codex-mailbox-proxy`
# follows FAKE_PROXY (listen = publish a socket and serve until killed).
FAKE_C11 = r'''#!/usr/bin/env python3
import os, socket, sys, time, json
args = sys.argv[1:]
while args and args[0] == "--socket":
    args = args[2:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
if args[:1] == ["codex-mailbox-proxy"]:
    mode = os.environ.get("FAKE_PROXY", "listen")
    listen = args[args.index("--listen") + 1]
    if mode == "fail":
        sys.exit(3)
    if mode == "hang":
        time.sleep(30); sys.exit(0)
    s = socket.socket(socket.AF_UNIX); s.bind(listen + ".tmp"); s.listen(1); os.rename(listen + ".tmp", listen)
    time.sleep(30)
'''

FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_ARGV"], "w") as f:
    json.dump(sys.argv[1:], f)
'''


class WrapperTests(unittest.TestCase):
    def run_wrapper(self, argv, *, native=None, proxy="listen", wrapper=WRAPPER):
        with tempfile.TemporaryDirectory(prefix="c11-470-wrap-", dir="/tmp") as td:
            tmp = Path(td)
            bundle = tmp / "bundle"; real = tmp / "real"
            bundle.mkdir(); real.mkdir()
            shutil.copy2(wrapper, bundle / "codex"); (bundle / "codex").chmod(0o755)
            (bundle / "c11").write_text(FAKE_C11); (bundle / "c11").chmod(0o755)
            (real / "codex").write_text(FAKE_CODEX); (real / "codex").chmod(0o755)
            sock = tmp / "app.sock"
            server = socket.socket(socket.AF_UNIX); server.bind(str(sock)); server.listen(1)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
            env.update(PATH=f"{bundle}:{real}:/usr/bin:/bin", HOME=str(tmp), CMUX_SURFACE_ID="11111111-2222-3333-4444-555555555555",
                       CMUX_SOCKET_PATH=str(sock), FAKE_LOG=str(tmp / "c11.log"), FAKE_ARGV=str(tmp / "argv.json"),
                       FAKE_PROXY=proxy)
            if native is not None:
                env["C11_CODEX_NATIVE_MAIL"] = native
            started = time.monotonic()
            pid, fd = pty.fork()
            if pid == 0:
                os.execve(str(bundle / "codex"), [str(bundle / "codex"), *argv], env)
            out = b""
            while True:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            os.waitpid(pid, 0)
            elapsed = time.monotonic() - started
            server.close()
            calls = [[a.replace(str(tmp), "<tmp>") for a in json.loads(line)] for line in (tmp / "c11.log").read_text().splitlines()] if (tmp / "c11.log").exists() else []
            # Each run has its own temporary bundle path; compare everything else.
            launched = [a.replace(str(tmp), "<tmp>") for a in json.loads((tmp / "argv.json").read_text())]
            # The relay is a child of the Codex process; stop any fake left serving.
            subprocess.run(["/usr/bin/pkill", "-f", str(bundle / "c11")], check=False)
            proxy_dir = Path(f"/tmp/c11-{os.getuid()}")
            return launched, calls, elapsed, proxy_dir

    def test_setting_off_is_byte_identical_to_no_setting(self):
        for argv in ([], ["resume", "01a162f5-08ef-75a0-9f33-75526786ad94"], ["--no-daemon"], ["fix the bug"]):
            unset, unset_calls, _, _ = self.run_wrapper(argv)
            off, off_calls, _, _ = self.run_wrapper(argv, native="0")
            self.assertEqual(unset, off)
            self.assertNotIn("--remote", off)
            self.assertFalse(any(c[:1] == ["codex-mailbox-proxy"] for c in unset_calls + off_calls))

    @unittest.skipUnless(os.environ.get("C11_MAIN_CODEX_WRAPPER"), "set C11_MAIN_CODEX_WRAPPER to origin/main's Resources/bin/codex")
    def test_setting_off_matches_main_wrapper(self):
        main = Path(os.environ["C11_MAIN_CODEX_WRAPPER"])
        for argv in ([], ["resume", "01a162f5-08ef-75a0-9f33-75526786ad94"], ["fix the bug"]):
            for native in (None, "0"):
                new, new_calls, _, _ = self.run_wrapper(argv, native=native)
                old, old_calls, _, _ = self.run_wrapper(argv, wrapper=main)
                self.assertEqual(new, old)
                # set-agent and agent-hook run in the background; their order varies.
                self.assertEqual(sorted(map(json.dumps, new_calls)), sorted(map(json.dumps, old_calls)))

    def test_setting_on_adds_only_the_remote_flag(self):
        base, _, _, _ = self.run_wrapper(["resume", "01a162f5-08ef-75a0-9f33-75526786ad94"])
        on, calls, _, proxy_dir = self.run_wrapper(["resume", "01a162f5-08ef-75a0-9f33-75526786ad94"], native="1")
        index = on.index("--remote")
        self.assertEqual(on[:index] + on[index + 2:], base)
        self.assertRegex(on[index + 1], r"^unix:///tmp/c11-%d/codex-\d+\.sock$" % os.getuid())
        proxy = next(c for c in calls if c[:1] == ["codex-mailbox-proxy"])
        self.assertEqual(proxy[proxy.index("--listen") + 1], on[index + 1][len("unix://"):])
        self.assertEqual(os.stat(proxy_dir).st_mode & 0o777, 0o700)

    def test_operator_transport_choices_skip_the_relay(self):
        for argv in (["--no-daemon"], ["--remote", "ws://127.0.0.1:9"], ["--remote=unix://"], ["agents"], ["queue", "--thread", "x", "--message", "y"]):
            launched, calls, _, _ = self.run_wrapper(argv, native="1")
            self.assertFalse(any(c[:1] == ["codex-mailbox-proxy"] for c in calls), argv)
            self.assertEqual(launched.count("--remote"), argv.count("--remote") + 0, argv)

    def test_explicit_notify_keeps_the_default_transport(self):
        # Codex runs no notify program under --remote, so an operator override keeps the default transport.
        for argv in (["-c", 'notify=["/tmp/review-custom-notify"]'], ["--config", "notify = []"],
                     ['--config=notify=["/tmp/n"]'], ["-cnotify=[]"], ["resume", "--last", "-c", "notify=[]"]):
            base, _, _, _ = self.run_wrapper(argv)
            launched, calls, _, _ = self.run_wrapper(argv, native="1")
            self.assertEqual(launched, base, argv)
            self.assertNotIn("--remote", launched, argv)
            self.assertFalse(any(c[:1] == ["codex-mailbox-proxy"] for c in calls), argv)
        launched, _, _, _ = self.run_wrapper(["-c", 'model="o3"'], native="1")
        self.assertIn("--remote", launched)

    def test_retired_proxy_remote_starts_a_fresh_relay(self):
        session = "01a162f5-08ef-75a0-9f33-75526786ad94"
        retired = "unix:///tmp/c11-%d/codex-99999.sock" % os.getuid()
        base, _, _, _ = self.run_wrapper(["resume", session])
        for argv in (["--remote", retired, "resume", session], ["--remote=" + retired, "resume", session]):
            on, calls, _, _ = self.run_wrapper(argv, native="1")
            self.assertNotIn(retired, on, argv)
            index = on.index("--remote")
            self.assertEqual(on[:index] + on[index + 2:], base, argv)
            self.assertRegex(on[index + 1], r"^unix:///tmp/c11-%d/codex-\d+\.sock$" % os.getuid())
            proxy = next(c for c in calls if c[:1] == ["codex-mailbox-proxy"])
            self.assertEqual(proxy[proxy.index("--listen") + 1], on[index + 1][len("unix://"):])
            # The lifecycle claim sees the resume id, as for a plain `codex resume <id>`.
            self.assertTrue(any(session in " ".join(c) for c in calls if c[:1] != ["codex-mailbox-proxy"]), calls)
            off, _, _, _ = self.run_wrapper(argv)
            self.assertEqual(off, base, argv)

    def test_operator_remote_is_unchanged(self):
        for argv in (["--remote", "ws://127.0.0.1:9", "resume", "--last"], ["--remote", "unix:///tmp/elsewhere.sock"]):
            for native in (None, "1"):
                launched, calls, _, _ = self.run_wrapper(argv, native=native)
                self.assertEqual(launched.count("--remote"), 1, (argv, native))
                self.assertEqual(launched[launched.index("--remote") + 1], argv[1])
                self.assertFalse(any(c[:1] == ["codex-mailbox-proxy"] for c in calls), (argv, native))

    def test_relay_failure_launches_codex_unchanged(self):
        base, _, _, _ = self.run_wrapper([])
        for mode in ("fail", "hang"):
            launched, _, elapsed, _ = self.run_wrapper([], native="1", proxy=mode)
            self.assertEqual(launched, base, mode)
            self.assertLess(elapsed, 6, mode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
