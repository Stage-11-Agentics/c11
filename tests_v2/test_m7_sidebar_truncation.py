#!/usr/bin/env python3
"""M7: Sidebar truncation rule projected by surface.get_titlebar_state.sidebar_label.

Covers the four normative cases from the spec's test surface:
  - Long, token-boundary cut (last space before char 25 → "... the full smoke…").
  - Long, no-space hard-cut at cluster 24 + ellipsis.
  - Short, no truncation.
  - Whitespace trim + internal collapse.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _set_title(c, surface_id: str, title: str) -> None:
    res = c._call(
        "surface.set_metadata",
        {
            "surface_id": surface_id,
            "mode": "merge",
            "source": "explicit",
            "metadata": {"title": title},
        },
    ) or {}
    _must(
        (res.get("applied") or {}).get("title") is True,
        f"set_metadata did not apply title={title!r}: {res}",
    )


def _sidebar(c, surface_id: str) -> str:
    state = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
    return str(state.get("sidebar_label") or "")


def _fresh_surface(c) -> tuple[str, str]:
    created = c._call("workspace.create") or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    c._call("workspace.select", {"workspace_id": ws_id})
    current = c._call("surface.current", {"workspace_id": ws_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return ws_id, surface_id


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods and "surface.get_titlebar_state" in methods,
            f"Required M2/M7 methods missing. methods={sorted(methods)[:60]}",
        )

        # Case 1: token-boundary cut.
        ws_id, surface_id = _fresh_surface(c)
        try:
            _set_title(c, surface_id, "Running the full smoke suite across ten shards")
            label = _sidebar(c, surface_id)
            _must(
                label == "Running the full smoke\u2026",
                f"expected 'Running the full smoke…'; got {label!r}",
            )
        finally:
            c.close_workspace(ws_id)

        # Case 2: hard-cut fallback (no spaces in first 25).
        ws_id, surface_id = _fresh_surface(c)
        try:
            _set_title(c, surface_id, "ReallyLongContainerizedWorkflowRunner")
            label = _sidebar(c, surface_id)
            _must(
                label == "ReallyLongContainerizedW\u2026",
                f"expected 'ReallyLongContainerizedW…'; got {label!r}",
            )
            # Invariants: 24 chars + 1 ellipsis cluster.
            _must(len(label) == 25, f"sidebar_label length should be 25 clusters, got {len(label)}: {label!r}")
        finally:
            c.close_workspace(ws_id)

        # Case 3: short title passes through unchanged.
        ws_id, surface_id = _fresh_surface(c)
        try:
            _set_title(c, surface_id, "Short")
            label = _sidebar(c, surface_id)
            _must(label == "Short", f"expected 'Short'; got {label!r}")
        finally:
            c.close_workspace(ws_id)

        # Case 4: trim + collapse internal whitespace (still ≤ 25 after collapse).
        ws_id, surface_id = _fresh_surface(c)
        try:
            _set_title(c, surface_id, "  Padded   inner   spaces  ")
            label = _sidebar(c, surface_id)
            _must(
                label == "Padded inner spaces",
                f"expected 'Padded inner spaces'; got {label!r}",
            )
        finally:
            c.close_workspace(ws_id)

    print("PASS: M7 sidebar truncation (token boundary, hard-cut, short, collapse)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
