#!/usr/bin/env python3
"""Atlas main-tip backstop. Dry runs build normally but never post commit statuses."""
from __future__ import annotations

import argparse
from datetime import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid
from zoneinfo import ZoneInfo


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


poller = module("poller", "c11-pr-swift-poller.py")
quarantine = module("quarantine", "host_test_quarantine.py")
CONTEXT = "c11/main-atlas"
LABEL = "com.stage11.c11-main-backstop"
ROOT = Path.home() / "c11-main-backstop"
SLOTS = Path.home() / "c11-poller/bin/atlas_build_slots.py"
CADENCE = 30
TIMEOUT = 900


class Deferred(Exception):
    pass


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, sort_keys=True) + "\n")
    temporary.replace(path)


def read(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def record(root, event, **fields):
    row = {"time": datetime.now(ZoneInfo("America/Los_Angeles")).isoformat(), "event": event, **fields}
    with (root / "state/events.jsonl").open("a") as output:
        output.write(json.dumps(row, sort_keys=True) + "\n")
    print(json.dumps(row, sort_keys=True), flush=True)


def command(argv, cwd=None, env=None, timeout=120):
    return subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True,
                          check=True, timeout=timeout).stdout.strip()


def git(repo, *args):
    poller.assert_git_args(args)
    return command(["/usr/bin/git", "-c", "protocol.file.allow=never", "-c",
                    "core.hooksPath=/dev/null", *args], cwd=repo,
                   env=poller.git_base_env(), timeout=180)


def api(path, *args):
    env = os.environ.copy()
    for key in poller.GH_ENV_DROP:
        env.pop(key, None)
    return json.loads(command(["/opt/homebrew/bin/gh", "api", *args,
                               "repos/" + poller.REPO_NAME + "/" + path], env=env, timeout=30))


def remote_tip():
    output = git(None, "ls-remote", "--refs", poller.PARENT_URL, "refs/heads/main")
    parts = output.split()
    if len(parts) != 2 or parts[1] != "refs/heads/main" or not poller.SHA_RE.fullmatch(parts[0]):
        raise RuntimeError("main lookup did not return exactly one SHA")
    return parts[0]


def pr_work_pending():
    """Use the poller's admission policy and terminal states, never its writable state."""
    page = 1
    deadline = time.monotonic() + 30
    while page <= 10:
        if time.monotonic() >= deadline:
            raise Deferred("PR queue inspection exceeded 30 seconds")
        rows = api(f"pulls?state=open&per_page=100&page={page}")
        if not isinstance(rows, list):
            raise RuntimeError("unreadable PR queue")
        for row in rows:
            admitted, _, captured = poller.admit(row)
            if not admitted:
                continue
            if time.monotonic() >= deadline:
                raise Deferred("PR queue inspection exceeded 30 seconds")
            statuses = api(f"commits/{captured['sha']}/status")["statuses"]
            status = next((s["state"] for s in statuses if s["context"] == "c11/pr-swift"), None)
            if status not in poller.TERMINAL_STATES:
                return True
        if len(rows) < 100:
            return False
        page += 1
    raise RuntimeError("PR queue exceeds pagination limit")


def guest_running():
    rows = command(["/opt/homebrew/bin/tart", "list"], timeout=15)
    return bool(poller.running_guests(rows))


