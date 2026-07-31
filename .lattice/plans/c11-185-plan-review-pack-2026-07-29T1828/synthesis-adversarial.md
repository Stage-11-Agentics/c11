# Adversarial Review Synthesis: C11-185 Plan

**Plan under review:** `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md`
**Ticket:** C11-185 "Agent-state tooltips and persistent Surface Details activity timestamps"
**Reviewers synthesized:** Claude, Codex, Gemini (three independent adversarial passes, 2026-07-29T1828)
**Synthesis mode:** read-only. No files were modified other than this one.

---

## Executive Summary

1. **All three models independently reach the same verdict: revise the plan before implementation starts.** Codex states it as a formal recommendation ("revise before implementation"), Claude rates concern "high," Gemini calls one issue a "fatal flaw." There is no dissenting reviewer and no reviewer who thinks the plan is ready as written.

2. **The unanimous #1 risk is temporal staleness.** All three models, arriving from different angles, identify the same irreconcilable pair: Step 2 precomputes a localized relative-duration string in an edge-driven parent path, while the locked contract demands the tooltip be fresh on hover entry with no repeating timers. Precomputed relative time cannot be both. Gemini calls this the plan's fatal flaw; Codex calls it the largest issue; Claude proves it mechanically (`.help(_:)` takes a `String` evaluated at body time and cannot recompute on hover).

3. **The unanimous #2 risk is timestamp provenance.** The plan never defines where "when this state began" comes from. Claude goes furthest and asserts the ticket itself points at the wrong source: `SurfaceActivityTracker` is a **last-touch clock**, not a state-start clock, bumped by terminal input and by non-transition lifecycle reports. If that is correct, the load-bearing input for every duration in this feature does not exist in the codebase and no step in the plan creates it. Codex independently demands a full state-start provenance matrix; Gemini flags the cold and waiting cases specifically.

4. **The unanimous #3 risk is that the plan is a restatement, not a design.** Claude: "The ticket is the plan," ~200 words adding zero decisions. Codex: "not yet an executable bridge." Gemini: "a superficial checklist that parrots the acceptance criteria." Consequence all three name: the hard calls get made silently at the keyboard, and the review gate has no baseline to review against.

5. **The unanimous #4 risk is that the most likely failure mode is invisible to every automated gate in the plan.** A tooltip that never renders, or renders stale, compiles clean, passes all eight enumerated Step 4 test cases, and shows green CI. All three models say screenshots or a five-second QA pass will not catch it; Claude adds that the only detector (Step 6 visual evidence) is gated on an approval that was withheld on the immediately preceding ticket.

6. **Highest-leverage single amendment, agreed across models:** the shared projection must emit **structured semantic evidence** (presented lifecycle token, trustworthy state-start `Date`, last-activity `Date`, modifier flags) and **not** a finished localized sentence. Formatting resolves at a bounded leaf on hover. This one change dissolves the staleness class, the Bonsplit-persists-localized-copy class, and the per-minute model-churn class simultaneously.

7. **One real disagreement to arbitrate:** the mechanism for lazy resolution. Gemini proposes Bonsplit accept a closure `() -> String`; Claude notes `BonsplitTabActivityPresentation` is `Codable, Equatable, Hashable` and round-trips through persisted layout, so a closure breaks it; Codex proposes a generic `Codable`/`Sendable` semantic payload with wording owned by c11. Codex/Claude converge; Gemini's specific proposal is likely unimplementable as stated.

8. **Second real disagreement:** local test policy. Codex Amendment 8 tells the delegator to use `scripts/test-unit-local.sh` for host tests. Claude states this repo's operator has forbidden **all** local `xcodebuild test` for delegator runs including the "safe" `c11-logic` scheme, citing project memory and the C11-181 interruption incident, and calls Step 4's local-test line "the one line in the plan that is not merely thin but actively wrong." Claude's position is backed by specific precedent and should win unless the operator says otherwise.

---

## 1. Consensus Risks (flagged by 2 or 3 models). Highest Priority

### 1.1 Stale relative time versus fresh-on-hover with no timers: **3/3, unanimous, top priority**

1. Precomputing "Idle for 7 minutes" in a state-sync path means the string ages in place. State syncs are edge-driven; time is continuous.
2. Claude's mechanical proof: `.help(_:)` accepts a `String` evaluated during body evaluation. It has no hover-entry hook.
3. Codex's system proof: `Workspace.syncSurfaceTabActivityStateForPanel` deliberately skips a Bonsplit update when state/presentation are unchanged, and the 10-second detector sweep does not force unchanged-presentation updates. The sidebar has the same edge-driven problem. Surface Details has no clock at all.
4. Gemini's user-visible proof: background the window for three hours, foreground, hover. A string generated three hours ago is simply wrong, and in the worst case reads as the banned `0 minutes` copy.
5. Escape routes each violate a different locked constraint: a hover-tracked `@State` re-render risks invalidating typing-hot bodies; a repeating timer is banned; a static string is stale. **The plan picks none of them.**
6. Codex's added nuance: three consumers need three different refresh owners (top tab on hover entry, sidebar marks on per-mark hover entry, Surface Details advancing while visible via one bounded leaf subscription). The plan treats them as one problem.

### 1.2 State-start timestamp provenance is undefined, and possibly sourced wrong: **3/3**

1. Claude's specific claim: the ticket's named source, `SurfaceActivityTracker`, records **last touch** with a 250 ms leading-edge debounce, bumped by terminal input (`GhosttyTerminalView.swift:3862`), conversation claim (`ConversationHandlers.swift`), and every call to `onShellActivityChanged` / `onAgentLifecycleChanged` (`SurfaceLivenessDeriver.swift:117`, `:160`) whether or not state changed.
2. The concrete regression that follows: type one character into a pane idle for seven minutes, and the tooltip resets to "Idle for 0 minutes," producing exactly the copy the contract bans.
3. Claude proposes the real source exists elsewhere and is unnamed by the plan: `SurfaceMetadataStore.sources["activity"].ts`, protected by the no-op-write guard at `SurfaceMetadataStore.swift:900-903`, persisted via `SessionPanelSnapshot.metadataSources`.
4. Codex arrives at the same hole abstractly: the plan needs a **state-start provenance matrix** covering working, idle, cold, waiting, and suppressed-waiting, plus a tie-break rule for tracker-time versus metadata-source-time, plus fail-closed behavior for missing, future, negative, or contradictory timestamps.
5. Gemini flags two of the same cells (cold, waiting) as invisible assumptions.
6. Aggravating factor Claude raises: Step 1's constraint "without changing lifecycle inference" reads as a prohibition on recording a state-start at transition edges, i.e. it forecloses the fix the ticket needs. Recording an observation is not changing inference; the phrasing should be corrected either way.

