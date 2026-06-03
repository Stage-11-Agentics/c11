#!/usr/bin/env python3
"""Pick #2984: c11 <cmd> | head -1 exits cleanly, no SIGABRT on broken pipe."""

from __future__ import annotations

import glob
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import List, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get("C11_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI") or os.environ.get("C11_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli
    candidates: List[str] = []
    candidates += glob.glob("/tmp/c11-*/Build/Products/Debug/c11 DEV *.app/Contents/Resources/bin/c11")
    candidates += glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/c11 DEV*.app/Contents/Resources/bin/c11"
    ), recursive=True)
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate c11 CLI; set CMUXTERM_CLI or C11_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _broken_pipe_exit(cli: str, args: List[str]) -> Tuple[int, str]:
    """Run CLI, read only one line from stdout, then close the pipe. Return (returncode, one_line)."""
    env = dict(os.environ)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    line = b""
    try:
        line = proc.stdout.readline()
    finally:
        proc.stdout.close()
    proc.wait(timeout=5)
    return proc.returncode, line.decode("utf-8", errors="replace").strip()


def test_list_workspaces_sigpipe_clean(cli: str) -> None:
    """c11 list-workspaces | head -1: CLI must not abort on broken pipe."""
    rc, first_line = _broken_pipe_exit(cli, ["list-workspaces"])
    _must(
        rc != -signal.SIGABRT,
        f"c11 list-workspaces got SIGABRT (rc={rc}) on broken pipe — fix didn't land",
    )
    _must(
        rc in (0, -signal.SIGPIPE, 141),
        f"c11 list-workspaces unexpected exit code {rc} on broken pipe (expected 0, SIGPIPE, or 141)",
    )
    print(f"PASS: test_list_workspaces_sigpipe_clean (rc={rc}, first_line={first_line!r})")


def test_tree_sigpipe_clean(cli: str) -> None:
    """c11 tree | head -1: CLI must not abort on broken pipe."""
    rc, first_line = _broken_pipe_exit(cli, ["tree"])
    _must(
        rc != -signal.SIGABRT,
        f"c11 tree got SIGABRT (rc={rc}) on broken pipe — fix didn't land",
    )
    _must(
        rc in (0, -signal.SIGPIPE, 141),
        f"c11 tree unexpected exit code {rc} on broken pipe (expected 0, SIGPIPE, or 141)",
    )
    print(f"PASS: test_tree_sigpipe_clean (rc={rc}, first_line={first_line!r})")


def test_shell_pipeline_exit_code(cli: str) -> None:
    """Shell pipeline 'c11 list-workspaces | head -1' must exit with overall code 0."""
    env = dict(os.environ)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    cmd = f"{cli!r} --socket {SOCKET_PATH!r} list-workspaces | head -1"
    proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False, env=env)
    _must(
        proc.returncode == 0,
        f"Shell pipeline 'c11 list-workspaces | head -1' exited {proc.returncode}: {proc.stderr!r}",
    )
    print("PASS: test_shell_pipeline_exit_code")


def main() -> int:
    cli = _find_cli()
    test_list_workspaces_sigpipe_clean(cli)
    test_tree_sigpipe_clean(cli)
    test_shell_pipeline_exit_code(cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
