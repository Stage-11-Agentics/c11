#!/usr/bin/env python3
"""C11-26 regression: surface.send_text never blocks the main queue.

Why this test exists
--------------------
A captured 2026-05-03 hang showed `v2SurfaceSendText` parked in a nested
`CFRunLoopRun` inside an outer `DispatchQueue.main.sync` block: the handler
wrapped its body in `v2MainSync` and then called `waitForTerminalSurface`
(→ `v2AwaitCallback`), whose main-thread branch schedules its timeout via
`DispatchQueue.main.asyncAfter`. Because the main queue was already serialising
the outer block, the timeout block could never be popped — the wait was
unbounded. Sample evidence: 7120/7120 of a 10-second window stuck in the same
stack.

C11-26 routes `surface.send_text` (and the rest of the v2MainSync-wrapping
surface.* family) onto the socket worker thread via
`SocketCommandExecutionPolicy.socketWorker`. On the worker thread, the new
`waitForTerminalSurfaceOffMain` helper blocks on a DispatchSemaphore while
NotificationCenter observers fire on the still-free main queue (the legacy
`v2AwaitCallback` is left untouched per ticket non-goals — the parallel
helper avoids repointing its many @MainActor callers). The wait is bounded.

What this test asserts
----------------------
- `surface.send_text` returns within a generous wall-clock budget even while
  the main actor is being kept busy by other socket calls. Pre-fix, this could
  hang indefinitely; post-fix, the worker-side semaphore wait completes within
  the handler's 2.0 s internal timeout plus normal scheduling overhead.
- 20 parallel `surface.send_text` calls all complete within the wall-clock
  budget, exercising the off-main routing under concurrent load.

What this test does NOT do
--------------------------
- It does not grep `Sources/TerminalController.swift` for `nonisolated` or
  `SocketCommandExecutionPolicy` (per c11 CLAUDE.md "Test quality policy" —
  tests verify observable runtime behavior, not implementation shape).
- It does not directly reproduce the not-yet-attached precondition without a
  `workspace.apply` primitive (CMUX-37 territory). The single-call scenario
  uses parallel main-actor pressure to stress the same dispatch path; the
  burst scenario broadens coverage. If a future operator wants the
  not-yet-attached repro, they can extend the test once the workspace.apply
  primitive lands.

How to run
----------
This test runs against a tagged debug build of c11. Per c11 CLAUDE.md
"Testing policy", do NOT `open` an untagged `c11 DEV.app` to run this test —
use the tagged build socket the delegator produced via
`./scripts/reload.sh --tag <ticket-slug>`.

    C11_SOCKET=/tmp/c11-debug-c11-26-fix.sock python3 \\
        tests_v2/test_v2_surface_send_text_no_main_hang.py

Or via the project's tests-v2 runner (`scripts/run-tests-v2.sh`) once the
runner's test list picks the new file up.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET", "")

# Wall-clock budget for the single-call scenario. The handler's internal
# waitForTerminalSurface budget is 2.0 s; we add ~1 s of slack for round-trip
# and CI variance. Pre-fix this could hang indefinitely.
SINGLE_CALL_DEADLINE_SECONDS = 3.0

# Wall-clock budget for the 20-way burst. Pre-fix this could similarly hang.
# Post-fix all 20 calls run on the worker pool and finish well under this.
BURST_DEADLINE_SECONDS = 5.0
BURST_CALL_COUNT = 20

# Number of main-actor-pressure calls to drive in the background while the
# single send_text fires. system.tree is a known main-actor-bound v2 call —
# perfect for keeping the main queue busy without side-effects on workspace
# state.
PRESSURE_CALL_COUNT = 50


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _seed_workspace_and_surface(c: cmux) -> Tuple[str, str]:
    """Create a workspace and return (workspace_id, surface_id) for its first surface."""
    created = c._call("workspace.create", {}) or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")

    # The default workspace ships with a focused terminal surface; poll for it
    # to attach instead of a fixed sleep — see C11-26 review S3. Worst-case CI
    # variance still completes well under the 2 s budget.
    surfaces: list = []
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        surfaces = c.list_surfaces(ws_id)
        if surfaces:
            break
        time.sleep(0.05)
    _must(bool(surfaces), f"workspace {ws_id} has no surfaces after 2.0s poll: {surfaces}")
    sid = str(surfaces[0][1])
    _must(bool(sid), f"surface.list returned surface without id: {surfaces}")
    return ws_id, sid


def test_send_text_completes_under_main_actor_pressure(socket_path: str) -> None:
    """One surface.send_text returns within the deadline while the main queue is hot.

    Strategy: drive ~50 system.tree calls on a background thread (each runs on
    @MainActor) to keep the main dispatch queue saturated. While that's
    happening, fire one surface.send_text on a parallel connection. Pre-fix
    this could deadlock if the surface happened to be momentarily detached
    during a layout reshuffle. Post-fix, surface.send_text runs on the worker
    pool — even if main is busy, the worker-side semaphore wait does not
    nest a CFRunLoopRun on main.
    """
    with cmux(socket_path) as setup:
        ws_id, sid = _seed_workspace_and_surface(setup)

    try:
        # Main-actor pressure thread: drive system.tree in a tight loop on its
        # own connection while we issue the single send_text on another.
        pressure_done = threading.Event()
        pressure_errors: List[str] = []

        def pressure_worker() -> None:
            try:
                with cmux(socket_path) as p:
                    for _ in range(PRESSURE_CALL_COUNT):
                        if pressure_done.is_set():
                            return
                        try:
                            p._call("system.tree", {})
                        except cmuxError:
                            # Pressure errors are acceptable — they don't
                            # invalidate the deadline assertion below.
                            return
            except Exception as e:
                pressure_errors.append(str(e))

        pressure_thread = threading.Thread(target=pressure_worker, daemon=True)
        pressure_thread.start()
        # Brief head-start so the main queue is actually under load when we
        # issue the send_text.
        time.sleep(0.05)

        with cmux(socket_path) as c:
            start = time.monotonic()
            res = c._call(
                "surface.send_text",
                {"workspace_id": ws_id, "surface_id": sid, "text": "echo c11_26_main_pressure\n"},
                timeout_s=SINGLE_CALL_DEADLINE_SECONDS,
            )
            elapsed = time.monotonic() - start

        pressure_done.set()
        pressure_thread.join(timeout=2.0)

        _must(
            elapsed < SINGLE_CALL_DEADLINE_SECONDS,
            f"surface.send_text under main pressure took {elapsed:.2f}s "
            f"(deadline {SINGLE_CALL_DEADLINE_SECONDS}s) — possible main-queue deadlock regression",
        )
        _must(
            isinstance(res, dict) and bool(res.get("surface_id")),
            f"surface.send_text returned unexpected payload: {res!r}",
        )
        print(
            f"PASS: test_send_text_completes_under_main_actor_pressure "
            f"(elapsed={elapsed:.3f}s, pressure_errors={len(pressure_errors)})"
        )
    finally:
        with cmux(socket_path) as cleanup:
            try:
                cleanup.close_workspace(ws_id)
            except Exception:
                pass


def test_send_text_concurrent_burst(socket_path: str) -> None:
    """20 parallel surface.send_text calls complete within the wall-clock budget.

    Each worker uses its own socket connection so the connections don't
    serialize at the wire level. Pre-fix any one of these could have hung the
    whole batch (the worker thread would block waiting for the main queue to
    free). Post-fix the calls run on the socket worker pool and complete
    independently.
    """
    with cmux(socket_path) as setup:
        ws_id, sid = _seed_workspace_and_surface(setup)

    try:
        elapsed_ms_per_call: List[Optional[float]] = [None] * BURST_CALL_COUNT
        errors: List[Tuple[int, str]] = []

        def worker(idx: int) -> None:
            try:
                with cmux(socket_path) as c:
                    start = time.monotonic()
                    res = c._call(
                        "surface.send_text",
                        {
                            "workspace_id": ws_id,
                            "surface_id": sid,
                            "text": f"echo c11_26_burst_{idx}\n",
                        },
                        timeout_s=BURST_DEADLINE_SECONDS,
                    )
                    elapsed_ms_per_call[idx] = (time.monotonic() - start) * 1000.0
                    if not (isinstance(res, dict) and res.get("surface_id")):
                        errors.append((idx, f"unexpected payload: {res!r}"))
            except Exception as e:
                errors.append((idx, str(e)))

        threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(BURST_CALL_COUNT)]
        start = time.monotonic()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=BURST_DEADLINE_SECONDS + 1.0)
        wall_elapsed = time.monotonic() - start

        unfinished = [i for i, t in enumerate(threads) if t.is_alive()]
        _must(
            not unfinished,
            f"workers did not finish within {BURST_DEADLINE_SECONDS}s: indices={unfinished}",
        )
        _must(
            not errors,
            f"surface.send_text errors during burst: {errors[:5]}{'…' if len(errors) > 5 else ''}",
        )
        _must(
            wall_elapsed < BURST_DEADLINE_SECONDS,
            f"20 parallel surface.send_text calls took {wall_elapsed:.2f}s "
            f"(deadline {BURST_DEADLINE_SECONDS}s) — possible main-queue contention regression",
        )

        timings = [v for v in elapsed_ms_per_call if v is not None]
        slowest = sorted(timings, reverse=True)[:3]
        slowest_str = ", ".join(f"{ms:.0f}ms" for ms in slowest)
        print(
            f"PASS: test_send_text_concurrent_burst "
            f"(wall={wall_elapsed:.3f}s, slowest_3={slowest_str})"
        )
    finally:
        with cmux(socket_path) as cleanup:
            try:
                cleanup.close_workspace(ws_id)
            except Exception:
                pass


def main() -> int:
    if not SOCKET_PATH:
        print("SKIP: C11_SOCKET / CMUX_SOCKET not set — no live c11 instance")
        return 0
    if not os.path.exists(SOCKET_PATH):
        print(f"SKIP: socket {SOCKET_PATH} does not exist")
        return 0

    test_send_text_completes_under_main_actor_pressure(SOCKET_PATH)
    test_send_text_concurrent_burst(SOCKET_PATH)
    print("OK: all tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
