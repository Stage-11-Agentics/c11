# Adversarial Plan Review — c11-185-plan (Claude)

Plan under review: `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md`
Ticket: C11-185 "Agent-state tooltips and persistent Surface Details activity timestamps"
Reviewed: 2026-07-29T18:28 (20260729-1828)
Mode: adversarial. Read-only. Nothing was modified.

---

## Executive Summary

**Concern level: high, and not for the reason it looks like.** The plan is not wrong. It is *absent*. Six sentences, roughly two hundred words, restating the ticket's own Architecture section in fewer words and adding zero decisions. Compare its sibling C11-184, which needed ~500 lines for a comparable surface. Every hard call this ticket contains — where the state-start timestamp comes from, how a tooltip stays fresh without a timer, what formatter produces a plural-safe duration, which view precomputes what — gets made silently at the keyboard, and the first time any human or reviewer sees the actual design is step 6's self-review, after all of it is built.

**The single biggest issue** is that the ticket's central data requirement does not exist in the codebase and no step creates it. The locked contract says working and idle durations come from "the c11-observed lifecycle or input boundary recorded by `SurfaceActivityTracker`." `SurfaceActivityTracker` records **last touch**, not **state start**. It is bumped by terminal input (`GhosttyTerminalView.swift:3862`), by conversation claim (`ConversationHandlers.swift`), and by *every* call to `onShellActivityChanged` / `onAgentLifecycleChanged` (`SurfaceLivenessDeriver.swift:117`, `:160`) whether or not the state actually changed. Build the duration on it and the tooltip resets to zero when the operator types one character into an idle pane whose presented lifecycle never moved — producing exactly the `0 minutes` copy the contract bans. The real state-start does exist, in a place the plan never names (`SurfaceMetadataStore.sources["activity"].ts`, protected by the no-op-write guard at `SurfaceMetadataStore.swift:900-903`, persisted via `SessionPanelSnapshot.metadataSources`). A plan this terse will not find it; the ticket sentence points at the wrong source and the plan repeats the pointer.

**The second biggest issue** is that the most likely failure mode of this entire feature is *silent*, and the plan's only detector for it is the gate that got switched off last time. Bonsplit already documents this exact bug twice in its own source — `SafeTooltip.swift` and `TabBarView.swift:1911-1917`: a tooltip attached to an occluded or non-hit-testable view "silently never appeared," because macOS does not query occluded views for tooltips. The activity mark is a decorative leaf. If `.help()` lands on it wrong, everything compiles, every test in step 4 passes, CI is green, and the feature does not exist. Step 6's hover evidence is the only thing that can catch it — and it is gated on "the separately requested approval," which for the immediately preceding ticket (C11-184) was **withheld**, shipping ten visual scenarios unvalidated by explicit operator decision. The plan has no answer for a second denial.

---

## How Plans Like This Fail

**Pattern 1 — "the derived-display feature that discovers its data doesn't exist."** UI tickets that surface a *duration* fail on the same rock: the system tracked *state*, not *when state began*. Someone finds a timestamp with a plausible name, wires it up, the numbers look fine in the happy path, and the bug is a class of interaction nobody tested. This plan is maximally vulnerable: step 1 says "map the shared lifecycle/attention projection … **without changing lifecycle inference**," which forecloses the one change that would produce a real state-start; steps 2–3 add only the projection and `createdAt`. There is no step in this plan whose output is a trustworthy state-start timestamp. It is the plan's load-bearing input and it is missing.

**Pattern 2 — "green tests, dead feature."** The repo's own CLAUDE.md has a section named for this ("Green Tests ≠ Working Product"). Tooltips are the canonical instance: the payload is testable, the *appearance* is not, and the payload test passing is actively misleading. Step 4's eight test cases all test the projection. None of them can fail if the tooltip never renders.

**Pattern 3 — the third change to a hot surface where the first two never got measured.** C11-183 and C11-184 both touched `TabItemView` and the sidebar mark renderers. C11-184's plan defines a 20-agent ≤1 ms p95 gate and then records, in bold, that it "was not run; flag-tier motion ships unmeasured." C11-185 adds per-agent string composition and (depending on the mechanism chosen) per-minute model churn on top of that, and defines **no latency gate at all** — step 4 is "focused safe logic/host tests and build checks." Three tickets, cumulative unmeasured risk on the one code path the repo protects most aggressively. This is how typing latency regresses: not in one commit, in three.

