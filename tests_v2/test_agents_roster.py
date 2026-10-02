#!/usr/bin/env python3
"""C11-231 journal roster through the packaged CLI and agents.list.

Synthetic structural hooks only. The roster read does not reconstruct an
EventLog, so saturating that log is not part of this check: phase, source,
freshness, connection, and health come back from the journal. The command
does not launch, resume, or focus an agent.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from cmux import cmux
from test_claude_attention_batch import eventually


FOCUS_KEYS = ("window_id", "workspace_id", "pane_id", "surface_id", "tab_id")


def main():
    path, cli = os.environ["C11_SOCKET_PATH"], os.environ["C11_CLI"]
    assert "sandbox" in path or "c11-sb-" in path, "Use sandbox-tests-v2.sh"
    app = next(parent for parent in Path(cli).resolve().parents if parent.suffix == ".app")
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle == "com.stage11.c11":
        raise SystemExit("refusing the production bundle id")
    with cmux(path) as client, tempfile.TemporaryDirectory(prefix="c11-agents-") as temporary:
        workspace = client.new_workspace()
        surfaces = [client.list_surfaces(workspace)[0][1]]
        for _ in range(4):
            surfaces.append(client._call("tab.create", {"workspace_id": workspace, "type": "terminal"})["tab_id"])
        blocked, working, historical, ended, unknown = surfaces
        sessions = {tab: str(uuid.uuid4()) for tab in surfaces}
        before = focus_ids(client.identify())

        def hook(tab, event, fields=None):
            env = {key: value for key, value in os.environ.items() if not key.startswith(("C11_", "CMUX_"))}
            env.update(
                CMUX_WORKSPACE_ID=workspace,
                CMUX_SURFACE_ID=tab,
                CMUX_BUNDLE_ID=bundle,
                CMUX_CLAUDE_HOOK_STATE_PATH=str(Path(temporary) / sessions[tab]),
            )
            payload = {"session_id": sessions[tab], **(fields or {})}
            result = subprocess.run(
                [cli, "--socket", path, "claude-hook", event],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError("claude-hook failed")

        def control(tab, session, signal):
            event = {
                "schema_version": 1,
                "event_id": str(uuid.uuid4()),
                "kind": "agent.state.changed",
                "emitted_at_ms": int(time.time() * 1000),
                "tab_id": tab,
                "workspace_id": workspace,
                "session_id": session,
                "agent_kind": "claude-code",
                "source": "c11",
                "adapter": "c11",
                "native_event": "connection_lost",
                "signal": signal,
            }
            client._call("agent.event.append", {"event": event})

        hook(blocked, "session-start")
        hook(blocked, "prompt-submit", {"prompt_id": "blocked-turn"})
        hook(blocked, "pre-tool-use", {
            "prompt_id": "blocked-turn",
            "tool_name": "AskUserQuestion",
            "tool_use_id": "synthetic-ask",
        })
        hook(working, "session-start")
        hook(working, "prompt-submit", {"prompt_id": "working-turn"})
        hook(historical, "session-start")
        control(historical, sessions[historical], "connection_lost")
        hook(ended, "session-start")
        hook(ended, "session-end")
        control(ended, sessions[ended], "connection_lost")
        # Push the session start out of the retained window. The candidate stays
        # unknown because the start is no longer in the read, and coverage is pruned.
        hook(unknown, "session-start")
        for _ in range(64):
            control(unknown, sessions[unknown], "connection_lost")

        def roster():
            result = subprocess.run(
                [cli, "--socket", path, "agents", "--json"],
                text=True,
                capture_output=True,
                timeout=15,
            )
            if result.returncode != 0:
                raise AssertionError("agents json failed")
            return json.loads(result.stdout)

        def row(document, tab):
            matches = [item for item in document["tabs"] if str(item["tab_id"]).lower() == tab.lower()]
            if len(matches) != 1:
                raise AssertionError("roster row missing")
            return matches[0]

        def ready():
            document = roster()
            ask = row(document, blocked)
            worker = row(document, working)
            return ask["state"] == "blocked" and ask["reason"] == "question" and worker["state"] == "working"

        eventually(ready, "roster did not show the two synthetic owners", timeout=8)
        document = roster()
        assert document["schema_version"] == 1
        assert document["live_identity"] == "available"
        ask = row(document, blocked)
        worker = row(document, working)
        assert ask["kind"] == "claude-code"
        assert ask["source"] == "hook"
        assert ask["model"] is None
        assert ask["freshness"] in ("fresh", "stale")
        assert ask["confirmation"] == "confirmed"
        assert ask["connection"] == "live"
        assert worker["model"] is None
        assert worker["reason"] is None
        assert worker["source"] == "hook"
        listed = client._call("agents.list")
        assert row(listed, blocked)["state"] == "blocked"
        assert row(listed, working)["state"] == "working"

        def candidate(document, tab):
            matches = [item for item in document["restore_candidates"] if str(item["tab_id"]).lower() == tab.lower()]
            if len(matches) != 1:
                raise AssertionError("restore candidate missing")
            return matches[0]

        def labeled():
            document = roster()
            return (
                candidate(document, historical)["label"] == "historical_candidate"
                and candidate(document, ended)["label"] == "ended"
                and candidate(document, unknown)["label"] == "unknown"
            )

        eventually(labeled, "restore labels were not classified", timeout=8)
        document = roster()
        assert candidate(document, ended)["label"] == "ended"
        assert candidate(document, ended)["agent_kind"] == "claude-code"
        assert candidate(document, ended)["confirmation"] == "unconfirmed"
        assert candidate(document, historical)["connection"] == "disconnected"
        assert candidate(document, historical)["coverage"] == "retained"
        assert candidate(document, unknown)["connection"] == "disconnected"
        assert candidate(document, unknown)["coverage"] == "event_pruned"
        assert "questions" not in json.dumps(document)
        after = focus_ids(client.identify())
        if before != after:
            raise AssertionError("focused tab changed")
        print("PASS synthetic roster, restore labels, and unchanged focus")


def focus_ids(ident):
    focused = ident.get("focused") or {}
    if not isinstance(focused, dict):
        return None
    return tuple(focused.get(key) for key in FOCUS_KEYS)


if __name__ == "__main__":
    main()
