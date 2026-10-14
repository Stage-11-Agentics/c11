# Evolutionary Plan Review: c11-183-plan (Claude)

Plan: `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md`
Ticket: C11-183 "Rebuild agent-state mark vocabulary: lifecycle in shape alone"
Baseline: `ba1382a6c`, branch `codex/C11-183-mark-vocabulary`
Reviewed: 2026-07-28

---

## Executive Summary

This plan is competent and unusually disciplined about the things plans usually get wrong: submodule ancestry, typing-hot-path invalidation, timer proliferation, scope non-goals. It will probably produce a working change. My concern is not that it fails; it is that it succeeds at a smaller thing than it could, and pays a structural tax it does not need to pay.

The plan treats this ticket as "fix two renderers to agree." The far more valuable framing is: **this ticket is where c11 gets a state-presentation language and an app-level animation clock, both of which are infrastructure that four or five future features will want.** The plan builds both, but builds them in shapes that are hard to reuse: the geometry is hand-duplicated across a submodule boundary, the clock is buried inside a vendored tab-bar library, and the (state, flagged, suppressed) composition rules, which are the actual intellectual content of the ticket, never become a testable object.

The single highest-leverage restructure is an **inversion**: make Bonsplit's mark a pure, public function of `(state, color, phase)` that c11 imports and renders directly, and keep the clock plus all animation policy in c11. That collapses Phase 2 into nothing, eliminates the geometry-drift risk the plan can only mitigate with "review the diff side by side," turns the contested spec rules into a 64-row truth table testable in `c11-logic`, and reduces the submodule dance to exactly one commit instead of two.

There is also one concrete executability defect worth fixing before implementation goes further: **the plan's own verification command cannot run.** `WorkspacePulseMarkRowMetricsTests` lives in `c11Tests/WorkspaceUnitTests.swift`, which is a member of the `c11Tests` target only, not `c11LogicTests`. The command `-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests` will not match, and the plan explicitly forbids the host-bound run that would exercise it. Details in **Correctness Gaps**.

---

## What's Really Being Built

Not "four new glyphs." Three pieces of infrastructure, only one of which the plan names:

**1. A state-presentation language.** Four shapes that carry lifecycle without color, with color freed as a modifier channel and opacity explicitly reserved as headroom. Once shape is the load-bearing channel, the vocabulary becomes portable to any surface that needs to say "what is this agent doing": the notifications list, the command palette, the menu bar extra, `c11 tree` CLI output, Overwatch's cross-workspace digests, workspace blueprint previews. The plan scopes it to two renderers because that is where the defect is. The asset is bigger than the defect.

**2. An app-level animation clock with eligibility gating.** One coalesced tick, stable per-entity phase offsets, and a registration model that stops work when the app is inactive, the workspace is unselected, the pane is collapsed, or the leaf is scrolled out of viewport. c11 does not have this today. This is the piece with the longest reuse tail: `SidebarDecayClock`, tab flash, progress indicators, staleness ticks, and every future ambient-motion feature wants exactly this primitive. The plan builds it and then hides it inside `vendor/bonsplit/`, where c11's other consumers cannot cleanly reach it and where every future tuning change costs a two-repo commit-push-ancestry-pointer cycle.

**3. A modifier composition seam.** `(state, flagged, suppressed)` plus two global overrides (Reduce Motion, Static marks) plus one tier rule (flag beats suppression) plus one replacement rule (flagged waiting replaces the dip rather than stacking with it). This is where all the design argument in both spec docs actually lives, and it is the contract C11-184 will lean on hardest. The plan mentions "centralize projection/presentation priority so ... are testable" in Risks, but Phase 4 never produces the object that would make it testable. It stays diffuse inside two view bodies.

**What this ticket really is:** the moment c11 acquires a formal vocabulary for agent state and a shared heartbeat to animate it. Named that way, several plan choices look different.

---

## Correctness Gaps (verified against the repo)

These are not evolutionary; they are things that will bite during execution. I checked each against the tree at `ba1382a6c`.

### G1. The metrics verification command cannot run (blocking)

Plan, Phase 4: tests go in `c11Tests/WorkspaceUnitTests.swift`.
Plan, verification: `-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`.
Plan, non-goals: "No host-bound local `c11-unit` run."

