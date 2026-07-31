# C11-183: Rebuild agent-state mark vocabulary: lifecycle in shape alone

> Revision 2 — incorporates the apply-by-default findings from the trident plan
> review (`notes/trident-review-C11-183-plan-pack-20260728-1327/synthesis-action.md`).
> One decision remains OPEN and is flagged needs-human on the ticket: clock
> ownership (see "Open decision" under Phase 2).

## Outcome

Rebuild the four surface lifecycle marks so state is carried by shape at a fixed
9pt size in both the Bonsplit surface-tab renderer and the c11 workspace-pulse
renderer. Add default-on, shared-clock motion with a localized `Static marks`
opt-out, a Reduce Motion hard stop, and a forward-compatible
`(state, flagged, suppressed)` presentation seam for C11-184.

The implementation stage ends with:

- all Bonsplit work reaching one final remote-reachable state on
  Stage-11-Agentics/bonsplit `main`, proven by ancestry check, before the single
  parent submodule-pointer commit;
- the parent branch `codex/C11-183-mark-vocabulary` committed and pushed;
- proportionate behavioral tests and app compilation recorded;
- C11-183 transitioned to `review` for fresh review and later running-system
  validation by the parent orchestrator.

The delegator does not open a PR. Rationale (not an omission): the LAT-218 flow
runs fresh review before any PR exists; the parent orchestrator owns PR-opening
after review. Consequence acknowledged: `.github/workflows/ci.yml` triggers only
on push-to-`main` and `pull_request`, so pushing this branch runs no CI. The
parent orchestrator is responsible for CI evidence — opening the draft PR (or
otherwise triggering the workflow) at the review stage, before validation
concludes. The local `xcodebuild` invocations listed under Verification are
subject to the standing C11-181 operator correction (defer local c11 xcodebuild
to CI during delegator runs); if the operator confirms that correction applies
here, the same commands run in CI via the orchestrator's draft PR instead, and
this stage's local evidence is limited to Bonsplit's `swift test`. A first
`c11-logic` run in a fresh worktree pays the full multi-minute app build.

## Binding inputs and precedence

1. `docs/c11-mark-vocabulary.md` is the shape, sizing, base-motion, performance,
   and call-site contract.
2. `docs/c11-flagged-agent-plan.md` supplies only the downstream modifier field
   definitions and composition priority; C11-184 primitives remain out of scope.
3. `scratchpad/mark-vocabulary-candidates.html` is the live geometry and timing
   reference.
4. The operator clarification recorded on C11-183 overrides stale flagged-motion
   prose in the prompt and docs:
   - flagged working uses the same normal 4-second typewriter fill;
   - flagged idle and flagged cold remain still;
   - flagged waiting alone replaces the normal 1.2-second core dip with the
     0.4-second violet/white core flash;
   - there is no separate breathe animation;
   - no dedicated QA/performance harness and no oversized test suite are built,
     **and** — quoting the clarification in full — the stage must "preserve the
     shared-clock/leaf-isolation/offscreen-gating architecture and perform
     proportionate tagged-build validation." That trailing obligation is carried
     into the Validation handoff section below.
5. `AGENTS.md` / `CLAUDE.md` govern typing-hot paths, localization, test quality,
   safe local test schemes, fresh-worktree provisioning, and submodule ancestry.

## Settled visual and behavioral contract

### Static 9pt vocabulary

- Working: a 9pt square at 25% mark-color opacity, overlaid by a 3x3 grid of
  2pt square dots on 3pt pitch with a 0.5pt inset in each cell.
- Waiting: a concentric 1.5pt frame, 1pt gap, and 4pt solid core.
- Idle: a 1pt hollow frame.
- Cold: a centered 9x2pt line.
- Every state occupies a uniform slot, so titles do not move on lifecycle
  transitions.
- `WorkspacePulseMarkRowMetrics.minimumSlot` becomes 9pt and `markSide` stays
  exactly 9pt; crowded rows yield via spacing/overflow instead of shrinking the
  signal.
