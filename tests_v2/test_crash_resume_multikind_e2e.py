#!/usr/bin/env python3
"""C11-164 (RES-1..RES-5): the multi-kind force-kill crash-resume ACCEPTANCE gate.

This is the acceptance oracle for the crash-resume machinery. It drives a TAGGED
c11 build through the full save / kill -9 / relaunch / reclassify loop across
>=12 conversations spanning ALL FOUR first-class agent kinds
(claude-code, codex, pi, omp) in >=4 workspaces, with deliberately adversarial
fixtures, and asserts on the reclassified conversation-store STATE (not on the
resume keystroke — see crash_resume_support module docstring for why).

============================ HOW TO RUN ============================
Author-only; do NOT run inside the orchestration. To run it yourself:

    # 1. Build (and launch) the tagged app ONCE. The harness manages its own
    #    launches thereafter (it needs to inject the PATH shims), and kills the
    #    reload-launched instance first.
    ./scripts/reload.sh --tag res-post

    # 2. Run the acceptance harness (never via the host-bound xcodebuild action):
    python3 tests_v2/test_crash_resume_multikind_e2e.py

    # Optional: run a subset by name substring, e.g.
    python3 tests_v2/test_crash_resume_multikind_e2e.py all_present kill_switch

Everything is isolated to the `res-post` tagged bundle id / socket / snapshot,
so it never touches the operator's prod c11 (this session) or its sessions.

============================ TOPOLOGY (12 surfaces / 12 workspaces / 4 kinds) ==
  claude-code x4  (cc0..cc3)     push-primary: SessionStart-hook emulation.
  codex       x4  (cx0, cx1,     pull-primary: id resolved from the rollout file
                   cxADVa,cxADVb)  at restore. cx0/cx1 have DISTINCT cwds (each
                                   codex fixture's first-line payload.cwd matches
                                   its surface) so they resume cleanly; cxADVa +
                                   cxADVb SHARE one cwd → the ambiguity policy
                                   fires (two candidates, same cwd → state
                                   unknown "ambiguous").
  pi          x2  (pi0, pi1)     pull-primary, cwd-slug-scoped. pi1's cwd carries
                                   BOTH a STALE (mtime < claim) and a FRESH
                                   (mtime > claim) session file, so the claim-time
                                   floor is exercised: floor drops the stale one →
                                   pi1 resolves cleanly (else it would go
                                   ambiguous).
  omp         x2  (omp0, omp1)   pull-primary, cwd-slug-scoped.

Adversarial coverage (mandatory per the brief):
  * >=1 same-cwd codex pair (cxADVa/cxADVb) — exercises the ambiguity policy.
  * >=1 cwd (pi1) with a stale+fresh pair — exercises the mtime/activity floor.

============================ ORACLE ============================
Per surface, from `c11 conversation list --json` (see
crash_resume_support.classify_conversation):
  RESOLVED          state=suspended + "crash recovery: transcript verified on
                    disk". Resume will fire.
  HONEST_DIAGNOSTIC real ref, unknown/tombstoned, non-empty reason (ambiguous /
                    transcript-not-found). Did NOT resume; said why.
  UNRESOLVED        placeholder survived (scrape kind, no on-disk session) — a
                    SAFE skip (resume() skips placeholders), distinguished from
                    a genuine silent fresh-launch.
  FAIL              state=alive, or suspended WITHOUT the verified reason — the
                    silent fresh/wrong resume this gate exists to catch.

Acceptance passes iff every surface is RESOLVED or HONEST_DIAGNOSTIC (0 FAIL,
0 UNRESOLVED), with the adversarial pair honestly ambiguous.

Scenario variants: all-present (acceptance), one-transcript-missing-per-kind,
clean `app restart`, double kill-9 (idempotent), and the
CMUX_DISABLE_CONVERSATION_STORE kill switch.
"""

import json
import os
import signal
import sys
import time

import crash_resume_support as S


# --------------------------------------------------------------------------- #
# Pass/fail accounting.
# --------------------------------------------------------------------------- #

PASS, FAILED = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAILED).append(name)
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {name}" + (f" — {detail}" if detail and not cond else ""))


# --------------------------------------------------------------------------- #
# Topology.
# --------------------------------------------------------------------------- #