I resolved target membership from `GhosttyTabs.xcodeproj/project.pbxproj`:

| File (on disk) | Sources phase | Owning target |
|---|---|---|
| `c11Tests/SidebarActivityProjectorTests.swift` | `37DDE3B0…` | **c11LogicTests** |
| `c11Tests/WorkspaceUnitTests.swift` | `F1000005…` | **c11Tests** (host-bound) |

`WorkspacePulseMarkRowMetricsTests` is at `c11Tests/WorkspaceUnitTests.swift:2472`, so it is reachable only from the host-bound suite the plan forbids. The projector half is fine by luck (that file is on disk in `c11Tests/` but is a `c11LogicTests` member, exactly the disk-vs-target confusion that caused C11-105).

**Fix, cheapest first:** put the new 9pt slot-floor assertions in a file already in `c11LogicTests` (`WorkspaceContentViewVisibilityTests.swift` and `SidebarWidthPolicyTests.swift` are both members and both thematically adjacent), or add `WorkspaceUnitTests.swift` to the logic target. Avoid the second if it drags host-dependent classes into the logic target. Do not silently drop the assertion.

### G2. Raising `minimumSlot` to 9 changes the overflow ladder, and existing tests encode the old one

`WorkspacePulseMarkRowMetrics.layout` computes `stride = minimumSlot + minimumSpacing`. Going 8 to 9 makes stride 10 to 11, so `+N` overflow starts one or two marks earlier at any given sidebar width. `WorkspaceUnitTests.swift:2512-2545` asserts against the current ladder. The plan says it will adjust "existing Bonsplit behavior/metric tests" but never mentions adjusting the existing c11 metrics tests, which are the ones that will actually move. Small, but it is a red test the delegator will hit and might paper over.

### G3. The summary mark is 10pt, and the plan says "same renderer seam" without resolving it

`workspacePulseMark(for:summaryScale:side:)` at `Sources/ContentView.swift:11816` uses `side = summaryScale ? 10 : 9`, wrapped in a `.frame(width: 16, height: 16)`. The spec says 9pt always. A 3pt-pitch 3x3 grid tiles exactly into 9pt and does not tile into 10pt: you either drop the summary row to 9pt (a visible change to a surface the ticket never mentions) or you scale the grid and lose the hard-edged pixel alignment that is the whole idiom. The plan asserts "summary and footer marks use the same renderer seam" without noticing the two call sites currently disagree on size. Pick one explicitly.

### G4. Phase 2 implies a second submodule cycle the plan only describes once

The eight-step "commit, push to Stage-11-Agentics main, prove ancestry, then commit the parent pointer" sequence appears once, under Phase 1. Phase 2 then adds a clock seam under `vendor/bonsplit/Sources/Bonsplit/`, which is another Bonsplit commit requiring the same ritual, plus a second parent-pointer commit. Either fold all Bonsplit work into one pass before any push, or state the cycle twice. (The restructure in **How It Could Be Better** removes the second cycle entirely.)

### G5. The evidence chain is thinner than it looks, because "no PR" means "no CI"

The stage's total local evidence is: a Bonsplit `swift test`, one narrow `c11-logic` slice (half of which cannot run, per G1), and an `xcodebuild build`. No host tests, no tagged launch, no visual check, no PR, therefore no CI run. `CLAUDE.md` also warns that some `c11-logic` classes crash under the bare local runner and are only trustworthy in CI. So the stage may end with essentially zero verified test signal on the logic that matters. A draft PR (or `gh workflow run`) is what buys the CI `build` gate, which actually runs the logic suite. Worth naming as an explicit handoff obligation on the orchestrator rather than leaving it implicit in "transitioned to review."

### G6. Chrome scale is unaddressed

c11 ships `ChromeScaleTokens` / `ChromeScaleSettings` / `ChromeScaleObserver`. "Marks pin to 9pt always" is a statement about points, and chrome scale is a mechanism for making chrome bigger. Whether marks scale with chrome or defy it is a real product decision that neither doc makes. At minimum, note which one you implemented so review does not have to reverse-engineer it.

---

## How It Could Be Better

### The inversion: pure marks in Bonsplit, clock and policy in c11

