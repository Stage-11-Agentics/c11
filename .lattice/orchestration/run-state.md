# Run state — Truth & Stability cycle (2026-07)

**Started:** 2026-07-07
**Orchestrator:** agent:ts-orchestrator (Fable, surface:149 "T&S Orchestrator", workspace:14 "T&S Run")
**Contract:** `docs/cycles/2026-07-truth-and-stability/` (SPEC.md · EVALUATION.md · BUILDPLAN.md · ORCHESTRATOR-PROMPT.md)
**Base:** `main` @ `b0f9120b2` (contains required `d81d1df4a`)

## Configuration

| Setting | Value |
|---|---|
| Autonomy | **Fully Autonomous** — decisions logged below; only destructive/irreversible actions park `needs_human` |
| Fleet | Opus delegators (`claude-opus-4-8`), one per ticket, own worktree each |
| Concurrency | Wave 1 N=3 · Wave 2 N=4 · **hard wave barrier: no Wave 2 branch until C11-159 is merged to main** |
| Merge policy | Orchestrator merges **Wave 1** (gates: validation artifact recorded + CI green on PR + for C11-159 the tests_v2 parity baseline pre/post per DX-2), then `done`. **Wave 2 stops at `pr_open`** — operator merges |
| Git remote (verified) | `origin` = https://github.com/Stage-11-Agentics/c11.git (upstream = manaflow, read-only, NEVER push) |
| Terminal pre-merge status | `pr_open` (config: `pr_open` requires a `validation`-role artifact; `done` requires a `review`-role artifact) |
| Status vocabulary | backlog → in_planning → planned → in_progress → review → in_validation → pr_open → done (+ blocked/cancelled) |
| plan_review_mode / review_mode | triple / inline (board config; delegators invoke headless reviews with `--mode single` per skill) |
| Master Validator | ON (5-min loop, global audit) |
| Result Validator | ON (fresh session after C3; walks validation-plan.md pre-merge-static rows) |
| Auto-close finished surfaces | ON |
| Attention protocol | **Never interrupt the operator.** No pings/flashes mid-run. Checkpoint digests written here + markdown surface. One notification at run end |
| Build lock | Lattice resource **`xcodebuild`** (res_01KWXMXMA2R65PYT0N5SBE3Q7W), max-holders 2, TTL 1800s. Acquire (`--wait`) before ANY xcodebuild/test invocation; heartbeat every ~10 min while held; release immediately after |
| Recovery ladder | 2 failed fix cycles → fresh-context captain w/ handoff brief → on captain failure park `needs_human` + full writeup; run flows around parked tickets |
| Validation bar | Every ticket: tagged build + recorded live scenario proof attached to the ticket. CI green necessary, never sufficient |

## Workspace panes (c11 refs)

| Role | Ref |
|---|---|
| workspace | workspace:14 "T&S Run" |
| main_view_area (Orchestrator + validators) | pane:48 (surface:149 = Orchestrator) |
| control_surface | pane:49 (surface:151 shell · surface:155 Lattice Board browser) |
| delegate_view_1 | pane:50 (seed surface:152) |
| delegate_view_2 | pane:51 (seed surface:153) |
| delegate_view_3 | pane:52 (seed surface:154) |
| lattice_dashboard_port | 56516 (log: /tmp/lattice-dashboard-56516.log) |

Soft cap 15 surfaces per delegate pane; route new spawns to the lightest-loaded pane.

## Tickets in scope

