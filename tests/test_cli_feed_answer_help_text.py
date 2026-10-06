#!/usr/bin/env python3
"""Regression: help flags consumed by --text are literal feed.answer text."""

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            if not line.startswith(b"{"):
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue

            request = json.loads(line)
            self.server.requests.append(request)
            if request["method"] == "system.capabilities":
                result = {"methods": ["panel.list", "feed.answer"],
                          "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
            else:
                result = {"answered": False, "delivered": False, "submitted": False, "retry": "safe"}
            response = {"id": request["id"], "ok": True, "result": result}
            self.wfile.write((json.dumps(response) + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path):
        self.requests = []
        super().__init__(path, Handler)


def main():
    cli = os.environ.get("C11_CLI") or os.environ.get("C11_CLI_BIN")
    if not cli or not Path(cli).is_file():
        raise RuntimeError("Set C11_CLI to the tagged build's bundled CLI")

    workspace = "11111111-2222-4333-8444-555555555555"
    tab = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    with tempfile.TemporaryDirectory(prefix="c11-feed-answer-cli-") as directory:
        socket_path = str(Path(directory) / "fixture.sock")
        server = Server(socket_path)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            env = fake_server_env(socket_path)
            env.update(
                CMUX_CLI_SENTRY_DISABLED="1",
                CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
                C11_QUIET_DISCOVERY="1",
            )
            for literal in ("--help", "-h"):
                start = len(server.requests)
                result = subprocess.run(
                    [cli, "--socket", socket_path, "feed", "answer", tab,
                     "--workspace", workspace, "--text", literal, "--json"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                assert result.returncode == 0, result.stderr
                sent = [request for request in server.requests[start:]
                        if request["method"] == "feed.answer"]
                assert len(sent) == 1, (literal, result.stdout, result.stderr, server.requests[start:])
                assert sent[0]["params"]["text"] == literal, sent[0]
                assert json.loads(result.stdout)["retry"] == "safe"
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)
        print("PASS: --help and -h were each sent once as feed.answer text")


if __name__ == "__main__":
    main()
