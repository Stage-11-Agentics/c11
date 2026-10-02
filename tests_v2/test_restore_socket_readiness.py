#!/usr/bin/env python3
"""C11-297 startup oracle, ONLY for a disposable tagged sandbox guest.

No socket discovery, app launch, or tenant configuration changes are performed.
The caller owns the verified display, UI slot, hard dismissal timer and teardown.

1. On Atlas, with the guest app stopped, run `prepare --socket <guest-socket>
   --evidence-dir <guest-dir>`. Copy its session.json to the tagged guest session
   path. Source <guest-dir>/shell-probe.zsh through a temporary ZDOTDIR startup
   file passed only to this launch; do not edit tenant dotfiles. The script/helper
   path must exist in that guest.
2. Start `observe --socket <guest-socket> --evidence-dir <guest-dir>` BEFORE
   launching the tagged app with C11_QA_LAUNCH=resume, capturing stderr. Observe
   requires an absent socket initially and permits transport retries only until
   each client's first connection. Thereafter only typed not_ready is retried.
3. Run `verify --socket <guest-socket> --evidence-dir <guest-dir>
   --diagnostics <stderr-log> --realize-workspaces`. All eight first shell pings must have succeeded;
   every successful tree must contain all two windows/four workspaces/eight tabs.
   verify sends harmless, UUID-targeted printf commands and checks each tab's
   unique sentinel appears only in that tab. --realize-workspaces explicitly
   selects each restored workspace to mount any lazy terminal surfaces. Evidence
   distinguishes shell probes recorded before/after that selection; it does not
   claim all eight shells started during the initial restore.
4. Save the final tree/screenshots, quit cleanly through synthesized input and
   prove dismissal. For second-resume proof use a NEW evidence directory, rerun
   prepare there to create the shell hook but KEEP the app's saved session, then
   repeat observe/launch/verify. Do not copy the initial fixture over saved state.

The shell hook runs the probe synchronously as soon as the shell starts; its
first ping does NOT retry missing/refused sockets. It writes per-tab JSON even
on failure. No actual agent credentials, prompts, or resume sessions are used.
Host regression tests separately measure global ref walks and mutation edges.
"""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shlex
import socket
import sys
import time
import uuid