| Ticket | Title (short) | SPEC IDs | Wave | Mode | Status | Branch | Worktree | Depends on |
|---|---|---|---|---|---|---|---|---|
| C11-159 | Dispatcher extraction (keystone) | DX-1..5 | 1 | inline-full | done (PR #317 merged) | ts/dx-dispatcher-extraction | c11-worktrees/dx-dispatcher-extraction | — |
| C11-160 | Repo hygiene | HYG-1..3 | 1 | fast-track | done (PR #315 merged) | ts/hyg-repo-hygiene | c11-worktrees/hyg-repo-hygiene | — |
| C11-161 | Public-surface truth | WEB-1..5 | 1 | inline-full | done (PR #316 merged) | ts/web-public-surface | c11-worktrees/web-public-surface | — |
| C11-162 | Telemetry truth | TEL-1..8 | 2 | sub-agent-full | backlog | (cut after 159 merges) | — | C11-159 |
| C11-162 | Events stream | EVT-1..8 | 2 | inline-full | backlog | (cut after 159 merges) | — | C11-159 |
| C11-162 | Crash-resume completion | RES-1..5 | 2 | sub-agent-full | backlog | (cut after 159 merges) | — | C11-159 |
| C11-162 | P0 correctness | COR-1..4 | 2 | inline-full | backlog | (cut after 159 merges) | — | C11-159 |

Wave 2 branch bases: `origin/main` post-DX-merge (never the in-review DX branch — barrier is at merge, per operator config; press-ahead applies to *planning* only).

## Checkpoints

- [x] **C1** (2026-07-07 09:06Z) — DX merged (#317 @ 16c9c2d2a); HYG merged (#315); WEB merged (#316); DX-2 parity recorded (subset deviation logged); CI green on all three. Wave 1: 3/3 done, zero parked.
- [x] **C2** (2026-07-07 09:14Z) — four Wave 2 delegators in_progress on worktrees cut from 16c9c2d2a; TEL/RES in sub-agent-full impl, EVT/COR inline-full. Planning phase completed pre-merge via press-ahead (zero barrier wall-clock lost).
- [x] **C3** (2026-07-07 12:04Z) — all four Wave 2 tickets at pr_open with validation artifacts: #318 EVT, #319 COR, #320 TEL, #321 RES. Zero parked tickets; zero captains needed. Merge-order note: TEL and RES both touch SessionPanelSnapshot/SurfaceActivity (RES additive/namespaced) — second merge may need a trivial reconcile.
- [ ] **C4** — Result Validator report at `.lattice/orchestration/validation-report.md`
- [ ] **C5** — operator merges Wave 2, runs post-merge smoke checklist, closeout audit

## Coordination notes

- TEL↔EVT seam: EVT-2 consumes TEL's derived-liveness transitions. If C11-163 reaches the seam first, it lands the event type behind a stub and C11-162 completes it. Log the seam decision either way.
- C11-162 delegator must read `docs/c11-waiting-agent-cluster-plan.md` as a design input.
- Localization pass required for any new user-facing strings (C11-162 certainly; 163/165 possibly).
- Merge/dispatch decisions key off `git`/`gh` truth, never delegator claims.

## Decision log (append-only)

- 2026-07-07 [autonomy: full] Archived stale `.lattice/orchestration/` contents from the 2026-06-28 exact-resume run to `archive/2026-06-28-exact-resume/` — this run needs a clean orchestration root; prior artifacts preserved.
- 2026-07-07 [autonomy: full] Build lock implemented as Lattice resource `xcodebuild` with `--max-holders 2 --ttl 1800` (native support beats a hand-rolled lock dir; TTL protects against dead holders, heartbeat covers long builds).
- 2026-07-07 [autonomy: full] Wave 1 delegators reuse the three seed surfaces (152/153/154) in the delegate panes rather than spawning extra tabs — fewer surfaces, same isolation (worktrees carry the real isolation).

- 2026-07-07 [autonomy: full] HYG-2 outcome accepted: 6 dependabot PRs merged; #250 (eslint 9→10) was merged on green CI then reverted by the delegator via #314 after discovering CI runs no eslint (web-typecheck is tsc-only) and eslint 10 fatally breaks `bun run lint`. Verified reverted on origin/main (8a98f0f7e). Delegator's self-correction accepted as resolution "closed with reason".
- 2026-07-07 [autonomy: full] Confirmed `bun run lint` is red on BASE main (5 pre-existing no-html-link-for-pages errors in web/app) — predates this cycle, not a HYG regression. WEB delegator informed FYI-only; fixing them is optional, not scope.
- 2026-07-07 [autonomy: full] C11-160 merge order ahead of C11-161: both touch CONTRIBUTING.md; HYG is ready first, WEB rebases onto post-merge main before its PR.
- 2026-07-07 [autonomy: full] C11-161 PR #316 carries operator flags in its body (confirm public domain / feedback inbox / legal entity+contact / PostHog key / Stage 11 social handles before DEPLOY; env contract changed). Judged deploy-time concerns, not merge blockers — merge proceeds on CI green; flags surfaced in closeout report for the operator.
- 2026-07-07 [autonomy: full] TEL visual proofs (TEL-2/6/7 screenshots) were deferred by the delegator — display asleep at 6am, screencapture black. Accepted as an environmental limitation with unit-proof + repro-script compensation, then bounced the delegator once with the caffeinate -u display-wake recipe to attempt the capture anyway. pr_open stands regardless; felt-tier judgment was always post-merge smoke.
- 2026-07-07 [autonomy: full] C11-159 DEVIATIONS ACCEPTED (PR #317): (1) DX-2 parity evidence is a host-safe dispatch-representative tests_v2 subset (full-suite VM runner pkills c11 and c11-vm unreachable while operator works) — same-env before/after identical pass/fail + reason-types, disclosed in PARITY docs; full-suite coverage remains CI/VM territory; Result Validator will inspect row 2 accordingly. (2) v1 dispatch relocated wholesale into SocketDispatch.swift, not decomposed per-domain — judged consistent with DX-5's "no deeper redesign"; per-domain units exist for all 20 v2 domains. (3) Own-reviewer fallback after code-review CLI empty-diff quirk — per playbook. (4) Pre-existing browser.wait env-hang flagged, fails identically at baseline, out of scope. (5) No rebase: diff disjoint from #315/#316.
- 2026-07-07 [autonomy: full] PRESS-AHEAD FIRED at C11-159 → review: judged the extraction diff structurally stable (mechanical relocation; the Sources/SocketHandlers/ seam Wave 2 codes against is settled). Spawned all four Wave 2 delegators in PLANNING-ONLY mode: scratch-sandbox cwd, read-only view of the DX branch, plans to the board, hard stop at `planned` awaiting RESUME IMPLEMENTATION. Wave barrier intact — no branch cut until DX merges. Spawns staggered 15s (429 lesson).
- 2026-07-07 [autonomy: full] STRAY-COMMIT REMEDIATION (C11-159): DX delegator edited and committed extraction work (5d7689da8) in the PARENT checkout, landing on local main. Froze delegator, cherry-picked onto ts/dx-dispatcher-extraction (b7e4364f3), moved WIP ThemeHandlers.swift into the worktree, soft-reset main checkout to b0f9120b2 with per-file restore (no reset --hard — live .lattice board state must never be clobbered). Backup ref dx-stray-backup kept until PR merge. Credit: Master Validator caught it within two audit ticks.

## Run-time footguns

(rows added during dispatch: symptom → cause → mitigation)

| Symptom | Cause | Mitigation |
|---|---|---|
| All delegators showing `429 Rate limited · Retrying (attempt N/10)` at boot | 4 Opus sessions + orchestrator started in the same minute; 5h usage window ~55% with high projection | Claude Code auto-retries; watch for sessions that exhaust 10/10 attempts and nudge them with a `send` "retry and continue" + enter. Stagger future spawns if it recurs |
| Delegator source edits/commits land in the PARENT checkout (local main gains an un-gated commit; feature branch missing work) | Delegator used absolute parent-repo paths for Sources/ edits — the prompt's LATTICE_ROOT guidance ("absolute parent path for .lattice writes") bled into source-file paths | Boot prompts for Wave 2 add: source paths are ALWAYS worktree-absolute or cwd-relative; pre-commit guard `git rev-parse --show-toplevel` == worktree path. Recovery recipe: freeze → cherry-pick to branch → per-file restore + reset --soft on main (never --hard; .lattice is live) |
| Auto `lattice code-review` returns empty diff for worktree delegators | The review CLI resolves the parent checkout, not the invoking worktree, as diff base | Own-reviewer fallback per playbook (worked 3/3: DX, EVT, COR). PROMOTED: file upstream Lattice ticket at closeout — this is a Lattice bug, fix at source per code/CLAUDE.md |
| New c11 surface accepts `send` (OK) but `send-key`/`read-screen` fail "Surface not ready"/"not found"; PTY never wires | Surface-init wedge on late-run surface creation (post-churn); text sends vanish into an unwired terminal | Probe with `read-screen` before trusting a fresh surface; on wedge, close it and reuse an established surface (Control shell worked). Candidate c11 bug ticket at closeout |
