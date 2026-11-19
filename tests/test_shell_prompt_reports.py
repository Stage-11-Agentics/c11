#!/usr/bin/env python3
"""C11H-272: every shell prompt reports, so an empty Return reaches the app.

A resume into the live shell an agent left waits for an empty prompt: after a
key at the prompt, the operator presses Return on an empty line and asks again.
That prompt must be reported. Each case runs a real interactive shell (zsh,
bash 5, /bin/bash 3.2) with the bundled integration on a pty, a disposable
listener at its socket path and a captured `_cmux_send`, and checks the reports
one prompt sends: one write, the prompt report carrying the agent kick.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import shutil
import subprocess
import unittest

from shell_pty import SHELLS, InteractiveShell, is_zsh

# Watchers and probes that spawn work a report test does not need.
STUBS = ("_cmux_report_tty_once", "_cmux_ports_kick", "_cmux_report_git_branch_for_path",
         "_cmux_report_pr_for_path", "_cmux_start_pr_poll_loop", "_cmux_stop_pr_poll_loop",
         "_cmux_start_git_head_watch", "_cmux_stop_git_head_watch")
PROMPT_REPORT = "report_shell_state prompt --tab=fixture-panel --panel=fixture-panel --agent-kick=1"
RUNNING_REPORT = "report_shell_state running --tab=fixture-panel --panel=fixture-panel"
STATE = "report_shell_state "


def has_preexec(shell):
    """The bash integration's preexec rides PS0, which bash has from 4.4."""
    if is_zsh(shell):
        return True
    major, minor = subprocess.run([shutil.which(shell) or shell, "--norc", "-c",
                                   'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"'],
                                  capture_output=True, text=True, check=True).stdout.split()
    return (int(major), int(minor)) >= (4, 4)


class ShellPromptReportTests(unittest.TestCase):
    def shell(self, name):
        item = InteractiveShell(name, socket=True, sink=True, stubs=STUBS)
        self.addCleanup(item.close)
        item.read_until(b"READY> ")
        return item

    def test_an_empty_return_reports_a_new_prompt(self):
        for name in SHELLS:
            with self.subTest(shell=name):
                item = self.shell(name)
                self.assertEqual(item.wait_sent(1, STATE), [PROMPT_REPORT], f"{name}: the first prompt")
                item.write(b"\r")
                item.next_prompt()
                self.assertEqual(item.wait_sent(2, STATE), [PROMPT_REPORT] * 2,
                                 f"{name}: an empty Return must report its prompt")
                item.write(b"\r")
                item.next_prompt()
                self.assertEqual(item.wait_sent(3, STATE), [PROMPT_REPORT] * 3, f"{name}: and again")

    def test_a_command_reports_running_then_its_prompt_and_sends_no_separate_kick(self):
        for name in SHELLS:
            with self.subTest(shell=name):
                item = self.shell(name)
                item.wait_sent(1, STATE)
                item.type(":")
                item.next_prompt()
                preexec = has_preexec(name)
                expected = [PROMPT_REPORT] + ([RUNNING_REPORT] if preexec else []) + [PROMPT_REPORT]
                self.assertEqual(item.wait_sent(len(expected), STATE), expected, name)
                # The prompt's kick rides its report; only preexec kicks on its own.
                self.assertEqual(len(item.sent("agent_kick")), 1 if preexec else 0,
                                 f"{name}: kicks: {item.sent()}")

    def test_ctrl_c_at_the_prompt_reports_a_new_prompt(self):
        for name in SHELLS:
            with self.subTest(shell=name):
                item = self.shell(name)
                item.wait_sent(1, STATE)
                item.write(b"half typed")
                item.read_until(b"half typed")
                item.write(b"\x03")
                item.next_prompt()
                self.assertEqual(item.wait_sent(2, STATE), [PROMPT_REPORT] * 2,
                                 f"{name}: Ctrl-C leaves an empty prompt and reports it")


if __name__ == "__main__":
    for shell in SHELLS:
        if not shutil.which(shell):
            raise SystemExit(f"Required fixture shell is unavailable: {shell}")
    unittest.main(verbosity=2)
