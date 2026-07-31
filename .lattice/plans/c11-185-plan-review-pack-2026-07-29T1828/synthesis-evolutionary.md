# Synthesis: Evolutionary Reviews, C11-185

Reviews synthesized: `evolutionary-claude.md` (Opus 5), `evolutionary-codex.md` (Codex), `evolutionary-gemini.md` (Gemini).
Lens: Evolutionary / Exploratory. Plan: `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md` (6 steps). Contract: C11-185.
Attribution shorthand: **[C]** Claude, **[X]** Codex, **[G]** Gemini, **[all]** unanimous.

---

## Executive Summary

All three reviewers independently reached the same conclusion in three different vocabularies: **the plan is aiming one level below what it is actually building.** It reads as "add tooltip strings and two timestamp fields"; what it delivers is c11's first per-surface temporal model. Claude calls it a "temporal ledger" and the third leg of the C11-183/184/185 tripod (shape, then modifiers, then time). Codex calls it a "surface activity truth packet." Gemini calls it an "Agent Profiling and Telemetry Engine." Same object, three names.

The strongest technical consensus is a single architectural inversion: **carry immutable semantic time anchors through the hot paths and format lazily at the edge; never cache the rendered duration string in a value type that crosses an Equatable gate.** Two reviewers independently derive this from the plan's own internal contradiction: the plan says "precompute for top tabs and `WorkspacePulseAgent`" *and* "refresh tooltip copy on hover entry," and those cannot both be true. Claude grounds the failure in verified line numbers (`ContentView.swift:11745`, `Workspace.swift:6818`, `WorkspaceContentView.swift:286`) and adds that SwiftUI `.help()` is structurally incapable of hover-time refresh. Codex reaches the same place from the Bonsplit side (an immutable `helpText` in `BonsplitTabActivityPresentation` cannot refresh). Gemini reaches it from the reuse side (baking localized strings early forecloses non-UI consumers). This is the single highest-leverage change to the plan, and it makes acceptance criterion 5 automatically true rather than merely hard.

The second consensus is **freeze the temporal semantics before writing code, and data-first sequencing.** Both Claude and Codex want the timestamp-source rules written down as a table, both flag the cold-duration derivation as semantically suspect, both want persistence landed and tested before any UI, and both want Surface Details as the first vertical slice with Bonsplit plus the submodule last.

The sharpest disagreement worth the author's attention: **whether to emit a state-transition event in this ticket.** Claude argues yes, one line, because "a log started today is worth more in a month than a log started in a month is worth ever." Codex argues explicitly no: do not start activity history here. That decision is worth making deliberately rather than by default.

Gemini contributes one thing neither other reviewer noticed and which is cheap and real: **wall-clock subtraction is wrong across sleep/wake.**

---

## 1. Consensus Direction

Evolution paths identified by more than one model, ordered by strength of agreement.

1. **This is a temporal model, not a tooltip. [all]** The persistent deliverable is a per-surface packet: presented lifecycle, state boundary, last activity, logical creation time, flag reason and age, suppression. Tooltips and Surface Details are its first and most primitive consumers. All three reviewers say the packet outlives and outweighs any individual renderer.

2. **Separate semantic truth from localized text. [all]** Two layers, not one: an immutable data type (Codex: `SurfaceActivityTruth`; Gemini: `TemporalAgentProfile`; Claude: anchors on the existing structs) plus a pure formatter taking that data and an injected `now`. Gemini's phrasing is the memorable one: "do the math in raw units as deep in the stack as possible, project into localized strings at the absolute edge." Codex adds the test benefit: fixed dates become trivially injectable.

3. **A precomputed final string cannot satisfy hover-entry refresh; design the refresh seam explicitly. [C][X]** Both reviewers want the plan to *reject cached final strings in writing*. Claude proposes an AppKit `LazyTooltip` (`NSViewRepresentable` + `NSToolTipOwner`, roughly 40 lines) whose provider closure runs at hover time. Codex proposes a generic Codable temporal-help payload (undated text templates plus an optional boundary date) that Bonsplit samples `Date()` against on hover entry, keeping Bonsplit ignorant of c11 policy. These are compatible: Claude's is the c11-side mechanism, Codex's is the submodule-side contract.

