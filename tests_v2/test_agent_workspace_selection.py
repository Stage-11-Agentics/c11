#!/usr/bin/env python3
"""C11-323 incident replay. Run only via sandbox-tests-v2.sh.

A real shell in background workspace B issues CLI and unannotated raw v1/v2
requests toward C, while operator workspace A remains selected. The peer TTY
supplies raw-socket attribution, rather than the harness inventing a caller.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


def wire(command, path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(20)
        connection.connect(path)
        connection.sendall((command + "\n").encode())
        reply = b""
        while b"\n" not in reply:
            part = connection.recv(65536)
            if not part:
                break
            reply += part
        return reply.split(b"\n", 1)[0].decode()


def call(method, params=None, path=None):
    reply = json.loads(wire(json.dumps({"id": 323, "method": method, "params": params or {}}), path))
    assert reply.get("ok"), (method, reply)
    return reply.get("result", {})


def selected(path):
    return call("workspace.current", path=path)["workspace_id"]


def agent_probe(scene):
    path = scene["socket"]
    checks = []
    def blocked(label, command):
        reply = wire(command, path)
        assert "workspace_switch_blocked" in reply, (label, reply)
        assert selected(path) == scene["a"], label
        checks.append(label)
    def blocked_v2(method, params=None):
        blocked("v2:" + method, json.dumps({"id": 323, "method": method, "params": params or {}}))
    def cli(args, refused=False):
        result = subprocess.run([scene["cli"], "--socket", path, *args], capture_output=True, text=True, timeout=30)
        if refused:
            assert result.returncode != 0 and "workspace_switch_blocked" in result.stderr + result.stdout, (args, result)
        else:
            assert result.returncode == 0, (args, result.stderr, result.stdout)
        assert selected(path) == scene["a"], args
        checks.append("cli:" + " ".join(args))
    blocked("v1:select_workspace", "select_workspace " + scene["c"])
    for method in ("workspace.select", "workspace.next", "workspace.previous"):
        blocked_v2(method, {"workspace_id": scene["c"]} if method == "workspace.select" else {})
    for method in ("next_window", "previous_window"):
        blocked("v1:" + method, method)
    blocked_v2("workspace.last")
    blocked("v1:last_window", "last_window")
    cli(["last-window"], refused=True)
    blocked_v2("browser.focus_webview", {"workspace_id": scene["c"], "tab_id": scene["browser"]})
    blocked("v1:focus_webview", "focus_webview " + scene["browser"])
    cli(["select-workspace", "--workspace", scene["c"]], refused=True)
    cli(["next-window"], refused=True)
    cli(["previous-window"], refused=True)
    cli(["find-window", "--select", "C11-323 C"], refused=True)
    cli(["__tmux-compat", "select-window", "-t", scene["c"]], refused=True)
    cli(["focus-tab", "--workspace", scene["c"], "--tab", scene["other_tab"]])
    assert call("tab.current", {"workspace_id": scene["c"]}, path)["tab_id"] == scene["other_tab"]
    cli(["focus-area", "--workspace", scene["c"], "--area", scene["other_area"]])
    call("tab.focus", {"workspace_id": scene["c"], "tab_id": scene["c_tab"]}, path)
    call("area.focus", {"workspace_id": scene["c"], "area_id": scene["other_area"]}, path)
    assert wire("focus_surface " + scene["other_tab"], path).startswith("OK")
    assert wire("focus_pane " + scene["other_area"], path).startswith("OK")
    assert selected(path) == scene["a"]
    cli(["set-metadata", "--workspace", scene["c"], "--tab", scene["other_tab"], "--key", "description", "--value", "background proof", "--type", "string"])
    cli(["new-tab", "--workspace", scene["c"]])
    cli(["launch-agent", "--type", "codex", "--workspace", scene["c"], "--title", "C11-323 launch proof"])
    cli(["send", "--workspace", scene["c"], "--tab", scene["c_tab"], "printf 'background-send-ok\\n'"])
    cli(["browser", "--workspace", scene["c"], "--tab", scene["browser"], "eval", "document.body.innerHTML='<button id=proof onclick=\"this.textContent=123\">click</button>'; true"])
    cli(["browser", "--workspace", scene["c"], "--tab", scene["browser"], "click", "#proof"])
    cli(["browser", "--workspace", scene["c"], "--tab", scene["browser"], "snapshot"])
    checks.append("raw-focus-and-background-work")
    Path(scene["result"]).write_text(json.dumps({"ok": True, "checks": checks, "caller": os.environ.get("C11_TAB_ID")}))


def main():
    path = os.environ.get("C11_SOCKET") or os.environ.get("CMUX_SOCKET_PATH")
    cli = os.environ.get("C11_CLI") or os.environ.get("CMUXTERM_CLI")
    assert path and cli, "Run through sandbox-tests-v2.sh"
    a = selected(path)
    b = call("workspace.create", {"title": "C11-323 B"}, path)["workspace_id"]
    c = call("workspace.create", {"title": "C11-323 C"}, path)["workspace_id"]
    b_tab = call("tab.list", {"workspace_id": b}, path)["tabs"][0]["id"]
    c_tab = call("tab.list", {"workspace_id": c}, path)["tabs"][0]["id"]
    split = call("tab.split", {"workspace_id": c, "tab_id": c_tab, "direction": "right"}, path)
    browser = call("tab.create", {"workspace_id": c, "type": "browser", "url": "about:blank"}, path)["tab_id"]
    app_binary = str(Path(cli).parents[2] / "MacOS/c11")
    processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    pid = next(int(line.strip().split(None, 1)[0]) for line in processes.splitlines() if app_binary in line)
    for menu_item in ("Next Workspace", "Previous Workspace"):
        subprocess.run(["/usr/bin/osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "{menu_item}" of menu "Workspace" of menu bar 1'], check=True)
        time.sleep(0.3)
    assert selected(path) == a
    # Finder remains frontmost throughout the agent attempts.
    subprocess.run(["/usr/bin/osascript", "-e", 'tell application "Finder" to activate'], check=True)
    output = Path("/tmp/c11-323-agent-proof.json")
    output.unlink(missing_ok=True)
    scene = {"socket": path, "cli": cli, "a": a, "b": b, "c": c, "c_tab": c_tab,
             "other_tab": split["tab_id"], "other_area": split["area_id"], "browser": browser,
             "result": str(output)}
    scene_path = Path("/tmp/c11-323-scene.json")
    scene_path.write_text(json.dumps(scene))
    command = f"/usr/bin/python3 {Path(__file__).resolve()} --agent {scene_path}\n"
    call("tab.send_text", {"workspace_id": b, "tab_id": b_tab, "text": command}, path)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and not output.exists():
        assert selected(path) == a
        time.sleep(0.25)
    assert output.exists(), call("tab.read_text", {"workspace_id": b, "tab_id": b_tab}, path)
    result = json.loads(output.read_text())
    assert result["ok"] and result["caller"].lower() == b_tab.lower(), result
    frontmost = subprocess.check_output(["/usr/bin/osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true'], text=True).strip()
    assert frontmost == "Finder", frontmost
    print(json.dumps(result, indent=2))
    # Verify the emitter's actual serialized output, including unknown-free raw attribution.
    event_dir = Path.home() / "Library/Application Support/c11/events"
    records = []
    for file in event_dir.glob("events-*.ndjson"):
        for line in file.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("type") == "workspace.switch_blocked" and row.get("payload", {}).get("target", "").lower() == c.lower():
                records.append(row)
    assert records, "Missing workspace.switch_blocked events"
    assert all(row["payload"]["caller_tab_id"].lower() == b_tab.lower() for row in records), records
    assert any(row["payload"]["method"] == "select_workspace" for row in records)
    print("PASS: workspace selection remains A; raw and CLI callers attributed to B")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--agent":
        agent_probe(json.loads(Path(sys.argv[2]).read_text()))
    else:
        main()