def prepare(root):
    repo = root / "worktree"
    if not repo.exists():
        git(root, "clone", "--no-checkout", "--no-tags", poller.PARENT_URL, str(repo))
    if git(repo, "remote", "get-url", "origin") != poller.PARENT_URL:
        raise RuntimeError("unexpected worktree origin")
    # No caller SHA or ref: the fetch itself selects authoritative main at admission.
    git(repo, "fetch", "--no-tags", "--no-recurse-submodules", poller.PARENT_URL,
        "+refs/heads/main:refs/remotes/origin/main")
    sha = git(repo, "rev-parse", "refs/remotes/origin/main")
    previous = read(root / "state/accepted.json", {}).get("sha")
    if previous and previous != sha:
        try:
            git(repo, "merge-base", "--is-ancestor", previous, sha)
        except subprocess.CalledProcessError as error:
            raise RuntimeError("main rewound or history was replaced; operator reconciliation required") from error
    write(root / "state/accepted.json", {"sha": sha})
    git(repo, "reset", "--hard", sha)
    git(repo, "clean", "-ffdx")
    for path, url in poller.GITLINKS:
        sub = repo / path
        if not (sub / ".git").exists():
            sub.mkdir(parents=True, exist_ok=True)
            git(sub, "init")
        pin = git(repo, "rev-parse", f"{sha}:{path}")
        git(sub, "fetch", "--no-tags", "--no-recurse-submodules", url, pin)
        git(sub, "reset", "--hard", pin)
        git(sub, "clean", "-ffdx")
    ghostty = git(repo, "rev-parse", f"{sha}:ghostty")
    if poller.link_ghosttykit(Path.home() / ".cache/cmux/ghosttykit", ghostty, repo) != "ok":
        raise RuntimeError("main's GhosttyKit cache is missing")
    if remote_tip() != sha:
        raise Deferred("main advanced during preparation")
    return repo, sha


def gate(root, repo, sha, attempt):
    texts = [(repo / p).read_text() if (repo / p).exists() else "" for p in poller.PACKAGE_RESOLVED]
    key = poller.dependency_key(texts, [git(repo, "rev-parse", f"HEAD:{p}") for p, _ in poller.GITLINKS])
    derived = root / "cache" / ("DerivedData-" + key)
    env = poller.build_env()
    for name in ("C11_ATLAS_BUILD_SLOT", "C11_BUILD_LOCK_DIR"):
        env[name] = os.environ[name]
    env["C11_BUILD_LOCK_TIMEOUT"] = "0"
    env["C11_TEST_DERIVED_DATA"] = str(derived)
    rows = quarantine.read_host_test_quarantine(repo / "scripts/host-test-quarantine.tsv")
    record(root, "quarantine", sha=sha, rows=rows)
    skips = ["-skip-testing:" + row["test_id"] for row in rows]
    common = ["-project", "GhosttyTabs.xcodeproj", "-configuration", "Debug", "-destination",
              "platform=macOS", "-derivedDataPath", str(derived), "COMPILER_INDEX_STORE_ENABLE=NO"]
    stages = [("app", [str(repo / "scripts/with-build-lock.sh"), poller.XCODEBUILD,
                       *common, "-scheme", "c11", "build"], None, {})]
    for name, scheme, selectors, overrides in (
        ("logic", "c11-logic", ["-only-testing:c11LogicTests"], {"C11_TEST_PARALLEL_WORKERS": "8"}),
        ("host", "c11-unit", ["-only-testing:c11Tests"], {}),
    ):
        result = attempt / (name + ".xcresult")
        stages.append((name, [str(repo / "scripts/test-unit-local.sh"), *selectors, *skips,
                              "-resultBundlePath", str(result), "COMPILER_INDEX_STORE_ENABLE=NO"],
                       result, {"C11_TEST_SCHEME": scheme, **overrides}))
    cli = derived / "Build/Products/Debug/c11"
    env.update({"C11_CLI_BIN": str(cli), "C11_CLI": str(cli)})
    for filename in ("test_cli_ssh_shell_bootstrap.py", "test_cli_focus_history.py",
                     "test_cli_window_scope.py", "test_cli_activity_analysis.py", "test_mailbox_body_cli.py"):
        args = ["/usr/bin/python3", "tests/" + filename]
        if filename == "test_mailbox_body_cli.py":
            args.append(str(cli))
        stages.append((filename, args, None, {}))
    stages.extend([
        ("send-raw", ["/usr/bin/python3", "tests_v2/test_send_raw_and_flags.py", "--offline"], None, {}),
        ("shell", ["/bin/bash", "tests/test_shell_git_watchers.sh"], None, {}),
    ])
    # A quick link or CodeSign failure in any xcodebuild stage is a stale cache:
    # empty this key's DerivedData once and rerun the whole gate from the app build.
    for run in (1, 2):
        state, outcomes, stale = run_stages(root, repo, sha, attempt, stages, env, run)
        if stale is None or run == 2:
            return state, outcomes
        record(root, "stale-cache", sha=sha, deps=key, stage=stale[0], kind=stale[1], seconds=stale[2])
        poller.empty_derived_data(derived)
    return state, outcomes


