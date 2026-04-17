#!/usr/bin/env python3
"""M8: each pane line in the text tree carries `size=`, `px=`, `split=` badges.

Spec format:
  pane pane:N size=W%×H% px=W×H split=H:left|H:right|V:top|V:bottom (chain)
or `split=none` for a root single pane.
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]
from tree_test_helpers import (
    SOCKET_PATH,
    PANE_LINE_BADGES_RE,
    find_cli_binary,
    pane_lines,
    run_tree_text,
)


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _make_split_workspace(c: cmux) -> str:
    wsid = c.new_workspace()
    c.select_workspace(wsid)
    time.sleep(0.2)
    return wsid


def _close_workspace_quietly(c: cmux, wsid: str) -> None:
    try:
        c.close_workspace(wsid)
    except Exception:
        pass


def test_single_pane_workspace_split_none(c: cmux, cli: str) -> None:
    """A workspace with one pane should print `split=none` and well-formed badges."""
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, ["--no-layout"], canvas_cols=80)
        lines = pane_lines(text)
        _must(lines, f"expected at least one pane line; output:\n{text}")
        for line in lines:
            _must(
                PANE_LINE_BADGES_RE.search(line) is not None,
                f"pane line missing badges: {line!r}",
            )
        # At least one of those should be split=none.
        _must(
            any("split=none" in l for l in lines),
            f"single-pane workspace should print split=none; lines:\n{lines}",
        )
        print("PASS: test_tree_text_pane_line_badges (single pane)")
    finally:
        _close_workspace_quietly(c, wsid)


def test_horizontal_split_badges(c: cmux, cli: str) -> None:
    """A horizontal split should print split=H:left and split=H:right."""
    wsid = _make_split_workspace(c)
    try:
        c.new_split("right")
        time.sleep(0.25)
        text = run_tree_text(cli, ["--no-layout"], canvas_cols=80)
        lines = pane_lines(text)
        _must(len(lines) >= 2, f"expected >=2 pane lines after split; got {len(lines)}\n{text}")
        for line in lines:
            _must(
                PANE_LINE_BADGES_RE.search(line) is not None,
                f"pane line missing badges after split: {line!r}",
            )
        _must(any("split=H:left" in l for l in lines), f"missing split=H:left: {lines}")
        _must(any("split=H:right" in l for l in lines), f"missing split=H:right: {lines}")
        print("PASS: test_tree_text_pane_line_badges (horizontal split)")
    finally:
        _close_workspace_quietly(c, wsid)


def test_nested_split_chain(c: cmux, cli: str) -> None:
    """Nested split should produce a comma-separated chain (`H:right,V:top`)."""
    wsid = _make_split_workspace(c)
    try:
        right_panel = c.new_split("right")
        time.sleep(0.15)
        c.focus_surface(right_panel)
        time.sleep(0.05)
        c.new_split("down")
        time.sleep(0.25)
        text = run_tree_text(cli, ["--no-layout"], canvas_cols=80)
        lines = pane_lines(text)
        _must(len(lines) >= 3, f"expected >=3 pane lines; got {len(lines)}\n{text}")
        for line in lines:
            _must(
                PANE_LINE_BADGES_RE.search(line) is not None,
                f"pane line missing badges in nested split: {line!r}",
            )
        # Look for a chain split=H:right,V:top or H:right,V:bottom.
        chain_present = any(
            ("split=H:right,V:top" in l) or ("split=H:right,V:bottom" in l) for l in lines
        )
        _must(chain_present, f"expected nested chain badge; lines:\n{lines}")
        print("PASS: test_tree_text_pane_line_badges (nested chain)")
    finally:
        _close_workspace_quietly(c, wsid)


def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        test_single_pane_workspace_split_none(c, cli)
        test_horizontal_split_badges(c, cli)
        test_nested_split_chain(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