# Each entry: (label, kind, cwd_key). Panes with the SAME cwd_key share a cwd
# (the adversarial same-cwd codex pair); everything else is distinct.
PANES = [
    ("cc0", "claude-code", "cc0"),
    ("cc1", "claude-code", "cc1"),
    ("cc2", "claude-code", "cc2"),
    ("cc3", "claude-code", "cc3"),
    ("cx0", "codex", "cx0"),
    ("cx1", "codex", "cx1"),
    ("cxADVa", "codex", "codex-adv"),   # shared cwd ↓
    ("cxADVb", "codex", "codex-adv"),   # shared cwd ↑  (ambiguity pair)
    ("pi0", "pi", "pi0"),
    ("pi1", "pi", "pi1"),               # + stale sibling (floor test)
    ("omp0", "omp", "omp0"),
    ("omp1", "omp", "omp1"),
]


class Topology:
    """Builds the 12-surface topology on a live launched harness and writes the
    on-disk session fixtures. `omit` is a set of labels whose session fixtures
    are deliberately NOT created (the missing-per-kind variant)."""

    def __init__(self, h: S.MultiKindHarness):
        self.h = h
        self.specs = []          # list of dicts: label, kind, cwd, sid
        self.by_label = {}

    def cwd_for(self, cwd_key: str) -> str:
        return os.path.join(self.h.run_dir, "ws", cwd_key)

    def build_panes(self):
        """Create every workspace and run its (shim) agent. Returns after all
        panes have written their READY sentinel (set-agent + claim + optional
        push complete) so a subsequent `state save` captures the full store."""
        for label, kind, cwd_key in PANES:
            cwd = self.cwd_for(cwd_key)
            sid = S.new_uuid()
            cmd = self.h.command_for(kind, sid)
            wsref = self.h.make_workspace(f"RES-{label}", cwd, cmd)
            spec = {"label": label, "kind": kind, "cwd": cwd, "sid": sid,
                    "workspace": wsref}
            self.specs.append(spec)
            self.by_label[label] = spec
        # Wait for all shims to finish their setup handshake, then confirm the
        # store actually holds all refs.
        ready = self.h.wait_ready(len(PANES))
        count = self.h.wait_conversation_count(len(PANES))
        return ready, count

    def write_fixtures(self, omit=frozenset()):
        """Create each surface's on-disk session file at the exact path its
        scraper reads. Fresh files get mtime=now (safely after every pane's
        wrapper-claim, which happened during build_panes); pi1 additionally
        gets a STALE sibling below the claim floor."""
        now = time.time()
        stale = now - 3600            # an hour before any claim ⇒ below floor
        for spec in self.specs:
            if spec["label"] in omit:
                continue
            kind, cwd, sid = spec["kind"], spec["cwd"], spec["sid"]
            if kind == "claude-code":
                spec["fixture"] = self.h.make_claude_session(cwd, sid)
            elif kind == "codex":
                spec["fixture"] = self.h.make_codex_session(cwd, sid, mtime=now)
            elif kind == "pi":
                spec["fixture"] = self.h.make_pi_session(cwd, sid, mtime=now)
                if spec["label"] == "pi1":
                    # Adversarial: a second, OLDER pi session in the same cwd
                    # slug dir. The claim-time floor must drop it, else pi1 goes
                    # ambiguous. Distinct id + distinct ISO ts so both files
                    # coexist in the slug dir.
                    spec["stale_fixture"] = self.h.make_pi_session(
                        cwd, S.new_uuid(), mtime=stale,
                        ts="2026-01-01T00-00-00-000Z")
            elif kind == "omp":
                spec["fixture"] = self.h.make_omp_session(cwd, sid, mtime=now)


# --------------------------------------------------------------------------- #
# Shared step helpers.
# --------------------------------------------------------------------------- #

def assert_precrash_snapshot(topo: Topology):
    """`state save`, then assert the snapshot carries per-panel
    surface_conversations, that claude-code entries are real (placeholder=False)
    and codex/pi/omp entries are placeholder wrapperClaims (placeholder=True).
    This makes a later failure diagnosable as claim-capture vs resume."""
    save = topo.h.cli("state", "save")
    check("state save ok", save.returncode == 0, save.stderr.strip())

    actives = []   # (kind, id, placeholder)
    try:
        snap = json.load(open(S.SNAPSHOT_PATH))
        for w in snap.get("windows", []):
            for ws in w["tabManager"]["workspaces"]:
                for p in ws["panels"]:
                    a = (p.get("surface_conversations") or {}).get("active")
                    if a:
                        actives.append((a.get("kind"), a.get("id"),
                                        bool(a.get("placeholder"))))
    except Exception as e:
        check("snapshot readable", False, f"{e}")
        return

    check("snapshot carries >=12 surface_conversations", len(actives) >= 12,
          f"got {len(actives)}")
    cc = [a for a in actives if a[0] == "claude-code"]
    scrape = [a for a in actives if a[0] in ("codex", "pi", "omp")]
    check("pre-crash: claude-code refs are real (placeholder=False)",
          len(cc) >= 4 and all(not a[2] for a in cc),
          f"{[(a[0], a[2]) for a in cc]}")
    check("pre-crash: codex/pi/omp refs are wrapperClaim placeholders (True)",
          len(scrape) >= 8 and all(a[2] for a in scrape),
          f"{[(a[0], a[2]) for a in scrape]}")


