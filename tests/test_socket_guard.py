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
                except (TimeoutError, socket.timeout):
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
                except (TimeoutError, socket.timeout):
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


def test_pathlib_socket_argument_is_refused() -> None:
    """Popen accepts pathlib.Path. The guard must refuse that form too."""
    directory = tempfile.mkdtemp(prefix="c11-509-patharg-")
    path = os.path.join(directory, "foreign.sock")
    accepted = {"n": 0}
    stop = threading.Event()

    def serve() -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(path):
                os.remove(path)
            server.bind(path)
            server.listen(1)
            server.settimeout(0.2)
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except (TimeoutError, socket.timeout):
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
            fail("pathlib canary did not bind")
        time.sleep(0.02)
    script = textwrap.dedent(
        f"""
        import subprocess, sys
        from pathlib import Path
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        try:
            subprocess.run(
                [sys.executable, "--socket", Path({path!r}), "-c", "print('ran')"],
                check=False,
            )
        except socket_guard.SocketGuardError as exc:
            print(type(exc).__name__)
            raise SystemExit(0)
        raise SystemExit("child was spawned")
        """
    )
    result = fresh(script)
    time.sleep(0.2)
    stop.set()
    thread.join(timeout=2)
    if result.returncode != 0 or "SocketGuardError" not in result.stdout:
        fail(f"pathlib argv\nstdout={result.stdout}\nstderr={result.stderr}")
    if accepted["n"] != 0:
        fail(f"pathlib argv connected ({accepted['n']})")


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


class Listener:
    """A private unix listener that counts what reaches it. Stands in for a live socket."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.accepted = 0
        self._stop = threading.Event()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(path)
        self._server.listen(16)
        self._server.settimeout(0.05)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except (TimeoutError, socket.timeout):
                continue
            except OSError:
                return
            self.accepted += 1
            conn.close()

    def close(self) -> None:
        # A connect that finished before the child exited is still in the backlog.
        time.sleep(0.2)
        self._stop.set()
        self._thread.join(timeout=2)
        self._server.close()


PROBE_SOURCE = """\
import os, socket, sys
path = None
if "--socket" in sys.argv:
    path = sys.argv[sys.argv.index("--socket") + 1]
elif any(arg.startswith("--socket=") for arg in sys.argv):
    path = next(arg for arg in sys.argv if arg.startswith("--socket=")).split("=", 1)[1]
else:
    for key in ("C11_SOCKET_PATH", "C11_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET"):
        value = os.environ.get(key, "")
        if value and not value.startswith("/c11-unroutable"):
            path = value
            break
if path is None:
    print("no socket")
    raise SystemExit(0)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(2)
