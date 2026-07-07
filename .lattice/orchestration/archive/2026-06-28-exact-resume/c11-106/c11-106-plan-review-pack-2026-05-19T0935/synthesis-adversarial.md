# Adversarial Synthesis — C11-106 (C11-104 follow-ups)

- **PLAN_ID:** c11-106-plan
- **MODELS SYNTHESIZED:** Claude, Codex
- **MODELS MISSING:** Gemini (API quota exhausted at synthesis time — third adversarial perspective unavailable; treat the consensus list as "2-of-3" rather than "3-of-3" agreement)
- **TIMESTAMP:** 20260519-0935
- **Plan under review:** `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01KS06C8QZ43D6NH203QFE3SMQ.md`

## Executive Summary

Both reviewers (Claude, Codex) converge on the same headline diagnosis: **the plan is faithful to the C11-104 audit but is structurally a list of decisions disguised as a list of tasks.** Its single biggest defect is that it keeps two incompatible architectural paths open in parallel — "wire `DerivationCoordinator` and `GitContextResolverCache` into production" vs. "document them as forward-looking-only" — while writing acceptance criteria that only make sense under the first path. That ambiguity is not harmless: it permits a delegator to satisfy the letter of the plan while leaving the core drift unresolved.

Both reviewers also flag **systemic underestimation of "wire it in"**. The plan budgets ~50–100 lines of glue. In reality, the existing production path (`TabManager.initialWorkspaceGitMetadataSnapshot`) is a `nonisolated static` synchronous snapshot running on a legacy probe queue, while `DerivationCoordinator.run` is async and completes on main. Bridging those is not a call-site swap; it is a probe-lifecycle refactor with an ownership model, an injection seam, generation-token discipline, and a cache-key design that has to survive submodules and linked worktrees.

A third strong consensus point: **the plan bundles too much into one PR** (wiring + four missing tests + enum rename + `.stale` state + dead-code deletion + theme-opacity polish + validation-plan hygiene) without bisection granularity, without a priority/drop order, and without committing to a typing-latency smoke pass — the very thing PR #181 never validated.

Gemini's perspective is absent. The points below are the consensus of two reviewers, not three; the missing third would have been most likely to add weight to (or contest) the YAGNI argument and the cache-key sufficiency claims around submodules. Treat that gap as a known unknown.

**Net recommendation distilled from both reviewers:** before sending to implementation, the plan author must (a) pick one path and stop offering "operator's call" branches in the body, (b) split the work into multiple PRs with explicit ordering, (c) commit to a typing-latency smoke pass on a tagged build, and (d) specify the test harnesses for AC16/AC17/AC20 (socket handler vs. store, subprocess-trap for `dispatchPrecondition`) rather than treating them as "missing tests."

---

## 1. Consensus Risks (Both Models Flag)

These are the highest-priority items — concerns surfaced independently by both Claude and Codex.

1. **"Two acceptable resolutions" in Section 1 is a structural flaw, not a flexibility feature.** The plan keeps both "wire it in" and "document as forward-looking-only" open, but every hard AC assumes the first path. A delegator can satisfy the plan while preserving the architectural drift. Both reviewers: pick one before starting; "operator's call" without an explicit checkpoint is delegation-by-default.

2. **"Wire it in" is systemically underestimated.** The plan describes it as ~50–100 lines of glue. In reality:
   - `initialWorkspaceGitMetadataSnapshot` is `nonisolated static` and synchronous; `DerivationCoordinator.run` is async and completes on main. Bridging them is a probe-lifecycle decision, not a call swap.
   - The plan never names cache ownership (`TabManager` vs `DerivationCoordinator` vs `GitContextDeriver` vs `GitContextResolver`), the injection/testing seam, or how stale-async results are guarded against the existing gen-token contract.
   - Neither reviewer believes "50–100 lines of glue" survives contact with the existing snapshot apply path.