def crash(topo: Topology, sig=signal.SIGKILL):
    """kill -9 the tagged instance; assert the dirty sentinel remains (never
    promoted to clean) and no clean sentinel was written."""
    topo.h.stop(sig)
    dirty = os.path.exists(S.DIRTY_SENTINEL)
    clean = os.path.exists(S.CLEAN_SENTINEL)
    check("after kill -9: dirty sentinel remains", dirty,
          f"dirty={dirty} clean={clean} ({S.DIRTY_SENTINEL})")
    check("after kill -9: no clean sentinel", not clean, S.CLEAN_SENTINEL)


def settle_and_classify(h: S.MultiKindHarness, expected: int,
                       timeout: float = 30.0):
    """Poll `conversation list --json` after a relaunch until the store holds
    >= `expected` surfaces AND the classification counts are stable across two
    consecutive reads (seed → scrape → reclassify have settled). Returns the
    oracle rows."""
    deadline = time.time() + timeout
    prev_sig = None
    rows = []
    while time.time() < deadline:
        convs = S.read_conversations(h.cli_path).get("conversations", [])
        rows = S.oracle_table(convs)
        sig = tuple(sorted((r["classification"], r["cwd"]) for r in rows))
        if len(rows) >= expected and sig == prev_sig:
            return rows
        prev_sig = sig
        time.sleep(1.0)
    return rows


def kinds_resolved(rows):
    """Set of kinds with at least one RESOLVED surface."""
    return {r["kind"] for r in rows if r["classification"] == S.RESOLVED}


def rows_for_cwd(rows, cwd):
    return [r for r in rows if r["cwd"] == cwd]


# --------------------------------------------------------------------------- #
# Scenarios.
# --------------------------------------------------------------------------- #

def scenario_all_present(h: S.MultiKindHarness):
    """RES-1 acceptance: full topology, every session present. Every surface
    must be RESOLVED or (for the adversarial pair) HONEST_DIAGNOSTIC; zero FAIL,
    zero UNRESOLVED."""
    print("\n== all-present (ACCEPTANCE) ==")
    h.reset_persistence()
    h.launch()
    topo = Topology(h)
    ready, count = topo.build_panes()
    check("all shims reached READY", ready >= len(PANES), f"ready={ready}")
    check("store holds all refs pre-crash", count >= len(PANES), f"count={count}")
    topo.write_fixtures()
    assert_precrash_snapshot(topo)

    crash(topo)
    h.launch(no_resume=True)
    rows = settle_and_classify(h, expected=len(PANES))
    counts = S.print_oracle_table(rows, "all-present")

    check("acceptance: >=12 surfaces observed", len(rows) >= 12, f"{len(rows)}")
    check("acceptance: zero FAIL (no silent fresh-launch)",
          counts.get(S.FAIL, 0) == 0)
    check("acceptance: zero UNRESOLVED (every session present ⇒ resolved)",
          counts.get(S.UNRESOLVED, 0) == 0)

    kr = kinds_resolved(rows)
    for kind in ("claude-code", "codex", "pi", "omp"):
        check(f"acceptance: >=1 {kind} surface RESOLVED", kind in kr, f"resolved={kr}")

    # Adversarial same-cwd codex pair → both HONEST_DIAGNOSTIC (ambiguous).
    adv_cwd = topo.cwd_for("codex-adv")
    adv = rows_for_cwd(rows, adv_cwd)
    check("adversarial: same-cwd codex pair present (2 surfaces, 1 cwd)",
          len(adv) == 2, f"rows={len(adv)}")
    check("adversarial: same-cwd codex pair is HONEST_DIAGNOSTIC (ambiguous)",
          len(adv) == 2 and all(r["classification"] == S.HONEST_DIAGNOSTIC
                                and "ambiguous" in (r["detail"] or "")
                                for r in adv),
          f"{[(r['classification'], r['detail']) for r in adv]}")

    # Floor test: pi1's cwd resolves to pi1's OWN fresh id (stale sibling was
    # dropped by the claim-time floor; otherwise it would be ambiguous).
    pi1 = topo.by_label["pi1"]
    pi1_rows = rows_for_cwd(rows, pi1["cwd"])
    check("floor: pi1 (stale+fresh) resolves to its fresh id (stale dropped)",
          len(pi1_rows) == 1
          and pi1_rows[0]["classification"] == S.RESOLVED
          and pi1_rows[0]["id"] == pi1["sid"],
          f"{[(r['classification'], r['id']) for r in pi1_rows]} want id={pi1['sid']}")

    h.stop()


