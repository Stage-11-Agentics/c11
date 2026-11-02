#!/usr/bin/env python3
"""C11-576: an explicit target that does not resolve fails closed on every command.

Drives the CLI built from the change under test (C11_CLI_BIN) against a fake
socket; no app, GUI or operator session is used. The fake follows the app's
contract: a routing key that names nothing is refused with not_found, an absent
key takes the documented default (the selected workspace, the focused panel).

Every row runs twice, with a short ref left over from an earlier launch and
with an unknown UUID, and must:
  * exit nonzero and report not_found;
  * get no mutating request accepted (nothing created, typed, written);
  * never send a request carrying a live target the caller did not name (no
    fallback to the selected workspace or focused panel).
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

from concurrent.futures import ThreadPoolExecutor
import copy
import json
import shlex
import socketserver
import subprocess
import tempfile
import threading
import uuid

from fake_server_env import fake_server_env
from test_cli_socket_deadline import resolve_c11_cli


def ident(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "c11-576/" + name))


WINDOW = {"id": ident("window"), "ref": "window:1", "index": 0, "key": True, "visible": True}
WORKSPACES = [
    {"id": ident(f"ws{i}"), "ref": f"workspace:{i + 1}", "index": i, "title": f"WS {i}",
     "selected": i == 0, "window_id": WINDOW["id"], "window_ref": WINDOW["ref"]}
    for i in range(2)
]
AREAS = [
    {"id": ident(f"area{i}"), "ref": f"area:{i + 1}", "index": 0, "focused": True,
     "panel_count": 1, "workspace_id": WORKSPACES[i]["id"]}
    for i in range(2)
]
PANELS = [
    {"id": ident(f"panel{i}"), "ref": f"panel:{i + 1}", "index": 0, "index_in_area": 0,
     "title": f"panel {i}", "type": "terminal", "focused": True, "selected": True,
     "selected_in_area": True, "area_id": AREAS[i]["id"], "area_ref": AREAS[i]["ref"],
     "workspace_id": WORKSPACES[i]["id"], "workspace_ref": WORKSPACES[i]["ref"]}
    for i in range(2)
]
KINDS = {"window": [WINDOW], "workspace": WORKSPACES, "area": AREAS, "panel": PANELS}
ROUTING_KEYS = {
    "window_id": "window", "workspace_id": "workspace", "pane_id": "area", "area_id": "area",
    "surface_id": "panel", "panel_id": "panel", "tab_id": "panel",
}
LIVE_VALUES = {v for items in KINDS.values() for item in items for v in (item["id"], item["ref"])}

# Methods that only read state. Anything else that the fake accepts is a mutation.
READ_ONLY = {
    "system.capabilities", "system.identify", "system.tree", "system.ping", "auth.login",
    "window.list", "window.current", "workspace.list", "workspace.current", "area.list",
    "area.panels", "panel.list", "panel.current", "panel.get_metadata", "panel.input_state",
    "panel.get_titlebar_state", "panel.locate", "sidebar.state", "workspace.group.list",
    "config.list", "flag.kind.list", "workspace.get_metadata", "flag.list", "panel.family",
    "browser.profiles.list", "mailbox.resolve",
}
V1_READ_ONLY = {"auth", "list_status", "list_log", "list_meta", "ping"}

FEATURES = [
    "vocabulary.workspace_area_panel", "send.explicit_panel", "routing.canonical_keys",
    "create.initial_input", "send.raw", "read_selection.terminal", "input_state.terminal",
    "window.route_without_focus", "window.resize", "cli.rpc", "browser.profiles",
    "markdown.agent_cli", "links.panel", "links.terminal", "fleet",
]


def canonical_ref(value: str) -> str:
    if ":" not in value:
        return value
    prefix, rest = value.split(":", 1)
    prefix = prefix.lower()
    return {"tab": "panel", "surface": "panel", "pane": "area"}.get(prefix, prefix) + ":" + rest


def find(kind: str, value) -> dict | None:
    if not isinstance(value, str):
        return None
    for item in KINDS[kind]:
        if item["id"].lower() == value.strip().lower() or item["ref"] == canonical_ref(value.strip()):
            return item
    return None


class RPCError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.payload = {"code": code, "message": message}


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            wire = line.decode().strip()
            if not wire.startswith("{"):
                try:
                    response = self.server.dispatch_v1(wire)
                except RPCError as error:
                    response = "ERROR: " + error.payload["code"] + ": " + error.payload["message"]
            else:
                request = json.loads(wire)
                method, params = request["method"], request.get("params", {}) or {}
                try:
                    result = self.server.dispatch(method, params)
                    response = json.dumps({"id": request.get("id"), "ok": True, "result": result})
                except RPCError as error:
                    response = json.dumps({"id": request.get("id"), "ok": False, "error": error.payload})
            self.wfile.write((response + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str) -> None:
        self.lock = threading.Lock()
        self.calls: list[tuple[str, dict]] = []
        self.accepted_mutations: list[tuple[str, dict]] = []
        super().__init__(path, Handler)

    def reset(self) -> None:
        with self.lock:
            self.calls = []
            self.accepted_mutations = []

    def check_routing(self, params: dict) -> None:
        for key, kind in ROUTING_KEYS.items():
            if key in params and params[key] is not None and find(kind, params[key]) is None:
                raise RPCError("not_found", f"Unknown {key}: {params[key]}")

    def dispatch(self, method: str, params: dict) -> dict:
        with self.lock:
            self.calls.append((method, copy.deepcopy(params)))
        if method == "system.capabilities":
            return {"methods": sorted(READ_ONLY | {
                        "panel.create", "area.create", "workspace.create", "agent.launch",
                        "panel.send_text", "panel.send_key", "panel.set_metadata", "panel.clear_metadata",
                        "panel.trigger_flash", "browser.open_split", "markdown.open", "flag.raise",
                        "workspace.set_metadata", "workspace.rename", "panel.focus", "area.focus"}),
                    "features_version": 1,
                    "features": [{"id": name, "version": 1} for name in FEATURES],
                    "server": {"version": "synthetic", "commit": "synthetic"}}
        self.check_routing(params)
        workspace = find("workspace", params.get("workspace_id")) or WORKSPACES[0]
        if method == "window.list":
            return {"windows": [dict(WINDOW, workspace_count=len(WORKSPACES))]}
        if method == "window.current":
            return {"window_id": WINDOW["id"], "window_ref": WINDOW["ref"]}
        if method == "workspace.list":
            return {"window_id": WINDOW["id"], "window_ref": WINDOW["ref"], "workspaces": copy.deepcopy(WORKSPACES)}
        if method == "workspace.current":
            return {"workspace_id": WORKSPACES[0]["id"], "workspace_ref": WORKSPACES[0]["ref"],
                    "window_id": WINDOW["id"], "window_ref": WINDOW["ref"]}
        if method == "panel.list":
            return {"workspace_id": workspace["id"], "workspace_ref": workspace["ref"],
                    "window_id": WINDOW["id"], "window_ref": WINDOW["ref"],
                    "panels": [copy.deepcopy(p) for p in PANELS if p["workspace_id"] == workspace["id"]]}
        if method == "area.list":
            return {"workspace_id": workspace["id"], "workspace_ref": workspace["ref"],
                    "areas": [copy.deepcopy(a) for a in AREAS if a["workspace_id"] == workspace["id"]]}
        if method == "system.identify":
            panel = PANELS[0]
            focused = {"window_id": WINDOW["id"], "window_ref": WINDOW["ref"],
                       "workspace_id": panel["workspace_id"], "workspace_ref": panel["workspace_ref"],
                       "area_id": panel["area_id"], "area_ref": panel["area_ref"],
                       "panel_id": panel["id"], "panel_ref": panel["ref"]}
            return {"focused": focused, "caller": None}
        if method in READ_ONLY:
            return {"workspace_id": workspace["id"], "workspace_ref": workspace["ref"]}
        with self.lock:
            self.accepted_mutations.append((method, copy.deepcopy(params)))
        return {"workspace_id": workspace["id"], "workspace_ref": workspace["ref"],
                "panel_id": PANELS[0]["id"], "panel_ref": PANELS[0]["ref"]}

    def dispatch_v1(self, wire: str) -> str:
        args = shlex.split(wire)
        command = args[0] if args else ""
        with self.lock:
            self.calls.append((command, {"wire": wire}))
        if command in ("auth", "ping"):
            return "OK" if command == "auth" else "PONG"
        options = {}
        for arg in args[1:]:
            if arg.startswith("--") and "=" in arg:
                key, value = arg[2:].split("=", 1)
                options[key] = value
        if "tab" in options and find("workspace", options["tab"]) is None and find("panel", options["tab"]) is None:
            raise RPCError("not_found", f"Tab not found: {options['tab']}")
        for key in ("surface", "panel"):
            if key in options and find("panel", options[key]) is None:
                raise RPCError("not_found", f"Panel not found: {options[key]}")
        if command not in V1_READ_ONLY:
            with self.lock:
                self.accepted_mutations.append((command, {"wire": wire}))
        return "OK"


LIVE_WS = WORKSPACES[1]["ref"]  # a valid, non-selected workspace for rows that also need a live one

# Each row: (label, argv with {window}/{workspace}/{area}/{panel} placeholders).
ROWS = [
    ("list-panels", "list-panels --workspace {workspace}"),
    ("list-areas", "list-areas --workspace {workspace}"),
    ("new-panel workspace", "new-panel --workspace {workspace}"),
    ("new-panel area", "new-panel --area {area}"),
    ("new-area workspace", "new-area --workspace {workspace}"),
    ("new-area browser", "new-area --workspace {workspace} --type browser --url about:blank"),
    ("new-workspace window", "--window {window} new-workspace"),
    ("list-panels window", "--window {window} list-panels"),
    ("launch-agent workspace", "launch-agent --type claude-code --workspace {workspace}"),
    ("launch-agent area", "launch-agent --type claude-code --area {area}"),
    ("send", "send --workspace {workspace} --panel {panel} -- echo stale"),
    ("send panel only", "send --panel {panel} -- echo stale"),
    ("send-key", "send-key --panel {panel} enter"),
    ("set-status", "set-status --workspace {workspace} stale value"),
    ("set-status panel", "set-status --workspace " + LIVE_WS + " --panel {panel} stale value"),
    ("set-progress", "set-progress --workspace {workspace} 0.5"),
    ("log", "log --workspace {workspace} -- stale"),
    ("clear-status", "clear-status --workspace {workspace} stale"),
    ("clear-progress", "clear-progress --workspace {workspace}"),
    ("clear-log", "clear-log --workspace {workspace}"),
    ("list-status", "list-status --workspace {workspace}"),
    ("list-log", "list-log --workspace {workspace}"),
    ("sidebar-state", "sidebar-state --workspace {workspace}"),
    ("browser open panel", "browser open --panel {panel} about:blank"),
    ("browser open area", "browser open --area {area} about:blank"),
    ("browser open workspace", "browser open --workspace {workspace} about:blank"),
    ("markdown open panel", "markdown open --panel {panel} {md}"),
    ("markdown open workspace", "markdown open --workspace {workspace} {md}"),
    ("set-metadata", "set-metadata --panel {panel} --key stale --value v"),
    ("set-metadata workspace", "set-metadata --workspace {workspace} --key stale --value v"),
    ("clear-metadata", "clear-metadata --panel {panel} --key stale"),
    ("rename-panel", "rename-panel --panel {panel} stale"),
    ("set-title", "set-title --panel {panel} stale"),
    ("set-description", "set-description --panel {panel} stale"),
    ("set-agent", "set-agent --panel {panel} --type claude"),
    ("set-panel-icon", "set-panel-icon --panel {panel} X"),
    ("set-panel-color", "set-panel-color --panel {panel} teal"),
    ("trigger-flash", "trigger-flash --panel {panel}"),
    ("raise-flag", "raise-flag --by operator --panel {panel} stale"),
]


def stale_values(kind: str) -> list[tuple[str, str]]:
    # A short ref minted by an earlier launch, and a UUID nothing has.
    return [("stale-ref", f"{kind}:99"), ("unknown-uuid", ident(f"missing/{kind}"))]


def run_row(cli: str, socket_path: str, server: Server, md: str, label: str, template: str, variant: str) -> list[str]:
    values = {kind: dict(stale_values(kind))[variant] for kind in KINDS}
    argv = [part.format(md=md, **values) for part in shlex.split(template)]
    with server.lock:
        server.calls = []
        server.accepted_mutations = []
    env = fake_server_env(socket_path)
    env["C11_SOCKET_PASSWORD"] = ""
    proc = subprocess.run([cli, "--json", *argv], env=env, capture_output=True, text=True, timeout=30)
    out = proc.stdout + proc.stderr
    failures = []
    name = f"{label} [{variant}]"
    if proc.returncode == 0:
        failures.append(f"{name}: exited 0: {out.strip()[:300]}")
    if "not_found" not in out:
        failures.append(f"{name}: no not_found in output: {out.strip()[:300]}")
    with server.lock:
        mutations = list(server.accepted_mutations)
        calls = list(server.calls)
    if mutations:
        failures.append(f"{name}: mutation accepted: {mutations}")
    # No fallback: wherever a request carries a key of a kind the caller named,
    # it carries the named value. An omitted flag may still take its default
    # (rename-panel without --workspace sends the selected workspace).
    named_kinds = {kind for kind in KINDS if "{" + kind + "}" in template}
    for method, params in calls:
        if method in READ_ONLY and method not in ("sidebar.state", "panel.get_metadata"):
            continue  # listing live state to resolve a handle is not a fallback
        if "wire" in params:
            options = dict(arg[2:].split("=", 1) for arg in shlex.split(params["wire"])[1:]
                           if arg.startswith("--") and "=" in arg)
            pairs = [("workspace" if find("workspace", v) or k == "tab" and not find("panel", v) else "panel", v)
                     for k, v in options.items() if k in ("tab", "surface", "panel")]
        else:
            pairs = [(ROUTING_KEYS[k], params[k]) for k in ROUTING_KEYS if isinstance(params.get(k), str)]
        for kind, value in pairs:
            if kind in named_kinds and value != values[kind]:
                failures.append(f"{name}: {method} sent {kind}={value}, not the named {values[kind]}")
    return failures


def main() -> int:
    cli = resolve_c11_cli()
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="c11-576-") as tmp:
        md = os.path.join(tmp, "note.md")
        with open(md, "w") as handle:
            handle.write("# stale\n")

        def group(variant: str) -> list[str]:
            path = os.path.join(tmp, f"{variant}.sock")
            server = Server(path)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            out: list[str] = []
            try:
                for label, template in ROWS:
                    out += run_row(cli, path, server, md, label, template, variant)
            finally:
                server.shutdown()
                server.server_close()
            return out

        with ThreadPoolExecutor(max_workers=2) as pool:
            for result in pool.map(group, ["stale-ref", "unknown-uuid"]):
                failures += result

        # Omitting the flag keeps the default: list-panels reads the selected workspace.
        path = os.path.join(tmp, "default.sock")
        server = Server(path)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            env = fake_server_env(path)
            proc = subprocess.run([cli, "--json", "list-panels"], env=env, capture_output=True, text=True, timeout=30)
            if proc.returncode != 0 or PANELS[0]["id"] not in proc.stdout and PANELS[0]["ref"] not in proc.stdout:
                failures.append(f"default list-panels: rc={proc.returncode} {proc.stdout.strip()[:300]} {proc.stderr.strip()[:300]}")
        finally:
            server.shutdown()
            server.server_close()

    for failure in failures:
        print("FAIL", failure)
    total = len(ROWS) * 2 + 1
    print(f"{total - len(failures)}/{total} checks passed" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
