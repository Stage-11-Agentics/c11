#!/usr/bin/env python3
"""C11H-255 memory soak: footprint growth of a c11 app under an operator-shaped load.

Runs where the c11 app runs (a build-host sandbox guest). Drives that app through
its own CLI and socket and reads its memory through the kernel's ledgers
(task_name_for_pid + task_info(TASK_VM_INFO)): a read like `top`'s, which never
suspends the app.

  1. fills the display with the window, opens --workspaces workspaces of
     --panels terminals laid out as a split grid (--layout splits, so every
     terminal of a shown workspace draws) or as tabs in one area (--layout
     tabs, only the selected tab draws); every workspace but the selected one
     is hidden. Each terminal first prints a marker and 300 lines, so its
     content and scrollback can be checked across hide and show;
  2. starts the load: spinners rewriting their title at 10 Hz, printers
     writing mixed Unicode and emoji lines (scrollback and glyph cache), idle
     "claude" agents, and from this script set-status, set-metadata and
     mailbox traffic every few seconds;
  3. records one ledger row every --interval seconds for --warmup + --steady
     seconds, and fits the growth rate of the steady part;
  4. --churn N: opens and closes N panels --churn-rounds times and records
     the ledgers, panel count and thread count before and after each round;
  5. --visit (before the warm-up) and --cycle (at the end) show each workspace
     once, as the operator does: the app is activated and Cmd+<n> is typed with
     cliclick in the guest's Aqua session; every switch is checked against
     list-windows. A terminal draws, and so holds GPU memory, only once it has
     been visible.

Stops only the loops it started. Prints one JSON row and writes it and the
rows (TSV) into --out.
"""

import argparse
import ctypes
import json
import os
import subprocess
import sys
import time

GIB = 1024.0 ** 3


# ---- kernel ledgers -------------------------------------------------------

class TaskVMInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in (
        "virtual_size",)] + [("region_count", ctypes.c_int32), ("page_size", ctypes.c_int32)] + [
        (name, ctypes.c_uint64) for name in (
            "resident_size", "resident_size_peak", "device", "device_peak", "internal", "internal_peak",
            "external", "external_peak", "reusable", "reusable_peak", "purgeable_volatile_pmap",
            "purgeable_volatile_resident", "purgeable_volatile_virtual", "compressed", "compressed_peak",
            "compressed_lifetime", "phys_footprint", "min_address", "max_address")] + [
        (name, ctypes.c_int64) for name in (
            "ledger_phys_footprint_peak", "ledger_purgeable_nonvolatile",
            "ledger_purgeable_novolatile_compressed", "ledger_purgeable_volatile",
            "ledger_purgeable_volatile_compressed", "ledger_tag_network_nonvolatile",
            "ledger_tag_network_nonvolatile_compressed", "ledger_tag_network_volatile",
            "ledger_tag_network_volatile_compressed", "ledger_tag_media_footprint",
            "ledger_tag_media_footprint_compressed", "ledger_tag_media_nofootprint",
            "ledger_tag_media_nofootprint_compressed", "ledger_tag_graphics_footprint",
            "ledger_tag_graphics_footprint_compressed", "ledger_tag_graphics_nofootprint",
            "ledger_tag_graphics_nofootprint_compressed", "ledger_tag_neural_footprint",
            "ledger_tag_neural_footprint_compressed", "ledger_tag_neural_nofootprint",
            "ledger_tag_neural_nofootprint_compressed")]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_TASK_VM_INFO = 22


