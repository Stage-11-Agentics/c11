#!/usr/bin/env python3
"""Spec test: all first-class TUIs (claude, codex, kimi, opencode) classify correctly.

For each canonical TUI, prepares a sleep-equivalent binary named after the TUI,
spawns it in its own surface, and verifies the heuristic writes the matching
`terminal_type` with `source == "heuristic"`.
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
    prepare_mock_bin,
    send_ctrl_c_to_surface,
    spawn_mock_in_surface,
    wait_for_terminal_type,
)


CASES = [
    ("claude", "claude-code"),
    ("codex", "codex"),
    ("kimi", "kimi"),
    ("opencode", "opencode"),
]


def main() -> int:
    mocks: list[Path] = []
    try:
        with cmux() as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            for binary_name, expected_type in CASES:
                mock = prepare_mock_bin(binary_name)
                mocks.append(mock)

                surface_id = client.new_surface(panel_type="terminal")
                time.sleep(0.3)

                spawn_mock_in_surface(client, surface_id, mock)
                try:
                    meta, sources = wait_for_terminal_type(
                        client,
                        workspace_id=workspace_id,
                        surface_id=surface_id,
                        expected=expected_type,
                        expected_source="heuristic",
                        timeout=20.0,
                    )
                finally:
                    send_ctrl_c_to_surface(client, surface_id)

                if meta.get("terminal_type") != expected_type:
                    raise cmuxError(
                        f"{binary_name}: expected terminal_type={expected_type}, got {meta!r}"
                    )
                if (sources.get("terminal_type") or {}).get("source") != "heuristic":
                    raise cmuxError(
                        f"{binary_name}: expected source=heuristic, got {sources!r}"
                    )

            client.close_workspace(workspace_id)
    finally:
        for m in mocks:
            cleanup_mock_dir(m)

    print("OK test_tui_detection_all_first_class")
    return 0


if __name__ == "__main__":
    sys.exit(main())
