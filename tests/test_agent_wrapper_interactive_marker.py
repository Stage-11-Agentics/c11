#!/usr/bin/env python3
"""
C11_AGENT_INTERACTIVE_PID at the real-binary boundary, for every agent wrapper.

c11 pushes mailbox messages only to a tab whose lifecycle reports carry this
marker, so it must be set exactly when the launch is an interactive agent that
reads its terminal: stdin and stdout are TTYs and no print/headless/background
mode is requested. It must equal the agent's own PID (the wrapper execs the
real binary), and an inherited value must never leak through any exec path.
"""

from __future__ import annotations

import os
import pty
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "Resources" / "bin"
SURFACE = "6F0C3D2A-1B2C-4D5E-8F90-0123456789AB"
INHERITED = "99999"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run(wrapper: str, argv: list[str], *, tty_stdout: bool, in_c11: bool = True) -> tuple[str, str]:
    """Returns (marker seen by the real binary, the real binary's PID)."""
    with tempfile.TemporaryDirectory(prefix="c11-marker-") as td:
        tmp = Path(td)
        wrapper_dir, real_dir = tmp / "wrapper-bin", tmp / "real-bin"
        wrapper_dir.mkdir()
        real_dir.mkdir()
        shutil.copy2(BIN / wrapper, wrapper_dir / wrapper)
        (wrapper_dir / wrapper).chmod(0o755)
        if wrapper == "pi":
            shutil.copy2(BIN / "pi-lifecycle.ts", wrapper_dir / "pi-lifecycle.ts")
        log = tmp / "real.log"
        notify_log = tmp / "notify.log"
        make_executable(
            real_dir / wrapper,
            '#!/usr/bin/env bash\nprintf "%s %s\\n" "${C11_AGENT_INTERACTIVE_PID-__UNSET__}" "$$" > "$FAKE_LOG"\n'
            'printf "%s\\n" "$@" > "$FAKE_LOG.args"\n',
        )
        # Fake c11: answers ping, accepts everything else, and records the
        # marker it sees on a `notify` (the Codex turn-complete callback).
        make_executable(
            wrapper_dir / "c11",
            '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == notify ]] && '
            'printf "%s\\n" "${C11_AGENT_INTERACTIVE_PID-__UNSET__}" > "$FAKE_NOTIFY_LOG"; done\nexit 0\n',
        )
        sock_path = str(tmp / "c11.sock")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(sock_path)
        env = {
            "PATH": f"{wrapper_dir}:{real_dir}:/usr/bin:/bin",
            "HOME": str(tmp),
            "FAKE_LOG": str(log),
            "FAKE_NOTIFY_LOG": str(notify_log),
            "C11_AGENT_INTERACTIVE_PID": INHERITED,
            "TMPDIR": str(tmp),
        }
        if in_c11:
            env.update({
                "CMUX_SURFACE_ID": SURFACE,
                "C11_TAB_ID": SURFACE,
                "CMUX_WORKSPACE_ID": SURFACE,
                "CMUX_SOCKET_PATH": sock_path,
            })
        master, slave = pty.openpty()
        # Files, not pipes: a wrapper's disowned watcher (Grok's session
        # follower) may outlive the agent, and must not hold the harness open.
        out_path, err_path = tmp / "stdout", tmp / "stderr"
        try:
            with open(out_path, "w") as out_file, open(err_path, "w") as err_file:
                proc = subprocess.Popen(
                    [str(wrapper_dir / wrapper), *argv],
                    cwd=tmp,
                    env=env,
                    stdin=slave,
                    stdout=slave if tty_stdout else out_file,
                    stderr=err_file,
                )
                returncode = proc.wait(timeout=20)
        finally:
            os.close(slave)
            os.close(master)
            sock.close()
        if argv[:1] == ["__c11-notify"]:
            if not notify_log.exists():
                raise AssertionError(f"{wrapper} {argv}: notify never reached c11 ({err_path.read_text()!r})")
            return notify_log.read_text().strip(), INHERITED
        if not log.exists():
            raise AssertionError(
                f"{wrapper} {argv}: real binary not reached (rc={returncode}, {err_path.read_text()!r})"
            )
        marker, pid = log.read_text().split()
        ARGS[(wrapper, tuple(argv), tty_stdout, in_c11)] = (tmp / "real.log.args").read_text().split("\n")
        return marker, pid


ARGS: dict = {}

CASES = [
    # (wrapper, argv, tty_stdout, in_c11, expect_marker)
    ("claude", ["hello"], True, True, True),
    ("claude", ["-p", "hello"], True, True, False),
    ("claude", ["--print", "hello"], True, True, False),
    ("claude", ["--bg", "hello"], True, True, False),
    ("claude", ["--background", "hello"], True, True, False),
    ("claude", ["hello"], False, True, False),          # stdout piped
    ("claude", ["agents"], True, True, False),          # early passthrough exec
    ("claude", ["hello"], True, False, False),          # outside c11
    ("claude", ["-cp", "hello"], True, True, False),    # combined short flags
    ("claude", ["-pc", "hello"], True, True, False),
    ("codex", [], True, True, True),
    ("codex", ["exec", "hi"], True, True, False),
    ("codex", [], False, True, False),
    ("codex", [], True, False, False),
    ("codex", ["e", "hi"], True, True, False),              # `exec` alias
    # The turn-complete callback is a child of the interactive Codex: it must
    # keep (and report) that Codex's marker, here the inherited value.
    ("codex", ["__c11-notify", '{"type":"agent-turn-complete"}'], True, True, True),
    ("grok", [], True, True, True),
    ("grok", ["-p", "hi"], True, True, False),
    ("grok", ["agent"], True, True, False),
    ("grok", ["--single=hi"], True, True, False),
    ("grok", ["-phi"], True, True, False),
    ("grok", ["-cp", "hi"], True, True, False),
    ("grok", ["--prompt-file=/tmp/x"], True, True, False),
    ("grok", [], False, True, False),
    ("opencode", [], True, True, True),
    ("opencode", ["run", "hi"], True, True, False),
    ("opencode", [], False, True, False),
    ("pi", [], True, True, True),
    ("pi", ["-p", "hi"], True, True, False),
    ("pi", [], False, True, False),
]


def main() -> int:
    failures = []
    for wrapper, argv, tty_stdout, in_c11, expect_marker in CASES:
        label = f"{wrapper} {' '.join(argv) or '(interactive)'} stdout={'tty' if tty_stdout else 'pipe'} in_c11={in_c11}"
        try:
            marker, pid = run(wrapper, argv, tty_stdout=tty_stdout, in_c11=in_c11)
        except Exception as error:  # noqa: BLE001
            failures.append(f"{label}: {error}")
            continue
        if expect_marker and marker != pid:
            failures.append(f"{label}: expected marker == agent pid {pid}, got {marker}")
        if not expect_marker and marker != "__UNSET__":
            failures.append(f"{label}: expected no marker, got {marker}")
        print(f"{'ok ' if not failures or not failures[-1].startswith(label) else 'FAIL'} {label}: marker={marker} pid={pid}")
    # `-cp`/`-pc` continue a conversation: the wrapper must not inject a
    # fresh --session-id (Claude rejects the pair).
    for argv in (["-cp", "hello"], ["-pc", "hello"]):
        real_argv = ARGS.get(("claude", tuple(argv), True, True), [])
        if "--session-id" in real_argv:
            failures.append(f"claude {' '.join(argv)}: --session-id injected into a continue: {real_argv}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PASS: {len(CASES)} wrapper launch modes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