3. **The cache key `(cwd, mtime(headPath))` is not obviously sufficient.** Both reviewers attack this from different angles that arrive at the same conclusion:
   - Submodule panes depend on the inner HEAD, the outer superproject HEAD, `.gitmodules`, and `--git-common-dir`; one HEAD path cannot represent that dependency graph.
   - mtime is fragile under clock skew (NTP correction, rsync/Time Machine preserving source mtimes, `git update-ref` overwriting with identical mtime), and the plan inherits the current invalidation strategy without examining whether it is correct for production traffic on a 64-CPU host running 40+ panes.
   - Linked-worktree removal-and-recreate at the same path is a real workflow for c11's target user and the cache key does not defend against it.

4. **The plan bundles too many categories of work into one PR.** Both reviewers list essentially the same six-to-eight categories and both conclude the bundle is the default, not a deliberate choice. Neither sees a bisection plan for a post-merge regression (especially AC33 typing latency). Both recommend splitting — at minimum, land the missing tests as a safety net before the wiring change touches anything.

5. **The four "missing tests" are not all simple test additions; some require new runtime seams.**
   - **AC16** (`source=derived` socket rejection) lives in `TerminalController`'s external socket handler, not in `SurfaceMetadataStore`. Testing it at the store level would be a fake — both reviewers warn against substituting store-level tests for socket-handler tests.
   - **AC20** (`dispatchPrecondition` trip) cannot be caught with a normal in-process XCTest assertion — `dispatchPrecondition` is `EXC_BAD_INSTRUCTION`, not `XCTFail`. Requires a subprocess fork or external test binary. Without explicit guidance the delegator will recreate the previous sentinel-test mistake.
   - **AC14** (subprocess timeout) requires stubbing `git` so it sleeps and asserting a SIGTERM-then-SIGKILL contract within a deterministic time budget — fixture infrastructure that may not exist in `c11LogicTests`.
   - **AC12** linked-worktree + submodule fixtures are meaningfully harder than the plan implies (real `git submodule add`, superproject commits, in-tree fixture cost vs. on-the-fly setUp fragility).

6. **The enum rename (`.unknown` → `.noBranch`, add `.notInRepo`, add `.stale`) is not search-and-replace.** Both reviewers: this is a type-shape change with semantic consequences for `WorktreeChipProjector`, `applyDerivedWorktreeBranchMetadata`, `SurfaceMetadataStore`, the socket read path, and every snapshot/test fixture. A `default:` clause anywhere in the codebase hides the rename from the compiler. Claude calls it "compiler-driven discovery"; Codex calls it "semantic churn." Same point.

7. **The "no user-visible sidebar render change" out-of-scope rule conflicts with the optional theme-opacity polish (M6).** Both reviewers flag this. Theme-backed opacity is visible. Branch/no-branch handling can become visible if `.noBranch` is encoded as empty string vs `(no branch)` vs nil. The plan's own out-of-scope clause contradicts its own optional work.

8. **Dead-code deletion (Section 5) relies on a `grep` falsification protocol that is insufficient in Swift.** Protocol witness tables, `@objc` exposure, KeyPath references, persistence migrations, snapshot-restore paths, plan-capture, Lattice plugin extensions, and test-only consumers can all dodge a grep. Both reviewers want a stronger gate (build + run both `c11-logic` and `c11-unit` schemes after deletion); both note that "confirm dead, delete" in a PR already overloaded with architectural changes is the most innocent-looking and most regression-prone line item.

9. **"Operator's call" appears too many times for a closing-follow-up ticket.** Both reviewers count multiple branches in the plan (Section 1, Section 4, Section 6) where the plan defers a real decision to the operator without obligating consultation. In practice the delegator picks, rationalizes in the PR body, and the operator finds out at review. The fix is the same in both reviews: either make the picks before starting, or explicitly block on operator decision; do not ship the option of consultation without the obligation.

10. **The validation-plan hygiene item (Section 7) will not happen as written.** Both reviewers: it is last, it has no AC, it competes with code work, it has no enforcement, and "annotating the old C11-104 validation plan in-place" is itself questionable practice. Codex specifically warns against mutating historical evidence; Claude predicts it gets dropped 80% of the time. Both prefer a C11-106 dated addendum over in-place edits.

