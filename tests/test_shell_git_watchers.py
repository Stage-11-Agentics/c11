#!/usr/bin/env python3
"""Exercise the bundled shell integration in disposable shells and repositories."""
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_ROOT = Path(os.environ.get(
    "C11_SHELL_INTEGRATION_ROOT", str(ROOT / "Resources" / "shell-integration")))
SHELLS = ("bash", "zsh")


def alive(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                            capture_output=True, text=True, check=False)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def eventually(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


class ShellFixture:
    """Own every process started by a case, including disowned shell helpers."""
    def __init__(self, shell, body):
        self.temp = tempfile.TemporaryDirectory(prefix="c11-shell-watch-")
        self.path = Path(self.temp.name)
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(self.path / "listener.sock"))
        self.socket.listen()
        (self.path / "identity").write_text("  Thu Oct  1 22:00:00 2026  \n")
        (self.path / "branch").write_text("fixture-main\n")
        (self.path / "git.log").touch()
        (self.path / "send.log").touch()
        self.shell = shell
        integration = INTEGRATION_ROOT / (
            "cmux-zsh-integration.zsh" if shell == "zsh" else "cmux-bash-integration.bash")
        header = r'''
case_dir="$1"
integration="$2"
export CMUX_SOCKET_PATH="$case_dir/listener.sock" CMUX_TAB_ID=fixture-tab CMUX_PANEL_ID=fixture-panel
unset CMUX_RESTORE_SCROLLBACK_FILE GHOSTTY_BIN_DIR
if [[ -n "${ZSH_VERSION:-}" ]]; then zmodload zsh/datetime; fi
source "$integration"
if [[ -n "${ZSH_VERSION:-}" ]]; then
    # Invoke the production functions explicitly; script commands are not prompts.
    preexec_functions=()
    precmd_functions=()
    zshexit_functions=()
    _cmux_stop_git_head_watch
    _cmux_stop_pr_poll_loop
fi
ps() {
    if [[ "$1" == "-o" && "$2" == "lstart=" ]]; then
        cat "$case_dir/identity"
    else
        command ps "$@"
    fi
}
_cmux_send() { printf '%s\n' "$1" >> "$case_dir/send.log"; }
_cmux_report_tty_once() { :; }
_cmux_report_shell_activity_state() { :; }
_cmux_ports_kick() { :; }
_cmux_agent_kick() { :; }
prompt_report() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        _cmux_precmd
    else
        _cmux_prompt_command
    fi
}
wait_release() { while [[ ! -f "$case_dir/release" ]]; do sleep 0.05; done; }
wait_git_job() {
    local attempts=0
    while kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; do
        (( attempts += 1 ))
        (( attempts < 60 )) || return 1
        sleep 0.05
    done
    wait "$_CMUX_GIT_JOB_PID" 2>/dev/null || true
}
'''
        script = self.path / "driver.sh"
        script.write_text(header + body + "\n")
        args = [shutil.which(shell)] + (["-f"] if shell == "zsh" else ["--noprofile", "--norc"])
        args += [str(script), str(self.path), str(integration)]
        self.output = open(self.path / "output", "w+")
        env = os.environ.copy()
        for key in tuple(env):
            if key.startswith(("C11_", "CMUX_", "GHOSTTY_")) or key == "BASH_ENV":
                del env[key]
        # zsh -f still reads .zshenv. Keep the operator's integration hooks out.
        env["ZDOTDIR"] = str(self.path)
        self.driver = subprocess.Popen(args, stdout=self.output, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=env)

    def read(self, name):
        path = self.path / name
        return path.read_text() if path.exists() else ""

    def await_file(self, name, timeout=3):
        if not eventually(lambda: bool(self.read(name).strip()), timeout):
            raise AssertionError(f"{self.shell}: missing {name}; output: {self.read('output')}")
        return self.read(name)

    def wait_exit(self, timeout=3):
        self.driver.wait(timeout=timeout)
        if self.driver.returncode:
            raise AssertionError(f"{self.shell}: exit {self.driver.returncode}: {self.read('output')}")

    def finish(self):
        (self.path / "release").touch()
        self.wait_exit()

    def close(self):
        # Cleanup only the process group and recorded PIDs created by this fixture.
        try:
            try:
                os.killpg(self.driver.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                # macOS can report EPERM after the group leader was reaped.
                # The recorded helpers still need individual cleanup and proof.
                pass
            pids = [int(self.read(name).strip())
                    for name in ("watch.pid", "probe.pid", "leaf.pid", "reporter.pid")
                    if self.read(name).strip().isdigit()]
            for pid in pids:
                if alive(pid):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
            try:
                self.driver.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.driver.kill()
                self.driver.wait(timeout=3)
            if not eventually(lambda: not any(alive(pid) for pid in pids)):
                remaining = [pid for pid in pids if alive(pid)]
                raise AssertionError(f"{self.shell}: helpers survived fixture cleanup: {remaining}")
        finally:
            self.output.close()
            self.socket.close()
            self.temp.cleanup()


class ShellGitWatcherTests(unittest.TestCase):
    def fixture(self, shell, body):
        item = ShellFixture(shell, body)
        self.addCleanup(item.close)
        return item

    def test_fixture_cleanup_handles_reaped_group_and_stops_recorded_helper(self):
        for shell in SHELLS:
            for error in (ProcessLookupError, PermissionError):
                with self.subTest(shell=shell, error=error.__name__):
                    item = ShellFixture(shell, r'''
sleep 60 &
printf '%s\n' "$!" > "$case_dir/watch.pid"
wait_release
''')
                    helper = None
                    try:
                        helper = int(item.await_file("watch.pid"))
                        item.finish()  # Reap the group leader while its helper is live.
                        self.assertTrue(alive(helper))
                        with mock.patch.object(os, "killpg", side_effect=error):
                            item.close()
                        self.assertFalse(alive(helper))
                        self.assertIsNotNone(item.driver.poll())
                    finally:
                        if helper is not None and alive(helper):
                            os.kill(helper, signal.SIGKILL)
                        if not item.output.closed:
                            item.close()

    def test_fixture_cleanup_does_not_hide_a_surviving_helper(self):
        item = ShellFixture("bash", r'''
sleep 60 &
printf '%s\n' "$!" > "$case_dir/watch.pid"
wait_release
''')
        helper = None
        try:
            helper = int(item.await_file("watch.pid"))
            item.finish()
            self.assertTrue(alive(helper))
            with mock.patch.object(os, "killpg", side_effect=PermissionError), \
                    mock.patch.object(os, "kill", side_effect=PermissionError):
                with self.assertRaisesRegex(AssertionError, "helpers survived fixture cleanup"):
                    item.close()
            self.assertTrue(alive(helper))
            self.assertTrue(item.output.closed)
            self.assertEqual(item.socket.fileno(), -1)
        finally:
            if helper is not None and alive(helper):
                os.kill(helper, signal.SIGKILL)
            if not item.output.closed:
                item.close()

    def test_parent_identity_is_trimmed_and_rejects_death_reuse_and_empty_capture(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                item = self.fixture(shell, r'''
parent_start="$(_cmux_parent_shell_lstart "$$")"
[[ "$parent_start" == 'Thu Oct  1 22:00:00 2026' ]] || exit 10
_cmux_parent_shell_alive "$$" "$parent_start" || exit 11
printf 'different-start\n' > "$case_dir/identity"
if _cmux_parent_shell_alive "$$" "$parent_start"; then exit 12; fi
: > "$case_dir/identity"
if _cmux_parent_shell_alive "$$" "$parent_start"; then exit 13; fi
if _cmux_parent_shell_alive "$$" ''; then exit 14; fi
printf 'Thu Oct  1 22:00:00 2026\n' > "$case_dir/identity"
if _cmux_parent_shell_alive "$$" ''; then exit 15; fi
rm "$case_dir/identity"
if _cmux_parent_shell_alive "$$" "$parent_start"; then exit 16; fi
''')
                item.wait_exit()

    def test_prompt_branch_report_never_invokes_status_or_sends_dirty(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                item = self.fixture(shell, r'''
git() {
    printf '%s\n' "$*" >> "$case_dir/git.log"
    case " $* " in
        *' branch --show-current '*) cat "$case_dir/branch" ;;
        *' status '*) printf ' M fake\n' ;;
    esac
}
_cmux_start_pr_poll_loop() { :; }
prompt_report
wait_git_job || exit 10
: > "$case_dir/branch"
_CMUX_GIT_FORCE=1
_CMUX_GIT_LAST_RUN=0
_CMUX_GIT_JOB_PID=''
prompt_report
wait_git_job || exit 11
printf 'done\n' > "$case_dir/done"
''')
                item.await_file("done")
                item.wait_exit()
                argv = item.read("git.log").splitlines()
                self.assertTrue(argv, "prompt must actually invoke git")
                self.assertTrue(all("status" not in line.split() for line in argv), argv)
                reports = item.read("send.log").splitlines()
                self.assertTrue(any(line.startswith("report_git_branch fixture-main ") for line in reports), reports)
                self.assertTrue(any(line.startswith("clear_git_branch ") for line in reports), reports)
                self.assertTrue(all("--status" not in line for line in reports), reports)

    def test_empty_identity_does_not_start_forever_watchers(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                item = self.fixture(shell, r'''
mkdir -p "$case_dir/repo/.git"
printf 'ref: refs/heads/main\n' > "$case_dir/repo/.git/HEAD"
cd "$case_dir/repo" || exit 10
: > "$case_dir/identity"
_cmux_report_pr_for_path() { printf 'unexpected-probe\n' >> "$case_dir/probes"; }
_cmux_start_pr_poll_loop "$PWD" 1
[[ -z "$_CMUX_PR_POLL_PID" ]] || exit 11
if [[ -n "${ZSH_VERSION:-}" ]]; then
    _cmux_start_git_head_watch
    [[ -z "$_CMUX_GIT_HEAD_WATCH_PID" ]] || exit 12
fi
sleep 0.2
[[ ! -e "$case_dir/probes" ]] || exit 13
''')
                item.wait_exit()

    def test_idle_watchers_stop_on_dead_or_reused_parent_identity(self):
        for shell in SHELLS:
            kinds = ("pr", "head") if shell == "zsh" else ("pr",)
            for kind in kinds:
                for changed in ("", "replacement-start\n"):
                    with self.subTest(shell=shell, kind=kind, changed=changed):
                        body = r'''
mkdir -p "$case_dir/repo/.git"
printf 'ref: refs/heads/main\n' > "$case_dir/repo/.git/HEAD"
cd "$case_dir/repo" || exit 10
_CMUX_PR_POLL_INTERVAL=45
_cmux_report_pr_for_path() { printf 'probe\n' >> "$case_dir/probes"; }
'''
                        body += (r'''
_cmux_start_pr_poll_loop "$PWD" 1
printf '%s\n' "$_CMUX_PR_POLL_PID" > "$case_dir/watch.pid"
''' if kind == "pr" else r'''
_cmux_start_git_head_watch
printf '%s\n' "$_CMUX_GIT_HEAD_WATCH_PID" > "$case_dir/watch.pid"
''')
                        body += "wait_release\n"
                        item = self.fixture(shell, body)
                        pid = int(item.await_file("watch.pid"))
                        if kind == "pr":
                            item.await_file("probes")
                        time.sleep(1.1)
                        self.assertTrue(alive(pid), "same identity must keep watcher alive")
                        if kind == "pr":
                            self.assertEqual(item.read("probes").splitlines(), ["probe"], "45s probe cadence must stay intact")
                        (item.path / "identity").write_text(changed)
                        self.assertTrue(eventually(lambda: not alive(pid)), "idle watcher outlived identity change by >3s")
                        self.assertIsNone(item.driver.poll(), "watcher must not exit parent shell")
                        item.finish()

    def blocked_probe(self, ignore_term=False):
        # A real external probe with an attributable descendant, both held past 20s.
        body = r'''
_cmux_report_pr_for_path() {
    python3 - "$case_dir" <<'PYCODE'
import os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
child = subprocess.Popen(CHILD_COMMAND)
(root / "probe.pid").write_text(str(os.getpid()))
(root / "leaf.pid").write_text(str(child.pid))
time.sleep(60)
PYCODE
}
'''
        if ignore_term:
            child_code = ("import pathlib,signal,sys,time; "
                          "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                          "pathlib.Path(sys.argv[1], 'leaf.ready').write_text('ready'); time.sleep(60)")
            child_command = f"['python3', '-c', {child_code!r}, str(root)]"
        else:
            child_command = repr(["sleep", "60"])
        return body.replace("CHILD_COMMAND", child_command)

    def test_blocked_pr_watchers_cancel_attributable_children_on_parent_death_or_reuse(self):
        for shell in SHELLS:
            for timeout in (20, 0):
                for changed in ("", "replacement-start\n"):
                    with self.subTest(shell=shell, timeout=timeout, changed=changed):
                        item = self.fixture(shell, self.blocked_probe(ignore_term=True) + f"\n_CMUX_ASYNC_JOB_TIMEOUT={timeout}\n" + r'''
_cmux_start_pr_poll_loop "$PWD" 1
printf '%s\n' "$_CMUX_PR_POLL_PID" > "$case_dir/watch.pid"
wait_release
''')
                        watcher = int(item.await_file("watch.pid"))
                        probe = int(item.await_file("probe.pid"))
                        leaf = int(item.await_file("leaf.pid"))
                        item.await_file("leaf.ready")
                        self.assertTrue(alive(watcher) and alive(probe) and alive(leaf))
                        (item.path / "identity").write_text(changed)
                        self.assertTrue(eventually(lambda: not any(alive(pid) for pid in (watcher, probe, leaf))),
                                        "watcher/probe/descendant survived parent loss for >3s")
                        self.assertIsNone(item.driver.poll())
                        item.finish()

    def test_probe_returns_distinct_parent_gone_result_and_keeps_live_parent_timeout(self):
        for shell in SHELLS:
            for parent_gone in (True, False):
                with self.subTest(shell=shell, parent_gone=parent_gone):
                    item = self.fixture(shell, self.blocked_probe() + (r'''
_CMUX_ASYNC_JOB_TIMEOUT=20
''' if parent_gone else r'''
_CMUX_ASYNC_JOB_TIMEOUT=1
''') + r'''
parent_start="$(_cmux_parent_shell_lstart "$$")"
_cmux_run_pr_probe_with_timeout "$PWD" "$$" "$parent_start"
printf '%s\n' "$?" > "$case_dir/result"
''')
                    probe = int(item.await_file("probe.pid"))
                    leaf = int(item.await_file("leaf.pid"))
                    if parent_gone:
                        (item.path / "identity").write_text("")
                    self.assertEqual(int(item.await_file("result")), 2 if parent_gone else 1)
                    item.wait_exit()
                    self.assertFalse(alive(probe) or alive(leaf), "probe return must follow descendant cleanup")

    def test_quick_probe_success_with_live_parent_is_preserved(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                item = self.fixture(shell, r'''
_cmux_report_pr_for_path() {
    /bin/sh -c 'printf "%s\n" "$PPID"' > "$case_dir/probe.pid"
    printf 'successful-probe\n'
    return 0
}
parent_start="$(_cmux_parent_shell_lstart "$$")"
_cmux_run_pr_probe_with_timeout "$PWD" "$$" "$parent_start" || exit 10
''')
                item.wait_exit()
                self.assertIn("successful-probe", item.read("output"))
                probe = int(item.await_file("probe.pid"))
                self.assertFalse(alive(probe), "successful probe must be gone before fixture cleanup")

    def test_probe_exit_two_is_transient_and_watcher_recovers(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                item = self.fixture(shell, r'''
_CMUX_PR_POLL_INTERVAL=1
_cmux_report_pr_for_path() {
    if [[ ! -f "$case_dir/failed-probe" ]]; then
        printf 'transient-failure\n' > "$case_dir/failed-probe"
        return 2
    fi
    printf 'recovered\n' > "$case_dir/recovered"
}
_cmux_start_pr_poll_loop "$PWD" 1
printf '%s\n' "$_CMUX_PR_POLL_PID" > "$case_dir/watch.pid"
wait_release
_cmux_stop_pr_poll_loop
''')
                watcher = int(item.await_file("watch.pid"))
                item.await_file("failed-probe")
                item.await_file("recovered", timeout=4)
                self.assertTrue(alive(watcher), "probe's own exit2 must not signal parent loss")
                item.finish()

    def test_real_git_checkout_and_commit_succeed_while_reporting(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                # Driver waits for repository provisioning before sourcing/reporting.
                item = self.fixture(shell, r'''
while [[ ! -f "$case_dir/repo-ready" ]]; do sleep 0.05; done
cd "$case_dir/repo" || exit 10
git() { printf '%s\n' "$*" >> "$case_dir/git.log"; command git "$@"; }
_cmux_start_pr_poll_loop() { :; }
if [[ -n "${ZSH_VERSION:-}" ]]; then
    _cmux_start_git_head_watch
    printf '%s\n' "$_CMUX_GIT_HEAD_WATCH_PID" > "$case_dir/watch.pid"
fi
{
    while [[ ! -f "$case_dir/release" ]]; do
        prompt_report
        sleep 0.2
    done
} &
printf '%s\n' "$!" > "$case_dir/reporter.pid"
wait_release
if [[ -n "${ZSH_VERSION:-}" ]]; then _cmux_stop_git_head_watch; fi
wait 2>/dev/null || true
''')
                repo = item.path / "repo"
                repo.mkdir()
                def git(*args):
                    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True)
                git("init", "-q", "-b", "fixture-main")
                git("config", "user.name", "Synthetic Fixture")
                git("config", "user.email", "fixture@example.invalid")
                git("config", "commit.gpgsign", "false")
                (repo / "file").write_text("initial\n")
                git("add", "file")
                git("commit", "-qm", "Synthetic initial")
                (item.path / "repo-ready").touch()
                item.await_file("reporter.pid")
                self.assertTrue(eventually(lambda: "report_git_branch fixture-main " in item.read("send.log")))
                git("checkout", "-qb", "fixture-next")
                self.assertTrue(eventually(lambda: "report_git_branch fixture-next " in item.read("send.log")),
                                "checkout must cause an automatic branch report")
                (repo / "file").write_text("committed while reporter runs\n")
                git("add", "file")
                committed = git("commit", "-qm", "Synthetic concurrent report")
                self.assertNotIn("index.lock", committed.stderr)
                argv = item.read("git.log").splitlines()
                self.assertTrue(argv)
                self.assertTrue(all("status" not in line.split() for line in argv), argv)
                self.assertNotIn("--status", item.read("send.log"))
                item.finish()

    def test_zsh_head_signature_change_reports_new_branch_without_prompt(self):
        item = self.fixture("zsh", r'''
mkdir -p "$case_dir/repo/.git"
printf 'ref: refs/heads/fixture-main\n' > "$case_dir/repo/.git/HEAD"
cd "$case_dir/repo" || exit 10
git() { printf '%s\n' "$*" >> "$case_dir/git.log"; cat "$case_dir/branch"; }
_cmux_start_git_head_watch
printf '%s\n' "$_CMUX_GIT_HEAD_WATCH_PID" > "$case_dir/watch.pid"
wait_release
_cmux_stop_git_head_watch
''')
        item.await_file("watch.pid")
        (item.path / "branch").write_text("fixture-next\n")
        (item.path / "repo/.git/HEAD").write_text("ref: refs/heads/fixture-next\n")
        self.assertTrue(eventually(lambda: "report_git_branch fixture-next " in item.read("send.log")))
        self.assertTrue(all("status" not in line.split() for line in item.read("git.log").splitlines()))
        self.assertNotIn("--status", item.read("send.log"))
        item.finish()

    def test_real_parent_sigkill_stops_watchers_without_exit_hooks(self):
        for shell in SHELLS:
            kinds = ("pr", "head") if shell == "zsh" else ("pr",)
            for kind in kinds:
                with self.subTest(shell=shell, kind=kind):
                    body = r'''
unset -f ps
mkdir -p "$case_dir/repo/.git"
printf 'ref: refs/heads/main\n' > "$case_dir/repo/.git/HEAD"
cd "$case_dir/repo" || exit 10
'''
                    if kind == "pr":
                        body += self.blocked_probe(ignore_term=True) + r'''
_CMUX_ASYNC_JOB_TIMEOUT=0
_cmux_start_pr_poll_loop "$PWD" 1
printf '%s\n' "$_CMUX_PR_POLL_PID" > "$case_dir/watch.pid"
'''
                    else:
                        body += r'''
_cmux_start_git_head_watch
printf '%s\n' "$_CMUX_GIT_HEAD_WATCH_PID" > "$case_dir/watch.pid"
'''
                    item = self.fixture(shell, body + "wait_release\n")
                    targets = [int(item.await_file("watch.pid"))]
                    if kind == "pr":
                        targets += [int(item.await_file(name)) for name in ("probe.pid", "leaf.pid")]
                        item.await_file("leaf.ready")
                    self.assertTrue(all(alive(pid) for pid in targets))
                    item.driver.kill()  # Only the parent, never its process group.
                    item.driver.wait(timeout=3)
                    self.assertTrue(eventually(lambda: not any(alive(pid) for pid in targets)),
                                    "real parent death must stop watcher and probe tree within 3s")


if __name__ == "__main__":
    for shell in SHELLS:
        if not shutil.which(shell):
            raise SystemExit(f"Required fixture shell is unavailable: {shell}")
    unittest.main(verbosity=2)
