#!/usr/bin/env python3
"""Fake interactive agent for proof_turnless_doorbell.py (C11-555). Not a test.

Runs in the foreground of a c11 terminal panel, holds the tty in raw mode, and
draws a Claude Code style empty composer (a rule, `❯` plus a no-break space,
a rule). It registers through the real hook CLI: `claude-hook session-start`
with `C11_AGENT_INTERACTIVE_PID` set to its own pid, which c11 records as an
attach with no turn edge.

`--mode turnless` never reports anything after that, like a harness that emits
no turn edges. `--mode control` reports `claude-hook prompt-submit` on every
Return, so c11's journal shows a turn in progress from then on.

Every submitted line is appended to `--log` as one JSON object.
"""

import argparse
import json
import os
import select
import subprocess
import sys
import termios
import time
import tty
import uuid

RULE = "─" * 40


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["turnless", "control"], required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--max-seconds", type=float, default=720)
    args = parser.parse_args()

    session = str(uuid.uuid4())
    hook_env = dict(os.environ, C11_AGENT_INTERACTIVE_PID=str(os.getpid()))

    def log(record: dict) -> None:
        record["t"] = time.time()
        with open(args.log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record) + "\n")

    def hook(name: str, payload: dict) -> int:
        result = subprocess.run(
            [args.cli, "claude-hook", name],
            input=json.dumps(payload).encode(),
            env=hook_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        return result.returncode

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    buffer = ""

    def draw() -> None:
        out = "\x1b[H\x1b[2J" + RULE + "\r\n" + "❯ " + buffer + "\r\n" + RULE
        out += f"\x1b[2;{3 + len(buffer)}H"
        os.write(sys.stdout.fileno(), out.encode())

    try:
        tty.setraw(fd)
        draw()
        status = hook("session-start", {
            "session_id": session,
            "cwd": os.getcwd(),
            "source": "startup",
            "hook_event_name": "SessionStart",
        })
        log({"event": "ready", "mode": args.mode, "pid": os.getpid(), "session": session, "hook": status})
        deadline = time.time() + args.max_seconds
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if not ready:
                continue
            data = os.read(fd, 4096)
            if not data:
                break
            text = data.decode("utf-8", errors="replace")
            index = 0
            while index < len(text):
                char = text[index]
                index += 1
                if char == "\x1b":
                    # Skip one escape sequence (bracketed paste markers, keys).
                    while index < len(text) and not text[index].isalpha() and text[index] != "~":
                        index += 1
                    index += 1
                    continue
                if char in ("\r", "\n"):
                    line = buffer
                    buffer = ""
                    draw()
                    record = {"event": "submit", "line": line}
                    if args.mode == "control":
                        record["prompt_submit_hook"] = hook("prompt-submit", {
                            "session_id": session,
                            "cwd": os.getcwd(),
                            "prompt": line,
                            "hook_event_name": "UserPromptSubmit",
                        })
                    log(record)
                    continue
                if char == "\x03":
                    log({"event": "interrupted"})
                    return 0
                if char == "\x7f":
                    buffer = buffer[:-1]
                elif char >= " ":
                    buffer += char
                draw()
        log({"event": "timeout"})
        return 0
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    sys.exit(main())
