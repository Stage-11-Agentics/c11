# Plan review: C11-272 SQLite lifecycle journal spec (one cycle)

You are the **independent cross-family plan reviewer** for C11-272 in the c11 1.0 release run. The spec was written by a GPT-6-Astra owner; you are Grok. You are **read-only**: do not edit any file in any worktree, do not commit, do not mint tickets, do not message anyone but the Orchestrator.

## Setup
1. `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`; actor `agent:grok-review-272`.
2. Name your tab: `c11 rename-tab --tab "$C11_TAB_ID" "C11-272 Spec Review"`; description: `c11 set-description --tab "$C11_TAB_ID" $'Reviewing the journal spec once; next, post the review and verdict.\nLineage: c11 1.0 Orchestrator → C11-272 Spec Review'`.
3. Send `REVIEWING C11-272 PLAN <sha256 of the plan file> BASE 0ff8887e5e` to the Orchestrator (mailbox below) before you start.

## Read
- The spec: `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`.
- The ticket: `lattice show C11-272` (and C11-273, C11-277 for downstream needs).
- `docs/aar-c11-188-attention-loop.md` (read it carefully: this review exists because of it).
- `upstream-triage/c11-1.0/BACKLOG.md` J1, J2, J7 and the D1/D3 rulings; `feature-audit-astra.md` §4 (late-event counterexample); `feature-audit-fable.md` §4; `01-event-journal.md`. These are in `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/`.
- Code the spec cites, in the read-only worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-journal` (origin/main `0ff8887e5e`). Verify citations rather than trusting them.

## What to judge (one substantive pass)
1. **Bounded, not C11-188 again.** Is every acceptance criterion tied to a named incident, fixture or analytics question? Any absolute "fail closed / exactly-once / never disagree across every boundary" language? Does the receipt/spool/drain design re-create C11-188's epochs, fences, markers or transaction coordinator under new names? Is the mechanism proportionate to the observed incidents?
2. **Astra's counterexample:** Stop gets seq 10, a late async PreToolUse gets 11; the agent must not flip back to working. Does the fold rule actually guarantee this, and without breaking a genuinely new turn that starts after Stop?
3. **Rulings honored:** SQLite WAL in App Support with system libsqlite3 + NDJSON export (D3); no prompt/tool bodies; honest `unknown`/`disconnected`/`degraded`; replay repaints only blocked/error, unconfirmed; `activity` keeps being written so sidebar, ⌥V and suppression are untouched; no tenant config writes (doctrine; C11-278 is the only amendment); no blocking bridge (D6); transcript edges advisory (D4).
4. **Hot paths and threading:** append off main, serial writer queue, fold applied main-async; nothing on the keystroke path; autoreleasepool on any long-lived loop.
5. **Analytics:** can the schema answer J7's questions (time in state, wait-for-operator, blocked minutes, turns/hour, errors/interrupts, stall outliers) by agent, model, workspace and window?
6. **Buildability:** is C11-273 implementable from this spec in one ticket, with a clear cut line to C11-274..277?

Do not rewrite the spec. Do not hunt theoretical crash windows that no named incident or analytics question needs; that is exactly the failure mode the AAR describes.

## Output
Write the review to a file, then: `lattice comment C11-272 --file <review.md> --role review --actor agent:grok-review-272` (if `--role review` is rejected, drop `--role`). Structure: verdict; **Blocking** findings (numbered, each with spec section, evidence, and the smallest fix); **Non-blocking** findings; and one line stating whether any blocking fix would **change the architecture** (this decides whether a re-review happens).

Then send exactly one line: `VERDICT C11-272 PASS|FAIL <plan sha256> <comment event id>` and stop.

Mailbox: `c11 send --workspace 8D68EE13-823E-44FF-B2DE-611FFD7BDA7F --tab E588D406-2E13-4581-A349-4EB46BA26639 "<line>"`. No other messages. No Claude subagents.
