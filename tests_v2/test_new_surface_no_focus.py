#!/usr/bin/env python3
"""Pick #1418: surface.create with focus:false / c11 new-surface --no-focus preserves selected workspace."""

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


def _current_workspace(c: cmux) -> str:
    payload = c._call("workspace.current") or {}
    ws_id = str(payload.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.current returned no workspace_id: {payload}")
    return ws_id


def test_socket_no_focus(c: cmux) -> None:
    """surface.create with focus:false must not change the selected workspace."""
    baseline_ws = _current_workspace(c)
    other_ws = c._call("workspace.create") or {}
    bg_ws = str(other_ws.get("workspace_id") or "")
    _must(bool(bg_ws), f"workspace.create returned no workspace_id: {other_ws}")
    try:
        _must(
            _current_workspace(c) == baseline_ws,
            "workspace.create already changed selected workspace (pre-condition failed)",
        )
        res = c._call("surface.create", {"workspace_id": bg_ws, "type": "terminal", "focus": False}) or {}
        sid = str(res.get("surface_id") or "")
        _must(bool(sid), f"surface.create returned no surface_id: {res}")
        time.sleep(0.2)
        _must(
            _current_workspace(c) == baseline_ws,
            f"surface.create focus:false changed selected workspace to {_current_workspace(c)!r} (expected {baseline_ws!r})",
        )
    finally:
        try:
            c.close_workspace(bg_ws)
        except Exception:
            pass
    print("PASS: test_socket_no_focus")


def test_cli_no_focus_flag(c: cmux, cli: str) -> None:
    """c11 new-surface --no-focus must not change the selected workspace."""
    baseline_ws = _current_workspace(c)
    other_ws = c._call("workspace.create") or {}
    bg_ws = str(other_ws.get("workspace_id") or "")
    _must(bool(bg_ws), f"workspace.create returned no workspace_id: {other_ws}")
    try:
        proc = _run_cli(cli, ["new-surface", "--workspace", bg_ws, "--no-focus"])
        _must(proc.returncode == 0, f"c11 new-surface --no-focus failed: {proc.stderr!r}")
        time.sleep(0.2)
        _must(
            _current_workspace(c) == baseline_ws,
            f"c11 new-surface --no-focus changed selected workspace to {_current_workspace(c)!r} (expected {baseline_ws!r})",
        )
    finally:
        try:
            c.close_workspace(bg_ws)
        except Exception:
            pass
    print("PASS: test_cli_no_focus_flag")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_socket_no_focus(c)
        test_cli_no_focus_flag(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
