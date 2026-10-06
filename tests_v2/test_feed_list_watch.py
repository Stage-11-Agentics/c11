#!/usr/bin/env python3
"""C11-264 feed list/watch on an isolated guest. Do not point this at the operator socket.

Synthetic structural append plus a display note. The prompt stays in the live
list JSON and out of the event log. Live resume traces wait for later producers.
"""
import json
import os
from pathlib import Path
import subprocess
import queue
import threading
import time
import uuid

from cmux import cmux, cmuxError
from test_claude_attention_batch import eventually


SENTINEL = "PRIVATE-SENTINEL-264"


def wait_guest_ready(client):
    deadline = time.monotonic() + 15
    while True:
        try:
            client._call("feed.list")
            return
        except cmuxError as error:
            if not str(error).startswith("not_ready:") or time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


class FeedWatcher:
    def __init__(self, cli, path, extra=()):
        self.process = subprocess.Popen([cli, "--socket", path, *extra, "feed", "watch", "--json", "--scope", "all"],
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.lines.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def until(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.lines.get(timeout=min(0.5, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                assert self.process.poll() is None, "feed watch exited"
                continue
            if predicate(value):
                return value
        raise AssertionError("feed watch did not produce the expected update")

    def close(self):
        self.process.kill()
        self.process.wait(timeout=5)
        self.reader.join(timeout=2)


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
        wait_guest_ready(client)
        features = client.capabilities()["features"]
        assert any(item.get("id") == "feed.asks" and item.get("version") == 1 for item in features), features
        window = client.new_window()
        try:
            ask_workspace = client.new_workspace(window)
            other_workspace = client.new_workspace(window)
            ask_tab = client.list_surfaces(ask_workspace)[0][1]
            client._call("panel.create", {"workspace_id": ask_workspace, "type": "terminal", "focus": False})
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
                journal = client._call("panel.get_metadata", {"panel_id": ask_tab})["metadata"]["journal"]
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
                rows = [row for row in payload.get("rows") or [] if row.get("panel_id") == ask_tab]
                return payload if rows and rows[0].get("prompt") == SENTINEL and rows[0].get("flag") else None
            payload = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and payload is None:
                payload = listed()
                if payload is None:
                    time.sleep(0.05)
            assert payload is not None, "feed list did not show the flagged question"
            row = next(row for row in payload["rows"] if row["panel_id"] == ask_tab)
            assert row["kind"] == "question" and row["state"] == "open"
            assert row["workspace_id"] == ask_workspace
            assert all(other.get("panel_id") != other_tab or other.get("kind") is not None for other in payload["rows"])

            listed_cli = cli_json(cli, path, ["feed", "list", "--json"])
            assert listed_cli.returncode == 0, listed_cli.stderr
            body = json.loads(listed_cli.stdout)
            assert any(item.get("panel_id") == ask_tab and item.get("prompt") == SENTINEL for item in body["rows"])
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

            watch = FeedWatcher(cli, path)
            try:
                watched = watch.until(lambda value: any(item.get("panel_id") == ask_tab for item in value.get("rows", [])))
                client._call("flag.lower", {"surface_id": ask_tab, "by": "operator"})
                client._call("flag.suppress", {"surface_id": ask_tab, "by": "operator"})
                watch.until(lambda value: "rows" in value and not any(item.get("panel_id") == ask_tab for item in value["rows"]))
                client._call("flag.unsuppress", {"surface_id": ask_tab, "by": "operator"})
                watch.until(lambda value: any(item.get("panel_id") == ask_tab and item.get("kind") == "question" for item in value.get("rows", [])))
                client._call("agent.event.append", {"event": {**draft, "event_id": str(uuid.uuid4()),
                    "kind": "agent.state.changed", "signal": "tool_activity", "native_event": "PreToolUse"}})
                client._call("notification.create_for_panel", {"workspace_id": ask_workspace, "panel_id": ask_tab,
                    "title": "Synthetic telemetry", "body": "Unrelated update"})
                assert any(item.get("panel_id") == ask_tab for item in client._call("feed.list")["rows"])
                client._call("agent.event.append", {"event": {**draft, "event_id": str(uuid.uuid4()),
                    "kind": "agent.attention.resolved", "resolution": "resumed", "native_event": "PostToolUse"}})
                watch.until(lambda value: "rows" in value and not any(item.get("panel_id") == ask_tab for item in value["rows"]))
                assert client.identify().get("focused") == before, "feed watch lifecycle updates moved focus"
                client._call("flag.raise", {"surface_id": ask_tab, "reason": "closure", "by": "operator"})
                watch.until(lambda value: any(item.get("panel_id") == ask_tab and item.get("flag") for item in value.get("rows", [])))
                client._call("panel.close", {"workspace_id": ask_workspace, "panel_id": ask_tab})
                watch.until(lambda value: "rows" in value and not any(item.get("panel_id") == ask_tab for item in value["rows"]))
                client._call("flag.raise", {"surface_id": other_tab, "reason": "workspace-closure", "by": "operator"})
                watch.until(lambda value: any(item.get("panel_id") == other_tab for item in value.get("rows", [])))
                client.close_workspace(other_workspace)
                watch.until(lambda value: "rows" in value and not any(item.get("panel_id") == other_tab for item in value["rows"]))
            finally:
                watch.close()
            assert any(item.get("panel_id") == ask_tab for item in watched.get("rows") or [])
            print("PASS live watch covers suppression, resolution, flagged tab/workspace closure")
        finally:
            client.close_window(window)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
