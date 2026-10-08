#!/usr/bin/env python3
"""C11-280: four real create routes queue input, preserve the shell, and reject atomically.

Run only on an authorized isolated tagged app: set C11_SOCKET and C11_CLI.
The separate host fixture exercises slow isolated rc and native reconstruction.
"""
import base64
import json
import os
from pathlib import Path
import re
import shlex
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid

from cmux import cmux, cmuxError


def main():
    target = next((os.environ[k] for k in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH")
                   if os.environ.get(k)), "")
    assert re.fullmatch(r"/tmp/(?:c11|cmux)-debug-[^/]+\.sock", target), "explicit tagged socket required"
    cli = os.environ.get("C11_CLI")
    assert cli and Path(cli).is_file(), "C11_CLI must identify the same tagged artifact"
    created = []
    traced = []

    class Proxy(socketserver.StreamRequestHandler):
        def handle(self):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
                upstream.settimeout(10)
                upstream.connect(target)
                with upstream.makefile("rwb") as wire:
                    for line in self.rfile:
                        if line.startswith(b"{"):
                            traced.append(json.loads(line))
                        wire.write(line)
                        wire.flush()
                        response = wire.readline()
                        if not response:
                            return
                        self.wfile.write(response)

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    with tempfile.TemporaryDirectory(prefix="c11-280-v2-", dir="/tmp") as temporary, cmux(target) as client:
        proxy_path = str(Path(temporary) / "trace.sock")
        server = Server(proxy_path, Proxy)
        worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
        worker.start()
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("C11_", "CMUX_")):
                env.pop(key)
        for key in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH"):
            env[key] = proxy_path

        def run(*arguments, accepted=True):
            result = subprocess.run([cli, "--socket", proxy_path, "--json", "--id-format", "uuids", *arguments],
                                    env=env, text=True, capture_output=True, timeout=10)
            if accepted:
                assert result.returncode == 0, (arguments, result.stderr)
                return json.loads(result.stdout)
            assert result.returncode != 0, (arguments, result.stdout)
            return result.stderr

        def workspace_ids():
            return {row[1] for row in client.list_workspaces()}

        def snapshot(workspace):
            tabs = client._call("panel.list", {"workspace_id": workspace})["panels"]
            areas = client._call("area.list", {"workspace_id": workspace})["areas"]
            return workspace_ids(), {row["id"] for row in tabs}, {row["id"] for row in areas}

        def read(workspace, tab):
            value = client._call("panel.read_text", {"workspace_id": workspace, "panel_id": tab})
            return value.get("text") or base64.b64decode(value.get("base64") or "").decode("utf-8", "replace")

        def wait_output(workspace, tab, marker, timeout=10):
            deadline = time.monotonic() + timeout
            text = ""
            while time.monotonic() < deadline:
                text = read(workspace, tab)
                if marker in text:
                    return text
                time.sleep(0.05)
            raise AssertionError("missing execution output " + marker + ": " + text[-1500:])

        def command(label):
            token = label + "_" + uuid.uuid4().hex
            # The echoed command never contains the assembled output marker.
            return "printf 'C11_280_%s\\n' '" + token + "'", "C11_280_" + token

        def followup(workspace, tab, label):
            text, marker = command(label)
            client._call("panel.send_text", {"workspace_id": workspace, "panel_id": tab, "text": text})
            client._call("panel.send_key", {"workspace_id": workspace, "panel_id": tab, "key": "enter"})
            wait_output(workspace, tab, marker)

        def own(payload):
            workspace = payload["workspace_id"]
            created.append(workspace)
            return workspace

        def tab_of(payload, workspace):
            return payload.get("panel_id") or client._call("panel.list", {"workspace_id": workspace})["panels"][0]["id"]

        try:
            capabilities = client._call("system.capabilities")
            assert any(row.get("id") == "create.initial_input" for row in capabilities["features"]), capabilities
            initial, marker = command("workspace")
            before = len(traced)
            payload = run("new-workspace", "--title", "C11-280 fixture", "--command", initial)
            workspace = own(payload)
            tab = tab_of(payload, workspace)
            assert payload["initial_input"] == "queued", payload
            requests = traced[before:]
            creates = [r for r in requests if r["method"] == "workspace.create"]
            assert len(creates) == 1 and creates[0]["params"]["initial_input"] == initial + "\r", requests
            assert not any(r["method"] == "panel.send_text" for r in requests), requests
            wait_output(workspace, tab, marker)
            followup(workspace, tab, "workspace_followup")
            print("PASS: workspace.create carries initial_input once; no create-following panel.send_text")

            for route, arguments in (("new-panel", ["new-panel"]),
                                     ("new-split", ["new-split", "down", "--allow-undersized"]),
                                     ("new-area", ["new-area", "--direction", "right", "--allow-undersized"])):
                text, marker = command(route)
                payload = run(*arguments, "--workspace", workspace, "--command", text)
                assert payload["initial_input"] == "queued", payload
                tab = tab_of(payload, workspace)
                wait_output(workspace, tab, marker)
                followup(workspace, tab, route + "_followup")
                print("PASS: " + route + " executes queued input and retains an interactive shell")

            for kind in ("browser", "markdown"):
                for route in ("new-panel", "new-area"):
                    before = snapshot(workspace)
                    error = run(route, "--workspace", workspace, "--type", kind,
                                "--command", "echo forbidden", accepted=False)
                    assert "--command" in error, error
                    assert snapshot(workspace) == before, "CLI rejection changed layout"
            before = snapshot(workspace)
            error = run("new-workspace", "--layout", "/missing/fixture.json",
                        "--command", "echo forbidden", accepted=False)
            assert "--command" in error and "--layout" in error, error
            assert snapshot(workspace) == before

            invalid = [("workspace.create", {"initial_input": "x", "layout": {}})]
            for method in ("workspace.create", "panel.create", "panel.split", "area.create"):
                for value in (42, True, [], {}):
                    invalid.append((method, {"workspace_id": workspace, "panel_id": tab,
                                             "direction": "down", "initial_input": value}))
            for method in ("panel.create", "area.create"):
                for kind in ("browser", "markdown"):
                    invalid.append((method, {"workspace_id": workspace, "direction": "down",
                                             "type": kind, "initial_input": "x"}))
            for method, params in invalid:
                before = snapshot(workspace)
                try:
                    client._call(method, params)
                except cmuxError as error:
                    assert "invalid_params" in str(error), str(error)
                else:
                    raise AssertionError("RPC should reject: " + method + repr(params))
                assert snapshot(workspace) == before, "RPC rejection mutated workspace/tab/area sets"
            print("PASS: non-terminal, layout and invalid-type CLI/RPC rejections are atomic")

            replacement, marker = command("replacement")
            # Darwin Ghostty execs the first command, so use an explicit shell
            # program for a receipt plus a bounded, noninteractive holder.
            payload = client._call("workspace.create", {
                "title": "C11-280 replacement fixture",
                "initial_command": "/bin/sh -c " + shlex.quote(replacement + "; exec /bin/sleep 30")
            })
            replacement_ws = own(payload)
            replacement_tab = tab_of(payload, replacement_ws)
            wait_output(replacement_ws, replacement_tab, marker)
            later, later_marker = command("must_not_execute")
            client._call("panel.send_text", {"workspace_id": replacement_ws, "panel_id": replacement_tab, "text": later + "\n"})
            time.sleep(0.5)
            assert later_marker not in read(replacement_ws, replacement_tab), "initial_command unexpectedly retained a shell"
            print("PASS: initial_command replaces the shell; initial_input leaves it running")
            print("PASS: create.initial_input live tagged artifact checks complete")
        finally:
            cleanup_errors = []
            for workspace in reversed(created):
                try:
                    client._call("workspace.close", {"workspace_id": workspace})
                except Exception as error:
                    cleanup_errors.append(str(error))
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)
            assert not cleanup_errors, cleanup_errors
            assert not (workspace_ids() & set(created)), "disposable workspace cleanup failed"


if __name__ == "__main__":
    main()
