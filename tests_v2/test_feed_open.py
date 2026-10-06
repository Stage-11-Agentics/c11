#!/usr/bin/env python3
"""C11-264 feed open on an isolated guest. Focus stays inside c11 and sends no answer.

Unknown workspace or tab returns unavailable and leaves the focused tab alone.
"""
import json
import os
import subprocess
import uuid

from cmux import cmux
from test_claude_attention_batch import eventually
from test_feed_list_watch import wait_guest_ready


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
    return focused.get("workspace_id"), focused.get("panel_id") or focused.get("tab_id")


def aqua(command):
    user = subprocess.check_output(["/usr/bin/id", "-un"], text=True).strip()
    return ["/usr/bin/sudo", "-n", "/bin/launchctl", "asuser", str(os.getuid()),
            "/usr/bin/sudo", "-n", "-u", user, *command]


def main():
    path, cli = require_guest()
    with cmux(path) as client:
        wait_guest_ready(client)
        window = client.new_window()
        other_window = client.new_window()
        try:
            ask_workspace = client.new_workspace(window)
            other_workspace = client.new_workspace(other_window)
            ask_tab = client.list_surfaces(ask_workspace)[0][1]
            other_tab = client.list_surfaces(other_workspace)[0][1]
            client.focus_surface(other_tab)
            client.select_workspace(other_workspace)
            assert focused_tab(client) == (other_workspace, other_tab)

            # Leave a partial terminal command on the target. Opening Feed must
            # not type an answer, submit it, or activate c11 over Finder.
            client._call("panel.read_text", {"workspace_id": ask_workspace, "panel_id": ask_tab})
            client.send_surface(ask_tab, "SYNTHETIC_UNSUBMITTED_264")
            eventually(lambda: "SYNTHETIC_UNSUBMITTED_264" in client._call("panel.read_text", {"workspace_id": ask_workspace, "panel_id": ask_tab})["text"], "partial input visible")
            before_text = client._call("panel.read_text", {"workspace_id": ask_workspace, "panel_id": ask_tab})["text"]
            artifacts = "/Volumes/My Shared Files/out"
            subprocess.run(aqua(["/usr/sbin/screencapture", "-x", f"{artifacts}/feed-open-before.png"]), check=True)
            subprocess.run(aqua(["/usr/bin/osascript", "-e", 'tell application "Finder" to activate']), check=True)
            def frontmost():
                return subprocess.check_output(aqua(["/usr/bin/osascript", "-e", 'tell application "System Events" to get name of first application process whose frontmost is true']), text=True).strip()
            eventually(lambda: frontmost() == "Finder", "Finder activation settled")

            opened = subprocess.run(
                [cli, "--socket", path, "feed", "open", ask_tab, "--workspace", ask_workspace, "--json"],
                text=True, capture_output=True, timeout=15,
            )
            assert opened.returncode == 0, opened.stderr
            payload = json.loads(opened.stdout)
            assert payload["workspace_id"] == ask_workspace and payload["tab_id"] == ask_tab
            target_tabs = client._call("panel.list", {"workspace_id": ask_workspace, "window_id": window})["panels"]
            assert any(row["id"] == ask_tab and row["focused"] for row in target_tabs), target_tabs
            target_workspaces = client.list_workspaces(window)
            assert any(row[1] == ask_workspace and row[3] for row in target_workspaces)
            assert frontmost() == "Finder", "feed open activated or raised c11"
            subprocess.run(aqua(["/usr/sbin/screencapture", "-x", f"{artifacts}/feed-open-after.png"]), check=True)
            assert client._call("panel.read_text", {"workspace_id": ask_workspace, "panel_id": ask_tab})["text"] == before_text, "feed open sent terminal input"
            unchanged_focus = focused_tab(client)

            unknown = str(uuid.uuid4())
            missed = subprocess.run(
                [cli, "--socket", path, "feed", "open", unknown, "--workspace", ask_workspace],
                text=True, capture_output=True, timeout=15,
            )
            assert missed.returncode != 0
            assert "unavailable" in (missed.stdout + missed.stderr)
            assert focused_tab(client) == unchanged_focus

            missing_workspace = subprocess.run(
                [cli, "--socket", path, "feed", "open", ask_tab, "--workspace", unknown],
                text=True, capture_output=True, timeout=15,
            )
            assert missing_workspace.returncode != 0
            assert "unavailable" in (missing_workspace.stdout + missing_workspace.stderr)
            assert focused_tab(client) == unchanged_focus
            assert frontmost() == "Finder"
            print("PASS cross-window feed open selects the exact target, preserves Finder frontmost and terminal input, and leaves unknown targets unchanged")
        finally:
            client.close_window(window)
            client.close_window(other_window)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
