#!/usr/bin/env python3
"""Shared helpers for c11mux Module 1 (TUI auto-detection) tests_v2 suite.

The heuristic inspects each surface's TTY via `ps -t <ttys>` and classifies the
foreground process by its `comm` field. Since we can't rely on a test box having
claude/codex/kimi/opencode installed, tests copy `/bin/sleep` to a temp path
with the desired name and exec it inside the surface; `comm` on Darwin is the
exec'd file's basename, which satisfies the heuristic's binary-match table.

The helpers also wrap surface.set_metadata / surface.get_metadata /
surface.clear_metadata so the individual test files stay compact.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Mock-binary preparation
# ---------------------------------------------------------------------------

def prepare_mock_bin(name: str, *, scratch_dir: Optional[Path] = None) -> Path:
    """Return a path to a `sleep`-equivalent binary named `name`.

    Copies /bin/sleep into a scratch directory so `ps -o comm=` reports
    `name`. `name` must be a canonical TUI name (claude, codex, kimi,
    opencode) or an arbitrary kebab-case string for the unknown-fallback
    test.
    """
    scratch = scratch_dir or Path(tempfile.mkdtemp(prefix=f"cmux-m1-mock-{name}-"))
    scratch.mkdir(parents=True, exist_ok=True)
    dst = scratch / name
    shutil.copy("/bin/sleep", dst)
    os.chmod(dst, 0o755)
    return dst


def cleanup_mock_dir(path: Path) -> None:
    try:
        shutil.rmtree(path.parent, ignore_errors=True)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Surface input — spawn / kill mock processes
# ---------------------------------------------------------------------------

def spawn_mock_in_surface(client, surface_id: str, mock_bin: Path, duration_seconds: int = 600) -> None:
    """Send `<mock_bin> <duration> &` then wait briefly so the heuristic can run."""
    # Foreground the mock so `pid == tpgid`. Use exec so the shell becomes the mock
    # process and the process-tree heuristic picks it up as the foreground.
    line = f"exec {mock_bin} {duration_seconds}\n"
    client._call("surface.send_text", {"surface_id": surface_id, "text": line})


def send_ctrl_c_to_surface(client, surface_id: str) -> None:
    client._call("surface.send_key", {"surface_id": surface_id, "key": "ctrl-c"})


# ---------------------------------------------------------------------------
# Metadata wrappers
# ---------------------------------------------------------------------------

def set_metadata(
    client,
    *,
    workspace_id: Optional[str] = None,
    surface_id: Optional[str] = None,
    partial: Dict[str, Any],
    source: str = "explicit",
    mode: str = "merge",
) -> Dict[str, Any]:
    params: Dict[str, Any] = {"metadata": partial, "mode": mode, "source": source}
    if workspace_id is not None:
        params["workspace_id"] = workspace_id
    if surface_id is not None:
        params["surface_id"] = surface_id
    return client._call("surface.set_metadata", params) or {}


def get_metadata(
    client,
    *,
    workspace_id: Optional[str] = None,
    surface_id: Optional[str] = None,
    keys: Optional[List[str]] = None,
    include_sources: bool = False,
) -> Dict[str, Any]:
    params: Dict[str, Any] = {}
    if workspace_id is not None:
        params["workspace_id"] = workspace_id
    if surface_id is not None:
        params["surface_id"] = surface_id
    if keys is not None:
        params["keys"] = keys
    if include_sources:
        params["include_sources"] = True
    return client._call("surface.get_metadata", params) or {}


def clear_metadata(
    client,
    *,
    workspace_id: Optional[str] = None,
    surface_id: Optional[str] = None,
    keys: Optional[List[str]] = None,
    source: str = "explicit",
) -> Dict[str, Any]:
    params: Dict[str, Any] = {"source": source}
    if workspace_id is not None:
        params["workspace_id"] = workspace_id
    if surface_id is not None:
        params["surface_id"] = surface_id
    if keys is not None:
        params["keys"] = keys
    return client._call("surface.clear_metadata", params) or {}


def set_agent(
    client,
    *,
    workspace_id: Optional[str] = None,
    surface_id: Optional[str] = None,
    agent_type: str,
    model: Optional[str] = None,
    task: Optional[str] = None,
    role: Optional[str] = None,
) -> Dict[str, Any]:
    partial: Dict[str, Any] = {"terminal_type": agent_type}
    if model is not None:
        partial["model"] = model
    if task is not None:
        partial["task"] = task
    if role is not None:
        partial["role"] = role
    return set_metadata(
        client,
        workspace_id=workspace_id,
        surface_id=surface_id,
        partial=partial,
        source="declare",
        mode="merge",
    )


# ---------------------------------------------------------------------------
# Polling / waits
# ---------------------------------------------------------------------------

def wait_for_terminal_type(
    client,
    *,
    workspace_id: str,
    surface_id: str,
    expected: str,
    expected_source: Optional[str] = None,
    timeout: float = 15.0,
    poll: float = 0.25,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """Poll until metadata[terminal_type] == expected (and optionally source matches).

    Returns (metadata, metadata_sources) at the moment the assertion holds. Raises
    AssertionError on timeout.
    """
    deadline = time.time() + timeout
    last_meta: Dict[str, Any] = {}
    last_sources: Dict[str, Any] = {}
    while time.time() < deadline:
        payload = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            include_sources=True,
        )
        last_meta = payload.get("metadata") or {}
        last_sources = payload.get("metadata_sources") or {}
        current = last_meta.get("terminal_type")
        current_source = (last_sources.get("terminal_type") or {}).get("source")
        if current == expected and (expected_source is None or current_source == expected_source):
            return last_meta, last_sources
        time.sleep(poll)
    raise AssertionError(
        f"timed out waiting for terminal_type={expected!r}"
        f"{f' source={expected_source!r}' if expected_source else ''};"
        f" last metadata={last_meta!r} sources={last_sources!r}"
    )


def wait_for_terminal_type_source(
    client,
    *,
    workspace_id: str,
    surface_id: str,
    expected_source: str,
    timeout: float = 15.0,
    poll: float = 0.25,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    deadline = time.time() + timeout
    last_meta: Dict[str, Any] = {}
    last_sources: Dict[str, Any] = {}
    while time.time() < deadline:
        payload = get_metadata(
            client,
            workspace_id=workspace_id,
            surface_id=surface_id,
            include_sources=True,
        )
        last_meta = payload.get("metadata") or {}
        last_sources = payload.get("metadata_sources") or {}
        if (last_sources.get("terminal_type") or {}).get("source") == expected_source:
            return last_meta, last_sources
        time.sleep(poll)
    raise AssertionError(
        f"timed out waiting for terminal_type source={expected_source!r};"
        f" last metadata={last_meta!r} sources={last_sources!r}"
    )