4. **The three hot-path Equatable gates must not see a minute-ticking value. [C][X]** Claude names them concretely: `TabItemView.==` compares `workspacePulse`, which holds `agents: [WorkspacePulseAgent]`; the top-tab sync gates on `existing.activityPresentation != activityPresentation` in two places. A rendered duration inside either means every sidebar row and every agent tab diffs once a minute forever, on paths CLAUDE.md marks as typing-latency-critical. Codex states the same constraint as a rule: use `SidebarDecayClock` only in small visible leaves, never from the equatable sidebar row or the Bonsplit tab row.

5. **Pre-register the timestamp-source table before implementation. [C][X]** The contract implies four duration semantics from three different sources with three fallback rules. Both reviewers want that written as an explicit table (lifecycle → trustworthy boundary → behavior when evidence is missing) as a plan artifact, not discovered during implementation. Codex supplies a draft table; Claude supplies the reason it matters (three sources means three fallback branches and three test families).

6. **The cold-duration derivation is the weak link. [C][X]** Both flag `lastActivityAt + SidebarAgentColdSettings.thresholdSeconds()`. Claude identifies the actual defect: because it is computed from a *live setting*, editing the cold threshold in Settings retroactively rewrites how long every cold agent "has been cold," and a displayed elapsed time that moves backward when you change a preference is a credibility leak in a feature whose whole pitch is honesty. Claude's fix (stamp the boundary) and Codex's fix (pin the arithmetic in the table and test exact threshold crossing) are the two available answers.

7. **Accessibility must supersede, not stack. [C][X]** Bonsplit's `TabActivityAccessibility` already emits its own lifecycle value and a hardcoded waiting-only help string (`TabItemView.swift:148`, applied at `TabBarView.swift:1085` and `:1208`). Layering host-supplied help on top yields VoiceOver saying "Idle for 7 minutes, Flagged: …" then "Idle," or "Waiting for your response" twice. Both reviewers note the contract's "without duplicating values already exposed by the tab" only parses under a supersede rule, and both want that rule stated and tested, Codex explicitly including the collapsed/overflow tab renderer.

8. **Data-first, UI-last sequencing. [C][X]** Nearly identical orderings, independently derived: (a) freeze semantics and fixtures, (b) build the pure packet plus formatter with its full test matrix, (c) land persistence for all three panel kinds including legacy decode, (d) Surface Details as the first vertical slice, (e) the two sidebar mark locations, (f) Bonsplit plus the submodule push, (g) English freeze then six-locale translation, (h) review and one tagged validation pass. The shared rationale: each stage becomes the oracle for the next, and everything with a cross-repo or build-launch cost lands after the cheap parts have proven the design. The plan's current step 4 ("tests") batches tests after two steps of UI work; both reviewers want tests written with the code they cover.

9. **Surface Details should get a structured capture seam, not view-level rediscovery. [C][X]** One capture value carrying metadata, activity truth, creation time, last activity, and capture time as *separate* fields. Codex is explicit that the SwiftUI view must not rediscover a `Workspace` through globals; refresh recaptures absolute truth and the leaf clock only advances display ages. Claude adds the free win: `SurfaceManifestView` already has `refRow(label:value:field:size:)`, `copyButton(field:value:)`, and the `copiedField`/"Copied" flow, so the "selectable and unambiguous copy value" requirement is already solved and should be reused rather than reimplemented.

10. **The same packet wants a headless read. [all]** Claude: `c11 activity <surface>` over the socket, feeding Overwatch real numbers instead of inferred prose. Codex: a read-only agent-facing truth seam. Gemini: a `c11 top` process-list equivalent, or AppleScript. Claude and Codex both keep it out of scope for this ticket and file it as a follow-on; Gemini argues for doing it in the same pass. Majority position: file it now while context is hot, ship it next.

