#!/usr/bin/python3
"""c11 2.0 migration e2e, guest driver (C11H-266). Runs inside a Tart guest only.

Phases (argv[1]): setup | quit | relaunch | check | shot | all-baseline.
key=value arguments follow. State lives under /tmp/migw; record.json is what
setup saw, check-<label>.json is a verdict.

setup     install the given c11h.app at /Applications/c11h.app, launch it the
          way a user does (LaunchServices, default socket path, socket mode
          automation so this ssh-driven script may call the CLI), and build a
          world: 4 workspaces (3 never selected), stand-in agents in 8 panels
          spread over shards, titles, descriptions, mailbox addresses.
quit      clean-quit c11h (TERM) and prove every stand-in survived.
relaunch  open an app (app=<path>) with extra env (env=K=V,K=V) and wait for
          its socket (sock=<path>; default c11h's).
check     every recorded panel is back attached: same shell pid, same stand-in
          pid, scrollback has the pre-quit mark, input lands, nothing was typed
          into it, nothing resumed, metadata kept, and a survivor's own CLI
          (c11h's, from its inherited env) still reaches the running app.

Never run on a host: it kills every herdr-core and wipes c11h state in $HOME.
"""
import hashlib, json, os, plistlib, signal, stat, subprocess, sys, time, uuid

W = "/tmp/migw"
R = "/tmp/migw-results"  # verdicts, screenshots and logs; survives every setup
HOME = os.path.expanduser("~")
C11H_APP = "/Applications/c11h.app"
C11H_SOCK = f"{HOME}/Library/Application Support/c11h/c11h.sock"
LEDGER = f"{W}/ledger.jsonl"
AGENT = f"{W}/agent.py"

AGENT_SRC = r'''
import json, os, select, subprocess, sys, time
name, mark, ledger = sys.argv[1], sys.argv[2], sys.argv[3]
def log(**kw):
    kw.update(name=name, pid=os.getpid(), ts=time.time())
    with open(ledger, "a") as f:
        f.write(json.dumps(kw) + "\n")
log(event="start", shell_pid=os.getppid())
print(f"MARK {mark} pid={os.getpid()}", flush=True)
n = 0
while True:
    r, _, _ = select.select([sys.stdin], [], [], 2.0)
    if r:
        line = sys.stdin.readline()
        if not line:
            log(event="eof"); break
        line = line.rstrip("\n")
        if line.startswith("run:"):
            p = subprocess.run(line[4:], shell=True, capture_output=True, text=True, timeout=30)
            log(event="run", line=line, rc=p.returncode, out=(p.stdout + p.stderr)[-400:])
        else:
            log(event="input", line=line)
        print(f"got {line}", flush=True)
    else:
        n += 1
        print(f"tick {n}", flush=True)
'''


def args_dict(argv):
    out = {}
    for a in argv:
        if "=" in a:
            k, v = a.split("=", 1)
            out[k] = v
    return out


