#!/usr/bin/env python3
"""Spec test: env-var declaration path.

Per spec, the wrapper reads CMUX_AGENT_TYPE/_MODEL/_TASK/_ROLE once at
surface-child-process start and calls `cmux set-agent`. In the interim
the test uses a send-text stand-in:

    cmux send-text 'cmux set-agent --type claude-code --model claude-opus-4-7\n'

and asserts both keys land with source=declare within a few seconds.
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

        # Stand-in for the wrapper: drive the declaration through the shell.
        # Uses explicit --surface so the CLI inside the surface targets its own surface.
        cmd = (
            f"cmux set-agent --type claude-code --model claude-opus-4-7 "
            f"--surface {surface_id}\n"
        )
        client._call("surface.send_text", {"surface_id": surface_id, "text": cmd})

        meta, sources = wait_for_terminal_type(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            expected="claude-code",
            expected_source="declare",
            timeout=10.0,
        )
        if meta.get("model") != "claude-opus-4-7":
            raise cmuxError(f"expected model=claude-opus-4-7, got {meta!r}")
        if (sources.get("model") or {}).get("source") != "declare":
            raise cmuxError(f"expected model source=declare, got {sources!r}")

        client.close_workspace(workspace_id)

    print("OK test_tui_detection_env_declaration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
