# Trident Synthesis: C11-183 Mark Vocabulary Plan (Standard / Analytical tier)

- **Plan under review:** `.lattice/plans/task_01KYMTWW3VVZSR308G0X3YE79H.md` (270 lines)
- **Reviews synthesized:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
- **Synthesized:** 2026-07-28
- **Mode:** read-only synthesis; one contested fact independently verified against the repo

---

## Executive Summary

1. **All three models agree the architecture is right.** Shape carries lifecycle, motion is isolated in leaf views, one shared clock serves both renderers, per-mark `TimelineView`s are rejected, off-screen work is gated, and the `(state, flagged, suppressed)` default-false seam correctly splits C11-183 from C11-184. No model asks for a rethink. The disagreement is entirely about whether the plan is *executable as written*.

2. **Two of three models return "Needs revision"; one returns "Ready to execute."** Claude and Codex both independently identify a blocking defect in the verification section. Gemini not only misses it but names the exact broken thing as a **strength**.

3. **I verified the contested fact against `project.pbxproj`. Claude and Codex are correct; Gemini is wrong.** `WorkspaceUnitTests.swift` (which contains `WorkspacePulseMarkRowMetricsTests`) is a member of the host-bound `c11Tests` target only. The plan's stated command `-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests` matches nothing and will silently run zero of the two sizing assertions. The trap is subtle and worth recording: `SidebarActivityProjectorTests.swift` *also* lives on disk under `c11Tests/` but **is** a member of `c11LogicTests`. On-disk directory does not determine target membership in this project. This is the same class of mismatch that caused C11-105.

4. **The confidence-weighted verdict is Needs Revision.** Gemini's "ready" is not a genuine third opinion; it rests on a factual error that the other two models each caught independently and that I confirmed. Its review is roughly one-seventh the length of Claude's and contains no file-line verification.

5. **Three defects are blocking by consensus or by verification:** (a) the unrunnable `c11-logic` command; (b) the Bonsplit Phase 2 delivery sequence, which mutates the submodule again after Phase 1 already pushed and advanced the parent pointer, with no second commit/push/ancestry/pointer cycle specified (Codex only, but structurally undeniable against the plan text); (c) the hard fleet-scale typing-latency gate deferred with no owner, no bound, and no contingency for a failed gate.

6. **The one genuinely open architectural fork is clock ownership.** All three touch it, and two converge on the same correction from different directions: Bonsplit should define the clock type or protocol, but **c11 should own and inject the single instance**, because app-active and Reduce Motion state are app-global concepts a package should not reach for. Claude goes further and argues the split is inverted: share the *geometry* upstream (the drift-prone thing) and keep the *clock* in c11 (the app-scoped thing). This is the only decision that is expensive to reverse after Phase 2.

7. **Highest-value single finding across all three reviews:** Claude's observation that the plan contains **no test for the ticket's own thesis**. Phase 4 tests projection and sizing. Nothing asserts that four states produce four distinguishable marks, which is the entire defect being fixed.

---

## 1. Where the Models Agree (highest-confidence findings)

### 1.1 Unanimous (3/3)

1. **The central design is correct and should not be rethought.** Shape-first vocabulary, leaf-isolated motion, one shared clock with stable per-surface offsets, no per-mark timers or `TimelineView`s. All three explicitly reject the "obvious" per-mark `TimelineView` alternative on identical grounds: 40+ decoupled timers at fleet scale would attack the typing-latency budget the repo protects.
2. **Preserving `TabItemView`'s `Equatable` conformance and `.equatable()` call site is the right guardrail**, and keeping clock observation out of the parent body is the correct invalidation strategy.
3. **Suppression-as-projection beats suppression-as-visual-dimming.** Projecting suppressed-waiting down to idle keeps the renderers drawing exactly four fundamental shapes instead of a combinatorial matrix of dimmed variants.
4. **Submodule provenance handling is a strength.** Named branch rather than detached HEAD, remote-main ancestry proven with `merge-base --is-ancestor` before the parent pointer commit. All three call this out; the disagreement is only about *completeness* (see 2.3).
5. **Off-screen gating is an area of concern.** All three flag it, from three non-overlapping angles (see 2.4).
6. **The Bonsplit purity boundary needs sharper definition.** All three worry that something c11-specific leaks into the upstreamable package; they name three different leaks.
7. **The "no dedicated performance harness" call is correct**, because the operator said so explicitly. Claude and Codex both add the same caveat: "no harness" and "no measurement at all" are different positions.

