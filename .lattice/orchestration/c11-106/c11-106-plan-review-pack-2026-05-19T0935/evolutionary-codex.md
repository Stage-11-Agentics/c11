# Evolutionary Review: c11-106-plan / Codex

## Executive Summary

The biggest opportunity is to stop treating C11-106 as a cleanup pass for C11-104 and treat it as the moment c11 gets its first real ambient-context pipeline.

The current plan is correct about the immediate gaps: wire `DerivationCoordinator`, settle cache invalidation, add missing tests, rename state cases, and clean up deferred edges. But the deeper value is that c11 is learning how to convert observable terminal state into canonical, queryable, operator-visible metadata without asking agents to self-report. Git worktree and branch chips are the first example, not the destination.

If this evolves well, C11-106 becomes the foundation for "context chips" across the whole room: git, host, SSH target, container, kubectl context, cloud profile, task identity, session lifecycle, maybe even risky-state warnings. The follow-up plan should still ship narrowly, but it should make the `DerivationCoordinator` real enough that the next deriver is boring to add.

## What's Really Being Built

At the surface, the plan closes validation gaps from PR #181. Underneath, it is building a trusted derivation layer between raw surface state and the c11 metadata manifest.

That layer has four jobs:

1. Observe ambient state from ground truth (`cwd`, gitfs, shell reports, process/session context).
2. Derive structured facts off-main without touching typing hot paths.
3. Apply those facts through one guarded mutation path with stale-result protection.
4. Publish the same facts to both UI state and `SurfaceMetadataStore` so the sidebar, CLI, Lattice, and future agents see one truth.

This is more strategic than "show worktree chips." It is c11's internal sensor bus. Once it exists, agents no longer need to narrate basic context, and the operator no longer needs to infer it from prompts, cwd strings, or orchestration notes.

## How It Could Be Better

The plan should choose "wire it in" as the only serious path. The "document forward-looking-only" option is useful as a fallback, but it dilutes the most valuable part of the ticket. A half-real coordinator creates ambiguity: future agents will either bypass it because production bypasses it, or wire a second deriver inconsistently. Make the first deriver load-bearing now.

I would tighten the implementation shape around a small `DerivedMetadataSnapshot`, not just `ResolvedGitContext`. Today `InitialWorkspaceGitMetadataSnapshot` already mixes legacy branch, dirty state, PR data, and git context. The next evolution is to have the coordinator produce an explicit bundle of derived outputs plus provenance:

```swift
struct DerivedMetadataSnapshot: Sendable, Equatable {
    let git: ResolvedGitContext?
    let diagnostics: [DerivedMetadataDiagnostic]
    let cache: DerivationCacheResult
}
```

This does not need to be a large abstraction. The point is to avoid each future deriver inventing its own result plumbing, logging, stale guards, and metadata write policy.

The cache story should also become a shared policy instead of a git-only utility. Keep `GitContextResolverCache` concrete if that is the smallest safe move, but design the coordinator call site as if every deriver can declare an invalidation key. For git, the key is `(cwd, mtime(git rev-parse --git-path HEAD))`. For host/container/kube, the key might be `(pid/session, env hash, config mtime)`. The shape matters more than generalizing everything immediately.

Finally, `.stale` should not be framed only as an enum naming fix. It is the first explicit "derived fact is no longer trustworthy" state. That is different from not-in-repo, timeout, no branch, and unknown. Treat it structurally.

## Mutations and Wild Ideas

**Context strip, not git chips.** Worktree and branch chips could become the first row in a compact "context strip" for each surface. The row might eventually show repo/worktree, branch, dirty state, host, container, kube context, AWS profile, and task. The sidebar becomes an operations board for the whole room.

**Risk chips.** `.stale`, dirty worktree, detached HEAD, production kube context, or mismatched branch-vs-ticket could render as subtle risk hints. This would turn derived metadata from passive context into operator safety infrastructure.

