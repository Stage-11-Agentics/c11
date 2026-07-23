#!/usr/bin/env python3
"""Executable lifecycle checks for the PATH-scoped Codex wrapper."""

from __future__ import annotations

import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"


def executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class Fixture:
    def __init__(self, tmp: Path, live_socket: bool = True) -> None:
        self.tmp = tmp
        self.wrapper_bin = tmp / "wrapper-bin"
        self.real_bin = tmp / "real-bin"
        self.wrapper_bin.mkdir(parents=True)
        self.real_bin.mkdir(parents=True)
        self.events = tmp / "events.log"
        self.argv = tmp / "argv.log"
        self.socket_path = tmp / "c11.sock"
        self.socket: socket.socket | None = None
        shutil.copy2(SOURCE_WRAPPER, self.wrapper_bin / "codex")
        (self.wrapper_bin / "codex").chmod(0o755)
        executable(
            self.real_bin / "codex",
            """#!/usr/bin/env bash
set -uo pipefail
printf 'real-start\n' >> "$FAKE_EVENTS"
: > "$FAKE_ARGV"
printf '%s\n' "$@" >> "$FAKE_ARGV"
case "${FAKE_REAL_MODE:-ok}" in
  exit42) exit 42 ;;
  wait) exec sleep 30 ;;
esac
exit 0
""",
        )
        executable(
            self.wrapper_bin / "c11",
            """#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "--socket" ]]; then shift 2; fi
if [[ "${1:-}" == "ping" ]]; then exit "${FAKE_PING_STATUS:-0}"; fi
if [[ "${1:-}" == "conversation" && "${2:-}" == "claim" ]]; then
  printf 'claim-start %s timeout=%s\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC:-}" >> "$FAKE_EVENTS"
  case "${FAKE_CLAIM_MODE:-ok}" in
    delay) sleep 0.2 ;;
    timeout) sleep 0.8; printf 'claim-expired-no-mutation\n' >> "$FAKE_EVENTS"; exit 1 ;;
    fail) exit 1 ;;
  esac
  printf 'claim-committed\n' >> "$FAKE_EVENTS"
  exit 0
fi
exit 0
""",
        )
        if live_socket:
            self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.socket.bind(str(self.socket_path))

    def close(self) -> None:
        if self.socket is not None:
            self.socket.close()

    def env(self, **updates: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.wrapper_bin}:{self.real_bin}:{env.get('PATH', '/usr/bin:/bin')}",
            "C11_SURFACE_ID": "c040ef8d-58a5-4c29-bebd-29f3d44ed203",
            "CMUX_SURFACE_ID": "c040ef8d-58a5-4c29-bebd-29f3d44ed203",
            "CMUX_SOCKET_PATH": str(self.socket_path),
            "FAKE_EVENTS": str(self.events),
            "FAKE_ARGV": str(self.argv),
        })
        env.update(updates)
        return env

    def run(self, argv: list[str], **updates: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.wrapper_bin / "codex"), *argv],
            cwd=self.tmp,
            env=self.env(**updates),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def event_lines(self) -> list[str]:
        return self.events.read_text().splitlines() if self.events.exists() else []

    def argv_lines(self) -> list[str]:
        return self.argv.read_text().splitlines() if self.argv.exists() else []

    def boundary_file(self) -> Path:
        return Path(
            str(self.socket_path)
            + ".codex-launch-boundaries/"
            + self.env()["CMUX_SURFACE_ID"]
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="c11-codex-wrapper-") as raw_tmp:
        tmp = Path(raw_tmp)

        fixture = Fixture(tmp / "ordered")
        try:
            argv = ["resume", "54b30d2f-2371-4dc0-9294-35dc75e55de3", "--search"]
            proc = fixture.run(argv, FAKE_CLAIM_MODE="delay")
            lines = fixture.event_lines()
            expect(proc.returncode == 0, f"ordered launch failed: {proc.stderr}", failures)
            expect(fixture.argv_lines() == argv, f"argv changed: {fixture.argv_lines()}", failures)
            expect("claim-committed" in lines and "real-start" in lines and lines.index("claim-committed") < lines.index("real-start"), f"claim was not committed before exec: {lines}", failures)
            claim_line = next((line for line in lines if line.startswith("claim-start")), "")
            expect("--ttl-ms 700" in claim_line and "timeout=0.75" in claim_line, f"claim was not expiry-bounded: {claim_line}", failures)
            expect(f"--expected-resume-id {argv[1]}" in claim_line, f"exact resume intent was not forwarded: {claim_line}", failures)
            expect(not fixture.boundary_file().exists(), "acknowledged claim left a stale launch-boundary marker", failures)
        finally:
            fixture.close()

        fixture = Fixture(tmp / "failure")
        try:
            proc = fixture.run(["--search", "prompt"], FAKE_CLAIM_MODE="fail")
            expect(proc.returncode == 0 and fixture.argv_lines() == ["--search", "prompt"], f"claim failure blocked or changed Codex: {proc.stderr}", failures)
            plain_claim = next((line for line in fixture.event_lines() if line.startswith("claim-start")), "")
            expect("--expected-resume-id" not in plain_claim, f"plain launch forged resume intent: {plain_claim}", failures)
            marker = fixture.boundary_file()
            expect(marker.exists(), "failed claim did not leave a fail-closed launch-boundary marker", failures)
            if marker.exists():
                marker_lines = marker.read_text().splitlines()
                expect(
                    len(marker_lines) >= 3
                    and marker_lines[0].isdigit()
                    and marker_lines[1] == ""
                    and marker_lines[2].startswith(
                        fixture.env()["CMUX_SURFACE_ID"] + ":"
                    ),
                    f"invalid boundary marker: {marker_lines}",
                    failures,
                )
            proc = fixture.run([], FAKE_REAL_MODE="exit42")
            expect(proc.returncode == 42, f"real Codex exit status was not preserved: {proc.returncode}", failures)
        finally:
            fixture.close()

        fixture = Fixture(tmp / "timeout")
        try:
            start = time.monotonic()
            proc = fixture.run([], FAKE_CLAIM_MODE="timeout")
            elapsed = time.monotonic() - start
            lines = fixture.event_lines()
            expect(proc.returncode == 0 and elapsed < 2.0, f"expired claim blocked launch for {elapsed:.2f}s", failures)
            expect("claim-expired-no-mutation" in lines and "claim-committed" not in lines, f"expired claim mutated: {lines}", failures)
            expect(lines.index("claim-expired-no-mutation") < lines.index("real-start"), f"Codex exec raced expiry acknowledgement: {lines}", failures)
            expect(fixture.boundary_file().exists(), "expired claim did not leave a fail-closed launch-boundary marker", failures)
        finally:
            fixture.close()

        fixture = Fixture(tmp / "signal")
        try:
            proc = subprocess.Popen(
                [str(fixture.wrapper_bin / "codex")],
                cwd=fixture.tmp,
                env=fixture.env(FAKE_REAL_MODE="wait"),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.time() + 2
            while time.time() < deadline and "real-start" not in fixture.event_lines():
                time.sleep(0.02)
            proc.send_signal(signal.SIGTERM)
            returncode = proc.wait(timeout=2)
            expect(returncode == -signal.SIGTERM, f"signal semantics changed: {returncode}", failures)
        finally:
            fixture.close()

        fixture = Fixture(tmp / "passthrough", live_socket=False)
        try:
            argv = ["resume", "thread-id"]
            proc = fixture.run(argv)
            expect(proc.returncode == 0 and fixture.argv_lines() == argv, f"missing-socket passthrough failed: {proc.stderr}", failures)
            expect(not any(line.startswith("claim-start") for line in fixture.event_lines()), f"missing socket attempted claim: {fixture.event_lines()}", failures)
            expect(not fixture.boundary_file().exists(), "unavailable-socket passthrough wrote a marker outside the live-socket gate", failures)
        finally:
            fixture.close()

    if failures:
        print("FAIL: Codex wrapper resume lifecycle")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: Codex wrapper claims before exec and preserves passthrough/argv/exit/signal behavior")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
