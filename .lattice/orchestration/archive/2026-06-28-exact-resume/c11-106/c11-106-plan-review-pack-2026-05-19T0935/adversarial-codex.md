# Adversarial Review: c11-106-plan / Codex

## Executive Summary

This plan is pointed at the right debt, but it is not tight enough to be a reliable execution contract. The biggest problem is that it keeps two incompatible paths open: "wire the coordinator/cache into production" or "document them as forward-looking-only." Almost every hard acceptance criterion assumes the first path, while the plan still permits the second. That ambiguity is not harmless; it lets the implementer satisfy the letter of the plan while leaving the core architectural drift unresolved.

The second concern is underestimation. "Wire it in" is framed as modest glue, but the existing production path is a synchronous snapshot function running on the legacy probe queue, while `DerivationCoordinator.run` is async and completes on main. Cache use is not just a call-site swap. It needs a coherent ownership model, an injection/testing seam, stale-result guards, and a cache key that handles submodules and linked worktrees correctly.

I would not send this plan to implementation as-is. It needs a decision: either this ticket is the production-wiring ticket, or it is a documentation/test-debt cleanup ticket. Trying to keep both in one plan is how the follow-up becomes another partial.

## How Plans Like This Fail

This kind of follow-up usually fails by turning validation gaps into a checklist without re-designing the underlying contract. The plan inherits AC numbers from C11-104, but some of those ACs are mutually dependent: AC12 cache behavior, AC17 socket reads populated by coordinator, and AC20 coordinator preconditions only matter if the coordinator is production-load-bearing. If the coordinator is documented as future-only, those tests become either fake or irrelevant.

It also risks confusing tests with behavior. The plan says "add the four missing tests" but several tests require new seams first. AC16 cannot be honestly verified by `SurfaceMetadataStore` alone because the `source=derived` rejection lives in `TerminalController`'s external socket handler, not in the store. AC20 cannot be honestly caught with a normal in-process XCTest assertion because `dispatchPrecondition` terminates the process. Without explicit harness guidance, a delegator will likely recreate the previous sentinel-test mistake.

The plan also bundles too many categories of work: production architecture, cache invalidation, socket security tests, enum semantics, stale worktree behavior, dead-code cleanup, theme polish, and validation-plan editing. The likely failure mode is a large PR with several "operator's call" branches, partial tests, and a PR body that explains why some originally required items remain deferred.

## Assumption Audit

Load-bearing assumption: `DerivationCoordinator` can replace the direct resolver call with 50-100 lines of glue. That is weak. The current baseline at `2b1be4220` has `TabManager.initialWorkspaceGitMetadataSnapshot(for:)` returning a single synchronous snapshot containing legacy branch, dirty status, pull request, and `gitContext`. `DerivationCoordinator.run` schedules work on its own queue and calls back on main. Using it directly would either force a blocking wait, split the snapshot lifecycle, or refactor the probe scheduler. None of that is named.

Load-bearing assumption: cache key `(cwd, mtime(headPath))` is sufficient. It is not obviously sufficient for submodules. The displayed context can include both the outer superproject and the inner submodule, but `git rev-parse --git-path HEAD` from the submodule cwd only tracks the inner HEAD. If the superproject branch changes while a pane is inside a submodule, a one-HEAD key can serve stale outer context. The key likely needs all relevant HEAD paths or a resolver-provided dependency set, not a single path.

Load-bearing assumption: adding `.stale`, `.notInRepo`, and `.noBranch` is just enum naming. It is semantic churn. Today `nil` means clear, `.unknown` means degraded branch, and the projector/store paths already encode behavior around those shapes. Introducing explicit states changes cache values, projection, derived metadata writes, socket reads, and test fixtures. It may be worth doing, but it is not a search-and-replace.

Load-bearing assumption: C11-106 can stay "no user-visible sidebar render change" while also optionally changing dim opacity to theme-backed values and adding stale/no-branch state semantics. The opacity change is visible. Branch/no-branch handling can become visible if metadata stores empty string instead of `(no branch)` or vice versa. The plan's out-of-scope line conflicts with its optional work.

Load-bearing assumption: tests can all live in `c11Tests/` with `c11LogicTests` target membership. That may be true for resolver/cache/projector tests, but the socket protocol path in `TerminalController` is private and tied to app state/main-sync resolution. If the plan expects hostless logic tests, it needs to define the test seam. Otherwise the implementer may either skip the real socket path or accidentally move this into the host-required suite.

Load-bearing assumption: the local implementation baseline is already on the C11-104 merge. In this workspace, `main` is behind the referenced merge even though commit `2b1be4220` exists. The plan should explicitly require starting from the merged C11-104 baseline or rebasing onto current `main`; otherwise agents may inspect the wrong tree and produce nonsense edits.