### 1.3 Cold duration must be threshold-crossing, not last-touch and not boolean-publish-time: **3/3**

1. Correct arithmetic: cold start = `trustedLastTouch + thresholdSeconds`.
2. Claude's blocker: `SurfaceLivenessDeriver.publishCold` takes `observedLastTouchedAt` purely as a local staleness guard and **discards it**, publishing only `setAgentCold(Bool)`. The render site therefore has no access to the cold-start input, and no step in the plan adds a published value.
3. Codex: the start must not be "the moment the cold Boolean happens to publish."
4. Gemini: does the projection precalculate the transition time, or does the leaf node need to know the threshold?
5. Failure mode if unresolved: "Cold for" silently equals total idle duration.
6. One piece of good news Claude verified: `SidebarAgentColdSettings` clamps the threshold to 60…3600 s, so a zero threshold cannot collapse "Cold for" into total idle time.

### 1.4 Waiting-start timestamp has no accessor, and the multi-unread case is undefined: **3/3**

1. `TerminalNotification.createdAt` exists, but the store exposes only `hasUnreadNotification(forTabId:surfaceId:)`. There is no per-surface `createdAt` accessor. A new API is required and the plan does not add one.
2. Codex: it must be the **exact signal-eligible** unread record, a precomputed timestamp query or index, with renderer-side notification scans explicitly forbidden by the guardrails. A missing-record fallback must be defined.
3. Claude: with two unreads on one surface, oldest (correct: when waiting began) or newest (wrong, resets on every notification, and is the easier code)? Unspecified.
4. Codex adds the suppressed case: when raw waiting is suppressed and presented as idle, the duration must come from the idle lifecycle/input boundary, not the unread record's waiting time.
5. Gemini: is this timestamp even present in the `WorkspacePulseAgent` payload today, or does it need new and potentially expensive wiring?

### 1.5 A localized string does not belong in `BonsplitTabActivityPresentation`: **3/3 on the problem, 2/3 converging on the fix**

1. Claude's structural objection: that struct is `Codable, Equatable, Hashable`, carried on the internal `TabItem` which decodes it (`TabItem.swift:117`), so it round-trips through Bonsplit's **persisted layout**. Baking a sentence in means (a) every agent tab's presentation value changes once a minute forever, producing a tab-bar model diff on a cadence, and (b) human-language localized copy is serialized into persisted layout and can be restored stale or in the previous UI language.
2. It also crosses the ticket's own generic/product line: a localized product sentence is not "generic help data," so the stated boundary is honored in letter only.
3. Codex: the public seam needs an explicit distinction between tooltip/help payload, complete accessibility override versus additive accessibility detail, and whether Bonsplit appends its own default lifecycle.
4. Gemini: if the field accepts a precomputed `String`, Bonsplit's tooltips will be "hopelessly stale."
5. **Convergent fix (Claude + Codex):** pass structured, stable, `Codable`/`Sendable` data (a state token, an optional state-start `Date`, modifier booleans), and let the host format. The value then changes only on real transitions: no cadence churn, nothing localized persisted.
6. **Divergent fix (Gemini):** have Bonsplit accept `() -> String`. This is likely unimplementable, since a closure breaks `Codable`/`Equatable` on a struct that must persist. Note it and discard it in favor of item 5.

### 1.6 Duration-format contract is entirely unspecified, and the reachable answers are wrong: **3/3**

1. Which formatter? Claude: `RelativeDateTimeFormatter` is already in the target file and yields "7 min ago," producing the nonsense "Working 2 minutes ago." A hand-rolled `%lld minutes` key drags in xcstrings plural variations. `DateComponentsFormatter` is the right tool: locale-correct "7 minutes" including Slavic plural rules, composed into `String(localized: "…for %@")`.
2. Codex enumerates what tests cannot be written without: units and rollover boundaries, floor versus nearest rounding, behavior below one minute, behavior exactly at a boundary, behavior at the instant cold begins, future dates and clock correction, whether state-only fallback applies to a real duration that rounds to zero, and how plural-safe text composes without forcing English word order.
3. Claude's sub-minute gap: what does a three-second-old state display? This is the **commonest case for `working`**, the state operators look at most, and it is undefined.
4. Localization consensus: ru and uk require one/few/many/other plural categories, a structurally different xcstrings shape. Claude notes `jq .` well-formedness **cannot** detect a missing plural category, so Step 5's "validate catalogs/tokens" is not a sufficient gate. Gemini calls the single-agent translation delegation "hand-waving away" plural complexity. Claude adds that CLAUDE.md prescribes one sub-agent per locale for larger batches, and duration copy across six locales with plurals qualifies.
5. Both Claude and Codex note the plan targets only c11's xcstrings and never names Bonsplit's seven `.lproj` catalogs (`Bundle.module.localizedString`), which are a separate output.

### 1.7 The plan is a restatement of the ticket, not a design: **3/3**

1. Claude: six sentences, ~200 words; the sibling ticket C11-184 needed ~500 lines for comparable surface area. Every hard call is deferred to the keyboard, and the first time anyone sees the design is Step 6's self-review, after it is all built.
2. Codex: "not safe to treat 'a competent agent will infer the rest from the ticket' as sufficient here, because the missing decisions sit exactly where plausible implementations diverge."
3. Gemini: "parrots the acceptance criteria without resolving the fundamental architectural contradictions."
4. Structural consequence both Claude and Codex name: the plan → implement → review chain loses its middle link. The reviewer can only review the code, not whether the code matches an intended design.
5. Claude's framing to force a decision: if the ticket is authoritative, say so and delete the plan. If the plan is authoritative, it must contain the decisions. What exists is the worst of both.

