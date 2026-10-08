#!/usr/bin/env python3
"""C11-260 disposable sidebar fixture and model oracles, NOT a UI test.

Use an isolated sandbox guest or an explicitly reserved tagged QA app on Atlas:
  C11_SOCKET=/tmp/c11-debug-TAG.sock C11_GROUPS_TEST_TAG=TAG \
  C11_CLI=/absolute/tagged.app/Contents/Resources/bin/c11 \
  python3 tests_v2/test_workspace_groups_sidebar.py prepare --state /tmp/sidebar.json
Repeat the same explicit environment with inspect or cleanup. No auto-discovery.
prepare --extra-workspaces 54 supplies 60 terminal workspaces and six folders;
this is a mount/functional fixture, NOT the mixed-type g60 performance protocol.
inspect --assert-baseline checks seed expectations before GUI interaction.
inspect --out PATH records current groups, notifications, metadata, identities,
and independently derived expected counts without asserting the UI was rendered.
cleanup removes only recorded seed IDs; foreign additions are retained.

Workspace-scoped nil-tab notifications have no public creation method. Their
aggregation is covered by unit tests; this runtime seam is explicitly unperformed.
No synthetic attention is claimed to be a native provider lifecycle capture.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from test_workspace_groups import cmux, require, test_environment

SCHEMA = "c11-260-sidebar-fixture-v1"


def save(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def command(cli, socket_path, *args):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("C11_", "CMUX_"))}
    proc = subprocess.run([cli, "--socket", socket_path, "--json", "--id-format", "both", *args],
                          capture_output=True, text=True, timeout=30, env=env)
    require(proc.returncode == 0, f"Candidate CLI failed: {args}: {proc.stderr}")
    return json.loads(proc.stdout)


def tab_ids(client, workspace):
    return client._call("panel.list", {"workspace_id": workspace})["panels"]


def read_state(path, socket_path):
    state = json.loads(path.read_text())
    require(state.get("schema") == SCHEMA, "Not a sidebar fixture state file")
    require(Path(state["socket"]).resolve() == Path(socket_path).resolve(),
            "State belongs to a different socket; refusing to touch it")
    require(state.get("token") and state.get("window"), "Incomplete fixture ownership")
    return state


def snapshot(client, state, cli, socket_path):
    tree = client._call("system.tree", {"scope": "all"})
    windows = tree["windows"]
    live = {w["id"]: window["id"] for window in windows for w in window["workspaces"]}
    groups = []
    if any(window["id"] == state["window"] for window in windows):
        payload = command(cli, socket_path, "workspace-group", "list", "--window", state["window"])
        groups = payload["workspace_groups"]
        require(groups == client._call("workspace.group.list", {"window_id": state["window"]})["workspace_groups"],
                "Bundled CLI and socket group list disagree")
    notices = client._call("notification.list")["notifications"]
    owned_workspace_ids = {value["id"] for value in state["workspaces"].values()}
    relevant_notices = [n for n in notices if n["workspace_id"] in owned_workspace_ids]
    tab_metadata = {}
    workspaces = {}
    for wid in owned_workspace_ids:
        if wid not in live:
            continue
        rows = client._call("workspace.list", {"window_id": live[wid]})["workspaces"]
        row = next(row for row in rows if row["id"] == wid)
        tabs = tab_ids(client, wid)
        waiting = flagged = 0
        for tab in tabs:
            md = client._call("panel.get_metadata", {"workspace_id": wid, "panel_id": tab["id"]})["metadata"]
            tab_metadata[tab["id"]] = md
            is_flagged = bool(md.get("flag"))
            suppressed = md.get("suppressed") is True
            exact_unread = any(n["workspace_id"] == wid and
                               (n.get("panel_id")) == tab["id"] and
                               not n["is_read"] for n in relevant_notices)
            flagged += int(is_flagged)
            # The seeded terminal demands use exact unread notices. This is an
            # expected-input oracle, not a second lifecycle implementation or a
            # socket claim that the header actually shows its resolved state.
            waiting += int(exact_unread and not suppressed)
        workspaces[wid] = {
            "window_id": live[wid], "record": row, "panels": tabs,
            "expected_attention": {
                "flaggedCount": flagged, "waitingCount": waiting,
                "unreadCount": sum(not n["is_read"] for n in relevant_notices if n["workspace_id"] == wid),
            },
        }
    expected_headers = {}
    for group in groups:
        members = group["member_workspace_ids"]
        unknown_members = [wid for wid in members if wid not in workspaces]
        counts = {"memberCount": len(members), "flaggedCount": 0, "waitingCount": 0, "unreadCount": 0}
        for wid in members:
            if wid in workspaces:
                for key, value in workspaces[wid]["expected_attention"].items():
                    counts[key] += value
        expected_headers[group["id"]] = {
            "counts": counts, "complete_owned_member_oracle": not unknown_members,
            "unowned_members_not_inspected": unknown_members,
            "violet_expected": counts["flaggedCount"] > 0,
            "collapsed": group["is_collapsed"],
        }
    identity = {wid: [tab["id"] for tab in record["panels"]] for wid, record in workspaces.items()}
    seed_identity = {record["id"]: record["panel_ids"] for record in state["workspaces"].values()}
    missing_workspaces = sorted(set(seed_identity) - set(identity))
    missing_tabs = {wid: sorted(set(tabs) - set(identity.get(wid, [])))
                    for wid, tabs in seed_identity.items() if set(tabs) - set(identity.get(wid, []))}
    return {
        "scope": "socket/CLI setup and expected model oracle only", "ui_proven": False,
        "timestamp_unix": time.time(), "fixture_token": state["token"],
        "group_list": groups, "expected_headers": expected_headers,
        "workspaces": workspaces, "tab_metadata": tab_metadata,
        "notifications": relevant_notices, "identities": identity,
        "seed_identities_preserved": not missing_workspaces and not missing_tabs,
        "missing_seed_workspaces": missing_workspaces, "missing_seed_tabs": missing_tabs,
        "selection": {window["id"]: window.get("selected_workspace_id") for window in windows},
        "tree": tree,
        "unperformed": ["visible header/menus/pointer drag", "native responder and shell process continuity",
                        "mount caps require real mount/prime logs", "subset resume requires actual picker",
                        "workspace-scoped nil-tab unread: no public fixture injector; unit coverage only"],
    }


def assert_baseline(report, state):
    require(report["seed_identities_preserved"], "A seeded workspace/tab disappeared")
    gid = state["groups"]["attention"]
    actual = report["expected_headers"][gid]
    require(actual["counts"] == {"memberCount": 3, "flaggedCount": 1, "waitingCount": 1, "unreadCount": 3},
            f"Attention seed not intact: {actual}")
    require(actual["collapsed"] and actual["violet_expected"], "Attention group must be collapsed with a flag")
    require(report["selection"].get(state["window"]) == state["workspaces"]["active"]["id"],
            "Expected the active terminal to remain selected inside its collapsed group")
    plain = state["workspaces"]["flagged_plain"]["panel_ids"][0]
    md = report["tab_metadata"][plain]
    require(md.get("terminal_type") in (None, "shell", "terminal"), "Plain flagged terminal became an agent")
    require(md.get("suppressed") is True and bool(md.get("flag")), "Plain flag/suppression fixture changed")
    suppressed = state["workspaces"]["suppressed"]["panel_ids"][0]
    require(report["tab_metadata"][suppressed].get("suppressed") is True, "Suppressed demand not suppressed")


def prepare(client, state_path, socket_path, cli, extra):
    require(not state_path.exists(), "State already exists; inspect or cleanup it first")
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state = {"schema": SCHEMA, "token": str(uuid.uuid4()), "socket": socket_path,
             "cli": str(Path(cli).resolve()), "cli_sha256": hashlib.sha256(Path(cli).read_bytes()).hexdigest(),
             "created_unix": time.time(), "window": None, "groups": {}, "workspaces": {},
             "status": "preparing", "fixture_kind": "synthetic terminal-only functional fixture"}
    # Save every owned ID immediately so a partial setup remains cleanable.
    save(state_path, state)
    try:
        state["window"] = client.new_window()
        save(state_path, state)
        initial = client._call("workspace.list", {"window_id": state["window"]})["workspaces"]
        require(len(initial) == 1, "New fixture window must start with one workspace")
        roles = ["active", "waiting", "suppressed", "flagged_plain", "destination", "ungrouped"]
        roles += [f"extra_{index:02}" for index in range(extra)]
        for index, role in enumerate(roles):
            wid = initial[0]["id"] if index == 0 else client._call(
                "workspace.create", {"window_id": state["window"], "focus": False})["workspace_id"]
            state["workspaces"][role] = {"id": wid, "panel_ids": []}
            save(state_path, state)
            state["workspaces"][role]["panel_ids"] = [tab["id"] for tab in tab_ids(client, wid)]
            save(state_path, state)
            client._call("workspace.rename", {"window_id": state["window"], "workspace_id": wid,
                                               "title": f"S260 {role.replace('_', ' ')}"})
        for role, name in (("attention", "Attention: hidden members"), ("active", "Active member stays mounted"),
                           ("destination", "Move destination"), ("empty", "Empty drop target"),
                           ("pinned_empty", "Pinned empty"),
                           ("long_name", "Long group name for truncation and full accessible tooltip verification")):
            group = client._call("workspace.group.create", {"window_id": state["window"], "name": name})["group"]
            state["groups"][role] = group["id"]
            save(state_path, state)
        for role, members in (("attention", ["waiting", "suppressed", "flagged_plain"]),
                              ("active", ["active"]),
                              ("destination", ["destination"] + [r for r in roles if r.startswith("extra_")])):
            client._call("workspace.group.add", {"window_id": state["window"], "group_id": state["groups"][role],
                                                  "workspace_ids": [state["workspaces"][r]["id"] for r in members]})
        client._call("workspace.group.pin", {"window_id": state["window"], "group_id": state["groups"]["pinned_empty"]})
        client._call("workspace.action", {"window_id": state["window"],
                                          "workspace_id": state["workspaces"]["waiting"]["id"], "action": "pin"})
        # Only this window's selected terminal; no app-focus override or external app activation.
        client._call("workspace.select", {"window_id": state["window"], "workspace_id": state["workspaces"]["active"]["id"]})
        for role in ("suppressed", "flagged_plain"):
            record = state["workspaces"][role]
            client._call("flag.suppress", {"workspace_id": record["id"], "panel_id": record["panel_ids"][0], "by": "agent"})
        record = state["workspaces"]["flagged_plain"]
        client._call("flag.raise", {"workspace_id": record["id"], "panel_id": record["panel_ids"][0],
                                    "caller_panel_id": state["workspaces"]["active"]["panel_ids"][0],
                                    "by": "agent", "reason": "Synthetic C11-260 validation flag; no operator action"})
        for role in ("waiting", "suppressed", "flagged_plain"):
            record = state["workspaces"][role]
            client._call("notification.create_for_panel", {
                "workspace_id": record["id"], "panel_id": record["panel_ids"][0],
                "title": f"Synthetic S260 {role}", "subtitle": state["token"],
                "body": "Disposable sidebar fixture; not a real agent request"})
        for role in ("attention", "active", "empty"):
            client._call("workspace.group.collapse", {"window_id": state["window"], "group_id": state["groups"][role]})
        report = snapshot(client, state, cli, socket_path)
        assert_baseline(report, state)
        state["status"] = "prepared"
        state["baseline"] = report
        save(state_path, state)
        return {"status": "PREPARED", "state": str(state_path), "window_id": state["window"],
                "groups": state["groups"], "workspaces": state["workspaces"],
                "expected_attention_header": report["expected_headers"][state["groups"]["attention"]],
                "ui_proven": False, "unperformed": report["unperformed"]}
    except BaseException as error:
        state["status"] = "prepare_failed"
        state["error"] = str(error)
        save(state_path, state)
        raise


def cleanup(client, state, path):
    require(state.get("status") != "cleaned", "Fixture already cleaned")
    tree = client._call("system.tree", {"scope": "all"})
    owners = {w["id"]: window["id"] for window in tree["windows"] for w in window["workspaces"]}
    live_window_ids = {window["id"] for window in tree["windows"]}
    retained = []
    removed = []
    if state["window"] in live_window_ids:
        groups = client._call("workspace.group.list", {"window_id": state["window"]})["workspace_groups"]
        for group in groups:
            if group["id"] in state["groups"].values():
                client._call("workspace.group.delete", {"window_id": state["window"], "group_id": group["id"]})
    if state["window"] in live_window_ids:
        rows = client._call("workspace.list", {"window_id": state["window"]})["workspaces"]
        groups = client._call("workspace.group.list", {"window_id": state["window"]})["workspace_groups"]
        owned = {record["id"]: set(record["panel_ids"]) for record in state["workspaces"].values()}
        only_owned = not groups and all(
            row["id"] in owned and all(tab["id"] in owned[row["id"]] for tab in tab_ids(client, row["id"]))
            for row in rows)
        if only_owned:
            client.close_window(state["window"])
            removed.extend(row["id"] for row in rows)
            for row in rows:
                owners.pop(row["id"], None)
    for record in reversed(list(state["workspaces"].values())):
        wid = record["id"]
        if wid not in owners:
            continue
        tabs = tab_ids(client, wid)
        # If a validator dropped an unowned tab into an owned workspace, retain
        # the containing workspace rather than closing somebody else's tab.
        if any(tab["id"] not in record["panel_ids"] for tab in tabs):
            retained.append({"workspace_id": wid, "reason": "contains unowned tabs"})
            continue
        client._call("workspace.close", {"workspace_id": wid, "window_id": owners[wid]})
        removed.append(wid)
    # Some apps close an empty window, others create a replacement workspace.
    # Never close that replacement or an operator-created addition by inference.
    windows = client._call("window.list")["windows"]
    if state["window"] in {window["id"] for window in windows}:
        rows = client._call("workspace.list", {"window_id": state["window"]})["workspaces"]
        groups = client._call("workspace.group.list", {"window_id": state["window"]})["workspace_groups"]
        if not rows and not groups:
            client.close_window(state["window"])
        else:
            retained.append({"window_id": state["window"], "reason": "remaining unowned or retained contents",
                             "workspace_ids": [row["id"] for row in rows], "group_ids": [g["id"] for g in groups]})
    state["status"] = "cleanup_partial" if retained else "cleaned"
    state["cleanup"] = {"removed_workspace_ids": removed, "retained": retained, "unix": time.time()}
    save(path, state)
    return {"status": "PARTIAL_CLEANUP" if retained else "CLEANED_OWN_SEEDS",
            **state["cleanup"], "ui_proven": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("phase", choices=["prepare", "inspect", "cleanup"])
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--out", type=Path, help="Optional model-oracle JSON destination")
    parser.add_argument("--extra-workspaces", type=int, default=0, help="Prepare only: 0..54 additional terminal workspaces")
    parser.add_argument("--assert-baseline", action="store_true", help="Inspect only: check initial attention and identity expectations")
    args = parser.parse_args()
    require(args.state.is_absolute() and not args.state.is_symlink(), "State must be an absolute non-symlink path")
    require(0 <= args.extra_workspaces <= 54, "extra-workspaces must be in 0..54")
    require(args.phase == "prepare" or args.extra_workspaces == 0, "extra-workspaces applies only to prepare")
    require(args.phase == "inspect" or not args.assert_baseline, "assert-baseline applies only to inspect")
    socket_path, cli = test_environment()
    with cmux(socket_path) as client:
        if args.phase == "prepare":
            result = prepare(client, args.state, socket_path, cli, args.extra_workspaces)
        else:
            state = read_state(args.state, socket_path)
            if args.phase == "cleanup":
                result = cleanup(client, state, args.state)
            else:
                result = snapshot(client, state, cli, socket_path)
                if args.assert_baseline:
                    assert_baseline(result, state)
                    result["baseline_assertions"] = "PASS (model inputs only)"
        if args.out:
            require(args.out.is_absolute() and not args.out.is_symlink(), "Output must be an absolute non-symlink path")
            require(args.out != args.state, "Output must not overwrite ownership state")
            args.out.parent.mkdir(parents=True, exist_ok=True)
            save(args.out, result)
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"status": "FAIL", "error": str(error), "ui_proven": False}), file=sys.stderr)
        raise SystemExit(1)