Cosmetic assumption: validation-plan hygiene can be done by annotating the old C11-104 validation plan in-place. That is risky. A validation plan/report is historical evidence; editing it after the fact can blur what was known at merge time. Prefer a C11-106 validation addendum or C11-104 follow-up note rather than mutating the original artifact.

## Blind Spots

The plan never defines the production coordinator API. Does `DerivationCoordinator` own the cache? Does `GitContextDeriver` own it? Does `TabManager` own it? How is the cache injected in tests? How are cache statistics or runner invocation counts observed? Without that, AC12 is underspecified.

The plan does not address result ordering if the coordinator is genuinely async. The existing gen-token and expected-cwd guards protect the current snapshot apply path. If git context becomes a separate coordinator callback, the plan must say whether it reuses the same generation token, creates a separate token, or remains bundled into the existing snapshot. This is exactly the stale-async risk AC13 was meant to cover.

The cache invalidation story ignores multiple dependency files. Submodule display depends on inner HEAD, outer HEAD, `.gitmodules`, and potentially `--git-common-dir` / worktree metadata. Linked worktree detection depends on gitdir/common-dir paths. A cache keyed only on cwd and one HEAD mtime can be correct for simple branch chips and wrong for stacked submodule rows.

The timeout state is under-designed. The plan says "assert defined timeout result" but the current `GitRunner` only returns `String?`, collapsing non-zero, timeout, exec failure, empty stdout, not-in-repo, and broken HEAD into nil. A real `.timeout` state requires changing the runner result type or adding side-channel error classification. That can ripple through every fake runner and resolver test.

The plan does not decide whether direct legacy branch probing remains. Even if `GitContextResolverCache` is wired, `initialWorkspaceGitMetadataSnapshot` still runs `git branch --show-current`, `git status`, and possibly `gh pr view`. If the motivation is reducing repeated subprocess work or protecting latency, caching only `ResolvedGitContext` may not move the actual bottleneck much. The plan should say what success looks like in terms of subprocess count or observed probe behavior.

The socket tests are not specified enough. "Send a `set_metadata` frame" could mean live Unix socket, direct private handler, or extracted parser/handler seam. Those are very different cost and reliability profiles. The plan should forbid substituting store-level tests for socket-handler tests if the acceptance criterion is security of external writes.

The plan does not address docs consistency beyond `skills/c11/references/metadata.md`. The global/project agent instructions say the canonical Codex file mirrors Claude's file and skill changes need sync discipline. If the skill reference is changed, the plan should say whether any generated/symlinked copy or canonical Claude-side source needs updating.

## Challenged Decisions

The "two acceptable resolutions" decision is the most serious flaw. If the plan recommends wiring, make wiring required. If documentation-only is still acceptable, then rewrite the acceptance criteria so cache/coordinator tests are not pretending to validate production behavior. Leaving both paths open is how the team gets another "PARTIAL but acceptable" result.

The recommendation to rename implementation enum cases deserves pushback. The spec names may be cleaner, but shipping code already uses `nil` and `.unknown`. Renaming to match a validation document may add churn without improving user behavior unless `.stale` and `.notInRepo` carry real semantic differences. The better decision may be: add `.stale` only if production needs distinct stale handling; otherwise update the spec to describe the existing nil/unknown behavior and stop pretending naming drift is a functional defect.

The stale worktree item should not be optional if the plan chooses the cache path. Caches make stale-worktree behavior more important, not less. If a removed worktree can be cached as valid, recreated, or nil-cached under a coarse mtime key, the sidebar can lie. Either solve stale invalidation in the cache design or explicitly defer the cache.

The theme opacity polish should be out. It is user-visible, unrelated to the architecture/test debt, and conflicts with the stated out-of-scope rule. It belongs in a tiny visual polish ticket or not at all.

Dead-code deletion should be lower priority than it appears. Removing `Workspace.orderedUniqueBranchDirectoryEntries()` may be fine, but this plan is already overloaded. Unless the dead code creates confusion for the coordinator/cache work, deleting it adds review surface without closing the architectural gap.

The validation-plan hygiene instruction should be changed. Do not edit the old C11-104 validation plan as if it always knew the follow-up outcome. Add a C11-106 section or a dated addendum that says which gaps were closed by this follow-up.

## Hindsight Preview

Two years from now, the likely "we should have known" is that a forward-looking abstraction became production architecture without a real contract. The current coordinator is a thin queue wrapper; making it "load-bearing" means designing lifecycle, cancellation, dependency tracking, and test seams. The plan treats that as incidental glue.

Another hindsight risk: the cache will be technically wired but only for the simplest cwd-to-branch case. Submodule panes, linked worktree deletion, branch changes in outer repos, and `.gitmodules` name changes will keep producing odd sidebar states. The early warning sign is tests that use fake paths and fake mtimes rather than real linked worktree and submodule fixtures with actual git metadata movement.

