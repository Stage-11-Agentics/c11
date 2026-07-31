# Adversarial Plan Review — c11-185-plan

PLAN_ID: `c11-185-plan`  
MODEL: `Codex`

## Executive Summary

**Recommendation: revise before implementation.**

The ticket is unusually precise, but the six-step plan is not yet an executable bridge to it. The largest issue is temporal truth: the plan says to precompute help and capture structured details, but it never defines how durations are recomputed on hover or while Surface Details remains open. In the current code, top-tab presentation sync is edge-driven, sidebar values re-render only when published state changes, and Surface Details has no clock. A literal implementation can therefore be semantically correct at capture time and visibly wrong minutes later.

Four other gaps are substantial:

1. There is no authoritative state-start selection matrix for working, idle, cold, waiting, or suppressed waiting.
2. Surface Details has no specified capture/provider seam for panel-owned `createdAt`, activity truth, refresh, timezone-safe display, or copy values.
3. The Bonsplit accessibility seam is underspecified and currently composes host detail before the lifecycle, then appends the default lifecycle. Supplying the new full string would duplicate or misorder VoiceOver output.
4. Worktree, ancestry, submodule-branch setup, safe host-test commands, independent review, and PR/CI ordering are left implicit despite concrete repository hazards.

The plan is directionally right. It is not safe to treat “a competent agent will infer the rest from the ticket” as sufficient here, because the missing decisions sit exactly where plausible implementations diverge.

## How Plans Like This Fail

This kind of feature usually fails through several individually reasonable local choices:

- **Frozen relative time.** A formatter is pure and well tested, but nobody owns a refresh event. “Idle for 2 minutes” stays visible for twenty minutes.
- **Three almost-shared truths.** Top tabs, sidebar marks, and Surface Details all consume similar inputs through different update paths. They agree in unit tests at a supplied `now` but drift in the running app.
- **A timestamp is available, so it is treated as the timestamp.** Metadata write time, last input, notification creation, cold crossing, and panel construction are all dates, but they have different meanings.
- **Legacy restore silently fabricates history.** An initializer default of `Date()` turns a missing legacy `created_at` into a new creation time during restore.
- **Accessibility is appended rather than projected.** The visual tooltip is correct while VoiceOver says modifiers first or repeats the lifecycle.
- **A native tooltip is attached to the wrong layer.** It lands on the whole tab or row, changes hit testing, or misses the padded mark target.
- **Submodule work begins detached.** The implementation is correct, but its commit is orphaned or the parent points at a commit not reachable from remote `main`.
- **Screenshots prove presence, not behavior.** One captured tooltip does not prove duration rollover, cold-threshold arithmetic, hover refresh, overflow behavior, or that click/context-menu/close interactions remain intact.

The present plan is vulnerable to every one of these except the obvious legacy-decoding case, which it at least names.

## Assumption Audit

### Load-bearing assumptions

- **“Pure activity-help projection” implies a single timestamp policy.** It does not. The plan must state the exact inputs and precedence used to select `stateStartAt` and `lastActivityAt`.
- **Precomputation can satisfy hover freshness.** It cannot without an explicit refresh rail. `Workspace.syncSurfaceTabActivityStateForPanel` currently avoids a Bonsplit update when state/presentation are unchanged; the 10-second detector sweep does not force unchanged presentation updates. The sidebar has the same edge-driven problem.
- **The existing coarse clock is already available to these views.** It is available as an animation primitive, not as a defined activity-age contract. The plan must decide whether to reuse it, add a bounded visible-view clock, or resolve only on hover.
- **The notification store exposes the waiting start.** It currently exposes exact-surface unread presence, not the matching record’s `createdAt`. A precomputed timestamp query/index is required; renderer-side scans would violate the guardrails.
- **`createdAt` promotion is mechanically safe.** It is only safe if fresh creation and legacy restore are distinguishable at every constructor. A defaulted `Date()` parameter is especially dangerous unless restore always passes explicit `nil`.
- **Surface Details can “capture structured data” with its current API.** Its capture function currently has only workspace/surface IDs and reads only `SurfaceMetadataStore`; it has no panel reference, panel creation date, notification timestamp, or shared activity projection.
- **The existing Bonsplit accessibility field can carry the new semantics.** Today it is additive: host `accessibilityValue` is appended before Bonsplit’s lifecycle value. That cannot express “lifecycle, duration, modifiers” without duplication or wrong ordering.
- **A self-review is an adequate review gate.** It is not an independent review. The Lattice workflow and this repository’s normal ticket discipline expect a fresh reviewer before validation.
- **The linked branch is current enough.** At review time `feat/c11-185-agent-activity-details` is one commit behind `main`. It contains C11-183 and C11-184, but the plan has no base/ancestry check or fast-forward step.

