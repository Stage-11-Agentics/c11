#!/usr/bin/env python3
"""Crash-resume e2e driver (C11-468). Runs inside a sandbox guest's Aqua
session through run.sh; state lives in /tmp/c468/ in the guest.

Phases:
  setup <cli> <socket> <app> [claude=N codex=N corpus_claude=N corpus_codex=N size=BYTES]
            fake claude/codex on PATH, a synthetic transcript corpus, workspaces
            of agent panels with causal refs (hook push, Codex capture-runtime),
            one resolvable and one unresolvable Codex placeholder
  crash [nosave=1]
            state save (unless nosave), kill -9 c11, purge caches
  relaunch [delay=SECONDS] [fail=1]
            start the app with C11_QA_LAUNCH=resume; delay/fail set the DEBUG
            startup-scrape seams
  collect [wait=S settle=S]
            summarize resume.mode, startup_audit, per-panel decisions, what each
            panel's screen shows (attaching lazy terminals first), state verify
  useapp tar=<path in guest>
            swap in another .app (same tag shares the session file), e.g. a
            baseline build staged in ~/.c11-sandbox/out/<run>/ on the host,
            seen in the guest at "/Volumes/My Shared Files/out/"
  refs      count refs by kind, source, state and diagnostic
  verbdemo  give the unresolved placeholder an id, then drive
            c11 conversation resume (dry run, live, repeat)
"""
import glob
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
import uuid

STATE = "/tmp/c468"
HOME = os.path.expanduser("~")
WORK = os.path.join(HOME, "c468-work")


def sh(*args, check=True, capture=True, env=None):
    r = subprocess.run(args, capture_output=capture, text=True, env=env)
    if check and r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {args}\n{r.stdout}\n{r.stderr}")
    return r.stdout if capture else ""


def load_meta():
    with open(os.path.join(STATE, "meta.json")) as f:
        return json.load(f)


def c11(meta, *args, check=True):
    return sh(meta["cli"], "--socket", meta["socket"], *args, check=check)


def c11_json(meta, *args):
    out = c11(meta, "--json", "--id-format", "both", *args)
    return json.loads(out)


def find_uuid(obj, keys=("panel_id", "surface_id", "id", "workspace_id")):
    if isinstance(obj, dict):
        for k in keys:
            v = obj.get(k)
            if isinstance(v, str) and re.fullmatch(r"[0-9A-Fa-f-]{36}", v):
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


def slug(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def write_blob(path, header, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(header.encode())
        f.write(b"\n")
        f.write(os.urandom(max(0, size - len(header) - 1)))


def fake_agents():
    script = """#!/bin/sh
echo "FAKE-$(basename "$0" | tr a-z A-Z)-RESUMED $*"
exec sleep 2000000
"""
    for name in ("claude", "codex"):
        tmp = f"/tmp/fake-{name}"
        with open(tmp, "w") as f:
            f.write(script)
        os.chmod(tmp, 0o755)
        sh("sudo", "-n", "mkdir", "-p", "/usr/local/bin")
        sh("sudo", "-n", "cp", tmp, f"/usr/local/bin/{name}")
        sh("sudo", "-n", "chmod", "755", f"/usr/local/bin/{name}")


def corpus(claude_files, codex_files, size):
    rnd = random.Random(468)
    projects = os.path.join(HOME, ".claude", "projects")
    sessions = os.path.join(HOME, ".codex", "sessions")
    # Claude: 60 project dirs plus one crowded dir, like the incident machine.
    crowded = os.path.join(projects, slug(os.path.join(WORK, "crowded")))
    for i in range(claude_files):
        d = crowded if i % 12 == 0 else os.path.join(projects, slug(os.path.join(WORK, f"proj-{i % 60}")))
        write_blob(os.path.join(d, f"{uuid.UUID(int=rnd.getrandbits(128), version=4)}.jsonl"),
                   '{"type":"summary"}', size)
    for i in range(codex_files):
        sid = str(uuid.UUID(int=rnd.getrandbits(128), version=4))
        day = 1 + i % 28
        month = 1 + (i // 28) % 9
        path = os.path.join(sessions, f"2026/{month:02d}/{day:02d}/rollout-2026-{month:02d}-{day:02d}T10-00-00-{sid}.jsonl")
        header = json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": os.path.join(WORK, f"old-{i % 90}")}})
        write_blob(path, header, size)


def codex_rollout(sid, cwd):
    sessions = os.path.join(HOME, ".codex", "sessions")
    path = os.path.join(sessions, f"2026/10/21/rollout-2026-10-21T15-00-00-{sid}.jsonl")
    write_blob(path, json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd}}), 4096)
    return path


