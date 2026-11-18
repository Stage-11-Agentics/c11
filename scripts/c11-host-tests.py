#!/usr/bin/env python3
"""Run the host-app test suite (c11Tests) on main's tip in a disposable sandbox guest.

The build host builds `c11-unit` for testing in a fleet slot; a guest clone that carries the
build host's own Xcode runs `xcodebuild test-without-building`. Never a merge gate: it posts
no GitHub status and reports red runs to the Lattice board. docs/c11-host-tests-lane.md.
"""

from __future__ import annotations

import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime


REPO_URL = "https://github.com/Stage-11-Agentics/c11h.git"
# The slot runner comes from the tested checkout (main's current copy), not an older installed one.
SLOT_RUNNER_OVERRIDE = os.environ.get("C11_HOST_TESTS_SLOT_RUNNER")
XCODE_APP = Path(os.environ.get("C11_HOST_TESTS_XCODE", "/Applications/Xcode-26.3.app"))
TART = os.environ.get("C11_HOST_TESTS_TART", "/opt/homebrew/bin/tart")
SANDBOX_ROOT = Path(os.environ.get("C11_HOST_TESTS_SANDBOX_ROOT", str(Path.home() / ".c11-sandbox")))
SANDBOX_KEY = Path.home() / ".ssh" / "c11-sandbox"
GOLDEN = os.environ.get("C11_HOST_TESTS_GOLDEN", "c11-sandbox-golden")
GUEST_USER = "admin"
VM_PREFIX = "c11-ht-"
BOARD_ACTOR = "agent:c11-host-tests"
RED_TAG = "host-tests-red"
INFRA_TAG = "host-tests-infra"

BUILD_TIMEOUT_S = 1800      # after slot admission
GUEST_TIMEOUT_S = 1500      # clone through teardown
SLOT_ADMISSION_S = 1200     # waiting for a fleet build slot; past it the run defers
GUEST_WAIT_S = 900          # how long a built run waits for a free guest before deferring
RUN_TIMEOUT_S = 5400        # the whole run: covers admission + build + guest wait + guest phase
QUIET_AFTER_SANDBOX_S = 600 # an owner between sandbox-down and sandbox-up keeps the guest
MAX_LOAD = 40.0
MIN_FREE_GIB = 45
MAX_INFRA_PER_TIP = 3
BOARD_TIMEOUT_S = 120
FAILURE_TEXT_CHARS = 200
REPORT_FAILURES = 40
KEEP_CACHES = 2
RETENTION_S = 14 * 24 * 60 * 60
# Paths whose change alone does not touch the host app or its tests: docs/, notes/ and top-level
# Markdown. Markdown elsewhere can be a fixture (c11Tests/) or ship in the app (skills/, Resources/).
DOCS_ONLY = re.compile(r"(^docs/|^notes/|^[^/]+\.md$)")


# ---------------------------------------------------------------- small helpers

def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def log(message: str) -> None:
    print(f"[{now_iso()}] {message}", flush=True)


def git(repo: Path, *args: str, timeout: int = 300) -> str:
    result = subprocess.run(["/usr/bin/git", "-C", str(repo), *args],
                            check=True, capture_output=True, text=True, timeout=timeout)
    return result.stdout.strip()


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as out:
        fcntl.flock(out.fileno(), fcntl.LOCK_EX)
        out.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    try:
        with path.open(encoding="utf-8") as src:
            for line in src:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if type(row) is dict:
                    rows.append(row)
    except FileNotFoundError:
        pass
    return rows


def load_average() -> float | None:
    try:
        return round(os.getloadavg()[0], 2)
    except OSError:
        return None


def free_gib(path: Path) -> float:
    usage = shutil.disk_usage(path)
    return usage.free / (1 << 30)


