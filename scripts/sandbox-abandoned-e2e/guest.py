#!/usr/bin/env python3
"""Abandoned-session e2e driver (C11H-352). Runs inside a sandbox guest's Aqua
session through run.sh; state lives in /tmp/c11h352/ in the guest.

An hc session whose core never runs again keeps whatever its terminals left
running. c11-core lists such sessions and, asked for one, ends what they left:
SIGHUP, then SIGKILL after the grace, chosen by hc's recorded identity.

  prepare   quit the app sandbox-up launched, end its hc, wipe this build's hc
            state, launch fresh (shards off: c11-core status needs the base core)
  live      a c11 panel starts a nohup sleep and a HUP-ignoring sleep: live
            terminals whose jobs must never be touched
  probe     with c11's pinned herdr-core, two sessions c11 does not own:
            c11-probe-old (a HUP-ignoring root with a child: the alive-root
            shape; a root with a nohup job: the dead-root shape) and
            c11-probe-held (one terminal, core and holder left running)
  abandon   SIGKILL c11-probe-old's core, then its holder (guest pids)
  checks    c11-core abandoned / --json / status and c11 hc-diagnostics list
            it; end-abandoned refuses this build's session and the held one;
            end-abandoned c11-probe-old ends exactly its leftovers and starts
            no core; c11's own terminals and the held session keep running
Prints the summary between C11H352-SUMMARY markers. Exit 0 pass, 1 fail.
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

STATE = "/tmp/c11h352"
HOME = os.path.expanduser("~")
OLD = "c11-probe-old"
HELD = "c11-probe-held"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def now():
    return time.time()


def run(args, timeout=60, env=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def sh(*args, check=True, timeout=60, env=None):
    rc, out, err = run(list(args), timeout=timeout, env=env)
    if check and rc != 0:
        raise SystemExit(f"command failed ({rc}): {args}\n{out}\n{err}")
    return out


def save(name, obj):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name), "w") as f:
        json.dump(obj, f, indent=1)


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


def hc_diag(meta):
    try:
        return json.loads(c11(meta, "hc-diagnostics", "--json", check=False, timeout=20))
    except ValueError:
        return None


def core_tool(meta, *args, timeout=60):
    """c11-core from the guest shell (no HC_SESSION: not inside a terminal)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HC_", "C11_", "CMUX_"))}
    rc, out, err = run([meta["core"], *args], timeout=timeout, env=env)
    parsed = None
    if "--json" in args:
        try:
            parsed = json.loads(out)
        except ValueError:
            parsed = None
    return rc, out, err, parsed


def find_uuid(obj, keys):
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


def bundle_id(app):
    import plistlib
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def app_binary(meta):
    return os.path.join(meta["app"], "Contents", "MacOS", "c11")


def ps_rows(fields="command"):
    out = sh("/bin/ps", "-axww", "-o", f"pid=,{fields}=", check=False)
    rows = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)$", line)
        if m:
            rows.append((int(m.group(1)), m.group(2)))
    return rows


def table():
    """pid -> (start, ppid, command) for every process: lstart is fixed width (24)."""
    out = sh("/bin/ps", "-axww", "-o", "pid=,ppid=,lstart=,command=", check=False)
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(.{24})\s+(.*)$", line)
        if m:
            rows[int(m.group(1))] = (m.group(3), int(m.group(2)), m.group(4))
    return rows


def app_pids(meta):
    binary = app_binary(meta)
    return [pid for pid, cmd in ps_rows() if cmd == binary or cmd.startswith(binary + " ")]


def alive(pid):
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
    """Guest only, by pids read in this run."""
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def hc_cores(session):
    want = re.compile(r"(?:^|\s)HC_SESSION=(" + session + r")(?:\s|$)")
    out = sh("/bin/ps", "-axwwE", "-o", "pid=,command=", check=False)
    found = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)$", line)
        if m and re.search(r"\sserve(?:\s|$)", m.group(2)) and "HC_RUNTIME=1" in m.group(2) and want.search(m.group(2)):
            found.append(int(m.group(1)))
    return found


def own_family_cores(s0):
    return hc_cores(re.escape(s0) + r"(?:-s[0-9]+)?")


def own_family_holders(s0):
    want = re.compile(r"\shold\s+--socket\s+\S*/\.local/share/c11/run/(" + re.escape(s0) + r"(?:-s[0-9]+)?)\.holder\.")
    return [pid for pid, cmd in ps_rows() if want.search(cmd)]


