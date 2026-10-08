#!/usr/bin/env python3
"""C11-285 tagged-app acceptance: local raw calls and unchanged friendly send."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from cmux import cmux
from fake_server_env import fake_server_env


def main():
    path = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET")
    cli = os.environ.get("C11_CLI")
    if not path or not re.fullmatch(r"/tmp/(?:c11|cmux)-debug-[^/]+\.sock", path) or not cli:
        raise RuntimeError("Set C11_SOCKET to an isolated tagged debug socket and C11_CLI to its bundled CLI")
    env = fake_server_env(path)
    env["C11_QUIET_DISCOVERY"] = "1"

    def run(args):
        return subprocess.run([cli, "--socket", path, *args], env=env, text=True, capture_output=True, timeout=15)

    def success(args):
        result = run(args)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    with cmux(path) as c:
        before = c._call("window.list")
        result = success(["rpc", "system.ping"])
        assert result["pong"] is True
        assert c._call("window.list") == before, "ping changed window selection"
        caps = success(["rpc", "system.capabilities"])
        assert {"id": "cli.rpc", "version": 1} in caps["features"]
        failure = run(["rpc", "no.such.method"])
        assert failure.returncode != 0 and "method_not_found" in failure.stderr
        rejected = run(["rpc", "system.ping", "[]"])
        assert rejected.returncode != 0 and "JSON object" in rejected.stderr
        ws = c.new_workspace()
        try:
            c.select_workspace(ws)
            tab = c.list_surfaces(ws)[0][1]
            command = "printf 'C11_RPC_%s\\n' 'receipt'\r"
            success(["rpc", "panel.send_text", json.dumps({"workspace_id": ws, "panel_id": tab, "text": command})])
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                screen = run(["read-screen", "--workspace", ws, "--panel", tab]).stdout
                if "C11_RPC_receipt" in screen:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("raw send receipt missing")
            friendly = run(["send", "--workspace", ws, "--panel", tab, "printf 'C11_FRIENDLY_%s\\n' 'receipt'"])
            assert friendly.returncode == 0, friendly.stderr
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if "C11_FRIENDLY_receipt" in run(["read-screen", "--workspace", ws, "--panel", tab]).stdout:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("friendly send receipt missing")
        finally:
            c.close_workspace(ws)
    print("PASS: tagged rpc ping preserves window; cli.rpc advertised; unknown and invalid calls rejected")
    print("PASS: raw panel.send_text and existing friendly send both produce shell receipts")


if __name__ == "__main__":
    main()
