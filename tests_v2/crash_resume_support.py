#!/usr/bin/env python3
"""C11-164 (RES-1..RES-5) crash-resume acceptance harness — shared machinery.

Factored so both the existing claude-only harness (C11-131,
`test_crash_resume_e2e.py`) AND the new multi-kind acceptance harness
(`test_crash_resume_multikind_e2e.py`) *could* build on it. The existing file
is intentionally left untouched; this module mirrors its constants and patterns
(app-bundle discovery, tagged launch/relaunch, `kill -9` of ONLY the tagged
PID, socket CLI wrapper, snapshot/sentinel paths, cwd->slug, fake session-file
fixtures, per-kind shim generators) and adds a store-state oracle.

TAG here is `res-post` (post-fix acceptance gate), so it never collides with the
`c11-131` tagged bundle/socket/snapshot the sibling harness uses.

=== Why the oracle asserts on STORE STATE, not the resume keystroke ===
Restored panes re-source the operator's ~/.zshrc (which rebuilds PATH from
scratch), so a PATH shim cannot shadow the restored PTY's `claude`/`codex`/…
resolution — the resume *keystroke* is therefore not observable to this harness
(it is covered separately by a real-agent smoke). What IS observable and
decisive is the reclassified conversation-store state exposed by
`c11 conversation list --json`: after a crash + relaunch the store either
- RESOLVED the ref to `state=suspended` +
  `diagnostic_reason="crash recovery: transcript verified on disk"` (resume will
  fire on this surface), or
- produced an HONEST_DIAGNOSTIC (`state=unknown/tombstoned` with a non-empty
  reason — e.g. codex `ambiguous: N candidates; chose newest`, or
  `crash recovery: transcript not found`), or
- FAILED silently (still `alive`/`placeholder`, or `suspended` with no verified
  reason) — a silent fresh-launch, the bug this gate exists to catch.

Mechanism references (verified against the merged source in this worktree):
- Restore ordering: `AppDelegate.prepareStartupSessionSnapshotIfNeeded`
  seeds the store from the snapshot, seeds the activity floor, runs
  `ConversationStore.runScrapeCapture` (resolves codex/pi/omp placeholders to
  real ids from disk), then on a dirty sentinel runs
  `ConversationStore.reclassifyAfterCrash` — AppDelegate.swift:3265-3334.
- `reclassifyAfterCrash`: for each `.alive`/`.suspended` ref, strategy
  `transcriptExists` → verified => `.suspended` "crash recovery: transcript
  verified on disk"; missing => `.unknown` "crash recovery: transcript not
  found" — Store.swift:246-268.
- `CMUX_DISABLE_AGENT_RESTART=1` suppresses only the resume *typing* pass
  (Workspace.swift:372); the seed/scrape/reclassify above still run, so the
  reclassified state stays observable — SessionPersistence.swift:38-39.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


# --------------------------------------------------------------------------- #
# Constants — mirror the C11-131 harness, retargeted to TAG=res-post.
# --------------------------------------------------------------------------- #

TAG = "res-post"
TAG_SLUG = "res-post"                        # socket uses the raw tag slug
# reload.sh derives the bundle id by sanitizing the tag: `-` -> `.`, plus a
# `.debug` infix. `c11-131` -> `com.stage11.c11.debug.c11.131`, so
# `res-post` -> `com.stage11.c11.debug.res.post`.
BUNDLE_ID = "com.stage11.c11.debug.res.post"
SOCKET_PATH = f"/tmp/c11-debug-{TAG_SLUG}.sock"
APP_SUPPORT = os.path.expanduser("~/Library/Application Support/c11")
SNAPSHOT_PATH = os.path.join(APP_SUPPORT, f"session-{BUNDLE_ID}.json")
SENTINEL_DIR = os.path.expanduser("~/.c11/runtime")
# Kill ONLY the tagged build by its unique app-path token; the operator's prod
# c11 (this very session) never matches this substring.
PROC_TOKEN = f"{TAG_SLUG}.app/Contents/MacOS"

# Per-kind on-disk session-file roots each scraper reads. Derived from the
# scraper sources in this worktree (cited at each fixture writer below).
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
CODEX_SESSIONS = os.path.expanduser("~/.codex/sessions")
PI_SESSIONS = os.path.expanduser("~/.pi/agent/sessions")
OMP_SESSIONS = os.path.expanduser("~/.omp/agent/sessions")

# Dirty/clean shutdown sentinel file names (ShutdownSentinel.swift:40-57;
# sanitiseBundleId keeps [A-Za-z0-9._-], so the bundle id passes through
# unchanged).
DIRTY_SENTINEL = os.path.join(SENTINEL_DIR, f"shutdown.{BUNDLE_ID}.dirty")
CLEAN_SENTINEL = os.path.join(SENTINEL_DIR, f"shutdown.{BUNDLE_ID}.clean")

FIRST_CLASS_KINDS = ("claude-code", "codex", "pi", "omp")


# --------------------------------------------------------------------------- #
# cwd -> per-kind session-directory slug functions.
#
# Each MUST match its scraper/strategy EXACTLY or the fixture lands where the
# scraper never looks. Citations are to the merged source in this worktree.
# --------------------------------------------------------------------------- #

def claude_slug(cwd: str) -> str:
    """Claude Code: replace every `/` AND `.` in the absolute cwd with `-`.
    Source: ClaudeCodeStrategy.projectSlug — Sources/Conversation/Strategies/
    ClaudeCode.swift:94-101 (and the C11-131 harness `_slug_for_cwd`,
    tests_v2/test_crash_resume_e2e.py:59-60)."""
    return "".join("-" if c in "/." else c for c in cwd)


def pi_slug(cwd: str) -> str:
    """pi: strip a single leading `/` or `\\`, map `/`,`\\`,`:` -> `-`, wrap in
    leading+trailing `--`. Dots are KEPT (unlike Claude). Source:
    PiScraper.sessionSlug — Sources/Conversation/Scrapers/PiScraper.swift:62-69."""
    stripped = cwd
    if stripped[:1] in ("/", "\\"):
        stripped = stripped[1:]
    mapped = "".join("-" if c in "/\\:" else c for c in stripped)
    return f"--{mapped}--"


def omp_slug(cwd: str, home: str = None) -> str:
    """omp: strip the home-directory prefix if present, then map every `/` ->
    `-`. No lowercasing; existing dashes preserved. Source:
    OmpScraper.sessionSlug — Sources/Conversation/Scrapers/OmpScraper.swift:55-61.
    (Our run-scoped cwds live under $TMPDIR, not $HOME, so no prefix is
    stripped and the slug is just the full path with `/`->`-`.)"""
    home = home if home is not None else os.path.expanduser("~")
    path = cwd
    if home and path.startswith(home):
        path = path[len(home):]
    return path.replace("/", "-")


# --------------------------------------------------------------------------- #
# Discovery + low-level helpers (mirrors C11-131 harness verbatim in shape).
# --------------------------------------------------------------------------- #

def find_app_bundle() -> str:
    """Locate the built tagged .app bundle (reload.sh writes a tagged
    DerivedData path). Prefers a bundle whose Info.plist carries BUNDLE_ID."""
    roots = []
    dd = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
    if os.path.isdir(dd):
        roots += [
            os.path.join(dd, d) for d in os.listdir(dd)
            if d.startswith("c11-") or "GhosttyTabs" in d
        ]
    roots += [f"/tmp/c11-{TAG_SLUG}"]
    candidates = []
    for root in roots:
        for base, dirs, _files in (os.walk(root) if os.path.isdir(root) else []):
            for d in list(dirs):
                if d.endswith(".app"):
                    candidates.append(os.path.join(base, d))
            dirs[:] = [d for d in dirs if not d.endswith(".app")]
    for app in sorted(candidates, key=os.path.getmtime, reverse=True):
        plist = os.path.join(app, "Contents", "Info.plist")
        try:
            out = subprocess.run(
                ["defaults", "read", os.path.splitext(plist)[0],
                 "CFBundleIdentifier"],
                capture_output=True, text=True,
            ).stdout.strip()
        except Exception:
            out = ""
        if out == BUNDLE_ID:
            return app
    raise RuntimeError(
        f"Could not find a built .app with bundle id {BUNDLE_ID}. "
        f"Run ./scripts/reload.sh --tag {TAG} first."
    )


def app_executable(app: str) -> str:
    return os.path.join(app, "Contents", "MacOS", "c11")


def tagged_cli(app: str) -> str:
    return os.path.join(app, "Contents", "Resources", "bin", "c11")


def kill_tagged_instances():
    """SIGKILL ONLY the tagged build's process, matched by its unique app-path
    token. Guarded so a misconfigured PROC_TOKEN can never target prod c11."""
    assert TAG_SLUG in PROC_TOKEN and PROC_TOKEN.endswith("/Contents/MacOS"), \
        f"refusing to pkill with an unsafe token: {PROC_TOKEN!r}"
    subprocess.run(["pkill", "-9", "-f", PROC_TOKEN], capture_output=True)
    time.sleep(0.6)


def _cli(cli_path, *args, timeout=15.0, env_extra=None):
    """Run the tagged CLI against the tagged socket."""
    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = SOCKET_PATH
    env["C11_SOCKET"] = SOCKET_PATH
    if env_extra:
        env.update(env_extra)
    return subprocess.run([cli_path, *args], capture_output=True, text=True,
                          env=env, timeout=timeout)


def wait_socket_ready(cli_path, timeout: float = 45.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(SOCKET_PATH):
            try:
                if _cli(cli_path, "ping", timeout=4.0).returncode == 0:
                    return
            except Exception:
                pass
        time.sleep(0.4)
    raise RuntimeError(f"socket {SOCKET_PATH} not ready after {timeout}s")


def wait_socket_gone(cli_path, timeout: float = 15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not os.path.exists(SOCKET_PATH):
            return
        try:
            if _cli(cli_path, "ping", timeout=2.0).returncode != 0:
                return
        except Exception:
            return
        time.sleep(0.3)
    return


def new_uuid() -> str:
    """Fresh, run-unique conversation id. UUIDv4 shape satisfies every kind's
    `isValidConversationUUID` (8-4-4-4-12 hex)."""
    return str(uuid.uuid4())


def screen_is_locked() -> bool:
    """True if the macOS login session is locked. A locked screen restricts the
    window server, so the tagged app can create workspaces over the socket but
    the GUI never materialises them and their `--command` never runs (every
    surface reads `ready=0`). Detect it up front so a locked-screen run fails
    with an actionable message instead of a confusing all-zero oracle."""
    try:
        import Quartz  # pyobjc; present in the system python used for tests_v2
        d = Quartz.CGSessionCopyCurrentDictionary()
        return bool(d and d.get("CGSSessionScreenIsLocked"))
    except Exception:
        return False  # can't tell → don't block


def require_unlocked_screen():
    if screen_is_locked():
        raise SystemExit(
            "REFUSING TO RUN: the macOS screen is LOCKED. This harness drives a "
            "real tagged c11 GUI (workspaces + PTYs); a locked session stalls the "
            "window server so no agent shim ever runs (you would see ready=0 for "
            "every surface). Unlock the screen and re-run. (CI's headless runner "
            "and an unlocked interactive session are both fine.)"
        )


# --------------------------------------------------------------------------- #
# Store-state oracle.
# --------------------------------------------------------------------------- #

RESOLVED = "RESOLVED"
HONEST_DIAGNOSTIC = "HONEST_DIAGNOSTIC"
UNRESOLVED = "UNRESOLVED"    # placeholder survived — safe skip, no wrong resume
FAIL = "FAIL"               # silent fresh-launch: alive, or suspended-unverified

# The exact reason `reclassifyAfterCrash` stamps on a verified ref
# (Store.swift:259). RESOLVED requires this substring so a `suspended` state
# with any *other* reason (a silent clean-path suspend that never verified the
# transcript) is caught as FAIL.
VERIFIED_REASON_SUBSTR = "transcript verified on disk"


def classify_conversation(conv: dict) -> tuple:
    """Classify a single `conversation list --json` entry into FOUR buckets:

      RESOLVED          state=suspended + verified-transcript reason. The
                        resume rail will fire on this surface. (Acceptance.)
      HONEST_DIAGNOSTIC real ref (placeholder=False), state unknown/tombstoned,
                        non-empty reason — e.g. codex `ambiguous: N candidates`,
                        or claude `crash recovery: transcript not found`. The
                        pane did NOT resume, and told the operator why.
      UNRESOLVED        placeholder still true after crash recovery. Only
                        reachable for scrape-primary kinds whose on-disk session
                        was absent at restore, so the id never resolved.
                        resume() skips placeholders (Codex/Pi/Omp.swift resume:
                        `.skip("placeholder…")`), so this is a SAFE no-op — not
                        a silent fresh-launch. The acceptance scenario still
                        requires zero UNRESOLVED (every session present ⇒ every
                        id resolves); the missing-per-kind variant expects it
                        for the deliberately-starved scrape surface.
      FAIL              the only genuinely bad outcome: state=alive (never
                        reclassified) or state=suspended WITHOUT the verified
                        reason (the resume rail would type into the pane on
                        unverified state) — a silent fresh/wrong resume.

    The brief's 3-bucket contract (RESOLVED / HONEST_DIAGNOSTIC / SILENT_FRESH)
    maps as: SILENT_FRESH == FAIL. UNRESOLVED is split out from the brief's
    "placeholder ⇒ fail" because a *surviving* placeholder cannot cause a wrong
    resume (resume skips it); folding it into FAIL would wrongly flag the
    missing-session safe-skip. Acceptance treats UNRESOLVED as a failure too
    (asserts zero), so the strict bar is preserved where it matters.

    Returns (classification, detail_str).
    """
    state = (conv.get("state") or "").lower()
    reason = (conv.get("diagnostic_reason") or "").strip()
    placeholder = bool(conv.get("placeholder", False))

    # A surviving placeholder can never emit a ResumeAction, so it is a safe
    # skip regardless of state — classify it before the state ladder.
    if placeholder:
        return UNRESOLVED, f"placeholder unresolved (state={state}, reason={reason!r})"

    if state == "suspended":
        if VERIFIED_REASON_SUBSTR in reason:
            return RESOLVED, reason
        # Suspended but not via verified crash-recovery = a silent fresh/clean
        # suspend the resume rail would fire on without on-disk evidence.
        return FAIL, f"suspended WITHOUT verified reason: {reason!r}"

    if state in ("unknown", "tombstoned", "unsupported"):
        if reason:
            return HONEST_DIAGNOSTIC, f"state={state}: {reason}"
        return FAIL, f"state={state} with EMPTY diagnostic_reason (silent)"

    if state == "alive":
        return FAIL, "still alive after crash recovery (silent fresh-launch)"

    return FAIL, f"unexpected state={state!r} reason={reason!r}"


def read_conversations(cli_path) -> dict:
    """Return the parsed `conversation list --json` payload
    ({'conversations': [...], 'is_disabled': bool}) or {} on error."""
    res = _cli(cli_path, "conversation", "list", "--json")
    try:
        return json.loads(res.stdout)
    except Exception:
        return {}


def oracle_table(conversations: list) -> list:
    """Classify every surface. Returns a list of dicts:
    {surface_id, kind, cwd, id, state, placeholder, classification, detail}."""
    rows = []
    for c in conversations:
        cls, detail = classify_conversation(c)
        rows.append({
            "surface_id": c.get("surface_id"),
            "kind": c.get("kind"),
            "cwd": c.get("cwd"),
            "id": c.get("id"),
            "state": c.get("state"),
            "placeholder": c.get("placeholder"),
            "classification": cls,
            "detail": detail,
        })
    return rows


def print_oracle_table(rows: list, title: str = "store-state oracle"):
    print(f"\n  --- {title} ({len(rows)} surfaces) ---")
    counts = {RESOLVED: 0, HONEST_DIAGNOSTIC: 0, UNRESOLVED: 0, FAIL: 0}
    for r in rows:
        counts[r["classification"]] = counts.get(r["classification"], 0) + 1
        cwd = (r["cwd"] or "")[-28:]
        print(f"    [{r['classification']:<17}] {str(r['kind']):<12} "
              f"cwd=…{cwd:<28} state={str(r['state']):<10} {r['detail']}")
    print(f"    totals: RESOLVED={counts[RESOLVED]} "
          f"HONEST_DIAGNOSTIC={counts[HONEST_DIAGNOSTIC]} "
          f"UNRESOLVED={counts[UNRESOLVED]} FAIL={counts[FAIL]}")
    return counts


# --------------------------------------------------------------------------- #
# The multi-kind harness.
# --------------------------------------------------------------------------- #

class MultiKindHarness:
    """Owns the run dir, the per-kind PATH shims, the tagged-app launch/kill,
    the fixture writers, and fixture teardown. Idempotent: every instance uses a
    fresh run dir and fresh UUIDs; `cleanup()` removes ONLY files this run
    created (tracked by exact path) and its run-scoped session subdirs — it
    never touches the operator's real ~/.claude, ~/.codex, ~/.pi, ~/.omp
    sessions."""

    def __init__(self):
        self.run_id = uuid.uuid4().hex[:8]
        self.run_dir = tempfile.mkdtemp(prefix=f"c11-{TAG_SLUG}-e2e-")
        self.shim_dir = os.path.join(self.run_dir, "bin")
        self.zdotdir = os.path.join(self.run_dir, "zdot")
        os.makedirs(self.shim_dir, exist_ok=True)
        os.makedirs(self.zdotdir, exist_ok=True)

        self.app = find_app_bundle()
        self.exe = app_executable(self.app)
        self.cli_path = tagged_cli(self.app)

        # Run-scoped codex subdir so teardown is a single rmtree of OUR dir
        # (codex has no cwd slug; the scraper walks the whole tree recursively,
        # so any depth is found — ClaudeCodeScraper.swift:73-124).
        self.codex_dir = os.path.join(CODEX_SESSIONS, f"c11-{TAG_SLUG}-{self.run_id}")

        # Teardown bookkeeping — only ever our own paths.
        self._created_files = set()   # exact fixture file paths
        self._created_dirs = set()    # run-scoped session dirs (safe rmtree)

        self.proc = None
        self._write_shims()
        self._write_zdotdir()

    # -- shim + zdotdir ---------------------------------------------------- #

    def _write_zdotdir(self):
        """The operator's ~/.zshrc rebuilds PATH from scratch, which would wipe
        any PATH we prepend at app launch. Redirect every pane's zsh to a
        minimal ZDOTDIR whose PATH puts the shim dir first, so bare
        `claude`/`codex`/`pi`/`omp` resolve to our shims. (Same trick as the
        C11-131 harness, tests_v2/test_crash_resume_e2e.py:168-182.)"""
        body = (
            f'export PATH="{self.shim_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\n'
            f'export SHIM_C11="{self.cli_path}"\n'
            f'export SHIM_SOCKET="{SOCKET_PATH}"\n'
            f'export SHIM_LOG_DIR="{self.run_dir}"\n'
        )
        for name in (".zshrc", ".zshenv"):
            with open(os.path.join(self.zdotdir, name), "w") as f:
                f.write(body)

    def _write_shims(self):
        """One fake shim per kind. Each shim:
          1. records its argv to `<run>/<kind>-invocations.log`,
          2. declares terminal_type via `c11 set-agent --type <kind>` (so the
             restored panel is picked up by ScrapeCaptureContext.contexts —
             ScrapeCapturePipeline.swift:34-58),
          3. wrapper-claims a placeholder via
             `c11 conversation claim --kind <kind> --cwd "$PWD"` (mirrors
             Resources/bin/{codex,pi,omp}),
          4. claude-code ONLY: emulates the SessionStart hook via
             `c11 conversation push --kind claude-code --id <uuid> --source
             hook` (codex/pi/omp are scrape-primary — NO push; the id is
             resolved from the on-disk session file),
          5. writes a `READY` sentinel line, then blocks like a TUI.

        Surface resolution uses the pane's own CMUX_SURFACE_ID (set by c11 per
        pane); we pin --socket explicitly so the calls always land on the
        tagged instance regardless of PATH/env propagation."""
        common_head = (
            '#!/bin/bash\n'
            'KIND="__KIND__"\n'
            'LOG="$SHIM_LOG_DIR/$KIND-invocations.log"\n'
            'C11="$SHIM_C11"; SOCK="$SHIM_SOCKET"\n'
            'echo "INVOKE kind=$KIND pid=$$ cwd=$PWD args=$*" >> "$LOG"\n'
            # (2) terminal_type declaration.
            '"$C11" --socket "$SOCK" set-agent --type "$KIND" >> "$LOG" 2>&1 || true\n'
            # (3) wrapper-claim placeholder.
            '"$C11" --socket "$SOCK" conversation claim --kind "$KIND" '
            '--cwd "$PWD" >> "$LOG" 2>&1 || true\n'
        )
        claude_push = (
            # (4) claude-code SessionStart-hook emulation (push-primary).
            'if [ -n "$SHIM_ID" ]; then\n'
            '  "$C11" --socket "$SOCK" conversation push --kind claude-code '
            '--id "$SHIM_ID" --source hook --cwd "$PWD" >> "$LOG" 2>&1 || true\n'
            '  echo "PUSHED id=$SHIM_ID cwd=$PWD" >> "$LOG"\n'
            'fi\n'
        )
        common_tail = (
            # (5) READY sentinel + block like a TUI.
            'echo "READY kind=$KIND cwd=$PWD" >> "$LOG"\n'
            'while true; do sleep 1; done\n'
        )
        for kind in FIRST_CLASS_KINDS:
            # Shim file name is the bare agent binary name the pane invokes.
            name = {"claude-code": "claude"}.get(kind, kind)
            body = common_head.replace("__KIND__", kind)
            if kind == "claude-code":
                body += claude_push
            body += common_tail
            path = os.path.join(self.shim_dir, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)

    def command_for(self, kind: str, sid: str = None) -> str:
        """The shell command a workspace runs in its focused surface. claude
        threads its known id via SHIM_ID; codex/pi/omp take no id (scrape
        resolves it)."""
        binname = {"claude-code": "claude"}.get(kind, kind)
        if kind == "claude-code":
            assert sid, "claude-code needs a known id"
            return f"SHIM_ID={sid} {binname}"
        return binname

    # -- launch / kill ----------------------------------------------------- #

    def launch(self, disable_store=False, no_resume=False):
        env = dict(os.environ)
        # Drop the parent c11 session's surface/socket env so the tagged app
        # doesn't inherit them.
        for k in list(env):
            if k.startswith("CMUX_") or k.startswith("C11_"):
                env.pop(k, None)
        env["PATH"] = self.shim_dir + ":" + env.get("PATH", "")
        env["SHIM_C11"] = self.cli_path
        env["SHIM_SOCKET"] = SOCKET_PATH
        env["SHIM_LOG_DIR"] = self.run_dir
        env["ZDOTDIR"] = self.zdotdir
        # CRITICAL (CLAUDE.md): a normal tagged launch blocks on two modal
        # sheets before the GUI is usable — the Agent Skills install/update
        # sheet and the "Resume previous session?" picker. Either one wedges the
        # main thread, so `new-workspace` allocates an id over the socket but the
        # workspace never materialises and its `--command` never runs (the
        # `ready=0` failure mode). Suppress both by setting C11_QA_LAUNCH:
        # `resume` when a snapshot exists (post-crash relaunch — restore the
        # session silently, no picker) so the store still seeds/scrapes/
        # reclassifies; `fresh` otherwise (pre-crash build — nothing to restore).
        env["C11_QA_LAUNCH"] = "resume" if os.path.exists(SNAPSHOT_PATH) else "fresh"
        # Let the harness's external CLI talk to the socket; default c11Only
        # mode rejects non-descendant callers by process ancestry.
        env["CMUX_SOCKET_MODE"] = "allowAll"
        if disable_store:
            env["CMUX_DISABLE_CONVERSATION_STORE"] = "1"
        if no_resume:
            # Layout restores; the resume typing pass is suppressed
            # (Workspace.swift:372) so the seeded + scraped + reclassified refs
            # stay observable instead of being re-captured to `alive`.
            env["CMUX_DISABLE_AGENT_RESTART"] = "1"
        # Direct-exec of the inner Mach-O (mirrors the proven C11-131 harness).
        self.proc = subprocess.Popen(
            [self.exe], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_socket_ready(self.cli_path)

    def stop(self, sig=signal.SIGKILL):
        if self.proc and self.proc.poll() is None:
            try:
                os.kill(self.proc.pid, sig)
            except ProcessLookupError:
                pass
        # Belt-and-suspenders: also reap by token (the app may re-parent).
        if sig == signal.SIGKILL:
            subprocess.run(["pkill", "-9", "-f", PROC_TOKEN], capture_output=True)
        wait_socket_gone(self.cli_path)
        if self.proc:
            try:
                self.proc.wait(timeout=10)
            except Exception:
                pass

    # -- CLI + workspace --------------------------------------------------- #

    def cli(self, *args, env_extra=None, timeout=15.0):
        return _cli(self.cli_path, *args, timeout=timeout, env_extra=env_extra)

    def make_workspace(self, title, cwd, command) -> str:
        os.makedirs(cwd, exist_ok=True)
        res = self.cli("new-workspace", "--title", title, "--cwd", cwd,
                       "--command", command)
        for line in (res.stdout or "").strip().splitlines():
            if line.startswith("OK "):
                return line[3:].strip()
        return ""

    def reset_shim_logs(self):
        """Truncate the per-kind invocation logs. The shims APPEND (`>>`) to one
        log per kind in the shared run_dir, so counts accumulate across
        scenarios; without a reset, a later scenario's `wait_ready(N)` returns
        immediately on a prior scenario's stale READY lines (an ineffective
        barrier). Call at the start of each scenario's `build_panes` — the prior
        scenario's app (and its shims) is already killed, so nothing is racing
        the truncate. Because each shim writes READY only AFTER its claim + push
        complete, a fresh READY count is also a reliable "pushes landed" barrier."""
        for kind in FIRST_CLASS_KINDS:
            try:
                open(os.path.join(self.run_dir, f"{kind}-invocations.log"), "w").close()
            except OSError:
                pass

    def log_text(self, kind: str) -> str:
        path = os.path.join(self.run_dir, f"{kind}-invocations.log")
        try:
            with open(path) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def wait_ready(self, expected_count: int, timeout: float = 150.0) -> int:
        """Poll all per-kind logs until >= `expected_count` READY sentinels
        have been written (set-agent + claim + optional push all completed).
        Returns the count seen. The timeout is generous: building N workspaces
        each spawns a shell + runs a shim that makes 2-3 socket round-trips, and
        under concurrent machine load (e.g. sibling xcodebuilds) the aggregate
        can take well over a minute for a full 12-pane topology."""
        deadline = time.time() + timeout
        seen = 0
        while time.time() < deadline:
            seen = sum(
                len(re.findall(r"^READY ", self.log_text(k), re.M))
                for k in FIRST_CLASS_KINDS
            )
            if seen >= expected_count:
                return seen
            time.sleep(0.5)
        return seen

    def wait_conversation_count(self, expected: int, timeout: float = 90.0) -> int:
        """Poll `conversation list --json` until >= `expected` refs exist."""
        deadline = time.time() + timeout
        n = 0
        while time.time() < deadline:
            n = len(read_conversations(self.cli_path).get("conversations", []))
            if n >= expected:
                return n
            time.sleep(0.5)
        return n

    # -- fixture writers (land at each scraper's real path) ---------------- #

    def _write_session(self, path: str, mtime: float, first_line: str = None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            # Most scrapers stat metadata only (privacy contract) and never
            # open transcript bytes, so an opaque summary line suffices. Codex
            # is the exception post-G3: it does a BOUNDED read of the FIRST
            # line and extracts `payload.cwd` to recover the session's real
            # cwd, so codex fixtures pass a real first_line (see
            # make_codex_session).
            f.write((first_line or '{"type":"summary","summary":"c11-164 fake session"}') + "\n")
        os.utime(path, (mtime, mtime))
        self._created_files.add(path)

    def make_claude_session(self, cwd: str, sid: str, mtime: float = None) -> str:
        """~/.claude/projects/<claude_slug(cwd)>/<uuid>.jsonl.
        Path/slug: ClaudeCodeStrategy.transcriptExists +
        ClaudeCodeScraper — ClaudeCode.swift:79-101, ClaudeCodeScraper.swift:36-65.
        (mtime is irrelevant for claude: transcriptExists is a stat existence
        check with no floor; kept for signature parity.)"""
        d = os.path.join(CLAUDE_PROJECTS, claude_slug(cwd))
        self._created_dirs.add(d)
        path = os.path.join(d, f"{sid}.jsonl")
        self._write_session(path, mtime if mtime is not None else time.time())
        return path

    def make_codex_session(self, cwd: str, sid: str, mtime: float,
                          ts: str = "2026-07-07T12-00-00") -> str:
        """~/.codex/sessions/<run-subdir>/rollout-<ts>-<uuid>.jsonl.

        Codex has NO cwd-slug DIRECTORY — the scraper walks the whole
        ~/.codex/sessions tree recursively (subdir depth is irrelevant; real
        codex nests under YYYY/MM/DD). We use a run-scoped subdir so teardown
        is a single rmtree.

        Two things the scraper needs from a codex fixture (post-G3):
        - Filename `rollout-<ISO8601-with-dashes>-<uuid>.jsonl`; the id is the
          trailing 36-char UUID (`stem.suffix(36)`) — CodexScraper,
          ClaudeCodeScraper.swift:106-114.
        - A valid FIRST LINE whose `payload.cwd` EXACTLY equals the surface's
          cwd. G3's real-cwd recovery reads only that field; the CodexStrategy
          then keeps only candidates whose recovered cwd == the surface cwd.
          This is what lets distinct-cwd codex panes resume (each matches only
          its own cwd) while same-cwd codex pairs stay honestly ambiguous.

        `mtime` must be >= the pane's wrapper-claim time so the claim-time floor
        keeps it (CodexStrategy.capture — Codex.swift:29-41)."""
        self._created_dirs.add(self.codex_dir)
        path = os.path.join(self.codex_dir, f"rollout-{ts}-{sid}.jsonl")
        header = json.dumps({
            "timestamp": "2026-07-07T00:00:00",
            "type": "session_meta",
            "payload": {
                "id": sid,
                "cwd": cwd,               # MUST match the surface's cwd exactly
                "originator": "cli",
                "instructions": "stub",
            },
        })
        self._write_session(path, mtime, first_line=header)
        return path

    def make_pi_session(self, cwd: str, sid: str, mtime: float,
                        ts: str = "2026-07-07T12-00-00-000Z") -> str:
        """~/.pi/agent/sessions/<pi_slug(cwd)>/<ISO-ts>_<uuid>.jsonl. pi is
        cwd-scoped: the scraper lists ONLY the cwd's slug dir. Filename is
        `<ISO-ts>_<uuid>` — id is the substring after the LAST `_` (the ISO
        timestamp uses dashes, no `_`). Source: PiScraper —
        PiScraper.swift:50-106."""
        d = os.path.join(PI_SESSIONS, pi_slug(cwd))
        self._created_dirs.add(d)
        path = os.path.join(d, f"{ts}_{sid}.jsonl")
        self._write_session(path, mtime)
        return path

    def make_omp_session(self, cwd: str, sid: str, mtime: float,
                        ts: str = "1751889600000") -> str:
        """~/.omp/agent/sessions/<omp_slug(cwd)>/<ts>_<uuid>.jsonl. omp is
        cwd-scoped like pi. Filename is `<ts>_<uuid>` — id is the substring
        after the LAST `_`. Source: OmpScraper — OmpScraper.swift:41-105."""
        d = os.path.join(OMP_SESSIONS, omp_slug(cwd))
        self._created_dirs.add(d)
        path = os.path.join(d, f"{ts}_{sid}.jsonl")
        self._write_session(path, mtime)
        return path

    def remove_session_file(self, path: str):
        """Delete a specific fixture file (models the transcript-missing
        variant). Stays tracked so double-teardown is harmless."""
        try:
            os.remove(path)
        except FileNotFoundError:
            pass

    # -- persistence + teardown ------------------------------------------- #

    def reset_persistence(self):
        """Wipe this tagged bundle's snapshot + sentinels for a clean slate."""
        for p in (SNAPSHOT_PATH, DIRTY_SENTINEL, CLEAN_SENTINEL):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
        for name in (os.listdir(SENTINEL_DIR) if os.path.isdir(SENTINEL_DIR) else []):
            if BUNDLE_ID in name:
                try:
                    os.remove(os.path.join(SENTINEL_DIR, name))
                except FileNotFoundError:
                    pass

    def cleanup(self):
        # App is launched via `open` (no child handle) — always reap the tagged
        # instance by token.
        kill_tagged_instances()
        # Remove ONLY our own fixture files first, then our run-scoped session
        # dirs (safe because every dir here was minted from a run-unique cwd or
        # the run-scoped codex subdir — never a shared operator dir).
        for path in list(self._created_files):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
        for d in list(self._created_dirs):
            # Guard: refuse to rmtree a bare session ROOT (would nuke the
            # operator's real sessions). Every tracked dir must be strictly
            # deeper than its root.
            root = None
            for r in (CLAUDE_PROJECTS, CODEX_SESSIONS, PI_SESSIONS, OMP_SESSIONS):
                if d.startswith(r + os.sep):
                    root = r
                    break
            if root is None or os.path.normpath(d) == os.path.normpath(root):
                continue
            shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(self.run_dir, ignore_errors=True)
