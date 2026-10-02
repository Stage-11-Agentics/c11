#!/usr/bin/env python3
"""B006: pending state-save/snapshot waits leave main-actor socket reads usable.

Run only via scripts/sandbox-tests-v2.sh in an isolated guest.
"""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cmux import cmux, cmuxError


def main():
    socket_path = os.environ["C11_SOCKET_PATH"]
    started = threading.Event()
    snapshot_started = threading.Event()
    timeout_started = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/started":
                started.set()
            elif self.path == "/snapshot-started":
                snapshot_started.set()
            elif self.path == "/timeout-started":
                timeout_started.set()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<!doctype html><title>B006 fixture</title><button>ready</button>")

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

            def delay_snapshot(milliseconds, signal_path):
                client._call("browser.eval", {**params, "script": f"""
                    window.fixtureOriginalStyle = window.fixtureOriginalStyle || window.getComputedStyle;
                    let started = false;
                    window.getComputedStyle = function(...args) {{
                        if (!started) {{
                            started = true;
                            fetch({json.dumps(signal_path)});
                            const until = Date.now() + {milliseconds};
                            while (Date.now() < until) {{}}
                        }}
                        return window.fixtureOriginalStyle.apply(this, args);
                    }};
                    true;
                """})

            def snapshot_while_querying(signal):
                outcome = {}

                def capture():
                    try:
                        with cmux(socket_path) as reader:
                            outcome["response"] = reader._call("browser.snapshot", params, timeout_s=40)
                    except Exception as error:
                        outcome["error"] = error

                capture_thread = threading.Thread(target=capture, daemon=True)
                capture_thread.start()
                assert signal.wait(5), "snapshot evaluation never started"
                assert capture_thread.is_alive(), "fixture did not hold the pending snapshot"
                before = time.monotonic()
                client._call("workspace.list", timeout_s=4)
                elapsed = time.monotonic() - before
                capture_thread.join(35)
                assert not capture_thread.is_alive(), "snapshot did not return a finite result"
                assert elapsed < 1.0, f"pending snapshot held main for {elapsed:.3f}s"
                return outcome, elapsed

            delay_snapshot(2000, "/snapshot-started")
            captured, elapsed = snapshot_while_querying(snapshot_started)
            if "error" in captured:
                raise captured["error"]
            assert captured["response"]["page"]["title"] == "B006 fixture", captured
            assert "ready" in captured["response"]["snapshot"], captured
            print(f"PASS: main query in {elapsed:.3f}s; slow snapshot callback/result delivered")

            # Snapshot retries in an isolated JS world after the page-world
            # attempt times out: hold the process beyond both finite attempts.
            delay_snapshot(25000, "/timeout-started")
            timed_out, elapsed = snapshot_while_querying(timeout_started)
            error = timed_out.get("error")
            assert isinstance(error, cmuxError), timed_out
            assert str(error).startswith("js_error:") and "timed out" in str(error).lower(), error
            before = time.monotonic()
            client._call("workspace.list", timeout_s=4)
            assert time.monotonic() - before < 1.0, "socket did not recover after snapshot timeout"
            client._call("browser.eval", {**params, "script": "window.getComputedStyle = window.fixtureOriginalStyle; true;"}, timeout_s=20)
            recovered = client._call("browser.snapshot", params)
            assert "ready" in recovered["snapshot"], recovered
            print(f"PASS: finite snapshot error; main query in {elapsed:.3f}s and subsequent snapshot recovered")
    finally:
        if workspace_id:
            with cmux(socket_path) as client:
                client.close_workspace(workspace_id)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
