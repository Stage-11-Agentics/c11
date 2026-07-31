# C11-184 — Flagged and suppressed agents: executable implementation plan

## Goal and binding inputs

Ship two orthogonal, persisted modifiers over the existing four-state agent lifecycle:

- `flag`: a required one-line reason declaring that human action is needed.
- `suppressed`: an operator/agent choice that removes routine attention signalling while preserving notification history.

The implementation is governed by:

1. `docs/c11-flagged-agent-plan.md` (binding feature spec).
2. `docs/c11-attention-model-skill-section.md` (exact staged skill copy).
3. `docs/c11-mark-vocabulary.md` and shipped dependency C11-183 at `29102376f`.
4. The repository `AGENTS.md` threading, localization, testing, tagged-build, skill-sync, and submodule rules.

Base gate: implementation must start from `09782511b` (or a descendant containing `29102376f`). Do not rebuild or redesign the C11-183 lifecycle vocabulary.

## Decisions from the seam audit

The spec wins where the current base is only forward scaffolding:

- C11-183 already added `flagged` / `suppressed` fields and a `presentedState` projection to `WorkspacePulseAgent`, plus partial flagged drawing in the sidebar renderer. Those fields are not wired to metadata.
- The shipped sidebar mark currently animates flagged working with the normal stepped fill and leaves flagged idle/cold static. The binding spec instead requires **breathe for every flagged non-waiting state** and the core-only 0.4 s violet/white square wave for flagged waiting. Replace the scaffolding behavior.
- The shipped Bonsplit mark supports host-injected color/motion internally, but a tab carries only `activityState`; c11 cannot yet send a per-surface modifier, violet tint, alarm alternate color, or explicit flag motion to the surface-tab renderer. Extend the generic Bonsplit host-presentation seam rather than adding c11-specific `flagged` semantics to Bonsplit.
- `WorkspaceContentView` currently folds Static marks, Reduce Motion, app/workspace activity into one Bonsplit animation permission. That cannot express “Static marks disables base motion, but flag motion still runs; Reduce Motion disables both.” Split the generic host policy into base-motion and explicit/attention-motion eligibility.
- `TerminalNotificationStore` has only raw unread indexes, emits `waiting.entered` from raw per-tab counts, and decides external delivery without consulting attention metadata. It needs distinct raw-history and signal-eligible indexes.
- `SurfaceMetadataStore` has no typed attention snapshot or enumeration by flag age. Oldest-first `flag.list` and the flag phase of Option-V need a bounded typed index/query using the metadata source timestamp as the raise time.
- The spec’s “true state” wording means the raw derived lifecycle remains available internally, while every human-facing projection for an unflagged suppressed surface presents waiting as idle. A suppressed+flagged surface exposes the true lifecycle and the flag wins.
- The current Waiting Agent footer is app/window-global through the shared notification store. The Flagged Agents row follows that existing scope; this does not add the explicitly out-of-scope cross-workspace dashboard/aggregation surface.

## Architecture and data flow

### Canonical truth and typed projection

Add canonical metadata keys:

- `MetadataKey.flag = "flag"`: non-empty, trimmed, single-line string; cap at 256 characters.
- `MetadataKey.suppressed = "suppressed"`: strict JSON Boolean.

Both are written at `.explicit`, survive the existing session snapshot/autosave path, and remain visible through `get-metadata`. `flag` absence means lowered. `suppressed == true` means suppressed; absent/false means ordinary.

Build one typed attention seam (new `Sources/AttentionModel.swift`, or an equivalently isolated file if review finds a better existing home):

- `SurfaceAttentionSnapshot`: workspace id, surface id, optional flag reason, flag raise timestamp, suppressed Boolean.
- Pure presentation reducer:
  - raw `waiting` + suppressed + not flagged -> presented `idle`;
  - otherwise raw lifecycle is unchanged;
  - flag color/motion overrides suppression;
  - suppression never deletes raw notification history.