def scenario_missing_transcript_per_kind(h: S.MultiKindHarness):
    """One session omitted per kind. The claude-code surface → HONEST_DIAGNOSTIC
    ("transcript not found"); the scrape-primary surfaces (codex/pi/omp) → a
    SAFE UNRESOLVED placeholder (no on-disk session ⇒ id never resolves, resume
    skips). Crucially: still zero FAIL, and every other surface resolves."""
    print("\n== one-transcript-missing-per-kind ==")
    h.reset_persistence()
    h.launch()
    topo = Topology(h)
    topo.build_panes()
    # Starve exactly one surface per kind (pi0, not pi1, so pi1 keeps its
    # floor-test role).
    omit = {"cc3", "cx1", "pi0", "omp1"}
    topo.write_fixtures(omit=omit)
    assert_precrash_snapshot(topo)

    crash(topo)
    h.launch(no_resume=True)
    rows = settle_and_classify(h, expected=len(PANES))
    counts = S.print_oracle_table(rows, "missing-per-kind")

    check("missing: zero FAIL (still no silent fresh-launch)",
          counts.get(S.FAIL, 0) == 0)

    # Targeted expectations.
    cc3 = rows_for_cwd(rows, topo.by_label["cc3"]["cwd"])
    check("missing: starved claude-code → HONEST_DIAGNOSTIC (transcript not found)",
          len(cc3) == 1 and cc3[0]["classification"] == S.HONEST_DIAGNOSTIC
          and "not found" in (cc3[0]["detail"] or ""),
          f"{[(r['classification'], r['detail']) for r in cc3]}")

    for lbl in ("cx1", "pi0", "omp1"):
        r = rows_for_cwd(rows, topo.by_label[lbl]["cwd"])
        check(f"missing: starved {lbl} → UNRESOLVED (safe placeholder skip)",
              len(r) == 1 and r[0]["classification"] == S.UNRESOLVED,
              f"{[(x['classification'], x['detail']) for x in r]}")

    # Non-starved distinct-cwd surfaces of each kind still resolve.
    kr = kinds_resolved(rows)
    for kind in ("claude-code", "codex", "pi", "omp"):
        check(f"missing: a present {kind} surface still RESOLVED", kind in kr,
              f"resolved={kr}")

    h.stop()


def scenario_clean_restart(h: S.MultiKindHarness):
    """Clean `c11 app restart`: the suspend → final-snapshot → promoteToClean
    choreography. We assert the on-disk artifacts (parity with the C11-131
    harness): the sentinel is promoted to clean and the snapshot carries
    SUSPENDED claude-code refs (codex/pi/omp remain wrapperClaim placeholders
    pre-restart — they only resolve at the next restore's scrape). Kept last-ish
    because `app restart`'s `open -n` self-relaunch can leave a lingering
    instance."""
    print("\n== clean app restart ==")
    h.reset_persistence()
    h.launch()
    topo = Topology(h)
    topo.build_panes()
    topo.write_fixtures()

    restart = h.cli("app", "restart")
    check("app restart accepted", restart.returncode == 0, restart.stderr.strip())
    S.wait_socket_gone(h.cli_path, timeout=20)
    time.sleep(2)
    S.kill_tagged_instances()   # reap the self-relaunched instance

    clean = os.path.exists(S.CLEAN_SENTINEL)
    check("app restart promoted sentinel to clean", clean, S.CLEAN_SENTINEL)

    suspended = []
    try:
        snap = json.load(open(S.SNAPSHOT_PATH))
        for w in snap.get("windows", []):
            for ws in w["tabManager"]["workspaces"]:
                for p in ws["panels"]:
                    a = (p.get("surface_conversations") or {}).get("active")
                    if a and a.get("kind") == "claude-code":
                        suspended.append(a.get("state"))
    except Exception:
        pass
    check("clean restart: claude-code refs are suspended in snapshot",
          len(suspended) >= 4 and all(s == "suspended" for s in suspended),
          f"states={suspended}")

    S.kill_tagged_instances()


