#!/usr/bin/env python3
"""
Tier 1 persistence, Phase 1.5 — stable workspace UUID regression test.

Creates a handful of workspaces, then uses the debug-only
`debug.session.round_trip_workspaces` socket command to snapshot-and-restore
the whole `TabManager` in place. Workspace UUIDs must survive the round-trip
so external consumers (Lattice, CLI, scripted tests) can safely cache
`(workspace_id, surface_id)` tuples across c11mux restarts.

Notes:
- Requires a DEBUG cmux build. The `debug.session.round_trip_workspaces`
  method is gated on `#if DEBUG`.
- Do NOT run locally per project testing policy (run via the VM or CI with
  `CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock` pointed at a tagged build).
"""

from __future__ import annotations

import os
import sys
import time
from typing import List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def wait_for_socket(path: str, timeout_s: float = 5.0) -> None:
    start = time.time()
    while not os.path.exists(path):
        if time.time() - start >= timeout_s:
            raise RuntimeError(f"Socket not found at {path}")
        time.sleep(0.1)


def test_round_trip_preserves_workspace_ids(client: cmux) -> tuple[bool, str]:
    # Seed a few extra workspaces so the test exercises the multi-workspace
    # path, not just the single-workspace happy path.
    created_ids: List[str] = []
    for _ in range(3):
        ws_id = client.new_workspace()
        created_ids.append(str(ws_id))
        time.sleep(0.2)

    try:
        result = client._call("debug.session.round_trip_workspaces", params={})
        if not isinstance(result, dict):
            return False, f"Unexpected round-trip payload type: {type(result).__name__}"

        before = list(result.get("before") or [])
        after = list(result.get("after") or [])
        if not before:
            return False, f"Round-trip returned no 'before' IDs: {result}"
        if before != after:
            return False, (
                f"Workspace IDs changed across TabManager round-trip. "
                f"before={before} after={after}"
            )
        for ws_id in created_ids:
            if ws_id not in before:
                return False, (
                    f"Created workspace {ws_id} missing from round-trip before list: {before}"
                )
    finally:
        for ws_id in created_ids:
            try:
                client.close_workspace(ws_id)
            except Exception:
                pass

    return True, "Workspace IDs preserved across in-process TabManager round-trip"


def run_tests() -> int:
    print("=" * 60)
    print("cmux Workspace UUID Stability Test (Tier 1 Phase 1.5)")
    print("=" * 60)
    print()

    probe = cmux()
    wait_for_socket(probe.socket_path, timeout_s=5.0)

    tests = [
        ("round-trip preserves workspace ids", test_round_trip_preserves_workspace_ids),
    ]

    passed = 0
    failed = 0

    try:
        with cmux(socket_path=probe.socket_path) as client:
            caps = client.capabilities()
            methods = set((caps or {}).get("methods") or [])
            if "debug.session.round_trip_workspaces" not in methods:
                print(
                    "SKIP: socket does not expose debug.session.round_trip_workspaces "
                    "(likely a non-DEBUG build). Run against a `cmux DEV` tagged build."
                )
                return 0

            for name, fn in tests:
                print(f"  Running: {name} ... ", end="", flush=True)
                try:
                    ok, msg = fn(client)
                except Exception as e:
                    ok, msg = False, str(e)
                status = "PASS" if ok else "FAIL"
                print(f"{status}: {msg}")
                if ok:
                    passed += 1
                else:
                    failed += 1
    except cmuxError as e:
        print(f"Error: {e}")
        return 1

    print()
    print(f"Results: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(run_tests())
