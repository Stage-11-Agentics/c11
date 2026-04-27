#!/usr/bin/env python3
"""Pick #3098: c11 tree --json and surface.list return non-null tty for terminal surfaces."""

from __future__ import annotations

import glob
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

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


def _register_tty(socket_path: str, ws_id: str, surface_id: str, tty_name: str) -> None:
    """Send a report_tty command via the raw CLI socket protocol."""
    raw_cmd = f"report_tty {tty_name} --tab={ws_id} --panel={surface_id}\n"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    try:
        sock.sendall(raw_cmd.encode())
        sock.settimeout(2.0)
        resp = sock.recv(4096).decode(errors="replace").strip()
        if not resp.startswith("OK"):
            raise cmuxError(f"report_tty failed: {resp!r}")
    finally:
        sock.close()


def _all_surfaces_from_tree(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for win in payload.get("windows", []):
        for ws in win.get("workspaces", []):
            for pane in ws.get("panes", []):
                out.extend(pane.get("surfaces", []))
    return out


def _run_cli(cli: str, args: List[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env["CMUX_SOCKET"] = SOCKET_PATH
    cmd = [cli, "--socket", SOCKET_PATH] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def test_tty_key_present_in_surface_list(c: cmux) -> None:
    """surface.list must include a 'tty' key for every terminal surface (may be null)."""
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    try:
        time.sleep(0.3)
        res = c._call("surface.list", {"workspace_id": ws_id}) or {}
        surfaces = res.get("surfaces") or []
        _must(bool(surfaces), f"surface.list returned no surfaces for ws {ws_id}")
        for s in surfaces:
            _must("tty" in s, f"surface.list response missing 'tty' key for terminal surface: {s}")
    finally:
        try:
            c.close_workspace(ws_id)
        except Exception:
            pass
    print("PASS: test_tty_key_present_in_surface_list")


def test_surface_list_tty_non_null_after_register(c: cmux) -> None:
    """After registering a TTY via report_tty, surface.list must return a non-null tty."""
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    try:
        time.sleep(0.3)
        surfaces_res = c._call("surface.list", {"workspace_id": ws_id}) or {}
        surfaces = surfaces_res.get("surfaces") or []
        _must(bool(surfaces), f"No surfaces in workspace {ws_id}")
        surface_id = str(surfaces[0].get("id") or "")
        _must(bool(surface_id), f"Surface missing id: {surfaces}")

        fake_tty = "/dev/ttys099"
        _register_tty(SOCKET_PATH, ws_id, surface_id, fake_tty)
        time.sleep(0.2)

        surfaces_after = (c._call("surface.list", {"workspace_id": ws_id}) or {}).get("surfaces") or []
        found = next((s for s in surfaces_after if s.get("id") == surface_id), None)
        _must(found is not None, f"Surface {surface_id!r} disappeared after TTY register")
        _must(
            found.get("tty") == fake_tty,
            f"surface.list tty expected {fake_tty!r}, got {found.get('tty')!r}",
        )
    finally:
        try:
            c.close_workspace(ws_id)
        except Exception:
            pass
    print("PASS: test_surface_list_tty_non_null_after_register")


def test_tree_json_tty_non_null_after_register(c: cmux, cli: str) -> None:
    """After registering a TTY, c11 tree --json must include the non-null tty."""
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    try:
        time.sleep(0.3)
        surfaces_res = c._call("surface.list", {"workspace_id": ws_id}) or {}
        surfaces = surfaces_res.get("surfaces") or []
        _must(bool(surfaces), f"No surfaces in workspace {ws_id}")
        surface = surfaces[0]
        surface_id = str(surface.get("id") or "")
        surface_ref = str(surface.get("ref") or "")

        fake_tty = "/dev/ttys098"
        _register_tty(SOCKET_PATH, ws_id, surface_id, fake_tty)
        time.sleep(0.2)

        proc = _run_cli(cli, ["--json", "tree", "--workspace", ws_id])
        _must(proc.returncode == 0, f"c11 --json tree failed: {proc.stderr!r}")
        payload = json.loads(proc.stdout or "{}")
        tree_surfaces = _all_surfaces_from_tree(payload)
        _must(bool(tree_surfaces), f"No surfaces in c11 tree --json output: {payload}")

        # Tree output uses 'ref' for matching (not 'id').
        found = next((s for s in tree_surfaces if s.get("ref") == surface_ref), None)
        if found is None:
            # Fallback: if only one surface in workspace, use it.
            _must(len(tree_surfaces) == 1, f"Surface ref {surface_ref!r} not in tree; multiple surfaces: {[s.get('ref') for s in tree_surfaces]}")
            found = tree_surfaces[0]
        _must("tty" in found, f"tree --json surface missing 'tty' key: {found}")
        _must(
            found.get("tty") == fake_tty,
            f"tree --json tty expected {fake_tty!r}, got {found.get('tty')!r}",
        )
    finally:
        try:
            c.close_workspace(ws_id)
        except Exception:
            pass
    print("PASS: test_tree_json_tty_non_null_after_register")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_tty_key_present_in_surface_list(c)
        test_surface_list_tty_non_null_after_register(c)
        test_tree_json_tty_non_null_after_register(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