- A main-actor observable index/coordinator that mirrors the canonical store for active surfaces, provides `flaggedCount`, oldest-first active flags, signal eligibility, and per-surface snapshots.
- One serialized `SurfaceAttentionService` (name may vary, responsibility may not) owns the complete commit boundary: canonical metadata write/clear, original active-epoch timestamp, typed projection/index refresh, signal-index refresh, event emission, and optional direct system delivery. A mutating socket response is sent only after that whole commit is observable. Do not make `TabItemView` or a keystroke path query the metadata store.
- The generic `surface.set_metadata` / `surface.clear_metadata` routes may not bypass that boundary. Route writes, keyed clears, replace/clear-all operations touching `flag` or `suppressed` through the service (or reject those keys there with a precise protocol error and require the flag family). Snapshot restore, launch stamping, detach/transfer, close, and prune also enter through explicit service hooks. Add adversarial coverage for every bypass.
- Metadata remains authoritative; the observable index is a bounded render/query cache, not a second persistence system.

Mutation semantics:

1. `raise(reason)` validates before mutation, writes the canonical reason, records/reuses the original active-epoch timestamp, publishes the active flag, emits `flag.raised {reason}`, refreshes render/signal projections, then delivers the separate direct flag system notification even when the surface is suppressed. This one direct-delivery branch is the operator's Phase 3 decision; routine waiting-derived delivery remains suppressed independently. An active-to-active reason revision preserves that original timestamp, emits one new `flag.raised` event and one updated direct notification, but never creates a second queue entry. Only an explicit lower followed by a new raise starts a new epoch and moves the flag to the back.
2. `lower(by)` clears `flag`, publishes the transition, emits `flag.lowered {by}`, and never marks notification history read.
3. `suppress(by)` writes `true`, refreshes signal eligibility immediately (including an already-unread notification), emits `flag.suppressed {by}`, and cancels/removes any pending routine external notification for that surface without deleting its in-app record.
4. `unsuppress(by)` clears or writes false consistently, refreshes signal eligibility immediately, and emits `flag.unsuppressed {by}`. An existing unread record becomes signal-eligible again and may create the correct 0->1 waiting edge; it does not manufacture a second record.
5. Repeating an identical mutation is idempotent: no duplicate event, system notification, queue-age reset, or revision churn. Relaunch/restore preserves the active epoch for both identical and revised reasons.

The `by` vocabulary is exactly `operator | agent`. Banner dismissal is always `operator`; agent CLI lower/suppress/unsuppress defaults to `agent`, with an explicit socket field for trusted operator-originated actions. Launch-time modifiers are operator-originated.

### Attention signalling versus notification history

Refactor `TerminalNotificationStore.NotificationIndexes` to retain both views:

- Raw unread/history indexes: every unread record, including suppressed surfaces.
- Signal-eligible unread indexes: surface-less notifications plus surface notifications for which `!(suppressed && !flagged)`.

Use signal-eligible indexes for:

- Waiting Agent badge/count and lit state.
- Workspace waiting demand and exact-surface waiting projection.
- `waiting.entered` / `waiting.left` 0<->1 edges.
- Option-V waiting fallback.
- menu-bar/unread affordances that would otherwise leak a suppressed completion as a signal.

Keep raw indexes for the notifications list/history and explicit reads. The list must still show the suppressed notification record and permit marking/removing it.

At `addNotification`:

- Always create/update the in-app record.
- Always settle liveness to idle as today.
- Do not deliver the normal system notification when the target surface is suppressed, regardless of flag state; the feature spec explicitly says suppressed surfaces deliver no system notification.
- A raised flag’s system notification is a separate direct delivery path and never inserts a `TerminalNotification`.

When attention metadata changes while notifications already exist, rebuild only signal eligibility and emit the real edge transition. Avoid rewriting `notifications` merely to force `didSet`.

### Lifecycle and rendering

Extend `SurfaceTabActivityResolver` (or introduce a sibling pure reducer) to consume the typed attention snapshot:

- Agent, no exact unread: `working` / `idle` / `cold` as today.
- Exact unread, ordinary: `waiting`.
- Exact unread, suppressed and unflagged: `idle`.
- Exact unread, suppressed and flagged: `waiting`.

Populate `WorkspacePulseAgent.flagged` and `.suppressed` from the precomputed attention snapshot in the parent sidebar census. Add `WorkspacePulseSummary.flaggedCount`; dominant attention precedence is flagged > waiting > working > idle > cold without adding a `WorkspacePulseState` case. Counts and row ordering use `presentedState`.

For the two mark renderers:

- Lifecycle stays encoded by the C11-183 shape.
- Flag applies flat violet (`#9D8AD9` starting value, dialled in the tagged build).
- Suppression has no tint, dim, badge, or label.
- Unflagged suppressed working is a static full grid.
- Flagged waiting: steady violet frame; 4 pt core alternates violet/white on a hard 0.4 s square wave; no base dip or breathe.
- Flagged working/idle/cold: whole-mark slow opacity breathe; no stepped fill/dip concurrently.
- Reduce Motion renders every combination statically.
- Static marks disables only base stepped fill/dip. It does not disable flag breathe/flash.
- All motion is leaf-isolated, opacity/color only, uses the one shared clock and stable surface-id phase offset, and unsubscribes off-screen, in collapsed/unselected workspaces, or while the app is inactive.

Keep Bonsplit generic:

- Add a public, optional per-tab activity-presentation value (color override, explicit motion channel, alternate core color), or equivalent generic host-injection fields.
- Add a generic `breathe` motion sampler/channel.
- Separate generic base-motion permission from explicit-motion permission so c11 can apply Static marks and Reduce Motion correctly.
- Carry the optional presentation through `Tab`, `TabItem`, controller create/update, transfer, and decode-with-default paths.
- Do not name flag/suppression in Bonsplit public types. This extension is a reasonable upstream candidate because it is generic host-controlled mark presentation; flag it in the PR rather than opening an upstream PR during this task.

### Flag navigation

Extract a pure attention-jump selector:

1. Active flags ordered by original raise timestamp ascending (oldest first), stable tie-break by workspace/surface UUID.
2. Skip stale/unopenable surfaces and try the next flag.
3. If no flag opens, choose the latest signal-eligible unread notification (existing newest-first stack behavior).

`jumpToLatestUnread()` may be renamed internally to reflect the broader semantics, but all existing call sites and the Option-V binding stay one action. The Flagged Agents row invokes this exact selector. Opening a flagged surface passes no notification id and does not lower the flag. The banner X/agent command is the only lower path.

### In-surface banner and system notification

Mount a distinct `NSHostingView<SurfaceFlagBanner>` from `GhosttySurfaceScrollView`, following the existing `SurfaceSearchOverlay` ownership and z-order pattern:

- top edge, below the surface title bar, floating over terminal pixels;
- no layout participation and therefore no PTY resize;
- flag glyph, single-line/truncated reason, localized accessibility label/help, localized dismiss control;
- X calls `lower(by: .operator)` and restores terminal focus without synthesizing terminal input;
- update/remove the host only on attention transitions; do not touch `TerminalSurface.forceRefresh()` or `WindowTerminalHostView.hitTest()`.

Define z-order explicitly against find, pane-interaction, keyboard-copy, notification-ring, and flash overlays so both the banner and find field remain operable.

Use the existing notification authorization/sound/custom-command machinery for direct flag delivery:

- title = current surface title/fallback;
- body = flag reason;
- `userInfo` contains workspace/surface ids so click focuses the surface;
- no `TerminalNotificationStore` record and no waiting count;
- one explicit direct-delivery branch where flag raise pierces suppression; routine
  notification-store delivery remains suppressed independently;
- repeated identical raise is not redelivered.

## Owned files and seams

Expected primary files:

- `Sources/AttentionModel.swift` (new typed reducer/index/coordinator; add target membership deliberately).
- `Sources/SurfaceMetadataStore.swift` (canonical keys, strict validation, timestamped typed snapshot support).
- `Sources/Sidebar/SidebarActivityProjector.swift` (flagged count and precedence; retain four lifecycle cases).
- `Sources/SurfaceLivenessDeriver.swift` (suppression-aware surface-tab projection).
- `Sources/TerminalNotificationStore.swift` (raw versus signal indexes, edge/delivery filtering, direct flag notification seam).
- `Sources/Workspace.swift` (attention mirror, lifecycle/presentation sync, launch-time atomic stamp, restore/close handling).
- `Sources/ContentView.swift` (precomputed modifiers, flagged row, correct sidebar mark motion/accessibility).
- `Sources/WorkspaceContentView.swift` (base versus explicit motion environment policy).
- `Sources/GhosttyTerminalView.swift` (portal-hosted flag banner only; no hot-path changes).
- `Sources/AppDelegate.swift` (priority jump selector use and flag-notification response focus).
- `Sources/Events/EventEnvelope.swift` and `Sources/Events/EventEmitter.swift` (four event types/helpers).
- `Sources/SocketHandlers/SocketDispatch.swift`, a focused attention handler file if added, and `Sources/SocketHandlers/SystemHandlers.swift` (flag domain routing and method listing).
- `Sources/SocketHandlers/SurfaceHandlers.swift` (generic metadata bypass prevention and attention commit-before-response ordering).
- `CLI/c11.swift` (commands, launch flags, help, global usage).
- `Sources/DefaultAgentResolver.swift` only if the launch request needs to carry validated attention intent; do not contaminate command composition if handler-owned fields suffice.
- `Resources/Localizable.xcstrings`.
- `skills/c11/SKILL.md` (exact staged section).
- `GhosttyTabs.xcodeproj/project.pbxproj` only for real target membership. If the Ruby xcodeproj tool is used, review semantic membership/build evidence rather than hand-fighting normalization.