def wait_socket(meta, timeout):
    deadline = now() + timeout
    while now() < deadline:
        if os.path.exists(meta["socket"]) and c11(meta, "ping", check=False, timeout=5).strip():
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


def launch(meta, qa):
    env = {
        "HOME": HOME, "USER": os.environ.get("USER", "admin"), "LOGNAME": os.environ.get("USER", "admin"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "C11_SOCKET_MODE": "automation", "C11_ALLOW_SOCKET_OVERRIDE": "1",
        "C11_SOCKET": meta["socket"], "C11_SOCKET_PATH": meta["socket"], "C11_QA_LAUNCH": qa,
    }
    if meta.get("dsock"):
        env["CMUXD_UNIX_PATH"] = meta["dsock"]
    if meta.get("log"):
        env["C11_DEBUG_LOG"] = meta["log"]
    if os.path.exists(meta["socket"]):
        os.unlink(meta["socket"])
    subprocess.Popen(["nohup", app_binary(meta)], env=env, stdout=open(os.path.join(STATE, "app.out"), "a"),
                     stderr=subprocess.STDOUT, start_new_session=True)
    if not wait_socket(meta, 60):
        raise SystemExit(f"socket {meta['socket']} did not answer within 60 s; see {STATE}/app.out")


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
    return [p for p in pids if alive(p)]


def members_of(root):
    """Every process whose session leader is `root`, with its start time."""
    rows = table()
    out = []
    for pid, (start, ppid, cmd) in rows.items():
        try:
            if os.getsid(pid) == root:
                out.append({"pid": pid, "start": start, "ppid": ppid, "cmd": cmd[:120]})
        except OSError:
            pass
    return sorted(out, key=lambda m: m["pid"])


def stable_members(root):
    """Present in two reads 2 s apart: the shell integration's `sleep 1` never is."""
    first = {(m["pid"], m["start"]) for m in members_of(root)}
    time.sleep(2.0)
    return [m for m in members_of(root) if (m["pid"], m["start"]) in first]


def still_running(members):
    rows = table()
    return [m for m in members if rows.get(m["pid"], (None,))[0] == m["start"]]


def send_line(meta, p, text):
    deadline = now() + 20
    while True:
        r = subprocess.run([meta["cli"], "--socket", meta["socket"], "send", "--workspace", p["workspace"],
                            "--panel", p["panel"], text], capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return
        err = r.stdout + r.stderr
        if not ("hc_input_unavailable" in err or "inventory_pending" in err) or now() >= deadline:
            raise SystemExit(f"send to {p['panel']} failed ({r.returncode}): {err[-400:]}")
        time.sleep(0.5)


# ----------------------------------------------------------------- phases

def prepare(meta):
    diag = hc_diag(meta) if os.path.exists(meta["socket"]) else None
    s0 = next((s["session"] for s in (diag or {}).get("shards", []) if s.get("index") == 0), None)
    if not s0:
        tag = meta["bundle"].split("com.stage11.c11.debug.", 1)[-1].replace(".", "-").strip("-")
        s0 = "c11-" + tag
    meta["hc_session"] = s0
    kill9(term_app(meta))
    for _ in range(8):
        cores, holders = own_family_cores(s0), own_family_holders(s0)
        if not cores and not holders:
            break
        kill9(cores + holders)
        time.sleep(0.5)
    for pattern in (os.path.join(HOME, ".local/state/herdr-core", s0 + "*"),
                    os.path.join(HOME, ".local/state/herdr-core", "c11-probe-*"),
                    os.path.join(HOME, "Library/Application Support/c11/HC", s0 + "*"),
                    os.path.join(HOME, ".local/share/c11/run", s0 + "*"),
                    os.path.join(HOME, ".local/share/c11/run", "c11-probe-*")):
        for path in glob.glob(pattern):
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.lexists(path):
                os.unlink(path)
    # Shards stay at their default (off): c11-core status talks to the base session's core.
    sh("/usr/bin/defaults", "delete", meta["bundle"], "c11.shards.enabled", check=False)
    sh("/usr/bin/defaults", "write", meta["bundle"], "warnBeforeQuitShortcut", "-bool", "false")
    launch(meta, "fresh")
    diag = wait_ready(meta, 60)
    # c11's pinned hc ships in the app (`HCCoreBinary`).
    hc = [os.path.join(meta["app"], "Contents", "Helpers", "herdr-core")]
    hc += sorted(glob.glob(os.path.join(HOME, ".local/share/c11/hc/*/herdr-core")))
    hc = [p for p in hc if os.access(p, os.X_OK)]
    if not hc:
        raise SystemExit("no pinned herdr-core in the app or under ~/.local/share/c11/hc")
    meta["hc"] = hc[0]
    return {"hc_session": s0, "readiness": (diag or {}).get("readiness"), "hc": meta["hc"]}


def live(meta):
    """A c11 panel with jobs that must never be touched."""
    tree = c11_json(meta, "tree", "--all")
    selected, stack = None, [tree]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            if o.get("selected") is True and o.get("areas"):
                selected = o
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    if not selected:
        raise SystemExit("no selected workspace")
    p = {"workspace": selected["id"].upper(), "panel": selected["areas"][0]["panels"][0]["id"].upper()}
    time.sleep(2.0)
    send_line(meta, p, "nohup sleep 735001 >/dev/null 2>&1 & (trap '' HUP; exec sleep 735002) &")
    time.sleep(3.0)
    rows = {(r.get("panel_id") or "").upper(): r for r in (hc_diag(meta) or {}).get("panels", [])}
    root = (rows.get(p["panel"]) or {}).get("pid")
    if not root:
        raise SystemExit(f"panel {p['panel']} has no root pid")
    p["root"] = root
    p["members"] = stable_members(root)
    meta["live"] = p
    return {"root": root, "members": len(p["members"])}


def hc_env(session):
    run_dir = os.path.join(HOME, ".local/share/c11/run")
    os.makedirs(run_dir, mode=0o700, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HC_", "C11_", "CMUX_"))}
    env.update({"HC_SESSION": session, "HC_SOCKET": os.path.join(run_dir, session + ".sock")})
    return env


def hc(meta, session, *args, timeout=60):
    rc, out, err = run([meta["hc"], *args], timeout=timeout, env=hc_env(session))
    if rc != 0:
        raise SystemExit(f"hc {args} ({session}) failed ({rc}): {out[-400:]} {err[-400:]}")
    return out


def find_terminals(obj):
    """Every dict carrying an address and a pid."""
    found, stack = [], [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            if isinstance(o.get("address"), str) and isinstance(o.get("pid"), int):
                found.append(o)
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    return found


def start_probe(meta, session, scripts):
    terminals = []
    for script in scripts:
        out = hc(meta, session, "run", "--bg", "--json", "--no-parent", "--", "/bin/sh", "-c", script)
        m = re.search(r'"address"\s*:\s*"([^"]+)"', out)
        if not m:
            raise SystemExit(f"hc run printed no address: {out[:400]}")
        terminals.append({"address": m.group(1), "run": out[:600]})
    time.sleep(2.0)
    for t in terminals:
        got = find_terminals(json.loads(hc(meta, session, "get", t["address"], "--json")))
        item = next((g for g in got if g["address"] == t["address"]), None)
        if not item or item.get("state") != "live":
            screen = run([meta["hc"], "read", t["address"]], timeout=20, env=hc_env(session))[1]
            raise SystemExit(f"{session}: {t['address']} is not live: {json.dumps(item)[:800]} run={t['run']} screen={screen[-600:]}")
        t["root"] = item["pid"]
        t["members"] = stable_members(item["pid"])
    return {"session": session, "terminals": terminals, "cores": hc_cores(re.escape(session))}


def probe(meta):
    old = start_probe(meta, OLD, [
        # alive root: the root ignores the hangup, and so does its child
        "trap '' HUP; sleep 735101 & exec sleep 735102",
        # dead root: the root ends on the hangup, its nohup job does not
        "nohup sleep 735111 >/dev/null 2>&1 & exec sleep 735112",
    ])
    held = start_probe(meta, HELD, ["trap '' HUP; exec sleep 735121"])
    meta["old"], meta["held"] = old, held
    return {"old": [len(t["members"]) for t in old["terminals"]], "held": [len(t["members"]) for t in held["terminals"]],
            "cores": {"old": old["cores"], "held": held["cores"]}}


def abandon(meta):
    old = meta["old"]
    rows = table()
    holder = rows.get(old["terminals"][0]["root"], (None, None))[1]
    cores = hc_cores(re.escape(OLD))
    if not cores or not holder or holder <= 1:
        raise SystemExit(f"{OLD}: want its core and holder, got cores {cores}, holder {holder}")
    kill9(cores)
    kill9([holder])
    time.sleep(4.0)
    alive_root, dead_root = old["terminals"]
    expected = still_running(alive_root["members"]) + [m for m in still_running(dead_root["members"]) if m["pid"] != dead_root["root"]]
    meta["expected"] = expected
    rows = table()
    return {"killed": {"cores": cores, "holder": holder}, "cores_after": hc_cores(re.escape(OLD)),
            "alive_root_parent": rows.get(alive_root["root"], (None, None))[1],
            "dead_root_running": dead_root["root"] in rows and still_running([m for m in dead_root["members"] if m["pid"] == dead_root["root"]]) != [],
            "expected": expected}


def check(checks, name, ok, **detail):
    checks[name] = {"pass": bool(ok), **detail}


def checks_phase(meta, checks):
    old, held, live_panel = meta["old"], meta["held"], meta["live"]
    expected = meta["expected"]
    alive_root, dead_root = old["terminals"]
    shape = (alive_root["root"] in {m["pid"] for m in expected}
             and dead_root["root"] not in {m["pid"] for m in expected}
             and len(expected) == 3 and hc_cores(re.escape(OLD)) == [])
    check(checks, "abandoned_shape", shape, expected=[(m["pid"], m["cmd"]) for m in expected],
          note="alive root + its child, and the dead root's nohup job; no core")

    # c11-core abandoned --json
    rc, out, err, listing = core_tool(meta, "abandoned", "--json")
    save("abandoned-before.json", listing or {"raw": out, "err": err})
    sessions = {s["session"]: s for s in (listing or {}).get("sessions", [])}
    item = sessions.get(OLD) or {}
    items = (item.get("processes") or {}).get("items", [])
    got = {(i["pid"], i["basis"]) for i in items}
    want_pids = {m["pid"] for m in expected}
    basis_ok = ({p for p, b in got if b == "root"} == {alive_root["root"]}
                and {p for p, b in got if b == "scope"} == {m["pid"] for m in expected if m["pid"] not in {x["pid"] for x in alive_root["members"]}})
    check(checks, "listed", rc == 0 and {p for p, _ in got} == want_pids and basis_ok,
          rc=rc, got=sorted(got), want=sorted(want_pids), item=item)
    s0 = meta["hc_session"]
    own_listed = [s for s in sessions if s == s0 or s.startswith(s0 + "-")]
    skipped = {s["session"]: s["why"] for s in (listing or {}).get("skipped", [])}
    check(checks, "others_not_listed", rc == 0 and not own_listed and HELD not in sessions and skipped.get(HELD) == "core_running",
          own_listed=own_listed, skipped=skipped, protected=(listing or {}).get("protected"))

    rc_t, text, _, _ = core_tool(meta, "abandoned", "--all")
    save("abandoned-text.txt", {"text": text})
    check(checks, "text_line", rc_t == 0 and re.search(rf"^abandoned session={re.escape(OLD)} terminals=2 terminals_left=2 processes=3 unverified=0$", text, re.M) is not None,
          text=text)

    rc_s, _, _, status = core_tool(meta, "--json")
    check(checks, "status_counts", rc_s == 0 and ((status or {}).get("abandoned") or {}).get("processes", 0) >= 3,
          abandoned=(status or {}).get("abandoned"), rc=rc_s)

    # c11 hc-diagnostics: the app's view (cached for 30 s, so poll past it)
    entry, deadline = None, now() + 45
    while now() < deadline:
        diag = hc_diag(meta) or {}
        entry = next((s for s in diag.get("abandoned_sessions", []) if s.get("session") == OLD), None)
        if entry:
            break
        time.sleep(3)
    diag_text = c11(meta, "hc-diagnostics", check=False, timeout=20)
    line_ok = re.search(rf"^abandoned session={re.escape(OLD)} terminals=2 terminals_left=2 processes=3 unverified=0$", diag_text, re.M)
    check(checks, "hc_diagnostics", bool(entry) and entry.get("processes") == 3 and line_ok is not None,
          entry=entry, lines=[l for l in diag_text.splitlines() if l.startswith("abandoned")])

    # refusals
    rc_c, _, _, refused = core_tool(meta, "end-abandoned", s0, "--yes", "--json")
    check(checks, "refuse_current", rc_c == 7 and ((refused or {}).get("error") or {}).get("code") == "current",
          rc=rc_c, reply=refused)
    held_members = [m for t in held["terminals"] for m in t["members"]]
    rc_h, _, _, refused_h = core_tool(meta, "end-abandoned", HELD, "--yes", "--json")
    check(checks, "refuse_core_running", rc_h == 7 and ((refused_h or {}).get("error") or {}).get("code") == "core_running"
          and len(still_running(held_members)) == len(held_members), rc=rc_h, reply=refused_h)
    # The held session's core dies; its holder lives (and restarts the core after 3 s).
    held_cores = hc_cores(re.escape(HELD))
    kill9(held_cores)
    time.sleep(0.3)
    rc_k, _, _, refused_k = core_tool(meta, "end-abandoned", HELD, "--yes", "--json")
    code_k = ((refused_k or {}).get("error") or {}).get("code")
    time.sleep(1.0)
    check(checks, "refuse_live_holder", rc_k == 7 and code_k in ("holder_alive", "core_running")
          and len(still_running(held_members)) == len(held_members), rc=rc_k, code=code_k, killed_core=held_cores)

    # the end
    started = now()
    rc_e, out_e, err_e, ended = core_tool(meta, "end-abandoned", OLD, "--yes", "--json")
    elapsed = now() - started
    save("end.json", ended or {"raw": out_e, "err": err_e})
    deadline = now() + 6
    left = still_running(expected)
    while left and now() < deadline:
        time.sleep(0.3)
        left = still_running(expected)
    procs = (ended or {}).get("processes") or {}
    check(checks, "end_ends_leftovers", rc_e == 0 and not left and procs.get("hung_up") == 3 and procs.get("remaining") == 0,
          rc=rc_e, reply=ended, left=left, elapsed_s=round(elapsed, 2))
    check(checks, "end_starts_no_core", hc_cores(re.escape(OLD)) == [], cores=hc_cores(re.escape(OLD)))

    live_left = still_running(live_panel["members"])
    check(checks, "live_untouched", len(live_left) == len(live_panel["members"]) and len(live_panel["members"]) >= 3,
          members=len(live_panel["members"]), running=len(live_left))
    held_left = still_running(held_members)
    check(checks, "held_untouched", len(held_left) == len(held_members), members=len(held_members), running=len(held_left))

    rc_a, _, _, after = core_tool(meta, "abandoned", "--json")
    save("abandoned-after.json", after or {})
    check(checks, "relisted_clean", rc_a == 0 and OLD not in {s["session"] for s in (after or {}).get("sessions", [])},
          sessions=[s["session"] for s in (after or {}).get("sessions", [])])


def in_guest(app):
    """This driver quits apps, kills hc processes and deletes state: it runs
    only inside a sandbox VM, on the app sandbox-up staged there."""
    vm = run(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], timeout=10)[1].strip() == "1"
    staged = os.path.realpath(app).startswith(os.path.realpath(os.path.join(HOME, "c11-sandbox", "apps")) + "/")
    return vm and staged


def main():
    args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    if not in_guest(args.get("app", "")):
        print("refused: guest.py runs only inside a sandbox guest, on the app sandbox-up staged there", file=sys.stderr)
        sys.exit(2)
    os.makedirs(STATE, exist_ok=True)
    meta = {"app": args["app"], "socket": args["socket"], "log": args.get("log"), "dsock": args.get("dsock")}
    meta["cli"] = os.path.join(meta["app"], "Contents", "Resources", "bin", "c11")
    meta["core"] = os.path.join(meta["app"], "Contents", "Resources", "bin", "c11-core")
    meta["bundle"] = bundle_id(meta["app"])
    summary = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "phases": {}, "checks": {}}
    try:
        for name, fn in (("prepare", prepare), ("live", live), ("probe", probe), ("abandon", abandon)):
            t = now()
            summary["phases"][name] = fn(meta)
            summary["phases"][name]["seconds"] = round(now() - t, 2)
            print(f"phase {name}: {json.dumps(summary['phases'][name])[:600]}", flush=True)
        checks_phase(meta, summary["checks"])
    except SystemExit as e:
        summary["harness_error"] = str(e)
    except Exception as e:  # report, never hang
        summary["harness_error"] = f"{type(e).__name__}: {e}"
    failed = [k for k, v in summary["checks"].items() if not v.get("pass") and not v.get("informational")]
    summary["failed"] = failed
    summary["result"] = "pass" if summary["checks"] and not failed and not summary.get("harness_error") else "fail"
    print("===C11H352-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H352-SUMMARY-END===")
    sys.exit(0 if summary["result"] == "pass" else 1)


if __name__ == "__main__":
    main()
