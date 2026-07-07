# Truth & Stability Cycle — BUILDPLAN

Execution plan for the SPEC in this directory. Operator decisions (2026-07-06 interview) baked in; the Orchestrator's Phase 0 collapses to surface-and-confirm.

## Run configuration (operator-decided, finalized 2026-07-07)

- **Orchestrator:** Opus instance, dedicated new workspace. Delegators: **Opus everywhere** (all seven tickets). Launch: immediately on operator sign-off; run continuously, overnight included.
- **Autonomy: Fully Autonomous.** The orchestrator decides architectural forks, scope calls, and dependency questions itself and logs every decision with rationale to run-state's append-only decision log. Only genuinely destructive or irreversible actions (force-push, data deletion, anything outside the repo) park as `needs_human`.
- **Attention protocol: never interrupt.** No mid-run pings. Checkpoint digests (C1-C4) are written to run-state and a markdown surface, not pushed at the operator. Blocked work parks as `needs_human` and the run continues around it. One consolidated report plus a single notification at run end.
- **Waves:** two, hard barrier. Wave 2 branches cut only after DX merges (everything in Wave 2 touches the dispatched command surface; building on the extracted base avoids four-way conflicts inside a 20k-line file).
- **Concurrency:** Wave 1 N=3, Wave 2 N=4 (one delegator per ticket). **Build lock: at most 2 concurrent xcodebuild/test invocations across the run** (orchestrator-managed; the operator is working on this machine).
- **Merge policy:** the orchestrator **merges Wave 1 tickets itself**, gated on validation artifacts + CI green + (for DX) the recorded parity baseline, then moves them to `done` with review artifacts recorded in-flow. **Wave 2 tickets stop at `pr_open`** for operator merge. `pr_open` requires a validation-role artifact per board config; `done` requires a review-role artifact.
- **Recovery ladder:** two failed fix attempts by a delegator → fresh-context captain with a handoff brief; captain failure → park as `needs_human` with a full state writeup; the run continues around parked tickets.
- **Master Validator:** on. **Result Validator:** on (fresh session, runs the pre-merge-static rows of EVALUATION.md).
- **Validation bar (every ticket):** tagged build + recorded live scenario proof, not CI-green alone.

## Tickets

| # | Ticket | SPEC IDs | Wave | Mode | Depends on |
|---|---|---|---|---|---|
| 1 | Extract socket dispatch from TerminalController into per-domain handlers (mechanical, zero behavior change) | DX-1..5 | 1 | inline-full | — |
| 2 | Repo hygiene: untrack node_modules, resolve dependabot queue, stale-branch inventory | HYG-1..3 | 1 | fast-track | — |
| 3 | Public-surface truth: web/ rebrand, CONTRIBUTING fix, socket API reference rewrite, ROADMAP stub, tests_v2 binary discovery | WEB-1..5 | 1 | inline-full | — |
| 4 | Telemetry truth: metadata age + decay, PTY-derived liveness, stale takeover, waiting-agent cluster restyle | TEL-1..8 | 2 | sub-agent-full | 1 |
| 5 | Events stream: NDJSON event log, v1 taxonomy, rotation, `c11 events tail`, envelope schema | EVT-1..8 | 2 | inline-full | 1 |
| 6 | Crash-resume completion: the force-kill scenario as the acceptance gate, scrape rail wired, repeatable harness | RES-1..5 | 2 | sub-agent-full | 1 |
| 7 | P0 correctness: empty-ref rejection everywhere, main-thread socket-path elimination, flood regression test | COR-1..4 | 2 | inline-full | 1 |

Notes for the Orchestrator:
- Ticket 1 is the keystone: prioritize it; tickets 2 and 3 are conflict-free with it and each other (different file sets: repo metadata / web+docs / Sources).
- Tickets 4, 5, 7 all touch the extracted handler layer and metadata store; worktrees isolate them, but the Orchestrator should watch the TEL↔EVT seam (EVT-2 consumes TEL's derived-liveness transitions; if 5 lands before 4, the derived-transition event type lands behind a stub and 4 completes it — an acceptable, logged seam).
- Ticket 6 mostly lives in Sources/Conversation/ and Resources/bin/; its dispatcher contact is small but it still waits for Wave 2 per the barrier decision.
- Ticket 4 folds in `docs/c11-waiting-agent-cluster-plan.md` — the delegator must read that plan as a design input, and the plan doc should be committed as part of the ticket.
- Localization pass (6 locales) per CLAUDE.md for any ticket adding user-facing strings (4 certainly; 5 and 7 possibly).
- Each Wave 2 ticket's boot prompt must name its SPEC IDs, the EVALUATION rows it owes, and the tagged-build-plus-scenario-proof bar.

## Checkpoints

1. **C1 (Wave 1 done):** DX merged to main, HYG and WEB at `pr_open` or merged. Gate: baseline parity run recorded (DX-2), CI green.
2. **C2 (Wave 2 dispatched):** four delegators live on rebased worktrees.
3. **C3 (Wave 2 terminal):** all tickets at `pr_open` with validation artifacts.
4. **C4 (Result Validation):** fresh-session validator walks EVALUATION pre-merge-static rows, writes `.lattice/orchestration/validation-report.md` + operator smoke checklist.
5. **C5 (Operator):** merges, runs the post-merge smoke checkpoints (EVALUATION bottom), and the closeout audit routes lessons.

## Follow-on (chartered, not in this cycle)

Local-model scrollback observation layer; events socket-subscribe channel; mailbox Stage 3; README register pass + Show HN assets (operator-collaboration track); remote/c11d second act (later this year).
