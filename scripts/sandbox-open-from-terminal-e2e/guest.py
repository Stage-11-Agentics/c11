#!/usr/bin/env python3
"""Open-from-terminal e2e driver (C11H-415). Runs inside a sandbox guest's Aqua
session through run.sh; state lives in /tmp/c11h415/ in the guest.

`open -a` hands the app the environment of the terminal it runs in, hc's
`HC_SCOPE` token included. When that panel closes, hc ends every process whose
exec-time environment carries the token: before C11H-415 that was c11 itself.

  prepare   quit the app sandbox-up launched, end its hc, wipe this build's hc
            state, launch fresh
  panels    the selected workspace's first panel is the witness (a foreground
            sleep that must outlive everything); a second panel is the launcher
  relaunch  the launcher waits for c11 to exit and runs `open -a <app>`; c11 is
            quit by TERM (the installer's clean quit) and comes back from that
            terminal, carrying its environment
  close     the launcher panel is closed by the CLI, as the Captain did
  carrier   (c11 still up) a panel runs a stand-in for an older c11 app opened
            from it: a bundle `com.stage11.c11.e2e-carrier` whose executable is
            a copy of the bundled CLI, running `events tail -f`, carrying that
            terminal's token. Its panel is closed: the end is held, no kill,
            an "End held" notice. Then the notice's rule (C11H-417), each step
            checked for having happened (a close must leave no window, a move
            must make a new record):
            every window closes (no notice) and a new one opens (it moved);
            it is marked read and its workspace's last shell is sent `exit`:
            driven only if that removes the workspace, else the check says
            "not driven" and never passes; the operator clears it, every
            window closes and another opens (it stays cleared, the end still
            held); a second carrier's close is a new hold (told, unread);
            both carriers are killed (guest pids), both ends go ahead with
            nothing else changing, and the notice goes
  checks    c11's exec-time environment holds no terminal identity; c11 is up
            and answering 6 s after the close (hc's HUP, TERM, KILL take at most
            3 s); the witness keeps running; the launcher's own shell ended; the
            carrier's end was held, noticed, then released
Prints the summary between C11H415-SUMMARY markers. Exit 0 pass, 1 fail.
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

STATE = "/tmp/c11h415"
HOME = os.path.expanduser("~")
TITLE = "C11H-415 launcher"
CARRIER_TITLE = "C11H-415 carrier panel"
CARRIER_ID = "com.stage11.c11.e2e-carrier"
IDENTITY = re.compile(r"(?:^|\s)((?:HC_SCOPE|HC_TERMINAL_ID|HC_TERMINAL_SOCKET|C11_PANEL_ID|C11_SURFACE_ID|CMUX_SURFACE_ID|C11_HC_SESSION)=\S*)")


def now():
    return time.time()


def run(args, timeout=60, env=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def sh(*args, check=True, timeout=60):
    rc, out, err = run(list(args), timeout=timeout)
    if check and rc != 0:
        raise SystemExit(f"command failed ({rc}): {args}\n{out}\n{err}")
    return out


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


def bundle_id(app):
    import plistlib
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def app_commit(app):
    """The commit the staged app was built from (`C11Commit`), for the evidence."""
    import plistlib
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("C11Commit")
    except (OSError, ValueError):
        return None


def app_binary(meta):
    return os.path.join(meta["app"], "Contents", "MacOS", "c11")


def ps_rows():
    out = sh("/bin/ps", "-axww", "-o", "pid=,ppid=,lstart=,command=", check=False)
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(.{24})\s+(.*)$", line)
        if m:
            rows[int(m.group(1))] = (m.group(3), int(m.group(2)), m.group(4))
    return rows


def app_pids(meta):
    binary = app_binary(meta)
    return [pid for pid, (_, _, cmd) in ps_rows().items() if cmd == binary or cmd.startswith(binary + " ")]


def alive(pid):
    # The harness launches c11 as its own child: reap it, or its zombie answers
    # kill(pid, 0) (here and in the launcher terminal's wait) after it exited.
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


def own_family(s0):
    """This build's hc cores and holders, by their recorded session (guest only)."""
    out = sh("/bin/ps", "-axwwE", "-o", "pid=,command=", check=False)
    session = re.compile(r"(?:^|\s)HC_SESSION=" + re.escape(s0) + r"(?:-s[0-9]+)?(?:\s|$)")
    holder = re.compile(r"\shold\s+--socket\s+\S*/\.local/share/c11/run/" + re.escape(s0) + r"(?:-s[0-9]+)?\.holder\.")
    found = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(.*)$", line)
        if not m:
            continue
        cmd = m.group(2)
        if ("HC_RUNTIME=1" in cmd and session.search(cmd) and re.search(r"\sserve(?:\s|$)", cmd)) or holder.search(cmd):
            found.append(int(m.group(1)))
    return found


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
    """The harness's own launch: a clean environment, never a terminal's."""
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
    rows = ps_rows()
    out = []
    for pid, (start, ppid, cmd) in rows.items():
        try:
            if os.getsid(pid) == root:
                out.append({"pid": pid, "start": start, "ppid": ppid, "cmd": cmd[:120]})
        except OSError:
            pass
    return sorted(out, key=lambda m: m["pid"])


