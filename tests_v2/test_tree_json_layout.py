#!/usr/bin/env python3
"""M8: JSON layout shape and split geometry under `cmux tree --json`.

Covers spec's enumerated tests:
  - test_tree_layout_horizontal_split
  - test_tree_layout_vertical_split
  - test_tree_layout_nested_split
  - test_tree_content_area_sum
  - test_tree_json_backcompat
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore[import]
from tree_test_helpers import (
    SOCKET_PATH,
    all_panes,
    all_workspaces,
    assert_layout_well_formed,
    find_cli_binary,
    percent_area,
    run_tree_json,
)


EPS = 0.02  # 2% tolerance for divider rounding / DPI snapping.


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _make_fresh_workspace(c: cmux) -> str:
    wsid = c.new_workspace()
    c.select_workspace(wsid)
    time.sleep(0.25)
    return wsid


def _close_workspace_quietly(c: cmux, wsid: str) -> None:
    try:
        c.close_workspace(wsid)
    except Exception:
        pass


def _wait_for_layout(c: cmux, wsid: str, cli: str, expected_panes: int, timeout_s: float = 3.0) -> Dict[str, Any]:
    """Poll `cmux tree --workspace <id>` until layout is populated."""
    deadline = time.time() + timeout_s
    last: Dict[str, Any] = {}
    while time.time() < deadline:
        payload = run_tree_json(cli, ["--workspace", wsid])
        panes = all_panes(payload)
        last = payload
        if len(panes) == expected_panes:
            laid = [p for p in panes if isinstance(p.get("layout"), dict) and isinstance(p["layout"].get("percent"), dict)]
            if len(laid) == expected_panes:
                return payload
        time.sleep(0.1)
    return last


def test_layout_horizontal_split(c: cmux, cli: str) -> None:
    wsid = _make_fresh_workspace(c)
    try:
        # Create a left/right split (split right).
        c.new_split("right")
        time.sleep(0.2)
        payload = _wait_for_layout(c, wsid, cli, expected_panes=2)
        panes = all_panes(payload)
        _must(len(panes) == 2, f"expected 2 panes, got {len(panes)}: {panes}")
        for p in panes:
            assert_layout_well_formed(p)

        # The two panes should partition the horizontal axis (~ 0..0.5 and ~0.5..1.0)
        # and each cover the full vertical axis.
        h_starts = sorted([p["layout"]["percent"]["H"][0] for p in panes])
        h_ends = sorted([p["layout"]["percent"]["H"][1] for p in panes])
        _must(abs(h_starts[0] - 0.0) < EPS, f"left pane H[0] != 0: {h_starts}")
        _must(abs(h_ends[1] - 1.0) < EPS, f"right pane H[1] != 1: {h_ends}")
        # Touching at the divider.
        _must(abs(h_ends[0] - h_starts[1]) < EPS, f"divider mismatch: {h_ends[0]} vs {h_starts[1]}")
        for p in panes:
            v0, v1 = p["layout"]["percent"]["V"]
            _must(abs(v0) < EPS and abs(v1 - 1.0) < EPS, f"horizontal split should leave V full: {p['layout']['percent']}")

        # split_path should be a 1-element array per pane (H:left / H:right).
        chains = sorted([tuple(p["layout"].get("split_path") or []) for p in panes])
        _must(chains == [("H:left",), ("H:right",)], f"split_path mismatch: {chains}")
        print("PASS: test_tree_layout_horizontal_split")
    finally:
        _close_workspace_quietly(c, wsid)


def test_layout_vertical_split(c: cmux, cli: str) -> None:
    wsid = _make_fresh_workspace(c)
    try:
        c.new_split("down")
        time.sleep(0.2)
        payload = _wait_for_layout(c, wsid, cli, expected_panes=2)
        panes = all_panes(payload)
        _must(len(panes) == 2, f"expected 2 panes, got {len(panes)}")
        for p in panes:
            assert_layout_well_formed(p)

        v_starts = sorted([p["layout"]["percent"]["V"][0] for p in panes])
        v_ends = sorted([p["layout"]["percent"]["V"][1] for p in panes])
        _must(abs(v_starts[0]) < EPS, f"top pane V[0] != 0: {v_starts}")
        _must(abs(v_ends[1] - 1.0) < EPS, f"bottom pane V[1] != 1: {v_ends}")
        _must(abs(v_ends[0] - v_starts[1]) < EPS, f"vertical divider mismatch")
        for p in panes:
            h0, h1 = p["layout"]["percent"]["H"]
            _must(abs(h0) < EPS and abs(h1 - 1.0) < EPS, f"vertical split should leave H full: {p['layout']['percent']}")

        chains = sorted([tuple(p["layout"].get("split_path") or []) for p in panes])
        _must(chains == [("V:bottom",), ("V:top",)], f"split_path mismatch: {chains}")
        print("PASS: test_tree_layout_vertical_split")
    finally:
        _close_workspace_quietly(c, wsid)


def test_layout_nested_split(c: cmux, cli: str) -> None:
    """Right pane is itself split vertically → 3 panes total.

    Expected split_paths:
      left pane          : ["H:left"]
      top-right pane     : ["H:right", "V:top"]
      bottom-right pane  : ["H:right", "V:bottom"]
    """
    wsid = _make_fresh_workspace(c)
    try:
        right_panel = c.new_split("right")
        time.sleep(0.15)
        c.focus_surface(right_panel)
        time.sleep(0.05)
        c.new_split("down")
        time.sleep(0.2)
        payload = _wait_for_layout(c, wsid, cli, expected_panes=3)
        panes = all_panes(payload)
        _must(len(panes) == 3, f"expected 3 panes, got {len(panes)}: {[p.get('ref') for p in panes]}")
        for p in panes:
            assert_layout_well_formed(p)

        chains = sorted([tuple(p["layout"].get("split_path") or []) for p in panes])
        _must(
            chains == [("H:left",), ("H:right", "V:bottom"), ("H:right", "V:top")],
            f"nested split_path chains mismatch: {chains}",
        )
        print("PASS: test_tree_layout_nested_split")
    finally:
        _close_workspace_quietly(c, wsid)


def test_content_area_sum(c: cmux, cli: str) -> None:
    """Sum of pane percent areas must equal 1.0 ± tolerance."""
    wsid = _make_fresh_workspace(c)
    try:
        right_panel = c.new_split("right")
        time.sleep(0.15)
        c.focus_surface(right_panel)
        c.new_split("down")
        time.sleep(0.2)
        payload = _wait_for_layout(c, wsid, cli, expected_panes=3)
        panes = all_panes(payload)
        total = sum(percent_area(p) for p in panes)
        _must(abs(total - 1.0) < 0.05, f"pane percent areas should sum to 1.0, got {total}")

        # Pixel sum should match content area pixels (within rounding tolerance).
        ws = all_workspaces(payload)[0]
        content = ws.get("content_area")
        _must(
            isinstance(content, dict) and isinstance(content.get("pixels"), dict),
            f"workspace.content_area.pixels missing: {content}",
        )
        cw = float(content["pixels"]["width"])
        ch = float(content["pixels"]["height"])
        total_px = sum(
            (p["layout"]["pixels"]["H"][1] - p["layout"]["pixels"]["H"][0])
            * (p["layout"]["pixels"]["V"][1] - p["layout"]["pixels"]["V"][0])
            for p in panes
        )
        ratio = total_px / (cw * ch)
        _must(0.95 <= ratio <= 1.05, f"pane pixel area should sum to content area; ratio={ratio}")
        print("PASS: test_tree_content_area_sum")
    finally:
        _close_workspace_quietly(c, wsid)


def test_json_backcompat(c: cmux, cli: str) -> None:
    """JSON shape preserves pre-M8 keys; new keys are additive."""
    payload = run_tree_json(cli, ["--all"])
    _must("windows" in payload, f"top-level missing 'windows': keys={list(payload.keys())}")
    for win in payload["windows"]:
        for key in ("id", "ref", "workspaces"):
            _must(key in win, f"window missing '{key}': {list(win.keys())}")
        for ws in win["workspaces"]:
            for key in ("id", "ref", "panes"):
                _must(key in ws, f"workspace missing '{key}': {list(ws.keys())}")
            # M8 added: content_area (may be null pre-layout).
            _must("content_area" in ws, f"workspace missing 'content_area': {list(ws.keys())}")
            for p in ws["panes"]:
                for key in ("id", "ref", "surfaces", "layout"):
                    _must(key in p, f"pane missing '{key}': {list(p.keys())}")
                # M8 layout sub-object exists; values may be null pre-layout.
                _must(isinstance(p["layout"], dict), f"pane.layout must be dict: {p}")
                for k in ("percent", "pixels", "split_path"):
                    _must(k in p["layout"], f"pane.layout missing '{k}': {p['layout']}")
                # split_path must be a list (may be empty).
                _must(isinstance(p["layout"]["split_path"], list), f"split_path must be list: {p['layout']}")
    print("PASS: test_tree_json_backcompat")


def main() -> int:
    cli = find_cli_binary()
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        test_layout_horizontal_split(c, cli)
        test_layout_vertical_split(c, cli)
        test_layout_nested_split(c, cli)
        test_content_area_sum(c, cli)
        test_json_backcompat(c, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