def setup(argv):
    meta = {"cli": argv[0], "socket": argv[1], "app": argv[2]}
    opts = dict(a.split("=", 1) for a in argv[3:])
    n_claude = int(opts.get("claude", 20))
    n_codex = int(opts.get("codex", 6))
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "meta.json"), "w") as f:
        json.dump(meta, f)

    fake_agents()
    t = time.time()
    corpus(int(opts.get("corpus_claude", 5000)), int(opts.get("corpus_codex", 5000)), int(opts.get("size", 65536)))
    print(f"corpus seeded in {time.time() - t:.1f}s")

    panels = []
    per_ws = 8
    specs = [("claude-code", i) for i in range(n_claude)] + [("codex", i) for i in range(n_codex)] \
        + [("codex-placeholder", 0), ("codex-placeholder", 1)]
    ws_id = None
    for index, (kind, i) in enumerate(specs):
        name = f"{kind}-{i}"
        cwd = os.path.join(WORK, name)
        os.makedirs(cwd, exist_ok=True)
        if index % per_ws == 0:
            ws_id = find_uuid(c11_json(meta, "new-workspace", "--cwd", cwd), ("workspace_id", "id"))
            time.sleep(1.0)
            tree = c11_json(meta, "list-panels", "--workspace", ws_id)
            panel_id = tree["panels"][0]["id"]
        else:
            panel_id = find_uuid(c11_json(meta, "new-panel", "--workspace", ws_id, "--cwd", cwd), ("panel_id", "surface_id", "id"))
        panels.append({"panel": panel_id, "workspace": ws_id, "kind": kind, "cwd": cwd, "name": name})
    time.sleep(3.0)

    for p in panels:
        agent_kind = "codex" if p["kind"].startswith("codex") else "claude-code"
        c11(meta, "set-agent", "--panel", p["panel"], "--workspace", p["workspace"], "--type", agent_kind)
        if p["kind"] == "claude-code":
            sid = str(uuid.uuid4())
            d = os.path.join(HOME, ".claude", "projects", slug(p["cwd"]))
            write_blob(os.path.join(d, f"{sid}.jsonl"), '{"type":"summary"}', 4096)
            c11(meta, "conversation", "push", "--panel", p["panel"], "--kind", "claude-code", "--id", sid,
                "--source", "hook", "--cwd", p["cwd"])
            p["conversation"] = sid
        elif p["kind"] == "codex":
            sid = str(uuid.uuid4())
            codex_rollout(sid, p["cwd"])
            c11(meta, "send", "--workspace", p["workspace"], "--panel", p["panel"],
                f"cd {p['cwd']} && CODEX_THREAD_ID={sid} c11 conversation capture-runtime")
            p["conversation"] = sid
        else:
            c11(meta, "send", "--workspace", p["workspace"], "--panel", p["panel"], f"cd {p['cwd']}")
            time.sleep(0.5)
            c11(meta, "conversation", "claim", "--panel", p["panel"], "--kind", "codex", "--cwd", p["cwd"])
            if p["name"].endswith("-0"):
                time.sleep(1.1)
                sid = str(uuid.uuid4())
                codex_rollout(sid, p["cwd"])
                p["conversation"] = sid
    time.sleep(3.0)
    with open(os.path.join(STATE, "panels.json"), "w") as f:
        json.dump(panels, f, indent=1)
    listing = c11_json(meta, "conversation", "list")
    print(json.dumps({"panels": len(panels), "refs": len(listing.get("conversations", []))}))


