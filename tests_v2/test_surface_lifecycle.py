#!/usr/bin/env python3
"""C11-25 surface lifecycle smoke test.

Validates that the canonical `lifecycle_state` metadata key is wired
through the surface.set_metadata / surface.get_metadata socket path:

  - Accepted values: active, throttled, hibernated.
  - Rejected values: 'suspended' (reserved-only per review fix I4),
    anything else outside the enum, and any non-string.
  - Round-trips through the metadata store and is readable via
    surface.get_metadata.

Does NOT exercise the runtime hibernate dispatch end-to-end — that
requires triggering the operator menu, which lives outside the socket
PTY reach and is covered by the c11Tests Swift unit tests + a tagged-
build computer-use scenario in the Validate phase.

Per CLAUDE.md, never run locally — CI / VM only.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

# `suspended` is defined in the enum but rejected at the validator
# (review fix I4) — it has no runtime consumer in C11-25 and accepting
# it would let an external writer park a value the runtime ignores.
LEGAL_STATES = ["active", "throttled", "hibernated"]
RESERVED_STATES = ["suspended"]


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _fresh_surface(c) -> tuple[str, str]:
    workspace_id = c.new_workspace()
    current = c._call("surface.current", {"workspace_id": workspace_id}) or {}
    surface_id = str(current.get("surface_id") or "")
    _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
    return workspace_id, surface_id


def _run_legal_values(c) -> None:
    workspace_id, surface_id = _fresh_surface(c)
    try:
        for state in LEGAL_STATES:
            res = (
                c._call(
                    "surface.set_metadata",
                    {
                        "surface_id": surface_id,
                        "mode": "merge",
                        "source": "explicit",
                        "metadata": {"lifecycle_state": state},
                    },
                )
                or {}
            )
            applied = res.get("applied") or {}
            _must(
                applied.get("lifecycle_state") is True,
                f"lifecycle_state={state} should be accepted: {res}",
            )

            got = (
                c._call("surface.get_metadata", {"surface_id": surface_id})
                or {}
            )
            md = got.get("metadata") or {}
            _must(
                md.get("lifecycle_state") == state,
                f"lifecycle_state should round-trip as {state!r}: {md}",
            )
    finally:
        c.close_workspace(workspace_id)


def _run_rejects_unknown_value(c) -> None:
    workspace_id, surface_id = _fresh_surface(c)
    try:
        # The validator rejects anything outside the four enum values.
        try:
            c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"lifecycle_state": "frozen"},
                },
            )
        except cmuxError as err:
            msg = str(err)
            _must(
                "reserved_key_invalid_type" in msg or "lifecycle_state" in msg,
                f"unknown value should be rejected with reserved_key_invalid_type, got: {msg!r}",
            )
        else:
            raise cmuxError(
                "lifecycle_state='frozen' was accepted; the validator is not wired"
            )
    finally:
        c.close_workspace(workspace_id)


def _run_rejects_non_string(c) -> None:
    workspace_id, surface_id = _fresh_surface(c)
    try:
        try:
            c._call(
                "surface.set_metadata",
                {
                    "surface_id": surface_id,
                    "mode": "merge",
                    "source": "explicit",
                    "metadata": {"lifecycle_state": 1},
                },
            )
        except cmuxError as err:
            msg = str(err)
            _must(
                "reserved_key_invalid_type" in msg or "lifecycle_state" in msg,
                f"non-string value should be rejected, got: {msg!r}",
            )
        else:
            raise cmuxError(
                "lifecycle_state=1 was accepted; the validator is not wired"
            )
    finally:
        c.close_workspace(workspace_id)


def _run_rejects_suspended(c) -> None:
    """Review fix I4: 'suspended' is reserved-only — defined in the enum
    but rejected at the validator until a runtime consumer exists."""
    for state in RESERVED_STATES:
        workspace_id, surface_id = _fresh_surface(c)
        try:
            try:
                c._call(
                    "surface.set_metadata",
                    {
                        "surface_id": surface_id,
                        "mode": "merge",
                        "source": "explicit",
                        "metadata": {"lifecycle_state": state},
                    },
                )
            except cmuxError as err:
                msg = str(err)
                _must(
                    "reserved_key_invalid_type" in msg or "lifecycle_state" in msg,
                    f"reserved value {state!r} should be rejected, got: {msg!r}",
                )
            else:
                raise cmuxError(
                    f"lifecycle_state={state!r} was accepted; "
                    f"reserved-only validator (I4) is not wired"
                )
        finally:
            c.close_workspace(workspace_id)


def _surface_for_id(surfaces: list, surface_id: str) -> dict | None:
    for s in surfaces:
        if str(s.get("id") or "") == surface_id:
            return s
    return None


def _run_metrics_in_surface_list(c) -> None:
    """C11-25 fix DoD #5: a freshly-spawned terminal surface must expose
    a `metrics` block with cpu_pct + rss_mb in surface.list once the
    sampler converges. surface.list is the wire source `c11 tree --json`
    decorates from, so this covers the tree-json contract too.
    """
    workspace_id, surface_id = _fresh_surface(c)
    try:
        # Sampler runs at 2 Hz by default; pid provider refreshes every
        # 2s. Allow up to 8 s for: provider tick → proc_listpids resolve
        # → first sample → next sample carrying CPU% delta.
        deadline = time.monotonic() + 8.0
        last_metrics: dict | None = None
        while time.monotonic() < deadline:
            res = c._call("surface.list", {"workspace_id": workspace_id}) or {}
            surfaces = res.get("surfaces") or []
            surface = _surface_for_id(surfaces, surface_id)
            _must(surface is not None, f"surface.list missing surface {surface_id}: {res}")
            assert surface is not None
            _must(
                surface.get("type") == "terminal",
                f"expected terminal surface, got {surface.get('type')!r}: {surface}",
            )
            metrics = surface.get("metrics")
            _must(
                isinstance(metrics, dict),
                f"terminal surface.list payload missing `metrics` block: {surface}",
            )
            assert isinstance(metrics, dict)
            _must(
                "cpu_pct" in metrics and "rss_mb" in metrics,
                f"metrics block missing cpu_pct/rss_mb keys: {metrics}",
            )
            last_metrics = metrics
            if metrics.get("cpu_pct") is not None and metrics.get("rss_mb") is not None:
                _must(
                    isinstance(metrics["cpu_pct"], (int, float)) and metrics["cpu_pct"] >= 0,
                    f"cpu_pct should be a non-negative number once sampled: {metrics}",
                )
                _must(
                    isinstance(metrics["rss_mb"], (int, float)) and metrics["rss_mb"] > 0,
                    f"rss_mb should be a positive number once sampled: {metrics}",
                )
                return
            time.sleep(0.5)
        raise cmuxError(
            f"sampler never produced non-null metrics for surface {surface_id} "
            f"within 8s; last metrics: {last_metrics}"
        )
    finally:
        c.close_workspace(workspace_id)


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        _run_legal_values(client)
        _run_rejects_unknown_value(client)
        _run_rejects_non_string(client)
        _run_rejects_suspended(client)
        _run_metrics_in_surface_list(client)
    print("OK c11-25 surface lifecycle metadata roundtrip + metrics surface.list exposure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