def kill_tree(pid: int, grace: float = 10.0) -> None:
    """TERM then KILL the process group this lane started (start_new_session), by its PID."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            try:
                os.killpg(pid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.2)


# ---------------------------------------------------------------- decisions (pure)

def is_docs_only(paths: list[str]) -> bool:
    """True when every changed path is documentation, so the host suite has nothing new to run."""
    return bool(paths) and all(DOCS_ONLY.search(p) for p in paths)


TERMINAL = ("success", "failure")


def counted(records: list[dict]) -> list[dict]:
    """Rows that decide what the lane does next: a dry run never marks a tip tested or failed."""
    return [r for r in records if not r.get("dry_run")]


def last_terminal(records: list[dict]) -> dict | None:
    for row in reversed(counted(records)):
        if row.get("state") in TERMINAL or row.get("state") == "skipped-docs":
            return row
    return None


def infra_count(records: list[dict], tip: str) -> int:
    """Consecutive infrastructure errors at this tip, newest first."""
    n = 0
    for row in reversed(counted(records)):
        if row.get("tip") != tip:
            continue
        if row.get("state") == "error":
            n += 1
        elif row.get("state") in TERMINAL:
            break
    return n


def infra_streak(records: list[dict]) -> int:
    """Consecutive infrastructure errors across tips, newest first; a real result ends the streak."""
    n = 0
    for row in reversed(counted(records)):
        if row.get("state") == "error":
            n += 1
        elif row.get("state") in TERMINAL:
            break
    return n


def tip_decision(records: list[dict], tip: str, changed_since_last: list[str] | None,
                 force: bool) -> str:
    """run | unchanged | docs-only | infra-capped."""
    if force:
        return "run"
    last = last_terminal(records)
    if last is not None and last.get("tip") == tip:
        return "unchanged"
    if infra_count(records, tip) >= MAX_INFRA_PER_TIP:
        return "infra-capped"
    if last is not None and changed_since_last is not None and is_docs_only(changed_since_last):
        return "docs-only"
    return "run"


def guest_gate(running_vms: list[str], sandbox_activity_age_s: float | None, load: float | None,
               free: float) -> str | None:
    """None when the lane may take a guest; otherwise the reason it waits."""
    if running_vms:
        return "a guest is running: " + ",".join(running_vms)
    if sandbox_activity_age_s is not None and sandbox_activity_age_s < QUIET_AFTER_SANDBOX_S:
        return f"sandbox activity {int(sandbox_activity_age_s)}s ago"
    if load is not None and load >= MAX_LOAD:
        return f"one-minute load {load}"
    if free < MIN_FREE_GIB:
        return f"only {free:.0f} GiB free"
    return None


def open_tickets(tasks: list[dict]) -> list[dict]:
    return [t for t in tasks if t.get("status") not in ("done", "cancelled")]


def report_action(state: str, tip: str, records: list[dict], red_open: list[dict],
                  infra_open: list[dict]) -> dict | None:
    """What the board should hear about this run, or None.

    failure: create the red ticket, or comment on the open one.
    success: comment on an open red ticket (green again); otherwise nothing.
    error: only the third consecutive infrastructure error at one tip reaches the board.
    """
    short = tip[:10]
    if state == "failure":
        if red_open:
            return {"op": "comment", "task": red_open[0]["short_id"], "tag": RED_TAG}
        return {"op": "create", "tag": RED_TAG, "title": f"c11Tests red on main {short}"}
    if state == "success":
        # Only the first green after a red: records end with this run, so look before it.
        previous = next((r for r in reversed(counted(records[:-1])) if r.get("state") in TERMINAL), None)
        if red_open and previous is not None and previous.get("state") == "failure":
            return {"op": "comment", "task": red_open[0]["short_id"], "tag": RED_TAG, "green": True}
        return None
    # Every third infrastructure error in a row reaches the board, across tips, so a lane that fails
    # at every new tip is never silent.
    if state == "error" and infra_streak(records) % MAX_INFRA_PER_TIP == 0:
        if infra_open:
            return {"op": "comment", "task": infra_open[0]["short_id"], "tag": INFRA_TAG}
        return {"op": "create", "tag": INFRA_TAG, "title": f"c11Tests lane cannot run main {short}"}
    return None


def summarize(summary: object) -> tuple[str, str, list[str], dict]:
    """(state, reason, failing test ids, counts) from an xcresult test summary."""
    if type(summary) is not dict:
        return "error", "xcresult summary unavailable", [], {}
    counts = {k: summary.get(k) for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    failures = []
    for item in summary.get("testFailures") or []:
        if type(item) is dict:
            name = item.get("testIdentifierString") or item.get("testName") or "?"
            first = (str(item.get("failureText") or "").strip().splitlines() or [""])[0]
            text = " ".join(first.split())[:FAILURE_TEXT_CHARS]
            failures.append(f"{item.get('targetName', 'c11Tests')}/{name}" + (f" :: {text}" if text else ""))
    total, skipped, failed = counts["totalTestCount"], counts["skippedTests"], counts["failedTests"]
    if type(total) is not int or type(skipped) is not int or type(failed) is not int:
        return "error", "xcresult summary is missing test counts", failures, counts
    if total - skipped <= 0:
        return "failure", "zero executed tests", failures, counts
    if failed > 0 or summary.get("result") == "Failed":
        return "failure", f"{failed} failed tests", failures, counts
    if summary.get("result") == "Passed":
        return "success", f"{counts['passedTests']} passed", failures, counts
    return "error", f"unrecognized xcresult result {summary.get('result')!r}", failures, counts


# ---------------------------------------------------------------- the host side

def tart(*args: str, timeout: int = 120, check: bool = True) -> str:
    result = subprocess.run([TART, *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"tart {' '.join(args)} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout


def tart_vms() -> dict[str, str]:
    vms = {}
    for line in tart("list").splitlines():
        fields = line.split()
        if len(fields) < 3 or fields[0] == "Source":
            continue
        vms[fields[1]] = fields[-1]
    return vms


def running_vms() -> list[str]:
    return sorted(n for n, st in tart_vms().items() if st != "stopped")


def sandbox_activity_age() -> float | None:
    newest = None
    for path in [SANDBOX_ROOT / "runs", SANDBOX_ROOT / "clone.lock"]:
        candidates = [path]
        if path.is_dir() and path.name == "runs":
            candidates += list(path.iterdir())
        for item in candidates:
            try:
                mtime = item.stat().st_mtime
            except FileNotFoundError:
                continue
            newest = mtime if newest is None else max(newest, mtime)
    return None if newest is None else time.time() - newest


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def process_identity(pid: int) -> dict | None:
    """A process's start time and exact command line as ps reports them, or None when it is gone
    (a zombie counts as gone). sandbox-up.sh compares the same two ps fields the same way."""
    if pid <= 0:
        return None

    def ps(field: str) -> str:
        # Pinned locale and zone: lstart prints by LC_TIME and TZ, and the lane (under launchd) and an
        # owner's sandbox-up (under its shell) must read the same identity the same way.
        return subprocess.run(["/bin/ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True,
                              env=dict(os.environ, LC_ALL="C", TZ="UTC0")).stdout.strip()

    stat = ps("stat")
    if not stat or stat.startswith("Z"):
        return None
    start, command = ps("lstart"), ps("command")
    return {"start": start, "command": command} if start and command else None


def identity_matches(pid: object, recorded: object) -> bool:
    """A recorded PID is the recorded process only if its start time and command line are unchanged.
    Anything else (gone, reused, never recorded) never authorizes a signal."""
    if type(pid) is not int or type(recorded) is not dict or not recorded.get("start"):
        return False
    return process_identity(pid) == {"start": recorded.get("start"), "command": recorded.get("command")}


def lane_alive(claim: dict) -> bool:
    """A claim's lane is alive only while its PID is still that same lane process."""
    return identity_matches(claim.get("pid"), claim.get("lane"))


def claims_dir() -> Path:
    return SANDBOX_ROOT / "host-tests" / "owned"


def claim_vm(vm: str, root: Path, run_id: str, producer: dict | None = None) -> None:
    """Record a lane guest as ours before anything can create it. Deletion authority is this record,
    never the c11-ht- prefix; sandbox-up reads these records to preempt the lane. `pid` is the lane
    process; `producer_pid` is the tart process that may be creating or starting the VM right now
    (its command line names the VM), which sandbox-up stops before it takes the guest back. Each PID
    is stored with its identity (start time and exact command line): only a process that still
    matches it may ever be signalled."""
    claims_dir().mkdir(parents=True, exist_ok=True)
    tmp = claims_dir() / f".{vm}.{os.getpid()}"
    row = {"vm": vm, "root": str(root), "pid": os.getpid(), "lane": process_identity(os.getpid()),
           "run_id": run_id, "time": now_iso()}
    if producer is not None:
        row["producer_pid"] = producer["pid"]
        row["producer"] = producer["identity"]
    tmp.write_text(json.dumps(row))
    os.replace(tmp, claims_dir() / f"{vm}.json")


def read_claims() -> list[dict]:
    rows = []
    for path in sorted(claims_dir().glob("*.json")) if claims_dir().exists() else []:
        try:
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if type(row) is dict and row.get("vm") == path.stem:
            rows.append(row)
    return rows


def delete_vm(name: str) -> None:
    """Stop and delete a guest this lane recorded as its own, then drop the record."""
    claim = claims_dir() / f"{name}.json"
    if not name.startswith(VM_PREFIX):
        raise RuntimeError(f"refusing to delete VM {name}: not a lane guest")
    if not claim.exists():
        if name not in tart_vms():
            return  # already gone and released (a yield's cleanup finished first)
        raise RuntimeError(f"refusing to delete VM {name}: not recorded as a lane guest")
    # The guest is disposable: no graceful shutdown, so a yield never waits on it.
    tart("stop", name, "--timeout", "2", timeout=15, check=False)
    tart("delete", name, timeout=30, check=False)
    for _ in range(20):  # a concurrent delete (yield watcher, sandbox-up) may still be finishing
        if name not in tart_vms():
            break
        time.sleep(0.5)
    else:
        tart("delete", name, timeout=30, check=False)
        if name in tart_vms():
            raise RuntimeError(f"lane guest {name} is still present after delete")
    claim.unlink(missing_ok=True)


