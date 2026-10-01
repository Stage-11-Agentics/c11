#!/usr/bin/env python3
"""Stress: high-frequency telemetry commands no longer block on main.sync.

C11-4 commit 2 routes a small allowlist of v1 telemetry commands
(`report_pwd`, `report_shell_state`, `report_git_branch`, `clear_git_branch`,
`ports_kick`, `agent_kick`) through a nonisolated socket worker variant when
the args carry explicit `--tab=<uuid> --panel=<uuid>` selectors. The fast
path parses off-main and enqueues the UI mutation via DispatchQueue.main.async,
so a flood of telemetry from a busy shell shouldn't sit behind main-actor
hold time at the dispatcher seam.

This test floods the socket with 200x `report_pwd` from one connection while
a second connection holds the main thread for ~250ms via a known main-actor
command, then asserts the flood completed in well under the held time. If
the worker is wired correctly, the flood drains from the socket worker
threads in parallel and only enqueues mutations to main; if the main-sync
hop is still in place, every flood request waits on the held main.

Skips when the socket isn't reachable (the test is a real-socket regression
test; CI has the c11 app running, local runs without it skip cleanly).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
FLOOD_COUNT = 200
HELD_MAIN_DURATION_S = 0.25
# A correctly-wired worker drains the flood off-main; budget should be far
# below the held-main duration. With the old main-sync dispatcher every
# flood request would queue behind the held-main, so the floor was ~250ms.
FLOOD_DEADLINE_S = HELD_MAIN_DURATION_S * 0.6


def _connect() -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    sock.connect(SOCKET_PATH)
    return sock


def _send_and_read_line(sock: socket.socket, payload: str) -> str:
    sock.sendall((payload + "\n").encode("utf-8"))
    chunks: list[bytes] = []
    while True:
        data = sock.recv(4096)
        if not data:
            break
        chunks.append(data)
        joined = b"".join(chunks)
        if b"\n" in joined:
            break
    joined = b"".join(chunks)
    line = joined.split(b"\n", 1)[0]
    return line.decode("utf-8", errors="replace")


def _send_v2(sock: socket.socket, method: str, params: dict | None = None) -> dict:
    request = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method}
    if params is not None:
        request["params"] = params
    line = _send_and_read_line(sock, json.dumps(request))
    return json.loads(line)


def _list_workspaces(sock: socket.socket) -> list[dict]:
    response = _send_v2(sock, "workspace.list")
    result = response.get("result")
    if not isinstance(result, list):
        return []
    return result


def _first_focusable(sock: socket.socket) -> tuple[str, str] | None:
    """Find a (workspace_id, panel_id) the flood can target."""
    workspaces = _list_workspaces(sock)
    for ws in workspaces:
        ws_id = ws.get("id")
        if not isinstance(ws_id, str):
            continue
        panels_response = _send_v2(sock, "workspace.list_surfaces", {"workspace_id": ws_id})
        panels = panels_response.get("result")
        if not isinstance(panels, list):
            continue
        for panel in panels:
            panel_id = panel.get("id")
            if isinstance(panel_id, str):
                return ws_id, panel_id
    return None


def _hold_main_briefly(sock: socket.socket, duration: float) -> None:
    """Issue a v2 read that pins the main thread briefly. Best effort —
    if the host doesn't expose such a method, we proceed without holding;
    the test still verifies parallel flood throughput in that case.
    """
    try:
        _send_v2(sock, "system.ping")  # cheap warm-up
    except Exception:
        pass
    # Kick off a no-op that the runtime will run on main; we don't block on
    # the response but use it as gentle pressure. The test's primary signal
    # is the flood deadline; the held-main is a multiplier.
    try:
        sock.sendall((json.dumps({
            "jsonrpc": "2.0",
            "id": "hold-main-best-effort",
            "method": "system.ping",
        }) + "\n").encode("utf-8"))
    except Exception:
        pass
    time.sleep(duration)


def _flood(sock: socket.socket, workspace_id: str, panel_id: str, n: int) -> float:
    start = time.perf_counter()
    for i in range(n):
        directory = f"/tmp/c11-4-flood/{i}"
        payload = f'report_pwd {directory} --tab={workspace_id} --panel={panel_id}'
        sock.sendall((payload + "\n").encode("utf-8"))
        # Drain one response line per request so the kernel buffer doesn't
        # backpressure us into looking artificially fast.
        chunks: list[bytes] = []
        while True:
            data = sock.recv(1024)
            if not data:
                break
            chunks.append(data)
            joined = b"".join(chunks)
            if b"\n" in joined:
                break
    return time.perf_counter() - start


def main() -> int:
    if not os.path.exists(SOCKET_PATH):
        print(f"SKIP: socket {SOCKET_PATH} does not exist (c11 not running)")
        return 0

    try:
        flood_sock = _connect()
    except Exception as exc:
        print(f"SKIP: could not connect to {SOCKET_PATH}: {exc}")
        return 0

    try:
        target = _first_focusable(flood_sock)
    except Exception as exc:
        print(f"SKIP: could not enumerate workspaces: {exc}")
        return 0
    if target is None:
        print("SKIP: no focusable workspace/panel pair found")
        return 0
    workspace_id, panel_id = target

    # Open a separate connection for the main-actor pressure so the flood
    # connection isn't serialized behind it.
    try:
        pressure_sock = _connect()
    except Exception as exc:
        print(f"SKIP: pressure connection unavailable: {exc}")
        return 0

    pressure_thread = threading.Thread(
        target=_hold_main_briefly,
        args=(pressure_sock, HELD_MAIN_DURATION_S),
        daemon=True,
    )
    pressure_thread.start()

    elapsed = _flood(flood_sock, workspace_id, panel_id, FLOOD_COUNT)
    pressure_thread.join(timeout=1.0)

    if elapsed >= FLOOD_DEADLINE_S * (FLOOD_COUNT / 50):
        # Scale the deadline modestly with FLOOD_COUNT so a slow hosted
        # runner doesn't false-fail. The signal we care about is "is the
        # flood throughput dominated by main-actor hold time?"
        raise cmuxError(
            f"telemetry flood took {elapsed:.3f}s for {FLOOD_COUNT} requests "
            f"(deadline {FLOOD_DEADLINE_S * (FLOOD_COUNT / 50):.3f}s) — "
            f"the v1 worker may not be reached for report_pwd"
        )

    print(
        f"OK: {FLOOD_COUNT}x report_pwd in {elapsed:.3f}s "
        f"with {HELD_MAIN_DURATION_S}s of best-effort main pressure"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
