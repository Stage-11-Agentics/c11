#!/usr/bin/env python3
"""C11H-238 load soak: main-thread busy share and CPU under hc panel load.

Runs on the machine where the c11 app runs (a build-host sandbox guest, or a
tagged build on the build host). Drives that app through its own CLI and socket:

  1. waits for a quiet host (one-minute load under --max-load),
  2. opens --workspaces workspaces with --panels terminal panels each
     (placement spreads workspaces over hc shards; at least --min-shards
     must hold live terminals),
  3. measures the idle layout: a 30 s /usr/bin/sample of the app's main
     thread and the second sample of `top -l 2`,
  4. starts --spinners terminals rewriting their title at 10 Hz (OSC 0 with
     a braille spinner) and measures the same again, while watching
     creation-intents.json's mtime and the hang log,
  5. stops the spinners (only the loops it started) and prints one JSON row.

It never signals the app or any process it did not start. The panels it
opens stay; the guest is disposable. `--parse-sample <file>` only parses.

Usage (guest):
  python3 c11-load-soak.py --cli <c11 cli> --socket <socket> --label head --out <dir>
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

# A spinning agent: one long-lived process named `grok` (a copy of zsh) that
# rewrites its title at 10 Hz with no child processes, so hc sees title events
# and no foreground churn, like Grok's own spinner.
SPINNER = (
    "{bin}/grok -fc 'stty -icanon -echo; zmodload zsh/zselect; while :; do for c in "
    "\u280b \u2819 \u2839 \u2838 \u283c \u2834 \u2826 \u2827 \u2807 \u280f; do "
    "printf \"\\033]0;%s soak working\\007\" $c; zselect -t 10; done; done'"
)
# An idle agent: a process named `claude` (a copy of zsh) in front of its
# terminal with the tty non-canonical (signals still on), so the kernel check finds it owning the
# terminal the way an interactive agent at its prompt does.
IDLE_AGENT = "{bin}/claude -fc 'stty -icanon -echo; zmodload zsh/zselect; while :; do zselect -t 100000; done'"

# A working agent: a process named `claude` (a copy of zsh) that runs the
# app's own Claude hook verbs, the way Claude Code's hooks do: one session
# start, then turns of tool calls (pre and post tool use) and a stop. The
# journal and activity marks see the same structural events as a real agent.
HOOK_AGENT = (
    "{bin}/claude -fc 'stty -icanon -echo; zmodload zsh/zselect; C=${{C11_BUNDLED_CLI_PATH:-c11}}; "
    "S=$(/usr/bin/uuidgen); J() {{ print -r -- \"{{\\\"session_id\\\":\\\"$S\\\",\\\"cwd\\\":\\\"$PWD\\\"$1}}\"; }}; "
    "J \",\\\"source\\\":\\\"startup\\\"\" | $C claude-hook session-start >/dev/null 2>&1; "
    "while :; do J \",\\\"prompt\\\":\\\"soak\\\"\" | $C claude-hook prompt-submit >/dev/null 2>&1; "
    "for i in {{1..{tools}}}; do J \",\\\"tool_name\\\":\\\"Bash\\\"\" | $C claude-hook pre-tool-use >/dev/null 2>&1; "
    "zselect -t {tool_cs}; J \",\\\"tool_name\\\":\\\"Bash\\\"\" | $C claude-hook post-tool-use >/dev/null 2>&1; "
    "zselect -t {gap_cs}; done; J \"\" | $C claude-hook stop >/dev/null 2>&1; zselect -t {rest_cs}; done'"
)

LINE = re.compile(r"^(?P<prefix>[\s+!:|]*?)(?P<count>\d+) (?P<symbol>.+)$")


def parse_main_thread(text, probe_symbols=("MailboxAgentForeground",)):
    """Main-thread busy share from `sample` output.

    total: the main thread's sample count. idle: samples parked in
    __CFRunLoopServiceMachPort (the run loop waiting for work). Probe
    counts are the outermost frames whose symbol contains each name, so a
    nested frame is not counted twice.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if "Thread_" in line and ("Main Thread" in line or "com.apple.main-thread" in line):
            start = i
            break
    if start is None:
        return None
    head = LINE.match(lines[start].strip())
    total = int(head.group("count")) if head else 0
    idle = 0
    probes = {name: 0 for name in probe_symbols}
    open_probe = {name: None for name in probe_symbols}
    for line in lines[start + 1:]:
        if "Thread_" in line and not line.lstrip(" +!:|").startswith(tuple("0123456789")):
            break
        if re.match(r"^\s{4}\d+ Thread_", line):
            break
        m = LINE.match(line)
        if not m:
            if line.strip() == "" or line.startswith("Total number"):
                break
            continue
        depth = len(m.group("prefix"))
        count = int(m.group("count"))
        symbol = m.group("symbol")
        if "__CFRunLoopServiceMachPort" in symbol:
            idle += count
        for name in probe_symbols:
            if open_probe[name] is not None and depth <= open_probe[name]:
                open_probe[name] = None
            if open_probe[name] is None and name in symbol:
                probes[name] += count
                open_probe[name] = depth
    busy = max(0, total - idle)
    return {
        "samples": total,
        "idle_samples": idle,
        "busy_samples": busy,
        "busy_pct": round(100.0 * busy / total, 1) if total else None,
        "probe_samples": probes,
    }