**What the plan does:** Bonsplit owns the shape *and* an animation clock seam. c11's `ContentView` reimplements the same 9pt geometry in a second leaf view and subscribes to Bonsplit's clock.

**What I would do instead:**

```swift
// vendor/bonsplit/Sources/Bonsplit/Public/Views/BonsplitActivityMark.swift
public struct BonsplitActivityMark: View {
    public let state: BonsplitTabActivityState
    public let color: Color
    /// 0..9 filled dots for .running; ignored by other states.
    public let fillCount: Int
    /// Core opacity multiplier for .waiting; 1.0 static.
    public let coreOpacity: Double
    public let side: CGFloat
    // pure function of inputs. no timer, no @State, no environment.
}
```

Bonsplit's own `TabActivityMark` becomes a thin wrapper. c11 `import Bonsplit` already exists in five files including `c11App.swift`, so the sidebar renders **the same view instance**, not a copy of its geometry.

Consequences, all good:

- **Geometry drift becomes structurally impossible.** The plan's stated mitigation is "use the same named geometry constants in both renderers and review the final diff side by side." That is a promise a human keeps for one PR and nobody keeps for two years. Sharing the view removes the class of bug.
- **Phase 2 largely disappears.** No Bonsplit-owned clock, no cross-module subscription protocol, no "generic renderer primitive" justification exercise. One Bonsplit commit, one push, one ancestry proof, one pointer commit. G4 dissolves.
- **Bonsplit gets *more* upstream-clean, not less.** A public, dependency-free, accessibility-correct state glyph that takes its animation phase as an input is a strictly better upstream offer than one that ships a timer. Timers are the part upstream maintainers argue about.
- **All policy lands in one place in c11:** Reduce Motion, Static marks, app-active, workspace-selected, pane-collapsed, viewport intersection, flag tier, suppression projection. One place to read, one place to test, one place to tune after the latency gate.
- **Iteration cost collapses.** Post-gate timing tweaks (and there will be some, the spec itself says the ladder order is "probably, not certainly" correct) become a one-repo edit instead of a submodule round trip.

The plan's counter-argument would be that the clock must live in Bonsplit for the tab chips to use it. It does not: Bonsplit's `TabBarView` can own its own tiny clock, or better, c11 can pass phase down through the existing `Tab` model the same way it already passes `activityState` and `flashGeneration`. `flashGeneration: Int` on `TabItemView` is the exact precedent: an animation signal the host computes and Bonsplit renders. Follow it.

### Make the composition rules an object, not a view-body conditional

This is the second-biggest win and it is nearly free:

```swift
enum MarkMotion: Equatable { case none, typewriterFill, coreDip, alarmFlash }
enum MarkColorRole: Equatable { case lifecycle, flagViolet }

struct MarkPresentation: Equatable {
    let state: WorkspacePulseState   // post-suppression projection
    let color: MarkColorRole
    let motion: MarkMotion

    static func resolve(
        rawState: WorkspacePulseState,
        flagged: Bool,
        suppressed: Bool,
        staticMarks: Bool,
        reduceMotion: Bool,
        eligible: Bool
    ) -> MarkPresentation
}
```

Every contested sentence in both spec docs becomes one row of a truth table:

- flag beats suppression
- unflagged suppressed waiting projects to idle
- flagged waiting replaces the dip, never stacks with it
- flagged working keeps the normal fill even under Static marks
- flagged idle and cold are still
- Reduce Motion zeroes `motion` for every input combination
- ineligible (offscreen, background, unselected, collapsed) zeroes `motion`

That is 4 x 2 x 2 x 2 x 2 x 2 = 128 combinations, exhaustively enumerable in a `c11-logic` test that runs in milliseconds and needs no host, no view, and no timing. It is the highest test value per line in the entire ticket, it satisfies the repo's "behavior not source text" test policy cleanly, and it is precisely the artifact C11-184 needs handed to it. The plan's Phase 4 currently tests the projector and the slot metrics: both worth having, neither touching the composition logic that is the actual ticket.

It also directly discharges the plan's own risk entry ("Modifier ambiguity: centralize projection/presentation priority so ... are testable and do not stack two motions"). Right now that risk has a mitigation sentence but no deliverable.

### Ship the dead flagged code with a way to see it

