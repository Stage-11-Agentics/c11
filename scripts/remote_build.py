#!/usr/bin/env python3
"""SSH transport for a self-contained worktree snapshot and existing c11 build scripts."""
import argparse
import contextlib
from datetime import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

SUBMODULES = ("ghostty", "vendor/bonsplit")
# The build host's working folder, under its home: mirrors, per-tag checkouts, artifacts, gates.jsonl.
BUILD_DIR = "c11-builds"
# Host mirror name -> checkout path; the host keeps one bare mirror per repository.
REPOS = {"parent": "", "ghostty": "ghostty", "vendor-bonsplit": "vendor/bonsplit"}
EXCLUDED = (".git", ".lattice", ".etch", "DerivedData", "build", "build-*",
            "GhosttyKit.xcframework", "ghostty/zig-out", "ghostty/.zig-cache",
            "c11d/zig-out", "c11d/.zig-cache", "web/node_modules")
# The build host's free-space floor for a new tag lives in atlas_build_slots.py (--tag-floor).
# This variable replaces the floor for one deliberate build; every use is logged.
FLOOR_OVERRIDE_ENV = "C11_BUILD_HOST_FLOOR_GIB"
TAG_FLOOR_REFUSED = 73


class ToolchainError(ValueError):
    """Missing, unusable or unsupported native build tools (exit 3)."""


def run(args, cwd=None, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=cwd, check=True, **kwargs)


def git(root, *args):
    return run(["git", "-C", root, *args], stdout=subprocess.PIPE).stdout.decode().strip()


def c11_user_runtime_dir():
    """c11's per-user folder, resolved as scripts/lib/c11-user-paths.sh does: C11_DEV_RUNTIME_DIR
    when set (tests' own roots), else DARWIN_USER_TEMP_DIR plus c11. Never $TMPDIR."""
    override = os.environ.get("C11_DEV_RUNTIME_DIR")
    if override:
        return Path(override.rstrip("/") or "/")
    try:
        temp = os.confstr(65537)  # _CS_DARWIN_USER_TEMP_DIR, what `getconf DARWIN_USER_TEMP_DIR` prints
    except (ValueError, OSError):
        temp = None
    if not temp or not temp.startswith("/"):
        temp = str(Path.home() / "Library/Caches")
    return Path(temp.rstrip("/")) / "c11"


def ensure_private_dir(path):
    """Creates `path` 0700, or verifies it is a real folder this user owns and sets it 0700."""
    if not os.path.lexists(path):
        previous = os.umask(0o077)
        try:
            Path(path).mkdir(mode=0o700, parents=True, exist_ok=True)
        finally:
            os.umask(previous)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise PermissionError(f"{path} is not a folder this user owns")
        if stat.S_IMODE(info.st_mode) != 0o700:
            os.fchmod(descriptor, 0o700)
    finally:
        os.close(descriptor)


def write_private_line(path, value, uid):
    """Writes one line 0600 as c11_private_write does: an entry another uid owns, or a folder,
    is refused; anything else at `path` (a link included) is replaced by the rename, never
    written through. Returns whether it wrote."""
    path = Path(path)
    try:
        info = os.lstat(path)
        if info.st_uid != uid or stat.S_ISDIR(info.st_mode):
            return False
    except FileNotFoundError:
        pass
    except OSError:
        return False
    try:
        descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".c11-write.")
    except OSError:
        return False
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(value + "\n")
        os.replace(temporary, path)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        return False
    return True


def publish_cli_pointer(cli_path, runtime_dir=None, legacy=Path("/tmp/c11-last-cli-path"), uid=None):
    """Points the dev shim (`c11-dev`) at a just-installed CLI, as reload.sh does: the per-user
    pointer first, then the old /tmp one its older readers use (C11H-364 L21). `uid` is the
    owner an existing pointer must have (tests inject another). A refusal skips that copy."""
    owner = os.getuid() if uid is None else uid
    folder = Path(runtime_dir) if runtime_dir is not None else c11_user_runtime_dir()
    written = []
    try:
        ensure_private_dir(folder)
    except OSError:
        folder = None
    for path in ([folder / "c11-last-cli-path"] if folder is not None else []) + [Path(legacy)]:
        if write_private_line(path, str(cli_path), owner):
            written.append(path)
    return written


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def excluded(name):
    import fnmatch
    return any(fnmatch.fnmatch(name.split("/")[0], p) or name == p or
               name.startswith(p + "/") for p in EXCLUDED)


def safe_path(root, name):
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or not p.parts or ".git" in p.parts:
        raise ValueError(f"unsafe overlay path: {name!r}")
    dest = root / name
    if not dest.parent.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"overlay parent escapes source: {name!r}")
    return dest


def entry(root, name):
    path = safe_path(root, name)
    if path.is_symlink():
        return {"path": name, "kind": "symlink", "target": os.readlink(path)}
    if not path.exists():
        return {"path": name, "kind": "deleted"}
    if not path.is_file():
        raise ValueError(f"unsupported overlay type: {name!r}")
    return {"path": name, "kind": "file", "sha256": digest(path),
            "mode": path.stat().st_mode & 0o777}


