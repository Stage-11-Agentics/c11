#!/usr/bin/env python3
"""M8: ASCII floor plan rendering for `cmux tree`.

Covers spec's enumerated tests:
  - test_tree_floor_plan_default_on
  - test_tree_floor_plan_off_with_window_flag
  - test_tree_floor_plan_opt_in_with_layout
  - test_tree_floor_plan_never_in_json
  - test_tree_floor_plan_box_content
  - test_tree_floor_plan_title_truncation
  - test_tree_floor_plan_narrow_pane_degradation
  - test_tree_floor_plan_tiny_canvas_suppressed
  - test_tree_floor_plan_aspect_ratio
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]
from tree_test_helpers import (
    SOCKET_PATH,
    find_cli_binary,
    run_cli,
    run_tree_text,
)


# Box-drawing characters used by the renderer.
BOX_CHARS = set("─│┌┐└┘├┤┬┴┼")
ALL_BOX_CHARS = BOX_CHARS | {" "}


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _has_floor_plan(text: str) -> bool:
    """Return True iff the output contains a floor plan (box drawing rows)."""
    for line in text.splitlines():
        if any(ch in BOX_CHARS for ch in line):
            return True
    return False


def _floor_plan_rows(text: str) -> List[str]:
    """Return the lines that look like floor-plan grid rows."""
    out: List[str] = []
    for line in text.splitlines():
        # A grid row is a line containing at least one box-drawing character
        # AND only box chars + spaces (heuristic that excludes the tree section).
        if any(ch in BOX_CHARS for ch in line) and all(ch in ALL_BOX_CHARS or not ch.strip() for ch in line):
            out.append(line)
    return out


def _make_split_workspace(c: cmux) -> str:
    wsid = c.new_workspace()
    c.select_workspace(wsid)
    time.sleep(0.2)
    c.new_split("right")
    time.sleep(0.25)
    return wsid


def _close_workspace_quietly(c: cmux, wsid: str) -> None:
    try:
        c.close_workspace(wsid)
    except Exception:
        pass


def test_default_on_for_workspace_scope(c: cmux, cli: str) -> None:
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, canvas_cols=80)
        _must(_has_floor_plan(text), f"default cmux tree should render a floor plan; output:\n{text}")
        print("PASS: test_tree_floor_plan_default_on")
    finally:
        _close_workspace_quietly(c, wsid)


def test_off_with_window_flag(c: cmux, cli: str) -> None:
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, ["--window"], canvas_cols=80)
        _must(not _has_floor_plan(text), f"--window should suppress floor plan; output:\n{text}")
        print("PASS: test_tree_floor_plan_off_with_window_flag")
    finally:
        _close_workspace_quietly(c, wsid)


def test_opt_in_with_layout(c: cmux, cli: str) -> None:
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, ["--window", "--layout"], canvas_cols=80)
        _must(_has_floor_plan(text), f"--window --layout should render floor plan; output:\n{text}")

        text2 = run_tree_text(cli, ["--no-layout"], canvas_cols=80)
        _must(not _has_floor_plan(text2), f"--no-layout should suppress floor plan; output:\n{text2}")
        print("PASS: test_tree_floor_plan_opt_in_with_layout")
    finally:
        _close_workspace_quietly(c, wsid)


def test_never_in_json(c: cmux, cli: str) -> None:
    """JSON mode must never include floor plan text. Output must parse as JSON."""
    wsid = _make_split_workspace(c)
    try:
        # `--layout` is asked explicitly but JSON mode wins.
        rc, stdout, stderr = run_cli(cli, ["tree", "--layout"], json_mode=True, canvas_cols=80)
        _must(rc == 0, f"JSON tree --layout should succeed; stderr={stderr}")
        # Must parse as JSON (i.e. no leading floor plan text glued in).
        try:
            json.loads(stdout)
        except json.JSONDecodeError as e:
            raise cmuxError(f"JSON output not parseable when --layout is set: {e}; stdout={stdout!r}")
        # Defensive: no box characters anywhere.
        for ch in BOX_CHARS:
            _must(ch not in stdout, f"JSON output contains box-drawing char {ch!r}: {stdout!r}")
        print("PASS: test_tree_floor_plan_never_in_json")
    finally:
        _close_workspace_quietly(c, wsid)


def test_box_content_includes_pane_ref_and_size(c: cmux, cli: str) -> None:
    """Each pane box body must include the pane ref and percent×percent."""
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, canvas_cols=120)
        rows = _floor_plan_rows(text)
        body = "\n".join(rows)
        _must(rows, f"expected floor plan rows; output:\n{text}")
        # Two panes → at least two pane:N references should appear inside boxes.
        ref_matches = re.findall(r"pane:\d+", body)
        _must(len(ref_matches) >= 2, f"expected >=2 pane refs in floor plan; matches={ref_matches}\nbody:\n{body}")
        # Percent badges appear as N%W or N%×N% (renderer collapses spaces in narrow boxes).
        pct_matches = re.findall(r"\d+%\s*[Wx×]", body)
        _must(pct_matches, f"expected percent badge in floor plan; body:\n{body}")
        print("PASS: test_tree_floor_plan_box_content")
    finally:
        _close_workspace_quietly(c, wsid)


def test_title_truncation(c: cmux, cli: str) -> None:
    """Title line must be truncated with ellipsis when wider than the box."""
    wsid = c.new_workspace()
    c.select_workspace(wsid)
    time.sleep(0.2)
    try:
        # Force a long workspace title so the box body has something definite to
        # truncate (per spec the box body's title line is the selected tab title;
        # tab titles for a fresh shell are typically the working dir).
        try:
            c.rename_workspace(
                "this-is-a-very-long-workspace-title-that-should-not-fit-in-any-tiny-box",
                workspace=wsid,
            )
        except Exception:
            pass
        # Single pane (no split) → big box. With small canvas-cols the title
        # truncation logic kicks in.
        text = run_tree_text(cli, canvas_cols=40)
        rows = _floor_plan_rows(text)
        if not rows:
            # 40 cols is the suppression threshold edge; bump up.
            text = run_tree_text(cli, canvas_cols=50)
            rows = _floor_plan_rows(text)
        body = "\n".join(rows)
        _must(rows, f"expected rows at 40-50 cols; output:\n{text}")
        # Long title cannot fit; must contain a truncation ellipsis OR be entirely absent.
        if "this-is-a-very" in body:
            _must("…" in body, f"long title rendered without ellipsis truncation; body:\n{body}")
        # Workspace header line above the plan should always show the title (it's
        # not subject to box-width truncation).
        header_line = next((l for l in text.splitlines() if "workspace" in l and "this-is-a-very" in l), None)
        _must(header_line is not None, f"workspace header line missing long title; output:\n{text}")
        print("PASS: test_tree_floor_plan_title_truncation")
    finally:
        _close_workspace_quietly(c, wsid)


def test_narrow_pane_degradation(c: cmux, cli: str) -> None:
    """Very narrow boxes collapse to a single summary line.

    Build many vertical splits so each pane gets a narrow column.
    """
    wsid = c.new_workspace()
    c.select_workspace(wsid)
    time.sleep(0.2)
    try:
        # Make 4 panes side by side.
        for _ in range(3):
            c.new_split("right")
            time.sleep(0.1)
        text = run_tree_text(cli, canvas_cols=50)  # narrow canvas
        rows = _floor_plan_rows(text)
        body = "\n".join(rows)
        _must(rows, f"expected floor plan rows; output:\n{text}")
        # The box body must have at most one body row per box. We approximate by
        # checking that the total number of grid rows is small relative to the
        # collapsed expected (4–6 rows ≈ borders + 1 body row each).
        _must(len(rows) <= 12, f"narrow canvas should collapse bodies; rows={len(rows)} body:\n{body}")
        print("PASS: test_tree_floor_plan_narrow_pane_degradation")
    finally:
        _close_workspace_quietly(c, wsid)


def test_tiny_canvas_suppressed(c: cmux, cli: str) -> None:
    """Canvas width <40 must suppress the plan with a one-line notice."""
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, canvas_cols=20)
        _must(not _has_floor_plan(text), f"<40 col canvas should suppress plan; output:\n{text}")
        _must(
            "[layout suppressed" in text or "canvas <40" in text or "suppressed" in text,
            f"suppressed plan should print explanation; output:\n{text}",
        )
        print("PASS: test_tree_floor_plan_tiny_canvas_suppressed")
    finally:
        _close_workspace_quietly(c, wsid)


def test_aspect_ratio(c: cmux, cli: str) -> None:
    """Canvas height should follow round(width × (h/w) × 0.5), bounded [6, 60]."""
    wsid = _make_split_workspace(c)
    try:
        text = run_tree_text(cli, canvas_cols=80)
        rows = _floor_plan_rows(text)
        _must(rows, f"expected rows; output:\n{text}")
        # Bounded between 6 and 60 inclusive.
        _must(6 <= len(rows) <= 60, f"row count {len(rows)} out of bounds [6,60]")
        # Wider canvas should not produce fewer rows for the same workspace.
        text2 = run_tree_text(cli, canvas_cols=160)
        rows2 = _floor_plan_rows(text2)
        _must(rows2, f"expected rows at 160 cols; output:\n{text2}")
        _must(
            len(rows2) >= len(rows),
            f"expected wider canvas to give >= rows; 80→{len(rows)} 160→{len(rows2)}",
        )
        print("PASS: test_tree_floor_plan_aspect_ratio")
    finally:
        _close_workspace_quietly(c, wsid)


def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        test_default_on_for_workspace_scope(c, cli)
        test_off_with_window_flag(c, cli)
        test_opt_in_with_layout(c, cli)
        test_never_in_json(c, cli)
        test_box_content_includes_pane_ref_and_size(c, cli)
        test_title_truncation(c, cli)
        test_narrow_pane_degradation(c, cli)
        test_tiny_canvas_suppressed(c, cli)
        test_aspect_ratio(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
