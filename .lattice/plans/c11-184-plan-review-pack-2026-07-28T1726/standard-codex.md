# Standard Plan Review — C11-184

## Executive Summary

This is a strong plan for the right feature, and its central architecture is sound: flagging and suppression should remain orthogonal modifiers over the four-state lifecycle; metadata should remain canonical; notification history and attention signalling must be separated; renderers should consume precomputed values; Bonsplit should receive only generic host presentation; and the terminal banner belongs in the AppKit portal layer.

My verdict is **Needs revision**, not “Needs rethinking.” The overall decomposition is substantially the one I would choose. The plan is also unusually good about repository-specific hazards: it protects typing-hot paths, makes Reduce Motion authoritative, preserves notification history, closes generic metadata bypasses, respects C11-165 focus/ref behavior, calls out submodule reachability, forbids local test actions per the operator’s instruction, and requires tagged visual and fleet-scale latency evidence.

However, implementation should not begin yet. Five contract gaps are still capable of producing internally inconsistent behavior:

1. The binding spec says a suppressed surface sends no system notification, while the plan leaves that decision open in one section and pre-accepts “direct flag delivery pierces suppression” in its visual gate and acceptance checklist.
2. The proposed original flag epoch is not representable under the current metadata write behavior when an active flag’s reason changes.
3. The raw-versus-signal notification split is conceptually right but lacks a published invalidation mechanism and a complete consumer migration contract.
4. The plan requires flag reason/state accessibility in both renderers without carrying the reason through either renderer’s presentation model.
5. The priority-jump action is broader than the current menu/status affordances that invoke and enable it; a flag-only state would leave at least one existing jump affordance disabled or mislabeled.

Resolve those before Phase 1. They are narrow revisions to an otherwise executable plan.

## The Plan’s Intent vs. Its Execution

The real intent is not merely to add two metadata fields or two visual treatments. It is to preserve the operator’s trust in c11’s attention signal at fleet scale:

- routine completion remains visible in history but can be removed from the demand channel;
- exceptional human blockers rise above routine waiting;
- a background worker can remain quiet unless it genuinely needs intervention;
- every visual and navigation surface agrees about which agent needs the operator.

The plan serves that intent well. In particular, it correctly rejects a linear `suppressed | normal | flagged` state and preserves the existing four lifecycle shapes. It also correctly treats a flag as declared state and waiting as derived state. That distinction is the foundation of the feature.

There are three places where execution currently drifts from intent.

First, the plan has not resolved what “suppression is not a gag” means outside the app. The binding feature spec says “Suppressed surfaces deliver no system notification, by definition,” while the plan’s tagged validation item 8 and acceptance checklist require the direct flag notification to pierce suppression. Its final “operator-held” section then says the faithful spec reading is “no.” This is not a harmless late implementation choice because it changes the headline promise, the validation matrix, and the meaning of suppression. Phases 0–2 can be reasoned about independently, but the implementation plan as a whole cannot have two acceptance outcomes.

Second, the plan uses “flag” for two related but not identical meanings: “work has stopped and only a human can restart it” and “a critical mission the operator intends to watch from dispatch.” The binding spec explicitly permits the latter, so this is not necessarily wrong, but the consequences are unspecified. Does `launch-agent --flag` immediately send the operator a system notification for the flag they just created? Does that mission-level flag remain raised through ordinary completion? If so, a flagged mission is an operator watch marker, not necessarily a human blocker. That distinction needs one explicit launch-time delivery rule so the rare escalation tier does not become noisy at dispatch.

Third, the plan says every human-facing projection of suppressed waiting becomes idle, but its implementation language sometimes treats signal eligibility as though it were the raw lifecycle input. Those must stay distinct. A suppressed, unflagged unread is raw waiting/history plus presented idle/no signal. A suppressed, flagged unread is raw waiting plus presented waiting/flag priority. The code should not erase the raw input merely because a signal query filters it.

## Architectural Assessment

### What is architecturally right

