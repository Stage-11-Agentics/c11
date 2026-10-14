# Trident Adversarial Synthesis: C11-183 Plan Review

**Ticket:** C11-183, "Rebuild agent-state mark vocabulary: lifecycle in shape alone"
**Plan under review:** `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md`
**Reviewers synthesized:** Claude (adversarial), Codex (adversarial), Gemini (adversarial)
**Pack:** `notes/trident-review-C11-183-plan-pack-20260728-1327/`
**Synthesized:** 2026-07-28

---

## 0. Executive Summary

All three adversarial reviewers converge on the same verdict: **the plan is strong on the easy half (geometry, filenames, git ceremony) and weak or absent on the hard half (animation architecture, empirical latency validation, cross-module policy propagation).** None of the three recommends executing the plan as written.

The three severity calls, in the reviewers' own framing:

1. **Claude:** "high concern, narrow and fixable" — the *verification architecture* is broken such that the change ships with effectively zero executed test coverage of what it actually changes. Claude is the only reviewer that read the tree and found hard, verified defects in the plan's own commands.
2. **Codex:** "major rework required before this plan is safe to execute as written" — the ticket's HARD SHIP BLOCKER can neither pass nor fail because no threshold, baseline, workload, or protocol exists.
3. **Gemini:** "critical architectural inversion plus high likelihood of failing its own performance gates" — and if the gate fails, the most complex piece of the implementation becomes dead code.

**The three things all three models independently flagged:**

1. Putting the shared animation clock inside `vendor/bonsplit` is architecturally backwards and destroys the "upstream-clean" premise the ticket explicitly demanded.
2. Deferring 100% of empirical validation converts a capitalized merge blocker into an unowned, unmeasurable, thresholdless IOU.
3. The degradation ladder (fill → dip-only → static) is the entire mitigation for default-on animation, and the plan builds none of it, so a failed gate has no remedy in code that exists.

**The single most actionable finding** comes from Claude alone and is verified against the tree: the plan's own verification command targets a test class in the wrong build target, and the "no PR" decision means CI never runs either. That is not a judgment call; it is a defect that will error on execution. Fix that before anything else, because it is cheap and it currently invalidates the plan's entire evidence chain.

**Recommended disposition:** the static-geometry work (Phase 1 shapes, metrics) can proceed. The animation clock, setting propagation, offscreen gating, and modifier (`flagged`/`suppressed`) behavior should be treated as unsettled pending answers to Section 5.

---

## 1. Consensus Risks

Ordered by agreement strength, then severity. Agreement counts in brackets.

### 1.1 The shared clock does not belong in Bonsplit [3/3, all reviewers led with this]

Every model independently challenged the same decision, and each reached it by a different route:

1. **Gemini** calls it "an architectural inversion": c11 is the orchestrator, bonsplit is a UI component library, and the parent app should own the global ticker and pass phase down. Forcing a tab bar to own the global heartbeat "just to keep the vocabulary together is a mistake."
2. **Claude** calls the "generic renderer primitive" justification "a definitional move, not an argument." An app-lifetime singleton timer with registration tokens, app-active gating, Reduce Motion gating, and scroll-viewport intersection tracking is application infrastructure, not shape vocabulary. The ticket's word-for-word instruction was "PURE SHAPE VOCABULARY with no c11-specific concepts."
3. **Codex** adds the embedder argument: a process singleton inside a reusable package makes every embedder inherit scheduling behavior, and default-on animation changes behavior for all of them unless the package contract is explicitly opt-in.

**Shared counterproposal (all three converge on the same alternative):** Bonsplit exports a host-neutral mark view plus a deterministic phase function and accepts a `phase: Double` (or small value type) as a plain parameter. c11 owns the timer, app-active gating, Reduce Motion observation, and viewport intersection, all of which it already has machinery for. Codex adds a fallback: if bonsplit must schedule its own internal leaves, make it an *injected* service with a no-animation default for other embedders, and prove c11 supplies one shared instance to both renderers.

**Why this is the top consensus item:** it is the only finding where three models, given the same plan, wrote three independently-derived rejections of the same sentence.

### 1.2 The hard latency gate is deferred into unmeasurability [3/3]

1. **Codex** is most explicit: lines 231-234 defer all visual and timing validation while lines 180 and 265 exclude a harness, and nothing replaces the exclusion. No tagged-build command, no fleet construction method, no baseline, no measured quantity, no threshold, no typing workload, no evidence format, no ladder procedure. "The ticket's hard ship blocker can therefore neither pass nor fail."
2. **Claude** names the mechanism of failure: "plans that convert a blocker into a downstream handoff without naming the downstream owner and the pass criterion reliably ship the blocker unmeasured." It also catches the specific scope slippage: the operator said skip the *harness* and then said "perform proportionate tagged-build validation," and that trailing clause is the one thing the plan did not carry into its precedence list.
3. **Gemini** predicts the outcome: the gate "barely passes, or fails sporadically on older Intel Macs."

**Consensus remedy:** pre-register the scenario and the pass/fail threshold *now*, in this plan. Codex supplies a ten-item protocol (tagged build + QA launch commands, reproducible 20-agent/40-mark setup, both renderers concurrently visible, motion-disabled baseline, fixed typing scenario and measurement source, explicit regression threshold, separate fill-only and dip-only runs, ladder decision branch, background/unselected/collapsed/offscreen readbacks, artifact names). The delegator does not have to *run* it; a fresh validator does. But a fresh validator cannot invent an acceptance threshold after seeing the result.

### 1.3 The degradation ladder is designed in the spec and built nowhere [3/3]

1. **Claude:** the ladder is "the *entire* risk mitigation for a default-on animation," the plan reproduces none of it, and the ticket's "Done when" explicitly permits "or the ladder is applied and the outcome recorded" as an escape hatch that the plan removes by not building it. The shipped `Static marks` boolean cannot express the middle rung (dip yes, fill no).
2. **Codex:** without independently controllable experimental switches, a validator who finds a regression cannot tell whether viewport tracking, scheduler fan-out, dot-body rebuilds, or duplicate sidebar marks caused it. "The task returns to implementation without diagnostic leverage."
3. **Gemini:** predicts the fill fails and asks the follow-on nobody else asked: if we fall back to dip-only, is the complex dot-fill code removed, or left as dead weight?

**Consensus remedy:** ship the setting as a three-value enum (`animated` / `attentionOnly` / `static`) rather than a boolean. One type, pre-pays the ladder, and gives the validator the independent switches the ladder procedure requires.

