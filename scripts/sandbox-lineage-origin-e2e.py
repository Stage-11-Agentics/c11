#!/usr/bin/env python3
"""C11H-260 lineage-origin e2e. Runs inside a sandbox guest's Aqua session.

Usage (on the Tart host, after scripts/sandbox-up.sh <run> <tagged.app>):
  copy this file to ~/.c11-sandbox/out/<run>/ and run
  scripts/sandbox-exec.sh <run> /usr/bin/python3 -u "/Volumes/My Shared Files/out/sandbox-lineage-origin-e2e.py" \
      <phase> <guest app path> <guest socket path>

Phases:
  cases    operator (Area > New Panel > New Terminal menu item, PID-scoped),
           panel (`c11 new-panel` typed into that panel's shell),
           external (`c11 new-panel` from this shell, no caller panel);
           each read back through `c11 family --json` and the panel sheet
           subtitle (debug.panel_sheet.detail), with a screenshot of the sheet
  restart  state save, kill the app, drop one panel's lineage node and strip
           the origin from another (the shape a pre-C11H-260 snapshot has),
           relaunch with C11_QA_LAUNCH=resume, read every origin back
State and results live in /Volumes/My Shared Files/out/c260/.
"""
import json
import os
import subprocess
import sys
import time

OUT = "/Volumes/My Shared Files/out/c260"
HOME = os.path.expanduser("~")


def sh(*args, check=True, env=None, timeout=60):
    r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {args}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def clean_env(socket):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("C11_", "CMUX_", "HC_"))}
    env["C11_SOCKET"] = socket
    env["C11_SOCKET_PATH"] = socket
    return env


class Guest:
    def __init__(self, app, socket):
        self.app, self.socket = app, socket
        self.cli = os.path.join(app, "Contents/Resources/bin/c11")
        self.binary = os.path.join(app, "Contents/MacOS/c11")

    def c11(self, *args, check=True):
        return sh(self.cli, "--socket", self.socket, *args, check=check, env=clean_env(self.socket))

    def json(self, *args):
        return json.loads(self.c11("--json", "--id-format", "both", *args))

    def pid(self):
        out = sh("/usr/bin/pgrep", "-f", self.binary, check=False).split()
        return int(out[0]) if out else None

    def panels(self):
        tree = self.json("tree", "--all", "--no-layout")
        ids = {}
        def walk(node):
            if isinstance(node, dict):
                if node.get("type") in ("terminal", "browser", "markdown") and node.get("id"):
                    ids[node["id"]] = node
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(tree)
        return ids

    def origin(self, panel_id):
        fam = self.json("family", "--panel", panel_id)
        node = next(n for n in fam["nodes"] if panel_id in (n.get("id"), n.get("id_uuid"), n.get("uuid")) or
                    n.get("id", "").endswith(panel_id))
        return {k: node.get(k) for k in ("id", "ref", "title", "origin", "origin_detail", "created_at",
                                         "parent_panel_id", "parent_panel_ref")}

    def subtitle(self, panel_id):
        out = self.c11("rpc", "debug.panel_sheet.detail", json.dumps({"surface_id": panel_id}), check=False)
        try:
            return json.loads(out).get("subtitle")
        except ValueError:
            return out.strip()

    def wait_new(self, before, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            now = self.panels()
            new = [p for p in now if p not in before]
            if new:
                return new
            time.sleep(0.5)
        raise SystemExit("no new panel appeared")


def uuid_of(entry):
    for key in ("id", "uuid", "id_uuid"):
        v = entry.get(key)
        if isinstance(v, str) and len(v) == 36:
            return v
    return entry.get("id")


def record(name, value):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "results.json")
    data = json.load(open(path)) if os.path.exists(path) else {}
    data[name] = value
    json.dump(data, open(path, "w"), indent=2)
    print(name, json.dumps(value, indent=2))


def menu_new_terminal(g, before):
    script = (f'tell application "System Events" to tell (first process whose unix id is {g.pid()}) '
              'to click menu item "New Terminal" of menu 1 of menu item "New Panel" of menu "Area" of menu bar 1')
    sh("/usr/bin/osascript", "-e", script)
    return g.wait_new(before)[0]


