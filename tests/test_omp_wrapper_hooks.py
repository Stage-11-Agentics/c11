#!/usr/bin/env python3
"""Runtime contract checks for the c11-scoped omp wrapper's extension rail."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "omp"
SOURCE_EXTENSION = ROOT / "Resources" / "bin" / "omp-prompt-cache.ts"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def run_wrapper(socket_live: bool, argv: list[str]) -> tuple[int, list[str], list[str], list[str], str, list[str]]:
    with tempfile.TemporaryDirectory(prefix="c11-omp-wrapper-test-") as td:
        tmp = Path(td)
        home = tmp / "home"
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        home.mkdir()
        wrapper_dir.mkdir()
        real_dir.mkdir()
        shutil.copy2(SOURCE_WRAPPER, wrapper_dir / "omp")
        shutil.copy2(SOURCE_EXTENSION, wrapper_dir / "omp-prompt-cache.ts")
        (wrapper_dir / "omp").chmod(0o755)

        real_args = tmp / "real-args.log"
        real_env = tmp / "real-env.log"
        c11_log = tmp / "c11.log"
        socket_path = str(tmp / "c11.sock")

        make_executable(
            real_dir / "omp",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_REAL_ARGS_LOG"
printf '%s\\n' "${C11_AGENT_HOOK_CLI-}" > "$FAKE_REAL_ENV_LOG"
""",
        )
        make_executable(
            wrapper_dir / "c11",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_C11_LOG"
""",
        )

        test_socket: socket.socket | None = None
        if socket_live:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "PATH": f"{wrapper_dir}:{real_dir}:/usr/bin:/bin",
                "CMUX_SOCKET_PATH": socket_path,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "FAKE_REAL_ARGS_LOG": str(real_args),
                "FAKE_REAL_ENV_LOG": str(real_env),
                "FAKE_C11_LOG": str(c11_log),
            }
        )
        env.pop("CMUX_OMP_HOOKS_DISABLED", None)
        env.pop("C11_AGENT_HOOK_CLI", None)
        try:
            proc = subprocess.run(
                [str(wrapper_dir / "omp"), *argv],
                cwd=tmp,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
            )
            deadline = time.monotonic() + 2
            while socket_live and time.monotonic() < deadline:
                if any("conversation claim --kind omp" in line for line in lines(c11_log)):
                    break
                time.sleep(0.02)
        finally:
            if test_socket is not None:
                test_socket.close()

        home_files = sorted(str(path.relative_to(home)) for path in home.rglob("*"))
        return proc.returncode, lines(real_args), lines(real_env), lines(c11_log), proc.stderr.strip(), home_files


def test_interactive_live_surface_loads_the_prompt_cache_extension() -> None:
    code, argv, env_log, c11_log, stderr, home_files = run_wrapper(True, ["--model", "test"])
    assert code == 0, stderr
    assert home_files == [], f"the wrapper must not write tenant config: {home_files}"
    assert argv[0] == "--extension", argv
    assert argv[1].endswith("/omp-prompt-cache.ts"), argv
    assert argv[2:] == ["--model", "test"], argv
    assert env_log and env_log[0].endswith("/c11"), env_log
    assert any("set-agent --type omp" in line for line in c11_log), c11_log
    assert any("conversation claim --kind omp" in line for line in c11_log), c11_log


def test_missing_socket_passes_through() -> None:
    code, argv, env_log, c11_log, stderr, _ = run_wrapper(False, ["--model", "test"])
    assert code == 0, stderr
    assert argv == ["--model", "test"], argv
    assert env_log == [""], env_log
    assert c11_log == [], c11_log


def test_noninteractive_command_passes_through() -> None:
    code, argv, _, c11_log, stderr, _ = run_wrapper(True, ["--version"])
    assert code == 0, stderr
    assert argv == ["--version"], argv
    assert not any("set-agent" in line or "conversation" in line for line in c11_log), c11_log


if __name__ == "__main__":
    test_interactive_live_surface_loads_the_prompt_cache_extension()
    test_missing_socket_passes_through()
    test_noninteractive_command_passes_through()
    print("PASS: omp wrapper loads the prompt cache extension by flag, without persistent config")