### 1.4 Two renderers, duplicated geometry, no mechanism to prove agreement [2/3, Claude + Codex]

1. The ticket's first "Done when" is literally "Both renderers draw the new set and **agree**."
2. The plan's mitigation is "use the same named geometry constants/order in both renderers and review the final diff side by side."
3. **Claude:** "Side-by-side diff review is not a mechanism; it is a hope." There is no shared constant source (bonsplit must stay c11-agnostic, c11 cannot reach into bonsplit `Internal/`) and no test asserting agreement.
4. **Codex** adds the irony: "the whole ticket exists because two visual states drifted into an accessibility lie. Duplicating the replacement vocabulary invites a future recurrence." It also notes the mirrored-constant tests, if duplication is kept deliberately, must cover the waiting frame/core arithmetic, not just the outer 9pt slot.

### 1.5 Reduce Motion is stated four times and specified zero times [2/3, Claude + Codex]

1. **Claude** verified there is **zero prior art**: grepping `accessibilityDisplayShouldReduceMotion` / `reduceMotion` / `ReduceMotion` across `Sources/` and `vendor/bonsplit/Sources/` returns nothing.
2. Both reviewers flag that reading the value once is insufficient: `NSWorkspace.shared.notificationCenter` `accessibilityDisplayOptionsDidChangeNotification` must be observed for live toggling.
3. **Claude** adds the scope trap: per-leaf observation is N observers, reintroducing exactly the proliferation the plan forbids for timers.
4. **Codex** lists "Reduce Motion only applied after relaunch" in its hindsight preview as a named likely failure.

### 1.6 Offscreen / viewport gating is the riskiest mechanism and gets one sentence [3/3]

1. **Claude:** "use scroll viewport intersection for surface tabs" means `GeometryReader` + preference keys or `onGeometryChange` per tab chip, propagating up through the tab bar's scroll view, on the tab bar's render path, during typing. Precisely the class of work `CLAUDE.md` warns about. The plan's assurance that it will not touch `hitTest()` or `forceRefresh()` is true and beside the point.
2. **Codex:** the current tab strip tracks aggregate scroll geometry and selected-tab geometry, not a cheap per-tab visibility fact. "Per-tab GeometryReaders/preferences can become the performance regression the feature is supposed to avoid." Its hindsight preview names "viewport tracking cost more than the animations" as a top-two predicted failure.
3. **Gemini:** frames it as the SwiftUI Environment Trap, where injecting a shared clock via Combine or Environment "can cause unexpected deep tree invalidations that destroy typing latency."

### 1.7 `flagged` / `suppressed` ship as dormant, unreachable, unexercisable code [2/3, Claude + Codex]

1. Nothing in C11-183 sets either field; C11-184 owns the producers and is explicitly out of scope.
2. **Codex:** "The plan currently has the worst combination: it takes on downstream behavior but excludes the means to exercise it." The violet recolor, the flagged-waiting flash, and the priority rule can compile while being visually or behaviorally wrong, then force C11-184 to rewrite them.
3. **Claude:** the first human to ever see the 0.4s alarm flash sees it in production. Counterproposal: a `#if DEBUG` seam or debug-menu toggle forcing a mark's `(state, flagged, suppressed)` tuple. `CLAUDE.md` already blesses the pattern: "If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first."
4. **Codex's structural alternative:** either C11-183 builds only a generic host-neutral presentation seam, or modifier plumbing moves wholesale to C11-184. The current middle ground is "premature abstraction presented as forward compatibility."

### 1.8 The forward-compat seam is not actually end-to-end [2/3, Claude + Codex]

1. **Codex:** adding defaulted modifier parameters only to *internal* `TabActivityMark` gives C11-184 no route from c11 metadata through public `Bonsplit.Tab` / `TabItem` / controller updates / `TabBarView` to the leaf. And adding `flagged`/`suppressed` to bonsplit's *public* models violates the pure-package goal. The plan does not resolve which.
2. **Claude** sharpens it into a fork with opposite consequences: if the fields land on `TabItem` (which is `Codable`, with a legacy-JSON compat test at `BonsplitTests.swift:370-377`), session snapshot round-tripping and that test are in play. If they land as view parameters, they are unreachable from c11's tab data.
3. **Claude** finds the same fork on the c11 side: `WorkspacePulseAgent` (`Sources/Sidebar/SidebarActivityProjector.swift:25`) is a `let`-field `Equatable, Identifiable` struct on the synthesized memberwise init. `let flagged: Bool = false` produces a member with **no init parameter**, so C11-184 cannot set it. `let flagged: Bool` with an explicit defaulted init works but is a different edit. The plan says only "add default-false fields."

### 1.9 Second bonsplit commit, no submodule ceremony [2/3, Claude + Codex]

1. The eight-step sequence (branch, test, commit, push, fetch, ancestry-verify, then pointer) appears only under Phase 1.
2. Phase 2 adds the shared clock to bonsplit: a second commit needing the identical dance and a second pointer bump. The plan never says so.
3. **Claude:** "A delegator following the plan literally does Phase 1's ceremony and then, in Phase 2, edits bonsplit and moves on."
4. **Codex** adds the remote-drift case: if bonsplit `main` advances during implementation, the parent pointer can end up referencing an unpushed or rebased commit. It wants a final fetch/rebase decision, final-HEAD push, and ancestry proof immediately before the parent commit, plus separate provenance so the upstream offer names only the clean commit.

### 1.10 Localization is treated as optional cleanup [2/3, Claude + Codex]