def cases(g):
    launch = g.panels()
    # 0. launch: the workspace c11 opened at a fresh start, and the grid it filled it with.
    record("launch_panels", {pid_: {"origin": g.origin(pid_), "sheet_subtitle": g.subtitle(pid_)} for pid_ in launch})
    record("launch_tree_text", [l for l in g.c11("tree", "--all", "--no-layout").splitlines() if "↳" in l][:6])

    # 1. operator: the real menu item, scoped to this build's process. A
    #    second one is the node `restart` strips to the pre-C11H-260 shape.
    op = menu_new_terminal(g, launch)
    op_strip = menu_new_terminal(g, g.panels())
    time.sleep(1.5)
    record("operator", {"panel": op, "family": g.origin(op), "sheet_subtitle": g.subtitle(op),
                        "second": g.origin(op_strip)})
    g.c11("rpc", "debug.panel_sheet.open", json.dumps({"surface_id": op}), check=False)
    time.sleep(1.0)
    sh("/usr/sbin/screencapture", "-x", os.path.join(OUT, "sheet-operator.png"), check=False)
    g.c11("rpc", "debug.panel_sheet.open", json.dumps({"surface_id": op, "open": False}), check=False)

    # 2. panel: typed into the operator panel's own shell, so the CLI carries C11_PANEL_ID.
    before = g.panels()
    marker = os.path.join(OUT, "child.out")
    g.c11("send", "--panel", op, f"'{g.cli}' new-panel > '{marker}' 2>&1")
    child = g.wait_new(before)[0]
    time.sleep(1.5)
    record("panel", {"panel": child, "cli_output": open(marker).read() if os.path.exists(marker) else None,
                     "family": g.origin(child), "sheet_subtitle": g.subtitle(child)})
    g.c11("rpc", "debug.panel_sheet.open", json.dumps({"surface_id": child}), check=False)
    time.sleep(1.0)
    sh("/usr/sbin/screencapture", "-x", os.path.join(OUT, "sheet-child.png"), check=False)
    g.c11("rpc", "debug.panel_sheet.open", json.dumps({"surface_id": child, "open": False}), check=False)

    # 3. external: this shell has no C11_PANEL_ID (clean_env strips every C11_*).
    before = g.panels()
    g.c11("new-panel")
    ext = g.wait_new(before)[0]
    time.sleep(1.0)
    record("external", {"panel": ext, "family": g.origin(ext), "sheet_subtitle": g.subtitle(ext)})

    # 4. agent.launch commits on a main-queue hop: a callerless socket request
    #    stays external whatever source tag it carries (review finding 1).
    launches = {}
    for source in ("a-button", "chaos", None):
        params = {"type": "claude-code", "focus": False}
        if source:
            params["source"] = source
        before = g.panels()
        out = g.c11("rpc", "agent.launch", json.dumps(params), check=False)
        try:
            new = g.wait_new(before, timeout=15)[0]
            launches[source or "none"] = {"family": g.origin(new), "sheet_subtitle": g.subtitle(new)}
        except SystemExit:
            launches[source or "none"] = {"error": out[-400:]}
    record("agent_launch_callerless", launches)

    # The surface.created events carry the same origins.
    events = g.c11("events", "tail", "--since", "10m", "--filter", "type=panel.created", check=False)
    record("panel_created_events", [json.loads(l) for l in events.splitlines() if l.startswith("{")][-6:])
    json.dump({"operator": op, "operator_strip": op_strip, "child": child, "external": ext, "launch": list(launch)},
              open(os.path.join(OUT, "ids.json"), "w"))


def restart(g):
    ids = json.load(open(os.path.join(OUT, "ids.json")))
    saved = json.loads(g.c11("--json", "state", "save"))
    path = saved.get("snapshot_path")
    record("state_save", saved)
    if "c11" in g.binary and "Contents/MacOS" in g.binary:
        sh("sudo", "-n", "pkill", "-9", "-f", g.binary, check=False)
    time.sleep(1.5)

    snap = json.load(open(path))
    nodes = snap.get("panelLineageNodes") or []
    launch_root = next((n for n in nodes if n["id"] == ids["operator_strip"]), None)
    edits = {"dropped_node": ids["external"], "stripped_origin": launch_root and launch_root["id"],
             "stripped_was": launch_root and launch_root.get("origin")}
    snap["panelLineageNodes"] = [n for n in nodes if n["id"] != ids["external"]]
    for n in snap["panelLineageNodes"]:
        if launch_root and n["id"] == launch_root["id"]:
            n.pop("origin", None)
            n.pop("origin_detail", None)
    json.dump(snap, open(path, "w"))
    record("snapshot_edits", edits)

    env = {
        "HOME": HOME, "USER": os.environ.get("USER", "admin"), "LOGNAME": os.environ.get("USER", "admin"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "C11_SOCKET_MODE": "automation", "C11_ALLOW_SOCKET_OVERRIDE": "1",
        "C11_SOCKET": g.socket, "C11_SOCKET_PATH": g.socket, "C11_QA_LAUNCH": "resume",
    }
    sh("sudo", "-n", "rm", "-f", g.socket, check=False)
    subprocess.Popen(["nohup", g.binary], env=env, stdout=open(os.path.join(OUT, "app-relaunch.out"), "a"),
                     stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(120):
        if os.path.exists(g.socket):
            break
        time.sleep(0.5)
    time.sleep(6)
    after = {}
    for name in ("operator", "child", "external"):
        pass
    after["launch"] = {p: {"family": g.origin(p), "sheet_subtitle": g.subtitle(p)} for p in ids["launch"]}
    for name in ("operator", "child", "external"):
        after[name] = {"family": g.origin(ids[name]), "sheet_subtitle": g.subtitle(ids[name])}
    if launch_root:
        after["operator_node_stripped"] = {"family": g.origin(launch_root["id"]),
                                         "sheet_subtitle": g.subtitle(launch_root["id"])}
    record("after_restart", after)
    g.c11("rpc", "debug.panel_sheet.open", json.dumps({"surface_id": ids["external"]}), check=False)
    time.sleep(1.0)
    sh("/usr/sbin/screencapture", "-x", os.path.join(OUT, "sheet-restored.png"), check=False)


if __name__ == "__main__":
    phase, app, socket = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(OUT, exist_ok=True)
    {"cases": cases, "restart": restart}[phase](Guest(app, socket))
