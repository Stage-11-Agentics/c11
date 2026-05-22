# Standard Plan Review — C11-106 (follow-up to C11-104 / PR #181)

- **Plan ID:** `c11-106-plan`
- **Model:** Claude (Opus 4.7, 1M)
- **Lens:** PlanReview-Standard (analytical / architectural)
- **Timestamp:** 2026-05-19T09:35
- **Plan file:** `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01KS06C8QZ43D6NH203QFE3SMQ.md`

---

## Executive Summary

This is a sound, well-scoped follow-up plan. It reads exactly the way a competent post-merge cleanup ticket should read: it accepts that the parent PR shipped the user-visible feature correctly, identifies the gaps as test coverage and architectural drift rather than functional regressions, and proposes resolutions that are concrete, bounded, and reversible.

The single most important thing in this plan is **Section 1 (wire `DerivationCoordinator` + `GitContextResolverCache` into production, or explicitly document them as forward-only)**. That decision determines whether C11-104 lands as a real feature with the seam it advertised, or as a feature whose architectural narrative is half a step ahead of its implementation. Everything else in the plan is housekeeping; this one is load-bearing.

The plan author's recommendation — *wire it in* — is the correct call, and the cost estimate ("~50–100 lines of glue + two cache invalidation tests") is plausible. The alternative ("document as forward-looking-only") is also acceptable and the plan acknowledges that honestly, which is a healthy sign. The plan resists the common failure mode of pretending only one resolution is acceptable.

**Verdict: ready to execute, with a small number of clarifications captured in the questions section.** The work decomposes cleanly into independent sub-tasks; the acceptance criteria match the scope; and the explicit "out of scope" boundary (AC19 restore-warmpath as its own ticket) is the right cut.

---

## The Plan's Intent vs. Its Execution

**Intent:** Close the test-coverage and architectural-drift gaps the C11-104 validation audit surfaced, without re-opening user-visible behavior or expanding scope into adjacent tickets (AC19, AC31–33).

**Execution:** The plan is structured as a numbered checklist of seven items (six discrete + one polish), each tied back to a specific AC number or validation-report finding. Every item has a clear pass condition. Section 1 carries the architectural weight; sections 2–4 are test-and-naming cleanup; sections 5–7 are housekeeping.

There is no drift between intent and execution. The plan author is the same person (or at least the same role) who produced the validation report, so the lineage is tight: every item in the plan maps back to a "FAIL" / "PARTIAL" / "drift" row in the audit. That traceability is genuinely valuable — when a future agent reads this, they can reconstruct *why* each item is here.

One small mismatch worth naming: the plan's Section 1 references `TabManager.swift:1724` as the call site for `GitContextResolver.resolve(cwd:)`. On the local `main` checkout I'm reviewing from (HEAD `ef484b1c6`), PR #181 has NOT been pulled in yet, and at line 1724 the file is actually inside `workspacePullRequestSnapshot`. The reference is correct against the merged PR's `2b1be4220`, just not against the local main I'm viewing from. This isn't a plan defect — the plan is written against the post-merge state — but it's worth confirming that line number once the delegator pulls. (See Q1.)

---

## Architectural Assessment

### Is the decomposition right?

Yes. The seven sections correspond to genuinely independent units of work:

1. Coordinator wiring — touches `TabManager` only; benefits from being its own commit.
2. Missing tests (AC14, AC16, AC17, AC20) — four small unit tests, each independent of the others and of section 1.
3. Enum renaming — search-and-replace plus call-site updates; mechanical and reviewable in isolation.
4. `.stale` state — depends on section 3's enum decision but is otherwise standalone.
5. Dead-code cleanup — independent.
6. Polish (timeout 5s→2s, dim opacity → ThemeKey) — operator's call; cleanly optional.
7. Validation-plan hygiene — pure documentation.

This shape is what you want for a follow-up PR: bounded, parallelizable inside the agent's head, and reviewable section by section. A single delegator can plausibly carry the whole thing in one sweep, but the work could also be split across two delegators if needed (section 1 + sections 2–4 / 7 + section 5).

### Is the structure right?

Mostly yes. One observation: section 1 offers two acceptable resolutions and recommends one ("wire it in"), but the acceptance criteria (line 73) treats both as valid pass conditions. That's the right call — the operator should still get to override the recommendation if "forward-looking-only" is what they want. The plan correctly stops short of forcing a decision the operator should make.

