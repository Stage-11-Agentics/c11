#!/usr/bin/env python3
"""Runtime checks for the shared c11 socket guard. No live app socket."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import socket
import subprocess
import tempfile
import textwrap
import threading
import time

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS_DIR)


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def fresh(script: str, *, env: dict[str, str] | None = None, args: list[str] | None = None) -> subprocess.CompletedProcess[str]:
    child_env = dict(os.environ if env is None else env)
    return subprocess.run(
        [sys.executable, "-c", script, *(args or [])],
        cwd=REPO,
        env=child_env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )


def test_install_scrubs_to_sentinel() -> None:
    canary = "/tmp/c11-509-not-a-real-live-socket.sock"
    script = textwrap.dedent(
        f"""
        import os, sys
        sys.path.insert(0, {TESTS_DIR!r})
        os.environ["C11_SOCKET"] = {canary!r}
        os.environ["C11_SOCKET_PATH"] = {canary!r}
        os.environ["CMUX_SOCKET_PATH"] = {canary!r}
        os.environ["CMUX_SOCKET"] = {canary!r}
        os.environ["C11_PANEL_ID"] = "panel-live"
        os.environ["C11_WORKSPACE_ID"] = "ws-live"
        os.environ["CMUX_SURFACE_ID"] = "surface-live"
        import socket_guard
        socket_guard.install()
        keys = socket_guard.SOCKET_ENV_KEYS
        assert all(os.environ[key] == socket_guard.SENTINEL for key in keys), os.environ
        for key in ("C11_PANEL_ID", "C11_WORKSPACE_ID", "CMUX_SURFACE_ID"):
            assert key not in os.environ, key
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"scrub\nstdout={result.stdout}\nstderr={result.stderr}")


def test_refuse_existing_socket_before_accept() -> None:
    directory = tempfile.mkdtemp(prefix="c11-509-foreign-")
    path = os.path.join(directory, "foreign.sock")
    # The parent created this directory, so the parent's guard would allow it.
    # The child did not. Acceptance is what proves the syscall did not happen.
    accepted = {"n": 0}
    stop = threading.Event()

    def serve() -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(path):
                os.remove(path)
            server.bind(path)
            server.listen(4)
            server.settimeout(0.2)
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except TimeoutError:
                    continue
                accepted["n"] += 1
                conn.close()
        finally:
            server.close()
            try:
                os.remove(path)
            except OSError:
                pass

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    deadline = time.time() + 2
    while not os.path.exists(path):
        if time.time() > deadline:
            stop.set()
            fail("foreign listener did not bind")
        time.sleep(0.02)

    script = textwrap.dedent(
        f"""
        import sys
        sys.path.insert(0, {TESTS_DIR!r})
        import socket
        import socket_guard
        socket_guard.install()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.connect(sys.argv[1])
        except socket_guard.SocketGuardError:
            print("refused")
            raise SystemExit(0)
        print("connected")
        raise SystemExit(2)
        """
    )
    # Pass the path only as an argument. Do not put it in the child env, and
    # do not let this process connect.
    result = fresh(script, args=[path])
    time.sleep(0.3)
    stop.set()
    thread.join(timeout=2)
    if result.returncode != 0 or "refused" not in result.stdout:
        fail(f"refuse\nstdout={result.stdout}\nstderr={result.stderr}")
    if accepted["n"] != 0:
        fail(f"listener accepted {accepted['n']} connection(s)")


