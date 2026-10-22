#!/usr/bin/env python3
"""Exercise `c11 codex-mailbox-proxy` between a fake Codex TUI, a fake Codex app
server and a fake c11 socket, all disposable Unix peers owned by this test.
Run on Atlas: C11_TEST_CLI=/absolute/path/to/built/c11 python3 tests/test_codex_mailbox_proxy.py
The live c11 app, the real codex binary and all tenant configuration are outside this test.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

INVITATION = "You have mail: run c11 mailbox recv --ack when you want to receive it."
PASSWORD = "test-only-app-password"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SETTLE = 0.1  # lets the proxy parse a frame the TUI has already received


# --- WebSocket framing -------------------------------------------------------

def ws_accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def xor_mask(data: bytes, key: bytes) -> bytes:
    if not data:
        return b""
    repeated = (key * (len(data) // 4 + 1))[:len(data)]
    return (int.from_bytes(data, "big") ^ int.from_bytes(repeated, "big")).to_bytes(len(data), "big")


def ws_encode(payload: bytes, *, mask: bool, opcode: int = 1) -> bytes:
    header = bytearray([0x80 | opcode])
    bit = 0x80 if mask else 0
    n = len(payload)
    if n < 126:
        header.append(bit | n)
    elif n < 65536:
        header.append(bit | 126)
        header += struct.pack(">H", n)
    else:
        header.append(bit | 127)
        header += struct.pack(">Q", n)
    if mask:
        key = os.urandom(4)
        header += key
        payload = xor_mask(payload, key)
    return bytes(header) + payload


def ws_decode_one(buf: bytes):
    """Return (fin, opcode, masked, payload, consumed) or None when incomplete."""
    if len(buf) < 2:
        return None
    b0, b1 = buf[0], buf[1]
    fin, opcode, masked, length, pos = bool(b0 & 0x80), b0 & 0x0F, bool(b1 & 0x80), b1 & 0x7F, 2
    if length == 126:
        if len(buf) < 4:
            return None
        length, pos = struct.unpack(">H", buf[2:4])[0], 4
    elif length == 127:
        if len(buf) < 10:
            return None
        length, pos = struct.unpack(">Q", buf[2:10])[0], 10
    key = b""
    if masked:
        if len(buf) < pos + 4:
            return None
        key, pos = buf[pos:pos + 4], pos + 4
    if len(buf) < pos + length:
        return None
    payload = buf[pos:pos + length]
    if masked:
        payload = xor_mask(payload, key)
    return fin, opcode, masked, payload, pos + length


class WSReader:
    """Reassembles messages; yields (opcode, payload, every_frame_masked)."""

    def __init__(self):
        self.buf = b""
        self.fragments = b""
        self.fragment_opcode = None
        self.fragment_masked = True

    def feed(self, data: bytes):
        self.buf += data
        out = []
        while True:
            frame = ws_decode_one(self.buf)
            if frame is None:
                return out
            fin, opcode, masked, payload, consumed = frame
            self.buf = self.buf[consumed:]
            if opcode >= 8:
                out.append((opcode, payload, masked))
                continue
            if opcode != 0:
                self.fragment_opcode, self.fragments, self.fragment_masked = opcode, b"", True
            self.fragments += payload
            self.fragment_masked = self.fragment_masked and masked
            if fin:
                out.append((self.fragment_opcode, self.fragments, self.fragment_masked))
                self.fragments, self.fragment_opcode = b"", None


def shutdown_close(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    sock.close()


# --- Fake c11 socket ---------------------------------------------------------

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
        if line == ("auth " + PASSWORD).encode():
            self.connection.sendall(b"OK\n")
            return self.read(timeout=timeout)
        return json.loads(line)

    def serve_in_background(self, stop: threading.Event):
        """Answer auth and subscribe on any connection, for tests that do not inspect c11."""
        def handle(connection):
            pending = b""
            connection.settimeout(0.2)
            while not stop.is_set():
                try:
                    data = connection.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not data:
                    return
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if line.startswith(b"auth "):
                        connection.sendall(b"OK\n")
                        continue
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    if "id" in request:
                        connection.sendall(json.dumps({"id": request["id"], "ok": True,
                                                       "result": {"subscription_id": str(uuid.uuid4())}}).encode() + b"\n")

        def loop():
            self.server.settimeout(0.2)
            connections = []
            while not stop.is_set():
                try:
                    connection, _ = self.server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                connections.append(connection)
                threading.Thread(target=handle, args=(connection,), daemon=True).start()
            for connection in connections:
                shutdown_close(connection)

        worker = threading.Thread(target=loop, daemon=True)
        worker.start()
        return worker

    def close(self):
        if self.connection:
            self.connection.close()
            self.connection = None
        self.server.close()


# --- Fake Codex app server ---------------------------------------------------

class ServerConn:
    def __init__(self, server, sock, index):
        self.server = server
        self.sock = sock
        self.index = index
        self.request_line = ""
        self.headers = {}
        self.handshaken = False
        self.is_tui = False
        self.closed = threading.Event()
        self.send_lock = threading.Lock()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def send_text(self, text: str, value=None):
        # Recorded before the write, so anything the proxy does in reaction sorts after it.
        self.server.record("send", self, value if value is not None else json.loads(text), text.encode(), False)
        with self.send_lock:
            self.sock.sendall(ws_encode(text.encode(), mask=False))

    def send(self, value):
        self.send_text(json.dumps(value), value)

    def run(self):
        try:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return
                head += chunk
            head, rest = head.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            self.request_line = lines[0]
            for line in lines[1:]:
                name, _, value = line.partition(":")
                self.headers[name.strip().lower()] = value.strip()
            response = ("HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n"
                        "sec-websocket-accept: %s\r\n\r\n" % ws_accept_key(self.headers.get("sec-websocket-key", "")))
            with self.send_lock:
                self.sock.sendall(response.encode())
            with self.server.cv:
                self.handshaken = True
                self.server.cv.notify_all()
            reader = WSReader()
            data = rest
            while True:
                for opcode, payload, masked in reader.feed(data):
                    if opcode == 8:
                        return
                    if opcode == 1:
                        self.server.on_message(self, payload, masked)
                data = self.sock.recv(65536)
                if not data:
                    return
        except OSError:
            pass
        except Exception as error:  # surfaced by tearDown
            self.server.errors.append("conn %d: %r" % (self.index, error))
        finally:
            # Like the real app server, hang up when the client does.
            self.closed.set()
            shutdown_close(self.sock)
            with self.server.cv:
                self.server.cv.notify_all()


class FakeCodexServer:
    """Speaks Codex's app-server WebSocket JSON-RPC on a Unix socket.

    queue_mode decides what follows a `thread/queue/add`:
      confirm: after confirm_delay the submission is consumed and turn/started reaches the TUI connection.
      stay:    the submission stays queued and nothing reaches the TUI.
      consume: the submission is consumed into an in-progress turn the TUI never hears about.
    """

    def __init__(self, path: Path):
        self.path = path
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(16)
        self.listener.settimeout(0.2)
        self.cv = threading.Condition()
        self.connections = []
        self.events = []
        self.seq = 0
        self.errors = []
        self.stop = threading.Event()
        self.timers = []
        self.thread_counter = 0
        self.queue = {}           # thread id -> [{"id", "clientUserMessageId"}]
        self.added = []           # (thread id, queued id, client id)
        self.consumed_turns = {}  # thread id -> turn dict for thread/turns/list
        self.queue_mode = "confirm"
        self.confirm_delay = 0.05
        self.accept_thread = threading.Thread(target=self.accept_loop, daemon=True)
        self.accept_thread.start()

    def accept_loop(self):
        while not self.stop.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.cv:
                conn = ServerConn(self, sock, len(self.connections))
                self.connections.append(conn)
                self.cv.notify_all()
            conn.thread.start()

    def record(self, kind, conn, msg, raw, masked):
        with self.cv:
            self.seq += 1
            self.events.append({"seq": self.seq, "t": time.monotonic(), "kind": kind, "conn": conn,
                                "msg": msg, "raw": raw, "masked": masked})
            self.cv.notify_all()

    def on_message(self, conn, payload, masked):
        msg = json.loads(payload)
        if msg.get("method") == "initialize" and \
                ((msg.get("params") or {}).get("clientInfo") or {}).get("name") == "codex-tui":
            conn.is_tui = True
        self.record("recv", conn, msg, payload, masked)
        if "method" in msg and "id" in msg:
            result = self.handle(conn, msg)
            if result is not None:
                conn.send({"id": msg["id"], "result": result})

    def handle(self, conn, msg):
        method, params = msg["method"], msg.get("params") or {}
        thread = params.get("threadId")
        if method == "initialize":
            return {"userAgent": "fake-codex/0.163.0"}
        if method in ("thread/start", "thread/resume", "thread/fork"):
            with self.cv:
                self.thread_counter += 1
                tid = thread if method == "thread/resume" and thread else "thr-%d" % self.thread_counter
            return {"thread": {"id": tid, "status": {"type": "idle"}, "ephemeral": bool(params.get("ephemeral"))}}
        if method == "thread/unsubscribe":
            return {"status": "unsubscribed"}
        if method == "thread/queue/add":
            qid = "q-" + uuid.uuid4().hex[:8]
            cid = params.get("clientUserMessageId")
            with self.cv:
                self.queue.setdefault(thread, []).append({"id": qid, "clientUserMessageId": cid})
                self.added.append((thread, qid, cid))
            conn.send({"id": msg["id"], "result": {"queuedSubmission": {"id": qid, "threadId": thread}}})
            if self.queue_mode == "confirm":
                self.later(self.confirm_delay, self.confirm, thread, qid)
            elif self.queue_mode == "consume":
                self.later(0.05, self.consume_silently, thread, qid, cid)
            return None
        if method == "thread/queue/list":
            with self.cv:
                return {"data": [{"id": q["id"], "threadId": thread} for q in self.queue.get(thread, [])]}
        if method == "thread/queue/delete":
            with self.cv:
                before = self.queue.get(thread, [])
                after = [q for q in before if q["id"] != params.get("queuedSubmissionId")]
                self.queue[thread] = after
            return {"deleted": len(after) != len(before)}
        if method == "thread/turns/list":
            with self.cv:
                turn = self.consumed_turns.get(thread)
            return {"data": [turn] if turn else []}
        if method == "turn/interrupt":
            return {}
        if method == "account/read":
            return {"account": None, "requiresOpenaiAuth": False}
        return {}

    def later(self, delay, fn, *args):
        timer = threading.Timer(delay, self.guard, (fn,) + args)
        timer.daemon = True
        self.timers.append(timer)
        timer.start()

    def guard(self, fn, *args):
        try:
            fn(*args)
        except OSError:
            pass
        except Exception as error:
            self.errors.append(repr(error))

    def pop_queued(self, thread, qid):
        with self.cv:
            self.queue[thread] = [q for q in self.queue.get(thread, []) if q["id"] != qid]

    def confirm(self, thread, qid):
        self.pop_queued(thread, qid)
        self.notify_tui("thread/status/changed", {"threadId": thread, "status": {"type": "active", "activeFlags": []}})
        self.notify_tui("turn/started", {"threadId": thread, "turn": {"id": "turn-" + qid, "status": "inProgress", "items": []}})

    def consume_silently(self, thread, qid, cid):
        self.pop_queued(thread, qid)
        with self.cv:
            self.consumed_turns[thread] = {"id": "turn-" + qid, "status": "inProgress",
                                           "items": [{"type": "userMessage", "id": "item-1", "clientId": cid,
                                                      "content": [{"type": "text", "text": INVITATION}]}]}

    def tui_conn(self):
        with self.cv:
            for conn in self.connections:
                if conn.is_tui and not conn.closed.is_set():
                    return conn
        return None

    def notify_tui(self, method, params):
        conn = self.tui_conn()
        if conn is None:
            raise AssertionError("no TUI connection upstream")
        conn.send({"method": method, "params": params})

    def run_turn(self, thread):
        turn = {"id": "turn-" + uuid.uuid4().hex[:8], "status": "inProgress", "items": []}
        self.notify_tui("thread/status/changed", {"threadId": thread, "status": {"type": "active", "activeFlags": []}})
        self.notify_tui("turn/started", {"threadId": thread, "turn": turn})
        self.notify_tui("turn/completed", {"threadId": thread, "turn": dict(turn, status="completed")})
        self.notify_tui("thread/status/changed", {"threadId": thread, "status": {"type": "idle"}})

    def find(self, kind=None, method=None, conn=None, after=0, pred=None):
        with self.cv:
            return [e for e in self.events
                    if e["seq"] > after and (kind is None or e["kind"] == kind)
                    and (method is None or e["msg"].get("method") == method)
                    and (conn is None or e["conn"] is conn)
                    and (pred is None or pred(e))]

    def wait_event(self, timeout=3, **filters):
        deadline = time.monotonic() + timeout
        with self.cv:
            while True:
                found = self.find(**filters)
                if found:
                    return found[0]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError("server never saw %r" % (filters,))
                self.cv.wait(remaining)

    def wait(self, predicate, timeout=3):
        with self.cv:
            if not self.cv.wait_for(predicate, timeout):
                raise AssertionError("server condition not reached")

    def requests(self, method):
        return [e["msg"] for e in self.find(kind="recv", method=method)]

    def close(self):
        self.stop.set()
        for timer in self.timers:
            timer.cancel()
        self.listener.close()
        self.accept_thread.join(timeout=3)
        with self.cv:
            connections = list(self.connections)
        for conn in connections:
            shutdown_close(conn.sock)
            conn.thread.join(timeout=3)


# --- Fake Codex TUI ----------------------------------------------------------

class FakeTUI:
    def __init__(self, path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect(str(path))
        self.key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET /rpc HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n" % self.key).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("proxy closed during handshake")
            head += chunk
        head, rest = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise AssertionError("handshake failed: %r" % lines[0])
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        if headers.get("sec-websocket-accept") != ws_accept_key(self.key):
            raise AssertionError("bad sec-websocket-accept: %r" % headers.get("sec-websocket-accept"))
        self.sock.settimeout(None)
        self.cv = threading.Condition()
        self.received = []  # (raw payload, decoded message)
        self.eof = False
        self.next_id = 0
        self.send_lock = threading.Lock()
        self.thread = threading.Thread(target=self.run, args=(rest,), daemon=True)
        self.thread.start()

    def run(self, data):
        reader = WSReader()
        try:
            while True:
                for opcode, payload, _ in reader.feed(data):
                    if opcode == 1:
                        with self.cv:
                            self.received.append((payload, json.loads(payload)))
                            self.cv.notify_all()
                data = self.sock.recv(65536)
                if not data:
                    break
        except OSError:
            pass
        finally:
            with self.cv:
                self.eof = True
                self.cv.notify_all()

    def send_text(self, text: str):
        with self.send_lock:
            self.sock.sendall(ws_encode(text.encode(), mask=True))

    def send(self, value):
        self.send_text(json.dumps(value))

    def request(self, method, params):
        with self.cv:
            self.next_id += 1
            rid = self.next_id
        self.send({"id": rid, "method": method, "params": params})
        return rid

    def mark(self):
        with self.cv:
            return len(self.received)

    def wait_for(self, predicate, timeout=3, start=0):
        deadline = time.monotonic() + timeout
        with self.cv:
            while True:
                for _, msg in self.received[start:]:
                    if predicate(msg):
                        return msg
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self.eof:
                    raise AssertionError("TUI never received the expected frame")
                self.cv.wait(remaining)

    def call(self, method, params, timeout=3):
        rid = self.request(method, params)
        return self.wait_for(lambda m: m.get("id") == rid and "method" not in m, timeout)["result"]

    def initialize(self):
        self.call("initialize", {"clientInfo": {"name": "codex-tui", "title": None, "version": "0.163.0"},
                                 "capabilities": {"experimentalApi": True}})
        self.send({"method": "initialized"})

    def start_thread(self, ephemeral=False, **extra):
        params = dict({"cwd": "/tmp", "ephemeral": ephemeral}, **extra)
        return self.call("thread/start", params)["thread"]["id"]

    def close(self):
        shutdown_close(self.sock)
        self.thread.join(timeout=3)


# --- Tests -------------------------------------------------------------------

class CodexMailboxProxyTests(unittest.TestCase):
    def setUp(self):
        self.sock_dir = Path(tempfile.mkdtemp(prefix="c11-470s-", dir="/tmp"))
        self.listen_dir = Path(tempfile.mkdtemp(prefix="c11-470-", dir="/tmp"))
        os.chmod(self.listen_dir, 0o700)
        self.listen = self.listen_dir / "tui.sock"
        self.links = []
        self.app = Peer(self.sock_dir / "app.sock")
        self.server = FakeCodexServer(self.sock_dir / "codex.sock")
        self.panel = str(uuid.uuid4())
        self.processes = []
        self.process = None
        self.harness = None
        self.tuis = []
        self.stop_background = threading.Event()
        self.background = []

    def tearDown(self):
        for tui in self.tuis:
            tui.close()
        for process in self.processes + ([self.harness] if self.harness else []):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        self.stop_background.set()
        for worker in self.background:
            worker.join(timeout=3)
        self.app.close()
        self.server.close()
        for link in self.links:
            if os.path.lexists(link):
                os.unlink(link)
        shutil.rmtree(self.listen_dir, ignore_errors=True)
        shutil.rmtree(self.sock_dir, ignore_errors=True)
        self.assertEqual(self.server.errors, [])

    # helpers

    def stderr(self):
        try:
            return (self.sock_dir / "proxy.stderr").read_text(errors="replace")[-2000:]
        except OSError:
            return ""

    def launch(self, agent_pid=None, listen=None, extra=()):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("C11_", "CMUX_"))}
        env.update(C11_SOCKET=str(self.app.path), C11_PANEL_ID=self.panel,
                   C11_AGENT_INTERACTIVE_PID=str(agent_pid if agent_pid is not None else os.getpid()))
        with open(self.sock_dir / "proxy.stderr", "ab") as err:
            self.process = subprocess.Popen(
                [os.environ["C11_TEST_CLI"], "--password", PASSWORD, "codex-mailbox-proxy",
                 "--listen", str(listen or self.listen), "--upstream", str(self.server.path), *extra],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, env=env)
        self.processes.append(self.process)
        return self.process

    def subscribe(self):
        self.app.accept()
        request = self.app.read()
        self.assertEqual(request["method"], "mailbox.native.subscribe")
        self.app.send({"id": request["id"], "ok": True, "result": {"subscription_id": str(uuid.uuid4())}})
        return request

    def wait_listen(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail("proxy exited %s before listening: %s" % (self.process.returncode, self.stderr()))
            try:
                if stat.S_ISSOCK(os.lstat(self.listen).st_mode):
                    return
            except FileNotFoundError:
                pass
            time.sleep(0.02)
        self.fail("proxy never created the listen socket")

    def start(self, agent_pid=None):
        self.launch(agent_pid)
        request = self.subscribe()
        self.wait_listen()
        return request

    def spawn_harness(self):
        self.harness = subprocess.Popen(["/bin/sleep", "60"])
        return self.harness

    def connect_tui(self):
        tui = FakeTUI(self.listen)
        self.tuis.append(tui)
        tui.initialize()
        return tui, tui.start_thread()

    def thread_status(self, tui, thread, status, start):
        tui.wait_for(lambda m: m.get("method") == "thread/status/changed"
                     and m["params"]["threadId"] == thread and m["params"]["status"]["type"] == status, start=start)
        time.sleep(SETTLE)

    def warm(self, tui, thread):
        mark = tui.mark()
        self.server.run_turn(thread)
        self.thread_status(tui, thread, "idle", mark)

    def offer(self):
        delivery = str(uuid.uuid4())
        self.app.send({"type": "deliver", "delivery_id": delivery, "text": INVITATION})
        return delivery

    def reply(self, delivery, timeout=3):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.fail("no reply for delivery %s: %s" % (delivery, self.stderr()))
            try:
                frame = self.app.read(timeout=remaining)
            except socket.timeout:
                continue
            if frame.get("delivery_id") == delivery:
                return frame

    def assert_no_reply(self, delivery, until):
        while True:
            remaining = until - time.monotonic()
            if remaining <= 0:
                return
            try:
                frame = self.app.read(timeout=remaining)
            except socket.timeout:
                return
            self.assertNotEqual(frame.get("delivery_id"), delivery, frame)

    def queue_add_threads(self):
        return [msg["params"]["threadId"] for msg in self.server.requests("thread/queue/add")]

    # 1
    def test_relays_frames_both_ways_unchanged(self):
        self.start()
        mode = os.lstat(self.listen).st_mode
        self.assertTrue(stat.S_ISSOCK(mode))
        self.assertEqual(stat.S_IMODE(mode), 0o600)
        tui = FakeTUI(self.listen)  # verifies sec-websocket-accept, so the key reached upstream intact
        self.tuis.append(tui)
        self.server.wait(lambda: any(c.handshaken for c in self.server.connections))
        # The proxy probes the upstream once at startup; that probe never upgrades.
        upstream = next(c for c in self.server.connections if c.handshaken)
        self.assertEqual(upstream.request_line, "GET /rpc HTTP/1.1")
        self.assertEqual(upstream.headers.get("sec-websocket-key"), tui.key)

        sent = [
            json.dumps({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "codex-tui", "title": None, "version": "0.163.0"},
                "capabilities": {"experimentalApi": True}, "note": "héllo ✓"}}, ensure_ascii=False),
            json.dumps({"method": "initialized"}),
            json.dumps({"id": 2, "method": "config/read", "params": {"pad": "m" * 300}}),
            json.dumps({"id": 3, "method": "config/read", "params": {"pad": "L" * 70000}}),
        ]
        for text in sent:
            tui.send_text(text)
        self.server.wait(lambda: len(self.server.find(kind="recv", conn=upstream)) >= len(sent))
        got = self.server.find(kind="recv", conn=upstream)
        self.assertEqual([e["raw"] for e in got], [t.encode() for t in sent])
        self.assertTrue(all(e["masked"] for e in got))
        # The three requests are answered before the notifications below go out.
        self.server.wait(lambda: len(self.server.find(kind="send", conn=upstream)) >= 3)

        down = [
            json.dumps({"method": "thread/started", "params": {"note": "☃"}}, ensure_ascii=False),
            json.dumps({"method": "item/agentMessage/delta", "params": {"delta": "d" * 300}}),
            json.dumps({"method": "item/agentMessage/delta", "params": {"delta": "D" * 70000}}),
        ]
        for text in down:
            upstream.send_text(text)
        expected = [e["raw"] for e in self.server.find(kind="send", conn=upstream)]
        self.assertEqual(expected[-len(down):], [t.encode() for t in down])
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with tui.cv:
                raws = [raw for raw, _ in tui.received]
            if len(raws) >= len(expected):
                break
            time.sleep(0.02)
        self.assertEqual(raws, expected)

    # 2
    def test_subscribe_frame_shape(self):
        self.launch()
        request = self.subscribe()
        self.assertIn("id", request)
        params = request["params"]
        self.assertEqual(params["route"], "codex_queue")
        self.assertIs(params["can_queue"], False)
        self.assertEqual(params["panel_id"], self.panel)
        self.assertEqual(params["agent_pid"], os.getpid())
        self.assertIsInstance(params["session_id"], str)

    # 3
    def test_warm_idle_displayed_thread_is_accepted(self):
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        delivery = self.offer()
        frame = self.reply(delivery)
        self.assertEqual(frame["type"], "accepted", frame)
        adds = self.server.find(kind="recv", method="thread/queue/add")
        self.assertEqual(len(adds), 1)
        add = adds[0]
        self.assertFalse(add["conn"].is_tui)
        self.assertEqual(add["msg"]["params"]["threadId"], thread)
        self.assertEqual(add["msg"]["params"]["input"], [{"type": "text", "text": INVITATION, "text_elements": []}])
        self.assertIsInstance(add["msg"]["params"]["clientUserMessageId"], str)
        self.assertTrue(add["msg"]["params"]["clientUserMessageId"])
        ring_methods = [e["msg"].get("method") for e in self.server.find(kind="recv", conn=add["conn"])]
        self.assertEqual(ring_methods[:3], ["initialize", "initialized", "thread/queue/add"])
        lists = self.server.find(kind="recv", method="thread/queue/list", after=add["seq"])
        self.assertTrue(lists and lists[0]["msg"]["params"]["threadId"] == thread)

    # 16
    def test_turn_completion_runs_the_notify_callback_without_text(self):
        handler = self.sock_dir / "notify-handler"
        calls = self.sock_dir / "notify-calls"
        handler.write_text("#!/bin/sh\nprintf '%s\\t%s\\n' \"$1\" \"$2\" >> " + str(calls) + "\n")
        handler.chmod(0o755)
        self.launch(extra=("--notify", str(handler)))
        self.subscribe()
        self.wait_listen()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not calls.exists():
            time.sleep(0.05)
        self.assertTrue(calls.exists(), "notify callback never ran")
        verb, payload = calls.read_text().splitlines()[0].split("\t")
        self.assertEqual(verb, "__c11-notify")
        payload = json.loads(payload)
        self.assertEqual(payload["type"], "agent-turn-complete")
        self.assertEqual(payload["thread-id"], thread)
        self.assertEqual(set(payload), {"type", "thread-id", "turn-id", "client"})

    # 4
    def test_new_thread_after_slash_new_is_the_target(self):
        self.start()
        tui, first = self.connect_tui()
        self.warm(tui, first)
        second = tui.start_thread()
        self.warm(tui, second)
        # Before the unsubscribe both threads are held; the latest start is the one on screen.
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "accepted")
        tui.call("thread/unsubscribe", {"threadId": first})
        self.warm(tui, second)  # the ring's turn finishes, so the thread is idle again
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "accepted")
        self.assertEqual(self.queue_add_threads(), [second, second])

    # 5
    def test_ephemeral_helper_thread_is_never_displayed(self):
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        helper = tui.start_thread(ephemeral=True, threadSource="thread_title")
        self.warm(tui, helper)
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "accepted")
        self.assertEqual(self.queue_add_threads(), [thread])

    # 6
    def test_thread_without_completed_turn_rejects_without_queueing(self):
        self.start()
        tui, _ = self.connect_tui()
        time.sleep(SETTLE)
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "rejected")
        self.assertEqual(self.queue_add_threads(), [])

    # 7
    def test_busy_thread_rejects_without_queueing(self):
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        mark = tui.mark()
        self.server.notify_tui("thread/status/changed", {"threadId": thread, "status": {"type": "active", "activeFlags": []}})
        self.thread_status(tui, thread, "active", mark)
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "rejected")
        self.assertEqual(self.queue_add_threads(), [])

    # 8
    def test_no_tui_rejects(self):
        self.start()
        delivery = self.offer()
        self.assertEqual(self.reply(delivery)["type"], "rejected")
        self.assertEqual(self.queue_add_threads(), [])

    # 9
    def test_ring_holds_only_subscription_changes(self):
        self.server.confirm_delay = 0.8
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        delivery = self.offer()
        add = self.server.wait_event(kind="recv", method="thread/queue/add")
        sent_at = time.monotonic()
        account = tui.request("account/read", {"refreshToken": False})
        gated = tui.request("thread/start", {"cwd": "/tmp", "ephemeral": False})
        tui_conn = self.server.tui_conn()
        passed = self.server.wait_event(timeout=0.5, kind="recv", conn=tui_conn,
                                        pred=lambda e: e["msg"].get("id") == account)
        self.assertLess(passed["t"] - sent_at, 0.4)
        self.assertEqual(self.reply(delivery, timeout=4)["type"], "accepted")
        held = self.server.wait_event(kind="recv", conn=tui_conn, method="thread/start",
                                      pred=lambda e: e["msg"].get("id") == gated)
        confirm = self.server.wait_event(kind="send", conn=tui_conn, method="turn/started", after=add["seq"])
        self.assertLess(passed["seq"], confirm["seq"])
        self.assertLess(confirm["seq"], held["seq"])
        self.assertGreaterEqual(held["t"], confirm["t"])
        tui.wait_for(lambda m: m.get("id") == gated and "result" in m)

    # 10
    def test_unconfirmed_queued_submission_is_withdrawn_and_rejected(self):
        self.server.queue_mode = "stay"
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        delivery = self.offer()
        self.assertEqual(self.reply(delivery, timeout=5)["type"], "rejected")
        self.assertEqual(len(self.server.added), 1)
        _, qid, _ = self.server.added[0]
        deletes = self.server.requests("thread/queue/delete")
        self.assertEqual(len(deletes), 1)
        self.assertEqual(deletes[0]["params"]["threadId"], thread)
        self.assertEqual(deletes[0]["params"]["queuedSubmissionId"], qid)
        self.assertEqual(self.server.queue.get(thread), [])
        self.assertEqual(self.server.requests("turn/interrupt"), [])

    # 11
    def test_consumed_unseen_submission_is_interrupted_without_reply(self):
        self.server.queue_mode = "consume"
        self.start()
        tui, thread = self.connect_tui()
        self.warm(tui, thread)
        offered = time.monotonic()
        delivery = self.offer()
        interrupt = self.server.wait_event(timeout=5, kind="recv", method="turn/interrupt")
        _, qid, _ = self.server.added[0]
        turns = self.server.find(kind="recv", method="thread/turns/list")
        self.assertTrue(turns and turns[0]["seq"] < interrupt["seq"])
        self.assertEqual(turns[0]["msg"]["params"]["threadId"], thread)
        self.assertEqual(interrupt["msg"]["params"], {"threadId": thread, "turnId": "turn-" + qid})
        self.assertEqual(self.server.requests("thread/queue/delete"), [])
        self.assert_no_reply(delivery, until=max(offered + 3, time.monotonic() + 0.5))

    # 12
    def test_tui_disconnect_exits_and_removes_listen_socket(self):
        self.start()
        tui, _ = self.connect_tui()
        tui.close()
        self.tuis.remove(tui)
        self.assertEqual(self.process.wait(timeout=5), 0, self.stderr())
        self.assertFalse(os.path.lexists(self.listen))

    # 13
    def test_agent_exit_retires_proxy(self):
        harness = self.spawn_harness()
        self.start(agent_pid=harness.pid)
        harness.terminate()
        harness.wait(timeout=3)
        self.process.wait(timeout=5)

    # 14
    def test_unsafe_listen_dir_exits_without_listening(self):
        self.background.append(self.app.serve_in_background(self.stop_background))
        link = Path(str(self.listen_dir) + "-link")
        os.symlink(self.listen_dir, link)
        self.links.append(link)
        cases = [("mode 0755", self.listen_dir, 0o755), ("symlinked dir", link, 0o700)]
        for name, directory, mode in cases:
            with self.subTest(name):
                os.chmod(self.listen_dir, mode)
                listen = directory / "tui.sock"
                process = self.launch(listen=listen)
                self.assertNotEqual(process.wait(timeout=5), 0, self.stderr())
                self.assertFalse(os.path.lexists(listen))
                self.assertFalse(os.path.lexists(self.listen))

    # 15
    def test_peer_outside_agent_tree_is_refused_before_upstream(self):
        harness = self.spawn_harness()
        self.start(agent_pid=harness.pid)
        probes = len(self.server.connections)  # the startup reachability probe
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3)
        try:
            client.connect(str(self.listen))
            try:
                client.sendall(b"GET /rpc HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                               b"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
                data = client.recv(65536)
            except (BrokenPipeError, ConnectionResetError):
                data = b""
            self.assertEqual(data, b"")
        finally:
            client.close()
        time.sleep(0.3)
        self.assertEqual(len(self.server.connections), probes)


    # 17
    def test_slow_add_reply_reconciles_before_switch(self):
        original = self.server.handle

        def slow_add(conn, msg):
            if msg["method"] != "thread/queue/add":
                return original(conn, msg)
            thread, cid = msg["params"]["threadId"], msg["params"]["clientUserMessageId"]
            qid = "q-slow"
            with self.server.cv:
                self.server.queue.setdefault(thread, []).append({"id": qid, "clientUserMessageId": cid})
                self.server.added.append((thread, qid, cid))
            # The daemon took the write; its reply comes after the relay's add deadline.
            self.server.later(1.2, conn.send, {"id": msg["id"], "result": {"queuedSubmission": {"id": qid}}})

            def consume_if_pending():
                if any(q["id"] == qid for q in self.server.queue.get(thread, [])):
                    self.server.consume_silently(thread, qid, cid)
            self.server.later(2.4, consume_if_pending)
            return None

        self.server.handle = slow_add
        self.start()
        tui, old = self.connect_tui()
        self.warm(tui, old)
        offered = time.monotonic()
        delivery = self.offer()
        self.server.wait_event(kind="recv", method="thread/queue/add")
        gated = tui.request("thread/start", {"cwd": "/tmp", "ephemeral": False})
        self.assertEqual(self.reply(delivery)["type"], "rejected")
        tui.wait_for(lambda m: m.get("id") == gated and "result" in m, timeout=4)
        time.sleep(max(0, offered + 3 - time.monotonic()))
        self.assertEqual(self.server.queue.get(old), [])
        self.assertNotIn(old, self.server.consumed_turns)
        delete = self.server.wait_event(kind="recv", method="thread/queue/delete")
        self.assertEqual(delete["msg"]["params"], {"threadId": old, "queuedSubmissionId": "q-slow"})
        switch = self.server.wait_event(kind="recv", conn=self.server.tui_conn(), pred=lambda e: e["msg"].get("id") == gated)
        self.assertLess(delete["seq"], switch["seq"])

    # 18
    def test_failed_interrupt_holds_switch(self):
        self.server.queue_mode = "consume"
        original = self.server.handle
        attempts = []

        def flaky_interrupt(conn, msg):
            if msg["method"] != "turn/interrupt":
                return original(conn, msg)
            attempts.append(msg["params"]["turnId"])
            if len(attempts) == 1:
                conn.send({"id": msg["id"], "error": {"code": -32000, "message": "temporarily unavailable"}})
                return None
            self.server.consumed_turns[msg["params"]["threadId"]]["status"] = "interrupted"
            return {}

        self.server.handle = flaky_interrupt
        self.start()
        tui, old = self.connect_tui()
        self.warm(tui, old)
        offered = time.monotonic()
        delivery = self.offer()
        self.server.wait_event(kind="recv", method="thread/queue/add")
        gated = tui.request("thread/start", {"cwd": "/tmp", "ephemeral": False})
        tui.wait_for(lambda m: m.get("id") == gated and "result" in m, timeout=6)
        self.assertEqual(len(attempts), 2)
        self.assertEqual(self.server.consumed_turns[old]["status"], "interrupted")
        interrupts = self.server.find(kind="recv", method="turn/interrupt")
        switch = self.server.wait_event(kind="recv", conn=self.server.tui_conn(), pred=lambda e: e["msg"].get("id") == gated)
        self.assertLess(interrupts[-1]["seq"], switch["seq"])
        self.assert_no_reply(delivery, until=max(offered + 3, time.monotonic() + 0.3))

    # 19
    def test_turns_list_without_items_holds_switch(self):
        self.check_unmatched_turn_rows_hold_switch(lambda turn: {"id": turn["id"], "status": turn["status"]})

    # 20
    def test_turns_list_with_empty_items_holds_switch(self):
        # A turn can be listed before its user message item is published.
        self.check_unmatched_turn_rows_hold_switch(lambda turn: {"id": turn["id"], "status": turn["status"], "items": []})

    # 21
    def test_unseen_turn_of_another_message_is_not_interrupted(self):
        self.server.queue_mode = "consume"
        original = self.server.handle

        def foreign(conn, msg):
            thread = (msg.get("params") or {}).get("threadId")
            if msg["method"] == "thread/turns/list":
                turn = self.server.consumed_turns.get(thread)
                if turn is None:
                    return {"data": []}
                return {"data": [{"id": turn["id"], "status": turn["status"],
                                  "items": [{"type": "userMessage", "id": "item-9", "clientId": "someone-else"}]}]}
            return original(conn, msg)

        self.server.handle = foreign
        self.start()
        tui, old = self.connect_tui()
        self.warm(tui, old)
        self.offer()
        self.server.wait_event(kind="recv", method="thread/queue/add")
        gated = tui.request("thread/start", {"cwd": "/tmp", "ephemeral": False})
        time.sleep(3)
        self.assertEqual(self.server.requests("turn/interrupt"), [])
        self.assertFalse(self.server.find(kind="recv", conn=self.server.tui_conn(), pred=lambda e: e["msg"].get("id") == gated))
        self.server.consumed_turns[old]["status"] = "completed"  # once it ends, the switch goes through
        tui.wait_for(lambda m: m.get("id") == gated and "result" in m, timeout=5)

    def check_unmatched_turn_rows_hold_switch(self, row_for):
        self.server.queue_mode = "consume"
        original = self.server.handle
        lists = []
        interrupts = []

        def bare_lists(conn, msg):
            thread = (msg.get("params") or {}).get("threadId")
            if msg["method"] == "thread/turns/list":
                lists.append(msg)
                turn = self.server.consumed_turns.get(thread)
                if len(lists) == 1 or turn is None:
                    return {}  # an unreadable list says nothing
                return {"data": [row_for(turn)]}
            if msg["method"] == "turn/interrupt":
                interrupts.append(msg)
                if len(interrupts) == 1:
                    return None  # never answered: the relay must not treat it as done
                self.server.consumed_turns[thread]["status"] = "interrupted"
                return {}
            return original(conn, msg)

        self.server.handle = bare_lists
        self.start()
        tui, old = self.connect_tui()
        self.warm(tui, old)
        self.offer()
        self.server.wait_event(kind="recv", method="thread/queue/add")
        gated = tui.request("thread/start", {"cwd": "/tmp", "ephemeral": False})
        tui.wait_for(lambda m: m.get("id") == gated and "result" in m, timeout=8)
        self.assertGreaterEqual(len(lists), 2)
        self.assertEqual(len(interrupts), 2)
        self.assertEqual(interrupts[-1]["params"]["turnId"], self.server.consumed_turns[old]["id"])
        self.assertEqual(self.server.consumed_turns[old]["status"], "interrupted")
        last = self.server.find(kind="recv", method="turn/interrupt")[-1]
        switch = self.server.wait_event(kind="recv", conn=self.server.tui_conn(), pred=lambda e: e["msg"].get("id") == gated)
        self.assertLess(last["seq"], switch["seq"])

if __name__ == "__main__":
    if not Path(os.environ.get("C11_TEST_CLI", "")).is_file():
        raise SystemExit("Set C11_TEST_CLI to the Atlas-built CLI")
    unittest.main(verbosity=2)
