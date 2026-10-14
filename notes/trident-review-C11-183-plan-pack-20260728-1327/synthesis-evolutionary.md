# Synthesis: Evolutionary/Exploratory Reviews of the C11-183 Plan

Ticket: C11-183 "Rebuild agent-state mark vocabulary: lifecycle in shape alone"
Plan: `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md`
Sources: `evolutionary-claude.md`, `evolutionary-codex.md`, `evolutionary-gemini.md`
Synthesized: 2026-07-28

---

## Executive Summary

1. **All three reviewers agree the plan is directionally right and structurally undersold.** Nobody thinks it fails. All three think it succeeds at a smaller thing than it could, because it frames the ticket as "make two renderers agree on four glyphs" when the ticket is actually where c11 acquires (a) a formal state-presentation language, (b) an app-level animation clock with eligibility gating, and (c) a testable modifier composition seam.

2. **The single strongest consensus recommendation is to make the composition rules a pure object.** Claude proposes `MarkPresentation.resolve(...)`, Codex proposes `ActivityMarkPresentation.resolve(...)`; both want `(state, flagged, suppressed, staticPreference, reduceMotion, eligible) -> (effectiveState, color role, motion channel, phase)` plus an exhaustive table-driven test in `c11-logic`. The plan's own Risks section names this need ("centralize projection/presentation priority so ... are testable") but Phase 4 never produces the object. This is the cheapest high-value change on the table and it is the artifact C11-184 most needs.

3. **The second strongest consensus is to eliminate geometry duplication structurally.** The plan's mitigation for drift is "same named constants plus side-by-side diff review." Claude and Codex independently call this a promise nobody keeps for two years and both recommend one shared public Bonsplit mark leaf (or, as Codex's fallback, a public geometry/phase kernel with two thin adapters) rendered by both call sites.

4. **The three disagree productively on where the clock lives.** Claude wants it inverted out of the submodule entirely (`C11AnimationClock` in c11, phase passed into Bonsplit the way `flashGeneration` already is). Codex wants it split into a pure phase model plus a registration broker, agnostic about repo. Gemini wants it generalized in place as a `WorkspaceMetronome`. All three reject "a vendored tab-bar library owns the host app's heartbeat" as the final shape.

5. **Two reviewers found executability defects that will bite during implementation.** Most urgently, Claude verified against the repo that `WorkspacePulseMarkRowMetricsTests` lives in a `c11Tests`-only target, so the plan's own verification command (`-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests`) cannot match, and the plan forbids the host-bound run that would exercise it. Codex independently found a missing truth-table row (unflagged suppressed **working** must also be static), a prose-versus-mock timing contradiction, an unsafe submodule pointer sequence, and a repository-policy conflict on localization.

6. **All three flag a sequencing inversion.** Tests and the risky part come last in the current plan. Claude wants the resolver plus truth table first; Codex wants the truth table and exact phase equations frozen before any view code; Gemini wants the clock de-risked against the latency gate first, since the latency gate is the hard ship blocker. Different first steps, same critique: the plan validates its riskiest content last.

7. **The shared flywheel thesis: the vocabulary is a language, and languages compound with surface count.** Two renderers is not a flywheel. A shared pure-function mark plus text analogues in CLI output makes the marginal cost of a fifth surface one call site, and Gemini adds the demand-side loop: cheaper peripheral reads raise the fleet size the operator is willing to run, which makes the vocabulary more valuable still.

---

## 1. Consensus Direction

Evolution paths that two or three models identified independently.

1. **Presentation resolution should be a pure, centralized function, not view-body conditionals.** (Claude, Codex; Gemini implies it through "semantic geometric protocol.") Inputs: lifecycle state, `flagged`, `suppressed`, `Static marks`, Reduce Motion, eligibility. Outputs: effective state, color role, motion channel, phase. Every contested sentence in both spec docs becomes one row of a table. Claude counts 128 combinations, exhaustively enumerable, no host, no views, no timing, milliseconds to run.

2. **The two renderers should share an implementation, not share constants.** (Claude, Codex.) c11 already imports Bonsplit in five files including `c11App.swift`. Rendering the same view instance removes the drift bug class instead of mitigating it. Codex's fallback if a public SwiftUI view is judged too large an API commitment: a public pure geometry/phase kernel plus two thin drawing adapters.

