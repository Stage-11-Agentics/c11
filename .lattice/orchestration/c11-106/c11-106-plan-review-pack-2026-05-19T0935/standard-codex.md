# Standard Plan Review: c11-106-plan / Codex

## Executive Summary

The plan is aimed at the right follow-up surface. It correctly identifies the main drift from C11-104: the user-visible sidebar chip feature shipped, but the architectural seam, cache, several validation-plan tests, and enum vocabulary are not fully load-bearing. That is the right thing to close in C11-106.

My verdict is **needs revision before execution**, not because the scope is wrong, but because the plan leaves too many architectural choices open for a delegator ticket. The biggest risk is the first item: "wire `DerivationCoordinator` + `GitContextResolverCache` into production OR document them as forward-looking-only." That is a planning fork, not an implementation step. The rest of the plan, especially AC17 and the recommendation to add linked-worktree/submodule cache invalidation tests, implicitly assumes the first path. The ticket should choose one path up front.

The most important technical gap is cache correctness. A cache keyed only by `(cwd, mtime(git rev-parse --git-path HEAD))` is plausible for a simple checkout or linked worktree, but it is not sufficient for all contexts C11-104 resolves. In a submodule cwd, the resolver returns both outer superproject context and inner submodule context; invalidating only on the inner HEAD can leave the displayed outer branch stale when the superproject changes. Also, caching nil results when `headPath` is nil can make "not currently a repo" sticky if a repo is initialized later in the same cwd.

## The Plan's Intent vs. Its Execution

The intent is clear: turn the C11-104 validation audit into a small hardening PR that closes test gaps and removes misleading architecture. That is exactly the right follow-up after a merge-with-known-drift.

The execution drifts in three places:

1. It mixes decision-making with implementation. "Wire it in or document it" and "decide enum naming" are valid product/architecture questions, but a delegator needs a single target.
2. It treats "coordinator" and "cache" as one issue. They are related, but not identical. The cache can be made production-load-bearing without adopting the current async `DerivationCoordinator.run` shape, and the coordinator can be documented as a future seam while production uses the existing probe queue.
3. It says the wiring cost is modest, but the current production path is not just a git-context resolver call. `TabManager.initialWorkspaceGitMetadataSnapshot` also computes legacy branch, dirty state, and PR state, and it is called from a delayed retry/timer system with generation and expected-cwd guards. Replacing or wrapping that path needs to preserve retry, stop conditions, main-actor apply, and hot-path discipline.

## Architectural Assessment

The decomposition is directionally good: production wiring/documentation, missing tests, enum vocabulary, stale state, dead code, optional polish, validation hygiene. Those are the right buckets.

The problem is that the first bucket should be decomposed further:

- **Cache integration:** define cache ownership, cache key semantics, what result states may be cached, and which HEAD paths contribute to a key.
- **Coordinator integration:** decide whether the existing `DerivationCoordinator.run` is actually the production orchestration mechanism or whether it remains a seam for future independent derivers.
- **Snapshot shape:** define whether `InitialWorkspaceGitMetadataSnapshot` remains the single aggregation point for branch, dirty, PR, and git context, or whether derived metadata moves onto its own pipeline.

I would not start by forcing `DerivationCoordinator.run` into the existing timer callback. The current coordinator is generic and callback-based, while the existing probe path is already off-main and owns retry/generation behavior. A lower-risk architecture is:

- keep `initialWorkspaceGitMetadataSnapshot` as the aggregation point for C11-106;
- add a `GitContextResolverCache` instance owned by `TabManager` or by a small static resolver facade;
- route git-context resolution through a cache-aware helper;
- update docs to say `DerivationCoordinator` is a forward seam unless it is actually called by production.

That achieves the load-bearing cache goal without pretending the current coordinator is the scheduler.

If the operator wants the E1 architecture to be real now, then the plan should specify a larger refactor: make the coordinator handle multiple derivers, cacheable git context, and stale-result guards as first-class behavior. That is a bigger PR than the plan currently admits.

## Is This the Move?

Yes, with revisions. C11-106 should exist, and it should close the audit gaps while the C11-104 context is still fresh. Letting the seam remain ambiguous is exactly how dead abstractions become misleading maintenance hazards.

The right move is to prioritize:

1. Make the production truth unambiguous: either the coordinator/cache are load-bearing, or docs/code comments say they are not.
2. Add tests for real externally observable contracts: socket rejection, socket reads, timeout process termination, linked-worktree/submodule cache invalidation.
3. Normalize enum/state vocabulary only if it improves behavior and tests, not merely to match a spec document.

The optional polish should stay optional. Theme-backed dim opacity and timeout 2s vs 5s are reasonable follow-ups, but they should not crowd out the correctness questions.

## Key Strengths