**Room queries.** Once derived metadata is reliable, the CLI can answer questions like: "which surfaces are on branch feat/foo?", "which panes are in stale worktrees?", "which agents are in this repo but not this ticket worktree?", "which sessions are touching production kube?" This is a natural fit for Lattice and for orchestration dashboards.

**Self-healing prompts.** A future c11-aware agent launcher could include a short derived-context preamble: cwd, branch, worktree, host/container, ticket, and stale warnings. Agents would start with better situational awareness without persistent writes to their own config.

**Derivation replay harness.** Capture `cwd` transitions and derivation outputs as a trace. Replaying the trace would regression-test cache invalidation, stale result dropping, and UI updates without launching the app or depending on real git timing.

**Operator policies.** If context chips become policy-aware, the operator could define warnings: "highlight any surface on main with dirty state", "flag kubectl production", "flag stale worktree", "flag branch not matching Lattice task." That is downstream, but C11-106 can preserve the option by making derived states typed instead of collapsed into empty strings too early.

## What It Unlocks

Wiring `DerivationCoordinator` unlocks a repeatable path for every ambient fact c11 can derive without agent cooperation. The immediate unlocks are cache reuse, linked-worktree and submodule invalidation tests, and less drift between code, docs, and validation plans.

The next unlock is queryability. Derived `worktree` and `branch` values are already written into `SurfaceMetadataStore` with source `.derived`; once that path is trusted and tested through socket reads, Lattice can consume it as normal metadata. That is the bridge from visual sidebar feature to orchestration primitive.

The `.stale` state unlocks a better mental model for degraded context. `nil` means "no fact." `.unknown` means "fact exists but cannot be named." `.stale` means "previous fact may be invalid because its backing path disappeared." `.timeout` means "the derivation did not complete inside budget." These deserve different observability and sometimes different UI treatment, even if the current chip render clears all of them.

Cache invalidation unlocks confidence to add more derivers. Without a cache policy, every new context source risks death by a thousand background probes. With a coordinator-owned invalidation discipline, adding host/container/kube context is incremental instead of scary.

## Sequencing and Compounding

The best sequence is:

1. First, make production use the coordinator for git, but keep the existing `initialWorkspaceGitProbeQueue` and apply-side generation guards. This minimizes behavioral change while making the seam real.
2. Next, wire the git cache inside the production derivation path and add the linked-worktree plus submodule resolved-HEAD invalidation tests. This proves the hardest correctness claim.
3. Then settle typed states: `notInRepo`, `bare`, `stale`, `timeout`, `noBranch`. Even if the UI clears most of them, the resolver/coordinator should not erase the distinction.
4. Then add AC16 and AC17 socket tests. These prove the derived metadata is part of the external contract, not only sidebar state.
5. Then add AC20 only if there is a maintainable fatal-precondition test pattern already accepted in the repo. If not, document the residual gap rather than adding a brittle fake test.
6. Finally, delete dead legacy branch-directory helpers and annotate the validation plan with what C11-106 resolved.

I would defer theme-backed dim opacity unless the PR is already touching theme tokens. It is valid polish, but it does not compound as much as making the derivation path real.

I would also avoid solving AC19 restore warm-path in this ticket unless it falls out cleanly. Restore pre-paint is a lifecycle problem, not a git resolver problem. It deserves its own small plan because it has different failure modes: stale snapshots, session resume timing, and visual first paint.

## The Flywheel

The flywheel is:

Reliable derivation path -> more ambient context becomes cheap to add -> sidebar and socket become more truthful -> operators and orchestrators depend on derived metadata -> tests and traces cover more state transitions -> adding the next deriver gets safer and faster.

The plan can accelerate this flywheel with two small additions:

1. Add a "how to add a deriver" mini-section to `skills/c11/references/metadata.md` after the coordinator is wired. Include queueing, cache key, stale guard, source `.derived`, snapshot exclusion, socket read behavior, and test expectations.
2. Add one debug log or lightweight diagnostic counter around cache hit/miss/stale/timeout. It does not need to be UI yet. The important part is that future performance issues can be explained without instrumenting from scratch.