def budget(deadline: float, cap: float | None = None) -> float:
    """Seconds left before `deadline`, at most `cap`; past it, the phase is over."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError(f"guest phase passed {GUEST_TIMEOUT_S}s")
    return left if cap is None else min(left, cap)


def yield_path(vm: str) -> Path:
    return SANDBOX_ROOT / "lane-yield" / vm


class CloneLock:
    """sandbox-up's mkdir lock: held only while choosing and booting a clone."""

    def __init__(self) -> None:
        self.path = SANDBOX_ROOT / "clone.lock"
        self.held = False

    def acquire(self, timeout: float, cancelled) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if cancelled():
                raise InterruptedError("yielded to sandbox-up")
            try:
                self.path.mkdir(parents=True)
            except FileExistsError:
                try:
                    pid = (self.path / "pid").read_text().strip()
                except OSError:
                    pid = ""  # released, or not yet written, between our mkdir and this read
                if pid.isdigit() and not pid_alive(int(pid)):
                    shutil.rmtree(self.path, ignore_errors=True)
                    continue
                time.sleep(0.5)
                continue
            (self.path / "pid").write_text(f"{os.getpid()}\n")
            (self.path / "run").write_text("host-tests\n")
            self.held = True
            return
        raise TimeoutError("clone.lock stayed held")

    def release(self) -> None:
        # An owner whose deadline passed may have taken the lock over: never remove theirs.
        if self.held:
            try:
                mine = (self.path / "pid").read_text().strip() == str(os.getpid())
            except OSError:
                mine = False
            if mine:
                shutil.rmtree(self.path, ignore_errors=True)
            self.held = False


def prepare_worktree(root: Path, ref: str) -> tuple[Path, str]:
    worktree = root / "worktree"
    if not worktree.exists():
        subprocess.run(["/usr/bin/git", "clone", "--no-tags", REPO_URL, str(worktree)],
                       check=True, timeout=600)
    origin = git(worktree, "remote", "get-url", "origin").removesuffix(".git")
    if origin != REPO_URL.removesuffix(".git"):
        raise RuntimeError(f"unexpected worktree origin: {origin}")
    if git(worktree, "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("lane worktree has local changes; refusing to reset it")
    git(worktree, "fetch", "--no-tags", "origin", f"+refs/heads/{ref}:refs/remotes/origin/{ref}")
    git(worktree, "checkout", "--detach", "--force", f"refs/remotes/origin/{ref}")
    tip = git(worktree, "rev-parse", "HEAD")
    git(worktree, "submodule", "update", "--init", "--recursive", "ghostty", "vendor/bonsplit",
        timeout=900)
    return worktree, tip


def changed_paths(worktree: Path, old: str, new: str) -> list[str] | None:
    try:
        out = git(worktree, "diff", "--name-only", f"{old}..{new}")
    except subprocess.CalledProcessError:
        return None
    return [p for p in out.splitlines() if p]


def link_ghosttykit(worktree: Path) -> None:
    gitlink = git(worktree, "rev-parse", "HEAD:ghostty")
    kit = Path.home() / ".cache" / "cmux" / "ghosttykit" / gitlink / "GhosttyKit.xcframework"
    if not kit.is_dir():
        env = dict(os.environ, GHOSTTY_SHA=gitlink, GHOSTTYKIT_OUTPUT_DIR=str(kit))
        kit.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(worktree / "scripts" / "download-prebuilt-ghosttykit.sh")],
                       cwd=kit.parent, env=env, check=True, timeout=900)
    if not kit.is_dir():
        raise RuntimeError(f"GhosttyKit cache is missing for {gitlink}")
    link = worktree / "GhosttyKit.xcframework"
    if link.is_symlink():
        if link.resolve() == kit.resolve():
            return
        link.unlink()
    elif link.exists():
        raise RuntimeError(f"refusing to replace a non-symlink {link}")
    link.symlink_to(kit)