11. **Age-based attention routing is the first real product payoff. [all]** Claude: oldest-stuck-first as Option-V's third rung, free once a state boundary exists, and the honest answer to "what should I look at" when nothing is explicitly demanding attention. Codex: age-aware attention routing once waiting has a stable epoch. Gemini: an "Attention Required" queue sorted by wait duration, or by flag severity multiplied by time.

12. **Restore forensics. [C][X]** `createdAt` plus `lastActivityAt` plus `Captured` forms a triplet that distinguishes a restored-but-dormant surface from one newly created after relaunch. Claude sharpens it into a claim about c11 itself: "this surface is 3 days old and has been restored 4 times" is the first thing c11 could ever say that *proves* the PATH-scoped resume wrappers actually work. `createdAt` is an assertion about c11's continuity, not a display value.

---

## 2. Points of Genuine Disagreement

Worth resolving explicitly rather than letting the implementer pick.

1. **Emit `activity.state_changed` now, or defer history entirely?**
   - **[C] Yes, in this ticket.** One line at the same edge that stamps the boundary, through the existing `Sources/Events/EventEmitter.swift` (which already carries four C11-184 attention events). Argument: it is the *only* part of this ticket that compounds, and "deferring the emit does not defer the cost, it destroys the history."
   - **[X] No.** "Epoch history, only if demanded. Do not start that event history in this ticket." Argument: scope discipline; the present snapshot can evolve into bounded activity epochs later if operators ask.
   - Claude offers the middle path itself: if the emit cannot be made cheap enough off-main, stamping the anchor alone still leaves the door open.

2. **`createdAt`: protocol promotion or side registry?**
   - **[X] Promote `createdAt: Date?` through `Panel` and all three conformers**, with a constructor/identity audit by semantic category (initial workspace surface, split/new-surface paths, placeholder and last-panel replacement, restore for all three panel types, detach/transfer, browser reopen).
   - **[C] Use a `SurfaceCreationRegistry` mirroring `SurfaceActivityTracker`.** `Panel` is `@MainActor` with three conformers, one of which is 10,278 lines; promotion is a wide shallow diff across the noisiest files and must be repeated for every future surface kind. The registry route is four touch points that already exist and already do exactly this for `lastActivityAt` (`Workspace.swift:905`, `AppDelegate.swift:3317`).
   - Claude states the honest counter-argument for the protocol route (an immutable `let createdAt: Date` is trivially correct and needs no lifecycle management, whereas a registry is a second thing that can desync) and then makes the real point: `created_at` on `SessionPanelSnapshot` is the contract, both routes satisfy it, so **pick deliberately and say why** rather than defaulting to the wider diff.
   - Note both reviewers still need Codex's identity audit regardless of route: the invariant "same logical surface identity preserves its date, a genuinely new identity gets a new date, missing legacy provenance stays nil" has to be enforced at every call site either way.

3. **Waiting epoch: oldest unread, or newest?** **[X]** raises this as the single most load-bearing undecided semantic and argues for the **oldest currently unread, signal-eligible exact-surface notification**, because waiting began there and remains continuous until no qualifying unread record remains; using the newest would silently reset "Waiting for…" while the state never left waiting. Neither other reviewer noticed the ambiguity. Codex also notes the notification index currently records *membership, not time*, so a pure exact-surface epoch builder has to be added to `TerminalNotificationStore` rather than scanned from a view.

4. **Legacy `createdAt`: strictly `Not recorded`, or heuristically inferred?** **[G]** asks whether a rough `createdAt` could be inferred from the legacy snapshot file's modification time. **[C]** answers preemptively and in the opposite direction: "honest absence" (`Not recorded`, plus "never fabricate `0 minutes`") is one principle applied twice and should be named as a **convention** in the plan, because every temporal surface built after this one will copy it. Recommendation: hold the line, and record the reason so the question doesn't get re-litigated.

---

## 3. Best Concrete Suggestions

Ranked by leverage per unit of effort. Deduplicated across all three reviews.

