#!/usr/bin/env python3
"""Tier 1 Phase 2: SurfaceMetadataStore on-disk persistence round-trip.

Sets varied metadata on a surface, forces a full save-to-disk and
reload-from-disk round-trip via the DEBUG-only `debug.session.save_and_load`
socket command, then reads the metadata back via `surface.get_metadata`
and asserts every typed value plus every source record survives.

All metadata + sources round-trip. Sources preserve `.explicit`
attribution and positive `ts`.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _fresh_surface(c) -> tuple[str, str]:
    workspace_id = c.new_workspace()
    current = c._call("surface.current", {"workspace_id": workspace_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return workspace_id, surface_id


def _run_main_variant(c) -> None:
    workspace_id, surface_id = _fresh_surface(c)
    try:
        # Write varied types so the bridge path gets exercised end to end.
        metadata_in: dict[str, Any] = {
            "title": f"Phase 2 smoke {int(time.time())}",
            "progress": 0.42,
            "active": True,
            "tags": {"team": "platform", "count": 3, "flags": ["a", "b"]},
        }
        set_res = c._call(
            "surface.set_metadata",
            {
                "surface_id": surface_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": metadata_in,
            },
        ) or {}
        applied = set_res.get("applied") or {}
        for k in metadata_in:
            _must(applied.get(k) is True, f"set_metadata didn't apply {k}: {set_res}")

        # Force actual on-disk round-trip.
        rt_res = c._call("debug.session.save_and_load", {})
        _must(rt_res is not None, "debug.session.save_and_load returned no result")

        got = c._call(
            "surface.get_metadata",
            {"surface_id": surface_id, "include_sources": True},
        ) or {}
        md = got.get("metadata") or {}
        sources = got.get("metadata_sources") or {}

        _must(md.get("title") == metadata_in["title"], f"title: {md}")
        _must(
            isinstance(md.get("progress"), (int, float))
            and abs(float(md["progress"]) - 0.42) < 1e-9,
            f"progress: {md}",
        )
        _must(md.get("active") is True, f"active: {md}")
        tags = md.get("tags") or {}
        _must(tags.get("team") == "platform", f"nested team: {tags}")
        # Numbers round-trip as floats per the PersistedJSONValue contract.
        _must(
            isinstance(tags.get("count"), (int, float))
            and abs(float(tags["count"]) - 3.0) < 1e-9,
            f"nested count: {tags}",
        )
        flags = tags.get("flags") or []
        _must(list(flags) == ["a", "b"], f"nested flags: {tags}")

        # Every key must carry its source + ts sidecar.
        for k in metadata_in:
            src = sources.get(k) or {}
            _must(
                src.get("source") == "explicit",
                f"{k} source should be 'explicit' after round-trip: {src}",
            )
            ts = src.get("ts")
            _must(
                isinstance(ts, (int, float)) and ts > 0,
                f"{k} ts should be positive: {src}",
            )

        print("PASS: Tier 1 Phase 2 metadata persistence")
    finally:
        try:
            c.close_workspace(workspace_id)
        except Exception:
            pass


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        _run_main_variant(client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
