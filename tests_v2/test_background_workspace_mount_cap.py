#!/usr/bin/env python3
"""B012: bounded mounts and headless demand in a 60-workspace isolated QA app.

Run in the sandbox guest with C11_MOUNT_LOG=/tmp/c11-debug-<tag>.log and
C11_SOCKET_PATH set. Uses real mount/prime events; workspace count is not used
as a proxy for mounted SwiftUI bodies. Disable debug mount-retention fixtures.
Restore and human-visible switch checks belong to the batch Validator scenario.
"""

import os
from pathlib import Path
import re
import time

from cmux import cmux


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def mounts(log):
    return [
        (selected, ids.split(",") if ids else [])
        for selected, ids in re.findall(
            r"ws\.mount\.reconcile[^\n]*selected=(\w+)[^\n]*mounted=\[([^\]]*)\]", log
        )
    ]


def main():
    socket_path = os.environ.get("C11_SOCKET_PATH") or os.environ.get("C11_SOCKET")
    log_path = os.environ.get("C11_MOUNT_LOG")
    require(socket_path and log_path, "Set explicit sandbox socket and tagged app debug log")
    path = Path(log_path)
    offset = path.stat().st_size

    def events():
        with path.open("rb") as handle:
            handle.seek(offset)
            return handle.read().decode("utf-8", errors="replace")

    def check_mounts(limit):
        samples = mounts(events())
        require(samples, "No real mount events captured")
        for selected, ids in samples:
            require(len(ids) <= limit, f"Mount cap exceeded: {selected=} {ids=}")
            require(selected == "nil" or selected in ids, f"Selected workspace unmounted: {selected=} {ids=}")
        return samples

    count = 60
    created = []
    with cmux(socket_path) as client:
        original = client._call("workspace.current")["workspace_id"]
        original_tab = client._call("panel.current", {"workspace_id": original})
        try:
            started = time.monotonic()
            for _ in range(count):
                created.append(client._call("workspace.create", {"focus": False})["workspace_id"])
            listed = {row[1] for row in client.list_workspaces()}
            require(set(created) <= listed, "Creation requests were dropped")
            check_mounts(2)
            require(client._call("workspace.current")["workspace_id"] == original, "Creation stole selection")

            # Demand an actually unmounted later member, even if priming has
            # already progressed while the socket created the batch.
            mounted = set(check_mounts(2)[-1][1])
            target = next(ws for ws in reversed(created) if ws[:5].upper() not in mounted)
            tabs = client._call("panel.list", {"workspace_id": target})["panels"]
            tab = tabs[0]["id"]
            params = {"workspace_id": target, "panel_id": tab}
            client._call("panel.read_text", params)  # C11-296: read before send.
            client._call("panel.send_text", {**params, "text": "printf 'MOUNT_CAP_%s\\n' 'HEADLESS'"})
            deadline = time.monotonic() + 5
            while "MOUNT_CAP_HEADLESS" not in client._call("panel.read_text", params)["text"]:
                require(time.monotonic() < deadline, "Unmounted sibling did not execute command")
                time.sleep(0.05)
            require(client._call("workspace.current")["workspace_id"] == original, "Headless demand stole selection")
            require(client._call("panel.current", {"workspace_id": original}) == original_tab, "Headless demand changed focused tab")

            # Every finite queue member must finish, including a startup timeout.
            prefixes = {ws[:5].upper() for ws in created}
            deadline = time.monotonic() + count * 2 + 15
            while True:
                log = events()
                finished = set(re.findall(r"workspace\.backgroundPrime\.finish workspace=(\w+)", log))
                samples = check_mounts(2)
                if prefixes <= finished and len(samples[-1][1]) == 1:
                    break
                require(time.monotonic() < deadline, "Background queue stalled or did not settle to one body")
                time.sleep(0.1)
            print(f"{count} requests retained and primed; settled in {time.monotonic() - started:.3f}s")

            for ws in (created[0], created[count // 2], created[-1], original):
                client._call("workspace.select", {"workspace_id": ws})
                require(client._call("workspace.current")["workspace_id"] == ws, "Switch selected wrong workspace")
                time.sleep(0.3)
            deadline = time.monotonic() + 5
            while True:
                samples = check_mounts(3)  # selected + real retiring + one background
                if samples[-1] == (original[:5].upper(), [original[:5].upper()]):
                    break
                require(time.monotonic() < deadline, "Handoff did not settle to selected workspace")
                time.sleep(0.1)
            require(set(created) <= {row[1] for row in client.list_workspaces()}, "Priming removed workspace models")
        finally:
            client._call("workspace.select", {"workspace_id": original})
            for ws in reversed(created):
                client.close_workspace(ws)
    print("PASS: bounded real mounts, all requests retained, headless read/send, switch settlement")


if __name__ == "__main__":
    main()