1. **Invert the precompute: immutable anchors through the hot paths, formatting at hover. [C][X][G]** Carry presented state, optional state boundary, optional `lastActivityAt`, flag reason, `flagRaisedAt`, and suppression through `WorkspacePulseAgent` and the Bonsplit presentation. Format nothing until a pointer rests on a glyph. One fix resolves three problems at once: Equatable churn on two verified typing-critical gates, AC5's same-instant agreement (becomes automatic and free, since both callers invoke one pure formatter over the same anchors), and wasted `DateComponentsFormatter` work inside a view body for text nobody is looking at. Claude notes the plan gets *simpler*: one new ~40-line file, and step 2 stops needing to precompute localized composition anywhere.

2. **Write the timestamp-source table into the plan before implementation. [C][X]** Lifecycle → boundary source → missing-evidence behavior, plus the suppression ordering rule Codex supplies: **apply suppression before selecting the duration source** (raw waiting + suppressed + unflagged presents as idle and therefore uses activity evidence, not the hidden notification timestamp; flagged + suppressed preserves waiting and may use its unread epoch). Also decide future/invalid timestamp behavior here.

3. **Stamp `stateEnteredAt` at the transition edge and persist it as `state_entered_at`. [C]** Collapses three reconstruction rules into one field, one rule ("when c11 observed the transition"), one test family, and converts cold's start from an arithmetic function of a mutable setting into a recorded fact. Keep reconstruction as the *legacy fallback*, not the primary. Claude flags the reviewer trap: the plan must state explicitly that recording *when* inference changed is not *changing* inference, or a reviewer reading step 1's "without changing lifecycle inference" will treat the stamp as out of bounds.

4. **Use monotonic time for durations, wall-clock only for absolute stamps. [G]** The only reviewer to catch this, and it is cheap and real. `now - stateStart` over wall-clock is fragile across system sleep, lid-close, timezone change, and VM suspend, producing anomalies like "Cold for -5 hours" or an instant cold-state on wake. Use `ProcessInfo.processInfo.systemUptime` or `mach_absolute_time` for relative durations; reserve `Date` for `Created` and `Last activity` labels and for the persisted snapshot. Note the interaction with suggestion 3: a persisted wall-clock stamp is still the right *durable* record, so the plan needs a stated rule for reconciling a persisted wall-clock boundary with a monotonic in-session clock across a restart.

5. **Land the snapshot fields alone, first, as their own commit. [C][X]** `created_at` and `state_entered_at` on `SessionPanelSnapshot` plus capture, seed, and clear. Purely additive, the backcompat pattern is already proven by `last_activity_at` in C11-164, zero UI risk, fully testable in `c11LogicTests` via round-trip and legacy decode. Claude's asymmetric-payoff argument: **the data starts accumulating the moment the field lands, not the moment the UI lands.** If the rest of C11-185 slips a week, the operator's machine has a week of real timestamps when the tooltip arrives, and the analytics screen has history the day it is built. Start the clock before you build the clock face.

6. **Give hit-testing the padded mark its own plan step, not a clause. [C]** `vendor/bonsplit/Sources/Bonsplit/Public/SafeTooltip.swift` records that a previous AppKit `addToolTip` implementation *silently never fired* because it was hosted on a click-through view whose `hitTest` returned nil, and macOS never queries an occluded view for its tooltip. The tooltip owner must be genuinely hit-testable **while remaining transparent to click routing** so tab selection, context menu, and close behavior are unchanged. That pair is the single fiddliest thing in the ticket and is currently a clause inside step 2. Codex independently wants a test asserting attachment to the padded mark rather than the row or the composition rail.

7. **State and test the accessibility supersede rule. [C][X]** Host-supplied complete activity accessibility *replaces* Bonsplit's default lifecycle value; ordinary tabs with no complete presentation keep Bonsplit's localized default. Test the normal renderer and the collapsed/overflow renderer. In the sidebar summary row expose mark semantics once on the actionable row; in the census row expose them once on the standalone mark; keep the decorative shape itself hidden from accessibility.

8. **Add a pure exact-surface unread-epoch builder to `TerminalNotificationStore`. [X]** Do not scan notifications from a view. Decide oldest-vs-newest in the plan (see disagreement 3) and test the epoch resetting only after the last qualifying unread clears.

