# Standard Plan Review — c11-185-plan — Codex

## Executive Summary

This is the right feature architecture expressed as a good six-line outline, but it is not yet a sufficiently executable implementation plan. My verdict is **Needs revision**, not rethinking.

The strongest choice is the decision to create one c11-owned temporal projection and have the three tooltip locations plus Surface Details consume it. That preserves the C11-183/C11-184 state pipeline, keeps product semantics out of Bonsplit, and avoids turning derived UI text into metadata. Promoting logical `createdAt` onto `Panel` and through `SessionPanelSnapshot` is also the correct persistence boundary.

The single most important missing piece is the temporal delivery mechanism. Step 2 says to “precompute” localized activity help and attach native help, but the contract requires the displayed duration to refresh on hover entry and Surface Details to keep relative values current. A preformatted string carried through the current immutable Bonsplit presentation will become stale. The plan needs to say that the shared projection is a timestamp-bearing semantic payload, define where exact timestamps are acquired, and name the leaf-only refresh seam that renders the payload against an injected/current `now` without querying stores from hot view bodies.

Three related seams must be made explicit before implementation:

1. `TerminalNotificationStore` currently exposes exact-surface unread membership, but not that surface notification's `createdAt`; its indexes only retain latest unread by workspace (`Sources/TerminalNotificationStore.swift:680-688,923-957`). Waiting duration needs a bounded exact-surface timestamp accessor or index.
2. Bonsplit currently appends host `accessibilityValue` and its own lifecycle label (`vendor/bonsplit/.../TabItemView.swift:969-986`). Supplying a complete lifecycle-duration-modifier phrase through the current field would announce lifecycle twice.
3. `SurfaceManifestSnapshot.capture` currently captures only metadata, metadata sources, and capture time (`Sources/SurfaceManifestView.swift:39-47`). The plan needs a concrete structured capture dependency for panel `createdAt`, tracker last activity, attention, lifecycle, and exact waiting evidence, with Refresh rerunning that same capture.

Once those are resolved in the plan, a competent implementer should be able to execute the ticket safely.

## The Plan's Intent vs. Its Execution

The plan understands the real intent. This is not merely tooltip copy. It establishes a single temporal interpretation of the lifecycle already projected by c11 and makes Surface Details the expanded view of that same truth. Steps 2 and 3 correctly separate:

- lifecycle/help semantics from renderers;
- logical surface creation from terminal runtime creation;
- structured details from mutable metadata JSON;
- c11 product semantics from generic Bonsplit presentation.

The execution outline drifts in one place: it treats time-derived copy as if it were ordinary immutable presentation data. The lifecycle and modifiers can be precomputed; elapsed duration cannot be permanently preformatted. `SurfaceActivityTracker` deliberately stores a date and permits bounded synchronous snapshot reads, while forbidding use from hot paths (`Sources/Conversation/SurfaceActivity.swift:12-17,31-65`). The plan should preserve that model: acquire dates in an existing parent/sync or snapshot-capture path, then format them in a leaf at an explicit clock instant.

There is also an ambiguity in “state-start arithmetic.” The contract names four distinct sources:

- working/idle: the c11-observed lifecycle or input boundary;
- cold: `lastActivity + coldThreshold`;
- waiting: exact signal-eligible surface notification creation;
- suppression: no start time.

Those mappings should be in the plan, not left implicit under “map the shared lifecycle/attention projection.” They are the feature's correctness core, and they prevent a renderer from accidentally using metadata-source timestamps, total idle time for cold, or workspace-level latest notification time.

## Architectural Assessment

### What is structurally right

The proposed center of gravity is correct:

```text
existing lifecycle + attention + timestamp evidence
                       |
                       v
        pure c11 activity-help/details payload
              /              |              \
      Bonsplit mark   sidebar mark leaves   Surface Details
```

That is better than three localized-string builders because it gives tests one semantic object to exercise and makes tooltip/details agreement testable at the same injected `now`.

Making `createdAt` a `Panel` property is also better than:

- a terminal-only `TerminalSurface` debug timestamp;
- a parallel workspace dictionary keyed by panel ID;
- mutable metadata;
- capture time or app-launch time.

The panel is the logical surface object, and `SessionPanelSnapshot` is already the restoration envelope. Its existing optional `lastActivityAt` demonstrates the backward-compatible snapshot pattern (`Sources/SessionPersistence.swift:362-380`).