C11-183 builds the violet recolor, the alarm flash, and flag-beats-suppression, while C11-184 (explicitly out of scope) owns every primitive that could *set* `flagged` or `suppressed`. So this ticket ships several hundred lines of visual behavior that cannot be reached at runtime by any means, and hands them to a validation stage that has no way to trigger them. Nobody will look at the violet flash until C11-184, at which point it is old code with no memory attached.

Three options, cheapest to most:

1. **Defer the flag-tier visuals to C11-184.** Ship only the seam: fields defaulting false, `MarkPresentation.resolve` returning the flagged cases, and the truth-table test. C11-184 implements `alarmFlash` when it implements `raise-flag`. This is the tightest scope and the plan's own "forward-compatible seam" language already points at it.
2. **Add a two-line socket/debug override** that forces a surface's `(flagged, suppressed)` for the session, so the visuals are drivable now.
3. **Build a Marks debug window** (below).

I would take 1 or 3. Taking neither means shipping unverifiable pixels.

### The Marks contact sheet

The operator vetoed "a dedicated QA/performance harness," and that veto is right: a fleet benchmark rig is a project. But a **Debug menu window rendering the full mark matrix** is not that thing, and it is maybe sixty lines given the existing debug-window infrastructure in `skills/c11-debug-windows`:

- 4 states x {unflagged, flagged} x {unsuppressed, suppressed}, live-animating, at true 9pt
- a greyscale toggle (which is the ticket's stated accessibility acceptance criterion, currently checkable only by eye against a real fleet)
- a "render 200 marks" stepper

That last row is quietly the fleet-scale perf gate the spec demands, without a fleet: 200 animating leaves plus typing into any terminal in the same window is a strictly harsher test than 20 real agents, and it is reproducible on demand instead of requiring an orchestrated fleet spin-up. It also converts the deferred visual validation stage from "spin up agents, wait for states, screenshot, hope you caught waiting" into one screenshot.

I flag the scope tension honestly: this is additive work the operator's clarification leaned against. I think it is worth raising precisely because it makes the validation the operator *does* want cheap rather than expensive, and because the acceptance criterion "all four states distinguishable in greyscale" currently has no practical way to be checked.

---

## Mutations and Wild Ideas

**The vocabulary escapes the GUI.** Once shape carries state, the marks have exact text analogues: `▦` working, `▣` waiting, `□` idle, `▬` cold. Put them in `c11 tree`, `c11 list`, and the mailbox digest and the operator reads fleet state identically in the sidebar and in a terminal. For Overwatch, which routes across workspaces by reading CLI output, this is the difference between parsing state strings and glancing at a column. Cheap, and it makes the vocabulary a c11-wide language instead of a sidebar detail. (Note the CLI form is genuinely greyscale-only, which is a nice forcing function on the shape-alone claim.)

**Phase offset as identity, not just anti-sync.** The plan derives phase from stable UUID bytes purely to stagger the fleet. But a stable phase offset means a given agent's mark always ticks at the same point in the cycle, which over weeks becomes a weak identity cue: the operator learns "the one that ticks on the offbeat." Free, already implied by the design, worth not accidentally destroying with a re-randomize on relaunch. Derive from the surface UUID and it persists across sessions.

**The clock as a general c11 primitive.** Name it `C11AnimationClock`, not `ActivityMarkClock`. `SidebarDecayClock` already exists and does adjacent work. Tab flash (`flashGeneration`) is a hand-rolled one-shot. Staleness ticks poll. A single registration-based clock with eligibility gating could absorb all three over time, and the eligibility model (app-active, workspace-selected, pane-collapsed, viewport-intersecting) is the genuinely hard part being built here anyway. Build it once, generically, in c11.

**Typing as the fill source.** The working mark's typewriter fill is currently decorative: nine dots on a fixed 4s cycle regardless of what the agent is doing. c11 already sees PTY output volume. A fill driven by *actual output throughput* would make the mark say "how hard is this agent working," not just "it is working." Deliberately not for this ticket (it breaks the shared-clock coalescing model and probably the latency budget), but it is the obvious next mutation and worth not designing it out: keep `fillCount` an input rather than deriving it internally from phase, and this stays reachable later for free. This is one more argument for the pure-function mark.

**Motion hierarchy as a product claim.** The spec says "the fastest-moving thing in the sidebar is always the agent that needs the operator." That is a genuinely good idea and it is currently an emergent property of two independently chosen durations. Encode it: a single ordered table of (motion, period) where the invariant "attention period < working period" is asserted in the truth-table test. Then future motion additions cannot quietly break the hierarchy that is the entire point.

---

## What It Unlocks

- **C11-184 becomes small.** With `MarkPresentation.resolve` and the fields already on `WorkspacePulseAgent`, the flagged/suppressed ticket is metadata keys, socket methods, events, a sidebar row, and a banner. Zero renderer work. That is the difference between a two-week ticket and a three-day one.
- **The color channel is free, and opacity is still unspent.** Both spec docs say so explicitly. That is two unallocated visual channels on a primitive that appears next to every surface in the app. Worth being deliberate about what earns them (my instinct: opacity should stay unspent as long as possible; it is the only channel that composes multiplicatively with everything else and it is the easiest to spend badly).
- **A real accessibility claim.** The in-code comment currently lies. After this, "survives greyscale and a color-blind reader" is true and demonstrable. That is a legitimate upstream contribution to bonsplit and a legitimate public claim for c11.
- **An animation budget with a measurement.** Whatever the latency gate finds, c11 ends this ticket knowing what N animating leaves cost. Every future ambient-motion proposal gets priced against a real number instead of a fear.
- **A shared heartbeat.** See the clock mutation above. Nothing else in c11 can currently animate cheaply at fleet scale. After this, everything can.

---

## Sequencing and Compounding

The plan's order is Bonsplit shapes, then clock, then c11, then tests. Tests last is the weak link: the composition rules are the part most likely to be wrong, and they are validated at the very end, after two renderers already encode them.

**Better order:**

1. **`MarkPresentation.resolve` plus its exhaustive truth-table test, first.** Pure Swift, no views, no submodule, runs in `c11-logic` in under a second. This is where the spec ambiguities surface, and surfacing them before any pixel is drawn is worth a lot. If the operator's clarification and the two docs disagree anywhere (they do, in places: the docs' "breathe" is removed by the clarification but still appears in prose), the truth table is where that becomes undeniable.
2. **Bonsplit pure shape view, public, phase as input.** One commit, one push, ancestry proof, one pointer commit. Done with the submodule for the rest of the ticket.
3. **c11 clock plus eligibility gating**, with the marks still static. Verify registration, unregistration, and stop-on-idle before anything moves.
4. **Wire motion.** Now everything underneath is tested and the only new risk is timing.
5. **Metrics/slot floor**, in a `c11-logic`-member file. Independent of the above, parallelizable.

