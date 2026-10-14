# Standard Plan Review — C11-183

## Executive Summary

This is a strong plan with the right central design: shape carries lifecycle, motion is leaf-isolated, one clock serves both renderers, off-screen work is gated, and the vendored Bonsplit change is kept free of c11 metadata plumbing. The author has understood both the accessibility defect and the performance risk created by making motion default-on.

My verdict is **Needs revision before execution is considered plan-complete**. The architecture does not need to be rethought, but the plan has three blocking defects:

1. The ticket's hard fleet-scale typing-latency gate is deferred to a later validator without a validation phase, procedure, baseline, pass/fail bound, or explicit ladder decision. The plan therefore cannot take C11-183 from implementation through its own “Done when” criteria.
2. The Bonsplit delivery sequence is incomplete. Phase 1 pushes the shape commit and advances the parent pointer, but Phase 2 then adds the shared clock and animation integration inside the same submodule without a second commit/push/ancestry/pointer sequence.
3. The stated `c11-logic` verification command cannot run the metrics tests where the plan says they will live. `WorkspacePulseMarkRowMetricsTests` is currently in `c11Tests/WorkspaceUnitTests.swift`, which is a member of the host-bound `c11Tests` target, not `c11LogicTests`.

Fix those, make the motion policy and settings data flow explicit, and add a small amount of focused behavioral coverage. With that revision, this is the move.

## The Plan's Intent vs. Its Execution

The underlying intent is larger than replacing four glyphs. C11-183 is meant to establish a durable presentation substrate:

- lifecycle remains legible without hue;
- color becomes available to C11-184;
- default-on motion remains cheap at fleet scale;
- two independent renderers stay visually and temporally consistent;
- crowded sidebar layouts preserve the 9pt signal;
- accessibility preferences have final authority.

The plan serves that intent well through its settled contract and its leaf-isolation/shared-clock decomposition. It also correctly separates dormant `(state, flagged, suppressed)` presentation compatibility from C11-184's actual metadata, socket, notification, and persistence primitives.

The drift begins at the stage boundary. Lines 11–18 define only the delegator's implementation stage, while the ticket's acceptance criteria require observed tagged-build behavior and fleet-scale latency evidence. Lines 231–234 explicitly defer every visual and latency claim. Deferral to a fresh validator is good lifecycle discipline; omitting that validator's phase from the canonical task plan is not. A plan for the whole ticket must say how the later stage proves the hard gate, what evidence it records, and how a failed gate selects and revalidates the degradation ladder.

There is also a smaller semantic overreach. The plan does more than prepare a modifier seam: it implements violet rendering, flagged-waiting flash behavior, and suppression projection before C11-184 has a source of truth for either modifier. That can be a sensible anti-rework choice, but the plan should distinguish:

- generic renderer capability delivered by C11-183;
- dormant test-only modifier inputs;
- behavior that is not operationally true until C11-184 wires metadata and notification filtering.

In particular, projecting a suppressed waiting agent to idle is not sufficient on its own: the current caller still passes raw workspace unread demand into `WorkspacePulseProjector`, which can synthesize a waiting count. C11-184's signal-eligible unread work resolves that later. C11-183 should not claim complete suppression semantics before then.

## Architectural Assessment

### Decomposition

The decomposition into vocabulary, clock integration, c11 projection/settings, and tests is fundamentally right. Shape-first is especially valuable: it lets the team inspect static truth before adding timing and visibility complexity.

The main structural correction is to treat all Bonsplit work as one submodule delivery boundary. Phase 2 changes files under `vendor/bonsplit`, so Phase 1 cannot be the only place that commits and pushes the submodule and advances the parent pointer. The cleaner sequence is:

1. implement the vocabulary and generic clock/integration on one named Bonsplit branch;
2. run the final Bonsplit suite on the complete submodule state;
3. commit one or more logical Bonsplit commits;
4. push the final Bonsplit `HEAD` to `origin/main`;
5. fetch and prove final-`HEAD` ancestry from `origin/main`;
6. only then commit the final parent submodule pointer.

