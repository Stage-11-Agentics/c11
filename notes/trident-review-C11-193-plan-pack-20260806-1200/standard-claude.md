# Standard Plan Review: C11-193

- **PLAN_ID:** c11-193-plan
- **MODEL:** Claude
- **Plan file:** `.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md`
- **Ticket:** C11-193, "launch-agent: refuse to start an agent in another agent's linked worktree"
- **Reviewed:** 2026-08-06

---

## Executive Summary

**The bet is right. The plan is not yet executable.**

The underlying idea is one of the better small tickets I have read in this repo. The ticket author correctly identified that this is a *guard* problem, not a *default* problem, and articulated why: the failure is silent, both parent and child lack any signal, and the damage surfaces later as unattributed edits in someone else's branch. That reasoning is sound and I would not relitigate it.

The plan, however, is five abstract lines standing on top of a ticket that is unusually concrete. The ticket supplies the exact detection commands, the exact error text, and a real incident with dates. The plan restates that material at *lower* resolution and pins none of the decisions an implementer will actually be forced to make. Every sentence is defensible; almost none of them are actionable.

**The single most important thing:** the plan's central instruction, "reject only inherited cwd resolution when it points at a linked worktree," describes an operation on a value that does not exist at the seam the plan is aiming at. In the current code, an absent `cwd` resolves to `.inherit` with `resolved = nil`, and the actual directory is only materialized much later in the inheritance chain (parent panel cwd → workspace cwd → `$HOME`). There is no inherited path string to probe at validation time. Materializing it is the hardest part of this ticket, it lives on the main actor, and the plan does not mention it. An implementer following this plan literally will discover this in hour one and will then be improvising the design that the plan was supposed to contain.

Verdict: **Needs revision.** Small, targeted revision, not a rethink. Six or seven decisions need pinning; the architecture underneath them is fine.

---

## The Plan's Intent vs. Its Execution

The intent, from the ticket, is precise: enforce the invariant *no two agents mutate the same tree*, at the one point where c11 silently violates it. The plan preserves that intent in outline and correctly keeps the asymmetry (refuse inherited, permit explicit with one acknowledgement). That is faithful.

Where it drifts is in resolution. Compare the two documents:

| The ticket supplies | The plan says |
|---|---|
| Exact commands: `git rev-parse --git-dir` vs `--git-common-dir` | "a testable linked-worktree probe that compares" them |
| Exact user-facing message, naming the branch | "one actionable acknowledgement" / "actionable branch/error text" |
| Explicit-`--cwd` case should "say so once" | "preserve explicit `--cwd` as an intentional override" |
| A real incident with three agents and a named branch | not referenced |

The plan is a *summary of the ticket*, not a *plan for the ticket*. It reads like it was written by compressing the description rather than by reading the code. The tell is step 1: "Locate the existing launch-agent cwd resolution seam and its pure-logic tests." A plan written after reading the code would name that seam. A plan that asks the implementer to go find it has deferred the design work, which means the plan is not the artifact that decides anything.

This matters more than usual here because of how this repo works. Under the lattice-orchestrator workflow the plan is the durable handoff to a fresh delegator in its own worktree with no memory of the planning conversation. A plan whose first step is "go figure out where this goes" hands the delegator an unbounded design problem while presenting it as a bounded implementation task. That is precisely the shape that produces the eight-cycle non-converging runs this repo has already been burned by (see the C11-188 memory).

To be fair on calibration: Lattice plans in this repo are habitually terse, and the delegator will read the ticket alongside the plan. Judged as "plan plus ticket," this is thin but not empty. Judged as a document that decides anything the ticket left open, it decides nothing.

---

## Architectural Assessment

### The decomposition is right in shape

Probe → policy → adapter → tests is the correct factoring, and it matches the existing local idiom. `CwdParamResolution` in `Sources/TerminalController.swift:22` is exactly this pattern: a pure enum with an `Outcome`, a thin socket adapter (`v2ResolveCwdParam`, ~line 2767) mapping outcomes onto the error envelope, and behavioral tests against the real filesystem. Reusing that shape is the right instinct and the plan gets credit for it.

### But the plan is aimed at the wrong seam, and the right one is harder

Three concrete problems, in ascending order of severity.

**1. `CwdParamResolution` is scoped to a different command.** Its own doc comment reads: "Pure validation for the `--cwd` flag on `new-split` / `new-pane` (socket methods `surface.split` / `pane.create`)." `agent.launch` does pass a `cwd` param and the reference doc says it is "validated server-side," so it plausibly shares the adapter, but the plan says "the existing launch-agent cwd resolution seam" as though it is singular, known, and launch-agent-specific. If the guard lands in the shared seam it silently changes `new-pane` and `new-split` behavior too. The non-goals list does not forbid that, so an implementer could reasonably ship it. That is a scope leak hiding in an unstated assumption.