11. **Tests written after shipping the feature get written to match the implementation, not the spec.** AC14 is the cleanest example: the implementation timeout is 5s, the spec says 2s. If the test is written first and the implementation kept at 5s, the test cements the drift. Both reviewers: commit to the spec value or commit to a SPEC amendment before writing the test, not after.

---

## 2. Unique Concerns (One Model Only)

These are risks raised by only one reviewer. They are not lower-confidence; they are simply unconfirmed by the second perspective and worth investigating on their own merits.

### From Claude only

12. **YAGNI is not on the menu of resolutions.** The plan treats "wire it in" and "document forward-looking" as the only two options. A third option — delete `DerivationCoordinator` and `GitContextResolverCache` as premature abstractions and write a thin synchronous bounded-size dict cache inside `GitContextResolver`, adding the coordinator back when a real second deriver appears (host/SSH/container/kubectl) — is never considered. If "is this seam load-bearing for any work in the next 90 days?" honestly answers "no," that matters.

13. **PR #181's typing-latency commitment (AC33) was never validated by the operator.** The follow-up is layering more work on the same hot path without anyone having typed 100 chars in a worktree pane on a tagged build. Doubling down on an unvalidated baseline.

14. **No rollback contingency if the parent PR's chip feature is disabled by S9.** If AC33 fails post-merge and the operator flips `sidebarShowBranchDirectory` to off, the chip feature is hidden by default. Does this follow-up's wiring change still ship? Does it gate behind the same toggle? The plan never asks.

15. **No commit-by-commit guidance for bisection.** Six categories in one PR with no commit-discipline note means a squash merge erases bisection granularity for a future AC33-style regression.

16. **The `cmux` compat alias path is unmentioned.** If AC16's socket rejection is verified through the `c11` socket only, the test exercises one entry point and assumes the `cmux` alias inherits. May be true, but should be named.

17. **Settings UI theme-key drift.** The chip toggle's localization keys are populated for 6 locales as of #181. The dim-opacity ThemeKey work (M6) would add two more theme keys. The next theme JSON pass may not realize they exist and ship a theme with hardcoded defaults that look subtly off.

18. **Concurrent PR risk to `TabManager.swift`.** It is a 5,539-line god-class with high traffic. The C11-99 AAR (`629888044`) already layered on top of #181; further concurrent C11-99/C11-103 work could collide. A merge conflict that "looks resolved" can leave both the legacy direct call and the new coordinator call running, wasting one probe per pane on launch and adding 50–150ms on a many-pane workspace.

19. **AC19 (restore-warmpath) defer has no ticket number.** "Real follow-up but separate ticket" without a Lattice ID is informally indefinite. Chips paint blank on session restore — exactly the kind of thing operators notice.

20. **No telemetry ask for the cache.** If the cache lands but no one measures hit/miss rates in production, regressions surface as "slow chip render" complaints months later with no instrument to diagnose.

21. **Section 1's "documented as forward-looking-only" branch writes its own executioner's warrant.** Section 5 (dead-code deletion) gives the next agent a policy that lets them delete the documented-only seam in the next pass. The plan does not defend against eating its own tail.

22. **Two delegators might be safer than one.** Tests (Section 2) and wiring (Section 1) are conceptually independent. Two delegators in parallel could ship the tests first as a safety net, then the wiring in a second PR. The plan assumes one delegator.

### From Codex only

23. **Result ordering under a genuinely async coordinator is undefined.** The existing gen-token and expected-cwd guards protect the synchronous snapshot apply. If git context becomes a separate async callback, the plan must say whether it reuses the same generation token, creates a new one, or stays bundled. This is exactly the AC13 stale-async risk and the plan is silent.

24. **The `.timeout` state is under-designed at the runner level.** `GitRunner` currently returns `String?` and collapses non-zero, timeout, exec failure, empty stdout, not-in-repo, and broken HEAD all into `nil`. A real `.timeout` state requires changing the runner's result type or adding side-channel classification — which then ripples through every fake-runner test and every resolver test.

