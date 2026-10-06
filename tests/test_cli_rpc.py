#!/usr/bin/env python3
"""C11-285: raw-call framing, literal params and pre-connection rejection."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


def main():
    cli = os.environ.get("C11_CLI") or os.environ.get("C11_CLI_BIN")
    if not cli:
        raise RuntimeError("Set C11_CLI to the candidate bundled CLI")
    with tempfile.TemporaryDirectory(prefix="c11-rpc-") as directory:
        path = str(Path(directory) / "fixture.sock")
        requests = []
        connections = []
        errors = []
        stopped = threading.Event()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        server.settimeout(0.1)

        def serve():
            while not stopped.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                connections.append(True)
                try:
                    with conn, conn.makefile("rwb") as stream:
                        for line in stream:
                            if not line.startswith(b"{"):
                                # Existing auth/compat probes; never log their text.
                                stream.write(b"OK\n")
                                stream.flush()
                                continue
                            request = json.loads(line)
                            requests.append(request)
                            method = request["method"]
                            if method == "system.capabilities":
                                result = {"methods": ["panel.list", "fixture.echo", "no.such.method", "system.ping"],
                                          "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}
                            elif method == "no.such.method":
                                response = {"id": request["id"], "ok": False, "error": {"code": "method_not_found", "message": "Unknown fixture method"}}
                                stream.write((json.dumps(response) + "\n").encode())
                                stream.flush()
                                continue
                            elif method == "system.ping":
                                result = {"pong": True, "is_terminating_app": False}
                            else:
                                result = {"params": request["params"], "panel_id": "11111111-1111-4111-8111-111111111111"}
                            stream.write((json.dumps({"id": request["id"], "ok": True, "result": result}) + "\n").encode())
                            stream.flush()
                except Exception as error:
                    errors.append(type(error).__name__)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()

        def run(args, socket_path=path):
            env = fake_server_env(socket_path)
            env.update(CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1", C11_QUIET_DISCOVERY="1")
            return subprocess.run([cli, "--socket", socket_path, *args], env=env, capture_output=True, text=True, timeout=10)

        try:
            for args in [["rpc", "system.ping"], ["--json", "rpc", "system.ping"], ["rpc", "system.ping", "--json"]]:
                start = len(requests)
                result = run(args)
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == {"pong": True, "is_terminating_app": False}
                actual = [r for r in requests[start:] if r["method"] != "system.capabilities"]
                assert len(actual) == 1 and actual[0]["params"] == {}
            params = {"text": "literal\\n 世界\n", "nested": [None, True, {"panel_id": "panel:987"}]}
            start = len(requests)
            result = run(["rpc", "fixture.echo", json.dumps(params)])
            assert result.returncode == 0, result.stderr
            body = json.loads(result.stdout)
            assert body["params"] == params
            assert body["panel_id"] == "11111111-1111-4111-8111-111111111111"
            actual = [r for r in requests[start:] if r["method"] != "system.capabilities"]
            assert len(actual) == 1 and actual[0]["params"] == params
            result = run(["rpc", "no.such.method"])
            assert result.returncode != 0 and "method_not_found" in result.stderr
            for args in [[], [""], ["bad method"], ["system.ping", "[]"], ["system.ping", "null"], ["system.ping", '"text"'], ["system.ping", "1"], ["system.ping", "{bad"], ["system.ping", "{}", "extra"], ["system.ping", "--help"]]:
                before = (len(connections), len(requests))
                result = run(["rpc", *args])
                assert result.returncode != 0, args
                assert (len(connections), len(requests)) == before, args
            before = len(connections)
            result = run(["rpc", "--help"])
            assert result.returncode == 0 and "Usage: c11 rpc" in result.stdout
            assert len(connections) == before
            result = run(["rpc", "system.ping"], str(Path(directory) / "absent.sock"))
            assert result.returncode != 0 and "JSON object" not in result.stderr
            assert not errors, errors
            print("PASS: rpc sends one named v2 request; literal JSON/results preserved; server error passed through")
            print("PASS: ten malformed calls and help make zero connections; valid missing-app call fails")
        finally:
            stopped.set()
            worker.join(timeout=2)
            server.close()


if __name__ == "__main__":
    main()