Bonsplit submodule files likely required:

- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitActivityAnimationClock.swift`.
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitEnvironment.swift`.
- `vendor/bonsplit/Sources/Bonsplit/Public/Types/Tab.swift`.
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift`.
- `vendor/bonsplit/Sources/Bonsplit/Internal/Models/TabItem.swift`.
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift` and any alternate/compact tab-bar mark call sites.

Because Bonsplit is a submodule: check out local `main`, fast-forward it to `origin/main`, then commit and push to remote `main` before committing the parent pointer. Verify the submodule is not detached and `git merge-base --is-ancestor HEAD origin/main`. Keep the change generic and offer it upstream in the handoff.

Expected behavior tests and target ownership:

| Coverage | File(s) | Target/executor |
|---|---|---|
| Pure reducer/index/jump, summary precedence, liveness projection, metadata validation/restore, event envelopes, notification index builder | `c11Tests/AttentionModelTests.swift`, `SidebarActivityProjectorTests.swift`, `SurfaceLivenessDeriverTests.swift`, `SurfaceMetadataStoreValidationTests.swift`, `EventLogTests.swift`, `NotificationAndMenuBarTests.swift` | `c11LogicTests`, executed only by PR CI |
| AppKit/portal ownership, notification delivery, live socket mutation response ordering | focused files under `c11Tests/` | host-bound `c11Tests`, executed only by PR CI |
| Tagged runtime CLI/socket behavior | focused `tests_v2` cases | tagged debug socket during validation and PR CI as applicable |
| Generic mark presentation/animation | Bonsplit’s existing test files | Bonsplit test target, executed only by PR CI |

Validate target membership for `AttentionModel.swift` and every new/changed test file with `xcodebuild -list`, `build-for-testing`, and project membership inspection; do not run a local test action.

Do not add source-text, plist-text, AST, or grep tests.

## Implementation phases

### Phase 0 — ancestry and baseline

1. Confirm worktree HEAD descends from `09782511b` and contains `29102376f`.
2. Provision submodules and the `GhosttyKit.xcframework` symlink if the implementation worktree is fresh.
3. Record clean scoped status and the passing baseline Debug compile. Do not run any local test action; assertion baselines and all XCTest evidence come from PR CI.
4. Before touching Bonsplit, enter the submodule, check out local `main`, fetch `origin`, and fast-forward local `main` to `origin/main`. Confirm `git symbolic-ref --short HEAD` is `main`. Commit and push only that branch; before the parent pointer commit, verify the submodule HEAD is on `main`, equals or is an ancestor of `origin/main`, and is reachable from the pushed remote.

### Phase 1 — canonical model and pure logic

1. Add/validate canonical keys and typed snapshots.
2. Implement the pure attention presentation reducer and oldest-first selector.
3. Add flagged summary precedence/count without changing lifecycle enum cases.
4. Add all four event taxonomy cases and emission helpers.
5. Land adversarial logic tests before wiring UI.

Gate: canonical state round-trips through snapshot restore; invalid/blank/multiline/oversize reasons and non-Boolean suppression fail before mutation.

### Phase 2 — primitives and launch

1. Add socket routing/methods `flag.raise`, `flag.lower`, `flag.list`, `flag.suppress`, `flag.unsuppress`.
2. Add CLI commands:
   - `c11 raise-flag --surface <s> "<reason>"`
   - `c11 lower-flag --surface <s>`
   - `c11 suppress --surface <s>`
   - `c11 unsuppress --surface <s>`