def crash(argv):
    meta = load_meta()
    opts = dict(a.split("=", 1) for a in argv)
    out = None
    if opts.get("nosave") != "1":
        out = os.path.join(STATE, f"snapshot-{int(time.time())}.json")
        c11(meta, "state", "save", "--out", out)
        shutil.copy(out, os.path.join(STATE, "last-snapshot.json"))
    sh("sudo", "-n", "killall", "-9", "c11", check=False)
    time.sleep(1.0)
    sh("sudo", "-n", "purge", check=False)
    print(json.dumps({"saved": out}))


def relaunch(argv):
    meta = load_meta()
    opts = dict(a.split("=", 1) for a in argv)
    app = meta["app"]
    binary = os.path.join(app, "Contents/MacOS/c11")
    env = {
        "HOME": HOME, "USER": os.environ.get("USER", "admin"), "LOGNAME": os.environ.get("USER", "admin"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "C11_SOCKET_MODE": "automation", "C11_ALLOW_SOCKET_OVERRIDE": "1",
        "C11_SOCKET": meta["socket"], "C11_SOCKET_PATH": meta["socket"],
        "C11_QA_LAUNCH": "resume",
    }
    if "delay" in opts:
        env["C11_DEBUG_STARTUP_SCRAPE_DELAY_SECONDS"] = opts["delay"]
    if opts.get("fail") == "1":
        env["C11_DEBUG_STARTUP_SCRAPE_FAIL"] = "1"
    sh("sudo", "-n", "rm", "-f", meta["socket"], check=False)
    launched = time.time()
    subprocess.Popen(["nohup", binary], env=env, stdout=open(os.path.join(STATE, "app.out"), "a"),
                     stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(90):
        if os.path.exists(meta["socket"]):
            break
        time.sleep(0.5)
    with open(os.path.join(STATE, "launched_at"), "w") as f:
        f.write(str(launched))
    if not os.path.exists(meta["socket"]):
        raise SystemExit(f"socket {meta['socket']} did not appear; see {STATE}/app.out")
    print(json.dumps({"socket_after_s": round(time.time() - launched, 2)}))


def useapp(argv):
    opts = dict(a.split("=", 1) for a in argv)
    meta = load_meta()
    old_bundle, new_bundle = opts.get("from_bundle"), opts.get("to_bundle")
    if opts.get("tar"):
        dest = os.path.join(HOME, "c11-sandbox", "apps", "swap")
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(dest)
        sh("tar", "-xf", opts["tar"], "-C", dest)
        app = glob.glob(os.path.join(dest, "*.app"))[0]
        sh("xattr", "-cr", app, check=False)
        meta["app"] = app
        meta["cli"] = os.path.join(app, "Contents/Resources/bin/c11")
    if old_bundle and new_bundle:
        support = os.path.join(HOME, "Library/Application Support/c11")
        shutil.copy(os.path.join(support, f"session-{old_bundle}.json"),
                    os.path.join(support, f"session-{new_bundle}.json"))
        for suffix in ("dirty", "clean"):
            path = os.path.join(HOME, ".c11/runtime", f"shutdown.{new_bundle}.{suffix}")
            if os.path.exists(path):
                os.remove(path)
    json.dump(meta, open(os.path.join(STATE, "meta.json"), "w"))
    print(json.dumps(meta))


def refs(argv):
    meta = load_meta()
    listing = c11_json(meta, "conversation", "list")
    import collections
    counts = collections.Counter(
        (c["kind"], c["captured_via"], c["state"], (c.get("diagnostic_reason") or "")[:48])
        for c in listing.get("conversations", []))
    for k, v in sorted(counts.items()):
        print(v, *k)


def verbdemo(argv):
    meta = load_meta()
    panels = json.load(open(os.path.join(STATE, "panels.json")))
    target = next(p for p in panels if p["name"] == "codex-placeholder-1")
    sid = str(uuid.uuid4())
    codex_rollout(sid, target["cwd"])
    c11(meta, "conversation", "push", "--panel", target["panel"], "--kind", "codex", "--id", sid,
        "--source", "manual", "--cwd", target["cwd"])
    print("DRY-RUN", c11(meta, "conversation", "resume", "--all-skipped", "--dry-run", "--json"))
    print("LIVE", c11(meta, "conversation", "resume", "--all-skipped", "--json"))
    print("SECOND", c11(meta, "conversation", "resume", "--panel", target["panel"], "--json"))
    c11(meta, "read-screen", "--workspace", target["workspace"], "--panel", target["panel"], "--lines", "5", check=False)
    time.sleep(6)
    screen = c11(meta, "read-screen", "--workspace", target["workspace"], "--panel", target["panel"], "--lines", "12", check=False)
    print("SCREEN", screen.strip().splitlines()[-3:])
    print("TYPED_ONCE", screen.count("FAKE-CODEX-RESUMED") == 1 and sid in screen, sid)


def newest_events():
    files = glob.glob(os.path.join(HOME, "Library/Application Support/c11*/events/events-*.ndjson"))
    return max(files, key=os.path.getmtime) if files else None


def collect(argv):
    meta = load_meta()
    opts = dict(a.split("=", 1) for a in argv)
    time.sleep(float(opts.get("wait", 20)))
    panels = json.load(open(os.path.join(STATE, "panels.json")))
    events_path = newest_events()
    events = [json.loads(l) for l in open(events_path)] if events_path else []
    mode = [e["payload"] for e in events if e.get("type") == "conversation.resume.mode"]
    audits = [e for e in events if e.get("type") == "conversation.startup_audit"]
    decisions = {}
    for e in events:
        if e.get("type") == "conversation.resume.decision":
            decisions[(e.get("panel") or e.get("surface") or "").upper()] = {"ts": e.get("ts"), **e["payload"]}
    rows = []
    resumed = 0
    # Background-workspace terminals attach lazily; a first read attaches them
    # and flushes any queued resume text.
    for p in panels:
        c11(meta, "read-screen", "--workspace", p["workspace"], "--panel", p["panel"], "--lines", "5", check=False)
    time.sleep(float(opts.get("settle", 8)))
    for p in panels:
        screen = c11(meta, "read-screen", "--workspace", p["workspace"], "--panel", p["panel"], "--lines", "40", check=False)
        marker = "FAKE-CLAUDE-RESUMED" if p["kind"] == "claude-code" else "FAKE-CODEX-RESUMED"
        ok = marker in screen and (p.get("conversation") or "") in screen
        p["screen_tail"] = screen.strip().splitlines()[-1:] if screen.strip() else []
        resumed += ok
        d = decisions.get(p["panel"].upper()) or {}
        rows.append({"name": p["name"], "resumed_on_screen": ok, "decision": d.get("decision"),
                     "screen_tail": p["screen_tail"],
                     "skip_code": d.get("skip_code"), "reason": d.get("reason"), "ts": d.get("ts")})
    verify = c11(meta, "state", "verify", "--mode", "dirty", os.path.join(STATE, "last-snapshot.json"), check=False)
    summary = {
        "events_file": events_path,
        "mode": mode[-1] if mode else None,
        "startup_audit": audits[-1]["payload"] if audits else None,
        "resumed_on_screen": resumed,
        "panels": len(panels),
        "rows": rows,
        "state_verify": verify[:4000],
    }
    out = os.path.join(STATE, f"collect-{int(time.time())}.json")
    json.dump(summary, open(out, "w"), indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    phase, rest = sys.argv[1], sys.argv[2:]
    {"setup": setup, "crash": crash, "relaunch": relaunch, "collect": collect, "useapp": useapp, "refs": refs, "verbdemo": verbdemo}[phase](rest)
