# Standard Plan Review Synthesis — C11-106

- **Plan ID:** `c11-106-plan`
- **Lens:** PlanReview-Standard (analytical / architectural)
- **Timestamp:** 2026-05-19T09:35
- **Sources synthesized:** Claude (Opus 4.7, 1M), Codex
- **Missing input:** Gemini Standard review — Gemini API was at quota at review time. Only 2 of 3 perspectives are reflected here; treat the synthesis as 2-model rather than 3-model.

---

## Executive Summary

1. Both reviewers agree on the underlying diagnosis: C11-106 targets the right surface (closing audit drift from C11-104), the seven-section decomposition matches the audit, and the explicit "out of scope" boundary around AC19 and AC31–33 is correct.
2. The reviewers diverge sharply on **readiness**. Claude returns **"ready to execute with minor clarifications"** — the open items are scope-clarifying, not scope-shifting. Codex returns **"needs revision before execution"** — the open items, particularly cache key semantics and the wire-vs-document fork, are load-bearing architectural choices that a delegator cannot resolve mid-flight.
3. The single load-bearing question in the plan is **Section 1: wire `DerivationCoordinator` + `GitContextResolverCache` into production, or document them as forward-only.** Both reviewers flag this; both agree the plan should commit to one path before delegation; they differ on which path is right and on how much downstream specification that decision requires.
4. Codex surfaces a category Claude missed entirely: **cache correctness for submodules and nil-head states.** A cache keyed on `(cwd, mtime(headPath))` is insufficient for submodule cwds (which resolve both outer and inner contexts) and risks sticky negative results for "not yet a repo" cases. This is the highest-impact unique finding in the pack.
5. Claude surfaces a category Codex underweights: **line-reference drift, commit hygiene inside the single PR, and CI/testing-policy guardrails** (no untagged `c11 DEV.app`, `c11-logic` is the only safe local test loop). These are delegator-experience concerns rather than architectural ones, but they matter for a ticket that will be executed by a sub-agent.
6. **Missing third perspective.** Gemini's Standard review would normally provide an independent tie-breaker on the wire-vs-document question and on whether the AC20 precondition test is achievable in-process. Absent that signal, treat the readiness verdict as a 1-1 split that leans toward "revise before delegating" because Codex's cache-correctness gaps are concrete and unaddressed by the current plan text.

**Consolidated verdict: revise the plan to commit to a production architecture path and to specify cache semantics, then it is ready to execute.** The structural shape is right; the under-specification is real but surgical.

---

## 1. Where the Reviewers Agree (Highest Confidence)

1. **The ticket should exist and the scope is correctly framed.** Both reviewers explicitly endorse C11-106 as the right follow-up to C11-104 and confirm the seven-section decomposition maps cleanly to the validation audit's PASS/PARTIAL/FAIL grid.
2. **Section 1 (coordinator/cache wiring) is the load-bearing item.** Both treat this as the architectural pivot of the ticket; everything else is cleanup that orbits the decision made here.
3. **The "wire it in OR document forward-only" fork must collapse to a single path before delegation.** Both reviewers identify the dual-acceptable resolution as a planning gap, not a flexibility feature. A delegator ticket needs one target.
4. **AC19 (restore warm-path) and AC31–33 (operator smoke) are correctly out of scope.** Both reviewers explicitly endorse the carve-out.
5. **AC20 (main-thread precondition trip) is under-specified and likely fragile as written.** Both reviewers flag the "`XCTExpectFailure` or precondition-fatal pattern" wording as not equivalent and not obviously achievable in-process. Both recommend either committing to a specific safe pattern (subprocess/helper) or downgrading to a documented sentinel.
6. **Enum renaming is more than vocabulary.** Both reviewers note that `.noBranch` / `.notInRepo` / `.stale` change resolver state semantics, not just names — and that the rendering/metadata contract for each state needs to be specified, not implied.
7. **Validation-plan hygiene (Section 7) should produce a v3 / addendum, not an in-place edit of the v2 plan.** Both reviewers reach this conclusion. The v2 plan is an audit artifact; rewriting it blurs what PR #181 was judged against. Codex states this more emphatically; Claude states it as a preference.
8. **Section 5 (dead-code cleanup) deserves a softer pass condition.** Both reviewers warn that `Workspace.orderedUniqueBranchDirectoryEntries()` and related helpers may still feed legacy callers and that "grep and delete" is the right method but should be guarded by "no behavior change," not promoted to a hard AC.
9. **The "~50-100 lines of glue" cost estimate is optimistic if the recommended wiring path is taken.** Both reviewers (Codex more explicitly, Claude in Q15) flag that submodule/linked-worktree cache fixtures plus threading-model preservation could push the real number meaningfully higher.
10. **Optional polish items (timeout 5s→2s, hardcoded dim opacity) are real drift from the v2 SPEC.** Both reviewers acknowledge they are genuine and bounded. Both also implicitly recommend either promoting them to mandatory or accepting that "optional" will mean "deferred indefinitely."

