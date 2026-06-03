#!/usr/bin/env python3
"""Pick #2951: workspace.create with invalid layout rolls back — no orphan workspace left."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import tempfile
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


def _all_workspace_ids(c: cmux) -> List[str]:
    workspaces = c.list_workspaces()
    return [ws_id for (_, ws_id, _, _) in workspaces]


def test_bad_plan_version_no_orphan_socket(c: cmux) -> None:
    """workspace.create with an unsupported plan version must error and leave no new workspace."""
    ids_before = set(_all_workspace_ids(c))

    try:
        result = c._call("workspace.create", {
            "layout": {
                "plan": {
                    "version": 9999,
                    "workspace": {},
                    "layout": {"type": "pane", "pane": {"surfaceIds": ["s1"]}},
                    "surfaces": [{"id": "s1", "kind": "terminal"}],
                },
            },
        })
        raise cmuxError(
            f"workspace.create with invalid plan version should have failed, but returned: {result}"
        )
    except cmuxError as exc:
        if "should have failed" in str(exc):
            raise

    time.sleep(0.3)
    ids_after = set(_all_workspace_ids(c))
    new_ids = ids_after - ids_before
    _must(
        len(new_ids) == 0,
        f"workspace.create with invalid plan left {len(new_ids)} orphan workspace(s): {new_ids}",
    )
    print("PASS: test_bad_plan_version_no_orphan_socket")


def test_bad_blueprint_no_orphan_cli(cli: str, c: cmux) -> None:
    """c11 new-workspace --layout <bad-file> must error and leave no new workspace."""
    ids_before = set(_all_workspace_ids(c))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, prefix="c11-test-bad-blueprint-"
    ) as f:
        # Blueprint file with no 'plan' key triggers CLI error before socket call.
        json.dump({"version": "bad", "not_a_plan": True}, f)
        bad_path = f.name

    try:
        env = dict(os.environ)
        env.pop("CMUX_SURFACE_ID", None)
        env.pop("CMUX_WORKSPACE_ID", None)
        env.pop("CMUX_TAB_ID", None)
        env["CMUX_SOCKET"] = SOCKET_PATH
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "new-workspace", "--layout", bad_path],
            capture_output=True, text=True, check=False, env=env,
        )
        _must(
            proc.returncode != 0,
            f"c11 new-workspace --layout <bad> should exit non-zero, got 0. stdout={proc.stdout!r}",
        )
    finally:
        try:
            os.unlink(bad_path)
        except OSError:
            pass

    time.sleep(0.3)
    ids_after = set(_all_workspace_ids(c))
    new_ids = ids_after - ids_before
    _must(
        len(new_ids) == 0,
        f"c11 new-workspace with bad blueprint left {len(new_ids)} orphan workspace(s): {new_ids}",
    )
    print("PASS: test_bad_blueprint_no_orphan_cli")


def test_valid_plan_creates_workspace(c: cmux) -> None:
    """workspace.create with a valid plan must succeed and workspace appears in list."""
    ids_before = set(_all_workspace_ids(c))
    new_ws_res = c._call("workspace.create", {
        "layout": {
            "plan": {
                "version": 1,
                "workspace": {},
                "layout": {"type": "pane", "pane": {"surfaceIds": ["s1"]}},
                "surfaces": [{"id": "s1", "kind": "terminal"}],
            },
        },
    }) or {}
    new_ws = str(new_ws_res.get("workspace_id") or "")
    _must(bool(new_ws), f"workspace.create with valid plan returned no workspace_id: {new_ws_res}")
    try:
        time.sleep(0.2)
        ids_after = set(_all_workspace_ids(c))
        _must(
            new_ws in ids_after,
            f"workspace.create with valid plan returned {new_ws!r} but it's not in workspace list",
        )
    finally:
        try:
            c.close_workspace(new_ws)
        except Exception:
            pass
    print("PASS: test_valid_plan_creates_workspace")


def main() -> int:
    cli = _find_cli()
    with cmux(SOCKET_PATH) as c:
        test_bad_plan_version_no_orphan_socket(c)
        test_bad_blueprint_no_orphan_cli(cli, c)
        test_valid_plan_creates_workspace(c)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
