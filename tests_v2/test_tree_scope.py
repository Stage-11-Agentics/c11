#!/usr/bin/env python3
"""M8: scope behavior of `cmux tree`.

Covers spec's enumerated tests:
  - test_tree_default_scope_workspace
  - test_tree_window_flag
  - test_tree_workspace_flag
  - test_tree_all_flag
  - test_tree_conflicting_flags
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]
from tree_test_helpers import (
    SOCKET_PATH,
    all_workspaces,
    find_cli_binary,
    run_cli,
    run_tree_json,
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def test_default_scope_workspace(c: cmux, cli: str) -> None:
    """Default scope is the caller's current workspace.

    With two workspaces in the current window, default `cmux tree` returns
    exactly one workspace (the selected one). `--window` returns >= 2.
    """
    # Ensure at least two workspaces in the current window.
    initial = c.list_workspaces()
    if len(initial) < 2:
        c.new_workspace()
        time.sleep(0.2)

    current_id = c._call("workspace.current")["workspace_id"]  # type: ignore[index]
    c.select_workspace(current_id)
    time.sleep(0.1)

    payload = run_tree_json(cli)
    workspaces = all_workspaces(payload)
    _must(
        len(workspaces) == 1,
        f"default scope should return exactly 1 workspace, got {len(workspaces)}: {[w.get('ref') for w in workspaces]}",
    )
    returned_id = workspaces[0].get("id") or workspaces[0].get("ref")
    _must(
        returned_id == current_id or workspaces[0].get("ref") == current_id,
        f"default scope returned wrong workspace: {returned_id} != {current_id}",
    )
    print("PASS: test_tree_default_scope_workspace")


def test_window_flag(c: cmux, cli: str) -> None:
    """`--window` returns all workspaces in the current window."""
    initial = c.list_workspaces()
    if len(initial) < 2:
        c.new_workspace()
        time.sleep(0.2)
    expected = len(c.list_workspaces())

    payload = run_tree_json(cli, ["--window"])
    workspaces = all_workspaces(payload)
    _must(
        len(workspaces) >= 2,
        f"--window should return >=2 workspaces (have {expected}), got {len(workspaces)}",
    )
    # All returned workspaces share the same window id.
    win_ids = {w.get("id") for w in payload.get("windows", [])}
    _must(len(win_ids) == 1, f"--window must constrain to a single window, got {win_ids}")
    print("PASS: test_tree_window_flag")


def test_workspace_flag(c: cmux, cli: str) -> None:
    """`--workspace <id>` returns that workspace only."""
    workspaces_local = c.list_workspaces()
    if len(workspaces_local) < 2:
        c.new_workspace()
        time.sleep(0.2)
        workspaces_local = c.list_workspaces()
    # Pick a non-current workspace (use last).
    target_id = workspaces_local[-1][1]  # (index, id, title, selected)

    payload = run_tree_json(cli, ["--workspace", target_id])
    workspaces = all_workspaces(payload)
    _must(
        len(workspaces) == 1,
        f"--workspace should return exactly 1, got {len(workspaces)}",
    )
    returned = workspaces[0].get("id") or workspaces[0].get("ref")
    _must(
        returned == target_id or workspaces[0].get("ref") == target_id,
        f"--workspace returned wrong workspace: {returned} != {target_id}",
    )
    print("PASS: test_tree_workspace_flag")


def test_all_flag(c: cmux, cli: str) -> None:
    """`--all` returns every window/workspace."""
    payload = run_tree_json(cli, ["--all"])
    windows = payload.get("windows", [])
    _must(len(windows) >= 1, f"--all should return >=1 window, got {len(windows)}")
    workspaces = all_workspaces(payload)
    _must(len(workspaces) >= 1, f"--all should return >=1 workspace, got {len(workspaces)}")
    # Sanity: cmux always reports the current window.
    print(f"PASS: test_tree_all_flag (windows={len(windows)} workspaces={len(workspaces)})")


def test_conflicting_flags(cli: str) -> None:
    """Mutually exclusive scope flags must raise a structured error."""
    pairs = [
        ["--all", "--window"],
        ["--all", "--workspace", "workspace:1"],
        ["--window", "--workspace", "workspace:1"],
        ["--layout", "--no-layout"],
    ]
    for pair in pairs:
        rc, _stdout, stderr = run_cli(
            cli, ["tree"] + pair, json_mode=False, expect_failure=True,
        )
        _must(rc != 0, f"conflicting flags {pair} should fail; got rc={rc}")
        merged = stderr.lower()
        _must(
            "conflict" in merged or "mutually exclusive" in merged or "cannot" in merged or "exclusive" in merged,
            f"error for {pair} should mention conflict; got: {stderr!r}",
        )
    print("PASS: test_tree_conflicting_flags")


def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        test_default_scope_workspace(c, cli)
        test_window_flag(c, cli)
        test_workspace_flag(c, cli)
        test_all_flag(c, cli)
        test_conflicting_flags(cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
