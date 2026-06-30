#!/usr/bin/env python3
"""`c11 tree --report` — human-readable Markdown fleet snapshot.

Covers:
  - test_report_structure        header, generated line, panes, summary table
  - test_report_defaults_to_all  no scope flag => every workspace in the window
  - test_report_out_file         --out writes the markdown to a file
  - test_report_workspace_scope  --workspace narrows to a single workspace
  - test_report_markdown_alias   --markdown is an alias for --report
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]
from tree_test_helpers import (
    SOCKET_PATH,
    find_cli_binary,
    run_cli,
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run_report(cli: str, extra_args=None):
    args = ["tree", "--report"] + (extra_args or [])
    _, stdout, _ = run_cli(cli, args)
    return stdout


def _heading_count(markdown: str) -> int:
    return sum(1 for line in markdown.splitlines() if line.startswith("### "))


def test_report_structure(c: cmux, cli: str) -> None:
    if len(c.list_workspaces()) < 2:
        c.new_workspace()
        time.sleep(0.2)

    md = _run_report(cli)
    _must(md.startswith("# c11 Fleet Snapshot"), f"report must start with the title header; got: {md[:60]!r}")
    _must("_Generated " in md, "report must carry a `_Generated ...` line")
    for token in ("window", "workspace", "surface"):
        _must(token in md, f"generated line should mention {token!r}")
    _must("**Pane**" in md, "report must list panes")
    _must("## Summary" in md, "report must end with a Summary section")
    _must("| Window | Workspace | Panes | Surfaces |" in md, "report must contain the summary table header")
    print("PASS: test_report_structure")


def test_report_defaults_to_all(c: cmux, cli: str) -> None:
    """No scope flag => fleet-wide (every workspace in the window, >= 2)."""
    if len(c.list_workspaces()) < 2:
        c.new_workspace()
        time.sleep(0.2)
    expected = len(c.list_workspaces())

    md = _run_report(cli)
    headings = _heading_count(md)
    _must(
        headings >= expected,
        f"--report should default to all workspaces (>= {expected}); got {headings} workspace headings",
    )
    print(f"PASS: test_report_defaults_to_all (headings={headings} expected>={expected})")


def test_report_out_file(cli: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        out_path = os.path.join(tmp, "nested", "fleet.md")
        rc, stdout, _ = run_cli(cli, ["tree", "--report", "--out", out_path])
        _must(rc == 0, f"--out should succeed; rc={rc}")
        _must("OK fleet-report path=" in stdout, f"--out should print an OK line; got: {stdout!r}")
        _must(os.path.isfile(out_path), f"--out should create {out_path}")
        content = Path(out_path).read_text(encoding="utf-8")
        _must(content.startswith("# c11 Fleet Snapshot"), "written file must contain the report")
    print("PASS: test_report_out_file")


def test_report_workspace_scope(c: cmux, cli: str) -> None:
    """`--workspace <id> --report` narrows to exactly one workspace."""
    workspaces = c.list_workspaces()
    if len(workspaces) < 2:
        c.new_workspace()
        time.sleep(0.2)
        workspaces = c.list_workspaces()
    target_id = workspaces[-1][1]  # (index, id, title, selected)

    md = _run_report(cli, ["--workspace", target_id])
    headings = _heading_count(md)
    _must(headings == 1, f"--workspace --report should render exactly 1 workspace, got {headings}")
    print("PASS: test_report_workspace_scope")


def test_report_markdown_alias(cli: str) -> None:
    _, stdout, _ = run_cli(cli, ["tree", "--markdown"])
    _must(stdout.startswith("# c11 Fleet Snapshot"), "--markdown should alias --report")
    print("PASS: test_report_markdown_alias")


def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        test_report_structure(c, cli)
        test_report_defaults_to_all(c, cli)
        test_report_out_file(cli)
        test_report_workspace_scope(c, cli)
        test_report_markdown_alias(cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
