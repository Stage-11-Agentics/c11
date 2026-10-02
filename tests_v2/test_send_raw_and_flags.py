#!/usr/bin/env python3
"""C11-281 built CLI fixtures (--offline) and isolated tagged PTY proof.

Live mode requires C11_CLI, C11_281_SOCKET and C11_281_EVENT_LOG (that tagged
app's per-instance log). Never use the operator's session. Collector mode runs
inside one disposable terminal.
"""

import argparse
from contextlib import contextmanager
import hashlib
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


@contextmanager
def fragmented_requests(socket_path, directory):
    """Relay built-CLI requests, deliberately pausing inside UTF-8 sequences."""
    path = str(Path(directory) / "fragment.sock")
    errors, splits = [], []
    stopped = threading.Event()
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen(4)
    listener.settimeout(0.1)

    def relay():
        try:
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection, socket.socket(socket.AF_UNIX) as upstream:
                    upstream.connect(socket_path)
                    with connection.makefile("rb") as incoming, upstream.makefile("rb") as outgoing:
                        for request in incoming:
                            if len(request) > 8192:
                                cuts = [i for i in range(4000, 4095) if request[i] & 0xC0 == 0x80]
                                assert cuts, "large fixture must contain UTF-8 on the wire near a read boundary"
                                cut = cuts[0]
                                try:
                                    request[:cut].decode("utf-8")
                                except UnicodeDecodeError:
                                    pass
                                else:
                                    raise AssertionError("fragment did not end inside a multibyte character")
                                upstream.sendall(request[:cut])
                                # The listener's blocking read consumes this fragment before
                                # the remainder arrives, instead of coalescing both writes.
                                time.sleep(0.15)
                                for offset in range(cut, len(request), 4095):
                                    upstream.sendall(request[offset:offset + 4095])
                                    time.sleep(0.005)
                                splits.append({"wire_bytes": len(request), "split": cut})
                            else:
                                upstream.sendall(request)
                            response = outgoing.readline()
                            assert response, "upstream disconnected without a response"
                            connection.sendall(response)
        except Exception as error:
            errors.append(error)

    peer = threading.Thread(target=relay, daemon=True)
    peer.start()
    try:
        yield path, splits
    finally:
        stopped.set()
        peer.join(timeout=5)
        listener.close()
        assert not peer.is_alive() and not errors, errors


