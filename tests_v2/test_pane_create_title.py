#!/usr/bin/env python3
"""CMUX-11 Phase 2: area.create / tab.split --title seeding.

Verifies that when `area.create` (and `tab.split`) is called with a
`title` parameter, the new pane's metadata is seeded with
`{title: <value>, source: "explicit"}` atomically with the pane id
becoming valid — no window between "pane exists" and "title set."

Calling `area.create` without `title` produces a fresh pane with empty
metadata (matching Phase 1 default).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _test_pane_create_without_title(c: cmux) -> None:
    workspace_id = c.new_workspace()
    try:
        res = c._call("area.create", {
            "workspace_id": workspace_id,
            "direction": "right",
        }) or {}
        pane_id = res.get("area_id")
        _must(bool(pane_id), f"area.create returned no area_id: {res}")

        got = c._call("area.get_metadata", {
            "workspace_id": workspace_id,
            "area_id": str(pane_id),
        }) or {}
        _must(got.get("metadata") == {},
              f"pane without --title should have empty metadata: {got}")
    finally:
        c._call("workspace.close", {"workspace_id": workspace_id})


def _test_pane_create_with_title(c: cmux) -> None:
    workspace_id = c.new_workspace()
    try:
        title = "Parent :: Pane-With-Seed"
        res = c._call("area.create", {
            "workspace_id": workspace_id,
            "direction": "right",
            "title": title,
        }) or {}
        pane_id = res.get("area_id")
        _must(bool(pane_id), f"area.create returned no area_id: {res}")

        got = c._call("area.get_metadata", {
            "workspace_id": workspace_id,
            "area_id": str(pane_id),
            "include_sources": True,
        }) or {}
        md = got.get("metadata", {})
        _must(md.get("title") == title,
              f"seeded title missing: md={md}")

        src = got.get("metadata_sources", {}).get("title", {})
        _must(src.get("source") == "explicit",
              f"seeded title source should be explicit, got: {src}")
    finally:
        c._call("workspace.close", {"workspace_id": workspace_id})


def _test_surface_split_with_title(c: cmux) -> None:
    workspace_id = c.new_workspace()
    try:
        title = "Parent :: Split-Seed"
        res = c._call("tab.split", {
            "workspace_id": workspace_id,
            "direction": "down",
            "title": title,
        }) or {}
        pane_id = res.get("area_id")
        _must(bool(pane_id), f"tab.split returned no area_id: {res}")

        got = c._call("area.get_metadata", {
            "workspace_id": workspace_id,
            "area_id": str(pane_id),
        }) or {}
        _must(got.get("metadata", {}).get("title") == title,
              f"tab.split title seed missing: {got}")
    finally:
        c._call("workspace.close", {"workspace_id": workspace_id})


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        _test_pane_create_without_title(c)
        _test_pane_create_with_title(c)
        _test_surface_split_with_title(c)

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
