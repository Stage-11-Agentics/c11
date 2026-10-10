#!/usr/bin/env python3
"""Advisory Atlas poller for same-repo c11 pull requests.

Phase 2 of C11-371. This process is not a GitHub Actions runner. Nothing in
this file bootstraps a LaunchAgent. `supervise` is one long-running process
that runs only when state/enabled.json sets enabled to true. It holds the
queue, the rate-limit deadline and the credential client in memory; a restart
rebuilds them from the GitHub API plus R2 recovery. The LaunchAgent template
does not create enabled.json. Arming waits for Atin's GO-LIVE.

Credentials: gh mode (the Atlas gh login, credential.json {"mode": "gh"}) is
active; App mode (app.json plus private-key.pem) is the config-only upgrade.

Status delivery (orchestrator ruling): no outbox. A status POST gets three
tries that honour Retry-After; if all fail the poller logs status_undelivered
and the next cycle builds that head again and posts a fresh result. The budget
is classified once, from slot acquisition to build end. Posting time is
excluded and logged separately as post_seconds.

R2 amendment (orchestrator, comment on C11-371): a free running.lock is not
proof that the build is gone. Recovery, and the check before every start,
also probe the recorded process group with killpg(pgid, 0) and do not clear
running.json or admit a build until that group is ESRCH.
"""

from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


REPO_ID = 1212901838
REPO_NAME = "Stage-11-Agentics/c11"
PARENT_URL = "https://github.com/Stage-11-Agentics/c11.git"
GHOSTTY_URL = "https://github.com/Stage-11-Agentics/ghostty.git"
BONSPLIT_URL = "https://github.com/Stage-11-Agentics/bonsplit.git"
PINNED_URLS = frozenset((PARENT_URL, GHOSTTY_URL, BONSPLIT_URL))
GITLINKS = (("ghostty", GHOSTTY_URL), ("vendor/bonsplit", BONSPLIT_URL))
STATUS_CONTEXT = "c11/pr-swift"
SLUG = "fu-371r"
LABEL = "com.stage11.c11-pr-swift-poller"
XCODEBUILD = "/Applications/Xcode-26.3.app/Contents/Developer/usr/bin/xcodebuild"
DEVELOPER_DIR = "/Applications/Xcode-26.3.app/Contents/Developer"
LIST_URL = (
    "https://api.github.com/repos/Stage-11-Agentics/c11/pulls"
    "?state=open&per_page=100&sort=updated&direction=desc"
)
API = "https://api.github.com"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
USER_AGENT = "c11-pr-swift-poller"
CADENCE_S = 25
YIELD_INTERVAL_S = 5
TERM_GRACE_S = 10
KILL_BUDGET_S = 60
BUDGET_S = 120
HTTP_TIMEOUT_S = 20
MAX_PAGES = 10
DECISION_LIMIT = 200
POST_TRIES = 3
DISARMED_SLEEP_S = 3600
TERMINAL_STATES = frozenset(("success", "failure"))
KNOWN_STAGES = frozenset(("plist_installed", "app_installed", "key_placed", "gh_configured"))
GH_FALLBACK = "/opt/homebrew/bin/gh"
CREDENTIAL_UNAVAILABLE = "credential-unavailable"
GH_ENV_DROP = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST")
BUILD_ENV_DROP = (
    "C11_BUILD_LOCK",
    "C11_SOCKET",
    "C11_SOCKET_PATH",
    "C11_SURFACE_ID",
    "CMUX_SURFACE_ID",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "Authorization",
)

_MISSING = object()
_LOCK_FDS = []


class OriginRefused(Exception):
    pass


class ScopeStop(Exception):
    pass


class CredentialUnavailable(Exception):
    """The credential could not be read this time. Skip and retry; never a scope pass."""


def admit(obj):
    """Pure admission. Returns (ok, reason, captured). Never reads the PR tree."""
    if type(obj) is not dict:
        return False, "malformed", None
    if "number" not in obj or "state" not in obj or "head" not in obj or "base" not in obj:
        return False, "malformed", None
    number = obj["number"]
    if type(number) is not int or number < 1:
        return False, "malformed", None
    state = obj["state"]
    if type(state) is not str:
        return False, "malformed", None
    if state != "open":
        return False, "not_open", None
    head = obj["head"]
    base = obj["base"]
    if type(head) is not dict or type(base) is not dict:
        return False, "malformed", None
    for side in (head, base):
        if "repo" not in side:
            return False, "malformed", None
        repo = side["repo"]
        if repo is None:
            return False, "missing_repo", None
        if type(repo) is not dict:
            return False, "malformed", None
        if "id" not in repo or "full_name" not in repo:
            return False, "malformed", None
        if type(repo["id"]) is not int:
            return False, "repo_id", None
        if repo["id"] != REPO_ID:
            return False, "repo_id", None
        if repo["full_name"] != REPO_NAME:
            return False, "repo_name", None
    sha = head.get("sha", _MISSING)
    ref = head.get("ref", _MISSING)
    if type(sha) is not str or SHA_RE.fullmatch(sha) is None:
        return False, "malformed_sha", None
    if type(ref) is not str or ref == "" or ref.startswith("refs/"):
        return False, "malformed_ref", None
    if not branch_name_ok(ref):
        return False, "malformed_ref", None
    return True, "admitted", {"pr": number, "sha": sha, "ref": ref}