client.connect(path)
client.close()
print("connected")
"""


class BypassRig:
    """One told-live listener, one foreign listener nobody names, and an unguarded probe."""

    def __init__(self) -> None:
        self.directory = tempfile.mkdtemp(prefix="c573-")
        self.live = Listener(os.path.join(self.directory, "live.sock"))
        self.foreign = Listener(os.path.join(self.directory, "foreign.sock"))
        self.probe = os.path.join(self.directory, "probe.py")
        with open(self.probe, "w", encoding="utf-8") as handle:
            handle.write(PROBE_SOURCE)

    def close(self) -> None:
        self.live.close()
        self.foreign.close()

    def run_case(self, body: str) -> subprocess.CompletedProcess[str]:
        """Run ``body`` in a fresh guarded child that did not create these sockets."""
        script = "\n".join(
            [
                "import os, shlex, socket, subprocess, sys, tempfile",
                f"sys.path.insert(0, {TESTS_DIR!r})",
                f"LIVE = {self.live.path!r}",
                f"FOREIGN = {self.foreign.path!r}",
                f"DIR = {self.directory!r}",
                f"PROBE = {self.probe!r}",
                "PY = sys.executable",
                'os.environ["C11_SOCKET_PATH"] = LIVE',
                "import socket_guard",
                "socket_guard.install()",
                "try:",
                textwrap.indent(textwrap.dedent(body).strip(), "    "),
                "except socket_guard.SocketGuardError as exc:",
                '    print("refused:", exc)',
                "    raise SystemExit(0)",
                'print("not refused")',
            ]
        )
        return subprocess.run(
            [sys.executable, "-c", script],
            cwd=REPO,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )


def assert_all_refused(label: str, cases: dict[str, str]) -> None:
    """Every case must be refused, and neither listener may see a connection."""
    rig = BypassRig()
    problems = []
    try:
        for name, body in cases.items():
            result = rig.run_case(body)
            if result.returncode != 0 or "refused:" not in result.stdout:
                problems.append(
                    f"{name}: rc={result.returncode} "
                    f"stdout={result.stdout.strip()!r} stderr={result.stderr.strip()[-300:]!r}"
                )
    finally:
        rig.close()
    accepted = rig.live.accepted + rig.foreign.accepted
    if problems or accepted:
        detail = "\n  ".join(problems)
        fail(f"{label}: {len(problems)} of {len(cases)} not refused, listeners accepted {accepted}\n  {detail}")


def test_shell_strings_are_refused() -> None:
    """A command string is tokenized, so a flag or assignment inside it is seen."""
    assert_all_refused(
        "shell string",
        {
            "shell_true_socket_flag": 'subprocess.run(f"{PY} {PROBE} --socket {FOREIGN}", shell=True, check=False)',
            "shell_true_socket_equals": 'subprocess.run(f"{PY} {PROBE} --socket={FOREIGN}", shell=True, check=False)',
            "shell_true_env_prefix": 'subprocess.run(f"C11_SOCKET_PATH={FOREIGN} {PY} {PROBE}", shell=True, check=False)',
            "shell_true_cmux_key": 'subprocess.run(f"CMUX_SOCKET_PATH={FOREIGN} {PY} {PROBE}", shell=True, check=False)',
            "shell_true_export": 'subprocess.run(f"export C11_SOCKET_PATH={FOREIGN}; {PY} {PROBE}", shell=True, check=False)',
            "shell_true_list": 'subprocess.run([f"{PY} {PROBE} --socket {FOREIGN}"], shell=True, check=False)',
            "shell_true_assembled_live": 'subprocess.run(f"D={DIR}; {PY} {PROBE} --socket $D/live.sock", shell=True, check=False)',
            "shell_true_quote_split_live": """subprocess.run(f'{PY} {PROBE} --socket "{LIVE[:6]}""{LIVE[6:]}"', shell=True, check=False)""",
            "sh_c_socket_flag": 'subprocess.run(["/bin/sh", "-c", f"{PY} {PROBE} --socket {LIVE}"], check=False)',
            "sh_c_env_prefix": 'subprocess.run(["/bin/sh", "-c", f"C11_SOCKET_PATH={LIVE} {PY} {PROBE}"], check=False)',
            "sh_c_nested": """subprocess.run(["/bin/sh", "-c", f"/bin/sh -c '{PY} {PROBE} --socket {LIVE}'"], check=False)""",
            "env_argv_assignment": 'subprocess.run(["/usr/bin/env", f"C11_SOCKET_PATH={LIVE}", PY, PROBE], check=False)',
            "os_popen": 'os.popen(f"{PY} {PROBE} --socket {FOREIGN}").read()',
            "generator_argv": 'subprocess.Popen(iter([PY, PROBE, "--socket", FOREIGN])).wait()',
            "bytes_env_key": 'subprocess.run([PY, PROBE], env={b"C11_SOCKET_PATH": os.fsencode(LIVE), b"PATH": b"/usr/bin:/bin"}, check=False)',
            "python_c_connect": 'subprocess.run([PY, "-c", f"import socket; socket.socket(socket.AF_UNIX).connect({LIVE!r})"], check=False)',
            "endpoint_inside_a_word": """subprocess.run([PY, "-c", "import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1].split(':')[1].split(',')[0])", f"UNIX-CONNECT:{LIVE},retry=1"], check=False)""",
        },
    )


def test_relative_socket_paths_use_the_child_directory() -> None:
    """A relative endpoint means a path under the directory the child runs in."""
    assert_all_refused(
        "relative path",
        {
            "env_kwarg_child_cwd": 'subprocess.run([PY, PROBE], cwd=DIR, env={"C11_SOCKET_PATH": "live.sock"}, check=False)',
            "env_kwarg_bytes_cwd": 'subprocess.run([PY, PROBE], cwd=os.fsencode(DIR), env={"C11_SOCKET_PATH": "live.sock"}, check=False)',
            "env_kwarg_foreign": 'subprocess.run([PY, PROBE], cwd=DIR, env={"C11_SOCKET_PATH": "foreign.sock"}, check=False)',
            "positional_cwd_and_env": 'subprocess.Popen([PY, PROBE], -1, None, None, None, None, None, True, False, DIR, {"C11_SOCKET_PATH": "live.sock"}).wait()',
            "env_kwarg_cwd_in_shell": 'subprocess.run(f"cd {DIR}; {PY} {PROBE}", shell=True, env={"C11_SOCKET_PATH": "live.sock"}, check=False)',
            "shell_cd_socket_flag": 'subprocess.run(f"cd {DIR}; {PY} {PROBE} --socket live.sock", shell=True, check=False)',
            "shell_cd_env_prefix": 'subprocess.run(f"cd {DIR} && C11_SOCKET_PATH=foreign.sock {PY} {PROBE}", shell=True, check=False)',
            "shell_cd_newline": 'subprocess.run(f"cd {DIR}\\n{PY} {PROBE} --socket foreign.sock", shell=True, check=False)',
            "shell_subshell_cd": 'subprocess.run(f"(cd {DIR}; {PY} {PROBE} --socket foreign.sock)", shell=True, check=False)',
            "shell_cd_chain": """subprocess.run(f"cd {os.path.dirname(DIR)} && cd {os.path.basename(DIR)} && {PY} {PROBE} --socket foreign.sock", shell=True, check=False)""",
            "sh_c_cd": 'subprocess.run(["/bin/sh", "-c", f"cd {DIR}; {PY} {PROBE} --socket foreign.sock"], check=False)',
            "shell_cd_unreadable": 'subprocess.run(f"cd $(printf %s {DIR}); {PY} {PROBE} --socket foreign.sock", shell=True, check=False)',
            "system_cd_socket_flag": 'os.system(f"cd {DIR}; {PY} {PROBE} --socket foreign.sock")',
        },
    )


def test_cleared_socket_env_stays_on_the_sentinel() -> None:
    """A test that clears the socket variables must not hand a child implicit discovery."""
    rig = BypassRig()
    default_helper = os.path.join(rig.directory, "default_helper.py")
    with open(default_helper, "w", encoding="utf-8") as handle:
        handle.write(
            textwrap.dedent(
                f"""
                import os, socket, sys
                path = os.environ.get("C11_SOCKET_PATH") or {rig.live.path!r}
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(2)
                try:
                    client.connect(path)
                except OSError:
                    print("no default")
                    raise SystemExit(0)
                print("connected default")
                """
            )
        )
    forms = {
        "system": "os.system(f'{PY} {HELPER}')",
        "popen": "os.popen(f'{PY} {HELPER}').read()",
        "subprocess": "subprocess.run([PY, HELPER], check=False)",
        "execv": "os.execv(PY, [PY, HELPER])",
        "spawnv": "os.spawnv(os.P_WAIT, PY, [PY, HELPER])",
    }
    problems = []
    try:
        for name, form in forms.items():
            result = rig.run_case(
                "\n".join(
                    [
                        f"HELPER = {default_helper!r}",
                        "for key in socket_guard.SOCKET_ENV_KEYS:",
                        "    os.environ.pop(key, None)",
                        form,
                    ]
                )
            )
            if "connected default" in result.stdout:
                problems.append(f"{name}: {result.stdout.strip()!r}")
    finally:
        rig.close()
    if problems or rig.live.accepted:
        fail(f"cleared env reached the default, accepted {rig.live.accepted}: {problems}")


def test_harmless_data_naming_a_similar_path_still_runs() -> None:
    """Only a complete endpoint is refused. A longer path that contains it is just data."""
    rig = BypassRig()
    try:
        result = rig.run_case(
            """
            show = [PY, "-c", "import sys; print(sys.argv[1])"]
            for word in (
                "diagnostic=" + LIVE + ".backup",
                LIVE + ".backup",
                LIVE + "-old",
                LIVE + "/child",
                "/backup" + LIVE,
                "note: " + LIVE + "x is gone",
            ):
                proc = subprocess.run(show + [word], check=True, capture_output=True, text=True)
                assert proc.stdout.strip() == word, proc.stdout
            proc = subprocess.run(f"echo {LIVE}.backup", shell=True, check=True, capture_output=True, text=True)
            assert proc.stdout.strip() == LIVE + ".backup", proc.stdout
            print("ok")
            """
        )
    finally:
        rig.close()
    if result.returncode != 0 or "ok" not in result.stdout or "refused:" in result.stdout:
        fail(f"harmless data\nstdout={result.stdout}\nstderr={result.stderr}")
    if rig.live.accepted or rig.foreign.accepted:
        fail("harmless data reached a listener")


def test_wrappers_keep_the_original_api() -> None:
    """Valid calls, malformed calls and return values match the unwrapped functions."""
    directory = tempfile.mkdtemp(prefix="c573-api-")
    marker = os.path.join(directory, "launched")
    script = textwrap.dedent(
        f"""
        import inspect, os, signal, subprocess, sys
        sys.path.insert(0, {TESTS_DIR!r})
        import socket_guard
        socket_guard.install()
        MARKER = {marker!r}
        SH = "/bin/sh"
        TOUCH = ["sh", "-c", "touch " + MARKER]
        SEVEN = ["sh", "-c", "exit 7"]
        ENV = dict(os.environ)

        def launched():
            found = os.path.exists(MARKER)
            if found:
                os.remove(MARKER)
            return found

        def raises_type_error(call):
            try:
                call()
            except TypeError:
                pass
            else:
                raise AssertionError("no TypeError")
            assert not launched(), "a malformed call launched a child"

        # The names match, so a keyword call means the same thing.
        originals = dict(socket_guard._orig_spawn)
        originals["execve"] = socket_guard._orig_execve
        originals["system"] = socket_guard._orig_system
        for name, original in originals.items():
            expected = list(inspect.signature(original).parameters)
            actual = list(inspect.signature(getattr(os, name)).parameters)
            assert expected == actual, (name, expected, actual)

        # Valid keyword forms.
        assert os.spawnv(mode=os.P_WAIT, file=SH, args=SEVEN) == 7
        assert os.spawnvp(mode=os.P_WAIT, file="sh", args=SEVEN) == 7
        assert os.spawnve(mode=os.P_WAIT, file=SH, args=SEVEN, env=ENV) == 7
        assert os.spawnvpe(mode=os.P_WAIT, file="sh", args=SEVEN, env=ENV) == 7
        assert os.spawnve(os.P_WAIT, SH, SEVEN, ENV) == 7
        assert os.spawnl(os.P_WAIT, SH, *SEVEN) == 7
        assert os.spawnle(os.P_WAIT, SH, *SEVEN, ENV) == 7
        assert os.spawnlp(os.P_WAIT, "sh", *SEVEN) == 7
        assert os.spawnlpe(os.P_WAIT, "sh", *SEVEN, ENV) == 7
        pid = os.fork()
        if pid == 0:
            try:
                os.execve(path=SH, argv=SEVEN, env=ENV)
            finally:
                os._exit(99)
        assert os.waitpid(pid, 0)[1] == 7 << 8
        pid = os.posix_spawn(SH, SEVEN, ENV)
        assert os.waitpid(pid, 0)[1] == 7 << 8
        pid = os.posix_spawnp("sh", SEVEN, ENV, setsid=True)
        assert os.waitpid(pid, 0)[1] == 7 << 8

        # A required env stays required, and nothing launches without it.
        raises_type_error(lambda: os.spawnve(os.P_WAIT, SH, TOUCH))
        raises_type_error(lambda: os.spawnvpe(os.P_WAIT, "sh", TOUCH))
        raises_type_error(lambda: os.spawnve(mode=os.P_WAIT, file=SH, args=TOUCH))
        raises_type_error(lambda: os.execve(SH, TOUCH))
        raises_type_error(lambda: os.execve(SH, TOUCH, None))
        raises_type_error(lambda: os.posix_spawn(SH, TOUCH))
        if sys.version_info < (3, 13):
            raises_type_error(lambda: os.posix_spawn(SH, TOUCH, None))
            raises_type_error(lambda: os.posix_spawnp("sh", TOUCH, None))
        else:
            # Since 3.13, None means inherit.
            assert os.waitpid(os.posix_spawn(SH, SEVEN, None), 0)[1] == 7 << 8
            assert os.waitpid(os.posix_spawnp("sh", SEVEN, None), 0)[1] == 7 << 8
        raises_type_error(lambda: os.spawnv(os.P_WAIT, SH, TOUCH, ENV))
        # The originals' child fails on a None env, so the status is 127 and nothing runs.
        assert os.spawnve(os.P_WAIT, SH, TOUCH, None) == 127
        assert not launched()
        assert os.spawnvpe(os.P_WAIT, "sh", TOUCH, None) == 127
        assert not launched()

        # os.system: the same raw wait status, signals included.
        assert os.system("exit 7") == 7 << 8
        assert os.system("exit 0") == 0
        assert os.system("kill -9 $$") == signal.SIGKILL
        parameter = next(iter(inspect.signature(socket_guard._orig_system).parameters))
        assert os.system(**{{parameter: "exit 7"}}) == 7 << 8
        assert os.system(b"exit 7") == 7 << 8
        raises_type_error(lambda: os.system(5))
        # It sends the sanitized env and leaves the process-wide mapping alone.
        os.environ["C11_SOCKET_PATH"] = "/c573-missing/a.sock"
        before = dict(os.environ)
        before_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
        assert os.system('test "$CMUX_SOCKET" = /c573-missing/a.sock') == 0
        assert dict(os.environ) == before
        assert signal.pthread_sigmask(signal.SIG_BLOCK, []) == before_mask
        print("ok")
        """
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=REPO,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"wrapper api\nstdout={result.stdout}\nstderr={result.stderr}")


def test_exec_and_spawn_are_refused() -> None:
    """Every os.exec*, os.spawn* and os.posix_spawn* form is refused before the child runs."""
    env = '{**os.environ, "C11_SOCKET_PATH": LIVE}'
    # Since Python 3.13, posix_spawn's env=None means inherit. Before that, the
    # original raises TypeError, so there is nothing to refuse.
    inherit_none: dict[str, str] = {}
    if sys.version_info >= (3, 13):
        inherit_none = {
            "posix_spawn_none_env_argv": 'os.waitpid(os.posix_spawn(PY, [PY, PROBE, "--socket", LIVE], None), 0)',
            "posix_spawn_none_env_mutated": 'os.environ["C11_SOCKET_PATH"] = LIVE; os.waitpid(os.posix_spawn(PY, [PY, PROBE], None), 0)',
            "posix_spawnp_none_env_argv": 'os.waitpid(os.posix_spawnp(PY, [PY, PROBE, "--socket", LIVE], None), 0)',
        }
    assert_all_refused(
        "exec and spawn",
        {
            **inherit_none,
            "execv": 'os.execv(PY, [PY, PROBE, "--socket", LIVE])',
            "execv_shell": 'os.execv("/bin/sh", ["/bin/sh", "-c", f"{PY} {PROBE} --socket {LIVE}"])',
            "execv_mutated_environ": 'os.environ["C11_SOCKET_PATH"] = LIVE; os.execv(PY, [PY, PROBE])',
            "execl": 'os.execl(PY, PY, PROBE, "--socket", LIVE)',
            "execlp": 'os.execlp(PY, PY, PROBE, "--socket", LIVE)',
            "execvp": 'os.execvp(PY, [PY, PROBE, "--socket", LIVE])',
            "execve_env": f"os.execve(PY, [PY, PROBE], {env})",
            "execle_env": f"os.execle(PY, PY, PROBE, {env})",
            "execlpe_env": f"os.execlpe(PY, PY, PROBE, {env})",
            "execvpe_env": f"os.execvpe(PY, [PY, PROBE], {env})",
            "spawnv": 'os.spawnv(os.P_WAIT, PY, [PY, PROBE, "--socket", LIVE])',
            "spawnl": 'os.spawnl(os.P_WAIT, PY, PY, PROBE, "--socket", LIVE)',
            "spawnvp": 'os.spawnvp(os.P_WAIT, PY, [PY, PROBE, "--socket", LIVE])',
            "spawnlp": 'os.spawnlp(os.P_WAIT, PY, PY, PROBE, "--socket", LIVE)',
            "spawnve_env": f"os.spawnve(os.P_WAIT, PY, [PY, PROBE], {env})",
            "spawnle_env": f"os.spawnle(os.P_WAIT, PY, PY, PROBE, {env})",
            "spawnvpe_env": f"os.spawnvpe(os.P_WAIT, PY, [PY, PROBE], {env})",
            "spawnlpe_env": f"os.spawnlpe(os.P_WAIT, PY, PY, PROBE, {env})",
            "spawnv_mutated_environ": 'os.environ["C11_SOCKET_PATH"] = LIVE; os.spawnv(os.P_WAIT, PY, [PY, PROBE])',
            "posix_spawn_argv": 'os.waitpid(os.posix_spawn(PY, [PY, PROBE, "--socket", LIVE], dict(os.environ)), 0)',
            "posix_spawn_env": f"os.waitpid(os.posix_spawn(PY, [PY, PROBE], {env}), 0)",
            "posix_spawnp_argv": 'os.waitpid(os.posix_spawnp(PY, [PY, PROBE, "--socket", LIVE], dict(os.environ)), 0)',
            "posix_spawnp_env": f"os.waitpid(os.posix_spawnp(PY, [PY, PROBE], {env}), 0)",
            "system_flag": 'os.system(f"{PY} {PROBE} --socket {LIVE}")',
            "system_env_prefix": 'os.system(f"C11_SOCKET_PATH={LIVE} {PY} {PROBE}")',
            "system_mutated_environ": 'os.environ["C11_SOCKET_PATH"] = LIVE; os.system(f"{PY} {PROBE}")',
        },
    )


def test_symlinks_resolve_before_the_allowlist() -> None:
    """A link in an allowed temp dir inherits nothing, however it got allowed."""
    connect = (
        "client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); "
        "client.settimeout(2); client.connect(link)"
    )
    make_link = 'root = tempfile.mkdtemp(prefix="c573-own-"); link = os.path.join(root, "x.sock")'
    bind_then_swap = "\n".join(
        [
            make_link,
            "own = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); own.bind(link); own.close()",
            "os.remove(link); os.symlink({target}, link)",
        ]
    )
    allowed_link = "\n".join([make_link, "os.symlink({target}, link)", "socket_guard.allow(link)"])
    assert_all_refused(
        "symlink",
        {
            "bound_path_swapped_for_live_link_connect": bind_then_swap.format(target="LIVE") + "\n" + connect,
            "bound_path_swapped_for_foreign_link_connect": bind_then_swap.format(target="FOREIGN") + "\n" + connect,
            "bound_path_swapped_child_socket_flag": bind_then_swap.format(target="LIVE")
            + '\nsubprocess.run([PY, PROBE, "--socket", link], check=False)',
            "bound_path_swapped_child_env": bind_then_swap.format(target="LIVE")
            + '\nsubprocess.run([PY, PROBE], env={**os.environ, "C11_SOCKET_PATH": link}, check=False)',
            "allow_live_link": allowed_link.format(target="LIVE") + "\n" + connect,
            "allow_foreign_link": allowed_link.format(target="FOREIGN") + "\n" + connect,
            "allow_live_itself": "socket_guard.allow(LIVE)\nlink = LIVE\n" + connect,
            "fake_server_env_live_link": "\n".join(
                [
                    make_link,
                    "os.symlink(LIVE, link)",
                    "from fake_server_env import fake_server_env",
                    "subprocess.run([PY, PROBE], env=fake_server_env(link), check=False)",
                ]
            ),
            "fake_server_env_live": "\n".join(
                [
                    "from fake_server_env import fake_server_env",
                    "subprocess.run([PY, PROBE], env=fake_server_env(LIVE), check=False)",
                ]
            ),
            "allow_through_linked_directory": "\n".join(
                [
                    'root = tempfile.mkdtemp(prefix="c573-own-")',
                    'os.symlink(DIR, os.path.join(root, "d"))',
                    'link = os.path.join(root, "d", "live.sock")',
                    "socket_guard.allow(link)",
                    connect,
                ]
            ),
        },
    )


def test_live_socket_named_directly_stays_refused() -> None:
    """The forms the guard already refused keep refusing the told-live path."""
    assert_all_refused(
        "named directly",
        {
            "shell_true_flag": 'subprocess.run(f"{PY} {PROBE} --socket {LIVE}", shell=True, check=False)',
            "shell_true_env_prefix": 'subprocess.run(f"C11_SOCKET_PATH={LIVE} {PY} {PROBE}", shell=True, check=False)',
            "argv_flag": 'subprocess.run([PY, PROBE, "--socket", LIVE], check=False)',
            "env_kwarg": 'subprocess.run([PY, PROBE], env={**os.environ, "C11_SOCKET_PATH": LIVE}, check=False)',
            "link_in_temp_root": "\n".join(
                [
                    'root = tempfile.mkdtemp(prefix="c573-own-")',
                    'link = os.path.join(root, "x.sock")',
                    "os.symlink(LIVE, link)",
                    "client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)",
                    "client.settimeout(2)",
                    "client.connect(link)",
                ]
            ),
        },
    )


def test_private_listener_traffic_still_works() -> None:
    """Every guarded form reaches a socket the test made, so ordinary tests keep working."""
    rig = BypassRig()
    try:
        script = textwrap.dedent(
            f"""
            import os, socket, subprocess, sys, tempfile, threading, time
            sys.path.insert(0, {TESTS_DIR!r})
            import socket_guard
            socket_guard.install()
            PY = sys.executable
            PROBE = {rig.probe!r}
            root = tempfile.mkdtemp(prefix="c573-own-")
            OWN = os.path.join(root, "own.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(OWN)
            server.listen(32)
            server.settimeout(0.05)
            count = {{"n": 0}}
            stop = threading.Event()
            def serve():
                while not stop.is_set():
                    try:
                        conn, _ = server.accept()
                    except (TimeoutError, socket.timeout):
                        continue
                    count["n"] += 1
                    conn.close()
            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            env = {{**os.environ, "C11_SOCKET_PATH": OWN}}
            sub = lambda *a, **k: subprocess.run(*a, check=True, **k)
            forms = [
                lambda: sub(f"{{PY}} {{PROBE}} --socket {{OWN}}", shell=True),
                lambda: sub(f"C11_SOCKET_PATH={{OWN}} {{PY}} {{PROBE}}", shell=True),
                lambda: sub(["/bin/sh", "-c", f"{{PY}} {{PROBE}} --socket {{OWN}}"]),
                lambda: sub(["/usr/bin/env", f"C11_SOCKET_PATH={{OWN}}", PY, PROBE]),
                lambda: sub([PY, PROBE, "--socket", OWN]),
                lambda: sub([PY, PROBE], env=env),
                lambda: subprocess.Popen(iter([PY, PROBE, "--socket", OWN])).wait(),
                lambda: os.system(f"{{PY}} {{PROBE}} --socket {{OWN}}"),
                lambda: os.spawnv(os.P_WAIT, PY, [PY, PROBE, "--socket", OWN]),
                lambda: os.spawnve(os.P_WAIT, PY, [PY, PROBE], env),
                lambda: os.spawnlp(os.P_WAIT, PY, PY, PROBE, "--socket", OWN),
                lambda: os.waitpid(os.posix_spawn(PY, [PY, PROBE], env), 0),
                lambda: os.waitpid(os.posix_spawnp(PY, [PY, PROBE, "--socket", OWN], dict(os.environ)), 0),
                lambda: sub([PY, PROBE], cwd=root, env={{**os.environ, "C11_SOCKET_PATH": "own.sock"}}),
                lambda: sub(f"cd {{root}}; {{PY}} {{PROBE}} --socket own.sock", shell=True),
                lambda: sub(f"cd {{root}} && C11_SOCKET_PATH=own.sock {{PY}} {{PROBE}}", shell=True),
                lambda: subprocess.Popen([PY, PROBE], -1, None, None, None, None, None, True, False, root, {{**os.environ, "C11_SOCKET_PATH": "own.sock"}}).wait(),
            ]
            for form in forms:
                form()
            # exec replaces the process, so it runs in a forked child.
            pid = os.fork()
            if pid == 0:
                try:
                    os.execve(PY, [PY, PROBE], env)
                finally:
                    os._exit(99)
            os.waitpid(pid, 0)
            expected = len(forms) + 1
            deadline = time.time() + 3
            while count["n"] < expected and time.time() < deadline:
                time.sleep(0.02)
            stop.set()
            thread.join(timeout=2)
            assert count["n"] == expected, (count["n"], expected)
            # A socket that does not exist yet is not refused: missing-socket
            # tests rely on getting the CLI's own error.
            missing = os.path.join(root, "not-there.sock")
            proc = subprocess.run(f"echo {{missing}} --socket {{missing}}", shell=True, capture_output=True, text=True, check=True)
            assert missing in proc.stdout, proc.stdout
            # A deleted working directory is the child's problem, not the guard's.
            gone = tempfile.mkdtemp(prefix="c573-gone-")
            os.chdir(gone)
            os.rmdir(gone)
            assert subprocess.run(["/bin/sh", "-c", "exit 3"], cwd="/").returncode == 3
            assert subprocess.run("exit 4", shell=True, cwd="/").returncode == 4
            assert subprocess.run(["/bin/sh", "-c", "exit 5"]).returncode == 5
            assert os.system("exit 6") == 6 << 8
            print("ok")
            """
        )
        result = subprocess.run(
            [sys.executable, "-c", script],
            cwd=REPO,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
    finally:
        rig.close()
    if result.returncode != 0 or not result.stdout.strip().endswith("ok"):
        fail(f"private listener\nstdout={result.stdout}\nstderr={result.stderr}")
    if rig.live.accepted or rig.foreign.accepted:
        fail("private listener traffic reached another socket")


def test_helper_fixture_socket_is_not_a_false_positive() -> None:
    """A fixture a helper process made must pass, in or out of the guard's tracking."""
    untracked = f"/tmp/c573-fixture-{os.getpid()}.sock"
    if os.path.exists(untracked):
        os.remove(untracked)
    server = Listener(untracked)
    tracked_root = tempfile.mkdtemp(prefix="c573-fx-")
    try:
        script = textwrap.dedent(
            f"""
            import os, subprocess, sys, tempfile, time
            sys.path.insert(0, {TESTS_DIR!r})
            import socket_guard
            socket_guard.install()
            PY = sys.executable
            UNTRACKED = {untracked!r}
            # A word that only mentions a helper's socket does not connect it.
            subprocess.run([PY, "-c", "pass", "--listen", UNTRACKED], check=True)
            subprocess.run(f"{{PY}} -c pass --listen {{UNTRACKED}}", shell=True, check=True)
            # A helper child binds under a temp dir this test made, then the test uses it.
            root = tempfile.mkdtemp(prefix="c573-kid-")
            path = os.path.join(root, "kid.sock")
            helper = "import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(3)"
            kid = subprocess.Popen([PY, "-c", helper, path])
            deadline = time.time() + 2
            while not os.path.exists(path):
                assert time.time() < deadline, "helper did not bind"
                time.sleep(0.02)
            subprocess.run([PY, "-c", "pass", "--socket", path], check=True)
            subprocess.run(f"C11_SOCKET_PATH={{path}} {{PY}} -c pass", shell=True, check=True)
            kid.kill()
            kid.wait()
            print("ok")
            """
        )
        result = subprocess.run(
            [sys.executable, "-c", script],
            cwd=tracked_root,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
    finally:
        server.close()
        os.remove(untracked)
    if result.returncode != 0 or result.stdout.strip() != "ok":
        fail(f"helper fixture\nstdout={result.stdout}\nstderr={result.stderr}")


def test_live_app_gate_sees_runners_other_than_a_script() -> None:
    """``-m unittest`` and ``runpy`` put a runner in argv[0]. The gate still fires."""
    name = sorted(socket_guard.LIVE_APP_SCRIPTS)[0]
    # A stand-in with the same name. The real file's body never runs here.
    directory = tempfile.mkdtemp(prefix="c573-gate-")
    stand_in = os.path.join(directory, name)
    with open(stand_in, "w", encoding="utf-8") as handle:
        handle.write(
            textwrap.dedent(
                f"""
                import sys
                sys.path.insert(0, {TESTS_DIR!r})
                import socket_guard
                socket_guard.install()
                print("BODY RAN")
                """
            )
        )
    env = os.environ.copy()
    env.pop(socket_guard.LIVE_APP_ENV, None)
    module = name[: -len(".py")]
    runs = {
        "unittest": [sys.executable, "-m", "unittest", module],
        "import": [sys.executable, "-c", f"import {module}"],
        "runpy": [sys.executable, "-c", f"import runpy; runpy.run_path({stand_in!r})"],
    }
    for label, command in runs.items():
        proc = subprocess.run(
            command,
            cwd=directory,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        if "BODY RAN" in proc.stdout or f"refusing to start {name}" not in proc.stderr:
            fail(f"live app gate via {label}\ncode={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}")


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
        test_pathlib_socket_argument_is_refused,
        test_live_app_scripts_refuse_without_opt_in,
        test_shell_strings_are_refused,
        test_relative_socket_paths_use_the_child_directory,
        test_exec_and_spawn_are_refused,
        test_cleared_socket_env_stays_on_the_sentinel,
        test_wrappers_keep_the_original_api,
        test_harmless_data_naming_a_similar_path_still_runs,
        test_symlinks_resolve_before_the_allowlist,
        test_live_socket_named_directly_stays_refused,
        test_private_listener_traffic_still_works,
        test_helper_fixture_socket_is_not_a_false_positive,
        test_live_app_gate_sees_runners_other_than_a_script,
    ]
    # Name tests on the command line to run a subset, as the red proof does.
    if sys.argv[1:]:
        tests = [test for test in tests if test.__name__ in sys.argv[1:]]
        if not tests:
            fail(f"no test named {sys.argv[1:]}")
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"PASS {len(tests)} socket guard tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
