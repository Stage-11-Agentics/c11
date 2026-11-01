#!/usr/bin/env python3
"""Prove tests/test_*.py cannot connect to an inherited c11 socket.

This is a runtime check. A canary listens. Each socket-capable test file is
executed against it. Zero accepts is success. A second phase uses no socket
env and a temp HOME whose default socket is the canary. The red phase runs
the incident test with the guard switched off and requires at least one accept.

The canary is the live-socket stand-in. Nothing here dials the operator's app.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import signal
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO = TESTS_DIR.parent

# Host-affecting files refuse to start unless C11_TEST_ALLOW_LIVE_APP=1.
# The canary does not set that, and does not need to execute their bodies.
SKIP = {
    "test_socket_guard_canary.py": "this runner",
    "test_socket_access.py": "refuses without C11_TEST_ALLOW_LIVE_APP; launches and kills a dev app",
    "test_session_restore_unfocused_workspace_multi_window_cycle.py": "refuses without C11_TEST_ALLOW_LIVE_APP; pkills and quits an app",
    "test_session_restore_unfocused_workspace_relaunch_cycle.py": "refuses without C11_TEST_ALLOW_LIVE_APP; pkills and quits an app",
    "test_atlas_build_slots.py": "refuses without C11_TEST_ALLOW_LIVE_APP; takes the shared build lock",
    "test_cmd_option_t_close_other_tabs_in_pane.py": "refuses without C11_TEST_ALLOW_LIVE_APP; sends the close-tabs shortcut",
}

# A live socket is accepted at startup. Tests that only wait on the missing
# sentinel return in about two seconds. Eight workers keep the CI job inside
# its eight minutes; the serial red phases stay one process.
PER_TEST_TIMEOUT_S = 4
WORKERS = 8


class Canary:
    def __init__(self, path: str) -> None:
        self.path = path
        self.accepted = 0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._server: socket.socket | None = None

    def start(self) -> None:
        parent = os.path.dirname(self.path)
        os.makedirs(parent, exist_ok=True)
        if os.path.exists(self.path):
            raise SystemExit(f"refusing to replace an existing socket at {self.path}")
        socket_guard.allow(self.path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        server.listen(128)
        server.settimeout(0.2)
        self._server = server

        def serve() -> None:
            assert self._server is not None
            while not self._stop.is_set():
                try:
                    conn, _ = self._server.accept()
                except TimeoutError:
                    continue
                self.accepted += 1
                try:
                    conn.close()
                except OSError:
                    pass

        self._thread = threading.Thread(target=serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
        if self._server is not None:
            self._server.close()
        try:
            os.remove(self.path)
        except OSError:
            pass


def test_files() -> list[Path]:
    return sorted(path for path in TESTS_DIR.glob("test_*.py") if path.name not in SKIP)


def child_env(base: dict[str, str]) -> dict[str, str]:
    env = dict(base)
    env["PYTHONPATH"] = str(TESTS_DIR) + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    env.pop("C11_SOCKET_GUARD_RED_PROOF", None)
    env.pop("C11_SOCKET_GUARD_DISABLED", None)
    return env


def run_test(path: Path, env: dict[str, str]) -> str:
    log_dir = Path("/tmp/c11-509-canary-logs")
    log_dir.mkdir(exist_ok=True)
    log_path = log_dir / f"{path.stem}.log"
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            [sys.executable, str(path)],
            cwd=str(REPO),
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            code = proc.wait(timeout=PER_TEST_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
            return "timeout"
    if code == 0:
        return "pass"
    return f"exit {code}"


def run_phase(title: str, env: dict[str, str], canary: Canary) -> list[tuple[str, str, int]]:
    """Run every file together. Acceptance is the phase total, not a per-file delta."""
    print(f"\n== {title}", flush=True)
    before = canary.accepted
    statuses: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(run_test, path, env) for path in test_files()]
        for path, future in zip(test_files(), futures):
            statuses[path.name] = future.result()
    delta = canary.accepted - before
    print(f"phase accepts={delta}", flush=True)
    rows: list[tuple[str, str, int]] = []
    for path in test_files():
        status = statuses[path.name]
        # Per-file attribution is unavailable while files share one listener.
        # A zero phase total means every file accepted nothing.
        file_delta = 0 if delta == 0 else delta
        rows.append((path.name, status, file_delta))
        mark = "quiet" if delta == 0 else "CONNECT"
        print(f"  {mark} {file_delta} {status} {path.name}", flush=True)
    return rows


def scenario_env(canary_path: str, home: str) -> dict[str, str]:
    env = child_env(os.environ)
    env["HOME"] = home
    for key in socket_guard.SOCKET_ENV_KEYS:
        env[key] = canary_path
    env["C11_PANEL_ID"] = "panel-operator"
    env["C11_WORKSPACE_ID"] = "ws-operator"
    env["CMUX_SURFACE_ID"] = "surface-operator"
    return env


def bare_env(home: str) -> dict[str, str]:
    env = child_env(os.environ)
    env["HOME"] = home
    for key in socket_guard.SOCKET_ENV_KEYS:
        env.pop(key, None)
    return env


def red_direct(canary_path: str, home: str) -> None:
    """A process with no guard dials the canary. That is the removed-guard case."""
    script = (
        "import socket, sys\n"
        "client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
        "client.settimeout(2)\n"
        "client.connect(sys.argv[1])\n"
        "print('connected')\n"
    )
    env = bare_env(home)
    with socket_guard.permit_implicit_discovery():
        subprocess.run(
            [sys.executable, "-c", script, canary_path],
            cwd=str(REPO),
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )


def write_audit(rows: list[tuple[str, str, int]], bare_rows: list[tuple[str, str, int]]) -> None:
    lines = [
        "| test | inherited socket env | no socket env | coverage |",
        "| --- | --- | --- | --- |",
    ]
    bare = {name: (status, delta) for name, status, delta in bare_rows}
    for name, status, delta in rows:
        bare_status, bare_delta = bare.get(name, ("", 0))
        coverage = "guard installed; canary accepted 0"
        if delta or bare_delta:
            coverage = "CONNECTED; guard bypassed"
        lines.append(
            f"| `{name}` | {status}, accepts {delta} | {bare_status}, accepts {bare_delta} | {coverage} |"
        )
    for name, reason in sorted(SKIP.items()):
        if name == "test_socket_guard_canary.py":
            continue
        lines.append(
            f"| `{name}` | not executed | not executed | header installs the guard; skipped here because it {reason} |"
        )
    text = "\n".join(lines) + "\n"
    out = Path("/tmp/c11-509-audit.md")
    out.write_text(text, encoding="utf-8")
    print(f"\nAudit: {out}")


def main() -> int:
    pid = os.getpid()
    home = f"/tmp/c11-509-home-{pid}"
    os.makedirs(home, exist_ok=True)
    # Not a direct /tmp/*.sock name. The CLI's discovery glob matches c11*.sock
    # and cmux*.sock in /tmp, and this file must not be one of those hits.
    inherited = Canary(f"{home}/canary.sock")
    default_path = f"{home}/Library/Application Support/c11/c11.sock"
    default = Canary(default_path)
    inherited.start()
    default.start()
    failures: list[str] = []
    try:
        inherited_rows = run_phase(
            "inherited C11_SOCKET_PATH and CMUX_SOCKET_PATH point at the canary",
            scenario_env(inherited.path, home),
            inherited,
        )
        if inherited.accepted:
            failures.append(f"inherited phase accepted {inherited.accepted}")

        with socket_guard.permit_implicit_discovery():
            bare_rows = run_phase(
                "no socket env, canary on the temp-HOME default socket",
                bare_env(home),
                default,
            )
        if default.accepted:
            failures.append(f"default-path phase accepted {default.accepted}")

        before_red = inherited.accepted
        red_incident_count_start = inherited.accepted
        env = scenario_env(inherited.path, home)
        env["C11_SOCKET_GUARD_RED_PROOF"] = "1"
        env["C11_SOCKET_GUARD_DISABLED"] = "1"
        proc = subprocess.Popen(
            [sys.executable, str(TESTS_DIR / "test_claude_hook_session_mapping.py")],
            cwd=str(REPO),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            proc.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
        red_incident_accepts = inherited.accepted - red_incident_count_start
        print(f"\nred incident test accepts={red_incident_accepts}")
        if red_incident_accepts < 1:
            failures.append("removing the guard did not make the incident test connect")

        before_direct = default.accepted
        red_direct(default.path, home)
        # Give the accept loop a moment.
        time.sleep(0.3)
        direct_accepts = default.accepted - before_direct
        print(f"red unguarded connect to the default path accepts={direct_accepts}")
        if direct_accepts < 1:
            failures.append("an unguarded connect did not reach the default-path canary")

        # The red connects are expected. Green totals are the ones before red.
        if before_red != sum(delta for _, _, delta in inherited_rows):
            failures.append("inherited accept accounting drifted")

        write_audit(inherited_rows, bare_rows)
    finally:
        inherited.stop()
        default.stop()

    if failures:
        print("FAIL")
        for item in failures:
            print(f"  {item}")
        return 1
    print("\nPASS canary: green phases accepted nothing; red phases connected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
