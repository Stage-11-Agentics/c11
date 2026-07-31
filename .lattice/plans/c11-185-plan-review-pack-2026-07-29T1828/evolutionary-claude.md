# TP-c11-185-plan-Claude-Evolutionary-20260729-1828

Reviewer: Claude (Opus 5) · Lens: Evolutionary · Plan: `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md` (6 steps) · Contract: C11-185

Grounded against HEAD `78e348c74`. Files read: `Sources/Sidebar/SidebarActivityProjector.swift`, `Sources/Conversation/SurfaceActivity.swift`, `Sources/SurfaceManifestView.swift`, `Sources/Panels/Panel.swift`, `Sources/SessionPersistence.swift` (`SessionPanelSnapshot`), `Sources/SidebarDecayClock.swift`, `Sources/ContentView.swift` (census + `TabItemView.==`), `Sources/Workspace.swift` (`resolvedSurfaceTabActivityPresentation`, snapshot capture), `vendor/bonsplit/.../BonsplitActivityAnimationClock.swift`, `.../SafeTooltip.swift`, `.../Views/TabItemView.swift`.

---

### Executive Summary

The plan is executable and correctly scoped, but it is aiming one level too low. It reads as "add tooltip strings and two timestamp fields." What it is actually doing is giving c11 a **temporal model of agent work**: the third leg of a tripod whose first two legs already shipped. C11-183 gave agent state a *shape* (what is it). C11-184 gave it *modifiers* (does it want me). C11-185 gives it *time* (how long, since when, since first breath). Once `createdAt`, `lastActivityAt`, and a state-entry anchor are all persisted per surface, c11 can answer questions it currently cannot: which agent has been stuck longest, how long a session has actually lived, what the fleet's throughput looks like. That is the data layer for the dedicated agent-analytics screen the operator flagged on 2026-07-24 as the thing to raise before stacking more weight onto sidebar pulse cards.

The biggest concrete opportunity is also the biggest correctness risk, and they are the same decision. The plan says "precompute it for top tabs and `WorkspacePulseAgent`" and "refresh tooltip copy on hover entry." Those two sentences are in tension, and as written the first one wins in a way that breaks three things at once: it puts a value that changes every minute inside two verified Equatable fast-path gates, it makes acceptance criterion 5 (tooltip and Surface Details agree at the same clock instant) unachievable rather than merely hard, and it burns date-formatting work in a SwiftUI body for every agent on every sidebar invalidation. Inverting it, precompute immutable *time anchors*, format lazily at hover through an AppKit tooltip owner, resolves all three at once and leaves behind a reusable primitive. That is the single highest-leverage change to this plan.

Second opportunity: the plan reconstructs three different state-start times from three different sources with three different fallback rules. Stamping one `stateEnteredAt` at the transition edge collapses that into one field, one rule, one test matrix, and is the exact field that makes everything downstream possible. Ship it as the primary and keep reconstruction as the legacy fallback, not the reverse.

---

### What's Really Being Built

**Stated deliverable:** hover text on marks, plus three rows in Surface Details.

**Actual capability:** a per-surface temporal ledger, persisted across restart, that survives the app's own lifecycle. Concretely, after this ships `SessionPanelSnapshot` carries `last_activity_at` (already there, C11-164) plus `created_at` (new), and if step 2 is done well, a state-entry anchor too. That triple is the minimum viable schema for every "how is the fleet doing over time" question c11 cannot currently answer.

Three consequences the plan does not name:

1. **The tooltip is a read-model of an event log that does not exist yet.** The plan derives durations by reconstruction. The moment you instead *record* the transition, you have a log, and the log is worth an order of magnitude more than the tooltip. `Sources/Events/EventEmitter.swift` already exists and already carries the four C11-184 attention events. Adding `activity.state_changed {from, to, at}` at the same edge where you stamp the anchor costs one line and makes the ledger durable, queryable, and consumable by Overwatch without any new store.

2. **`createdAt` surviving restore is a trust signal for session resume, not just a details row.** c11 ships PATH-scoped resume wrappers under `Resources/bin/` whose entire justification is capturing lifecycle across reboots. "This surface is 3 days old and has been restored 4 times" is the first thing c11 could ever say that proves resume actually worked. The plan treats `createdAt` as a display value; it is really an assertion about c11's own continuity.

