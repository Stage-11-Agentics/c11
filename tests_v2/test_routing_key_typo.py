#!/usr/bin/env python3
"""C11-279 tagged/sandbox socket proof; never run on the operator's session.

Requires an explicit C11_SOCKET_PATH or C11_SOCKET from the guest/tagged build.
Creates one disposable workspace, verifies rejection on worker and main-actor
commands, proves a listed alias delivers, then closes the workspace.
"""

import os
from pathlib import Path
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def screen(client, workspace, tab):
    return str(client._call("tab.read_text", {"workspace_id": workspace, "tab_id": tab}).get("text", ""))


def reject(client, method, params, key, canonical):
    try:
        client._call(method, params)
    except cmuxError as error:
        message = str(error)
        assert "invalid_params" in message and key in message and canonical in message, message
    else:
        raise AssertionError(f"{method} accepted unsupported routing key {key}")


def main():
    socket_path = os.environ.get("C11_SOCKET_PATH") or os.environ["C11_SOCKET"]
    workspace = None
    with cmux(socket_path) as client:
        try:
            features = client._call("system.capabilities")["features"]
            assert any(item["id"] == "routing.canonical_keys" and item["version"] == 1 for item in features)
            workspace = client._call("workspace.create")["workspace_id"]
            client._call("workspace.select", {"workspace_id": workspace})
            tab = client._call("tab.list", {"workspace_id": workspace})["tabs"][0]["id"]
            rejected = "C11279_REJECT_" + uuid.uuid4().hex

            reject(client, "tab.send_text", {
                "workspace_id": workspace, "surfaceId": tab, "text": rejected, "submit": False
            }, "surfaceId", "tab_id")
            reject(client, "tab.send_text", {
                "workspace_id": workspace, "tabRef": tab, "text": rejected, "submit": False
            }, "tabRef", "tab_ref")
            # system.identify follows the main-actor dispatch seam; no mutation
            # is needed to show it applies the same rejection policy.
            reject(client, "system.identify", {
                "workspaceId": workspace
            }, "workspaceId", "workspace_id")
            assert rejected not in screen(client, workspace, tab), "rejected input reached the focused terminal"

            # Opaque nested data and character typos remain outside this check.
            client._call("system.identify", {
                "metadata": {"surfaceId": tab}, "surfce_id": tab, "title": "fixture"
            })
            delivered = "C11279_ALIAS_" + uuid.uuid4().hex
            client._call("tab.send_text", {
                "workspace_id": workspace, "surface_id": tab, "text": delivered, "submit": False
            })
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if delivered in screen(client, workspace, tab):
                    print("PASS C11-279 worker/main rejection, no rejected input, and listed alias delivery")
                    break
                time.sleep(0.15)
            else:
                raise AssertionError("listed surface_id alias did not deliver")
        finally:
            if workspace is not None:
                client.close_workspace(workspace)


if __name__ == "__main__":
    main()