class App:
    def __init__(self, cli, socket):
        self.cli, self.socket = cli, socket

    def run(self, *args, check=True):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "HC_"))}
        env["LC_ALL"] = env["LANG"] = "en_US.UTF-8"
        proc = subprocess.run([self.cli, "--socket", self.socket, *args], capture_output=True, text=True,
                              env=env, timeout=60)
        if check and proc.returncode != 0:
            raise RuntimeError(f"c11 {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc.stdout

    def json(self, *args):
        return json.loads(self.run("--json", *args))


def load1():
    out = subprocess.run(["/usr/sbin/sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout
    return float(out.strip().strip("{}").split()[0])


def wait_quiet(max_load, timeout):
    deadline = time.time() + timeout
    while True:
        current = load1()
        if current < max_load:
            return current
        if time.time() > deadline:
            raise RuntimeError(f"host not quiet: load {current} >= {max_load} after {timeout} s")
        time.sleep(10)


def app_pid(explicit):
    if explicit:
        return explicit
    out = subprocess.run(["/usr/bin/pgrep", "-x", "-n", "c11"], capture_output=True, text=True).stdout.split()
    if not out:
        out = subprocess.run(["/usr/bin/pgrep", "-f", "-n", "--", r"c11 (DEV|STAGING) .*\.app/Contents/MacOS/"],
                             capture_output=True, text=True).stdout.split()
    if not out:
        raise RuntimeError("no running c11 app found; pass --pid")
    return int(out[0])


def top_cpu(pid):
    out = subprocess.run(["/usr/bin/top", "-l", "2", "-pid", str(pid), "-stats", "pid,cpu,mem"],
                         capture_output=True, text=True, timeout=30).stdout
    rows = [line.split() for line in out.splitlines() if line.strip().startswith(str(pid) + " ")]
    if not rows:
        return None, None
    last = rows[-1]
    return float(last[1]), last[2] if len(last) > 2 else None


def take_sample(pid, seconds, path):
    subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path],
                   capture_output=True, text=True, timeout=seconds + 120)
    with open(path, errors="replace") as handle:
        return parse_main_thread(handle.read())


HANG_LOGS = []


def hang_logs():
    found = HANG_LOGS + glob.glob("/tmp/c11-hang-*.log") + glob.glob(os.path.expanduser("~/Library/Logs/c11*/hang.log"))
    return {path: os.path.getsize(path) for path in found if os.path.exists(path)}


def hang_lines_since(sizes):
    lines = []
    for path in hang_logs():
        start = sizes.get(path, 0)
        with open(path, "rb") as handle:
            handle.seek(start)
            for raw in handle.read().decode(errors="replace").splitlines():
                if raw.startswith("=== c11 hang.") or raw.startswith("=== c11 watchdog"):
                    lines.append(raw)
    return lines


def intents_files():
    # <home>/Library/Application Support/c11/HC/<session>/creation-intents.json, one per shard.
    pattern = os.path.expanduser("~/Library/Application Support/c11*/HC/*/creation-intents.json")
    return sorted(glob.glob(pattern))


def cpu_seconds(pid):
    """The process's total CPU time (user + system) from ps, in seconds."""
    out = subprocess.run(["/bin/ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    total = 0.0
    for part in out.split(":"):
        total = total * 60 + float(part)
    return total


def main_thread_seconds(pid):
    """The main thread's CPU time (system + user) from `ps -M`: its first thread row."""
    lines = subprocess.run(["/bin/ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()
    if len(lines) < 2:
        return None
    fields = lines[1].split()

    def seconds(value):
        total = 0.0
        for part in value.split(":"):
            total = total * 60 + float(part)
        return total
    try:
        return seconds(fields[6]) + seconds(fields[7])
    except (IndexError, ValueError):
        return None


def measure(pid, seconds, out, name):
    path = os.path.join(out, f"sample-{name}.txt")
    cpu_before, main_before, wall_before = cpu_seconds(pid), main_thread_seconds(pid), time.time()
    parsed = take_sample(pid, seconds, path)
    cpu_after, main_after, wall_after = cpu_seconds(pid), main_thread_seconds(pid), time.time()
    cpu, mem = top_cpu(pid)
    window_cpu = None
    if cpu_before is not None and cpu_after is not None:
        # Over the same window as the sample (sample itself costs a little).
        window_cpu = round(100.0 * (cpu_after - cpu_before) / max(0.001, wall_after - wall_before), 1)
    main_cpu = None
    if main_before is not None and main_after is not None:
        main_cpu = round(100.0 * (main_after - main_before) / max(0.001, wall_after - wall_before), 1)
    return {"sample": parsed, "cpu_pct": cpu, "cpu_pct_window": window_cpu, "main_cpu_pct_window": main_cpu,
            "mem": mem, "sample_file": path}


def live_shards(app):
    try:
        data = app.json("hc-diagnostics")
    except Exception as error:  # noqa: BLE001 - diagnostics are best-effort here
        return None, str(error)
    panels = data.get("panels", [])
    live = [p for p in panels if p.get("lifecycle") == "live"]
    per_shard = {}
    for p in live:
        per_shard[p.get("shard")] = per_shard.get(p.get("shard"), 0) + 1
    return {"live_panels": len(live), "shards": sorted(k for k in per_shard if k), "per_shard": per_shard}, None


def events_lines(since):
    """main.stall rows in the app's events files written after `since` (epoch s)."""
    rows = []
    for path in glob.glob(os.path.expanduser("~/Library/Application Support/c11*/events/events-*.ndjson")):
        if os.path.getmtime(path) < since:
            continue
        with open(path, errors="replace") as handle:
            for line in handle:
                if '"main.stall"' in line:
                    rows.append(json.loads(line))
    return rows


def stall_proof(args):
    started = time.time()
    cores = int(subprocess.run(["/usr/sbin/sysctl", "-n", "hw.ncpu"], capture_output=True, text=True).stdout)
    sizes = hang_logs()
    # Busy loops this harness starts and stops by their own handles.
    loops = [subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) for _ in range(cores)]
    try:
        time.sleep(args.stall_proof)
    finally:
        for loop in loops:
            loop.terminate()
        for loop in loops:
            loop.wait()
    time.sleep(3)
    row = {"label": args.label, "cores_loaded": cores, "seconds": args.stall_proof,
           "hang_lines": hang_lines_since(sizes), "main_stall": events_lines(started),
           "finished": time.strftime("%Y-%m-%d %H:%M:%S %Z")}
    with open(os.path.join(args.out, f"stall-{args.label}.json"), "w") as handle:
        json.dump(row, handle, indent=2)
    print(json.dumps(row, indent=2))
    return 0


def osascript(script):
    proc = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=30)
    return proc.returncode == 0, (proc.stderr or proc.stdout).strip()


def bundle_id(pid):
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "bundleid", str(pid)],
                         capture_output=True, text=True).stdout
    match = re.search(r'"CFBundleIdentifier"="([^"]+)"', out) or re.search(r'="([^"]+)"', out)
    return match.group(1) if match else None


def set_phase(phase, bundle):
    """visible: the app frontmost. inactive: Finder frontmost, the window still on
    screen. hidden: the app hidden, so no window of it is visible."""
    if phase == "visible":
        osascript(f'tell application "System Events" to set visible of (first process whose bundle identifier is "{bundle}") to true')
        return osascript(f'tell application id "{bundle}" to activate')
    if phase == "inactive":
        osascript(f'tell application "System Events" to set visible of (first process whose bundle identifier is "{bundle}") to true')
        return osascript('tell application "Finder" to activate')
    if phase == "hidden":
        osascript('tell application "Finder" to activate')
        return osascript(f'tell application "System Events" to set visible of (first process whose bundle identifier is "{bundle}") to false')
    raise ValueError(phase)


def churn_log_rows(path, since):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path, errors="replace") as handle:
        for line in handle:
            fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
            rows.append(fields)
    return [r for r in rows if r.get("ts", "") >= since]