3. **Honest absence is a feature being established as a convention.** `Not recorded` rather than a fabricated timestamp, and "never fabricate `0 minutes`," are the same principle applied twice. This ticket is where c11's temporal surfaces learn to say "I don't know." That convention will be copied by everything downstream, so it is worth naming as a convention in the plan rather than leaving it as two independent acceptance criteria.

---

### How It Could Be Better

#### 1. Invert the precompute: anchors, not strings. Pull, not push.

This is the load-bearing recommendation. Three verified problems, one fix.

**Problem A: Equatable churn in two verified hot gates.**

`Sources/ContentView.swift:11745` includes `lhs.workspacePulse == rhs.workspacePulse` in `TabItemView`'s `==`, and `WorkspacePulseSummary` holds `agents: [WorkspacePulseAgent]` (`SidebarActivityProjector.swift:72`). Put a rendered duration string on `WorkspacePulseAgent` and every sidebar row's `==` fails once a minute, forever, for every workspace. The `.equatable()` fast path that CLAUDE.md calls out as typing-latency-critical stops paying off on a wall-clock schedule.

Same shape on the top tab: `Sources/Workspace.swift:6818` gates the tab update on `existing.activityPresentation != activityPresentation`, and `WorkspaceContentView.swift:286` does the same comparison in its sync path. A duration inside `BonsplitTabActivityPresentation` means a real `Tab` mutation and tab-bar diff every minute per agent tab.

**Problem B: SwiftUI `.help()` cannot honor "refresh on hover entry."** `.help(_:)` captures its string at body-evaluation time. There is no hover-time callback. So the plan has picked a mechanism that is structurally incapable of the freshness the contract requires, and the only way to fake it is to re-evaluate bodies on a clock, which is exactly Problem A. AppKit does have the callback: `NSView.toolTip` with an `NSToolTipOwner` gets `view(_:stringForToolTip:point:userData:)` **at hover time**. That is the primitive the contract is describing.

**Problem C: AC5 becomes unachievable, not just hard.** "State duration agrees with the tooltip for the same surface at the same clock instant" cannot be guaranteed when the tooltip string was frozen at the last body eval and the details panel is aging on a 30s clock (`SidebarDecayClock.interval = 30`). With a hover-time provider, agreement is automatic and free: both callers invoke the same pure formatter over the same immutable anchors.

**The fix.** Add one small `NSViewRepresentable` (call it `LazyTooltip`) holding a `provider: () -> String?`, whose backing `NSView` sets `toolTip` to a sentinel and implements the owner callback to invoke the provider. Then:

- `WorkspacePulseAgent` and `BonsplitTabActivityPresentation` carry only immutable, transition-scoped values: presented state, optional `stateEnteredAt`, optional `lastActivityAt`, flag reason, `flagRaisedAt`, suppressed. These change only when something real changes, so both `==` gates keep working exactly as they do today.
- Zero `DateComponentsFormatter` / `RelativeDateTimeFormatter` work happens until a pointer actually rests on a 9pt glyph. Today the census (`ContentView.swift:8678`) runs inside a view body; adding per-agent date formatting there is real allocation on every sidebar invalidation, for text nobody is looking at.
- No timers anywhere in the tooltip path. The "no per-agent repeating timers" guardrail becomes trivially satisfied rather than carefully defended.
- One pure formatter function is the single source of truth for tooltip text, Surface Details text, and the VoiceOver value, which is what the ticket's "same projection" architecture point actually wants.

**Verified gotcha to respect:** `vendor/bonsplit/Sources/Bonsplit/Public/SafeTooltip.swift` documents that a previous AppKit `addToolTip` implementation silently never fired because it was hosted on a click-through view (`hitTest` returning nil), and macOS never queries an occluded view for its tooltip. The lazy tooltip view must therefore be genuinely hit-testable. The ticket already permits including the mark padding in the target, so there is a real hit area available; the plan should state that the padded area is the tooltip owner and that it must not return nil from `hitTest`. Also worth noting: the padded area must remain transparent to click routing so tab selection, context menu, and close behavior are unchanged, which means "hit-testable for tooltips, pass-through for clicks." Getting that pair right is the one genuinely fiddly bit of this ticket and deserves a named step, not a clause.

**Cost of this change to the plan:** one new ~40-line file, and step 2 gets *simpler* because the "localized duration/modifier composition" stops needing to be precomputed anywhere. Net reduction in plan complexity.

#### 2. Stamp the state-entry time; do not reconstruct it three ways.