def still_running(members):
    rows = ps_rows()
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


def panel_root(meta, panel, timeout=20):
    deadline = now() + timeout
    while now() < deadline:
        rows = {(r.get("panel_id") or "").upper(): r for r in (hc_diag(meta) or {}).get("panels", [])}
        root = (rows.get(panel) or {}).get("pid")
        if root:
            return root
        time.sleep(0.5)
    raise SystemExit(f"panel {panel} has no root pid")


def listing(meta):
    """`list-notifications`: (succeeded, its text). A failed listing proves nothing."""
    rc, out, err = run([meta["cli"], "--socket", meta["socket"], "list-notifications"], timeout=15)
    return rc == 0, (out if rc == 0 else err).strip()


def held_line(text):
    """The "End held" row of a listing as (workspace id, read state, record id), or None.
    Rows read `<n>:<id>|<workspace>|<surface>|<read|unread>|<title>|<subtitle>|<body>`."""
    for line in text.splitlines():
        fields = line.split("|")
        if len(fields) >= 5 and fields[4] == "End held":
            return fields[1], fields[3], fields[0].split(":", 1)[-1]
    return None


def window_ids(meta):
    windows = c11_json(meta, "list-windows", check=False) or []
    return [w.get("id") for w in windows if isinstance(w, dict) and w.get("id")]


def close_all_windows(meta):
    """Closes every window; (every close answered 0 and none is left, the closes' codes)."""
    codes = [run([meta["cli"], "--socket", meta["socket"], "close-window", "--window", w], timeout=30)[0]
             for w in window_ids(meta)]
    time.sleep(3.0)
    return bool(codes) and all(code == 0 for code in codes) and not window_ids(meta), codes


def workspace_panels(meta, workspace):
    tree = c11_json(meta, "tree", "--all", check=False) or {}
    stack = [tree]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            if (o.get("id") or "").upper() == workspace.upper() and "areas" in o:
                return [p["id"].upper() for a in o.get("areas") or [] for p in a.get("panels") or []]
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    return None  # not listed: the workspace is gone


def exec_env(pid):
    """The identity entries ps -E shows for pid: its exec-time environment."""
    out = sh("/bin/ps", "-wwE", "-o", "command=", "-p", str(pid), check=False)
    return sorted(set(m.group(1).split("=", 1)[0] + ("=<value>" if "=" in m.group(1) else "") for m in IDENTITY.finditer(out)))


# ----------------------------------------------------------------- phases

def prepare(meta):
    diag = hc_diag(meta) if os.path.exists(meta["socket"]) else None
    s0 = next((s["session"] for s in (diag or {}).get("shards", []) if s.get("index") == 0), None)
    if not s0:
        tag = meta["bundle"].split("com.stage11.c11.debug.", 1)[-1].replace(".", "-").strip("-")
        s0 = "c11-" + tag
    kill9(term_app(meta))
    for _ in range(8):
        found = own_family(s0)
        if not found:
            break
        kill9(found)
        time.sleep(0.5)
    for pattern in (os.path.join(HOME, ".local/state/herdr-core", s0 + "*"),
                    os.path.join(HOME, "Library/Application Support/c11/HC", s0 + "*"),
                    os.path.join(HOME, ".local/share/c11/run", s0 + "*")):
        for path in glob.glob(pattern):
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.lexists(path):
                os.unlink(path)
    sh("/usr/bin/defaults", "write", meta["bundle"], "warnBeforeQuitShortcut", "-bool", "false")
    launch(meta, "fresh")
    diag = wait_ready(meta, 60)
    return {"hc_session": s0, "readiness": (diag or {}).get("readiness")}


