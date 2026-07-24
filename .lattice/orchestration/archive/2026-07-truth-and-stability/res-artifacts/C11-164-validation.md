# C11-164 Crash-Resume — Validation Report

**Ticket:** C11-164 (RES-1..RES-5) · Truth & Stability cycle · branch `ts/res-crash-resume`
**Build:** tagged `res-post` (`com.stage11.c11.debug.res.post`)
**Validation bar:** tagged build + recorded live kill-9 scenario proof.

## RES-2 scope trace (each subsystem changed → the scenario need that required it)

| Subsystem changed | Why the scenario required it | File(s) |
|---|---|---|
| SurfaceActivityTracker snapshot persistence (G2) | codex/pi/omp scrape disambiguation filters on `mtime ≥ activity floor`; the floor was in-memory only and lost on restart, and `contexts(from:)` hardcoded it nil — so a restored scrape ran with no floor. The stale+fresh pi pair (pi1) exercises it. | `SessionPersistence.swift`, `Workspace.swift`, `AppDelegate.swift`, `ScrapeCapturePipeline.swift` |
| Codex real-cwd recovery (G3) | codex stores sessions flat; the scraper stamped the querying surface's cwd on every candidate → the cwd filter was a no-op → distinct-workspace codex sessions all read as mutually ambiguous and none resumed. The distinct-cwd codex surfaces (cx0/cx1) require it to RESOLVE; the same-cwd pair (cxADVa/b) requires it to STAY honestly ambiguous. | `Scrapers/ClaudeCodeScraper.swift` (CodexScraper + `ConversationFilesystem.readSessionHead`), `Strategies/Codex.swift` |
| references/conversation.md rewrite (RES-5) | doc described the now-shipped machinery as unlanded v1.1 items | `skills/c11/references/conversation.md` |

**Not touched (not exercised → out of scope, per RES-2):** forced-final-scrape-at-quit and a separate dirty-gated forced scrape (the restore-time scrape already runs unconditionally and resolved every present session — no scenario row needed them); opencode scraper registration (pi/omp satisfy the "+1 of pi/omp/opencode" clause with margin); the global on-disk conversation index.

## RES-1 — the force-kill scenario (recorded)

Harness: `tests_v2/test_crash_resume_multikind_e2e.py` (+ `crash_resume_support.py`).
Topology: **12 conversations / 12 workspaces / 4 kinds** (claude-code ×4, codex ×4, pi ×2, omp ×2), incl. an adversarial same-cwd codex pair and a stale+fresh pi pair.
Oracle: per-surface store state from `c11 conversation list --json` (auto-resume disabled), classified RESOLVED / HONEST_DIAGNOSTIC / UNRESOLVED / FAIL. **Zero silent fresh-launches** = zero FAIL.

### Acceptance run (all-present) — per-surface table
```
RESOLVED=10  HONEST_DIAGNOSTIC=2  UNRESOLVED=0  FAIL=0
  10 × RESOLVED         suspended + "crash recovery: transcript verified on disk"
                        (all 4 claude-code, codex cx0 + cx1, both pi, both omp)
   2 × HONEST_DIAGNOSTIC codex same-cwd pair → "ambiguous: 2 candidates; chose newest"
```
Every kind has ≥1 RESOLVED surface; the adversarial same-cwd codex pair is honestly ambiguous (not silently fresh-launched); pi1 (stale+fresh) resolves to its own fresh id (floor dropped the stale sibling).

## RES-3 — repeatable harness, twice consecutively green

- **Full run (all 5 scenarios): 49 passed, 0 failed** — recorded (`harness-full-run1.log`), captured while the operator's screen was UNLOCKED. Scenario variants all green: all-present (acceptance), one-transcript-missing-per-kind (starved surfaces → honest diagnostic / safe placeholder; zero FAIL), double kill-9 (idempotent, zero FAIL both cycles), kill switch (store disabled cleanly), clean `app restart` (suspended refs + clean sentinel).
- **Second consecutive full run: environmentally blocked in-session.** After that run the operator stepped away and the macOS screen LOCKED (`CGSSessionScreenIsLocked: True`), which restricts the window server so the tagged c11 GUI can't materialise workspaces — every surface then reads `ready=0` regardless of `caffeinate`. This is an operator-state blocker, not a code/harness defect: the single-pane end-to-end pipeline test passed on the FINAL build while the screen was unlocked, and the harness passed 49/0 earlier. The harness now aborts up front on a locked screen with an actionable message (`require_unlocked_screen()`), so the reconfirmation is a trivial re-run with the screen unlocked (operator at merge, or the Result Validator in a fresh session). **Recommended reconfirm:** `caffeinate -d -i python3 tests_v2/test_crash_resume_multikind_e2e.py` (twice), screen unlocked.

## Code review

Own-reviewer pass (the lattice `code-review` saw an empty working-tree diff since all work is committed; used the boot's own-reviewer fallback). All Swift changes CLEARED (G2/G3 logic, the `candidates(cwd:recoverCwd:)` overload + protocol conformance, `readSessionHead` safety, back-compat field, the SurfaceActivityTests fix). Oracle confirmed to catch regressions (no false-green) with no operator-session-damage path. Two harness findings, both false-**red** (flakiness) only: #1 per-scenario READY-baseline reset (FIXED, commit 635aa2dba); #2 shared-run_dir fixture accumulation (NIT, confirmed safe by the claim-time floor — left as-is).

## RES-4 — no regression to existing suites

- c11-logic conversation/resume logic suites: **45 tests green** (ConversationCrashRecovery, WorkspaceConversationResume, ConversationStrategy, + others).
- New Tier-1 tests: **17 green** (activity-floor round-trip + CodingKeys-trap guard, contexts floor threading, codex real-cwd recovery, distinct-cwd resolves / same-cwd ambiguous, parseCodexCwd edge cases).
- Existing claude-only `test_crash_resume_e2e.py` left untouched.
- Host `c11Tests` target: validated in CI (pre-existing local-toolchain compile errors in unrelated host files — identical to origin/main, green in CI).

## RES-5 — docs

`skills/c11/references/conversation.md` rewritten to post-cycle truth (crash-recovery guarantee per kind, codex real-cwd disambiguation, landed-vs-open list); installed skill synced via `scripts/sync-installed-skills.sh c11`.

## Operator spot-check checklist (RES-1 operator-assisted half — for the merge decision)

The autonomous recorded proof above gates `pr_open`. For the live spot-check at/after merge:
1. Build the tagged app: `./scripts/reload.sh --tag res-post`.
2. Run the harness: `python3 tests_v2/test_crash_resume_multikind_e2e.py` — expect `49 passed, 0 failed`.
3. Eyeball one live run: after the acceptance scenario's relaunch, `c11 conversation list --json` should show 10 `suspended` (verified) + 2 `unknown` (ambiguous) — the 2 ambiguous are the same-cwd codex pair (the workspace whose cwd ends `…/ws/codex-adv`); that pair is the deliberate honest-diagnostic case, everything else resumes.
4. (Optional, real agents) force-quit your real working c11 with live claude/codex sessions and relaunch — confirm they come back or show a specific diagnostic.

_Overlaps the C4 Result-Validator's operator smoke checklist — this is the RES-specific slice; do not double-run._