3. **The clock is general infrastructure and should be named and shaped as such.** (All three.) Claude: `C11AnimationClock`, host-side, absorbing `SidebarDecayClock`, tab flash, staleness ticks over time. Codex: split into a pure phase model plus a registration broker that arms one timer for the earliest required transition. Gemini: a generic `WorkspaceMetronome` publisher other ambient systems can tap. The convergent point is that the eligibility/registration model (app-active, workspace-selected, pane-not-collapsed, viewport-intersecting) is the genuinely hard and genuinely reusable part.

4. **Bonsplit's package API should stay generic; c11 attention semantics should not leak into it.** (Claude, Codex.) The plan calls Phase 1 an "upstream-clean vocabulary" while adding `flagged` and `suppressed` inputs to Bonsplit; those are c11 attention-model names. Keep the upstream-offerable commit genuinely shape-only and pass resolved tint/motion tokens rather than c11 concepts.

5. **The flag-tier visuals ship blind under the current scope.** (Claude explicit; Codex asks the same as a question.) C11-183 builds the violet recolor, the alarm flash, and flag-beats-suppression, while C11-184 owns every primitive that could set `flagged` or `suppressed`. Nothing this ticket builds can trigger the visuals, and the validation stage has no way to see them. Either defer them to C11-184 (keeping fields, resolve cases, and tests), or build a way to see them.

6. **Validation ownership is under-specified and the evidence chain is thin.** (Claude, Codex; Gemini via "formalize the fallback.") No PR means no CI, no host tests, no tagged launch, no visual check. Codex enumerates the validator's owned pre-merge gate in detail; Claude names it as an explicit handoff obligation on the orchestrator; Gemini wants the degradation ladder to be built-in configuration rather than a manual revert.

7. **Sequencing should front-load the risky content.** (All three, with different picks for "riskiest": composition rules for Claude, exact phase equations and truth table for Codex, clock latency profile for Gemini.)

8. **The vocabulary is portable beyond the two renderers named in the ticket.** (Claude: notifications list, command palette, menu bar extra, `c11 tree`, Overwatch digests. Codex: markdown dashboards, remote workspace summaries, companion clients. Gemini: peripheral-vision reading at fleet scale.) Structural choices made now at near-zero cost determine whether that portability is free later or a retrofit.

---

## 2. Best Concrete Suggestions

Ordered by value per unit of effort, merged across all three reviews. Items 1 through 5 are the ones I would not ship without.

1. **Fix the unrunnable verification command before writing more code.** (Claude, G1, verified against `project.pbxproj` at `ba1382a6c`.) `c11Tests/SidebarActivityProjectorTests.swift` is a `c11LogicTests` member; `c11Tests/WorkspaceUnitTests.swift` is `c11Tests` only. `WorkspacePulseMarkRowMetricsTests` sits at `WorkspaceUnitTests.swift:2472` and is reachable only from the host-bound suite the plan forbids. Cheapest fix: put the new 9pt slot-floor assertions in a file already in `c11LogicTests` (`WorkspaceContentViewVisibilityTests.swift` or `SidebarWidthPolicyTests.swift`, both thematically adjacent). Do not silently drop the assertion. This is the exact disk-versus-target confusion that caused C11-105.

2. **Add `MarkPresentation.resolve(...)` plus an exhaustive truth-table test.** (Claude, Codex.) Roughly 40 lines of implementation and 30 of test. Discharges an existing Risks entry that currently has a mitigation sentence and no deliverable. Satisfies the repo's "behavior not source text" test policy cleanly. Is the handoff artifact for C11-184.

3. **Complete the precedence ladder, including the row the plan is missing.** (Codex.) The plan states "unflagged suppressed waiting projects to idle" but the spec requires that *every* unflagged suppressed mark is static. A suppressed **working** surface must show the full static grid, not participate in the 4-second fill. Codex's ten-rung ladder, in order: (1) project unflagged suppressed waiting to idle; (2) flag defeats that projection; (3) Reduce Motion forces static for every combination; (4) ineligible leaves are static and unregistered; (5) flagged waiting uses the 0.4s core flash; (6) flagged working uses the normal fill even under `Static marks`; (7) flagged idle and cold are static; (8) any unflagged suppressed state is static; (9) `Static marks` disables remaining base motion; (10) otherwise working fills, waiting dips, idle and cold stay still.