**Pattern 4 — the plan that is a table of contents.** When a plan is a restatement of the ticket, the delegator's first hour is spent re-deriving the decisions the plan was supposed to record, and the *reviewer* has no baseline to review against — they can only review the code, not whether the code matches an intended design. That collapses the plan → implement → review chain into implement → review, which is precisely what the lattice-orchestrator workflow exists to prevent.

**Pattern 5 — sequencing bugs in submodule work.** The repo's most-repeated failure (CLAUDE.md pitfall, C11-184 Phase 0, the ancestry gate) is a Bonsplit commit made on a detached HEAD and orphaned. C11-184 needed five explicit sub-steps to guard it. C11-185 gives it half a sentence.

---

## Assumption Audit

### Load-bearing, and unlikely to hold

1. **"`SurfaceActivityTracker` gives us a state-start."** *Load-bearing. False.* It is a last-touch clock with a 250 ms leading-edge debounce, bumped by input and by non-transition lifecycle reports. See Executive Summary. Everything about working/idle duration rests on this and it is wrong as stated in the ticket the plan is executing.

2. **"A cold-start time is derivable at the render site."** *Load-bearing. Currently false.* Cold-start = `lastTouched + threshold`. `lastTouched` is never published to the UI: `SurfaceLivenessDeriver.publishCold` takes `observedLastTouchedAt` purely as a local staleness guard and discards it, publishing only `setAgentCold(Bool)`. So the sidebar/top-tab precompute path has no access to the cold-start input. The plan's step 2 says "precompute it for top tabs and `WorkspacePulseAgent`" without ever saying *from what*. A new published value is required and no step adds it.

3. **"`.help()` will render on the mark."** *Load-bearing. Roughly even odds, and failure is silent.* Bonsplit documents this exact failure twice in its own source. Additionally the sidebar summary mark sits inside a `Button` label (`ContentView.swift:12062`), and macOS tooltip registration inside button labels is unreliable; the census mark sits inside a `GeometryReader` with `.accessibilityElement(children: .ignore)`.

4. **"Fresh-on-hover is compatible with `.help()`."** *Load-bearing. False as stated.* `.help(_:)` takes a `String` evaluated during body evaluation. It cannot recompute on hover entry. The guardrail demands fresh-on-hover *and* no repeating timers. The three ways out each violate a different constraint (see Challenged Decisions). The plan picks none.

5. **"The existing Surface Details `Refresh` will reread the new values."** *Load-bearing. False.* `SurfaceManifestView.refresh()` reassigns only `snapshot = SurfaceManifestSnapshot.capture(...)`. `handle: SurfaceHandleInfo` is a `let` supplied at window construction and never re-read. Step 3's "capture structured Activity/Created/Last activity data … separately from metadata JSON" points directly at `SurfaceHandleInfo`, the one field Refresh cannot touch. Contract line "Refresh rereads absolute activity truth" then fails silently.

6. **"The translation pass is routine."** *Load-bearing for criterion 10. Optimistic.* If durations are composed with a hand-rolled `%lld minutes` key, six locales need xcstrings **plural variations**, and ru/uk require one/few/many/other — a structurally different xcstrings shape that `jq .` well-formedness will not catch a missing category in. Step 5 treats this as "validate catalogs/tokens."

### Load-bearing and probably fine

7. **Last activity survives restart.** Already true: `SessionPanelSnapshot.lastActivityAt` exists (C11-164) and `AppDelegate.swift:3324` seeds the tracker at restore. Criterion 7 is nearly free. Credit to the plan for not over-engineering it — though it also never notices that it is free.

8. **Metadata source `ts` round-trips.** True: `SessionPanelSnapshot.metadataSources: [String: PersistedMetadataSource]` explicitly exists "preserving the precedence chain across restarts." This is the good news the plan doesn't know it has.

9. **Cold threshold cannot be degenerate.** True: `SidebarAgentColdSettings` clamps to 60…3600 s, so "Cold for" can never collapse into total idle time via a zero threshold.

### Invisible assumptions the plan never states

