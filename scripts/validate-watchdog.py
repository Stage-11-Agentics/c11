#!/usr/bin/env python3
r"""C11-467 packaged proof. Run ONLY via sandbox-exec in an Atlas Tart guest.

  scripts/sandbox-exec.sh <run> python3 /Volumes/My\ Shared\ Files/out/validate-watchdog.py \
      --app <guest-tagged.app> --mode oversleep --output /Volumes/My\ Shared\ Files/out/oversleep

Modes: oversleep (30s injected watchdog delay), inert (same env without opt-in),
stress (300s, guest CPU count x8 default-QoS workers). Records each main-hopping
workspace.list latency. Every process has a hard deadline and exact-PID cleanup.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time


def local_time():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-7), "PDT")).isoformat()


def probe(path):
    started = time.monotonic()
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect(str(path))
        client.sendall(b'{"id":"watchdog-proof","method":"workspace.list","params":{}}\n')
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            if not chunk:
                raise RuntimeError("socket closed before a response")
            data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
        if not reply.get("ok"):
            raise RuntimeError(f"workspace.list failed: {reply}")
    return (time.monotonic() - started) * 1000


def stop_pid(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def timeout(_signal, _frame):
    raise TimeoutError("watchdog proof exceeded its hard 390-second deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("oversleep", "inert", "stress"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    # Refuse host execution even if a caller accidentally targets Atlas itself.
    virtual = subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], text=True).strip()
    app = args.app.resolve()
    guest_apps = Path.home() / "c11-sandbox/apps"
    if virtual != "1" or not app.is_relative_to(guest_apps) or not Path("/Volumes/My Shared Files/out").is_dir():
        raise SystemExit("REFUSED: requires a c11 sandbox guest and a guest-staged app")
    binary = app / "Contents/MacOS/c11"
    if not binary.is_file() or "DEV" not in app.name:
        raise SystemExit("REFUSED: expected a tagged c11 DEV bundle")
    args.output.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGALRM, timeout)
    signal.signal(signal.SIGTERM, timeout)
    signal.signal(signal.SIGINT, timeout)
    signal.alarm(390)
    # Retire only the sandbox-up instance of this exact bundle before relaunch.
    for line in subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == str(binary):
            stop_pid(int(parts[0]))
    sock = Path(f"/tmp/c11-sandbox-watchdog-{os.getpid()}.sock")
    hang_log = args.output / "hang.log"
    hang_log.write_text("")
    env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "PATH", "TMPDIR") if key in os.environ}
    env.update(C11_SOCKET_MODE="automation", C11_ALLOW_SOCKET_OVERRIDE="1",
               C11_SOCKET_PATH=str(sock), C11_SOCKET=str(sock), C11_QA_LAUNCH="fresh",
               CMUXD_UNIX_PATH=f"/tmp/c11-sandbox-watchdog-daemon-{os.getpid()}.sock",
               C11_DEBUG_LOG=str(args.output / "debug.log"), C11_HANG_LOG=str(hang_log))
    if args.mode in ("oversleep", "inert"):
        env["C11_HANG_TEST_OVERSLEEP_SECONDS"] = "30"
    if args.mode == "oversleep":
        env["C11_HANG_TESTING"] = "1"
    workers = []
    app_process = None
    rows = []
    summary = {"mode": args.mode, "started": local_time(), "app": str(app), "passed": False}
    try:
        with (args.output / "stdout.log").open("w") as out:
            app_process = subprocess.Popen([str(binary)], env=env, stdout=out, stderr=subprocess.STDOUT)
        summary["app_pid"] = app_process.pid
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if app_process.poll() is not None:
                raise RuntimeError("packaged app exited before socket readiness")
            try:
                probe(sock)
                break
            except (OSError, RuntimeError):
                time.sleep(0.25)
        else:
            raise RuntimeError("packaged app never served workspace.list")
        seconds = 38 if args.mode in ("oversleep", "inert") else 300
        if args.mode == "stress":
            count = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.ncpu"], text=True)) * 8
            # Each worker dies by its own deadline even if the parent is killed.
            code = ("import ctypes,time; lib=ctypes.CDLL(None); "
                    "assert lib.pthread_set_qos_class_self_np(0x15,0)==0; "
                    "end=time.monotonic()+300\nwhile time.monotonic()<end: pass\n")
            for _ in range(count):
                workers.append(subprocess.Popen(["/usr/bin/python3", "-c", code], stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL))
            summary["worker_pids"] = [worker.pid for worker in workers]
            summary["guest_cpus"] = count // 8
        start = time.monotonic()
        with (args.output / "latency.jsonl").open("w") as out:
            while time.monotonic() - start < seconds:
                sample = time.monotonic()
                if workers and sample - start < 290 and any(worker.poll() is not None for worker in workers):
                    raise RuntimeError("stress worker exited early; CPU saturation proof is invalid")
                row = {"time": local_time(), "elapsed_s": sample - start}
                try:
                    row["latency_ms"] = probe(sock)
                except Exception as error:
                    row["error"] = str(error)
                rows.append(row)
                out.write(json.dumps(row) + "\n")
                out.flush()
                time.sleep(max(0, 1 - (time.monotonic() - sample)))
        log = hang_log.read_text()
        latencies = sorted(row["latency_ms"] for row in rows if "latency_ms" in row)
        late = [line for line in log.splitlines() if "watchdog.late" in line]
        hangs = [line for line in log.splitlines() if "hang.begin" in line]
        summary.update(probes=len(rows), errors=[row for row in rows if "error" in row],
                       max_latency_ms=max(latencies, default=None),
                       p95_latency_ms=latencies[int((len(latencies) - 1) * .95)] if latencies else None,
                       hang_headers=hangs, late_headers=late)
        if args.mode == "oversleep":
            # Vacuity guard: the 30s sleep must really have occurred.
            import re
            assert any(int(re.search(r"lateMs=(\d+)", line)[1]) >= 29000 for line in late), "oversleep never fired"
        if args.mode == "inert":
            assert not late, "test seam affected a launch without C11_HANG_TESTING"
        assert not summary["errors"], "main-hopping probes failed"
        assert max(latencies) < 2000, "main-hopping probe exceeded two seconds"
        assert not hangs, "phantom hang.begin captured during a responsive main loop"
        summary["passed"] = True
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.terminate()
        for worker in workers:
            try:
                worker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait(timeout=3)
        if app_process is not None:
            if app_process.poll() is None:
                app_process.terminate()
            try:
                app_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app_process.kill()
                app_process.wait(timeout=3)
        summary["finished"] = local_time()
        summary["workers_reaped"] = all(worker.poll() is not None for worker in workers)
        summary["worker_exit_codes"] = [worker.returncode for worker in workers]
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
        signal.alarm(0)


if __name__ == "__main__":
    main()