The proposed `SurfaceAttentionService` is the correct center of gravity. The feature crosses metadata, observable presentation, notification eligibility, event emission, direct delivery, restore, transfer, and pruning. Leaving those as independent side effects at socket/UI call sites would guarantee drift. A single serialized mutation boundary is the right move.

The plan is also right to keep `SurfaceMetadataStore` authoritative and make the attention index a bounded cache over active surfaces. That preserves the existing persistence path and avoids a second database or snapshot format.

The dual notification-index model is the correct abstraction. Suppression is not deletion or read-state mutation. Raw unread/history and signal-eligible unread are genuinely different views over the same records, and the plan names that distinction clearly.

The renderer architecture is also correct:

- lifecycle shape remains the semantic channel;
- flag color/motion is a modifier;
- suppression has no independent visual treatment;
- the sidebar and Bonsplit receive immutable precomputed values;
- motion remains leaf-isolated and shared-clock driven;
- the terminal banner is portal-owned and does not resize the PTY.

### Blocking architectural gaps

#### 1. The flag epoch has no durable representation for reason revisions

The plan says an active-to-active reason revision preserves the original queue timestamp across relaunch, and it identifies the metadata source timestamp as the raise time. Those two statements do not work with the current store without a specified new write primitive.

`SurfaceMetadataStore.setMetadataLocked` preserves the existing `SourceRecord.ts` only for an identical same-source write. A changed reason writes a new value and a new timestamp (`Sources/SurfaceMetadataStore.swift:725-742`). Therefore:

- using the source timestamp directly moves a revised flag to the back;
- preserving the epoch only in the observable index loses it on relaunch;
- restoring from snapshot cannot recover an epoch that was already replaced.

The plan must choose a durable mechanism. My recommendation is an attention-specific atomic metadata mutation that updates the flag value while explicitly preserving the existing `flag` source record timestamp when the flag was already active. A new canonical `flag_raised_at` key would also work, but it expands the public model beyond the two binding fields and creates more generic-clear/replace surface area. Preserving the sidecar timestamp is the cleaner fit if the store API makes the behavior explicit and testable.

The same primitive must define mixed `mode=replace` behavior and lower-then-raise behavior atomically.

#### 2. Signal-index refresh needs a publication and consumer contract

Today `TerminalNotificationStore.notifications` is `@Published`, and its `didSet` rebuilds private indexes. Views observe the array, then call computed methods such as `unreadCount` and `hasUnreadNotification`. If suppression changes while the notification array does not, rebuilding a private signal index alone will not invalidate those views.

The plan correctly says not to rewrite `notifications` merely to trigger `didSet`, but it does not say what replaces that trigger. Add an explicit published signal snapshot or monotonically increasing `signalRevision`; make index replacement and publication part of the attention commit. Avoid ad hoc `objectWillChange.send()` calls scattered across the service.

The plan also needs an API ownership table. Existing code uses raw notification state for both history operations and signalling:

- the notifications list and explicit mark-read/remove operations need raw records;
- sidebar waiting state, workspace pulse demand, surface-tab waiting presentation, titlebar badge, menu-bar icon/count, Option-V fallback, and waiting edges need signal-eligible records;
- direct focus currently uses raw unread existence to mark a record read, which should not silently stop working merely because the record is suppressed.

Do not silently change the meaning of `hasUnreadNotification`. Introduce explicit names such as `hasRawUnreadNotification` and `hasSignalEligibleUnreadNotification`, then migrate each caller deliberately. The direct raw-array consumers in `ContentView`, `WorkspaceContentView`, `c11App`, `UpdateTitlebarAccessory`, and `AppDelegate` need to be included in the owned-seam audit, even if not all ultimately change.

#### 3. Generic metadata mutation remains a design choice, not an executable rule

The plan allows either routing generic `surface.set_metadata` / `clear_metadata` through the attention service or rejecting the keys and requiring the flag family. Those alternatives have materially different attribution, timestamp, idempotency, and mixed-transaction semantics.

This should be decided before coding. I recommend making the flag-family methods the sole mutation API for `flag` and `suppressed`, while keeping both fields visible through `get-metadata`. Generic set/clear/replace requests that would add, revise, or remove either attention field should fail with a precise protocol error. This gives the service a complete mutation perimeter, preserves `by`, and avoids guessing whether a generic metadata client is an operator or an agent.