10. That `Created` being `Not recorded` on every currently-open surface is acceptable on ship day (see Uncomfortable Truths).
11. That waiting duration disappearing across restart — `TerminalNotificationStore` is in-memory — is acceptable while Created and Last activity persist.
12. That adding a member to the `public @MainActor protocol Panel` is safe (it is, in-app, but `BrowserPanel.swift` is 10,278 lines and already carries an unrelated `createdAt` on `BrowserProfileDefinition:323`).
13. That the isolated worktree will build. It will not, three times in a row, until submodules and the `GhosttyKit.xcframework` symlink are provisioned — a documented CLAUDE.md pitfall the plan's step 1 walks straight into.
14. That "one fresh c11 surface" for six locales is enough parallelism. CLAUDE.md says one sub-agent per locale for larger batches.
15. That the delegator may run local tests. It may not — see Challenged Decisions #7.

---

## Blind Spots

**B1. There is no step that creates the state-start timestamp.** Restating: this is not a gap in detail, it is a missing deliverable. Steps 1–3 produce a projection, a `createdAt`, and details capture. Nothing produces the input the projection needs.

**B2. Detach, transfer, and drag-out are never mentioned.** `createdAt` must survive a surface moving between panes, workspaces, and windows. `Workspace.swift` has explicit detach handling around lines 9548–9605 that adds and removes `derivedActivityBySurface` entries. If any of those paths re-mints the panel, `Created` silently becomes "now" — the precise fabrication the contract forbids. Criterion 6 tests only "snapshot round-trip and restore," so a broken detach path ships green. This is the highest-probability *correctness* bug after the state-start.

**B3. The performance guardrail names the wrong view.** The ticket forbids formatting inside `ContentView.TabItemView` body and `WindowTerminalHostView.hitTest()`. But `TabItemView` is already `.equatable()`-skipped during typing. The path that is *not* skipped is the inline `pulseRoster` closure at `Sources/ContentView.swift:8626-8688`, which already walks every panel calling `tab.attentionSnapshot(...)` and `notificationStore.hasUnreadNotification(...)` per workspace on every sidebar invalidation. That is exactly where step 2's "precompute it for … `WorkspacePulseAgent`" lands. `DateFormatter`/`DateComponentsFormatter` are expensive and not thread-safe; N agents × M workspaces × every invalidation is a real regression vector that the stated guardrail literally permits. The plan inherits the guardrail without noticing it points at the already-safe view.

**B4. Nobody looked at the tooltip that already exists.** `TabBarView.swift:1916` already attaches `.help(tooltip)` to tab chrome, and `TabActivityAccessibility.help(for:)` (`TabItemView.swift:148-151`) already returns a localized help string for `waiting`. Adding a second tooltip inside a region a parent tooltip covers changes which one appears. Whichever wins, one of the two behaviors changes — and criterion 4 forbids behavior change. Also: the existing `TabActivityAccessibility.help` will now either be dead code or a second source of truth for the same sentence. The plan doesn't mention it.

**B5. Wasted precompute.** `workspacePulseVisibleAgents` is `prefix(2)`. The summary rows show two agents. Precomputing help strings for every agent in the census (step 2) is mostly discarded work, performed in the hot parent closure. The census mark row does need per-agent help — but it also compresses to a `+N` chip under width pressure (`workspacePulseMarkRow`), so hidden agents get no tooltip and the `+N` chip gets none either, against criterion 1's "every individual agent mark."

**B6. Sub-minute is undefined.** The contract bans `0 minutes` only for missing evidence. What does a state three seconds old display? "Working for 3 seconds"? bare "Working"? The unit ladder and rounding rule are unspecified — and this is the *most common* case for `working`, the state operators look at most.

**B7. "The exact surface unread-notification creation time" is ambiguous under multiple unreads.** `TerminalNotification.createdAt` exists but there is no per-surface accessor (only `hasUnreadNotification(forTabId:surfaceId:)`), so one must be added. With two unreads on one surface: oldest (when waiting began — correct) or newest (resets on every new notification — wrong, and the easier code)? Unspecified.

**B8. No rollback, no kill switch, no settings gate.** C11-184 shipped with a pre-registered fallback ladder. C11-185 has nothing. If the tooltips prove noisy, slow, or wrong after merge, the only lever is a revert that also removes the Surface Details group operators will already be relying on.

**B9. Timezone versus locale-awareness is unresolved, and the existing formatter is a footgun.** `SurfaceManifestView.timestampFormatter` is a `DateFormatter` with fixed `dateFormat = "yyyy-MM-dd HH:mm:ss"`, **no timezone and no explicit locale**. The contract demands timezone. A fixed `dateFormat` without `locale = en_US_POSIX` renders non-Gregorian calendars and non-Latin digits under some user locales — the opposite of "an unambiguous copy value." And adding TZ to the shared formatter changes the existing `Captured` row, brushing "do not redesign the panel beyond the new group." Three coupled decisions, zero mentioned.