Two intermediate parent-pointer commits are also valid, but each referenced Bonsplit commit must already be reachable from the remote. The current plan specifies neither valid completion of Phase 2.

### Clock ownership

A Bonsplit-defined generic clock type is reasonable because the tab leaf lives in Bonsplit and the workspace leaf needs the same timing source. A hidden process-global singleton owned by the package would be less attractive. The stronger architecture is for Bonsplit to define a public clock/scheduler protocol and implementation while c11 creates and injects the single app instance. That gives:

- one provable clock rather than one singleton per accidental code path;
- deterministic fake-clock tests;
- explicit lifetime and app-active control;
- no c11 preference key embedded in upstreamable Bonsplit code;
- a clean way for both renderers to share the same epoch and UUID phase function.

The plan currently says “Bonsplit-owned” and “exactly one shared timer/clock” without choosing between a public injected instance and a global `shared`. That choice matters enough to settle before implementation.

### Settings and accessibility state flow

The plan names `Sources/c11App.swift` as the `@AppStorage` owner, but that file contains the Settings control, not the two renderer trees. It does not specify how the value reaches:

- Bonsplit `TabActivityMark`;
- the c11 workspace mark leaf;
- the leaf subscription gate without making c11 `TabItemView` observe a clock or broad object.

This should be an explicit data-flow sentence and file-level seam. A narrow immutable preference value passed to the leaves, with the c11 `TabItemView` equality input updated if it crosses that boundary, is safer than dozens of leaves independently observing `UserDefaults`. Bonsplit should not hardcode a c11-specific defaults key if the change is meant to remain upstream-clean.