- **Summary mark:** the summary-row mark currently renders at 10pt
  (`ContentView.swift`, `summaryScale`). The 9pt geometry is arithmetically
  exact (3pt pitch × 3; 1.5+1+4+1+1.5 = 9) and does not divide at 10. Per the
  spec's "Marks render at 9pt, always," the summary mark drops to 9pt. This is
  a deliberate, reviewable visual change to the summary row — call it out in
  the final diff summary.
- **Chrome scale:** marks are pinned at 9pt and are intentionally exempt from
  chrome scale in this ticket; if chrome-scaled marks are wanted, that is a
  follow-up decision, not silent drift.
- Existing lifecycle colors in `Sources/Workspace.swift` are untouched.
- Bonsplit-side vocabulary note: `BonsplitTabActivityState` uses `.running`,
  which corresponds to c11's `working` (`WorkspacePulseState`). Phase 1 work
  greps for `.running`, not `.working`.

### Motion and modifiers

- Base motion is on unless `Static marks` is enabled.
- **Exact working-fill phase table** (matches the binding mock's keyframes):
  dot rank `i` (0-indexed, bottom-row-left-to-right typewriter order) becomes
  visible at `(i × 10) + 1` percent of a 4.0-second linear cycle; all nine dots
  are on from 81% through 100%; hard reset at the 100%/0% boundary. At phase 0
  the grid is empty (rank 0 appears at the 1% beat).
- **Exact dip:** unflagged waiting moves only its core through an ease-in-out
  `1.0 → 0.15 → 1.0` opacity cycle over 1.2 seconds (endpoints at 0% and 100%,
  minimum at 50%); its frame stays fixed.
- **Exact flash:** flagged waiting replaces the dip with a 0.4-second square
  wave on the core only — violet for the first half-cycle, white for the
  second, hard edges at 0% and 50%, no easing; the violet frame remains still.
- Idle and cold are still.
- Reduce Motion stops every mark animation, including flagged waiting.
- **Suppression is state-wide:** any unflagged suppressed mark is static
  regardless of state. Unflagged suppressed waiting projects to idle; a
  suppressed working mark renders the full nine-dot grid without animating.
- Flag overrides suppression. Flagged marks are violet `#9D8AD9`. The violet is
  NOT hardcoded inside Bonsplit: c11 injects it as an override tint alongside
  the theme-resolved lifecycle colors (the mark subsystem's colors are otherwise
  theme-resolved per workspace background via
  `resolvedSurfaceTabActivityColors(from:)`), so Bonsplit stays ignorant of
  "flagged" and the violet's light-theme contrast is checked in validation.
- Flagged working retains the normal fill even when `Static marks` is on,
  because flag-tier motion bypasses that setting; flagged idle/cold stay still.
  (Note: the trident review flags this bypass reading as an inference from the
  older flagged-agent doc rather than an explicit operator decision — surfaced
  on the ticket as S4; implement as written unless the operator says otherwise.)
- **Fill resume semantics:** phase derives from the shared absolute clock epoch,
  so a mark re-entering `working` (or regaining eligibility after being
  offscreen) resumes at the current clock phase rather than restarting at zero.
  This preserves the stable stagger; the mid-cycle join is intended behavior.
- `flagged` and `suppressed` default to `false`, so current behavior does not
  require C11-184 primitives and C11-184 can wire the fields without rewriting
  shape code.

### Presentation resolver (single source of composition truth)

All modifier composition rules above are centralized in one pure resolver
(Phase 3):

```swift
MarkPresentation.resolve(rawState:flagged:suppressed:staticMarks:reduceMotion:eligible:)
    -> (effectiveState, colorRole, motionChannel)   // motionChannel ∈ {none, typewriterFill, coreDip, alarmFlash}
```

Both renderers consume the resolver's output; neither re-derives priority
logic. This is the plan's "modifier ambiguity" mitigation turned into a
deliverable, and it is the seam C11-184 builds on.

## Repository-backed implementation phases

### Phase 0: worktree provisioning and baseline

A fresh worktree cannot build (CLAUDE.md: package resolution → missing ghostty
→ missing xcframework, none of which are code problems). Before any build:

```sh
git submodule update --init --recursive ghostty vendor/bonsplit
ln -s <main-checkout>/GhosttyKit.xcframework GhosttyKit.xcframework
```

Both are gitignored. Record both, plus the baseline commands below, as baseline
evidence.

### Phase 1: pure Bonsplit shape vocabulary

Files/seams:

- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
  - `TabActivityMarkMetrics` is already uniform-slot (`cellSide = 9`,
    `visibleSize = 10` and `leadingEdgeInset = 4` for all states, with a doc
    comment already asserting the no-title-shift property). The real Phase 1
    work is the `body` shape switch: 25%-opacity base square + 3x3 dot grid,
    1.5pt/1pt frames, 9x2pt line. State precisely in the commit what (if
    anything) changes in the metrics struct, and whether the existing metric
    assertions at `BonsplitTests.swift:1449-1450` change at all.
  - expose modifier inputs with defaults without importing c11 metadata
    concepts. Be explicit about where they land: view parameters on
    `TabActivityMark` (with defaults) — NOT new stored properties on `TabItem`,
    which is `Codable`, persisted, and covered by a legacy-JSON compat test.
  - **Rewrite both stale doc-comment sentences**, not just one: the
    accessibility claim (currently false for the running/waiting pair) must
    match the new shape vocabulary, and the "Nothing here animates … keeps
    continuous per-tab redraw off the tab-bar render path" sentence must state
    explicitly that the documented no-animation invariant (from the original
    "hard cell, no animation" commit) is deliberately retired and what replaces
    the guarantee: leaf-isolated state, one shared clock, eligibility gating.
- `vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift`
  - update the existing runtime view/metric checks only where behavior changes.

Submodule sequence (single-delivery — covers ALL Bonsplit work in this ticket):

1. verify clean `d4ff0e4c` baseline and remotes (`vendor/bonsplit` has exactly
   one remote: `origin` → Stage-11-Agentics/bonsplit);
2. `git -C vendor/bonsplit fetch origin`;
3. work on one named Bonsplit branch rather than detached HEAD;
4. make the Phase 1 shape commit and the Phase 2 clock-seam commit as two
   logical commits on that same branch;
5. run the package test suite on the FINAL Bonsplit state;
6. push the FINAL Bonsplit HEAD to `origin` `main`;
7. fetch and verify `git -C vendor/bonsplit merge-base --is-ancestor HEAD
   origin/main` for the final HEAD;
8. only then make a SINGLE parent submodule-pointer commit referencing that
   final HEAD. Never commit a parent pointer to a Bonsplit commit that is not
   yet remote-reachable.

Disclosure: the push to Bonsplit `origin/main` is effectively irreversible
(shared `main` is not rewindable without force-push). The rollback path for
rejected work is a revert commit on Bonsplit `main` plus a parent pointer bump.

No upstream almonk/manaflow PR is opened; evidence includes a one-line upstream
offer for the operator.

### Phase 2: one shared animation clock and Bonsplit leaf integration

> **OPEN DECISION (needs-human, settle before the Phase 2 commit).** Eight of
> nine trident reviewers challenge clock-in-Bonsplit and converge on the
> inverse: Bonsplit exports a pure public mark view taking phase as plain
> inputs (`fillCount`/`coreOpacity`, following the existing `flashGeneration`
> precedent), while c11 owns the clock, app-active gating, and Reduce Motion —
> where those APIs already live. If the operator flips this call, Phases 1–2
> restructure and the revised plan must be re-reviewed before execution. The
> text below describes the clock-in-Bonsplit shape ONLY as currently planned;
> whichever way the decision lands, it must be recorded here with 1–3 sentences
> of reasoning covering: (a) injected phase/policy input vs. owned clock;
> (b) if the clock stays in Bonsplit, whether it is a hidden `shared` singleton
> or a public protocol + c11-created injected instance, and how it learns
> app-active and Reduce Motion state without reaching for app-global APIs from
> inside the package; (c) which Bonsplit commit constitutes the upstream offer.

Files/seams:

- a small public, Bonsplit-owned generic activity-animation clock seam under
  `vendor/bonsplit/Sources/Bonsplit/`, shared by the tab renderer and c11
  workspace renderer (subject to the open decision above);
- `TabActivityMark` remains the animated leaf and owns only its local rendered
  phase/state, not a timer;
- `TabBarView.swift` supplies visibility eligibility for full-width tab marks
  and renders collapsed-tier marks statically.

Architecture:

- exactly one shared timer/clock for the app, with stable UUID-based phase
  offsets;
- **phase-offset algorithm (named, not just constrained):** FNV-1a over the
  sixteen UUID bytes, modulo the beat count. Computed once and cached at leaf
  construction, never per beat. Never Swift `Hasher` (per-process seeded).
  Stability across app relaunch and session restore is intended.
- channel-specific leaf updates: working changes only on fill beats, waiting
  changes only at the endpoints of compositor-driven opacity easing, and
  flagged waiting changes on its square-wave edges;
- no per-mark timers; no clock observation in c11 `TabItemView` or a workspace
  card body;
- animate only when the app is active, the mark is present/on-screen, the
  workspace is selected, and the pane is not collapsed. "Collapsed" covers all
  three senses: an actually collapsed split pane, Bonsplit's responsive narrow
  tab-strip tier, and an open collapsed-tier dropdown — collapsed-tier marks
  render statically;
- **offscreen gating is split per renderer** (they need different strategies):
  - *Sidebar:* the pulse rows already sit in a `LazyVStack`;
    `onAppear`/`onDisappear` on the rows plus the already-precomputed
    selected-workspace fact is sufficient. No viewport-intersection machinery
    there.
  - *Tab bar:* genuinely needs viewport intersection (non-lazy `HStack` in a
    `ScrollView`). Hang it off the existing `TabBarScrollViewBridge` seam (the
    `ObservableObject` already holding the `NSScrollView`): frames collected in
    the existing `tabScroll` coordinate space into an ID-keyed preference,
    intersected once, delivered to each leaf as a plain `Bool`, updated only on
    scroll/layout/tier changes — never on clock ticks or keystrokes.
- **Reduce Motion mechanism (named, single observer):** one app-scope observer
  — `NSWorkspace.shared.notificationCenter` observing
  `accessibilityDisplayOptionsDidChangeNotification` (there is no existing
  Reduce Motion plumbing anywhere in the repo; this is net-new) — owned by the
  clock/policy owner, not per-leaf. On a live transition to true: drain every
  registration immediately and normalize each mark to its static end state,
  without waiting for a view rebuild. The observer is removed on app
  termination alongside the clock. Setting changes gate leaf subscriptions the
  same way, with no work in `hitTest()` or `TerminalSurface.forceRefresh()`.
- **Observability:** a debug-only counter of live clock registrations (and, if
  cheap, current wake cadence), so "registrations drop to zero on app
  deactivation / workspace deselection / scroll-out" is an observable number
  for the validation stage. Any `dlog` call site is `#if DEBUG`-gated per the
  CLAUDE.md pitfall.

The shared clock is a generic renderer primitive, not a c11 flag/socket/metadata
primitive, so the Bonsplit change remains upstream-clean (again: subject to the
open decision).

### Phase 3: c11 projection, workspace renderer, sizing, and setting

Files/seams:

- `Sources/Sidebar/SidebarActivityProjector.swift`
  - add `flagged` and `suppressed` to `WorkspacePulseAgent` as
    `let flagged: Bool` / `let suppressed: Bool` **with an explicit
    initializer defaulting both to `false`** — NOT `let flagged: Bool = false`,
    which produces a member with no init parameter that C11-184 could never
    set. Existing construction sites stay unchanged.
  - project unflagged suppressed waiting to idle;
  - preserve true waiting when flagged and make flag override suppression;
  - keep the four-state lifecycle and established priority.
- `MarkPresentation` (new, small, pure — may live in an existing source file to
  avoid project churn): the resolver defined in the contract section. Both
  renderers consume it.
- `Sources/ContentView.swift`
  - implement the same 9pt geometry in a dedicated leaf view;
  - consume the one shared clock;
  - **Equatable strategy (decided, per axis):** the modifier fields (`flagged`,
    `suppressed`) route through the existing `workspacePulse:
    WorkspacePulseSummary` value, which is already an input to `TabItemView`'s
    hand-written `==` — so they participate in equality with no new stored
    properties. The setting / app-active / Reduce Motion axes are read
    leaf-locally inside the animated mark leaf (its own `@State`/observation),
    never routed through the enclosing `TabItemView`, so the `Equatable`
    contract and the `.equatable()` call site are untouched and cannot go
    stale: an environment change reaches the leaf without requiring the parent
    to re-evaluate.
  - pass stable `surfaceId` and modifier fields into the leaf;
  - change `WorkspacePulseMarkRowMetrics` to a 9pt slot floor and fixed 9pt
    mark side;
  - summary and footer marks use the same renderer seam, at 9pt (see the
    summary-mark decision in the contract section).
- `Sources/c11App.swift`
  - add `@AppStorage` for the default-false static preference;
  - add a localized `SettingsCardRow` labeled exactly `Static marks`, with an
    English localized subtitle and accessibility label.
- **`Static marks` propagation path (named):** follow the existing live
  UserDefaults-observer pattern where `Workspace` mutates and reassigns
  `BonsplitConfiguration.Appearance` (as chrome scale already does), adding a
  dedicated activity-mark motion-policy field to the configuration — NOT
  reusing `enableAnimations`, which c11 already sets false for split-layout
  animation. Already-mounted workspaces update live, not on relaunch. The c11
  workspace leaf reads the preference leaf-locally, never through the
  enclosing equatable `TabItemView`.

Only English call-site strings are authored in this stage. Do not modify
`Resources/Localizable.xcstrings` unless compilation/runtime extraction actually
requires it. **Translation delivery is a named durable artifact, not a note:**
the delegator files a follow-up Lattice ticket for the six-locale pass, listing
the exact new English keys (title, subtitle, accessibility label of `Static
marks`, plus any others authored), with the parent orchestrator as owner. State
in that ticket whether Phase 1's Bonsplit accessibility text introduced new
strings — Bonsplit localizes through its own `Bundle.module` catalog, not
`Resources/Localizable.xcstrings`. (Whether translations must land before
C11-183 closes is surfaced to the operator as S5; CI ignores
`Localizable.xcstrings` paths, so nothing will nag automatically.)

### Phase 4: proportionate behavioral tests

Target membership is stated explicitly per file — the on-disk directory does
NOT determine target membership here (the C11-105 trap):

- `c11Tests/SidebarActivityProjectorTests.swift` — **member of `c11LogicTests`**
  (despite living in `c11Tests/` on disk):
  - suppressed unflagged waiting becomes idle;
  - flagged+suppressed waiting remains waiting;
  - modifier priority/composition and default-false compatibility.
- **`MarkPresentation` resolver table test** — goes in a file that is already a
  `c11LogicTests` member (`SidebarWidthPolicyTests.swift`,
  `WorkspaceDerivedActivityTests.swift`, or `WorkspaceContentViewVisibilityTests.swift`
  are members and topically adjacent; do NOT add `WorkspaceUnitTests.swift` to
  the logic target — pbxproj edits normalize into huge diffs and would drag
  host-dependent classes across). Compact table-driven coverage: flag beats
  suppression; unflagged suppressed waiting projects to idle; ANY unflagged
  suppressed state is static (including suppressed working = static full
  grid); flagged waiting replaces the dip and never stacks two motions;
  flagged idle/cold still; Reduce Motion zeroes motion for every input;
  ineligible zeroes motion. Plus one phase-offset determinism assertion for a
  fixed UUID (FNV-1a stability).
- **9pt sizing assertions** — same rule: land in a `c11LogicTests`-member file
  reaching `WorkspacePulseMarkRowMetrics` through the existing `@testable
  import`, NOT in `WorkspaceUnitTests.swift` (which is a member of the
  host-bound `c11Tests` target only):
  - slot never drops below 9pt;
  - mark side remains exactly 9pt while crowded rows overflow.
- **Existing metrics assertions that change (named, deliberate):** raising
  `minimumSlot` 8 → 9 raises the stride 10 → 11 and shifts the overflow onset,
  so `testVeryCrowdedRosterShrinksMarksAndKeepsThemAllVisible` (which asserts
  shrink-below-preferred and `markSide == min(9, slot)`) becomes false by
  design, and `testOverflowingRosterCountsTheRemainder` changes its
  visible/hidden split. Rewrite them to the new contract with a comment stating
  the ladder shifted because `minimumSlot` rose — do not tune numbers until
  green. These live in the host-bound target; their rewrite rides to CI.
- existing Bonsplit behavior/metric tests, adjusted only to the new 9pt grammar.

No source-text, plist, or project-file assertions. No dedicated fleet harness,
no host-bound local `c11-unit` run, and no oversized animation test matrix.

## Verification commands and evidence

Baseline (Phase 0):

```sh
git status --short --branch
git rev-parse HEAD
git submodule status vendor/bonsplit ghostty
git submodule update --init --recursive ghostty vendor/bonsplit
ln -s <main-checkout>/GhosttyKit.xcframework GhosttyKit.xcframework
```

Bonsplit (final state, after both logical commits):

```sh
swift test --package-path vendor/bonsplit
git -C vendor/bonsplit diff --check
git -C vendor/bonsplit fetch origin
git -C vendor/bonsplit merge-base --is-ancestor HEAD origin/main
```

c11 pure behavior (actual test action; class names below are the
`c11LogicTests`-member homes chosen in Phase 4 — subject to the C11-181
local-run caveat in the Outcome section, in which case these run in CI):

```sh
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic \
  -configuration Debug -destination "platform=macOS" test \
  -only-testing:c11LogicTests/SidebarActivityProjectorTests \
  -only-testing:c11LogicTests/<chosen-logic-member-class-for-metrics-and-resolver>
```

Compile:

```sh
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 \
  -configuration Debug -destination "platform=macOS" build
```

Final scope and delivery:

```sh
git diff --check
git status --short --branch
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
git -C vendor/bonsplit merge-base --is-ancestor HEAD origin/main
git push -u origin codex/C11-183-mark-vocabulary
git rev-parse HEAD
git rev-parse origin/codex/C11-183-mark-vocabulary
```

Do not launch an untagged DEV.app. This implementation stage records only what
it actually ran and makes no visual or typing-latency claims.

## Validation handoff (owned obligations, not a harness)

Per the operator clarification's trailing clause ("perform proportionate
tagged-build validation"), the following are named acceptance obligations for
the fresh validation stage. Owner: the parent orchestrator's validation
stage/actor. This is a handoff contract, not a QA harness; its scope beyond the
items named here is the operator's call (surfaced as S2).

- Launch path: tagged build via `./scripts/reload.sh --tag <tag>` /
  `scripts/launch-tagged-automation.sh <tag> --qa fresh`. Never untagged.
- Fleet condition: reproduce a realistic multi-agent load (the ticket's frame:
  ~20 working agents ≈ 40+ animating leaves across tab chips + sidebar rows).
- Metric and bound: typing latency on the tagged build under that fleet, fill
  and dip measured INDEPENDENTLY (the spec's ladder order is a hypothesis to
  validate empirically, not an assumption). Failure = a perceptible regression
  against the same build with `Static marks` on; record numbers either way.
- Ladder contingency (named): if the gate fails, the parent orchestrator
  applies the spec's degradation ladder rung (dip-only default, then static
  default), records the outcome on C11-183 per the ticket's "Done when"
  escape hatch, and decides what the `Static marks` settings row says if the
  shipping default becomes static. Which ticket absorbs ladder implementation
  work is the orchestrator's call at that point.
