#!/usr/bin/env python3
"""Spec test: the TUI heuristic classifies a foreground `claude` process.

Copies /bin/sleep -> `claude` in a scratch dir, spawns it inside a fresh
surface, and waits for `terminal_type == "claude-code"` with
`metadata_sources.terminal_type.source == "heuristic"`.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError
from tui_detection_helpers import (
    cleanup_mock_dir,
    get_metadata,
    prepare_mock_bin,
    send_ctrl_c_to_surface,
    spawn_mock_in_surface,
    wait_for_terminal_type,
)


def main() -> int:
    mock = prepare_mock_bin("claude")
    try:
        with cmux() as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            surfaces = client.list_surfaces(workspace_id)
            if not surfaces:
                surface_id = client.new_surface(panel_type="terminal")
                time.sleep(0.3)
            else:
                surface_id = surfaces[0][1]

            spawn_mock_in_surface(client, surface_id, mock)
            try:
                meta, sources = wait_for_terminal_type(
                    client,
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                    expected="claude-code",
                    expected_source="heuristic",
                    timeout=20.0,
                )
            finally:
                send_ctrl_c_to_surface(client, surface_id)

            if meta.get("terminal_type") != "claude-code":
                raise cmuxError(f"expected terminal_type=claude-code, got {meta!r}")
            if (sources.get("terminal_type") or {}).get("source") != "heuristic":
                raise cmuxError(f"expected source=heuristic, got {sources!r}")

            # Cleanup.
            client.close_workspace(workspace_id)
    finally:
        cleanup_mock_dir(mock)

    print("OK test_tui_detection_claude_heuristic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