### What needs a more explicit decomposition

The current sequence puts all behavior tests after model, UI, persistence, and Bonsplit work. For a temporal feature, the pure semantics should be locked before renderer wiring. A stronger decomposition would be:

1. Baseline, ancestry, isolated-worktree, and submodule-state gate.
2. Define the timestamp-bearing payload, exact source mapping, formatter, and fixed-clock tests.
3. Add missing truth acquisition: exact-surface waiting timestamp and structured Surface Details capture inputs.
4. Add `createdAt` persistence through every constructor/create/restore path, with round-trip and legacy tests.
5. Wire sidebar leaves and Surface Details with leaf-only time refresh.
6. Extend Bonsplit generically for tooltip and accessibility presentation, then wire top tabs.
7. Translate, run scoped tests/builds, review, tagged validation, and delivery.

This is not a different architecture. It is the same architecture ordered so semantic errors fail before submodule/UI work.

### The temporal payload needs a contract

The plan should state that the payload contains semantic facts rather than a frozen tooltip:

- raw and/or presented lifecycle, with one clearly authoritative presentation field;
- optional state-start time;
- optional last-activity time;
- flag reason and optional flag raise time;
- suppression;
- pure `text(at:)` / details formatting against an injected clock instant.

Acquisition happens outside `ContentView.TabItemView` and the Bonsplit tab body. Rendering against `now` happens only in the small mark/help leaf or open Surface Details view. `SidebarDecayClock` already provides a shared 30-second leaf clock and explicitly forbids observation from `TabItemView` (`Sources/SidebarDecayClock.swift:4-25`), so the plan should say whether it is reused or whether a hover-local, nonrepeating refresh mechanism is used.

### The Bonsplit boundary is under-specified

`BonsplitTabActivityPresentation` is currently a generic, Codable value with renderer colors, motion, and one accessibility string (`vendor/bonsplit/.../BonsplitActivityAnimationClock.swift:14-41`). That is a good host-owned seam, but simply adding `helpText` does not satisfy hover-time refresh unless c11 updates it at hover or Bonsplit receives a generic dynamic-help mechanism.

The plan does not need to dictate the exact implementation, but it must choose one executable strategy and preserve these invariants:

- Bonsplit never learns `flagged`, `suppressed`, `cold threshold`, or c11 localization keys.
- The padded mark area, not the whole tab, owns the native tooltip.
- Tooltip refresh does not invalidate the whole tab row on a repeating tick.
- Existing selection, context menu, middle-click, close, layout, and mark-visibility behavior remain unchanged.
- A host-supplied complete activity accessibility phrase replaces, rather than precedes, Bonsplit's fallback lifecycle phrase; unrelated values such as Loading/Pinned/Unread remain composed once.

The current Bonsplit mark is nested inside the padded leading accessory (`TabItemView.swift:737-775`), while the tab as a whole owns accessibility (`:538-544`). This makes the hit target and accessibility behavior separate problems; the plan currently treats them as one.

### Surface Details needs an explicit capture seam

Step 3 rightly says the activity group is structured and separate from metadata JSON. It should also state how the capture obtains live panel truth. Today, Refresh simply reruns `SurfaceManifestSnapshot.capture(workspaceId:surfaceId:)` (`Sources/SurfaceManifestView.swift:422-424`), and that function cannot see panel creation time or the already-projected lifecycle.

The revised plan should make one capture function/provider collect:

- the same activity projection used by marks;
- `panel.createdAt`;
- `SurfaceActivityTracker.lastActivity`;
- capture time;
- existing metadata and sources.

Refresh must rerun that provider. Relative activity duration and last-activity age should render from the structured dates against the coarse leaf clock; absolute values should stay fixed until Refresh. The timestamp formatter must add a timezone—the current formatter does not (`SurfaceManifestView.swift:426-430`)—and the copy/selectable value must remain unambiguous.

## Is This the Move?

Yes. The plan is making the right major bets:

- reuse lifecycle inference rather than creating another state machine;
- make time evidence optional and fail honest when absent;
- preserve old snapshots as unknown rather than backfilling fabricated creation dates;
- keep derived display facts out of metadata;
- keep Bonsplit generic;
- use behavior tests and tagged visible validation;
- preserve submodule provenance and remote reachability.

