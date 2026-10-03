#!/usr/bin/env python3
"""B046: an explicit debug save must replace a recently richer snapshot.

Save a two-panel session, close one panel, change the survivor's metadata, and
exercise the DEBUG-only save-and-load command. The explicit command must write
the current metadata even though an ordinary autosave would hold back the
poorer one-panel snapshot for five minutes.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
METADATA_KEY = "b046_debug_save_marker"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _set_marker(client, workspace_id: str, tab_id: str, value: str) -> None:
    result = client._call("tab.set_metadata", {
        "workspace_id": workspace_id,
        "tab_id": tab_id,
        "mode": "merge",
        "source": "explicit",
        "metadata": {METADATA_KEY: value},
    }) or {}
    _must((result.get("applied") or {}).get(METADATA_KEY) is True,
          f"failed to set {METADATA_KEY}={value!r}: {result}")


def main() -> int:
    workspace_id = ""
    with cmux(SOCKET_PATH) as client:
        try:
            workspace_id = client.new_workspace()
            current = client._call("tab.current", {"workspace_id": workspace_id}) or {}
            survivor_id = str(current.get("tab_id") or "")
            _must(bool(survivor_id), f"new workspace has no current tab: {current}")

            split = client._call("tab.split", {
                "workspace_id": workspace_id,
                "tab_id": survivor_id,
                "direction": "right",
            }) or {}
            closed_id = str(split.get("tab_id") or "")
            _must(bool(closed_id), f"tab.split returned no new tab: {split}")
            tabs = (client._call("tab.list", {"workspace_id": workspace_id}) or {}).get("tabs") or []
            _must(len(tabs) == 2, f"expected two panels before save: {tabs}")

            old_value = f"before-{time.time_ns()}"
            new_value = f"after-{time.time_ns()}"
            _set_marker(client, workspace_id, survivor_id, old_value)
            seeded = client._call("session.save", {"include_scrollback": False}) or {}
            _must(bool(seeded.get("snapshot_path")), f"session.save did not report a snapshot: {seeded}")
            saved_at = time.monotonic()

            client._call("tab.close", {"workspace_id": workspace_id, "tab_id": closed_id})
            remaining = (client._call("tab.list", {"workspace_id": workspace_id}) or {}).get("tabs") or []
            _must([str(row.get("id") or "") for row in remaining] == [survivor_id],
                  f"expected only survivor {survivor_id} after close: {remaining}")
            _must(time.monotonic() - saved_at < 5 * 60, "fixture exceeded the five-minute holdback window")

            _set_marker(client, workspace_id, survivor_id, new_value)
            round_trip = client._call("debug.session.save_and_load", {})
            _must((round_trip or {}).get("ok") is True,
                  f"debug.session.save_and_load did not report success: {round_trip}")

            got = client._call("tab.get_metadata", {
                "workspace_id": workspace_id,
                "tab_id": survivor_id,
                "include_sources": True,
            }) or {}
            metadata = got.get("metadata") or {}
            _must(metadata.get(METADATA_KEY) == new_value,
                  f"debug save/load replayed stale metadata: expected {new_value!r}, got {metadata}")

            print("PASS: B046 explicit debug save replaced the recent richer snapshot")
            return 0
        finally:
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
