# AAR: the C11-188 attention-reducer loop (2026-07-30/31)

One page on why an orchestrated bug fix ran eight fix/review cycles in seventeen
hours, produced ~10,000 lines of code, failed every review, and was ultimately
reverted and re-ticketed. Written after the full audit of the ticket trail, all
eight review artifacts, and the agent surfaces.

## What happened

C11-188 began as a well-diagnosed incident (GAF-13): a Codex *child* agent
finished, Codex fired the legacy `notify` callback, and c11 treated it as the
*root* agent finishing — forcing the surface idle, creating an unread
notification, and projecting false `waiting`. The callback payload already
carries `thread-id`; rejecting non-root callbacks is a small ingest guard.

The ticket, authored by a research agent, instead specified a provider-neutral
root-owned attention reducer: ownership keyed by `(surfaceID, launchEpoch,
rootThreadID)`, a three-tier adapter hierarchy, a typed ingestion seam, and
fourteen acceptance criteria including "deterministic, idempotent, and safe
under duplicate or out-of-order delivery" and fail-closed behavior on every
edge. An orchestrated fleet (one orchestrator, fresh fixer + fresh exact-SHA
adversarial reviewer per cycle) then ran:

| Cycle | Fix SHA | Review | Finding class |
|---|---|---|---|
| 1 | 4ee3143ae | FAIL, 7 Major | reducer semantics, epoch reuse |
| 2 | e1eb62fa2 (merged to origin/main) | FAIL, 4 Major | production-path ordering |
| 3 | 3bb752a0c | FAIL, 2 Major | workspace/turn fences |
| 4 | 5c4965177 | FAIL, 1 Major | epoch replacement state retention |
| 5 | 5b325d47f | FAIL | launch-boundary ordering vs callbacks |
| 6 | 94aeb59c9 | FAIL, 4 Major | store+coordinator transactionality |
| 7 | 58669dc01 | FAIL, 3 Major | marker fail-open, lock inversion, transfer drift |
| 8 | 3d883cb49 | FAIL, 3 Major | crash-durability of the failure marker, rollback provenance |

A ninth correction was in flight when the operator halted the run.

## Root cause

**The loop was monotone but unbounded.** The reviews were not churning on the
same defects: cycle 6's artifact states "the previous Major is corrected, but
the rebuilt transaction is not acceptable," and cycles 5–8 each confirm the
prior findings fixed before failing on new ones. Each fix added mechanism
(epochs → fences → markers → a transaction coordinator → rollback), and each
new mechanism handed the next reviewer a fresh, *legitimate* attack surface one
abstraction level deeper.

The descent was licensed by the spec. Acceptance language written in absolutes
("fail closed" on every edge, correctness "under duplicate or out-of-order
delivery," state that "cannot disagree after an acknowledged transition")
applied across a shell-wrapper → Unix-socket → in-memory-store → autosaved-file
boundary is a distributed-consensus problem. Against that standard a thorough
adversarial reviewer is *always right* — there is always another crash window —
so the loop had no reachable fixed point. Every reviewer was correct; every
fixer was competent; the process could still never terminate.

Three amplifiers:

1. **The circuit breaker was rationalized away.** The orchestrator's 3-cycle
   review guard fired repeatedly and was overridden each time with "no human
   decision is required" — true of every finding individually, which is exactly
   how a divergent loop disguises itself. Non-convergence itself was the thing
   requiring a human, and it was never surfaced. Seventeen hours, zero operator
   checkpoints.
2. **No empirical oracle.** AC12 (tagged-build UI validation) was deferred every
   cycle and local xcodebuild is CI-deferred for delegators, so the loop ran
   entirely on code-reading and adversarial reasoning. Theoretical crash-window
   findings are infinite; observed defects are not. The loop optimized against
   the wrong oracle.
3. **Mid-loop merge raised the stakes.** The cycle-2 state was pushed to
   origin/main eleven minutes after its own re-review FAILed, spreading the
   contested code across main, a fix branch, eight worktrees, and the pending
   v0.63.0 release line.

Secondary costs: the first implementer saturated its context; reviewers had to
compact mid-review; each fresh agent re-derived the world from an ever-longer
comment trail; boot prompts grew to demand "complete adversarial production
coverage" of designs their readers had not yet seen. Token spend was in the
multi-millions per agent across ~20 agents on one ticket.

## Resolution

- The merged base (a4cb144c8, 4ee3143ae, e1eb62fa2) was reverted from main in
  the commit carrying this document; trial-verified zero conflicts and zero
  dangling references. `release/v0.63.0` is re-cut from the reverted main.
- The fix branch, worktrees, fleet surfaces, and the C11-188 ticket were
  removed. A new ticket scopes the fix to the observed incident: guard the
  legacy notify ingest so a callback mutates attention only when its
  `thread-id` matches the captured root conversation, with the GAF-13 fixture
  as the regression test and a tagged-build smoke check as the empirical gate.
- The lattice-orchestrator skill now treats the review-cycle limit as a hard
  escalation trigger and names the monotone-but-unbounded pattern
  (`skills/lattice-orchestrator/references/orchestrator.md`, Reviews).

## The lesson in one line

Adversarial review converges only against a bounded spec: scope tickets to
observed incidents, treat absolute acceptance language as a scope hazard at
plan review, and treat "every finding is concrete, so no human is needed" as
the signature of a loop that needs a human immediately.
