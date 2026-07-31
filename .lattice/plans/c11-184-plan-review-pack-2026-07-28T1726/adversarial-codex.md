# C11-184 Adversarial Plan Review

PLAN_ID: `c11-184-plan`  
MODEL: `Codex`

Citation shorthand: `task_...md` refers to
`.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md`.

## Executive Summary

**Verdict: NOT READY FOR IMPLEMENTATION. Concern level: high.**

The plan is unusually detailed, but it is not yet executable because several of its load-bearing contracts contradict one another or depend on validation infrastructure that does not exist.

The single biggest architectural problem is the proposed collapse of all non-history notification behavior into one “signal-eligible unread” projection. A flagged surface with an unread notification must simultaneously:

- preserve the unread as raw history;
- expose true `waiting` so the flagged-waiting alarm can render;
- remain eligible for flag priority;
- avoid counting as both a Flagged Agent and a Waiting Agent.

The plan’s formula, `!(suppressed && !flagged)` (`task_...md:68-79`), cannot satisfy that set. It makes a flagged+waiting record signal-eligible, while `flaggedCount` independently counts the same surface (`task_...md:101`). The result is exactly the flag/waiting double-count the spec says must not happen (`docs/c11-flagged-agent-plan.md:82-84`) and the review gate claims to prevent (`task_...md:427-435`). If flagged notifications are instead removed from the signal index, a suppressed+flagged surface loses the exact unread truth needed to render flagged waiting. This requires at least three explicit projections—not one binary eligibility bit:

1. raw unread/history;
2. exact unread used to derive true surface lifecycle;
3. routine waiting demand used by the Waiting Agent row, menu-bar signal, waiting events, and fallback navigation.

That defect is accompanied by seven other implementation blockers:

1. The binding spec and exact staged skill say suppressed surfaces do not deliver system notifications, while the plan requires suppressed flag raises to deliver them.
2. The original flag epoch cannot survive a changed reason using the current metadata write API without an explicit storage/API change the plan has not selected.
3. PR CI does not gate the host-bound tests, does not run Bonsplit tests, and the required `test-e2e.yml` workflow is absent.
4. The plan changes workspace-local flag UI into app-global aggregation while claiming it does not.
5. The raw-versus-signal migration lacks a consumer-by-consumer API map, so auto-read behavior, notification history, menu state, and visual demand can easily be conflated.
6. `by: operator | agent` is not trustworthy as designed, and launch-time attribution is wrong for the documented orchestrator/subagent use case.
7. The current task reuses the already-shipped `C11-184` identifier from PR #360, corrupting traceability.

Do not start implementation until those are resolved in the plan and binding documents. The right next move is a short architecture revision, not coding.

## How Plans Like This Fail

### 1. A single “clean” projection erases distinctions consumers actually need

Attention systems fail when “is unread,” “should interrupt,” “should look waiting,” “should appear in navigation,” and “should remain in history” are treated as one Boolean. This plan recognizes raw versus signal truth but stops one layer too early. Flagged waiting proves that exact lifecycle truth and routine waiting demand are different projections.

The danger is slow leakage rather than one obvious crash. A suppressed notification disappears from the badge but still lights the menu-bar tooltip. A flagged waiting surface appears in two counters. A focus path stops marking suppressed history read because a method silently changed from raw to signal semantics. Every local implementation looks plausible; the product becomes inconsistent.

### 2. “One service owns everything” becomes a substitute for an operation protocol

`SurfaceAttentionService` is assigned metadata mutation, epoch ownership, cache refresh, notification-index refresh, event emission, direct delivery, restore, transfer, close, and prune (`task_...md:51-53`). That is not yet an architecture; it is a list of responsibilities.

Restore, live raise, reason revision, transfer, close, prune, generic replace, and launch stamping do not share the same side effects. Without an explicit operation-mode table, the service will either:

