# Adversarial Plan Review — c11-183-plan (Codex)

## Executive Summary

**Verdict: major rework required before this plan is safe to execute as written.**

The plan is strong on naming the desired geometry and repeating the performance principles, but weak at the two places where this ticket can actually fail: the cross-module animation architecture and the hard fleet-scale typing-latency gate. It turns the ticket's merge blocker into an unspecified later activity, even though the operator explicitly asked for proportionate tagged-build validation. It also never defines how one setting, one app-active signal, one Reduce Motion signal, and one clock reach both the c11 and Bonsplit renderers without invalidating the hot parent views.

The single biggest issue is that this is not yet an executable performance plan. Lines 231–234 defer all visual and timing validation, while lines 180 and 265 exclude a harness or benchmark, but nothing replaces those exclusions with a concrete manual protocol: no tagged-build command, fleet construction method, baseline, measured quantity, threshold, typing workload, evidence format, or degradation-ladder procedure. The ticket's “hard ship blocker” can therefore neither pass nor fail.

Implementation may safely proceed on isolated static geometry and pure metric changes, but the animation clock, setting propagation, offscreen gating, and modifier behavior should not be treated as settled until the plan resolves the issues below.

## How Plans Like This Fail

### 1. The plan implements slogans instead of mechanisms

“One shared clock,” “leaf-isolated,” and “pause off-screen” are constraints, not an implementation design. The plan names no clock API, executor, tick strategy, registration lifecycle, ownership boundary, or propagation path. That omission matters because the current Bonsplit leaf receives only `(state, appearance)`, while the c11 sidebar renderer lives in an Equatable hot-path parent. The easiest implementations all violate a stated constraint:

- put `@AppStorage` or app-state observation in every outer row and churn hot parents;
- let Bonsplit read a c11-specific UserDefaults key and break package purity;
- create one clock per workspace/controller rather than one per app;
- use a high-frequency global observable clock and make every registered leaf re-evaluate on every tick;
- add per-tab geometry preferences whose updates invalidate `TabBarView` while scrolling or typing.

The plan needs to rule these out structurally, not by aspiration.

### 2. The hard gate is postponed until it can only surprise the project

The ticket says fleet-scale typing latency blocks merge and requires empirical ladder validation. The plan's implementation outcome stops at compilation and narrow logic tests (lines 11–18), then sends all visual/timing work to a later validator (lines 231–234). Late discovery is especially expensive here: a failed gate may require replacing the clock, viewport tracking, or animation policy, not merely changing a constant. The implementation plan should make the gate executable and preserve time for one rework cycle before review.

“No dedicated harness” does not mean “no defined validation.” A proportionate manual tagged-build scenario can still specify:

- how to create or restore 20 working agents;
- how to ensure both renderers are actually visible;
- the exact typing workload and baseline build;
- the measurement source and pass threshold;
- how to separately disable fill and dip to validate ladder order;
- which screenshots, traces, and configuration readbacks are attached.

None of that exists.

### 3. A downstream seam becomes unowned dormant product code

The plan expands C11-183 beyond the base vocabulary into flagged recolor, flagged waiting flash, suppression projection, and modifier priority, but C11-184's runtime primitives are explicitly out of scope. That leaves the new modifier paths unreachable in the running app. Without a small component-level seam or pure presentation-policy test, those paths can compile while being visually or behaviorally wrong, then force C11-184 to rewrite them.

The plan currently has the worst combination: it takes on downstream behavior but excludes the means to exercise it.

### 4. “Upstream-clean” erodes through convenient additions

The ticket calls the Bonsplit change a pure shape-vocabulary accessibility fix. The plan then proposes Bonsplit-owned clock infrastructure and `flagged` / `suppressed` inputs (lines 82–87 and 105–134). Those are not obviously part of a pure shape fix. Default-on animation also changes behavior for every Bonsplit embedder unless the host contract is explicitly opt-in at the package level and enabled by c11.

If this lands as one undifferentiated Bonsplit change, the upstream offer becomes difficult to review and future syncs inherit c11 attention-model concepts.

## Assumption Audit

### Load-bearing assumptions

1. **A single Bonsplit-owned clock can serve both modules without making Bonsplit c11-specific.**  
   Likelihood: uncertain. The plan never defines whether this is a process singleton, a controller-owned service, an environment value, or a public configuration dependency. “Public generic seam” is not enough.