The contract asks for four duration semantics with three different sources: working/idle from a `SurfaceActivityTracker` boundary, cold from `lastActivity + SidebarAgentColdSettings.thresholdSeconds()`, waiting from a notification's creation time. That is three reconstruction rules, three fallback branches, and three test families, and the cold one has a semantic bug hiding in it: because it is *computed* from a live setting, changing the cold threshold in Settings retroactively rewrites how long every cold agent has "been cold." A displayed elapsed time that moves backward when you change a preference is a small but genuine credibility leak in a feature whose entire pitch is honesty about what c11 observed.

**Better:** have `SurfaceLivenessDeriver` stamp `stateEnteredAt` when the *presented* state changes, and persist it in `SessionPanelSnapshot` as `state_entered_at` next to the proven `last_activity_at` field. One field, one rule ("when c11 observed the transition"), one test family. Cold's start becomes a recorded fact rather than an arithmetic function of a mutable setting.

Note explicitly that this does not violate step 1's "without changing lifecycle inference." Recording *when* inference changed is not changing inference. The plan should say so, because a reviewer reading step 1 will otherwise treat the stamp as out of bounds.

**Keep reconstruction, demote it.** Surfaces that were alive before the field existed, and legacy snapshots, fall back to the reconstruction rules. That is the same backcompat shape C11-164 already proved with `lastActivityAt`, so the risk is known and the decode path is copy-shaped.

**Tradeoff to name honestly:** reconstruction survives restart for free; a stamp does not unless persisted. Persisting it is the whole point, and the slot is already there.

#### 3. `createdAt`: consider a registry instead of a protocol promotion.

Step 3 says "promote optional logical `createdAt` through the `Panel` implementations." `Panel` is a `@MainActor` protocol with three conformers, one of which (`BrowserPanel.swift`) is 10,278 lines. Promoting through all three plus every fresh-create and restore call site is a wide, shallow diff across the noisiest files in the repo, and it will need repeating for every future surface kind.

The alternative is already the established pattern in this codebase for exactly this shape of data: a `SurfaceCreationRegistry` mirroring `SurfaceActivityTracker` beat for beat, off-main serial queue, `seed(from:)`, `snapshot()`, keyed by surface UUID. Then the entire wiring is four touch points, all of which already exist and already do this for `lastActivityAt`:

- one `record` at surface creation,
- one read at `Sources/Workspace.swift:905` where `lastActivityAt` is already captured for the snapshot,
- one `seed` at `Sources/AppDelegate.swift:3317` where the activity floor is already seeded from `panel.lastActivityAt`,
- one clear on close, alongside the existing tracker clear.

Zero protocol changes, zero per-kind restore plumbing, and it generalizes to future surface kinds for free.

**The honest counter-argument:** `createdAt` is immutable and intrinsic to a panel, so `let createdAt: Date` on each conformer is trivially correct and needs no synchronization or lifecycle management at all, whereas a registry adds a second thing that can leak or desync. That is a legitimate reason to prefer the protocol route. The decision that actually matters is neither: it is that `created_at` on `SessionPanelSnapshot` is the contract, and both routes satisfy it. The plan should pick deliberately and say why, rather than defaulting to the wider diff. My recommendation is the registry, on the grounds that it is the cheaper diff, matches an existing proven pattern in the same file pair, and does not have to be repeated per surface kind.

#### 4. Reuse Surface Details' existing copy affordances.

The contract requires absolute timestamps that "remain selectable and offer an unambiguous copy value." `Sources/SurfaceManifestView.swift` already has `refRow(label:value:field:size:)` and `copyButton(field:value:)` with the `copiedField` / "Copied" confirmation flow. The plan does not name them and risks reimplementing selectable text. This is a small win but it is free, and it makes the new group visually native to the panel rather than a bolted-on block, which matters because the ticket forbids redesigning the panel.

#### 5. Resolve the Bonsplit accessibility collision the plan does not mention.

Bonsplit's `TabActivityAccessibility.help(for:)` (`TabItemView.swift:148`) currently hardcodes waiting-only help ("This surface needs your response.") and it is applied as `.accessibilityHint` at `TabBarView.swift:1085` and `:1208`. `TabActivityAccessibility.value(for:)` separately emits "Running / Idle / Cold / Waiting for your response."

Layer a host-supplied help string on top of that without retiring the built-in and the operator gets two competing sentences in the tooltip-versus-VoiceOver channel, plus a duplicated "Waiting for your response." The contract explicitly requires VoiceOver to receive lifecycle, duration, modifiers, and flag reason "in the same semantic order as the tooltip, without duplicating values already exposed by the tab" — which is *only* satisfiable if the host-supplied string supersedes Bonsplit's derived one when present. The plan needs a sentence saying so, and a Bonsplit test asserting the supersede precedence, not just "help/accessibility rendering."

