#!/usr/bin/env python3
"""Host-end restore e2e driver (C11H-196). Runs inside a sandbox guest's Aqua
session through run.sh; state lives in /tmp/c11h196/ in the guest.

A host end is what a reboot does to c11: the app quits cleanly, then every hc
core and holder of the build's sessions dies, taking the agents with them. The
next launch (C11_QA_LAUNCH=resume) must resume every agent conversation once,
in its own cwd, hidden workspaces included, without the operator looking.

Phases (each takes key=value options; `all` runs them in order):
  prepare  app=<.app> socket=<sock> [log=<debug log>] [dsock=<daemon sock>] [n=8]
           quit the app sandbox-up launched, end its hc, wipe this build's
           state, install the stub `claude`, turn shards on, launch fresh
  setup    n agent panels (2 in the selected workspace, the rest spread over
           hidden workspaces), each running the stub; transcripts and causal
           refs without cwd (what the SessionStart bridge leaves)
  quit     TERM, the app's clean quit; the clean sentinel must appear
  hostend  SIGKILL this build's hc cores, then within 3 s its holders, then
           any agent or shell that outlived them
  scrub    delete cwd from every saved conversation ref (persisted-state replay)
  relaunch start the app with C11_QA_LAUNCH=resume, select nothing
  collect  [t=120 quiet=20 cpu=30] watch the ledger, then assert and print
           the summary between C11H196-SUMMARY markers
  again    [t2=45] (C11H-209; `all` runs it with again=1) quit cleanly and
           relaunch with resume on: an end the previous launch found and left
           (noresume=1) or decided (hidetranscripts=1: transcripts held away
           for the first relaunch, back for the second) is never resumed
           unasked. Adds (k) and (l) and prints the summary again; run.sh
           reads the last one
  lifecycle (mode=lifecycle, C11H-322/323; `all` only) survivors across a clean
           relaunch (ended while down, mid-turn, rested, a hookless opencode) read
           hc's word, never their saved working; then a host end: every resumed
           stub's SessionStart (the real `claude-hook`) rests its journal live at
           once and an expired cache draws cold
  seed     (mode=marks, C11H-321) prompt caches on the stubs' transcripts and a
           hidden opencode panel saved as working; persisted reads its saved
           activity after the quit; marks watches `c11 fleet` and asserts
"""
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

STATE = "/tmp/c11h196"
LEDGER = "/tmp/c11h196-ledger.jsonl"
STUB_PATH = "/usr/local/bin/claude"
HOME = os.path.expanduser("~")
WORK = os.path.join(HOME, "c11h196")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# The stub agent. The bundled wrapper (Resources/bin/claude) execs the next
# `claude` on PATH, adding --settings, the c11 note and, for a fresh start,
# --session-id. One start line per process, one line per stdin line.
STUB = r'''#!/usr/bin/python3 -u
# c11h196 stub claude (scripts/sandbox-host-end-e2e)
import json, os, sys, time
LEDGER = "/tmp/c11h196-ledger.jsonl"
def log(rec):
    rec["ts"] = time.time()
    rec["pid"] = os.getpid()
    rec["panel"] = os.environ.get("C11_PANEL_ID") or os.environ.get("CMUX_SURFACE_ID")
    fd = os.open(LEDGER, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
    try:
        os.write(fd, (json.dumps(rec) + "\n").encode())
    finally:
        os.close(fd)
try:
    cwd = os.getcwd()
except OSError:
    cwd = None
log({"event": "start", "argv": sys.argv[1:], "cwd": cwd, "pwd": os.environ.get("PWD"),
     "ppid": os.getppid(), "hc_session": os.environ.get("HC_SESSION"),
     "hc_terminal": os.environ.get("HC_TERMINAL_ID")})
resume = [sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == "--resume"]
print("C11H196-STUB-CLAUDE", "resume=" + (resume[0] if resume else "-"), "cwd=" + str(cwd), flush=True)
# C11H-321 (mode=marks): a panel listed here reports idle at start, as Claude's SessionStart hook does
# for a resumed session; the others report nothing, as when that hook never lands.
try:
    with open("/tmp/c11h321-start-idle") as f:
        start_idle = (os.environ.get("C11_PANEL_ID") or "").upper() in f.read().split()
except OSError:
    start_idle = False
if start_idle:
    import subprocess
    r = subprocess.run([os.environ.get("C11_BUNDLED_CLI_PATH") or "c11", "agent-hook", "idle"],
                       capture_output=True, text=True, timeout=20)
    log({"event": "agent-hook", "state": "idle", "at_start": True, "rc": r.returncode,
         "out": (r.stdout + r.stderr)[-300:]})
# C11H-322 (mode=lifecycle): Claude's own hooks through c11's real `claude-hook`, and hc's OSC 7501 status,
# as a real Claude reports both. The session id is the wrapper's --session-id, or --resume's.
HOOKS = os.path.exists("/tmp/c11h322-hooks")
sid = (resume[0] if resume else None) or next(
    (sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == "--session-id"), None)
def osc(state):
    sys.stdout.write("\x1b]7501;state=%s:app=claude-code\x1b\\" % state)
    sys.stdout.flush()
    log({"event": "osc", "state": state})
def hook(sub, extra=None):
    import subprocess
    payload = {"session_id": sid, "cwd": cwd}
    payload.update(extra or {})
    r = subprocess.run([os.environ.get("C11_BUNDLED_CLI_PATH") or "c11", "claude-hook", sub],
                       input=json.dumps(payload), capture_output=True, text=True, timeout=30)
    log({"event": "claude-hook", "sub": sub, "rc": r.returncode, "extra": extra or {},
         "interactive_pid": os.environ.get("C11_AGENT_INTERACTIVE_PID"), "out": (r.stdout + r.stderr)[-300:]})
def end_when_down():
    while not os.path.exists("/tmp/c11h322-down"):
        time.sleep(0.2)
    osc("done")
    hook("stop")
if HOOKS and sid:
    hook("session-start", {"source": "resume" if resume else "startup", "hook_event_name": "SessionStart"})
    osc("idle")
while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    text = line.decode("utf-8", "replace").rstrip("\n")
    log({"event": "stdin", "stdin": text})
    if HOOKS and text == "C11H322-WORK":
        osc("working")
        hook("prompt-submit", {"hook_event_name": "UserPromptSubmit"})
    elif HOOKS and text == "C11H322-DONE":
        osc("done")
        hook("stop", {"hook_event_name": "Stop"})
    elif HOOKS and text == "C11H322-DONE-WHEN-DOWN":
        import threading
        threading.Thread(target=end_when_down, daemon=True).start()
    # C11H-321 (mode=marks): report a turn the way a harness wrapper does, from this panel.
    if text in ("C11H321-WORK", "C11H321-IDLE"):
        import subprocess
        cli = os.environ.get("C11_BUNDLED_CLI_PATH") or "c11"
        state = "working" if text.endswith("WORK") else "idle"
        r = subprocess.run([cli, "agent-hook", state], capture_output=True, text=True, timeout=20)
        log({"event": "agent-hook", "state": state, "rc": r.returncode, "out": (r.stdout + r.stderr)[-300:]})
'''


# ---------------------------------------------------------------- helpers

def now():
    return time.time()


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).astimezone().isoformat(timespec="milliseconds") if ts else None


def sh(*args, check=True, timeout=60, env=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        if check:
            raise SystemExit(f"command timed out after {timeout}s: {args}")
        return ""
    if check and r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {args}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def opts_of(argv):
    return dict(a.split("=", 1) for a in argv if "=" in a)


def load(name, default=None):
    path = os.path.join(STATE, name)
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def save(name, obj):
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, os.path.join(STATE, name))


def c11(meta, *args, check=True, timeout=30):
    return sh(meta["cli"], "--socket", meta["socket"], *args, check=check, timeout=timeout)


def c11_json(meta, *args, check=True, timeout=30):
    out = c11(meta, "--json", "--id-format", "both", *args, check=check, timeout=timeout)
    try:
        return json.loads(out)
    except ValueError:
        if check:
            raise SystemExit(f"non-JSON from c11 {args}: {out[:400]}")
        return None


def hc_diag(meta, check=False):
    out = c11(meta, "hc-diagnostics", "--json", check=check, timeout=20)
    try:
        return json.loads(out)
    except ValueError:
        return None


def find_uuid(obj, keys=("panel_id", "surface_id", "id", "workspace_id")):
    if isinstance(obj, dict):
        for k in keys:
            v = obj.get(k)
            if isinstance(v, str) and UUID_RE.match(v):
                return v
        for v in obj.values():
            u = find_uuid(v, keys)
            if u:
                return u
    if isinstance(obj, list):
        for v in obj:
            u = find_uuid(v, keys)
            if u:
                return u
    return None


def slug(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def bundle_id(app):
    import plistlib
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def safe_bundle(bid):
    return re.sub(r"[^A-Za-z0-9._-]", "_", bid)


def app_binary(meta):
    return os.path.join(meta["app"], "Contents", "MacOS", "c11")


def ps_rows(with_env=False):
    flags = "-axwwE" if with_env else "-axww"
    out = sh("/bin/ps", flags, "-o", "pid=,command=", check=False)
    rows = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)$", line)
        if m:
            rows.append((int(m.group(1)), m.group(2)))
    return rows


def app_pids(meta):
    binary = app_binary(meta)
    return [pid for pid, cmd in ps_rows() if cmd == binary or cmd.startswith(binary + " ")]


