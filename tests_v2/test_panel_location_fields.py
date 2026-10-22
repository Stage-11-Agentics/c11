#!/usr/bin/env python3
"""C11-229: tree --json and get-metadata expose per-surface cwd, branch, worktree.

Drives the real socket path: `report_pwd` moves a terminal panel into a temp
repo, a linked worktree, and a non-repo directory; the off-main git probe
resolves each; `system.tree` and `panel.get_metadata` must agree with what
the sidebar chips render. A remote (c11 ssh style) workspace must report null,
never the local repo.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get("C11_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _git(cwd: str, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
        cwd=cwd, check=True, capture_output=True,
    )


def _report_pwd(ws_id: str, panel_id: str, path: str) -> None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    try:
        sock.sendall(f"report_pwd {path} --tab={ws_id} --panel={panel_id}\n".encode())
        sock.settimeout(2.0)
        resp = sock.recv(4096).decode(errors="replace").strip()
        _must(resp.startswith("OK"), f"report_pwd failed: {resp!r}")
    finally:
        sock.close()


def _tree_surface(c: cmux, ws_id: str, panel_id: str) -> Dict[str, Any]:
    payload = c._call("system.tree", {"workspace_id": ws_id, "scope": "workspace"}) or {}
    for win in payload.get("windows", []):
        for ws in win.get("workspaces", []):
            for pane in ws.get("areas", []):
                for s in pane.get("panels", []):
                    if s.get("id") == panel_id:
                        return s
    raise cmuxError(f"panel {panel_id} not in system.tree: {payload}")


def _metadata(c: cmux, ws_id: str, panel_id: str) -> Dict[str, Any]:
    return c._call("panel.get_metadata", {
        "workspace_id": ws_id, "panel_id": panel_id, "include_sources": True,
    }) or {}


def _wait_for(pred, what: str, timeout: float = 30.0, resend=None) -> Any:
    """Poll `pred`. `resend` re-announces the cwd each pass: the panel's own
    shell integration reports its startup directory late and would otherwise
    overwrite the one the test announced (a repeat of the same path is a no-op)."""
    deadline = time.time() + timeout
    last: Any = None
    while time.time() < deadline:
        if resend:
            resend()
        last = pred()
        if last:
            return last
        time.sleep(0.25)
    raise cmuxError(f"timed out waiting for {what}; last={last!r}")


def _first_panel(c: cmux, ws_id: str) -> str:
    panels = (c._call("panel.list", {"workspace_id": ws_id}) or {}).get("panels") or []
    _must(bool(panels), f"no panels in {ws_id}")
    return str(panels[0]["id"])


def main() -> int:
    root = tempfile.mkdtemp(prefix="c11-229-")
    root = os.path.realpath(root)
    main_repo = os.path.join(root, "repo")
    linked = os.path.join(root, "C11-229-demo")
    plain = os.path.join(root, "plain")
    os.makedirs(main_repo)
    os.makedirs(plain)
    _git(main_repo, "init", "-b", "main")
    Path(main_repo, "f.txt").write_text("x")
    _git(main_repo, "add", ".")
    _git(main_repo, "commit", "-m", "init")
    _git(main_repo, "worktree", "add", "-b", "C11-229-demo", linked)

    with cmux(SOCKET_PATH) as c:
        ws_id = str((c._call("workspace.create") or {}).get("workspace_id") or "")
        _must(bool(ws_id), "workspace.create returned no id")
        remote_ws = ""
        try:
            time.sleep(0.5)
            panel_id = _first_panel(c, ws_id)

            # 1. main checkout: branch main, worktree null.
            _report_pwd(ws_id, panel_id, main_repo)
            s = _wait_for(
                lambda: (lambda t: t if t.get("branch") == "main" else None)(_tree_surface(c, ws_id, panel_id)),
                "tree branch=main",
                resend=lambda: _report_pwd(ws_id, panel_id, main_repo),
            )
            _must(s.get("cwd") == main_repo, f"cwd {s.get('cwd')!r} != {main_repo!r}")
            _must(s.get("worktree") is None, f"main checkout worktree should be null: {s}")
            md = _metadata(c, ws_id, panel_id)
            _must(md["metadata"].get("branch") == "main", f"get-metadata branch: {md}")
            _must(md["metadata_sources"]["branch"]["source"] == "derived", f"branch source: {md}")
            print("PASS: main checkout")

            # 2. linked worktree: branch + basename; metadata agrees.
            _report_pwd(ws_id, panel_id, linked)
            s = _wait_for(
                lambda: (lambda t: t if t.get("worktree") == "C11-229-demo" else None)(_tree_surface(c, ws_id, panel_id)),
                "tree worktree=C11-229-demo",
                resend=lambda: _report_pwd(ws_id, panel_id, linked),
            )
            _must(s.get("branch") == "C11-229-demo", f"linked branch: {s}")
            _must(s.get("cwd") == linked, f"linked cwd: {s}")
            md = _metadata(c, ws_id, panel_id)
            _must(md["metadata"].get("worktree") == "C11-229-demo", f"metadata worktree: {md}")
            _must(md["metadata"].get("branch") == "C11-229-demo", f"metadata branch: {md}")
            _must(md["metadata_sources"]["worktree"]["source"] == "derived", f"worktree source: {md}")
            print("PASS: linked worktree")

            # 3. non-repo: cwd only.
            _report_pwd(ws_id, panel_id, plain)
            s = _wait_for(
                lambda: (lambda t: t if t.get("cwd") == plain and t.get("branch") is None else None)(_tree_surface(c, ws_id, panel_id)),
                "tree non-repo",
                resend=lambda: _report_pwd(ws_id, panel_id, plain),
            )
            _must(s.get("worktree") is None, f"non-repo worktree: {s}")
            print("PASS: non-repo")

            # 4. remote workspace: all null even when the path exists locally.
            remote_ws = str((c._call("workspace.create") or {}).get("workspace_id") or "")
            _must(bool(remote_ws), "second workspace.create failed")
            c._call("workspace.remote.configure", {
                "workspace_id": remote_ws, "destination": "nobody@c11-229.invalid", "auto_connect": False,
            })
            time.sleep(0.5)
            rpanel = _first_panel(c, remote_ws)
            for _ in range(8):  # outlast the probe's round trip; keep the path announced
                _report_pwd(remote_ws, rpanel, linked)
                time.sleep(0.5)
            s = _tree_surface(c, remote_ws, rpanel)
            for key in ("cwd", "branch", "worktree"):
                _must(key in s and s[key] is None, f"remote panel {key} must be null: {s}")
            md = _metadata(c, remote_ws, rpanel)["metadata"]
            _must(md.get("branch") in (None, ""), f"remote derived branch must be empty: {md}")
            _must(md.get("worktree") in (None, ""), f"remote derived worktree must be empty: {md}")
            print("PASS: remote workspace reports null")

            # 5. a resolved local workspace that turns remote drops its local
            #    identity at once, even when the shell announces the same cwd.
            flip_ws = str((c._call("workspace.create") or {}).get("workspace_id") or "")
            _must(bool(flip_ws), "third workspace.create failed")
            try:
                time.sleep(0.5)
                fpanel = _first_panel(c, flip_ws)
                _wait_for(
                    lambda: (lambda t: t if t.get("worktree") == "C11-229-demo" else None)(_tree_surface(c, flip_ws, fpanel)),
                    "flip workspace resolved locally",
                    resend=lambda: _report_pwd(flip_ws, fpanel, linked),
                )
                _must(_metadata(c, flip_ws, fpanel)["metadata"].get("branch") == "C11-229-demo", "seed metadata missing")
                time.sleep(2.0)
                c._call("workspace.remote.configure", {
                    "workspace_id": flip_ws, "destination": "nobody@c11-229.invalid", "auto_connect": False,
                })
                for _ in range(8):
                    _report_pwd(flip_ws, fpanel, linked)
                    time.sleep(0.5)
                s = _tree_surface(c, flip_ws, fpanel)
                for key in ("cwd", "branch", "worktree"):
                    _must(s.get(key) is None, f"flipped panel {key} must be null: {s}")
                md = _metadata(c, flip_ws, fpanel)["metadata"]
                _must(md.get("branch") in (None, ""), f"flipped derived branch must clear: {md}")
                _must(md.get("worktree") in (None, ""), f"flipped derived worktree must clear: {md}")
            finally:
                try:
                    c.close_workspace(flip_ws)
                except Exception:
                    pass
            print("PASS: local-to-remote transition clears derived identity")
        finally:
            for w in (ws_id, remote_ws):
                if w:
                    try:
                        c.close_workspace(w)
                    except Exception:
                        pass
            shutil.rmtree(root, ignore_errors=True)
    print("PASS: test_panel_location_fields")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