- redeliver notifications and re-emit events during restore;
- silently lower flags during close;
- reset epochs on transfer;
- invent `by` attribution for generic metadata replacement; or
- accumulate ad hoc Boolean parameters until the “single boundary” is harder to reason about than the original seams.

### 3. Validation prose outruns the repository’s actual gates

The plan repeatedly says CI is the sole test executor (`task_...md:328-345`) and assigns host and Bonsplit tests to PR CI (`task_...md:189-196`). In the current repository:

- `.github/workflows/ci.yml:203-232` marks host-bound `c11Tests` `continue-on-error: true`;
- the workflow does not invoke the Bonsplit test target;
- `.github/workflows/test-e2e.yml` does not exist on this branch; it was removed in `7cbc27d31`;
- `scripts/run-e2e.sh` still targets the upstream `manaflow-ai/cmux` repository, not this fork.

A plan that forbids every local test action and relies on absent or advisory remote gates can merge with all integration assertions failing. That is validation theatre, not risk mitigation.

### 4. Persistence is confused with in-memory observability

The plan requires a socket response only after the attention commit is observable (`task_...md:52`) and calls the modifiers persisted. The existing metadata store is in-memory (`Sources/SurfaceMetadataStore.swift:79-88`); the session snapshot runs on an eight-second autosave cadence (`Sources/SessionPersistence.swift:17`, `Sources/TabManager.swift:5551-5557`). A successful response therefore does not mean the flag is durable against a crash.

This is especially dangerous for a sticky escalation primitive. The operator will trust “raised” more than ordinary status metadata. If the app crashes within the autosave window and the flag vanishes, the feature breaks its central promise while every unit test of the in-memory service passes.

### 5. Sticky priority becomes starvation

The selector always chooses the oldest active flag, and opening it does not lower it (`task_...md:125-131`). Therefore repeated ⌥V presses return to the same surface forever. The operator cannot survey the second flag without dismissing the first—even if the first needs a decision they are not ready to make.

That is not a queue; it is a latch. A fleet UI needs either a per-invocation cycle cursor, an explicit “next flagged” behavior after arrival, or a deliberate decision that starvation is acceptable.

## Assumption Audit

| Assumption | Load-bearing? | Adversarial finding |
|---|---:|---|
| The binding inputs agree | Yes | False. The spec says no notification for suppressed surfaces (`docs/c11-flagged-agent-plan.md:34-42,257-263`); the plan requires direct delivery (`task_...md:475-483`). |
| The staged skill can be copied exactly | Yes | False. It says suppression excludes system notifications (`docs/c11-attention-model-skill-section.md:51-53`) and only promises a visual override (`:58-60`). |
| One signal-eligibility projection serves every consumer | Yes | False. Flagged waiting needs raw exact unread but must not duplicate routine waiting demand. |
| Metadata source timestamp can be the persistent flag epoch | Yes | Not with the current write path. A changed value replaces the source timestamp (`Sources/SurfaceMetadataStore.swift:699-741`). |
| The serialized service commit is durable | Yes | False under crash. Metadata persistence waits for autosave. |
| PR CI executes every required assertion | Yes | False. Host tests are advisory; Bonsplit tests are not invoked. |
| The E2E workflow can be triggered | Yes | False on this branch; `.github/workflows/test-e2e.yml` is absent. |
| The Flagged Agents row follows a harmless existing scope | Yes | False. The existing shared store is app-global, while the binding spec keeps c11 chrome workspace-local (`docs/c11-flagged-agent-plan.md:316-323`). |
| `by` identifies the real actor | Yes | Unsupported. Same-user socket clients can claim an origin unless a trusted internal route is defined. |
| Launch modifiers are operator-originated | No, but semantically important | False for the primary orchestrator/subagent use case, where an agent launches suppressed children. |
| An agent can react differently to operator dismissal | Yes, per the rationale | Unproven. An idle agent is not subscribed to `c11 events tail`; emitting `flag.lowered` does not deliver the dismissal into its PTY or conversation. |
| Suppression cancellation is reversible | No | Only partly. Delivered notification requests may be removable, but an already-run custom command cannot be undone. |
| “One timer” and a <=1 ms p95 delta can be verified | Yes | The plan defines a threshold but no measurement harness, timestamp source, sample count, warm-up, or noise-control protocol. |

