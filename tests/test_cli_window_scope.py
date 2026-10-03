#!/usr/bin/env python3
"""C11-283: exercise window routing through a CLI subprocess and fake socket.

Run with C11_CLI_BIN set to the CLI built from the change under test (for the
1.0 run, retrieved from Atlas). No app, GUI, or operator session is used.
The fake server intentionally defaults to key window A; only explicit routing
can reach B. Both windows use the same local numeric indexes and distinct refs.
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shlex
import socketserver
import subprocess
import tempfile
import threading
import uuid

from fake_server_env import fake_server_env
from test_cli_socket_deadline import resolve_c11_cli


def identifier(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "c11-window-scope/" + name))


def fixture() -> list[dict]:
    windows = []
    for wi, name in enumerate(("A", "B")):
        workspaces = []
        for index in range(2):
            ordinal = (wi + 1) * 10 + index
            workspace = {"id": identifier(f"{name}/workspace/{index}"),
                         "ref": f"workspace:{ordinal}", "index": index,
                         "title": f"{name} workspace {index}", "selected": index == 0,
                         "areas": [], "tabs": [], "status": {},
                         "notifications": [f"{name}-notification-{index}"]}
            for ti in range(2):
                area = {"id": identifier(f"{name}/{index}/area/{ti}"),
                        "ref": f"area:{ordinal * 10 + ti}", "index": ti,
                        "focused": ti == 0, "tab_count": 1}
                tab = {"id": identifier(f"{name}/{index}/tab/{ti}"),
                       "ref": f"tab:{ordinal * 100 + ti}", "index": ti,
                       "index_in_area": 0, "title": f"{name} tab {index}/{ti}",
                       "type": "terminal", "area_id": area["id"], "area_ref": area["ref"],
                       "selected": True, "selected_in_area": True,
                       "text": f"{name} screen {index}/{ti}", "metadata": {}}
                workspace["areas"].append(area)
                workspace["tabs"].append(tab)
            workspaces.append(workspace)
        windows.append({"id": identifier(f"window/{name}"), "ref": f"window:{wi + 1}",
                        "index": wi, "key": wi == 0, "visible": True,
                        "workspace_count": len(workspaces), "workspaces": workspaces})
    return windows


def matches(item: dict, token: str | None) -> bool:
    return token is not None and token in (item["id"], item["ref"])


class RPCError(Exception):
    def __init__(self, code: str, message: str) -> None:
        self.payload = {"code": code, "message": message}


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            wire = line.decode().strip()
            if not wire.startswith("{"):
                self.server.calls.append((wire, {}))
                if wire.startswith("auth "):
                    response = "OK"
                elif wire.startswith("focus_window "):
                    try:
                        self.server.focus(wire.split(" ", 1)[1])
                        response = "OK"
                    except RPCError as error:
                        response = "ERROR: " + error.payload["message"]
                else:
                    try:
                        response = self.server.dispatch_v1(wire)
                    except RPCError as error:
                        response = "ERROR: " + error.payload["message"]
            else:
                request = json.loads(wire)
                method, params = request["method"], request.get("params", {})
                self.server.calls.append((method, copy.deepcopy(params)))
                try:
                    payload = self.server.dispatch(method, params)
                    response = json.dumps({"id": request["id"], "ok": True, "result": payload})
                except RPCError as error:
                    response = json.dumps({"id": request["id"], "ok": False, "error": error.payload})
            self.wfile.write((response + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str) -> None:
        self.tree_mode = "ignores_scope"
        self.reset()
        super().__init__(path, Handler)

    def reset(self) -> None:
        self.windows = fixture()
        self.calls = []
        self.mutations = []

    def window(self, params: dict) -> dict:
        token = params.get("window_id")
        if token is not None:
            for item in self.windows:
                if matches(item, token):
                    return item
            raise RPCError("not_found", f"Window not found: {token}")
        # Existing server behavior: a globally addressed workspace/tab can
        # locate its manager, while an unqualified request uses the key window.
        for item in self.windows:
            for workspace in item["workspaces"]:
                if matches(workspace, params.get("workspace_id")) or any(
                    matches(tab, params.get("tab_id")) for tab in workspace["tabs"]
                ):
                    return item
        return next(item for item in self.windows if item["key"])

    def workspace(self, window: dict, params: dict) -> dict:
        token = params.get("workspace_id")
        if token is not None:
            for item in window["workspaces"]:
                if matches(item, token):
                    return item
            raise RPCError("not_found", f"Workspace not found: {token}")
        tab_token = params.get("tab_id")
        if tab_token is not None:
            for item in window["workspaces"]:
                if any(matches(tab, tab_token) for tab in item["tabs"]):
                    return item
            raise RPCError("not_found", f"Tab not found: {tab_token}")
        return next(item for item in window["workspaces"] if item["selected"])

    def target(self, workspace: dict, kind: str, params: dict) -> dict:
        token = params.get(f"{kind}_id")
        items = workspace["areas" if kind == "area" else "tabs"]
        if token is not None:
            for item in items:
                if matches(item, token):
                    return item
            raise RPCError("not_found", f"{kind.title()} not found: {token}")
        return items[0]

    def focus(self, token: str) -> dict:
        window = self.window({"window_id": token})
        for item in self.windows:
            item["key"] = item is window
        self.mutations.append(("focus", window["ref"]))
        return window

    def dispatch_v1(self, wire: str) -> str:
        args = shlex.split(wire)
        command = args[0]
        options = {}
        for index, arg in enumerate(args[1:], 1):
            if arg.startswith("--") and "=" in arg:
                key, value = arg[2:].split("=", 1)
                options[key] = value
            elif arg.startswith("--") and index + 1 < len(args):
                options[arg[2:]] = args[index + 1]
        if command == "close_window":
            window = self.window({"window_id": args[1]})
            self.windows.remove(window)
            self.mutations.append((command, window["ref"]))
            return "OK"
        if command in ("drag_surface_to_split", "refresh_surfaces", "default_agent"):
            params = {"workspace_id": options["workspace"]} if "workspace" in options else {}
            window = self.window(params)
            workspace = self.workspace(window, params)
            if command == "drag_surface_to_split":
                raw = args[1]
                tab = next((item for item in workspace["tabs"]
                            if matches(item, raw) or str(item["index"]) == raw), None)
                if tab is None:
                    raise RPCError("not_found", f"Tab not found: {raw}")
                tab.setdefault("splits", []).append(args[2])
            elif command == "refresh_surfaces":
                for tab in workspace["tabs"]:
                    tab["refresh_count"] = tab.get("refresh_count", 0) + 1
            elif "in-surface" in options:
                tab = self.target(workspace, "tab", {"tab_id": options["in-surface"]})
                tab["launch_count"] = tab.get("launch_count", 0) + 1
            else:
                tab = copy.deepcopy(workspace["tabs"][0])
                tab.update(id=identifier("legacy-agent/tab"), ref="tab:9002", index=len(workspace["tabs"]))
                workspace["tabs"].append(tab)
            self.mutations.append((command, window["ref"], workspace["ref"]))
            return "OK"
        if command == "clear_notifications":
            # This legacy endpoint really clears every window when unqualified.
            if "tab" not in options:
                workspaces = [(window, workspace) for window in self.windows
                              for workspace in window["workspaces"]]
            else:
                params = {"workspace_id": options["tab"]}
                window = self.window(params)
                workspaces = [(window, self.workspace(window, params))]
            for window, workspace in workspaces:
                workspace["notifications"].clear()
                self.mutations.append((command, window["ref"], workspace["ref"]))
            return "OK"
        if command in ("set_status", "clear_status", "set_progress", "clear_progress", "log", "clear_log"):
            params = {"workspace_id": options["tab"]} if "tab" in options else {}
            window = self.window(params)
            workspace = self.workspace(window, params)
            if "surface" in options:
                self.target(workspace, "tab", {"tab_id": options["surface"]})
            positionals = [arg for arg in args[1:] if not arg.startswith("--")]
            workspace["status"][command] = positionals
            self.mutations.append((command, window["ref"], workspace["ref"]))
            return "OK"
        raise RPCError("method_not_found", f"Unexpected v1 command: {command}")

    @staticmethod
    def context(window: dict, workspace: dict, tab: dict | None = None) -> dict:
        result = {"window_id": window["id"], "window_ref": window["ref"],
                  "workspace_id": workspace["id"], "workspace_ref": workspace["ref"]}
        if tab is not None:
            result.update(tab_id=tab["id"], tab_ref=tab["ref"],
                          area_id=tab["area_id"], area_ref=tab["area_ref"])
        return result

    def dispatch(self, method: str, params: dict) -> dict:
        if method == "system.capabilities":
            return {"methods": ["window.list", "workspace.list", "workspace.current",
                                "workspace.select", "area.list", "area.tabs", "area.create",
                                "tab.list", "tab.read_text", "tab.send_text", "tab.send_key",
                                "tab.create", "tab.split", "tab.get_metadata", "tab.set_metadata",
                                "system.identify", "system.tree", "workspace.group.list",
                                "notification.create", "notification.create_for_tab", "sidebar.state",
                                "flag.raise", "flag.lower", "flag.suppress", "flag.unsuppress",
                                "snapshot.create", "snapshot.restore", "snapshot.restore_set",
                                "tab.get_titlebar_state", "area.swap", "area.join",
                                "tab.move", "tab.reorder", "config.launch"],
                    "features_version": 1,
                    "features": [{"id": name, "version": 1} for name in
                                 ("vocabulary.workspace_area_tab", "send.explicit_tab",
                                  "window.route_without_focus", "send.raw")],
                    "server": {"version": "synthetic", "commit": "synthetic"}}
        if method == "window.list":
            return {"windows": [{k: copy.deepcopy(v) for k, v in item.items() if k != "workspaces"}
                                for item in self.windows]}
        if method == "window.focus":
            return self.context(self.focus(params["window_id"]), self.windows[1]["workspaces"][0])
        if method == "system.tree":
            if self.tree_mode == "unsupported":
                raise RPCError("method_not_found", "system.tree is unavailable")
            # Actual scope semantics: default selects one workspace of the
            # key window; --window selects all its workspaces; --all all windows.
            # The pre-fix modern server accepts, but ignores, window_id.
            key = next(item for item in self.windows if item["key"])
            target = self.window(params) if self.tree_mode == "scoped" else key
            scope = params.get("scope", "workspace")
            explicit_workspace = params.get("workspace_id")
            if explicit_workspace is not None:
                # Existing system.tree resolves explicit workspace handles
                # globally even when it ignores window_id.
                if self.tree_mode != "scoped":
                    target = self.window({"workspace_id": explicit_workspace})
                selected = self.workspace(target, {"workspace_id": explicit_workspace})
                window_node = copy.deepcopy(target)
                window_node["workspaces"] = [copy.deepcopy(selected)]
                return {"active": self.context(key, key["workspaces"][0], key["workspaces"][0]["tabs"][0]),
                        "caller": None, "windows": [window_node]}
            windows = copy.deepcopy(self.windows if scope == "all" else [target])
            if scope == "workspace":
                windows[0]["workspaces"] = [item for item in windows[0]["workspaces"] if item["selected"]]
            return {"active": self.context(key, key["workspaces"][0], key["workspaces"][0]["tabs"][0]),
                    "caller": None, "windows": windows}
        if method in ("tab.move", "tab.reorder"):
            # Existing endpoints locate the source globally and ignore window
            # routing for source membership. CLI admission must guard this seam.
            window = self.window({"tab_id": params.get("tab_id")})
            workspace = self.workspace(window, {"tab_id": params.get("tab_id")})
            tab = self.target(workspace, "tab", params)
            if method == "tab.move":
                # window_id is a destination selector, not source scope. Even
                # same-window injection chooses its selected workspace, which
                # would silently relocate a tab from a nonselected workspace.
                destination_params = {key: params[key] for key in ("window_id", "workspace_id") if key in params}
                destination_window = self.window(destination_params) if destination_params else window
                destination = self.workspace(destination_window, destination_params) if destination_params else workspace
                if "area_id" in params:
                    area = self.target(destination, "area", params)
                    tab["area_id"], tab["area_ref"] = area["id"], area["ref"]
                if destination is not workspace:
                    workspace["tabs"].remove(tab)
                    destination["tabs"].append(tab)
                    if "area_id" not in params:
                        tab["area_id"], tab["area_ref"] = destination["areas"][0]["id"], destination["areas"][0]["ref"]
                    workspace = destination
                    window = destination_window
                if "index" in params:
                    workspace["tabs"].remove(tab)
                    workspace["tabs"].insert(params["index"], tab)
            else:
                workspace["tabs"].remove(tab)
                workspace["tabs"].insert(params.get("index", 0), tab)
            self.mutations.append((method, window["ref"], workspace["ref"], tab["ref"]))
            return self.context(window, workspace, tab)
        if method in ("area.swap", "area.join"):
            # These endpoints locate handles globally. Validate scoped area
            # and tab membership in the client before entering this endpoint.
            def locate_area(token: str) -> tuple[dict, dict, dict]:
                for item in self.windows:
                    for ws in item["workspaces"]:
                        for area in ws["areas"]:
                            if matches(area, token):
                                return item, ws, area
                raise RPCError("not_found", f"Area not found: {token}")

            window, workspace, source = locate_area(params["area_id"])
            _, _, target = locate_area(params["target_area_id"])
            if method == "area.swap":
                for tab in workspace["tabs"]:
                    replacement = target if tab["area_id"] == source["id"] else source
                    tab["area_id"], tab["area_ref"] = replacement["id"], replacement["ref"]
            else:
                tabs = [self.target(workspace, "tab", params)] if "tab_id" in params else workspace["tabs"]
                for tab in tabs:
                    if tab["area_id"] == source["id"]:
                        tab["area_id"], tab["area_ref"] = target["id"], target["ref"]
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return self.context(window, workspace)
        window = self.window(params)
        if method == "workspace.list":
            # The real handler ignores workspace_id as a filter and lists
            # every workspace of the resolved window. It also does not reject
            # a foreign workspace_id when a valid window_id was supplied.
            selected = self.workspace(window, {})
            return {**self.context(window, selected), "workspaces": [
                {key: copy.deepcopy(value) for key, value in item.items() if key not in ("areas", "tabs")}
                for item in window["workspaces"]]}
        workspace = self.workspace(window, params)
        context = self.context(window, workspace)
        if method == "config.launch":
            # The CLI test models a server preserving scope through config ->
            # agent.launch. Real server forwarding requires a separate gate.
            if params.get("new_workspace"):
                workspace = copy.deepcopy(workspace)
                workspace.update(id=identifier("config/new-workspace"), ref="workspace:9000",
                                 index=len(window["workspaces"]), selected=False, title="Synthetic config")
                window["workspaces"].append(workspace)
                window["workspace_count"] += 1
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return self.context(window, workspace, workspace["tabs"][0])
        if method == "sidebar.state":
            return {**context, "status": copy.deepcopy(workspace["status"])}
        if method == "snapshot.create":
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return {**context, "snapshot_id": "synthetic-snapshot", "path": "synthetic-snapshot.json",
                    "tab_count": len(workspace["tabs"])}
        if method == "snapshot.restore":
            if params.get("in_place"):
                workspace = self.workspace(window, {"workspace_id": params["target_workspace_id"]})
                workspace["tabs"][0]["text"] = "Synthetic restored content"
            else:
                workspace = copy.deepcopy(workspace)
                workspace.update(id=identifier("restore/new-workspace"), ref="workspace:9001",
                                 index=len(window["workspaces"]), selected=False, title="Synthetic restore")
                window["workspaces"].append(workspace)
                window["workspace_count"] += 1
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return self.context(window, workspace)
        if method in ("notification.create", "notification.create_for_tab"):
            if method == "notification.create_for_tab":
                tab = self.target(workspace, "tab", params)
                context = self.context(window, workspace, tab)
            workspace["notifications"].append(params.get("title", "synthetic"))
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return context
        if method == "workspace.current":
            return context
        if method == "workspace.group.list":
            return {**context, "workspace_groups": []}
        if method == "workspace.select":
            for item in window["workspaces"]:
                item["selected"] = item is workspace
            self.mutations.append((method, window["ref"], workspace["ref"]))
            return context
        if method == "system.identify":
            return {"focused": self.context(window, workspace, workspace["tabs"][0]), "caller": None}
        if method == "area.list":
            return {**context, "areas": copy.deepcopy(workspace["areas"])}
        if method == "tab.list":
            return {**context, "tabs": copy.deepcopy(workspace["tabs"])}
        if method == "area.tabs":
            area = self.target(workspace, "area", params)
            return {**context, "area_id": area["id"], "area_ref": area["ref"],
                    "tabs": [copy.deepcopy(item) for item in workspace["tabs"]
                             if item["area_id"] == area["id"]]}
        if method in ("tab.create", "tab.split", "area.create"):
            if method == "tab.split":
                self.target(workspace, "tab", params)
            if method == "tab.create":
                area = self.target(workspace, "area", params)
            else:
                area = {"id": identifier(f"created/{len(self.mutations)}/area"),
                        "ref": "area:9000", "index": len(workspace["areas"]),
                        "focused": False, "tab_count": 1}
                workspace["areas"].append(area)
            tab = {"id": identifier(f"created/{len(self.mutations)}/tab"),
                   "ref": "tab:9000", "index": len(workspace["tabs"]), "type": "terminal",
                   "area_id": area["id"], "area_ref": area["ref"], "metadata": {}, "text": ""}
            workspace["tabs"].append(tab)
            self.mutations.append((method, window["ref"], workspace["ref"], tab["ref"]))
            return self.context(window, workspace, tab)
        tab = self.target(workspace, "tab", params)
        context = self.context(window, workspace, tab)
        if method.startswith("flag."):
            tab["attention"] = method
            self.mutations.append((method, window["ref"], workspace["ref"], tab["ref"]))
            return context
        if method == "tab.read_text":
            return {**context, "text": tab["text"]}
        if method == "tab.get_metadata":
            return {**context, "metadata": copy.deepcopy(tab["metadata"])}
        if method == "tab.get_titlebar_state":
            return {**context, "title": tab["metadata"].get("title", tab["title"]),
                    "description": tab["metadata"].get("description", "")}
        if method in ("tab.send_text", "tab.send_key", "tab.set_metadata"):
            if method == "tab.send_text":
                tab["text"] += params["text"]
            elif method == "tab.send_key":
                tab.setdefault("keys", []).append(params["key"])
            else:
                tab["metadata"].update(params["metadata"])
            self.mutations.append((method, window["ref"], workspace["ref"], tab["ref"]))
            return {**context, "metadata": copy.deepcopy(tab["metadata"]),
                    "submitted": bool(params.get("submit")), "queued": False, "delivered": True}
        raise RPCError("method_not_found", f"Unexpected method: {method}")


def main() -> int:
    explicit = os.environ.get("C11_CLI_BIN")
    if not explicit or not Path(explicit).is_file() or not os.access(explicit, os.X_OK):
        raise SystemExit("Set C11_CLI_BIN to the CLI built from this change; no bundled-CLI fallback.")
    cli = resolve_c11_cli()
    with tempfile.TemporaryDirectory(prefix="c11scope-") as directory:
        path = str(Path(directory) / "fake.sock")
        server = Server(path)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        a, b = fixture()
        a_ws, b_ws = a["workspaces"][0], b["workspaces"][0]
        a_tab, b_tab = a_ws["tabs"][0], b_ws["tabs"][0]
        caller = {"C11_TAB_ID": a_tab["id"], "CMUX_WORKSPACE_ID": a_ws["id"]}
        cases = 0

        def run(*args: str, window: str | None = b["ref"], success: bool = True,
                env: dict | None = None, reset: bool = True) -> subprocess.CompletedProcess:
            nonlocal cases
            if reset:
                server.reset()
            else:
                server.calls.clear()
            child_env = fake_server_env(path)
            child_env.update(env or {})
            prefix = [cli, "--socket", path, "--password", "synthetic-password", "--json", "--id-format", "both"]
            if window is not None:
                prefix += ["--window", window]
            proc = subprocess.run(prefix + list(args), env=child_env, text=True,
                                  capture_output=True, timeout=10)
            cases += 1
            assert (proc.returncode == 0) == success, (args, proc.returncode, proc.stdout, proc.stderr, server.calls)
            assert not any(method == "window.focus" for method, _ in server.calls), server.calls
            return proc

        def routed(method: str, *, destination: dict | None = None) -> dict:
            calls = [params for name, params in server.calls if name == method]
            assert calls, (method, server.calls)
            if method == "tab.move":
                # Source membership is admitted in B; the endpoint's window_id
                # only denotes an explicitly requested destination window.
                assert all(any(matches(tab, params.get("tab_id")) for workspace in b["workspaces"]
                               for tab in workspace["tabs"]) for params in calls), server.calls
                if destination is None:
                    assert all("window_id" not in params for params in calls), server.calls
                else:
                    assert all(matches(destination, params.get("window_id")) for params in calls), server.calls
            else:
                assert destination is None
                assert all(matches(b, params.get("window_id")) for params in calls), server.calls
            assert server.windows[0]["key"] and not server.windows[1]["key"], server.windows
            return calls[-1]

        def unchanged() -> None:
            assert not server.mutations and server.windows == fixture(), server.mutations

        try:
            # UUID, global ref, and 0-based window index all resolve B without focus.
            for token in (b["id"], b["ref"], "1"):
                payload = json.loads(run("read-screen", "--tab", b_tab["ref"], window=token).stdout)
                assert payload["text"] == b_tab["text"] and payload["window_id"] == b["id"], payload
                routed("tab.read_text")
                assert any(method == "window.list" for method, _ in server.calls), server.calls
                unchanged()

            # Ambient A caller identities cannot override B for fleet reads/create.
            payload = json.loads(run("read-screen", env=caller).stdout)
            assert payload["text"] == b_tab["text"], payload
            assert "tab_id" not in routed("tab.read_text"), server.calls
            unchanged()
            payload = json.loads(run("list-workspaces", env=caller).stdout)
            assert [item["ref"] for item in payload["workspaces"]] == [item["ref"] for item in b["workspaces"]]
            routed("workspace.list")
            unchanged()
            payload = json.loads(run("current-workspace", env=caller).stdout)
            assert payload["workspace_id"] == b_ws["id"], payload
            routed("workspace.current")
            unchanged()
            payload = json.loads(run("identify", env=caller).stdout)
            assert payload["focused"]["window_id"] == b["id"], payload
            assert "caller" not in routed("system.identify"), server.calls
            unchanged()

            # Numeric workspace 1 exists in both windows: resolve exclusively B.
            for command in ("read-screen", "select-workspace"):
                args = [command, "--workspace", "1"]
                if command == "read-screen":
                    args += ["--tab", "0"]
                payload = json.loads(run(*args).stdout)
                assert payload["workspace_id"] == b["workspaces"][1]["id"], payload
                routed("workspace.list")
                params = routed("tab.read_text" if command == "read-screen" else "workspace.select")
                assert matches(b["workspaces"][1], params["workspace_id"]), params
                if command == "read-screen":
                    routed("tab.list")
                    unchanged()
                else:
                    assert server.windows[1]["workspaces"][1]["selected"], server.windows
                    assert server.windows[0] == a, server.windows[0]

            # Bare tab/area indexes must resolve in B even without --workspace.
            payload = json.loads(run("read-screen", "--tab", "1").stdout)
            assert payload["text"] == b_ws["tabs"][1]["text"], payload
            routed("tab.list")
            routed("tab.read_text")
            unchanged()
            payload = json.loads(run("list-area-tabs", "--area", "1").stdout)
            assert [item["ref"] for item in payload["tabs"]] == [b_ws["tabs"][1]["ref"]], payload
            routed("area.list")
            routed("area.tabs")
            unchanged()
            for command, key, expected in (("list-areas", "areas", b_ws["areas"]),
                                           ("list-tabs", "tabs", b_ws["tabs"])):
                payload = json.loads(run(command).stdout)
                assert [item["ref"] for item in payload[key]] == [item["ref"] for item in expected], payload
                routed("area.list" if key == "areas" else "tab.list")
                unchanged()

            for args, method in ((["new-tab", "--area", "1", "--no-focus"], "tab.create"),
                                 (["new-split", "right", "--tab", "1"], "tab.split"),
                                 (["new-area", "--direction", "down"], "area.create")):
                payload = json.loads(run(*args, env=caller).stdout)
                assert payload["window_id"] == b["id"] and payload["workspace_id"] == b_ws["id"], payload
                routed(method)
                if method == "tab.create":
                    assert matches(b_ws["areas"][1], routed(method)["area_id"])
                    routed("area.list")
                elif method == "tab.split":
                    assert matches(b_ws["tabs"][1], routed(method)["tab_id"])
                    routed("tab.list")
                assert len(server.windows[1]["workspaces"][0]["tabs"]) == 3
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations

            for command, content, method in (("send", "B-only-sentinel", "tab.send_text"),
                                             ("send-key", "enter", "tab.send_key")):
                run(command, "--tab", "1", content, env=caller)
                params = routed(method)
                routed("tab.list")
                assert matches(b_ws["tabs"][1], params["tab_id"]), params
                changed_tab = server.windows[1]["workspaces"][0]["tabs"][1]
                assert content in (changed_tab["text"] if command == "send" else changed_tab["keys"])
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations

                # Suppression of caller env IDs must also suppress their admission.
                out = run(command, content, env=caller, success=False)
                assert "requires --tab" in out.stderr, out.stderr
                assert not any(name == method for name, _ in server.calls), server.calls
                unchanged()
                out = run(command, "--tab", a_tab["ref"], content, success=False)
                assert "not_found" in out.stderr, out.stderr
                routed(method)
                unchanged()

            # Merged send parsing must preserve window admission for aliases
            # and raw sends while retaining the new payload semantics.
            for command, flags, content, expected in (
                    ("send-tab", [], r"B-alias\n", "B-alias\r"),
                    ("paste", ["--no-submit"], r"B-paste\n", r"B-paste\n"),
                    ("send", ["--raw", "--no-submit"], r"B-raw\n", r"B-raw\n")):
                run(command, *flags, "--tab", "1", content, env=caller)
                params = routed("tab.send_text")
                assert matches(b_ws["tabs"][1], params["tab_id"]), params
                assert params["text"] == expected, params
                if command == "paste" or "--raw" in flags:
                    assert params["preserve_newlines"] and not params["submit"], params
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                assert server.windows[0]["key"] and not server.windows[1]["key"]
                out = run(command, *flags, content, env=caller, success=False)
                assert "requires --tab" in out.stderr, out.stderr
                assert not any(name == "tab.send_text" for name, _ in server.calls), server.calls
                unchanged()
                out = run(command, *flags, "--tab", a_tab["ref"], content, env=caller, success=False)
                assert "not_found" in out.stderr, out.stderr
                unchanged()

            # Metadata helpers must carry scope through target resolution and dispatch.
            run("set-metadata", "--tab", "1", "--key", "scope-test", "--value", "B-only")
            routed("tab.list")
            routed("tab.set_metadata")
            assert server.windows[1]["workspaces"][0]["tabs"][1]["metadata"] == {"scope-test": "B-only"}
            assert server.windows[0] == a, server.windows[0]
            payload = json.loads(run("get-metadata", "--tab", "1", reset=False).stdout)
            assert payload["metadata"] == {"scope-test": "B-only"}, payload
            routed("tab.get_metadata")

            # Title helpers ignore A caller workspace when an explicit B tab
            # is supplied; get-titlebar-state reads those same applied values.
            for command, key, value, reset in (("set-title", "title", "Scoped title", True),
                                                ("set-description", "description", "Scoped description", False)):
                run(command, "--tab", b_tab["id"], value, env=caller, reset=reset)
                routed("tab.set_metadata")
                assert server.windows[1]["workspaces"][0]["tabs"][0]["metadata"][key] == value
                assert server.windows[0] == a, server.windows[0]
            payload = json.loads(run("get-titlebar-state", "--tab", b_tab["id"], env=caller, reset=False).stdout)
            assert payload["title"] == "Scoped title" and payload["description"] == "Scoped description", payload
            routed("tab.get_titlebar_state")
            assert len(server.mutations) == 2 and server.windows[0] == a, server.mutations

            # v1 notification clearing and sidebar writes need an explicit
            # selected-workspace UUID because their wire protocol has no window.
            for extra, expected_ws in (([], b_ws), (["--workspace", "1"], b["workspaces"][1])):
                run("clear-notifications", *extra, env=caller)
                assert server.windows[0] == a, server.windows[0]
                assert len(server.mutations) == 1 and server.mutations[0][2] == expected_ws["ref"], server.mutations
                assert not server.windows[1]["workspaces"][expected_ws["index"]]["notifications"]
                commands = [name for name, _ in server.calls if name.startswith("clear_notifications")]
                assert len(commands) == 1 and f"--tab={expected_ws['id']}" in commands[0], commands
            # A global --window scopes the lookup; it does not replace the
            # caller's workspace. Reject A under B without dispatching a write.
            out = run("set-status", "scope-test", "B-only", env=caller, success=False)
            assert "not_found" in out.stderr, out.stderr
            assert not any(name.startswith("set_status") for name, _ in server.calls), server.calls
            unchanged()
            # An explicit B workspace is valid and overrides the A caller env.
            run("set-status", "scope-test", "B-only", "--workspace", b_ws["id"], env=caller)
            assert server.windows[1]["workspaces"][0]["status"] == {"set_status": ["scope-test", "B-only"]}
            assert server.windows[0] == a and server.mutations == [
                ("set_status", b["ref"], b_ws["ref"])
            ], server.mutations
            for args in (("--workspace", a_ws["id"]), ("--workspace", a_ws["ref"]),
                         ("--tab", a_ws["id"]), ("--tab", a_ws["ref"]),
                         ("--tab", a_tab["id"]), ("--tab", a_tab["ref"])):
                run("set-status", "scope-test", "foreign", *args, env=caller, success=False)
                assert not any(name.startswith("set_status") for name, _ in server.calls), server.calls
                unchanged()
            run("clear-notifications", "--workspace", a_ws["id"], success=False)
            assert not any(name.startswith("clear_notifications") for name, _ in server.calls), server.calls
            unchanged()

            for extra, expected_ws in (([], b_ws), (["--workspace", "1"], b["workspaces"][1])):
                payload = json.loads(run("sidebar-state", *extra, env=caller).stdout)
                assert payload["workspace_id"] == expected_ws["id"], payload
                routed("sidebar.state")
                unchanged()
            for extra, method in (([], "notification.create"),
                                  (["--tab", "1"], "notification.create_for_tab")):
                payload = json.loads(run("notify", "--title", "B-only", *extra, env=caller).stdout)
                assert payload["workspace_id"] == b_ws["id"], payload
                routed(method)
                if extra:
                    assert payload["tab_id"] == b_ws["tabs"][1]["id"], payload
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                assert server.windows[1]["workspaces"][0]["notifications"][-1] == "B-only"
            run("notify", "--title", "foreign", "--tab", a_tab["ref"], success=False)
            unchanged()

            for command, method in (("raise-flag", "flag.raise"), ("lower-flag", "flag.lower"),
                                    ("suppress", "flag.suppress"), ("unsuppress", "flag.unsuppress")):
                args = [command, "--tab", "1", "--by", "operator"]
                if command == "raise-flag":
                    args.append("Synthetic reason")
                payload = json.loads(run(*args, env=caller).stdout)
                assert payload["window_id"] == b["id"] and payload["tab_id"] == b_ws["tabs"][1]["id"], payload
                routed(method)
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                args[2] = a_tab["ref"]
                run(*args, env=caller, success=False)
                unchanged()

            for extra, expected_ws in (([], b_ws), (["--workspace", "1"], b["workspaces"][1])):
                payload = json.loads(run("snapshot", *extra, env=caller).stdout)
                assert payload["workspace_id"] == expected_ws["id"], payload
                routed("snapshot.create")
                assert server.mutations == [("snapshot.create", b["ref"], expected_ws["ref"])], server.mutations
                assert server.windows == fixture(), server.windows
            run("snapshot", "--workspace", a_ws["id"], success=False)
            assert not any(name == "snapshot.create" for name, _ in server.calls), server.calls
            unchanged()
            for extra in ([], ["--in-place"]):
                payload = json.loads(run("restore", "synthetic-snapshot", *extra, env=caller).stdout)
                assert payload["window_id"] == b["id"], payload
                params = routed("snapshot.restore")
                if extra:
                    routed("workspace.current")
                    assert params["target_workspace_id"] == b_ws["id"], params
                    assert server.windows[1]["workspaces"][0]["tabs"][0]["text"] == "Synthetic restored content"
                else:
                    assert len(server.windows[1]["workspaces"]) == 3
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations

            for command, method in (("swap-pane", "area.swap"), ("join-pane", "area.join")):
                args = [command, "--pane", b_ws["areas"][0]["ref"],
                        "--target-pane", b_ws["areas"][1]["ref"]]
                if command == "join-pane":
                    args += ["--tab", b_tab["ref"], "--no-focus"]
                payload = json.loads(run(*args, env=caller).stdout)
                assert payload["window_id"] == b["id"], payload
                routed(method)
                assert server.windows[1]["workspaces"][0]["tabs"][0]["area_ref"] == b_ws["areas"][1]["ref"]
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                for position in (2, 4):
                    foreign_args = list(args)
                    foreign_args[position] = a_ws["areas"][0]["ref"]
                    run(*foreign_args, env=caller, success=False)
                    assert not any(name == method for name, _ in server.calls), server.calls
                    unchanged()
                if command == "join-pane":
                    args[6] = a_tab["id"]
                    run(*args, env=caller, success=False)
                    assert not any(name == method for name, _ in server.calls), server.calls
                    unchanged()

            # Global source lookup in move/reorder requires client membership
            # checks for the source, destination workspace/area, and anchor.
            for command, extra, method in (("move-tab", ["--area", b_ws["areas"][1]["ref"]], "tab.move"),
                                           ("reorder-tab", ["--index", "0"], "tab.reorder")):
                payload = json.loads(run(command, "--tab", b_ws["tabs"][1]["ref"], *extra).stdout)
                assert payload["window_id"] == b["id"], payload
                routed(method)
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                run(command, "--tab", a_tab["ref"], *extra, success=False)
                assert not any(name == method for name, _ in server.calls), server.calls
                unchanged()
            for command, extra, method in (("move-tab", ["--workspace", a_ws["id"]], "tab.move"),
                                           ("move-tab", ["--area", a_ws["areas"][0]["ref"]], "tab.move"),
                                           ("move-tab", ["--before", a_tab["ref"]], "tab.move"),
                                           ("reorder-tab", ["--after", a_tab["ref"]], "tab.reorder")):
                run(command, "--tab", b_tab["ref"], *extra, success=False)
                assert not any(name == method for name, _ in server.calls), server.calls
                unchanged()
            source_ws = b["workspaces"][1]
            source_tab = source_ws["tabs"][1]
            payload = json.loads(run("move-tab", "--tab", source_tab["ref"], "--index", "0").stdout)
            assert payload["workspace_id"] == source_ws["id"] and payload["area_id"] == source_tab["area_id"], payload
            routed("tab.move")
            assert server.mutations == [("tab.move", b["ref"], source_ws["ref"], source_tab["ref"])], server.mutations
            assert server.windows[0] == a and server.windows[1]["workspaces"][0] == b_ws
            assert len(server.windows[1]["workspaces"][1]["tabs"]) == 2

            payload = json.loads(run("move-tab", "--tab", b_tab["ref"], "--window", a["ref"],
                                     "--workspace", a_ws["ref"]).stdout)
            assert payload["window_id"] == a["id"] and payload["workspace_id"] == a_ws["id"], payload
            routed("tab.move", destination=a)
            assert server.mutations == [("tab.move", a["ref"], a_ws["ref"], b_tab["ref"])], server.mutations
            assert len(server.windows[0]["workspaces"][0]["tabs"]) == 3
            assert len(server.windows[1]["workspaces"][0]["tabs"]) == 1
            assert any(tab["id"] == b_tab["id"] for tab in server.windows[0]["workspaces"][0]["tabs"])
            assert not any(tab["id"] == b_tab["id"] for tab in server.windows[1]["workspaces"][0]["tabs"])

            # Legacy routes need selected B's workspace on their v1 wire;
            # otherwise these same endpoints mutate the key window A.
            legacy_cases = ((["drag-tab-to-split", "--tab", "0", "right"], "drag_surface_to_split"),
                            (["refresh-tabs"], "refresh_surfaces"),
                            (["default-agent", "launch"], "default_agent"))
            for args, command in legacy_cases:
                run(*args, env=caller)
                assert server.mutations == [(command, b["ref"], b_ws["ref"])], server.mutations
                assert server.windows[0] == a and server.windows[1]["workspaces"][1] == b["workspaces"][1]
                wires = [shlex.split(name) for name, _ in server.calls if name.startswith(command)]
                assert len(wires) == 1, server.calls
                if command == "default_agent":
                    assert wires[0][wires[0].index("--workspace") + 1] == b_ws["id"], wires
                    assert len(server.windows[1]["workspaces"][0]["tabs"]) == 3
                else:
                    assert f"--workspace={b_ws['id']}" in wires[0], wires
                    if command == "drag_surface_to_split":
                        assert wires[0][1:3] == [b_tab["id"], "right"], wires
                        assert server.windows[1]["workspaces"][0]["tabs"][0]["splits"] == ["right"]
                    else:
                        assert all(tab["refresh_count"] == 1 for tab in server.windows[1]["workspaces"][0]["tabs"])
                assert server.windows[0]["key"] and not server.windows[1]["key"]
            for args, command in ((["drag-tab-to-split", "--tab", a_tab["id"], "right"], "drag_surface_to_split"),
                                  (["default-agent", "launch", "--in-tab", a_tab["id"]], "default_agent"),
                                  (["drag-tab-to-split", "--tab", "bogus", "right"], "drag_surface_to_split"),
                                  (["default-agent", "launch", "--in-tab", "bogus"], "default_agent")):
                run(*args, env=caller, success=False)
                assert not any(name.startswith(command) for name, _ in server.calls), server.calls
                unchanged()
            for args, command in legacy_cases:
                run(*args, window=None, env=caller)
                assert server.mutations == [(command, a["ref"], a_ws["ref"])], server.mutations
                assert server.windows[1] == b and server.windows[0]["key"]
                wires = [shlex.split(name) for name, _ in server.calls if name.startswith(command)]
                assert len(wires) == 1 and not any(arg.startswith("--workspace") for arg in wires[0]), wires
                if command == "drag_surface_to_split":
                    assert server.windows[0]["workspaces"][0]["tabs"][0]["splits"] == ["right"]
                elif command == "refresh_surfaces":
                    assert all(tab["refresh_count"] == 1 for tab in server.windows[0]["workspaces"][0]["tabs"])
                else:
                    assert len(server.windows[0]["workspaces"][0]["tabs"]) == 3

            # config.launch carries scope even when requesting a new workspace.
            for extra in ([], ["--new-workspace"]):
                payload = json.loads(run("config", "launch", "synthetic-config", *extra, env=caller).stdout)
                assert payload["window_id"] == b["id"], payload
                routed("config.launch")
                assert server.windows[0] == a and len(server.mutations) == 1, server.mutations
                assert len(server.windows[1]["workspaces"]) == (3 if extra else 2)
            for extra in (["--workspace", a_ws["id"]], ["--area", a_ws["areas"][0]["ref"]]):
                run("config", "launch", "synthetic-config", *extra, success=False)
                assert not any(name == "config.launch" for name, _ in server.calls), server.calls
                unchanged()

            # Both modern response filtering and method-not-found fallback stay in B.
            for mode in ("scoped", "ignores_scope", "unsupported"):
                server.tree_mode = mode
                for flags in ([], ["--all"], ["--window"]):
                    payload = json.loads(run("tree", *flags, env=caller).stdout)
                    assert [item["ref"] for item in payload["windows"]] == [b["ref"]], payload
                    expected_workspaces = b["workspaces"] if flags else [b_ws]
                    assert [item["ref"] for item in payload["windows"][0]["workspaces"]] == [
                        item["ref"] for item in expected_workspaces], payload
                    routed("system.tree")
                    if mode == "unsupported":
                        routed("workspace.list")
                    unchanged()
                for token in (b["workspaces"][1]["id"], b["workspaces"][1]["ref"]):
                    payload = json.loads(run("tree", "--workspace", token, env=caller).stdout)
                    assert [item["ref"] for item in payload["windows"]] == [b["ref"]], payload
                    assert [item["ref"] for item in payload["windows"][0]["workspaces"]] == [b["workspaces"][1]["ref"]], payload
                    routed("system.tree")
                    if mode == "unsupported":
                        routed("workspace.list")
                    unchanged()
                for token in (a_ws["id"], a_ws["ref"]):
                    out = run("tree", "--workspace", token, env=caller, success=False)
                    assert token in out.stderr, out.stderr
                    assert not any(name == "system.tree" for name, _ in server.calls), server.calls
                    unchanged()
            server.tree_mode = "ignores_scope"

            # A previously live handle must become invalid after closure, with
            # no command dispatch or mutation in the surviving key window.
            run("read-screen", "--tab", b_tab["ref"])
            run("close-window", "--window", b["ref"], window=None, reset=False)
            closed_state, close_mutations = copy.deepcopy(server.windows), list(server.mutations)
            assert len(closed_state) == 1 and closed_state[0]["key"]
            out = run("read-screen", "--tab", a_tab["ref"], success=False, reset=False)
            assert b["ref"] in out.stderr, out.stderr
            assert not any(name == "tab.read_text" for name, _ in server.calls), server.calls
            assert server.windows == closed_state and server.mutations == close_mutations

            for token in ("", "  ", "not-a-window", "window:999999", identifier("missing-window"), "999999", "-1"):
                out = run("read-screen", "--tab", b_tab["ref"], window=token, success=False)
                assert "window" in out.stderr.lower() and f"'{token}'" in out.stderr, (token, out.stderr)
                assert all(name in ("window.list", "system.capabilities", "auth synthetic-password")
                           for name, _ in server.calls), server.calls
                unchanged()

            # Per-command focus-window remains the explicit v1 focus action.
            run("focus-window", "--window", b["ref"], window=None)
            assert (f"focus_window {b['ref']}", {}) in server.calls, server.calls
            assert server.windows[1]["key"] and not server.windows[0]["key"], server.windows

            # Without global scope, caller-local behavior is preserved.
            payload = json.loads(run("read-screen", window=None, env=caller).stdout)
            assert payload["text"] == a_tab["text"], payload
            unchanged()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
    print(f"PASS: {cases} CLI fake-socket window-scope cases using the supplied CLI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