Reduce Motion also needs live observation, not a one-time read of `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. The plan should name the accessibility-display-options change notification (or an equivalent injectable monitor), its teardown, and the rule that an enabled override immediately unregisters every leaf and normalizes it to its static end state.

### Motion scheduler

“One shared clock” is necessary but not sufficient. Stable per-surface offsets produce different deadlines, so the plan should state whether the clock:

- ticks at a fixed cadence and deduplicates leaf updates, or
- schedules the next earliest registered phase edge.

The latter better matches the stated “channel-specific leaf updates” contract. Either is executable if the cadence and repaint behavior are explicit. The plan should also settle re-entry behavior: when a leaf becomes visible again, does it resume from the shared absolute epoch (recommended, preserving stable staggering) or restart its cycle?

## Is This the Move?

Yes, after revision. A static-only accessibility patch followed by separately invented animation would create duplicate geometry and almost guarantee timing drift. Conversely, putting motion in `ContentView.TabItemView` or using a `TimelineView` per mark would attack the exact typing path the repository protects. The proposed leaf + shared scheduler model is the correct middle.

The plan also makes the right call to avoid a bespoke performance harness. The operator explicitly rejected that scope. But “no dedicated harness” does not mean “no reproducible gate.” A proportionate tagged-build validation can use existing c11 instrumentation plus a documented manual fleet setup. The plan needs to specify:

- tagged build and QA launch command;
- a realistic 20-agent/40-plus-mark state;
- the terminal and typing action used for comparison;
- baseline versus animation-on samples;
- the metric and acceptable regression bound;
- separate fill-disabled and all-base-motion-disabled comparisons if the first run fails;
- confirmation that background, unselected-workspace, collapsed-pane, and scrolled-off tabs stop registering/updating;
- screenshots at true size for both renderers, Static marks, and Reduce Motion;
- the exact evidence attached before C11-183 can leave `in_validation`.

Without a measurable bound, “passes” cannot fail honestly. Without separate ladder samples, the plan cannot empirically decide whether fill or dip is the expensive channel.

## Key Strengths

- **The shape vocabulary is precise.** The 9pt cell, stroke widths, gap, core, dot pitch, fill order, and fixed slot are concrete enough to implement consistently.
- **Performance is treated as architecture, not cleanup.** Leaf-owned phase, a shared clock, stable offsets, visibility registration, and no observation in c11's equatable workspace row directly address the real invalidation risks.
- **The plan respects submodule provenance.** Named-branch work, remote reachability before parent pointers, and an explicit upstream offer are the right safeguards; only the multi-phase sequence needs correction.
- **The C11-184 boundary is mostly disciplined.** Actual commands, metadata, persistence, events, notification routing, and attention UI remain out of scope.
- **The test policy is understood.** The plan rejects source-text assertions and heavyweight matrices and asks for runtime/pure-behavior coverage.
- **The validation claims are honest.** It explicitly refuses to call compilation visual or latency proof. The needed correction is to specify the later proof, not to weaken that honesty.
- **The hot-path guardrails are concrete.** Preserving `.equatable()`, avoiding `hitTest()` and `forceRefresh()`, and prohibiting per-mark timers or `TimelineView`s are exactly the right constraints.

## Weaknesses and Gaps

### Blocking

1. **No executable hard performance gate.** The ticket cannot be done under the current plan because the required fleet-scale tagged validation is only named, not planned.
2. **Incomplete submodule delivery after Phase 2.** The final Bonsplit animation commit can be left unreachable or the parent pointer can reference only the Phase 1 shape state.
3. **Wrong local test target.** `WorkspacePulseMarkRowMetricsTests` lives in the host-bound target, while the command requests it from `c11LogicTests`. Either move/extract the pure metrics coverage into a file that belongs to `c11LogicTests`, or run it through `scripts/test-unit-local.sh`. The current “actual test action” is not evidence that those assertions ran.

### Important

4. **Core motion behavior is nearly untested.** The plan adds a scheduler, registration lifecycle, stable UUID phase function, Static marks, Reduce Motion, three animation channels, and visibility gating, then proposes tests only for projection and sizing. Avoiding an oversized matrix is correct; omitting focused pure tests is not. At minimum, test the presentation-policy resolver, stable phase determinism, static end states, subscription start/stop behavior, and clock shutdown at zero registrations.
5. **The settings data flow is unspecified.** `@AppStorage` in the Settings view does not by itself update both renderers, and pushing observation into every leaf may undermine the intended subscription economy.
6. **Runtime Reduce Motion changes are unspecified.** A hard override must take effect while the app is running, not merely after a view happens to rebuild or the app relaunches.
7. **Localization is incorrectly deferred.** The repository instruction says new English strings are followed by a translation pass for all six supported locales. Lines 163–165 and 255–256 turn that requirement into an optional later note. The canonical plan should include the translation stage before delivery, even if a separate fresh translator owns it.
8. **Flagged-working versus Static marks is not actually settled by the operator comment.** “Flagged non-waiting marks use normal lifecycle motion” can reasonably mean flagged working inherits the normal Static marks gate. Lines 68–69 instead preserve fill even when Static marks is on. The older docs support flag-tier bypass, but the new clarification explicitly replaced the older flagged-motion model. This needs a direct decision rather than an interpretation buried in the plan.
9. **The working cycle timing is imprecise.** The live mock has all nine dots on by 80% of a 4s cycle, followed by a 20% full hold. “Nine dots over the 4-second cycle, then a full hold” can produce a longer cycle or no hold. Bind the phase thresholds explicitly.
10. **Off-screen eligibility lacks an oracle.** The plan explains how it intends to detect tab viewport intersection but not how review or validation confirms that registrations actually disappear for scrolled-off tabs, collapsed presentations, inactive workspaces, and background app state.
11. **The dormant C11-184 seam needs a sharper truth boundary.** Modifier rendering may be ready, but suppressed notification counts and waiting-edge behavior are not part of C11-183. Tests and review language should avoid implying otherwise.

## Alternatives Considered

### Per-mark timers or `TimelineView`

Simpler locally, wrong globally. It multiplies clocks, creates synchronized visual noise or unstable phase, complicates background gating, and increases invalidation risk at fleet scale. The plan is right to reject it.

### Duplicate clocks, one per renderer

This keeps module boundaries simple but loses the single-clock guarantee and can make the same surface animate out of phase between tab and sidebar. The shared clock is better.

### Host-owned injected shared clock

This is the strongest refinement of the plan's current choice. Bonsplit owns the generic type/protocol and tab integration; c11 owns the one instance and injects it into both trees. It is more testable and upstream-clean than a hidden Bonsplit singleton.

### Implement shape only in C11-183

This would reduce scope and make the upstream patch especially clean, but it would leave the default-on motion and settings contract unshipped and force C11-184 to reopen both renderers. Given the binding spec, the plan is right to keep motion in C11-183.

### Defer all flagged/suppressed rendering to C11-184

This is viable and purer in scope, but risks rewriting geometry immediately. The plan's dormant default-false seam is reasonable if it stays generic, is explicitly non-operational, and does not drag c11 metadata concepts into Bonsplit's public model.

### Host-bound metrics test

Running the existing `WorkspaceUnitTests.swift` slice via `scripts/test-unit-local.sh` is valid, but expensive and contrary to the plan's stated local loop. Extracting the pure row-metrics tests into the logic target is the better fit.

## Readiness Verdict

**Needs revision.**

The plan becomes ready when it:

1. adds a complete, measurable tagged-build validation phase with fleet setup, baseline, thresholds, gating oracles, ladder procedure, evidence owner, and lifecycle outcome;
2. fixes the Bonsplit Phase 2 commit/push/remote-ancestry/parent-pointer sequence;
3. makes the metrics test actually runnable in the chosen test target;
4. specifies clock ownership/injection plus settings and live Reduce Motion data flow;
5. adds a small focused clock/policy test slice;
6. includes the required six-locale translation stage;
7. resolves the Static marks behavior for flagged working.

Those are bounded plan repairs. The core decomposition and technical bet should remain.

## Questions for the Plan Author

1. Does **Static marks** stop flagged-working's normal 4-second fill, or is flagged working still a flag-tier exception? Which exact sentence from the operator clarification is intended to decide this?
2. Is the shared clock a hidden Bonsplit singleton, a c11-created Bonsplit clock instance, or a protocol plus injected implementation?
3. What exact clock/scheduler cadence or next-deadline algorithm guarantees that leaves update only at their channel's phase edges despite per-surface offsets?
4. When a mark becomes eligible again, should it resume from a stable app-wide epoch or restart from phase zero?
5. What UserDefaults key owns `Static marks`, which settings page contains it, and how is its value propagated to both renderer trees without broad observation?
6. How does Reduce Motion update live when macOS accessibility display options change, and how is that observer tested or validated?
7. Should C11-183 ship dormant violet/flash/suppression behavior, or only the generic parameters needed for C11-184 to add those treatments? If dormant behavior ships, what review wording prevents it from being mistaken for operational suppression?
8. Will the Bonsplit vocabulary and clock land as one final remote-reachable submodule state, or as two pushed commits with two parent pointer commits?
9. Will `WorkspacePulseMarkRowMetricsTests` be moved into `c11LogicTests`, extracted into a new pure seam/file, or run through the safe host-bound wrapper?
10. Which focused tests will prove stable phase determinism, static end-state normalization, subscription removal, and timer shutdown without creating the rejected oversized animation matrix?
11. What existing typing-latency instrumentation will the validator use, what baseline and sample size apply, and what numeric regression bound constitutes failure?
12. How will the validator construct and verify the 20-agent/40-plus-visible-mark state without adding a dedicated harness?
13. How will off-screen/background gating be observed—debug counters, registration snapshots, Instruments, or another runtime oracle?
14. Does the 4-second working cycle use the live mock's exact 0/10/…/80% dot thresholds and 80–100% full hold?
15. Who owns the six-locale string-catalog pass, and must it land before C11-183 enters review or before PR delivery?
16. Has scoped approval been obtained for the fresh validator's tagged-build UI/computer-use flow, including screenshots and the fleet typing exercise, or is that gate operator-run?