The common failure mode here is not a bad high-level architecture. It is a nearly correct implementation whose tooltip looks right in the first minute but quietly drifts from Surface Details, announces duplicate state in VoiceOver, or uses a convenient workspace-level notification timestamp. The revised plan should be optimized against those failures.

I would not introduce a new generalized “temporal event history” subsystem, per-surface timers, or persisted lifecycle-transition log. The ticket only needs the latest trustworthy boundaries already available plus logical creation time. More infrastructure would enlarge the truth claims and conflict with the out-of-scope list.

## Key Strengths

1. **Single semantic projection.** This is the key architectural decision. It makes tooltip/details agreement a property of one pure model rather than a convention among renderers.

2. **No lifecycle reinference.** Step 1 explicitly protects the shipped C11-183/C11-184 pipeline. That avoids the most dangerous scope expansion.

3. **Correct persistence ownership.** A first-class optional `Panel.createdAt` carried through `SessionPanelSnapshot` cleanly distinguishes fresh nonnil creation from legacy unknown creation.

4. **Honest missing evidence.** The planned test coverage includes missing timestamps and legacy decode. This matches the contract's “Never fabricate 0 minutes” and `Not recorded` behavior.

5. **Structured details, not metadata pollution.** Step 3 prevents UI-derived facts from acquiring false persistence or metadata precedence semantics.

6. **Performance-aware projection.** Precomputing immutable evidence for `WorkspacePulseAgent` and the top-tab sync path is consistent with c11's typing-hot constraints.

7. **Renderer boundary discipline.** Bonsplit receives generic help/accessibility presentation while c11 retains localized lifecycle and attention semantics.

8. **Delivery discipline.** The submodule-first remote-main rule, translation pass, tagged QA launch, approval gate, visible evidence, draft PR, and `pr_open` end state are all appropriate.

## Weaknesses and Gaps

### Must revise before execution

1. **No executable hover-refresh mechanism.** A precomputed localized string is stale by construction. State explicitly how a timestamp-bearing payload becomes current help on hover without a per-agent timer or a hot-body store read.

2. **No exact per-surface waiting timestamp seam.** The notification index has only a membership set for `(workspace,surface)` and workspace-level latest notification. Add a bounded signal-eligible per-surface timestamp index/accessor and specify its semantics. Although `addNotification` replaces the prior record for the same surface (`TerminalNotificationStore.swift:960-965`), the plan should not rely on scanning the published notification array in a view.

3. **Accessibility composition can duplicate lifecycle.** The current Bonsplit path appends host accessibility then its own state. Define override/fallback semantics and test the final combined value in semantic order.

4. **Surface Details capture cannot currently obtain the promised truth.** Name the provider/call path that injects panel and activity facts into `SurfaceManifestSnapshot`; ensure Refresh uses it.

5. **Current-time ownership is absent.** Specify how Surface Details stays current and how sidebar/top-tab help refreshes, using the existing coarse shared clock or an equally bounded leaf mechanism.

6. **Source-to-state arithmetic is too implicit.** Spell out working, idle, cold, waiting, and suppressed-waiting timestamp selection in the pure projector. In particular, tests should establish whether presented idle for raw suppressed waiting uses the last-activity boundary rather than the unread-notification boundary.

### Should strengthen

7. **Fresh versus legacy constructor semantics.** “Optional `createdAt`” must not mean fresh surfaces may accidentally be nil. The plan should require fresh terminal/browser/markdown constructors to default to call-time `Date()`, while restore passes snapshot `createdAt` verbatim, including explicit nil.

8. **All creation paths need an audit, not only the three primary `new*Surface` methods.** Split creation, placeholders/repair, layout restore, CLI/socket creation, and direct panel construction should either route through the same initializer defaults or be listed as covered.

9. **Validation should include time movement.** Screenshots at one instant prove placement and copy shape, not that durations refresh. Include one before/after hover or details-age observation across a minute boundary, plus missing-evidence and legacy-restored visible cases where practical.

10. **Review/fix ordering is unclear.** Step 5 pushes the parent before Step 6 self-review. Add an explicit correction-and-reverification loop, with a final scoped status/ancestry check after the last fix and push.

11. **The worktree gate should be explicit.** An isolated C11-185 worktree exists, but the plan should verify execution is in it, record the base ancestry, provision submodules/framework if needed, and prove the dirty shared checkout remains untouched.

