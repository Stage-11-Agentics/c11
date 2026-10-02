#!/usr/bin/env python3
"""B006: pending state-save JavaScript must leave main-actor socket reads usable.

Run only via scripts/sandbox-tests-v2.sh in an isolated guest.
"""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cmux import cmux


def main():
    socket_path = os.environ["C11_SOCKET_PATH"]
    started = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/started":
                started.set()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<!doctype html><title>B006 fixture</title><p>ready</p>")

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    workspace_id = None
    try:
        with cmux(socket_path) as client, tempfile.TemporaryDirectory(prefix="c11-b006-") as directory:
            workspace_id = client.new_workspace()
            target = client._call("browser.open_split", {
                "workspace_id": workspace_id,
                "url": f"http://127.0.0.1:{server.server_port}/",
            })
            params = {"workspace_id": workspace_id, "tab_id": target["tab_id"]}
            client._call("browser.wait", {**params, "function": "document.readyState === 'complete'", "timeout_ms": 5000})
            client._call("browser.cookies.set", {**params, "name": "fixture", "value": "saved", "path": "/"})
            cookies = client._call("browser.cookies.get", {**params, "name": "fixture"})["cookies"]
            assert any(cookie["value"] == "saved" for cookie in cookies), cookies
            client._call("browser.eval", {**params, "script": """
                localStorage.clear(); sessionStorage.clear();
                localStorage.setItem('fixture-local', 'local');
                sessionStorage.setItem('fixture-session', 'session');
                const originalKey = Storage.prototype.key;
                Storage.prototype.key = function(...args) {
                    if (!window.fixtureSaveStarted) {
                        window.fixtureSaveStarted = true;
                        fetch('/started');
                        const until = Date.now() + 2000;
                        while (Date.now() < until) {}
                    }
                    return originalKey.apply(this, args);
                };
                true;
            """})
            output = Path(directory) / "state.json"
            result = {}

            def save():
                try:
                    with cmux(socket_path) as saver:
                        result["response"] = saver._call("browser.state.save", {**params, "path": str(output)})
                except Exception as error:
                    result["error"] = error

            worker = threading.Thread(target=save, daemon=True)
            worker.start()
            assert started.wait(5), "state-save storage read never started"
            assert worker.is_alive(), "fixture did not hold the pending save"
            before = time.monotonic()
            client._call("workspace.list", timeout_s=4)
            elapsed = time.monotonic() - before
            worker.join(15)
            assert not worker.is_alive(), "state save did not complete"
            if "error" in result:
                raise result["error"]
            assert elapsed < 1.0, f"pending save held main for {elapsed:.3f}s"
            saved = json.loads(output.read_text())
            assert saved["storage"]["local"]["fixture-local"] == "local", saved
            assert saved["storage"]["session"]["fixture-session"] == "session", saved
            assert any(cookie["name"] == "fixture" and cookie["value"] == "saved" for cookie in saved["cookies"]), saved
            print(f"PASS: main-actor read completed in {elapsed:.3f}s during pending state save")
    finally:
        if workspace_id:
            with cmux(socket_path) as client:
                client.close_workspace(workspace_id)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