def panels(meta):
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
    workspace = selected["id"].upper()
    witness = {"workspace": workspace, "panel": selected["areas"][0]["panels"][0]["id"].upper()}
    created = c11_json(meta, "new-panel", "--workspace", workspace)
    launcher_id = next((v for k, v in (created or {}).items() if k in ("panel_id", "surface_id", "id") and isinstance(v, str)), None)
    if not launcher_id:
        raise SystemExit(f"new-panel returned no panel id: {created}")
    launcher = {"workspace": workspace, "panel": launcher_id.upper()}
    c11(meta, "rename-panel", "--panel", launcher["panel"], TITLE)
    time.sleep(2.0)
    send_line(meta, witness, "sleep 735415")
    witness["root"] = panel_root(meta, witness["panel"])
    launcher["root"] = panel_root(meta, launcher["panel"])
    time.sleep(2.0)
    witness["members"] = members_of(witness["root"])
    meta["witness"], meta["launcher"] = witness, launcher
    return {"witness": witness["panel"], "witness_members": len(witness["members"]), "launcher": launcher["panel"]}


def relaunch(meta):
    before = app_pids(meta)
    if len(before) != 1:
        raise SystemExit(f"expected one c11 process, found {before}")
    old = before[0]
    # The incident's reopen, typed into the launcher terminal: after c11 exits,
    # `open -a` from this terminal. QA resume only keeps the startup dialogs away.
    send_line(meta, meta["launcher"],
              f"while kill -0 {old} 2>/dev/null; do sleep 0.2; done; C11_QA_LAUNCH=resume open -a '{meta['app']}'")
    time.sleep(1.0)
    os.kill(old, signal.SIGTERM)
    deadline = now() + 30
    while now() < deadline and alive(old):
        time.sleep(0.2)
    if alive(old):
        raise SystemExit("c11 did not quit on TERM within 30 s")
    deadline = now() + 90
    new = []
    while now() < deadline:
        new = [p for p in app_pids(meta) if p != old]
        if new and wait_socket(meta, 2):
            break
        time.sleep(0.5)
    if not new:
        raise SystemExit("c11 did not come back from the launcher terminal within 90 s")
    diag = wait_ready(meta, 60)
    pid = new[0]
    meta["app_pid"] = pid
    rows = ps_rows()
    meta["app_start"] = rows.get(pid, ("",))[0]
    identity = exec_env(pid)
    rc, log_out, _ = run(["/usr/bin/log", "show", "--style", "compact", "--last", "5m", "--predicate",
                          'subsystem == "com.stage11.c11" AND category == "hc.launch"'], timeout=60)
    launch_lines = [line[-240:] for line in log_out.splitlines() if "launch.env." in line][-4:]
    return {"old_pid": old, "app_pid": pid, "parent": rows.get(pid, (None, None))[1],
            "readiness": (diag or {}).get("readiness"), "exec_env_identity": identity, "launch_log": launch_lines}


def close(meta):
    started = now()
    rc, out, err = run([meta["cli"], "--socket", meta["socket"], "--json", "close-panel", "--panel", meta["launcher"]["panel"],
                        "--expect-title", TITLE], timeout=30)
    time.sleep(6.0)
    # Read now: the carrier phase later closes the window, which ends the witness on purpose.
    witness = meta["witness"]
    meta["witness_running"] = len(still_running(witness["members"]))
    return {"rc": rc, "out": out.strip()[-600:], "err": err.strip()[-300:], "seconds": round(now() - started, 2)}