12. **Approval scope should be recorded.** “After separately requested approval” is directionally correct. The execution plan should record the tagged local app, hover/right-click flows, screenshot artifacts, and absence of external data/credential interaction so a fresh validator can rely on the approval.

## Alternatives Considered

### Independent strings in each renderer

Simpler initially, but wrong. It would produce three formatting implementations, make fixed-clock agreement difficult to prove, and invite modifier-order drift. The plan's shared projection is better.

### Persist derived timestamps or tooltip text in metadata

This would make display artifacts look canonical, introduce precedence/staleness problems, and conflate observed facts with presentation. The plan correctly rejects it.

### Keep creation time in a workspace dictionary

This avoids changing `Panel`, but creates a second lifecycle keyed by panel IDs and complicates every create/close/transfer/restore path. First-class `Panel.createdAt` plus snapshot persistence is cleaner.

### Use the terminal runtime debug timestamp

It cannot cover browser/markdown and would reset with terminal recreation. The plan correctly promotes logical creation at the panel layer.

### Add per-mark timers

This would make freshness easy and performance poor. Reusing a shared coarse clock only in visible leaves, plus a hover-entry refresh, is the better approach.

### Let Bonsplit format c11 activity semantics

That would make a generic layout package understand c11 lifecycle, attention, timestamps, and localization. The host should provide semantic presentation; Bonsplit should only own the native help hit target and accessibility composition contract.

## Readiness Verdict

**Needs revision.**

The plan becomes ready to execute when it adds:

1. a timestamp-bearing payload contract and exact timestamp-source table;
2. the exact-surface waiting timestamp accessor/index;
3. a leaf-only hover/coarse-clock refresh strategy for all three tooltip locations and Surface Details;
4. explicit Bonsplit tooltip and accessibility override/fallback behavior;
5. a structured Surface Details capture provider that Refresh reruns;
6. fixed-clock tests for those decisions, plus final worktree/submodule/review correction gates.

These are bounded amendments. The underlying architecture and scope should remain unchanged.

## Questions for the Plan Author

1. Is the “precomputed activity-help projection” intended to be a timestamp-bearing semantic payload with `text(at:)`, or a preformatted string? If the latter, how will hover-time freshness be satisfied?

2. What exact mechanism refreshes the top-tab native tooltip on hover entry without observing a timer in the Equatable tab body or teaching Bonsplit c11 semantics?

3. Will `TerminalNotificationStore.NotificationIndexes` gain a signal-eligible timestamp keyed by `(workspaceId, surfaceId)`, and is the intended waiting start the creation time of the one current replacement notification?

4. For a raw waiting surface that is suppressed and therefore presented as idle, should its displayed idle duration use `SurfaceActivityTracker.lastActivity` rather than the unread notification's creation time? The duration-source table should make this explicit.

5. Does the payload distinguish raw lifecycle from presented lifecycle, and which one is authoritative for state-start selection? This matters for suppressed waiting and flag-plus-suppression.

6. How will a complete host accessibility phrase replace Bonsplit's fallback lifecycle value while still composing once with Loading, Pinned, Unread, Modified, and Zoomed?

7. What structured provider will `SurfaceManifestSnapshot.capture` call to obtain the live panel's `createdAt` and the exact same activity payload used by its marks?

8. Will browser and markdown Surface Details normally show `Last activity: Not recorded` until c11 gains a trustworthy observation source for them, or are there existing browser/markdown boundaries the implementation intends to adopt? The plan should avoid silently broadening observation claims.

9. Which clock owns relative updates while Surface Details is open, and will it be the existing `SidebarDecayClock` observed only by the activity/timing leaf?

10. What exact display and clipboard format will provide timezone-bearing, unambiguous absolute Created/Last activity values?

11. How will fresh creation pass a nonnil call-time date while legacy restore preserves explicit nil through the same constructors?

12. Which creation paths beyond `newTerminalSurface`, `newBrowserSurface`, and `newMarkdownSurface` are included in the audit and behavioral coverage?

13. Will tagged QA include a duration-boundary refresh observation, not only static screenshots, and a visible legacy/missing-evidence case?

14. What is the correction loop after Step 6 self-review if the parent branch and Bonsplit main were already pushed in Step 5?

15. Has the scoped computer-use approval request been recorded with the tagged app, exact hover/right-click flows, screenshot destinations, and data limits for the fresh validator?