Step 1 is the compounding one: it is the artifact C11-184 consumes, it is the artifact review reads to check the spec, and it is the artifact that makes step 4 a wiring exercise rather than a design exercise.

**Under-invest:** the flag-tier visuals (defer to C11-184, per above). **Over-invest relative to the plan:** the eligibility/registration model, because it is the piece with the longest reuse tail and the piece that is genuinely hard to retrofit.

---

## The Flywheel

There is one available and the plan does not reach for it.

**The vocabulary is a language, and languages compound with surface count.** Every additional surface that speaks it makes the vocabulary more valuable to learn, and a vocabulary the operator has already learned makes each new surface cheaper to add. Sidebar plus tab chips is two surfaces and no flywheel. Add the notifications list, the menu bar extra, `c11 tree`, and the Overwatch digest, and each addition raises the return on all the others. The operator learns four shapes once and reads agent state everywhere, including over SSH, including in an agent's own tool output.

The move that sets it spinning is small and it is the same move that fixes the drift risk: **one public, shared, pure-function mark renderer plus one text analogue**, rather than two hand-copied SwiftUI bodies. Once the mark is a component instead of a duplicated view body, the marginal cost of a fifth surface is a single call site. Once it is two duplicated bodies, the marginal cost of a fifth surface is a third copy, and nobody pays it.

Secondary loop: **cheap validation increases motion appetite.** If the contact sheet exists, checking any motion change is a screenshot. If it does not, checking any motion change is a fleet spin-up. The former means the motion hierarchy gets tuned until it is genuinely good; the latter means it ships at whatever the first plausible values were and never moves again.