3. Require an explicit non-empty surface ref for mutations; preserve the C11-165 no-focused-fallback write policy.
4. Add `launch-agent --flag "<reason>"` and `--suppressed`; permit both simultaneously.
5. Validate launch modifiers before creating a surface and stamp them before typing the agent launch line, so a fast completion cannot escape suppression.
6. Return attention fields in machine-readable launch/list results without changing plain ref summaries.

Socket execution contract: parse, validate, resolve, and dedupe on the socket worker; never use `DispatchQueue.main.sync`. Hop with `DispatchQueue.main.async` only for the minimum model/UI projection mutation, then complete the request after the serialized attention commit finishes. The handlers must not activate c11, raise windows, select workspaces, or mutate in-app focus. Add behavior tests for off-main parse/validation, commit-before-response ordering, and focus preservation.

Gate: idempotency, attribution, error codes, persistence, cross-workspace explicit targeting, no focus steal for mutation commands, and correct launch ordering are behavior-tested.

### Phase 3 — notification signal layer and navigation

1. Split raw and signal-eligible indexes.
2. Rebase waiting edges, counts, exact-surface demand, and external delivery on signal eligibility.
3. Refresh eligibility when flag/suppression changes without mutating notification history.
4. Add direct flag system notification delivery.
5. Wire oldest-flag-first then latest-waiting navigation.

Gate: the headline matrix works in logic/integration tests:

| Flag | Suppressed | Unread/stop result | Waiting signal | External notification |
|---|---:|---|---|---|
| no | no | waiting | yes | existing behavior |
| no | yes | idle, record retained | no | no |
| yes | no | true lifecycle, violet | flag priority | flag raise direct delivery |
| yes | yes | true lifecycle, violet | flag priority | flag raise direct delivery |

### Phase 4 — both renderers and sidebar row

1. Complete the generic Bonsplit presentation seam and breathe sampler.
2. Feed computed state/modifiers into surface tabs and workspace-card marks.
3. Split base/explicit motion policy and audit off-screen/background unsubscribe.
4. Add `Flagged Agents` above `Waiting Agent`, on demand only, violet fill/void text/hairline/no motion, count badge, same jump action.
5. Update accessibility values so flag reason/flag state are announced without claiming suppression visually.

Gate: no `@EnvironmentObject`, `@ObservedObject`, or store read enters Bonsplit `TabItemView`/the equatable c11 sidebar row body; all modifier data is immutable/precomputed.

### Phase 5 — portal banner

1. Add the AppKit-owned banner host and attention-transition updates.
2. Implement operator dismissal and focus restoration.
3. Exercise coexistence/z-order with find, pane interaction, copy badge, notification ring, flash, split churn, and surface close.

Gate: raising/lowering never changes PTY rows/columns or terminal geometry, and no stale overlay survives close/detach/restore.

### Phase 6 — localization and skill contract

1. Stabilize English `String(localized:defaultValue:)` keys first.
2. Launch a fresh translator stage in a new c11 surface to fill Japanese, Ukrainian, Korean, Simplified Chinese, Traditional Chinese, and Russian in `Resources/Localizable.xcstrings`.
3. Validate placeholders/plurals and inspect changed locale entries; do not hand-author translations in product code.
4. Copy the staged section from `docs/c11-attention-model-skill-section.md` into `skills/c11/SKILL.md` exactly, adjusting only if a shipped command contract necessarily changed and updating the staged source at the same time.
5. After the skill-source commit, run `scripts/sync-installed-skills.sh c11`, then diff/verify the live installed copy while preserving `.c11-skill.json`.

Gate: no new bare user-facing strings; source and installed skill describe commands that actually exist.

## Behavior-level test checklist

- Metadata:
  - valid reason/Boolean accepted at explicit tier;
  - blank, whitespace-only, multiline, non-string, over-cap reason rejected atomically;
  - non-Boolean suppression rejected;
  - restore preserves reason, suppression, source, and original raise timestamp;
  - repeated identical raise preserves queue age/revision.
- Modifier reducer:
  - every lifecycle × flag × suppression combination;
  - suppression maps only unflagged waiting to idle;
  - flag overrides suppression;
  - lifecycle enum remains four cases.
- Events:
  - exact type/payload for raised/lowered/suppressed/unsuppressed;
  - `by` limited to operator/agent;
  - idempotent calls produce no duplicate event.
