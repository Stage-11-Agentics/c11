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
                         "areas": [], "tabs": []}
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
                    response = "ERROR: unexpected v1 command " + wire
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
                                "system.identify", "system.tree", "workspace.group.list"],
                    "feature_schema_version": 1,
                    "features": [{"id": name, "version": 1} for name in
                                 ("vocabulary.workspace_area_tab", "send.explicit_tab",
                                  "window.route_without_focus")],
                    "server": {"version": "synthetic", "commit": "synthetic"}}
        if method == "window.list":
            return {"windows": [{k: copy.deepcopy(v) for k, v in item.items() if k != "workspaces"}
                                for item in self.windows]}
        if method == "window.focus":
            return self.context(self.focus(params["window_id"]), self.windows[1]["workspaces"][0])
        if method == "system.tree":
            if self.tree_mode == "unsupported":
                raise RPCError("method_not_found", "system.tree is unavailable")
            # Simulate a modern server that accepts, but ignores, window_id.
            key = next(item for item in self.windows if item["key"])
            return {"active": self.context(key, key["workspaces"][0], key["workspaces"][0]["tabs"][0]),
                    "caller": None, "windows": copy.deepcopy(self.windows)}
        window = self.window(params)
        workspace = self.workspace(window, params)
        context = self.context(window, workspace)
        if method == "workspace.list":
            items = window["workspaces"]
            if params.get("workspace_id") is not None:
                items = [workspace]
            return {**context, "workspaces": [{k: copy.deepcopy(v) for k, v in item.items()
                                              if k not in ("areas", "tabs")} for item in items]}
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
        if method == "tab.read_text":
            return {**context, "text": tab["text"]}
        if method == "tab.get_metadata":
            return {**context, "metadata": copy.deepcopy(tab["metadata"])}
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

        def routed(method: str) -> dict:
            calls = [params for name, params in server.calls if name == method]
            assert calls, (method, server.calls)
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

            # Metadata helpers must carry scope through target resolution and dispatch.
            run("set-metadata", "--tab", "1", "--key", "scope-test", "--value", "B-only")
            routed("tab.list")
            routed("tab.set_metadata")
            assert server.windows[1]["workspaces"][0]["tabs"][1]["metadata"] == {"scope-test": "B-only"}
            assert server.windows[0] == a, server.windows[0]
            payload = json.loads(run("get-metadata", "--tab", "1", reset=False).stdout)
            assert payload["metadata"] == {"scope-test": "B-only"}, payload
            routed("tab.get_metadata")

            # Both modern response filtering and method-not-found fallback stay in B.
            for mode in ("ignores_scope", "unsupported"):
                server.tree_mode = mode
                for flags in ([], ["--all"], ["--window"]):
                    payload = json.loads(run("tree", *flags, env=caller).stdout)
                    assert [item["ref"] for item in payload["windows"]] == [b["ref"]], payload
                    assert [item["ref"] for item in payload["windows"][0]["workspaces"]] == [
                        item["ref"] for item in b["workspaces"]], payload
                    routed("system.tree")
                    if mode == "unsupported":
                        routed("workspace.list")
                    unchanged()
            server.tree_mode = "ignores_scope"

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
    print(f"PASS: {cases} CLI fake-socket window-scope cases using {cli}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
