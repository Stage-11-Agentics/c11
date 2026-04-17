#!/usr/bin/env python3
"""Spec test: a surface running just the login shell classifies as "shell".

Creates a fresh terminal surface, waits for the heuristic to scan its TTY, and
asserts `terminal_type == "shell"` with `source == "heuristic"`. The canonical
shells recognized by the classifier are zsh, bash, fish, sh, dash.
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError
from tui_detection_helpers import wait_for_terminal_type


def main() -> int:
    with cmux() as client:
        workspace_id = client.new_workspace()
        client.select_workspace(workspace_id)
        time.sleep(0.25)

        surfaces = client.list_surfaces(workspace_id)
        surface_id = surfaces[0][1] if surfaces else client.new_surface(panel_type="terminal")
        time.sleep(0.3)

        meta, sources = wait_for_terminal_type(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            expected="shell",
            expected_source="heuristic",
            timeout=20.0,
        )
        if meta.get("terminal_type") != "shell":
            raise cmuxError(f"expected terminal_type=shell, got {meta!r}")
        if (sources.get("terminal_type") or {}).get("source") != "heuristic":
            raise cmuxError(f"expected source=heuristic, got {sources!r}")

        client.close_workspace(workspace_id)

    print("OK test_tui_detection_shell_fallback")
    return 0


if __name__ == "__main__":
    sys.exit(main())
