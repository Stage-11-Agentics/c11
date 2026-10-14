# Trident Synthesis: C11-193 Standard/Analytical Reviews

- **PLAN_ID:** `c11-193-plan`
- **Ticket:** C11-193, "launch-agent: refuse to start an agent in another agent's linked worktree"
- **Reviews synthesized:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
- **Synthesized:** 2026-08-06
- **Note:** several contested factual claims were spot-checked against the working tree during synthesis. Verified claims are marked **[verified]**.

---

## Executive Summary

1. **All three models endorse the product bet without reservation.** Guard rather than default; refuse inherited cwd into a linked worktree; permit explicit `--cwd` with an acknowledgement. No reviewer proposed relitigating the thesis, the non-goals, or the asymmetry between explicit and inherited. That is the highest-confidence finding in the pack.

2. **Two of three call the plan not executable; the split is not a coin flip.** Claude and Codex independently converge on the same blocker from different code paths: the plan's central instruction operates on a value that does not exist at the seam it names. Gemini says "ready to execute" but never examines the inherited-cwd resolution path, so its verdict rests on a strictly smaller evidence base rather than on a competing reading of the same evidence.

3. **The single most consequential disagreement is build-versus-reuse, and it is resolvable on the facts.** Claude designs a new probe and separately warns that a naive `--git-dir` versus `--git-common-dir` comparison produces false positives from a repo's top level. Codex says a hardened resolver already exists. **[verified]** `Sources/Metadata/GitContextResolver.swift` exists, already emits `.linkedWorktree` / `.mainCheckout` / `.stale` / `.notInRepo`, and its source comment at line 345 documents the exact relative-path normalization Claude warns about. Claude's hazard is real and Codex's finding is the fix for it. This is the clearest case in the pack of two models triangulating one answer.

4. **Threading is a live product-safety issue, not an implementation detail. [verified]** `agent.launch` is absent from `socketWorkerV2Methods`, so it enters on the main actor. `GitContextResolver.resolve` carries `dispatchPrecondition(condition: .notOnQueue(.main))` and traps if called there. A literal implementation of the plan either deadlocks, beachballs, or traps. Only Codex states this precisely; Claude flags the risk category correctly without the specifics; Gemini is silent.

5. **The plan is missing an output contract, and the default CLI path currently swallows warnings. [verified]** `launch-agent` prints via `printV2Payload` with a `v2OKSummary` fallback (`cli/c11.swift:2344`); the warnings-printing branches live in other handlers. An acknowledgement appended only to the `warnings` array would be invisible in human mode, which reproduces the silent-failure shape the ticket exists to kill. Codex alone caught this.

6. **Consolidated verdict: Needs revision, small and targeted.** Seven decisions need pinning. The architecture underneath them is sound and no reviewer asked for a rethink.

---

## 1. Where the Models Agree (Highest Confidence)

1. **The bet is correct.** All three endorse guard-over-default and the explicit/inherited asymmetry. Claude: "one of the better small tickets I have read in this repo." Codex: "the appropriate middle ground." Gemini: "definitely the move." Treat this as settled.

2. **The decomposition shape is right.** Probe, then policy, then adapter, then tests. All three accept the factoring; the disagreements are about what fills each box, not about the boxes.

3. **The git probe's I/O boundary is a genuine problem for the stated testability goal.** All three independently flag that shelling out to `git` breaks the pure-logic character of the `CwdParamResolution` seam and needs either injection, extraction, or a subprocess-free approach. This is the only weakness all three name.

4. **C11-194 interaction is unresolved and blocking-ish.** All three raise it, from three angles:
   - Claude: if a workspace root is itself a linked worktree, is that inherited (refuse) or intentional (allow)? Argues strongly for allow, and notes the plan's binary framing has no room for a third case.
   - Codex: the two tickets touch the same precedence logic; they need a shared resolution type and an explicit merge order or the merge will compile while silently redefining "inherited."
   - Gemini: on rejection, does the guard hard-error or silently fall back to the C11-194 workspace root? Argues for hard error.
   These are three facets of one decision. It must be made before either ticket ships.

5. **Naming the branch in the error message is a real strength.** All three call out actionable recovery copy as the plan's best user-facing property.