9. **Reuse `refRow` / `copyButton` / `copiedField` from `SurfaceManifestView`. [C]** Free, and it makes the new activity group visually native to a panel the ticket forbids redesigning.

10. **Design the Bonsplit seam as generic and data-shaped, not string-shaped. [X][G]** A Codable temporal-help payload (undated templates plus an optional boundary date) that Bonsplit renders without learning what "flagged," "suppressed," or "waiting" mean. Gemini adds the forward-compatibility argument: design it so it can later carry a rich payload if Bonsplit ever renders mini-charts or progress bars instead of text. Both note this keeps the primitive genuinely offerable upstream, since it imports no c11 policy.

11. **Name "honest absence" as a convention, not two acceptance criteria. [C]** `Not recorded` and "never fabricate `0 minutes`" are one principle. This ticket is where c11's temporal surfaces learn to say "I don't know," and everything downstream will copy whatever it does here.

12. **Measure sidebar body-evaluation frequency during step 1's baseline. [C]** Minutes of work with the existing debug event log, and it decides suggestion 1 empirically rather than by argument. The current step 1 baseline mapping omits it.

13. **Expand the test matrix. [X]** All three panel kinds; multiple unread notifications; waiting-epoch reset after the last unread clears; exact cold-threshold crossing; future and invalid timestamps; timezone-bearing copy values; accessibility non-duplication; tooltip attachment to the padded mark. Plus a constructor/identity audit checklist and a Bonsplit call-site audit covering normal and collapsed marks.

14. **File the two follow-on tickets now, while context is hot. [C]** `c11 activity <surface>` as a socket read, and oldest-stuck-first as Option-V's third rung. Both are thin once the projection exists and both are far more expensive to spec cold in three months.

15. **Spell out the Surface Details row obligations the plan compresses away. [X]** Activity, Created, Last activity, and Captured remain distinct rows; timestamps carry timezone; Created and Last activity remain selectable; copied values use an unambiguous offset-bearing form; `Not recorded` is localized and never converted to a fake date; and the behavior for non-agent terminal, browser, and markdown surfaces is explicitly defined rather than left to the implementer.

---

## 4. Wildest Mutations

Ordered roughly from most-plausible-next to most-ambitious. None are in scope for C11-185.

1. **Oldest-stuck-first navigation. [C]** C11-184 shipped oldest-flag-first then latest-waiting; boundaries give a third rung free: no flags, no waiting, jump to the agent cold longest. Zero new state. The most immediately valuable mutation on the list.

2. **"Why this mark?" provenance in Surface Details. [X]** Show the *source* of the current projection: lifecycle edge at T, unread record at T, cold threshold crossed at T. Turns intermittent liveness bugs from unfalsifiable into inspectable evidence.

3. **The transition ledger. [C]** `activity.state_changed {surface, from, to, at}` through the existing emitter. Turns "how long is this agent stuck" into "what does this fleet's day look like." Every link but the emit already exists.

4. **Lazy tooltips everywhere. [C]** There are 14 eager `.help(` call sites in `Sources/` today. Every one is a candidate to become lazy and always-fresh: worktree chips, port pills, notification rows, workspace cards. The ~40-line primitive pays for itself past the first use.

5. **Dense mode. [C]** The subtle one. `WorkspacePulseMarkRowMetrics` currently manages overflow with a "+N" chip *because marks must stay individually legible*. Once hover reliably carries identity, identity migrates off the 9pt glyph and a sidebar card could hold 60 marks instead of 30. This ticket quietly buys the option for a much denser fleet view.

6. **The attention-economy sidebar. [G]** Mutate the sidebar from a static list into a dynamic queue sorted by wait duration, or by flag severity multiplied by time.

7. **Session timeline scrubbing. [G]** With timestamps persisted, a true session timeline becomes buildable: scrub back to see exactly *when* an agent got stuck, or when a flag was raised relative to output.

