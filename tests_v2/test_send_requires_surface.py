#!/usr/bin/env python3
"""Pick #2839: c11 send / send-key without --surface and no CMUX_SURFACE_ID exits non-zero with error."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
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


def _run_cli_no_surface(cli: str, args: List[str]) -> subprocess.CompletedProcess:
    """Run CLI with surface env vars explicitly stripped."""
    env = dict(os.environ)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    env.pop("C11_SURFACE_ID", None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    cmd = [cli, "--socket", SOCKET_PATH] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def test_send_without_surface_fails(cli: str) -> None:
    """c11 send without --surface and no env target must exit non-zero with an error message."""
    proc = _run_cli_no_surface(cli, ["send", "hello"])
    _must(proc.returncode != 0, "c11 send without --surface should exit non-zero, but exited 0")
    merged = (proc.stdout + proc.stderr).lower()
    _must(
        "surface" in merged or "target" in merged or "required" in merged,
        f"c11 send without --surface expected error mentioning surface/target/required, got: {merged!r}",
    )
    print("PASS: test_send_without_surface_fails")


def test_send_key_without_surface_fails(cli: str) -> None:
    """c11 send-key without --surface and no env target must exit non-zero with an error message."""
    proc = _run_cli_no_surface(cli, ["send-key", "ctrl-c"])
    _must(proc.returncode != 0, "c11 send-key without --surface should exit non-zero, but exited 0")
    merged = (proc.stdout + proc.stderr).lower()
    _must(
        "surface" in merged or "target" in merged or "required" in merged,
        f"c11 send-key without --surface expected error mentioning surface/target/required, got: {merged!r}",
    )
    print("PASS: test_send_key_without_surface_fails")


def test_send_with_surface_succeeds(cli: str, c: cmux) -> None:
    """c11 send --surface <id> should succeed (guard doesn't fire when surface is explicit)."""
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    try:
        import time; time.sleep(0.2)
        surfaces = (c._call("surface.list", {"workspace_id": ws_id}) or {}).get("surfaces") or []
        _must(bool(surfaces), f"No surfaces in new workspace: {surfaces}")
        sid = str(surfaces[0].get("id") or "")
        _must(bool(sid), f"surface.list returned surface without id: {surfaces}")
        proc = _run_cli_no_surface(cli, ["send", "--workspace", ws_id, "--surface", sid, "echo c11_send_guard_test\n"])
        _must(proc.returncode == 0, f"c11 send with --surface failed unexpectedly: {proc.stderr!r}")
    finally:
        try:
            c.close_workspace(ws_id)
        except Exception:
            pass
    print("PASS: test_send_with_surface_succeeds")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_send_without_surface_fails(cli)
        test_send_key_without_surface_fails(cli)
        test_send_with_surface_succeeds(cli, c)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