6. **Ordering matters and the plan states none.** Claude and Codex both flag that the ship order changes how often the guard fires and what "inherited" means.

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Readiness verdict: 2 to 1, but not a genuine three-way contest

1. Claude: **Needs revision.** Three blockers, four single-sentence fixes.
2. Codex: **Needs revision.** Four blockers, eight readiness conditions.
3. Gemini: **Ready to execute**, pending "minor clarifications."

4. **Adjudication.** Gemini's review is roughly one fifth the length of the others and never traces what `cwd` resolves to when the param is absent. Its three questions are a strict subset of the other two reviews' concerns. This is not a model that looked at the same evidence and drew a different conclusion; it is a model that stopped earlier. Weight the two "needs revision" verdicts accordingly. The one thing Gemini's optimism does establish: nothing in the plan is *wrong*, only underspecified. That supports "small targeted revision" over "rethink."

### 2.2 Build a new probe versus reuse `GitContextResolver` (the sharpest divergence)

5. **Claude** designs a fresh probe, specifies its execution contract in detail (timeout, PATH, non-git directories, absolute-path normalization), and separately proposes a stat-based `.git`-file check as a cheaper alternative. Never mentions that a resolver already exists.
6. **Codex** makes reuse a blocking finding: a second probe "would duplicate policy and likely lose its normalization, submodule, stale-worktree, timeout, and branch-label behavior."
7. **Gemini** mentions `GitContextResolver` once, parenthetically, as a note appended to its architecture paragraph, then proposes hand-parsing the `.git` file as its lead alternative.
8. **Adjudication: Codex is right, and Claude's own evidence proves it. [verified]** Every hazard on Claude's list (relative `--git-dir`, timeouts, PATH, non-repo handling) is already solved in `GitContextResolver`. The resolver's line-345 comment addresses Claude's false-positive scenario by name. Claude's execution-contract list should be repurposed from "requirements for the new probe" into "the checklist proving the existing resolver is the right dependency."
9. **The residual value in Claude's and Gemini's alternatives** is the stat-based check for the *decision* with git reserved for the *branch label*. Worth one paragraph in the revised plan, but note that `GitContextResolver` already caches and bounds its calls, so the performance argument is weaker than it looks, and the correctness argument (submodules also use a `.git` file) cuts against it.

### 2.3 The core blocker: does an inherited cwd value exist to probe?

10. **Claude and Codex converge on yes-this-is-the-blocker via different traces.** Claude: `.inherit` carries no payload, `resolved = nil`, the real path materializes later in the panel-creation chain on the main actor. Codex: `v2ResolveCwdParam` collapses omitted/blank/`inherit` to `nil`, and `v2AgentLaunch` forwards that `nil` into placement-specific creation paths, with new-workspace and existing-workspace placements deriving the directory from different state.
11. **Codex goes one step further** by naming *which placement's state is authoritative*, which Claude leaves open.
12. **Gemini does not engage with this at all**, which is the entire reason for its divergent verdict.
13. **Both propose the same fix under different names:** a resolved value carrying provenance. Claude's `ResolvedCwd { path, origin }` with `CwdOrigin` of explicit / workspaceRoot / inheritedFromSurface. Codex's `AgentLaunchCwdResolution { path, source }`. Claude's three-case enum is the better shape because it resolves the C11-194 workspace-root question by construction rather than deferring it.

### 2.4 Same fact, opposite conclusions: the lattice-orchestrator workflow

14. **Gemini treats one-worktree-per-delegator as the justification** for the guard: agents will naturally spawn children into their own worktrees, so make it an error.
15. **Claude treats the identical fact as an ergonomics risk**: the guard will fire on essentially every nested launch in c11's own flagship workflow, and "shipping a guard that fires constantly in your own primary workflow without deciding whether an escape hatch exists is how guards get disabled wholesale three weeks later."
16. **Adjudication: both are correct and the tension is the finding.** High firing rate is simultaneously the guard's value and its adoption risk. The plan must state explicitly whether an escape hatch exists (`--allow-worktree`, env override) or deliberately declines one. Claude's framing is right that silence here guarantees a review argument.

### 2.5 Where the guard is enforced