**B10. Which formatter produces the duration.** Unstated, and the wrong answers are the reachable ones. `RelativeDateTimeFormatter` — already in this very file — yields "7 min ago," not a duration, and will produce "Working 2 minutes ago." A hand-rolled `%lld minutes` key drags in the plural-variation problem above. `DateComponentsFormatter` is the right tool (locale-correct "7 minutes" including Slavic plural rules, for free) composed into `String(localized: "…for %@")`. One clause of the plan naming it would remove an entire risk class.

**B11. Step ordering inside step 5 is backwards for localization.** "Commit and push any Bonsplit change … before the parent pointer. Delegate the final six-locale translation pass…" — if the translation pass reveals that a Bonsplit `.lproj` string is needed (Bonsplit uses seven `.lproj` catalogs via `Bundle.module.localizedString`, not xcstrings), the submodule has already been pushed and pointed at, and the whole sequence has to be redone.

**B12. No commit-unit plan, no file ownership table, no test-target assignment.** Which tests go to `c11LogicTests` versus host `c11Tests` versus Bonsplit's own target is a decision with real consequences in this repo (the `c11-logic` local-crash caveat, the C11-105 socket-unlink incident caused by a test in the wrong target). C11-184's plan has a table for this. C11-185 has "Run focused safe logic/host tests."

---

## Challenged Decisions

**1. Attaching a live localized sentence to `BonsplitTabActivityPresentation`.** That struct is `Codable, Equatable, Hashable` and is carried on the internal `TabItem`, which decodes it (`TabItem.swift:117`) — i.e. it round-trips through Bonsplit's persisted layout. Baking "Working for 2 minutes" into it means (a) every agent tab's presentation value changes once a minute forever, producing a tab-bar model diff on a cadence, and (b) human-language localized copy is serialized into persisted layout and can be restored stale or in the previous UI language. It also crosses the generic/product line the ticket draws: a localized product sentence is not "generic help data," so "Bonsplit renders supplied presentation; c11 owns product semantics" is honored in letter only. **Counter-proposal:** pass *structured, stable* data — a `helpStateToken: String` plus an optional `helpStateStartedAt: Date` plus modifier booleans — and have the host format. That value only changes on real transitions, so no cadence churn and nothing localized is persisted. It costs a formatting seam; it buys the whole problem class.

**2. `.help()` as the mechanism at all.** Given SafeTooltip's recorded history, the honest options are: (a) `.help()` on a deliberately hit-testable padded frame — cheapest, silent-fail risk, and hit-testing the mark risks criterion 4's "must not change tab selection / close behavior"; (b) an `NSViewRepresentable` that owns `NSView.toolTip` and can be mutated on hover — solves freshness, but a closure breaks `Codable`/`Equatable` on the presentation struct; (c) a custom hover popover — solves everything, violates "native tooltip." The plan states the constraint and names no mechanism, which means the mechanism gets chosen by whoever types first.

**3. Precomputing for every agent rather than lazily for the visible few.** Two summary rows are shown. `prefix(2)`. The default here looks like a default, not a choice.

**4. Reusing `SurfaceHandleInfo` for the new activity data.** Structurally tempting, functionally wrong — `Refresh` doesn't touch it. **Counter-proposal:** put the activity/timing group inside `SurfaceManifestSnapshot` (which `refresh()` does re-capture) as a sibling to `metadata`/`sources`, keeping it "separate from metadata JSON" as the ticket requires while remaining refreshable.

**5. Step 1's "without changing lifecycle inference."** Presented as a safety constraint; functionally it forecloses the fix the ticket needs. Recording a state-start at transition edges is not "changing lifecycle inference" — the inference is unchanged, an observation is added. The phrasing will read to a careful delegator as a prohibition on the correct implementation.

**6. One translator surface for six locales, with plurals.** CLAUDE.md: "For a larger batch, spawn one sub-agent per locale — six in parallel." Duration copy with plural variations across ru/uk/ko/ja/zh-Hans/zh-Hant is a larger batch. This looks like a default.

