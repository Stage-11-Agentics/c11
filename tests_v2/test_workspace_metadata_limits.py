#!/usr/bin/env python3
"""workspace.set_metadata rejects oversize values, bad keys, and over-capacity writes."""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


MAX_DESCRIPTION = 2048
MAX_ICON = 32
MAX_CUSTOM_KEY = 64
MAX_CUSTOM_VALUE = 1024
MAX_CUSTOM_KEYS = 32


def _expect_error(client, method, params, *, code_prefix: str = "") -> str:
    try:
        client._call(method, params)
    except cmuxError as e:
        msg = str(e)
        if code_prefix and not msg.startswith(code_prefix):
            raise cmuxError(f"Expected error starting with {code_prefix!r}, got: {msg}")
        return msg
    raise cmuxError(f"{method} with {params!r} should have failed but succeeded")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        workspace_id = client.new_workspace()
        try:
            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "description",
                    "value": "a" * (MAX_DESCRIPTION + 1),
                },
                code_prefix="value_too_long",
            )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "icon",
                    "value": "x" * (MAX_ICON + 1),
                },
                code_prefix="value_too_long",
            )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "my key",
                    "value": "hi",
                },
                code_prefix="invalid_key",
            )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "キー",
                    "value": "hi",
                },
                code_prefix="invalid_key",
            )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "a" * (MAX_CUSTOM_KEY + 1),
                    "value": "hi",
                },
                code_prefix="invalid_key",
            )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "note",
                    "value": "a" * (MAX_CUSTOM_VALUE + 1),
                },
                code_prefix="value_too_long",
            )

            # Fill the custom-key budget to the cap, then try one more.
            batch = {f"k_{i}": "v" for i in range(MAX_CUSTOM_KEYS)}
            ok = client._call(
                "workspace.set_metadata",
                {"workspace_id": workspace_id, "metadata": batch},
            )
            stored = ok.get("metadata") or {}
            if len([k for k in stored if k not in ("description", "icon")]) != MAX_CUSTOM_KEYS:
                raise cmuxError(
                    f"Expected exactly {MAX_CUSTOM_KEYS} custom keys after batch fill: {stored!r}"
                )

            _expect_error(
                client,
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "over_the_limit",
                    "value": "x",
                },
                code_prefix="too_many_keys",
            )

            # Canonical keys still allowed past the custom cap (they don't count).
            ok_canonical = client._call(
                "workspace.set_metadata",
                {
                    "workspace_id": workspace_id,
                    "key": "description",
                    "value": "ok",
                },
            )
            assert (ok_canonical.get("metadata") or {}).get("description") == "ok"
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: workspace.set_metadata enforces key/value/capacity limits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