## Blind Spots

### 1. There is no notification-consumer migration table

The current API name `hasUnreadNotification` is used for two incompatible classes of work:

- exact-surface waiting projection (`WorkspaceContentView.swift:92`, `ContentView.swift:8651`);
- marking a focused surface read (`TabManager.swift:3416-3425`, `3428-3439`).

Changing that method to signal semantics fixes suppression rendering but prevents focus from marking suppressed history read. Keeping it raw preserves read behavior but leaks suppression into waiting visuals.

The status menu is another split consumer. `NotificationMenuSnapshotBuilder` independently counts raw unread records (`AppDelegate.swift:13511-13529`), while the menu also exposes history, Mark All Read, inline records, a badge, a tooltip, and Jump to Unread (`AppDelegate.swift:13346-13468`). Some must remain raw; others must use routine signal demand. One `unreadCount` cannot serve both.

The plan needs a checked-in consumer matrix with explicit APIs such as:

- `hasRawUnread(...)`;
- `hasLifecycleUnread(...)`;
- `hasRoutineWaitingDemand(...)`;
- `rawUnreadCount`;
- `waitingSignalCount`;
- `recentHistory`.

Tests must cover every existing call site class, especially focus/read paths and status-menu mixed states.

### 2. Transition side effects are not defined

The plan says restore, launch, detach/transfer, close, and prune enter the service, but it never says what each operation emits or delivers. Required decisions include:

- restore hydrates without `flag.raised` and without external delivery;
- transfer preserves epoch and reason while changing workspace identity;
- close/prune removes the cache entry without pretending an operator/agent lowered it;
- generic replace/clear either rejects attention keys or maps them to a defined actor and event;
- launch stamping decides whether it emits `flag.raised` / `flag.suppressed`, and under which origin;
- restore of malformed or version-skewed metadata fails closed without deleting unrelated metadata.

“Route or reject” (`task_...md:53`) leaves a protocol decision to the implementer and is not acceptable in an executable plan.

### 3. Event payloads cannot represent reason revision

An active-to-active reason edit preserves the old queue epoch but emits another `flag.raised {reason}` (`task_...md:58`). The event carries no epoch ID, original `raisedAt`, revision marker, or `updated: true`. Overwatch and cron consumers cannot distinguish a new flag from a revision without racing a separate `flag.list` query.

If external routing is a goal (`docs/c11-flagged-agent-plan.md:287-298`), events need enough identity to be consumed idempotently. Use an epoch identifier plus `raisedAt`, or introduce `flag.updated`.

### 4. The `by` field does not solve the problem claimed for it

The spec says `by` lets an agent distinguish “seen and deferred” from “nobody looked” (`docs/c11-flagged-agent-plan.md:88-93`). But an agent that raised a flag and stopped is not automatically consuming the event stream. Banner dismissal does not type into the terminal or send a mailbox message. The agent still cannot react.

Either define an agent-facing acknowledgement path, explicitly require/watch an events subscription, or narrow the claim: `by` is audit provenance for external consumers, not a feedback channel to the blocked agent.

### 5. Multi-window behavior is absent

`TerminalNotificationStore.shared` is app-global (`Sources/TerminalNotificationStore.swift:631-646`), and every sidebar cluster reads its global unread count (`ContentView.swift:10695-10718`). If attention follows that pattern, every window will show the same flagged count and may jump into another window.

The plan alternates among “app/window-global,” “no cross-workspace aggregation,” and a workspace-local binding spec. There are no tests for:

- two windows with flags in only one;
- closing one window;
- a notification click whose target window is not current;
- identical surface/workspace restore IDs across window contexts;
- whether a row count is per selected workspace, per window, or app-wide.

### 6. Bonsplit accessibility localization is unowned

Phase 4 requires the surface tab to announce flag state/reason, but Phase 6 translates only `Resources/Localizable.xcstrings` (`task_...md:273-281`). Bonsplit currently owns its own seven `Localizable.strings` catalogs under `vendor/bonsplit/Sources/Bonsplit/Resources/<locale>.lproj/`, and its tab accessibility strings are resolved inside Bonsplit.

The plan must choose one:

- inject already-localized accessibility value/help through the generic presentation object; or
- add and translate generic Bonsplit resource keys in all seven package catalogs.

The owned-file list and translator scope currently cover neither.

### 7. External-delivery races and identifiers are unspecified

Reason revision promises “one updated direct notification” (`task_...md:58`). Updating rather than duplicating requires a stable per-flag-epoch notification identifier. Lowering should remove its pending/delivered request. A new epoch needs a new identifier. None of that is specified.

Suppression after a routine notification has already scheduled can remove a pending or delivered `UNNotificationRequest`, but it cannot undo `NotificationSoundSettings.runCustomCommand`, which runs after scheduling (`TerminalNotificationStore.swift:1026-1041`). The product promise must be temporal: suppression prevents future routine delivery and retracts removable requests; it cannot retract external effects already executed.

### 8. Sensitive flag reasons have no handling policy

Agent-authored reasons are persisted in session snapshots, emitted into the event log, displayed over terminal pixels, and placed in lock-screen-capable system notifications. A 256-character cap is not a privacy policy. The plan needs a statement about secrets/customer data, notification-preview expectations, and whether event/snapshot retention is acceptable.

### 9. The latency gate has no executable harness

“Capture p50/p95 keystroke-to-paint” and “subscriber count” (`task_...md:380-395`) require instrumentation that is not named in owned files or phases. Screenshots cannot prove timing or off-screen unsubscription. A manual observer cannot reliably measure a <=1 ms delta.

Specify the probe, clock, sampling window, trial count, warm-up, baseline order/randomization, output artifact, and subscriber-count debug seam before calling this a hard gate.

### 10. Ticket identity is already spent

Git history contains `46566ed14 Plan C11-184 surface tab agent states` and merged PR #360 at `dbdd75ec5` (“Show agent state on surface tabs”). The current Lattice task assigns the same short ID `C11-184` to a different feature.

Search, release notes, branches, worktrees, review artifacts, and future incident reports will be ambiguous. Rename this task to an unused ID or explicitly record a migration/alias before any commits use the duplicate identifier.

## Challenged Decisions

### One global attention service

**Counterargument:** a single transaction coordinator is useful, but making it own persistence, UI cache, notification indexes, event emission, delivery, and lifecycle cleanup creates a god object across a serial queue, the main actor, and `UNUserNotificationCenter`.

**Alternative:** define a pure `AttentionTransition` reducer that returns an explicit effect set. A narrow coordinator atomically commits metadata/epoch state, then applies typed effects to:

- projection cache;
- routine signal index;
- events;
- external delivery.

Restore/transfer/close use different reducer inputs and cannot accidentally inherit live-raise effects.

### Metadata source timestamp as queue age

**Counterargument:** source timestamps mean “when this value was written.” A reason revision is a real value write and should update that timestamp. Reinterpreting it as immutable epoch age makes metadata provenance lie.

**Alternative:** persist a private/canonical `flag_epoch` or `flag_raised_at` sidecar with explicit invariants, or extend the store with a transactional attention record. Do not overload `SourceRecord.ts`.

### Direct flag delivery piercing suppression