25. **The plan's success criterion is "architectural consistency," not a measurable performance number.** What does cache wiring buy in operator-visible terms? Fewer git invocations on cold launch? Shorter probe latency? Fewer subprocess spawns per minute? No typing regression? Without a number, "wire the cache" is a code-shape goal, not a behavior goal. If `initialWorkspaceGitMetadataSnapshot` still runs `git branch --show-current`, `git status`, and `gh pr view` uncached, the cache may not move the bottleneck the team thinks it moves.

26. **Docs-consistency surface beyond `metadata.md` is unmentioned.** Global/project agent instructions specify Codex-side mirror discipline for skill changes. If `skills/c11/references/metadata.md` is edited, the plan does not say which other canonical/generated/symlinked surfaces need to sync.

27. **The local baseline question is concrete and load-bearing.** The reviewer's workspace has `main` behind the referenced merge even though `2b1be4220` exists. The plan should explicitly require starting from the merged C11-104 baseline (or rebasing on current remote `main`); otherwise an agent will inspect the wrong tree and produce nonsense edits.

28. **Dead-code deletion priority should be downgraded.** Both reviewers flag it as risk-laden, but Codex specifically argues it should be dropped from this PR unless the dead code creates active confusion for the coordinator/cache work. Unbundle.

29. **Stale-worktree handling becomes more important when caching, not less.** If a removed worktree can be cached as valid (or recreated under a coarse mtime key), the sidebar can lie. Codex's framing: either solve stale invalidation in the cache design or explicitly defer the cache. The plan's framing (stale as "optional but recommended") gets the priority backwards.

---

## 3. Assumption Audit (Merged & Deduplicated)

All assumptions either reviewer flagged the plan as making, consolidated and de-duplicated. Marked **(L)** = load-bearing (the plan collapses without it), **(W)** = worth examining but not load-bearing.

### Architecture & wiring

1. **(L) `DerivationCoordinator` can replace the direct resolver call with ~50–100 lines of glue.** Both reviewers reject this. The existing synchronous `nonisolated static` snapshot path and the async coordinator have incompatible lifecycles.

2. **(L) `GitContextResolverCache` is the right cache primitive to wire in.** The plan assumes the existing shape (LRU, `(cwd, mtime(headPath))` key, `initialWorkspaceGitProbeQueue` execution context, `DerivationCoordinator.run` entry point) is correct for production — a vote of confidence in speculatively-authored shapes.

3. **(L) The cache key `(cwd, mtime(headPath))` is sufficient.** Both reviewers contest this for submodules, linked worktrees, clock skew, and identical-mtime overwrites.

4. **(L) The coordinator's threading contract survives the wiring.** `DerivationCoordinator.run` has a `dispatchPrecondition(.notOnQueue(.main))` guard. Whether the wiring keeps the current synchronous probe path (coordinator wrapping resolver, precondition still passes) or splits the snapshot lifecycle (every caller's synchrony expectation changes) is undefined.

5. **(W) The existing gen-token + expected-cwd discipline carries over.** If git context becomes an async callback, ordering guarantees may not. (Codex.)

### Tests

6. **(L) The four missing tests are achievable in `c11LogicTests`.** AC14 (process timeout), AC16 (socket-handler rejection), AC17 (socket read semantics), and AC20 (`dispatchPrecondition` crash) all may require runtime seams, harness infrastructure, or host-mode execution. Both reviewers warn against shipping fake tests at the wrong level.

7. **(L) Cache fixture tests can be built without real linked-worktree / submodule git fixtures.** The plan glosses the fixture cost. (Claude explicitly; Codex names it as an early-warning sign.)

8. **(W) `XCTExpectFailure` can catch a `dispatchPrecondition` trip.** It cannot — needs subprocess infrastructure. (Both reviewers.)

### Semantics

9. **(L) The enum rename is search-and-replace.** Both reviewers: it is a type-shape change with semantic effects across projector, store, derived metadata, socket reads, and tests.

