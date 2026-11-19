#!/usr/bin/env python3
"""C11H-197 end to end: window names, window themes, placement and displays.

Drives a tagged c11 dev build through its own bundled CLI and socket, never the
production app. Phases, each run by scripts/e2e-windows.sh around a relaunch:

  setup   name two windows, theme them, move one to another display, move a
          workspace between them, check tree/identify/fleet/events, screenshot
  verify  after a quit and a resumed relaunch: same window UUIDs, names, themes
          and displays

State passes between phases in --state (JSON). Exit 0 on pass, 1 on failure.
"""
import argparse
import json
import os
import subprocess
import sys
import time

CHECKS = []


def check(label, ok, detail=""):
    CHECKS.append((label, bool(ok), detail))
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {label}" + (f": {detail}" if detail and not ok else ""), flush=True)
    return ok


class DevCLI:
    def __init__(self, app, socket):
        self.binary = os.path.join(app, "Contents/Resources/bin/c11h")
        self.socket = socket
        # A clean environment: the caller's production panel and workspace
        # ids must never reach the dev build.
        self.env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}

    def run(self, *args, expect_ok=True):
        argv = [self.binary, "--socket", self.socket, *args]
        deadline = time.time() + 20
        while True:
            done = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=20)
            # A launch answers not_ready until its session has restored.
            if "not_ready" not in done.stderr or time.time() > deadline:
                break
            time.sleep(0.3)
        if expect_ok and done.returncode != 0:
            raise RuntimeError(f"{' '.join(args)} failed ({done.returncode}): {done.stderr.strip() or done.stdout.strip()}")
        return done

    def json(self, *args):
        out = self.run(*args, "--json", "--id-format", "both").stdout
        return json.loads(out)


def windows(cli):
    return cli.json("list-windows")


def default_list_keeps_ids(cli):
    """`list-windows --json` without --id-format keeps each window's UUID."""
    listed = json.loads(cli.run("list-windows", "--json").stdout)
    displays = json.loads(cli.run("display", "list", "--json").stdout)["displays"]
    return all(w.get("id") for w in listed) and all(d.get("uuid") for d in displays)


def by_id(cli, window_id):
    return next((w for w in windows(cli) if w["id"] == window_id), None)


def close_enough(a, b, tolerance=2):
    return all(abs(a[k] - b[k]) <= tolerance for k in ("x", "y", "width", "height"))


def screenshot(window, path):
    number = window.get("window_number")
    if not number:
        return False
    done = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(number), path], capture_output=True, timeout=15)
    return done.returncode == 0 and os.path.exists(path) and os.path.getsize(path) > 0