def atin_shape(args, app, pid, row):
    """Atin's live shape (2026-11-12): many workspaces, working agents in the
    selected one, waiting marks, description churn; measured visible, inactive
    and hidden."""
    tree = app.json("tree")
    window = tree["windows"][0]
    selected = window["selected_workspace_ref"]
    row["selected_workspace"] = selected
    bindir = os.path.join(args.out, "bin")
    os.makedirs(bindir, exist_ok=True)
    target = os.path.join(bindir, "claude")
    if not os.path.exists(target):
        subprocess.run(["/bin/cp", "/bin/zsh", target], check=True)

    # The selected workspace at Atin's mark count: several areas with full tab
    # strips, working agents spread across them, extra waiting panels.
    app.run("window", "move", "--window", "window:1", "--fill", check=False)
    for i in range(max(0, args.selected_areas - 1)):
        direction = "right" if i % 2 == 0 else "down"
        if not app.run("new-area", "--workspace", selected, "--direction", direction, check=False):
            app.run("new-area", "--workspace", selected, "--direction", direction, "--allow-undersized", check=False)
    area_refs = [a["ref"] for a in (find_key(app.json("tree", "--workspace", selected), "areas") or [])] or [None]
    row["selected_areas"] = len(area_refs)

    def selected_panel(i):
        argv = ["new-panel", "--workspace", selected]
        if area_refs[i % len(area_refs)]:
            argv += ["--area", area_refs[i % len(area_refs)]]
        return (selected, app.json(*argv)["panel_ref"])

    selected_panels = [selected_panel(i) for i in range(args.selected_agents)]
    selected_waiting = [selected_panel(args.selected_agents + i) for i in range(args.waiting_selected)]
    others = []
    for w in range(args.workspaces):
        ws = app.json("new-workspace", "--title", f"soak-{w + 1}")["workspace_ref"]
        for _ in range(args.panels):
            others.append((ws, app.json("new-panel", "--workspace", ws)["panel_ref"]))
        row.setdefault("workspaces", []).append(ws)
    deadline = time.time() + 240
    shards = None
    while time.time() < deadline:
        shards, _ = live_shards(app)
        if shards and shards["live_panels"] >= len(selected_panels) + len(others):
            break
        time.sleep(3)
    row["layout"] = shards

    row["load_before_idle"] = wait_quiet(args.max_load, args.quiet_timeout)
    bundle = bundle_id(pid)
    row["bundle"] = bundle
    set_phase("visible", bundle)
    time.sleep(args.settle)
    row["idle"] = measure(pid, args.seconds, args.out, f"{args.label}-idle")

    working = selected_panels + others[: max(0, args.hook_agents - len(selected_panels))]
    command = HOOK_AGENT.format(bin=bindir, tools=args.tools_per_turn, tool_cs=int(args.tool_seconds * 100),
                                gap_cs=int(args.gap_seconds * 100), rest_cs=int(args.rest_seconds * 100))
    for ws, panel in working:
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded", command)
    rest = [p for p in others if p not in working]
    for ws, panel in selected_waiting:
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded", IDLE_AGENT.format(bin=bindir))
    # `--waiting` is the total; the selected workspace's waiting panels come first.
    waiting = (selected_waiting + ([selected_panels[-1]] if selected_panels else []) + rest)[: args.waiting]
    time.sleep(2)
    for ws, panel in waiting:
        app.run("notify", "--workspace", ws, "--panel", panel, "--title", "soak", "--body", "needs you", check=False)
    flagged = selected_panels[: args.flagged]
    for ws, panel in flagged:
        app.run("raise-flag", "--panel", panel, "soak flag", check=False)
    row["hook_agents"], row["waiting"], row["flagged"] = len(working), len(waiting), len(flagged)
    describers = (working + rest)[: args.describers]

    def churn_descriptions(rounds):
        for n in range(rounds):
            for i, (ws, panel) in enumerate(describers):
                app.run("set-description", "--workspace", ws, "--panel", panel, f"soak step {n} of agent {i}",
                        check=False)

    time.sleep(args.settle)
    roster = app.json("agents")
    states = {}
    for p in roster.get("panels", []):
        states[str(p.get("state"))] = states.get(str(p.get("state")), 0) + 1
    row["agent_states"] = states

    hang_sizes = hang_logs()
    started_iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    for phase in args.phases.split(","):
        ok, detail = set_phase(phase, bundle)
        time.sleep(5)
        churn_descriptions(1)
        phase_start = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
        if phase == "visible" and args.mark_shots:
            # Look and timing: the same marks a few times within one working
            # cycle, for a side-by-side with the other build.
            shots = os.path.join(args.out, "shots")
            os.makedirs(shots, exist_ok=True)
            user = os.environ.get("USER") or "admin"
            for n in range(args.mark_shots):
                subprocess.run(["sudo", "-n", "/bin/launchctl", "asuser", str(os.getuid()), "/usr/bin/sudo", "-n",
                                "-u", user, "/usr/sbin/screencapture", "-x",
                                os.path.join(shots, f"marks-{n:02d}.png")], capture_output=True, timeout=30)
                time.sleep(0.6)
        row.setdefault("phases", {})[phase] = measure(pid, args.seconds, args.out, f"{args.label}-{phase}")
        row["phases"][phase]["phase_set"] = ok if ok else detail
        row["phases"][phase]["churn"] = churn_log_rows(args.churn_log, phase_start)
    set_phase("visible", bundle)
    if args.memory_minutes:
        # Memory under sustained churn: the agents keep working, the window
        # stays visible, and the footprint is read every two minutes.
        series = []
        deadline = time.time() + args.memory_minutes * 60
        while True:
            out = subprocess.run(["/usr/bin/footprint", "-p", str(pid)], capture_output=True, text=True).stdout
            match = re.search(r"Footprint:\s+([\d.]+)\s+([KMG]B)", out)
            _, mem = top_cpu(pid)
            series.append({"t": round(time.time()), "footprint": " ".join(match.groups()) if match else None,
                           "top_mem": mem})
            if time.time() >= deadline:
                break
            churn_descriptions(1)
            time.sleep(120)
        row["memory_series"] = series
    row["hang_lines"] = hang_lines_since(hang_sizes)
    row["main_stall"] = events_lines(time.mktime(time.strptime(started_iso, "%Y-%m-%dT%H:%M:%S")) - time.timezone)
    for ws, panel in working:
        app.run("send-key", "--workspace", ws, "--panel", panel, "ctrl+c", check=False)
    idle_busy = (row["idle"]["sample"] or {}).get("busy_pct")
    for phase, data in row.get("phases", {}).items():
        busy = (data["sample"] or {}).get("busy_pct")
        if idle_busy is not None and busy is not None:
            data["busy_delta_pct_points"] = round(busy - idle_busy, 1)
    row["finished"] = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    path = os.path.join(args.out, f"soak-{args.label}.json")
    with open(path, "w") as handle:
        json.dump(row, handle, indent=2)
    print(json.dumps(row, indent=2))
    return 0