def say(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def sh(cmd, check=False, timeout=60, env=None):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    if check and p.returncode != 0:
        raise SystemExit(f"failed ({p.returncode}): {' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    return p


def cli_path(app):
    for name in ("c11", "c11h"):
        path = f"{app}/Contents/Resources/bin/{name}"
        if os.path.exists(path):
            return path
    raise SystemExit(f"no CLI in {app}")


class CLI:
    def __init__(self, app, sock):
        self.bin = cli_path(app)
        self.env = {"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "C11_SOCKET": sock, "C11_SOCKET_PATH": sock, "USER": os.environ.get("USER", "admin")}

    def run(self, *args, check=True, timeout=30):
        return sh([self.bin, *args], check=check, timeout=timeout, env=self.env)

    def json(self, *args):
        out = self.run(*args).stdout
        return json.loads(out)


def pids_of(pattern_exact_prefix):
    p = sh(["/bin/ps", "-axo", "pid=,command="])
    out = []
    for line in p.stdout.splitlines():
        line = line.strip()
        pid, _, cmd = line.partition(" ")
        if cmd.startswith((pattern_exact_prefix, os.path.realpath(pattern_exact_prefix))):
            out.append(int(pid))
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for(pred, timeout, step=0.5):
    end = time.time() + timeout
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(step)
    return pred()


def ledger():
    if not os.path.exists(LEDGER):
        return []
    return [json.loads(l) for l in open(LEDGER) if l.strip()]


def open_app(app, env):
    os.makedirs(W, exist_ok=True)
    cmd = ["/usr/bin/open", "-n", "--stdout", "/tmp/migw/app-stdout.log", "--stderr", "/tmp/migw/app-stdout.log"]
    for k, v in env.items():
        cmd += ["--env", f"{k}={v}"]
    cmd.append(app)
    sh(cmd, check=True)


def wait_socket(cli, timeout=90):
    last = {}
    def ok():
        try:
            p = cli.run("tree", "--json", check=False, timeout=10)
        except subprocess.TimeoutExpired:
            last["err"] = "timeout"
            return False
        last["err"] = (p.stderr or p.stdout)[-300:]
        return p.returncode == 0
    up = wait_for(ok, timeout, 1.0)
    if not up:
        say("socket wait failed:", cli.env["C11_SOCKET"], last.get("err"))
    return up


def kill_all_c11h_family():
    """Guest-only reset: quit any c11h, end every hc core and holder."""
    for prefix in ("/Applications/c11h.app/Contents/MacOS/c11h",):
        for pid in pids_of(prefix):
            os.kill(pid, signal.SIGTERM)
    p = sh(["/bin/ps", "-axo", "pid=,command="])
    for line in p.stdout.splitlines():
        line = line.strip()
        pid, _, cmd = line.partition(" ")
        if ("/Contents/MacOS/c11h" in cmd and "/Applications/" not in cmd) or cmd.startswith(("/tmp/migw-apps/", "/private/tmp/migw-apps/")) \
                or "/c11-sandbox/apps/" in cmd:
            sh(["/usr/bin/sudo", "-n", "/bin/kill", "-TERM", pid])
    # Wait for every app to finish quitting: a quitting app still writes its
    # snapshot, and would re-create folders a wipe just removed.
    def apps_alive():
        out = sh(["/bin/ps", "-axo", "command="]).stdout
        return any(("/Contents/MacOS/c11" in c) for c in out.splitlines())
    if not wait_for(lambda: not apps_alive(), 30, 0.5):
        for line in sh(["/bin/ps", "-axo", "pid=,command="]).stdout.splitlines():
            pid, _, cmd = line.strip().partition(" ")
            if "/Contents/MacOS/c11" in cmd:
                sh(["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", pid])
        time.sleep(1)
    for line in sh(["/bin/ps", "-axo", "pid=,command="]).stdout.splitlines():
        line = line.strip()
        pid, _, cmd = line.partition(" ")
        if "herdr-core" in cmd:
            sh(["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", pid])


def wipe_state(keep1x=False):
    import glob
    c11h = ["Library/Application Support/c11h", ".local/share/c11h", ".local/state/herdr-core",  # c11-2.0:legacy
            ".c11h", ".c11h-snapshots", ".config/c11h", "Library/Logs/c11h",  # c11-2.0:legacy
            "Library/WebKit/com.stage11.c11h", "Library/HTTPStorages/com.stage11.c11h",  # c11-2.0:legacy
            "Library/Application Support/c11-migration.json", "Library/Application Support/c11.migrating",
            "Library/Application Support/c11.adopted-link", ".c11.migrating", ".c11.adopted-link",
            ".c11-snapshots.migrating", ".c11-snapshots.adopted-link", ".config/c11.migrating", ".config/c11.adopted-link",
            "Library/Application Support/c11.migration.lock", "Library/Logs/c11"]
    onex = ["Library/Application Support/c11", ".local/share/c11", ".c11", ".c11-snapshots", ".config/c11",
            "Library/WebKit/com.stage11.c11", "Library/HTTPStorages/com.stage11.c11"]
    for rel in c11h + ([] if keep1x else onex):
        sh(["/bin/rm", "-rf", os.path.join(HOME, rel)])
    for path in glob.glob(f"{HOME}/Library/Application Support/c11-1.x-kept-*") + glob.glob("/tmp/c11-*.sock"):
        sh(["/bin/rm", "-rf", path])
    # Links left by an adoption are ours even when 1.x is kept.
    for rel in ["Library/Application Support/c11", ".c11", ".c11-snapshots", ".config/c11"]:
        if os.path.islink(os.path.join(HOME, rel)):
            os.unlink(os.path.join(HOME, rel))
    doms = ["com.stage11.c11h"] + ([] if keep1x else ["com.stage11.c11"])  # c11-2.0:legacy
    out = sh(["/usr/bin/defaults", "domains"]).stdout
    doms += [d.strip() for d in out.split(",") if d.strip().startswith("com.stage11.c11.debug.")]
    for dom in doms:
        sh(["/usr/bin/defaults", "delete", dom])


def tree_panels(cli):
    t = cli.json("--id-format", "both", "tree", "--all", "--json")
    panels = {}
    for win in t.get("windows", []):
        for ws in win.get("workspaces", []):
            for area in ws.get("areas", []):
                for p in area.get("panels", []):
                    panels[p["id"]] = {"ref": p.get("ref"), "title": p.get("title"), "type": p.get("type"),
                                       "workspace": ws.get("id"), "workspace_selected": bool(ws.get("selected"))}
    return t, panels


def tree_workspaces(t):
    return [ws for win in t.get("windows", []) for ws in win.get("workspaces", [])]


def diagnostics(cli):
    d = cli.json("hc-diagnostics", "--json")
    return d, {p["panel_id"]: p for p in d.get("panels", [])}


def setup(a):
    src = a.get("src")
    os.makedirs(W, exist_ok=True)
    say("reset guest c11h state")
    kill_all_c11h_family()
    keep1x = a.get("keep1x") == "1"
    wipe_state(keep1x)
    for f in os.listdir(W):
        if keep1x and f in ("record1x.json",) or f.startswith("x"):
            continue
        sh(["/bin/rm", "-rf", os.path.join(W, f)])
    open(AGENT, "w").write(AGENT_SRC)
    if src and os.path.realpath(src) != os.path.realpath(C11H_APP):
        say("install", src, "->", C11H_APP)
        sh(["/usr/bin/sudo", "-n", "/bin/rm", "-rf", C11H_APP], check=True)
        sh(["/usr/bin/sudo", "-n", "/usr/bin/ditto", src, C11H_APP], check=True)
        sh(["/usr/bin/sudo", "-n", "/usr/sbin/chown", "-R", f"{os.getuid()}:20", C11H_APP], check=True)
        sh(["/usr/bin/xattr", "-dr", "com.apple.quarantine", C11H_APP])
    sh(["/usr/bin/defaults", "write", "com.stage11.c11h", "c11h.shards.enabled", "-bool", "YES"], check=True)
    open_app(C11H_APP, {"C11_QA_LAUNCH": "fresh", "C11_SOCKET_MODE": "automation"})
    cli = CLI(C11H_APP, C11H_SOCK)
    if not wait_socket(cli):
        raise SystemExit("c11h socket never answered")
    say("c11h up")
    time.sleep(3)

    ws_refs = []
    _, before = tree_panels(cli)
    big = a.get("world") == "big"
    for i in range(2, 13 if big else 5):
        d = f"{W}/ws{i}"
        os.makedirs(d, exist_ok=True)
        out = cli.run("new-workspace", "--cwd", d, "--title", f"Mig W{i}").stdout.strip()
        ws_refs.append(out.split()[1] if out.startswith("OK") else out)
    time.sleep(2)
    tree, panels = tree_panels(cli)
    workspaces = tree_workspaces(tree)
    say("workspaces", [(w.get("ref"), w.get("title"), w.get("selected")) for w in workspaces])
    # two stand-in panels per workspace: one new panel plus one more
    agents = []
    n = 0
    for w in workspaces[:12 if big else 4]:
        wref = w.get("id") or w.get("ref")
        for k in range(6 if big else 2):
            n += 1
            name = f"agent{n}"
            mark = f"{name}-{uuid.uuid4().hex[:10]}"
            command = [] if a.get("nostandins") == "1" else ["--command", f"/usr/bin/python3 {AGENT} {name} {mark} {LEDGER}"]
            out = cli.run("new-panel", "--type", "terminal", "--workspace", wref, *command).stdout
            ref = next((tok for tok in out.split() if tok.startswith("panel:")), None)
            agents.append({"name": name, "mark": mark, "workspace": wref, "ref": ref,
                           "workspace_selected": bool(w.get("selected"))})
    time.sleep(1)
    _, panels = tree_panels(cli)
    by_ref = {v["ref"]: k for k, v in panels.items()}
    for ag in agents:
        ag["panel_id"] = by_ref.get(ag["ref"])
        if not ag["panel_id"]:
            raise SystemExit(f"no panel for {ag}")
        target = ["--workspace", ag["workspace"], "--panel", ag["panel_id"]]
        cli.run("rename-panel", *target, f"Mig {ag['name']}")
        cli.run("set-description", *target, f"stand-in {ag['name']}")
        cli.run("set-metadata", *target, "--key", "mailbox.address", "--value",
                f"mig-{ag['name']}", "--type", "string")
    if big:
        # A browser store of real size: 1 GiB of written blocks.
        store = f"{HOME}/Library/WebKit/com.stage11.c11h/WebsiteDataStore/mig-big"  # c11-2.0:legacy
        os.makedirs(store, exist_ok=True)
        sh(["/usr/sbin/mkfile", "1g", f"{store}/blob.bin"], check=True, timeout=300)
    started = a.get("nostandins") == "1" or wait_for(
        lambda: len({e["name"] for e in ledger() if e["event"] == "start"}) >= len(agents), 120)
    say("stand-ins started", started and len(agents))
    record(cli, agents)


def record(cli, agents):
    tree, panels = tree_panels(cli)
    diag, dpanels = diagnostics(cli)
    starts = {e["name"]: e for e in ledger() if e["event"] == "start"}
    for ag in agents:
        pid_uuid = ag["panel_id"]
        dp = dpanels.get(pid_uuid or "", {})
        ag["shell_pid"] = dp.get("pid")
        ag["terminal"] = dp.get("terminal")
        ag["shard"] = dp.get("shard")
        ag["agent_pid"] = starts.get(ag["name"], {}).get("pid")
    shards = sorted({ag["shard"] for ag in agents if ag["shard"]})
    hidden = [ag for ag in agents if not ag["workspace_selected"]]
    rec = {"agents": agents, "shards": shards, "hidden_agents": len(hidden),
           "all_panels": {k: dict(v, **{"shell_pid": dpanels.get(k, {}).get("pid"),
                                        "terminal": dpanels.get(k, {}).get("terminal"),
                                        "shard": dpanels.get(k, {}).get("shard")}) for k, v in panels.items()},
           "c11h_version": diag.get("c11h_version"), "at": time.strftime("%Y-%m-%d %H:%M:%S %Z")}
    json.dump(rec, open(f"{W}/record.json", "w"), indent=1)
    json.dump(tree, open(f"{W}/tree-setup.json", "w"), indent=1)
    json.dump(diag, open(f"{W}/diag-setup.json", "w"), indent=1)
    say(f"recorded {len(agents)} stand-ins on shards {shards}, {len(hidden)} in hidden workspaces")


def app_binary(app):
    import plistlib
    info = plistlib.load(open(f"{app}/Contents/Info.plist", "rb"))
    return f"{app}/Contents/MacOS/{info['CFBundleExecutable']}"


def save_verdict(label, verdict):
    """Saves a verdict; the caller's phase then exits 1 when it failed."""
    os.makedirs(R, exist_ok=True)
    json.dump(verdict, open(f"{R}/{label}.json", "w"), indent=1)
    log = f"{HOME}/Library/Logs/c11/migration.log"
    if os.path.exists(log):
        sh(["/bin/cp", log, f"{R}/migration-{label}.log"])


def survivor_run(cli, ag, command, wait=6):
    """Type `run:<command>` into a stand-in; it runs it with its own inherited
    environment (c11h's CLI on PATH, c11h's socket) and logs rc and output."""
    tag = uuid.uuid4().hex[:8]
    cli.run("send", "--allow-unguarded", "--workspace", ag["workspace"], "--panel", ag["panel_id"],
            f"run:{command} # {tag}", check=False)
    hit = wait_for(lambda: [e for e in ledger() if e["event"] == "run" and tag in e.get("line", "")], wait, 0.5)
    return hit[-1] if hit else {"rc": None, "out": "no run logged"}


def skew_checks(cli, agents, nonce):
    """A surviving agent's everyday verbs through c11h h15's own CLI, against the running app."""
    a1, a2, a3 = agents[0], agents[1], agents[2]
    out = {}
    r = survivor_run(cli, a1, f'c11 set-description --panel "$C11_PANEL_ID" skew-desc-{nonce}')
    desc = cli.run("get-metadata", "--workspace", a1["workspace"], "--panel", a1["panel_id"], "--key", "description",
                   check=False).stdout
    out["set_description"] = {"pass": r["rc"] == 0 and f"skew-desc-{nonce}" in desc, "rc": r["rc"], "out": r["out"]}
    r = survivor_run(cli, a1, f'c11 set-status status skew-status-{nonce} --panel "$C11_PANEL_ID"')
    st = cli.run("get-metadata", "--workspace", a1["workspace"], "--panel", a1["panel_id"], "--key", "status",
                 check=False).stdout
    out["set_status"] = {"pass": r["rc"] == 0 and f"skew-status-{nonce}" in st, "rc": r["rc"], "out": r["out"]}
    r = survivor_run(cli, a1, f"c11 mailbox send --to mig-{a2['name']} skew-mail-{nonce}")
    out["mailbox_send"] = {"pass": r["rc"] == 0, "rc": r["rc"], "out": r["out"]}
    time.sleep(2)
    r = survivor_run(cli, a2, "c11 mailbox recv --ack")
    out["mailbox_recv_ack"] = {"pass": r["rc"] == 0 and f"skew-mail-{nonce}" in r["out"], "rc": r["rc"], "out": r["out"]}
    r = survivor_run(cli, a1, f"c11 send --allow-unguarded --workspace {a3['workspace']} --panel {a3['panel_id']} skew-send-{nonce}")
    landed = wait_for(lambda: any(e["name"] == a3["name"] and e.get("line") == f"skew-send-{nonce}"
                                  for e in ledger() if e["event"] == "input"), 6, 0.5)
    out["send_other_panel"] = {"pass": r["rc"] == 0 and bool(landed), "rc": r["rc"], "out": r["out"]}
    r = survivor_run(cli, a1, f'c11 raise-flag --panel "$C11_PANEL_ID" skew-flag-{nonce}')
    r2 = survivor_run(cli, a1, 'c11 lower-flag --panel "$C11_PANEL_ID"')
    out["raise_lower_flag"] = {"pass": r["rc"] == 0 and r2["rc"] == 0, "rc": [r["rc"], r2["rc"]], "out": r["out"]}
    return out


def migration_timing():
    """Per migration run: ms from its plan line to its last line, from the log."""
    path = f"{HOME}/Library/Logs/c11/migration.log"
    if not os.path.exists(path):
        return None
    from datetime import datetime
    runs = {}
    for line in open(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
        r = runs.setdefault(e["run"], {"first": t, "last": t, "steps": []})
        r["last"] = t
        r["steps"].append(f'{e["step"]}:{e["outcome"]}')
    return {k: {"ms": int((v["last"] - v["first"]).total_seconds() * 1000), "steps": v["steps"]} for k, v in runs.items()}


def crashlaunch(a):
    """Launch with a fault injected after a step: the app must exit 86 there."""
    app, step = a["app"], a["step"]
    env = {"C11_SOCKET_MODE": "automation", "C11_QA_LAUNCH": "resume", "C11_MIGRATION_QA": "1",
           "C11_MIGRATION_FAULT": step}
    logpath = f"{HOME}/Library/Logs/c11/migration.log"
    offset = os.path.getsize(logpath) if os.path.exists(logpath) else 0
    open_app(app, env)
    binary = app_binary(app)
    time.sleep(3)
    gone = wait_for(lambda: not pids_of(binary), 60, 0.5)
    new = ""
    if os.path.exists(logpath):
        with open(logpath) as f:
            f.seek(offset)
            new = f.read()
    # This launch's own fault line, for exactly this step.
    hit = any('"outcome":"fault_injected"' in l and f'"step":"{step}"' in l for l in new.splitlines())
    say("crashlaunch", step, "exited" if gone else "STILL RUNNING", "fault logged" if hit else "NO FAULT LINE")
    if not gone:
        for pid in pids_of(binary):
            os.kill(pid, signal.SIGKILL)
    if not gone or not hit:
        raise SystemExit(1)


def hostend(a):
    """What a reboot does to hc: end every core and holder (guest only), then
    every stand-in left. The apps are quit first."""
    for app in (C11H_APP, a.get("app", "")):
        if app and os.path.isdir(app):
            for pid in pids_of(app_binary(app)):
                os.kill(pid, signal.SIGTERM)
    time.sleep(3)
    for line in sh(["/bin/ps", "-axo", "pid=,command="]).stdout.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if "herdr-core" in cmd or AGENT in cmd:
            sh(["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", pid])
    time.sleep(2)
    say("host end: cores, holders and stand-ins ended")


CLAUDE_LEDGER = f"{W}/claude-ledger.jsonl"
STUB_PATH = "/usr/local/bin/claude"
# A resumable stand-in (after scripts/sandbox-host-end-e2e). The bundled wrapper
# execs the next `claude` on PATH with --session-id for a fresh start, or
# --resume <id> when c11 resumes a conversation. One line per start.
STUB = r'''#!/usr/bin/python3 -u
import json, os, sys, time
def log(rec):
    rec.update(ts=time.time(), pid=os.getpid(), panel=(os.environ.get("C11_PANEL_ID") or "").upper(),
               hc_session=os.environ.get("HC_SESSION"))
    fd = os.open("/tmp/migw/claude-ledger.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
    try:
        os.write(fd, (json.dumps(rec) + "\n").encode())
    finally:
        os.close(fd)
log({"event": "start", "argv": sys.argv[1:]})
print("MIG-STUB-CLAUDE", " ".join(sys.argv[1:]), flush=True)
while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    log({"event": "stdin", "line": line.decode("utf-8", "replace").rstrip("\n")})
'''


def claude_ledger():
    if not os.path.exists(CLAUDE_LEDGER):
        return []
    return [json.loads(l) for l in open(CLAUDE_LEDGER) if l.strip()]


def write_transcript(cwd, sid):
    import re
    from datetime import datetime, timezone
    path = os.path.join(HOME, ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd), f"{sid}.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    u1, u2 = str(uuid.uuid4()), str(uuid.uuid4())
    rows = [
        {"type": "summary", "summary": "c11 2.0 migration stand-in", "leafUuid": u2},
        {"parentUuid": None, "isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
         "version": "2.1.200", "gitBranch": "", "type": "user", "uuid": u1, "timestamp": stamp,
         "message": {"role": "user", "content": "hello"}},
        {"parentUuid": u1, "isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
         "version": "2.1.200", "gitBranch": "", "type": "assistant", "uuid": u2, "timestamp": stamp,
         "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}},
    ]
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def expected_hc_base(app, env_text=""):
    """Match C11Identity.hcLaunchTag for the built app, not a broad name prefix."""
    with open(f"{app}/Contents/Info.plist", "rb") as source:
        bundle = plistlib.load(source).get("CFBundleIdentifier", "").strip()
    env = dict(kv.split("=", 1) for kv in filter(None, env_text.split(",")))
    raw = env.get("C11_TAG", env.get("CMUX_TAG", "")).strip()
    if raw:
        return "c11-" + raw
    prefix = "com.stage11.c11."
    if bundle == "com.stage11.c11":
        return "c11"
    if not bundle.startswith(prefix):
        raise SystemExit(f"not a c11 destination bundle: {bundle!r}")
    rest = bundle[len(prefix):].replace(".", "-").strip("-")
    channels = ("debug", "staging", "nightly")
    if not rest:
        tag = "app"
    elif rest in channels:
        tag = rest
    elif rest.startswith("debug-"):
        tag = rest[len("debug-"):]
        if tag in channels or tag == "app" or tag.startswith(("staging-", "nightly-", "app-", "tag-")):
            tag = "tag-" + tag
    elif rest.startswith(("staging-", "nightly-")):
        tag = rest
    else:
        tag = "app-" + rest
    return "c11-" + tag


def convergence_source_manifest():
    """Hashes and permissions of the synthetic legacy snapshot, intents and credentials.
    Called only by marked-guest phases (or an isolated in-memory test fixture)."""
    support = "Library/Application Support/c11h"  # c11-2.0:legacy
    paths = [f"{support}/session-com.stage11.c11h.json",  # c11-2.0:legacy
             f"{support}/jev-key", f"{support}/socket-control-password"]
    hc = os.path.join(HOME, support, "HC")
    if os.path.isdir(hc):
        owned = {"c11h"} | {f"c11h-s{i}" for i in range(1, 9)}  # c11-2.0:legacy
        for session in sorted(os.listdir(hc)):
            if session not in owned:
                continue
            for directory, dirs, files in os.walk(os.path.join(hc, session), followlinks=False):
                dirs.sort()
                for name in sorted(files):
                    paths.append(os.path.relpath(os.path.join(directory, name), HOME))
    manifest = {}
    for relative in sorted(paths):
        path = os.path.join(HOME, relative)
        if not os.path.lexists(path):
            manifest[relative] = {"kind": "missing"}
            continue
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            manifest[relative] = {"kind": "link", "target": os.readlink(path)}
        elif stat.S_ISREG(info.st_mode):
            with open(path, "rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(source.read()).hexdigest()
            manifest[relative] = {"kind": "file", "sha256": digest,
                                  "mode": stat.S_IMODE(info.st_mode), "mtime_ns": info.st_mtime_ns}
        else:
            manifest[relative] = {"kind": "unexpected"}
    return manifest


def setup_claude(a):
    """A c11h world whose panels hold resumable (stub) Claude conversations."""
    setup(dict(a, nostandins="1"))
    # These are known fixture bytes, never credentials copied from a host.
    for name in ("jev-key", "socket-control-password"):
        path = f"{HOME}/Library/Application Support/c11h/{name}"  # c11-2.0:legacy
        with open(path, "w") as fixture:
            fixture.write("migration-fixture-" + name)
        os.chmod(path, 0o600)
    open(f"{W}/stub", "w").write(STUB)
    sh(["/usr/bin/sudo", "-n", "/bin/mkdir", "-p", "/usr/local/bin"], check=True)
    sh(["/usr/bin/sudo", "-n", "/bin/cp", f"{W}/stub", STUB_PATH], check=True)
    sh(["/usr/bin/sudo", "-n", "/bin/chmod", "755", STUB_PATH], check=True)
    cli = CLI(C11H_APP, C11H_SOCK)
    rec = json.load(open(f"{W}/record.json"))
    for ag in rec["agents"]:
        ag["cwd"] = f"{W}/c-{ag['name']}"
        os.makedirs(ag["cwd"], exist_ok=True)
        for _ in range(40):
            p = cli.run("send", "--allow-unguarded", "--workspace", ag["workspace"], "--panel", ag["panel_id"],
                        f"cd '{ag['cwd']}' && claude", check=False)
            if p.returncode == 0:
                break
            time.sleep(0.5)
    want = {ag["panel_id"].upper() for ag in rec["agents"]}
    wait_for(lambda: want <= {e["panel"] for e in claude_ledger() if e["event"] == "start"}, 90, 0.5)
    starts = {e["panel"]: e for e in claude_ledger() if e["event"] == "start"}
    time.sleep(1.5)
    for ag in rec["agents"]:
        argv = starts.get(ag["panel_id"].upper(), {}).get("argv", [])
        sid = argv[argv.index("--session-id") + 1] if "--session-id" in argv else str(uuid.uuid4())
        ag["conversation"] = sid.lower()
        write_transcript(ag["cwd"], ag["conversation"])
        cli.run("conversation", "push", "--panel", ag["panel_id"],
                "--kind", "claude-code", "--id", ag["conversation"], "--source", "hook", "--state", "alive",
                "--cwd", ag["cwd"])
        captured = cli.json("conversation", "get", "--panel", ag["panel_id"], "--json")
        active = captured.get("active") or {}
        if captured.get("panel_id", "").upper() != ag["panel_id"].upper() or active.get("id") != ag["conversation"] or active.get("state") != "alive":
            raise SystemExit(f"conversation fixture not captured on its panel: {ag['name']} {captured}")
    json.dump(rec, open(f"{W}/record.json", "w"), indent=1)
    started = len(want & set(starts))
    say(f"stub claude in {started}/{len(want)} panels, conversations pushed")
    if started < len(want):
        raise SystemExit(1)


def check_converged(a):
    """After convergence: every recorded panel back, live in 2.0's own pool, and
    its conversation resumed exactly once, with no click."""
    app = a["app"]
    label = a.get("label", "converged")
    mark = f"{W}/mark-{a.get('since_mark', '')}"
    if not a.get("since_mark") or not os.path.exists(mark):
        raise SystemExit("convergence check requires its original pre-convergence mark")
    since = float(open(mark).read())
    expected_base = expected_hc_base(app, a.get("env", ""))
    expected_sessions = {expected_base} | {f"{expected_base}-s{i}" for i in range(1, 9)}
    preservation_file = f"{W}/preserve-{a['since_mark']}.json"
    preserved_before = json.load(open(preservation_file)) if os.path.exists(preservation_file) else {}
    cli = CLI(app, a.get("sock") or default_sock(app))
    rec = json.load(open(f"{W}/record.json"))
    ids = {ag["panel_id"]: ag for ag in rec["agents"]}
    if not ids:
        raise SystemExit("convergence proof has no recorded conversation panels")

    def resumed(ag):
        return [e for e in claude_ledger() if e["event"] == "start" and e["panel"] == ag["panel_id"].upper()
                and e["ts"] >= since and "--resume" in e.get("argv", [])]

    def done():
        try:
            _, dp = diagnostics(cli)
        except Exception:
            return False
        return all(dp.get(i, {}).get("lifecycle") == "live" and resumed(ag) for i, ag in ids.items())
    wait_for(done, float(a.get("wait", "240")), 2.0)
    time.sleep(5)  # a second resume would land now
    _, panels = tree_panels(cli)
    _, dp = diagnostics(cli)
    per = {}
    for i, ag in ids.items():
        r = resumed(ag)
        d = dp.get(i, {})
        argv = r[0].get("argv", []) if r else []
        resume_index = argv.index("--resume") + 1 if "--resume" in argv else len(argv)
        resumed_id = argv[resume_index].lower() if resume_index < len(argv) else None
        per[ag["name"]] = {"present": i in panels, "live": d.get("lifecycle") == "live",
                           "shard": d.get("shard"), "reason": d.get("reason"),
                           "own_pool": d.get("shard") in expected_sessions,
                           "resumed_once": len(r) == 1,
                           "resumed_own_conversation": bool(ag.get("conversation")) and resumed_id == ag["conversation"].lower()}
    record_path = f"{HOME}/Library/Application Support/c11-migration.json"
    record = json.load(open(record_path)) if os.path.exists(record_path) else {}
    real = lambda rel: os.path.isdir(os.path.join(HOME, rel)) and not os.path.islink(os.path.join(HOME, rel))
    preserved_after = convergence_source_manifest()
    support = "Library/Application Support/c11h"  # c11-2.0:legacy
    required = [f"{support}/session-com.stage11.c11h.json",  # c11-2.0:legacy
                f"{support}/jev-key", f"{support}/socket-control-password"]
    preservation_complete = bool(preserved_before) and all(preserved_before.get(path, {}).get("kind") == "file" for path in required)
    preservation_complete = preservation_complete and any(path.endswith("/creation-intents.json") and value.get("kind") == "file"
                                                          for path, value in preserved_before.items())
    verdict = {"label": label, "at": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
               "expected_hc_base": expected_base, "since_mark": a["since_mark"],
               "assertions": {
                   "panels_present": all(v["present"] for v in per.values()),
                   "panels_live": all(v["live"] for v in per.values()),
                   "hidden_conversations_seeded": rec.get("hidden_agents", 0) > 0,
                   "own_pool": all(v["own_pool"] for v in per.values()),
                   "resumed_once": all(v["resumed_once"] for v in per.values()),
                   "resumed_own_conversation": all(v["resumed_own_conversation"] for v in per.values()),
                   "support_real_folder": real("Library/Application Support/c11"),
                   "home_real_folder": real(".c11"),
                   "snapshots_real_folder": real(".c11-snapshots"),
                   "config_real_folder": real(".config/c11"),
                   "preservation_recorded": preservation_complete,
                   "source_snapshot_intents_credentials_unchanged": preserved_after == preserved_before,
                   "c11h_folder_kept": os.path.isdir(f"{HOME}/Library/Application Support/c11h"),  # c11-2.0:legacy
                   "record_converged": record.get("phase") == "converged",
               }, "per_panel": per, "migration_timing": migration_timing(),
               "source_preservation": {"before": preserved_before, "after": preserved_after}}
    verdict["result"] = "pass" if all(verdict["assertions"].values()) else "fail"
    save_verdict(label, verdict)
    print("===MIG-VERDICT-BEGIN===")
    print(json.dumps(verdict, indent=1))
    print("===MIG-VERDICT-END===")
    say(label, verdict["result"], {k: v for k, v in verdict["assertions"].items() if not v} or "all pass")
    if verdict["result"] != "pass":
        raise SystemExit(1)  # failed verdict


def now_mark(a):
    name = a.get("name", "x")
    if a.get("preserve") == "1":
        manifest = convergence_source_manifest()
        with open(f"{W}/preserve-{name}.json", "w") as record:
            json.dump(manifest, record, indent=1, sort_keys=True)
    open(f"{W}/mark-{name}", "w").write(str(time.time()))
    say("mark", name, time.time())


def check_kept(a):
    """Both: c11 1.x's folder moved aside whole, settings exported, nothing incomplete."""
    import glob
    label = a.get("label", "kept-1x")
    kept = glob.glob(f"{HOME}/Library/Application Support/c11-1.x-kept-*")
    k = kept[0] if kept else ""
    verdict = {"label": label, "kept": os.path.basename(k), "assertions": {
        "one_kept_folder": len(kept) == 1,
        "complete": bool(k) and not os.path.exists(f"{k}/.incomplete"),
        "support_moved": bool(glob.glob(f"{k}/home/Library/Application Support/c11/session-*.json")),
        "defaults_exported": os.path.exists(f"{k}/defaults-com.stage11.c11.plist")
                             and "Submarine" in open(f"{k}/defaults-com.stage11.c11.plist").read(),
        "release_domain_untouched": "Submarine" in sh(["/usr/bin/defaults", "export", "com.stage11.c11", "-"]).stdout,
        "readme": os.path.exists(f"{k}/KEPT.md"),
    }}
    verdict["result"] = "pass" if all(verdict["assertions"].values()) else "fail"
    save_verdict(label, verdict)
    say(label, verdict["result"], {x: v for x, v in verdict["assertions"].items() if not v} or "all pass")
    if verdict["result"] != "pass":
        raise SystemExit(1)  # failed verdict


def quit_c11h(a):
    pids = pids_of(app_binary(a.get("app", C11H_APP)))
    if not pids:
        raise SystemExit("quit precondition failed: target app process not found")
    for pid in pids:
        os.kill(pid, signal.SIGTERM)
    gone = wait_for(lambda: not any(alive(p) for p in pids), 40)
    rec = json.load(open(f"{W}/record.json"))
    # Python stand-ins carry their pid; stub-Claude panels are judged by their terminal later.
    survivors = {ag["name"]: alive(ag["agent_pid"]) for ag in rec["agents"] if ag.get("agent_pid")}
    say("quit", a.get("app", C11H_APP), "clean" if gone else "STILL RUNNING", "survivors", survivors)
    json.dump({"quit": bool(gone), "survivors": survivors}, open(f"{W}/quit.json", "w"))
    if not gone or not all(survivors.values()):
        raise SystemExit(1)


def take_sample(app, name):
    os.makedirs(R, exist_ok=True)
    for pid in pids_of(app_binary(app))[:1]:
        sh(["/usr/bin/sample", str(pid), "3", "-file", f"{R}/sample-{name}.txt"], timeout=60)
        say("sampled", app, "as", name)


def save_timing(label, timing):
    os.makedirs(R, exist_ok=True)
    json.dump(timing, open(f"{R}/timing-{label}.json", "w"), indent=1)


def diagnose_stuck(app, label):
    """An app that never answered: what it is doing, saved beside the verdicts."""
    os.makedirs(R, exist_ok=True)
    d = f"{R}/stuck-{label}"
    os.makedirs(d, exist_ok=True)
    pids = pids_of(app_binary(app))
    with open(f"{d}/ps.txt", "w") as f:
        f.write(sh(["/bin/ps", "-axo", "pid,ppid,stat,etime,%cpu,rss,command"]).stdout)
    for pid in pids[:1]:
        sh(["/usr/bin/sample", str(pid), "5", "-file", f"{d}/sample.txt"], timeout=60)
    sh(["/usr/sbin/screencapture", "-x", f"{d}/screen.png"])
    reports = f"{HOME}/Library/Logs/DiagnosticReports"
    if os.path.isdir(reports):
        for n in os.listdir(reports):
            if "c11" in n:
                sh(["/bin/cp", os.path.join(reports, n), d])
    for src in (f"{HOME}/Library/Logs/c11/migration.log", "/tmp/migw/app-stdout.log"):
        if os.path.exists(src):
            sh(["/bin/cp", src, d])
    say("stuck:", label, "pids", pids, "evidence in", d)


def relaunch(a):
    app = a["app"]
    env = {"C11_SOCKET_MODE": "automation", "C11_QA_LAUNCH": "resume"}
    for kv in filter(None, a.get("env", "").split(",")):
        k, v = kv.split("=", 1)
        env[k] = v
    started = time.time()
    open_app(app, env)
    sock = a.get("sock")
    if not sock:
        # The socket a fresh launch binds: one created after the launch.
        # A relaunch finds the old file still there: it counts once it answers.
        def fresh():
            path = default_sock(app)
            if not os.path.exists(path):
                return None
            if os.path.getmtime(path) >= started - 1:
                return path
            try:
                return path if CLI(app, path).run("ping", check=False, timeout=3).returncode == 0 else None
            except subprocess.TimeoutExpired:
                return None
        sock = wait_for(fresh, 60, 1.0) or default_sock(app)
    cli = CLI(app, sock)
    label = a.get("label", "relaunch")
    # Sample the app at 30 s and 90 s while its socket has not answered.
    samples = {30: False, 90: False}
    def answered():
        for mark in samples:
            if not samples[mark] and time.time() - started >= mark:
                samples[mark] = True
                take_sample(app, f"{label}-{mark}s")
        try:
            return cli.run("tree", "--json", check=False, timeout=10).returncode == 0
        except subprocess.TimeoutExpired:
            return False
    up = wait_for(answered, int(a.get("wait", "240")), 1.0)
    t_socket = time.time() - started if up else None
    timing = {"label": label, "app": app, "socket_s": round(t_socket, 1) if t_socket else None,
              "samples_taken": [m for m, v in samples.items() if v]}
    if not up:
        timing["result"] = "socket never answered"
        save_timing(label, timing)
        diagnose_stuck(app, label)
        raise SystemExit("app socket never answered")
    if a.get("measure") == "1" and os.path.exists(f"{W}/record.json"):
        rec = json.load(open(f"{W}/record.json"))
        ids = [ag["panel_id"] for ag in rec["agents"]]
        def attached():
            try:
                _, dp = diagnostics(cli)
            except Exception:
                return False
            return all(dp.get(i, {}).get("lifecycle") == "live" for i in ids)
        ok = wait_for(attached, int(a.get("attach_wait", "600")), 2.0)
        timing["panels"] = len(ids)
        timing["all_attached_s"] = round(time.time() - started, 1) if ok else None
    save_timing(label, timing)
    say("timing", json.dumps(timing))
    say("relaunched", app)


def check(a):
    app = a.get("app", C11H_APP)
    label = a.get("label", "check")
    cli = CLI(app, a.get("sock") or default_sock(app))
    rec = json.load(open(f"{W}/record.json"))
    agents = rec["agents"]
    settle = float(a.get("settle", "20"))

    def all_live():
        _, dp = diagnostics(cli)
        return all(dp.get(ag["panel_id"], {}).get("lifecycle") == "live" for ag in agents)
    wait_for(all_live, settle, 1.0)
    tree, panels = tree_panels(cli)
    diag, dp = diagnostics(cli)
    starts_before = {}
    for e in ledger():
        if e["event"] == "start":
            starts_before[e["name"]] = starts_before.get(e["name"], 0) + 1
    # Lines this harness typed itself (pings, survivor runs, skew sends) are not
    # the app typing into an agent.
    ours = ("ping-", "run:", "skew-")
    typed = [e for e in ledger() if e["event"] in ("input", "run") and not e.get("line", "").startswith(ours)]
    results = {}
    nonce = uuid.uuid4().hex[:8]
    for ag in agents:
        r = {}
        pid = ag["panel_id"]
        p = dp.get(pid, {})
        r["present"] = pid in panels
        r["title"] = (panels.get(pid) or {}).get("title")
        r["live"] = p.get("lifecycle") == "live"
        r["same_shell_pid"] = p.get("pid") == ag["shell_pid"]
        r["same_terminal"] = p.get("terminal") == ag["terminal"]
        r["agent_alive"] = alive(ag["agent_pid"] or -1)
        r["started_once"] = starts_before.get(ag["name"], 0) == 1
        r["not_typed_into"] = not any(e["name"] == ag["name"] for e in typed)
        ws = ["--workspace", ag["workspace"]]
        # A hidden panel attaches on its first read after a relaunch; its
        # scrollback arrives on a later read (observed on c11h h15).
        reads = 0
        def has_mark():
            nonlocal reads
            reads += 1
            return ag["mark"] in cli.run("read-screen", *ws, "--panel", pid, "--scrollback", check=False).stdout
        r["scrollback_mark"] = bool(wait_for(has_mark, 15, 1.0))
        r["scrollback_reads"] = reads
        meta = cli.run("get-metadata", *ws, "--panel", pid, "--key", "mailbox.address", check=False).stdout
        r["mailbox_address"] = f"mig-{ag['name']}" in meta
        line = f"ping-{nonce}-{ag['name']}"
        cli.run("send", "--allow-unguarded", *ws, "--panel", pid, line, check=False)
        r["_ping"] = line
        results[ag["name"]] = r
    time.sleep(4)
    got = {(e["name"], e.get("line")) for e in ledger() if e["event"] == "input"}
    for ag in agents:
        r = results[ag["name"]]
        r["input_lands"] = (ag["name"], r.pop("_ping")) in got
    # A survivor's own CLI (its inherited PATH and C11_SOCKET) reaches the app.
    probe = agents[0]
    cli.run("send", "--allow-unguarded", "--workspace", probe["workspace"], "--panel", probe["panel_id"],
            f"run:c11 set-description --panel \"$C11_PANEL_ID\" survivor-cli-{nonce}", check=False)
    time.sleep(5)
    runs = [e for e in ledger() if e["event"] == "run" and nonce in e.get("line", "")]
    survivor_cli = bool(runs) and runs[-1]["rc"] == 0
    skew = {}
    if a.get("skew") == "1" and len(agents) >= 3:
        skew = skew_checks(cli, agents, nonce)
    timing = migration_timing()
    restore = cli.run("restore", "status", "--json", check=False).stdout
    agg = {k: all(r[k] for r in results.values()) for k in next(iter(results.values()))
           if k not in ("title", "scrollback_reads")}
    verdict = {
        "label": label, "app": app, "at": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "panels": len(agents), "shards": rec["shards"], "hidden_agents": rec["hidden_agents"],
        "assertions": dict(agg, survivor_cli=survivor_cli, two_shards=len(rec["shards"]) >= 2,
                           hidden_workspace=rec["hidden_agents"] > 0,
                           **{f"skew_{k}": v["pass"] for k, v in skew.items()}),
        "skew": skew, "migration_timing": timing,
        "per_panel": results, "survivor_cli_run": runs[-1] if runs else None,
        "restore_status": restore[-2000:],
    }
    verdict["result"] = "pass" if all(verdict["assertions"].values()) else "fail"
    save_verdict(label, verdict)
    json.dump(diag, open(f"{R}/diag-{label}.json", "w"), indent=1)
    print("===MIG-VERDICT-BEGIN===")
    print(json.dumps(verdict, indent=1))
    print("===MIG-VERDICT-END===")
    say(label, verdict["result"], {k: v for k, v in verdict["assertions"].items() if not v} or "all pass")
    if verdict["result"] != "pass":
        raise SystemExit(1)  # failed verdict


C11_APP = "/Applications/c11.app"
ONEX_THEME = "mig-onex"


def theme_name(out):
    """The theme name from `themes get`: 1.x prints `Chrome light: <name>`, 2.0 `Theme: <name> …`."""
    for line in out.splitlines():
        if line.startswith(("Theme:", "Chrome light:", "Chrome dark:")):
            rest = line.split(":", 1)[1].split()
            return rest[0] if rest else ""
    return ""


def c11_1x_socket():
    d = f"{HOME}/Library/Application Support/c11"
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if name.startswith("c11") and name.endswith(".sock"):
            return f"{d}/{name}"
    return f"{d}/c11-{os.getuid()}.sock"


def default_sock(app):
    if app.endswith("/c11h.app"):
        return C11H_SOCK
    if app.endswith("/c11.app"):
        return c11_1x_socket()
    # A tagged 2.0 Debug build listens in /tmp: the newest c11 socket there.
    socks = [f"/tmp/{n}" for n in os.listdir("/tmp") if n.startswith("c11-") and n.endswith(".sock")]
    return max(socks, key=os.path.getmtime) if socks else "/tmp/c11.sock"


def setup1x(a):
    """c11 1.8.x world: workspaces, titles, descriptions, mailbox addresses, a
    theme, a notification sound, a saved agent config. Its terminals end at quit."""
    os.makedirs(W, exist_ok=True)
    kill_all_c11h_family()
    for pid in pids_of(f"{C11_APP}/Contents/MacOS/c11"):
        os.kill(pid, signal.SIGTERM)
    wipe_state(False)
    for f in os.listdir(W):
        sh(["/bin/rm", "-rf", os.path.join(W, f)])
    say("install", a["src"], "->", C11_APP)
    sh(["/usr/bin/sudo", "-n", "/bin/rm", "-rf", C11_APP], check=True)
    sh(["/usr/bin/sudo", "-n", "/usr/bin/ditto", a["src"], C11_APP], check=True)
    sh(["/usr/bin/sudo", "-n", "/usr/sbin/chown", "-R", f"{os.getuid()}:20", C11_APP], check=True)
    sh(["/usr/bin/xattr", "-dr", "com.apple.quarantine", C11_APP])
    sh(["/usr/bin/defaults", "write", "com.stage11.c11", "notificationSound", "-string", "Submarine"], check=True)
    sh(["/usr/bin/defaults", "write", "com.stage11.c11", "SUEnableAutomaticChecks", "-bool", "NO"], check=True)
    # c11 1.x saves its session on a normal Quit (SIGTERM is a crash to it); no confirm sheet.
    sh(["/usr/bin/defaults", "write", "com.stage11.c11", "warnBeforeQuitShortcut", "-bool", "NO"], check=True)
    # A user theme in c11's own themes folder, so 1.x and 2.0 can both load it; no
    # bundled theme but stage11 (the default) ships in both.
    themes_dir = f"{HOME}/Library/Application Support/c11/themes"
    os.makedirs(themes_dir, exist_ok=True)
    base = open(f"{C11_APP}/Contents/Resources/c11-themes/stage11.toml").read()
    base = base.replace('name         = "stage11"', f'name         = "{ONEX_THEME}"', 1)
    base = base.replace('display_name = "Stage 11"', 'display_name = "Mig OneX"', 1)
    open(f"{themes_dir}/{ONEX_THEME}.toml", "w").write(base)
    open_app(C11_APP, {"C11_QA_LAUNCH": "fresh", "C11_SOCKET_MODE": "automation"})
    time.sleep(3)
    cli = CLI(C11_APP, c11_1x_socket())
    if not wait_socket(cli):
        raise SystemExit("c11 1.x socket never answered")
    say("c11 1.x up", cli.env["C11_SOCKET"])
    for i in range(2, 4):
        d = f"{W}/x{i}"
        os.makedirs(d, exist_ok=True)
        cli.run("new-workspace", "--cwd", d, "--title", f"OneX W{i}")
    time.sleep(2)
    tree, _ = tree_panels(cli)
    panels = []
    for n, ws in enumerate(tree_workspaces(tree), start=1):
        for area in ws.get("areas", []):
            for p in area.get("panels", []):
                if p.get("type") != "terminal":
                    continue
                target = ["--workspace", ws["id"], "--panel", p["id"]]
                name = f"onex{len(panels) + 1}"
                cli.run("rename-panel", *target, f"OneX {name}")
                cli.run("set-description", *target, f"1.x panel {name}")
                cli.run("set-metadata", *target, "--key", "mailbox.address", "--value", f"mig-{name}", "--type", "string")
                panels.append({"name": name, "panel_id": p["id"], "workspace": ws["id"], "workspace_title": ws.get("title"),
                               "cwd": p.get("cwd")})
    for slot in ("light", "dark"):
        cli.run("themes", "set", ONEX_THEME, "--slot", slot, check=False)
    saved = cli.run("config", "save", "mig-onex", "--harness", "claude-code", "--model", "claude-opus-5-5", check=False)
    time.sleep(2)
    themes = theme_name(cli.run("themes", "get", "--slot", "light", check=False).stdout)
    rec = {"panels": panels, "workspaces": [w.get("title") for w in tree_workspaces(tree)],
           "theme": themes, "config_saved": saved.returncode == 0,
           "agent_configs": os.path.exists(f"{HOME}/Library/Application Support/c11/agent-configs.json")}
    json.dump(rec, open(f"{W}/record1x.json", "w"), indent=1)
    say("1.x world:", len(panels), "panels in", rec["workspaces"], "theme", themes, "config", rec["config_saved"])
    pids = pids_of(f"{C11_APP}/Contents/MacOS/c11")
    sh(["/usr/bin/osascript", "-e", 'tell application id "com.stage11.c11" to quit'], timeout=60)
    clean = wait_for(lambda: not any(alive(p) for p in pids), 40)
    marker = os.path.exists(f"{HOME}/.c11/runtime/shutdown.com.stage11.c11.clean")
    say("1.x quit", "clean" if clean and marker else f"exited={bool(clean)} clean_marker={marker}")


def check1x(a):
    app = a["app"]
    label = a.get("label", "check-1x")
    cli = CLI(app, a.get("sock") or default_sock(app))
    rec = json.load(open(f"{W}/record1x.json"))
    time.sleep(float(a.get("settle", "10")))
    tree, panels = tree_panels(cli)
    titles = [w.get("title") for w in tree_workspaces(tree)]
    per = {}
    for p in rec["panels"]:
        got = panels.get(p["panel_id"])
        meta = cli.run("get-metadata", "--workspace", p["workspace"], "--panel", p["panel_id"], "--key", "mailbox.address",
                       check=False).stdout if got else ""
        per[p["name"]] = {"present": got is not None, "title": (got or {}).get("title") == f"OneX {p['name']}",
                          "mailbox_address": f"mig-{p['name']}" in meta}
    dump = sh(["/usr/bin/defaults", "export", a.get("domain", "com.stage11.c11"), "-"]).stdout
    verdict = {"label": label, "app": app, "at": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
               "assertions": {
                   "workspaces": all(t in titles for t in rec["workspaces"]),
                   "panels_present": all(v["present"] for v in per.values()),
                   "panel_titles": all(v["title"] for v in per.values()),
                   "mailbox_addresses": all(v["mailbox_address"] for v in per.values()),
                   "notification_sound": "Submarine" in dump,
                   # 2.0 shows one theme; the upgrade keeps 1.x's day theme.
                   "theme": rec["theme"] == ONEX_THEME
                            and theme_name(cli.run("themes", "get", check=False).stdout) == ONEX_THEME,
                   "agent_config": "mig-onex" in cli.run("config", "list", check=False).stdout or not rec["config_saved"],
               },
               "per_panel": per, "workspaces_now": titles}
    verdict["result"] = "pass" if all(verdict["assertions"].values()) else "fail"
    save_verdict(label, verdict)
    print("===MIG-VERDICT-BEGIN===")
    print(json.dumps(verdict, indent=1))
    print("===MIG-VERDICT-END===")
    say(label, verdict["result"], {k: v for k, v in verdict["assertions"].items() if not v} or "all pass")
    if verdict["result"] != "pass":
        raise SystemExit(1)  # failed verdict


def shot(a):
    os.makedirs(R, exist_ok=True)
    path = f"{R}/shot-{a.get('label', 'x')}.png"
    sh(["/usr/sbin/screencapture", "-x", path])
    say("screenshot", path)


GUEST_MARKER = "/var/tmp/c11-2.0-migration-guest"


def require_guest(run):
    """This driver ends apps and wipes c11h and c11 state in $HOME: it runs only
    in a Tart guest that run.sh marked for this run id, never on a host."""
    model = sh(["/usr/sbin/sysctl", "-n", "hw.model"]).stdout.strip()
    marker = open(GUEST_MARKER).read().strip() if os.path.exists(GUEST_MARKER) else ""
    if not model.startswith("VirtualMac") or not run or marker != run:
        raise SystemExit(f"refusing to run: not a marked guest for run {run!r} (model {model!r})")


def main():
    phase = sys.argv[1]
    require_guest(args_dict(sys.argv[2:]).get("run", ""))
    a = args_dict(sys.argv[2:])
    if phase == "setup":
        setup(a)
    elif phase == "quit":
        quit_c11h(a)
    elif phase == "relaunch":
        relaunch(a)
    elif phase == "check":
        check(a)
    elif phase == "shot":
        shot(a)
    elif phase == "crashlaunch":
        crashlaunch(a)
    elif phase == "hostend":
        hostend(a)
    elif phase == "setupclaude":
        setup_claude(a)
    elif phase == "mark":
        now_mark(a)
    elif phase == "checkconverged":
        check_converged(a)
    elif phase == "checkkept":
        check_kept(a)
    elif phase == "setup1x":
        setup1x(a)
    elif phase == "check1x":
        check1x(a)
    elif phase == "all-baseline":
        setup(a); shot({"label": "setup"}); quit_c11h(a)
        relaunch({"app": C11H_APP}); check({"label": "baseline-c11h-relaunch"}); shot({"label": "baseline"})
    else:
        raise SystemExit(f"unknown phase {phase}")


if __name__ == "__main__":
    main()