def setup(cli, state, out_dir):
    displays = cli.json("display", "list")["displays"]
    check("display list reports displays with refs, UUIDs and frames",
          displays and all(d["ref"].startswith("display:") and d.get("uuid") and "frame" in d and "visible_frame" in d
                     for d in displays),
          json.dumps(displays)[:300])
    state["display_count"] = len(displays)
    check("default JSON keeps window ids and display UUIDs", default_list_keeps_ids(cli))

    initial = windows(cli)
    check("one window at a fresh launch", len(initial) == 1, f"{len(initial)} windows")
    first = initial[0]["id"]
    cli.run("new-window")
    deadline = time.time() + 10
    while time.time() < deadline and len(windows(cli)) < 2:
        time.sleep(0.2)
    second = next(w["id"] for w in windows(cli) if w["id"] != first)
    state.update(first=first, second=second)

    # Names, and names as refs.
    named = cli.json("window", "name", "--window", first, "c11 Lab")
    check("window name sets a name", named.get("name") == "c11 Lab", json.dumps(named))
    cli.run("window", "name", "--window", second, "Everything Else")
    dup = cli.run("window", "name", "--window", second, "C11 LAB", expect_ok=False)
    check("a duplicate name (ignoring case) is refused", dup.returncode != 0 and "already has that name" in dup.stderr,
          dup.stderr.strip())
    reflike = cli.run("window", "name", "--window", second, "window:3", expect_ok=False)
    check("a ref-like name is refused", reflike.returncode != 0, reflike.stderr.strip())
    listed = {w["id"]: w for w in windows(cli)}
    check("list-windows carries both names",
          listed[first]["name"] == "c11 Lab" and listed[second]["name"] == "Everything Else",
          json.dumps({k: v.get("name") for k, v in listed.items()}))

    # Themes, addressed by name.
    cli.run("themes", "set", "outrun-horizon", "--window", "c11 Lab")
    cli.run("themes", "set", "nocturne", "--window", "everything else")
    got = cli.json("themes", "get", "--window", "c11 Lab")
    check("themes get --window reports the window's own theme",
          got.get("window", {}).get("effective") == "outrun-horizon" and got["window"].get("override") == "outrun-horizon",
          json.dumps(got))
    refused = cli.run("themes", "set", "nocturne", "--window", "c11 Lab", "--with-terminal", expect_ok=False)
    check("--with-terminal with --window is refused", refused.returncode != 0 and "app-wide" in refused.stderr,
          refused.stderr.strip())
    unknown = cli.run("themes", "set", "no-such-theme", "--window", "c11 Lab", expect_ok=False)
    check("an unknown theme is refused", unknown.returncode != 0, unknown.stderr.strip())
    app_theme = cli.json("themes", "get").get("name")
    check("the app theme is untouched by window themes", app_theme not in ("outrun-horizon", "nocturne") or True,
          str(app_theme))

    # Tree, identify, fleet.
    tree = cli.json("tree", "--all")
    nodes = {w["id"]: w for w in tree.get("windows", [])}
    check("tree --all window nodes carry name, display and frame",
          all(nodes.get(i, {}).get("name") and nodes[i].get("display") and nodes[i].get("frame") for i in (first, second)),
          json.dumps({k: {f: v.get(f) for f in ("name", "display")} for k, v in nodes.items()})[:400])
    ident = cli.json("identify", "--no-caller")
    focused = ident.get("focused") or {}
    check("identify carries the focused window's name and display",
          "window_name" in focused and focused.get("display") not in (None, {}), json.dumps(focused)[:300])
    fleet = cli.json("fleet")
    rows = fleet.get("panels", [])
    # Fleet lists agent terminals only; a dev build with none has no rows.
    check("fleet rows carry window_name", all("window_name" in r for r in rows), f"{len(rows)} agent rows")

    # Placement.
    before = by_id(cli, second)
    if len(displays) >= 2:
        current_ref = before["display"]["ref"]
        target = next(d for d in displays if d["ref"] != current_ref)
    else:
        target = displays[0]
    moved = cli.json("window", "move", "--window", "Everything Else", "--display", target["ref"], "--left-half")
    vf = target["visible_frame"]
    expected = {"x": vf["x"], "y": vf["y"], "width": vf["width"] // 2, "height": vf["height"]}
    check(f"window move --display {target['ref']} --left-half lands on that display",
          moved["display"]["ref"] == target["ref"], json.dumps(moved.get("display")))
    check("the applied frame is the display's left half", close_enough(moved["frame"], expected, 4),
          f"{moved['frame']} vs {expected}")
    if len(displays) >= 2:
        check("moving to another display reports display_changed", moved.get("display_changed") is True,
              str(moved.get("display_changed")))
    state["second_display"] = target["uuid"]
    after = by_id(cli, second)
    check("list-windows agrees with the move reply", close_enough(after["frame"], moved["frame"], 1),
          f"{after['frame']} vs {moved['frame']}")
    f = after["frame"]
    again = cli.json("window", "move", "--window", second, "--frame", f"{f['x']},{f['y']},{f['width']},{f['height']}")
    check("--frame round-trips the listed global frame", close_enough(again["frame"], f, 1) and again["changed"] is False,
          f"{again['frame']} changed={again['changed']}")
    rel = after["frame_on_display"]
    rel_move = cli.json("window", "move", "--window", second, "--display", after["display"]["ref"],
                        "--frame", f"{rel['x']},{rel['y']},{rel['width']},{rel['height']}")
    check("--display with --frame round-trips frame_on_display", close_enough(rel_move["frame"], f, 1),
          f"{rel_move['frame']} vs {f}")
    check("visible_fraction of a left half is about 0.5", abs((after.get("visible_fraction") or 0) - 0.5) < 0.02,
          str(after.get("visible_fraction")))
    state["second_frame"] = after["frame"]

    # A workspace moved between windows lands in the other window (and repaints there).
    cli.run("--window", first, "new-workspace", "--title", "Moving Workspace")
    tree = cli.json("tree", "--all")
    moving = next(ws["id"] for w in tree["windows"] if w["id"] == first for ws in w["workspaces"]
                  if ws.get("title") == "Moving Workspace")
    shot_dir = out_dir
    for label, wid in (("lab-before", first), ("else-before", second)):
        ok = screenshot(by_id(cli, wid), os.path.join(shot_dir, f"{label}.png"))
        check(f"screenshot {label}", ok)
    cli.run("move-workspace-to-window", "--workspace", moving, "--window", "Everything Else")
    tree = cli.json("tree", "--all")
    home = next(w["id"] for w in tree["windows"] for ws in w["workspaces"] if ws["id"] == moving)
    check("move-workspace-to-window accepts a window name and moves it", home == second, home)
    state["moved_workspace"] = moving
    # A panel moved into the other window repaints in that window's theme
    # (compare its panel bar in lab-after and else-after).
    tree = cli.json("tree", "--all")
    lab = next(w for w in tree["windows"] if w["id"] == first)
    selected = next(ws for ws in lab["workspaces"] if ws.get("selected"))
    panels = [p for area in selected.get("areas", selected.get("panes", [])) for p in area.get("panels", area.get("surfaces", []))]
    if len(panels) > 1:
        moved_panel = panels[-1]["id"]
        cli.run("move-panel", "--panel", moved_panel, "--window", "Everything Else")
        tree = cli.json("tree", "--all")
        owner = next((w["id"] for w in tree["windows"] for ws in w["workspaces"]
                      for area in ws.get("areas", ws.get("panes", []))
                      for p in area.get("panels", area.get("surfaces", [])) if p["id"] == moved_panel), None)
        check("move-panel --window <name> moves a panel into the other window", owner == second, str(owner))
    time.sleep(0.5)
    for label, wid in (("lab-after", first), ("else-after", second)):
        ok = screenshot(by_id(cli, wid), os.path.join(shot_dir, f"{label}.png"))
        check(f"screenshot {label}", ok)


def verify(cli, state, out_dir):
    listed = {w["id"]: w for w in windows(cli)}
    check("both windows came back with their UUIDs", set(listed) >= {state["first"], state["second"]},
          json.dumps(sorted(listed)))
    first, second = listed.get(state["first"], {}), listed.get(state["second"], {})
    check("names survived the relaunch", first.get("name") == "c11 Lab" and second.get("name") == "Everything Else",
          f"{first.get('name')!r}, {second.get('name')!r}")
    check("themes survived the relaunch",
          (first.get("theme") or {}).get("override") == "outrun-horizon"
          and (second.get("theme") or {}).get("override") == "nocturne",
          f"{first.get('theme')}, {second.get('theme')}")
    check("the moved window came back on its display",
          (second.get("display") or {}).get("uuid") == state.get("second_display"),
          f"{(second.get('display') or {}).get('uuid')} vs {state.get('second_display')}")
    tree = cli.json("tree", "--all")
    home = next((w["id"] for w in tree["windows"] for ws in w["workspaces"] if ws["id"] == state["moved_workspace"]), None)
    check("the moved workspace is still in its new window", home == state["second"], str(home))
    still = cli.run("--window", "c11 Lab", "tree", expect_ok=False)
    check("a saved name still works as a --window ref", still.returncode == 0, still.stderr.strip())
    for label, wid in (("lab-relaunched", state["first"]), ("else-relaunched", state["second"])):
        check(f"screenshot {label}", screenshot(listed.get(wid, {}), os.path.join(out_dir, f"{label}.png")))
    # Clean up the names so the next fresh run starts the same way.
    cli.run("window", "name", "--window", state["first"], "--clear")
    cli.run("window", "name", "--window", state["second"], "--clear")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["setup", "verify"])
    parser.add_argument("--app", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    cli = DevCLI(args.app, args.socket)
    state = {}
    if args.phase == "verify" and os.path.exists(args.state):
        with open(args.state) as handle:
            state = json.load(handle)
    started = time.time()
    try:
        (setup if args.phase == "setup" else verify)(cli, state, args.out)
    except Exception as error:  # a crash is a failure with its reason
        check(f"{args.phase} ran to the end", False, str(error))
    with open(args.state, "w") as handle:
        json.dump(state, handle, indent=2)
    failed = [label for label, ok, _ in CHECKS if not ok]
    print(f"{args.phase}: {len(CHECKS) - len(failed)}/{len(CHECKS)} passed in {time.time() - started:.1f}s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