WORKSPACES = [f"00000297-0000-0000-0000-{i:012d}" for i in range(1, 5)]
TABS = [f"00000297-0000-0000-0001-{i:012d}" for i in range(1, 9)]
PAIRS = [(WORKSPACES[i // 2], tab) for i, tab in enumerate(TABS)]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


class NotReady(Exception):
    pass


def request(path: str, method: str, params: dict | None = None, timeout: float = 3) -> dict:
    # cmux._call turns structured failures into strings; retain error.code here
    # so only the readiness condition can be retried, never a target miss.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        connection.sendall((json.dumps({"id": 297, "method": method, "params": params or {}}) + "\n").encode())
        with connection.makefile("rb") as stream:
            line = stream.readline(8 * 1024 * 1024)
    require(bool(line), f"{method}: connection closed without a response")
    response = json.loads(line)
    require(response.get("id") == 297, f"{method}: mismatched response id")
    if not response.get("ok"):
        error = response.get("error", {})
        if error.get("code") == "not_ready":
            raise NotReady(method)
        raise AssertionError(f"{method}: unexpected failure {error}")
    return response.get("result", {})


def complete_tree(tree: dict) -> dict[str, dict]:
    windows = tree.get("windows", [])
    require(len(windows) == 2, f"successful partial tree: expected 2 windows, got {len(windows)}")
    workspaces = [workspace for window in windows for workspace in window.get("workspaces", [])]
    require({w["id"].lower() for w in workspaces} == set(WORKSPACES) and len(workspaces) == 4,
            "successful partial/wrong tree: workspace UUIDs")
    require(all(len(w.get("workspaces", [])) == 2 for w in windows), "wrong workspace distribution")
    result = {}
    for workspace in workspaces:
        areas = workspace.get("areas", [])
        require(len(areas) == 2, f"successful partial tree: areas in {workspace['id']}")
        tabs = [tab for area in areas for tab in area.get("tabs", [])]
        expected = {tab for ws, tab in PAIRS if ws == workspace["id"].lower()}
        require(len(tabs) == 2 and {tab["id"].lower() for tab in tabs} == expected, "wrong tab UUIDs/placement")
        require(all(len(area.get("tabs", [])) == 1 for area in areas), "expected one tab in each area")
        for tab in tabs:
            require(isinstance(tab.get("ref"), str) and tab["ref"].startswith("tab:"), "missing canonical tab ref")
            result[tab["id"].lower()] = tab
    return result


def retry_ready(path: str, method: str, params: dict, deadline: float, evidence: dict) -> dict:
    while time.monotonic() < deadline:
        try:
            return request(path, method, params, timeout=max(0.01, min(3, deadline - time.monotonic())))
        except NotReady:
            evidence["not_ready"] += 1
            time.sleep(0.02)
    raise AssertionError(f"{method}: not_ready exceeded 10-second readiness deadline")


def probe(path: str, workspace: str, tab: str, allow_startup_wait: float = 0) -> dict:
    evidence = {"workspace_id": workspace, "tab_id": tab, "started_at": time.time(), "not_ready": 0,
                "connection_retries": 0}
    deadline = time.monotonic() + allow_startup_wait
    while True:
        try:
            require(request(path, "system.ping").get("pong") is True, "first ping failed")
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.monotonic() >= deadline:
                raise
            evidence["connection_retries"] += 1
            time.sleep(0.02)
    evidence["first_ping_at"] = time.time()
    deadline = time.monotonic() + 10
    tree = retry_ready(path, "system.tree", {"scope": "all"}, deadline, evidence)
    tabs = complete_tree(tree)
    ident = retry_ready(path, "system.identify", {"caller": {"workspace_id": workspace, "tab_id": tab}}, deadline, evidence)
    caller = ident.get("caller") or {}
    require(str(caller.get("workspace_id", "")).lower() == workspace, "identify returned wrong workspace")
    require(str(caller.get("tab_id", "")).lower() == tab, "identify returned wrong tab")
    retry_ready(path, "tab.read_text", {"workspace_id": workspace, "tab_id": tab}, deadline, evidence)
    evidence.update(result="PASS", completed_at=time.time(), tab_ref=tabs[tab]["ref"], tree=tree)
    return evidence


def fixture() -> dict:
    windows = []
    for window_index in range(2):
        workspaces = []
        for index in range(window_index * 2, window_index * 2 + 2):
            ids = TABS[index * 2:index * 2 + 2]
            workspaces.append({
                "id": WORKSPACES[index], "processTitle": f"Readiness {index + 1}", "isPinned": False,
                "currentDirectory": "/tmp", "focusedPanelId": ids[0], "statusEntries": [], "logEntries": [],
                "panels": [{"id": tab, "type": "terminal", "title": f"Probe {index * 2 + offset + 1}",
                            "isPinned": False, "isManuallyUnread": False, "listeningPorts": [],
                            "terminal": {"workingDirectory": "/tmp"}} for offset, tab in enumerate(ids)],
                "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
                           "first": {"type": "pane", "pane": {"panelIds": [ids[0]], "selectedPanelId": ids[0]}},
                           "second": {"type": "pane", "pane": {"panelIds": [ids[1]], "selectedPanelId": ids[1]}}}},
            })
        windows.append({"frame": {"x": 50 + 30 * window_index, "y": 50 + 30 * window_index, "width": 1000, "height": 700},
                        "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": workspaces},
                        "sidebar": {"isVisible": True, "selection": "tabs", "width": 200}})
    return {"version": 1, "createdAt": 1, "windows": windows}


def save(path: Path, data: dict) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def prepare(args: argparse.Namespace) -> None:
    require(not args.evidence_dir.exists(), "prepare needs a NEW evidence directory to exclude stale passes")
    args.evidence_dir.mkdir(parents=True)
    save(args.evidence_dir / "session.json", fixture())
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "shell-probe", "--socket", args.socket,
                          "--evidence-dir", str(args.evidence_dir)])
    (args.evidence_dir / "shell-probe.zsh").write_text(
        "# Source only from the disposable sandbox guest's shell startup.\n"
        "if [[ ${C11_TAB_ID:-${CMUX_SURFACE_ID:-}} == 00000297-0000-0000-0001-* ]]; then\n"
        f"  {command}\n"
        "fi\n"
    )
    print(json.dumps({"result": "PREPARED", "directory": str(args.evidence_dir)}))


def shell_probe(args: argparse.Namespace) -> None:
    tab = (os.environ.get("C11_TAB_ID") or os.environ.get("CMUX_SURFACE_ID") or "").lower()
    require(tab in TABS, "shell-probe requires one of the synthetic fixture tab IDs")
    workspace = dict((tab_id, ws) for ws, tab_id in PAIRS)[tab]
    path = args.evidence_dir / f"shell-{tab}.json"
    require(not path.exists(), f"duplicate shell startup record: {path}")
    try:
        evidence = probe(args.socket, workspace, tab)
    except Exception as error:
        save(path, {"result": "FAIL", "error": str(error), "tab_id": tab, "failed_at": time.time()})
        raise
    save(path, evidence)
    print(f"C11_SHELL_PROBE_PASS_{tab}")


def observe(args: argparse.Namespace) -> None:
    require(not Path(args.socket).exists(), "observe must start before the guest listener exists")
    require(args.evidence_dir.is_dir(), "run prepare first")
    require(not (args.evidence_dir / "observer.json").exists(), "observer evidence already exists")
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(probe, args.socket, ws, tab, args.timeout) for ws, tab in PAIRS]
        results = [future.result() for future in futures]
    evidence = {"result": "PASS", "clients": results}
    save(args.evidence_dir / "observer.json", evidence)
    print(json.dumps({"result": "PASS", "concurrent_clients": len(results),
                      "not_ready": sum(result["not_ready"] for result in results)}))