4. **Invert the Bonsplit relationship: pure public mark, no clock in the submodule.** (Claude; Codex's variant.) Signature Claude proposes:

   ```swift
   public struct BonsplitActivityMark: View {
       public let state: BonsplitTabActivityState
       public let color: Color
       public let fillCount: Int      // 0..9 filled dots for .running
       public let coreOpacity: Double // core multiplier for .waiting
       public let side: CGFloat
       // pure function of inputs. no timer, no @State, no environment.
   }
   ```

   Consequences: geometry drift becomes structurally impossible; Phase 2's cross-module clock protocol largely disappears; one Bonsplit commit instead of two, so the second submodule ancestry cycle dissolves; the upstream offer gets stronger, because a dependency-free accessibility-correct glyph that takes phase as input is easier for a maintainer to accept than one shipping a timer; post-gate timing tweaks become one-repo edits. Precedent already in the tree: `flashGeneration: Int` on `TabItemView` is exactly "host computes the animation signal, Bonsplit renders it."

5. **Fix the submodule sequence so the parent pointer is committed once, at the end.** (Codex, Claude G4.) The current plan proves ancestry and commits the pointer after Phase 1, then Phase 2 modifies Bonsplit again with no explicit push/ancestry gate on the final HEAD. Either fold all Bonsplit work into one pass before any push, or state the full eight-step ritual twice. Record the shape-only commit SHA separately for the upstream-offer note so upstream does not have to absorb c11's clock and policy work.

6. **Define the host-to-Bonsplit policy pipe explicitly.** (Codex.) `@AppStorage` in `c11App.swift` does not make Bonsplit's `TabActivityMark` react. Build on the existing pattern where `Workspace` constructs `BonsplitConfiguration.Appearance` and live UserDefaults observers mutate and reassign it for chrome scale and tab ordinals: add a `StaticMarkSettings` seam owning key and default; add an activity-mark motion policy to `Appearance` **distinct from** the existing `enableAnimations`, which c11 already sets false for split-layout animation; have `Workspace` initialize and observe it; have the c11 leaf read the same setting leaf-locally, never through the equatable `TabItemView`. Prove that toggling the setting registers and unregisters leaves without an app restart.

7. **Observe Reduce Motion live, not once.** (Codex, Gemini.) Querying `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` once is insufficient. The clock/policy owner should observe the accessibility-display-options notification and synchronously drain all registrations when Reduce Motion turns on.

8. **Resolve the working-cycle timing contradiction before coding it twice.** (Codex.) The plan says "nine dots over the 4-second cycle, then a full hold"; the binding mock turns rank `i` on at `i * 10%` with all dots on by roughly 81% and holds to the 4-second reset; other prose says nine cells over about 3.6 seconds. These are three different phase definitions. Freeze one formula, plus: whether the first dot is present at cycle start or after the first beat, the exact hold duration, the hard reset boundary, the 1.2s dip endpoints and easing, and the 0.4s flash's exact 50% edge.

9. **Make visibility an explicit data flow rather than a leaf inference.** (Codex.) `TabBarView` currently tracks scroll offset and container width and records only the selected tab's frame. Collect full-tier tab frames in the existing named `tabScroll` coordinate space via a UUID-keyed preference dictionary, intersect with the unobscured viewport (including the region behind trailing chrome), pass a plain `Bool` into each leaf, keep collapsed chips and dropdown rows static, and update the set only on scroll/layout/tier changes, never on clock ticks or keystrokes.

10. **Adjust the existing overflow-ladder expectations deliberately.** (Claude, G2.) `WorkspacePulseMarkRowMetrics.layout` computes `stride = minimumSlot + minimumSpacing`; 8 to 9 makes stride 10 to 11, so `+N` overflow starts one or two marks earlier at any width. `WorkspaceUnitTests.swift:2512-2545` encodes the old ladder. The plan mentions adjusting Bonsplit's tests but not these. Change them with a comment explaining the ladder shifted, rather than tuning numbers until green.

11. **Resolve the 10pt summary mark explicitly.** (Claude, G3.) `workspacePulseMark(for:summaryScale:side:)` at `Sources/ContentView.swift:11816` uses `side = summaryScale ? 10 : 9` inside a 16x16 frame. A 3pt-pitch 3x3 grid tiles exactly into 9pt and not into 10pt. Either drop the summary row to 9pt (a visible change to a surface the ticket never mentions) or scale the grid and lose the hard-edged pixel alignment that is the whole idiom. The plan asserts "same renderer seam" without noticing the call sites disagree.

12. **Own the six-locale `Localizable.xcstrings` update inside this stage.** (Codex.) "Do not modify the catalog; leave a translation-stage note" conflicts with the repository's hard localization rule for a new user-facing setting. The project convention is to delegate translation to parallel sub-agents, so this is cheap; it should not be deferred to an unnamed later stage.

13. **Specify an explicit stable UUID-byte phase-offset function and test it.** (Codex; the plan already forbids Swift `Hasher`, but does not define the replacement.) Claude adds: derive from the surface UUID so the offset persists across relaunches.

14. **Name the CI obligation.** (Claude, G5.) No PR plus no host tests plus no tagged launch equals no verified signal, and `CLAUDE.md` warns some `c11-logic` classes crash under the bare local runner and are trustworthy only in CI. Say who opens the draft PR (or triggers `gh workflow run`) and when, or review inherits an unverified branch.

15. **Write down the chrome-scale decision.** (Claude, G6.) c11 ships `ChromeScaleTokens` / `ChromeScaleSettings` / `ChromeScaleObserver`. "Marks pin to 9pt always" and a user-adjustable chrome scale are in tension. Even "marks defy chrome scale by design" is a sufficient answer; silence forces review to reverse-engineer it.

16. **Handle VoiceOver, not just color-blindness.** (Gemini, unique to it.) Set `accessibilityLabel` on state changes in the leaf, and aggressively debounce announcements so a 0.4s flashing flag does not spam the screen reader. The ticket's accessibility framing currently covers only the visual channel.

17. **Build the degradation ladder as configuration, not as a manual revert.** (Gemini; Codex's ladder procedure agrees.) If the render loop exceeds a frame budget, dip-only and then static should be reachable by a flag, with the recorded decision applying a predefined ladder rather than a hand revert under time pressure.

18. **Correct the stale spec docs.** (Claude, Q9.) `docs/c11-mark-vocabulary.md` and `docs/c11-flagged-agent-plan.md` still describe a "breathe" motion the operator clarification removed. The plan's precedence section handles it correctly, but leaving two specs describing motion that will not exist is how the next agent gets it wrong.

19. **Add text analogues for the four states in CLI output.** (Claude.) `▦` working, `▣` waiting, `□` idle, `▬` cold in `c11 tree`, `c11 list`, and the mailbox digest. Roughly two hours. The CLI form is genuinely greyscale-only, which is a useful forcing function on the shape-alone claim, and it is the first turn of the flywheel.

20. **Build a Debug-menu mark contact sheet** (Claude, roughly 60 lines given `skills/c11-debug-windows`): 4 states x {unflagged, flagged} x {unsuppressed, suppressed}, live-animating at true 9pt, plus a greyscale toggle and a "render 200 marks" stepper. The greyscale toggle makes the ticket's stated accessibility acceptance criterion checkable at all; the 200-mark stepper is a harsher fleet-scale perf test than 20 real agents and is reproducible on demand. Claude flags honestly that this sits near the operator's "no QA harness" veto and reads the veto as aimed at a benchmark rig rather than this. Codex's variant: make the phase source injectable in DEBUG so a reviewer can freeze all marks at phase 0, mid-fill, full-hold, dip-minimum, and flash-white.

---

## 3. Wildest Mutations

Ambitious or risky ideas, most defensible first. None of these belong in C11-183 as scoped; several are cheap to keep reachable.

1. **Throughput-coupled motion.** (Claude and Gemini, independently, and both call it the obvious next mutation.) The working mark's fill is currently decorative: nine dots on a fixed cycle regardless of what the agent is doing. c11 already sees PTY output volume. A fill driven by actual output throughput makes the mark say "how hard is this agent working," not just "it is working." Gemini's framing: a fast-typing agent fills rapidly, a heavily thinking agent fills slowly, immense qualitative telemetry at zero additional geometry. Deliberately out of scope (it breaks shared-clock coalescing and probably the latency budget), but keeping `fillCount` an input rather than deriving it internally from phase keeps it free later. This is one more argument for the pure-function mark.

2. **The vocabulary escapes the GUI.** (Claude.) Text analogues in `c11 tree`, `c11 list`, and the mailbox digest mean the operator reads fleet state identically in the sidebar and over SSH. For Overwatch, which routes across workspaces by reading CLI output, this is the difference between parsing state strings and glancing at a column.

3. **Spatial cohesion instead of anti-sync scatter.** (Gemini, and it directly contradicts both the plan and Claude.) Offset animation phase by the surface's sorted layout index rather than a stable UUID hash, turning 20 independent blinking marks into a cascading wave down the sidebar: a unified entity rather than a chaotic scatter-plot. Risk: layout-index phase is unstable across reorder and loses the identity property below, and a synchronized wave may read as more visually active than a scatter, not less.

4. **Phase offset as weak identity.** (Claude, the direct counter to #3.) A stable per-agent offset means a given agent's mark always ticks at the same point in the cycle, which over weeks becomes an identity cue: "the one that ticks on the offbeat." Free, already implied, worth not destroying with a re-randomize on relaunch. These two ideas are mutually exclusive and the choice is a real product decision.

5. **The 9-pixel agent display.** (Gemini.) If working is a 3x3 grid of dots, every agent now has a tiny 9-pixel display. An agent could eventually push a 3x3 bitmap to its own mark through the skill: a mini progress bar, distinct patterns for "compiling" versus "searching." Genuinely wild, and it collides head-on with "shape is exclusively the carrier for state," which is the ticket's whole thesis. Worth noting as a tension rather than a plan.

6. **Motion hierarchy as an asserted product claim.** (Claude.) The spec says "the fastest-moving thing in the sidebar is always the agent that needs the operator." Today that is an emergent property of two independently chosen durations. Encode it as a single ordered (motion, period) table with "attention period < working period" asserted in the truth-table test, so future motion additions cannot quietly break the hierarchy that is the entire point.

7. **A global chrome animation budget.** (Codex.) The registration broker naturally knows the count and cadence of live animations. A future policy could expose that count to diagnostics or conservatively degrade motion under energy pressure. Codex is explicit: do not make this adaptive in C11-183, collect evidence first.

8. **An animation eligibility inspector.** (Codex.) A lightweight debug overlay or log showing `surface -> registered channel -> reason eligible/ineligible`. Makes offscreen battery bugs diagnosable and is reusable for any other animated chrome.

9. **Sonar.** (Gemini.) With states decoupled and a global clock running, c11 could emit extremely subtle spatialized audio cues when an agent enters the needs-attention state, pitched by position in the workspace. The most speculative idea in the pack; noted for completeness, and it does follow logically from "attention has its own channel."

10. **Upstream accessibility kit.** (Codex, Claude.) The pure shape commit is a credible Bonsplit upstream contribution. If accepted, upstream improvements return through normal submodule updates and c11 carries less fork-only rendering code.

---

## 4. Flywheel Opportunities

Self-reinforcing loops identified across the three reviews.

1. **The language flywheel (Claude, the strongest single one).** A vocabulary compounds with surface count: every additional surface that speaks it makes the vocabulary more valuable to learn, and a vocabulary already learned makes each new surface cheaper to add. Sidebar plus tab chips is two surfaces and no flywheel. Add the notifications list, menu bar extra, `c11 tree`, and Overwatch digests and each addition raises the return on all the others. **The move that starts it spinning is the same move that kills the drift risk:** one public shared pure-function mark plus one text analogue. With a shared component the marginal cost of a fifth surface is one call site; with two duplicated view bodies it is a third copy, and nobody pays it.

2. **The density flywheel (Gemini, the demand-side counterpart).** Operators run few agents partly because the visual cost of checking states is high. Peripheral-readable geometry drops the per-agent cognitive cost, which allows 10 then 20 concurrent agents, which makes the spatial phase structure more legible and useful, which drops cognitive cost further. This is the loop that connects the ticket to c11's actual product thesis.

3. **The correctness flywheel (Codex).** One presentation truth table leads to one shared geometry and phase implementation, which makes modifier and renderer additions cheaper, which means less drift and fewer hot-path regressions, which builds confidence to run marks at fleet scale, which produces better real performance evidence, which sharpens scheduling and eligibility policy, which makes default-on motion safer.

4. **The upstream flywheel (Codex, Claude).** A shape-only accessibility commit is a clean Bonsplit upstream offer, which invites broader review and reuse, which keeps upstream fixes cherry-pickable, which means c11 carries less fork-only rendering code, which keeps future syncs cheap. The plan accelerates this only if the shape commit is genuinely separated from c11 attention semantics.

5. **The cheap-validation flywheel (Claude, secondary but practically decisive).** If the contact sheet exists, checking any motion change is one screenshot; if it does not, checking any motion change is a fleet spin-up. The former means the motion hierarchy gets tuned until it is genuinely good. The latter means it ships at whatever the first plausible values were and never moves again.

6. **The animation-budget flywheel (Claude, Codex).** Whatever the latency gate finds, c11 ends this ticket knowing what N animating leaves cost. Every future ambient-motion proposal then gets priced against a real number instead of a fear, and registration counts become the first direct evidence about the cost of animated agent fleets.

---

## 5. Strategic Questions for the Plan Author

Deduplicated and merged across all three reviews. Attribution in parentheses; C = Claude, X = Codex, G = Gemini.

### Architecture and layering

1. **Why does the clock live in Bonsplit rather than c11?** A vendored tab-bar library owning the host app's animation heartbeat is a layering inversion, and it makes every future timing tweak a two-repo operation. What breaks if Bonsplit takes phase as an input the way it already takes `flashGeneration`? (C1, G-adjacent)

2. **Should the two renderers share a view or share constants?** If a public Bonsplit SwiftUI mark view is too large an API commitment, is a public geometry/phase kernel with two thin drawing adapters acceptable instead? What is the objection to sharing the actual view, given c11 already imports Bonsplit? (C2, X2)

3. **Is the Bonsplit API allowed to name `flagged` and `suppressed`, or must the package stay generic and accept resolved tint/motion tokens from c11?** The plan calls Phase 1 "upstream-clean" while adding c11 attention-model names to it. (X3)

4. **Is the intended upstream offer the shape-only commit or the final shape-plus-clock Bonsplit history?** If the former, will its SHA be recorded separately? (X12)

5. **Where exactly does the `Static marks` value cross from c11 into already-mounted Bonsplit tab bars, and how are existing workspaces updated live?** Will it reuse the `Workspace` + `BonsplitConfiguration.Appearance` observer pattern, and will it be a policy field distinct from the existing `enableAnimations` that c11 already sets false? (X1, X-suggestion 3)

### Specification and truth table

6. **Will the resolver explicitly force unflagged suppressed *working* to the static full grid?** The plan's contract covers only suppressed waiting; the spec requires every unflagged suppressed mark to be static. (X5)

7. **Which timing source wins where the live mock's keyframes and the prose disagree, and what are the exact working beat and hold boundaries?** Also: is the first dot present at cycle start or after the first beat; what is the exact hold duration and reset boundary; what are the 1.2s dip endpoints and easing; and where exactly is the 0.4s flash's 50% edge? (X4)

8. **Will `MarkPresentation.resolve` plus an exhaustive truth table be added, and does it also assert the motion hierarchy invariant** ("attention period < working period") so future motion additions cannot break the claim the spec makes? (C, X, both)

9. **Do the flag-tier visuals ship in C11-183 at all?** Nothing this ticket builds can set `flagged` or `suppressed`, and C11-184 owns every primitive that would. Is there value in shipping visuals ahead of a way to see them, or is the seam plus truth table the right scope? (C3, X14)

10. **The docs still describe a "breathe" motion the operator clarification removed. Does this ticket correct `docs/c11-mark-vocabulary.md` and `docs/c11-flagged-agent-plan.md`, or does that fall to C11-184?** (C9)

### Clock, phase, and eligibility

11. **What is the exact stable UUID-byte phase-offset function, and is the offset intended to be stable across app relaunches?** Deriving from the surface UUID makes it so and yields a free identity cue. (C8, X6)

12. **Should phase offset be UUID-derived (anti-sync, per-agent identity) or layout-index-derived (a cohesive top-to-bottom wave)?** These are mutually exclusive and it is a product decision, not an implementation detail. (G1 versus C)

13. **Is the design a single publishing clock, or a pure phase model plus a registration broker that arms one timer for the earliest required transition?** A singleton publishing a date at high cadence still invalidates every subscriber on every tick. (X, architectural)

14. **What concrete mechanism observes live Reduce Motion changes and drains the shared clock's registrations?** A one-time query at setup is insufficient. (X6, G2)

15. **Does the clock respect macOS App Nap and display sleep, or does it rely purely on SwiftUI `onAppear`/`onDisappear`, which is unreliable in complex split views?** (G2)

16. **What exact coordinate space and frame-preference data define a "scrolled out" tab, including the region obscured by trailing chrome?** (X7)

### Sizing, surfaces, and accessibility

17. **What happens to the 10pt summary mark?** Drop it to 9 and change a surface the ticket does not mention, or scale the grid and lose the pixel alignment that is the idiom? (C5)

18. **Do marks honor chrome scale, or defy it by design?** Neither doc resolves the tension between "pin to 9pt always" and a user-adjustable chrome scale. (C6)

19. **How will VoiceOver handle the 0.4s violet/white alarm flash and lifecycle transitions generally, and how are announcements throttled?** (G3)

### Verification, delivery, and scope

20. **The plan's verification command targets `c11LogicTests/WorkspacePulseMarkRowMetricsTests`, but that class lives in a `c11Tests`-only file and the plan forbids the host-bound run. How will the slot-floor assertions actually be exercised?** (C, G1; blocking)

21. **Why does the current sequence commit the parent submodule pointer after Phase 1 when Phase 2 still modifies Bonsplit?** (C4, X11)

22. **Who runs CI, and when?** With no PR, no host tests, and no tagged launch, the branch reaches review with essentially no verified signal. Is a draft PR acceptable, or should the delegator trigger the workflow directly? (C7)

23. **Who owns the tagged validation stage, and where will its true-size, greyscale, visibility-gating, and latency evidence be recorded?** What objective typing-latency metric and regression bound makes the fleet-scale gate pass or fail? (X8, X9)

24. **If the shared clock fails the fleet-scale latency gate, what is the exact code-level degradation mechanism?** Is the ladder (fill-off, then dip-off, then fully static) built into configuration, or is it a manual revert? And if the fill fails while the dip passes, how does the shipping default change while keeping the `Static marks` copy truthful? (G1, X10)

25. **Is a Debug-menu mark contact sheet inside or outside the operator's "no QA harness" veto?** It is roughly 60 lines, it is the only practical way to check the greyscale acceptance criterion, and a 200-mark stepper is a harsher perf test than a real fleet. (C4)

26. **Can the plan be amended to own the six-locale `Localizable.xcstrings` update rather than deferring it?** The current instruction conflicts with the repository's hard localization rule for a new user-facing setting. (X13)

27. **How far do you want the vocabulary to travel?** If the answer is "eventually everywhere, including CLI output," then shared component versus duplicated bodies, and presentation-as-object versus view-body conditionals, should be decided differently now at near-zero cost rather than retrofitted later at real cost. (C10)

---

## Appendix: Recommended Resequencing (merged)

The three reviewers propose three different first steps. Merged, in dependency order:

1. **Freeze the truth table and the exact phase equations.** Resolve suppressed-working, the full precedence ladder, and the mock-versus-prose timing discrepancy before any view code. (X1, C1)
2. **Build the pure presentation and phase kernel plus its table-driven test.** Pure Swift, no views, no submodule, runs in `c11-logic` in under a second. This is where spec ambiguities surface, and surfacing them before any pixel is drawn is worth a lot. (C1, X2)
3. **De-risk the clock's latency profile early with a dummy leaf,** since the latency gate is the hard ship blocker and discovering a failure after the geometry is perfectly tuned is the expensive ordering. (G)
4. **Land the Bonsplit shape-only commit.** Public, phase-as-input, genuinely upstream-offerable, no c11 attention names. (C2, X3)
5. **Build the c11 clock plus eligibility gating with marks still static.** Verify registration, unregistration, and stop-on-idle before anything moves. (C3, X4)
6. **Wire motion.** Everything underneath is now tested; the only new risk is timing. (C4)
7. **Metrics and 9pt slot floor, in a `c11LogicTests`-member file.** Independent of the above and parallelizable. (C5)
8. **Localize the setting in all seven locales as part of implementation completion.** (X6)
9. **Push and prove ancestry on the final Bonsplit HEAD, then commit the parent pointer once, then push the parent branch.** (X8, X9)
10. **Fresh review, then tagged running-system validation with the fleet-scale latency and ladder gate, with a named owner and an evidence artifact.** (X10, C, G)

**Under-invest** relative to the plan: flag-tier visuals (defer to C11-184, keep the seam and the tests). **Over-invest** relative to the plan: the eligibility and registration model, because it has the longest reuse tail and is the hardest thing here to retrofit.