def branch_name_ok(ref):
    try:
        result = subprocess.run(
            ["git", "check-ref-format", "--branch", ref],
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    return result.returncode == 0


def link_next(header):
    if not header:
        return None
    for part in header.split(","):
        if 'rel="next"' in part:
            url = part.split(";", 1)[0].strip()
            if url.startswith("<") and url.endswith(">"):
                return url[1:-1]
    return None


def header_get(headers, name):
    """Case-insensitive lookup. Probes and urllib both hand us plain dicts."""
    if not headers or type(name) is not str:
        return None
    wanted = name.lower()
    for key, value in headers.items():
        if type(key) is str and key.lower() == wanted:
            return value
    return None


def parse_retry_after(value, now):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return max(0.0, float(text))
    except ValueError:
        return None


def reset_wait(headers, now):
    raw = header_get(headers, "X-RateLimit-Reset")
    if raw is None:
        return None
    try:
        return max(0.0, float(raw) - now)
    except (TypeError, ValueError):
        return None


def rate_wait(status, headers, now, needed):
    """Seconds to wait before the next request. None means no invented cap.

    Retry-After and the reset time are honored in full. There is no ceiling.
    A Remaining below what this cycle needs waits until reset instead of polling.
    Header names are matched without regard to case.
    """
    headers = headers or {}
    retry = parse_retry_after(header_get(headers, "Retry-After"), now)
    reset = reset_wait(headers, now)
    if status in (403, 429):
        waits = [item for item in (retry, reset) if item is not None]
        if not waits:
            return None
        return max(waits)
    if status == 0:
        return None
    remaining = header_get(headers, "X-RateLimit-Remaining")
    if remaining is not None:
        try:
            left = int(remaining)
        except (TypeError, ValueError):
            return None
        if left < needed:
            return reset
    return 0


def load_list_store(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if type(data) is not dict:
        return None
    etag = data.get("etag")
    body = data.get("body")
    if type(etag) is not str or etag == "" or type(body) is not list:
        return None
    return data


def save_list_store(path, etag, body):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps({"etag": etag, "body": body}) + "\n")


def clear_list_store(path):
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass


def git_base_env():
    env = {}
    for key in ("PATH", "HOME", "TMPDIR"):
        if key in os.environ:
            env[key] = os.environ[key]
    env.update({
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_COUNT": "0",
        "GIT_TERMINAL_PROMPT": "0",
    })
    return env


def assert_git_args(args):
    for arg in args:
        if type(arg) is not str:
            continue
        if arg.startswith("refs/pull/") or "/pull/" in arg and "merge" in arg:
            raise OriginRefused(arg)
        if "://" in arg or arg.startswith("git@"):
            if arg not in PINNED_URLS:
                raise OriginRefused(arg)


def run_git(args, cwd):
    """C11_POLLER_GIT replaces git for fixtures; the argv guard runs either way."""
    assert_git_args(args)
    override = os.environ.get("C11_POLLER_GIT")
    if override:
        env = git_base_env()
        spec = os.environ.get("C11_POLLER_GIT_SPEC")
        if spec:
            env["C11_POLLER_GIT_SPEC"] = spec
        return subprocess.run([override, *args], cwd=str(cwd), env=env, capture_output=True, text=True)
    cmd = ["git", "-c", "protocol.file.allow=never", "-c", "core.hooksPath=/dev/null", *args]
    return subprocess.run(cmd, cwd=cwd, env=git_base_env(), capture_output=True, text=True)


def ls_remote_matches(stdout, sha, ref):
    expected = "%s\trefs/heads/%s" % (sha, ref)
    lines = [line for line in stdout.splitlines() if line]
    return lines == [expected]


def revalidate(captured, fetch_pr, ls_remote):
    """Fresh PR GET plus the admission function plus the pinned tip check.

    A mismatch never rewrites captured. The caller keeps the original SHA.
    """
    try:
        body = fetch_pr(captured["pr"])
    except CredentialUnavailable:
        return False, CREDENTIAL_UNAVAILABLE, None
    except Exception as error:
        return False, "revoked", str(error)
    if body is None:
        return False, "revoked", "missing"
    ok, reason, fresh = admit(body)
    if not ok:
        if reason in ("not_open", "missing_repo", "repo_id", "repo_name"):
            return False, "revoked", reason
        return False, "revoked", reason
    if fresh["sha"] != captured["sha"]:
        return False, "superseded", "sha"
    if fresh["ref"] != captured["ref"]:
        return False, "revoked", "ref"
    try:
        stdout = ls_remote(captured["ref"])
    except OriginRefused:
        return False, "revoked", "origin_refused"
    except Exception:
        return False, "revoked", "ls_remote"
    if not ls_remote_matches(stdout, captured["sha"], captured["ref"]):
        return False, "superseded", "sha_not_branch_tip"
    return True, "revalidated", None


def fetch_captured(git, worktree, captured):
    """Fetch only the captured SHA from pinned URLs. Never a pull ref or a new tip."""
    sha = captured["sha"]
    parent = git(["fetch", "--no-tags", "--no-recurse-submodules", PARENT_URL, sha], worktree)
    if parent.returncode != 0:
        return False, "fetch_failed"
    checkout = git(["checkout", "--detach", sha], worktree)
    if checkout.returncode != 0:
        return False, "fetch_failed"
    for path, url in GITLINKS:
        shown = git(["rev-parse", "%s:%s" % (sha, path)], worktree)
        if shown.returncode != 0:
            return False, "fetch_failed"
        gitlink = shown.stdout.strip()
        if SHA_RE.fullmatch(gitlink) is None:
            return False, "fetch_failed"
        sub = Path(worktree) / path
        fetched = git(["fetch", "--no-tags", "--no-recurse-submodules", url, gitlink], sub)
        if fetched.returncode != 0:
            return False, "fetch_failed"
        reset = git(["reset", "--hard", gitlink], sub)
        if reset.returncode != 0:
            return False, "fetch_failed"
    head = git(["rev-parse", "HEAD"], worktree)
    if head.returncode != 0 or head.stdout.strip() != sha:
        return False, "fetch_failed"
    for path, _url in GITLINKS:
        shown = git(["rev-parse", "%s:%s" % (sha, path)], worktree)
        sub_head = git(["rev-parse", "HEAD"], Path(worktree) / path)
        if shown.returncode != 0 or sub_head.returncode != 0:
            return False, "fetch_failed"
        if sub_head.stdout.strip() != shown.stdout.strip():
            return False, "fetch_failed"
    return True, "fetched"


def clean_worktree(git, worktree):
    """R3. A residue failure is the caller's signal to skip the attempt."""
    commands = (
        ["clean", "-ffdx"],
        ["submodule", "foreach", "--recursive", "git clean -ffdx"],
        ["reset", "--hard"],
    )
    for args in commands:
        result = git(args, worktree)
        if result.returncode != 0:
            return False
    return True


def porcelain_paths(stdout):
    paths = []
    for line in stdout.splitlines():
        if len(line) < 4:
            continue
        paths.append(line[3:])
    return paths


def residue_ok(parent_status, submodule_statuses, symlink_ready):
    allowed = set()
    if symlink_ready:
        allowed.add("GhosttyKit.xcframework")
    for path in parent_status:
        if path not in allowed:
            return False
    for status in submodule_statuses:
        if status:
            return False
    return True


def result_directory(state, attempt_id, invocation):
    path = Path(state) / "results" / ("%s-%s" % (attempt_id, invocation))
    if path.exists():
        raise FileExistsError(str(path))
    return path


def xcodebuild_argv(worktree, derived, result_path):
    return [
        os.environ.get("C11_POLLER_XCODEBUILD") or XCODEBUILD,
        "-project", str(Path(worktree) / "GhosttyTabs.xcodeproj"),
        "-scheme", "c11-logic",
        "-configuration", "Debug",
        "-destination", "platform=macOS",
        "-derivedDataPath", str(derived),
        "-resultBundlePath", str(result_path),
        "test",
        "-only-testing:c11LogicTests/HealthFlagsTests",
        "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "60",
        "-maximum-test-execution-time-allowance", "60",
    ]


def build_env():
    env = {}
    for key in ("PATH", "HOME", "TMPDIR"):
        if key in os.environ:
            env[key] = os.environ[key]
    zig = str(Path.home() / "zig-0.15.2")
    env["PATH"] = zig + ":/opt/homebrew/bin:" + env.get("PATH", "")
    env["DEVELOPER_DIR"] = DEVELOPER_DIR
    for key in BUILD_ENV_DROP:
        env.pop(key, None)
    return env


def classify_result(log_text, build_seconds):
    seconds = int(build_seconds)
    matched = re.search(r"Executed ([1-9][0-9]*) tests?", log_text or "")
    passed = (
        "HealthFlagsTests" in (log_text or "")
        and "** TEST SUCCEEDED **" in (log_text or "")
        and matched is not None
    )
    if not passed:
        return "failure", "failed %ss" % seconds
    if build_seconds > BUDGET_S:
        return "failure", "budget %ss" % seconds
    return "success", "%ss" % seconds


def link_ghosttykit(cache_root, sha, worktree):
    root = Path(cache_root).resolve()
    src = Path(cache_root) / sha / "GhosttyKit.xcframework"
    if not src.is_dir():
        return "ghosttykit_missing"
    try:
        real = src.resolve()
    except OSError:
        return "ghosttykit_missing"
    if real != root and root not in real.parents:
        return "ghosttykit_missing"
    dest = Path(worktree) / "GhosttyKit.xcframework"
    if dest.is_symlink() or dest.exists():
        dest.unlink()
    dest.symlink_to(src)
    return "ok"


def running_path(root):
    return Path(root) / "state" / "running.json"


def read_running(root):
    path = running_path(root)
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if type(data) is not dict:
        return None
    pgid = data.get("pgid")
    if type(pgid) is not int or pgid <= 1:
        return None
    return data


def group_alive(pgid):
    """True when the recorded group still has a live member.

    killpg(pgid, 0) is the probe. On macOS it can return ESRCH for an
    orphaned group that ps still lists, so a live process-table hit keeps
    the group alive. The same call returns EPERM when the only member is an
    unreaped zombie; a zombie is not a running build. A free lock is never
    enough on its own.
    """
    if type(pgid) is not int or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except (ProcessLookupError, PermissionError):
        return _pgid_live(pgid)
    return True


def _pgid_live(pgid):
    """True when ps shows a non-zombie member of this process group."""
    listed = subprocess.run(["ps", "-axo", "pgid=,state="], capture_output=True, text=True)
    if listed.returncode != 0:
        return False
    wanted = str(pgid)
    for line in listed.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] != wanted:
            continue
        if not parts[1].startswith("Z"):
            return True
    return False


def _signal_group(pgid, sig):
    """Signal a recorded group. A zombie or a gone group is not an error."""
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def lock_is_free(path):
    """Non-blocking probe. A successful acquire is released before return."""
    flags = os.O_RDWR | os.O_CREAT
    fd = os.open(path, flags, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    finally:
        os.close(fd)


def kill_until_esrch(pgid, alive, kill, sleep, monotonic, term_grace, budget):
    """TERM, then KILL after term_grace, until ESRCH or budget. Returns True on ESRCH."""
    started = monotonic()
    deadline = started + budget
    kill(pgid, signal.SIGTERM)
    killed = False
    while True:
        if not alive(pgid):
            return True
        now = monotonic()
        if now >= deadline:
            return not alive(pgid)
        if not killed and now >= started + term_grace:
            kill(pgid, signal.SIGKILL)
            killed = True
        sleep(min(0.2, deadline - now))


def clear_running(root):
    try:
        running_path(root).unlink()
    except FileNotFoundError:
        pass


def append_event(root, event):
    path = Path(root) / "state" / "events.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(event) + "\n")


def recover(root, alive=None, kill=None, sleep=None, monotonic=None, term_grace=TERM_GRACE_S, budget=KILL_BUDGET_S):
    """R2 plus the amendment. Returns 'ready' or 'stuck'.

    A free lock does not clear running.json while the recorded group exists.
    running.json is removed only after killpg confirms ESRCH.
    """
    alive = alive or group_alive
    kill = kill or _signal_group
    sleep = sleep or time.sleep
    monotonic = monotonic or time.monotonic
    state = Path(root) / "state"
    state.mkdir(parents=True, exist_ok=True)
    lock_path = state / "running.lock"
    recorded = read_running(root)
    pgid = None if recorded is None else recorded.get("pgid")
    if pgid is not None and alive(pgid):
        append_event(root, {"event": "probe-alive", "pgid": pgid})
        gone = kill_until_esrch(pgid, alive, kill, sleep, monotonic, term_grace, budget)
        if not gone or alive(pgid):
            append_event(root, {"event": "stuck", "reason": "group"})
            return "stuck"
        if not lock_is_free(lock_path):
            # The group is gone. Wait out a lock that has not dropped yet.
            deadline = monotonic() + budget
            while not lock_is_free(lock_path):
                if monotonic() >= deadline:
                    append_event(root, {"event": "stuck", "reason": "lock"})
                    return "stuck"
                sleep(min(0.2, max(0.0, deadline - monotonic())))
        clear_running(root)
        append_event(root, {"event": "cleared", "pgid": pgid})
        return "ready"
    if not lock_is_free(lock_path):
        append_event(root, {"event": "stuck", "reason": "lock-no-group"})
        return "stuck"
    clear_running(root)
    append_event(root, {"event": "cleared-stale"})
    return "ready"


def slot_held(slots_dir, number):
    path = Path(slots_dir) / ("slot-%s.lock" % number)
    if not path.exists():
        return False
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def running_guests(tart_list):
    """Names of c11-sb-* VMs whose tart list state is not stopped."""
    names = []
    for line in (tart_list or "").splitlines():
        if not line or line.startswith("Source"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[1]
        if name.startswith("c11-sb-") and parts[-1] != "stopped":
            names.append(name)
    return names


def yield_reason(guests, our_slot, other_held):
    if guests:
        return "guest"
    if other_held:
        return "slot"
    return None


def open_inheritable_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def write_running(root, payload):
    path = running_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload) + "\n")
    os.replace(temporary, path)