**2. The explicit/inherited distinction is clean for launch-agent and dirty for the shared seam.** In `cli/c11.swift`, launch-agent does:

```swift
if let v = optionValue(commandArgs, name: "--cwd") { params["cwd"] = resolvePath(v) }
```

No `inherit` keyword special-case. So for launch-agent, key-present versus key-absent is a faithful proxy for explicit versus inherited. Good news the plan never claims. But `new-pane` *does* special-case the literal string:

```swift
params["cwd"] = cwd.lowercased() == "inherit" ? "inherit" : resolvePath(cwd)
```

so there, a *present* key yields `.inherit`. If the guard is written against `CwdParamResolution.Outcome` alone, the two commands disagree about what "explicit" means, and `new-pane --cwd inherit` gets classified as explicit-override when the user meant inherit. This is a real latent bug that a shared-seam implementation walks straight into, and the plan gives no guidance.

**3. The blocker: there is no inherited path to probe.** This is the one that matters. `CwdParamResolution.Outcome.inherit` carries no payload, and `v2ResolveCwdParam` sets `resolved = nil`. The doc comment is explicit that nil "falls through to the existing inheritance chain (parent panel cwd → workspace cwd → `$HOME`)," which is resolved later, in panel creation, on the main actor.

So step 3 as written, "reject only inherited cwd resolution when it points at a linked worktree," is asking a `nil` to point somewhere. To implement the guard the delegator must **first materialize the would-be inherited cwd** at guard time: reach into the resolved `TabManager`/panel state, read the launching surface's cwd, and only then probe it. That is main-actor work, it duplicates a resolution chain that currently lives elsewhere, and if done carelessly it either forks the chain (guard checks one path, spawn uses another, guard becomes a lie) or drags main-actor state into what was supposed to be a pure enum.

The plan does not acknowledge any of this. It is the single largest gap and the reason I cannot call this ready.

### An alternative framing worth considering

Rather than guarding at param-validation time, guard at the point where the cwd is *finally* resolved, immediately before spawn, with a small struct carrying both the path and its provenance:

```
enum CwdOrigin { case explicit, workspaceRoot, inheritedFromSurface }
struct ResolvedCwd { let path: String; let origin: CwdOrigin }
```

The policy function then stays pure and trivially testable: `(ResolvedCwd, WorktreeProbeResult) -> Decision`, where `Decision` is `allow`, `allowWithWarning`, or `refuse(branch:)`. The probe is injected, so tests never shell out to git.

This framing is stronger than the plan's for three reasons. It guarantees the guard sees the same path the spawn will actually use, closing the guard-lies-about-the-path failure mode. It makes provenance a first-class value instead of inferring it from param presence, which fixes the `new-pane --cwd inherit` ambiguity by construction. And it is exactly the seam C11-194 is already building: the sibling plan's step 4 is "Centralize and test cwd precedence: explicit `--cwd`, workspace root, then launching-surface cwd." That centralized precedence function *is* the natural home for `CwdOrigin`. Two tickets are converging on the same code from opposite directions and neither plan says so.

---

## Is This the Move?

Yes, with a sequencing caveat the plan should have addressed.

**Guard over default is correct.** The ticket's argument holds: a default expresses a preference, a guard enforces an invariant, and only the guard survives someone passing `--cwd` by hand. Silent cross-agent tree mutation is genuinely among the most expensive bug shapes to trace, because the evidence points at the wrong agent. Paying a small ergonomic tax to make it loud is a good trade.

**The priority order inside the plan is defensible** (probe, then policy, then tests) and the non-goals are well chosen. "Do not mutate tenant git state" is exactly the right instinct in a codebase whose CLAUDE.md draws a hard line at the edge of c11's own runtime.

**The sequencing caveat.** C11-193 and C11-194 change the same value from opposite ends, and neither plan names an order. This is not hypothetical: if 194 lands first, the inherited cwd is usually the workspace root and the guard rarely fires; if 193 lands first, it fires constantly. Worse, there is an unresolved semantic collision. Under 194's precedence, suppose an operator deliberately sets a workspace root that *is* a linked worktree, which is a completely reasonable thing to do when a workspace exists to work one branch. Is that "inherited" (refuse) or "intentional" (allow)? I would argue strongly it is intentional and must be allowed, since the operator explicitly configured it, but the plan's binary explicit-versus-inherited framing has no room for that third case. This needs deciding before either ticket ships, not after.

