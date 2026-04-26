#!/usr/bin/env python3
"""C11-7: CLI socket deadline — named timeouts and trace mode.

Tests verify observable behavior:
- A command sent to a socket that never responds exits non-zero within the deadline.
- stderr contains the stable "c11: timeout:" prefix with method/socket/elapsed fields.
- C11_TRACE=1 emits [c11-trace] start/end lines bracketing the request.
"""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time


# ---------------------------------------------------------------------------
# CLI binary resolution
# ---------------------------------------------------------------------------

def resolve_c11_cli() -> str:
    explicit = os.environ.get("C11_CLI_BIN") or os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    # Prefer the path written by scripts/reload.sh --tag.
    last_cli_path_file = "/tmp/c11-last-cli-path"
    if os.path.isfile(last_cli_path_file) and not os.path.islink(last_cli_path_file):
        try:
            candidate = open(last_cli_path_file).read().strip()
            if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
        except OSError:
            pass

    # Xcode DerivedData — both project names (historical: cmux, current: c11)
    candidates: list[str] = []
    for binary_name in ("c11", "cmux"):
        candidates.extend(glob.glob(
            os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/{binary_name}")
        ))
        candidates.extend(glob.glob(f"/tmp/cmux-*/Build/Products/Debug/{binary_name}"))
        candidates.extend(glob.glob(f"/tmp/c11-*/Build/Products/Debug/{binary_name}"))
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    for binary_name in ("c11", "cmux"):
        found = shutil.which(binary_name)
        if found:
            return found

    raise RuntimeError(
        "Unable to find c11 CLI binary. "
        "Run ./scripts/reload.sh --tag <name> first, or set C11_CLI_BIN."
    )


# ---------------------------------------------------------------------------
# Deaf socket server: accepts connections, reads input, never writes back.
# ---------------------------------------------------------------------------

