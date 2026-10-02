#!/usr/bin/env python3
"""C11-264 feed open on an isolated guest. Focus stays inside c11 and sends no answer.

Unknown workspace or tab returns unavailable and leaves the focused tab alone.
"""
import json
import os
import subprocess
import uuid

from cmux import cmux


def require_guest():
    path = os.environ.get("C11_SOCKET_PATH") or os.environ.get("C11_SOCKET")
    cli = os.environ.get("C11_CLI")
    if not path or not cli:
        raise SystemExit("Set C11_SOCKET_PATH and C11_CLI to an isolated guest")
    if path.endswith("Application Support/c11/c11.sock"):
        raise SystemExit("Refusing the operator socket")
    if "sandbox" not in path and "c11-sb-" not in path:
        raise SystemExit("Refusing a socket outside the sandbox guest")
    return path, cli


def focused_tab(client):
    focused = client.identify().get("focused") or {}
    return focused.get("workspace_id"), focused.get("tab_id") or focused.get("surface_id")


def main():
    path, cli = require_guest()
    with cmux(path) as client:
        window = client.new_window()
        try:
            ask_workspace = client.new_workspace(window)
            other_workspace = client.new_workspace(window)
            ask_tab = client.list_surfaces(ask_workspace)[0][1]
            other_tab = client.list_surfaces(other_workspace)[0][1]
            client.focus_surface(other_tab)
            client.select_workspace(other_workspace)
            assert focused_tab(client) == (other_workspace, other_tab)

            opened = subprocess.run(
                [cli, "--socket", path, "feed", "open", ask_tab, "--workspace", ask_workspace, "--json"],
                text=True, capture_output=True, timeout=15,
            )
            assert opened.returncode == 0, opened.stderr
            payload = json.loads(opened.stdout)
            assert payload["workspace_id"] == ask_workspace and payload["tab_id"] == ask_tab
            assert focused_tab(client) == (ask_workspace, ask_tab)
            assert focused_tab(client)[0] != other_workspace

            unknown = str(uuid.uuid4())
            missed = subprocess.run(
                [cli, "--socket", path, "feed", "open", unknown, "--workspace", ask_workspace],
                text=True, capture_output=True, timeout=15,
            )
            assert missed.returncode != 0
            assert "unavailable" in (missed.stdout + missed.stderr)
            assert focused_tab(client) == (ask_workspace, ask_tab)

            missing_workspace = subprocess.run(
                [cli, "--socket", path, "feed", "open", ask_tab, "--workspace", unknown],
                text=True, capture_output=True, timeout=15,
            )
            assert missing_workspace.returncode != 0
            assert "unavailable" in (missing_workspace.stdout + missing_workspace.stderr)
            assert focused_tab(client) == (ask_workspace, ask_tab)
            print("PASS feed open focuses the named tab and leaves an unknown target unchanged")
        finally:
            client.close_window(window)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