XCODEBUILD_STAGES = ("app", "logic", "host")


def run_stages(root, repo, sha, attempt, stages, env, run):
    outcomes = []
    for name, argv, result, overrides in stages:
        if result is not None and run > 1:
            # xcodebuild refuses an existing -resultBundlePath, and run 1 left one.
            rerun = result.with_name("%s-%s.xcresult" % (result.stem, run))
            argv = [str(rerun) if arg == str(result) else arg for arg in argv]
            result = rerun
        started = time.monotonic()
        log = attempt / ("%s.log" % name if run == 1 else "%s-%s.log" % (name, run))
        with log.open("w") as output:
            code = subprocess.call(argv, cwd=repo, env={**env, **overrides}, stdout=output, stderr=output)
        elapsed = time.monotonic() - started
        summary = unreadable = None
        if result is not None and code == 0:
            summary, unreadable = poller.read_summary(lambda: poller.xcresult_summary(result), time.sleep, tries=2)
        if code == 75:
            raise Deferred("build lock unavailable")
        state = "failure" if code else "success"
        if result is not None and code == 0:
            state, _ = poller.classify_result(elapsed, summary, unreadable)
        row = {"stage": name, "exit": code, "seconds": round(elapsed, 3), "state": state, "summary": summary,
               "run": run}
        if unreadable:
            row["unreadable"] = unreadable
        outcomes.append(row)
        record(root, "stage", sha=sha, **row)
        if state != "success":
            if code and name in XCODEBUILD_STAGES and elapsed < poller.STALE_CACHE_S:
                kind = poller.stale_cache_signature(log.read_text(errors="replace"))
                if kind:
                    return state, outcomes, (name, kind, round(elapsed, 3))
            return state, outcomes, None
    return "success", outcomes, None


