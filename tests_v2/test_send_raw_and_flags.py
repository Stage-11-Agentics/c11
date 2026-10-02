#!/usr/bin/env python3
"""C11-281 built CLI fixtures (--offline) and isolated tagged PTY proof.

Live mode requires C11_CLI and an explicitly supplied C11_281_SOCKET. Never use
the operator's session. Collector mode runs inside one disposable terminal.
"""

import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tty
import uuid


def collector(directory):
    """Record PTY input bytes, including paste delimiters and separate Return."""
    root = Path(directory)
    tty.setraw(sys.stdin.fileno())
    sys.stdout.write("\x1b[?2004hC11281_COLLECTOR_READY\r\n")
    sys.stdout.flush()
    (root / "ready").touch()
    deadline = time.monotonic() + 120
    with (root / "bytes").open("ab", buffering=0) as output:
        while time.monotonic() < deadline and not (root / "stop").exists():
            if select.select([sys.stdin], [], [], 0.1)[0]:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    break
                output.write(data)


def cli_run(cli, socket_path, *arguments, stdin=None, ok=True):
    environment = dict(os.environ)
    for name in ("C11_TAB_ID", "C11_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID"):
        environment.pop(name, None)
    environment["C11_TAB_ID"] = "33333333-3333-4333-8333-333333333333"
    proc = subprocess.run([cli, "--socket", socket_path, *arguments], input=stdin,
                          capture_output=True, text=True, timeout=25, env=environment)
    assert (proc.returncode == 0) == ok, (arguments, proc.returncode, proc.stderr)
    return proc


def offline(cli):
    """Protocol fixture proof; does not claim terminal or live app behavior."""
    workspace, tab = str(uuid.uuid4()), str(uuid.uuid4())
    cases = [
        (["send", "--raw", "--no-submit", r"literal\n"], None, r"literal\n", True, False),
        (["send", "--no-submit", r"literal\n"], None, "literal\r", False, False),
        (["send", "--raw", "--no-submit", "-"], "\nline1\nline2\r\n", "\nline1\nline2\r\n", True, False),
        (["paste", "--no-submit"], "\n", "\n", True, False),
        (["send-tab", "--raw", "--no-submit", "body"], None, "body", True, False),
        (["send", "--no-submit", "--", "--bogus"], None, "--bogus", False, False),
        (["send", "--no-submit", "--", "--help"], None, "--help", False, False),
    ]
    cases = [(a, stdin, body, raw, submit, False, True) for a, stdin, body, raw, submit in cases]
    cases += [
        (["send", "--raw", "--no-submit", "queued-body"], None, "queued-body", True, False, True, True),
        (["send", "--raw", "body"], None, "body", True, True, False, True),
        (["paste", "--no-submit", "body"], None, None, True, False, False, False),
    ]
    for arguments, stdin, expected, raw, submit, queued, supported in cases:
        with tempfile.TemporaryDirectory(prefix="c11-281-peer-", dir="/tmp") as directory:
            path = str(Path(directory) / "peer.sock")
            requests, errors = [], []
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(25)

                def serve():
                    try:
                        with listener.accept()[0] as connection, connection.makefile("rwb") as stream:
                            connection.settimeout(25)
                            for line in stream:
                                if line.startswith(b"auth "):
                                    stream.write(b"OK\n")
                                    stream.flush()
                                    continue
                                request = json.loads(line)
                                requests.append(request)
                                if request["method"] == "system.capabilities":
                                    result = {"methods": ["system.capabilities", "tab.list", "tab.send_text"],
                                              "features": [{"id": "send.raw", "version": 1}] if supported else []}
                                else:
                                    assert request["method"] == "tab.send_text", request
                                    result = {"workspace_id": workspace, "tab_id": tab,
                                              "queued": queued, "delivered": not queued, "submitted": submit}
                                stream.write((json.dumps({"id": request["id"], "ok": True,
                                                          "result": result}) + "\n").encode())
                                stream.flush()
                    except Exception as error:
                        errors.append(error)

                peer = threading.Thread(target=serve, daemon=True)
                peer.start()
                # Insert targeting before any literal -- terminator.
                targeted = [arguments[0], "--workspace", workspace, "--tab", tab, *arguments[1:]]
                try:
                    proc = cli_run(cli, path, *targeted, stdin=stdin, ok=supported)
                finally:
                    peer.join(timeout=25)
                assert not peer.is_alive() and not errors, errors
                sends = [r for r in requests if r["method"] == "tab.send_text"]
                if not supported:
                    assert not sends and len(requests) == 1, requests
                    assert "send.raw" in proc.stderr, proc.stderr
                    continue
                assert len(sends) == 1, requests
                params = sends[0]["params"]
                assert params["text"] == expected and params["submit"] is submit, params
                assert params.get("preserve_newlines", False) is raw, params
                assert params["caller_tab_id"] == "33333333-3333-4333-8333-333333333333", params
                expected_status = "queued, not delivered" if queued else (
                    "delivered, return scheduled" if submit else "delivered, not submitted")
                assert expected_status in proc.stdout, proc.stdout
                assert all(r["method"] in ("system.capabilities", "tab.send_text") for r in requests), requests

    with tempfile.TemporaryDirectory(prefix="c11-281-absent-") as directory:
        dead = str(Path(directory) / "absent.sock")
        for flag in ("--bogus", "--text"):
            proc = cli_run(cli, dead, "send", "--tab", tab, flag, "hello", ok=False)
            assert flag in proc.stderr and "Unknown flag" in proc.stderr, proc.stderr
        assert "send --raw" in cli_run(cli, dead, "paste", "--help").stdout
    print("PASS C11-281 built-CLI parser/protocol fixtures (not live PTY proof)")