def find_key(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for value in obj.values():
            found = find_key(value, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = find_key(value, key)
            if found is not None:
                return found
    return None


def portal_problems(app, expected_panel_ids=()):
    """Every visible terminal portal entry in the selected workspace sits exactly
    on its anchor, shown, attached and inside the window, and every terminal the
    tree says is showing has such an entry. Returns (checked, misfits)."""
    snap = json.loads(app.run("rpc", "debug.portal.snapshot", json.dumps({"window_id": "window:1"})))
    selected = str(find_key(snap, "selected_workspace_id") or "").lower()
    portal = find_key(snap, "terminal_portal") or {}
    problems, checked, seen = [], 0, set()
    if expected_panel_ids and not portal.get("present"):
        problems.append({"panel": None, "why": ["no_terminal_portal"]})
    for entry in portal.get("entries", []):
        identity = entry.get("identity") or {}
        workspace = str(identity.get("workspace_id") or identity.get("workspace") or "").lower()
        if not entry.get("visible_in_ui") or (selected and workspace and workspace != selected):
            continue
        checked += 1
        panel_id = str(identity.get("panel_id") or identity.get("panel") or "").lower()
        seen.add(panel_id)
        hosted, anchor = entry.get("hosted") or {}, entry.get("anchor") or {}
        hf, af = hosted.get("frame_in_window"), anchor.get("frame_in_window")
        why = []
        if entry.get("orphan"):
            why.append("orphan")
        if hosted.get("hidden") or hosted.get("hidden_by_ancestor"):
            why.append("hosted_hidden")
        if not hf or not af:
            why.append("no_frame")
        else:
            off = max(abs(hf[k] - af[k]) for k in ("x", "y", "width", "height"))
            if off > 1.0:
                why.append(f"stale_frame off={off:.1f}")
            if hf["width"] <= 1 or hf["height"] <= 1:
                why.append("blank_size")
        if why:
            problems.append({"panel": panel_id, "why": why, "hosted": hf, "anchor": af})
    for panel_id in expected_panel_ids:
        if str(panel_id).lower() not in seen:
            problems.append({"panel": panel_id, "why": ["no_visible_portal_entry"]})
    return checked, problems


def panel_membership(tree):
    """{panel id: workspace id} for every panel in every workspace of a tree."""
    found = {}
    for window in tree.get("windows", []):
        for ws in window.get("workspaces", []):
            for area in ws.get("areas", []):
                for panel in area.get("panels", []):
                    if panel.get("id"):
                        found[str(panel["id"]).lower()] = str(ws.get("id")).lower()
    return found


def workspace_id(tree, ref):
    for window in tree.get("windows", []):
        for ws in window.get("workspaces", []):
            if ws.get("ref") == ref or str(ws.get("id")).lower() == str(ref).lower():
                return str(ws.get("id")).lower()
    return None


def close_problem(before, after, panel_id, source):
    """None when the panel is gone from every workspace and its own lost exactly one."""
    panel_id = str(panel_id).lower()
    if panel_id not in before:
        return "closed panel was not in the tree before"
    if panel_id in after:
        return f"closed panel still in workspace {after[panel_id]}"
    was = sum(1 for ws in before.values() if ws == source)
    now = sum(1 for ws in after.values() if ws == source)
    return None if now == was - 1 else f"source workspace panels {was} -> {now}"


def move_problem(before, after, panel_id, source, destination):
    """None when the panel now lives in the destination, source -1, destination +1."""
    panel_id = str(panel_id).lower()
    if before.get(panel_id) != source:
        return f"moved panel was in {before.get(panel_id)}, not the source"
    if after.get(panel_id) != destination:
        return f"moved panel is in {after.get(panel_id)}, not the destination"
    def count(tree, ws):
        return sum(1 for w in tree.values() if w == ws)
    if count(after, source) != count(before, source) - 1:
        return f"source panels {count(before, source)} -> {count(after, source)}"
    if count(after, destination) != count(before, destination) + 1:
        return f"destination panels {count(before, destination)} -> {count(after, destination)}"
    return None


def window_frame(windows, ref="window:1"):
    for window in windows:
        if window.get("ref") == ref:
            return window.get("frame")
    return None


def resize_problem(requested, before, after, tolerance=2.0):
    """None when the window now has the requested size and actually changed.
    AppKit may nudge the origin to keep the title bar on screen, so only the
    size must match exactly (within tolerance)."""
    if not after:
        return "no window frame after the resize"
    for key in ("width", "height"):
        if abs(after[key] - requested[key]) > tolerance:
            return f"{key} {after[key]} != requested {requested[key]}"
    wanted_change = before and any(abs(requested[k] - before[k]) > tolerance for k in ("width", "height"))
    if wanted_change and all(abs(after[k] - before[k]) <= tolerance for k in ("x", "y", "width", "height")):
        return "window frame did not change"
    return None


def screen_marks(app, panels, tag):
    """Type a marker into each terminal and read it back from the screen."""
    misses = []
    for ws, panel in panels:
        mark = f"PORTALMARK-{tag}-{panel.split(':')[-1]}"
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded", f"echo {mark}\n", check=False)
    time.sleep(1.0)
    for ws, panel in panels:
        mark = f"PORTALMARK-{tag}-{panel.split(':')[-1]}"
        # Scrollback too: an undersized area shows one row, so the echo scrolls off.
        screen = app.run("read-screen", "--workspace", ws, "--panel", panel, "--lines", "40", check=False)
        if screen.count(mark) < 2:  # the typed command and its output
            misses.append(panel)
    return misses


def portal_shape(args, app, pid, row):
    """Portal churn on the selected workspace: spawn bursts (repro-c11-18),
    splits, closes, moves, workspace switches and window resizes. Every action
    must succeed and land; after each step every terminal the tree shows must
    have a portal entry on its anchor and read back typed text. Exits 1 on any
    failure, after writing the row."""
    bundle = bundle_id(pid)
    set_phase("visible", bundle)
    tree = app.json("tree")
    selected = tree["windows"][0]["selected_workspace_ref"]
    other = app.json("new-workspace", "--title", "portal-other")["workspace_ref"]
    for _ in range(2):
        app.json("new-panel", "--workspace", other)
    shots = os.path.join(args.out, "shots")
    os.makedirs(shots, exist_ok=True)
    steps, failures = [], []

    def selected_terminals():
        data = app.json("--id-format", "both", "tree", "--workspace", selected)
        found = []
        for window in data.get("windows", []):
            for ws in window.get("workspaces", []):
                for area in ws.get("areas", []):
                    for panel in area.get("panels", []):
                        if panel.get("type") == "terminal" and panel.get("selected_in_area"):
                            found.append((selected, panel["ref"], panel.get("id")))
        return found

    def act(name, *argv):
        proc = subprocess.run([app.cli, "--socket", app.socket, *argv], capture_output=True, text=True,
                              env={k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "HC_"))},
                              timeout=60)
        if proc.returncode != 0:
            failures.append({"step": name, "argv": list(argv), "error": (proc.stderr or proc.stdout).strip()[:300]})
        return proc.returncode == 0

    def area_count():
        data = app.json("tree", "--workspace", selected)
        return len(find_key(data, "areas") or [])

    def check(name):
        time.sleep(0.8)
        terminals = selected_terminals()
        checked, problems = portal_problems(app, [t[2] for t in terminals if t[2]])
        user = os.environ.get("USER") or "admin"
        subprocess.run(["sudo", "-n", "/bin/launchctl", "asuser", str(os.getuid()), "/usr/bin/sudo", "-n", "-u", user,
                        "/usr/sbin/screencapture", "-x", os.path.join(shots, f"{len(steps):02d}-{name}.png")],
                       capture_output=True, timeout=30)
        misses = screen_marks(app, [(t[0], t[1]) for t in terminals], f"{len(steps):02d}")
        if not terminals:
            problems.append({"panel": None, "why": ["no_terminals_in_tree"]})
        steps.append({"step": name, "terminals": len(terminals), "checked": checked, "problems": problems,
                      "read_screen_misses": misses})

    # The guest's window starts small; give the splits room.
    act("fill", "window", "move", "--window", "window:1", "--fill")
    time.sleep(0.5)
    first_area = find_key(app.json("tree", "--workspace", selected), "areas")[0]["ref"]
    check("start")
    for i in range(args.portal_iterations):
        for _ in range(3):
            act("spawn-burst", "new-panel", "--workspace", selected, "--area", first_area)
        time.sleep(0.15)
    check("spawn-burst")
    for direction in ("right", "down"):
        before = area_count()
        if not act(f"split-{direction}", "new-area", "--workspace", selected, "--direction", direction):
            failures.pop()  # a split refused for size gets one undersized try
            act(f"split-{direction}", "new-area", "--workspace", selected, "--direction", direction,
                "--allow-undersized")
        time.sleep(0.4)
        if area_count() != before + 1:
            failures.append({"step": f"split-{direction}", "error": f"areas {before} -> {area_count()}"})
        check(f"split-{direction}")
    def full_tree():
        return app.json("--id-format", "both", "tree", "--all")

    tree_now = full_tree()
    source_id, other_id = workspace_id(tree_now, selected), workspace_id(tree_now, other)
    victim = selected_terminals()[0]
    before = panel_membership(tree_now)
    act("close", "close-panel", "--workspace", selected, "--panel", victim[1])
    time.sleep(0.4)
    problem = close_problem(before, panel_membership(full_tree()), victim[2], source_id)
    if problem:
        failures.append({"step": "close", "error": problem})
    check("close")
    mover = selected_terminals()[0]
    before = panel_membership(full_tree())
    act("move-out", "move-panel", "--panel", mover[1], "--workspace", other)
    time.sleep(0.4)
    problem = move_problem(before, panel_membership(full_tree()), mover[2], source_id, other_id)
    if problem:
        failures.append({"step": "move-out", "error": problem})
    check("move-out")
    start_ref = app.json("tree")["windows"][0]["selected_workspace_ref"]
    for direction in ("]", "["):
        # The keystroke goes to the frontmost app: make it c11 (the first
        # screenshot can leave a system privacy prompt in front).
        set_phase("visible", bundle)
        time.sleep(0.3)
        osascript(f'tell application "System Events" to keystroke "{direction}" using {{command down, control down}}')
        time.sleep(0.8)
        now_ref = app.json("tree")["windows"][0]["selected_workspace_ref"]
        if direction == "]" and now_ref == start_ref:
            failures.append({"step": "workspace-switch", "error": "Cmd-Ctrl-] did not switch"})
    if app.json("tree")["windows"][0]["selected_workspace_ref"] != start_ref:
        failures.append({"step": "workspace-switch", "error": "did not return to the start workspace"})
    check("workspace-switch")
    resizes = []
    # Frames inside the guest's limits, so AppKit applies them as given: the
    # main window's minimum frame is about 900x672 (content 900x640 plus the
    # title bar), and the 1440x900 guest display leaves about 791 pt of height.
    for frame in ("0,40,1000,700", "0,40,1300,760", "60,60,1100,720"):
        x, y, w, h = (float(v) for v in frame.split(","))
        requested = {"x": x, "y": y, "width": w, "height": h}
        before = window_frame(app.json("list-windows"))
        act("resize", "window", "move", "--window", "window:1", "--frame", frame)
        time.sleep(0.4)
        after = window_frame(app.json("list-windows"))
        problem = resize_problem(requested, before, after)
        resizes.append({"requested": requested, "before": before, "after": after, "problem": problem})
        if problem:
            failures.append({"step": "resize", "error": problem, "requested": frame})
    row["portal_resizes"] = resizes
    check("resize")
    row["portal_steps"] = steps
    row["portal_action_failures"] = failures
    row["portal_problem_steps"] = [s["step"] for s in steps if s["problems"] or s["read_screen_misses"]]
    row["portal_passed"] = not failures and not row["portal_problem_steps"]
    row["finished"] = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    path = os.path.join(args.out, f"soak-{args.label}.json")
    with open(path, "w") as handle:
        json.dump(row, handle, indent=2)
    print(json.dumps(row, indent=2))
    return 0 if row["portal_passed"] else 1

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli")
    parser.add_argument("--socket")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--label", default="run")
    parser.add_argument("--out", default=".")
    parser.add_argument("--workspaces", type=int, default=8)
    parser.add_argument("--panels", type=int, default=6)
    parser.add_argument("--spinners", type=int, default=3)
    parser.add_argument("--min-shards", type=int, default=4)
    parser.add_argument("--agents", type=int, default=24, help="idle fake agents in other terminals")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--settle", type=int, default=20)
    parser.add_argument("--max-load", type=float, default=10.0)
    parser.add_argument("--quiet-timeout", type=int, default=900)
    parser.add_argument("--hang-log", action="append", default=[])
    parser.add_argument("--stall-proof", type=int, metavar="SECONDS",
                        help="load every core with busy loops for SECONDS (the app was launched with "
                             "C11_FORCE_MAIN_STALL) and report hang.begin and main.stall")
    parser.add_argument("--portal-iterations", type=int, default=20, help="portal: spawn bursts of 3 (repro-c11-18)")
    parser.add_argument("--shape", choices=("spinners", "atin", "portal"), default="spinners",
                        help="atin: Atin's live shape (working hook agents, waiting marks, phases)")
    parser.add_argument("--selected-agents", type=int, default=4, help="atin: working agents in the selected workspace")
    parser.add_argument("--hook-agents", type=int, default=8, help="atin: working agents in all")
    parser.add_argument("--waiting", type=int, default=3, help="atin: panels with an unread notification")
    parser.add_argument("--selected-areas", type=int, default=1, help="atin: areas in the selected workspace")
    parser.add_argument("--waiting-selected", type=int, default=0,
                        help="atin: extra idle agent panels in the selected workspace marked waiting")
    parser.add_argument("--flagged", type=int, default=0, help="atin: working selected agents with a raised flag")
    parser.add_argument("--mark-shots", type=int, default=0, help="atin: screenshots in the visible phase, 0.6 s apart")
    parser.add_argument("--describers", type=int, default=12, help="atin: panels whose description changes per phase")
    parser.add_argument("--tools-per-turn", type=int, default=12)
    parser.add_argument("--tool-seconds", type=float, default=2.0)
    parser.add_argument("--gap-seconds", type=float, default=3.0)
    parser.add_argument("--rest-seconds", type=float, default=20.0)
    parser.add_argument("--phases", default="visible,inactive,hidden")
    parser.add_argument("--churn-log", help="atin: C11_GRAPH_CHURN_LOG of the app, if set")
    parser.add_argument("--memory-minutes", type=int, default=0,
                        help="atin: after the phases, keep the load running and record the footprint")
    parser.add_argument("--parse-sample")
    args = parser.parse_args()

    if args.parse_sample:
        with open(args.parse_sample, errors="replace") as handle:
            print(json.dumps(parse_main_thread(handle.read()), indent=2))
        return 0
    if not args.cli or not args.socket:
        parser.error("--cli and --socket are required")

    os.makedirs(args.out, exist_ok=True)
    HANG_LOGS.extend(args.hang_log)
    if args.stall_proof:
        return stall_proof(args)
    app = App(args.cli, args.socket)
    pid = app_pid(args.pid)
    row = {"label": args.label, "pid": pid, "started": time.strftime("%Y-%m-%d %H:%M:%S %Z")}
    if args.shape == "atin":
        row["shape"] = "atin"
        return atin_shape(args, app, pid, row)
    if args.shape == "portal":
        row["shape"] = "portal"
        return portal_shape(args, app, pid, row)

    # Layout: W workspaces x P terminals.
    panels = []
    for w in range(args.workspaces):
        ws = app.json("new-workspace", "--title", f"soak-{w + 1}")["workspace_ref"]
        for _ in range(args.panels - 1):
            panels.append((ws, app.json("new-panel", "--workspace", ws)["panel_ref"]))
        row.setdefault("workspaces", []).append(ws)
    deadline = time.time() + 180
    shards = None
    while time.time() < deadline:
        shards, error = live_shards(app)
        if shards and shards["live_panels"] >= args.workspaces * args.panels:
            break
        time.sleep(3)
    row["layout"] = shards
    if not shards or len(shards["shards"]) < args.min_shards:
        row["layout_warning"] = f"fewer than {args.min_shards} shards hold live terminals"

    row["load_before_idle"] = wait_quiet(args.max_load, args.quiet_timeout)
    time.sleep(args.settle)
    hang_sizes = hang_logs()
    row["idle"] = measure(pid, args.seconds, args.out, f"{args.label}-idle")

    # Fake agent binaries (copies, so hc reports these names as the foreground).
    bindir = os.path.join(args.out, "bin")
    os.makedirs(bindir, exist_ok=True)
    for name, source in (("grok", "/bin/zsh"), ("claude", "/bin/zsh")):
        target = os.path.join(bindir, name)
        if not os.path.exists(target):
            subprocess.run(["/bin/cp", source, target], check=True)

    # Spinners: one loop per chosen terminal, each started by this harness.
    # One per workspace, so the spinners land on different shards.
    seen, spinner_panels = set(), []
    for ws, panel in panels:
        if ws not in seen and len(spinner_panels) < args.spinners:
            seen.add(ws)
            spinner_panels.append((ws, panel))
    agent_panels = [p for p in panels if p not in spinner_panels][: args.agents]
    for n, (ws, panel) in enumerate(agent_panels + spinner_panels):
        # Agents declare their mailbox, as the c11 skill tells them to.
        app.run("set-metadata", "--workspace", ws, "--panel", panel, "--key", "mailbox.address",
                "--value", f"soak-agent-{n}", "--type", "string", check=False)
        app.run("set-metadata", "--workspace", ws, "--panel", panel, "--key", "mailbox.delivery",
                "--value", "stdin", "--type", "string", check=False)
    for ws, panel in agent_panels:
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded", IDLE_AGENT.format(bin=bindir))
    row["agents"] = len(agent_panels)
    # The idle measurement includes the idle agents: re-measure after they start.
    time.sleep(args.settle)
    row["idle_agents"] = measure(pid, args.seconds, args.out, f"{args.label}-idle-agents")
    for ws, panel in spinner_panels:
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded", SPINNER.format(bin=bindir))
    time.sleep(5)
    intents = {path: os.path.getmtime(path) for path in intents_files()}
    row["load_before_loaded"] = load1()
    row["loaded"] = measure(pid, args.seconds, args.out, f"{args.label}-loaded")
    remaining = max(0, 60 - args.seconds - 5)
    time.sleep(remaining)
    row["intents_mtime_changed"] = {p: os.path.getmtime(p) != t for p, t in intents.items() if os.path.exists(p)}
    row["hang_lines"] = hang_lines_since(hang_sizes)
    for ws, panel in spinner_panels:
        app.run("send-key", "--workspace", ws, "--panel", panel, "ctrl+c", check=False)
    idle_busy = (row["idle_agents"]["sample"] or {}).get("busy_pct")
    loaded_busy = (row["loaded"]["sample"] or {}).get("busy_pct")
    if idle_busy is not None and loaded_busy is not None:
        row["busy_delta_pct_points"] = round(loaded_busy - idle_busy, 1)
    row["finished"] = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    path = os.path.join(args.out, f"soak-{args.label}.json")
    with open(path, "w") as handle:
        json.dump(row, handle, indent=2)
    print(json.dumps(row, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