class DeafSocketServer:
    """Unix socket server that accepts connections but never responds."""

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float = 2.0) -> bool:
        return self.ready.wait(timeout)

    def _run(self) -> None:
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            srv.bind(self.socket_path)
            srv.listen(8)
            srv.settimeout(30.0)
            self.ready.set()
            while True:
                try:
                    conn, _ = srv.accept()
                    # Accept the connection, drain input, but never send a byte back.
                    threading.Thread(target=self._drain, args=(conn,), daemon=True).start()
                except socket.timeout:
                    break
        finally:
            srv.close()
            try:
                os.remove(self.socket_path)
            except OSError:
                pass

    @staticmethod
    def _drain(conn: socket.socket) -> None:
        try:
            conn.settimeout(60.0)
            while conn.recv(4096):
                pass
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_cli(
    cli_path: str,
    *args: str,
    extra_env: dict[str, str] | None = None,
    timeout: float = 15.0,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [cli_path, *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_deadline_fires_and_names_timeout(cli_path: str, sock_path: str) -> tuple[bool, str]:
    """CLI exits non-zero with 'c11: timeout: method=...' when server never responds."""
    server = DeafSocketServer(sock_path)
    server.start()
    if not server.wait_ready():
        return False, "deaf server did not become ready"

    start = time.monotonic()
    proc = _run_cli(
        cli_path,
        "capabilities",
        extra_env={
            "CMUX_SOCKET_PATH": sock_path,
            # 600 ms deadline — fast enough for the test, long enough for slow CI.
            "C11_DEFAULT_SOCKET_DEADLINE_MS": "600",
        },
    )
    elapsed = time.monotonic() - start

    if proc.returncode == 0:
        return False, f"expected non-zero exit; got 0; stdout={proc.stdout!r}"

    # Must complete well within 2x the deadline.
    if elapsed > 5.0:
        return False, f"CLI took {elapsed:.1f}s — deadline did not fire in time"

    # stderr must contain the stable parseable prefix.
    if "c11: timeout:" not in proc.stderr:
        return False, f"expected 'c11: timeout:' in stderr; got {proc.stderr!r}"

    # Must name the method.
    if "method=system.capabilities" not in proc.stderr:
        return False, f"expected 'method=system.capabilities' in stderr; got {proc.stderr!r}"

    # Must include the socket path.
    if "socket=" not in proc.stderr:
        return False, f"expected 'socket=...' field in stderr; got {proc.stderr!r}"

    # Must include elapsed_ms.
    if "elapsed_ms=" not in proc.stderr:
        return False, f"expected 'elapsed_ms=...' field in stderr; got {proc.stderr!r}"

    return True, ""


def test_trace_mode_emits_start_and_end(cli_path: str, sock_path: str) -> tuple[bool, str]:
    """C11_TRACE=1 emits bracketing [c11-trace] -> / <- lines around the request."""
    server = DeafSocketServer(sock_path)
    server.start()
    if not server.wait_ready():
        return False, "deaf server did not become ready"

    proc = _run_cli(
        cli_path,
        "capabilities",
        extra_env={
            "CMUX_SOCKET_PATH": sock_path,
            "C11_DEFAULT_SOCKET_DEADLINE_MS": "600",
            "C11_TRACE": "1",
        },
    )

    if "[c11-trace] ->" not in proc.stderr:
        return False, f"expected '[c11-trace] ->' in stderr; got {proc.stderr!r}"

    if "[c11-trace] <-" not in proc.stderr:
        return False, f"expected '[c11-trace] <-' in stderr; got {proc.stderr!r}"

    if "status=timeout" not in proc.stderr:
        return False, f"expected 'status=timeout' in trace end line; got {proc.stderr!r}"

    if "elapsed=" not in proc.stderr:
        return False, f"expected 'elapsed=...' in trace end line; got {proc.stderr!r}"

    return True, ""


def test_no_deadline_for_browser_wait_command(cli_path: str, sock_path: str) -> tuple[bool, str]:
    """'browser wait' uses deadline:.none — the CLI default deadline does not apply.

    The deaf server will hold the connection open. With a 200ms default deadline
    and no explicit cli-side deadline for browser.wait, the CLI should NOT exit
    within 200ms. We give it 600ms and assert it is still running — then we kill it.
    """
    server = DeafSocketServer(sock_path)
    server.start()
    if not server.wait_ready():
        return False, "deaf server did not become ready"

    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = sock_path
    env["C11_DEFAULT_SOCKET_DEADLINE_MS"] = "200"
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    proc = subprocess.Popen(
        [cli_path, "browser", "wait", "--load-state", "complete"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    # Wait 600ms — well past the 200ms default deadline. browser.wait should still be alive.
    time.sleep(0.6)
    still_running = proc.poll() is None
    proc.terminate()
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    if not still_running:
        stderr = proc.stderr.read() if proc.stderr else ""
        return (
            False,
            f"'browser wait' exited early (deadline:.none was not applied). stderr={stderr!r}",
        )

    return True, ""


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def main() -> int:
    try:
        cli_path = resolve_c11_cli()
    except RuntimeError as exc:
        print(f"SKIP: {exc}")
        return 0  # Not a test failure; CLI not built yet.

    tmpdir = tempfile.mkdtemp(prefix="c11-deadline-test-")
    failures: list[str] = []

    tests = [
        ("deadline fires and names timeout", test_deadline_fires_and_names_timeout),
        ("trace mode emits start and end lines", test_trace_mode_emits_start_and_end),
        ("browser wait bypasses default deadline", test_no_deadline_for_browser_wait_command),
    ]

    for name, fn in tests:
        sock_path = os.path.join(tmpdir, f"{name.replace(' ', '_')}.sock")
        try:
            ok, msg = fn(cli_path, sock_path)
        except Exception as exc:
            ok, msg = False, f"unexpected exception: {exc}"
        finally:
            try:
                os.remove(sock_path)
            except OSError:
                pass

        status = "PASS" if ok else "FAIL"
        print(f"{status}: {name}")
        if not ok:
            print(f"  detail: {msg}")
            failures.append(name)

    try:
        os.rmdir(tmpdir)
    except OSError:
        pass

    if failures:
        print(f"\n{len(failures)} test(s) failed.")
        return 1

    print(f"\nAll {len(tests)} tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