- Notifications:
  - suppressed unread remains in raw list and can be read/removed;
  - it contributes zero signal count and no waiting edge/external delivery;
  - suppressing an already-unread surface emits the correct waiting-left edge;
  - unsuppressing an unread surface emits the correct waiting-entered edge;
  - flag overrides suppression for lifecycle/signal projection and the separate direct flag
    system-delivery path; routine waiting-derived delivery remains suppressed;
  - flag raise direct delivery does not add a notification-store record or waiting count.
- Navigation:
  - oldest flag wins over newer flag and every unread;
  - stale/unopenable flag is skipped;
  - no flag falls back to latest signal-eligible unread;
  - suppressed unread is skipped;
  - opening a flag neither lowers it nor marks unrelated history read.
- Launch/socket/CLI:
  - missing reason -> `invalid_params`;
  - missing/empty surface ref rejected;
  - `--flag` + `--suppressed` accepted together and stamped before command delivery;
  - `flag.list` is deterministic oldest-first and contains refs/reason/timestamp/suppression;
  - mutators do not focus/raise the app.
- Rendering policy:
  - flagged working/idle/cold select breathe;
  - flagged waiting selects binary flash only;
  - Static marks disables base motion only;
  - Reduce Motion disables all;
  - suppressed unflagged working is static;
  - hidden/background marks unsubscribe from the single clock.

## Compile and CI gates

The operator explicitly forbids every local `xcodebuild test` action for this ticket,
including the normally safe `c11-logic` scheme. Do not run `scripts/test-unit-local.sh`
either. Author behavior-level logic coverage, compile it locally, and let PR CI execute the
assertions.

1. Build the app with `xcodebuild ... build` in Debug and Release.
2. Compile both test targets with `build-for-testing` only, using an isolated tagged
   DerivedData path for this worktree. Treat this strictly as a link/membership check, never
   as proof that an assertion passed.
3. Run relevant Python socket tests only against the tagged build socket, never production
   state and never an untagged DEV app.
4. Run `git diff --check`; validate `xcodebuild -list`, target file membership, and Release
   compilation (especially any DEBUG-only `dlog`).
5. Push and require the repository PR checks, including their real test actions. CI is the
   sole test executor for this ticket.
6. Trigger the GitHub E2E workflow; do not run UI/E2E tests locally.

## Tagged runtime, visual, and latency validation

**Operator decision 2026-07-28:** this entire tagged runtime/computer-use section is
deferred for C11-184. Computer-use approval is not granted: do not launch a tagged build,
drive the UI, capture visual screenshots, or run the 20-agent latency protocol. The ten
visual scenarios below therefore remain unvalidated, the <=1 ms p95 fleet-latency gate is
unmeasured, and flag-tier motion ships unmeasured. CI green is the sole remaining validation
gate for PR #387. The original protocol remains below as the durable record of what was
deferred rather than being removed from the contract.

Before computer-use automation in any follow-up, obtain explicit operator
approval and record it in a Lattice comment: approved tool/surface, the local tagged c11 app,
the exact flag/suppression/Option-V/banner/mark flows and interactions, and the
data/credential boundary (no credentials, external domains, production state, or
consequential external actions). Use only one tagged launch and suppress startup dialogs;
because `reload.sh` both builds and launches, do not launch the same tag a second time:

```bash
C11_QA_LAUNCH=fresh ./scripts/reload.sh --tag c11-184-attention
```

Record the tagged bundle path, PID, and exact debug socket before exercising it. All
Debug/build-for-testing compilation uses the isolated DerivedData path assigned to this
tag/worktree.

Capture screenshots and a short validation record for:

1. Ordinary working/waiting/idle/cold marks in both renderers.
2. A flag raised mid-working: both marks snap violet; reason banner appears without geometry change.
3. Flagged waiting: steady violet frame and core-only violet/white flash.
4. Flagged idle/cold breathe.
5. Static marks on: base motion stops, flag motion continues.
6. Reduce Motion on: all motion stops while violet/shape/row/banner signals remain.
7. Suppressed completion: idle mark, no Flagged/Waiting count, no Option-V destination, no system notification, record visible in notifications list.
8. Suppressed+flagged: violet true lifecycle and flag priority/banner; direct flag raise system
   notification delivers while routine waiting-derived delivery stays barred.
9. Two flags with controlled timestamps: Option-V and row click visit oldest first; opening does not clear; X clears and next press advances.
10. Find overlay/banner coexistence, split churn, close/detach, background workspace, collapsed pane, and scrolled-out tab behavior.

