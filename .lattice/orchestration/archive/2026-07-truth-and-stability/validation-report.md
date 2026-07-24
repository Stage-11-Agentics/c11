# Validation Report — Truth & Stability cycle (2026-07)

Source spec: [SPEC.md](../../docs/cycles/2026-07-truth-and-stability/SPEC.md)
Source build plan: [BUILDPLAN.md](../../docs/cycles/2026-07-truth-and-stability/BUILDPLAN.md)
Source validation plan: [validation-plan.md](./validation-plan.md)
Result Validator: agent:ts-result-validator (fresh session, surface:151)
Date: 2026-07-07
Run completed: 2026-07-07T12:15Z (C3 terminal @ 12:04Z; #321 compat-tests green @ 12:15Z)

## Summary

- Total pre-merge-static criteria audited: **38**
- ✅ Pass: **32**
- ⚠️ Partial: **6**
- ❌ Fail: **0**
- ⛔ Blocked: **0**
- Post-merge-smoke rows staged for operator: 6 (§ Operator smoke-pass checklist)

**Overall verdict: 🟢 GREEN, with a thin amber band.** Every spec *capability* criterion is satisfied in code and CI is green on all seven PRs. All six Partials are **proof-completeness gaps, not code defects**: deferred visual/recorded proofs (a 6am autonomous run hit an asleep-then-locked display, so `screencapture` returned black frames) plus one literal pass-condition miss (RES-3 wants two consecutive green harness runs; only one is on record, the second blocked by the same locked screen). No spec criterion was left unimplemented, no ticket was abandoned, zero tickets parked `needs_human`. The residual items are one post-merge wiring one-liner (TEL↔EVT seam), a naming-residue cleanup deferred by design, and re-running two locked-out proofs — none block merge.

## Per-criterion results

### Wave 1 — DX / HYG / WEB (PRs #317, #315, #316 — all MERGED, CI green)

| # | ID | Result | Notes |
|---|---|---|---|
| 1 | DX-1 | ✅ Pass | No dispatch switch in TerminalController.swift; **15** handler units under `Sources/SocketHandlers/` (SocketDispatch.swift + 14 domain files) ≥ 6. |
| 2 | DX-2 | ✅ Pass (deviation accepted) | `PARITY-baseline-8a98f0f7e.md`: same 14-test host-safe subset, same 4 pass / 10 env-fail, same reason-types pre/post. Primary oracle = c11-logic full suite green + CI green. Full-suite parity is VM/CI territory (the canonical runner pkills c11); subset disclosed in the artifact. |
| 3 | DX-3 | ✅ Pass | Net `DispatchQueue.main.sync` in Sources unchanged (base 13 == head 13, counted independently at merge-base vs head). The one added `main.sync` is the relocated general-dispatch fallback; telemetry intercepted off-main earlier (C11-156). |
| 4 | DX-4 | ✅ Pass | TerminalController.swift = **8774 LOC** (< ~10k); largest new handler BrowserHandlers.swift = **1942 LOC** (< ~3k). |
| 5 | DX-5 | ✅ Pass (deviation accepted) | 400 removed `case` == 400 added, sorted-unique sets identical → pure relocation, zero renames/response changes. v1 switch relocated wholesale into SocketDispatch.swift (884 LOC) — logged scope call, consistent with "no deeper redesign." |
| 6 | HYG-1 | ✅ Pass | `git ls-tree -r origin/main \| grep -c node_modules` = **0**; `.gitignore:41`; CI green. |
| 7 | HYG-2 | ✅ Pass | Zero open dependabot PRs; 6 merged, #250 (eslint 9→10) merged-then-reverted via #314 (revert on main @ 8a98f0f7e) with reason. |
| 8 | HYG-3 | ✅ Pass | `docs/cycles/.../branch-inventory.md` (284 lines): local 87 / remote 164, last-commit date + author + ahead/behind + merged-status; explicit "No branches deleted." |
| 10 | WEB-1 | ✅ Pass | Only manaflow hit under web/ is the deliberate lineage blog link; PostHog is env-driven third-party analytics (empty key, `us.i.posthog.com`). See Drift for `cmuxterm_*` analytics-name residue (scoped out, not a WEB-1 miss). |
| 11 | WEB-2 | ✅ Pass | `CONTRIBUTING.md:24` → `Stage-11-Agentics/c11.git`; remaining manaflow refs are deliberate lineage. |
| 12 | WEB-3 | ✅ Pass | JSON-RPC/NDJSON framing documented (`socket-api-reference.md:31-33`); static count 142 source vs 143 doc entries (delegator live-`capabilities` cross-check 231==231); two `cmux` hits are deliberate compat-alias docs. |
| 13 | WEB-4 | ✅ Pass | `ROADMAP.md` present at repo root; `PHILOSOPHY.md:3` reference resolves. |
| 14 | WEB-5 | ✅ Pass | `tests_v2/cmux.py:86 find_cli_binary()` prefers c11 (override → last-path → build dirs), `cmux` legacy fallback only; discovery-log artifact exists (0.0s c11 resolution). |

### Wave 2 — TEL (PR #320, OPEN, CI green)

| # | ID | Result | Notes |
|---|---|---|---|
| 15 | TEL-1 | ✅ Pass | Last-updated timestamp stamped + precedence-gated (`SurfaceMetadataStore.swift:100,484`), survives snapshot (`SessionPersistence.swift:344,414`); `MetadataSourceTimestampTests` (4 tests) in c11LogicTests green-1223. Coverage is store-level XCTest, not a tests_v2 socket test (get_metadata ts exposure is pre-existing infra). |
| 16 | TEL-2 | ⚠️ Partial | Code PASS: defaults `300`/`900`s = **5m/15m** (`SidebarStalenessSettings.swift:27-28`), env overrides + Settings sliders → operator-tunable; fresh/stale/expired classifier present. **Visual half deferred** (three-state screenshots not captured — display asleep). |
| 18 | TEL-3 | ✅ Pass | `.derived` precedence **1** < `.explicit` **4**; `SurfaceLivenessDeriver.reconcile` only touches derived-owned keys, never clobbers fresh explicit (`SurfaceLivenessDeriver.swift:124-137`). Scripted proof = `tel-scenarios.sh` Scenario B (live transcript deferred; precedence crux fully code-verified). |
| 19 | TEL-4 | ⚠️ Partial | Code PASS: `SidebarActivityProjector.project()` explicit<expiry → explicit pill, ≥expiry → derived-takeover pill `isDerived==true`, visually distinct (gold-stroke), re-report heartbeat auto-resumes explicit. **Distinct-pill screenshot deferred.** |
| 20 | TEL-5 | ✅ Pass | hitTest/forceRefresh files not in diff; decay clock added to **child** subview only, `TabItemView ==` untouched, no new observed/binding props; one coarse 30s clock, no `main.sync`. Work moved *out* of the fast path. |
| 21 | TEL-6 | ⚠️ Partial | All 4 design elements present on branch (`ContentView.swift:10598`): two-row cluster, "Waiting Agent" rename, lit-state inversion (paperFill + gold hairline), prev/next arrows. **Tagged-build screenshot comparison deferred.** Note: diff adds only rename+inversion; two-row/arrows scaffold pre-existed on main (disclosed). |
| 23 | TEL-7 | ⚠️ Partial | Both scenarios scripted in `tel-scenarios.sh` (A: status→silence→decay→derived flip; B: never-report + output → derived working). **Recordings (transcript + screenshots) NOT attached** — deferred. Pass condition requires attached recordings → Partial. |
| 24 | TEL-8 | ✅ Pass | `skills/c11/references/metadata.md`: `activity` key + new "Liveness, age & decay" section documenting age/decay + derived tier; `sync-installed-skills.sh` run noted. |

### Wave 2 — EVT (PR #318, OPEN, CI green)

| # | ID | Result | Notes |
|---|---|---|---|
| 25 | EVT-1 | ✅ Pass | `spec/event-envelope.v1.schema.json` requires seq/ts/type/instance/v; live NDJSON (evt-post-47917) carries all + optional refs (nil omitted) + payload, seq monotonic 1→33, RFC3339-Z ts; `EventEnvelope.serialize` sortedKeys. |
| 26 | EVT-2 | ⚠️ Partial | **All emit sites wired in code** (surface.created/closed, workspace.selected, metadata.changed+tier, waiting.entered/left on 0↔1 edge, mailbox.accepted/delivered; liveness.derived = accepted TEL seam). **Recorded run shows only 5 members firing** — `workspace.selected` and `waiting.*` absent from attached artifacts despite live workspace switching. Report's "every member observed live" overstates the proof; those two are code-verified, not run-verified. |
| 27 | EVT-3 | ✅ Pass | `EventLog` writes on dedicated serial `.utility` queue, `append` mutates counters under lock then fire-and-forget `queue.async`; bounded `maxPending=4096` drop-newest → `log.dropped`. Stall-injection test floods 500 appends behind a pinned queue, asserts <1s + drop marker. |
| 28 | EVT-4 | ✅ Pass | `rotate()`: 8 MiB cap, rolls →`.ndjson.1` (one generation retained), writes `log.rotated` marker as first line, seq continues (not reset). Test asserts `.1` exists + marker + rolledSeq < currentSeq. |
| 29 | EVT-5 | ✅ Pass | `runEventsTail` implements `--follow` (rotation/inode-aware), `--filter type=`, `--since` (seq + duration), pre-socket. Report records the CLI matrix on tagged build. |
| 30 | EVT-6 | ✅ Pass (thin artifact) | `latency-result.txt` = `267 ms => PASS` (<1s); methodology stated, corroborated by `reactions.log` wall-clock stamps. Caveat: artifact is a one-line result, not a raw dual-timestamp breakdown (computation lives in the harness). |
| 31 | EVT-7 | ✅ Pass | `reactions.log` is a real `events tail --follow` consumer log: status change (metadata.changed key=status), mailbox delivery, surface close all present with per-event "consumer REACTED" reactions. |
| 32 | EVT-8 | ✅ Pass | PR #318 diff carries **both** `spec/event-envelope.v1.schema.json` (+ README + fixtures) **and** `skills/c11/references/events.md` (location/schema/taxonomy/CLI) + SKILL.md link; installed copy synced. |

### Wave 2 — RES (PR #321, OPEN) / COR (PR #319, OPEN, CI green)

| # | ID | Result | Notes |
|---|---|---|---|
| 33 | RES-1 | ✅ Pass | `C11-164-harness-49pass-run.log`: **12 surfaces / 12 distinct cwds / 4 kinds** (claude-code×4, codex×4, pi×2, omp×2). RESOLVED=10, HONEST_DIAGNOSTIC=2 (same-cwd codex pair, honest ambiguity), UNRESOLVED=0, FAIL=0. Exceeds ≥10/≥3/≥3-incl-cc+codex; per-surface table present; zero silent fresh-launches. |
| 35 | RES-2 | ✅ Pass | `C11-164-validation.md` §RES-2 scope-trace maps each changed subsystem → scenario need → files, with explicit "not touched → out of scope" list + justification. No unscoped work. |
| 36 | RES-3 | ⚠️ Partial | Harness in PR (`tests_v2/test_crash_resume_multikind_e2e.py` + `crash_resume_support.py`), documented. **Only ONE full green run (49/0) recorded**; 2nd blocked by `CGSSessionScreenIsLocked` (locked-screen env, not code). Twice-green pass condition not met on record. |
| 37 | RES-4 | ✅ Pass | 45 existing + 17 new resume logic tests green; `ci.yml:196` c11-logic in build job → SUCCESS; **#321 compat-tests SUCCESS @ 12:15Z** (validation-plan's/prompt's "pending" was stale). All #321 checks green. |
| 38 | RES-5 | ✅ Pass | `skills/c11/references/conversation.md` new "Crash recovery — guarantees per kind" section: contract + per-kind breakdown (claude-code/codex/pi/omp/opencode/grok) + codex real-cwd disambiguation. |
| 39 | COR-1 | ✅ Pass | `SocketSurfaceRefValidator` classifies absent/empty → `missing_ref`/`empty_ref`, no focus fallback; wired at 6 v2 sites + v1 setStatus/appendLog/setProgress + CLI stops client-side focus resolution. Recorded matrix: all 6 v2 methods × empty/whitespace/absent + no-stomp control PASS; CLI absent PASS. All 10 commands code-wired; 7/10 have a recorded live rejection (v1 trio proven by logic test + wiring — see What I couldn't verify). |
| 40 | COR-2 | ✅ Pass | `skills/c11/SKILL.md` + `references/metadata.md`: footgun rewritten (missing/empty ref rejected not fallback; all 10 commands enumerated; explicit `--surface` recommended); sync noted. |
| 41 | COR-3 | ✅ Pass | `notes/c11-165-mainthread-sweep.md` addresses all 3 genres: pane.confirm + feedback.submit (semaphore→worker + nonisolated), browser nested CFRunLoopRun → sliced `CFRunLoopRunInMode`. Post-sweep 0 CFRunLoopRun in dispatch layer. Recorded flood: 31 probes worst 37ms, hang.log clean. |
| 42 | COR-4 | ✅ Pass | Both tests in #319 diff: `SocketSurfaceRefValidatorTests` (11 logic cases, green in CI via c11-logic) + `test_cor3_socket_flood_mainthread.py` (green on tagged cor-post). #319 CI fully green. |

## Drift from BUILDPLAN.md

- **TEL↔EVT derived-liveness seam is a live post-merge wiring task.** EVT (#318) shipped the `liveness.derived` event *type* in the schema enum plus `EventEmitter.emitDerivedLiveness(...)` as a **stub with no call site**; TEL (#320) *deliberately* left the hookup unwired ("referencing it here would break `main`"). Both sides logged this as an accepted seam. Consequence: once #318 merges, someone must add the one-line call at `SurfaceLivenessDeriver.emitLivenessTransition(...)` or derived-liveness transitions will silently never emit as events (EVT-2 taxonomy member stays dark). This is the single functional follow-up the run leaves open — track it explicitly, don't let the "accepted seam" framing bury it.

- **DX v1 dispatch relocated wholesale, not sliced per-domain (DX-5).** The 20 v2 domains got their own handler units; the v1 switch moved intact into `SocketDispatch.swift` (884 LOC). Judged consistent with DX-5's "no deeper redesign," and it is — flagged only so a future reader isn't surprised the v1 path didn't get the per-domain treatment.

- **DX-2 parity is a host-safe subset, not the full tests_v2 suite.** Full-suite parity is VM/CI-only (the canonical runner pkills c11 and the operator was on the machine). The recorded before/after covers a 14-test dispatch-representative subset with identical results; c11-logic-full + CI-green carry the primary parity load. Acceptable and disclosed, but the full-suite tests_v2 parity claim is a CI/VM assertion, not something reproduced in-ticket.

- **`cmuxterm_*` analytics-name + cmux product-prose residue under web/.** WEB-1 was scoped to manaflow *domains/keys*; the cmux→c11 *branding* prose (PostHog event names `cmuxterm_download_clicked`/`cmuxterm_github_clicked`, locale product-name strings) was deferred to a separate naming-residue item. Not a WEB-1 failure, but a live branding remnant on the public surface the operator may want tracked (contradicts the [[feedback_cmux_to_c11_naming]] direction if left).

- **Infra gaps disclosed, orthogonal to code:** (a) the Lattice `code-review` CLI returns an empty diff for worktree delegators (resolves the parent checkout, not the worktree) — own-reviewer fallback used on DX/EVT/COR, promote to an upstream Lattice bug per code/CLAUDE.md; (b) the board's auto plan-review reviewer-pane spawn failed in the crowded orchestrator workspace (TEL), substituted by a two-lens own-review.

## Gaps

**No spec capability criterion is unsatisfied by an open or merged PR.** Every DX/HYG/WEB/TEL/EVT/RES/COR spec ID is implemented in code with CI green. The only literal pass-condition not met on record is **RES-3's "two consecutive green runs"** — one green run (49/0) is recorded; the second was blocked by a locked screen, not a code fault. This is a proof gap, not a capability gap.

## Recommendations

- **Post-merge wiring (do not skip):** after #318 merges, wire the TEL↔EVT `emitDerivedLiveness` call site (one line). Until then, `liveness.derived` events never fire despite the type existing. This is the run's one open functional thread.
- **New tickets:**
  - Upstream Lattice bug — `code-review` empty-diff for worktree delegators (promised at closeout in run-state; file it).
  - Naming-residue cleanup — `cmuxterm_*` PostHog event names + cmux product prose under web/ → c11.
  - RES-3 reconfirm — trivial screen-unlocked re-run to bank the second green harness run (or accept one run as sufficient; operator call).
- **Accept-as-is (validator's strict reading, operator may ratify):** DX-5 wholesale v1 relocation; DX-2 subset parity; all six deferred visual/recorded proofs (felt-tier judgment was always post-merge smoke per the run contract — the code mechanisms are all independently verified).
- **Merge-order note (from C3, still applies):** TEL (#320) and RES (#321) both touch `SessionPanelSnapshot`/`SurfaceActivity` (RES additive/namespaced); the second of the two to merge may need a trivial reconcile. Both PRs also flag a pre-existing base break in `c11Tests/SurfaceActivityTests.swift` — #321 fixes it in-scope, #319 flags it out-of-domain; consistent, not a conflict.

## What I couldn't verify

- **Lattice file-artifact raw bodies** aren't retrievable via the CLI (only titles + comment `data.body`). WEB-5's raw discovery-log *lines* and some validation-file *contents* were verified by their code + artifact existence/title, not by reading the recorded bytes.
- **Runtime/visual proofs** (TEL screenshots, TEL-7 scenario recordings) were deferred to the locked-display limitation — verified the code mechanisms, not the rendered pixels. These land in the operator smoke pass below.
- **COR socket-level tests_v2** (`test_cor1_*`, `test_cor3_*`) run on the c11-vm lane; **no GitHub CI workflow executes them** (only `mailbox-parity.yml` touches tests_v2). Their "green" is operator-attested tagged-build (cor-post) output, not a PR gate. The `SocketSurfaceRefValidatorTests` logic half *does* run in CI. So COR-1/3's socket evidence for the v1 trio (set-status/set-progress/log) is logic-test + code-wiring, not a recorded live socket rejection.
- **EVT-2** `workspace.selected` and `waiting.*` are code-verified (emit sites confirmed) but **not present in any recorded-run artifact** — the "every member observed live" claim is not fully evidenced.
- **Contract-author feedback:** several rows say "recorded run green" without specifying which lane (CI vs VM vs tagged-local); next cycle, name the expected evidence lane per row so "green" isn't ambiguous. And rows whose pass condition hinges on a screenshot should carry an explicit fallback ("if display capture unavailable, code-path proof + repro script suffices for pre-merge; visual defers to smoke") so the validator isn't forced to invent the Partial verdict.

## Operator smoke-pass checklist (post-merge)

Run after merging Wave 2. The Result Validator did not attempt these — they require a merged tree or human felt-tier judgment.

| # | ID | Verification method | Artifact to inspect | Pass condition |
|---|---|---|---|---|
| 9 | HYG-3b | Operator reviews inventory and decides deletions | inventory artifact (`docs/cycles/.../branch-inventory.md`) | Operator call |
| 17 | TEL-2b | Operator judges decay rendering + thresholds by living with it | merged build | Feels right (felt) |
| 22 | TEL-6b | Operator judges cluster restyle at a glance | merged build | Earns its place (felt) |
| 34 | RES-1b | Operator force-quits real session once and relaunches | merged build | Everything comes back |
| 43 | Smoke-1 | Live with new sidebar for a day (decay feel, derived-pill trust) | merged build | Operator judgment (felt) |
| 44 | Smoke-2 | `c11 events tail --follow` open during a normal day: signal or noise? | merged build | Operator judgment (felt) |

Additional smoke-pass items surfaced by this audit (not original plan rows, but worth folding in):
- After #318 merges and the TEL↔EVT call site is wired, confirm `c11 events tail --filter type=liveness.derived` actually emits when a pane goes silent → derived.
- Re-run `test_crash_resume_multikind_e2e.py` once with the screen unlocked to bank RES-3's second green run.
