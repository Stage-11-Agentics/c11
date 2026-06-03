#!/usr/bin/env python3
"""Pick #3129: surface.send_text delivers to a non-focused, non-selected surface."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List

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


def _wait_for(pred: Callable[[], bool], timeout_s: float = 8.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.1)
    raise cmuxError("Timed out waiting for condition")


def test_send_text_non_focused_surface(c: cmux, cli: str) -> None:
    """Send text to a non-selected workspace surface and confirm delivery via read-screen."""
    baseline_ws = (c._call("workspace.current") or {}).get("workspace_id", "")
    _must(bool(baseline_ws), "Could not determine current workspace")

    target_ws_res = c._call("workspace.create") or {}
    target_ws = str(target_ws_res.get("workspace_id") or "")
    _must(bool(target_ws), f"workspace.create returned no workspace_id: {target_ws_res}")

    other_ws_res = c._call("workspace.create") or {}
    other_ws = str(other_ws_res.get("workspace_id") or "")
    _must(bool(other_ws), f"workspace.create returned no workspace_id: {other_ws_res}")

    try:
        time.sleep(0.3)
        surfaces_res = c._call("surface.list", {"workspace_id": target_ws}) or {}
        surfaces = surfaces_res.get("surfaces") or []
        _must(bool(surfaces), f"No surfaces in target workspace {target_ws}")
        target_surface_id = str(surfaces[0].get("id") or "")
        _must(bool(target_surface_id), f"surface.list returned surface without id: {surfaces}")

        c._call("workspace.select", {"workspace_id": other_ws})
        time.sleep(0.1)

        current = str((c._call("workspace.current") or {}).get("workspace_id") or "")
        _must(current == other_ws, f"Expected selected workspace to be {other_ws!r}, got {current!r}")

        token = f"C11_SEND_NONFOCUS_{int(time.time() * 1000)}"
        c._call("surface.send_text", {
            "workspace_id": target_ws,
            "surface_id": target_surface_id,
            "text": f"echo {token}\n",
        })

        def token_visible() -> bool:
            payload = c._call("surface.read_text", {
                "workspace_id": target_ws,
                "surface_id": target_surface_id,
            }) or {}
            return token in str(payload.get("text") or "")

        _wait_for(token_visible, timeout_s=8.0)

        env = dict(os.environ)
        env.pop("CMUX_SURFACE_ID", None)
        env.pop("CMUX_WORKSPACE_ID", None)
        env["CMUX_SOCKET"] = SOCKET_PATH
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "read-screen",
             "--workspace", target_ws, "--surface", target_surface_id],
            capture_output=True, text=True, check=False, env=env,
        )
        _must(proc.returncode == 0, f"c11 read-screen failed: {proc.stderr!r}")
        _must(token in proc.stdout, f"c11 read-screen missing token {token!r}: {proc.stdout!r}")

        _must(
            str((c._call("workspace.current") or {}).get("workspace_id") or "") == other_ws,
            "send_text to non-focused workspace changed the selected workspace (focus stolen)",
        )
    finally:
        for ws in (target_ws, other_ws):
            try:
                c.close_workspace(ws)
            except Exception:
                pass

    print("PASS: test_send_text_non_focused_surface")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_send_text_non_focused_surface(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