def ledgers(pid):
    """GiB per ledger. heap = internal + compressed; gpu = purgeable + graphics, resident and compressed."""
    port = ctypes.c_uint32()
    me = ctypes.c_uint32.in_dll(_libc, "mach_task_self_")
    if _libc.task_name_for_pid(me, pid, ctypes.byref(port)) != 0:
        raise RuntimeError(f"task_name_for_pid({pid}) failed")
    info = TaskVMInfo()
    count = ctypes.c_uint32(ctypes.sizeof(info) // 4)
    try:
        if _libc.task_info(port, _TASK_VM_INFO, ctypes.byref(info), ctypes.byref(count)) != 0:
            raise RuntimeError("task_info(TASK_VM_INFO) failed")
    finally:
        _libc.mach_port_deallocate(me, port)
    row = {
        "footprint": info.phys_footprint, "peak": info.ledger_phys_footprint_peak,
        "resident": info.resident_size, "internal": info.internal, "compressed": info.compressed,
        "purg": info.ledger_purgeable_nonvolatile, "purg_cmp": info.ledger_purgeable_novolatile_compressed,
        "gfx": info.ledger_tag_graphics_footprint, "gfx_cmp": info.ledger_tag_graphics_footprint_compressed,
    }
    row = {k: round(v / GIB, 4) for k, v in row.items()}
    row["heap"] = round(row["internal"] + row["compressed"], 4)
    row["gpu"] = round(row["purg"] + row["purg_cmp"] + row["gfx"] + row["gfx_cmp"], 4)
    row["regions"] = info.region_count
    return row


def threads(pid):
    out = subprocess.run(["/bin/ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.splitlines()) - 1)


def slope_per_hour(rows, key):
    """Least-squares slope of rows[key] against rows['t'] (seconds), in GiB per hour."""
    if len(rows) < 3:
        return None
    xs = [r["t"] for r in rows]
    ys = [r[key] for r in rows]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    return round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 3600, 4)


# ---- the app --------------------------------------------------------------

class App:
    def __init__(self, cli, socket):
        self.cli, self.socket = cli, socket

    def run(self, *args, check=True, timeout=60):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_", "HC_"))}
        env["LC_ALL"] = env["LANG"] = "en_US.UTF-8"
        proc = subprocess.run([self.cli, "--socket", self.socket, *args], capture_output=True, text=True,
                              env=env, timeout=timeout)
        if check and proc.returncode != 0:
            raise RuntimeError(f"c11 {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc.stdout

    def json(self, *args):
        return json.loads(self.run("--json", *args))


def app_pid(explicit):
    if explicit:
        return explicit
    for pattern in (["-x", "-n", "c11"], ["-f", "-n", "--", r"c11 (DEV|STAGING) .*\.app/Contents/MacOS/"]):
        out = subprocess.run(["/usr/bin/pgrep", *pattern], capture_output=True, text=True).stdout.split()
        if out:
            return int(out[0])
    raise RuntimeError("no running c11 app found; pass --pid")


def aqua(*argv):
    """Run a command in the guest console user's Aqua session (cliclick needs it)."""
    uid, user = str(os.getuid()), os.environ.get("USER") or subprocess.run(
        ["/usr/bin/id", "-un"], capture_output=True, text=True).stdout.strip()
    return subprocess.run(["/usr/bin/sudo", "-n", "/bin/launchctl", "asuser", uid,
                           "/usr/bin/sudo", "-n", "-u", user, *argv], capture_output=True, text=True, timeout=30)


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def workspace_panels(app, ws):
    """Panel refs of one workspace, from tree --all --json."""
    tree = app.json("tree", "--all")
    nodes = [n for n in walk(tree) if n.get("ref") == ws] or \
        [n for n in walk(tree) if n.get("workspace_ref") == ws and not str(n.get("ref", "")).startswith("panel:")]
    for node in nodes:
        if node is not tree:
            refs = []
            for inner in walk(node):
                ref = inner.get("ref") or inner.get("panel_ref")
                if isinstance(ref, str) and ref.startswith("panel:") and ref not in refs:
                    refs.append(ref)
            if refs:
                return refs
    return []


def close_panel_verified(app, ws, ref, settle_s=5.0):
    """Close a panel and confirm it left the workspace's real inventory.

    Returns None when it is gone, else the reason: a refused or failed close, an unreadable
    inventory, or a close that reported success but left the panel in place."""
    try:
        app.run("close-panel", "--panel", ref)
    except Exception as error:  # noqa: BLE001
        return f"close-panel {ref} failed: {error}"
    deadline = time.time() + settle_s
    while True:
        try:
            present = ref in workspace_panels(app, ws)
        except Exception as error:  # noqa: BLE001
            return f"panel inventory of {ws} unreadable after closing {ref}: {error}"
        if not present:
            return None
        if time.time() >= deadline:
            return f"{ref} is still in {ws} {settle_s:.0f} s after close-panel reported success"
        time.sleep(0.5)


def main_latency_samples(app, n=6):
    """Round trips of list-windows, which answers on the main thread: a stall shows as a slow
    reply. Returns (milliseconds, failures); a failed, nonzero or malformed reply is a failure."""
    times, failures = [], []
    for _ in range(n):
        t = time.time()
        try:
            reply = app.json("list-windows")
            if not isinstance(reply, (dict, list)) or not reply:
                raise ValueError(f"malformed reply {str(reply)[:80]!r}")
            times.append(round((time.time() - t) * 1000))
        except Exception as error:  # noqa: BLE001
            times.append(None)
            failures.append(f"list-windows failed after {round((time.time() - t) * 1000)} ms: {error}")
    return times, failures


KEPT_FRAME_REFERENCE_SLACK_MS = 50


def kept_frame_shows(kept):
    """The timed shows of a kept-frame probe, by label: quick-N, long-N and control-7."""
    shows = {}
    for item in (kept or {}).get("quick_switch_back", []):
        shows[f"quick-{item['digit']}"] = item.get("show") or {}
    for item in (kept or {}).get("long_hidden_shows", []):
        shows[f"long-{item['digit']}"] = item.get("show") or {}
    if (kept or {}).get("delayed_frame_control"):
        shows["control-7"] = kept["delayed_frame_control"]
    return shows


def kept_frame_timing_failures(kept, reference=None, slack_ms=KEPT_FRAME_REFERENCE_SLACK_MS):
    """Releasing a kept frame must add no visible delay on show. A show passes when every
    terminal's first new frame is on its layer by the first main-thread turn after the
    selection (when that turn is recorded: the control's stall block), or when its slowest
    first frame is within slack_ms of the same show in a release-disabled reference run.
    Anything else, a missing reference included, is a failure."""
    failures = []
    reference_shows = kept_frame_shows(reference) if reference else {}
    for label, show in kept_frame_shows(kept).items():
        deltas = [v for v in (show.get("show_to_frame_ms") or {}).values() if v is not None]
        if not deltas:
            continue  # a missing frame is already a failure of the run itself
        read = show.get("read") or {}
        selections = read.get("selections") or []
        stall = read.get("stall")
        if stall and len(selections) == 1:
            first_turn = stall["start_ms"] - selections[0]["at_ms"]
            if max(deltas) <= first_turn:
                continue
        ref_deltas = [v for v in ((reference_shows.get(label) or {}).get("show_to_frame_ms") or {}).values()
                      if v is not None]
        if not ref_deltas:
            failures.append(f"{label}: first frame {max(deltas)} ms after selection, with no first main turn "
                            f"recorded and no release-disabled reference to compare against")
        elif max(deltas) > max(ref_deltas) + slack_ms:
            failures.append(f"{label}: first frame {max(deltas)} ms after selection, "
                            f"{round(max(deltas) - max(ref_deltas), 1)} ms later than the release-disabled "
                            f"reference (allowed {slack_ms})")
    return failures


def evaluate_kept_frame(result, reference=None):
    """All kept-frame failures of a recorded run: its own, plus the timing rule above.
    Failures from the superseded 250 ms-from-selection bound are dropped."""
    kept = result.get("kept_frame_probe")
    if not isinstance(kept, dict) or kept.get("failures") is None:
        return ["the kept-frame probe did not run"]
    own = [f for f in kept["failures"] if "(bound 250)" not in f]
    ref_kept = (reference or {}).get("kept_frame_probe") if reference else None
    return own + kept_frame_timing_failures(kept, ref_kept)


def evaluate_main(argv):
    p = argparse.ArgumentParser(prog="c11-memory-soak.py --evaluate",
                                description="Re-evaluate a recorded --kept-frame-probe result; exit 3 on failure")
    p.add_argument("--evaluate", required=True, metavar="RESULT_JSON")
    p.add_argument("--kept-frame-reference", metavar="RESULT_JSON",
                   help="a release-disabled run of the same probe")
    args = p.parse_args(argv)
    with open(args.evaluate) as handle:
        result = json.load(handle)
    reference = None
    if args.kept_frame_reference:
        with open(args.kept_frame_reference) as handle:
            reference = json.load(handle)
    failures = evaluate_kept_frame(result, reference)
    print(json.dumps({"result": args.evaluate, "reference": args.kept_frame_reference,
                      "failures": failures}, indent=2))
    return 3 if failures else 0


def kept_frame_exit_code(args, result):
    """3 when --kept-frame-check is on and the kept-frame probe failed or did not run."""
    if not getattr(args, "kept_frame_check", False):
        return 0
    probe = result.get("kept_frame_probe")
    if not isinstance(probe, dict) or probe.get("failures") is None or probe["failures"]:
        return 3
    return 0


def split_grid(app, ws, first, count):
    """Lay a workspace out as two columns of terminals; returns the panel refs in order."""
    def split(panel, direction):
        before = set(workspace_panels(app, ws))
        app.run("new-split", direction, "--workspace", ws, "--panel", panel, "--allow-undersized")
        new = [p for p in workspace_panels(app, ws) if p not in before]
        return new[0]
    rows = (count + 1) // 2
    cols = [[first], [split(first, "right")]]
    for col in cols:
        while len(col) < rows:
            col.append(split(col[-1], "down"))
    return [cols[c][r] for r in range(rows) for c in (0, 1)][:count]


def marker(panel):
    return f"C11H-MARK {panel}"


# printf keeps the marker out of the typed command line, so only output matches.
MARK = "printf 'C11H-%s %s begin\\n' MARK {panel}; seq 1 300; printf 'C11H-%s %s end\\n' MARK {panel}"


def check_panel(app, ws, panel):
    """Known content and scrollback of one terminal: its marker lines and the 300 lines between."""
    text = app.run("read-screen", "--workspace", ws, "--panel", panel, "--scrollback", check=False)
    lines = [ln.rstrip() for ln in text.splitlines()]
    begin = f"{marker(panel)} begin" in lines
    end = f"{marker(panel)} end" in lines
    seq_ok = False
    if begin and end:
        i = lines.index(f"{marker(panel)} begin")
        j = lines.index(f"{marker(panel)} end")
        # Only the numeric lines: MallocStackLogging writes its own notes in between.
        seq_ok = [ln for ln in lines[i + 1:j] if ln.isdigit()] == [str(n) for n in range(1, 301)]
    tail = [ln for ln in lines if ln.strip()][-1:] or [""]
    return {"panel": panel, "begin": begin, "end": end, "scrollback_300": seq_ok,
            "ok": begin and end and seq_ok, "last_line": tail[0][-120:]}


def check_workspace(app, ws, panels):
    rows = [check_panel(app, ws, p) for p in panels]
    return {"workspace": ws, "ok": all(r["ok"] for r in rows), "panels": rows}


def aqua_popen(*argv):
    """Start a command in the Aqua session without waiting (a screen recording)."""
    uid, user = str(os.getuid()), os.environ.get("USER") or subprocess.run(
        ["/usr/bin/id", "-un"], capture_output=True, text=True).stdout.strip()
    return subprocess.Popen(["/usr/bin/sudo", "-n", "/bin/launchctl", "asuser", uid,
                             "/usr/bin/sudo", "-n", "-u", user, *argv],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


SPINNER = ("{bin}/grok -fc 'stty -icanon -echo; zmodload zsh/zselect; while :; do for c in "
           "⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do "
           "printf \"\\033]0;%s soak working\\007\" $c; zselect -t 10; done; done'")
IDLE_AGENT = "{bin}/claude -fc 'stty -icanon -echo; zmodload zsh/zselect; while :; do zselect -t 100000; done'"
# A printer: agent-like output, one line every 200 ms, mixed scripts and emoji, so
# scrollback fills and the glyph atlases see new glyphs.
PRINTER = ("{bin}/codex -fc 'zmodload zsh/zselect; n=0; g=(✓ ✗ ▶ → ─ │ ┌ "
           "日本語 中文 한국어 Рус \U0001f680 \U0001f9ea \U0001f4e6 "
           "\U0001f525 ✨ ⚠️); while :; do n=$((n+1)); "
           "printf \"%6d %s tool call: Read src/file_%d.swift (%d lines) \\033[3%dm%s\\033[0m\\n\" "
           "$n ${{g[$((n%${{#g}}+1))]}} $((n%977)) $((n*7%3000)) $((n%7+1)) ${{g[$((n*3%${{#g}}+1))]}}; "
           "zselect -t 20; done'")


def app_bundle(pid):
    exe = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return exe.split("/Contents/MacOS/")[0] if "/Contents/MacOS/" in exe else None


def selected_workspace(app):
    try:
        win = app.json("list-windows")
        wins = win.get("windows", win) if isinstance(win, dict) else win
        return wins[0].get("selected_workspace_ref")
    except Exception:  # noqa: BLE001
        return None


def show_workspace(app, pid, digit):
    """Operator path: activate the app, type Cmd+<digit>. Returns the selected workspace ref after."""
    bundle = app_bundle(pid)
    if bundle:
        aqua("/usr/bin/open", "-a", bundle)
        time.sleep(1)
    aqua("/opt/homebrew/bin/cliclick", "ku:cmd", "ku:alt", "ku:shift", "ku:ctrl")
    before = selected_workspace(app)
    aqua("/opt/homebrew/bin/cliclick", "kd:cmd", f"t:{digit}", "ku:cmd")
    time.sleep(1)
    # The selection can land a moment late; wait up to 3 s more for it to move.
    for _ in range(6):
        now = selected_workspace(app)
        if now != before:
            return now
        time.sleep(0.5)
    return selected_workspace(app)


def show_ref(app, pid, ref):
    """Show a given workspace through the Cmd+digit path; Cmd+9 is the last one."""
    for digit in (9, 2, 3, 4, 5, 6, 7, 8, 1):
        if show_workspace(app, pid, digit) == ref:
            return ref
    return None


def ledger_row(pid, app, started, phase):
    row = {"t": round(time.time() - started, 1), "clock": time.strftime("%H:%M:%S"), "phase": phase}
    row.update(ledgers(pid))
    row["threads"] = threads(pid)
    try:
        diag = app.json("hc-diagnostics")
        row["panels"] = sum(1 for p in diag.get("panels", []) if p.get("lifecycle") == "live")
    except Exception:  # noqa: BLE001 - best effort
        row["panels"] = None
    return row


def main():
    if "--evaluate" in sys.argv[1:]:
        return evaluate_main(sys.argv[1:])
    p = argparse.ArgumentParser()
    p.add_argument("--cli", required=True)
    p.add_argument("--socket", required=True)
    p.add_argument("--pid", type=int)
    p.add_argument("--label", default="run")
    p.add_argument("--out", default=".")
    p.add_argument("--workspaces", type=int, default=8)
    p.add_argument("--panels", type=int, default=6)
    p.add_argument("--spinners", type=int, default=12)
    p.add_argument("--printers", type=int, default=6)
    p.add_argument("--agents", type=int, default=12)
    p.add_argument("--warmup", type=int, default=900)
    p.add_argument("--steady", type=int, default=1200)
    p.add_argument("--interval", type=int, default=60)
    p.add_argument("--churn", type=int, default=0, help="panels to open and close per round")
    p.add_argument("--churn-rounds", type=int, default=3)
    p.add_argument("--cycle", action="store_true", help="show each workspace once at the end")
    p.add_argument("--visit", type=float, default=0, metavar="SECONDS",
                   help="before the warm-up, show each workspace for SECONDS, then return to the first")
    p.add_argument("--no-fill", action="store_true")
    p.add_argument("--layout", choices=("splits", "tabs"), default="splits")
    p.add_argument("--kept-frame-probe", action="store_true",
                   help="with --show-probe --layer-probe: a switch back within the kept-frame grace "
                        "(30 s), the footprint once every workspace has been hidden past it, and the "
                        "show of a long-hidden workspace (layer timeline, main-thread latency, hang log)")
    p.add_argument("--kept-frame-check", action="store_true",
                   help="with --kept-frame-probe: enforce release (frames kept within the grace, "
                        "released past it, no first frame later than releasing allows (see "
                        "--kept-frame-reference), the delayed-frame control seen); any failure "
                        "or missing observation exits 3. --evaluate RESULT_JSON re-checks a recorded run")
    p.add_argument("--kept-frame-reference", metavar="RESULT_JSON",
                   help="with --kept-frame-check: a release-disabled run's result; each show's first "
                        "frame must be within 50 ms of it unless it landed by the first main turn")
    p.add_argument("--layer-probe", action="store_true",
                   help="with --show-probe, read each terminal layer's last frame (purgeable state "
                        "and non-zero share) while hidden and right after show (DEBUG builds only)")
    p.add_argument("--show-probe", action="store_true",
                   help="record the screen around Cmd+digit shows of hidden workspaces, "
                        "plain and after a window resize while hidden")
    p.add_argument("--diag", action="store_true",
                   help="save vmmap and footprint region summaries after the visits and at the end")
    args = p.parse_args()

    os.makedirs(args.out, exist_ok=True)
    app = App(args.cli, args.socket)
    pid = app_pid(args.pid)
    started = time.time()
    result = {"label": args.label, "pid": pid, "started": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
              "args": vars(args)}
    rows = []
    tsv = open(os.path.join(args.out, f"memory-{args.label}.tsv"), "w")
    cols = ["clock", "t", "phase", "footprint", "heap", "gpu", "purg", "purg_cmp", "gfx", "gfx_cmp",
            "resident", "internal", "compressed", "regions", "threads", "panels"]
    tsv.write("\t".join(cols) + "\n")

    def record(phase):
        row = ledger_row(pid, app, started, phase)
        rows.append(row)
        tsv.write("\t".join(str(row.get(c)) for c in cols) + "\n")
        tsv.flush()
        return row

    result["at_launch"] = record("launch")
    try:
        result["displays"] = app.json("display", "list")
    except Exception as error:  # noqa: BLE001
        result["displays_error"] = str(error)

    def diag(phase):
        # Guest only: these tools inspect the app, so never run them against an operator's app.
        if not args.diag:
            return
        for tool, argv in (("vmmap", ["/usr/bin/vmmap", "--summary", str(pid)]),
                           ("footprint", ["/usr/bin/footprint", str(pid)])):
            path = os.path.join(args.out, f"memory-{args.label}-{tool}-{phase}.txt")
            try:
                out = subprocess.run(argv, capture_output=True, text=True, timeout=180)
                text = out.stdout + out.stderr
            except Exception as error:  # noqa: BLE001
                text = f"{tool} failed: {error}\n"
            with open(path, "w") as handle:
                handle.write(text)

    if not args.no_fill:
        try:
            win = app.json("list-windows")
            wins = win.get("windows", win) if isinstance(win, dict) else win
            ref = wins[0].get("ref") or wins[0].get("id")
            app.run("window", "move", "--window", ref, "--fill", check=False)
            result["window"] = app.json("list-windows")
        except Exception as error:  # noqa: BLE001
            result["window_error"] = str(error)

    # A clean sidebar, so Cmd+2..9 reach the soak's workspaces: close any
    # workspace left over from the app sandbox-up launched (a "Recovered" one).
    try:
        keep = selected_workspace(app)
        listed = app.json("list-workspaces")
        leftovers = listed.get("workspaces", listed) if isinstance(listed, dict) else listed
        closed = []
        for row in leftovers:
            ref = row.get("ref") or row.get("workspace_ref")
            if keep and ref and ref != keep:
                app.run("close-workspace", "--workspace", ref, check=False)
                closed.append(row.get("title"))
        result["closed_leftovers"] = closed
    except Exception as error:  # noqa: BLE001
        result["closed_leftovers_error"] = str(error)

    # Layout.
    workspaces, panels = [], []
    for w in range(args.workspaces):
        ws = app.json("new-workspace", "--title", f"mem-{w + 1}")["workspace_ref"]
        workspaces.append(ws)
        if args.layout == "tabs":
            for _ in range(args.panels - 1):
                panels.append((ws, app.json("new-panel", "--workspace", ws)["panel_ref"]))
        else:
            first = workspace_panels(app, ws)[0]
            panels.extend((ws, p) for p in split_grid(app, ws, first, args.panels))
    deadline = time.time() + 180
    while time.time() < deadline:
        r = ledger_row(pid, app, started, "layout")
        if r["panels"] and r["panels"] >= args.workspaces * args.panels:
            break
        time.sleep(3)
    result["layout"] = record("layout")

    # Load.
    bindir = os.path.join(args.out, "bin")
    os.makedirs(bindir, exist_ok=True)
    for name in ("grok", "claude", "codex"):
        target = os.path.join(bindir, name)
        if not os.path.exists(target):
            subprocess.run(["/bin/cp", "/bin/zsh", target], check=True)
    by_ws = {}
    for ws, panel in panels:
        by_ws.setdefault(ws, []).append(panel)
    for ws, panel in panels:
        app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded",
                MARK.format(panel=panel), check=False)
    time.sleep(5)
    result["layout_panels"] = by_ws
    order = []  # round-robin over workspaces so each kind spreads over shards and hidden/visible
    for i in range(max(len(v) for v in by_ws.values())):
        for ws in workspaces:
            if i < len(by_ws.get(ws, [])):
                order.append((ws, by_ws[ws][i]))
    spinners = order[: args.spinners]
    printers = order[args.spinners: args.spinners + args.printers]
    agents = order[args.spinners + args.printers: args.spinners + args.printers + args.agents]
    for n, (ws, panel) in enumerate(spinners + printers + agents):
        app.run("set-metadata", "--workspace", ws, "--panel", panel, "--key", "mailbox.address",
                "--value", f"mem-agent-{n}", "--type", "string", check=False)
    for group, template in ((agents, IDLE_AGENT), (spinners, SPINNER), (printers, PRINTER)):
        for ws, panel in group:
            app.run("send", "--workspace", ws, "--panel", panel, "--allow-unguarded",
                    template.format(bin=bindir), check=False)
    result["load"] = {"spinners": len(spinners), "printers": len(printers), "agents": len(agents)}

    def telemetry(tick):
        # What agents do through the socket: status, metadata, mail.
        ws, panel = order[tick % len(order)]
        app.run("set-status", "--workspace", ws, "soak", f"tick {tick}", check=False)
        app.run("set-metadata", "--workspace", ws, "--panel", panel, "--key", "soak.tick",
                "--value", str(tick), "--type", "string", check=False)
        if tick % 2 == 0 and len(order) > 1:
            app.run("mailbox", "send", "--to", f"mem-agent-{(tick + 1) % len(order)}",
                    f"soak mail {tick}", check=False)

    # Visit: each workspace becomes visible once, as the operator's do.
    if args.visit:
        time.sleep(20)  # let the printers fill their screens first
        seen = []
        shown_checks = []
        for digit in range(2, min(9, len(workspaces) + 1) + 1):
            ref = show_workspace(app, pid, digit)
            time.sleep(args.visit)
            seen.append(ref)
            record(f"visit-{digit}")
            if ref in by_ws:
                shown_checks.append(check_workspace(app, ref, by_ws[ref]))
        seen.append(show_workspace(app, pid, 1))
        time.sleep(5)
        result["visit"] = {"selected": seen, "after": record("visit-done"), "checks": shown_checks}
        diag("visit-done")

    # Warm-up and steady phases.
    tick = 0
    next_row = time.time()
    end_warm = time.time() + args.warmup
    end_steady = end_warm + args.steady
    while time.time() < end_steady:
        telemetry(tick)
        tick += 1
        if time.time() >= next_row:
            record("warmup" if time.time() < end_warm else "steady")
            next_row += args.interval
        time.sleep(3)
    steady = [r for r in rows if r["phase"] == "steady"]
    result["steady"] = {
        "rows": len(steady),
        "first": steady[0] if steady else None,
        "last": steady[-1] if steady else None,
        "slope_gib_per_hour": {k: slope_per_hour(steady, k) for k in
                               ("footprint", "heap", "gpu", "purg", "gfx", "resident")},
        "threads_first_last": [steady[0]["threads"], steady[-1]["threads"]] if steady else None,
    }

    # Churn (scenario 2): per round, open N terminals in a fresh workspace, show
    # it (so every terminal draws and allocates), fill the screens, then end
    # half by `exit` and close the rest, return to the first workspace and
    # compare the ledgers, thread count (three per terminal: renderer, io,
    # cf_release) and live panel count with the level before the round.
    if args.churn:
        rounds = []
        for k in range(args.churn_rounds):
            before = record(f"churn{k}-before")
            ws = app.json("new-workspace", "--title", f"churn-{k}")["workspace_ref"]
            opened = [app.json("new-panel", "--workspace", ws)["panel_ref"] for _ in range(args.churn - 1)]
            shown = show_ref(app, pid, ws)
            for ref in opened:
                app.run("send", "--workspace", ws, "--panel", ref, "--allow-unguarded",
                        MARK.format(panel=ref) + "; " + PRINTER.format(bin=bindir), check=False)
            # Every churn terminal is a tab: select each in turn so each draws
            # (and allocates its swap chain) before it is closed.
            drawn = []
            for ref in opened:
                app.run("focus-panel", "--workspace", ws, "--panel", ref, check=False)
                time.sleep(1.5)
                drawn.append(check_panel(app, ws, ref))
            time.sleep(5)
            mid = record(f"churn{k}-open")
            for i, ref in enumerate(opened):
                if i % 2 == 0:
                    app.run("send-key", "--workspace", ws, "--panel", ref, "ctrl+c", check=False)
                    app.run("send", "--workspace", ws, "--panel", ref, "--allow-unguarded", "exit", check=False)
                else:
                    app.run("close-panel", "--panel", ref, check=False)
            time.sleep(5)
            show_workspace(app, pid, 1)
            app.run("close-workspace", "--workspace", ws, check=False)
            time.sleep(30)
            after = record(f"churn{k}-closed")
            rounds.append({"shown": shown == ws, "drawn": drawn,
                           "drawn_ok": all(d["ok"] for d in drawn), "before": before, "open": mid, "closed": after,
                           "opened_gib": round(mid["footprint"] - before["footprint"], 4),
                           "retained_gib": round(after["footprint"] - before["footprint"], 4),
                           "retained_gpu_gib": round(after["gpu"] - before["gpu"], 4),
                           "retained_threads": after["threads"] - before["threads"],
                           "retained_panels": (after["panels"] or 0) - (before["panels"] or 0)})
        result["churn"] = rounds

    # Cycle: show each workspace once (operator shortcut in the guest), then come back.
    if args.cycle:
        cyc = [record("cycle-before")]
        selected = []
        shots = []
        visit_map = dict(zip(range(2, 10), result.get("visit", {}).get("selected", [])))
        cycle_checks = []
        for digit in range(2, min(9, len(workspaces) + 1) + 1):
            expect = visit_map.get(digit)
            hidden = check_workspace(app, expect, by_ws[expect]) if expect in by_ws else None
            ref = show_workspace(app, pid, digit)
            shown = check_workspace(app, ref, by_ws[ref]) if ref in by_ws else None
            cycle_checks.append({"digit": digit, "workspace": ref, "while_hidden": hidden, "after_show": shown})
            selected.append(ref)
            time.sleep(3)
            cyc.append(record(f"cycle-{digit}"))
            # Scenario 3: what the operator sees on show, against the terminal's own text.
            shot = os.path.join(args.out, f"memory-{args.label}-cycle-{digit}.png")
            aqua("/usr/sbin/screencapture", "-x", shot)
            texts = {}
            for panel in by_ws.get(ref, [])[:6]:
                texts[panel] = app.run("read-screen", "--workspace", ref, "--panel", panel, check=False)[-400:]
            shots.append({"digit": digit, "workspace": ref, "screenshot": shot, "screens": texts})
        result["cycle_screens"] = shots
        result["cycle_checks"] = cycle_checks
        selected.append(show_workspace(app, pid, 1))
        time.sleep(10)
        cyc.append(record("cycle-after"))
        result["cycle"] = {"rows": cyc, "selected": selected}

    # Scenario 3, at show time: a hidden terminal released its GPU memory, so
    # the frame on screen when it is shown again must be its last frame, not
    # an emptied one, until the redraw lands. --layer-probe reads each
    # terminal layer's IOSurface (its last frame) while hidden and right after
    # Cmd+digit; a screen recording spans each show for a reviewer to watch
    # (video alone can't tell a kept frame from a redraw that already landed).
    if args.show_probe:
        bundle = app_bundle(pid)
        win = app.json("list-windows")
        wins = win.get("windows", win) if isinstance(win, dict) else win
        window_ref = wins[0].get("ref") or wins[0].get("id")
        probes = []

        visit_map = dict(zip(range(2, 10), result.get("visit", {}).get("selected", [])))

        def layers(ws):
            if not args.layer_probe or ws not in by_ws:
                return None
            out = {}
            for panel in by_ws[ws]:
                try:
                    reply = json.loads(app.run("rpc", "debug.terminal.layer_probe",
                                               json.dumps({"surface_id": panel}), check=False) or "{}")
                    out[panel] = reply.get("result", reply)
                except Exception as error:  # noqa: BLE001
                    out[panel] = {"error": str(error)}
            return out

        def probe(name, digit):
            movie = os.path.join(args.out, f"memory-{args.label}-show-{name}.mov")
            expect = visit_map.get(digit)
            before_show = layers(expect)
            if bundle:
                aqua("/usr/bin/open", "-a", bundle)
                time.sleep(1)
            aqua("/opt/homebrew/bin/cliclick", "ku:cmd", "ku:alt", "ku:shift", "ku:ctrl")
            rec = aqua_popen("/usr/sbin/screencapture", "-v", "-V", "4", "-x", movie)
            time.sleep(1.5)
            aqua("/opt/homebrew/bin/cliclick", "kd:cmd", f"t:{digit}", "ku:cmd")
            at_show = layers(expect)
            try:
                rec.wait(timeout=30)
            except subprocess.TimeoutExpired:
                rec.kill()
            ref = selected_workspace(app)
            check = check_workspace(app, ref, by_ws[ref]) if ref in by_ws else None
            frame = None
            try:
                w = app.json("list-windows")
                w = w.get("windows", w) if isinstance(w, dict) else w
                frame = w[0].get("frame")
            except Exception:  # noqa: BLE001
                pass
            probes.append({"name": name, "digit": digit, "movie": movie, "expected": expect,
                           "layers_while_hidden": before_show, "layers_at_show": at_show,
                           "recorded": os.path.exists(movie), "selected": ref, "window_frame": frame,
                           "panels": len(by_ws.get(ref, [])), "layout": args.layout, "check": check,
                           "recorder_error": (rec.stderr.read() if rec.stderr else "")[-300:]})

        for digit in (2, 3, 4, 5):
            probe(f"plain-{digit}", digit)
        # Resize while hidden: shrink the window with workspace 6 hidden, then
        # show it; move the window with workspace 7 hidden, then show it; grow
        # it back with workspace 8 hidden, then show that.
        app.run("window", "move", "--window", window_ref, "--frame", "0,30,1100,650", check=False)
        time.sleep(3)
        probe("smaller-6", 6)
        app.run("window", "move", "--window", window_ref, "--frame", "300,120,1100,650", check=False)
        time.sleep(3)
        probe("moved-7", 7)
        app.run("window", "move", "--window", window_ref, "--fill", check=False)
        time.sleep(3)
        probe("larger-8", 8)
        show_workspace(app, pid, 1)
        result["show_probe"] = probes

        if args.kept_frame_probe and args.layer_probe:
            # C11H-255: a hidden terminal keeps its last frame for 30 s, then releases it.
            # With --kept-frame-check every expectation below must hold, and any observation
            # that fails or is missing counts as a failure (the run exits 3). Without it the
            # same readings are only recorded (a baseline app may keep its frames).
            grace_s = 30
            enforce = args.kept_frame_check
            kept = {"failures": [], "enforced": enforce}

            def fail(message):
                kept["failures"].append(message)

            def surfaces(layer_map):
                # A panel whose probe failed maps to None, never to "no surfaces".
                out = {}
                for p, v in (layer_map or {}).items():
                    if not isinstance(v, dict) or "error" in v or not isinstance(v.get("surfaces"), list):
                        out[p] = None
                        continue
                    # The socket's JSON names the IOSurface id panel_id (its surface -> panel rename).
                    out[p] = [(s.get("state"), s.get("surface_id", s.get("panel_id")),
                               round(s.get("non_zero_fraction", 0), 3))
                              for s in v["surfaces"]]
                return out

            def drawn(layer):
                return [s for s in (layer or []) if s[0] == "non_volatile" and s[2] > 0.1]

            def keystroke(digit):
                if bundle:
                    aqua("/usr/bin/open", "-a", bundle)
                    time.sleep(1)
                aqua("/opt/homebrew/bin/cliclick", "ku:cmd", "ku:alt", "ku:shift", "ku:ctrl")
                aqua("/opt/homebrew/bin/cliclick", "kd:cmd", f"t:{digit}", "ku:cmd")

            def rpc(method, params):
                try:
                    reply = json.loads(app.run("rpc", method, json.dumps(params), check=False) or "{}")
                except Exception as error:  # noqa: BLE001
                    return None, str(error)
                if not isinstance(reply, dict) or "error" in reply:
                    return None, json.dumps(reply)[:300]
                return reply.get("result", reply), None

            def main_latency(label, n=6):
                times, failures = main_latency_samples(app, n)
                for failure in failures:
                    fail(f"{label}: {failure}")
                return times

            def hidden_layers(label, ws, expect):
                # expect: "kept" (every panel shows a drawn, non-volatile frame) or "released"
                # (every panel's probe answers with no surface). Returns {panel: [surface ids]}.
                layer_map = surfaces(layers(ws))
                ids = {}
                for panel in by_ws.get(ws, []):
                    layer = layer_map.get(panel)
                    if layer is None:
                        fail(f"{label}: no layer reading for {panel}")
                        continue
                    ids[panel] = [s[1] for s in layer]
                    if expect == "kept" and not drawn(layer):
                        fail(f"{label}: {panel} holds no kept frame ({layer})")
                    if expect == "released" and layer:
                        fail(f"{label}: {panel} still holds {layer} past the {grace_s} s grace")
                return {"expect": expect, "layers": layer_map, "ids": ids}

            def timed_show(label, digit, ws, stall_ms=0):
                # The app times the selection and each terminal's first new frame on its own
                # clock (debug.terminal.frame_watch), so input delivery into the guest adds nothing.
                panels = by_ws.get(ws, [])
                armed, error = rpc("debug.terminal.frame_watch",
                                   {"surface_ids": panels, "stall_after_select_ms": stall_ms, "timeout_ms": 15000})
                if error:
                    fail(f"{label}: frame_watch unavailable: {error}")
                    return {"error": error}
                keystroke(digit)
                deadline = time.time() + 15
                read = None
                while time.time() < deadline:
                    read, error = rpc("debug.terminal.frame_watch_read", {})
                    if error:
                        fail(f"{label}: frame_watch_read failed: {error}")
                        return {"armed": armed, "error": error}
                    if not read.get("running"):
                        break
                    time.sleep(0.25)
                shown_ref = selected_workspace(app)
                selections = read.get("selections") or []
                out = {"armed": armed, "read": read, "selected_after": shown_ref, "show_to_frame_ms": {}}
                if shown_ref != ws:
                    fail(f"{label}: Cmd+{digit} selected {shown_ref}, expected {ws}")
                if len(selections) != 1:
                    fail(f"{label}: expected one selection after arming, saw {len(selections)}")
                    return out
                selected_at = selections[0]["at_ms"]
                for panel in panels:
                    item = (read.get("panels") or {}).get(panel)
                    if not item or item.get("new_frame_ms") is None:
                        fail(f"{label}: {panel} showed no new frame within 15 s")
                        out["show_to_frame_ms"][panel] = None
                        continue
                    delta = round(item["new_frame_ms"] - selected_at, 1)
                    out["show_to_frame_ms"][panel] = delta
                    if delta < 0:
                        fail(f"{label}: {panel} had a new frame {-delta} ms before its selection")
                return out

            # Every workspace this probe uses must exist.
            needed = {d: visit_map.get(d) for d in (2, 3, 4, 5, 6, 7)}
            missing = [d for d, ws in needed.items() if ws not in by_ws]
            if missing:
                fail(f"workspaces for digits {missing} are missing")
            ws2, ws3, ws4, ws5, ws6, ws7 = (needed[d] for d in (2, 3, 4, 5, 6, 7))

            if not missing:
                # Hide 2 and 3 together at t0; 6 too, with a panel closed while its timer is pending.
                show_workspace(app, pid, 3)
                show_workspace(app, pid, 2)
                show_workspace(app, pid, 6)
                show_workspace(app, pid, 1)
                t0 = time.time()
                closing = by_ws[ws6][-1]
                close_error = close_panel_verified(app, ws6, closing)
                if close_error:
                    fail(f"close with the release timer pending: {close_error}")
                else:
                    by_ws[ws6] = by_ws[ws6][:-1]
                kept["closed_with_timer_pending"] = {"panel": closing, "error": close_error}

                # B: switch back within the grace. The kept frame is what the layer shows from the
                # selection until the redraw replaces it: never cleared, never empty.
                quick = []
                for digit, ws, at in ((3, ws3, 5), (2, ws2, 18)):
                    time.sleep(max(0, t0 + at - time.time()))
                    label = f"quick-{digit}"
                    hidden = hidden_layers(f"{label} hidden {at} s", ws, "kept")
                    shown = timed_show(label, digit, ws)
                    for panel, item in ((shown.get("read") or {}).get("panels") or {}).items():
                        if not item.get("baseline"):
                            fail(f"{label}: {panel} had no frame on its layer at the show")
                        elif item.get("cleared_ms") is not None:
                            fail(f"{label}: {panel}'s kept frame was cleared at {item['cleared_ms']} ms")
                    check = check_workspace(app, ws, by_ws[ws])
                    if not check["ok"]:
                        fail(f"{label}: content check failed")
                    quick.append({"digit": digit, "workspace": ws, "hidden": hidden, "show": shown, "check": check})
                    show_workspace(app, pid, 1)
                    kept[f"rehidden_{digit}"] = time.time() - t0
                kept["quick_switch_back"] = quick
                t2 = t0 + kept["rehidden_2"]

                # Renewed interval: 2 was hidden again at t2, so 20 s later it still keeps its
                # frame; 40 s after it has released it, as have 3 (hidden again before 2) and the
                # long-hidden 4, 5, 6 (one panel closed with its timer pending) and 7.
                time.sleep(max(0, t2 + 20 - time.time()))
                kept["renewed_2_at_20s"] = hidden_layers("renewed 2 at 20 s", ws2, "kept")
                time.sleep(max(0, t2 + grace_s + 10 - time.time()))
                kept["released_2"] = hidden_layers("2 rehidden past the grace", ws2, "released")
                for digit, ws in ((3, ws3), (4, ws4), (5, ws5), (6, ws6), (7, ws7)):
                    kept[f"released_{digit}"] = hidden_layers(f"{digit} hidden past the grace", ws, "released")
                kept["all_hidden_past_grace"] = record("all-hidden-past-grace")
                try:
                    os.kill(pid, 0)
                    kept["alive_after_close_with_timer_pending"] = True
                except OSError:
                    kept["alive_after_close_with_timer_pending"] = False
                    fail("app died after a panel closed with its release timer pending")

                # A: show long-hidden workspaces: time to every terminal's first frame, with no stall.
                hang_path = os.path.join(args.out, "hang.log")
                if not os.path.exists(hang_path):
                    fail(f"hang log {hang_path} is missing")
                hang_before = os.path.getsize(hang_path) if os.path.exists(hang_path) else 0
                long_shows = []
                for digit, ws in ((4, ws4), (5, ws5)):
                    label = f"long-{digit}"
                    shown = timed_show(label, digit, ws)
                    latency = main_latency(label)
                    time.sleep(1)
                    after = surfaces(layers(ws))
                    for panel in by_ws[ws]:
                        if not drawn(after.get(panel)):
                            fail(f"{label}: {panel} shows no drawn frame after the show ({after.get(panel)})")
                    check = check_workspace(app, ws, by_ws[ws])
                    if not check["ok"]:
                        fail(f"{label}: content check failed")
                    long_shows.append({"digit": digit, "workspace": ws, "show": shown, "main_latency_ms": latency,
                                       "layers_after": after, "check": check})
                    show_workspace(app, pid, 1)
                hang_after = os.path.getsize(hang_path) if os.path.exists(hang_path) else 0
                new_hang = ""
                if hang_after > hang_before:
                    with open(hang_path, errors="replace") as handle:
                        handle.seek(hang_before)
                        new_hang = handle.read()[-2000:]
                    fail("hang log grew during the long-hidden shows")
                kept["long_hidden_shows"] = long_shows
                kept["hang_log_new"] = new_hang

                # Control: the same show with the main thread held 400 ms right after the selection.
                # Every frame must then measure at least 400 ms, or the timing cannot see a delay.
                control = timed_show("control-7", 7, ws7, stall_ms=400)
                stall = (control.get("read") or {}).get("stall")
                if not stall:
                    fail("control-7: the stall did not run")
                for panel, delta in control.get("show_to_frame_ms", {}).items():
                    if delta is not None and delta < 400:
                        fail(f"control-7: {panel} measured {delta} ms under a 400 ms stall")
                kept["delayed_frame_control"] = control
                show_workspace(app, pid, 1)
            kept["main_latency_idle_ms"] = main_latency("idle")
            reference = None
            if args.kept_frame_reference:
                try:
                    with open(args.kept_frame_reference) as handle:
                        reference = json.load(handle).get("kept_frame_probe")
                except (OSError, ValueError) as error:
                    fail(f"kept-frame reference unreadable: {error}")
            for failure in kept_frame_timing_failures(kept, reference):
                fail(failure)
            result["kept_frame_probe"] = kept
            if kept["failures"]:
                print("kept-frame failures:\n  " + "\n  ".join(kept["failures"]), file=sys.stderr)
            show_workspace(app, pid, 1)

    for ws, panel in spinners + printers:
        app.run("send-key", "--workspace", ws, "--panel", panel, "ctrl+c", check=False)
    result["final"] = record("final")
    diag("final")
    result["finished"] = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    tsv.close()
    with open(os.path.join(args.out, f"memory-{args.label}.json"), "w") as handle:
        json.dump(result, handle, indent=2)
    print(json.dumps({k: result[k] for k in ("label", "layout", "steady", "final") if k in result}, indent=2))
    return kept_frame_exit_code(args, result)


if __name__ == "__main__":
    sys.exit(main())