### 1.2 Two of three, verified or structurally solid

8. **BLOCKER: the stated `c11-logic` verification command cannot run** (Claude, Codex; independently verified). Three remedies were proposed; both models converge on the same preferred one: put the sizing assertions in a file that is *already* a member of `c11LogicTests`, rather than editing `project.pbxproj` (which `CLAUDE.md` warns produces multi-thousand-line normalized diffs) or falling back to the host-bound `scripts/test-unit-local.sh` wrapper. Note the plan's Phase 4 compounds the confusion by naming the target files by their *directory* path (`c11Tests/...`) while the verification command names them by *target* (`c11LogicTests/...`).
9. **Core motion behavior is nearly untested** (Claude, Codex). The plan introduces a scheduler, a registration lifecycle, a stable UUID phase function, a Static marks setting, Reduce Motion, three animation channels, and visibility gating, then proposes tests only for projection and sizing. Avoiding an oversized matrix is right; omitting focused pure tests is not. Named candidates: phase determinism, static end-state normalization, subscription start/stop, clock shutdown at zero registrations, presentation-policy resolution.
10. **The Reduce Motion mechanism is unspecified and has no house precedent** (Claude, Codex). A grep for `accessibilityDisplayShouldReduceMotion` / `reduceMotion` across `Sources/` returns nothing, so this is net-new plumbing. The plan states the requirement four times without naming `@Environment(\.accessibilityReduceMotion)` versus `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` plus the change notification. Both models add that a one-time read is insufficient: the override must take effect live, which means an observer with defined teardown.
11. **The settings data-flow is unspecified** (Claude, Codex). `@AppStorage` in `Sources/c11App.swift` sits in the Settings view, not in either renderer tree. Nothing says how the value reaches Bonsplit's `TabActivityMark` and c11's workspace leaf, and the two obvious routes have opposite failure modes: widening `TabItemView`'s `==` (latency cost, stated honestly) versus reading the environment inside the leaf (classic `EquatableView` staleness, where an equal parent suppresses the body re-evaluation that would propagate the change).
12. **The typing-latency gate is deferred without an owner or a contingency** (Claude, Codex). The spec makes it a hard merge blocker with a defined degradation ladder (fill fails becomes dip-only; dip fails becomes static-default). The plan defers the whole gate to a later stage. Both models accept the deferral as honest lifecycle discipline and object to the *unowned* part: the branch reaches `review` with animation default-on, and nobody is named to flip the default if the gate fails. Claude adds the downstream consequence: in a static-default world the shipped `Static marks` settings row would have nothing to disable and becomes misleading copy.
13. **Clock ownership needs an explicit decision** (Claude, Codex; see 2.2).

---

## 2. Where the Models Diverge (the disagreement is signal)

### 2.1 The readiness verdict itself, and what caused the split

| Model | Verdict | Length | Independent file-line verification |
|---|---|---|---|
| Claude | Needs revision | ~260 lines | Yes, extensive (pbxproj, ContentView, TabItemView, TabBarView, docs, git remotes) |
| Codex | Needs revision | ~195 lines | Yes, targeted (test target membership, projector call path, mock timings) |
| Gemini | **Ready to execute** | ~35 lines | None evident |

Gemini's Strength #4 reads: *"Test Scheme Selection: By narrowing tests to `c11-logic` (`SidebarActivityProjectorTests`, `WorkspacePulseMarkRowMetricsTests`), the plan avoids the heavy `c11-unit` XCTest host overhead."* This is praise for the exact command that cannot execute. **Treat this divergence as a depth artifact, not a genuine three-way disagreement.** The lesson generalizes: a review that accepts a plan's verification commands at face value cannot certify readiness, because the verification section is precisely where a plan's claims about itself go unaudited.

### 2.2 Clock in Bonsplit versus geometry in Bonsplit (the real architectural fork)

Three distinct positions:

1. **Gemini: accept as planned.** Bonsplit owns the clock; c11 reimplements the 9pt geometry. No objection raised.
2. **Codex: keep the clock in Bonsplit, but invert ownership of the instance.** Bonsplit defines a public clock/scheduler protocol plus implementation; **c11 creates and injects the one app instance**. Buys one provable clock instead of one singleton per accidental code path, deterministic fake-clock tests, explicit lifetime and app-active control, and no c11 preference key embedded in upstreamable code.
3. **Claude: the split is backwards.** Promote `TabActivityMark` and `TabActivityMarkMetrics` out of `Internal/` to public, add optional injected phase inputs defaulting to the static end state (zero behavior change for existing consumers), and let c11 own the clock outright. Three arguments: (a) an animation clock is not "pure shape vocabulary" and is a harder upstream sell bundled into the same commit as the accessibility fix; (b) it shares the wrong thing, since **geometry** is the artifact that must not drift across two renderers and "review the final diff side by side" is the weakest mitigation in the plan; (c) the clock must gate on `NSApplication` active state and `NSWorkspace` accessibility state, both app-global concepts a package should not reach for.

**Synthesis.** Codex and Claude converge on the same operative correction from different starting points: **c11 should own the instance and the app-global gating, whatever Bonsplit declares.** They differ on whether geometry should also move upstream. Claude's drift argument is the stronger of the two unshared points and the plan does not rebut it: the mitigation for two independent copies of "3pt pitch, 2pt dot, 0.5pt inset, 1.5pt frame, 1pt gap, 4pt core" is a side-by-side diff read, which protects nothing after the first follow-up ticket touches one renderer. **The plan's real gap is that it does not show its work on this fork at all.** Claude's counterweight is honest and worth weighing: if the sidebar genuinely needs geometry the tab chip does not (the summary scale is exactly such a case, see 3.1), sharing shapes across a submodule boundary gets awkward fast.

### 2.3 Is the submodule sequence complete?

- **Gemini:** praises it as a strength that prevents the classic desync failure.
- **Claude:** praises the Phase 1 sequence in detail (eight numbered steps, correct order, ancestry gate inline) and confirms the submodule is currently detached at `d4ff0e4c`, so step 3 is not theoretical. Does not catch the Phase 2 gap.
- **Codex:** identifies a real structural gap. **Phase 2 modifies files under `vendor/bonsplit` (the shared clock seam), but only Phase 1 specifies a commit / push / ancestry / parent-pointer cycle.** As written, the plan can leave the final Bonsplit animation commit unreachable from the remote, or leave the parent pointer referencing only the Phase 1 shape state.

**Codex is right, and this is verifiable from the plan text alone.** Codex's preferred fix: treat all Bonsplit work as one delivery boundary (implement vocabulary and clock on one named branch, run the suite on the complete state, commit, push final HEAD, prove ancestry, then one parent pointer commit). Two intermediate pointer commits are also valid, provided each referenced commit is already remote-reachable. Note this interacts with 2.2: if the clock moves out of Bonsplit entirely, the gap disappears by construction.

### 2.4 Off-screen gating: three framings of the same area, none contradictory

- **Claude (mechanism):** the plan prescribes one uniform strategy where two are needed. For the tab bar it is right, because Bonsplit's tab bar is a **non-lazy `HStack` inside a horizontal `ScrollView`** (`TabBarView.swift:576+`), so every tab is materialized and `onAppear`/`onDisappear` will never fire for scroll-out. For the sidebar it is over-engineered, because `ContentView.swift:8586` already uses a **`LazyVStack`** where `onAppear`/`onDisappear` is sufficient and nearly free. Adds a concrete seam the plan misses: `TabBarScrollViewBridge` (`TabBarView.swift:97`) is an `ObservableObject` already holding the `NSScrollView`, and is where viewport intersection should hang.
- **Gemini (risk):** viewport-intersection detection in SwiftUI can trigger its own layout and scroll performance problems. Asks directly whether a `GeometryReader` inside the scroll view will cause layout thrashing on the tab bar during scroll.
- **Codex (proof):** the plan explains how it intends to *detect* eligibility but never how review or validation *confirms* that registrations actually disappear for scrolled-off tabs, collapsed presentations, inactive workspaces, and background app state. No oracle.