2. **The Static marks preference reaches both renderers live.**  
   Likelihood: low under the current plan. The only concrete storage work is an `@AppStorage` in `Sources/c11App.swift` (lines 156–159). No Bonsplit configuration field, Workspace observer, ContentView source, or public environment key is named. The repository already has explicit Workspace-to-Bonsplit live-update patterns; the plan ignores them.

3. **Reduce Motion changes are observed dynamically rather than sampled once.**  
   Likelihood: uncertain. Reading `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` once is insufficient. The plan needs the display-options-change notification, a single observation owner, and a subscription update path.

4. **“Scroll viewport intersection” can be added cheaply.**  
   Likelihood: uncertain and high-risk. The current tab strip tracks aggregate scroll geometry and selected-tab geometry, not a cheap visibility fact for every tab. Per-tab GeometryReaders/preferences can become the performance regression the feature is supposed to avoid.

5. **“Collapsed pane” has one unambiguous meaning.**  
   Likelihood: low. Bonsplit also has a responsive collapsed/narrow tab-strip tier with visible dropdown rows. The plan must distinguish an actually collapsed split pane from a narrow-layout collapsed tab strip and state whether visible dropdown marks animate.

6. **Stable UUID phase offsets preserve the desired cadence while still coalescing work.**  
   Likelihood: uncertain. Arbitrary offsets scatter deadlines. A single timer that wakes for every unique subscriber deadline is one timer but not necessarily coalesced work. The plan needs a quantized beat model or explicit next-deadline scheduler and tests for it.

7. **The plan's timing language maps to one deterministic phase function.**  
   Likelihood: low. “Nine dots over the 4-second cycle, then a full hold and hard reset” (lines 60–61) does not say how much of the four seconds is fill versus hold. The binding spec and prototype describe roughly 3.6 seconds of fill within a 4-second cycle. Boundary behavior must be exact or the two renderers can disagree.

8. **The final Bonsplit submodule commit is reachable from remote `main`.**  
   Likelihood: only if the final check catches a missing step. Phase 1 describes committing and pushing the static vocabulary, but Phase 2 adds more Bonsplit code and has no explicit second commit/push sequence. The final ancestry command can fail, but the plan does not tell the delegator to push the Phase 2 commit before committing the parent pointer.

9. **A fresh validator can reproduce fleet state without a harness or recipe.**  
   Likelihood: low. No setup, fixture, snapshot, or manual fleet-construction recipe is named.

10. **Deferring translations is harmless.**  
    Likelihood: low. The repository contract ships six non-English locales and requires catalog synchronization after English strings change. Lines 163–165 and 255–256 leave translation as an optional later note rather than a required pre-completion stage.

### Secondary assumptions

- A 1.5pt frame and 0.5pt dot insets remain crisp under every supported display scale.
- Summary-row and footer-row duplicates do not materially alter the fleet count.
- The first two summary agents can animate in addition to the full footer roster without changing the gate's workload model.
- The base commit `ba1382a6c` remains an acceptable integration base while `origin/main` moves.
- Directly advancing Stage-11-Agentics/bonsplit `main` before parent review is acceptable for both the static and animation commits.
- Default memberwise values on `WorkspacePulseAgent` are enough to avoid touching every construction site and preserve Equatable behavior.

## Blind Spots

### [Critical] There is no validation protocol for the merge blocker

The plan needs a dedicated section—not necessarily a dedicated harness—with:

1. tagged build and QA launch commands;
2. a reproducible 20-agent/40-plus-mark setup;
3. confirmation that surface tabs and sidebar marks are concurrently visible;
4. a baseline with motion disabled;
5. a fixed typing scenario and measurement source;
6. an explicit acceptable regression threshold;
7. separate fill-only and dip-only runs;
8. the exact ladder decision and configuration change if either run fails;
9. app-background, unselected-workspace, collapsed-pane, and scrolled-offscreen readbacks;
10. artifact names and the Lattice validation evidence to attach.

Without these, “hard blocker” is prose.

### [High] No cross-module control-flow diagram or API contract

The plan should name the exact flow:

`UserDefaults setting / app-active / Reduce Motion` → one policy owner → Bonsplit configuration or environment + c11 leaf input → registration eligibility → shared scheduler → leaf-local phase.

It must also state:

- which type owns the singleton;
- whether callbacks are `@MainActor`;
- whether the timer is a `Timer`, dispatch source, or another primitive;
- how registrations are weakly held and cancelled;
- how the clock stops at zero eligible leaves;
- how phase resumes without visual synchronization or reset;
- how a setting change updates every existing Workspace's Bonsplit controller;
- how the c11 Equatable parent avoids observing the clock.