def offline(cli):
    """Protocol fixture proof; does not claim terminal or live app behavior."""
    workspace, tab = str(uuid.uuid4()), str(uuid.uuid4())
    cases = [
        (["send", "--raw", "--no-submit", r"literal\n"], None, r"literal\n", True, False),
        (["send", "--no-submit", r"literal\n"], None, "literal\r", False, False),
        (["send", "--json", "body"], None, "body", False, True),
        (["send", "--raw", "--no-submit", "-"], "\nline1\nline2\r\n", "\nline1\nline2\r\n", True, False),
        (["paste", "--no-submit"], "\n", "\n", True, False),
        (["send-tab", "--raw", "--no-submit", "body"], None, "body", True, False),
        (["send", "--no-submit", "--", "--bogus"], None, "--bogus", False, False),
        (["send", "--no-submit", "--", "--help"], None, "--help", False, False),
    ]
    cases = [(a, stdin, body, raw, submit, False, True, None) for a, stdin, body, raw, submit in cases]
    cases += [
        (["send", "--raw", "--no-submit", "queued-body"], None, "queued-body", True, False, True, True, None),
        (["send", "--raw", "body"], None, "body", True, True, False, True, None),
        (["send", "--allow-unguarded", "body"], None, "body", False, True, False, True, None),
        (["send", "--json", "checked-body"], None, "checked-body", False, True, False, True, "checked"),
        (["paste", "--no-submit", "body"], None, None, True, False, False, False, None),
        (["paste", "--no-submit", "body"], None, None, True, False, False, None, None),
    ]
    for arguments, stdin, expected, raw, submit, queued, supported, guard_state in cases:
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
                                    if guard_state == "checked":
                                        result.update({"input_guard": "checked", "input_state": "empty",
                                                       "draft_length": None, "source": "active_screen",
                                                       "observed_at_ms": 123})
                                response = {"id": request["id"], "ok": True, "result": result}
                                if request["method"] == "system.capabilities" and supported is None:
                                    response = {"id": request["id"], "ok": False,
                                                "error": {"code": "method_not_found", "message": "Fixture legacy server"}}
                                stream.write((json.dumps(response) + "\n").encode())
                                stream.flush()
                    except Exception as error:
                        errors.append(error)

                peer = threading.Thread(target=serve, daemon=True)
                peer.start()
                # Insert targeting before any literal -- terminator.
                targeted = [arguments[0], "--workspace", workspace, "--tab", tab, *arguments[1:]]
                try:
                    proc = cli_run(cli, path, *targeted, stdin=stdin, ok=bool(supported))
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
                assert params.get("allow_unguarded", False) is ("--allow-unguarded" in arguments), params
                assert params["caller_tab_id"] == "33333333-3333-4333-8333-333333333333", params
                expected_status = "queued, not delivered" if queued else (
                    "delivered, return scheduled" if submit else "delivered, not submitted")
                if "--json" in arguments:
                    payload = json.loads(proc.stdout)
                    assert payload["input_guard"] == (guard_state or "unguarded"), payload
                    assert payload["input_state"] == ("empty" if guard_state == "checked" else "unknown"), payload
                else:
                    assert expected_status in proc.stdout and "input_guard: unguarded" in proc.stdout, proc.stdout
                assert all(r["method"] in ("system.capabilities", "tab.send_text") for r in requests), requests

    with tempfile.TemporaryDirectory(prefix="c11-281-absent-") as directory:
        dead = str(Path(directory) / "absent.sock")
        for flag in ("--bogus", "--text"):
            proc = cli_run(cli, dead, "send", "--tab", tab, flag, "hello", ok=False)
            assert flag in proc.stderr and "Unknown flag" in proc.stderr, proc.stderr
        assert "send --raw" in cli_run(cli, dead, "paste", "--help").stdout
        send_help = cli_run(cli, dead, "send", "--help").stdout
        assert "--allow-unguarded" in send_help and "not atomic" in send_help.lower(), send_help
        assert "send-key is not guarded" in send_help.lower(), send_help
        assert "Usage: c11 input-state" in cli_run(cli, dead, "input-state", "--help").stdout

    with tempfile.TemporaryDirectory(prefix="c11-267-refusal-") as directory:
        path = str(Path(directory) / "peer.sock")
        requests, errors = [], []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(25)

            def serve_refusal():
                try:
                    with listener.accept()[0] as connection, connection.makefile("rwb") as stream:
                        connection.settimeout(25)
                        for line in stream:
                            request = json.loads(line)
                            requests.append(request)
                            if request["method"] == "system.capabilities":
                                response = {"id": request["id"], "ok": True, "result": {
                                    "methods": ["system.capabilities", "tab.list", "tab.send_text"], "features": []}}
                            else:
                                assert request["method"] == "tab.send_text", request
                                response = {"id": request["id"], "ok": False, "error": {
                                    "code": "input_guard_refused", "message": "Input guard refused a draft.",
                                    "data": {"input_guard": "refused", "input_state": "draft",
                                             "draft_length": 7, "source": "active_screen",
                                             "observed_at_ms": 123, "reason": "draft",
                                             "hint": "Inspect or explicitly override."}}}
                            stream.write((json.dumps(response) + "\n").encode())
                            stream.flush()
                except Exception as error:
                    errors.append(error)

            peer = threading.Thread(target=serve_refusal, daemon=True)
            peer.start()
            proc = cli_run(cli, path, "--json", "send", "--workspace", workspace,
                           "--tab", tab, "body", ok=False)
            peer.join(timeout=25)
            assert not peer.is_alive() and not errors, errors
            payload = json.loads(proc.stdout)
            assert payload["ok"] is False, payload
            assert payload["error"]["code"] == "input_guard_refused", payload
            assert payload["error"]["data"]["draft_length"] == 7, payload
            assert payload["error"]["data"]["hint"] == "Inspect or explicitly override.", payload
            assert "input_guard_refused" in proc.stderr and "input_guard: refused" in proc.stderr, proc.stderr
            assert "Nothing was sent; do not press Enter" in proc.stderr and "raise-flag" in proc.stderr, proc.stderr
            assert [request["method"] for request in requests] == ["system.capabilities", "tab.send_text"], requests

    with tempfile.TemporaryDirectory(prefix="c11-267-input-state-") as directory:
        path = str(Path(directory) / "peer.sock")
        requests, errors = [], []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(25)

            def serve_input_state():
                try:
                    with listener.accept()[0] as connection, connection.makefile("rwb") as stream:
                        connection.settimeout(25)
                        for line in stream:
                            request = json.loads(line)
                            requests.append(request)
                            if request["method"] == "system.capabilities":
                                result = {"methods": ["system.capabilities", "tab.list", "tab.input_state"], "features": []}
                            else:
                                assert request["method"] == "tab.input_state", request
                                assert request["params"].get("tab_id") == tab, request
                                result = {"tab_id": tab, "input_state": "draft", "draft_length": 7,
                                          "source": "active_screen", "observed_at_ms": 123}
                            response = {"id": request["id"], "ok": True, "result": result}
                            stream.write((json.dumps(response) + "\n").encode())
                            stream.flush()
                except Exception as error:
                    errors.append(error)

            peer = threading.Thread(target=serve_input_state, daemon=True)
            peer.start()
            proc = cli_run(cli, path, "input-state", "--workspace", workspace, "--tab", tab, "--json")
            peer.join(timeout=25)
            assert not peer.is_alive() and not errors, errors
            payload = json.loads(proc.stdout)
            assert payload["input_state"] == "draft" and payload["draft_length"] == 7, payload
            assert [request["method"] for request in requests] == ["system.capabilities", "tab.input_state"], requests
    print("PASS C11-281 built-CLI parser/protocol fixtures (not live PTY proof)")