1. `Static marks` is locked user-facing copy: title, subtitle, toggle accessibility label, catalog entry, six translations.
2. The plan declines to touch `Resources/Localizable.xcstrings` and promises "a precise translation-stage note" to the parent.
3. **Codex:** "Leave a note is not a delivery plan." Translation is not optional because the English fallback compiles.
4. **Claude** adds the reason it will rot silently: `ci.yml` `paths-ignore` includes `Resources/Localizable.xcstrings`, so a later translation-only commit runs no CI and nothing will ever nag. A Lattice comment is not a ticket.
5. **Claude** also flags a missed surface: if bonsplit needs new accessibility strings, bonsplit has its own `Bundle.module` localization table (`TabActivityMark`'s neighbors use `localizedString(_:default:)`). Unmentioned.

### 1.11 Tests do not cover the shipping behavior [2/3, Claude + Codex]

1. **Codex** enumerates twelve untested surfaces: fill-step boundaries and hold duration, stable phase offsets for fixed UUIDs, waiting dip endpoints, flagged-waiting replacing rather than stacking the dip, Static marks, Reduce Motion, suppressed working staying static, flag-over-suppression, visible/inactive eligibility, registration cancellation, zero-registration shutdown, and live preference propagation to both renderers.
2. **Claude** puts it more bluntly: "the plan's tests exercise unreachable behavior and skip all reachable behavior." The Phase 4 tests that *will* execute cover suppressed projection, which cannot occur in production until C11-184.
3. **Claude** adds a cross-check: the plan's risk section names five risks (timer proliferation, phase instability, offscreen work, modifier ambiguity, geometry drift), every one of which is checkable in a pure unit test, and Phase 4 covers exactly one, in its unreachable form. "The risk list and the test list were written independently."
4. Both agree this does not require an oversized suite: a small pure policy/phase suite plus one clock-lifecycle test covers most of it.

---

## 2. Unique Concerns

Raised by exactly one model. Ordered by how much investigation they warrant.

### 2.1 Claude only, and verified against the tree

These are the highest-value unique findings because Claude checked them against the actual repository state at `ba1382a6c` / bonsplit `d4ff0e4c`, the pbxproj target membership, and `.github/workflows/ci.yml`.

1. **[BLOCKING, verified] The verification command names a class in the wrong target.** The plan writes mark-sizing tests into `c11Tests/WorkspaceUnitTests.swift`, then verifies with `-scheme c11-logic -only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`. `WorkspaceUnitTests.swift` is a member of **`c11Tests`** (build file `6B524A0BA34FD46A771335AB`, sources phase `F1000005A1B2C3D4E5F60718`), not `c11LogicTests`. `xcodebuild` will error on the `-only-testing` identifier. This is exactly the C11-105 trap documented in `CLAUDE.md`: `SidebarActivityProjectorTests.swift` lives in `c11Tests/` on disk but *is* a `c11LogicTests` member, while `WorkspaceUnitTests.swift` in the same directory is not. The plan lists both paths in one bullet as if equivalent and never names target membership once. **Cheap fix:** `WorkspacePulseMarkRowMetrics` is a pure `enum` of static functions on `CGFloat`; move the metrics tests into a `c11LogicTests`-member file and the plan's own command works.
2. **[BLOCKING, verified] "No PR" means no CI, and CI is the only place the edited tests can run.** `ci.yml` triggers only on push-to-`main` and `pull_request`. Pushing `codex/C11-183-mark-vocabulary` with no PR runs no CI at all. CI is the only place `c11Tests` runs (`ci.yml:219-220`), and the plan forbids running it locally. Combined with 2.1.1, the plan has picked the one arrangement where its tests can run neither locally nor in CI. `CLAUDE.md` at both repo and Stage11 root describes the default as "one delegator per ticket ... producing an open PR"; the plan asserts "no PR" twice with no rationale and no consequence analysis.
3. **[verified] Every submodule command contains an unresolved literal placeholder.** `git -C vendor/bonsplit fetch <stage11-remote>`, `merge-base --is-ancestor HEAD <stage11-remote>/main`. `vendor/bonsplit` has exactly one remote, `origin` = `https://github.com/Stage-11-Agentics/bonsplit.git`. "A plan whose delivery-gate commands are non-executable templates is not an executable plan."
4. **[verified] Four existing assertions encode the *old* compression contract.** `minimumSlot` 8 → 9 makes `stride` go 10 → 11, shifting overflow onset. `c11Tests/WorkspaceUnitTests.swift:2519` `testVeryCrowdedRosterShrinksMarksAndKeepsThemAllVisible` asserts `layout.markSide == min(9, layout.slot)`; `testOverflowingRosterCountsTheRemainder` at count=60 changes its hidden/visible split. The plan presents its new assertions as if the class were empty and never mentions rewriting the old ones. And per 2.1.1/2.1.2, cannot run any of them.
5. **[verified] Phase 1 overstates its scope; Phases 2-3 understate theirs.** `TabActivityMarkMetrics` *already* has `cellSide = 9`, uniform `visibleSize(for:) = 10`, uniform `leadingAccessoryWidth = 18`, and a doc comment already asserting the uniform-slot property. `BonsplitTests.swift:1449-1450` already asserts those values. The uniform-slot work the plan lists is already done in bonsplit. The real bonsplit change is only the `body` shape switch.
6. **[verified, blocks C11-184] The plan declares two binding docs stale and leaves them stale.** The plan's own precedence section says the operator clarification "overrides stale flagged-motion prose in the prompt **and docs**" and "there is no separate breathe animation." Breathe prose is still live in five places in `docs/c11-flagged-agent-plan.md` (lines 182, 186, 188, 198, 353) and once in `docs/c11-mark-vocabulary.md` (line 72). C11-184 `depends_on` C11-183 and will plan from that doc. The doc will tell it to implement breathe; C11-183's code will have none. Guaranteed downstream contradiction, roughly ten minutes of doc editing to prevent, explicitly scoped out.
7. **[verified] A documented prior performance decision is being silently reversed.** `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:164-165` currently reads: "Nothing here animates. The mark is drawn once per state change, which keeps continuous per-tab redraw off the tab-bar render path." The originating commit is titled "Agent-state marks: hard cell, **no animation**" (`d4ff0e4`). The plan reverses this invariant and mentions only "keep accessibility comments truthful." Related and unmentioned: bonsplit's `TabItemView` is **not** `.equatable()`-gated (only c11's is, `ContentView.swift:8725`) and already carries 11 `@State` properties, so the leaf-isolation argument is doing more work on the bonsplit side, and the plan's risk section addresses only the c11 side.
8. **[verified] Theming: light theme is never considered, and a hardcoded color bypasses the theme architecture.** `Sources/Workspace.swift:5663` `resolvedSurfaceTabActivityColors(from:)` returns a distinct light set (`runningHex "#1D2024"`, `waitingHex "#9B7415"`). The plan and spec discuss only dark values. The 25%-opacity base square becomes a mid-grey wash behind dark dots on light backgrounds, and that square is precisely the element the spec says prevents a partially-filled working mark from being misread. Separately, flagged violet `#9D8AD9` is a hardcoded literal in a subsystem that is otherwise entirely theme-resolved through `BonsplitConfiguration.Appearance.TabActivityColors`, and would be the first such color. The plan does not say so.
9. **1x display legibility is unaddressed, and it is the ticket's premise.** On a non-Retina external monitor, the working grid is 2px dots on 3px pitch with a 0.5px inset, and the waiting/idle discrimination is a 2px vs 1px stroke. "A shape-carries-state vocabulary that turns to mush on a 1x external monitor has failed its own premise. Nobody has checked."
10. **The greyscale claim, which is the ticket's entire premise, is never verified.** Ticket "Done when": "All four states distinguishable in greyscale." No greyscale check, no screenshot, no test. The change exists *because* a doc comment made a false accessibility claim (`TabItemView.swift:162`). Shipping the fix with the claim unverified repeats the original sin at one remove.
11. **Aggregate motion at fleet scale may invert the stated motion hierarchy.** The spec's justification ("the fastest-moving thing is always the agent that needs the operator") is a **per-mark** argument. At 20 agents / 40+ leaves you get ~20 staggered 2.5 Hz tickers against one or two smooth dips. Aggregate peripheral motion plausibly dominates. The hierarchy the design rests on may invert at exactly the scale the product exists for, and the only shipped remedy is a global on/off.
12. **Nothing ties the "working" fill to actual work.** The mark reads as telemetry (a cell filling with typed output) but is driven by a free-running clock. A hung agent stuck in `working` ticks merrily forever. Today's static square is honest about being a state indicator. "This is a product regression hiding inside an accessibility fix," and no reviewer in the chain is positioned to catch it because the plan makes no visual claims.
13. **Working-fill restart/resume on state transition is unspecified and user-visible.** working → waiting → working: does the fill resume at global clock phase (visible jump) or restart at zero? The plan's "leaves own only their local rendered phase/state" implies global derivation, implies a jump on every re-entry, and reads as a bug.
14. **No rollback story for the bonsplit `main` push.** Two commits go directly to `Stage-11-Agentics/bonsplit` `main`, unreviewed, before any parent-repo review exists (and with no parent PR, possibly before any review at all). Submodule `main` is not rewindable without force-pushing a shared branch; the remedy is a revert commit plus a pointer bump. The `merge-base --is-ancestor origin/main` invariant in `CLAUDE.md` is what forces main rather than a branch. Worth stating the irreversibility out loud.
15. **Phase ordering puts the irreversible step first.** Shapes are pushed to bonsplit main before anyone has seen the geometry rendered anywhere. Inverting (build both renderers, look at them, *then* split and push) costs nothing and keeps the irreversible step last.
16. **Registration leaks are silent by construction.** A leaf that fails to unregister on disappear is invisible until it shows up as an unexplained battery report. "The plan should require a debug counter of live clock registrations, which is three lines and turns an invisible leak into an observable number."
17. **Nobody has opened the mock.** `scratchpad/mark-vocabulary-candidates.html` is listed as binding input #3, "the live geometry and timing reference," and no step in the plan opens it, compares against it, or uses it as an acceptance reference.
18. **The local-`xcodebuild` assumption is contested and load-bearing.** `CLAUDE.md` says `c11-logic` is safe locally, but a recorded operator correction from C11-181 says defer **all** local c11 `xcodebuild` (any scheme, including `c11-logic`) to CI during delegator/headless runs. The plan's entire local evidence chain is two `xcodebuild` invocations. If the standing preference holds, the plan has no evidence chain and no PR to get CI.