**7. Step 4's "Run focused safe logic/host tests and build checks" — this contradicts a standing operator instruction.** The project memory records: *defer ALL local c11 xcodebuild (build/test, ANY scheme including the "safe" c11-logic) to CI during delegator/headless runs, even when a boot prompt calls the command safe (C11-181: operator interrupted a c11-logic test run)*. C11-184's plan states it as a hard rule: "The operator explicitly forbids every local `xcodebuild test` action for this ticket, including the normally safe `c11-logic` scheme. Do not run `scripts/test-unit-local.sh` either." A delegator following C11-185 step 4 literally will run the thing the operator interrupted last time. This is the one line in the plan that is not merely thin but actively wrong.

**8. Leaving the whole visual gate to step 6 behind an unspecified approval.** The most likely failure is invisible without a hover. Deferring the first hover to the end is the worst possible ordering. **Counter-proposal:** a day-one smoke — tagged build, one hardcoded `.help("PROBE")` on each of the three targets, confirm all three appear, *then* build the projection. That converts the highest-risk unknown into a five-minute check before any of the expensive work is done, and it needs no product copy and arguably a much narrower approval scope.

---

## Hindsight Preview

Two years on, the things we'd say:

- *"We should have known the tracker was a last-touch clock."* Its own doc comment says so. Thirty seconds of reading `SurfaceActivity.swift` was the whole diagnosis, and it never happened during planning.
- *"Why didn't we just probe the tooltip first?"* Bonsplit had the warning written down, in a comment, with the failure mode spelled out. We shipped the feature and found out in QA. Or worse: didn't.
- *"We measured the latency gate three tickets late."* C11-183, 184, 185 all touched the same hot path; the gate defined in 184 was never run, and 185 defined none. When typing latency did regress, we had three candidate commits and no baseline.
- *"`Created` said Not recorded for a month and everyone thought it was broken."* Honest per contract, invisible as a rationale to the person looking at the panel.
- *"The plan was a summary and the review reviewed the code."* The plan → implement → review chain lost its middle link, and the reviewer's only baseline was the ticket.

### Early-warning signals this plan has no mechanism to detect

| Signal | Detects | Present in plan? |
|---|---|---|
| Tooltip appears at all on a tagged build, day one | Blocker 2 (silent fail) | No — deferred to step 6 behind approval |
| "Idle for 7 minutes" → "Idle for 0 minutes" after one keystroke in an idle pane | Blocker 1 (wrong state-start source) | No |
| `Cold for` ever exceeds (Last-activity age − threshold) | cold arithmetic inverted | No |
| `Created` changes after a detach/drag-out/transfer | B2 | No |
| Tab-bar body-evaluation count per minute with 20 agents | Blocker 4 (cadence churn) | No |
| Sidebar parent-closure time with 30 agents | B3 (guardrail names wrong view) | No |
| Missing plural category in ru/uk | B10 / criterion 10 | No — `jq` won't catch it |
| Bonsplit submodule HEAD detached before the pointer commit | orphaned commit | No — half a sentence |

Eight signals, zero mechanisms. That is the shape of the risk here: not that the plan will do the wrong thing, but that it will not notice.

---

## Reality Stress Test

**Disruption A — computer-use approval is withheld again.** Precedent is one ticket old and explicit. Then: blockers 2 and 3 are undetectable, criterion 11 becomes "DEFERRED" for the second consecutive ticket, and c11 ships a hover feature that has never been hovered. Worse than C11-184's deferral, because C11-184's deferred items were *refinements* to visible behavior (motion, latency) while C11-185's deferred item is *whether the feature exists*. The plan has no fallback text for this and no defined terminal state on denial.

**Disruption B — the state-start turns out wrong in QA (or after merge).** Fixing it means recording a transition timestamp, which touches `SurfaceLivenessDeriver` / `Workspace` / the metadata store — exactly the lifecycle path step 1 promised not to change and the reviewer signed off on not changing. That is a re-plan mid-implementation with the Bonsplit submodule already pushed and pointed at, the translation pass already delegated (durations may change shape → re-translate), and a draft PR already open. This is the disruption most likely to double the ticket's cost.

**Disruption C — the operator's attention moves on.** This is the third ticket in a family, in a repo where memory records "delegators must press past PR-open." A six-sentence plan leaves `pr_open` with a draft PR, deferred visual evidence, and every hard decision undocumented. Whoever picks it up in three weeks reads a plan that tells them nothing about why the code looks the way it does. The ticket becomes the only artifact, and the ticket doesn't know what was built.

