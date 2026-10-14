# Plan Review: C11-183 Mark Vocabulary (Standard)

- **Plan ID:** c11-183-plan
- **Model:** Claude
- **Reviewed:** 2026-07-28 13:27
- **Plan file:** `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md`
- **Mode:** read-only review

---

## Executive Summary

This is a good plan with a broken verification section and one unsettled architectural fork.

The parts that are hard to get right are right. The precedence stack at the top (spec, then downstream plan, then live mock, then operator clarification overriding all stale prose) is the single best thing in the document and is rare in plans of this type. The submodule sequence is correct and complete in the exact order CLAUDE.md demands. The `(state, flagged, suppressed)` seam with both modifiers defaulting to false is the right call: it makes C11-183 independently shippable and lets C11-184 wire fields rather than rewrite shape code. The eleven non-goals pre-empt precisely the scope creep this ticket invites. And the plan is honest about what it does not prove, which is worth more than most of its content.

The problems are concentrated and mostly small:

1. **The stated `c11-logic` verification command cannot run.** `WorkspacePulseMarkRowMetricsTests` lives in `c11Tests/WorkspaceUnitTests.swift`, and that file is a member of the host-bound `c11Tests` target only, not `c11LogicTests`. Verified in `project.pbxproj`. Combined with the non-goal "No host-bound local `c11-unit` run," Phase 4's sizing assertions have no runnable home under the plan's own constraints.
2. **The 10pt summary mark is unaddressed.** `workspacePulseMark(for:summaryScale:)` renders at 10pt today. The 9pt geometry is arithmetically exact and does not survive a rescale.
3. **A spec rule is silently dropped:** suppressed unflagged working must render the static full grid. The plan covers only suppressed waiting.
4. **The docs the plan calls stale are never corrected**, and C11-184's author will read exactly those lines.
5. **One real architectural fork:** the plan puts a shared animation clock into bonsplit and duplicates the geometry into c11. I think that is backwards, and it is the one decision that is expensive to reverse after Phase 2.

Items 1 through 4 are small edits to the plan. Item 5 deserves ten minutes of thought before Phase 2 begins.

**The single most important thing:** settle the clock-versus-geometry question now. Everything else on this list is a paragraph.

---

## The Plan's Intent vs. Its Execution

The ticket's underlying intent has three strands, and the plan serves them unevenly.

**Strand 1: fix a real accessibility defect.** Working and waiting are both solid squares today, separated by hue alone, under a code comment claiming the set "survives greyscale and a color-blind reader." Confirmed at `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:162`, and the current `TabActivityMark` body at 166 to 191 does collapse `.running` and `.waiting` into the same filled rectangle. The plan's shape vocabulary fixes this correctly.

But there is no test for it. Phase 4 tests projection logic and slot sizing. Nothing asserts the thing the ticket exists to establish: that four states produce four distinguishable marks. Given the repo's test policy forbids source-text assertions, this has to be a rendered or shape-descriptor comparison rather than a grep, which is more work, but it is also the highest-value test available in this ticket and its absence is conspicuous. The defect being fixed is a false claim about the mark set; the regression guard should be an assertion about the mark set.

**Strand 2: free the color channel for C11-184.** Served well. The default-false modifier fields are the right seam and the projection rules (flag overrides suppression, suppressed waiting projects to idle) are stated precisely enough to test.

**Strand 3: do this without regressing typing latency.** Here intent and execution drift. The spec makes the latency gate a hard merge blocker with a defined degradation ladder. The ticket repeats it in Done-when. The plan defers the entire gate to a later validation stage and adds "This implementation stage records only what it actually ran and makes no visual or typing-latency claims."

I do not think that deferral is wrong. A delegator that cannot launch a tagged app should not pretend to a latency verdict, and the operator explicitly said to skip a dedicated performance harness. But the deferral leaves an unowned decision: the branch reaches `review` with animation default-on, and if the gate later fails, someone has to flip a default that the plan has already hardcoded. Nothing says who, or what happens to the `Static marks` toggle in a static-default world (the spec itself notes the toggle "then simply has nothing to disable," which would make the shipped settings row misleading). One paragraph of contingency would close this.

---

## Architectural Assessment

### The decomposition is sound

