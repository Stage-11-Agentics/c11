#!/usr/bin/env python3
"""C11H-364 N11: the c11 CLI checks the listener's uid after connect.

Runs a built Debug CLI (C11_CLI=<path to .../Contents/Resources/bin/c11>)
against a fake socket this test binds in its own temporary folder. With the
Debug-only C11_DEBUG_EXPECT_PEER_UID naming another uid, the listener stands
in for one another account planted: the CLI must refuse before sending a byte.
The control, with no override, talks to the same socket. Launches no app and
signals nothing.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


class FakeListener:
    def __init__(self, path: str) -> None:
        self.received = bytearray()
        self.connections = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.stopped = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while not self.stopped:
            try:
                conn, _ = self.sock.accept()
            except (socket.timeout, OSError):
                continue
            self.connections += 1
            conn.settimeout(2)
            try:
                while True:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    self.received.extend(chunk)
                    if b"\n" in chunk:
                        conn.sendall(b"PONG\n")
            except OSError:
                pass
            finally:
                conn.close()

    def close(self) -> None:
        self.stopped = True
        self.thread.join(2)
        self.sock.close()


@unittest.skipUnless(os.environ.get("C11_CLI"), "set C11_CLI to a built Debug c11 CLI")
class CLIPeerUIDTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        self.root = tempfile.mkdtemp(prefix="u364c.", dir=temp or None)
        self.path = os.path.join(self.root, "c11-fake.sock")
        self.listener = FakeListener(self.path)

    def tearDown(self) -> None:
        self.listener.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def run_cli(self, extra_env: dict) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
        env.update(extra_env)
        env["C11_QUIET_DISCOVERY"] = "1"
        return subprocess.run([os.environ["C11_CLI"], "--socket", self.path, "ping"],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_listener_run_by_another_user_is_refused_before_any_byte(self) -> None:
        result = self.run_cli({"C11_DEBUG_EXPECT_PEER_UID": str(os.getuid() + 1)})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("another user's process", result.stderr)
        self.assertEqual(bytes(self.listener.received), b"", "the CLI sent bytes to a foreign listener")

    def test_listener_run_by_this_user_is_used(self) -> None:
        result = self.run_cli({})
        self.assertGreater(len(self.listener.received), 0, result.stderr)
        self.assertNotIn("another user's process", result.stderr)


if __name__ == "__main__":
    sys.exit(unittest.main())