#### 6. Fix the step ordering (see Sequencing).

---

### Mutations and Wild Ideas

**`c11 activity <surface>` — the tooltip as a CLI read.** Once the projection is a pure value over immutable anchors, exposing it over the socket is a thin handler, not a feature. The ticket wisely puts new CLI/socket fields out of scope *"solely for this UI change"*, which is the right hedge for this ticket and exactly the thing to revisit the moment the value type exists. Overwatch's entire job is routing operator attention across workspaces, and right now it has to infer duration from prose. This hands it a number. File it as a follow-on, not scope creep.

**Oldest-stuck-first as Option-V's third rung.** C11-184 shipped oldest-flag-first, then latest-waiting. Durations give you a third fallback for free: no flags, no waiting, jump to the agent that has been cold longest. That is the honest answer to "what should I look at" when nothing is explicitly demanding attention, and it needs zero new state once `stateEnteredAt` exists. This is the most immediately valuable mutation on the list.

**The transition ledger.** Emit `activity.state_changed {from, to, at}` from the same edge that stamps the anchor. The log is durable, already has a transport, already has an Overwatch consumer, and turns "how long is this agent stuck" into "what does this fleet's day look like." One line at the right seam. This is the flywheel ignition, treated in its own section below.

**Dense mode.** If hover reliably answers "which agent is this and how long," identity migrates off the glyph and the marks can shrink. `WorkspacePulseMarkRowMetrics` currently manages overflow with a "+N" chip because marks must stay individually legible. Once hover carries identity, a sidebar card could hold 60 marks instead of 30. The tooltip is quietly the enabling condition for a much denser fleet view. Not this ticket, but worth knowing that this ticket buys the option.

**Resume forensics.** `createdAt` plus restore count turns the resume wrappers from a black box into something diagnosable. "Created 3 days ago, restored 4 times, last activity 12 minutes ago" is a debugging surface for the one part of c11 that reaches outside its own runtime and therefore has the least visibility.

**The one I'd be careful with: inferring agent productivity.** Durations plus transitions make "this agent spent 40 minutes idle" computable, and it is a short walk from there to a dashboard that looks like a performance metric. The contract's own out-of-scope list already draws the right line ("claiming observation of individual agent tool calls or output activity"), and the `Last activity` naming decision defends it precisely. Worth stating in the plan that the ledger inherits that same epistemic limit, because the moment this data reaches an analytics screen somebody will read it as more than it is.

---

### What It Unlocks

**Immediately, on ship:**
- Three persisted temporal facts per surface, accumulating on the operator's real machine from day one.
- A pure, testable duration projection with a single formatter, reusable anywhere.
- A pull-based hover-projection primitive. There are 14 eager `.help(` call sites in `Sources/` today; every one is a candidate to become lazy and always-fresh (worktree chips, port pills, notification rows, workspace cards).

**One step out:**
- Oldest-stuck-first navigation.
- `c11 activity` as a socket read, and through it Overwatch fleet digests with real numbers instead of inferred prose.
- The agent-analytics screen with actual history behind it rather than starting from zero on the day it is built.

**Two steps out:**
- Fleet throughput and wall-clock attribution.
- Stuck-agent detection and automatic reaping proposals.
- Dense fleet views, gated on hover carrying identity.

---

### Sequencing and Compounding

The plan's order is: baseline → projection + attach → persistence → tests → submodule/translation → validate. Tests in step 4 for work done in steps 2 and 3 is the part to fix, and there is a bigger reordering available.

**Recommended order, with the reasoning:**

**Step A. Ship the two snapshot fields alone, first, as their own commit.** `created_at` and `state_entered_at` on `SessionPanelSnapshot`, plus capture, seed, and clear. Purely additive, backcompat pattern already proven by `last_activity_at` in C11-164, zero UI risk, testable entirely in `c11LogicTests` through round-trip and legacy-decode.

This is the compounding move and it is worth being explicit about why: **the data starts accumulating the moment the field lands, not the moment the UI lands.** If the rest of C11-185 slips a week, the operator's machine has a week of real creation timestamps when the tooltip finally shows up, and the analytics screen has history the day it is built. Start the clock before you build the clock face. This is the one sequencing change with a genuinely asymmetric payoff.

