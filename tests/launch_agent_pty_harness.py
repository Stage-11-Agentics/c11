#!/usr/bin/env python3
"""Replay a launch command through an isolated interactive zsh PTY.

The fake agent supplied by the caller writes JSON to C11_LAUNCH_AGENT_RECEIPT:
{"instruction": <argv prompt>, "file_sha256": <digest>, "file_bytes": <size>}.
This verifies the executable argv/file seam. It does not emulate Ghostty.
"""

import argparse
import errno
import hashlib
import json
import os
import select
import shlex
import signal
import subprocess
import tempfile
import termios
import time
from pathlib import Path


PROMPT = b"C11_PTY_READY> "
PASTE_ON = b"\x1b[?2004h"
PASTE_OFF = b"\x1b[?2004l"
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"


def replay(command, expected_file, submission="repaired", timeout=5.0, bracketed="on"):
    """Return one JSON-serializable observation; always reap the PTY shell."""
    expected = Path(expected_file).read_bytes()
    result = {
        "scope": "interactive zsh PTY only; no Ghostty or real agent",
        "submission": submission,
        "bracketed_requested": bracketed,
        "command_bytes": len(command.encode("utf-8")),
        "expected_sha256": hashlib.sha256(expected).hexdigest(),
        "expected_bytes": len(expected),
        "success": False,
    }
    master, slave = os.openpty()
    os.set_blocking(master, False)
    proc = None
    output = bytearray()
    deadline = time.monotonic() + min(timeout, 5.0)
    try:
        result["pc_max_canon"] = os.fpathconf(slave, "PC_MAX_CANON")
        with tempfile.TemporaryDirectory(prefix="c11-launch-pty-") as tmp:
            receipt = Path(tmp) / "receipt.json"
            env = os.environ.copy()
            # No user startup files or agent telemetry may run in this fixture.
            for key in list(env):
                if key.startswith(("C11_", "CMUX_")):
                    env.pop(key)
            env.update({
                "TERM": "xterm-256color",
                "PS1": PROMPT.decode(),
                "PROMPT": PROMPT.decode(),
                "RPS1": "",
                "RPROMPT": "",
                "ZDOTDIR": tmp,
                "C11_LAUNCH_AGENT_RECEIPT": str(receipt),
            })

            def child_setup():
                import fcntl
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            proc = subprocess.Popen(
                ["/bin/zsh", "-d", "-f", "-i"],
                stdin=slave, stdout=slave, stderr=slave, env=env,
                preexec_fn=child_setup,
            )

            def drain_until(predicate):
                while time.monotonic() < deadline:
                    if predicate():
                        return True
                    ready, _, _ = select.select([master], [], [],
                                                min(0.05, max(0, deadline - time.monotonic())))
                    if ready:
                        try:
                            chunk = os.read(master, 65536)
                        except BlockingIOError:
                            continue
                        except OSError as exc:
                            if exc.errno == errno.EIO:
                                return predicate()
                            raise
                        if not chunk:
                            return predicate()
                        output.extend(chunk)
                    if proc.poll() is not None:
                        return predicate()
                return predicate()

            if not drain_until(lambda: PROMPT in output and PASTE_ON in output):
                result["error"] = "zsh did not reach a bracketed-paste ready prompt"
                return result
            if bracketed == "off":
                before = len(output)
                os.write(master, b"unset zle_bracketed_paste\r")
                if not drain_until(lambda: PROMPT in output[before:] and
                                   PASTE_OFF in output[before:]):
                    result["error"] = "zsh did not reach paste-disabled prompt"
                    return result
            result["icanon_at_prompt"] = bool(termios.tcgetattr(slave)[3] & termios.ICANON)
            result["bracketed_paste_at_prompt"] = output.rfind(PASTE_ON) > output.rfind(PASTE_OFF)
            payload = command.encode("utf-8")
            if submission == "baseline":
                payload += b"\n"
            framed = PASTE_START + payload + PASTE_END if bracketed == "on" else payload
            offset = 0
            while offset < len(framed):
                if time.monotonic() >= deadline:
                    result["error"] = "timeout writing paste payload"
                    return result
                _, writable, _ = select.select([], [master], [], 0.05)
                if writable:
                    # Small writes let zle drain while large synthetic pastes arrive.
                    try:
                        offset += os.write(master, framed[offset:offset + 1024])
                    except BlockingIOError:
                        pass
                # Bound each drain batch so output cannot starve the deadline.
                for _ in range(8):
                    if not select.select([master], [], [], 0)[0]:
                        break
                    try:
                        output.extend(os.read(master, 65536))
                    except BlockingIOError:
                        break
            if submission == "repaired":
                # A discrete Return occurs outside the bracketed paste envelope.
                os.write(master, b"\r")

            def has_receipt():
                if not receipt.exists():
                    return False
                try:
                    json.loads(receipt.read_text())
                    return True
                except (ValueError, OSError):
                    return False

            if not drain_until(has_receipt):
                result["error"] = "timeout waiting for fake-agent receipt"
            else:
                observed = json.loads(receipt.read_text())
                result["receipt"] = observed
                result["success"] = (
                    observed.get("file_sha256") == result["expected_sha256"]
                    and observed.get("file_bytes") == len(expected)
                    and isinstance(observed.get("instruction"), str)
                )
                if not result["success"]:
                    result["error"] = "fake-agent file digest or receipt mismatch"
            return result
    except (OSError, ValueError) as exc:
        result["error"] = str(exc)
        return result
    finally:
        result["paste_mode_on_count"] = output.count(PASTE_ON)
        result["paste_mode_off_count"] = output.count(PASTE_OFF)
        result["output_tail"] = bytes(output[-1500:]).decode("utf-8", errors="replace")
        if proc is not None:
            # The shell and its fixture children belong exclusively to this group.
            try:
                foreground_group = os.tcgetpgrp(slave)
                if foreground_group > 0 and foreground_group != os.getpgrp():
                    os.killpg(foreground_group, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            # zsh may rearrange process groups when it enables job control.
            # Kill its PID as well, regardless of the group's current leader.
            proc.kill()
            # Darwin can hold a dying tty writer until the master is closed.
            # Release both descriptors before waiting, rather than deadlocking
            # cleanup behind output that this fixture is no longer consuming.
            os.close(master)
            os.close(slave)
            master = slave = None
            try:
                proc.wait(timeout=1)
                result["shell_cleanup_returncode"] = proc.returncode
            except subprocess.TimeoutExpired:
                result["success"] = False
                result["error"] = "PTY shell did not reap after SIGKILL"
        if master is not None:
            os.close(master)
        if slave is not None:
            os.close(slave)


def diagnose():
    observations = []
    with tempfile.TemporaryDirectory(prefix="c11-pty-diagnose-") as tmp:
        # Include shell-sensitive pathname characters in the fixture itself.
        root = Path(tmp) / "space ' dollar$ semi;"
        root.mkdir()
        fake = root / "fake agent.py"
        fake.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
instruction = sys.argv[1]
if instruction == "--prompt-file":
    data = pathlib.Path(sys.argv[2]).read_bytes()
else:
    data = instruction.encode("utf-8")
pathlib.Path(os.environ["C11_LAUNCH_AGENT_RECEIPT"]).write_text(json.dumps({
    "instruction": instruction, "file_sha256": hashlib.sha256(data).hexdigest(),
    "file_bytes": len(data), "argv": sys.argv[1:]}))
''')
        fake.chmod(0o700)
        for size in (500, 1300, 32768):
            prompt = root / ("synthetic-%d.txt" % size)
            prompt.write_bytes((b"synthetic '$;` text\n" * (size // 19 + 1))[:size])
            original = shlex.quote(str(fake)) + " " + shlex.quote(prompt.read_text())
            repaired = shlex.quote(str(fake)) + " --prompt-file " + shlex.quote(str(prompt))
            for bracketed in ("on", "off"):
                for mode, command in (("baseline", original), ("repaired", repaired)):
                    observation = replay(command, prompt, mode, timeout=5.0, bracketed=bracketed)
                    observation["synthetic_prompt_bytes"] = size
                    observations.append(observation)
    return {"scope": "PTY observation, not a Ghostty diagnosis", "observations": observations}


def main():
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command")
    parser.add_argument("--expected-file")
    parser.add_argument("--submission", choices=("repaired", "baseline"), default="repaired")
    parser.add_argument("--bracketed", choices=("on", "off"), default="on")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--diagnose", action="store_true")
    args = parser.parse_args()
    if args.diagnose:
        print(json.dumps(diagnose(), ensure_ascii=True))
        return 0
    if args.command is None or args.expected_file is None:
        parser.error("--command and --expected-file are required without --diagnose")
    result = replay(args.command, args.expected_file, args.submission, args.timeout, args.bracketed)
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