8. **SLA monitoring and background OS notification. [G]** "Working > 10 minutes with no observable output" raises an internal flag; "waiting for input in the background > 5 minutes" fires an OS notification. The second is the more defensible of the two (see the caution below).

9. **Burn-rate meter. [G]** "Working for 20 minutes" correlates with token spend; a live per-tab burn meter helps manage compute cost. Attractive and dangerous: it is a *correlation* presented as a measurement.

10. **Auto-hibernation / GC. [G]** The most ambitious. Rather than passively showing "Cold for 3 hours," autonomously spin down, archive, or garbage-collect forgotten cold surfaces. Turns a passive UI feature into an active performance optimization, and turns a display bug into data loss. Would need the provenance work (mutation 2) to be trustworthy first.

11. **Terminal parity with Ghostty process start. [G]** Align logical `createdAt` with how Ghostty records process starts so a terminal-based agent and a browser-based agent look identical temporally.

**The caution, and it is unanimous in spirit even though only one reviewer states it. [C]** Durations plus transitions make "this agent spent 40 minutes idle" computable, and it is a short walk from there to a dashboard that reads like a performance metric. The contract's own out-of-scope list already draws the right line ("claiming observation of individual agent tool calls or output activity"), and the `Last activity` naming decision defends it precisely. The plan should state that the ledger **inherits that same epistemic limit**, because the moment this data reaches an analytics screen somebody will read it as more than it is. Mutations 8, 9, and 10 all sit on the wrong side of that line unless the limit travels with the data.

---

## 5. Flywheel Opportunities

The three reviewers found three *different* flywheels operating at three different altitudes. They are complementary, not competing, and the plan can start all three.

1. **The data-accumulation flywheel (Claude, the strongest claim in any of the three reviews).**
   Claude's blunt assessment of the plan as drafted: **"As written: none."** A tooltip is terminal. It is read once, understood, discarded, and generates no artifact and no accumulating asset. Surface Details is the same. Ship the plan exactly as written and you get a better product and precisely zero compounding.
   The ignition is one line at an edge the plan is already touching:
   > transitions recorded → durable event log → fleet digest and analytics have real history → operator trusts temporal data and asks better temporal questions → more surfaces annotate themselves with time → richer digest → …
   Every link but the first already exists: the event transport (four C11-184 attention events already flow through it), Overwatch as a consumer, and the analytics screen already on the operator's mind.
   **The timing argument is the important part, and it applies to the snapshot fields too:** the value of an event log is proportional to how far back it goes. A log started today is worth more in a month than a log started in a month is worth ever. Deferring does not defer the cost, it destroys the history. Guardrail: emit off the typing-hot path on C11-184's established off-main discipline, and only on real presented-state edges so the log does not become chatty.

2. **The engineering-correctness flywheel (Codex).**
   > one temporal source table → one truth packet → shared fixed-clock fixtures → renderer agreement tests → fewer divergent bugs → more confidence adding provenance → a stronger truth packet
   The small change that starts it is concrete and cheap: **make all three renderer tests consume the same fixture.** For a fixed surface, notification set, threshold, and `now`, assert that the sidebar tooltip text, the top-tab generic help/accessibility output, and the Surface Details Activity line all agree. Then test each renderer's actual attachment and hit area separately. That combination catches semantic drift and UI wiring failures independently, and it is the executable form of AC5 rather than a reviewer judgment call.

3. **The product-adoption flywheel (Gemini): transparency → trust → delegation.**
   > showing exactly what an agent is doing and for how long → operator trust → confidently launching more concurrent agents → more agents demand better visibility and sorting → richer temporal surfaces → more trust
   This is the one that connects to c11's stated mission (the operator running eight, ten, thirty agents). Gemini's accelerant is the correctness one: the flywheel only spins if the durations are *right*, which is exactly why the sleep/wake resilience point (suggestion 4) is load-bearing and not a nitpick. One visibly wrong duration costs more trust than ten correct ones earn.

4. **A fourth, implicit in Claude's read: resume becomes falsifiable.** c11's PATH-scoped resume wrappers are the one part of the system that reaches outside its own runtime, and therefore the part with the least visibility. `createdAt` plus a restore count makes resume diagnosable instead of a black box. That turns a trust liability into a trust asset, feeding flywheel 3.