10. **(L) Adding `.stale` / `.notInRepo` / `.noBranch` is "just naming."** No — it changes cache values, projection, write-path semantics, and observable socket reads. (Both.)

11. **(W) `.stale` clears chips the same way `nil` does, so behavior is unchanged.** If so, why add the state? (Codex.)

12. **(W) `GitRunner` returning `String?` is adequate for a real `.timeout` state.** Not without a typed result or side-channel error classification. (Codex.)

### Scope & process

13. **(L) Six categories of work fit in one PR.** Both reviewers: no.

14. **(L) The dead-code `grep` is sufficient to prove no consumers.** Swift's protocol witness tables, `@objc` exposure, KeyPath references, persistence migrations, and snapshot-restore paths all evade grep. (Both.)

15. **(L) CI green is sufficient evidence of safety.** Not for typing latency — both reviewers want an operator-driven tagged-build smoke pass. (Claude explicit; Codex implicit via "no user-visible change" critique.)

16. **(L) `origin/main` will accept the PR cleanly.** Concurrent work on `TabManager.swift` may force a merge resolution the plan doesn't budget for. (Claude; Codex names the baseline question.)

17. **(L) `2b1be4220` is the implementer's starting baseline.** The reviewer's workspace is behind it; the plan should require an explicit baseline. (Codex.)

18. **(W) The operator agrees with the recommendations (wire it in; rename the enum).** Recommendations are not commitments. (Claude.)

19. **(W) Validation-plan hygiene can be done by editing the old C11-104 validation plan in place.** Codex specifically warns: that mutates historical evidence. Prefer a dated addendum.

20. **(W) PR #181 stays merged.** If AC33 forces a revert, this follow-up's premise evaporates. (Claude.)

21. **(W) Skill/docs sync stops at `metadata.md`.** Other canonical surfaces (Codex-side mirror, generated copies, symlinks) may also need updating. (Codex.)

22. **(W) One delegator is the right shape.** Two could parallelize tests and wiring into separate PRs. (Claude.)

---

## 4. The Uncomfortable Truths (Recurring Hard Messages)

These are the hard messages that recur across both reviewers, distilled.

1. **The plan is reactive, not architectural.** Every section maps to a validator finding. That is good (work is grounded) and worrying (the plan is a derivative of an audit). If the validator missed something — and both reviewers list candidates (cache interaction with `nonisolated static`, submodule dependency graph, async ordering under gen-tokens, runner result-type design, socket-handler vs. store conflation) — the plan misses it too.

2. **The coordinator may not be the right abstraction yet.** A queue wrapper plus a protocol is not automatically better than a direct resolver call on the existing probe queue. With only one deriver today, wiring is valuable only if it establishes a real future contract. Neither reviewer can find that contract defined anywhere in the plan. (Codex explicit; Claude raises YAGNI as the unstated third option.)

3. **The cache design is too simple for the displayed data.** It may be fine for a single branch chip. It is not fine for stacked submodule rows, linked-worktree removal-and-recreate, clock-skew artifacts, or identical-mtime overwrites. Both reviewers.

4. **"Operator's call" is doing work that hides commitments.** Three sections punt to the operator without obligating consultation. The delegator picks, the plan author rationalizes in the PR body, the operator finds out at review. Both reviewers want this fixed up front.

5. **The validation-plan hygiene item will not happen as written.** Last, no AC, competes with code work, no enforcement. Both reviewers predict it gets dropped. Codex additionally objects to the mechanism (in-place editing of historical evidence).

6. **Tests written after a feature ships drift toward what the code does, not what the spec demanded.** AC14 (5s vs 2s timeout) is the canonical example. Both reviewers want the spec/implementation reconciliation made before the test gets written.

7. **The follow-up never addresses the typing-latency commitment the parent PR never validated.** PR #181's AC33 was deferred. This plan layers more work on the same hot path without proposing an operator-driven smoke pass. Doubling down on an unvalidated baseline. (Claude explicit; Codex implicit in "no user-visible change" critique.)

8. **The plan is shippable, competent, and faithful to the audit — and it's still a list of decisions disguised as a list of tasks.** Both reviewers arrive at this same closing assessment.