**All three simultaneously:** the plan ships a feature that may not render, whose durations may be wrong in the commonest interaction, with no visual evidence, no latency measurement, no rollback lever, and no written record of the decisions that produced it — and it reports green. Every automated gate in step 4 passes in that world. That is the honest worst case, and it requires no bad luck, only the same two decisions that were already made once on C11-184.

---

## The Uncomfortable Truths

1. **The ticket is the plan.** Everything load-bearing lives in C11-185's description. The plan file adds no decision, no sequencing insight, no risk, no gate. If the ticket is authoritative, say so and delete the plan; if the plan is authoritative, it has to contain the decisions. What exists now is the worst of both: a document that looks like a plan and functions as a summary, so the review gate has nothing to bite on.

2. **The plan restates constraints instead of resolving them.** "Attach native help only to the top-tab mark and the two individual sidebar mark locations" is the ticket's sentence. The plan's job was to say *how*, given that `.help()` is static-at-body-time, that the target may not be hit-testable, that a parent already owns a tooltip, and that the presentation struct is Codable. It says none of that.

3. **The three highest-risk items are all in step 6.** Which is to say: at the end, behind an approval, after the submodule is pushed and the translations are done. Risk should be front-loaded. This is back-loaded, and the ordering is not an oversight of detail — it is the plan's structure.

4. **`Created` will read `Not recorded` for every surface the operator currently has open.** On ship day, the feature's headline new field is blank everywhere until surfaces are recreated — which for long-lived workspaces means weeks. This is *correct* per contract and *will read as broken*. Nobody has said it out loud, and there is no mitigation discussed (not even a parenthetical "(not recorded before 0.62)" instead of a bare `Not recorded`).

5. **Waiting duration will vanish across restart while its neighbours persist.** `TerminalNotificationStore` is in-memory. So after a restart, a waiting surface shows Created (persisted), Last activity (persisted), and no waiting duration. Internally consistent with the contract, externally reads as a bug, unmentioned.

6. **This plan tells the delegator to do something the operator has already interrupted.** Step 4's local test run. It is in project memory as a specific past incident (C11-181). A plan for this repo should not have to be told.

7. **The submodule discipline that has bitten this repo hardest gets half a sentence.** "Commit and push any Bonsplit change to `Stage-11-Agentics/bonsplit` main before the parent pointer." C11-184 needed: check out local `main`, fetch, fast-forward, confirm `git symbolic-ref --short HEAD` is `main`, verify `git merge-base --is-ancestor HEAD origin/main`, *then* the pointer. The failure this guards against (orphaned commit on a detached HEAD) is silent and unrecoverable-in-place.

8. **The feature is genuinely good and the ticket is genuinely excellent.** That is what makes the thin plan costly rather than harmless: a well-specified ticket deserves a plan that converts specification into decisions, and this one converts it into a shorter specification.

### Credit where due

The six steps are in the right order (baseline → shared projection → persistence → tests → submodule/localization → validation), and putting the single shared projection before both consumers is the correct architectural instinct — it is the thing that keeps tooltip and Surface Details from drifting, which is criterion 5. Step 4's enumerated test cases are a genuinely good list that maps cleanly onto criterion 8. Step 3 correctly keeps legacy snapshots `nil` rather than backfilling. Step 5 and 6 correctly refuse to merge and correctly gate on approval. The skeleton is right. It is only a skeleton.

---

## Hard Questions for the Plan Author

1. **Where does the state-start timestamp come from?** `SurfaceActivityTracker.lastActivity` is a last-touch clock bumped by terminal input and by non-transition lifecycle reports. Name the actual source. If the answer is `SurfaceMetadataStore.sources["activity"].ts`, say so in the plan and confirm you have verified the no-op-write guard at `SurfaceMetadataStore.swift:900-903` and the `metadataSources` round-trip. *If the current answer is "the tracker," the plan is wrong and must change before implementation starts.*

2. **What does the tooltip show when the operator types one character into a pane that has been idle for seven minutes?** If the answer is "Idle for 0 minutes," that is banned copy. If it is "Idle for 7 minutes," explain how, given question 1.

3. **Where does the cold-start input reach the render site?** `publishCold` discards `observedLastTouchedAt` and publishes only a Bool. Which step adds the published value, and what is its type?

