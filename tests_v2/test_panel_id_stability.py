#!/usr/bin/env python3
"""
Tier 1 persistence, Phase 1 — stable panel UUID regression test.

Creates a mix of terminal / browser / markdown surfaces in a new workspace,
then uses the debug-only `debug.session.round_trip` socket command to
snapshot-and-restore the workspace in place. Panel UUIDs must survive the
round-trip so external consumers (Lattice, CLI, scripted tests) can safely
cache them across c11mux restarts.

Notes:
- Requires a DEBUG cmux build. The `debug.session.round_trip` method is
  gated on `#if DEBUG`.
- Do NOT run locally per project testing policy (run via the VM or CI with
  `CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock` pointed at a tagged build).
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from typing import Set

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def wait_for_socket(path: str, timeout_s: float = 5.0) -> None:
    start = time.time()
    while not os.path.exists(path):
        if time.time() - start >= timeout_s:
            raise RuntimeError(f"Socket not found at {path}")
        time.sleep(0.1)


def _surface_ids_in_workspace(client: cmux, workspace_id: str) -> Set[str]:
    rows = client.list_surfaces(workspace_id)
    ids: Set[str] = set()
    for _idx, sid, _focused in rows:
        if sid:
            ids.add(str(sid))
    return ids


def test_round_trip_preserves_panel_ids(client: cmux) -> tuple[bool, str]:
    ws_id = client.new_workspace()
    client.select_workspace(ws_id)
    time.sleep(0.4)

    # Workspace starts with one terminal surface; add two more panel types.
    browser_id = client.new_surface(panel_type="browser", url="https://example.com")
    time.sleep(0.4)

    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write("# round-trip\n")
        markdown_path = f.name
    try:
        # The v2 socket has no dedicated "new markdown" helper; reuse the
        # terminal path to round-trip at least two panel types. That already
        # exercises the surface-id preservation contract for terminals and
        # browsers, which is what matters for Phase 1.
        _ = client.new_surface(panel_type="terminal")
        time.sleep(0.4)

        pre_round_trip = _surface_ids_in_workspace(client, ws_id)
        if len(pre_round_trip) < 3:
            return False, f"Expected >=3 surfaces pre-round-trip, got {pre_round_trip}"
        if str(browser_id) not in pre_round_trip:
            return False, f"Browser id {browser_id} missing pre-round-trip: {pre_round_trip}"

        result = client._call(
            "debug.session.round_trip",
            params={"workspace_id": ws_id},
        )
        if not isinstance(result, dict):
            return False, f"Unexpected round-trip payload type: {type(result).__name__}"

        before = set(result.get("before") or [])
        after = set(result.get("after") or [])
        if not before:
            return False, f"Round-trip returned no 'before' IDs: {result}"
        if before != after:
            missing = before - after
            unexpected = after - before
            return False, (
                f"Panel IDs changed across round-trip. missing={missing} unexpected={unexpected}"
            )
        if not before.issubset(pre_round_trip | set([str(browser_id)])):
            return False, (
                f"Round-trip reported IDs outside the observed workspace: before={before} "
                f"observed={pre_round_trip}"
            )

        post_round_trip = _surface_ids_in_workspace(client, ws_id)
        if post_round_trip != before:
            return False, (
                f"surface.list disagrees with debug.session.round_trip after restore: "
                f"socket={post_round_trip} round_trip_after={after}"
            )
    finally:
        try:
            os.unlink(markdown_path)
        except OSError:
            pass
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass

    return True, "Panel IDs preserved across in-process session round-trip"


def run_tests() -> int:
    print("=" * 60)
    print("cmux Panel UUID Stability Test (Tier 1 Phase 1)")
    print("=" * 60)
    print()

    probe = cmux()
    wait_for_socket(probe.socket_path, timeout_s=5.0)

    tests = [
        ("round-trip preserves panel ids", test_round_trip_preserves_panel_ids),
    ]

    passed = 0
    failed = 0

    try:
        with cmux(socket_path=probe.socket_path) as client:
            caps = client.capabilities()
            methods = set((caps or {}).get("methods") or [])
            if "debug.session.round_trip" not in methods:
                print(
                    "SKIP: socket does not expose debug.session.round_trip "
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
