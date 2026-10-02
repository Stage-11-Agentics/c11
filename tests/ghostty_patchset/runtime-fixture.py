#!/usr/bin/env python3
"""Bounded C11-294 probes. Explicit tagged app and socket peer verification."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import select
import shlex
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import threading
import time
import tty
import traceback
import uuid

HERE = Path(__file__).resolve()
START, END = b"\x1b[200~", b"\x1b[201~"
CLOCK_NAME = "CLOCK_MONOTONIC_RAW"
METRIC_FIELDS = ("pty_ms", "read_screen_ms", "key_to_pty_ms",
                 "key_to_read_screen_ms", "invocation_to_key_post_ms")


def shared_ns():
    # macOS Python 3.9 monotonic_ns() can use a process-local epoch. RAW is a
    # kernel clock shared by the controller and independently launched workers.
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)


def verify_shared_clock():
    before = shared_ns()
    child = int(subprocess.check_output([
        sys.executable, "-c", "import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW))"
    ], text=True, timeout=3).strip())
    after = shared_ns()
    if not before <= child <= after:
        raise RuntimeError("parent/child RAW clock samples do not share an epoch")
    return {"clock": CLOCK_NAME, "parent_before_ns": before, "child_ns": child, "parent_after_ns": after}


def save(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def ps(pid, field):
    return subprocess.run(["/bin/ps", "-p", str(pid), "-o", field + "="],
                          capture_output=True, text=True, timeout=2).stdout.strip()


def worker(args):
    # Each child independently terminates even if the controller is killed.
    signal.signal(signal.SIGALRM, lambda *_: os._exit(124))
    signal.alarm(180)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    mode = args.mode
    identity = {"pid": os.getpid(), "pgrp": os.getpgrp(),
                "started": ps(os.getpid(), "lstart"), "mode": mode, "clock": CLOCK_NAME}
    if mode.startswith("shutdown"):
        def hup(*_):
            (out / "hup-observed").write_text("HUP\n")
            raise SystemExit(0)
        signal.signal(signal.SIGHUP, hup if mode in ("shutdown-graceful", "shutdown-detached") else signal.SIG_IGN)
        if mode == "shutdown-ignore-both":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode == "shutdown-detached":
            pid = os.fork()
            if pid == 0:
                os.setsid()
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                # POSIX alarm timers are not inherited across fork.
                signal.alarm(120)
                null = os.open(os.devnull, os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(null, fd)
                if null > 2:
                    os.close(null)
                save(out / "detached.json", {"pid": os.getpid(), "started": ps(os.getpid(), "lstart")})
                while True:
                    (out / "heartbeat").write_text(str(shared_ns()))
                    time.sleep(.1)
            deadline = time.monotonic() + 3
            while not (out / "detached.json").exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("detached child failed to start")
                time.sleep(.01)
        save(out / "ready.json", identity)
        while True:
            time.sleep(.1)
    if mode == "stream":
        save(out / "ready.json", identity)
        for i in range(180 * 20):
            # Fixed 20 Hz / ~10 KiB/s/terminal, plus one title change per second.
            frame = (f"stream {i:06d} " + "0123456789abcdef" * 30 + "\r\n").encode()
            os.write(1, frame)
            if i % 20 == 0:
                os.write(1, f"\x1b]2;C11 stream {i}\x07".encode())
            time.sleep(.05)
        return
    previous = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        if mode == "probe":
            save(out / "ready.json", identity)
            pending = b""
            while True:
                chunk = os.read(0, 4096)
                received_ns = shared_ns()
                if not chunk:
                    raise EOFError("probe PTY input closed")
                with (out / "raw-input.bin").open("ab") as raw:
                    raw.write(chunk)
                pending += chunk.replace(b"\r", b"\n")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    # CRLF may be split across reads. Empty delimiter fragments
                    # carry no token; raw-input.bin retains their exact bytes.
                    if not line:
                        continue
                    if not re.fullmatch(rb"p[0-9]{6}", line):
                        raise RuntimeError("unexpected probe bytes: " + repr(line))
                    os.write(1, b"\r\nACK:" + line + b"\r\n")
                    save(out / "ack.json", {"token": line.decode(), "received_ns": received_ns, "clock": CLOCK_NAME})
        if mode != "paste":
            raise RuntimeError("unknown worker mode")
        done = threading.Event()
        os.write(1, b"\x1b[?2004h\r\nC11_PASTE_READY\r\n")
        save(out / "ready.json", identity)
        def queries():
            while not done.wait(.02):
                os.write(1, b"\x1b[6n")
        query_thread = threading.Thread(target=queries, daemon=True)
        query_thread.start()
        captured = bytearray()
        deadline = time.monotonic() + 25
        # Deliberately let the queued paste exceed PTY buffer capacity.
        time.sleep(2)
        end_seen = None
        try:
            while time.monotonic() < deadline:
                if select.select([0], [], [], .05)[0]:
                    block = os.read(0, 65536)
                    if not block:
                        break
                    captured.extend(block)
                if END in captured and end_seen is None:
                    end_seen = time.monotonic()
                    done.set()
                if end_seen is not None and time.monotonic() - end_seen > .3:
                    break
        finally:
            done.set()
            query_thread.join(timeout=1)
            (out / "received.bin").write_bytes(captured)
            os.write(1, b"\x1b[?2004l")
        save(out / "done.json", {"bytes": len(captured), "end_seen": end_seen is not None})
    finally:
        termios.tcsetattr(0, termios.TCSANOW, previous)


class RPC:
    def __init__(self, args):
        if sys.platform != "darwin":
            raise RuntimeError("requires macOS")
        self.args = args
        self.app = Path(args.app).resolve(strict=True)
        self.cli = Path(args.cli).resolve(strict=True)
        if args.local_tagged:
            if args.tag not in ("c11-294-base", "c11-294-ghostty"):
                raise RuntimeError("local mode is restricted to the two authorized C11-294 tags")
            if self.app.name != "c11 DEV " + args.tag + ".app":
                raise RuntimeError("local app filename does not match the exact authorized tag")
            if args.tag == "c11-294-base" and not args.comparison_only:
                raise RuntimeError("old-engine baseline requires --comparison-only; stubborn shutdown can hang it")
            expected_socket = f"/tmp/c11-debug-{args.tag}.sock"
            if Path("/tmp").resolve() not in Path(args.out).resolve().parents:
                raise RuntimeError("local evidence output must be a new directory below /tmp")
        else:
            if not args.run_id or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.run_id):
                raise RuntimeError("sandbox mode requires an explicit lowercase run-id")
            expected_root = Path.home() / "c11-sandbox" / "apps" / args.run_id
            if self.app.parent != expected_root:
                raise RuntimeError("app must be the explicit sandbox-up tagged bundle")
            expected_socket = f"/tmp/c11-sandbox-{args.run_id}.sock"
        if self.cli != self.app / "Contents/Resources/bin/c11":
            raise RuntimeError("CLI must be inside the explicitly supplied tagged bundle")
        with (self.app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        expected_id = "com.stage11.c11.debug." + re.sub(r"[^a-z0-9]+", ".", args.tag.lower()).strip(".")
        if info.get("CFBundleIdentifier") != expected_id:
            raise RuntimeError("bundle is not the requested tagged build")
        if args.socket != expected_socket:
            raise RuntimeError("socket must match the explicit sandbox run or authorized local tag")
        metadata = os.lstat(args.socket)
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise RuntimeError("target is not a socket owned by the guest user")
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(4)
        self.sock.connect(args.socket)
        # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=2.
        self.pid = struct.unpack("i", self.sock.getsockopt(0, 2, 4))[0]
        executable = Path(ps(self.pid, "comm")).resolve()
        if executable != self.app / "Contents/MacOS/c11":
            raise RuntimeError("socket peer executable does not match the tagged bundle")
        self.sequence = 0
        self.buffer = b""

    def call(self, method, params=None, timeout=4):
        self.sequence += 1
        self.sock.settimeout(timeout)
        self.sock.sendall((json.dumps({"id": self.sequence, "method": method, "params": params or {}}) + "\n").encode())
        while b"\n" not in self.buffer:
            part = self.sock.recv(65536)
            if not part:
                raise RuntimeError("target socket closed")
            self.buffer += part
        line, self.buffer = self.buffer.split(b"\n", 1)
        result = json.loads(line)
        if result.get("id") != self.sequence or not result.get("ok"):
            raise RuntimeError(str(result))
        return result.get("result") or {}


def wait_file(path, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        error_path = path.parent / "error.json"
        if error_path.exists():
            raise RuntimeError("worker failed: " + error_path.read_text())
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(.01)
    raise TimeoutError(str(path))


def percentiles(values):
    values = sorted(values)
    if not values:
        return None
    return {name: values[min(len(values) - 1, math.ceil(p * len(values)) - 1)]
            for name, p in (("p50", .5), ("p95", .95), ("p99", .99), ("max", 1))}


def controller(args):
    if bool(args.ui_driver) != bool(args.ui_window):
        raise RuntimeError("--ui-driver and --ui-window must be provided together")
    if args.ui_driver and not args.local_tagged:
        raise RuntimeError("UI driver input is restricted to explicit --local-tagged mode")
    if args.ui_driver:
        driver = Path(args.ui_driver)
        if not driver.is_absolute() or not driver.is_file() or not os.access(driver, os.X_OK) or args.ui_window <= 0:
            raise RuntimeError("UI driver requires an explicit absolute executable path and positive window ID")
        driver = driver.resolve(strict=True)
    else:
        driver = None
    clock_evidence = verify_shared_clock()
    rpc = RPC(args)  # Complete all target checks before any mutation.
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic() + 240
    workspaces, workers = [], []
    stream_identities = []
    run_token = uuid.uuid4().hex
    result = {"status": "FAIL", "label": args.label, "engine_sha_claim": args.engine_sha,
              "load_average_start": os.getloadavg(),
              "app": str(rpc.app), "bundle_binary_sha256": digest(rpc.app / "Contents/MacOS/c11"),
              "bundle_dylib_sha256": {path.name: digest(path) for path in sorted((rpc.app / "Contents/MacOS").glob("*.dylib")) if path.is_file()},
              "cli_sha256": digest(rpc.cli), "fixture_sha256": digest(HERE),
              "socket": args.socket, "pid": rpc.pid, "run_token": run_token,
              "target_mode": "local-tagged" if args.local_tagged else "sandbox",
              "comparison_only": args.comparison_only,
              "measurement_version": "shared-raw-return-post-focus-ready-v2",
              "metric_definitions": {
                  "pty_ms": "full input invocation start to child PTY receipt; includes driver startup/validation/text/Return overhead",
                  "read_screen_ms": "full input invocation start to read-screen observation; includes driver and polling overhead",
                  "key_to_pty_ms": "Return driver's first CGEvent post timestamp to child PTY receipt (UI mode only)",
                  "key_to_read_screen_ms": "Return driver's first CGEvent post timestamp to read-screen observation (UI mode only; includes polling)",
                  "invocation_to_key_post_ms": "input invocation start to Return post; driver startup/validation/text overhead (UI mode only)",
              },
              "input_mode": "appkit-quartz-pid-scoped" if driver else "socket-synthetic",
              "ui_driver": {"path": str(driver), "sha256": digest(driver), "window": args.ui_window,
                            "pid": rpc.pid, "tag": args.tag,
                            "measurement_includes": "driver spawn, target/focus validation, text event and Return event"} if driver else None,
              "guest_hardware": subprocess.run(["/usr/sbin/sysctl", "-n", "hw.ncpu", "hw.memsize"], capture_output=True, text=True, timeout=2).stdout.strip(),
              "clock_verification": clock_evidence,
              "workload": {"streams": args.streams, "hz_per_stream": 20, "samples": args.samples,
                           "launch": "workspace-initial-command", "workspaces_per_stream": 1},
              "limits": {"rpc_seconds": 4, "probe_seconds": 2, "ui_readiness_seconds": 2, "shutdown_seconds": 18},
              "not_proven": ["physical hardware keyboard latency", "app tick durations/message counts",
                             "GPU current frame or cursor visibility", "computer-use hide/show",
                             "B072 backend WouldBlock attribution", "completion-order injection",
                             "reaped-leader/stale-PGID/pre-setsid shutdown cases"]}
    env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
    def call(method, params=None, timeout=4):
        if time.monotonic() > deadline:
            raise TimeoutError("240-second controller budget")
        return rpc.call(method, params, timeout)
    def workspace(initial_command="/bin/sleep 1"):
        ws = call("workspace.create", {"initial_command": initial_command})["workspace_id"]
        workspaces.append(ws)
        tab = call("tab.list", {"workspace_id": ws})["tabs"][0]["id"]
        return ws, tab
    def params(pair):
        return {"workspace_id": pair[0], "tab_id": pair[1]}
    def launch(mode, name):
        directory = out / (run_token + "-" + name)
        command = shlex.join([sys.executable, str(HERE), "worker", "--mode", mode, "--out", str(directory)])
        # Start the worker as the surface command, never through an interactive
        # login shell whose rc setup would confound load and readiness.
        pair = workspace(command)
        identity = wait_file(directory / "ready.json")
        workers.append((directory, identity))
        return pair, directory, identity
    def read(pair):
        return call("tab.read_text", params(pair)).get("text", "")
    def ui_event(action, value):
        invoked = [str(driver), action, str(rpc.pid), args.tag, str(args.ui_window), value]
        completed = subprocess.run(invoked, capture_output=True, text=True, timeout=10)
        try:
            evidence = json.loads(completed.stdout)
        except json.JSONDecodeError:
            evidence = {"stdout": completed.stdout, "stderr": completed.stderr}
        if completed.returncode or evidence.get("status") != "posted":
            raise RuntimeError("PID-scoped UI driver failed: " + repr(evidence))
        if evidence.get("pid") != rpc.pid or evidence.get("window") != args.ui_window:
            raise RuntimeError("UI driver response target mismatch")
        return evidence
    def focus_ready(pair):
        # Observe convergence only: never refocus or retry input to make a
        # measurement pass. Focus setup time is separate from input latency.
        began = shared_ns()
        until = time.monotonic() + 2
        observations = []
        required = ("inWindow", "isFirstResponder", "desiredFocus", "appIsActive", "windowIsKey", "isActive")
        while time.monotonic() < until:
            observation = {"observed_ns": shared_ns()}
            try:
                stats = call("debug.terminal.render_stats", params(pair), timeout=max(.01, until - time.monotonic()))["stats"]
                observation["stats"] = stats
                ready = (str(stats.get("panelId", "")).lower() == pair[1].lower()
                         and all(stats.get(field) is True for field in required))
            except Exception as error:
                observation["error"] = repr(error)
                observations.append(observation)
                break
            observations.append(observation)
            if ready:
                return {"ready": True, "elapsed_ms": (shared_ns() - began) / 1e6, "observations": observations}
            time.sleep(.02)
        return {"ready": False, "elapsed_ms": (shared_ns() - began) / 1e6, "observations": observations}
    def miss_snapshot(pair, directory, token):
        snapshot = {"token": token, "observed_ns": shared_ns()}
        # Each observation is independent so an unavailable socket does not
        # discard the child's receipt evidence or the exact bytes received.
        for name, observe in (
            ("ack", lambda: json.loads((directory / "ack.json").read_text())),
            ("raw_input_hex", lambda: (directory / "raw-input.bin").read_bytes().hex()),
            ("read_screen", lambda: read(pair)),
            ("focus", lambda: call("debug.terminal.render_stats", params(pair))["stats"]),
        ):
            try:
                snapshot[name] = observe()
            except Exception as error:
                snapshot[name + "_error"] = repr(error)
        save(directory / ("miss-" + token + ".json"), snapshot)
        return snapshot
    def probe(pair, directory, index):
        token = f"p{index:06d}"
        readiness = focus_ready(pair) if driver else None
        if readiness is not None and not readiness["ready"]:
            return {"token": token, "missed": True, "stage": "focus_readiness", "input_sent": False,
                    "readiness": readiness, "snapshot": miss_snapshot(pair, directory, token)}
        start = shared_ns()
        driver_evidence = None
        if driver:
            # No global keyboard events or alternate target fallback. The driver
            # refuses mismatched PID/tag/window/AX focus before posting to PID.
            driver_evidence = [ui_event("text", token), ui_event("key", "return")]
        else:
            call("tab.send_text", {**params(pair), "text": token + "\n", "submit": False})
        key_post_ns = None
        if driver:
            key_post_ns = driver_evidence[-1].get("first_post_ns")
            if type(key_post_ns) is not int or not start <= key_post_ns <= shared_ns():
                raise RuntimeError("Return driver first_post_ns missing/invalid or outside invocation interval: " + repr(driver_evidence[-1]))
        end = time.monotonic() + 2
        while time.monotonic() < end:
            if (directory / "error.json").exists():
                raise RuntimeError("probe worker failed: " + (directory / "error.json").read_text())
            ack_path = directory / "ack.json"
            if ack_path.exists():
                ack = json.loads(ack_path.read_text())
                if ack["token"] == token and "ACK:" + token in read(pair):
                    observed_ns = shared_ns()
                    received_ns = ack.get("received_ns")
                    if (ack.get("clock") != CLOCK_NAME or type(received_ns) is not int
                            or not start <= received_ns <= observed_ns):
                        raise RuntimeError("probe ACK clock mismatch or timestamp outside invocation/observation interval: " + repr(ack))
                    if key_post_ns is not None and not start <= key_post_ns <= received_ns <= observed_ns:
                        raise RuntimeError("invalid timing order: invocation <= Return post <= PTY ACK <= observation required")
                    sample = {"token": token, "driver": driver_evidence, "readiness": readiness,
                              "clock": CLOCK_NAME,
                              "timing_ns": {"invocation_start": start, "return_first_post": key_post_ns,
                                            "pty_received": received_ns, "read_screen_observed": observed_ns},
                              "pty_ms": (received_ns - start) / 1e6,
                              "read_screen_ms": (observed_ns - start) / 1e6}
                    if key_post_ns is not None:
                        sample.update(key_to_pty_ms=(received_ns - key_post_ns) / 1e6,
                                      key_to_read_screen_ms=(observed_ns - key_post_ns) / 1e6,
                                      invocation_to_key_post_ms=(key_post_ns - start) / 1e6)
                    return sample
            time.sleep(.01)
        return {"token": token, "driver": driver_evidence, "missed": True,
                "stage": "ack_observation", "input_sent": True, "readiness": readiness,
                "snapshot": miss_snapshot(pair, directory, token),
                "clock": CLOCK_NAME, "timing_ns": {"invocation_start": start, "return_first_post": key_post_ns}}
    try:
        stream_ws = None
        for i in range(args.streams):
            pair, _, identity = launch("stream", f"stream-{i}")
            if stream_ws is None:
                stream_ws = pair[0]
            stream_identities.append(identity)
        probe_pair, probe_dir, _ = launch("probe", "probe")
        call("workspace.select", {"workspace_id": probe_pair[0]})
        call("tab.focus", params(probe_pair))
        samples = []
        start = time.monotonic()
        result["responsiveness"] = {"clock": CLOCK_NAME, "samples": samples, "complete": False}
        save(out / "result.json", result)
        for i in range(args.samples):
            samples.append(probe(probe_pair, probe_dir, i))
            result["responsiveness"]["sample_seconds"] = time.monotonic() - start
            save(out / "result.json", result)
            if samples[-1].get("missed"):
                raise RuntimeError("probe missed; stopped before another input token: " + samples[-1]["token"])
            if i % 10 == 0:
                # Churn only our disposable workspaces; no operator topology.
                churn, _ = workspace()
                call("workspace.close", {"workspace_id": churn})
                workspaces.remove(churn)
                call("workspace.select", {"workspace_id": probe_pair[0]})
                call("tab.focus", params(probe_pair))
            time.sleep(.05)
        result["responsiveness"] = {"clock": CLOCK_NAME, "complete": True, "sample_seconds": time.monotonic() - start, "samples": samples,
            "missed": sum(bool(s.get("missed")) for s in samples),
            **{metric: percentiles([s[metric] for s in samples if metric in s]) for metric in METRIC_FIELDS}}
        result["stream_workers"] = stream_identities
        if any(ps(item["pid"], "lstart") != item["started"] for item in stream_identities):
            raise RuntimeError("a streaming worker exited during probing")
        if args.comparison_only:
            result["skipped"] = ["focus transitions", "paste", "shutdown cases"]
            if result["responsiveness"]["missed"]:
                raise RuntimeError("responsiveness probes missed")
            result["status"] = "PASS_FOR_REPORTED_SCENARIOS"
            return
        # Workspace hide/show setup and socket state oracle. This is NOT visual proof.
        for _ in range(10):
            call("workspace.select", {"workspace_id": stream_ws})
            call("workspace.select", {"workspace_id": probe_pair[0]})
            call("tab.focus", params(probe_pair))
        final = call("workspace.current")
        result["focus_state"] = {"current": final, "tabs": call("tab.list", {"workspace_id": probe_pair[0]}),
                                 "probe": probe(probe_pair, probe_dir, args.samples)}
        selected = next((tab for tab in result["focus_state"]["tabs"]["tabs"] if tab.get("id") == probe_pair[1]), {})
        if (final.get("workspace_id") != probe_pair[0] or not selected.get("focused")
                or not selected.get("selected_in_area") or result["focus_state"]["probe"].get("missed")):
            raise RuntimeError("final workspace/tab focus/probe state failed")
        # Explicit bundled CLI is exercised as a separate, timed observation.
        cli = subprocess.run([str(rpc.cli), "--socket", args.socket, "read-screen", "--workspace", probe_pair[0],
                              "--tab", probe_pair[1]], env=env, text=True, capture_output=True, timeout=5)
        (out / "cli-read-screen.txt").write_text(cli.stdout + cli.stderr)
        if cli.returncode or f"ACK:p{args.samples:06d}" not in cli.stdout:
            raise RuntimeError("explicit bundled CLI read-screen failed")
        # Paste bytes must reach a raw PTY, including one bracket pair only.
        paste_pair, paste_dir, _ = launch("paste", "paste")
        ready_deadline = time.monotonic() + 5
        while "C11_PASTE_READY" not in read(paste_pair):
            if time.monotonic() > ready_deadline:
                raise TimeoutError("paste mode/ready output never parsed")
            time.sleep(.02)
        payload = ("".join(f"line-{i:05d}: café αβ\n" for i in range(6000)) + "END-OF-SYNTHETIC-PASTE").encode()
        (out / "paste-input.bin").write_bytes(payload)
        call("tab.send_text", {**params(paste_pair), "text": payload.decode(), "submit": False})
        done = wait_file(paste_dir / "done.json", 30)
        raw = (paste_dir / "received.bin").read_bytes()
        begin, end = raw.find(START), raw.find(END)
        before = raw[:begin] if begin >= 0 else b""
        after = raw[end + len(END):] if end >= 0 else b""
        replies = re.findall(rb"\x1b\[[0-9]+;[0-9]+R", before + after)
        correct = done["end_seen"] and raw.count(START) == raw.count(END) == 1 and raw[begin + len(START):end] == payload
        result["paste"] = {"expected_bytes": len(payload), "captured_bytes": len(raw), "query_replies_outside_paste": len(replies),
                           "input_sha256": hashlib.sha256(payload).hexdigest(), "raw_sha256": hashlib.sha256(raw).hexdigest(),
                           "one_exact_bracketed_payload": correct}
        if not correct or not replies:
            raise RuntimeError("paste bytes/fences or concurrent terminal reply evidence failed")
        # Full shutdown case matrix remains native-fixture work; these exercise real tabs.
        result["shutdown"] = []
        for mode in ("graceful", "ignore-hup", "ignore-both", "detached"):
            pair, directory, identity = launch("shutdown-" + mode, "shutdown-" + mode)
            start = time.monotonic()
            # A fixture workspace contains its sole terminal; tab.close
            # deliberately rejects closing the last tab in an area.
            call("workspace.close", {"workspace_id": pair[0]}, timeout=20)
            workspaces.remove(pair[0])
            while ps(identity["pid"], "lstart") == identity["started"]:
                if time.monotonic() - start > 18:
                    raise TimeoutError("owned child still exists after shutdown budget: " + mode)
                time.sleep(.02)
            record = {"mode": mode, "elapsed_ms": (time.monotonic() - start) * 1000,
                      "child": identity, "hup_observed": (directory / "hup-observed").exists()}
            if mode == "graceful" and not record["hup_observed"]:
                raise RuntimeError("graceful child did not observe HUP")
            if mode == "detached":
                detached = wait_file(directory / "detached.json")
                heartbeat = (directory / "heartbeat").read_text()
                time.sleep(.25)
                alive = ps(detached["pid"], "lstart") == detached["started"] and (directory / "heartbeat").read_text() != heartbeat
                record["detached_kept_alive"] = alive
                if not alive:
                    raise RuntimeError("detached keep sentinel was killed")
            result["shutdown"].append(record)
        if result["responsiveness"]["missed"]:
            raise RuntimeError("responsiveness probes missed; retain distribution for orchestrator verdict")
        result["status"] = "PASS_FOR_REPORTED_SCENARIOS"
    except Exception as error:
        result["error"] = repr(error)
        raise
    finally:
        result["load_average_end"] = os.getloadavg()
        if "responsiveness" in result:
            summary = result["responsiveness"]
            collected = summary["samples"]
            summary["missed"] = sum(bool(item.get("missed")) for item in collected)
            for metric in METRIC_FIELDS:
                summary[metric] = percentiles([item[metric] for item in collected if metric in item])
        # Persist partial samples/error before any cleanup that might time out.
        save(out / "result.json", result)
        cleanup = []
        # Kill only identities created by this run, verified again before signal.
        for directory, identity in workers:
            candidates = [identity]
            if (directory / "detached.json").exists():
                candidates.append(json.loads((directory / "detached.json").read_text()))
            for item in candidates:
                if ps(item["pid"], "lstart") == item["started"] and str(directory) in ps(item["pid"], "args"):
                    try:
                        os.kill(item["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    reap_deadline = time.monotonic() + 2
                    while ps(item["pid"], "lstart") == item["started"] and time.monotonic() < reap_deadline:
                        time.sleep(.02)
                    if ps(item["pid"], "lstart") == item["started"]:
                        cleanup.append({"pid": item["pid"], "error": "fixture process still present after cleanup"})
        for ws in reversed(workspaces):
            try:
                rpc.call("workspace.close", {"workspace_id": ws}, timeout=3)
            except Exception as error:
                if "not_found" not in str(error):
                    cleanup.append({"workspace": ws, "error": repr(error)})
        result["cleanup_errors"] = cleanup
        if cleanup:
            result["status"] = "FAIL_CLEANUP"
        save(out / "result.json", result)
        rpc.sock.close()
        print(json.dumps({"status": result["status"], "result": str(out / "result.json")}))
        if cleanup:
            raise RuntimeError("fixture cleanup failed; see result.json")
    if result["status"] != "PASS_FOR_REPORTED_SCENARIOS":
        raise RuntimeError(result["status"])


def main():
    parser = argparse.ArgumentParser(__doc__)
    modes = parser.add_subparsers(dest="operation", required=True)
    child = modes.add_parser("worker")
    child.add_argument("--mode", required=True, choices=["probe", "paste", "stream", "shutdown-graceful", "shutdown-ignore-hup", "shutdown-ignore-both", "shutdown-detached"])
    child.add_argument("--out", required=True)
    run = modes.add_parser("run")
    for flag in ("tag", "socket", "cli", "app", "out", "engine-sha"):
        run.add_argument("--" + flag, required=True)
    run.add_argument("--run-id")
    run.add_argument("--local-tagged", action="store_true")
    run.add_argument("--comparison-only", action="store_true")
    run.add_argument("--ui-driver")
    run.add_argument("--ui-window", type=int)
    run.add_argument("--streams", type=int, default=30)
    run.add_argument("--samples", type=int, default=100)
    run.add_argument("--label", required=True, choices=["baseline", "candidate"])
    compare = modes.add_parser("compare")
    compare.add_argument("baseline")
    compare.add_argument("candidate")
    args = parser.parse_args()
    if args.operation == "compare":
        baseline = json.loads(Path(args.baseline).read_text())
        candidate = json.loads(Path(args.candidate).read_text())
        if (baseline["workload"] != candidate["workload"] or baseline["guest_hardware"] != candidate["guest_hardware"]
                or baseline["target_mode"] != candidate["target_mode"]
                or baseline.get("input_mode", "socket-synthetic") != candidate.get("input_mode", "socket-synthetic")
                or baseline.get("measurement_version") != candidate.get("measurement_version")):
            raise RuntimeError("baseline/candidate workload, CPU/RAM, target mode, input mode or measurement version differs")
        comparison = {"baseline_status": baseline["status"], "candidate_status": candidate["status"],
                      "threshold_verdict": "orchestrator-owned", "baseline": baseline.get("responsiveness"),
                      "candidate": candidate.get("responsiveness")}
        print(json.dumps(comparison, indent=2))
    elif args.operation == "worker":
        try:
            worker(args)
        except Exception as error:
            directory = Path(args.out)
            directory.mkdir(parents=True, exist_ok=True)
            save(directory / "error.json", {"error": repr(error), "traceback": traceback.format_exc(),
                                             "mode": args.mode, "clock": CLOCK_NAME})
            raise
    else:
        if not re.fullmatch(r"[0-9a-f]{40}", args.engine_sha):
            parser.error("engine-sha must be full40hex")
        if not 1 <= args.streams <= 30 or not 1 <= args.samples <= 100:
            parser.error("streams must be 1..30 and samples 1..100")
        controller(args)


if __name__ == "__main__":
    main()
