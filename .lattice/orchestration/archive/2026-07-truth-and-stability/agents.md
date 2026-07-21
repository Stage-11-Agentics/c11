# Agents — Truth & Stability run

Active table (overwritten each tick; Lattice + `c11 tree` are ground truth):

| Role | Ticket | Surface ref | Pane ref | Branch | Worktree | Phase | Last seen | Spawned at |
|---|---|---|---|---|---|---|---|---|
| Orchestrator | — | surface:149 | pane:48 | — | main checkout | dispatch loop | boot | 2026-07-07 |
| Master Validator | — | surface:158 | pane:48 | — | main checkout | audit loop | tick 66 | 2026-07-07 |
| Result Validator | — | surface:151 | pane:49 | — | main checkout | auditing validation-plan rows | spawn 08:20 | 2026-07-07 |
| RES delegator (Opus) | C11-164 | surface:162 | pane:57 | (post-merge) ts/res-crash-resume | (post-merge) | planned; awaiting RESUME | tick 24 | 2026-07-07 |

### Archived (run history)

| Actor | Ticket | Outcome | Notes |
|---|---|---|---|
| agent:ts-res-delegator | C11-164 | pr_open (PR #321) | RES-1 acceptance recorded: 49/0 (10 resolved / 2 honestly-ambiguous / 0 fail, 4 kinds). Fixed COR-flagged SurfaceActivityTests in scope; flagged TerminalAndGhosttyTests break (→C11-166). Twice-green rerun blocked by locked screen (disclosed + harness now aborts on lock). ~3h dispatch→pr_open, longest ticket. Surface closed. |
| agent:ts-tel-delegator | C11-162 | pr_open (PR #320) | All TEL rows delivered; c11-logic 1223/0; real-artifact smoke gate passed; 13 keys × 6 locales localized. Visual proofs deferred (locked macOS session defeats screencapture even after caffeinate -u — verified) → operator post-merge smoke w/ tel-scenarios.sh recipe. Seam: emitLivenessTransition left unwired on purpose (EVT #318 unmerged), one-line wiring documented at site. Surface closed. |
| agent:ts-cor-delegator | C11-165 | pr_open (PR #319) | All COR rows PASS on tagged cor-post (empty-ref matrix, flood 34ms, hang.log clean). Deliberate behavior change: ref-less external writes now error (skill synced). Flagged pre-existing SurfaceActivityTests break (relayed to RES). Own-reviewer fallback (empty-diff bug, 3rd occurrence). Surface closed. |
| agent:ts-evt-delegator | C11-163 | pr_open (PR #318) | First Wave 2 finisher (~55 min impl→pr_open). All EVT rows PASS w/ recorded proof + real-artifact smoke launch; latency 267ms. Seam decisions logged: liveness.derived stub for TEL, waiting.* second seam, pane metadata deferred. Own-reviewer fallback (auto review empty-diff base bug). Surface closed. |
| agent:ts-dx-delegator | C11-159 | done (merged) | Keystone. PR #317 squash-merged 09:06Z by orchestrator; ~2h05m dispatch→pr_open. TC 20351→8774 LOC, 20 handler units, parity subset identical, review PASS. Anomalies: boot turn killed by 429 (nudged); stray commit onto parent checkout main (MV caught tick 9-10, orchestrator cherry-pick+reset remediation, path discipline corrected). |
| agent:ts-web-delegator | C11-161 | done (merged) | PR #316 squash-merged 07:58Z by orchestrator; ~70 min dispatch→pr_open incl. one MAJOR fix cycle (dangling i18n keys). Method index 231==231; discovery finds c11 binary; rebased onto #315 cleanly. Deploy-time operator flags in PR body. |
| agent:ts-hyg-delegator | C11-160 | done (merged) | PR #315 squash-merged 07:25Z by orchestrator; ~37 min dispatch→pr_open. c11-logic 1183/0. Anomaly: #250 eslint-10 auto-merge broke bun lint (CI has no eslint job) — delegator self-caught and reverted via #314; footgun logged + memory filed. Branch inventory (87 local/164 remote) awaits operator. |
