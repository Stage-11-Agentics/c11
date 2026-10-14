# TP-c11-183-plan-Claude-Adversarial-20260728-1327

Adversarial review of `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md` (C11-183, "Rebuild agent-state mark vocabulary: lifecycle in shape alone").

Read against: the Lattice ticket + operator clarification comments, `docs/c11-mark-vocabulary.md`, `docs/c11-flagged-agent-plan.md`, `CLAUDE.md`, and the actual repository state at `ba1382a6c` / bonsplit `d4ff0e4c`.

Every claim below marked "verified" was checked against the tree, the pbxproj target membership, or `.github/workflows/ci.yml`.

---

## Executive Summary

**Concern level: high, and the reason is narrow and fixable.** The visual design in this plan is largely sound and faithful to the spec. The *verification architecture* is broken in a way that means, as written, this plan ships a user-visible, performance-sensitive, accessibility-motivated change with **effectively zero executed test coverage of the thing it actually changes**.

The single biggest issue is a chain of three decisions that compound:

1. The plan writes the mark-sizing tests into `c11Tests/WorkspaceUnitTests.swift` (Phase 4).
2. It then verifies them with `-scheme c11-logic -only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`.
3. It declares "no PR in the parent repository."

**Verified:** `WorkspaceUnitTests.swift` is a member of the **`c11Tests`** target (build file `6B524A0BA34FD46A771335AB`, sources phase `F1000005A1B2C3D4E5F60718` = `c11Tests`), **not** `c11LogicTests`. The class `WorkspacePulseMarkRowMetricsTests` exists today at `c11Tests/WorkspaceUnitTests.swift:2472` and is therefore in the host-bound target. So the plan's own verification command names a test class that does not and will not exist in the target it points at. `xcodebuild` will error on the `-only-testing` identifier, not silently pass.

**Verified:** `.github/workflows/ci.yml` triggers only on `push` to `main` and on `pull_request`. Pushing `codex/C11-183-mark-vocabulary` with no PR runs **no CI at all**. CI is the only place `c11Tests` runs (`ci.yml:219-220`, `-scheme c11-unit -only-testing:c11Tests`), and the plan forbids running it locally.

Net effect: the 9pt slot-floor change, the two-renderer shape rewrite, the shared clock, the offscreen gating, the Reduce Motion override, and the flagged-waiting flash all land with the following as their total evidence: one `xcodebuild build`, and one logic-scheme test invocation that half-fails on a bad identifier. The only tests that *would* execute (`SidebarActivityProjectorTests`, which **is** verified to be in `c11LogicTests` despite living in the `c11Tests/` directory) cover a code path that **cannot occur in production**, because nothing sets `suppressed` until C11-184.

That is the inversion: the plan's tests exercise unreachable behavior and skip all reachable behavior.

Second-biggest issue: the plan explicitly declares the two binding design docs stale on flagged motion, then does not fix them, while C11-184 is a `depends_on` child whose binding input **is** the stale doc. See "Blind Spots."

---

## How Plans Like This Fail

Common failure patterns for "rewrite a small visual primitive with animation, gated on a performance contract":

**1. The perf gate becomes an IOU that nobody redeems.** The ticket calls the typing-latency gate a HARD SHIP BLOCKER in capitals. The operator then said "skip a dedicated QA/performance harness ... perform proportionate tagged-build validation." The plan converted that into: no harness, no measurement, no tagged build, all deferred to "the fresh validation stage," and "This implementation stage records only what it actually ran and makes no visual or typing-latency claims." That is a legitimate reading of the clarification, but it means **nobody in the chain currently owns the measurement**, and the plan does not name who does, when, or against what threshold. Plans that convert a blocker into a downstream handoff without naming the downstream owner and the pass criterion reliably ship the blocker unmeasured.

**2. The degradation ladder is designed but never wired.** The spec's ladder (fill fails → dip-only default; dip fails → static default; flag motion fails → static violet) is the *entire* risk mitigation for a default-on animation. The plan reproduces none of it. There is no mechanism, no flag, no constant, no code path to degrade. If the deferred validation stage finds the fill regresses typing latency, the only lever that exists is the binary `Static marks` user setting, which is the wrong lever (it changes the default for everyone or nobody, and it cannot express "dip yes, fill no"). The ticket's "Done when" explicitly allows "**or the ladder is applied and the outcome recorded**" as an escape hatch. The plan removes the escape hatch by not building the ladder. This is the classic shape: mitigation designed in the spec, dropped in the plan because it looks like scope, missed until the gate fails.