### 1.8 Surface Details (Step 3) is under-designed and its refresh path is broken: **3/3, though only Claude finds the specific defect**

1. Claude's concrete finding: `SurfaceManifestView.refresh()` reassigns only `snapshot = SurfaceManifestSnapshot.capture(...)`. `handle: SurfaceHandleInfo` is a `let` supplied at window construction and never re-read. Step 3's "capture structured Activity/Created/Last activity data separately from metadata JSON" points directly at `SurfaceHandleInfo`, the one field Refresh cannot touch. The contract line "Refresh rereads absolute activity truth" then fails silently.
2. Claude's counter-proposal: put the activity/timing group inside `SurfaceManifestSnapshot` (which `refresh()` does re-capture) as a sibling to `metadata`/`sources`, satisfying "separate from metadata JSON" while remaining refreshable.
3. Codex's list of what Step 3 does not say: how `capture` receives panel `createdAt` and the shared projection; whether capture is done by `Workspace`, a testable provider, or a global lookup; what Activity shows for browser/markdown/non-agent surfaces; what happens if the surface closes while the utility window is open; how Refresh rereads panel, tracker, notification, and attention truth atomically enough to agree; how values tick after Refresh; how timezone is included; whether the displayed local timestamp or an ISO-8601 value is copied; where copy affordances live; how `Captured` stays unchanged in meaning and visually distinct.
4. Timezone consensus. Claude: `SurfaceManifestView.timestampFormatter` is a `DateFormatter` with fixed `dateFormat = "yyyy-MM-dd HH:mm:ss"`, **no timezone and no explicit locale**. A fixed `dateFormat` without `locale = en_US_POSIX` renders non-Gregorian calendars and non-Latin digits under some user locales, the opposite of "an unambiguous copy value." Adding TZ to the shared formatter also changes the existing `Captured` row, brushing the "do not redesign the panel" constraint. Three coupled decisions, zero mentioned.
5. Codex: timezone abbreviations are not globally unambiguous; display and clipboard formats may need to differ. Gemini: what happens to absolute timestamps if the user changes timezone or locale mid-session?

### 1.9 `createdAt` promotion can silently fabricate history: **3/3, from three different directions**

1. Codex's sharpest instance: a defaulted `Date()` parameter in a restore constructor turns a missing legacy `created_at` into a new creation time at app launch. The dangerous defect happens **after** decode, so the plan's snapshot round-trip test cannot catch it. The real regression test: a legacy snapshot with no `created_at` enters the real restore constructor and the resulting panel still has `createdAt == nil`.
2. Claude's blind spot B2: detach, transfer, and drag-out are never mentioned. `Workspace.swift:9548-9605` has explicit detach handling that adds and removes `derivedActivityBySurface` entries. If any of those paths re-mints the panel, `Created` silently becomes "now." Criterion 6 tests only snapshot round-trip and restore, so a broken detach path ships green. Claude ranks this the highest-probability correctness bug after the state-start.
3. Codex's path inventory demand: fresh create, session restore, legacy restore, panel transfer/detach, terminal replacement, placeholder repair, closed-browser reopen, and any layout-executor path. Then state which operations preserve logical creation and which deliberately create a new logical surface.
4. Gemini's extensibility angle: why only terminal, browser, and markdown? A future panel type would silently lack a creation timestamp. The architectural change feels incomplete.
5. Genuine good news (Claude verified): `SessionPanelSnapshot.lastActivityAt` already exists from C11-164 and `AppDelegate.swift:3324` seeds the tracker at restore, so criterion 7 (last activity survives restart) is nearly free. The plan never notices this. `SessionPanelSnapshot.metadataSources: [String: PersistedMetadataSource]` also already round-trips, preserving the precedence chain across restarts.

### 1.10 The likely failure is silent, and the plan's only detector is a gate that was withheld last time: **3/3 on the substance**