**These compose into one recommendation:** per-renderer strategy (Claude), hung off the existing bridge rather than new per-row geometry observation (Claude, which also answers Gemini's thrash concern for the sidebar), with a runtime oracle such as a debug registration counter to prove deregistration (Codex).

### 2.5 Localization: a genuine three-way split

- **Gemini:** deferring translation is a **strength** and correctly respects the "write English only" policy.
- **Codex:** deferring translation is a **defect**. The repo instruction is that new English strings are followed by a six-locale pass; plan lines 163-165 and 255-256 soften a requirement into an optional later note ("if needed"). The canonical plan should include the translation stage before delivery even if a fresh translator owns it.
- **Claude:** the note is correct as far as it goes but **incomplete in a different dimension**. Phase 1 touches Bonsplit accessibility text, and Bonsplit strings resolve through `Bundle.module.localizedString` against the package's own catalog, not `Resources/Localizable.xcstrings`. One localization note covers two catalogs.

**All three are partially right.** English-only authoring is correct (Gemini); the translation stage must be named and owned rather than conditional (Codex); and the note must distinguish the two catalogs (Claude).

### 2.6 Is the flagged-working / Static marks interaction settled?

- **Claude and Gemini:** accept plan lines 68-69 (flagged working retains the fill even when Static marks is on, because flag-tier motion bypasses the setting).
- **Codex:** this is an *interpretation*, not a settlement. The operator's clarification says "flagged non-waiting marks use normal lifecycle motion," which can just as reasonably mean flagged working **inherits** the normal Static marks gate. The older docs support a flag-tier bypass, but the same clarification explicitly replaced the older flagged-motion model, so citing those docs is circular.

**Codex's reading is the more careful one.** It also connects to a defect only Claude found: the docs that would settle the question still describe a breathe animation the operator says does not exist (see 3.1). The plan is resolving an ambiguity by appeal to prose it has itself declared stale.

### 2.7 Is the dormant modifier seam a strength or a scope overreach?

- **Claude:** a top-five strength. Default-false `flagged`/`suppressed` means C11-183 changes no current behavior on those axes, C11-184 wires fields rather than rewriting shape code, and C11-183 stays independently revertible.
- **Codex:** partly overreach. The plan ships violet rendering, flagged-waiting flash behavior, and suppression projection **before C11-184 has a source of truth for either modifier**. Backs this with a concrete call-path finding: the current caller still passes raw workspace unread demand into `WorkspacePulseProjector`, which can synthesize a waiting count, so projecting suppressed-waiting to idle does not deliver complete suppression semantics until C11-184's signal-eligible unread work lands.
- **Gemini:** unambiguous strength.

**Both are true and the reconciliation is a labeling problem, not a design problem.** The seam is right; the plan should separate three tiers in its own text and in review language: generic renderer capability delivered now, dormant test-only modifier inputs, and behavior that is not operationally true until C11-184.

---

## 3. Unique Insights (surfaced by exactly one model)

### 3.1 Claude only

1. **The 10pt summary mark is unresolved (highest-value unique finding).** `ContentView.swift:11816` defines `workspacePulseMark(for:summaryScale:side:)` with `side = overrideSide ?? (summaryScale ? 10 : 9)`, and the summary row at 11867 calls it with `summaryScale: true` inside a 16x16 frame. The plan says summary and footer marks share the renderer seam and separately that `markSide` stays exactly 9pt, but never reconciles them. This is arithmetically load-bearing: 3pt pitch times 3 equals 9; a 2pt dot with 0.5pt inset per side equals a 3pt sub-cell; the waiting mark is 1.5 + 1 + 4 + 1 + 1.5 = 9. **None of that divides at 10.** Three outcomes, all needing a decision: the summary drops to 9 (an unannounced visual change a reviewer will flag), it scales and the sub-geometry lands on fractional points, or it keeps a bespoke path and the two seams diverge on day one. The spec's own words, "Marks render at 9pt, always," point at the first.
2. **A spec rule is silently dropped.** `docs/c11-mark-vocabulary.md` states that suppressed unflagged marks never animate even under the animated default, and that **a suppressed working mark renders the static full grid**. The plan's motion contract covers only suppressed *waiting*, which is trivially satisfied anyway since suppressed waiting becomes idle and idle never animates. The load-bearing case is absent from both the contract and Phase 4's test list. It is currently dead code, which is exactly why it will be missed and why C11-184 will inherit an animating suppressed mark.
3. **The plan declares docs stale and leaves them stale.** Binding input 4 says the operator clarification overrides stale flagged-motion prose and that there is no separate breathe animation. But `docs/c11-mark-vocabulary.md:72` still says the mark breathes for flagged working/idle/cold, `:133` still lists breathe among what Reduce Motion suppresses, and `docs/c11-flagged-agent-plan.md:182` still tabulates breathe with lines 186 and 188 building further reasoning on it. No phase corrects them. **C11-184's implementer will read line 182 as the spec and build a breathe animation the operator says does not exist.**
4. **There is no Phase 0 worktree provisioning.** The plan's first build command is `xcodebuild -scheme c11 build`, which in a fresh worktree fails in the documented three-stage sequence (package resolution, missing ghostty, missing xcframework), none of which look like code problems. `git submodule update --init --recursive ghostty vendor/bonsplit` plus the `GhosttyKit.xcframework` symlink are cited in binding inputs but appear in no phase.
5. **No test for the ticket's actual thesis.** Nothing asserts that four states produce four distinguishable marks. Given the repo's ban on source-text assertions this needs a render or shape-descriptor seam, which the test policy explicitly endorses ("add a small runtime seam or harness first"). It is the only test that guards what the ticket exists to establish.
6. **A second false comment in Bonsplit.** The plan commits to keeping accessibility comments truthful, but `TabItemView.swift:164` also asserts *"Nothing here animates. The mark is drawn once per state change, which keeps continuous per-tab redraw off the tab-bar render path."* Phase 2 falsifies that sentence, and it is precisely the sentence a future upstream reviewer reads to understand render-path implications. Do not replace one false comment with another.
7. **A standing operator correction may forbid the plan's local builds.** There is a recorded C11-181 correction to defer **all** local c11 `xcodebuild` to CI during delegator/headless runs, including the nominally safe `c11-logic` scheme, after the operator interrupted exactly such a run. The plan hardcodes a local logic test and a local `-scheme c11 build`, and the first `c11-logic` run in a fresh worktree pays the full multi-minute app build.
8. **The phase algorithm is named only by prohibition.** "Never Swift `Hasher`" correctly rules out the per-process-seeded footgun but leaves the choice open. Naming it (for example FNV-1a over the sixteen UUID bytes modulo the beat count) removes a decision from implementation time and makes phase stability **the one cheaply unit-testable animation property**, currently absent from Phase 4.
9. **The `TimelineView` prohibition should be scoped to marks.** The repo already has two legitimate `TimelineView(.animation)` sites (`Sources/Update/UpdateBadge.swift:66` and the tab loading spinner at `TabItemView.swift:1013`), both single-instance and fine. An unscoped prohibition risks being read as a mandate to rip out the spinner.
10. **`<stage11-remote>` is a placeholder appearing five times**, including in the one sequence where a mistake orphans a commit. `vendor/bonsplit` has exactly one remote, `origin`, pointing at `Stage-11-Agentics/bonsplit`. Write it literally.
11. **Bonsplit's enum case is `.running`, not `.working`.** The plan speaks entirely in c11 vocabulary; a delegator working from the plan alone greps for the wrong case name in Phase 1.
12. **The no-PR non-goal is stated without reasoning.** A reviewer reading only the plan cannot tell whether this is a deliberate sequencing decision (hold to merge alongside C11-184, or open after fresh review) or an omission.
13. **A crisp three-way enumeration of the Equatable question**, which is the sharpest latency risk: (a) new stored properties on `TabItemView` added to `==`, widening the per-keystroke equality check; (b) new axes routed through the existing `workspacePulse` value, which is *already* in `==` and therefore free for `flagged`/`suppressed`; (c) `@AppStorage` and `@Environment` read inside the leaf with no `TabItemView` change, which keeps `==` untouched but hits `EquatableView` staleness from the other direction. Claude's own recommendation splits the answer: route the modifier fields through `workspacePulse` (cost-free), and decide separately for the setting, app-active, and Reduce Motion axes.

### 3.2 Codex only

14. **The Phase 2 submodule delivery gap** (detailed in 2.3). Structurally undeniable and cheap to fix.
15. **A complete specification of the missing validation phase**, which is the most operationally useful single passage across all three reviews: tagged build and QA launch command; a realistic 20-agent / 40-plus-mark state; the terminal and typing action used for comparison; baseline versus animation-on samples; the metric and acceptable regression bound; **separate fill-disabled and all-base-motion-disabled samples** so the ladder can be decided empirically rather than by hunch; confirmation that background, unselected-workspace, collapsed-pane, and scrolled-off tabs stop registering; true-size screenshots for both renderers under Static marks and Reduce Motion; and the exact evidence required before C11-183 leaves `in_validation`. The framing is the point: **without a measurable bound, "passes" cannot fail honestly.**
16. **Clock cadence is unspecified.** "One shared clock" is necessary but not sufficient, because stable per-surface offsets produce different deadlines. Does the clock tick at a fixed cadence and deduplicate leaf updates, or schedule the next earliest registered phase edge? The latter matches the plan's stated "channel-specific leaf updates" contract; either is executable once explicit.
17. **Re-entry behavior is unspecified.** When a leaf becomes eligible again, does it resume from the shared absolute epoch (recommended, preserving the stable staggering the offsets exist to produce) or restart at phase zero (which would re-synchronize marks into visual noise after any scroll)?
18. **The working cycle timing is imprecise against the mock.** The live mock has all nine dots on by 80% of a 4s cycle, followed by a 20% full hold. The plan's "nine dots over the 4-second cycle, then a full hold" admits either a longer cycle or no hold at all. Bind the phase thresholds explicitly.
19. **Bonsplit must not hardcode a c11 defaults key.** If the Static marks preference reaches `TabActivityMark` by the package reading `UserDefaults` for a c11-specific key, the upstream-clean story is dead.
20. **The suppression call path is incomplete today**, not just dormant: `WorkspacePulseProjector`'s caller still passes raw workspace unread demand and can synthesize a waiting count, so C11-183 should not claim complete suppression semantics.
21. **Scoped approval for the validator's computer-use pass** should be obtained up front (tagged-build UI flow, screenshots, fleet typing exercise), or the gate should be explicitly operator-run.

### 3.3 Gemini only

22. **The concrete Bonsplit API fork for violet, which neither other model names.** Both Claude and Codex gesture at "keep Bonsplit free of c11 concepts"; Gemini asks the actionable version: does `TabActivityMark` take `isFlagged: Bool` and hardcode `#9D8AD9` inside the package, or take `overrideColor: Color?` so c11 injects the tint and Bonsplit never learns what "flagged" means? **The second is clearly correct and the plan does not say which it picked.** This is the strongest contribution of the shortest review, and it is a genuine gap: plan line 86 says "expose modifier inputs with defaults without importing c11 metadata concepts," which is a constraint, not an API.
23. **The `GeometryReader`-in-`ScrollView` thrash risk on the tab bar specifically.** Claude identifies *where* the intersection logic should hang; Gemini asks whether the mechanism itself costs more than the 9pt repaint it saves. Complementary, and together they make a strong case for the existing `TabBarScrollViewBridge` over per-row geometry observation.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews and grouped. **Q1 through Q6 are gating.**

### Gating

1. **Where will the sizing assertions actually live?** `WorkspacePulseMarkRowMetricsTests` is in `c11Tests/WorkspaceUnitTests.swift`, a member of the host-bound `c11Tests` target, so `-only-testing:c11LogicTests/WorkspacePulseMarkRowMetricsTests` matches nothing and reports green having run nothing. Options: add the assertions to a file already in `c11LogicTests` (preferred by both models; `SidebarWidthPolicyTests.swift` and `WorkspaceDerivedActivityTests.swift` are members and topically adjacent), extract a pure metrics file into the logic target, edit `project.pbxproj` (accepting the documented diff-bloat and the risk that the rest of `WorkspaceUnitTests` will not compile in the logic target), or run host-bound via `scripts/test-unit-local.sh` (contrary to the plan's own non-goal). Also: reconcile Phase 4's directory-path naming with the command's target naming, since `SidebarActivityProjectorTests.swift` sits in `c11Tests/` on disk but belongs to `c11LogicTests`.
2. **How does Bonsplit get committed, pushed, ancestry-proven, and pointer-advanced a second time after Phase 2?** Phase 2 mutates `vendor/bonsplit` but only Phase 1 carries the eight-step sequence. One final remote-reachable state with one parent pointer commit, or two of each?
3. **Does the summary mark drop from 10pt to 9pt?** `workspacePulseMark(summaryScale: true)` renders at 10 today inside a 16x16 frame and the 9pt geometry does not divide at 10. Confirm the summary row is in scope and that the resulting visual change to the summary row is intended.
4. **Who owns the latency gate and what happens if it fails?** Which stage runs it, what numeric regression bound constitutes failure, who applies the ladder (fill-fails-to-dip-only, dip-fails-to-static-default), in which ticket, and what does the `Static marks` settings row say when the default is already static?
5. **Clock ownership: hidden Bonsplit singleton, c11-created Bonsplit instance, or protocol plus injected implementation?** And the prior question the plan never argues: **was promoting `TabActivityMark`/`TabActivityMarkMetrics` to public and injecting a phase from a c11-owned clock considered and rejected?** If so, on what grounds? As planned, the split shares the app-scoped thing (the clock) and duplicates the drift-prone thing (the geometry), mitigated only by a side-by-side diff read.
6. **Which of the three Equatable strategies is intended?** (a) new stored properties on `TabItemView` added to `==`; (b) new axes routed through the existing `workspacePulse` value, already in `==`; (c) `@AppStorage` and `@Environment` read inside the leaf with no `TabItemView` change. "Keep the contract intact" is a constraint, not a selection, and each option has a different staleness and latency profile.

### Contract and semantics

7. **Does `Static marks` stop flagged-working's 4-second fill, or is flagged working a flag-tier exception?** Quote the exact sentence from the operator clarification that decides it, given the docs that would otherwise settle it are the same docs the plan declares stale.
8. **Where is "suppressed unflagged working renders the static full grid"?** The spec requires it; the plan's motion contract covers only suppressed waiting. Deliberate omission on the grounds that nothing sets `suppressed` this ticket, or an oversight?
9. **Does the 4-second working cycle use the mock's exact dot thresholds and 80-100% full hold?** Bind the phase thresholds numerically.
10. **Should C11-183 ship dormant violet, flash, and suppression behavior at all, or only the generic parameters C11-184 needs?** If dormant behavior ships, what review wording prevents it from being mistaken for operational suppression, given the caller still passes raw unread demand into `WorkspacePulseProjector`?
11. **What is the stable phase algorithm?** "Not `Hasher`" rules out the footgun but leaves the choice open, and naming it makes phase stability the one cheaply unit-testable animation property.

### Mechanism and data flow

12. **What is the Reduce Motion mechanism, and how does it update live?** `@Environment(\.accessibilityReduceMotion)` or `NSWorkspace` plus `accessibilityDisplayOptionsDidChangeNotification`? Where does the observation live, what is its teardown, and how does a live toggle propagate across the `.equatable()` boundary? There is no existing usage anywhere in `Sources/` to follow, and the answer interacts with Q6.
13. **What UserDefaults key owns `Static marks`, and how does its value reach both renderer trees** without dozens of leaves independently observing `UserDefaults` and without Bonsplit hardcoding a c11-specific key?
14. **Does `TabActivityMark` take `isFlagged: Bool` with violet hardcoded in Bonsplit, or `overrideColor: Color?` with c11 injecting the tint?** Only the second keeps the package ignorant of "flagged."
15. **How does a Bonsplit-owned clock learn about app-active state and Reduce Motion**, both of which are `NSApplication`/`NSWorkspace` app-global concepts? Does the package read them directly (weakening the upstream story), or does c11 push gating in, and if so what is the API shape?
16. **Fixed-cadence-with-dedupe or next-earliest-deadline scheduling?** And on re-entry, does a leaf resume from the shared absolute epoch (preserving stable staggering) or restart at phase zero?
17. **Should off-screen gating differ per renderer?** The sidebar already uses a `LazyVStack` (`ContentView.swift:8586`) where `onAppear`/`onDisappear` suffices; the tab bar is a non-lazy `HStack` in a `ScrollView` where it never fires. Is viewport intersection intended for both or only the tab bar, should it hang off the existing `TabBarScrollViewBridge` (`TabBarView.swift:97`), and if a `GeometryReader` is used inside the scroll view, what rules out layout thrash during scroll?
18. **What runtime oracle proves deregistration actually happens** for scrolled-off tabs, collapsed panes, unselected workspaces, and background app state? Debug counters, registration snapshots, Instruments?

### Tests, docs, and process

19. **Is there any test for the ticket's thesis, that four states are distinguishable by shape?** Phase 4 covers projection and sizing only. Given the ban on source-text assertions this needs a render or shape-descriptor seam, which the test policy explicitly endorses. Planned, or left entirely to human validation?
20. **Which focused tests will cover phase determinism, static end-state normalization, subscription removal, and clock shutdown at zero registrations** without building the rejected oversized animation matrix?
21. **Will the stale breathe prose be corrected in this branch** (`docs/c11-mark-vocabulary.md:72,133` and `docs/c11-flagged-agent-plan.md:182,186,188`)? If not, is a follow-up ticket filed, given C11-184's implementer will read those lines as the spec?
22. **Will Phase 1 also correct the performance sentence** in `TabActivityMark`'s doc comment ("Nothing here animates. The mark is drawn once per state change..."), or only the accessibility sentence? Both become false in Phase 2.
23. **Where does worktree provisioning happen?** `git submodule update --init --recursive ghostty vendor/bonsplit` plus the `GhosttyKit.xcframework` symlink appear in binding inputs but in no phase, and the plan's first build command fails without them.
24. **Is the local `xcodebuild` usage confirmed with the operator**, given the standing C11-181 correction to defer all local c11 `xcodebuild` (including `c11-logic`) to CI during delegator runs?
25. **Who owns the six-locale translation pass and when must it land** (before review, or before PR delivery)? And does anything new land in **Bonsplit's own** catalog, which resolves through `Bundle.module.localizedString` rather than `Resources/Localizable.xcstrings`?
26. **Why no PR in the parent repo?** Stated as a non-goal without reasoning; a reviewer reading only the plan cannot tell decision from omission.
27. **Will `<stage11-remote>` be written literally as `origin`** in the sequence where a mistake orphans a commit? The submodule has exactly one remote.
28. **Has scoped computer-use approval been obtained for the validator's tagged-build pass**, or is that gate operator-run?

---

## 5. Overall Readiness Verdict

**NEEDS REVISION.** Two of three models return this verdict independently, and the third's "ready" rests on a factual error I confirmed against the repository. Weighted by verification depth, the synthesized verdict is not close.

**What is not in question.** No model asks for a rethink. The shape contract, the leaf-isolation and shared-clock decomposition, the default-false modifier seam, the projection-over-dimming choice, the rejection of per-mark timers, and the submodule ancestry discipline are all endorsed by all three. The delegator was right to start. **All required changes are plan edits, most measured in minutes.**

**The gate to "ready" is these seven items:**

1. **Name a runnable home for the sizing tests** (Q1). Preferred: a file already in `c11LogicTests`, not a `project.pbxproj` edit.
2. **Complete the Bonsplit Phase 2 delivery sequence** (Q2) so no animation commit can be left unreachable and no parent pointer can reference only the shape state.
3. **Specify the latency gate as an executable procedure with an owner** (Q4 and Codex's validation-phase spec): fleet setup, baseline, numeric bound, separate fill-disabled and motion-disabled ladder samples, gating oracles, evidence list, and the lifecycle outcome that lets C11-183 leave `in_validation`.
4. **Settle clock ownership and geometry ownership, with one sentence of reasoning** (Q5). This is the only item that is expensive after Phase 2 begins, because reversing it means moving a public API across a submodule boundary and taking a second push to Bonsplit `main`. **Ten minutes of thought now; a second submodule delivery later.**
5. **Close the three contract gaps:** the 10pt summary mark (Q3), the suppressed-working static rule (Q8), and flagged-working versus `Static marks` (Q7).
6. **Specify the data flow** for the setting, Reduce Motion (with live observation), and the `Equatable` strategy (Q6, Q12, Q13).
7. **Add a small focused test slice**, including at minimum the thesis test (four distinguishable shapes) and phase determinism (Q19, Q20).

**Two items that are cheap and disproportionately valuable if added:** correcting or explicitly deferring the stale breathe prose (Q21), because C11-184's implementer will otherwise build an animation the operator says does not exist; and a Phase 0 provisioning step (Q23), because the plan's first build command fails in a fresh worktree in a way that does not look like a code problem.

**Process note worth carrying forward.** The single blocking defect in this plan lived in its **verification section**, and the review that skipped independent verification not only missed it but praised it. When triaging future trident packs, weight a review's file-line citations, and treat "the plan's own test commands" as a mandatory audit target rather than a summary to paraphrase.
