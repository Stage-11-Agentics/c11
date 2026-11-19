#!/usr/bin/env python3
"""Measure forks and execs per minute of the shell integration's idle watchers.

Starts disposable shells (never the operator's), each running one watcher the
way a panel does: the zsh git HEAD watch (a foreground command is running) and
the zsh and bash PR poll loops between probes (the shell sits at a prompt).
Forks are observed as kqueue NOTE_FORK notifications on the watcher process.
kqueue folds forks that land before a read into one notification, so the fork
column is a lower bound; zero notifications means no fork at all. Execs are
counted exactly by PATH shims for `sleep` and `ps`, the only external commands
a tick runs. Every process it starts is in its own session and is stopped by
that group.

    scripts/measure-shell-watch-forks.py [--root DIR] [--seconds N] [--bash PATH]

--root picks the integration directory (default Resources/shell-integration),
so an older copy (`git show <ref>:<path>`) can be measured the same way.
--bash picks the bash to run (default: bash on PATH), e.g. /bin/bash for 3.2.
"""
import argparse
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = (("zsh", "head"), ("zsh", "pr"), ("bash", "pr"))
SHIM = '#!/bin/sh\nprintf "%s\\n" "$0" >> "$C11_MEASURE_EXEC_LOG"\nexec {real} "$@"\n'

DRIVER = r'''
case_dir="$1"; integration="$2"; kind="$3"
export CMUX_SOCKET_PATH="$case_dir/listener.sock" CMUX_TAB_ID=measure-tab CMUX_PANEL_ID=measure-panel
unset CMUX_RESTORE_SCROLLBACK_FILE GHOSTTY_BIN_DIR
source "$integration"
if [[ -n "${ZSH_VERSION:-}" ]]; then
    preexec_functions=(); precmd_functions=(); zshexit_functions=()
    _cmux_stop_git_head_watch; _cmux_stop_pr_poll_loop
fi
_cmux_send() { :; }
_cmux_report_pr_for_path() { :; }
_CMUX_PR_POLL_INTERVAL=3600
mkdir -p "$case_dir/repo/.git"
printf 'ref: refs/heads/main\n' > "$case_dir/repo/.git/HEAD"
cd "$case_dir/repo" || exit 10
if [[ "$kind" == head ]]; then
    _cmux_start_git_head_watch
    printf '%s\n' "$_CMUX_GIT_HEAD_WATCH_PID" > "$case_dir/watch.tmp"
else
    _cmux_start_pr_poll_loop "$PWD" 1
    printf '%s\n' "$_CMUX_PR_POLL_PID" > "$case_dir/watch.tmp"
fi
mv "$case_dir/watch.tmp" "$case_dir/watch.pid"
read -r release_line < "$case_dir/release"
'''


def proc_events(pid, seconds):
    kq = select.kqueue()
    try:
        kq.control([select.kevent(
            pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            fflags=select.KQ_NOTE_FORK | select.KQ_NOTE_EXEC | select.KQ_NOTE_EXIT)], 0, 0)
        forks = 0
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            for event in kq.control(None, 16, remaining):
                forks += bool(event.fflags & select.KQ_NOTE_FORK)
                if event.fflags & select.KQ_NOTE_EXIT:
                    raise RuntimeError(f"watcher {pid} exited during the measurement")
        return forks
    finally:
        kq.close()


def measure(shell, kind, integration_root, seconds, results, bash):
    with tempfile.TemporaryDirectory(prefix="c11-watch-measure-") as temp:
        case = Path(temp)
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(case / "listener.sock"))
        listener.listen()
        shims = case / "shims"
        shims.mkdir()
        for name in ("sleep", "ps"):
            shim = shims / name
            shim.write_text(SHIM.format(real=shutil.which(name)))
            shim.chmod(0o755)
        log = case / "execs.log"
        log.touch()
        os.mkfifo(case / "release")
        (case / "driver.sh").write_text(DRIVER)
        integration = Path(integration_root) / (
            "cmux-zsh-integration.zsh" if shell == "zsh" else "cmux-bash-integration.bash")
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("C11_", "CMUX_", "GHOSTTY_")) and k != "BASH_ENV"}
        env.update(PATH=f"{shims}:{env.get('PATH', '/usr/bin:/bin')}", ZDOTDIR=str(case),
                   C11_MEASURE_EXEC_LOG=str(log))
        args = ([shutil.which("zsh"), "-f"] if shell == "zsh" else [bash, "--noprofile", "--norc"])
        driver = subprocess.Popen(args + [str(case / "driver.sh"), str(case), str(integration), kind],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, start_new_session=True, env=env)
        try:
            pid_file = case / "watch.pid"
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            watcher = int(pid_file.read_text())
            time.sleep(2.5)  # Past the start-up probe; measure steady ticking only.
            before = len(log.read_text().splitlines())
            forks = proc_events(watcher, seconds)
            execs = len(log.read_text().splitlines()) - before
            results[(shell, kind)] = (forks * 60 / seconds, execs * 60 / seconds)
        finally:
            with open(case / "release", "w") as release:
                release.write("go\n")
            try:
                driver.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(driver.pid, signal.SIGKILL)  # This run's own session only.
            except (ProcessLookupError, PermissionError):
                pass
            driver.wait()
            listener.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=str(ROOT / "Resources" / "shell-integration"))
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--bash", default=shutil.which("bash"))
    options = parser.parse_args()
    results = {}
    threads = [threading.Thread(target=measure, args=(shell, kind, options.root, options.seconds, results, options.bash))
               for shell, kind in CASES]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    labels = {("zsh", "head"): "zsh HEAD watch (foreground command)",
              ("zsh", "pr"): "zsh PR poll, between probes (prompt)",
              ("bash", "pr"): "bash PR poll, between probes (prompt)"}
    version = subprocess.run([options.bash, "--version"], capture_output=True, text=True).stdout.split("\n")[0]
    print(f"integration: {options.root}  window: {options.seconds:g} s  bash: {options.bash} ({version})")
    print("fork notes: kqueue NOTE_FORK notifications, a lower bound on forks (0 means none)")
    print(f"{'watcher':40} {'fork notes/min':>15} {'execs/min':>10}")
    for case in CASES:
        forks, execs = results.get(case, (float("nan"), float("nan")))
        print(f"{labels[case]:40} {forks:15.1f} {execs:10.1f}")


if __name__ == "__main__":
    main()