---

## 2. Where the Reviewers Diverge (The Disagreement Itself Is Signal)

1. **Readiness verdict.**
   - Claude: **"ready to execute with minor clarifications."** Open items are framed as Q&A the delegator can resolve with one ping to the operator.
   - Codex: **"needs revision."** Open items are framed as architectural specification gaps that must be closed by the plan author before a delegator can start.
   - **Signal:** the two reviewers disagree on whether the open items are "scope-clarifying" (Claude) or "scope-shifting" (Codex). The disagreement maps to how each reviewer weights cache-correctness risk: Claude does not raise it; Codex makes it the centerpiece. If you believe Codex's cache concerns are real, the verdict tilts toward "revise"; if you believe they can be handled inline during implementation, the verdict tilts toward "ready."

2. **Recommended architectural path.**
   - Claude: **"wire it in."** Recommends the plan's recommended path, treats it as low-risk (~50–100 LOC), and frames the alternative ("forward-only") as defensible but a worse use of the moment.
   - Codex: **explicitly recommends Alternative B** — cache-aware git-context helper plus coordinator documented as a future seam. Argues the current `DerivationCoordinator` is too thin (no generation guards, no expected-cwd checks, no retry, no multi-deriver aggregation) to be load-bearing without a larger refactor.
   - **Signal:** Codex thinks "wire it in" implies more than the plan admits, and that the plan conflates "make the cache load-bearing" (cheap, useful) with "make the coordinator load-bearing" (expensive, premature). This is the most actionable disagreement in the pack — splitting the cache decision from the coordinator decision is a planning move neither reviewer's verdict assumes.

