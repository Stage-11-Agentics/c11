#!/usr/bin/env python3
"""C11-263 hook regression on an explicitly supplied disposable socket.

Run through sandbox-tests-v2.sh. These structural hook payloads exercise the
packaged CLI/store path; they are not captures of native provider emissions.
Incidents: C11-271 sibling wait, bypass ask, and clean SessionEnd.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

from cmux import cmux


def eventually(predicate, label, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(label)


def legacy(path, command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(path)
        connection.sendall((command + "\n").encode())
        response = b""
        while not response.endswith(b"\n"):
            chunk = connection.recv(4096)
            if not chunk:
                break
            response += chunk
        return response.decode().strip()


def main():
    socket_path = os.environ.get("C11_SOCKET_PATH") or os.environ.get("C11_SOCKET")
    cli = os.environ.get("C11_CLI")
    if not socket_path or not cli:
        raise RuntimeError("Set C11_SOCKET_PATH and C11_CLI to an isolated sandbox/tagged app")
    production = Path.home() / "Library/Application Support/c11/c11.sock"
    if Path(socket_path) == production or socket_path == "/tmp/c11-debug.sock":
        raise RuntimeError("Refusing the production/untagged socket")

    with tempfile.TemporaryDirectory(prefix="c11-263-hooks-") as temporary, cmux(socket_path) as client:
        workspace = client.new_workspace()
        try:
            caller = client.list_surfaces(workspace)[0][1]
            sibling = client._call("panel.create", {"workspace_id": workspace, "type": "terminal"})["panel_id"]
            # Only this disposable instance's focus oracle is overridden.
            client.set_app_focus(False)
            baseline = client.identify().get("focused")
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(("C11_", "CMUX_"))}
            environment.update(CMUX_WORKSPACE_ID=workspace,
                               CMUX_SURFACE_ID=caller,
                               CMUX_CLAUDE_HOOK_STATE_PATH=str(Path(temporary) / "sessions.json"))

            def hook(event, payload, env=None):
                result = subprocess.run([cli, "--socket", socket_path, "claude-hook", event],
                                        input=json.dumps(payload), text=True, capture_output=True,
                                        env=env or environment, timeout=10)
                assert result.returncode == 0, f"{event} failed: {result.stderr}"
                return result

            def notices():
                return [item for item in client.list_notifications() if item["workspace_id"] == workspace]

            def unread(tab):
                return [item for item in notices() if item.get("tab_id") == tab and not item["is_read"]]

            def seed():
                for tab in (caller, sibling):
                    client._call("notification.create_for_panel", {
                        "workspace_id": workspace, "tab_id": tab,
                        "title": "Synthetic wait", "body": "Attention fixture"})
                eventually(lambda: len(unread(caller)) == len(unread(sibling)) == 1, "both tabs waiting")
                return unread(sibling)[0]["id"]

            def assert_isolation(sibling_id):
                eventually(lambda: not unread(caller), "caller notice must clear")
                assert len(unread(sibling)) == 1 and unread(sibling)[0]["id"] == sibling_id, "sibling wait changed"
                assert client.identify().get("focused") == baseline, "hook changed selection"

            session = "synthetic-caller-session"
            for event in ("prompt-submit", "pre-tool-use", "session-end"):
                hook("session-start", {"session_id": session})
                sibling_id = seed()
                hook(event, {"session_id": session, "tool_name": "Bash"})
                assert_isolation(sibling_id)
                print(f"PASS: {event} preserves sibling waiting")

            capture = json.loads((Path(__file__).parent / "fixtures" /
                                  "c11-263-native-exit-plan-before.json").read_text())
            native_plan = next(row for row in capture["hooks"]
                               if row.get("hook_event_name") == "PreToolUse" and
                               row.get("tool_name") == "ExitPlanMode")
            for tool, mode in (("AskUserQuestion", "bypassPermissions"),
                               ("ExitPlanMode", "bypassPermissions"),
                               (native_plan["tool_name"], native_plan["permission_mode"])):
                hook("session-start", {"session_id": session})
                sibling_id = seed()
                legacy(socket_path, f"clear_notifications --tab={workspace} --panel={caller}")
                eventually(lambda: not unread(caller), "prepare bypass ask")
                hook("pre-tool-use", {"session_id": session, "permission_mode": mode,
                                      "tool_name": tool, "tool_input": {}})
                eventually(lambda: len(unread(caller)) == 1, f"{tool} must wait without Notification")
                assert unread(sibling)[0]["id"] == sibling_id
                hook("notification", {"session_id": session, "notification_type": "permission_prompt"})
                eventually(lambda: len(unread(caller)) == 1, "follow-up must replace, not duplicate")
                hook("prompt-submit", {"session_id": session})
                assert_isolation(sibling_id)
                print(f"PASS: {tool} in {mode} enters waiting without a Notification hook")

            hook("session-start", {"session_id": session})
            sibling_id = seed()
            legacy(socket_path, f"clear_notifications --tab={workspace} --panel={caller}")
            eventually(lambda: not unread(caller), "prepare normal-mode ask")
            hook("pre-tool-use", {"session_id": session, "permission_mode": "default",
                                  "tool_name": "AskUserQuestion", "tool_input": {}})
            client.list_surfaces(workspace)
            assert not unread(caller), "normal mode must retain its Notification route"
            for _ in range(2):
                hook("notification", {"session_id": session, "notification_type": "permission_prompt"})
                eventually(lambda: len(unread(caller)) == 1, "normal follow-up must have one item")
            assert unread(sibling)[0]["id"] == sibling_id
            print("PASS: normal-mode follow-up retains one attention item")

            # No session mapping and no explicit tab: never guess the focused tab.
            for bad_ref in (None, "", "not-a-tab", str(uuid.uuid4())):
                seed()
                unknown_env = dict(environment)
                if bad_ref is None:
                    unknown_env.pop("CMUX_SURFACE_ID")
                else:
                    unknown_env["CMUX_SURFACE_ID"] = bad_ref
                subprocess.run([cli, "--socket", socket_path, "claude-hook", "prompt-submit"],
                               input=json.dumps({"session_id": "unmapped-session"}), text=True,
                               capture_output=True, env=unknown_env, timeout=10)
                # Drain the main queue through a synchronous query after the hook's queued writes.
                client.list_surfaces(workspace)
                assert len(unread(caller)) == len(unread(sibling)) == 1, "unknown attribution cleared attention"
            print("PASS: absent, empty, invalid and stale tab attribution preserve notices")

            # Stale PID sweep uses the same timer as the product, not a fabricated hook.
            for attributed in (True, False):
                sibling_id = seed()
                process = subprocess.Popen(["/usr/bin/true"])
                process.wait(timeout=5)
                selector = f" --panel={caller}" if attributed else ""
                response = legacy(socket_path, f"set_agent_pid synthetic_stale {process.pid} --tab={workspace}{selector}")
                assert response.startswith("OK"), response
                if attributed:
                    eventually(lambda: not unread(caller), "known stale PID clears caller only", timeout=40)
                    assert_isolation(sibling_id)
                else:
                    time.sleep(31)
                    assert len(unread(caller)) == len(unread(sibling)) == 1, "unknown stale PID cleared notices"
                print(f"PASS: stale PID with attribution={attributed}")
            assert client.identify().get("focused") == baseline
        finally:
            client.set_app_focus(None)
            client.close_workspace(workspace)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