17. **Codex** argues server-side at `agent.launch` is the correct boundary, because direct socket clients and `c11 config launch` share it, and the CLI process's own cwd is not the target's effective inherited cwd.
18. **Gemini** poses client-versus-server as an open question, leaning server-side on race-condition grounds but noting client-side gives faster feedback.
19. **Claude** proposes moving the guard *later*, to the point of final cwd resolution immediately before spawn, so the guard provably sees the path the spawn will use.
20. **Adjudication: not actually in conflict.** Codex's server-side and Claude's just-before-spawn are compatible and complementary; together they give the strongest design. Gemini's client-side option should be explicitly rejected for Codex's stated reason.

### 2.6 Scope honesty

21. **Codex** argues the ticket's stated invariant ("no two agents mutate the same tree") is strictly broader than a linked-worktree check can enforce, since main checkouts can also be shared and c11 has no ownership registry. Recommends the acceptance criteria and user-facing copy say so plainly.
22. **Claude** raises the same gap as a question (are non-worktree contested-tree cases in scope?) rather than a finding.
23. **Gemini** does not raise it.
24. Codex's framing is stronger: this is a documentation obligation, not an open design question.

---

## 3. Unique Insights (Surfaced by Exactly One Model)

### Claude only

1. **Scope leak into `pane.create` / `surface.split`.** `CwdParamResolution`'s own doc comment scopes it to `new-split` / `new-pane`. If the guard lands in the shared seam it silently changes those commands' behavior, and the non-goals do not forbid that. High value: this is a shipped-by-accident risk nobody else saw.
2. **The `new-pane --cwd inherit` misclassification.** `new-pane` special-cases the literal string, so a *present* key yields `.inherit`. Any guard that infers provenance from key presence misclassifies that case as an explicit override. This is a latent bug that a shared-seam implementation walks straight into, and it is the strongest argument for a provenance value over a presence check.
3. **Step 5 contradicts a standing operator instruction.** The plan says run the narrowed `c11-logic` slice locally; standing guidance defers all local `xcodebuild` to CI for delegator and headless runs, including `c11-logic`, after the C11-181 interruption. A delegator following the plan burns operator attention doing the thing the operator asked nobody to do.
4. **Test target membership must be verified, not inferred. [verified]** `CwdParamResolutionTests.swift` lives in `c11Tests/` on disk. This exact on-disk-versus-target class of mismatch is the documented root cause of C11-105, where a test unlinked the production socket out from under a running app.
5. **Detached-HEAD degenerate case.** `--abbrev-ref HEAD` returns the literal string `HEAD`, making the "actionable" message non-actionable. (Codex raises the same case, but as a rendering-convention question rather than as a defect in the promised copy.)
6. **Lattice-plan-as-durable-handoff argument.** A plan whose first step is "go find the seam" hands a fresh delegator an unbounded design problem dressed as a bounded implementation task, which is the shape that produced the C11-188 eight-cycle non-converging run.

### Codex only

7. **The CLI warning channel is dead on the default path. [verified]** `launch-agent` prints through `printV2Payload` / `v2OKSummary`, which ignore `warnings`. An acknowledgement appended only to the JSON array is invisible to a human operator. Highest-value unique finding in the pack: it is the one gap that would let the ticket ship and still fail its own purpose.
8. **The precise threading trap. [verified]** `agent.launch` is absent from `socketWorkerV2Methods` so it enters on main; `GitContextResolver.resolve` traps on main via `dispatchPrecondition`; and dispatching to a background queue from inside a synchronous main-actor handler and waiting risks deadlock. Proposes routing `agent.launch` (and `config.launch`, which delegates to it) through the socket worker with bounded main hops.
9. **Time-of-check / time-of-use drift.** If the guard probes a live panel cwd and later passes `nil` to surface creation, a cwd change during the probe invalidates the decision. Probe and spawn must share one captured path, or the source state must be revalidated.
10. **Pre-mutation rejection as an explicit requirement.** On refusal: no new workspace, no surface, no identity metadata, no delayed prompt, no launch-stats record. Testable and easy to get wrong.
11. **Probe-failure taxonomy.** `GitRunner` returns `nil` for non-repo, non-zero exit, timeout, exec failure, and empty output alike. Those are not equivalent for a safety guard. Also asks what a `.stale` worktree should do. **[verified]** `.stale` and `.notInRepo` are distinct cases in the resolver, so the distinction is available if the plan asks for it.
12. **The CLI target may not be compiled by the proposed gates.** `c11-logic` exercises the app logic target; `cli/c11.swift` is separate. If warning printing changes there, an explicit CLI build gate is needed.
13. **Canonical diagnostic forms already exist** (`(detached @ <sha>)`, `(no branch)`) and should be reused rather than reinvented.

