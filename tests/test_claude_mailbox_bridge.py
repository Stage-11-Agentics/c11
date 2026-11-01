#!/usr/bin/env python3
"""Exercise the shipped CLI bridge against two disposable Unix peers.
Run on Atlas: C11_TEST_CLI=/absolute/path/to/built/c11 python3 tests/test_claude_mailbox_bridge.py
The live c11 app and all tenant configuration are outside this test.
Needs node: the invitation is read from the shipped native-mail transport.
"""
from __future__ import annotations
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import json
from datetime import datetime, timezone
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

TRANSPORT = Path(__file__).resolve().parents[1] / "Resources" / "bin" / "mailbox-native.mjs"


def transport_doorbell() -> str:
    # The omp, Pi and OpenCode transport accepts only this text. Every test
    # below sends it, so the Claude bridge must accept the same line.
    script = f"import {{ doorbellText }} from {json.dumps(TRANSPORT.as_uri())}; process.stdout.write(doorbellText)"
    return subprocess.run(["node", "--input-type=module", "-e", script],
                          check=True, capture_output=True, text=True, timeout=10).stdout


INVITATION = transport_doorbell()


class Peer:
    def __init__(self, path: Path):
        self.path = path
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen()
        self.server.settimeout(3)
        self.connection = None
        self.pending = b""

    def accept(self):
        self.connection, _ = self.server.accept()
        self.connection.settimeout(3)
        return self

    def send(self, value):
        self.connection.sendall(json.dumps(value).encode() + b"\n")

    def read(self, timeout=3):
        self.connection.settimeout(timeout)
        while b"\n" not in self.pending:
            data = self.connection.recv(4096)
            if not data:
                raise EOFError("peer closed")
            self.pending += data
        line, self.pending = self.pending.split(b"\n", 1)
        if line == b"auth test-only-app-password":
            self.connection.sendall(b"OK\n")
            return self.read(timeout=timeout)
        return json.loads(line)

    def close(self):
        if self.connection:
            self.connection.close()
            self.connection = None
        self.server.close()


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-472-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.session = str(uuid.uuid4())
        self.transcript = self.root / (self.session + ".jsonl")
        self.app = Peer(self.root / "app.sock")
        self.inbox = Peer(self.root / "inbox.sock")
        self.harness = subprocess.Popen(["/bin/sleep", "60"])
        self.process = None
        self.errors = []
        self.workers = []

    def tearDown(self):
        for worker in self.workers:
            worker.join(timeout=3)
        self.app.close()
        self.inbox.close()
        for process in [self.process, self.harness]:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            if process:
                for pipe in [process.stdin, process.stdout, process.stderr]:
                    if pipe:
                        pipe.close()
        for worker in self.workers:
            worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
        self.tmp.cleanup()
        self.assertEqual(self.errors, [])

    def launch(self, **overrides):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("C11_", "CMUX_", "CLAUDE_CODE_MESSAGING_"))}
        env.update(C11_SOCKET=str(self.app.path), C11_PANEL_ID=str(uuid.uuid4()),
                   C11_AGENT_INTERACTIVE_PID=str(self.harness.pid),
                   CLAUDE_CODE_MESSAGING_SOCKET=str(self.inbox.path),
                   CLAUDE_CODE_MESSAGING_TOKEN="test-only-inbox-token")
        env.update(overrides)
        self.process = subprocess.Popen([os.environ["C11_TEST_CLI"], "--password", "test-only-app-password", "claude-mailbox"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.process.stdin.write(json.dumps({"hook_event_name": "SessionStart", "session_id": self.session,
                                            "transcript_path": str(self.transcript)}).encode())
        self.process.stdin.close()
        return self.process

    def subscribe(self):
        self.app.accept()
        request = self.app.read()
        self.assertEqual(request["method"], "mailbox.native.subscribe")
        self.assertEqual(request["params"]["route"], "claude_inbox")
        self.assertFalse(request["params"]["can_queue"])
        self.assertEqual(request["params"]["agent_pid"], self.harness.pid)
        self.app.send({"id": request["id"], "ok": True, "result": {"connection_id": str(uuid.uuid4())}})

    def append(self, session=None, peer=True):
        content = INVITATION
        if peer:
            content = "Another Claude session sent a message:\n" + content + "\n\nPeer permissions."
        with self.transcript.open("a") as file:
            file.write(json.dumps({"type": "user", "sessionId": session or self.session,
                                   "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                                   "message": {"role": "user", "content": content}}) + "\n")

    def receive_invitation(self, *, confirm=True, wrong_session=False, delay_read=0,
                           token="test-only-inbox-token"):
        def work():
            try:
                self.inbox.accept()
                connection = self.inbox.connection
                time.sleep(delay_read)
                self.assertEqual(self.inbox.read(), {"type": "auth", "token": token})
                self.assertEqual(self.inbox.read(), {"type": "user", "message": {"role": "user", "content": INVITATION}})
                if confirm:
                    self.append(session=str(uuid.uuid4()) if wrong_session else None)
                connection.close()
                if self.inbox.connection is connection:
                    self.inbox.connection = None
            except Exception as error:
                self.errors.append(repr(error))
        worker = threading.Thread(target=work)
        worker.start()
        self.workers.append(worker)

    def offer(self):
        delivery = str(uuid.uuid4())
        self.app.send({"type": "deliver", "delivery_id": delivery, "text": INVITATION})
        return delivery

    def assert_quiet_exit(self):
        self.assertEqual(self.process.wait(timeout=3), 0)
        self.assertEqual(self.process.stdout.read(), b"")
        self.assertEqual(self.process.stderr.read(), b"")

    def assert_no_subscription(self):
        self.app.server.settimeout(.15)
        with self.assertRaises(socket.timeout):
            connection, _ = self.app.server.accept()
            connection.close()

    def test_repeat_acceptance_and_listener_retirement(self):
        self.launch()
        self.subscribe()
        for _ in range(2):
            self.receive_invitation()
            delivery = self.offer()
            self.assertEqual(self.app.read(timeout=2), {"type": "accepted", "delivery_id": delivery})
            self.workers[-1].join(timeout=2)
        self.app.connection.close()
        self.app.connection = None
        self.assert_quiet_exit()

    def test_unknown_frame_does_not_retire_live_subscription(self):
        self.launch()
        self.subscribe()
        self.app.send({"type": "heartbeat"})
        self.receive_invitation()
        delivery = self.offer()
        self.assertEqual(self.app.read(timeout=2), {"type": "accepted", "delivery_id": delivery})

    def test_replaced_frame_retires_without_waiting_for_socket_close(self):
        self.launch()
        self.subscribe()
        self.app.send({"type": "replaced"})
        self.assert_quiet_exit()

    def test_inbox_write_uses_remaining_two_second_deadline(self):
        token = "x" * (16 * 1024)
        self.inbox.server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
        self.launch(CLAUDE_CODE_MESSAGING_TOKEN=token)
        self.subscribe()
        self.receive_invitation(delay_read=1.25, token=token)
        delivery = self.offer()
        self.assertEqual(self.app.read(timeout=2.5), {"type": "accepted", "delivery_id": delivery})

    def assert_unconfirmed(self, delivery):
        # Reported inside the app's two-second bound, then never acknowledged.
        started = time.monotonic()
        self.assertEqual(self.app.read(timeout=2.4), {"type": "rejected", "delivery_id": delivery,
                                                    "reason": "unconfirmed"})
        self.assertLess(time.monotonic() - started, 2.0)
        with self.assertRaises(socket.timeout):
            self.app.read(timeout=1)

    def test_old_and_wrong_session_records_do_not_acknowledge(self):
        self.append()
        self.launch()
        self.subscribe()
        self.receive_invitation(wrong_session=True)
        self.assert_unconfirmed(self.offer())

    def test_successful_socket_write_without_harness_acceptance_is_not_ack(self):
        self.launch()
        self.subscribe()
        self.receive_invitation(confirm=False)
        self.assert_unconfirmed(self.offer())

    def test_late_confirmation_after_unconfirmed_is_accepted(self):
        self.launch()
        self.subscribe()
        self.receive_invitation(confirm=False)
        delivery = self.offer()
        self.assertEqual(self.app.read(timeout=2.4), {"type": "rejected", "delivery_id": delivery,
                                                    "reason": "unconfirmed"})
        self.workers[-1].join(timeout=2)
        self.append()
        self.assertEqual(self.app.read(timeout=1), {"type": "accepted", "delivery_id": delivery})

    def test_new_offer_ends_the_late_watch(self):
        self.launch()
        self.subscribe()
        self.receive_invitation(confirm=False)
        first = self.offer()
        self.assertEqual(self.app.read(timeout=2.4)["delivery_id"], first)
        self.workers[-1].join(timeout=2)
        self.receive_invitation()
        second = self.offer()
        self.assertEqual(self.app.read(timeout=2), {"type": "accepted", "delivery_id": second})
        with self.assertRaises(socket.timeout):
            self.app.read(timeout=.5)

    def test_unreadable_transcript_rejects_as_transcript_unavailable(self):
        self.transcript.write_text("")
        self.transcript.chmod(0)
        self.launch()
        self.subscribe()
        delivery = self.offer()
        self.assertEqual(self.app.read(timeout=2), {"type": "rejected", "delivery_id": delivery,
                                                  "reason": "transcript_unavailable"})
        self.assert_inbox_untouched()

    def test_stalled_inbox_write_rejects_as_inbox_write_failed(self):
        token = "x" * (16 * 1024)
        self.inbox.server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
        self.launch(CLAUDE_CODE_MESSAGING_TOKEN=token)
        self.subscribe()
        delivery = self.offer()
        self.inbox.accept()  # Accepts and never reads, so the auth line stalls.
        self.assertEqual(self.app.read(timeout=2.4), {"type": "rejected", "delivery_id": delivery,
                                                    "reason": "inbox_write_failed"})

    def assert_inbox_untouched(self):
        self.inbox.server.settimeout(.15)
        with self.assertRaises(socket.timeout):
            connection, _ = self.inbox.server.accept()
            connection.close()

    def test_missing_feature_exits_without_connecting(self):
        self.launch(CLAUDE_CODE_MESSAGING_TOKEN="")
        self.assert_quiet_exit()
        self.assert_no_subscription()

    def test_headless_launch_exits_without_connecting(self):
        self.launch(C11_AGENT_INTERACTIVE_PID="")
        self.assert_quiet_exit()
        self.assert_no_subscription()

    def test_harness_exit_retires_idle_bridge(self):
        self.launch()
        self.subscribe()
        self.harness.terminate()
        self.harness.wait(timeout=3)
        self.assert_quiet_exit()

    def test_missing_inbox_rejects_without_delivery(self):
        self.launch(CLAUDE_CODE_MESSAGING_SOCKET=str(self.root / "missing.sock"))
        self.subscribe()
        delivery = self.offer()
        self.assertEqual(self.app.read(timeout=2), {"type": "rejected", "delivery_id": delivery,
                                                  "reason": "inbox_unavailable"})

    def test_old_app_exits_quietly(self):
        self.launch()
        self.app.accept()
        request = self.app.read()
        self.app.send({"id": request["id"], "ok": False, "error": {"code": "unknown_method"}})
        self.assert_quiet_exit()


if __name__ == "__main__":
    if not Path(os.environ.get("C11_TEST_CLI", "")).is_file():
        raise SystemExit("Set C11_TEST_CLI to the Atlas-built CLI")
    unittest.main(verbosity=2)
