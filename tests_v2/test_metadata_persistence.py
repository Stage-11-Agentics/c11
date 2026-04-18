#!/usr/bin/env python3
"""Tier 1 Phase 2: SurfaceMetadataStore on-disk persistence round-trip.

Sets varied metadata on a surface, forces a full save-to-disk and
reload-from-disk round-trip via the DEBUG-only `debug.session.save_and_load`
socket command, then reads the metadata back via `surface.get_metadata`
and asserts every typed value plus every source record survives.

Two variants, selected by the `CMUX_DISABLE_METADATA_PERSIST` env var
in the RUNNING APP (not just the test process):

- Main variant (env var unset in app):
    All metadata + sources round-trip. Sources preserve `.explicit`
    attribution and positive `ts`.

- Rollback variant (env var `=1` in app launch env):
    Snapshot omits `metadata` / `metadataSources`; after save_and_load
    the live store is empty and the on-disk snapshot panels carry
    `metadata: null`.

CI launches the same test file twice — once without the env var, once
with — to cover both paths. Setting the env var on the test process
alone has no effect because the CLI is a separate process from the
running app; the var must reach the app's launch environment.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
# Whether the test process itself knows this run targets the rollback path.
# Note: this only indicates the caller's *expectation*. The running app's
# env is what actually controls the behavior under test.
TEST_EXPECTS_ROLLBACK = os.environ.get("CMUX_DISABLE_METADATA_PERSIST") == "1"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _snapshot_path() -> Path | None:
    """Locate the session snapshot JSON on disk. The filename embeds the
    app's bundle identifier, so glob for `session-*.json` under the
    c11mux application-support directory."""
    app_support = Path.home() / "Library" / "Application Support" / "c11mux"
    if not app_support.exists():
        return None
    candidates = sorted(
        app_support.glob("session-*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


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

        print("PASS: Tier 1 Phase 2 metadata persistence (main variant)")
    finally:
        try:
            c.close_workspace(workspace_id)
        except Exception:
            pass


def _run_rollback_variant(c) -> None:
    workspace_id, surface_id = _fresh_surface(c)
    try:
        c._call(
            "surface.set_metadata",
            {
                "surface_id": surface_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": {"title": "Rollback test", "progress": 0.5},
            },
        )
        c._call("debug.session.save_and_load", {})
        got = c._call(
            "surface.get_metadata",
            {"surface_id": surface_id, "include_sources": True},
        ) or {}
        md = got.get("metadata") or {}
        sources = got.get("metadata_sources") or {}
        _must(md == {}, f"Rollback: expected empty live store, got {md}")
        _must(sources == {}, f"Rollback: expected empty live sources, got {sources}")

        snap_path = _snapshot_path()
        _must(
            snap_path is not None and snap_path.exists(),
            f"Rollback: session snapshot file missing at {snap_path}",
        )
        snap = json.loads(snap_path.read_text())
        checked = 0
        for win in snap.get("windows", []):
            tabs = (win.get("tabManager") or {}).get("workspaces") or []
            for ws in tabs:
                for panel in ws.get("panels") or []:
                    # Rollback contract: the capture path emits nil for both
                    # fields, which JSONEncoder drops from the on-disk blob.
                    _must(
                        "metadata" not in panel or panel.get("metadata") is None,
                        f"Rollback: snapshot panel has metadata: {panel}",
                    )
                    _must(
                        "metadataSources" not in panel
                        or panel.get("metadataSources") is None,
                        f"Rollback: snapshot panel has metadataSources: {panel}",
                    )
                    checked += 1
        _must(checked > 0, "Rollback: snapshot contained no panels to check")
        print("PASS: Tier 1 Phase 2 metadata persistence (rollback variant)")
    finally:
        try:
            c.close_workspace(workspace_id)
        except Exception:
            pass


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        if TEST_EXPECTS_ROLLBACK:
            _run_rollback_variant(client)
        else:
            _run_main_variant(client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
