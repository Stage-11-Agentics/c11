#!/usr/bin/env python3
"""Advisory Atlas poller for same-repo c11 pull requests.

Phase 2 of C11-371. This process is not a GitHub Actions runner. Nothing in
this file bootstraps a LaunchAgent. Arming waits for an implementation review
PASS and for Atin to create the GitHub App.

R2 amendment (orchestrator, comment on C11-371): a free running.lock is not
proof that the build is gone. Recovery, and the check before every start,
also probe the recorded process group with killpg(pgid, 0) and do not clear
running.json or admit a build until that group is ESRCH.
"""

from __future__ import annotations

import base64
import fcntl
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
KNOWN_STAGES = frozenset(("plist_installed", "app_installed", "key_placed"))
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
    raw = None if headers is None else headers.get("X-RateLimit-Reset")
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
    """
    headers = headers or {}
    retry = parse_retry_after(headers.get("Retry-After"), now)
    reset = reset_wait(headers, now)
    if status in (403, 429):
        waits = [item for item in (retry, reset) if item is not None]
        if not waits:
            return None
        return max(waits)
    if status == 0:
        return None
    remaining = headers.get("X-RateLimit-Remaining")
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
    assert_git_args(args)
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
        XCODEBUILD,
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
    """True when the recorded group still has a member.

    killpg(pgid, 0) is the probe. On macOS it can return ESRCH for an
    orphaned group that ps still lists, so a process-table hit keeps the
    group alive. A free lock is never enough on its own.
    """
    if type(pgid) is not int or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return _pgid_listed(pgid)
    except PermissionError:
        return True
    return True


def _pgid_listed(pgid):
    listed = subprocess.run(["ps", "-axo", "pgid="], capture_output=True, text=True)
    if listed.returncode != 0:
        return False
    wanted = str(pgid)
    return any(line.strip() == wanted for line in listed.stdout.splitlines())


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
    kill = kill or (lambda pgid, sig: os.killpg(pgid, sig))
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
        nxt = link_next((response.get("headers") or {}).get("Link"))
        if not nxt:
            return pages, False
        url = nxt
    last = pages[-1]
    truncated = link_next((last.get("headers") or {}).get("Link")) is not None
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


class AppClient:
    """GitHub App client. Scope inventory is un-narrowed; status uses a narrowed token.

    A 401 mints once and retries once. There is no fallback to gh, GITHUB_TOKEN,
    netrc, or the gh config. GET /app/installations/{id} is not called.
    """

    def __init__(self, app_id, installation_id, key_path, transport, now=None, sign=None):
        self.app_id = app_id
        self.installation_id = installation_id
        self.key_path = Path(key_path)
        self.transport = transport
        self.now = now or time.time
        self.sign = sign or openssl_sign
        self.scoped = False
        self.refreshed = False
        self.mints = []
        self.unscoped_token = None
        self.narrowed_token = None

    @classmethod
    def from_config(cls, config_dir=None, transport=None):
        directory = Path(config_dir) if config_dir else Path.home() / ".config" / "c11-pr-swift"
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
        return cls(app["app_id"], app["installation_id"], key_path, transport or urllib_transport)

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
        if response.get("status") != 401:
            return response
        if self.refreshed or remint is None:
            return response
        self.refreshed = True
        fresh = remint()
        headers = dict(headers)
        headers["Authorization"] = "Bearer " + fresh
        return self._send(method, url, headers, body)

    def _send(self, method, url, headers, body):
        if "/app/installations/" in url and not url.endswith("/access_tokens"):
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
    """One poll cycle. Launchd is what keeps a single process; the flock is the second lock."""

    def __init__(self, root, world):
        self.root = Path(root)
        self.world = world
        self.not_before = 0
        self.disarmed = False
        self.scoped = False
        self.queue = []
        self.spawns = []
        self.fetches = []
        self.posts = []
        self.attempt_clock = None

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
        with (self.state() / "decisions.jsonl").open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

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
        lock = self.hold_supervisor_lock()
        if lock is None:
            self.log(decision="supervisor-busy")
            return "busy"
        try:
            return self._poll_locked()
        finally:
            os.close(lock)

    def _poll_locked(self):
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
            if not self.world.scope_ok():
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
            self.not_before = self.world.time() + CADENCE_S
            self.log(decision="timeout")
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
            self.not_before = self.world.time() + (wait if wait > 0 else CADENCE_S)
            self.log(decision="rate-or-error", status=status, seconds=wait)
            return "no-build"
        else:
            pages, truncated = self._pages_from(response)
            if any(page.get("status") in (403, 429, 0) for page in pages):
                self.log(decision="rate-or-error", status=status)
                return "no-build"
            body = []
            for page in pages:
                chunk = page.get("body")
                if type(chunk) is not list:
                    clear_list_store(store)
                    self.log(decision="malformed-list")
                    return "no-build"
                body.extend(chunk)
            etag = headers.get("ETag")
            if etag:
                save_list_store(store, etag, body)
            if truncated:
                self.log(decision="pr_list_truncated")
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
        self.not_before = self.world.time() + (wait or CADENCE_S)
        return self.maybe_start()

    def _list_headers(self):
        saved = load_list_store(self.state() / "list.json")
        headers = {"Accept": "application/vnd.github+json", "User-Agent": USER_AGENT}
        if saved is not None:
            headers["If-None-Match"] = saved["etag"]
        return headers

    def _pages_from(self, first):
        pages = [first]
        url = link_next((first.get("headers") or {}).get("Link"))
        while url and len(pages) < MAX_PAGES:
            page = self.world.list_page_url(url)
            pages.append(page)
            if page.get("status") != 200:
                break
            url = link_next((page.get("headers") or {}).get("Link"))
        else:
            url = None
        truncated = False
        if len(pages) == MAX_PAGES:
            truncated = link_next((pages[-1].get("headers") or {}).get("Link")) is not None
        return pages, truncated

    def _remember_queue(self, admitted):
        known = {item["pr"] for item in self.queue}
        for captured in admitted:
            if captured["pr"] not in known:
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
            looked = self.world.pull(item["pr"])
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
        item = self.queue[0]
        ok, reason, _detail = revalidate(
            item,
            lambda number: self.world.pull(number),
            lambda ref: self.world.ls_remote(ref),
        )
        if not ok:
            # The captured SHA stays what the list admitted. A moved tip is not
            # written into this attempt and is not fetched.
            self.log(decision=reason, pr=item["pr"], sha=item["sha"])
            self.queue.pop(0)
            return reason
        if not self._fetch(item):
            return "fetch_failed"
        if not self._prepare_tree(item):
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

    def _prepare_tree(self, item):
        if not clean_worktree(self.world.git, self.world.worktree):
            self.log(decision="residue", pr=item["pr"])
            return False
        parent = porcelain_paths(self.world.status(self.world.worktree))
        sub_status = [porcelain_paths(self.world.status(Path(self.world.worktree) / path)) for path, _url in GITLINKS]
        linked = self.world.ghosttykit(item["sha"])
        if linked == "ghosttykit_missing":
            self.log(decision="ghosttykit_missing", pr=item["pr"])
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
        invocation = 1
        self.attempt_clock = self.world.time()
        started = self._spawn_one(item, invocation)
        if started != "ran":
            return started
        if self.world.last_exit == 0 and self._within_budget():
            return "started"
        if invocation == 1 and self.world.last_exit != 0:
            invocation = 2
            self._spawn_one(item, invocation)
        return "started"

    def _spawn_one(self, item, invocation):
        attempt_id = item.get("attempt_id") or uuid.uuid4().hex
        item["attempt_id"] = attempt_id
        result = result_directory(self.state(), attempt_id, invocation)
        current = {
            "attempt_id": attempt_id,
            "invocation": invocation,
            "pr": item["pr"],
            "sha": item["sha"],
            "ref": item["ref"],
            "result": str(result),
        }
        (self.state() / "current.json").write_text(json.dumps(current) + "\n")
        argv = self.world.build_argv(self.world.worktree, self.root / "cache" / "DerivedData", result)
        command = slot_command(self.root, argv)
        self.spawns.append({"command": command, "sha": item["sha"], "result": str(result), "invocation": invocation})
        append_event(self.root, {"event": "spawn", "sha": item["sha"], "invocation": invocation, "result": str(result)})
        exit_code = self.world.spawn(command)
        self._finish(item, exit_code)
        return "ran"

    def _within_budget(self):
        return (self.world.time() - self.attempt_clock) <= BUDGET_S

    def _finish(self, item, exit_code):
        self.world.last_exit = exit_code
        seconds = self.world.time() - (self.attempt_clock or self.world.time())
        state, description = classify_result(self.world.build_log, seconds)
        if exit_code != 0 and state == "success":
            state, description = "failure", "failed %ss" % int(seconds)
        self._post(item["sha"], state, description)

    def _post(self, sha, state, description):
        body = status_body(sha, state, description)
        body["sha"] = sha
        self.posts.append(body)
        self.world.post_status(body)
        self.log(decision="result", sha=sha, state=state, description=description)

    def watch(self, record):
        """Every 5s while a build runs. Kill our group and post error on yield."""
        guests = self.world.guests()
        our = record.get("slot")
        other = None
        if our in (1, 2):
            other = 1 if our == 2 else 2
        other_held = False if other is None else self.world.slot_held(other)
        reason = yield_reason(guests, our, other_held)
        if reason is None:
            return None
        pgid = record.get("pgid")
        if type(pgid) is int and pgid > 1:
            try:
                self.world.killpg(pgid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self._post(record.get("sha") or "", "error", "yielded to Atlas work")
        self.log(decision="yielded", reason=reason, pr=record.get("pr"))
        return reason

    def watch_while(self, running, record):
        """Every 5s while running() is true. Returns the yield reason, or None.

        `supervise` does not enter this loop. It stays disarmed until arming
        is authorized. An armed supervisor passes a running() that is true
        while its slot process is still alive.
        """
        while running():
            reason = self.watch(record)
            if reason is not None:
                return reason
            self.world.sleep(YIELD_INTERVAL_S)
        return None


def _remaining(headers):
    try:
        return int(headers.get("X-RateLimit-Remaining"))
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
    actor.remove_local_state()
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


def _revalidate_with_client(root, client):
    current = json.loads((Path(root) / "state" / "current.json").read_text())

    def fetch_pr(number):
        response = client.pull(number)
        if response.get("status") != 200:
            return None
        return response.get("body")

    def ls_remote(ref):
        result = run_git(["ls-remote", PARENT_URL, "refs/heads/%s" % ref], root)
        if result.returncode != 0:
            raise ScopeStop("ls-remote")
        return result.stdout

    return revalidate(current, fetch_pr, ls_remote)


def post_build_pending(client, current):
    """Pending status after the second revalidation, immediately before exec."""
    body = status_body(current["sha"], "pending", "build started")
    body["sha"] = current["sha"]
    return client.post_status_body(body)


def child_revalidate_from_root(root):
    current = json.loads((Path(root) / "state" / "current.json").read_text())
    if os.environ.get("C11_POLLER_TEST") == "1":
        harness = json.loads((Path(root) / "harness.json").read_text())
        return revalidate(current, lambda _number: harness["pr"], lambda _ref: harness["ls_remote"])
    client = AppClient.from_config()
    client.verify_scope()
    return _revalidate_with_client(root, client)


def run_child_cli(root, exec_argv):
    holder = {}

    def revalidate_fn(root):
        if os.environ.get("C11_POLLER_TEST") == "1":
            return child_revalidate_from_root(root)
        client = AppClient.from_config()
        client.verify_scope()
        holder["client"] = client
        return _revalidate_with_client(root, client)

    def post_pending(current):
        if os.environ.get("C11_POLLER_TEST") == "1":
            append_event(root, {"event": "pending", "sha": current["sha"]})
            return True
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
            "usage: c11-pr-swift-poller.py child|recover|supervise|render-plist|hold-supervisor ...\n"
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
        sys.stderr.write("supervise is not armed; launchd bootstrap is not authorized\n")
        return 2
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