A second observation: section 3 (enum renaming) has the same shape — two acceptable resolutions, one recommended. Again, the right pattern.

The asymmetry I'd flag is section 4 (`.stale` state). The plan describes it as "Decide whether to pick it up here or leave as a known-deferred edge case" without recommending. Given that section 3 wants to introduce a proper `.notInRepo` case, the natural co-traveller is to also introduce `.stale` at the same time — same enum, same migration cost. Doing them in two separate PRs would mean touching the same enum twice with the second touch invalidating tests written against the first. I'd nudge section 4 to recommend "do it here unless you're tight on time," not leave it neutral. (See Q4.)

### Alternative framings

One alternative is to **split this into two tickets**: a "wire it in" ticket (section 1, the architectural piece) and a "test coverage + naming" ticket (sections 2, 3, 5, 6, 7). The argument for splitting is that section 1 is the only one with real risk — production code change, threading question, cache invalidation question — and the rest is bounded cleanup. The argument against (which the plan implicitly takes) is that the work is small enough that splitting overhead exceeds the benefit, and that landing everything as a single follow-up PR keeps the "C11-104 closeout" story coherent.

I'd agree with the plan's choice to keep it together, **provided** the PR description clearly labels which commits are which. If the wiring goes sideways in CI, the operator should be able to revert section 1 commits without losing the tests and renames. (See Q2.)

A second alternative — and the only one I'd genuinely push back on — is to **defer section 1 entirely and ship sections 2–7 first**. Argument: the test gaps and naming drift are paying compound interest; the wiring decision deserves more design air. Counter: the validation report's headline drift item is the cache/coordinator gap, and leaving it deferred a second time would start to look like permanent ambiguity about whether those classes are real or aspirational. The plan correctly rejects this alternative by recommending in-line wiring.

---

## Is This the Move?

Yes. The bets the plan makes:

1. **Bet: PR #181 shipped clean enough that follow-ups are housekeeping, not rework.** Validated by the audit (22 PASS / 6 PARTIAL / 4 FAIL / 1 CANNOT_VERIFY, with no user-visible regressions and a clear merge gate). Right bet.
2. **Bet: The cache/coordinator architecture is worth completing, not deleting.** This is the most consequential bet in the plan. If the operator believes future derivers (host/SSH, container, kubectl, AWS profile) are real near-term work, wiring it in *now* prevents another round of "we have the seam but nobody uses it" debt. If those derivers are speculative, the alternative — documenting as forward-only — costs nothing today. The plan correctly leaves this decision visible. (See Q3.)
3. **Bet: Enum renaming is worth doing now while the surface area is still small.** Right bet. Renaming `.unknown` → `.noBranch` and `nil` → `.notInRepo`/`.stale` later is more painful once tests and call sites multiply.
4. **Bet: Optional polish items (timeout, dim opacity) are clearly labeled optional and don't gate merge.** Right bet — they're real but small.

The priorities are in the right order. Section 1 is the lead because it's the highest-leverage architectural decision. Tests come second because they harden the contracts that section 1 establishes. Naming is third because it changes the vocabulary that everything else uses. Polish is last.

### Common failure patterns this plan avoids

- **"All tests are equivalent."** The plan doesn't lump AC14/16/17/20 into a generic "add tests" line — it names each by AC number and specifies what the test must exercise (timeout result, `invalid_source` rejection, derived-value read path, deterministic precondition trip).
- **"Architecture drift is OK because it's not user-visible."** The plan explicitly rejects this — section 1 is the longest section precisely because the user-invisible drift is the highest-priority cleanup.
- **"We'll do naming in a future ticket."** The plan refuses this temptation by including section 3 in scope.
- **"Validation plan is one-shot."** Section 7 fixes the chronic problem of validation plans going stale after one round. Annotating in-place is the right move.

### Common failure patterns this plan partly avoids

