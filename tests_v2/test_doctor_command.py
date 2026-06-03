#!/usr/bin/env python3
"""`c11 doctor` reports CLI resolution state with a stable JSON shape.

Skips when CMUX_BUNDLED_CLI_PATH is unset (matches the existing tests_v2
pattern of skipping environmental probes that rely on the c11 terminal env).
The doctor output's job is exactly to surface that resolution state, so the
JSON contract is what we lock in here.
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux"
    )
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
        ),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def main() -> int:
    cli = _find_cli_binary()

    # The doctor command must not require the socket — verify by running with
    # an explicit, unreachable socket path so we don't accidentally connect to
    # whatever c11 instance happens to be running on this machine.
    base_env = dict(os.environ)
    base_env["C11_SOCKET"] = "/tmp/c11-doctor-test-no-socket.sock"
    base_env["C11_QUIET_DISCOVERY"] = "1"

    # Plain text invocation. Exit zero, prints the human table.
    plain = _run([cli, "doctor"], env=base_env)
    _must(plain.returncode == 0, f"`c11 doctor` should exit 0: rc={plain.returncode} {plain.stderr!r}")
    _must(
        "c11 doctor" in plain.stdout.lower() or "cli resolution" in plain.stdout.lower(),
        f"plain output should mention doctor / CLI resolution: {plain.stdout!r}",
    )
    _must(
        "status:" in plain.stdout,
        f"plain output should include a status line: {plain.stdout!r}",
    )

    # JSON invocation. Stable shape; subset of fields always present.
    js_proc = _run([cli, "doctor", "--json"], env=base_env)
    _must(
        js_proc.returncode == 0,
        f"`c11 doctor --json` should exit 0: rc={js_proc.returncode} {js_proc.stderr!r}",
    )
    try:
        payload = json.loads(js_proc.stdout)
    except json.JSONDecodeError as exc:
        raise cmuxError(f"`c11 doctor --json` produced invalid JSON: {exc} :: {js_proc.stdout!r}")

    _must(isinstance(payload, dict), f"json payload should be a dict, got {type(payload)}")
    for required in ("status", "path_fix_applied", "path", "notes"):
        _must(required in payload, f"json payload missing required key {required!r}: {payload}")

    valid_status = {"ok", "mismatch", "missing", "no_bundle"}
    _must(
        payload["status"] in valid_status,
        f"status must be one of {valid_status}, got {payload['status']!r}",
    )
    _must(isinstance(payload["path"], list), f"path must be a list, got {type(payload['path'])}")
    _must(isinstance(payload["notes"], list), f"notes must be a list, got {type(payload['notes'])}")
    _must(
        isinstance(payload["path_fix_applied"], bool),
        f"path_fix_applied must be a bool, got {type(payload['path_fix_applied'])}",
    )

    # When CMUX_BUNDLED_CLI_PATH is set, bundled_cli_path should agree.
    bundled_env = os.environ.get("CMUX_BUNDLED_CLI_PATH", "").strip()
    if bundled_env:
        _must(
            payload.get("bundled_cli_path") == bundled_env,
            f"bundled_cli_path should equal env CMUX_BUNDLED_CLI_PATH: "
            f"{payload.get('bundled_cli_path')!r} vs {bundled_env!r}",
        )

    # Reject unknown flags with a non-zero exit and a recognizable message.
    bad = _run([cli, "doctor", "--nonsense"], env=base_env)
    _must(bad.returncode != 0, f"unknown flag should fail: rc={bad.returncode} {bad.stdout!r}")
    combined = (bad.stdout + bad.stderr).lower()
    _must(
        "unknown flag" in combined or "--nonsense" in combined,
        f"unknown flag error should mention the flag: {combined!r}",
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
