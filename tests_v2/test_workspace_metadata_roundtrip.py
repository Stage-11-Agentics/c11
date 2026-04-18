#!/usr/bin/env python3
"""workspace.set_metadata / workspace.get_metadata / workspace.clear_metadata roundtrip."""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        workspace_id = client.new_workspace()
        try:
            set_payload = client._call(
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "description",
                    "value": "Backend refactor",
                },
            )
            metadata = set_payload.get("metadata") or {}
            _must(
                metadata.get("description") == "Backend refactor",
                f"set_metadata should return the new description: {set_payload!r}",
            )

            get_payload = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id},
            )
            stored = get_payload.get("metadata") or {}
            _must(
                stored.get("description") == "Backend refactor",
                f"get_metadata should return the stored description: {get_payload!r}",
            )

            _ = client._call(
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "metadata": {"icon": "🦊", "project.tag": "alpha"},
                },
            )
            get_all = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id},
            )
            stored = get_all.get("metadata") or {}
            _must(stored.get("description") == "Backend refactor", f"description persisted after subsequent write: {stored!r}")
            _must(stored.get("icon") == "🦊", f"icon stored via batch write: {stored!r}")
            _must(stored.get("project.tag") == "alpha", f"custom key stored: {stored!r}")

            get_single = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id, "key": "icon"},
            )
            _must(get_single.get("value") == "🦊", f"single-key get should expose 'value': {get_single!r}")

            # Delete a single key via value=null.
            _ = client._call(
                "workspace.set_metadata",
                {"workspace_id": workspace_id, "key": "project.tag", "value": None},
            )
            after_delete = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id},
            )
            after = after_delete.get("metadata") or {}
            _must("project.tag" not in after, f"project.tag should be deleted: {after!r}")
            _must(after.get("description") == "Backend refactor", f"description survives delete: {after!r}")

            # Clear a specific key.
            _ = client._call(
                "workspace.clear_metadata",
                {"workspace_id": workspace_id, "keys": ["icon"]},
            )
            after_clear_one = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id},
            )
            remaining = after_clear_one.get("metadata") or {}
            _must("icon" not in remaining, f"icon should be cleared: {remaining!r}")

            # Clear all.
            _ = client._call(
                "workspace.clear_metadata",
                {"workspace_id": workspace_id},
            )
            after_all = client._call(
                "workspace.get_metadata",
                {"workspace_id": workspace_id},
            )
            _must(
                (after_all.get("metadata") or {}) == {},
                f"clear_metadata without keys should empty the store: {after_all!r}",
            )
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: workspace metadata roundtrip (set/get/clear) via socket")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
