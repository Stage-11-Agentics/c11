#!/usr/bin/env python3
"""C11H-199 Chaos Wizard cast against the real app. Run only through sandbox-tests-v2.sh.

Proves, over the socket: the same seed draws the same four pieces; a dry run
plans and creates nothing; a real cast makes the run folder, four studios with
their commissions, the gallery pages and the cast log; opens one workspace
titled "Chaos HH:MM" in the "Chaos" folder whose four areas form two columns
of two, one agent panel each, started in its own studio; and leaves the operator's selected workspace where it was.
"""
import json
import os
from pathlib import Path
import re
import signal
import socket
import time
import urllib.parse

signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("chaos proof deadline")))
signal.alarm(240)
SOCKET = os.environ.get("C11_SOCKET_PATH", "")
assert os.environ.get("C11_TEST_ALLOW_LIVE_APP") == "1", "sandbox runner required"
assert re.fullmatch(r"/tmp/c11?-sandbox-[A-Za-z0-9._-]+\.sock", SOCKET), "sandbox socket required"

CLIENT = socket.socket(socket.AF_UNIX)
CLIENT.settimeout(90)
CLIENT.connect(SOCKET)
READER = CLIENT.makefile("rb")
SEQ = 0
CHECKS = []


def call(method, **params):
    global SEQ
    SEQ += 1
    CLIENT.sendall((json.dumps(dict(id=SEQ, method=method, params=params)) + "\n").encode())
    response = json.loads(READER.readline())
    assert response["id"] == SEQ and response.get("ok"), (method, response)
    return response["result"]


def check(label, condition, detail=None):
    assert condition, (label, detail)
    CHECKS.append(label)


def workspace_node(tree, workspace_id):
    for window in tree["windows"]:
        for ws in window["workspaces"]:
            if ws["id"] == workspace_id:
                return window, ws
    return None, None


before = call("workspace.current")["workspace_id"]

first = call("chaos.draw", mode="four", seed="42")
again = call("chaos.draw", mode="four", seed="42")
titles = [p["title"] for p in first["pieces"]]
check("seed repeats the draw", [p["title"] for p in again["pieces"]] == titles, titles)
check("four distinct premises", len(set(titles)) == 4, titles)
check("draw has no prompts unless asked", all("prompt" not in p for p in first["pieces"]))

default = call("chaos.draw")
check("the default draw is two, like the button", default["mode"] == "two" and len(default["pieces"]) == 2, default.get("mode"))

dry = call("chaos.cast", mode="four", seed="42", dry_run=True)
check("dry run plans prompts", all(p["studio"] in p["prompt"] for p in dry["pieces"]))
check("dry run creates nothing", not Path(dry["run"]).exists(), dry["run"])

cast = call("chaos.cast", mode="four", seed="42")
check("cast reports no error", "error" not in cast, cast.get("error"))
check("four agents launched", len(cast["launched"]) == 4, cast["launched"])
ws_id = cast["workspace_id"]
check("selection unchanged", call("workspace.current")["workspace_id"] == before)

root, run = Path(cast["root"]), Path(cast["run"])
check("run record", json.loads((run / "chaos-run.json").read_text())["seed"] == "42")
check("run page", "Chaos Wizard cast" in (run / "index.html").read_text())
check("root gallery lists run", "./" + urllib.parse.quote(run.name) + "/index.html" in (root / "gallery.html").read_text())
check("cast log", json.loads((root / "casts.jsonl").read_text().splitlines()[-1])["run"] == str(run))
studio_by_index = {}
for piece in cast["pieces"]:
    studio = Path(piece["studio"])
    check(f"studio {piece['index']} inside run", studio.parent == run, studio)
    check(f"commission {piece['index']}", str(studio) in (studio / "COMMISSION.md").read_text())
    studio_by_index[piece["index"]] = str(studio)
studio_by_panel = {l["panel_id"]: studio_by_index[l["index"]] for l in cast["launched"]}

deadline = time.time() + 30
while True:
    window, ws = workspace_node(call("system.tree", workspace_id=ws_id), ws_id)
    panels = [p for a in (ws or {}).get("areas", []) for p in a["panels"]]
    if ws and len(panels) == 4 and all(p.get("cwd") for p in panels):
        break
    assert time.time() < deadline, ("workspace never settled", ws)
    time.sleep(1)

check("workspace title", re.fullmatch(r"Chaos \d\d:\d\d", ws["title"]), ws["title"])
groups = {g["id"]: g for g in window.get("workspace_groups", [])}
check("in the Chaos folder", groups.get(ws.get("group_id"), {}).get("name") == "Chaos", (ws.get("group_id"), groups))
areas = ws["areas"]
check("four areas, one panel each", len(areas) == 4 and all(len(a["panels"]) == 1 for a in areas),
      [len(a["panels"]) for a in areas])
columns = {tuple(a["layout"]["percent"]["H"]) for a in areas}
rows = {tuple(a["layout"]["percent"]["V"]) for a in areas}
check("two columns of two", len(columns) == 2 and len(rows) == 2, (columns, rows))
check("launched panels are the grid", {l["panel_id"] for l in cast["launched"]} == {p["id"] for p in panels})
for p in panels:
    check(f"panel {p['ref']} in its studio", studio_by_panel.get(p["id"]) == p["cwd"].rstrip("/"), (p["id"], p["cwd"]))

# Each agent's first message names its piece (the line is typed at the shell,
# then shown by the agent), so the wild premise is on screen from the start.
# Indexes in the cast payload are 1-based. The comparison drops whitespace
# (wrapping splits the line across rows) and quotes and backslashes (the
# shell's echo of the launch line shows an apostrophe as '\'').
def flat(text):
    return "".join(ch for ch in text if not ch.isspace() and ch not in "'\\")


index_by_panel = {l["panel_id"]: l["index"] for l in cast["launched"]}
headline_by_index = {piece["index"]: piece["headline"] for piece in cast["pieces"]}
check("headlines number the pieces", all(h.startswith(f"Chaos Wizard commission {i} of 4: ")
                                         for i, h in headline_by_index.items()), headline_by_index)
for p in panels:
    want = flat(headline_by_index[index_by_panel[p["id"]]])
    deadline, seen = time.time() + 30, ""
    while want not in seen and time.time() < deadline:
        seen = flat(call("panel.read_text", workspace_id=ws_id, surface_id=p["id"], scrollback=True).get("text", ""))
        time.sleep(1)
    check(f"panel {p['ref']} shows its piece", want in seen, (want, seen[-400:]))

print(json.dumps({"ok": True, "checks": CHECKS, "run": str(run), "workspace": ws_id}))
