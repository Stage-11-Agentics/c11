"""Shared helpers for `cmux tree` (M8) test files.

Centralizes:
  - Locating the cmux CLI binary across DerivedData paths.
  - Invoking the CLI with --json or text output, optionally with --canvas-cols.
  - Common assertions about the new tree shape (layout/content_area, badges).

Tests live alongside this module under tests_v2/ and are exercised on the VM
(e.g. via `gh workflow run test-e2e.yml`); they expect a running cmux instance
on the configured CMUX_SOCKET.
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
from typing import Any, Dict, List, Optional, Tuple


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def find_cli_binary() -> str:
    """Return the path to a cmux CLI binary, preferring a fresh M8 build."""
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    candidates: List[str] = []
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates += glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
    ), recursive=True)
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise RuntimeError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def run_cli(
    cli: str,
    args: List[str],
    *,
    json_mode: bool = False,
    canvas_cols: Optional[int] = None,
    expect_failure: bool = False,
) -> Tuple[int, str, str]:
    """Run the cmux CLI and return (rc, stdout, stderr).

    Always passes --socket so tests don't depend on the env discovery path.
    `--json` is added as a global flag (BEFORE the subcommand) when requested.
    `--canvas-cols` is added AFTER the subcommand because it's tree-specific.
    """
    cmd = [cli, "--socket", SOCKET_PATH]
    if json_mode:
        cmd.append("--json")
    cmd += args
    if canvas_cols is not None:
        cmd += ["--canvas-cols", str(canvas_cols)]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if not expect_failure and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise RuntimeError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.returncode, proc.stdout, proc.stderr


def run_tree_json(
    cli: str,
    extra_args: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """Run `cmux --json tree [extra_args]` and parse JSON output."""
    args = ["tree"] + (extra_args or [])
    _, stdout, _ = run_cli(cli, args, json_mode=True)
    try:
        return json.loads(stdout or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON from `cmux tree`: {stdout!r} ({exc})")


def run_tree_text(
    cli: str,
    extra_args: Optional[List[str]] = None,
    canvas_cols: Optional[int] = None,
) -> str:
    """Run `cmux tree [extra_args]` (text mode) and return stdout."""
    args = ["tree"] + (extra_args or [])
    _, stdout, _ = run_cli(cli, args, canvas_cols=canvas_cols)
    return stdout


def all_panes(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Flat list of every pane dict across all windows/workspaces."""
    out: List[Dict[str, Any]] = []
    for win in payload.get("windows", []):
        for ws in win.get("workspaces", []):
            out.extend(ws.get("panes", []))
    return out


def all_workspaces(payload: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Flat list of every workspace dict across all windows."""
    out: List[Dict[str, Any]] = []
    for win in payload.get("windows", []):
        out.extend(win.get("workspaces", []))
    return out


def assert_layout_well_formed(pane: Dict[str, Any]) -> None:
    """Raise if pane.layout is missing/malformed for a laid-out workspace."""
    layout = pane.get("layout")
    if not isinstance(layout, dict):
        raise AssertionError(f"pane.layout missing/not dict: {pane}")
    pct = layout.get("percent")
    if not isinstance(pct, dict):
        raise AssertionError(f"pane.layout.percent missing: {layout}")
    h = pct.get("H"); v = pct.get("V")
    if not (isinstance(h, list) and len(h) == 2):
        raise AssertionError(f"layout.percent.H must be [start,end]: {pct}")
    if not (isinstance(v, list) and len(v) == 2):
        raise AssertionError(f"layout.percent.V must be [start,end]: {pct}")
    for label, arr in (("H", h), ("V", v)):
        for i, val in enumerate(arr):
            if not isinstance(val, (int, float)):
                raise AssertionError(f"layout.percent.{label}[{i}] not numeric: {arr}")
            if val < -1e-9 or val > 1.0 + 1e-9:
                raise AssertionError(f"layout.percent.{label}[{i}]={val} out of [0,1]")
        if arr[1] <= arr[0]:
            raise AssertionError(f"layout.percent.{label} non-increasing: {arr}")


def percent_area(pane: Dict[str, Any]) -> float:
    """Return the normalized area covered by a pane (0..1)."""
    pct = pane["layout"]["percent"]
    h0, h1 = pct["H"]; v0, v1 = pct["V"]
    return max(0.0, h1 - h0) * max(0.0, v1 - v0)


# Pane line badge regex per spec:
#   pane <ref> size=W%×H% px=W×H split=<chain>
PANE_LINE_BADGES_RE = re.compile(
    r"pane\s+\S+\s+size=\d+%×\d+%\s+px=\d+×\d+\s+split=(?:none|(?:[HV]:(?:left|right|top|bottom))(?:,[HV]:(?:left|right|top|bottom))*)"
)


def pane_lines(text: str) -> List[str]:
    """Extract pane lines from the hierarchical tree section of `cmux tree`."""
    out: List[str] = []
    for line in text.splitlines():
        # Tree pane lines are prefixed with box-drawing branches like "├── pane ..."
        # and may sit under a workspace branch. Match by the literal " pane " token.
        if " pane " in line and re.search(r" pane\s+\S+", line):
            out.append(line)
    return out