3. **Scope and risk of submodule cache fixtures.**
   - Claude: mentions the linked-worktree + submodule fixture requirement as a strength (Section 1 inherits the trident pack's correction on `git rev-parse --git-path HEAD`) and asks a clarifying question (Q15) about whether existing fixtures exist.
   - Codex: treats submodule cache invalidation as the technical centerpiece of the ticket and argues the proposed key `(cwd, mtime(headPath))` is insufficient because submodule cwds resolve both outer and inner contexts. Recommends either excluding submodule contexts from the cache or keying on multiple HEAD paths.
   - **Signal:** this is the highest-stakes divergence in the pack. If Codex is right about the cache key being insufficient, Section 1 cannot ship as currently described — the AC12 cache invalidation tests would either pass against an incorrect cache or fail because the cache is invalidating too aggressively. Claude does not engage with the submodule key question at all.

4. **Caching nil / negative results.**
   - Claude: silent on this question.
   - Codex: explicit weakness — caching nil when `headMtime` is nil collapses "not in repo," "missing cwd," "bare clone," "timeout," and "broken gitdir" into one sticky negative result that survives until eviction. Recommends a policy: only cache when a resolved HEAD path exists.
   - **Signal:** another concrete correctness gap that the plan does not address. This is independently actionable and inexpensive to specify in the plan text.

5. **`GitRunner` API shape for timeout.**
   - Claude: silent.
   - Codex: explicit — `GitRunner.run` returns `String?`, which cannot distinguish timeout from non-zero exit / missing git / not-in-repo / bare clone / deleted branch. Adding `.timeout` requires either a result enum, a timeout-aware runner API, or accepting that timeout maps to nil and testing only process termination. The plan should choose.
   - **Signal:** Codex's read is correct on the current `GitRunner` shape. Claude's framing of AC14 ("Either `XCTExpectFailure` around a main-thread invocation, or precondition-fatal test pattern") doesn't address the runner-API question at all.

6. **Section 4 (`.stale` state) — co-traveller with Section 3, or deferred?**
   - Claude: argues `.stale` should be promoted from optional to mandatory because it shares the enum-migration cost with Section 3 (Q4).
   - Codex: argues `.stale` is not merely naming and that the rendering/metadata contract must be specified before deciding (Weakness 5, Q8).
   - **Signal:** both reviewers reject the plan's neutrality on `.stale`, but for different reasons. Claude wants the work done now to save migration cost; Codex wants the contract defined now so the work means something when done. Both signals point in the same direction (specify it in the plan), but the specification depth differs.

7. **Commit hygiene inside the single PR.**
   - Claude: raises Q2 — should the delegator land Section 1 as a separable commit so it can be reverted independently if CI has fallout?
   - Codex: not raised.
   - **Signal:** Claude's concern is operationally real (CI revertibility) but tactical; Codex's concerns are architectural. Neither reviewer suggests splitting the ticket into two PRs as the default — both treat the single-PR shape as acceptable for the scope.

8. **`TabManager.swift:1724` line reference accuracy.**
   - Claude: notes the line reference matches the post-#181 merged state, not local `main` HEAD; asks the plan author to restate it as a function name (Q1).
   - Codex: not raised.
   - **Signal:** small but worth fixing — line numbers drift, function names don't.

---

## 3. Unique Insights (One Reviewer Only)

### Surfaced by Codex only

1. **Cache key insufficiency for submodule cwds.** The proposed `(cwd, mtime(headPath))` does not catch superproject HEAD changes when the resolved context spans both outer and inner repos. This is concrete, testable, and unaddressed in the plan.
2. **Negative-result caching is sticky.** Caching nil when `headMtime` is nil makes "not in repo" survive subsequent `git init` until eviction. Mitigation: don't cache nil-head states.
3. **`GitRunner.run` returns `String?` only.** Distinguishing timeout from other failures requires a richer return type or a separate API. AC14 as written cannot be implemented cleanly without choosing one.
4. **The `DerivationCoordinator` is too thin to be a production scheduler.** It lacks generation tokens, expected-cwd guards, retry behavior, and multi-deriver aggregation. Wiring it in load-bearing today implies more refactor than the plan admits.
5. **Cache integration ≠ coordinator integration.** The plan conflates them. The cache can be load-bearing without adopting the current coordinator shape; the coordinator can be documented as a future seam while the cache becomes real. Splitting these decisions cleanly is the recommended Alternative B path.
6. **Metadata-value contract mismatch in C11-104.** The projector renders `.unknown` as `"(no branch)"`, but `applyDerivedWorktreeBranchMetadata` writes an empty derived `branch` for `.unknown`. C11-106 should settle this contract explicitly across sidebar projection and `c11 get-metadata`.
7. **`InitialWorkspaceGitMetadataSnapshot` aggregation question.** Should derived git context remain part of the existing snapshot, or move to its own pipeline? The plan implicitly assumes the former but does not say so.
8. **Suggested revised acceptance criteria (8 items).** Codex provides a concrete rewrite of the AC block as the closing section — a planning artifact, not just a critique. Notably: AC #2 ("`TabManager` no longer calls uncached `GitContextResolver.resolve(cwd:)` directly") makes the cache wiring testable as a static-analysis assertion.

### Surfaced by Claude only

1. **Line-reference drift.** `TabManager.swift:1724` is correct against the merged state but not against local `main` HEAD; recommend restating call sites by function name (`TabManager.initialWorkspaceGitMetadataSnapshot` body).
2. **Commit hygiene inside the single PR.** If Section 1 has CI fallout, the operator should be able to revert just the wiring without losing the tests and renames. Recommend one commit per section, or at minimum "wiring" vs. "tests" vs. "renaming."
3. **CI verification loop and testing-policy guardrails.** The plan should explicitly reference `code/c11/CLAUDE.md` "Testing policy" so the delegator doesn't accidentally `open` an untagged `c11 DEV.app` or run `xcodebuild test` for the host-required scheme locally. `c11-logic` is the safe local loop; `c11-unit` / `compat-tests` / `test-e2e` go to CI.
4. **Skill reference (`skills/c11/references/metadata.md`) needs an update either way.** Whichever path Section 1 takes, the current text describes the coordinator as a seam — that becomes either inaccurate (if wired) or more aspirational (if documented forward-only). Should be an explicit AC.
5. **AC16 coverage breadth — one call site or all four?** The `invalid_source` rejection happens at four `TerminalController.swift` sites. The plan literally requires one test. Validation-plan principle ("test the contract, not the implementation shape") supports one, but four is cheap.
6. **PR-body convention questions.** What does "this ticket" mean — Lattice task ID, C11-106 number, or both? PR title format (`C11-106: <subject>`)?
7. **"Optional means deferred" failure pattern.** Claude frames Section 6's optional polish as a known anti-pattern and recommends promoting them to mandatory if the operator wants them done at all.
8. **Implicit option to split into two delegators mid-flight.** If Section 1 unexpectedly grows, the delegator should be empowered to split the work into wiring vs. cleanup tickets rather than push through.

---

## 4. Consolidated Questions for the Plan Author

Numbered, deduplicated. Where both reviewers asked the same question, the formulations are merged.

1. **Section 1 path decision.** Will C11-106 (a) wire both `DerivationCoordinator` and `GitContextResolverCache` into production, (b) wire only the cache and document the coordinator as a future seam (Codex's Alternative B), or (c) document both as forward-looking-only? The plan must commit to one before delegation. If (b), several downstream specifications change (AC17 setup, threading, snapshot shape).
2. **Cache ownership.** Where does the production cache live: `TabManager` instance property, static resolver facade, or a new git-context service object?
3. **Cache key semantics for submodules.** The proposed `(cwd, mtime(headPath))` does not catch superproject HEAD changes from a submodule cwd. Should submodule contexts be excluded from the cache, or should the key include both superproject and submodule HEAD mtimes? Tests need to mutate both independently.
4. **Negative-result caching policy.** Should nil resolver results be cached at all? If yes, what invalidates `(cwd, nil)` when a directory becomes a git repo later? Simplest safe rule: only cache when a resolved HEAD path exists and its mtime was read successfully.
5. **Threading model for cache-aware resolution.** Which queue runs the cache lookup and the underlying probe? Is the existing `initialWorkspaceGitProbeQueue` reused? How is the result delivered back to the main actor? If the coordinator is wired in, does it own generation tokens and expected-cwd guards, or do those stay in `TabManager.applyWorkspaceGitMetadataSnapshot`?
6. **`GitRunner` API shape for AC14.** Does the plan want timeout represented as a distinct resolver state? If yes, does `GitRunner.run` get a richer result enum, a timeout-aware sibling API, or do we accept that timeout maps to nil and test only that the process terminates?
7. **Timeout default value.** Should the timeout change from 5s to 2s in this PR (closing v2 SPEC drift), or test the current 5s and update the SPEC instead?
8. **Section 3 enum rename — semantics, not just names.** For each new state, what does the plan want?
   - `.notInRepo` → empty `worktree` and empty `branch`?
   - `.stale` → clear values, remove derived keys, or preserve previous values with a stale marker?
   - `.noBranch` → render `"(no branch)"` in sidebar AND return `"(no branch)"` via `c11 get-metadata`? (Note: C11-104 already has a contract mismatch — projector renders `"(no branch)"` for `.unknown` but `applyDerivedWorktreeBranchMetadata` writes empty. Settle this explicitly.)
9. **Section 4 (`.stale`) — promote to mandatory?** Both reviewers reject the plan's neutrality. Co-traveller with Section 3 saves migration cost (Claude); contract must be specified anyway (Codex). Is there a reason to defer?
10. **AC20 test pattern.** `XCTExpectFailure` and a fatal `dispatchPrecondition` are not equivalent. Will the plan commit to (a) a subprocess/helper fatal-test harness, (b) a documented sentinel + manual notes, or (c) downgrade AC20 to "verify precondition exists via code review, not test"? A fake deterministic crash test that destabilizes `c11LogicTests` is worse than the current gap.
11. **AC16 coverage breadth.** Single call site (cheap, contract-level) or all four `TerminalController.swift` sites (belt-and-braces)?
12. **Section 5 (dead code) — guard.** Make this a "no behavior change" subtask rather than a required AC. Should the delegator delete `Workspace.orderedUniqueBranchDirectoryEntries()` after a grep, or surface a callers list to the operator before deleting? What's the safe pattern for verifying nothing in `c11Tests/`, CLI tooling, or persistence schemas calls it?
13. **Section 6 polish — mandatory or optional?** Both items (timeout 5s→2s, hardcoded `0.55` opacity → ThemeKey) close real v2 SPEC drift. Promote to mandatory, or accept they will likely be deferred?
14. **Section 7 — annotation location.** v3 addendum / separate C11-106 validation file (both reviewers' preference) or in-place edit to v2? In-place blurs what PR #181 was judged against.
15. **Skill reference update.** Should an edit to `skills/c11/references/metadata.md` be an explicit AC? Either path resolution makes the current text inaccurate (wired → no longer a seam) or more aspirational (documented forward-only → say so plainly).
16. **`TabManager.swift:1724` reference.** Confirm the line lands in the post-#181 codebase and restate the call site by function name (`TabManager.initialWorkspaceGitMetadataSnapshot` body) so the delegator isn't chasing a drifting line number.
17. **Commit hygiene inside the single PR.** One commit per section (or at minimum: wiring / tests / renaming as separable units) so Section 1 can be reverted independently if CI has fallout?
18. **CI verification loop guardrails.** Should the plan reference `code/c11/CLAUDE.md` "Testing policy" explicitly? Delegator should know `c11-logic` is the safe local loop and `c11-unit` / `compat-tests` / `test-e2e` go to CI. Never `open` an untagged `c11 DEV.app`.
19. **PR body / title convention.** Does AC #6 ("PR body links to this ticket") mean the Lattice task ID, the C11-106 number, or both? Title format `C11-106: <subject>`?
20. **Validation-plan annotation commit grouping.** If Section 7 produces edits to validation-plan documents, do those live in the same PR as the code change, or in a separate doc-only commit?
21. **Submodule fixture authoring cost.** Does `c11Tests/` already have a helper that builds a temp submodule, or does the delegator need to author one from scratch? If the latter, the "~50–100 lines of glue" estimate likely undercounts.
22. **`InitialWorkspaceGitMetadataSnapshot` aggregation.** Does derived git context stay part of the existing snapshot, or move to its own pipeline? The plan implicitly assumes the former.

---

## 5. Overall Readiness Verdict — Synthesized

1. **Structural verdict: the plan is shaped correctly.** Both reviewers endorse the seven-section decomposition, the audit traceability, the out-of-scope carve-out for AC19 and AC31–33, and the validation-plan hygiene step.
2. **Specification verdict: the plan is under-specified in load-bearing places.** Section 1's wire-vs-document fork is the most visible gap. Codex surfaces deeper gaps around cache key semantics, negative-result caching policy, `GitRunner` API shape, and metadata-value contracts. None of these can be resolved by the delegator without operator input.
3. **Synthesized verdict: REVISE BEFORE DELEGATION.** Specifically:
   1. Collapse the Section 1 fork to a single path — recommend Codex's Alternative B (cache load-bearing, coordinator documented as future seam) as the lowest-blast-radius option that still closes AC12.
   2. Specify cache key semantics for submodules (multi-HEAD keying or explicit exclusion) and nil-head states (don't cache, or include a directory-mtime invalidation input).
   3. Choose an AC20 test pattern (subprocess harness, documented sentinel, or downgrade) and write that choice into the AC text.
   4. Pin the timeout-state contract: either richer `GitRunner` return type with `.timeout`, or accept nil and test only process termination.
   5. Specify the metadata-value contract for `.noBranch` / `.notInRepo` / `.stale` so sidebar projection and `get-metadata` agree.
   6. Pin Section 7 annotation to a v3 addendum / separate file.
   7. Add an explicit AC for `skills/c11/references/metadata.md` update.
   8. Reference `code/c11/CLAUDE.md` "Testing policy" so the delegator follows the right local/CI loop.
4. **What's NOT needed:** structural rewrite, splitting the ticket into two PRs (unless Section 1 unexpectedly grows during implementation), or expanding scope to AC19 / AC31–33.
5. **Confidence in this verdict:** moderate. With Gemini's standard review missing, the readiness call is a 1-1 split between "ready with clarifications" (Claude) and "needs revision" (Codex). The synthesis tilts toward Codex's verdict because Codex's unique findings (cache key insufficiency, negative-result caching, `GitRunner` shape, contract mismatch) are concrete, technically grounded, and unaddressed in the plan text — they are the kind of gaps that turn into rework if discovered during implementation rather than during planning. If a Gemini perspective arrives and endorses Claude's "ready with clarifications" framing, the verdict could move back to "ready with the seven specified plan edits applied inline."

---

*Synthesis note: this is a read-only synthesis. The only file written by this pass is this synthesis document at the assigned output path. The underlying reviews and plan were not modified.*