### [High] Modifier behavior is internally incomplete

The binding vocabulary says suppressed unflagged working marks render a static full grid. The plan mentions only suppressed waiting becoming idle (lines 66, 140–145, 171–174). It never says the animation policy rejects `suppressed && !flagged`, so a future suppressed working agent can still animate.

The operator said flagged non-waiting marks use normal lifecycle motion. The plan interprets that as flagged working filling even when Static marks is on (lines 68–69). That may be intended, but it is not established by the clarification. “Normal lifecycle motion” can equally mean that Static marks disables it, while flagged waiting remains the exceptional flash. This must be resolved explicitly rather than inherited from stale flag-tier prose.

The plan also needs one canonical pure presentation decision such as:

`effectiveState`, `effectiveColor`, `motionChannel`, and `isEligible`

derived from `(rawState, flagged, suppressed, staticMarks, reduceMotion, visible, appActive)`. Today those rules are scattered between projector prose and renderer prose.

### [High] “Forward-compatible” is not true for the Bonsplit call path

Adding defaulted modifier parameters only to internal `TabActivityMark` does not give C11-184 a route from c11 metadata through public `Bonsplit.Tab` / `TabItem` / controller updates / `TabBarView` to the leaf. The plan does not identify that route, and adding `flagged` / `suppressed` directly to Bonsplit public models would violate the pure-package goal.

Either:

- C11-183 should build only a generic visual/presentation seam with a host-neutral API; or
- modifier plumbing should remain in C11-184, with C11-183 limited to reusable shapes and base motion.

The current middle ground is dormant internal code, not a forward-compatible integration seam.

### [High] Tests do not cover the new failure surface

The proposed tests cover projection and sizing, but not:

- exact fill-step boundaries and full-hold duration;
- stable phase offsets for fixed UUIDs;
- waiting dip endpoints;
- flagged waiting replacing rather than stacking the dip;
- Static marks;
- Reduce Motion;
- suppressed working remaining static;
- flag-over-suppression;
- visible/inactive eligibility decisions;
- registration cancellation and zero-registration clock shutdown;
- the “one scheduler, no per-leaf timer” design through an executable seam;
- live preference propagation to both renderers.

This does not require an oversized animation matrix. A small pure policy/phase suite plus one clock lifecycle test would cover most of it.

### [Medium] Geometry agreement is maintained by duplication and hope

The plan proposes a dedicated c11 leaf and a separate Bonsplit leaf, then mitigates drift with “same named geometry constants/order” and side-by-side review (lines 253–254). Names do not enforce equality across modules.

The plan should evaluate a shared host-neutral geometry/presentation primitive exported by Bonsplit and consumed by both renderers. If duplication is deliberate, it should specify mirrored constants and executable metric tests in both modules, including the waiting frame/core arithmetic—not only the outer 9pt slot.

### [Medium] Localization is treated as optional cleanup

`Static marks` is locked user-facing copy. The English title, subtitle, toggle accessibility label, catalog entry, and six translations need an owned phase and verification before the ticket is done. “Leave a note” is not a delivery plan.

### [Medium] Submodule sequencing is incomplete

The plan's push sequence belongs to Phase 1, but Phase 2 also modifies Bonsplit. It needs:

- one commit for the upstream-offerable static vocabulary;
- a separate commit for generic animation infrastructure if retained;
- review of the exact diff between `d4ff0e4c` and final submodule HEAD;
- push of final HEAD to Stage-11-Agentics/bonsplit `main`;
- fetched remote-main ancestry proof for final HEAD;
- only then the parent pointer commit.

The upstream offer must name only the clean commit(s), not the c11-specific modifier behavior.

### [Medium] The plan omits fresh-worktree provisioning evidence

The plan cites repository provisioning rules but does not record submodule initialization or the `GhosttyKit.xcframework` symlink check before the first Xcode build. Since implementation is already in an isolated worktree, this should be a concrete baseline check, not an assumed prerequisite.

## Challenged Decisions

### Put the shared clock in Bonsplit

**Counterargument:** the clock is product runtime policy, while Bonsplit should own only mark rendering and accept a host-provided phase/policy. Putting a process singleton in a reusable package makes all embedders inherit scheduling behavior and complicates upstreaming.