def child_main(root, exec_argv, revalidate_fn, post_pending):
    """setsid, inheritable lock, flock, running.json, revalidate, then exec.

    The recorded group is this process. No supervisor PID, birth, or argv marker.
    """
    os.setsid()
    state = Path(root) / "state"
    state.mkdir(parents=True, exist_ok=True)
    fd = open_inheritable_lock(state / "running.lock")
    _LOCK_FDS.append(fd)
    current = json.loads((state / "current.json").read_text())
    pgid = os.getpgrp()
    slot = os.environ.get("C11_ATLAS_BUILD_SLOT")
    write_running(root, {
        "pgid": pgid,
        "attempt_id": current["attempt_id"],
        "invocation": current["invocation"],
        "pr": current["pr"],
        "sha": current["sha"],
        "ref": current["ref"],
        "slot": int(slot) if slot and slot.isdigit() else None,
        "acquired_at": time.time(),
    })
    # The lock fd stays open across exec. Do not close it.
    ok, reason, _detail = revalidate_fn(root)
    if not ok:
        append_event(root, {"event": "child-revalidate-failed", "reason": reason})
        return 3
    if post_pending is not None and post_pending(current) is False:
        return 4
    argv = list(exec_argv)
    env = build_env()
    os.execvpe(argv[0], argv, env)
    return 1


def collect_pages(fetch):
    """Follow Link next at most MAX_PAGES times. A further next is truncated."""
    pages = []
    url = LIST_URL
    for _ in range(MAX_PAGES):
        response = fetch(url)
        pages.append(response)
        if response.get("status") in (304, 403, 429, 0):
            return pages, False
        nxt = link_next(header_get(response.get("headers") or {}, "Link"))
        if not nxt:
            return pages, False
        url = nxt
    last = pages[-1]
    truncated = link_next(header_get(last.get("headers") or {}, "Link")) is not None
    return pages, truncated


def scope_exact(repositories):
    if type(repositories) is not list or len(repositories) != 1:
        return False
    repo = repositories[0]
    if type(repo) is not dict:
        return False
    return type(repo.get("id")) is int and repo.get("id") == REPO_ID and repo.get("full_name") == REPO_NAME


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    pad = "=" * ((4 - (len(text) % 4)) % 4)
    return base64.urlsafe_b64decode(text + pad)


def openssl_sign(data, key_path):
    """RS256 via openssl. The PEM stays a file path; it is never an argv value."""
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path), "-binary"],
        input=data,
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout:
        raise ScopeStop("openssl-sign")
    return result.stdout