---

## Concrete Suggestions

Ordered by value per unit of effort.

1. **Fix G1 before writing more code.** Move the slot-floor assertions into a `c11LogicTests` member file. The plan's verification command is currently unrunnable, and the plan forbids the only run that would exercise it.
2. **Add `MarkPresentation.resolve` and its exhaustive truth-table test.** ~40 lines of implementation, ~30 of test, discharges an existing Risks entry, and is the deliverable C11-184 most needs.
3. **Invert the Bonsplit relationship:** public pure-function mark taking `fillCount` / `coreOpacity` / `side`, no clock in the submodule, c11 imports and renders the same view in the sidebar. Removes the geometry-drift risk class, removes the second submodule cycle, shrinks the c11 diff, and makes the upstream offer stronger.
4. **Keep the clock in c11 and name it generically.** `C11AnimationClock` with token-based registration and eligibility gating.
5. **Defer the flag-tier visuals to C11-184**, keeping only the fields, the resolve cases, and the tests. Or build the contact sheet so they are visible. Do not ship them blind.
6. **Resolve the 10pt summary mark (G3) explicitly** and say which way you went in the handoff.
7. **Adjust the existing `WorkspacePulseMarkRowMetricsTests` overflow expectations (G2)** deliberately, with a comment saying the ladder shifted because `minimumSlot` rose, rather than tuning numbers until green.
8. **Name the CI obligation (G5).** "No PR" plus "no host tests" plus "no tagged launch" equals no verified signal. Say who opens the draft PR and when, or the review stage inherits an unverified branch.
9. **Say something about chrome scale (G6)**, even if the answer is "marks defy it by design."
10. **Text analogues for the four states in CLI output.** Two hours, and it is the first turn of the flywheel.

---

## Questions for the Plan Author

1. **Why does the clock live in Bonsplit rather than c11?** The plan asserts it stays "upstream-clean" as a generic renderer primitive, but a vendored tab-bar library owning the host app's animation heartbeat is a layering inversion, and it makes every future timing tweak a two-repo operation. What breaks if Bonsplit takes phase as an input the way it already takes `flashGeneration`?

2. **Should the two renderers share a view or share constants?** The plan chooses constants plus side-by-side diff review. Sharing the actual view is strictly stronger and c11 already imports Bonsplit. What is the objection?

3. **Do the flag-tier visuals ship in C11-183 at all?** They cannot be triggered by anything this ticket builds, and C11-184 owns every primitive that would set the fields. Is there value in shipping them ahead of a way to see them, or is the seam plus the truth table the right scope?

4. **Is a Debug-menu mark contact sheet inside or outside the operator's "no QA harness" veto?** It is ~60 lines, it makes the greyscale acceptance criterion checkable, and it is a harsher fleet-scale perf test than a real fleet. I read the veto as aimed at a benchmark rig, not this, but that is your call to confirm with the operator.

5. **What happens to the 10pt summary mark?** Drop it to 9 and change a surface the ticket does not mention, or scale the grid and lose pixel alignment?

6. **Do marks honor chrome scale?** "Pin to 9pt always" and a user-adjustable chrome scale are in tension, and neither doc resolves it.

7. **Who runs CI, and when?** With no PR and no host tests, the branch reaches review with essentially no verified test signal. Is a draft PR acceptable, or should the delegator trigger the workflow directly?

8. **Is the phase offset intended to be stable across app relaunches?** Deriving from the surface UUID makes it so, which is a small, free identity cue. Worth confirming it is intended rather than incidental.

9. **The docs still describe a "breathe" motion for flagged non-waiting states; the operator clarification removes it.** The plan handles this correctly in its precedence section, but the docs themselves are now stale. Does this ticket correct `docs/c11-mark-vocabulary.md` and `docs/c11-flagged-agent-plan.md`, or does that fall to C11-184? Leaving two specs describing motion that will not exist is how the next agent gets it wrong.

10. **How far do you want the vocabulary to travel?** If the answer is "eventually everywhere, including CLI output," several structural choices in this ticket (shared component versus duplicated bodies, presentation as an object versus view-body conditionals) should be made differently now, at near-zero extra cost, rather than retrofitted later at real cost.
