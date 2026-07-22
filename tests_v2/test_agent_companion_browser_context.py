#!/usr/bin/env python3
"""Tagged-socket contract for agent-linked companion browser public APIs.

This file is authored in ACB-04 but intentionally executed only by ACB-07/11
against tagged apps. Run the enabled matrix with the default test environment;
run the default-off compatibility matrix with
``C11_AGENT_COMPANION_EXPECT_ENABLED=0`` against a feature-disabled app.
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
EXPECT_ENABLED = os.environ.get("C11_AGENT_COMPANION_EXPECT_ENABLED", "1").strip().lower() not in {
    "0",
    "false",
    "off",
}
LSAPPINFO = "/usr/bin/lsappinfo"

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


def _workspace_location(client: cmux, workspace_id: str) -> dict[str, Any]:
    payload = client._call("workspace.list") or {}
    row = next(
        (item for item in payload.get("workspaces") or [] if item.get("id") == workspace_id),
        None,
    )
    _must(isinstance(row, dict), f"Workspace missing from workspace.list: {payload}")
    location = dict(row)
    location["window_id"] = payload.get("window_id")
    location["window_ref"] = payload.get("window_ref")
    _must(isinstance(location.get("ref"), str), f"Workspace ref missing: {location}")
    _must(isinstance(location.get("index"), int), f"Workspace index missing: {location}")
    _must(isinstance(location.get("window_id"), str), f"Window id missing: {location}")
    _must(isinstance(location.get("window_ref"), str), f"Window ref missing: {location}")
    return location


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


def _frontmost_application() -> str:
    process = subprocess.run(
        [LSAPPINFO, "front"],
        capture_output=True,
        text=True,
        check=False,
    )
    _must(
        process.returncode == 0 and bool(process.stdout.strip()),
        f"Unable to read frontmost macOS application: {process.stderr!r}",
    )
    return process.stdout.strip()


def _focus_fingerprint(client: cmux, workspace_id: str) -> str:
    identify = client._call("system.identify") or {}
    window_list = client._call("window.list") or {}
    pane_list = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    compact = {
        "frontmost_application": _frontmost_application(),
        "focused": identify.get("focused"),
        "windows": [
            {
                "id": row.get("id"),
                "key": row.get("key"),
                "visible": row.get("visible"),
                "selected_workspace_id": row.get("selected_workspace_id"),
            }
            for row in window_list.get("windows") or []
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
    before_surface_list = _focus_fingerprint(client, workspace_id)
    surface_row = next(
        (row for row in _surface_rows(client, workspace_id) if row.get("id") == browser_id),
        None,
    )
    _must(
        _focus_fingerprint(client, workspace_id) == before_surface_list,
        "surface.list changed window/workspace/pane/surface focus",
    )
    _must(isinstance(surface_row, dict), "Created browser missing from surface.list")
    _must(_context(surface_row) == expected, "surface.list context differs from surface.context.get")

    before_tree = _focus_fingerprint(client, workspace_id)
    tree = client._call("system.tree", {"workspace_id": workspace_id}) or {}
    _must(
        _focus_fingerprint(client, workspace_id) == before_tree,
        "system.tree changed window/workspace/pane/surface focus",
    )
    tree_row = _find_surface_node(tree, browser_id)
    _must(isinstance(tree_row, dict), "Created browser missing from system.tree")
    _must(_context(tree_row) == expected, "system.tree context differs from surface.context.get")

    before_tab_list = _focus_fingerprint(client, workspace_id)
    tabs = client._call("browser.tab.list", {"workspace_id": workspace_id}) or {}
    _must(
        _focus_fingerprint(client, workspace_id) == before_tab_list,
        "browser.tab.list changed window/workspace/pane/surface focus",
    )
    tab_row = next((row for row in tabs.get("tabs") or [] if row.get("id") == browser_id), None)
    _must(isinstance(tab_row, dict), "Created browser missing from browser.tab.list")
    _must(_context(tab_row) == expected, "browser.tab.list context differs from surface.context.get")


def _run_cli_process(
    socket_path: str,
    workspace_id: str | None,
    caller_surface_id: str | None,
    *arguments: str,
    legacy_workspace_id: str | None = None,
    legacy_surface_id: str | None = None,
) -> subprocess.CompletedProcess[str]:
    cli = find_cli_binary()
    environment = dict(os.environ)
    environment["C11_SOCKET"] = socket_path
    for key, value in [
        ("C11_WORKSPACE_ID", workspace_id),
        ("C11_SURFACE_ID", caller_surface_id),
        ("CMUX_WORKSPACE_ID", legacy_workspace_id),
        ("CMUX_SURFACE_ID", legacy_surface_id),
    ]:
        if value is None:
            environment.pop(key, None)
        else:
            environment[key] = value
    return subprocess.run(
        [
            cli,
            "--socket",
            socket_path,
            "--json",
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )


def _run_cli_json(
    socket_path: str,
    workspace_id: str | None,
    caller_surface_id: str | None,
    *arguments: str,
    legacy_workspace_id: str | None = None,
    legacy_surface_id: str | None = None,
) -> dict[str, Any]:
    process = _run_cli_process(
        socket_path,
        workspace_id,
        caller_surface_id,
        *arguments,
        legacy_workspace_id=legacy_workspace_id,
        legacy_surface_id=legacy_surface_id,
    )
    _must(process.returncode == 0, f"CLI command failed: {process.stderr}\n{process.stdout}")
    json_start = process.stdout.find("{")
    _must(json_start >= 0, f"CLI did not emit JSON: {process.stdout!r}")
    payload, _ = json.JSONDecoder().raw_decode(process.stdout[json_start:])
    _must(isinstance(payload, dict), f"CLI emitted non-object JSON: {payload!r}")
    return payload


def _expect_cli_failure(
    socket_path: str,
    workspace_id: str | None,
    caller_surface_id: str | None,
    expected_text: str,
    *arguments: str,
) -> None:
    process = _run_cli_process(
        socket_path,
        workspace_id,
        caller_surface_id,
        *arguments,
    )
    output = f"{process.stderr}\n{process.stdout}"
    _must(process.returncode != 0, f"CLI unexpectedly succeeded: {output}")
    _must(expected_text in output, f"Expected CLI error containing {expected_text!r}, got: {output}")


def _run_cli_browser_open(
    socket_path: str,
    workspace_id: str | None,
    caller_surface_id: str | None,
    *arguments: str,
    legacy_workspace_id: str | None = None,
    legacy_surface_id: str | None = None,
) -> dict[str, Any]:
    return _run_cli_json(
        socket_path,
        workspace_id,
        caller_surface_id,
        "browser",
        "open",
        *arguments,
        "about:blank?agent-companion-contract=1",
        legacy_workspace_id=legacy_workspace_id,
        legacy_surface_id=legacy_surface_id,
    )


def _assert_cli_routing(
    client: cmux,
    socket_path: str,
    workspace_id: str,
    workspace_ref: str,
    workspace_index: int,
    other_workspace_id: str,
    caller_surface_id: str,
    caller_window_id: str,
    caller_window_ref: str,
    caller_pane_id: str,
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

    for equivalent_workspace in (workspace_ref, workspace_id.lower()):
        payload = _run_cli_browser_open(
            socket_path,
            workspace_id,
            caller_surface_id,
            "--workspace",
            equivalent_workspace,
        )
        _must(
            payload.get("link_result") == "automatic",
            f"Equivalent workspace spelling lost attribution ({equivalent_workspace}): {payload}",
        )

    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--window",
        caller_window_id,
        "--workspace",
        str(workspace_index),
    )
    _must(payload.get("link_result") == "automatic", f"Workspace index lost attribution: {payload}")

    payload = _run_cli_browser_open(
        socket_path,
        workspace_id,
        caller_surface_id,
        "--workspace",
        other_workspace_id,
    )
    _must(payload.get("workspace_id") == other_workspace_id, f"CLI changed explicit workspace routing: {payload}")
    _must(payload.get("link_result") == "no_caller", f"Different workspace retained caller attribution: {payload}")

    for equivalent_window in (caller_window_ref, caller_window_id.lower()):
        payload = _run_cli_browser_open(
            socket_path,
            workspace_id,
            caller_surface_id,
            "--window",
            equivalent_window,
        )
        _must(
            payload.get("workspace_id") == workspace_id,
            f"Same-window caller workspace was not forwarded ({equivalent_window}): {payload}",
        )
        _must(
            payload.get("link_result") == "automatic",
            f"Same-window targeting lost attribution ({equivalent_window}): {payload}",
        )

    new_surface = _run_cli_json(
        socket_path,
        workspace_id,
        caller_surface_id,
        "new-surface",
        "--type",
        "browser",
        "--workspace",
        workspace_ref,
        "--pane",
        caller_pane_id,
        "--url",
        "about:blank?cli-new-surface=1",
        "--no-focus",
    )
    _must(new_surface.get("link_result") == "automatic", f"CLI new-surface did not link: {new_surface}")

    new_pane = _run_cli_json(
        socket_path,
        workspace_id,
        caller_surface_id,
        "new-pane",
        "--type",
        "browser",
        "--workspace",
        workspace_ref,
        "--direction",
        "down",
        "--url",
        "about:blank?cli-new-pane=1",
        "--force",
    )
    _must(new_pane.get("link_result") == "automatic", f"CLI new-pane did not link: {new_pane}")

    created_window = client._call("window.create") or {}
    different_window_id = str(created_window.get("window_id") or "")
    _must(bool(different_window_id), f"window.create failed: {created_window}")
    try:
        different_window_workspaces = client._call(
            "workspace.list",
            {"window_id": different_window_id},
        ) or {}
        target_workspace = next(
            (
                row
                for row in different_window_workspaces.get("workspaces") or []
                if row.get("selected") is True
            ),
            None,
        )
        if target_workspace is None:
            target_workspace = next(
                iter(different_window_workspaces.get("workspaces") or []),
                None,
            )
        _must(
            isinstance(target_workspace, dict),
            f"New window has no target workspace: {different_window_workspaces}",
        )
        target_workspace_id = str(target_workspace.get("id") or "")
        target_workspace_index = target_workspace.get("index")
        _must(
            bool(target_workspace_id) and isinstance(target_workspace_index, int),
            f"New-window workspace identity is incomplete: {target_workspace}",
        )
        target_pane_id = str(_first_terminal(client, target_workspace_id).get("pane_id") or "")
        _must(bool(target_pane_id), "New-window workspace has no target pane")

        for route in ("browser open", "new-surface", "new-pane"):
            different_window = _run_cli_json(
                socket_path,
                workspace_id,
                caller_surface_id,
                *_cli_creation_arguments(
                    route,
                    str(target_workspace_index),
                    target_pane_id,
                    window_handle=different_window_id,
                ),
            )
            _must(
                different_window.get("window_id") == different_window_id,
                f"CLI {route} changed explicit different-window routing: {different_window}",
            )
            _must(
                different_window.get("workspace_id") == target_workspace_id,
                f"CLI {route} resolved a numeric workspace outside its explicit window: {different_window}",
            )
            _must(
                different_window.get("link_result") == "no_caller",
                f"CLI {route} retained caller attribution across windows: {different_window}",
            )
    finally:
        client._call("window.close", {"window_id": different_window_id})


def _socket_creation_request(
    method: str,
    workspace_id: str,
    caller_pane_id: str,
    caller_surface_id: str | None,
    *,
    workspace_wide: bool = False,
    invalid_link_mode: bool = False,
) -> tuple[str, dict[str, Any]]:
    if method == "browser.open_split":
        params: dict[str, Any] = {
            "workspace_id": workspace_id,
            "url": "about:blank?socket-outcome-matrix=1",
        }
    elif method == "surface.create":
        params = {
            "workspace_id": workspace_id,
            "pane_id": caller_pane_id,
            "type": "browser",
            "url": "about:blank?socket-outcome-matrix=1",
            "focus": False,
        }
    elif method == "pane.create":
        params = {
            "workspace_id": workspace_id,
            "direction": "down",
            "type": "browser",
            "url": "about:blank?socket-outcome-matrix=1",
            "allow_undersized": True,
        }
    else:
        raise cmuxError(f"Unknown socket creation route: {method}")

    if caller_surface_id is not None:
        params["caller_surface_id"] = caller_surface_id
    if workspace_wide:
        params["link_mode"] = "workspace"
    if invalid_link_mode:
        params["link_mode"] = "not-a-link-mode"
    return method, params


def _cli_creation_arguments(
    route: str,
    workspace_handle: str,
    caller_pane_id: str,
    *,
    workspace_wide: bool = False,
    window_handle: str | None = None,
) -> list[str]:
    prefix = ["--window", window_handle] if window_handle is not None else []
    wide = ["--workspace-wide"] if workspace_wide else []
    if route == "browser open":
        window = ["--window", window_handle] if window_handle is not None else []
        return [
            "browser",
            "open",
            *window,
            "--workspace",
            workspace_handle,
            *wide,
            "about:blank?cli-outcome-matrix=1",
        ]
    if route == "new-surface":
        return [
            *prefix,
            "new-surface",
            "--type",
            "browser",
            "--workspace",
            workspace_handle,
            "--pane",
            caller_pane_id,
            "--url",
            "about:blank?cli-outcome-matrix=1",
            "--no-focus",
            *wide,
        ]
    if route == "new-pane":
        return [
            *prefix,
            "new-pane",
            "--type",
            "browser",
            "--workspace",
            workspace_handle,
            "--direction",
            "down",
            "--url",
            "about:blank?cli-outcome-matrix=1",
            "--force",
            *wide,
        ]
    raise cmuxError(f"Unknown CLI creation route: {route}")


def _assert_creation_payload(
    client: cmux,
    label: str,
    payload: dict[str, Any],
    expected_result: str,
    expected_agent_id: str | None,
) -> None:
    _must(payload.get("link_result") == expected_result, f"{label} returned wrong outcome: {payload}")
    context = _context(payload)
    _must(
        context.get("linked_agent_surface_id") == expected_agent_id,
        f"{label} returned wrong linked caller: {context}",
    )
    surface_id = payload.get("surface_id")
    _must(isinstance(surface_id, str), f"{label} returned no browser: {payload}")
    client._call("surface.close", {"surface_id": surface_id})


def _assert_creation_outcome_matrix(
    client: cmux,
    socket_path: str,
    workspace_id: str,
    workspace_ref: str,
    workspace_index: int,
    caller_window_id: str,
    caller_surface_id: str,
    caller_surface_ref: str,
    caller_pane_id: str,
    non_agent_surface_id: str,
    cross_workspace_id: str,
    cross_workspace_agent_id: str,
) -> None:
    outcomes = [
        ("automatic", caller_surface_id, False, "automatic", caller_surface_id),
        ("stale caller", str(uuid.uuid4()), False, "caller_not_found", None),
        ("cross-workspace caller", cross_workspace_agent_id, False, "caller_workspace_mismatch", None),
        ("non-agent caller", non_agent_surface_id, False, "caller_not_agent", None),
        ("omitted caller", None, False, "no_caller", None),
        ("workspace-wide malformed caller", "malformed-caller", True, "workspace", None),
    ]

    for method in ("browser.open_split", "surface.create", "pane.create"):
        before = len(_surface_rows(client, workspace_id))
        invalid_method, invalid_params = _socket_creation_request(
            method,
            workspace_id,
            caller_pane_id,
            caller_surface_id,
            invalid_link_mode=True,
        )
        _expect_error(client, invalid_method, invalid_params, "invalid_params")
        malformed_method, malformed_params = _socket_creation_request(
            method,
            workspace_id,
            caller_pane_id,
            "malformed-caller",
        )
        _expect_error(client, malformed_method, malformed_params, "invalid_params")
        _must(
            len(_surface_rows(client, workspace_id)) == before,
            f"{method} mutated before rejecting invalid provenance",
        )
        for case, caller, workspace_wide, expected, linked_agent in outcomes:
            route_method, params = _socket_creation_request(
                method,
                workspace_id,
                caller_pane_id,
                caller,
                workspace_wide=workspace_wide,
            )
            payload = client._call(route_method, params) or {}
            _assert_creation_payload(client, f"{method} / {case}", payload, expected, linked_agent)

        mixed_method, mixed_params = _socket_creation_request(
            method,
            workspace_ref,
            caller_pane_id,
            caller_surface_ref,
        )
        mixed_payload = client._call(mixed_method, mixed_params) or {}
        _assert_creation_payload(
            client,
            f"{method} / mixed workspace-ref and caller-ref handles",
            mixed_payload,
            "automatic",
            caller_surface_id,
        )

    for route in ("browser open", "new-surface", "new-pane"):
        before = len(_surface_rows(client, workspace_id))
        invalid_arguments = _cli_creation_arguments(
            route,
            "not-a-workspace-handle",
            caller_pane_id,
        )
        _expect_cli_failure(
            socket_path,
            workspace_id,
            caller_surface_id,
            "Invalid workspace handle:",
            *invalid_arguments,
        )
        _must(
            len(_surface_rows(client, workspace_id)) == before,
            f"CLI {route} mutated before rejecting an invalid workspace handle",
        )

        for handle in (workspace_id, workspace_ref, workspace_id.lower()):
            payload = _run_cli_json(
                socket_path,
                workspace_id,
                caller_surface_id,
                *_cli_creation_arguments(route, handle, caller_pane_id),
            )
            _assert_creation_payload(
                client,
                f"CLI {route} / same-target handle {handle}",
                payload,
                "automatic",
                caller_surface_id,
            )

        mixed = _run_cli_json(
            socket_path,
            workspace_id,
            caller_surface_ref,
            *_cli_creation_arguments(route, workspace_ref, caller_pane_id),
        )
        _assert_creation_payload(
            client,
            f"CLI {route} / mixed workspace-ref and caller-ref handles",
            mixed,
            "automatic",
            caller_surface_id,
        )

        precedence = _run_cli_json(
            socket_path,
            workspace_id,
            caller_surface_id,
            *_cli_creation_arguments(route, workspace_ref, caller_pane_id),
            legacy_workspace_id=cross_workspace_id,
            legacy_surface_id=cross_workspace_agent_id,
        )
        _assert_creation_payload(
            client,
            f"CLI {route} / C11 environment precedence over conflicting CMUX environment",
            precedence,
            "automatic",
            caller_surface_id,
        )

        indexed = _run_cli_json(
            socket_path,
            workspace_id,
            caller_surface_id,
            *_cli_creation_arguments(
                route,
                str(workspace_index),
                caller_pane_id,
                window_handle=caller_window_id,
            ),
        )
        _assert_creation_payload(
            client,
            f"CLI {route} / explicit-window index",
            indexed,
            "automatic",
            caller_surface_id,
        )

        cli_outcomes = [
            ("malformed caller suppression", workspace_id, "malformed-caller", False, "no_caller"),
            ("stale caller suppression", workspace_id, str(uuid.uuid4()), False, "no_caller"),
            (
                "different-workspace suppression",
                cross_workspace_id,
                cross_workspace_agent_id,
                False,
                "no_caller",
            ),
            ("non-agent caller", workspace_id, non_agent_surface_id, False, "caller_not_agent"),
            ("omitted caller", None, None, False, "no_caller"),
            ("workspace-wide malformed caller", workspace_id, "malformed-caller", True, "workspace"),
        ]
        for case, caller_workspace, caller, workspace_wide, expected in cli_outcomes:
            payload = _run_cli_json(
                socket_path,
                caller_workspace,
                caller,
                *_cli_creation_arguments(
                    route,
                    workspace_ref,
                    caller_pane_id,
                    workspace_wide=workspace_wide,
                ),
            )
            _assert_creation_payload(client, f"CLI {route} / {case}", payload, expected, None)


def _assert_disabled_compatibility(
    client: cmux,
    workspace_id: str,
    caller_surface_id: str,
    caller_pane_id: str,
) -> None:
    requests = [
        (
            "browser.open_split",
            {
                "workspace_id": workspace_id,
                "url": "about:blank?disabled-open-split=1",
                "caller_surface_id": "malformed-caller",
                "link_mode": "invalid-while-disabled",
            },
        ),
        (
            "surface.create",
            {
                "workspace_id": workspace_id,
                "pane_id": caller_pane_id,
                "type": "browser",
                "url": "about:blank?disabled-surface-create=1",
                "focus": False,
                "caller_surface_id": "malformed-caller",
                "link_mode": "invalid-while-disabled",
            },
        ),
        (
            "pane.create",
            {
                "workspace_id": workspace_id,
                "direction": "down",
                "type": "browser",
                "url": "about:blank?disabled-pane-create=1",
                "allow_undersized": True,
                "caller_surface_id": "malformed-caller",
                "link_mode": "invalid-while-disabled",
            },
        ),
    ]
    created_ids: list[str] = []
    additive_keys = {
        "link_result",
        "context",
        "linked_agent_surface_id",
        "linked_agent_surface_ref",
        "linked_agent_name",
    }
    for method, params in requests:
        payload = client._call(method, params) or {}
        _must(isinstance(payload.get("surface_id"), str), f"Disabled {method} failed: {payload}")
        _must(additive_keys.isdisjoint(payload), f"Disabled {method} leaked additive fields: {payload}")
        created_ids.append(str(payload["surface_id"]))

    cli_requests = [
        (
            "browser open",
            lambda: _run_cli_browser_open(SOCKET_PATH, workspace_id, caller_surface_id),
        ),
        (
            "new-surface",
            lambda: _run_cli_json(
                SOCKET_PATH,
                workspace_id,
                caller_surface_id,
                "new-surface",
                "--type",
                "browser",
                "--workspace",
                workspace_id,
                "--pane",
                caller_pane_id,
                "--url",
                "about:blank?disabled-cli-new-surface=1",
                "--no-focus",
            ),
        ),
        (
            "new-pane",
            lambda: _run_cli_json(
                SOCKET_PATH,
                workspace_id,
                caller_surface_id,
                "new-pane",
                "--type",
                "browser",
                "--workspace",
                workspace_id,
                "--direction",
                "down",
                "--url",
                "about:blank?disabled-cli-new-pane=1",
                "--force",
            ),
        ),
    ]
    for label, create in cli_requests:
        payload = create()
        _must(additive_keys.isdisjoint(payload), f"Disabled CLI {label} leaked additive fields: {payload}")
        created_ids.append(str(payload["surface_id"]))

    for row in _surface_rows(client, workspace_id):
        if row.get("id") in created_ids:
            _must("context" not in row, f"Disabled surface.list leaked context: {row}")

    tree = client._call("system.tree", {"workspace_id": workspace_id}) or {}
    for surface_id in created_ids:
        row = _find_surface_node(tree, surface_id)
        _must(isinstance(row, dict) and "context" not in row, f"Disabled system.tree leaked context: {row}")

    tabs = client._call("browser.tab.list", {"workspace_id": workspace_id}) or {}
    for row in tabs.get("tabs") or []:
        if row.get("id") in created_ids:
            _must("context" not in row, f"Disabled browser.tab.list leaked context: {row}")

    for method, params in [
        ("surface.context.get", {"surface_id": created_ids[0]}),
        (
            "surface.context.link",
            {"surface_id": created_ids[0], "agent_surface_id": caller_surface_id},
        ),
        ("surface.context.unlink", {"surface_id": created_ids[0]}),
    ]:
        _expect_error(client, method, params, "method_not_found")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        workspace_id = _workspace_id(client)
        workspace_location = _workspace_location(client, workspace_id)
        caller = _first_terminal(client, workspace_id)
        caller_id = str(caller["id"])
        caller_ref = str(caller.get("ref") or "")
        caller_pane_id = str(caller.get("pane_id") or "")
        _must(bool(caller_ref), f"Caller ref identity missing: {caller}")
        _must(bool(caller_pane_id), f"Caller pane identity missing: {caller}")

        if not EXPECT_ENABLED:
            _assert_disabled_compatibility(
                client,
                workspace_id,
                caller_id,
                caller_pane_id,
            )
            print("PASS: disabled companion APIs and additive response/query fields remain absent")
            return 0

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
        before_context_get = _focus_fingerprint(client, workspace_id)
        queried = client._call("surface.context.get", {"surface_id": browser_id}) or {}
        _must(
            _focus_fingerprint(client, workspace_id) == before_context_get,
            "surface.context.get changed window/workspace/pane/surface focus",
        )
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
            caller_surface_id="malformed-caller-must-be-ignored",
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

        _assert_creation_outcome_matrix(
            client,
            SOCKET_PATH,
            workspace_id,
            str(workspace_location["ref"]),
            int(workspace_location["index"]),
            caller_window_id,
            caller_id,
            caller_ref,
            caller_pane_id,
            shell_id,
            other_workspace_id,
            other_caller_id,
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
            client,
            SOCKET_PATH,
            workspace_id,
            str(workspace_location["ref"]),
            int(workspace_location["index"]),
            other_workspace_id,
            caller_id,
            caller_window_id,
            str(workspace_location["window_ref"]),
            caller_pane_id,
        )

    print("PASS: agent companion creation, mutation, canonical query, compatibility, and focus contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