### Secondary assumptions

- Locale-aware duration formatting will automatically yield the locked “for …” grammar. `RelativeDateTimeFormatter` naturally produces “ago/in,” not a duration noun phrase. The formatter and localized sentence structure need an explicit design.
- Timezone abbreviations are unambiguous copy values. They are not globally unambiguous; display and clipboard formats may need to differ.
- All panel creation paths funnel through the three obvious helpers. Direct terminal replacement, placeholder repair, closed-browser reopen, transfer, and alternate restore paths need an explicit audit.
- One translation agent will notice both c11’s string catalog and Bonsplit’s seven `.lproj` catalogs. The plan should name both outputs.

## Blind Spots

### 1. No timestamp provenance matrix

The plan needs a table or equivalent pure resolver contract:

- **Working:** which of activity metadata source time and `SurfaceActivityTracker.lastActivity` wins, especially when input occurs without a lifecycle-state change?
- **Idle:** same question, including notification-triggered lifecycle settlement.
- **Cold:** start must be `trustedLastTouch + threshold`, not `trustedLastTouch` and not the moment the cold Boolean happens to publish.
- **Waiting:** use the exact signal-eligible unread record’s `createdAt`; define the missing-record fallback.
- **Suppressed waiting presented as idle:** use the idle lifecycle/input boundary, not the unread record’s waiting time.
- **Flag + suppression:** modifier order must remain lifecycle, flagged reason, suppression.
- **Missing, future, or contradictory timestamps:** define fail-closed behavior and ensure no negative or fabricated zero duration.

Without this, “same projection” merely centralizes an ambiguous answer.

### 2. No duration-format contract

Tests cannot be written deterministically until the plan specifies:

- units and rollover boundaries;
- floor versus nearest rounding;
- behavior below one minute and exactly at a boundary;
- behavior at the instant cold begins;
- handling of future dates/clock correction;
- whether state-only fallback applies to a real duration that rounds to zero;
- how plural-safe localized duration text is composed without forcing English word order.

### 3. No refresh ownership

The plan must distinguish three consumers:

- Top tab: resolve fresh help on hover entry without store reads/date formatting in the typing-hot tab body.
- Sidebar summary and census marks: resolve on each mark’s hover entry from immutable payload.
- Surface Details: age and activity duration continue advancing while the panel is visible, with one bounded leaf subscription and no per-agent timer.

The immutable payload should carry semantic inputs, not a string that ages in place. If Bonsplit must resolve time at hover, its public payload needs a generic, Codable/Sendable representation that still leaves lifecycle/modifier wording owned by c11.

### 4. Surface Details is not designed

Step 3 does not say:

- how `SurfaceManifestSnapshot.capture` receives panel `createdAt` and the shared activity projection;
- whether capture is performed by `Workspace`, a testable provider, or a global lookup;
- what Activity shows for browser/markdown/non-agent surfaces;
- what happens if the surface closes while the utility window is open;
- how Refresh rereads panel, tracker, notification, and attention truth atomically enough to agree;
- how the visible relative values tick after Refresh;
- how timezone is included;
- whether the displayed local timestamp or an ISO-8601 value is copied;
- where copy affordances live for Created and Last activity;
- how Captured remains unchanged in meaning and visually distinct.

This is too much behavior to leave under “capture structured data.”

### 5. Creation-path completeness is not gated

