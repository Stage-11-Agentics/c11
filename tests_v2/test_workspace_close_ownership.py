#!/usr/bin/env python3
"""C11-300 routing/move oracle; run only against an isolated tagged test guest.

The socket rejects an explicit wrong-window close before calling closeWorkspace.
This checks that public boundary and live terminal survival. The host-target
WorkspaceManagerWorkspaceOwnershipTests directly exercises the repaired method.
Confirmation UI remains a separate batch Validator scenario.

Creates and closes only its own two windows. The caller owns verified-display,
hard UI timeout, screenshots, and final synthesized dismissal of the tagged app.
"""
from __future__ import annotations

import argparse
import json
import re
import time
import uuid

from cmux import cmux, cmuxError


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def probe(client: cmux, tab: str, stage: str, marker: str) -> tuple[str, str]:
    client.send_surface(tab,
        'if kill -0 "$C11_OWNERSHIP_CHILD" 2>/dev/null; then '
        f"printf 'C11_OWNERSHIP_{stage} %s %s %s\\n' "
        '"$$" "$C11_OWNERSHIP_CHILD" "$C11_OWNERSHIP_MARKER"; fi\n')
    pattern = re.compile(rf"C11_OWNERSHIP_{stage} (\d+) (\d+) {marker}(?:\s|$)")
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        match = pattern.search(client.read_terminal_text(tab))
        if match:
            return match.group(1), match.group(2)
        time.sleep(0.2)
    raise AssertionError(f"{stage}: shell variable or live child missing")


def wrong_window_close(client: cmux, workspace: str, window: str) -> None:
    try:
        client._call("workspace.close", {"workspace_id": workspace, "window_id": window})
    except cmuxError as error:
        require(str(error).startswith("not_found:"), f"unexpected close error: {error}")
    else:
        raise AssertionError("wrong-window close must return not_found")


def workspace_ids(client: cmux, window: str) -> list[str]:
    return [row[1] for row in client.list_workspaces(window_id=window)]


def run(client: cmux) -> dict:
    windows: list[str] = []
    try:
        for _ in range(2):
            windows.append(client.new_window())
        source, destination = windows
        workspace = client.new_workspace(window_id=source)
        client.new_workspace(window_id=destination)
        source_before = workspace_ids(client, source)
        destination_before = workspace_ids(client, destination)
        require(len(source_before) >= 2 and len(destination_before) >= 2, "two workspaces per window required")
        client.select_workspace(workspace)
        tabs_before = client.list_surfaces(workspace)
        tab_ids = [row[1] for row in tabs_before]
        require(bool(tab_ids), "fixture needs a terminal")
        tab = tab_ids[0]
        marker = uuid.uuid4().hex
        client.send_surface(tab,
            f"C11_OWNERSHIP_MARKER={marker}; "
            "(for i in {1..120}; do sleep 1; done) & C11_OWNERSHIP_CHILD=$!\n")
        before = probe(client, tab, "BEFORE", marker)

        wrong_window_close(client, workspace, destination)
        require(workspace_ids(client, source) == source_before, "wrong close changed source list")
        require(workspace_ids(client, destination) == destination_before, "wrong close changed destination list")
        require([row[1] for row in client.list_surfaces(workspace)] == tab_ids, "wrong close changed tabs")
        require(probe(client, tab, "WRONG_CLOSE", marker) == before, "wrong close restarted shell/child")

        client.move_workspace_to_window(workspace, destination, focus=False)
        require(workspace not in workspace_ids(client, source), "move left workspace in source")
        require(workspace in workspace_ids(client, destination), "move missing from destination")
        require([row[1] for row in client.list_surfaces(workspace)] == tab_ids, "move changed tabs")
        wrong_window_close(client, workspace, source)
        require(probe(client, tab, "MOVED", marker) == before, "move/stale close restarted shell/child")

        client._call("workspace.close", {"workspace_id": workspace, "window_id": destination})
        require(workspace not in workspace_ids(client, destination), "owner close did not remove workspace")
        require(workspace_ids(client, source) == [w for w in source_before if w != workspace], "owner close changed source siblings")
        require(workspace_ids(client, destination) == destination_before, "owner close changed destination siblings")
        return {"workspace": workspace, "panels": tab_ids, "shell_pid": before[0], "child_pid": before[1],
                "wrong_window": "not_found", "move_and_stale_close": "survived", "owner_close": "removed"}
    finally:
        for window in reversed(windows):
            client.close_window(window)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="isolated guest socket, never the operator session")
    args = parser.parse_args()
    with cmux(socket_path=args.socket) as client:
        result = run(client)
    print(json.dumps({"result": "PASS", "evidence": result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
