# Seat: Journal Spec Astra

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Journal Spec Astra
- **Actor:** `agent:astra-journal`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-journal` (branch `c11-1.0/C11-272-journal-spec`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `journal`

## Queue
1. **C11-272** (P1, spec): write the SQLite lifecycle journal spec as the C11-272 plan. Then **C11-273** (P1, store/append/fold/replay) plan, after the C11-272 spec has passed its plan review. You will implement C11-273 in build mode.

## C11-272 specifics
- The spec covers everything in BACKLOG.md J1: vocabulary (cmux kinds plus `turn.interrupted`, `source` with a confidence rank); ordering (app-assigned sequence plus source occurrence time; **Astra's counterexample must pass**: Stop gets 10, a late PreToolUse gets 11, the agent must not flip back to working); store (SQLite WAL in App Support, system libsqlite3, idempotent `event_id`); retention by time and byte budget; privacy (no prompt or tool bodies); honest states (`unknown`, `disconnected`, `degraded`); replay (on relaunch repaint only blocked and error, shown unconfirmed); migration (keep writing `activity` so sidebar, ⌥V and suppression are untouched). Also the NDJSON export (D3) and the analytics questions J7 must answer (time in state, wait-for-operator, blocked minutes, turns/hour, errors/interrupts, stall outliers), so the schema serves them.
- Read report `01-event-journal.md`, `feature-audit-astra.md` §4, `feature-audit-fable.md` §4, and upstream `Packages/macOS/CmuxAgentJournal/` (upstream remote is `upstream`; read with `git show upstream/main:<path>`, fetch `upstream` if needed, never push to it).
- The fixture corpus (C11-271) is being captured in parallel by another seat. Name the incidents the spec must satisfy by the C11-271 list (bypass AskUserQuestion/ExitPlanMode, late async PreToolUse after Stop, Esc interrupt, restart while waiting, sibling tool start clearing another tab's waiting, the C11-189 child-completion case). The fixtures will be at `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-fixtures` when ready; do not wait on them to write the spec.
- **This is the one ticket with an independent plan review** (Grok, one cycle). Write the spec so a reviewer can attack it: decisions explicit, every acceptance criterion tied to a named incident or analytics question, no absolute fail-closed language, mechanism proportionate (read the C11-188 AAR twice; the ack/spool/drain design must not become C11-188's markers under new names). After you store the plan, set status planned (no auto review) and send PLANNED; the Orchestrator launches the reviewer and sends you the findings once. Re-review happens only if the findings change the architecture.
- Plan C11-273 only after the spec review is resolved.
