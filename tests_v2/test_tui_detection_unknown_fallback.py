#!/usr/bin/env python3
"""Spec test: unknown foreground processes classify as terminal_type="unknown".

Copies /bin/sleep as an arbitrary kebab-case binary the classifier does not
recognize and asserts the heuristic writes `terminal_type == "unknown"` with
`source == "heuristic"`.
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError
from tui_detection_helpers import (
    cleanup_mock_dir,
    prepare_mock_bin,
    send_ctrl_c_to_surface,
    spawn_mock_in_surface,
    wait_for_terminal_type,
)


def main() -> int:
    mock = prepare_mock_bin("my-custom-tool")
    try:
        with cmux() as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            surfaces = client.list_surfaces(workspace_id)
            surface_id = surfaces[0][1] if surfaces else client.new_surface(panel_type="terminal")
            time.sleep(0.3)

            spawn_mock_in_surface(client, surface_id, mock)
            try:
                meta, sources = wait_for_terminal_type(
                    client,
                    workspace_id=workspace_id,
                    surface_id=surface_id,
                    expected="unknown",
                    expected_source="heuristic",
                    timeout=20.0,
                )
            finally:
                send_ctrl_c_to_surface(client, surface_id)

            if meta.get("terminal_type") != "unknown":
                raise cmuxError(f"expected terminal_type=unknown, got {meta!r}")
            if (sources.get("terminal_type") or {}).get("source") != "heuristic":
                raise cmuxError(f"expected source=heuristic, got {sources!r}")

            client.close_workspace(workspace_id)
    finally:
        cleanup_mock_dir(mock)

    print("OK test_tui_detection_unknown_fallback")
    return 0


if __name__ == "__main__":
    sys.exit(main())