9. **The C11-104 validation report is being treated as a closing list rather than a decision input.** Both reviewers: the report exists to inform what to do; the plan is treating it as what to do. Some of the gaps the validator listed are not worth closing now; some need architectural decisions before they can be honestly closed at all.

---

## 5. Consolidated Hard Questions (Deduplicated, Numbered)

All questions raised by either reviewer, merged. Identical questions consolidated. Numbered for the plan author to respond to point-by-point. Tagged **[C]** = from Claude, **[X]** = from Codex, **[B]** = both reviewers raised it (with possibly different framings).

### Path decision

1. **[B] Is C11-106 required to wire `DerivationCoordinator` and `GitContextResolverCache` into production — yes or no?** If you cannot pick without the operator, say "blocked on operator decision" and don't start work.

2. **[X] If documentation-only remains acceptable, which acceptance criteria are removed or rewritten so the plan does not pretend production cache/coordinator behavior exists?**

3. **[C] Have you considered just deleting `DerivationCoordinator` and `GitContextResolverCache` as premature abstractions, with a clean note that they should be added back when the second deriver lands?** YAGNI was not on your menu of resolutions.

4. **[C] Section 1's "documented as forward-looking-only" branch — what stops the next agent from deleting the cache and coordinator as dead code under your own Section 5 dead-code-cleanup policy?**

### Wiring details

5. **[B] If you wire `DerivationCoordinator` into production, do you delete the direct call to `GitContextResolver.resolve(cwd:)` at `TabManager.swift:1724`, or do you keep both paths during a transition?** If both, for how long, and what tests prove they agree?

6. **[X] Who owns the cache: `TabManager`, `DerivationCoordinator`, `GitContextDeriver`, or `GitContextResolver`?**

7. **[X] What is the exact production call flow after wiring? Does `initialWorkspaceGitMetadataSnapshot` remain synchronous, or does git context apply in a separate async callback?**

8. **[X] If git context applies separately, what generation token or expected-cwd guard prevents late coordinator results from writing stale derived metadata?**

### Cache design

9. **[X] What are all filesystem dependencies for a cached `ResolvedGitContext` inside a submodule? Is one `HEAD` path enough?**

10. **[X] Should the cache key include the resolved `headPath` string itself, not just cwd and mtime, to avoid collisions when git indirection changes?**

11. **[C] What's the cache-invalidation behavior under clock skew?** mtime is not monotonic. If NTP corrects the clock backward, a cached entry can have a future mtime relative to "now," but a future write can produce a smaller mtime than the cached one. Does that produce a stale cache hit?

12. **[X] How does the cache recover when a linked worktree is removed and later recreated at the same path with coarse filesystem mtimes?**

13. **[X] If the legacy branch/status/PR probes remain uncached, what problem does the new cache materially solve?**

14. **[X] What is the performance success criterion after cache wiring: fewer git invocations, shorter probe latency, no typing regression, or just architectural consistency?**

### Test harnesses

15. **[B] What harness will AC20 use to assert `dispatchPrecondition` crashes without killing the whole XCTest process?** `XCTExpectFailure` does not trap `EXC_BAD_INSTRUCTION`. Subprocess fork? Separate test binary? Be concrete.

16. **[B] What harness will AC16 (and possibly AC17) use to exercise the external socket handler in `TerminalController` rather than `SurfaceMetadataStore` directly?** Substituting store-level tests for socket-handler tests is explicitly disallowed.

17. **[X] Are socket metadata tests allowed in `c11LogicTests`, or do they require the host-backed `c11-unit` path?**

18. **[C] AC14 timeout test: are you writing the test against the spec's 2s or the implementation's 5s?** And if 2s, are you also changing the implementation? Both? Just the test? Where does that decision get recorded?

19. **[C] AC16 socket-frame rejection: are you exercising the test through the c11 socket only, or also through the `cmux` compat alias path?**

20. **[C] AC17 socket get-metadata read: does `c11 get-metadata --key worktree` return an empty string, nil, or an error when the pane is in `.notInRepo`?** What does your test assert? Is that consistent with `--key branch`'s behavior?