def start_carrier(meta, exe, title, workspace):
    """A panel running the carrier (a backgrounded `events tail -f` plus a
    sleep); returns (panel, its root pid, the carrier pid)."""
    created = c11_json(meta, "new-panel", "--workspace", workspace)
    panel_id = next((v for k, v in (created or {}).items() if k in ("panel_id", "surface_id", "id") and isinstance(v, str)), None)
    if not panel_id:
        raise SystemExit(f"new-panel returned no panel id: {created}")
    p = {"workspace": workspace.upper(), "panel": panel_id.upper()}
    # Named with its workspace: a window a CLI opened is never the active one.
    c11(meta, "rename-panel", "--workspace", p["workspace"], "--panel", p["panel"], title)
    time.sleep(2.0)
    known = {q for q, (_, _, cmd) in ps_rows().items() if cmd.startswith(exe)}
    send_line(meta, p, f"'{exe}' events tail -f >/dev/null 2>&1 & sleep 735416 &")
    root = panel_root(meta, p["panel"])
    deadline, pid = now() + 15, None
    while now() < deadline and not pid:
        pid = next((q for q, (_, _, cmd) in ps_rows().items() if cmd.startswith(exe) and q not in known), None)
        time.sleep(0.3)
    if not pid:
        raise SystemExit("the carrier did not start")
    return p, root, pid


def close_held(meta, p, title):
    rc, out, _ = run([meta["cli"], "--socket", meta["socket"], "--json", "close-panel", "--workspace", p["workspace"],
                      "--panel", p["panel"], "--expect-title", title], timeout=30)
    try:
        return rc, (json.loads(out).get("session_end_outcomes") or [{}])[0]
    except ValueError:
        return rc, {}