Four phases in dependency order: pure bonsplit vocabulary, then the clock, then c11 projection and sizing and setting, then tests. Phase 1 being upstream-clean in isolation is what preserves the upstream offer, and putting it first means the bonsplit commit and push happen before the parent has anything to entangle them with. That is the correct order and it is the order that keeps the submodule from being orphaned.

The one thing missing from the front is Phase 0. The plan's binding inputs cite CLAUDE.md for "fresh-worktree provisioning," but no phase actually lists `git submodule update --init --recursive ghostty vendor/bonsplit` and the `GhosttyKit.xcframework` symlink from the main checkout. The delegator is working in an isolated worktree and the plan's own first build command is `xcodebuild -scheme c11 build`. That command is the first thing that will fail, in the documented three-stage sequence (package resolution, then missing ghostty, then missing xcframework), none of which look like code problems. Provisioning belongs in the plan as a step, not in the binding-inputs list as a citation.

### The clock-in-bonsplit choice is the fork worth arguing about

The plan puts "a small public, Bonsplit-owned generic activity-animation clock seam" inside the package, shared by both renderers, and reimplements the 9pt geometry independently in `Sources/ContentView.swift`. Its mitigation for the resulting duplication is "use the same named geometry constants/order in both renderers and review the final diff side by side."

I think this is inverted, for three reasons.

**First, it strains the upstream constraint the ticket set.** The ticket says keep the bonsplit change "PURE SHAPE VOCABULARY with no c11-specific concepts... a clean accessibility fix to offer upstream." An animation clock is not shape vocabulary. Its sole motivation is that a second renderer, living outside the package, wants to share a tick. The plan argues it is "a generic renderer primitive, not a c11 flag/socket/metadata primitive," which is true as far as it goes, but an upstream reviewer at almonk/bonsplit is being asked to accept a public timer API whose only consumer inside the package is one 9pt mark that could own its own phase. That is a harder sell than the shape fix, and it is bundled into the same commit as the shape fix.

**Second, it shares the wrong thing.** The geometry is the artifact that must not drift: two renderers drawing the same four states from two independent copies of "3pt pitch, 2pt dot, 0.5pt inset, 1.5pt frame, 1pt gap, 4pt core." "Review the final diff side by side" is the weakest mitigation in the plan and it protects nothing after the first follow-up ticket touches one renderer. The clock, by contrast, is the thing that genuinely wants to be app-scoped, because it has to gate on `NSApplication` active state and `NSWorkspace` accessibility state, both of which are app-global concepts a package should not be reaching for.

**Third, the inverse is a smaller upstream ask.** `TabActivityMark` and `TabActivityMarkMetrics` are currently internal, sitting under `Internal/Views/`. Promoting them (or a small public `MarkShape` plus metrics type) to public is a normal thing for a UI package to do: it publishes the shapes it draws. Adding an optional injected phase input (`fillIndex: Int` defaulting to full, `corePhase: Double` defaulting to 1.0) keeps `TabActivityMark` renderable statically with zero behavior change for any existing consumer, which is the most upstream-friendly shape an animation change can take. Then c11 owns the single clock in `Sources/`, where the app-active and Reduce Motion state already lives, and the sidebar renderer consumes bonsplit's public geometry instead of copying it. Upstream diff: shape vocabulary plus an optional input. Drift risk: zero.

The plan's choice is not indefensible. If the sidebar renderer genuinely needs geometry the tab chip does not (the summary row at a different scale, for instance, which is exactly the unresolved item below), sharing shapes across the boundary gets awkward fast. But the plan does not show its work on this, and it is the one decision that is painful to reverse after Phase 2, because reversing means moving a public API across a submodule boundary and taking a second push to bonsplit `main`.

### The Equatable question is left ambiguous, and it is the sharpest latency risk

`workspacePulseMarkRow` renders inside c11's `TabItemView` (`Sources/ContentView.swift:11552`), which is `.equatable()`-gated with a hand-written `==` enumerating every value input. This is precisely the structure CLAUDE.md flags as a typing-latency hot path.

The plan says two things that conflict:

- "pass stable `surfaceId`, modifier fields, selected-workspace eligibility, setting state, app-active state, and Reduce Motion state into the leaf"
- "keep the enclosing c11 `TabItemView` `Equatable` contract and `.equatable()` call site intact"