- **"Optional means it won't get done."** Section 6 lists two optional polish items. Both are real (timeout 5s→2s contradicts the v2 SPEC; hardcoded `0.55` opacity contradicts the SPEC's ThemeKey approach). Operator's call is honest, but if the answer is "yes, polish them," they should move into the mandatory list. (See Q6.)

---

## Key Strengths

1. **Traceability to the audit.** Every item maps to a specific AC number or validation-report finding. A future agent can reconstruct the rationale without re-reading the audit.
2. **Honest framing of dual-acceptable resolutions.** Sections 1, 3, and 4 each describe two acceptable outcomes and recommend one. This is a healthy pattern — it lets the operator override without forcing them to argue against a false binary.
3. **Concrete pass conditions.** The acceptance criteria block at lines 73–78 is unambiguous. "Cache-invalidation tests that use linked-worktree + submodule fixtures" is exactly the specificity the parent plan's AC12 lacked.
4. **Explicit "out of scope" boundary.** AC19 (restore-warmpath) and AC31–33 (operator smoke) are correctly carved out. Without that fence, this ticket would silently absorb the next two tickets.
5. **Cost honesty.** "~50-100 lines of glue + two cache invalidation tests" is the kind of estimate that lets a delegator decide whether to take the whole ticket in one sweep or ask for help.
6. **Linked-worktree + submodule fixture requirement.** Section 1's specification that the cache key must use `git rev-parse --git-path HEAD` (the resolved path, not `<cwd>/.git/HEAD`) is the exact fix the trident pack flagged on the parent plan. The plan inherits that correction without having to re-derive it.

---

## Weaknesses and Gaps

1. **Section 1 leaves the threading model under-specified.** The plan says `TabManager.initialWorkspaceGitMetadataSnapshot` should call `DerivationCoordinator.run` against `[GitContextDeriver]`. It doesn't say which queue runs the coordinator, how the result is delivered back to the main actor, or whether the existing `initialWorkspaceGitProbeQueue` is reused as the coordinator's queue or replaced. The v2 SPEC (referenced indirectly via the validation report) presumably constrains this, but the plan should re-state it. (See Q5.)
2. **AC20 test approach is hand-waved.** The plan says "Either `XCTExpectFailure` around a main-thread invocation, or precondition-fatal test pattern." The validation report admits this is hard ("We can't easily intercept `dispatchPrecondition` in-process"). The plan should commit to one approach or explicitly say "delegator's call after a 30-minute spike — if neither pattern works, document why and downgrade to a sentinel + manual notes." Right now the AC reads as if a real test is achievable when the validation report implied it might not be. (See Q7.)
3. **Section 4 (`.stale` state) is under-specified relative to its dependencies.** It depends on section 3's enum naming decision. If section 3 keeps the current `nil`/`.unknown` proxies and updates the SPEC instead, then section 4's `.stale` introduction adds a new case alongside `.unknown` — meaningful surface-area decision that the plan doesn't address. (See Q4.)
4. **Dead-code cleanup criterion is fuzzy.** Section 5 says "Grep for callers; if confirmed dead, delete." That's correct but doesn't address what "delete" means for `Workspace.orderedUniqueBranchDirectoryEntries()` — is it private/internal? Does anything in CLI tooling, snapshots, or tests still call it? The validation report's P6 noted "the underlying state fields are preserved and still feed both the new chip row and the legacy callers I sampled," which suggests the answer isn't trivially "yes delete." (See Q8.)
5. **No explicit CI verification step.** The acceptance criteria mention "CI green; no regressions in `c11-logic` or `compat-tests`" (item 5), but don't specify how the delegator should verify locally before pushing. Given the project's policy ("don't run `xcodebuild test` locally" — both in CLAUDE.md and in the operator's memory), the delegator needs a documented loop: which scheme to compile locally (`c11-logic` is safe), which to defer to CI (`c11-unit`, `compat-tests`, `test-e2e`). The plan should reference the existing testing policy explicitly so the delegator doesn't accidentally launch an untagged `c11 DEV.app`. (See Q9.)
6. **Validation-plan hygiene step (section 7) doesn't say where to annotate.** "Annotate the v2 validation plan in-place (or a v3 section)" — fine, but which? In-place edits to historical validation plans are a smell; a v3 amendment section is cleaner. The plan should pick one. (See Q10.)
7. **No mention of submodule update in `skills/c11/references/metadata.md`.** If section 1's outcome is "document as forward-only," the metadata reference needs an edit. If section 1's outcome is "wire it in," the reference also needs an edit (the current text post-#181 describes the coordinator as a seam; that becomes inaccurate). Either way, a docs edit is implied but not called out as an AC. (See Q11.)
8. **AC16's test pattern is more nuanced than the plan suggests.** The plan says "Send a `set_metadata` frame with `source=derived` from a non-internal-caller path; assert `invalid_source` error." The rejection happens at four call sites (`Sources/TerminalController.swift:8246-8248, 8368-8370, 9124-9126, 9221-9223`). A single test covering one call site is what the plan literally requires, but the validation-plan hygiene principle suggests all four should be exercised. (See Q12.)

---

## Alternatives Considered

### Section 1: Wire it in vs. document forward-only

- **Wire it in (recommended):** Real production cache; future derivers slot in cleanly; AC12 becomes verifiable end-to-end.
- **Document forward-only:** Lower-risk, no production threading change; cache class becomes documented dead code waiting for a future user.

The plan correctly recommends "wire it in." The cost differential is small (~50–100 lines), the architectural payoff is large (the seam stops being aspirational), and the alternative ("document forward-only") leaves the same cleanup waiting for the next agent. The only argument for the alternative is "we don't actually need the cache today because git probes are already off the hot path." That's true but circular — *if* we ever add a second deriver, we'll want the cache; *if* we never add one, we should delete the class outright, not document it. The recommended path is better.

### Section 3: Rename implementation vs. rewrite SPEC

- **Rename implementation (recommended):** `BranchValue.noBranch`, `GitContextKind.notInRepo`, `GitContextKind.stale`. Self-documenting; matches SPEC verbatim.
- **Rewrite SPEC:** Update v2 SPEC to use `nil` and `.unknown`. Cheaper edit (text only).

The plan correctly recommends renaming. The SPEC names are more self-documenting and Swift idioms favor named enum cases over `nil` proxies for state distinctions. Rewriting the SPEC would lock in a less-clear vocabulary forever.

### Section 4: Pick up `.stale` here vs. defer

The plan is genuinely neutral here. I'd lean toward picking it up — same enum, same migration cost, and deferring it means a third touch on the enum in another PR. But if the operator wants to keep this PR tight, deferral is defensible. (See Q4.)

### Single ticket vs. split into two

- **Single ticket (plan's choice):** Coherent closeout story; one PR to track; tests and wiring land together.
- **Split into two:** Section 1 in its own ticket (wiring + threading + cache fixtures); sections 2–7 in a hygiene ticket. Lower blast radius if section 1 has problems.

The plan implicitly chose single ticket, which is right for the size of work involved. If section 1 unexpectedly grows (e.g., the threading model turns out to be more invasive than estimated), the delegator should be empowered to split it mid-flight rather than push through.

---

## Readiness Verdict

**Ready to execute with minor clarifications.** The plan is sound, the decomposition is right, the priorities are in the right order, and the acceptance criteria are concrete enough for a delegator to work against. The open questions (below) are scope-clarifying rather than scope-shifting — none of them should block the delegator from starting.

What would change this verdict:
- If Q3 (operator's stance on the wiring vs. forward-only decision) reveals the operator wants forward-only, sections 1's pass condition still works but the plan should be edited to put that path first and remove the "wire it in" implementation detail.
- If Q5 (threading model) reveals genuine ambiguity in the v2 SPEC, the delegator may need a small architecture-spike pass before coding.
- If Q7 (AC20 precondition trip) reveals there is genuinely no good test pattern, the AC should be downgraded explicitly rather than left aspirational.

None of these would require a structural rewrite of the plan — they're all surgical edits to specific sections.

---

## Questions for the Plan Author

1. **`TabManager.swift:1724` line reference.** On the local `main` HEAD I'm reviewing from (`ef484b1c6`), line 1724 is inside `workspacePullRequestSnapshot`, not at a `GitContextResolver.resolve(cwd:)` call. I believe the reference is correct against the post-#181 merged state (`2b1be4220`). Can you confirm the call site lands in the post-merge codebase, and ideally re-state the call-site path as a function name (`TabManager.initialWorkspaceGitMetadataSnapshot` body) so the delegator isn't chasing line numbers that drift?

2. **Commit hygiene inside the single PR.** If section 1 (wiring) lands in the same PR as sections 2–7 (cleanup), should the delegator commit them as separable units (one commit per section, or at least "wiring" vs. "tests" vs. "renaming")? This matters because if section 1 has unexpected test-host fallout in CI, the operator should be able to revert just the wiring without losing the renames and new tests.

3. **Section 1 decision: wire it in or document forward-only?** The plan recommends wiring it in, and I agree, but it explicitly leaves the call open. Can you confirm this is still your preference, or do you want the delegator to make the call after a short feasibility check? If the latter, what's the trigger to flip to "forward-only" (e.g., threading turns out to be invasive, cache fixtures are too brittle)?

4. **Section 4 (`.stale` state) — defer or do here?** The plan is neutral. Given section 3 already touches the enum, it seems much cheaper to add `.stale` in the same change. Is there a specific reason to leave it deferred? If not, can we promote section 4 from optional to mandatory?

5. **Threading model for `DerivationCoordinator.run`.** The plan says `TabManager.initialWorkspaceGitMetadataSnapshot` calls `DerivationCoordinator.run`, but doesn't specify which queue the coordinator runs on, whether the existing `initialWorkspaceGitProbeQueue` is reused, or how the result is delivered back. Can you point the delegator at the relevant v2 SPEC section, or restate the threading constraint in this plan?

6. **Section 6 polish items — gate on operator decision or do them by default?** The plan flags timeout (5s → 2s) and dim opacity (hardcoded → ThemeKey) as optional. The validation report treated both as drift from the v2 SPEC. Should the delegator just do them by default in this PR (since they close real drift items), or wait for explicit operator approval?

7. **AC20 test pattern.** The validation report admitted in-process precondition interception is hard. The plan says "Either `XCTExpectFailure` ... or precondition-fatal test pattern." If the delegator tries both and neither works cleanly, what's the fallback? An honest sentinel + comment? Or should AC20 be downgraded to "verify precondition exists at the call site via documentation, not test"?

8. **Section 5 (dead code) — scope.** `Workspace.orderedUniqueBranchDirectoryEntries()` is named explicitly. The validation report (P6) suggests the underlying state fields still feed both new and legacy callers. Can the delegator delete this method confidently after a `grep`, or do you want them to leave it and surface a list to you before deleting? (Plus: what's the safe pattern for verifying nothing in `c11Tests/`, CLI tooling, or persistence schemas calls it?)

9. **CI verification loop.** The plan says "CI green; no regressions in `c11-logic` or `compat-tests`." Per project policy, the delegator can run `c11-logic` locally but not `c11-unit` / `compat-tests` / `test-e2e`. Should the plan explicitly reference `code/c11/CLAUDE.md` "Testing policy" so the delegator doesn't accidentally `open` an untagged `c11 DEV.app`?

10. **Section 7 — where does the annotation go?** "Annotate the v2 validation plan in-place (or a v3 section)" — please pick one. In-place is messier but keeps a single file; v3 amendment is cleaner but requires future readers to scroll. My preference is v3 amendment for the same reason the v2 amendments live as their own section under the original SPEC.

11. **Docs edit (`skills/c11/references/metadata.md`).** Whichever way section 1 resolves, the metadata reference needs an edit (current text describes the coordinator as a seam; that becomes either inaccurate or even more aspirational). Should this be added as an explicit AC, or is it implied under "documented in code + skill reference as forward-looking-only" (which only covers the forward-only branch)?

12. **AC16 — single call site or all four?** The rejection happens at four `TerminalController.swift` sites. Does AC16 want one test that hits one call site (cheap), or four tests / one parameterized test that hits all four (more coverage)? My read of the validation-plan principle ("test the contract, not the implementation shape") says one is enough since the rejection logic is identical; but if the operator wants belt-and-braces coverage, four is cheap too.

13. **What "PR body links to this ticket" means.** Acceptance criterion 6 says "PR body links to this ticket and to PR #181; describes which AC numbers it closes." Does "this ticket" mean the Lattice task ID, the C11-106 ticket number, or both? And should the PR title follow the existing convention (`C11-106: <subject>`)?

14. **Definition of "done" for the in-place validation-plan annotations.** If section 7 produces edits to `validation-plan.md`, should those edits live in the same PR as the code change, or in a separate doc-only commit?

15. **Submodule fixture for the cache invalidation test.** Section 1's AC12 fixture requirements ("linked-worktree + submodule") imply the delegator needs to script up a submodule for the test. Is there an existing fixture pattern in `c11Tests/` (e.g., a helper that builds a temp submodule), or does this need to be authored from scratch? If the latter, that's an additional cost the "~50-100 lines" estimate may not cover.

---

*Reviewer note: this is a read-only review. No files outside the assigned output path were modified.*