def test_bind_and_connect_under_test_temp() -> None:
    script = textwrap.dedent(
        f"""
        import os, socket, sys, tempfile, threading, time
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        root = tempfile.mkdtemp(prefix="c11-509-own-")
        path = os.path.join(root, "own.sock")
        accepted = {{"ok": False}}
        def serve():
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            server.settimeout(2)
            conn, _ = server.accept()
            accepted["ok"] = True
            conn.close()
            server.close()
        thread = threading.Thread(target=serve)
        thread.start()
        deadline = time.time() + 2
        while not os.path.exists(path):
            if time.time() > deadline:
                raise SystemExit("bind did not appear")
            time.sleep(0.02)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2)
        client.connect(path)
        thread.join(timeout=2)
        assert accepted["ok"]
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"own socket\nstdout={result.stdout}\nstderr={result.stderr}")


def test_child_env_uses_test_socket_for_every_key() -> None:
    script = textwrap.dedent(
        f"""
        import os, subprocess, sys, tempfile
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        root = tempfile.mkdtemp(prefix="c11-509-env-")
        path = os.path.join(root, "fake.sock")
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = path
        proc = subprocess.run(
            [sys.executable, "-c", "import os; print(os.environ['C11_SOCKET']); print(os.environ['CMUX_SOCKET'])"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        print(proc.stdout.strip())
        if proc.returncode != 0:
            raise SystemExit(proc.stderr)
        lines = proc.stdout.strip().splitlines()
        assert lines == [path, path], lines
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or not result.stdout.strip().endswith("ok"):
        fail(f"child env\nstdout={result.stdout}\nstderr={result.stderr}")


def test_child_without_socket_env_receives_sentinel() -> None:
    script = textwrap.dedent(
        f"""
        import os, subprocess, sys
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        env = os.environ.copy()
        for key in socket_guard.SOCKET_ENV_KEYS:
            env.pop(key, None)
        proc = subprocess.run(
            [sys.executable, "-c", "import os; print(os.environ.get('C11_SOCKET_PATH', ''))"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        assert proc.stdout.strip() == socket_guard.SENTINEL, proc.stdout
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"sentinel child\nstdout={result.stdout}\nstderr={result.stderr}")


def test_operator_identity_is_not_forwarded() -> None:
    script = textwrap.dedent(
        f"""
        import os, subprocess, sys
        sys.path.insert(0, {TESTS_DIR!r})
        os.environ["C11_PANEL_ID"] = "panel-live"
        os.environ["C11_WORKSPACE_ID"] = "ws-live"
        import socket_guard
        socket_guard.install()
        env = os.environ.copy()
        env["C11_PANEL_ID"] = "panel-live"
        env["C11_WORKSPACE_ID"] = "ws-fresh"
        proc = subprocess.run(
            [sys.executable, "-c",
             "import os; print(repr(os.environ.get('C11_PANEL_ID'))); print(repr(os.environ.get('C11_WORKSPACE_ID')))"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        lines = proc.stdout.strip().splitlines()
        assert lines == ["None", "'ws-fresh'"], lines
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"identity\nstdout={result.stdout}\nstderr={result.stderr}")


def test_existing_foreign_env_is_refused() -> None:
    directory = tempfile.mkdtemp(prefix="c11-509-envrefuse-")
    path = os.path.join(directory, "live-looking.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    script = textwrap.dedent(
        f"""
        import os, subprocess, sys
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        env = os.environ.copy()
        env["C11_SOCKET_PATH"] = {path!r}
        try:
            subprocess.run([sys.executable, "-c", "print('no')"], env=env, check=False)
        except socket_guard.SocketGuardError as exc:
            print(type(exc).__name__)
            raise SystemExit(0)
        raise SystemExit("child was spawned")
        """
    )
    # The listener path is under a temp dir this process created, so this
    # process would allow it. Run the assertion in a child that did not
    # create the directory: pass the path in after that child's install.
    result = fresh(script)
    server.close()
    if result.returncode != 0 or "SocketGuardError" not in result.stdout:
        fail(f"env refuse\nstdout={result.stdout}\nstderr={result.stderr}")


def test_well_known_bind_requires_allow() -> None:
    script = textwrap.dedent(
        f"""
        import os, socket, sys
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        path = "/tmp/c11-509-well-known-missing.sock"
        # Not a well-known name. Use the app-support suffix under /tmp,
        # which the guard treats as a shared default.
        root = "/tmp/c11-509-wk"
        os.makedirs(root + "/Library/Application Support/c11", exist_ok=True)
        path = root + "/Library/Application Support/c11/c11.sock"
        if os.path.exists(path):
            os.remove(path)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.bind(path)
        except socket_guard.SocketGuardError:
            pass
        else:
            raise SystemExit("bind of well-known path succeeded")
        socket_guard.allow(path)
        client.bind(path)
        client.close()
        os.remove(path)
        print("ok")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"well-known bind\nstdout={result.stdout}\nstderr={result.stderr}")


def test_cmux_default_does_not_touch_canary() -> None:
    directory = tempfile.mkdtemp(prefix="c11-509-cmux-")
    path = os.path.join(directory, "canary.sock")
    accepted = {"n": 0}
    stop = threading.Event()

    def serve() -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(path)
            server.listen(4)
            server.settimeout(0.2)
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except TimeoutError:
                    continue
                accepted["n"] += 1
                conn.close()
        finally:
            server.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    deadline = time.time() + 2
    while not os.path.exists(path):
        if time.time() > deadline:
            stop.set()
            fail("cmux canary did not bind")
        time.sleep(0.02)
    script = textwrap.dedent(
        f"""
        import os, sys
        sys.path.insert(0, {TESTS_DIR!r})
        os.environ["CMUX_SOCKET_PATH"] = {path!r}
        os.environ["C11_SOCKET_PATH"] = {path!r}
        import socket_guard
        socket_guard.install()
        import cmux
        resolved = cmux.cmux().socket_path
        assert resolved == socket_guard.SENTINEL, resolved
        print("ok")
        """
    )
    result = fresh(script)
    time.sleep(0.3)
    stop.set()
    thread.join(timeout=2)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"cmux default\nstdout={result.stdout}\nstderr={result.stderr}")
    if accepted["n"] != 0:
        fail(f"cmux default connected to the canary ({accepted['n']})")


def test_live_app_scripts_refuse_without_opt_in() -> None:
    """Running a host-affecting file on a normal host exits before its body."""
    for name in sorted(socket_guard.LIVE_APP_SCRIPTS):
        env = os.environ.copy()
        env.pop(socket_guard.LIVE_APP_ENV, None)
        for key in socket_guard.SOCKET_ENV_KEYS:
            env[key] = socket_guard.SENTINEL
        proc = subprocess.run(
            [sys.executable, os.path.join(TESTS_DIR, name)],
            cwd=REPO,
            env=env,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if proc.returncode != 2 or f"refusing to start {name}" not in proc.stderr:
            fail(
                f"live app refusal {name}\n"
                f"code={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
            )
        if proc.stdout.strip():
            fail(f"live app script {name} printed before refusing:\n{proc.stdout}")

    script = textwrap.dedent(
        f"""
        import os, sys
        sys.path.insert(0, {TESTS_DIR!r})
        os.environ[{socket_guard.LIVE_APP_ENV!r}] = "1"
        import socket_guard
        for name in sorted(socket_guard.LIVE_APP_SCRIPTS):
            socket_guard.refuse_live_app(name)
        print("allowed")
        """
    )
    result = fresh(script)
    if result.returncode != 0 or result.stdout.strip() != "allowed":
        fail(f"live app opt-in\nstdout={result.stdout}\nstderr={result.stderr}")


def main() -> int:
    tests = [
        test_install_scrubs_to_sentinel,
        test_refuse_existing_socket_before_accept,
        test_bind_and_connect_under_test_temp,
        test_child_env_uses_test_socket_for_every_key,
        test_child_without_socket_env_receives_sentinel,
        test_operator_identity_is_not_forwarded,
        test_existing_foreign_env_is_refused,
        test_well_known_bind_requires_allow,
        test_cmux_default_does_not_touch_canary,
        test_live_app_scripts_refuse_without_opt_in,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"PASS {len(tests)} socket guard tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
