#!/usr/bin/env python3
"""Compiled-CLI regression: ambiguous rename targets never dispatch tab.action.

The pure Swift parser tests protect the shared target seam. This test protects
the executable `rename-tab` compatibility wrapper that once stripped repeated
targets with the generic last-value-wins parser before forwarding to
`tab-action`. The no-global-`--window` cases below must fail locally and write
zero socket bytes. A command with global pre-command `--window` may first send
its separate `window.focus` RPC; that does not weaken the invariant that an
ambiguous rename never dispatches `tab.action`.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path


def resolve_c11_cli() -> str:
    for key in ("C11_CLI_BIN", "CMUX_CLI_BIN", "CMUX_CLI"):
        candidate = os.environ.get(key)
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(
        "Set C11_CLI_BIN (or CMUX_CLI_BIN) to the freshly built c11 CLI binary."
    )


class RecordingSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.ready = threading.Event()
        self.finished = threading.Event()
        self.received = bytearray()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()
        if not self.ready.wait(timeout=2):
            raise RuntimeError("recording socket did not become ready")

    def wait(self) -> None:
        if not self.finished.wait(timeout=2):
            raise RuntimeError("recording socket did not finish")
        if self.error is not None:
            raise self.error

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.path))
            server.listen(1)
            server.settimeout(1)
            self.ready.set()
            try:
                connection, _ = server.accept()
            except TimeoutError:
                return
            with connection:
                connection.settimeout(1)
                while True:
                    try:
                        chunk = connection.recv(4096)
                    except TimeoutError:
                        break
                    if not chunk:
                        break
                    self.received.extend(chunk)
        except Exception as exc:  # surfaced on the test thread
            self.error = exc
        finally:
            server.close()
            self.finished.set()


def run_case(cli: str, socket_path: Path, args: list[str]) -> tuple[bool, str]:
    recorder = RecordingSocket(socket_path)
    recorder.start()

    env = os.environ.copy()
    env.update(
        {
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            # If a regression does dispatch, keep the failure fast while the
            # fake server deliberately withholds a response.
            "C11_DEFAULT_SOCKET_DEADLINE_MS": "300",
            "CMUX_WORKSPACE_ID": "workspace:99",
            "CMUX_SURFACE_ID": "surface:99",
        }
    )
    process = subprocess.run(
        [cli, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
        env=env,
    )
    recorder.wait()

    merged = f"{process.stdout}\n{process.stderr}".strip()
    if process.returncode == 0:
        return False, f"expected a non-zero local rejection, got 0: {merged!r}"
    if "more than one" not in merged:
        return False, f"expected an ambiguity error, got: {merged!r}"
    if recorder.received:
        return False, f"expected zero socket bytes, got {bytes(recorder.received)!r}"
    return True, ""


def main() -> int:
    cli = resolve_c11_cli()
    cases = [
        [
            "rename-tab",
            "--tab", "surface:1",
            "--tab", "surface:2",
            "new title",
        ],
        [
            "rename-tab",
            "--tab", "surface:1",
            "--surface", "surface:2",
            "new title",
        ],
        [
            "rename-tab",
            "--workspace", "workspace:1",
            "--workspace", "workspace:2",
            "--tab", "surface:3",
            "new title",
        ],
    ]

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="c11-zero-dispatch-") as temp_dir:
        for index, args in enumerate(cases):
            socket_path = Path(temp_dir) / f"case-{index}.sock"
            ok, detail = run_case(cli, socket_path, args)
            label = " ".join(args)
            print(f"{'PASS' if ok else 'FAIL'}: {label}")
            if not ok:
                failures.append(f"{label}: {detail}")

    if failures:
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(f"PASS: all {len(cases)} ambiguous rename-tab commands wrote zero socket bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