def alive(pid):
    # The app this driver launched is its own child: reap it, or an exited app
    # stays a zombie that kill(pid, 0) still reports.
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False
    except ChildProcessError:
        pass
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill9(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            sh("/usr/bin/sudo", "-n", "/bin/kill", "-9", str(pid), check=False)


def session_re(meta):
    return re.escape(meta["hc_session"]) + r"(?:-s[0-9]+)?"


def hc_cores(meta):
    """This build's hc cores: `<helper> serve` with HC_RUNTIME=1 and one of
    its sessions in HC_SESSION (ps -E shows a same-uid process's env)."""
    want = re.compile(r"(?:^|\s)HC_SESSION=(" + session_re(meta) + r")(?:\s|$)")
    found = []
    for pid, cmd in ps_rows(with_env=True):
        if not re.search(r"\sserve(?:\s|$)", cmd) or "HC_RUNTIME=1" not in cmd:
            continue
        m = want.search(cmd)
        if m:
            found.append({"pid": pid, "session": m.group(1)})
    return found


def hc_holders(meta):
    want = re.compile(r"\shold\s+--socket\s+\S*/\.local/share/c11/run/(" + session_re(meta) + r")\.holder\.")
    found = []
    for pid, cmd in ps_rows():
        m = want.search(cmd)
        if m:
            found.append({"pid": pid, "session": m.group(1)})
    return found


def session_processes(meta):
    """Anything still carrying one of this build's sessions in its env that is
    not a core or holder: shells and agents in hc terminals."""
    want = re.compile(r"(?:^|\s)(?:C11_)?HC_SESSION=(" + session_re(meta) + r")(?:\s|$)")
    core_pids = {c["pid"] for c in hc_cores(meta)} | {h["pid"] for h in hc_holders(meta)}
    me = os.getpid()
    return [{"pid": pid, "cmd": cmd.split(" HC_")[0][:160]}
            for pid, cmd in ps_rows(with_env=True)
            if pid not in core_pids and pid != me and want.search(cmd)]


def log_sizes():
    sizes = {}
    for path in sorted(glob.glob(os.path.join(HOME, "Library/Logs/c11*/hc-diagnostics.log*"))):
        try:
            sizes[path] = os.path.getsize(path)
        except OSError:
            pass
    return sizes


def ledger():
    rows = []
    if os.path.exists(LEDGER):
        with open(LEDGER) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        rows.append({"event": "unparsed", "raw": line[:200]})
    return rows


def arg_after(argv, flag):
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return None


def walk_workspaces(tree):
    """Every workspace node (a dict with `areas`) in `tree --all --json`."""
    found = []
    def rec(o):
        if isinstance(o, dict):
            if "areas" in o and isinstance(o["areas"], list):
                found.append(o)
                return
            for v in o.values():
                rec(v)
        elif isinstance(o, list):
            for v in o:
                rec(v)
    rec(tree)
    return found


def tree_view(meta):
    tree = c11_json(meta, "tree", "--all", check=False, timeout=30)
    if tree is None:
        return None
    workspaces = []
    for ws in walk_workspaces(tree):
        panels = []
        for area in ws.get("areas") or []:
            for p in area.get("panels") or []:
                panels.append({"id": (p.get("id") or "").upper(), "type": p.get("type"),
                               "title": p.get("title"), "last_seen_at": p.get("last_seen_at"),
                               "being_seen": p.get("being_seen"), "cwd": p.get("cwd")})
        workspaces.append({"id": (ws.get("id") or "").upper(), "title": ws.get("title"),
                           "selected": ws.get("selected") is True, "panels": panels})
    return workspaces


def wait_socket(meta, timeout):
    deadline = now() + timeout
    while now() < deadline:
        if os.path.exists(meta["socket"]):
            out = c11(meta, "ping", check=False, timeout=5)
            if out.strip():
                return True
        time.sleep(0.5)
    return False


def wait_ready(meta, timeout):
    deadline = now() + timeout
    diag = None
    while now() < deadline:
        diag = hc_diag(meta)
        if diag and diag.get("readiness") == "ready":
            return diag
        time.sleep(1)
    return diag


def launch(meta, qa, extra_env=None):
    env = {
        "HOME": HOME, "USER": os.environ.get("USER", "admin"), "LOGNAME": os.environ.get("USER", "admin"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "C11_SOCKET_MODE": "automation", "C11_ALLOW_SOCKET_OVERRIDE": "1",
        "C11_SOCKET": meta["socket"], "C11_SOCKET_PATH": meta["socket"],
        "C11_QA_LAUNCH": qa,
    }
    if meta.get("dsock"):
        env["CMUXD_UNIX_PATH"] = meta["dsock"]
    if meta.get("log"):
        env["C11_DEBUG_LOG"] = meta["log"]
    env.update(extra_env or {})
    sh("/usr/bin/sudo", "-n", "/bin/rm", "-f", meta["socket"], check=False)
    started = now()
    subprocess.Popen(["nohup", app_binary(meta)], env=env,
                     stdout=open(os.path.join(STATE, "app.out"), "a"), stderr=subprocess.STDOUT,
                     start_new_session=True)
    if not wait_socket(meta, 60):
        raise SystemExit(f"socket {meta['socket']} did not answer within 60 s; see {STATE}/app.out")
    return started


def term_app(meta, timeout=30):
    pids = app_pids(meta)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = now() + timeout
    while now() < deadline and any(alive(p) for p in pids):
        time.sleep(0.2)
    left = [p for p in pids if alive(p)]
    return pids, left


def end_hc(meta, budget=10.0):
    """SIGKILL cores, then holders straight after (well inside 3 s), and keep
    killing until neither respawns for 2 s or the budget runs out."""
    t0 = now()
    rounds = []
    quiet_since = None
    while now() - t0 < budget:
        cores, holders = hc_cores(meta), hc_holders(meta)
        if not cores and not holders:
            quiet_since = quiet_since or now()
            if now() - quiet_since >= 2.0:
                break
            time.sleep(0.25)
            continue
        quiet_since = None
        tc = now()
        kill9([c["pid"] for c in cores])
        th = now()
        kill9([h["pid"] for h in holders])
        rounds.append({"at_s": round(tc - t0, 3), "cores": cores, "holders": holders,
                       "core_to_holder_s": round(th - tc, 3)})
        time.sleep(0.25)
    return {"rounds": rounds, "cores_left": hc_cores(meta), "holders_left": hc_holders(meta),
            "elapsed_s": round(now() - t0, 3)}


# ----------------------------------------------------------------- phases

def prepare(argv):
    o = opts_of(argv)
    meta = load("meta.json", {}) or {}
    for k in ("app", "socket", "log", "dsock"):
        if o.get(k):
            meta[k] = o[k]
    if not meta.get("app") or not meta.get("socket"):
        raise SystemExit("prepare needs app=<.app> socket=<sock>")
    meta["cli"] = os.path.join(meta["app"], "Contents/Resources/bin/c11")
    meta["bundle"] = bundle_id(meta["app"])
    meta["n"] = int(o.get("n", meta.get("n", 8)))
    shutil.rmtree(STATE, ignore_errors=True)
    os.makedirs(STATE)
    diag = hc_diag(meta) if os.path.exists(meta["socket"]) else None
    s0 = next((s["session"] for s in (diag or {}).get("shards", []) if s.get("index") == 0), None)
    if not s0:
        tag = meta["bundle"].split("com.stage11.c11.debug.", 1)[-1].replace(".", "-").strip("-")
        s0 = "c11-" + tag
    meta["hc_session"] = s0
    meta["session_file"] = os.path.join(HOME, "Library/Application Support/c11",
                                         f"session-{safe_bundle(meta['bundle'])}.json")
    sb = safe_bundle(meta["bundle"])
    meta["sentinels"] = {k: os.path.join(HOME, ".c11/runtime", f"shutdown.{sb}.{k}") for k in ("clean", "dirty")}
    save("meta.json", meta)

    pids, left = term_app(meta)
    kill9(left)
    ended = end_hc(meta)
    stray = session_processes(meta)
    kill9([p["pid"] for p in stray])
    for pattern in (os.path.join(HOME, ".local/state/herdr-core", s0 + "*"),
                    os.path.join(HOME, "Library/Application Support/c11/HC", s0 + "*"),
                    os.path.join(HOME, ".local/share/c11/run", s0 + "*")):
        for path in glob.glob(pattern):
            shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) else os.remove(path)
    for path in [meta["session_file"], *meta["sentinels"].values(), LEDGER, "/tmp/c11h321-start-idle",
                 LC_HOOKS, LC_DOWN]:
        if os.path.exists(path):
            os.remove(path)
    shutil.rmtree(WORK, ignore_errors=True)
    shutil.rmtree("/private/tmp/c11h196-work", ignore_errors=True)

    with open(os.path.join(STATE, "stub"), "w") as f:
        f.write(STUB)
    sh("/usr/bin/sudo", "-n", "/bin/mkdir", "-p", "/usr/local/bin")
    sh("/usr/bin/sudo", "-n", "/bin/cp", os.path.join(STATE, "stub"), STUB_PATH)
    sh("/usr/bin/sudo", "-n", "/bin/chmod", "755", STUB_PATH)
    sh("/usr/bin/defaults", "write", meta["bundle"], "c11.shards.enabled", "-bool", "true")
    sh("/usr/bin/defaults", "write", meta["bundle"], "warnBeforeQuitShortcut", "-bool", "false")

    started = launch(meta, "fresh")
    diag = wait_ready(meta, 60)
    meta["fresh_launch_at"] = started
    save("meta.json", meta)
    out = {"bundle": meta["bundle"], "hc_session": s0, "quit_pids": pids, "hc_ended": ended,
           "stray_killed": stray, "readiness": (diag or {}).get("readiness"),
           "other_claude_on_path": [p for p in sh("/bin/zsh", "-lc", "whence -ap claude", check=False).split()
                                    if p != STUB_PATH]}
    save("prepare.json", out)
    print(json.dumps(out))


def setup(argv):
    meta = load("meta.json")
    n = meta["n"]
    hidden_ws = max(1, (n - 2 + 1) // 2)
    t_setup = now()
    workspaces = tree_view(meta) or []
    selected = next((w for w in workspaces if w["selected"]), None)
    if not selected or not selected["panels"]:
        raise SystemExit(f"no selected workspace with a panel: {json.dumps(workspaces)[:800]}")
    w0 = selected["id"]
    p0 = selected["panels"][0]["id"]
    cwds = [os.path.join(WORK, "proj-a"), os.path.join(WORK, "work_b"), os.path.join(WORK, "svc.c"),
            os.path.join(WORK, "my_app.v2"), os.path.join(WORK, "proj-e"), os.path.join(WORK, "data_f"),
            "/private/tmp/c11h196-work/proj-g", os.path.join(WORK, "h.dot_dir")]
    while len(cwds) < n:
        cwds.append(os.path.join(WORK, f"extra_{len(cwds)}"))
    for d in cwds[:n]:
        os.makedirs(d, exist_ok=True)

    panels = [{"panel": p0, "workspace": w0, "visible": True, "cwd": cwds[0]}]
    split = c11_json(meta, "new-split", "right", "--workspace", w0, "--panel", p0)
    panels.append({"panel": find_uuid(split, ("panel_id", "surface_id", "id")).upper(), "workspace": w0,
                   "visible": True, "cwd": cwds[1]})
    i = 2
    # layout=tabs (C11H-206): every hidden agent panel is a tab in one area of one hidden workspace, the shape
    # where a hidden panel's fresh terminal never started on the operator's laptop. Default: two panels per hidden workspace.
    tabs = opts_of(argv).get("layout") == "tabs"
    if tabs:
        hidden_ws = 1
    for _ in range(hidden_ws):
        if i >= n:
            break
        ws = find_uuid(c11_json(meta, "new-workspace", "--cwd", cwds[i]), ("workspace_id", "id")).upper()
        first = None
        deadline = now() + 15
        while now() < deadline and not first:
            listed = c11_json(meta, "list-panels", "--workspace", ws, check=False) or {}
            first = (listed.get("panels") or [{}])[0].get("id")
            if not first:
                time.sleep(0.5)
        if not first:
            raise SystemExit(f"workspace {ws} has no panel")
        panels.append({"panel": first.upper(), "workspace": ws, "visible": False, "cwd": cwds[i]})
        i += 1
        while i < n:
            made = c11_json(meta, "new-panel", "--workspace", ws, "--cwd", cwds[i])
            panels.append({"panel": find_uuid(made, ("panel_id", "surface_id", "id")).upper(), "workspace": ws,
                           "visible": False, "cwd": cwds[i]})
            i += 1
            if not tabs:
                break
    time.sleep(2.0)

    def send_line(p, text):
        # A panel made a moment ago in a hidden workspace may still be attaching
        # its terminal ("reconnects"): that refusal sends nothing, so retry it.
        deadline = now() + 20
        while True:
            r = subprocess.run([meta["cli"], "--socket", meta["socket"], "send", "--workspace", p["workspace"],
                                "--panel", p["panel"], text],
                               capture_output=True, text=True, timeout=30)
            err = r.stdout + r.stderr
            if r.returncode == 0:
                return
            retryable = "hc_input_unavailable" in err or "inventory_pending" in err
            if not retryable or now() >= deadline:
                raise SystemExit(f"send to {p['panel']} failed ({r.returncode}): {err[-400:]}")
            time.sleep(0.5)

    if opts_of(argv).get("login") == "1":
        # C11H-235: replace each terminal's root with the root a build before C11H-232 opened
        # (`exec` keeps the pid hc recorded), so a SIGTERM to it ends the session as on 2026-11-06.
        user = os.environ.get("USER", "admin")
        for p in panels:
            send_line(p, f"exec /usr/bin/login -flp {user} /bin/bash --noprofile --norc -c 'exec -l /bin/zsh'")
        time.sleep(4.0)
    for p in panels:
        send_line(p, f"cd '{p['cwd']}' && claude")
    deadline = now() + 60
    starts = {}
    while now() < deadline:
        starts = {(r.get("panel") or "").upper(): r for r in ledger() if r.get("event") == "start"}
        if all(p["panel"] in starts for p in panels):
            break
        time.sleep(0.5)
    missing = [p for p in panels if p["panel"] not in starts]
    if missing:
        screens = {p["panel"]: c11(meta, "read-screen", "--workspace", p["workspace"], "--panel", p["panel"],
                                   "--lines", "15", check=False)[-600:] for p in missing}
        raise SystemExit(f"stub did not start in {len(missing)} panel(s) within 60 s: {json.dumps(screens)}")
    time.sleep(1.5)  # let the wrapper's background claim land first

    for p in panels:
        start = starts[p["panel"]]
        sid = arg_after(start.get("argv") or [], "--session-id")
        p["conversation_source"] = "wrapper --session-id" if sid and UUID_RE.match(sid) else "generated"
        if p["conversation_source"] == "generated":
            sid = str(uuid.uuid4())
        p["conversation"] = sid.lower()
        p["stub_start"] = {"pid": start.get("pid"), "cwd": start.get("cwd"), "hc_session": start.get("hc_session")}
        write_transcript(p["cwd"], p["conversation"])
        c11(meta, "conversation", "push", "--panel", p["panel"], "--kind", "claude-code",
            "--id", p["conversation"], "--source", "hook", "--state", "alive")
    time.sleep(2.0)

    listing = c11_json(meta, "conversation", "list", check=False) or {}
    refs = {}
    for c in listing.get("conversations", []):
        key = (c.get("panel_id") or c.get("surface_id") or "").upper()
        refs.setdefault(key, []).append({k: c.get(k) for k in ("kind", "id", "state", "captured_via", "cwd")})
    diag = hc_diag(meta) or {}
    shard_of = {(r.get("panel_id") or "").upper(): r.get("shard") for r in diag.get("panels", [])}
    for p in panels:
        p["shard"] = shard_of.get(p["panel"])
        p["refs_live"] = refs.get(p["panel"], [])
    shards = sorted({p["shard"] for p in panels if p["shard"]})
    bad_refs = [p["panel"] for p in panels
                if not any(r.get("id") == p["conversation"] for r in p["refs_live"])]
    before = tree_view(meta) or []
    save("panels.json", panels)
    save("tree-before.json", before)
    out = {"panels": len(panels), "shards": shards, "refs_missing": bad_refs,
           "selected_workspace": w0, "setup_s": round(now() - t_setup, 1)}
    save("setup.json", out)
    print(json.dumps(out))
    # Shards are assigned per workspace: the tabs layout has two workspaces, so it cannot spread over three.
    need_shards = 1 if tabs else 3
    if len(shards) < need_shards:
        raise SystemExit(f"panels landed on {len(shards)} hc shard(s), need >= {need_shards}: {shards}")
    if bad_refs:
        raise SystemExit(f"conversation push did not take for {bad_refs}")


def write_transcript(cwd, sid):
    path = os.path.join(HOME, ".claude", "projects", slug(cwd), f"{sid}.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    u1, u2 = str(uuid.uuid4()), str(uuid.uuid4())
    lines = [
        {"type": "last-prompt", "lastPrompt": "keep going", "sessionId": sid},
        {"type": "summary", "summary": "c11h196 synthetic session", "leafUuid": u2},
        {"type": "file-history-snapshot", "messageId": u1, "isSnapshotUpdate": False,
         "snapshot": {"messageId": u1, "trackedFileBackups": {}, "timestamp": stamp}},
        {"parentUuid": None, "isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
         "version": "2.1.200", "gitBranch": "", "type": "user", "uuid": u1, "timestamp": stamp,
         "message": {"role": "user", "content": "hello from c11h196"}},
        {"parentUuid": u1, "isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
         "version": "2.1.200", "gitBranch": "", "type": "assistant", "uuid": u2, "timestamp": stamp,
         "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}},
    ]
    with open(path, "w") as f:
        for rec in lines:
            f.write(json.dumps(rec) + "\n")
    return path


def quit_(argv, name="quit"):
    meta = load("meta.json")
    t0 = now()
    pre_diag = hc_diag(meta) or {}
    save("hc-before-quit.json", pre_diag)
    pids, left = term_app(meta, timeout=30)
    clean = meta["sentinels"]["clean"]
    clean_ok = os.path.exists(clean) and os.path.getmtime(clean) >= t0 - 1
    out = {"pids": pids, "still_running": left, "quit_s": round(now() - t0, 2), "clean_sentinel": clean_ok,
           "dirty_sentinel_present": os.path.exists(meta["sentinels"]["dirty"])}
    save(name + ".json", out)
    print(json.dumps(out))
    if left or not clean_ok:
        raise SystemExit(f"clean quit failed: {out}")


def hostend(argv):
    meta = load("meta.json")
    before = {"cores": hc_cores(meta), "holders": hc_holders(meta)}
    ended = end_hc(meta)
    time.sleep(2.0)
    survivors = session_processes(meta)
    stub_pids = {r.get("pid") for r in ledger() if r.get("event") == "start"}
    stub_alive = [p for p in stub_pids if p and alive(p)]
    kill9([p["pid"] for p in survivors] + stub_alive)
    time.sleep(0.5)
    out = {"before": before, "ended": ended, "survivors_killed": survivors, "stubs_killed": stub_alive,
           "left": session_processes(meta)}
    ok = bool(before["cores"]) and not ended["cores_left"] and not ended["holders_left"] and all(
        r["core_to_holder_s"] < 3 for r in ended["rounds"])
    out["ok"] = ok
    save("hostend.json", out)
    print(json.dumps(out))
    if not ok:
        raise SystemExit(f"host end did not complete: {out}")


def scrub(argv):
    meta = load("meta.json")
    path = meta["session_file"]
    with open(path) as f:
        snap = json.load(f)
    shutil.copy(path, os.path.join(STATE, "session-before-scrub.json"))
    removed, refs = [], []

    def rec(o, panel=None):
        if isinstance(o, dict):
            pid = o.get("id") if isinstance(o.get("id"), str) and "surface_conversations" in o else panel
            sc = o.get("surface_conversations")
            if isinstance(sc, dict):
                for ref in ([sc.get("active")] if sc.get("active") else []) + list(sc.get("history") or []):
                    if isinstance(ref, dict):
                        if "cwd" in ref:
                            removed.append({"panel": pid, "cwd": ref.pop("cwd")})
                        refs.append({"panel": (pid or "").upper(), "kind": ref.get("kind"), "id": ref.get("id"),
                                     "state": ref.get("state"), "source": ref.get("capturedVia") or ref.get("captured_via")})
            for v in o.values():
                rec(v, pid)
        elif isinstance(o, list):
            for v in o:
                rec(v, panel)
    rec(snap)
    tmp = path + ".c11h196"
    with open(tmp, "w") as f:
        json.dump(snap, f)
    os.replace(tmp, path)
    panels = load("panels.json")
    missing = [p["panel"] for p in panels if not any(r["id"] == p["conversation"] for r in refs)]
    out = {"session_file": path, "cwd_removed": len(removed), "refs": refs, "seeded_refs_missing": missing}
    save("scrub.json", out)
    print(json.dumps({k: v for k, v in out.items() if k != "refs"}))
    if missing:
        raise SystemExit(f"saved session lacks refs for {missing}")


HELD = os.path.join(HOME, ".claude", "projects.c11h196-held")


def hold_transcripts(hold):
    """C11H-209: hidetranscripts=1 moves every transcript away before the first
    relaunch (each resume is then skipped: no saved conversation on disk) and
    `again` puts them back before the second."""
    live = os.path.join(HOME, ".claude", "projects")
    if hold:
        if os.path.isdir(live) and not os.path.exists(HELD):
            os.replace(live, HELD)
        return os.path.isdir(HELD) and not os.path.exists(live)
    if not os.path.isdir(HELD):
        return os.path.isdir(live)
    # Merge back file by file: the first relaunch may have recreated `live`.
    for root, _, files in os.walk(HELD):
        target = os.path.join(live, os.path.relpath(root, HELD))
        os.makedirs(target, exist_ok=True)
        for name in files:
            os.replace(os.path.join(root, name), os.path.join(target, name))
    shutil.rmtree(HELD, ignore_errors=True)
    return os.path.isdir(live)


def relaunch(argv):
    meta = load("meta.json")
    if opts_of(argv).get("hidetranscripts") == "1" and not hold_transcripts(True):
        raise SystemExit("could not hold the transcripts away")
    sizes = log_sizes()
    # C11H-205: noresume=1 relaunches with agent restart off, so no host-end
    # record covers the ends and a shown panel's fresh shell is the only change.
    extra = {"CMUX_DISABLE_AGENT_RESTART": "1"} if opts_of(argv).get("noresume") == "1" else {}
    started = launch(meta, "resume", extra)
    out = {"launched_at": started, "socket_after_s": round(now() - started, 2), "log_sizes_before": sizes}
    save("relaunch.json", out)
    print(json.dumps({k: v for k, v in out.items() if k != "log_sizes_before"}))


def events_since(t0):
    rows = []
    for path in glob.glob(os.path.join(HOME, "Library/Application Support/c11*/events/events-*.ndjson*")):
        if os.path.getmtime(path) < t0 - 5:
            continue
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                ts = parse_ts(e.get("ts"))
                if ts is not None and ts >= t0 - 1:
                    e["_ts"] = ts
                    e["_file"] = os.path.basename(path)
                    rows.append(e)
    rows.sort(key=lambda e: e["_ts"])
    return rows


def parse_ts(raw):
    if isinstance(raw, (int, float)):
        return raw / 1000.0 if raw > 1e11 else float(raw)
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def cputime(pid):
    raw = sh("/bin/ps", "-o", "cputime=", "-p", str(pid), check=False).strip()
    if not raw:
        return None
    days = 0
    if "-" in raw:
        d, raw = raw.split("-", 1)
        days = int(d)
    parts = [float(x) for x in raw.split(":")]
    secs = 0.0
    for x in parts:
        secs = secs * 60 + x
    return days * 86400 + secs


def collect(argv):
    o = opts_of(argv)
    t_limit, quiet, cpu_window = float(o.get("t", 120)), float(o.get("quiet", 20)), float(o.get("cpu", 30))
    noresume = o.get("noresume") == "1"
    hidden = o.get("hidetranscripts") == "1"
    meta = load("meta.json")
    panels = load("panels.json")
    rl = load("relaunch.json")
    t0 = rl["launched_at"]
    by_conv = {p["conversation"]: p for p in panels}
    selected_before = next((w for w in load("tree-before.json") if w["selected"]), None)
    samples, diag_samples = [], []

    def resumes():
        out = []
        for r in ledger():
            if r.get("event") == "start" and r.get("ts", 0) >= t0:
                sid = arg_after(r.get("argv") or [], "--resume")
                out.append({"conversation": (sid or "").lower() or None, "ts": r["ts"], "cwd": r.get("cwd"),
                            "pwd": r.get("pwd"), "panel": (r.get("panel") or "").upper(), "pid": r.get("pid"),
                            "argv": r.get("argv")})
        return out

    # Watch only: no read-screen, no focus, nothing that attaches a hidden terminal.
    deadline = t0 + t_limit
    next_sample = 0
    while now() < deadline:
        seen = {r["conversation"] for r in resumes()}
        if now() >= next_sample:
            view = tree_view(meta)
            sel = next((w for w in (view or []) if w["selected"]), None)
            present = {x["id"] for w in (view or []) for x in w["panels"]}
            samples.append({"t_s": round(now() - t0, 1), "selected": sel["id"] if sel else None,
                            "restored": all(p["panel"] in present for p in panels)})
            d = hc_diag(meta) or {}
            diag_samples.append({"t_s": round(now() - t0, 1), "readiness": d.get("readiness"),
                                 "panels": {(r.get("panel_id") or "").upper(): {
                                     k: r.get(k) for k in ("lifecycle", "terminal", "reason", "restore_notice", "host_end")
                                     if k in r} for r in d.get("panels", [])}})
            next_sample = now() + 5
        if all(c in seen for c in by_conv):
            break
        # noresume: nothing resumes; watch until every shown panel is live again.
        # hidetranscripts: until every panel's record has settled.
        if hidden and diag_samples:
            rows = diag_samples[-1]["panels"]
            if all((rows.get(p["panel"], {}).get("host_end") or {}).get("state") in ("not_resumed", "failed", "kept")
                   for p in panels):
                break
        if noresume and diag_samples:
            rows = diag_samples[-1]["panels"]
            if all(rows.get(p["panel"], {}).get("lifecycle") == "live" for p in panels if p["visible"]):
                break
        time.sleep(0.5)
    t_watch_end = now()
    first_pass = resumes()
    last_resume = max([r["ts"] for r in first_pass], default=None)

    # CPU over the window after the last resume (or after T); the quiet wait for
    # typed input runs inside it.
    app = (app_pids(meta) or [None])[0]
    cpu = {"pid": app, "window_s": cpu_window, "samples_pct": []}
    c_start = cputime(app) if app else None
    w_start = now()
    while now() - w_start < max(cpu_window, quiet):
        pct = sh("/bin/ps", "-o", "%cpu=", "-p", str(app), check=False).strip() if app else ""
        if pct:
            cpu["samples_pct"].append(float(pct))
        time.sleep(1.0)
    c_end = cputime(app) if app else None
    if c_start is not None and c_end is not None:
        cpu["avg_pct"] = round(100.0 * (c_end - c_start) / (now() - w_start), 1)
        cpu["max_sample_pct"] = max(cpu["samples_pct"] or [0])
    cpu["after_last_resume"] = last_resume is not None

    final = resumes()
    rows = ledger()
    stdin_lines = [r for r in rows if r.get("event") == "stdin"]
    events = events_since(t0)
    decisions = [e for e in events if e.get("type") == "conversation.resume.decision"]
    conv_events = [e for e in events if str(e.get("type", "")).startswith("conversation.")]
    view_after = tree_view(meta) or []
    diag_after = hc_diag(meta) or {}
    listing = c11_json(meta, "conversation", "list", check=False) or {}
    sizes_after = log_sizes()

    # (a) each seeded id resumed exactly once within T, in its cwd
    a_rows = []
    for p in panels:
        hits = [r for r in final if r["conversation"] == p["conversation"]]
        in_t = [r for r in hits if r["ts"] <= t0 + t_limit]
        first = in_t[0] if in_t else (hits[0] if hits else None)
        cwd_ok = bool(first) and os.path.realpath(first["cwd"] or "") == os.path.realpath(p["cwd"])
        a_rows.append({"panel": p["panel"], "visible": p["visible"], "shard": p.get("shard"),
                       "conversation": p["conversation"], "seeded_cwd": p["cwd"], "resumes": len(hits),
                       "resumes_within_t": len(in_t),
                       "resume_after_s": round(first["ts"] - t0, 2) if first else None,
                       "ledger_cwd": first["cwd"] if first else None, "cwd_ok": cwd_ok,
                       "resumed_in_panel": first["panel"] if first else None,
                       "panel_ok": bool(first) and first["panel"] == p["panel"],
                       "pass": len(hits) == 1 and len(in_t) == 1 and cwd_ok})
    a_pass = all(r["pass"] for r in a_rows)
    stray = [r for r in final if r["conversation"] not in by_conv]

    # (b) spacing of resume starts
    ts_sorted = sorted(r["ts"] for r in final)
    gaps = [round(b - a, 3) for a, b in zip(ts_sorted, ts_sorted[1:])]
    b_pass = len(ts_sorted) >= 2 and min(gaps) >= 0.5 if gaps else False

    # (c) nothing typed into a live stub
    c_pass = not stdin_lines

    # (d) selection unchanged; hidden panels never seen
    sel_after = next((w for w in view_after if w["selected"]), None)
    # Only samples taken once restore has every panel back; earlier ones may
    # show the window before its workspaces are restored.
    sel_ids = {s["selected"] for s in samples if s["restored"] and s["selected"]} | (
        {sel_after["id"]} if sel_after else set())
    visible_ids = {p["panel"] for p in panels if p["visible"]}
    sel_panels = {x["id"] for x in sel_after["panels"]} if sel_after else set()
    panel_view = {x["id"]: x for w in view_after for x in w["panels"]}
    hidden_seen = []
    for p in panels:
        if p["visible"]:
            continue
        v = panel_view.get(p["panel"])
        if v is None or v.get("last_seen_at") is not None or v.get("being_seen") is not False:
            hidden_seen.append({"panel": p["panel"], "view": v})
    d_pass = (len(sel_ids) == 1 and bool(sel_after) and visible_ids <= sel_panels and not hidden_seen)

    # (e) decision events: <= 1 per panel, total <= N + 2
    per_panel = {}
    for e in decisions:
        key = (e.get("panel") or e.get("surface") or "").upper()
        per_panel[key] = per_panel.get(key, 0) + 1
    e_pass = all(v <= 1 for v in per_panel.values()) and len(decisions) <= len(panels) + 2

    # (f) no Recovered workspace, no panel beyond those before the quit
    before_ids = {x["id"] for w in load("tree-before.json") for x in w["panels"]}
    after_ids = set(panel_view)
    recovered = [w["title"] for w in view_after if "recovered" in str(w.get("title") or "").lower()]
    f_pass = not recovered and not (after_ids - before_ids)

    # (g) no stale restore notice on a resumed panel
    diag_rows = {(r.get("panel_id") or "").upper(): r for r in diag_after.get("panels", [])}
    g_rows, g_unknown = [], []
    for p in panels:
        r = diag_rows.get(p["panel"], {})
        if "restore_notice" not in r:
            g_unknown.append(p["panel"])
        g_rows.append({"panel": p["panel"], "restore_notice": r.get("restore_notice", "<absent>"),
                       "host_end": r.get("host_end", "<absent>"), "lifecycle": r.get("lifecycle"),
                       "reason": r.get("reason")})
    g_fail = [x for x in g_rows if x["restore_notice"] not in (None, "<absent>")]
    g_pass = not g_fail

    # (j) C11H-205: a live panel never says its session ended (panel 408).
    # With resume off no host-end record covers the end, which is when the
    # notice used to stay on the shown panels' fresh shells.
    # With resume off the shown panels' fresh shells must say the previous
    # session ended; with resume on the host-end banner explains it and the
    # notice is gone.
    j_rows = [x for x in g_rows if x["lifecycle"] == "live"]
    j_want = "previous_session_ended" if noresume else None
    j_fail = [x for x in j_rows if x["restore_notice"] != j_want]
    j_pass = bool(j_rows) and not j_fail

    # (i) the restore record agrees, and a restore agent's run changes nothing
    # (every conversation already resumed; once-only).
    status = c11_json(meta, "restore", "status", check=False) or {}
    # noresume / hidetranscripts: `restore run --all` is the operator asking
    # for every offered resume, which `again` would then see finished.
    rerun = {} if (noresume or hidden) else (c11_json(meta, "restore", "run", "--all", check=False) or {})
    summary_i = status.get("summary") or {}
    scheduled = [r for r in rerun.get("panels", []) if r.get("outcome") == "scheduled"]
    i_pass = (summary_i.get("total") == len(panels) and summary_i.get("resumed") == len(panels)
              and summary_i.get("need_you") == 0 and summary_i.get("finished") is True and not scheduled)

    growth = {k: sizes_after.get(k, 0) - rl["log_sizes_before"].get(k, 0)
              for k in set(sizes_after) | set(rl["log_sizes_before"])}

    def ev(e):
        return {"t_s": round(e["_ts"] - t0, 2), "type": e.get("type"),
                "panel": (e.get("panel") or e.get("surface") or "").upper(), "payload": e.get("payload")}

    assertions = {
        "a_each_resumed_once_in_cwd_within_T": {"pass": a_pass, "t_s": t_limit, "rows": a_rows,
                                                "unseeded_resumes": stray},
        "b_resumes_spaced_ge_0_5s": {"pass": b_pass, "gaps_s": gaps, "min_gap_s": min(gaps) if gaps else None},
        "c_nothing_typed_into_live_agent": {"pass": c_pass, "stdin_lines": stdin_lines[:20],
                                            "checked_after_quiet_s": quiet},
        "d_selection_unchanged_hidden_unseen": {"pass": d_pass,
                                                "selected_before": selected_before["id"] if selected_before else None,
                                                "selected_seen": sorted(i for i in sel_ids if i),
                                                "visible_panels_in_selected": sorted(visible_ids & sel_panels),
                                                "hidden_seen": hidden_seen},
        "e_decisions_le_1_per_panel_total_le_n_plus_2": {"pass": e_pass, "total": len(decisions),
                                                         "limit": len(panels) + 2, "per_panel": per_panel},
        "f_no_recovered_no_extra_panels": {"pass": f_pass, "recovered_workspaces": recovered,
                                           "extra_panels": sorted(after_ids - before_ids),
                                           "missing_panels": sorted(before_ids - after_ids)},
        "g_no_stale_restore_notice": {"pass": g_pass, "field_absent_for": g_unknown,
                                      "note": "absent field reported as unknown, not a failure", "rows": g_rows},
        "i_restore_status_complete_and_rerun_is_a_no_op": {"pass": i_pass, "summary": summary_i,
                                                           "rerun_scheduled": scheduled,
                                                           "status_rows": status.get("panels")},
        "j_live_panel_has_no_end_notice": {"pass": j_pass, "live_rows": j_rows, "failing": j_fail, "want": j_want,
                                           "note": "fails when no panel is live to check"},
        "h_resumed_in_own_panel": {"pass": all(r["panel_ok"] for r in a_rows if r["resumes"]) and
                                   any(r["resumes"] for r in a_rows),
                                   "informational": True},
    }
    if noresume or hidden:
        # Nothing is resumed and hidden panels stay ended (their notice is
        # true), so the resume assertions and (g) only inform.
        for k in ("a_each_resumed_once_in_cwd_within_T", "b_resumes_spaced_ge_0_5s",
                  "g_no_stale_restore_notice", "i_restore_status_complete_and_rerun_is_a_no_op"):
            assertions[k]["informational"] = True
    gating = [k for k, v in assertions.items() if not v.get("informational")]
    summary = {
        "result": "pass" if all(assertions[k]["pass"] for k in gating) else "fail",
        "failed": [k for k in gating if not assertions[k]["pass"]],
        "app": meta["app"], "bundle": meta["bundle"], "hc_session": meta["hc_session"],
        "c11_version": diag_after.get("c11_version"),
        "launched_at": iso(t0), "watch_ended_after_s": round(t_watch_end - t0, 1),
        "resumed": sum(1 for r in a_rows if r["resumes"]), "panels": len(panels),
        "assertions": assertions,
        "cpu_after_last_resume": cpu,
        "hc_diagnostics_log_growth_bytes": growth,
        "hc_diagnostics_log_sizes_after": sizes_after,
        "phases": {k: load(k + ".json") for k in ("prepare", "setup", "quit", "hostend")},
        "scrub": {k: v for k, v in (load("scrub.json") or {}).items() if k != "refs"},
        "saved_refs": (load("scrub.json") or {}).get("refs"),
        "seeded": [{k: p.get(k) for k in ("panel", "workspace", "visible", "shard", "cwd", "conversation",
                                          "conversation_source")} for p in panels],
        "selection_samples": samples,
        "hc_diag_samples": diag_samples,
        "decision_timeline_per_10s": timeline(decisions, t0),
        "decision_reasons": reasons(decisions),
        "decision_span_s": [round(decisions[0]["_ts"] - t0, 1), round(decisions[-1]["_ts"] - t0, 1)] if decisions else None,
        "conversation_events_first": [ev(e) for e in conv_events][:60],
        "conversations_after": [{k: c.get(k) for k in ("panel_id", "kind", "id", "state", "captured_via",
                                                       "cwd", "diagnostic_reason")}
                                for c in listing.get("conversations", [])],
        "hc_diagnostics_after": {k: diag_after.get(k) for k in ("readiness", "readiness_reason", "holder_lost_count",
                                                                "shards", "panels")},
        "app_out_tail": tail(os.path.join(STATE, "app.out"), 60),
        "debug_log_resume_lines": grep_tail(meta.get("log"), r"resume|restore|stopped_by_restart|host.?end", 120),
    }
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H196-SUMMARY-END===")


def again(argv):
    """C11H-209 and C11H-205 decision 2. After `collect`, quit cleanly and
    relaunch with agent resume on. Every host end of the first relaunch was
    decided there (resumed, or offered) or happened before it started, so this
    launch types nothing: (k) no agent starts. After a no-resume first launch,
    (l) each panel's record offers Resume instead (main resumed all of them)."""
    o = opts_of(argv)
    wait = float(o.get("t2", 45))
    noresume = o.get("noresume") == "1"
    hidden = o.get("hidetranscripts") == "1"
    meta = load("meta.json")
    panels = load("panels.json")
    summary = load("summary.json")
    quit_([], name="quit2")
    if hidden and not hold_transcripts(False):
        raise SystemExit("could not put the transcripts back")
    started = launch(meta, "resume")
    if not wait_ready(meta, 60):
        raise SystemExit("hc did not become ready after the second relaunch")
    rows = {}
    deadline = started + wait
    starts = []
    while now() < deadline:
        starts = [r for r in ledger() if r.get("event") == "start" and r.get("ts", 0) >= started]
        if starts:
            break
        d = hc_diag(meta) or {}
        rows = {(r.get("panel_id") or "").upper(): r for r in d.get("panels", [])}
        time.sleep(1)
    time.sleep(2)
    starts = [r for r in ledger() if r.get("event") == "start" and r.get("ts", 0) >= started]
    d = hc_diag(meta) or {}
    rows = {(r.get("panel_id") or "").upper(): r for r in d.get("panels", [])}
    # (l) covers the panels the first relaunch left ended (hidden ones; a shown
    # panel's fresh shell is a new terminal).
    first = {(r.get("panel_id") or "").upper(): r.get("lifecycle")
             for r in (summary.get("hc_diagnostics_after") or {}).get("panels") or []}
    l_rows = []
    for p in panels:
        if first.get(p["panel"]) != "ended":
            continue
        r = rows.get(p["panel"], {})
        he = r.get("host_end") or {}
        l_rows.append({"panel": p["panel"], "visible": p["visible"], "lifecycle": r.get("lifecycle"),
                       "state": he.get("state"), "offers_resume": he.get("offers_resume"), "reason": he.get("reason")})
    l_fail = [x for x in l_rows if x["state"] != "not_resumed" or x["offers_resume"] is not True] or (
        [] if l_rows else [{"note": "no panel was left ended by the first relaunch"}])
    status = c11_json(meta, "restore", "status", check=False) or {}
    summary["assertions"]["k_second_launch_starts_no_agent"] = {
        "pass": not starts, "starts": [{k: r.get(k) for k in ("ts", "panel", "argv", "cwd")} for r in starts][:20],
        "watched_s": wait}
    summary["assertions"]["l_older_end_is_offered_not_resumed"] = {
        "pass": not l_fail, "rows": l_rows, "failing": l_fail, "restore_status": status.get("summary"),
        "informational": not (noresume or hidden),
        "note": "gating after noresume=1 (found and left) or hidetranscripts=1 (decided, not resumed)"}
    gating = [k for k, v in summary["assertions"].items() if not v.get("informational")]
    summary["failed"] = [k for k in gating if not summary["assertions"][k]["pass"]]
    summary["result"] = "fail" if summary["failed"] else "pass"
    summary["second_launch"] = {"launched_at": iso(started), "quit": load("quit2.json"),
                                "debug_log_resume_lines": grep_tail(meta.get("log"), r"resume|host.?end", 60)}
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H196-SUMMARY-END===")


def signal_end(argv):
    """C11H-232 (`mode=signal`): outside signals at one terminal root each, never a broad pkill.
    A: SIGTERM to the root while the stub agent runs; the root (the login shell) ignores it and the agent
       keeps running. B: SIGKILL to the root (what `pkill -9 -f` sends); the panel stays with an
       outside_signal record that offers Resume, nothing resumes unasked, `restore run` resumes it once in
       its cwd. C: c11's own End Session (close-panel) still closes. D: a clean exit (Ctrl-D to the stub,
       then `exit`) still closes. Every root's argv is the shell, with no login and no option string, and
       the incident's pattern list (`pgrep -f <x> -n`, read-only) names none of them."""
    o = opts_of(argv)
    meta = load("meta.json")
    panels = load("panels.json")
    if len(panels) < 4:
        raise SystemExit(f"signal mode needs n>=4 panels, have {len(panels)}")
    a, b, c, d = panels[:4]
    t0 = now()
    asserts = {}

    def check(name, ok, **detail):
        asserts[name] = {"pass": bool(ok), **detail}
        print(f"{'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:600]}", flush=True)

    def diag_rows():
        return {(r.get("panel_id") or "").upper(): r for r in (hc_diag(meta) or {}).get("panels", [])}

    def wait_for(fn, timeout, step=0.5):
        deadline = now() + timeout
        value = fn()
        while not value and now() < deadline:
            time.sleep(step)
            value = fn()
        return value

    def panel_ids():
        return {p["id"] for w in (tree_view(meta) or []) for p in w["panels"]}

    rows = diag_rows()
    roots = {}
    for p in (a, b, c, d):
        pid = (rows.get(p["panel"]) or {}).get("pid")
        cmd = sh("/bin/ps", "-o", "command=", "-p", str(pid), check=False).strip() if pid else ""
        roots[p["panel"]] = {"pid": pid, "command": cmd}
    bad = {k: v for k, v in roots.items()
           if not v["pid"] or "login" in v["command"] or re.search(r"(^|\s)-[A-Za-z]|--no", v["command"])}
    check("root_is_the_shell", not bad, roots=roots)
    matched = [int(x) for x in sh("/usr/bin/pgrep", "-f", "tsx mock-backend/server.ts", "-n", check=False).split()]
    hit = [r for r in roots.values() if r["pid"] in matched]
    check("incident_pattern_misses_roots", not hit, matched=len(matched), roots_hit=hit)

    # A: SIGTERM is ignored by the root; the agent keeps running.
    stub_a = a.get("stub_start", {}).get("pid")
    os.kill(roots[a["panel"]]["pid"], signal.SIGTERM)
    time.sleep(3)
    row_a = diag_rows().get(a["panel"]) or {}
    check("sigterm_root_survives", alive(roots[a["panel"]]["pid"]) and bool(stub_a and alive(stub_a))
          and a["panel"] in panel_ids() and str(row_a.get("lifecycle", "")).startswith("live"),
          root_alive=alive(roots[a["panel"]]["pid"]), stub_alive=bool(stub_a and alive(stub_a)),
          lifecycle=row_a.get("lifecycle"))

    # B: an outside SIGKILL ends the root; the panel stays and offers Resume.
    starts_before = len([r for r in ledger() if r.get("event") == "start"])
    os.kill(roots[b["panel"]]["pid"], signal.SIGKILL)
    host_end = wait_for(lambda: (diag_rows().get(b["panel"]) or {}).get("host_end"), 20)
    check("sigkill_panel_kept", b["panel"] in panel_ids() and bool(host_end), host_end=host_end)
    check("record_offers_resume", bool(host_end) and host_end.get("cause") == "outside_signal"
          and host_end.get("signal") == 9 and host_end.get("state") == "not_resumed"
          and host_end.get("offers_resume") is True and host_end.get("conversation_id") == b["conversation"],
          host_end=host_end)
    time.sleep(float(o.get("quiet", "8")))
    status = c11_json(meta, "restore", "status", check=False) or {}
    row = next((r for r in status.get("panels", []) if (r.get("panel_id") or "").upper() == b["panel"]), None)
    resumed_unasked = [r for r in ledger() if r.get("event") == "start"][starts_before:]
    check("restore_status_lists_it", bool(row) and row.get("state") == "skipped" and row.get("cause") == "outside_signal",
          row=row, summary=status.get("summary"))
    check("never_resumed_unasked", not resumed_unasked, starts=resumed_unasked)
    run = c11_json(meta, "restore", "run", "--panel", b["panel"], check=False) or {}
    t_run = now()
    resumed = wait_for(lambda: [r for r in ledger()[0:] if r.get("event") == "start"
                                and arg_after(r.get("argv") or [], "--resume") == b["conversation"]], 60)
    again_rows = [r for r in ledger() if r.get("event") == "start"
                  and arg_after(r.get("argv") or [], "--resume") == b["conversation"]]
    host_end_after = wait_for(lambda: ((diag_rows().get(b["panel"]) or {}).get("host_end") or {}).get("state") == "resumed"
                              and (diag_rows().get(b["panel"]) or {}).get("host_end"), 15)
    check("restore_run_resumes_once_in_cwd", bool(resumed) and len(again_rows) == 1
          and again_rows[0].get("cwd") == b["cwd"] and (again_rows[0].get("panel") or "").upper() == b["panel"],
          run=run, resumes=again_rows, after_s=round(now() - t_run, 1), host_end=host_end_after)

    # C: End Session still closes.
    c11(meta, "close-panel", "--workspace", c["workspace"], "--panel", c["panel"], check=False)
    gone_c = wait_for(lambda: c["panel"] not in panel_ids(), 15)
    check("end_session_closes", gone_c)

    # D: a clean exit still closes: Ctrl-D ends the stub, a second Ctrl-D ends the shell with 0.
    c11(meta, "send-key", "--workspace", d["workspace"], "--panel", d["panel"], "ctrl+d", check=False)
    time.sleep(1.5)
    c11(meta, "send-key", "--workspace", d["workspace"], "--panel", d["panel"], "ctrl+d", check=False)
    gone_d = wait_for(lambda: d["panel"] not in panel_ids(), 15)
    check("clean_exit_closes", gone_d, screen=None if gone_d else c11(meta, "read-screen", "--workspace",
          d["workspace"], "--panel", d["panel"], "--lines", "8", check=False)[-400:])

    failed = [k for k, v in asserts.items() if not v["pass"]]
    summary = {"result": "fail" if failed else "pass", "mode": "signal", "failed": failed,
               "resumed": len(again_rows), "panels": 4, "assertions": asserts, "elapsed_s": round(now() - t0, 1),
               "diag_log_signal_lines": [l for path in sorted(glob.glob(os.path.join(HOME, "Library/Logs/c11*/hc-diagnostics.log")))
                                         for l in grep_tail(path, r"outside_signal_end", 20)]}
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H196-SUMMARY-END===")


# A compiled tests_v2/ax_walk.swift, written by run.sh for mode=mass (finds the strip's Resume all).
AX_WALK = "/tmp/c11h196-ax-walk"


def mass_end(argv):
    """C11H-235 (`mode=mass`): a mass outside-signal end is recorded once and offers Resume all; c11 raises
    no flag for it (C11H-240).
    Seven stub agents whose roots are `/usr/bin/login` (setup login=1, the root SIGTERM ends). S alone: a
    single end, no mass end. M (one shown, two in a hidden workspace): SIGTERM to each root pid within 2 s; one
    terminal.mass_signal_end and no flag, nothing resumes unasked, the strip's Resume all (clicked by its
    accessibility id) resumes each once in its cwd, and a second Resume all resumes none. A (all hidden),
    with the setting on: they resume without a click. Every end has exactly one terminal.ended_by_signal on
    `events tail`. hc-diagnostics reports root=login for these and root=shell for a fresh terminal."""
    o = opts_of(argv)
    meta = load("meta.json")
    panels = load("panels.json")
    if len(panels) < 7:
        raise SystemExit(f"mass mode needs n>=7 panels (10 for the launch rows), have {len(panels)}")
    single, group_m, group_a = panels[1], [panels[0], panels[2], panels[3]], [panels[4], panels[5], panels[6]]
    quiet = float(o.get("quiet", "8"))
    t0 = now()
    asserts = {}

    def check(name, ok, informational=False, **detail):
        asserts[name] = {"pass": bool(ok), **({"informational": True} if informational else {}), **detail}
        print(f"{'INFO' if informational else 'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:700]}",
              flush=True)

    def diag():
        return hc_diag(meta) or {}

    def diag_rows():
        return {(r.get("panel_id") or "").upper(): r for r in diag().get("panels", [])}

    def wait_for(fn, timeout, step=0.5):
        deadline = now() + timeout
        value = fn()
        while not value and now() < deadline:
            time.sleep(step)
            value = fn()
        return value

    def starts():
        return [r for r in ledger() if r.get("event") == "start"]

    def resumes_of(p):
        return [r for r in starts() if arg_after(r.get("argv") or [], "--resume") == p["conversation"]]

    def offered(p):
        h = (diag_rows().get(p["panel"]) or {}).get("host_end") or {}
        return h if h.get("cause") == "outside_signal" and h.get("offers_resume") is True else None

    def flag_of(p):
        md = c11_json(meta, "get-metadata", "--workspace", p["workspace"], "--panel", p["panel"], check=False) or {}
        md = md.get("metadata", md)
        return md.get("flag")

    def c11_flags(after=None):
        return [e for e in tail("flag.raised", after) if (e.get("payload") or {}).get("by") == "c11"]

    def tail(kind, after=None):
        out = c11(meta, "events", "tail", "--filter", f"type={kind}", check=False, timeout=30)
        rows = []
        for line in out.splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if (parse_ts(e.get("ts")) or 0) >= (after or t0) - 1:
                rows.append(e)
        return rows

    def kill_roots(group, spacing):
        rows = diag_rows()
        pids = []
        for p in group:
            pid = (rows.get(p["panel"]) or {}).get("pid")
            pids.append({"panel": p["panel"], "pid": pid,
                         "command": sh("/bin/ps", "-o", "command=", "-p", str(pid), check=False).strip() if pid else ""})
        t_kill = now()
        for i, row in enumerate(pids):
            if row["pid"]:
                os.kill(int(row["pid"]), signal.SIGTERM)  # one recorded pid, never a pattern
            if i + 1 < len(pids):
                time.sleep(spacing)
        return pids, round(now() - t_kill, 2)

    # Root form: every agent terminal here roots at login; a fresh terminal roots at the shell.
    rows = diag_rows()
    roots = {p["panel"]: rows.get(p["panel"], {}).get("root") for p in panels}
    check("root_login_reported", all(v == "login" for v in roots.values()) and diag().get("login_rooted", 0) >= 7,
          roots=roots, login_rooted=diag().get("login_rooted"))
    fresh = find_uuid(c11_json(meta, "new-panel", "--workspace", panels[0]["workspace"]), ("panel_id", "surface_id", "id"))
    fresh_root = wait_for(lambda: (diag_rows().get((fresh or "").upper()) or {}).get("root") == "shell", 20)
    check("root_shell_for_a_new_terminal", bool(fresh_root),
          row={k: (diag_rows().get((fresh or "").upper()) or {}).get(k) for k in ("root", "pid", "lifecycle")})
    text = c11(meta, "hc-diagnostics", check=False)
    check("text_reports_root_and_count", "login_rooted=" in text and " root=login " in text and " root=shell " in text,
          lines=[l for l in text.splitlines() if "login_rooted" in l])

    # S alone: kept with Resume, no mass end, no flag.
    s_pids, _ = kill_roots([single], 0)
    s_end = wait_for(lambda: offered(single), 30)
    time.sleep(5 + 2 + 3)  # past the window and the settle
    check("single_end_kept_without_mass_end", bool(s_end) and not tail("terminal.mass_signal_end")
          and not flag_of(single), host_end=s_end, killed=s_pids, flag=flag_of(single))
    c11_json(meta, "restore", "run", "--panel", single["panel"], check=False)
    wait_for(lambda: resumes_of(single), 60)

    # M: three roots within 2 s, the setting off (the default).
    selected_before = next((w["id"] for w in tree_view(meta) or [] if w["selected"]), None)
    sh("/usr/bin/defaults", "write", meta["bundle"], "c11.massSignalEnd.autoResume", "-bool", "false")
    before_m = len(starts())
    m_pids, m_span = kill_roots(group_m, 0.6)
    m_ends = wait_for(lambda: all(offered(p) for p in group_m) and [offered(p) for p in group_m], 40)
    mass = wait_for(lambda: tail("terminal.mass_signal_end"), 15)
    time.sleep(quiet)
    m_flags = {p["panel"]: flag_of(p) for p in group_m}
    raised = c11_flags()
    check("mass_kept_panels", bool(m_ends) and len(m_ends) == 3, killed=m_pids, kill_span_s=m_span,
          states=[{k: (e or {}).get(k) for k in ("cause", "signal", "state", "offers_resume")} for e in (m_ends or [])])
    check("one_mass_end_event_with_count", len(mass) == 1 and (mass[0].get("payload") or {}).get("count") == 3
          and set((mass[0].get("payload") or {}).get("panels") or []) == {p["panel"] for p in group_m}
          and not {"flag_panel", "notified"} & set(mass[0].get("payload") or {})
          and (mass[0].get("payload") or {}).get("auto_resume") is False, events=mass)
    check("no_flag_on_a_mass_end", not raised and not any(m_flags.values()), flags=m_flags, raised=raised)
    check("mass_never_resumed_unasked", len(starts()) == before_m, starts=starts()[before_m:])
    tree = tree_view(meta) or []
    seen = {p["id"]: p for w in tree for p in w["panels"]}
    check("hidden_panels_not_shown", next((w["id"] for w in tree if w["selected"]), None) == selected_before
          and all(seen.get(p["panel"], {}).get("last_seen_at") is None for p in group_m[1:]),
          selected_before=selected_before, hidden=[seen.get(p["panel"]) for p in group_m[1:]])

    # One panel resumed alone from its own banner route: the other two still wait for Resume all.
    c11_json(meta, "restore", "run", "--panel", group_m[0]["panel"], check=False)
    wait_for(lambda: resumes_of(group_m[0]), 60)
    time.sleep(3)
    check("others_wait_after_one_resumes", all(offered(p) for p in group_m[1:]),
          waiting=[bool(offered(p)) for p in group_m[1:]])

    # The strip's Resume all (the other two), clicked by its accessibility id; then a second Resume all.
    clicked, ax_note = None, "no AX helper in the guest"
    if os.path.exists(AX_WALK):
        app_pid = (app_pids(meta) or [None])[0]
        sh(AX_WALK, str(app_pid), "activate", check=False)
        time.sleep(1.0)
        raw = sh(AX_WALK, str(app_pid), "ids", check=False) or ""
        found = []
        try:
            listed = json.loads(raw.strip().splitlines()[-1]) if raw.strip() else []
            if isinstance(listed, dict):
                ax_note = f"ax_walk: {listed}"
                listed = []
            found = [e for e in listed if isinstance(e, dict) and e.get("id") == "hc-mass-end-resume-all"]
            if not found and isinstance(listed, list):
                ax_note = {"ids": len(listed), "strip_like": [e for e in listed if isinstance(e, dict) and (
                    "restore" in str(e.get("id")) or "Resume" in str(e.get("title")) or "hc-" in str(e.get("id")))][:12]}
        except ValueError:
            ax_note = f"ax_walk output not JSON: {raw[:300]}"
        if found:
            (x, y), (w, h) = found[0]["position"], found[0]["size"]
            sh("/opt/homebrew/bin/cliclick", f"c:{round(x + w / 2)},{round(y + h / 2)}", check=False)
            clicked = {"x": round(x + w / 2), "y": round(y + h / 2)}
    if not clicked:
        c11_json(meta, "restore", "run", "--all", check=False)  # the same route; reported below
    check("resume_all_clicked_in_the_strip", bool(clicked), informational=not clicked, click=clicked, ax=ax_note)
    wait_for(lambda: all(resumes_of(p) for p in group_m), 60)
    time.sleep(3)
    rerun = c11_json(meta, "restore", "run", "--all", check=False) or {}
    time.sleep(quiet)
    m_resumes = {p["panel"]: resumes_of(p) for p in group_m}
    gaps = sorted(r[0]["ts"] for r in m_resumes.values() if r)
    check("resume_all_once_each_in_cwd", all(len(r) == 1 for r in m_resumes.values())
          and all(r[0].get("cwd") == p["cwd"] and (r[0].get("panel") or "").upper() == p["panel"]
                  for p, r in ((p, m_resumes[p["panel"]]) for p in group_m) if r),
          resumes={k: [{"cwd": x.get("cwd"), "panel": x.get("panel")} for x in v] for k, v in m_resumes.items()},
          gaps_s=[round(b - a, 2) for a, b in zip(gaps, gaps[1:])], second_run=rerun.get("panels"))

    # A: the setting on; nothing is clicked.
    sh("/usr/bin/defaults", "write", meta["bundle"], "c11.massSignalEnd.autoResume", "-bool", "true")
    time.sleep(2)
    a_pids, a_span = kill_roots(group_a, 0.6)
    a_done = wait_for(lambda: all(resumes_of(p) for p in group_a), 90)
    time.sleep(quiet)
    a_resumes = {p["panel"]: resumes_of(p) for p in group_a}
    a_mass = [e for e in tail("terminal.mass_signal_end") if (e.get("payload") or {}).get("auto_resume") is True]
    check("setting_on_resumes_without_a_click", bool(a_done) and all(len(r) == 1 for r in a_resumes.values())
          and all(r and r[0].get("cwd") == p["cwd"] for p, r in ((p, a_resumes[p["panel"]]) for p in group_a))
          and len(a_mass) == 1, killed=a_pids, kill_span_s=a_span, mass=a_mass,
          resumes={k: [x.get("cwd") for x in v] for k, v in a_resumes.items()})
    check("setting_on_no_workspace_switch", next((w["id"] for w in tree_view(meta) or [] if w["selected"]), None)
          == selected_before)
    sh("/usr/bin/defaults", "write", meta["bundle"], "c11.massSignalEnd.autoResume", "-bool", "false")

    # Exactly one terminal.ended_by_signal per ended panel, one terminal.mass_signal_end per mass end,
    # and no flag by c11 through all of it.
    ended = tail("terminal.ended_by_signal")
    per_panel = {}
    for e in ended:
        per_panel[(e.get("panel") or "").upper()] = per_panel.get((e.get("panel") or "").upper(), 0) + 1
    want = {p["panel"] for p in [single] + group_m + group_a}
    check("one_ended_by_signal_event_per_panel", set(per_panel) == want and all(v == 1 for v in per_panel.values())
          and all((e.get("payload") or {}).get("outcome") == "kept" and (e.get("payload") or {}).get("signal") == 15
                  for e in ended), per_panel=per_panel,
          found=sorted({(e.get("payload") or {}).get("found") for e in ended}))
    check("two_mass_ends_in_all", len(tail("terminal.mass_signal_end")) == 2)
    check("no_flag_by_c11_in_the_run", not c11_flags(), raised=c11_flags())

    # L: three roots end while c11 is quit (hc keeps them). The next launch finds the ends and records
    # them once, with no flag; the launch after that finds them decided and records none of them again.
    if len(panels) >= 10:
        group_l = panels[7:10]
        rows = diag_rows()
        l_pids = [(rows.get(p["panel"]) or {}).get("pid") for p in group_l]
        quit_([], name="quit-mass")
        t_kill = now()
        for i, pid in enumerate(l_pids):
            if pid:
                os.kill(int(pid), signal.SIGTERM)  # one recorded pid each
            if i + 1 < len(l_pids):
                time.sleep(0.6)
        kill_span = round(now() - t_kill, 2)
        before_l = len(starts())
        t_launch = now()
        relaunch([])
        wait_ready(meta, 60)
        l_ends = wait_for(lambda: all(offered(p) for p in group_l) and [offered(p) for p in group_l], 90)
        l_mass = wait_for(lambda: tail("terminal.mass_signal_end", t_launch), 20) or []
        time.sleep(quiet)
        l_ended = tail("terminal.ended_by_signal", t_launch)
        l_per = {}
        for e in l_ended:
            l_per[(e.get("panel") or "").upper()] = l_per.get((e.get("panel") or "").upper(), 0) + 1
        check("launch_found_mass_end_recorded_once", bool(l_ends) and len(l_mass) == 1 and not c11_flags(t_launch)
              and set((l_mass[0].get("payload") or {}).get("panels") or []) == {p["panel"] for p in group_l}
              and l_per == {p["panel"]: 1 for p in group_l}, killed=l_pids, kill_span_s=kill_span, mass=l_mass,
              found=sorted({(e.get("payload") or {}).get("found") for e in l_ended}), per_panel=l_per,
              flags=c11_flags(t_launch))
        check("launch_found_never_resumed_unasked", len(starts()) == before_l, starts=starts()[before_l:])
        quit_([], name="quit-mass-again")
        t_again = now()
        relaunch([])
        wait_ready(meta, 60)
        time.sleep(15)
        again_mass = tail("terminal.mass_signal_end", t_again)
        again_flags = c11_flags(t_again)
        again_ended = tail("terminal.ended_by_signal", t_again)
        still = [offered(p) for p in group_l]
        check("relaunch_never_records_again", not again_mass and not again_flags and not again_ended and all(still)
              and len(starts()) == before_l, mass=again_mass, flags=again_flags, ended=again_ended,
              still_offered=[bool(x) for x in still])

    failed = [k for k, v in asserts.items() if not v["pass"] and not v.get("informational")]
    summary = {"result": "fail" if failed else "pass", "mode": "mass", "failed": failed,
               "resumed": sum(len(v) for v in list(m_resumes.values()) + list(a_resumes.values())), "panels": len(panels),
               "assertions": asserts, "elapsed_s": round(now() - t0, 1),
               "diag_log_lines": [l for path in sorted(glob.glob(os.path.join(HOME, "Library/Logs/c11*/hc-diagnostics.log")))
                                  for l in grep_tail(path, r"outside_signal_end|mass_signal_end", 30)]}
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H196-SUMMARY-END===")


# ------------------------------------------------------- mode=marks (C11H-321)

MARKS_BIN = "/tmp/c11h321-bin"
MARKS_TTL = 300  # the transcripts' 5-minute prompt cache
FAKE_OPENCODE = "#!/usr/bin/python3\n# c11h321 stand-in: an opencode process that does nothing\nimport time\ntime.sleep(10 ** 6)\n"


def write_cache_transcript(cwd, sid, request_at):
    """A Claude-shaped transcript whose last request wrote a 5-minute prompt cache at `request_at`."""
    path = os.path.join(HOME, ".claude", "projects", slug(cwd), f"{sid}.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)

    def stamp(t):
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    u1, u2 = str(uuid.uuid4()), str(uuid.uuid4())
    base = {"isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid, "version": "2.1.200",
            "gitBranch": ""}
    lines = [
        {"type": "summary", "summary": "c11h321 synthetic session", "leafUuid": u2},
        {**base, "parentUuid": None, "type": "user", "uuid": u1, "timestamp": stamp(request_at),
         "message": {"role": "user", "content": "hello from c11h321"}},
        {**base, "parentUuid": u1, "type": "assistant", "uuid": u2, "timestamp": stamp(request_at),
         "message": {"role": "assistant", "model": "claude-opus-5-5", "id": "msg_" + uuid.uuid4().hex[:16],
                     "content": [{"type": "text", "text": "ok"}],
                     "usage": {"input_tokens": 2, "cache_read_input_tokens": 0,
                               "cache_creation_input_tokens": 4000, "output_tokens": 5,
                               "cache_creation": {"ephemeral_5m_input_tokens": 4000,
                                                  "ephemeral_1h_input_tokens": 0}}}},
    ]
    with open(path, "w") as f:
        for rec in lines:
            f.write(json.dumps(rec) + "\n")
    return path


def fleet_rows(meta):
    out = c11(meta, "fleet", "--json", check=False, timeout=20)
    try:
        return {(r.get("panel_id") or "").upper(): r for r in json.loads(out).get("panels", [])}
    except (ValueError, AttributeError):
        return {}


def send_text(meta, p, text, budget=20):
    deadline = now() + budget
    while True:
        r = subprocess.run([meta["cli"], "--socket", meta["socket"], "send", "--workspace", p["workspace"],
                            "--panel", p["panel"], text], capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return
        err = r.stdout + r.stderr
        if not ("hc_input_unavailable" in err or "inventory_pending" in err) or now() >= deadline:
            raise SystemExit(f"send to {p['panel']} failed ({r.returncode}): {err[-400:]}")
        time.sleep(0.5)


def shot(name):
    """The guest's screen, into the run's shared folder when it is mounted (sandbox-shot's convention)."""
    shared = "/Volumes/My Shared Files/out"
    directory = shared if os.path.isdir(shared) else STATE
    path = os.path.join(directory, f"c11h321-{name}.png")
    sh("/usr/sbin/screencapture", "-x", path, check=False, timeout=20)
    return path if os.path.exists(path) else None


def marks_seed(argv):
    """Expired, warm and no-evidence caches on resumed stub agents (shown and hidden), plus panel 1901's
    shape: a hidden opencode panel last seen working, with no conversation to resume."""
    meta = load("meta.json")
    panels = load("panels.json")
    if len(panels) < 6:
        raise SystemExit(f"marks mode needs n>=6 panels, have {len(panels)}")
    # (cache, whether the resumed agent reports idle at start). 0 and 1 are shown, the rest hidden.
    roles = [("expired", False), ("warm", True), ("expired", True), ("warm", False), ("none", False),
             ("expired", False)]
    # A whole second, stamped on both records: the app's cache clock and this harness's agree exactly.
    seeded_at = float(int(now()))
    for p, (role, start_idle) in zip(panels, roles):
        p["role"] = role
        p["start_idle"] = start_idle
        p["request_at"] = {"expired": seeded_at - 7200, "warm": seeded_at, "none": None}[role]
        if p["request_at"] is not None:
            write_cache_transcript(p["cwd"], p["conversation"], p["request_at"])
    with open("/tmp/c11h321-start-idle", "w") as f:
        f.write("\n".join(p["panel"] for p in panels if p["start_idle"]) + "\n")
    os.makedirs(MARKS_BIN, exist_ok=True)
    fake = os.path.join(MARKS_BIN, "opencode")
    with open(fake, "w") as f:
        f.write(FAKE_OPENCODE)
    os.chmod(fake, 0o755)
    host = panels[4]
    made = c11_json(meta, "new-panel", "--workspace", host["workspace"], "--cwd", host["cwd"])
    opencode = {"panel": find_uuid(made, ("panel_id", "surface_id", "id")).upper(), "workspace": host["workspace"],
                "visible": False, "cwd": host["cwd"], "role": "ended-working"}
    time.sleep(2.0)
    c11(meta, "set-agent", "--panel", opencode["panel"], "--type", "opencode")
    # What the opencode plugin does at a turn start, then the process itself in the foreground.
    send_text(meta, opencode, f'"${{C11_BUNDLED_CLI_PATH:-c11}}" agent-hook working && {fake}')
    deadline = now() + 20
    row = {}
    while now() < deadline:
        row = fleet_rows(meta).get(opencode["panel"], {})
        if row.get("lifecycle") == "working" and row.get("agent_type") == "opencode":
            break
        time.sleep(0.5)
    out = {"seeded_at": seeded_at, "roles": {p["panel"]: [p["role"], p["start_idle"]] for p in panels},
           "opencode_panel": opencode["panel"], "opencode_before_quit": {k: row.get(k) for k in ("agent_type", "lifecycle")}}
    save("panels.json", panels)
    save("marks.json", {**out, "opencode": opencode})
    print(json.dumps(out))
    if row.get("lifecycle") != "working":
        raise SystemExit(f"the opencode panel never drew working before the quit: {row}")


def persisted_activity(meta, panel_id):
    """The opencode panel's saved `activity` value and source in the session file the clean quit wrote."""
    with open(meta["session_file"]) as f:
        snap = json.load(f)
    found = {"panel": False}

    def rec(o):
        if isinstance(o, dict):
            if (o.get("id") or "").upper() == panel_id and "metadata" in o:
                found.update(panel=True, activity=(o.get("metadata") or {}).get("activity"),
                             source=(o.get("metadataSources") or {}).get("activity"))
                return
            for v in o.values():
                rec(v)
        elif isinstance(o, list):
            for v in o:
                rec(v)
    rec(snap)
    return found


def marks_persisted(argv):
    meta = load("meta.json")
    out = persisted_activity(meta, load("marks.json")["opencode"]["panel"])
    save("marks-persisted.json", out)
    print(json.dumps(out))


def resume_starts(rows, t0):
    """Panel -> the conversation ids its stub was started with as `--resume <id>` at or after t0, in order."""
    out = {}
    for r in rows:
        if r.get("event") == "start" and (r.get("ts") or 0) >= t0:
            rid = arg_after(r.get("argv") or [], "--resume")
            if rid:
                out.setdefault((r.get("panel") or "").upper(), []).append(rid.lower())
    return out


def resumed_once_verdict(panels, starts):
    """Each stub panel resumed exactly once, with its own conversation id."""
    wrong = {p["panel"]: starts.get(p["panel"], []) for p in panels
             if starts.get(p["panel"], []) != [p["conversation"].lower()]}
    return not wrong, {"wrong": wrong}


def ended_verdict(samples, panel, diag_row, resumed_ids, within=10):
    """The ended opencode panel. In fleet from its first appearance on, and hc diagnostics report it `ended`, both
    within `within` samples of the launch. Before hc reports the end it may still draw the working it was restored
    with; from that sample on it never draws working, and it ends idle. The final diagnostics list it as `ended`;
    it is never resumed. A missing observation fails."""
    seen = [s["lc"].get(panel) for s in samples]
    hc = [s.get("hc") for s in samples]
    first = next((i for i, v in enumerate(seen) if v is not None), None)
    ended_at = next((i for i, v in enumerate(hc) if v == "ended"), None)
    listed = first is not None and first < within and all(v is not None for v in seen[first:])
    after_end = seen[ended_at + 1:] if ended_at is not None else []
    detail = {"seen": sorted({v or "none" for v in seen}), "first_listed_sample": first,
              "ended_reported_sample": ended_at,
              "ended_reported_s": samples[ended_at]["t"] if ended_at is not None else None,
              "working_before_end": [samples[i]["t"] for i, v in enumerate(seen[:(ended_at or 0) + 1]) if v == "working"],
              "seen_after_end": sorted({v or "none" for v in after_end}),
              "final": seen[-1] if seen else None, "hc_lifecycle": (diag_row or {}).get("lifecycle"),
              "in_diagnostics": diag_row is not None, "resumed": resumed_ids}
    ok = (listed and ended_at is not None and ended_at < within and "working" not in after_end
          and seen[-1] == "idle" and diag_row is not None and diag_row.get("lifecycle") == "ended" and not resumed_ids)
    return ok, detail


def marks_collect(argv):
    """Watch `c11 fleet` after the resume launch (nothing is selected or read), then assert. Times are measured
    from each panel's own resume start. An agent that reports nothing at start keeps the shell's working for
    C11-398's window (120 s) unless its cache is cold; one that reports idle (Claude's SessionStart) rests at once."""
    o = opts_of(argv)
    meta = load("meta.json")
    panels = load("panels.json")
    marks = load("marks.json")
    persisted = load("marks-persisted.json", {})
    opencode = marks["opencode"]
    t0 = load("relaunch.json")["launched_at"]
    window = 120 + 30  # C11-398's window plus three sweeps
    budget = float(o.get("cold_budget", 40))  # a resumed panel's expired cache: two sweeps and a transcript read
    warm_cold_at = marks["seeded_at"] + MARKS_TTL
    deadline = max(warm_cold_at + float(o.get("late", 40)), now() + 60)
    probe = panels[0]  # shown, expired, reports nothing at start: the agent that takes a turn after the resume
    samples, first_cold, shots, resume_at = [], {}, {}, {}
    work = {"state": "waiting"}

    def resumes():
        for r in ledger():
            if r.get("event") == "start" and (r.get("ts") or 0) >= t0 and arg_after(r.get("argv") or [], "--resume"):
                resume_at.setdefault((r.get("panel") or "").upper(), r["ts"])

    while now() < deadline:
        resumes()
        # Diagnostics first, then fleet: a mark read after hc reported the end must already show it.
        hc_now = {(r.get("panel_id") or "").upper(): r.get("lifecycle")
                  for r in (hc_diag(meta) or {}).get("panels", [])}.get(opencode["panel"])
        rows = fleet_rows(meta)
        t = now()
        sample = {"t": round(t - t0, 1), "ts": t, "hc": hc_now,
                  "lc": {p["panel"]: rows.get(p["panel"], {}).get("lifecycle") for p in panels + [opencode]},
                  "cache": {p["panel"]: (rows.get(p["panel"], {}).get("prompt_cache") or {}).get("state")
                            for p in panels}}
        samples.append(sample)
        for p in panels:
            if sample["lc"][p["panel"]] == "cold" and p["panel"] not in first_cold:
                first_cold[p["panel"]] = t
        expired = [p for p in panels if p["role"] == "expired"]
        if "expired" not in shots and all(p["panel"] in first_cold for p in expired):
            shots["expired"] = shot("expired-cold")
        lc_probe = sample["lc"][probe["panel"]]
        started = resume_at.get(probe["panel"])
        if work["state"] == "waiting" and started and (probe["panel"] in first_cold or t - started > window):
            send_text(meta, probe, "C11H321-WORK")
            work = {"state": "sent", "sent_at": now(), "probe_was_cold": probe["panel"] in first_cold}
        elif work["state"] == "sent" and lc_probe == "working":
            work.update(state="working", working_after_s=round(t - work["sent_at"], 1))
            shots["working"] = shot("resumed-agent-working")
            send_text(meta, probe, "C11H321-IDLE")
            work["idle_sent_at"] = now()
        elif work["state"] == "working" and lc_probe == "cold":
            work.update(state="cold-again", cold_again_after_s=round(t - work["idle_sent_at"], 1))
        warm = [p for p in panels if p["role"] == "warm"]
        if (now() > warm_cold_at + 20 and all(p["panel"] in first_cold for p in expired + warm)
                and work["state"] == "cold-again"):
            break
        time.sleep(2.0)
    resumes()
    shots["end"] = shot("warm-turned-cold")
    diag = {(r.get("panel_id") or "").upper(): r for r in (hc_diag(meta) or {}).get("panels", [])}
    hooks = [r for r in ledger() if r.get("event") == "agent-hook"]

    asserts = {}

    def check(name, ok, informational=False, **detail):
        asserts[name] = {"pass": bool(ok), "informational": informational, **detail}
        print(f"{'INFO' if informational else 'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:700]}",
              flush=True)

    def seen(p, after=None, before=None):
        return sorted({s["lc"][p["panel"]] or "none" for s in samples
                       if (after is None or s["ts"] >= after) and (before is None or s["ts"] < before)})

    def since_resume(p, ts):
        return round(ts - resume_at[p["panel"]], 1) if ts and p["panel"] in resume_at else None

    starts = resume_starts(ledger(), t0)
    ok, detail = resumed_once_verdict(panels, starts)
    check("resumed_every_stub", ok, **detail)
    # The scenario itself: the clean quit saved the opencode panel's working, as it saved 1901's.
    check("opencode_saved_working", persisted.get("activity") == "working", persisted=persisted)
    expired = [p for p in panels if p["role"] == "expired"]
    check("expired_cold_at_once",
          all(p["panel"] in first_cold and since_resume(p, first_cold[p["panel"]]) is not None
              and since_resume(p, first_cold[p["panel"]]) <= budget for p in expired),
          budget_s=budget,
          seconds_after_resume={p["panel"]: since_resume(p, first_cold.get(p["panel"])) for p in expired},
          reports_idle_at_start={p["panel"]: p["start_idle"] for p in expired},
          seen_before_cold={p["panel"]: seen(p, after=resume_at.get(p["panel"]), before=first_cold.get(p["panel"]))
                            for p in expired})
    warm = [p for p in panels if p["role"] == "warm"]
    # A warm panel rests (idle) from its start edge, or once C11-398's window ends, until its cache expires.
    rest = {p["panel"]: (resume_at.get(p["panel"], t0) + (10 if p["start_idle"] else window)) for p in warm}
    check("warm_idle_until_cold_at",
          all(seen(p, after=rest[p["panel"]], before=warm_cold_at - 5) == ["idle"] for p in warm),
          cold_at=iso(warm_cold_at),
          seen={p["panel"]: seen(p, after=rest[p["panel"]], before=warm_cold_at - 5) for p in warm},
          before_rest={p["panel"]: seen(p, after=resume_at.get(p["panel"]), before=rest[p["panel"]]) for p in warm})
    check("warm_cold_on_time",
          all(p["panel"] in first_cold and warm_cold_at - 1 <= first_cold[p["panel"]] <= warm_cold_at + 25
              for p in warm),
          seconds_after_cold_at={p["panel"]: round(first_cold[p["panel"]] - warm_cold_at, 1)
                                 if p["panel"] in first_cold else None for p in warm})
    none = [p for p in panels if p["role"] == "none"]
    check("no_evidence_rests_idle", all(seen(p, after=resume_at.get(p["panel"], t0) + window) == ["idle"] for p in none),
          seen={p["panel"]: seen(p, after=resume_at.get(p["panel"], t0) + window) for p in none})
    ok, detail = ended_verdict(samples, opencode["panel"], diag.get(opencode["panel"]),
                               starts.get(opencode["panel"], []))
    check("ended_opencode_never_working", ok, **detail)
    check("resumed_agent_working_then_cold", work["state"] == "cold-again", work=work, hooks=hooks[-6:])

    failed = [k for k, v in asserts.items() if not v["pass"] and not v.get("informational")]
    summary = {"result": "pass" if not failed else "fail", "resumed": len(set(resume_at) & {p["panel"] for p in panels}),
               "panels": len(panels), "failed": failed, "assertions": asserts, "shots": shots,
               "launched_at": iso(t0), "warm_cold_at": iso(warm_cold_at),
               "roles": {p["panel"]: [p["role"], p["start_idle"], p["visible"]] for p in panels},
               "opencode": opencode["panel"], "samples": [{k: v for k, v in s.items() if k != "ts"} for s in samples]}
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary))
    print("===C11H196-SUMMARY-END===")


# --------------------------------------------------- mode=lifecycle (C11H-322, C11H-323)

LC_HOOKS = "/tmp/c11h322-hooks"
# Not working: at the prompt (idle), its cache expired (cold), or a finished turn's unread notification (waiting).
RESTING = ("idle", "cold", "waiting")
LC_DOWN = "/tmp/c11h322-down"
LC_BIN = "/tmp/c11h322-bin"
# An opencode stand-in with no hooks: hc's status is all it reports. It works until c11 goes down, then is done.
LC_OPENCODE = r'''#!/usr/bin/python3 -u
import os, sys, time
def osc(state):
    sys.stdout.write("\x1b]7501;state=%s:app=opencode\x1b\\" % state)
    sys.stdout.flush()
osc("working")
while not os.path.exists("/tmp/c11h322-down"):
    time.sleep(0.2)
osc("done")
open("/tmp/c11h322-opencode-done", "w").write(str(time.time()))
time.sleep(10 ** 6)
'''

# A Codex stand-in (C11H-322 repair 1): its own causal conversation (`capture-runtime`), hc's `working` at T1, then
# Codex's own notify turn end at T2 > T1 while c11 is up. hc keeps that `working` (a background terminal, C11H-123).
LC_CODEX = r'''#!/usr/bin/python3 -u
import base64, json, os, subprocess, sys, time
thread = os.environ["C11H322_CODEX_THREAD"]
cli = os.environ.get("C11_BUNDLED_CLI_PATH") or "c11"
subprocess.run([cli, "conversation", "capture-runtime"], env=dict(os.environ, CODEX_THREAD_ID=thread), check=False)
sys.stdout.write("\x1b]7501;state=working:app=codex\x1b\\")
sys.stdout.flush()
time.sleep(3.0)
payload = base64.b64encode(json.dumps({"type": "agent-turn-complete", "thread-id": thread}).encode()).decode()
env = lambda k: os.environ.get("C11_" + k) or os.environ.get("CMUX_" + k) or ""
done = subprocess.run([cli, "notify", "--title", "Codex", "--workspace", env("WORKSPACE_ID"),
                       "--surface", env("SURFACE_ID")],
                      env=dict(os.environ, C11_CODEX_NOTIFY_PAYLOAD_B64=payload), capture_output=True, text=True)
open("/tmp/c11h322-codex-ended", "w").write(json.dumps({"ts": time.time(), "rc": done.returncode,
                                                        "out": (done.stdout + done.stderr)[-300:],
                                                        "hc_session": os.environ.get("HC_SESSION"),
                                                        "hc_socket": os.environ.get("HC_SOCKET")}))
time.sleep(10 ** 6)
'''


def agent_rows(meta):
    out = c11(meta, "agents", "--json", check=False, timeout=20)
    try:
        return {(r.get("panel_id") or "").upper(): r for r in json.loads(out).get("panels", [])}
    except (ValueError, AttributeError):
        return {}


def lc_seed(argv):
    """Survivor roles. Claude stubs (each its own causal conversation): two end their turn while c11 is down,
    two stay mid-turn, one rests before the quit. A hidden opencode panel with no hooks and no conversation
    (no causal owner) is saved working and is done while c11 is down."""
    meta = load("meta.json")
    panels = load("panels.json")
    if len(panels) < 6:
        raise SystemExit(f"lifecycle mode needs n>=6 panels, have {len(panels)}")
    roles = ["ended", "midturn", "ended", "rested", "midturn", "rested"]
    for p, role in zip(panels, roles):
        p["role"] = role
    fresh = agent_rows(meta)
    started = {p["panel"]: {k: fresh.get(p["panel"], {}).get(k) for k in ("state", "connection", "confirmation")}
               for p in panels}
    for p in panels:
        send_text(meta, p, "C11H322-WORK")
    time.sleep(1.0)
    for p in panels:
        if p["role"] == "rested":
            send_text(meta, p, "C11H322-DONE")
        elif p["role"] == "ended":
            send_text(meta, p, "C11H322-DONE-WHEN-DOWN")
    os.makedirs(LC_BIN, exist_ok=True)
    fake = os.path.join(LC_BIN, "opencode")
    with open(fake, "w") as f:
        f.write(LC_OPENCODE)
    os.chmod(fake, 0o755)
    host = panels[4]
    made = c11_json(meta, "new-panel", "--workspace", host["workspace"], "--cwd", host["cwd"])
    opencode = {"panel": find_uuid(made, ("panel_id", "surface_id", "id")).upper(), "workspace": host["workspace"],
                "visible": False, "cwd": host["cwd"], "role": "opencode-ended"}
    codex_fake = os.path.join(LC_BIN, "codex")
    with open(codex_fake, "w") as f:
        f.write(LC_CODEX)
    os.chmod(codex_fake, 0o755)
    made = c11_json(meta, "new-panel", "--workspace", host["workspace"], "--cwd", host["cwd"])
    codex = {"panel": find_uuid(made, ("panel_id", "surface_id", "id")).upper(), "workspace": host["workspace"],
             "visible": False, "cwd": host["cwd"], "role": "codex-ended-before-quit"}
    time.sleep(2.0)
    c11(meta, "set-agent", "--panel", opencode["panel"], "--type", "opencode")
    send_text(meta, opencode, f'"${{C11_BUNDLED_CLI_PATH:-c11}}" agent-hook working && {fake}')
    c11(meta, "set-agent", "--panel", codex["panel"], "--type", "codex")
    send_text(meta, codex, f"C11H322_CODEX_THREAD={uuid.uuid4()} {codex_fake}")
    # A turn end leaves an unread notification: a rested stub reads `waiting` (or idle once seen).
    want = {p["panel"]: (RESTING if p["role"] == "rested" else ("working",)) for p in panels}
    want[opencode["panel"]] = ("working",)
    deadline = now() + 30
    rows = {}
    while now() < deadline:
        rows = fleet_rows(meta)
        if all(rows.get(k, {}).get("lifecycle") in v for k, v in want.items()) \
                and os.path.exists("/tmp/c11h322-codex-ended"):
            break
        time.sleep(0.5)
    before = {k: rows.get(k, {}).get("lifecycle") for k in [*want, codex["panel"]]}
    codex_journal = {f: agent_rows(meta).get(codex["panel"], {}).get(f) for f in ("state", "connection", "confirmation")}
    try:
        with open("/tmp/c11h322-codex-ended") as f:
            codex_notify = json.load(f)
    except (OSError, ValueError):
        codex_notify = None
    out = {"roles": {p["panel"]: p["role"] for p in panels}, "opencode": opencode["panel"], "codex": codex["panel"],
           "fresh_start_journal": started, "before_quit": before, "codex_journal_before_quit": codex_journal,
           "codex_notify": codex_notify}
    save("panels.json", panels)
    save("lifecycle.json", {**out, "opencode": opencode, "codex": codex})
    print(json.dumps(out))
    if any(before[k] not in v for k, v in want.items()):
        raise SystemExit(f"the panels never reached their roles before the quit: want {want}, got {before}")


def lc_down(argv):
    """c11 is down (clean quit). The ended stubs and the opencode stand-in end their turns now, as an agent does
    while c11 is away: hc keeps their `done`, and the Claude stubs' Stop hooks find no socket and spool."""
    meta = load("meta.json")
    panels = load("panels.json")
    lc = load("lifecycle.json")
    t0 = now()
    open(LC_DOWN, "w").write(str(t0))
    ended = {p["panel"] for p in panels if p["role"] == "ended"}
    deadline = now() + 30
    stops = {}
    while now() < deadline:
        stops = {(r.get("panel") or "").upper(): r for r in ledger()
                 if r.get("event") == "claude-hook" and r.get("sub") == "stop" and (r.get("ts") or 0) >= t0}
        if ended <= set(stops) and os.path.exists("/tmp/c11h322-opencode-done"):
            break
        time.sleep(0.5)
    os.remove(LC_DOWN)
    persisted = persisted_activity(meta, lc["opencode"]["panel"])
    out = {"down_s": round(now() - t0, 1), "stops": {k: {"rc": v.get("rc"), "out": v.get("out")} for k, v in stops.items()},
           "opencode_done": os.path.exists("/tmp/c11h322-opencode-done"), "opencode_saved": persisted}
    save("lifecycle-down.json", out)
    print(json.dumps(out))
    if not ended <= set(stops):
        raise SystemExit(f"ended stubs did not report their turn end while c11 was down: {out}")


def lc_sample(meta, panels, extra=()):
    rows, journal = fleet_rows(meta), agent_rows(meta)
    keys = [p["panel"] for p in panels] + list(extra)
    return {"ts": now(), "lc": {k: rows.get(k, {}).get("lifecycle") for k in keys},
            "cache": {k: (rows.get(k, {}).get("prompt_cache") or {}).get("state") for k in keys},
            "journal": {k: "/".join(str(journal.get(k, {}).get(f)) for f in ("state", "connection", "confirmation"))
                        for k in keys}}


def lc_survivors(argv):
    """After the relaunch (no host end: every terminal survived). Nothing is selected or read."""
    meta = load("meta.json")
    panels = load("panels.json")
    lc = load("lifecycle.json")
    down = load("lifecycle-down.json", {})
    opencode = lc["opencode"]["panel"]
    codex = (lc.get("codex") or {}).get("panel")
    extra = [opencode] + ([codex] if codex else [])
    t0 = load("relaunch.json")["launched_at"]
    samples = []
    observe = float(opts_of(argv).get("observe", 30))
    while now() < t0 + observe:
        samples.append(lc_sample(meta, panels, extra))
        time.sleep(2.0)
    midturn = [p for p in panels if p["role"] == "midturn"]
    for p in midturn:
        send_text(meta, p, "C11H322-DONE")
    sent = now()
    while now() < sent + 15:
        samples.append(lc_sample(meta, panels, extra))
        if all(samples[-1]["lc"][p["panel"]] in RESTING for p in midturn):
            break
        time.sleep(2.0)
    asserts = {}

    def check(name, ok, informational=False, **detail):
        asserts[name] = {"pass": bool(ok), "informational": informational, **detail}
        print(f"{'INFO' if informational else 'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:700]}",
              flush=True)

    def seen(k, before=None, after=None):
        return [s["lc"][k] for s in samples if (before is None or s["ts"] < before) and (after is None or s["ts"] >= after)]

    def last(k):
        # No samples is a failed check, never an IndexError.
        values = seen(k)
        return values[-1] if values else None

    for p in panels:
        p["seen"] = seen(p["panel"])
    ended = [p for p in panels if p["role"] == "ended"]
    check("survivor_ended_while_down_never_working",
          all("working" not in seen(p["panel"]) and last(p["panel"]) in RESTING for p in ended),
          seen={p["panel"]: sorted({v or "none" for v in seen(p["panel"])}) for p in ended})
    oc = seen(opencode)
    check("opencode_saved_working", (down.get("opencode_saved") or {}).get("activity") == "working",
          saved=down.get("opencode_saved"))
    check("opencode_done_while_down_never_working", "working" not in oc and last(opencode) in RESTING,
          seen=sorted({v or "none" for v in oc}), first=oc[:3])
    if codex:
        # The staging itself: after the relaunch hc still holds the stand-in's `working`, stamped before Codex's
        # own turn end. Found by its foreground argv in hc's own records (`c11 hc ls`).
        def hc_records(node):
            if isinstance(node, dict):
                if "status" in node and "c11h322-bin/codex" in json.dumps(node):
                    yield node
                for v in node.values():
                    yield from hc_records(v)
            elif isinstance(node, list):
                for v in node:
                    yield from hc_records(v)
        # `c11 hc` runs only inside a c11 terminal's hc session: borrow the one the stand-in recorded.
        notify = lc.get("codex_notify") or {}
        hc_env = dict(os.environ, HC_SESSION=notify.get("hc_session") or "", HC_SOCKET=notify.get("hc_socket") or "")

        def hc_read(*args):
            r = subprocess.run([meta["cli"], "--socket", meta["socket"], "hc", *args], env=hc_env,
                               capture_output=True, text=True, timeout=20)
            try:
                return json.loads(r.stdout)
            except ValueError:
                print(f"hc {args}: rc={r.returncode} {(r.stdout + r.stderr)[-300:]}", flush=True)
                return None
        hc_ls = hc_read("ls")
        held = [r for r in hc_records(hc_ls) if isinstance(r.get("status"), dict)]
        if not held:
            print(f"hc ls held no stand-in record: {json.dumps(hc_ls)[:900]}", flush=True)
        status = held[-1]["status"] if held else {}
        hc_state = status.get("state")
        hc_ms = held[-1].get("status_ms") if held else None
        if held and hc_ms is None and held[-1].get("address"):
            # `ls` may omit hc's status time; `get` on the terminal carries it.
            try:
                got = hc_read("get", str(held[-1]["address"])) or {}
                hc_ms = next((r.get("status_ms") for r in hc_records(got)), None) or got.get("status_ms")
            except (ValueError, AttributeError):
                pass
        ended_ms = (notify.get("ts") or 0) * 1000
        check("codex_hc_holds_working_older_than_turn_end",
              hc_state == "working" and isinstance(hc_ms, (int, float)) and 0 <= hc_ms < ended_ms,
              hc_state=hc_state, hc_status_ms=hc_ms, notify_ms=round(ended_ms), records=len(held))
        cx = seen(codex)
        # Codex's own notify ended its turn (T2) after hc's `working` (T1); hc still says working (C11H-123).
        check("codex_turn_ended_before_quit_never_working", "working" not in cx and last(codex) in RESTING,
              seen=sorted({v or "none" for v in cx}), first=cx[:3], before_quit=lc.get("before_quit", {}).get(codex),
              journal_before_quit=lc.get("codex_journal_before_quit"), notify=lc.get("codex_notify"))
    first_working = {p["panel"]: next((round(s["ts"] - t0, 1) for s in samples if s["lc"][p["panel"]] == "working"), None)
                     for p in midturn}
    check("survivor_mid_turn_reads_working",
          all(first_working[p["panel"]] is not None and first_working[p["panel"]] <= 20
              and not set(seen(p["panel"], after=t0 + 20, before=sent)) & set(RESTING) for p in midturn),
          first_working_s=first_working,
          seen_before_done={p["panel"]: sorted({v or "none" for v in seen(p["panel"], before=sent)}) for p in midturn})
    check("survivor_mid_turn_then_done_rests",
          all(last(p["panel"]) in RESTING for p in midturn),
          final={p["panel"]: seen(p["panel"])[-1:] for p in midturn})
    rested = [p for p in panels if p["role"] == "rested"]
    check("survivor_rested_never_working", all("working" not in seen(p["panel"], before=sent) for p in rested),
          seen={p["panel"]: sorted({v or "none" for v in seen(p["panel"], before=sent)}) for p in rested})
    check("survivor_journal_after_relaunch", True, informational=True,
          journal={k: sorted({s["journal"][k] for s in samples}) for k in samples[0]["journal"]} if samples else {})
    save("lifecycle-survivors.json", {"asserts": asserts, "samples": samples})
    save("panels.json", panels)
    return asserts


def lc_caches(argv):
    """Before the host end: an expired prompt cache on two resumed sessions, a warm one on two."""
    panels = load("panels.json")
    stamped = float(int(now()))
    for p, role in zip(panels, ["expired", "warm", "expired", "warm", "none", "none"]):
        p["cache"] = role
        if role != "none":
            write_cache_transcript(p["cwd"], p["conversation"], stamped - 7200 if role == "expired" else stamped)
    save("panels.json", panels)
    save("lifecycle-caches.json", {"stamped": stamped})


def lc_resumed(argv):
    """After the host end and the resume launch: each stub resumes once and reports SessionStart (source resume)
    through the real hook. Its journal rests live at once, and an expired cache draws cold."""
    o = opts_of(argv)
    meta = load("meta.json")
    panels = load("panels.json")
    t0 = load("relaunch.json")["launched_at"]
    budget = float(o.get("cold_budget", 40))
    deadline = now() + float(o.get("observe", 75))
    samples, resume_at, first = [], {}, {"live_idle": {}, "cold": {}}
    while now() < deadline:
        for r in ledger():
            if r.get("event") == "start" and (r.get("ts") or 0) >= t0 and arg_after(r.get("argv") or [], "--resume"):
                resume_at.setdefault((r.get("panel") or "").upper(), r["ts"])
        sample = lc_sample(meta, panels)
        samples.append(sample)
        for p in panels:
            k = p["panel"]
            if sample["journal"][k] == "idle/live/confirmed":
                first["live_idle"].setdefault(k, sample["ts"])
            if sample["lc"][k] == "cold":
                first["cold"].setdefault(k, sample["ts"])
        expired = [p["panel"] for p in panels if p["cache"] == "expired"]
        if len(resume_at) >= len(panels) and all(p["panel"] in first["live_idle"] for p in panels) \
                and all(k in first["cold"] for k in expired) and now() > max(resume_at.values()) + 30:
            break
        time.sleep(2.0)
    hooks = [r for r in ledger() if r.get("event") == "claude-hook" and r.get("sub") == "session-start"
             and (r.get("ts") or 0) >= t0]
    asserts = {}

    def check(name, ok, informational=False, **detail):
        asserts[name] = {"pass": bool(ok), "informational": informational, **detail}
        print(f"{'INFO' if informational else 'PASS' if ok else 'FAIL'} {name} {json.dumps(detail, default=str)[:700]}",
              flush=True)

    def after(k, ts):
        return round(ts - resume_at[k], 1) if ts and k in resume_at else None

    starts = resume_starts(ledger(), t0)
    ok, detail = resumed_once_verdict(panels, starts)
    check("resumed_every_stub", ok, **detail)
    check("resume_session_start_hook_ran",
          {(h.get("panel") or "").upper() for h in hooks if h.get("rc") == 0} >= {p["panel"] for p in panels},
          hooks={(h.get("panel") or "").upper(): [h.get("rc"), h.get("extra"), h.get("interactive_pid")] for h in hooks})
    check("resumed_journal_rests_live",
          all(after(p["panel"], first["live_idle"].get(p["panel"])) is not None
              and after(p["panel"], first["live_idle"][p["panel"]]) <= 20 for p in panels),
          seconds_after_resume={p["panel"]: after(p["panel"], first["live_idle"].get(p["panel"])) for p in panels},
          journal={p["panel"]: sorted({s["journal"][p["panel"]] for s in samples}) for p in panels})
    expired = [p for p in panels if p["cache"] == "expired"]
    check("resumed_expired_cache_draws_cold",
          all(after(p["panel"], first["cold"].get(p["panel"])) is not None
              and after(p["panel"], first["cold"][p["panel"]]) <= budget for p in expired),
          budget_s=budget, seconds_after_resume={p["panel"]: after(p["panel"], first["cold"].get(p["panel"])) for p in expired},
          seen={p["panel"]: sorted({s["lc"][p["panel"]] or "none" for s in samples}) for p in expired})
    warm = [p for p in panels if p["cache"] == "warm"]
    check("resumed_warm_cache_rests_idle",
          all(not {s["lc"][p["panel"]] for s in samples if p["panel"] in resume_at and s["ts"] >= resume_at[p["panel"]] + 10}
              - {"idle", "waiting"} for p in warm),
          seen={p["panel"]: sorted({s["lc"][p["panel"]] or "none" for s in samples
                                    if p["panel"] in resume_at and s["ts"] >= resume_at[p["panel"]] + 10}) for p in warm})
    save("lifecycle-resumed.json", {"asserts": asserts, "samples": samples})
    return asserts


def lc_run(argv):
    o = opts_of(argv)
    t = now()
    timings, asserts = {}, {}
    phases = (("prepare", prepare, argv + ["n=6"]), ("hooks", lambda a: open(LC_HOOKS, "w").write("1"), []),
              ("setup", setup, []), ("seed", lc_seed, []), ("quit", quit_, []), ("down", lc_down, []),
              ("relaunch", relaunch, []),
              ("survivors", lc_survivors, [f"{k}={v}" for k, v in o.items() if k == "observe"]),
              ("caches", lc_caches, []), ("quit2", lambda a: quit_(a, "quit2"), []), ("hostend", hostend, []),
              ("relaunch2", relaunch, []),
              ("resumed", lc_resumed, [f"{k}={v}" for k, v in o.items() if k == "cold_budget"]))
    for name, fn, args in phases:
        p = now()
        print(f"--- phase {name}", flush=True)
        result = fn(args)
        if name in ("survivors", "resumed"):
            asserts.update(result)
        timings[name] = round(now() - p, 1)
    panels = load("panels.json")
    failed = [k for k, v in asserts.items() if not v["pass"] and not v.get("informational")]
    summary = {"result": "pass" if not failed else "fail", "resumed": len(resume_starts(ledger(), load("relaunch.json")["launched_at"])),
               "panels": len(panels), "failed": failed, "assertions": asserts,
               "roles": {p["panel"]: [p["role"], p.get("cache"), p["visible"]] for p in panels},
               "seed": load("lifecycle.json"), "down": load("lifecycle-down.json"),
               "phase_seconds": timings, "total_s": round(now() - t, 1)}
    save("summary.json", summary)
    print("===C11H196-SUMMARY-BEGIN===")
    print(json.dumps(summary, default=str))
    print("===C11H196-SUMMARY-END===")


def timeline(events, t0):
    buckets = {}
    for e in events:
        b = int((e["_ts"] - t0) // 10) * 10
        buckets[b] = buckets.get(b, 0) + 1
    return {f"{b}-{b + 10}s": buckets[b] for b in sorted(buckets)}


def reasons(events):
    counts = {}
    for e in events:
        p = e.get("payload") or {}
        key = " | ".join(str(p.get(k)) for k in ("decision", "skip_code", "reason", "mode"))
        counts[key] = counts.get(key, 0) + 1
    return counts


def tail(path, n):
    if not path or not os.path.exists(path):
        return []
    with open(path, errors="replace") as f:
        return [l.rstrip("\n")[:400] for l in f.readlines()[-n:]]


def grep_tail(path, pattern, n):
    if not path or not os.path.exists(path):
        return []
    rx = re.compile(pattern, re.I)
    with open(path, errors="replace") as f:
        return [l.rstrip("\n")[:400] for l in f if rx.search(l)][-n:]


def run_all(argv):
    o = opts_of(argv)
    t = now()
    timings = {}
    stress = []
    if o.get("mode") == "mass":
        # C11H-235: several outside signals at once.
        for name, fn, args in (("prepare", prepare, argv + ["n=10"]), ("setup", setup, ["login=1"]),
                               ("mass", mass_end, [f"{k}={v}" for k, v in o.items() if k == "quiet"])):
            p = now()
            print(f"--- phase {name}", flush=True)
            fn(args)
            timings[name] = round(now() - p, 1)
        print(json.dumps({"phase_seconds": timings, "total_s": round(now() - t, 1)}))
        return
    if o.get("mode") == "lifecycle":
        # C11H-322/323: survivors across a relaunch take a real read; a resumed session rests live at once.
        lc_run(argv)
        return
    if o.get("mode") == "marks":
        # C11H-321: the sidebar marks a host end restores (prompt cache cold, no phantom working).
        for name, fn, args in (("prepare", prepare, argv + ["n=6"]), ("setup", setup, []),
                               ("seed", marks_seed, []), ("quit", quit_, []), ("persisted", marks_persisted, []),
                               ("hostend", hostend, []), ("relaunch", relaunch, []),
                               ("collect", marks_collect, [f"{k}={v}" for k, v in o.items()
                                                           if k in ("late", "cold_budget")])):
            p = now()
            print(f"--- phase {name}", flush=True)
            fn(args)
            timings[name] = round(now() - p, 1)
        print(json.dumps({"phase_seconds": timings, "total_s": round(now() - t, 1)}))
        return
    if o.get("mode") == "signal":
        # C11H-232: outside signals at single roots instead of a host end.
        for name, fn, args in (("prepare", prepare, argv + ["n=4"]), ("setup", setup, ["layout=tabs"]),
                               ("signal", signal_end, [f"{k}={v}" for k, v in o.items() if k == "quiet"])):
            p = now()
            print(f"--- phase {name}", flush=True)
            fn(args)
            timings[name] = round(now() - p, 1)
        print(json.dumps({"phase_seconds": timings, "total_s": round(now() - t, 1)}))
        return
    try:
        for name, fn, args in (("prepare", prepare, argv),
                               ("setup", setup, [f"{k}={v}" for k, v in o.items() if k == "layout"]),
                               ("quit", quit_, []), ("hostend", hostend, []), ("scrub", scrub, []),
                               ("relaunch", relaunch, [f"{k}={v}" for k, v in o.items() if k in ("noresume", "hidetranscripts")]),
                               ("collect", collect, [f"{k}={v}" for k, v in o.items()
                                                     if k in ("t", "quiet", "cpu", "noresume", "hidetranscripts")]),
                               ("again", again, [f"{k}={v}" for k, v in o.items() if k in ("t2", "noresume", "hidetranscripts")])):
            if name == "again" and o.get("again") != "1":
                continue
            p = now()
            print(f"--- phase {name}", flush=True)
            if name == "quit" and int(o.get("stress", "0")) > 0:
                # stress=N (C11H-206): N busy loops from the quit on, so the restart and the resumes run under
                # load, as on a loaded Mac. Setup runs unloaded so the harness stays inside its own waits.
                stress = [subprocess.Popen(["/bin/sh", "-c", "while :; do :; done"]) for _ in range(int(o["stress"]))]
            fn(args)
            timings[name] = round(now() - p, 1)
    finally:
        for proc in stress:
            proc.kill()
            proc.wait()
        if o.get("hidetranscripts") == "1":
            hold_transcripts(False)
    print(json.dumps({"phase_seconds": timings, "total_s": round(now() - t, 1)}))


if __name__ == "__main__":
    os.makedirs(STATE, exist_ok=True)
    phase, rest = sys.argv[1], sys.argv[2:]
    {"prepare": prepare, "setup": setup, "quit": quit_, "hostend": hostend, "scrub": scrub,
     "relaunch": relaunch, "collect": collect, "again": again, "signal": signal_end, "mass": mass_end,
     "seed": marks_seed, "persisted": marks_persisted, "marks": marks_collect,
     "all": run_all}[phase](rest)
