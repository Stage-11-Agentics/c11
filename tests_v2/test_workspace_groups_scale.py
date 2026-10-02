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
    """Record shell PIDs without treating a missing TTY as a test failure."""
    if not tty or not isinstance(tty, str):
        return []
    tty_name = Path(tty).name
    try:
        proc = subprocess.run(
            ["ps", "-t", tty_name, "-o", "pid=,comm="],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    result: list[int] = []
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        command = Path(parts[1].strip()).name.lstrip("-").lower()
        if command in SHELL_NAMES:
            result.append(pid)
    return sorted(set(result))


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
        client._call("workspace.select", {
            "window_id": window_id, "workspace_id": workspace_id(state, "g60-w03"),
        })
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
    before = workspace_snapshot(client, state["window_id"])
    result: dict[str, Any] = {
        "step": name, "started_at": now_iso(), "status": "FAIL", "assertions": [],
        "unverified": [], "before": before,
    }
    try:
        assertions, unverified = action()
        result["assertions"] = assertions
        result["unverified"] = unverified
        result["status"] = "UNVERIFIED" if unverified else "PASS"
    except BaseException as error:
        result["error"] = str(error)
        result["status"] = "FAIL"
        result["after"] = workspace_snapshot(client, state["window_id"])
        result["finished_at"] = now_iso()
        result["elapsed_seconds"] = round(time.time() - started, 3)
        output.write(json.dumps(result, sort_keys=True) + "\n")
        output.flush()
        raise
    result["after"] = workspace_snapshot(client, state["window_id"])
    result["finished_at"] = now_iso()
    result["elapsed_seconds"] = round(time.time() - started, 3)
    output.write(json.dumps(result, sort_keys=True) + "\n")
    output.flush()
    return result


def launch_agent_probe(client: cmux, state: dict[str, Any], workspace_name: str,
                       *, suppressed: bool = False, timeout: float = 60.0) -> dict[str, Any]:
    workspace = workspace_id(state, workspace_name)
    caller = state["workspaces"]["g60-w03"]["tab_ids"][0]
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
                                                if n.get("workspace_id") == wid and not n.get("is_read", False)),
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
            record_all_workspaces(client, state)
            atomic_write(state_path, state)

        add("A1", lambda: (
            ["provisioned 60 workspaces", "six groups present", "two empty groups present",
             "mixed browser and markdown tabs present", "workspace/tab identities recorded"],
            [],
        ) if assert_g60(client, state) else ([], []))

        def a2() -> tuple[list[str], list[str]]:
            move_workspace(client, state, "g60-w35", group_id(state, "move_lane"))
            move_workspace(client, state, "g60-w35", None)
            snap = workspace_snapshot(client, state["window_id"])
            require(snap["workspaces"][workspace_id(state, "g60-w35")]["group_id"] is None,
                    "A2 out-of-group move did not detach w35")
            return ["w35 entered Move Lane", "w35 returned to ungrouped state"], []
        add("A2", a2)

        def a3() -> tuple[list[str], list[str]]:
            move_workspace(client, state, "g60-w16", group_id(state, "tail"), before="g60-w15")
            move_workspace(client, state, "g60-w16", group_id(state, "move_lane"), before="g60-w25")
            move_workspace(client, state, "g60-w16", group_id(state, "tail"), before="g60-w17")
            tail = workspace_snapshot(client, state["window_id"])["group_by_id"][group_id(state, "tail")]
            expected = [workspace_id(state, name) for name in GROUP_MEMBERS["tail"]]
            require(tail["member_workspace_ids"] == expected, "A3 did not restore Tail member order")
            return ["w16 reordered before w15", "w16 transferred through Move Lane", "Tail membership restored"], []
        add("A3", a3)

        def a4() -> tuple[list[str], list[str]]:
            move_workspace(client, state, "g60-w36", group_id(state, "empty_pinned"))
            move_workspace(client, state, "g60-w37", group_id(state, "empty_collapsed"))
            before = workspace_snapshot(client, state["window_id"])
            require(before["group_by_id"][group_id(state, "empty_collapsed")]["is_collapsed"],
                    "A4 expanded Empty Collapsed during a move")
            move_workspace(client, state, "g60-w36", None)
            move_workspace(client, state, "g60-w37", None)
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
            move_workspace(client, state, "g60-w38", None, before="g60-w29")
            move_workspace(client, state, "g60-w01", None, after="g60-w39")
            interim = workspace_snapshot(client, state["window_id"])
            require(interim["workspaces"][workspace_id(state, "g60-w29")]["pinned"], "w29 pin changed")
            require(interim["workspaces"][workspace_id(state, "g60-w01")]["pinned"], "w01 pin changed")
            move_workspace(client, state, "g60-w01", group_id(state, "pinned_fleet"), before="g60-w02")
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
                client.close_workspace(wid)
                state["closed_workspace_ids"].append(wid)
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
            unverified: list[str] = []
            w09, w10, w11, w12, w13, w14 = [workspace_id(state, f"g60-w{i:02d}") for i in range(9, 15)]
            caller = state["workspaces"]["g60-w03"]["tab_ids"][0]
            w09_tab = state["workspaces"]["g60-w09"]["tab_ids"][0]
            w11_tab = state["workspaces"]["g60-w11"]["tab_ids"][0]
            w12_tab = state["workspaces"]["g60-w12"]["tab_ids"][0]
            w14_tab = state["workspaces"]["g60-w14"]["tab_ids"][0]
            client._call("flag.raise", {
                "workspace_id": w09, "tab_id": w09_tab, "caller_tab_id": caller,
                "by": "agent", "reason": "C11-261 plain collapsed-group flag",
            })
            try:
                w10_probe = launch_agent_probe(client, state, "g60-w10", timeout=lifecycle_timeout)
                if not w10_probe["waiting_observed"]:
                    unverified.append("w10 native agent launch did not expose lifecycle_state=waiting within timeout")
            except Exception as error:
                w10_probe = {"status": "unperformed", "error": str(error)}
                unverified.append(f"w10 native agent launch unavailable: {error}")
            try:
                w11_probe = launch_agent_probe(client, state, "g60-w11", timeout=lifecycle_timeout)
                w11_probe_tab = w11_probe.get("tab_id")
            except Exception as error:
                w11_probe = {"status": "unperformed", "error": str(error)}
                w11_probe_tab = w11_tab
                unverified.append(f"w11 native agent launch unavailable: {error}")
            w11_workspace = w11
            client._call("flag.suppress", {"workspace_id": w11_workspace, "tab_id": w11_probe_tab, "by": "agent"})
            client._call("flag.raise", {
                "workspace_id": w11_workspace, "tab_id": w11_probe_tab, "caller_tab_id": caller,
                "by": "agent", "reason": "C11-261 suppressed collapsed-group escalation",
            })
            client._call("flag.suppress", {"workspace_id": w12, "tab_id": w12_tab, "by": "agent"})
            before_notices = list((client._call("notification.list") or {}).get("notifications") or [])
            workspace_notice = client._call("notification.create", {
                "workspace_id": w13, "title": "C11-261 workspace notice", "subtitle": "g60-v1",
                "body": "Workspace-scoped synthetic notification",
            }) or {}
            tab_notice = client._call("notification.create_for_tab", {
                "workspace_id": w14, "tab_id": w14_tab, "title": "C11-261 exact-tab notice",
                "subtitle": "g60-v1", "body": "Exact-tab synthetic notification",
            }) or {}
            if workspace_notice.get("surface_id") or workspace_notice.get("tab_id"):
                unverified.append("w13 workspace notification used a focused tab; null-tab aggregation was not proven")
            oracle = attention_oracle(client, state)
            collapsed = oracle["group"][group_id(state, "collapsed_flag")]
            require(collapsed["collapsed"], "A8 attention group was expanded")
            require(w09_tab in collapsed["expected"]["flagged_tab_ids"], "w09 plain flag missing from oracle")
            require(w11_probe_tab in collapsed["expected"]["flagged_tab_ids"], "w11 escalation flag missing from oracle")
            require(w12_tab not in collapsed["expected"]["waiting_tab_ids"], "w12 suppressed tab counted waiting")
            new_notices = [notice for notice in oracle["notifications"] if notice not in before_notices]
            require(any((notice.get("tab_id") or notice.get("surface_id")) == w14_tab for notice in new_notices),
                    "w14 exact-tab notification missing")
            state["attention_oracle"] = oracle
            state["attention_probe"] = {"w10": w10_probe, "w11": w11_probe,
                                         "w13_response": workspace_notice, "w14_response": tab_notice}
            return ["w09 plain flag recorded", "w10 native waiting probe attempted",
                    "w11 suppression then escalation recorded", "w12 suppression excluded from waiting",
                    "w14 exact-tab notification resolved by ID", "counts derived from live IDs"], unverified
        add("A8", a8)

        def a9() -> tuple[list[str], list[str]]:
            empty_pinned = group_id(state, "empty_pinned")
            move_lane = group_id(state, "move_lane")
            before = workspace_snapshot(client, state["window_id"])
            require(before["group_by_id"][empty_pinned]["member_count"] == 0, "Empty Pinned is not empty")
            move_members = list(before["group_by_id"][move_lane]["member_workspace_ids"])
            client._call("workspace.group.delete", {"window_id": state["window_id"], "group_id": empty_pinned})
            client._call("workspace.group.ungroup", {"window_id": state["window_id"], "group_id": move_lane})
            state["deleted_group_ids"].append(empty_pinned)
            state["un_grouped_ids"].extend(move_members)
            after = workspace_snapshot(client, state["window_id"])
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
                    "id": panel.get("id"), "type": panel.get("type"), "title": panel.get("title"),
                    "isPinned": panel.get("isPinned", False),
                    "terminal": panel.get("terminal"), "browser": panel.get("browser"),
                    "markdown": panel.get("markdown"),
                }
                panels.append(record)
            workspaces.append({
                "id": workspace.get("id"), "processTitle": workspace.get("processTitle"),
                "customTitle": workspace.get("customTitle"), "isPinned": workspace.get("isPinned", False),
                "groupId": workspace.get("groupId"),
                "currentDirectory": workspace.get("currentDirectory"),
                "focusedPanelId": workspace.get("focusedPanelId"),
                "panels": panels,
                "layout": workspace.get("layout"),
            })
        groups_raw = manager.get("workspaceGroups")
        groups_value = None if groups_raw is None else [
            {key: group.get(key) for key in ("id", "name", "color", "icon", "isCollapsed", "isPinned")}
            for group in groups_raw
        ]
        windows.append({
            "workspaces": workspaces,
            "workspaceGroups": groups_value,
            "selectedWorkspaceIndex": manager.get("selectedWorkspaceIndex"),
        })
    return {"version": raw.get("version"), "windows": windows}


def compare_sessions(expected: Path, actual: Path, mode: str) -> dict[str, Any]:
    expected_semantics = session_semantics(expected)
    actual_semantics = session_semantics(actual)
    if mode == "groups":
        require(expected_semantics == actual_semantics,
                "clean restart changed group identity/order/membership or workspace/tab semantics")
    elif mode == "pre-group":
        require(len(actual_semantics["windows"]) == 1, "pre-group restore did not yield one window")
        window = actual_semantics["windows"][0]
        require(not window["workspaceGroups"], "pre-group restore invented workspace groups")
        require(len(window["workspaces"]) == 1 and window["workspaces"][0]["groupId"] is None,
                "pre-group restore did not yield one ungrouped workspace")
    elif mode == "empty-group":
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
