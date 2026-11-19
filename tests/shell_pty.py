"""One interactive shell with the bundled c11 integration on a pty, for tests.

The shell reads only the rc file written here (no user dotfiles). It owns its
PID and nothing else. `socket=True` binds a disposable listener at the shell's
socket path, so the hooks pass their `[[ -S ]]` guard; `sink=True` replaces
`_cmux_send` with an append to a file, so every report the hooks send is
captured and nothing reaches any c11. `stubs` names integration helpers to make
inert (git, PR and watcher helpers spawn work a report test does not need).
"""
import fcntl
import os
import pty
import select
import shutil
import signal
import socket as socket_module
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_ROOT = Path(os.environ.get(
    "C11_SHELL_INTEGRATION_ROOT", str(ROOT / "Resources" / "shell-integration")))
SHELLS = ("bash", "zsh")
if os.path.exists("/bin/bash") and os.path.realpath(shutil.which("bash") or "") != "/bin/bash":
    SHELLS += ("/bin/bash",)
PROMPT = b"READY> "


def is_zsh(shell):
    return os.path.basename(shell) == "zsh"


def integration_for(shell):
    return INTEGRATION_ROOT / ("cmux-zsh-integration.zsh" if is_zsh(shell) else "cmux-bash-integration.bash")


class InteractiveShell:
    def __init__(self, shell, socket=False, sink=False, stubs=()):
        self.temp = tempfile.TemporaryDirectory(prefix="c11-shell-pty-")
        self.home = Path(self.temp.name)
        self.sink = self.home / "sent.log"
        self.listener = None
        socket_path = self.home / "c11.sock"
        if socket:
            self.listener = socket_module.socket(socket_module.AF_UNIX)
            self.listener.bind(str(socket_path))
            self.listener.listen()
        zsh = is_zsh(shell)
        lines = [
            f'export CMUX_SOCKET_PATH="{socket_path}" CMUX_TAB_ID=fixture-panel CMUX_PANEL_ID=fixture-panel',
            "unset CMUX_RESTORE_SCROLLBACK_FILE GHOSTTY_BIN_DIR",
            f'source "{integration_for(shell)}"',
        ]
        lines += [f"{name}() {{ :; }}" for name in stubs]
        if sink:
            lines.append(f"_cmux_send() {{ printf '%s\\n' \"$1\" >> \"{self.sink}\"; }}")
        lines.append("PS1='READY> '")
        (self.home / (".zshrc" if zsh else "bashrc")).write_text("\n".join(lines) + "\n")
        self.sink.touch()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("C11_", "CMUX_", "GHOSTTY_")) and key not in ("BASH_ENV", "TERM_PROGRAM")}
        env.update(TERM="xterm-256color", ZDOTDIR=str(self.home), HOME=str(self.home))
        args = [shutil.which(shell) or shell]
        args += ["-i"] if zsh else ["--noprofile", "--rcfile", str(self.home / "bashrc"), "-i"]
        self.master, slave = pty.openpty()
        # The pty is the shell's controlling terminal, as in a real terminal,
        # so Ctrl-C reaches it as SIGINT.
        self.process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=env, cwd=str(self.home),
                                        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.output = bytearray()

    def read_until(self, needle, start=0, timeout=5):
        deadline = time.monotonic() + timeout
        while self.output.find(needle, start) < 0:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"no {needle!r} after byte {start}: {bytes(self.output)!r}")
            ready, _, _ = select.select([self.master], [], [], remaining)
            if ready:
                try:
                    chunk = os.read(self.master, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    raise AssertionError(f"pty closed before {needle!r}: {bytes(self.output)!r}")
                self.output += chunk
        return self.output.find(needle, start)

    def next_prompt(self, timeout=5):
        """Wait for the prompt drawn after everything read so far."""
        return self.read_until(PROMPT, len(self.output), timeout)

    def write(self, data):
        os.write(self.master, data)

    def type(self, line):
        self.write(line.encode() + b"\n")

    def sent(self, prefix=""):
        return [line for line in self.sink.read_text().splitlines() if line.startswith(prefix) and line]

    def wait_sent(self, count, prefix="", timeout=5):
        """The hooks send from background jobs: wait for `count` captured lines
        that start with `prefix`, then a moment more for any stray extra."""
        deadline = time.monotonic() + timeout
        while len(self.sent(prefix)) < count and time.monotonic() < deadline:
            time.sleep(0.02)
        time.sleep(0.2)
        return self.sent(prefix)

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGKILL)  # Only the PID this fixture started.
            self.process.wait(timeout=3)
        finally:
            os.close(self.master)
            if self.listener:
                self.listener.close()
            self.temp.cleanup()