Passing new axes down from the parent means they become stored properties on `TabItemView`, and then either they go into `==` (widening the per-keystroke equality check, which the plan should say out loud) or they do not (and the leaf renders stale state, which is the classic `EquatableView` bug). The third option, reading `@AppStorage` and `@Environment(\.accessibilityReduceMotion)` directly inside the leaf, keeps `==` untouched but contradicts "pass into the leaf" and lands in the same `EquatableView` staleness hazard from the other direction, since an equal parent can suppress the body re-evaluation that would propagate the environment change. There is precedent either way: `TabItemView` already reads `@Environment(\.colorScheme)` in its body.

"Keep the contract intact" is a constraint, not an implementation. The plan needs to name which of the three it means. Note that the existing `workspacePulse: WorkspacePulseSummary` is already in `==`, so routing `flagged` and `suppressed` through the projected agent model costs nothing and is almost certainly the right answer for those two. It is the setting, app-active, and Reduce Motion axes that need a decision.

### Offscreen gating needs two strategies, not one

The plan states offscreen gating as one uniform requirement and prescribes "scroll viewport intersection for surface tabs rather than assuming SwiftUI pauses offscreen content."

For the surface tab bar it is right, and the reason is worth recording: bonsplit's tab bar is a non-lazy `HStack` inside a horizontal `ScrollView` (`TabBarView.swift:576` onward), so every tab is materialized and `onAppear`/`onDisappear` will never fire for scroll-out. There is also an existing seam the plan does not name: `TabBarScrollViewBridge` at `TabBarView.swift:97`, an `ObservableObject` already holding the `NSScrollView`. That is where viewport intersection should hang, and pointing at it would save the delegator a discovery pass.

For the sidebar it is over-engineered. `Sources/ContentView.swift:8586` already uses a `LazyVStack`, where `onAppear`/`onDisappear` is sufficient and nearly free. Prescribing viewport-intersection machinery uniformly risks adding per-row geometry observation to a scrolling surface in order to save the repaint of a 9pt square, which is a plausible net loss.

---

## Is This the Move?

Yes, with the caveat above. A few checks on the bets.

**Rebuilding the vocabulary before shipping the flagged feature is correct sequencing.** The alternative, shipping C11-184's violet recolor onto the current set, would land a modifier on top of a set where two states are already indistinguishable in greyscale, compounding the defect instead of clearing it. The dependency direction in Lattice matches.

**Default-on motion is the risky bet, and the plan knows it.** The spec's own performance contract concedes the ladder may have to be applied. My instinct agrees with the spec's stated hunch: the dip is a pure opacity change the render server can composite without body re-evaluation, while the dot fill changes which shapes are drawn and forces re-evaluation once per beat. But at ~2.5 fps per mark, forty marks is roughly 100 body evaluations per second of nine-rectangle views, which is not obviously fatal. The honest position is that neither of us knows, which is why the spec says measure both independently, and why the deferral of that measurement without a named owner is the plan's most consequential omission.

**Skipping the dedicated harness is right** given the operator said so, and given the ladder can be re-run manually if the first tagged build looks bad.

