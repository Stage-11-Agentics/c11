#!/usr/bin/env python3
"""Regression: global CLI flags still parse and v1 ERROR responses fail with non-zero exit."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
LAST_SOCKET_HINT_PATH = Path("/tmp/cmux-last-socket-path")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def _merged_output(proc: subprocess.CompletedProcess[str]) -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def main() -> int:
    cli = _find_cli_binary()

    # Global --version should be handled before socket command dispatch.
    version_proc = _run([cli, "--version"])
    version_out = _merged_output(version_proc).lower()
    _must(version_proc.returncode == 0, f"--version should succeed: {version_proc.returncode} {version_out!r}")
    _must("cmux" in version_out, f"--version output should mention cmux: {version_out!r}")

    # Debug builds should auto-resolve the active debug socket via /tmp/cmux-last-socket-path
    # when CMUX_SOCKET_PATH is not set.
    hint_backup: str | None = None
    hint_had_file = LAST_SOCKET_HINT_PATH.exists()
    if hint_had_file:
        hint_backup = LAST_SOCKET_HINT_PATH.read_text(encoding="utf-8")
    try:
        LAST_SOCKET_HINT_PATH.write_text(f"{SOCKET_PATH}\n", encoding="utf-8")
        auto_env = dict(os.environ)
        auto_env.pop("CMUX_SOCKET_PATH", None)
        auto_env.pop("CMUX_SOCKET", None)
        auto_ping = _run([cli, "ping"], env=auto_env)
        auto_ping_out = _merged_output(auto_ping).lower()
        _must(auto_ping.returncode == 0, f"debug auto socket resolution should succeed: {auto_ping.returncode} {auto_ping_out!r}")
        _must("pong" in auto_ping_out, f"debug auto socket resolution should return pong: {auto_ping_out!r}")
    finally:
        try:
            if hint_had_file:
                LAST_SOCKET_HINT_PATH.write_text(hint_backup or "", encoding="utf-8")
            else:
                LAST_SOCKET_HINT_PATH.unlink(missing_ok=True)
        except OSError:
            pass

    # Global --password should parse as a flag (not a command name) and still allow non-password sockets.
    ping_proc = _run([cli, "--socket", SOCKET_PATH, "--password", "ignored-in-cmuxonly", "ping"])
    ping_out = _merged_output(ping_proc).lower()
    _must(ping_proc.returncode == 0, f"ping with --password should succeed: {ping_proc.returncode} {ping_out!r}")
    _must("pong" in ping_out, f"ping should still return pong: {ping_out!r}")

    # V1 errors must produce non-zero exit codes for automation correctness.
    bad_focus = _run([cli, "--socket", SOCKET_PATH, "focus-window", "--window", "window:999999"])
    bad_out = _merged_output(bad_focus).lower()
    _must(bad_focus.returncode != 0, f"focus-window with invalid target should fail non-zero: {bad_out!r}")
    _must("error" in bad_out, f"focus-window failure should surface an error: {bad_out!r}")

    print("PASS: global flags parse correctly and v1 ERROR responses fail the CLI process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