**The ergonomics question nobody asked.** c11's own default workflow, lattice-orchestrator, puts one delegator per git worktree. This guard will fire on essentially every nested launch in the repo's flagship workflow. The ticket's answer, "pass `--cwd` explicitly," is acceptable, but shipping a guard that fires constantly in your own primary workflow without deciding whether an escape hatch exists is how guards get disabled wholesale three weeks later. The plan should state, one way or the other, whether it adds `--allow-worktree` or an env override, or deliberately declines. Silence is the one answer that guarantees an argument during review.

---

## Key Strengths

**Guard-not-default reasoning.** Reflects a real principle: enforce invariants where they can be violated, not where they are usually respected. Defaults are advisory; invariants need teeth. The ticket names the invariant precisely ("no two agents mutate the same tree") rather than the proxy ("children start at the project root"), which is why the guard generalizes correctly to the explicit-`--cwd` case.

**Asymmetric treatment of explicit versus inherited.** This is the plan's best idea and it is genuinely subtle. Refusing the inherited case while permitting the explicit one with an acknowledgement respects operator intent while eliminating the accident. It converts a silent failure into either a hard stop or a conscious choice, never a surprise. Many plans would have refused both and made the tool annoying, or warned on both and made the warning noise.

**Testability as a first-class step, not an afterthought.** Steps 2 and 4 push toward a pure, injectable probe. This matches the repo's stated test-quality policy (behavior through executable paths, not source-text assertions) and the existing `CwdParamResolution` precedent. In a codebase where local `xcodebuild` is discouraged and CI is the gate, pure logic seams are worth real design effort.

**Non-goals exist and are correctly chosen.** Three of them, each ruling out a plausible scope creep: blocking explicit helpers, mutating git state, changing focus behavior. The last one shows awareness of the socket focus policy in CLAUDE.md, which is a good sign about the author's context.

---

## Weaknesses and Gaps

Ordered by how much damage each will cause downstream.

**1. The inherited cwd is not available at the guard point (blocker).** Detailed above. Downstream effect: the delegator either invents the materialization design mid-implementation, or implements the guard against `nil` and ships something that never fires. The second outcome is worse because it passes review as a no-op.

**2. Running `git` from the app process is entirely unaddressed.** The probe shells out. The plan says "testable" and stops. Four unaddressed hazards, all of which this repo has specifically been bitten by:

- **Threading.** CLAUDE.md's socket command threading policy says default to off-main and require an explicit comment to justify main. `agent.launch` touches main-actor state. A synchronous `Process()` git call on the main actor is a beachball or deadlock hazard in a codebase carrying `notes/BUG-main-thread-deadlock-attachSurface.md` and a whole C11-192 workstream on fingerprinting main-thread hangs. This must be stated in the plan, not discovered.
- **Timeout.** If git blocks on an index lock, a network filesystem, or a pathological repo, what happens? An unbounded subprocess call from a UI process is a hang. There must be a timeout and a defined behavior on expiry (I would argue: allow, and warn, since failing open on a diagnostic is better than wedging launches).
- **PATH.** `docs/launch-agent-reference.md` explicitly documents that "the app-process PATH is poorer than the login-shell PATH a pane actually gets," which is why a missing launch binary is a warning rather than an error. The same trap applies to `git`. Use an absolute path or handle not-found explicitly.
- **Non-git directories.** `rev-parse` exits non-zero outside a repo. That must be treated as "allow," not as an error. Obvious once stated; easy to get wrong in a hurry.

**3. A likely false-positive in the detection itself.** `git rev-parse --git-dir` returns a **relative** path (`.git`) when run from a repo's top level, while `--git-common-dir` may return an absolute path depending on cwd and git version. A naive string comparison therefore produces false positives, and false positives here mean *refusing legitimate launches in the main checkout*, the loudest possible failure. The ticket says "verified on this machine," but that verification was done from one particular cwd. The robust form is `git -C <path> rev-parse --path-format=absolute --git-dir --git-common-dir` (git ≥ 2.31), or comparing after `realpath` normalization. A plan is exactly where this gets pinned. Also note the probe must use `-C <path>` and must never `chdir` the app process.

**4. Branch-name extraction has an undefined degenerate case.** `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD` when detached, so the actionable message becomes "linked git worktree on 'HEAD'," which is not actionable. The plan promises "actionable branch/error text" without defining the fallback.

