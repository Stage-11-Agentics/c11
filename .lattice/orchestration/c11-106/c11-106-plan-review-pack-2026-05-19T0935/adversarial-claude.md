# Adversarial Plan Review — C11-106 (C11-104 follow-ups)

- **PLAN_ID:** c11-106-plan
- **MODEL:** Claude
- **TIMESTAMP:** 20260519-0935
- **Plan under review:** `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01KS06C8QZ43D6NH203QFE3SMQ.md`
- **Parent ticket:** C11-104 (PR #181, merged at `2b1be4220` per `origin/main`)
- **Validation report consulted:** `.lattice/orchestration/c11-104/validation-report.md` (22 PASS / 6 PARTIAL / 4 FAIL / 1 CANNOT_VERIFY)

## Executive Summary

This is a tidy, well-aimed follow-up plan — every item maps to a real audit finding, the recommendations match the validator's, and the scope is plausibly one PR. **My adversarial concern is not what's in the plan; it's the architectural decision the plan flinches at.**

Section 1 frames "wire `DerivationCoordinator` into production **OR** document it as forward-looking-only" as two acceptable resolutions. That branch is the entire ticket. If we pick "wire it in," the work is ~50–100 lines of glue plus the fixture tests AC12 actually wants — but the plan never describes the glue, names a single call site beyond `TabManager.swift:1724`, or commits to a cache-invalidation strategy that will survive contact with submodules and linked worktrees. If we pick "document as forward-looking-only," we're freezing dead code in `Sources/` with a doc-comment apology, and the next ticket to add a host/SSH deriver will discover the seam is shaped for the present, not the future. Both branches have hidden commitments the plan defers to "operator's call." That's the unsigned check.

The second-biggest concern is **scope creep masquerading as cleanup**. The plan bundles six categories of work (wiring, four missing tests, enum rename, `.stale` state, dead-code deletion, optional polish, validation-plan hygiene). The enum rename alone is a search-and-replace that touches public-ish state names, `applyDerivedWorktreeBranchMetadata`, every test that mentions `.unknown`/`nil`, and the SPEC. Bundling it with a coordinator wiring change in the same PR makes the diff hard to bisect if AC33 typing-latency regression shows up post-merge. The plan inherits AC33 risk from #181 (the operator hasn't actually validated typing latency yet per the audit) and stacks more on top.

How concerned should you be? Moderate. The plan is good at what it covers; it's quiet about the things you only learn the hard way. The biggest single risk is shipping the coordinator wiring **and** the enum rename **and** the dead-code deletion in one PR, then having a post-merge regression and not knowing which change moved the needle.

## How Plans Like This Fail

Follow-up tickets to a merged feature have a characteristic failure mode: **they ride on the assumption that the parent PR's user-visible behavior is "good enough" and use that as cover to take risks the parent wouldn't have.** A few patterns to watch:

1. **The "we know what's broken so let's fix everything" trap.** The validator produced a clean list of 11 specific items. The plan picks up all of them. But each item carries its own risk surface, and the cumulative risk of one PR that touches the resolver, the coordinator, four test files, an enum used by the production probe, and the SPEC is meaningfully higher than the sum of its parts. **The classic outcome:** the PR lands, AC33 regresses subtly (paste speed in worktree panes feels worse), and bisecting between "the wiring change," "the timeout change to 2s," and "the enum rename" is painful because each one of them touched the same call chain.

2. **The "deferred-to-operator" bait-and-switch.** Section 1, section 4, and section 6 each have a "two acceptable resolutions" or "operator's call" branch. In practice, the delegator picks one without explicit confirmation, the plan-author rationalizes the choice in the PR body, and the reviewer can't tell whether the operator agreed or was bypassed. **The honest version is: the plan author should pick.** "Operator's call" only works if the operator is actually consulted; otherwise it's a way to ship without owning the decision.

3. **Cleanup creep.** Section 5 ("Confirm + delete dead code") is the most innocent-looking item and the most likely to wake up a sleeping consumer. `Workspace.orderedUniqueBranchDirectoryEntries()` was retired by AC24 — but the validator only verified "no longer called by the sidebar," not "no longer called by anyone." Persistence, snapshot capture, plan capture, the workspace title bar, the command palette, search — any of these could still reach for it, and a `grep` in `Sources/` alone won't catch a callsite in `Tests/`, in a Lattice-plugin extension point, or in the `cmux` legacy alias path. **A delete-on-grep is a destructive action; the plan should require a build + test pass on both `c11-logic` and `c11-unit` schemes after the delete, not just the grep.**

4. **The "tests for a feature already shipped" anti-pattern.** Adding AC14/16/17/20 tests now, after the code is in production, has a known psychological pull: the tests get written to match what the code does, not what the spec demanded. AC14 is the cleanest example — the plan acknowledges the implementation timeout is 5s vs spec's 2s. If the test is written first and the implementation kept at 5s, the test will assert 5s. The spec drift gets cemented rather than corrected. **The plan should commit to the spec's number or commit to a SPEC amendment, not write the test against the current value.**

5. **The validation-plan hygiene item that never happens.** Section 7 ("Annotate the v2 validation plan in-place") is a chore that competes with code work in a single PR. In practice, the delegator runs out of time, ships the code work, and the validation plan stays out of date. The next round of follow-ups re-discovers the same items. **Either bind this to a checklist in the PR template or accept that it won't happen.**

6. **The submodule-fixture rabbit hole.** AC12 wants linked-worktree + submodule fixtures touching the resolved HEAD path. Writing a real submodule fixture in a test is meaningfully harder than the plan implies — you need to `git submodule add`, commit the superproject, and either keep the fixture in-tree (huge tarball cost in repo) or build it on the fly in `setUp` (slow + flaky on CI's git version). The plan handwaves "linked-worktree + submodule fixture tests that AC12 specified" without acknowledging the fixture-building cost.

## Assumption Audit

**Load-bearing (the plan collapses without these):**

1. **PR #181 will stay merged.** The plan reads `validation-report.md` and treats #181 as a stable foundation. As of `origin/main` HEAD it is — `2b1be4220` is in the ancestry. But the local checkout this review was performed against didn't have it; that's a benign fetch lag, but it's a signal that "merged" and "on every working copy" aren't the same thing. **More substantively:** if AC33 (typing latency) bites post-merge, the operator's documented rollback per S9 is to flip `sidebarShowBranchDirectory` default to off. That doesn't revert the code; it just hides the chips. The follow-up PR's changes would still ship. But if the rollback escalates to a full PR revert, this entire follow-up's premise evaporates. **The plan never acknowledges this scenario.**

2. **`GitContextResolverCache` is the right cache primitive to wire in.** The plan assumes (a) `(cwd, mtime(headPath))` is the right cache key, (b) the existing `initialWorkspaceGitProbeQueue` is the right execution context, and (c) `DerivationCoordinator.run` is the right entry point. None of these are revisited. The validator already flagged that the cache and coordinator are "library code, not system code"; wiring them in without redesigning is a vote of confidence in shapes that were authored speculatively, not against a working integration.

3. **The four missing tests are achievable as unit tests in `c11LogicTests`.** AC14 (subprocess timeout) and AC16 (socket frame rejection) both need infrastructure that may not exist as logic-test fixtures. AC14 needs a way to stub `git` such that it sleeps — typically via `PATH` manipulation or process-injection — and verify a SIGTERM-then-SIGKILL contract within a deterministic time budget. AC16 needs the socket protocol handler exercised without a running app host. Both are doable, but **the plan treats them as small line-items**. The validator's report did the same.

4. **The enum rename is search-and-replace.** The plan says: "the cost is a search-and-replace + the AC10 stale test." But renaming `BranchValue.unknown` → `BranchValue.noBranch` and adding `GitContextKind.notInRepo` + `.stale` cases changes the **shape** of the enums consumed by `WorktreeChipProjector`, by `applyDerivedWorktreeBranchMetadata`, and by every snapshot-encode path. Adding a `.stale` case to a Swift enum forces every `switch` over `GitContextKind` to add a case or use `default`. A grep + edit can miss `where` clauses, pattern-matching in `if case let`, and any exhaustiveness check the compiler will catch but humans won't on review. **This is not a search-and-replace; it's a type-shape change with compiler-driven discovery.**

5. **The dead-code grep is sufficient.** Section 5 says "Grep for callers; if confirmed dead, delete." `Workspace.orderedUniqueBranchDirectoryEntries()` and `tab.sidebarBranchDirectoryEntriesInDisplayOrder` may have callers in Lattice plugins, in test-only code paths, in persistence migration helpers, in snapshot-restore code that runs only on cold launch, or in dynamic Swift KVC-style access. A grep does not prove absence in Swift the way it might in Python; protocol witness tables, `@objc` exposure, and KeyPath references can all dodge it.

6. **`origin/main` will accept the PR cleanly.** The follow-up's diff base is `2b1be4220`. The branch already has commits `629888044` (C11-99 Area C AAR) layered on top. Any conflicting concurrent work — particularly to `TabManager.swift`, which is a frequently-touched 5,539-line god-class — will require a merge resolution that the plan doesn't budget for.

**Not load-bearing but worth examining:**

- The plan assumes the operator agrees with the recommendations (wire it in; rename the enum). The recommendations are bold but they're still recommendations.
- The plan assumes "no regressions in `c11-logic` or `compat-tests`" is sufficient evidence of safety (AC criterion 5). It is not sufficient for typing latency — that needs an operator-driven smoke pass that the parent C11-104 ticket also deferred.

## Blind Spots

**What's absent that should be present:**

1. **No mention of the merge order against the other 3+ PRs ahead of #181.** When `validation-report.md` was written, `feat/c11-104-sidebar-chips` was "3 commits behind `main`: #178, #182, #180." Since then, #181 itself merged and `629888044` (#183) landed on top. The follow-up branch bases on a different `main` than the validator saw. Any review checklist that just says "rebase on main" misses that the surface area has shifted.

2. **No risk model for the coordinator wiring's threading contract.** `DerivationCoordinator.run` has a `dispatchPrecondition(.notOnQueue(.main))` guard. The current call site `TabManager.swift:1724` lives inside `initialWorkspaceGitMetadataSnapshot`, which is `nonisolated static`. Wiring the coordinator in means the function either (a) continues to call the resolver directly inside the static probe-queue path, with the coordinator wrapping it (in which case the precondition still passes since the probe queue is not main), or (b) the function is split, with synchronous probing handed off to coordinator-driven derivers. The plan doesn't say which. If (b), every existing caller's expectations of `initialWorkspaceGitMetadataSnapshot`'s synchrony change. **This is a structural decision, not a wiring change.**

3. **No cache-eviction policy beyond LRU.** The existing `GitContextResolverCache` has LRU. But mtime-based invalidation is fragile when (a) the operator's clock skews backward (DST, NTP correction), (b) the HEAD file is overwritten with identical mtime by `git update-ref` in fast succession, or (c) a copy operation (rsync, time-machine restore) preserves the source's mtime. The plan inherits the existing cache's invalidation strategy without examining whether it's correct for production traffic on a 64-CPU machine running 40+ panes. **At-launch all-pane probe storms are exactly when cache invalidation bugs show up.**

4. **No discussion of what the four missing tests would catch in CI that running tests don't.** AC14 (timeout) is meant to catch a regression where a future change to `ProcessGitRunner` removes or weakens the timeout — but the test as described would also break if anyone changes the timeout value, which the plan itself is contemplating. **A test that fails when the spec changes is a test of the spec, not the code.** That's not necessarily wrong, but the plan doesn't acknowledge the coupling.

5. **No mention of the `cmux` compat alias path.** c11 ships a `cmux` CLI alias. If `set_metadata` rejection (AC16) is verified through the c11 socket but not through the `cmux` alias path, the test exercises one entry point and assumes the other inherits. That assumption may hold, but it should be named.

6. **No mention of what happens to the SPEC document if the rename loses.** Section 3 offers "rename the implementation OR rewrite the SPEC." If the operator picks "rewrite the SPEC," **who owns it?** The C11-104 Lattice ticket description is the SPEC source per `validation-report.md` line 5. Editing the Lattice ticket description as a hindsight rewrite is a one-way operation — does the ticket get marked "spec amended post-merge in C11-106"? Is there an audit trail? The plan is silent.

7. **No commit-by-commit guidance.** Six categories of work in one PR is asking for a multi-commit branch where each category is its own commit. The plan doesn't say so, but if the delegator squashes, post-merge bisecting an AC33-style typing-latency regression to a specific category becomes impossible.

8. **No mention of submodule fixture cost.** As noted above, the AC12 linked-worktree + submodule fixture is a meaningful piece of test infrastructure to write. The plan budgets it as "~50-100 lines of glue + the two cache invalidation tests" but doesn't separate the glue cost from the fixture cost.

9. **No deferred-item back-pressure.** Section 4 (`.stale` state + AC10) is "decide whether to pick it up here or leave as a known-deferred edge case." Section 6 has two more optional items. Section 7 is a chore. **The plan never says: if the delegator is running long, here's the priority order to drop work.** A delegator with no priority ordering will spread time evenly across all items and ship a partial PR for each, instead of complete PRs for the high-value items.

10. **No success criteria for "documented as forward-looking-only" in section 1.** What does "documented" mean? A `///` doc-comment on `class GitContextResolverCache`? A line in `metadata.md`? Both? Does it require the validator's eyes? If the seam is dead in production code, **what stops the next agent from deleting it as dead code in the next cleanup pass?**

11. **No mention of how to validate AC33 (typing latency) for the follow-up itself.** The parent #181 had three operator-smoke ACs. This follow-up touches the same hot path (changes `applyDerivedWorktreeBranchMetadata` if the coordinator wiring lands, possibly changes the cache layer the probe runs against). It needs its own typing-latency smoke pass, not just "CI green."

## Challenged Decisions

**Decision 1: bundle 6+ categories in one PR.**
*Counterargument:* split the work. Wiring the coordinator is one PR. Adding the four missing tests is a second (and arguably safer to land first, so the wiring change has guard rails). Enum rename is a third. Dead-code deletion is a fourth. Each is reviewable independently; each is bisectable independently if something regresses; each has a coherent rollback story.
*Is the bundle deliberate?* The plan doesn't argue for the bundle; it just lists six sections and proposes them as one ticket. That reads like a default, not a deliberate choice.

**Decision 2: "Recommendation: wire it in" without budgeting the structural change.**
*Counterargument:* wiring requires understanding what `DerivationCoordinator` was designed for. If it was designed for the *next* deriver (host/SSH/container/kubectl) and not for retrofitting the present `GitContextDeriver`, forcing it into the production path now ties the present deriver to a shape that was speculative when authored. The honest move may be "delete `DerivationCoordinator` as YAGNI, write a thin synchronous cache layer, and add the coordinator back when the second deriver is real."
*Is "wire it in" the right default?* For a v2 SPEC that explicitly wanted the seam, yes. For pragmatic code health, maybe not.

**Decision 3: enum rename to match SPEC vs SPEC rewrite to match implementation.**
*Counterargument for "rewrite the SPEC":* the implementation has already shipped. The implementation's `nil`/`.unknown` shape has been live in production since `2b1be4220`. It has not regressed user behavior. Renaming after the fact is busywork driven by aesthetics of self-documenting names. The SPEC should reflect what we actually built.
*Counterargument for "rename":* SPECs that document fiction will rot. The next person reading the SPEC will be confused by the divergence. Sooner is cheaper than later.
*Plan's recommendation is "rename."* Reasonable, but the counterargument deserves an explicit "we considered keeping the implementation and rewriting the SPEC; here's why we chose the rename."

**Decision 4: timeout 2s vs 5s.**
*Counterargument:* the implementation chose 5s because the delegator deemed 2s too aggressive on slow disks (per validator). The follow-up plan says "operator's call" but lists it under "optional polish." This is a real product decision: 5s on a hung `git` invocation means a chip can be blank for 5 seconds before falling through. 2s means more false-positive timeouts on slow Time Machine restores. **The plan should make a call**, not punt to the operator without context.

**Decision 5: AC10 (`.stale` state) classed as "optional but recommended."**
*Counterargument:* if the enum rename happens, `.stale` is essentially free — you're already touching the enum shape. If the enum rename is deferred, `.stale` is a substantial addition. The plan doesn't acknowledge this coupling. The right framing is: "if we rename, we add `.stale` too. If we don't rename, we defer `.stale`."

**Decision 6: AC19 (restore-warmpath) out of scope.**
*Counterargument:* this is the most user-visible deferred item from #181 — chips paint blank on session restore for the duration of one async probe. It's the kind of thing operators notice ("why are my chips empty when I open c11?"). The plan defers it to a "real follow-up but separate ticket" with no ticket number. **Is that ticket filed?** If not, the deferral is informally indefinite.

**Decision 7: AC31–AC33 deliberately not run.**
*Counterargument:* AC33 (typing-latency burst) is the thing that decides whether the follow-up itself regresses the hot path. Punting it to "operator runs at their convenience" repeats the parent ticket's exposure. Either commit to a build-and-validate step in the delegator's flow or accept that the typing-latency claim is unverified post-follow-up too.

## Hindsight Preview

**Two years from now, things we might wish we had done differently:**

1. **"We should have split the PR." → Bisecting a typing-latency regression six months later is impossible because everything landed in one diff.**

2. **"We should have killed `DerivationCoordinator` as YAGNI." → The seam never grew a second deriver. Every code review since has had to look at it and decide it's still load-bearing. Some agent eventually deleted it in a cleanup pass, then someone else added it back. By year two we have 4 reincarnations of the same speculative seam, none of which has ever shipped a host/SSH deriver.**

3. **"We should have renamed the enum before shipping #181, not after." → Renaming after shipment is a multi-PR refactor with a paper trail of "we used to call this `.unknown`" code-archeology comments. The state names in commit history, in Lattice tickets, in skill docs, in delegator AAR documents all reference the old names.**

4. **"We should have written the AC14 timeout test before the production code." → The test got written to match the 5s default and the SPEC's 2s value got forgotten. Two years later someone discovers a hung pane chip and traces it back to the timeout choice. They look at the test for guidance and find it confirms 5s. They argue with the SPEC, lose, and we ship a different default.**

5. **"We should have killed the legacy `verticalBranchDirectoryLines()` codepath in #181 itself instead of deferring its deletion." → Section 5's "confirm dead, delete" is a delete-on-future-self pattern. Future self has different priorities than past self assumed. The dead code outlives its purpose by 18 months because no one's incentive to clean it up exceeds the risk of breaking something they don't know about.**

**Early-warning signs the plan doesn't have mechanisms to detect:**

- **The cache wiring lands but no one looks at hit/miss rates in production.** The plan has no telemetry ask. We won't know if the cache is actually saving probes or constantly invalidating itself until an operator notices a slow chip render six months in.
- **A new deriver is added to `[GitContextDeriver]` and silently fails the `dispatchPrecondition` check** because someone calls `DerivationCoordinator.run` from a context that happens to be on main during snapshot-restore. The runtime crash is rare and only on a specific cold-start path; it gets attributed to "weird launch hang" for months.
- **The `.stale` state is added but `WorktreeChipProjector` doesn't render it** — same as the current `.unknown` proxy. The user-visible behavior is identical even though the enum is now more expressive. **No one writes the test that distinguishes them.**
- **Settings UI label drift.** The new chip toggle's localization keys are populated for 6 locales as of #181. The dim opacity ThemeKey work (M6) — if it lands here — adds two more theme keys. Whoever does the theme JSON pass next may not realize those keys exist and ship a theme with hardcoded defaults that look subtly off.

## Reality Stress Test

**Three most likely disruptions hitting simultaneously:**

1. **Operator runs the post-merge smoke pass on #181 and AC33 typing-latency fails.** The operator flips `sidebarShowBranchDirectory` default to off per S9. The chip feature is now off by default in nightlies. **What does this follow-up do?** Section 1's "wire the coordinator into production" is touching a code path that's now feature-flagged off for most users. The plan never asks whether the wiring should be gated on the same toggle. If it isn't, the wiring runs even when chips are hidden — at zero user-visible value. If it is, the test fixtures need to exercise both states.

2. **A concurrent PR refactors `TabManager.initialWorkspaceGitMetadataSnapshot`.** It's a 5,539-line god-class with high traffic. Concurrent work — possibly C11-99, C11-103, or another C11-104-adjacent refactor — touches the same probe path. The follow-up's coordinator-wiring patch hits a merge conflict and the resolver gets called twice (once via legacy direct call, once via coordinator). The double-call wastes one probe per pane on launch and adds 50-150ms to cold launch on a machine with many panes. The bug is subtle because both calls return the same answer. **Nothing in the plan defends against this.**

3. **The `c11Tests` host scheme starts hanging in CI again.** The recent `compat-tests` job is at 10m28s; it's flaky territory. If it tips over, the follow-up PR's CI gating becomes "build green, compat-tests timed out, ship anyway." All four new tests (AC14/16/17/20) end up never having actually run in CI before merge. Two months later, AC14's test is found to have always been broken and the timeout regression it was meant to catch already happened.

**What happens when all three hit at once?** The follow-up is forced to land in a chip-disabled-by-default world, on a god-class that's been refactored under it, with CI that didn't actually run the new tests. The PR ships, no one notices anything broken because the feature is off, six months later we re-enable chips by default, the coordinator runs from main on a cold-launch path, the precondition crashes, and the post-mortem points at a follow-up PR that was rubber-stamped because everything looked green at the time.

## The Uncomfortable Truths

1. **The plan is the byproduct of an audit, not an architectural decision.** Every section maps to a validator finding. That's good in one sense (the work is grounded) and worrying in another (the plan is reactive). If the validator had missed something, the plan would have missed it too. **What did the validator miss?** Possibly: how `GitContextResolverCache` interacts with the `nonisolated static` shape of `initialWorkspaceGitMetadataSnapshot` under concurrent probe storms at launch; whether `applyDerivedWorktreeBranchMetadata` interacts correctly with the gen-token guards under the new `.stale` state; whether `c11 get-metadata --key worktree` semantically distinguishes "not yet derived" from "explicitly not in repo." The plan inherits all of these blind spots.

2. **"Wire it in OR document it as forward-looking" is a false binary.** The third option — delete the cache and coordinator as premature abstractions, write a synchronous bounded-size dict cache inside `GitContextResolver`, and add the seam back when there's an actual second deriver — is never considered. That's the YAGNI move and it's not on the menu. Asking "is this seam load-bearing for any work we'll do in the next 90 days?" honestly might give us "no." That answer matters.

3. **The "operator's call" language is doing work that hides commitments.** Three sections have "operator's call" branches. In practice, the operator delegates the call to the delegator, the delegator picks, and the operator never sees the decision until PR review. **If the operator wanted to weigh in, the plan should say "before starting, ask the operator: A or B?"** As written, the plan creates the option of consultation without creating the obligation.

4. **The validation-plan hygiene item (section 7) will not happen.** It's last, it has no AC, it competes with code work, and it has no enforcement. Plans that include "also update the docs" as their last bullet point ship without the docs updated 80% of the time.

5. **The AC10 `.stale` state defer is real risk.** The user-visible symptom of "worktree removed from another pane" is "chip sticks at the last-known branch for the rest of the session." That's a confusing bug to operators who use `git worktree` heavily — which is exactly c11's target audience. Defer-without-tracking is how this becomes the next bug report.

6. **Nothing here addresses the typing-latency commitment we never validated.** PR #181 shipped without an operator-driven AC33 pass. This follow-up is layering more on top without validating the original premise. The plan should pause and ask: has anyone actually typed 100 chars in a worktree pane on a tagged build? If no, the next merge is doubling down on an unvalidated baseline.

7. **The plan assumes one delegator. Two would be safer.** Section 1 (wiring) and section 2 (tests) are conceptually independent — tests can land first as a safety net before the wiring changes anything. Bundling them with the same delegator forces sequential work and a single commit chain. **Two delegators in parallel could ship the tests first, then the wiring, in two PRs.**

## Hard Questions for the Plan Author

1. **Section 1 says "two acceptable resolutions." Pick one. If you can't pick without the operator, say "blocked on operator decision" and don't start work.** Which is it: wire or document?

2. **If you wire `DerivationCoordinator` into production, do you delete the direct call to `GitContextResolver.resolve(cwd:)` at `TabManager.swift:1724`, or do you keep both paths during a transition?** If both, for how long, and what tests prove they agree?

3. **What's the cache-invalidation behavior under clock skew?** mtime is not monotonic. If NTP corrects the clock backward, a cached entry can have a future mtime relative to "now," but a future write can produce a smaller mtime than the cached one. Does that produce a stale cache hit? "We don't know" is a real possible answer here.

4. **Section 1's "documented as forward-looking-only" branch — what stops the next agent from deleting the cache and coordinator as dead code under your own section 5 dead-code-cleanup policy?** Aren't we writing the executioner's warrant right next to the executioner's instructions?

5. **AC14 timeout test: are you writing the test against the spec's 2s or the implementation's 5s?** And if 2s, are you also changing the implementation to 2s? Both? Just the test? Where does that decision get recorded?

6. **AC16 socket-frame-rejection test: are you exercising the test through the c11 socket only, or also through the `cmux` compat alias path?** The rejection code lives in `TerminalController.swift`; is the alias path going through the same handler?

7. **AC17 socket get-metadata read test: does `c11 get-metadata --key worktree` return an empty string, nil, or an error when the pane is in `.notInRepo`?** What does your test assert? Is that consistent with `--key branch`'s behavior?

8. **AC20 deterministic main-thread precondition trip: how, exactly?** `XCTExpectFailure` doesn't trap `dispatchPrecondition` crashes — they're EXC_BAD_INSTRUCTION, not XCTFails. Are you doing this via a subprocess fork? A signal handler? A separate test binary? The current sentinel test exists *because* this is hard.

9. **Section 3 enum rename: have you confirmed every `switch` over `BranchValue` and `GitContextKind` in the codebase is exhaustive and will compile-error you into a complete rename?** If any uses `default`, the compiler won't help and you'll silently miss call sites.

10. **Section 4 `.stale` state: when does the deriver actually return `.stale` vs returning `nil` (cwd directory gone)?** What's the precise observable signal? `git rev-parse --show-toplevel` returning nonzero with a specific error? A check on the worktree pointer file? Be concrete.

11. **Section 5 dead-code deletion: what's your falsification protocol?** Beyond `grep`, are you running both `c11-logic` and `c11-unit` schemes after the delete? Are you checking that snapshot-restore, plan-capture, and persistence migrations still work?

12. **Section 6 timeout 5s → 2s: have you measured how often the current 5s actually times out on a realistic operator's machine?** "Conservative" is a vibe; data is a number.

13. **Section 7 validation-plan hygiene: who owns it after the PR merges?** If the delegator runs out of time, does the operator do it? Is there a checklist item in PR review?

14. **AC criterion 6 says "PR body links to this ticket and to PR #181; describes which AC numbers it closes." Which AC numbers, specifically?** If the answer is "depends on what we ship," that's a sign the scope is uncertain — clarify the floor and ceiling.

15. **What is your bisection plan if AC33 (typing latency) regresses post-merge?** Multi-commit branch with one commit per section? Squash? Without a plan, "fix forward" is the default and there's no rollback granularity.

16. **What happens to this follow-up if the operator's smoke pass on #181 fails AC33 and the chip feature is feature-flagged off by default?** Does this PR still merge? Does its scope change?

17. **Are you bundling all six sections in one PR, or splitting?** The plan doesn't say. If bundling, why? If splitting, how?

18. **The plan says "CI green; no regressions in `c11-logic` or `compat-tests`" as AC #5. Are you running anything beyond CI?** Specifically, are you running a tagged-build typing-latency smoke pass under `./scripts/reload.sh --tag c11-106` before merge?

19. **Is there a Lattice ticket for the AC19 restore-warmpath defer? If not, when does it get filed and by whom?** "Real follow-up but separate ticket" is not a commitment without a number.

20. **Have you considered just deleting `DerivationCoordinator` and `GitContextResolverCache` as premature abstractions, with a clean note that they should be added back when the second deriver lands?** YAGNI was not on your menu of resolutions and probably should have been.

---

**Bottom line:** The plan is competent, faithful to the audit, and shippable. It is also a list of decisions disguised as a list of tasks. The single highest-leverage move is to commit to specific picks (wire it in vs document; rename vs rewrite-SPEC; 2s vs 5s; one PR vs split) **before starting**, with the operator's explicit say-so on the two-or-three that genuinely deserve it. The second-highest move is to split the work so the merge has bisection granularity. Everything else is downstream of those two choices.