def dependency_cache(root: Path, worktree: Path) -> Path:
    digest = hashlib.sha256()
    for rel in ("GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                "Package.resolved"):
        p = worktree / rel
        digest.update(p.read_bytes() if p.exists() else b"")
    for sub in ("ghostty", "vendor/bonsplit"):
        digest.update(git(worktree, "rev-parse", f"HEAD:{sub}").encode())
    cache = root / "cache" / ("DerivedData-" + digest.hexdigest()[:12])
    cache.mkdir(parents=True, exist_ok=True)
    os.utime(cache)
    others = sorted((p for p in (root / "cache").glob("DerivedData-*") if p != cache),
                    key=lambda p: p.stat().st_mtime, reverse=True)
    for stale in others[KEEP_CACHES - 1:]:
        shutil.rmtree(stale, ignore_errors=True)
    return cache


def build_for_testing(root: Path, worktree: Path, run_dir: Path, live: dict) -> dict:
    derived = dependency_cache(root, worktree)
    slot_record = run_dir / "slot.json"
    build_log = run_dir / "build.log"
    argv = [
        "/usr/bin/python3", SLOT_RUNNER_OVERRIDE or str(worktree / "scripts" / "atlas_build_slots.py"),
        "c11-host-tests",
        str(XCODE_APP / "Contents/Developer/usr/bin/xcodebuild"),
        "-project", str(worktree / "GhosttyTabs.xcodeproj"),
        "-scheme", "c11-unit", "-configuration", "Debug", "-destination", "platform=macOS",
        "-derivedDataPath", str(derived),
        "-clonedSourcePackagesDirPath", str(root / "cache" / "SourcePackages"),
        "COMPILER_INDEX_STORE_ENABLE=NO", "build-for-testing",
    ]
    env = dict(os.environ)
    env.update(DEVELOPER_DIR=str(XCODE_APP / "Contents/Developer"),
               C11_ATLAS_SLOT_RECORD_PATH=str(slot_record),
               C11_BUILD_LOCK_TIMEOUT=str(SLOT_ADMISSION_S),
               PATH=":".join((str(Path.home() / "zig-0.15.2"), "/opt/homebrew/bin", "/usr/bin", "/bin")))
    env.pop("C11_BUILD_LOCK", None)
    started = time.monotonic()
    admitted = None
    with build_log.open("w") as out:
        proc = subprocess.Popen(argv, cwd=worktree, env=env, stdout=out, stderr=subprocess.STDOUT,
                                start_new_session=True)
        live["pid"] = proc.pid
        while proc.poll() is None:
            if admitted is None and slot_record.exists():
                admitted = time.monotonic()
            if admitted is not None and time.monotonic() - admitted > BUILD_TIMEOUT_S:
                kill_tree(proc.pid)
                proc.wait()
                live.pop("pid", None)
                return {"ok": False, "infra": True, "reason": f"build timed out after {BUILD_TIMEOUT_S}s",
                        "log": str(build_log)}
            time.sleep(0.5)
    live.pop("pid", None)
    finished = time.monotonic()
    result = {
        "ok": proc.returncode == 0,
        "infra": False,
        "exit": proc.returncode,
        "slot_wait_seconds": round((admitted or finished) - started, 1),
        "build_seconds": round(finished - (admitted or started), 1),
        "log": str(build_log),
        "products": str(derived / "Build" / "Products"),
    }
    text = build_log.read_text(errors="replace")
    if proc.returncode == 75 and "admission timed out" in text:
        result.update(infra=True, deferred=True, reason="slot admission timed out")
    elif proc.returncode != 0:
        # Red only for the code's own errors; a fetch, disk or cache fault is infrastructure.
        diagnostics = [l for l in text.splitlines() if re.search(
            r"\.(swift|m|h|c|mm):\d+:\d+: error:|Undefined symbols for architecture|^ld: (error|symbol)|"
            r"Multiple commands produce", l)]
        result.update(infra=not diagnostics, reason=f"build-for-testing exited {proc.returncode}",
                      diagnostics=diagnostics[:10])
    return result


def quarantine_skips(worktree: Path) -> list[str]:
    spec = importlib.util.spec_from_file_location("host_test_quarantine",
                                                  worktree / "scripts" / "host_test_quarantine.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rows = module.read_host_test_quarantine(worktree / "scripts" / "host-test-quarantine.tsv")
    # The guest is a clean machine: only `all` rows are skipped; `remote` rows describe the build host.
    return [r["test_id"] for r in rows if r["scope"] == "all" and r["test_id"].startswith("c11Tests/")]


# ---------------------------------------------------------------- the guest

class Guest:
    """One disposable clone, named c11-ht-<run>, deleted on every exit path."""

    def __init__(self, run_id: str, run_dir: Path, live: dict, root: Path | None = None) -> None:
        self.vm = VM_PREFIX + run_id.lower()
        self.run_id = run_id
        self.root = root or run_dir
        self.run_dir = run_dir
        self.live = live
        self.ip = ""
        self.tart_proc: subprocess.Popen | None = None
        self.child: subprocess.Popen | None = None
        self.yielded = False
        # Held while deciding to launch a VM producer and while a yield takes effect, so no producer
        # starts after a yield and every producer that started is known to the yield.
        self.produce_lock = threading.Lock()
        self.stopping = threading.Event()
        self.watcher: threading.Thread | None = None
        self.tart_log = None
        self.known = SANDBOX_ROOT / "known_hosts.host-tests"

    # -- lifecycle
    def boot(self, deadline: float) -> dict:
        t0 = time.monotonic()
        # Claimed and watched before the clone lock: an owner's sandbox-up can preempt us from here on.
        claim_vm(self.vm, self.root, self.run_id)
        self.live["vm"] = self.vm
        self.watcher = threading.Thread(target=self._watch_yield, daemon=True)
        self.watcher.start()
        lock = CloneLock()
        lock.acquire(budget(deadline, 120), lambda: self.yielded)
        try:
            self._check(deadline)
            reason = guest_gate(running_vms(), None, None, MIN_FREE_GIB)
            if reason:
                raise BlockingIOError(reason)
            self._tart(deadline, "clone", GOLDEN, self.vm)
            self._tart(deadline, "set", self.vm, "--cpu", "4", "--memory", "8192", "--display", "1440x900",
                       "--random-mac")
            self.tart_log = (self.run_dir / "tart.log").open("w")
            self._launch(
                [TART, "run", "--no-graphics", "--no-audio", "--no-clipboard", self.vm], role="tart_proc",
                stdin=subprocess.DEVNULL, stdout=self.tart_log, stderr=subprocess.STDOUT)
            started = time.monotonic()
            while tart_vms().get(self.vm, "stopped") == "stopped":
                self._check(deadline)
                if self.tart_proc.poll() is not None or time.monotonic() - started > 60:
                    raise RuntimeError("tart run did not start the clone")
                time.sleep(0.5)
        finally:
            lock.release()
        while not self.ip:
            self._check(deadline)
            try:
                ip = subprocess.run([TART, "ip", self.vm, "--wait", "3"], capture_output=True, text=True,
                                    timeout=budget(deadline, 15)).stdout
            except subprocess.TimeoutExpired:
                continue  # the next _check ends the phase once the deadline is spent
            self.ip = ip.strip().splitlines()[0] if ip.strip() else ""
        while True:
            self._check(deadline)
            probe = self.ssh("print -r -- ok", timeout=budget(deadline, 30), check=False)
            if probe.returncode == 0 and probe.stdout.strip() == "ok":
                break
            time.sleep(3)
        return {"boot_seconds": round(time.monotonic() - t0, 1)}

    def _launch(self, argv: list[str], role: str = "child", **kwargs) -> subprocess.Popen:
        """Start a process that can create or start the VM, unless a yield has been requested.

        The check and the launch happen under produce_lock, and the yield watcher takes the same lock
        to set `yielded`: a producer either starts before the yield (and the yield stops it) or never.
        The claim records the producer's PID for sandbox-up's takeover.
        """
        with self.produce_lock:
            if self.yielded or yield_path(self.vm).exists():
                self.yielded = True
                raise InterruptedError("yielded to sandbox-up")
            proc = subprocess.Popen(argv, start_new_session=True, **kwargs)
            setattr(self, role, proc)  # visible to the yield before the lock is released
            identity = self._producer_identity(proc, argv)
            claim_vm(self.vm, self.root, self.run_id,
                     producer={"pid": proc.pid, "identity": identity} if identity else None)
            return proc

    def _producer_identity(self, proc: subprocess.Popen, argv: list[str]) -> dict | None:
        """The producer's identity once it has exec'd tart: its command line names the tart verb
        (argv[1]) and this VM. Without one, sandbox-up gets no authority to signal it."""
        verb = f" {argv[1]} "
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and proc.poll() is None:
            identity = process_identity(proc.pid)
            if identity and verb in identity["command"] + " " and self.vm in identity["command"]:
                return identity
            time.sleep(0.01)
        return None

    def _stop_producers(self) -> None:
        """Terminate and reap every VM producer this guest started."""
        for proc in (self.child, self.tart_proc):
            if proc is None:
                continue
            if proc.poll() is None:
                kill_tree(proc.pid, grace=2)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass

    def _tart(self, deadline: float, *args: str) -> None:
        """A tart step the yield watcher can kill, bounded by the guest deadline."""
        self._launch([TART, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            out, _ = self.child.communicate(timeout=budget(deadline, 120))
        except subprocess.TimeoutExpired:
            kill_tree(self.child.pid)
            self.child.wait()
            raise TimeoutError(f"tart {args[0]} timed out")
        if self.yielded:
            raise InterruptedError("yielded to sandbox-up")
        if self.child.returncode != 0:
            raise RuntimeError(f"tart {args[0]} exited {self.child.returncode}: {(out or '').strip()[-300:]}")

    def teardown(self) -> None:
        self.stopping.set()
        if self.watcher is not None:
            self.watcher.join(60)  # let a yield's own cleanup finish before cleaning up again
        # Producers first, then the VM, then (inside delete_vm) the claim.
        self._stop_producers()
        try:
            delete_vm(self.vm)
            self.live.pop("vm", None)  # only once it is really gone; run() retries otherwise
        finally:
            if self.tart_log is not None:
                self.tart_log.close()
            yield_path(self.vm).unlink(missing_ok=True)

    def _watch_yield(self) -> None:
        while not self.stopping.wait(0.5):
            if yield_path(self.vm).exists():
                log(f"yield requested by sandbox-up; deleting {self.vm}")
                with self.produce_lock:
                    self.yielded = True  # from here no producer can start
                # Every producer that did start is stopped and reaped before the VM and claim go.
                self._stop_producers()
                try:
                    delete_vm(self.vm)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    log(f"yield delete failed: {error}; sandbox-up deletes it at its deadline")
                return

    def _check(self, deadline: float) -> None:
        if self.yielded:
            raise InterruptedError("yielded to sandbox-up")
        budget(deadline)

    # -- transport
    def ssh_argv(self, command: str) -> list[str]:
        return ["/usr/bin/ssh", "-i", str(SANDBOX_KEY), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={self.known}",
                "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=10",
                "-o", "LogLevel=ERROR", f"{GUEST_USER}@{self.ip}", command]

    def ssh(self, script: str, timeout: float, check: bool = True,
            stdout=subprocess.PIPE) -> subprocess.CompletedProcess:
        self.child = subprocess.Popen(self.ssh_argv("exec /bin/zsh -s"), stdin=subprocess.PIPE,
                                      stdout=stdout, stderr=subprocess.STDOUT, text=True,
                                      start_new_session=True)
        try:
            out, _ = self.child.communicate(script, timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_tree(self.child.pid)
            self.child.wait()
            raise TimeoutError("guest command timed out")
        result = subprocess.CompletedProcess(self.child.args, self.child.returncode, out or "", "")
        if self.yielded:
            raise InterruptedError("yielded to sandbox-up")
        if check and result.returncode != 0:
            raise RuntimeError(f"guest command exited {result.returncode}: {(out or '')[-400:]}")
        return result

    def push(self, parent: Path, names: list[str], dest: str, timeout: float,
             excludes: tuple[str, ...] = ()) -> None:
        tar_argv = ["/usr/bin/tar", "-C", str(parent), "-cf", "-"]
        for pattern in excludes:
            tar_argv += ["--exclude", pattern]
        tar_argv += names
        sender = subprocess.Popen(tar_argv, stdout=subprocess.PIPE, env=dict(os.environ, COPYFILE_DISABLE="1"),
                                  start_new_session=True)
        self.child = subprocess.Popen(
            self.ssh_argv(f"mkdir -p {shlex.quote(dest)} && /usr/bin/tar -xf - -C {shlex.quote(dest)}"),
            stdin=sender.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        sender.stdout.close()
        try:
            _, err = self.child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_tree(self.child.pid)
            kill_tree(sender.pid)
            raise TimeoutError(f"copying {names} timed out")
        sender.wait()
        if self.yielded:
            raise InterruptedError("yielded to sandbox-up")
        if self.child.returncode != 0 or sender.returncode != 0:
            raise RuntimeError(f"copy of {names} failed: {err.decode(errors='replace')[-400:]}")

    def pull(self, remote_parent: str, name: str, local_parent: Path, timeout: float) -> None:
        local_parent.mkdir(parents=True, exist_ok=True)
        self.child = subprocess.Popen(
            self.ssh_argv(f"/usr/bin/tar -C {shlex.quote(remote_parent)} -cf - {shlex.quote(name)}"),
            stdout=subprocess.PIPE, start_new_session=True)
        try:
            receiver = subprocess.run(["/usr/bin/tar", "-xf", "-", "-C", str(local_parent)],
                                      stdin=self.child.stdout, timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_tree(self.child.pid)
            raise TimeoutError(f"fetching {name} timed out")
        self.child.wait(timeout=30)
        if self.yielded:
            raise InterruptedError("yielded to sandbox-up")
        if receiver.returncode != 0 or self.child.returncode != 0:
            raise RuntimeError(f"fetching {name} from the guest failed")


GUEST_RUN = r'''
set -u
setopt pipefail
zmodload zsh/datetime
base="$HOME/c11-ht"
dev="$base/Xcode.app/Contents/Developer"
export DEVELOPER_DIR="$dev"
t0=$EPOCHSECONDS
/usr/bin/sudo -n /usr/bin/env DEVELOPER_DIR="$dev" "$dev/usr/bin/xcodebuild" -license accept || exit 41
/usr/bin/sudo -n /usr/bin/env DEVELOPER_DIR="$dev" "$dev/usr/bin/xcodebuild" -runFirstLaunch || exit 42
/usr/bin/sudo -n /usr/sbin/DevToolsSecurity -enable >/dev/null 2>&1 || true
print -r -- "C11HT first_launch_seconds=$((EPOCHSECONDS - t0))"
setopt null_glob
runs=("$base"/Products/*.xctestrun)
unsetopt null_glob
(( ${#runs} == 1 )) || { print -r -- "C11HT expected one xctestrun, found ${#runs}"; exit 43; }
/bin/rm -rf "$base/out"; mkdir -p "$base/out"
uid="$(id -u)"; user="$(id -un)"
t1=$EPOCHSECONDS
# The test host app needs the Aqua session: enter it as root, then drop back to the console user.
/usr/bin/sudo -n /bin/launchctl asuser "$uid" /usr/bin/sudo -n -u "$user" /usr/bin/env \
  HOME="$HOME" USER="$user" LOGNAME="$user" TMPDIR="${TMPDIR:-/tmp}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$dev" \
  TEST_RUNNER_C11_QA_LAUNCH=fresh \
  "$dev/usr/bin/xcodebuild" test-without-building \
    -xctestrun "$runs[1]" -destination platform=macOS \
    -resultBundlePath "$base/out/result.xcresult" \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 60 \
    -only-testing:c11Tests __SKIPS__
rc=$?
print -r -- "C11HT test_seconds=$((EPOCHSECONDS - t1)) exit=$rc"
exit 0
'''


def read_summary(bundle: Path) -> tuple[object, str | None]:
    xcrun = Path("/usr/bin/xcrun")
    env = dict(os.environ, DEVELOPER_DIR=str(XCODE_APP / "Contents/Developer"))
    last = None
    for attempt in range(2):
        try:
            out = subprocess.run([str(xcrun), "xcresulttool", "get", "test-results", "summary",
                                  "--path", str(bundle), "--compact"],
                                 capture_output=True, text=True, timeout=120, env=env)
            if out.returncode == 0:
                return json.loads(out.stdout), None
            last = f"xcresulttool exited {out.returncode}"
        except (subprocess.TimeoutExpired, ValueError, OSError) as error:
            last = str(error)
        if attempt == 0:
            time.sleep(5)
    return None, last


def run_guest(run_id: str, run_dir: Path, products: Path, worktree: Path, skips: list[str], live: dict,
              timing: dict, root: Path | None = None) -> dict:
    """Fills `timing` as it goes, so a failed step still leaves the earlier steps' seconds.

    Every phase starts only while the shared deadline has time left and gets at most what is left,
    so no copy or test invocation begins after the guest ceiling.
    """
    deadline = time.monotonic() + GUEST_TIMEOUT_S
    guest = Guest(run_id, run_dir, live, root)
    timing["vm"] = guest.vm

    def step(fn, *args, cap: float | None = None, **kwargs):
        guest._check(deadline)
        return fn(*args, timeout=budget(deadline, cap), **kwargs)

    try:
        timing.update(guest.boot(deadline))
        t = time.monotonic()
        step(guest.ssh, "/bin/rm -rf $HOME/c11-ht; mkdir -p $HOME/c11-ht", cap=60)
        step(guest.push, XCODE_APP.parent, [XCODE_APP.name], "c11-ht")
        step(guest.ssh, f"/bin/mv $HOME/c11-ht/{shlex.quote(XCODE_APP.name)} $HOME/c11-ht/Xcode.app", cap=60)
        names = sorted(p.name for p in products.iterdir() if p.name == "Debug" or p.suffix == ".xctestrun")
        step(guest.push, products, names, "c11-ht/Products", excludes=("*.dSYM",))
        # Tests find fixtures through compile-time source paths (#filePath): mirror the checkout,
        # without Git data or Zig caches, at the same absolute path in the guest.
        dest = shlex.quote(str(worktree))
        step(guest.ssh, f"/usr/bin/sudo -n /bin/mkdir -p {dest} && /usr/bin/sudo -n /usr/sbin/chown -R "
                        f"$(id -un) {shlex.quote(str(worktree.parent))}", cap=60)
        step(guest.push, worktree, sorted(p.name for p in worktree.iterdir() if p.name != ".git"), str(worktree),
             excludes=(".git", "ghostty/.zig-cache", "ghostty/zig-out", "build-*", ".build"))
        timing["copy_seconds"] = round(time.monotonic() - t, 1)
        skip_args = " ".join(shlex.quote("-skip-testing:" + s) for s in skips)
        log_path = run_dir / "test.log"
        with log_path.open("w") as out:
            step(guest.ssh, GUEST_RUN.replace("__SKIPS__", skip_args), stdout=out)
        text = log_path.read_text(errors="replace")
        for key in ("first_launch_seconds", "test_seconds"):
            m = re.search(rf"C11HT {key}=(\d+)", text)
            timing[key] = int(m.group(1)) if m else None
        m = re.search(r"C11HT test_seconds=\d+ exit=(\d+)", text)
        timing["xcodebuild_exit"] = int(m.group(1)) if m else None
        step(guest.pull, "c11-ht/out", "result.xcresult", run_dir)
        timing["result_bundle"] = str(run_dir / "result.xcresult")
    finally:
        t = time.monotonic()
        try:
            guest.teardown()
        except (OSError, RuntimeError, subprocess.SubprocessError):
            if not guest.yielded:
                raise
        finally:
            timing["yielded"] = guest.yielded
            timing["teardown_seconds"] = round(time.monotonic() - t, 1)
    return timing


# ---------------------------------------------------------------- the board

def board(root: Path, *args: str) -> dict:
    board_dir = root / "board"
    out = subprocess.run([os.environ.get("C11_HOST_TESTS_LATTICE", str(Path.home() / ".local/bin/lattice")),
                          *args, "--actor", BOARD_ACTOR, "--json"],
                         cwd=board_dir, capture_output=True, text=True, timeout=BOARD_TIMEOUT_S)
    if out.returncode != 0:
        raise RuntimeError(f"lattice {args[0]} exited {out.returncode}: {out.stderr.strip()[-300:]}")
    return json.loads(out.stdout or "{}")


def board_list(root: Path, tag: str) -> list[dict]:
    board_dir = root / "board"
    out = subprocess.run([os.environ.get("C11_HOST_TESTS_LATTICE", str(Path.home() / ".local/bin/lattice")),
                          "list", "--tag", tag, "--json"], cwd=board_dir, capture_output=True, text=True,
                         timeout=BOARD_TIMEOUT_S)
    if out.returncode != 0:
        raise RuntimeError(f"lattice list exited {out.returncode}: {out.stderr.strip()[-300:]}")
    return open_tickets(json.loads(out.stdout).get("data") or [])


def report_text(row: dict, newer: dict | None = None) -> str:
    lines = [f"{row['state']} at main {row['tip']} ({row['started']}): {row.get('reason', '')}."]
    if newer is not None:
        lines.append(f"Delivered late; a newer run at main {newer.get('tip')} was {newer.get('state')}.")
    counts = row.get("counts") or {}
    if counts:
        lines.append("Counts: " + ", ".join(f"{k} {v}" for k, v in counts.items()) + ".")
    seconds = [f"{k.replace('_seconds', '')} {row[k]} s" for k in ("build_seconds", "test_seconds")
               if row.get(k) is not None]
    if seconds:
        lines.append("Timing: " + ", ".join(seconds) + ".")
    failures = row.get("failures") or []
    for name in failures[:REPORT_FAILURES]:
        lines.append(f"- {name}")
    if len(failures) > REPORT_FAILURES:
        lines.append(f"- … and {len(failures) - REPORT_FAILURES} more (see evidence)")
    if row.get("state") == "error" and row.get("log_tail"):
        lines.append("Log tail:")
        lines.extend(f"    {line}" for line in row["log_tail"][-10:])
    lines.append(f"Evidence on the build host: {row.get('run_dir')}")
    return "\n".join(lines)


BOARD_FAULTS = (OSError, RuntimeError, ValueError, subprocess.SubprocessError)  # includes TimeoutExpired


def report(root: Path, row: dict, records: list[dict], dry_run: bool, newer: dict | None = None) -> dict:
    """Deliver one run's board action. Never raises: a fault is returned as unavailable/error."""
    try:
        red = board_list(root, RED_TAG) if not dry_run else []
        infra = board_list(root, INFRA_TAG) if not dry_run else []
    except BOARD_FAULTS as error:
        return {"op": "unavailable", "error": str(error)}
    action = report_action(row["state"], row["tip"], records, red, infra)
    if action is None:
        return {"op": "none"}
    body = report_text(row, newer)
    if action.get("green"):
        body = f"Green again at main {row['tip']} ({row['started']}). " + body
    action["body"] = body
    if dry_run:
        action["dry_run"] = True
        return action
    try:
        if action["op"] == "create":
            made = board(root, "create", action["title"], "--type", "bug", "--priority", "high",
                         "--tag", action["tag"], "--description", body)
            action["task"] = (made.get("data") or {}).get("short_id")
        else:
            board(root, "comment", action["task"], body)
    except BOARD_FAULTS as error:
        action["error"] = str(error)
    return action


def landed(board: object) -> bool:
    if board is None:
        return True  # an older row with nothing to report
    return type(board) is dict and board.get("op") not in ("pending", "unavailable") and not board.get("error")


def board_pending(records: list[dict]) -> list[dict]:
    """Every counted run whose board report has not landed, oldest first. A newer result, delivered
    or not, never hides an older undelivered one."""
    delivered = {r["board_for"] for r in records if r.get("board_for") and landed(r.get("board"))}
    delivered |= {r["board_retry_of"] for r in records if r.get("board_retry_of") and landed(r.get("board"))}
    return [r for r in counted(records)
            if "state" in r and "board" in r and r.get("run_id") not in delivered and not landed(r.get("board"))]


def deliver(root: Path, row: dict, records: list[dict], records_path: Path, dry_run: bool,
            newer: dict | None = None) -> dict:
    result = report(root, row, records, dry_run, newer)
    append_jsonl(records_path, {"board_for": row["run_id"], "time": now_iso(), "board": result,
                                "dry_run": dry_run})
    return result


# ---------------------------------------------------------------- run / health / stop

class Abort(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(f"signal {signum}")
        self.signum = signum


def sweep_orphans(events: Path) -> None:
    """Under the host-wide run lock, a claim whose process is gone is an orphan: delete that VM.
    Only recorded claims are touched, never a VM by its name alone."""
    for claim in read_claims():
        if lane_alive(claim):
            continue
        try:
            delete_vm(claim["vm"])
            append_jsonl(events, {"time": now_iso(), "event": "orphan-deleted", "vm": claim["vm"],
                                  "root": claim.get("root")})
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            append_jsonl(events, {"time": now_iso(), "event": "orphan-delete-failed", "vm": claim["vm"],
                                  "error": str(error)})


def run(root: Path, ref: str, force: bool, dry_run: bool) -> int:
    root = root.expanduser().resolve()
    state = root / "state"
    state.mkdir(parents=True, exist_ok=True)
    # One lane run per Tart host, whatever --root: the orphan sweep deletes every c11-ht-* VM.
    SANDBOX_ROOT.mkdir(parents=True, exist_ok=True)
    lock = (SANDBOX_ROOT / "host-tests.run.lock").open("a+")  # noqa: SIM115 (held for the process)
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("skipped: another run holds the lock")
        return 0
    live: dict = {}

    def on_signal(signum, _frame):
        raise Abort(signum)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGALRM, on_signal)
    signal.alarm(RUN_TIMEOUT_S)
    records_path = root / "records" / "runs.jsonl"
    events = state / "events.jsonl"
    run_id = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:6]
    row: dict = {"run_id": run_id, "started": now_iso(), "dry_run": dry_run}
    run_json = state / "run.json"
    records: list[dict] = []
    try:
        sweep_orphans(events)
        worktree, tip = prepare_worktree(root, ref)
        row["tip"] = tip
        records = read_jsonl(records_path)
        if not dry_run:
            for pending in board_pending(records):
                upto = records[:records.index(pending) + 1]
                later = [r for r in counted(records[len(upto):]) if r.get("state") in TERMINAL]
                deliver(root, pending, upto, records_path, False, later[-1] if later else None)
            records = read_jsonl(records_path)
        last = last_terminal(records)
        changed = changed_paths(worktree, last["tip"], tip) if last else None
        decision = tip_decision(records, tip, changed, force)
        if decision == "docs-only":
            row.update(state="skipped-docs", reason=f"only docs changed since {last['tip'][:10]}")
            append_jsonl(records_path, row)
            log(row["reason"])
            return 0
        if decision != "run":
            append_jsonl(events, {"time": now_iso(), "event": decision, "tip": tip})
            log(f"skipped: {decision} at {tip[:10]}")
            return 0
        reason = guest_gate([], None, load_average(), free_gib(root))
        if reason:
            append_jsonl(events, {"time": now_iso(), "event": "deferred", "tip": tip, "reason": reason})
            log(f"deferred: {reason}")
            return 0
        run_dir = root / "results" / run_id
        run_dir.mkdir(parents=True)
        row["run_dir"] = str(run_dir)
        run_json.write_text(json.dumps({"pid": os.getpid(), "identity": process_identity(os.getpid()),
                                        "run_id": run_id, "tip": tip, "root": str(root),
                                        "vm": VM_PREFIX + run_id.lower()}))
        prune(root)
        link_ghosttykit(worktree)
        skips = quarantine_skips(worktree)
        row["skipped_selectors"] = skips
        row["load1"] = load_average()
        build = build_for_testing(root, worktree, run_dir, live)
        row.update({k: build.get(k) for k in ("slot_wait_seconds", "build_seconds")})
        if build.get("deferred"):
            append_jsonl(events, {"time": now_iso(), "event": "deferred", "tip": tip, "reason": build["reason"]})
            log(f"deferred: {build['reason']}")
            return 0
        if not build["ok"]:
            row.update(state="error" if build["infra"] else "failure", reason=build["reason"],
                       failures=build.get("diagnostics") or [], counts={})
            if build["infra"] and build.get("log"):
                row["log_tail"] = Path(build["log"]).read_text(errors="replace").splitlines()[-10:]
            return finish(root, row, records, records_path, dry_run)
        # Wait for a free guest; owners always come first.
        waited = time.monotonic()
        while True:
            reason = guest_gate(running_vms(), sandbox_activity_age(), load_average(), free_gib(root))
            if reason is None:
                break
            if time.monotonic() - waited > GUEST_WAIT_S:
                append_jsonl(events, {"time": now_iso(), "event": "deferred", "tip": tip, "reason": reason,
                                      "after": "build"})
                log(f"deferred after build: {reason}")
                return 0
            time.sleep(30)
        row["guest_wait_seconds"] = round(time.monotonic() - waited, 1)
        timing: dict = {}
        try:
            run_guest(run_id, run_dir, Path(build["products"]), worktree, skips, live, timing, root)
        except BlockingIOError as busy:
            append_jsonl(events, {"time": now_iso(), "event": "deferred", "tip": tip, "reason": str(busy)})
            return 0
        except InterruptedError:
            row.update(timing)
            row.update(state="yielded", reason="an owner's sandbox-up preempted the lane guest")
            append_jsonl(records_path, row)
            log(row["reason"])
            return 0
        except (TimeoutError, RuntimeError, OSError, subprocess.SubprocessError) as error:
            row.update(timing)
            if timing.get("yielded"):
                row.update(state="yielded", reason="an owner's sandbox-up preempted the lane guest")
                append_jsonl(records_path, row)
                return 0
            row.update(state="error", reason=f"guest: {error}", failures=[], counts={})
            test_log = run_dir / "test.log"
            if test_log.exists():
                row["log_tail"] = test_log.read_text(errors="replace").splitlines()[-10:]
            return finish(root, row, records, records_path, dry_run)
        row.update(timing)
        if timing.get("yielded"):
            row.update(state="yielded", reason="an owner's sandbox-up preempted the lane guest")
            append_jsonl(records_path, row)
            return 0
        bundle = run_dir / "result.xcresult"
        summary, error = read_summary(bundle) if bundle.exists() else (None, "no result bundle")
        st, why, failures, counts = summarize(summary)
        if error:
            st, why = "error", f"result unreadable: {error}"
        elif st == "success" and timing.get("xcodebuild_exit") not in (0, None):
            st, why = "error", f"xcresult passed but xcodebuild exited {timing['xcodebuild_exit']}"
        row.update(state=st, reason=why, failures=failures, counts=counts)
        if st == "success":
            shutil.rmtree(bundle, ignore_errors=True)
            row.pop("result_bundle", None)
        return finish(root, row, records, records_path, dry_run)
    except Abort as stop:
        return record_abort(root, row, records, records_path, dry_run, stop)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        if "finished" in row:  # the outcome is already recorded; never overwrite it
            log(f"after recording: {error}")
            return 0 if row.get("state") == "success" else 1
        if "tip" not in row:
            append_jsonl(events, {"time": now_iso(), "event": "prepare-failed", "error": str(error)})
            log(f"prepare failed: {error}")
            return 1
        row.update(state="error", reason=f"setup: {error}", failures=[], counts={})
        return finish(root, row, records, records_path, dry_run)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        if live.get("pid"):
            kill_tree(live["pid"])
        if live.get("vm"):
            try:
                delete_vm(live["vm"])
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass  # the next run's sweep deletes it
        run_json.unlink(missing_ok=True)


def record_abort(root: Path, row: dict, records: list[dict], records_path: Path, dry_run: bool,
                 stop: Abort) -> int:
    """What a SIGTERM or the run timeout records. An outcome already recorded is never rewritten:
    a signal during board delivery leaves that report pending, to be retried."""
    if "finished" in row:
        log(f"stopped after recording: {stop}")
        return 0 if row.get("state") == "success" else 1
    if stop.signum == signal.SIGALRM:
        row.update(state="error", reason=f"run passed {RUN_TIMEOUT_S}s", failures=[], counts={})
        if "tip" in row:
            return finish(root, row, records, records_path, dry_run)
    else:
        # An operator's stop or a launchd bootout: not the lane's or the code's fault.
        row.update(state="stopped", reason=f"stopped by {stop}")
    append_jsonl(records_path, row)
    return 1


def finish(root: Path, row: dict, records: list[dict], records_path: Path, dry_run: bool) -> int:
    """Record the outcome first, then deliver it: a board fault can delay a report, never change or lose it."""
    row["finished"] = now_iso()
    row["board"] = {"op": "pending"}
    append_jsonl(records_path, row)
    row["board"] = deliver(root, row, records + [row], records_path, dry_run)
    print(json.dumps(row, sort_keys=True, indent=1), flush=True)
    return 0 if row["state"] == "success" else 1


def prune(root: Path) -> None:
    cutoff = time.time() - RETENTION_S
    for path in (root / "results").glob("*"):
        try:
            if path.stat().st_mtime < cutoff:
                shutil.rmtree(path, ignore_errors=True)
        except FileNotFoundError:
            continue


def health(root: Path) -> int:
    root = root.expanduser().resolve()
    label = "com.stage11.c11-host-tests"
    svc = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True, text=True)
    state_line = next((l.strip() for l in svc.stdout.splitlines() if l.strip().startswith("state =")), "not loaded")
    print(f"service {label}: {state_line}")
    script = root / "bin" / "c11-host-tests.py"
    if script.exists():
        print(f"installed sha256 {hashlib.sha256(script.read_bytes()).hexdigest()}")
        worktree = root / "worktree"
        if worktree.exists():
            try:
                main_bytes = subprocess.run(["/usr/bin/git", "-C", str(worktree), "show",
                                             "refs/remotes/origin/main:scripts/c11-host-tests.py"],
                                            capture_output=True, check=True).stdout
                print(f"main's     sha256 {hashlib.sha256(main_bytes).hexdigest()}")
            except subprocess.CalledProcessError:
                print("main has no scripts/c11-host-tests.py")
    run_json = root / "state" / "run.json"
    print("active run: " + (run_json.read_text().strip() if run_json.exists() else "none"))
    try:
        vms = tart_vms()
        lanes = [f"{c['vm']} {vms.get(c['vm'], 'absent')} root={c.get('root')} pid={c.get('pid')}"
                 for c in read_claims()]
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        lanes = [f"tart list failed: {error}"]
    print("lane guests: " + (", ".join(lanes) or "none"))
    events = read_jsonl(root / "state" / "events.jsonl")
    print("last event: " + (json.dumps(events[-1], sort_keys=True) if events else "none"))
    rows = [r for r in read_jsonl(root / "records" / "runs.jsonl") if "state" in r]
    if rows:
        last = rows[-1]
        print("last run: " + json.dumps({k: last.get(k) for k in
                                         ("started", "tip", "state", "reason", "board")}, sort_keys=True))
    else:
        print("last run: none")
    return 0


def stop(root: Path) -> int:
    """Stop this root's run and delete only guests recorded under this root whose run is gone."""
    root = root.expanduser().resolve()
    run_json = root / "state" / "run.json"
    if run_json.exists():
        info = json.loads(run_json.read_text())
        pid = info.get("pid")
        # Only the recorded run process itself (same start time and command line) is signalled.
        if info.get("root") == str(root) and identity_matches(pid, info.get("identity")):
            os.kill(pid, signal.SIGTERM)  # the run's own handler deletes its guest and build tree
            for _ in range(60):
                time.sleep(1)
                if not identity_matches(pid, info.get("identity")):
                    break
            print(f"stopped run pid {pid}")
    for claim in read_claims():
        if claim.get("root") != str(root) or lane_alive(claim):
            continue
        delete_vm(claim["vm"])
        print(f"deleted lane guest {claim['vm']}")
    return 0


def main(argv: list[str]) -> int:
    usage = ("usage: c11-host-tests.py run --root <dir> [--ref main] [--force] [--dry-run]\n"
             "       c11-host-tests.py health --root <dir>\n"
             "       c11-host-tests.py stop --root <dir>")
    if len(argv) < 2 or argv[1] not in ("run", "health", "stop"):
        print(usage, file=sys.stderr)
        return 2
    root, ref, force, dry = None, "main", False, False
    args = iter(argv[2:])
    for arg in args:
        if arg == "--root":
            root = Path(next(args, ""))
        elif arg == "--ref":
            ref = next(args, "main")
        elif arg == "--force":
            force = True
        elif arg == "--dry-run":
            dry = True
        else:
            print(f"unknown argument: {arg}\n{usage}", file=sys.stderr)
            return 2
    if root is None or not str(root):
        print("--root is required", file=sys.stderr)
        return 2
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", ref):
        print("--ref must be a branch name", file=sys.stderr)
        return 2
    if argv[1] == "health":
        return health(root)
    if argv[1] == "stop":
        return stop(root)
    try:
        return run(root, ref, force, dry)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"host-tests lane error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