**5. The error code is undefined.** The socket returns a code/message envelope, and `docs/launch-agent-reference.md` carries a table of them (`unknown_agent_type`, `empty_command`, `invalid_params`, `not_found`, and so on). No existing code fits: `invalid_params` is semantically wrong, since the params are fine and the *environment* is the problem. An implementer with no guidance will invent one, and the docs table will go stale the moment it ships. Name the code in the plan. Likewise, name the channel for the explicit-`--cwd` acknowledgement: the result envelope already has a `warnings` array precedent (used for the missing-binary case), and that is almost certainly the right vehicle.

**6. Docs and skill contract are missing from the plan.** CLAUDE.md states the hard rule twice over: every change to CLI, socket protocol, or metadata schema is incomplete until the skill is updated, and editing a skill source is incomplete until `scripts/sync-installed-skills.sh` runs. This ticket changes launch-agent's observable failure modes and adds an error code, so `docs/launch-agent-reference.md` is going stale by construction. The sibling plan C11-194 *does* include "update the c11 skill contract for any CLI/socket changes" and "sync installed skills if edited." C11-193 omits both. When two sibling plans written for the same subsystem disagree about whether the docs rule applies, the one that omits it is wrong.

**7. Step 5 conflicts with a standing operator instruction.** The plan says "Run the narrowed `c11-logic` test slice, then the proportionate broader safe logic gate." The operator's standing guidance is to defer *all* local c11 `xcodebuild` to CI during delegator and headless runs, explicitly including the nominally safe `c11-logic` scheme, after the operator interrupted exactly such a run during C11-181. CI's `build` job is the compile-plus-logic gate. Step 5 should say "push and let CI gate it," not "run it locally." This is not a nitpick: a delegator following the plan will burn operator attention doing the thing the operator asked nobody to do.

**8. Test target membership is assumed, not verified.** The plan says `c11-logic`. But the closest analogous test, `CwdParamResolutionTests.swift`, lives in `c11Tests/` **on disk** while its doc comment claims exercisability from `c11LogicTests`. This exact on-disk-versus-target mismatch is the documented root cause of C11-105, where a test living in `c11Tests/` but belonging to the `c11LogicTests` target unlinked the production socket out from under a running app. The plan must state which target the new tests join and require verifying membership rather than inferring it from the directory name.

---

## Alternatives Considered

**Guard versus better default.** The ticket considered this and chose correctly; C11-194 is the default. They are complements. No objection.

**Guard at param validation (plan) versus guard at final cwd resolution (alternative).** Covered above. The alternative is meaningfully better: it sees the path the spawn actually uses, it makes provenance explicit rather than inferred, and it converges with the seam C11-194 is already building. I would move the guard here.

**Refuse versus warn-loudly on the inherited case.** The ticket floated both ("refuse, or warn very loudly") and the plan silently picked refuse. I agree with refuse, but the plan should say it *chose*, and say why, because it is the decision most likely to be questioned in review. The argument for refuse: a warning printed to a socket client that an orchestrating agent may never render is not a signal at all. The failure mode this ticket exists to kill is precisely "nobody sees the signal."

**Shelling out to git versus reading `.git` directly.** The ticket notes that a linked worktree has a `.git` *file* rather than a directory, which is a zero-subprocess, zero-timeout, zero-PATH check that would sidestep hazard #2 entirely. It is slightly less general than `rev-parse` (submodules also use a `.git` file, so it needs a disambiguating check on the `gitdir:` pointer). Worth an explicit paragraph: the stat-based check is dramatically cheaper and safer to run on the main actor, and the branch name is the only thing that genuinely needs git. A hybrid, stat to decide, git only to name the branch for the message, may be the best of both. The plan does not consider it.

**Blocking versus warning for the explicit case.** Plan permits with acknowledgement. Correct, and the ticket agrees.

---

## Readiness Verdict

**Needs revision.** Not a rethink; the thesis is sound and the non-goals are well drawn. But this plan cannot be handed to a fresh delegator as-is, because its central step operates on a value that does not exist at the seam it names, and because it instructs a local test run the operator has asked not to happen.

**What changes the verdict to ready:**

1. Name the actual file and function where the guard lands, after reading the code. Resolve whether it is launch-agent-specific or shared with `pane.create`/`surface.split`, and state the consequence either way.
2. Say how the inherited cwd is materialized at guard time, and confirm the guard and the spawn read the same value.
3. Specify the probe's execution contract: thread/actor, timeout and its fail-open behavior, git resolution strategy given the poor app-process PATH, non-git-directory handling, and absolute-path normalization to avoid the relative-`.git-dir` false positive.
4. Name the error code and the exact message template, plus the fallback when HEAD is detached. Name the channel for the explicit-`--cwd` acknowledgement (`warnings` array, most likely).
5. Add the docs and skill step: `docs/launch-agent-reference.md` error table, the c11 skill if the CLI contract moves, and `scripts/sync-installed-skills.sh` if any skill is touched. Match the sibling plan.
6. Replace "run the narrowed `c11-logic` slice" with pushing to CI, and state which test target the new tests join, with membership verified in the pbxproj rather than assumed from the directory.
7. State the C11-193 / C11-194 ordering, and decide the workspace-root-is-a-worktree case.

