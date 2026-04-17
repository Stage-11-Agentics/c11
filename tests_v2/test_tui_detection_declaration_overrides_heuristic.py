#!/usr/bin/env python3
"""Spec test: declaration overrides heuristic; heuristic does not clobber declaration.

1. Spawn a `claude` mock; wait for heuristic to classify terminal_type=claude-code.
2. `set_agent(terminal_type=codex, model=moonshot-v2)` with source=declare.
3. Assert terminal_type == "codex", source == "declare".
4. Kill the claude mock (Ctrl-C) to end the foreground process; wait 15s.
5. Assert terminal_type == "codex" still (heuristic's lower precedence cannot
   overwrite a declared value).
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
    set_agent,
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
            surface_id = surfaces[0][1] if surfaces else client.new_surface(panel_type="terminal")
            time.sleep(0.3)

            spawn_mock_in_surface(client, surface_id, mock)
            wait_for_terminal_type(
                client,
                workspace_id=workspace_id,
                surface_id=surface_id,
                expected="claude-code",
                expected_source="heuristic",
                timeout=20.0,
            )

            set_agent(
                client,
                workspace_id=workspace_id,
                surface_id=surface_id,
                agent_type="codex",
                model="moonshot-v2",
            )

            meta, sources = wait_for_terminal_type(
                client,
                workspace_id=workspace_id,
                surface_id=surface_id,
                expected="codex",
                expected_source="declare",
                timeout=5.0,
            )
            if meta.get("model") != "moonshot-v2":
                raise cmuxError(f"expected model=moonshot-v2, got {meta!r}")

            # End the heuristic's target process and wait long enough for a
            # periodic sweep. The heuristic must not downgrade the declared value.
            send_ctrl_c_to_surface(client, surface_id)
            time.sleep(15.0)

            final = get_metadata(
                client,
                workspace_id=workspace_id,
                surface_id=surface_id,
                include_sources=True,
            )
            if (final.get("metadata") or {}).get("terminal_type") != "codex":
                raise cmuxError(f"heuristic clobbered declaration: {final!r}")
            if ((final.get("metadata_sources") or {}).get("terminal_type") or {}).get("source") != "declare":
                raise cmuxError(f"expected source=declare, got {final!r}")

            client.close_workspace(workspace_id)
    finally:
        cleanup_mock_dir(mock)

    print("OK test_tui_detection_declaration_overrides_heuristic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
