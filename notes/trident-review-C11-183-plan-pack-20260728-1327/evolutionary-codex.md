### Executive Summary

The biggest opportunity is not merely a better set of four glyphs. C11-183 can create a small, deterministic **agent-mark presentation engine**: lifecycle and modifiers enter on one side; geometry, color, motion channel, phase, and animation eligibility emerge on the other. That engine would make the two current renderers agree by construction, give C11-184 a narrow wiring job, and establish a reusable power/performance boundary for animated chrome.

The current plan is directionally strong: it preserves the four-state lifecycle, separates shape from color, keeps animation out of typing-hot parents, uses one clock, includes offscreen/background gates, respects Reduce Motion, and honors the operator’s “no breathe” override. It is not yet fully executable as written, though. Five gaps should be amended before the implementation is treated as plan-complete:

1. There is no defined reactive path from the c11 `Static marks` preference into Bonsplit’s internal tab renderer.
2. The modifier truth table is incomplete: unflagged suppressed **working** must also be static, not only suppressed waiting.
3. The working-cycle prose is ambiguous and disagrees with the live mock’s actual keyframes.
4. The submodule sequence proves and commits the pointer after Phase 1 even though Phase 2 changes Bonsplit again; the final Phase 2 commit has no explicit push/ancestry gate.
5. The plan defers all tagged fleet-scale latency work, despite the ticket and operator clarification requiring proportionate tagged-build validation and the spec making that a hard pre-merge gate.

There is also a direct repository-policy conflict: “do not modify `Localizable.xcstrings`; leave a translation-stage note” does not satisfy the hard localization rule for a new user-facing setting. The six translations must be part of the owned delivery sequence.

The best evolution is to make presentation resolution pure and centralized, make rendering shared or token-driven, and make the shared clock only an execution mechanism for an already-tested deterministic phase model.

### What's Really Being Built

At the surface, this is a 9pt accessibility repair. Underneath, it is the first declarative visual grammar for agent attention in c11.

That grammar has three independent axes:

- lifecycle: waiting, working, idle, cold;
- attention modifiers: flagged and suppressed;
- execution policy: static preference, Reduce Motion, app activity, selection, collapse, and viewport visibility.

The plan currently distributes those decisions across the projector, two leaf views, the clock, and call-site eligibility. That can work, but it makes the real asset hard to see. The durable capability is a function like:

```text
(state, flagged, suppressed, staticPreference, reduceMotion, eligible)
    -> (effectiveState, palette, motionChannel, staticPhase)
```

followed by deterministic geometry and phase functions. The clock should not decide semantics. It should only wake eligible leaves at the next transition required by that already-resolved presentation.

Seen this way, C11-183 is also building an animation-budget boundary for c11 chrome: one source of time, no timers in leaves, no observation in the equatable workspace-card parent, and an explicit definition of which invisible marks consume zero work. That infrastructure is more valuable than any individual animation.

### How It Could Be Better

#### 1. Make agreement structural, not a review chore

The plan says to duplicate the 9pt geometry in Bonsplit and `ContentView.swift`, reuse named constants, and compare the diff side by side. That still permits drift on stroke widths, core placement, fill order, static phase, tint priority, and later C11-184 changes.

A stronger design is one public, generic Bonsplit mark leaf used by both call sites. `BonsplitTabActivityState` is already public, and Bonsplit already imports SwiftUI. The shared leaf can accept generic presentation tokens rather than c11 metadata concepts:

```text
state
color
motion mode
stable id
eligibility
```

The internal surface-tab adapter and the c11 workspace adapter would map their own state into those inputs. If making a public SwiftUI view is judged too large an API commitment, the minimum viable alternative is a public pure geometry/presentation kernel with two thin drawing adapters. Either is stronger than two independently authored shape switch statements.

This also resolves a tension in Phase 1. The plan calls that commit an “upstream-clean vocabulary” while also adding `flagged` and `suppressed` inputs to Bonsplit. Those names are c11 attention-model semantics. Keep the upstream-offerable commit genuinely shape-only, then add generic tint/motion presentation inputs in a second commit. The upstream offer can cleanly point to the first commit.

#### 2. Define the host-to-Bonsplit policy pipe