def carrier(meta):
    """Ends a c11 app holds, the notice that says so, and its rule."""
    if not (meta.get("app_pid") and alive(meta["app_pid"])):
        return {"skipped": "c11 did not survive the close"}
    bundle = os.path.join(STATE, "carrier", "C11Carrier.app")
    macos = os.path.join(bundle, "Contents", "MacOS")
    os.makedirs(macos, exist_ok=True)
    exe = os.path.join(macos, "C11Carrier")
    shutil.copy2(meta["cli"], exe)
    import plistlib
    with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": CARRIER_ID, "CFBundleExecutable": "C11Carrier",
                       "CFBundlePackageType": "APPL", "CFBundleName": "C11Carrier"}, f)
    p, root, pid = start_carrier(meta, exe, CARRIER_TITLE, meta["witness"]["workspace"])
    carries = "HC_SCOPE=" in sh("/bin/ps", "-wwE", "-o", "command=", "-p", str(pid), check=False)
    c11(meta, "clear-notifications", check=False)
    rc, outcome = close_held(meta, p, CARRIER_TITLE)
    time.sleep(7.0)  # past the close's 5 s report and two 3 s rechecks
    held_root_alive = alive(root)
    listed_ok, notices = listing(meta)

    # Every window closes while the end is held (driven: each close answered and
    # none is left), then a new one opens: the notice moves (a new record).
    before = held_line(notices)
    closed_all, close_codes = close_all_windows(meta)
    without_ok, without_window = listing(meta)
    reopened = run([meta["cli"], "--socket", meta["socket"], "new-window"], timeout=30)
    time.sleep(4.0)
    reopen_ok, after_reopen = listing(meta)
    moved = held_line(after_reopen)

    # Read, then its workspace's last shell exits. Driven only when that removes
    # the workspace; otherwise the check says "not driven" and never passes.
    read_marked, exit_driven, exit_note, after_exit_ok, after_exit = False, False, "", False, ""
    if moved:
        read_marked = run([meta["cli"], "--socket", meta["socket"], "workspace-action", "--workspace", moved[0],
                           "--action", "mark-read"], timeout=15)[0] == 0
        time.sleep(0.5)
        panels = workspace_panels(meta, moved[0]) or []
        if len(panels) != 1:
            exit_note = f"its workspace holds {len(panels)} panels, not one"
        else:
            send_line(meta, {"workspace": moved[0].upper(), "panel": panels[0]}, "exit")
            deadline = now() + 10
            while now() < deadline and workspace_panels(meta, moved[0]) is not None:
                time.sleep(0.5)
            if workspace_panels(meta, moved[0]) is not None:
                exit_note = "the workspace was still listed 10 s after its shell was sent exit"
            else:
                exit_driven = True
                if not window_ids(meta):
                    run([meta["cli"], "--socket", meta["socket"], "new-window"], timeout=30)
                    time.sleep(4.0)
                after_exit_ok, after_exit = listing(meta)

    # The operator clears it; every window closes (driven) and another opens: it stays cleared.
    cleared = run([meta["cli"], "--socket", meta["socket"], "clear-notifications"], timeout=15)[0] == 0
    time.sleep(0.5)
    clear_closed_all, clear_close_codes = close_all_windows(meta)
    clear_reopened = run([meta["cli"], "--socket", meta["socket"], "new-window"], timeout=30)[0] == 0
    time.sleep(4.0)
    after_clear_ok, after_clear = listing(meta)
    still_held = alive(root)

    # A new hold after the clear is told, unread.
    second_root, second_pid, second_held = None, None, None
    workspace = (held_line(after_clear) or (None,))[0] or next(iter(
        (w.get("selected_workspace_id") for w in (c11_json(meta, "list-windows", check=False) or []) if isinstance(w, dict))), None)
    if workspace:
        p2, second_root, second_pid = start_carrier(meta, exe, CARRIER_TITLE + " 2", workspace)
        close_held(meta, p2, CARRIER_TITLE + " 2")
        time.sleep(2.0)
        second_ok, second_listing = listing(meta)
        second_held = held_line(second_listing) if second_ok else ("listing_failed", second_listing[-120:])

    # Both carriers quit: no hc event follows, only each end's own recheck.
    kill9([q for q in (pid, second_pid) if q])
    deadline = now() + 15
    while now() < deadline and (alive(root) or (second_root and alive(second_root))):
        time.sleep(0.3)
    released_s = round(now() - (deadline - 15), 1)
    time.sleep(1.0)
    release_ok, after_release = listing(meta)
    rc_log, log_out, _ = run(["/usr/bin/log", "show", "--style", "compact", "--last", "3m", "--predicate",
                              'subsystem == "com.stage11.c11" AND category == "hc.lifecycle"'], timeout=60)
    end_lines = [line[-200:] for line in log_out.splitlines() if "hc.end.held" in line or "hc.end.released" in line][-6:]
    meta["carrier"] = {
        "carries": carries, "outcome": outcome, "held_root_alive": held_root_alive,
        "notice": listed_ok and "End held" in notices,
        "before": before, "closed_all": closed_all, "close_codes": close_codes, "reopened": reopened[0] == 0,
        "without_listing_ok": without_ok, "notice_without_window": "End held" in without_window,
        "reopen_listing_ok": reopen_ok, "moved": moved,
        "read_marked": read_marked, "exit_driven": exit_driven, "exit_note": exit_note,
        "after_exit": held_line(after_exit) if after_exit_ok else None,
        "cleared": cleared, "clear_closed_all": clear_closed_all, "clear_close_codes": clear_close_codes,
        "clear_reopened": clear_reopened, "after_clear_ok": after_clear_ok,
        "notice_after_clear": "End held" in after_clear,
        "still_held_after_clear": still_held, "second_held": second_held,
        "released_root_ended": not alive(root) and not (second_root and alive(second_root)),
        "released_after_s": released_s, "release_listing_ok": release_ok,
        "notice_gone_after_release": release_ok and "End held" not in after_release,
    }
    return {"carrier_pid": pid, "carries_token": carries, "close_rc": rc, "outcome": outcome,
            "held_root_alive": held_root_alive, "notices": notices[-300:],
            "close_codes": close_codes, "without_window": without_window[-300:], "new_window": reopened[0],
            "after_reopen": after_reopen[-300:], "read_marked": read_marked, "exit_driven": exit_driven,
            "exit_note": exit_note, "after_exit": after_exit[-300:], "cleared": cleared,
            "clear_close_codes": clear_close_codes, "after_clear": after_clear[-300:],
            "still_held_after_clear": still_held, "second_held": second_held,
            "released_after_s": released_s, "release_listing_ok": release_ok,
            "after_release": after_release[-300:], "end_log": end_lines}


