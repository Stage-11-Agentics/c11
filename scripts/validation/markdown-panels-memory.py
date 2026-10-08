#!/usr/bin/env python3
"""Run only inside a c11 sandbox guest: comparable 20-panel RSS/creation probe."""
import argparse
import json
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("socket")
    parser.add_argument("document")
    parser.add_argument("output")
    args = parser.parse_args()
    if not args.socket.startswith("/tmp/c11-sandbox-"):
        parser.error("use a sandbox guest socket")

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

    def memory():
        listing = subprocess.check_output(["ps", "-axo", "pid,ppid,rss,command"], text=True)
        rows = []
        for line in listing.splitlines()[1:]:
            fields = line.strip().split(None, 3)
            if len(fields) != 4:
                continue
            command = fields[3]
            if ".app/Contents/MacOS/c11" in command or "com.apple.WebKit." in command:
                rows.append({"pid": int(fields[0]), "ppid": int(fields[1]), "rss_kib": int(fields[2]), "command": command})
        return {"total_rss_kib": sum(row["rss_kib"] for row in rows), "processes": rows}

    tree = rpc("system.tree")
    window = tree["windows"][0]
    workspace = window["workspaces"][0]
    common = {"workspace_id": workspace["id"]}
    report = {"brand": rpc("system.brand"), "document": args.document, "panels": 20,
              "metric": "sum of RSS (KiB) for c11 and WebKit processes in an isolated guest; shared pages may be counted more than once",
              "uptime": subprocess.check_output(["uptime"], text=True).strip(), "before": memory()}
    panels = []
    start = time.perf_counter()
    for _ in range(20):
        panel = rpc("panel.create", {**common, "type": "markdown", "file": args.document, "focus": False})
        panels.append(panel.get("panel_id") or panel["surface_id"])
    report["create_twenty_seconds"] = time.perf_counter() - start
    report["never_shown"] = memory()
    start = time.perf_counter()
    for panel_id in panels:
        rpc("panel.focus", {**common, "panel_id": panel_id})
        rpc("markdown.get_content", {**common, "panel_id": panel_id})
    report["visit_twenty_seconds"] = time.perf_counter() - start
    report["after_visit"] = memory()
    report["tree"] = rpc("system.tree")
    with open(args.output, "w") as output:
        json.dump(report, output, indent=2)
    print(json.dumps({key: report[key] for key in ["panels", "create_twenty_seconds", "visit_twenty_seconds", "uptime"]}))
    print(json.dumps({key: report[key]["total_rss_kib"] for key in ["before", "never_shown", "after_visit"]}))


if __name__ == "__main__":
    main()