**3. Two renderers drift.** Two independent implementations of the same 9pt geometry (bonsplit `TabActivityMark` and c11 `workspacePulseMark`) with a mitigation of "use the same named geometry constants/order in both renderers and review the final diff side by side." Side-by-side diff review is not a mechanism; it is a hope. There is no shared constant source (bonsplit must stay c11-agnostic, c11 cannot reach into bonsplit `Internal/`), and no test asserting the two agree. The ticket's first "Done when" is literally "Both renderers draw the new set and **agree**" and the plan has no way to demonstrate agreement.

**4. The vendored-fork purity constraint quietly dies.** See "Challenged Decisions."

**5. Forward-compat fields become permanently dead.** `flagged`/`suppressed` ship defaulted-false with no producer. If C11-184 slips or changes shape, this is dead code plus an unexercised alarm-flash render path that nobody has ever seen run.

---

## Assumption Audit

### Load-bearing, and at risk

**A1. "The plan's verification commands are executable."**
FALSE, verified. Two separate defects:
- `-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests` names a class that lives in the `c11Tests` target.
- Every submodule command uses an unresolved literal placeholder `<stage11-remote>`: `git -C vendor/bonsplit fetch <stage11-remote>`, `merge-base --is-ancestor HEAD <stage11-remote>/main`. **Verified:** `vendor/bonsplit` has exactly one remote, `origin` = `https://github.com/Stage-11-Agentics/bonsplit.git`. The placeholder should just be `origin`. A plan whose delivery-gate commands are non-executable templates is not an executable plan.