Before declaring the visual run successful, inspect `c11 tree --no-layout`; rebalance unreadable panes and retain screenshots of the final legible layout.

Fleet-scale latency protocol:

1. Use the same tagged build/machine, fixed window geometry, terminal workload, and at least 20 active agent surfaces so 40+ marks exist across surface tabs and sidebar cards.
2. Capture p50/p95 keystroke-to-paint timing for:
   - static marks baseline;
   - full default base motion;
   - dip-only candidate;
   - flag motion with several representative flags;
   - background/unselected workspaces (subscriber count must drop).
3. Hard pass criterion: feature-on p95 delta versus the static baseline is **<= 1 ms**, with no subjective typing degradation and no unexpected body churn in `TabItemView`.
4. Inspect the shared-clock subscriber count: one timer only; visible eligible leaf count, not total fleet count; no subscriptions for background/off-screen/collapsed marks.
5. If the gate fails, apply the pre-registered ladder and rerun:
   - disable stepped fill by default, retain dip if it passes;
   - if dip fails, ship base marks static;
   - independently, if flag motion fails, ship flags static violet.
6. Record raw numbers, configuration, screenshots, and the chosen rung in the validation artifact and PR.

## Acceptance checklist

- [ ] C11-183 ancestry present; lifecycle vocabulary/9 pt geometry unchanged.
- [ ] Flag and suppression are separate canonical explicit metadata fields and survive relaunch.
- [ ] Required reason is validated as one non-empty line.
- [ ] Flags are sticky and clear only by explicit operator/agent lower.
- [ ] Suppressed unflagged surfaces never present waiting.
- [ ] Suppressed notification history survives while every routine signal channel is filtered.
- [ ] Flag overrides suppression for lifecycle, violet treatment, banner, queue priority, and flag motion.
- [ ] Suppressed+flagged direct delivery pierces suppression at one isolated flag-delivery
      branch; routine suppressed notification-store delivery remains barred.
- [ ] `flag.list` and Option-V use oldest-first flags; waiting remains latest-first.
- [ ] No second shortcut is added.
- [ ] Flagged Agents row is above Waiting Agent and has zero footprint at count zero.
- [ ] Portal banner does not resize/garble the PTY.
- [ ] Flag raise does not write `TerminalNotificationStore`.
- [ ] All four attention events carry the specified payload.
- [ ] `launch-agent --flag` / `--suppressed` work independently and together, before process command delivery.
- [ ] Both mark renderers agree for every modifier/lifecycle combination.
- [ ] Static marks and Reduce Motion precedence match the spec.
- [ ] PR CI test actions are green at the final head SHA; CI is the sole remaining gate by
      operator decision.
- [ ] **DEFERRED by operator decision:** the ten tagged-build visual scenarios have no
      runtime screenshots or computer-use evidence because approval was not granted.
- [ ] **DEFERRED by operator decision:** the 20-agent <=1 ms p95 fleet-latency protocol was
      not run; flag-tier motion ships unmeasured and the fallback ladder was not exercised.
- [ ] Six locale translations are complete and validated.
- [ ] Staged skill text lands, installed c11 skill is synced and verified.
- [ ] Bonsplit submodule commit is pushed/reachable before parent pointer commit.
- [ ] Fresh independent code review has no unresolved correctness, threading, focus, accessibility, persistence, localization, or performance findings.

## Review and PR gates

1. Commit in coherent units: model/tests; primitives/launch; signal/navigation; renderer/submodule; banner/UI; localization/skill.
2. After architecture is accepted, use a bounded review budget: one fresh correctness/threading review, one focused fix pass, one terminal re-review.
3. Reviewer must inspect:
   - no raw/signal count leakage;
   - no main-thread sync on telemetry paths;
   - no focus steal from socket mutations;
   - no store reads/observation added to typing-hot views;
   - restore/close/detach cleanup;
   - event idempotency and attribution;
   - notification versus flag double-count prevention;
   - submodule reachability and generic API naming;
   - exact skill/runtime command agreement.
4. Attach review and running-system validation evidence before `pr_open`.
5. Open a draft PR only after local scoped checks and submodule push. Do not merge, tag, release, notarize, publish, or update production as part of C11-184.

## Risks and mitigations

