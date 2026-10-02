#!/usr/bin/env python3
"""Exercise built launch-agent CLI parsing and response forwarding on a fake socket.

Set C11_CLI to the executable built from this checkout. No app, agent process,
user configuration, or production socket is used.
"""

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


WORKSPACE = "11111111-1111-4111-8111-111111111111"
TAB = "22222222-2222-4222-8222-222222222222"
AREA = "33333333-3333-4333-8333-333333333333"


def synthetic_prompt(byte_count):
    prefix = "  \nQuotes: '\" $HOME `echo nope`; Unicode: δ 日本語 🧭\n"
    suffix = "\n\t  "
    padding = byte_count - len((prefix + suffix).encode("utf-8"))
    assert padding > 0
    value = prefix + "x" * padding + suffix
    assert len(value.encode("utf-8")) == byte_count
    return value


def main():
    cli = os.environ.get("C11_CLI") or os.environ.get("C11_CLI_BIN")
    assert cli and Path(cli).is_file(), "Set C11_CLI to this checkout's built executable"
    launches = []
    failures = []
    reply = {
        "workspace_id": WORKSPACE,
        "tab_id": TAB,
        "area_id": AREA,
        "workspace_ref": "workspace:1",
        "tab_ref": "tab:1",
        "area_ref": "area:1",
        "startup": "pending",
        "startup_process": None,
        "prompt_file": "/fixture/owned prompt.txt",
    }

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                if not line.startswith(b"{"):
                    self.wfile.write(b"OK\n")
                    continue
                try:
                    request = json.loads(line)
                    method = request["method"]
                    if method == "system.capabilities":
                        payload = {"methods": ["agent.launch"]}
                    elif method == "agent.launch":
                        launches.append(request)
                        payload = dict(reply)
                    else:
                        failures.append("unexpected method: " + method)
                        payload = {}
                    response = {"id": request["id"], "ok": True, "result": payload}
                    self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
                except (KeyError, ValueError) as exc:
                    failures.append(str(exc))
                    return

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    with tempfile.TemporaryDirectory(prefix="c11-launch-cli-", dir="/tmp") as temporary:
        root = Path(temporary)
        socket_path = str(root / "fake.sock")
        prompt_file = root / "prompt ' dollar$ semi; 日本語.txt"
        server = Server(socket_path, Handler)
        worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
        worker.start()
        environment = fake_server_env(socket_path)
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        def run(*arguments, json_output=True):
            command = [cli, "--socket", socket_path]
            if json_output:
                command.append("--json")
            command += ["launch-agent", "--type", "codex", "--new-workspace", *arguments]
            return subprocess.run(command, env=environment, capture_output=True,
                                  text=True, encoding="utf-8", timeout=5)

        def accepted(*arguments, expected_prompt):
            before = len(launches)
            result = run(*arguments)
            assert result.returncode == 0, result.stderr
            assert len(launches) == before + 1, (result.stdout, launches[before:])
            params = launches[-1]["params"]
            assert params["prompt"] == expected_prompt, "CLI changed the raw prompt body"
            assert params["prompt"].encode("utf-8") == expected_prompt.encode("utf-8")
            assert params["type"] == "codex" and params["new_workspace"] is True, params
            assert "prompt_file" not in params, "CLI must forward content rather than caller file pathname"
            return json.loads(result.stdout)

        def rejected(*arguments, expected_error):
            before = len(launches)
            result = run(*arguments)
            assert result.returncode != 0, result.stdout
            assert expected_error in result.stderr, result.stderr
            assert len(launches) == before, "invalid input reached agent.launch"

        try:
            for size in (500, 1300, 32768):
                prompt = synthetic_prompt(size)
                prompt_file.write_bytes(prompt.encode("utf-8"))
                accepted("--prompt", prompt, expected_prompt=prompt)
                accepted("--prompt-file", str(prompt_file), expected_prompt=prompt)
                print("PASS: inline/file raw prompt bytes preserved (%d B)" % size)

            rejected("--prompt", "inline", "--prompt-file", str(prompt_file),
                     expected_error="mutually exclusive")
            rejected("--prompt-file", str(root / "missing.txt"), expected_error="failed to read --prompt-file")
            prompt_file.write_text(" \t\r\n", encoding="utf-8")
            rejected("--prompt-file", str(prompt_file), expected_error="failed to read --prompt-file")
            prompt_file.write_bytes(b"\xff\xfe")
            rejected("--prompt-file", str(prompt_file), expected_error="failed to read --prompt-file")
            print("PASS: conflicting, missing, whitespace-only and invalid UTF-8 files fail before launch")

            for state in ("pending", "started"):
                process = None if state == "pending" else {"pid": 1234, "executable": "/fixture/codex"}
                reply.update(startup=state, startup_process=process)
                payload = accepted("--prompt", "startup fixture", expected_prompt="startup fixture")
                assert payload["startup"] == state, payload
                assert payload["startup_process"] == process, payload
                assert payload["prompt_file"] == reply["prompt_file"], payload
                human = run("--prompt", "startup fixture", json_output=False)
                assert human.returncode == 0, human.stderr
                assert "startup=" + state in human.stdout, human.stdout
                print("PASS: startup=%s human and JSON forwarding" % state)

            assert not failures, failures
            print("PASS: built CLI fake-socket launch-agent checks (10 accepted launches, 4 rejected inputs)")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)
            assert not worker.is_alive(), "fake socket server did not stop"


if __name__ == "__main__":
    main()
