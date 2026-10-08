#!/usr/bin/env python3
"""Read-only oracle for C11-299 on an isolated tagged Atlas sandbox build.

Never run against the operator's session. This script does not launch, stop,
seed, or save an app. Supply the guest socket explicitly through --socket.

Scenario (after Atlas builds are enabled):
1. Stop a disposable tagged app. Copy fixtures/duplicate-session.json to that
   tag's session-com.stage11.c11.debug.<tag>.json in the guest c11 state folder.
2. Launch that tag with C11_QA_LAUNCH=resume, capturing stderr to a log.
3. Run this oracle with --phase first --diagnostics <stderr-log>. Capture the
   tagged window and check both areas are readable on a verified display.
4. Quit cleanly, relaunch the same tag with C11_QA_LAUNCH=resume, then run with
   --phase second --saved-snapshot <tag-session-file>.
5. Capture the final tree/screenshot, dismiss the tagged app through synthesized
   input and verify it closed. Bound the whole UI run with a hard timeout.

The mixed terminal/browser/markdown control is PanelIdentityRestoreTests; this
fixture isolates conflicting records and references within/across two areas.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from cmux import cmux

WORKSPACE = "00000000-0000-0000-0000-000000000299"
A, B, C = [f"00000000-0000-0000-0000-00000000000{x}" for x in "ABC"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def leaves(node: dict) -> list[dict]:
    if node["type"] == "pane":
        return [node["pane"]]
    split = node["split"]
    return leaves(split["first"]) + leaves(split["second"])


def verify_saved(path: Path) -> None:
    snapshot = json.loads(path.read_text())
    workspaces = [w for window in snapshot["windows"] for w in window["tabManager"]["workspaces"]]
    workspace = next(w for w in workspaces if w["id"].upper() == WORKSPACE)
    ids = [p["id"].upper() for p in workspace["panels"]]
    require(len(ids) == 3 and set(ids) == {A, B, C}, f"saved records: {ids}")
    panes = leaves(workspace["layout"])
    require([[i.upper() for i in p["panelIds"]] for p in panes] == [[A, B], [C]], "saved layout")
    require([p["selectedPanelId"].upper() for p in panes] == [B, C], "saved selections")
    first = next(p for p in workspace["panels"] if p["id"].upper() == A)
    require(first["metadata"]["fixture"] == "first", "saved first-record metadata")


def verify_live(client: cmux) -> dict:
    params = {"workspace_id": WORKSPACE}
    tabs = client._call("panel.list", params)["panels"]
    ids = [t["id"].upper() for t in tabs]
    require(len(ids) == 3 and set(ids) == {A, B, C}, f"live tabs: {ids}")
    areas = client._call("area.list", params)["areas"]
    require(len(areas) == 2, f"area count: {len(areas)}")
    groups = []
    for area in sorted(areas, key=lambda a: a["index"]):
        group = sorted((t for t in tabs if t["area_id"] == area["id"]), key=lambda t: t["index_in_area"])
        groups.append([t["id"].upper() for t in group])
    require(groups == [[A, B], [C]], f"live placement/order: {groups}")
    require([a["selected_panel_id"].upper() for a in sorted(areas, key=lambda a: a["index"])] == [B, C], "live area selections")
    require([t["id"].upper() for t in tabs if t["focused"]] == [C], "live focus")
    metadata = client._call("panel.get_metadata", {**params, "panel_id": A})["metadata"]
    require(metadata.get("fixture") == "first", "later duplicate overwrote metadata")
    return {"panels": tabs, "areas": areas, "metadata": metadata}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--phase", choices=["first", "second"], required=True)
    parser.add_argument("--diagnostics", type=Path)
    parser.add_argument("--saved-snapshot", type=Path)
    args = parser.parse_args()
    if args.phase == "first":
        require(args.diagnostics is not None, "first restore requires captured diagnostics")
        log = args.diagnostics.read_text()
        for reason in ("duplicate_record", "duplicate_layout_reference"):
            require(f"session.restore.drop workspace={WORKSPACE} tab={A} reason={reason}" in log,
                    f"missing {reason} diagnostic for synthetic A")
    else:
        require(args.saved_snapshot is not None, "second restore requires the saved session")
        verify_saved(args.saved_snapshot)
    with cmux(socket_path=args.socket) as client:
        evidence = verify_live(client)
    print(json.dumps({"result": "PASS", "phase": args.phase, "evidence": evidence}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