1. Claude's evidence: Bonsplit documents this exact bug **twice in its own source** (`SafeTooltip.swift` and `TabBarView.swift:1911-1917`): a tooltip attached to an occluded or non-hit-testable view "silently never appeared," because macOS does not query occluded views for tooltips.
2. The activity mark is a decorative leaf. The sidebar summary mark sits inside a `Button` label (`ContentView.swift:12062`), where tooltip registration is unreliable; the census mark sits inside a `GeometryReader` with `.accessibilityElement(children: .ignore)`.
3. If `.help()` lands wrong: everything compiles, all eight Step 4 tests pass, CI is green, and the feature does not exist.
4. Codex: "Screenshots prove presence, not behavior." One captured tooltip does not prove duration rollover, cold-threshold arithmetic, hover refresh, overflow behavior, or that click/context-menu/close interactions remain intact.
5. Gemini: "The feature easily meets the acceptance criteria during a 5-second QA test but fails entirely in real-world, long-lived development sessions."
6. Claude's added structural point: the three highest-risk items are all in Step 6, i.e. at the end, behind an approval, after the submodule is pushed and the translations are done. Risk should be front-loaded.
7. **Convergent counter-proposal (Claude, endorsed by the shape of Codex's critique):** a day-one smoke on a tagged build with one hardcoded `.help("PROBE")` on each of the three targets. Confirm all three appear, then build the projection. Five minutes, no product copy needed, and arguably a much narrower computer-use approval scope.

### 1.11 Performance guardrails point at the wrong view, and hover tracking is itself a hazard: **3/3**

1. Claude's finding: the ticket forbids formatting inside `ContentView.TabItemView` body, but `TabItemView` is already `.equatable()`-skipped during typing. The path that is **not** skipped is the inline `pulseRoster` closure at `Sources/ContentView.swift:8626-8688`, which already walks every panel calling `tab.attentionSnapshot(...)` and `notificationStore.hasUnreadNotification(...)` per workspace on every sidebar invalidation. That is exactly where Step 2's "precompute for `WorkspacePulseAgent`" lands. `DateFormatter`/`DateComponentsFormatter` are expensive and not thread-safe; N agents × M workspaces × every invalidation is a real regression vector that the stated guardrail literally permits.
2. Gemini's inverse concern: if formatting is correctly deferred to hover, what happens when the user aggressively scrubs the mouse across 50 tabs? And how do you prevent `.onHover` tracking from invalidating `TabItemView` bodies, which is exactly the typing-hot re-render the guardrail exists to prevent?
3. Codex: resolve fresh help on hover entry "without store reads/date formatting in the typing-hot tab body," and bound the Surface Details clock to one visible leaf subscription with no per-agent timer.
4. Claude's cumulative-risk argument: C11-183 and C11-184 both touched `TabItemView` and the sidebar mark renderers. C11-184 defined a 20-agent ≤1 ms p95 gate and recorded in bold that it "was not run; flag-tier motion ships unmeasured." C11-185 adds per-agent string composition on top and defines **no latency gate at all**. Three tickets, cumulative unmeasured risk on the one code path this repo protects most aggressively.

### 1.12 Bonsplit submodule discipline gets half a sentence: **2/3 (Claude, Codex)**

1. The plan says: "Commit and push any Bonsplit change to `Stage-11-Agentics/bonsplit` main before the parent pointer."
2. Claude: C11-184 needed five explicit sub-steps: check out local `main`, fetch, fast-forward, confirm `git symbolic-ref --short HEAD` is `main`, verify `git merge-base --is-ancestor HEAD origin/main`, then the pointer. The failure this guards against (orphaned commit on a detached HEAD) is silent and unrecoverable in place. It is this repo's most-repeated failure per CLAUDE.md.
3. Codex's timing correction: "Pushing near the end is fine; **preparing** Bonsplit near the end is not." Branch checkout and fast-forward must happen **before** the first edit, with a final fetch/ancestry check before the parent pointer commit.
4. Codex's race scenario: Bonsplit `origin/main` advances while implementation is underway, and the pointer lands on a commit no longer reachable from remote `main`.
5. Claude's ordering bug in Step 5: "push Bonsplit, then delegate translation" breaks if the translation pass reveals a needed Bonsplit `.lproj` string, because the submodule is already pushed and pointed at.

### 1.13 Operational preflight and gating are implicit where the repo has concrete hazards: **2/3 (Claude, Codex)**

1. Worktree provisioning. Claude: a fresh `git worktree add` cannot build until you run `git submodule update --init --recursive ghostty vendor/bonsplit` and symlink `GhosttyKit.xcframework` from the main checkout. Without it, Step 1's baseline build fails three times in a row for reasons that are not code. Documented CLAUDE.md pitfall; the plan walks straight into it. Codex independently lists "provision submodules/framework as required."
2. Base/ancestry. Codex: at review time `feat/c11-185-agent-activity-details` is **one commit behind `main`**. It contains C11-183 and C11-184, but the plan has no base check or fast-forward step.
3. Review independence. Codex: Step 6's self-review is not an independent review; the Lattice workflow expects a fresh reviewer before validation. Claude makes the same point from a different direction (the plan gives the reviewer no baseline).
4. PR/CI ordering. Codex: open the draft PR early enough for PR CI to inform validation, or explicitly justify relying on local evidence first.
5. Computer-use approval scope. Codex: record the approved tagged app, hover/right-click flows, screenshots, and data limits before UI interaction. Claude: the immediately preceding ticket (C11-184) had this approval **withheld**, shipping ten visual scenarios unvalidated, and C11-185 has no fallback text and no defined terminal state on a second denial.
6. Test-target assignment. Claude: which tests go to `c11LogicTests` versus host `c11Tests` versus Bonsplit's own target is a decision with real consequences here (the `c11-logic` local-crash caveat, the C11-105 socket-unlink incident caused by a test in the wrong target). C11-184's plan has a table. C11-185 has "Run focused safe logic/host tests."

---

## 2. Unique Concerns (one model only). Worth Investigating

### Claude only

1. **`publishCold` discards the cold-start input.** `SurfaceLivenessDeriver.publishCold` takes `observedLastTouchedAt` purely as a local staleness guard and publishes only `setAgentCold(Bool)`. A new published value is required and no step adds it. This is a distinct, verifiable missing deliverable rather than a general "cold is undefined" concern.
2. **A tooltip already exists on the tab, and a second one changes which appears.** `TabBarView.swift:1916` already attaches `.help(tooltip)` to tab chrome, and `TabActivityAccessibility.help(for:)` (`TabItemView.swift:148-151`) already returns a localized help string for `waiting`. Adding a nested tooltip changes which one wins. Criterion 4 forbids behavior change; one of the two behaviors changes regardless. The existing `TabActivityAccessibility.help` also becomes either dead code or a second source of truth for the same sentence.
3. **Overflow-hidden census marks and the `+N` chip get no tooltip.** `workspacePulseMarkRow` compresses under width pressure. Criterion 1 says "every individual agent mark." Hidden agents get nothing and the `+N` chip gets nothing.
4. **Wasted precompute.** `workspacePulseVisibleAgents` is `prefix(2)`. Precomputing help strings for every agent in the census is mostly discarded work performed in the hot parent closure.
5. **Step 4 instructs a local test run the operator has already interrupted.** Project memory records: defer **all** local c11 `xcodebuild` (build/test, any scheme including the "safe" `c11-logic`) to CI during delegator/headless runs, per the C11-181 incident. C11-184's plan states it as a hard rule and also forbids `scripts/test-unit-local.sh`. Claude calls this the one line in the plan that is actively wrong, not merely thin.
6. **No rollback, no kill switch, no settings gate.** C11-184 shipped with a pre-registered fallback ladder. If the tooltips prove noisy, slow, or wrong post-merge, the only lever is a revert that also removes the Surface Details group operators will already be relying on.
7. **`Created` will read `Not recorded` for every currently-open surface on ship day.** Correct per contract, and it will read as broken, for weeks in long-lived workspaces. No mitigation is discussed, not even a parenthetical "(not recorded before 0.62)" instead of a bare `Not recorded`.
8. **Waiting duration will vanish across restart while its neighbours persist.** `TerminalNotificationStore` is in-memory, so after restart a waiting surface shows Created (persisted), Last activity (persisted), and no waiting duration. Internally consistent, externally reads as a bug, unmentioned.
9. **Adding a member to `public @MainActor protocol Panel`** is safe in-app, but `BrowserPanel.swift` is 10,278 lines and already carries an unrelated `createdAt` on `BrowserProfileDefinition:323`. Naming collision risk worth a glance.
10. **No commit-unit plan and no file-ownership table.** C11-184's plan has both.
11. **The early-warning-signal table.** Claude enumerates eight detectable signals (tooltip appears at all on day one; "Idle for 7 minutes" → "0 minutes" after one keystroke; `Cold for` exceeding last-activity age minus threshold; `Created` changing after detach; tab-bar body-evaluation count per minute at 20 agents; sidebar parent-closure time at 30 agents; missing plural category in ru/uk; Bonsplit HEAD detached before the pointer commit) and observes that the plan has a mechanism for **zero** of them. "Not that the plan will do the wrong thing, but that it will not notice."

### Codex only

12. **Accessibility composition is a contract change, not a passive optional string.** Today the seam is **additive**: host `accessibilityValue` is composed **before** Bonsplit's default lifecycle value, then Bonsplit appends its own lifecycle. Supplying the new full string therefore produces duplicated or misordered VoiceOver output. The locked order is lifecycle, then flagged reason, then suppression. The API needs an explicit "complete override versus additive detail" distinction and a decision on whether Bonsplit appends its default lifecycle and waiting hint at all. Claude touches the existing-help-string issue but not the composition-order defect.
13. **Renderer-side notification scans must be explicitly forbidden**, with a precomputed exact-surface unread timestamp API or index provided instead.
14. **Fail-closed policy for missing, future, negative, and contradictory timestamps**, ensuring no negative duration and no fabricated zero.
15. **What Activity displays for browser, markdown, shell, and non-agent surfaces with no trustworthy lifecycle evidence.** Entirely unaddressed by the plan and by the other two reviewers.
16. **What happens if the surface closes while the Surface Details utility window is open.**
17. **What the Copy action actually places on the pasteboard:** localized display text, timezone abbreviation, numeric offset, or ISO-8601. Display and clipboard formats may legitimately differ.
18. **An executable cross-consumer consistency test:** if the tooltip, the accessibility value, and Surface Details disagree at one injected clock instant, which test fails, and through which executable path?
19. **Early-warning code smells to grep for:** any final tooltip string stored in long-lived model state; any renderer calling `Date()` without an injected now or a hover/visible clock owner; any use of metadata write time as logical creation; any restore constructor where omitted and explicit-`nil` creation dates are indistinguishable; any VoiceOver path combining a full host string with Bonsplit's default; any Bonsplit edit while `git symbolic-ref --short HEAD` is not `main`.

### Gemini only

20. **Mouse-scrub cost at scale.** If formatting is correctly deferred to hover, aggressively scrubbing the pointer across 50 tabs triggers 50 on-demand formatter invocations. Foundation's plural-correct formatters are, in Gemini's words, "expensive to allocate and call on the fly." Neither of the other reviewers costs the lazy path.
21. **Timezone or locale change mid-session.** What happens to already-displayed `Created` and `Last activity` absolute values? Claude and Codex cover formatter configuration; only Gemini asks about a live change.
22. **Panel-type extensibility.** Promoting `createdAt` to exactly three panel types means a fourth type added later silently lacks a creation timestamp. Argues for the protocol-level requirement rather than three parallel additions.
23. **The framing that the spec asks for something the platform is bad at.** "SwiftUI is historically terrible at providing lazy, dynamic tooltips without timers or view body invalidations." Worth taking seriously as a reason the mechanism decision cannot be deferred: it may need an `NSViewRepresentable` owning `NSView.toolTip`, which is a design decision with API consequences, not an implementation detail.

---

## 3. Assumption Audit (merged and deduplicated)

### 3.1 Load-bearing and demonstrably false

1. **"`SurfaceActivityTracker` gives us a state-start."** It is a last-touch clock with a 250 ms leading-edge debounce, bumped by input and by non-transition lifecycle reports. Every working and idle duration rests on this. *(Claude, with Codex and Gemini reaching the same hole abstractly.)*
2. **"Fresh-on-hover is compatible with `.help()` and a precomputed string."** `.help(_:)` is evaluated at body time and has no hover-entry hook. *(All three.)*
3. **"Precomputation satisfies hover freshness."** It cannot without an explicit refresh rail; the top-tab sync path and the sidebar are both edge-driven and skip unchanged presentations, and Surface Details has no clock. *(Codex, Gemini.)*
4. **"The existing Surface Details `Refresh` will reread the new values."** `refresh()` re-captures only `snapshot`; `handle` is a construction-time `let`. *(Claude.)*
5. **"A cold-start time is derivable at the render site."** `publishCold` discards `observedLastTouchedAt` and publishes only a Bool. *(Claude, with Codex and Gemini flagging the arithmetic.)*
6. **"The notification store exposes the waiting start."** It exposes presence, not the matching record's `createdAt`. *(Codex, Claude, Gemini.)*
7. **"The existing Bonsplit accessibility field can carry the new semantics."** It is additive; host detail is composed before Bonsplit's default lifecycle, which is then appended. *(Codex.)*
8. **"Locale-aware duration formatting will automatically yield the locked 'for …' grammar."** `RelativeDateTimeFormatter` produces "ago/in," not a duration noun phrase. *(Codex, Claude.)*

### 3.2 Load-bearing, uncertain, and failing silently

9. **"`.help()` will render on the mark."** Roughly even odds by Claude's read, with Bonsplit documenting the exact silent failure twice in its own source, and both target sites structurally suspect (a `Button` label; a `GeometryReader` with `.accessibilityElement(children: .ignore)`). *(Claude; Codex flags "attached to the wrong layer" generically.)*
10. **"`createdAt` promotion is mechanically safe."** Only if fresh creation and legacy restore are distinguishable at **every** constructor. A defaulted `Date()` parameter is the specific hazard. *(Codex.)*
11. **"All panel creation paths funnel through the three obvious helpers."** Direct terminal replacement, placeholder repair, closed-browser reopen, transfer, detach, drag-out, and alternate restore paths need an explicit audit. *(Codex + Claude.)*
12. **"The translation pass is routine."** Six locales, plural variations, ru/uk one/few/many/other, plus Bonsplit's seven `.lproj` catalogs as a second output. `jq .` cannot detect a missing plural category. *(Claude, Codex, Gemini.)*
13. **"Surface Details can capture structured data with its current API."** `capture` today has only workspace/surface IDs and reads only `SurfaceMetadataStore`: no panel reference, no creation date, no notification timestamp, no shared projection. *(Codex.)*
14. **"The linked branch is current enough."** It is one commit behind `main` and the plan has no ancestry or fast-forward step. *(Codex.)*
15. **"A self-review is an adequate review gate."** *(Codex; Claude concurs structurally.)*
16. **"Timezone abbreviations are unambiguous copy values."** They are not globally unambiguous. *(Codex; Claude adds the missing `en_US_POSIX` locale hazard.)*
17. **"Screenshots are sufficient interaction evidence."** They prove presence, not rollover, arithmetic, hover refresh, overflow, or interaction preservation. *(Codex, Gemini, Claude.)*

### 3.3 Load-bearing and probably fine (verified good news the plan does not know it has)

18. **Last activity already survives restart.** `SessionPanelSnapshot.lastActivityAt` exists from C11-164 and `AppDelegate.swift:3324` seeds the tracker at restore. Criterion 7 is nearly free. *(Claude.)*
19. **Metadata source `ts` already round-trips.** `SessionPanelSnapshot.metadataSources: [String: PersistedMetadataSource]` exists explicitly to preserve the precedence chain across restarts. *(Claude.)*
20. **The cold threshold cannot be degenerate.** `SidebarAgentColdSettings` clamps to 60…3600 s. *(Claude.)*

### 3.4 Invisible assumptions the plan never states

21. That `Created: Not recorded` on every currently-open surface is acceptable on ship day, without self-explaining copy. *(Claude.)*
22. That waiting duration disappearing across restart, while Created and Last activity persist, is acceptable. *(Claude.)*
23. That adding a member to `public @MainActor protocol Panel` is safe alongside `BrowserPanel`'s existing unrelated `createdAt`. *(Claude.)*
24. That the isolated worktree will build without submodule and `GhosttyKit.xcframework` provisioning. It will not. *(Claude; Codex lists provisioning as a required preflight.)*
25. That one fresh c11 surface is enough parallelism for six locales with plurals. CLAUDE.md prescribes one sub-agent per locale for larger batches. *(Claude.)*
26. That the delegator may run local `xcodebuild` tests. Per project memory and C11-181, it may not. *(Claude; contradicted by Codex, see §5 Q29.)*
27. That the promotion of `createdAt` to exactly three panel types is architecturally complete. *(Gemini.)*
28. That deferred formatting is cheap enough for rapid pointer traversal across many tabs. *(Gemini.)*
29. That computer-use approval will be granted this time. It was withheld on C11-184. *(Claude.)*
30. That there will be no need for a rollback lever post-merge. *(Claude.)*

---

## 4. The Uncomfortable Truths (recurring hard messages)

1. **"One shared projection" is a slogan, not an algorithm.** Codex says it outright; Claude says the projection has no trustworthy input; Gemini says the plan "parrots" the criteria. Centralizing an ambiguous answer does not make it correct. It makes all three consumers wrong identically.

2. **The plan spends more precision on commit choreography than on the hardest product requirement: time that stays truthful.** Codex's phrasing. Claude's version: the plan restates constraints instead of resolving them. Gemini's version: the author summarized the task description into six bullets "without actually designing a technical solution for the most contradictory constraints."

3. **The feature's core requirement may be in tension with the platform, and the plan does not acknowledge it.** Gemini names it directly. Lazy, dynamic, timer-free tooltips are not something SwiftUI hands you. Claude enumerates the three escape routes and notes each violates a different locked constraint, and that the plan picks none, "which means the mechanism gets chosen by whoever types first."

4. **Every automated gate in the plan can pass in a world where the feature does not work.** All three models. The payload is testable, the appearance is not, and the payload test passing is actively misleading. The repo's own CLAUDE.md has a section named for exactly this ("Green Tests ≠ Working Product").

5. **Risk is back-loaded, and that is the plan's structure rather than an oversight of detail.** Claude. The three highest-risk items all sit in Step 6: at the end, behind an approval that was denied on the previous ticket, after the submodule is pushed and the translations are delegated. If the state-start turns out wrong in QA, the fix touches the lifecycle path Step 1 promised not to change, with a pushed submodule pointer, a delegated translation pass whose copy may need to change shape, and an open draft PR. Codex reaches the same place from the disruption side.

6. **A restored surface can be told it was created at app launch.** Codex. A one-token default (`= Date()`) in a restore constructor fabricates history, and the plan's chosen test (Codable round-trip) is structurally incapable of detecting it.

7. **Some contract lines will fail silently rather than loudly.** "Refresh rereads absolute activity truth" (the field Refresh cannot touch), "every individual agent mark" (overflow-hidden marks and the `+N` chip), "no `0 minutes` copy" (one keystroke into an idle pane). Claude. Nothing errors. The values are just wrong.

8. **Two things will be correct per contract and will read as broken to the operator.** `Created: Not recorded` everywhere on ship day, and waiting duration vanishing across restart while its neighbours persist. Claude. Neither is said out loud anywhere, and neither has a mitigation or a copy treatment.

9. **This is the third consecutive ticket on the same hot path and none of the three has been measured.** Claude. C11-184 defined a latency gate and recorded that it was not run. C11-185 defines none, and adds per-agent string composition. "This is how typing latency regresses: not in one commit, in three."

10. **The plan tells the delegator to do something the operator has already interrupted.** Claude, on Step 4's local test run and the C11-181 incident. A plan for this repo should not need to be told.

11. **The submodule discipline that has bitten this repo hardest gets half a sentence.** Claude and Codex. The failure it guards against is silent and unrecoverable in place, and C11-184 needed five explicit sub-steps.

12. **Self-review plus screenshots is not a rigorous terminal gate for a feature whose main failure modes are invisible in a static screenshot.** Codex.

13. **The ticket is excellent, and that is exactly what makes the thin plan costly rather than harmless.** Claude's closing note, and the fairest framing of the whole review: a well-specified ticket deserves a plan that converts specification into decisions. This one converts it into a shorter specification. The skeleton is right (baseline → shared projection → persistence → tests → submodule/localization → validation, with the single shared projection correctly placed before both consumers). It is only a skeleton.

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews. Questions 1 through 8 are blockers: the plan should not proceed to implementation until they are answered in writing.

### Blockers

1. **Where does the state-start timestamp come from, per presented state?** Produce a provenance matrix for working, idle, cold, waiting, and suppressed-waiting-presented-as-idle. `SurfaceActivityTracker.lastActivity` is a last-touch clock bumped by terminal input and by non-transition lifecycle reports. If the answer is `SurfaceMetadataStore.sources["activity"].ts`, say so in the plan and confirm you have verified the no-op-write guard at `SurfaceMetadataStore.swift:900-903` and the `metadataSources` round-trip. State the tie-break when tracker time and metadata-source time disagree. *If the current answer is "the tracker," the plan is wrong and must change before implementation starts.*

2. **What does the tooltip show when the operator types one character into a pane that has been idle for seven minutes?** If the answer is "Idle for 0 minutes," that is banned copy. If it is "Idle for 7 minutes," explain the mechanism, given question 1.

3. **What causes a tooltip to change from "2 minutes" to "3 minutes" when no lifecycle, attention, notification, or terminal-kind value changes?** Name the refresh rail for each of the three consumers separately: top-tab hover entry, per-mark sidebar hover entry, and Surface Details advancing while visible under one bounded leaf subscription. And name the mechanism: hit-testable padded frame with a static string, `NSViewRepresentable` owning `NSView.toolTip`, minute-granular string baked into the presentation, or something else. Each option violates a different stated constraint. Which one, and which constraint gives?

4. **How is that hover refresh implemented without date formatting in a typing-hot body and without `.onHover` state tracking that invalidates `TabItemView`?** If deferred formatting is the answer, what is the cost of a pointer scrubbing across 50 tabs?

5. **Does the live duration string go inside `BonsplitTabActivityPresentation`?** That struct is `Codable, Equatable, Hashable` and round-trips through persisted layout via `TabItem.swift:117`. If yes: how do you prevent a per-minute tab-model diff for every agent tab, and what happens when a localized sentence is persisted and restored after a UI-language change? If no: what structured, `Codable`/`Sendable` fields go in instead, and where does formatting happen? (A closure `() -> String` appears incompatible with the struct's conformances; confirm or refute.)

6. **Which step verifies that a `.help()` on the mark actually renders, and when?** Bonsplit documents this exact silent failure twice in its own source (`SafeTooltip.swift`, `TabBarView.swift:1911-1917`), and both target sites are structurally suspect. Why is the first hover in Step 6 rather than a day-one hardcoded `PROBE` on a tagged build? **And what happens if computer-use approval is withheld a second time: does this ship, and under what acceptance language?** *"We don't know" is the current answer and it is the single most consequential unknown in the plan.*

7. **Where does the cold-start input reach the render site?** `SurfaceLivenessDeriver.publishCold` discards `observedLastTouchedAt` and publishes only a Bool. Which step adds the published value, what is its type, and does the arithmetic use `trustedLastTouch + thresholdSeconds` rather than either endpoint alone?

8. **What is the complete duration-format contract?** Units and rollover boundaries; floor versus nearest; behavior below one minute (the commonest `working` case); behavior exactly at a boundary; behavior at the instant cold begins; future dates and clock correction; whether the state-only fallback applies to a real duration that rounds to zero. Name the formatter. If not `DateComponentsFormatter`, how do ru and uk get one/few/many correct, and what validates that, given `jq` cannot detect a missing plural category?

### Data model and correctness

9. **Which API returns the exact signal-eligible unread-notification `createdAt` for a surface**, why is that read guaranteed to match the state resolver, and what is the missing-record fallback?

10. **With two unread notifications on one surface, which `createdAt` is the waiting start:** oldest (when waiting began) or newest (which resets the duration on every notification, and is the easier code)?

11. **When raw waiting is suppressed and presented as idle, which timestamp drives "Idle for …"?**

12. **What is the fail-closed behavior for missing, future, negative, or contradictory timestamps?** Guarantee no negative duration and no fabricated zero.

13. **Does `createdAt` survive detach, drag-out, and cross-workspace transfer?** Criterion 6 tests only snapshot round-trip; `Workspace.swift:9548-9605` has explicit detach handling that mutates `derivedActivityBySurface`. Which test covers it? If none, `Created` silently becomes "now" on a common operation and ships green.

14. **How does a decoded legacy `created_at == nil` pass explicitly through restore without triggering a fresh-create default?** Enumerate the full path inventory: fresh create, session restore, legacy restore, transfer/detach, terminal replacement, placeholder repair, closed-browser reopen, layout-executor paths. State which preserve logical creation and which deliberately mint a new logical surface. The required regression test is real-constructor, not Codable round-trip.

15. **Why only terminal, browser, and markdown?** Does a future panel type silently lack a creation timestamp, and should this be a protocol-level requirement instead? Also confirm no collision with `BrowserProfileDefinition.createdAt` (`BrowserPanel.swift:323`).

### Surface Details

16. **How does `Refresh` reread Created and Last activity**, given that `SurfaceManifestView.refresh()` re-captures only `snapshot` and never `handle` (a construction-time `let`)? If the answer is "move the group into `SurfaceManifestSnapshot`," say so in the plan.

17. **How does `SurfaceManifestSnapshot.capture` obtain a live panel's `createdAt`, the notification timestamp, and the shared projection?** Is capture performed by `Workspace`, by a testable provider, or by a global lookup?

18. **What does Activity display for browser, markdown, shell, and agent surfaces with no trustworthy lifecycle evidence?**

19. **What happens if the surface closes while the Surface Details window is open?**

20. **Does the absolute timestamp formatter get `timeZone` and `locale = en_US_POSIX`?** Does the existing `Captured` row change as a result, and is that in scope given "do not redesign the panel beyond the new activity/timing group"? What happens if the user changes timezone or locale mid-session?

21. **What does Copy place on the pasteboard:** localized display text, timezone abbreviation, numeric offset, or ISO-8601? May display and clipboard formats differ, and where do the copy affordances live?

### Accessibility and interaction

22. **How does the Bonsplit API prevent a complete c11 accessibility string from being followed by Bonsplit's default "Running/Idle/…" value?** Today the seam is additive: host detail composes before Bonsplit's lifecycle, which is then appended. The locked order is lifecycle, then flagged reason, then suppression. Is this a complete override or additive detail, and does Bonsplit still append its waiting hint?

23. **What happens to the existing tooltip** at `TabBarView.swift:1916` and the existing `TabActivityAccessibility.help(for:)` (`TabItemView.swift:148-151`)? Does the mark tooltip suppress the tab tooltip in its region, or vice versa? Criterion 4 forbids behavior change; one of these two changes. Does the old helper become dead code or a second source of truth?

24. **Do overflow-hidden census marks and the `+N` chip get help text?** Criterion 1 says "every individual agent mark," and `workspacePulseMarkRow` compresses under width pressure.

25. **Which interaction regressions are explicitly tested:** tooltip attached to the padded mark target rather than the tab, row, or composition rail; tab selection; context menu; close button; overflow; layout unchanged?

### Performance

26. **Where exactly is the help payload precomputed, and have you measured that site?** The `pulseRoster` closure at `ContentView.swift:8626-8688` is **not** `.equatable()`-skipped and already walks every panel per workspace per invalidation. The ticket's guardrail names `TabItemView`, which **is** skipped. Is the guardrail pointing at the wrong view, and what is the measured cost at 30 agents? Note that `DateFormatter`/`DateComponentsFormatter` are expensive and not thread-safe.

27. **Why is there no latency gate at all**, when C11-184 defined one for the same code paths and then shipped without running it? What is the cumulative typing-latency evidence for C11-183 + 184 + 185 combined? *Current answer: none exists.*

28. **Is precomputing for every agent in the census the right default, given `workspacePulseVisibleAgents` is `prefix(2)`?**

### Process, gating, and sequencing

29. **Is Step 4's local test run a deliberate reversal or an oversight?** Project memory (C11-181) and C11-184's plan both forbid every local `xcodebuild test` action for c11 delegator work, including `c11-logic`, and C11-184 also forbids `scripts/test-unit-local.sh`. One reviewer (Codex) recommends `scripts/test-unit-local.sh` for host tests, in direct conflict. **The operator should arbitrate this explicitly, and the plan should record the exact permitted commands.**

30. **Which step provisions the isolated worktree** (`git submodule update --init --recursive ghostty vendor/bonsplit`, plus the `GhosttyKit.xcframework` symlink from the main checkout)? Without it, the Step 1 baseline build fails three times in a row for reasons that are not code.

31. **What is the agreed base, and where is the ancestry check?** The branch is currently one commit behind `main`. Confirm C11-183 and C11-184 ancestry and fast-forward before the first edit.

32. **What are the full Bonsplit sub-steps, and in what order?** Local `main` checkout, fetch, fast-forward **before the first edit**; `git symbolic-ref --short HEAD` confirmation; `git merge-base --is-ancestor HEAD origin/main`; a final fetch and drift recheck before the parent pointer commit. And: does Step 5's ordering survive the case where the translation pass reveals a needed Bonsplit `.lproj` string **after** the submodule is already pushed and pointed at?

33. **Which test goes in which target** (`c11LogicTests`, host `c11Tests`, Bonsplit's own), and what are the commit units and owned paths? This repo has specific precedent for getting it wrong (the `c11-logic` local-crash caveat, the C11-105 socket-unlink incident).

34. **Why is the final gate a self-review rather than a fresh independent review?**

35. **Will the draft PR be opened before validation so CI can inform the tagged run**, or is local host evidence intentionally the gate?

36. **What is the approved computer-use scope** (tagged app, hover and right-click flows, screenshots, data limits), and where will it be recorded? What is the terminal state on denial?

37. **What is the rollback lever?** If tooltips prove noisy, slow, or wrong post-merge, is there a settings gate, or is the only option a revert that also removes the Surface Details group operators will already be relying on?

38. **Which single test fails, through an executable path, if the tooltip, the accessibility value, and Surface Details disagree at one injected clock instant?**

### Product honesty

39. **Is `Created: Not recorded` on every currently-open surface acceptable on ship day**, for the weeks it takes long-lived workspaces to recreate surfaces? Will the copy explain itself, or just read as broken?

40. **Is waiting duration vanishing across restart acceptable** while Created and Last activity persist? `TerminalNotificationStore` is in-memory.

41. **Is the position that the ticket is the plan?** C11-184's plan ran ~500 lines for comparable surface area; this one is ~200 words. If the ticket is authoritative, state that explicitly and tell the review gate what it is reviewing against.

---

## Appendix: Reviewer Convergence Map

| Risk | Claude | Codex | Gemini |
|---|---|---|---|
| Stale precomputed duration vs fresh-on-hover, no timers | Yes | Yes (largest) | Yes (fatal) |
| State-start provenance undefined / wrong source | Yes (biggest) | Yes (matrix) | Partial |
| Cold = lastTouch + threshold, not boolean publish | Yes | Yes | Yes |
| Waiting timestamp has no accessor; multi-unread undefined | Yes | Yes | Yes |
| Localized string must not live in Bonsplit presentation | Yes | Yes | Yes (diff. fix) |
| Duration format / plural / rounding contract missing | Yes | Yes | Yes |
| Plan is a restatement, not a design | Yes | Yes | Yes |
| Surface Details under-designed; Refresh can't reread | Yes (specific) | Yes (broad) | Partial (TZ) |
| `createdAt` fabrication on restore / detach / transfer | Yes (detach) | Yes (restore) | Partial (types) |
| Silent visual failure; screenshots insufficient | Yes | Yes | Yes |
| Perf guardrail names wrong view / hover invalidation | Yes | Yes | Yes |
| Bonsplit submodule / branch discipline thin | Yes | Yes | No |
| Worktree, base, ancestry, PR-CI, review independence | Yes | Yes | No |
| Accessibility composition order duplication | Partial | Yes | No |
| No latency gate across 183/184/185 | Yes | No | No |
| Local test policy conflict (C11-181) | Yes | Contradicts | No |
| No rollback / kill switch | Yes | No | No |
| Lazy formatting cost at 50 tabs | No | No | Yes |
| Non-agent surface Activity display | No | Yes | No |
| Clipboard format (ISO vs localized) | Partial | Yes | No |