---

## 6. Strategic Questions for the Plan Author

Deduplicated across all three reviews and grouped. Sources marked.

**Mechanism and hot paths**

1. Is the tooltip mechanism SwiftUI `.help()` or an AppKit tooltip owner? `.help()` captures its string at body-evaluation time and has no hover-time callback, so it cannot satisfy "refresh tooltip copy on hover entry" or AC5's same-instant agreement without clock-driven body re-evaluation. If `.help()` is a hard constraint, which of those two requirements is being relaxed, and has the operator agreed? **[C]**
2. Is exact hover-entry refresh mandatory for the *first frame* of the native tooltip, or is the existing 30-second `SidebarDecayClock` granularity acceptable? The locked wording currently implies the former. **[X]**
3. Have you confirmed that a duration-bearing `WorkspacePulseAgent` invalidates `TabItemView.==` (`ContentView.swift:11745`) once a minute per workspace, and that a duration-bearing `BonsplitTabActivityPresentation` trips `Workspace.swift:6818` and `WorkspaceContentView.swift:286` on the same cadence? If the answer is "acceptable," what is the measured cost at 20+ agents? **[C]**
4. How does the padded tooltip target stay hit-testable for tooltips, per `SafeTooltip.swift`'s recorded silent-failure mode, while remaining transparent to tab selection, context menu, and close? Should this be its own plan step rather than a clause in step 2? **[C][X]**
5. Is the activity-help projection tightly coupled to string generation, or is it a structured object a future CLI, background resource manager, or events consumer could reuse unchanged? **[G][X]**

**Temporal semantics**

6. Does a continuous waiting duration begin at the **oldest** currently unread signal-eligible exact-surface notification, or reset to the **newest**? Resetting would silently restart "Waiting for…" while the state never left waiting. **[X]**
7. Will you **record** `stateEnteredAt` at the transition edge, or **reconstruct** it from three sources? If reconstructing, is the cold-duration-moves-when-the-threshold-changes behavior intended, and does it survive the "never fabricate" standard this ticket is otherwise holding? **[C]**
8. Relatedly: if a state-entry anchor is *not* adopted and the operator edits the cold threshold while agents are cold, what should the displayed cold duration do? Silently jumping is the current implied behavior. **[C]**
9. How are durations computed across system sleep, lid-close, and timezone change? Should an agent be "Cold" immediately on wake if the threshold elapsed while sleeping? Are you using a monotonic clock for relative durations and wall-clock only for absolute labels, and if so how do a persisted wall-clock boundary and an in-session monotonic clock reconcile after restart? **[G]**
10. Should lifecycle-transition writes bypass `SurfaceActivityTracker`'s 250 ms first-write-wins debounce so the boundary is exact under fixed-clock tests and rapid transitions? **[X]**
11. What is the required copy representation for absolute timestamps: localized display plus ISO 8601 with numeric UTC offset, or one shared format? **[X]**
12. Should flag age be deliberately omitted from v1 copy while `flagRaisedAt` is retained in the semantic packet? **[X]**

**Identity, persistence, and scope**

13. `createdAt` route: protocol promotion through three `Panel` conformers (one of them 10,278 lines), or a `SurfaceCreationRegistry` mirroring `SurfaceActivityTracker` at four already-existing touch points? What makes the wider diff worth it, given `created_at` on `SessionPanelSnapshot` is the actual contract either way? **[C][X]**
14. Is a reopened closed browser a **new** logical surface with a new Created time, or does reopening preserve the closed surface's original logical creation? More generally, has the constructor/identity audit been done across initial workspace surface, split and new-surface paths, placeholder and last-panel replacement, restore for all three panel types, and detach/transfer? **[X]**
15. For browser, markdown, and non-agent terminal surfaces, should Surface Details show Activity and Last activity as `Not recorded`, or is there another existing truth source the contract intends to expose? **[X]**
16. Should the legacy-snapshot `Not recorded` rule stay absolute, or could a rough `createdAt` be inferred from the snapshot file's modification time? (Two reviewers implicitly answer "stay absolute"; the question is whether the reasoning gets written down as a durable convention so it is not re-litigated.) **[G] vs [C]**
17. Would you land `created_at` and `state_entered_at` as a **standalone first commit** so real data starts accumulating on the operator's machine immediately, even if the UI slips? **[C][X]**
18. Is `activity.state_changed` in or out? It is one line at an edge you are already touching, it is the only thing in this ticket that compounds, and deferring it does not defer the cost, it destroys the history. If it is out, is that a scope call or a threading concern? Codex's position is the opposite: do not start activity history here. **[C] vs [X]**