def wait_until(predicate, description, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(description)


def live(cli, socket_path, event_log):
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

            def events():
                lines = Path(event_log).read_text().splitlines()
                result = []
                for index, line in enumerate(lines):
                    try:
                        result.append(json.loads(line))
                    except json.JSONDecodeError:
                        assert index == len(lines) - 1, line
                return result

            def collect(arguments, stdin, body, submitted, event_text=None, route=None):
                path = root / "bytes"
                before = len(path.read_bytes()) if path.exists() else 0
                last_seq = max(event["seq"] for event in events())
                proc = cli_run(cli, route or socket_path, "--json", arguments[0], "--workspace", workspace,
                               "--tab", tab, *arguments[1:], stdin=stdin)
                payload = json.loads(proc.stdout)
                assert payload["delivered"] is True and payload["queued"] is False, payload
                assert payload["submitted"] is submitted, payload
                expected = b"\x1b[200~" + body.encode() + b"\x1b[201~" + (b"\r" if submitted else b"")
                wait_until(lambda: path.exists() and len(path.read_bytes()) >= before + len(expected),
                           "collector did not receive expected input")
                time.sleep(0.3)
                actual = path.read_bytes()[before:]
                assert actual == expected, (len(actual), len(expected), hashlib.sha256(actual).hexdigest(), hashlib.sha256(expected).hexdigest())
                sent = wait_until(lambda: [event for event in events()
                                           if event["seq"] > last_seq
                                           and event["type"] == "tab.input_sent"
                                           and event.get("surface", "").lower() == tab.lower()],
                                  "send event was not recorded")
                assert len(sent) == 1, sent
                record = sent[0]["payload"]
                assert record["text"] == (body if event_text is None else event_text), record
                assert record["caller_tab_id"] == "33333333-3333-4333-8333-333333333333", record
                assert record["submitted"] is submitted and not record.get("queued", False), record

            collect(["send", "--raw", "--no-submit", r"literal\n"], None, r"literal\n", False)
            collect(["paste", "--no-submit"], "\nline1\nline2\r\n", "\nline1\nline2\r\n", False)
            collect(["paste", "--no-submit"], "\n", "\n", False)
            collect(["send", "--raw", "-"], "\n", "\n", True)
            collect(["send", "--no-submit", r"literal\n"], None, "literal", True, event_text="literal\r")
            ascii_body = "C11281_LARGE_ASCII_" + "0123456789abcdef" * 4096
            collect(["send", "--raw", "--no-submit", "-"], ascii_body, ascii_body, False)
            utf8_body = "界🙂é" * 8192 + "\nUTF8_END\n"
            with fragmented_requests(socket_path, directory) as (route, splits):
                collect(["send", "--raw", "--no-submit", "-"], utf8_body, utf8_body, False, route=route)
                assert len(splits) == 1, splits
                print("PASS C11-281 large ASCII/UTF-8 stdin byte-exact PTY; forced split", splits[0])
            before = (root / "bytes").read_bytes()
            for flag in ("--bogus", "--text"):
                proc = cli_run(cli, socket_path, "send", "--workspace", workspace,
                               "--tab", tab, flag, "hello", ok=False)
                assert flag in proc.stderr, proc.stderr
            time.sleep(0.3)
            assert (root / "bytes").read_bytes() == before, "unknown flag reached the PTY"
            print("PASS C11-281 attached PTY bytes, Return boundary, single full attributed event, and flag rejection")
        finally:
            (root / "stop").touch()
            client.close_workspace(workspace)



def queued(cli, socket_path, event_log):
    """Bounded Debug fixture: actual handler timeout, event and attach flush."""
    sys.path.insert(0, str(Path(__file__).parent))
    from cmux import cmux
    with cmux(socket_path) as client:
        workspace = client._call("workspace.create")["workspace_id"]
        try:
            # Normal create calls eagerly start terminals. The fixture creates
            # and holds one new tab atomically, before those callbacks run.
            anchor = client._call("tab.list", {"workspace_id": workspace})["tabs"][0]["id"]
            created = client._call("debug.terminal.runtime_start_hold", {
                "workspace_id": workspace, "tab_id": anchor, "create": True, "hold": True
            })
            tab = created["tab_id"]
            target = {"workspace_id": workspace, "tab_id": tab}
            last_seq = max(json.loads(line)["seq"] for line in Path(event_log).read_text().splitlines())
            body = r"C11_281_QUEUED\n_LITERAL"
            proc = cli_run(cli, socket_path, "--json", "send", "--workspace", workspace,
                           "--tab", tab, "--raw", "--no-submit", body)
            payload = json.loads(proc.stdout)
            assert payload["queued"] and not payload["delivered"] and not payload["submitted"], payload
            suffix = " C11_281_QUEUED_SUFFIX"
            proc = cli_run(cli, socket_path, "paste", "--workspace", workspace,
                           "--tab", tab, "--no-submit", suffix)
            assert "queued, not delivered" in proc.stdout and "has not seen it" in proc.stdout, proc.stdout
            client._call("debug.terminal.runtime_start_hold", {**target, "hold": False})
            client._call("workspace.select", {"workspace_id": workspace})

            def screen():
                return client._call("tab.read_text", target).get("text", "")

            text = wait_until(lambda: (value if body + suffix in (value := screen()) else None),
                              "queued text did not appear after attach")
            assert "command not found" not in text.lower(), "queued no-submit dispatched Return"
            sent = [json.loads(line) for line in Path(event_log).read_text().splitlines()]
            sent = [event for event in sent if event["seq"] > last_seq
                    and event["type"] == "tab.input_sent"
                    and event.get("surface", "").lower() == tab.lower()]
            assert len(sent) == 2, sent
            for event, expected in zip(sent, [body, suffix]):
                record = event["payload"]
                assert record["text"] == expected and record["queued"] and not record["submitted"], record
                assert record["caller_tab_id"] == "33333333-3333-4333-8333-333333333333", record
            print("PASS C11-281 actual queued response/human status, one attributed event per send, attach flush")
        finally:
            client.close_workspace(workspace)


def queued_bytes(cli, socket_path, event_log):
    """Pre-attach queue, then the real flush into an attached raw PTY oracle.

    The bounded Debug flush hold permits the collector to start after runtime
    attach without consuming the pre-attach queue. Releasing it executes the
    ordinary flush, including any Return outside the paste envelope.
    """
    import shlex
    sys.path.insert(0, str(Path(__file__).parent))
    from cmux import cmux
    cases = [
        (["send", "--raw", "--no-submit", "\nleading\ninterior\ntrailing\n"], None, "\nleading\ninterior\ntrailing\n", False),
        (["send", "--raw", "--no-submit", "\n"], None, "\n", False),
        (["send", "--raw", "--no-submit", "-"], "\nstdin界🙂\n", "\nstdin界🙂\n", False),
        (["paste", "--no-submit"], "\n", "\n", False),
        (["send", "--raw", "-"], "\nsubmitted\n", "\nsubmitted\n", True),
    ]
    with tempfile.TemporaryDirectory(prefix="c11-281-queued-bytes-") as directory, cmux(socket_path) as client:
        workspace = None
        try:
            for index, (arguments, stdin, body, submitted) in enumerate(cases):
                # An inactive workspace avoids the visible-tab eager-start path.
                workspace = client._call("workspace.create")["workspace_id"]
                anchor_tab = client._call("tab.list", {"workspace_id": workspace})["tabs"][0]["id"]
                root = Path(directory) / str(index)
                root.mkdir()
                tab = client._call("debug.terminal.runtime_start_hold", {
                    "workspace_id": workspace, "tab_id": anchor_tab,
                    "create": True, "hold": True, "hold_flush": True
                })["tab_id"]
                target = {"workspace_id": workspace, "tab_id": tab}
                last_seq = max(json.loads(line)["seq"] for line in Path(event_log).read_text().splitlines())
                proc = cli_run(cli, socket_path, "--json", arguments[0], "--workspace", workspace,
                               "--tab", tab, *arguments[1:], stdin=stdin)
                payload = json.loads(proc.stdout)
                assert payload["queued"] and not payload["delivered"], payload
                assert payload["submitted"] is submitted, payload
                # Start the runtime while leaving its pending flush held.
                client._call("debug.terminal.runtime_start_hold", {**target, "hold": False})
                client._call("workspace.select", {"workspace_id": workspace})
                client._call("tab.focus", target)
                command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--collector", str(root)])
                response = client._call("tab.send_text", {**target, "text": command, "submit": True})
                assert response["delivered"] and not response["queued"], response
                wait_until(lambda: (root / "ready").exists(), "queued-byte collector did not start", timeout=5)
                path = root / "bytes"
                assert not path.read_bytes(), "fixture flushed before the PTY oracle was ready"
                client._call("debug.terminal.runtime_start_hold", {**target, "hold": False, "hold_flush": False})
                expected = b"\x1b[200~" + body.encode() + b"\x1b[201~" + (b"\r" if submitted else b"")
                wait_until(lambda: path.exists() and len(path.read_bytes()) >= len(expected), "queued bytes did not flush")
                time.sleep(0.3)
                actual = path.read_bytes()
                assert actual == expected, (index, actual, expected)
                sent = [json.loads(line) for line in Path(event_log).read_text().splitlines()]
                sent = [event for event in sent if event["seq"] > last_seq and event["type"] == "tab.input_sent"
                        and event.get("surface", "").lower() == tab.lower() and event["payload"]["text"] != command]
                assert len(sent) == 1, sent
                record = sent[0]["payload"]
                assert record["text"] == body and record["queued"] and record["submitted"] is submitted, record
                assert record["caller_tab_id"] == "33333333-3333-4333-8333-333333333333", record
                (root / "stop").touch()
                print("PASS C11-281 queued byte/Return oracle", index, len(body.encode()), "submitted", submitted)
                client.close_workspace(workspace)
                workspace = None
        finally:
            for stop_dir in Path(directory).iterdir():
                (stop_dir / "stop").touch()
            if workspace is not None:
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
        live(cli, os.environ["C11_281_SOCKET"], os.environ["C11_281_EVENT_LOG"])
        queued(cli, os.environ["C11_281_SOCKET"], os.environ["C11_281_EVENT_LOG"])
        queued_bytes(cli, os.environ["C11_281_SOCKET"], os.environ["C11_281_EVENT_LOG"])


if __name__ == "__main__":
    main()
