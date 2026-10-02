#!/usr/bin/env python3
"""C11-259 G-basic/G-invalid/G-focus socket and candidate CLI scenarios.

Run through scripts/sandbox-tests-v2.sh in the isolated guest against its tagged
QA app, with explicit C11_SOCKET and C11_CLI supplied by the runner. Never
discovers a socket or a CLI automatically; direct host execution is rejected.
These checks prove model/selection behavior, not macOS responder focus or
restart persistence (those require the tagged validator scenario).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def test_environment():
    """Reject defaults, production paths, symlinks and direct tagged host apps."""
    raw = os.environ.get("C11_SOCKET")
    require(bool(raw), "Set C11_SOCKET explicitly to the isolated QA socket")
    path = Path(raw)
    resolved = path.resolve()
    require(path.is_absolute(), "C11_SOCKET must be absolute")
    require(not path.is_symlink(), "Refusing a symlinked socket")
    require(resolved.parent == Path("/tmp").resolve(), "QA socket must be under /tmp")
    sandbox = re.fullmatch(r"c11-sandbox-[A-Za-z0-9_.-]+\.sock", path.name)
    require(bool(sandbox), "Run through scripts/sandbox-tests-v2.sh in the isolated guest")
    require(path.is_socket(), f"QA socket does not exist: {path}")
    cli = os.environ.get("C11_CLI")
    require(bool(cli) and Path(cli).is_file() and os.access(cli, os.X_OK),
            "Set C11_CLI explicitly to the candidate executable")
    return str(path), cli


class Fixture:
    """Only owns the two windows it creates; cleanup never closes prior windows."""

    def __init__(self, client, socket_path, cli):
        self.c = client
        self.socket_path = socket_path
        self.cli_path = cli
        self.windows = []

    def __enter__(self):
        try:
            self.window = self.c.new_window()
            self.windows.append(self.window)
            self.other_window = self.c.new_window()
            self.windows.append(self.other_window)
            self.other_workspace = self.rows(self.other_window)[0]["id"]
            # Keep the automatically created workspace as an unrelated selection.
            self.selected = self.rows()[0]["id"]
            self.workspaces = [self.c.new_workspace(window_id=self.window) for _ in range(4)]
            self.c._call("workspace.select", {
                "workspace_id": self.selected, "window_id": self.window,
            })
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exc_type, exc, tb):
        errors = []
        for window in reversed(self.windows):
            try:
                self.c.close_window(window)
            except Exception as error:
                errors.append(str(error))
        if errors:
            message = "QA window cleanup failed: " + "; ".join(errors)
            if exc_type is None:
                raise AssertionError(message)
            print(message, file=sys.stderr)

    def call(self, verb, **params):
        return self.c._call("workspace.group." + verb,
                            {"window_id": self.window, **params})

    def rows(self, window=None):
        return self.c._call("workspace.list", {
            "window_id": window or self.window,
        })["workspaces"]

    def ids(self):
        return [row["id"] for row in self.rows()]

    def groups(self, window=None):
        return self.call("list", window_id=window or self.window)["workspace_groups"]

    def group(self, group_id):
        return next(g for g in self.groups() if g["id"] == group_id)

    def tree(self):
        return self.c._call("system.tree", {"scope": "all"})

    def selection(self):
        # Check both per-window selected workspace and selected/focused tabs.
        return {
            window["id"]: (
                window["selected_workspace_id"],
                {ws["id"]: [(area["id"],
                              [(tab["id"], tab["focused"], tab["selected"])
                               for tab in area["tabs"]])
                             for area in ws["areas"]]
                 for ws in window["workspaces"]},
            ) for window in self.tree()["windows"] if window["id"] in self.windows
        }

    def identities(self):
        # All windows, including pre-existing ones: no hidden anchor workspace/tab.
        return {
            window["id"]: {
                ws["id"]: sorted(tab["id"] for area in ws["areas"] for tab in area["tabs"])
                for ws in window["workspaces"]
            } for window in self.tree()["windows"]
        }

    def snapshot(self):
        # Omit asynchronous titles, ports, activity, geometry and shell metadata.
        return {
            "windows": {
                window: {
                    "groups": self.groups(window),
                    "workspaces": [(r["id"], r["pinned"], r["group_id"])
                                   for r in self.rows(window)],
                } for window in self.windows
            },
            "selection": self.selection(), "identities": self.identities(),
        }

    def mutate(self, verb, **params):
        selection, identities = self.selection(), self.identities()
        result = self.call(verb, **params)
        require(self.selection() == selection, f"{verb} changed workspace/tab selection")
        require(self.identities() == identities, f"{verb} created/closed a workspace or tab")
        return result

    def error(self, code, method, params):
        before = self.snapshot()
        try:
            self.c._call(method, {"window_id": self.window, **params})
        except cmuxError as error:
            require(str(error).split(":", 1)[0] == code,
                    f"{method}: expected {code}, got {error}")
        else:
            raise AssertionError(f"{method} unexpectedly succeeded: {params}")
        require(self.snapshot() == before, f"{method} partially mutated on {code}")

    def cli(self, *args, fail=False):
        env = dict(os.environ)
        for key in ("C11_TAB_ID", "C11_SURFACE_ID", "C11_WORKSPACE_ID", "C11_WINDOW_ID",
                    "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_WINDOW_ID"):
            env.pop(key, None)
        proc = subprocess.run(
            [self.cli_path, "--socket", self.socket_path, "--json", "--id-format", "both", *args],
            capture_output=True, text=True, timeout=30, env=env,
        )
        require((proc.returncode != 0) if fail else (proc.returncode == 0),
                f"CLI {args}: rc={proc.returncode} stdout={proc.stdout} stderr={proc.stderr}")
        return proc if fail else json.loads(proc.stdout)

    def parity(self):
        groups = self.groups()
        rows = self.rows()
        window = next(w for w in self.tree()["windows"] if w["id"] == self.window)
        require(window["workspace_groups"] == groups, "group list/tree disagree")
        require([w["id"] for w in window["workspaces"]] == self.ids(), "flat tree order changed")
        require({w["id"]: w["group_id"] for w in window["workspaces"]} ==
                {w["id"]: w["group_id"] for w in rows}, "membership list/tree disagree")
        for group in groups:
            members = [w["id"] for w in rows if w["group_id"] == group["id"]]
            require(group["member_workspace_ids"] == members, "member order disagrees with flat order")
            require(group["member_count"] == len(members), "incorrect member count")
            require(group["ref"].startswith("workspace_group:"), "missing group ref")


def exercise_groups(f):
    a, b, c, d = f.workspaces
    g = f.mutate("create", name="Synthetic Folder")["group"]["id"]
    h = f.mutate("create", name="Synthetic Folder")["group"]["id"]
    require(g != h, "duplicate names must have distinct identity")
    require(f.group(g)["member_count"] == 0, "new folder is not empty")
    require(not f.group(g)["is_pinned"] and not f.group(g)["is_collapsed"], "incorrect defaults")
    f.mutate("rename", group_id=g, name="  Renamed Folder  ")
    require(f.group(g)["name"] == "Renamed Folder", "name not trimmed")
    for verb, field, value in (("set_color", "color", "#AABBCC"),
                               ("set_icon", "icon", "folder.fill")):
        f.mutate(verb, group_id=g, **{field: value})
        require(str(f.group(g)[field]).upper() == value.upper(), f"{field} not stored")
        f.mutate(verb, group_id=g, **{field: None})
        require(f.group(g)[field] is None, f"{field} not cleared")
    f.mutate("add", group_id=g, workspace_ids=[a, b])
    f.mutate("add", group_id=h, workspace_ids=[c])
    for verb, field, expected in (("collapse", "is_collapsed", True),
                                   ("expand", "is_collapsed", False),
                                   ("pin", "is_pinned", True),
                                   ("unpin", "is_pinned", False)):
        f.mutate(verb, group_id=g)
        require(f.group(g)[field] is expected, f"{verb} did not update {field}")
    f.mutate("move", group_id=h, before_id=g)
    require([x["id"] for x in f.groups()] == [h, g], "folder before move failed")
    f.mutate("move", group_id=h, after_id=g)
    require([x["id"] for x in f.groups()] == [g, h], "folder after move failed")
    f.mutate("move", group_id=h, index=0)
    require(f.groups()[0]["id"] == h, "folder index move failed")
    f.mutate("pin", group_id=g)
    f.mutate("move", group_id=h, before_id=g)
    require(f.groups()[0]["id"] == g, "unpinned folder crossed pin boundary")
    require(not f.group(h)["is_pinned"], "folder move toggled pin")
    f.mutate("unpin", group_id=g)

    missing = str(uuid.uuid4())
    cases = [
        ("duplicate_workspace", "add", {"group_id": g, "workspace_ids": [d, d]}),
        ("already_grouped", "add", {"group_id": g, "workspace_ids": [d, a]}),
        ("already_grouped", "add", {"group_id": g, "workspace_ids": [d, c]}),
        ("workspace_not_found", "add", {"group_id": g, "workspace_ids": [d, missing]}),
        ("wrong_window", "add", {"group_id": g, "workspace_ids": [d, f.other_workspace]}),
        ("not_member", "remove", {"group_id": g, "workspace_ids": [a, c]}),
        ("group_not_found", "delete", {"group_id": missing}),
        ("invalid_params", "rename", {"group_id": g, "name": "  "}),
        ("invalid_params", "create", {"name": "  "}),
        ("invalid_params", "set_color", {"group_id": g, "color": "not-a-color"}),
        ("invalid_params", "set_icon", {"group_id": g, "icon": "not.a.real.c11.symbol"}),
        ("invalid_params", "add", {"group_id": g, "workspace_ids": []}),
        ("invalid_params", "add", {"group_id": g, "workspace_ids": "bad-array"}),
        ("invalid_params", "move", {"group_id": g, "before_id": h, "after_id": h}),
        ("not_member", "move", {"workspace_id": a, "to_group_id": h, "before_id": b}),
    ]
    for code, verb, params in cases:
        f.error(code, "workspace.group." + verb, params)
    foreign = f.call("create", window_id=f.other_window, name="Foreign Folder")["group"]["id"]
    f.error("wrong_window", "workspace.group.rename", {"group_id": foreign, "name": "No"})
    f.error("wrong_window", "workspace.group.move", {"workspace_id": a, "to_group_id": foreign})
    f.mutate("move", workspace_id=b, to_group_id=h, before_id=c)
    require(f.group(h)["member_workspace_ids"] == [b, c], "member transfer order failed")
    f.mutate("move", workspace_id=b, to_group_id=h, after_id=c)
    require(f.group(h)["member_workspace_ids"] == [c, b], "member relative reorder failed")
    f.mutate("move", workspace_id=b, to_group_id=None)
    require(next(w for w in f.rows() if w["id"] == b)["group_id"] is None, "move did not detach")
    f.mutate("remove", group_id=g, workspace_ids=[a])
    require(f.group(g)["member_count"] == 0, "last removal deleted folder")
    f.error("empty_group", "workspace.group.focus", {"group_id": g})
    f.mutate("add", group_id=g, workspace_ids=[a, b])
    f.mutate("collapse", group_id=g)
    f.parity()  # Collapsed members remain in both machine-readable views.
    f.call("focus", group_id=g)
    selected = f.c._call("workspace.current", {"window_id": f.window})["workspace_id"]
    require(selected == f.group(g)["member_workspace_ids"][0], "focus did not pick first member")
    f.c._call("workspace.select", {"window_id": f.window, "workspace_id": b})
    f.call("focus", group_id=g)
    require(f.c._call("workspace.current", {"window_id": f.window})["workspace_id"] == b,
            "focus replaced selected group member")
    f.mutate("collapse", group_id=g)  # Even collapsing the selected member preserves focus.
    order = f.ids()
    f.mutate("delete", group_id=g)
    f.mutate("ungroup", group_id=h)
    require(f.ids() == order, "delete/ungroup changed canonical order")
    require(not f.groups() and all(w["group_id"] is None for w in f.rows()), "members not detached")
    f.parity()


def exercise_lifecycle(f):
    a, b = f.workspaces[:2]
    g = f.mutate("create", name="Lifecycle Folder")["group"]["id"]
    f.mutate("add", group_id=g, workspace_ids=[a, b])
    before_tabs = dict(f.identities()[f.window])
    f.c.move_workspace_to_window(a, f.other_window, focus=False)
    require(f.group(g)["member_workspace_ids"] == [b], "cross-window detach retained membership")
    moved = next(r for r in f.rows(f.other_window) if r["id"] == a)
    require(moved["group_id"] is None, "cross-window move inherited group")
    require(f.identities()[f.other_window][a] == before_tabs[a], "cross-window move changed tabs")
    f.c._call("workspace.close", {"window_id": f.window, "workspace_id": b})
    require(f.group(g)["member_count"] == 0, "closing final member deleted folder")
    new = f.c.new_workspace(window_id=f.window)
    require(next(r for r in f.rows() if r["id"] == new)["group_id"] is None, "ambient group inheritance")
    f.parity()


def exercise_cli(f):
    # UUIDs and ephemeral handles must both resolve, but display names must not.
    before = f.identities()
    def command(verb, *args):
        selection = f.selection()
        result = f.cli("workspace-group", verb, "--window", f.window, *args)
        if verb != "focus":
            require(f.selection() == selection, f"CLI {verb} changed selection")
        return result

    result = command("create", "--name", "CLI Folder")
    g = result["group"]
    h = command("create", "--name", "CLI Second")["group"]
    command("rename", "--group", g["ref"], "--name", "CLI Renamed")
    listed = command("list")["workspace_groups"]
    require(next(x for x in listed if x["id"] == g["id"])["name"] == "CLI Renamed", "CLI ref resolution failed")
    c, d = f.workspaces[2:]
    refs = {r["id"]: r["ref"] for r in f.rows()}
    command("add", "--group", g["ref"], "--workspaces", f"{refs[c]},{d}")
    for verb, field, value in (("set-color", "color", "#112233"),
                               ("set-icon", "icon", "folder.fill")):
        command(verb, "--group", g["id"], "--" + field, value)
        require(f.group(g["id"])[field] == value, f"CLI {verb} did not apply")
        command(verb, "--group", g["id"], "--clear")
        require(f.group(g["id"])[field] is None, f"CLI {verb} did not clear")
    for verb, field, value in (("collapse", "is_collapsed", True),
                               ("expand", "is_collapsed", False),
                               ("pin", "is_pinned", True),
                               ("unpin", "is_pinned", False)):
        command(verb, "--group", g["id"])
        require(f.group(g["id"])[field] is value, f"CLI {verb} did not apply")
    command("move", "--group", h["ref"], "--before", g["ref"])
    ids = [r["id"] for r in f.groups()]
    require(ids.index(h["id"]) < ids.index(g["id"]), "CLI folder move failed")
    command("move", "--workspace", refs[d], "--to-group", h["ref"])
    require(f.group(h["id"])["member_workspace_ids"] == [d], "CLI member transfer failed")
    command("move", "--workspace", refs[d], "--to-group", "none")
    command("remove", "--group", g["ref"], "--workspaces", refs[c])
    command("add", "--group", g["ref"], "--workspaces", refs[c])
    command("focus", "--group", g["ref"])
    require(f.c._call("workspace.current", {"window_id": f.window})["workspace_id"] == c,
            "CLI focus did not select member")
    command("collapse", "--group", g["id"])
    state = f.snapshot()
    f.cli("workspace-group", "delete", "--window", f.window, "--group", "CLI Renamed", fail=True)
    require(f.snapshot() == state, "CLI accepted display name or partially mutated")
    tree = f.cli("tree", "--all")
    node = next(w for w in tree["windows"] if w["id"] == f.window)
    require(node["workspace_groups"] == f.groups(), "CLI tree lost group records")
    require([w["id"] for w in node["workspaces"]] == f.ids(), "CLI tree lost flat workspace order")
    command("delete", "--group", g["id"])
    command("ungroup", "--group", h["ref"])
    require(f.identities() == before, "CLI folder operations created/closed tabs or workspaces")


def main():
    socket_path, cli = test_environment()
    with cmux(socket_path) as client:
        with Fixture(client, socket_path, cli) as fixture:
            exercise_groups(fixture)
            exercise_lifecycle(fixture)
            exercise_cli(fixture)
    print("PASS: groups, atomic errors, lifecycle, selection preservation and CLI parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
