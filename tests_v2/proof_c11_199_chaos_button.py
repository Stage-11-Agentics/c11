#!/usr/bin/env python3
"""C11H-199 native proof: one click on the sidebar's Chaos button casts two.

ONLY in a sandbox guest. Compile the AX helper beside this file first:
xcrun swiftc -O -target arm64-apple-macos14 tests_v2/ax_walk.swift -o <dir>/.ax-walk

Socket/CLI calls set the scene and read oracles. Every UI action is a
timestamped HID event (click count 1) aimed at an element found by its
accessibility identifier or footer position: the titlebar sidebar button (to
two columns) and the Chaos button. Proves the button sits beside Waiting Agent
in two columns, and that one click, with no popover or choice, selects a new
"Chaos HH:MM" workspace in the Chaos folder with two areas side by side (an
operator gesture, so it switches). The cast's agents are ended at the end.
200-second active limit.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("CHAOS_PROOF_OUT", "/Volumes/My Shared Files/out/chaos-button-proof"))
AX_WALK = HERE / ".ax-walk"
signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("chaos button proof deadline")))
signal.alarm(200)


class Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
CG.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
CG.CGEventCreateMouseEvent.restype = ctypes.c_void_p
CG.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
CG.CGEventSetTimestamp.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
CF.CFRelease.argtypes = [ctypes.c_void_p]

SOCKET = os.environ.get("C11_SOCKET_PATH", "")
assert re.fullmatch(r"/tmp/c11?-sandbox-[A-Za-z0-9._-]+\.sock", SOCKET), "sandbox socket required"
RUN = re.sub(r"^/tmp/c11?-sandbox-", "", SOCKET).removesuffix(".sock")
APPS = list((Path("/Users/admin/c11-sandbox/apps") / RUN).glob("*.app"))
assert len(APPS) == 1, APPS
APP = APPS[0]
EXE = str(APP / "Contents/MacOS/c11")
PIDS = [int(l.strip().split(None, 1)[0]) for l in subprocess.check_output(["ps", "-axo", "pid,comm"], text=True).splitlines()
        if l.strip().split(None, 1)[-1] == EXE]
assert len(PIDS) == 1, ("exact guest app", PIDS)
PID = PIDS[0]
CLI = str(APP / "Contents/Resources/bin/c11")
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("C11_PANEL", "C11_WORKSPACE", "CMUX_"))}
OUT.mkdir(parents=True, exist_ok=True)
REPORT = {"pid": PID, "checks": [], "events": []}


def c11(*args):
    r = subprocess.run([CLI, "--socket", SOCKET, *args], env=ENV, capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r.stdout


def rpc(method, params=None):
    return json.loads(c11("rpc", method, json.dumps(params or {})))


def ax(op):
    out = subprocess.run([str(AX_WALK), str(PID), op], capture_output=True, text=True, timeout=20)
    result = json.loads(out.stdout)
    assert not (isinstance(result, dict) and result.get("error")), result
    return result


def element(identifier):
    found = [e for e in ax("ids") if e.get("id") == identifier]
    return found[0] if found else None


def wait(predicate, label, timeout=12):
    deadline, last = time.monotonic() + timeout, None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (AssertionError, subprocess.CalledProcessError, KeyError, ValueError) as error:
            last = str(error)
        time.sleep(0.2)
    raise AssertionError((label, last))


def passed(label, **evidence):
    REPORT["checks"].append(dict(label=label, **evidence))
    print("PASS", label, flush=True)


def shot(name):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-D", "1", str(OUT / (name + ".png"))], check=True, timeout=15)


def click(e, label):
    (x, y), (w, h) = e["position"], e["size"]
    x, y = round(x + w / 2), round(y + h / 2)
    for kind in (5, 1, 2):
        event = CG.CGEventCreateMouseEvent(None, kind, Point(x, y), 0)
        if kind != 5:
            CG.CGEventSetIntegerValueField(event, 1, 1)  # kCGMouseEventClickState
        CG.CGEventSetTimestamp(event, time.monotonic_ns())
        CG.CGEventPost(0, event)
        CF.CFRelease(event)
        time.sleep(0.12)
    REPORT["events"].append(dict(click=label, x=x, y=y, at_ms=round(time.time() * 1000)))


def columns():
    ws = rpc("workspace.current")["workspace_id"]
    return json.loads(c11("sidebar-state", "--json", "--workspace", ws))["layout"]["columns"]


try:
    subprocess.run(["/usr/bin/pkill", "-x", "System Settings"], timeout=5, check=False)
    subprocess.run(["/opt/homebrew/bin/cliclick", "ku:cmd", "ku:alt", "ku:shift", "ku:ctrl"], timeout=15, check=False)
    subprocess.run([str(AX_WALK), str(PID), "activate"], timeout=10, check=False)
    wait(lambda: ax("foreground") == PID, "exact guest app is frontmost")
    for flag in rpc("flag.list").get("flags", []):  # a flag takes the second slot; this proof wants Chaos there
        c11("lower-flag", "--panel", flag.get("panel_id") or flag.get("surface_id"), "--by", "operator")

    if columns() != 2:
        toggle = wait(lambda: element("titlebarControl.toggleSidebar"), "titlebar sidebar button")
        for _ in range(4):
            if columns() == 2:
                break
            click(toggle, "titlebar sidebar button")
            time.sleep(0.6)
    assert columns() == 2, ("two columns", columns())
    # The sidebar's own "Sidebar" identifier overrides the footer buttons' ids in
    # the AX tree, so the footer is found as its row of full-width pill buttons:
    # the lowest row of AXButtons at least 100 x 40 pt inside the sidebar.
    def footer():
        pills = [e for e in ax("ids") if e.get("role") == "AXButton" and e.get("size")
                 and e["size"][0] >= 100 and e["size"][1] >= 40 and e["position"][0] < 700]
        if not pills:
            return None
        bottom = max(p["position"][1] for p in pills)
        row = sorted((p for p in pills if abs(p["position"][1] - bottom) < 2), key=lambda p: p["position"][0])
        return row if len(row) == 2 else None
    waiting, chaos = wait(footer, "two footer pills in two columns")
    same_row = abs(chaos["position"][1] - waiting["position"][1]) < 2
    right_of = chaos["position"][0] > waiting["position"][0] + waiting["size"][0]
    assert same_row and right_of, ("Chaos beside Waiting", chaos, waiting)
    passed("Chaos sits beside Waiting Agent in two columns", chaos=chaos["position"], waiting=waiting["position"])
    shot("1-sidebar-two-columns")

    before = rpc("workspace.current")["workspace_id"]
    windows_before = {e.get("window_id") for e in ax("ids")}
    click(chaos, "Chaos button")
    selected = wait(lambda: (lambda w: w if w != before else None)(rpc("workspace.current")["workspace_id"]),
                    "the click selects a new workspace", timeout=30)
    passed("one click selects the new workspace while it fills in")

    def full_grid():
        tree = rpc("system.tree", {"workspace_id": selected})
        node = [w for win in tree["windows"] for w in win["workspaces"] if w["id"] == selected][0]
        return (tree, node) if len(node["areas"]) == 2 else None
    tree, ws = wait(full_grid, "the workspace fills to two areas", timeout=40)
    groups = {g["id"]: g["name"] for win in tree["windows"] for g in win.get("workspace_groups", [])}
    assert re.fullmatch(r"Chaos \d\d:\d\d", ws["title"]), ws["title"]
    assert groups.get(ws.get("group_id")) == "Chaos", (ws.get("group_id"), groups)
    areas = ws["areas"]
    cols = {tuple(a["layout"]["percent"]["H"]) for a in areas}
    rows = {tuple(a["layout"]["percent"]["V"]) for a in areas}
    assert len(areas) == 2 and len(cols) == 2 and len(rows) == 1, (len(areas), cols, rows)
    passed("the click selects a new Chaos workspace, two areas side by side, in the Chaos folder",
           title=ws["title"], workspace=selected)
    after = ax("ids")
    assert {e.get("window_id") for e in after} <= windows_before, "no popover or other window opened"
    assert not any(e.get("id") == "ChaosCastError" for e in after), "no cast error"
    passed("no popover or choice opened")
    time.sleep(2)
    shot("2-cast-selected")
    REPORT["cast_workspace"] = selected
    REPORT["status"] = "passed"
except BaseException as error:
    REPORT["status"] = "failed"
    REPORT["error"] = repr(error)
    try:
        shot("failure")
    except Exception:
        pass
    raise
finally:
    (OUT / "result.json").write_text(json.dumps(REPORT, indent=2))
