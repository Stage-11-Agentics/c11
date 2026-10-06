#!/usr/bin/env python3
"""Built watcher reauthenticates at the selected socket and retains all scope."""
import json
import socketserver
import tempfile
import threading
from pathlib import Path

from test_feed_list_watch import FeedWatcher, require_guest


def main():
    _, cli = require_guest()
    connections = []
    with tempfile.TemporaryDirectory(prefix="c11-feed-auth-", dir="/tmp") as temporary:
        address = str(Path(temporary) / "peer.sock")
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                generation = len(connections)
                connection = {"auth": False, "scopes": []}
                connections.append(connection)
                feeds = 0
                for raw in self.rfile:
                    line = raw.decode().strip()
                    if line.startswith("auth "):
                        connection["auth"] = line == "auth synthetic-watch-password"
                        response = "OK" if connection["auth"] else "ERROR: Access denied"
                    else:
                        assert connection["auth"], "reconnected client omitted authentication"
                        request = json.loads(line)
                        if request["method"] == "system.capabilities":
                            result = {"methods": ["panel.list", "feed.list"],
                                      "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
                        else:
                            assert request["method"] == "feed.list", request
                            connection["scopes"].append(request["params"]["scope"])
                            feeds += 1
                            if generation == 0 and feeds >= 3:
                                return
                            result = {"instance": f"synthetic-instance-{generation}", "scope": request["params"]["scope"], "rows": []}
                        response = json.dumps({"ok": True, "result": result})
                    self.wfile.write((response + "\n").encode())
                    self.wfile.flush()
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        watcher = FeedWatcher(cli, address, extra=("--password", "synthetic-watch-password"))
        try:
            watcher.until(lambda value: value.get("instance") == "synthetic-instance-0")
            watcher.until(lambda value: value.get("continuity") == "unavailable")
            watcher.until(lambda value: value.get("instance") == "synthetic-instance-1")
            assert len(connections) >= 2 and all(c["auth"] for c in connections)
            assert all(scope == "all" for c in connections for scope in c["scopes"])
            print("PASS transport reconnect preserves selected socket, authentication and scope")
        finally:
            watcher.close()
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)


if __name__ == "__main__":
    main()
