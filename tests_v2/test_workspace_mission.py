#!/usr/bin/env python3
"""C11-493 packaged UI acceptance. Run only through sandbox-tests-v2.sh."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import time

signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("mission proof deadline")))
signal.alarm(480)
SOCKET = os.environ.get("C11_SOCKET_PATH", "")
assert os.environ.get("C11_TEST_ALLOW_LIVE_APP") == "1", "sandbox runner required"
assert re.fullmatch(r"/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock", SOCKET), "sandbox socket required"
RUN = SOCKET.removeprefix("/tmp/c11-sandbox-").removesuffix(".sock")
for key in list(os.environ):
    if key.startswith(("C11_SOCKET", "CMUX_SOCKET")):
        del os.environ[key]
APP_ROOT = f"/Users/admin/c11-sandbox/apps/{RUN}/"
PIDS = [int(line.strip().split(None, 1)[0]) for line in subprocess.check_output(
    ["ps", "-axo", "pid,comm"], text=True).splitlines()
    if APP_ROOT in line and line.endswith("/Contents/MacOS/c11")]
assert len(PIDS) == 1, ("exact guest app missing", PIDS)
PID = PIDS[0]
OUT = Path("/Volumes/My Shared Files/out/workspace-mission")
assert OUT.parent.is_dir(), "guest share missing"
OUT.mkdir(exist_ok=True)
ROOT = Path.home() / "c11-sandbox" / f"mission-fixtures-{RUN}"
A, B = ROOT / "shared", ROOT / "other"
A.mkdir(parents=True, exist_ok=True)
B.mkdir(parents=True, exist_ok=True)
FILE = A / "C11.md"
FILE.write_text("# Mission fixture\n\n## Mission\n\nExplore the amber orchard. Keep the whole mission in the tooltip.\n")
CLIENT = socket.socket(socket.AF_UNIX)
CLIENT.settimeout(12)
CLIENT.connect(SOCKET)
READER = CLIENT.makefile("rb")
SEQ = 0
RESULTS = []


def call(method, **params):
    global SEQ
    SEQ += 1
    CLIENT.sendall((json.dumps(dict(id=SEQ, method=method, params=params)) + "\n").encode())
    response = json.loads(READER.readline())
    assert response["id"] == SEQ and response.get("ok"), (method, response)
    return response["result"]


def osa(body):
    return subprocess.check_output(["osascript", "-e",
        f'tell application "System Events" to tell (first process whose unix id is {PID})\n{body}\nend tell'],
        text=True, timeout=20).strip()


def ax(ws, expression):
    return osa(f'''set es to entire contents of (first window whose subrole is "AXStandardWindow")
repeat with e in es
try
if (value of attribute "AXIdentifier" of e) is "sidebar.workspace.{ws}" then
return {expression}
end if
end try
end repeat
error "missing workspace row"''')


def frame(ws):
    return [float(v) for v in ax(ws, "{position of e, size of e}").split(", ")]


def mission(ws):
    value = ax(ws, 'value of attribute "AXValueDescription" of e')
    return "" if value == "missing value" else value


def wait_for(predicate, label, timeout=5):
    before = time.monotonic()
    while time.monotonic() - before < timeout:
        if predicate():
            return round(time.monotonic() - before, 3)
        time.sleep(.1)
    raise AssertionError(label)


def shot(name):
    assert osa("get frontmost") == "true", "guest app lost foreground"
    subprocess.run(["screencapture", "-x", "-o", str(OUT / (name + ".png"))], check=True, timeout=10)


def note(name, **details):
    RESULTS.append(dict(case=name, **details))
    (OUT / "result.json").write_text(json.dumps(dict(pid=PID, socket=SOCKET, root=str(A),
        workspace=WS, other_workspace=EMPTY, cases=RESULTS), indent=2))
    print("PASS", name, json.dumps(details), flush=True)


osa('set value of attribute "AXEnhancedUserInterface" to true')
osa("set frontmost to true")
initial = call("system.identify")["focused"]
WS, WINDOW = initial["workspace_id"], initial["window_id"]
osa("set position of window 1 to {20, 40}")
display = call("window.resize", window_id=WINDOW, width=1200, height=900)
call("workspace.rename", workspace_id=WS, title="Mission shared A")
call("workspace.set_root", workspace_id=WS, root_directory=str(A))
SHARED = call("workspace.create", window_id=WINDOW, cwd=str(A), title="Mission shared B")["workspace_id"]
EMPTY = call("workspace.create", window_id=WINDOW, cwd=str(B), title="Mission absent")["workspace_id"]
layout = call("sidebar.state", workspace_id=WS)["layout"]
if layout["double_wide"]:
    osa('click menu item "Double Wide" of menu 1 of menu item "Sidebar" of menu 1 of menu bar item "View" of menu bar 1')
wait_for(lambda: "amber orchard" in mission(WS) and mission(SHARED) == mission(WS), "shared root mission")
assert mission(EMPTY) == "", mission(EMPTY)
before_height = frame(WS)[3]
empty_height = frame(EMPTY)[3]
assert before_height > empty_height, (before_height, empty_height)
note("display-and-shared-root", display=display, frames={ws: frame(ws) for ws in [WS, SHARED, EMPTY]})
shot("01-shared-and-missing")

replacement = A / "replacement.md"
replacement.write_text("## Mission\n\nExplore the violet orchard. The second sentence is still in the tooltip.\n")
replacement.replace(FILE)
elapsed = wait_for(lambda: "violet orchard" in mission(WS) and mission(SHARED) == mission(WS), "atomic file edit")
assert frame(WS)[3] == before_height, (before_height, frame(WS))
note("live-edit-fixed-height", seconds=elapsed, mission=mission(WS))
shot("02-live-edit")

for name, contents in [("empty", b""), ("binary", b"hello\x00binary"), ("huge", b"x" * 65537)]:
    (B / "C11.md").write_bytes(contents)
    time.sleep(2.2)
    assert mission(EMPTY) == "", (name, mission(EMPTY))
    assert frame(EMPTY)[3] == empty_height, (name, frame(EMPTY), empty_height)
note("unusable-files-no-blank-line", missing_height=empty_height)
FILE.unlink()
wait_for(lambda: mission(WS) == "" and mission(SHARED) == "", "deletion clears cards")
assert frame(WS)[3] == empty_height, frame(WS)
note("deletion", height=frame(WS)[3])

FILE.write_text("## Mission\n\nExplore the silver orchard. Native agent receipt must identify this sentence.\n")
wait_for(lambda: "silver orchard" in mission(WS), "recreation")
call("workspace.set_root", workspace_id=SHARED, root_directory=str(B))
wait_for(lambda: mission(SHARED) == "", "changing root clears prior mission")
call("workspace.set_root", workspace_id=SHARED, root_directory=str(A))
wait_for(lambda: mission(SHARED) == mission(WS), "changing root back restores shared mission")
note("recreation-and-root-change")

# A process fixture records the actual environment and staged prompt emitted
# by the native launch path. A real Codex mission read follows this UI script.
fixture = ROOT / "launch-receipt.py"
fixture.write_text('''import json, os, pathlib, sys
instruction = next(a for a in sys.argv if a.startswith("Read the file at "))
path = instruction[len("Read the file at "):-len(" and follow it exactly.")]
pathlib.Path(os.environ["C11_TEST_MISSION_RECEIPT"]).write_text(json.dumps({"mission": os.environ.get("C11_MISSION_FILE"), "prompt": pathlib.Path(path).read_text(), "cwd": os.getcwd()}))
''')
task = "Keep this exact task text.\n  With trailing spaces  "
for name, target, cwd, expected in [
    ("cwd-override-keeps-target-mission", WS, B, str(FILE)),
    ("new-workspace-uses-new-root", None, A, str(FILE)),
    ("rootless-clears-inherited-context", EMPTY, A, ""),
]:
    if name.startswith("rootless"):
        call("workspace.set_root", workspace_id=EMPTY, root_directory=None)
    receipt = OUT / (name + ".json")
    receipt.unlink(missing_ok=True)
    params = dict(type="codex", cwd=str(cwd), prompt=task, focus=False,
        command_override="/usr/bin/python3 " + shlex.quote(str(fixture)),
        env={"C11_MISSION_FILE": "/wrong/inherited/C11.md", "C11_TEST_MISSION_RECEIPT": str(receipt)})
    if target:
        params["workspace_id"] = target
    else:
        params["new_workspace"] = True
    launched = call("agent.launch", **params)
    wait_for(receipt.exists, name + " process receipt", timeout=20)
    observation = json.loads(receipt.read_text())
    assert observation["mission"] == expected, (name, observation)
    assert observation["cwd"] == str(cwd), (name, observation)
    assert observation["prompt"].endswith(task), (name, observation)
    if expected:
        assert "C11_MISSION_FILE" in observation["prompt"], observation
    else:
        assert observation["prompt"] == task, observation
    note(name, receipt=observation, panel=launched.get("panel_id"))

osa('click menu item "Double Wide" of menu 1 of menu item "Sidebar" of menu 1 of menu bar item "View" of menu bar 1')
wait_for(lambda: call("sidebar.state", workspace_id=WS)["layout"]["double_wide"], "Tiles enabled")
tile_frames = {ws: frame(ws) for ws in [WS, SHARED, EMPTY]}
assert len({value[3] for value in tile_frames.values()}) == 1, tile_frames
x, y, width, height = tile_frames[WS]
subprocess.run(["/opt/homebrew/bin/cliclick", f"m:{int(x+width/2)},{int(y+height/2)}"], check=True, timeout=10)
wait_for(lambda: int(osa('count of (windows whose subrole is "AXSystemDialog")')) > 0, "Tiles hover preview")
shot("03-tiles-hover")
osa("key code 53")
subprocess.run(["/opt/homebrew/bin/cliclick", "m:1000,700"], check=True, timeout=10)
wait_for(lambda: int(osa('count of (windows whose subrole is "AXSystemDialog")')) == 0, "preview dismissed by input")
note("tiles-fixed-height-and-dismissal", frames=tile_frames)
shot("04-preview-dismissed")
osa('click menu item "Double Wide" of menu 1 of menu item "Sidebar" of menu 1 of menu bar item "View" of menu bar 1')
note("agent-fixture-ready", mission_path=str(FILE), sha256=hashlib.sha256(FILE.read_bytes()).hexdigest(), expected="Explore the silver orchard.")
signal.alarm(0)
print("Mission UI proof complete; fixture remains for the real agent launch.", flush=True)