Adding `@AppStorage` in `c11App.swift` does not make Bonsplit’s `TabActivityMark` react to it. The current plan names no bridge.

There is an existing repository pattern to build on: `Workspace` constructs `BonsplitConfiguration.Appearance`, and live UserDefaults observers mutate and reassign configuration for chrome scale, surface availability, and tab ordinals. Add a mark-specific setting seam, for example:

- `StaticMarkSettings` owns the key and default;
- `BonsplitConfiguration.Appearance` gains an activity-mark motion policy distinct from its existing split-layout `enableAnimations`;
- `Workspace` initializes that policy and observes the setting for live changes;
- the c11 workspace mark leaf reads the same setting through a leaf-local input or leaf-local `@AppStorage`, never through the enclosing equatable `TabItemView`.

An environment-injected policy object at the Bonsplit root is another valid design. What matters is that the plan chooses one path, states how it updates every existing workspace, and proves that toggling the setting registers/unregisters leaves without restarting the app.

Reduce Motion needs the same precision. Querying `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` once is insufficient for a live setting change. The clock/policy owner should observe the accessibility-display-options notification once and drain all registrations immediately when Reduce Motion becomes true.

#### 3. Centralize the full precedence table

The plan correctly says flag overrides suppression and Reduce Motion stops everything, but it misses the spec’s rule that every unflagged suppressed mark is static. A suppressed working surface must show the full static grid, not participate in the normal 4-second fill.

Encode and test one precedence ladder:

1. Project unflagged `suppressed + waiting` to idle.
2. A flag defeats that state projection.
3. Reduce Motion forces the static form for every combination.
4. Ineligible/offscreen/background/collapsed leaves are static and unregistered.
5. `flagged + waiting` uses the 0.4s core flash.
6. `flagged + working` uses the normal fill even when `Static marks` is enabled.
7. Flagged idle and cold are static.
8. Any unflagged suppressed state is static.
9. `Static marks` disables remaining base motion.
10. Otherwise working fills, waiting dips, idle/cold remain static.

This can be a compact table-driven pure test rather than an oversized animation suite. It is exactly the kind of small seam that prevents C11-184 from rewriting or accidentally stacking animations.

#### 4. Separate absolute phase from wake-up scheduling

“One shared clock” is necessary but underspecified. A singleton that publishes a date at a high cadence would still invalidate every subscriber on every tick. A single timer that fires separately for every UUID offset could become an N-transition scheduler in disguise.

Define two layers:

- a pure phase model: stable UUID bytes + monotonic time -> working fill count, waiting endpoint, or flagged-waiting edge;
- a registration broker: eligible leaves register only for their channel’s next transition, and the broker arms one timer for the earliest required transition.

For waiting, the broker should only initiate compositor-driven endpoint animations; it should not drive opacity frame by frame. For working and flagged waiting, it should wake only on discrete edges. Registration tokens must be removed on disappearance or eligibility loss, and the timer must be absent when the registration set is empty, the app is inactive, or Reduce Motion is enabled.

Use an explicit stable UUID-byte algorithm and test it. Do not use Swift `Hasher`.

#### 5. Make visibility an explicit data flow

The plan says “use scroll viewport intersection” but does not identify the seam. `TabBarView` currently tracks scroll offset/content/container width and only records the selected tab’s frame. A concrete approach is:

- collect full-tier tab frames in the existing named `tabScroll` coordinate space via a dictionary preference keyed by tab UUID;
- intersect those frames with the unobscured viewport;
- pass a plain `Bool` to each mark leaf;
- keep collapsed control-chip and dropdown marks static;
- update the visibility set only on scroll/layout/tier changes, not clock ticks or keystrokes.

For workspace marks, pass the already-precomputed `isActive`/selected-workspace fact into the leaf. Do not add clock or settings observation to c11’s enclosing `TabItemView`, and keep its `==` inputs and `.equatable()` call site intact.

#### 6. Resolve exact timing before coding it twice

The plan says “nine dots over the 4-second cycle, then a full hold,” while the binding mock turns rank `i` on at `i * 10%`, has all dots on by approximately 81%, and holds until the 4-second reset. The prose elsewhere says nine cells over approximately 3.6 seconds. These are not the same phase definition.

Choose one exact formula and write it into the plan. Do the same for:

- whether the first working dot is present at cycle start or after the first beat;
- the exact full-grid hold duration;
- the hard reset boundary;
- the 1.2-second dip endpoints and easing;
- the 0.4-second flash’s exact 50% edge.

The live mock is listed above prose in the binding precedence only after the main spec, so this discrepancy should be resolved explicitly rather than guessed during implementation.

#### 7. Restore acceptance ownership

Compilation is not enough for this ticket. The implementation plan may stop at `review`, but the overall plan must still specify the validator’s owned gate before merge:

- tagged build launched with QA startup dialogs suppressed;
- true-size inspection of both renderers in Light and Dark themes and in a grayscale capture;
- `Static marks` toggled live;
- Reduce Motion toggled live;
- app inactive, unselected workspace, collapsed pane, and scrolled-out tab shown to unregister;
- realistic fleet topology with both renderers active;
- baseline-versus-animation-on typing-latency measurement, then independent fill-off and dip-off comparisons if the gate fails;
- recorded decision applying the predefined degradation ladder.

This need not create a dedicated harness. It does need a repeatable scenario, an objective metric/pass bound, an evidence location, and a named owner/stage. “Later fresh validation” without those details leaves the hard ship blocker unable to fail.

### Mutations and Wild Ideas

These should not expand C11-183, but they are valuable follow-ons once its kernel exists.

1. **Deterministic visual time travel.** Make the phase source injectable in DEBUG/tests. A reviewer could freeze all marks at phase 0, mid-fill, full-hold, dip-minimum, and flash-white without waiting for wall-clock timing. That turns future shape reviews into reproducible evidence without adding a production harness.

2. **An animation eligibility inspector.** A lightweight debug overlay or log could show `surface -> registered channel -> reason eligible/ineligible`. This would make offscreen battery bugs diagnosable and would be reusable for other animated chrome.

3. **A global chrome animation budget.** The registration broker naturally knows the count and cadence of live animations. A future policy could expose that count to diagnostics or conservatively degrade motion under energy pressure. Do not make this adaptive in C11-183; first collect evidence.

4. **A portable attention alphabet.** Once lifecycle is shape-only and modifiers are presentation tokens, the same grammar can render in markdown dashboards, remote workspace summaries, or companion clients without inheriting c11’s SwiftUI implementation.

5. **Upstream accessibility kit.** The pure shape commit is a credible Bonsplit upstream contribution. If accepted, c11 gains a small flywheel: upstream improvements return through normal submodule updates while c11 retains only host-specific policy and attention semantics.

### What It Unlocks

- C11-184 can wire real modifier truth into a stable presentation resolver instead of editing geometry and animation in two places.
- Violet becomes a lossless escalation channel because lifecycle no longer depends on hue.
- Opacity remains available for future semantics because suppression is a state projection, not dimming.
- New renderers can consume the same mark grammar without reinterpreting lifecycle.
- Shared eligibility and scheduling become reusable infrastructure for battery-safe animated chrome.
- Deterministic phase math enables focused unit tests and reproducible visual validation.
- Registration counts create the first direct evidence about the cost of animated agent fleets, which can inform future defaults.

### Sequencing and Compounding

I would reorder the work as follows:

1. **Freeze the truth table and exact phase equations.** Resolve the suppressed-working rule, setting/flag/Reduce Motion precedence, and mock/prose timing discrepancy before view code.
2. **Build the pure presentation and phase kernel with a small test table.** This becomes the contract for everything later.
3. **Land Bonsplit commit A: shape-only vocabulary.** Keep it independently upstream-offerable and do not update the parent pointer yet.
4. **Land Bonsplit commit B: generic shared renderer/clock/policy seams plus full-tier visibility inputs.** Avoid c11 flag metadata names in the generic package API.
5. **Wire c11 policy and projection.** Add modifier defaults, `StaticMarkSettings`, live propagation into every existing Bonsplit workspace, leaf-only settings/eligibility inputs, and the 9pt sidebar floor.
6. **Localize the setting in all seven locales.** This is part of implementation completion, not a later note.
7. **Run package tests, focused c11 logic tests, and app compilation.**
8. **Commit and push the final Bonsplit HEAD, fetch, and prove final HEAD is an ancestor of the Stage-11 remote `main`.** Only now commit the parent submodule pointer.
9. **Commit and push the parent branch.**
10. **Fresh review, then tagged running-system validation and the fleet-scale latency/ladder gate.** No PR or merge until the gate has an evidence artifact and verdict.