- **Raw/signal index drift:** one pure index builder with explicit eligibility input; transition tests for suppress/unsuppress over existing unread records.
- **Metadata cache divergence:** metadata is canonical; cache hydrates from it on restore and is pruned with surfaces; revisions/tests cover idempotency.
- **Race at launch:** validate and stamp modifiers before typing the launch line.
- **Flag duplicated as waiting:** direct flag notification bypasses `TerminalNotificationStore`; tests assert zero record/count.
- **Spec precedence implemented differently in two renderers:** one shared pure presentation value/sampler, matrix tests, screenshot pairs.
- **Static/Reduce Motion conflation:** separate base and explicit motion gates; Reduce Motion is the final hard override.
- **Broad SwiftUI invalidation/typing lag:** immutable precomputation, leaf subscriptions only, one timer, 20-agent numeric gate and fallback ladder.
- **Banner focus/z-order regressions:** AppKit portal owner, explicit z-order matrix, focus-restoration and split-churn runtime tests.
- **Flag queue age reset:** preserve source timestamp on identical raise; deterministic tie-break.
- **Notification click ambiguity:** flag notification carries workspace/surface refs but no store id; response focuses without read/lower side effects.
- **Bonsplit fork divergence:** generic host presentation only, push reachable main before pointer, offer upstream.
- **pbxproj normalization noise:** prefer existing project tooling and verify semantic membership/build settings.
- **Localization/skill drift:** translator stage after English freeze; source-to-installed skill sync is a release gate.

## Plan-review cycle 1 resolutions (authoritative)

- Removed every local test-action instruction; CI alone executes XCTest assertions.
- Replaced write-then-publish with one serialized attention commit service and explicitly
  closed generic metadata set/clear/replace, restore, launch, transfer, close, and prune
  bypasses.
- Defined active-to-active reason revision: preserve the original queue epoch, emit/update
  once, and reset age only after explicit lower plus a new raise.
- Replaced the double tagged launch with one `C11_QA_LAUNCH=fresh reload.sh` launch and exact
  bundle/PID/socket evidence.
- Added the detached-submodule prevention gate: Bonsplit local `main`, fast-forwarded and
  pushed/reachable before the parent pointer.
- Made socket worker/main-actor responsibilities and response ordering executable, and assigned
  every behavior test to `c11LogicTests`, host `c11Tests`, tagged socket validation, or Bonsplit
  CI.
- Restored the explicit computer-use approval gate: the precise local tagged-app flow,
  interactions, and no-credentials/external-actions boundary must be approved and recorded in
  Lattice before automation starts.

## Operator Phase 3 decision — resolved

A direct flag raise on a suppressed surface **does** send a system notification. The flag
tier overrides suppression completely, including out-of-app direct delivery. The phrase
“suppressed surfaces deliver no system notification” is narrowed to routine waiting-derived
notification delivery only; the separate `flag.raise` delivery path is exempt. The code keeps
this at one direct-delivery branch. No waiting eligibility, notification history, lifecycle,
projector, queue, banner, or routine notification-store rule depends on it. The binding spec
must be amended in this PR so its tables and System notification section agree with the code.

## Operator validation decision — resolved

For PR #387, CI green replaces the tagged-build visual and fleet-latency gates. Computer-use
approval is explicitly withheld. Do not launch a tagged build, drive the UI, run the ten visual
scenarios, or execute the 20-agent latency protocol. This defers, rather than passes, both
acceptance items: no visual screenshots exist, the <=1 ms p95 threshold is unmeasured, and
flag-tier motion ships without measured fleet-scale latency evidence. Do not merge as part of
this delegator run; report when final-head CI is green and stop.

## Explicit non-goals

- No new lifecycle enum cases.
- No flag priority levels, rate limits, soft caps, or enforcement.
- No age-based visual escalation or `SidebarDecayClock` changes.
- No auto-lower on terminal input, focus, read, or notification open.
- No dedicated flag sound.
- No second keyboard shortcut.
- No workspace-level suppression.
- No predictive attention signal.
- No new cross-workspace flag dashboard; events are the Overwatch integration.
- No operator UI for saved launch-config flag/suppression defaults unless separately specified.
- No tenant config/dotfile writes.
- No changes to Ghostty or other submodules beyond the generic Bonsplit presentation seam.
- No release, merge, tag, notarization, publication, or production actuation.

## Reset 2026-07-28 by agent:codex-c11-184-delegator

## Reset 2026-07-28 by agent:codex-c11-184-delegator

## Reset 2026-07-29 by agent:codex-c11-184-delegator
