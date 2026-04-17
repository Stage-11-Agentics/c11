#!/usr/bin/env python3
"""Spec test: metadata is pruned on surface close and does not leak to new surfaces.

1. Create a surface; declare `terminal_type=claude-code, model=x`.
2. Close the surface.
3. Create a new surface in the same workspace.
4. Assert the new surface's metadata does not carry values from the closed one.
5. Confirm the original surface's get_metadata now returns `surface_not_found`.
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError
from tui_detection_helpers import (
    get_metadata,
    set_agent,
)


def main() -> int:
    with cmux() as client:
        workspace_id = client.new_workspace()
        client.select_workspace(workspace_id)
        time.sleep(0.25)

        surfaces = client.list_surfaces(workspace_id)
        original_id = surfaces[0][1] if surfaces else client.new_surface(panel_type="terminal")
        time.sleep(0.3)

        set_agent(
            client,
            workspace_id=workspace_id,
            surface_id=original_id,
            agent_type="claude-code",
            model="claude-opus-4-7",
        )

        # Sanity: the declaration landed.
        payload = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=original_id,
            include_sources=True,
        )
        if (payload.get("metadata") or {}).get("terminal_type") != "claude-code":
            raise cmuxError(f"declaration did not land: {payload!r}")

        # 2. Close the surface.
        client.close_surface(original_id)
        time.sleep(0.5)

        # 3. Create a new surface in the same workspace.
        new_id = client.new_surface(panel_type="terminal")
        time.sleep(0.5)

        # 4. New surface should not inherit any metadata from the closed one.
        new_payload = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=new_id,
            include_sources=True,
        )
        new_meta = new_payload.get("metadata") or {}
        if new_meta.get("terminal_type") == "claude-code" and new_meta.get("model") == "claude-opus-4-7":
            raise cmuxError(
                f"new surface inherited closed surface's declaration: {new_payload!r}"
            )
        # The `model` key specifically must not leak (the heuristic never writes it).
        if new_meta.get("model") == "claude-opus-4-7":
            raise cmuxError(f"model leaked to new surface: {new_payload!r}")

        # 5. Original surface should be gone.
        try:
            get_metadata(
                client,
                workspace_id=workspace_id,
                surface_id=original_id,
                include_sources=True,
            )
            raise cmuxError("expected surface_not_found for closed surface")
        except cmuxError as exc:
            if "surface_not_found" not in str(exc):
                raise

        client.close_workspace(workspace_id)

    print("OK test_tui_detection_survives_surface_close")
    return 0


if __name__ == "__main__":
    sys.exit(main())
