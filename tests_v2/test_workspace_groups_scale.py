#!/usr/bin/env python3
"""C11-261 g60-v1 workspace-group fixture and socket oracle.

This module owns the repeatable, machine-readable half of the C11-261 sign-off
line.  It deliberately does not drive AppKit: the C1-C6 computer-use chapters
in ``docs/groups-signoff.md`` are a separate reviewer handoff.

All operations require an explicitly reserved tagged socket (or the isolated
sandbox socket used by the v2 harness).  The fixture state records every ID it
creates so cleanup can retain anything a validator added later.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402
from test_workspace_groups import require, test_environment  # noqa: E402


SCHEMA = "c11-261-g60-v1"
FIXTURE_VERSION = 1
GROUP_NAMES = {
    "pinned_fleet": "Pinned Fleet",
    "collapsed_flag": "Collapsed Flag",
    "empty_pinned": "Empty Pinned",
    "empty_collapsed": "Empty Collapsed",
    "tail": "Tail",
    "move_lane": "Move Lane",
}
GROUP_ORDER = [
    "pinned_fleet",
    "collapsed_flag",
    "empty_pinned",
    "empty_collapsed",
    "tail",
    "move_lane",
]
GROUP_MEMBERS = {
    "pinned_fleet": [f"g60-w{i:02d}" for i in range(1, 9)],
    "collapsed_flag": [f"g60-w{i:02d}" for i in range(9, 15)],
    "tail": [f"g60-w{i:02d}" for i in range(15, 25)],
    "move_lane": [f"g60-w{i:02d}" for i in range(25, 29)],
    "empty_pinned": [],
    "empty_collapsed": [],
}
WORKSPACE_NAMES = [f"g60-w{i:02d}" for i in range(1, 61)]
PINNED_WORKSPACES = {"g60-w01", "g60-w02", "g60-w29", "g60-w30", "g60-w31", "g60-w32"}
SPECIAL_TABS = {
    "g60-w04": "browser",
    "g60-w05": "markdown",
    "g60-w33": "browser",
    "g60-w34": "markdown",
}
SHELL_NAMES = {"bash", "dash", "fish", "ksh", "sh", "tcsh", "zsh"}


class FixtureSkip(Exception):
    """The candidate app cannot prove this ticket's required socket seam."""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def atomic_write(path: Path, value: Any) -> None:
    require(path.is_absolute() and not path.is_symlink(), f"unsafe output path: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def read_json(path: Path) -> Any:
    require(path.is_absolute() and path.is_file() and not path.is_symlink(), f"missing JSON: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def uuid_string(value: Any) -> str:
    return str(value)


def capability_check(client: cmux) -> None:
    try:
        tree = client._call("system.tree", {"scope": "all"})
        windows = tree.get("windows") or []
        if not windows:
            raise FixtureSkip("workspace groups unavailable: candidate has no window")
        client._call("workspace.group.list", {"window_id": windows[0]["id"]})
    except cmuxError as error:
        if str(error).split(":", 1)[0] in {"method_not_found", "unsupported"}:
            raise FixtureSkip(f"workspace.group.list unavailable: {error}") from error
        raise


def rows(client: cmux, window_id: str) -> list[dict[str, Any]]:
    return list((client._call("workspace.list", {"window_id": window_id}) or {}).get("workspaces") or [])


def groups(client: cmux, window_id: str) -> list[dict[str, Any]]:
    return list((client._call("workspace.group.list", {"window_id": window_id}) or {}).get("workspace_groups") or [])


def tabs(client: cmux, workspace_id: str) -> list[dict[str, Any]]:
    return list((client._call("tab.list", {"workspace_id": workspace_id}) or {}).get("tabs") or [])


def tab_metadata(client: cmux, workspace_id: str, tab_id: str) -> dict[str, Any]:
    try:
        return dict((client._call("tab.get_metadata", {
            "workspace_id": workspace_id, "tab_id": tab_id,
        }) or {}).get("metadata") or {})
    except cmuxError:
        return {}


def tree(client: cmux) -> dict[str, Any]:
    return dict(client._call("system.tree", {"scope": "all"}) or {})


def workspace_window_map(client: cmux) -> dict[str, str]:
    return {
        workspace["id"]: window["id"]
        for window in tree(client).get("windows") or []
        for workspace in window.get("workspaces") or []
    }


def shell_pids(tty: Any) -> list[int]:
    """Record TTY shell roots, excluding transient shell children (prompt/hooks)."""
    if not tty or not isinstance(tty, str):
        return []
    tty_name = Path(tty).name
    try:
        proc = subprocess.run(
            ["ps", "-t", tty_name, "-o", "pid=,ppid=,comm="],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    processes: dict[int, tuple[int, str]] = {}
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid, parent = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        command = Path(parts[2].strip()).name.lstrip("-").lower()
        processes[pid] = (parent, command)
    roots: list[int] = []
    for pid, (parent, command) in processes.items():
        if command not in SHELL_NAMES:
            continue
        seen = {pid}
        while parent in processes and parent not in seen:
            seen.add(parent)
            ancestor, ancestor_command = processes[parent]
            if ancestor_command in SHELL_NAMES:
                break
            parent = ancestor
        else:
            roots.append(pid)
    return sorted(roots)


def tab_identity(client: cmux, workspace_id: str, tab: dict[str, Any]) -> dict[str, Any]:
    tab_id = uuid_string(tab["id"])
    tty = tab.get("tty")
    identity: dict[str, Any] = {
        "id": tab_id,
        "type": tab.get("type"),
        "title": tab.get("title"),
        "tty": tty,
        "shell_pids": shell_pids(tty),
        "metadata": tab_metadata(client, workspace_id, tab_id),
    }
    identity["identity_recorded"] = bool(identity["id"] and (
        identity["type"] != "terminal" or identity["tty"] or identity["shell_pids"]
    ))
    return identity


def workspace_snapshot(client: cmux, window_id: str) -> dict[str, Any]:
    current_rows = rows(client, window_id)
    current_groups = groups(client, window_id)
    order = [uuid_string(row["id"]) for row in current_rows]
    workspaces: dict[str, Any] = {}
    for row in current_rows:
        wid = uuid_string(row["id"])
        current_tabs = [tab_identity(client, wid, tab) for tab in tabs(client, wid)]
        workspaces[wid] = {
            "id": wid,
            "title": row.get("title"),
            "pinned": bool(row.get("pinned", False)),
            "group_id": row.get("group_id"),
            "tabs": current_tabs,
            "tab_ids": [tab["id"] for tab in current_tabs],
        }
    normalized_groups = []
    for group in current_groups:
        normalized_groups.append({
            "id": uuid_string(group["id"]),
            "ref": group.get("ref"),
            "name": group.get("name"),
            "color": group.get("color"),
            "icon": group.get("icon"),
            "is_collapsed": bool(group.get("is_collapsed", False)),
            "is_pinned": bool(group.get("is_pinned", False)),
            "member_workspace_ids": [uuid_string(item) for item in group.get("member_workspace_ids") or []],
            "member_count": int(group.get("member_count", 0)),
        })
    by_id = {group["id"]: group for group in normalized_groups}
    projection: list[dict[str, Any]] = []
    for pinned in (True, False):
        for group in normalized_groups:
            if group["is_pinned"] == pinned:
                projection.append({"kind": "group", "id": group["id"]})
        for wid in order:
            record = workspaces[wid]
            if record["pinned"] == pinned and record["group_id"] is None:
                projection.append({"kind": "workspace", "id": wid})
    return {
        "captured_at": now_iso(),
        "window_id": uuid_string(window_id),
        "workspace_order": order,
        "workspaces": workspaces,
        "groups": normalized_groups,
        "group_by_id": by_id,
        "root_projection": projection,
    }


def record_workspace(client: cmux, name: str, workspace_id: str) -> dict[str, Any]:
    current_tabs = tabs(client, workspace_id)
    return {
        "name": name,
        "id": uuid_string(workspace_id),
        "tab_ids": [uuid_string(tab["id"]) for tab in current_tabs],
        "tabs": [tab_identity(client, workspace_id, tab) for tab in current_tabs],
    }


def record_all_workspaces(client: cmux, state: dict[str, Any]) -> None:
    for name, record in state["workspaces"].items():
        wid = record["id"]
        if wid in workspace_window_map(client):
            state["workspaces"][name] = record_workspace(client, name, wid)


def assert_identity(before: dict[str, Any], after: dict[str, Any],
                    *, removed: set[str] | None = None, added_tabs: set[str] | None = None) -> list[str]:
    """Assert the declared removal, every surviving tab, and available shell processes."""
    removed, added_tabs = removed or set(), added_tabs or set()
    old_ids, new_ids = set(before["workspace_order"]), set(after["workspace_order"])
    require(len(new_ids) == len(after["workspace_order"]), "duplicate workspace IDs")
    require(old_ids - new_ids == removed and new_ids - old_ids == set(),
            f"workspace removal differs: expected {removed}, actual {old_ids - new_ids}")
    unknown: list[str] = []
    for wid in old_ids - removed:
        old, new = before["workspaces"][wid], after["workspaces"][wid]
        old_tabs = {tab["id"]: tab for tab in old["tabs"]}
        new_tabs = {tab["id"]: tab for tab in new["tabs"]}
        require(len(new_tabs) == len(new["tabs"]), f"duplicate tab IDs in {wid}")
        require(set(new_tabs) - set(old_tabs) <= added_tabs and set(old_tabs) <= set(new_tabs),
                f"surviving workspace {wid} lost/recreated tabs")
        for tid, tab in old_tabs.items():
            current = new_tabs[tid]
            require(current["type"] == tab["type"], f"tab type changed: {tid}")
            if tab["type"] == "terminal":
                if tab["shell_pids"]:
                    require(current["shell_pids"] == tab["shell_pids"], f"shell PID set changed: {tid}")
                    require(current["tty"] == tab["tty"], f"terminal TTY changed: {tid}")
                else:
                    unknown.append(f"shell identity unavailable for terminal {tid}")
    for wid in removed:
        for tab in before["workspaces"][wid]["tabs"]:
            for pid in tab["shell_pids"]:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    proc = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                          capture_output=True, text=True, timeout=2)
                    if not proc.stdout.strip() or proc.stdout.strip().startswith("Z"):
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError(f"closed workspace retained shell PID {pid}")
            if tab["type"] == "terminal" and not tab["shell_pids"]:
                unknown.append(f"closed terminal process identity unavailable: {tab['id']}")
    all_tabs = [tid for workspace in after["workspaces"].values() for tid in workspace["tab_ids"]]
    require(len(all_tabs) == len(set(all_tabs)), "duplicate tabs across workspaces")
    return unknown


def assert_move(client: cmux, state: dict[str, Any], name: str, destination: str | None,
                *, before: str | None = None, after: str | None = None) -> dict[str, Any]:
    old = workspace_snapshot(client, state["window_id"])
    wid = workspace_id(state, name)
    move_workspace(client, state, name, destination, before=before, after=after)
    new = workspace_snapshot(client, state["window_id"])
    state.setdefault("intermediate", []).append({"operation": "move", "workspace": name,
                                                "destination": destination, "before": old, "after": new})
    assert_identity(old, new)
    require(new["workspaces"][wid]["group_id"] == destination, f"{name} did not enter {destination}")
    require(new["workspaces"][wid]["pinned"] == old["workspaces"][wid]["pinned"], f"{name} pin changed")
    # A move may reposition only its source. Every other workspace must retain order/membership.
    require([item for item in new["workspace_order"] if item != wid] ==
            [item for item in old["workspace_order"] if item != wid], "move reordered unrelated workspaces")
    for other in set(old["workspaces"]) - {wid}:
        require(old["workspaces"][other]["group_id"] == new["workspaces"][other]["group_id"],
                "move changed unrelated membership")
    peers = [item for item in new["workspace_order"]
             if new["workspaces"][item]["group_id"] == destination
             and new["workspaces"][item]["pinned"] == new["workspaces"][wid]["pinned"]]
    if before and workspace_id(state, before) in peers:
        require(peers.index(wid) + 1 == peers.index(workspace_id(state, before)), "before placement failed")
    elif after and workspace_id(state, after) in peers:
        require(peers.index(wid) == peers.index(workspace_id(state, after)) + 1, "after placement failed")
    elif before or after:
        require(peers[0 if before else -1] == wid, "pin-boundary clamping failed")
    else:
        require(peers[-1] == wid, "move did not append to destination segment")
    return new


def group_id(state: dict[str, Any], role: str) -> str:
    value = state["groups"].get(role)
    require(value, f"fixture group role has no ID: {role}")
    return str(value)


def workspace_id(state: dict[str, Any], name: str) -> str:
    record = state["workspaces"].get(name)
    require(record and record.get("id"), f"fixture workspace has no ID: {name}")
    return str(record["id"])


def move_workspace(client: cmux, state: dict[str, Any], name: str, destination: str | None,
                   *, before: str | None = None, after: str | None = None) -> dict[str, Any]:
    params: dict[str, Any] = {
        "window_id": state["window_id"],
        "workspace_id": workspace_id(state, name),
        "to_group_id": destination if destination is not None else None,
    }
    if before is not None:
        params["before_id"] = workspace_id(state, before)
    if after is not None:
        params["after_id"] = workspace_id(state, after)
    return dict(client._call("workspace.group.move", params) or {})


def order_group_members(client: cmux, state: dict[str, Any], role: str) -> None:
    """Pin/group segment operations can reorder members; restore the fixture contract."""
    members = GROUP_MEMBERS[role]
    for name, before in reversed(list(zip(members, members[1:]))):
        move_workspace(client, state, name, group_id(state, role), before=before)


def expect_error(client: cmux, method: str, params: dict[str, Any], code: str) -> str:
    try:
        client._call(method, params)
    except cmuxError as error:
        actual = str(error).split(":", 1)[0]
        require(actual == code, f"{method}: expected {code}, got {error}")
        return str(error)
    raise AssertionError(f"{method} unexpectedly succeeded; expected {code}")


def assert_g60(client: cmux, state: dict[str, Any]) -> dict[str, Any]:
    snap = workspace_snapshot(client, state["window_id"])
    require(len(snap["workspace_order"]) == 60, "g60 fixture must have 60 workspaces")
    require(len(snap["groups"]) == 6, "g60 fixture must have six groups")
    require(sum(group["member_count"] == 0 for group in snap["groups"]) == 2,
            "g60 fixture must have two empty groups")
    titles = {record["title"] for record in snap["workspaces"].values()}
    require(titles == set(WORKSPACE_NAMES), f"workspace title set is not g60: {titles}")
    for role, names in GROUP_MEMBERS.items():
        group = snap["group_by_id"].get(group_id(state, role))
        require(group is not None, f"missing group for role {role}")
        expected_ids = [workspace_id(state, name) for name in names]
        member_ids = group["member_workspace_ids"]
        require(member_ids == expected_ids,
                f"{role} member order differs: {member_ids} != {expected_ids}")
    for name in PINNED_WORKSPACES:
        require(snap["workspaces"][workspace_id(state, name)]["pinned"], f"{name} must be pinned")
    for name, expected_type in SPECIAL_TABS.items():
        actual = snap["workspaces"][workspace_id(state, name)]["tabs"]
        require(len(actual) == 1 and actual[0]["type"] == expected_type,
                f"{name} must contain one {expected_type} tab: {actual}")
    require(all(record["tab_ids"] for record in state["workspaces"].values()),
            "every workspace must have a recorded tab ID")
    return snap


def provision(client: cmux, state_path: Path, fixture_root: Path, tag: str) -> dict[str, Any]:
    require(not state_path.exists(), f"state already exists: {state_path}; cleanup it first")
    fixture_root.mkdir(parents=True, exist_ok=True)
    note = fixture_root / "g60-v1-note.md"
    note.write_text("# C11-261 synthetic note\n\nFixture content only.\n", encoding="utf-8")
    state: dict[str, Any] = {
        "schema": SCHEMA,
        "fixture_version": FIXTURE_VERSION,
        "status": "provisioning",
        "created_at": now_iso(),
        "tag": tag,
        "socket": os.environ["C11_SOCKET"],
        "cli": os.environ["C11_CLI"],
        "cli_sha256": hashlib.sha256(Path(os.environ["C11_CLI"]).read_bytes()).hexdigest(),
        "fixture_root": str(fixture_root),
        "fixture_note": str(note),
        "window_id": None,
        "groups": {},
        "workspaces": {},
        "closed_workspace_ids": [],
        "deleted_group_ids": [],
        "un_grouped_ids": [],
        "agent_probe_tab_ids": [],
        "steps": [],
    }
    atomic_write(state_path, state)
    try:
        window_id = client.new_window()
        state["window_id"] = window_id
        atomic_write(state_path, state)
        initial = rows(client, window_id)
        require(len(initial) == 1, f"new fixture window must start with one workspace: {initial}")

        for index, name in enumerate(WORKSPACE_NAMES):
            wid = initial[0]["id"] if index == 0 else client.new_workspace(window_id=window_id)
            client._call("workspace.rename", {
                "window_id": window_id, "workspace_id": wid, "title": name,
            })
            state["workspaces"][name] = record_workspace(client, name, wid)
            atomic_write(state_path, state)

        for name, tab_type in SPECIAL_TABS.items():
            record = state["workspaces"][name]
            old_tabs = list(record["tab_ids"])
            params: dict[str, Any] = {
                "workspace_id": record["id"], "type": tab_type, "focus": False,
            }
            if tab_type == "browser":
                params["url"] = "about:blank"
            else:
                params["file"] = str(note)
            created = client._call("tab.create", params) or {}
            new_tab = created.get("tab_id") or created.get("surface_id")
            require(new_tab, f"tab.create returned no tab for {name}: {created}")
            for old_tab in old_tabs:
                client._call("tab.close", {"workspace_id": record["id"], "tab_id": old_tab})
            state["workspaces"][name] = record_workspace(client, name, record["id"])
            require(state["workspaces"][name]["tab_ids"] == [str(new_tab)],
                    f"{name} did not retain only its synthetic {tab_type} tab")
            atomic_write(state_path, state)

        for name in sorted(PINNED_WORKSPACES, key=WORKSPACE_NAMES.index):
            client._call("workspace.action", {
                "window_id": window_id, "workspace_id": workspace_id(state, name), "action": "pin",
            })

        for role in GROUP_ORDER:
            created = client._call("workspace.group.create", {
                "window_id": window_id, "name": GROUP_NAMES[role],
            }) or {}
            group = created.get("group") or {}
            require(group.get("id"), f"group.create returned no ID for {role}: {created}")
            state["groups"][role] = group["id"]
            atomic_write(state_path, state)

        for role in GROUP_ORDER:
            members = [workspace_id(state, name) for name in GROUP_MEMBERS[role]]
            if members:
                client._call("workspace.group.add", {
                    "window_id": window_id, "group_id": group_id(state, role), "workspace_ids": members,
                })
        for role in ("pinned_fleet", "empty_pinned"):
            client._call("workspace.group.pin", {"window_id": window_id, "group_id": group_id(state, role)})
        for role in ("collapsed_flag", "empty_collapsed"):
            client._call("workspace.group.collapse", {
                "window_id": window_id, "group_id": group_id(state, role),
            })
        # Pinning is a segment operation. Explicit group moves make the fixture
        # order deterministic without selecting by a display name later.
        client._call("workspace.group.move", {
            "window_id": window_id, "group_id": group_id(state, "pinned_fleet"), "index": 0,
        })
        client._call("workspace.group.move", {
            "window_id": window_id, "group_id": group_id(state, "empty_pinned"), "index": 1,
        })
        for role in GROUP_ORDER:
            if GROUP_MEMBERS[role]:
                order_group_members(client, state, role)
        # C11-323 forbids socket callers from changing the operator's visible
        # workspace. Keep the fixture in the background; every oracle operation
        # below addresses its window and workspace IDs directly. Visible checks
        # belong to the human computer-use chapters.
        record_all_workspaces(client, state)
        initial_snapshot = assert_g60(client, state)
        state["initial_snapshot"] = initial_snapshot
        state["status"] = "provisioned"
        atomic_write(state_path, state)
        return {
            "status": "PROVISIONED",
            "schema": SCHEMA,
            "window_id": window_id,
            "workspace_count": 60,
            "group_count": 6,
            "empty_group_count": 2,
            "state": str(state_path),
            "ui_proven": False,
        }
    except BaseException as error:
        state["status"] = "provision_failed"
        state["error"] = str(error)
        atomic_write(state_path, state)
        raise


def snapshot_command(client: cmux, state_path: Path, out: Path | None) -> dict[str, Any]:
    state = read_json(state_path)
    require(state.get("schema") == SCHEMA, "not a C11-261 g60 state file")
    require(os.path.realpath(state["socket"]) == os.path.realpath(os.environ["C11_SOCKET"]),
            "state belongs to another socket")
    snap = workspace_snapshot(client, state["window_id"])
    result = {
        "status": "SNAPSHOT",
        "schema": SCHEMA,
        "fixture_token": state.get("created_at"),
        "snapshot": snap,
        "unperformed": [
            "visible sidebar rendering",
            "pointer drag/cancel gesture",
            "human typing/focus responder proof",
            "native event-stream subscription",
        ],
    }
    if out:
        atomic_write(out, result)
    return result


def run_step(client: cmux, state: dict[str, Any], output, name: str,
             action: Callable[[], tuple[list[str], list[str]]]) -> dict[str, Any]:
    started = time.time()
    state["intermediate"] = []
    before = workspace_snapshot(client, state["window_id"])
    result: dict[str, Any] = {
        "step": name, "started_at": now_iso(), "status": "FAIL", "assertions": [],
        "unverified": [], "before": before,
    }
    try:
        assertions, unverified = action()
        after = workspace_snapshot(client, state["window_id"])
        removed = set(state["closed_workspace_ids"]) & set(before["workspace_order"])
        unverified += assert_identity(before, after, removed=removed,
                                      added_tabs=set(state["agent_probe_tab_ids"]))
        result["assertions"] = assertions
        result["unverified"] = unverified
        result["status"] = "UNVERIFIED" if unverified else "PASS"
    except BaseException as error:
        result["error"] = str(error)
        result["status"] = "FAIL"
        result["after"] = workspace_snapshot(client, state["window_id"])
        result["intermediate"] = state["intermediate"]
        result["finished_at"] = now_iso()
        result["elapsed_seconds"] = round(time.time() - started, 3)
        output.write(json.dumps(result, sort_keys=True) + "\n")
        output.flush()
        raise
    result["after"] = workspace_snapshot(client, state["window_id"])
    result["intermediate"] = state["intermediate"]
    result["finished_at"] = now_iso()
    result["elapsed_seconds"] = round(time.time() - started, 3)
    output.write(json.dumps(result, sort_keys=True) + "\n")
    output.flush()
    return result


def launch_agent_probe(client: cmux, state: dict[str, Any], workspace_name: str,
                       *, suppressed: bool = False, timeout: float = 60.0) -> dict[str, Any]:
    workspace = workspace_id(state, workspace_name)
    caller = state["workspaces"]["g60-w03"]["tab_ids"][0]
    # This chapter uses a fresh, disposable tagged instance. Clear its notice
    # history once, before seeding the exact synthetic notice IDs.
    client._call("notification.clear")
    params: dict[str, Any] = {
        "type": "codex",
        "workspace_id": workspace,
        "caller_tab_id": caller,
        "prompt": "C11-261 synthetic lifecycle probe. Do one short turn, then wait.",
        "title": f"C11-261 {workspace_name} lifecycle probe",
        "cwd": state["fixture_root"],
        "focus": False,
    }
    if suppressed:
        params["suppressed"] = True
    launched = client._call("agent.launch", params) or {}
    tab_id = launched.get("tab_id") or launched.get("surface_id")
    require(tab_id, f"agent.launch returned no tab ID: {launched}")
    tab_id = str(tab_id)
    state.setdefault("agent_probe_tab_ids", []).append(tab_id)
    deadline = time.time() + timeout
    observed: list[dict[str, Any]] = []
    waiting = False
    while time.time() < deadline:
        metadata = tab_metadata(client, workspace, tab_id)
        state_value = metadata.get("lifecycle_state") or metadata.get("activity")
        observed.append({"at": now_iso(), "lifecycle_state": state_value, "metadata": metadata})
        if state_value == "waiting":
            waiting = True
            break
        time.sleep(1)
    return {
        "tab_id": tab_id,
        "workspace_id": workspace,
        "launch": launched,
        "waiting_observed": waiting,
        "observations": observed[-10:],
        "timeout_seconds": timeout,
    }


def signal_eligible(notice: dict[str, Any], records: list[dict[str, Any]]) -> bool:
    tid = notice.get("tab_id") or notice.get("surface_id")
    if tid is None:
        return True
    metadata = next((tab["metadata"] for tab in records if tab["id"] == tid), {})
    return metadata.get("suppressed") is not True or bool(metadata.get("flag"))


def setup_attention(client: cmux, state: dict[str, Any]) -> dict[str, Any]:
    """Repeatable C2 scene: real exact-tab unread on declared synthetic agent tabs."""
    # This command is confined to the disposable tagged fixture. Reset its notice
    # history once so repeated C2 setup does not accumulate additional unread.
    client._call("notification.clear")
    caller = state["workspaces"]["g60-w03"]["tab_ids"][0]
    for number in range(9, 15):
        name = f"g60-w{number:02d}"
        params = {"workspace_id": workspace_id(state, name), "tab_id": state["workspaces"][name]["tab_ids"][0]}
        client._call("flag.lower", {**params, "by": "operator"})
        client._call("flag.unsuppress", {**params, "by": "operator"})
        if number in (10, 11, 14):
            client._call("tab.set_metadata", {**params, "metadata": {"terminal_type": "codex"}, "source": "explicit"})
            client._call("notification.create_for_tab", {**params, "title": "C11-261 synthetic waiting",
                                                        "body": name})
        if number in (11, 12):
            client._call("flag.suppress", {**params, "by": "operator"})
        if number in (9, 11):
            client._call("flag.raise", {**params, "caller_tab_id": caller, "by": "operator",
                                       "reason": "C11-261 synthetic escalation"})
    oracle = attention_oracle(client, state)
    summary = oracle["group"][group_id(state, "collapsed_flag")]
    require(len(summary["expected"]["flagged_tab_ids"]) == 2, "C2 setup requires exactly two flags")
    require(len(summary["expected"]["waiting_tab_ids"]) == 2, "C2 setup requires two unsuppressed exact notices")
    require(len(summary["expected"]["unread_notification_ids"]) == 3, "flagged suppressed unread remains eligible")
    state["attention_oracle"] = oracle
    return {"status": "SETUP", "seam": "real exact-tab unread plus declared synthetic terminal_type",
            "oracle": oracle, "ui_proven": False}


def geometry(client: cmux, state: dict[str, Any], count: int) -> dict[str, Any]:
    require(count in (9, 10, 99, 100), "geometry count must be 9, 10, 99 or 100")
    if "geometry" not in state["groups"]:
        created = client._call("workspace.group.create", {"window_id": state["window_id"], "name": "Geometry"})
        state["groups"]["geometry"] = created["group"]["id"]
    for number in range(61, 101):
        name = f"g60-w{number:02d}"
        if name not in state["workspaces"]:
            wid = client.new_workspace(window_id=state["window_id"])
            client._call("workspace.rename", {"workspace_id": wid, "title": name})
            state["workspaces"][name] = record_workspace(client, name, wid)
    names = sorted(state["workspaces"])
    for index, name in enumerate(names):
        move_workspace(client, state, name, group_id(state, "geometry") if index < count else None)
    snap = workspace_snapshot(client, state["window_id"])
    require(len(snap["workspaces"]) == 100, "geometry must have exactly 100 workspaces")
    require(snap["group_by_id"][group_id(state, "geometry")]["member_count"] == count, "geometry count mismatch")
    return {"status": "SETUP", "member_count": count, "snapshot": snap, "ui_proven": False}


def attention_oracle(client: cmux, state: dict[str, Any]) -> dict[str, Any]:
    snap = workspace_snapshot(client, state["window_id"])
    member_ids = {wid for group in snap["groups"] for wid in group["member_workspace_ids"]}
    notices = list((client._call("notification.list") or {}).get("notifications") or [])
    relevant = [notice for notice in notices if notice.get("workspace_id") in member_ids]
    workspaces: dict[str, Any] = {}
    for wid in member_ids:
        records = snap["workspaces"].get(wid, {}).get("tabs", [])
        flagged = []
        waiting = []
        for tab in records:
            metadata = tab.get("metadata") or {}
            if metadata.get("flag"):
                flagged.append(tab["id"])
            exact_unread = [notice for notice in relevant if notice.get("workspace_id") == wid
                            and (notice.get("tab_id") or notice.get("surface_id")) == tab["id"]
                            and not notice.get("is_read", False)]
            if exact_unread and metadata.get("suppressed") is not True:
                waiting.append(tab["id"])
        workspaces[wid] = {
            "flagged_tab_ids": sorted(flagged),
            "waiting_tab_ids": sorted(waiting),
            "unread_notification_ids": sorted(str(n.get("id")) for n in relevant
                if n.get("workspace_id") == wid and not n.get("is_read", False)
                and signal_eligible(n, records)),
        }
    headers: dict[str, Any] = {}
    for group in snap["groups"]:
        aggregate = {"flagged_tab_ids": [], "waiting_tab_ids": [], "unread_notification_ids": []}
        for wid in group["member_workspace_ids"]:
            for key in aggregate:
                aggregate[key].extend(workspaces.get(wid, {}).get(key, []))
        headers[group["id"]] = {
            "member_count": group["member_count"],
            "collapsed": group["is_collapsed"],
            "expected": {key: sorted(value) for key, value in aggregate.items()},
        }
    return {
        "source": "socket group membership + tab metadata + notification IDs",
        "ui_proven": False,
        "workspace": workspaces,
        "group": headers,
        "notifications": relevant,
    }


def automated(client: cmux, state_path: Path, out: Path, lifecycle_timeout: float) -> dict[str, Any]:
    state = read_json(state_path)
    require(state.get("schema") == SCHEMA, "not a C11-261 g60 state file")
    require(os.path.realpath(state["socket"]) == os.path.realpath(os.environ["C11_SOCKET"]),
            "state belongs to another socket")
    out.parent.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    with out.open("w", encoding="utf-8") as output:
        def add(name: str, action: Callable[[], tuple[list[str], list[str]]]) -> None:
            result = run_step(client, state, output, name, action)
            results.append(result)
            state["steps"].append({"step": name, "status": result["status"], "finished_at": result["finished_at"]})
            # Keep the provisioned ownership records immutable. Only explicitly
            # launched A8 tabs are added for cleanup after their identity checks.
            for record in state["workspaces"].values():
                live = result["after"]["workspaces"].get(record["id"])
                if live:
                    known = set(record["tab_ids"])
                    for tab in live["tabs"]:
                        if tab["id"] not in known and tab["id"] in state["agent_probe_tab_ids"]:
                            record["tab_ids"].append(tab["id"])
                            record["tabs"].append(tab)
            atomic_write(state_path, state)

        add("A1", lambda: (
            ["provisioned 60 workspaces", "six groups present", "two empty groups present",
             "mixed browser and markdown tabs present", "workspace/tab identities recorded"],
            [],
        ) if assert_g60(client, state) else ([], []))

        def a2() -> tuple[list[str], list[str]]:
            assert_move(client, state, "g60-w35", group_id(state, "move_lane"))
            assert_move(client, state, "g60-w35", None)
            snap = workspace_snapshot(client, state["window_id"])
            require(snap["workspaces"][workspace_id(state, "g60-w35")]["group_id"] is None,
                    "A2 out-of-group move did not detach w35")
            return ["w35 entered Move Lane", "w35 returned to ungrouped state"], []
        add("A2", a2)

        def a3() -> tuple[list[str], list[str]]:
            assert_move(client, state, "g60-w16", group_id(state, "tail"), before="g60-w15")
            assert_move(client, state, "g60-w16", group_id(state, "move_lane"), before="g60-w25")
            assert_move(client, state, "g60-w16", group_id(state, "tail"), before="g60-w17")
            tail = workspace_snapshot(client, state["window_id"])["group_by_id"][group_id(state, "tail")]
            expected = [workspace_id(state, name) for name in GROUP_MEMBERS["tail"]]
            require(tail["member_workspace_ids"] == expected, "A3 did not restore Tail member order")
            return ["w16 reordered before w15", "w16 transferred through Move Lane", "Tail membership restored"], []
        add("A3", a3)

        def a4() -> tuple[list[str], list[str]]:
            assert_move(client, state, "g60-w36", group_id(state, "empty_pinned"))
            assert_move(client, state, "g60-w37", group_id(state, "empty_collapsed"))
            before = workspace_snapshot(client, state["window_id"])
            require(before["group_by_id"][group_id(state, "empty_collapsed")]["is_collapsed"],
                    "A4 expanded Empty Collapsed during a move")
            assert_move(client, state, "g60-w36", None)
            assert_move(client, state, "g60-w37", None)
            after = workspace_snapshot(client, state["window_id"])
            require(after["group_by_id"][group_id(state, "empty_pinned")]["member_count"] == 0,
                    "A4 did not restore Empty Pinned")
            require(after["group_by_id"][group_id(state, "empty_collapsed")]["member_count"] == 0,
                    "A4 did not restore Empty Collapsed")
            return ["w36 moved to and from Empty Pinned", "w37 moved to and from collapsed empty group",
                    "collapsed state remained true"], []
        add("A4", a4)

        def a5() -> tuple[list[str], list[str]]:
            before = workspace_snapshot(client, state["window_id"])
            assert_move(client, state, "g60-w38", None, before="g60-w29")
            assert_move(client, state, "g60-w01", None, after="g60-w39")
            interim = workspace_snapshot(client, state["window_id"])
            require(interim["workspaces"][workspace_id(state, "g60-w29")]["pinned"], "w29 pin changed")
            require(interim["workspaces"][workspace_id(state, "g60-w01")]["pinned"], "w01 pin changed")
            assert_move(client, state, "g60-w01", group_id(state, "pinned_fleet"), before="g60-w02")
            after = workspace_snapshot(client, state["window_id"])
            require(after["workspaces"][workspace_id(state, "g60-w38")]["pinned"] ==
                    before["workspaces"][workspace_id(state, "g60-w38")]["pinned"],
                    "w38 pin segment changed during a drop")
            require(after["workspaces"][workspace_id(state, "g60-w01")]["pinned"], "w01 pin changed on return")
            return ["unpinned w38 was dropped toward pinned w29", "pinned w01 was dropped toward unpinned space",
                    "pin state stayed invariant"], []
        add("A5", a5)

        def a6() -> tuple[list[str], list[str]]:
            before = workspace_snapshot(client, state["window_id"])
            expect_error(client, "workspace.group.add", {
                "window_id": state["window_id"], "group_id": group_id(state, "collapsed_flag"),
                "workspace_ids": [workspace_id(state, "g60-w09")],
            }, "already_grouped")
            foreign_window = client.new_window()
            try:
                foreign_rows = rows(client, foreign_window)
                require(foreign_rows, "second-window cancellation oracle has no workspace")
                expect_error(client, "workspace.group.add", {
                    "window_id": state["window_id"], "group_id": group_id(state, "collapsed_flag"),
                    "workspace_ids": [foreign_rows[0]["id"]],
                }, "wrong_window")
            finally:
                client.close_window(foreign_window)
            after = workspace_snapshot(client, state["window_id"])
            require(before["workspace_order"] == after["workspace_order"] and before["groups"] == after["groups"],
                    "A6 rejected drop mutated the fixture")
            return ["already-grouped add rejected", "wrong-window add rejected", "fixture identity/order unchanged"], []
        add("A6", a6)

        def a7() -> tuple[list[str], list[str]]:
            close_names = [f"g60-w{i:02d}" for i in (15, 24)] + [f"g60-w{i:02d}" for i in range(16, 24)]
            for name in close_names:
                wid = workspace_id(state, name)
                before = workspace_snapshot(client, state["window_id"])
                members = before["group_by_id"][group_id(state, "tail")]["member_workspace_ids"]
                if name == "g60-w15":
                    require(members[0] == wid, "w15 is not the first Tail member")
                if name == "g60-w24":
                    require(members[-1] == wid, "w24 is not the last Tail member")
                client.close_workspace(wid)
                state["closed_workspace_ids"].append(wid)
                after = workspace_snapshot(client, state["window_id"])
                state["intermediate"].append({"operation": "close", "removed_workspace_ids": [wid],
                    "removed_tabs": before["workspaces"][wid]["tabs"], "before": before, "after": after})
                assert_identity(before, after, removed={wid})
                require(after["workspace_order"] == [item for item in before["workspace_order"] if item != wid],
                        "close changed surviving order")
                require(after["group_by_id"][group_id(state, "tail")]["member_workspace_ids"] ==
                        [item for item in members if item != wid], "close changed unrelated Tail membership")
            snap = workspace_snapshot(client, state["window_id"])
            tail = snap["group_by_id"][group_id(state, "tail")]
            require(tail["member_count"] == 0, "A7 did not drain Tail")
            require(group_id(state, "tail") in {group["id"] for group in snap["groups"]},
                    "A7 deleted the empty Tail folder")
            remaining = set(snap["workspace_order"])
            require(not remaining.intersection(state["closed_workspace_ids"]), "A7 reopened a closed workspace")
            return [f"closed {len(close_names)} Tail members", "empty Tail folder remained", "closed IDs stayed absent"], []
        add("A7", a7)

        def a8() -> tuple[list[str], list[str]]:
            setup_attention(client, state)
            return ["two flags including suppressed escalation",
                    "suppressed routine waiting excluded", "eligible unread matched exact IDs"], []

        add("A8", a8)

        def a9() -> tuple[list[str], list[str]]:
            empty_pinned = group_id(state, "empty_pinned")
            move_lane = group_id(state, "move_lane")
            before = workspace_snapshot(client, state["window_id"])
            require(before["group_by_id"][empty_pinned]["member_count"] == 0, "Empty Pinned is not empty")
            move_members = list(before["group_by_id"][move_lane]["member_workspace_ids"])
            client._call("workspace.group.delete", {"window_id": state["window_id"], "group_id": empty_pinned})
            middle = workspace_snapshot(client, state["window_id"])
            assert_identity(before, middle)
            require(set(before["group_by_id"]) - set(middle["group_by_id"]) == {empty_pinned},
                    "delete removed an unexpected group")
            state["intermediate"].append({"operation": "delete", "before": before, "after": middle})
            client._call("workspace.group.ungroup", {"window_id": state["window_id"], "group_id": move_lane})
            state["deleted_group_ids"].append(empty_pinned)
            state["un_grouped_ids"].extend(move_members)
            after = workspace_snapshot(client, state["window_id"])
            assert_identity(middle, after)
            require(set(middle["group_by_id"]) - set(after["group_by_id"]) == {move_lane},
                    "ungroup removed an unexpected group")
            require(before["workspace_order"] == after["workspace_order"], "ungroup changed canonical order")
            state["intermediate"].append({"operation": "ungroup", "before": middle, "after": after})
            require(empty_pinned not in after["group_by_id"], "A9 did not delete Empty Pinned")
            require(move_lane not in after["group_by_id"], "A9 did not remove Move Lane")
            for wid in move_members:
                require(wid in after["workspaces"] and after["workspaces"][wid]["group_id"] is None,
                        f"A9 lost or retained membership for {wid}")
            return ["deleted empty pinned group", "ungrouped Move Lane", "member workspaces and tab IDs remained alive"], []
        add("A9", a9)

        def a10() -> tuple[list[str], list[str]]:
            before = workspace_snapshot(client, state["window_id"])
            partial = [workspace_id(state, name) for name in ("g60-w60", "g60-w59", "g60-w58")]
            dry = client._call("workspace.reorder_batch", {
                "window_id": state["window_id"], "ordered_workspace_ids": partial, "dry_run": True,
            }) or {}
            dry_after = workspace_snapshot(client, state["window_id"])
            require(dry_after["workspace_order"] == before["workspace_order"], "A10 dry-run mutated order")
            real = client._call("workspace.reorder_batch", {
                "window_id": state["window_id"], "ordered_workspace_ids": partial, "dry_run": False,
            }) or {}
            after = workspace_snapshot(client, state["window_id"])
            require(set(after["workspace_order"]) == set(before["workspace_order"]), "A10 changed workspace set")
            pins = [wid for wid in before["workspace_order"] if before["workspaces"][wid]["pinned"]]
            expected = pins + partial + [wid for wid in before["workspace_order"] if wid not in pins + partial]
            require(after["workspace_order"] == expected, "A10 real batch did not apply the exact partial order")
            require(real.get("changed") is True, "A10 real batch was a no-op")
            require(all(after["workspaces"][wid]["group_id"] == before["workspaces"][wid]["group_id"]
                        for wid in before["workspaces"]), "A10 changed membership")
            for name in PINNED_WORKSPACES:
                require(after["workspaces"][workspace_id(state, name)]["pinned"] ==
                        before["workspaces"][workspace_id(state, name)]["pinned"],
                        f"A10 changed pin segment for {name}")
            return [f"dry-run changed={dry.get('changed')}", f"real changed={real.get('changed')}",
                    "workspace set and pin segment preserved"], [
                        "event emission was not captured by this one-shot socket oracle; changed=true is not event proof",
                    ]
        add("A10", a10)

    state["status"] = "automated_complete"
    state["automated_finished_at"] = now_iso()
    state["automation_result"] = {
        "steps": [{"step": item["step"], "status": item["status"]} for item in results],
        "ui_proven": False,
        "operator_approval": None,
    }
    atomic_write(state_path, state)
    return {"status": "AUTOMATED", "schema": SCHEMA, "steps": state["automation_result"]["steps"],
            "results": str(out), "state": str(state_path), "ui_proven": False}


def cleanup(client: cmux, state_path: Path, out: Path | None) -> dict[str, Any]:
    state = read_json(state_path)
    require(state.get("schema") == SCHEMA, "not a C11-261 g60 state file")
    require(os.path.realpath(state["socket"]) == os.path.realpath(os.environ["C11_SOCKET"]),
            "state belongs to another socket")
    result: dict[str, Any] = {
        "schema": SCHEMA, "started_at": now_iso(), "removed": [], "retained": [], "ui_proven": False,
    }
    live_windows = {window["id"] for window in tree(client).get("windows") or []}
    window_id = state.get("window_id")
    if window_id in live_windows:
        live_groups = groups(client, window_id)
        owned_groups = set(state.get("groups", {}).values())
        for group in live_groups:
            if group["id"] in owned_groups:
                client._call("workspace.group.delete", {"window_id": window_id, "group_id": group["id"]})
                result["removed"].append({"kind": "group", "id": group["id"]})
        live_rows = rows(client, window_id)
        owned_workspace_ids = {record["id"] for record in state.get("workspaces", {}).values()}
        for row in list(live_rows):
            wid = row["id"]
            current_tabs = tabs(client, wid)
            recorded = next((record for record in state["workspaces"].values() if record["id"] == wid), None)
            recorded_tabs = set(recorded.get("tab_ids", [])) if recorded else set()
            if wid not in owned_workspace_ids:
                result["retained"].append({"kind": "workspace", "id": wid, "reason": "not fixture-owned"})
                continue
            foreign = [tab["id"] for tab in current_tabs if tab["id"] not in recorded_tabs and tab["id"] not in state.get("agent_probe_tab_ids", [])]
            if foreign:
                result["retained"].append({"kind": "workspace", "id": wid, "reason": "contains unowned tabs", "tabs": foreign})
                continue
            client._call("workspace.close", {"window_id": window_id, "workspace_id": wid})
            result["removed"].append({"kind": "workspace", "id": wid})
        if window_id in {window["id"] for window in (client._call("window.list") or {}).get("windows", [])}:
            result["retained"].append({"kind": "window", "id": window_id, "reason": "remaining content or app fallback"})
    state["status"] = "cleaned" if not result["retained"] else "cleanup_partial"
    state["cleanup"] = result
    state["cleanup"]["finished_at"] = now_iso()
    atomic_write(state_path, state)
    if out:
        atomic_write(out, result)
    return result


def session_semantics(path: Path) -> dict[str, Any]:
    raw = read_json(path)
    windows = []
    for window in raw.get("windows") or []:
        manager = window.get("tabManager") or {}
        workspaces = []
        for workspace in manager.get("workspaces") or []:
            panels = []
            for panel in workspace.get("panels") or []:
                record = {
                    "id": panel.get("id"), "type": panel.get("type"),
                    "isPinned": panel.get("isPinned", False),
                }
                # Runtime-owned terminal titles, PTYs, pane IDs, and browser
                # rendering flags are regenerated on a clean launch. The
                # restore contract is panel identity/type plus the persisted
                # browser/markdown payload, not those volatile runtime fields.
                if panel.get("type") == "browser":
                    browser = panel.get("browser") or {}
                    record["browser"] = {
                        key: browser.get(key)
                        for key in ("backHistoryURLStrings", "forwardHistoryURLStrings",
                                    "pageZoom", "profileID")
                    }
                elif panel.get("type") == "markdown":
                    record["markdown"] = panel.get("markdown")
                panels.append(record)
            workspaces.append({
                "id": workspace.get("id"),
                "customTitle": workspace.get("customTitle"), "isPinned": workspace.get("isPinned", False),
                "groupId": workspace.get("groupId"),
                "panels": panels,
            })
        groups_raw = manager.get("workspaceGroups")
        groups_value = [
            {key: group.get(key) for key in ("id", "name", "color", "icon", "isCollapsed", "isPinned")}
            for group in groups_raw or []
        ]
        windows.append({
            "workspaces": workspaces,
            "workspaceGroups": groups_value,
            "selectedWorkspaceIndex": manager.get("selectedWorkspaceIndex"),
        })

    # A fresh tagged app can put its pre-existing empty window before the
    # restored fixture window. Match windows by their persisted identities so
    # that this harmless ordering difference cannot hide a workspace reorder.
    def window_key(window: dict[str, Any]) -> tuple[Any, ...]:
        group_ids = tuple(group.get("id") for group in window["workspaceGroups"] or [])
        workspace_ids = tuple(workspace.get("id") for workspace in window["workspaces"])
        return group_ids, workspace_ids

    windows.sort(key=window_key)
    return {"version": raw.get("version"), "windows": windows}


def compare_sessions(expected: Path, actual: Path, mode: str) -> dict[str, Any]:
    expected_semantics = session_semantics(expected)
    actual_semantics = session_semantics(actual)
    if mode == "groups":
        require(expected_semantics == actual_semantics,
                "clean restart changed group identity/order/membership or workspace/tab semantics")
    elif mode == "pre-group":
        require(expected_semantics == actual_semantics,
                "pre-group restore changed fixture workspace/tab identity or persisted semantics")
        require(len(actual_semantics["windows"]) == 1, "pre-group restore did not yield one window")
        window = actual_semantics["windows"][0]
        require(not window["workspaceGroups"], "pre-group restore invented workspace groups")
        require(len(window["workspaces"]) == 1 and window["workspaces"][0]["groupId"] is None,
                "pre-group restore did not yield one ungrouped workspace")
    elif mode == "empty-group":
        require(expected_semantics == actual_semantics,
                "empty-group restore changed fixture workspace/tab or group identity/properties")
        require(len(actual_semantics["windows"]) == 1, "empty-group restore did not yield one window")
        window = actual_semantics["windows"][0]
        require(window["workspaceGroups"] and len(window["workspaceGroups"]) == 1,
                "empty-group restore dropped the empty folder")
        require(len(window["workspaces"]) == 1 and window["workspaces"][0]["groupId"] is None,
                "empty-group control workspace unexpectedly became a member")
    else:
        raise AssertionError(f"unknown restore compare mode: {mode}")
    return {"status": "PASS", "mode": mode, "expected": str(expected), "actual": str(actual), "ui_proven": False}


def assert_fixture_session(expected: Path, actual: Path, mode: str) -> dict[str, Any]:
    return compare_sessions(expected, actual, mode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    provision_parser = sub.add_parser("provision")
    provision_parser.add_argument("--state", required=True, type=Path)
    provision_parser.add_argument("--fixture-root", required=True, type=Path)
    provision_parser.add_argument("--tag", required=True)

    snapshot_parser = sub.add_parser("snapshot")
    snapshot_parser.add_argument("--state", required=True, type=Path)
    snapshot_parser.add_argument("--out", type=Path)

    automated_parser = sub.add_parser("automated")
    automated_parser.add_argument("--state", required=True, type=Path)
    automated_parser.add_argument("--out", required=True, type=Path)
    automated_parser.add_argument("--lifecycle-timeout", type=float, default=60.0)

    cleanup_parser = sub.add_parser("cleanup")
    cleanup_parser.add_argument("--state", required=True, type=Path)
    cleanup_parser.add_argument("--out", type=Path)

    for chapter in ("attention", "geometry"):
        chapter_parser = sub.add_parser(chapter)
        chapter_parser.add_argument("--state", required=True, type=Path)
        chapter_parser.add_argument("--out", type=Path)
        if chapter == "geometry":
            chapter_parser.add_argument("--count", required=True, type=int)

    compare_parser = sub.add_parser("compare-session")
    compare_parser.add_argument("--expected", required=True, type=Path)
    compare_parser.add_argument("--actual", required=True, type=Path)
    compare_parser.add_argument("--mode", required=True, choices=["groups", "pre-group", "empty-group"])

    args = parser.parse_args()
    if args.command == "compare-session":
        result = compare_sessions(args.expected, args.actual, args.mode)
        print(json.dumps(result, sort_keys=True))
        return 0

    socket_path, _cli = test_environment()

    with cmux(socket_path) as client:
        capability_check(client)
        if args.command == "provision":
            result = provision(client, args.state, args.fixture_root, args.tag)
        elif args.command == "snapshot":
            result = snapshot_command(client, args.state, args.out)
        elif args.command == "automated":
            result = automated(client, args.state, args.out, args.lifecycle_timeout)
        elif args.command == "cleanup":
            result = cleanup(client, args.state, args.out)
        elif args.command in ("attention", "geometry"):
            state = read_json(args.state)
            require(state["socket"] == socket_path, "chapter state belongs to another socket")
            result = setup_attention(client, state) if args.command == "attention" else geometry(client, state, args.count)
            atomic_write(args.state, state)
            if args.out:
                atomic_write(args.out, result)
        else:
            raise AssertionError(f"unknown command: {args.command}")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FixtureSkip as error:
        print(f"SKIP: {error}", file=sys.stderr)
        raise SystemExit(77)
    except Exception as error:
        print(json.dumps({"status": "FAIL", "error": str(error), "ui_proven": False}), file=sys.stderr)
        raise SystemExit(1)
