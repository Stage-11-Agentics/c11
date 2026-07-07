#!/usr/bin/env python3
"""C11-165 COR-3/COR-4: a socket flood must not monopolize the main thread.

The C11-156 reproduction shape: many concurrent hook/telemetry writes plus a
blocking-genre command, while a cheap liveness probe must keep returning under
an absolute deadline. If a future change puts a blocking handler
(pane.confirm / feedback.submit) back on the main-actor policy, or reintroduces
main-thread sync work on the telemetry path, the probe deadline blows and this
test fails.

Runs against a tagged build socket (C11_SOCKET / CMUX_SOCKET). Per plan §8.12
this FAILS (not skips) when it cannot reach its socket, and uses an ABSOLUTE
probe deadline (the in-repo precedent) rather than a noisy relative comparison.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


# A single main-thread stall would blow this; generous enough to absorb normal
# scheduling jitter on a loaded CI/VM host.
PROBE_DEADLINE_S = 2.0
FLOOD_THREADS = 8
FLOOD_ITERS = 40


def _client(sock: str) -> cmux:
    c = cmux(socket_path=sock)
    c.connect()
    return c


def main() -> int:
    sock = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET")
    if not sock or not os.path.exists(sock):
        print(f"FAIL: no reachable c11 socket (C11_SOCKET/CMUX_SOCKET={sock!r})")
        return 1

    setup = _client(sock)
    ws = setup._call("workspace.current") or {}
    ws_id = ws.get("workspace_id")
    if not ws_id:
        print("FAIL: no current workspace")
        return 1

    stop = threading.Event()
    errors: list[str] = []

    def flood(worker: int) -> None:
        # Each worker its own connection (the socket is per-connection).
        try:
            c = _client(sock)
        except Exception as e:  # noqa: BLE001
            errors.append(f"flood connect {worker}: {e}")
            return
        for i in range(FLOOD_ITERS):
            if stop.is_set():
                return
            try:
                # Tab-scoped telemetry write — the hook/telemetry flood shape.
                c._call("workspace.set_metadata",
                        {"workspace_id": ws_id, "metadata": {f"flood_{worker}": str(i)}})
            except cmuxError:
                pass  # rejections are fine; we're measuring liveness, not writes

    # Fire a blocking-genre command off in its own thread. feedback.submit blocks
    # on a 35s semaphore that — pre-C11-165 — froze main; it now runs off-main so
    # it must NOT stall the probe. (It will fail fast on validation/network; we
    # only care that it does not monopolize main.)
    def blocker() -> None:
        try:
            c = _client(sock)
            c._call("feedback.submit",
                    {"email": "cor3@example.com", "body": "flood-probe"}, timeout_s=40.0)
        except Exception:  # noqa: BLE001
            pass

    threads = [threading.Thread(target=flood, args=(w,), daemon=True)
               for w in range(FLOOD_THREADS)]
    threads.append(threading.Thread(target=blocker, daemon=True))
    for t in threads:
        t.start()

    # While the flood runs, a cheap probe must keep returning under the deadline.
    probe = _client(sock)
    worst = 0.0
    probes = 0
    deadline_end = time.monotonic() + 6.0
    while time.monotonic() < deadline_end and any(t.is_alive() for t in threads):
        t0 = time.monotonic()
        try:
            probe._call("workspace.list")
        except cmuxError as e:
            errors.append(f"probe error: {e}")
            break
        dt = time.monotonic() - t0
        worst = max(worst, dt)
        probes += 1
        if dt > PROBE_DEADLINE_S:
            errors.append(f"probe latency {dt:.2f}s exceeded {PROBE_DEADLINE_S}s "
                          f"— main thread monopolized under flood")
            break
        time.sleep(0.02)

    stop.set()
    for t in threads:
        t.join(timeout=2.0)

    if errors:
        print("FAIL: " + "; ".join(errors))
        return 1
    print(f"PASS: {probes} probes under flood, worst latency {worst*1000:.0f}ms "
          f"(< {PROBE_DEADLINE_S*1000:.0f}ms)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as e:
        print(f"FAIL: {e}")
        sys.exit(1)