**A2. "`c11Tests/` directory membership implies `c11Tests` target membership."**
FALSE, verified, and this is exactly the trap that produced C11-105 (documented in `CLAUDE.md`: `TerminalControllerSocketSecurityTests.swift` was "a member of the `c11LogicTests` target (despite living in `c11Tests/` on disk)" and unlinked the operator's production socket). `SidebarActivityProjectorTests.swift` lives in `c11Tests/` on disk and is a member of `c11LogicTests`. `WorkspaceUnitTests.swift` lives in the same directory and is a member of `c11Tests`. The plan writes both file paths in the same bullet list as if they were equivalent. The repo has already been burned once by exactly this ambiguity and the plan does not name target membership even once.

**A3. "Running `xcodebuild` locally is fine."**
Contested. `CLAUDE.md` says `c11-logic` is "safe to run locally." An operator correction recorded from C11-181 says to defer **all** local c11 `xcodebuild` (build and test, any scheme including `c11-logic`) to CI during delegator/headless runs, because the operator interrupted a `c11-logic` test run. The plan's entire local evidence chain is two `xcodebuild` invocations. If the operator's standing preference holds, the plan has no evidence chain at all, and it has no PR to get CI. This assumption is load-bearing and the plan does not know it is contested.

**A4. "A shared animation clock is a generic renderer primitive, so the Bonsplit change remains upstream-clean."**
Weak. This is asserted, not argued. An app-lifetime singleton timer with registration tokens, app-active gating, Reduce Motion gating, and scroll-viewport intersection tracking is application infrastructure, not a tab-bar component's business. The ticket's instruction was explicit and narrower: "Keep this change PURE SHAPE VOCABULARY with no c11-specific concepts: it is a clean accessibility fix to offer upstream." The clock is not shape vocabulary. Whether or not it is "c11-specific," it materially reduces the odds that an upstream maintainer takes the patch, which is the stated point of the constraint.

**A5. "Bonsplit metrics need updating."**
Mostly false, verified. `TabActivityMarkMetrics` today already has `cellSide = 9`, `visibleSize(for:) = 10` for all states, and `leadingAccessoryWidth = 18` for all states, with a doc comment that already says "Every state occupies the same slot, so a tab's title never shifts horizontally." The uniform-slot property the plan lists as work is **already true in bonsplit**. `BonsplitTests.swift:1449-1450` asserts exactly those values. The real bonsplit change is only the `body` shape switch (plus the 25%-opacity base square, the 3x3 dot grid, the 1.5pt/1pt frames). Phase 1 overstates its scope; Phases 2 and 3 understate theirs.

**A6. "Reduce Motion is a gate the code can just read."**
Verified there is **zero prior art**: `grep` for `accessibilityDisplayShouldReduceMotion` / `reduceMotion` / `ReduceMotion` across `Sources/` and `vendor/bonsplit/Sources/` returns nothing. The plan never says where the observer lives, that `NSWorkspace.shared.notificationCenter` `accessibilityDisplayOptionsDidChangeNotification` must be observed for live toggling, or that it must be observed at app scope rather than per-leaf (per-leaf observation is N observers, reintroducing exactly the proliferation the plan forbids for timers). "Reduce Motion is a hard override" is stated four times and specified zero times.

**A7. "Colors are untouched, so theming is not in scope."**
Half-true and dangerous. Verified: `Sources/Workspace.swift:5663` `resolvedSurfaceTabActivityColors(from backgroundColor:)` returns a **light-theme** set (`runningHex "#1D2024"`, `waitingHex "#9B7415"`) and a dark set. The mark colors are theme-resolved per workspace background. The plan and the spec discuss only dark-theme values. Two consequences the plan never considers:
- The working mark's new "full 9pt square at **25% opacity**" base. On a light background with a near-black `#1D2024` at 25%, this is a mid-grey wash behind dark dots. Legibility unverified in either theme, and it is the element the spec says prevents a partially-filled working mark from being misread.
- Flagged violet `#9D8AD9` is a **hardcoded literal** in a subsystem that is otherwise entirely theme-resolved. On a light workspace background, a light violet is low-contrast. The plan introduces a color that bypasses the theme architecture and does not say so.

**A8. "`flagged`/`suppressed` as fields is a trivial additive change."**
Unspecified where they live on the bonsplit side. `TabItem` is `Codable` and its `activityState` is persisted, with a legacy-JSON compatibility test at `BonsplitTests.swift:370-377` asserting the key is absent from legacy payloads. If the modifier inputs land on `TabItem`, session-snapshot round-tripping and that compat test are in play. If they land as view parameters on `TabActivityMark`, they are unreachable from c11's tab data and the c11 side has no way to feed them. The plan says "expose modifier inputs with defaults" without resolving which, and the answer determines whether the seam is actually usable by C11-184.

`WorkspacePulseAgent` (verified, `Sources/Sidebar/SidebarActivityProjector.swift:25`) is a `let`-field `Equatable, Identifiable` struct relying on the synthesized memberwise init. Adding `let flagged: Bool = false` produces a member with no init parameter; adding `let flagged: Bool` breaks every construction site. The plan says "add default-false fields" without naming which form, and the two forms have opposite consequences for the "C11-184 can wire the fields without rewriting shape code" promise.

### Load-bearing and probably fine

- Bonsplit is a SwiftPM package with `swift test --package-path vendor/bonsplit` viable (verified: `Package.swift` present, 78 tests).
- `ContentView.swift` already `import Bonsplit` (verified line 2), so a Bonsplit-owned public clock is at least *reachable* from the sidebar.
- The c11 `TabItemView: View, Equatable` + `.equatable()` contract is real (verified `ContentView.swift:11546`, `:11552`, `:11555`, call site `:8725`) and the plan correctly refuses to touch it.
- Submodule push-before-pointer ordering matches `CLAUDE.md`.

### Invisible assumptions the plan never states

- That a 2pt dot on 3pt pitch with 0.5pt inset renders legibly. **On a 1x display this is a 2px dot on 3px pitch with a half-pixel inset.** Nothing in the plan or the spec addresses pixel snapping, non-Retina, or anti-aliasing. A shape-carries-state vocabulary that turns to mush on a 1x external monitor has failed its own premise. Nobody has checked. Same for 1.5pt vs 1pt stroke discrimination at 9pt: at 1x that is 2px vs 1px, and the "heavier frame = higher priority" reading is the *only* thing distinguishing waiting-frame from idle-frame besides the core.
- That the shared clock's phase offset is stable across app restarts. The plan says "derive phase from UUID bytes with an explicit stable algorithm, never Swift `Hasher`," which is correct, but does not say the offsets must also be stable across a *session restore* where surface UUIDs persist. They will be, which is good, but it also means a given agent always animates at the same phase forever, which is a mild aesthetic determinism nobody weighed.
- That the working fill restart/resume semantics on state transition are obvious. They are not. When a surface goes working → waiting → working, does the fill resume at global clock phase (appearing to jump) or restart from zero? The plan says leaves own "only its local rendered phase/state, not a timer," which implies global-phase derivation, which implies a visible jump on every re-entry to working. Unspecified, user-visible, and the kind of thing that reads as a bug.

---

## Blind Spots

### B1. The plan declares two binding docs stale and leaves them stale, while the child ticket reads them

The plan's own precedence section says the operator clarification "overrides stale flagged-motion prose in the prompt **and docs**" and "there is no separate breathe animation."

**Verified, the "breathe" prose is still live in five places in `docs/c11-flagged-agent-plan.md`** (lines 182, 186, 188, 198, 353) and once in `docs/c11-mark-vocabulary.md` (line 72: "For the other flagged combinations ... the mark breathes as the flagged-agent plan specifies"). The plan's non-goals list does not include updating either doc, and its file lists do not touch them.

C11-184 (`task_01KYMTXQVWCXCF0TGN5ZWG341E`, verified `depends_on` C11-183) will be planned from `docs/c11-flagged-agent-plan.md`. That doc will tell it to implement breathe. C11-183's code will have no breathe. This is a guaranteed downstream contradiction, and the fix costs about ten minutes of doc editing that this plan explicitly scopes out.

Worse, removing breathe collapses the flagged tier's stated three-step escalation ("static violet says a flag is up, breathe says a flag is up on a live agent, the flash says the agent is flagged *and stopped*", `c11-flagged-agent-plan.md:188`) into two steps. Nobody has re-derived whether flagged-working is still distinguishable from flagged-idle at a glance under the new rule. Under this plan, flagged working animates (normal fill), flagged idle is still, so they *are* distinguishable, but only because the base motion happens to carry it. That is load-bearing and accidental, and it is now also the reason `Static marks` cannot apply to flagged working (the plan's "flag-tier motion bypasses that setting" rule). An operator who turns on `Static marks` gets a still fleet plus a small number of still-ticking flagged agents, which is arguably a *better* signal than the design intended, but it was not designed, it fell out.

