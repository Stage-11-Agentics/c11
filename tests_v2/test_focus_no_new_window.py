#!/usr/bin/env python3
"""Pick #3065: workspace.select (focus intent) does not increment the window count."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import List

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


def _run_cli(cli: str, args: List[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    cmd = [cli, "--socket", SOCKET_PATH] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def _window_count(c: cmux) -> int:
    windows = c.list_windows()
    return len(windows)


def test_select_workspace_no_new_window_socket(c: cmux) -> None:
    """workspace.select must not increase window count."""
    count_before = _window_count(c)
    new_ws_res = c._call("workspace.create") or {}
    new_ws = str(new_ws_res.get("workspace_id") or "")
    _must(bool(new_ws), f"workspace.create returned no workspace_id: {new_ws_res}")
    try:
        baseline_ws = str((c._call("workspace.current") or {}).get("workspace_id") or "")
        c._call("workspace.select", {"workspace_id": new_ws})
        time.sleep(0.2)
        count_after = _window_count(c)
        _must(
            count_after == count_before,
            f"workspace.select increased window count from {count_before} to {count_after} (spawned a new window)",
        )
        c._call("workspace.select", {"workspace_id": baseline_ws})
        time.sleep(0.1)
        count_restore = _window_count(c)
        _must(
            count_restore == count_before,
            f"Second workspace.select changed window count from {count_before} to {count_restore}",
        )
    finally:
        try:
            c.close_workspace(new_ws)
        except Exception:
            pass
    print("PASS: test_select_workspace_no_new_window_socket")


def test_select_workspace_no_new_window_cli(c: cmux, cli: str) -> None:
    """c11 workspace.select / c11 list-workspaces must not increase window count."""
    count_before = _window_count(c)
    new_ws_res = c._call("workspace.create") or {}
    new_ws = str(new_ws_res.get("workspace_id") or "")
    _must(bool(new_ws), f"workspace.create returned no workspace_id: {new_ws_res}")
    try:
        proc = _run_cli(cli, ["select-workspace", "--workspace", new_ws])
        _must(proc.returncode == 0, f"c11 select-workspace failed: {proc.stderr!r}")
        time.sleep(0.2)
        count_after = _window_count(c)
        _must(
            count_after == count_before,
            f"c11 select-workspace increased window count from {count_before} to {count_after}",
        )
        list_proc = _run_cli(cli, ["list-workspaces"])
        _must(list_proc.returncode == 0, f"c11 list-workspaces failed: {list_proc.stderr!r}")
        count_list = _window_count(c)
        _must(
            count_list == count_before,
            f"c11 list-workspaces changed window count from {count_before} to {count_list}",
        )
    finally:
        try:
            c.close_workspace(new_ws)
        except Exception:
            pass
    print("PASS: test_select_workspace_no_new_window_cli")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_select_workspace_no_new_window_socket(c)
        test_select_workspace_no_new_window_cli(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