The cache invalidation flywheel is especially important. If cache keys are explicit and tests use real linked-worktree and submodule HEAD paths, every future git edge case can be turned into a fixture. The system gets better as weird repos are encountered.

## Concrete Suggestions

Make the plan's primary recommendation stronger: "Wire it in" should be the default acceptance path; "document future-only" should be allowed only if implementation discovers real risk.

Introduce typed resolver outcomes instead of continuing to overload `nil`:

```swift
enum GitContextResolution: Equatable, Sendable {
    case resolved(ResolvedGitContext)
    case notInRepo
    case bare
    case stale
    case timeout
}
```

If this is too much churn for C11-106, at least rename `.unknown` to `.noBranch` and add `.stale` now, while keeping `nil` for not-in-repo. But the richer enum is the better evolutionary move.

Treat `.stale` as an internal diagnostic even if chips clear. Write empty `worktree` and `branch` to metadata, but preserve the stale reason in a non-rendered derived diagnostic field or debug log. Otherwise c11 will not be able to distinguish "not a repo" from "repo disappeared under a live pane."

Make `DerivationCoordinator` own cache lookup for git. The call site should look conceptually like "run git deriver for cwd with cache policy, complete with snapshot," not "call resolver, then separately remember cache exists." This is the difference between a reusable coordinator and a wrapper.

Add one test that exercises the whole production-ish pipeline without SwiftUI: fake cwd A, derive, apply to `SurfaceMetadataStore`, then socket-get `worktree` and `branch`. That closes AC17 and proves the UI/store dual-write contract.

For AC14, decide whether timeout is a typed state or just a nil clear. The spec says `.timeout`; if the implementation only returns nil, the test will lock in less information than future risk chips need. Prefer typed timeout.

For AC20, do not overfit. If deterministic precondition crash testing is awkward in XCTest, add a small subprocess test harness or explicitly mark the fatal-test pattern as deferred. A comment-only sentinel was already judged insufficient; another weak sentinel will not improve the system.

When deleting dead code, check whether `SidebarBranchOrdering` tests still cover a non-sidebar consumer. If the ordering helper is now only legacy, delete it. If command palette or workspace search still benefits from it, rename it away from "sidebar" to avoid false cleanup later.

Add validation-plan hygiene as a required final step, not optional. This ticket exists because validation drift was rediscovered after merge; the plan should close the loop by marking AC10/12/14/16/17/20 status explicitly after C11-106.

## Questions for the Plan Author

1. Is the strategic decision that `DerivationCoordinator` is now the production path for all derived metadata, or only a convenience wrapper for future isolated experiments?

2. Should resolver outcomes preserve typed degradation states (`notInRepo`, `bare`, `stale`, `timeout`, `noBranch`) even when the current UI renders several of them as empty chips?

3. Do you want `.stale` to be externally visible through metadata or diagnostics, or only an internal state that clears chips?

4. Should cache policy live inside `GitContextResolverCache`, inside `DerivationCoordinator`, or at the `TabManager` call site? This determines how easy the second deriver will be.

5. Is the 2-second timeout a product requirement for snappy UI, or was 5 seconds an intentional reliability tradeoff for slow disks and large repos?

6. Should AC19 restore warm-path stay out of C11-106? It is valuable, but it touches session restore and first paint rather than derivation correctness.

7. Are host/SSH/container/kubectl/AWS derivers expected soon enough that C11-106 should add a small "add a deriver" guide now?

8. Should `SurfaceMetadataStore` eventually carry derived diagnostics separately from rendered canonical strings, so operators can query "why did this chip clear?"

9. Does Lattice intend to consume `worktree` and `branch` through `c11 get-metadata` soon? If yes, AC17 should be treated as contract-level, not just test hygiene.

10. Should stale/risk states become visual warnings in the sidebar, or is the design principle that derived chips remain context-only and non-alarming?
