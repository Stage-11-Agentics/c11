#!/usr/bin/env python3
"""tools/c11-guest/claude-env.sh: the token reaches the guest command's environment by ssh
stdin, never argv, and verify-clean finds a planted slice.

A stand-in `ssh` on PATH logs its argv and runs the remote command line with /bin/zsh -c on
this machine, with HOME set to a throwaway "guest home". A stand-in tart answers `ip`. The
token is a random fake in the shape of a setup token.
"""
import hashlib
import json
import os
import pathlib
import secrets
import string
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
TOOL = REPO / "tools" / "c11-guest" / "claude-env.sh"

FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
with open(os.environ["FAKE_SSH_ARGV"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
env = {"HOME": os.environ["FAKE_GUEST_HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
remote = sys.argv[-1]
# The Aqua route's session hop needs root; the stand-in drops only that prefix and runs the
# rest of the real chain (env -i, then the reader), so stdin must still carry the token through.
hop = '/usr/bin/sudo -n /bin/launchctl asuser "$(id -u)" /usr/bin/sudo -n -u "$(id -un)" '
if remote.startswith(hop):
    remote = remote[len(hop):]
sys.exit(subprocess.run(["/bin/zsh", "-c", remote], env=env).returncode)
'''
FAKE_TART = "#!/bin/sh\n[ \"$1\" = ip ] && echo 127.0.0.1\n"


def fake_token():
    alphabet = string.ascii_letters + string.digits
    return "sk-ant-oat01-" + "".join(secrets.choice(alphabet) for _ in range(95))


class ClaudeEnvInjection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)  # runs last, after any permission restores
        t = pathlib.Path(self.tmp.name)
        self.bin = t / "bin"; self.bin.mkdir()
        (self.bin / "ssh").write_text(FAKE_SSH); (self.bin / "ssh").chmod(0o755)
        (self.bin / "tart").write_text(FAKE_TART); (self.bin / "tart").chmod(0o755)
        self.host_home = t / "host"; self.host_home.mkdir()
        self.guest_home = t / "guest"; self.guest_home.mkdir()
        self.evidence = t / "evidence"; self.evidence.mkdir()
        self.argv_log = t / "ssh-argv.jsonl"; self.argv_log.write_text("")
        self.token = fake_token()
        self.slice = self.token[13:25]
        self.token_file = t / "bravo.token"
        self.token_file.write_text("# Bravo setup token for c11 guests\n" + self.token + "\n")

    def run_tool(self, *args, token_file=None):
        env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.host_home),
               "C11_GUEST": "unit", "TART": str(self.bin / "tart"),
               "C11_CLAUDE_TOKEN_FILE": str(token_file or self.token_file),
               "FAKE_SSH_ARGV": str(self.argv_log), "FAKE_GUEST_HOME": str(self.guest_home),
               "EVIDENCE_DIR": str(self.evidence),
               "C11_VERIFY_GUEST_ROOTS": str(self.guest_home), "C11_VERIFY_GUEST_HOME": str(self.guest_home),
               "C11_VERIFY_GUEST_SUDO": "0"}
        if "C11_VERIFY_GUEST_ROOTS_OVERRIDE" in os.environ:
            env["C11_VERIFY_GUEST_ROOTS"] = os.environ["C11_VERIFY_GUEST_ROOTS_OVERRIDE"]
        return subprocess.run(["/bin/bash", str(TOOL), *args], env=env, capture_output=True, text=True, timeout=60)

    def ssh_argv(self):
        return self.argv_log.read_text()

    def assert_never_exposed(self, result):
        for where, text in (("ssh argv", self.ssh_argv()), ("stdout", result.stdout), ("stderr", result.stderr)):
            self.assertNotIn(self.slice, text, f"token slice in {where}")

    def test_sh_exports_the_token_from_stdin(self):
        snippet = ('print -r -- "sha=$(print -rn -- "$CLAUDE_CODE_OAUTH_TOKEN" | shasum -a 256 | cut -c1-64)"\n'
                   'if read -r -t 1 extra; then print -r -- stdin=more; else print -r -- stdin=empty; fi\n'
                   'print -r -- "autoupdater=$DISABLE_AUTOUPDATER"')
        r = self.run_tool("sh", snippet)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sha=" + hashlib.sha256(self.token.encode()).hexdigest(), r.stdout)
        self.assertIn("stdin=empty", r.stdout)
        self.assertIn("autoupdater=1", r.stdout)
        self.assertEqual(len(self.ssh_argv().splitlines()), 1)
        self.assert_never_exposed(r)

    # A child process (not the shell that read it) must find the token in its environment.
    CHILD = ("/usr/bin/python3 -c 'import hashlib, os; t = os.environ.get(\"CLAUDE_CODE_OAUTH_TOKEN\", \"\"); "
             "print(\"child_sha=\" + hashlib.sha256(t.encode()).hexdigest())'")

    def test_child_process_receives_the_token(self):
        r = self.run_tool("sh", self.CHILD)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("child_sha=" + hashlib.sha256(self.token.encode()).hexdigest(), r.stdout)
        self.assert_never_exposed(r)

    def test_aqua_route_child_receives_the_token(self):
        r = self.run_tool("aqua-sh", self.CHILD)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("child_sha=" + hashlib.sha256(self.token.encode()).hexdigest(), r.stdout)
        self.assertIn("launchctl asuser", self.ssh_argv())
        self.assert_never_exposed(r)

    def test_guest_writes_no_file_holding_the_token(self):
        r = self.run_tool("sh", 'print -r -- ran')
        self.assertEqual(r.returncode, 0, r.stderr)
        hits = [p for p in self.guest_home.rglob("*") if p.is_file() and self.slice in p.read_text(errors="ignore")]
        self.assertEqual(hits, [])

    def test_a_file_with_no_setup_token_is_refused_before_ssh(self):
        bad = pathlib.Path(self.tmp.name) / "bad.token"
        bad.write_text("# nothing here\nsk-ant-api03-notasetuptoken\n")
        r = self.run_tool("sh", "true", token_file=bad)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not a Claude setup token", r.stderr)
        self.assertEqual(self.ssh_argv(), "")

    def test_verify_clean_passes_on_a_clean_run(self):
        r = self.run_tool("verify-clean")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("guest=absent", r.stdout)
        self.assertIn("host=absent", r.stdout)
        self.assertIn("verify_clean=pass", r.stdout)
        self.assert_never_exposed(r)
        self.assertFalse((self.guest_home / ".c11-verify-canary").exists())

    def test_verify_clean_finds_a_slice_in_the_guest(self):
        (self.guest_home / "leak.log").write_text("x" + self.slice + "y\n")
        r = self.run_tool("verify-clean")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("guest=FOUND", r.stdout)
        self.assertIn("leak.log", r.stdout)
        self.assert_never_exposed(r)

    def test_verify_clean_finds_a_slice_on_the_host(self):
        (self.evidence / "row").mkdir()
        (self.evidence / "row" / "shot.txt").write_text(self.token + "\n")
        extra = pathlib.Path(self.tmp.name) / "transcripts"; extra.mkdir()
        (extra / "t.jsonl").write_text(json.dumps({"x": self.slice}) + "\n")
        r = self.run_tool("verify-clean", str(extra))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("host=FOUND", r.stdout)
        self.assertIn("shot.txt", r.stdout)
        self.assertIn("t.jsonl", r.stdout)


    def unreadable(self, path):
        path.write_text(self.slice + "\n")
        path.chmod(0)
        self.addCleanup(path.chmod, 0o600)

    def test_verify_clean_errors_on_an_unreadable_guest_file(self):
        self.unreadable(self.guest_home / "root-owned.log")
        r = self.run_tool("verify-clean")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("guest=ERROR", r.stdout)
        self.assertIn("verify_clean=FAIL", r.stdout)
        self.assert_never_exposed(r)

    def test_verify_clean_errors_on_an_unreadable_host_file(self):
        self.unreadable(self.evidence / "root-owned.log")
        r = self.run_tool("verify-clean")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("host=ERROR", r.stdout)
        self.assertIn("verify_clean=FAIL", r.stdout)
        self.assert_never_exposed(r)

    def test_verify_clean_errors_on_a_missing_named_root(self):
        r = self.run_tool("verify-clean", str(pathlib.Path(self.tmp.name) / "no-such-transcripts"))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("host=ERROR", r.stdout)
        self.assertIn("missing root:", r.stdout)

    def test_verify_clean_errors_on_a_missing_guest_root(self):
        env_roots = f"{self.guest_home} {self.guest_home}/not-there"
        os.environ["C11_VERIFY_GUEST_ROOTS_OVERRIDE"] = env_roots
        try:
            r = self.run_tool("verify-clean")
        finally:
            del os.environ["C11_VERIFY_GUEST_ROOTS_OVERRIDE"]
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("guest=ERROR", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