4. **Which step verifies that a `.help()` on the mark actually renders?** Given `SafeTooltip.swift` and `TabBarView.swift:1911-1917` documenting this exact silent failure, why is the first hover in step 6 rather than a day-one probe? **What happens if computer-use approval is withheld a second time — does this ship, and under what acceptance language?** *"We don't know" is the current answer and it is the single most consequential unknown in the plan.*

5. **What is the mechanism for "refresh tooltip copy on hover entry" given that `.help(_:)` is evaluated at body time?** Name it: hit-testable padded frame with a static string, `NSViewRepresentable` owning `NSView.toolTip`, or minute-granular string baked into the presentation. Each violates a different stated constraint. Which one, and which constraint gives?

6. **Does the live duration string go inside `BonsplitTabActivityPresentation`?** If yes: how do you prevent a per-minute tab-model diff for every agent tab, and what happens when a localized sentence is persisted into Bonsplit's layout and restored after a UI-language change? If no: what structured fields go in instead, and where does formatting happen?

7. **Does `createdAt` survive detach, drag-out, and cross-workspace transfer?** Criterion 6 only tests snapshot round-trip. `Workspace.swift:9548-9605` has explicit detach handling. Which test covers it? If none, `Created` silently becomes "now" on a common operation and ships green.

8. **Where exactly is the help payload precomputed, and have you measured that site?** The `pulseRoster` closure at `ContentView.swift:8626-8688` is not `.equatable()`-skipped and already walks every panel per workspace per invalidation. The ticket's guardrail names `TabItemView` — which is skipped. Is the guardrail pointing at the wrong view, and what is the measured cost at 30 agents?

9. **Why is there no latency gate at all**, when C11-184 defined one for the same code paths and then shipped without running it? What is the cumulative typing-latency evidence for C11-183 + 184 + 185 combined? *Current answer: none exists.*

10. **What formatter produces "7 minutes"?** If not `DateComponentsFormatter`, how do ru and uk get one/few/many correct, and what validates that beyond `jq` well-formedness (which cannot detect a missing plural category)?

11. **What does a three-second-old state display?** Specify the unit ladder and rounding rule. This is the commonest case for `working`.

12. **With two unread notifications on one surface, which `createdAt` is the waiting start?** Oldest or newest? Newest resets the duration on every notification.

13. **How does `Refresh` reread Created and Last activity**, given that `SurfaceManifestView.refresh()` re-captures only `snapshot` and never `handle`?

14. **Does the absolute timestamp formatter get `timeZone` and `locale = en_US_POSIX`?** And does the existing `Captured` row change with it — and is that in scope, given "do not redesign the panel beyond the new activity/timing group"?

15. **What happens to the existing tooltip** at `TabBarView.swift:1916` and the existing `TabActivityAccessibility.help(for:)`? Does the mark tooltip suppress the tab tooltip in its region, or vice versa? Criterion 4 forbids behavior change; one of these two changes.

16. **Do overflow-hidden census marks and the `+N` chip get help text?** Criterion 1 says "every individual agent mark."

17. **Why does step 4 instruct a local test run** when project memory (C11-181) and C11-184's plan both explicitly forbid every local `xcodebuild test` action for c11 delegator work, including `c11-logic`? Is this an oversight or a deliberate reversal?

18. **What are the Bonsplit sub-steps?** Local `main` checkout, fetch, fast-forward, `symbolic-ref` confirmation, `merge-base --is-ancestor` verification — all of them, before the pointer. And: does step 5's ordering survive the case where the translation pass reveals a needed Bonsplit `.lproj` string *after* the submodule is already pushed?

19. **Which step provisions the isolated worktree** (`git submodule update --init --recursive ghostty vendor/bonsplit` plus the `GhosttyKit.xcframework` symlink)? Without it, step 1's baseline build fails three times in a row for reasons that are not code.

20. **What is the rollback lever?** If tooltips prove noisy, slow, or wrong post-merge, is there a settings gate, or is the only option a revert that also removes the Surface Details group?

21. **Is `Created: Not recorded` on every currently-open surface acceptable on ship day**, and is the copy going to explain itself, or just read as broken?

22. **Why is this plan two hundred words when C11-184's was five hundred lines for comparable surface area?** Is the position that the ticket is the plan? If so, that should be stated, and the review gate should be told what it is reviewing against.