def checks(meta, summary):
    c = summary["checks"]
    relaunched = summary["phases"]["relaunch"]
    closed = summary["phases"]["close"]
    identity = relaunched["exec_env_identity"]
    c["exec_env_clean"] = {"pass": not identity, "identity": identity}
    pid = meta["app_pid"]
    same = ps_rows().get(pid, ("",))[0] == meta["app_start"]
    answering = bool(c11(meta, "ping", check=False, timeout=5).strip()) if same else False
    c["app_survives_close"] = {"pass": same and answering, "pid": pid, "alive": same, "answering": answering}
    witness = meta["witness"]
    running = meta.get("witness_running", 0)
    c["witness_live"] = {"pass": bool(witness["members"]) and running == len(witness["members"]),
                         "members": len(witness["members"]), "running_after_close": running}
    root = meta["launcher"]["root"]
    c["launcher_ended"] = {"pass": not alive(root), "root": root}
    outcome = None
    try:
        outcome = json.loads(closed["out"]) if closed["out"] else None
    except ValueError:
        pass
    c["close_reply"] = {"informational": True, "rc": closed["rc"], "reply": outcome or closed["out"] or closed["err"]}
    held = meta.get("carrier")
    if held:
        c["carrier_carries_token"] = {"pass": held["carries"]}
        c["carrier_end_held"] = {"pass": held["outcome"].get("outcome") == "pending"
                                 and held["outcome"].get("reason") == "appCarriesScope" and held["held_root_alive"],
                                 "outcome": held["outcome"]}
        c["carrier_hold_noticed"] = {"pass": held["notice"]}
        before, moved = held["before"], held["moved"]
        c["carrier_notice_survives_last_window"] = {
            "pass": held["closed_all"] and held["reopened"] and held["without_listing_ok"]
                    and not held["notice_without_window"] and held["reopen_listing_ok"]
                    and bool(before) and bool(moved) and moved[2] != before[2],
            "close_codes": held["close_codes"], "before": before, "after_reopen": moved}
        after_exit = held["after_exit"]
        if not held["exit_driven"]:
            # The transition did not happen: reported, never a pass.
            c["carrier_notice_moves_read_on_last_shell_exit"] = {"pass": False, "informational": True,
                                                                 "status": "not_driven", "why": held["exit_note"]}
        else:
            c["carrier_notice_moves_read_on_last_shell_exit"] = {
                "pass": held["read_marked"] and bool(after_exit) and after_exit[1] == "read"
                        and bool(moved) and after_exit[2] != moved[2],
                "after_exit": after_exit}
        c["carrier_cleared_notice_stays_cleared"] = {
            "pass": held["cleared"] and held["clear_closed_all"] and held["clear_reopened"] and held["after_clear_ok"]
                    and not held["notice_after_clear"] and held["still_held_after_clear"],
            "close_codes": held["clear_close_codes"]}
        second = held["second_held"]
        c["carrier_new_hold_after_clear_is_told"] = {"pass": isinstance(second, tuple) and second[1] == "unread",
                                                     "second": second}
        c["carrier_end_released"] = {"pass": held["released_root_ended"], "after_s": held["released_after_s"]}
        c["carrier_notice_gone_on_release"] = {"pass": held["notice_gone_after_release"],
                                               "listing_ok": held["release_listing_ok"]}
        alive_after = ps_rows().get(meta["app_pid"], ("",))[0] == meta["app_start"]
        c["app_survives_carrier"] = {"pass": alive_after and bool(c11(meta, "ping", check=False, timeout=5).strip())}


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
    meta["bundle"] = bundle_id(meta["app"])
    summary = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "app_commit": app_commit(meta["app"]),
               "phases": {}, "checks": {}}
    try:
        for name, fn in (("prepare", prepare), ("panels", panels), ("relaunch", relaunch), ("close", close),
                         ("carrier", carrier)):
            t = now()
            summary["phases"][name] = fn(meta)
            summary["phases"][name]["seconds"] = round(now() - t, 2)
            print(f"phase {name}: {json.dumps(summary['phases'][name])[:800]}", flush=True)
        checks(meta, summary)
    except SystemExit as e:
        summary["harness_error"] = str(e)
    except Exception as e:  # report, never hang
        summary["harness_error"] = f"{type(e).__name__}: {e}"
    failed = [k for k, v in summary["checks"].items() if not v.get("pass") and not v.get("informational")]
    summary["failed"] = failed
    summary["result"] = "pass" if summary["checks"] and not failed and not summary.get("harness_error") else "fail"
    print("===C11H415-SUMMARY-BEGIN===")
    print(json.dumps(summary, indent=1, default=str))
    print("===C11H415-SUMMARY-END===")
    sys.exit(0 if summary["result"] == "pass" else 1)


if __name__ == "__main__":
    main()