def wait_until(predicate, description, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(description)


def live(cli, socket_path):
    sys.path.insert(0, str(Path(__file__).parent))
    from cmux import cmux
    with tempfile.TemporaryDirectory(prefix="c11-281-pty-") as directory, cmux(socket_path) as client:
        root = Path(directory)
        workspace = client._call("workspace.create")["workspace_id"]
        try:
            features = client._call("system.capabilities")["features"]
            assert any(item["id"] == "send.raw" and item["version"] == 1 for item in features), features
            client._call("workspace.select", {"workspace_id": workspace})
            tab = client._call("tab.list", {"workspace_id": workspace})["tabs"][0]["id"]
            # Launch the byte collector through the normal shell path.
            import shlex
            command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--collector", directory])
            client._call("tab.send_text", {"workspace_id": workspace, "tab_id": tab,
                                          "text": command, "submit": True})
            wait_until(lambda: (root / "ready").exists(), "collector did not start")

            def collect(arguments, stdin, body, submitted):
                path = root / "bytes"
                before = len(path.read_bytes()) if path.exists() else 0
                proc = cli_run(cli, socket_path, "--json", arguments[0], "--workspace", workspace,
                               "--tab", tab, *arguments[1:], stdin=stdin)
                payload = json.loads(proc.stdout)
                assert payload["delivered"] is True and payload["queued"] is False, payload
                assert payload["submitted"] is submitted, payload
                expected = b"\x1b[200~" + body.encode() + b"\x1b[201~" + (b"\r" if submitted else b"")
                wait_until(lambda: path.exists() and len(path.read_bytes()) >= before + len(expected),
                           "collector did not receive expected input")
                time.sleep(0.3)
                actual = path.read_bytes()[before:]
                assert actual == expected, (actual, expected)

            collect(["send", "--raw", "--no-submit", r"literal\n"], None, r"literal\n", False)
            collect(["paste", "--no-submit"], "\nline1\nline2\r\n", "\nline1\nline2\r\n", False)
            collect(["paste", "--no-submit"], "\n", "\n", False)
            collect(["send", "--raw", "-"], "\n", "\n", True)
            collect(["send", "--no-submit", r"literal\n"], None, "literal", True)
            before = (root / "bytes").read_bytes()
            for flag in ("--bogus", "--text"):
                proc = cli_run(cli, socket_path, "send", "--workspace", workspace,
                               "--tab", tab, flag, "hello", ok=False)
                assert flag in proc.stderr, proc.stderr
            time.sleep(0.3)
            assert (root / "bytes").read_bytes() == before, "unknown flag reached the PTY"
            print("PASS C11-281 attached PTY byte/Return boundary and unknown-flag rejection")
        finally:
            (root / "stop").touch()
            client.close_workspace(workspace)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--collector")
    args = parser.parse_args()
    if args.collector:
        collector(args.collector)
        return
    cli = os.environ["C11_CLI"]
    if args.offline:
        offline(cli)
    else:
        live(cli, os.environ["C11_281_SOCKET"])


if __name__ == "__main__":
    main()
