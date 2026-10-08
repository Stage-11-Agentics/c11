#!/usr/bin/env python3
"""Run only inside a c11 sandbox guest: comparable 20-panel memory/creation probe."""
import argparse
import json
import os
from pathlib import Path
import re
import select
import socket
import statistics
import subprocess
import time


def physical_footprint_bytes(report, pid):
    """Read the per-process physical ledger, not category totals or RSS."""
    matches = [process for process in report["processes"] if process["pid"] == pid]
    if len(matches) != 1:
        raise ValueError(f"footprint JSON must contain exactly PID {pid}")
    value = matches[0]["auxiliary"]["phys_footprint"]
    unit_bytes = report["bytes per unit"]
    if (isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0
            or isinstance(unit_bytes, bool) or not isinstance(unit_bytes, (int, float)) or unit_bytes <= 0):
        raise ValueError("invalid physical footprint or byte unit")
    result = value * unit_bytes
    if result != int(result):
        raise ValueError("physical footprint is not an integral byte count")
    return int(result)


class RendererEvents:
    """Wait on native DEBUG log writes; never infer readiness from a delay."""

    pattern = re.compile(r"markdown\.renderer\.(ready|evicted) panel=([0-9A-Fa-f-]+) (.*)")

    def __init__(self, path):
        self.path = Path(path)
        self.events = []
        self.resident = set()
        self.pending = b""
        self.queue = select.kqueue()
        # dlog can create its default file only when its first message lands.
        directory = os.open(self.path.parent, os.O_RDONLY)
        try:
            self.queue.control([select.kevent(directory, filter=select.KQ_FILTER_VNODE,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                             fflags=select.KQ_NOTE_WRITE)], 0, 0)
            deadline = time.monotonic() + 45
            while not self.path.exists():
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not self.queue.control(None, 1, remaining):
                    raise TimeoutError(f"native renderer debug log missing: {self.path}")
            self.queue.control([select.kevent(directory, filter=select.KQ_FILTER_VNODE,
                                             flags=select.KQ_EV_DELETE)], 0, 0)
        finally:
            os.close(directory)
        self.file = self.path.open("rb")
        self.file.seek(0, os.SEEK_END)
        self.queue.control([select.kevent(self.file.fileno(), filter=select.KQ_FILTER_VNODE,
                                         flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                         fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0, 0)

    def mark(self):
        self.read()
        return len(self.events)

    def read(self):
        if os.fstat(self.file.fileno()).st_size < self.file.tell():
            raise RuntimeError("native renderer debug log truncated during measurement")
        self.pending += self.file.read()
        lines = self.pending.split(b"\n")
        self.pending = lines.pop()
        for raw in lines:
            line = raw.decode("utf-8", errors="replace")
            match = self.pattern.search(line)
            if not match:
                continue
            kind, panel, fields = match.groups()
            event = {"kind": kind, "panel": panel.lower(), "raw": line}
            event.update(dict(re.findall(r"(\w+)=([^\s]+)", fields)))
            self.events.append(event)
            if kind == "ready":
                self.resident.add(panel.lower())
            else:
                self.resident.discard(panel.lower())

    def wait(self, kind, panel, after):
        deadline = time.monotonic() + 45
        while True:
            self.read()
            for event in self.events[after:]:
                if event["kind"] == kind and event["panel"] == panel.lower():
                    return event
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.queue.control(None, 1, remaining):
                raise TimeoutError(f"no native {kind} event for panel {panel}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket")
    parser.add_argument("document")
    parser.add_argument("output")
    parser.add_argument("--metric", choices=["footprint", "rss", "both"], default="footprint")
    parser.add_argument("--host-context", type=json.loads, help="Atlas hostname/load metadata captured by the caller")
    parser.add_argument("--renderer-events", help="native Bonsplit DEBUG log; wait for settled renders")
    parser.add_argument("--reshow-count", type=int, default=0, help="evict/recreate one panel this many times")
    args = parser.parse_args()
    if args.reshow_count < 0 or args.reshow_count > 100 or (args.reshow_count and not args.renderer_events):
        parser.error("reshow-count requires renderer-events and must be between 0 and 100")
    if not args.socket.startswith("/tmp/c11-sandbox-"):
        parser.error("use a sandbox guest socket")
    run_id = args.socket.removeprefix("/tmp/c11-sandbox-").removesuffix(".sock")
    if not (Path("/Volumes/My Shared Files/out").is_dir()
            and (Path.home() / "c11-sandbox/apps" / run_id).is_dir()):
        parser.error("run inside the matching disposable sandbox guest")
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    raw_directory = output_path.parent / (output_path.stem + "-raw")
    raw_directory.mkdir(exist_ok=True)

    def run(command):
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=45)

    def rpc(method, params=None):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(30)
            client.connect(args.socket)
            client.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            result = b""
            while b"\n" not in result:
                chunk = client.recv(65536)
                if not chunk:
                    raise RuntimeError("socket closed without reply")
                result += chunk
        reply = json.loads(result.split(b"\n", 1)[0])
        if not reply.get("ok"):
            raise RuntimeError(reply)
        return reply["result"]

    # The Unix listener pins this run's exact app. XPC WebKit children have PPID1;
    # launchctl's responsible PID, rather than ancestry/name alone, identifies them.
    listeners = {int(value) for value in run([
        "/usr/sbin/lsof", "-nP", "-t", "-a", "-U", "--", args.socket
    ]).split()}
    if len(listeners) != 1:
        raise RuntimeError(f"expected one sandbox socket listener, found {listeners}")
    app_pid = listeners.pop()

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    events = RendererEvents(args.renderer_events) if args.renderer_events else None

    def memory(phase):
        started = time.perf_counter()
        load = {"guest_load_average": os.getloadavg(), "guest_uptime": run(["/usr/bin/uptime"]).strip()}
        listing = run(["/bin/ps", "-axo", "pid,ppid,rss,command"])
        rows, excluded, gone = [], [], []
        app_seen = False
        for line in listing.splitlines()[1:]:
            fields = line.strip().split(None, 3)
            if len(fields) != 4:
                continue
            process_pid, parent_pid, rss_kib = map(int, fields[:3])
            command = fields[3]
            if process_pid == app_pid:
                expected = str(Path.home() / "c11-sandbox/apps" / run_id) + "/"
                if not command.startswith(expected) or ".app/Contents/MacOS/c11" not in command:
                    raise RuntimeError("sandbox listener is not the expected tagged c11 executable")
                app_seen = True
                attribution = "exact sandbox socket listener"
            elif command.startswith("/System/") and "/com.apple.WebKit." in command:
                try:
                    details = run(["/usr/bin/sudo", "-n", "/bin/launchctl", "procinfo", str(process_pid)])
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                    if not alive(process_pid):
                        gone.append({"pid": process_pid, "stage": "attribution", "error": str(error)})
                        continue
                    raise
                procinfo_path = raw_directory / f"{phase}-{process_pid}.procinfo.txt"
                procinfo_path.write_text(details)
                responsible = re.search(r"(?m)^responsible pid\s*=\s*(\d+)\s*$", details)
                if responsible is None and not alive(process_pid):
                    gone.append({"pid": process_pid, "stage": "attribution", "procinfo_path": str(procinfo_path)})
                    continue
                if responsible is None or int(responsible[1]) != app_pid:
                    excluded.append({"pid": process_pid, "command": command,
                                     "responsible_pid": int(responsible[1]) if responsible else None,
                                     "procinfo_path": str(procinfo_path)})
                    continue
                attribution = "WebKit responsible PID matches sandbox listener"
            else:
                continue
            row = {"pid": process_pid, "ppid": parent_pid, "rss_kib": rss_kib,
                   "command": command, "attribution": attribution}
            if args.metric in ("footprint", "both"):
                footprint_path = raw_directory / f"{phase}-{process_pid}.footprint.json"
                text_path = raw_directory / f"{phase}-{process_pid}.footprint.txt"
                try:
                    text_path.write_text(run(["/usr/bin/sudo", "-n", "/usr/bin/footprint", "-p", str(process_pid),
                                              "-f", "bytes", "-j", str(footprint_path)]))
                    footprint_report = json.loads(footprint_path.read_text())
                    row["physical_footprint_bytes"] = physical_footprint_bytes(footprint_report, process_pid)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, KeyError, ValueError) as error:
                    if process_pid != app_pid and not alive(process_pid):
                        gone.append({"pid": process_pid, "stage": "footprint", "error": str(error),
                                     "footprint_json_path": str(footprint_path), "footprint_text_path": str(text_path)})
                        continue
                    raise
                row["footprint_json_path"] = str(footprint_path)
                row["footprint_text_path"] = str(text_path)
                row["footprint_auxiliary"] = next(
                    process["auxiliary"] for process in footprint_report["processes"] if process["pid"] == process_pid
                )
                row["footprint_errors"] = footprint_report.get("errors")
                row["footprint_warnings"] = footprint_report.get("warnings")
            rows.append(row)
        if not app_seen or not alive(app_pid):
            raise RuntimeError("sandbox app PID exited during measurement")
        snapshot = {**load, "processes": rows, "excluded_webkit_processes": excluded,
                    "gone_processes": gone,
                    "measurement_seconds": time.perf_counter() - started,
                    "sample_note": "process physical ledgers sampled sequentially; not an atomic system snapshot"}
        if args.metric in ("footprint", "both"):
            snapshot["total_physical_footprint_bytes"] = sum(row["physical_footprint_bytes"] for row in rows)
        if args.metric in ("rss", "both"):
            snapshot["total_rss_kib"] = sum(row["rss_kib"] for row in rows)
        return snapshot

    tree = rpc("system.tree")
    window = tree["windows"][0]
    workspace = window["workspaces"][0]
    common = {"workspace_id": workspace["id"]}
    report = {"brand": rpc("system.brand"), "document": args.document, "panels": 20,
              "socket": args.socket, "app_pid": app_pid, "metric": args.metric,
              "metric_definition": "sum of per-process auxiliary.phys_footprint bytes from footprint JSON for exact c11 listener and its responsible WebKit processes; RSS retained only as a separate optional metric",
              "host_context": args.host_context, "raw_reports_directory": str(raw_directory),
              "renderer_events_path": args.renderer_events,
              "uptime": run(["/usr/bin/uptime"]).strip()}

    def persist():
        output_path.write_text(json.dumps(report, indent=2))

    def focus(panel_id):
        mark = events.mark() if events else None
        rpc("panel.focus", {**common, "panel_id": panel_id})
        rpc("markdown.get_content", {**common, "panel_id": panel_id})
        if events:
            events.read()
            if panel_id.lower() not in events.resident:
                return events.wait("ready", panel_id, mark)
            return next((event for event in events.events[mark:]
                         if event["kind"] == "ready" and event["panel"] == panel_id.lower()), None)
        return None

    report["before"] = memory("before")
    persist()
    print("checkpoint before", flush=True)
    panels = []
    start = time.perf_counter()
    for _ in range(20):
        panel = rpc("panel.create", {**common, "type": "markdown", "file": args.document, "focus": False})
        panels.append(panel.get("panel_id") or panel["surface_id"])
    report["create_twenty_seconds"] = time.perf_counter() - start
    report["never_shown"] = memory("never-shown")
    report["panel_ids"] = panels
    persist()
    print("checkpoint never_shown", flush=True)
    start = time.perf_counter()
    for panel_id in panels:
        focus(panel_id)
    report["visit_twenty_seconds"] = time.perf_counter() - start
    report["after_visit"] = memory("after-visit")
    persist()
    print("checkpoint after_visit", flush=True)
    if args.reshow_count:
        target, others = panels[0], panels[1:6]

        def evict_target():
            mark = events.mark()
            for other in others:
                focus(other)
            return events.wait("evicted", target, mark)

        events.read()
        if target.lower() in events.resident:
            evict_target()
        samples = []
        report["reshow"] = {"target_panel": target, "other_panels": others, "samples": samples,
                            "definition": "native creation-to-restored-settled elapsedMs, not RPC overhead"}
        for index in range(args.reshow_count):
            event = focus(target)
            if event is None:
                raise RuntimeError("reshow target reused a resident renderer instead of recreating")
            sample = {"iteration": index + 1, "elapsed_ms": float(event["elapsedMs"]), "ready": event}
            samples.append(sample)
            sample["evicted"] = evict_target()
            persist()
            print(f"checkpoint reshow {index + 1} {sample['elapsed_ms']:.3f}ms", flush=True)
        report["reshow"]["median_elapsed_ms"] = statistics.median(sample["elapsed_ms"] for sample in samples)
        report["after_reshow"] = memory("after-reshow")
    if events:
        events.read()
        report["renderer_events"] = events.events
    report["tree"] = rpc("system.tree")
    persist()
    print(json.dumps({key: report[key] for key in ["panels", "app_pid", "create_twenty_seconds", "visit_twenty_seconds", "uptime"]}))
    print(json.dumps({key: {metric: value for metric, value in report[key].items() if metric.startswith("total_")}
                      for key in ["before", "never_shown", "after_visit"]}))


if __name__ == "__main__":
    main()