### B2. Aggregate motion at fleet scale inverts the stated motion hierarchy

The spec's justification for default-on motion is: "the fastest-moving thing in the sidebar is always the agent that needs the operator; working ticks along slowly behind it; everything else is still."

That reasoning is **per-mark**. At the fleet scale this product targets (the ticket says 20 agents, 40+ leaves), you have roughly 20 working marks ticking at 2.5 Hz on staggered phases in the sidebar and tab bar, against one or two dipping cores. Aggregate peripheral motion from twenty staggered tickers plausibly dominates two smooth dips. The hierarchy the design is built on may invert at exactly the scale the product is for.

The plan defers all visual validation, so this is discoverable only after ship, and the only remedy shipped is a global on/off.

### B3. Nothing ties the "working" fill to actual work

The mark reads as telemetry ("a cell full of typed output") but is driven by a free-running clock. A hung agent stuck in `working` shows dots ticking merrily forever. Today's static solid square is honest about being a state indicator; an animated typewriter fill implies liveness it does not measure. This is a product regression hiding inside an accessibility fix, and no reviewer in this chain is positioned to catch it because the plan makes no visual claims.

### B4. The greyscale claim, which is the ticket's entire premise, is never verified

Ticket "Done when": "All four states distinguishable in greyscale." The plan has no greyscale check, no screenshot, no test, and defers to a validation stage without specifying that the greyscale check is part of it. The change exists *because* a doc comment made a false accessibility claim (`TabItemView.swift:162`, verified). Shipping the fix with the claim again unverified repeats the original sin at one remove.

### B5. The prior performance decision being reversed is not acknowledged

**Verified**, `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:164-165`:

> `/// Nothing here animates. The mark is drawn once per state change, which keeps`
> `/// continuous per-tab redraw off the tab-bar render path.`

That is a deliberate, documented, prior performance decision, and the bonsplit commit it came from is literally titled "Agent-state marks: hard cell, **no animation**" (verified, `d4ff0e4`). This plan reverses it and mentions only "keep accessibility comments truthful." A reviewer reading the diff should be told, explicitly, that a documented no-animation-on-the-tab-bar-render-path invariant is being deliberately retired and what replaces the guarantee. The plan does not say it.

Also relevant and unmentioned: bonsplit's `TabItemView` is **not** `.equatable()`-gated (verified: only c11's is, at `ContentView.swift:8725`), and already carries 11 `@State` properties. The leaf-isolation argument is therefore doing more work on the bonsplit side than on the c11 side, and the plan's risk section addresses only the c11 side.

### B6. Offscreen gating is the hardest engineering in the plan and gets one sentence

"use scroll viewport intersection for surface tabs rather than assuming SwiftUI pauses offscreen content." In practice this means `GeometryReader` + preference keys or an `onGeometryChange` per tab chip, propagating up through the tab bar's scroll view, on the tab bar's render path, during typing. That is precisely the class of work `CLAUDE.md` warns about. The plan asserts it will not touch `hitTest()` or `forceRefresh()`, which is true and beside the point: layout-preference churn in the tab bar is its own hazard. One sentence of plan for the riskiest mechanism in the ticket.

### B7. No rollback story for the bonsplit main push

The plan pushes two commits directly to `Stage-11-Agentics/bonsplit` `main`, unreviewed, before any parent-repo review exists (and with no parent PR, possibly before any review at all). Submodule `main` is not rewindable without force-pushing a shared branch. If review rejects the shape work, the remedy is a revert commit on bonsplit main plus a pointer bump. The plan does not say this, and the `merge-base --is-ancestor origin/main` invariant in `CLAUDE.md` is what forces main rather than a branch. Worth stating the irreversibility out loud rather than discovering it.

### B8. Phase 2's submodule ceremony is missing