**Accessibility and the submodule boundary**

19. Does host-supplied help **supersede** `TabActivityAccessibility.help(for:)`, or stack with it? The contract's "without duplicating values already exposed by the tab" only parses under supersede. Where is that asserted? **[C][X]**
20. Must the generic Bonsplit tooltip cover collapsed/overflow representations of an individual surface tab as well as the visible horizontal tab strip? **[X]**
21. Is the Bonsplit help interface designed so it can later carry a rich data payload (mini-charts, progress bars) rather than only text, and does it stay free of c11 policy so it can be offered upstream? **[G][X]**

**Product framing**

22. The operator's 2026-07-24 note asked for the dedicated-agent-analytics-screen conversation *before* more weight lands on sidebar pulse cards. This ticket builds that screen's data layer without naming it. Should the plan state the schema intent explicitly so the screen is not later built against a shape this ticket accidentally foreclosed? **[C]**
23. The contract carefully limits what `Last activity` claims to observe. Once this data reaches an analytics surface, somebody will read it as agent productivity. Should that epistemic limit be written into the plan as a durable constraint on the ledger, not just on this ticket's copy? **[C]**
24. `WorkspacePulseAgent` has now taken forward-compatible fields from C11-183, real ones from C11-184, and more from C11-185, all inside an Equatable summary on a typing-sensitive path. At what point does it want splitting into a stable identity/state part and a volatile detail part fetched lazily? Is that this ticket or the next one? **[C]**
25. Could the precise `Waiting` duration drive an OS notification (agent waiting for input in the background beyond N minutes), and should an auto-archive policy for long-cold agents be considered on this data? Both are out of scope here; the question is whether the packet's shape should anticipate them. **[G]**

---

## Appendix: Unique Contributions by Reviewer

**Claude (Opus 5)** — the only review grounded in verified line numbers, which turns three "be careful" notes into concrete defects: the two Equatable gates, `.help()`'s structural inability to refresh at hover, and `SafeTooltip.swift`'s recorded silent-failure precedent. Also uniquely: the AC5-becomes-automatic framing, the `createdAt`-as-resume-proof reading, the "as written: no flywheel" verdict with the one-line ignition, the "start the clock before you build the clock face" sequencing argument, the dense-mode second-order unlock, the `refRow`/`copyButton` reuse, the "honest absence as a named convention" framing, and the productivity-metric caution.

**Codex** — the most execution-grade review, and the only one to catch the waiting-epoch ambiguity and that `NotificationIndexes` records membership rather than time. Also uniquely: the draft timestamp-source table, the suppression-ordering rule, the collapsed/overflow renderer gap, the logical-identity constructor audit by semantic category, the structured Surface Details capture seam (and the no-globals rule), the compressed row obligations, and the shared-fixture renderer-agreement flywheel. Its three "load-bearing decisions a competent implementer would still have to invent" is the sharpest single framing of what the plan is missing.

**Gemini** — the shortest review and the only one to catch the monotonic-clock/sleep-wake problem, which is a genuine correctness issue nobody else saw. Also the most ambitious on downstream product (burn-rate meter, auto-hibernation/GC, session timeline scrubbing, SLA monitoring) and the only one to raise Ghostty process-start parity and the legacy-mtime inference question. Its "transparency → trust → delegation" flywheel is the only one framed at the product-adoption altitude, and it connects most directly to c11's stated mission.