This preserves the valuable shape-only upstream commit while fixing the current unsafe sequence, where Phase 1 commits the parent pointer before Phase 2 mutates Bonsplit again.

### The Flywheel

The useful flywheel is:

```text
one presentation truth table
    -> one shared geometry/phase implementation
    -> cheaper modifier and renderer additions
    -> less visual drift and fewer hot-path regressions
    -> more confidence to use the marks at fleet scale
    -> better performance evidence from real fleets
    -> sharper scheduling and eligibility policy
    -> safer default-on motion
```

There is a second upstream loop:

```text
shape-only accessibility commit
    -> clean Bonsplit upstream offer
    -> broader review and reuse
    -> upstream fixes remain cherry-pickable
    -> c11 carries less fork-only rendering code
```

The plan accelerates both loops if it separates the shape commit from c11 attention semantics and makes the final parent pointer reference the fully pushed clock/rendering commit.

### Concrete Suggestions

1. Add a pure `ActivityMarkPresentation.resolve(...)` seam and a compact precedence test covering Reduce Motion, static preference, flagged working, flagged waiting, suppressed working, and suppressed waiting.
2. Prefer one public generic Bonsplit mark leaf for both renderers. If that API is rejected, share public geometry and phase tokens and keep adapters thin.
3. Add a dedicated activity-mark motion policy to `BonsplitConfiguration.Appearance`; do not reuse the existing `enableAnimations`, which c11 currently sets false for split-layout animation.
4. Mirror the existing live `Workspace` settings-observer pattern so `Static marks` updates already-created workspaces immediately.
5. Observe accessibility-display changes once at the clock/policy owner and synchronously disable future scheduling when Reduce Motion turns on.
6. Specify an explicit, stable UUID-byte phase-offset function and exact cycle equations.
7. Use a tab-frame preference map in `tabScroll` to compute a plain visible-ID set; do not make mark leaves infer visibility.
8. Keep collapsed-tier marks static, including the active collapsed chip and popover rows.
9. Amend the submodule instructions to push and verify the final Phase 2 Bonsplit HEAD before the sole parent-pointer commit.
10. Replace the translation-stage note with an owned six-locale catalog update.
11. Add a validation-stage section with the tagged launch command, repeatable fleet topology, metric/pass bound, ladder procedure, and artifact destination.
12. Record the shape-only Bonsplit commit SHA separately in the eventual upstream-offer note so upstream does not have to absorb c11’s clock/policy work.

### Questions for the Plan Author

1. Where exactly does the `Static marks` value cross from c11 into the already-mounted Bonsplit tab bars, and how are existing workspaces updated live?
2. Should the shared artifact be a public Bonsplit SwiftUI mark view, or only a public geometry/phase kernel with two drawing adapters?
3. Is the Bonsplit API allowed to name `flagged` and `suppressed`, or should the package remain generic and accept resolved tint/motion tokens from c11?
4. Which timing source wins where the live mock’s keyframes and the prose disagree, and what are the exact working beat and hold boundaries?
5. Will the pure resolver explicitly force unflagged suppressed working to the static full grid?
6. What concrete mechanism observes live Reduce Motion changes and drains the shared clock’s registrations?
7. What exact coordinate space and frame-preference data will define “scrolled out” tabs, including the region obscured by trailing chrome?
8. What objective typing-latency metric and regression bound makes the fleet-scale gate pass or fail?
9. Who owns the tagged validation stage, and where will its true-size, grayscale, visibility-gating, and latency evidence be recorded?
10. If the fill fails but the dip passes, how will the shipping default be changed and represented in `Static marks` copy so the setting remains truthful?
11. Why does the current sequence commit the parent submodule pointer after Phase 1 when Phase 2 still modifies Bonsplit?
12. Is the intended upstream offer the shape-only commit or the final shape-plus-clock Bonsplit history?
13. Can the plan be amended to include the required six-locale `Localizable.xcstrings` update rather than deferring it?
14. Does C11-183 need live paths for `flagged` and `suppressed`, or only a tested default-false presentation seam until C11-184 supplies real modifier data?