def scenario_double_kill(h: S.MultiKindHarness):
    """RES-3 idempotency: a second kill -9 with no clean quit between must not
    resurrect a ref to a wrongly-resumable state, crash-loop, or fresh-launch.
    Build once, crash+observe, then crash the relaunched instance again and
    re-observe: still zero FAIL, app healthy."""
    print("\n== double kill -9 (idempotent) ==")
    h.reset_persistence()
    h.launch()
    topo = Topology(h)
    topo.build_panes()
    topo.write_fixtures()
    assert_precrash_snapshot(topo)

    crash(topo)
    h.launch(no_resume=True)
    rows1 = settle_and_classify(h, expected=len(PANES))
    c1 = S.print_oracle_table(rows1, "double-kill cycle 1")
    check("double kill cycle 1: zero FAIL", c1.get(S.FAIL, 0) == 0)
    tree1 = h.cli("tree", "--json")
    check("double kill cycle 1: app healthy", tree1.returncode == 0)

    # Second kill -9 (dirty again), no clean quit between.
    h.stop(signal.SIGKILL)
    check("double kill: dirty sentinel remains after 2nd kill",
          os.path.exists(S.DIRTY_SENTINEL))
    h.launch(no_resume=True)
    rows2 = settle_and_classify(h, expected=1)   # ref set may shrink; be lenient
    c2 = S.print_oracle_table(rows2, "double-kill cycle 2")
    check("double kill cycle 2: zero FAIL (idempotent, no silent resurrection)",
          c2.get(S.FAIL, 0) == 0)
    tree2 = h.cli("tree", "--json")
    check("double kill cycle 2: app healthy after 2nd relaunch",
          tree2.returncode == 0)
    h.stop()


def scenario_kill_switch(h: S.MultiKindHarness):
    """RES kill switch: relaunch with CMUX_DISABLE_CONVERSATION_STORE=1. The
    store is inert — layout restores, nothing resumes, no error, and
    `conversation list --json` reports is_disabled=True."""
    print("\n== kill switch (CMUX_DISABLE_CONVERSATION_STORE=1) ==")
    h.reset_persistence()
    h.launch()
    topo = Topology(h)
    topo.build_panes()
    topo.write_fixtures()
    h.cli("state", "save")
    h.stop(signal.SIGKILL)

    h.launch(disable_store=True)
    time.sleep(6)
    tree = h.cli("tree", "--json")
    check("kill switch: app healthy after restore", tree.returncode == 0,
          tree.stderr.strip())
    clist = h.cli("conversation", "list", "--json")
    try:
        disabled = json.loads(clist.stdout).get("is_disabled", False)
    except Exception:
        disabled = False
    check("kill switch: conversation store reports disabled", disabled is True,
          clist.stdout[:200])
    h.stop()


# clean_restart runs last: its `app restart` self-relaunch (open -n) can leave a
# lingering instance that races the next scenario's launch. Keeping it last
# contains the blast radius (mirrors the C11-131 harness ordering).
SCENARIOS = [
    scenario_all_present,
    scenario_missing_transcript_per_kind,
    scenario_double_kill,
    scenario_kill_switch,
    scenario_clean_restart,
]


def main():
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    S.kill_tagged_instances()
    h = S.MultiKindHarness()
    print(f"app:    {h.app}")
    print(f"socket: {S.SOCKET_PATH}")
    print(f"run:    {h.run_dir}")
    try:
        for fn in SCENARIOS:
            if only and not any(o in fn.__name__ for o in only):
                continue
            # Hard isolation between scenarios: settle the socket + process
            # table before the next launch (rapid repeated GUI launches race).
            S.kill_tagged_instances()
            try:
                os.remove(S.SOCKET_PATH)
            except OSError:
                pass
            time.sleep(2.0)
            try:
                fn(h)
            except Exception as e:
                FAILED.append(fn.__name__)
                print(f"  [FAIL] {fn.__name__} raised: {e}")
                try:
                    h.stop(signal.SIGKILL)
                except Exception:
                    pass
    finally:
        h.cleanup()
    print(f"\n{len(PASS)} passed, {len(FAILED)} failed")
    if FAILED:
        print("FAILED:", ", ".join(FAILED))
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