The operator resolved this, so implementation should follow the decision—but the decision is still not integrated into the contract. “Suppressed means no system notification” remains in the binding spec, task description, and staged skill. A behavior change this trust-sensitive cannot be left as a late PR amendment.

Amend all binding inputs first and state the rule plainly: suppression blocks routine completion delivery; a flag is an explicit escalation and may deliver externally.

### Oldest flag always wins

**Counterargument:** oldest-first is fair only if dequeue occurs. Here opening does not dequeue, so the oldest item monopolizes the shortcut.

**Alternative:** preserve sticky flags but cycle active flags after each successful open, resetting when the set changes or after a timeout. The row can still display the oldest as the initial destination.

### Exposing claimed operator origin on the socket

**Counterargument:** “trusted operator-originated action” is not a defined trust boundary. Agents and operator shells run as the same user and can reach the same local socket.

**Alternative:** banner/UI actions use an internal operator-only call path; CLI/socket actions are recorded as claimed actor or default to agent. If operator CLI provenance is required, define an actual capability rather than a string field.

### App-global flagged row

**Counterargument:** copying an existing global Waiting Agent behavior does not make cross-workspace aggregation local. It expands the feature beyond the binding spec and produces duplicate global rows across windows.

**Alternative:** either make the row selected-workspace-local as specified, or explicitly amend the product contract and add multi-window/global-index tests.

## Hindsight Preview

Six months after shipping, the likely “we should have known” failures are:

1. **Flags and waiting disagree across surfaces.** The sidebar row says two waiting, the menu badge says three, ⌥V skips one, and the notifications list shows four. Root cause: no consumer matrix and one overloaded eligibility bit.
2. **The oldest flag traps ⌥V.** Operators stop using the shortcut because it repeatedly opens the same deferred blocker.
3. **A crash loses the most important flag.** In-memory success was mistaken for persistence before the eight-second autosave.
4. **Reason edits page Overwatch twice.** `flag.raised` has no epoch/revision identity.
5. **Agents never react to dismissal.** The `by` field exists in the log but no blocked agent receives it.
6. **A host regression merges green.** The only executing host tests are advisory, and the package tests never ran.
7. **Translations diverge between sidebar and surface tab.** c11’s xcstrings are complete while Bonsplit falls back to English.
8. **History becomes impossible to discuss.** “C11-184 regression” refers to two unrelated shipped efforts.

Early warning signs the plan should instrument:

- the same surface contributing to both flagged and waiting aggregate counts;
- any attention cache entry without matching canonical metadata and epoch;
- event epochs seen more than once as “raised” without an explicit update marker;
- signal-count differences across sidebar, status item, Option-V, and workspace pulse;
- animation subscribers greater than visible eligible marks;
- an OK socket response followed by no persisted snapshot revision within a bounded interval.

## Reality Stress Test

### Disruption 1: rapid concurrent transitions

An agent raises a flag, revises the reason, completes and writes a notification, while an orchestrator suppresses the surface. The current plan has no total ordering for the metadata queue, main-actor notification store, and asynchronous notification center.

Likely result: the source timestamp resets, two `flag.raised` events escape, the routine waiting edge briefly fires, the Flagged and Waiting rows both count the surface, and a custom notification command runs before suppression can retract it.

Required mitigation: an explicit transition reducer, epoch identity, distinct lifecycle/routine projections, and concurrency tests that permute these operations.

### Disruption 2: app crash or restore/transfer churn

The app crashes after returning OK but before autosave, or restores a flagged surface and immediately transfers/detaches it.

Likely result: the flag disappears after crash, or restore emits a fresh escalation/direct notification, or the cache retains the old workspace identity.

Required mitigation: define durability semantics, hydration-without-effects, transfer identity rules, and artifact-level restart tests.

### Disruption 3: remote validation is unavailable or red

Local XCTest is prohibited. The PR’s host tests fail but are advisory. Bonsplit tests are never invoked. The named E2E workflow cannot be dispatched.