**Step B. The pure projection plus its full test matrix, no UI.** The value type, the formatter, the fallback rules, the modifier composition. All of it is pure, so all of it is `c11LogicTests`, and per the C11-184 precedent CI is the sole executor. This is where the eight test cases in the plan's step 4 belong: written with the code they cover, not batched after two steps of UI work.

**Step C. `LazyTooltip` plus Surface Details.** Surface Details before the marks, deliberately: it is a plain SwiftUI panel with no hit-testing subtlety, no Equatable fast path, and no submodule. It proves the projection end to end against a low-risk surface. If the duration semantics are wrong, you find out here, cheaply.

**Step D. The two sidebar mark locations.** c11-owned, no submodule round trip.

**Step E. Bonsplit help field plus the top tab, and the submodule push.** Last, because it is the only step with a cross-repo commit ordering gate, and because by now the projection and the tooltip primitive are both proven. Fewer reasons to need a second Bonsplit commit.

**Step F. Localization, then one tagged QA launch.** Unchanged from the plan, and correct: English freeze, delegate six locales to a fresh surface, `jq` validation with interpolation-token checks.

**What this buys:** the risky and expensive parts (submodule, tagged build, computer-use approval) land last, after everything cheap has already proven the design. The plan as written puts the Bonsplit renderer in step 2 and discovers problems in step 4 or step 6, each of which costs a build-launch-fix loop and potentially a second submodule commit.

**Under-invested early in the current plan:** step 1's baseline mapping does not include measuring the current sidebar body-evaluation frequency. That number is what tells you whether string precompute in the census is a real cost or a theoretical one, and it takes minutes to get with the existing debug event log. Get it before choosing, not after.

---

### The Flywheel

**As written: none.** A tooltip is terminal. It is read once, understood, discarded, and generates no artifact and no accumulating asset. Surface Details is the same. Ship this plan exactly as drafted and you have a better product and precisely zero compounding.

**Engineerable, with one line.** At the same edge where you stamp `stateEnteredAt`, emit `activity.state_changed {surface, from, to, at}` through the existing `Sources/Events/EventEmitter.swift`. Then:

> transitions recorded → durable event log → fleet digest and analytics have real history → operator trusts temporal data and asks better temporal questions → more surfaces annotate themselves with time → richer digest → ...

Every link but the first already exists. The event transport exists (C11-184 put four attention events through it). Overwatch exists and is already an event consumer. The analytics screen is already on the operator's mind. The only missing link is the emit, and the plan is already going to be touching that exact edge for a different reason.

**Why this is worth doing inside C11-185 rather than deferring:** the value of an event log is proportional to how far back it goes. A log started today is worth more in a month than a log started in a month is worth ever. Deferring the emit does not defer the cost, it destroys the history. This is the same argument as Step A above and it is the strongest sequencing claim in this review.

**The guardrail to respect:** emit off the typing-hot path, on the same off-main discipline C11-184's socket policy already established, and only on real presented-state edges so the log does not become chatty. If the emit cannot be made cheap enough, stamping the anchor alone still leaves the door open, and that is the acceptable fallback.

---

### Concrete Suggestions

1. **Add `LazyTooltip`** (`NSViewRepresentable` + `NSToolTipOwner`, ~40 lines) and make it the mechanism for all three mark locations. Precompute anchors, format at hover. Fixes Equatable churn in both verified gates, makes AC5 automatically true, eliminates all formatting work for tooltips nobody hovers, and needs no timers. Respect `SafeTooltip.swift`'s recorded lesson: the owner view must be hit-testable while staying transparent to click routing. Give that pair its own plan step.

2. **Stamp `stateEnteredAt` in `SurfaceLivenessDeriver` on presented-state edges**, persist as `state_entered_at`, and demote the three reconstruction rules to a legacy fallback. Collapses three duration sources into one, and stops cold-duration from moving retroactively when the operator edits the cold threshold. Say explicitly in the plan that this does not change lifecycle inference.

3. **Emit `activity.state_changed` at that same edge.** One line. Converts a terminal feature into a compounding one. Off-main, edges only.

4. **Reorder to A–F above.** Snapshot fields alone and first, pure projection with its own tests, Surface Details before marks, Bonsplit and the submodule last, tagged QA once.