### 2.2 Codex only

1. **"Collapsed pane" is ambiguous and the plan treats it as one thing.** Bonsplit has a responsive collapsed/narrow tab-strip tier with visible dropdown rows, which is a different thing from an actually collapsed split pane. The plan must distinguish them and state whether visible dropdown marks animate.
2. **The 4-second phase table is not deterministic as written.** "Nine dots over the 4-second cycle, then a full hold and hard reset" does not say how much of the four seconds is fill versus hold. The binding spec and prototype describe roughly 3.6s of fill within a 4s cycle. Boundary behavior must be exact, phase 0 and phase wrap included, or the two renderers will disagree numerically even if they share constant names.
3. **One timer is not the same as coalesced work.** Arbitrary UUID-derived offsets scatter deadlines; a single timer that wakes for every unique subscriber deadline is one timer object with N wakeups. The plan needs a quantized beat model or an explicit next-deadline scheduler, and tests for it. Codex's hindsight preview leads with exactly this failure: "the shared clock was technically singular but still expensive."
4. **The plan misses one of the binding vocabulary's own rules.** The vocabulary says suppressed unflagged working marks render a **static full grid**. The plan mentions only suppressed-waiting-becomes-idle. It never says the animation policy rejects `suppressed && !flagged`, so a future suppressed working agent will still animate.
5. **"Flagged working bypasses Static marks" is an unconfirmed product decision, not an inherited fact.** The operator said flagged non-waiting marks use "normal lifecycle motion." That can equally mean Static marks *does* disable it while flagged-waiting remains the exceptional flash. The plan picked one reading from partially-superseded flag-tier prose. This needs an operator answer. (Claude reaches an adjacent observation from the opposite direction in its B1: the plan's chosen rule means an operator who enables "Static marks" still sees motion, which makes the label say something false, and Claude notes the resulting behavior "was not designed, it fell out.")
6. **There is no canonical presentation-policy function.** The rules are scattered between projector prose and renderer prose. Codex proposes one pure decision surface deriving `effectiveState`, `effectiveColor`, `motionChannel`, `isEligible` from `(rawState, flagged, suppressed, staticMarks, reduceMotion, visible, appActive)`. This is also the cheapest thing to unit-test, and it would close most of the gap in 1.11.
7. **No fresh-worktree provisioning evidence.** The plan cites the provisioning rules but records no submodule init and no `GhosttyKit.xcframework` symlink check before the first Xcode build. Since implementation runs in an isolated worktree, this should be a concrete baseline check.
8. **Bonsplit `main` advancing mid-implementation is unhandled.** Static commit based on `d4ff0e4c`, Phase 2 adds more, another change lands remotely: the first push may succeed, the second is unspecified, and the parent pointer can reference an unpushed or rebased commit.
9. **Sunk-cost warning.** "If the implementation is already underway, sunk-cost pressure is now a risk. The static geometry work should not be used to wave through an unresolved animation architecture."

### 2.3 Gemini only

1. **Layout overflow when the row genuinely runs out of width is completely unaddressed.** `minimumSlot` becomes 9pt and yields width instead of shrinking. What happens when there is no width left to yield? Does the title truncate, do marks clip, does the row wrap? This is the direct product consequence of the change Claude analyzed only from the test-assertion side, and neither of the other two reviewers asked it.
2. **Non-key-window CPU wakeups.** The plan gates on "app is active." What about c11 visible on a secondary monitor while the user types in another app? Is the CPU waking at 2.5 Hz to draw dots for 20 agents nobody is looking at? "App active" and "app visible" and "app key" are three different predicates and the plan names one.
3. **Phase-offset computation cost.** Deriving phase from UUID bytes with an explicit stable algorithm is correct for stability, but if that derivation runs per-beat per-mark it is pure overhead. It must be cached at initialization.
4. **The 0.4s flash may be hostile at fleet scale.** A 2.5 Hz hard violet/white square wave is technically under the 3 Hz seizure threshold, but multiple stalled agents strobing indefinitely could be visually exhausting. Nobody has weighed the multi-agent case of the alarm state. (Note this compounds with Claude's 2.1.12: nobody will ever see this render before production.)
5. **Dead-code disposition after a ladder application.** If the fill fails the gate and we fall back to dip-only, is the dot-fill implementation removed or left in the repo as dead weight? Gemini is the only reviewer that asks what the *repository* looks like after the ladder is applied.

---

## 3. Assumption Audit (merged and deduplicated)

Merged from all three reviewers. Verification status reflects Claude's tree checks where available. Reviewer attribution in brackets.

### 3.1 Assumptions that are false or defective as written

1. **"The plan's verification commands are executable."** FALSE, verified two ways: the `-only-testing` identifier names a class in the wrong target, and every submodule command contains the literal placeholder `<stage11-remote>` where the single remote is `origin`. [Claude]
2. **"`c11Tests/` directory membership implies `c11Tests` target membership."** FALSE, verified. This is the exact ambiguity that produced C11-105 and unlinked the operator's production socket. The plan lists files from both targets in one bullet and never names membership. [Claude]
3. **"Bonsplit metrics need updating for uniform slotting."** MOSTLY FALSE, verified: `cellSide = 9`, uniform `visibleSize = 10`, uniform `leadingAccessoryWidth = 18` already exist, with a doc comment already asserting the property, and `BonsplitTests.swift:1449-1450` already asserting the values. [Claude]
4. **"There is a single unambiguous meaning of 'collapsed pane'."** FALSE: split-pane collapse and the responsive narrow tab-strip tier are different states with different mark visibility. [Codex]
5. **"The plan's timing language maps to one deterministic phase function."** FALSE: fill-vs-hold split within the 4s cycle is unstated; spec and prototype imply ~3.6s fill. [Codex]

### 3.2 Load-bearing and at material risk

6. **"The shared clock is a generic renderer primitive, so the Bonsplit change stays upstream-clean."** All three reviewers rate this low-to-weak. Gemini: "Likelihood to hold: Low. A generic tab bar library does not naturally need a staggered, UUID-hashed, application-wide animation clock." Claude: asserted, not argued, and it is a definitional move. Codex: it makes every embedder inherit scheduling behavior. [3/3]
7. **"Leaf isolation prevents parent invalidation."** Gemini rates Medium: "If the shared clock is implemented via an `@Observable` or `ObservableObject` that the leaf subscribes to, it is very easy to accidentally trigger layout passes in the parent." Codex names the specific hazards: `@AppStorage` in outer rows, high-frequency global observables, per-tab geometry preferences invalidating `TabBarView`. Claude notes bonsplit's `TabItemView` is not `.equatable()`-gated at all. [3/3]
8. **"The Static marks preference reaches both renderers live."** Codex rates low: the only concrete storage work is an `@AppStorage` in `Sources/c11App.swift`; no Bonsplit configuration field, Workspace observer, ContentView source, or public environment key is named, and the repo already has explicit Workspace-to-Bonsplit live-update patterns the plan ignores. [Codex]
9. **"Reduce Motion is a value the code can just read."** Uncertain-to-false. Requires `accessibilityDisplayOptionsDidChangeNotification`, a single observation owner at app scope, and a subscription update path. Zero prior art in the repo. [Claude + Codex]
10. **"Scroll viewport intersection can be added cheaply."** Uncertain and high-risk in all three framings. [3/3]
11. **"Stable UUID phase offsets preserve cadence while coalescing work."** Uncertain: one timer object is not one wakeup. Needs a quantized beat model. [Codex]
12. **"`flagged`/`suppressed` as defaulted fields is a trivial additive change."** Unspecified on both sides of the boundary, with opposite consequences per branch (bonsplit `TabItem` Codable + legacy compat test vs view parameters; `let x: Bool = false` with no init parameter vs `let x: Bool` with a defaulted init). [Claude + Codex]
13. **"Running `xcodebuild` locally is fine."** Contested by a recorded operator correction (C11-181). The plan's whole evidence chain rests on it. [Claude]
14. **"Colors are untouched, so theming is out of scope."** Half-true and dangerous: mark colors are theme-resolved per workspace background, only dark values were considered, and the plan introduces the subsystem's first hardcoded non-theme-resolved color. [Claude]
15. **"A fresh validator can reproduce fleet state without a harness or recipe."** Low: no setup, fixture, snapshot, or manual fleet-construction recipe is named anywhere. [Codex]
16. **"Deferring translations is harmless."** Low: six locales are a shipping contract, and CI's `paths-ignore` guarantees nothing will ever nag. [Claude + Codex]
17. **"The final Bonsplit submodule commit is reachable from remote `main`."** Only if the final check happens to catch a missing step; Phase 2's push is never specified. [Claude + Codex]

### 3.3 Load-bearing and probably fine (verified)

18. Bonsplit is a SwiftPM package with `swift test --package-path vendor/bonsplit` viable (`Package.swift` present, 78 tests). [Claude]
19. `ContentView.swift` already imports Bonsplit (line 2), so a Bonsplit-owned public clock is at least reachable from the sidebar. [Claude]
20. The c11 `TabItemView: View, Equatable` + `.equatable()` contract is real (`ContentView.swift:11546`, `:11552`, `:11555`, call site `:8725`) and the plan correctly refuses to touch it. [Claude]
21. Submodule push-before-pointer ordering matches `CLAUDE.md`. [Claude]
22. Opacity tweens are cheap relative to structural shape changes, so the plan's read that the dip is cheap and the fill expensive is likely right. Gemini rates this High confidence. [Gemini]

### 3.4 Invisible assumptions the plan never states at all

23. That a 2pt dot on 3pt pitch with a 0.5pt inset, and a 1.5pt vs 1pt stroke discrimination, render legibly at 1x. No pixel-snapping, non-Retina, or anti-aliasing consideration anywhere. [Claude, echoed as a secondary by Codex]
24. That phase offsets are stable across session restore, and that this means a given agent animates at the same phase forever (mild aesthetic determinism nobody weighed). [Claude]
25. That the working-fill restart/resume semantics on state transition are obvious. They are not, and the implied answer is a visible jump. [Claude]
26. That summary-row and footer-row mark duplicates do not materially change the fleet count in the gate's workload model. [Codex]
27. That the first two summary agents animating *in addition to* the full footer roster does not change the workload model. [Codex]
28. That base commit `ba1382a6c` remains an acceptable integration base while `origin/main` moves. [Codex]
29. That directly advancing `Stage-11-Agentics/bonsplit` `main` before parent review is acceptable, for both commits. [Claude + Codex]
30. That "app active" is the right gate, as opposed to "app visible" or "app key," on multi-monitor setups. [Gemini]
31. That the UUID→phase derivation is cached rather than recomputed per beat. [Gemini]
32. That the 9pt floor always has width available to take. [Gemini]

---

## 4. The Uncomfortable Truths

Ordered by how many reviewers landed on them. These are the messages the plan author is least likely to want and most likely to need.

### 4.1 Recurring across all three reviewers

1. **The "upstream-clean Bonsplit fix" is a fiction, and the plan uses the phrase to justify the decision that makes upstreaming hardest.** Gemini states it flatly: "We are shoving c11-specific animation logic and UUID-phase staggering into a tab bar library to satisfy our own architectural constraints." Claude: "Saying the shared clock is a generic renderer primitive is a definitional move, not an argument. The ticket said pure shape vocabulary. A registration-token animation clock is not shape vocabulary by any reading." Codex: "The pure upstream patch was rejected as product-specific. It bundled default-on animation, flags, suppression, and scheduler ownership with the accessibility shapes."
2. **The plan is precise where the work is easy and vague where the ticket is dangerous.** Codex says it directly: "detailed where the work is easy: shape dimensions, filenames, and git commands; and vague where the ticket is dangerous: scheduler design, viewport cost, live policy propagation, and empirical latency." Claude's version: the riskiest mechanism in the ticket (offscreen gating) gets one sentence. Gemini's version: the plan "vastly underestimates the SwiftUI invalidation risks."
3. **"Later fresh validation" is functioning as a place to hide missing acceptance design.** Codex names it in exactly those words. Claude names the rhetorical mechanism: "This implementation stage records only what it actually ran and makes no visual or typing-latency claims" is "a well-crafted disclaimer that converts a total absence of evidence into an apparent methodological virtue. On a ticket whose deliverable is what four 9-pixel shapes look like, it is not a virtue."

### 4.2 Recurring across two reviewers

4. **The most complex thing in the plan has a serious chance of never shipping.** Gemini: "We are building a highly complex, 4-second staggered typewriter animation that has a very high chance of being disabled by the latency fallback ladder before it even ships." Claude reaches the same place from the ladder's absence: if validation fails, the only options are killing the animation outright or reopening a ticket that has already made irreversible submodule commits.
5. **The forward-compat seam is premature abstraction wearing forward-compat's clothes.** Codex: "not actually end-to-end and not cleanly upstreamable." Claude: the fields ship "defaulted-false with no producer," and if C11-184 slips or changes shape this is dead code plus an unexercised alarm-flash render path nobody has ever seen run.
6. **Avoiding an oversized test suite is sensible; omitting focused tests for presentation policy and scheduler lifecycle is not.** Codex states it; Claude's corollary is sharper: "the only new behavior the plan actually tests is behavior that cannot happen."
7. **The operator's clarification was about scope, and the plan used it as cover for something broader.** Claude: "Skip a dedicated QA/performance harness and avoid an oversized test suite" became "no tagged build, no screenshot, no greyscale check, no animation test, no gating test, no clock test," while the clarification's own trailing clause said "perform proportionate tagged-build validation," and that clause is the one thing the plan did not carry into its precedence list. Codex: "No dedicated harness does not mean no defined validation."

### 4.3 Raised once, but hard

8. **This plan cannot prove it works, and everyone is treating that as acceptable because the sentence is written confidently.** [Claude]
9. **One timer object is not one unit of work.** "The plan cannot claim one shared clock merely because there is one timer object. Main-thread fan-out and wakeup frequency are the costs that matter." [Codex]
10. **Motion that reads as liveness but measures nothing is a product regression hiding inside an accessibility fix.** A hung agent animates forever. Today's static square is honest. [Claude]
11. **Nobody in this chain has looked at the mock,** despite it being named binding input #3 and "the live geometry and timing reference." [Claude]
12. **Default-on motion may train users to disable the feature or ignore the sidebar.** "We will also realize that default-on motion for background terminal processes trains users to either turn on Static marks immediately or ignore the UI entirely because it's too busy." [Gemini] Claude's independent version: at 20 agents the aggregate of staggered tickers may drown the two dips the whole hierarchy is built on.
13. **Sunk cost is now an active risk if implementation has started.** The clean static-geometry work must not be used to wave through the unresolved animation architecture. [Codex]
14. **A capitalized HARD SHIP BLOCKER currently has no pass criterion anywhere in the chain.** Not in the ticket, not in the plan, not in the handoff. [Claude + Codex]

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews, grouped, and ordered so that blocking, cheap-to-fix defects come first. Reviewer attribution in brackets. 34 questions.

### A. Blocking defects in the plan's own executable content (fix before anything else)

1. `WorkspaceUnitTests.swift` is a member of the **`c11Tests`** target, not `c11LogicTests`, yet your verification command is `-scheme c11-logic -only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`. Did you check target membership, or infer it from the directory name? What is the correction: move the metrics tests into a `c11LogicTests`-member file, or accept that the 9pt sizing change ships unrun? [Claude]
2. CI triggers only on push-to-`main` and `pull_request`. With "no PR in the parent repository," **name the mechanism that runs any test at any point before this merges.** [Claude]
3. What authorizes "no PR," given `CLAUDE.md`'s stated default of one delegator per ticket producing an open PR, and was the CI consequence in Q2 weighed when that was decided? [Claude]
4. Every submodule command contains the literal placeholder `<stage11-remote>`; `vendor/bonsplit` has exactly one remote, `origin`. Is this plan intended to be executed, or read? [Claude]
5. Four existing assertions in `WorkspacePulseMarkRowMetricsTests` (`WorkspaceUnitTests.swift:2519-2529`) encode the *old* compress-to-8pt contract, including `XCTAssertEqual(layout.markSide, min(9, layout.slot))`. Which of them change, and how do you verify them given Q1 and Q2? [Claude]
6. `TabActivityMarkMetrics` already has `cellSide = 9`, uniform `visibleSize = 10`, and uniform `leadingAccessoryWidth = 18`, with a comment already asserting the uniform-slot property, and `BonsplitTests.swift:1449-1450` already asserting the values. What specifically changes in `TabActivityMarkMetrics`, and does that test need to change at all? [Claude]
7. What worktree provisioning evidence confirms both submodules and the `GhosttyKit.xcframework` symlink were ready before the first Xcode build? [Codex]

### B. The animation architecture (the top consensus challenge)

8. Justify the shared clock living in bonsplit rather than in c11 with a `phase` parameter passed in. The ticket said "PURE SHAPE VOCABULARY with no c11-specific concepts, a clean accessibility fix to offer upstream." **Would you accept an app-lifetime registration-token timer into a third-party tab-bar library you maintained?** [Claude + Codex + Gemini, all three]
9. What concrete API makes the scheduler **one per app** rather than one per Bonsplit controller, workspace, renderer, or generic specialization? Name the owning type, whether callbacks are `@MainActor`, whether the primitive is a `Timer` or a dispatch source, how registrations are weakly held and cancelled, and how the clock stops at zero eligible leaves. [Codex]
10. How exactly does Bonsplit compute a UUID-based phase offset without importing c11's `WorkspacePulseAgent` or metadata concepts? [Gemini]
11. How are arbitrary UUID offsets **quantized** so one timer coalesces work rather than waking once per leaf deadline? One timer object is not one wakeup. [Codex]
12. Is the UUID→phase derivation cached at initialization, or recomputed per beat per mark? [Gemini]
13. What proves the clock stops with zero eligible leaves and while the app is inactive, and what prevents stale or deallocated leaf registrations from receiving ticks? [Codex]
14. Will you expose a live-registration count (three lines, debug-only) so a leaked leaf is an observable number rather than an unexplained battery report? [Claude]
15. Does the shared timer pause when c11 is visible on a secondary monitor but is not the key window? "App active," "app visible," and "app key" are three different predicates and the plan names one. [Gemini]
16. What is the exact 4-second phase table: when does each of the nine dots appear, how long is the full hold, and what happens at phase 0 and at wrap? The spec and prototype imply ~3.6s fill; the plan's prose does not say. [Codex]
17. When a surface goes working → waiting → working, does the fill resume at global clock phase (visible jump) or restart at zero? This is user-visible and unspecified. [Claude]

### C. Policy propagation and gating

18. Who owns the truth for Static marks, app-active, and Reduce Motion, and how does each **live** change reach both existing Bonsplit controllers and c11 leaves? The plan names only an `@AppStorage` in `Sources/c11App.swift`. [Codex]
19. Where is Reduce Motion read, where is `accessibilityDisplayOptionsDidChangeNotification` observed, and at what scope? There is zero prior art in the repo, and per-leaf observation reintroduces the N-observers problem your own risk section forbids for timers. [Claude + Codex]
20. What does "scroll viewport intersection" mean in code, and how does it avoid per-tab geometry preference churn invalidating `TabBarView` during scroll, resize, drag, and title changes? This is one sentence of plan for the riskiest mechanism in the ticket. [Claude + Codex + Gemini]
21. Does "collapsed pane" mean an actually collapsed split pane, Bonsplit's responsive narrow tab-strip tier, a closed dropdown, or all three? What happens to marks in an *open* collapsed-layout dropdown? [Codex]

### D. The latency gate and the ladder

22. **What exact tagged-build fleet scenario, typing workload, baseline build, measurement source, and numeric threshold decides whether C11-183 passes?** "Belongs to the fresh validation stage" names a stage, not an owner or a number. If the answer is "we don't know," say so, because a HARD SHIP BLOCKER currently has no pass criterion anywhere in the chain. [Claude + Codex]
23. How will the validator independently measure **fill-only** and **dip-only** to apply the required ladder, given the plan ships no independently controllable switches? [Codex + Claude]
24. The spec's ladder is the sole mitigation for default-on animation, and the ticket's "Done when" explicitly permits "or the ladder is applied and the outcome recorded." Your plan builds no ladder and ships a boolean that cannot express the middle rung. **If deferred validation finds the fill regresses latency, what is the exact remedy, in code that exists?** [Claude + Codex + Gemini]
25. Should `Static marks` be an enum (`animated` / `attentionOnly` / `static`) instead of a boolean, pre-paying the ladder for the cost of one type? [Claude]
26. If the gate fails because **viewport tracking or scheduler fan-out** is expensive rather than dot drawing, does the ladder still disable fill first, or does the ticket return for architectural repair? [Codex]
27. What is the rework loop after fresh validation fails, given the plan ends the delegator's stage before the only ship-blocking evidence exists? [Codex]
28. At 20 agents the sidebar carries ~20 staggered 2.5 Hz tickers against one or two smooth dips. The spec's motion-hierarchy argument is per-mark. What is your basis for believing it holds in aggregate, at the fleet scale this product exists for? [Claude]

### E. Modifiers, the seam, and C11-184

29. Why are `flagged` and `suppressed` entering the Bonsplit leaf at all if the Bonsplit change must remain a pure, upstream-clean shape-vocabulary fix? [Codex + Claude]
30. Do `flagged`/`suppressed` land on bonsplit's `TabItem` (which is `Codable` with a legacy-JSON compat test at `BonsplitTests.swift:370-377`) or as `TabActivityMark` view parameters? If the latter, what public, host-neutral path will C11-184 use to carry them through `Bonsplit.Tab`, controller updates, and `TabBarView` without rewriting the seam? [Claude + Codex]
31. Is `WorkspacePulseAgent.flagged` declared as `let flagged: Bool = false` (no init parameter, so C11-184 **cannot** set it) or `let flagged: Bool` with an explicit defaulted init (call sites unchanged, C11-184 can set it)? These have opposite consequences for the plan's central forward-compat promise. [Claude]
32. Where is the rule that suppressed **unflagged working** renders the static full grid even when global motion is on? The binding vocabulary specifies it; the plan mentions only suppressed-waiting-becomes-idle. [Codex]
33. Why does flagged working bypass Static marks? Did the operator explicitly choose that, or was it inherited from flag-tier prose the clarification partially replaced? An operator who enables "Static marks" and still sees motion has been told something false by the label. [Codex + Claude]
34. There is no way to see the flagged violet or the 0.4s alarm flash render, in this ticket or in any tagged build. Will you add a `#if DEBUG` seam to force `(state, flagged, suppressed)`? `CLAUDE.md` already blesses the pattern. If not, the first human to see the alarm flash sees it in production, and nobody has weighed what several agents strobing at 2.5 Hz simultaneously feels like. [Claude + Gemini]

### F. Visual correctness, which is the actual deliverable

35. `resolvedSurfaceTabActivityColors(from:)` returns a distinct **light-theme** palette. Have you rendered the 25%-opacity base square, the 1pt vs 1.5pt frames, and `#9D8AD9` against a light workspace background? If not, what is your basis for believing the vocabulary reads in both themes? [Claude]
36. Where does `#9D8AD9` live, given every other mark color is theme-resolved through `BonsplitConfiguration.Appearance.TabActivityColors`? Is this the subsystem's first hardcoded, non-theme-resolved color, and is that intended? [Claude]
37. At 1x, the working grid is 2px dots on 3px pitch with a 0.5px inset, and waiting-vs-idle is a 2px vs 1px stroke. What is your evidence the four states remain distinguishable there? The ticket's premise is that shape alone carries state. [Claude]
38. The ticket's "Done when" includes "all four states distinguishable in greyscale," and this change exists because a doc comment made a false accessibility claim. Where is the greyscale check? [Claude]
39. The ticket's first "Done when" is "both renderers **agree**." With bonsplit forbidden from importing c11 concepts and c11 unable to import bonsplit `Internal/`, where do the shared geometry constants live, and what executable check demonstrates agreement? "Review the final diff side by side" is not a mechanism. [Claude + Codex]
40. When the mark row yields width to preserve the 9pt floor, **what gets truncated or clipped when the row genuinely runs out of width?** Title truncation, mark clipping, row wrap? [Gemini]
41. The working fill is a free-running clock, not a function of output. A hung agent in `working` animates indefinitely. Is motion-that-reads-as-liveness-but-measures-nothing acceptable, and was it considered? [Claude]
42. `scratchpad/mark-vocabulary-candidates.html` is binding input #3, "the live geometry and timing reference." No step in the plan opens or compares against it. Has anyone on this ticket looked at it? [Claude]

### G. Submodule, docs, and delivery hygiene

43. `TabItemView.swift:164-165` currently reads "Nothing here animates. The mark is drawn once per state change, which keeps continuous per-tab redraw off the tab-bar render path," from a commit titled "Agent-state marks: hard cell, no animation." You are reversing a documented performance invariant. What replaces the guarantee, and where will a reviewer be told the reversal is deliberate? [Claude]
44. Where is the explicit Phase 2 submodule commit / push / ancestry sequence before the parent pointer commit, and is that a second pointer commit or an amend? [Claude + Codex]
45. Which final Bonsplit commits are pushed to Stage-11 `main`, and which exact commit is offered upstream? The upstream offer must name only the clean commit. [Codex]
46. If bonsplit `main` advances during implementation, what is the fetch / rebase-or-merge decision, and where is the final-HEAD ancestry proof taken? [Codex]
47. Both bonsplit commits go to `main`, unreviewed and unrewindable, before any parent-repo review. If review rejects the geometry, what is the rollback, and **why is the irreversible step first rather than last?** [Claude]
48. The plan states the operator clarification "overrides stale flagged-motion prose in the prompt **and docs**," then does not update the docs. `docs/c11-flagged-agent-plan.md` specifies breathe in five places (182, 186, 188, 198, 353) and `docs/c11-mark-vocabulary.md` once (72), and the former is the binding input for C11-184, which `depends_on` this ticket. Why is fixing that prose not in scope, and who fixes it before C11-184 plans? [Claude]
49. Who owns the six-locale translation pass, when does it run, and what evidence prevents C11-183 reaching done with English-only catalog coverage? Note `ci.yml` `paths-ignore` excludes `Resources/Localizable.xcstrings`, so nothing will ever nag. And does the bonsplit side need any new `Bundle.module` strings? [Claude + Codex]
50. If the fill is later disabled by the ladder, is the dot-fill implementation removed from the repo or left as dead weight? [Gemini]

---

## 6. Suggested Minimum Bar Before Execution

Not a reviewer position, but the intersection of what all three would accept. Offered so the author has a concrete target rather than 50 open questions.

1. **Fix the executable defects** (Q1-Q7). Cheap, mechanical, and they currently invalidate the plan's entire evidence chain.
2. **Decide the clock's home** (Q8). All three reviewers want it in c11 with a phase parameter passed into bonsplit. If it stays in bonsplit, the plan needs an argument, not an assertion.
3. **Pre-register the gate** (Q22-Q24). Scenario, baseline, workload, metric, threshold, ladder branch. The delegator does not have to run it; a validator cannot invent it later.
4. **Ship the setting as a three-value enum**, not a boolean (Q25). One type, and the ladder becomes applicable rather than theoretical.
5. **Write one canonical presentation-policy function** and unit-test it (Codex 2.2.6): `(rawState, flagged, suppressed, staticMarks, reduceMotion, visible, appActive)` → `(effectiveState, effectiveColor, motionChannel, isEligible)`. This is pure, cheap, target-safe, and closes most of the 1.11 test gap in one move.
6. **Do one tagged build and take four screenshots** in both themes plus one greyscale conversion (Claude D2). This discharges three of the ticket's five "Done when" bullets for very little cost, and it is what the operator's "perform proportionate tagged-build validation" clause actually asked for.
7. **Spend ten minutes editing the two stale docs** (Q48) so C11-184 does not plan against superseded prose.
8. **Either cut the modifier work to a host-neutral seam, or add the `#if DEBUG` seam that lets someone see it render** (Q29-Q34). The current middle ground satisfies neither reviewer.