Likely result: pressure to merge based on compile, screenshots, and logic tests, precisely where portal focus, notification delivery, and package animation regressions are most likely.

Required mitigation: make focused host slices hard-fail in CI, add an actual Bonsplit CI job, and identify or restore a fork-owned E2E workflow before implementation.

## The Uncomfortable Truths

1. **The plan currently guarantees double accounting for the headline flagged-waiting combination unless it gives up either the alarm state or the “no double count” promise.**
2. **The strongest persistence promise is only eventually durable.**
3. **The `by` field does not let a blocked agent know anything unless another delivery mechanism exists.**
4. **The plan calls itself CI-only while naming test gates the repository does not enforce or possess.**
5. **“Follows the existing scope” is being used to conceal a real product-scope change from workspace-local to app-global aggregation.**
6. **The oldest-first selector is not a queue because nothing advances it.**
7. **The plan’s level of detail creates false confidence.** Many paragraphs specify colors, timing, and commit grouping while the fundamental state projections, actor provenance, persistence boundary, and executable test path remain unsettled.
8. **The ticket number collision is not clerical trivia.** It will poison every future search and handoff if allowed into commits and PR titles.

## Hard Questions for the Plan Author

1. When one surface is both flagged and truly waiting, should it increment both Flagged Agents and Waiting Agent? If not, which exact projection feeds each count?
2. What are the three explicit notification views—raw history, exact lifecycle unread, and routine waiting demand—and which existing call site consumes each?
3. Does focusing a suppressed surface mark its retained unread record read? Which API preserves that behavior without leaking a waiting signal?
4. Why does the binding spec still say suppressed surfaces never deliver system notifications when the resolved plan says a suppressed flag must deliver one?
5. Will the task description and staged skill be amended too, or only `docs/c11-flagged-agent-plan.md`?
6. Where is original flag epoch stored? How does a reason revision update the string without overwriting the existing `SourceRecord.ts`?
7. Is an OK response required to mean in-memory observable or crash-durable? What happens during the current eight-second autosave window?
8. What exact effects occur for live raise, reason revision, restore, launch stamp, transfer, close, prune, generic keyed clear, clear-all, and replace?
9. Are generic metadata routes rejecting attention keys or routing them? “Either” is not a protocol.
10. How does an agent that has stopped receive an operator dismissal and its `by` value? If it cannot, why does the spec claim the agent can distinguish the cases?
11. Who is the actor when an orchestrator agent runs `launch-agent --suppressed` for a child? Why does the plan label every launch-time modifier operator-originated?
12. What prevents a same-user socket client from claiming `by: operator`?
13. Is the Flagged Agents row selected-workspace-local, window-local, or app-global? Why does that differ from the binding spec’s workspace-local UI?
14. How should two windows render and navigate an app-global flag count?
15. How does repeated ⌥V reach the second active flag without lowering the first?
16. What stable notification identifier represents a flag epoch, and what happens to pending/delivered requests on revise and lower?
17. What does suppression promise after a custom notification command has already executed?
18. Does `flag.raised` represent a new epoch or a reason update? How can Overwatch consume it idempotently?
19. Where are the Bonsplit accessibility translations owned, and how are all seven package locales validated?
20. Which CI job hard-fails the new host-bound tests? Which CI job runs Bonsplit tests?
21. What fork-owned workflow replaces the absent `.github/workflows/test-e2e.yml`?
22. What exact instrument captures keystroke-to-paint p50/p95, and how is a <=1 ms delta distinguished from run-to-run noise?
23. Are flag reasons allowed to contain secrets or customer data given their persistence, event logging, banner display, and system-notification exposure?
24. Why is this feature reusing `C11-184`, already present in git history and PR #360? What is the migration plan to an unused identifier?

Until those questions have authoritative answers reflected in the plan, spec, staged skill, task record, and CI configuration, implementation should remain blocked.
