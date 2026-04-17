#!/usr/bin/env python3
"""M7: Description write/read via surface.set_metadata + surface.get_titlebar_state.

Covers:
- Literal Markdown preservation (parse-on-render, not parse-on-store).
- Auto-expand on first description set.
- --auto-expand=false (via auto_expand=False on socket) suppresses auto-expand.
- Description > 2048 chars → reserved_key_invalid_type.
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


def main() -> int:
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "surface.set_metadata" in methods and "surface.get_titlebar_state" in methods,
            f"Required M2/M7 methods missing. methods={sorted(methods)[:60]}",
        )

        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": ws_id})
        current = c._call("surface.current", {"workspace_id": ws_id}) or {}
        surface_id = str(current.get("surface_id") or "")
        _must(bool(surface_id), f"surface.current returned no surface_id: {current}")

        # Default: new surface is collapsed=true.
        state0 = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
        _must(state0.get("collapsed") is True, f"new surface should be collapsed: {state0}")

        # Write description with literal Markdown.
        desc = f"Running **10 shards** in parallel; reports to `lat-{stamp}`."
        res = c._call(
            "surface.set_metadata",
            {
                "surface_id": surface_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": {"description": desc},
            },
        ) or {}
        applied = (res.get("applied") or {}).get("description")
        _must(applied is True, f"set_metadata description not applied: {res}")

        # Read back literal string (no markdown parsing).
        state = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
        _must(state.get("description") == desc, f"description mismatch: {state}")
        _must(state.get("description_source") == "explicit", f"description_source mismatch: {state}")
        _must(isinstance(state.get("description_ts"), (int, float)), f"description_ts missing: {state}")

        # Auto-expand: first description set flips collapsed → false.
        _must(state.get("collapsed") is False, f"first description set should auto-expand: {state}")

        # Second surface: test auto_expand=false suppression.
        created2 = c._call("workspace.create") or {}
        ws_id2 = str(created2.get("workspace_id") or "")
        _must(bool(ws_id2), f"workspace.create returned no workspace_id: {created2}")
        c._call("workspace.select", {"workspace_id": ws_id2})
        current2 = c._call("surface.current", {"workspace_id": ws_id2}) or {}
        surface_id2 = str(current2.get("surface_id") or "")

        res2 = c._call(
            "surface.set_metadata",
            {
                "surface_id": surface_id2,
                "mode": "merge",
                "source": "explicit",
                "metadata": {"description": "quiet note"},
                "auto_expand": False,
            },
        ) or {}
        _must(
            (res2.get("applied") or {}).get("description") is True,
            f"description with auto_expand=false not applied: {res2}",
        )
        state2 = c._call("surface.get_titlebar_state", {"surface_id": surface_id2}) or {}
        _must(
            state2.get("collapsed") is True,
            f"auto_expand=false should keep collapsed: {state2}",
        )

        # description > 2048 chars → reserved_key_invalid_type.
        oversize = "x" * 2049
        raised = False
        try:
            c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"description": oversize},
                },
            )
        except cmuxError as e:
            raised = "reserved_key_invalid_type" in str(e)
        _must(raised, "Expected reserved_key_invalid_type for description > 2048 chars")

        # Description from prior set still intact.
        state_after = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
        _must(state_after.get("description") == desc, f"description should be unchanged: {state_after}")

        c.close_workspace(ws_id)
        c.close_workspace(ws_id2)

    print("PASS: M7 description read/write + auto-expand gating")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
