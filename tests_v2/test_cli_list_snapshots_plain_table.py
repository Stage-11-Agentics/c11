#!/usr/bin/env python3
"""CLI regression: `c11 list-snapshots` (plain table) formats a real row.

Trident I5's earlier fix replaced a broken `%s` printf with `String.padding`
but did not add a subprocess test because the c11Tests unit target can't
easily exercise the CLI binary. This test drives the live socket + CLI
end-to-end: create a snapshot via the CLI, list it in both plain-table
and JSON forms, and assert the columns line up (id, surface count as an
int, source=current).
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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
    return proc.stdout


def _extract_snapshot_id(ok_line: str) -> str:
    # The `c11 snapshot` plain output starts with a line like:
    #   OK snapshot=01KQ0... surfaces=N path=/abs/...
    for token in ok_line.split():
        if token.startswith("snapshot="):
            return token.split("=", 1)[1]
    raise cmuxError(f"could not find snapshot= token in: {ok_line!r}")


def main() -> int:
    cli = _find_cli_binary()
    snapshots_dir = os.path.expanduser("~/.c11-snapshots")
    # Skip rather than error when the snapshot directory is not writable or
    # when no live c11 instance is reachable. CI owns the positive path.
    if not os.path.isdir(snapshots_dir):
        try:
            os.makedirs(snapshots_dir, exist_ok=True)
        except OSError as e:
            print(f"SKIP: {snapshots_dir} not writable: {e}")
            return 0

    workspace_id = ""
    snapshot_id = ""
    snapshot_path = ""
    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()

            # 1. Create a real snapshot via the CLI (plain-table output).
            snapshot_out = _run_cli(cli, ["snapshot", "--workspace", workspace_id]).strip()
            first_line = snapshot_out.splitlines()[0] if snapshot_out else ""
            _must(first_line.startswith("OK "), f"snapshot should print OK, got {snapshot_out!r}")
            snapshot_id = _extract_snapshot_id(first_line)
            snapshot_path = os.path.join(snapshots_dir, f"{snapshot_id}.json")
            _must(os.path.isfile(snapshot_path), f"snapshot file not written at {snapshot_path}")

            # 2. Plain-table list-snapshots.
            table_out = _run_cli(cli, ["list-snapshots"])
            table_lines = [line for line in table_out.splitlines() if line.strip()]
            _must(bool(table_lines), f"list-snapshots produced no output: {table_out!r}")
            header = table_lines[0]
            for col in ("SNAPSHOT_ID", "CREATED_AT", "WORKSPACE_TITLE", "SURFACES", "ORIGIN", "SOURCE"):
                _must(col in header, f"list-snapshots header missing '{col}': {header!r}")
            row = next((line for line in table_lines if line.startswith(snapshot_id)), None)
            _must(row is not None, f"list-snapshots missing row for {snapshot_id}: {table_out!r}")
            # The plain-table row is fixed-width padded. Splitting on
            # whitespace and picking by index is brittle with spaces in
            # titles; verify the surface-count column by JSON comparison
            # below. Here we only assert the id and source tokens appear.
            _must(snapshot_id in row, f"row does not contain id: {row!r}")
            _must("current" in row, f"row source column is not 'current': {row!r}")

            # 3. JSON form, compare against the plain table.
            json_out = _run_cli(cli, ["list-snapshots", "--json"])
            payload = json.loads(json_out)
            snapshots = payload.get("snapshots") or []
            match = next((e for e in snapshots if e.get("snapshot_id") == snapshot_id), None)
            _must(match is not None, f"list-snapshots --json missing row for {snapshot_id}")
            surface_count = match.get("surface_count")
            _must(
                isinstance(surface_count, int) and surface_count >= 0,
                f"surface_count is not a non-negative int: {surface_count!r}",
            )
            _must(match.get("source") == "current", f"source not 'current': {match.get('source')!r}")
            # The row's surface count must match what the plain table
            # reports (as an integer in the 4th column). Splitting header
            # offsets is brittle, but the numeric token near the
            # id->source span is stable; confirm at least one integer
            # token matches surface_count.
            row_ints = [int(tok) for tok in row.split() if tok.isdigit()]
            _must(
                surface_count in row_ints,
                f"plain-table row surface count tokens {row_ints} do not contain JSON surface_count {surface_count}: {row!r}",
            )
    finally:
        if snapshot_path and os.path.isfile(snapshot_path):
            try:
                os.remove(snapshot_path)
            except OSError:
                pass
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: c11 list-snapshots plain-table formats and round-trips through JSON")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