The eight-step submodule sequence (branch, test, commit, push, fetch, ancestry-verify, then pointer) appears only under Phase 1. Phase 2 adds the shared clock to bonsplit, which is a second bonsplit commit needing the identical dance and a second pointer bump. The plan never says so. A delegator following the plan literally does Phase 1's ceremony and then, in Phase 2, edits bonsplit and moves on.

### B9. Localization loose end with no owner

The plan adds a `Static marks` `SettingsCardRow` in English only, declines to touch `Resources/Localizable.xcstrings`, and promises to "leave the parent a precise translation-stage note." A note in a Lattice comment is not a ticket. `CLAUDE.md` requires a translation pass and describes delegating it to a sub-agent. Note also that `ci.yml` `paths-ignore` includes `Resources/Localizable.xcstrings`, so a later translation-only commit runs no CI, which is fine, but it also means nothing will ever remind anyone. This will sit untranslated for six locales indefinitely unless a ticket exists.

Separately: if the bonsplit side needs any new accessibility strings, bonsplit has its own `Bundle.module` localization table (verified, `TabActivityMark`'s neighbors use `localizedString(_:default:)` against `Bundle.module`). Not mentioned.

### B10. The "no PR" decision is asserted without authority or consequence analysis

`CLAUDE.md` (repo root and Stage11 root) describes the default orchestrator workflow as "one delegator per ticket ... producing an open PR through plan → implement → review → fix." This plan says "The delegator does not open a PR" twice and offers no rationale. It may well be a valid orchestrator instruction, but the plan does not cite it, and the plan does not reckon with the consequence established above: **no PR means no CI, and CI is the only place the host-bound tests it is editing can run.**

---

## Challenged Decisions

**D1. Put the shared clock in Bonsplit.**
Counterargument: put it in c11 and pass a `phase: Double` (or a small `MarkAnimationPhase` value) into `TabActivityMark` as a plain parameter. Bonsplit then stays pure shape vocabulary plus one numeric input, which is genuinely upstreamable and matches the ticket's instruction word for word. c11 owns the timer, the app-active gating, the Reduce Motion observation, and the viewport intersection, all of which are application concerns it already has the machinery for. The plan's chosen direction pushes app infrastructure *into the vendored fork*, which maximizes future merge friction with `manaflow-ai/cmux` and `almonk/bonsplit`, the exact cost `CLAUDE.md` warns about ("Don't silently diverge on shared code"). I read this as a default (the clock is shared, bonsplit is shared, therefore bonsplit) rather than a deliberate choice, and the plan's one-sentence defense of it is assertion.

**D2. Defer 100% of empirical validation.**
The operator said skip the *harness* and avoid an *oversized* test suite, and said "perform proportionate tagged-build validation." The plan reads that as "no tagged build in this stage at all." Those are different. A single tagged build with a screenshot of four marks at 9pt in both renderers, in both themes, and one greyscale conversion, costs very little and discharges three of the ticket's five "Done when" bullets. The recorded operator feedback pattern in this repo ("delegators must press past PR-open to tagged build + screenshot + validation") points the other way. This is the plan's most defensible-looking decision and I think it is wrong on the margin.

**D3. Write sizing tests into a host-bound file while forbidding host-bound runs.**
The alternative is obvious and cheap: `WorkspacePulseMarkRowMetrics` is a pure `enum` of static functions on `CGFloat`. Move it (or add a new metrics test class) into the `c11LogicTests` target, where `SidebarActivityProjectorTests` already lives. Then the plan's own verification command works. As written the plan has picked the one arrangement where its tests can neither run locally nor in CI.

**D4. `minimumSlot` 8 → 9 without checking the existing overflow assertions.**
Verified consequence: `stride = minimumSlot + minimumSpacing` goes 10 → 11, so overflow onset shifts. `c11Tests/WorkspaceUnitTests.swift:2519` `testVeryCrowdedRosterShrinksMarksAndKeepsThemAllVisible` asserts `layout.slot < preferredSlot` and `layout.markSide == min(9, layout.slot)` at count=16 / width=178. With slot floored at 9: 16*9 + 15*2 = 174 ≤ 178, so it likely still passes, but the test's *name and intent* ("ShrinksMarks") become false, and `testOverflowingRosterCountsTheRemainder` at count=60 changes its hidden/visible split. The plan says "slot never drops below 9pt; mark side remains exactly 9pt while crowded rows overflow" as if these were new tests, without acknowledging that four existing assertions in that class encode the *old* compression contract and must be rewritten. And it cannot run any of them.

**D5. Ship the flagged rendering paths with no way to exercise them.**
Non-goals forbid any flag/suppress CLI, socket, or metadata primitive. So the violet recolor, the 0.4s violet/white core flash, and the flag-overrides-suppression rule all ship as code no human or agent can trigger. Counterproposal: a `#if DEBUG` seam or a debug-menu toggle that forces a mark's `(state, flagged, suppressed)` tuple, so a validator can actually look at the alarm flash once before it ships. `CLAUDE.md` already blesses the pattern ("If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam"). The plan's Phase 4 policy section cites the same test-quality doc and then declines to add the seam.

**D6. `Static marks` as a single boolean.**
The spec designed a three-rung ladder for a reason. A boolean cannot express dip-only. If the ladder ever has to be applied, the setting has to be redesigned. Shipping the enum now (`animated` / `attentionOnly` / `static`) costs one type and pre-pays the ladder. Also worth asking: is `Static marks` the right label at all when flag-tier motion ignores it? An operator who enables "Static marks" and still sees motion has been told something false by the label.

**D7. Phase ordering.**
Phase 1 pushes bonsplit shapes to main; Phase 2 pushes the clock to bonsplit main; Phase 3 does c11. The shapes are committed and irreversible before anyone has seen the geometry rendered anywhere. If the 2pt-dot-on-3pt-pitch grid turns out to be mush at 1x, the correction is a third bonsplit commit. Inverting (build both renderers, look at them, *then* split and push the bonsplit commits) costs nothing and keeps the irreversible step last.

---

## Hindsight Preview

Two years out, the likely "we should have known" list:

1. **"We should have known the tests were in the wrong target."** It is in `CLAUDE.md`, with a named incident (C11-105) and a described blast radius. The plan re-created the ambiguity in its Phase 4 file list.
2. **"Why didn't we just look at it once?"** A single tagged build and four screenshots would have discharged the greyscale bullet, the both-renderers-agree bullet, the 9pt bullet, and the light-theme question. The plan's total avoidance of the GUI on a purely visual ticket is the decision that will look strangest in retrospect.
3. **"Why did the flagged docs still say breathe?"** Because C11-183's plan named them stale and then did not fix them, and C11-184 planned off the stale text.
4. **"The animation was never actually measured."** The ticket said HARD SHIP BLOCKER in capital letters; the clarification relaxed the *harness*; the plan relaxed the *measurement*; the validation stage inherits an unbounded ask with no threshold.
5. **"The clock never should have gone into bonsplit."** The first upstream sync after this will be the moment it becomes obvious.

**Early-warning signs this plan has no mechanism to detect:**
- Anyone reporting the sidebar "feels busy" or turning `Static marks` on immediately. There is no telemetry on the setting.
- A working mark ticking on an agent that is actually hung. Nothing correlates fill with output.
- Marks looking soft or uneven on an external 1x display. Nobody will file it as a c11 bug; they will file it as "the marks look weird."
- Battery drain on a large fleet. The gating is designed but not instrumented, so a leaked registration (a leaf that fails to unregister on disappear) is invisible. **The plan should require a debug counter of live clock registrations**, which is three lines and turns an invisible leak into an observable number.

---

## Reality Stress Test

Three likely disruptions, hitting together:

**Disruption 1: the operator interrupts or forbids the local `xcodebuild` runs** (consistent with the recorded C11-181 correction).
Effect: the plan's only two pieces of evidence vanish. With no PR, there is no CI fallback. The delegator delivers a branch with an unverified compile and moves the ticket to `review`. The reviewer inherits a change to two renderers, a new app-lifetime timer, and a sizing contract, with nothing green anywhere.

**Disruption 2: the deferred validation stage finds the fill regresses typing latency at fleet scale.**
Effect: there is no ladder to apply. The available responses are (a) flip the default to static, which makes the animation work dead, or (b) reopen the ticket and build the ladder now, in a branch that has already pushed two irreversible commits to bonsplit `main`. The `Static marks` boolean cannot express the intermediate rung the spec designed for exactly this moment.

**Disruption 3: C11-184 starts before C11-183 is reviewed.**
Effect: C11-184 plans against `docs/c11-flagged-agent-plan.md`, implements breathe for flagged working/idle/cold, and discovers mid-implementation that C11-183 shipped "flagged working uses normal fill, flagged idle/cold still." Meanwhile it also finds that `WorkspacePulseAgent.flagged` may have been declared in a form that its own producers cannot set. Both tickets stall on a reconciliation nobody scheduled.

**All three together:** an unverified branch, no CI, an unbuildable ladder, irreversible submodule commits, and a blocked child ticket, with the only recovery path being a fresh agent re-reading two mutually contradictory docs. This is not a low-probability compound. Disruption 3 is near-certain given the `depends_on` link already exists, and Disruption 1 has already happened once on this repo.

---

## The Uncomfortable Truths

1. **This plan cannot prove it works, and it says so, and everyone is treating that as acceptable because the sentence is written confidently.** "This implementation stage records only what it actually ran and makes no visual or typing-latency claims" is a well-crafted disclaimer that converts a total absence of evidence into an apparent methodological virtue. On a ticket whose deliverable is *what four 9-pixel shapes look like*, it is not a virtue.

2. **The operator's clarification was about scope, and the plan used it as cover for something broader.** "Skip a dedicated QA/performance harness and avoid an oversized test suite" became "no tagged build, no screenshot, no greyscale check, no animation test, no gating test, no clock test," while the clarification's own trailing clause said "perform proportionate tagged-build validation." That clause is the one thing from the clarification that the plan did not carry into its precedence list.

3. **The only new behavior the plan actually tests is behavior that cannot happen.** Suppressed-waiting-projects-to-idle and flagged-plus-suppressed-stays-waiting are both unreachable until C11-184 ships a producer. The four tests in Phase 4 that will actually execute are tests of dead code.

4. **The "upstream-clean" framing is being used to justify a decision that makes upstreaming harder.** Saying "the shared clock is a generic renderer primitive, not a c11 flag/socket/metadata primitive, so the Bonsplit change remains upstream-clean" is a definitional move, not an argument. The ticket said pure shape vocabulary. A registration-token animation clock is not shape vocabulary by any reading.

5. **The plan's risk section names five risks and mitigates none of them with a test.** Timer proliferation, phase instability, offscreen work, modifier ambiguity, geometry drift: every one is checkable in a pure unit test (registration count, phase determinism for a fixed UUID, projection priority table, shared-constant equality), and Phase 4 covers exactly one of them (modifier ambiguity, in its unreachable form). The risk list and the test list were written independently.

6. **Nobody in this chain has looked at the mock.** `scratchpad/mark-vocabulary-candidates.html` is listed as binding input #3, "the live geometry and timing reference," and no step in the plan opens it, compares against it, or uses it as an acceptance reference.

---

## Hard Questions for the Plan Author

1. `WorkspaceUnitTests.swift` is a member of the **`c11Tests`** target, not `c11LogicTests`. Your verification command is `-scheme c11-logic -only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`. Did you check target membership, or did you infer it from the directory name? What is the corrected plan: move the metrics tests into a `c11LogicTests`-member file, or accept that the 9pt sizing change ships unrun?

2. CI triggers only on push-to-`main` and on `pull_request`. With "no PR in the parent repository," **what runs any test at any point before this merges?** Name the mechanism.

3. Four existing assertions in `WorkspacePulseMarkRowMetricsTests` (`WorkspaceUnitTests.swift:2519-2529`) encode the *old* compress-to-8pt contract, including `XCTAssertEqual(layout.markSide, min(9, layout.slot))`. Your plan lists new assertions but never mentions rewriting the old ones. Have you read that class? Which assertions change, and how do you verify them given (1) and (2)?

4. Every submodule command in your verification block contains the literal placeholder `<stage11-remote>`. `vendor/bonsplit` has exactly one remote, `origin`. Is this plan intended to be executed, or read?

5. The plan states the operator clarification "overrides stale flagged-motion prose in the prompt **and docs**," and then does not update the docs. `docs/c11-flagged-agent-plan.md` specifies breathe in five places and is the binding input for C11-184, which `depends_on` this ticket. Why is fixing that prose not in scope, and who fixes it before C11-184 plans?

6. `TabItemView.swift:164-165` currently reads "Nothing here animates. The mark is drawn once per state change, which keeps continuous per-tab redraw off the tab-bar render path," from a commit titled "Agent-state marks: hard cell, no animation." You are reversing a documented performance invariant. What replaces the guarantee, and where will a reviewer be told this reversal is deliberate?

7. Justify the shared clock living in bonsplit rather than in c11 with a `phase` parameter passed in. The ticket's instruction was "PURE SHAPE VOCABULARY with no c11-specific concepts ... a clean accessibility fix to offer upstream." Would you accept an app-lifetime registration-token timer into a third-party tab-bar library you maintained?

8. The spec's degradation ladder (fill → dip-only → static, and static-violet for flag tier) is the sole mitigation for default-on animation, and the ticket's "Done when" explicitly permits "**or the ladder is applied and the outcome recorded**." Your plan builds no ladder and ships a boolean setting that cannot express the middle rung. If the deferred validation finds the fill regresses latency, what is the exact remedy, in code that exists?

9. Who owns the typing-latency measurement, when does it happen, and **what is the pass threshold**? "Belongs to the fresh validation stage" names a stage, not an owner or a number. If the answer is "we don't know," say so, because right now a HARD SHIP BLOCKER has no defined pass criterion anywhere in the chain.

10. The ticket's first "Done when" is "Both renderers **agree**." With bonsplit forbidden from importing c11 concepts and c11 unable to import bonsplit `Internal/`, where do the shared geometry constants live, and what test or check demonstrates agreement? "Review the final diff side by side" is not a mechanism.

11. `resolvedSurfaceTabActivityColors(from:)` returns a distinct **light-theme** palette. Have you rendered the 25%-opacity base square, the 1pt vs 1.5pt frames, and the hardcoded `#9D8AD9` violet against a light workspace background? If not, what is your basis for believing the vocabulary reads in both themes?

12. Where does `#9D8AD9` live, given every other mark color is theme-resolved through `BonsplitConfiguration.Appearance.TabActivityColors`? Are you introducing the first hardcoded, non-theme-resolved mark color in the subsystem, and is that intended?

13. At 1x (non-Retina external display), the working grid is 2px dots on 3px pitch with a 0.5px inset, and the waiting/idle discrimination is a 2px vs 1px stroke. What is your evidence that the four states remain distinguishable there? The ticket's premise is that shape alone carries state.

14. Where is Reduce Motion read, where is `accessibilityDisplayOptionsDidChangeNotification` observed, and at what scope? There is currently zero prior art in the repo. Per-leaf observation reintroduces the N-observers problem your own risk section forbids for timers.

15. Do `flagged`/`suppressed` land on bonsplit's `TabItem` (which is `Codable` and has a legacy-JSON compat test at `BonsplitTests.swift:370-377`), or as `TabActivityMark` view parameters? If the latter, how does the c11 tab-bar call site ever supply them, and in what sense is the seam "forward-compatible"?

16. `WorkspacePulseAgent` is a `let`-field struct on the synthesized memberwise init. Is `flagged` declared as `let flagged: Bool = false` (no init parameter, so C11-184 cannot set it) or `let flagged: Bool` with an explicit defaulted init (every call site unchanged, C11-184 can set it)? These have opposite consequences for the plan's central forward-compat promise.

17. Nothing sets `suppressed` in this ticket. Your only executable new tests cover suppressed projection. Do you accept that Phase 4 tests unreachable behavior while the shipping behavior (shapes, motion, gating, sizing) gets no test at all? What would you add if you had to test one shipping behavior?

18. There is no way to see the flagged violet or the 0.4s alarm flash render, in this ticket or in any tagged build. Will you add a `#if DEBUG` seam to force `(state, flagged, suppressed)`? If not, the first human to see the alarm flash sees it in production.

19. Phase 2 adds a second bonsplit commit but the eight-step push/ancestry/pointer sequence is written only under Phase 1. Is the Phase 2 bonsplit commit pushed and ancestry-verified before its own pointer bump, and is that a second pointer commit or an amend?

20. Both bonsplit commits go to `Stage-11-Agentics/bonsplit` `main`, unreviewed and unrewindable, before any parent-repo review. If review rejects the geometry, what is the rollback, and why is the irreversible step first rather than last?

21. When a surface goes working → waiting → working, does the fill resume at global clock phase (visible jump) or restart at zero? This is user-visible and unspecified.

22. At 20 agents the sidebar carries ~20 staggered 2.5 Hz tickers against 1-2 smooth dips. The spec's motion hierarchy argument is per-mark. What is your basis for believing it holds in aggregate, at the fleet scale this product exists for? If the answer is "we'll find out after ship," say so.

23. The working fill is a free-running clock, not a function of output. A hung agent in `working` animates indefinitely. Is motion-that-reads-as-liveness-but-measures-nothing an acceptable product property, and was it considered?

24. `CLAUDE.md`'s default is "one delegator per ticket ... producing an open PR." What authorizes "no PR," and was the CI consequence (question 2) weighed when that was decided?

25. `scratchpad/mark-vocabulary-candidates.html` is binding input #3, "the live geometry and timing reference." No step in the plan opens or compares against it. Has anyone on this ticket looked at it?

26. English-only `Static marks` with a "precise translation-stage note" to the parent: is a Lattice comment the deliverable, or will a ticket exist? Note `ci.yml` `paths-ignore` excludes `Resources/Localizable.xcstrings`, so nothing will ever nag.

27. Registration leaks in the shared clock are silent by construction. Will you expose a live-registration count (three lines, debug-only) so a leaked leaf is an observable number rather than an unexplained battery report?

28. `TabActivityMarkMetrics` already has `cellSide = 9`, uniform `visibleSize = 10`, and uniform `leadingAccessoryWidth = 18`, with a comment already asserting the uniform-slot property. What, specifically, changes in `TabActivityMarkMetrics`, and does `BonsplitTests.swift:1449-1450` need to change at all?