### Enum + state design

21. **[C] Section 3 enum rename: have you confirmed every `switch` over `BranchValue` and `GitContextKind` in the codebase is exhaustive and will compile-error you into a complete rename?** If any uses `default`, the compiler won't help.

22. **[X] Should enum renaming be pursued for functional clarity, or is this just changing code to satisfy spec wording after the fact?**

23. **[B] Section 4 `.stale` state: when does the deriver actually return `.stale` vs returning `nil` (cwd directory gone)?** What's the precise observable signal? `git rev-parse --show-toplevel` returning nonzero with a specific error? A check on the worktree pointer file? Be concrete.

24. **[X] If `.stale` clears chips just like nil, what behavior requires a separate `.stale` state?**

25. **[X] Does adding `.timeout` require changing `GitRunner` from `String?` to a typed result? If not, how will the resolver distinguish timeout from ordinary git failure?**

### Scope, ordering, and rollback

26. **[B] Are you bundling all six sections in one PR, or splitting?** If bundling, why? If splitting, how?

27. **[C] What is your bisection plan if AC33 (typing latency) regresses post-merge?** Multi-commit branch with one commit per section? Squash? Without a plan, "fix forward" is the default and there is no rollback granularity.

28. **[C] What happens to this follow-up if the operator's smoke pass on #181 fails AC33 and the chip feature is feature-flagged off by default?** Does this PR still merge? Does its scope change?

29. **[C] Section 5 dead-code deletion: what's your falsification protocol?** Beyond `grep`, are you running both `c11-logic` and `c11-unit` schemes after the delete? Are you checking snapshot-restore, plan-capture, and persistence migrations?

30. **[C] Section 6 timeout 5s → 2s: have you measured how often the current 5s actually times out on a realistic operator's machine?** "Conservative" is a vibe; data is a number.

31. **[C] Why is theme-backed opacity included in a no-user-visible-render-change follow-up?** (Codex raises this independently as a scope conflict.)

### Process & artifacts

32. **[C] Section 7 validation-plan hygiene: who owns it after the PR merges?** If the delegator runs out of time, does the operator do it? Is there a checklist item in PR review?

33. **[X] Should C11-106 preserve the C11-104 validation plan as historical evidence and write a new addendum instead of editing it in place?**

34. **[X] What exact baseline should the delegator start from: local `main`, merge commit `2b1be4220`, or latest remote `main`?**

35. **[C] AC criterion 6 says the PR body links to this ticket and to PR #181 and describes which AC numbers it closes. Which AC numbers, specifically?** If the answer is "depends on what we ship," that's a sign the scope is uncertain — clarify the floor and ceiling.

36. **[C] The plan says "CI green; no regressions in `c11-logic` or `compat-tests`" as AC #5. Are you running anything beyond CI?** Specifically, are you running a tagged-build typing-latency smoke pass under `./scripts/reload.sh --tag c11-106` before merge?

37. **[C] Is there a Lattice ticket for the AC19 restore-warmpath defer? If not, when does it get filed and by whom?** "Real follow-up but separate ticket" is not a commitment without a number.

38. **[X] What is the smallest PR that would make the next validation report say "PASS" rather than another cluster of PARTIALs?** (This is the synthesized closing question — answer it well and the rest of the plan tightens automatically.)

---

## Closing Note for the Plan Author

Both reviewers landed in the same place: the plan is competent, faithful to the audit, and shippable as written — and that is the problem. It is shippable as a list of partials. The work it actually wants to do (commit to wiring or kill the seam; specify cache dependencies for submodules and linked worktrees; design test harnesses for socket and `dispatchPrecondition`; ship a typing-latency smoke pass) is harder than the plan implies. **Pick before delegating, split before bundling, validate before merging.** The third reviewer (Gemini) was not available, so treat the consensus list above as 2-of-3 confidence, not 3-of-3 — and weigh the unique concerns proportionally higher than you would if a third confirming voice were on the record.