def text_result(result: dict) -> str:
    if "text" in result:
        return result["text"]
    return base64.b64decode(result.get("base64", "")).decode(errors="replace")


def verify(args: argparse.Namespace) -> None:
    observer = json.loads((args.evidence_dir / "observer.json").read_text())
    require(observer.get("result") == "PASS" and len(observer["clients"]) == 8, "observer did not pass")
    complete_tree(request(args.socket, "system.tree", {"scope": "all"}))
    before_realization = [tab for tab in TABS if (args.evidence_dir / f"shell-{tab}.json").exists()]
    realized_at = None
    if args.realize_workspaces:
        realized_at = time.time()
        for workspace in WORKSPACES:
            request(args.socket, "workspace.select", {"workspace_id": workspace})
            # Let AppKit realize this workspace before selecting the next one.
            deadline = time.monotonic() + 10
            expected = [tab for ws, tab in PAIRS if ws == workspace]
            while time.monotonic() < deadline:
                if all((args.evidence_dir / f"shell-{tab}.json").exists() for tab in expected):
                    break
                time.sleep(0.05)
            require(all((args.evidence_dir / f"shell-{tab}.json").exists() for tab in expected),
                    f"shells did not realize in workspace {workspace}")
    for workspace, tab in PAIRS:
        shell = json.loads((args.evidence_dir / f"shell-{tab}.json").read_text())
        require(shell.get("result") == "PASS" and shell.get("connection_retries") == 0,
                f"listener was not ready at first shell call: {shell}")
        require(shell["tab_id"] == tab and shell["workspace_id"] == workspace, "wrong shell evidence identity")
        complete_tree(shell["tree"])
    log = args.diagnostics.read_text()
    begin_lines = [line for line in log.splitlines() if "session.restore.begin" in line]
    require(begin_lines and all("socket_listening=1" in line for line in begin_lines),
            "restore began before listener readiness, or diagnostic is missing")
    require("session.restore.ready" in log, "restore-ready diagnostic missing")
    require(log.index("session.restore.begin") < log.index("session.restore.ready"), "invalid diagnostic ordering")
    tokens = {tab: f"C11_TARGET_{uuid.uuid4().hex}" for tab in TABS}
    for workspace, tab in PAIRS:
        token = tokens[tab]
        command = "printf '%s%s\\n' " + shlex.quote(token[:12]) + " " + shlex.quote(token[12:]) + "\n"
        request(args.socket, "tab.send_text", {"workspace_id": workspace, "tab_id": tab, "text": command})
    deadline = time.monotonic() + 10
    captures = {}
    while time.monotonic() < deadline:
        captures = {tab: text_result(request(args.socket, "tab.read_text", {"workspace_id": ws, "tab_id": tab}))
                    for ws, tab in PAIRS}
        for tab, text in captures.items():
            require(not any(token in text for other, token in tokens.items() if other != tab),
                    f"misrouted sentinel reached {tab}")
        if all(tokens[tab] in captures[tab] for tab in TABS):
            break
        time.sleep(0.1)
    require(all(tokens[tab] in captures[tab] for tab in TABS), "sentinels did not reach every intended terminal")
    final_tree = request(args.socket, "system.tree", {"scope": "all"})
    complete_tree(final_tree)
    save(args.evidence_dir / "verified.json", {"result": "PASS", "tree": final_tree,
                                              "tokens": tokens, "captures": captures, "begin_lines": begin_lines,
                                              "shells_recorded_before_realization": before_realization,
                                              "explicit_realization_started_at": realized_at})
    print(json.dumps({"result": "PASS", "shell_first_calls": 8, "targeted_sentinels": 8,
                      "shells_recorded_before_realization": len(before_realization),
                      "evidence": str(args.evidence_dir / "verified.json")}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for name in ("prepare", "observe", "shell-probe", "verify"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--socket", required=True, help="explicit disposable guest socket; no discovery")
        subparser.add_argument("--evidence-dir", required=True, type=lambda value: Path(value).resolve())
        if name == "observe":
            subparser.add_argument("--timeout", type=float, default=60, help="bounded wait for first listener; then 10s readiness")
        if name == "verify":
            subparser.add_argument("--diagnostics", type=Path, required=True)
            subparser.add_argument("--realize-workspaces", action="store_true",
                                   help="explicitly select restored workspaces to mount lazy terminals")
    args = parser.parse_args()
    require(Path(args.socket).is_absolute(), "socket must be an absolute guest path")
    if args.mode == "observe":
        require(0 < args.timeout <= 60, "timeout must be in (0, 60] seconds")
    {"prepare": prepare, "observe": observe, "shell-probe": shell_probe, "verify": verify}[args.mode](args)


if __name__ == "__main__":
    main()
