#!/usr/bin/env python3
"""C11-26 followup regression: v1 socket handlers must not self-deadlock on main.

Why this test exists
--------------------
After C11-26 (#112), the new socket dispatcher
(`processCommandUsingSocketExecutionPolicy`) routes default-policy commands
through

    DispatchQueue.main.sync { MainActor.assumeIsolated { processCommand(...) } }

from the worker thread. That moves every v1 handler — and every
default-policy v2 handler — onto the main thread before the switch fires.

About 100 v1 handlers in `TerminalController.swift` (and 12 in
`ThemeSocketMethods.swift`) were written against the *pre*-C11-26 reality
where `handleClient` invoked `processCommand(trimmed)` directly on the
worker. Those handlers hop to main themselves with bare
`DispatchQueue.main.sync { … }`. Post-C11-26 that hop is reentrant:
libdispatch's self-deadlock guard (`__DISPATCH_WAIT_FOR_QUEUE__`) traps with
EXC_BREAKPOINT and Apple's UI never surfaces it — the c11 window vanishes.

The operator hit this 4× on 2026-05-04 (twice on a `c11 DEV main` build,
twice on shipped 0.45.0/0.45.1). Every Sentry-native breakpad dump in
`~/.local/state/ghostty/crash/*.ghosttycrash` bottoms out at
`setProgress(_:) + 924` → `closure #1 in processCommand(_:) + 3856` →
`__DISPATCH_WAIT_FOR_QUEUE__ + 484`. The earlier 14:26 IPS hang on 0.44.1
(build 95) is the same class of bug pre-detection: same dispatch path, same
self-wait, but on an older libdispatch that hung indefinitely instead of
trapping.

What this test asserts
----------------------
- Issuing a v1 `set_progress` command across 30 fresh socket connections does
  not crash the c11 process. Pre-fix, the first call would trap and the
  second connect would fail (`ECONNREFUSED`) because the listener was gone.
  Post-fix, every call returns "OK" and the listener stays up.
- A spread of other v1 commands that follow the same bare-`main.sync` shape
  (`set_status`, `clear_status`, `report_pwd`, `clear_progress`,
  `report_git_branch`, `clear_git_branch`) all complete cleanly. They share
  the dispatcher path, so a regression on the dispatcher would fail any of
  them; covering several anchors the fix instead of testing one anchor only.

What this test does NOT do
--------------------------
- It does not grep `Sources/TerminalController.swift` for `v2MainSync` or
  any other implementation token (per c11 CLAUDE.md "Test quality policy" —
  tests verify observable runtime behavior, not implementation shape).
- It does not assert on Sentry/breakpad files directly. Whether a regression
  produces a crash dump or just a hang depends on macOS/libdispatch version;
  the contract this test enforces is "the call returns OK and the next
  connection succeeds", which catches both shapes.

How to run
----------
This test runs against a tagged debug build of c11. Per c11 CLAUDE.md
"Testing policy", do NOT `open` an untagged `c11 DEV.app` to run it — use the
tagged build socket produced by `./scripts/reload.sh --tag <slug>`.

    C11_SOCKET=/tmp/c11-debug-<slug>.sock python3 \\
        tests_v2/test_v1_handler_main_self_deadlock.py
"""

from __future__ import annotations

import os
import socket
import sys
import time
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = (
    os.environ.get("C11_SOCKET")
    or os.environ.get("CMUX_SOCKET")
    or "/tmp/cmux-debug.sock"
)

# Wall-clock budget per call. The handler does a tiny main-actor write; even
# under CI variance this should complete well under a second. Pre-fix the
# call traps inside libdispatch so the socket either drops or hangs.
PER_CALL_DEADLINE_SECONDS = 2.0

# Repeat count for the focused set_progress probe. The first call is the one
# that traps pre-fix; we repeat to catch any flakier intermediate state
# (e.g. accidentally fixed by a stale main-actor pump).
SET_PROGRESS_REPEAT = 30


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _send_v1(command: str, *, deadline_s: float = PER_CALL_DEADLINE_SECONDS) -> str:
    """Send one v1 line, return the trimmed response.

    Each call uses a fresh connection, mirroring how the production CLI talks
    to the daemon. That also means a regression that kills the listener will
    surface as `ConnectionRefusedError` on the *next* call, which the caller
    converts into a clear failure message.
    """
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(deadline_s)
        sock.connect(SOCKET_PATH)
        sock.sendall((command + "\n").encode("utf-8"))
        chunks: List[bytes] = []
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
            sock.settimeout(0.1)
    return b"".join(chunks).decode("utf-8", errors="replace").strip()