A third hindsight risk: AC20 gets "solved" with another sentinel test. If the test does not run the bad call in a subprocess and assert non-zero termination, it does not prove the precondition trips. The plan should state that explicitly.

Watch for these early warning signs:

1. The PR body says "coordinator wired for tests" but `TabManager.initialWorkspaceGitMetadataSnapshot` still calls `GitContextResolver.resolve` directly.
2. Cache tests instantiate `GitContextResolverCache` manually but no production code owns one.
3. Socket tests call `SurfaceMetadataStore.setMetadata(... source: .derived)` instead of the external `surface.set_metadata` handler.
4. Timeout tests use a fake runner returning nil instead of exercising process timeout/termination.
5. Submodule cache tests only touch the inner submodule HEAD and never change the outer superproject branch.
6. The validation plan is edited in place without a dated addendum, making the audit trail harder to trust.

## Reality Stress Test

Disruption 1: the implementer chooses the documentation-only path to keep the PR small. Then AC12 and AC17 cannot honestly pass as production behavior, AC20 is mostly irrelevant, and the ticket closes with the original drift preserved. The plan currently allows that outcome.

Disruption 2: the implementer chooses wiring and discovers it is not a drop-in. The PR grows into a `TabManager` probe lifecycle refactor, plus resolver result typing, plus cache dependency tracking. Review risk goes up, and the "no user-visible change" constraint becomes harder to maintain.

Disruption 3: CI exposes test fragility. Real timeout tests can add seconds or flake; socket-handler tests may require main actor/app state; precondition-crash tests need subprocess infrastructure. If these harnesses are not designed up front, the likely compromise is weak tests that satisfy names but not behavior.

If these hit simultaneously, the plan will either sprawl or retreat into documentation. The current acceptance criteria do not force a clean middle path.

## The Uncomfortable Truths

The plan is trying to make the C11-104 validation report look fully resolved without choosing which parts are actually worth resolving now.

The coordinator may not be the right abstraction yet. A queue wrapper plus a protocol is not automatically better than a direct resolver call on the existing probe queue. If there is only one deriver today, wiring the coordinator is valuable only if it establishes a real future contract. The plan does not define that contract.

The cache design is currently too simple for the displayed data. It might be fine for a single branch chip, but stacked submodule context has more dependencies than one HEAD mtime.

"Operator's call" appears too often for a ticket that is supposed to close concrete follow-up gaps. It hides decisions that should be made before delegating implementation.

The test work is not all "just add tests." Some tests require new runtime seams or helper harnesses. Calling them missing tests understates the implementation needed.

## Hard Questions for the Plan Author

1. Is C11-106 required to wire `DerivationCoordinator` and `GitContextResolverCache` into production, yes or no?

2. If documentation-only remains acceptable, which acceptance criteria are removed or rewritten so the plan does not pretend production cache/coordinator behavior exists?

3. Who owns the cache: `TabManager`, `DerivationCoordinator`, `GitContextDeriver`, or `GitContextResolver`?

4. What is the exact production call flow after wiring? Does `initialWorkspaceGitMetadataSnapshot` remain synchronous, or does git context apply in a separate async callback?

5. If git context applies separately, what generation token or expected-cwd guard prevents late coordinator results from writing stale derived metadata?

6. What are all filesystem dependencies for a cached `ResolvedGitContext` inside a submodule? Is one `HEAD` path enough?

7. Should the cache key include the resolved `headPath` string itself, not just cwd and mtime, to avoid collisions when git indirection changes?

8. How does the cache recover when a linked worktree is removed and later recreated at the same path with coarse filesystem mtimes?

9. Does adding `.timeout` require changing `GitRunner` from `String?` to a typed result? If not, how will the resolver distinguish timeout from ordinary git failure?

10. What harness will AC20 use to assert `dispatchPrecondition` crashes without killing the whole XCTest process?

11. What harness will AC16 and AC17 use to exercise the external socket handler rather than `SurfaceMetadataStore` directly?

12. Are socket metadata tests allowed in `c11LogicTests`, or do they require the host-backed `c11-unit` path?

13. Why is theme-backed opacity included in a no-user-visible-render-change follow-up?

14. Should enum renaming be pursued for functional clarity, or is this just changing code to satisfy spec wording after the fact?

15. If `.stale` clears chips just like nil, what behavior requires a separate `.stale` state?

16. Should C11-106 preserve the C11-104 validation plan as historical evidence and write a new addendum instead of editing it in place?

17. What exact baseline should the delegator start from: local `main`, merge commit `2b1be4220`, or latest remote `main`?

18. What is the performance success criterion after cache wiring: fewer git invocations, shorter probe latency, no typing regression, or just architectural consistency?

19. If the legacy branch/status/PR probes remain uncached, what problem does the new cache materially solve?

20. What is the smallest PR that would make the next validation report say "PASS" rather than another cluster of PARTIALs?
