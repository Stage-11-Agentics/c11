#!/usr/bin/env python3
"""
Regression tests for the Resources/bin/grok native-mail leader launch (C11-477).

The wrapper adds Grok's `--leader --leader-socket /tmp/c11-grok-leader-<pid>.sock`
only for interactive c11 launches the operator did not already steer, starts the
`c11 grok-mailbox` sidecar, and reaps exactly its own leader when Grok exits.
"""

from __future__ import annotations
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import pty
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "grok"

# A stand-in for Grok's leader: listens on the socket, records its PID in the
# lock beside it (as Grok does), and lives until signalled.
FAKE_LEADER = """
import os, socket, sys, time
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
with open(path[:-len(".sock")] + ".lock", "w") as f:
    f.write(str(os.getpid()))
while True:
    time.sleep(1)
"""


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie child of this test still answers kill(0); reap if it is ours.
    try:
        done, _ = os.waitpid(pid, os.WNOHANG)
        return done == 0
    except ChildProcessError:
        return True


def wait_for(predicate, timeout: float = 6.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def start_fake_leader(tmp: Path, sock: str) -> int:
    helper = tmp / "fake_leader.py"
    helper.write_text(FAKE_LEADER, encoding="utf-8")
    proc = subprocess.Popen([sys.executable, "-I", str(helper), sock], start_new_session=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert wait_for(lambda: Path(sock[:-5] + ".lock").exists() and Path(sock[:-5] + ".lock").read_text())
    return proc.pid


class Run:
    def __init__(self, argv: list[str], *, env_extra: dict[str, str] | None = None,
                 interactive: bool = True, no_leader_support: bool = False, spawn_leader: bool = False,
                 tmpdir: str | None = None):
        # Under /tmp so the wrapper's TMPDIR stays short enough to hold the socket.
        self.td = tempfile.TemporaryDirectory(prefix="c11-grok-test-", dir="/tmp")
        tmp = Path(self.td.name)
        self.tmp = tmp
        home = tmp / "home"
        home.mkdir()
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir()
        real_dir.mkdir()
        shutil.copy2(SOURCE_WRAPPER, wrapper_dir / "grok")
        (wrapper_dir / "grok").chmod(0o755)
        (tmp / "fake_leader.py").write_text(FAKE_LEADER, encoding="utf-8")
        self.real_log = tmp / "real-args.log"
        self.c11_log = tmp / "c11.log"
        self.leader_pid_file = tmp / "leader.pid"
        make_executable(real_dir / "grok", f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "--leader" && "${{2:-}}" == "--version" ]]; then
  [[ "${{FAKE_NO_LEADER:-0}}" == "1" ]] && {{ echo "error: unexpected argument '--leader' found" >&2; exit 2; }}
  echo "grok 1.0.70"; exit 0
fi
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"; done
sock=""
prev=""
for arg in "$@"; do [[ "$prev" == "--leader-socket" ]] && sock="$arg"; prev="$arg"; done
if [[ "${{FAKE_SPAWN_LEADER:-0}}" == "1" && -n "$sock" ]]; then
  {sys.executable} -I "{tmp}/fake_leader.py" "$sock" </dev/null >/dev/null 2>&1 &
  echo $! > "{self.leader_pid_file}"
  for _ in $(seq 1 100); do [[ -s "${{sock%.sock}}.lock" ]] && break; sleep 0.05; done
fi
exit 0
""")
        make_executable(wrapper_dir / "c11", """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_C11_LOG"
[[ "${1:-}" == "--socket" ]] && shift 2
[[ "${1:-}" == "ping" ]] && exit 0
[[ "${1:-}" == "grok-mailbox" && -n "${FAKE_SIDECAR_EXIT:-}" ]] && exit "$FAKE_SIDECAR_EXIT"
exit 0
""")
        self.app_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        app_path = str(tmp / "c11.sock")
        self.app_socket.bind(app_path)
        env = os.environ.copy()
        for key in [k for k in env if k.startswith(("C11_", "CMUX_", "GROK_"))]:
            env.pop(key)
        env.update({
            "HOME": str(home), "TMPDIR": tmpdir or str(tmp), "PATH": f"{wrapper_dir}:{real_dir}:/usr/bin:/bin",
            "CMUX_SURFACE_ID": "6E8B3C64-1C8D-4F5A-9B0E-2D7C5A1F3E90", "CMUX_SOCKET_PATH": app_path,
            "FAKE_REAL_ARGS_LOG": str(self.real_log), "FAKE_C11_LOG": str(self.c11_log),
            "FAKE_NO_LEADER": "1" if no_leader_support else "0",
            "FAKE_SPAWN_LEADER": "1" if spawn_leader else "0",
        })
        env.update(env_extra or {})
        terminal = pty.openpty() if interactive else None
        try:
            proc = subprocess.Popen(["grok", *argv], cwd=tmp, env=env,
                                    stdin=terminal[1] if terminal else subprocess.DEVNULL,
                                    stdout=terminal[1] if terminal else subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            self.pid = proc.pid
            self.code = proc.wait(timeout=15)
        finally:
            if terminal:
                for descriptor in terminal:
                    os.close(descriptor)

    def leader_socket(self) -> str:
        return f"{self.tmp}/c11-grok-leader-{self.pid}.sock"

    @property
    def argv(self) -> list[str]:
        return self.real_log.read_text(encoding="utf-8").splitlines() if self.real_log.exists() else []

    def c11_calls(self) -> list[str]:
        return self.c11_log.read_text(encoding="utf-8").splitlines() if self.c11_log.exists() else []

    def sidecar_calls(self, wait: float = 0.0) -> list[str]:
        if wait:
            wait_for(lambda: any(" grok-mailbox " in c for c in self.c11_calls()), wait)
        return [c for c in self.c11_calls() if " grok-mailbox " in c]

    def native_states(self, wait: float = 3.0) -> list[str]:
        def states() -> list[str]:
            return [c.split("--value ", 1)[1].split(" ", 1)[0] for c in self.c11_calls()
                    if "--key mailbox.native_state" in c]
        wait_for(lambda: bool(states()), wait)
        return states()

    def close(self) -> None:
        self.app_socket.close()
        # The wrapper's disowned background jobs can still be appending to
        # logs here, and removing the tree under them fails with "Directory
        # not empty"; retry until they have finished.
        deadline = time.time() + 10
        while True:
            try:
                self.td.cleanup()
                return
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_interactive_launch_adds_private_leader_and_sidecar() -> None:
    run = Run([])
    try:
        sock = run.leader_socket()
        argv = run.argv
        expect(argv[:3] == ["--leader", "--leader-socket", sock], f"leader args first: {argv}")
        expect(argv[3] == "--session-id" and len(argv[4]) == 36, f"injected session id: {argv}")
        calls = run.sidecar_calls(wait=3)
        expect(len(calls) == 1, f"one sidecar: {run.c11_calls()}")
        expect(f"--leader-socket {sock} --session-id {argv[4]}" in calls[0], calls[0])
        expect(f"--registry {run.tmp}/home/.grok/active_sessions.json" in calls[0], calls[0])
        expect(run.native_states() == ["grok_leader"], str(run.c11_calls()))
    finally:
        run.close()


def test_resume_binds_the_resumed_session() -> None:
    session = "909f490f-cdde-47ed-b8e6-2ec3274979e0"
    run = Run(["--resume", session])
    try:
        expect(run.argv[:2] == ["--leader", "--leader-socket"] and run.argv[3:] == ["--resume", session], str(run.argv))
        expect(f"--session-id {session}" in run.sidecar_calls(wait=3)[0], str(run.c11_calls()))
    finally:
        run.close()


def test_operator_choices_and_opt_out_skip_leader_mode() -> None:
    cases = [
        (["--leader"], {}, "off:operator_leader"), (["--no-leader"], {}, "off:operator_leader"),
        (["--leader-socket", "/tmp/x.sock"], {}, "off:operator_leader"),
        (["--leader-socket=/tmp/x.sock"], {}, "off:operator_leader"),
        (["--sandbox", "workspace"], {}, "off:sandbox"), (["--sandbox=workspace"], {}, "off:sandbox"),
        ([], {"GROK_SANDBOX": "workspace"}, "off:sandbox"), ([], {"C11_GROK_NATIVE_MAIL_DISABLED": "1"}, "off:opt_out"),
        (["--continue"], {}, "off:no_session"),
    ]
    for argv, extra, state in cases:
        run = Run(argv, env_extra=extra)
        try:
            got = run.argv
            expect(got[len(got) - len(argv):] == argv, f"operator args kept: {argv} {extra}: {got}")
            expect(got.count("--leader") == argv.count("--leader"), f"{argv} {extra}: {got}")
            expect(not any("c11-grok-leader-" in a for a in got), f"{argv} {extra}: {got}")
            expect(run.sidecar_calls(wait=0.5) == [], f"{argv} {extra}: {run.c11_calls()}")
            expect(run.native_states() == [state], f"{argv} {extra}: {run.c11_calls()}")
        finally:
            run.close()


def test_grok_without_leader_flag_launches_typed_only() -> None:
    run = Run([], no_leader_support=True)
    try:
        expect(run.argv[0] == "--session-id" and "--leader" not in run.argv, str(run.argv))
        expect(run.sidecar_calls(wait=0.5) == [], str(run.c11_calls()))
        expect(run.native_states() == ["off:no_leader_flag"], str(run.c11_calls()))
    finally:
        run.close()


def test_non_interactive_launch_is_untouched() -> None:
    run = Run([], interactive=False)
    try:
        expect("--leader" not in run.argv, str(run.argv))
        expect(run.sidecar_calls(wait=0.5) == [], str(run.c11_calls()))
        expect(run.native_states() == ["off:non_interactive"], str(run.c11_calls()))
    finally:
        run.close()


def test_long_tmpdir_falls_back_to_tmp_for_the_socket() -> None:
    with tempfile.TemporaryDirectory(prefix="c11-grok-long-", dir="/tmp") as td:
        long_dir = Path(td) / ("d" * 70)
        long_dir.mkdir()
        run = Run([], tmpdir=str(long_dir))
        try:
            expect(run.argv[2] == f"/tmp/c11-grok-leader-{run.pid}.sock", str(run.argv))
        finally:
            run.close()


def test_sidecar_failures_are_recorded_by_reason() -> None:
    for code, state in (("4", "off:client_failed"), ("5", "off:subscribe_refused")):
        run = Run([], env_extra={"FAKE_SIDECAR_EXIT": code})
        try:
            wait_for(lambda: len(run.native_states(0)) >= 2, 4)
            expect(run.native_states() == ["grok_leader", state], f"{code}: {run.c11_calls()}")
        finally:
            run.close()


def test_leader_that_never_comes_up_is_recorded() -> None:
    run = Run([], env_extra={"FAKE_SIDECAR_EXIT": "3"})
    try:
        wait_for(lambda: len(run.native_states(0)) >= 2, 4)
        expect(run.native_states() == ["grok_leader", "off:no_socket"], str(run.c11_calls()))
    finally:
        run.close()


def test_own_leader_is_reaped_when_grok_exits() -> None:
    run = Run([], spawn_leader=True)
    try:
        sock = run.leader_socket()
        leader = int(run.leader_pid_file.read_text().strip())
        expect(wait_for(lambda: not alive(leader), 6), "leader still running after Grok exited")
        expect(not Path(sock).exists() and not Path(sock[:-5] + ".lock").exists(), "socket or lock left behind")
    finally:
        run.close()


def test_stale_leader_of_a_dead_grok_is_reaped_and_live_one_kept() -> None:
    with tempfile.TemporaryDirectory(prefix="c11-grok-stale-", dir="/tmp") as td:
        tmp = Path(td)
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        stale_sock = f"{td}/c11-grok-leader-{dead.pid}.sock"
        live_owner = subprocess.Popen(["/bin/sleep", "30"])
        live_sock = f"{td}/c11-grok-leader-{live_owner.pid}.sock"
        stale_leader = start_fake_leader(tmp, stale_sock)
        live_leader = start_fake_leader(tmp, live_sock)
        try:
            run = Run([], tmpdir=td)
            try:
                expect(wait_for(lambda: not alive(stale_leader), 6), "stale leader not reaped")
                expect(wait_for(lambda: not Path(stale_sock).exists(), 6), "stale socket left behind")
                expect(alive(live_leader) and Path(live_sock).exists(), "live Grok's leader was touched")
            finally:
                run.close()
        finally:
            for pid in (stale_leader, live_leader):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            live_owner.kill()
            live_owner.wait()
            for path in (stale_sock, live_sock, stale_sock[:-5] + ".lock", live_sock[:-5] + ".lock"):
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass


def test_unverified_lock_pid_is_never_signalled() -> None:
    # A lock naming a process that does not hold the socket must not be killed.
    with tempfile.TemporaryDirectory(prefix="c11-grok-lock-", dir="/tmp") as td:
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        sock = f"{td}/c11-grok-leader-{dead.pid}.sock"
        bystander = subprocess.Popen(["/bin/sleep", "30"])
        Path(sock).write_text("")
        Path(sock[:-5] + ".lock").write_text(str(bystander.pid))
        try:
            run = Run([], tmpdir=td)
            try:
                expect(wait_for(lambda: not Path(sock).exists(), 6), "stale files not removed")
                expect(bystander.poll() is None, "unrelated process was signalled")
            finally:
                run.close()
        finally:
            bystander.kill()
            bystander.wait()
            for path in (sock, sock[:-5] + ".lock"):
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_") and callable(value)]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {test.__name__}: {error}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