Items 1 through 3 are the blockers. Items 4 through 7 are each a single sentence and each prevents a predictable review cycle.

---

## Questions for the Plan Author

1. **Which seam, exactly?** Does `agent.launch` route its `cwd` through `v2ResolveCwdParam`/`CwdParamResolution`, or does it have its own path? Please name the file and line after reading the code.

2. **If the seam is shared with `pane.create`/`surface.split`, is the guard supposed to apply there too?** The non-goals do not say. My read is that it should not, since the ticket is specifically about agent launches, but that means the guard cannot live in the shared enum unchanged.

3. **How does the guard learn the inherited cwd?** At validation time it is `nil` and the real path is resolved later in the panel-creation chain. What is the plan for materializing it, and how do you guarantee the guard and the spawn see the same directory?

4. **`new-pane --cwd inherit` passes a present key that resolves to `.inherit`.** If the guard classifies explicit-versus-inherited by key presence, that case is misclassified. Does the guard need a provenance value rather than a presence check?

5. **Which thread does the git probe run on?** CLAUDE.md's threading policy defaults to off-main. If it must be main-actor, what is the timeout, and what happens on expiry: allow, refuse, or warn?

6. **How is `git` located, given the documented poor app-process PATH?** Absolute path, `xcrun`, or something else? And what is the behavior when git is absent entirely?

7. **Have you confirmed the `--git-dir` versus `--git-common-dir` comparison is safe from the repo top level?** `--git-dir` can return a relative `.git`, which risks a false positive that would refuse launches in the *main* checkout. Will you use `--path-format=absolute` or realpath normalization?

8. **Was the cheaper stat-based check considered?** A linked worktree has a `.git` file rather than a directory. That needs no subprocess and no timeout. Is there a reason to prefer `rev-parse` beyond needing the branch name for the message?

9. **What is the branch name when HEAD is detached?** `--abbrev-ref HEAD` returns `HEAD`, which makes the message non-actionable. What is the fallback: short SHA, worktree directory name, something else?

10. **What error code does the refusal use?** No existing code in the `docs/launch-agent-reference.md` table fits. Are you adding one, and will you update that table?

11. **Through what channel does the explicit-`--cwd` acknowledgement reach the caller?** The result envelope's existing `warnings` array seems right. Confirm, so it does not get invented twice.

12. **Is there an escape hatch?** Under lattice-orchestrator, one delegator per worktree is the default, so this guard will fire constantly in c11's own flagship workflow. Is there an `--allow-worktree` flag or env override, or is "pass `--cwd`" the whole answer? A deliberate "no" is fine; silence is not.

13. **Which ships first, C11-193 or C11-194?** They modify the same resolution from opposite ends and the ordering changes how often the guard fires.

14. **If a workspace root is itself a linked worktree, does the guard fire?** Under 194's precedence that value is technically inherited, but the operator configured it deliberately. My strong view is it must be allowed. Do you agree, and does that require a third provenance case beyond explicit/inherited?

15. **Which test target do the new tests join, and have you verified membership in the pbxproj?** Note that `CwdParamResolutionTests.swift` lives in `c11Tests/` on disk despite a doc comment claiming `c11LogicTests`, and that this exact mismatch class caused C11-105.

16. **Should step 5 be running tests locally at all?** Standing guidance is to defer all local `xcodebuild` to CI for delegator and headless runs, including `c11-logic`, after the C11-181 interruption. Was the local run intentional?

17. **Does `docs/launch-agent-reference.md` or the c11 skill need updating?** The sibling plan includes both a skill-contract step and a sync step; this one includes neither, while adding a new error code and a new failure mode.

18. **Refuse versus warn on the inherited case:** the ticket offered both and the plan chose refuse without comment. Was that a deliberate choice, and is it settled? It is the decision most likely to be challenged in review.

19. **Are there non-worktree contested-tree cases worth covering,** for example two agents in the same checkout on the same branch? The stated invariant ("no two agents mutate the same tree") is broader than the linked-worktree check that implements it. Is the gap intentional for now?

20. **Is there any manual or computer-use validation expected,** or is a green CI logic suite the whole gate? Given that the observable deliverable is an error message a human is supposed to act on, I would want to see the actual message text once in a real terminal before calling it done.