### Gemini only

14. **The silent-fallback failure mode, named as its own hazard.** On rejection, does the guard hard-error or quietly fall back to the C11-194 workspace root? Gemini is the only reviewer to name silent fallback as a distinct outcome the plan must prohibit, with the right reason: "spatial confusion (where did my agent spawn?)." Small but genuinely additive, and it deserves an explicit line in the plan.
15. **The worktree-deleted-under-the-child scenario.** The parent may close its ticket and remove the worktree while the inherited child is still running. This is a concrete, previously unstated harm that strengthens the ticket's motivation.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews and ordered by blocking weight. Attribution in brackets.

### Blocking

1. **How does the guard learn the inherited cwd, and which placement's state is authoritative?** At validation time it is `nil`; the real path materializes later, and new-workspace versus existing-workspace placements derive it from different state. Name the seam, the file, and the function. [Claude, Codex]

2. **Do you reuse `GitContextResolver`, or justify a second git classifier?** It already performs the normalized `--git-common-dir` versus `--git-dir` comparison and handles submodules, detached HEAD, stale worktrees, bounded timeouts, and branch labels. If you build new, state what the existing resolver fails to provide. [Codex; implicitly answers Claude's false-positive hazard]

3. **What is the threading design?** `agent.launch` currently enters on the main actor and `GitContextResolver.resolve` traps if called there. Do you route `agent.launch` (and `config.launch`) through the socket worker, or something else? Where are the bounded main-actor hops? [Codex, Claude]

4. **How do you guarantee the probed cwd is the spawned cwd?** Is the resolved path captured and pinned for the spawn, or is the source state revalidated after the probe? [Codex, Claude]

5. **Through what channel does the explicit-`--cwd` acknowledgement actually reach a human?** The default `launch-agent` output path prints `v2OKSummary` and ignores the `warnings` array, so a warnings-only implementation is invisible in human mode. Confirm stderr line plus JSON `warnings` element, emitted once. [Codex]

### Design decisions that must be pinned

6. **Explicit versus inherited: presence check or provenance value?** `new-pane --cwd inherit` passes a present key that resolves to `.inherit`, so key presence misclassifies it. Does the design need a three-case origin (explicit / workspace root / inherited-from-surface)? [Claude]

7. **Is the seam shared with `pane.create` / `surface.split`, and if so does the guard apply there too?** The non-goals are silent, so an implementer could reasonably ship a behavior change to both commands. [Claude]

8. **If a workspace root is itself a linked worktree, does the guard fire?** Under C11-194's precedence it is technically inherited, but the operator configured it deliberately. Claude and Codex both lean toward allow. Does this require the third provenance case in Q6? [Claude, Codex]

9. **On rejection, is the outcome a hard error, or a fallback to the C11-194 workspace root?** State explicitly that there is no silent fallback. [Gemini]

10. **What is the policy when the git classification is inconclusive** (timeout, exec failure, git absent, malformed output)? Fail open with a warning, fail closed, or a distinct error? Is silent fail-open acceptable for the inherited case? [Codex, Claude]

11. **What happens on a `.stale` worktree?** Same rejection, distinct repair message, or allow? [Codex]

12. **What is the error code, and what fields are stable in `error.data`?** No existing code in the `docs/launch-agent-reference.md` table fits; `invalid_params` is semantically wrong because the params are fine and the environment is the problem. Codex proposes `linked_worktree_requires_explicit_cwd`. [Claude, Codex]

13. **What is the branch label when HEAD is detached or absent?** Reuse the existing canonical forms `(detached @ <sha>)` and `(no branch)` rather than emitting the literal string `HEAD`. [Claude, Codex]

14. **Is there an escape hatch?** Under lattice-orchestrator, one delegator per worktree is the default, so this guard fires constantly in c11's own flagship workflow. `--allow-worktree`, env override, or a deliberate no? Silence is the one answer that guarantees a review argument. [Claude]

15. **Refuse versus warn-loudly on the inherited case.** The ticket offered both; the plan chose refuse without comment. Was that deliberate, and is it settled? [Claude]

16. **Which ticket owns the shared cwd-resolution seam, and what is the merge order between C11-193 and C11-194?** [Claude, Codex]

17. **Is the guard deliberately limited to linked worktrees?** Main checkouts can also be contested, so the stated invariant "no two agents mutate the same tree" is broader than what ships. Should the acceptance criteria and user-facing copy say so plainly? [Codex, Claude]

### Process and validation

18. **Should step 5 run tests locally at all?** Standing guidance defers all local `xcodebuild`, including `c11-logic`, to CI for delegator and headless runs. [Claude]

19. **Which test target do the new tests join, and has membership been verified in the pbxproj?** `CwdParamResolutionTests.swift` lives in `c11Tests/` on disk, and this exact mismatch class caused C11-105. [Claude]

20. **Do the proposed gates compile `cli/c11.swift`?** If warning printing changes in the CLI target, `c11-logic` alone does not cover it. [Codex]

21. **Does `docs/launch-agent-reference.md` need the new error code and semantics, and does the c11 skill contract move?** The sibling C11-194 plan includes both a skill-contract step and a `scripts/sync-installed-skills.sh` step; this plan includes neither while adding a new error code and a new failure mode. [Claude, Codex]

22. **Is tagged runtime validation authorized?** The deliverable is an error message a human is meant to act on. Both reviewers want proof that no surface is created on rejection, that the explicitly overridden child actually starts in the requested worktree, and that the warning appears exactly once in human mode. [Codex, Claude]

23. **Was a subprocess-free stat-based check considered for the decision, with git reserved only for the branch label?** Note the submodule caveat: submodules also use a `.git` file, so the check needs to inspect the `gitdir:` pointer. [Claude, Gemini]

---

## 5. Overall Readiness Verdict

1. **Synthesized verdict: NEEDS REVISION.** Small, targeted, and bounded. Two of three reviewers reach this directly; the third's dissent rests on a materially shallower read of the same code rather than on a competing interpretation.

2. **What is settled and should not be relitigated:** the guard-over-default thesis, the explicit/inherited asymmetry, refuse rather than warn on the inherited case, server-side enforcement at `agent.launch`, no tenant git mutation, and the three stated non-goals. All three reviewers endorse these.

3. **What blocks a handoff to a fresh delegator** (consolidated questions 1 through 5):
   - There is no inherited cwd value at the seam the plan names.
   - The plan proposes building what already exists in hardened form.
   - A literal implementation traps or deadlocks on the main actor.
   - Nothing guarantees the probed path is the spawned path.
   - The acknowledgement has no channel that a human can see.

4. **What is one sentence each and prevents a predictable review cycle:** error code and message template, detached-HEAD fallback, probe-failure policy, `.stale` handling, escape-hatch decision, C11-193/194 ordering and the workspace-root case, scope-honesty language, docs and skill sync, CI-not-local test gating, and test-target membership.

5. **Estimated revision cost is low relative to the risk it removes.** No reviewer asked for a redesign. The revised plan is essentially the current plan plus one named provenance-carrying resolution type, one dependency decision (reuse the existing resolver), one threading decision, and roughly ten pinned single-line choices.

6. **The highest-leverage single edit:** replace step 3's "reject only inherited cwd resolution when it points at a linked worktree" with a named resolution type carrying path plus a three-case origin (explicit, workspace root, inherited-from-surface), resolved before the probe and pinned through to the spawn. That one change dissolves the core blocker, the `new-pane --cwd inherit` misclassification, the C11-194 workspace-root ambiguity, and the check/spawn drift risk simultaneously, and it is the seam C11-194 is already building from the other direction.

7. **Recommended gate before implementation starts:** the plan author answers questions 1 through 5 in the plan document itself, and states the C11-193/194 ordering. Questions 6 through 23 can be answered inline in the revised plan without a second review round.