If generic writes remain allowed, the plan must specify:

- how `by` is derived;
- how an active reason revision preserves its epoch;
- how a mixed replace commits ordinary metadata and attention atomically;
- what happens when precedence rejects one attention key but accepts another;
- whether clear-all lowers a flag and emits `flag.lowered`, and with which actor.

#### 4. Dominance and accessibility values are under-modeled

“Dominant attention precedence is flagged > waiting > working > idle > cold without adding a `WorkspacePulseState` case” is not an executable type contract. `WorkspacePulseSummary.dominant` currently returns `WorkspacePulseState`. It cannot return “flagged” without either:

- a separate `WorkspacePulseDominance`/attention-priority type;
- a `(state, flagged)` presentation value;
- or a `dominantAgent` plus derived presentation.

Choose one and identify the consumers. `flaggedCount` alone does not define what `dominant` returns for a flagged-working agent.

Likewise, the plan requires accessibility to announce flag state and reason, but the proposed renderer payloads do not carry the reason:

- `WorkspacePulseAgent` currently carries booleans but no flag reason;
- the proposed generic Bonsplit presentation mentions color, motion, and alternate core color but no accessibility override.

Carry a normalized reason into the sidebar agent presentation and add a generic accessibility value/help override (or equivalent host-supplied accessibility descriptor) to Bonsplit. Keep the public Bonsplit vocabulary generic; it does not need to call the field `flagReason`.

Also decide whether the generic Bonsplit presentation is encoded. It is derived cache, not canonical truth. Persisting it in `TabItem` risks restoring stale violet/motion state before the metadata-backed attention index hydrates. Prefer an optional non-authoritative field that defaults to nil on decode and is recomputed by c11 after restore, unless a concrete transfer path truly requires encoding.

#### 5. Direct system-notification lifecycle is incomplete

The plan covers identical-raise dedupe and says a changed reason may send an updated notification, but it does not define the OS notification identifier or cleanup semantics.

Use a stable identifier per surface and active flag epoch so a reason revision replaces the prior pending/delivered notification instead of creating a second OS-level item. Specify whether:

- lowering removes pending and/or delivered flag notifications;
- suppressing an already-flagged surface removes a pending flag notification under the eventual suppressed-delivery policy;
- clicking a direct flag notification focuses without lowering or reading history;
- launch-time flags deliver immediately or only arm the visual watch state.

“Optional direct system delivery completes before the socket response” also needs precise wording. `UNUserNotificationCenter.add` is asynchronous. The commit can guarantee that scheduling was requested/enqueued before response, not that macOS delivered the banner.

#### 6. Priority navigation has stale callers and affordances

The pure selector is good, and passing `notificationId: nil` when opening a flag correctly avoids marking unrelated notification history read.

But the existing status-menu item is enabled from unread notification count and is labeled “Jump to Latest Unread.” With one flag and zero signal-eligible unread records, the new priority action would exist while that menu item remains disabled and inaccurately named. The plan’s “all existing call sites stay one action” requirement must include:

- enablement when either an active flag or signal-eligible unread exists;
- updated localized copy that remains true for both phases;
- tooltip/state-hint behavior;
- the menu-bar unread count remaining signal-eligible notification count rather than being overloaded with flag count.

The same audit should cover any command-palette or menu predicates that currently derive “has unread” directly from the raw notification array.

## Is This the Move?

Yes, after revision.

I would keep the plan’s phase structure and service-centered architecture. I would not turn flag/suppression into lifecycle enum cases, put the banner in SwiftUI layout, query metadata from `TabItemView`, or insert flags into `TerminalNotificationStore`. Those alternatives all lose important semantics or create known performance/layout hazards.

I would make three refinements:

1. **Use an attention-specific store transaction beneath the service.** It should return prior and committed typed attention state, preserve the active epoch across reason revisions, and make replace/clear behavior explicit.
2. **Expose two named notification views and one published signal snapshot.** Raw history remains the array; signal consumers never inspect it directly.
3. **Make one shared attention presentation value feed both renderers.** It should include presented lifecycle, color/motion policy, flagged state, and normalized accessibility text. Bonsplit receives the generic visual/accessibility subset; the c11 sidebar receives the same semantic projection.

