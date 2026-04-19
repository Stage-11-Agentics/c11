#!/usr/bin/env python3
"""Tier 1 Phase 3: statusEntries persistence round-trip via the CLI.

Flow:
  1. Set a status on a fresh workspace using the public `cmux` CLI
     (which wraps the v1 `set_status` socket command), including the
     optional fidelity fields (`url`, `priority`, `format`).
  2. Force save-to-disk + reload-from-disk via the DEBUG-only
     `debug.session.save_and_load` socket command.
  3. Re-read via `list-status` and assert every field round-trips.
  4. Re-announce the same status. Assert the call succeeds (the
     stale-clearing path exercises the Phase 3 override of
     `shouldReplaceStatusEntry`).

Two variants, selected by `CMUX_DISABLE_STATUS_ENTRY_PERSIST` in the
running app (not the test process):

- Main variant (env var unset in app): all fields round-trip.
- Rollback variant (env var `=1` in app launch env): statusEntries
  are discarded on restore per pre-Phase-3 behavior.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
TEST_EXPECTS_ROLLBACK = os.environ.get("CMUX_DISABLE_STATUS_ENTRY_PERSIST") == "1"

STATUS_KEY = "phase3.smoke"
STATUS_VALUE = "Running"
STATUS_ICON = "sf:sparkles"
STATUS_COLOR = "#FF8800"
STATUS_URL = "https://example.com/session/1"
STATUS_PRIORITY = "7"
STATUS_FORMAT = "markdown"


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


def _run_cli(cli: str, args: list[str]) -> str:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def _set_status(cli: str, workspace_id: str) -> None:
    resp = _run_cli(
        cli,
        [
            "set-status",
            STATUS_KEY,
            STATUS_VALUE,
            "--workspace",
            workspace_id,
            "--icon",
            STATUS_ICON,
            "--color",
            STATUS_COLOR,
            "--url",
            STATUS_URL,
            "--priority",
            STATUS_PRIORITY,
            "--format",
            STATUS_FORMAT,
        ],
    )
    _must(resp.startswith("OK"), f"set-status failed: {resp!r}")


def _list_status(cli: str, workspace_id: str) -> str:
    return _run_cli(cli, ["list-status", "--workspace", workspace_id])


def _parse_status_line(line: str) -> dict[str, str]:
    # Format: "<key>=<value> icon=... color=... url=... priority=N format=..."
    out: dict[str, str] = {}
    head, _, rest = line.partition(" ")
    k, _, v = head.partition("=")
    out["key"] = k
    out["value"] = v
    for token in rest.split():
        k, _, v = token.partition("=")
        if k:
            out[k] = v
    return out


def _run_main_variant(client, cli: str) -> None:
    workspace_id = client.new_workspace()
    try:
        _set_status(cli, workspace_id)

        rt = client._call("debug.session.save_and_load", {})
        _must(rt is not None, "debug.session.save_and_load returned no result")

        after = _list_status(cli, workspace_id)
        _must(after, f"Expected restored status, got empty: {after!r}")
        parsed = _parse_status_line(after)
        _must(parsed.get("key") == STATUS_KEY, f"Key: {parsed}")
        _must(parsed.get("value") == STATUS_VALUE, f"Value: {parsed}")
        _must(parsed.get("icon") == STATUS_ICON, f"Icon: {parsed}")
        _must(parsed.get("color") == STATUS_COLOR, f"Color: {parsed}")
        _must(parsed.get("url") == STATUS_URL, f"URL: {parsed}")
        _must(parsed.get("priority") == STATUS_PRIORITY, f"Priority: {parsed}")
        _must(parsed.get("format") == STATUS_FORMAT, f"Format: {parsed}")

        # Re-announce identical status. The stale→live override path runs
        # inside shouldReplaceStatusEntry; we can exercise the surface
        # behavior by confirming the second write succeeds and the entry
        # is still listable (i.e. not accidentally dropped by the override).
        _set_status(cli, workspace_id)
        still_there = _list_status(cli, workspace_id)
        parsed_after = _parse_status_line(still_there)
        _must(
            parsed_after.get("key") == STATUS_KEY,
            f"Entry missing after re-announce: {still_there!r}",
        )

        print("PASS: Tier 1 Phase 3 statusEntries persistence (main variant)")
    finally:
        try:
            client.close_workspace(workspace_id)
        except Exception:
            pass


def _run_rollback_variant(client, cli: str) -> None:
    workspace_id = client.new_workspace()
    try:
        _set_status(cli, workspace_id)

        rt = client._call("debug.session.save_and_load", {})
        _must(rt is not None, "debug.session.save_and_load returned no result")

        after = _list_status(cli, workspace_id)
        _must(
            "No status" in after or after == "",
            f"Rollback: expected empty statusEntries after restore, got {after!r}",
        )
        print("PASS: Tier 1 Phase 3 statusEntries persistence (rollback variant)")
    finally:
        try:
            client.close_workspace(workspace_id)
        except Exception:
            pass


def main() -> int:
    cli = _find_cli_binary()
    with cmux(SOCKET_PATH) as client:
        if TEST_EXPECTS_ROLLBACK:
            _run_rollback_variant(client, cli)
        else:
            _run_main_variant(client, cli)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
