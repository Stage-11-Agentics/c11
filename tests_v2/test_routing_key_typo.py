#!/usr/bin/env python3
"""C11-279 tagged/sandbox socket proof; never run on the operator's session.

Requires an explicit C11_279_SOCKET from the guest/tagged build.
Creates one disposable workspace, verifies rejection on worker and main-actor
commands, proves a listed alias delivers, then closes the workspace.

Routing selectors are checked by exact spelling: a case or underscore variant of a
selector (`Panel_ID`, `panelid`, `surfaceId`, `tabRef`) is rejected with the canonical
spelling suggested, and the suggestion names the panel family (`panel_id`, `panel_ref`,
`area_id`), whichever old spelling was typed. The listed spellings (`panel_id`, `tab_id`,
`surface_id`, and the `*_ref` forms) are accepted and deliver.
"""

import os
from pathlib import Path
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def screen(client, workspace, panel):
    # `busy` is the documented retry signal (a cold background terminal attaching).
    deadline = time.time() + 10
    while True:
        try:
            return str(client._call("panel.read_text", {"workspace_id": workspace, "panel_id": panel}).get("text", ""))
        except cmuxError as error:
            if not str(error).startswith("busy") or time.time() > deadline:
                raise
            time.sleep(0.25)


def reject(client, method, params, key, canonical):
    try:
        client._call(method, params)
    except cmuxError as error:
        message = str(error)
        assert "invalid_params" in message and key in message and canonical in message, message
        # The suggestion follows the rejected key, and names the panel family only.
        suggestion = message.split(key, 1)[1]
        assert f"'{canonical}'" in suggestion, (key, canonical, message)
        for old_family in ("tab_", "surface_", "pane_", "tabId", "surfaceId", "paneId"):
            assert old_family not in suggestion, (key, old_family, message)
    else:
        raise AssertionError(f"{method} accepted unsupported routing key {key}")


def delivered(client, workspace, panel, token, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if token in screen(client, workspace, panel):
            return True
        time.sleep(0.15)
    return False


def main():
    socket_path = os.environ["C11_279_SOCKET"]
    workspace = None
    with cmux(socket_path) as client:
        try:
            features = client._call("system.capabilities")["features"]
            assert any(item["id"] == "routing.canonical_keys" and item["version"] == 1 for item in features)
            workspace = client._call("workspace.create")["workspace_id"]
            panel = client._call("panel.list", {"workspace_id": workspace})["panels"][0]["id"]
            area = client._call("area.list", {"workspace_id": workspace})["areas"][0]["id"]
            rejected = "C11279_REJECT_" + uuid.uuid4().hex

            # Case and underscore variants of a panel selector are rejected, and the
            # suggestion is the canonical panel spelling, whichever old name was typed.
            for key, canonical in (
                ("surfaceId", "panel_id"),
                ("Panel_ID", "panel_id"),
                ("panelid", "panel_id"),
                ("panelId", "panel_id"),
                ("tabId", "panel_id"),
                ("TAB_ID", "panel_id"),
                ("SurfaceID", "panel_id"),
                ("tabRef", "panel_ref"),
                ("panelRef", "panel_ref"),
                ("Surface_Ref", "panel_ref"),
            ):
                reject(client, "panel.send_text", {
                    "workspace_id": workspace, key: panel, "text": rejected, "submit": False
                }, key, canonical)

            # The same policy applies under the older method names (both reach one handler).
            for method in ("tab.send_text", "surface.send_text"):
                reject(client, method, {
                    "workspace_id": workspace, "Panel_ID": panel, "text": rejected, "submit": False
                }, "Panel_ID", "panel_id")

            # Area selectors: the suggestion is area_id / area_ref, never pane_*.
            for key, canonical in (("areaId", "area_id"), ("paneId", "area_id"), ("Pane_ID", "area_id"),
                                   ("paneRef", "area_ref")):
                reject(client, "area.panels", {"workspace_id": workspace, key: area}, key, canonical)

            # Prefixed selectors keep their own canonical suggestion.
            reject(client, "panel.move", {
                "workspace_id": workspace, "panel_id": panel, "targetAreaId": area
            }, "targetAreaId", "target_area_id")
            reject(client, "panel.reorder", {
                "workspace_id": workspace, "panel_id": panel, "beforePanelId": panel
            }, "beforePanelId", "before_panel_id")

            # system.identify follows the main-actor dispatch seam; no mutation
            # is needed to show it applies the same rejection policy.
            reject(client, "system.identify", {
                "workspaceId": workspace
            }, "workspaceId", "workspace_id")
            assert rejected not in screen(client, workspace, panel), "rejected input reached the focused terminal"

            # Opaque nested data and character typos remain outside this check.
            client._call("system.identify", {
                "metadata": {"surfaceId": panel, "panelId": panel}, "surfce_id": panel, "panl_id": panel,
                "title": "fixture"
            })

            # Every listed spelling is accepted and delivers.
            for method, key in (("panel.send_text", "panel_id"), ("panel.send_text", "tab_id"),
                                ("panel.send_text", "surface_id"), ("tab.send_text", "tab_id"),
                                ("surface.send_text", "surface_id")):
                token = "C11279_ALIAS_" + uuid.uuid4().hex
                client._call(method, {
                    "workspace_id": workspace, key: panel, "text": token, "submit": False
                })
                assert delivered(client, workspace, panel, token), f"listed alias {method} with {key} did not deliver"
            # Ref selectors in every prefix deliver too.
            ref = client._call("panel.list", {"workspace_id": workspace})["panels"][0]["ref"]
            ordinal = ref.split(":", 1)[1]
            for key, value in (("panel_ref", f"panel:{ordinal}"), ("tab_ref", f"tab:{ordinal}"),
                               ("surface_ref", f"surface:{ordinal}"), ("panel_id", f"TAB:{ordinal}")):
                token = "C11279_REF_" + uuid.uuid4().hex
                client._call("panel.send_text", {
                    "workspace_id": workspace, key: value, "text": token, "submit": False
                })
                assert delivered(client, workspace, panel, token), f"listed ref {key}={value} did not deliver"
            print("PASS C11-279 worker/main rejection, no rejected input, and listed alias delivery")
        finally:
            if workspace is not None:
                client.close_workspace(workspace)


if __name__ == "__main__":
    main()