The plan should enumerate fresh create, session restore, legacy restore, panel transfer/detach, terminal replacement/placeholder repair, browser reopen, and any layout-executor path. It should then state which operations preserve identity/creation and which deliberately create a new logical surface.

The key regression test is not merely Codable round-trip. It is: a legacy snapshot with no `created_at` enters the real restore constructor and the resulting panel still has `createdAt == nil`.

### 6. Interaction and accessibility regressions are weakly covered

The test list does not explicitly cover:

- tooltip attached to the padded mark target, not the tab/row/composition rail;
- tab selection, context menu, close button, overflow, and layout unchanged;
- top-tab accessibility lifecycle first, modifiers second, and no duplicate default lifecycle;
- both sidebar locations receiving the same value and order;
- tooltip refresh after elapsed time changes without lifecycle mutation;
- Surface Details live age and Refresh behavior;
- copy value including an unambiguous timezone/offset.

### 7. Operational sequencing is incomplete

The plan must make these preconditions explicit before source edits:

- create/use an isolated worktree from an agreed current base and verify C11-183/C11-184 ancestry;
- provision submodules/framework as required;
- enter Bonsplit `main`, fetch and fast-forward it before editing, and recheck remote drift before push;
- record exact owned paths and baseline status;
- use `c11-logic` only for pure slices and `scripts/test-unit-local.sh` for host-required local tests;
- open the draft PR early enough for PR CI to inform validation, or explicitly justify relying on local evidence first;
- use an independent reviewer, not only builder self-review;
- record the scoped computer-use approval and exact tagged QA flow before UI interaction.

## Challenged Decisions

### Precompute “help” as a final localized string

If that is what step 2 intends, it is the wrong abstraction. Precompute semantic evidence—presented lifecycle, trustworthy start, last activity, modifiers—and resolve the time-sensitive string at a bounded leaf event. Otherwise the implementation either freezes or pushes periodic updates through every tab/card.

### Put generic help into `BonsplitTabActivityPresentation` without redefining accessibility semantics

The public seam needs an explicit distinction between:

- tooltip/help payload;
- complete accessibility override versus additive accessibility detail;
- whether Bonsplit should append its default lifecycle and waiting hint.

Leaving the current additive behavior in place cannot meet the locked VoiceOver order.

### Use only snapshot round-trip tests for creation time

That proves serialization, not constructor behavior. The dangerous defect happens after decode when a restore helper calls an initializer whose default is `Date()`.

### Treat screenshots as sufficient interaction evidence

Screenshots are necessary for visible copy and placement, but a short UI scenario must also exercise selection, right-click Surface Details, close/overflow behavior, hover of both sidebar mark locations, and elapsed-time refresh. Evidence should include timestamps or a repeat capture that proves aging.

### Push Bonsplit near the end

Pushing near the end is fine; preparing Bonsplit near the end is not. Branch checkout/fast-forward and remote ownership must be established before its first edit. A final fetch/ancestry check is then required before the parent pointer commit.

## Hindsight Preview

The likely “we should have known” outcomes are:

- A user reports a tooltip that still says “2 minutes” after a long meeting because all tests injected one fixed `now`.
- Surface Details says an old restored surface was “Created” at app launch because restore fell through a fresh-create default.
- The top tab says “Flagged: …, Working” while the sidebar says “Working …, Flagged: …” because the Bonsplit field remained additive.
- Cold duration is actually total idle duration because the Boolean carried no crossing timestamp.
- The displayed timestamp says `CST`, and the clipboard value is not globally interpretable.
- A submodule pointer lands to a detached or no-longer-main commit after another contributor advances Bonsplit.

Early warning signs the plan should require:

- any final tooltip string stored in long-lived model state;
- any renderer calling `Date()` without an injected/testable now or hover/visible clock owner;
- any use of metadata write time as logical creation;
- any restore constructor where omitted and explicit-`nil` creation dates are indistinguishable;
- any VoiceOver implementation that combines both a full host activity string and Bonsplit’s default lifecycle;
- any Bonsplit edit while `git symbolic-ref --short HEAD` is not `main`.

## Reality Stress Test

Three likely disruptions arriving together:

1. The agent stays idle without another state transition for twenty minutes.
2. The app restores a pre-C11-185 snapshot.
3. Bonsplit `origin/main` advances while implementation is underway.

Under the current plan, the tooltip can freeze, Created can be fabricated during restore, and the submodule push/pointer can race remote history. None is exotic. They are normal operation. The revised plan needs explicit mechanisms for all three, not only end-stage review.

## The Uncomfortable Truths

- “One shared projection” is currently a slogan, not a fully specified source-of-truth algorithm.
- The plan spends more precision on commit choreography than on the hardest product requirement: time that remains truthful.
- Step 3 understates Surface Details enough that an implementer could satisfy its wording while missing timezone, copy, live aging, refresh, and non-agent behavior.
- The Bonsplit change is not just “generic help data.” It is an accessibility-composition contract change, and treating it as a passive optional string is likely to ship duplicate output.
- Self-review plus screenshots is not a rigorous terminal gate for a feature whose main failure modes are invisible in a static screenshot.

## Required Plan Amendments

Before implementation, add:

1. A pure `ActivityHelpProjection` input/output contract with an injected `now` and an explicit state-start provenance matrix.
2. A precomputed exact-surface unread timestamp API/index and a rule forbidding notification scans in renderers.
3. A refresh design for top-tab hover, sidebar-mark hover, and visible Surface Details.
4. A Surface Details capture/provider design covering Activity, Created, Last activity, Captured, refresh, closure, timezone, selection, and copy.
5. An explicit Bonsplit help/accessibility override contract with legacy decode/transfer tests.
6. A complete creation/restore path inventory and real-constructor legacy test for all three panel types.
7. Interaction regression checks for mark hit areas, selection, context menus, close/overflow, and exclusion of the composition rail.
8. Worktree/base/submodule preflight, safe exact test commands, independent review, PR-CI ordering, and recorded computer-use scope.

## Hard Questions for the Plan Author

1. What exact timestamp is `stateStartAt` for each presented state, and what wins when tracker time and metadata-source time differ?
2. When raw waiting is suppressed and presented as idle, which timestamp drives “Idle for …”?
3. How does cold retain the exact threshold-crossing start without introducing a second lifecycle derivation?
4. What causes a top-tab tooltip to change from “2 minutes” to “3 minutes” if no lifecycle, attention, notification, or terminal-kind value changes?
5. How is that hover refresh implemented without formatting dates in the typing-hot `TabItemView` body?
6. What clock keeps Surface Details current while open, and how is its subscription bounded to one visible leaf?
7. What is the exact locale/plural/rounding policy below one minute, at one minute, at the cold boundary, and for future timestamps? **Current answer appears to be “we do not know.”**
8. Which API returns the exact signal-eligible notification `createdAt` for a surface, and why is that read guaranteed to match the state resolver?
9. How does Surface Details obtain a live panel’s `createdAt` without abusing metadata or freezing an immutable handle captured at window construction?
10. What does Activity display for browser, markdown, shell, and agent surfaces with no trustworthy lifecycle evidence?
11. What does the Copy action place on the pasteboard: localized display text, timezone abbreviation, numeric offset, or ISO-8601?
12. How will the Bonsplit API prevent a complete c11 accessibility string from being followed by Bonsplit’s default “Running/Idle/…” value?
13. Which direct panel constructors and reopen/transfer/replacement paths were audited, and which preserve versus reset logical creation?
14. How does a decoded legacy `created_at == nil` get passed explicitly through restore without triggering a fresh-create default?
15. Why is the final gate a self-review rather than a fresh independent review?
16. Will the draft PR be opened before validation so CI can inform the tagged run, or is local host evidence intentionally the gate?
17. What exact commands constitute “focused safe logic/host tests,” and where is the `scripts/test-unit-local.sh` requirement recorded?
18. Where does the plan require Bonsplit to be on updated local `main` before the first edit, not merely reachable from remote after the last edit?
19. What is the approved computer-use scope—tagged app, hover/right-click flows, screenshots, and data limits—and where will it be recorded?
20. If the tooltip, accessibility value, and Surface Details disagree at one injected clock instant, which test fails through an executable path?