def child(root, attempt):
    if os.environ.get("C11_ATLAS_BUILD_SLOT") != "1":
        raise RuntimeError("backstop requires reserved slot 1")
    with (root / "state/running.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sha = None
        started = time.monotonic()
        load = os.getloadavg()[0]
        try:
            if guest_running() or pr_work_pending():
                raise Deferred("guest or PR work has priority")
            repo, sha = prepare(root)
            # Revalidate after all slow preparation, immediately before any checkout code.
            if pr_work_pending() or remote_tip() != sha:
                raise Deferred("PR work queued or main advanced")
            record(root, "build-start", sha=sha, load1=load)
            state, stages = gate(root, repo, sha, attempt)
            result = {"sha": sha, "state": state, "stages": stages}
        except Deferred as error:
            result = {"sha": sha, "state": "deferred", "reason": str(error)}
        except Exception as error:
            result = {"sha": sha, "state": "error", "reason": type(error).__name__ + ": " + str(error)}
        result.update(seconds=round(time.monotonic() - started, 3), load1=load)
        write(attempt / "result.json", result)
        return 0


def post(result):
    if result.get("sha") and result["state"] in ("success", "failure", "error"):
        api("statuses/" + result["sha"], "-X", "POST", "-f", "context=" + CONTEXT,
            "-f", "state=" + result["state"], "-f",
            f"description=Atlas app, logic, host, CLI gate: {result['state']} ({int(result['seconds'])}s)")


def cycle(root, publish=False, force=False):
    if guest_running() or pr_work_pending():
        record(root, "deferred", reason="guest or PR work has priority")
        return "deferred"
    tip = remote_tip()
    last = read(root / "state/last.json", {})
    if not force and last.get("sha") == tip and last.get("state") in ("success", "failure"):
        record(root, "unchanged", sha=tip)
        return "unchanged"
    attempt = root / "state/results" / uuid.uuid4().hex
    attempt.mkdir(parents=True)
    env = poller.build_env()
    env["C11_BUILD_LOCK_TIMEOUT"] = "0"  # Never queue ahead of the PR poller.
    argv = ["/usr/bin/python3", str(SLOTS), "astra-466", "--poller", "/usr/bin/python3",
            str(Path(__file__).resolve()), "child", "--root", str(root), "--attempt", str(attempt)]
    with (attempt / "admission.log").open("w") as log:
        process = subprocess.Popen(argv, env=env, stdout=log, stderr=log, start_new_session=True)
        poller.write_running(root, {"pgid": process.pid})
        started = time.monotonic()
        interruption = None
        priority_check = time.monotonic()
        try:
            while process.poll() is None:
                if time.monotonic() - started > TIMEOUT:
                    interruption = "hard deadline exceeded"
                    break
                if guest_running():
                    interruption = "yielded to sandbox guest"
                    break
                if time.monotonic() - priority_check >= CADENCE:
                    if pr_work_pending():
                        interruption = "yielded to PR work"
                        break
                    priority_check = time.monotonic()
                time.sleep(5)
        finally:
            if poller.recover(root) != "ready":
                raise RuntimeError("build process tree did not exit")
            process.wait(timeout=15)
    result = read(attempt / "result.json")
    if interruption or process.returncode == 75:
        record(root, "deferred", reason=interruption or "slot 1 unavailable", attempt=str(attempt))
        return "deferred"
    if result is None:
        record(root, "error", reason="child produced no result", exit=process.returncode, attempt=str(attempt))
        return "error"
    record(root, "result", attempt=str(attempt), dry_run=not publish, **result)
    # A failed POST keeps last.json unchanged, so it can be retried on the next cycle.
    if publish:
        post(result)
    if result["state"] in ("success", "failure"):
        write(root / "state/last.json", result)
    return result["state"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("once", "supervise", "child", "recover"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--publish", action="store_true", help="post c11/main-atlas; requires installed enable record")
    parser.add_argument("--force", action="store_true", help="repeat a completed tip for a warm measurement")
    parser.add_argument("--attempt", type=Path)
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    if root == (Path.home() / "c11-poller").resolve() or (Path.home() / "c11-poller").resolve() in root.parents:
        parser.error("the PR poller root is off limits")
    if root / "worktree" in Path(__file__).resolve().parents:
        parser.error("runner must live outside its build checkout")
    (root / "state").mkdir(parents=True, exist_ok=True)
    if args.mode == "child":
        if args.attempt is None or root / "state/results" not in args.attempt.resolve().parents:
            parser.error("child requires its own result directory")
        return child(root, args.attempt)
    with (root / "state/supervisor.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 75
        if poller.recover(root) != "ready":
            return 2
        if args.mode == "recover":
            return 0
        if args.publish and (root != ROOT.resolve() or read(root / "state/enabled.json") != {"enabled": True}):
            parser.error("publishing requires the installed, enabled backstop root")
        # launchctl bootout must unwind the running tree before releasing admission.
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            try:
                outcome = cycle(root, args.publish, args.force)
            except Deferred as error:
                record(root, "deferred", reason=str(error))
                outcome = "deferred"
            except Exception as error:
                record(root, "error", reason=type(error).__name__ + ": " + str(error))
                outcome = "error"
            if args.mode == "once":
                return 0 if outcome in ("success", "unchanged") else 75 if outcome == "deferred" else 1
            time.sleep(CADENCE)


if __name__ == "__main__":
    sys.exit(main())