**Not opening a PR is a deviation from the standard delegator pattern** (CLAUDE.md's lattice-orchestrator default ends in an open PR). The plan states it as a non-goal without justification. Presumably the orchestrator wants to sequence C11-183 and C11-184 into one PR, or wants a fresh review before the PR exists. Either is reasonable, but the plan should say which, because a reviewer reading only the plan will read "no PR" as an omission rather than a decision.

---

## Key Strengths

**The precedence stack.** Four documents disagree with each other, and the plan resolves the conflict explicitly and in the right direction, pinning the live operator clarification above both the spec and the downstream plan, and enumerating exactly which clauses it overrides. Most plans handling four inputs simply cite them all and let the implementer discover the contradictions at 2am. This one does the work up front. It reflects the principle that a plan's job is to remove decisions from implementation time, not to relocate them.

**The submodule sequence.** Eight numbered steps, in the correct order, with `git merge-base --is-ancestor HEAD <remote>/main` inline as the gate before the parent pointer commit. This is the exact failure mode CLAUDE.md warns about (orphaned commits from a detached HEAD), and the plan does not just cite the rule, it operationalizes it with the verification command. Confirmed the submodule is currently at `d4ff0e4c` on `remotes/origin/HEAD`, that is, detached, so step 3's "work on a named branch rather than detached HEAD" is not theoretical.

**The default-false modifier seam.** `flagged` and `suppressed` defaulting to false means C11-183 changes no current behavior on those axes and C11-184 wires fields rather than rewriting shape code. This is the correct way to split a two-ticket feature: the first ticket lands the shape of the interface, the second fills it. It also makes C11-183 independently revertible.

**Honest evidence claims.** "This implementation stage records only what it actually ran and makes no visual or typing-latency claims" prevents exactly the fake-green outcome CLAUDE.md's own "Green Tests do not equal Working Product" section warns about. A plan that pre-commits to what it will not claim is a plan whose green status means something.

**The non-goals section.** Eleven of them, several closing off scope creep this ticket actively invites: no CLI or socket primitives, no skill sync, no color changes, no upstream PR, no unrelated primary-checkout edits. This is what keeps a two-renderer visual change from becoming a feature.

---

## Weaknesses and Gaps

### 1. The `c11-logic` verification command cannot run (blocker)

The plan specifies:

```sh
xcodebuild ... -scheme c11-logic ... test \
  -only-testing:c11LogicTests/SidebarActivityProjectorTests \
  -only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests
```

Verified against `GhosttyTabs.xcodeproj/project.pbxproj`:

- `SidebarActivityProjectorTests.swift` **is** a member of `c11LogicTests`. That half works.
- `WorkspacePulseMarkRowMetricsTests` is declared at `c11Tests/WorkspaceUnitTests.swift:2472`, and `WorkspaceUnitTests.swift` is **not** a member of `c11LogicTests`. It appears only in the `c11Tests` (host-bound) sources phase.

So the second `-only-testing:` argument matches nothing. Combined with the plan's own non-goal ("No host-bound local `c11-unit` run"), Phase 4's two sizing assertions ("slot never drops below 9pt", "mark side remains exactly 9pt while crowded rows overflow") have no runnable home in this plan.

Three ways out, and the plan must pick one:

- **Add `WorkspaceUnitTests.swift` to the `c11LogicTests` target.** This is a `project.pbxproj` edit, and CLAUDE.md warns that pbxproj edits via the `xcodeproj` Ruby gem normalize the whole file and produce multi-thousand-line diffs. The plan budgets zero for this and explicitly hopes to avoid "unrelated Xcode project churn" (Phase 3 says so about the settings seam). It would also drag the rest of `WorkspaceUnitTests` into the logic target, which may not compile there.
- **Put the new sizing tests in a file already in `c11LogicTests`.** `SidebarWidthPolicyTests.swift` and `WorkspaceDerivedActivityTests.swift` are both members and are topically adjacent. `WorkspacePulseMarkRowMetrics` is internal in `Sources/ContentView.swift`, and `c11LogicTests` reaches it via `@testable import` against the app dylib, so this works without touching pbxproj. This is almost certainly the right answer and it costs one sentence in Phase 4.
- **Defer the sizing tests to CI.** Acceptable but weakens the local loop.

### 2. The 10pt summary mark is unresolved

`Sources/ContentView.swift:11816` defines `workspacePulseMark(for:summaryScale:side:)` with `let side: CGFloat = overrideSide ?? (summaryScale ? 10 : 9)`, and the summary row at 11867 calls it with `summaryScale: true` inside a 16x16 frame.

The plan says "summary and footer marks use the same renderer seam" and separately that "`markSide` stays exactly 9pt," but never says what happens to the summary's 10pt. This matters because the geometry is arithmetically exact at 9: 3pt pitch times 3 equals 9; a 2pt dot with 0.5pt inset on each side equals the 3pt sub-cell; the waiting mark is 1.5 plus 1 plus 4 plus 1 plus 1.5 equals 9. None of that divides at 10. Either the summary mark drops to 9 (an unannounced visual change to the summary row that a reviewer will flag), or it scales and the sub-geometry lands on fractional points, or it keeps a bespoke path and the two seams diverge on day one.

The spec's own words are "Marks render at 9pt, always," which suggests the summary should drop to 9. The plan should say so explicitly rather than leave it to be discovered.

### 3. The suppressed-working static rule is dropped

`docs/c11-mark-vocabulary.md` is unambiguous: "**Suppressed unflagged marks never animate**, even under the animated default... A suppressed working mark renders the static full grid."

The plan's motion contract says only: "Unflagged suppressed waiting projects to idle and does not animate." That covers the waiting case, which is trivially satisfied anyway since suppressed waiting becomes idle and idle never animates. The load-bearing case, suppressed plus working must not run the typewriter fill, is absent from the contract section and absent from Phase 4's test list, even though Phase 4 tests suppression in three other respects.

It is currently dead code (nothing sets `suppressed = true` in this ticket), which is exactly why it will be missed and why C11-184 will inherit an animating suppressed mark. The rule is one line and the test is one assertion.

### 4. The stale docs are declared stale and left stale

Binding input 4 says the operator clarification "overrides stale flagged-motion prose in the prompt and docs" and states "there is no separate breathe animation." But:

- `docs/c11-mark-vocabulary.md:72` still says "For the other flagged combinations (flagged-and-working, -idle, -cold) the mark breathes as the flagged-agent plan specifies."
- `docs/c11-mark-vocabulary.md:133` still lists "breathe" among what Reduce Motion suppresses.
- `docs/c11-flagged-agent-plan.md:182` still tabulates "flagged + working / idle / cold → breathe (slow opacity cycle)," and 186 and 188 build further reasoning on it.

No phase corrects them. The non-goals exclude a different doc (`c11-attention-model-skill-section.md`) but say nothing about these two. So the plan simultaneously declares the docs wrong and leaves them as the binding spec for the next ticket, whose author will read `c11-flagged-agent-plan.md` line 182 and implement a breathe animation the operator said does not exist.

Either add a doc-correction step (cheap, and it is the same worktree) or state explicitly that doc correction is out of scope and a follow-up ticket exists. Silence is the one option that guarantees the drift propagates.

### 5. Reduce Motion has no precedent and no named mechanism

A grep for `accessibilityDisplayShouldReduceMotion` and `reduceMotion` across `Sources/` returns nothing. This is net-new plumbing with no house pattern to follow. The plan states the requirement four times but never names the mechanism (`@Environment(\.accessibilityReduceMotion)` versus `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` plus the `accessibilityDisplayOptionsDidChangeNotification` observer), nor where the observation lives, nor how a live toggle propagates through the `.equatable()` boundary. Given item 6 below, the choice is not free.

### 6. The performance ladder has no owner and no contingency

Covered above. In short: the branch reaches `review` with a default the plan may not be allowed to keep, and nothing says who flips it, what the `Static marks` row says in a static-default world, or whether that is a new ticket.

### 7. The stale comment in bonsplit is only half-addressed

The plan commits to "keep accessibility comments truthful." But `TabActivityMark`'s doc comment at `TabItemView.swift:164` also asserts: "Nothing here animates. The mark is drawn once per state change, which keeps continuous per-tab redraw off the tab-bar render path." That sentence becomes false in Phase 2, and it is exactly the sentence a future upstream reviewer will read to understand the render-path implications of the change. The ticket's whole framing is that a false comment in this file is a real defect. Do not replace one false comment with another.

### 8. Smaller items

- **`<stage11-remote>` is a placeholder in a submodule push sequence.** Verified: `vendor/bonsplit` has exactly one remote, `origin`, pointing at `https://github.com/Stage-11-Agentics/bonsplit.git`. Concretize it. A placeholder in the one sequence where a mistake orphans a commit is a needless risk.
- **The phase algorithm is named by prohibition only.** "Derive phase from UUID bytes with an explicit stable algorithm, never Swift `Hasher`" correctly rules out the footgun (`Hasher` is per-process seeded) but leaves the choice open. Naming it, for example FNV-1a over the sixteen UUID bytes modulo the beat count, removes a decision from implementation time and makes phase stability the one animation property that is cheaply unit-testable in `c11-logic`. It is currently absent from Phase 4.
- **Bonsplit's state enum is `.running`, not `.working`.** `BonsplitTabActivityState` uses `.running`. The plan speaks entirely in c11 vocabulary. Trivial, but a delegator working from the plan alone will grep for the wrong case name in Phase 1.
- **Two localization catalogs, one localization note.** The plan's localization guidance (English at `String(localized:)` call sites, do not touch `Resources/Localizable.xcstrings`) is correct for the c11 side. Bonsplit strings go through `Bundle.module.localizedString` against the package's own catalog. Probably no new bonsplit strings are needed, but the note does not distinguish the two and Phase 1 does touch accessibility text.
- **Local `xcodebuild` conflicts with a standing operator correction.** CLAUDE.md sanctions the `c11-logic` scheme locally, and the plan uses it plus a local `-scheme c11 build`. There is a recorded correction from C11-181 to the effect that during delegator or headless runs, all local c11 `xcodebuild` including the "safe" `c11-logic` scheme should be deferred to CI, after the operator interrupted exactly such a run. Worth confirming before the delegator spends the first-run multi-minute app build that `c11-logic` requires.

---

## Alternatives Considered

**Clock in bonsplit versus geometry in bonsplit.** Covered at length above. The alternative: promote `TabActivityMark` and `TabActivityMarkMetrics` out of `Internal/`, make them public, add optional injected phase inputs defaulting to the static end state, and let c11 own the single clock in `Sources/` where app-active and accessibility state already live. Upstream diff stays shape-plus-optional-input, drift risk goes to zero, and the package stops reaching for app-global state. I believe this is stronger, but the plan's choice is defensible if the sidebar's geometry needs (summary scale, overflow row) genuinely diverge from the tab chip's. The plan does not argue either side, which is the actual gap.

**One shared clock versus per-view `TimelineView`.** The plan mandates one shared clock and forbids `TimelineView` in leaves. Correct, and the spec agrees. Worth noting the repo already has two `TimelineView(.animation)` sites (`Sources/Update/UpdateBadge.swift:66` and `vendor/bonsplit/.../TabItemView.swift:1013`, the tab loading spinner), both of which are single-instance and therefore fine. The plan's prohibition should be scoped to marks so nobody reads it as a mandate to rip out the spinner.

**Deferring the latency gate versus running a proportionate check in-stage.** The plan defers everything. The alternative, a single tagged build plus a coarse fleet-scale observation recorded as an observation rather than a verdict, would cost the delegator one build and would surface a catastrophic regression before review rather than after. The operator did say to skip a dedicated harness, but "no harness" and "no observation at all" are different positions.

**Testing shape distinguishability versus not.** The plan omits it. The alternative is one behavioral test asserting four distinct rendered outputs or four distinct shape descriptors across the four states. It costs a small render seam, which the repo test policy explicitly endorses ("If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first"), and it is the only test that guards the ticket's actual thesis.

---

## Readiness Verdict

**Needs revision.** Not a rethink: the shape contract, the modifier seam, the phase ordering, and the submodule discipline are all correct, and the delegator is right to have started.

Revisions that change the verdict to ready:

1. **Fix the `c11-logic` test target problem** (item 1). Name where the sizing tests will live. Preferred: an existing `c11LogicTests` member file, not a pbxproj edit.
2. **Resolve the 10pt summary mark** (item 2). One sentence stating it becomes 9pt, or stating why it does not.
3. **Add the suppressed-working static rule** to the motion contract and to Phase 4 (item 3).
4. **Pick one answer to the `TabItemView` Equatable question** (Architectural Assessment). State which axes ride in `workspacePulse`, which are read in the leaf, and whether `==` changes.
5. **Decide clock-in-bonsplit versus geometry-in-bonsplit** and record one sentence of reasoning. This is the only one that is expensive after Phase 2 begins.
6. **Add Phase 0 worktree provisioning** (submodule init plus xcframework symlink).
7. **Say what happens to the stale breathe prose** in the two docs: fix it or file it.

Items 1 through 4 and 6 through 7 are plan edits measured in minutes. Item 5 is a judgment call that should be made before the Phase 2 commit rather than after.

---

## Questions for the Plan Author

1. **`WorkspacePulseMarkRowMetricsTests` is in `c11Tests`, not `c11LogicTests`, so the stated `-only-testing:` command matches nothing.** Where will the new sizing tests live? Moving `WorkspaceUnitTests.swift` into the logic target means a pbxproj edit with the documented diff-bloat problem; adding assertions to an existing logic-target file (`SidebarWidthPolicyTests` or `WorkspaceDerivedActivityTests`) avoids it entirely. Which?

2. **Do the summary marks drop from 10pt to 9pt?** `workspacePulseMark(summaryScale: true)` renders at 10 today inside a 16x16 frame. The 9pt geometry does not divide at 10. The spec says "Marks render at 9pt, always." Confirm the summary row is included and that the resulting visual change is intended.

3. **Where is "suppressed unflagged working renders the static full grid"?** The spec requires it; the plan's motion contract covers only suppressed waiting. Is the omission deliberate (on the grounds that nothing sets `suppressed` in this ticket), or an oversight to correct?

4. **Which of the three Equatable strategies is intended?** (a) New stored properties on `TabItemView` added to `==`; (b) new axes routed through the existing `workspacePulse` value which is already in `==`; (c) `@AppStorage` and `@Environment` read inside the leaf with no `TabItemView` change. Each has a different staleness and latency profile, and "keep the contract intact" does not select one.

5. **Why does the clock go into bonsplit rather than the geometry?** Specifically: was promoting `TabActivityMark`/`TabActivityMarkMetrics` to public and injecting a phase from a c11-owned clock considered and rejected? If so, on what grounds? The current split shares the app-scoped thing and duplicates the drift-prone thing.

6. **How does a bonsplit-owned clock learn about app-active state and Reduce Motion?** Both are app-global (`NSApplication`, `NSWorkspace`). Does the package read them directly (which weakens the upstream story), or does c11 push gating in, and if the latter, what is the API shape?

7. **What is the Reduce Motion mechanism?** `@Environment(\.accessibilityReduceMotion)` or the `NSWorkspace` property plus `accessibilityDisplayOptionsDidChangeNotification`? There is no existing usage anywhere in `Sources/` to follow, and the answer interacts with question 4.

8. **What is the contingency if the latency gate later fails?** The spec's ladder is fill-fails-becomes-dip-only, dip-fails-becomes-static-default. Who applies it, in which ticket, and what does the `Static marks` settings row say when the default is already static (the spec notes it would have nothing to disable)?

9. **Will the stale breathe prose in `docs/c11-mark-vocabulary.md` (lines 72, 133) and `docs/c11-flagged-agent-plan.md` (lines 182, 186, 188) be corrected in this branch?** If not, is there a follow-up ticket, given C11-184's implementer will read those lines as the spec?

10. **Should the offscreen-gating strategy differ per renderer?** The sidebar already uses a `LazyVStack` (`ContentView.swift:8586`) where `onAppear`/`onDisappear` suffices; the tab bar uses a non-lazy `HStack` in a `ScrollView` where it does not. Is the intent to build viewport intersection for both, or only for the tab bar? And should it hang off the existing `TabBarScrollViewBridge` (`TabBarView.swift:97`)?

11. **Is there a test for the ticket's actual thesis, that the four states are distinguishable by shape?** Phase 4 covers projection and sizing only. Given the repo's ban on source-text assertions, this needs a render or shape-descriptor seam. Is one planned, or is greyscale distinguishability being left entirely to the human validation stage?

12. **What is the stable phase algorithm?** "Not `Hasher`" rules out the footgun but leaves the choice open. Naming it would make phase stability unit-testable in `c11-logic`, which is currently the only cheaply testable animation property and is absent from Phase 4.

13. **Will Phase 1 also correct the performance sentence in `TabActivityMark`'s doc comment** ("Nothing here animates. The mark is drawn once per state change..."), or only the accessibility sentence? Both become false.

14. **Is the local `xcodebuild` usage confirmed with the operator?** There is a standing correction from C11-181 to defer all local c11 `xcodebuild`, including the `c11-logic` scheme, to CI during delegator runs. The plan hardcodes both a local logic test and a local `-scheme c11 build`, and the first `c11-logic` run in a fresh worktree pays the full app build cost.

15. **Where does worktree provisioning happen?** `git submodule update --init --recursive ghostty vendor/bonsplit` plus the `GhosttyKit.xcframework` symlink are cited in binding inputs but appear in no phase. The plan's first build command will fail without them.

16. **Why no PR in the parent repo?** Stated as a non-goal without reasoning. Is C11-183 being held to merge alongside C11-184, or is the orchestrator opening the PR after fresh review? A reviewer reading only the plan cannot tell whether this is a decision or an omission.

17. **`<stage11-remote>` appears five times as a placeholder.** The submodule has exactly one remote, `origin`, pointing at `Stage-11-Agentics/bonsplit`. Any reason not to write `origin` literally in the sequence where a mistake orphans a commit?

18. **Does anything new land in bonsplit's own localization catalog?** Phase 1 touches accessibility text; bonsplit strings go through `Bundle.module.localizedString` against a separate catalog from `Resources/Localizable.xcstrings`. The plan's localization note addresses only the c11 side.