5. **Use a `SurfaceCreationRegistry` mirroring `SurfaceActivityTracker`** rather than promoting `createdAt` through three `Panel` conformers including a 10k-line file. Four touch points, all of which already exist and already do this for `lastActivityAt` (`Workspace.swift:905`, `AppDelegate.swift:3317`). Or promote through the protocol deliberately and say why. Either way, name the choice.

6. **State the Bonsplit accessibility supersede rule** and test it: when the host supplies help, it replaces `TabActivityAccessibility.help(for:)` rather than stacking with it, and the tab must not announce "Waiting for your response" twice.

7. **Reuse `refRow` / `copyButton` / `copiedField`** from `SurfaceManifestView` for the new activity group.

8. **Add the "honest absence" convention as a named plan item**, not two separate acceptance criteria. `Not recorded` and "never fabricate `0 minutes`" are one principle, and it will be copied by every temporal surface built after this one.

9. **File two follow-on tickets now, while the context is hot:** `c11 activity <surface>` as a socket read, and oldest-stuck-first as Option-V's third rung. Both are thin once this projection exists and both are much more expensive to spec cold in three months.

10. **Measure sidebar body-evaluation frequency during step 1's baseline.** It is the number that decides suggestion 1 empirically rather than by argument, and the existing debug event log will tell you in minutes.

---

### Questions for the Plan Author

1. **Tooltip mechanism.** Is the intent SwiftUI `.help()` or an AppKit tooltip owner? `.help()` captures its string at body-evaluation time and has no hover-time callback, so it cannot satisfy "refresh tooltip copy on hover entry" or AC5's same-instant agreement without clock-driven body re-evaluation. If `.help()` is a hard constraint, which of those two requirements is being relaxed, and has the operator agreed?

2. **Equatable churn.** Have you confirmed that a duration-bearing `WorkspacePulseAgent` invalidates `TabItemView.==` at `ContentView.swift:11745` once a minute per workspace, and that a duration-bearing `BonsplitTabActivityPresentation` trips `Workspace.swift:6818` and `WorkspaceContentView.swift:286` on the same cadence? If the answer is "acceptable," what is the measured cost at 20+ agents?

3. **Stamp or reconstruct.** Will you record `stateEnteredAt` at the transition edge, or reconstruct from three sources? If reconstructing, is the cold-duration-moves-when-the-threshold-changes behavior intended, and does it survive the "never fabricate" standard this ticket is otherwise holding?

4. **`createdAt` route.** Protocol promotion through three conformers, or a registry mirroring `SurfaceActivityTracker`? What makes the wider diff worth it, given the snapshot field is the actual contract either way?

5. **Event emission.** Is `activity.state_changed` in or out? It is one line at an edge you are already touching, it is the only thing in this ticket that compounds, and deferring it does not defer the cost, it destroys the history. If it is out, is that a scope call or a threading concern?

6. **Bonsplit help precedence.** Does host-supplied help supersede `TabActivityAccessibility.help(for:)`, or stack with it? The contract's "without duplicating values already exposed by the tab" only parses under supersede. Where is that asserted?

7. **Hit-testing the mark padding.** How does the padded tooltip target stay hit-testable for tooltips (per `SafeTooltip.swift`'s recorded failure mode) while remaining transparent to tab selection, context menu, and close? This is the fiddliest part of the ticket and currently a clause in step 2 rather than a step.

8. **Sequencing the snapshot fields.** Would you land `created_at` and `state_entered_at` as a standalone first commit so real data starts accumulating on the operator's machine immediately, even if the UI slips?

9. **Analytics screen alignment.** The operator's 2026-07-24 note asked for the dedicated-screen conversation before more weight lands on sidebar pulse cards. This ticket builds that screen's data layer without naming it. Should the plan state the schema intent explicitly so the screen is not later built against a shape this ticket accidentally foreclosed?

10. **Epistemic boundary, inherited.** The contract carefully limits what `Last activity` claims to observe. Once this data reaches an analytics surface, somebody will read it as agent productivity. Should that limit be written into the plan as a durable constraint on the ledger, not just on this ticket's copy?

11. **Cold threshold as a live setting.** If a state-entry anchor is *not* adopted, and the operator changes the cold threshold while agents are cold, what should the displayed cold duration do? Silently jump is the current implied behavior.

12. **`WorkspacePulseAgent` growth.** This struct has now taken forward-compatible fields from C11-183 and real ones from C11-184, and C11-185 adds more, all inside an Equatable summary on a typing-sensitive path. At what point does it want splitting into a stable identity/state part and a volatile detail part fetched lazily? Is that this ticket or the next one?