**Alternative:** export a host-neutral mark view and deterministic phase function from Bonsplit; let c11 own the one app scheduler and inject leaf-local phase updates. If Bonsplit must own the scheduler to animate its internal leaves, make it an injected service/configuration with a no-animation default for other embedders, and explicitly prove c11 supplies one shared instance to both renderers.

### Implement flagged and suppressed presentation in C11-183

**Counterargument:** it expands an accessibility repair into an unreachable slice of C11-184, contaminates the clean upstream diff, and creates code that cannot be validated through the running product.

**Alternative:** land the four shapes, base motion, fixed sizing, and a host-neutral presentation API now. Land actual modifier composition with the primitives that can exercise it in C11-184.

### Defer all running-system validation

**Counterargument:** fresh independent validation is correct, but an implementation plan still must define the validation contract and reserve the implementation owner for rework. A fresh validator cannot invent the acceptance threshold after seeing the result.

**Alternative:** pre-register the scenario and pass/fail threshold now. The delegator compiles and runs pure tests; the fresh validator executes the tagged scenario; failure returns the ticket to implementation with an explicit ladder branch.

### Duplicate shape code across modules

**Counterargument:** the whole ticket exists because two visual states drifted into an accessibility lie. Duplicating the replacement vocabulary invites a future recurrence.

**Alternative:** share a generic mark renderer or at least a single public geometry model with module-specific colors and accessibility wrappers.

### Push directly to the submodule's `main` during implementation

**Counterargument:** repository policy requires final reachability before the parent pointer, but it does not require mixing the upstream-clean shape commit and the more contentious scheduler/modifier commit or pushing an unreviewed final design prematurely.

**Alternative:** create and review named submodule commits, then fast-forward the Stage-11 remote `main` immediately before the parent pointer commit. Preserve separate provenance for the upstream-offerable subset.

## Hindsight Preview

Two years from now, the likely “we should have known” failures are:

1. **The shared clock was technically singular but still expensive.** It woke at every staggered leaf deadline, performed main-actor fan-out, and saved timer objects without saving meaningful work.
2. **Viewport tracking cost more than the animations.** Per-tab geometry preferences churned during scroll, resize, drag, and title changes and invalidated the tab strip.
3. **Static marks worked in the sidebar but not in Bonsplit.** The preference had no explicit live propagation route to existing workspace controllers.
4. **Reduce Motion only applied after relaunch.** The implementation sampled the system preference instead of observing changes.
5. **C11-184 had to rewrite the seam.** Internal defaulted arguments did not transport modifiers through Bonsplit's public tab model.
6. **The two renderers drifted.** One fixed the 4pt core or fill order while the other retained the old geometry.
7. **The latency ladder could not be defended.** No recorded baseline, threshold, or independent fill/dip measurement existed, so the chosen default reflected impression rather than evidence.
8. **The “pure upstream” patch was rejected as product-specific.** It bundled default-on animation, flags, suppression, and scheduler ownership with the accessibility shapes.

Early warning signs the plan should monitor:

- more than one clock/scheduler instance in runtime diagnostics;
- registrations remaining after workspace deselection or app deactivation;
- body evaluations in `TabItemView` or `TabBarView` at animation cadence;
- UserDefaults changes affecting one renderer before the other;
- visible marks snapping into phase after returning onscreen;
- timer wakeups continuing with zero visible eligible marks;
- the tagged gate being described qualitatively rather than with a baseline and threshold;
- the final Bonsplit HEAD not being an ancestor of fetched Stage-11 `main`.

## Reality Stress Test

### Disruption 1: Bonsplit `main` advances during implementation

The static commit is based on `d4ff0e4c`, Phase 2 adds scheduler work, and another change lands remotely. The plan's first push may succeed, the second is not specified, and the parent pointer can end up referencing an unpushed or rebased commit. The plan needs a final fetch/rebase-or-merge decision, final-HEAD push, and ancestry proof immediately before the parent commit.

### Disruption 2: fleet-scale fill fails the latency gate

The ticket requires testing dip-only next, then static. The plan has neither independently controllable experimental switches nor a measurement procedure. The validator discovers a regression but cannot tell whether viewport tracking, scheduler fan-out, dot-body rebuilds, or duplicate sidebar marks caused it. The task returns to implementation without diagnostic leverage.

### Disruption 3: the operator toggles Static marks or Reduce Motion while the app is active, then switches workspaces and backgrounds the app

This simultaneously exercises preference propagation, accessibility notification handling, app-active gating, workspace eligibility, cancellation, and phase resume. The plan specifies outcomes but no owner or state machine. The likely result is one renderer stopping, another continuing, stale registrations surviving, or animations restarting in lockstep.

