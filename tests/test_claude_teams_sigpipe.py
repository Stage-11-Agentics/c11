#!/usr/bin/env python3
"""Executable SIGPIPE inheritance regression for `c11 claude-teams`.

Run on Atlas with C11_CLI pointing at the exact built CLI. A tiny native
sigaction observer is compiled by cc: Python itself resets SIGPIPE at startup
and would hide the inherited disposition. All CLI state and paths are temporary;
no production socket is contacted. This is a standalone script, not pytest.
"""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile


OBSERVER_SOURCE = r"""
#include <signal.h>
#include <stdio.h>

int main(void) {
    struct sigaction disposition;
    if (sigaction(SIGPIPE, NULL, &disposition) != 0) {
        perror("sigaction");
        return 2;
    }
    if (disposition.sa_handler == SIG_DFL) {
        puts("DFL");
    } else if (disposition.sa_handler == SIG_IGN) {
        puts("IGN");
    } else {
        puts("OTHER");
    }
    return 0;
}
"""


def isolated_environment(root: Path, path: Path) -> dict[str, str]:
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("C11_", "CMUX_", "CLAUDE_", "DYLD_"))
        and key not in ("TMUX", "TMUX_PANE", "CLAUDECODE")
    }
    env.update({
        "HOME": str(root / "home"),
        "XDG_CONFIG_HOME": str(root / "home" / ".config"),
        "XDG_CACHE_HOME": str(root / "home" / ".cache"),
        "PATH": str(path),
    })
    return env


def capture(args: list[str], env: dict[str, str], *, restore_signals: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=5, check=False, restore_signals=restore_signals)


def expect_disposition(args: list[str], env: dict[str, str], expected: str,
                       *, restore_signals: bool = True) -> None:
    result = capture(args, env, restore_signals=restore_signals)
    assert result.returncode == 0, f"observer exited {result.returncode}: {result.stderr!r}"
    assert result.stdout.strip() == expected, (
        f"expected native SIGPIPE={expected}, got {result.stdout.strip()!r}; stderr={result.stderr!r}"
    )


def readers_closed(args: list[str], env: dict[str, str]) -> int:
    read_out, write_out = os.pipe()
    read_err, write_err = os.pipe()
    os.close(read_out)
    os.close(read_err)
    try:
        process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                                   stdout=write_out, stderr=write_err, close_fds=True)
    finally:
        os.close(write_out)
        os.close(write_err)
    try:
        return process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise


def compile_observer(root: Path) -> Path:
    source = root / "sigpipe_observer.c"
    observer = root / "sigpipe_observer"
    source.write_text(OBSERVER_SOURCE, encoding="utf-8")
    compiler = shlex.split(os.environ.get("CC", "/usr/bin/cc"))
    assert compiler, "CC must name a compiler"
    build = subprocess.run([*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            str(source), "-o", str(observer)],
                           capture_output=True, text=True, timeout=30, check=False)
    assert build.returncode == 0, f"native observer compilation failed: {build.stderr}"
    return observer


def main() -> int:
    try:
        configured_cli = os.environ.get("C11_CLI")
        assert configured_cli, "Set C11_CLI to the exact built native CLI"
        actual_cli = Path(configured_cli).expanduser().resolve(strict=True)
        assert os.access(actual_cli, os.X_OK), "C11_CLI is not executable"
        with tempfile.TemporaryDirectory(prefix="c11-269-sigpipe-") as directory:
            root = Path(directory)
            (root / "home" / ".config").mkdir(parents=True)
            # Prevent the bundle's sibling claude wrapper from supplying a
            # fallback: each route must depend solely on this fixture's PATH.
            cli_dir = root / "isolated-cli"
            cli_dir.mkdir()
            cli = cli_dir / "c11"
            shutil.copy2(actual_cli, cli)
            observer = compile_observer(root)
            resolved_bin = root / "resolved-bin"
            wrapper_bin = root / "wrapper-bin"
            missing_bin = root / "missing-bin"
            bad_bin = root / "bad-interpreter-bin"
            for directory_path in (resolved_bin, wrapper_bin, missing_bin, bad_bin):
                directory_path.mkdir()
            shutil.copy2(observer, resolved_bin / "claude")
            wrapper = wrapper_bin / "claude"
            wrapper.write_text(
                "#!/bin/sh\n"
                "# cmux claude wrapper - injects hooks and session tracking\n"
                f"exec {shlex.quote(str(observer))} \"$@\"\n", encoding="utf-8"
            )
            wrapper.chmod(0o755)
            bad_claude = bad_bin / "claude"
            bad_claude.write_text(f"#!{root / 'nonexistent-interpreter'}\n", encoding="utf-8")
            bad_claude.chmod(0o755)
            resolved_env = isolated_environment(root, resolved_bin)
            wrapper_env = isolated_environment(root, wrapper_bin)
            # Calibrate both the native observer and wrapper before relying on
            # them. Shells can change dispositions; this wrapper must preserve
            # both the ignored and default states, so it cannot hide the bug.
            previous = signal.signal(signal.SIGPIPE, signal.SIG_IGN)
            try:
                for executable, env in ((observer, resolved_env), (wrapper, wrapper_env)):
                    expect_disposition([str(executable)], env, "IGN", restore_signals=False)
                    expect_disposition([str(executable)], env, "DFL", restore_signals=True)
            finally:
                signal.signal(signal.SIGPIPE, previous)
            print("PASS: native observer and wrapper preserve both signal dispositions")

            launch = [str(cli), "--socket", str(root / "absent.sock"), "claude-teams", "--version"]
            expect_disposition(launch, resolved_env, "DFL")
            print("PASS: resolved-path execv child inherits SIG_DFL")
            expect_disposition(launch, wrapper_env, "DFL")
            print("PASS: wrapper-skipped PATH execvp child inherits SIG_DFL")

            for label, directory_path in (("execv", bad_bin), ("execvp", missing_bin)):
                env = isolated_environment(root, directory_path)
                failure = capture(launch, env)
                assert failure.returncode == 1, f"{label} failure exited {failure.returncode}"
                assert "Failed to launch claude:" in failure.stderr, failure.stderr
                assert not failure.stdout.strip(), failure.stdout
                status = readers_closed(launch, env)
                assert status == 1, (
                    f"{label} failure with readers closed exited {status}; "
                    "the CLI must restore ignored SIGPIPE before writing its error"
                )
                print(f"PASS: {label} failure reports CLI error and survives closed error pipe")

            # --help returns before socket connection; bare `help` requires a
            # live socket and would fail on absent.sock even with open pipes.
            for command in ("--help", "--version"):
                args = [str(cli), "--socket", str(root / "absent.sock"), command]
                ordinary = capture(args, resolved_env)
                assert ordinary.returncode == 0 and ordinary.stdout, ordinary.stderr
                status = readers_closed(args, resolved_env)
                assert status == 0, f"c11 {command} with readers closed exited {status}"
            print("PASS: help/version keep safe broken-pipe output behavior")
        return 0
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
