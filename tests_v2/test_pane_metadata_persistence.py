#!/usr/bin/env python3
"""CMUX-11 Phase 3: PaneMetadataStore on-disk persistence round-trip.

Sets pane metadata via `pane.set_metadata`, forces a full save-to-disk +
reload-from-disk cycle via the DEBUG-only `debug.session.save_and_load`
socket command, then reads the metadata back via `pane.get_metadata` and
asserts every value plus every source attribution survived.

Mirrors `test_metadata_persistence.py` but on the pane axis. Two variants,
selected by the `CMUX_DISABLE_METADATA_PERSIST` env var **in the running
app**:

- Main variant (env var unset in the app):
    Pane metadata + sources round-trip; the on-disk snapshot's pane layout
    leaves carry `id`, `metadata`, and `metadataSources`.

- Rollback variant (env var `=1` in the app launch env):
    Both the live store and the on-disk snapshot omit pane metadata.

CI runs the same test file twice — once without the env var, once with —
to cover both paths. Setting the env var on the test process alone has no
effect because the CLI is a separate process from the app.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterable

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
TEST_EXPECTS_ROLLBACK = os.environ.get("CMUX_DISABLE_METADATA_PERSIST") == "1"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _snapshot_path() -> Path | None:
    app_support = Path.home() / "Library" / "Application Support" / "c11mux"
    if not app_support.exists():
        return None
    candidates = sorted(
        app_support.glob("session-*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def _fresh_workspace_and_pane(c: cmux) -> tuple[str, str]:
    workspace_id = c.new_workspace()
    split_res = c._call("surface.split", {"workspace_id": workspace_id, "direction": "right"}) or {}
    pane_id = split_res.get("pane_id")
    _must(bool(pane_id), f"surface.split returned no pane_id: {split_res}")
    return workspace_id, str(pane_id)


def _iter_pane_layout_nodes(node: Any) -> Iterable[dict]:
    """Walk a SessionWorkspaceLayoutSnapshot tree, yielding leaf pane dicts."""
    if not isinstance(node, dict):
        return
    node_type = node.get("type")
    if node_type == "pane":
        pane = node.get("pane")
        if isinstance(pane, dict):
            yield pane
        return
    if node_type == "split":
        split = node.get("split") or {}
        for child_key in ("first", "second"):
            child = split.get(child_key)
            yield from _iter_pane_layout_nodes(child)


def _run_main_variant(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)
    try:
        # Mix of types so the bridge gets exercised.
        title_value = f"Parent :: Phase3 smoke {int(time.time())}"
        metadata_in: dict[str, Any] = {
            "title": title_value,
            "progress": 0.42,
            "active": True,
            "tags": {"team": "platform", "rungs": ["parent", "phase3"]},
        }
        set_res = c._call(
            "pane.set_metadata",
            {
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": metadata_in,
            },
        ) or {}
        applied = set_res.get("applied") or {}
        for k in metadata_in:
            _must(applied.get(k) is True, f"pane.set_metadata didn't apply {k}: {set_res}")

        # Force on-disk round-trip (clears live PaneMetadataStore, then replays
        # from the persisted snapshot).
        rt_res = c._call("debug.session.save_and_load", {})
        _must(rt_res is not None, "debug.session.save_and_load returned no result")

        got = c._call(
            "pane.get_metadata",
            {
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "include_sources": True,
            },
        ) or {}
        md = got.get("metadata") or {}
        sources = got.get("metadata_sources") or {}

        _must(md.get("title") == title_value, f"title round-trip wrong: {md}")
        _must(
            isinstance(md.get("progress"), (int, float))
            and abs(float(md["progress"]) - 0.42) < 1e-9,
            f"progress round-trip wrong: {md}",
        )
        _must(md.get("active") is True, f"active round-trip wrong: {md}")
        tags = md.get("tags") or {}
        _must(tags.get("team") == "platform", f"nested team wrong: {tags}")
        rungs = tags.get("rungs") or []
        _must(list(rungs) == ["parent", "phase3"], f"nested rungs wrong: {tags}")

        for k in metadata_in:
            src = sources.get(k) or {}
            _must(
                src.get("source") == "explicit",
                f"{k} source should be 'explicit' after round-trip: {src}",
            )
            ts = src.get("ts")
            _must(
                isinstance(ts, (int, float)) and ts > 0,
                f"{k} ts should be positive after round-trip: {src}",
            )

        # Spot-check the on-disk snapshot: at least one pane layout leaf
        # should carry `id` + `metadata` + `metadataSources` for our pane.
        snap_path = _snapshot_path()
        _must(
            snap_path is not None and snap_path.exists(),
            f"session snapshot file missing at {snap_path}",
        )
        snap = json.loads(snap_path.read_text())
        found_pane = False
        for win in snap.get("windows", []):
            for ws in (win.get("tabManager") or {}).get("workspaces") or []:
                for pane in _iter_pane_layout_nodes(ws.get("layout")):
                    if pane.get("id") == pane_id:
                        found_pane = True
                        pane_md = pane.get("metadata") or {}
                        pane_sources = pane.get("metadataSources") or {}
                        _must(
                            pane_md.get("title") == title_value,
                            f"snapshot pane metadata title wrong: {pane_md}",
                        )
                        _must(
                            (pane_sources.get("title") or {}).get("source") == "explicit",
                            f"snapshot pane source wrong: {pane_sources}",
                        )
        _must(found_pane, f"snapshot did not contain our pane id={pane_id}")

        print("PASS: CMUX-11 Phase 3 pane metadata persistence (main variant)")
    finally:
        try:
            c.close_workspace(workspace_id)
        except Exception:
            pass


def _run_rollback_variant(c: cmux) -> None:
    workspace_id, pane_id = _fresh_workspace_and_pane(c)
    try:
        c._call(
            "pane.set_metadata",
            {
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": {"title": "Rollback", "progress": 0.5},
            },
        )
        c._call("debug.session.save_and_load", {})
        got = c._call(
            "pane.get_metadata",
            {
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "include_sources": True,
            },
        ) or {}
        md = got.get("metadata") or {}
        sources = got.get("metadata_sources") or {}
        _must(md == {}, f"Rollback: expected empty pane store, got {md}")
        _must(sources == {}, f"Rollback: expected empty pane sources, got {sources}")

        snap_path = _snapshot_path()
        _must(
            snap_path is not None and snap_path.exists(),
            f"Rollback: session snapshot file missing at {snap_path}",
        )
        snap = json.loads(snap_path.read_text())
        checked = 0
        for win in snap.get("windows", []):
            for ws in (win.get("tabManager") or {}).get("workspaces") or []:
                for pane in _iter_pane_layout_nodes(ws.get("layout")):
                    _must(
                        "metadata" not in pane or pane.get("metadata") is None,
                        f"Rollback: snapshot pane has metadata: {pane}",
                    )
                    _must(
                        "metadataSources" not in pane
                        or pane.get("metadataSources") is None,
                        f"Rollback: snapshot pane has metadataSources: {pane}",
                    )
                    checked += 1
        _must(checked > 0, "Rollback: snapshot contained no pane leaves to check")
        print("PASS: CMUX-11 Phase 3 pane metadata persistence (rollback variant)")
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
