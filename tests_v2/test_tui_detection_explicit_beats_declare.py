#!/usr/bin/env python3
"""Spec test: explicit > declare in the precedence ladder.

1. set_agent(terminal_type=codex) — source=declare.
2. set_metadata({terminal_type: claude-code}) — source=explicit.
3. Assert final value = claude-code, source=explicit.
4. set_agent(terminal_type=kimi) — should be rejected (`applied: false` in
   the write response) and the stored value must remain claude-code.
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
    set_metadata,
)


def main() -> int:
    with cmux() as client:
        workspace_id = client.new_workspace()
        client.select_workspace(workspace_id)
        time.sleep(0.25)

        surfaces = client.list_surfaces(workspace_id)
        surface_id = surfaces[0][1] if surfaces else client.new_surface(panel_type="terminal")
        time.sleep(0.3)

        # 1. Declare codex.
        set_agent(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            agent_type="codex",
        )

        # 2. Explicit overrides to claude-code.
        explicit_result = set_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            partial={"terminal_type": "claude-code"},
            source="explicit",
            mode="merge",
        )
        if (explicit_result.get("applied") or {}).get("terminal_type") is not True:
            raise cmuxError(f"explicit set_metadata should apply, got {explicit_result!r}")

        # 3. Assert final value = claude-code, source=explicit.
        payload = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            include_sources=True,
        )
        meta = payload.get("metadata") or {}
        sources = payload.get("metadata_sources") or {}
        if meta.get("terminal_type") != "claude-code":
            raise cmuxError(f"expected terminal_type=claude-code, got {meta!r}")
        if (sources.get("terminal_type") or {}).get("source") != "explicit":
            raise cmuxError(f"expected source=explicit, got {sources!r}")

        # 4. Declare kimi — should be rejected; explicit still wins.
        declare_after = set_agent(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            agent_type="kimi",
        )
        if (declare_after.get("applied") or {}).get("terminal_type") is not False:
            raise cmuxError(
                f"declare after explicit should be rejected, got {declare_after!r}"
            )
        reason = (declare_after.get("reasons") or {}).get("terminal_type")
        if reason != "lower_precedence":
            raise cmuxError(
                f"expected reason=lower_precedence, got {declare_after!r}"
            )

        final = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            include_sources=True,
        )
        if (final.get("metadata") or {}).get("terminal_type") != "claude-code":
            raise cmuxError(f"explicit value was clobbered: {final!r}")

        client.close_workspace(workspace_id)

    print("OK test_tui_detection_explicit_beats_declare")
    return 0


if __name__ == "__main__":
    sys.exit(main())