- **It is grounded in the validation audit.** The plan is not inventing new scope; it maps directly to AC14, AC16, AC17, AC20, AC12, and the documented drift.
- **It provides an explicit escape hatch.** Documenting the seam as forward-looking-only is a legitimate alternative if the operator does not want a production refactor.
- **It preserves hot-path awareness.** The plan keeps the focus on off-main git work and c11's typing-latency constraints.
- **It includes cleanup and validation hygiene.** The dead-code grep and validation-plan annotation are small but important. They prevent the next validator from rediscovering known decisions.
- **It keeps AC19 out of scope.** Restore warm-path behavior touches lifecycle and initial paint; separating that from this hardening PR is sensible.

## Weaknesses and Gaps

### 1. The plan must choose "wire" or "document" before delegation

The acceptance criteria allow either path, but several later steps assume wiring. For example, AC17 says to populate derived metadata "via the coordinator." If the ticket takes the documentation path, AC17 needs a different setup: populate through `SurfaceMetadataStore.setInternal(.derived)` or through the existing production apply path.

Recommendation: make "wire cache into production git-context resolution" mandatory, and make "document `DerivationCoordinator` as forward-looking unless actually invoked" mandatory. Treat coordinator production adoption as optional only if a concrete design is added.

### 2. Cache key semantics are underspecified for submodules

The proposed key is `(cwd, mtime(headPath))`, where `headPath = git rev-parse --git-path HEAD`. That catches linked worktree HEAD movement. It does not obviously catch all submodule cases because the resolved context includes:

- outer superproject branch/worktree context;
- inner submodule branch context.

From a submodule cwd, `--git-path HEAD` generally points at the submodule's HEAD, not the superproject HEAD. If the superproject branch changes while the submodule HEAD does not, a cached `ResolvedGitContext` can keep rendering the old outer branch.

Recommendation: either do not cache submodule combined contexts yet, or key them by all relevant resolved HEAD paths: outer/superproject HEAD plus inner/submodule HEAD. Tests should mutate both independently.

### 3. Caching nil can create stale negative results

`GitContextResolverCache` supports storing `ResolvedGitContext?`, including nil. If the cache key has `headMtime == nil`, a not-in-repo, missing cwd, bare repo, timeout, or broken gitdir can all collapse into `(cwd, nil)`. If that result is cached, a later `git init`, repaired worktree, or recovered command path could remain invisible until cache eviction.

Recommendation: define a policy. The simplest safe rule is: only cache when a resolved HEAD path exists and its mtime was read successfully. Do not cache nil-head states unless the key includes another invalidation input such as cwd directory mtime.

### 4. Timeout needs an API shape, not just a test

AC14 asks for a defined timeout result, but `GitRunner.run` currently returns only `String?`. That cannot distinguish timeout from non-zero exit, missing git, not-in-repo, bare clone, or deleted branch. Adding `.timeout` requires either:

- changing `GitRunner` to return a result enum with failure reasons;
- adding a timeout-aware runner API used only by the resolver;
- accepting that timeout maps to nil and testing only that the process terminates.

The plan should choose. Otherwise the delegator will discover this mid-implementation and either over-refactor or write a weak test.

### 5. The `.stale` / `.notInRepo` / `.noBranch` rename is not merely naming

The current implementation uses nil for no context and `.unknown` for no branch. Introducing explicit states changes the resolver model. That can be worthwhile, but the plan should define the rendering and metadata behavior for each state:

- Does `.notInRepo` write empty `worktree` and empty `branch`?
- Does `.stale` write empty values, remove keys, or keep previous explicit/derived values untouched?
- Does `.noBranch` render `"(no branch)"` in the sidebar and also return `branch: "(no branch)"` through `c11 get-metadata`?

There is already a mismatch in C11-104: the projector renders `.unknown` as `"(no branch)"`, but `applyDerivedWorktreeBranchMetadata` writes an empty derived `branch` value for `.unknown`. C11-106 should settle that contract explicitly.

### 6. AC20 is likely fragile unless implemented as a subprocess fatal test

`dispatchPrecondition` aborts. `XCTExpectFailure` does not make an in-process fatal precondition safe. The plan mentions "XCTExpectFailure around a main-thread invocation, or precondition-fatal test pattern," but those are not equivalent.

Recommendation: specify a subprocess/helper pattern or downgrade AC20 to a documented sentinel. A fake deterministic crash test that destabilizes `c11LogicTests` would be worse than the current gap.

### 7. Dead-code cleanup may be less dead than the plan implies

On the merged C11-104 ref, `Workspace.sidebarBranchDirectoryEntriesInDisplayOrder` is still called from `ContentView` helper code and from tests. The validator said the legacy render path was retired, but some helper code remains in the file. The plan's "grep and delete if confirmed" wording is good, but the likely outcome is either a slightly larger ContentView cleanup or leaving compatibility helpers in place.

Recommendation: make this a cleanup subtask with "no behavior change" as the guard, not a required acceptance criterion.

### 8. Validation-plan hygiene should not mutate historical evidence casually

Annotating the v2 validation plan in place can be useful, but that file is also an audit artifact. A v3 section or separate C11-106 validation addendum is cleaner than editing history in a way that blurs what PR #181 was originally judged against.

## Alternatives Considered

### Alternative A: Wire everything through `DerivationCoordinator`

