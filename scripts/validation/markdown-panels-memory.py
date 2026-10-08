#!/usr/bin/env python3
"""Run only inside a c11 sandbox guest: comparable 20-panel memory/creation probe."""
import argparse
import json
import os
from pathlib import Path
import re
import socket
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket")
    parser.add_argument("document")
    parser.add_argument("output")
    parser.add_argument("--metric", choices=["footprint", "rss", "both"], default="footprint")
    parser.add_argument("--host-context", type=json.loads, help="Atlas hostname/load metadata captured by the caller")
    args = parser.parse_args()
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

    def memory(phase):
        started = time.perf_counter()
        load = {"guest_load_average": os.getloadavg(), "guest_uptime": run(["/usr/bin/uptime"]).strip()}
        listing = run(["/bin/ps", "-axo", "pid,ppid,rss,command"])
        rows, excluded = [], []
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
                details = run(["/usr/bin/sudo", "-n", "/bin/launchctl", "procinfo", str(process_pid)])
                procinfo_path = raw_directory / f"{phase}-{process_pid}.procinfo.txt"
                procinfo_path.write_text(details)
                responsible = re.search(r"(?m)^responsible pid\s*=\s*(\d+)\s*$", details)
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
                text_path.write_text(run(["/usr/bin/sudo", "-n", "/usr/bin/footprint", "-p", str(process_pid),
                                          "-f", "bytes", "-j", str(footprint_path)]))
                footprint_report = json.loads(footprint_path.read_text())
                row["physical_footprint_bytes"] = physical_footprint_bytes(footprint_report, process_pid)
                row["footprint_json_path"] = str(footprint_path)
                row["footprint_text_path"] = str(text_path)
                row["footprint_auxiliary"] = next(
                    process["auxiliary"] for process in footprint_report["processes"] if process["pid"] == process_pid
                )
                row["footprint_errors"] = footprint_report.get("errors")
                row["footprint_warnings"] = footprint_report.get("warnings")
            rows.append(row)
        if not app_seen:
            raise RuntimeError("sandbox app PID exited during measurement")
        snapshot = {**load, "processes": rows, "excluded_webkit_processes": excluded,
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
              "uptime": run(["/usr/bin/uptime"]).strip()}

    def persist():
        output_path.write_text(json.dumps(report, indent=2))

    report["before"] = memory("before")
    persist()
    panels = []
    start = time.perf_counter()
    for _ in range(20):
        panel = rpc("panel.create", {**common, "type": "markdown", "file": args.document, "focus": False})
        panels.append(panel.get("panel_id") or panel["surface_id"])
    report["create_twenty_seconds"] = time.perf_counter() - start
    report["never_shown"] = memory("never-shown")
    persist()
    start = time.perf_counter()
    for panel_id in panels:
        rpc("panel.focus", {**common, "panel_id": panel_id})
        rpc("markdown.get_content", {**common, "panel_id": panel_id})
    report["visit_twenty_seconds"] = time.perf_counter() - start
    report["after_visit"] = memory("after-visit")
    report["tree"] = rpc("system.tree")
    persist()
    print(json.dumps({key: report[key] for key in ["panels", "app_pid", "create_twenty_seconds", "visit_twenty_seconds", "uptime"]}))
    print(json.dumps({key: {metric: value for metric, value in report[key].items() if metric.startswith("total_")}
                      for key in ["before", "never_shown", "after_visit"]}))


if __name__ == "__main__":
    main()
