#!/usr/bin/env python3
"""C11-534: exercise the built CLI against bounded, newline-framed Unix peers.

Requires an explicit C11_CLI_BIN. Never discovers or contacts a running app.
Run with --fast-only against the old binary to demonstrate the regression red.
"""

from __future__ import annotations
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

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

from fake_server_env import fake_server_env


def frame(result=None, *, error=None, request_id="fixture"):
    envelope = {"id": request_id, "ok": error is None}
    envelope["error" if error else "result"] = error or result or {}
    return json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"


CAPS = {"methods": ["panel.list", "fixture.echo"],
        "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}


def exchange(cli, handler, *, method="system.capabilities", deadline_ms=2000):
    """Keep the accepted connection open until the CLI exits, unless asked to close."""
    # Let large-frame correctness checks tolerate startup and runner load.
    # Keep the fixture alive long enough to observe the CLI's own deadline.
    timeout_seconds = max(6, deadline_ms / 1000 + 2)
    with tempfile.TemporaryDirectory(prefix="c11-frame-", dir="/tmp") as directory:
        path = str(Path(directory) / "s")
        stopped = threading.Event()
        errors = []
        record = {"requests": [], "peer_closed": False}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(path)
            server.listen(1)
            server.settimeout(timeout_seconds)

            def serve():
                try:
                    with server.accept()[0] as conn:
                        conn.settimeout(timeout_seconds)
                        pending = bytearray()

                        def read_line():
                            while b"\n" not in pending:
                                data = conn.recv(4096)
                                if not data:
                                    raise AssertionError("CLI closed before its next request")
                                pending.extend(data)
                            line, _, rest = pending.partition(b"\n")
                            pending[:] = rest
                            return line

                        def request():
                            line = read_line()
                            record.setdefault("request_received", time.monotonic())
                            value = json.loads(line)
                            record["requests"].append(value["method"])
                            return value

                        # A known explicit password bypasses saved files and Keychain.
                        # Authentication is setup; each handler still sees only JSON.
                        assert read_line() == b"auth c11-fixture-only", "unexpected auth prelude"
                        conn.sendall(b"OK\n")
                        handler(conn, request, record, stopped)
                        stopped.wait(timeout_seconds)
                except Exception as exc:
                    errors.append(repr(exc))

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            env = fake_server_env(path)
            home = Path(directory) / "home"
            home.mkdir()
            env.pop("CMUX_SOCKET_PASSWORD", None)
            env.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
                       XDG_CONFIG_HOME=str(home / ".config"))
            env.update(C11_DEFAULT_SOCKET_DEADLINE_MS=str(deadline_ms),
                       CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
                       C11_QUIET_DISCOVERY="1")
            try:
                result = subprocess.run([cli, "--socket", path, "--password", "c11-fixture-only", "rpc", method], env=env,
                                        capture_output=True, timeout=timeout_seconds)
            finally:
                stopped.set()
                worker.join(timeout=timeout_seconds + 1)
            assert not worker.is_alive(), "fixture did not stop"
            assert not errors, {
                "peer_errors": errors,
                "returncode": result.returncode,
                "stderr": result.stderr.decode(errors="replace"),
            }
            return result, record


def record_client_close(conn, record):
    # Observe protocol completion without timing process startup or reaping.
    assert conn.recv(1) == b"", "CLI sent unexpected bytes after its response"
    record["client_closed"] = time.monotonic()


def reply_handler(chunks, *, close=False, delay=0.015):
    def serve(conn, request, record, stopped):
        request()
        for index, chunk in enumerate(chunks):
            if index:
                time.sleep(delay)
            if index == len(chunks) - 1:
                record["sent"] = time.monotonic()
            conn.sendall(chunk)
        if close:
            conn.shutdown(socket.SHUT_WR)
            record["peer_closed"] = True
        record_client_close(conn, record)
    return serve


def assert_success(result, expected):
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert json.loads(result.stdout) == expected, "response content was lost or changed"


def test_fast_open_peer(cli):
    result, record = exchange(cli, reply_handler([frame({"pong": True})]))
    assert_success(result, {"pong": True})
    latency = record["client_closed"] - record["sent"]
    assert not record["peer_closed"]
    assert latency < 0.100, f"waited {latency * 1000:.1f} ms after LF while peer stayed open"
    print(f"  LF to client socket close: {latency * 1000:.1f} ms (peer still open)")


def test_newline_alone(cli):
    wire = frame({"text": "first\nsecond\r\nthird"})
    result, record = exchange(cli, reply_handler([wire[:5], wire[5:-1], b"\n"]))
    assert_success(result, {"text": "first\nsecond\r\nthird"})
    assert record["client_closed"] - record["sent"] < 0.100


