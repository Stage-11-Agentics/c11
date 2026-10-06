#!/usr/bin/env python3
"""Regression: panel/workspace action naming is consistent in CLI + socket v2."""

import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run_cli(cli: str, args: List[str], json_output: bool) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    for name in ("C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"):
        env.pop(name, None)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: List[str]) -> Dict:
    output = _run_cli(cli, args, json_output=True)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _focused_surface_ref(c: cmux, workspace_id: str) -> str:
    current = c._call("panel.current", {"workspace_id": workspace_id}) or {}
    surface_ref = str(current.get("panel_ref") or "")
    if surface_ref.startswith("panel:"):
        return surface_ref

    listed = c._call("panel.list", {"workspace_id": workspace_id}) or {}
    rows = listed.get("panels") or []
    for row in rows:
        if bool(row.get("focused")):
            ref = str(row.get("ref") or "")
            if ref.startswith("panel:"):
                return ref
    for row in rows:
        ref = str(row.get("ref") or "")
        if ref.startswith("panel:"):
            return ref

    raise cmuxError(f"Unable to resolve focused surface ref in workspace {workspace_id}: {listed}")


def main() -> int:
    cli = _find_cli_binary()

    help_text = _run_cli(cli, ["panel-action", "--help"], json_output=False)
    _must("Target panel" in help_text, "panel-action --help should describe panel target naming")
    _must("--panel <id|ref|index>" in help_text, "panel-action --help should document --panel")
    _must("surface" not in help_text.lower() and not re.search(r"\btabs?\b", help_text.lower()),
          "panel-action --help should not use the old tab or surface words")
    _must("--panel panel:" in help_text, "panel-action examples should use panel: refs")

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        for method in ["workspace.action", "panel.action"]:
            _must(method in methods, f"Missing method in capabilities: {method}")

        created = c._call("workspace.create", {}) or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        ws_other = ""
        try:
            # Agents cannot select workspaces; every call below targets ws_id explicitly.
            surface_ref = _focused_surface_ref(c, ws_id)
            panel_ref = "panel:" + surface_ref.split(":", 1)[1]

            pin = _run_cli_json(cli, ["panel-action", "--workspace", ws_id, "--panel", panel_ref, "--action", "pin"])
            _must(str(pin.get("panel_ref") or "").startswith("panel:"), f"Expected panel_ref in panel-action payload: {pin}")
            _must(bool(pin.get("pinned")) is True, f"panel-action pin should report pinned=true: {pin}")

            unpin = _run_cli_json(cli, ["panel-action", "--workspace", ws_id, "--panel", panel_ref, "--action", "unpin"])
            _must(bool(unpin.get("pinned")) is False, f"panel-action unpin should report pinned=false: {unpin}")

            socket_panel = c._call("panel.action", {"workspace_id": ws_id, "panel_id": panel_ref, "action": "clear_name"}) or {}
            _must(str(socket_panel.get("panel_ref") or "").startswith("panel:"), f"Expected panel_ref in panel.action result: {socket_panel}")
            _must(str(socket_panel.get("workspace_id") or "") == ws_id, f"panel.action should target requested workspace: {socket_panel}")

            other_created = c._call("workspace.create", {}) or {}
            ws_other = str(other_created.get("workspace_id") or "")
            _must(bool(ws_other), f"workspace.create (second) returned no workspace_id: {other_created}")
            # ws_other stays in the background; the globally focused panel lives in the
            # guest's selected workspace, which is still "another workspace" for this check.
            ws_target_ref = ""
            ws_list = c._call("workspace.list", {}) or {}
            for row in ws_list.get("workspaces") or []:
                if str(row.get("id") or "") == ws_id:
                    ws_target_ref = str(row.get("ref") or "")
                    break

            # Regression: workspace-scoped panel-action without --panel should target that workspace,
            # not whichever panel is globally focused in another workspace.
            cli_scoped = _run_cli_json(cli, ["panel-action", "--workspace", ws_id, "--action", "mark-unread"])
            _must(str(cli_scoped.get("panel_ref") or "").startswith("panel:"), f"Expected panel_ref in scoped panel-action result: {cli_scoped}")
            got_scoped_workspace = str(cli_scoped.get("workspace_id") or cli_scoped.get("workspace_ref") or "")
            _must(
                got_scoped_workspace in {x for x in [ws_id, ws_target_ref] if x},
                f"workspace-scoped panel-action should resolve target workspace: {cli_scoped}",
            )

            # Regression: panel_id alone should resolve both tab manager + workspace, even when another workspace is selected.
            by_panel_only = c._call("panel.action", {"panel_id": panel_ref, "action": "mark_unread"}) or {}
            _must(str(by_panel_only.get("panel_ref") or "").startswith("panel:"), f"Expected panel_ref in panel_id-only result: {by_panel_only}")
            _must(str(by_panel_only.get("workspace_id") or "") == ws_id, f"panel_id-only action should resolve target workspace: {by_panel_only}")

            mark_read = c._call("panel.action", {"panel_id": panel_ref, "action": "mark_read"}) or {}
            _must(str(mark_read.get("panel_ref") or "").startswith("panel:"), f"Expected panel_ref in mark_read result: {mark_read}")
            _must(str(mark_read.get("workspace_id") or "") == ws_id, f"mark_read should resolve target workspace: {mark_read}")
        finally:
            if ws_other:
                try:
                    c.close_workspace(ws_other)
                except Exception:
                    pass
            try:
                c.close_workspace(ws_id)
            except Exception:
                pass

    print("PASS: tab/workspace naming stays consistent across panel-action CLI and socket APIs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
