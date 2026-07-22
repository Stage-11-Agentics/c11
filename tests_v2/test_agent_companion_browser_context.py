#!/usr/bin/env python3
"""Tagged-socket contract for agent-linked companion browser public APIs.

This file is authored in ACB-04 but intentionally executed only by ACB-07/11
against a tagged app launched with C11_AGENT_COMPANION_BROWSER_ENABLED=1.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError, find_cli_binary


SOCKET_PATH = (
    os.environ.get("C11_SOCKET")
    or os.environ.get("CMUX_SOCKET")
    or os.environ.get("CMUX_SOCKET_PATH")
    or "/tmp/c11-debug-agent-companion-api.sock"
)

CONTEXT_KEYS = {
    "kind",
    "browser_surface_id",
    "browser_surface_ref",
    "browser_name",
    "linked_agent_surface_id",
    "linked_agent_surface_ref",
    "linked_agent_name",
    "link_state",
    "presentation_state",
    "active_agent_surface_id",
    "active_agent_surface_ref",
    "active_agent_name",
}


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _expect_error(client: cmux, method: str, params: dict[str, Any], code: str) -> None:
    try:
        client._call(method, params)
    except cmuxError as error:
        _must(str(error).startswith(f"{code}:"), f"Expected {code}, got {error}")
        return
    raise cmuxError(f"Expected {method} to fail with {code}")


def _workspace_id(client: cmux) -> str:
    payload = client._call("workspace.current") or {}
    workspace_id = payload.get("workspace_id")
    _must(isinstance(workspace_id, str) and workspace_id, f"Missing workspace id: {payload}")
    return workspace_id


def _surface_rows(client: cmux, workspace_id: str) -> list[dict[str, Any]]:
    payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    rows = payload.get("surfaces") or []
    _must(isinstance(rows, list), f"surface.list returned invalid rows: {payload}")
    return rows


def _first_terminal(client: cmux, workspace_id: str) -> dict[str, Any]:
    terminal = next(
        (row for row in _surface_rows(client, workspace_id) if row.get("type") == "terminal"),
        None,
    )
    _must(isinstance(terminal, dict), "Tagged test workspace has no terminal caller")
    return terminal


def _context(payload: dict[str, Any]) -> dict[str, Any]:
    context = payload.get("context")
    _must(isinstance(context, dict), f"Missing companion context: {payload}")
    _must(set(context) == CONTEXT_KEYS, f"Context field set drifted: {sorted(context)}")
    _must(context.get("kind") == "agent_companion", f"Unexpected context kind: {context}")
    return context


def _find_surface_node(value: Any, surface_id: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if value.get("id") == surface_id and value.get("type") == "browser":
            return value
        for child in value.values():
            found = _find_surface_node(child, surface_id)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_surface_node(child, surface_id)
            if found is not None:
                return found
    return None


def _focus_fingerprint(client: cmux, workspace_id: str) -> str:
    identify = client._call("system.identify") or {}
    surface_list = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    pane_list = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    compact = {
        "focused": identify.get("focused"),
        "selected_workspace_id": identify.get("selected_workspace_id"),
        "surfaces": [
            {
                "id": row.get("id"),
                "focused": row.get("focused"),
                "selected_in_pane": row.get("selected_in_pane"),
            }
            for row in surface_list.get("surfaces") or []
        ],
        "panes": [
            {
                "id": row.get("id"),
                "focused": row.get("focused"),
                "selected_surface_id": row.get("selected_surface_id"),
            }
            for row in pane_list.get("panes") or []
        ],
    }
    return json.dumps(compact, sort_keys=True, separators=(",", ":"))


def _mark_as_agent(client: cmux, surface_id: str) -> None:
    client._call(
        "surface.set_metadata",
        {
            "surface_id": surface_id,
            "metadata": {"terminal_type": "codex", "title": "API Contract Agent"},
            "mode": "merge",
            "source": "explicit",
        },
    )


def _create_browser(
    client: cmux,
    workspace_id: str,
    **extra: Any,
) -> dict[str, Any]:
    params: dict[str, Any] = {"workspace_id": workspace_id, "url": "about:blank"}
    params.update(extra)
    payload = client._call("browser.open_split", params) or {}
    _must(isinstance(payload.get("surface_id"), str), f"Creation returned no browser: {payload}")
    return payload


def _assert_canonical_queries(
    client: cmux,
    workspace_id: str,
    browser_id: str,
    expected: dict[str, Any],
) -> None:
    surface_row = next(
        (row for row in _surface_rows(client, workspace_id) if row.get("id") == browser_id),
        None,
    )
    _must(isinstance(surface_row, dict), "Created browser missing from surface.list")
    _must(_context(surface_row) == expected, "surface.list context differs from surface.context.get")

    tree = client._call("system.tree", {"workspace_id": workspace_id}) or {}
    tree_row = _find_surface_node(tree, browser_id)
    _must(isinstance(tree_row, dict), "Created browser missing from system.tree")
    _must(_context(tree_row) == expected, "system.tree context differs from surface.context.get")

    tabs = client._call("browser.tab.list", {"workspace_id": workspace_id}) or {}
    tab_row = next((row for row in tabs.get("tabs") or [] if row.get("id") == browser_id), None)
    _must(isinstance(tab_row, dict), "Created browser missing from browser.tab.list")
    _must(_context(tab_row) == expected, "browser.tab.list context differs from surface.context.get")


def _run_cli_browser_open(
    socket_path: str,
    workspace_id: str,
    caller_surface_id: str,
    *arguments: str,
) -> dict[str, Any]:
    cli = find_cli_binary()
    environment = dict(os.environ)
    environment.update(
        {
            "C11_SOCKET": socket_path,
            "C11_WORKSPACE_ID": workspace_id,
            "C11_SURFACE_ID": caller_surface_id,
        }
    )
    environment.pop("CMUX_WORKSPACE_ID", None)
    environment.pop("CMUX_SURFACE_ID", None)
    process = subprocess.run(
        [
            cli,
            "--socket",
            socket_path,
            "--json",
            "browser",
            "open",
            *arguments,
            "about:blank?workspace-wide=1",
        ],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )
    _must(process.returncode == 0, f"CLI --workspace-wide failed: {process.stderr}\n{process.stdout}")
    lines = [line for line in process.stdout.splitlines() if line.strip().startswith("{")]
    _must(bool(lines), f"CLI did not emit JSON: {process.stdout!r}")
    return json.loads(lines[-1])


def _assert_cli_routing(
    socket_path: str,
    workspace_id: str,
    other_workspace_id: str,
    caller_surface_id: str,
    caller_window_id: str,
) -> None:
    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--workspace-wide",
    )
    _must(payload.get("link_result") == "workspace", f"CLI opt-out did not win: {payload}")

    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--workspace",
        workspace_id,
    )
    _must(payload.get("link_result") == "automatic", f"Explicit caller workspace lost attribution: {payload}")

    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--workspace",
        other_workspace_id,
    )
    _must(payload.get("workspace_id") == other_workspace_id, f"CLI changed explicit workspace routing: {payload}")
    _must(payload.get("link_result") == "no_caller", f"Different workspace retained caller attribution: {payload}")

    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--window",
        caller_window_id,
    )
    _must(payload.get("workspace_id") == workspace_id, f"Same-window caller workspace was not forwarded: {payload}")
    _must(payload.get("link_result") == "automatic", f"Same-window targeting lost attribution: {payload}")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        workspace_id = _workspace_id(client)
        caller = _first_terminal(client, workspace_id)
        caller_id = str(caller["id"])
        _mark_as_agent(client, caller_id)
        caller_location = client._call(
            "system.identify",
            {"caller": {"workspace_id": workspace_id, "surface_id": caller_id}},
        ) or {}
        caller_window_id = str((caller_location.get("caller") or {}).get("window_id") or "")
        _must(bool(caller_window_id), f"Caller window identity missing: {caller_location}")

        surface_count = len(_surface_rows(client, workspace_id))
        _expect_error(
            client,
            "browser.open_split",
            {"workspace_id": workspace_id, "caller_surface_id": "not-a-ref"},
            "invalid_params",
        )
        _must(
            len(_surface_rows(client, workspace_id)) == surface_count,
            "Malformed caller created a browser before rejection",
        )
        _expect_error(
            client,
            "browser.open_split",
            {"workspace_id": workspace_id, "link_mode": "surprise"},
            "invalid_params",
        )

        automatic = _create_browser(
            client,
            workspace_id,
            caller_surface_id=caller_id,
            link_mode="automatic",
        )
        _must(automatic.get("link_result") == "automatic", f"Valid caller did not link: {automatic}")
        browser_id = str(automatic["surface_id"])
        queried = client._call("surface.context.get", {"surface_id": browser_id}) or {}
        expected_context = _context(queried)
        _must(expected_context.get("browser_surface_id") == browser_id, "Browser identity mismatch")
        _must(expected_context.get("linked_agent_surface_id") == caller_id, "Caller identity mismatch")
        _must(isinstance(expected_context.get("browser_name"), str), "Browser name missing")
        _must(isinstance(expected_context.get("browser_surface_ref"), str), "Browser ref missing")
        _must(isinstance(expected_context.get("linked_agent_name"), str), "Agent name missing")
        _must(isinstance(expected_context.get("linked_agent_surface_ref"), str), "Agent ref missing")
        _assert_canonical_queries(client, workspace_id, browser_id, expected_context)

        before_mutations = _focus_fingerprint(client, workspace_id)
        unlinked = client._call("surface.context.unlink", {"surface_id": browser_id}) or {}
        _must(_context(unlinked).get("link_state") == "unlinked", f"Unlink failed: {unlinked}")
        _must(_focus_fingerprint(client, workspace_id) == before_mutations, "Unlink changed focus state")

        linked = client._call(
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": caller_id},
        ) or {}
        _must(_context(linked).get("linked_agent_surface_id") == caller_id, f"Link failed: {linked}")
        _must(_focus_fingerprint(client, workspace_id) == before_mutations, "Link changed focus state")

        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": caller_id, "active_agent": True},
            "invalid_params",
        )
        _expect_error(
            client,
            "surface.context.get",
            {"surface_id": caller_id},
            "target_not_browser",
        )
        _expect_error(
            client,
            "surface.context.get",
            {"surface_id": str(uuid.uuid4())},
            "browser_not_found",
        )
        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": str(uuid.uuid4())},
            "agent_not_found",
        )
        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": browser_id},
            "target_not_terminal",
        )

        stale = _create_browser(
            client,
            workspace_id,
            caller_surface_id=str(uuid.uuid4()),
        )
        _must(stale.get("link_result") == "caller_not_found", f"Stale caller result drifted: {stale}")

        no_caller = _create_browser(client, workspace_id)
        _must(no_caller.get("link_result") == "no_caller", f"Omitted caller compatibility drifted: {no_caller}")

        workspace_wide = _create_browser(
            client,
            workspace_id,
            caller_surface_id=caller_id,
            link_mode="workspace",
        )
        _must(workspace_wide.get("link_result") == "workspace", f"Workspace mode drifted: {workspace_wide}")
        _must(_context(workspace_wide).get("link_state") == "unlinked", "Workspace mode linked a browser")

        shell = client._call(
            "surface.create",
            {"workspace_id": workspace_id, "type": "terminal", "focus": False},
        ) or {}
        shell_id = str(shell.get("surface_id"))
        non_agent = _create_browser(client, workspace_id, caller_surface_id=shell_id)
        _must(non_agent.get("link_result") == "caller_not_agent", f"Non-agent result drifted: {non_agent}")
        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": shell_id},
            "agent_not_recognized",
        )

        other_workspace = client._call("workspace.create", {"focus": False}) or {}
        other_workspace_id = str(other_workspace.get("workspace_id"))
        _must(other_workspace_id and other_workspace_id != "None", f"Workspace creation failed: {other_workspace}")
        other_caller = _first_terminal(client, other_workspace_id)
        other_caller_id = str(other_caller["id"])
        _mark_as_agent(client, other_caller_id)
        cross_workspace = _create_browser(
            client,
            workspace_id,
            caller_surface_id=other_caller_id,
        )
        _must(
            cross_workspace.get("link_result") == "caller_workspace_mismatch",
            f"Cross-workspace result drifted: {cross_workspace}",
        )
        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": browser_id, "agent_surface_id": other_caller_id},
            "link_workspace_mismatch",
        )

        quiet_workspace = client._call("workspace.create", {"focus": False}) or {}
        quiet_workspace_id = str(quiet_workspace.get("workspace_id"))
        quiet_browser = _create_browser(client, quiet_workspace_id, link_mode="workspace")
        _expect_error(
            client,
            "surface.context.link",
            {"surface_id": quiet_browser["surface_id"], "active_agent": True},
            "no_active_agent",
        )

        _assert_cli_routing(
            SOCKET_PATH,
            workspace_id,
            other_workspace_id,
            caller_id,
            caller_window_id,
        )

    print("PASS: agent companion creation, mutation, canonical query, compatibility, and focus contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
