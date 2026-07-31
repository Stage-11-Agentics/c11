#!/usr/bin/env python3
"""Regression tests for the c11-scoped Codex completion bridge."""

from __future__ import annotations

import base64
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def wait_for_line(path: Path, needle: str) -> list[str]:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        lines = read_lines(path)
        if any(needle in line for line in lines):
            return lines
        time.sleep(0.02)
    return read_lines(path)


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    callback: bool = False,
) -> tuple[int, list[str], list[str], str, str]:
    with tempfile.TemporaryDirectory(prefix="c11-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir()
        real_dir.mkdir()

        wrapper = wrapper_dir / "codex"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        c11_log = tmp / "c11.log"
        socket_path = str(tmp / "c11.sock")

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
""",
        )
        make_executable(
            wrapper_dir / "c11",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s timeout=%s payload=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" "${C11_CODEX_NOTIFY_PAYLOAD_B64-__UNSET__}" >> "$FAKE_C11_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" && "${FAKE_C11_PING_OK:-0}" != "1" ]]; then
  exit 1
fi
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        env["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_C11_LOG"] = str(c11_log)
        env["FAKE_C11_PING_OK"] = "1" if socket_state == "live" else "0"

        command = [str(wrapper)]
        if callback:
            command.append("__c11-notify")
            command.append('{"type":"agent-turn-complete"}')
        else:
            command.extend(argv)

        try:
            proc = subprocess.run(
                command,
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            c11_lines = wait_for_line(
                c11_log,
                " notify " if callback else " agent-hook idle",
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        return (
            proc.returncode,
            read_lines(real_args_log),
            c11_lines,
            proc.stdout.strip(),
            proc.stderr.strip(),
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_completion_callback(failures: list[str]) -> None:
    code, real_argv, c11_log, _, stderr = run_wrapper(
        socket_state="live",
        argv=["hello"],
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[:1] == ["-c"], f"live socket: missing config prefix: {real_argv}", failures)
    expect(
        len(real_argv) >= 3
        and real_argv[1].startswith('notify=["')
        and real_argv[1].endswith('","__c11-notify"]'),
        f"live socket: malformed completion notify config: {real_argv}",
        failures,
    )
    expect(real_argv[-1] == "hello", f"live socket: original argv was not preserved: {real_argv}", failures)
    expect(any(" agent-hook idle" in line for line in c11_log), f"missing initial idle seed: {c11_log}", failures)


def test_completion_callback_creates_surface_notification(failures: list[str]) -> None:
    code, real_argv, c11_log, _, stderr = run_wrapper(
        socket_state="live",
        argv=[],
        callback=True,
    )
    expect(code == 0, f"callback: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == [], f"callback: real Codex must not launch: {real_argv}", failures)
    notify_lines = [line for line in c11_log if " notify " in line]
    expect(len(notify_lines) == 1, f"callback: expected one c11 notification: {c11_log}", failures)
    if notify_lines:
        line = notify_lines[0]
        expect("--title Codex" in line, f"callback: missing Codex title: {line}", failures)
        expect(
            "--workspace 11111111-1111-1111-1111-111111111111" in line,
            f"callback: missing workspace scope: {line}",
            failures,
        )
        expect(
            "--surface 22222222-2222-2222-2222-222222222222" in line,
            f"callback: missing surface scope: {line}",
            failures,
        )
        encoded_payload = line.split("payload=", 1)[1].split()[0]
        expect(encoded_payload != "__UNSET__", f"callback: missing forwarded payload: {line}", failures)
        if encoded_payload != "__UNSET__":
            decoded_payload = base64.b64decode(encoded_payload).decode("utf-8")
            expect(
                decoded_payload == '{"type":"agent-turn-complete"}',
                f"callback: wrong forwarded payload: {decoded_payload}",
                failures,
            )
        expect("timeout=0.75" in line, f"callback: notification call is not bounded: {line}", failures)


def test_missing_socket_is_unchanged_passthrough(failures: list[str]) -> None:
    code, real_argv, c11_log, _, stderr = run_wrapper(
        socket_state="missing",
        argv=["hello"],
    )
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"missing socket: expected passthrough argv: {real_argv}", failures)
    expect(c11_log == [], f"missing socket: c11 should not be called: {c11_log}", failures)


def test_explicit_notify_override_remains_later_in_argv(failures: list[str]) -> None:
    custom = 'notify=["/custom/notifier"]'
    code, real_argv, _, _, stderr = run_wrapper(
        socket_state="live",
        argv=["-c", custom],
    )
    expect(code == 0, f"explicit override: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[-2:] == ["-c", custom], f"explicit override lost precedence: {real_argv}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_completion_callback(failures)
    test_completion_callback_creates_surface_notification(failures)
    test_missing_socket_is_unchanged_passthrough(failures)
    test_explicit_notify_override_remains_later_in_argv(failures)

    if failures:
        print("FAIL: Codex wrapper completion checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: Codex wrapper reports focus-independent turn completion to c11")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