# c11LogicTests sets TEST_HOST empty. c11Tests points TEST_HOST at the app
# binary. c11UITests is a UI-test bundle (TEST_TARGET_NAME = c11). Any other
# target selects scheme c11-unit, which includes c11Tests and launches the app.
LOGIC_TEST_TARGET = "c11LogicTests"
HOST_APP_TEST_TARGETS = frozenset({"c11Tests", "c11UITests"})


def only_testing_selectors(extra):
    return [arg.split(":", 1)[1] for arg in extra if arg.startswith("-only-testing:")]


def apply_host_test_policy(args):
    """--mode test runs c11LogicTests only. A host-app selector is refused before shipping."""
    if getattr(args, "mode", None) != "test":
        return
    selectors = only_testing_selectors(args.extra)
    refused = [selector for selector in selectors if selector.split("/", 1)[0] != LOGIC_TEST_TARGET]
    if refused:
        listed = ", ".join("-only-testing:" + selector for selector in refused)
        hosts = ", ".join(sorted(HOST_APP_TEST_TARGETS))
        raise ValueError(
            f"--mode test refuses {listed}: a host-app selector launches the app on the host. "
            f"Only {LOGIC_TEST_TARGET} runs through this route ({hosts} need the app). "
            "Guests have no Xcode, so host classes are compile-only on hosts "
            "(--mode test-build compiles them and runs nothing). "
            "Prove host behavior in a sandbox guest: scripts/sandbox-up.sh, then scripts/sandbox-tests-v2.sh."
        )
    if not selectors:
        args.extra = ["-only-testing:" + LOGIC_TEST_TARGET, *list(args.extra)]


