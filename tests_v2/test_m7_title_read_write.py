#!/usr/bin/env python3
"""M7: Title write/read via surface.set_metadata + surface.get_titlebar_state."""

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

        # Write title with source=explicit.
        title = f"Running smoke tests {stamp}"
        res = c._call(
            "surface.set_metadata",
            {
                "surface_id": surface_id,
                "mode": "merge",
                "source": "explicit",
                "metadata": {"title": title},
            },
        ) or {}
        applied = (res.get("applied") or {}).get("title")
        _must(applied is True, f"set_metadata title not applied: {res}")

        # Read back.
        state = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
        _must(state.get("title") == title, f"title mismatch: {state}")
        _must(state.get("title_source") == "explicit", f"title_source mismatch: {state}")
        _must(isinstance(state.get("title_ts"), (int, float)), f"title_ts missing: {state}")
        _must(
            state.get("sidebar_label") is not None and isinstance(state["sidebar_label"], str),
            f"sidebar_label missing: {state}",
        )

        # Invalid: title > 256 chars returns reserved_key_invalid_type.
        oversize = "x" * 257
        raised = False
        try:
            c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"title": oversize},
                },
            )
        except cmuxError as e:
            raised = "reserved_key_invalid_type" in str(e)
        _must(raised, "Expected reserved_key_invalid_type for title > 256 chars")

        # Invariant: title unchanged after rejection.
        state_after = c._call("surface.get_titlebar_state", {"surface_id": surface_id}) or {}
        _must(state_after.get("title") == title, f"title should be unchanged: {state_after}")

        # Invalid: control char in title rejected.
        raised = False
        try:
            c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"title": "bad\ntitle"},
                },
            )
        except cmuxError as e:
            raised = "reserved_key_invalid_type" in str(e)
        _must(raised, "Expected reserved_key_invalid_type for title with \\n")

        c.close_workspace(ws_id)

    print("PASS: M7 title read/write via set_metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