An alternative would be to split this into separate model/signal and UI PRs. That would reduce review size, but it also creates an awkward intermediate state where canonical modifiers exist without a trustworthy operator surface. Given the plan’s draft-PR discipline and coherent commit units, one PR is defensible. The Bonsplit commit should still be independently reviewable and pushed/reachable before the parent pointer lands.

## Key Strengths

1. **Correct domain model.** Orthogonal modifiers preserve the valuable suppressed-plus-flagged combination without corrupting lifecycle meaning.
2. **Canonical-state discipline.** Metadata remains authoritative and the attention coordinator is explicitly a cache, not a second persistence layer.
3. **A real commit boundary.** Centralizing metadata, projection, eligibility, events, and delivery is the right defense against cross-layer drift.
4. **History/signal separation.** The plan preserves records instead of implementing suppression as deletion, read-state mutation, or notification avoidance.
5. **Performance-aware rendering.** Immutable precomputation, leaf isolation, one shared clock, visibility gating, and a measured fallback ladder match c11’s typing-latency constraints.
6. **Correct portal ownership.** The banner follows the proven find-overlay pattern and explicitly avoids PTY geometry changes and hot-path work.
7. **Good operational gates.** Exact ancestry, isolated DerivedData, Release compile, CI-only XCTest execution, tagged socket validation, explicit computer-use approval, and submodule reachability are all appropriately concrete.
8. **Good idempotency intent.** No duplicate events, notifications, queue entries, or epoch resets is the right bar for automation-facing mutation commands.
9. **Focus safety.** Explicit refs and non-focus mutation behavior preserve the C11-165 contract.
10. **Bounded review discipline.** One correctness review, one fix pass, and one terminal re-review is an appropriate closeout budget after architecture acceptance.

## Weaknesses and Gaps

### Blocking

- Suppressed-plus-flagged external delivery has contradictory acceptance criteria.
- Active flag epoch preservation is not supported by the specified metadata representation/write path.
- Signal-index changes have no explicit publication mechanism.
- Raw and signal consumers are not exhaustively classified, making leakage and broken read behavior likely.
- Generic metadata mutation semantics and actor attribution remain undecided.
- Flag reason cannot reach the required renderer accessibility output.
- Flag-only priority navigation leaves existing menu enablement/copy stale.

### Significant but non-blocking once specified

- `flag.list` scope is unclear in a multi-window process: global active flags, one window’s `TabManager`, or an optional workspace/window filter.
- “Machine-readable launch/list results” does not identify which list methods gain attention fields (`flag.list`, `surface.list`, or both).
- Launch-time flag delivery is unspecified and may generate an immediate redundant notification.
- Direct flag notification identifiers, revision replacement, and lower/suppress cleanup are unspecified.
- The plan requires persistence but the tagged validation flow does not explicitly include quit/resume verification. Logic restore tests are valuable, but a real tagged relaunch would catch service hydration and stale presentation issues.
- Transfer hooks are named but not contractually detailed. A detached flagged surface must preserve reason and epoch while changing workspace ownership, and the source index must not briefly leave a stale queue entry.
- “Trusted operator-originated” socket attribution has no trust model. If `by` is provenance rather than an authorization boundary, say so; otherwise define how it is authenticated.
- Unicode validation should reject all newline scalars, not only LF, and the 256-character cap should state whether it is measured after trimming/normalization.

## Alternatives Considered

### New lifecycle cases

Rejected correctly. Adding `.flagged` or `.suppressed` lifecycle cases cannot represent flagged-working versus flagged-waiting and makes suppressed-plus-flagged incoherent.

### Put flag records in `TerminalNotificationStore`

Rejected correctly. It would conflate declared escalation with derived waiting, double-count demand, and make explicit lowering fight read semantics.

### Derive attention by querying metadata in views