def mint_jwt(app_id, key_path, now, sign):
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    claims = {"iat": int(now) - 60, "exp": int(now) + 540, "iss": str(app_id)}
    payload = b64url(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = ("%s.%s" % (header, payload)).encode()
    return signing_input.decode("ascii") + "." + b64url(sign(signing_input, key_path))


def urllib_transport(method, url, headers, body, timeout=HTTP_TIMEOUT_S):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            parsed = json.loads(raw) if raw else None
            return {"status": response.status, "headers": dict(response.headers), "body": parsed}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = None
        return {"status": error.code, "headers": dict(error.headers or {}), "body": parsed}
    except (TimeoutError, urllib.error.URLError):
        return {"status": 0, "headers": {}, "body": None}


def fixture_transport(directory):
    """Fake GitHub at the HTTP boundary, shared by the supervisor and its child.

    routes.json is a list of {method, url (substring) or suffix, responses}.
    The n-th matching request gets responses[n], then the last one repeats.
    requests.jsonl records method, url, body and the bearer kind, never a token.
    """
    base = Path(directory)

    def transport(method, url, headers, body, timeout=HTTP_TIMEOUT_S):
        log = base / "requests.jsonl"
        with (base / "transport.lock").open("a+") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            routes = json.loads((base / "routes.json").read_text())
            prior = []
            if log.exists():
                prior = [json.loads(line) for line in log.read_text().splitlines() if line]
            chosen, response = None, {"status": 404, "headers": {}, "body": None}
            for index, route in enumerate(routes):
                if route.get("method", method) != method:
                    continue
                if "suffix" in route and not url.endswith(route["suffix"]):
                    continue
                if "url" in route and route["url"] not in url:
                    continue
                used = sum(1 for item in prior if item.get("route") == index)
                responses = route["responses"]
                chosen, response = index, responses[min(used, len(responses) - 1)]
                break
            bearer = (headers or {}).get("Authorization", "")[len("Bearer "):]
            with log.open("a") as handle:
                handle.write(json.dumps({
                    "method": method,
                    "url": url,
                    "body": body,
                    "route": chosen,
                    "auth": "jwt" if bearer.count(".") == 2 else "token",
                    "bearer_sha256": hashlib.sha256(bearer.encode()).hexdigest(),
                }) + "\n")
        if response.get("delay"):
            time.sleep(response["delay"])
        return {
            "status": response.get("status", 200),
            "headers": dict(response.get("headers") or {}),
            "body": response.get("body"),
        }

    return transport


def config_directory():
    override = os.environ.get("C11_POLLER_CONFIG_DIR")
    if override:
        return Path(override)
    return Path.home() / ".config" / "c11-pr-swift"


def default_transport():
    fixture = os.environ.get("C11_POLLER_FAKE_HTTP")
    if fixture:
        return fixture_transport(fixture)
    return urllib_transport


class AppClient:
    """GitHub App client. Scope inventory is un-narrowed; status uses a narrowed token.

    A 401 mints once for that request and retries once. A later request may mint
    again. A second 401 on the fresh credential stops that request. There is no
    fallback to gh, GITHUB_TOKEN, netrc, or the gh config. GET
    /app/installations/{id} is never the inventory and is not called; teardown
    DELETEs that URL and proves absence from the GET /app/installations list.
    """

    def __init__(self, app_id, installation_id, key_path, transport, now=None, sign=None):
        self.app_id = app_id
        self.installation_id = installation_id
        self.key_path = Path(key_path)
        self.transport = transport
        self.now = now or time.time
        self.sign = sign or openssl_sign
        self.scoped = False
        self.mints = []
        self.unscoped_token = None
        self.narrowed_token = None

    @classmethod
    def from_config(cls, config_dir=None, transport=None):
        directory = Path(config_dir) if config_dir else config_directory()
        try:
            app = json.loads((directory / "app.json").read_text())
        except (OSError, ValueError) as error:
            raise ScopeStop("app-config") from error
        if type(app) is not dict:
            raise ScopeStop("app-config")
        if type(app.get("app_id")) is not int or type(app.get("installation_id")) is not int:
            raise ScopeStop("app-config")
        key_path = directory / "private-key.pem"
        if not key_path.is_file():
            raise ScopeStop("key")
        return cls(app["app_id"], app["installation_id"], key_path, transport or default_transport())

    def _jwt(self):
        return mint_jwt(self.app_id, self.key_path, self.now(), self.sign)

    def mint(self, repositories):
        """None omits repository narrowing. A list narrows to those names."""
        body = {} if repositories is None else {"repositories": list(repositories)}
        if "permissions" in body:
            raise ScopeStop("permissions")
        self.mints.append(body)
        url = "%s/app/installations/%s/access_tokens" % (API, self.installation_id)
        response = self._send("POST", url, self._bearer(self._jwt()), body)
        token = response.get("body").get("token") if type(response.get("body")) is dict else None
        if response.get("status") not in (200, 201) or type(token) is not str or token == "":
            raise ScopeStop("mint")
        return token

    def verify_scope(self):
        self.unscoped_token = self.mint(None)
        response = self._authed(
            "GET",
            API + "/installation/repositories?per_page=100",
            self.unscoped_token,
            remint=lambda: self.mint(None),
        )
        body = response.get("body")
        repos = body.get("repositories") if type(body) is dict else None
        total = body.get("total_count") if type(body) is dict else None
        if response.get("status") != 200 or total != 1 or not scope_exact(repos):
            raise ScopeStop("scope")
        self.narrowed_token = self.mint(["c11"])
        self.scoped = True
        return True

    def list_pulls(self, headers):
        self._require_scope()
        request_headers = self._bearer(self.narrowed_token)
        if headers and headers.get("If-None-Match"):
            request_headers["If-None-Match"] = headers["If-None-Match"]
        return self._authed("GET", LIST_URL, self.narrowed_token, extra=request_headers, remint=self._remint_narrowed)

    def pull(self, number):
        self._require_scope()
        url = "%s/repos/%s/pulls/%s" % (API, REPO_NAME, number)
        return self._authed("GET", url, self.narrowed_token, remint=self._remint_narrowed)

    def get_url(self, url):
        self._require_scope()
        return self._authed("GET", url, self.narrowed_token, remint=self._remint_narrowed)

    def post_status_body(self, body):
        self._require_scope()
        sha = body.get("sha") if type(body) is dict else None
        if SHA_RE.fullmatch(sha or "") is None:
            raise ScopeStop("sha")
        url = "%s/repos/%s/statuses/%s" % (API, REPO_NAME, sha)
        payload = {
            "state": body["state"],
            "context": STATUS_CONTEXT,
            "description": body["description"],
        }
        return self._authed("POST", url, self.narrowed_token, body=payload, remint=self._remint_narrowed)

    def head_status(self, sha):
        """The latest c11/pr-swift state on this commit, or None."""
        self._require_scope()
        if SHA_RE.fullmatch(sha or "") is None:
            raise ScopeStop("sha")
        url = "%s/repos/%s/commits/%s/status" % (API, REPO_NAME, sha)
        response = self._authed("GET", url, self.narrowed_token, remint=self._remint_narrowed)
        body = response.get("body")
        if response.get("status") != 200 or type(body) is not dict or type(body.get("statuses")) is not list:
            return None
        for item in body["statuses"]:
            if type(item) is dict and item.get("context") == STATUS_CONTEXT:
                return item.get("state")
        return None

    def app_identity(self):
        """GET /app with the App JWT. The id must be this App's."""
        response = self._send("GET", API + "/app", self._bearer(self._jwt()), None)
        body = response.get("body")
        return response.get("status") == 200 and type(body) is dict and body.get("id") == self.app_id

    def installation_listed(self):
        """True, False, or None when the list could not be read."""
        response = self._send("GET", API + "/app/installations?per_page=100", self._bearer(self._jwt()), None)
        body = response.get("body")
        if response.get("status") != 200 or type(body) is not list:
            return None
        return any(type(item) is dict and item.get("id") == self.installation_id for item in body)

    def delete_installation(self):
        url = "%s/app/installations/%s" % (API, self.installation_id)
        return self._send("DELETE", url, self._bearer(self._jwt()), None)

    def _require_scope(self):
        if not self.scoped or not self.narrowed_token:
            raise ScopeStop("status-before-scope")

    def _remint_narrowed(self):
        self.narrowed_token = self.mint(["c11"])
        return self.narrowed_token

    def _bearer(self, token):
        return {
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        }

    def _authed(self, method, url, token, body=None, extra=None, remint=None):
        headers = extra or self._bearer(token)
        response = self._send(method, url, headers, body)
        if response.get("status") != 401 or remint is None:
            return response
        fresh = remint()
        headers = dict(headers)
        headers["Authorization"] = "Bearer " + fresh
        retried = self._send(method, url, headers, body)
        return retried

    def _send(self, method, url, headers, body):
        if "/app/installations/" in url and not url.endswith("/access_tokens") and method != "DELETE":
            raise ScopeStop("installation-get")
        leaked = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        auth = headers.get("Authorization", "")
        if leaked and leaked in auth:
            raise ScopeStop("env-token")
        if not auth.startswith("Bearer "):
            raise ScopeStop("env-token")
        try:
            return self.transport(method, url, headers, body)
        except TimeoutError:
            return {"status": 0, "headers": {}, "body": None}


class GhClient:
    """The Atlas gh login as the credential (Atin's decision; the active mode).

    The token is read with `gh auth token` at each request, held only for that
    request, and never logged or written. GH_TOKEN and GITHUB_TOKEN are removed
    from gh's environment so the stored login is what answers. The calls and the
    admission are the App mode's; only the bearer differs. Scope: GET
    /repos/Stage-11-Agentics/c11 must return repo id 1212901838 with push.
    """

    def __init__(self, transport, gh=None):
        self.transport = transport
        self.gh = gh or shutil.which("gh") or GH_FALLBACK
        self.scoped = False

    @classmethod
    def from_config(cls, data, transport=None):
        gh = data.get("gh")
        if gh is not None and (type(gh) is not str or gh == ""):
            raise ScopeStop("credential-config")
        return cls(transport or default_transport(), gh)

    def _token(self):
        env = {key: value for key, value in os.environ.items() if key not in GH_ENV_DROP}
        try:
            result = subprocess.run([self.gh, "auth", "token", "--hostname", "github.com"],
                                    capture_output=True, text=True, timeout=15, env=env)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CredentialUnavailable("gh-token") from error
        token = result.stdout.strip()
        if result.returncode != 0 or token == "" or any(char.isspace() for char in token):
            raise CredentialUnavailable("gh-token")
        return token

    def _request(self, method, url, body=None, etag=None):
        headers = {
            "Authorization": "Bearer " + self._token(),
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        }
        if etag:
            headers["If-None-Match"] = etag
        try:
            return self.transport(method, url, headers, body)
        except TimeoutError:
            return {"status": 0, "headers": {}, "body": None}

    def _call(self, method, url, body=None, etag=None):
        """A token that cannot be read is a skipped request, not a crash."""
        try:
            return self._request(method, url, body, etag)
        except CredentialUnavailable:
            return {"status": 0, "headers": {}, "body": None, "error": CREDENTIAL_UNAVAILABLE}

    def verify_scope(self):
        response = self._request("GET", "%s/repos/%s" % (API, REPO_NAME))
        body = response.get("body")
        permissions = body.get("permissions") if type(body) is dict else None
        if (response.get("status") != 200 or type(body) is not dict or type(body.get("id")) is not int
                or body.get("id") != REPO_ID or body.get("full_name") != REPO_NAME
                or type(permissions) is not dict or permissions.get("push") is not True):
            raise ScopeStop("scope")
        self.scoped = True
        return True

    def _require_scope(self):
        if not self.scoped:
            raise ScopeStop("status-before-scope")

    def list_pulls(self, headers):
        self._require_scope()
        return self._call("GET", LIST_URL, etag=(headers or {}).get("If-None-Match"))

    def get_url(self, url):
        self._require_scope()
        return self._call("GET", url)

    def pull(self, number):
        self._require_scope()
        return self._call("GET", "%s/repos/%s/pulls/%s" % (API, REPO_NAME, number))

    def head_status(self, sha):
        self._require_scope()
        if SHA_RE.fullmatch(sha or "") is None:
            raise ScopeStop("sha")
        response = self._call("GET", "%s/repos/%s/commits/%s/status" % (API, REPO_NAME, sha))
        raise_if_unavailable(response)
        body = response.get("body")
        if response.get("status") != 200 or type(body) is not dict or type(body.get("statuses")) is not list:
            return None
        for item in body["statuses"]:
            if type(item) is dict and item.get("context") == STATUS_CONTEXT:
                return item.get("state")
        return None

    def post_status_body(self, body):
        self._require_scope()
        sha = body.get("sha") if type(body) is dict else None
        if SHA_RE.fullmatch(sha or "") is None:
            raise ScopeStop("sha")
        payload = {"state": body["state"], "context": STATUS_CONTEXT, "description": body["description"]}
        return self._call("POST", "%s/repos/%s/statuses/%s" % (API, REPO_NAME, sha), payload)


def raise_if_unavailable(response):
    """A skipped gh request is its own outcome, never "missing" or "no status"."""
    if type(response) is dict and response.get("error") == CREDENTIAL_UNAVAILABLE:
        raise CredentialUnavailable(CREDENTIAL_UNAVAILABLE)


def make_client(config_dir=None):
    """app.json means App mode. Otherwise credential.json {"mode": "gh"} means gh mode."""
    directory = Path(config_dir) if config_dir else config_directory()
    if (directory / "app.json").exists():
        return AppClient.from_config(directory)
    try:
        data = json.loads((directory / "credential.json").read_text())
    except (OSError, ValueError) as error:
        raise ScopeStop("credential-config") from error
    if type(data) is not dict or data.get("mode") != "gh":
        raise ScopeStop("credential-config")
    return GhClient.from_config(data)


def status_body(sha, state, description):
    if len(description) > 140:
        raise ValueError("description longer than 140")
    if state not in ("pending", "success", "failure", "error"):
        raise ValueError(state)
    if SHA_RE.fullmatch(sha) is None:
        raise ValueError("sha")
    return {
        "state": state,
        "context": STATUS_CONTEXT,
        "description": description,
    }


class Supervisor:
    """The poll loop's state. `supervise` keeps one instance for the process lifetime.

    The queue, the rate-limit deadline, the App client and the set of heads
    already reported live here, in memory. Launchd keeps one process; the
    supervisor.lock flock is the second lock.
    """

    def __init__(self, root, world, cadence=CADENCE_S):
        self.root = Path(root)
        self.world = world
        self.cadence = cadence
        self.not_before = 0
        self.disarmed = False
        self.scoped = False
        self.queue = []
        self.reported = {}
        self.spawns = []
        self.fetches = []
        self.posts = []
        self.attempt_clock = None
        self.acquired_at = None
        self.build_end = None
        self.delivered = False
        self.stopped = None
        self.credential_skipped = False
        self.awaiting_kit = {}

    def state(self):
        path = self.root / "state"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def log(self, **fields):
        forbidden = ("authorization", "token", "pem", "private")
        for key in fields:
            if key.lower() in forbidden:
                raise ValueError(key)
        record = dict(fields)
        record["ts"] = self.world.time()
        path = self.state() / "decisions.jsonl"
        with path.open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        self._trim_decisions(path)

    def _trim_decisions(self, path):
        """Keep the last DECISION_LIMIT lines. Result directories are not swept."""
        try:
            lines = path.read_text().splitlines()
        except OSError:
            return
        if len(lines) <= DECISION_LIMIT:
            return
        path.write_text("\n".join(lines[-DECISION_LIMIT:]) + "\n")

    def hold_supervisor_lock(self):
        path = self.state() / "supervisor.lock"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None
        return fd

    def poll_once(self):
        """One cycle under its own supervisor.lock. `supervise` holds the lock itself."""
        lock = self.hold_supervisor_lock()
        if lock is None:
            self.log(decision="supervisor-busy")
            return "busy"
        try:
            return self.cycle()
        finally:
            os.close(lock)

    def cycle(self):
        if self.disarmed:
            return "disarmed"
        if recover(self.root, alive=self.world.group_alive, kill=self.world.killpg,
                   sleep=self.world.sleep, monotonic=self.world.monotonic) == "stuck":
            self.disarmed = True
            self.log(decision="stuck")
            return "stuck"
        if self.world.time() < self.not_before:
            waited = self.not_before - self.world.time()
            self.world.sleep(waited)
            self.log(decision="backoff", seconds=waited)
            return "backoff"
        if not self.scoped:
            scoped = self.world.scope_ok()
            if scoped is None:
                self.not_before = self.world.time() + self.cadence
                self.log(decision="credential-unavailable")
                return "no-build"
            if not scoped:
                self.disarmed = True
                self.log(decision="scope-stop")
                return "scope-stop"
            self.scoped = True
        response = self.world.list_page(self._list_headers())
        status = response.get("status", 0)
        headers = response.get("headers") or {}
        store = self.state() / "list.json"
        if status == 304:
            saved = load_list_store(store)
            if saved is None:
                clear_list_store(store)
                self.log(decision="etag-cleared")
                return "etag-cleared"
            body = saved["body"]
        elif status == 0:
            self.not_before = self.world.time() + self.cadence
            self.log(decision=response.get("error") or "timeout")
            return "no-build"
        elif status == 401:
            self.disarmed = True
            self.log(decision="unauthorized")
            return "no-build"
        elif status != 200:
            wait = rate_wait(status, headers, self.world.time(), 1)
            if wait is None:
                self.disarmed = True
                self.log(decision="rate-limited-no-deadline", status=status)
                return "no-build"
            self.not_before = self.world.time() + (wait if wait > 0 else self.cadence)
            self.log(decision="rate-or-error", status=status, seconds=wait)
            return "no-build"
        else:
            pages, truncated = self._pages_from(response)
            stopped = self._stop_for_later_page(pages)
            if stopped is not None:
                return stopped
            body = []
            for page in pages:
                chunk = page.get("body")
                if type(chunk) is not list:
                    clear_list_store(store)
                    self.log(decision="malformed-list")
                    return "no-build"
                body.extend(chunk)
            etag = header_get(headers, "ETag")
            if etag:
                save_list_store(store, etag, body)
            if truncated:
                self.log(decision="pr_list_truncated")
            headers = self._latest_quota(pages, headers)
        admitted = []
        for obj in body:
            ok, reason, captured = admit(obj)
            if not ok:
                number = obj.get("number") if type(obj) is dict else None
                self.log(decision="skipped", reason=reason, pr=number)
                continue
            admitted.append(captured)
        needed = 1 + len(admitted)
        wait = rate_wait(status if status != 304 else 200, headers, self.world.time(), needed)
        if wait is None or (wait and wait > 0 and _remaining(headers) < needed):
            if wait is None:
                self.disarmed = True
                self.log(decision="rate-limited-no-deadline", needed=needed)
                return "no-build"
            self.not_before = self.world.time() + wait
            self.log(decision="backoff", seconds=wait, needed=needed)
            return "backoff"
        self._remember_queue(admitted)
        self._resolve_absent(body)
        self.not_before = self.world.time() + (wait or self.cadence)
        return self.maybe_start()

    def _list_headers(self):
        saved = load_list_store(self.state() / "list.json")
        headers = {"Accept": "application/vnd.github+json", "User-Agent": USER_AGENT}
        if saved is not None:
            headers["If-None-Match"] = saved["etag"]
        return headers

    def _pages_from(self, first):
        pages = [first]
        url = link_next(header_get(first.get("headers") or {}, "Link"))
        while url and len(pages) < MAX_PAGES:
            page = self.world.list_page_url(url)
            pages.append(page)
            if page.get("status") != 200:
                break
            url = link_next(header_get(page.get("headers") or {}, "Link"))
        truncated = False
        if len(pages) == MAX_PAGES:
            truncated = link_next(header_get(pages[-1].get("headers") or {}, "Link")) is not None
        return pages, truncated

    def _stop_for_later_page(self, pages):
        """A page after the first carries its own deadline. It does not disarm on timeout."""
        for page in pages[1:]:
            status = page.get("status", 0)
            page_headers = page.get("headers") or {}
            if status in (403, 429):
                wait = rate_wait(status, page_headers, self.world.time(), 1)
                if wait is None:
                    self.disarmed = True
                    self.log(decision="rate-limited-no-deadline", status=status)
                    return "no-build"
                self.not_before = self.world.time() + (wait if wait > 0 else self.cadence)
                self.log(decision="rate-or-error", status=status, seconds=wait)
                return "no-build"
            if status == 0:
                self.not_before = self.world.time() + self.cadence
                self.log(decision=page.get("error") or "timeout")
                return "no-build"
            if status != 200:
                self.log(decision="rate-or-error", status=status)
                return "no-build"
        return None

    def _latest_quota(self, pages, fallback):
        """The newest page that carries Remaining or Reset is this cycle's quota."""
        chosen = fallback
        for page in pages:
            page_headers = page.get("headers") or {}
            if header_get(page_headers, "X-RateLimit-Remaining") is not None or header_get(page_headers, "X-RateLimit-Reset") is not None:
                chosen = page_headers
        return chosen

    def _remember_queue(self, admitted):
        """Queue admitted heads that are not queued and not already reported."""
        known = {item["pr"] for item in self.queue}
        for captured in admitted:
            if captured["pr"] in known or self.reported.get(captured["pr"]) == captured["sha"]:
                continue
            item = dict(captured)
            item["queued_at"] = self.world.time()
            self.queue.append(item)

    def _resolve_absent(self, body):
        present = set()
        for obj in body:
            if type(obj) is dict and type(obj.get("number")) is int:
                present.add(obj["number"])
        kept = []
        for item in self.queue:
            if item["pr"] in present:
                kept.append(item)
                continue
            try:
                looked = self.world.pull(item["pr"])
            except CredentialUnavailable:
                self.log(decision=CREDENTIAL_UNAVAILABLE, pr=item["pr"], sha=item["sha"])
                kept.append(item)
                continue
            if looked is None or (type(looked) is dict and looked.get("status") == 404):
                self.log(decision="revoked", pr=item["pr"], reason="absent")
                continue
            payload = looked.get("body", looked) if type(looked) is dict and "body" in looked else looked
            ok, reason, fresh = admit(payload)
            if not ok:
                self.log(decision="revoked", pr=item["pr"], reason=reason)
                continue
            if fresh["sha"] != item["sha"] or fresh["ref"] != item["ref"]:
                self.log(decision="superseded", pr=item["pr"])
                kept.append(fresh)
                continue
            kept.append(item)
        self.queue = kept

    def _next_item(self):
        """The first queued head that still revalidates and has no terminal status.

        A head whose c11/pr-swift status is already success or failure is
        recorded and skipped, so a restarted process does not rebuild it. A head
        waiting for its GhosttyKit cache entry is passed over, with no network
        call, until that entry exists.
        """
        for item in list(self.queue):
            key = (item["pr"], item["sha"])
            if key in self.awaiting_kit:
                if not self.world.kit_available(self.awaiting_kit[key]):
                    continue
                del self.awaiting_kit[key]
            ok, reason, _detail = revalidate(
                item,
                lambda number: self.world.pull(number),
                lambda ref: self.world.ls_remote(ref),
            )
            if reason == CREDENTIAL_UNAVAILABLE:
                return self._credential_skip(item)
            if not ok:
                # The captured SHA stays what the list admitted. A moved tip is not
                # written into this attempt and is not fetched.
                self.log(decision=reason, pr=item["pr"], sha=item["sha"])
                self.queue.remove(item)
                continue
            try:
                prior = self.world.head_status(item["sha"])
            except CredentialUnavailable:
                return self._credential_skip(item)
            if prior in TERMINAL_STATES:
                self.reported[item["pr"]] = item["sha"]
                self.log(decision="already-reported", pr=item["pr"], sha=item["sha"])
                self.queue.remove(item)
                continue
            return item
        return None

    def _rotate(self, item):
        """A head that could not be prepared goes to the back, so it never blocks the rest."""
        if item in self.queue:
            self.queue.remove(item)
            self.queue.append(item)

    def _credential_skip(self, item):
        """The head stays queued; this cycle starts nothing."""
        self.credential_skipped = True
        self.log(decision=CREDENTIAL_UNAVAILABLE, pr=item["pr"], sha=item["sha"])
        return None

    def maybe_start(self):
        """Before every start, recover again. A live recorded group admits nothing."""
        if recover(self.root, alive=self.world.group_alive, kill=self.world.killpg,
                   sleep=self.world.sleep, monotonic=self.world.monotonic) != "ready":
            self.disarmed = True
            self.log(decision="stuck")
            return "stuck"
        if not self.queue:
            return "idle"
        if self.world.guests():
            self.log(decision="no-start", reason="guest")
            return "no-start"
        if self.world.slot_held(1) or self.world.slot_held(2):
            self.log(decision="no-start", reason="slot")
            return "no-start"
        self.credential_skipped = False
        item = self._next_item()
        if item is None:
            return CREDENTIAL_UNAVAILABLE if self.credential_skipped else "idle"
        if not self._fetch(item):
            self._rotate(item)
            return "fetch_failed"
        if not self._prepare_tree(item):
            self._rotate(item)
            return "residue"
        if self.world.guests() or self.world.slot_held(1) or self.world.slot_held(2):
            self.log(decision="no-start", reason="raced")
            return "no-start"
        return self._spawn(item)

    def _fetch(self, item):
        def git(args, cwd):
            assert_git_args(args)
            self.fetches.append(list(args))
            return self.world.git(args, cwd)
        try:
            ok, reason = fetch_captured(git, self.world.worktree, item)
        except OriginRefused as error:
            self.log(decision="origin_refused", detail=str(error))
            return False
        if not ok:
            self.log(decision=reason, pr=item["pr"], sha=item["sha"])
        return ok

    def _ghostty_gitlink(self, item):
        shown = self.world.git(["rev-parse", "%s:ghostty" % item["sha"]], self.world.worktree)
        gitlink = (shown.stdout or "").strip() if shown.returncode == 0 else ""
        return gitlink if SHA_RE.fullmatch(gitlink) else None

    def _prepare_tree(self, item):
        if not clean_worktree(self.world.git, self.world.worktree):
            self.log(decision="residue", pr=item["pr"])
            return False
        sub_status = [porcelain_paths(self.world.status(Path(self.world.worktree) / path)) for path, _url in GITLINKS]
        gitlink = self._ghostty_gitlink(item)
        if gitlink is None or self.world.ghosttykit(gitlink) == "ghosttykit_missing":
            if gitlink is not None:
                self.awaiting_kit[(item["pr"], item["sha"])] = gitlink
            self.log(decision="ghosttykit_missing", pr=item["pr"], gitlink=gitlink)
            return False
        parent = porcelain_paths(self.world.status(self.world.worktree))
        if not residue_ok(parent, sub_status, symlink_ready=True):
            self.log(decision="residue", pr=item["pr"])
            return False
        if not self.world.toolchain_ok():
            self.log(decision="toolchain", pr=item["pr"])
            return False
        return True

    def _spawn(self, item):
        """One attempt: a fresh attempt id, then at most one cache retry.

        The item leaves the queue whatever happens. A later list re-admits it
        unless a success or failure for that head was delivered.
        """
        item["attempt_id"] = uuid.uuid4().hex
        self.acquired_at = None
        self.build_end = None
        self.attempt_clock = self.world.time()
        self.stopped = None
        self.delivered = False
        self._drop(item)
        for invocation in (1, 2):
            code = self._spawn_one(item, invocation)
            self.build_end = self.world.time()
            self._note_acquired()
            if code == "rejected":
                return "rejected"
            if self.stopped:
                return "stopped"
            if self.world.last_exit == 0:
                break
        self._finish(item, self.world.last_exit)
        return "started"

    def _spawn_one(self, item, invocation):
        attempt_id = item["attempt_id"]
        result = result_directory(self.state(), attempt_id, invocation)
        log_path = result.parent / ("%s-%s.log" % (attempt_id, invocation))
        current = {
            "attempt_id": attempt_id,
            "invocation": invocation,
            "pr": item["pr"],
            "sha": item["sha"],
            "ref": item["ref"],
            "result": str(result),
            "log": str(log_path),
        }
        (self.state() / "current.json").write_text(json.dumps(current) + "\n")
        argv = self.world.build_argv(self.world.worktree, self.root / "cache" / "DerivedData", result)
        command = slot_command(self.root, argv)
        self.spawns.append({"command": command, "sha": item["sha"], "result": str(result), "invocation": invocation})
        append_event(self.root, {"event": "spawn", "sha": item["sha"], "invocation": invocation, "result": str(result)})
        exit_code = self.world.spawn(command, log_path)
        self.world.last_exit = exit_code
        if exit_code in (3, 4):
            self.log(decision="child-rejected", pr=item["pr"], sha=item["sha"], invocation=invocation, exit=exit_code)
            return "rejected"
        return "ran"

    def _note_acquired(self):
        """The child writes acquired_at when it holds the slot. Queue time is earlier."""
        if self.acquired_at is not None:
            return
        recorded = read_running(self.root)
        if recorded is None:
            return
        stamp = recorded.get("acquired_at")
        if type(stamp) is int or type(stamp) is float:
            self.acquired_at = stamp

    def build_seconds(self):
        """Slot acquisition (first invocation) to the end of the last build."""
        start = self.acquired_at if self.acquired_at is not None else self.attempt_clock
        end = self.build_end if self.build_end is not None else self.world.time()
        if start is None:
            return 0
        return max(0.0, end - start)

    def _finish(self, item, exit_code):
        seconds = self.build_seconds()
        state, description = classify_result(self.world.build_log, seconds)
        if exit_code != 0 and state == "success":
            state, description = "failure", "failed %ss" % int(seconds)
        self.delivered = self._post(item["sha"], state, description, pr=item["pr"], build_seconds=round(seconds, 3))
        if self.delivered:
            self.reported[item["pr"]] = item["sha"]

    def _post(self, sha, state, description, pr=None, **fields):
        """Three tries, honouring Retry-After. No outbox: a miss is logged and dropped."""
        body = status_body(sha, state, description)
        body["sha"] = sha
        self.posts.append(body)
        started = self.world.time()
        last = None
        for attempt in range(1, POST_TRIES + 1):
            response = self.world.post_status(body)
            last = response.get("status") if type(response) is dict else None
            if last in (200, 201):
                self.log(decision="result", pr=pr, sha=sha, state=state, description=description,
                         post_seconds=round(self.world.time() - started, 3), **fields)
                return True
            retryable = last in (0, 403, 429) or (type(last) is int and last >= 500)
            if attempt == POST_TRIES or not retryable:
                break
            headers = response.get("headers") if type(response) is dict else None
            wait = parse_retry_after(header_get(headers or {}, "Retry-After"), self.world.time())
            self.world.sleep(2 ** (attempt - 1) if wait is None else wait)
        self.log(decision="status_undelivered", pr=pr, sha=sha, state=state, description=description,
                 status=last, post_seconds=round(self.world.time() - started, 3), **fields)
        return False

    def _drop(self, item):
        for index, queued in enumerate(self.queue):
            if queued.get("pr") == item.get("pr"):
                self.queue.pop(index)
                return

    def _pace(self, seconds):
        """Advance the world's clock, and a real slice when that clock is fake.

        A fake sleep finishes in the same instant, which would SIGKILL a process
        that is still dying from SIGTERM. A real sleep already covers the slice.
        """
        before = time.monotonic()
        self.world.sleep(seconds)
        elapsed = time.monotonic() - before
        floor = min(float(seconds), 0.05)
        if elapsed < floor:
            time.sleep(floor - elapsed)

    def _stop_group(self, record):
        pgid = record.get("pgid")
        if type(pgid) is not int or pgid <= 1:
            return False
        return kill_until_esrch(
            pgid,
            self.world.group_alive,
            self.world.killpg,
            self._pace,
            self.world.monotonic,
            TERM_GRACE_S,
            KILL_BUDGET_S,
        )

    def _watch_reason(self, record):
        if record.get("pr") is not None and record.get("sha") and record.get("ref"):
            ok, reason, _detail = revalidate(
                {"pr": record["pr"], "sha": record["sha"], "ref": record["ref"]},
                lambda number: self.world.pull(number),
                lambda ref: self.world.ls_remote(ref),
            )
            if reason == CREDENTIAL_UNAVAILABLE:
                # Unknown, not revoked: keep the build and check again next tick.
                self.log(decision=CREDENTIAL_UNAVAILABLE, pr=record["pr"], sha=record["sha"], during="watch")
            elif not ok:
                return reason
        our = record.get("slot")
        other = None
        if our in (1, 2):
            other = 1 if our == 2 else 2
        other_held = False if other is None else self.world.slot_held(other)
        return yield_reason(self.world.guests(), our, other_held)

    def watch(self, record):
        """Every 5s while a build runs. Revalidate, then kill until the group is gone."""
        reason = self._watch_reason(record)
        if reason is None:
            return None
        self.stopped = reason
        self._stop_group(record)
        sha = record.get("sha") or ""
        if reason in ("guest", "slot"):
            self.delivered = self._post(sha, "error", "yielded to Atlas work", pr=record.get("pr"))
            self.log(decision="yielded", reason=reason, pr=record.get("pr"))
        elif reason == "superseded":
            self.delivered = self._post(sha, "failure", "superseded", pr=record.get("pr"))
            self.log(decision="superseded", pr=record.get("pr"), sha=sha)
        elif reason == "revoked":
            self.delivered = self._post(sha, "failure", "revoked", pr=record.get("pr"))
            self.log(decision="revoked", pr=record.get("pr"), sha=sha)
        else:
            self.delivered = self._post(sha, "failure", reason, pr=record.get("pr"))
            self.log(decision=reason, pr=record.get("pr"), sha=sha)
        return reason

    def watch_while(self, running, record):
        """Every 5s while running() is true. Returns the stop reason, or None."""
        while running():
            reason = self.watch(record)
            if reason is not None:
                return reason
            self.world.sleep(YIELD_INTERVAL_S)
        return None


def _remaining(headers):
    try:
        return int(header_get(headers, "X-RateLimit-Remaining"))
    except (TypeError, ValueError):
        return 0


def slot_command(root, build_argv):
    poller = str(Path(__file__).resolve())
    slots = str(Path(__file__).resolve().parent / "atlas_build_slots.py")
    return [
        sys.executable, slots, SLUG,
        sys.executable, poller, "child", "--root", str(root),
        "--exec", *build_argv,
    ]


def render_plist(home, template=None):
    path = Path(template) if template else (
        Path(__file__).resolve().parent / "launchd" / "com.stage11.c11-pr-swift-poller.plist.in"
    )
    return path.read_text().replace("@HOME@", str(home))


def layout_inside_worktree(script_path, worktree):
    script = Path(script_path).resolve()
    root = Path(worktree).resolve()
    return script == root or root in script.parents


def teardown(stages, actor):
    """Remove recorded local stages. Unknown stages are not assumed.

    The App is uninstalled, and the absence check runs, only when
    app_installed was recorded. The key is destroyed only after that check
    when the App stage is present.
    """
    if type(stages) is not list:
        return {"action": "reconcile", "removed": []}
    unknown = [stage for stage in stages if stage not in KNOWN_STAGES]
    if unknown:
        return {"action": "reconcile", "unknown": unknown, "removed": []}
    removed = []
    if "plist_installed" in stages:
        actor.bootout()
        if not actor.processes_gone():
            return {"action": "stop", "removed": removed}
        actor.remove_plist()
        removed.append("plist_installed")
    if "app_installed" in stages:
        actor.uninstall_app()
        if not actor.absence_ok():
            return {"action": "stop", "removed": removed}
        removed.append("app_installed")
    if "key_placed" in stages:
        actor.remove_key()
        removed.append("key_placed")
    if "gh_configured" in stages:
        actor.remove_gh_config()
        removed.append("gh_configured")
    if not actor.remove_local_state():
        return {"action": "stop", "removed": removed, "reason": "local-state"}
    return {"action": "done", "removed": removed}


def rotate_swap(key_dir, authenticates):
    """Documented steps 3 and 4. Refuses to move the live key until .new works.

    The previous key stays as private-key.pem.old. Nothing deletes it here.
    """
    directory = Path(key_dir)
    current = directory / "private-key.pem"
    new = directory / "private-key.pem.new"
    old = directory / "private-key.pem.old"
    if not new.is_file():
        raise FileNotFoundError(str(new))
    if not authenticates(new):
        raise RuntimeError("new key did not authenticate")
    if old.exists():
        raise FileExistsError(str(old))
    os.replace(current, old)
    os.replace(new, current)
    return "swapped"


def rotate_drop_old(key_dir, authenticates):
    """Documented step 7. Refuses while the old key still authenticates."""
    old = Path(key_dir) / "private-key.pem.old"
    if not old.is_file():
        raise FileNotFoundError(str(old))
    if authenticates(old):
        raise RuntimeError("old key still authenticates")
    old.unlink()
    return "dropped"


def ls_remote_tip(ref, cwd):
    result = run_git(["ls-remote", PARENT_URL, "refs/heads/%s" % ref], cwd)
    if result.returncode != 0:
        raise ScopeStop("ls-remote")
    return result.stdout


def _revalidate_with_client(root, client):
    current = json.loads((Path(root) / "state" / "current.json").read_text())

    def fetch_pr(number):
        response = client.pull(number)
        raise_if_unavailable(response)
        if response.get("status") != 200:
            return None
        return response.get("body")

    return revalidate(current, fetch_pr, lambda ref: ls_remote_tip(ref, root))


def post_build_pending(client, current):
    """Pending status after the second revalidation, immediately before exec."""
    body = status_body(current["sha"], "pending", "build started")
    body["sha"] = current["sha"]
    return client.post_status_body(body)


def run_child_cli(root, exec_argv):
    """The build child: its own client, the second revalidation, pending, exec.

    A credential or scope failure is a refusal before pending (exit 3), so the
    supervisor neither posts nor retries it.
    """
    holder = {}

    def revalidate_fn(root):
        try:
            client = make_client()
            client.verify_scope()
        except (ScopeStop, CredentialUnavailable) as error:
            append_event(root, {"event": "child-credential-failed", "reason": str(error)})
            return False, "credential", str(error)
        holder["client"] = client
        return _revalidate_with_client(root, client)

    def post_pending(current):
        client = holder.get("client")
        if client is None:
            append_event(root, {"event": "pending-failed", "reason": "no-client"})
            return False
        try:
            response = post_build_pending(client, current)
        except ScopeStop as error:
            append_event(root, {"event": "pending-failed", "reason": str(error)})
            return False
        status = response.get("status")
        if status not in (200, 201):
            append_event(root, {"event": "pending-failed", "status": status})
            return False
        append_event(root, {"event": "pending", "sha": current["sha"]})
        return True

    return child_main(root, exec_argv, revalidate_fn, post_pending)


def service_enabled(root):
    """True only when state/enabled.json sets enabled to the boolean true.

    The LaunchAgent template does not create that file. Bootstrapping the
    template still exits 2.
    """
    path = Path(root) / "state" / "enabled.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if type(data) is not dict or data.get("enabled") is not True:
        return None
    return data


class ProductionWorld:
    """The real adapters: AppClient over HTTP, git, tart, the slot locks, processes.

    Fixtures swap tools, not code paths: C11_POLLER_FAKE_HTTP replaces the
    HTTP transport, and C11_POLLER_GIT, C11_POLLER_TART, C11_POLLER_ZIG,
    C11_POLLER_XCODEBUILD, C11_POLLER_KIT_CACHE and C11_ATLAS_SLOTS_DIR name
    the tools and directories. The plist sets none of them.
    """

    def __init__(self, root, worktree):
        self.root = Path(root)
        self.worktree = str(worktree)
        self.supervisor = None
        self.client = None
        self.last_exit = 0
        self.log_path = None

    def bind(self, supervisor):
        self.supervisor = supervisor

    def time(self):
        return time.time()

    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(max(0.0, seconds))

    def scope_ok(self):
        """True, False (a scope or config refusal: disarm), or None (credential unavailable: retry)."""
        try:
            self.client = make_client()
            self.client.verify_scope()
        except CredentialUnavailable:
            self.client = None
            return None
        except ScopeStop:
            self.client = None
            return False
        return True

    def list_page(self, headers):
        return self.client.list_pulls(headers)

    def list_page_url(self, url):
        return self.client.get_url(url)

    def pull(self, number):
        response = self.client.pull(number)
        raise_if_unavailable(response)
        if response.get("status") != 200:
            return None
        return response.get("body")

    def head_status(self, sha):
        return self.client.head_status(sha)

    def ls_remote(self, ref):
        return ls_remote_tip(ref, self.root)

    def guests(self):
        tart = os.environ.get("C11_POLLER_TART", "tart")
        try:
            result = subprocess.run([tart, "list"], capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            return ["tart-unavailable"]
        if result.returncode != 0:
            return ["tart-unavailable"]
        return running_guests(result.stdout)

    def slot_held(self, number, _probe=slot_held):
        slots = os.environ.get("C11_ATLAS_SLOTS_DIR", "/tmp/c11-atlas-build-slots")
        return _probe(slots, number)

    def group_alive(self, pgid, _probe=group_alive):
        return _probe(pgid)

    def killpg(self, pgid, sig):
        _signal_group(pgid, sig)

    def git(self, args, cwd):
        return run_git(args, cwd)

    def status(self, cwd):
        result = self.git(["status", "--porcelain=v1", "--ignored"], cwd)
        return result.stdout or ""

    def _kit_cache(self):
        cache = os.environ.get("C11_POLLER_KIT_CACHE") or os.environ.get("CMUX_GHOSTTYKIT_CACHE_DIR")
        return cache or str(Path.home() / ".cache" / "cmux" / "ghosttykit")

    def ghosttykit(self, gitlink):
        """Link the cache entry for the Ghostty gitlink, never the parent SHA."""
        return link_ghosttykit(self._kit_cache(), gitlink, self.worktree)

    def kit_available(self, gitlink):
        return (Path(self._kit_cache()) / gitlink / "GhosttyKit.xcframework").is_dir()

    def toolchain_ok(self):
        zig = os.environ.get("C11_POLLER_ZIG") or str(Path.home() / "zig-0.15.2" / "zig")
        try:
            result = subprocess.run([zig, "version"], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return result.returncode == 0 and result.stdout.strip() == "0.15.2"

    def build_argv(self, worktree, derived, result):
        return xcodebuild_argv(worktree, derived, result)

    @property
    def build_log(self):
        if self.log_path is None:
            return ""
        try:
            return Path(self.log_path).read_text(errors="replace")
        except OSError:
            return ""

    def post_status(self, body):
        if self.client is None:
            return {"status": 0, "headers": {}, "body": None}
        try:
            return self.client.post_status_body(body)
        except ScopeStop:
            return {"status": 0, "headers": {}, "body": None}

    def spawn(self, command, log_path):
        """Run the slot wrapper, collecting stdout and stderr into the attempt log."""
        self.log_path = Path(log_path)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        stale = read_running(self.root)
        with self.log_path.open("wb") as log:
            proc = subprocess.Popen(command, start_new_session=True, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        record = None
        while proc.poll() is None and time.monotonic() < deadline:
            record = read_running(self.root)
            if record is not None and record != stale:
                break
            record = None
            time.sleep(0.05)
        if proc.poll() is None and record is not None and self.supervisor is not None:
            self.supervisor.watch_while(lambda: proc.poll() is None, record)
        if proc.poll() is None:
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                _signal_group(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
        self.last_exit = 1 if proc.returncode is None else proc.returncode
        return self.last_exit


class InstallationActor:
    """Recorded-stage teardown against launchd, the process table and the App API."""

    def __init__(self, root):
        self.root = Path(root)
        self.config_dir = config_directory()

    def _launchctl(self, *args):
        tool = os.environ.get("C11_POLLER_LAUNCHCTL") or "launchctl"
        target = "gui/%s/%s" % (os.getuid(), LABEL)
        return subprocess.run([tool, *args, target], capture_output=True, text=True)

    def _plist_path(self):
        override = os.environ.get("C11_POLLER_PLIST")
        if override:
            return Path(override)
        return Path.home() / "Library" / "LaunchAgents" / (LABEL + ".plist")

    def bootout(self):
        self._launchctl("bootout")

    def processes_gone(self):
        """The service is unloaded, the recorded build group is ESRCH, and no supervisor holds its lock."""
        if self._launchctl("print").returncode == 0:
            append_event(self.root, {"event": "teardown-blocked", "reason": "service-loaded"})
            return False
        recorded = read_running(self.root)
        if recorded is not None and group_alive(recorded["pgid"]):
            append_event(self.root, {"event": "teardown-blocked", "reason": "build-group", "pgid": recorded["pgid"]})
            return False
        lock = self.root / "state" / "supervisor.lock"
        if lock.exists() and not lock_is_free(lock):
            append_event(self.root, {"event": "teardown-blocked", "reason": "supervisor-lock"})
            return False
        return True

    def remove_plist(self):
        try:
            self._plist_path().unlink()
        except FileNotFoundError:
            pass

    def uninstall_app(self):
        """DELETE the installation with the App JWT. Absence is proven separately."""
        try:
            response = AppClient.from_config(self.config_dir).delete_installation()
        except ScopeStop as error:
            append_event(self.root, {"event": "uninstall-failed", "reason": str(error)})
            return False
        append_event(self.root, {"event": "uninstall", "status": response.get("status")})
        return response.get("status") in (204, 404)

    def absence_ok(self):
        """The key still authenticates as this App, and the installation is not listed.

        A rejected key proves nothing about the installation, so it is not absence.
        """
        try:
            client = AppClient.from_config(self.config_dir)
            if not client.app_identity():
                append_event(self.root, {"event": "absence-unproven", "reason": "app-identity"})
                return False
            listed = client.installation_listed()
        except ScopeStop as error:
            append_event(self.root, {"event": "absence-unproven", "reason": str(error)})
            return False
        if listed is not False:
            append_event(self.root, {"event": "absence-unproven", "reason": "listed" if listed else "list"})
            return False
        return True

    def remove_key(self):
        key = self.config_dir / "private-key.pem"
        try:
            key.unlink()
        except FileNotFoundError:
            pass

    def remove_gh_config(self):
        """Only the poller's own credential.json. The gh login itself is not touched."""
        try:
            (self.config_dir / "credential.json").unlink()
        except FileNotFoundError:
            pass

    def remove_local_state(self):
        """Remove cache/, then state/ with stages.json last. True only when both are gone.

        An absent path is already removed. Any other error is reported and leaves
        stages.json in place, so a later teardown can retry.
        """
        state = self.root / "state"
        record = state / "stages.json"
        try:
            _remove_path(self.root / "cache")
            if state.is_dir():
                for child in state.iterdir():
                    if child.name != "stages.json":
                        _remove_path(child)
                saved = record.read_bytes() if record.exists() else None
                _remove_path(record)
                try:
                    state.rmdir()
                except OSError:
                    # The directory stays, so its stage record must stay too.
                    if saved is not None:
                        record.write_bytes(saved)
                    raise
        except OSError as error:
            sys.stderr.write("teardown: local state not removed: %s\n" % error)
            return False
        return not (self.root / "cache").exists() and not state.exists()


def _remove_path(path):
    path = Path(path)
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except FileNotFoundError:
        pass


def supervise_cli(root, cycles=None):
    """The long-running service. `--cycles N` stops after N cycles, for fixtures.

    A disarmed supervisor stays alive and idle, so launchd's KeepAlive does not
    restart it into polling. A human clears the cause and restarts the service.
    """
    enabled = service_enabled(root)
    if enabled is None:
        sys.stderr.write("supervise is not armed; launchd bootstrap is not authorized\n")
        return 2
    worktree = enabled.get("worktree")
    if type(worktree) is not str or worktree == "":
        worktree = str(Path(root) / "worktree")
    if layout_inside_worktree(Path(__file__).resolve(), worktree):
        sys.stderr.write("supervise refuses to run inside the worktree\n")
        return 2
    try:
        cadence = float(os.environ.get("C11_POLLER_CADENCE_S", CADENCE_S))
    except ValueError:
        cadence = CADENCE_S
    world = ProductionWorld(root, worktree)
    supervisor = Supervisor(root, world, cadence=cadence)
    world.bind(supervisor)
    lock = supervisor.hold_supervisor_lock()
    if lock is None:
        sys.stderr.write("another supervisor holds supervisor.lock\n")
        return 2
    try:
        count = 0
        while cycles is None or count < cycles:
            if supervisor.disarmed:
                if cycles is not None:
                    break
                world.sleep(DISARMED_SLEEP_S)
                continue
            supervisor.cycle()
            count += 1
            if cycles is not None and count >= cycles:
                break
            wait = supervisor.not_before - world.time()
            if wait > cadence:
                supervisor.log(decision="sleep", seconds=round(wait, 3))
            if wait > 0:
                world.sleep(wait)
    finally:
        os.close(lock)
    return 0


def teardown_cli(root):
    path = Path(root) / "state" / "stages.json"
    try:
        stages = json.loads(path.read_text())
    except (OSError, ValueError):
        stages = []
    result = teardown(stages, InstallationActor(root))
    sys.stdout.write(json.dumps(result) + "\n")
    return 0 if result.get("action") == "done" else 2


def hold_supervisor(root):
    """Hold supervisor.lock until SIGTERM. Used so a restart can see a dead supervisor."""
    path = Path(root) / "state"
    path.mkdir(parents=True, exist_ok=True)
    fd = os.open(path / "supervisor.lock", os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    (path / "supervisor.pid").write_text(str(os.getpid()) + "\n")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(30)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write(
            "usage: c11-pr-swift-poller.py child|recover|supervise|teardown|render-plist|hold-supervisor ...\n"
            "Does not bootstrap launchd. See docs/c11-pr-swift-poller.md.\n"
        )
        return 0
    command = argv[1]
    if command == "render-plist":
        home = argv[argv.index("--home") + 1]
        sys.stdout.write(render_plist(home))
        return 0
    root = argv[argv.index("--root") + 1]
    if command == "recover":
        outcome = recover(root)
        sys.stdout.write(outcome + "\n")
        return 0 if outcome == "ready" else 2
    if command == "hold-supervisor":
        hold_supervisor(root)
        return 0
    if command == "child":
        if "--exec" not in argv:
            sys.stderr.write("child requires --exec in this build; supervise supplies xcodebuild\n")
            return 2
        exec_argv = argv[argv.index("--exec") + 1:]
        return run_child_cli(root, exec_argv)
    if command == "supervise":
        cycles = int(argv[argv.index("--cycles") + 1]) if "--cycles" in argv else None
        return supervise_cli(root, cycles)
    if command == "teardown":
        return teardown_cli(root)
    sys.stderr.write("unknown command\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as error:
        sys.stderr.write("poller: %s\n" % error)
        sys.exit(1)
