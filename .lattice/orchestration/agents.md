# Agents — Exact-session resume run

Live join of "what's running where." Refreshed by the Orchestrator each tick. Lattice + c11 remain authoritative for live state.

## Active

| Role | Ticket | Surface | Pane | Branch | Worktree | Phase | Spawned |
|------|--------|---------|------|--------|----------|-------|---------|
| Orchestrator | — | surface:110 | pane:38 (Main View Area) | — | main checkout | dispatch | start |
| Master Validator | — | surface:113 | pane:38 (Main View Area) | — | — | audit | start |
| Lattice Board | — | surface:111 | pane:39 (Control Surface) | — | — | browser @ :55068 | start |
| Result Validator | — | surface:126 | pane:38 (Main View Area) | — | main checkout | Phase 4 audit | run-complete |

## Pending (Wave 2 — press-ahead off C11-152's branch once it hits review/pr_open)

| Role | Ticket | Depends on | Branch base |
|------|--------|------------|-------------|
| Delegator | C11-153 (pi) | C11-152 | feat/c11-152-scrape-capture (press-ahead) |
| Delegator | C11-154 (omp) | C11-152 | feat/c11-152-scrape-capture (press-ahead) |

## Infra
- Lattice dashboard: PORT 55068, log /tmp/lattice-dashboard-55068.log

## Auto-merges
| Ticket | PR | Merge SHA | Notes |
|---|---|---|---|
| C11-152 | #273 | e6edf9513 | Squash. `--auto` merged immediately (no required-check branch protection); CI `build` PASSED on main after (clean). 7 pipeline + 14 regression green, MV-confirmed. |
| C11-151 | #274 | 60646a3ac | Squash. Merge gated on CI `build` green (pbxproj-touching) — build passed (5m6s), then merged. LOAD-BEARING row 1 satisfied (observed live opencode re-attach, base62 fix proven). Delegator rebased onto 152 seam + resolved pbxproj conflict pre-merge. |
| C11-153 | #275 | 678098587 | Squash. Merge gated on CI build green — passed (4m59s). LOAD-BEARING row 6 satisfied (observed live pi exact-resume, session re-rendered). Delegator self-rebased onto merged 151+152. Sound deviation: cwd-scoped PiScraper. |
| C11-154 | #276 | cf177868 | Squash (merge by MV on operator instruction; orchestrator owns completion). CI build green (4m54s). Row 7 satisfied SINGLE-SESSION-ONLY (live omp 'Welcome back!' of 019f111a in a clean cwd). **CORRECTION (Phase-4 RV finding GAP 1): the OmpScraper whole-tree ambiguity bug the MV flagged was NOT actually fixed in merged code — candidates(cwd:) still walks the whole tree (cwd only stamps the candidate); no cwd-slug branch like PiScraper. omp is single-session-only as shipped → follow-up C11-156.** Delegator rebased onto merged 151+153 (registry union + pbxproj via xcodeproj gem). |

## Archived (run history)
| Actor | Ticket | Outcome | Notes |
|---|---|---|---|
| agent:delegator-c11-152 | C11-152 | done | Merged PR #273 @ e6edf9513. Live scrape-capture pipeline (the missing restore seam). Validation rows 4+5 satisfied; live-agent resume deferred to pi/omp by design. own-reviewer fallback used (CLI empty-diff bug). Surface:114 closed. Public seam documented for 153/154. |
| agent:delegator-c11-151 | C11-151 | done | Merged PR #274 @ 60646a3ac. opencode exact-resume via plugin rail. LOAD-BEARING row 1 satisfied (observed live re-attach to ses_…U/O, base62 fix). 26 c11-logic green + I/L/O/U guard. own-reviewer fallback (CLI empty-diff). Rebased onto 152 seam, pbxproj resolved. Surface:112 closed. Caveat: time_updated didn't advance (OpenRouter credits, external). |
| agent:delegator-c11-153 | C11-153 | done | Merged PR #275 @ 678098587. pi exact-resume (PiScraper cwd-scoped + PiStrategy). LOAD-BEARING row 6 satisfied (live pi --session re-render, no caveat). 17 c11-logic green, parity verified. own-reviewer fallback. Self-rebased onto merged main. Surface:117 closed. |
| agent:delegator-c11-154 | C11-154 | done | Merged PR #276 @ cf177868. omp exact-resume (OmpScraper + OmpStrategy). Row 7 satisfied SINGLE-SESSION-ONLY (live 'Welcome back!' resume in a clean cwd). 19 c11-logic green. own-reviewer fallback. Self-rebased onto merged main (union of 3 strategies). Surface:118 closed. **CORRECTION (Phase-4 RV): OmpScraper whole-tree ambiguity NOT fixed in merged code despite the mid-run 'fixed' claim — follow-up C11-156.** Flagged C11-155 (bun-detection).** |
