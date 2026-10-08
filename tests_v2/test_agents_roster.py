#!/usr/bin/env python3
"""C11-231 journal roster through the packaged CLI and agents.list.

Synthetic structural hooks only. This deliberately skips an EventLog interval
between a committed lifecycle change and the next roster read, then checks
snapshot recovery for phase, source, freshness, connection, and health. The
command does not launch, resume, or focus an agent.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from cmux import cmux, cmuxError
from test_claude_attention_batch import eventually


FOCUS_KEYS = ("window_id", "workspace_id", "area_id", "panel_id")


def main():
    path, cli = os.environ["C11_SOCKET_PATH"], os.environ["C11_CLI"]
    assert "sandbox" in path or "c11-sb-" in path, "Use sandbox-tests-v2.sh"
    app = next(parent for parent in Path(cli).resolve().parents if parent.suffix == ".app")
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle == "com.stage11.c11":
        raise SystemExit("refusing the production bundle id")
    with cmux(path) as client, tempfile.TemporaryDirectory(prefix="c11-agents-") as temporary:
        def session_ready():
            try:
                client._call("workspace.list", timeout_s=2)
            except cmuxError as error:
                if str(error).startswith("not_ready:"):
                    return False
                raise
            return True

        eventually(session_ready, "session restoration readiness", timeout=30)
        workspace = client.new_workspace()
        surfaces = [client.list_surfaces(workspace)[0][1]]
        for _ in range(4):
            surfaces.append(client._call("panel.create", {"workspace_id": workspace, "type": "terminal"})["panel_id"])
        blocked, working, historical, ended, unknown = surfaces
        sessions = {tab: str(uuid.uuid4()) for tab in surfaces}
        before = focus_ids(client.identify())

        # Journal ownership is exact ConversationStore state. Establish that
        # identity through the packaged socket before exercising hook folds;
        # SessionStart remains in the trace as the provider lifecycle event.
        for tab in surfaces:
            client._call("conversation.push", {
                "tab_id": tab, "kind": "claude-code", "id": sessions[tab], "source": "hook"
            })

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
                "native_event": signal,
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
            matches = [item for item in document["panels"] if str(item["panel_id"]).lower() == tab.lower()]
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

        # Deliberately drop this observer's event-stream interval: append a
        # committed AskUserQuestion transition without tailing/reading events,
        # then recover only through the fresh agents snapshot.
        focus_before_gap = focus_ids(client.identify())
        hook(working, "pre-tool-use", {
            "prompt_id": "working-turn",
            "tool_name": "AskUserQuestion",
            "tool_use_id": "synthetic-dropped-interval-ask",
        })

        def recovered_snapshot():
            document = roster()
            current = row(document, working)
            if current["state"] == "blocked" and current["reason"] == "question":
                return document, current
            return None

        eventually(recovered_snapshot, "fresh roster snapshot recovers the deliberately skipped event interval", timeout=8)
        recovered = roster()
        recovered_row = row(recovered, working)
        assert recovered_row["source"] == "hook"
        assert recovered_row["freshness"] == "fresh"
        assert recovered_row["confirmation"] == "confirmed"
        assert recovered_row["health"] == "ok"
        control(working, sessions[working], "adapter_gap")

        def degraded_snapshot():
            document = roster()
            current = row(document, working)
            return (document, current) if current["health"] == "degraded" else None

        eventually(degraded_snapshot, "fresh roster snapshot retains known state through an adapter gap", timeout=8)
        degraded = roster()
        degraded_row = row(degraded, working)
        assert degraded_row["state"] == "blocked"
        assert degraded_row["reason"] == "question"
        assert degraded_row["source"] == "hook"
        assert degraded_row["freshness"] == "fresh"
        assert degraded_row["connection"] == "live"
        control(working, sessions[working], "adapter_recovered")
        eventually(lambda: row(roster(), working)["health"] == "ok", "adapter recovery returns health to ok", timeout=8)
        assert focus_ids(client.identify()) == focus_before_gap
        print("PASS skipped event-stream interval, degraded-source snapshot recovery, and unchanged focus")

        def candidate(document, tab):
            matches = [item for item in document["restore_candidates"] if str(item["panel_id"]).lower() == tab.lower()]
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