This makes the E1 architecture real. It is conceptually clean if c11 expects several derived metadata sources soon. The cost is that the current coordinator is too thin to be a full production scheduler: it does not own cache policy, generation guards, expected-cwd checks, retry behavior, or multi-deriver aggregation. Making it load-bearing now is a real refactor.

Use this path only if the operator wants to invest in the general derived-metadata pipeline now.

### Alternative B: Cache-aware git context helper, coordinator documented as future seam

This is the pragmatic C11-106 path. Keep the current `TabManager` probe lifecycle, add cache-aware resolution where `GitContextResolver.resolve` is called, add the missing tests, and update docs/comments so `DerivationCoordinator` is not described as production wiring.

This is my recommended path. It closes the real performance/drift issue with lower blast radius.

### Alternative C: Documentation-only, no production cache

This is acceptable if the operator wants the smallest PR. It should be honest: update code comments and `skills/c11/references/metadata.md` to say the coordinator/cache are future seams, add only the missing socket/timeout/precondition tests that do not depend on production cache wiring, and create a separate ticket for cache integration.

This is defensible, but it leaves the C11-104 AC12 cache promise unfulfilled.

### Alternative D: Split C11-106 into two PRs

PR 1: documentation honesty, enum/spec naming, socket tests, timeout test, dead-code cleanup.

PR 2: production cache/coordinator/stale-state refactor with fixture-heavy linked-worktree/submodule tests.

This is safer if the team is worried about typing-latency or production-probe regressions. The downside is another round of orchestration overhead.

## Readiness Verdict

**Needs revision.**

The plan is close, but I would not hand it to a delegator as-is. It should be tightened in these ways:

1. Choose the production architecture path up front.
2. Specify cache ownership and invalidation semantics, especially for submodules and nil-head states.
3. Define the resolver/result model needed for timeout, stale, not-in-repo, and no-branch states.
4. Clarify metadata values for no-branch/stale/timeout so sidebar projection and `get-metadata` agree.
5. Replace the AC20 wording with a concrete safe fatal-test strategy or explicitly accept a sentinel test.

Once those are resolved, the plan is ready. The actual scope is still reasonable if the recommended path is cache-aware production resolution plus forward-looking coordinator docs.

## Questions for the Plan Author

1. Should C11-106 make `DerivationCoordinator` production-load-bearing, or should it document the coordinator as a future seam and only wire `GitContextResolverCache` into the existing `TabManager` probe?
2. If the coordinator is wired in, should it own generation tokens and expected-cwd guards, or should those remain exclusively in `TabManager.applyWorkspaceGitMetadataSnapshot`?
3. Where should the production cache live: as a `TabManager` instance property, a static resolver facade, or inside a new git-context service object?
4. Should nil resolver results be cached at all? If yes, what invalidates `(cwd, nil)` when a directory becomes a git repo later?
5. For submodule cwd resolution, should the cache key include both the superproject HEAD mtime and the submodule HEAD mtime?
6. Should submodule contexts be excluded from cache until multi-HEAD invalidation is implemented?
7. What is the desired external `branch` metadata value for no-branch states: empty string, `"(no branch)"`, or key removal?
8. What should `.stale` do to metadata: clear values, remove derived keys, or preserve the previous value with some stale marker?
9. Does the operator want timeout represented as a distinct resolver state, or is "process terminated and chips clear" sufficient?
10. If timeout is distinct, should `GitRunner` return a richer result enum instead of `String?`?
11. Should the timeout default change from 5s to 2s in this PR, or should the plan merely test the current 5s behavior and update the spec?
12. Is enum renaming intended to be source-level vocabulary only, or should it change user-observable metadata/projection behavior?
13. Should AC20 be implemented with a subprocess fatal-test harness, or should the project keep the existing sentinel approach and mark the stronger AC deferred?
14. Should validation-plan updates be made in-place, or should C11-106 create a v3/addendum file to preserve the C11-104 validation artifact unchanged?
15. Is `Workspace.orderedUniqueBranchDirectoryEntries()` still needed for any non-sidebar consumer, or can the whole legacy branch/directory helper chain be removed if the remaining `ContentView` helper is unused?

## Suggested Revised Acceptance Criteria

1. Production docs are truthful: every reference to `GitContextDeriver`, `DerivationCoordinator`, and cache states whether it is load-bearing now or a future seam.
2. `TabManager` no longer calls uncached `GitContextResolver.resolve(cwd:)` directly for production git-context probes, unless the ticket explicitly chooses documentation-only.
3. Cache policy is tested against linked worktrees and submodules, including every HEAD path that can affect rendered output.
4. Nil-head states are either not cached or have a tested invalidation path.
5. AC14, AC16, AC17, and AC20 are added or explicitly reclassified with rationale.
6. Resolver state names and metadata output values are aligned with the spec and with sidebar projection.
7. Dead legacy branch/directory helpers are deleted only if call-site cleanup proves they are unreachable.
8. PR body records which C11-104 ACs are closed, deferred, or intentionally rewritten.
