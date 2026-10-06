#!/usr/bin/env python3
"""Regression: explicit `rename-panel` CLI command parity with panel.action rename."""

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run_cli(cli: str, args: List[str], env: Optional[Dict[str, str]] = None) -> str:
    merged_env = dict(os.environ)
    merged_env.pop("CMUX_WORKSPACE_ID", None)
    merged_env.pop("C11_PANEL_ID", None)
    merged_env.pop("C11_TAB_ID", None)
    merged_env.pop("C11_SURFACE_ID", None)
    merged_env.pop("CMUX_PANEL_ID", None)
    merged_env.pop("CMUX_TAB_ID", None)
    merged_env.pop("CMUX_SURFACE_ID", None)
    if env:
        merged_env.update(env)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=merged_env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must("panel.action" in methods, f"Missing panel.action in capabilities: {sorted(methods)[:40]}")

        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")

        c._call("workspace.select", {"workspace_id": ws_id})
        current = c._call("panel.current", {"workspace_id": ws_id}) or {}
        surface_id = str(current.get("panel_id") or "")
        _must(bool(surface_id), f"panel.current returned no panel_id: {current}")

        socket_title = f"socket rename {stamp}"
        socket_payload = c._call(
            "panel.action",
            {
                "workspace_id": ws_id,
                "panel_id": surface_id,
                "action": "rename",
                "title": socket_title,
            },
        )
        _must(
            str((socket_payload or {}).get("title") or "") == socket_title,
            f"panel.action rename response missing requested title: {socket_payload}",
        )

        cli_title = f"cli rename {stamp}"
        cli_out = _run_cli(cli, ["rename-panel", "--workspace", ws_id, "--panel", surface_id, cli_title])
        _must(
            "action=rename" in cli_out.lower() and "panel=" in cli_out.lower(),
            f"rename-panel --panel should route to panel.action rename summary, got: {cli_out!r}",
        )

        env_title = f"env rename {stamp}"
        env_out = _run_cli(
            cli,
            ["rename-panel", env_title],
            env={
                "CMUX_WORKSPACE_ID": ws_id,
                "C11_PANEL_ID": surface_id,
            },
        )
        _must(
            "action=rename" in env_out.lower() and "panel=" in env_out.lower(),
            f"rename-panel via C11_PANEL_ID should route to panel.action rename summary, got: {env_out!r}",
        )

        # M7: legacy rename-panel must land in the M2 metadata blob with source=explicit.
        titlebar_state = c._call(
            "panel.get_titlebar_state",
            {"panel_id": surface_id},
        ) or {}
        _must(
            titlebar_state.get("title") == env_title,
            f"rename-panel should write title canonical key, got: {titlebar_state}",
        )
        _must(
            titlebar_state.get("title_source") == "explicit",
            f"rename-panel should set title_source=explicit, got: {titlebar_state}",
        )

        invalid = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "rename-panel", "--workspace", ws_id],
            capture_output=True,
            text=True,
            check=False,
            env={k: v for k, v in os.environ.items() if k not in {"CMUX_WORKSPACE_ID", "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"}},
        )
        invalid_output = f"{invalid.stdout}\n{invalid.stderr}"
        _must(invalid.returncode != 0, "Expected rename-panel without title to fail")
        _must("rename-panel requires a title" in invalid_output, f"Unexpected rename-panel error: {invalid_output!r}")

        c.close_workspace(ws_id)

    print("PASS: rename-panel CLI parity works with explicit and env-derived targets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