- Visual acceptance at true 9pt, both renderers side by side, in BOTH Light and
  Dark theme slots (mark colors are theme-resolved per workspace background, so
  the light pass is required — the 25%-opacity base square and the
  1.5pt-vs-1pt frame discrimination are the at-risk elements):
  - all four states distinguishable in greyscale (the ticket's thesis);
  - both renderers draw the new set and agree;
  - 1x (non-Retina) legibility: at 1x the grid is 2px dots on 3px pitch and
    waiting/idle discrimination is a 2px vs 1px stroke;
  - flagged violet contrast in the light theme.
- Registration hygiene: the debug-only registration counter reads zero on app
  deactivation, workspace deselection, and scroll-out.

## Risks and mitigations

- **Typing-hot invalidation:** keep clock observation/subscription inside mark
  leaves; never add observable state to c11 `TabItemView`, and preserve its
  equality inputs and `.equatable()`. Note: Bonsplit's own `TabItemView` is NOT
  `.equatable()`-gated (only c11's is), so leaf isolation carries MORE weight
  on the Bonsplit side — the animated leaf's `@State` must be the only thing
  invalidated by a beat there too.
- **Timer proliferation:** one shared clock with registration tokens; leaves
  never construct timers or TimelineViews. Debug registration counter makes
  leaks observable.
- **Offscreen battery work:** register only eligible/on-screen leaves, unregister
  on disappearance/eligibility loss, and stop the shared timer with no live
  registrations or while the app is inactive.
- **Phase instability:** FNV-1a over UUID bytes (named above), never Swift
  `Hasher`.
- **Modifier ambiguity:** the `MarkPresentation` resolver is the single source
  of composition truth, with a table-driven test; flagged-over-suppressed and
  flagged-waiting replacement cannot stack two motions because the resolver
  returns exactly one `motionChannel`.
- **Submodule orphaning:** ONE Bonsplit delivery — both logical commits pushed
  as a final HEAD to `origin/main`, ancestry proven, then a single parent
  pointer commit. Push disclosure and rollback path stated in Phase 1.
- **Geometry drift:** use the same named geometry constants/order in both
  renderers and review the final diff side by side. (The trident review argues
  drift should be structurally impossible via a shared public mark view — that
  is part of the open Phase 2 decision, S1.)
- **Localization scope:** English at `String(localized:)` call sites only;
  the six-locale pass is a named follow-up ticket (Phase 3), not a note.

## Explicit non-goals

- No flag/suppress CLI, socket, metadata, persistence, event, sidebar-row,
  banner, system-notification, launch-agent, or keyboard-priority primitives.
- No `docs/c11-attention-model-skill-section.md` landing and no installable-skill
  edit/sync.
- No lifecycle color changes and no new lifecycle state.
- No dedicated QA/performance harness or heavyweight fleet benchmark.
- No upstream Bonsplit PR.
- No PR in the parent repository (rationale and CI obligation stated in
  Outcome).
- No host-bound local test run and no untagged app launch.
- No unrelated primary-checkout edits; only this shared Lattice plan/events and
  the isolated implementation worktree are in scope.

## Reset 2026-07-28 by agent:codex-mark-orchestrator

## Reset 2026-07-28 by agent:codex-mark-rereviewer
