#!/usr/bin/env python3
"""B087: first read starts a never-focused terminal on an isolated test socket.

Run through sandbox-tests-v2.sh; ColdTerminalReadTests additionally proves the
absent-runtime precondition and removal during the wait inside the host app.
"""

import base64
import os
import subprocess
import time

from cmux import cmux, cmuxError, find_cli_binary


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    socket_path = os.environ.get("C11_SOCKET_PATH") or os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET")
    require(socket_path, "Set an explicit isolated test socket")
    cli = find_cli_binary()
    with cmux(socket_path) as client:
        original_ws = client._call("workspace.current")["workspace_id"]
        original_tab = client._call("panel.current", {"workspace_id": original_ws})
        ws = client._call("workspace.create")["workspace_id"]
        try:
            tab = client._call("panel.create", {
                "workspace_id": ws, "type": "terminal", "focus": False,
            })["panel_id"]
            params = {"workspace_id": ws, "panel_id": tab}
            started = time.monotonic()
            first = client._call("panel.read_text", params)
            elapsed = time.monotonic() - started
            require(first.get("panel_id", first.get("panel_id")) == tab, f"Wrong target: {first}")
            require(isinstance(first.get("text"), str), f"Cold read failed: {first}")
            print(f"First cold read: {elapsed:.3f}s")

            # Readiness can precede shell output. No send or focus is allowed
            # until the shell has printed; neither may mask missing startup.
            deadline = time.monotonic() + 5
            while not first["text"].strip() and time.monotonic() < deadline:
                time.sleep(0.05)
                first = client._call("panel.read_text", params)
            require(first["text"].strip(), "Started shell never printed its prompt")
            require(client._call("workspace.current")["workspace_id"] == original_ws, "Cold read changed workspace")
            require(client._call("panel.current", {"workspace_id": original_ws}) == original_tab, "Cold read changed focused tab")

            # AC3: warmed/focused capture parity, Unicode, scrollback and last-N.
            client._call("workspace.select", {"workspace_id": ws})
            client._call("panel.focus", params)
            client._call("panel.send_text", {**params, "text": "printf 'COLD_READ_%02d_λ雪\\n' {1..8}"})
            deadline = time.monotonic() + 5
            while True:
                captured = client._call("panel.read_text", {**params, "scrollback": True})
                if "COLD_READ_08_λ雪" in captured["text"]:
                    break
                require(time.monotonic() < deadline, "Shell output did not arrive")
                time.sleep(0.05)
            for method in ("panel.read_text", "tab.read_text", "surface.read_text"):  # canonical + both silent aliases
                captured = client._call(method, {**params, "scrollback": True, "lines": 20})
                require("COLD_READ_08_λ雪" in captured["text"], f"{method} lost Unicode output")
                require(base64.b64decode(captured["base64"]).decode() == captured["text"], "Text/base64 mismatch")
                require(len(captured["text"].splitlines()) <= 20, "Line limit exceeded")
            result = subprocess.run(
                [cli, "--socket", socket_path, "read-screen", "--workspace", ws, "--panel", tab, "--lines", "20"],
                capture_output=True, text=True, timeout=5,
            )
            require(result.returncode == 0 and "COLD_READ_08_λ雪" in result.stdout, f"CLI capture failed: {result}")

            client._call("panel.close", params)
            started = time.monotonic()
            try:
                client._call("panel.read_text", params)
            except cmuxError:
                pass
            else:
                raise AssertionError("Closed UUID unexpectedly read another tab")
            require(time.monotonic() - started < 4, "Closed read exceeded startup budget plus 2s scheduling allowance")
        finally:
            client._call("workspace.select", {"workspace_id": original_ws})
            client.close_workspace(ws)
    print("PASS: cold startup, no focus change, capture parity and closed UUID")


if __name__ == "__main__":
    main()
