#!/usr/bin/env python3
"""C11H-272: a prompt after a dead agent resets the keyboard modes it left on.

An agent that pushes the kitty keyboard protocol (or turns on modifyOtherKeys)
and dies leaves the terminal encoding keys for it, so the surviving shell reads
`08;5u` for ctrl+l. The bundled zsh and bash integrations write the reset at
every prompt. Each case runs a real interactive shell with the integration in a
pty, runs a child that pushes kitty flags and is killed by SIGTERM, and checks
the reset reaches the terminal after the child's bytes, before the next prompt.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from shell_pty import SHELLS, InteractiveShell, integration_for, is_zsh

RESET = b"\x1b[<99u\x1b[>4m"
PUSH = b"\x1b[>15u"
# A stand-in agent: push kitty flags, say it is up, and die the way pkill ended
# the Codex seats (SIGTERM), leaving the push in place.
# The marker is assembled by printf, so the pty's echo of the typed line never matches it.
AGENT = "/bin/sh -c 'printf \"\\033[>15uAGENT-%s\\n\" UP; kill -TERM $$'"


class KeyboardModeResetTests(unittest.TestCase):
    def shell(self, name):
        item = InteractiveShell(name)
        self.addCleanup(item.close)
        return item

    def test_prompt_after_a_dead_agent_resets_kitty_and_modify_other_keys(self):
        for name in SHELLS:
            with self.subTest(shell=name):
                item = self.shell(name)
                item.read_until(b"READY> ")
                start = len(item.output)
                item.type(AGENT)
                agent_up = item.read_until(b"AGENT-UP", start)
                push = item.output.rfind(PUSH, start, agent_up)
                self.assertGreaterEqual(push, 0, f"{name}: the stand-in agent's push is missing")
                prompt = item.read_until(b"READY> ", agent_up)
                reset = item.output.find(RESET, agent_up, prompt)
                self.assertGreaterEqual(
                    reset, 0, f"{name}: no keyboard-mode reset between the dead agent and the next prompt: "
                    f"{bytes(item.output[agent_up:prompt + 7])!r}")

    def test_a_hook_whose_stdout_is_not_a_terminal_writes_nothing(self):
        for name in SHELLS:
            with self.subTest(shell=name):
                zsh = is_zsh(name)
                integration = integration_for(name)
                with tempfile.TemporaryDirectory(prefix="c11-kbd-reset-") as home:
                    script = Path(home) / "driver.sh"
                    script.write_text(
                        f'export CMUX_SOCKET_PATH="{home}/absent.sock" CMUX_TAB_ID=t CMUX_PANEL_ID=p\n'
                        f'source "{integration}"\n'
                        + ("_cmux_precmd\n" if zsh else "_cmux_prompt_command\n"))
                    env = {key: value for key, value in os.environ.items()
                           if not key.startswith(("C11_", "CMUX_", "GHOSTTY_")) and key != "BASH_ENV"}
                    env["ZDOTDIR"] = home
                    args = [shutil.which(name) or name] + (["-f"] if zsh else ["--noprofile", "--norc"])
                    result = subprocess.run(args + [str(script)], capture_output=True, env=env,
                                            stdin=subprocess.DEVNULL, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn(RESET, result.stdout)


if __name__ == "__main__":
    for shell in SHELLS:
        if not shutil.which(shell):
            raise SystemExit(f"Required fixture shell is unavailable: {shell}")
    unittest.main(verbosity=2)
