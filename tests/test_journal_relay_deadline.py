#!/usr/bin/env python3
"""Built CLI hook against a disposable hc document store with its link down."""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

import socket_guard
from fake_server_env import fake_server_env

socket_guard.install()

PANEL = "22222222-2222-4222-8222-222222222222"
WORKSPACE = "11111111-1111-4111-8111-111111111111"


def main():
    cli = os.environ["C11_CLI_BIN"]
    with tempfile.TemporaryDirectory(prefix="c135-", dir="/tmp") as directory:
        root = Path(directory)
        path = root / ".local/share/c11/run/c11-fixture.sock"
        path.parent.mkdir(parents=True)
        docs = {}
        requests = []
        errors = []
        lock = threading.Lock()

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                try:
                    for line in self.rfile:
                        message = json.loads(line)
                        method, params = message["method"], message["params"]
                        response = {"jsonrpc": "2.0", "id": message["id"]}
                        with lock:
                            if method == "hello":
                                result = {"generation": 1}
                            elif method == "doc.get":
                                result = docs.get(params["name"], {"value": None, "version": 0})
                            elif method == "doc.set":
                                previous = docs.get(params["name"], {"version": 0})
                                assert params["version"] == previous["version"], "unexpected CAS conflict"
                                result = {"value": params["value"], "version": previous["version"] + 1}
                                docs[params["name"]] = result
                                if isinstance(params["value"], dict) and params["value"].get("st") == "req":
                                    requests.append(params["value"])
                            else:
                                raise AssertionError(method)
                            response["result"] = result
                        self.wfile.write((json.dumps(response) + "\n").encode())
                        self.wfile.flush()
                except Exception as error:
                    errors.append(repr(error))

        server = socketserver.ThreadingUnixStreamServer(str(path), Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        base = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "C11_", "CMUX_", "HC_"))}
        env = fake_server_env(str(path), base)
        env.update(C11_RELAY_HC_SOCKET=str(path), C11_RELAY_SESSION="c11-fixture",
                   C11_PANEL_ID=PANEL, C11_WORKSPACE_ID=WORKSPACE, HC_TERMINAL_ID="t1",
                   C11_CLAUDE_HOOK_STATE_PATH=str(root / "state.json"),
                   CMUX_CLAUDE_HOOK_STATE_PATH=str(root / "state.json"),
                   CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
                   HOME=str(root), CFFIXED_USER_HOME=str(root))
        try:
            started = time.monotonic()
            result = subprocess.run([cli, "--socket", str(path), "claude-hook", "post-tool-use",
                                     "--workspace", WORKSPACE, "--panel", PANEL],
                                    input=json.dumps({"session_id": "synthetic-relay", "prompt_id": "turn-a",
                                                      "tool_use_id": "tool-a", "tool_name": "Bash"}),
                                    env=env, capture_output=True, text=True, timeout=2)
            elapsed = time.monotonic() - started
            assert result.returncode == 0, result.stderr
            assert not errors, errors
            assert len(requests) == 1, requests
            request = requests[0]
            assert json.loads(request["line"])["method"] == "agent.event.append", request
            assert 100 <= request["timeout_ms"] <= 250, request["timeout_ms"]
            assert elapsed < 1, elapsed  # Hook budget plus startup and local fake hc I/O.
            spool = docs["c11h.relay.spool"]["value"]["records"]
            assert len(spool) == 1, spool
            assert json.loads(spool[0]["line"])["method"] == "agent.event.append", spool
            assert all(value["value"] is None for name, value in docs.items() if name.startswith("c11h.relay.r")), docs
            print(f"PASS: hook journal timeout={request['timeout_ms']}ms, elapsed={elapsed:.3f}s; one append spooled, no live request")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


if __name__ == "__main__":
    main()