When all three happen together, the plan has no stable recovery point: the package commit is moving, the ship configuration is undecided, and the runtime policy has no single authoritative owner.

## The Uncomfortable Truths

- The plan is detailed where the work is easy—shape dimensions, filenames, and git commands—and vague where the ticket is dangerous—scheduler design, viewport cost, live policy propagation, and empirical latency.
- “Later fresh validation” currently functions as a place to hide missing acceptance design. Independence does not compensate for an undefined test.
- The proposed `flagged` / `suppressed` seam is not actually end-to-end and is not cleanly upstreamable. It is premature abstraction presented as forward compatibility.
- The plan cannot claim one shared clock merely because there is one timer object. Main-thread fan-out and wakeup frequency are the costs that matter.
- Avoiding an oversized suite is sensible. Omitting focused tests for the presentation policy and scheduler lifecycle is not.
- The plan makes an unconfirmed product decision that flagged working ignores Static marks. That needs an operator answer, not an inference from stale documentation.
- Translation is not optional because the English fallback compiles.
- If the implementation is already underway, sunk-cost pressure is now a risk. The static geometry work should not be used to wave through an unresolved animation architecture.

## Hard Questions for the Plan Author

1. **[UNKNOWN / BLOCKING] What exact tagged-build fleet scenario, typing workload, baseline, metric, and threshold decides whether C11-183 passes?**
2. **[UNKNOWN / BLOCKING] How will the validator independently measure fill-only and dip-only behavior to apply the required ladder?**
3. **[UNKNOWN / BLOCKING] What concrete API makes the scheduler one per app rather than one per Bonsplit controller, workspace, renderer, or generic specialization?**
4. **[UNKNOWN / BLOCKING] Who owns the Static marks, app-active, and Reduce Motion truth, and how does each live change reach both existing Bonsplit controllers and c11 leaves?**
5. **[UNKNOWN / BLOCKING] What does “scroll viewport intersection” mean in code, and how will it avoid per-tab geometry preference churn in `TabBarView`?**
6. **Does “collapsed pane” mean an actually collapsed split pane, Bonsplit's responsive narrow tab-strip tier, a closed dropdown, or all three? What happens to marks in an open collapsed-layout dropdown?**
7. **Why does flagged working bypass Static marks? Did the operator explicitly choose that, or did the plan inherit it from the stale flag-tier rule that the clarification partially replaced?**
8. **Where is the rule that suppressed unflagged working renders the static full grid, even when global motion is on?**
9. **Why are `flagged` and `suppressed` concepts entering the Bonsplit leaf if the Bonsplit change must remain a pure, upstream-clean shape-vocabulary fix?**
10. **What public, host-neutral path will C11-184 use to carry modifier presentation through `Bonsplit.Tab`, controller updates, `TabBarView`, and `TabActivityMark` without rewriting the seam?**
11. **If there is intentionally no runtime path for modifiers in C11-183, how will flagged waiting, suppression priority, and violet rendering be behaviorally validated before they ship?**
12. **What is the exact 4-second phase table: when does each dot appear, how long is the full hold, and what happens at phase 0 and phase wrap?**
13. **How are arbitrary UUID offsets quantized so one timer still coalesces work instead of waking for every leaf's unique deadline?**
14. **What thread or actor invokes registration callbacks, and how are stale or deallocated leaf registrations prevented from receiving ticks?**
15. **What proves the clock stops with zero eligible leaves and while the app is inactive?**
16. **Why duplicate geometry in two renderers instead of sharing a generic renderer or geometry model? What executable check prevents future drift?**
17. **Which final Bonsplit commits are pushed to Stage-11 `main`, and which exact commit is offered upstream?**
18. **Where is the explicit Phase 2 submodule commit/push/ancestry sequence before the parent pointer commit?**
19. **Who owns the six-locale translation pass, when does it run, and what evidence keeps C11-183 from reaching done with English-only catalog coverage?**
20. **What exact worktree provisioning evidence confirms both submodules and `GhosttyKit.xcframework` were ready before Xcode validation?**
21. **If the fleet gate fails because viewport tracking or scheduler fan-out—not dot drawing—is expensive, does the ladder still disable fill first, or does implementation return for architectural repair?**
22. **What is the rework loop after fresh validation fails, given that the plan currently ends the delegator's stage before the only ship-blocking evidence exists?**