Rejected correctly. It would introduce synchronous store work and observation into typing-sensitive rows and make the two renderers drift.

### Store a third `flag_raised_at` metadata key

Viable but not preferred. It makes the epoch obvious and portable, but expands the canonical public model and creates more clear/replace invariants. Preserving the `flag` source timestamp through an explicit attention-store transaction is a tighter fit.

### Permit generic metadata writes for attention keys

Viable only with a fully specified transactional adapter. Rejecting them in favor of the flag-domain mutations is simpler, gives accurate actor/event semantics, and closes the bypass perimeter more convincingly.

### Persist Bonsplit’s derived presentation

Not preferred. It helps generic decode/transfer, but risks making a render cache look authoritative. Recompute from c11 metadata after restore and carry it explicitly during live transfer instead.

## Readiness Verdict

**Needs revision.**

The plan becomes ready to execute when it:

1. records the operator’s suppressed-plus-flagged direct-notification decision and makes the spec, matrix, validation steps, acceptance checklist, and tests agree;
2. specifies the durable epoch-preservation write primitive for reason revisions;
3. defines raw versus signal notification APIs, a published signal invalidation mechanism, and an explicit consumer migration table;
4. chooses route-versus-reject semantics for generic attention metadata writes;
5. defines the typed dominance result and carries flag reason into both renderers’ accessibility models;
6. updates every existing priority-jump caller’s enablement and copy;
7. specifies direct-notification identifier, revision, launch, lower, and suppress behavior.

These are contract amendments, not a redesign. Once resolved, the remaining phases are well decomposed and appropriately gated.

## Questions for the Plan Author

1. On a suppressed surface, should a direct flag raise send a system notification: yes or no? Which document becomes authoritative after the decision?
2. Should `launch-agent --flag` send a system notification immediately, or should launch-time flagging only establish the sticky visual/watch state?
3. Does a launch-time mission flag remain raised through ordinary completion until explicitly lowered, even when no human blocker ever arose?
4. Is the metadata source timestamp definitively the public flag epoch, and may an attention-specific store write preserve it while changing the reason?
5. Should generic `surface.set_metadata` / `clear_metadata` / replace be forbidden from mutating `flag` and `suppressed`, or must they be first-class mutation routes?
6. If generic routes remain allowed, what `by` value do they emit, and how is a mixed ordinary-metadata-plus-attention replace made atomic?
7. Is `by: operator | agent` trusted authorization data or descriptive provenance? What prevents an agent socket client from claiming `operator`?
8. Should focusing a suppressed surface continue to mark its raw notification record read even though that record contributes no signal?
9. What exact published value invalidates UI when eligibility changes without `notifications` changing?
10. Which current consumers are intentionally raw-history consumers, and which must migrate to signal eligibility?
11. What type represents “flagged dominates waiting” while `WorkspacePulseState` remains four cases?
12. Must the full flag reason be announced on both the Bonsplit surface tab and the sidebar mark, or is “Flagged” sufficient on marks while the banner carries the reason?
13. What should the existing “Jump to Latest Unread” menu item be renamed to, and should it be enabled when flags exist but signal-eligible unread count is zero?
14. Is `flag.list` process-global across all windows/workspaces, scoped to the addressed window, or filterable?
15. Which machine-readable list responses gain attention fields: only `flag.list`, or `surface.list` as well?
16. What stable identifier should direct flag notifications use, and should a reason revision replace the prior OS notification?
17. Does lowering remove pending/delivered direct flag notifications, or do already-delivered notifications remain as historical OS artifacts?
18. After a flag is raised, what should a later suppress/unsuppress do to a pending direct flag notification under the chosen delivery policy?
19. Should the generic Bonsplit presentation be encoded in `TabItem`, or should it default to nil on decode and always be rehydrated from c11 metadata?
20. Must tagged runtime validation include a real quit/resume cycle for an active flag, revised reason, and suppressed unread record?
21. During cross-workspace/window detach and attach, must flag queue age remain unchanged and globally ordered throughout the transfer?
22. Does the 256-character reason cap count Swift grapheme clusters after trimming, and should every Unicode newline separator be rejected?
