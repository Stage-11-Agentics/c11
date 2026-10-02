#!/usr/bin/env python3
"""C11-264 feed list/watch on an isolated guest. Do not point this at the operator socket.

Synthetic structural append plus a display note. The prompt stays in the live
list JSON and out of the event log. Live resume traces wait for later producers.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from cmux import cmux
from test_claude_attention_batch import eventually


SENTINEL = "PRIVATE-SENTINEL-264"


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


def cli_json(cli, path, args):
    result = subprocess.run([cli, "--socket", path, *args], text=True, capture_output=True, timeout=15)
    return result


def main():
    path, cli = require_guest()
    with cmux(path) as client:
        features = client.capabilities()["features"]
        assert any(item.get("id") == "feed.asks" and item.get("version") == 1 for item in features), features
        window = client.new_window()
        try:
            ask_workspace = client.new_workspace(window)
            other_workspace = client.new_workspace(window)
            ask_tab = client.list_surfaces(ask_workspace)[0][1]
            other_tab = client.list_surfaces(other_workspace)[0][1]
            session = str(uuid.uuid4())
            client._call("conversation.push", {
                "tab_id": ask_tab, "kind": "claude-code", "id": session, "source": "hook", "state": "alive",
            })
            client._call("flag.raise", {
                "surface_id": ask_tab, "reason": "synthetic-flag", "by": "operator",
            })
            draft = {
                "schema_version": 1, "event_id": str(uuid.uuid4()), "kind": "agent.question.requested",
                "emitted_at_ms": int(time.time() * 1000), "tab_id": ask_tab, "workspace_id": ask_workspace,
                "session_id": session, "agent_kind": "claude-code", "source": "hook", "adapter": "claude_hook",
                "native_event": "PreToolUse", "request_id": "synthetic-ask",
            }
            receipt = client._call("agent.event.append", {"event": draft})

            def blocked():
                journal = client._call("tab.get_metadata", {"tab_id": ask_tab})["metadata"]["journal"]
                return journal.get("phase") == "blocked" and journal.get("reason") == "question"
            eventually(blocked, "question projection")
            noted = client._call("feed.note_display", {
                "workspace_id": ask_workspace, "tab_id": ask_tab, "agent_kind": "claude-code",
                "session_id": session, "event_id": receipt["event_id"], "request_id": "synthetic-ask",
                "prompt": SENTINEL,
            })
            assert noted.get("accepted") is True, noted

            def listed():
                payload = client._call("feed.list", {"scope": "attention"})
                rows = [row for row in payload.get("rows") or [] if row.get("tab_id") == ask_tab]
                return payload if rows and rows[0].get("prompt") == SENTINEL and rows[0].get("flag") else None
            payload = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and payload is None:
                payload = listed()
                if payload is None:
                    time.sleep(0.05)
            assert payload is not None, "feed list did not show the flagged question"
            row = next(row for row in payload["rows"] if row["tab_id"] == ask_tab)
            assert row["kind"] == "question" and row["state"] == "open"
            assert row["workspace_id"] == ask_workspace
            assert all(other.get("tab_id") != other_tab or other.get("kind") is not None for other in payload["rows"])

            listed_cli = cli_json(cli, path, ["feed", "list", "--json"])
            assert listed_cli.returncode == 0, listed_cli.stderr
            body = json.loads(listed_cli.stdout)
            assert any(item.get("tab_id") == ask_tab and item.get("prompt") == SENTINEL for item in body["rows"])
            before = client.identify().get("focused")
            again = cli_json(cli, path, ["feed", "list", "--json"])
            assert again.returncode == 0
            assert client.identify().get("focused") == before, "feed list moved focus"

            instance = body.get("instance")
            if isinstance(instance, str) and instance:
                log = Path.home() / "Library/Application Support/c11/events" / f"events-{instance}.ndjson"
                if log.is_file():
                    text = log.read_text(errors="replace")
                    assert SENTINEL not in text, "prompt reached the event log"
                    assert "ask.opened" in text

            watch = subprocess.Popen(
                [cli, "--socket", path, "feed", "watch", "--json"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            try:
                line = watch.stdout.readline() if watch.stdout else ""
            finally:
                watch.kill()
                watch.wait(timeout=5)
            watched = json.loads(line)
            assert any(item.get("tab_id") == ask_tab for item in watched.get("rows") or [])
            assert client.identify().get("focused") == before, "feed watch moved focus"
            print("PASS feed list and watch show the flagged question without moving focus")
        finally:
            client.close_window(window)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