def _new_workspace(client: cmux) -> str:
    created = client._call("workspace.create", {}) or {}
    ws_id = str(created.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
    return ws_id


def test_set_progress_does_not_self_deadlock(socket_path: str) -> None:
    """Repeated v1 set_progress on a fresh workspace returns OK every time.

    This is the focused signature: setProgress's bare DispatchQueue.main.sync
    is what fired in production today. If the dispatcher path were still
    self-deadlocking, the first call would trap; after the trap, the listener
    is gone and the *second* connect raises ConnectionRefusedError.
    """
    with cmux(socket_path) as client:
        ws_id = _new_workspace(client)
    try:
        for i in range(SET_PROGRESS_REPEAT):
            value = round(0.01 + 0.03 * i, 4)  # 0.01..~0.88, all valid
            start = time.monotonic()
            try:
                resp = _send_v1(f"set_progress {value} --label=c11_26 --tab={ws_id}")
            except (ConnectionRefusedError, OSError) as e:
                raise cmuxError(
                    f"set_progress iteration {i} could not reach socket "
                    f"({e!r}) — listener likely crashed (EXC_BREAKPOINT regression)"
                )
            elapsed = time.monotonic() - start
            _must(
                resp.startswith("OK"),
                f"set_progress iteration {i} returned {resp!r}",
            )
            _must(
                elapsed < PER_CALL_DEADLINE_SECONDS,
                f"set_progress iteration {i} took {elapsed:.2f}s "
                f"(deadline {PER_CALL_DEADLINE_SECONDS}s) — possible deadlock regression",
            )
        print(
            f"PASS: test_set_progress_does_not_self_deadlock "
            f"(iterations={SET_PROGRESS_REPEAT})"
        )
    finally:
        with cmux(socket_path) as cleanup:
            try:
                cleanup.close_workspace(ws_id)
            except Exception:
                pass


def test_v1_main_sync_handlers_return_ok(socket_path: str) -> None:
    """A spread of v1 handlers that share the bare-main.sync shape all return OK.

    Each one routes through processCommand → switch case → bare main.sync
    (pre-fix). Hitting them in sequence on a single fresh workspace checks
    the dispatcher path is healthy across more than just setProgress, so a
    future regression cannot regress a sibling without this catching it.
    """
    with cmux(socket_path) as client:
        ws_id = _new_workspace(client)

    # `command` is the full v1 line; `predicate` decides what counts as success.
    # Most return "OK"; a few return data lines whose mere presence proves the
    # handler completed without trapping.
    probes = [
        ("set_progress 0.42 --label=probe --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("clear_progress --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("set_status probe-key probe-value --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("clear_status probe-key --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("report_pwd /tmp --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("report_git_branch main --tab=" + ws_id, lambda r: r.startswith("OK")),
        ("clear_git_branch --tab=" + ws_id, lambda r: r.startswith("OK")),
    ]

    try:
        for cmd, ok in probes:
            try:
                resp = _send_v1(cmd)
            except (ConnectionRefusedError, OSError) as e:
                raise cmuxError(
                    f"{cmd!r} could not reach socket ({e!r}) — listener likely crashed"
                )
            _must(ok(resp), f"{cmd!r} returned unexpected response: {resp!r}")
        print(
            f"PASS: test_v1_main_sync_handlers_return_ok "
            f"(probes={len(probes)})"
        )
    finally:
        with cmux(socket_path) as cleanup:
            try:
                cleanup.close_workspace(ws_id)
            except Exception:
                pass


def main() -> int:
    if not SOCKET_PATH or not os.path.exists(SOCKET_PATH):
        print(
            f"SKIP: socket not found at {SOCKET_PATH!r}. "
            f"Set C11_SOCKET to a tagged build's socket "
            f"(e.g. /tmp/c11-debug-<slug>.sock).",
            file=sys.stderr,
        )
        return 0

    failures: List[str] = []
    for fn in (
        test_set_progress_does_not_self_deadlock,
        test_v1_main_sync_handlers_return_ok,
    ):
        try:
            fn(SOCKET_PATH)
        except Exception as e:
            failures.append(f"{fn.__name__}: {e}")
            print(f"FAIL: {fn.__name__}: {e}", file=sys.stderr)

    if failures:
        print(f"\n{len(failures)} test(s) failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