def test_fragmented_utf8(cli):
    payload = {"text": "A界🙂Z"}
    wire = frame(payload)
    at = wire.index("界".encode())
    result, _ = exchange(cli, reply_handler([wire[:at + 1], wire[at + 1:at + 4], wire[at + 4:]]))
    assert_success(result, payload)


def test_large_reply(cli):
    payload = {"text": "a" * (8 * 1024 * 1024) + "界\nend"}
    wire = frame(payload)
    # Fragment across many kernel reads, without making runtime proportional to sleeps.
    result, _ = exchange(cli, reply_handler([wire[i:i + 32749] for i in range(0, len(wire), 32749)], delay=0),
                         deadline_ms=20000)
    assert_success(result, payload)


def test_error_reply(cli):
    result, record = exchange(cli, reply_handler([frame(error={"code": "fixture_error", "message": "line one\n界"})]))
    assert result.returncode != 0 and b"fixture_error" in result.stderr
    assert record["client_closed"] - record["sent"] < 0.100


def test_preprotocol_error(cli):
    result, _ = exchange(cli, reply_handler([b"ERROR: Access denied by fixture\n"]))
    assert result.returncode != 0 and b"ERROR: Access denied by fixture" in result.stderr


def test_eof_without_newline(cli):
    result, record = exchange(cli, reply_handler([frame({"eof": True})[:-1]], close=True))
    assert_success(result, {"eof": True})
    assert record["peer_closed"]


def test_unterminated_open_peer(cli):
    result, record = exchange(cli, reply_handler([frame({"open": True})[:-1]]), deadline_ms=180)
    assert result.returncode != 0 and b"c11: timeout:" in result.stderr, result.stderr
    assert 0.12 < record["client_closed"] - record["sent"] < 1


def test_slow_drip_deadline(cli):
    def serve(conn, request, record, stopped):
        request()
        # Every fragment arrives inside the per-read timeout. The total deadline
        # must still expire rather than being reset by each arriving byte.
        for chunk in [b'{"result":', b'{"text":', b'"', b'a', b'b', b'c', b'd']:
            if select.select([conn], [], [], 0.06)[0]:
                record_client_close(conn, record)
                return
            try:
                conn.sendall(chunk)
            except BrokenPipeError:
                record_client_close(conn, record)
                return
        record_client_close(conn, record)
    result, record = exchange(cli, serve, deadline_ms=180)
    assert result.returncode != 0 and b"c11: timeout:" in result.stderr, result.stderr
    latency = record["client_closed"] - record["request_received"]
    assert latency < 0.5, record
    print(f"  request to client socket close: {latency * 1000:.1f} ms")


def test_sequential_replies(cli):
    def serve(conn, request, record, stopped):
        first = request()
        conn.sendall(frame(CAPS, request_id=first["id"]))
        second = request()
        conn.sendall(frame({"second": True}, request_id=second["id"]))
    result, record = exchange(cli, serve, method="fixture.echo")
    assert_success(result, {"second": True})
    assert record["requests"] == ["system.capabilities", "fixture.echo"], record


def test_coalesced_frames(cli):
    def serve(conn, request, record, stopped):
        first = request()
        # Synthetic prequeued second frame tests byte ownership, not request-id
        # validation. The current client does not correlate response IDs.
        conn.sendall(frame(CAPS, request_id=first["id"]) + frame({"queued": True}))
        request()
    result, record = exchange(cli, serve, method="fixture.echo")
    assert_success(result, {"queued": True})
    assert record["requests"] == ["system.capabilities", "fixture.echo"], record


def main():
    cli = os.environ.get("C11_CLI_BIN")
    if not cli or not Path(cli).is_absolute() or not os.access(cli, os.X_OK):
        raise RuntimeError("C11_CLI_BIN must name an explicit absolute executable")
    tests = [test_fast_open_peer] if "--fast-only" in sys.argv else [
        test_fast_open_peer, test_newline_alone, test_fragmented_utf8, test_large_reply,
        test_error_reply, test_preprotocol_error, test_eof_without_newline,
        test_unterminated_open_peer, test_slow_drip_deadline,
        test_sequential_replies, test_coalesced_frames,
    ]
    failures = []
    for test in tests:
        try:
            test(cli)
            print(f"PASS: {test.__name__}", flush=True)
        except Exception as exc:
            failures.append(test.__name__)
            print(f"FAIL: {test.__name__}: {exc}", flush=True)
    print(f"{len(tests) - len(failures)}/{len(tests)} passed", flush=True)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
