#!/usr/bin/env python3
"""Keep a real packaged watcher alive through a guest app restart with old log retained."""
import json
import os
from pathlib import Path
import subprocess
import re
import time
import uuid

from cmux import cmux
from test_feed_list_watch import FeedWatcher, require_guest


def rss(pid):
    return int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(pid)], text=True).strip())


def main():
    path, cli = require_guest()
    app = Path(cli).parents[3]
    assert app.name == "c11 DEV c11-264.app", app
    watcher = FeedWatcher(cli, path)
    client = cmux(path)
    client.connect()
    try:
        initial = watcher.until(lambda value: "rows" in value)
        old_instance = initial["instance"]
        assert old_instance, "restart proof requires recording enabled"
        old_log = Path.home() / "Library/Application Support/c11/events" / f"events-{old_instance}.ndjson"
        assert old_log.is_file(), old_log
        client.close()
        pids = subprocess.check_output(["/usr/bin/pgrep", "-f", re.escape(str(app / "Contents/MacOS/c11")) + "$"], text=True).split()
        assert len(pids) == 1, pids
        subprocess.run(["/bin/kill", pids[0]], check=True)
        watcher.until(lambda value: value.get("continuity") == "unavailable")
        # Same selected socket, clean QA launch, same console user and packaged binary.
        user = subprocess.check_output(["/usr/bin/id", "-un"], text=True).strip()
        uid = str(os.getuid())
        subprocess.run(["/usr/bin/sudo", "-n", "/bin/launchctl", "asuser", uid,
                        "/usr/bin/sudo", "-n", "-u", user, "/usr/bin/env", "-i",
                        f"HOME={Path.home()}", f"USER={user}", f"LOGNAME={user}",
                        "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "C11_SOCKET_MODE=automation",
                        "C11_ALLOW_SOCKET_OVERRIDE=1", f"C11_SOCKET_PATH={path}", f"C11_SOCKET={path}",
                        "C11_QA_LAUNCH=fresh", "/bin/zsh", "-c",
                        'nohup "$1" > /tmp/c11-feed-restart.stdout 2>&1 &', "_", str(app / "Contents/MacOS/c11")], check=True)
        recovered = watcher.until(lambda value: "rows" in value and value.get("instance") != old_instance, timeout=30)
        assert recovered["scope"] == "all", recovered
        assert old_log.is_file(), "old log was removed during restart"
        client.connect()
        workspace = client.new_workspace()
        tab = client.list_surfaces(workspace)[0][1]
        try:
            session = str(uuid.uuid4())
            client._call("conversation.push", {"tab_id": tab, "kind": "claude-code", "id": session, "source": "hook", "state": "alive"})
            draft = {"schema_version": 1, "event_id": str(uuid.uuid4()), "kind": "agent.turn.started",
                     "emitted_at_ms": int(time.time() * 1000), "workspace_id": workspace, "tab_id": tab,
                     "session_id": session, "agent_kind": "claude-code", "source": "hook", "adapter": "claude_hook",
                     "native_event": "UserPromptSubmit", "turn_id": "restart-turn"}
            client._call("agent.event.append", {"event": draft})
            client._call("agent.event.append", {"event": {**draft, "event_id": str(uuid.uuid4()),
                "kind": "agent.turn.completed", "native_event": "Stop"}})
            watcher.until(lambda value: any(row.get("tab_id") == tab and row.get("kind") == "turn_end" for row in value.get("rows", [])))
            # Bounded Foundation churn: repeatedly refresh changed rows/event logs
            # after warming the watcher. RSS is observed on the actual CLI process.
            time.sleep(2)
            before = rss(watcher.process.pid)
            for index in range(60):
                client._call("flag.raise", {"surface_id": tab, "reason": f"memory-{index}", "by": "operator"})
                watcher.until(lambda value: any(row.get("tab_id") == tab and (row.get("flag") or {}).get("reason") == f"memory-{index}" for row in value.get("rows", [])))
                client._call("flag.lower", {"surface_id": tab, "by": "operator"})
                watcher.until(lambda value: any(row.get("tab_id") == tab and not row.get("flag") for row in value.get("rows", [])))
            after = rss(watcher.process.pid)
            assert after - before < 24 * 1024, (before, after)
            print(f"PASS actual restart recovered instance and all-scope turn_end with old log retained; watch RSS {before}->{after} KiB across 120 changes")
        finally:
            client.close_workspace(workspace)
    finally:
        watcher.close()
        client.close()


if __name__ == "__main__":
    main()