def snapshot(root, payload, args, held=None):
    apply_host_test_policy(args)
    held = held or {}
    head = git(root, "rev-parse", "HEAD")
    modules = {}
    for name in SUBMODULES:
        pinned = git(root, "ls-tree", "HEAD", name).split()[2]
        actual = git(root / name, "rev-parse", "HEAD")
        if pinned != actual or git(root / name, "status", "--porcelain", "--untracked-files=normal"):
            raise ValueError(f"{name} must be provisioned, clean and at pinned SHA {pinned}")
        modules[name] = pinned
    # Union staged and unstaged changes; diff against HEAD includes tracked deletes/renames.
    raw = run(["git", "-C", root, "diff", "--name-only", "--no-renames", "-z", "HEAD"],
              stdout=subprocess.PIPE).stdout
    raw += run(["git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z"],
               stdout=subprocess.PIPE).stdout
    names = sorted(set(os.fsdecode(n) for n in raw.split(b"\0") if n))
    overlays = []
    overlay_dir = payload / "overlay"
    overlay_dir.mkdir()
    for name in names:
        if excluded(name):
            continue
        if name in SUBMODULES or any(name.startswith(s + "/") for s in SUBMODULES):
            raise ValueError("dirty submodule/gitlink is not a permitted overlay")
        item = entry(root, name)
        overlays.append(item)
        src = safe_path(root, name)
        dst = safe_path(overlay_dir, name)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if item["kind"] == "file":
            shutil.copy2(src, dst)
        elif item["kind"] == "symlink":
            dst.symlink_to(item["target"])
        if entry(root, name) != item:
            raise ValueError(f"source changed during snapshot: {name!r}")
    bundles = {}
    for repo, path in REPOS.items():
        kind = bundle(root / path, payload / (repo + ".bundle"), held.get(repo, []))
        if kind:
            bundles[repo] = kind
    test_scheme = selected_test_scheme(args.extra)
    selectors = only_testing_selectors(args.extra)
    selected_test_targets = {selector.split("/", 1)[0] for selector in selectors}
    host_quarantine = []
    if args.mode == "test" and not args.no_host_quarantine:
        host_quarantine = [
            item for item in read_host_test_quarantine(root)
            if not selectors or item["test_id"].split("/", 1)[0] in selected_test_targets
        ]
    test_args = list(args.extra)
    existing_skips = {
        arg.split(":", 1)[1] for arg in test_args if arg.startswith("-skip-testing:")
    }
    for item in host_quarantine:
        item["explicitly_selected"] = item["test_id"] in selectors
        item["already_skipped"] = item["test_id"] in existing_skips
        item["auto_skipped"] = not item["explicitly_selected"] and not item["already_skipped"]
    test_args.extend(
        "-skip-testing:" + item["test_id"] for item in host_quarantine
        if item["auto_skipped"]
    )
    manifest = {"invocation": uuid.uuid4().hex, "head": head, "bundles": bundles,
                "branch": git(root, "branch", "--show-current"), "submodules": modules,
                "overlay": overlays, "dirty": bool(overlays), "tag": args.tag,
                "slug": slug(args.tag), "mode": args.mode, "extra": args.extra,
                "test_args": test_args, "test_scheme": test_scheme,
                "host_test_quarantine": host_quarantine,
                "release_options": [f"--{k}" for k in ("clean", "wmo", "universal") if getattr(args, k)],
                "developer_dir": os.environ.get("C11_REMOTE_DEVELOPER_DIR", "/Applications/Xcode-26.3.app/Contents/Developer"),
                "zig_dir": os.environ.get("C11_REMOTE_ZIG_DIR", "")}
    (payload / "identity.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def slug(tag):
    return re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")


def read_host_test_quarantine(root):
    """Load the shared parser from disk only when the client snapshots host tests."""
    helper_path = Path(__file__).resolve().parent / "host_test_quarantine.py"
    spec = importlib.util.spec_from_file_location("c11_host_test_quarantine", helper_path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load quarantine parser: {helper_path}")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper.read_host_test_quarantine(Path(root) / "scripts" / "host-test-quarantine.tsv")


def selected_test_scheme(extra):
    selectors = only_testing_selectors(extra)
    if selectors and all(selector.startswith(LOGIC_TEST_TARGET) for selector in selectors):
        return "c11-logic"
    return "c11-unit"


def bundle(repo, path, held):
    """Bundle HEAD minus everything reachable from heads the host already holds.

    Returns "full", "incremental", or None when the host already has HEAD."""
    shas = [s for s in held if re.fullmatch(r"[0-9a-f]{40}", s)]
    known = []
    if shas:
        # Only commits this clone has can bound the bundle; the rest are unknown here.
        check = run(["git", "-C", repo, "cat-file", "--batch-check=%(objecttype)"],
                    input="".join(s + "\n" for s in shas).encode(), stdout=subprocess.PIPE)
        known = [s for s, kind in zip(shas, check.stdout.decode().splitlines()) if kind == "commit"]
    revs = "".join(["HEAD\n", *("^" + s + "\n" for s in known)]).encode()
    missing = run(["git", "-C", repo, "rev-list", "--count", "--stdin"], input=revs, stdout=subprocess.PIPE)
    if int(missing.stdout) == 0:
        return None
    # Prerequisites are commits the host mirror holds; its fetch refuses the bundle otherwise.
    run(["git", "-c", "pack.threads=2", "-C", repo, "bundle", "create", "--quiet", path, "--stdin"], input=revs)
    return "incremental" if known else "full"


@contextlib.contextmanager
def mirror_lock(repo):
    """Hold the host's lock for one repository mirror; the kernel drops it if the process dies."""
    mirrors = Path.home() / BUILD_DIR / "mirrors"
    mirrors.mkdir(parents=True, exist_ok=True)
    with (mirrors / (repo + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield mirrors / (repo + ".git")


def ready_mirror(mirror, subpath):
    """Make the mirror a usable bare repository. Caller holds its lock.

    An interrupted first use can leave a directory that is not a repository; it is
    rebuilt. A new mirror adopts the heads of the host's existing per-tag checkouts,
    so moving onto mirrors does not re-upload history the host already has."""
    check = subprocess.run(["git", "--git-dir", str(mirror), "rev-parse", "--is-bare-repository"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if check.returncode == 0 and check.stdout.strip() == b"true":
        return
    staging = mirror.with_name(mirror.name + ".init")
    shutil.rmtree(staging, ignore_errors=True)
    run(["git", "init", "--quiet", "--bare", staging])
    for checkout in sorted((Path.home() / BUILD_DIR).glob("*/source")):
        repo = checkout / subpath
        head = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "HEAD"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode().strip()
        if (repo / ".git").exists() and head:
            # Best effort: a checkout that cannot be read only means less is adopted.
            subprocess.run(["git", "--git-dir", str(staging), "fetch", "--quiet", "--no-recurse-submodules",
                            str(repo), "+HEAD:refs/c11/" + head], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(mirror, ignore_errors=True)
    staging.rename(mirror)


def host_held_heads():
    """Host side of held_heads: every head each mirror holds, by repository."""
    held = {}
    for repo, subpath in REPOS.items():
        with mirror_lock(repo) as mirror:
            ready_mirror(mirror, subpath)
            refs = run(["git", "--git-dir", mirror, "for-each-ref", "--format=%(objectname)", "refs/c11/"],
                       stdout=subprocess.PIPE)
        held[repo] = refs.stdout.decode().split()
    return held


class Transport:
    """Reaches the build host: over ssh, or in place when --host is "local".

    The local form runs the same command strings from $HOME, the directory an ssh
    session starts in, and maps host:path to $HOME/path. A release driven on the
    build host itself (with its signing keychain) needs no ssh hop and no
    authorized_keys entry, and still enters remote() and its admission slots."""

    def __init__(self, host):
        self.host = host
        self.local = host == "local"

    def command(self, command):
        if self.local:
            return ["/bin/bash", "-c", command]
        return ["ssh", "-o", "BatchMode=yes", self.host, command]

    def cwd(self):
        return str(Path.home()) if self.local else None

    def location(self, relative):
        if not self.local:
            return self.host + ":" + relative
        # Keep a trailing slash: rsync copies a directory's contents only with one.
        return str(Path.home() / relative) + ("/" if relative.endswith("/") else "")

    def rsync(self, *flags):
        return ["rsync", *flags] if self.local else ["rsync", *flags, "-e", "ssh -o BatchMode=yes"]


def held_heads(transport):
    """Ask the host which commits each repository mirror holds.

    The host runs this script from stdin, so the probe shares mirror_head's locking
    and readiness checks; any host failure fails staging instead of reading as empty."""
    response = run(transport.command(shlex.join(["python3", "-", "--held-heads"])), cwd=transport.cwd(),
                   input=Path(__file__).read_bytes(), stdout=subprocess.PIPE)
    return json.loads(response.stdout)


def floor_override():
    """C11_BUILD_HOST_FLOOR_GIB as GiB, or None when unset; anything but a number >= 0 is refused."""
    raw = os.environ.get(FLOOR_OVERRIDE_ENV, "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        value = -1.0
    if not (value >= 0 and value != float("inf")):
        raise ValueError(f"{FLOOR_OVERRIDE_ENV} takes a number of GiB, 0 or more (got {raw!r})")
    return value


def log_floor_override(root, tag, floor):
    """Print and append one line per override, as the shareable override does; unlogged, it does not proceed."""
    path = Path.home() / ".local/state/c11/build-host-floor-overrides.log"
    try:
        head = git(root, "rev-parse", "--short", "HEAD")
    except (OSError, subprocess.CalledProcessError):
        head = "unknown"
    line = (f"{datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')} context=remote-build "
            f"tag={tag} head={head} floor_gib={floor:.10g}")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as log:
            log.write(line + "\n")
    except OSError as error:
        raise OSError(f"{FLOOR_OVERRIDE_ENV} override not logged ({error}), so it does not proceed") from error
    print(f"[remote-build] build-host floor overridden to {floor:.10g} GiB for tag {tag} (logged to {path})",
          file=sys.stderr, flush=True)


def start_tag_floor(transport, root, tag_slug, floor):
    """Start the host's new-tag floor check: the requester's own atlas_build_slots.py, run from stdin.
    Returns None when it can't start; the build then goes ahead without it."""
    command = ["python3", "-", "--tag-floor", tag_slug]
    if floor is not None:
        command += ["--floor-gib", f"{floor:.10g}"]
    try:
        with (root / "scripts" / "atlas_build_slots.py").open("rb") as script:
            return subprocess.Popen(transport.command(shlex.join(command)), cwd=transport.cwd(), stdin=script,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        print(f"[remote-build] could not start the build host's floor check: {error}", file=sys.stderr)
        return None


def finish_tag_floor(probe):
    """Wait for the floor check and pass its text through; returns its exit code (0 when it never started)."""
    if probe is None:
        return 0
    out, err = probe.communicate()
    sys.stdout.write(out.decode(errors="replace"))
    sys.stdout.flush()
    sys.stderr.write(err.decode(errors="replace"))
    sys.stderr.flush()
    return probe.returncode


def mirror_head(payload, manifest, repo, sha):
    """Publish one exact commit in the host's shared mirror; return the mirror and ref."""
    ref = "refs/c11/" + sha
    # Initialization, publication and verification are serialized per mirror, so two
    # tags staging one new head never contend for its ref lock inside Git.
    with mirror_lock(repo) as mirror:
        ready_mirror(mirror, REPOS[repo])
        if repo in manifest["bundles"]:
            # Fetch verifies the bundle's prerequisite commits are already in the mirror.
            command = ["git", "--git-dir", mirror, "fetch", "--quiet", "--no-recurse-submodules",
                       payload / (repo + ".bundle"), "+HEAD:" + ref]
        else:
            command = ["git", "--git-dir", mirror, "update-ref", ref, sha + "^{commit}"]
        attempt = subprocess.run([str(a) for a in command], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        held = subprocess.run(["git", "--git-dir", str(mirror), "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
                              stdout=subprocess.PIPE).stdout.decode().strip()
    if attempt.returncode or held != sha:
        raise ValueError(f"host mirror {repo} lacks {sha}: {attempt.stderr.decode().strip()}")
    return mirror, ref


def apply_overlay(root, payload, manifest):
    for item in manifest["overlay"]:
        dst = safe_path(root, item["path"])
        src = safe_path(payload / "overlay", item["path"])
        if dst.is_symlink() or dst.is_file():
            dst.unlink()
        elif dst.exists():
            raise ValueError("overlay cannot replace a directory")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if item["kind"] == "file":
            shutil.copy2(src, dst)
            dst.chmod(item["mode"])
        elif item["kind"] == "symlink":
            dst.symlink_to(item["target"])
        elif item["kind"] != "deleted":
            raise ValueError("unsupported overlay kind")
        if entry(root, item["path"]) != item:
            raise ValueError(f"overlay identity mismatch: {item['path']!r}")


def observe_test_phase(process, log_path):
    """Measure the XCTest phase from its live start/end markers in the build log."""
    started = None
    finished = None
    position = 0
    pending = ""
    start_markers = ("Test Suite 'All tests' started at", "Testing started")
    end_markers = (
        "Test Suite 'All tests' passed at",
        "Test Suite 'All tests' failed at",
        "** TEST SUCCEEDED **",
        "** TEST FAILED **",
    )
    with log_path.open("r", encoding="utf-8", errors="replace") as log:
        while process.poll() is None:
            log.seek(position)
            chunk = pending + log.read()
            position = log.tell()
            lines = chunk.splitlines(keepends=True)
            pending = lines.pop() if lines and not lines[-1].endswith(("\n", "\r")) else ""
            observed_at = time.monotonic()
            for line in lines:
                if started is None and any(marker in line for marker in start_markers):
                    started = observed_at
                if started is not None and any(marker in line for marker in end_markers):
                    finished = observed_at
            time.sleep(0.05)
        log.seek(position)
        chunk = pending + log.read()
        observed_at = time.monotonic()
        for line in chunk.splitlines():
            if started is None and any(marker in line for marker in start_markers):
                started = observed_at
            if started is not None and any(marker in line for marker in end_markers):
                finished = observed_at
    if started is None:
        return 0.0
    return max(0.0, (finished or time.monotonic()) - started)


def require_test_success(build_log, source, env):
    """Require a passing XCTest result with at least one executed test."""
    bundles = re.findall(r"(?m)^[ \t]+(.+?\.xcresult)[ \t]*$", build_log)
    if bundles:
        bundle = Path(bundles[-1]).expanduser()
        if not bundle.is_absolute():
            bundle = source / bundle
        try:
            summary = run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                           "--path", bundle, "--compact"], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            report = json.loads(summary.stdout)
            if not isinstance(report, dict):
                raise ValueError("xcresult summary is not a JSON object")
            total = int(report.get("totalTestCount", 0))
            skipped = int(report.get("skippedTests", 0))
            failed = int(report.get("failedTests", 0))
        except (OSError, subprocess.CalledProcessError, ValueError, TypeError) as error:
            raise ValueError(f"could not read XCTest result bundle {bundle}: {error}") from error
        executed = total - skipped
        if executed <= 0:
            raise ValueError(f"test action executed zero tests according to {bundle}")
        if report.get("result") != "Passed" or failed:
            raise ValueError(
                f"test action xcresult was {report.get('result')!r} "
                f"(executed {executed}, failed {failed})"
            )
        return

    # Older xcodebuild versions may omit the result-bundle path from stdout.
    # Keep their explicit summary support, including the zero-test guard.
    executed = re.search(r"Executed ([0-9]+) tests?\b", build_log)
    if "** TEST SUCCEEDED **" in build_log and executed and int(executed.group(1)) > 0:
        return
    raise ValueError("test action did not report a passing xcresult or nonzero test summary")


def append_gate_record(manifest, result, *, started):
    """Append one serialized owner-gate measurement on the build host."""
    record = {
        "tag": manifest["tag"],
        "mode": manifest["mode"],
        "head": manifest["head"],
        "slot_wait_seconds": result.get("slot_wait_seconds", 0.0),
        "build_seconds": result.get("build_seconds", 0.0),
        "test_seconds": result.get("test_seconds", 0.0),
        "result": "success" if result.get("ok") else "failure",
        "invocation_id": manifest["invocation"],
        "started": started,
        "test_args": manifest["test_args"],
    }
    path = Path.home() / BUILD_DIR / "gates.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as gates:
        fcntl.flock(gates.fileno(), fcntl.LOCK_EX)
        gates.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        gates.flush()


def remote(payload, locked=False):
    invocation_started = time.monotonic()
    invocation_started_at = datetime.now().astimezone().isoformat()
    manifest = json.loads((payload / "identity.json").read_text())
    # Xcode tracks output paths textually. After a build-cache directory moves
    # behind a symlink, mixing aliases can delete freshly produced libraries as
    # stale outputs. Use one physical spelling for source, products and logs.
    base = (Path.home() / BUILD_DIR / manifest["slug"]).resolve()
    artifacts = base / "artifacts" / manifest["invocation"]
    artifacts.mkdir(parents=True, exist_ok=True)
    if not locked:
        # Load and same-tag admission enclose source preparation, native builds, and snapshot.
        runner = Path(__file__).resolve()
        slot_record_path = artifacts / "slot.json"
        slot_env = os.environ.copy()
        slot_env["C11_ATLAS_SLOT_RECORD_PATH"] = str(slot_record_path)
        try:
            code = subprocess.call([sys.executable, payload / "atlas_build_slots.py", manifest["slug"],
                                    payload / "with-build-lock.sh", sys.executable,
                                    runner, "--remote-locked", payload], env=slot_env)
        except OSError as error:
            code = 4
            print(f"[remote-build] could not start build-host admission: {error}", file=sys.stderr)
        try:
            result = json.loads((artifacts / "result.json").read_text())
        except (OSError, ValueError):
            # Admission failures happen before the locked child can write result.json.
            try:
                slot_wait = json.loads(slot_record_path.read_text())["slot_wait_seconds"]
            except (OSError, ValueError, KeyError):
                slot_wait = time.monotonic() - invocation_started
            result = {
                "slot_wait_seconds": round(max(0.0, slot_wait), 3),
                "build_seconds": 0.0,
                "test_seconds": 0.0,
                "ok": False,
            }
        try:
            slot_record_path.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            append_gate_record(manifest, result, started=invocation_started_at)
        except OSError as error:
            # Measurement must never change the app or test result.
            print(f"[remote-build] could not append gate record: {error}", file=sys.stderr)
        return code
    try:
        slot_wait = max(0.0, float(os.environ.get("C11_ATLAS_SLOT_WAIT_SECONDS", "0")))
    except ValueError:
        slot_wait = 0.0
    result = dict(manifest, compile="failed", tests="na" if manifest["mode"] != "test" else "failed",
                  slot_wait_seconds=round(slot_wait, 3), build_seconds=0.0, test_seconds=0.0)
    try:
        # Stable per-tag paths preserve incremental compiler/Zig caches between invocations.
        source = base / "source"
        prior_overlay = base / "last-overlay.json"
        if prior_overlay.exists():
            for item in json.loads(prior_overlay.read_text()):
                path = safe_path(source, item["path"])
                if path.is_file() or path.is_symlink():
                    path.unlink()
        for repo, path in REPOS.items():
            sha = manifest["submodules"].get(path, manifest["head"])
            mirror, ref = mirror_head(payload, manifest, repo, sha)
            checkout = source / path
            if not (checkout / ".git").exists():
                if checkout.exists():
                    shutil.rmtree(checkout)
                run(["git", "init", "--quiet", checkout])
            # Recursive fetch would ask old origins for unrelated historical gitlinks.
            run(["git", "-C", checkout, "fetch", "--no-recurse-submodules", "--quiet", mirror, ref])
            run(["git", "-C", checkout, "reset", "--hard", sha], stdout=subprocess.DEVNULL)
            if not path:
                # Clear old overlays without deleting build caches or required submodule repositories.
                run(["git", "-C", source, "clean", "-fd", "-e", "ghostty", "-e", "vendor/bonsplit"],
                    stdout=subprocess.DEVNULL)
        apply_overlay(source, payload, manifest)
        prior_overlay.write_text(json.dumps(manifest["overlay"]) + "\n")
        if git(source, "rev-parse", "HEAD") != manifest["head"] or any(
                git(source / n, "rev-parse", "HEAD") != h for n, h in manifest["submodules"].items()):
            raise ValueError("remote source identity mismatch")
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = manifest["developer_dir"]
        env["PATH"] = (manifest["zig_dir"] or str(Path.home() / "zig-0.15.2")) + ":/opt/homebrew/bin:/usr/local/bin:" + env["PATH"]
        try:
            result["xcode"] = run(["xcodebuild", "-version"], env=env, stdout=subprocess.PIPE).stdout.decode().strip()
            result["zig"] = run(["zig", "version"], env=env, stdout=subprocess.PIPE).stdout.decode().strip()
        except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
            raise ToolchainError(f"toolchain unavailable: {error}") from error
        if result["xcode"].splitlines()[:1] != ["Xcode 26.3"] or result["zig"] != "0.15.2":
            raise ToolchainError("requires process-scoped Xcode 26.3 and Zig 0.15.2")
        env["C11_BUILD_LOCK_LABEL"] = "remote:" + manifest["slug"]
        mode = manifest["mode"]
        tag = manifest["tag"]
        if mode == "ghosttykit":
            command = [sys.executable, source / "scripts/build-ghosttykit-admitted.py", artifacts]
            app = None
        elif mode in ("test", "test-build"):
            env["C11_TEST_DERIVED_DATA"] = str(base / "derived-test")
            env["C11_TEST_SCHEME"] = manifest.get("test_scheme", "c11-unit")
            if env["C11_TEST_SCHEME"] == "c11-logic":
                env["C11_TEST_PARALLEL_WORKERS"] = "8"
            # Selected tests must execute, not default to the build action.
            # test-build compiles every test target and launches nothing: host
            # tests may not start an app on the host (CLAUDE.md, Testing).
            action = "build-for-testing" if mode == "test-build" else "test"
            command = [source / "scripts/test-unit-local.sh", action, *manifest["test_args"]]
            app = None
        else:
            if mode == "debug":
                derived = Path.home() / "Library/Developer/Xcode/DerivedData" / ("c11-" + manifest["slug"])
                command = [source / "scripts/reload.sh", "--tag", tag, "--no-launch", "--derived-data", derived]
                app = derived / "Build/Products/Debug" / ("c11 DEV " + tag + ".app")
            else:
                derived = base / "derived-release"
                command = [source / "scripts/reloads.sh", "--tag", tag, "--no-launch", "--derived-data", derived,
                           *manifest["release_options"]]
                app = derived / "Build/Products/Release" / ("c11 STAGING " + tag + ".app")
        log_path = artifacts / "build.log"
        with log_path.open("w") as log:
            for item in manifest.get("host_test_quarantine", []):
                if item.get("explicitly_selected"):
                    action = "explicitly selected; quarantine auto-skip omitted"
                    if item.get("already_skipped"):
                        action += "; caller also supplied -skip-testing"
                elif item.get("already_skipped"):
                    action = "already skipped by caller"
                else:
                    action = "skipped"
                log.write("[host-quarantine] %s: %s scope=%s: %s\n" %
                          (action, item["test_id"], item["scope"], item["reason"]))
            log.flush()
            if mode == "test":
                build = subprocess.Popen([str(a) for a in command], cwd=source, env=env,
                                         stdout=log, stderr=subprocess.STDOUT)
                test_seconds = observe_test_phase(build, log_path)
                build.wait()
            else:
                build = subprocess.run([str(a) for a in command], cwd=source, env=env,
                                       stdout=log, stderr=subprocess.STDOUT)
                test_seconds = 0.0
        result["test_seconds"] = round(test_seconds, 3)
        build_log = log_path.read_text()
        if mode == "test" and ("Test Suite " in build_log or "Testing started" in build_log):
            result["compile"] = "ok"
        # Failed assertions still produce diagnostic bundles. Snapshot them before
        # returning the native status or allowing the next request to clean source.
        try:
            for i, argument in enumerate(manifest["extra"]):
                if argument == "-resultBundlePath" and i + 1 < len(manifest["extra"]):
                    bundle = source / manifest["extra"][i + 1]
                    if bundle.is_dir() and bundle.resolve().is_relative_to(source.resolve()):
                        shutil.copytree(bundle, artifacts / "tests.xcresult", symlinks=True)
        except OSError as error:
            if not build.returncode:
                raise
            result["result_bundle_error"] = str(error)
        if build.returncode:
            raise subprocess.CalledProcessError(build.returncode, command)
        if mode == "test":
            require_test_success(build_log, source, env)
            result["tests"] = "ok"
        if mode == "test-build" and "** TEST BUILD SUCCEEDED **" not in build_log:
            raise ValueError("build-for-testing exited 0 without ** TEST BUILD SUCCEEDED **")
        if mode == "ghosttykit":
            if not re.search(r"C11_GHOSTTY_TEST_OK tests=[1-9][0-9]*\b", build_log):
                raise ValueError("Ghostty kit build did not verify native tests")
            result["tests"] = "ok"
            result["kit"] = "GhosttyKit.xcframework.tar.gz"
            result["kit_sha256"] = digest(artifacts / result["kit"])
        if app:
            if not app.is_dir():
                raise ValueError("successful build did not produce the requested app")
            shutil.copytree(app, artifacts / app.name, symlinks=True)
            result["app"] = app.name
            result["executable_sha256"] = digest(artifacts / app.name / "Contents/MacOS/c11")
        result["compile"] = "ok"
        result["ok"] = True
        code = 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        result["ok"] = False
        result["error"] = str(error)
        code = 3 if isinstance(error, ToolchainError) else (
            error.returncode if isinstance(error, subprocess.CalledProcessError) else 4)
        print(f"[remote-build] failure: {error}", file=sys.stderr)
    result["build_seconds"] = round(max(0.0, time.monotonic() - invocation_started - result["test_seconds"]), 3)
    (artifacts / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("C11_REMOTE_RESULT " + json.dumps({"invocation": manifest["invocation"], "artifacts": str(artifacts),
                                          "ok": result["ok"], "compile": result["compile"], "tests": result["tests"]}), flush=True)
    return code


def client(args):
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="c11-remote-source-") as tmp:
        payload = Path(tmp)
        host = args.host
        transport = Transport(host)
        started = time.monotonic()
        floor = getattr(args, "floor_gib", None)
        if floor is not None:
            log_floor_override(root, slug(args.tag), floor)
        # The floor check shares the held-heads round trip and ends before anything is
        # bundled, copied or built for this tag, so a refused new tag leaves no folder on the host.
        # Only the held-heads probe's shared upkeep runs beside it: a missing or broken mirror is
        # initialized, as on every build.
        probe = start_tag_floor(transport, root, slug(args.tag), floor)
        refused = (f"[remote-build] refused: the build host is under its free-space floor for new tag "
                   f"{args.tag}; nothing was copied for this tag")
        try:
            held = held_heads(transport)
        except Exception:
            if finish_tag_floor(probe) == TAG_FLOOR_REFUSED:
                print(refused, file=sys.stderr)
                return TAG_FLOOR_REFUSED
            raise
        floor_code = finish_tag_floor(probe)
        if floor_code == TAG_FLOOR_REFUSED:
            print(refused, file=sys.stderr)
            return TAG_FLOOR_REFUSED
        if floor_code:
            # A broken check never stops the fleet: only its refusal (73) does.
            print(f"[remote-build] the build host's floor check failed (exit {floor_code}); "
                  "building without it", file=sys.stderr, flush=True)
        manifest = snapshot(root, payload, args, held)
        for name in ("remote_build.py", "host_test_quarantine.py", "atlas_build_slots.py", "with-build-lock.sh"):
            shutil.copy2(root / "scripts" / name, payload / name)
        relative = f"{BUILD_DIR}/{manifest['slug']}/incoming/{manifest['invocation']}"
        run(transport.command(shlex.join(["mkdir", "-p", relative])), cwd=transport.cwd())
        run([*transport.rsync("-a"), str(payload) + "/", transport.location(relative) + "/"])
        sent = sum(f.stat().st_size for f in payload.rglob("*") if f.is_file() and not f.is_symlink())
        print(f"[remote-build] staged {sent / 1e6:.2f} MB in {time.monotonic() - started:.1f}s; bundles: " +
              (", ".join(f"{r}={k}" for r, k in manifest["bundles"].items()) or "none, host holds every head"),
              flush=True)
        command = shlex.join(["python3", relative + "/remote_build.py", "--remote", relative])
        print(f"[remote-build] host={host} tag={args.tag} invocation={manifest['invocation']} head={manifest['head']}", flush=True)
        print(f"[remote-build] remote log: ~/{BUILD_DIR}/{manifest['slug']}/artifacts/{manifest['invocation']}/build.log", flush=True)
        process = subprocess.run(transport.command(command), cwd=transport.cwd(),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(process.stdout, end="", flush=True)
        local = root / "build-remote" / manifest["invocation"]
        local.mkdir(parents=True)
        (local / "transport.log").write_text(process.stdout)
        remote_artifacts = f"{BUILD_DIR}/{manifest['slug']}/artifacts/{manifest['invocation']}/"
        retrieved = subprocess.run([*transport.rsync("-az"), transport.location(remote_artifacts), str(local) + "/"])
        print(f"[remote-build] logs and identity: {local}")
        if process.returncode:
            return process.returncode
        if retrieved.returncode:
            return retrieved.returncode
        result = json.loads((local / "result.json").read_text())
        identity_keys = ("invocation", "head", "submodules", "overlay", "mode", "tag",
                         "test_args", "test_scheme", "host_test_quarantine")
        if not result.get("ok") or any(result.get(k) != manifest[k] for k in identity_keys):
            raise ValueError("remote result/source identity mismatch")
        if result["compile"] != "ok" or (args.mode == "test" and result["tests"] != "ok"):
            raise ValueError("remote build/test result failed")
        if args.mode == "test-build":
            print("C11_REMOTE_OK compile=ok tests=not-run (build-for-testing; nothing launched)")
            return 0
        if args.mode == "test":
            print("C11_REMOTE_OK compile=ok tests=ok quarantined=%d" %
                  sum(1 for item in result.get("host_test_quarantine", [])
                      if item.get("auto_skipped")))
            return 0
        if args.mode == "ghosttykit":
            if result["tests"] != "ok" or digest(local / result["kit"]) != result["kit_sha256"]:
                raise ValueError("retrieved Ghostty kit verification failed")
            print(f"GHOSTTYKIT_PATH={local / result['kit']}\nC11_REMOTE_OK compile=ok tests=ok")
            return 0
        app = local / result["app"]
        if digest(app / "Contents/MacOS/c11") != result["executable_sha256"]:
            raise ValueError("retrieved artifact executable hash mismatch")
        if args.mode == "debug":
            plist = app / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            launch_env = info.setdefault("LSEnvironment", {})
            launch_env["CMUXD_UNIX_PATH"] = str(Path.home() / "Library/Application Support/c11" / ("c11d-dev-" + manifest["slug"] + ".sock"))
            launch_env["C11_REPO_ROOT"] = str(root)
            plist.write_bytes(plistlib.dumps(info))
            run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", app])
            run(["codesign", "--verify", "--deep", "--strict", app])
            destination = Path.home() / "Library/Developer/Xcode/DerivedData" / ("c11-" + manifest["slug"]) / "Build/Products/Debug" / app.name
        else:
            destination = Path.home() / "Library/Developer/Xcode/DerivedData" / ("remote-release-" + manifest["slug"]) / app.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Complete transfer/signing precedes replacement, so a remote failure preserves the old app.
        incoming = destination.with_name(destination.name + ".incoming-" + manifest["invocation"])
        shutil.copytree(app, incoming, symlinks=True)
        backup = destination.with_name(destination.name + ".previous-" + manifest["invocation"])
        if destination.exists():
            destination.rename(backup)
        try:
            incoming.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        result["local_executable_sha256"] = digest(destination / "Contents/MacOS/c11")
        (local / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if args.mode == "debug":
            # Publish the convenience CLI pointer only after a complete artifact replace.
            publish_cli_pointer(destination / "Contents/Resources/bin/c11")
        print(f"APP_PATH={destination}\nC11_REMOTE_OK compile=ok tests=na")
        if args.launch:
            run([root / "scripts/launch-tagged-automation.sh", args.tag, "--qa", "fresh"])
        return 0


def main():
    if sys.argv[1:] == ["--held-heads"]:
        print(json.dumps(host_held_heads()))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] in ("--remote", "--remote-locked"):
        return remote(Path(sys.argv[2]).resolve(), locked=sys.argv[1] == "--remote-locked")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="ssh host to build on (else C11_REMOTE_HOST, from the environment or "
                                       "~/.config/c11/dev-hosts)")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--mode", choices=("debug", "test", "test-build", "release", "ghosttykit"), default="debug",
                        help="test runs c11LogicTests only and refuses a host-app selector; "
                             "test-build compiles the test targets (build-for-testing) and runs nothing")
    parser.add_argument("--no-host-quarantine", action="store_true",
                        help="run quarantined c11Tests and c11LogicTests methods from the shared inventory")
    parser.add_argument("--launch", action="store_true", help="launch a returned Debug app with QA fresh")
    for option in ("clean", "wmo", "universal"):
        parser.add_argument("--" + option, action="store_true")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.extra and args.extra[0] == "--":
        args.extra.pop(0)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.tag):
        parser.error("tag must be 1–64 letters, digits, dots, underscores or hyphens")
    if not args.host:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from dev_hosts import dev_host
        args.host = dev_host("C11_REMOTE_HOST", "--host")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._-]*", args.host):
        parser.error("invalid SSH host")
    if args.launch and args.mode != "debug":
        parser.error("--launch requires --mode debug")
    if args.extra and args.mode != "test":
        parser.error("extra arguments require --mode test")
    if args.mode != "release" and (args.clean or args.wmo or args.universal):
        parser.error("--clean/--wmo/--universal require --mode release")
    # Refuse a host-app selector before client() stages or sends anything.
    apply_host_test_policy(args)
    try:
        args.floor_gib = floor_override()
    except ValueError as error:
        parser.error(str(error))
    return client(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"[remote-build] {error}", file=sys.stderr)
        sys.exit(error.returncode if isinstance(error, subprocess.CalledProcessError) else 4)
